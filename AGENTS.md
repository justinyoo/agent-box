# Agent instructions

## Architecture

- `agent-box` and `appmod-box` are independent Azure Developer CLI (`azd`) projects. Run azd from the chosen project directory; each has its own environment, hooks, parameters, and Bicep modules. Both create `rg-{environmentName}`, so use different environment names when deploying both into the same subscription.
- Each project provisions a Windows VM, Bastion Developer, and NAT Gateway. Agent Box additionally provisions Microsoft Foundry and the MAI image model; its Speech model names are outputs, not model deployments.
- Each `azure.yaml` runs interactive preprovision and postprovision hooks in both Bash and PowerShell. Shared region validation and hook-message helpers live in `shared/`; keep the two hook platforms behaviorally aligned. Agent Box selects or preserves a VM availability zone and selects a separate Foundry region.
- Preprovision packages the project-specific installer files as a gzip/base64 JSON payload, stores it in three azd environment values, and passes them through Bicep. VM Run Command stages the files in the local administrator's profile; it does not install tools. The user signs in and runs the installer manually. The staging script substitutes the administrator placeholder and refuses to overwrite different existing files.

## Build and validation

Prerequisites: Python 3, Bash, PowerShell 7, Azure CLI with Bicep, and azd 1.35.1 or later. CI runs on Ubuntu using the following local checks:

```bash
python3 tests/validate.py
pwsh -NoLogo -NoProfile -File tests/Test-Scripts.ps1
```

For a focused check, call an individual function in `tests/validate.py`, for example:

```bash
python3 -c 'from tests.validate import check_packaging; check_packaging()'
```

`bash appmod-box/infra/tests/vm-payload.tests.sh` runs the workshop Bash payload tests separately. To compile one Bicep entry point without writing a generated template:

```bash
az bicep build --file agent-box/infra/main.bicep --stdout > /dev/null
```

Use `appmod-box/infra/main.bicep` for the other project. These local checks do not deploy Azure resources or verify actual Windows VM behavior; the Windows runtime suite is skipped on non-Windows hosts.

## Repository conventions

- Keep azd environment mappings in each `infra/main.parameters.json` aligned with Bicep parameters and both preprovision implementations. For numeric or boolean azd inputs, use string Bicep parameters and convert with `int()` or `bool()` so malformed values fail rather than silently default.
- Preserve explicit Windows client license confirmation; the administrator password is a secure Bicep parameter. Do not output account keys.
- Payload builders and staging scripts enforce a 90,000-character compressed payload limit and a 1 MiB expanded limit. Update both Bash and PowerShell packaging paths and payload tests together when changing staged files or their format.
- The two VM installers contain separately maintained common functions with tests checking their equivalence; project-specific installation steps and arguments can differ. Keep the staged administrator placeholder intact.
- Keep each project's English and Korean README links and corresponding guidance aligned. PowerShell and shell scripts use LF line endings, as specified by `.gitattributes`.
