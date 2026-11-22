$ErrorActionPreference = 'Stop'
trap {
    Write-Error "[FAIL] $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
$sharedDir = Join-Path $PSScriptRoot '..\..\..\shared'
. (Join-Path $sharedDir 'hook-messages.ps1')

function Get-AzdValue {
    param([string]$Name)
    $value = & azd env get-value $Name --environment $env:AZURE_ENV_NAME 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ([string]($value -join "`n")).Trim()
}

function Get-Setting {
    param([string]$Name, [string]$Default)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) { $value = Get-AzdValue $Name }
    if ($value) { return $value }
    return $Default
}

if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) { throw 'azd did not provide AZURE_ENV_NAME.' }
$vmSize = Get-Setting 'APP_MOD_VM_SIZE' 'Standard_D8s_v5'
$diskSize = Get-Setting 'APP_MOD_OS_DISK_SIZE_GB' '256'
$shutdownEnabled = Get-Setting 'APP_MOD_AUTO_SHUTDOWN_ENABLED' 'true'
$shutdownTime = Get-Setting 'APP_MOD_AUTO_SHUTDOWN_TIME' '0000'
if ($shutdownTime -cnotmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') {
    throw 'APP_MOD_AUTO_SHUTDOWN_TIME must be a valid 24-hour time in HHmm format.'
}
$setValues = @(
    "APP_MOD_VM_SIZE=$vmSize", "APP_MOD_OS_DISK_SIZE_GB=$diskSize",
    "APP_MOD_AUTO_SHUTDOWN_ENABLED=$shutdownEnabled", "APP_MOD_AUTO_SHUTDOWN_TIME=$shutdownTime"
)

$location = Get-Setting 'AZURE_LOCATION' ''
$subscription = Get-Setting 'AZURE_SUBSCRIPTION_ID' ''
if (-not $location) { throw 'Set AZURE_LOCATION in the azd environment before provisioning.' }
if (-not $subscription) { throw 'Set AZURE_SUBSCRIPTION_ID in the azd environment before provisioning.' }
& (Join-Path $sharedDir 'validate-region.ps1') -Region $location -Subscription $subscription `
    -VmSize $vmSize -Publisher 'MicrosoftWindowsDesktop' `
    -Offer 'windows-11' -Sku 'win11-26h2-ent' -Version 'latest' -Zone ''

& azd env set @setValues --environment $env:AZURE_ENV_NAME
if ($LASTEXITCODE -ne 0) { throw 'Failed to save settings in the azd environment.' }
& (Join-Path $PSScriptRoot 'package-user-scripts.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Failed to package workshop scripts.' }
$payload = (Get-Content -LiteralPath (Join-Path $PWD 'infra\.generated\payload.json') -Raw | ConvertFrom-Json).content
if (-not $payload -or $payload.Length -gt 90000 -or $payload -cnotmatch '^[A-Za-z0-9+/=]+$') {
    throw 'Invalid script payload.'
}
for ($part = 1; $part -le 3; $part++) {
    $offset = ($part - 1) * 30000
    $value = if ($offset -lt $payload.Length) {
        $payload.Substring($offset, [Math]::Min(30000, $payload.Length - $offset))
    } else { '' }
    & azd env set "VM_SCRIPT_PAYLOAD_$part=$value" --environment $env:AZURE_ENV_NAME
    if ($LASTEXITCODE -ne 0) { throw "Failed to save script payload part $part in the azd environment." }
}
Write-HookMessage "[PASS] app-modernisation-workshop is ready for azd environment $env:AZURE_ENV_NAME."
