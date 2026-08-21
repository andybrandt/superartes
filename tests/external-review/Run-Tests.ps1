[CmdletBinding()]
param(
    [Parameter()]
    [string]$RunnerPath = (Join-Path $PSScriptRoot '..\..\skills\external-review\invoke-reviewer.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Test-Lib.ps1')

# This check intentionally precedes fixture creation. It is the native Windows
# RED checkpoint and must fail for only the deliberately missing adapter.
if (-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) {
    [Console]::Error.WriteLine("FAIL: PowerShell runner is missing: $RunnerPath")
    exit 1
}
$RunnerPath = (Resolve-Path -LiteralPath $RunnerPath).ProviderPath

function Invoke-Runner {
    param([Parameter()][string[]]$Arguments = @())
    Invoke-Captured $RunnerPath $Arguments
}

function Start-Review {
    param(
        [Parameter(Mandatory = $true)][int]$ExpectedExit,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    Invoke-Runner (@('start') + $Arguments)
    Assert-Equal $ExpectedExit.ToString() $script:CaptureExitCode.ToString() "start returns $ExpectedExit"
    return Get-OutputField 'RUN_DIR'
}

function Wait-Review {
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][int]$Timeout,
        [Parameter(Mandatory = $true)][int]$ExpectedExit
    )
    Invoke-Runner @('wait', $RunDirectory, $Timeout.ToString())
    Assert-Equal $ExpectedExit.ToString() $script:CaptureExitCode.ToString() "wait returns $ExpectedExit"
}

function Copy-RunFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Suffix
    )
    $destination = Join-Path $env:SUPERARTES_REVIEW_TMPDIR ("run-synthetic-$Suffix")
    Copy-Item -LiteralPath $Source -Destination $destination -Recurse
    $runId = "synthetic-$Suffix"
    Write-Utf8NoBom (Join-Path $destination 'run-id') $runId
    Write-Utf8NoBom (Join-Path $destination 'run-path') $destination
    Write-Utf8NoBom (Join-Path $destination 'marker') "superartes-external-review:$runId"
    return $destination
}

function Assert-ArtifactSet {
    param(
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][string[]]$Present,
        [Parameter(Mandatory = $true)][string[]]$Absent,
        [Parameter(Mandatory = $true)][string]$Label
    )
    foreach ($artifact in $Present) {
        if (Test-Path -LiteralPath (Join-Path $RunDirectory $artifact) -PathType Leaf) {
            Pass-Test "$Label retains applicable artifact $artifact"
        }
        else { Fail-Test "$Label retains applicable artifact $artifact" }
    }
    foreach ($artifact in $Absent) {
        if (-not (Test-Path -LiteralPath (Join-Path $RunDirectory $artifact))) {
            Pass-Test "$Label omits inapplicable artifact $artifact"
        }
        else { Fail-Test "$Label omits inapplicable artifact $artifact" }
    }
}

function Test-SharedContract {
    $contractPath = Join-Path $PSScriptRoot 'contract.txt'
    $contract = @{}
    foreach ($line in [IO.File]::ReadAllLines($contractPath)) {
        $parts = $line.Split(
            [char[]]@('='), 2, [StringSplitOptions]::None)
        $contract[$parts[0]] = $parts[1]
    }
    Assert-Equal 'check,start,status,wait,cancel,cleanup' $contract.operations 'PowerShell reads operation contract'
    Assert-Equal 'claude-prompt,codex-prompt,codex-review' $contract.profiles 'PowerShell reads profile contract'
    Assert-Equal 'running,exited,launch-failed,cancelled,indeterminate' $contract.states 'PowerShell reads state contract'
    Assert-Equal 'marker,run-path,review-key,profile,provider,run-id,provider-session,work-dir,scope-kind,scope-value,state,started-at,completed-at,supervisor-pid,supervisor-start,reviewer-pid,reviewer-start,reviewer-pgid,exit-code,prompt,result,reviewer-output,reviewer-log,supervisor-output,supervisor-log,previous-run,cancel-requested' $contract.artifacts 'PowerShell reads artifact contract'
    Invoke-Runner @('--help')
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'help succeeds'
    foreach ($word in (($contract.operations + ',' + $contract.profiles).Split(','))) {
        Assert-Contains $script:CaptureOutput $word "help advertises $word"
    }
    foreach ($code in @('0', '2', '3', '4', '12', '64', '65', '66', '75', '127')) {
        Assert-Contains $script:CaptureOutput $code "help advertises exit $code"
    }
}

function Test-StaticSecurityInvariants {
    $source = [IO.File]::ReadAllText($RunnerPath)
    $testSourceBytes = [IO.File]::ReadAllBytes($PSCommandPath)
    if (@($testSourceBytes | Where-Object { $_ -gt 0x7F }).Count -eq 0) {
        Pass-Test 'PowerShell test source is ASCII-safe without an encoding declaration'
    }
    else { Fail-Test 'PowerShell test source is ASCII-safe without an encoding declaration' }
    if ($source.Contains("RedirectStandardInput = '\\.\NUL'") -and
        $source.Contains("-RedirectStandardInput '\\.\NUL'") -and
        -not $source.Contains("RedirectStandardInput = 'NUL'") -and
        -not $source.Contains("-RedirectStandardInput 'NUL'")) {
        Pass-Test 'detached launches use the absolute Windows null stream'
    }
    else { Fail-Test 'detached launches use the absolute Windows null stream' }
    if (-not $source.Contains('& $reviewerCommand') -and
        -not $source.Contains('& $launcher')) {
        Pass-Test 'batch-capable reviewer commands are never invoked through the PowerShell call operator'
    }
    else { Fail-Test 'batch-capable reviewer commands are never invoked through the PowerShell call operator' }
    $templateLines = @($source -split "`r?`n" | Where-Object { $_.Contains('$commandTemplate =') })
    $rawDynamicTemplate = @($templateLines | Where-Object {
        $_ -match '\$(reviewerCommand|reviewerArguments|Command|Arguments|Value)(?![A-Za-z0-9_])'
    })
    if ($templateLines.Count -gt 0 -and $rawDynamicTemplate.Count -eq 0) {
        Pass-Test 'cmd command templates contain no raw dynamic reviewer value interpolation'
    }
    else { Fail-Test 'cmd command templates contain no raw dynamic reviewer value interpolation' }
    $ambiguousInterpolationPattern = '\$' +
        '(?!(?:global|local|private|script|using|env|function|variable|alias):)' +
        '[A-Za-z_][A-Za-z0-9_]*:'
    if (-not [regex]::IsMatch($source, $ambiguousInterpolationPattern)) {
        Pass-Test 'interpolated variables before colons use explicit delimiters'
    }
    else { Fail-Test 'interpolated variables before colons use explicit delimiters' }
    if (-not $source.Contains(".ProviderPath.TrimEnd('\')")) {
        Pass-Test 'canonical directory resolution does not trim a Windows drive root separator'
    }
    else { Fail-Test 'canonical directory resolution does not trim a Windows drive root separator' }
    $lateRemovalMatch = [regex]::Match(
        $source, '\$lateArtifacts\s*=\s*@\(([^)]*)\)')
    $lateRemovalNames = @()
    if ($lateRemovalMatch.Success) {
        $lateRemovalNames = @([regex]::Matches(
            $lateRemovalMatch.Groups[1].Value, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value })
    }
    if ($lateRemovalNames.Count -gt 0 -and
        $lateRemovalNames[$lateRemovalNames.Count - 1] -ceq 'review-key') {
        Pass-Test 'cleanup attempts review-key removal after every validation artifact'
    }
    else { Fail-Test 'cleanup attempts review-key removal after every validation artifact' }
}

function Test-CimCreationTokenNormalization {
    $instant = [DateTime]::SpecifyKind(
        [DateTime]'2026-08-21T12:34:56', [DateTimeKind]::Utc).AddTicks(10)
    $sameSecond = $instant.AddTicks(10)
    $instantToken = ConvertTo-CimCreationToken $instant
    $sameSecondToken = ConvertTo-CimCreationToken $sameSecond
    if ($instantToken -cne $sameSecondToken) {
        Pass-Test 'CIM creation tokens preserve distinct ticks within one second'
    }
    else { Fail-Test 'CIM creation tokens preserve distinct ticks within one second' }
    $dmtfInstant = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($instant)
    Assert-Equal $instantToken (ConvertTo-CimCreationToken $dmtfInstant) 'DateTime and DMTF representations normalize to one CIM creation token'
    if ($instantToken -match '^\d+$') {
        Pass-Test 'CIM creation token is a culture-independent UTC ticks integer'
    }
    else { Fail-Test 'CIM creation token is a culture-independent UTC ticks integer' }
}

function Test-PreflightAndInvalidArguments {
    foreach ($profile in @('claude-prompt', 'codex-prompt', 'codex-review')) {
        Invoke-Runner @('check', $profile)
        Assert-Equal '0' $script:CaptureExitCode.ToString() "$profile preflight resolves cmd launcher"
    }
    $prompt = Join-Path $script:TestRoot 'valid prompt.txt'
    Write-Utf8NoBom $prompt 'valid'
    $cases = @(
        @(@('nonsense'), 64, 'unknown operation'),
        @(@('check'), 64, 'check arity'),
        @(@('check', 'claude-prompt', 'extra'), 64, 'check extra argument'),
        @(@('check', 'unknown'), 64, 'unknown profile'),
        @(@('start', 'claude-prompt', 'key', $script:TestRoot), 64, 'missing prompt'),
        @(@('start', 'claude-prompt', '', $script:TestRoot, $prompt), 64, 'empty review key'),
        @(@('start', 'claude-prompt', 'key', (Join-Path $script:TestRoot 'missing-work'), $prompt), 64, 'missing work directory'),
        @(@('start', 'claude-prompt', 'key', $script:TestRoot, (Join-Path $script:TestRoot 'missing-prompt')), 64, 'missing prompt file'),
        @(@('start', 'codex-prompt', 'key', $script:TestRoot, $prompt, 'extra'), 64, 'codex prompt extra argument'),
        @(@('start', 'codex-review', 'key', $script:TestRoot, 'uncommitted', 'extra'), 64, 'uncommitted extra'),
        @(@('start', 'codex-review', 'key', $script:TestRoot, 'base'), 64, 'base missing value'),
        @(@('start', 'codex-review', 'key', $script:TestRoot, 'commit', ''), 64, 'commit empty value'),
        @(@('start', 'codex-review', 'key', $script:TestRoot, 'base', 'bad"scope'), 64, 'scope rejects double quote'),
        @(@('start', 'codex-review', 'key', $script:TestRoot, 'base', "bad`nscope"), 64, 'scope rejects line break'),
        @(@('start', 'codex-review', 'key', $script:TestRoot, 'unknown'), 64, 'invalid review scope'),
        @(@('status'), 64, 'status arity'),
        @(@('status', 'one', 'two'), 64, 'status extra argument'),
        @(@('cancel'), 64, 'cancel arity'),
        @(@('cleanup'), 64, 'cleanup arity'),
        @(@('wait', (Join-Path $script:TestRoot 'missing'), '1'), 65, 'unknown run'),
        @(@('wait', (Join-Path $script:TestRoot 'missing'), 'invalid64'), 64, 'invalid timeout'),
        @(@('wait', (Join-Path $script:TestRoot 'missing'), '-1'), 64, 'negative timeout'),
        @(@('wait', (Join-Path $script:TestRoot 'missing'), '1', 'extra'), 64, 'wait extra argument')
    )
    foreach ($case in $cases) {
        Invoke-Runner $case[0]
        Assert-Equal $case[1].ToString() $script:CaptureExitCode.ToString() $case[2]
    }
    $savedReviewRoot = $env:SUPERARTES_REVIEW_TMPDIR
    $invalidReviewRoot = Join-Path $script:TestRoot 'review root is a file'
    Write-Utf8NoBom $invalidReviewRoot 'not a directory'
    $env:SUPERARTES_REVIEW_TMPDIR = $invalidReviewRoot
    Invoke-Runner @('--help')
    $env:SUPERARTES_REVIEW_TMPDIR = $savedReviewRoot
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'unexpected lifecycle initialization failure maps to indeterminate exit'
    $lockedPrompt = Join-Path $script:TestRoot 'locked unreadable prompt.txt'
    Write-Utf8NoBom $lockedPrompt 'locked'
    $lockedStream = [IO.File]::Open(
        $lockedPrompt, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Invoke-Runner @('start', 'claude-prompt', 'locked|prompt', $script:TestRoot, $lockedPrompt)
        Assert-Equal '64' $script:CaptureExitCode.ToString() 'existing unreadable prompt is usage error'
    }
    finally { $lockedStream.Dispose() }
}

