#Requires -Version 7.0
<#
.SYNOPSIS
Returns the current public IPv4 address as a single-host CIDR for VM_RDP_SOURCE.
.EXAMPLE
azd env set VM_RDP_SOURCE (./scripts/Get-RdpSource.ps1)
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$response = Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15 `
    -MaximumRedirection 0 -ErrorAction Stop
if ($response -isnot [string]) {
    throw 'ipify did not return a valid IPv4 address.'
}

$sourceIp = $response.Trim()
[Net.IPAddress]$address = $null
if (-not [Net.IPAddress]::TryParse($sourceIp, [ref]$address) -or
    $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
    $address.ToString() -cne $sourceIp) {
    throw 'ipify did not return a valid IPv4 address.'
}

"$sourceIp/32"
