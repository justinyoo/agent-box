"""Compile and check both azd templates without creating Azure resources."""

import base64
import gzip
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "agent-box" / "infra"
WORKSHOP = ROOT / "appmod-box" / "infra"
SHARED = ROOT / "shared"
ENV = {**os.environ, "AZURE_CORE_ONLY_SHOW_ERRORS": "false"}


def run(*args, env=None, succeeds=True):
    result = subprocess.run(
        args, cwd=ROOT, env=ENV if env is None else env, text=True, capture_output=True
    )
    if succeeds and result.returncode:
        raise AssertionError(f"{args[0]} failed:\n{result.stdout}\n{result.stderr}")
    if not succeeds and not result.returncode:
        raise AssertionError(f"{args[0]} unexpectedly succeeded.")
    return result


def compile_bicep(source, output):
    run("az", "bicep", "build", "--file", str(source), "--outfile", str(output))
    return json.loads(output.read_text())


def make_fake_az(binary):
    executable = binary / "az"
    executable.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "from pathlib import Path\n"
        "args = sys.argv[1:]\n"
        "if os.environ.get('AZ_TEST_LOG'):\n"
        "    with Path(os.environ['AZ_TEST_LOG']).open('a') as log: log.write(json.dumps(args) + '\\n')\n"
        "mode = os.environ.get('AZ_TEST_MODE', '')\n"
        "def value(name): return args[args.index(name) + 1]\n"
        "if args[:3] == ['vm', 'image', 'list']:\n"
        "    if mode == 'image-error': print('image API failed', file=sys.stderr); sys.exit(1)\n"
        "    if mode != 'missing-image':\n"
        "        print('\\t'.join([value('--publisher'), value('--offer'), value('--sku'), '1.2.3']))\n"
        "elif args[:2] == ['vm', 'list-skus']:\n"
        "    if mode == 'sku-error': print('SKU API failed', file=sys.stderr); sys.exit(1)\n"
        "    if mode != 'missing-sku':\n"
        "        zones = {'wrong-zone': '2', 'no-zones': '', 'unsorted-zones': '3,1,2',"
        " 'four-only': '4'}.get(mode, '1,2,3')\n"
        "        restricted = {'restricted-zone': '1', 'all-restricted': '1,2,3',"
        " 'invalid-zone-restriction': 'invalid'}.get(mode, '')\n"
        "        count = '1' if restricted or mode == 'unknown-zone-restriction' else '0'\n"
        "        known = '1' if restricted else '0'\n"
        "        print('\\t'.join([value('--size'), '1' if mode == 'location-restricted' else '0',"
        " zones, restricted, '1' if mode == 'unknown-restriction' else '0', count, known,"
        " 'eastus2,centralus' if mode == 'multiple-locations' else value('--location')]))\n"
        "elif args[:2] == ['vm', 'show']:\n"
        "    if mode == 'vm-error': print('VM lookup failed', file=sys.stderr); sys.exit(1)\n"
        "    print(os.environ.get('AZ_TEST_VM_LOCATION', 'eastus2') + '|' + os.environ.get('AZ_TEST_VM_ZONE', '2'))\n"
        "else: print('unexpected az command', file=sys.stderr); sys.exit(2)\n"
    )
    executable.chmod(0o755)


def make_fake_azd(directory):
    binary = directory / "bin"
    binary.mkdir()
    make_fake_az(binary)
    executable = binary / "azd"
    executable.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "from pathlib import Path\n"
        "args = sys.argv[1:]\n"
        "store_path = Path(os.environ['AZD_TEST_STORE'])\n"
        "store = json.loads(store_path.read_text()) if store_path.exists() else {}\n"
        "environment = args[args.index('--environment') + 1]\n"
        "values = store.setdefault(environment, {})\n"
        "if args[:2] == ['env', 'get-value']:\n"
        "    value = values.get(args[2])\n"
        "    if value is None: sys.exit(1)\n"
        "    print(value)\n"
        "elif args[:3] == ['env', 'config', 'get']:\n"
        "    value = values.get('config:' + args[3])\n"
        "    if value is None: sys.exit(1)\n"
        "    print(json.dumps(value))\n"
        "elif args[:2] == ['env', 'set']:\n"
        "    end = args.index('--environment')\n"
        "    entries = args[2:end]\n"
        "    if any('=' not in entry for entry in entries): sys.exit(2)\n"
        "    values.update(dict(entry.split('=', 1) for entry in entries))\n"
        "    store[environment] = values\n"
        "    store_path.write_text(json.dumps(store))\n"
        "else:\n"
        "    sys.exit(2)\n"
    )
    executable.chmod(0o755)
    return binary


def invoke_hook(platform, env):
    template = env.get("DEPLOYMENT_TEMPLATE", "agent-box")
    project = ROOT / ("appmod-box" if template == "app-modernisation-workshop" else "agent-box")
    if platform == "posix":
        args = ["bash", str(project / "infra/scripts/preprovision.sh")]
    else:
        args = [
            "pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
            str(project / "infra/scripts/preprovision.ps1"),
        ]
    return subprocess.run(args, cwd=project, env=env, text=True, capture_output=True)


