# Agent Box

[Repository template guide](../README.md)

Agent Box provisions a Windows 11 Enterprise development VM with Bastion Developer access and a NAT Gateway. It also creates a Microsoft Foundry account and project with a `MAI-Image-2.7` deployment. Tool installation and user sign-in are manual.

## Default configuration

| Setting | Value |
| --- | --- |
| Image | `microsoftwindowsdesktop:windows-11:win11-26h2-ent:latest` |
| VM | `Standard_D64ds_v7` |
| OS disk | Premium SSD, 127 GiB |
| Boot security | Trusted Launch, Secure Boot, vTPM |
| Windows login | Default `.\agentboxuser`, local administrator |
| Access | Bastion Developer in the Azure portal; no VM public IP or public RDP rule |
| Network | Internet access through NAT Gateway |
| Automatic shutdown | Daily at 00:00 Korea Standard Time |

The VM and Foundry regions are independent. The Foundry region is limited to `eastus`, `swedencentral`, `westeurope`, and `westus`: the overlap between the image model catalog and Speech model availability checked on 2026-11-21. This snapshot does not guarantee deployment or local inference. Confirm current model availability and quota before provisioning.

## Prerequisites

- Azure Developer CLI (`azd`) 1.35.1 or later, and Azure CLI with Bicep support.
- Azure permissions to create resource groups, Compute, Network, VM Run Command, and Microsoft Foundry resources. Azure CLI must be signed in with access to the azd environment's subscription.
- Sufficient quota and capacity for the 64-vCPU VM, its disk, and the Foundry model deployment.
- Eligibility to run Windows 11 client software in Azure. A required Bicep parameter asks for explicit confirmation.
- A VM region in the allowlist in [`infra/main.bicep`](infra/main.bicep). The preprovision hook checks the configured VM image, size, and availability zone for the subscription.

## Deploy

1. Change to the `agent-box` directory.

   ```bash
   cd agent-box
   ```

1. If running the azd CLI in the Copilot app terminal, set the environment variable as follows.

   ```bash
   # zsh/bash
   export AZD_NON_INTERACTIVE=false
   ```

   ```powershell
   # PowerShell
   $env:AZD_NON_INTERACTIVE = 'false'
   ```

1. Sign in to Azure.

   ```bash
   azd auth login
   az login
   ```

1. Create an azd environment.

   ```bash
   azd env new <environment-name> --location <azure-region>
   ```

1. Optionally, configure the environment before deployment.

   To change the local administrator name, run `azd env set VM_ADMIN_USERNAME <username>`.

   To set the independent Foundry region, run `azd env set MAI_FOUNDRY_REGION <region>` with one of the regions listed above. The value is saved in the azd environment. The template does not substitute a different model when deployment is unavailable.

   For non-interactive provisioning, set `MAI_FOUNDRY_REGION` and, after confirming Windows client eligibility, run `azd env config set infra.parameters.confirmWindowsClientLicense true`. The former `CONFIRM_WINDOWS_CLIENT_LICENSE` environment variable is no longer used.

1. Start the deployment.

   ```bash
   azd up
   ```

   azd prompts for the secure Windows administrator password, Windows client license confirmation, and other missing values.

Override other supported settings with `azd env set`. Numeric and boolean values are accepted as strings and validated during deployment. See [`infra/main.bicep`](infra/main.bicep) and [`infra/main.parameters.json`](infra/main.parameters.json) for the full input mapping.

The initial region picker uses a snapshot of regions where Bastion Developer is documented and both the default VM image and VM size appeared in Azure CLI lookups on 2026-11-22. The SKU lookup included subscription-restricted entries and did not filter regions by availability zone. The snapshot was taken with one subscription, may omit other supported regions, and also applies when a custom image or VM size is configured. A listed SKU does not guarantee availability for a particular subscription.

Before provisioning, the hook checks the image and VM size in the selected subscription and chooses the lowest-numbered unrestricted availability zone. To select a different supported zone, run `azd env set VM_ZONE <zone>`. The selected value is saved in the azd environment and reused on subsequent runs. To select automatically again, clear it with `azd env set VM_ZONE ""`.

