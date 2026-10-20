#Requires -Version 7.0
<#
.SYNOPSIS
Runs isolated script checks without Windows account changes or software installs.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path $PSScriptRoot -Parent
$definitions = @{}
foreach ($file in Get-ChildItem (Join-Path $project 'scripts') -Filter *.ps1) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($definition in $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
        $definitions[$definition.Name] = [scriptblock]::Create($definition.Extent.Text)
    }
}
$script:passed = 0
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    try { & $Action; throw 'EXPECTED_FAILURE_MISSING' }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw } }
}
function Test-Case([string]$Name, [scriptblock]$Action) {
    foreach ($definition in $definitions.Values) { . $definition }
    & $Action 6>$null
    $script:passed++
    Write-Host "PASS: $Name"
}
function Get-TestUser {
    [pscustomobject]@{ Name = 'enrolleduser'; Enabled = $true; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }
}
function Get-TestNvmRelease {
    param([string]$Version = '2.7.3')

    [pscustomobject]@{
        tag_name = "v$Version"; draft = $false; prerelease = $false
        assets = @(
            [pscustomobject]@{ name = "nvm-$Version-arm64-setup.exe" }
            [pscustomobject]@{ name = "nvm-$Version-x64-sync.exe" }
            [pscustomobject]@{
                name = "nvm-$Version-x64-setup.exe"
                browser_download_url = "https://github.com/nvm-windows/nvm/releases/download/v$Version/nvm-$Version-x64-setup.exe"
                digest = 'sha256:' + ('a' * 64)
            }
        )
    }
}

Test-Case 'new secondary administrator is added by identity, not an ambiguous name' {
    $script:user = $null
    $script:member = $false
    function Get-LocalUser { param($ErrorAction)
        if ($null -ne $script:user) { return $script:user }
    }
    function New-LocalUser { param($Name, $Password, $Description, $ErrorAction)
        Assert-True ($Password -is [Security.SecureString]) 'Password was not kept secure.'
        $script:user = Get-TestUser
        return $script:user
    }
    function Add-LocalGroupMember { param($SID, $Member, $ErrorAction)
        Assert-True ($SID -eq 'S-1-5-32-544' -and $Member.SID.Value -eq $script:user.SID.Value) 'Wrong group or identity.'
        $script:member = $true
    }
    function Get-LocalGroupMember { param($SID, $ErrorAction)
        if ($script:member) { return $script:user }
    }
    $password = ConvertTo-SecureString 'SYNTHETIC-TEST-ONLY' -AsPlainText -Force
    $result = Ensure-LocalAdministrator -Username enrolleduser -InitialAdminUsername azureuser -Password $password
    Assert-True ($result.SID.Value -eq $script:user.SID.Value -and $script:member) 'Account not verified.'
}
Test-Case 'existing administrator is verified without a password reset or elevation' {
    function Get-LocalUser { param($ErrorAction) Get-TestUser }
    function Get-LocalGroupMember { param($SID, $ErrorAction) Get-TestUser }
    function New-LocalUser { throw 'Unexpected creation.' }
    function Add-LocalGroupMember { throw 'Unexpected elevation.' }
    function Set-LocalUser { throw 'Unexpected password change.' }
    $password = ConvertTo-SecureString 'SYNTHETIC-TEST-ONLY' -AsPlainText -Force
    $null = Ensure-LocalAdministrator -Username enrolleduser -InitialAdminUsername azureuser -Password $password
}
Test-Case 'unsafe existing account and invalid names fail before account mutation' {
    function Get-LocalUser { param($ErrorAction) Get-TestUser }
    function Get-LocalGroupMember { param($SID, $ErrorAction) }
    function New-LocalUser { throw 'Unexpected creation.' }
    function Add-LocalGroupMember { throw 'Unexpected elevation.' }
    $password = ConvertTo-SecureString 'SYNTHETIC-TEST-ONLY' -AsPlainText -Force
    Assert-Throws { Ensure-LocalAdministrator enrolleduser azureuser $password } '*not a local administrator*'
    Assert-Throws { Ensure-LocalAdministrator AzureUser azureuser $password } '*must differ*'
    Assert-Throws { Ensure-LocalAdministrator '../invalid' azureuser $password } '*valid Windows local account*'
}