def check_hooks():
    with tempfile.TemporaryDirectory(prefix="agentbox-hooks-") as temporary:
        directory = Path(temporary)
        binary = make_fake_azd(directory)
        for platform in ("posix", "windows"):
            store_path = directory / f"{platform}.json"
            base_env = {
                **ENV,
                "PATH": str(binary) + os.pathsep + ENV["PATH"],
                "AZD_TEST_STORE": str(store_path),
                "AZURE_ENV_NAME": f"validation-{platform}",
                "AZURE_LOCATION": "eastus2",
                "AZURE_SUBSCRIPTION_ID": "test-subscription",
                "AZD_NON_INTERACTIVE": "true",
                "APP_MOD_VM_SIZE": "",
                "APP_MOD_OS_DISK_SIZE_GB": "",
                "APP_MOD_AUTO_SHUTDOWN_ENABLED": "",
                "APP_MOD_AUTO_SHUTDOWN_TIME": "",
            }
            base_env.pop("VM_ZONE", None)
            base_env.pop("AZURE_VM_ID", None)
            base_env.pop("CONFIRM_WINDOWS_CLIENT_LICENSE", None)

            no_region = invoke_hook(platform, {
                **base_env, "DEPLOYMENT_TEMPLATE": "agent-box",
                "MAI_FOUNDRY_REGION": "",
            })
            assert no_region.returncode != 0
            assert "MAI_FOUNDRY_REGION" in no_region.stdout + no_region.stderr
            assert not store_path.exists()

            invalid_region = invoke_hook(platform, {
                **base_env, "DEPLOYMENT_TEMPLATE": "agent-box",
                "MAI_FOUNDRY_REGION": "eastus2",
            })
            assert invalid_region.returncode != 0
            assert "MAI_FOUNDRY_REGION must be one of" in invalid_region.stdout + invalid_region.stderr
            assert not store_path.exists()

            selected = {
                **base_env,
                "DEPLOYMENT_TEMPLATE": "agent-box",
                "MAI_FOUNDRY_REGION": "eastus",
                "MAI_IMAGE_CAPACITY": "2",
            }
            result = invoke_hook(platform, selected)
            assert result.returncode == 0, result.stdout + result.stderr
            state = json.loads(store_path.read_text())[base_env["AZURE_ENV_NAME"]]
            assert "DEPLOYMENT_TEMPLATE" not in state and "DEPLOYMENT_TEMPLATE_LOCK" not in state
            assert "CONFIRM_WINDOWS_CLIENT_LICENSE" not in state
            assert state["MAI_FOUNDRY_REGION"] == "eastus"
            assert state["MAI_IMAGE_CAPACITY"] == "2"
            assert state["VM_ZONE"] == "1"
            assert "APP_MOD_VM_SIZE" not in state

            for mode, message in (
                ("missing-image", "VM image"),
                ("image-error", "Could not query VM images"),
                ("missing-sku", "VM size"),
                ("sku-error", "Could not query VM sizes"),
                ("location-restricted", "restricted"),
                ("unknown-restriction", "restricted"),
                ("no-zones", "No availability zones"),
                ("all-restricted", "No unrestricted availability zones"),
                ("unknown-zone-restriction", "incomplete zone restrictions"),
                ("invalid-zone-restriction", "invalid zone restriction"),
                ("multiple-locations", "unexpected zone locations"),
            ):
                failed_env = {
                    **selected, "AZURE_ENV_NAME": f"{platform}-{mode}", "AZ_TEST_MODE": mode,
                }
                result = invoke_hook(platform, failed_env)
                assert result.returncode != 0 and message in result.stdout + result.stderr, result.stdout + result.stderr
                assert failed_env["AZURE_ENV_NAME"] not in json.loads(store_path.read_text())
            unsupported = invoke_hook(platform, {
                **selected, "AZURE_ENV_NAME": f"{platform}-unsupported", "AZURE_LOCATION": "malaysiacentral",
            })
            assert unsupported.returncode != 0 and "Bastion Developer" in unsupported.stdout + unsupported.stderr
            assert f"{platform}-unsupported" not in json.loads(store_path.read_text())

            log_path = directory / f"{platform}-az.log"
            custom_agent = {
                **selected, "AZURE_ENV_NAME": f"{platform}-custom-agent",
                "AZURE_LOCATION": "koreacentral", "AZ_TEST_LOG": str(log_path),
                "VM_SIZE": "Standard_D8s_v5", "VM_ZONE": "2",
                "VM_IMAGE_PUBLISHER": "CustomPublisher", "VM_IMAGE_OFFER": "CustomOffer",
                "VM_IMAGE_SKU": "CustomSku", "VM_IMAGE_VERSION": "1.2.3",
            }
            result = invoke_hook(platform, custom_agent)
            assert result.returncode == 0, result.stdout + result.stderr
            assert json.loads(store_path.read_text())[custom_agent["AZURE_ENV_NAME"]]["VM_ZONE"] == "2"
            calls = [json.loads(line) for line in log_path.read_text().splitlines()]
            assert len(calls) == 2
            assert all(call[call.index("--subscription") + 1] == "test-subscription" for call in calls)
            assert calls[0][calls[0].index("--publisher") + 1] == "CustomPublisher"
            assert calls[0][calls[0].index("--sku") + 1] == "CustomSku"
            assert calls[1][calls[1].index("--size") + 1] == "Standard_D8s_v5"
            persisted_zone = invoke_hook(platform, {
                **selected, "AZURE_ENV_NAME": custom_agent["AZURE_ENV_NAME"], "AZ_TEST_MODE": "unsorted-zones",
            })
            assert persisted_zone.returncode == 0, persisted_zone.stdout + persisted_zone.stderr
            assert json.loads(store_path.read_text())[custom_agent["AZURE_ENV_NAME"]]["VM_ZONE"] == "2"

            for mode, expected_zone in (
                ("wrong-zone", "2"), ("restricted-zone", "2"),
                ("unsorted-zones", "1"), ("four-only", "4"),
            ):
                name = f"{platform}-automatic-{mode}"
                result = invoke_hook(platform, {
                    **selected, "AZURE_ENV_NAME": name, "AZURE_LOCATION": "koreacentral",
                    "AZ_TEST_MODE": mode,
                })
                assert result.returncode == 0, result.stdout + result.stderr
                assert json.loads(store_path.read_text())[name]["VM_ZONE"] == expected_zone

            for mode, expected_zone in (("restricted-zone", "2"), ("no-zones", None), ("all-restricted", None)):
                name = f"{platform}-germany-{mode}"
                result = invoke_hook(platform, {
                    **selected, "AZURE_ENV_NAME": name, "AZURE_LOCATION": "germanywestcentral",
                    "AZ_TEST_MODE": mode,
                })
                if expected_zone:
                    assert result.returncode == 0, result.stdout + result.stderr
                    assert json.loads(store_path.read_text())[name]["VM_ZONE"] == expected_zone
                else:
                    assert result.returncode != 0 and "availability zones" in result.stdout + result.stderr
                    assert name not in json.loads(store_path.read_text())

            korea_override = invoke_hook(platform, {
                **selected, "AZURE_ENV_NAME": f"{platform}-korea-override",
                "AZURE_LOCATION": "koreacentral", "VM_ZONE": "1", "AZ_TEST_MODE": "wrong-zone",
            })
            assert korea_override.returncode != 0 and "zone 1" in korea_override.stdout + korea_override.stderr
            restricted_override = invoke_hook(platform, {
                **selected, "AZURE_ENV_NAME": f"{platform}-restricted-override",
                "VM_ZONE": "1", "AZ_TEST_MODE": "restricted-zone",
            })
            assert restricted_override.returncode != 0 and "zone 1" in restricted_override.stdout + restricted_override.stderr
            empty_zone = invoke_hook(platform, {
                **selected, "AZURE_ENV_NAME": f"{platform}-empty-zone", "VM_ZONE": "", "AZ_TEST_MODE": "no-zones",
            })
            assert empty_zone.returncode != 0 and "No availability zones" in empty_zone.stdout + empty_zone.stderr

            invalid_zone = invoke_hook(platform, {
                **selected, "AZURE_ENV_NAME": f"{platform}-invalid-zone", "VM_ZONE": "5",
            })
            assert invalid_zone.returncode != 0 and "VM_ZONE" in invalid_zone.stdout + invalid_zone.stderr

            existing_name = f"{platform}-existing-vm"
            saved = json.loads(store_path.read_text())
            saved[existing_name] = {"AZURE_VM_ID": "/subscriptions/test-subscription/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm"}
            store_path.write_text(json.dumps(saved))
            existing_env = {**selected, "AZURE_ENV_NAME": existing_name}
            result = invoke_hook(platform, existing_env)
            assert result.returncode == 0, result.stdout + result.stderr
            assert json.loads(store_path.read_text())[existing_name]["VM_ZONE"] == "2"
            cleared = invoke_hook(platform, {**existing_env, "VM_ZONE": ""})
            assert cleared.returncode == 0, cleared.stdout + cleared.stderr
            assert json.loads(store_path.read_text())[existing_name]["VM_ZONE"] == "2"
            mismatch = invoke_hook(platform, {**existing_env, "VM_ZONE": "1"})
            assert mismatch.returncode != 0 and "existing VM zone 2" in mismatch.stdout + mismatch.stderr
            assert json.loads(store_path.read_text())[existing_name]["VM_ZONE"] == "2"
            lookup_failed = invoke_hook(platform, {**existing_env, "AZ_TEST_MODE": "vm-error"})
            assert lookup_failed.returncode != 0 and "Could not verify" in lookup_failed.stdout + lookup_failed.stderr
            wrong_region = invoke_hook(platform, {**existing_env, "AZ_TEST_VM_LOCATION": "centralus"})
            assert wrong_region.returncode != 0 and "different region" in wrong_region.stdout + wrong_region.stderr
            wrong_subscription = invoke_hook(platform, {**existing_env, "AZURE_SUBSCRIPTION_ID": "other-subscription"})
            assert wrong_subscription.returncode != 0 and "selected subscription" in wrong_subscription.stdout + wrong_subscription.stderr
            no_existing_zone = invoke_hook(platform, {**existing_env, "AZ_TEST_VM_ZONE": ""})
            assert no_existing_zone.returncode != 0 and "previously deployed VM" in no_existing_zone.stdout + no_existing_zone.stderr

            rerun = invoke_hook(platform, base_env)
            assert rerun.returncode == 0, rerun.stdout + rerun.stderr
            assert json.loads(store_path.read_text())[base_env["AZURE_ENV_NAME"]]["MAI_FOUNDRY_REGION"] == "eastus"
            bad_capacity = invoke_hook(platform, {
                **base_env, "MAI_IMAGE_CAPACITY": "0",
            })
            assert bad_capacity.returncode != 0
            assert "positive whole number" in bad_capacity.stdout + bad_capacity.stderr

            config_name = f"config-region-{platform}"
            saved = json.loads(store_path.read_text())
            saved[config_name] = {"config:infra.parameters.maiFoundryRegion": "westeurope"}
            store_path.write_text(json.dumps(saved))
            configured = invoke_hook(platform, {
                **selected, "AZURE_ENV_NAME": config_name, "MAI_FOUNDRY_REGION": "",
            })
            assert configured.returncode == 0, configured.stdout + configured.stderr
            assert json.loads(store_path.read_text())[config_name]["MAI_FOUNDRY_REGION"] == "westeurope"
            saved = json.loads(store_path.read_text())
            saved[config_name]["MAI_FOUNDRY_REGION"] = ""
            saved[config_name]["config:infra.parameters.maiFoundryRegion"] = "eastus2"
            store_path.write_text(json.dumps(saved))
            invalid_config = invoke_hook(platform, {
                **selected, "AZURE_ENV_NAME": config_name, "MAI_FOUNDRY_REGION": "",
            })
            assert invalid_config.returncode != 0 and "one of" in invalid_config.stdout + invalid_config.stderr

            workshop_env = {
                **base_env,
                "AZURE_ENV_NAME": f"workshop-{platform}",
                "DEPLOYMENT_TEMPLATE": "app-modernisation-workshop",
            }
            workshop = invoke_hook(platform, workshop_env)
            assert workshop.returncode == 0, workshop.stdout + workshop.stderr
            workshop_state = json.loads(store_path.read_text())[workshop_env["AZURE_ENV_NAME"]]
            assert "DEPLOYMENT_TEMPLATE" not in workshop_state and "DEPLOYMENT_TEMPLATE_LOCK" not in workshop_state
            assert "MAI_FOUNDRY_REGION" not in workshop_state
            assert workshop_state["APP_MOD_VM_SIZE"] == "Standard_D8s_v5"
            assert workshop_state["APP_MOD_OS_DISK_SIZE_GB"] == "256"
            assert workshop_state["APP_MOD_AUTO_SHUTDOWN_ENABLED"] == "true"
            assert workshop_state["APP_MOD_AUTO_SHUTDOWN_TIME"] == "0000"

            workshop_log = directory / f"{platform}-workshop-az.log"
            workshop_without_zone = invoke_hook(platform, {
                **workshop_env, "AZURE_ENV_NAME": f"workshop-zone-{platform}",
                "APP_MOD_VM_SIZE": "Standard_D16s_v5", "AZ_TEST_MODE": "wrong-zone",
                "AZ_TEST_LOG": str(workshop_log),
            })
            assert workshop_without_zone.returncode == 0, workshop_without_zone.stdout + workshop_without_zone.stderr
            workshop_calls = [json.loads(line) for line in workshop_log.read_text().splitlines()]
            assert workshop_calls[1][workshop_calls[1].index("--size") + 1] == "Standard_D16s_v5"

            custom_settings = {
                "APP_MOD_VM_SIZE": "Standard_D16s_v5",
                "APP_MOD_OS_DISK_SIZE_GB": "512",
                "APP_MOD_AUTO_SHUTDOWN_ENABLED": "false",
                "APP_MOD_AUTO_SHUTDOWN_TIME": "2100",
            }
            saved = json.loads(store_path.read_text())
            saved[workshop_env["AZURE_ENV_NAME"]].update(custom_settings)
            store_path.write_text(json.dumps(saved))
            result = invoke_hook(platform, workshop_env)
            assert result.returncode == 0, result.stdout + result.stderr
            state = json.loads(store_path.read_text())[workshop_env["AZURE_ENV_NAME"]]
            assert all(state[key] == value for key, value in custom_settings.items())

            result = invoke_hook(platform, {**workshop_env, "APP_MOD_AUTO_SHUTDOWN_TIME": "2359"})
            assert result.returncode == 0, result.stdout + result.stderr
            state = json.loads(store_path.read_text())[workshop_env["AZURE_ENV_NAME"]]
            assert state["APP_MOD_AUTO_SHUTDOWN_TIME"] == "2359"
            for invalid_time in ("2400", "2360", "090", "12:00", "abcd"):
                result = invoke_hook(platform, {**workshop_env, "APP_MOD_AUTO_SHUTDOWN_TIME": invalid_time})
                assert result.returncode != 0, result.stdout + result.stderr
                assert "APP_MOD_AUTO_SHUTDOWN_TIME" in result.stdout + result.stderr
                assert json.loads(store_path.read_text())[workshop_env["AZURE_ENV_NAME"]]["APP_MOD_AUTO_SHUTDOWN_TIME"] == "2359"

            existing_name = f"existing-{platform}"
            saved = json.loads(store_path.read_text())
            saved[existing_name] = {
                "AZURE_RESOURCE_GROUP": "existing-rg",
                "VM_NAME": "existing-vm",
                "VM_PUBLIC_IP": "192.0.2.1",
                "FOUNDRY_RESOURCES": "[]",
            }
            store_path.write_text(json.dumps(saved))
            result = invoke_hook(platform, {**selected, "AZURE_ENV_NAME": existing_name})
            assert result.returncode == 0, result.stdout + result.stderr
            state = json.loads(store_path.read_text())[existing_name]
            assert state["MAI_FOUNDRY_REGION"] == "eastus"

    print("Both project hooks passed configuration, validation, and payload checks.")


