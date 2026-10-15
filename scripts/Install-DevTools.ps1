#Requires -Version 5.1

<#
.SYNOPSIS
Installs Agent Box tools with WinGet and runtimes with NVM and uv.
.DESCRIPTION
Run in an elevated Windows x64 user session, not as SYSTEM. Windows PowerShell
5.1 is supported so that PowerShell 7 does not need to be installed beforehand.
If necessary, bootstraps WinGet using Microsoft's Microsoft.WinGet.Client module.

Installs PowerShell 7, Git, NVM for Windows, uv, Azure CLI, Azure Developer CLI,
GitHub CLI, GitHub Copilot CLI, and the GitHub Copilot app. NVM uses its
user-scoped x86 installer; run as the intended account (enrolleduser in the
planned sign-in task). The other tools are installed machine-wide.
Existing tool versions in the requested scope are retained; missing packages
use the latest stable version in the WinGet catalog. Installs and activates
the latest Node.js LTS release through NVM, and installs/upgrades Python to the
latest patch of the requested minor version available to uv. Existing runtime
versions are not removed. Unversioned Python aliases are not overwritten.
Package and source agreements are accepted noninteractively.
WinGet may select MSI installers internally; this script never invokes them
directly. It does not authenticate tools or allow automatic reboots.
.PARAMETER DisableFirstSignInTask
Disables \AgentBox\InstallDevTools only after tool and runtime setup succeeds.
Requires the provisioning-created TaskFingerprint; omit both for standalone use.
.PARAMETER TaskFingerprint
Identifies the task configuration that launched this installer, preventing an
older running installer from disabling a newer setup task.
.PARAMETER PythonVersion
Python major.minor version to install through uv. Defaults to 3.14.
Available patch releases depend on the installed uv version's download catalog.
.EXAMPLE
powershell.exe -NoProfile -File ./Install-DevTools.ps1
.EXAMPLE
pwsh.exe -NoProfile -File ./Install-DevTools.ps1 -PythonVersion 3.15
.LINK
https://learn.microsoft.com/windows/package-manager/winget/
.LINK
https://learn.microsoft.com/windows/package-manager/winget/install
.LINK
https://docs.astral.sh/uv/concepts/python-versions/
#>
[CmdletBinding()]
param(
    [switch]$DisableFirstSignInTask,

    [ValidatePattern('^[a-fA-F0-9]{64}$')]
    [string]$TaskFingerprint,

    [ValidatePattern('^3\.\d+$')]
    [string]$PythonVersion = '3.14'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-LoggedProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$LogDirectory
    )

    $logPrefix = Join-Path $LogDirectory ('command-{0}' -f [guid]::NewGuid().ToString('N'))
    Write-Host ('{0} {1}' -f (Split-Path $Executable -Leaf), ($Arguments -join ' '))
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$logPrefix.stdout.log" `
        -RedirectStandardError "$logPrefix.stderr.log" -ErrorAction Stop

    foreach ($path in @("$logPrefix.stdout.log", "$logPrefix.stderr.log")) {
        Get-Content -LiteralPath $path -ErrorAction Stop | ForEach-Object { Write-Host $_ }
    }

    if ($null -eq $process.ExitCode) {
        throw "$Executable did not return an exit code. See $LogDirectory."
    }

    # WinGet HRESULTs can arrive as signed process exit codes.
    return [pscustomobject]@{
        ExitCode = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$process.ExitCode), 0)
        StandardOutput = [string](Get-Content -LiteralPath "$logPrefix.stdout.log" -Raw -ErrorAction Stop)
    }
}

function Invoke-WinGetCommand {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$LogDirectory
    )

    $result = Invoke-LoggedProcess @PSBoundParameters
    return $result.ExitCode
}

