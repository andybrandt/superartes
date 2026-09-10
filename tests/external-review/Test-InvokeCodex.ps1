# Test-InvokeCodex.ps1 — deterministic tests for the Windows background runner.
#
# Uses a fake `codex` on PATH, so it needs no credentials, network or model
# tokens. Runs under Windows PowerShell 5.1 and under PowerShell 7 on any
# platform. The Linux run is a syntax-and-logic check, not native-Windows
# verification. Three things it cannot reach: on Windows the fake is served by a
# codex.cmd shim, the runner then dispatches that through cmd.exe, and
# `Get-Command -CommandType Application` has to pick the .cmd out of a PATHEXT
# search that Linux has no equivalent of — nothing here shadows `codex`, so the
# resolution has only ever chosen between one candidate. None of the three has
# been exercised on a Windows host.
#
#   pwsh           -NoProfile -File tests/external-review/Test-InvokeCodex.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\external-review\Test-InvokeCodex.ps1

$ErrorActionPreference = 'Continue'

# Forward slashes, not '..\..': PowerShell normalises them on Windows, whereas a
# backslash is a literal filename character on Linux and macOS.
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
$Runner = Join-Path $RepoRoot 'skills/external-review/invoke-codex.ps1'
# Fail loudly if the runner is missing, instead of letting the harness supply the
# exit codes the assertions expect. `pwsh -File <missing-script>` exits 64 — the
# same code this runner uses for EVERY usage error — so without this guard a suite
# pointed at nothing reports 14 assertions as PASSED for entirely the wrong reason.
if (-not (Test-Path -LiteralPath $Runner -PathType Leaf)) {
    # To stderr, where the shell sibling sends it: this is a harness failure, not
    # a line of test output.
    [Console]::Error.WriteLine("FATAL: runner not found: $Runner")
    [Console]::Error.Flush()
    exit 1
}

$script:Passed = 0
$script:Failed = 0

function Pass { param([string] $Label) $script:Passed++; Write-Host "PASS: $Label" }
function Fail {
    param([string] $Label, [string] $Detail)
    $script:Failed++
    Write-Host "FAIL: $Label`n      $Detail"
}
function AssertStatus {
    param([string] $Label, [int] $Expected, [int] $Actual)
    if ($Expected -eq $Actual) { Pass $Label } else { Fail $Label "expected exit $Expected, got $Actual" }
}
# -like treats its right side as a WILDCARD PATTERN, so a needle containing [, ]
# or * would not match itself — '-o' is fine, but a run directory or a scope value
# need not be. .Contains is a literal search. The interpolation is deliberate:
# Get-Content -Raw on an empty file returns AutomationNull, which a [string] cast
# leaves null and .Contains would then throw on.
function AssertContains {
    param([string] $Label, [string] $Needle, [string] $Haystack)
    if ("$Haystack".Contains($Needle)) { Pass $Label } else { Fail $Label "expected '$Needle' in: $Haystack" }
}
function AssertAbsent {
    param([string] $Label, [string] $Needle, [string] $Haystack)
    if ("$Haystack".Contains($Needle)) { Fail $Label "did not expect '$Needle' in: $Haystack" } else { Pass $Label }
}
function AssertEquals {
    param([string] $Label, [string] $Expected, [string] $Actual)
    if ($Expected -eq $Actual) { Pass $Label } else { Fail $Label "expected '$Expected', got '$Actual'" }
}

function Test-OnWindowsHost {
    return ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
}

function New-Sandbox {
    # Isolated temp directory plus a fake codex on PATH. GetTempPath honours TMPDIR
    # on Linux and, on Windows, checks TMP FIRST and only then TEMP — which is why
    # Invoke-Runner sets both of those. Setting TEMP alone leaves the runner writing
    # into the real user temp on Windows.
    # The name carries a SPACE on purpose. Quoting is the stated reason
    # ConvertTo-ProcessArgument and the cmd `/s /c` form exist, and a Windows temp
    # path under a user named "John Smith" is the ordinary case, not an exotic one.
    # Putting the space here buys that coverage for every test in the file.
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('invoke-codex test.' + [System.IO.Path]::GetRandomFileName().Replace('.', ''))
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    foreach ($sub in @('bin', 'tmp', 'work')) {
        New-Item -ItemType Directory -Path (Join-Path $sandbox $sub) | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    # The fake's logic lives in PowerShell so both platforms share one
    # implementation of the contract: record argv one per line, record stdin,
    # honour a delay, emulate -o, and exit as told.
    $fakeLogic = @'
$argv = @($args)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($env:FAKE_CODEX_ARGV, (($argv -join "`n") + "`n"), $utf8NoBom)
$stdin = [Console]::In.ReadToEnd()
[System.IO.File]::WriteAllText($env:FAKE_CODEX_STDIN, $stdin, $utf8NoBom)
[Console]::Out.WriteLine('fake codex final message'); [Console]::Out.Flush()
[Console]::Error.WriteLine('fake codex event stream'); [Console]::Error.Flush()
if ($env:FAKE_CODEX_SLEEP) { Start-Sleep -Seconds ([int] $env:FAKE_CODEX_SLEEP) }
$out = ''
for ($i = 0; $i -lt $argv.Count - 1; $i++) { if ($argv[$i] -eq '-o') { $out = $argv[$i + 1] } }
if ($out) {
    $body = 'fake review body'
    if ($env:FAKE_CODEX_RESULT) { $body = $env:FAKE_CODEX_RESULT }
    [System.IO.File]::WriteAllText($out, $body, $utf8NoBom)
}
$code = 0
if ($env:FAKE_CODEX_EXIT) { $code = [int] $env:FAKE_CODEX_EXIT }
exit $code
'@
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'bin/codex-fake.ps1'), $fakeLogic, $utf8NoBom)

    if (Test-OnWindowsHost) {
        # Windows resolves codex.cmd via PATHEXT. UNVERIFIED on a Windows host.
        $shim = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0codex-fake.ps1`" %*`r`n"
        [System.IO.File]::WriteAllText((Join-Path $sandbox 'bin/codex.cmd'), $shim, $utf8NoBom)
    }
    else {
        $shim = "#!/usr/bin/env bash`nexec pwsh -NoProfile -File `"`$(dirname `"`$0`")/codex-fake.ps1`" `"`$@`"`n"
        $shimPath = Join-Path $sandbox 'bin/codex'
        [System.IO.File]::WriteAllText($shimPath, $shim, $utf8NoBom)
        & chmod +x $shimPath
    }
    return $sandbox
}

