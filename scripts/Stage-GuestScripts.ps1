#Requires -Version 5.1
<#
.SYNOPSIS
Stages the non-secret script payload delivered by the VM managed Run Command.
.DESCRIPTION
The deployment embeds this script and its base64 file map in source.script.
No scripts are downloaded, and staged scripts are not executed here.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Files
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-AgentBoxPermissions {
    param([string]$Path, [switch]$Directory)

    $acl = if ($Directory) {
        [Security.AccessControl.DirectorySecurity]::new()
    }
    else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($administrators)
    $inheritance = if ($Directory) {
        [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    else {
        [Security.AccessControl.InheritanceFlags]::None
    }
    foreach ($entry in @(
        @{ Sid = 'S-1-5-18'; Rights = 'FullControl' }
        @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
        @{ Sid = 'S-1-5-11'; Rights = 'ReadAndExecute' }
    )) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($entry.Sid),
            [Security.AccessControl.FileSystemRights]$entry.Rights,
            $inheritance, [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Copy-AgentBoxScripts {
    param([hashtable]$Files, [string]$RootDirectory)

    $names = @('New-LocalAdmin.ps1', 'Initialize-Guest.ps1', 'Start-IntuneEnrollment.ps1', 'Install-DevTools.ps1')
    if ($Files.Count -ne $names.Count) { throw 'The guest script payload must contain exactly the four expected files.' }
    $decoded = @{}
    foreach ($name in $names) {
        if (-not $Files.ContainsKey($name) -or $Files[$name] -isnot [string] -or
            [string]::IsNullOrEmpty($Files[$name])) {
            throw "Missing or invalid payload for $name."
        }
        $decoded[$name] = [Convert]::FromBase64String($Files[$name])
    }

    $scriptDirectory = Join-Path $RootDirectory 'Scripts'
    foreach ($path in @($RootDirectory, $scriptDirectory)) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing to stage scripts through a file or reparse point: $path."
            }
        }
        else {
            New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
        }
        Set-AgentBoxPermissions -Path $path -Directory
    }

    foreach ($name in $names) {
        $destination = Join-Path $scriptDirectory $name
        if (Test-Path -LiteralPath $destination) {
            $item = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing to overwrite a directory or reparse point: $destination."
            }
        }
        $temporary = Join-Path $scriptDirectory ('.{0}.{1}.tmp' -f $name, [guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllBytes($temporary, $decoded[$name])
            Set-AgentBoxPermissions -Path $temporary
            if ([IO.File]::Exists($destination)) {
                # This overload needs a CLR null, not PowerShell's empty-string conversion.
                [IO.File]::Replace($temporary, $destination, [NullString]::Value)
            }
            else {
                [IO.File]::Move($temporary, $destination)
            }
            Set-AgentBoxPermissions -Path $destination
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -cne $Files[$name]) {
                throw "Staged content verification failed for $name."
            }
            Write-Host "Staged $name."
        }
        finally {
            if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess) {
    throw 'Guest script staging requires 64-bit PowerShell on Windows.'
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Guest script staging requires local administrator privileges.'
}
Copy-AgentBoxScripts -Files $Files -RootDirectory (Join-Path $env:ProgramData 'AgentBox')
