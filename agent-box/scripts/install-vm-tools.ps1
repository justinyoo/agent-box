#Requires -Version 5.1

<#
.SYNOPSIS
Installs Agent Box tools in interactive groups after per-item confirmation.
.DESCRIPTION
Run in an elevated Windows x64 user session, not as SYSTEM. Windows PowerShell
5.1 is supported so that PowerShell 7 does not need to be installed beforehand.
If necessary, bootstraps WinGet using Microsoft's Microsoft.WinGet.Client module.

The installer preserves existing tools, asks before each installation, and stops
for manual restarts. -Yes approves the listed package agreements and actions.
The script does not authenticate tools, launch Docker Desktop, or create a Linux
user. Run it as the configured local administrator after signing in.
.PARAMETER Yes
Approve all package installations, license terms, and setup changes.
.PARAMETER Help
Show usage instructions without installing tools.
.PARAMETER PythonVersion
Python major.minor version to install through uv. Defaults to 3.14.
Available patch releases depend on the installed uv version's download catalog.
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
.LINK
https://docs.astral.sh/uv/concepts/python-versions/
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Help,

    [ValidatePattern('^3\.\d+$')]
    [string]$PythonVersion = '3.14'
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
    return ([string]$result.StandardOutput).Trim()
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
        Write-InstallMessage ('[WARN] WinGet is not ready (0x{0:X8}); attempting the documented bootstrap.' -f $code)
    }

    Write-InstallMessage '[INFO] Preparing WinGet for the signed-in administrator.'
    if (-not (Confirm-InstallAction 'Install or repair WinGet and its Microsoft.WinGet.Client prerequisites.')) {
        throw 'WinGet setup was declined; no remaining tools can be installed.'
    }
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
        [string]$LogDirectory,
        [Parameter(Mandatory)]
        [ValidateSet('Prerequisites', 'Runtimes', 'Containers', 'GitHub', 'Azure', 'Editors')]
        [string]$Group
    )

    $packages = @(
        @{ Group = 'Prerequisites'; Id = 'Microsoft.PowerShell'; Name = 'PowerShell 7'; Extra = @('--installer-type', 'wix') }
        @{ Group = 'Runtimes'; Id = 'Microsoft.DotNet.SDK.10'; Name = '.NET 10 SDK'; Extra = @() }
        @{ Group = 'Runtimes'; Id = 'Microsoft.DotNet.SDK.11'; Name = '.NET 11 SDK'; Extra = @() }
        @{ Group = 'Runtimes'; Id = 'astral-sh.uv'; Name = 'uv'; Extra = @() }
        @{ Group = 'Containers'; Id = 'Docker.DockerDesktop'; Name = 'Docker Desktop (WSL2 backend)'; Extra = @('--override', 'install --backend=wsl-2') }
        @{ Group = 'GitHub'; Id = 'Git.Git'; Name = 'Git'; Extra = @() }
        @{ Group = 'GitHub'; Id = 'GitHub.cli'; Name = 'GitHub CLI'; Extra = @() }
        @{ Group = 'GitHub'; Id = 'GitHub.Copilot'; Name = 'GitHub Copilot CLI'; Extra = @() }
        @{ Group = 'Azure'; Id = 'Microsoft.AzureCLI'; Name = 'Azure CLI'; Extra = @() }
        @{ Group = 'Azure'; Id = 'Microsoft.Azd'; Name = 'Azure Developer CLI'; Extra = @() }
        @{ Group = 'Editors'; Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code'; Extra = @() }
    )
    $notInstalled = [Convert]::ToUInt32('8A150014', 16)
    $alreadyInstalled = @('8A15002B', '8A150061', '8A15010D') |
        ForEach-Object { [Convert]::ToUInt32($_, 16) }
    $rebootRequired = @('8A150109', '8A15010A') |
        ForEach-Object { [Convert]::ToUInt32($_, 16) }

    $complete = $true
    foreach ($package in $packages) {
        if ($package.Group -ne $Group) { continue }
        $id = $package.Id
        if ($id -eq 'Docker.DockerDesktop' -and -not (Test-WslPlatform)) {
            Write-InstallMessage '[MANUAL] Docker Desktop is waiting for a ready WSL2 platform.'
            $complete = $false
            continue
        }
        $query = @('list', '--id', $id, '--exact', '--source', 'winget')
        if ($Yes) {
            $query += @('--accept-source-agreements', '--disable-interactivity')
        }
        $code = Invoke-WinGetCommand -Executable $WinGetExecutable -Arguments $query `
            -LogDirectory $LogDirectory
        if ($code -eq 0) {
            Write-InstallMessage "[PASS] $($package.Name) is installed. Keeping the existing installation."
            continue
        }
        if ($code -ne $notInstalled) {
            throw ('Cannot determine whether {0} is installed (0x{1:X8}). See {2}.' -f $id, $code, $LogDirectory)
        }
        if (-not (Confirm-InstallAction "Install $($package.Name) with WinGet and accept its package agreements.")) {
            Write-InstallMessage "[MANUAL] Skipped the $($package.Name) installation."
            $complete = $false
            continue
        }

        $arguments = @(
            'install', '--id', $id, '--exact', '--source', 'winget', '--scope', 'machine',
            '--architecture', 'x64', '--silent', '--no-upgrade',
            '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity'
        )
        $arguments += $package.Extra

        $code = Invoke-WinGetCommand -Executable $WinGetExecutable -Arguments $arguments `
            -LogDirectory $LogDirectory
        if ($rebootRequired -contains $code) {
            $script:RestartRequired = $true
            Write-InstallMessage "[MANUAL] $($package.Name) requires a manual restart. Restart Windows, then run this script again."
            return $false
        }
        if ($code -ne 0 -and $alreadyInstalled -notcontains $code) {
            throw ('Installation of {0} failed (0x{1:X8}). See {2}.' -f $id, $code, $LogDirectory)
        }

        $code = Invoke-WinGetCommand -Executable $WinGetExecutable -Arguments $query `
            -LogDirectory $LogDirectory
        if ($code -ne 0) {
            throw ('{0} was not verified after installation (0x{1:X8}). See {2}.' -f $id, $code, $LogDirectory)
        }
        Write-InstallMessage "[PASS] Verified the $($package.Name) installation."
    }
    return $complete
}

function Get-NvmVersion {
    param([string]$LogDirectory)

    $output = Invoke-ToolCommand -CommandName 'nvm.exe' -Arguments @('version') `
        -LogDirectory $LogDirectory
    # NVM 2 prefixes the version with "v" and can append an edition notice.
    if ($output -notmatch '^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:\r?\n|$)') {
        throw "NVM did not report a recognizable version. See $LogDirectory."
    }
    return $Matches[1]
}

function Get-LatestNvmRelease {
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/nvm-windows/nvm/releases/latest' `
        -Headers @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' } `
        -UserAgent 'AgentBox-DevTools' -TimeoutSec 60 -ErrorAction Stop
    if ($null -eq $release -or
        -not $release.PSObject.Properties['draft'] -or
        -not $release.PSObject.Properties['prerelease'] -or
        -not $release.PSObject.Properties['tag_name'] -or
        -not $release.PSObject.Properties['assets'] -or
        $release.draft -isnot [bool] -or $release.prerelease -isnot [bool] -or
        $release.draft -or $release.prerelease -or
        $release.tag_name -notmatch '^v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$') {
        throw 'GitHub did not return valid stable NVM release metadata.'
    }
    $version = $Matches[1]
    $assetName = "nvm-$version-x64-setup.exe"
    $assets = @($release.assets | Where-Object {
        $_.PSObject.Properties['name'] -and $_.name -ceq $assetName
    })
    if ($assets.Count -ne 1) {
        throw "NVM $version must have exactly one $assetName release asset."
    }
    $asset = $assets[0]
    $expectedUrl = "https://github.com/nvm-windows/nvm/releases/download/$($release.tag_name)/$assetName"
    if (-not $asset.PSObject.Properties['browser_download_url'] -or
        $asset.browser_download_url -cne $expectedUrl -or
        -not $asset.PSObject.Properties['digest'] -or
        $asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
        throw "NVM $version has an invalid installer URL or SHA-256 digest."
    }
    return [pscustomobject]@{
        Version = $version
        DownloadUrl = $expectedUrl
        Sha256 = $Matches[1]
    }
}

function Install-NvmForWindows {
    param([string]$LogDirectory)

    Update-ProcessPath
    $existing = Get-Command nvm.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $existing) {
        $version = Get-NvmVersion -LogDirectory $LogDirectory
        Write-InstallMessage "[PASS] NVM $version is installed. Keeping the existing installation."
        return $true
    }
    if (-not (Confirm-InstallAction 'Install nvm-windows from its latest stable GitHub x64 release.')) {
        return $false
    }

    $installer = Join-Path $LogDirectory ('nvm-setup-{0}.exe' -f [guid]::NewGuid().ToString('N'))
    $originalTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $originalTls -bor [Net.SecurityProtocolType]::Tls12
        $release = Get-LatestNvmRelease
        Write-InstallMessage "[INFO] Installing NVM $($release.Version) from $($release.DownloadUrl)."
        Invoke-WebRequest -Uri $release.DownloadUrl -OutFile $installer -UseBasicParsing `
            -UserAgent 'AgentBox-DevTools' -TimeoutSec 180 -ErrorAction Stop | Out-Null
        $hash = Get-FileHash -LiteralPath $installer -Algorithm SHA256 -ErrorAction Stop
        if ($hash.Hash -ne $release.Sha256) {
            throw 'NVM installer SHA-256 does not match its GitHub release digest.'
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $installer -ErrorAction Stop
        if ($signature.Status -ne 'Valid') {
            throw "NVM installer Authenticode signature is not valid: $($signature.Status)."
        }
        $result = Invoke-LoggedProcess -Executable $installer -Arguments @(
            '/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/CURRENTUSER',
            '/NORESTART', '/RESTARTEXITCODE=3010', '/NOCLOSEAPPLICATIONS',
            '/OFFICIALNODE=ignore', ('/LOG="{0}"' -f (Join-Path $LogDirectory 'nvm-setup.log'))
        ) -LogDirectory $LogDirectory
        if ($result.ExitCode -eq 3010) {
            throw 'NVM requires a restart. Restart manually, sign in again, and rerun this script.'
        }
        if ($result.ExitCode -ne 0) {
            throw ('NVM installation failed (0x{0:X8}). See {1}.' -f $result.ExitCode, $LogDirectory)
        }
        Update-ProcessPath
        $installedVersion = Get-NvmVersion -LogDirectory $LogDirectory
        if ($installedVersion -ne $release.Version) {
            throw "NVM reports $installedVersion instead of $($release.Version). Check installer logs and PATH conflicts in $LogDirectory."
        }
        return $true
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $originalTls
        if (Test-Path -LiteralPath $installer -PathType Leaf) {
            Remove-Item -LiteralPath $installer -Force -ErrorAction Stop
        }
    }
}

function Get-WslExecutable {
    $command = Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }
    $path = Join-Path $env:SystemRoot 'System32\wsl.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
}

function Invoke-WslCommand {
    param([string]$Executable, [string[]]$Arguments)

    # A missing WSL installation reports status on stderr; inspect its exit code before deciding what to do.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = $null
    $text = (& $Executable @Arguments 2>&1 | Out-String) -replace "`0", ''
    if ($null -eq $LASTEXITCODE) { throw "$Executable did not return an exit code." }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text.Trim() }
}