$unjoined = @(
    '| Device State |', ' AzureAdJoined : NO', ' DomainJoined : NO',
    '| User State |', ' WorkplaceJoined : NO'
)
$tenant = [guid]'11111111-1111-1111-1111-111111111111'
Test-Case 'dsregcmd parsing preserves unknown states and section boundaries' {
    $status = ConvertFrom-DeviceJoinStatus $unjoined
    Assert-True (-not $status.AzureAdJoined -and $null -eq $status.TenantId) 'Unjoined status incorrect.'
    $joined = $unjoined -replace 'AzureAdJoined : NO', 'AzureAdJoined : YES'
    $joined += @('| Tenant Details |', " TenantId : $tenant", '| Work Account 1 |', ' TenantId : unrelated')
    $status = ConvertFrom-DeviceJoinStatus $joined
    Assert-True ($status.TenantId -eq $tenant) 'Wrong tenant section was parsed.'
    Assert-Throws { ConvertFrom-DeviceJoinStatus @('| Device State |', 'AzureAdJoined : NO') } '*Cannot determine*'
    Assert-Throws { ConvertFrom-DeviceJoinStatus ($unjoined + 'WorkplaceJoined : YES') } '*duplicate*'
}
Test-Case 'existing joins and registrations cannot be overwritten' {
    $status = [pscustomobject]@{ AzureAdJoined = $true; DomainJoined = $false; WorkplaceJoined = $false; TenantId = $tenant }
    Assert-True (Test-ExpectedDeviceJoin $status $tenant) 'Matching tenant was rejected.'
    Assert-Throws { Test-ExpectedDeviceJoin $status ([guid]'22222222-2222-2222-2222-222222222222') } '*not the expected tenant*'
    $status.DomainJoined = $true
    Assert-Throws { Test-ExpectedDeviceJoin $status $tenant } '*Active Directory domain*'
    $status.DomainJoined = $false
    $status.AzureAdJoined = $false
    $status.WorkplaceJoined = $true
    Assert-Throws { Test-ExpectedDeviceJoin $status $tenant } '*work-account registration*'
}
Test-Case 'check-only never launches UI or claims Intune enrollment' {
    function Get-DeviceJoinStatus {
        [pscustomobject]@{ AzureAdJoined = $false; DomainJoined = $false; WorkplaceJoined = $false; TenantId = $null }
    }
    function Start-Process { throw 'Unexpected UI launch.' }
    function Read-Host { throw 'Unexpected prompt.' }
    $result = Invoke-GuidedEnrollment -ExpectedTenantId $tenant -CheckOnly
    Assert-True (-not $result.EntraJoinVerified -and -not $result.IntuneEnrollmentVerified) 'False enrollment success.'
}
Test-Case 'guided flow opens only work settings and verifies the resulting join' {
    $script:reads = 0
    $script:opened = $false
    function Get-DeviceJoinStatus {
        $script:reads++
        [pscustomobject]@{ AzureAdJoined = $script:reads -gt 1; DomainJoined = $false; WorkplaceJoined = $false; TenantId = $tenant }
    }
    function Start-Process { param($FilePath, $ErrorAction)
        Assert-True ($FilePath -eq 'ms-settings:workplace') 'Wrong enrollment flow.'
        $script:opened = $true
    }
    function Read-Host { param($Prompt) return '' }
    $result = Invoke-GuidedEnrollment -ExpectedTenantId $tenant
    Assert-True ($script:opened -and $result.EntraJoinVerified -and -not $result.IntuneEnrollmentVerified) 'Join/MDM status conflated.'
}
Test-Case 'cancelled guided enrollment is not reported as success' {
    function Get-DeviceJoinStatus {
        [pscustomobject]@{ AzureAdJoined = $false; DomainJoined = $false; WorkplaceJoined = $false; TenantId = $null }
    }
    function Start-Process { param($FilePath, $ErrorAction) }
    function Read-Host { param($Prompt) return 'cancel' }
    Assert-Throws { Invoke-GuidedEnrollment -ExpectedTenantId $tenant } '*cancelled*'
}

