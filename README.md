# Agent Box

An infrastructure-only Azure Developer CLI (`azd`) project for a new Windows 11
Enterprise VM. It reproduces the inspected VM's configuration without cloning
its disk, adopting its resource group, or copying its enrollment state.

The **Azure hosting tenant** is the Microsoft Entra tenant associated with the
subscription that hosts the VM and its Azure resources. The **Intune enrollment
tenant** is the tenant the Windows guest joins for Intune management. These can
be different tenants.

**The default VM is `Standard_D64ds_v7`: 64 vCPUs and 256 GiB RAM. It is relatively
expensive. Public RDP is blocked until you explicitly configure a trusted source.**

## What is provisioned

- A new, environment-specific resource group, VNet/subnet, NIC, NSG, and Standard
  static public IPv4 address.
- A zone-1 VM in West US 2, using the single-session
  `microsoftwindowsdesktop:windows-11:win11-26h2-ent:latest` image.
- Trusted Launch, Secure Boot, vTPM, NVMe, a 127-GiB Premium SSD OS disk,
  accelerated networking, automatic Windows updates, and managed boot diagnostics.
- A managed Run Command that stages the local project scripts with
  administrator/SYSTEM write permissions. It does not download or execute the
  enrollment or tool-installation helpers.
- One Custom Script Extension that creates/verifies the secondary administrator
  and registers its first-sign-in tools task.

The managed Run Command avoids putting large script bodies into a Windows
process command line. It completes before the short Custom Script Extension
command runs. No script-hosting storage account, public repository, azd hook,
managed identity, AVD infrastructure, or `AADLoginForWindows` extension is needed.

The resource declarations use Resource Groups `2025-04-01`, Compute
`2026-04-01`, and Network **pinned to `2025-09-01`** for published Bicep schema
support. Older Bicep clients can still report `BCP081` (types unavailable) for
the newer Compute APIs; Azure what-if is also needed. Read-only response properties, including
`enableVMAgentPlatformUpdates`, are not assigned. VM agent provisioning and
automatic Windows updates remain enabled through their writable settings.

## Prerequisites

- Azure Developer CLI **1.35.1 or later** on the deployment machine.
- Permission to create a resource group and its Compute/Network resources in the
  hosting subscription, including VM Run Command and extension resources.
- Available size/image/zone capacity, sufficient quota, and compatible Azure
  Policy in the selected region. The default VM needs another 64 vCPUs of
  regional and Ddsv7-family quota. Availability is not a capacity reservation.
- Qualifying Windows client virtualization rights. `Windows_Client` is declared
  on the VM; an Intune license alone does not establish these rights.
- For later enrollment, an account in the Intune enrollment tenant with the
  required Intune/Entra licensing, join permissions, MDM user scope, and
  enrollment-policy permissions.

The deployment machine does not need Windows or PowerShell. Guest setup uses
the VM's built-in Windows PowerShell 5.1. PowerShell 7 is installed later through
WinGet.

## Create a new environment

Authenticate to the **Azure hosting tenant**, not the Intune enrollment tenant
unless they happen to be the same:

```console
azd auth login --tenant-id <hosting-tenant-guid>
azd env new agentbox-dev --subscription <hosting-subscription-guid> --location westus2
```

Choose a distinct environment name for each independent VM. Names and Windows
computer names are deterministic within an environment, not based on a timestamp.
Reusing an environment updates its existing resources. Changing resource naming,
computer name, image family, or initial administrator after creation may require
a new environment; it is not a migration workflow.

Existing environments keep their saved `AZURE_LOCATION`; changing the template
default does not move deployed resources.

Configure any overrides, then review and provision:

```console
azd provision --preview
azd provision
```

These are deployment commands for you to run deliberately. `--preview` is a
read-only Azure what-if; the second command creates billable resources.
There are no application services, so `azd deploy` is not needed.

### Password handling

Leave `VM_ADMIN_PASSWORD` unset to receive azd's secure prompt. Supply a strong
12-123-character password that meets Azure/Windows requirements. The same input
initializes `azureuser` and the new `enrolleduser` account.

