[CmdletBinding()]
param([string]$CompiledTemplate)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$vmScripts = Join-Path $root '..\scripts'

. (Join-Path $root 'scripts\package-user-scripts.ps1')
. (Join-Path $root 'scripts\stage-user-scripts.ps1')
. (Join-Path $vmScripts 'install-vm-tools.ps1')
$script:Passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:Passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $caught = $null
    try { & $Action | Out-Null }
    catch { $caught = $_.Exception.Message }
    Assert-True ($null -ne $caught -and $caught -match $Pattern) "$Message ($caught)"
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("appmod-vm-test-" + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixture)
try {
    & {
        $Yes = $false
        $script:VmInteractive = $true; $script:VmAnswer = 'n'; $script:VmPrompts = 0
        function Test-InstallInteractive { return $script:VmInteractive }
        function Read-Host { $script:VmPrompts++; return $script:VmAnswer }
        Assert-True (-not (Confirm-InstallAction 'fixture action')) 'default VM consent still allows declining'
        $script:VmAnswer = 'y'
        Assert-True (Confirm-InstallAction 'fixture action') 'default VM consent accepts explicit approval'
        $Yes = $true
        Assert-True ((Confirm-InstallAction 'fixture action') -and $script:VmPrompts -eq 2) 'Yes approves VM actions without reading input'
        $script:VmInteractive = $false
        Assert-True (Confirm-InstallAction 'fixture action') 'Yes approves actions in a noninteractive context'
        $Yes = $false
        Assert-Throws { Confirm-InstallAction 'fixture action' } 'interactive.*-Yes' 'noninteractive mode requires Yes'
    }

    & {
        $Yes = $true
        $script:VmPackagePresent = $false; $script:RestartRequired = $false
        function Test-InstallInteractive { return $true }
        function Read-Host { throw 'Yes must not prompt' }
        function Update-ProcessPath { }
        function winget {
            Assert-True ($args -contains '--accept-source-agreements' -and
                $args -contains '--disable-interactivity') 'Yes accepts source agreements during version discovery too'
            $global:LASTEXITCODE=0
            "Versions`n2.0.1"
        }
        Assert-True ((Get-VmWingetVersion Fixture.Package '^2\.\d+\.\d+$') -eq '2.0.1') 'Yes retains stable package version selection'
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            Assert-True ($Command -eq 'winget' -and
                $Arguments -contains '--accept-package-agreements' -and
                $Arguments -contains '--accept-source-agreements' -and
                $Arguments -contains '--disable-interactivity') 'Yes passes explicit agreement acceptance to WinGet'
            $script:VmPackagePresent = $true
            return $true
        }
        Assert-True (Install-VmPackage Fixture.Package Fixture -TestInstalled { $script:VmPackagePresent }) 'Yes uses the regular installer and verifies installation'
        function Invoke-VmInstaller { $script:RestartRequired=$true; return $true }
        Assert-True (-not (Install-VmPackage Fixture.Package Fixture -TestInstalled { $false })) 'Yes does not bypass reboot boundaries'
        $script:RestartRequired=$false
    }

    $sources = Get-VmPayloadSources
    $bundle = New-VmPayload $sources
    $payload = Expand-VmPayload $bundle.content
    Assert-True ($payload.files.Count -eq $sources.Count) 'payload contains every required file'
    Assert-True (@($payload.files | Where-Object name -like '*.vsconfig').Count -eq 1 -and
        $payload.files.name -contains 'buildtools.vsconfig') 'payload delivers only the Build Tools configuration'
    Assert-True ($bundle.content.Length -le 90000) 'compressed payload stays below inline limit'
    foreach ($file in $payload.files) {
        Assert-True ((Get-VmBytesHash ([Convert]::FromBase64String($file.content))) -eq
            (Get-VmBytesHash ([IO.File]::ReadAllBytes($sources[$file.name])))) "byte-exact delivery: $($file.name)"
    }
    Assert-Throws { Expand-VmPayload 'not base64' } '.' 'invalid compressed payload fails'
    $large = Join-Path $fixture 'large.ps1'
    [IO.File]::WriteAllBytes($large, (New-Object byte[] 1048576))
    Assert-Throws { New-VmPayload @{ 'large.ps1'=$large } } 'limit' 'oversized payload fails before compression'

    $profile = Join-Path $fixture 'profile with spaces'
    $null = [IO.Directory]::CreateDirectory($profile)
    Write-VmUserFiles $profile $payload
    Write-VmUserFiles $profile $payload
    Assert-True ((Get-ChildItem (Join-Path $profile 'scripts') -File).Count -eq $sources.Count) 'same payload is idempotent'
    & {
        . (Join-Path $profile 'scripts\install-vm-tools.ps1')
        Assert-True ([bool](Get-Command Install-WorkshopNode -CommandType Function)) 'delivered installer contains its Node dependencies'
    }
    $modified = Join-Path $profile 'scripts\install-vm-tools.ps1'
    [IO.File]::WriteAllText($modified, 'user edit')
    Assert-Throws { Write-VmUserFiles $profile $payload } 'Preserving different' 'user edits are never overwritten'
    Assert-True ([IO.File]::ReadAllText($modified) -eq 'user edit') 'conflicting content remains intact'
    $badPayload = [pscustomobject]@{ files=@([pscustomobject]@{name='..\escape.ps1';content='YQ=='}) }
    Assert-Throws { Write-VmUserFiles $profile $badPayload } 'Invalid' 'path traversal is rejected'
    $duplicate = [pscustomobject]@{ files=@(
        [pscustomobject]@{name='a.ps1';content='YQ=='},
        [pscustomobject]@{name='A.ps1';content='Yg=='}
    ) }
    Assert-Throws { Write-VmUserFiles $profile $duplicate } 'duplicate' 'case-insensitive duplicate names fail'
    Assert-True (-not (Test-Path (Join-Path $profile 'scripts\a.ps1'))) 'conflicts are checked before writing'
    if ($IsWindows) {
        $junction = Join-Path $fixture 'junction'
        $null = New-Item -ItemType Junction -Path $junction -Target $profile
        Assert-Throws { Write-VmUserFiles $junction $payload } 'reparse' 'profile junctions are rejected'
        Remove-Item -LiteralPath $junction -Force
    }

    Add-Type -TypeDefinition @'
