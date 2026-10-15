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
Test-Case 'WinGet scopes and installer architectures remain explicit for all nine packages' {
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
    Assert-True ($script:installs.Count -eq 9) 'Missing packages or repeated installs.'
    foreach ($installation in $script:installs) {
        if ($installation.Id -eq 'CoreyButler.NVMforWindows') {
            Assert-True ($installation.Scope -eq 'user' -and $installation.Architecture -eq 'x86') 'NVM scope changed.'
        }
        else {
            Assert-True ($installation.Scope -eq 'machine' -and $installation.Architecture -eq 'x64') 'Machine package scope changed.'
        }
    }
}

Write-Host "$script:passed isolated script checks passed. Windows integration remains a separate validation step."