Test-Case 'task registration uses an interactive elevated token and preserves completed state' {
    $oldWindir = $env:WINDIR
    try {
        $env:WINDIR = [IO.Path]::GetTempPath()
        $script:existing = $null
        $script:registrations = [Collections.Generic.List[object]]::new()
        function Initialize-AgentBoxTaskFolder {}
        function Get-ScheduledTask { param($ErrorAction)
            if ($null -ne $script:existing) { $script:existing }
        }
        function New-ScheduledTaskAction { param($Execute, $Argument)
            [pscustomobject]@{ Execute = $Execute; Arguments = $Argument }
        }
        function New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User)
            Assert-True $AtLogOn 'Missing logon trigger.'
            [pscustomobject]@{ User = $User }
        }
        function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel)
            Assert-True ($LogonType -eq 'Interactive' -and $RunLevel -eq 'Highest') 'Wrong task context.'
            [pscustomobject]@{ UserId = $UserId }
        }
        function New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable, $MultipleInstances, $ExecutionTimeLimit)
            Assert-True ($MultipleInstances -eq 'IgnoreNew') 'Concurrent task instances allowed.'
            [pscustomobject]@{ Enabled = $true }
        }
        function Register-ScheduledTask { param($TaskPath, $TaskName, $Description, $Action, $Trigger, $Principal, $Settings, [switch]$Force, $ErrorAction)
            $script:registrations.Add([pscustomobject]@{
                Description = $Description; Action = $Action; Settings = $Settings; Principal = $Principal
            })
        }
        Register-DevToolsSignInTask -UserSid 'S-1-5-21-1-2-3-1001' -PythonVersion 3.14 -ScriptDirectory (Join-Path $project 'scripts')
        $first = $script:registrations[0]
        Assert-True ($first.Settings.Enabled -and $first.Action.Arguments.Contains('-TaskFingerprint')) 'New task not configured.'
        Assert-True ($first.Action.Execute -eq (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe')) 'Wrong executable path.'
        Assert-True (-not $first.Action.Arguments.Contains('-Password')) 'Task stores a password.'
        $script:existing = [pscustomobject]@{
            TaskName = 'InstallDevTools'; TaskPath = '\AgentBox\'; Description = $first.Description; State = 'Disabled'
        }
        Register-DevToolsSignInTask -UserSid 'S-1-5-21-1-2-3-1001' -PythonVersion 3.14 -ScriptDirectory (Join-Path $project 'scripts')
        Assert-True (-not $script:registrations[1].Settings.Enabled) 'Completed task was re-enabled on unchanged deployment.'
        Register-DevToolsSignInTask -UserSid 'S-1-5-21-1-2-3-1001' -PythonVersion 3.15 -ScriptDirectory (Join-Path $project 'scripts')
        Assert-True $script:registrations[2].Settings.Enabled 'Changed runtime configuration did not enable setup.'
        $script:existing.Description = 'Unrelated task'
        Assert-Throws {
            Register-DevToolsSignInTask -UserSid 'S-1-5-21-1-2-3-1001' -PythonVersion 3.14 -ScriptDirectory (Join-Path $project 'scripts')
        } '*unmanaged task*'
    }
    finally { $env:WINDIR = $oldWindir }
}
Test-Case 'an older installer cannot disable a newer task' {
    $script:disabled = $false
    function Get-ScheduledTask { param($TaskPath, $TaskName, $ErrorAction)
        [pscustomobject]@{ Description = 'AgentBox:InstallDevTools:new' }
    }
    function Disable-ScheduledTask { param($TaskPath, $TaskName, $ErrorAction) $script:disabled = $true }
    Assert-Throws { Complete-FirstSignInSetup -Fingerprint old } '*newer configuration was not disabled*'
    Assert-True (-not $script:disabled) 'Newer task was disabled.'
    Complete-FirstSignInSetup -Fingerprint new
    Assert-True $script:disabled 'Matching task was not disabled.'
}

