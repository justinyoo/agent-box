#Requires -Version 5.1

<#
.SYNOPSIS
Installs App Modernisation VM tools after per-item confirmation.
.DESCRIPTION
Run in an elevated Windows x64 local administrator session, not as SYSTEM. Windows
PowerShell 5.1 bootstraps WinGet and PowerShell 7 when necessary, then runs the
remaining installation in PowerShell 7.

The installer preserves existing tools, asks before each installation, and stops
for manual restarts. -Yes approves the listed package agreements and actions.
The script does not authenticate tools, launch Docker Desktop, or create a Linux
user. Run it as the configured local administrator after signing in.
.PARAMETER Yes
Approve all package installations, license terms, and setup changes.
.PARAMETER Help
Show usage instructions without installing tools.
.PARAMETER Track
Workshop tool track. The supported track is dotnet.
.EXAMPLE
powershell.exe -NoProfile -File ./install-vm-tools.ps1
.EXAMPLE
powershell.exe -NoProfile -File ./install-vm-tools.ps1 -Yes
.LINK
https://learn.microsoft.com/windows/package-manager/winget/
.LINK
https://learn.microsoft.com/windows/package-manager/winget/install
.LINK
https://github.com/nvm-windows/nvm/releases/latest
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Help,

    [ValidateSet('dotnet')]
    [string]$Track = 'dotnet'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Console output, consent, and restart checks.
function Test-InstallOutputTerminal {
    return -not [Console]::IsOutputRedirected
}

function Write-InstallMessage {
    param([string]$Message)
    $options = @{}
    if (-not $env:NO_COLOR -and -not $env:CI -and $env:TERM -ne 'dumb' -and
        (Test-InstallOutputTerminal) -and $Message -match '^\[(PASS|FAIL|WARN|MANUAL|INFO)\]') {
        $options.ForegroundColor = switch ($Matches[1]) {
            'PASS' { 'Green' }
            'FAIL' { 'Red' }
            'WARN' { 'Yellow' }
            'MANUAL' { 'Cyan' }
            'INFO' { 'Blue' }
        }
    }
    Write-Host $Message @options
}

function Test-InstallInteractive {
    return -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected -or
        -not [Environment]::UserInteractive)
}

function Confirm-InstallAction {
    param([string]$Message)
    if ($Yes) {
        Write-InstallMessage "[INFO] Approved by -Yes: $Message"
        return $true
    }
    if (-not (Test-InstallInteractive)) {
        throw 'Installation requires an interactive administrator session or the explicit -Yes switch.'
    }
    Write-Host $Message
    $answer = Read-Host 'Continue? [y/N]'
    return $answer -imatch '^y(?:es)?$'
}

function Test-RebootPending {
    $componentBasedServicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $windowsUpdate = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    return $componentBasedServicing -or $windowsUpdate
}

# External command logging.
function Invoke-LoggedProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$LogDirectory,
        [switch]$StreamOutput,
        [switch]$Quiet
    )

    $logPrefix = Join-Path $LogDirectory ('command-{0}' -f [guid]::NewGuid().ToString('N'))
    if (-not $Quiet) {
        Write-Host ('{0} {1}' -f (Split-Path $Executable -Leaf), ($Arguments -join ' '))
    }
    if (-not $StreamOutput) {
        $process = Start-Process -FilePath $Executable -ArgumentList $Arguments `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$logPrefix.stdout.log" `
            -RedirectStandardError "$logPrefix.stderr.log" -ErrorAction Stop

        if (-not $Quiet) {
            foreach ($path in @("$logPrefix.stdout.log", "$logPrefix.stderr.log")) {
                Get-Content -LiteralPath $path -ErrorAction Stop | ForEach-Object { Write-Host $_ }
            }
        }
        if ($null -eq $process.ExitCode) {
            throw "$Executable did not return an exit code. See $LogDirectory."
        }
        $standardOutput = [string](Get-Content -LiteralPath "$logPrefix.stdout.log" -Raw -ErrorAction Stop)
        $standardError = [string](Get-Content -LiteralPath "$logPrefix.stderr.log" -Raw -ErrorAction Stop)
        # WinGet HRESULTs can arrive as signed process exit codes.
        return [pscustomobject]@{
            ExitCode = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$process.ExitCode), 0)
            StandardOutput = $standardOutput
            CombinedOutput = "$standardOutput`n$standardError"
        }
    }

    $encoding = [Text.UTF8Encoding]::new($false)
    $stdout = [IO.StreamWriter]::new("$logPrefix.stdout.log", $false, $encoding)
    try {
        $stderr = [IO.StreamWriter]::new("$logPrefix.stderr.log", $false, $encoding)
        try {
            $standardOutput = [Text.StringBuilder]::new()
            $combinedOutput = [Text.StringBuilder]::new()
            # Keep native prompts visible while recording the two output streams.
            $ErrorActionPreference = 'Continue'
            $PSNativeCommandUseErrorActionPreference = $false
            $global:LASTEXITCODE = $null
            & $Executable @Arguments 2>&1 | ForEach-Object {
                $line = [string]$_
                if ($_ -is [Management.Automation.ErrorRecord]) {
                    $stderr.WriteLine($line)
                    $stderr.Flush()
                }
                else {
                    $stdout.WriteLine($line)
                    $stdout.Flush()
                    $null = $standardOutput.AppendLine($line)
                }
                $null = $combinedOutput.AppendLine($line)
                if (-not $Quiet) { Write-Host $line }
            }
            $code = $LASTEXITCODE
            if ($null -eq $code) {
                throw "$Executable did not return an exit code. See $LogDirectory."
            }
            return [pscustomobject]@{
                ExitCode = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$code), 0)
                StandardOutput = $standardOutput.ToString()
                CombinedOutput = $combinedOutput.ToString()
            }
        }
        finally { $stderr.Dispose() }
    }
    finally { $stdout.Dispose() }
}

# Tool setup and verification.
function Find-VmPowerShell {
    $candidates = @(
        Get-Command pwsh -CommandType Application -All -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Source }
    )
    foreach ($base in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { $candidates += Join-Path $base 'PowerShell\7\pwsh.exe' }
    }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\7\pwsh.exe'
    }
    foreach ($scope in @('Machine', 'User')) {
        foreach ($directory in ([Environment]::GetEnvironmentVariable('Path', $scope) -split ';')) {
            if ($directory) {
                $candidates += Join-Path ([Environment]::ExpandEnvironmentVariables($directory.Trim().Trim('"'))) 'pwsh.exe'
            }
        }
    }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $major = & $candidate -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major' 2>$null
            if ($LASTEXITCODE -eq 0 -and "$major".Trim() -eq '7') { return $candidate }
        }
        catch { Write-InstallMessage "[WARN] Could not inspect PowerShell at $candidate`: $($_.Exception.Message)" }
    }
}

function Invoke-VmPowerShell {
    param(
        [string]$ScriptPath,
        [System.Collections.IDictionary]$BoundParameters,
        [object[]]$RemainingArguments
    )

    $executable = Find-VmPowerShell
    if (-not $executable) {
        throw 'PowerShell 7.x could not be located. Open a new terminal and retry.'
    }

    # Serialize parameters to preserve spaces, Unicode, quotes, arrays and false switches.
    $parameters = @{}
    foreach ($key in $BoundParameters.Keys) {
        $value = $BoundParameters[$key]
        if ($value -is [Management.Automation.SwitchParameter]) { $value = [bool]$value }
        $parameters[$key] = $value
    }
    $payload = [Management.Automation.PSSerializer]::Serialize(@{
        Path = $ScriptPath; Parameters = $parameters; Arguments = $RemainingArguments
    })
    $data = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    $command = @'
$payload = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__DATA__')))
$parameters = $payload.Parameters
$arguments = @()
if ($null -ne $payload.Arguments) { $arguments = @($payload.Arguments) }
$global:LASTEXITCODE = 0
& $payload.Path @parameters @arguments
$succeeded = $?
if ($succeeded) { exit 0 }
if ($LASTEXITCODE -eq 0) { exit 1 }
exit $LASTEXITCODE
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command.Replace('__DATA__', $data)))
    $workerArguments = @('-NoLogo', '-NoProfile', '-InputFormat', 'Text', '-OutputFormat', 'Text')
    $interactive = Test-InstallInteractive
    if (-not $interactive) { $workerArguments += '-NonInteractive' }
    $workerArguments += @('-EncodedCommand', $encoded)
    if ($interactive) {
        # Inherit console handles instead of redirecting the worker through a pipeline.
        $worker = Start-Process -FilePath $executable -ArgumentList $workerArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
        return $worker.ExitCode
    }
    & $executable @workerArguments | Out-Host
    return $LASTEXITCODE
}

