$ErrorActionPreference = 'Stop'
trap {
    Write-Error "[FAIL] $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
. (Join-Path $PSScriptRoot '..\..\..\shared\hook-messages.ps1')

if (-not $env:AZURE_RESOURCE_GROUP) { throw 'AZURE_RESOURCE_GROUP is missing from the deployment outputs.' }
if (-not $env:AZURE_VM_NAME) { throw 'AZURE_VM_NAME is missing from the deployment outputs.' }
if (-not $env:AZURE_VM_ADMIN_USERNAME) { throw 'AZURE_VM_ADMIN_USERNAME is missing from the deployment outputs.' }
$adminUsername = $env:AZURE_VM_ADMIN_USERNAME
Write-HookMessage "[INFO] Resource group: $env:AZURE_RESOURCE_GROUP"
Write-HookMessage "[INFO] VM: $env:AZURE_VM_NAME"
Write-HookMessage "[INFO] Windows Login Username: $adminUsername"
Write-HookMessage '[MANUAL] Connect: Azure portal > VM > Connect > Bastion'
Write-HookMessage "[MANUAL] Sign in with .\$adminUsername and the password you entered."
Write-HookMessage '[MANUAL] After sign-in, open an elevated PowerShell terminal and run:'
Write-HookMessage '[MANUAL]   powershell.exe -NoProfile -File "$HOME\scripts\install-vm-tools.ps1"'
Write-HookMessage '[MANUAL] Tools are not installed during deployment. Approve installations and restart manually when requested.'
Write-HookMessage '[MANUAL] Verify WSL2 and Docker manually. See README.md for installation, licensing, and cleanup.'