function Invoke-ToolCommand {
    param(
        [string]$CommandName,
        [string[]]$Arguments,
        [string]$LogDirectory
    )

    $command = Get-Command $CommandName -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $executable = $command.Source
    if ([IO.Path]::GetExtension($executable) -eq '.cmd') {
        # These batch wrappers are used only for version checks with literal arguments.
        if ($executable.Contains('%') -or
            @($Arguments | Where-Object { $_ -notmatch '^[A-Za-z0-9_.-]+$' }).Count -gt 0) {
            throw "Unsupported batch-command path or arguments for $CommandName."
        }
        $Arguments = @('/d', '/s', '/c', ('""{0}" {1}"' -f $executable, ($Arguments -join ' ')))
        $executable = $env:ComSpec
    }
    $result = Invoke-LoggedProcess -Executable $executable -Arguments $Arguments `
        -LogDirectory $LogDirectory
    if ($result.ExitCode -ne 0) {
        throw ('{0} failed (0x{1:X8}). See {2}.' -f $CommandName, $result.ExitCode, $LogDirectory)
    }
    return $result.StandardOutput.Trim()
}

function Update-ProcessPath {
    # NVM's PATH entries can reference variables installed after this process started.
    foreach ($name in @('NVM_HOME', 'NVM_SYMLINK')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'User')
        if ([string]::IsNullOrEmpty($value)) {
            $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
        }
        if (-not [string]::IsNullOrEmpty($value)) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
    $path = @(
        [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::GetEnvironmentVariable('Path', 'User')
    ) -join [IO.Path]::PathSeparator
    $env:Path = [Environment]::ExpandEnvironmentVariables($path)
}

function Initialize-WinGet {
    param([string]$LogDirectory)

    $command = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) {
        $code = Invoke-WinGetCommand -Executable $command.Source -Arguments @('--version') `
            -LogDirectory $LogDirectory
        if ($code -eq 0) {
            return $command.Source
        }
        Write-Warning ('WinGet is not ready (0x{0:X8}); attempting the documented bootstrap.' -f $code)
    }

    Write-Host 'Preparing WinGet for the signed-in administrator.'
    $originalTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $originalTls -bor [Net.SecurityProtocolType]::Tls12
        if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            $nuget = Get-PackageProvider -ListAvailable -ErrorAction Stop |
                Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' }
            if (-not $nuget) {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
                    -Scope AllUsers -Force -ErrorAction Stop | Out-Null
            }
            Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery `
                -Scope AllUsers -Force -ErrorAction Stop
        }
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -Latest -ErrorAction Stop | Out-Null
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalTls
    }

    Update-ProcessPath
    $command = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw 'WinGet is still unavailable. Check App Installer registration and organizational policy, then rerun in an elevated user session.'
    }
    $code = Invoke-WinGetCommand -Executable $command.Source -Arguments @('--version') `
        -LogDirectory $LogDirectory
    if ($code -ne 0) {
        throw ('WinGet bootstrap did not produce a working client (0x{0:X8}). See {1}.' -f $code, $LogDirectory)
    }
    return $command.Source
}