function Invoke-ToolProbe {
    param([string]$Name, [string[]]$Arguments = @())
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return [pscustomobject]@{ Code = 127; Text = '' } }
    $result = Invoke-LoggedProcess -Executable $command.Source -Arguments $Arguments `
        -LogDirectory $logDirectory -StreamOutput -Quiet
    return [pscustomobject]@{ Code = $result.ExitCode; Text = $result.CombinedOutput.Trim() }
}

function Test-MinimumVersion {
    param([string]$Text, [version]$Minimum)
    $match = [regex]::Match($Text, '(?<!\d)(\d+\.\d+\.\d+)(?![\d-])')
    return $match.Success -and ([version]$match.Groups[1].Value -ge $Minimum)
}

function Update-ProcessPath {
    $existing = @($env:Path -split ';' | Where-Object { $_ })
    foreach ($scope in @('Machine', 'User')) {
        foreach ($entry in ([Environment]::GetEnvironmentVariable('Path', $scope) -split ';')) {
            $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim())
            if ($expanded -and $expanded -notin $existing) { $existing += $expanded }
        }
    }
    $env:Path = $existing -join ';'
    foreach ($name in @('NVM_HOME', 'NVM_SYMLINK')) {
        if (-not [Environment]::GetEnvironmentVariable($name, 'Process')) {
            foreach ($scope in @('User', 'Machine')) {
                $value = [Environment]::GetEnvironmentVariable($name, $scope)
                if ($value) {
                    [Environment]::SetEnvironmentVariable($name, [Environment]::ExpandEnvironmentVariables($value), 'Process')
                    break
                }
            }
        }
    }
}

function Get-PersistentRuntimePath {
    param([ValidateSet('User', 'Machine')][string]$Scope)

    $root = if ($Scope -eq 'User') { [Microsoft.Win32.Registry]::CurrentUser } else { [Microsoft.Win32.Registry]::LocalMachine }
    $subkey = if ($Scope -eq 'User') { 'Environment' } else { 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
    $key = $root.OpenSubKey($subkey, $false)
    if ($null -eq $key) { throw "Cannot open the $Scope environment registry key." }
    try {
        return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    finally { $key.Dispose() }
}

function Set-PersistentRuntimePath {
    param([ValidateSet('User')][string]$Scope, [string]$Value)

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) { throw "Cannot write the $Scope environment registry key." }
    try {
        $existing = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = if ($null -eq $existing) { [Microsoft.Win32.RegistryValueKind]::ExpandString } else { $key.GetValueKind('Path') }
        if ($kind -notin @([Microsoft.Win32.RegistryValueKind]::String, [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
            throw "The $Scope PATH has an unsupported registry type."
        }
        $key.SetValue('Path', $Value, $kind)
    }
    finally { $key.Dispose() }

    if (-not ('AgentBox.EnvironmentNotifier' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AgentBox {
    public static class EnvironmentNotifier {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr wParam,
            string lParam, uint flags, uint timeout, out UIntPtr result);
    }
}
'@ -ErrorAction Stop
    }
    $result = [UIntPtr]::Zero
    $sent = [AgentBox.EnvironmentNotifier]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result
    )
    if ($sent -eq [IntPtr]::Zero) { throw "Updated $Scope PATH, but could not broadcast the environment change. Sign out and sign in again." }
}

function Assert-NoRuntimeCommandConflict {
    param([string]$Name, [string]$ExpectedPath)

    $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and ($command.CommandType -ne 'Application' -or
        [IO.Path]::GetFullPath($command.Source) -ine [IO.Path]::GetFullPath($ExpectedPath))) {
        throw "The existing $Name command ($($command.Source)) takes precedence over $ExpectedPath. Resolve the conflict manually; PATH was not reordered."
    }
}

function Test-RuntimePath {
    param([string]$Directory, [string]$Executable)

    $machinePath = Get-PersistentRuntimePath -Scope Machine
    $userPath = Get-PersistentRuntimePath -Scope User
    $target = [Environment]::ExpandEnvironmentVariables($Directory).TrimEnd('\', '/')
    foreach ($entry in ((@($machinePath, $userPath) -join ';') -split ';')) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"'))
        if ($expanded.TrimEnd('\', '/') -ieq $target) { return $true }
        if ($expanded -and [IO.Path]::IsPathRooted($expanded) -and
            (Test-Path -LiteralPath (Join-Path $expanded $Executable) -PathType Leaf)) {
            throw "An existing $Executable in $expanded takes precedence over $Directory. Resolve the PATH conflict manually; existing entries were preserved."
        }
    }
    return $false
}

function Set-RuntimePath {
    param([string]$Directory, [string]$Executable, [string]$Name)

    if (-not [IO.Path]::IsPathRooted($Directory) -or $Directory -match '[;"]' -or
        -not (Test-Path -LiteralPath (Join-Path $Directory $Executable) -PathType Leaf)) {
        throw "The runtime executable directory is invalid: $Directory"
    }
    Update-ProcessPath
    Assert-NoRuntimeCommandConflict -Name $Name -ExpectedPath (Join-Path $Directory $Executable)
    $found = Test-RuntimePath -Directory $Directory -Executable $Executable
    if (-not $found) {
        if (-not (Confirm-InstallAction "Append $Directory to the user PATH for $Executable, preserving existing entries and their order.")) {
            throw "Adding $Directory to the user PATH was declined."
        }
        $userPath = Get-PersistentRuntimePath -Scope User
        $separator = if ($userPath -and -not $userPath.EndsWith(';')) { ';' } else { '' }
        Set-PersistentRuntimePath -Scope User -Value "$userPath$separator$Directory"
    }
    Update-ProcessPath
}

function Invoke-FrameworkProbe {
    param([string]$File, [string[]]$Arguments)
    try {
        $text = (& $File @Arguments 2>&1 | Out-String).Trim()
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
    }
    catch { return [pscustomobject]@{ Code = 127; Text = $_.Exception.Message } }
}

function Get-DotnetFrameworkBuildTools {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $result = Invoke-FrameworkProbe $vswhere @('-products', '*', '-version', '[17.0,19.0)', '-requires', 'Microsoft.Component.MSBuild', '-format', 'json', '-utf8')
    if ($result.Code -ne 0) { throw 'Could not run vswhere from Visual Studio Installer.' }
    try { $instances = @($result.Text | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'Could not parse vswhere output.' }
    foreach ($instance in ($instances | Sort-Object { [version]$_.installationVersion } -Descending)) {
        if (-not $instance.installationPath) { continue }
        $major = ([version]$instance.installationVersion).Major
        $msbuild = Join-Path $instance.installationPath 'MSBuild\Current\Bin\MSBuild.exe'
        $webTools = Join-Path $instance.installationPath "MSBuild\Microsoft\VisualStudio\v$major.0"
        if ((Test-Path -LiteralPath $msbuild -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $webTools 'WebApplications\Microsoft.WebApplication.targets') -PathType Leaf)) {
            return [pscustomobject]@{ MSBuild = $msbuild; WebTools = $webTools; Version = "$major.0" }
        }
    }
    throw 'MSBuild.exe and WebApplications\Microsoft.WebApplication.targets from VS 2022/2026 IDE or Build Tools are required. Check the ASP.NET web build components.'
}

function Get-WorkshopIisExpress {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        $exe = Join-Path $base 'IIS Express\iisexpress.exe'
        $template = Join-Path $base 'IIS Express\AppServer\applicationhost.config'
        if ((Test-Path -LiteralPath $exe -PathType Leaf) -and (Test-Path -LiteralPath $template -PathType Leaf)) {
            return [pscustomobject]@{ Exe = $exe; Template = $template }
        }
    }
    throw 'The IIS Express executable and AppServer\applicationhost.config template are required.'
}

function Get-WorkshopReleaseVersion {
    param($Probe)
    if ($Probe.Code -eq 0 -and $Probe.Text.Trim() -match '^v?(\d+\.\d+\.\d+)$') {
        return [version]$Matches[1]
    }
}

function Get-WorkshopNvmConfiguration {
    $probe = Invoke-ToolProbe nvm @('config', 'get', 'root', 'mode', 'auto_install', 'enabled', '--json')
    if ($probe.Code -ne 0) { Write-InstallMessage '[FAIL] Could not query nvm-windows 2 configuration.'; return }
    try { $config = $probe.Text | ConvertFrom-Json -ErrorAction Stop }
    catch [ArgumentException] { Write-InstallMessage '[FAIL] Invalid nvm-windows 2 configuration JSON.'; return }
    if (-not $config -or -not $config.PSObject.Properties['root'] -or
        -not $config.PSObject.Properties['mode'] -or -not $config.PSObject.Properties['enabled'] -or
        -not $config.PSObject.Properties['auto_install'] -or
        $config.root -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($config.root) -or
        -not (Split-Path $config.root.TrimEnd('\') -Parent) -or
        $config.mode -cnotin @('shim', 'link') -or $config.enabled -isnot [bool] -or
        $config.auto_install -isnot [bool] -or -not $config.enabled -or $config.auto_install) {
        Write-InstallMessage '[MANUAL] Check nvm-windows 2 root/mode/enabled settings. This script will not continue with auto_install=true, to prevent installation without individual consent.'
        return
    }
    return $config
}

function Get-WorkshopNvmSelection {
    $list = Invoke-ToolProbe nvm @('list', '--json')
    # nvm 2.0.x prints text instead of JSON before the first Node installation.
    if ($list.Code -eq 0 -and $list.Text.Trim() -ceq 'No versions installed.') {
        Write-InstallMessage '[INFO] nvm has no installed Node.js versions.'
        return [pscustomobject]@{ Version = $null; IsEmpty = $true }
    }
    if ($list.Code -ne 0 -or $list.Text.Trim() -notmatch '^\[[\s\S]*\]$') { Write-InstallMessage '[FAIL] Could not list installed nvm-windows 2 versions.'; return }
    try { $versions = @($list.Text | ConvertFrom-Json -ErrorAction Stop) }
    catch [ArgumentException] { Write-InstallMessage '[FAIL] Invalid nvm-windows 2 version list JSON.'; return }
    foreach ($entry in $versions) {
        if (-not $entry -or -not $entry.PSObject.Properties['version'] -or
            -not $entry.PSObject.Properties['installed'] -or -not $entry.PSObject.Properties['default'] -or
            -not (Get-WorkshopReleaseVersion ([pscustomobject]@{ Code=0; Text=[string]$entry.version })) -or
            $entry.installed -isnot [bool] -or $entry.default -isnot [bool]) {
            Write-InstallMessage '[FAIL] Invalid nvm-windows 2 version list format.'; return
        }
    }
    $defaults = @($versions | Where-Object { $_.installed -eq $true -and $_.default -eq $true })
    if ($defaults.Count -gt 1) { Write-InstallMessage '[FAIL] Multiple default nvm-windows 2 versions were found.'; return }
    return [pscustomobject]@{ Version = if ($defaults.Count) {
        Get-WorkshopReleaseVersion ([pscustomobject]@{ Code=0; Text=[string]$defaults[0].version })
    } else { $null }; IsEmpty = $versions.Count -eq 0 }
}

function Test-WorkshopNvmOwnership {
    param([string]$NodePath)
    $nvm = Get-Command nvm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nvm) { return $false }
    $version = Get-WorkshopReleaseVersion (Invoke-ToolProbe nvm @('version'))
    if (-not $version) { return $false }
    if ($version.Major -eq 2) {
        $config = Get-WorkshopNvmConfiguration
        if (-not $config) { return $false }
        $root = [IO.Path]::GetFullPath($config.root).TrimEnd('\')
        $dataRoot = Split-Path $root -Parent
        $runtime = Join-Path $dataRoot '.nodejs'
        $link = Get-Item -LiteralPath $runtime -Force -ErrorAction SilentlyContinue
        if ($link) {
            if ($link.LinkType -notin @('Junction', 'SymbolicLink') -or @($link.Target).Count -ne 1) { return $false }
            $target = [IO.Path]::GetFullPath(@($link.Target)[0]).TrimEnd('\')
            if ($config.mode -eq 'shim') {
                if ($target -ine (Join-Path $dataRoot '.shim')) { return $false }
            }
            elseif ((Split-Path $target -Parent) -ine $root -or (Split-Path $target -Leaf) -notmatch '^v\d+\.\d+\.\d+$') { return $false }
        }
        if ($NodePath -and (-not $link -or
            [IO.Path]::GetFullPath($NodePath) -ine (Join-Path $runtime 'node.exe'))) { return $false }
        return $true
    }
    if ($version.Major -ne 1 -or -not $env:NVM_HOME -or -not $env:NVM_SYMLINK) { return $false }
    if ([IO.Path]::GetFullPath($nvm.Source) -ine [IO.Path]::GetFullPath((Join-Path $env:NVM_HOME 'nvm.exe'))) { return $false }
    $settings = Join-Path $env:NVM_HOME 'settings.txt'
    if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) { return $false }
    $lines = Get-Content -LiteralPath $settings
    $root = @($lines | Where-Object { $_ -match '^root:\s*(.+)$' } | ForEach-Object { $_ -replace '^root:\s*', '' })
    $path = @($lines | Where-Object { $_ -match '^path:\s*(.+)$' } | ForEach-Object { $_ -replace '^path:\s*', '' })
    if ($root.Count -ne 1 -or $path.Count -ne 1 -or
        $root[0].TrimEnd('\') -ine $env:NVM_HOME.TrimEnd('\') -or
        $path[0].TrimEnd('\') -ine $env:NVM_SYMLINK.TrimEnd('\')) { return $false }
    $link = Get-Item -LiteralPath $env:NVM_SYMLINK -Force -ErrorAction SilentlyContinue
    if ($link) {
        if ($link.LinkType -ne 'SymbolicLink') { return $false }
        $targets = @($link.Target)
        if ($targets.Count -ne 1) { return $false }
        $target = [IO.Path]::GetFullPath($targets[0])
        if ((Split-Path $target -Parent) -ine $env:NVM_HOME.TrimEnd('\') -or
            (Split-Path $target -Leaf) -notmatch '^v\d+\.\d+\.\d+$') { return $false }
    }
    if ($NodePath) {
        if (-not $link -or [IO.Path]::GetFullPath($NodePath) -ine
            [IO.Path]::GetFullPath((Join-Path $env:NVM_SYMLINK 'node.exe'))) { return $false }
        $active = Get-WorkshopReleaseVersion (Invoke-ToolProbe node @('--version'))
        if (-not $active -or (Split-Path $target -Leaf) -ine "v$active") { return $false }
    }
    return $true
}

function Get-WorkshopNodeRelease {
    param([int]$Major)
    $releases = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30 -ErrorAction Stop
    return ($releases | Where-Object { $_.version -match "^v$Major\.\d+\.\d+$" } |
        ForEach-Object { [version]$_.version.TrimStart('v') } | Sort-Object -Descending | Select-Object -First 1)
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

function Enable-VmNvmRuntimePath {
    param($Config)
    if (-not $Config) { return }
    $runtime = Join-Path (Split-Path $Config.root.TrimEnd('\') -Parent) '.nodejs'
    if (Test-Path -LiteralPath (Join-Path $runtime 'node.exe') -PathType Leaf) {
        if (-not (Test-WorkshopNvmOwnership (Join-Path $runtime 'node.exe'))) {
            throw 'The nvm runtime directory is not safely managed by nvm. Resolve the conflict before changing PATH.'
        }
        Set-RuntimePath -Directory $runtime -Executable 'node.exe' -Name 'node'
    }
}

function Install-WorkshopNode {
    param([switch]$Update, [switch]$LatestLts)
    if (-not $Yes -and -not (Test-InstallInteractive)) { return $false }
    Update-ProcessPath
    $node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($node -and $node.CommandType -ne 'Application') {
        throw 'The existing node command is not an nvm executable. Resolve the conflict manually.'
    }
    $nvm = Get-Command nvm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $nvm) {
        # nvm's installer may offer to take over an existing Node installation.
        # Do not even launch it when ownership or its default link is ambiguous.
        $defaultLink = if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'nodejs' }
        if ($node -or $env:NVM_HOME -or $env:NVM_SYMLINK -or
            ($defaultLink -and (Test-Path -LiteralPath $defaultLink))) {
            Write-InstallMessage '[MANUAL] Existing Node.js/NVM paths will be preserved. Identify the original installer and prepare the switch to nvm-windows manually.'
            return $false
        }
        if (-not (Get-Command winget -CommandType Application -ErrorAction SilentlyContinue)) {
            Write-InstallMessage '[MANUAL] winget must already be installed to install nvm-windows.'
            return $false
        }
        if (-not (Confirm-InstallAction 'Install AuthorSoftware.NVMWindows through winget. Network access, administrator approval, and a review of the terms may be required.')) { return $false }
        & winget install --id AuthorSoftware.NVMWindows --exact --source winget | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-InstallMessage '[FAIL] nvm-windows installation failed.'; return $false }
        Update-ProcessPath
    }
    $nodePath = if ($node) { $node.Source } else { $null }
    if (-not (Test-WorkshopNvmOwnership $nodePath)) {
        Write-InstallMessage '[MANUAL] Could not establish ownership of the nvm-windows configuration or active Node.js installation. No paths will be deleted or overwritten.'
        return $false
    }
    $nvmVersion = Get-WorkshopReleaseVersion (Invoke-ToolProbe nvm @('version'))
    if (-not $nvmVersion -or $nvmVersion.Major -notin @(1, 2)) { Write-InstallMessage '[FAIL] Could not verify a supported nvm-windows version.'; return $false }
    $root = $env:NVM_HOME
    $hasActive = [bool]$node
    if ($nvmVersion -and $nvmVersion.Major -eq 2) {
        $config = Get-WorkshopNvmConfiguration
        if (-not $config) { return $false }
        $root = $config.root
        $selection = Get-WorkshopNvmSelection
        if (-not $selection) { return $false }
        $hasActive = $null -ne $selection.Version
        if ($hasActive -and -not $node) {
            Enable-VmNvmRuntimePath $config
            $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($hasActive -and -not $node) { Write-InstallMessage '[MANUAL] The nvm-windows Node.js executable directory is not in PATH. Rerun in a new terminal.'; return $false }
    }
    if (-not $root) { Write-InstallMessage '[FAIL] Could not verify the nvm-windows installation root.'; return $false }
    $currentProbe = if ($node) { Invoke-ToolProbe node @('--version') }
    $current = if ($currentProbe) { Get-WorkshopReleaseVersion $currentProbe }
    if ($node -and -not $current -and ($hasActive -or $currentProbe.Code -eq 0)) { Write-InstallMessage '[FAIL] Could not verify a stable Node.js version.'; return $false }
    $hasActive = [bool]$current
    if ($current -and -not $Update) {
        Write-InstallMessage "[INFO] Keeping Node.js $current (no -Update)."
        return $current.Major -ge 22
    }
    $major = if ($current -and $current.Major -ge 22) { $current.Major } else { 22 }
    try {
        if ($LatestLts) {
            $latest = [version](Get-LatestNodeLts).Version
            $major = $latest.Major
        }
        else { $latest = Get-WorkshopNodeRelease $major }
    }
    catch { Write-InstallMessage "[FAIL] Could not query Node.js releases: $($_.Exception.Message)"; return $false }
    if (-not $latest -or $latest.Major -ne $major) { Write-InstallMessage '[FAIL] Could not verify a stable Node.js release.'; return $false }
    if ($current -and $current -ge $latest) { Write-InstallMessage "[PASS] Keeping Node.js $current (no downgrade)."; return $true }
    $installedNode = Join-Path $root "v$latest\node.exe"
    $firstInstall = $nvmVersion.Major -eq 2 -and $selection.IsEmpty -and -not $current
    if (-not (Test-Path -LiteralPath $installedNode -PathType Leaf)) {
        $description = "Install Node.js $latest through nvm. Existing versions will be preserved."
        if ($firstInstall) {
            $description += ' nvm 2 automatically selects the first installed version as the default. This also authorizes that activation for subsequent terminals.'
        }
        if (-not (Confirm-InstallAction $description)) {
            return ($current -and $current.Major -ge 22)
        }
        $install = Invoke-ToolProbe nvm @('install', "$latest")
        if ($install.Code -ne 0) { Write-InstallMessage "[FAIL] nvm install failed: $($install.Text)"; return $false }
    }
    $probe = Invoke-ToolProbe $installedNode @('--version')
    if ((Get-WorkshopReleaseVersion $probe) -ne $latest) { Write-InstallMessage '[FAIL] Installed Node.js version verification failed.'; return $false }
    if ($firstInstall) {
        Update-ProcessPath
        Enable-VmNvmRuntimePath $config
        $liveNode = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($liveNode -and $liveNode.CommandType -ne 'Application') {
            Write-InstallMessage '[MANUAL] The node command changed. Activation will not proceed.'
            return $false
        }
        $liveConfig = Get-WorkshopNvmConfiguration
        $liveSelection = Get-WorkshopNvmSelection
        if ($liveConfig -and $liveSelection -and $liveConfig.root -ieq $root -and
            $liveConfig.mode -ceq $config.mode -and $liveSelection.Version -eq $latest -and
            $liveNode -and (Test-WorkshopNvmOwnership $liveNode.Source) -and
            (Get-WorkshopReleaseVersion (Invoke-ToolProbe node @('--version'))) -eq $latest) {
            Write-InstallMessage "[PASS] [Windows host] nvm installed and selected the first Node.js $latest."
            return $true
        }
    }
    if (-not (Confirm-InstallAction "Run nvm use $latest`: change the shared Windows Node.js selection (shim/link). This affects subsequent terminals, but not running Node.js processes. Administrator approval may be required.")) {
        Write-InstallMessage "[INFO] Activation skipped. If needed, run nvm use $latest manually and verify the result."
        return ($current -and $current.Major -ge 22)
    }
    # Recheck immediately before a link change; never take over a new collision.
    $liveNode = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($liveNode -and $liveNode.CommandType -ne 'Application') {
        Write-InstallMessage '[MANUAL] The node command changed. Activation will not proceed.'
        return $false
    }
    $liveNodePath = if ($liveNode) { $liveNode.Source } else { $null }
    if (-not (Test-WorkshopNvmOwnership $liveNodePath)) {
        Write-InstallMessage '[MANUAL] nvm-windows management settings changed. Activation will not proceed.'
        return $false
    }
    if ($nvmVersion.Major -eq 2) {
        $liveConfig = Get-WorkshopNvmConfiguration
        $liveSelection = Get-WorkshopNvmSelection
        if (-not $liveConfig -or -not $liveSelection -or $liveConfig.root -ine $root -or
            $liveConfig.mode -cne $config.mode -or $liveSelection.Version -ne $selection.Version) {
            Write-InstallMessage '[MANUAL] nvm-windows 2 configuration or default selection changed. Activation will not proceed.'
            return $false
        }
    }
    $liveVersion = if ($liveNode -and $hasActive) { Get-WorkshopReleaseVersion (Invoke-ToolProbe node @('--version')) }
    if ($liveVersion -ne $current) {
        Write-InstallMessage '[MANUAL] Detected a Node.js path conflict or active version change. Activation will not proceed.'
        return $false
    }
    $useArguments = @('use', "$latest")
    if ($nvmVersion -and $nvmVersion.Major -eq 2) { $useArguments += '--no-install' }
    $use = Invoke-ToolProbe nvm $useArguments
    Update-ProcessPath
    if ($nvmVersion.Major -eq 2) { Enable-VmNvmRuntimePath $config }
    $activeNode = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($use.Code -ne 0 -or -not $activeNode -or
        -not (Test-WorkshopNvmOwnership $activeNode.Source) -or
        (Get-WorkshopReleaseVersion (Invoke-ToolProbe node @('--version'))) -ne $latest) {
        Write-InstallMessage '[FAIL] Could not verify nvm activation or the running Node.js version. Check PATH and nvm list in a new terminal.'
        return $false
    }
    Write-InstallMessage "[PASS] [Windows host] nvm Node.js $latest"
    return $true
}

