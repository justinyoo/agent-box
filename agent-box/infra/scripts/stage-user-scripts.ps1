[CmdletBinding()]
param(
    [string]$PayloadBase64 = '__PAYLOAD_BASE64__',
    [string]$AdminUsernameBase64 = '__ADMIN_USERNAME_BASE64__'
)

function Expand-VmPayload {
    param([string]$Content)
    if (-not $Content -or $Content.Length -gt 90000) { throw 'Invalid compressed payload size.' }
    $inputStream = New-Object IO.MemoryStream(,([Convert]::FromBase64String($Content)))
    $gzip = New-Object IO.Compression.GZipStream($inputStream, [IO.Compression.CompressionMode]::Decompress)
    $output = New-Object IO.MemoryStream
    try {
        $buffer = New-Object byte[] 8192
        while (($read = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($output.Length + $read -gt 1048576) { throw 'Expanded payload exceeds 1 MiB.' }
            $output.Write($buffer, 0, $read)
        }
        $payload = [Text.Encoding]::UTF8.GetString($output.ToArray()) | ConvertFrom-Json -ErrorAction Stop
    }
    finally {
        $gzip.Dispose()
        $inputStream.Dispose()
        $output.Dispose()
    }
    if ($payload.schemaVersion -ne 1 -or @($payload.files).Count -lt 1 -or @($payload.files).Count -gt 32) {
        throw 'Unsupported VM payload format.'
    }
    return $payload
}

function Assert-VmPath {
    param([string]$Path)
    $current = [IO.Path]::GetFullPath($Path)
    if ($current.StartsWith('\\')) { throw 'Network profile paths are not supported.' }
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing reparse point: $current"
            }
        }
        $parent = Split-Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-VmProfilePath {
    param([string]$Sid)
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid"
    if (Test-Path -LiteralPath $key) {
        $value = (Get-ItemProperty -LiteralPath $key -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
        if (-not $value) { throw 'The existing profile has no ProfileImagePath.' }
        return [Environment]::ExpandEnvironmentVariables($value)
    }
}

function New-VmUserProfile {
    param([string]$Sid, [string]$Username)
    if (-not ('AgentBox.UserProfile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace AgentBox {
    public static class UserProfile {
        [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
        public static extern int CreateProfile(string sid, string name, StringBuilder path, uint length);
    }
}
'@ -ErrorAction Stop
    }
    # CreateProfile rejects output buffers larger than MAX_PATH with 0x800706F7.
    $buffer = New-Object Text.StringBuilder 260
    $result = [AgentBox.UserProfile]::CreateProfile($Sid, $Username, $buffer, [uint32]$buffer.Capacity)
    # Another provisioning operation may have created the same profile.
    if ($result -ne 0 -and $result -ne -2147024713) {
        [Runtime.InteropServices.Marshal]::ThrowExceptionForHR($result)
    }
}

function Resolve-VmUserProfile {
    param([string]$Username)
    $user = Get-LocalUser -Name $Username -ErrorAction Stop
    $sid = $user.SID.Value
    if (-not $user.Enabled -or -not $sid) { throw "The $Username account is missing or disabled." }
    $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
    if ($sid -notin @($members | ForEach-Object { $_.SID.Value })) {
        throw "$Username is not a local administrator."
    }
    $path = Get-VmProfilePath -Sid $sid
    if (-not $path) {
        New-VmUserProfile -Sid $sid -Username $Username
        $path = Get-VmProfilePath -Sid $sid
    }
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "The $Username profile could not be resolved after CreateProfile."
    }
    Assert-VmPath $path
    return [IO.Path]::GetFullPath($path)
}

function Get-VmBytesHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)) }
    finally { $sha.Dispose() }
}

function Write-VmUserFiles {
    param([string]$ProfilePath, $Payload, [string]$AdminUsernameBase64)
    Assert-VmPath $ProfilePath
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) { throw 'Profile directory is missing.' }
    $directory = Join-Path $ProfilePath 'scripts'
    Assert-VmPath $directory
    if ((Test-Path -LiteralPath $directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw 'The scripts path is not a directory.'
    }
    $names = @{}
    $pending = foreach ($file in $Payload.files) {
        if ($file.name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]*\.(ps1|vsconfig)$' -or $names.ContainsKey($file.name)) {
            throw "Invalid or duplicate payload file name: $($file.name)"
        }
        $names[$file.name] = $true
        $path = Join-Path $directory $file.name
        Assert-VmPath $path
        $bytes = [Convert]::FromBase64String($file.content)
        if ($file.name -ceq 'install-vm-tools.ps1') {
            $script = [Text.Encoding]::UTF8.GetString($bytes)
            $placeholder = '__ADMIN_USERNAME_' + 'BASE64__'
            if (-not $script.Contains($placeholder)) { throw 'Installer administrator placeholder is missing.' }
            $bytes = [Text.Encoding]::UTF8.GetBytes($script.Replace($placeholder, $AdminUsernameBase64))
        }
        if ($bytes.Length -gt 262144) { throw "Payload file too large: $($file.name)" }
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-VmBytesHash ([IO.File]::ReadAllBytes($path))) -ne (Get-VmBytesHash $bytes)) {
                throw "Preserving different existing file: $path. Move it aside before reprovisioning."
            }
        }
        else { [pscustomobject]@{ Path = $path; Bytes = $bytes } }
    }
    $null = [IO.Directory]::CreateDirectory($directory)
    foreach ($file in $pending) {
        Assert-VmPath $file.Path
        $stream = [IO.File]::Open($file.Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($file.Bytes, 0, $file.Bytes.Length) }
        finally { $stream.Dispose() }
    }
    Write-Host "[PASS] Installation scripts staged in $directory. No tools were installed."
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        $adminUsername = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($AdminUsernameBase64))
        if ([string]::IsNullOrWhiteSpace($adminUsername)) { throw 'Administrator username is missing.' }
        $payload = Expand-VmPayload $PayloadBase64
        $profile = Resolve-VmUserProfile -Username $adminUsername
        Write-VmUserFiles -ProfilePath $profile -Payload $payload -AdminUsernameBase64 $AdminUsernameBase64
    }
    catch {
        Write-Error "VM script staging failed: $($_.Exception.Message)" -ErrorAction Continue
        exit 1
    }
}