function Test-WslPlatform {
    $wsl = Get-WslExecutable
    if (-not $wsl) { return $false }
    $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    if ($feature.State -ne 'Enabled') { return $false }
    return (Invoke-WslCommand $wsl @('--status')).Code -eq 0
}

function Install-WslPlatform {
    if (Test-WslPlatform) {
        Write-InstallMessage '[PASS] WSL2 platform is ready.'
        return $true
    }
    if (Test-RebootPending) {
        $script:RestartRequired = $true
        Write-InstallMessage '[MANUAL] A Windows restart is pending. Restart manually and rerun this script.'
        return $false
    }
    if (-not (Confirm-InstallAction 'Enable the WSL2 virtual machine platform without restarting Windows.')) {
        Write-InstallMessage '[MANUAL] Skipped the WSL2 platform setup.'
        return $false
    }
    $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    if ($feature.State -ne 'Enabled') {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop
        if ($result.RestartNeeded) {
            $script:RestartRequired = $true
            Write-InstallMessage '[MANUAL] WSL2 needs a Windows restart. Restart manually and rerun this script.'
            return $false
        }
    }
    $wsl = Get-WslExecutable
    if (-not $wsl) { throw 'wsl.exe was not found after enabling the WSL2 platform.' }
    if (-not (Confirm-InstallAction 'Install WSL without a Linux distribution (wsl.exe --install --no-distribution).')) {
        Write-InstallMessage '[MANUAL] Skipped the WSL2 platform installation.'
        return $false
    }
    $result = Invoke-WslCommand $wsl @('--install', '--no-distribution')
    $code = $result.Code
    if ($code -in @(1641, 3010) -or (Test-RebootPending)) {
        $script:RestartRequired = $true
        Write-InstallMessage '[MANUAL] WSL2 needs a Windows restart. Restart manually and rerun this script.'
        return $false
    }
    if ($code -ne 0) { throw "WSL2 platform installation failed (exit code $code): $($result.Text)" }
    if (-not (Test-WslPlatform)) {
        $script:RestartRequired = $true
        Write-InstallMessage '[MANUAL] WSL2 becomes available after a Windows restart. Restart manually and rerun this script.'
        return $false
    }
    Write-InstallMessage '[PASS] WSL2 platform is ready.'
    return $true
}

