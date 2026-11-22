# Agent Box

Agent Box provisions a Windows 11 Enterprise development VM, a Bastion Developer connection, a NAT Gateway, and one Microsoft Foundry account/project with a `MAI-Image-2.7` deployment. No tool installation or user sign-in is automated.

## Requirements and defaults

- `azd` 1.35.1 or later and Azure CLI with Bicep support.
- Azure permissions to create resource groups, Compute, Network, VM Run Command, and Microsoft Foundry resources.
- Sufficient quota and capacity for the 64-vCPU VM, its disk, and the selected Foundry model deployment.
- Eligibility to run Windows 11 client software in Azure. The required Bicep parameter asks for an explicit confirmation.
- Azure CLI signed in with access to the azd environment's subscription.
- A VM region in the allowlist in [`infra/main.bicep`](infra/main.bicep). The preprovision hook also queries the configured VM image, size, and availability zone for the subscription.

| Setting | Default |
| --- | --- |
| VM | `Standard_D64ds_v7` |
| Image | `microsoftwindowsdesktop:windows-11:win11-26h2-ent:latest` |
| Boot security | Trusted Launch, Secure Boot, and vTPM |
| Local administrator | `agentboxuser` |
| OS disk | 127 GiB Premium SSD |
| Network access | Bastion Developer; no VM public IP or public RDP rule |
| Outbound internet | NAT Gateway |
| Automatic shutdown | Daily at 00:00 Korea Standard Time |

The VM and Foundry regions are independent. The Foundry region is limited to `eastus`, `swedencentral`, `westeurope`, and `westus`, the overlap between the image model catalog and Speech model availability checked on 2026-11-21. This snapshot does not guarantee deployment or local inference. Confirm current model availability and quota before provisioning. `MAI_FOUNDRY_REGION` is saved in the azd environment and can be set explicitly to one of these regions; the template does not substitute a different model when deployment is unavailable.

## Provision

Run from the `agent-box` directory:

```console
cd agent-box
azd auth login
az login
azd env new <environment-name> --location <azure-region>
azd up
```

azd prompts for the secure Windows administrator password, Windows client license confirmation, and other missing values. To change the local administrator name before provisioning, run `azd env set VM_ADMIN_USERNAME <username>`; otherwise it defaults to `agentboxuser`. For non-interactive provisioning, set `MAI_FOUNDRY_REGION` and, after confirming eligibility, run `azd env config set infra.parameters.confirmWindowsClientLicense true`. The former `CONFIRM_WINDOWS_CLIENT_LICENSE` environment variable is no longer used.

The initial region picker lists regions where Bastion Developer is documented and both the default VM image and VM size appeared in Azure CLI lookups on 2026-11-22. The SKU lookup included subscription-restricted entries and did not filter regions by availability zone. A listed SKU does not guarantee availability for a particular subscription. This snapshot was taken with one subscription, may omit other supported regions, and also applies when a custom image or VM size is configured.

Before provisioning, the hook checks the image and VM size in the selected subscription and chooses the lowest-numbered unrestricted availability zone. Set `VM_ZONE` explicitly with `azd env set VM_ZONE <zone>` to select a different supported zone. The chosen value is saved in the azd environment and reused on subsequent runs; to select automatically again, clear it with `azd env set VM_ZONE ""`. If a previously deployed VM is recorded in the environment, its existing zone is verified and retained, and a conflicting override stops provisioning. A missing or restricted zone, incomplete zone information, or a failed lookup also stops provisioning; non-zonal deployment is not supported by this template. The check cannot guarantee quota or capacity. If a lookup fails, check Azure CLI authentication and subscription access.

You can override supported settings with `azd env set`. Numeric and boolean values are accepted as strings and validated during deployment. See [`infra/main.bicep`](infra/main.bicep) and [`infra/main.parameters.json`](infra/main.parameters.json) for the full input mapping.

