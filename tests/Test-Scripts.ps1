[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$paths = @(
    (Join-Path $RepositoryRoot 'agent-box')
    (Join-Path $RepositoryRoot 'appmod-box')
    (Join-Path $RepositoryRoot 'shared')
    (Join-Path $RepositoryRoot 'tests')
)
$files = foreach ($path in $paths) {
    Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File -Recurse -ErrorAction Stop
}

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$errors
    )
    if ($errors.Count -gt 0) {
        throw "PowerShell parse errors in $($file.FullName):`n$($errors | Out-String)"
    }
}

$installer = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'agent-box/scripts/install-vm-tools.ps1') -Raw
foreach ($required in @(
        "param(`n    [switch]`$Yes"
        'Install-VmDotnetSdk 10'
        'Install-VmDotnetSdk 11'
        'Install-VmDocker'
        'Install-VmCopilotCli'
        'Install-VmAzd'
        'Get-LatestNodeLts'
        'Install-VmUbuntu'
        'GitHub-Copilot-windows-x64.msi'
        'Get-AuthenticodeSignature'
)) {
    if (-not $installer.Contains($required)) {
        throw "Agent Box installer is missing required behavior: $required"
    }
}
if ($installer -match 'Complete-FirstSignInSetup|ScheduledTask|Intune|enrollment') {
    throw 'The Agent Box installer must not configure sign-in tasks or Intune enrollment.'
}

& {
    $trees = @{}
    foreach ($project in @('agent-box', 'appmod-box')) {
        $tokens = $null
        $errors = $null
        $trees[$project] = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $RepositoryRoot "$project/scripts/install-vm-tools.ps1"), [ref]$tokens, [ref]$errors
        )
    }
    foreach ($name in @('Test-InstallOutputTerminal', 'Write-InstallMessage', 'Test-InstallInteractive',
            'Confirm-InstallAction', 'Test-RebootPending', 'Invoke-LoggedProcess', 'Find-VmPowerShell',
            'Invoke-VmPowerShell', 'Update-ProcessPath', 'Test-CopilotCli',
            'Invoke-ToolProbe', 'Test-MinimumVersion', 'Invoke-VmInstaller', 'Get-VmWingetVersion',
            'Install-VmPackage', 'Test-VmWinget', 'Initialize-VmWinget', 'Test-VmPowerShell7', 'Install-VmPowerShell',
            'Get-VmWslExecutable', 'Invoke-VmWindowsFeature', 'Test-VmWslPlatform',
            'Install-VmWslPlatform', 'Get-VmUbuntuVersion', 'Install-VmUbuntu',
            'Install-VmDotnetSdk', 'Test-VmCommand', 'Test-VmDesktopApp', 'Install-VmDocker',
            'Install-VmGit', 'Install-VmGitHubCli', 'Install-VmCopilotCli',
            'Install-VmAzureCli', 'Install-VmAzd', 'Install-VmVsCode',
            'Get-PersistentRuntimePath', 'Set-PersistentRuntimePath',
            'Assert-NoRuntimeCommandConflict', 'Test-RuntimePath', 'Set-RuntimePath',
            'Get-WorkshopReleaseVersion', 'Get-WorkshopNvmConfiguration', 'Get-WorkshopNvmSelection',
            'Test-WorkshopNvmOwnership', 'Get-WorkshopNodeRelease', 'Get-LatestNodeLts',
            'Enable-VmNvmRuntimePath', 'Install-WorkshopNode', 'Install-VmNvm', 'Test-VmNodeCommands',
            'Get-CopilotAppVersion', 'Install-CopilotApp', 'Assert-VmInstallerContext',
            'Invoke-VmInstallationSteps')) {
        $definitions = foreach ($project in @('agent-box', 'appmod-box')) {
            $definition = $trees[$project].Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            if (-not $definition) { throw "Missing $project common function: $name" }
            $definition.Extent.Text
        }
        if ($definitions[0] -cne $definitions[1]) { throw "Installer common function differs: $name" }
    }
    $agentFunctions = @($trees['agent-box'].FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
    foreach ($definition in $agentFunctions) {
        if ($definition.Name -eq 'Invoke-VmToolInstallation') { continue }
        $other = $trees['appmod-box'].Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $definition.Name
        }, $true)
        if ($other -and $definition.Extent.Text -cne $other.Extent.Text) {
            throw "Installer common function differs: $($definition.Name)"
        }
    }
    foreach ($project in @('agent-box', 'appmod-box')) {
        $main = $trees[$project].Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-VmToolInstallation'
        }, $true)
        foreach ($name in @('Install-VmWslPlatform', 'Install-VmUbuntu', 'Install-VmDotnetSdk',
                'Install-VmNvm', 'Install-VmDocker', 'Install-VmGit', 'Install-VmGitHubCli',
                'Install-VmCopilotCli', 'Install-VmAzureCli', 'Install-VmAzd', 'Install-VmVsCode',
                'Install-CopilotApp', 'Invoke-VmInstallationSteps')) {
            $call = $main.Find({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $name
            }, $true)
            if (-not $call) { throw "$project does not use shared installer function $name." }
        }
    }
    $docker = @($trees['appmod-box'].FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Install-VmPackage' -and
            $node.Extent.Text -match 'Docker\.DockerDesktop'
    }, $true))
    if ($docker.Count -ne 1) { throw 'Workshop Docker installation command was not found uniquely.' }
    function Install-VmPackage {
        param($Id, $Name, $TestInstalled, $ExtraArguments)
        if ($ExtraArguments.Count -ne 2 -or $ExtraArguments[0] -ne '--override') {
            throw 'Workshop Docker installation did not supply the expected override.'
        }
        $script:AppmodDockerOverrideArgument = $ExtraArguments[1]
    }
    Invoke-Expression $docker[0].Extent.Text
}