Test-Case 'staging copies exact bytes without executing scripts and is repeatable' {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentbox-stage-test-' + [guid]::NewGuid().ToString('N'))
    $script:aclCalls = 0
    function Set-AgentBoxPermissions { param($Path, [switch]$Directory) $script:aclCalls++ }
    try {
        $files = @{}
        foreach ($name in @('New-LocalAdmin.ps1', 'Initialize-Guest.ps1', 'Start-IntuneEnrollment.ps1', 'Install-DevTools.ps1')) {
            $files[$name] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("throw 'must not execute $name'"))
        }
        Copy-AgentBoxScripts -Files $files -RootDirectory $testRoot
        Copy-AgentBoxScripts -Files $files -RootDirectory $testRoot
        foreach ($name in $files.Keys) {
            $bytes = [IO.File]::ReadAllBytes((Join-Path (Join-Path $testRoot 'Scripts') $name))
            Assert-True ([Convert]::ToBase64String($bytes) -eq $files[$name]) 'Staged content changed.'
        }
        Assert-True ($script:aclCalls -eq 20) 'Directory/file protection was omitted.'
        $files['unexpected.ps1'] = 'invalid'
        Assert-Throws { Copy-AgentBoxScripts -Files $files -RootDirectory $testRoot } '*exactly the four expected files*'
    }
    finally {
        if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
    }
}

