# Windows 11 Development VM

[English](README.md) | [한국어](README.ko.md)

[Repository template guide](../README.md)

`azure.yaml` creates a Windows 11 VM and copies the installation helpers to `$HOME/scripts` for the specified local administrator (default: `appmoduser`). Install the tools after signing in to the VM.

## Default configuration

| Setting | Value |
| --- | --- |
| Image | `MicrosoftWindowsDesktop:windows-11:win11-26h2-ent:latest`, x64 Gen2 |
| Region | Selected at deployment; `koreacentral` recommended |
| VM | `Standard_D8s_v5`, 8 vCPU, 32 GiB |
| OS disk | Premium SSD, 256 GiB |
| Boot security | Trusted Launch, Secure Boot, vTPM |
| Windows login | Default `.\appmoduser`, local administrator, user-supplied password |
| Access | Bastion Developer in the Azure portal |
| Network | No public IP on the VM; internet access through NAT Gateway |
| Automatic shutdown | Deallocated daily at 00:00 Korea Standard Time by default |

`latest` is the latest image for that SKU used for a new VM. It does not update an existing VM's image or switch to another SKU.

## Prerequisites

- [Azure subscription](https://aka.ms/azure/free)
- [`azd` CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- Azure CLI: `az login` must provide access to the azd environment's subscription.
- [License eligibility to use Windows client in Azure](https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment)

## Deploy

1. Change to the `appmod-box` directory.

   ```bash
   cd appmod-box
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

## Sign in and install tools

1. Find the Windows login username in the `azd provision` or `azd up` output. In the Azure portal, select **Connect > Bastion** for the VM, then sign in with that local administrator account (default: `.\appmoduser`) and the password entered during deployment.
1. **Run PowerShell as administrator**.
1. Run the following command and approve the requested actions.

   ```powershell
   & "$HOME/scripts/install-vm-tools.ps1"
   ```

   By default, the installer asks for approval for each item. Adding `-Yes` approves tool installation, terms acceptance (including WinGet package and source agreements), and configuration changes (including nvm configuration and Node.js activation) in one operation, and also permits non-interactive execution. The specified administrator account and administrator privileges are still required.

   ```powershell
   & "$HOME/scripts/install-vm-tools.ps1" -Yes
   ```

1. If prompted to restart, save your work, restart the VM manually, and rerun the same command.

### Tools installed

The installer follows the order below and stops when a restart is required.

| Group | Tool | Installation and verification |
| --- | --- | --- |
| 1. Installation tools | WinGet | Register or install App Installer |
| 1. Installation tools | PowerShell | Stable 7.x release. Existing versions are not updated automatically |
| 2. Windows features | WSL2 platform | Install without a distribution using `wsl.exe --install --no-distribution`. Restart manually after installation |
| 2. Windows features | Ubuntu | Register for the specified administrator account after WSL2 installation |
| 2. Windows features | MSMQ | Enable the Server feature and start the service. No queues or data are created |
| 3. Runtimes and SDKs | Visual C++ x64 runtime | Install `Microsoft.VCRedist.2015+.x64` and verify DLLs |
| 3. Runtimes and SDKs | .NET Framework | Check for runtime 4.8 or later; install 4.8.1 if absent |
| 3. Runtimes and SDKs | .NET 10 SDK | `Microsoft.DotNet.SDK.10`, stable 10.x release. Other major versions are retained |
| 3. Runtimes and SDKs | .NET 11 SDK | `Microsoft.DotNet.SDK.11`, stable 11.x release. Installed alongside .NET 10 |
| 3. Runtimes and SDKs | nvm-windows, Node.js | Stable nvm 2.x release and Node.js 22.x. Existing supported major versions are retained |
| 4. .NET Framework tools | Build Tools 2026 | Stable 18.x release. Web and .NET desktop build tools, 4.8 Targeting Pack, and SDK from [buildtools.vsconfig](scripts/buildtools.vsconfig) |
| 4. .NET Framework tools | IIS Express | Official Microsoft x64 MSI. Verify SHA-256 and Microsoft signature |
| 4. .NET Framework tools | SQL Server LocalDB | Official Microsoft SQL Server 2025 Express LocalDB x64 MSI. Verify SHA-256 and Microsoft signature. No databases or instances are created |
| 4. .NET Framework tools | Build and runtime tool verification | Verify the 4.8 Targeting Pack, MSBuild web build tools, IIS Express, and SQL Server LocalDB. No databases are created or initialized |
| 5. Databases and containers | PostgreSQL 18 client | Install and verify only `commandlinetools` from `PostgreSQL.PostgreSQL.18`. Add it to the user PATH after approval. No server, pgAdmin, or Stack Builder is installed, and no database is created |
| 5. Databases and containers | Docker Desktop | Install with the WSL2 backend. First launch and terms review are manual |
| 6. GitHub tools | Git | `Git.Git` |
| 6. GitHub tools | GitHub CLI | `GitHub.cli`, 2.45.0 or later |
| 6. GitHub tools | GitHub Copilot CLI | `GitHub.Copilot`. Verify with `copilot --version` |
| 7. Azure tools | Azure CLI | `Microsoft.AzureCLI` |
| 7. Azure tools | azd | `Microsoft.Azd` |
| 8. Editors and modernization tools | VS Code | `Microsoft.VisualStudioCode` |
| 8. Editors and modernization tools | GitHub Copilot app | Latest official stable x64 MSI from `github/app`. Verify SHA-256 and GitHub signature |
| 8. Editors and modernization tools | Modernize CLI | `GitHub.Copilot.modernization.agent`. Verify with `modernize --version` |

After installing the PostgreSQL 18 client, close Windows Terminal completely and reopen it to apply the PATH change. Run `psql --version` and verify that it reports 18.x.

If the Node.js path is not in PATH, the installer checks for conflicts and, with approval, appends it to the user PATH. The order of existing PATH entries is not changed.

### Manual post-installation steps

1. Start Docker Desktop, review the terms and WSL2 configuration, and use Linux containers.
1. Start Ubuntu from Windows Terminal and create a Linux user account.
1. Sign in to the GitHub Copilot app.

## Clean up resources

When finished, remove the environment's resources from the `appmod-box` directory on the PC used for deployment to prevent additional charges. Back up any needed data first.

```bash
azd down --environment appmod-dev
```