function Invoke-VmInstaller {
    param([string]$Command, [string[]]$Arguments)
    $executable = Get-Command $Command -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $result = Invoke-LoggedProcess -Executable $executable.Source -Arguments $Arguments `
        -LogDirectory $logDirectory -StreamOutput
    $code = $result.ExitCode
    if ($code -in @([uint32]1641, [uint32]3010,
            [Convert]::ToUInt32('8A150109', 16), [Convert]::ToUInt32('8A15010A', 16))) {
        $script:RestartRequired = $true
        Write-InstallMessage '[MANUAL] The installer requested a restart. Restart manually and rerun this script.'
        return $true
    }
    if ($code -ne 0) { throw "$Command installation failed (exit code $code): $($result.CombinedOutput)" }
    return $true
}

function Get-VmWingetVersion {
    param([string]$Id, [string]$VersionPattern)
    $arguments = @('show', '--id', $Id, '--exact', '--source', 'winget', '--versions', '--disable-interactivity')
    if ($Yes) { $arguments += '--accept-source-agreements' }
    $executable = Get-Command winget -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $result = Invoke-LoggedProcess -Executable $executable.Source -Arguments $arguments `
        -LogDirectory $logDirectory -StreamOutput
    if ($result.ExitCode -ne 0) {
        throw "Failed to query $Id versions. Check the source agreements and network access in winget: $($result.CombinedOutput)"
    }
    $versions = @($result.StandardOutput -split '\r?\n' | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match $VersionPattern } | ForEach-Object { [version]$_ } | Sort-Object -Descending)
    if (-not $versions.Count) { throw "No stable $Id version matches the required pattern: $VersionPattern" }
    return $versions[0].ToString()
}

