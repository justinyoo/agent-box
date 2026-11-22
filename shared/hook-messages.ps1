function Write-HookMessage {
    param([string]$Message)

    $options = @{}
    if (-not $env:NO_COLOR -and -not $env:CI -and $env:TERM -ne 'dumb' -and
        -not [Console]::IsOutputRedirected -and $Message -match '^\[(PASS|FAIL|WARN|MANUAL|INFO)\]') {
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
