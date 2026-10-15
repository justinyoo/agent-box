"""Compile and check deployment contracts without creating Azure resources."""

import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
INFRA = ROOT / "infra"
ENV = {**os.environ, "AZURE_CORE_ONLY_SHOW_ERRORS": "false"}


def run(*args, succeeds=True, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env or ENV, text=True, capture_output=True)
    if succeeds and result.returncode:
        raise AssertionError(f"{args[0]} failed:\n{result.stdout}\n{result.stderr}")
    if not succeeds and not result.returncode:
        raise AssertionError("Invalid fixture unexpectedly compiled.")
    return result


def literal(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n") + "'"


def evaluate(directory, expression, declarations="", succeeds=True):
    source = directory / "fixture.bicepparam"
    destination = directory / "fixture.json"
    source.write_text(f"using none\n{declarations}\nparam result = {expression}\n")
    run("az", "bicep", "build-params", "--file", str(source), "--outfile", str(destination), succeeds=succeeds)
    if succeeds:
        return json.loads(destination.read_text())["parameters"]["result"]["value"]


def check_powershell(path):
    command = (
        "$tokens=$null; $errors=$null; "
        "$null=[System.Management.Automation.Language.Parser]::ParseFile("
        "$env:AGENTBOX_SCRIPT, [ref]$tokens, [ref]$errors); "
        "if ($errors.Count) { throw ($errors | Out-String) }"
    )
    run("pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command,
        env={**ENV, "AGENTBOX_SCRIPT": str(path)})


def check_bash_rdp_source():
    script = ROOT / "scripts" / "get-rdp-source.sh"
    run("bash", "-n", str(script))
    with tempfile.TemporaryDirectory(prefix="agentbox-rdp-source-") as temporary:
        directory = Path(temporary)
        curl = directory / "curl"
        curl.write_text(
            '#!/usr/bin/env bash\n'
            'printf "%s\\n" "$@" > "$AGENTBOX_CURL_ARGS"\n'
            'printf "%s" "$AGENTBOX_IP_RESPONSE"\n'
            'exit "$AGENTBOX_CURL_EXIT"\n'
        )
        curl.chmod(0o755)
        arguments = directory / "curl-args"
        cases = [
            ("203.0.113.42", 0, "203.0.113.42/32\n"),
            (" \t203.0.113.42\r\n", 0, "203.0.113.42/32\n"),
            ("1.0.255.1", 0, "1.0.255.1/32\n"),
            ("", 0, ""),
            ("<html>error</html>", 0, ""),
            ("256.0.0.1", 0, ""),
            ("01.2.3.4", 0, ""),
            ("127.1", 0, ""),
            ("::1", 0, ""),
            ("203.0.113.42/32", 0, ""),
            ("*", 0, ""),
            ("203.0.113.42\n203.0.113.43", 0, ""),
            ("", 22, ""),
            ("203.0.113.42", 28, ""),
        ]
        for response, status, expected in cases:
            result = subprocess.run(
                ["bash", str(script)], cwd=ROOT, text=True, capture_output=True,
                env={**ENV, "PATH": str(directory) + os.pathsep + ENV["PATH"],
                     "AGENTBOX_CURL_ARGS": str(arguments), "AGENTBOX_IP_RESPONSE": response,
                     "AGENTBOX_CURL_EXIT": str(status)},
            )
            assert result.stdout == expected, f"Unexpected source output for {response!r}: {result.stdout!r}"
            assert (result.returncode == 0) == bool(expected), f"Wrong exit status for {response!r}."
            assert bool(result.stderr) == (not expected), f"Wrong error output for {response!r}."
            assert arguments.read_text().splitlines() == [
                "-q", "--ipv4", "--fail", "--silent", "--show-error",
                "--connect-timeout", "5", "--max-time", "15", "https://api.ipify.org",
            ]
    print(f"{len(cases)} isolated Bash RDP source checks passed.")


def check_preprovision_hooks():
    azd = shutil.which("azd")
    assert azd, "azd is required to validate preprovision hooks."
    with tempfile.TemporaryDirectory(prefix="agentbox-hooks-") as temporary:
        directory = Path(temporary)
        shutil.copyfile(ROOT / "azure.yaml", directory / "azure.yaml")
        scripts = directory / "scripts"
        scripts.mkdir()
        (scripts / "get-rdp-source.sh").write_text(
            '#!/usr/bin/env bash\n'
            'if [ "$AGENTBOX_LOOKUP_FAIL" = 1 ]; then echo "Synthetic lookup failure" >&2; exit 1; fi\n'
            'printf "%s\\n" "203.0.113.42/32"\n'
        )
        (scripts / "Get-RdpSource.ps1").write_text(
            'if ($env:AGENTBOX_LOOKUP_FAIL -eq "1") { throw "Synthetic lookup failure" }\n'
            '"203.0.113.42/32"\n'
        )
        for name in ("hook-default", "hook-target"):
            environment = directory / ".azure" / name
            environment.mkdir(parents=True)
            (environment / ".env").write_text(
                f'AZURE_ENV_NAME="{name}"\nVM_RDP_SOURCE="198.51.100.9/32"\n'
            )
        (directory / ".azure" / "config.json").write_text(
            json.dumps({"defaultEnvironment": "hook-default"})
        )
        binary = directory / "bin"
        binary.mkdir()
        arguments = directory / "azd-args.json"
        fake_azd = binary / "fake_azd.py"
        fake_azd.write_text(
            'import json, os, sys\n'
            'from pathlib import Path\n'
            'Path(os.environ["AGENTBOX_AZD_ARGS"]).write_text(json.dumps(sys.argv[1:]))\n'
            'sys.exit(int(os.environ["AGENTBOX_AZD_EXIT"]))\n'
        )
        stub = binary / "azd"
        stub.write_text('#!/usr/bin/env bash\nexec "$AGENTBOX_PYTHON" "$AGENTBOX_FAKE_AZD" "$@"\n')
        stub.chmod(0o755)
        (binary / "azd.cmd").write_text('@"%AGENTBOX_PYTHON%" "%AGENTBOX_FAKE_AZD%" %*\n')
        for platform in ("posix", "windows"):
            for lookup_fails, save_status in ((False, 0), (True, 0), (False, 1)):
                arguments.unlink(missing_ok=True)
                result = subprocess.run(
                    [azd, "hooks", "run", "preprovision", "--platform", platform,
                     "--environment", "hook-target", "--no-prompt"],
                    cwd=directory, text=True, capture_output=True,
                    env={**ENV, "PATH": str(binary) + os.pathsep + ENV["PATH"],
                         "AGENTBOX_LOOKUP_FAIL": str(int(lookup_fails)),
                         "AGENTBOX_AZD_EXIT": str(save_status), "AGENTBOX_AZD_ARGS": str(arguments),
                         "AGENTBOX_PYTHON": sys.executable, "AGENTBOX_FAKE_AZD": str(fake_azd)},
                )
                expected_success = not lookup_fails and save_status == 0
                assert (result.returncode == 0) == expected_success, (
                    f"{platform} hook returned {result.returncode}:\n{result.stdout}\n{result.stderr}"
                )
                if lookup_fails:
                    assert not arguments.exists(), "Failed lookup attempted to save an RDP source."
                    assert "Synthetic lookup failure" in result.stdout + result.stderr
                else:
                    assert arguments.exists(), f"{platform} hook did not call azd env set."
                    assert json.loads(arguments.read_text()) == [
                        "env", "set", "VM_RDP_SOURCE", "203.0.113.42/32", "--environment", "hook-target",
                    ], "Hook did not refresh the source in the requested environment."
    print("6 isolated preprovision hook checks passed.")


def check_rdp_allowlist(directory, main_source, resources_source):
    expression = re.search(r"^var rdpSources = (.+)$", main_source, re.M).group(1)
    for current, additional, expected in (
        ("", "[]", []),
        ("203.0.113.10/32", "[]", ["203.0.113.10/32"]),
        ("", '["198.51.100.0/24"]', ["198.51.100.0/24"]),
        ("203.0.113.10/32", '["203.0.113.10/32","198.51.100.0/24"]',
         ["203.0.113.10/32", "198.51.100.0/24"]),
    ):
        declarations = f"var allowedRdpSource = {literal(current)}\nvar additionalRdpSources = {literal(additional)}"
        assert evaluate(directory, expression, declarations) == expected
    evaluate(directory, expression, "var allowedRdpSource = ''\nvar additionalRdpSources = 'invalid-json'", succeeds=False)
    evaluate(directory, expression, "var allowedRdpSource = ''\nvar additionalRdpSources = '{}'", succeeds=False)
    rules_expression = re.search(
        r"securityRules: (empty\(allowedRdpSources\)[\s\S]+?^    \])", resources_source, re.M
    ).group(1)
    assert evaluate(directory, rules_expression, "var allowedRdpSources = []") == []
    for sources in (["203.0.113.10/32"], ["203.0.113.10/32", "198.51.100.0/24"]):
        rules = evaluate(directory, rules_expression, f"var allowedRdpSources = json({literal(json.dumps(sources))})")
        assert len(rules) == 1
        assert rules[0]["properties"]["sourceAddressPrefixes"] == sources
        assert "sourceAddressPrefix" not in rules[0]["properties"]
        assert rules[0]["properties"]["protocol"] == "Tcp"
        assert rules[0]["properties"]["destinationPortRange"] == "3389"
    assert "output VM_RDP_ENABLED bool = !empty(rdpSources)" in main_source
    print("RDP allowlist merge and NSG rule contracts passed.")


def main():
    main_source = (INFRA / "main.bicep").read_text()
    resources_source = (INFRA / "resources.bicep").read_text()
    with tempfile.TemporaryDirectory(prefix="agentbox-validation-") as temporary:
        directory = Path(temporary)
        compiled = directory / "main.json"
        build = run("az", "bicep", "build", "--file", str(INFRA / "main.bicep"), "--outfile", str(compiled))
        diagnostics = build.stdout + build.stderr
        warnings = set(re.findall(r"Warning (BCP\d+):", diagnostics))
        assert warnings <= {"BCP081"}, f"Unexpected Bicep schema warnings:\n{diagnostics}"
        if "BCP081" in warnings:
            print("Bicep reports missing types for newer service APIs (BCP081); full schema coverage requires Azure validation.")
        template = json.loads(compiled.read_text())
        resource_group = next(r for r in template["resources"] if r["type"] == "Microsoft.Resources/resourceGroups")
        assert resource_group["apiVersion"] == "2025-04-01"
        deployment = next(r for r in template["resources"] if r["type"] == "Microsoft.Resources/deployments")
        child = deployment["properties"]["template"]
        child_resources = child["resources"]
        if isinstance(child_resources, dict):
            child_resources = child_resources.values()
        resources = {r["type"]: r for r in child_resources}
        assert set(resources) == {
            "Microsoft.Network/networkSecurityGroups",
            "Microsoft.Network/virtualNetworks",
            "Microsoft.Network/publicIPAddresses",
            "Microsoft.Network/networkInterfaces",
            "Microsoft.Compute/virtualMachines",
            "Microsoft.Compute/virtualMachines/runCommands",
            "Microsoft.Compute/virtualMachines/extensions",
        }
        for resource_type, resource in resources.items():
            expected = "2025-09-01" if resource_type.startswith("Microsoft.Network/") else "2026-04-01"
            assert resource["apiVersion"] == expected, f"Unexpected API version for {resource_type}."
        assert template["parameters"]["adminPassword"]["type"].lower() == "securestring"
        assert "defaultValue" not in template["parameters"]["adminPassword"]
        assert child["parameters"]["adminPassword"]["type"].lower() == "securestring"
        assert template["parameters"]["location"]["defaultValue"] == "westus2"
        assert template["parameters"]["vmSize"]["defaultValue"] == "Standard_D64ds_v7"
        assert template["parameters"]["zone"]["defaultValue"] == "1"
        assert template["parameters"]["adminUsername"]["defaultValue"] == "azureuser"
        assert template["parameters"]["enrollmentAdminUsername"]["defaultValue"] == "enrolleduser"
        assert template["parameters"]["pythonVersion"]["defaultValue"] == "3.14"
        assert template["parameters"]["allowedRdpSource"]["defaultValue"] == ""
        # ARM escapes a literal string that starts with '['.
        assert template["parameters"]["additionalRdpSources"]["defaultValue"] == "[[]"
        assert template["parameters"]["additionalRdpSources"]["type"] == "string"
        assert template["parameters"]["zone"]["allowedValues"] == ["", "1", "2", "3"]
        assert template["parameters"]["acceleratedNetworking"]["allowedValues"] == ["true", "false"]
        vm = resources["Microsoft.Compute/virtualMachines"]
        assert "identity" not in vm
        assert vm["properties"]["securityProfile"] == {
            "securityType": "TrustedLaunch",
            "uefiSettings": {"secureBootEnabled": True, "vTpmEnabled": True},
        }
        assert vm["properties"]["licenseType"] == "Windows_Client"
        assert vm["properties"]["storageProfile"]["osDisk"]["createOption"] == "FromImage"
        assert vm["properties"]["storageProfile"]["dataDisks"] == []
        windows_configuration = vm["properties"]["osProfile"]["windowsConfiguration"]
        assert "enableVMAgentPlatformUpdates" not in windows_configuration
        assert windows_configuration["provisionVMAgent"] is True
        assert windows_configuration["enableAutomaticUpdates"] is True
        for resource in resources.values():
            assert "provisioningState" not in resource.get("properties", {})
            assert "instanceView" not in resource.get("properties", {})
        assert "primary" not in resources["Microsoft.Network/networkInterfaces"]["properties"]
        assert child["parameters"]["osDiskSizeGb"]["minValue"] == 127
        assert child["parameters"]["osDiskSizeGb"]["maxValue"] == 4095

        bindings = json.loads((INFRA / "main.parameters.json").read_text())["parameters"]
        assert set(bindings) == set(template["parameters"])
        variables = {re.fullmatch(r"\$\{([A-Z0-9_]+)\}", p["value"]).group(1) for p in bindings.values()}
        assert variables.isdisjoint(template["outputs"]), "Outputs must not become implicit input overrides."
        assert bindings["osDiskSizeGb"]["value"] == "${VM_OS_DISK_SIZE_GB}"
        assert bindings["additionalRdpSources"]["value"] == "${VM_RDP_ADDITIONAL_SOURCES}"
        assert deployment["properties"]["parameters"]["osDiskSizeGb"]["value"] == "[int(parameters('osDiskSizeGb'))]"
        assert evaluate(directory, "int(osDiskSizeGb)", "var osDiskSizeGb = '256'") == 256
        evaluate(directory, "int(osDiskSizeGb)", "var osDiskSizeGb = 'not-a-number'", succeeds=False)
        assert evaluate(directory, "bool(acceleratedNetworking)", "var acceleratedNetworking = 'false'") is False

        naming = {}
        for name in ("vmName", "computerName"):
            naming[name] = re.search(rf"^param {name} string = (.+)$", main_source, re.M).group(1)
        naming["resourceGroup"] = re.search(r"^var resourceGroupName = (.+)$", main_source, re.M).group(1)
        names = []
        for environment in ("validation-a", "validation-b"):
            declarations = (
                f"var environmentName = {literal(environment)}\n"
                "var namePrefix = 'agentbox'\n"
                "var testSubscription = '00000000-0000-0000-0000-000000000000'"
            )
            expression = "{\n" + "\n".join(
                f"{name}: {expr.replace('subscription().id', 'testSubscription')}"
                for name, expr in naming.items()
            ) + "\n}"
            names.append(evaluate(directory, expression, declarations))
        assert names[0] != names[1]
        for values in names:
            assert len(values["vmName"]) <= 50
            assert re.fullmatch(r"ab-[a-z0-9]{12}", values["computerName"])
        assert names[0]["computerName"] != names[1]["computerName"]

        check_rdp_allowlist(directory, main_source, resources_source)
        assert resources_source.count("zones: empty(zone) ? [] : [zone]") == 2
        assert evaluate(directory, "empty(zone) ? [] : [zone]", "var zone = ''") == []
        assert evaluate(directory, "empty(zone) ? [] : [zone]", "var zone = '2'") == ["2"]

        tag_expression = re.search(r"^var resourceTags = (union\(tags, \{[\s\S]+?^\}\))", main_source, re.M).group(1)
        tags = evaluate(directory, tag_expression,
                        "var environmentName = 'real-env'\nvar tags = { 'azd-env-name': 'spoofed', owner: 'test', project: 'custom' }")
        assert tags["azd-env-name"] == "real-env" and tags["owner"] == "test"
        assert tags["project"] == "custom"

        declarations = []
        for name, function, path in re.findall(
            r"^var (\w+) = (loadTextContent|loadFileAsBase64)\('([^']+)'\)$", resources_source, re.M
        ):
            relative = os.path.relpath((INFRA / path).resolve(), directory).replace(os.sep, "/")
            declarations.append(f"var {name} = {function}({literal(relative)})")
        stage_expression = re.search(
            r"script: (format\('''[\s\S]+?''',\s*stagingScript,\s*localAdminScript,\s*initializationScript,\s*enrollmentScript,\s*devToolsScript\))",
            resources_source,
        ).group(1)
        staging = evaluate(directory, stage_expression, "\n".join(declarations))
        assert len(staging.encode()) < 65536, "Staging exceeds the project's 64 KiB source-script budget."
        assert "${stagingScript}" not in staging
        embedded = dict(re.findall(r"'([\w-]+\.ps1)' = '([A-Za-z0-9+/=]+)'", staging))
        assert set(embedded) == {"New-LocalAdmin.ps1", "Initialize-Guest.ps1",
                                 "Start-IntuneEnrollment.ps1", "Install-DevTools.ps1"}
        for name, encoded in embedded.items():
            assert base64.b64decode(encoded) == (ROOT / "scripts" / name).read_bytes()
        staged = directory / "staged-command.ps1"
        staged.write_text(staging)
        check_powershell(staged)
        stage_resource = resources["Microsoft.Compute/virtualMachines/runCommands"]
        assert stage_resource["properties"]["asyncExecution"] is False
        assert stage_resource["properties"]["treatFailureAsDeploymentFailure"] is True
        assert "protectedParameters" not in stage_resource["properties"]

        extension = resources["Microsoft.Compute/virtualMachines/extensions"]
        assert extension["properties"]["type"] == "CustomScriptExtension"
        assert "settings" not in extension["properties"]
        assert any(
            dependency == "stageGuestScripts" or "stage-guest-scripts" in dependency
            for dependency in extension["dependsOn"]
        )
        assert "adminPassword" not in json.dumps(child["variables"]["guestConfiguration"])
        assert "adminPassword" not in child["variables"]["setupFingerprint"]
        command_expression = re.search(r"^      commandToExecute: (.+)$", resources_source, re.M).group(1)
        # This is synthetic validation data, never a deployment credential.
        password = ("NotARealCredential-A9!" + chr(0x2603) + "'\"$;%!&|\\") * 4
        password = password[:123]
        config = {"initialAdminUsername": "azureuser", "enrollmentAdminUsername": "enrolleduser", "pythonVersion": "3.14"}
        command = evaluate(directory, command_expression,
                           f"var adminPassword = {literal(password)}\n"
                           f"var guestConfigurationBase64 = base64({literal(json.dumps(config))})")
        assert len(command) < 8191
        assert password not in command
        encoded = re.findall(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", command)
        assert json.loads(base64.b64decode(encoded[0])) == config
        assert base64.b64decode(encoded[1]).decode() == password
        assert "Start-IntuneEnrollment.ps1" not in command and "winget" not in command
        assert "AgentBox/Scripts/Initialize-Guest.ps1" in command
        assert "\\" not in command
        assert child["outputs"]["enrollmentScriptPath"]["value"] == "C:/ProgramData/AgentBox/Scripts/Start-IntuneEnrollment.ps1"
        assert child["outputs"]["devToolsScriptPath"]["value"] == "C:/ProgramData/AgentBox/Scripts/Install-DevTools.ps1"
        assert child["outputs"]["devToolsTaskPath"]["value"] == "\\AgentBox\\InstallDevTools"
        body = command.split('-Command "', 1)[1][:-1]
        body_path = directory / "protected-command.ps1"
        body_path.write_text(body)
        check_powershell(body_path)
        for script in (ROOT / "scripts").glob("*.ps1"):
            check_powershell(script)
            text = script.read_text()
            assert not re.search(r"\.\\[\w-]+\.ps1\b", text), f"Non-POSIX script example in {script.name}."
            assert not re.search(r"(?:AgentBox\\(?:Scripts|Logs)|System32\\|\b[A-Za-z]:\\)", text), (
                f"Non-POSIX filesystem path in {script.name}."
            )
        readme = (ROOT / "README.md").read_text()
        assert not re.search(r"\b[A-Za-z]:\\", readme), "README filesystem examples must use POSIX separators."

    run("pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(ROOT / "tests" / "Test-Scripts.ps1"))
    check_bash_rdp_source()
    check_preprovision_hooks()
    run(sys.executable, str(ROOT / "tests" / "test_rdp_sources.py"))
    print("Bicep, parameter, resource-graph, payload, PowerShell/Bash, and hook checks passed.")
    print("No Azure resources, Windows accounts, or software installations were changed.")


if __name__ == "__main__":
    main()