function Test-CopilotCli {
    param([string]$LogDirectory)

    Update-ProcessPath
    $command = Get-Command copilot -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) { return $false }
    $result = Invoke-LoggedProcess -Executable $command.Source -Arguments @('--version') `
        -LogDirectory $LogDirectory -StreamOutput -Quiet
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StandardOutput)) {
        throw "The existing Copilot CLI at $($command.Source) could not be verified. See $LogDirectory."
    }
    return $true
}

function Install-VmPackage {
    param(
        [string]$Id,
        [string]$Name,
        [scriptblock]$TestInstalled,
        [string]$VersionPattern,
        [string[]]$ExtraArguments = @()
    )
    if (Test-RebootPending) {
        $script:RestartRequired = $true
        Write-InstallMessage '[MANUAL] A Windows restart is pending. Restart manually and rerun this script.'
        return $false
    }
    if (& $TestInstalled) { Write-InstallMessage "[PASS] $Name is installed. Keeping the existing installation."; return $true }
    if (-not (Confirm-InstallAction "Install $Name ($Id). Review the license and installation details shown.")) {
        Write-InstallMessage "[MANUAL] Skipped the $Name installation."
        return $false
    }
    $arguments = @('install', '--id', $Id, '--exact', '--source', 'winget')
    if ($Yes) { $arguments += @('--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
    if ($VersionPattern) { $arguments += @('--version', (Get-VmWingetVersion $Id $VersionPattern)) }
    $arguments += $ExtraArguments
    $null = Invoke-VmInstaller winget $arguments
    if ($script:RestartRequired) { return $false }
    if (Test-RebootPending) {
        $script:RestartRequired = $true
        Write-InstallMessage '[MANUAL] A Windows restart is pending. Restart manually and rerun this script.'
        return $false
    }
    if (Get-Command Update-ProcessPath -CommandType Function -ErrorAction SilentlyContinue) { Update-ProcessPath }
    if (-not (& $TestInstalled)) { throw "Could not verify $Name after installation. Rerun from a new terminal." }
    Write-InstallMessage "[PASS] Verified the $Name installation."
    return $true
}

function Test-VmWinget {
    $command = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $false }
    $result = Invoke-LoggedProcess -Executable $command.Source -Arguments @('--version') `
        -LogDirectory $logDirectory -StreamOutput -Quiet
    if ($result.ExitCode -ne 0) {
        Write-InstallMessage ('[WARN] WinGet is not ready (0x{0:X8}). See {1}.' -f $result.ExitCode, $logDirectory)
        return $false
    }
    return $true
}