def check_interactive_command_logging():
    if os.name == "nt":
        print("Skipped pseudo-terminal command logging test on Windows.")
        return

    import pty

    with tempfile.TemporaryDirectory(prefix="appmod-log-interactive-") as directory:
        root = Path(directory)
        child = root / "prompt.py"
        child.write_text(
            'print("PROMPT FOR INPUT", flush=True)\n'
            'value = input()\n'
            'print("ANSWER=" + value, flush=True)\n'
        )
        runner = root / "runner.ps1"
        runner.write_text(
            "param($Installer, $Child, $LogDirectory, $Python)\n"
            ". $Installer\n"
            "$result = Invoke-LoggedProcess -Executable $Python -Arguments @('-u', $Child) -LogDirectory $LogDirectory -StreamOutput\n"
            "if ($result.ExitCode -ne 0) { exit 1 }\n"
        )
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(
                ["pwsh", "-NoLogo", "-NoProfile", "-File", str(runner),
                 str(WORKSHOP.parent / "scripts/install-vm-tools.ps1"), str(child), str(root), sys.executable],
                stdin=slave, stdout=slave, stderr=slave,
            )
        finally:
            os.close(slave)
        output = b""
        sent = False
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(master, 8192)
                    except OSError:
                        break
                    if not chunk:
                        break
                    output += chunk
                    if b"PROMPT FOR INPUT" in output and not sent:
                        os.write(master, b"yes\n")
                        sent = True
                elif process.poll() is not None:
                    break
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired as exc:
                raise AssertionError(f"Interactive command timed out: {output!r}") from exc
            logs = list(root.glob("command-*.stdout.log"))
            assert process.returncode == 0 and sent and b"ANSWER=yes" in output, output
            assert len(logs) == 1 and "ANSWER=yes" in logs[0].read_text()
        finally:
            os.close(master)
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