Test-Case 'LTS resolution ignores a newer non-LTS release and does not depend on row order' {
    function Invoke-RestMethod { param($Uri, $TimeoutSec, $ErrorAction)
        Write-Output -NoEnumerate @(
            [pscustomobject]@{ version = 'v22.99.0'; lts = 'Old'; files = @('win-x64-zip') }
            [pscustomobject]@{ version = 'v26.8.0'; lts = $false; files = @('win-x64-zip') }
            [pscustomobject]@{ version = 'v24.22.0'; lts = 'Current'; files = @('win-x64-zip') }
        )
    }
    Assert-True ((Get-LatestNodeLts).Version -eq '24.22.0') 'Wrong LTS selected.'
}
Test-Case 'NVM resolves the latest stable x64 installer without pinning a release version' {
    function Invoke-RestMethod { param($Uri, $Headers, $UserAgent, $TimeoutSec, $ErrorAction)
        Assert-True ($Uri -ceq 'https://api.github.com/repos/nvm-windows/nvm/releases/latest') 'Wrong release source.'
        Assert-True ($Headers.Accept -eq 'application/vnd.github+json') 'Missing GitHub response format.'
        Assert-True ($Headers['X-GitHub-Api-Version'] -eq '2022-11-28') 'Missing GitHub API version.'
        Assert-True ($UserAgent -eq 'AgentBox-DevTools' -and $TimeoutSec -eq 60 -and $ErrorAction -eq 'Stop') 'Unsafe release lookup.'
        return $script:nvmRelease
    }
    foreach ($version in @('2.7.3', '3.1.0')) {
        $script:nvmRelease = Get-TestNvmRelease -Version $version
        $result = Get-LatestNvmRelease
        Assert-True ($result.Version -eq $version) 'NVM release version was pinned.'
        Assert-True ($result.DownloadUrl -eq $script:nvmRelease.assets[2].browser_download_url) 'Wrong architecture or setup asset.'
        Assert-True ($result.Sha256 -ceq ('a' * 64)) 'SHA-256 was not read from release metadata.'
    }
}
Test-Case 'NVM rejects draft, prerelease, and malformed release metadata' {
    function Invoke-RestMethod { return $script:nvmRelease }
    foreach ($invalid in @('draft', 'prerelease', 'missing-flag', 'string-flag', 'bad-version', 'null')) {
        $script:nvmRelease = Get-TestNvmRelease
        switch ($invalid) {
            'draft' { $script:nvmRelease.draft = $true }
            'prerelease' { $script:nvmRelease.prerelease = $true }
            'missing-flag' { $script:nvmRelease.PSObject.Properties.Remove('prerelease') }
            'string-flag' { $script:nvmRelease.draft = 'false' }
            'bad-version' { $script:nvmRelease.tag_name = '../invalid' }
            'null' { $script:nvmRelease = $null }
        }
        Assert-Throws { Get-LatestNvmRelease } '*valid stable NVM release metadata*'
    }
}
Test-Case 'NVM rejects missing or ambiguous installers and untrusted asset metadata' {
    function Invoke-RestMethod { return $script:nvmRelease }
    foreach ($invalid in @('missing', 'duplicate', 'wrong-version')) {
        $script:nvmRelease = Get-TestNvmRelease
        switch ($invalid) {
            'missing' { $script:nvmRelease.assets = $script:nvmRelease.assets[0..1] }
            'duplicate' { $script:nvmRelease.assets += $script:nvmRelease.assets[2] }
            'wrong-version' { $script:nvmRelease.assets[2].name = 'nvm-2.7.4-x64-setup.exe' }
        }
        Assert-Throws { Get-LatestNvmRelease } '*exactly one*release asset*'
    }
    foreach ($invalid in @('http', 'wrong-repository', 'missing-digest', 'bad-digest')) {
        $script:nvmRelease = Get-TestNvmRelease
        $asset = $script:nvmRelease.assets[2]
        switch ($invalid) {
            'http' { $asset.browser_download_url = $asset.browser_download_url.Replace('https:', 'http:') }
            'wrong-repository' { $asset.browser_download_url = $asset.browser_download_url.Replace('/nvm-windows/', '/untrusted/') }
            'missing-digest' { $asset.PSObject.Properties.Remove('digest') }
            'bad-digest' { $asset.digest = 'sha256:invalid' }
        }
        Assert-Throws { Get-LatestNvmRelease } '*invalid installer URL or SHA-256 digest*'
    }
}
Test-Case 'NVM version parsing supports retained v1 installs and v2 edition notices' {
    function Invoke-ToolCommand { param($CommandName, $Arguments, $LogDirectory)
        Assert-True ($CommandName -eq 'nvm.exe' -and ($Arguments -join ' ') -eq 'version') 'Wrong version probe.'
        return $script:nvmOutput
    }
    foreach ($version in @('1.2.2', '2.7.3', '3.1.0-beta.1')) {
        $script:nvmOutput = if ($version.StartsWith('1.')) { $version } else { "v$version`r`nCommunity Edition" }
        Assert-True ((Get-NvmVersion -LogDirectory unused) -eq $version) 'NVM version was parsed incorrectly.'
    }
    $script:nvmOutput = 'unexpected output'
    Assert-Throws { Get-NvmVersion -LogDirectory unused } '*recognizable version*'
}
Test-Case 'NVM installs once with verified bytes, user scope, no reboot, and temporary-file cleanup' {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentbox-nvm-test-' + [guid]::NewGuid().ToString('N'))
    $originalTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        $logs = Join-Path $testRoot 'logs with spaces'
        $null = New-Item -ItemType Directory -Path $logs
        $script:nvmPayload = Join-Path $testRoot 'payload.bin'
        [IO.File]::WriteAllText($script:nvmPayload, 'Synthetic installer bytes; never executable.')
        $script:nvmRelease = Get-TestNvmRelease
        $script:nvmRelease.assets[2].digest = 'sha256:' + (Get-FileHash -LiteralPath $script:nvmPayload -Algorithm SHA256).Hash
        $script:nvmInstalled = $false
        $script:nvmInstalledVersion = '2.7.3'
        $script:nvmLookups = 0
        $script:nvmDownloads = 0
        $script:nvmSignatures = 0
        $script:nvmLaunches = 0
        function Update-ProcessPath {}
        function Get-Command { param($Name, $CommandType, $ErrorAction)
            Assert-True ($Name -eq 'nvm.exe' -and $CommandType -eq 'Application') 'Unexpected executable lookup.'
            if ($script:nvmInstalled) { [pscustomobject]@{ Source = 'nvm.exe' } }
        }
        function Invoke-RestMethod { $script:nvmLookups++; return $script:nvmRelease }
        function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $UserAgent, $TimeoutSec, $ErrorAction)
            Assert-True ($Uri -eq $script:nvmRelease.assets[2].browser_download_url) 'Wrong download URL.'
            Assert-True ($UseBasicParsing -and $TimeoutSec -eq 180 -and $ErrorAction -eq 'Stop') 'Unsafe download options.'
            $script:nvmDownloads++
            Copy-Item -LiteralPath $script:nvmPayload -Destination $OutFile
        }
        function Get-AuthenticodeSignature { param($LiteralPath, $ErrorAction)
            Assert-True (Test-Path -LiteralPath $LiteralPath -PathType Leaf) 'Installer was not downloaded.'
            $script:nvmSignatures++
            [pscustomobject]@{ Status = 'Valid' }
        }
        function Invoke-LoggedProcess { param($Executable, $Arguments, $LogDirectory)
            Assert-True ($script:nvmSignatures -eq 1) 'Installer ran before signature verification.'
            foreach ($argument in @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/CURRENTUSER',
                '/NORESTART', '/RESTARTEXITCODE=3010', '/NOCLOSEAPPLICATIONS', '/OFFICIALNODE=ignore')) {
                Assert-True ($Arguments -contains $argument) "Missing safe setup argument $argument."
            }
            $log = Join-Path $LogDirectory 'nvm-setup.log'
            Assert-True ($Arguments -contains ('/LOG="{0}"' -f $log)) 'Installer log path was not quoted.'
            [IO.File]::WriteAllText($log, 'Synthetic setup log.')
            $script:nvmLaunches++
            $script:nvmInstalled = $true
            [pscustomobject]@{ ExitCode = [uint32]0; StandardOutput = '' }
        }
        function Invoke-ToolCommand { param($CommandName, $Arguments, $LogDirectory)
            Assert-True ($script:nvmInstalled) 'NVM was not installed before verification.'
            return "v$script:nvmInstalledVersion`nCommunity Edition"
        }
        Install-NvmForWindows -LogDirectory $logs
        Install-NvmForWindows -LogDirectory $logs
        $script:nvmInstalledVersion = '1.2.2'
        Install-NvmForWindows -LogDirectory $logs
        Assert-True ($script:nvmLookups -eq 1 -and $script:nvmDownloads -eq 1 -and $script:nvmLaunches -eq 1) 'Existing NVM was reinstalled or upgraded.'
        Assert-True (@(Get-ChildItem -LiteralPath $logs -Filter *.exe).Count -eq 0) 'Downloaded installer was retained.'
        Assert-True (Test-Path -LiteralPath (Join-Path $logs 'nvm-setup.log')) 'Installer log was removed.'
        Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $originalTls) 'TLS settings were not restored.'
    }
    finally {
        if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
    }
}
Test-Case 'NVM fails closed on network, integrity, installer, restart, and verification errors' {
    $testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentbox-nvm-failure-' + [guid]::NewGuid().ToString('N'))
    $originalTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        $null = New-Item -ItemType Directory -Path $testRoot
        $script:nvmPayload = Join-Path $testRoot 'payload.bin'
        [IO.File]::WriteAllText($script:nvmPayload, 'Synthetic installer bytes; never executable.')
        function Update-ProcessPath {}
        function Get-Command {}
        function Invoke-RestMethod {
            if ($script:nvmFailure -eq 'network') { throw 'Synthetic GitHub API failure.' }
            return $script:nvmRelease
        }
        function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing, $UserAgent, $TimeoutSec, $ErrorAction)
            Copy-Item -LiteralPath $script:nvmPayload -Destination $OutFile
            if ($script:nvmFailure -eq 'download') { throw 'Synthetic download failure.' }
            if ($script:nvmFailure -eq 'hash') { [IO.File]::WriteAllText($OutFile, 'Corrupt payload.') }
        }
        function Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = $(if ($script:nvmFailure -eq 'signature') { 'NotSigned' } else { 'Valid' }) }
        }
        function Invoke-LoggedProcess {
            $script:nvmLaunches++
            $code = switch ($script:nvmFailure) { 'installer' { 13 }; 'restart' { 3010 }; default { 0 } }
            [pscustomobject]@{ ExitCode = [uint32]$code; StandardOutput = '' }
        }
        function Invoke-ToolCommand {
            if ($script:nvmFailure -eq 'missing-command') { throw 'Synthetic missing nvm.exe on PATH.' }
            return 'v2.7.2'
        }
        foreach ($case in @(
            @{ Name = 'network'; Pattern = '*GitHub API failure*'; Launches = 0 }
            @{ Name = 'download'; Pattern = '*download failure*'; Launches = 0 }
            @{ Name = 'hash'; Pattern = '*SHA-256 does not match*'; Launches = 0 }
            @{ Name = 'signature'; Pattern = '*signature is not valid*'; Launches = 0 }
            @{ Name = 'installer'; Pattern = '*installation failed*'; Launches = 1 }
            @{ Name = 'restart'; Pattern = '*requires a restart*'; Launches = 1 }
            @{ Name = 'wrong-version'; Pattern = '*instead of 2.7.3*'; Launches = 1 }
            @{ Name = 'missing-command'; Pattern = '*missing nvm.exe*'; Launches = 1 }
        )) {
            $script:nvmRelease = Get-TestNvmRelease
            $script:nvmRelease.assets[2].digest = 'sha256:' + (Get-FileHash -LiteralPath $script:nvmPayload -Algorithm SHA256).Hash
            $script:nvmFailure = $case.Name
            $script:nvmLaunches = 0
            Assert-Throws { Install-NvmForWindows -LogDirectory $testRoot } $case.Pattern
            Assert-True ($script:nvmLaunches -eq $case.Launches) "Wrong installer execution for $($case.Name)."
            Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter *.exe).Count -eq 0) 'Failed installer download was retained.'
            Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $originalTls) 'Failed install changed TLS settings.'
        }
    }
    finally {
        if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
    }
}
Test-Case 'Node LTS setup handles NVM v1 and v2 arguments and rejects an incorrect active architecture' {
    function Get-LatestNodeLts { [pscustomobject]@{ Version = '24.22.0'; Lts = 'Current' } }
    function Update-ProcessPath {}
    function Test-Path { param($LiteralPath, $PathType) return $LiteralPath -eq 'managed-python.exe' }
    function Invoke-ToolCommand { param($CommandName, $Arguments, $LogDirectory)
        switch ($CommandName) {
            'nvm.exe' {
                if ($Arguments[0] -eq 'version') { return "v$script:runtimeNvmVersion" }
                $expected = if ($script:runtimeNvmVersion.StartsWith('1.')) { '24.22.0 64' } else { '24.22.0' }
                Assert-True (($Arguments -join ' ') -eq "$($Arguments[0]) $expected") 'Incorrect NVM architecture argument.'
                $script:runtimeCalls.Add($Arguments[0])
                return ''
            }
            'node.exe' { return (@{ version = '24.22.0'; lts = 'Current'; arch = $script:runtimeArch } | ConvertTo-Json -Compress) }
            'npm' {
                Assert-True (($Arguments -join ' ') -eq '--version') 'Wrong npm probe.'
                $script:runtimeCalls.Add('npm')
                return '10.9.0'
            }
            'uv.exe' {
                if ($Arguments[1] -eq 'find') { return 'managed-python.exe' }
                Assert-True (($Arguments -join ' ') -eq 'python install 3.14 --upgrade --no-config --no-progress') 'Python installation changed.'
                return ''
            }
            'managed-python.exe' { return 'Python 3.14.8' }
            default { throw "Unexpected tool: $CommandName." }
        }
    }
    foreach ($version in @('1.2.2', '2.7.3')) {
        $script:runtimeNvmVersion = $version
        $script:runtimeArch = 'x64'
        $script:runtimeCalls = [Collections.Generic.List[string]]::new()
        Install-LanguageRuntimes -PythonVersion 3.14 -LogDirectory unused
        Assert-True (($script:runtimeCalls -join ',') -eq 'install,use,npm') 'Node installation/activation/probe ordering changed.'
    }
    $script:runtimeArch = 'x86'
    Assert-Throws { Install-LanguageRuntimes -PythonVersion 3.14 -LogDirectory unused } '*does not match LTS*for x64*'
}

