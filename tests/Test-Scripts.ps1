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
        "'Microsoft.DotNet.SDK.10'"
        "'Microsoft.DotNet.SDK.11'"
        "'Docker.DockerDesktop'"
        "'GitHub.Copilot'"
        "'Microsoft.Azd'"
        'Get-LatestNodeLts'
        'Install-UbuntuWsl'
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
    Set-StrictMode -Version Latest
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Invoke-WslCommand', 'Test-WslPlatform', 'Install-WslPlatform',
            'Get-UbuntuWslVersion', 'Install-UbuntuWsl')) {
        $definition = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
        if (-not $definition) { throw "Missing Agent Box WSL function: $name" }
        Invoke-Expression $definition.Extent.Text
    }

    $PSNativeCommandUseErrorActionPreference = $true
    $executable = (Get-Process -Id $PID).Path
    $result = Invoke-WslCommand $executable @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
        '[Console]::Error.WriteLine("WSL is not installed"); exit 42')
    if ($result.Code -ne 42 -or $result.Text -notmatch 'WSL is not installed') {
        throw 'A native WSL error did not preserve its exit code and diagnostic output.'
    }
    $result = Invoke-WslCommand $executable @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
        '[Console]::Out.WriteLine("WSL ready"); exit 0')
    if ($result.Code -ne 0 -or $result.Text -notmatch 'WSL ready') {
        throw 'A successful native WSL command was not reported correctly.'
    }

    $script:WslReady = $false
    $script:WslInstallCode = 0
    $script:WslCalls = [Collections.Generic.List[string]]::new()
    $script:RestartRequired = $false
    function Get-WslExecutable { return 'fixture-wsl.exe' }
    function Get-WindowsOptionalFeature { return [pscustomobject]@{ State = 'Enabled' } }
    function Test-RebootPending { return $false }
    function Confirm-InstallAction { return $true }
    function Write-InstallMessage { }
    function Invoke-WslCommand {
        param($Executable, $Arguments)
        $command = $Arguments -join ' '
        $script:WslCalls.Add($command)
        switch ($command) {
            '--status' {
                if ($script:WslReady) { return [pscustomobject]@{ Code = 0; Text = 'ready' } }
                return [pscustomobject]@{ Code = 1; Text = 'The Windows Subsystem for Linux is not installed.' }
            }
            '--install --no-distribution' {
                if ($script:WslInstallCode -eq 0) { $script:WslReady = $true }
                return [pscustomobject]@{ Code = $script:WslInstallCode; Text = 'fixture installation error' }
            }
            '--list --verbose' {
                return [pscustomobject]@{ Code = 1; Text = 'Windows Subsystem for Linux has no installed distributions.' }
            }
            '--install --distribution Ubuntu --no-launch' {
                return [pscustomobject]@{ Code = $script:WslInstallCode; Text = 'fixture Ubuntu error' }
            }
            default { throw "Unexpected WSL command: $command" }
        }
    }
    if (-not (Install-WslPlatform) -or
        ($script:WslCalls -join ',') -cne '--status,--install --no-distribution,--status') {
        throw 'Missing WSL did not reach the platform installer and subsequent readiness check.'
    }
    if ((Get-UbuntuWslVersion) -ne 0) { throw 'An empty WSL distribution list was not accepted.' }
    $script:WslReady = $false
    $script:WslInstallCode = 42
    $failed = $false
    try { Install-WslPlatform | Out-Null }
    catch { $failed = $_.Exception.Message -match 'exit code 42.*fixture installation error' }
    if (-not $failed) { throw 'A WSL installation failure did not report its exit code and diagnostics.' }
    $script:WslInstallCode = 3010
    if ((Install-WslPlatform) -or -not $script:RestartRequired) {
        throw 'A WSL restart-required exit code was not preserved.'
    }
    $script:RestartRequired = $false
    $script:WslReady = $true
    $script:WslInstallCode = 42
    $failed = $false
    try { Install-UbuntuWsl | Out-Null }
    catch { $failed = $_.Exception.Message -match 'exit code 42.*fixture Ubuntu error' }
    if (-not $failed) { throw 'An Ubuntu installation failure did not report its exit code and diagnostics.' }
}

