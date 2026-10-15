#Requires -Version 5.1
<#
.SYNOPSIS
Creates/verifies the secondary administrator and registers its first-sign-in setup.
.DESCRIPTION
Called by the VM Custom Script Extension after scripts have been staged.
Never starts the tools task, signs in a user, or performs Intune enrollment.
#>
[CmdletBinding()]
param(
    [string]$InitialAdminUsername = 'azureuser',
    [string]$EnrollmentAdminUsername = 'enrolleduser',
    [Parameter(Mandatory)]
    [Security.SecureString]$Password,
    [ValidatePattern('^3\.\d+$')]
    [string]$PythonVersion = '3.14'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-AgentBoxTaskFolder {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    foreach ($folder in $root.GetFolders(0)) {
        if ($folder.Name -eq 'AgentBox') { return }
    }
    $null = $root.CreateFolder('AgentBox')
}

function Register-DevToolsSignInTask {
    param(
        [string]$UserSid,
        [ValidatePattern('^3\.\d+$')]
        [string]$PythonVersion,
        [string]$ScriptDirectory
    )

    $installer = Join-Path $ScriptDirectory 'Install-DevTools.ps1'
    $hash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256 -ErrorAction Stop).Hash
    $fingerprintInput = [Text.Encoding]::UTF8.GetBytes("$UserSid|$PythonVersion|$hash")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $fingerprint = ([BitConverter]::ToString($sha.ComputeHash($fingerprintInput))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    $description = "AgentBox:InstallDevTools:$fingerprint"
    $existing = Get-ScheduledTask -ErrorAction Stop |
        Where-Object { $_.TaskPath -eq '\AgentBox\' -and $_.TaskName -eq 'InstallDevTools' } |
        Select-Object -First 1
    if ($null -ne $existing -and -not ([string]$existing.Description).StartsWith('AgentBox:InstallDevTools:')) {
        throw 'An unmanaged task already occupies \AgentBox\InstallDevTools; it was not overwritten.'
    }
    if ($null -ne $existing -and [string]$existing.State -eq 'Running') {
        if ($existing.Description -ne $description) {
            throw 'Developer tool installation is running. Let it finish before updating its setup configuration.'
        }
        Write-Host 'The unchanged developer tools task is already running.'
        return
    }
    $keepDisabled = $null -ne $existing -and $existing.Description -eq $description -and
        [string]$existing.State -eq 'Disabled'

    Initialize-AgentBoxTaskFolder
    $powershell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PythonVersion {1} -DisableFirstSignInTask -TaskFingerprint {2}' -f `
        $installer, $PythonVersion, $fingerprint
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserSid
    $principal = New-ScheduledTaskPrincipal -UserId $UserSid -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $settings.Enabled = -not $keepDisabled
    Register-ScheduledTask -TaskPath '\AgentBox\' -TaskName 'InstallDevTools' `
        -Description $description -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force -ErrorAction Stop | Out-Null
    Write-Host "Registered the developer tools sign-in task; enabled: $(-not $keepDisabled)."
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'Guest setup requires 64-bit PowerShell on Windows.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Guest setup requires local administrator privileges.'
}
$account = & (Join-Path $PSScriptRoot 'New-LocalAdmin.ps1') -Username $EnrollmentAdminUsername `
    -InitialAdminUsername $InitialAdminUsername -Password $Password
Register-DevToolsSignInTask -UserSid $account.SID.Value -PythonVersion $PythonVersion -ScriptDirectory $PSScriptRoot
Write-Host 'Guest setup is ready. Tool installation waits for the secondary administrator to sign in; enrollment remains manual.'