Test-Case 'WinGet scopes and installer architectures remain explicit for all eight packages' {
    $script:installed = @{}
    $script:installs = [Collections.Generic.List[object]]::new()
    function Invoke-WinGetCommand { param($Executable, $Arguments, $LogDirectory)
        $id = $Arguments[[Array]::IndexOf($Arguments, '--id') + 1]
        $scope = $Arguments[[Array]::IndexOf($Arguments, '--scope') + 1]
        $key = "$id/$scope"
        if ($Arguments[0] -eq 'list') {
            if ($script:installed.ContainsKey($key)) { return [uint32]0 }
            return [Convert]::ToUInt32('8A150014', 16)
        }
        $architecture = $Arguments[[Array]::IndexOf($Arguments, '--architecture') + 1]
        $script:installs.Add([pscustomobject]@{ Id = $id; Scope = $scope; Architecture = $architecture })
        Assert-True ($Arguments -contains '--no-upgrade' -and $Arguments -contains '--silent') 'Installation policy changed.'
        $script:installed[$key] = $true
        return [uint32]0
    }
    Install-DevToolPackages -WinGetExecutable winget.exe -LogDirectory unused
    Install-DevToolPackages -WinGetExecutable winget.exe -LogDirectory unused
    Assert-True ($script:installs.Count -eq 8) 'Missing packages or repeated installs.'
    foreach ($installation in $script:installs) {
        Assert-True ($installation.Id -ne 'CoreyButler.NVMforWindows') 'NVM must not be installed through WinGet.'
        Assert-True ($installation.Scope -eq 'machine' -and $installation.Architecture -eq 'x64') 'Machine package scope changed.'
    }
}