& {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    foreach ($name in @('Confirm-InstallAction', 'Install-DevToolPackages')) {
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

    $queried = [Collections.Generic.List[string]]::new()
    $wslReady = $true
    $installation = [pscustomobject]@{ Enabled = $false; Installed = $false; Arguments = @() }
    function Test-WslPlatform { return $wslReady }
    function Invoke-WinGetCommand {
        param([string]$Executable, [string[]]$Arguments, [string]$LogDirectory)
        if ($installation.Enabled -and $Arguments[0] -eq 'install') {
            $installation.Arguments = $Arguments
            $installation.Installed = $true
            return 0
        }
        if ($Arguments[0] -ne 'list') { throw 'Unexpected WinGet installation in test.' }
        $queried.Add($Arguments[2])
        if ($installation.Enabled -and -not $installation.Installed) {
            return [Convert]::ToUInt32('8A150014', 16)
        }
        return 0
    }
    $expectedGroups = [ordered]@{
        Prerequisites = @('Microsoft.PowerShell')
        Runtimes = @('Microsoft.DotNet.SDK.10', 'Microsoft.DotNet.SDK.11', 'astral-sh.uv')
        Containers = @('Docker.DockerDesktop')
        GitHub = @('Git.Git', 'GitHub.cli', 'GitHub.Copilot')
        Azure = @('Microsoft.AzureCLI', 'Microsoft.Azd')
        Editors = @('Microsoft.VisualStudioCode')
    }
    foreach ($group in $expectedGroups.Keys) {
        $queried.Clear()
        if (-not (Install-DevToolPackages -WinGetExecutable winget -LogDirectory temp -Group $group)) {
            throw "Installed package group $group was not accepted."
        }
        if (($queried -join ',') -cne ($expectedGroups[$group] -join ',')) {
            throw "Incorrect packages or order for group $group."
        }
    }
    $wslReady = $false
    $queried.Clear()
    if ((Install-DevToolPackages -WinGetExecutable winget -LogDirectory temp -Group Containers) -or $queried.Count) {
        throw 'Docker was not blocked when the WSL2 platform was unavailable.'
    }
    $installation.Enabled = $true
    $queried.Clear()
    if (-not (Install-DevToolPackages -WinGetExecutable winget -LogDirectory temp -Group Editors)) {
        throw 'Missing editor package was not installed and verified.'
    }
    if (($queried -join ',') -cne 'Microsoft.VisualStudioCode,Microsoft.VisualStudioCode' -or
        $installation.Arguments -notcontains '--accept-package-agreements' -or
        $installation.Arguments -notcontains '--disable-interactivity') {
        throw 'WinGet installation did not preserve the approved package and agreement handling.'
    }
}

& {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($installer, [ref]$tokens, [ref]$errors)
    $main = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-VmToolInstallation'
    }, $true)
    if (-not $main) { throw 'Agent Box installation flow was not found.' }
    Invoke-Expression $main.Extent.Text
    $events = [Collections.Generic.List[string]]::new()
    $messages = [Collections.Generic.List[string]]::new()
    $packageFailure = ''
    function Write-InstallMessage { param([string]$Message) $messages.Add($Message) }
    function Update-ProcessPath { }
    function Initialize-WinGet { param([string]$LogDirectory) $events.Add('winget'); return 'winget' }
    function Install-DevToolPackages {
        param([string]$WinGetExecutable, [string]$LogDirectory, [string]$Group)
        $events.Add("packages:$Group")
        if ($Group -eq 'Prerequisites' -and $packageFailure) {
            if ($packageFailure -eq 'restart') { $script:RestartRequired = $true }
            return $false
        }
        return $true
    }
    function Install-WslPlatform { $events.Add('wsl'); return $true }
    function Test-WslPlatform { return $true }
    function Install-UbuntuWsl { $events.Add('ubuntu'); return $true }
    function Install-NvmForWindows { param([string]$LogDirectory) $events.Add('nvm'); return $true }
    function Install-LanguageRuntimes {
        param([string]$PythonVersion, [string]$LogDirectory)
        $events.Add('language-runtimes')
        return $true
    }
    function Install-CopilotApp { $events.Add('copilot-app'); return $true }
    function Test-DevToolCommands { param([string]$LogDirectory) $events.Add('verification') }
    if ((Invoke-VmToolInstallation -LogDirectory 'temp' -PythonVersion '3.14') -ne 0) {
        throw 'Agent Box installation did not report success.'
    }
    $expectedEvents = @(
        'winget', 'packages:Prerequisites', 'wsl', 'ubuntu', 'packages:Runtimes',
        'nvm', 'language-runtimes', 'packages:Containers', 'packages:GitHub',
        'packages:Azure', 'packages:Editors', 'copilot-app', 'verification'
    )
    if (($events -join ',') -cne ($expectedEvents -join ',')) {
        throw "Unexpected Agent Box installation order: $($events -join ',')."
    }
    $stages = @($messages | Where-Object { $_ -match '^\[INFO\] === \[\d/7\]' })
    if ($stages.Count -ne 7) { throw 'Agent Box did not display all seven installation stages.' }
    for ($index = 0; $index -lt $stages.Count; $index++) {
        if (-not $stages[$index].Contains("[$($index + 1)/7]")) {
            throw 'Agent Box installation stage numbers are out of order.'
        }
    }
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
        function Find-WorkshopPowerShell { return (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source }
        $code = Invoke-WorkshopPowerShell -ScriptPath $worker `
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
        $name = if ($project -eq 'agent-box') { 'Get-CopilotAppVersion' } else { 'Get-VmCopilotVersion' }
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
            $name = if ($project -eq 'agent-box') { 'Install-CopilotApp' } else { 'Install-VmCopilot' }
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
            function Get-VmCopilotVersion { Get-CopilotAppVersion }
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
            }
        }
    }
    finally {
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
