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

1. Start the deployment.

   ```bash
   azd up
   ```

   azd prompts for the secure Windows administrator password, Windows client license confirmation, and other missing values.

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

If no conflicting uv-bin executable exists, the installer uses uv's experimental `--default` option to create `python.exe` even when another Python command takes precedence. For the default Python version, it runs:

```powershell
uv.exe python install 3.14 --default --no-config --no-progress
```

### Manual post-installation steps

1. Restart Windows if requested, then rerun the installer until it reports successful verification.
1. Run `wsl -d Ubuntu` to create the first Linux user.
1. Start Docker Desktop, complete its first-run setup and terms, and verify Linux containers.
1. Sign in to the Copilot app and authenticate the Azure/GitHub CLIs as needed.

## Foundry outputs

The template deploys the `MAI-Image-2.7` image model. It outputs Speech API model identifiers, defaulting to `MAI-Voice-2.1` and `MAI-Transcribe-2`, but does not deploy those models.

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