function Initialize-VmWinget {
    if (Test-VmWinget) { return $true }
    if (Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop) {
        if (-not (Confirm-InstallAction 'Register App Installer (Windows Package Manager) for the current user.')) { return $false }
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    }
    else {
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            if (-not (Confirm-InstallAction 'Install the NuGet package provider required to prepare WinGet.')) { return $false }
            $null = Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ErrorAction Stop
        }
        if (-not (Get-Module -ListAvailable Microsoft.WinGet.Client)) {
            if (-not (Confirm-InstallAction 'Install the Microsoft.WinGet.Client module from PSGallery for the current user.')) { return $false }
            Install-Module -Name Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
        }
        if (-not (Confirm-InstallAction 'Install or repair the stable WinGet package manager for all users with Microsoft.WinGet.Client.')) { return $false }
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -ErrorAction Stop | Out-Host
    }
    Update-ProcessPath
    if (-not (Test-VmWinget)) {
        throw 'winget is not working. Check App Installer and rerun from a new elevated terminal.'
    }
    return $true
}

function Test-VmPowerShell7 {
    $path = Find-VmPowerShell
    if (-not $path) { return $false }
    $major = & $path -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major'
    if ($LASTEXITCODE -ne 0 -or "$major".Trim() -ne '7') { throw 'Check the stable PowerShell 7.x path.' }
    return $true
}

function Install-VmPowerShell {
    return (Install-VmPackage Microsoft.PowerShell 'PowerShell 7.x' `
        -VersionPattern '^7\.\d+\.\d+(?:\.\d+)?$' -TestInstalled { Test-VmPowerShell7 })
}

function Get-VmWslExecutable {
    $command = Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $path = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
}

function Invoke-VmWindowsFeature {
    param(
        [ValidateSet('VirtualMachinePlatform', 'MSMQ-Server')]
        [string]$FeatureName,
        [switch]$Enable
    )
    # DISM cmdlets can fail with "Class not registered" in MSIX PowerShell 7.
    $command = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    if (__ENABLE__) {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName '__FEATURE__' -All -NoRestart -ErrorAction Stop
        [pscustomobject]@{ RestartNeeded = [bool]$result.RestartNeeded } | ConvertTo-Json -Compress
    }
    else {
        $result = Get-WindowsOptionalFeature -Online -FeatureName '__FEATURE__' -ErrorAction Stop
        [pscustomobject]@{ State = [string]$result.State } | ConvertTo-Json -Compress
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
    $enabled = if ($Enable) { '$true' } else { '$false' }
    $command = $command.Replace('__ENABLE__', $enabled).Replace('__FEATURE__', $FeatureName)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $probe = Invoke-ToolProbe $engine @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
    if ($probe.Code -ne 0) {
        throw "Windows PowerShell feature operation failed for $FeatureName (exit code $($probe.Code)): $($probe.Text)"
    }
    $result = $probe.Text | ConvertFrom-Json -ErrorAction Stop
    if (($Enable -and $result.RestartNeeded -isnot [bool]) -or
        (-not $Enable -and [string]::IsNullOrWhiteSpace($result.State))) {
        throw "Invalid Windows PowerShell feature response for ${FeatureName}: $($probe.Text)"
    }
    return $result
}

function Test-VmWslPlatform {
    $wsl = Get-VmWslExecutable
    if (-not $wsl) { return $false }
    $feature = Invoke-VmWindowsFeature -FeatureName VirtualMachinePlatform
    if ("$($feature.State)" -ne 'Enabled') { return $false }
    return (Invoke-ToolProbe $wsl @('--status')).Code -eq 0
}

function Install-VmWslPlatform {
    if (Test-VmWslPlatform) { Write-InstallMessage '[PASS] WSL2 platform is ready.'; return $true }
    $feature = Invoke-VmWindowsFeature -FeatureName VirtualMachinePlatform
    if ("$($feature.State)" -in @('EnablePending', 'DisablePending')) { $script:RestartRequired = $true; return $false }
    $wsl = Get-VmWslExecutable
    if (-not $wsl) { throw 'wsl.exe was not found. Check the Windows 11 image and the WSL documentation.' }
    if (-not (Confirm-InstallAction 'Install the WSL2 platform without a Linux distribution (wsl.exe --install --no-distribution). A manual restart is required. Ubuntu is installed in a later step after the restart.')) {
        return $false
    }
    $null = Invoke-VmInstaller $wsl @('--install', '--no-distribution')
    if ($script:RestartRequired) { return $false }
    if (Test-VmWslPlatform) { Write-InstallMessage '[PASS] WSL2 platform is ready.'; return $true }
    # wsl.exe can return 0 while VirtualMachinePlatform waits for a restart.
    $script:RestartRequired = $true
    Write-InstallMessage '[MANUAL] The WSL2 platform becomes available after a restart. Restart manually and rerun.'
    return $false
}

function Get-VmUbuntuVersion {
    $list = Invoke-ToolProbe wsl.exe @('--list', '--verbose')
    $text = $list.Text -replace "`0", ''
    if ($list.Code -ne 0) {
        # WSL reports an empty distribution list as a nonzero exit code.
        if ($text -match '^\s*Windows Subsystem for Linux has no installed distributions\.(?:\s|$)') { return 0 }
        throw "Failed to list WSL distributions: $text"
    }
    if ($text -match '(?mi)^\s*\*?\s*Ubuntu(?:-[\w.]+)?\s+\S+\s+([12])\s*$') {
        return [int]$Matches[1]
    }
    return 0
}

function Install-VmUbuntu {
    if (-not (Test-VmWslPlatform)) {
        Write-InstallMessage '[MANUAL] Ubuntu requires the WSL2 platform. Complete the WSL2 platform step and restart first.'
        return $false
    }
    $version = Get-VmUbuntuVersion
    if ($version -eq 1) { throw 'The existing Ubuntu uses WSL1. Preserve its data and convert it to WSL2 manually.' }
    if ($version -eq 2) { Write-InstallMessage '[PASS] Verified Ubuntu on WSL2 for the current user.'; return $true }
    if (-not (Confirm-InstallAction 'Install Ubuntu on WSL2 for the current user. Set up the first Linux user manually afterward.')) {
        return $false
    }
    $null = Invoke-VmInstaller wsl.exe @('--install', '--distribution', 'Ubuntu', '--no-launch')
    if ($script:RestartRequired) { return $false }
    if ((Get-VmUbuntuVersion) -ne 2) { throw 'Could not verify Ubuntu on WSL2. Check for a pending restart and the WSL status.' }
    Write-InstallMessage '[MANUAL] Run wsl -d Ubuntu to set up the first Linux user.'
    return $true
}

function Install-VmMsmq {
    $feature = Invoke-VmWindowsFeature -FeatureName MSMQ-Server
    if ("$($feature.State)" -in @('EnablePending', 'DisablePending')) {
        $script:RestartRequired = $true
        return $false
    }
    if ("$($feature.State)" -ne 'Enabled') {
        if (-not (Confirm-InstallAction 'Enable MSMQ Server and the required Windows features. No automatic restart.')) { return $false }
        $result = Invoke-VmWindowsFeature -FeatureName MSMQ-Server -Enable
        if ($result.RestartNeeded) { $script:RestartRequired = $true; return $false }
        if ((Invoke-VmWindowsFeature -FeatureName MSMQ-Server).State -ne 'Enabled') {
            throw 'Could not verify that the MSMQ feature is enabled.'
        }
    }
    $service = Get-Service MSMQ -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        if (-not (Confirm-InstallAction 'Set the MSMQ service to start automatically and start it. No queues or data are created.')) { return $false }
        Set-Service MSMQ -StartupType Automatic -ErrorAction Stop
        Start-Service MSMQ -ErrorAction Stop
        $service = Get-Service MSMQ -ErrorAction Stop
        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    }
    Write-InstallMessage '[PASS] Verified MSMQ Server and its running service.'
    return $true
}