foreach ($project in @('agent-box', 'appmod-box')) {
    & {
        Set-StrictMode -Version Latest
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $RepositoryRoot "$project/scripts/install-vm-tools.ps1"), [ref]$tokens, [ref]$errors)
        foreach ($name in @('Invoke-VmInstaller', 'Test-VmWinget', 'Install-VmPackage', 'Test-CopilotCli', 'Install-VmCopilotCli',
                'Install-VmWslPlatform', 'Get-VmUbuntuVersion', 'Install-VmUbuntu', 'Install-VmDocker',
                'Enable-VmNvmRuntimePath', 'Install-VmNvm')) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            if (-not $definition) { throw "$project missing $name." }
            Invoke-Expression $definition.Extent.Text
        }
        $Yes = $true
        $logDirectory = 'fixture'
        $script:RestartRequired = $false
        $script:Pending = $false
        $script:CliPresent = $false
        $script:CliWorks = $true
        $script:InstallCli = $true
        $script:PendingAfterInstall = $false
        $script:InstallCalls = 0
        $script:InstallerArguments = @()
        function Write-InstallMessage { }
        function Update-ProcessPath { }
        function Test-RebootPending { return $script:Pending }
        function Confirm-InstallAction { return $true }
        function Get-Command {
            param($Name)
            if ($Name -eq 'copilot' -and $script:CliPresent) {
                return [pscustomobject]@{ Source = 'fixture-copilot.exe' }
            }
        }
        function Invoke-LoggedProcess {
            if ($script:CliWorks) { return [pscustomobject]@{ ExitCode = 0; StandardOutput = '1.2.3'; CombinedOutput = '' } }
            return [pscustomobject]@{ ExitCode = 1; StandardOutput = ''; CombinedOutput = '' }
        }
        function Get-Command { return [pscustomobject]@{ Source = 'fixture-winget.exe' } }
        if (-not (Test-VmWinget)) { throw "$project did not accept a working WinGet." }
        $script:CliWorks = $false
        if (Test-VmWinget) { throw "$project accepted a failing WinGet executable." }
        $script:CliWorks = $true
        function Get-Command {
            param($Name)
            if ($Name -eq 'copilot' -and $script:CliPresent) {
                return [pscustomobject]@{ Source = 'fixture-copilot.exe' }
            }
        }
        function Invoke-VmInstaller {
            param($Command, $Arguments)
            $script:InstallCalls++
            $script:InstallerArguments = $Arguments
            if ($script:InstallCli) { $script:CliPresent = $true }
            if ($script:PendingAfterInstall) { $script:Pending = $true }
            return $true
        }
        $script:CliPresent = $true
        if (-not (Install-VmCopilotCli) -or $script:InstallCalls -ne 0) {
            throw "$project did not preserve a working Copilot CLI."
        }
        $script:CliPresent = $false
        if (-not (Install-VmCopilotCli) -or $script:InstallCalls -ne 1 -or
            $script:InstallerArguments -notcontains '--accept-package-agreements') {
            throw "$project did not install and verify Copilot CLI with approved agreements."
        }
        $script:CliPresent = $false; $script:PendingAfterInstall = $true; $script:RestartRequired = $false
        if ((Install-VmCopilotCli) -or -not $script:RestartRequired) {
            throw "$project ignored a restart requested during package installation."
        }
        $script:Pending = $false; $script:PendingAfterInstall = $false; $script:RestartRequired = $false
        $script:CliPresent = $false; $script:InstallCli = $false
        $failed = $false
        try { Install-VmCopilotCli | Out-Null }
        catch { $failed = $_.Exception.Message -match 'Could not verify' }
        if (-not $failed) { throw "$project accepted a missing Copilot CLI after installation." }
        $script:CliPresent = $true; $script:CliWorks = $false
        $failed = $false
        try { Install-VmCopilotCli | Out-Null }
        catch { $failed = $_.Exception.Message -match 'could not be verified' }
        if (-not $failed) { throw "$project accepted a broken Copilot CLI." }
        $script:Pending = $true; $script:RestartRequired = $false
        if ((Install-VmCopilotCli) -or -not $script:RestartRequired) {
            throw "$project ignored a pending Windows restart."
        }

        $script:PlatformReady = $false; $script:PlatformState = 'Disabled'
        $script:RestartRequired = $false; $script:WslInstallCalls = 0
        function Test-VmWslPlatform { return $script:PlatformReady }
        function Get-VmWslExecutable { return 'fixture-wsl.exe' }
        function Invoke-VmWindowsFeature { return [pscustomobject]@{ State = $script:PlatformState } }
        function Invoke-VmInstaller {
            param($Command, $Arguments)
            if (($Arguments -join ' ') -ne '--install --no-distribution') { throw 'Unexpected WSL arguments.' }
            $script:WslInstallCalls++
            return $true
        }
        if ((Install-VmWslPlatform) -or -not $script:RestartRequired -or $script:WslInstallCalls -ne 1) {
            throw "$project failed to stop for a required WSL restart."
        }
        $script:RestartRequired = $false; $script:PlatformState = 'EnablePending'
        if ((Install-VmWslPlatform) -or -not $script:RestartRequired -or $script:WslInstallCalls -ne 1) {
            throw "$project reinstalled a pending WSL platform."
        }
        $script:PlatformReady = $true
        $script:DistroText = '* Ubuntu-24.04 Stopped 2'; $script:DistroCode = 0
        function Invoke-ToolProbe { return [pscustomobject]@{ Code = $script:DistroCode; Text = $script:DistroText } }
        if ((Get-VmUbuntuVersion) -ne 2 -or -not (Install-VmUbuntu)) {
            throw "$project did not preserve an existing versioned Ubuntu on WSL2."
        }
        $script:DistroText = '* Ubuntu Stopped 1'
        $failed = $false
        try { Install-VmUbuntu | Out-Null }
        catch { $failed = $_.Exception.Message -match 'WSL1' }
        if (-not $failed) { throw "$project accepted an existing Ubuntu WSL1 installation." }
        $script:DistroCode = 1; $script:DistroText = 'Access is denied.'
        $failed = $false
        try { Get-VmUbuntuVersion | Out-Null }
        catch { $failed = $_.Exception.Message -match 'Access is denied' }
        if (-not $failed) { throw "$project ignored a WSL distribution query failure." }
        $script:PlatformReady = $false
        if (Install-VmDocker) { throw "$project did not block Docker when WSL is unavailable." }

        $script:Ownership = $false; $script:PathCalls = 0
        $config = [pscustomobject]@{ root = (Join-Path ([IO.Path]::GetTempPath()) 'nvm-test/root') }
        function Test-Path { return $true }
        function Test-WorkshopNvmOwnership { return $script:Ownership }
        function Set-RuntimePath { $script:PathCalls++ }
        $failed = $false
        try { Enable-VmNvmRuntimePath $config }
        catch { $failed = $_.Exception.Message -match 'not safely managed' }
        if (-not $failed -or $script:PathCalls -ne 0) {
            throw "$project accepted an unmanaged Node runtime for PATH."
        }
        $script:Ownership = $true
        Enable-VmNvmRuntimePath $config
        if ($script:PathCalls -ne 1) { throw "$project did not prepare the managed Node runtime PATH." }

        function Get-Command { return [pscustomobject]@{ Source = 'fixture-nvm.exe' } }
        function Get-WorkshopReleaseVersion { return [version]'2.0.1' }
        function Invoke-ToolProbe { return [pscustomobject]@{ Code = 0; Text = '{"auto_install":false}' } }
        function Get-WorkshopNvmConfiguration { return [pscustomobject]@{ auto_install = $false } }
        function Install-WorkshopNode {
            param([switch]$Update, [switch]$LatestLts)
            $script:LatestLtsRequested = $LatestLts -and $Update
            return $true
        }
        function Test-VmNodeCommands { }
        if (-not (Install-VmNvm -LatestLts) -or -not $script:LatestLtsRequested) {
            throw "$project did not pass the latest LTS requirement to the shared Node installer."
        }
        if (-not (Install-VmNvm) -or $script:LatestLtsRequested) {
            throw "$project changed the workshop default Node version policy."
        }
    }
}

foreach ($project in @('agent-box', 'appmod-box')) {
    & {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $RepositoryRoot "$project/scripts/install-vm-tools.ps1"), [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-VmInstaller'
        }, $true)
        Invoke-Expression $definition.Extent.Text
        $logDirectory = 'fixture'
        function Get-Command { return [pscustomobject]@{ Source = 'fixture.exe' } }
        function Write-InstallMessage { }
        function Invoke-LoggedProcess {
            return [pscustomobject]@{ ExitCode = $script:ExitCode; CombinedOutput = 'fixture diagnostics' }
        }
        foreach ($code in @([uint32]3010, [Convert]::ToUInt32('8A150109', 16),
                [Convert]::ToUInt32('8A15010A', 16))) {
            $script:ExitCode = $code; $script:RestartRequired = $false
            if (-not (Invoke-VmInstaller fixture @()) -or -not $script:RestartRequired) {
                throw "$project did not preserve restart exit code $code."
            }
        }
        $script:ExitCode = 42; $script:RestartRequired = $false; $failed = $false
        try { Invoke-VmInstaller fixture @() | Out-Null }
        catch { $failed = $_.Exception.Message -match 'exit code 42.*fixture diagnostics' }
        if (-not $failed) { throw "$project discarded native installation diagnostics." }
    }
}

foreach ($project in @('agent-box', 'appmod-box')) {
    & {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $RepositoryRoot "$project/scripts/install-vm-tools.ps1"), [ref]$tokens, [ref]$errors)
        foreach ($name in @('Install-WorkshopNode', 'Get-WorkshopReleaseVersion')) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            Invoke-Expression $definition.Extent.Text
        }
        $Yes = $true
        $script:SelectedPolicy = ''
        $script:NodeCommandType = 'Application'
        function Update-ProcessPath { }
        function Write-InstallMessage { }
        function Get-Command {
            param($Name)
            $type = if ($Name -eq 'node') { $script:NodeCommandType } else { 'Application' }
            return [pscustomobject]@{ CommandType = $type; Source = "fixture-$Name.exe" }
        }
        function Test-WorkshopNvmOwnership { return $true }
        function Get-WorkshopNvmConfiguration {
            return [pscustomobject]@{ root = (Join-Path ([IO.Path]::GetTempPath()) 'nvm-test/root'); mode = 'shim' }
        }
        function Get-WorkshopNvmSelection { return [pscustomobject]@{ Version = [version]'22.1.0'; IsEmpty = $false } }
        function Invoke-ToolProbe {
            param($Name, $Arguments)
            if ($Name -eq 'nvm') { return [pscustomobject]@{ Code = 0; Text = '2.0.1' } }
            return [pscustomobject]@{ Code = 0; Text = 'v22.1.0' }
        }
        function Get-LatestNodeLts {
            $script:SelectedPolicy = 'lts'
            return [pscustomobject]@{ Version = '24.2.0'; Lts = 'fixture' }
        }
        function Get-WorkshopNodeRelease {
            param($Major)
            $script:SelectedPolicy = "major:$Major"
            return [version]'22.2.0'
        }
        function Test-Path { return $false }
        function Confirm-InstallAction { return $false }
        if (-not (Install-WorkshopNode -Update -LatestLts) -or $script:SelectedPolicy -ne 'lts') {
            throw "$project did not select the latest LTS for Agent Box."
        }
        if (-not (Install-WorkshopNode -Update) -or $script:SelectedPolicy -ne 'major:22') {
            throw "$project did not preserve the workshop Node major policy."
        }
        $script:NodeCommandType = 'Alias'; $script:SelectedPolicy = ''; $failed = $false
        try { Install-WorkshopNode -Update -LatestLts | Out-Null }
        catch { $failed = $_.Exception.Message -match 'existing node command' }
        if (-not $failed -or $script:SelectedPolicy) {
            throw "$project did not reject a Node alias before selecting or installing a runtime."
        }
    }
}

