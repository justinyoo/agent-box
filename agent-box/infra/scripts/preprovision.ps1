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

function Test-NonInteractive {
    return ($env:AZD_NON_INTERACTIVE -ieq 'true') -or
        -not [string]::IsNullOrWhiteSpace($env:CI) -or
        -not [Environment]::UserInteractive -or [Console]::IsInputRedirected
}

function Read-InteractiveValue {
    param([string]$Prompt)
    if (Test-NonInteractive) { throw $Prompt }
    return (Read-Host $Prompt).Trim()
}

function Read-MaiRegion {
    if (Test-NonInteractive) {
        throw 'Set MAI_FOUNDRY_REGION explicitly before running azd in CI or non-interactive mode.'
    }
    Write-HookMessage '[INFO] Choose the Foundry region (verify current model availability and quota):'
    Write-Host '  1. East US (eastus)'
    Write-Host '  2. Sweden Central (swedencentral)'
    Write-Host '  3. West Europe (westeurope)'
    Write-Host '  4. West US (westus)'
    $selection = Read-InteractiveValue 'Selection [1-4 or region]'
    $region = switch -CaseSensitive ($selection) {
        '1' { 'eastus' }
        '2' { 'swedencentral' }
        '3' { 'westeurope' }
        '4' { 'westus' }
        default { $selection }
    }
    return $region
}

if ([string]::IsNullOrWhiteSpace($env:AZURE_ENV_NAME)) { throw 'azd did not provide AZURE_ENV_NAME.' }
$setValues = @()
$region = if ($env:MAI_FOUNDRY_REGION) { $env:MAI_FOUNDRY_REGION } else { Get-AzdValue 'MAI_FOUNDRY_REGION' }
if (-not $region) {
    $configuredRegion = & azd env config get infra.parameters.maiFoundryRegion --environment $env:AZURE_ENV_NAME 2>$null
    if ($LASTEXITCODE -eq 0) {
        $region = ([string]($configuredRegion -join "`n") | ConvertFrom-Json -ErrorAction Stop)
    }
}
if (-not $region) {
    $region = Read-MaiRegion
}
if ($region -cnotin @('eastus', 'swedencentral', 'westeurope', 'westus')) {
    throw 'MAI_FOUNDRY_REGION must be one of: eastus, swedencentral, westeurope, westus.'
}
$capacity = if ($env:MAI_IMAGE_CAPACITY) { $env:MAI_IMAGE_CAPACITY } else { Get-AzdValue 'MAI_IMAGE_CAPACITY' }
if (-not $capacity) { $capacity = '1' }
if ($capacity -cnotmatch '^[0-9]+$' -or [long]$capacity -lt 1) {
    throw 'MAI_IMAGE_CAPACITY must be a positive whole number.'
}
$setValues += @("MAI_FOUNDRY_REGION=$region", "MAI_IMAGE_CAPACITY=$capacity")

$location = Get-Setting 'AZURE_LOCATION' ''
$subscription = Get-Setting 'AZURE_SUBSCRIPTION_ID' ''
if (-not $location) { throw 'Set AZURE_LOCATION in the azd environment before provisioning.' }
if (-not $subscription) { throw 'Set AZURE_SUBSCRIPTION_ID in the azd environment before provisioning.' }
$vmSize = Get-Setting 'VM_SIZE' 'Standard_D64ds_v7'
$publisher = Get-Setting 'VM_IMAGE_PUBLISHER' 'microsoftwindowsdesktop'
$offer = Get-Setting 'VM_IMAGE_OFFER' 'windows-11'
$sku = Get-Setting 'VM_IMAGE_SKU' 'win11-26h2-ent'
$version = Get-Setting 'VM_IMAGE_VERSION' 'latest'
if (Test-Path Env:VM_ZONE) {
    $zone = [string]$env:VM_ZONE
} else {
    $zone = Get-AzdValue 'VM_ZONE'
}
$vmId = Get-Setting 'AZURE_VM_ID' ''
if ($vmId) {
    if (-not $vmId.StartsWith("/subscriptions/$subscription/resourceGroups/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The previously deployed VM is not in the selected subscription. Use a new azd environment for a new VM.'
    }
    $query = "join('|', [location, join(',', zones || ``[]``)])"
    $vmInfo = & az vm show --ids $vmId --subscription $subscription --query $query --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not verify the previously deployed VM. Check its AZURE_VM_ID and Azure CLI access.'
    }
    $vmParts = ([string]($vmInfo -join "`n")) -split '\|'
    if ($vmParts.Length -ne 2 -or $vmParts[0] -ine $location -or $vmParts[1] -cnotmatch '^[1-4]$') {
        throw 'The previously deployed VM has a different region or no supported single zone. Use a new azd environment for a new VM.'
    }
    if ($zone -and $zone -cne $vmParts[1]) {
        throw "VM_ZONE $zone differs from the existing VM zone $($vmParts[1]). An existing VM cannot be moved by reprovisioning."
    }
    $zone = $vmParts[1]
}
$selectedZone = & (Join-Path $sharedDir 'validate-region.ps1') -Region $location -Subscription $subscription `
    -VmSize $vmSize -Publisher $publisher -Offer $offer -Sku $sku -Version $version -Zone $zone -SelectZone
$setValues += "VM_ZONE=$selectedZone"
Write-HookMessage "[INFO] Using VM availability zone $selectedZone in $location."

& azd env set @setValues --environment $env:AZURE_ENV_NAME
if ($LASTEXITCODE -ne 0) { throw 'Failed to save settings in the azd environment.' }
& (Join-Path $PSScriptRoot 'package-user-scripts.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Failed to package Agent Box scripts.' }
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
Write-HookMessage "[PASS] agent-box is ready for azd environment $env:AZURE_ENV_NAME."