function Test-ProfileCaptureContract {
    foreach ($profile in @('claude-prompt', 'codex-prompt', 'codex-review')) {
        Invoke-Runner @('check', $profile)
        Assert-Equal '0' $script:CaptureExitCode.ToString() "$profile explicit capture preflight succeeds"
    }
    Assert-Equal 'claude-test' ([IO.File]::ReadAllText(
        (Join-Path $script:FakeLogDirectory 'claude.preflight-version'))) 'Claude preflight receives exact version stdout'
    Assert-Equal 'codex-test' ([IO.File]::ReadAllText(
        (Join-Path $script:FakeLogDirectory 'codex.preflight-version'))) 'Codex preflight receives exact version stdout'
    Assert-Equal '--safe-mode --permission-mode --output-format --session-id --tools --allowedTools' ([IO.File]::ReadAllText(
        (Join-Path $script:FakeLogDirectory 'claude.preflight-help'))) 'Claude preflight receives exact help stdout'
    Assert-Equal '--sandbox --skip-git-repo-check --output-last-message' ([IO.File]::ReadAllText(
        (Join-Path $script:FakeLogDirectory 'codex-prompt.preflight-help'))) 'Codex prompt preflight receives exact help stdout'
    Assert-Equal '--uncommitted --base --commit --skip-git-repo-check --output-last-message' ([IO.File]::ReadAllText(
        (Join-Path $script:FakeLogDirectory 'codex-review.preflight-help'))) 'Codex review preflight receives exact help stdout'
    if (@(Get-ChildItem -LiteralPath $env:SUPERARTES_REVIEW_TMPDIR `
            -Filter '.preflight-*' -Force).Count -eq 0) {
        Pass-Test 'preflight removes every private temporary capture file'
    }
    else { Fail-Test 'preflight removes every private temporary capture file' }
}

function Test-ClaudePromptLifecycle {
    $workDirectory = Join-Path $script:TestRoot 'work directory with spaces'
    [void](New-Item -ItemType Directory -Path $workDirectory)
    $prompt = Join-Path $script:TestRoot 'unicode prompt.txt'
    $nativeJson = Join-Path $script:TestRoot 'native.json'
    $polishPrompt = -join [char[]]@(
        0x005A, 0x0061, 0x017C, 0x00F3, 0x0142, 0x0107, 0x0020,
        0x0067, 0x0119, 0x015B, 0x006C, 0x0105, 0x0020, 0x006A,
        0x0061, 0x017A, 0x0144)
    $unicodeResult = -join [char[]]@(0x017C, 0x00F3, 0x0142, 0x0077)
    Write-Utf8NoBom $prompt ($polishPrompt + "`nsecond line")
    Write-Utf8NoBom $nativeJson (
        '[{"type":"result","session_id":"native","result":"' +
        $unicodeResult + '"}]')
    $env:FAKE_NATIVE_JSON_FILE = $nativeJson
    $env:CLAUDE_CODE_USE_POWERSHELL_TOOL = 'controller-value'
    $run = Start-Review 0 @('claude-prompt', 'document|windows path|spec', $workDirectory, $prompt)
    Wait-Review $run 10 0
    $env:FAKE_NATIVE_JSON_FILE = $null
    $state = [IO.File]::ReadAllText((Join-Path $run 'state')).Trim()
    if ($state -cne 'exited') {
        $diagnosticParts = @()
        foreach ($artifact in @('supervisor-log', 'supervisor-output', 'reviewer-log')) {
            $path = Join-Path $run $artifact
            $value = '<missing>'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $value = [IO.File]::ReadAllText($path)
            }
            $diagnosticParts += "$artifact=[$value]"
        }
        $artifactNames = @(Get-ChildItem -LiteralPath $run -Force |
            Select-Object -ExpandProperty Name) -join ','
        throw "Claude lifecycle prerequisite failed: state=$state; $($diagnosticParts -join '; '); artifacts=[$artifactNames]"
    }
    Pass-Test 'Claude reaches exited'
    Assert-Equal '0' ([IO.File]::ReadAllText((Join-Path $run 'exit-code')).Trim()) 'Claude exit is retained'
    Assert-FileEqual $nativeJson (Join-Path $run 'result') 'Claude native JSON is retained byte-for-byte'
    Assert-Utf8NoBom (Join-Path $run 'review-key') 'metadata is UTF-8 without BOM'
    $session = [IO.File]::ReadAllText((Join-Path $run 'provider-session')).Trim()
    $argvPath = Join-Path $script:FakeLogDirectory "claude-$session.argv.json"
    $expected = @(
        '-p', '--safe-mode', '--permission-mode', 'dontAsk',
        '--tools', 'Read,Glob,Grep,PowerShell',
        '--allowedTools', 'Read,Glob,Grep,PowerShell(git diff *),PowerShell(git status *),PowerShell(git rev-parse *),PowerShell(git cat-file *),PowerShell(git show *),PowerShell(git log *)',
        '--output-format', 'json', '--session-id', $session
    )
    Assert-JsonArrayEqual $expected $argvPath 'Claude cmd launcher receives every fixed argument intact and in order'
    Assert-Equal '1' ([IO.File]::ReadAllText((Join-Path $script:FakeLogDirectory "claude-$session.env"))) 'Claude child alone receives PowerShell tool environment'
    Assert-Equal 'controller-value' $env:CLAUDE_CODE_USE_POWERSHELL_TOOL 'Claude child environment does not mutate controller scope'
    $env:CLAUDE_CODE_USE_POWERSHELL_TOOL = $null
    Assert-Equal $workDirectory ([IO.File]::ReadAllText((Join-Path $script:FakeLogDirectory "claude-$session.pwd"))) 'Claude work directory is exact'
    Invoke-Runner @('status', $run)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'terminal status succeeds'
    foreach ($field in @('PROFILE=', 'PROVIDER=', 'STARTED_AT=', 'ELAPSED_SECONDS=', 'RESULT=', 'REVIEWER_OUTPUT=', 'REVIEWER_LOG=', 'SUPERVISOR_OUTPUT=', 'SUPERVISOR_LOG=', 'REVIEWER_PID=', 'EXIT_CODE=', 'COMPLETED_AT=')) {
        Assert-Contains $script:CaptureOutput $field "status includes $field"
    }
    $present = @(
        'marker', 'run-path', 'review-key', 'profile', 'provider', 'run-id',
        'provider-session', 'work-dir', 'state', 'started-at', 'completed-at',
        'supervisor-pid', 'supervisor-start', 'reviewer-pid', 'reviewer-start',
        'reviewer-pgid', 'exit-code', 'prompt', 'result', 'reviewer-log',
        'supervisor-output', 'supervisor-log'
    )
    Assert-ArtifactSet $run $present @(
        'scope-kind', 'scope-value', 'previous-run', 'cancel-requested',
        'reviewer-output'
    ) 'Claude prompt'
}

function Test-ClaudeDirectOutputAndScalarExit {
    $prompt = Join-Path $script:TestRoot 'direct output prompt.txt'
    Write-Utf8NoBom $prompt 'direct output'
    $successBytes = Join-Path $script:TestRoot 'direct success bytes.json'
    [IO.File]::WriteAllBytes($successBytes, [byte[]]@(
        0x7B, 0x22, 0x72, 0x65, 0x73, 0x75, 0x6C, 0x74, 0x22, 0x3A,
        0x22, 0xE2, 0x82, 0xAC, 0x22, 0x7D, 0x0D, 0x0A))
    $env:FAKE_NATIVE_JSON_FILE = $successBytes
    $success = Start-Review 0 @(
        'claude-prompt', 'direct-output|success', $script:TestRoot, $prompt
    )
    Wait-Review $success 10 0
    $env:FAKE_NATIVE_JSON_FILE = $null
    Assert-FileEqual $successBytes (Join-Path $success 'result') 'direct Claude stdout preserves success bytes exactly'
    Assert-Equal '0' ([IO.File]::ReadAllText((Join-Path $success 'exit-code')).Trim()) 'direct Claude success records one scalar exact exit code'

    $failureBytes = Join-Path $script:TestRoot 'direct failure bytes.json'
    [IO.File]::WriteAllBytes($failureBytes, [byte[]]@(
        0x7B, 0x22, 0x70, 0x61, 0x72, 0x74, 0x69, 0x61, 0x6C, 0x22, 0x3A,
        0x74, 0x72, 0x75, 0x65, 0x7D, 0x0A))
    $env:FAKE_NATIVE_JSON_FILE = $failureBytes
    $env:FAKE_RESULT_BEFORE_EXIT = '1'
    $env:FAKE_REVIEW_EXIT = '37'
    $failure = Start-Review 0 @(
        'claude-prompt', 'direct-output|failure', $script:TestRoot, $prompt
    )
    Wait-Review $failure 10 0
    $env:FAKE_NATIVE_JSON_FILE = $null
    $env:FAKE_RESULT_BEFORE_EXIT = $null
    $env:FAKE_REVIEW_EXIT = $null
    Assert-FileEqual $failureBytes (Join-Path $failure 'result') 'direct Claude stdout preserves nonzero bytes exactly'
    Assert-Equal '37' ([IO.File]::ReadAllText((Join-Path $failure 'exit-code')).Trim()) 'direct Claude failure records one scalar exact exit code'
}

function Test-NativeExecutableDispatchParity {
    $claudeCommand = Join-Path $script:TestRoot 'bin\claude.cmd'
    $disabledCommand = Join-Path $script:TestRoot 'bin\claude.cmd.disabled'
    $nativeCommand = Join-Path $script:TestRoot 'bin\claude.exe'
    Move-Item -LiteralPath $claudeCommand -Destination $disabledCommand
    Copy-Item -LiteralPath $script:NativeReviewerPath -Destination $nativeCommand
    try {
        $prompt = Join-Path $script:TestRoot 'native executable prompt.bin'
        $stdout = Join-Path $script:TestRoot 'native executable stdout.bin'
        $stderr = Join-Path $script:TestRoot 'native executable stderr.bin'
        [IO.File]::WriteAllBytes($prompt, [byte[]]@(0x70, 0x72, 0x6F, 0x6D, 0x70, 0x74, 0x0A))
        [IO.File]::WriteAllBytes($stdout, [byte[]]@(0x7B, 0x22, 0xE2, 0x82, 0xAC, 0x22, 0x7D, 0x0D, 0x0A))
        [IO.File]::WriteAllBytes($stderr, [byte[]]@(0x6E, 0x61, 0x74, 0x69, 0x76, 0x65, 0x2D, 0x65, 0x72, 0x72, 0x0A))
        $env:FAKE_NATIVE_EXE_STDOUT_FILE = $stdout
        $env:FAKE_NATIVE_EXE_STDERR_FILE = $stderr
        $env:CLAUDE_CODE_USE_POWERSHELL_TOOL = 'native-controller'
        $run = Start-Review 0 @(
            'claude-prompt', 'native-exe|success', $script:TestRoot, $prompt
        )
        Wait-Review $run 10 0
        Assert-Equal '0' ([IO.File]::ReadAllText((Join-Path $run 'exit-code')).Trim()) 'native executable success exit is exact'
        Assert-FileEqual $stdout (Join-Path $run 'result') 'native executable stdout reaches result byte-for-byte'
        Assert-FileEqual $stderr (Join-Path $run 'reviewer-log') 'native executable stderr reaches reviewer log byte-for-byte'
        $session = [IO.File]::ReadAllText((Join-Path $run 'provider-session')).Trim()
        $logBase = Join-Path $script:FakeLogDirectory "claude-native-$session"
        Assert-FileEqual $prompt "$logBase.stdin" 'native executable receives stdin byte-for-byte'
        Assert-Equal '1' ([IO.File]::ReadAllText("$logBase.env")) 'native executable alone receives PowerShell tool environment'
        Assert-Equal $script:TestRoot ([IO.File]::ReadAllText("$logBase.pwd")) 'native executable working directory is exact'
        $actualArguments = [Text.Encoding]::UTF8.GetString(
            [IO.File]::ReadAllBytes("$logBase.argv")).Split(
                [char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries)
        $expectedArguments = @(
            '-p', '--safe-mode', '--permission-mode', 'dontAsk',
            '--tools', 'Read,Glob,Grep,PowerShell',
            '--allowedTools', 'Read,Glob,Grep,PowerShell(git diff *),PowerShell(git status *),PowerShell(git rev-parse *),PowerShell(git cat-file *),PowerShell(git show *),PowerShell(git log *)',
            '--output-format', 'json', '--session-id', $session
        )
        Assert-Equal ($expectedArguments | ConvertTo-Json -Compress) `
            ($actualArguments | ConvertTo-Json -Compress) 'native executable argv is exact and ordered'

        $env:FAKE_REVIEW_EXIT = '29'
        $failed = Start-Review 0 @(
            'claude-prompt', 'native-exe|failure', $script:TestRoot, $prompt
        )
        Wait-Review $failed 10 0
        Assert-Equal '29' ([IO.File]::ReadAllText((Join-Path $failed 'exit-code')).Trim()) 'native executable nonzero exit is exact'
        Assert-FileEqual $stdout (Join-Path $failed 'result') 'native executable nonzero stdout remains exact'
        Assert-FileEqual $stderr (Join-Path $failed 'reviewer-log') 'native executable nonzero stderr remains exact'
        $failedSession = [IO.File]::ReadAllText(
            (Join-Path $failed 'provider-session')).Trim()
        $failedLogBase = Join-Path $script:FakeLogDirectory `
            "claude-native-$failedSession"
        Assert-FileEqual $prompt "$failedLogBase.stdin" 'native executable nonzero stdin remains exact'
        Assert-Equal '1' ([IO.File]::ReadAllText("$failedLogBase.env")) 'native executable nonzero environment remains exact'
        Assert-Equal $script:TestRoot ([IO.File]::ReadAllText(
            "$failedLogBase.pwd")) 'native executable nonzero working directory remains exact'
        $failedArguments = [Text.Encoding]::UTF8.GetString(
            [IO.File]::ReadAllBytes("$failedLogBase.argv")).Split(
                [char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries)
        $expectedArguments[$expectedArguments.Count - 1] = $failedSession
        Assert-Equal ($expectedArguments | ConvertTo-Json -Compress) `
            ($failedArguments | ConvertTo-Json -Compress) 'native executable nonzero argv remains exact and ordered'
    }
    finally {
        $env:FAKE_REVIEW_EXIT = $null
        $env:FAKE_NATIVE_EXE_STDOUT_FILE = $null
        $env:FAKE_NATIVE_EXE_STDERR_FILE = $null
        $env:CLAUDE_CODE_USE_POWERSHELL_TOOL = $null
        Remove-Item -LiteralPath $nativeCommand -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $disabledCommand -Destination $claudeCommand
    }
}

function Test-SlowFailureAndPartialResults {
    $prompt = Join-Path $script:TestRoot 'slow prompt.txt'
    Write-Utf8NoBom $prompt 'slow'
    $env:FAKE_REVIEW_DELAY = '3'
    $run = Start-Review 0 @('claude-prompt', 'slow|windows', $script:TestRoot, $prompt)
    $reviewerId = [IO.File]::ReadAllText((Join-Path $run 'reviewer-pid')).Trim()
    $reviewerStart = [IO.File]::ReadAllText((Join-Path $run 'reviewer-start')).Trim()
    $supervisorId = [IO.File]::ReadAllText((Join-Path $run 'supervisor-pid')).Trim()
    $supervisorStart = [IO.File]::ReadAllText((Join-Path $run 'supervisor-start')).Trim()
    if ((Test-ProcessIdentity ([int]$reviewerId) $reviewerStart) -and
        (Test-ProcessIdentity ([int]$supervisorId) $supervisorStart)) {
        Pass-Test 'hidden supervisor and reviewer survive after start PowerShell exits'
    }
    else { Fail-Test 'hidden supervisor and reviewer survive after start PowerShell exits' }
    Wait-Review $run 1 3
    Assert-Contains $script:CaptureOutput 'STATE=running' 'slow timeout reports running'
    $liveResult = Join-Path $run 'result'
    if ((Test-Path -LiteralPath $liveResult -PathType Leaf) -and
        (Get-Item -LiteralPath $liveResult).Length -eq 0) {
        Pass-Test 'slow live reviewer retains an empty result without inferring failure'
    }
    else { Fail-Test 'slow live reviewer retains an empty result without inferring failure' }
    Wait-Review $run 10 0
    $env:FAKE_REVIEW_DELAY = $null

    $partial = Join-Path $script:TestRoot 'partial.json'
    Write-Utf8NoBom $partial '{"broken":'
    $env:FAKE_REVIEW_EXIT = '23'
    $env:FAKE_RESULT_BEFORE_EXIT = '1'
    $env:FAKE_CLAUDE_PARTIAL_FILE = $partial
    $failed = Start-Review 0 @('claude-prompt', 'failure|windows', $script:TestRoot, $prompt)
    Wait-Review $failed 10 0
    $env:FAKE_REVIEW_EXIT = $null
    $env:FAKE_RESULT_BEFORE_EXIT = $null
    $env:FAKE_CLAUDE_PARTIAL_FILE = $null
    Assert-Equal '23' ([IO.File]::ReadAllText((Join-Path $failed 'exit-code')).Trim()) 'nonzero reviewer exit is retained'
    Assert-FileEqual $partial (Join-Path $failed 'result') 'partial JSON survives failure'
}

function Test-SupervisionIdentityAndTiming {
    $prompt = Join-Path $script:TestRoot 'supervision prompt.txt'
    Write-Utf8NoBom $prompt 'supervision'
    $env:FAKE_REVIEW_DELAY = '30'
    $env:FAKE_SPAWN_CHILD = '1'
    $env:SUPERARTES_REVIEW_TEST_FORCE_IDENTITY_FAILURE = '1'
    $failed = Start-Review 0 @('claude-prompt', 'identity|forced-launch', $script:TestRoot, $prompt)
    $env:SUPERARTES_REVIEW_TEST_FORCE_IDENTITY_FAILURE = $null
    Wait-Review $failed 10 0
    Assert-Equal 'launch-failed' ([IO.File]::ReadAllText((Join-Path $failed 'state')).Trim()) 'forced reviewer identity failure is launch-failed'
    if (-not (Test-Path -LiteralPath (Join-Path $failed 'reviewer-pid'))) {
        Pass-Test 'forced identity failure never publishes reviewer identity'
    }
    else { Fail-Test 'forced identity failure never publishes reviewer identity' }
    $failedSession = [IO.File]::ReadAllText((Join-Path $failed 'provider-session')).Trim()
    $failedChildPid = Join-Path $script:FakeLogDirectory "claude-$failedSession.child-pid"
    $failedChildStart = Join-Path $script:FakeLogDirectory "claude-$failedSession.child-start"
    if ((Test-Path -LiteralPath $failedChildPid) -and (Test-Path -LiteralPath $failedChildStart)) {
        $childId = [int]([IO.File]::ReadAllText($failedChildPid).Trim())
        $childStart = [IO.File]::ReadAllText($failedChildStart).Trim()
        if (Wait-ForProcessExit $childId $childStart) { Pass-Test 'forced identity failure reaps fake reviewer descendants' }
        else { Fail-Test 'forced identity failure reaps fake reviewer descendants' }
    }
    $env:FAKE_SPAWN_CHILD = $null
    $env:FAKE_REVIEW_DELAY = $null

    $env:SUPERARTES_REVIEW_TEST_SETUP_DELAY = '2'
    $env:FAKE_REVIEW_DELAY = '1'
    $timed = Start-Review 0 @('claude-prompt', 'timing|setup-excluded', $script:TestRoot, $prompt)
    Wait-Review $timed 10 0
    $env:SUPERARTES_REVIEW_TEST_SETUP_DELAY = $null
    $env:FAKE_REVIEW_DELAY = $null
    $started = [long]([IO.File]::ReadAllText((Join-Path $timed 'started-at')).Trim())
    $completed = [long]([IO.File]::ReadAllText((Join-Path $timed 'completed-at')).Trim())
    if (($completed - $started) -le 2) { Pass-Test 'setup delay is excluded from reviewer runtime' }
    else { Fail-Test 'setup delay is excluded from reviewer runtime' }

    for ($attempt = 0; $attempt -lt 5; $attempt += 1) {
        $quick = Start-Review 0 @('claude-prompt', "status|zero-delay|$attempt", $script:TestRoot, $prompt)
        Invoke-Runner @('status', $quick)
        if ($script:CaptureExitCode -ne 4) { Pass-Test "zero-delay status $attempt is determinate" }
        else { Fail-Test "zero-delay status $attempt is determinate" }
        Wait-Review $quick 10 0
    }
}

function Test-SupervisorStdinDetached {
    $prompt = Join-Path $script:TestRoot 'stdin prompt.txt'
    Write-Utf8NoBom $prompt 'reviewer-only stdin'
    $probe = Join-Path $script:TestRoot 'supervisor-stdin-probe'
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_STDIN_PROBE = $probe
    $run = Start-Review 0 @('claude-prompt', 'supervisor|stdin-detached', $script:TestRoot, $prompt)
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_STDIN_PROBE = $null
    Wait-Review $run 10 0
    Assert-Equal '' ([IO.File]::ReadAllText($probe)) 'hidden supervisor stdin is detached'
    $session = [IO.File]::ReadAllText((Join-Path $run 'provider-session')).Trim()
    Assert-FileContains (Join-Path $script:FakeLogDirectory "claude-$session.stdin") 'reviewer-only stdin' 'reviewer inherits retained prompt independently'
}

function Test-StatusTrustOrdering {
    $prompt = Join-Path $script:TestRoot 'status prompt.txt'
    Write-Utf8NoBom $prompt 'status'
    $env:FAKE_REVIEW_DELAY = '5'
    $forged = Start-Review 0 @('claude-prompt', 'status|forged-reviewer', $script:TestRoot, $prompt)
    $realReviewerStart = [IO.File]::ReadAllText((Join-Path $forged 'reviewer-start')).Trim()
    Write-Utf8NoBom (Join-Path $forged 'reviewer-start') 'forged'
    Invoke-Runner @('status', $forged)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'forged reviewer identity makes status indeterminate'
    Write-Utf8NoBom (Join-Path $forged 'reviewer-start') $realReviewerStart
    Wait-Review $forged 10 0

    $env:FAKE_REVIEW_DELAY = '30'
    $terminalFirst = Start-Review 0 @('claude-prompt', 'status|terminal-first', $script:TestRoot, $prompt)
    Write-Utf8NoBom (Join-Path $terminalFirst 'completed-at') '1'
    Write-Utf8NoBom (Join-Path $terminalFirst 'exit-code') '0'
    Write-Utf8NoBom (Join-Path $terminalFirst 'state') 'exited'
    Invoke-Runner @('status', $terminalFirst)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'terminal metadata wins despite live recorded PID'
    Write-Utf8NoBom (Join-Path $terminalFirst 'state') 'running'
    Remove-Item -LiteralPath (Join-Path $terminalFirst 'completed-at') -Force
    Remove-Item -LiteralPath (Join-Path $terminalFirst 'exit-code') -Force
    Invoke-Runner @('cancel', $terminalFirst)
    Wait-Review $terminalFirst 10 0

    $deadSupervisor = Start-Review 0 @('claude-prompt', 'status|dead-supervisor', $script:TestRoot, $prompt)
    $supervisorPid = [int]([IO.File]::ReadAllText((Join-Path $deadSupervisor 'supervisor-pid')).Trim())
    $supervisorStart = [IO.File]::ReadAllText((Join-Path $deadSupervisor 'supervisor-start')).Trim()
    Stop-ValidatedFixtureProcess $supervisorPid $supervisorStart
    Start-Sleep -Milliseconds 300
    Invoke-Runner @('status', $deadSupervisor)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'dead supervisor with live reviewer is indeterminate'
    foreach ($artifact in @(
        'marker', 'run-path', 'review-key', 'profile', 'provider', 'run-id',
        'provider-session', 'work-dir', 'state', 'started-at',
        'supervisor-pid', 'supervisor-start', 'reviewer-pid', 'reviewer-start',
        'reviewer-pgid', 'prompt', 'result', 'reviewer-log',
        'supervisor-output', 'supervisor-log'
    )) {
        if (Test-Path -LiteralPath (Join-Path $deadSupervisor $artifact)) {
            Pass-Test "dead-supervisor diagnosis retains $artifact"
        }
        else { Fail-Test "dead-supervisor diagnosis retains $artifact" }
    }
    $deadReviewerPid = [int]([IO.File]::ReadAllText((Join-Path $deadSupervisor 'reviewer-pid')).Trim())
    $deadReviewerStart = [IO.File]::ReadAllText((Join-Path $deadSupervisor 'reviewer-start')).Trim()
    Invoke-Runner @('cancel', $deadSupervisor)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'dead-supervisor reviewer can still be cancelled by validated identity'
    if (Wait-ForProcessExit $deadReviewerPid $deadReviewerStart) { Pass-Test 'dead-supervisor cancellation leaves no reviewer root' }
    else { Fail-Test 'dead-supervisor cancellation leaves no reviewer root' }
    $env:FAKE_REVIEW_DELAY = $null
}

function Test-RemovedWorkDirectoryLaunchFailure {
    $work = Join-Path $script:TestRoot 'work removed before launch'
    [void](New-Item -ItemType Directory -Path $work)
    $prompt = Join-Path $script:TestRoot 'removed work prompt.txt'
    Write-Utf8NoBom $prompt 'removed work'
    $ready = Join-Path $script:TestRoot 'supervisor publication ready'
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_READY_FILE = $ready
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_DELAY = '3'
    $output = Join-Path $script:TestRoot 'removed-work.out'
    $errorOutput = Join-Path $script:TestRoot 'removed-work.err'
    $process = Start-RunnerCapture $RunnerPath @(
        'start', 'claude-prompt', 'launch|removed-work', $work, $prompt
    ) $output $errorOutput
    Require-File $ready 'removed-work fixture reaches delayed supervisor publication'
    Remove-Item -LiteralPath $work -Force
    $process.WaitForExit()
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_READY_FILE = $null
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_DELAY = $null
    $text = [IO.File]::ReadAllText($output) + [IO.File]::ReadAllText($errorOutput)
    $run = ''
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.StartsWith('RUN_DIR=')) { $run = $line.Substring(8) }
    }
    Assert-Equal 'launch-failed' ([IO.File]::ReadAllText((Join-Path $run 'state')).Trim()) 'removed work directory becomes launch-failed'
}

function Test-HiddenSupervisorLaunchException {
    $prompt = Join-Path $script:TestRoot 'supervisor launch exception prompt.txt'
    Write-Utf8NoBom $prompt 'supervisor launch exception'
    $env:SUPERARTES_REVIEW_TEST_FORCE_SUPERVISOR_START_EXCEPTION = '1'
    Invoke-Runner @(
        'start', 'claude-prompt', 'launch|supervisor-exception', $script:TestRoot, $prompt
    )
    $env:SUPERARTES_REVIEW_TEST_FORCE_SUPERVISOR_START_EXCEPTION = $null
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'hidden supervisor Start-Process exception is an accepted lifecycle result'
    Assert-Contains $script:CaptureOutput 'STATE=launch-failed' 'hidden supervisor exception prints launch-failed state'
    $run = Get-OutputField 'RUN_DIR'
    $runId = Get-OutputField 'RUN_ID'
    if ($run.Length -gt 0 -and $runId.Length -gt 0) {
        Pass-Test 'hidden supervisor exception prints run directory and run identifier'
    }
    else { Fail-Test 'hidden supervisor exception prints run directory and run identifier' }
    Assert-Equal 'launch-failed' ([IO.File]::ReadAllText((Join-Path $run 'state')).Trim()) 'hidden supervisor exception retains launch-failed state'
    Assert-FileContains (Join-Path $run 'supervisor-log') 'Could not start hidden supervisor:' 'hidden supervisor exception retains diagnostic'
    if ((Test-Path -LiteralPath (Join-Path $run 'completed-at') -PathType Leaf) -and
        (Get-Item -LiteralPath (Join-Path $run 'completed-at')).Length -gt 0) {
        Pass-Test 'hidden supervisor exception records completion evidence'
    }
    else { Fail-Test 'hidden supervisor exception records completion evidence' }
    if (-not (Test-Path -LiteralPath (Join-Path $env:SUPERARTES_REVIEW_TMPDIR '.registry-lock'))) {
        Pass-Test 'hidden supervisor exception releases the creator registry lock'
    }
    else { Fail-Test 'hidden supervisor exception releases the creator registry lock' }
    $retry = Start-Review 0 @(
        '--after-terminal', $run, 'claude-prompt', 'launch|supervisor-exception',
        $script:TestRoot, $prompt
    )
    Wait-Review $retry 10 0
    Assert-Equal $run ([IO.File]::ReadAllText((Join-Path $retry 'previous-run')).Trim()) 'linked retry follows hidden supervisor launch failure'
}

function Test-CodexProfiles {
    $prompt = Join-Path $script:TestRoot 'codex prompt.txt'
    Write-Utf8NoBom $prompt 'codex input'
    $run = Start-Review 0 @('codex-prompt', 'codex|prompt', $script:TestRoot, $prompt)
    Wait-Review $run 10 0
    $logBase = Join-Path $script:FakeLogDirectory ("codex-" + (Split-Path $run -Leaf))
    Assert-JsonArrayEqual @(
        'exec', '-', '-s', 'read-only', '--skip-git-repo-check', '-o',
        (Join-Path $run 'result')
    ) "$logBase.argv.json" 'Codex prompt cmd launcher receives exact ordered arguments'
    Assert-FileContains "$logBase.stdin" 'codex input' 'Codex prompt reaches stdin'
    Assert-Equal '' ([IO.File]::ReadAllText("$logBase.env")) 'Codex prompt does not inherit Claude-only environment'
    Assert-FileContains (Join-Path $run 'result') 'fake Codex review' 'Codex native prompt result is retained'
    Assert-ArtifactSet $run @(
        'marker', 'run-path', 'review-key', 'profile', 'provider', 'run-id',
        'provider-session', 'work-dir', 'state', 'started-at', 'completed-at',
        'supervisor-pid', 'supervisor-start', 'reviewer-pid', 'reviewer-start',
        'reviewer-pgid', 'exit-code', 'prompt', 'result', 'reviewer-output',
        'reviewer-log', 'supervisor-output', 'supervisor-log'
    ) @('scope-kind', 'scope-value', 'previous-run', 'cancel-requested') 'Codex prompt'
    foreach ($scope in @(
        @('uncommitted'),
        @('base', 'feature & echo INJECTED | less-than< greater-than> caret^ percent%PATH% (group)'),
        @('commit', '0123456789abcdef0123456789abcdef01234567')
    )) {
        $review = Start-Review 0 (@('codex-review', "codex|$($scope[0])", $script:TestRoot) + $scope)
        Wait-Review $review 10 0
        $reviewLog = Join-Path $script:FakeLogDirectory ("codex-" + (Split-Path $review -Leaf) + '.argv.json')
        $expected = @('exec', 'review', ("--" + $scope[0]))
        if ($scope[0] -cne 'uncommitted') { $expected += $scope[1] }
        $expected += @('--skip-git-repo-check', '-o', (Join-Path $review 'result'))
        Assert-JsonArrayEqual $expected $reviewLog "Codex $($scope[0]) cmd launcher receives exact ordered arguments"
        Assert-Equal '' ([IO.File]::ReadAllText(($reviewLog -replace '\.argv\.json$', '.env'))) "Codex $($scope[0]) does not inherit Claude-only environment"
        $argumentText = [IO.File]::ReadAllText($reviewLog)
        if (-not $argumentText.Contains('--sandbox') -and -not $argumentText.Contains('read-only')) {
            Pass-Test "Codex $($scope[0]) review has no prompt sandbox arguments"
        }
        else { Fail-Test "Codex $($scope[0]) review has no prompt sandbox arguments" }
        if (-not (Test-Path -LiteralPath ($reviewLog -replace '\.argv\.json$', '.stdin'))) {
            Pass-Test "Codex $($scope[0]) review has no stdin"
        }
        else { Fail-Test "Codex $($scope[0]) review has no stdin" }
        Assert-FileContains (Join-Path $review 'result') 'fake Codex review' "Codex $($scope[0]) native result is retained"
        Assert-ArtifactSet $review @(
            'marker', 'run-path', 'review-key', 'profile', 'provider', 'run-id',
            'provider-session', 'work-dir', 'scope-kind', 'scope-value', 'state',
            'started-at', 'completed-at', 'supervisor-pid', 'supervisor-start',
            'reviewer-pid', 'reviewer-start', 'reviewer-pgid', 'exit-code',
            'result', 'reviewer-output', 'reviewer-log', 'supervisor-output',
            'supervisor-log'
        ) @('prompt', 'previous-run', 'cancel-requested') "Codex $($scope[0]) review"
    }

    $injectionMarker = Join-Path $script:TestRoot 'cmd-injection-marker'
    $injectionPayload = 'feature&echo.injected>%SUPERARTES_REVIEW_INJECTION_MARKER%|%PATH%'
    $env:SUPERARTES_REVIEW_INJECTION_MARKER = $injectionMarker
    $adversarial = Start-Review 0 @(
        'codex-review', 'codex|base|adversarial', $script:TestRoot, 'base', $injectionPayload
    )
    Wait-Review $adversarial 10 0
    $adversarialLog = Join-Path $script:FakeLogDirectory (
        'codex-' + (Split-Path $adversarial -Leaf) + '.argv.json')
    Assert-JsonArrayEqual @(
        'exec', 'review', '--base', $injectionPayload,
        '--skip-git-repo-check', '-o', (Join-Path $adversarial 'result')
    ) $adversarialLog 'cmd launcher preserves adversarial metacharacter payload as one exact argument'
    if (-not (Test-Path -LiteralPath $injectionMarker)) {
        Pass-Test 'cmd launcher adversarial argument creates no injection marker'
    }
    else { Fail-Test 'cmd launcher adversarial argument creates no injection marker' }
    $env:SUPERARTES_REVIEW_INJECTION_MARKER = $null
}

function Test-ExactKeyAndChain {
    $prompt = Join-Path $script:TestRoot 'chain prompt.txt'
    Write-Utf8NoBom $prompt 'chain'
    $first = Start-Review 0 @('claude-prompt', 'same|key', $script:TestRoot, $prompt)
    Wait-Review $first 10 0
    Invoke-Runner @('start', 'claude-prompt', 'same|key', $script:TestRoot, $prompt)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'terminal exact key requires explicit chaining'
    Assert-Equal $first (Get-OutputField 'RUN_DIR') 'duplicate identifies unique tail'
    $second = Start-Review 0 @('--after-terminal', $first, 'claude-prompt', 'same|key', $script:TestRoot, $prompt)
    Wait-Review $second 10 0
    Assert-Equal $first ([IO.File]::ReadAllText((Join-Path $second 'previous-run')).Trim()) 'linked retry records previous tail'
    $distinct = Start-Review 0 @('claude-prompt', 'same|key|suffix', $script:TestRoot, $prompt)
    Wait-Review $distinct 10 0
}

function Test-ChainTailAndCorruptionMatrix {
    $prompt = Join-Path $script:TestRoot 'chain matrix prompt.txt'
    Write-Utf8NoBom $prompt 'chain matrix'
    $first = Start-Review 0 @('claude-prompt', 'chain|matrix', $script:TestRoot, $prompt)
    Wait-Review $first 10 0
    $env:FAKE_REVIEW_DELAY = '4'
    $second = Start-Review 0 @('--after-terminal', $first, 'claude-prompt', 'chain|matrix', $script:TestRoot, $prompt)
    Invoke-Runner @('start', 'claude-prompt', 'chain|matrix', $script:TestRoot, $prompt)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'attempt two live is returned as outstanding'
    Assert-Equal $second (Get-OutputField 'RUN_DIR') 'attempt two live is the returned chain member'
    Invoke-Runner @('start', '--after-terminal', $first, 'claude-prompt', 'chain|matrix', $script:TestRoot, $prompt)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'earlier terminal is rejected as retry predecessor'
    Wait-Review $second 10 0
    $env:FAKE_REVIEW_DELAY = $null

    $other = Start-Review 0 @('claude-prompt', 'chain|other-key', $script:TestRoot, $prompt)
    Wait-Review $other 10 0
    Invoke-Runner @('start', '--after-terminal', $other, 'claude-prompt', 'chain|matrix', $script:TestRoot, $prompt)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'wrong-key predecessor is rejected'

    $liveKey = 'chain|multiple-live'
    $env:FAKE_REVIEW_DELAY = '30'
    $live = Start-Review 0 @('claude-prompt', $liveKey, $script:TestRoot, $prompt)
    $liveClone = Copy-RunFixture $live 'multiple-live'
    Write-Utf8NoBom (Join-Path $liveClone 'review-key') $liveKey
    Invoke-Runner @('start', 'claude-prompt', $liveKey, $script:TestRoot, $prompt)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'multiple nonterminal matches are corruption'
    Assert-Contains $script:CaptureOutput $live 'multiple-nonterminal diagnostic lists real live run'
    Assert-Contains $script:CaptureOutput $liveClone 'multiple-nonterminal diagnostic lists synthetic live run'
    Remove-Item -LiteralPath $liveClone -Recurse -Force
    Invoke-Runner @('cancel', $live)
    Wait-Review $live 10 0
    $env:FAKE_REVIEW_DELAY = $null

    $tailKey = 'chain|multiple-terminal-tails'
    $tailOne = Start-Review 0 @('claude-prompt', $tailKey, $script:TestRoot, $prompt)
    Wait-Review $tailOne 10 0
    $tailTwo = Copy-RunFixture $tailOne 'tail-two'
    Write-Utf8NoBom (Join-Path $tailTwo 'review-key') $tailKey
    Remove-Item -LiteralPath (Join-Path $tailTwo 'previous-run') -Force -ErrorAction SilentlyContinue
    Invoke-Runner @('start', 'claude-prompt', $tailKey, $script:TestRoot, $prompt)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'multiple terminal tails are corruption'
    Assert-Contains $script:CaptureOutput $tailOne 'multiple-tail diagnostic lists first tail'
    Assert-Contains $script:CaptureOutput $tailTwo 'multiple-tail diagnostic lists second tail'

    $cycleKey = 'chain|zero-terminal-tails'
    $cycleOne = Start-Review 0 @('claude-prompt', $cycleKey, $script:TestRoot, $prompt)
    Wait-Review $cycleOne 10 0
    $cycleTwo = Copy-RunFixture $cycleOne 'cycle-two'
    Write-Utf8NoBom (Join-Path $cycleTwo 'review-key') $cycleKey
    Write-Utf8NoBom (Join-Path $cycleOne 'previous-run') $cycleTwo
    Write-Utf8NoBom (Join-Path $cycleTwo 'previous-run') $cycleOne
    Invoke-Runner @('start', 'claude-prompt', $cycleKey, $script:TestRoot, $prompt)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'zero terminal tails are corruption'
    Assert-Contains $script:CaptureOutput $cycleOne 'zero-tail diagnostic lists first cycle member'
    Assert-Contains $script:CaptureOutput $cycleTwo 'zero-tail diagnostic lists second cycle member'
}

function Test-LiveExactKeyAndDistinctConcurrency {
    $prompt = Join-Path $script:TestRoot 'concurrency prompt.txt'
    Write-Utf8NoBom $prompt 'concurrency'
    $env:FAKE_REVIEW_DELAY = '4'
    $first = Start-Review 0 @('claude-prompt', 'concurrent|same', $script:TestRoot, $prompt)
    Invoke-Runner @('start', 'claude-prompt', 'concurrent|same', $script:TestRoot, $prompt)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'live exact-key duplicate attaches instead of launching'
    Assert-Equal $first (Get-OutputField 'RUN_DIR') 'live duplicate returns sole matching run'
    $second = Start-Review 0 @('claude-prompt', 'concurrent|different', $script:TestRoot, $prompt)
    $firstPid = [IO.File]::ReadAllText((Join-Path $first 'reviewer-pid')).Trim()
    $secondPid = [IO.File]::ReadAllText((Join-Path $second 'reviewer-pid')).Trim()
    if ($firstPid -cne $secondPid) { Pass-Test 'distinct keys run concurrently' }
    else { Fail-Test 'distinct keys run concurrently' }
    $firstSession = [IO.File]::ReadAllText((Join-Path $first 'provider-session')).Trim()
    $secondSession = [IO.File]::ReadAllText((Join-Path $second 'provider-session')).Trim()
    if ($firstSession -cne $secondSession -and
        (Test-Path -LiteralPath (Join-Path $script:FakeLogDirectory "claude-$firstSession.argv.json")) -and
        (Test-Path -LiteralPath (Join-Path $script:FakeLogDirectory "claude-$secondSession.argv.json"))) {
        Pass-Test 'distinct keys retain separate reviewer logs'
    }
    else { Fail-Test 'distinct keys retain separate reviewer logs' }
    Wait-Review $first 10 0
    Wait-Review $second 10 0
    $env:FAKE_REVIEW_DELAY = $null
}

function Test-SimultaneousSameKeySerialization {
    $prompt = Join-Path $script:TestRoot 'simultaneous prompt.txt'
    Write-Utf8NoBom $prompt 'simultaneous'
    $env:FAKE_REVIEW_DELAY = '3'
    $outputs = @(
        (Join-Path $script:TestRoot 'simultaneous-one.out'),
        (Join-Path $script:TestRoot 'simultaneous-two.out')
    )
    $errors = @(
        (Join-Path $script:TestRoot 'simultaneous-one.err'),
        (Join-Path $script:TestRoot 'simultaneous-two.err')
    )
    $one = Start-RunnerCapture $RunnerPath @('start', 'claude-prompt', 'simultaneous|same-key', $script:TestRoot, $prompt) $outputs[0] $errors[0]
    $two = Start-RunnerCapture $RunnerPath @('start', 'claude-prompt', 'simultaneous|same-key', $script:TestRoot, $prompt) $outputs[1] $errors[1]
    $one.WaitForExit()
    $two.WaitForExit()
    $codes = @($one.ExitCode, $two.ExitCode) | Sort-Object
    Assert-Equal '0,12' (($codes | ForEach-Object { $_.ToString() }) -join ',') 'simultaneous same-key starts yield one launch and one attach'
    $runs = @()
    foreach ($output in $outputs) {
        $runs += Get-FieldFromText ([IO.File]::ReadAllText($output)) 'RUN_DIR'
    }
    Assert-Equal $runs[0] $runs[1] 'simultaneous same-key starts identify one run'
    Wait-Review $runs[0] 10 0
    $env:FAKE_REVIEW_DELAY = $null
}

function Test-CreatorSupervisorHandoff {
    $prompt = Join-Path $script:TestRoot 'handoff prompt.txt'
    Write-Utf8NoBom $prompt 'handoff'

    $preCommitPause = Join-Path $script:TestRoot 'pause-before-review-key'
    $env:SUPERARTES_REVIEW_TEST_PRE_REVIEW_KEY_PAUSE_FILE = $preCommitPause
    $preCommitOut = Join-Path $script:TestRoot 'precommit.out'
    $preCommitErr = Join-Path $script:TestRoot 'precommit.err'
    $preCommit = Start-RunnerCapture $RunnerPath @('start', 'claude-prompt', 'handoff|precommit', $script:TestRoot, $prompt) $preCommitOut $preCommitErr
    Require-File $preCommitPause 'creator reaches pre-review-key checkpoint'
    Stop-CapturedFixtureProcess $preCommit
    Remove-Item -LiteralPath $preCommitPause -Force -ErrorAction SilentlyContinue
    $env:SUPERARTES_REVIEW_TEST_PRE_REVIEW_KEY_PAUSE_FILE = $null
    $orphan = @(Get-ChildItem -LiteralPath $env:SUPERARTES_REVIEW_TMPDIR -Directory -Filter 'run-*' | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'run-id')) -and
        -not (Test-Path -LiteralPath (Join-Path $_.FullName 'review-key'))
    })[-1].FullName
    $orphanEvidence = @{}
    foreach ($artifact in @(
        'marker', 'run-path', 'profile', 'provider', 'run-id',
        'provider-session', 'work-dir', 'prompt'
    )) {
        $artifactPath = Join-Path $orphan $artifact
        if (Test-Path -LiteralPath $artifactPath -PathType Leaf) {
            Pass-Test "pre-review-key orphan retains $artifact"
            $orphanEvidence[$artifact] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($artifactPath))
        }
        else { Fail-Test "pre-review-key orphan retains $artifact" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $orphan 'review-key'))) {
        Pass-Test 'pre-review-key orphan has no commit marker'
    }
    else { Fail-Test 'pre-review-key orphan has no commit marker' }
    $replacement = Start-Review 0 @('claude-prompt', 'handoff|precommit', $script:TestRoot, $prompt)
    Wait-Review $replacement 10 0
    if (-not $replacement.Equals($orphan, [StringComparison]::OrdinalIgnoreCase)) {
        Pass-Test 'pre-review-key replacement is a distinct run'
    }
    else { Fail-Test 'pre-review-key replacement is a distinct run' }
    foreach ($artifact in $orphanEvidence.Keys) {
        Assert-Equal $orphanEvidence[$artifact] ([Convert]::ToBase64String(
            [IO.File]::ReadAllBytes((Join-Path $orphan $artifact)))) "replacement leaves orphan $artifact untouched"
    }
    $published = @(Get-ChildItem -LiteralPath $env:SUPERARTES_REVIEW_TMPDIR -Directory -Filter 'run-*' | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'review-key')) -and
        ([IO.File]::ReadAllText((Join-Path $_.FullName 'review-key')).Trim() -ceq 'handoff|precommit')
    })
    Assert-Equal '1' $published.Count.ToString() 'precommit creator death leaves no published duplicate'

    $preLaunchPause = Join-Path $script:TestRoot 'pause-before-launch'
    $env:SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE = $preLaunchPause
    $preLaunchOut = Join-Path $script:TestRoot 'prelaunch.out'
    $preLaunchErr = Join-Path $script:TestRoot 'prelaunch.err'
    $preLaunch = Start-RunnerCapture $RunnerPath @('start', 'claude-prompt', 'handoff|prelaunch', $script:TestRoot, $prompt) $preLaunchOut $preLaunchErr
    Require-File $preLaunchPause 'creator reaches committed prelaunch checkpoint'
    $preLaunchRun = @(Get-ChildItem -LiteralPath $env:SUPERARTES_REVIEW_TMPDIR -Directory -Filter 'run-*' | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'review-key')) -and
        ([IO.File]::ReadAllText((Join-Path $_.FullName 'review-key')).Trim() -ceq 'handoff|prelaunch')
    })[0].FullName
    Stop-CapturedFixtureProcess $preLaunch
    Remove-Item -LiteralPath $preLaunchPause -Force -ErrorAction SilentlyContinue
    $env:SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE = $null
    Invoke-Runner @('start', 'claude-prompt', 'handoff|prelaunch', $script:TestRoot, $prompt)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'committed prelaunch creator death is repaired and retained'
    Assert-Equal 'launch-failed' ([IO.File]::ReadAllText((Join-Path $preLaunchRun 'state')).Trim()) 'committed prelaunch death becomes launch-failed'
    Assert-FileContains (Join-Path $preLaunchRun 'supervisor-log') 'Reconciled abandoned pre-launch run after registry owner death' 'prelaunch repair records diagnostic'
    if ((Test-Path -LiteralPath (Join-Path $preLaunchRun 'completed-at') -PathType Leaf) -and
        (Get-Item -LiteralPath (Join-Path $preLaunchRun 'completed-at')).Length -gt 0) {
        Pass-Test 'prelaunch repair records completion evidence'
    }
    else { Fail-Test 'prelaunch repair records completion evidence' }
    $preLaunchRetry = Start-Review 0 @('--after-terminal', $preLaunchRun, 'claude-prompt', 'handoff|prelaunch', $script:TestRoot, $prompt)
    Wait-Review $preLaunchRetry 10 0
    Assert-Equal $preLaunchRun ([IO.File]::ReadAllText((Join-Path $preLaunchRetry 'previous-run')).Trim()) 'prelaunch linked retry succeeds against repaired tail'

    $intentPause = Join-Path $script:TestRoot 'pause-after-intent'
    $env:SUPERARTES_REVIEW_TEST_POST_INTENT_PAUSE_FILE = $intentPause
    $env:SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS = '0'
    $intentOut = Join-Path $script:TestRoot 'intent.out'
    $intentErr = Join-Path $script:TestRoot 'intent.err'
    $intent = Start-RunnerCapture $RunnerPath @('start', 'claude-prompt', 'handoff|intent', $script:TestRoot, $prompt) $intentOut $intentErr
    Require-File $intentPause 'creator reaches launch-intent checkpoint'
    Stop-CapturedFixtureProcess $intent
    Remove-Item -LiteralPath $intentPause -Force -ErrorAction SilentlyContinue
    $env:SUPERARTES_REVIEW_TEST_POST_INTENT_PAUSE_FILE = $null
    Invoke-Runner @('start', 'claude-prompt', 'handoff|intent', $script:TestRoot, $prompt)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'abandoned launch intent is fenced as outstanding terminal evidence'
    $intentRun = Get-OutputField 'RUN_DIR'
    Assert-Equal 'launch-failed' ([IO.File]::ReadAllText((Join-Path $intentRun 'state')).Trim()) 'launch intent guard records launch-failed'
    Assert-FileContains (Join-Path $intentRun 'supervisor-log') 'Reconciled launch intent without supervisor publication' 'launch intent guard records diagnostic'
    if ((Test-Path -LiteralPath (Join-Path $intentRun 'completed-at') -PathType Leaf) -and
        (Get-Item -LiteralPath (Join-Path $intentRun 'completed-at')).Length -gt 0) {
        Pass-Test 'launch intent guard records completion evidence'
    }
    else { Fail-Test 'launch intent guard records completion evidence' }
    $intentRetry = Start-Review 0 @('--after-terminal', $intentRun, 'claude-prompt', 'handoff|intent', $script:TestRoot, $prompt)
    Wait-Review $intentRetry 10 0
    Assert-Equal $intentRun ([IO.File]::ReadAllText((Join-Path $intentRetry 'previous-run')).Trim()) 'launch intent linked retry succeeds'
    $env:SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS = $null
}

function Test-DelayedSupervisorPublicationAndLateFence {
    $prompt = Join-Path $script:TestRoot 'publication prompt.txt'
    Write-Utf8NoBom $prompt 'publication'
    $env:FAKE_REVIEW_DELAY = '2'
    $publicationCountBefore = @(Get-ChildItem -LiteralPath $script:FakeLogDirectory -Filter 'claude-*.argv.json').Count
    $publicationReady = Join-Path $script:TestRoot 'publication-ready'
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_READY_FILE = $publicationReady
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_DELAY = '2'
    $env:SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS = '5'
    $out = Join-Path $script:TestRoot 'publication.out'
    $err = Join-Path $script:TestRoot 'publication.err'
    $creator = Start-RunnerCapture $RunnerPath @('start', 'claude-prompt', 'handoff|publication-wins', $script:TestRoot, $prompt) $out $err
    Require-File $publicationReady 'delayed supervisor publishes identity before registry claim delay'
    $publicationRun = @(Get-ChildItem -LiteralPath $env:SUPERARTES_REVIEW_TMPDIR -Directory -Filter 'run-*' | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'review-key')) -and
        ([IO.File]::ReadAllText((Join-Path $_.FullName 'review-key')).Trim() -ceq 'handoff|publication-wins')
    })[0].FullName
    $publicationSupervisorPid = [int]([IO.File]::ReadAllText((Join-Path $publicationRun 'supervisor-pid')).Trim())
    $publicationSupervisorStart = [IO.File]::ReadAllText((Join-Path $publicationRun 'supervisor-start')).Trim()
    if (Test-ProcessIdentity $publicationSupervisorPid $publicationSupervisorStart) {
        Pass-Test 'delayed supervisor identity is live and visible'
    }
    else { Fail-Test 'delayed supervisor identity is live and visible' }
    Invoke-Runner @('start', 'claude-prompt', 'handoff|publication-wins', $script:TestRoot, $prompt)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'duplicate waits for delayed supervisor publication and attaches'
    $run = Get-OutputField 'RUN_DIR'
    Assert-Equal $publicationRun $run 'delayed publication competitor returns original run'
    $creator.WaitForExit()
    Wait-Review $run 10 0
    $publicationSession = [IO.File]::ReadAllText((Join-Path $run 'provider-session')).Trim()
    if (Test-Path -LiteralPath (Join-Path $script:FakeLogDirectory "claude-$publicationSession.argv.json")) {
        Pass-Test 'delayed publication retains one per-run reviewer invocation log'
    }
    else { Fail-Test 'delayed publication retains one per-run reviewer invocation log' }
    $publicationCountAfter = @(Get-ChildItem -LiteralPath $script:FakeLogDirectory -Filter 'claude-*.argv.json').Count
    Assert-Equal ($publicationCountBefore + 1).ToString() $publicationCountAfter.ToString() 'delayed publication launches exactly one reviewer'
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_READY_FILE = $null
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_DELAY = $null

    $lateCountBefore = @(Get-ChildItem -LiteralPath $script:FakeLogDirectory -Filter 'claude-*.argv.json').Count
    $lateReady = Join-Path $script:TestRoot 'late-ready'
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_START_DELAY = '3'
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_START_READY_FILE = $lateReady
    $env:SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS = '0'
    $lateOut = Join-Path $script:TestRoot 'late-fence.out'
    $lateErr = Join-Path $script:TestRoot 'late-fence.err'
    $late = Start-RunnerCapture $RunnerPath @('start', 'claude-prompt', 'handoff|guard-wins', $script:TestRoot, $prompt) $lateOut $lateErr
    Require-File $lateReady 'late supervisor reaches deterministic pre-initialization fence'
    Invoke-Runner @('start', 'claude-prompt', 'handoff|guard-wins', $script:TestRoot, $prompt)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'publication guard establishes one terminal attempt'
    $lateRun = Get-OutputField 'RUN_DIR'
    $lateRetry = Start-Review 0 @('--after-terminal', $lateRun, 'claude-prompt', 'handoff|guard-wins', $script:TestRoot, $prompt)
    Wait-Review $lateRetry 10 0
    $late.WaitForExit()
    Start-Sleep -Seconds 4
    Assert-Equal 'launch-failed' ([IO.File]::ReadAllText((Join-Path $lateRun 'state')).Trim()) 'late supervisor fence cannot revive launch-failed run'
    if (-not (Test-Path -LiteralPath (Join-Path $lateRun 'reviewer-pid'))) {
        Pass-Test 'late supervisor fence launches no duplicate reviewer'
    }
    else { Fail-Test 'late supervisor fence launches no duplicate reviewer' }
    $lateOriginalSession = [IO.File]::ReadAllText((Join-Path $lateRun 'provider-session')).Trim()
    if (-not (Test-Path -LiteralPath (Join-Path $script:FakeLogDirectory "claude-$lateOriginalSession.argv.json"))) {
        Pass-Test 'late original supervisor produces no reviewer invocation log'
    }
    else { Fail-Test 'late original supervisor produces no reviewer invocation log' }
    $lateRetrySession = [IO.File]::ReadAllText((Join-Path $lateRetry 'provider-session')).Trim()
    if (Test-Path -LiteralPath (Join-Path $script:FakeLogDirectory "claude-$lateRetrySession.argv.json")) {
        Pass-Test 'late-fence linked retry retains its one reviewer invocation log'
    }
    else { Fail-Test 'late-fence linked retry retains its one reviewer invocation log' }
    $lateCountAfter = @(Get-ChildItem -LiteralPath $script:FakeLogDirectory -Filter 'claude-*.argv.json').Count
    Assert-Equal ($lateCountBefore + 1).ToString() $lateCountAfter.ToString() 'late supervisor plus linked retry launches exactly one reviewer'
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_START_DELAY = $null
    $env:SUPERARTES_REVIEW_TEST_SUPERVISOR_START_READY_FILE = $null
    $env:SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS = $null
    $env:FAKE_REVIEW_DELAY = $null
}

function Test-ReparseEvidenceWriteSafety {
    $prompt = Join-Path $script:TestRoot 'unsafe evidence prompt.txt'
    Write-Utf8NoBom $prompt 'unsafe evidence'
    $pause = Join-Path $script:TestRoot 'unsafe-evidence-prelaunch-pause'
    $env:SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE = $pause
    $output = Join-Path $script:TestRoot 'unsafe-evidence.out'
    $errorOutput = Join-Path $script:TestRoot 'unsafe-evidence.err'
    $creator = Start-RunnerCapture $RunnerPath @(
        'start', 'claude-prompt', 'evidence|supervisor-log-reparse', $script:TestRoot, $prompt
    ) $output $errorOutput
    Require-File $pause 'unsafe-evidence fixture reaches committed prelaunch checkpoint'
    $run = @(Get-ChildItem -LiteralPath $env:SUPERARTES_REVIEW_TMPDIR -Directory -Filter 'run-*' | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'review-key')) -and
        ([IO.File]::ReadAllText((Join-Path $_.FullName 'review-key')).Trim() -ceq 'evidence|supervisor-log-reparse')
    })[0].FullName
    Stop-CapturedFixtureProcess $creator
    Remove-Item -LiteralPath $pause -Force -ErrorAction SilentlyContinue
    $env:SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE = $null

    $outside = Join-Path $script:TestRoot 'outside supervisor log target'
    [void](New-Item -ItemType Directory -Path $outside)
    Write-Utf8NoBom (Join-Path $outside 'sentinel') 'outside supervisor evidence preserved'
    $unsafeLog = Join-Path $run 'supervisor-log'
    New-RequiredJunction $unsafeLog $outside
    Invoke-Runner @('start', 'claude-prompt', 'evidence|supervisor-log-reparse', $script:TestRoot, $prompt)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'reconciliation terminalizes run without writing through supervisor-log reparse point'
    Assert-Contains $script:CaptureOutput 'Unsafe supervisor log; diagnostic was not written:' 'unsafe supervisor log is reported externally'
    Assert-Equal 'launch-failed' ([IO.File]::ReadAllText((Join-Path $run 'state')).Trim()) 'unsafe supervisor log reconciliation still records safe launch-failed state'
    if ((Test-Path -LiteralPath (Join-Path $run 'completed-at') -PathType Leaf) -and
        (Get-Item -LiteralPath (Join-Path $run 'completed-at')).Length -gt 0) {
        Pass-Test 'unsafe supervisor log reconciliation records safe completion evidence'
    }
    else { Fail-Test 'unsafe supervisor log reconciliation records safe completion evidence' }
    Assert-FileContains (Join-Path $outside 'sentinel') 'outside supervisor evidence preserved' 'supervisor-log reparse point preserves outside sentinel'
    [IO.Directory]::Delete($unsafeLog, $false)
    $retry = Start-Review 0 @('--after-terminal', $run, 'claude-prompt', 'evidence|supervisor-log-reparse', $script:TestRoot, $prompt)
    Wait-Review $retry 10 0
}

function Test-RegistryLockRecovery {
    $prompt = Join-Path $script:TestRoot 'registry prompt.txt'
    Write-Utf8NoBom $prompt 'registry'
    $lock = Join-Path $env:SUPERARTES_REVIEW_TMPDIR '.registry-lock'
    [void](New-Item -ItemType Directory -Path $lock)
    Write-Utf8NoBom (Join-Path $lock 'owner-pid') '99999999'
    Write-Utf8NoBom (Join-Path $lock 'owner-start') '1'
    $recovered = Start-Review 0 @('claude-prompt', 'registry|stale', $script:TestRoot, $prompt)
    Assert-Contains $script:CaptureOutput 'Reclaimed stale registry lock:' 'dead registry owner recovery is diagnosed'
    Wait-Review $recovered 10 0
    if (-not (Test-Path -LiteralPath $lock)) { Pass-Test 'dead registry owner is reclaimed' }
    else { Fail-Test 'dead registry owner is reclaimed' }

    [void](New-Item -ItemType Directory -Path $lock)
    Invoke-Runner @('start', 'claude-prompt', 'registry|malformed', $script:TestRoot, $prompt)
    Assert-Equal '75' $script:CaptureExitCode.ToString() 'malformed registry owner fails closed'
    if (Test-Path -LiteralPath $lock -PathType Container) { Pass-Test 'malformed registry lock is retained' }
    else { Fail-Test 'malformed registry lock is retained' }
    Remove-Item -LiteralPath $lock -Force

    [void](New-Item -ItemType Directory -Path $lock)
    Write-Utf8NoBom (Join-Path $lock 'owner-pid') $PID.ToString()
    Write-Utf8NoBom (Join-Path $lock 'owner-start') '1'
    $wrongStart = Start-Review 0 @('claude-prompt', 'registry|current-wrong-start', $script:TestRoot, $prompt)
    Wait-Review $wrongStart 10 0
    Pass-Test 'current PID with wrong start token is reclaimed'

    [void](New-Item -ItemType Directory -Path $lock)
    Write-Utf8NoBom (Join-Path $lock 'owner-pid') $PID.ToString()
    Write-Utf8NoBom (Join-Path $lock 'owner-start') (Get-ProcessStartToken $PID)
    Invoke-Runner @('start', 'claude-prompt', 'registry|live', $script:TestRoot, $prompt)
    Assert-Equal '75' $script:CaptureExitCode.ToString() 'live registry owner fails closed'
    Assert-Contains $script:CaptureOutput 'Registry lock unavailable:' 'live registry owner has exact diagnostic'
    Remove-Item -LiteralPath (Join-Path $lock 'owner-pid') -Force
    Remove-Item -LiteralPath (Join-Path $lock 'owner-start') -Force
    Remove-Item -LiteralPath $lock -Force

    [void](New-Item -ItemType Directory -Path $lock)
    Write-Utf8NoBom (Join-Path $lock 'owner-pid') $PID.ToString()
    Write-Utf8NoBom (Join-Path $lock 'owner-start') (Get-ProcessStartToken $PID)
    $env:SUPERARTES_REVIEW_TEST_FORCE_UNVERIFIABLE_PID = $PID.ToString()
    Invoke-Runner @('start', 'claude-prompt', 'registry|unverifiable', $script:TestRoot, $prompt)
    $env:SUPERARTES_REVIEW_TEST_FORCE_UNVERIFIABLE_PID = $null
    Assert-Equal '75' $script:CaptureExitCode.ToString() 'live unverifiable registry owner fails closed'
    Remove-Item -LiteralPath (Join-Path $lock 'owner-pid') -Force
    Remove-Item -LiteralPath (Join-Path $lock 'owner-start') -Force
    Remove-Item -LiteralPath $lock -Force

    [void](New-Item -ItemType Directory -Path $lock)
    Invoke-Runner @('start', 'claude-prompt', 'registry|ownerless', $script:TestRoot, $prompt)
    Assert-Equal '75' $script:CaptureExitCode.ToString() 'ownerless registry lock fails closed'
    Assert-Contains $script:CaptureOutput 'owner metadata is missing or malformed' 'ownerless registry lock has exact diagnostic'
    Remove-Item -LiteralPath $lock -Force
}

function Test-CancelProcessTreeAndIdentityFailure {
    $prompt = Join-Path $script:TestRoot 'cancel prompt.txt'
    Write-Utf8NoBom $prompt 'cancel'
    $env:FAKE_REVIEW_DELAY = '30'
    $env:FAKE_SPAWN_CHILD = '1'
    $run = Start-Review 0 @('claude-prompt', 'cancel|tree', $script:TestRoot, $prompt)
    $session = [IO.File]::ReadAllText((Join-Path $run 'provider-session')).Trim()
    $childPath = Join-Path $script:FakeLogDirectory "claude-$session.child-pid"
    Require-File $childPath 'fake reviewer child starts'
    $childStartPath = Join-Path $script:FakeLogDirectory "claude-$session.child-start"
    Require-File $childStartPath 'fake reviewer child publishes start identity'
    $reviewerId = [int]([IO.File]::ReadAllText((Join-Path $run 'reviewer-pid')).Trim())
    $reviewerStart = [IO.File]::ReadAllText((Join-Path $run 'reviewer-start')).Trim()
    $childId = [int]([IO.File]::ReadAllText($childPath).Trim())
    $childStart = [IO.File]::ReadAllText($childStartPath).Trim()
    $signalLog = Join-Path $script:TestRoot 'cancel-signal-order.txt'
    $env:SUPERARTES_REVIEW_TEST_SIGNAL_LOG = $signalLog
    Invoke-Runner @('cancel', $run)
    $env:SUPERARTES_REVIEW_TEST_SIGNAL_LOG = $null
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'cancel accepts validated process tree'
    if (Wait-ForProcessExit $reviewerId $reviewerStart) { Pass-Test 'accepted cancellation removes recorded reviewer root' }
    else { Fail-Test 'accepted cancellation removes recorded reviewer root' }
    if (Wait-ForProcessExit $childId $childStart) { Pass-Test 'accepted cancellation removes recorded fake child' }
    else { Fail-Test 'accepted cancellation removes recorded fake child' }
    $signals = @([IO.File]::ReadAllLines($signalLog))
    if ($signals.Count -gt 1 -and $signals[0].StartsWith('root:')) {
        Pass-Test 'cancellation signal log records root before descendants'
    }
    else { Fail-Test 'cancellation signal log records root before descendants' }
    $lastDepth = [int]::MaxValue
    $depthsDescending = $true
    if ($signals.Count -gt 1) {
        foreach ($signal in $signals[1..($signals.Count - 1)]) {
            $parts = $signal.Split(':')
            $depth = [int]$parts[1]
            if ($depth -gt $lastDepth) { $depthsDescending = $false }
            $lastDepth = $depth
        }
    }
    if ($depthsDescending) { Pass-Test 'cancellation signals descendants deepest first' }
    else { Fail-Test 'cancellation signals descendants deepest first' }
    Wait-Review $run 10 0
    Assert-Equal 'cancelled' ([IO.File]::ReadAllText((Join-Path $run 'state')).Trim()) 'cancel publishes cancelled terminal state'
    Assert-Equal '-1' ([IO.File]::ReadAllText((Join-Path $run 'exit-code')).Trim()) 'forced Windows cancellation retains exact process exit evidence'
    $cancelEvidence = [IO.File]::ReadAllText((Join-Path $run 'cancel-requested')).Trim()
    if ($cancelEvidence -match '^accepted:\d+$') { Pass-Test 'cancel retains exact accepted terminal evidence' }
    else { Fail-Test 'cancel retains exact accepted terminal evidence' }
    $env:FAKE_REVIEW_DELAY = $null
    $env:FAKE_SPAWN_CHILD = $null

    $env:FAKE_REVIEW_DELAY = '3'
    $invalid = Start-Review 0 @('claude-prompt', 'cancel|identity', $script:TestRoot, $prompt)
    $realStart = [IO.File]::ReadAllText((Join-Path $invalid 'reviewer-start')).Trim()
    Write-Utf8NoBom (Join-Path $invalid 'reviewer-start') 'invalid-start-token'
    Invoke-Runner @('cancel', $invalid)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'identity mismatch fails closed'
    Assert-Contains $script:CaptureOutput 'STATE=indeterminate' 'identity mismatch is indeterminate'
    $invalidPid = [int]([IO.File]::ReadAllText((Join-Path $invalid 'reviewer-pid')).Trim())
    if ((Get-ProcessStartToken $invalidPid).Length -gt 0) { Pass-Test 'forged root identity kills no process' }
    else { Fail-Test 'forged root identity kills no process' }
    Write-Utf8NoBom (Join-Path $invalid 'reviewer-start') $realStart
    Wait-Review $invalid 10 0
    Assert-Equal 'exited' ([IO.File]::ReadAllText((Join-Path $invalid 'state')).Trim()) 'rejected cancellation permits natural exit'
    $env:FAKE_REVIEW_DELAY = $null
}

function Test-CancellationCimAndLockFailures {
    $prompt = Join-Path $script:TestRoot 'cancel failure prompt.txt'
    Write-Utf8NoBom $prompt 'cancel failures'
    $env:FAKE_REVIEW_DELAY = '30'
    $env:FAKE_SPAWN_CHILD = '1'
    $run = Start-Review 0 @('claude-prompt', 'cancel|cim', $script:TestRoot, $prompt)
    $env:SUPERARTES_REVIEW_TEST_FORCE_CIM_FAILURE = '1'
    Invoke-Runner @('cancel', $run)
    $env:SUPERARTES_REVIEW_TEST_FORCE_CIM_FAILURE = $null
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'CIM query failure makes cancellation indeterminate'
    Assert-FileContains (Join-Path $run 'cancel-requested') 'rejected:snapshot-failed:' 'CIM failure is retained as rejected evidence'
    Invoke-Runner @('cancel', $run)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'reviewer can be safely cancelled after CIM recovers'
    Wait-Review $run 10 0

    $unavailable = Start-Review 0 @('claude-prompt', 'cancel|child-identity', $script:TestRoot, $prompt)
    $unavailableSession = [IO.File]::ReadAllText((Join-Path $unavailable 'provider-session')).Trim()
    $unavailableChildPidPath = Join-Path $script:FakeLogDirectory "claude-$unavailableSession.child-pid"
    $unavailableChildStartPath = Join-Path $script:FakeLogDirectory "claude-$unavailableSession.child-start"
    Require-File $unavailableChildPidPath 'child-identity fixture child starts'
    Require-File $unavailableChildStartPath 'child-identity fixture child records StartTime'
    $unavailableRootPid = [int]([IO.File]::ReadAllText((Join-Path $unavailable 'reviewer-pid')).Trim())
    $unavailableRootStart = [IO.File]::ReadAllText((Join-Path $unavailable 'reviewer-start')).Trim()
    $unavailableChildPid = [int]([IO.File]::ReadAllText($unavailableChildPidPath).Trim())
    $unavailableChildStart = [IO.File]::ReadAllText($unavailableChildStartPath).Trim()
    $descendantSignalLog = Join-Path $script:TestRoot 'descendant-identity-mismatch-signals.txt'
    $env:SUPERARTES_REVIEW_TEST_SIGNAL_LOG = $descendantSignalLog
    $env:SUPERARTES_REVIEW_TEST_FORCE_DESCENDANT_CREATION_MISMATCH = '1'
    Invoke-Runner @('cancel', $unavailable)
    $env:SUPERARTES_REVIEW_TEST_FORCE_DESCENDANT_CREATION_MISMATCH = $null
    $env:SUPERARTES_REVIEW_TEST_SIGNAL_LOG = $null
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'descendant CIM creation mismatch aborts cancellation before signalling'
    Assert-FileContains (Join-Path $unavailable 'cancel-requested') 'rejected:snapshot-failed:' 'descendant CIM mismatch retains rejected snapshot evidence'
    if (-not (Test-Path -LiteralPath $descendantSignalLog)) {
        Pass-Test 'descendant CIM creation mismatch emits no process signal'
    }
    else { Fail-Test 'descendant CIM creation mismatch emits no process signal' }
    if (Test-ProcessIdentity $unavailableRootPid $unavailableRootStart) { Pass-Test 'descendant CIM mismatch leaves reviewer root alive' }
    else { Fail-Test 'descendant CIM mismatch leaves reviewer root alive' }
    if (Test-ProcessIdentity $unavailableChildPid $unavailableChildStart) { Pass-Test 'descendant CIM mismatch leaves fake child alive' }
    else { Fail-Test 'descendant CIM mismatch leaves fake child alive' }
    if (-not ([IO.File]::ReadAllText((Join-Path $unavailable 'cancel-requested')).Contains('accepted:'))) {
        Pass-Test 'descendant CIM mismatch publishes no accepted marker'
    }
    else { Fail-Test 'descendant CIM mismatch publishes no accepted marker' }
    Invoke-Runner @('cancel', $unavailable)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'cancellation succeeds after descendant CIM identity recovers'
    Wait-Review $unavailable 10 0

    $lateTrigger = Join-Path $script:TestRoot 'late descendant trigger'
    $lateReady = Join-Path $script:TestRoot 'late descendant ready'
    $lateSignalLog = Join-Path $script:TestRoot 'late-descendant-signals.txt'
    $env:SUPERARTES_REVIEW_TEST_SNAPSHOT_TRIGGER_FILE = $lateTrigger
    $env:SUPERARTES_REVIEW_TEST_ADDED_DESCENDANT_READY_FILE = $lateReady
    $lateRun = Start-Review 0 @(
        'claude-prompt', 'cancel|late-descendant', $script:TestRoot, $prompt
    )
    $lateSession = [IO.File]::ReadAllText(
        (Join-Path $lateRun 'provider-session')).Trim()
    $lateRootPid = [int]([IO.File]::ReadAllText(
        (Join-Path $lateRun 'reviewer-pid')).Trim())
    $lateRootStart = [IO.File]::ReadAllText(
        (Join-Path $lateRun 'reviewer-start')).Trim()
    $env:SUPERARTES_REVIEW_TEST_SIGNAL_LOG = $lateSignalLog
    Invoke-Runner @('cancel', $lateRun)
    $env:SUPERARTES_REVIEW_TEST_SIGNAL_LOG = $null
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'new descendant after snapshot aborts cancellation'
    Assert-FileContains (Join-Path $lateRun 'cancel-requested') 'rejected:snapshot-failed:' 'new descendant retains rejected snapshot evidence'
    Require-File $lateReady 'late descendant fixture publishes ready evidence'
    $lateChildPidPath = Join-Path $script:FakeLogDirectory `
        "claude-$lateSession.late-child-pid"
    $lateChildStartPath = Join-Path $script:FakeLogDirectory `
        "claude-$lateSession.late-child-start"
    Require-File $lateChildPidPath 'late descendant publishes PID'
    Require-File $lateChildStartPath 'late descendant publishes start identity'
    $lateChildPid = [int]([IO.File]::ReadAllText($lateChildPidPath).Trim())
    $lateChildStart = [IO.File]::ReadAllText($lateChildStartPath).Trim()
    if (-not (Test-Path -LiteralPath $lateSignalLog)) {
        Pass-Test 'new descendant rejection emits no process signal'
    }
    else { Fail-Test 'new descendant rejection emits no process signal' }
    if (Test-ProcessIdentity $lateRootPid $lateRootStart) {
        Pass-Test 'new descendant rejection leaves reviewer root alive'
    }
    else { Fail-Test 'new descendant rejection leaves reviewer root alive' }
    if (Test-ProcessIdentity $lateChildPid $lateChildStart) {
        Pass-Test 'new descendant rejection leaves added child alive'
    }
    else { Fail-Test 'new descendant rejection leaves added child alive' }
    $env:SUPERARTES_REVIEW_TEST_SNAPSHOT_TRIGGER_FILE = $null
    $env:SUPERARTES_REVIEW_TEST_ADDED_DESCENDANT_READY_FILE = $null
    Invoke-Runner @('cancel', $lateRun)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'late descendant tree cancels after hook removal'
    Wait-Review $lateRun 10 0

    $env:FAKE_SPAWN_CHILD = $null
    $env:FAKE_REVIEW_DELAY = '2'
    $naturalExit = Start-Review 0 @('claude-prompt', 'cancel|root-natural-exit-race', $script:TestRoot, $prompt)
    $env:SUPERARTES_REVIEW_TEST_CANCEL_WAIT_FOR_ROOT_EXIT = '1'
    Invoke-Runner @('cancel', $naturalExit)
    $env:SUPERARTES_REVIEW_TEST_CANCEL_WAIT_FOR_ROOT_EXIT = $null
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'root exit after initial identity validation fails closed'
    Assert-Contains $script:CaptureOutput 'STATE=indeterminate' 'root exit race is reported as indeterminate'
    if (-not (Test-Path -LiteralPath (Join-Path $naturalExit '.cancel-lock'))) {
        Pass-Test 'root exit race safely releases cancellation lock'
    }
    else { Fail-Test 'root exit race safely releases cancellation lock' }
    $naturalEvidence = [IO.File]::ReadAllText((Join-Path $naturalExit 'cancel-requested')).Trim()
    if ($naturalEvidence -match '^rejected:identity-mismatch:\d+$') {
        Pass-Test 'root exit race retains rejected cancellation evidence'
    }
    else { Fail-Test 'root exit race retains rejected cancellation evidence' }
    if (-not $naturalEvidence.StartsWith('pending:')) {
        Pass-Test 'root exit race leaves no pending cancellation evidence'
    }
    else { Fail-Test 'root exit race leaves no pending cancellation evidence' }
    Wait-Review $naturalExit 10 0
    Assert-Equal 'exited' ([IO.File]::ReadAllText((Join-Path $naturalExit 'state')).Trim()) 'root exit race retains natural terminal state'
    Assert-Equal '0' ([IO.File]::ReadAllText((Join-Path $naturalExit 'exit-code')).Trim()) 'root exit race retains natural exit evidence'
    $env:FAKE_REVIEW_DELAY = '30'
    $env:FAKE_SPAWN_CHILD = '1'

    $ownIdentity = Start-Review 0 @('claude-prompt', 'cancel|owner-identity', $script:TestRoot, $prompt)
    $env:SUPERARTES_REVIEW_TEST_FORCE_CANCEL_OWNER_IDENTITY_FAILURE = '1'
    Invoke-Runner @('cancel', $ownIdentity)
    $env:SUPERARTES_REVIEW_TEST_FORCE_CANCEL_OWNER_IDENTITY_FAILURE = $null
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'cancellation lock fails closed without caller StartTime'
    if (-not (Test-Path -LiteralPath (Join-Path $ownIdentity '.cancel-lock'))) {
        Pass-Test 'failed caller identity publishes no cancellation lock'
    }
    else { Fail-Test 'failed caller identity publishes no cancellation lock' }
    Invoke-Runner @('cancel', $ownIdentity)
    Wait-Review $ownIdentity 10 0
    $env:FAKE_REVIEW_DELAY = $null
    $env:FAKE_SPAWN_CHILD = $null
}

function Test-CancellationLockMatrixAndMonotonicEvidence {
    $prompt = Join-Path $script:TestRoot 'cancel lock prompt.txt'
    Write-Utf8NoBom $prompt 'cancel locks'
    $env:FAKE_REVIEW_DELAY = '30'

    $stale = Start-Review 0 @('claude-prompt', 'cancel-lock|stale', $script:TestRoot, $prompt)
    $staleLock = Join-Path $stale '.cancel-lock'
    [void](New-Item -ItemType Directory -Path $staleLock)
    Write-Utf8NoBom (Join-Path $staleLock 'owner-pid') '99999999'
    Write-Utf8NoBom (Join-Path $staleLock 'owner-start') '1'
    Invoke-Runner @('cancel', $stale)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'stale cancellation lock is reclaimed'
    Assert-Contains $script:CaptureOutput 'Reclaimed stale cancellation lock:' 'stale cancellation lock recovery is diagnosed'
    Wait-Review $stale 10 0

    foreach ($case in @('live', 'unverifiable', 'malformed')) {
        $run = Start-Review 0 @('claude-prompt', "cancel-lock|$case", $script:TestRoot, $prompt)
        $lock = Join-Path $run '.cancel-lock'
        [void](New-Item -ItemType Directory -Path $lock)
        if ($case -cne 'malformed') {
            Write-Utf8NoBom (Join-Path $lock 'owner-pid') $PID.ToString()
            Write-Utf8NoBom (Join-Path $lock 'owner-start') (Get-ProcessStartToken $PID)
        }
        if ($case -ceq 'unverifiable') {
            $env:SUPERARTES_REVIEW_TEST_FORCE_UNVERIFIABLE_PID = $PID.ToString()
        }
        Invoke-Runner @('cancel', $run)
        $env:SUPERARTES_REVIEW_TEST_FORCE_UNVERIFIABLE_PID = $null
        Assert-Equal '12' $script:CaptureExitCode.ToString() "$case cancellation lock fails closed"
        Assert-Contains $script:CaptureOutput 'Cancellation lock unavailable: live, unverifiable, ownerless, or malformed:' "$case cancellation lock has exact diagnostic"
        if (Test-Path -LiteralPath $lock -PathType Container) { Pass-Test "$case cancellation lock is retained" }
        else { Fail-Test "$case cancellation lock is retained" }
        Get-ChildItem -LiteralPath $lock -Force | Remove-Item -Force
        Remove-Item -LiteralPath $lock -Force
        Invoke-Runner @('cancel', $run)
        Wait-Review $run 10 0
    }

    $env:SUPERARTES_REVIEW_TEST_CANCEL_ACCEPT_DELAY = '5'
    $concurrent = Start-Review 0 @('claude-prompt', 'cancel-lock|concurrent', $script:TestRoot, $prompt)
    $oneOut = Join-Path $script:TestRoot 'cancel-one.out'
    $oneErr = Join-Path $script:TestRoot 'cancel-one.err'
    $one = Start-RunnerCapture $RunnerPath @('cancel', $concurrent) $oneOut $oneErr
    $pendingPath = Join-Path $concurrent 'cancel-requested'
    $pendingBefore = Wait-ForArtifactPrefix $pendingPath 'pending:'
    if ($pendingBefore.Length -gt 0) { Pass-Test 'concurrent cancellation synchronizes on pending marker' }
    else { Fail-Test 'concurrent cancellation synchronizes on pending marker' }
    Invoke-Runner @('cancel', $concurrent)
    Assert-Equal '12' $script:CaptureExitCode.ToString() 'concurrent cancellation caller observes held private lock'
    Assert-Equal $pendingBefore ([IO.File]::ReadAllText($pendingPath).Trim()) 'concurrent caller cannot rewrite pending evidence'
    $one.WaitForExit()
    Assert-Equal '0' $one.ExitCode.ToString() 'cancellation lock holder completes accepted request'
    $env:SUPERARTES_REVIEW_TEST_CANCEL_ACCEPT_DELAY = $null
    Wait-Review $concurrent 10 0
    $evidence = [IO.File]::ReadAllText((Join-Path $concurrent 'cancel-requested')).Trim()
    if ($evidence -match '^accepted:\d+$') { Pass-Test 'concurrent cancellation leaves monotonic accepted evidence' }
    else { Fail-Test 'concurrent cancellation leaves monotonic accepted evidence' }
    Assert-Equal 'cancelled' ([IO.File]::ReadAllText((Join-Path $concurrent 'state')).Trim()) 'accepted cancellation after five-second publication delay wins terminal classification'

    $terminal = Start-Review 0 @('claude-prompt', 'cancel-lock|terminal', $script:TestRoot, $prompt)
    Invoke-Runner @('cancel', $terminal)
    Wait-Review $terminal 10 0
    $terminalEvidence = [IO.File]::ReadAllText((Join-Path $terminal 'cancel-requested')).Trim()
    Invoke-Runner @('cancel', $terminal)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'terminal cancellation trusts terminal metadata'
    Assert-Equal $terminalEvidence ([IO.File]::ReadAllText((Join-Path $terminal 'cancel-requested')).Trim()) 'terminal cancellation does not rewrite accepted evidence'
    $env:FAKE_REVIEW_DELAY = $null
}

function Test-CancellationTerminalFenceRecovery {
    $prompt = Join-Path $script:TestRoot 'cancel terminal fence prompt.txt'
    Write-Utf8NoBom $prompt 'cancel terminal fence'
    $env:FAKE_REVIEW_DELAY = '30'
    $env:SUPERARTES_REVIEW_TEST_CANCEL_ACCEPT_DELAY = '8'
    $run = Start-Review 0 @('claude-prompt', 'cancel-fence|malformed-owner', $script:TestRoot, $prompt)
    $reviewerId = [int]([IO.File]::ReadAllText((Join-Path $run 'reviewer-pid')).Trim())
    $reviewerStart = [IO.File]::ReadAllText((Join-Path $run 'reviewer-start')).Trim()
    $cancelOut = Join-Path $script:TestRoot 'cancel-fence.out'
    $cancelErr = Join-Path $script:TestRoot 'cancel-fence.err'
    $canceller = Start-RunnerCapture $RunnerPath @('cancel', $run) $cancelOut $cancelErr
    $pendingPath = Join-Path $run 'cancel-requested'
    $pending = Wait-ForArtifactPrefix $pendingPath 'pending:'
    if ($pending.Length -eq 0) {
        Fail-Test 'terminal fence fixture publishes pending cancellation evidence'
        throw 'Cancellation did not publish pending evidence'
    }
    Pass-Test 'terminal fence fixture publishes pending cancellation evidence'
    if (-not (Wait-ForProcessExit $reviewerId $reviewerStart)) {
        Fail-Test 'terminal fence fixture reviewer exits during cancellation transaction'
        throw 'Reviewer did not exit during cancellation transaction'
    }
    Pass-Test 'terminal fence fixture reviewer exits during cancellation transaction'
    $cancelLock = Join-Path $run '.cancel-lock'
    $ownerPid = [IO.File]::ReadAllText((Join-Path $cancelLock 'owner-pid')).Trim()
    $ownerStart = [IO.File]::ReadAllText((Join-Path $cancelLock 'owner-start')).Trim()
    Remove-Item -LiteralPath (Join-Path $cancelLock 'owner-start') -Force
    if (-not (Test-Path -LiteralPath (Join-Path $cancelLock 'owner-start'))) {
        Pass-Test 'terminal fence fixture makes cancellation lock structurally ownerless'
    }
    else {
        Fail-Test 'terminal fence fixture makes cancellation lock structurally ownerless'
        throw 'Cancellation lock retained owner-start metadata'
    }
    Stop-CapturedFixtureProcess $canceller
    Invoke-Runner @('status', $run)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'malformed cancellation lock keeps terminal classification indeterminate'
    Assert-Equal 'running' ([IO.File]::ReadAllText((Join-Path $run 'state')).Trim()) 'malformed cancellation lock does not publish a false terminal state'
    Assert-Equal $pending ([IO.File]::ReadAllText($pendingPath).Trim()) 'malformed cancellation lock preserves pending evidence'
    Write-Utf8NoBom (Join-Path $cancelLock 'owner-pid') $ownerPid
    Write-Utf8NoBom (Join-Path $cancelLock 'owner-start') $ownerStart
    Wait-Review $run 10 0
    Assert-FileContains $pendingPath 'rejected:abandoned:' 'stale cancellation owner is reclaimed with rejected abandoned evidence'
    Assert-Equal 'exited' ([IO.File]::ReadAllText((Join-Path $run 'state')).Trim()) 'reclaimed abandoned cancellation permits natural exited classification'
    $env:SUPERARTES_REVIEW_TEST_CANCEL_ACCEPT_DELAY = $null
    $env:FAKE_REVIEW_DELAY = $null
}

function Test-SafeCleanup {
    $prompt = Join-Path $script:TestRoot 'cleanup prompt.txt'
    Write-Utf8NoBom $prompt 'cleanup'
    $env:FAKE_REVIEW_DELAY = '30'
    $running = Start-Review 0 @('claude-prompt', 'cleanup|running', $script:TestRoot, $prompt)
    Invoke-Runner @('cleanup', $running)
    Assert-Equal '66' $script:CaptureExitCode.ToString() 'cleanup refuses running review'
    Invoke-Runner @('cancel', $running)
    Wait-Review $running 10 0
    $env:FAKE_REVIEW_DELAY = $null
    $run = Start-Review 0 @('claude-prompt', 'cleanup|known', $script:TestRoot, $prompt)
    Wait-Review $run 10 0
    $evidenceBefore = @{}
    foreach ($entry in @(Get-ChildItem -LiteralPath $run -Force)) {
        if (-not $entry.PSIsContainer) {
            $evidenceBefore[$entry.Name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($entry.FullName))
        }
    }
    Write-Utf8NoBom (Join-Path $run 'unknown-evidence') 'preserve'
    Invoke-Runner @('cleanup', $run)
    Assert-Equal '66' $script:CaptureExitCode.ToString() 'cleanup refuses unknown evidence'
    Assert-FileContains (Join-Path $run 'unknown-evidence') 'preserve' 'unknown evidence is retained'
    foreach ($name in $evidenceBefore.Keys) {
        $path = Join-Path $run $name
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $evidenceBefore[$name]) {
            Pass-Test "unknown cleanup entry preserves standard evidence $name"
        }
        else { Fail-Test "unknown cleanup entry preserves standard evidence $name" }
    }

    $unsafe = Start-Review 0 @('claude-prompt', 'cleanup|unsafe-known', $script:TestRoot, $prompt)
    Wait-Review $unsafe 10 0
    $unsafeEvidence = @{}
    foreach ($name in @('marker', 'profile', 'state', 'review-key')) {
        $unsafeEvidence[$name] = [IO.File]::ReadAllText((Join-Path $unsafe $name))
    }
    $outsideArtifact = Join-Path $script:TestRoot 'outside cleanup artifact target'
    [void](New-Item -ItemType Directory -Path $outsideArtifact)
    Write-Utf8NoBom (Join-Path $outsideArtifact 'sentinel') 'preserve outside cleanup target'
    $unsafeResult = Join-Path $unsafe 'result'
    Remove-Item -LiteralPath $unsafeResult -Force
    New-RequiredJunction $unsafeResult $outsideArtifact
    Invoke-Runner @('cleanup', $unsafe)
    Assert-Equal '66' $script:CaptureExitCode.ToString() 'cleanup preflight refuses a reparse-point known artifact'
    foreach ($name in $unsafeEvidence.Keys) {
        Assert-Equal $unsafeEvidence[$name] ([IO.File]::ReadAllText((Join-Path $unsafe $name))) "unsafe cleanup entry preserves standard evidence $name"
    }
    Assert-FileContains (Join-Path $outsideArtifact 'sentinel') 'preserve outside cleanup target' 'unsafe cleanup artifact preserves outside target'
    [IO.Directory]::Delete($unsafeResult, $false)

    $locked = Start-Review 0 @('claude-prompt', 'cleanup|locked-artifact', $script:TestRoot, $prompt)
    Wait-Review $locked 10 0
    $lockedEvidence = @{}
    foreach ($name in @('marker', 'run-path', 'review-key', 'profile', 'state', 'result')) {
        $lockedEvidence[$name] = [Convert]::ToBase64String(
            [IO.File]::ReadAllBytes((Join-Path $locked $name)))
    }
    $lockedArtifact = Join-Path $locked 'reviewer-log'
    $lockedStream = [IO.File]::Open(
        $lockedArtifact, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::None)
    try {
        Invoke-Runner @('cleanup', $locked)
        Assert-Equal '66' $script:CaptureExitCode.ToString() 'cleanup preflight refuses a locked known artifact'
        foreach ($name in $lockedEvidence.Keys) {
            $actual = [Convert]::ToBase64String(
                [IO.File]::ReadAllBytes((Join-Path $locked $name)))
            Assert-Equal $lockedEvidence[$name] $actual "locked cleanup artifact preserves standard evidence $name"
        }
    }
    finally { $lockedStream.Dispose() }

    $clean = Start-Review 0 @('claude-prompt', 'cleanup|clean', $script:TestRoot, $prompt)
    Wait-Review $clean 10 0
    $sibling = Start-Review 0 @('claude-prompt', 'cleanup|sibling', $script:TestRoot, $prompt)
    Wait-Review $sibling 10 0
    Invoke-Runner @('cleanup', $clean)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'cleanup removes exact known artifacts'
    if ((-not (Test-Path -LiteralPath $clean)) -and (Test-Path -LiteralPath $sibling)) {
        Pass-Test 'cleanup preserves sibling run'
    }
    else { Fail-Test 'cleanup preserves sibling run' }

    $staleLockRun = Start-Review 0 @('claude-prompt', 'cleanup|stale-cancel-lock', $script:TestRoot, $prompt)
    Wait-Review $staleLockRun 10 0
    $staleLock = Join-Path $staleLockRun '.cancel-lock'
    [void](New-Item -ItemType Directory -Path $staleLock)
    Write-Utf8NoBom (Join-Path $staleLock 'owner-pid') '99999999'
    Write-Utf8NoBom (Join-Path $staleLock 'owner-start') '1'
    Invoke-Runner @('cleanup', $staleLockRun)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'cleanup reclaims stale cancellation lock before empty removal'
    if (-not (Test-Path -LiteralPath $staleLockRun)) { Pass-Test 'normal cleanup removes only empty run directory' }
    else { Fail-Test 'normal cleanup removes only empty run directory' }

    $copied = Join-Path $env:SUPERARTES_REVIEW_TMPDIR 'run-copied'
    Copy-Item -LiteralPath $sibling -Destination $copied -Recurse
    Invoke-Runner @('cleanup', $copied)
    Assert-Equal '65' $script:CaptureExitCode.ToString() 'cleanup rejects copied path mismatch'
    $outside = Join-Path $script:TestRoot 'run-outside'
    Copy-Item -LiteralPath $sibling -Destination $outside -Recurse
    Invoke-Runner @('cleanup', $outside)
    Assert-Equal '65' $script:CaptureExitCode.ToString() 'cleanup rejects outside run'

    $markerPath = Join-Path $sibling 'marker'
    $marker = [IO.File]::ReadAllText($markerPath)
    Write-Utf8NoBom $markerPath 'wrong-marker'
    Invoke-Runner @('cleanup', $sibling)
    Assert-Equal '65' $script:CaptureExitCode.ToString() 'cleanup rejects marker mismatch'
    Write-Utf8NoBom $markerPath $marker.TrimEnd("`r", "`n")

    $link = Join-Path $env:SUPERARTES_REVIEW_TMPDIR 'run-link'
    New-RequiredJunction $link $sibling
    Invoke-Runner @('cleanup', $link)
    Assert-Equal '65' $script:CaptureExitCode.ToString() 'cleanup rejects reparse-point run'
    [IO.Directory]::Delete($link, $false)
}

function Test-ReparseRootAndLockSafety {
    $prompt = Join-Path $script:TestRoot 'junction prompt.txt'
    Write-Utf8NoBom $prompt 'junction safety'
    $outside = Join-Path $script:TestRoot 'outside lock target'
    [void](New-Item -ItemType Directory -Path $outside)
    Write-Utf8NoBom (Join-Path $outside 'sentinel') 'preserve outside'
    Write-Utf8NoBom (Join-Path $outside 'owner-pid') '99999999'
    Write-Utf8NoBom (Join-Path $outside 'owner-start') '1'

    $registryLink = Join-Path $env:SUPERARTES_REVIEW_TMPDIR '.registry-lock'
    New-RequiredJunction $registryLink $outside
    Invoke-Runner @('start', 'claude-prompt', 'junction|registry', $script:TestRoot, $prompt)
    Assert-Equal '75' $script:CaptureExitCode.ToString() 'registry lock junction fails closed'
    Assert-FileContains (Join-Path $outside 'sentinel') 'preserve outside' 'registry junction preserves outside sentinel'
    Assert-FileContains (Join-Path $outside 'owner-pid') '99999999' 'registry junction preserves outside owner metadata'
    [IO.Directory]::Delete($registryLink, $false)

    $env:FAKE_REVIEW_DELAY = '30'
    $run = Start-Review 0 @('claude-prompt', 'junction|cancel', $script:TestRoot, $prompt)
    $cancelLink = Join-Path $run '.cancel-lock'
    New-RequiredJunction $cancelLink $outside
    Invoke-Runner @('cancel', $run)
    Assert-Equal '4' $script:CaptureExitCode.ToString() 'cancellation lock junction fails closed'
    Assert-FileContains (Join-Path $outside 'sentinel') 'preserve outside' 'cancellation junction preserves outside sentinel'
    Assert-FileContains (Join-Path $outside 'owner-start') '1' 'cancellation junction preserves outside owner metadata'
    [IO.Directory]::Delete($cancelLink, $false)
    Invoke-Runner @('cancel', $run)
    Wait-Review $run 10 0
    $env:FAKE_REVIEW_DELAY = $null

    $rootTarget = Join-Path $script:TestRoot 'outside root target'
    [void](New-Item -ItemType Directory -Path $rootTarget)
    Write-Utf8NoBom (Join-Path $rootTarget 'root-sentinel') 'root preserved'
    $rootLink = Join-Path $script:TestRoot 'review root junction'
    New-RequiredJunction $rootLink $rootTarget
    $savedRoot = $env:SUPERARTES_REVIEW_TMPDIR
    $env:SUPERARTES_REVIEW_TMPDIR = $rootLink
    $rootRun = Start-Review 0 @('claude-prompt', 'junction|canonical-root', $script:TestRoot, $prompt)
    $canonicalRootTarget = (Resolve-Path -LiteralPath $rootTarget).ProviderPath.TrimEnd('\')
    if ((Split-Path $rootRun -Parent).Equals($canonicalRootTarget, [StringComparison]::OrdinalIgnoreCase)) {
        Pass-Test 'linked review root prints run under canonical target'
    }
    else { Fail-Test 'linked review root prints run under canonical target' }
    Invoke-Runner @('status', $rootRun)
    Assert-OneOf @('0', '3') $script:CaptureExitCode.ToString() 'status accepts canonical run from linked review root'
    Wait-Review $rootRun 10 0
    Invoke-Runner @('cleanup', $rootRun)
    Assert-Equal '0' $script:CaptureExitCode.ToString() 'cleanup accepts canonical run from linked review root'
    if (-not (Test-Path -LiteralPath $rootRun)) { Pass-Test 'linked-root cleanup removes canonical run only' }
    else { Fail-Test 'linked-root cleanup removes canonical run only' }
    $env:SUPERARTES_REVIEW_TMPDIR = $savedRoot
    Assert-FileContains (Join-Path $rootTarget 'root-sentinel') 'root preserved' 'review root junction preserves outside data'
    [IO.Directory]::Delete($rootLink, $false)
}

function Test-NoProcessLeaks {
    Start-Sleep -Milliseconds 500
    $found = @()
    try {
        foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            if ($process.CommandLine -and
                ([string]$process.CommandLine).IndexOf($script:CanonicalTestRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $found += $process
            }
        }
    }
    catch {
        Fail-Test "no-process-leak CIM query succeeds: $($_.Exception.Message)"
        return
    }
    Assert-Equal '0' $found.Count.ToString() 'no fake reviewer or supervisor processes remain'
}

Start-TestSuite
try {
    $spacedRunnerDirectory = Join-Path $script:TestRoot 'copied runner path with spaces'
    [void](New-Item -ItemType Directory -Path $spacedRunnerDirectory)
    $spacedRunner = Join-Path $spacedRunnerDirectory 'invoke reviewer copy.ps1'
    Copy-Item -LiteralPath $RunnerPath -Destination $spacedRunner
    $RunnerPath = (Resolve-Path -LiteralPath $spacedRunner).ProviderPath
    if ($RunnerPath.Contains(' ')) { Pass-Test 'suite executes a copied runner whose path contains spaces' }
    else { Fail-Test 'suite executes a copied runner whose path contains spaces' }
    Test-SharedContract
    Test-StaticSecurityInvariants
    Test-CimCreationTokenNormalization
    Test-ProfileCaptureContract
    Test-PreflightAndInvalidArguments
    Test-ClaudePromptLifecycle
    Test-ClaudeDirectOutputAndScalarExit
    Test-NativeExecutableDispatchParity
    Test-SlowFailureAndPartialResults
    Test-SupervisionIdentityAndTiming
    Test-SupervisorStdinDetached
    Test-StatusTrustOrdering
    Test-RemovedWorkDirectoryLaunchFailure
    Test-HiddenSupervisorLaunchException
    Test-CodexProfiles
    Test-ExactKeyAndChain
    Test-ChainTailAndCorruptionMatrix
    Test-LiveExactKeyAndDistinctConcurrency
    Test-SimultaneousSameKeySerialization
    Test-CreatorSupervisorHandoff
    Test-DelayedSupervisorPublicationAndLateFence
    Test-ReparseEvidenceWriteSafety
    Test-RegistryLockRecovery
    Test-CancelProcessTreeAndIdentityFailure
    Test-CancellationCimAndLockFailures
    Test-CancellationLockMatrixAndMonotonicEvidence
    Test-CancellationTerminalFenceRecovery
    Test-SafeCleanup
    Test-ReparseRootAndLockSafety
    Test-NoProcessLeaks
}
finally {
    Stop-TestSuite
}
Complete-TestSuite