The Bicep input is `@secure()`, and the extension receives it only through
`protectedSettings`. Encoding protects command quoting, **not** the password by
itself. No password is included in outputs or staged script files.

azd saves prompted secrets in its local user vault and references them from its
environment configuration. Protect the azd user profile, `.azure` state, and
deployment caches; `@secure()` is not a promise of zero local persistence or
encryption of every local artifact. Do not share debug logs or commit local
environment files. A privileged administrator inside the VM can inspect runtime
execution; protected settings do not isolate a password from that administrator.

For unattended use, inject `VM_ADMIN_PASSWORD` from an approved secret store into
the azd process, or use azd's supported existing Key Vault secret references.
This project does not create a vault. **Do not use ordinary
`azd env set VM_ADMIN_PASSWORD <password>`**, which stores it in a plain-text
environment file. A noninteractive run without the required password fails.

Password sharing is an **initial creation** behavior. Redeployment does not
reset an existing secondary account or synchronize later password changes.
Two accounts sharing a password are not independent credential backups.

## Configuration

Use `azd env set NAME VALUE` for overrides, and `azd env unset NAME` to return to
the Bicep default. Unset optional variables are omitted by azd; defaults live in
`infra/main.bicep`, not in a second default-value list in the parameter file.

| Environment variable | Default / meaning |
| --- | --- |
| `AZURE_ENV_NAME` | Supplied by `azd env new`; 1-24 characters |
| `AZURE_LOCATION` | `westus2`; select consistently when creating the environment |
| `VM_NAME_PREFIX` | `agentbox`; 1-12 letters/digits/hyphens |
| `VM_NAME_OVERRIDE` | Derived from the prefix, environment, and subscription; at most 50 characters |
| `VM_COMPUTER_NAME_OVERRIDE` | Deterministic `ab-` plus 12-character token; Windows limit is 15 |
| `VM_SIZE` | `Standard_D64ds_v7` |
| `VM_ZONE` | `1`; an explicitly empty value selects a regional VM |
| `VM_IMAGE_PUBLISHER` | `microsoftwindowsdesktop` |
| `VM_IMAGE_OFFER` | `windows-11` |
| `VM_IMAGE_SKU` | `win11-26h2-ent`, single-session |
| `VM_IMAGE_VERSION` | `latest`; use a published version to pin new VM images |
| `VM_ADMIN_USERNAME` | `azureuser` |
| `VM_ENROLLMENT_ADMIN_USERNAME` | `enrolleduser`; must differ from the initial name |
| `VM_ADMIN_PASSWORD` | Required secure input; see password handling above |
| `VM_OS_DISK_SIZE_GB` | `127`; range 127-4095 |
| `VM_OS_DISK_TYPE` | `Premium_LRS`; also `StandardSSD_LRS` or `Standard_LRS` |
| `VM_DISK_CONTROLLER` | `NVMe`; also `SCSI`, if supported by the size and image |
| `VM_ACCELERATED_NETWORKING` | `true`; accepts `true` or `false` |
| `VM_VNET_PREFIX` | `172.16.0.0/16` |
| `VM_SUBNET_PREFIX` | `172.16.0.0/24`; must fit within the VNet |
| `VM_RDP_SOURCE` | Empty: no public RDP allow rule |
| `VM_PYTHON_VERSION` | `3.14`; a `3.x` minor-version request |
| `VM_TAGS` | JSON object, default `{}`; reserved azd environment tag takes precedence |

Size overrides do not automatically change the disk controller, image, zone, or
accelerated networking. Check that the combination is supported. `latest` affects
new VM image selection; it does not upgrade an existing VM's OS disk.

Disk size is accepted as decimal text at the public entry point and strictly
converted to an integer for the resource module. Accelerated networking uses an
allowed text enum and is converted to a boolean. This deliberately avoids azd's
numeric/boolean coercion silently ignoring malformed environment strings.

Examples for Bash or PowerShell 7:

```console
azd env set VM_OS_DISK_SIZE_GB 256
azd env set VM_ACCELERATED_NETWORKING false
azd env set VM_ZONE ""
azd env set VM_TAGS '{"purpose":"agent-box"}'
```