function Get-UbuntuWslVersion {
    $wsl = Get-WslExecutable
    $result = Invoke-WslCommand $wsl @('--list', '--verbose')
    $text = $result.Text
    if ($result.Code -ne 0) {
        if ($text -match 'Windows Subsystem for Linux has no installed distributions') { return 0 }
        throw "Could not list WSL distributions: $text"
    }
    if ($text -match '(?mi)^\s*\*?\s*Ubuntu(?:-[\w.]+)?\s+\S+\s+([12])\s*$') {
        return [int]$Matches[1]
    }
    return 0
}

function Install-UbuntuWsl {
    if (-not (Test-WslPlatform)) {
        Write-InstallMessage '[MANUAL] Ubuntu requires the WSL2 platform. Complete that step and restart first.'
        return $false
    }
    $version = Get-UbuntuWslVersion
    if ($version -eq 1) { throw 'The existing Ubuntu uses WSL1. Preserve its data and convert it to WSL2 manually.' }
    if ($version -eq 2) {
        Write-InstallMessage '[PASS] Ubuntu is installed on WSL2.'
        return $true
    }
    if (-not (Confirm-InstallAction 'Install Ubuntu on WSL2 for the current user. Create the first Linux user manually after installation.')) {
        Write-InstallMessage '[MANUAL] Skipped the Ubuntu installation.'
        return $false
    }
    $wsl = Get-WslExecutable
    $result = Invoke-WslCommand $wsl @('--install', '--distribution', 'Ubuntu', '--no-launch')
    $code = $result.Code
    if ($code -in @(1641, 3010) -or (Test-RebootPending)) {
        $script:RestartRequired = $true
        Write-InstallMessage '[MANUAL] Ubuntu requires a Windows restart. Restart manually and rerun this script.'
        return $false
    }
    if ($code -ne 0) { throw "Ubuntu installation failed (exit code $code): $($result.Text)" }
    if ((Get-UbuntuWslVersion) -ne 2) {
        throw 'Ubuntu was not verified as a WSL2 distribution. Check WSL status and rerun.'
    }
    Write-InstallMessage '[PASS] Ubuntu is installed on WSL2.'
    Write-InstallMessage '[MANUAL] Run wsl -d Ubuntu to set up the first Linux user.'
    return $true
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
    $path = Join-Path $env:TEMP ("agentbox-copilot-$([guid]::NewGuid().ToString('N')).msi")
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

function Test-DevToolCommands {
    param([string]$LogDirectory)

    Update-ProcessPath
    $checks = @(
        @{ Command = 'pwsh.exe'; Arguments = @('--version') }
        @{ Command = 'dotnet.exe'; Arguments = @('--list-sdks') }
        @{ Command = 'git.exe'; Arguments = @('--version') }
        @{ Command = 'nvm.exe'; Arguments = @('version') }
        @{ Command = 'uv.exe'; Arguments = @('--version') }
        @{ Command = 'az.cmd'; Arguments = @('version', '--output', 'json') }
        @{ Command = 'azd.exe'; Arguments = @('version') }
        @{ Command = 'gh.exe'; Arguments = @('--version') }
        @{ Command = 'copilot.exe'; Arguments = @('--version') }
        @{ Command = 'code.cmd'; Arguments = @('--version') }
    )
    foreach ($check in $checks) {
        Invoke-ToolCommand -CommandName $check.Command -Arguments $check.Arguments `
            -LogDirectory $LogDirectory | Out-Null
    }
    $dotnetSdks = Invoke-ToolCommand -CommandName 'dotnet.exe' -Arguments @('--list-sdks') -LogDirectory $LogDirectory
    foreach ($major in @(10, 11)) {
        if ($dotnetSdks -notmatch "(?m)^$major\.\d+\.\d+\s+\[") {
            throw ".NET $major SDK is missing. Install it separately, then rerun this script."
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe') -PathType Leaf)) {
        throw 'Docker Desktop was not found after package installation.'
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

function Install-NodeRuntime {
    param([string]$LogDirectory)

    $node = Get-LatestNodeLts
    if (-not (Confirm-InstallAction "Install and activate Node.js LTS $($node.Version) through nvm-windows.")) {
        Write-InstallMessage '[MANUAL] Skipped the Node.js installation.'
        return $false
    }
    $nvmVersion = [version]((Get-NvmVersion -LogDirectory $LogDirectory).Split('-')[0])
    $nodeArguments = @($node.Version)
    if ($nvmVersion.Major -lt 2) {
        $nodeArguments += '64'
    }
    # NVM 2 uses the native x64 build; a trailing "64" would request another Node version.
    Write-InstallMessage "[INFO] Installing and activating Node.js LTS $($node.Version) ($($node.Lts))."
    Invoke-ToolCommand -CommandName 'nvm.exe' -Arguments (@('install') + $nodeArguments) `
        -LogDirectory $LogDirectory | Out-Null
    Invoke-ToolCommand -CommandName 'nvm.exe' -Arguments (@('use') + $nodeArguments) `
        -LogDirectory $LogDirectory | Out-Null
    Update-ProcessPath
    $nodeJson = Invoke-ToolCommand -CommandName 'node.exe' -Arguments @(
        '-p', 'JSON.stringify({version:process.versions.node,lts:process.release.lts,arch:process.arch})'
    ) -LogDirectory $LogDirectory
    if ([string]::IsNullOrWhiteSpace($nodeJson)) {
        throw "Node.js did not return runtime information. See $LogDirectory."
    }
    $activeNode = $nodeJson | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $activeNode -or
        -not $activeNode.PSObject.Properties['version'] -or
        -not $activeNode.PSObject.Properties['lts'] -or
        -not $activeNode.PSObject.Properties['arch'] -or
        $activeNode.version -ne $node.Version -or
        $activeNode.lts -ne $node.Lts -or
        $activeNode.arch -ne 'x64') {
        throw "Active Node.js does not match LTS $($node.Version) for x64. Check NVM and PATH conflicts."
    }
    Invoke-ToolCommand -CommandName 'npm' -Arguments @('--version') `
        -LogDirectory $LogDirectory | Out-Null
    return $true
}

function Install-PythonRuntime {
    param(
        [ValidatePattern('^3\.\d+$')]
        [string]$PythonVersion,
        [string]$LogDirectory
    )
    if (-not (Confirm-InstallAction "Install the latest Python $PythonVersion patch available to uv.")) {
        Write-InstallMessage '[MANUAL] Skipped the Python installation.'
        return $false
    }
    Write-InstallMessage "[INFO] Installing the latest Python $PythonVersion patch available to uv."
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
    Write-InstallMessage "[PASS] $pythonOutput is available through uv. Existing unversioned Python commands were not replaced."
    return $true
}

# Installer context and stages.
function Assert-VmInstallerContext {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This installer requires Windows. It does not install anything on this host.'
    }
    if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Run this script in a 64-bit PowerShell process on Windows x64.'
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

function Invoke-VmToolInstallation {
    param([string]$LogDirectory, [string]$PythonVersion)

    $script:RestartRequired = $false
    $complete = $true
    Update-ProcessPath
    Write-InstallMessage '[INFO] === [1/7] Installation prerequisites ==='
    $wingetExecutable = Initialize-WinGet -LogDirectory $LogDirectory
    if (-not (Install-DevToolPackages -WinGetExecutable $wingetExecutable -LogDirectory $LogDirectory -Group Prerequisites)) {
        $complete = $false
        if ($script:RestartRequired) { return 3010 }
    }

    Write-InstallMessage '[INFO] === [2/7] Windows features ==='
    if (-not (Install-WslPlatform)) {
        $complete = $false
        if ($script:RestartRequired) { return 3010 }
    }
    if (Test-WslPlatform) {
        if (-not (Install-UbuntuWsl)) {
            $complete = $false
            if ($script:RestartRequired) { return 3010 }
        }
    }
    else {
        Write-InstallMessage '[MANUAL] Ubuntu requires the WSL2 platform. Complete that step and restart first.'
        $complete = $false
    }

    Write-InstallMessage '[INFO] === [3/7] Runtimes and SDKs ==='
    if (-not (Install-DevToolPackages -WinGetExecutable $wingetExecutable -LogDirectory $LogDirectory -Group Runtimes)) {
        $complete = $false
        if ($script:RestartRequired) { return 3010 }
    }
    try {
        if (-not (Install-NvmForWindows -LogDirectory $LogDirectory)) {
            Write-InstallMessage '[MANUAL] nvm-windows is not ready.'
            $complete = $false
        }
        elseif (-not (Install-NodeRuntime -LogDirectory $LogDirectory)) {
            $complete = $false
        }
    }
    catch {
        Write-InstallMessage "[FAIL] Node.js installation failed: $($_.Exception.Message)"
        if ($_.ScriptStackTrace) { Write-InstallMessage "[INFO] $($_.ScriptStackTrace)" }
        $complete = $false
    }
    if (-not (Install-PythonRuntime -PythonVersion $PythonVersion -LogDirectory $LogDirectory)) {
        $complete = $false
    }

    foreach ($group in @(
        @{ Name = 'Containers'; Label = '[4/7] Containers' }
        @{ Name = 'GitHub'; Label = '[5/7] GitHub tools' }
        @{ Name = 'Azure'; Label = '[6/7] Azure tools' }
        @{ Name = 'Editors'; Label = '[7/7] Editors and apps' }
    )) {
        Write-InstallMessage "[INFO] === $($group.Label) ==="
        if (-not (Install-DevToolPackages -WinGetExecutable $wingetExecutable -LogDirectory $LogDirectory -Group $group.Name)) {
            $complete = $false
            if ($script:RestartRequired) { return 3010 }
        }
    }
    if (-not (Install-CopilotApp)) { $complete = $false }
    if ($script:RestartRequired) { return 3010 }

    try {
        Test-DevToolCommands -LogDirectory $LogDirectory
    }
    catch {
        Write-InstallMessage "[FAIL] Tool verification is incomplete: $($_.Exception.Message)"
        $complete = $false
    }
    Write-InstallMessage '[MANUAL] Run wsl -d Ubuntu to create the first Linux user, then start Docker Desktop and verify Linux containers.'
    Write-InstallMessage '[INFO] Azure/GitHub authentication, Copilot app sign-in, and user onboarding were not performed.'
    if (-not $complete) {
        Write-InstallMessage '[FAIL] One or more tools were declined, failed, or could not be verified. Resolve the messages above and rerun this script.'
        return 1
    }
    Write-InstallMessage '[PASS] Tool installations and available versions were verified. Open a new terminal.'
    return 0
}

# Script entry point.
if ($Help) {
    Write-Host 'Run after signing in as the configured local administrator in an elevated PowerShell terminal:'
    Write-Host '  powershell.exe -NoProfile -File "$HOME\scripts\install-vm-tools.ps1"'
    Write-Host 'Use -Yes to approve every listed installation, package agreement, and setup change.'
    Write-Host 'If a restart is requested, restart manually and rerun the same command.'
    exit 0
}
$transcriptStarted = $false
try {
    Assert-VmInstallerContext
    $logDirectory = Join-Path $env:ProgramData (
        'AgentBox/Logs/DevTools/{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
    Start-Transcript -Path (Join-Path $logDirectory 'install.log') -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
    Write-InstallMessage "[INFO] Installation logs: $logDirectory"
    exit (Invoke-VmToolInstallation -LogDirectory $logDirectory -PythonVersion $PythonVersion)
}
catch {
    Write-Error "[FAIL] $($_.Exception.Message)" -ErrorAction Continue
    if ($_.ScriptStackTrace) { Write-InstallMessage "[INFO] $($_.ScriptStackTrace)" }
    exit 1
}
finally {
    if ($transcriptStarted) { Stop-Transcript -ErrorAction Stop | Out-Null }
}
