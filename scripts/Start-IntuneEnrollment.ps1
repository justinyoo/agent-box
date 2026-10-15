#Requires -Version 5.1
<#
.SYNOPSIS
Guides a local administrator through a Microsoft Entra join to the Intune enrollment tenant.
.DESCRIPTION
Opens Windows Settings, not an unattended enrollment API. Credentials and MFA
remain in Windows UI. An Entra join is never reported as proof of Intune enrollment.
.PARAMETER TenantId
The expected Intune enrollment tenant's GUID, used to verify the result, not to force a tenant choice.
.PARAMETER CheckOnly
Reports join state without opening Settings or attempting a join.
.EXAMPLE
./Start-IntuneEnrollment.ps1 -TenantId '<intune-tenant-guid>'
.EXAMPLE
./Start-IntuneEnrollment.ps1 -TenantId '<intune-tenant-guid>' -CheckOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid]$TenantId,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-DeviceJoinStatus {
    param([string[]]$Lines)

    $section = ''
    $values = @{}
    $fields = @{
        'Device State' = @('AzureAdJoined', 'DomainJoined')
        'User State' = @('WorkplaceJoined')
        'Tenant Details' = @('TenantId')
    }
    foreach ($line in $Lines) {
        if ($line -match '^\s*\|\s*(?<section>[^|]+?)\s*\|\s*$') {
            $section = $Matches.section.Trim()
        }
        elseif ($fields.ContainsKey($section) -and
            $line -match '^\s*(?<name>\w+)\s*:\s*(?<value>.*?)\s*$') {
            $name = $Matches.name
            $value = $Matches.value
            if ($fields[$section] -contains $name) {
                if ($values.ContainsKey($name)) { throw "Ambiguous dsregcmd output: duplicate $name." }
                $values[$name] = $value
            }
        }
    }
    foreach ($name in @('AzureAdJoined', 'DomainJoined', 'WorkplaceJoined')) {
        if (-not $values.ContainsKey($name) -or $values[$name] -notmatch '^(YES|NO)$') {
            throw "Cannot determine $name from dsregcmd. Review the device status manually before joining."
        }
    }
    $joined = $values.AzureAdJoined -eq 'YES'
    $joinedTenant = [guid]::Empty
    if ($joined -and (-not $values.ContainsKey('TenantId') -or
        -not [guid]::TryParse($values.TenantId, [ref]$joinedTenant) -or $joinedTenant -eq [guid]::Empty)) {
        throw 'The device reports an Entra join without a valid device tenant ID.'
    }
    return [pscustomobject]@{
        AzureAdJoined = $joined
        DomainJoined = $values.DomainJoined -eq 'YES'
        WorkplaceJoined = $values.WorkplaceJoined -eq 'YES'
        TenantId = if ($joined) { $joinedTenant } else { $null }
    }
}

function Get-DeviceJoinStatus {
    $command = Get-Command dsregcmd.exe -CommandType Application -ErrorAction Stop
    $PSNativeCommandUseErrorActionPreference = $false
    $lines = @(& $command.Source /status)
    if ($LASTEXITCODE -ne 0) { throw "dsregcmd failed with exit code $LASTEXITCODE." }
    ConvertFrom-DeviceJoinStatus -Lines $lines
}

function Test-ExpectedDeviceJoin {
    param($Status, [guid]$ExpectedTenantId)

    if ($Status.DomainJoined) {
        throw 'This device is joined to an Active Directory domain. Stop and coordinate with its administrator.'
    }
    if ($Status.AzureAdJoined -and $Status.TenantId -ne $ExpectedTenantId) {
        throw "The device is already joined to tenant $($Status.TenantId), not the expected tenant. No connection was removed."
    }
    if (-not $Status.AzureAdJoined -and $Status.WorkplaceJoined) {
        throw 'A work-account registration already exists. Review it in Access work or school; do not remove an actively managed connection automatically.'
    }
    return $Status.AzureAdJoined
}