function Test-VmFrameworkRuntime {
    $path = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (-not (Test-Path $path)) { return $false }
    return (Get-ItemProperty $path -Name Release -ErrorAction Stop).Release -ge 528040
}

function Install-VmDotnetSdk {
    param([ValidateSet(10, 11)][int]$Major)
    return (Install-VmPackage -Id "Microsoft.DotNet.SDK.$Major" -Name ".NET $Major SDK" `
        -VersionPattern "^$Major\.\d+\.\d+$" -TestInstalled {
            $probe = Invoke-ToolProbe dotnet @('--list-sdks')
            $probe.Code -eq 0 -and $probe.Text -match "(?m)^$Major\.\d+\.\d+\s+\["
        })
}

function Test-VmVisualCppRuntime {
    foreach ($name in @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$name") -PathType Leaf)) { return $false }
    }
    return $true
}

function Install-VmVisualCppRuntime {
    return (Install-VmPackage -Id Microsoft.VCRedist.2015+.x64 -Name 'Microsoft Visual C++ v14 Redistributable (x64)' `
        -TestInstalled { Test-VmVisualCppRuntime })
}

function Get-VmPostgresClient {
    $paths = @((Join-Path $env:ProgramFiles 'PostgreSQL\18\bin\psql.exe'))
    $command = Get-Command psql -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $paths += $command.Source }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $probe = Invoke-ToolProbe $path @('--version')
        if ($probe.Code -eq 0 -and $probe.Text -match '^psql \(PostgreSQL\) 18\.\d+(?:\s|$)') { return $path }
        Write-InstallMessage "[WARN] Could not verify PostgreSQL 18 at '$path' (exit code $($probe.Code)). Output: $($probe.Text)"
    }
    Write-InstallMessage "[INFO] No working PostgreSQL 18 client was found. Checked: $($paths -join ', ')"
}

function Test-VmPostgresClient {
    return [bool](Get-VmPostgresClient)
}