& {
    Set-StrictMode -Version Latest
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Install-VmPowerShell', 'Invoke-VmPowerShell', 'Get-VmWingetVersion', 'Test-VmPowerShell7')) {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $definition) { throw "Missing Agent Box PowerShell function: $name" }
        Invoke-Expression $definition.Extent.Text
    }
    $script:PowerShellReady = $false
    $script:PowerShellInstalls = 0
    $script:PowerShellInstallResult = $true
    function Find-VmPowerShell {
        if ($script:PowerShellReady) { return (Get-Process -Id $PID).Path }
    }
    function Install-VmPackage {
        param($Id, $Name, $VersionPattern, $TestInstalled)
        if ($Id -ne 'Microsoft.PowerShell') { throw 'Unexpected bootstrap package.' }
        if (& $TestInstalled) { return $true }
        $script:PowerShellInstalls++
        if (-not $script:PowerShellInstallResult) { return $false }
        $script:PowerShellReady = $true
        return $true
    }
    function Write-InstallMessage { }
    function Test-InstallInteractive { return $false }
    $Yes = $true
    $script:PowerShellVersions = "8.0.0`n7.4.10`n7.5.2`n7.6.0-preview.1"
    function Get-Command { return [pscustomobject]@{ Source = 'fixture-winget' } }
    function Invoke-LoggedProcess {
        return [pscustomobject]@{ ExitCode = 0; StandardOutput = $script:PowerShellVersions }
    }
    $logDirectory = 'temp'
    if ((Get-VmWingetVersion Microsoft.PowerShell '^7\.\d+\.\d+(?:\.\d+)?$') -ne '7.5.2') {
        throw 'PowerShell bootstrap did not select the newest stable 7.x release.'
    }
    $script:PowerShellVersions = "8.0.0`n7.6.0-preview.1"
    $failed = $false
    try { Get-VmWingetVersion Microsoft.PowerShell '^7\.\d+\.\d+(?:\.\d+)?$' | Out-Null }
    catch { $failed = $_.Exception.Message -match 'No stable' }
    if (-not $failed) { throw 'PowerShell bootstrap accepted a preview or a non-7.x version.' }
    $script:PowerShellInstallResult = $false
    if (Install-VmPowerShell) {
        throw 'A declined or restart-required PowerShell installation was reported as ready.'
    }
    $script:PowerShellInstallResult = $true
    $script:PowerShellInstalls = 0
    if (-not (Install-VmPowerShell) -or
        -not (Install-VmPowerShell) -or
        $script:PowerShellInstalls -ne 1) {
        throw 'PowerShell bootstrap did not install once and preserve an existing installation.'
    }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("agentbox-worker-test-" + [guid]::NewGuid().ToString('N'))
    $worker = Join-Path $temporary 'worker with spaces.ps1'
    $result = Join-Path $temporary 'result.json'
    $previousOutput = $env:AGENTBOX_BOOTSTRAP_TEST_OUTPUT
    try {
        $null = New-Item -ItemType Directory -Path $temporary
        [IO.File]::WriteAllText($worker, @'
param([string]$PythonVersion, [switch]$Yes)
@{ PythonVersion = $PythonVersion; Yes = [bool]$Yes } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $env:AGENTBOX_BOOTSTRAP_TEST_OUTPUT
exit 37
'@)
        $env:AGENTBOX_BOOTSTRAP_TEST_OUTPUT = $result
        $code = Invoke-VmPowerShell -ScriptPath $worker -BoundParameters @{ PythonVersion = '3.14'; Yes = $true }
        $stored = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
        if ($code -ne 37 -or $stored.PythonVersion -ne '3.14' -or -not $stored.Yes) {
            throw 'Agent Box PowerShell bootstrap did not preserve parameters or the worker exit code.'
        }
        $code = Invoke-VmPowerShell -ScriptPath $worker -BoundParameters @{ PythonVersion = '3.13'; Yes = $false }
        $stored = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
        if ($code -ne 37 -or $stored.PythonVersion -ne '3.13' -or $stored.Yes) {
            throw 'Agent Box PowerShell bootstrap did not preserve a false consent switch.'
        }
    }
    finally {
        $env:AGENTBOX_BOOTSTRAP_TEST_OUTPUT = $previousOutput
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

& {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Confirm-InstallAction')) {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $definition) { throw "Missing installer function: $name" }
        Invoke-Expression $definition.Extent.Text
    }

    $messages = [Collections.Generic.List[string]]::new()
    function Write-InstallMessage { param([string]$Message) $messages.Add($Message) }
    function Test-InstallInteractive { return $interactive }
    function Read-Host { param([string]$Prompt) return $answer }
    $Yes = $false
    $interactive = $true
    foreach ($case in @(
        @{ Answer = 'y'; Approved = $true }
        @{ Answer = 'Y'; Approved = $true }
        @{ Answer = 'yes'; Approved = $true }
        @{ Answer = 'YES'; Approved = $true }
        @{ Answer = 'n'; Approved = $false }
        @{ Answer = ''; Approved = $false }
    )) {
        $answer = $case.Answer
        if ((Confirm-InstallAction 'Install a tool.') -ne $case.Approved) {
            throw "Incorrect consent decision for '$answer'."
        }
    }
    $interactive = $false
    $blocked = $false
    try { Confirm-InstallAction 'Install a tool.' | Out-Null }
    catch { $blocked = $true }
    if (-not $blocked) { throw 'Non-interactive consent without -Yes was accepted.' }
    $Yes = $true
    if (-not (Confirm-InstallAction 'Install a tool.')) { throw '-Yes did not approve the installation.' }


}

& {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Invoke-VmInstallationSteps', 'Invoke-VmToolInstallation')) {
        $main = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $main) { throw "Agent Box installation function $name was not found." }
        Invoke-Expression $main.Extent.Text
    }
    $events = [Collections.Generic.List[string]]::new()
    $messages = [Collections.Generic.List[string]]::new()
    $packageFailure = ''
    $nodeFailure = $false
    function Write-InstallMessage { param([string]$Message) $messages.Add($Message) }
    function Update-ProcessPath { }
    function Test-RebootPending { return $false }
    function Install-VmDotnetSdk {
        param($Major)
        $events.Add("sdk:$Major")
        if ($Major -eq 10 -and $packageFailure) {
            if ($packageFailure -eq 'restart') { $script:RestartRequired = $true }
            return $false
        }
        return $true
    }
    function Install-VmPackage { param($Id) $events.Add("package:$Id"); return $true }
    function Install-VmWslPlatform { $events.Add('wsl'); return $true }
    function Install-VmUbuntu { $events.Add('ubuntu'); return $true }
    function Install-VmDocker { $events.Add('docker'); return $true }
    function Install-VmGit { $events.Add('git'); return $true }
    function Install-VmGitHubCli { $events.Add('gh'); return $true }
    function Install-VmCopilotCli { $events.Add('copilot-cli'); return $true }
    function Install-VmAzureCli { $events.Add('az'); return $true }
    function Install-VmAzd { $events.Add('azd'); return $true }
    function Install-VmVsCode { $events.Add('vscode'); return $true }
    function Install-VmNvm {
        param([switch]$LatestLts)
        if (-not $LatestLts) { throw 'Agent Box must request the latest LTS.' }
        $events.Add('nvm')
        $events.Add('node')
        if ($nodeFailure) { throw 'fixture Node failure' }
        return $true
    }
    function Install-PythonRuntime {
        param([string]$PythonVersion, [string]$LogDirectory)
        $events.Add("python:$PythonVersion")
        return $true
    }
    function Install-CopilotApp { $events.Add('copilot-app'); return $true }
    function Test-RuntimeCommands { param([string]$LogDirectory) $events.Add('runtime-verification') }
    if ((Invoke-VmToolInstallation -LogDirectory 'temp' -PythonVersion '3.14') -ne 0) {
        throw 'Agent Box installation did not report success.'
    }
    $expectedEvents = @(
        'wsl', 'ubuntu', 'sdk:10', 'sdk:11', 'package:astral-sh.uv',
        'nvm', 'node', 'python:3.14', 'docker', 'git', 'gh', 'copilot-cli',
        'az', 'azd', 'vscode', 'copilot-app', 'runtime-verification'
    )
    if (($events -join ',') -cne ($expectedEvents -join ',')) {
        throw "Unexpected Agent Box installation order: $($events -join ',')."
    }
    $stages = @($messages | Where-Object { $_ -match '^\[INFO\] === \[\d/7\]' })
    if ($stages.Count -ne 6) { throw 'Agent Box did not display the six post-bootstrap installation stages.' }
    for ($index = 0; $index -lt $stages.Count; $index++) {
        if (-not $stages[$index].Contains("[$($index + 2)/7]")) {
            throw 'Agent Box installation stage numbers are out of order.'
        }
    }
    $events.Clear()
    $messages.Clear()
    $nodeFailure = $true
    if ((Invoke-VmToolInstallation -LogDirectory 'temp' -PythonVersion '3.14') -ne 1 -or
        $events -notcontains 'python:3.14' -or
        -not ($messages | Where-Object { $_ -match '^\[FAIL\] nvm and Node\.js: fixture Node failure' })) {
        throw 'A Node.js failure prevented Python installation or was not reported.'
    }
    $nodeFailure = $false
    $packageFailure = 'restart'
    if ((Invoke-VmToolInstallation -LogDirectory 'temp' -PythonVersion '3.14') -ne 3010) {
        throw 'Agent Box did not return the restart-required status.'
    }
    $packageFailure = 'incomplete'
    if ((Invoke-VmToolInstallation -LogDirectory 'temp' -PythonVersion '3.14') -ne 1) {
        throw 'Agent Box did not return an incomplete-installation status.'
    }
}