Resource names returned in `VM_NAME` and `VM_COMPUTER_NAME` are **outputs**.
Use their `_OVERRIDE` variables for inputs so outputs cannot accidentally pin
future defaults.

### Enable restricted RDP

Set `VM_RDP_SOURCE` to your actual trusted public IPv4 address or CIDR, then
preview and provision the change. The address below is a documentation example;
replace it before use:

```console
azd env set VM_RDP_SOURCE "203.0.113.10/32"
azd provision --preview
azd provision
azd env get-value VM_RDP_ENDPOINT
```

Only TCP 3389 is allowed from that source. Do not use `*` or `0.0.0.0/0`.
With the default empty source, having a public IP does **not** mean public RDP
is accessible. No caller-IP detection or broad access fallback is performed.

## First sign-in and tools

1. Connect with the initial local administrator, normally `.\azureuser`, and
   retain working fallback access.
2. Sign in as `.\enrolleduser`, initially using the same password. The scheduled
   task `\AgentBox\InstallDevTools` runs with that user's interactive token and
   highest privileges, without saving a password or enabling automatic logon.
3. Wait for tool setup and open a new terminal. Provisioning success means the
   task was registered, **not** that this future sign-in installation has run.

The installer is copied to:

```text
C:/ProgramData/AgentBox/Scripts/Install-DevTools.ps1
```

| Tool | WinGet package | Scope |
| --- | --- | --- |
| PowerShell 7 | `Microsoft.PowerShell` | Machine |
| Git for Windows | `Git.Git` | Machine |
| NVM for Windows | `CoreyButler.NVMforWindows` | Signing-in user; x86 installer on the x64 VM |
| uv | `astral-sh.uv` | Machine |
| Azure CLI | `Microsoft.AzureCLI` | Machine |
| Azure Developer CLI | `Microsoft.Azd` | Machine |
| GitHub CLI | `GitHub.cli` | Machine |
| GitHub Copilot CLI | `GitHub.Copilot` | Machine |
| GitHub Copilot app | `GitHub.CopilotApp` | Machine |

WinGet can choose MSI installers internally, but the script never downloads or
invokes tool MSIs directly. It bootstraps a missing WinGet client through
Microsoft's PowerShell module in the **user** context, not SYSTEM. Existing tool
versions are kept; missing tools use the stable WinGet catalog.

After the tools are available, setup:

- Resolves the latest stable Node.js LTS release, installs and activates that
  exact **64-bit** version through NVM, and verifies Node and npm.
- Installs/upgrades **Python 3.14** to the newest patch known to the installed uv
  catalog. An older uv may need an explicit WinGet upgrade to know newer Python
  patches. No unrelated Python installation or unversioned alias is overwritten.
  Use project-specific selection such as `uv run --python 3.14`.

Azure/GitHub login, Copilot app onboarding, and licensing/policy access remain
manual for each user. The tools task never runs the enrollment helper.

Logs are under `C:/ProgramData/AgentBox/Logs/DevTools`. A failure leaves the task
enabled for a later sign-in; the task has a two-hour execution limit and does
not reboot Windows automatically. Resolve failures before retrying. Existing
non-NVM Node installations can cause activation/PATH conflicts; they are not
automatically deleted.

You can rerun the installer manually in elevated PowerShell as the intended
secondary user:

```powershell
& 'C:/ProgramData/AgentBox/Scripts/Install-DevTools.ps1'
# Optional minor-version override:
& 'C:/ProgramData/AgentBox/Scripts/Install-DevTools.ps1' -PythonVersion 3.15
```

The scheduled invocation supplies its configuration fingerprint and disables
itself only after all setup succeeds. An older instance cannot disable a newer
task configuration. Unchanged redeployment preserves a completed task's disabled
state; changes to the installer, target user, or Python version enable a new run.

Filesystem paths use POSIX-style `/` separators, which PowerShell accepts on
Windows. Task Scheduler identifiers such as `\AgentBox\InstallDevTools`,
registry-provider paths, and local-account names such as `.\enrolleduser`
retain their native Windows syntax; they are not filesystem paths.