Test-Case 'RDP source lookup emits only a single-host IPv4 CIDR' {
    function Invoke-RestMethod { param($Uri, $TimeoutSec, $MaximumRedirection, $ErrorAction)
        Assert-True ($Uri -eq 'https://api.ipify.org') 'Wrong IPv4 lookup service.'
        Assert-True ($TimeoutSec -eq 15 -and $MaximumRedirection -eq 0 -and $ErrorAction -eq 'Stop') 'Unsafe HTTP options.'
        return $ipResponse
    }
    foreach ($response in @('203.0.113.42', " `t203.0.113.42`r`n", '1.0.255.1')) {
        $ipResponse = $response
        $result = @(& (Join-Path $project 'scripts/Get-RdpSource.ps1'))
        Assert-True ($result.Count -eq 1 -and $result[0] -ceq "$($response.Trim())/32") 'Unexpected source output.'
    }
}
Test-Case 'RDP source lookup rejects malformed responses without success output' {
    function Invoke-RestMethod { param($Uri, $TimeoutSec, $MaximumRedirection, $ErrorAction)
        return $ipResponse
    }
    foreach ($response in @('', '<html>error</html>', '256.0.0.1', '01.2.3.4', '127.1',
        '::1', '203.0.113.42/32', '*', "203.0.113.42`n203.0.113.43", @{ ip = '203.0.113.42' })) {
        $ipResponse = $response
        $output = [Collections.Generic.List[object]]::new()
        Assert-Throws {
            & (Join-Path $project 'scripts/Get-RdpSource.ps1') | ForEach-Object { $output.Add($_) }
        } '*did not return a valid IPv4 address*'
        Assert-True ($output.Count -eq 0) 'Invalid response emitted a source value.'
    }
}
Test-Case 'RDP source lookup surfaces HTTP and network failures' {
    function Invoke-RestMethod { param($Uri, $TimeoutSec, $MaximumRedirection, $ErrorAction)
        throw 'Synthetic HTTP or timeout failure.'
    }
    $output = [Collections.Generic.List[object]]::new()
    Assert-Throws {
        & (Join-Path $project 'scripts/Get-RdpSource.ps1') | ForEach-Object { $output.Add($_) }
    } '*Synthetic HTTP or timeout failure*'
    Assert-True ($output.Count -eq 0) 'Failed lookup emitted a source value.'
}

Write-Host "$script:passed isolated script checks passed. Windows integration remains a separate validation step."