function Install-DevToolPackages {
    param(
        [string]$WinGetExecutable,
        [string]$LogDirectory
    )

    $packageIds = @(
        'Microsoft.PowerShell'
        'Git.Git'
        'CoreyButler.NVMforWindows'
        'astral-sh.uv'
        'Microsoft.AzureCLI'
        'Microsoft.Azd'
        'GitHub.cli'
        'GitHub.Copilot'
        'GitHub.CopilotApp'
    )
    $notInstalled = [Convert]::ToUInt32('8A150014', 16)
    $alreadyInstalled = @('8A15002B', '8A150061', '8A15010D') |
        ForEach-Object { [Convert]::ToUInt32($_, 16) }
    $rebootRequired = @('8A150109', '8A15010A') |
        ForEach-Object { [Convert]::ToUInt32($_, 16) }

    foreach ($id in $packageIds) {
        $scope = if ($id -eq 'CoreyButler.NVMforWindows') { 'user' } else { 'machine' }
        $architecture = if ($id -eq 'CoreyButler.NVMforWindows') { 'x86' } else { 'x64' }
        $query = @(
            'list', '--id', $id, '--exact', '--source', 'winget', '--scope', $scope,
            '--accept-source-agreements', '--disable-interactivity'
        )
        $code = Invoke-WinGetCommand -Executable $WinGetExecutable -Arguments $query `
            -LogDirectory $LogDirectory
        if ($code -eq 0) {
            Write-Host "$id is already installed (scope: $scope); keeping its current version."
            continue
        }
        if ($code -ne $notInstalled) {
            throw ('Cannot determine whether {0} is installed (0x{1:X8}). See {2}.' -f $id, $code, $LogDirectory)
        }

        $arguments = @(
            'install', '--id', $id, '--exact', '--source', 'winget', '--scope', $scope,
            '--architecture', $architecture, '--silent', '--no-upgrade',
            '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity'
        )
        if ($id -eq 'Microsoft.PowerShell') {
            # Avoid the per-user MSIX default; WinGet still manages the installer.
            $arguments += @('--installer-type', 'wix')
        }

        $code = Invoke-WinGetCommand -Executable $WinGetExecutable -Arguments $arguments `
            -LogDirectory $LogDirectory
        if ($rebootRequired -contains $code) {
            throw "$id requires a restart. Restart manually and sign in again to retry; the first-sign-in task remains enabled."
        }
        if ($code -ne 0 -and $alreadyInstalled -notcontains $code) {
            throw ('Installation of {0} failed (0x{1:X8}). See {2}.' -f $id, $code, $LogDirectory)
        }

        $code = Invoke-WinGetCommand -Executable $WinGetExecutable -Arguments $query `
            -LogDirectory $LogDirectory
        if ($code -ne 0) {
            throw ('{0} was not verified in {1} scope (0x{2:X8}). See {3}.' -f $id, $scope, $code, $LogDirectory)
        }
        Write-Host "$id is installed (scope: $scope)."
    }
}

function Test-DevToolCommands {
    param([string]$LogDirectory)

    Update-ProcessPath
    $checks = @(
        @{ Command = 'pwsh.exe'; Arguments = @('--version') }
        @{ Command = 'git.exe'; Arguments = @('--version') }
        @{ Command = 'nvm.exe'; Arguments = @('version') }
        @{ Command = 'uv.exe'; Arguments = @('--version') }
        @{ Command = 'az.cmd'; Arguments = @('version', '--output', 'json') }
        @{ Command = 'azd.exe'; Arguments = @('version') }
        @{ Command = 'gh.exe'; Arguments = @('--version') }
        @{ Command = 'copilot.exe'; Arguments = @('--version') }
    )
    foreach ($check in $checks) {
        Invoke-ToolCommand -CommandName $check.Command -Arguments $check.Arguments `
            -LogDirectory $LogDirectory | Out-Null
    }
}

function Get-LatestNodeLts {
    $releases = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' `
        -TimeoutSec 60 -ErrorAction Stop
    $ltsReleases = @($releases | Where-Object { $_.lts -is [string] -and $_.lts.Length -gt 0 })
    if ($ltsReleases.Count -eq 0) {
        throw 'The Node.js release index contains no LTS releases.'
    }
    foreach ($release in $ltsReleases) {
        if ($release.version -notmatch '^v\d+\.\d+\.\d+$') {
            throw 'The Node.js release index contains an invalid LTS version.'
        }
    }
    $latest = $ltsReleases |
        Sort-Object { [version]$_.version.Substring(1) } -Descending |
        Select-Object -First 1
    if ($latest.files -notcontains 'win-x64-zip') {
        throw "Node.js $($latest.version) has no Windows x64 ZIP in the release index."
    }
    return [pscustomobject]@{
        Version = $latest.version.Substring(1)
        Lts = $latest.lts
    }
}

