#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\.generated\payload.json')
)

function Get-VmPayloadSources {
    $sources = [ordered]@{}
    foreach ($name in @('install-vm-tools.ps1')) {
        $sources[$name] = Join-Path $PSScriptRoot "..\..\scripts\$name"
    }
    return $sources
}

function New-VmPayload {
    param([System.Collections.IDictionary]$Sources)
    $files = foreach ($name in $Sources.Keys) {
        if (-not (Test-Path -LiteralPath $Sources[$name] -PathType Leaf)) { throw "Missing payload source: $name" }
        [ordered]@{ name = $name; content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Sources[$name])) }
    }
    $json = [ordered]@{ schemaVersion = 1; files = @($files) } | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    if ($bytes.Length -gt 1048576) { throw 'VM script payload exceeds the 1 MiB uncompressed limit.' }
    $stream = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Compress, $true)
    try { $gzip.Write($bytes, 0, $bytes.Length) }
    finally { $gzip.Dispose() }
    try { $content = [Convert]::ToBase64String($stream.ToArray()) }
    finally { $stream.Dispose() }
    if ($content.Length -gt 90000) { throw 'Compressed VM payload is too large for inline delivery.' }
    return [ordered]@{ content = $content }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    . (Join-Path $PSScriptRoot '..\..\..\shared\hook-messages.ps1')
    try {
        $payload = New-VmPayload -Sources (Get-VmPayloadSources)
        $target = [IO.Path]::GetFullPath($OutputPath)
        $null = [IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        $temporary = "$target.$([guid]::NewGuid().ToString('N')).tmp"
        try {
            [IO.File]::WriteAllText($temporary, ($payload | ConvertTo-Json -Compress) + "`n", [Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($target)) { [IO.File]::Replace($temporary, $target, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $target) }
        }
        finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
        Write-HookMessage "[PASS] VM script payload: $($payload.content.Length) base64 characters."
    }
    catch {
        Write-Error "[FAIL] VM script packaging failed: $($_.Exception.Message)" -ErrorAction Continue
        exit 1
    }
}