& {
    Set-StrictMode -Version Latest
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Invoke-ToolCommand', 'Install-PythonRuntime')) {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $definition) { throw "Missing Agent Box runtime function: $name" }
        Invoke-Expression $definition.Extent.Text
    }
    function Get-Command {
        param($Name, $CommandType, $ErrorAction)
        if ($Name -eq 'fixture.exe') { return [pscustomobject]@{ Source = 'fixture.exe' } }
        if ($Name -eq 'node' -and ($script:ConflictName -eq 'node' -or $script:CurrentNode)) {
            return [pscustomobject]@{ CommandType = 'Application'; Source = 'other-node.exe' }
        }
    }
    function Invoke-LoggedProcess {
        param($Executable, $Arguments, $LogDirectory)
        return [pscustomobject]@{ ExitCode = 0; StandardOutput = $null }
    }
    $output = Invoke-ToolCommand -CommandName 'fixture.exe' -Arguments @() -LogDirectory 'temp'
    if ($output -ne '') { throw 'Successful native commands with no stdout must return an empty string.' }

    $calls = [Collections.Generic.List[string]]::new()
    $script:NodeOutput = '{"version":"26.13.1","lts":"fixture","arch":"x64"}'
    $pythonPath = (Get-Process -Id $PID).Path
    $binDirectory = Split-Path $pythonPath -Parent
    $defaultPython = Join-Path $binDirectory 'python.exe'
    $script:DefaultIdentity = 'managed-python'
    $script:DefaultExists = $true
    $script:ConflictName = ''
    $script:CurrentNode = $false
    $script:PersistentConflict = ''
    function Confirm-InstallAction { return $true }
    function Write-InstallMessage { }
    function Update-ProcessPath { }
    function Get-NvmRuntimeDirectory { return $binDirectory }
    function Set-RuntimePath {
        param($Directory, $Executable, $Name)
        Assert-NoRuntimeCommandConflict -Name $Name -ExpectedPath (Join-Path $Directory $Executable)
        $null = Test-RuntimePath -Directory $Directory -Executable $Executable
        $calls.Add("path $Directory $Executable")
    }
    function Assert-NoRuntimeCommandConflict {
        param($Name, $ExpectedPath)
        if ($script:ConflictName -eq $Name) { throw "fixture $Name conflict" }
    }
    function Test-RuntimePath {
        param($Directory, $Executable)
        if ($Executable -eq $script:PersistentConflict) { throw "fixture $Executable PATH conflict" }
        return $false
    }
    function Assert-RuntimeCommand {
        param($Name, $ExpectedPath)
        $calls.Add("resolve $Name $ExpectedPath")
    }
    function Test-Path {
        param($LiteralPath, $PathType)
        if ($LiteralPath -eq $defaultPython) { return $script:DefaultExists }
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType
    }
    function Get-LatestNodeLts { return [pscustomobject]@{ Version = '26.13.1'; Lts = 'fixture' } }
    function Get-NvmVersion { return '2.0.1' }
    function Invoke-ToolCommand {
        param($CommandName, $Arguments, $LogDirectory)
        $calls.Add("$CommandName $($Arguments -join ' ')")
        if ($CommandName -eq 'node.exe') { return $script:NodeOutput }
        if ($CommandName -eq 'uv.exe' -and $Arguments[0] -eq 'python' -and $Arguments[1] -eq 'find') {
            return $pythonPath
        }
        if ($CommandName -eq 'uv.exe' -and $Arguments[0] -eq 'python' -and $Arguments[1] -eq 'dir') {
            return $binDirectory
        }
        if ($CommandName -eq 'uv.exe' -and $Arguments -contains '--default') {
            $script:DefaultExists = $true
        }
        if ($CommandName -eq $pythonPath -and $Arguments[0] -eq '--version') { return 'Python 3.14.2' }
        if ($CommandName -eq $pythonPath -and $Arguments[0] -eq '-c') { return 'managed-python' }
        if ($CommandName -eq $defaultPython -and $Arguments[0] -eq '-c') { return $script:DefaultIdentity }
        return ''
    }
    if (-not (Install-PythonRuntime -PythonVersion '3.14' -LogDirectory 'temp')) {
        throw 'The uv-managed Python installation was not verified.'
    }
    if ($calls -notcontains 'uv.exe python install 3.14 --upgrade --no-config --no-progress' -or
        $calls -notcontains 'uv.exe python install 3.14 --default --no-config --no-progress' -or
        $calls -notcontains 'uv.exe python find cpython3.14 --managed-python --no-python-downloads --no-project --system --no-config' -or
        $calls -notcontains 'uv.exe python dir --bin --no-config' -or
        $calls -notcontains "path $binDirectory python.exe" -or
        $calls -notcontains "resolve python $defaultPython") {
        throw 'The latest Python 3.14 patch was not installed and located through uv.'
    }
    $calls.Clear()
    $script:DefaultIdentity = 'unrelated-python'
    $failed = $false
    try { Install-PythonRuntime -PythonVersion '3.14' -LogDirectory 'temp' | Out-Null }
    catch { $failed = $_.Exception.Message -match 'not the selected uv-managed interpreter' }
    if (-not $failed -or $calls -contains 'uv.exe python install 3.14 --default --no-config --no-progress' -or
        @($calls | Where-Object { $_ -like 'path *' }).Count -ne 0) {
        throw 'An unrelated Python in the uv bin directory was accepted or overwritten.'
    }
    $script:DefaultIdentity = 'managed-python'
    $script:ConflictName = 'python'
    $script:DefaultExists = $false
    $calls.Clear()
    $failed = $false
    try { Install-PythonRuntime -PythonVersion '3.14' -LogDirectory 'temp' | Out-Null }
    catch { $failed = $_.Exception.Message -match 'fixture python conflict' }
    if (-not $failed -or $calls -notcontains 'uv.exe python install 3.14 --upgrade --no-config --no-progress' -or
        $calls -notcontains 'uv.exe python install 3.14 --default --no-config --no-progress' -or
        -not $script:DefaultExists -or @($calls | Where-Object { $_ -like 'path *' }).Count -ne 0) {
        throw 'A conflicting Python command prevented creation or allowed PATH changes.'
    }
    $script:ConflictName = ''
    $script:PersistentConflict = 'python.exe'
    $script:DefaultExists = $false
    $calls.Clear()
    $failed = $false
    try { Install-PythonRuntime -PythonVersion '3.14' -LogDirectory 'temp' | Out-Null }
    catch { $failed = $_.Exception.Message -match 'python.exe PATH conflict' }
    if (-not $failed -or $calls -notcontains 'uv.exe python install 3.14 --default --no-config --no-progress' -or
        -not $script:DefaultExists -or @($calls | Where-Object { $_ -like 'path *' }).Count -ne 0) {
        throw 'A persistent PATH conflict prevented creation or allowed PATH changes.'
    }
}