If a previously deployed VM is recorded in the environment, the hook verifies and retains its existing zone. A conflicting override stops provisioning. A missing or restricted zone, incomplete zone information, or a failed lookup also stops provisioning; this template does not support non-zonal deployment. The check cannot guarantee quota or capacity. If a lookup fails, check Azure CLI authentication and subscription access.

Resource names follow the azd starter pattern: `rg-{environmentName}` for the resource group and type-specific prefixes such as `vm-`, `vnet-`, and `nsg-` followed by a token derived from the subscription, environment, and VM region. The Foundry account and project use the same token followed by the Foundry region, for example `cogsvc-{resourceToken}-eastus`. Changing the VM region changes the token; changing the Foundry region changes its name suffix. VM and Windows computer name overrides remain available.

## Sign in and install tools

1. Find the Windows login username in the `azd provision` or `azd up` output. In the Azure portal, select **Connect > Bastion** for the VM, then sign in with that local administrator account (default: `.\agentboxuser`) and the password entered during provisioning.
1. **Run PowerShell as administrator** under the same account.
1. Run the following command and approve the requested actions.

   ```powershell
   & "$HOME\scripts\install-vm-tools.ps1"
   ```

   By default, the installer asks for approval for each installation and setup change. Adding `-Yes` approves all listed actions and package terms in one run.

   ```powershell
   & "$HOME\scripts\install-vm-tools.ps1" -Yes
   ```

1. If prompted to restart, save your work, restart the VM manually, and rerun the same command.

The repository's installer is a template populated with the configured administrator name during deployment. Use the staged file rather than executing the raw repository file directly.

Windows PowerShell 5.1 prepares WinGet and PowerShell 7.x, then reruns the installer in PowerShell 7.x. A pending Windows restart stops installation and must be completed manually. The installer does not automatically reboot Windows, authenticate Azure or GitHub tools, sign in to the Copilot app, launch Docker Desktop, or create the first Ubuntu user.

Logs are written below `C:\ProgramData\AgentBox\Logs\DevTools`. The `install.log` file contains the transcript; major installation and verification commands have separate `command-*.stdout.log` and `command-*.stderr.log` files.

### Tools installed

The installer follows the order below and stops when a restart is required.

| Group | Tool | Installation and verification |
| --- | --- | --- |
| 1. Installation prerequisites | WinGet | Register or install App Installer |
| 1. Installation prerequisites | PowerShell | Stable 7.x release |
| 2. Windows features | WSL2 platform | Install without a distribution using `wsl.exe --install --no-distribution`. Restart manually when requested |
| 2. Windows features | Ubuntu | Register for the signed-in administrator account after WSL2 installation |
| 3. Runtimes and SDKs | .NET 10 SDK | `Microsoft.DotNet.SDK.10`, stable 10.x release |
| 3. Runtimes and SDKs | .NET 11 SDK | `Microsoft.DotNet.SDK.11`, stable 11.x release. Installed alongside .NET 10 |
| 3. Runtimes and SDKs | uv | `astral-sh.uv` |
| 3. Runtimes and SDKs | nvm-windows, Node.js | Stable nvm-windows 2.x package and the latest stable Node.js LTS available when the installer runs |
| 3. Runtimes and SDKs | Python | uv and the latest Python 3.14 patch available to uv |
| 4. Containers | Docker Desktop | Install with the WSL2 backend. First launch and terms review are manual |
| 5. GitHub tools | Git | `Git.Git` |
| 5. GitHub tools | GitHub CLI | `GitHub.cli`, 2.45.0 or later |
| 5. GitHub tools | GitHub Copilot CLI | `GitHub.Copilot`. Verify with `copilot --version` |
| 6. Azure tools | Azure CLI | `Microsoft.AzureCLI` |
| 6. Azure tools | azd | `Microsoft.Azd` |
| 7. Editors and apps | VS Code | `Microsoft.VisualStudioCode` |
| 7. Editors and apps | GitHub Copilot app | Official `github/app` x64 MSI. Verify the GitHub Authenticode signature and the release SHA-256 digest when published |

Existing tools and unrelated Python and Node installations are preserved. The installer does not replace an existing nvm 1.x installation. For Copilot CLI, it checks `copilot --version` before and after installation, preserving a working CLI even if WinGet does not list it.

