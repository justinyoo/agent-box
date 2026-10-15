#Requires -Version 7.3
<#
.SYNOPSIS
Appends the current public IPv4 /32 to the deployed RDP rule and persists its allowlist.
.EXAMPLE
./scripts/Add-RdpSourceIp.ps1 -EnvironmentName agentbox-dev
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-RdpNative {
    param([string]$CommandName, [string[]]$Arguments, [string]$FailureMessage = 'CLI command failed.')

    if ($CommandName -eq 'azd') {
        $PSNativeCommandArgumentPassing = 'Standard'
    }
    $output = & $CommandName @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage $CommandName failed with exit code $LASTEXITCODE."
    }
    return ($output -join [Environment]::NewLine)
}

function ConvertTo-RdpSources {
    param([object[]]$Sources)

    $normalized = foreach ($source in $Sources) {
        if ($source -isnot [string]) { throw 'RDP sources must be IPv4 strings.' }
        $parts = $source.Split('/')
        [Net.IPAddress]$address = $null
        if ($parts.Count -gt 2 -or
            -not [Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
            $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
            $address.ToString() -cne $parts[0]) {
            throw 'Refusing an invalid RDP source; use an IPv4 address or CIDR.'
        }
        $prefix = if ($parts.Count -eq 1) { '32' } else { $parts[1] }
        if ($prefix -notmatch '\A([1-9]|[12][0-9]|3[0-2])\z') {
            throw 'Refusing an invalid or unrestricted RDP source; use a CIDR prefix of 1-32.'
        }
        "$address/$prefix"
    }
    $normalized | Sort-Object -Unique
}

$project = Split-Path $PSScriptRoot -Parent
$envArgs = @('env', 'get-values', '--cwd', $project, '--output', 'json')
if ($EnvironmentName) { $envArgs += @('--environment', $EnvironmentName) }
$config = Invoke-RdpNative azd $envArgs | ConvertFrom-Json -AsHashtable
foreach ($key in @('AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'VM_NAME')) {
    if ($config[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($config[$key])) {
        throw "Select a provisioned azd environment; required value $key is missing."
    }
}
$environment = $config['AZURE_ENV_NAME']
$subscription = $config['AZURE_SUBSCRIPTION_ID']
$resourceGroup = $config['AZURE_RESOURCE_GROUP']
$nsgName = "$($config['VM_NAME'])-nsg"
$sourceIp = & (Join-Path $PSScriptRoot 'Get-RdpSource.ps1')
$saved = ConvertFrom-Json -InputObject ($config['VM_RDP_ADDITIONAL_SOURCES'] ?? '[]') -NoEnumerate
if ($saved -isnot [array]) { throw 'VM_RDP_ADDITIONAL_SOURCES must be a JSON array.' }
$saved = @(ConvertTo-RdpSources $saved)

$ruleName = 'allow-rdp-from-trusted-source'
$ruleArgs = @('--subscription', $subscription, '--resource-group', $resourceGroup, '--nsg-name', $nsgName)
$rules = ConvertFrom-Json -InputObject (Invoke-RdpNative az (@('network', 'nsg', 'rule', 'list') + $ruleArgs + @('--output', 'json'))) `
    -AsHashtable -NoEnumerate
if ($rules -isnot [array]) { throw 'Expected an NSG rule list.' }
$matches = @($rules | Where-Object { $_['name'] -eq $ruleName })
if ($matches.Count -gt 1) { throw 'Multiple matching RDP rules.' }
$action = 'create'
$rule = @{}
if ($matches.Count -eq 1) {
    $action = 'update'
    $rule = $matches[0]
    $ports = @($rule['destinationPortRanges'] ?? @())
    if ($rule['destinationPortRange']) { $ports += $rule['destinationPortRange'] }
    $ports = @($ports | Sort-Object -Unique)
    if ($rule['direction'] -ne 'Inbound' -or $rule['access'] -ne 'Allow' -or $rule['protocol'] -ne 'Tcp' -or
        $ports.Count -ne 1 -or $ports[0] -ne '3389' -or
        @($rule['sourceApplicationSecurityGroups'] ?? @()).Count -ne 0 -or
        (-not $rule['sourceAddressPrefix'] -and @($rule['sourceAddressPrefixes'] ?? @()).Count -eq 0)) {
        throw 'The existing named rule is not a supported IPv4 RDP allow rule; review it manually.'
    }
}
elseif (@($rules | Where-Object { $_['direction'] -eq 'Inbound' -and $_['priority'] -eq 1000 }).Count -gt 0) {
    throw 'Inbound priority 1000 is occupied; review the NSG before creating the RDP rule.'
}

$sources = @($saved) + @($rule['sourceAddressPrefixes'] ?? @()) + @($sourceIp)
if ($rule['sourceAddressPrefix']) { $sources += $rule['sourceAddressPrefix'] }
if ($config['VM_RDP_SOURCE']) { $sources += $config['VM_RDP_SOURCE'] }
$sources = @(ConvertTo-RdpSources $sources)
$sourcesJson = ConvertTo-Json -InputObject $sources -Compress
Write-Host "Appending $sourceIp to $resourceGroup/$nsgName in subscription $subscription (environment $environment)."
$null = Invoke-RdpNative azd @('env', 'set', 'VM_RDP_ADDITIONAL_SOURCES', $sourcesJson, '--cwd', $project, '--environment', $environment) `
    -FailureMessage 'Could not persist the RDP allowlist. No Azure rule was changed.'
$writeArgs = @('network', 'nsg', 'rule', $action) + $ruleArgs + @('--name', $ruleName, '--source-address-prefixes') + $sources
if ($action -eq 'create') {
    $writeArgs += @('--priority', '1000', '--direction', 'Inbound', '--access', 'Allow', '--protocol', 'Tcp',
        '--destination-port-ranges', '3389')
}
$null = Invoke-RdpNative az ($writeArgs + @('--output', 'none')) `
    -FailureMessage 'The allowlist was saved, but the Azure rule update failed. Rerun this script or provision to apply it.'
$actual = Invoke-RdpNative az (@('network', 'nsg', 'rule', 'show') + $ruleArgs + @('--name', $ruleName, '--output', 'json')) `
    -FailureMessage 'The Azure update was submitted, but verification failed. The allowlist remains saved; inspect the rule before retrying.' |
    ConvertFrom-Json -AsHashtable
$actualSources = @($actual['sourceAddressPrefixes'] ?? @())
if ($actual['sourceAddressPrefix']) { $actualSources += $actual['sourceAddressPrefix'] }
$actualSources = @(ConvertTo-RdpSources $actualSources)
if (($actualSources -join "`n") -cne ($sources -join "`n")) {
    throw 'The Azure rule does not match the saved allowlist. Inspect the rule for a failed or concurrent update.'
}
Write-Host "Verified RDP sources: $sourcesJson"