function Show-EnrollmentStatus {
    param([bool]$Joined, [guid]$ExpectedTenantId)

    if ($Joined) {
        Write-Host "Microsoft Entra join verified for the Intune enrollment tenant $ExpectedTenantId."
    }
    else {
        Write-Warning "The device is not joined to the Intune enrollment tenant $ExpectedTenantId."
    }
    Write-Host 'Intune enrollment is NOT verified by this script.'
    Write-Host 'In the Intune admin center for the Intune enrollment tenant, confirm the device record and a successful recent check-in.'
    return [pscustomobject]@{
        EntraJoinVerified = $Joined
        ExpectedTenantId = $ExpectedTenantId
        IntuneEnrollmentVerified = $false
    }
}

function Invoke-GuidedEnrollment {
    param([guid]$ExpectedTenantId, [switch]$CheckOnly)

    $status = Get-DeviceJoinStatus
    $joined = Test-ExpectedDeviceJoin -Status $status -ExpectedTenantId $ExpectedTenantId
    if ($joined -or $CheckOnly) {
        Show-EnrollmentStatus -Joined $joined -ExpectedTenantId $ExpectedTenantId
        return
    }

    Write-Host "Expected Intune enrollment tenant: $ExpectedTenantId"
    Write-Host 'Confirm your account in the Intune enrollment tenant has Windows/Intune licensing, device-join permission, and MDM enrollment scope.'
    Write-Host 'Check enrollment restrictions, device limits, and MFA/Conditional Access with the Intune enrollment tenant administrator.'
    Write-Host 'Review existing work/MDM connections in Settings. If another organization manages this device, stop.'
    Write-Host 'Choose Connect > Join this device to Microsoft Entra ID under Alternate actions.'
    Write-Host 'Do not use ordinary work-account registration or Enroll only in device management.'
    Write-Host 'Sign in to the Intune enrollment tenant and complete MFA in Windows UI. Verify the organization before choosing Join.'
    Write-Host "If Windows restarts, sign back in with your local account and rerun with -TenantId $ExpectedTenantId -CheckOnly."
    Start-Process 'ms-settings:workplace' -ErrorAction Stop | Out-Null
    $answer = Read-Host 'After finishing the Windows join, press Enter to verify, or type cancel to stop'
    if (-not [string]::IsNullOrEmpty($answer)) {
        throw 'Verification cancelled; no enrollment success is being claimed.'
    }

    $status = Get-DeviceJoinStatus
    $joined = Test-ExpectedDeviceJoin -Status $status -ExpectedTenantId $ExpectedTenantId
    if (-not $joined) {
        throw 'The expected Entra join is not complete. Review Windows Settings and tenant requirements, or verify after a restart.'
    }
    Show-EnrollmentStatus -Joined $true -ExpectedTenantId $ExpectedTenantId
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'Run this helper in 64-bit PowerShell inside the Windows VM.'
}
if (-not [Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0 -or
    [Console]::IsInputRedirected -or
    @([Environment]::GetCommandLineArgs() | Where-Object { $_ -match '^-noni' }).Count -gt 0) {
    throw 'Run this helper manually from your interactive Windows desktop session.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -eq 'S-1-5-18' -or $identity.User.Value -match '-500$') {
    throw 'Sign in as the second local administrator, not SYSTEM or the Azure-provisioned built-in administrator.'
}
$localUser = Get-LocalUser -ErrorAction Stop |
    Where-Object { $_.SID.Value -eq $identity.User.Value } | Select-Object -First 1
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if ($null -eq $localUser -or -not $localUser.Enabled -or
    -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as administrator while signed in as the second local administrator.'
}
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name EditionID -ErrorAction Stop).EditionID
if ($os.ProductType -ne 1 -or [int]$os.BuildNumber -lt 22000 -or
    [string]::IsNullOrWhiteSpace($edition) -or $edition -match '^Core') {
    throw 'This helper expects a Windows 11 Pro, Enterprise, or Education desktop that supports Microsoft Entra join.'
}
Invoke-GuidedEnrollment -ExpectedTenantId $TenantId -CheckOnly:$CheckOnly