Python installation is attempted even if Node.js setup fails; the installer still reports the Node.js failure. The Python patch version is the latest available in the installed uv release's download catalog. If no conflicting uv-bin executable exists, the installer uses uv's experimental `--default` option to create `python.exe` even when another Python command takes precedence. It then reports any command or PATH conflict for manual resolution without changing PATH order. Use `uv python list --only-installed` to check uv-managed installations.

The installer preserves existing PATH entries and their order. When needed and there is no conflict, it asks before appending the runtime directory to the signed-in user's PATH (`-Yes` approves this). It never changes the system PATH for runtime priority. A conflicting `node` or `python`, including a WindowsApps alias, must be resolved manually before activation. Existing terminals may need to be reopened or the user signed out and back in. Previous versions of this installer may already have modified the system PATH; this version does not undo those changes.

### Manual post-installation steps

1. Restart Windows if requested, then rerun the installer until it reports successful verification.
1. Run `wsl -d Ubuntu` to create the first Linux user.
1. Start Docker Desktop, complete its first-run setup and terms, and verify Linux containers.
1. Sign in to the Copilot app and authenticate the Azure/GitHub CLIs as needed.

WSL2, Ubuntu, and Docker Desktop are installed by the script, but their operation must be verified manually on the deployed VM. Local tests do not perform these post-deployment checks.

Docker Desktop is free for personal use, education, non-commercial open source, and qualifying small businesses. Commercial use in an organization with **250 or more employees or more than USD 10 million in annual revenue** requires a paid subscription. Review the [Docker Desktop subscription terms](https://www.docker.com/legal/docker-subscription-service-agreement/).

## Foundry outputs

The template creates one `AIServices` account and project in `MAI_FOUNDRY_REGION`, then deploys `MAI-Image-2.7` as `mai-image-2.7` using the Microsoft format, version `2026-11-02`, and `GlobalStandard` SKU. Capacity defaults to `1` and is configured with `MAI_IMAGE_CAPACITY`.

The image deployment name can be changed with `MAI_IMAGE_DEPLOYMENT_NAME_OVERRIDE`; this changes the deployment name, not the underlying image model.

`MAI-Voice-2.1` and `MAI-Transcribe-2` are Speech API model identifiers, not model deployments created by this template. They can be changed with `MAI_VOICE_MODEL_OVERRIDE` and `MAI_TRANSCRIBE_MODEL_OVERRIDE`; these values are output as provided and are not validated against Speech model availability. The Speech endpoint is the account's `.cognitiveservices.azure.com` endpoint; the Speech region is `MAI_FOUNDRY_REGION`. See the [MAI Voice](https://learn.microsoft.com/azure/ai-services/speech-service/mai-voices) and [MAI Transcribe](https://learn.microsoft.com/azure/ai-services/speech-service/mai-transcribe) usage guides for API formats and current availability.

Useful deployment outputs include:

| Output | Purpose |
| --- | --- |
| `AZURE_RESOURCE_GROUP`, `AZURE_VM_NAME`, `AZURE_VM_ID` | VM and resource group identity |
| `AZURE_BASTION_NAME` | Bastion Developer resource |
| `FOUNDRY_ACCOUNT_NAME`, `FOUNDRY_ACCOUNT_ID` | Foundry account identity |
| `FOUNDRY_PROJECT_NAME`, `FOUNDRY_PROJECT_ENDPOINT` | Foundry project connection |
| `MAI_IMAGE_ENDPOINT`, `MAI_IMAGE_DEPLOYMENT_NAME` | Image model endpoint and deployment |
| `AZURE_SPEECH_ENDPOINT`, `AZURE_SPEECH_REGION` | Speech API endpoint and region |
| `MAI_VOICE_MODEL`, `MAI_TRANSCRIBE_MODEL` | Speech model identifiers |

The template does not retrieve or emit account keys. It does not configure model inference permissions or test an inference request.

## Clean up resources

Back up data first. From the `agent-box` directory, remove only the intended azd environment:

```console
azd down --environment <environment-name>
```

Stopping the VM does not remove charges for retained disks, the NAT Gateway, or public IP resources.