& {
    Set-StrictMode -Version Latest
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-ProcessPath'
    }, $true)
    Invoke-Expression $definition.Extent.Text
    $originalPath = $env:Path
    $originalNvmHome = $env:NVM_HOME
    $originalNvmSymlink = $env:NVM_SYMLINK
    try {
        $env:Path = 'fixture-first;fixture-second'
        Update-ProcessPath
        $entries = @($env:Path -split ';')
        if ($entries.Count -lt 2 -or $entries[0] -cne 'fixture-first' -or $entries[1] -cne 'fixture-second') {
            throw 'Refreshing process PATH changed the original entry order.'
        }
    }
    finally {
        $env:Path = $originalPath
        $env:NVM_HOME = $originalNvmHome
        $env:NVM_SYMLINK = $originalNvmSymlink
    }
}

& {
    Set-StrictMode -Version Latest
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Assert-NoRuntimeCommandConflict', 'Test-RuntimePath', 'Set-RuntimePath', 'Assert-RuntimeCommand', 'Test-RuntimeCommands', 'Test-VmNodeCommands')) {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $definition) { throw "Missing runtime PATH function: $name" }
        Invoke-Expression $definition.Extent.Text
    }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("agentbox-path-" + [guid]::NewGuid().ToString('N'))
    $originalFixtureEnv = $env:AGENTBOX_PATH_FIXTURE
    $originalNvmSymlink = $env:NVM_SYMLINK
    $originalLocalAppData = $env:LOCALAPPDATA
    $originalPath = $env:Path
    try {
        $preferred = Join-Path $fixture 'preferred'
        $conflict = Join-Path $fixture 'conflict'
        $other = Join-Path $fixture 'other'
        foreach ($directory in @($preferred, $conflict, $other)) {
            $null = [IO.Directory]::CreateDirectory($directory)
        }
        [IO.File]::WriteAllText((Join-Path $preferred 'python.exe'), '')
        [IO.File]::WriteAllText((Join-Path $conflict 'python.exe'), '')
        $env:AGENTBOX_PATH_FIXTURE = $fixture
        $script:PathValues = @{ User = "$other;%AGENTBOX_PATH_FIXTURE%/preferred;$preferred"; Machine = $other }
        $writes = [Collections.Generic.List[string]]::new()
        $script:AllowPath = $true
        function Get-PersistentRuntimePath { param($Scope) return $script:PathValues[$Scope] }
        function Set-PersistentRuntimePath {
            param($Scope, $Value)
            $script:PathValues[$Scope] = $Value
            $writes.Add($Scope)
        }
        function Confirm-InstallAction { return $script:AllowPath }
        function Write-InstallMessage { }
        function Update-ProcessPath { }
        function Get-Command { }
        Set-RuntimePath -Directory $preferred -Executable 'python.exe' -Name python
        if ($script:PathValues.User -cne "$other;%AGENTBOX_PATH_FIXTURE%/preferred;$preferred" -or $writes.Count) {
            throw 'Existing PATH entries or their order were changed.'
        }
        $script:PathValues.User = "$other;%AGENTBOX_PATH_FIXTURE%/other"
        Set-RuntimePath -Directory $preferred -Executable 'python.exe' -Name python
        if ($script:PathValues.User -cne "$other;%AGENTBOX_PATH_FIXTURE%/other;$preferred" -or
            $writes.Count -ne 1 -or $writes[0] -ne 'User') {
            throw 'Runtime directory was not appended while preserving the original user PATH.'
        }
        Set-RuntimePath -Directory $preferred -Executable 'python.exe' -Name python
        if ($writes.Count -ne 1) { throw 'Repeated PATH setup was not idempotent.' }
        $script:PathValues.Machine = "%AGENTBOX_PATH_FIXTURE%/conflict;$other"
        $writes.Clear()
        $failed = $false
        try { Set-RuntimePath -Directory $preferred -Executable 'python.exe' -Name python }
        catch { $failed = $_.Exception.Message -match 'conflict manually' }
        if (-not $failed -or $writes.Count -or $script:PathValues.Machine -cne "%AGENTBOX_PATH_FIXTURE%/conflict;$other") {
            throw 'System PATH conflict was not reported without modifying PATH.'
        }
        $script:PathValues.Machine = $other
        $script:PathValues.User = "$conflict;$preferred"
        $failed = $false
        try { Set-RuntimePath -Directory $preferred -Executable 'python.exe' -Name python }
        catch { $failed = $_.Exception.Message -match 'conflict manually' }
        if (-not $failed -or $writes.Count) { throw 'User PATH conflict was not reported without modifying PATH.' }
        $script:PathValues.User = $other
        $script:PathValues.Machine = $other
        $script:AllowPath = $false
        $writes.Clear()
        $failed = $false
        try { Set-RuntimePath -Directory $preferred -Executable 'python.exe' -Name python }
        catch { $failed = $_.Exception.Message -match 'declined' }
        if (-not $failed -or $writes.Count) { throw 'Declined user PATH change was not respected.' }
        $failed = $false
        try { Set-RuntimePath -Directory $other -Executable 'python.exe' -Name python }
        catch { $failed = $_.Exception.Message -match 'invalid' }
        if (-not $failed -or $writes.Count) { throw 'A missing runtime executable was accepted.' }

        $script:CommandFixture = [pscustomobject]@{ CommandType = 'Application'; Source = (Join-Path $preferred 'python.exe') }
        function Get-Command { return $script:CommandFixture }
        Assert-RuntimeCommand -Name python -ExpectedPath (Join-Path $preferred 'python.exe')
        $script:CommandFixture = [pscustomobject]@{ CommandType = 'Function'; Source = 'python' }
        $failed = $false
        try { Assert-RuntimeCommand -Name python -ExpectedPath (Join-Path $preferred 'python.exe') }
        catch { $failed = $_.Exception.Message -match 'aliases, functions, and PATH' }
        if (-not $failed) { throw 'A PowerShell function shadowing the runtime was accepted.' }
        $failed = $false
        try { Assert-NoRuntimeCommandConflict -Name python -ExpectedPath (Join-Path $preferred 'python.exe') }
        catch { $failed = $_.Exception.Message -match 'Resolve the conflict manually' }
        if (-not $failed) { throw 'A PowerShell function conflict was not reported before PATH changes.' }

        $npmPath = Join-Path $preferred 'npm.ps1'
        [IO.File]::WriteAllText($npmPath, "Write-Output '1.2.3'; `$global:LASTEXITCODE = 0")
        function Test-WorkshopNvmOwnership { return $true }
        function Invoke-ToolCommand { return $preferred }
        function Get-Command {
            param($Name)
            if ($Name -eq 'npm') { return [pscustomobject]@{ CommandType = 'ExternalScript'; Source = $npmPath } }
            return [pscustomobject]@{ CommandType = 'Application'; Source = (Join-Path $preferred "$Name.exe") }
        }
        Test-RuntimeCommands -LogDirectory temp
        Test-VmNodeCommands
        $npmPath = Join-Path $other 'npm.ps1'
        $failed = $false
        try { Test-VmNodeCommands }
        catch { $failed = $_.Exception.Message -match 'npm does not resolve' }
        if (-not $failed) { throw 'An npm command outside the nvm runtime was accepted.' }
        $npmPath = Join-Path $preferred 'npm.ps1'
        [IO.File]::WriteAllText($npmPath, "Write-Output 'invalid'; `$global:LASTEXITCODE = 0")
        $failed = $false
        try { Test-VmNodeCommands }
        catch { $failed = $_.Exception.Message -match 'npm command could not be verified' }
        if (-not $failed) { throw 'An invalid npm command was accepted.' }
    }
    finally {
        $env:AGENTBOX_PATH_FIXTURE = $originalFixtureEnv
        $env:NVM_SYMLINK = $originalNvmSymlink
        $env:LOCALAPPDATA = $originalLocalAppData
        $env:Path = $originalPath
        if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $fixture) {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        }
    }
}