Resource names follow the azd starter pattern: `rg-{environmentName}` for the resource group and type-specific prefixes such as `vm-`, `vnet-`, and `nsg-` followed by a token derived from the subscription, environment, and VM region. The Foundry account and project use the same token followed by the Foundry region, for example `cogsvc-{resourceToken}-eastus`. Changing the VM region changes the token; changing the Foundry region changes its name suffix. VM and Windows computer name overrides remain available.

## Connect and install tools

After provisioning, connect in Azure portal at **Virtual machines > your VM > Connect > Bastion**. Sign in as `.\<username>` using the configured local administrator name (default `agentboxuser`) and the password entered during provisioning. Open PowerShell as administrator under that same account and run:

```powershell
& "$HOME\scripts\install-vm-tools.ps1"
```

The installer displays numbered stages and status messages, and asks before each installation and setup change. To approve all listed actions and package terms in one run:

```powershell
& "$HOME\scripts\install-vm-tools.ps1" -Yes
```

Windows PowerShell 5.1 prepares WinGet and PowerShell 7.x, then reruns the installer in PowerShell 7.x. If a restart is requested, restart Windows manually and rerun the command. The installer does not authenticate Azure or GitHub tools, sign in to the Copilot app, launch Docker Desktop, create the first Ubuntu user, or automatically reboot Windows. Logs are written below `C:\ProgramData\AgentBox\Logs\DevTools`: `install.log` contains the transcript, and major installation and verification commands have separate `command-*.stdout.log` and `command-*.stderr.log` files.

| Group | Installs |
| --- | --- |
| Package manager | WinGet |
| Windows tooling | PowerShell 7 |
| Windows features | WSL2 platform, Ubuntu on WSL2 |
| .NET SDKs | .NET 10 SDK and .NET 11 SDK side by side |
| JavaScript | nvm-windows and the latest stable Node.js LTS available when the installer runs |
| Python | uv and the latest Python 3.14 patch available to uv |
| Containers | Docker Desktop configured for its WSL2 backend |
| Source control and GitHub | Git, GitHub CLI (`gh`), GitHub Copilot CLI |
| Azure | Azure CLI and Azure Developer CLI (`azd`) |
| Editor and app | Visual Studio Code and the official GitHub Copilot app for Windows |

Existing tools and unrelated Python/Node installations are preserved. The installer uses the stable nvm-windows 2.x WinGet package and does not replace an existing nvm 1.x installation. The Copilot app uses the official `github/app` x64 MSI and a valid GitHub Authenticode signature; the release SHA-256 digest is checked when GitHub publishes one.

For Copilot CLI, the installer checks `copilot --version` before and after installation, preserving a working CLI even if WinGet does not list it. A pending Windows restart stops installation and must be completed manually.

Python installation is attempted even if Node.js setup fails; the installer still reports the Node.js failure. The Python patch version is the latest available in the installed uv release's download catalog. If no conflicting uv-bin executable exists, the installer uses uv's experimental `--default` option to create `python.exe` even when another Python command takes precedence. It then reports any command or PATH conflict for manual resolution without changing PATH order. Use `uv python list --only-installed` to check uv-managed installations.

The installer preserves existing PATH entries and their order. When needed and there is no conflict, it asks before appending the runtime directory to the signed-in user's PATH (`-Yes` approves this); it never changes the system PATH for runtime priority. A conflicting `node` or `python`, including a WindowsApps alias, must be resolved manually before activation. Existing terminals may need to be reopened or the user signed out and back in. Previous versions of this installer may already have modified the system PATH; this version does not undo those changes.

The repository's installer is a template populated with the configured administrator name during deployment. Use the staged file rather than executing the raw repository file directly.

### Manual post-install checks

After the script completes:

1. Restart Windows if requested, then rerun the installer until it reports successful verification.
2. Run `wsl -d Ubuntu` to create the first Linux user.
3. Start Docker Desktop, complete its first-run setup and terms, and verify Linux containers.
4. Sign in to the Copilot app and authenticate the Azure/GitHub CLIs as needed.

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

## Cleanup

Back up data first. From the `agent-box` directory, remove only the intended azd environment:

```console
azd down --environment <environment-name>
```

Stopping the VM does not remove charges for retained disks, the NAT Gateway, or public IP resources.
