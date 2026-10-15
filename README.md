# Agent Box

Provision a standalone Windows 11 Enterprise development VM with Azure Developer CLI (`azd`) and Bicep. Guest setup creates a local administrator, installs developer tools at first sign-in, and provides a helper for manual Intune enrollment.

- **Azure hosting tenant:** the Microsoft Entra tenant associated with the VM's Azure subscription.
- **Intune enrollment tenant:** the tenant the Windows guest joins for Intune management. It can differ from the hosting tenant.

**The default VM has 64 vCPUs and 256 GiB RAM and is relatively expensive. Public RDP is blocked until you configure a trusted source.**

## Prerequisites

- `azd` **1.35.1 or later**. The deployment machine does not need Windows.
- Azure permissions for resource groups, Compute/Network resources, VM Run Commands, and extensions; sufficient regional and Ddsv7-family quota for 64 vCPUs; and compatible capacity and policies.
- Qualifying Windows client virtualization rights. Intune licensing alone is not sufficient.
- For enrollment: an account in the Intune enrollment tenant with the required Intune/Entra licenses, device-join permission, MDM user scope, and enrollment-policy permissions.

## Deploy

Replace the uppercase placeholders and choose a unique environment name:

```console
azd auth login --tenant-id <HOSTING_TENANT_GUID>
azd env new agentbox-dev --subscription <HOSTING_SUBSCRIPTION_GUID> --location westus2

# Optional: allow RDP from your trusted public IPv4 address only.
azd env set VM_RDP_SOURCE "<TRUSTED_PUBLIC_IPV4>/32"

azd provision --preview
azd provision
azd env get-value VM_RDP_ENDPOINT
```

`--preview` is read-only; `azd provision` creates billable resources. Do not allow RDP from `*` or `0.0.0.0/0`. There are no application services, so `azd deploy` is unnecessary.

Each environment gets its own resource group, VM, OS disk, VNet/subnet, NIC, NSG, and static public IP. Trusted Launch, Secure Boot, vTPM, automatic Windows updates, and managed boot diagnostics are enabled. A managed Run Command stages scripts; a Custom Script Extension creates/verifies the secondary administrator and registers its tools task.

Reusing an environment updates its resources. Existing environments retain their saved location; changing defaults does not migrate a deployed VM.

### Passwords

Leave `VM_ADMIN_PASSWORD` unset for azd's secure prompt. Supply a 12-123-character password meeting Azure/Windows requirements. It initializes both local accounts; later changes are not synchronized, and redeployment does not reset the secondary account.

For automation, inject the password from a secret store into the azd process. **Do not store it with `azd env set` or commit credentials.** azd retains prompted secrets in its local user vault; protect its profile, `.azure` state, and deployment caches. Azure secure parameters and protected extension settings do not hide runtime secrets from administrators inside the VM.

## Configuration

Use `azd env set NAME VALUE` to override settings and `azd env unset NAME` to restore optional defaults. Full constraints are in [infra/main.bicep](infra/main.bicep).

| Variable | Default / meaning |
| --- | --- |
| `AZURE_ENV_NAME` | Set by `azd env new` |
| `AZURE_LOCATION` | `westus2` |
| `VM_NAME_PREFIX` | `agentbox` |
| `VM_NAME_OVERRIDE` | Environment-derived VM name |
| `VM_COMPUTER_NAME_OVERRIDE` | Environment-derived Windows name; maximum 15 characters |
| `VM_SIZE` | `Standard_D64ds_v7` |
| `VM_ZONE` | `1`; empty means regional |
| `VM_IMAGE_PUBLISHER` | `microsoftwindowsdesktop` |
| `VM_IMAGE_OFFER` | `windows-11` |
| `VM_IMAGE_SKU` | `win11-26h2-ent`, single-session |
| `VM_IMAGE_VERSION` | `latest`; accepts a published version |
| `VM_ADMIN_USERNAME` | `azureuser` |
| `VM_ENROLLMENT_ADMIN_USERNAME` | `enrolleduser`; must differ from the initial account |
| `VM_ADMIN_PASSWORD` | Required secure input |
| `VM_OS_DISK_SIZE_GB` | `127`; range 127-4095 |
| `VM_OS_DISK_TYPE` | `Premium_LRS`; also `StandardSSD_LRS` or `Standard_LRS` |
| `VM_DISK_CONTROLLER` | `NVMe`; also `SCSI` when compatible |
| `VM_ACCELERATED_NETWORKING` | `true`; accepts `false` |
| `VM_VNET_PREFIX` | `172.16.0.0/16` |
| `VM_SUBNET_PREFIX` | `172.16.0.0/24`; must fit within the VNet |
| `VM_RDP_SOURCE` | Empty; otherwise a trusted IPv4 address/CIDR for TCP 3389 |
| `VM_PYTHON_VERSION` | `3.14`; a Python minor version |
| `VM_TAGS` | `{}`; the azd environment tag takes precedence |

Check compatibility when changing the region, size, zone, image, disk controller, or accelerated networking. Image `latest` applies to new VMs, not OS upgrades. `VM_NAME` and `VM_COMPUTER_NAME` are outputs; use the `_OVERRIDE` variables for inputs.

Example overrides for Bash or PowerShell 7:

```console
azd env set VM_OS_DISK_SIZE_GB 256
azd env set VM_ZONE ""
azd env set VM_TAGS '{"purpose":"agent-box"}'
```

## First sign-in and tools

1. Connect using the local `azureuser` account and retain working fallback access.
2. Sign in locally as `enrolleduser` with the same initial password. The elevated `\AgentBox\InstallDevTools` task starts automatically.
3. Wait for setup to finish, then open a new terminal. Provisioning registers the task; it does not wait for this future sign-in.

WinGet installs **PowerShell 7, Git, NVM for Windows, uv, Azure CLI, azd, gh, GitHub Copilot CLI, and GitHub Copilot app**. NVM is user-scoped; the other tools are machine-wide. Existing tool versions are retained.

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

With Azure CLI/Bicep, Python 3, and PowerShell 7 installed:

```console
python3 tests/validate.py
```

Local checks cover templates and isolated script behavior, not actual Windows provisioning or enrollment. API versions are Resource Groups `2025-04-01`, Compute `2026-04-01`, and Network `2025-09-01`. Older Bicep clients may report missing Compute schemas (`BCP081`); also use the Azure preview.

For guest-setup failures, inspect `stage-guest-scripts` first, then `configure-guest`. Failed deployments can leave resources behind. Existing disabled or non-administrator accounts require manual review rather than automatic elevation or password resets.

## Cleanup

Select the intended environment and back up needed data before running:

```console
azd down
```

**This deletes the environment's VM and OS disk.** Do not target the original source resources or another environment.

## References

- [azd environment configuration](https://learn.microsoft.com/azure/developer/azure-developer-cli/manage-environment-variables)
- [Windows 11 Azure licensing and local administrator requirements](https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment)
- [Windows Entra join and MDM enrollment](https://learn.microsoft.com/windows/client-management/mdm-enrollment-of-windows-devices#use-the-settings-app)
