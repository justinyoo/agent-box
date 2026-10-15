#Requires -Version 5.1
<#
.SYNOPSIS
Creates the secondary local administrator without changing an existing password.
.EXAMPLE
$password = Read-Host 'Initial VM password' -AsSecureString
./New-LocalAdmin.ps1 -Username enrolleduser -InitialAdminUsername azureuser -Password $password
#>
[CmdletBinding()]
param(
    [ValidateLength(1, 20)]
    [string]$Username = 'enrolleduser',

    [ValidateLength(1, 20)]
    [string]$InitialAdminUsername = 'azureuser',

    [Parameter(Mandatory)]
    [Security.SecureString]$Password
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-LocalAdministrator {
    param(
        [string]$Username,
        [string]$InitialAdminUsername,
        [Security.SecureString]$Password
    )

    foreach ($name in @($Username, $InitialAdminUsername)) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 20 -or
            $name.Trim() -ne $name -or $name.EndsWith('.') -or
            $name -match '["/\\\[\]:;|=,+*?<>@\x00-\x1f]' -or $name -match '^[. ]+$') {
            throw 'Administrator names must be valid Windows local account names of 1-20 characters.'
        }
    }
    if ([string]::Equals($Username, $InitialAdminUsername, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The secondary administrator must differ from the initial administrator.'
    }
    if ($null -eq $Password -or $Password.Length -eq 0) {
        throw 'A nonempty secure password is required.'
    }

    $user = Get-LocalUser -ErrorAction Stop |
        Where-Object { $_.Name -eq $Username } | Select-Object -First 1
    $created = $false
    if ($null -eq $user) {
        $user = New-LocalUser -Name $Username -Password $Password `
            -Description 'Agent Box enrollment administrator' -ErrorAction Stop
        Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $user -ErrorAction Stop
        $created = $true
    }

    if (-not $user.Enabled) {
        throw "The existing account '$Username' is disabled; it was not changed."
    }
    $membership = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop |
        Where-Object { $null -ne $_.SID -and $_.SID.Value -eq $user.SID.Value })
    if ($membership.Count -eq 0) {
        throw "Account '$Username' is not a local administrator. Review any partial setup manually; existing accounts are not elevated."
    }

    if ($created) {
        Write-Host "Created and verified local administrator '$Username'."
    }
    else {
        Write-Host "Verified existing local administrator '$Username'; its password was not changed."
    }
    return $user
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'Run New-LocalAdmin.ps1 in 64-bit PowerShell on Windows.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Local administrator privileges are required.'
}
Ensure-LocalAdministrator -Username $Username -InitialAdminUsername $InitialAdminUsername -Password $Password