function Invoke-Runner {
    # Invoke-Runner <sandbox> <args> [<env overrides>] -> @{ ExitCode; StdOut; StdErr }
    param([string] $Sandbox, [string[]] $RunnerArgs, [hashtable] $Overrides = @{})

    $saved = @{}
    foreach ($name in @('PATH','TMPDIR','TEMP','TMP','FAKE_CODEX_ARGV','FAKE_CODEX_STDIN',
                        'FAKE_CODEX_SLEEP','FAKE_CODEX_EXIT','FAKE_CODEX_RESULT',
                        'SUPERARTES_CODEX_POLL_INTERVAL')) {
        $saved[$name] = (Get-Item -Path ("env:" + $name) -ErrorAction SilentlyContinue).Value
    }

    $env:PATH = (Join-Path $Sandbox 'bin') + [System.IO.Path]::PathSeparator + $saved['PATH']
    # TMP as well as TEMP: Win32 GetTempPath reads TMP first, so setting only TEMP
    # would isolate nothing on Windows and would make the cross-temp discard test
    # a vacuous pass, its "different TEMP" being the same directory as before.
    $env:TMPDIR = Join-Path $Sandbox 'tmp'
    $env:TEMP = Join-Path $Sandbox 'tmp'
    $env:TMP = Join-Path $Sandbox 'tmp'
    $env:FAKE_CODEX_ARGV = Join-Path $Sandbox 'argv'
    $env:FAKE_CODEX_STDIN = Join-Path $Sandbox 'stdin'
    $env:FAKE_CODEX_SLEEP = ''
    $env:FAKE_CODEX_EXIT = '0'
    $env:FAKE_CODEX_RESULT = ''
    $env:SUPERARTES_CODEX_POLL_INTERVAL = '1'
    foreach ($key in $Overrides.Keys) { Set-Item -Path ("env:" + $key) -Value $Overrides[$key] }

    $outFile = Join-Path $Sandbox 'out.txt'
    $errFile = Join-Path $Sandbox 'err.txt'

    # Quote every element: Start-Process joins -ArgumentList with spaces and does
    # not quote, so a sandbox path containing a space would split into two args.
    # -ExecutionPolicy Bypass unconditionally. It is per-process and NOT inherited,
    # so without it these children run under the machine policy — Restricted by
    # default on Windows clients — and every assertion fails for a reason that has
    # nothing to do with the runner. Linux pwsh accepts and ignores the switch.
    $quoted = @()
    foreach ($item in (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Runner) + $RunnerArgs)) {
        if ($item -match '\s') { $quoted += ('"' + $item + '"') } else { $quoted += $item }
    }

    # -PassThru WITHOUT -Wait, then WaitForExit on the direct child only.
    # Start-Process -Wait waits for the whole process tree on Windows, via a job
    # object that no redirect can opt out of, so it would block here until the fake
    # reviewer's sleep elapsed — inverting every "unfinished run" assertion. The
    # runner's own worker keeps -Wait, because blocking on the tree is what a
    # worker is for.
    $proc = Start-Process -FilePath ((Get-Process -Id $PID).Path) -ArgumentList $quoted `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $proc.WaitForExit()

    $result = [pscustomobject] @{
        ExitCode = $proc.ExitCode
        StdOut   = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        StdErr   = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    }

    foreach ($name in $saved.Keys) { Set-Item -Path ("env:" + $name) -Value $saved[$name] }
    return $result
}

function Get-RunDir {
    param([string] $StdOut)
    if ($StdOut -match 'RUN_DIR=(.+)') { return $Matches[1].Trim() }
    return ''
}

function Get-RunDirOrFail {
    # Without this gate an empty run directory makes later assertions pass
    # vacuously: Test-Path on '' is false, so "the directory is gone" succeeds
    # for a run that never started. A suite that cannot fail is worse than none.
    param([string] $Label, [string] $StdOut)
    $dir = Get-RunDir $StdOut
    if ([string]::IsNullOrWhiteSpace($dir)) {
        Fail $Label 'no RUN_DIR was printed'
        return ''
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Fail $Label "RUN_DIR is not a directory: $dir"
        return ''
    }
    Pass $Label
    return $dir
}

function Wait-Sentinel {
    param([string] $RunDir, [int] $Tries = 400)
    for ($i = 0; $i -lt $Tries; $i++) {
        if (Test-Path -LiteralPath (Join-Path $RunDir 'exit-code') -PathType Leaf) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# --------------------------------------------------------------------------

function Test-Usage {
    $sandbox = New-Sandbox
    AssertStatus 'no subcommand exits 64' 64 (Invoke-Runner $sandbox @()).ExitCode
    AssertStatus 'unknown subcommand exits 64' 64 (Invoke-Runner $sandbox @('nonsense')).ExitCode
    AssertStatus 'absent work directory exits 64' 64 `
        (Invoke-Runner $sandbox @('start', 'review', (Join-Path $sandbox 'nope'), 'uncommitted')).ExitCode
    AssertStatus 'absent prompt file exits 64' 64 `
        (Invoke-Runner $sandbox @('start', 'prompt', (Join-Path $sandbox 'work'), (Join-Path $sandbox 'nope.md'))).ExitCode
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-PromptLifecycle {
    $sandbox = New-Sandbox
    $promptFile = Join-Path $sandbox 'prompt.md'
    [System.IO.File]::WriteAllText($promptFile, 'review this document')

    $r = Invoke-Runner $sandbox @('start', 'prompt', (Join-Path $sandbox 'work'), $promptFile)
    AssertStatus 'start prompt exits 0' 0 $r.ExitCode
    AssertContains 'start prompt prints RUN_DIR' 'RUN_DIR=' $r.StdOut

    $runDir = Get-RunDirOrFail 'start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    AssertContains 'prompt is copied into the run directory' 'review this document' `
        (Get-Content -LiteralPath (Join-Path $runDir 'prompt') -Raw)

    if (Wait-Sentinel $runDir) { Pass 'prompt run finishes' } else { Fail 'prompt run finishes' 'no sentinel' }

    AssertContains 'the prompt is fed to codex on stdin' 'review this document' `
        (Get-Content -LiteralPath (Join-Path $sandbox 'stdin') -Raw)

    # Exact vector, not a substring: a flag drifting to the wrong position is
    # precisely the defect class an earlier review already caught here.
    $argv = @((Get-Content -LiteralPath (Join-Path $sandbox 'argv')) | Where-Object { $_ -ne '' })
    $expectedArgv = @('exec', '-', '-s', 'read-only', '--skip-git-repo-check', '-o', (Join-Path $runDir 'result'))
    AssertEquals 'prompt mode builds the exact argument vector' `
        ($expectedArgv -join '|') ($argv -join '|')
    AssertEquals 'result holds the review body' 'fake review body' `
        (Get-Content -LiteralPath (Join-Path $runDir 'result') -Raw)
    AssertContains 'stdout captures the final message' 'fake codex final message' `
        (Get-Content -LiteralPath (Join-Path $runDir 'log') -Raw)
    AssertContains 'stderr captures the event stream' 'fake codex event stream' `
        (Get-Content -LiteralPath (Join-Path $runDir 'err-log') -Raw)

    $s = Invoke-Runner $sandbox @('status', $runDir)
    AssertStatus 'status of a finished run exits 0' 0 $s.ExitCode
    AssertContains 'status reports done' 'STATE=done' $s.StdOut
    AssertContains 'status reports exit code' 'EXIT_CODE=0' $s.StdOut
    AssertAbsent 'a finished run reports no launch error' 'LAUNCH_ERROR=' $s.StdOut

    $sentinel = (Get-Content -LiteralPath (Join-Path $runDir 'exit-code') -Raw).Trim()
    if ($sentinel -match '^[0-9]+$') { Pass 'exit-code holds a bare integer' }
    else { Fail 'exit-code holds a bare integer' "got '$sentinel'" }

    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-NonZeroExit {
    $sandbox = New-Sandbox
    $promptFile = Join-Path $sandbox 'p.md'
    [System.IO.File]::WriteAllText($promptFile, 'x')
    $r = Invoke-Runner $sandbox @('start', 'prompt', (Join-Path $sandbox 'work'), $promptFile) @{ FAKE_CODEX_EXIT = '7' }
    $runDir = Get-RunDirOrFail 'start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    Wait-Sentinel $runDir | Out-Null
    AssertEquals 'non-zero reviewer exit is recorded' '7' `
        (Get-Content -LiteralPath (Join-Path $runDir 'exit-code') -Raw).Trim()
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-ReviewScopes {
    foreach ($case in @(
        @{ Scope = 'uncommitted'; Extra = @(); Middle = @('--uncommitted') },
        @{ Scope = 'base'; Extra = @('master'); Middle = @('--base', 'master') },
        @{ Scope = 'commit'; Extra = @('deadbeef'); Middle = @('--commit', 'deadbeef') }
    )) {
        $sandbox = New-Sandbox
        $runnerArgs = @('start', 'review', (Join-Path $sandbox 'work'), $case.Scope) + $case.Extra
        $r = Invoke-Runner $sandbox $runnerArgs
        AssertStatus ($case.Scope + ' scope starts') 0 $r.ExitCode

        $runDir = Get-RunDirOrFail ($case.Scope + ' printed a usable RUN_DIR') $r.StdOut
        if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; continue }
        Wait-Sentinel $runDir | Out-Null

        # Assert on the argument vector the FAKE received, not on the runner's own
        # cmd file — otherwise the runner is grading its own homework.
        $argv = @((Get-Content -LiteralPath (Join-Path $sandbox 'argv')) | Where-Object { $_ -ne '' })
        $expected = @('exec', '-s', 'read-only', 'review') + $case.Middle +
                    @('--skip-git-repo-check', '-o', (Join-Path $runDir 'result'))
        AssertEquals ($case.Scope + ' builds the exact argument vector') `
            ($expected -join '|') ($argv -join '|')
        Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
    }
}

function Test-ScopeValidation {
    $sandbox = New-Sandbox
    $work = Join-Path $sandbox 'work'
    AssertStatus 'uncommitted rejects a scope value' 64 (Invoke-Runner $sandbox @('start','review',$work,'uncommitted','extra')).ExitCode
    AssertStatus 'base requires a scope value' 64 (Invoke-Runner $sandbox @('start','review',$work,'base')).ExitCode
    AssertStatus 'commit requires a scope value' 64 (Invoke-Runner $sandbox @('start','review',$work,'commit')).ExitCode
    AssertStatus 'unknown scope kind exits 64' 64 (Invoke-Runner $sandbox @('start','review',$work,'nonsense')).ExitCode
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-StatusAndWait {
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start','review',(Join-Path $sandbox 'work'),'uncommitted') @{ FAKE_CODEX_SLEEP = '12' }
    $runDir = Get-RunDirOrFail 'start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }

    $s = Invoke-Runner $sandbox @('status', $runDir)
    AssertStatus 'status of an unfinished run exits 3' 3 $s.ExitCode
    AssertContains 'status names the state honestly' 'STATE=not-recorded' $s.StdOut

    AssertStatus 'wait exits 3 when it times out' 3 (Invoke-Runner $sandbox @('wait', $runDir, '2')).ExitCode

    $w = Invoke-Runner $sandbox @('wait', $runDir, '60')
    AssertStatus 'wait exits 0 once the run finishes' 0 $w.ExitCode
    AssertContains 'wait reports done' 'STATE=done' $w.StdOut

    AssertStatus 'wait rejects a non-numeric timeout' 64 (Invoke-Runner $sandbox @('wait', $runDir, 'soon')).ExitCode
    AssertStatus 'status of a missing run directory exits 65' 65 `
        (Invoke-Runner $sandbox @('status', (Join-Path $sandbox 'not-a-run'))).ExitCode
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-Discard {
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start','review',(Join-Path $sandbox 'work'),'uncommitted') @{ FAKE_CODEX_SLEEP = '12' }
    $runDir = Get-RunDirOrFail 'start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }

    AssertStatus 'discard of an unfinished run exits 66' 66 (Invoke-Runner $sandbox @('discard', $runDir)).ExitCode
    if (Test-Path -LiteralPath $runDir) { Pass 'a refused discard leaves the run intact' }
    else { Fail 'a refused discard leaves the run intact' 'directory was removed' }

    $d = Invoke-Runner $sandbox @('discard', $runDir, '--force')
    AssertStatus 'forced discard exits 0' 0 $d.ExitCode
    AssertContains 'discard reports its state' 'STATE=discarded' $d.StdOut
    if (Test-Path -LiteralPath $runDir) { Fail 'forced discard removes the run' 'directory survived' }
    else { Pass 'forced discard removes the run' }
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-DiscardRejectsTraversal {
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start','review',(Join-Path $sandbox 'work'),'uncommitted')
    $runDir = Get-RunDirOrFail 'start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    Wait-Sentinel $runDir | Out-Null

    $victim = Join-Path (Join-Path $sandbox 'tmp') 'victim'
    New-Item -ItemType Directory -Path $victim | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $victim 'started-at'), "0`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $victim 'mode'), "review`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $victim 'exit-code'), "0`n", $utf8NoBom)

    $traversal = Join-Path $runDir '../../victim'
    AssertStatus 'discard rejects a traversal path' 65 (Invoke-Runner $sandbox @('discard', $traversal)).ExitCode
    if (Test-Path -LiteralPath $victim) { Pass 'the traversal target survives' }
    else { Fail 'the traversal target survives' 'victim was removed' }

    AssertStatus 'discard rejects a directory outside the runs root' 65 `
        (Invoke-Runner $sandbox @('discard', $victim)).ExitCode
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-MissingCodex {
    # PATH holding only a pwsh symlink, so `codex` genuinely cannot be resolved.
    $sandbox = New-Sandbox
    $bare = Join-Path $sandbox 'bare'
    New-Item -ItemType Directory -Path $bare | Out-Null
    $psExe = (Get-Process -Id $PID).Path
    if (-not (Test-OnWindowsHost)) { & ln -s $psExe (Join-Path $bare 'pwsh') }

    $savedPath = $env:PATH
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMPDIR
    $savedTmpWin = $env:TMP
    $env:PATH = $bare
    $env:TEMP = Join-Path $sandbox 'tmp'
    $env:TMPDIR = Join-Path $sandbox 'tmp'
    $env:TMP = Join-Path $sandbox 'tmp'
    $outFile = Join-Path $sandbox 'mc-out.txt'
    $errFile = Join-Path $sandbox 'mc-err.txt'
    $proc = Start-Process -FilePath $psExe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Runner, 'start', 'review', (Join-Path $sandbox 'work'), 'uncommitted') `
        -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $proc.WaitForExit()
    $env:PATH = $savedPath; $env:TEMP = $savedTemp; $env:TMPDIR = $savedTmp; $env:TMP = $savedTmpWin

    AssertStatus 'missing codex exits 127' 127 $proc.ExitCode
    AssertContains 'missing codex explains itself' 'not on PATH' `
        (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-HelpAndPollInterval {
    $sandbox = New-Sandbox
    foreach ($flag in @('-h', '--help')) {
        $r = Invoke-Runner $sandbox @($flag)
        AssertStatus "$flag exits 0" 0 $r.ExitCode
        AssertContains "$flag prints usage on stdout" 'invoke-codex.ps1 start prompt' $r.StdOut
        AssertEquals "$flag writes nothing to stderr" '' "$($r.StdErr)".Trim()
    }
    # Emptiness is asserted through string interpolation, never a [string] cast.
    # Get-Content -Raw on an EMPTY file returns AutomationNull; casting that to
    # [string] stays null, so .Trim() throws and the assertion is skipped WITHOUT
    # being counted — the suite then reports fewer assertions and stays green.
    $r = Invoke-Runner $sandbox @('nonsense')
    AssertContains 'a usage error goes to stderr' 'invoke-codex.ps1 start prompt' $r.StdErr
    AssertEquals 'a usage error writes nothing to stdout' '' "$($r.StdOut)".Trim()

    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-PollIntervalValidation {
    # The poll interval feeds one loop, in `wait`, and is validated there and
    # nowhere else. Validating it at script scope instead would fail every OTHER
    # subcommand too — answering `discard` with a complaint about a poll interval
    # — so each of these cases is asserted twice: rejected by `wait`, ignored by
    # the subcommands that never read it.
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start', 'review', (Join-Path $sandbox 'work'), 'uncommitted')
    $runDir = Get-RunDirOrFail 'poll-interval start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    Wait-Sentinel $runDir | Out-Null

    foreach ($bad in @('0', 'soon', '2x')) {
        AssertStatus "wait rejects poll interval '$bad'" 64 `
            (Invoke-Runner $sandbox @('wait', $runDir, '4') @{ SUPERARTES_CODEX_POLL_INTERVAL = $bad }).ExitCode
        AssertStatus "status ignores poll interval '$bad'" 0 `
            (Invoke-Runner $sandbox @('status', $runDir) @{ SUPERARTES_CODEX_POLL_INTERVAL = $bad }).ExitCode
    }

    # Leading zeros are accepted, because the shell sibling accepts them.
    AssertStatus 'wait accepts a leading-zero poll interval' 0 `
        (Invoke-Runner $sandbox @('wait', $runDir, '4') @{ SUPERARTES_CODEX_POLL_INTERVAL = '02' }).ExitCode
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-MalformedAndForeignRunDirs {
    $sandbox = New-Sandbox
    $runsRoot = Join-Path (Join-Path $sandbox 'tmp') 'superartes-codex-runs'
    New-Item -ItemType Directory -Path $runsRoot -Force | Out-Null

    # Exists, but carries none of the marker files this runner writes.
    $malformed = Join-Path $runsRoot 'run.malformed'
    New-Item -ItemType Directory -Path $malformed | Out-Null
    AssertStatus 'status of a malformed run directory exits 65' 65 (Invoke-Runner $sandbox @('status', $malformed)).ExitCode
    AssertStatus 'discard of a malformed run directory exits 65' 65 (Invoke-Runner $sandbox @('discard', $malformed)).ExitCode

    # started-at but no mode — the shape a start killed between those two writes
    # leaves behind. BOTH markers are required before discard will rm -rf, so this
    # must be refused rather than deleted.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $halfWritten = Join-Path $runsRoot 'run.halfwritten'
    New-Item -ItemType Directory -Path $halfWritten | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $halfWritten 'started-at'), "0`n", $utf8NoBom)
    AssertStatus 'status of a run directory without mode exits 65' 65 (Invoke-Runner $sandbox @('status', $halfWritten)).ExitCode
    $d = Invoke-Runner $sandbox @('discard', $halfWritten, '--force')
    AssertStatus 'discard of a run directory without mode exits 65' 65 $d.ExitCode
    AssertContains 'the malformed message names both markers' 'missing started-at or mode' $d.StdErr
    if (Test-Path -LiteralPath $halfWritten) { Pass 'a half-written run directory survives discard' }
    else { Fail 'a half-written run directory survives discard' 'it was removed' }

    # A direct child of the runs root that this runner did not create.
    $foreign = Join-Path $runsRoot 'somebody-elses-data'
    New-Item -ItemType Directory -Path $foreign | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    foreach ($f in @(@('started-at', '0'), @('mode', 'review'), @('exit-code', '0'))) {
        [System.IO.File]::WriteAllText((Join-Path $foreign $f[0]), $f[1] + "`n", $utf8NoBom)
    }
    AssertStatus 'discard refuses a foreign directory in the runs root' 65 (Invoke-Runner $sandbox @('discard', $foreign)).ExitCode
    if (Test-Path -LiteralPath $foreign) { Pass 'the foreign directory survives' }
    else { Fail 'the foreign directory survives' 'it was removed' }
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-DiscardAcrossTempDirs {
    # Every subcommand is a separate process for an agent, so discard must not
    # depend on the ambient TEMP matching the one start used.
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start', 'review', (Join-Path $sandbox 'work'), 'uncommitted')
    $runDir = Get-RunDirOrFail 'cross-TEMP start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    Wait-Sentinel $runDir | Out-Null

    $elsewhere = Join-Path $sandbox 'elsewhere'
    New-Item -ItemType Directory -Path $elsewhere | Out-Null
    # TMP as well, or on Windows this "different TEMP" is not different at all:
    # GetTempPath reads TMP first, so the runner would keep using the same
    # directory and the test would pass without ever crossing a temp boundary.
    $d = Invoke-Runner $sandbox @('discard', $runDir) @{ TEMP = $elsewhere; TMPDIR = $elsewhere; TMP = $elsewhere }
    AssertStatus 'discard works from a different TEMP' 0 $d.ExitCode
    if (Test-Path -LiteralPath $runDir) { Fail 'cross-TEMP discard removes the run' 'directory survived' }
    else { Pass 'cross-TEMP discard removes the run' }
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-ForcePosition {
    # A short sleep, not a long one: the fake reviewer keeps its working directory
    # INSIDE the sandbox, and on Windows a directory cannot be removed while it is
    # some process's current directory. Long enough that the run is still
    # unfinished when discard runs, short enough to be over before teardown.
    $sandbox = New-Sandbox
    foreach ($order in @('after', 'before')) {
        $r = Invoke-Runner $sandbox @('start', 'review', (Join-Path $sandbox 'work'), 'uncommitted') @{ FAKE_CODEX_SLEEP = '2' }
        $runDir = Get-RunDirOrFail "$order-form start printed a usable RUN_DIR" $r.StdOut
        if (-not $runDir) { continue }
        if ($order -eq 'after') { $d = Invoke-Runner $sandbox @('discard', $runDir, '--force') }
        else { $d = Invoke-Runner $sandbox @('discard', '--force', $runDir) }
        AssertStatus "--force $order the run directory works" 0 $d.ExitCode
        # Exit 0 alone would also be reported by a discard that removed nothing.
        if (Test-Path -LiteralPath $runDir) { Fail "--force $order removes the run" 'directory survived' }
        else { Pass "--force $order removes the run" }
    }
    Start-Sleep -Seconds 3
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-WorkerErrIsClean {
    # worker-err is written by the WORKER ITSELF, and only when something has gone
    # wrong. It is not fed by any stream redirect: the parent's redirects (to
    # worker-log and worker-stderr) exist solely to detach the worker from the
    # caller's console, and cannot carry anything, because Start-Process pumps a
    # redirected stream through the parent and the parent exits immediately.
    # A healthy run must therefore leave worker-err empty or absent, or
    # LAUNCH_ERROR would fire spuriously on every review.
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start', 'review', (Join-Path $sandbox 'work'), 'uncommitted')
    $runDir = Get-RunDirOrFail 'worker-err check printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    Wait-Sentinel $runDir | Out-Null

    $workerErr = Join-Path $runDir 'worker-err'
    $size = 0
    if (Test-Path -LiteralPath $workerErr -PathType Leaf) { $size = (Get-Item -LiteralPath $workerErr).Length }
    AssertEquals 'a healthy run leaves worker-err empty' '0' ([string] $size)
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-WorkerFailureIsSurfaced {
    # A worker that dies must not look like a reviewer still working.
    #
    # worker-err exists for exactly one reason: without it, a worker that failed
    # and a worker that is busy are indistinguishable, and the controller waits
    # forever. So the failure here is made to happen FOR REAL, rather than by
    # hand-writing worker-err — which would only test how status formats a file
    # the test itself created.
    #
    # The shell sibling forces its equivalent with a failing setsid shim on PATH.
    # There is no PowerShell analogue: the worker's interpreter is resolved to an
    # absolute path, so no PATH entry can intercept it. Instead the worker is made
    # to fail at the write it exists to perform — the sentinel — by putting a
    # DIRECTORY where exit-code.tmp must go while the fake reviewer is still
    # sleeping. The write throws, and the worker's own try/catch is what records
    # the reason: it calls Write-WorkerError, which WRITES worker-err directly.
    #
    # Nothing about this arrives through the parent's stream redirection, which
    # carries nothing at all once the parent has exited. That is precisely why the
    # worker's wrap exists, and why deleting it as redundant would restore the
    # silent-hang state this test was written to prevent: no sentinel, no
    # explanation, and a controller waiting forever.
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start', 'review', (Join-Path $sandbox 'work'), 'uncommitted') @{ FAKE_CODEX_SLEEP = '3' }
    $runDir = Get-RunDirOrFail 'worker-failure start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    New-Item -ItemType Directory -Path (Join-Path $runDir 'exit-code.tmp') | Out-Null

    # A bounded ceiling well past the fake's sleep: the sentinel must never
    # arrive at all, not merely be late.
    if (Wait-Sentinel $runDir 90) {
        Fail 'a failed worker never records completion' 'exit-code appeared anyway'
    }
    else { Pass 'a failed worker never records completion' }

    $workerErr = Join-Path $runDir 'worker-err'
    $size = 0
    if (Test-Path -LiteralPath $workerErr -PathType Leaf) { $size = (Get-Item -LiteralPath $workerErr).Length }
    if ($size -gt 0) { Pass 'the worker records its own failure in worker-err' }
    else { Fail 'the worker records its own failure in worker-err' 'worker-err is empty' }

    # And the parent's redirect target stays empty, as the pump argument predicts.
    $workerStderr = Join-Path $runDir 'worker-stderr'
    $redirectSize = 0
    if (Test-Path -LiteralPath $workerStderr -PathType Leaf) { $redirectSize = (Get-Item -LiteralPath $workerStderr).Length }
    AssertEquals 'the parent redirect target carries nothing' '0' ([string] $redirectSize)

    $s = Invoke-Runner $sandbox @('status', $runDir)
    AssertStatus 'status of a failed worker exits 3' 3 $s.ExitCode
    AssertContains 'status surfaces the worker error' 'LAUNCH_ERROR=' $s.StdOut
    AssertContains 'a failed run is not called running' 'STATE=not-recorded' $s.StdOut
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-StatusReportsProvenance {
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start', 'review', (Join-Path $sandbox 'work'), 'uncommitted')
    $runDir = Get-RunDirOrFail 'provenance check printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    Wait-Sentinel $runDir | Out-Null
    $s = Invoke-Runner $sandbox @('status', $runDir)
    AssertContains 'status names the working tree' 'WORK_DIR=' $s.StdOut
    AssertContains 'status names the command it ran' 'CMD=' $s.StdOut

    # One parser must read both runners, so the KEY SEQUENCE is part of the
    # contract rather than an implementation detail. This is the shell sibling's.
    $keys = @()
    foreach ($line in ($s.StdOut -split "`n")) {
        if ($line.Trim() -match '^([A-Z_]+)=') { $keys += $Matches[1] }
    }
    $expected = @('RUN_DIR', 'MODE', 'WORK_DIR', 'CMD', 'ELAPSED_SECONDS', 'RESULT',
                  'STDOUT_LOG', 'STDERR_LOG', 'STATE', 'EXIT_CODE', 'RESULT_BYTES')
    AssertEquals 'status prints the sibling field order' ($expected -join '|') ($keys -join '|')
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-RecoveredRunReportsEmptyMetadata {
    # A run directory found again after the fact may hold only its markers. The
    # shell sibling still prints WORK_DIR and CMD, empty, because a controller
    # parses a fixed field list; printing them conditionally would make an
    # incomplete run parse as a different shape of record.
    $sandbox = New-Sandbox
    $runsRoot = Join-Path (Join-Path $sandbox 'tmp') 'superartes-codex-runs'
    New-Item -ItemType Directory -Path $runsRoot -Force | Out-Null
    $partial = Join-Path $runsRoot 'run.partial'
    New-Item -ItemType Directory -Path $partial | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $partial 'started-at'), "0`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $partial 'mode'), "review`n", $utf8NoBom)

    $s = Invoke-Runner $sandbox @('status', $partial)
    AssertStatus 'status of a bare run directory exits 3' 3 $s.ExitCode
    AssertContains 'WORK_DIR is printed even when unrecorded' 'WORK_DIR=' $s.StdOut
    AssertContains 'CMD is printed even when unrecorded' 'CMD=' $s.StdOut
    AssertContains 'a bare run directory is not called running' 'STATE=not-recorded' $s.StdOut
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-RunDirectoryContract {
    # The two run-directory files that exist only because the worker is a
    # separately launched process, and both of which have already been a Critical
    # defect: null-stdin (a real file, because Start-Process pre-validates every
    # redirect path with File.Exists and \\.\NUL is not a file) and codex-path
    # (the resolved program, because the worker's redirects rule out PATHEXT).
    $sandbox = New-Sandbox
    $r = Invoke-Runner $sandbox @('start', 'review', (Join-Path $sandbox 'work'), 'uncommitted')
    $runDir = Get-RunDirOrFail 'run-contract start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    Wait-Sentinel $runDir | Out-Null

    $nullStdin = Join-Path $runDir 'null-stdin'
    if (Test-Path -LiteralPath $nullStdin -PathType Leaf) { Pass 'a null stdin file is created in the run directory' }
    else { Fail 'a null stdin file is created in the run directory' "not found: $nullStdin" }
    AssertEquals 'the null stdin file is empty' '0' ([string] (Get-Item -LiteralPath $nullStdin).Length)
    AssertEquals 'review mode records the null stdin file as its stdin' $nullStdin `
        "$(Get-Content -LiteralPath (Join-Path $runDir 'stdin') -Raw)".Trim()
    # Trimmed, not compared raw: PowerShell pumps a redirected stdin file into the
    # child and terminates it with a newline, so an empty file arrives as "`n"
    # where the shell sibling's /dev/null arrives as nothing at all. What matters
    # is that no CONTENT reaches the reviewer.
    AssertEquals 'the reviewer receives no stdin content in review mode' '' `
        "$(Get-Content -LiteralPath (Join-Path $sandbox 'stdin') -Raw)".Trim()

    # The fake is reached through codex.cmd on Windows and a bash shim elsewhere;
    # either way the recorded path must be the resolved program, not a bare name.
    $shimName = 'codex'
    if (Test-OnWindowsHost) { $shimName = 'codex.cmd' }
    AssertEquals 'the resolved codex program is recorded for the worker' `
        (Join-Path (Join-Path $sandbox 'bin') $shimName) `
        "$(Get-Content -LiteralPath (Join-Path $runDir 'codex-path') -Raw)".Trim()
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-SymlinkedWorkDirIsResolved {
    # A symlinked checkout must be recorded as the path it points AT, the way the
    # shell sibling's `cd && pwd -P` records it. Resolve-Path alone normalises but
    # does not resolve, so this silently regresses to the link path if anyone
    # simplifies Resolve-PhysicalPath away.
    #
    # Asserted by comparing two runs rather than against a path this test computes
    # itself: the temp directory may sit behind a link of its own on some hosts,
    # and self-consistency between the two forms is the property that matters.
    $sandbox = New-Sandbox
    $work = Join-Path $sandbox 'work'
    $link = Join-Path $sandbox 'work-link'

    $linked = $true
    try {
        if (Test-OnWindowsHost) { New-Item -ItemType SymbolicLink -Path $link -Target $work -ErrorAction Stop | Out-Null }
        else { & ln -s $work $link; if ($LASTEXITCODE -ne 0) { $linked = $false } }
    }
    catch { $linked = $false }

    if (-not $linked) {
        # Creating a symbolic link on Windows needs Developer Mode or elevation.
        # Announced rather than silently passed: a skipped check must never look
        # like a satisfied one.
        Write-Host 'SKIP: symlinked work directory (cannot create a symbolic link on this host)'
        Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
        return
    }

    $direct = Invoke-Runner $sandbox @('start', 'review', $work, 'uncommitted')
    $directDir = Get-RunDirOrFail 'direct work directory starts' $direct.StdOut
    $viaLink = Invoke-Runner $sandbox @('start', 'review', $link, 'uncommitted')
    $linkDir = Get-RunDirOrFail 'symlinked work directory starts' $viaLink.StdOut
    if ((-not $directDir) -or (-not $linkDir)) {
        Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
        return
    }
    Wait-Sentinel $directDir | Out-Null
    Wait-Sentinel $linkDir | Out-Null

    $recordedDirect = "$(Get-Content -LiteralPath (Join-Path $directDir 'work-dir') -Raw)".Trim()
    $recordedLink = "$(Get-Content -LiteralPath (Join-Path $linkDir 'work-dir') -Raw)".Trim()
    AssertEquals 'a symlinked work directory records the physical path' $recordedDirect $recordedLink
    AssertAbsent 'the recorded work directory is not the link' 'work-link' $recordedLink
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

function Test-PromptModeStdin {
    # Prompt mode feeds codex the copied prompt, not the null stdin — the run
    # directory has both files and they must not be confused.
    $sandbox = New-Sandbox
    $promptFile = Join-Path $sandbox 'p.md'
    [System.IO.File]::WriteAllText($promptFile, 'prompt body')
    $r = Invoke-Runner $sandbox @('start', 'prompt', (Join-Path $sandbox 'work'), $promptFile)
    $runDir = Get-RunDirOrFail 'prompt-stdin start printed a usable RUN_DIR' $r.StdOut
    if (-not $runDir) { Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue; return }
    Wait-Sentinel $runDir | Out-Null
    AssertEquals 'prompt mode records the prompt as its stdin' (Join-Path $runDir 'prompt') `
        "$(Get-Content -LiteralPath (Join-Path $runDir 'stdin') -Raw)".Trim()
    if (Test-Path -LiteralPath (Join-Path $runDir 'null-stdin') -PathType Leaf) {
        Pass 'prompt mode still creates a null stdin for the worker'
    }
    else { Fail 'prompt mode still creates a null stdin for the worker' 'null-stdin not found' }
    Remove-Item -Recurse -Force -LiteralPath $sandbox -ErrorAction SilentlyContinue
}

Test-Usage
Test-MissingCodex
Test-HelpAndPollInterval
Test-PollIntervalValidation
Test-PromptLifecycle
Test-PromptModeStdin
Test-SymlinkedWorkDirIsResolved
Test-RunDirectoryContract
Test-NonZeroExit
Test-ReviewScopes
Test-ScopeValidation
Test-StatusAndWait
Test-Discard
Test-DiscardRejectsTraversal
Test-MalformedAndForeignRunDirs
Test-DiscardAcrossTempDirs
Test-ForcePosition
Test-WorkerErrIsClean
Test-WorkerFailureIsSurfaced
Test-StatusReportsProvenance
Test-RecoveredRunReportsEmptyMetadata

Write-Host ""
Write-Host "$($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -gt 0) { exit 1 }
exit 0