using System.Text;
namespace Appmod {
    public static class UserProfile {
        public static int Result;
        public static int CreateProfile(string sid, string name, StringBuilder path, uint length) {
            if (path.Capacity < 1 || path.Capacity > 260 || length != path.Capacity) {
                return unchecked((int)0x800706F7);
            }
            return Result;
        }
    }
}
'@
    New-VmUserProfile -Sid 'S-1-5-21-123-456-789-1001' -Username 'appmoduser'
    Assert-True $? 'profile creation respects the native MAX_PATH buffer limit'
    [Appmod.UserProfile]::Result = -2147024713
    New-VmUserProfile -Sid 'S-1-5-21-123-456-789-1001' -Username 'appmoduser'
    Assert-True $? 'native already-existing profile result is accepted'
    [Appmod.UserProfile]::Result = -2147024891
    Assert-Throws {
        New-VmUserProfile -Sid 'S-1-5-21-123-456-789-1001' -Username 'appmoduser'
    } '.' 'other native profile creation errors still propagate'
    [Appmod.UserProfile]::Result = 0

    & {
        $script:Created = 0
        $script:HasProfile = $false
        function Get-LocalUser { [pscustomobject]@{ Enabled=$true; SID=[pscustomobject]@{ Value='S-1-5-21-123-456-789-1001' } } }
        function Get-LocalGroupMember { [pscustomobject]@{ SID=[pscustomobject]@{ Value='S-1-5-21-123-456-789-1001' } } }
        function Get-VmProfilePath { if ($script:HasProfile) { return $profile } }
        function New-VmUserProfile {
            param($Sid,$Username)
            Assert-True ($Sid -eq 'S-1-5-21-123-456-789-1001' -and $Username -eq 'appmoduser') 'profile API receives target SID and account'
            $script:Created++
            $script:HasProfile=$true
        }
        Assert-True ((Resolve-VmUserProfile -Username 'appmoduser') -eq $profile) 'new profile uses resolved path, not SYSTEM HOME'
        Assert-True ((Resolve-VmUserProfile -Username 'appmoduser') -eq $profile -and $script:Created -eq 1) 'existing profile does not call CreateProfile'
        $script:HasProfile = $false
        function New-VmUserProfile { throw 'fixture CreateProfile failure' }
        Assert-Throws { Resolve-VmUserProfile -Username 'appmoduser' } 'CreateProfile failure' 'profile creation failure propagates'
        function Get-LocalGroupMember { @() }
        Assert-Throws { Resolve-VmUserProfile -Username 'appmoduser' } 'not a local administrator' 'administrator membership is required'
    }

    & {
        $script:Installs = 0
        function Confirm-InstallAction { return $false }
        function Invoke-VmInstaller { $script:Installs++; throw 'must not run' }
        Assert-True (-not (Install-VmPackage Fixture.Package Fixture -TestInstalled { $false })) 'declined package stays incomplete'
        Assert-True ($script:Installs -eq 0) 'decline never launches installer'
        Assert-True (Install-VmPackage Fixture.Package Fixture -TestInstalled { $true }) 'existing tool is kept without consent or install'
        function Confirm-InstallAction { return $true }
        function Get-VmWingetVersion { param($Id,$VersionPattern); return '2.0.1' }
        function Update-ProcessPath { }
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            $script:Installs++
            Assert-True ($Command -eq 'winget' -and $Arguments -contains '--version' -and $Arguments -contains '2.0.1') 'major-constrained version is pinned'
            Assert-True ($Arguments -notcontains '--accept-package-agreements' -and
                $Arguments -notcontains '--accept-source-agreements') 'default installation does not automatically accept WinGet agreements'
            return $true
        }
        $script:RestartRequired=$false
        Assert-Throws {
            Install-VmPackage Fixture.Package Fixture -VersionPattern '^2\.\d+\.\d+$' -TestInstalled { $false }
        } 'after installation' 'exit zero alone is not installation success'
        function Invoke-VmInstaller { throw 'fixture native failure' }
        Assert-Throws { Install-VmPackage Fixture.Package Fixture -TestInstalled { $false } } 'native failure' 'installer failures propagate'
        function Invoke-VmInstaller { $script:RestartRequired=$true; return $true }
        Assert-True (-not (Install-VmPackage Fixture.Package Fixture -TestInstalled { $false })) 'reboot-pending install is not marked verified'
    }

    & {
        function winget {
            $global:LASTEXITCODE=0
            "Versions`n3.0.0`n2.0.0`n2.0.1`n2.1.0-preview.1"
        }
        Assert-True ((Get-VmWingetVersion AuthorSoftware.NVMWindows '^2\.\d+\.\d+$') -eq '2.0.1') 'release selection excludes other majors and previews'
        Assert-Throws { Get-VmWingetVersion Fixture.Package '^18\.\d+\.\d+$' } 'No stable' 'missing required major fails'
        function winget { $global:LASTEXITCODE=1; 'fixture lookup failure' }
        Assert-Throws { Get-VmWingetVersion Fixture.Package '^2\.\d+\.\d+$' } 'Failed to query' 'version discovery failure never falls back'
    }

    & {
        function Confirm-InstallAction { return $true }
        function Update-ProcessPath { }
        function Test-VmPowerShell7 { return $script:PowerShellInstalled }
        function winget {
            $global:LASTEXITCODE=0
            return $script:PowerShellVersions
        }
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            $versionIndex = [Array]::IndexOf($Arguments, '--version')
            Assert-True ($Command -eq 'winget' -and $Arguments -contains 'Microsoft.PowerShell' -and
                $versionIndex -ge 0 -and $Arguments[$versionIndex + 1] -eq $script:ExpectedPowerShellVersion) 'PowerShell installs the exact stable WinGet package version'
            $script:PowerShellInstalled=$true
            return $true
        }
        foreach ($case in @(
            @{ Text="Version`n8.0.0.0`n7.7.0.0-preview.1`n7.6.9.0`n7.6.10.0`n6.2.7.0"; Expected='7.6.10.0' },
            @{ Text="Version`n7.5.9`n7.5.10`n7.6.0-preview.1"; Expected='7.5.10' }
        )) {
            $script:PowerShellVersions=$case.Text
            $script:ExpectedPowerShellVersion=$case.Expected
            $script:PowerShellInstalled=$false
            $script:RestartRequired=$false
            Assert-True (Install-VmPowerShell) 'PowerShell accepts three- and four-part stable versions and excludes previews and other majors'
        }
    }

    & {
        $script:SdkText="9.0.100 [C:\fixture\sdk]`n11.0.100-preview.1 [C:\fixture\sdk]"
        $script:SdkInstalls=0; $script:Approved=$true; $script:VerifySdk=$true
        $script:RestartRequired=$false
        function Confirm-InstallAction { $script:Approved }
        function Update-ProcessPath { }
        function Invoke-ToolProbe {
            param($Name,$Arguments)
            Assert-True ($Name -eq 'dotnet' -and ($Arguments -join ' ') -eq '--list-sdks') 'SDK verification lists installed SDKs instead of relying on the default SDK'
            [pscustomobject]@{Code=0;Text=$script:SdkText}
        }
        function winget {
            $global:LASTEXITCODE=0
            "Version`n11.0.101`n11.0.100`n11.0.102-preview.1`n10.0.101`n10.0.100"
        }
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            Assert-True ($Command -eq 'winget' -and $Arguments -contains "Microsoft.DotNet.SDK.$script:ExpectedMajor" -and
                $Arguments -contains "$script:ExpectedMajor.0.101") 'SDK installs pin the requested stable major'
            $script:SdkInstalls++
            if ($script:VerifySdk) { $script:SdkText += "`n$script:ExpectedMajor.0.101 [C:\fixture\sdk]" }
            return $true
        }
        foreach ($major in @(10,11)) {
            $script:ExpectedMajor=$major
            Assert-True (Install-VmDotnetSdk $major) ".NET $major SDK can be installed alongside other majors"
            Assert-True (Install-VmDotnetSdk $major) "existing stable .NET $major SDK is preserved"
        }
        Assert-True ($script:SdkInstalls -eq 2) 'each SDK major installs once, including when another major or preview exists'
        $script:SdkText='10.0.101 [C:\fixture\sdk]'; $script:Approved=$false
        Assert-True (-not (Install-VmDotnetSdk 11)) 'declining SDK 11 remains incomplete even with SDK 10 installed'
        Assert-True ($script:SdkInstalls -eq 2) 'declining SDK 11 never runs its installer'
        $script:Approved=$true; $script:VerifySdk=$false
        Assert-Throws { Install-VmDotnetSdk 11 } 'after installation' 'SDK 11 must be verified after installer success'
    }

    & {
        $script:PsqlVersion='psql (PostgreSQL) 17.9'; $script:PsqlCode=0
        $script:PsqlInstalls=0; $script:Approved=$false; $script:RestartRequired=$false
        $script:PsqlPathCalls=0
        function Set-VmPostgresPath { $script:PsqlPathCalls++; return $true }
        $messages = [Collections.Generic.List[string]]::new()
        function Write-InstallMessage { param($Message); $messages.Add($Message) }
        function Get-Command { [pscustomobject]@{Source='C:\fixture-postgres\psql.exe'} }
        function Update-ProcessPath { }
        function Test-Path { return $true }
        function Invoke-ToolProbe {
            param($Name,$Arguments)
            Assert-True (($Arguments -join ' ') -eq '--version') 'psql verification does not connect to or create a database'
            [pscustomobject]@{Code=$script:PsqlCode;Text=$script:PsqlVersion}
        }
        function Confirm-InstallAction { $script:Approved }
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            Assert-True ($Command -eq 'winget' -and $Arguments -contains 'PostgreSQL.PostgreSQL.18' -and
                $Arguments -contains '--override' -and $Arguments[-1] -eq
                '--mode unattended --unattendedmodeui minimal --enable-components commandlinetools --disable-components server,pgAdmin,stackbuilder') 'PostgreSQL installer selects only client tools without server or database setup'
            $script:PsqlInstalls++; $script:PsqlVersion='psql (PostgreSQL) 18.7'
            return $true
        }
        Assert-True (-not (Install-VmPostgresClient)) 'client installation requires consent and does not accept psql 17'
        Assert-True ($script:PsqlInstalls -eq 0) 'declined psql installation never launches winget'
        $script:Approved=$true
        Assert-True (Install-VmPostgresClient) 'psql 18 is verified even when its directory is not in PATH'
        Assert-True (Install-VmPostgresClient) 'existing psql 18 does not reinstall'
        Assert-True ($script:PsqlInstalls -eq 1) 'PostgreSQL client installs once'
        Assert-True ($script:PsqlPathCalls -eq 2) 'new and existing PostgreSQL installations both configure PATH'
        $script:PsqlCode=-1073741515; $script:PsqlVersion=''
        Assert-True (-not (Test-VmPostgresClient)) 'nonzero psql exit cannot satisfy verification'
        Assert-True (@($messages | Where-Object {
            $_ -match "\[WARN\].*psql.exe.*exit code -1073741515"
        }).Count -gt 0) 'silent native startup failure reports the executable path and exit code'
    }

    & {
        $script:RuntimeReady=$false; $script:ClientPresent=$true
        function Set-VmPostgresPath { return $true }
        $script:RuntimeApproved=$false; $script:ClientApproved=$false
        $script:RuntimeRestart=$false; $script:RestartRequired=$false
        $script:ClientInstalls=[Collections.Generic.List[string]]::new()
        $clientPath = Join-Path $env:ProgramFiles 'PostgreSQL\18\bin\psql.exe'
        function Get-Command { [pscustomobject]@{Source=$clientPath} }
        function Update-ProcessPath { }
        function Test-Path {
            param($LiteralPath,$PathType)
            if ($LiteralPath -eq $clientPath) { return $script:ClientPresent }
            if ($LiteralPath -match '\\System32\\(vcruntime140|vcruntime140_1|msvcp140)\.dll$') { return $script:RuntimeReady }
            throw "Unexpected path: $LiteralPath"
        }
        function Invoke-ToolProbe {
            param($Name,$Arguments)
            Assert-True ($Name -eq $clientPath -and ($Arguments -join ' ') -eq '--version') 'client dependency verification does not connect to a database'
            if (-not $script:RuntimeReady) { return [pscustomobject]@{Code=-1073741515;Text=''} }
            [pscustomobject]@{Code=0;Text='psql (PostgreSQL) 18.7'}
        }
        function Confirm-InstallAction {
            param($Message)
            if ($Message -match 'Microsoft\.VCRedist') { return $script:RuntimeApproved }
            return $script:ClientApproved
        }
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            Assert-True ($Command -eq 'winget') 'client dependencies use the existing consented package installer'
            $id = $Arguments[[Array]::IndexOf($Arguments, '--id') + 1]
            $script:ClientInstalls.Add($id)
            switch ($id) {
                'Microsoft.VCRedist.2015+.x64' {
                    $script:RuntimeReady=$true
                    $script:RestartRequired=$script:RuntimeRestart
                }
                'PostgreSQL.PostgreSQL.18' { $script:ClientPresent=$true }
                default { throw "Unexpected package: $id" }
            }
            return $true
        }
        Assert-True (-not (Install-VmPostgresClient) -and $script:ClientInstalls.Count -eq 0) 'declining the runtime prevents PostgreSQL installation'
        $script:RuntimeApproved=$true
        Assert-True (Install-VmPostgresClient) 'installing the missing runtime repairs an existing PostgreSQL client'
        Assert-True (($script:ClientInstalls -join ',') -eq 'Microsoft.VCRedist.2015+.x64') 'working client is not reinstalled after repairing its runtime'
        Assert-True ((Install-VmPostgresClient) -and $script:ClientInstalls.Count -eq 1) 'existing runtime and PostgreSQL client are preserved'
        $script:RuntimeReady=$false; $script:ClientPresent=$false; $script:ClientApproved=$true
        $script:ClientInstalls.Clear()
        Assert-True (Install-VmPostgresClient) 'fresh client installation includes its runtime prerequisite'
        Assert-True (($script:ClientInstalls -join ',') -eq 'Microsoft.VCRedist.2015+.x64,PostgreSQL.PostgreSQL.18') 'x64 runtime installs before the client'
        $script:RuntimeReady=$false; $script:ClientPresent=$false; $script:RuntimeRestart=$true
        $script:ClientInstalls.Clear()
        Assert-True (-not (Install-VmPostgresClient) -and $script:RestartRequired) 'runtime restart requirement is preserved'
        Assert-True (($script:ClientInstalls -join ',') -eq 'Microsoft.VCRedist.2015+.x64') 'PostgreSQL installation waits for the runtime restart'
        $script:RestartRequired=$false; $script:RuntimeReady=$false
        function Invoke-VmInstaller { throw 'fixture runtime installation failure' }
        Assert-Throws { Install-VmPostgresClient } 'runtime installation failure' 'runtime installation errors are not hidden'
    }

    & {
        $client = 'C:\fixture-postgres\18\bin\psql.exe'
        $directory = Split-Path -Parent $client
        $script:StoredUserPath = '%SystemRoot%\System32;C:\keep'
        $script:PathWrites=0; $script:PathApproved=$false; $script:PathUpdates=0
        $script:ResolvedClient=$client; $script:ClientRuns=$true
        $messages=[Collections.Generic.List[string]]::new()
        $registry = [pscustomobject]@{}
        $registry | Add-Member ScriptMethod GetValue { param($Name,$Default,$Options); return $script:StoredUserPath }
        $registry | Add-Member ScriptMethod GetValueNames { return @('Path') }
        $registry | Add-Member ScriptMethod GetValueKind { param($Name); return [Microsoft.Win32.RegistryValueKind]::ExpandString }
        function Set-ItemProperty {
            param($LiteralPath,$Name,$Value,$Type,$ErrorAction)
            Assert-True ($LiteralPath -eq 'HKCU:\Environment' -and $Name -eq 'Path' -and
                $Type -eq [Microsoft.Win32.RegistryValueKind]::ExpandString -and
                $ErrorAction -eq 'Stop') 'PATH writes preserve the registry type and surface errors'
            $script:StoredUserPath=$Value; $script:PathWrites++
        }
        function Get-VmPostgresClient { return $client }
        function Get-Item {
            param($LiteralPath,$ErrorAction)
            Assert-True ($LiteralPath -eq 'HKCU:\Environment') 'PostgreSQL PATH changes target only the current user'
            return $registry
        }
        function Confirm-InstallAction { return $script:PathApproved }
        function Update-ProcessPath { $script:PathUpdates++ }
        function Test-VmCommand { param($Name); return $Name -eq 'psql' -and $script:ClientRuns }
        function Get-Command { [pscustomobject]@{Source=$script:ResolvedClient} }
        function Write-InstallMessage { param($Message); $messages.Add($Message) }
        Assert-True (-not (Set-VmPostgresPath) -and $script:PathWrites -eq 0 -and
            $script:PathUpdates -eq 0) 'declining PATH changes preserves both user and process environments'
        $script:PathApproved=$true
        Assert-True (Set-VmPostgresPath) 'consented PostgreSQL PATH configuration completes'
        Assert-True ($script:StoredUserPath -ceq "%SystemRoot%\System32;C:\keep;$directory" -and
            $script:PathWrites -eq 1 -and $script:PathUpdates -eq 1) 'PATH append preserves raw variables and existing order and refreshes the installer'
        Assert-True ((Set-VmPostgresPath) -and $script:PathWrites -eq 1) 'repeated configuration does not duplicate PATH'
        $script:StoredUserPath = '"' + $directory.ToUpperInvariant() + '\";C:\keep'
        $script:PathApproved=$false
        Assert-True ((Set-VmPostgresPath) -and $script:PathWrites -eq 1) 'quoted case-insensitive paths with trailing separators are not duplicated'
        $script:StoredUserPath = ''; $script:PathApproved=$true
        Assert-True ((Set-VmPostgresPath) -and $script:StoredUserPath -ceq $directory) 'empty user PATH is initialized without an empty entry'
        $script:ResolvedClient='C:\older-postgres\psql.exe'
        Assert-True (Set-VmPostgresPath) 'existing command precedence is preserved'
        Assert-True (@($messages | Where-Object { $_ -match '^\[WARN\].*Another psql.*older-postgres' }).Count -eq 1) 'another psql taking precedence is reported explicitly'
        $script:ClientRuns=$false
        Assert-Throws { Set-VmPostgresPath } 'could not run' 'failed process PATH verification is not reported as success'
        function Get-VmPostgresClient { return $null }
        Assert-Throws { Set-VmPostgresPath } 'without a working' 'missing client cannot be added to PATH'
        function Get-VmPostgresClient { return $client }
        $script:StoredUserPath=''
        function Set-ItemProperty { throw 'fixture registry access denied' }
        Assert-Throws { Set-VmPostgresPath } 'registry access denied' 'persistent PATH write failures propagate'
    }

    if ($IsWindows) {
        & {
            $subKey = 'Software\appmod-vm-test-' + [guid]::NewGuid().ToString('N')
            $registryPath = 'HKCU:\' + $subKey
            $client = 'C:\fixture-postgres\18\bin\psql.exe'
            $directory = Split-Path -Parent $client
            $registry = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey)
            $registry.Dispose()
            try {
                function Get-VmPostgresClient { return $client }
                function Get-Item {
                    param($LiteralPath,$ErrorAction)
                    if ($LiteralPath -ne 'HKCU:\Environment') { throw 'Unexpected registry read target' }
                    Microsoft.PowerShell.Management\Get-Item -LiteralPath $registryPath -ErrorAction Stop
                }
                function Set-ItemProperty {
                    param($LiteralPath,$Name,$Value,$Type,$ErrorAction)
                    if ($LiteralPath -ne 'HKCU:\Environment') { throw 'Unexpected registry write target' }
                    Microsoft.PowerShell.Management\Set-ItemProperty -LiteralPath $registryPath `
                        -Name $Name -Value $Value -Type $Type -ErrorAction Stop
                }
                function Confirm-InstallAction { return $true }
                function Update-ProcessPath { }
                function Test-VmCommand { return $true }
                function Get-Command { [pscustomobject]@{Source=$client} }
                function Write-InstallMessage { param($Message) }
                foreach ($kind in @([Microsoft.Win32.RegistryValueKind]::String,
                    [Microsoft.Win32.RegistryValueKind]::ExpandString)) {
                    Microsoft.PowerShell.Management\Set-ItemProperty -LiteralPath $registryPath -Name Path `
                        -Value '%SystemRoot%\System32;C:\keep' -Type $kind -ErrorAction Stop
                    Assert-True (Set-VmPostgresPath) "PATH append works with a real read-only registry handle ($kind)"
                    Assert-True (Set-VmPostgresPath) "real registry PATH append is idempotent ($kind)"
                    $stored = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subKey)
                    try {
                        Assert-True ($stored.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq
                            "%SystemRoot%\System32;C:\keep;$directory" -and $stored.GetValueKind('Path') -eq $kind) `
                            "real registry PATH preserves raw entries, order and value type ($kind)"
                    }
                    finally { $stored.Dispose() }
                }
            }
            finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subKey) }
        }
    }

    & {
        function Get-Command { [pscustomobject]@{Source='Invoke-FixtureNative'} }
        function Invoke-LoggedProcess { [pscustomobject]@{ ExitCode = $script:NativeCode } }
        $logDirectory = $fixture
        foreach ($code in @(1641,3010)) {
            $script:NativeCode=$code; $script:RestartRequired=$false
            Assert-True (Invoke-VmInstaller fixture @()) "installer code $code is handled"
            Assert-True $script:RestartRequired "installer code $code requires manual restart"
        }
        $script:NativeCode=0; $script:RestartRequired=$false
        Assert-True (Invoke-VmInstaller fixture @()) 'native exit zero is handled'
        $script:NativeCode=42
        Assert-Throws { Invoke-VmInstaller fixture @() } '42' 'nonzero native status fails explicitly'
    }

    & {
        function Test-InstallInteractive { return $false }
        function Read-Host { throw 'must not prompt' }
        $Yes = $false
        Assert-Throws { Confirm-InstallAction 'fixture' } 'interactive.*-Yes' 'noninteractive mode requires Yes'
        Assert-Throws { Assert-VmInstallerContext } 'interactive.*-Yes|Windows x64' 'noninteractive identity guard runs before installation'
        function Test-InstallInteractive { return $true }
        function Get-LocalUser { [pscustomobject]@{SID=[pscustomobject]@{Value='S-1-5-21-123-456-789-1001'}} }
        Assert-Throws { Assert-VmInstallerContext } 'Sign in as appmoduser|Windows x64' 'another Windows account cannot install tools'
    }

    & {
        $script:Registered=$false
        function Get-Command { if ($script:Registered) { [pscustomobject]@{Source='fixture-winget.exe'} } }
        function Get-AppxPackage { [pscustomobject]@{Name='Microsoft.DesktopAppInstaller'} }
        function Confirm-InstallAction { return $false }
        function Add-AppxPackage { throw 'must not register before consent' }
        Assert-True (-not (Initialize-VmWinget)) 'App Installer registration requires consent'
        function Confirm-InstallAction { return $true }
        function Add-AppxPackage {
            param([switch]$RegisterByFamilyName,$MainPackage,$ErrorAction)
            Assert-True ($RegisterByFamilyName -and $MainPackage -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe') 'registers the official App Installer family'
            $script:Registered=$true
        }
        Assert-True (Initialize-VmWinget) 'WinGet registration is rechecked'
        $script:Registered=$false
        function Get-AppxPackage { return $null }
        function Get-PackageProvider { return $null }
        function Confirm-InstallAction { return $false }
        function Install-PackageProvider { throw 'must not install provider without consent' }
        Assert-True (-not (Initialize-VmWinget)) 'WinGet recovery provider requires separate consent'
    }

    & {
        function Get-WindowsOptionalFeature { throw 'Class not registered' }
        function Enable-WindowsOptionalFeature { throw 'Class not registered' }
        $script:FeatureResponse='{"State":"Enabled"}'
        $script:FeatureCode=0
        function Invoke-ToolProbe {
            param($Name,$Arguments)
            Assert-True ($Name -eq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -and
                $Arguments -contains '-NoProfile' -and $Arguments -contains '-NonInteractive') 'servicing runs in Windows PowerShell 5.1 outside MSIX PowerShell 7'
            $encodedIndex = [Array]::IndexOf($Arguments, '-EncodedCommand')
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Arguments[$encodedIndex + 1]))
            $prefix = @'
function Get-WindowsOptionalFeature {
    param([switch]$Online, $FeatureName, $ErrorAction)
    if (-not $Online -or $FeatureName -ne 'VirtualMachinePlatform') { throw 'Invalid feature query' }
    [pscustomobject]@{ State='Enabled' }
}
function Enable-WindowsOptionalFeature {
    param([switch]$Online, $FeatureName, [switch]$All, [switch]$NoRestart, $ErrorAction)
    if (-not $Online -or -not $All -or -not $NoRestart -or $FeatureName -ne 'MSMQ-Server') { throw 'Unsafe feature activation' }
    [pscustomobject]@{ RestartNeeded=$true }
}
'@
            $testEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$prefix`n$command"))
            $actual = (& $Name -NoLogo -NoProfile -NonInteractive -EncodedCommand $testEncoded | Out-String).Trim()
            Assert-True ($LASTEXITCODE -eq 0 -and $actual -eq $script:FeatureResponse) 'Windows PowerShell worker queries state or enables with NoRestart and returns JSON'
            [pscustomobject]@{ Code=$script:FeatureCode; Text=$script:FeatureResponse }
        }
        Assert-True ((Invoke-VmWindowsFeature -FeatureName VirtualMachinePlatform).State -eq 'Enabled') 'feature query avoids the current process DISM registration error'
        $script:FeatureResponse='{"RestartNeeded":true}'
        Assert-True (Invoke-VmWindowsFeature -FeatureName MSMQ-Server -Enable).RestartNeeded 'servicing preserves the restart-needed result'
    }

    & {
        function Invoke-ToolProbe { [pscustomobject]@{ Code=1; Text='fixture servicing failure' } }
        Assert-Throws { Invoke-VmWindowsFeature -FeatureName VirtualMachinePlatform } 'fixture servicing failure' 'servicing failures propagate instead of reporting a disabled feature'
        function Invoke-ToolProbe { [pscustomobject]@{ Code=0; Text='{}' } }
        Assert-Throws { Invoke-VmWindowsFeature -FeatureName VirtualMachinePlatform } 'Invalid.*response' 'missing feature state is rejected'
        Assert-Throws { Invoke-VmWindowsFeature -FeatureName MSMQ-Server -Enable } 'Invalid.*response' 'missing reboot status is rejected'
    }

    & {
        function Get-VmWslExecutable { 'fixture-wsl.exe' }
        $script:FeatureState='Enabled'; $script:StatusCode=0
        function Invoke-VmWindowsFeature { [pscustomobject]@{ State=$script:FeatureState } }
        function Invoke-ToolProbe {
            param($Name,$Arguments)
            Assert-True ($Name -eq 'fixture-wsl.exe' -and ($Arguments -join ' ') -eq '--status') 'WSL2 platform probe is read-only'
            [pscustomobject]@{ Code=$script:StatusCode; Text='' }
        }
        Assert-True (Test-VmWslPlatform) 'enabled platform with working wsl.exe is ready'
        $script:StatusCode=1
        Assert-True (-not (Test-VmWslPlatform)) 'failed wsl.exe status is not ready'
        $script:FeatureState='Disabled'; $script:StatusCode=0
        Assert-True (-not (Test-VmWslPlatform)) 'disabled VirtualMachinePlatform is not ready'
    }

    & {
        $script:Platform=$false; $script:FeatureState='Disabled'; $script:PlatformInstalls=0
        function Test-VmWslPlatform { $script:Platform }
        function Invoke-VmWindowsFeature { [pscustomobject]@{ State=$script:FeatureState } }
        function Get-VmWslExecutable { 'C:\Windows\System32\wsl.exe' }
        function Confirm-InstallAction { return $false }
        function Invoke-VmInstaller { throw 'must not install without consent' }
        Assert-True (-not (Install-VmWslPlatform)) 'WSL2 platform decline is preserved'
        function Confirm-InstallAction { return $true }
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            Assert-True ($Command -like '*wsl.exe' -and ($Arguments -join ' ') -eq '--install --no-distribution') 'WSL2 platform installs without a distribution'
            $script:PlatformInstalls++; return $true
        }
        $script:RestartRequired=$false
        Assert-True (-not (Install-VmWslPlatform)) 'WSL2 platform awaiting activation stays incomplete'
        Assert-True $script:RestartRequired 'WSL2 platform installation requires a manual restart'
        $script:FeatureState='EnablePending'; $script:RestartRequired=$false
        Assert-True (-not (Install-VmWslPlatform) -and $script:RestartRequired -and $script:PlatformInstalls -eq 1) 'pending platform activation is not reinstalled'
        $script:Platform=$true; $script:RestartRequired=$false
        Assert-True ((Install-VmWslPlatform) -and $script:PlatformInstalls -eq 1) 'ready WSL2 platform is preserved'
    }

    & {
        $emptyList = "Windows Subsystem for Linux has no installed distributions.`r`n`r`nUse 'wsl.exe --list --online' to list available distributions`r`nand 'wsl.exe --install <Distro>' to install."
        $script:DistroText = $emptyList.ToCharArray() -join "`0"
        $script:DistroCode = -1; $script:UbuntuInstalls = 0; $script:UbuntuApproved = $false
        $script:RestartRequired = $false
        function Test-VmWslPlatform { return $true }
        function Invoke-ToolProbe {
            param($Name,$Arguments)
            Assert-True ($Name -eq 'wsl.exe' -and ($Arguments -join ' ') -eq '--list --verbose') 'Ubuntu detection only lists distributions'
            [pscustomobject]@{ Code=$script:DistroCode; Text=$script:DistroText }
        }
        function Confirm-InstallAction { return $script:UbuntuApproved }
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            Assert-True ($Command -eq 'wsl.exe' -and ($Arguments -join ' ') -eq '--install --distribution Ubuntu --no-launch') 'empty distribution list reaches the consented Ubuntu installer'
            $script:UbuntuInstalls++
            $script:DistroCode = 0
            $script:DistroText = "  NAME      STATE      VERSION`r`n* Ubuntu    Stopped    2"
            return $true
        }
        Assert-True ((Get-VmUbuntuVersion) -eq 0) 'nonzero empty-list response with NUL characters means Ubuntu is absent'
        Assert-True (-not (Install-VmUbuntu) -and $script:UbuntuInstalls -eq 0) 'first Ubuntu installation still requires consent'
        $script:UbuntuApproved = $true
        Assert-True (Install-VmUbuntu) 'first Ubuntu installation succeeds after the empty-list response'
        Assert-True ((Get-VmUbuntuVersion) -eq 2) 'installed Ubuntu version is parsed from the real list format'
        Assert-True ((Install-VmUbuntu) -and $script:UbuntuInstalls -eq 1) 'existing Ubuntu is preserved after first installation'
        $script:DistroText = "  NAME      STATE      VERSION`r`n* Debian    Stopped    2"
        Assert-True ((Get-VmUbuntuVersion) -eq 0) 'other distributions do not count as Ubuntu'
        $script:DistroText = "  NAME      STATE      VERSION`r`n* Ubuntu    Stopped    1"
        Assert-Throws { Install-VmUbuntu } 'WSL1' 'parsed WSL1 installation is not replaced'
        $script:DistroCode = 1; $script:DistroText = 'Access is denied.'
        Assert-Throws { Install-VmUbuntu } 'Access is denied' 'real distribution-list errors still propagate'
        $script:DistroText = ''
        Assert-Throws { Get-VmUbuntuVersion } 'Failed to list' 'unexplained nonzero status is not treated as an empty list'
    }

    & {
        $script:WslVersion=0; $script:WslCalls=0
        function Test-VmWslPlatform { return $false }
        function Get-VmUbuntuVersion { throw 'must not query distributions before the platform is ready' }
        Assert-True (-not (Install-VmUbuntu)) 'Ubuntu waits for the WSL2 platform'
        function Test-VmWslPlatform { return $true }
        function Get-VmUbuntuVersion { $script:WslVersion }
        function Confirm-InstallAction { return $false }
        function Invoke-VmInstaller { throw 'must not install without consent' }
        Assert-True (-not (Install-VmUbuntu)) 'Ubuntu decline is preserved'
        function Confirm-InstallAction { return $true }
        function Invoke-VmInstaller {
            param($Command,$Arguments)
            Assert-True ($Command -eq 'wsl.exe' -and ($Arguments -join ' ') -eq '--install --distribution Ubuntu --no-launch') 'Ubuntu installs without auto-launch or user deletion'
            $script:WslVersion=2; $script:WslCalls++; return $true
        }
        $script:RestartRequired=$false
        Assert-True (Install-VmUbuntu) 'Ubuntu installation is checked'
        Assert-True (Install-VmUbuntu) 'existing Ubuntu WSL2 is preserved'
        Assert-True ($script:WslCalls -eq 1) 'Ubuntu is not reinstalled'
        $script:WslVersion=1
        Assert-Throws { Install-VmUbuntu } 'WSL1' 'existing WSL1 is not destructively replaced'
    }

    & {
        function Confirm-InstallAction { return $true }
        function Invoke-VmWindowsFeature {
            param($FeatureName,[switch]$Enable)
            if (-not $Enable) { return [pscustomobject]@{ State='Disabled' } }
            Assert-True ($FeatureName -eq 'MSMQ-Server') 'MSMQ enables its Windows feature'
            return [pscustomobject]@{ RestartNeeded=$true }
        }
        $script:RestartRequired=$false
        Assert-True (-not (Install-VmMsmq)) 'MSMQ pending reboot stays incomplete'
        Assert-True $script:RestartRequired 'MSMQ reports reboot requirement'
    }

    & {
        $script:NodeCalls=0; $script:AutoInstall=$true; $script:Approved=$false
        function Get-Command { [pscustomobject]@{ Source='fixture-nvm.exe' } }
        function Invoke-ToolProbe {
            param($Name,$Arguments)
            switch ($Arguments[0]) {
                'version' { [pscustomobject]@{Code=0;Text='2.0.1'} }
                'config' {
                    if ($Arguments[1] -eq 'set') {
                        Assert-True (($Arguments -join ' ') -eq 'config set auto_install=false') 'nvm uses documented assignment syntax'
                        $script:AutoInstall=$false
                    }
                    [pscustomobject]@{Code=0;Text=(@{ auto_install=$script:AutoInstall } | ConvertTo-Json -Compress)}
                }
                default { throw 'unexpected nvm probe' }
            }
        }
        function Confirm-InstallAction { $script:Approved }
        function Get-WorkshopNvmConfiguration { if (-not $script:AutoInstall) { [pscustomobject]@{auto_install=$false} } }
        function Install-WorkshopNode { $script:NodeCalls++; return $true }
        Assert-True (-not (Install-VmNvm)) 'automatic Node installation is not enabled by default'
        Assert-True ($script:NodeCalls -eq 0) 'no Node probes before nvm policy consent'
        $script:Approved=$true
        Assert-True (Install-VmNvm) 'consented nvm preparation uses shared Node installer'
        Assert-True ($script:NodeCalls -eq 1 -and -not $script:AutoInstall) 'nvm auto-install disabled before Node work'
        function Invoke-ToolProbe { [pscustomobject]@{Code=0;Text='1.2.2'} }
        Assert-Throws { Install-VmNvm } 'not replaced automatically' 'nvm 1.x is never silently replaced'
    }

    & {
        $Yes = $true
        function Test-InstallInteractive { return $false }
        function Read-Host { throw 'Yes must not prompt for Node installation or activation' }
        function Get-Command { [pscustomobject]@{ Source='fixture-nvm.exe' } }
        function Invoke-ToolProbe {
            param($Name,$Arguments)
            if ($Arguments[0] -eq 'version') { return [pscustomobject]@{Code=0;Text='2.0.1'} }
            return [pscustomobject]@{Code=0;Text='{"auto_install":false}'}
        }
        function Get-WorkshopNvmConfiguration { return [pscustomobject]@{ auto_install=$false } }
        function Install-WorkshopNode {
            Assert-True (Confirm-InstallAction 'fixture Node installation') 'Yes covers the Node installation prompt'
            Assert-True (Confirm-InstallAction 'fixture Node activation') 'Yes covers the Node activation prompt'
            return $true
        }
        Assert-True (Install-VmNvm) 'Yes completes the VM Node flow'
        $Yes = $false
        function Test-InstallInteractive { return $true }
        function Read-Host { return 'n' }
        Assert-True (-not (Confirm-InstallAction 'fixture unrelated action')) 'installation still requires explicit approval without Yes'
    }

    & {
        function Get-VmVsInstance { return $null }
        function Install-VmPackage {
            param($Id,$Name,$TestInstalled,$VersionPattern,$ExtraArguments)
            Assert-True ($Id -eq 'Microsoft.VisualStudio.BuildTools' -and $VersionPattern -eq '^18\.\d+\.\d+$') 'VS 2026 installs only the stable 18.x Build Tools package'
            Assert-True ($ExtraArguments[0] -eq '--override' -and $ExtraArguments[1] -match '--norestart' -and
                $ExtraArguments[1].Contains('buildtools.vsconfig')) 'Build Tools configuration and no-restart options are forwarded'
            return $true
        }
        Assert-True (Install-VmVisualStudio BuildTools (Join-Path $vmScripts 'buildtools.vsconfig')) 'Build Tools installer plans explicit workload config'
    }

    & {
        $script:VsReady=$false
        function Get-VmVsInstance {
            param($Product,$Requires=@())
            if ($Requires.Count) {
                Assert-True ($Product -eq 'BuildTools' -and
                    $Requires -contains 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools' -and
                    $Requires -contains 'Microsoft.VisualStudio.Workload.WebBuildTools' -and
                    $Requires -contains 'Microsoft.Net.Component.4.8.TargetingPack' -and
                    $Requires -contains 'Microsoft.Net.Component.4.8.SDK') 'Build Tools verifies web and desktop workloads and Framework development tools'
                Assert-True ($Requires -notcontains 'Microsoft.VisualStudio.Component.IISExpress' -and
                    $Requires -notcontains 'Microsoft.VisualStudio.Component.SQL.LocalDB.Runtime') 'unsupported runtime components are not passed to Build Tools'
            }
            if (-not $Requires.Count -or $script:VsReady) { [pscustomobject]@{installationPath='C:\fixture with spaces\VS'} }
        }
        function Confirm-InstallAction { return $true }
        function Start-Process {
            param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction)
            Assert-True ($ArgumentList -match '^modify ' -and $ArgumentList.Contains('"C:\fixture with spaces\VS"') -and
                $ArgumentList -notmatch '--wait' -and $Wait -and $PassThru) 'existing VS modification quotes paths and waits through Start-Process'
            $script:VsReady=$true
            [pscustomobject]@{ExitCode=0}
        }
        Assert-True (Install-VmVisualStudio BuildTools (Join-Path $vmScripts 'buildtools.vsconfig')) 'existing VS workloads are verified after modification'
    }

    & {
        $script:MsiReady=$false; $script:MsiApprovals=$false; $script:MsiInstalls=0
        $script:MsiHash='fixture-hash'; $script:MsiSignature='Valid'; $script:MsiPublisher='Microsoft Corporation'
        $script:MsiCode=0; $script:VerifyMsi=$true; $script:RestartRequired=$false
        function Confirm-InstallAction {
            param($Message)
            Assert-True ($Message -match 'accept its license terms') 'standalone MSI consent includes license acceptance'
            return $script:MsiApprovals
        }
        function Invoke-WebRequest {
            param($Uri,$OutFile,[switch]$UseBasicParsing,$ErrorAction)
            $script:MsiDownload=$OutFile
            [IO.File]::WriteAllText($OutFile,'fixture')
        }
        function Get-FileHash { [pscustomobject]@{Hash=$script:MsiHash} }
        function Get-AuthenticodeSignature {
            [pscustomobject]@{Status=$script:MsiSignature;SignerCertificate=[pscustomobject]@{Subject="CN=Microsoft Corporation, O=$script:MsiPublisher, C=US"}}
        }
        function Update-ProcessPath { }
        function Start-Process {
            param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction)
            Assert-True ($FilePath.EndsWith('System32\msiexec.exe') -and
                $ArgumentList.Contains("/i `"$script:MsiDownload`" /passive /norestart IACCEPTSQLLOCALDBLICENSETERMS=YES") -and
                $Wait -and $PassThru) 'standalone MSI uses quoted paths, license acceptance and no automatic restart'
            $script:MsiInstalls++
            $script:MsiReady=$script:VerifyMsi
            [pscustomobject]@{ExitCode=$script:MsiCode}
        }
        $options=@{Name='fixture';Uri='https://download.visualstudio.microsoft.com/fixture.msi';Sha256='fixture-hash'
            TestInstalled={ $script:MsiReady };Properties='IACCEPTSQLLOCALDBLICENSETERMS=YES'}
        Assert-True (-not (Install-VmMicrosoftMsi @options)) 'declined standalone MSI does not install'
        Assert-True (-not $script:MsiDownload -and $script:MsiInstalls -eq 0) 'decline occurs before any download'
        $script:MsiApprovals=$true
        Assert-True (Install-VmMicrosoftMsi @options) 'standalone MSI is verified after installation'
        Assert-True (-not (Test-Path -LiteralPath $script:MsiDownload)) 'successful MSI is cleaned up'
        Assert-True (Install-VmMicrosoftMsi @options) 'existing standalone tool is kept without reinstalling'
        Assert-True ($script:MsiInstalls -eq 1) 'existing tool never launches another MSI'
        $script:MsiReady=$false; $script:MsiHash='wrong-hash'
        Assert-Throws { Install-VmMicrosoftMsi @options } 'hash' 'wrong MSI hash blocks execution'
        $script:MsiHash='fixture-hash'; $script:MsiSignature='NotSigned'
        Assert-Throws { Install-VmMicrosoftMsi @options } 'signature' 'unsigned MSI blocks execution'
        $script:MsiSignature='Valid'; $script:MsiPublisher='Other Publisher'
        Assert-Throws { Install-VmMicrosoftMsi @options } 'signature' 'valid signature from another publisher blocks execution'
        Assert-True ($script:MsiInstalls -eq 1 -and -not (Test-Path -LiteralPath $script:MsiDownload)) 'failed integrity checks clean up without executing'
        $script:MsiPublisher='Microsoft Corporation'; $script:VerifyMsi=$false; $script:MsiCode=1603
        Assert-Throws { Install-VmMicrosoftMsi @options } '1603' 'MSI installation failure propagates'
        $script:MsiCode=0
        Assert-Throws { Install-VmMicrosoftMsi @options } 'after installation' 'MSI exit zero without installed files is not success'
        $script:MsiCode=3010
        Assert-True (-not (Install-VmMicrosoftMsi @options)) 'MSI reboot request remains incomplete'
        Assert-True ($script:RestartRequired -and -not (Test-Path -LiteralPath $script:MsiDownload)) 'MSI reboot request is reported and download cleaned up'
    }

    & {
        function Install-VmMicrosoftMsi {
            param($Name,$Uri,$Sha256,$TestInstalled,$Properties)
            Assert-True ($Uri.StartsWith('https://download.visualstudio.microsoft.com/') -and
                $Sha256 -match '^[a-f0-9]{64}$') 'runtime MSI uses official Microsoft URL and pinned SHA-256'
            if ($Name -like '*LocalDB*') {
                Assert-True ($Properties -eq 'IACCEPTSQLLOCALDBLICENSETERMS=YES') 'LocalDB wrapper passes its required license acceptance only after MSI consent'
            }
            return $true
        }
        Assert-True (Install-VmIisExpress) 'IIS Express uses standalone Microsoft MSI installation'
        Assert-True (Install-VmLocalDb) 'LocalDB uses standalone Microsoft MSI installation'
    }

    & {
        function Test-Path { return $false }
        Assert-Throws { Test-VmFrameworkTools } 'Targeting Pack' 'Framework runtime alone cannot satisfy build prerequisites'
        function Test-Path {
            param($LiteralPath)
            $LiteralPath.EndsWith('v4.8\mscorlib.dll') -or $LiteralPath.EndsWith('170\Tools\Binn\SqlLocalDB.exe')
        }
        function Get-DotnetFrameworkBuildTools { [pscustomobject]@{MSBuild='fixture'} }
        function Get-WorkshopIisExpress { [pscustomobject]@{Exe='fixture'} }
        function Get-Command { return $null }
        function Test-VmCommand {
            param($Name,$Arguments)
            Assert-True ($Name.EndsWith('170\Tools\Binn\SqlLocalDB.exe') -and ($Arguments -join ' ') -eq 'versions') 'LocalDB fallback only queries versions, never creates a database'
            return $true
        }
        Assert-True (Test-VmFrameworkTools) 'LocalDB is detected even before PATH refresh'
    }

    & {
        function Get-VmCopilotVersion { return $null }
        function Confirm-InstallAction { return $false }
        function Invoke-RestMethod { throw 'must not download without consent' }
        Assert-True (-not (Install-VmCopilot)) 'Copilot consent precedes release discovery'
        function Get-VmCopilotVersion { return [version]'1.3.0' }
        Assert-True (Install-VmCopilot) 'existing Copilot app is preserved'
    }

    & {
        $script:CopilotVersion=$null; $script:MsiCalls=0; $script:SignatureStatus='Valid'
        function Get-VmCopilotVersion { $script:CopilotVersion }
        function Confirm-InstallAction { return $true }
        function Invoke-RestMethod {
            [pscustomobject]@{ tag_name='v1.3.0'; prerelease=$false; draft=$false; assets=@(
                [pscustomobject]@{ name='GitHub-Copilot-windows-x64.msi'
                    browser_download_url='https://github.com/github/app/releases/download/v1.3.0/GitHub-Copilot-windows-x64.msi'
                    digest='sha256:ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb'
                }
            ) }
        }
        function Invoke-WebRequest {
            param($Uri,$OutFile,[switch]$UseBasicParsing,$ErrorAction)
            $script:DownloadedMsi=$OutFile
            [IO.File]::WriteAllBytes($OutFile,[byte[]]@(97))
        }
        function Get-AuthenticodeSignature {
            [pscustomobject]@{Status=$script:SignatureStatus; SignerCertificate=[pscustomobject]@{Subject='CN="GitHub, Inc.", O="GitHub, Inc.", C=US'}}
        }
        function Start-Process {
            param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction)
            Assert-True ($ArgumentList.Contains("/i `"$script:DownloadedMsi`" /passive /norestart") -and $Wait) 'Copilot MSI path is quoted and automatic restart disabled'
            $script:MsiCalls++; $script:CopilotVersion=[version]'1.3.0'
            [pscustomobject]@{ExitCode=0}
        }
        Assert-True (Install-VmCopilot) 'Copilot verifies digest, signature and installed version'
        Assert-True (-not (Test-Path -LiteralPath $script:DownloadedMsi)) 'successful MSI download is cleaned up'
        $script:CopilotVersion=$null; $script:SignatureStatus='NotSigned'
        Assert-Throws { Install-VmCopilot } 'signature' 'unsigned MSI never executes'
        Assert-True ($script:MsiCalls -eq 1 -and -not (Test-Path -LiteralPath $script:DownloadedMsi)) 'failed MSI verification cleans up without execution'
    }

    & {
        $script:RuntimeSteps=[Collections.Generic.List[string]]::new()
        $script:CliSteps=[Collections.Generic.List[string]]::new()
        $script:InstallationOrder=[Collections.Generic.List[string]]::new()
        $script:CopilotCliCheck=$null
        function Test-RebootPending { return $false }
        function Get-PSDrive { [pscustomobject]@{Free=100GB} }
        function Install-VmWslPlatform { $script:InstallationOrder.Add('WSL2'); return $true }
        function Install-VmUbuntu { $script:InstallationOrder.Add('Ubuntu'); return $true }
        function Install-VmMsmq { $script:InstallationOrder.Add('MSMQ'); return $true }
        function Install-VmPackage {
            param($Id,$Name,$TestInstalled)
            $script:InstallationOrder.Add($Id)
            if ($Id -in @('GitHub.cli','GitHub.Copilot')) { $script:CliSteps.Add($Id) }
            if ($Id -eq 'GitHub.Copilot') { $script:CopilotCliCheck=$TestInstalled }
            return $true
        }
        function Install-VmNvm { $script:InstallationOrder.Add('Node'); $script:CliSteps.Add('nvm'); return $true }
        function Install-VmDotnetSdk { param($Major); $script:InstallationOrder.Add("SDK$Major"); return $true }
        function Install-VmPostgresClient { $script:InstallationOrder.Add('PostgreSQL'); return $true }
        function Install-VmCopilot { $script:InstallationOrder.Add('CopilotApp'); return $true }
        function Install-VmVisualStudio {
            param($Product,$ConfigFile)
            Assert-True ($Product -eq 'BuildTools') 'installer never requests a Community installation'
            $script:InstallationOrder.Add('BuildTools')
            $script:RuntimeSteps.Add('BuildTools')
            return $true
        }
        function Install-VmIisExpress { $script:InstallationOrder.Add('IIS'); $script:RuntimeSteps.Add('IIS Express'); return $true }
        function Install-VmLocalDb { $script:InstallationOrder.Add('LocalDB'); $script:RuntimeSteps.Add('LocalDB'); return $true }
        function Test-VmFrameworkTools { $script:InstallationOrder.Add('FrameworkCheck'); $script:RuntimeSteps.Add('Verify'); return $true }
        $savedCI = $env:CI; $savedNoColor = $env:NO_COLOR; $savedTerm = $env:TERM
        $rendered = [Collections.Generic.List[object]]::new()
        function Test-InstallOutputTerminal { return $true }
        function Write-Host {
            param($Object,$ForegroundColor)
            $rendered.Add([pscustomobject]@{ Text=$Object; Color=$ForegroundColor })
        }
        try {
            $env:CI = ''; $env:NO_COLOR = ''; $env:TERM = 'xterm'
            Assert-True ((Invoke-VmToolInstallation) -eq 0) 'Build Tools-only flow completes with separate runtime tools'
            Assert-True (($script:RuntimeSteps -join ',') -eq 'BuildTools,IIS Express,LocalDB,Verify') 'standalone runtime tools install after Build Tools and before final verification'
            Assert-True (($script:CliSteps -join ',') -eq 'nvm,GitHub.cli,GitHub.Copilot') 'Copilot CLI follows GitHub CLI after the runtime group'
            $expectedOrder = @(
                'WSL2', 'Ubuntu', 'MSMQ', 'Microsoft.VCRedist.2015+.x64',
                'Microsoft.DotNet.Framework.Runtime', 'SDK10', 'SDK11', 'Node',
                'BuildTools', 'IIS', 'LocalDB', 'FrameworkCheck',
                'PostgreSQL', 'Docker.DockerDesktop', 'Git.Git', 'GitHub.cli', 'GitHub.Copilot',
                'Microsoft.AzureCLI', 'Microsoft.Azd', 'Microsoft.VisualStudioCode',
                'CopilotApp', 'GitHub.Copilot.modernization.agent'
            )
            Assert-True (($script:InstallationOrder -join ',') -ceq ($expectedOrder -join ',')) 'all tools run in the agreed dependency and purpose order'
            $expectedGroups = @(
                '[INFO] === [2/8] Windows features ===',
                '[INFO] === [3/8] Runtimes and SDKs ===',
                '[INFO] === [4/8] .NET Framework build and run tools ===',
                '[INFO] === [5/8] Database and containers ===',
                '[INFO] === [6/8] GitHub tools ===',
                '[INFO] === [7/8] Azure tools ===',
                '[INFO] === [8/8] Editors and modernization tools ==='
            )
            $groupMessages = @($rendered | Where-Object { $_.Text.StartsWith('[INFO] === ') })
            Assert-True (($groupMessages.Text -join ',') -ceq ($expectedGroups -join ',')) 'each installation group heading appears once in order'
            $script:CopilotCliCode=0
            function Invoke-ToolProbe {
                param($Name,$Arguments)
                Assert-True ($Name -eq 'copilot' -and ($Arguments -join ' ') -eq '--version') 'Copilot CLI verification only probes its version without starting a session'
                [pscustomobject]@{ Code=$script:CopilotCliCode; Text='fixture Copilot CLI version' }
            }
            Assert-True (& $script:CopilotCliCheck) 'working Copilot CLI is recognized as installed'
            $script:CopilotCliCode=1
            Assert-True (-not (& $script:CopilotCliCheck)) 'failed Copilot CLI probe does not count as installed'
            foreach ($case in @(
                @{ Status='PASS'; Color='Green' },
                @{ Status='MANUAL'; Color='Cyan' },
                @{ Status='INFO'; Color='Blue' }
            )) {
                $messages = @($rendered | Where-Object { $_.Text.StartsWith("[$($case.Status)]") })
                Assert-True ($messages.Count -gt 0 -and @($messages | Where-Object Color -ne $case.Color).Count -eq 0) "VM $($case.Status) messages use the shared status color"
            }
            $rendered.Clear()
            function Install-VmUbuntu { throw 'fixture Ubuntu failure' }
            Assert-True ((Invoke-VmToolInstallation) -eq 1) 'colored failure output preserves the incomplete exit code'
            Assert-True (@($rendered | Where-Object {
                $_.Text -eq '[FAIL] Ubuntu WSL2: fixture Ubuntu failure' -and $_.Color -eq 'Red'
            }).Count -eq 1) 'VM installation failures retain their details and render red'
            $rendered.Clear()
            $env:NO_COLOR = '1'
            Assert-True ((Invoke-VmToolInstallation) -eq 1) 'plain output preserves the incomplete exit code'
            Assert-True ($rendered.Count -gt 0 -and @($rendered | Where-Object Color).Count -eq 0) 'NO_COLOR disables colors throughout the VM installation flow'
        }
        finally {
            $env:CI = $savedCI; $env:NO_COLOR = $savedNoColor; $env:TERM = $savedTerm
        }
    }

    & {
        function Test-RebootPending { return $true }
        function Get-PSDrive { throw 'must not proceed before reboot' }
        Assert-True ((Invoke-VmToolInstallation) -eq 3010) 'reboot-required entry exits before further work'
        function Test-RebootPending { return $false }
        function Get-PSDrive { [pscustomobject]@{Free=100GB} }
        function Install-VmWslPlatform { $script:RestartRequired=$true; return $false }
        function Install-VmUbuntu { throw 'must not run after reboot boundary' }
        Assert-True ((Invoke-VmToolInstallation) -eq 3010) 'new reboot requirement stops subsequent installation steps'
    }

    $staging = [IO.File]::ReadAllText((Join-Path $root 'scripts\stage-user-scripts.ps1')).Replace('__PAYLOAD_BASE64__', $bundle.content)
    $tokens=$null; $errors=$null
    $null = [Management.Automation.Language.Parser]::ParseInput($staging, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'generated inline staging script parses'
    Assert-True ([Text.Encoding]::UTF8.GetByteCount($staging) -lt 131072) 'inline script remains below ARM string result limit'
    if ($IsWindows) {
        $installer = Join-Path $vmScripts 'install-vm-tools.ps1'
        & powershell.exe -NoProfile -NonInteractive -File $installer -Help | Out-Host
        Assert-True ($LASTEXITCODE -eq 0) 'Windows PowerShell 5.1 can parse installer and show help'
        & powershell.exe -NoProfile -NonInteractive -File $installer 2>&1 | Out-Host
        Assert-True ($LASTEXITCODE -eq 1) 'real 5.1 noninteractive entry refuses installation'
        $yesFixture = Join-Path $fixture 'yes-entry'
        $null = [IO.Directory]::CreateDirectory($yesFixture)
        $workerFixture = Join-Path $yesFixture 'worker fixture.ps1'
        $workerSource = @'
param([string]$Track, [switch]$Yes)
@{ Track = $Track; Yes = [bool]$Yes } | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $env:APPMOD_BOOTSTRAP_TEST_OUTPUT
exit 37
'@
        [IO.File]::WriteAllText($workerFixture, $workerSource, [Text.UTF8Encoding]::new($true))
        $previousOutput = $env:APPMOD_BOOTSTRAP_TEST_OUTPUT
        try {
            $env:APPMOD_BOOTSTRAP_TEST_OUTPUT = Join-Path $yesFixture 'result.json'
            $workerCode = Invoke-WorkshopPowerShell -ScriptPath $workerFixture `
                -BoundParameters @{ Track = 'dotnet'; Yes = $true } -RemainingArguments @()
            $workerResult = Get-Content -LiteralPath $env:APPMOD_BOOTSTRAP_TEST_OUTPUT -Raw | ConvertFrom-Json
            Assert-True ($workerCode -eq 37 -and $workerResult.Track -eq 'dotnet' -and $workerResult.Yes) 'bootstrap forwards Yes and preserves the worker exit code'
        }
        finally { $env:APPMOD_BOOTSTRAP_TEST_OUTPUT = $previousOutput }
        $escaped = $installer.Replace("'", "''")
        & powershell.exe -NoProfile -NonInteractive -Command "try { . '$escaped'; exit 99 } catch { Write-Output 'expected dot-source rejection'; exit 0 }" | Out-Host
        Assert-True ($LASTEXITCODE -eq 0) '5.1 dot-sourcing throws without exiting caller'
        $inlineFile = Join-Path $fixture 'inline.ps1'
        [IO.File]::WriteAllText($inlineFile,$staging,[Text.UTF8Encoding]::new($true))
        $parserCommand = '$t=$null; $e=$null; [void][Management.Automation.Language.Parser]::ParseFile(''' +
            $inlineFile.Replace("'", "''") + ''',[ref]$t,[ref]$e); if($e.Count){$e;exit 1}'
        & powershell.exe -NoProfile -NonInteractive -Command $parserCommand | Out-Host
        Assert-True ($LASTEXITCODE -eq 0) 'generated inline script parses in Windows PowerShell 5.1'
    }

    if ($CompiledTemplate) {
        $template = Get-Content -LiteralPath $CompiledTemplate -Raw | ConvertFrom-Json
        Assert-True (-not ($template.parameters.location.PSObject.Properties.Name -contains 'defaultValue')) 'location has no default that would suppress the azd selection prompt'
        Assert-True ($template.parameters.adminPassword.type -eq 'secureString' -and
            -not ($template.parameters.adminPassword.PSObject.Properties.Name -contains 'defaultValue')) 'password is prompted and secure'
        Assert-True ($template.parameters.confirmWindowsClientLicense.allowedValues.Count -eq 1 -and
            $template.parameters.confirmWindowsClientLicense.allowedValues[0] -eq $true) 'license refusal cannot provision'
        $raw = [IO.File]::ReadAllText($CompiledTemplate)
        Assert-True ($raw -notmatch 'AADLoginForWindows|roleAssignments|principalId|runAsPassword') 'no Entra login or copied administrator secrets'
        $workstation = @($template.resources | Where-Object name -eq 'workstation')[0].properties.template
        $vm = @($workstation.resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines')[0]
        Assert-True ($vm.properties.osProfile.adminUsername -eq 'appmoduser') 'local admin username cannot vary'
        Assert-True ($vm.properties.securityProfile.uefiSettings.secureBootEnabled -and
            $vm.properties.securityProfile.uefiSettings.vTpmEnabled) 'Windows 11 secure boot and TPM preserved'
        $schedule = @($workstation.resources | Where-Object type -eq 'Microsoft.DevTestLab/schedules')[0]
        Assert-True (-not ($schedule.PSObject.Properties.Name -contains 'condition') -and
            $schedule.properties.status -eq "[if(parameters('autoShutdownEnabled'), 'Enabled', 'Disabled')]") 'disabling shutdown updates an existing schedule instead of leaving it active'
        $scripts = @($template.resources | Where-Object name -eq 'user-scripts')[0].properties.template
        $delivery = @($scripts.resources | Where-Object type -eq 'Microsoft.Compute/virtualMachines/runCommands')[0]
        Assert-True ($delivery.properties.treatFailureAsDeploymentFailure -and -not $delivery.properties.asyncExecution) 'staging failure fails synchronous deployment'
    }
    Write-Host "[PASS] VM infrastructure and installer checks: $script:Passed"
}
finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