## Manual Intune enrollment

The Azure resources and billing remain in the subscription associated with the
**Azure hosting tenant**. The Windows guest joins Microsoft Entra ID and enrolls
in Intune in the **Intune enrollment tenant** through its approved user-based
flow. This is not an Azure Virtual Desktop deployment.

While signed in as the **second local administrator**, open an elevated Windows
PowerShell or PowerShell 7 session:

```powershell
& 'C:/ProgramData/AgentBox/Scripts/Start-IntuneEnrollment.ps1' -TenantId '<intune-tenant-guid>'
```

The helper checks local state and opens **Accounts > Access work or school**.
Choose **Connect > Join this device to Microsoft Entra ID** under Alternate
actions. Do not choose ordinary work-account registration or MDM-only enrollment.
Sign in with your account from the Intune enrollment tenant and complete MFA in
Windows UI. Confirm the displayed organization before joining; `-TenantId`
verifies the result, not the UI's tenant selection.

The Intune enrollment tenant must permit the join/enrollment and include the
licensed user in its automatic MDM enrollment scope. The helper cannot verify
those tenant policies locally and does not bypass them.

After completing the flow, or after a requested restart:

```powershell
& 'C:/ProgramData/AgentBox/Scripts/Start-IntuneEnrollment.ps1' -TenantId '<intune-tenant-guid>' -CheckOnly
```

Expect `AzureAdJoined : YES` and the correct device tenant. **Separately confirm
the device record and successful check-in in the Intune admin center for the
Intune enrollment tenant.** An Entra join, MDM discovery URL, or opened settings
page is not proof of Intune enrollment. `AzureAdPrt` and `WorkplaceJoined` need
not be `YES` while using a local Windows account.

The helper stops on unknown state, another tenant/domain, or conflicting work
registration. It never removes management, deletes enrollment registry keys,
captures cloud passwords, or runs `dsregcmd /join` as a workaround. Do not clone
an enrolled VM or issue Intune Wipe to an RDP-only VM.

## Validation and troubleshooting

With Azure CLI/Bicep, Python 3, and PowerShell 7 installed on the development
machine, run:

```console
python3 tests/validate.py
```

This compiles Bicep, evaluates parameter/naming/RDP/payload fixtures, checks the
short protected command and staged files, rejects read-only-property diagnostics,
and runs isolated script tests. API-version and POSIX-path checks prevent those
defaults from silently regressing. Schema-availability warnings remain visible. It
does not create Azure resources, Windows users, or install tools. Windows ACLs,
Run Command/extension execution, first-sign-in behavior, and actual enrollment
still require an authorized Windows deployment for end-to-end validation.

For deployment troubleshooting, distinguish the managed Run Command's execution
status from the extension state. `stage-guest-scripts` must succeed before
`configure-guest`; script failures are deployment failures, not successful
fallbacks. A partially created resource group/VM can remain after failure.
Review it before cleanup or retry.

An existing secondary account is never silently re-enabled, promoted, or reset.
If initial creation only partially succeeded, inspect and remediate the account
with the authorized administrator. Tenant policy may also remove local
administrator rights; do not bypass it.

## Cleanup

After backing up anything needed, select the intended **new** environment and
review its resources before running:

```console
azd down
```

This is destructive: the new environment's VM and OS disk are deleted. Do not
target the original source resource group or an unrelated azd environment.

## References

- [azd environment configuration](https://learn.microsoft.com/azure/developer/azure-developer-cli/manage-environment-variables)
- [Windows 11 Azure licensing and second administrator requirement](https://learn.microsoft.com/azure/virtual-machines/windows/windows-desktop-multitenant-hosting-deployment)
- [Managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)
- [Windows Custom Script Extension and protected settings](https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-windows)
- [Full Windows Entra join and MDM enrollment](https://learn.microsoft.com/windows/client-management/mdm-enrollment-of-windows-devices#use-the-settings-app)
- [WinGet](https://learn.microsoft.com/windows/package-manager/winget/)
- [Python support status](https://devguide.python.org/versions/) and [uv-managed Python](https://docs.astral.sh/uv/concepts/python-versions/)