def check_hook_colors():
    if os.name == "nt":
        print("Skipped pseudo-terminal hook color tests on Windows.")
        return

    import pty

    base_env = {**ENV, "TERM": "xterm", "AZURE_RESOURCE_GROUP": "rg-test",
                "AZURE_VM_NAME": "vm-test", "AZURE_VM_ADMIN_USERNAME": "testuser"}
    base_env.pop("NO_COLOR", None)
    base_env.pop("CI", None)

    def terminal_output(command, env, expected_exit=0):
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave, env=env)
        finally:
            os.close(slave)
        output = b""
        try:
            deadline = time.monotonic() + 10
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
                    raise AssertionError(f"Hook color test timed out: {output!r}")
                try:
                    chunk = os.read(master, 8192)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
            assert process.wait(timeout=10) == expected_exit, output
        finally:
            os.close(master)
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        return output

    cases = (
        (["bash", "-c", 'source "$1"; for tag in PASS FAIL WARN MANUAL INFO; do write_hook_message "[$tag] fixture"; done',
          "--", str(SHARED / "hook-messages.sh")]),
        (["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
          f". '{SHARED / 'hook-messages.ps1'}'; "
          "foreach ($tag in @('PASS','FAIL','WARN','MANUAL','INFO')) { Write-HookMessage \"[$tag] fixture\" }"]),
    )
    expected = {"PASS": 32, "FAIL": 31, "WARN": 33, "MANUAL": 36, "INFO": 34}
    for command in cases:
        output = terminal_output(command, base_env)
        for tag, color in expected.items():
            assert f"\x1b[{color}m[{tag}] fixture".encode() in output, output
        redirected = subprocess.run(command, env=base_env, capture_output=True, check=True).stdout
        assert b"\x1b" not in redirected, redirected
        for disabled in ({"NO_COLOR": "1"}, {"CI": "true"}, {"TERM": "dumb"}):
            output = terminal_output(command, {**base_env, **disabled})
            for tag, color in expected.items():
                assert f"\x1b[{color}m[{tag}] fixture".encode() not in output, output
                assert f"[{tag}] fixture".encode() in output, output

    for project in (AGENT, WORKSHOP):
        for shell, name in ((["bash"], "postprovision.sh"),
                            (["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File"], "postprovision.ps1")):
            output = terminal_output([*shell, str(project / "scripts" / name)], base_env)
            assert b"\x1b[34m[INFO] Resource group: rg-test" in output, output
            assert b"\x1b[36m[MANUAL] Connect:" in output, output
        failure = subprocess.run(["bash", str(project / "scripts/preprovision.sh")],
                                 env={**base_env, "AZURE_ENV_NAME": ""}, capture_output=True)
        assert failure.returncode != 0 and b"[FAIL]" in failure.stderr and b"\x1b" not in failure.stderr
        failure = terminal_output(["bash", str(project / "scripts/preprovision.sh")],
                                  {**base_env, "AZURE_ENV_NAME": ""}, expected_exit=1)
        assert b"\x1b[31m[FAIL] azd did not provide AZURE_ENV_NAME." in failure, failure
        failure = terminal_output(["bash", str(project / "scripts/postprovision.sh")],
                                  {**base_env, "AZURE_VM_NAME": ""}, expected_exit=1)
        assert b"\x1b[31m[FAIL] AZURE_VM_NAME" in failure, failure
        for name, env in (("preprovision.ps1", {**base_env, "AZURE_ENV_NAME": ""}),
                          ("postprovision.ps1", {**base_env, "AZURE_VM_NAME": ""})):
            failure = subprocess.run(["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
                                      str(project / "scripts" / name)], env=env, capture_output=True)
            assert failure.returncode != 0 and b"[FAIL]" in failure.stderr, failure.stderr
    print("Hook status colors and terminal opt-outs passed.")


def check_interactive_region_selection():
    if os.name == "nt":
        print("Skipped pseudo-terminal region selection tests on Windows.")
        return

    import pty
    import fcntl
    import struct
    import termios

    def invoke_interactive(platform, env, selection):
        args = (
            ["bash", str(AGENT / "scripts/preprovision.sh")]
            if platform == "posix" else
            ["pwsh", "-NoLogo", "-NoProfile", "-File", str(AGENT / "scripts/preprovision.ps1")]
        )
        pid, terminal = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            os.chdir(ROOT / "agent-box")
            os.execvpe(args[0], args, env)

        output = b""
        selection_sent = False
        deadline = time.monotonic() + 45
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([terminal], [], [], 1)
                if not ready:
                    continue
                try:
                    chunk = os.read(terminal, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                output += chunk
                if not selection_sent and b"Selection [1-4 or region]" in output:
                    time.sleep(0.3)
                    os.write(terminal, (selection + "\n").encode())
                    selection_sent = True
            else:
                os.kill(pid, 9)
                raise AssertionError(f"{platform} region prompt timed out:\n{output.decode(errors='replace')}")
        finally:
            os.close(terminal)
            _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), output.decode(errors="replace")

    cases = (
        ("1", "eastus"),
        ("2", "swedencentral"),
        ("3", "westeurope"),
        ("4", "westus"),
        ("eastus", "eastus"),
        ("southindia", None),
        ("eastus2", None),
        ("5", None),
        ("", None),
        ("bad-region", None),
    )
    with tempfile.TemporaryDirectory(prefix="agentbox-region-") as temporary:
        directory = Path(temporary)
        binary = make_fake_azd(directory)
        for platform in ("posix", "windows"):
            for index, (selection, expected) in enumerate(cases):
                store = directory / f"{platform}-{index}.json"
                env = {
                    **ENV,
                    "PATH": str(binary) + os.pathsep + ENV["PATH"],
                    "AZD_TEST_STORE": str(store),
                    "AZURE_ENV_NAME": f"interactive-{platform}-{index}",
                    "AZURE_LOCATION": "eastus2",
                    "AZURE_SUBSCRIPTION_ID": "test-subscription",
                    "AZD_NON_INTERACTIVE": "false",
                    "DEPLOYMENT_TEMPLATE": "agent-box",
                    "TERM": "dumb",
                }
                for name in ("CI", "MAI_FOUNDRY_REGION"):
                    env.pop(name, None)
                code, output = invoke_interactive(platform, env, selection)
                assert "Choose the Foundry region" in output, output
                if expected is None:
                    assert code != 0 and not store.exists(), output
                else:
                    assert code == 0, output
                    saved = json.loads(store.read_text())[env["AZURE_ENV_NAME"]]
                    assert saved["MAI_FOUNDRY_REGION"] == expected, output

    print("Both interactive hooks passed Foundry region menu and invalid input checks.")