function Set-VmPostgresPath {
    $client = Get-VmPostgresClient
    if (-not $client) { throw 'Cannot configure PATH without a working PostgreSQL 18 client.' }
    $directory = Split-Path -Parent $client
    $environment = Get-Item -LiteralPath 'HKCU:\Environment' -ErrorAction Stop
    $userPath = [string]$environment.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $entries = @($userPath -split ';' | ForEach-Object {
        [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\', '/')
    })
    if ($directory.TrimEnd('\', '/') -notin $entries) {
        if (-not (Confirm-InstallAction "Append '$directory' to the current user's PATH. Existing entries and their order will be preserved.")) {
            Write-InstallMessage '[MANUAL] PostgreSQL 18 user PATH configuration was skipped.'
            return $false
        }
        $separator = if ($userPath -and -not $userPath.EndsWith(';')) { ';' } else { '' }
        $kind = if ($environment.GetValueNames() -contains 'Path') {
            $environment.GetValueKind('Path')
        } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
        Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name Path -Value "$userPath$separator$directory" `
            -Type $kind -ErrorAction Stop
    }
    Update-ProcessPath
    if (-not (Test-VmCommand psql)) { throw 'User PATH was configured, but psql could not run in the installer process.' }
    $command = Get-Command psql -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if ($command.Source -ine $client) {
        Write-InstallMessage "[WARN] Another psql takes precedence in PATH: '$($command.Source)'. Existing order was preserved. Use '$client' explicitly for PostgreSQL 18."
    }
    Write-InstallMessage '[PASS] PostgreSQL 18 directory is in the user PATH and the installer PATH. Restart Windows Terminal to refresh its environment; the calling shell is unchanged.'
    return $true
}

function Install-VmPostgresClient {
    if (-not (Install-VmVisualCppRuntime)) {
        Write-InstallMessage '[MANUAL] PostgreSQL 18 client requires the x64 Visual C++ runtime. Complete that installation and any requested restart first.'
        return $false
    }
    if (-not (Install-VmPackage -Id PostgreSQL.PostgreSQL.18 -Name 'PostgreSQL 18 command-line tools (client only)' `
        -ExtraArguments @('--override', '--mode unattended --unattendedmodeui minimal --enable-components commandlinetools --disable-components server,pgAdmin,stackbuilder') `
        -TestInstalled { Test-VmPostgresClient })) { return $false }
    return (Set-VmPostgresPath)
}

function Install-VmNvm {
    param([switch]$LatestLts)
    $nvm = Get-Command nvm -CommandType Application -ErrorAction SilentlyContinue
    if ($nvm) {
        $version = Get-WorkshopReleaseVersion (Invoke-ToolProbe nvm @('version'))
        if (-not $version -or $version.Major -ne 2) { throw 'The existing nvm is not replaced automatically. Prepare nvm-windows 2.x manually.' }
    }
    else {
        $nodeLink = Join-Path $env:ProgramFiles 'nodejs'
        if ((Get-Command node -CommandType Application -ErrorAction SilentlyContinue) -or
            $env:NVM_HOME -or $env:NVM_SYMLINK -or (Test-Path -LiteralPath $nodeLink)) {
            throw 'Preserving the existing Node.js or NVM paths. Migrate to nvm-windows 2.x manually.'
        }
        $installed = Install-VmPackage -Id AuthorSoftware.NVMWindows -Name 'nvm-windows 2.x' -VersionPattern '^2\.\d+\.\d+$' -TestInstalled {
            $v = Get-WorkshopReleaseVersion (Invoke-ToolProbe nvm @('version'))
            $v -and $v.Major -eq 2
        }
        if (-not $installed) { return $false }
    }
    $probe = Invoke-ToolProbe nvm @('config', 'get', 'auto_install', '--json')
    if ($probe.Code -ne 0) { throw 'Could not read the nvm auto_install setting.' }
    $config = $probe.Text | ConvertFrom-Json -ErrorAction Stop
    if (-not $config -or -not $config.PSObject.Properties['auto_install'] -or
        $config.auto_install -isnot [bool]) { throw 'The nvm auto_install setting is invalid.' }
    if ($config.auto_install) {
        if (-not (Confirm-InstallAction 'Set nvm auto_install to false to prevent Node.js installations without consent.')) { return $false }
        $change = Invoke-ToolProbe nvm @('config', 'set', 'auto_install=false')
        if ($change.Code -ne 0) { throw "Failed to disable nvm auto_install: $($change.Text)" }
    }
    if (-not (Get-WorkshopNvmConfiguration)) {
        throw 'Set auto_install to false in the nvm config, check root, mode and enabled, and rerun.'
    }
    $installed = if ($LatestLts) { Install-WorkshopNode -Update -LatestLts } else { Install-WorkshopNode }
    if (-not $installed) { return $false }
    Test-VmNodeCommands
    return $true
}

function Test-VmNodeCommands {
    $node = Get-Command node -ErrorAction Stop | Select-Object -First 1
    if ($node.CommandType -ne 'Application' -or -not (Test-WorkshopNvmOwnership $node.Source)) {
        throw 'node does not resolve to the nvm-managed runtime. Check PowerShell aliases, functions, and PATH.'
    }
    $npm = Get-Command npm -ErrorAction Stop | Select-Object -First 1
    if ($npm.CommandType -notin @('Application', 'ExternalScript') -or
        [IO.Path]::GetFullPath((Split-Path $npm.Source -Parent)) -ine
            [IO.Path]::GetFullPath((Split-Path $node.Source -Parent)) -or
        (Split-Path $npm.Source -Leaf) -notin @('npm.exe', 'npm.cmd', 'npm.ps1')) {
        throw 'npm does not resolve to the nvm runtime directory. Check PowerShell aliases, functions, and PATH.'
    }
    $global:LASTEXITCODE = $null
    $npmVersion = (& $npm.Source --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $npmVersion -notmatch '^\d+\.\d+\.\d+') {
        throw 'The default npm command could not be verified.'
    }
}

function Get-VmVsInstance {
    param([string]$Product, [string[]]$Requires = @())
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return }
    $arguments = @('-products', "Microsoft.VisualStudio.Product.$Product", '-version', '[18.0,19.0)', '-latest', '-format', 'json', '-utf8')
    if ($Requires.Count) { $arguments += '-requires'; $arguments += $Requires }
    $probe = Invoke-ToolProbe $vswhere $arguments
    if ($probe.Code -ne 0) { throw "Failed to query Visual Studio: $($probe.Text)" }
    $instances = @($probe.Text | ConvertFrom-Json -ErrorAction Stop)
    if ($instances.Count) { return $instances[0] }
}

function Install-VmVisualStudio {
    param([ValidateSet('BuildTools')][string]$Product, [string]$ConfigFile)
    $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json -ErrorAction Stop
    $components = @($config.components)
    if (Get-VmVsInstance $Product $components) { Write-InstallMessage "[PASS] Verified the Visual Studio 2026 $Product configuration."; return $true }
    $instance = Get-VmVsInstance $Product
    if ($instance) {
        if (-not (Confirm-InstallAction "Add the missing components from $ConfigFile to the existing Visual Studio 2026 $Product. Close Visual Studio first.")) { return $false }
        $setup = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
        # setup.exe does not support the bootstrapper's --wait switch.
        $arguments = "modify --installPath `"$($instance.installationPath)`" --config `"$ConfigFile`" --passive --norestart"
        $process = Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -in @(1641, 3010)) { $script:RestartRequired = $true; return $false }
        if ($process.ExitCode -ne 0) { throw "Visual Studio modification failed (exit code $($process.ExitCode))." }
        if (-not (Get-VmVsInstance $Product $components)) { throw 'Could not verify the requested Visual Studio components.' }
        return $true
    }
    $override = "--passive --wait --norestart --config `"$ConfigFile`""
    return Install-VmPackage -Id "Microsoft.VisualStudio.$Product" -Name "Visual Studio 2026 $Product" `
        -VersionPattern '^18\.\d+\.\d+$' -ExtraArguments @('--override', $override) `
        -TestInstalled { [bool](Get-VmVsInstance $Product $components) }
}

function Get-CopilotAppVersion {
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction Stop) {
            $app = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            if ($app.PSObject.Properties['DisplayName'] -and $app.DisplayName -match '^GitHub Copilot( App)?$') {
                $version = $null
                if (-not $app.PSObject.Properties['DisplayVersion'] -or
                    -not [version]::TryParse($app.DisplayVersion, [ref]$version)) {
                    throw 'Could not read the installed GitHub Copilot app version.'
                }
                return $version
            }
        }
    }
}

function Install-CopilotApp {
    $existing = Get-CopilotAppVersion
    if ($existing) {
        Write-InstallMessage "[PASS] Keeping GitHub Copilot app $existing. Sign in manually."
        return $true
    }
    if (-not (Confirm-InstallAction 'Install the GitHub Copilot app from the official github/app stable x64 MSI.')) {
        Write-InstallMessage '[MANUAL] Skipped the GitHub Copilot app installation.'
        return $false
    }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/github/app/releases/latest' `
        -Headers @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' } `
        -UserAgent 'AgentBox-VM-Setup' -TimeoutSec 60 -ErrorAction Stop
    if ($release.prerelease -or $release.draft -or $release.tag_name -notmatch '^v?(\d+\.\d+\.\d+)$') {
        throw 'GitHub did not return a stable Copilot app release.'
    }
    $expectedVersion = [version]$Matches[1]
    $assets = @($release.assets | Where-Object name -eq 'GitHub-Copilot-windows-x64.msi')
    if ($assets.Count -ne 1 -or $assets[0].browser_download_url -notlike 'https://github.com/github/app/releases/download/*') {
        throw 'The official GitHub Copilot x64 MSI was not found.'
    }
    $path = Join-Path $env:TEMP ("vm-copilot-$([guid]::NewGuid().ToString('N')).msi")
    try {
        Invoke-WebRequest -Uri $assets[0].browser_download_url -OutFile $path -UseBasicParsing `
            -UserAgent 'AgentBox-VM-Setup' -TimeoutSec 180 -ErrorAction Stop
        $digest = if ($assets[0].PSObject.Properties['digest']) { [string]$assets[0].digest } else { '' }
        if ($digest) {
            if ($digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
                throw 'GitHub returned an unsupported Copilot MSI digest.'
            }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $Matches[1]) {
                throw 'The Copilot MSI SHA-256 digest does not match the GitHub release.'
            }
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or
            $signature.SignerCertificate.Subject -notmatch '(CN|O)="?GitHub(,? Inc\.?)?"?(,|$)') {
            throw 'The Copilot MSI does not have a valid GitHub Authenticode signature.'
        }
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
            -ArgumentList "/i `"$path`" /passive /norestart" -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -in @(1641, 3010)) {
            $script:RestartRequired = $true
            Write-InstallMessage '[MANUAL] The Copilot app requested a Windows restart. Restart manually and rerun this script.'
            return $false
        }
        if ($process.ExitCode -ne 0) { throw "Copilot app installation failed (exit code $($process.ExitCode))." }
        $installed = Get-CopilotAppVersion
        if (-not $installed -or $installed -lt $expectedVersion) {
            throw 'Could not verify the installed GitHub Copilot app version.'
        }
        Write-InstallMessage "[PASS] Installed GitHub Copilot app $installed. Sign in manually."
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
}

function Test-VmCommand {
    param([string]$Name, [string[]]$Arguments = @('--version'))
    $probe = Invoke-ToolProbe $Name $Arguments
    return $probe.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($probe.Text)
}

function Test-VmDesktopApp {
    param([string[]]$Paths)
    return @($Paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0
}

function Install-VmDocker {
    if (-not (Test-VmWslPlatform)) {
        Write-InstallMessage '[MANUAL] Docker Desktop is waiting for a ready WSL2 platform.'
        return $false
    }
    return (Install-VmPackage Docker.DockerDesktop 'Docker Desktop (WSL2 backend)' -TestInstalled {
        Test-VmDesktopApp @((Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'))
    } -ExtraArguments @('--override', 'install --backend=wsl-2'))
}

function Install-VmGit {
    return (Install-VmPackage Git.Git Git -TestInstalled { Test-VmCommand git })
}

function Install-VmGitHubCli {
    return (Install-VmPackage GitHub.cli 'GitHub CLI 2.45.0+' -TestInstalled {
        $probe = Invoke-ToolProbe gh @('--version')
        $probe.Code -eq 0 -and (Test-MinimumVersion $probe.Text '2.45.0')
    })
}

function Install-VmCopilotCli {
    return (Install-VmPackage GitHub.Copilot 'GitHub Copilot CLI' -TestInstalled {
        Test-CopilotCli -LogDirectory $logDirectory
    })
}

function Install-VmAzureCli {
    return (Install-VmPackage Microsoft.AzureCLI 'Azure CLI' -TestInstalled { Test-VmCommand az })
}

function Install-VmAzd {
    return (Install-VmPackage Microsoft.Azd azd -TestInstalled { Test-VmCommand azd @('version') })
}

function Install-VmVsCode {
    return (Install-VmPackage Microsoft.VisualStudioCode 'VS Code' -TestInstalled {
        Test-VmDesktopApp @((Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'))
    })
}

function Install-VmMicrosoftMsi {
    param([string]$Name, [string]$Uri, [string]$Sha256, [scriptblock]$TestInstalled, [string]$Properties = '')
    if (& $TestInstalled) { Write-InstallMessage "[PASS] $Name is installed. Keeping the existing installation."; return $true }
    if (-not (Confirm-InstallAction "Install $Name from the official Microsoft MSI and accept its license terms. Review https://www.microsoft.com/licensing/terms/ before continuing. No database or instance will be created.")) {
        return $false
    }
    $path = Join-Path $env:TEMP ("appmod-microsoft-$([guid]::NewGuid().ToString('N')).msi")
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $path -UseBasicParsing -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Sha256) { throw "The $Name MSI hash does not match." }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw "Could not verify a valid Microsoft signature on the $Name MSI."
        }
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
            -ArgumentList "/i `"$path`" /passive /norestart $Properties" -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -in @(1641, 3010)) { $script:RestartRequired=$true; return $false }
        if ($process.ExitCode -ne 0) { throw "$Name MSI installation failed (exit code $($process.ExitCode))." }
        Update-ProcessPath
        if (-not (& $TestInstalled)) { throw "Could not verify $Name after installation." }
        Write-InstallMessage "[PASS] Verified the $Name installation."
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
}

function Test-VmIisExpress {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ((Test-Path -LiteralPath (Join-Path $base 'IIS Express\iisexpress.exe') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $base 'IIS Express\AppServer\applicationhost.config') -PathType Leaf)) { return $true }
    }
    return $false
}

function Install-VmIisExpress {
    return (Install-VmMicrosoftMsi -Name 'IIS Express 10 x64' `
        -Uri 'https://download.visualstudio.microsoft.com/download/pr/4c26ccd0-4528-45dc-aa5c-72c557a58703/341a554d60163f8b275d1d6f97149d03a18f59bb340a15f1bd70659f237537fe/iisexpress_amd64_en-us.msi' `
        -Sha256 '341a554d60163f8b275d1d6f97149d03a18f59bb340a15f1bd70659f237537fe' -TestInstalled { Test-VmIisExpress })
}

function Test-VmLocalDb {
    $localDb = Get-Command SqlLocalDB.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $candidates = @()
    if ($localDb) { $candidates += $localDb.Source }
    foreach ($version in @('170', '160', '150')) {
        $candidates += Join-Path $env:ProgramFiles "Microsoft SQL Server\$version\Tools\Binn\SqlLocalDB.exe"
    }
    $found = $false
    foreach ($path in $candidates) {
        if ((Test-Path -LiteralPath $path) -and (Test-VmCommand $path @('versions'))) { $found = $true; break }
    }
    return $found
}

function Install-VmLocalDb {
    return (Install-VmMicrosoftMsi -Name 'SQL Server 2025 Express LocalDB x64' `
        -Uri 'https://download.visualstudio.microsoft.com/download/pr/4c26ccd0-4528-45dc-aa5c-72c557a58703/0891bf47652d88f06d76a339a5db37ddc9c801d1e973e14b3b551609f1cfa4cb/SqlLocalDB.msi' `
        -Sha256 '0891bf47652d88f06d76a339a5db37ddc9c801d1e973e14b3b551609f1cfa4cb' `
        -Properties 'IACCEPTSQLLOCALDBLICENSETERMS=YES' -TestInstalled { Test-VmLocalDb })
}

function Test-VmFrameworkTools {
    $framework = Join-Path ${env:ProgramFiles(x86)} 'Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8\mscorlib.dll'
    if (-not (Test-Path -LiteralPath $framework)) { throw '.NET Framework 4.8 Targeting Pack is missing.' }
    if (-not (Get-DotnetFrameworkBuildTools)) { throw 'MSBuild or the .NET Framework web build tools are missing.' }
    if (-not (Get-WorkshopIisExpress)) { throw 'IIS Express was not found.' }
    if (-not (Test-VmLocalDb)) { throw 'Could not verify the SQL Server LocalDB version.' }
    Write-InstallMessage '[PASS] Verified the .NET Framework 4.8 Targeting Pack, web build tools, IIS Express and LocalDB.'
    return $true
}

# Installer context and stages.
function Assert-VmInstallerContext {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Run this installer from Windows x64 PowerShell.'
    }
    if (-not $Yes -and -not (Test-InstallInteractive)) {
        throw 'Installation requires an interactive administrator session or the explicit -Yes switch.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -eq 'S-1-5-18') {
        throw 'Do not run this script as SYSTEM. Sign in as the configured local administrator and run it manually.'
    }
    $adminUsername = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ADMIN_USERNAME_BASE64__'))
    $account = Get-LocalUser -Name $adminUsername -ErrorAction Stop
    if (-not $account.Enabled -or $identity.User.Value -ne $account.SID.Value) {
        throw "Sign in as the configured local administrator $adminUsername before running this installer."
    }
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open PowerShell as administrator under the signed-in local administrator account.'
    }
}

function Invoke-VmInstallationSteps {
    param([array]$Steps)
    $failed = $false
    foreach ($step in $Steps) {
        if ($step.ContainsKey('Group')) { Write-InstallMessage "[INFO] === $($step.Group) ===" }
        try {
            if (-not (& $step.Run)) { $failed = $true; Write-InstallMessage "[MANUAL] $($step.Name) is not ready." }
        }
        catch {
            $failed = $true
            Write-InstallMessage "[FAIL] $($step.Name): $($_.Exception.Message)"
            if ($_.ScriptStackTrace) { Write-InstallMessage "[INFO] $($_.ScriptStackTrace)" }
        }
        if ($script:RestartRequired -or (Test-RebootPending)) {
            Write-InstallMessage '[MANUAL] A restart is required. The script does not restart automatically. Restart and rerun the same command.'
            return 3010
        }
    }
    if ($failed) { return 1 }
    return 0
}

function Invoke-VmToolInstallation {
    $script:RestartRequired = $false
    if (Test-RebootPending) {
        Write-InstallMessage '[MANUAL] A Windows restart is pending. Restart manually and rerun this script.'
        return 3010
    }
    $drive = Get-PSDrive -Name $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
    if ($drive.Free -lt 50GB) { throw 'Free at least 50 GiB on the system drive before installation.' }
    $steps = @(
        @{ Group='[2/8] Windows features'; Name='WSL2 platform'; Run={ Install-VmWslPlatform } },
        @{ Name='Ubuntu WSL2'; Run={ Install-VmUbuntu } },
        @{ Name='MSMQ'; Run={ Install-VmMsmq } },
        @{ Group='[3/8] Runtimes and SDKs'; Name='Visual C++ x64 runtime'; Run={ Install-VmVisualCppRuntime } },
        @{ Name='.NET Framework'; Run={
            Install-VmPackage Microsoft.DotNet.Framework.Runtime '.NET Framework 4.8.x runtime' `
                -VersionPattern '^4\.8\.1$' -TestInstalled { Test-VmFrameworkRuntime }
        } },
        @{ Name='.NET 10 SDK'; Run={ Install-VmDotnetSdk 10 } },
        @{ Name='.NET 11 SDK'; Run={ Install-VmDotnetSdk 11 } },
        @{ Name='nvm and Node.js'; Run={ Install-VmNvm } },
        @{ Group='[4/8] .NET Framework build and run tools'; Name='Visual Studio Build Tools'; Run={
            Install-VmVisualStudio BuildTools (Join-Path $PSScriptRoot 'buildtools.vsconfig')
        } },
        @{ Name='IIS Express'; Run={ Install-VmIisExpress } },
        @{ Name='SQL Server LocalDB'; Run={ Install-VmLocalDb } },
        @{ Name='Framework build and run tools'; Run={ Test-VmFrameworkTools } },
        @{ Group='[5/8] Database and containers'; Name='PostgreSQL 18 client'; Run={ Install-VmPostgresClient } },
        @{ Name='Docker Desktop'; Run={ Install-VmDocker } },
        @{ Group='[6/8] GitHub tools'; Name='Git'; Run={ Install-VmGit } },
        @{ Name='GitHub CLI'; Run={ Install-VmGitHubCli } },
        @{ Name='GitHub Copilot CLI'; Run={ Install-VmCopilotCli } },
        @{ Group='[7/8] Azure tools'; Name='Azure CLI'; Run={ Install-VmAzureCli } },
        @{ Name='azd'; Run={ Install-VmAzd } },
        @{ Group='[8/8] Editors and modernization tools'; Name='VS Code'; Run={ Install-VmVsCode } },
        @{ Name='GitHub Copilot app'; Run={ Install-CopilotApp } },
        @{ Name='Modernize CLI'; Run={
            Install-VmPackage GitHub.Copilot.modernization.agent 'Modernize CLI' -TestInstalled { Test-VmCommand modernize }
        } }
    )
    $result = Invoke-VmInstallationSteps -Steps $steps
    if ($result -eq 3010) { return $result }
    Write-InstallMessage '[MANUAL] Set up the first Ubuntu user, start Docker Desktop and confirm Linux containers, sign in to the Copilot app, authenticate gh and Copilot CLI, and verify Modernize CLI.'
    Write-InstallMessage '[INFO] Azure/GitHub sign-in, subscription changes, provider registration and lab database creation were not performed.'
    if ($result -ne 0) { return 1 }
    Write-InstallMessage '[PASS] Verified the tool installations. Validate app builds and the VM runtime separately.'
    return 0
}

# Script entry point.
if ($MyInvocation.InvocationName -eq '.') {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Dot-sourcing requires PowerShell 7. Run this script normally from Windows PowerShell 5.1.' }
}
elseif ($Help) {
    Write-Host 'Run after signing in as the configured local administrator in an elevated PowerShell terminal:'
    Write-Host '  powershell.exe -NoProfile -File "$HOME\scripts\install-vm-tools.ps1"'
    Write-Host 'Use -Yes to approve every listed installation, package agreement, and setup change.'
    Write-Host 'If a restart is requested, restart manually and rerun the same command.'
}
else {
    $ErrorActionPreference = 'Stop'
    $transcriptStarted = $false
    try {
        Assert-VmInstallerContext
        $logDirectory = Join-Path $env:ProgramData (
            'AppModBox/Logs/DevTools/{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
        )
        New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
        Start-Transcript -Path (Join-Path $logDirectory 'install.log') -ErrorAction Stop | Out-Null
        $transcriptStarted = $true
        Write-InstallMessage "[INFO] Installation logs: $logDirectory"
        $script:RestartRequired = $false
        if (Test-RebootPending) { Write-InstallMessage '[MANUAL] Restart manually and rerun this script.'; exit 3010 }
        Write-InstallMessage '[INFO] === [1/8] Installation prerequisites ==='
        if (-not (Initialize-VmWinget)) { Write-InstallMessage '[MANUAL] winget is not ready.'; exit 1 }
        if (-not (Install-VmPowerShell)) {
            if ($script:RestartRequired) { exit 3010 }
            exit 1
        }
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            exit (Invoke-VmPowerShell -ScriptPath $PSCommandPath `
                -BoundParameters @{ Track = 'dotnet'; Yes = [bool]$Yes } -RemainingArguments @())
        }
        if ($PSVersionTable.PSVersion.Major -ne 7) { throw 'Run this script in PowerShell 7.x.' }
        exit (Invoke-VmToolInstallation)
    }
    catch {
        Write-Error "[FAIL] $($_.Exception.Message)" -ErrorAction Continue
        if ($_.ScriptStackTrace) { Write-InstallMessage "[INFO] $($_.ScriptStackTrace)" }
        exit 1
    }
    finally {
        if ($transcriptStarted) { Stop-Transcript -ErrorAction Stop | Out-Null }
    }
}
