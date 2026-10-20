# Agent Box

Provision a standalone Windows 11 Enterprise development VM and regional Microsoft Foundry accounts/projects with Azure Developer CLI (`azd`) and Bicep. Foundry hosts GPT-Image 2.5 Sunburst, GPT-6 Astra, and Claude Opus 5.5. Guest setup creates a local administrator, installs developer tools at first sign-in, and provides a helper for manual Intune enrollment.

- **Azure hosting tenant:** the Microsoft Entra tenant associated with the VM's Azure subscription.
- **Intune enrollment tenant:** the tenant the Windows guest joins for Intune management. It can differ from the hosting tenant.

**The default VM has 64 vCPUs and 256 GiB RAM and is relatively expensive. Public RDP is limited to the provisioning computer's detected public IPv4 address and any explicitly retained trusted sources.**

## Prerequisites

- `azd` **1.35.1 or later**. The deployment machine does not need Windows.
- `az` **2.90.0 or later**.
- Azure permissions for resource groups, Compute/Network resources, VM Run Commands, and extensions; sufficient regional and Ddsv7-family quota for 64 vCPUs; and compatible capacity and policies.
- Permissions to create `Microsoft.CognitiveServices` accounts, projects, and model deployments, plus available **Global Standard** quota and any required model access in each selected region. Regional availability alone does not guarantee capacity or subscription eligibility.
- For Claude: an eligible paid Azure subscription, Marketplace purchasing permissions, and accurate organization attestation values. Azure credits alone do not cover Claude usage; review [Claude subscription restrictions](https://learn.microsoft.com/azure/foundry/foundry-models/how-to/use-foundry-models-claude#subscription-type-and-region-support).
- Qualifying Windows client virtualization rights. Intune licensing alone is not sufficient.
- For enrollment: an account in the Intune enrollment tenant with the required Intune/Entra licenses, device-join permission, MDM user scope, and enrollment-policy permissions.

## Deploy

Replace the uppercase placeholders and choose a unique environment name:

**Claude Marketplace terms:** provisioning sends `CLAUDE_ORGANIZATION_NAME`, `CLAUDE_COUNTRY_CODE`, and `CLAUDE_INDUSTRY` to Azure in `modelProviderData`, which accepts the Anthropic Marketplace offer on your behalf. Review the [Anthropic Commercial Terms](https://www.anthropic.com/legal/commercial-terms), [Usage Policy](https://www.anthropic.com/legal/aup), [Supported Regions Policy](https://aka.ms/supported_anthropic_regions), and [Microsoft Product Terms](https://www.microsoft.com/licensing/terms/) before provisioning. These attestation inputs have no defaults; use values that accurately describe the organization using Claude.

```console
azd auth login --tenant-id <HOSTING_TENANT_GUID>
azd env new <HOSTING_ENV_NAME> --subscription <HOSTING_SUBSCRIPTION_GUID> --location <HOSTING_LOCATION>

azd provision --preview
azd provision
```

`--preview` does not change Azure resources; hooks can update local azd settings. `azd provision` creates billable resources. Do not allow RDP from `*` or `0.0.0.0/0`. There are no application services, so `azd deploy` is unnecessary.

The three model-region inputs have **no defaults**: azd prompts for each unless its environment variable is set. The VM/resource-group region is independent. See [Foundry models and regions](#foundry-models-and-regions) for allowed choices and example overrides.

Each environment gets its own resource group, VM, OS disk, VNet/subnet, NIC, NSG, and static public IP, plus **one Foundry account and project per distinct model region**. Models selecting the same region share that account/project; three distinct regions create three pairs. Trusted Launch, Secure Boot, vTPM, automatic Windows updates, and managed boot diagnostics are enabled. A managed Run Command stages scripts; a Custom Script Extension creates/verifies the secondary administrator and registers its tools task.

Reusing an environment updates its resources. Existing environments retain their saved location; changing defaults does not migrate a deployed VM.

### Source IP for RDP

#### Verification

Run the following helper script to print the detected CIDR without changing Azure or azd settings:

```bash
# zsh/bash
./scripts/get-rdp-source.sh
```

```powershell
# PowerShell
./scripts/Get-RdpSource.ps1
```

#### Update

Run the following helper script to append your current public IPv4 `/32` to the existing RDP rule through Azure CLI:

```bash
# zsh/bash
./scripts/add-rdp-source-ip.sh
```

```powershell
# PowerShell
./scripts/Add-RdpSourceIp.ps1
```

### Passwords

Leave `VM_ADMIN_PASSWORD` unset for azd's secure prompt. Supply a 12-123-character password meeting Azure/Windows requirements. It initializes both local accounts; later changes are not synchronized, and redeployment does not reset the secondary account.

For automation, inject the password from a secret store into the azd process. **Do not store it with `azd env set` or commit credentials.** azd retains prompted secrets in its local user vault; protect its profile, `.azure` state, and deployment caches. Azure secure parameters and protected extension settings do not hide runtime secrets from administrators inside the VM.

## Configuration

Use `azd env set NAME VALUE` to override settings and `azd env unset NAME` to restore optional defaults. Full constraints are in [infra/main.bicep](infra/main.bicep).

| Variable                       | Default / meaning                                                                                                |
| ------------------------------ | -----------------------------------------------------------------------------------------------------------------|
| `AZURE_ENV_NAME`               | Set by `azd env new`                                                                                             |
| `AZURE_LOCATION`               | Set by `azd up` or `azd provision`; recommend `eastus2`` or `westus3`                                            |
| `VM_NAME_PREFIX`               | `agentbox`                                                                                                       |
| `VM_NAME_OVERRIDE`             | Environment-derived VM name                                                                                      |
| `VM_COMPUTER_NAME_OVERRIDE`    | Environment-derived Windows name; maximum 15 characters                                                          |
| `VM_SIZE`                      | `Standard_D64ds_v7`                                                                                              |
| `VM_ZONE`                      | `1`; empty means regional                                                                                        |
| `VM_IMAGE_PUBLISHER`           | `microsoftwindowsdesktop`                                                                                        |
| `VM_IMAGE_OFFER`               | `windows-11`                                                                                                     |
| `VM_IMAGE_SKU`                 | `win11-26h2-ent`, single-session                                                                                 |
| `VM_IMAGE_VERSION`             | `latest`; accepts a published version                                                                            |
| `VM_ADMIN_USERNAME`            | `azureuser`                                                                                                      |
| `VM_ENROLLMENT_ADMIN_USERNAME` | `enrolleduser`; must differ from the initial account                                                             |
| `VM_ADMIN_PASSWORD`            | Required secure input                                                                                            |
| `VM_OS_DISK_SIZE_GB`           | `127`; range 127-4095                                                                                            |
| `VM_OS_DISK_TYPE`              | `Premium_LRS`; also `StandardSSD_LRS` or `Standard_LRS`                                                          |
| `VM_DISK_CONTROLLER`           | `NVMe`; also `SCSI` when compatible                                                                              |
| `VM_ACCELERATED_NETWORKING`    | `true`; accepts `false`                                                                                          |
| `VM_VNET_PREFIX`               | `172.16.0.0/16`                                                                                                  |
| `VM_SUBNET_PREFIX`             | `172.16.0.0/24`; must fit within the VNet                                                                        |
| `VM_RDP_SOURCE`                | Refreshed by the preprovision hook to the current public IPv4 `/32`; merged with additional sources for TCP 3389 |
| `VM_RDP_ADDITIONAL_SOURCES`    | `[]`; JSON array of retained trusted IPv4 addresses/CIDRs, maintained by the RDP append scripts                  |
| `VM_PYTHON_VERSION`            | `3.14`; a Python minor version                                                                                   |
| `VM_TAGS`                      | `{}`; the azd environment tag takes precedence                                                                   |

Check compatibility when changing the region, size, zone, image, disk controller, or accelerated networking. Image `latest` applies to new VMs, not OS upgrades. `VM_NAME` and `VM_COMPUTER_NAME` are outputs; use the `_OVERRIDE` variables for inputs.

Example overrides for Bash or PowerShell 7:

```console
azd env set VM_OS_DISK_SIZE_GB 256
azd env set VM_ZONE ""
azd env set VM_TAGS '{"purpose":"agent-box"}'
```

### Foundry models and regions

Model deployments inherit their parent Foundry account's region. The template groups models by the selected region and creates an `AIServices` account and child project for each group, in the same resource group as the VM. Account/project managed identities are enabled. No MAI model is provisioned.

| Bicep parameter | azd environment variable | Allowed regions |
| --- | --- | --- |
| `gptImage25Region` | `GPT_IMAGE_25_REGION` | `eastus2`, `polandcentral`, `swedencentral`, `uaenorth`, `westus3` |
| `gpt6AstraRegion` | `GPT_6_ASTRA_REGION` | `australiaeast`, `brazilsouth`, `canadacentral`, `canadaeast`, `centralus`, `eastus`, `eastus2`, `francecentral`, `germanywestcentral`, `italynorth`, `japaneast`, `koreacentral`, `northcentralus`, `norwayeast`, `polandcentral`, `southafricanorth`, `southcentralus`, `southeastasia`, `southindia`, `spaincentral`, `swedencentral`, `switzerlandnorth`, `switzerlandwest`, `uaenorth`, `uksouth`, `westeurope`, `westus`, `westus3` |
| `claudeOpus55Region` | `CLAUDE_OPUS_55_REGION` | `centralus`, `eastus`, `eastus2`, `northcentralus`, `southcentralus`, `swedencentral`, `westcentralus`, `westus`, `westus3` |

All three region parameters are required and constrained with Bicep `@allowed`. The VM's `location` is also constrained to its seven documented regions. `westus2` is a valid VM location, **not** an allowed location for these model deployments. These model allowlists apply to **Global Standard**, not other SKUs, and describe resource placement rather than a guarantee that inference stays in that region. Availability can change; the lists reflect the catalog checked in October 2026.

| Deployment name | Model version | Capacity variable | Default capacity |
| --- | --- | --- | --- |
| `gpt-image-2.5-sunburst` | `2026-09-08` | `GPT_IMAGE_25_CAPACITY` | `3` |
| `gpt-6-astra` | `2026-09-03` | `GPT_6_ASTRA_CAPACITY` | `10` |
| `claude-opus-5-5` | `2` (Azure-hosted) | `CLAUDE_OPUS_55_CAPACITY` | `10` |

Versions are pinned with automatic upgrades disabled. Capacities are positive whole numbers in **model-specific Azure deployment units**, not a universal tokens-per-minute value. Supply them as decimal text; invalid numbers fail rather than silently reverting to a default. Model quota and capacity limits still apply.

Claude also requires `CLAUDE_ORGANIZATION_NAME`, a two-letter `CLAUDE_COUNTRY_CODE`, and `CLAUDE_INDUSTRY`. Supported industry values are `technology`, `finance`, `healthcare`, `education`, `retail`, `manufacturing`, `government`, `media`, and `other`. azd prompts for missing attestation values.

For example, use one Foundry account/project in `eastus2` while keeping the VM in `westus2`:

```console
azd env set AZURE_LOCATION westus2
azd env set GPT_IMAGE_25_REGION eastus2
azd env set GPT_6_ASTRA_REGION eastus2
azd env set CLAUDE_OPUS_55_REGION eastus2
```

Set these before provisioning, and change any model region independently. Reusing a region reuses its deterministically named account/project. **Changing a model region is not a move:** incremental provisioning creates the new regional resources/deployment but does not delete the old ones. Review and explicitly clean up unused deployments/accounts after verifying the replacement; they can continue consuming quota.

### Foundry connection outputs

`azd env get-values` includes `FOUNDRY_RESOURCES`, a JSON array mapping each selected region to its account name/resource ID, project name/resource ID, and project endpoint. Model-specific outputs route to the corresponding regional account:

| Model | API base URL output | Deployment name output |
| --- | --- | --- |
| GPT-Image 2.5 Sunburst | `GPT_IMAGE_25_BASE_URL` | `GPT_IMAGE_25_DEPLOYMENT_NAME` |
| GPT-6 Astra | `GPT_6_ASTRA_BASE_URL` | `GPT_6_ASTRA_DEPLOYMENT_NAME` |
| Claude Opus 5.5 | `CLAUDE_OPUS_55_BASE_URL` | `CLAUDE_OPUS_55_DEPLOYMENT_NAME` |

The GPT URLs use the OpenAI `/openai/v1/` API; Claude uses the Anthropic `/anthropic` API. The accounts expose authenticated public endpoints and allow API keys for BYOK. **No API keys are retrieved, written to VM settings, or exported by the template.** Retrieve a key through the account's Azure portal page and store it only in the client credential store. Entra ID inference requires appropriate data-plane RBAC; this template does not grant those roles.

For the Copilot app, add the compatible Foundry/model provider in **Settings > Model providers** using the corresponding endpoint, deployment name, and credentials. GPT-6 Astra and Claude are agent-session models; provisioning an image model does not by itself add image-generation tooling to Copilot.

## First sign-in and tools

1. Connect using the local `azureuser` account and retain working fallback access.
2. Sign in locally as `enrolleduser` with the same initial password. The elevated `\AgentBox\InstallDevTools` task starts automatically.
3. Wait for setup to finish, then open a new terminal. Provisioning registers the task; it does not wait for this future sign-in.

WinGet installs **PowerShell 7, Git, uv, Azure CLI, azd, gh, GitHub Copilot CLI, and GitHub Copilot app** machine-wide. Existing tool versions are retained.

**NVM for Windows** is installed separately from the [latest stable GitHub release of `nvm-windows/nvm`](https://github.com/nvm-windows/nvm/releases/latest), not from WinGet. On a fresh installation, the script resolves GitHub's latest non-draft, non-prerelease release at runtime, selects its x64 setup executable, verifies its SHA-256 digest and Authenticode signature, and installs it silently for the signed-in user. No NVM release version is pinned. An existing NVM installation is verified and retained rather than automatically upgraded. Setup preserves any standalone Node.js installation and does not restart Windows automatically.

NVM installs and activates the latest **64-bit Node.js LTS**. uv installs the latest **Python 3.14** patch known to its catalog, without replacing unrelated Python defaults. Azure/GitHub authentication and Copilot onboarding remain manual.

Setup logs are in `C:/ProgramData/AgentBox/Logs/DevTools`. Failures leave the task enabled for a later sign-in; success disables it. To retry manually, run elevated PowerShell as the secondary administrator:

```powershell
& 'C:/ProgramData/AgentBox/Scripts/Install-DevTools.ps1'
```

The script accepts `-PythonVersion` for a minor-version override. Changes to the installer, target user, or configured Python version re-enable setup on redeployment.

## Intune enrollment

While signed in as `enrolleduser`, open elevated PowerShell and run:

```powershell
& 'C:/ProgramData/AgentBox/Scripts/Start-IntuneEnrollment.ps1' -TenantId '<INTUNE_TENANT_GUID>'
```

In the Windows Settings page, choose **Connect > Join this device to Microsoft Entra ID**, not ordinary work-account registration or MDM-only enrollment. Sign in to the Intune enrollment tenant and complete MFA. Confirm the organization before joining: `-TenantId` verifies the result, not the UI's tenant selection.

After joining or restarting, verify again:

```powershell
& 'C:/ProgramData/AgentBox/Scripts/Start-IntuneEnrollment.ps1' -TenantId '<INTUNE_TENANT_GUID>' -CheckOnly
```

**Entra join does not prove Intune enrollment.** Separately confirm the device record and successful check-in in the Intune admin center for the Intune enrollment tenant. The helper does not bypass tenant policies, remove existing management, or capture cloud credentials.

Azure resources remain in the hosting subscription. This is not Azure Virtual Desktop, and no `AADLoginForWindows` extension is installed. Do not clone an enrolled VM or issue Intune Wipe to an RDP-only VM.

## Development and troubleshooting

With azd, Azure CLI/Bicep, Python 3, Bash, jq, and PowerShell 7.3+ installed:

```console
python3 tests/validate.py
```

Local checks cover templates and isolated script behavior, including model/VM region constraints, shared and split Foundry placement, mocked IP lookups, Azure CLI allowlist updates, and both platform hooks in temporary environments, not actual Windows provisioning, enrollment, or model inference. API versions are Resource Groups `2025-04-01`, Compute `2026-04-01`, Network `2025-09-01`, Foundry accounts/projects `2025-06-01`, and model deployments `2025-10-01-preview` (the documented Claude Marketplace attestation API). Older Bicep clients may report missing service schemas (`BCP081`); also use the Azure preview.

For guest-setup failures, inspect the deployment status of these Azure VM child resources, defined in [infra/resources.bicep](infra/resources.bicep), in order:

1. Managed Run Command **`stage-guest-scripts`**, which runs [scripts/Stage-GuestScripts.ps1](scripts/Stage-GuestScripts.ps1).
2. Custom Script Extension **`configure-guest`**, which runs [scripts/Initialize-Guest.ps1](scripts/Initialize-Guest.ps1).

These are Azure resource names, not repository filenames. Failed deployments can leave resources behind. Existing disabled or non-administrator accounts require manual review rather than automatic elevation or password resets.

## Cleanup

Select the intended environment and back up needed data before running:

```console
azd down --force --purge
```

**This deletes the environment's VM, OS disk, Foundry accounts/projects, and model deployments**, including older regional resources left in the same resource group after region changes. Do not target the original source resources or another environment.

## References

- [azd environment configuration](https://learn.microsoft.com/azure/developer/azure-developer-cli/manage-environment-variables)
- [Windows 11 Azure licensing and local administrator requirements](https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment)
- [Windows Entra join and MDM enrollment](https://learn.microsoft.com/windows/client-management/mdm-enrollment-of-windows-devices#use-the-settings-app)
- [Foundry model regional availability](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability)
- [Claude model regional availability](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-from-partners#region-availability-by-deployment-type)
- [Claude provisioning and Marketplace attestation](https://learn.microsoft.com/azure/developer/ai/how-to/deploy-claude-foundry)
