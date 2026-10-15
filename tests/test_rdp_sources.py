"""Exercise the RDP append scripts with isolated Azure CLI/azd fixtures."""

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RULE_NAME = "allow-rdp-from-trusted-source"
CURRENT = "203.0.113.42/32"
RULE = {
    "name": RULE_NAME, "direction": "Inbound", "access": "Allow", "protocol": "Tcp",
    "priority": 1000, "sourceAddressPrefix": "198.51.100.10/32",
    "sourcePortRange": "*", "destinationAddressPrefix": "*", "destinationPortRange": "3389",
    "description": "Keep this description",
}


def mock_cli(command, args):
    path = Path(os.environ["AGENTBOX_RDP_STATE"])
    state = json.loads(path.read_text())
    state["calls"].append([command, *args])
    path.write_text(json.dumps(state))

    def option(name):
        return args[args.index(name) + 1]

    def fail_if(stage):
        if state.get("failure") == stage:
            print(f"Synthetic {stage} failure.", file=sys.stderr)
            sys.exit(23)

    if command == "azd":
        assert args[:2] in (["env", "get-values"], ["env", "set"]), args
        assert Path(option("--cwd")) == path.parent, args
        if "--environment" in args:
            assert option("--environment") == "test-env", args
        if args[1] == "get-values":
            fail_if("env-read")
            print(json.dumps(state["config"]))
        else:
            fail_if("env-save")
            assert args[2] == "VM_RDP_ADDITIONAL_SOURCES", args
            assert option("--environment") == "test-env", args
            assert isinstance(json.loads(args[3]), list), "Native CLI lost JSON array quoting."
            state["config"][args[2]] = args[3]
    else:
        assert command == "az" and args[:3] == ["network", "nsg", "rule"], args
        assert option("--subscription") == "11111111-1111-1111-1111-111111111111", args
        assert option("--resource-group") == "rg-test", args
        assert option("--nsg-name") == "vm-test-nsg", args
        action = args[3]
        if action == "list":
            fail_if("rules-read")
            print(json.dumps(state["rules"]))
        else:
            assert option("--name") == RULE_NAME, args
            if action == "show":
                fail_if("verify")
                rule = next(rule for rule in state["rules"] if rule["name"] == RULE_NAME)
                if state.get("mismatch"):
                    rule = {**rule, "sourceAddressPrefix": "192.0.2.99/32", "sourceAddressPrefixes": []}
                print(json.dumps(rule))
            else:
                assert action in ("create", "update"), args
                fail_if("rule-write")
                start = args.index("--source-address-prefixes") + 1
                end = next((i for i in range(start, len(args)) if args[i].startswith("--")), len(args))
                sources = args[start:end]
                assert sources and sources == json.loads(state["config"]["VM_RDP_ADDITIONAL_SOURCES"])
                if action == "create":
                    assert not any(rule["name"] == RULE_NAME for rule in state["rules"])
                    for flag, expected in {
                        "--priority": "1000", "--direction": "Inbound", "--access": "Allow",
                        "--protocol": "Tcp", "--destination-port-ranges": "3389",
                    }.items():
                        assert option(flag) == expected, args
                    rule = copy.deepcopy(RULE)
                    state["rules"].append(rule)
                else:
                    assert "--priority" not in args and "--destination-port-ranges" not in args
                    rule = next(rule for rule in state["rules"] if rule["name"] == RULE_NAME)
                rule["sourceAddressPrefix"] = sources[0] if len(sources) == 1 else None
                rule["sourceAddressPrefixes"] = sources if len(sources) > 1 else []
    path.write_text(json.dumps(state))