def check_real_azd_hooks():
    with tempfile.TemporaryDirectory(prefix="agentbox-azd-") as temporary:
        work = Path(temporary)
        for name in ("agent-box", "appmod-box", "shared"):
            shutil.copytree(ROOT / name, work / name, ignore=shutil.ignore_patterns(".generated", ".azure"))
        binary = work / "bin"
        binary.mkdir()
        make_fake_az(binary)
        base_env = os.environ.copy()
        for name in (
            "AZURE_ENV_NAME", "DEPLOYMENT_TEMPLATE", "CONFIRM_WINDOWS_CLIENT_LICENSE",
            "MAI_FOUNDRY_REGION", "MAI_IMAGE_CAPACITY", "AZD_NON_INTERACTIVE",
            "AZURE_DEV_USER_AGENT", "CI", "APP_MOD_VM_SIZE", "APP_MOD_OS_DISK_SIZE_GB",
            "APP_MOD_AUTO_SHUTDOWN_ENABLED", "APP_MOD_AUTO_SHUTDOWN_TIME",
            "VM_ZONE", "AZURE_VM_ID",
        ):
            base_env.pop(name, None)
        base_env["AZURE_DEV_USER_AGENT"] = "microsoft_foundry_skill"
        base_env["AZD_NON_INTERACTIVE"] = "true"
        base_env["PATH"] = str(binary) + os.pathsep + base_env["PATH"]

        def azd(project, *args, **overrides):
            return subprocess.run(
                ["azd", *args], cwd=work / project, env={**base_env, **overrides},
                text=True, capture_output=True,
            )

        for project in ("agent-box", "appmod-box"):
            for platform in ("posix", "windows"):
                environment = f"smoke-{platform}"
                created = azd(project, "env", "new", environment, "--location", "eastus2", "--subscription",
                              "00000000-0000-0000-0000-000000000001", "--no-prompt")
                assert created.returncode == 0, created.stdout + created.stderr
                if project == "agent-box":
                    values = ["MAI_FOUNDRY_REGION=eastus"]
                else:
                    values = ["VM_ADMIN_USERNAME=customworkshop", "APP_MOD_VM_SIZE=Standard_D16s_v5", "APP_MOD_OS_DISK_SIZE_GB=512",
                              "APP_MOD_AUTO_SHUTDOWN_ENABLED=false", "APP_MOD_AUTO_SHUTDOWN_TIME=2100"]
                configured = azd(project, "env", "set", *values, "--environment", environment, "--no-prompt")
                assert configured.returncode == 0, configured.stdout + configured.stderr
                result = azd(project, "hooks", "run", "preprovision", "--platform", platform,
                             "--environment", environment, "--no-prompt")
                assert result.returncode == 0, result.stdout + result.stderr
                assert "Windows client" not in result.stdout + result.stderr
                missing_license = azd(project, "env", "get-value", "CONFIRM_WINDOWS_CLIENT_LICENSE",
                                      "--environment", environment, "--no-prompt")
                assert missing_license.returncode != 0
                missing_config = azd(project, "env", "config", "get",
                                    "infra.parameters.confirmWindowsClientLicense",
                                    "--environment", environment, "--no-prompt")
                assert missing_config.returncode != 0
                configured_license = azd(project, "env", "config", "set",
                                         "infra.parameters.confirmWindowsClientLicense", "true",
                                         "--environment", environment, "--no-prompt")
                assert configured_license.returncode == 0, configured_license.stderr
                stored_license = azd(project, "env", "config", "get",
                                     "infra.parameters.confirmWindowsClientLicense",
                                     "--environment", environment, "--no-prompt")
                assert stored_license.returncode == 0 and json.loads(stored_license.stdout) is True
                for entry in values:
                    name, value = entry.split("=", 1)
                    persisted = azd(project, "env", "get-value", name, "--environment", environment, "--no-prompt")
                    assert persisted.returncode == 0 and persisted.stdout.strip() == value, persisted.stderr
                if project == "agent-box":
                    persisted = azd(project, "env", "get-value", "VM_ZONE", "--environment", environment, "--no-prompt")
                    assert persisted.returncode == 0 and persisted.stdout.strip() == "1", persisted.stderr
                payload_file = work / project / "infra/.generated/payload.json"
                payload = json.loads(payload_file.read_text())["content"]
                parts = []
                for part in range(1, 4):
                    persisted = azd(project, "env", "get-value", f"VM_SCRIPT_PAYLOAD_{part}",
                                    "--environment", environment, "--no-prompt")
                    assert persisted.returncode == 0, persisted.stderr
                    parts.append(persisted.stdout.strip())
                assert all(len(part) <= 30000 for part in parts)
                assert "".join(parts) == payload
                unset = azd(project, "env", "get-value", "DEPLOYMENT_TEMPLATE", "--environment", environment,
                            "--no-prompt")
                assert unset.returncode != 0

        project = "agent-box"
        environment = "smoke-config-region"
        created = azd(project, "env", "new", environment, "--location", "eastus2", "--subscription",
                      "00000000-0000-0000-0000-000000000001", "--no-prompt")
        assert created.returncode == 0, created.stdout + created.stderr
        configured = azd(project, "env", "config", "set", "infra.parameters.maiFoundryRegion", "westeurope",
                         "--environment", environment, "--no-prompt")
        assert configured.returncode == 0, configured.stdout + configured.stderr
        for platform in ("posix", "windows"):
            result = azd(project, "hooks", "run", "preprovision", "--platform", platform,
                         "--environment", environment, "--no-prompt")
            assert result.returncode == 0, result.stdout + result.stderr
            persisted = azd(project, "env", "get-value", "MAI_FOUNDRY_REGION",
                            "--environment", environment, "--no-prompt")
            assert persisted.returncode == 0 and persisted.stdout.strip() == "westeurope", persisted.stderr
            removed = azd(project, "env", "set", "MAI_FOUNDRY_REGION=",
                          "--environment", environment, "--no-prompt")
            assert removed.returncode == 0, removed.stdout + removed.stderr

    print("Both independent azd projects passed POSIX and PowerShell hooks without Azure deployment.")


def check_payload(path, expected_sources):
    payload = json.loads(path.read_text())
    assert set(payload) == {"content"}
    assert len(payload["content"]) <= 90000
    expanded = json.loads(gzip.decompress(base64.b64decode(payload["content"])))
    assert expanded["schemaVersion"] == 1
    files = {item["name"]: base64.b64decode(item["content"]) for item in expanded["files"]}
    assert set(files) == set(expected_sources)
    for name, source in expected_sources.items():
        assert files[name] == source.read_bytes(), f"Packaged file differs from source: {name}"