& {
    Set-StrictMode -Version Latest
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-VmNvm'
    }, $true)
    Invoke-Expression $definition.Extent.Text
    $originalNvmHome = $env:NVM_HOME
    $originalNvmSymlink = $env:NVM_SYMLINK
    $originalProgramFiles = $env:ProgramFiles
    try {
        $env:NVM_HOME = ''
        $env:NVM_SYMLINK = ''
        $env:ProgramFiles = [IO.Path]::GetTempPath()
        $script:ExistingNode = $true
        function Update-ProcessPath { }
        function Get-Command {
            param($Name)
            if ($Name -eq 'node' -and $script:ExistingNode) { return [pscustomobject]@{ Source = 'existing-node.exe' } }
        }
        function Confirm-InstallAction { throw 'NVM installer was reached despite an existing runtime.' }
        foreach ($case in @('command', 'nvm-path')) {
            $script:ExistingNode = $case -eq 'command'
            if ($case -eq 'nvm-path') { $env:NVM_HOME = 'existing-nvm-home' }
            $failed = $false
            try { Install-VmNvm | Out-Null }
            catch { $failed = $_.Exception.Message -match 'Preserving the existing' }
            if (-not $failed) { throw "NVM installation did not preserve the existing $case." }
        }
    }
    finally {
        $env:NVM_HOME = $originalNvmHome
        $env:NVM_SYMLINK = $originalNvmSymlink
        $env:ProgramFiles = $originalProgramFiles
    }
}

