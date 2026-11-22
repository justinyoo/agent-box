param(
    [string]$Region,
    [string]$Subscription,
    [string]$VmSize,
    [string]$Publisher,
    [string]$Offer,
    [string]$Sku,
    [string]$Version,
    [string]$Zone,
    [switch]$SelectZone
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'hook-messages.ps1')

if ($Region -cnotmatch '^[a-z0-9]+$') { throw 'AZURE_LOCATION must be a lowercase Azure region code.' }
if ($VmSize -cnotmatch '^[A-Za-z0-9_]+$') { throw 'VM size must contain only letters, numbers, and underscores.' }
if (-not $Subscription) { throw 'AZURE_SUBSCRIPTION_ID is required for regional availability checks.' }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is required for regional availability checks.' }
if ($Region -cnotin (Get-Content (Join-Path $PSScriptRoot 'bastion-developer-regions.txt'))) {
    throw "Bastion Developer is not in the documented region list for $Region. Choose another AZURE_LOCATION or update the list after checking Microsoft documentation."
}

Write-HookMessage "[INFO] Checking VM image and size availability in $Region; the SKU lookup can take several minutes."
$images = & az vm image list --subscription $Subscription --location $Region --publisher $Publisher `
    --offer $Offer --sku $Sku --all --query '[].[publisher,offer,sku,version]' --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Could not query VM images in $Region for the selected subscription. Check Azure CLI authentication and permissions."
}
$found = $false
foreach ($line in $images) {
    $parts = $line -split "`t"
    if ($parts.Length -eq 4 -and $parts[0] -ieq $Publisher -and $parts[1] -ieq $Offer -and `
        $parts[2] -ieq $Sku -and ($Version -eq 'latest' -or $parts[3] -eq $Version)) {
        $found = $true
        break
    }
}
if (-not $found) { throw "VM image ${Publisher}:${Offer}:${Sku}:${Version} is not available in $Region for the selected subscription." }

$query = "[?name=='$VmSize'].[name, length(restrictions[?type=='Location']), join(',', locationInfo[].zones[]), join(',', restrictions[?type=='Zone'].restrictionInfo.zones[]), length(restrictions[?type!='Location' && type!='Zone']), length(restrictions[?type=='Zone']), length(restrictions[?type=='Zone' && length(restrictionInfo.zones || ``[]``) > ``0``]), join(',', locationInfo[].location)]"
$result = & az vm list-skus --subscription $Subscription --location $Region --resource-type virtualMachines `
    --size $VmSize --all --query $query --output tsv --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Could not query VM sizes in $Region for the selected subscription. Check Azure CLI authentication and permissions."
}
if (-not $result) { throw "VM size $VmSize is not available in $Region for the selected subscription." }
$parts = ([string]($result -join "`n")) -split "`t"
if ($parts.Length -ne 8 -or $parts[0] -cne $VmSize -or $parts[1] -notmatch '^\d+$' -or
    $parts[4] -notmatch '^\d+$' -or $parts[5] -notmatch '^\d+$' -or $parts[6] -notmatch '^\d+$') {
    throw "Azure CLI returned an unexpected VM size response for $VmSize in $Region."
}
if ($parts[1] -ne '0' -or $parts[4] -ne '0') {
    throw "VM size $VmSize is restricted in $Region for the selected subscription."
}
if ($SelectZone) {
    if ($parts[7] -ine $Region) { throw "Azure CLI returned unexpected zone locations for $VmSize in $Region." }
    if ($parts[5] -ne $parts[6]) {
        throw "Azure CLI returned incomplete zone restrictions for $VmSize in $Region."
    }
    if ($Zone -and $Zone -cnotmatch '^[1-4]$') { throw 'VM_ZONE must be a zone number from 1 to 4.' }
    if (-not $parts[2]) { throw "No availability zones were reported for VM size $VmSize in $Region." }
    $candidates = @($parts[2] -split ',')
    if (@($candidates | Where-Object { $_ -cnotmatch '^[1-4]$' }).Count -gt 0) {
        throw "Azure CLI returned an unsupported zone for $VmSize in $Region."
    }
    $restricted = @($parts[3] -split ',')
    if ($parts[3] -and @($restricted | Where-Object { $_ -cnotmatch '^[1-4]$' }).Count -gt 0) {
        throw "Azure CLI returned an invalid zone restriction for $VmSize in $Region."
    }
    $available = @($candidates | Where-Object { $_ -cnotin $restricted } | Sort-Object { [int]$_ })
    if (-not $available.Count) { throw "No unrestricted availability zones were reported for VM size $VmSize in $Region." }
    if ($Zone -and $Zone -cnotin $available) {
        throw "VM size $VmSize is not available in zone $Zone in $Region for the selected subscription."
    }
    $selectedZone = if ($Zone) { $Zone } else { $available[0] }
}
Write-HookMessage "[PASS] VM image, size, and Bastion Developer region checks passed for $Region."
if ($SelectZone) { Write-Output $selectedZone }