class RdpSourceTests(unittest.TestCase):
    def check_case(self, platform, state, success, expected=None, explicit_environment=True):
        with tempfile.TemporaryDirectory(prefix="agentbox-rdp-append-") as temporary:
            directory = Path(temporary)
            scripts = directory / "scripts"
            scripts.mkdir()
            for name in ("add-rdp-source-ip.sh", "Add-RdpSourceIp.ps1"):
                shutil.copyfile(ROOT / "scripts" / name, scripts / name)
            (scripts / "get-rdp-source.sh").write_text(
                'if [ "$AGENTBOX_LOOKUP_FAIL" = 1 ]; then echo "Synthetic lookup failure" >&2; exit 1; fi\n'
                f'printf "%s\\n" "{CURRENT}"\n'
            )
            (scripts / "Get-RdpSource.ps1").write_text(
                'if ($env:AGENTBOX_LOOKUP_FAIL -eq "1") { throw "Synthetic lookup failure" }\n'
                f'"{CURRENT}"\n'
            )
            binary = directory / "bin"
            binary.mkdir()
            for command in ("az", "azd"):
                stub = binary / command
                stub.write_text(
                    f'#!/usr/bin/env bash\nexec "$AGENTBOX_PYTHON" "$AGENTBOX_RDP_TEST" mock-cli {command} "$@"\n'
                )
                stub.chmod(0o755)
                (binary / f"{command}.cmd").write_text(
                    f'@"%AGENTBOX_PYTHON%" "%AGENTBOX_RDP_TEST%" mock-cli {command} %*\n'
                )
            state_path = directory / "state.json"
            state_path.write_text(json.dumps(state))
            command = (
                ["bash", str(scripts / "add-rdp-source-ip.sh")] if platform == "bash" else
                ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(scripts / "Add-RdpSourceIp.ps1")]
            )
            if explicit_environment:
                command += ["test-env"] if platform == "bash" else ["-EnvironmentName", "test-env"]
            result = subprocess.run(
                command, cwd=ROOT, text=True, capture_output=True, timeout=30,
                env={**os.environ, "PATH": str(binary) + os.pathsep + os.environ["PATH"],
                     "AGENTBOX_PYTHON": sys.executable, "AGENTBOX_RDP_TEST": str(Path(__file__).resolve()),
                     "AGENTBOX_RDP_STATE": str(state_path),
                     "AGENTBOX_LOOKUP_FAIL": str(int(state.get("lookup_fails", False)))},
            )
            self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
            after = json.loads(state_path.read_text())
            writes = [call for call in after["calls"] if call[:4] in (
                ["az", "network", "nsg", "rule"],
            ) and call[4] in ("create", "update")]
            saves = [call for call in after["calls"] if call[:3] == ["azd", "env", "set"]]
            if success:
                self.assertIn("Verified RDP sources:", result.stdout)
                self.assertEqual(json.loads(after["config"]["VM_RDP_ADDITIONAL_SOURCES"]), sorted(expected))
                self.assertEqual(len(writes), 1)
                self.assertEqual(len(saves), 1)
                first_call = after["calls"][0]
                self.assertEqual("--environment" in first_call, explicit_environment)
                actual = next(rule for rule in after["rules"] if rule["name"] == RULE_NAME)
                original = next((rule for rule in state["rules"] if rule["name"] == RULE_NAME), None)
                if original:
                    for key, value in original.items():
                        if key not in ("sourceAddressPrefix", "sourceAddressPrefixes"):
                            self.assertEqual(actual[key], value)
                self.assertEqual(
                    [rule for rule in after["rules"] if rule["name"] != RULE_NAME],
                    [rule for rule in state["rules"] if rule["name"] != RULE_NAME],
                )
            else:
                self.assertTrue(result.stderr.strip(), "Failure did not report an error.")
                self.assertNotIn("Verified RDP sources:", result.stdout)
                if state.get("failure") in ("rule-write", "verify") or state.get("mismatch"):
                    self.assertEqual(len(writes), 1)
                    self.assertEqual(json.loads(after["config"]["VM_RDP_ADDITIONAL_SOURCES"]), sorted(expected))
                else:
                    self.assertFalse(writes, "Invalid input or failed save attempted an Azure write.")
                    self.assertEqual(after["config"], state["config"])
            return after

    def test_append_and_failures(self):
        base = {
            "config": {
                "AZURE_ENV_NAME": "test-env", "AZURE_SUBSCRIPTION_ID": "11111111-1111-1111-1111-111111111111",
                "AZURE_RESOURCE_GROUP": "rg-test", "VM_NAME": "vm-test",
                "VM_RDP_SOURCE": "192.0.2.20/32",
                "VM_RDP_ADDITIONAL_SOURCES": '["203.0.113.50/32"]',
            },
            "rules": [RULE, {**RULE, "name": "unrelated", "priority": 1100}],
            "calls": [],
        }
        expected = ["192.0.2.20/32", "198.51.100.10/32", CURRENT, "203.0.113.50/32"]
        for platform in ("bash", "pwsh"):
            with self.subTest(platform=platform, case="append-default-environment"):
                after = self.check_case(platform, copy.deepcopy(base), True, expected, False)
            with self.subTest(platform=platform, case="repeat-is-idempotent"):
                after["calls"] = []
                self.check_case(platform, after, True, expected)
            with self.subTest(platform=platform, case="create-single-source"):
                state = copy.deepcopy(base)
                state["rules"] = []
                del state["config"]["VM_RDP_ADDITIONAL_SOURCES"]
                state["config"]["VM_RDP_SOURCE"] = ""
                self.check_case(platform, state, True, [CURRENT])
            with self.subTest(platform=platform, case="normalize-and-preserve-cidr"):
                state = copy.deepcopy(base)
                state["rules"][0].pop("sourceAddressPrefix")
                state["rules"][0]["sourceAddressPrefixes"] = ["198.51.100.0/24", CURRENT.removesuffix("/32")]
                self.check_case(platform, state, True, ["192.0.2.20/32", "198.51.100.0/24", CURRENT, "203.0.113.50/32"])
            for source in ("*", "0.0.0.0/0", "198.51.100.1/0", "Internet", "::1", "256.1.1.1", "01.1.1.1", "1.1.1.1/33"):
                with self.subTest(platform=platform, case=f"invalid-existing-{source}"):
                    state = copy.deepcopy(base)
                    state["rules"][0]["sourceAddressPrefix"] = source
                    self.check_case(platform, state, False)
            for saved in ('["*"]', '["::1"]', '{"not":"an array"}', 'null', 'invalid-json'):
                with self.subTest(platform=platform, case=f"invalid-saved-{saved}"):
                    state = copy.deepcopy(base)
                    state["config"]["VM_RDP_ADDITIONAL_SOURCES"] = saved
                    self.check_case(platform, state, False)
            for overrides in ({"access": "Deny"}, {"destinationPortRange": "22"},
                              {"sourceApplicationSecurityGroups": [{"id": "test-asg"}]}):
                with self.subTest(platform=platform, case=f"incompatible-rule-{overrides}"):
                    state = copy.deepcopy(base)
                    state["rules"][0].update(overrides)
                    self.check_case(platform, state, False)
            with self.subTest(platform=platform, case="priority-conflict"):
                state = copy.deepcopy(base)
                state["rules"] = [{**RULE, "name": "conflicting-rule"}]
                self.check_case(platform, state, False)
            with self.subTest(platform=platform, case="missing-deployment-output"):
                state = copy.deepcopy(base)
                del state["config"]["VM_NAME"]
                self.check_case(platform, state, False)
            with self.subTest(platform=platform, case="lookup-failure"):
                self.check_case(platform, {**copy.deepcopy(base), "lookup_fails": True}, False)
            for failure in ("env-read", "rules-read", "env-save", "rule-write", "verify"):
                with self.subTest(platform=platform, case=failure):
                    self.check_case(platform, {**copy.deepcopy(base), "failure": failure}, False, expected)
            with self.subTest(platform=platform, case="verification-mismatch"):
                self.check_case(platform, {**copy.deepcopy(base), "mismatch": True}, False, expected)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "mock-cli":
        mock_cli(sys.argv[2], sys.argv[3:])
    else:
        unittest.main()