function Install-LanguageRuntimes {
    param(
        [ValidatePattern('^3\.\d+$')]
        [string]$PythonVersion,
        [string]$LogDirectory
    )

    $node = Get-LatestNodeLts
    Write-Host "Installing and activating Node.js LTS $($node.Version) ($($node.Lts))."
    Invoke-ToolCommand -CommandName 'nvm.exe' -Arguments @('install', $node.Version, '64') `
        -LogDirectory $LogDirectory | Out-Null
    Invoke-ToolCommand -CommandName 'nvm.exe' -Arguments @('use', $node.Version, '64') `
        -LogDirectory $LogDirectory | Out-Null
    Update-ProcessPath
    $nodeJson = Invoke-ToolCommand -CommandName 'node.exe' -Arguments @(
        '-p', 'JSON.stringify({version:process.versions.node,lts:process.release.lts,arch:process.arch})'
    ) -LogDirectory $LogDirectory
    $activeNode = $nodeJson | ConvertFrom-Json -ErrorAction Stop
    if (-not $activeNode.PSObject.Properties['version'] -or
        -not $activeNode.PSObject.Properties['lts'] -or
        -not $activeNode.PSObject.Properties['arch'] -or
        $activeNode.version -ne $node.Version -or
        $activeNode.lts -ne $node.Lts -or
        $activeNode.arch -ne 'x64') {
        throw "Active Node.js does not match LTS $($node.Version) for x64. Check NVM and PATH conflicts."
    }
    Invoke-ToolCommand -CommandName 'npm.cmd' -Arguments @('--version') `
        -LogDirectory $LogDirectory | Out-Null

    Write-Host "Installing the latest Python $PythonVersion patch available to uv."
    Invoke-ToolCommand -CommandName 'uv.exe' -Arguments @(
        'python', 'install', $PythonVersion, '--upgrade', '--no-config', '--no-progress'
    ) -LogDirectory $LogDirectory | Out-Null
    $pythonPath = Invoke-ToolCommand -CommandName 'uv.exe' -Arguments @(
        'python', 'find', "cpython$PythonVersion", '--managed-python', '--no-python-downloads',
        '--no-project', '--system', '--no-config'
    ) -LogDirectory $LogDirectory
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
        throw 'uv did not return an existing managed Python executable.'
    }
    $pythonOutput = Invoke-ToolCommand -CommandName $pythonPath -Arguments @('--version') `
        -LogDirectory $LogDirectory
    if ($pythonOutput -notmatch ('^Python ' + [regex]::Escape($PythonVersion) + '\.\d+$')) {
        throw "The uv-managed interpreter does not report a stable Python $PythonVersion patch."
    }
    Write-Host "$pythonOutput is available through uv. Existing unversioned Python commands were not replaced."
}

function Complete-FirstSignInSetup {
    param([string]$Fingerprint)

    $task = Get-ScheduledTask -TaskPath '\AgentBox\' -TaskName 'InstallDevTools' -ErrorAction Stop
    if ($task.Description -ne "AgentBox:InstallDevTools:$Fingerprint") {
        throw 'The tool setup task has changed. Its newer configuration was not disabled.'
    }
    Disable-ScheduledTask -TaskPath '\AgentBox\' -TaskName 'InstallDevTools' -ErrorAction Stop | Out-Null
}

if ($DisableFirstSignInTask -and [string]::IsNullOrEmpty($TaskFingerprint)) {
    throw 'TaskFingerprint is required when disabling the provisioning-created task.'
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Install-DevTools.ps1 requires Windows. It does not install anything on this host.'
}
if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Run this script in a 64-bit PowerShell process on Windows x64.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -eq 'S-1-5-18') {
    throw 'Do not run this script as SYSTEM. Schedule it under the enrolleduser account at sign-in.'
}
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run PowerShell as administrator under your signed-in local account.'
}

$logDirectory = Join-Path $env:ProgramData (
    'AgentBox/Logs/DevTools/{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
Start-Transcript -Path (Join-Path $logDirectory 'install.log') -ErrorAction Stop | Out-Null
try {
    Write-Host "Installation logs: $logDirectory"
    Update-ProcessPath
    $wingetExecutable = Initialize-WinGet -LogDirectory $logDirectory
    Install-DevToolPackages -WinGetExecutable $wingetExecutable -LogDirectory $logDirectory
    Test-DevToolCommands -LogDirectory $logDirectory
    Install-LanguageRuntimes -PythonVersion $PythonVersion -LogDirectory $logDirectory

    if ($DisableFirstSignInTask) {
        Complete-FirstSignInSetup -Fingerprint $TaskFingerprint
    }
    Write-Host 'Development tools and language runtimes are ready. Open a new terminal; Azure and GitHub sign-in remain manual.'
}
finally {
    Stop-Transcript -ErrorAction Stop | Out-Null
}