& {
    . (Join-Path $RepositoryRoot 'appmod-box/scripts/install-vm-tools.ps1')
    $installerSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'appmod-box/scripts/install-vm-tools.ps1') -Raw
    if ($installerSource -match '(?m)^\s*\.\s+\(Join-Path') {
        throw 'App Modernisation installer must not dot-source external scripts.'
    }
    $interactive = $true
    $Yes = $false
    function Test-InstallInteractive { return $interactive }
    function Read-Host { return $answer }
    foreach ($case in @(
        @{ Answer = 'y'; Approved = $true }
        @{ Answer = 'YES'; Approved = $true }
        @{ Answer = 'n'; Approved = $false }
    )) {
        $answer = $case.Answer
        if ((Confirm-InstallAction 'Install a tool.') -ne $case.Approved) {
            throw "Incorrect App Modernisation consent decision for '$answer'."
        }
    }
    $interactive = $false
    $blocked = $false
    try { Confirm-InstallAction 'Install a tool.' | Out-Null }
    catch { $blocked = $true }
    if (-not $blocked) { throw 'App Modernisation accepted noninteractive consent without -Yes.' }
    if (Install-WorkshopNode) { throw 'Node installation ran noninteractively without -Yes.' }
    $Yes = $true
    if (-not (Confirm-InstallAction 'Install a tool.')) { throw 'App Modernisation -Yes did not approve noninteractive installation.' }
    function Update-ProcessPath { throw 'Node flow reached' }
    $reached = $false
    try { Install-WorkshopNode | Out-Null }
    catch { $reached = $_.Exception.Message -eq 'Node flow reached' }
    if (-not $reached) { throw 'App Modernisation -Yes did not reach the noninteractive Node flow.' }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("appmod-worker-test-" + [guid]::NewGuid().ToString('N'))
    $worker = Join-Path $temporary 'worker with spaces.ps1'
    $result = Join-Path $temporary 'result.json'
    $previousOutput = $env:APPMOD_BOOTSTRAP_TEST_OUTPUT
    try {
        $null = New-Item -ItemType Directory -Path $temporary
        [IO.File]::WriteAllText($worker, @'
param([string]$Track, [switch]$Yes)
@{ Track = $Track; Yes = [bool]$Yes } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $env:APPMOD_BOOTSTRAP_TEST_OUTPUT
exit 37
'@)
        $env:APPMOD_BOOTSTRAP_TEST_OUTPUT = $result
        function Find-VmPowerShell { return (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source }
        $code = Invoke-VmPowerShell -ScriptPath $worker `
            -BoundParameters @{ Track = 'dotnet'; Yes = $true } -RemainingArguments @()
        $stored = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
        if ($code -ne 37 -or $stored.Track -ne 'dotnet' -or -not $stored.Yes) {
            throw 'PowerShell bootstrap did not preserve the consent switch or worker exit code.'
        }
    }
    finally {
        $env:APPMOD_BOOTSTRAP_TEST_OUTPUT = $previousOutput
        if (Test-Path -LiteralPath $worker) { Remove-Item -LiteralPath $worker -Force }
        if (Test-Path -LiteralPath $result) { Remove-Item -LiteralPath $result -Force }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

& {
    . (Join-Path $RepositoryRoot 'appmod-box/scripts/install-vm-tools.ps1')
    $Yes = $true
    $script:OwnershipChecks = 0
    function Update-ProcessPath { }
    function Write-InstallMessage { param([string]$Message) }
    function Get-Command {
        param($Name)
        if ($Name -eq 'nvm') { return [pscustomobject]@{ Source = 'nvm.exe' } }
    }
    function Test-WorkshopNvmOwnership {
        param($NodePath)
        if ($NodePath) { throw 'Unexpected Node path.' }
        $script:OwnershipChecks++
        return $script:OwnershipChecks -eq 1
    }
    function Invoke-ToolProbe {
        param($Name, $Arguments)
        if ($Name -eq 'nvm') { return [pscustomobject]@{ Code = 0; Text = '2.0.1' } }
        return [pscustomobject]@{ Code = 0; Text = 'v22.1.0' }
    }
    function Get-WorkshopNvmConfiguration { return [pscustomobject]@{ root = [IO.Path]::GetTempPath(); mode = 'shim' } }
    function Get-WorkshopNvmSelection { return [pscustomobject]@{ Version = $null; IsEmpty = $false } }
    function Get-WorkshopNodeRelease { return [version]'22.1.0' }
    function Test-Path { return $true }
    function Confirm-InstallAction { return $true }
    if ((Install-WorkshopNode) -or $script:OwnershipChecks -ne 2) {
        throw 'Missing Node executables did not reach the ownership checks safely under StrictMode.'
    }
}

& {
    . (Join-Path $RepositoryRoot 'appmod-box/scripts/install-vm-tools.ps1')
    function Write-InstallMessage { param([string]$Message) }
    function Invoke-ToolProbe { return [pscustomobject]@{ Code = 0; Text = '{}' } }
    if (Get-WorkshopNvmConfiguration) { throw 'Incomplete nvm configuration was accepted.' }
    function Invoke-ToolProbe { return [pscustomobject]@{ Code = 0; Text = '[{"version":"22.1.0"}]' } }
    if (Get-WorkshopNvmSelection) { throw 'Incomplete nvm version list was accepted.' }
    function Invoke-RestMethod { return @() }
    if (Get-WorkshopNodeRelease 22) { throw 'An empty Node release list was accepted.' }
}

& {
    Set-StrictMode -Version Latest
    foreach ($project in @('agent-box', 'appmod-box')) {
        $tokens = $null
        $errors = $null
        $path = Join-Path $RepositoryRoot "$project/scripts/install-vm-tools.ps1"
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $name = 'Get-CopilotAppVersion'
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $definition) { throw "Missing $project Copilot version check." }
        Invoke-Expression $definition.Extent.Text
        function Test-Path { return $true }
        function Get-ChildItem { return @([pscustomobject]@{ PSPath = 'unrelated' }, [pscustomobject]@{ PSPath = 'copilot' }) }
        function Get-ItemProperty {
            param($Path, $LiteralPath)
            $key = if ($LiteralPath) { $LiteralPath } else { $Path }
            if ($key -eq 'unrelated') { return [pscustomobject]@{ UninstallString = 'fixture' } }
            return [pscustomobject]@{ DisplayName = 'GitHub Copilot'; DisplayVersion = '1.2.3' }
        }
        if ((& $name) -ne [version]'1.2.3') {
            throw "$project did not skip unrelated uninstall entries without a display name."
        }
    }
}

& {
    Set-StrictMode -Version Latest
    $previousTemp = $env:TEMP
    $previousSystemRoot = $env:SystemRoot
    try {
        $env:TEMP = [IO.Path]::GetTempPath()
        $env:SystemRoot = [IO.Path]::GetTempPath()
        foreach ($project in @('agent-box', 'appmod-box')) {
            $tokens = $null
            $errors = $null
            $path = Join-Path $RepositoryRoot "$project/scripts/install-vm-tools.ps1"
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $name = 'Install-CopilotApp'
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            if (-not $definition) { throw "Missing $project Copilot installer." }
            Invoke-Expression $definition.Extent.Text
            $script:CopilotVersionChecks = 0
            function Get-CopilotAppVersion {
                $script:CopilotVersionChecks++
                if ($script:CopilotVersionChecks -gt 1) { return [version]'1.2.3' }
            }
            function Confirm-InstallAction { return $true }
            function Write-InstallMessage { }
            function Invoke-RestMethod {
                return [pscustomobject]@{
                    prerelease = $false
                    draft = $false
                    tag_name = 'v1.2.3'
                    assets = @([pscustomobject]@{
                        name = 'GitHub-Copilot-windows-x64.msi'
                        browser_download_url = 'https://github.com/github/app/releases/download/v1.2.3/fixture.msi'
                    })
                }
            }
            function Invoke-WebRequest { }
            function Get-AuthenticodeSignature {
                return [pscustomobject]@{
                    Status = 'Valid'
                    SignerCertificate = [pscustomobject]@{ Subject = 'CN=GitHub, Inc.' }
                }
            }
            function Start-Process { return [pscustomobject]@{ ExitCode = 0 } }
            function Test-Path { return $false }
            if (-not (& $name) -or $script:CopilotVersionChecks -ne 2) {
                throw "$project did not verify the Copilot installation when the optional digest was absent."
            }
        }
    }
    finally {
        $env:TEMP = $previousTemp
        $env:SystemRoot = $previousSystemRoot
    }
}

& {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("appmod-command-log-test-" + [guid]::NewGuid().ToString('N'))
    $fixture = Join-Path $temporary 'command fixture.ps1'
    try {
        $null = New-Item -ItemType Directory -Path $temporary
        [IO.File]::WriteAllText($fixture, @'
param([string]$Value)
Write-Output "stdout:$Value"
[Console]::Error.WriteLine("stderr:$Value")
exit 37
'@)
        $executable = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        foreach ($project in @('agent-box', 'appmod-box')) {
            $tokens = $null
            $errors = $null
            $path = Join-Path $RepositoryRoot "$project/scripts/install-vm-tools.ps1"
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq 'Invoke-LoggedProcess'
            }, $true)
            if (-not $definition) { throw "Missing $project command logging function." }
            Invoke-Expression $definition.Extent.Text
            foreach ($streaming in @($false, $true)) {
                $logDirectory = Join-Path $temporary "$project-$streaming"
                $null = New-Item -ItemType Directory -Path $logDirectory
                $fileArgument = if ($streaming) { $fixture } else { "`"$fixture`"" }
                $valueArgument = if ($streaming) { 'value with spaces' } else { '"value with spaces"' }
                $result = Invoke-LoggedProcess -Executable $executable -Arguments @(
                    '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $fileArgument, $valueArgument
                ) -LogDirectory $logDirectory -StreamOutput:$streaming -Quiet
                $outLogs = @(Get-ChildItem -LiteralPath $logDirectory -Filter 'command-*.stdout.log')
                $errLogs = @(Get-ChildItem -LiteralPath $logDirectory -Filter 'command-*.stderr.log')
                if ($result.ExitCode -ne 37 -or $outLogs.Count -ne 1 -or $errLogs.Count -ne 1 -or
                    (Get-Content -LiteralPath $outLogs[0].FullName -Raw).Trim() -cne 'stdout:value with spaces' -or
                    (Get-Content -LiteralPath $errLogs[0].FullName -Raw).Trim() -cne 'stderr:value with spaces' -or
                    $result.CombinedOutput -notmatch 'stdout:value with spaces' -or
                    $result.CombinedOutput -notmatch 'stderr:value with spaces') {
                    throw "$project command logs did not preserve arguments, streams, or the exit code (streaming=$streaming)."
                }
                if ($streaming) {
                    $dockerOverride = $script:AppmodDockerOverrideArgument
                    $dockerResult = Invoke-LoggedProcess -Executable $executable -Arguments @(
                        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $fixture, $dockerOverride
                    ) -LogDirectory $logDirectory -StreamOutput -Quiet
                    if ($dockerResult.ExitCode -ne 37 -or
                        $dockerResult.StandardOutput.Trim() -cne 'stdout:install --backend=wsl-2') {
                        throw "$project Docker installer override was not passed as one process argument."
                    }
                }
            }
        }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
        foreach ($name in @('Invoke-LoggedProcess', 'Invoke-VmInstaller')) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            Invoke-Expression $definition.Extent.Text
        }
        $logDirectory = Join-Path $temporary 'agent-winget'
        $null = New-Item -ItemType Directory -Path $logDirectory
        function Get-Command { return [pscustomobject]@{ Source = $executable } }
        $failed = $false
        try {
            Invoke-VmInstaller fixture @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $fixture, $script:AppmodDockerOverrideArgument
            ) | Out-Null
        }
        catch { $failed = $_.Exception.Message -match 'exit code 37' }
        $output = Get-ChildItem -LiteralPath $logDirectory -Filter 'command-*.stdout.log' |
            Get-Content -Raw
        if (-not $failed -or $output.Trim() -cne 'stdout:install --backend=wsl-2') {
            throw 'Agent WinGet invocation did not pass the Docker override as one process argument.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

& {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("agentbox-bootstrap-entry-" + [guid]::NewGuid().ToString('N'))
    $fixture = Join-Path $temporary 'install-vm-tools.ps1'
    $previousProgramData = $env:ProgramData
    $previousMode = $env:AGENTBOX_BOOTSTRAP_TEST_MODE
    try {
        $null = New-Item -ItemType Directory -Path $temporary
        $marker = '# Script entry point.'
        if (-not $installer.Contains($marker)) { throw 'Agent Box installer entry point was not found.' }
        $mocks = @'
function Assert-VmInstallerContext { }
function Test-RebootPending { return $false }
function Initialize-VmWinget { return $true }
function Install-VmPowerShell {
    if ($env:AGENTBOX_BOOTSTRAP_TEST_MODE -eq 'restart') {
        $script:RestartRequired = $true
        return $false
    }
    if ($env:AGENTBOX_BOOTSTRAP_TEST_MODE -eq 'declined') { return $false }
    return $true
}
function Invoke-VmToolInstallation {
    param($LogDirectory, $PythonVersion)
    Write-InstallMessage "[PASS] fixture Python=$PythonVersion"
    return 0
}

'@
        [IO.File]::WriteAllText($fixture, $installer.Replace($marker, $mocks + $marker))
        $env:ProgramData = $temporary
        foreach ($mode in @('success', 'declined', 'restart')) {
            $env:AGENTBOX_BOOTSTRAP_TEST_MODE = $mode
            $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $fixture -Yes -PythonVersion 3.13 2>&1 | Out-String
            $expected = if ($mode -eq 'success') { 0 } elseif ($mode -eq 'declined') { 1 } elseif ($IsWindows) { 3010 } else { 3010 % 256 }
            if ($LASTEXITCODE -ne $expected -or $output -notmatch 'Installation logs:' -or
                ($mode -eq 'success' -and $output -notmatch 'fixture Python=3\.13')) {
                throw "Agent Box bootstrap entry fixture failed ($mode): $output"
            }
        }
        $logs = @(Get-ChildItem -LiteralPath (Join-Path $temporary 'AgentBox/Logs/DevTools') -Filter 'install.log' -Recurse)
        if ($logs.Count -ne 3) { throw 'Agent Box did not create an installation log for each bootstrap run.' }
    }
    finally {
        $env:ProgramData = $previousProgramData
        $env:AGENTBOX_BOOTSTRAP_TEST_MODE = $previousMode
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

& {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("appmod-log-test-" + [guid]::NewGuid().ToString('N'))
    $fixture = Join-Path $temporary 'install-vm-tools.ps1'
    $previousProgramData = $env:ProgramData
    $previousFailure = $env:APPMOD_LOG_TEST_FAIL
    try {
        $null = New-Item -ItemType Directory -Path $temporary
        $source = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'appmod-box/scripts/install-vm-tools.ps1') -Raw
        $marker = "if (`$MyInvocation.InvocationName -eq '.') {"
        if (-not $source.Contains($marker)) { throw 'App Modernisation installer entry point was not found.' }
        $mocks = @'
function Assert-VmInstallerContext { }
function Test-RebootPending { return $false }
function Initialize-VmWinget {
    if ($env:APPMOD_LOG_TEST_FAIL) { throw 'fixture bootstrap failure' }
    return $true
}
function Install-VmPowerShell { return $true }
function Invoke-VmToolInstallation { Write-InstallMessage '[PASS] fixture installation'; return 0 }

'@
        [IO.File]::WriteAllText($fixture, $source.Replace($marker, $mocks + $marker))
        $env:ProgramData = $temporary
        foreach ($failure in @($false, $true)) {
            $env:APPMOD_LOG_TEST_FAIL = if ($failure) { 'true' } else { '' }
            $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $fixture -Yes 2>&1 | Out-String
            $expected = if ($failure) { 1 } else { 0 }
            if ($LASTEXITCODE -ne $expected -or $output -notmatch 'Installation logs:') {
                throw "App Modernisation transcript fixture failed: $output"
            }
        }
        $logs = @(Get-ChildItem -LiteralPath (Join-Path $temporary 'AppModBox/Logs/DevTools') -Filter 'install.log' -Recurse)
        if ($logs.Count -ne 2) { throw 'App Modernisation did not create an installation log for each run.' }
        $text = ($logs | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        if ($text -notmatch 'fixture installation' -or $text -notmatch 'fixture bootstrap failure') {
            throw 'App Modernisation installation logs did not capture success and failure.'
        }
    }
    finally {
        $env:ProgramData = $previousProgramData
        $env:APPMOD_LOG_TEST_FAIL = $previousFailure
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    }
}

& {
    . (Join-Path $RepositoryRoot 'appmod-box/infra/scripts/package-user-scripts.ps1')
    . (Join-Path $RepositoryRoot 'appmod-box/infra/scripts/stage-user-scripts.ps1')
    function Assert-VmPath { param([string]$Path) }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("appmod-stage-test-" + [guid]::NewGuid().ToString('N'))
    $scriptsDirectory = Join-Path $temporary 'scripts'
    $installerPath = Join-Path $scriptsDirectory 'install-vm-tools.ps1'
    $configPath = Join-Path $scriptsDirectory 'buildtools.vsconfig'
    $legacyPath = Join-Path $scriptsDirectory 'java-tools.ps1'
    $state = @{ Username = ''; Enabled = $true; Administrator = $true }
    function Get-LocalUser {
        param([string]$Name)
        $state.Username = $Name
        return [pscustomobject]@{ Enabled = $state.Enabled; SID = [pscustomobject]@{ Value = 'S-1-5-21-456' } }
    }
    function Get-LocalGroupMember {
        if ($state.Administrator) { return [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-456' } } }
    }
    function Get-VmProfilePath { return $temporary }
    try {
        $null = New-Item -ItemType Directory -Path $scriptsDirectory -Force
        [IO.File]::WriteAllText($installerPath, 'existing user changes')
        [IO.File]::WriteAllText($legacyPath, 'existing legacy file')
        $payload = Expand-VmPayload (New-VmPayload (Get-VmPayloadSources)).content
        $username = "custom'admin"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($username))
        if ((Resolve-VmUserProfile -Username $username) -cne [IO.Path]::GetFullPath($temporary) -or
            $state.Username -cne $username) {
            throw 'App Modernisation staging did not resolve the configured administrator profile.'
        }
        foreach ($case in @('Enabled', 'Administrator')) {
            $state[$case] = $false
            $errorMessage = ''
            try { Resolve-VmUserProfile -Username $username | Out-Null }
            catch { $errorMessage = $_.Exception.Message }
            if (-not $errorMessage) { throw "App Modernisation staging accepted an invalid administrator: $case." }
            $state[$case] = $true
        }
        $blocked = $false
        try { Write-VmUserFiles -ProfilePath $temporary -Payload $payload -AdminUsernameBase64 $encoded }
        catch { $blocked = $_.Exception.Message -match 'Preserving different existing file' }
        if (-not $blocked -or [IO.File]::ReadAllText($installerPath) -cne 'existing user changes' -or
            (Test-Path -LiteralPath $configPath)) {
            throw 'App Modernisation staging did not preserve the existing installer before writing.'
        }
        Remove-Item -LiteralPath $installerPath -Force
        Write-VmUserFiles -ProfilePath $temporary -Payload $payload -AdminUsernameBase64 $encoded
        Write-VmUserFiles -ProfilePath $temporary -Payload $payload -AdminUsernameBase64 $encoded
        foreach ($file in $payload.files) {
            $staged = Join-Path $scriptsDirectory $file.name
            $expected = [Convert]::FromBase64String($file.content)
            if ($file.name -eq 'install-vm-tools.ps1') {
                $source = [Text.Encoding]::UTF8.GetString($expected)
                $expected = [Text.Encoding]::UTF8.GetBytes($source.Replace('__ADMIN_USERNAME_BASE64__', $encoded))
                $tokens = $null
                $errors = $null
                $null = [Management.Automation.Language.Parser]::ParseFile($staged, [ref]$tokens, [ref]$errors)
                if ($errors.Count -gt 0) { throw "Staged workshop installer has parse errors: $($errors | Out-String)" }
            }
            if ((Get-VmBytesHash ([IO.File]::ReadAllBytes($staged))) -ne (Get-VmBytesHash $expected)) {
                throw "App Modernisation staging changed $($file.name)."
            }
        }
        if ([IO.File]::ReadAllText($legacyPath) -cne 'existing legacy file') {
            throw 'App Modernisation staging removed an existing legacy file.'
        }
    }
    finally {
        foreach ($path in @($installerPath, $configPath, $legacyPath)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        if (Test-Path -LiteralPath $scriptsDirectory) { Remove-Item -LiteralPath $scriptsDirectory -Force }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

& {
    . (Join-Path $RepositoryRoot 'agent-box/infra/scripts/stage-user-scripts.ps1')
    $state = @{ Created = $false; Enabled = $true; Administrator = $true; Username = '' }
    function Get-LocalUser {
        param([string]$Name)
        $state.Username = $Name
        [pscustomobject]@{ Enabled = $state.Enabled; SID = [pscustomobject]@{ Value = 'S-1-5-21-123' } }
    }
    function Get-LocalGroupMember {
        param([string]$SID)
        if ($state.Administrator) { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-123' } } }
    }
    function Get-VmProfilePath {
        param([string]$Sid)
        if ($state.Created) { return $RepositoryRoot }
    }
    function New-VmUserProfile {
        param([string]$Sid, [string]$Username)
        if ($Username -cne 'customadmin' -or $Sid -cne 'S-1-5-21-123') { throw 'Incorrect profile identity.' }
        $state.Created = $true
    }
    $profile = Resolve-VmUserProfile -Username 'customadmin'
    if ($state.Username -cne 'customadmin' -or $profile -cne [IO.Path]::GetFullPath($RepositoryRoot)) {
        throw 'Staging did not resolve the configured local administrator profile.'
    }
    foreach ($case in @('Enabled', 'Administrator')) {
        $state[$case] = $false
        $errorMessage = ''
        try { Resolve-VmUserProfile -Username 'customadmin' | Out-Null }
        catch { $errorMessage = $_.Exception.Message }
        if (-not $errorMessage) { throw "Staging accepted an invalid administrator: $case." }
        $state[$case] = $true
    }

    function Assert-VmPath { param([string]$Path) }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("agentbox-test-" + [guid]::NewGuid().ToString('N'))
    $scriptsDirectory = Join-Path $temporary 'scripts'
    $stagedInstaller = Join-Path $scriptsDirectory 'install-vm-tools.ps1'
    try {
        $null = New-Item -ItemType Directory -Path $temporary
        $username = "custom'admin"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($username))
        $source = [IO.File]::ReadAllBytes((Join-Path $RepositoryRoot 'agent-box/scripts/install-vm-tools.ps1'))
        $payload = [pscustomobject]@{
            files = @([pscustomobject]@{ name = 'install-vm-tools.ps1'; content = [Convert]::ToBase64String($source) })
        }
        Write-VmUserFiles -ProfilePath $temporary -Payload $payload -AdminUsernameBase64 $encoded
        $staged = [IO.File]::ReadAllText($stagedInstaller)
        if (-not $staged.Contains("'$encoded'") -or $staged.Contains('__ADMIN_USERNAME_BASE64__')) {
            throw 'The staged installer did not receive the encoded administrator name.'
        }
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($stagedInstaller, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "Staged installer has parse errors: $($errors | Out-String)" }
    }
    finally {
        if (Test-Path -LiteralPath $stagedInstaller) { Remove-Item -LiteralPath $stagedInstaller -Force }
        if (Test-Path -LiteralPath $scriptsDirectory) { Remove-Item -LiteralPath $scriptsDirectory -Force }
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

Write-Host "[PASS] Parsed $($files.Count) PowerShell scripts and checked both installer contracts."