def check_packaging():
    run("bash", str(AGENT / "scripts/package-user-scripts.sh"))
    run("bash", str(WORKSHOP / "scripts/package-user-scripts.sh"))
    check_payload(
        AGENT / ".generated/payload.json",
        {"install-vm-tools.ps1": AGENT.parent / "scripts/install-vm-tools.ps1"},
    )
    workshop_sources = {
        "install-vm-tools.ps1": WORKSHOP.parent / "scripts/install-vm-tools.ps1",
        "buildtools.vsconfig": WORKSHOP.parent / "scripts/buildtools.vsconfig",
    }
    check_payload(WORKSHOP / ".generated/payload.json", workshop_sources)
    with tempfile.TemporaryDirectory(prefix="vm-package-test-") as directory:
        fixture = Path(directory)
        shutil.copytree(SHARED, fixture / "shared")
        for project in (AGENT.parent, WORKSHOP.parent):
            root = fixture / project.name
            shutil.copytree(project / "scripts", root / "scripts")
            scripts = root / "infra" / "scripts"
            scripts.mkdir(parents=True)
            shutil.copy2(project / "infra/scripts/package-user-scripts.ps1", scripts)
            target = root / "custom output" / "payload.json"
            builder = scripts / "package-user-scripts.ps1"
            command = ("pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(builder), "-OutputPath", str(target))
            run(*command)
            run(*command)
            sources = {path.name: path for path in (root / "scripts").iterdir() if path.is_file()}
            check_payload(target, sources)
            original = target.read_bytes()
            (root / "scripts/install-vm-tools.ps1").unlink()
            failure = run(*command, succeeds=False)
            assert "Missing payload source" in failure.stderr
            assert target.read_bytes() == original
            assert not list(target.parent.glob("*.tmp"))
    print("Agent Box and workshop payloads passed size and byte-integrity checks.")


def check_templates(directory):
    outputs = {}
    for name, path in (
        ("agent-box", AGENT / "main.bicep"),
        ("workstation", AGENT / "modules/workstation.bicep"),
        ("user-scripts", AGENT / "modules/user-scripts.bicep"),
        ("foundry", AGENT / "modules/foundry.bicep"),
        ("workshop", WORKSHOP / "main.bicep"),
    ):
        outputs[name] = compile_bicep(path, directory / f"{name}.json")

    agent_main = outputs["agent-box"]
    assert set(agent_main["outputs"]) == {
        "AZURE_RESOURCE_GROUP", "AZURE_VM_NAME", "AZURE_VM_ID",
        "AZURE_VM_ADMIN_USERNAME", "AZURE_BASTION_NAME", "AZURE_SCRIPT_DELIVERY",
        "FOUNDRY_ACCOUNT_NAME", "FOUNDRY_ACCOUNT_ID", "FOUNDRY_PROJECT_NAME",
        "FOUNDRY_PROJECT_ENDPOINT", "MAI_IMAGE_ENDPOINT", "MAI_IMAGE_DEPLOYMENT_NAME",
        "AZURE_SPEECH_ENDPOINT", "AZURE_SPEECH_REGION", "MAI_VOICE_MODEL", "MAI_TRANSCRIBE_MODEL",
    }
    for template_name, template_dir in (("agent-box", AGENT), ("workshop", WORKSHOP)):
        bindings = json.loads((template_dir / "main.parameters.json").read_text())["parameters"]
        assert set(bindings) == set(outputs[template_name]["parameters"]) - {"confirmWindowsClientLicense"}
        assert outputs[template_name]["parameters"]["environmentName"]["maxLength"] == 32
        license_parameter = outputs[template_name]["parameters"]["confirmWindowsClientLicense"]
        assert license_parameter["type"].lower() == "bool"
        assert license_parameter["allowedValues"] == [True]
        assert "defaultValue" not in license_parameter
        for parameter, binding in bindings.items():
            assert binding["value"].startswith("${") and binding["value"].endswith("}"), parameter
        assert "deploymentTemplate" not in bindings
    assert not (ROOT / "azure.yaml").exists()
    assert "namePrefix" not in agent_main["parameters"]
    documented_regions = {
        line for line in (SHARED / "bastion-developer-regions.txt").read_text().splitlines()
        if line and not line.startswith("#")
    }
    expected_regions = {
        "agent-box": {
            "australiasoutheast", "brazilsouth", "centralus", "eastasia", "eastus2",
            "germanywestcentral", "japanwest", "koreacentral", "koreasouth",
            "northcentralus", "swedencentral", "uksouth", "westeurope", "westus",
        },
        "workshop": documented_regions - {"centraluseuap", "eastus2euap"},
    }
    for template_name in ("agent-box", "workshop"):
        regions = outputs[template_name]["parameters"]["location"]["allowedValues"]
        assert len(regions) == len(set(regions))
        assert set(regions) == expected_regions[template_name]
        assert "koreacentral" in regions and "malaysiacentral" not in regions
        modules = outputs[template_name]["resources"]
        script_module = next(module for module in modules if module["name"] in (
            "agent-box-user-scripts", "user-scripts"
        ))
        assert script_module["properties"]["parameters"]["scriptPayload"]["value"] == (
            "[format('{0}{1}{2}', parameters('scriptPayloadPart1'), "
            "parameters('scriptPayloadPart2'), parameters('scriptPayloadPart3'))]"
        )
        script_parameter = script_module["properties"]["template"]["parameters"]["scriptPayload"]
        assert script_parameter["minLength"] == 1 and script_parameter["maxLength"] == 90000
    assert agent_main["parameters"]["zone"]["defaultValue"] == ""
    assert set(agent_main["parameters"]["zone"]["allowedValues"]) == {"", "1", "2", "3", "4"}
    assert agent_main["parameters"]["adminPassword"]["type"].lower() == "securestring"
    assert agent_main["parameters"]["adminUsername"]["defaultValue"] == "agentboxuser"
    assert agent_main["parameters"]["adminUsername"]["minLength"] == 1
    assert agent_main["parameters"]["adminUsername"]["maxLength"] == 20
    assert agent_main["outputs"]["AZURE_VM_ADMIN_USERNAME"]["value"] == "[parameters('adminUsername')]"
    agent_modules = {module["name"]: module for module in agent_main["resources"]}
    workstation_params = agent_modules["agent-box-workstation"]["properties"]["parameters"]
    assert workstation_params["adminUsername"]["value"] == "[parameters('adminUsername')]"
    assert workstation_params["confirmWindowsClientLicense"]["value"] == "[parameters('confirmWindowsClientLicense')]"
    workshop_workstation = next(
        module for module in outputs["workshop"]["resources"] if module["name"] == "workstation"
    )
    assert workshop_workstation["properties"]["parameters"]["confirmWindowsClientLicense"]["value"] == (
        "[parameters('confirmWindowsClientLicense')]"
    )
    workshop = outputs["workshop"]
    assert workshop["parameters"]["adminUsername"]["defaultValue"] == "appmoduser"
    assert workshop["parameters"]["adminUsername"]["minLength"] == 1
    assert workshop["parameters"]["adminUsername"]["maxLength"] == 20
    assert workshop["outputs"]["AZURE_VM_ADMIN_USERNAME"]["value"] == "[parameters('adminUsername')]"
    assert workshop_workstation["properties"]["parameters"]["adminUsername"]["value"] == "[parameters('adminUsername')]"
    workshop_vm = next(resource for resource in workshop_workstation["properties"]["template"]["resources"]
                       if resource["type"] == "Microsoft.Compute/virtualMachines")
    assert workshop_vm["properties"]["osProfile"]["adminUsername"] == "[parameters('adminUsername')]"
    workshop_scripts = next(module for module in workshop["resources"] if module["name"] == "user-scripts")
    assert workshop_scripts["properties"]["parameters"]["adminUsername"]["value"] == "[parameters('adminUsername')]"
    assert "base64(parameters('adminUsername'))" in workshop_scripts["properties"]["template"]["variables"]["stagingScript"]
    workshop_bindings = json.loads((WORKSHOP / "main.parameters.json").read_text())["parameters"]
    assert workshop_bindings["adminUsername"]["value"] == "${VM_ADMIN_USERNAME}"
    assert agent_modules["agent-box-user-scripts"]["properties"]["parameters"]["adminUsername"]["value"] == (
        "[parameters('adminUsername')]"
    )
    assert agent_main["parameters"]["maiFoundryRegion"]["maxLength"] == 42
    assert set(agent_main["parameters"]["maiFoundryRegion"]["allowedValues"]) == {
        "eastus", "swedencentral", "westeurope", "westus",
    }
    assert agent_main["parameters"]["maiFoundryRegion"]["metadata"]["azd"]["type"] == "location"
    agent_bindings = json.loads((AGENT / "main.parameters.json").read_text())["parameters"]
    assert agent_bindings["maiFoundryRegion"]["value"] == "${MAI_FOUNDRY_REGION}"
    assert agent_bindings["adminUsername"]["value"] == "${VM_ADMIN_USERNAME}"
    for parameter, default, variable in (
        ("maiImageDeploymentName", "mai-image-2.7", "MAI_IMAGE_DEPLOYMENT_NAME_OVERRIDE"),
        ("maiVoiceModel", "MAI-Voice-2.1", "MAI_VOICE_MODEL_OVERRIDE"),
        ("maiTranscribeModel", "MAI-Transcribe-2", "MAI_TRANSCRIBE_MODEL_OVERRIDE"),
    ):
        assert agent_main["parameters"][parameter]["defaultValue"] == default
        assert agent_main["parameters"][parameter]["minLength"] == 1
        assert agent_bindings[parameter]["value"] == "${" + variable + "}"
    assert agent_modules["agent-box-foundry"]["properties"]["parameters"]["imageDeploymentName"]["value"] == (
        "[parameters('maiImageDeploymentName')]"
    )
    agent_source = (AGENT / "main.bicep").read_text()
    assert "var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))" in agent_source
    assert "var resourceGroupName = 'rg-${environmentName}'" in agent_source
    assert "? 'vm-${resourceToken}'\n  : vmName" in agent_source
    assert "? take('w11-${resourceToken}', 15)\n  : computerName" in agent_source
    assert "resourceToken: resourceToken" in agent_source
    assert "name: 'cogsvc-${resourceToken}-${maiFoundryRegion}'" in agent_source
    assert "projectName: 'proj-${resourceToken}-${maiFoundryRegion}'" in agent_source
    assert "int(osDiskSizeGb)" in agent_source
    assert "int(maiImageCapacity)" in agent_source
    assert "bool(acceleratedNetworking)" in agent_source
    assert "bool(autoShutdownEnabled)" in agent_source
    assert "VM_NAME_OVERRIDE" not in agent_source
    assert "enrollment" not in agent_source.lower()
    assert "listKeys(" not in (AGENT / "modules/foundry.bicep").read_text()

    workstation = outputs["workstation"]
    assert workstation["parameters"]["zone"]["minLength"] == 1
    resources = {resource["type"]: resource for resource in workstation["resources"]}
    assert set(resources) == {
        "Microsoft.Network/networkSecurityGroups",
        "Microsoft.Network/publicIPAddresses",
        "Microsoft.Network/natGateways",
        "Microsoft.Network/virtualNetworks",
        "Microsoft.Network/bastionHosts",
        "Microsoft.Network/networkInterfaces",
        "Microsoft.Compute/virtualMachines",
        "Microsoft.DevTestLab/schedules",
    }
    for resource_type, prefix in (
        ("Microsoft.Network/networkSecurityGroups", "nsg"),
        ("Microsoft.Network/publicIPAddresses", "pip-nat"),
        ("Microsoft.Network/natGateways", "ng"),
        ("Microsoft.Network/virtualNetworks", "vnet"),
        ("Microsoft.Network/bastionHosts", "bas"),
        ("Microsoft.Network/networkInterfaces", "nic"),
    ):
        assert resources[resource_type]["name"] == f"[format('{prefix}-{{0}}', parameters('resourceToken'))]"
    assert resources["Microsoft.Network/networkSecurityGroups"]["properties"]["securityRules"] == []
    assert resources["Microsoft.Network/bastionHosts"]["sku"]["name"] == "Developer"
    assert resources["Microsoft.Network/bastionHosts"]["properties"]["ipConfigurations"] == []
    assert resources["Microsoft.Network/networkInterfaces"]["properties"]["ipConfigurations"][0]["properties"].get(
        "publicIPAddress"
    ) is None
    assert resources["Microsoft.Network/virtualNetworks"]["properties"]["subnets"][0]["properties"][
        "defaultOutboundAccess"
    ] is False
    vm = resources["Microsoft.Compute/virtualMachines"]
    assert vm["zones"] == ["[parameters('zone')]"]
    assert vm["name"] == "[parameters('vmName')]"
    assert vm["properties"]["storageProfile"]["osDisk"]["name"] == (
        "[format('osdisk-{0}', parameters('resourceToken'))]"
    )
    assert vm["properties"]["securityProfile"] == {
        "securityType": "TrustedLaunch",
        "uefiSettings": {"secureBootEnabled": True, "vTpmEnabled": True},
    }
    assert vm["properties"]["osProfile"]["adminUsername"] == "[parameters('adminUsername')]"
    assert workstation["parameters"]["confirmWindowsClientLicense"]["allowedValues"] == [True]
    assert vm["properties"]["licenseType"] == (
        "[if(parameters('confirmWindowsClientLicense'), 'Windows_Client', null())]"
    )
    assert outputs["agent-box"]["parameters"]["adminPassword"]["type"].lower() == "securestring"
    assert resources["Microsoft.DevTestLab/schedules"]["properties"]["dailyRecurrence"]["time"] == "0000"
    assert "var timeZoneId = 'Korea Standard Time'" in (
        AGENT / "modules/workstation.bicep"
    ).read_text()

    user_scripts = outputs["user-scripts"]["resources"][0]
    assert user_scripts["type"] == "Microsoft.Compute/virtualMachines/runCommands"
    assert user_scripts["properties"]["asyncExecution"] is False
    assert user_scripts["properties"]["treatFailureAsDeploymentFailure"] is True
    assert "stage-agent-box-user-scripts" in user_scripts["name"]
    assert "base64(parameters('adminUsername'))" in outputs["user-scripts"]["variables"]["stagingScript"]

    foundry = outputs["foundry"]
    foundry_resources = {resource["type"]: resource for resource in foundry["resources"]}
    assert set(foundry_resources) == {
        "Microsoft.CognitiveServices/accounts",
        "Microsoft.CognitiveServices/accounts/projects",
        "Microsoft.CognitiveServices/accounts/deployments",
    }
    assert foundry_resources["Microsoft.CognitiveServices/accounts/projects"]["name"] == (
        "[format('{0}/{1}', parameters('name'), parameters('projectName'))]"
    )
    deployment = foundry_resources["Microsoft.CognitiveServices/accounts/deployments"]
    assert deployment["name"] == "[format('{0}/{1}', parameters('name'), parameters('imageDeploymentName'))]"
    assert deployment["sku"]["name"] == "GlobalStandard"
    assert deployment["properties"]["model"] == {
        "format": "Microsoft", "name": "MAI-Image-2.7", "version": "2026-11-02"
    }
    assert deployment["properties"]["versionUpgradeOption"] == "NoAutoUpgrade"
    assert foundry["outputs"]["speechEndpoint"]["value"] == (
        "[format('https://{0}.cognitiveservices.azure.com', parameters('name'))]"
    )
    assert foundry["outputs"]["imageDeploymentName"]["value"] == "[parameters('imageDeploymentName')]"
    assert agent_main["outputs"]["MAI_IMAGE_DEPLOYMENT_NAME"]["value"].endswith(
        ".outputs.imageDeploymentName.value]"
    )
    assert agent_main["outputs"]["MAI_VOICE_MODEL"]["value"] == "[parameters('maiVoiceModel')]"
    assert agent_main["outputs"]["MAI_TRANSCRIBE_MODEL"]["value"] == "[parameters('maiTranscribeModel')]"

    workshop = outputs["workshop"]
    assert workshop["parameters"]["vmSize"]["defaultValue"] == "Standard_D8s_v5"
    assert workshop["parameters"]["osDiskSizeGB"]["defaultValue"] == "256"
    assert workshop["parameters"]["autoShutdownTime"]["defaultValue"] == "0000"
    workshop_source = (WORKSHOP / "main.bicep").read_text()
    assert "Korea Standard Time" in workshop_source
    assert "appmoduser" in workshop_source

    for legacy in (
        ROOT / "infra/resources.bicep", ROOT / "infra/foundry.bicep",
        ROOT / "scripts/Initialize-Guest.ps1", ROOT / "scripts/Start-IntuneEnrollment.ps1",
        ROOT / "scripts/Add-RdpSourceIp.ps1", ROOT / "tests/test_rdp_sources.py",
    ):
        assert not legacy.exists(), f"Obsolete Agent Box file remains: {legacy.relative_to(ROOT)}"
    print("Both project templates, VM networking, licensing, and Foundry contracts passed.")


def check_scripts():
    bash_files = [path for root in (AGENT, WORKSHOP, SHARED) for path in root.rglob("*.sh")]
    for path in bash_files:
        run("bash", "-n", str(path))
    test_output = WORKSHOP / ".test-output"
    output_existed = test_output.exists()
    run("bash", str(WORKSHOP / "tests/vm-payload.tests.sh"))
    if not output_existed and test_output.exists() and not any(test_output.iterdir()):
        test_output.rmdir()
    run(
        "pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
        str(ROOT / "tests/Test-Scripts.ps1"), "-RepositoryRoot", str(ROOT),
    )
    workshop_outputs = {
        **ENV,
        "DEPLOYMENT_TEMPLATE": "app-modernisation-workshop",
        "AZURE_RESOURCE_GROUP": "rg-workshop-test",
        "AZURE_VM_NAME": "vm-workshop-test",
        "AZURE_VM_ADMIN_USERNAME": "customworkshop",
    }
    agent_outputs = {
        **ENV,
        "AZURE_RESOURCE_GROUP": "rg-agent-test",
        "AZURE_VM_NAME": "vm-agent-test",
        "AZURE_VM_ADMIN_USERNAME": "customadmin",
    }
    for shell, hook in (
        (("bash",), "postprovision.sh"),
        (("pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File"), "postprovision.ps1"),
    ):
        guidance = run(*shell, str(WORKSHOP / "scripts" / hook), env=workshop_outputs)
        assert "README.md" in guidance.stdout and r".\customworkshop" in guidance.stdout
        guidance = run(*shell, str(AGENT / "scripts" / hook), env=agent_outputs)
        assert r".\customadmin" in guidance.stdout and r".\agentboxuser" not in guidance.stdout
        for project, outputs in ((WORKSHOP, workshop_outputs), (AGENT, agent_outputs)):
            for name in ("AZURE_RESOURCE_GROUP", "AZURE_VM_NAME", "AZURE_VM_ADMIN_USERNAME"):
                failure = run(*shell, str(project / "scripts" / hook),
                              env={**outputs, name: ""}, succeeds=False)
                assert name in failure.stderr
    if os.name == "nt":
        run(
            "pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File",
            str(WORKSHOP / "tests/vm-setup.tests.ps1"),
        )
    else:
        print("Skipped the workshop Windows VM runtime suite on this non-Windows host.")
    print(f"Parsed {len(bash_files)} Bash scripts and the PowerShell script set.")


def check_numeric_and_boolean_conversions(directory):
    fixture = directory / "conversion.bicepparam"
    output = directory / "conversion.json"
    for expression, declarations, expected in (
        ("int(osDiskSizeGb)", "var osDiskSizeGb = '256'", 256),
        ("bool(acceleratedNetworking)", "var acceleratedNetworking = 'false'", False),
    ):
        fixture.write_text(f"using none\n{declarations}\nparam result = {expression}\n")
        run("az", "bicep", "build-params", "--file", str(fixture), "--outfile", str(output))
        assert json.loads(output.read_text())["parameters"]["result"]["value"] == expected

    fixture.write_text(
        "using none\nvar osDiskSizeGb = 'not-a-number'\nparam result = int(osDiskSizeGb)\n"
    )
    run("az", "bicep", "build-params", "--file", str(fixture), "--outfile", str(output), succeeds=False)
    fixture.write_text(
        "using none\nvar acceleratedNetworking = 'not-a-boolean'\n"
        "param result = bool(acceleratedNetworking)\n"
    )
    run("az", "bicep", "build-params", "--file", str(fixture), "--outfile", str(output), succeeds=False)
    print("String-backed numeric and boolean inputs convert strictly and reject malformed values.")


def main():
    for command in ("az", "azd", "bash", "pwsh", "python3"):
        assert shutil.which(command), f"{command} is required for local validation."
    with tempfile.TemporaryDirectory(prefix="agentbox-validation-") as temporary:
        directory = Path(temporary)
        check_templates(directory)
        check_packaging()
        check_numeric_and_boolean_conversions(directory)
    check_scripts()
    check_hook_colors()
    check_interactive_command_logging()
    check_hooks()
    check_interactive_region_selection()
    check_real_azd_hooks()
    print("All local checks passed. No Azure resources or Windows software were changed.")


if __name__ == "__main__":
    main()
