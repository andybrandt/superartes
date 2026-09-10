# invoke-codex.ps1 — run a Codex review in the background for a Claude Code
# controller on Windows. Sibling of invoke-codex.sh: same subcommands, same run
# directory layout, same exit codes.
#
# Written for Windows PowerShell 5.1 (which ships with Windows) and PowerShell 7.
# It avoids 7-only syntax so a single file serves both.
#
# Commands:
#   invoke-codex.ps1 start prompt <work-dir> <prompt-file>
#   invoke-codex.ps1 start review <work-dir> uncommitted
#   invoke-codex.ps1 start review <work-dir> base   <base-ref>
#   invoke-codex.ps1 start review <work-dir> commit <commit-sha>
#   invoke-codex.ps1 status  <run-dir>
#   invoke-codex.ps1 wait    <run-dir> <timeout-seconds>
#   invoke-codex.ps1 discard <run-dir> [--force]
#   invoke-codex.ps1 --help
#
# Exit codes: 0 completion recorded, 3 not recorded, 64 usage, 65 bad run directory,
#             66 discard refused, 127 codex not found. 65 covers any case where
#             the run's storage is unusable: it could not be created, written to,
#             validated as a run directory this runner made, or removed — and the
#             case where the run exists but its worker could not be launched.
#
# `__run` is an internal subcommand. `start` re-invokes this script with it in a
# hidden window, and that hidden copy is what blocks on codex and writes the
# sentinel. Re-invoking the script beats assembling a long -Command string, which
# is where PowerShell quoting usually goes wrong.
#
# Deliberately no Set-StrictMode: this script reads $IsWindows, which does not
# exist on Windows PowerShell 5.1. Without strict mode it is simply $null there,
# which is what Test-OnWindows below relies on.

$ErrorActionPreference = 'Stop'

$RunsDirName = 'superartes-codex-runs'
$RunsRoot = Join-Path ([System.IO.Path]::GetTempPath()) $RunsDirName

# Seconds between sentinel checks in `wait`. Overridable for the test suite only,
# and held as a STRING here because it is validated in Wait-ForRun, which is its
# only consumer. Validating it at script scope instead would fail `start`,
# `status` and `discard` as well — on Windows only, since the shell sibling
# validates inside `wait` — answering a request to discard a run with a complaint
# about a poll interval the caller never mentioned.
$PollInterval = '2'
if ($env:SUPERARTES_CODEX_POLL_INTERVAL) {
    $PollInterval = $env:SUPERARTES_CODEX_POLL_INTERVAL
}

function Test-OnWindows {
    # True on Windows PowerShell 5.1 (PSEdition Desktop) and on PowerShell 7 for
    # Windows; false on PowerShell 7 for Linux or macOS, where this script is only
    # ever exercised by its own test suite.
    return ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
}

function Resolve-PhysicalPath {
    # Absolute AND physical, matching the shell sibling's `cd "$dir" && pwd -P`.
    # An agent records a printed path as a literal string and reuses it from a
    # different process on a later tool call, so a symlinked checkout must be
    # recorded identically by both runners. Resolve-Path normalises but never
    # resolves a link, which is why it is not enough on its own.
    #
    # PowerShell 7 resolves the whole chain through ResolveLinkTarget. Windows
    # PowerShell 5.1 has no such method and falls back to the reparse point's own
    # target, which covers the final component — a junction or a directory
    # symlink, the usual case — and leaves intermediate links unresolved.
    param([string] $Path)
    $item = Get-Item -LiteralPath (Resolve-Path -LiteralPath $Path).ProviderPath -Force
    if ($item.PSObject.Methods.Name -contains 'ResolveLinkTarget') {
        $target = $item.ResolveLinkTarget($true)
        if ($target) { return $target.FullName }
        return $item.FullName
    }
    if ($item.Target) { return ([System.IO.Path]::GetFullPath(@($item.Target)[0])) }
    return $item.FullName
}

function Resolve-CodexPath {
    # Resolve `codex` to one absolute program path, in the parent, once. Returns
    # an empty string when it cannot be found.
    #
    # -CommandType Application earns its place twice over. It rejects aliases,
    # functions and .ps1 files — all of which a bare Get-Command accepts and the
    # worker could not launch — and it returns the actual program file, which for
    # the documented npm install route is codex.cmd.
    #
    # The worker cannot repeat this lookup for itself. Its stream redirects force
    # UseShellExecute=false, so Windows goes through CreateProcessW, which appends
    # only ".exe" and never consults PATHEXT: a bare "codex" resolves here and
    # fails there. Recording the resolved path is what closes that gap.
    $found = @(Get-Command 'codex' -CommandType Application -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { return '' }
    return $found[0].Source
}

function Get-HostExecutable {
    # The interpreter to re-invoke for the hidden worker. On 5.1 that is
    # powershell.exe from $PSHOME; on PowerShell 7 it is the running pwsh, which
    # is also what makes the launch path testable on Linux.
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        return (Join-Path $PSHOME 'powershell.exe')
    }
    return (Get-Process -Id $PID).Path
}

function Get-EpochSeconds {
    # Get-Date -UFormat %s returns a decimal on PowerShell 7 and an integer on
    # 5.1, so compute it explicitly instead.
    return [int] [Math]::Floor((Get-Date).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
}

function Write-Line {
    # All normal output goes straight to the console rather than the pipeline, so
    # a function's return value is only ever its exit code.
    #
    # The explicit Flush is required. When stdout is redirected to a file the
    # stream is buffered, and PowerShell's `exit` tears the process down without
    # flushing it — status would emit only its first line and the caller would
    # never see STATE=.
    param([string] $Text)
    [Console]::Out.WriteLine($Text)
    [Console]::Out.Flush()
}

function Get-UsageText {
    return @'
Usage:
  invoke-codex.ps1 start prompt <work-dir> <prompt-file>
  invoke-codex.ps1 start review <work-dir> uncommitted
  invoke-codex.ps1 start review <work-dir> base   <base-ref>
  invoke-codex.ps1 start review <work-dir> commit <commit-sha>
  invoke-codex.ps1 status  <run-dir>
  invoke-codex.ps1 wait    <run-dir> <timeout-seconds>
  invoke-codex.ps1 discard <run-dir> [--force]
  invoke-codex.ps1 --help
'@
}

function Write-Usage {
    # Asking for help is a success path and goes to stdout. The sibling
    # invoke-reviewer.sh behaves the same way; a controller written against one
    # runner should not trip on the other.
    [Console]::Out.WriteLine((Get-UsageText))
    [Console]::Out.Flush()
    exit 0
}

function Write-UsageError {
    [Console]::Error.WriteLine((Get-UsageText))
    exit 64
}

function Stop-WithError {
    param([int] $Code, [string] $Message)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Write-RunFile {
    # Write one line with no byte-order mark, so the contract the shell sibling
    # defines still holds: a bare integer in exit-code, a bare path in work-dir.
    param([string] $Path, [string] $Value)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value + "`n", $utf8NoBom)
}

function Read-RunFile {
    param([string] $Path)
    return ([System.IO.File]::ReadAllText($Path)).Trim()
}

function Read-RunFileOrEmpty {
    # For the status fields the shell sibling prints unconditionally with
    # `cat 2>/dev/null`: a missing file is an empty value, not an error.
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return (Read-RunFile $Path)
}

function Remove-RunDirectoryQuietly {
    # Best-effort cleanup on an error path, with `rm -rf` semantics: failing to
    # clean up must not turn a usage error into a stack trace and exit 1.
    param([string] $RunDir)
    Remove-Item -Recurse -Force -LiteralPath $RunDir -ErrorAction SilentlyContinue
}

function Select-Rest {
    # PowerShell 5.1 has no safe slice for an empty array, so guard it here once.
    #
    # PowerShell unwraps a single-element array when a function returns it, so a
    # one-element result arrives at the caller as a bare string — and $result[0]
    # then yields its first CHARACTER rather than the element. Every call site
    # therefore wraps this in @(), which re-wraps a scalar and leaves a real array
    # alone. Do NOT also return with the unary comma: the two mechanisms cancel
    # out, producing a one-element array whose element is the array you wanted.
    param([object[]] $Items, [int] $From)
    if ($null -eq $Items -or $Items.Count -le $From) { return @() }
    return @($Items[$From..($Items.Count - 1)])
}

function ConvertTo-ProcessArgument {
    # Start-Process joins -ArgumentList with spaces and does NOT quote the
    # elements, so anything containing whitespace must arrive already quoted.
    # A checkout or temp directory with a space in its name is the usual victim.
    param([string] $Value)
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

function Assert-RunDirectory {
    # Reject anything that is not a run directory this script created. BOTH marker
    # files are required, exactly as the shell sibling requires them: a directory
    # carrying only one of them has not earned the rm -rf that `discard` performs.
    # That shape is reachable, not theoretical — Start-Run writes started-at before
    # mode, so a start killed between those two lines leaves precisely it.
    param([string] $RunDir)
    if ([string]::IsNullOrWhiteSpace($RunDir)) { Write-UsageError }
    if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) {
        Stop-WithError 65 "not a run directory: $RunDir"
    }
    if ((-not (Test-Path -LiteralPath (Join-Path $RunDir 'started-at') -PathType Leaf)) -or
        (-not (Test-Path -LiteralPath (Join-Path $RunDir 'mode') -PathType Leaf))) {
        Stop-WithError 65 "run directory is malformed (missing started-at or mode): $RunDir"
    }
}

function Start-Run {
    param([string] $Mode, [string] $WorkDir, [object[]] $Rest)

    if ([string]::IsNullOrWhiteSpace($Mode) -or [string]::IsNullOrWhiteSpace($WorkDir)) {
        Write-UsageError
    }
    # Resolve codex here, once, and hand the answer to the worker in the run
    # directory. See Resolve-CodexPath: the worker cannot do this for itself.
    $codexPath = Resolve-CodexPath
    if ([string]::IsNullOrWhiteSpace($codexPath)) {
        Stop-WithError 127 'codex is not on PATH'
    }
    if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
        Stop-WithError 64 "work directory does not exist: $WorkDir"
    }
    try { $WorkDir = Resolve-PhysicalPath $WorkDir }
    catch { Stop-WithError 64 "cannot enter work directory: $WorkDir" }

    # Every storage failure below is a 65. Left unguarded these surface as exit 1
    # with a raw stack trace, which is outside this runner's documented contract
    # and tells a controller nothing it can act on.
    try { New-Item -ItemType Directory -Path $RunsRoot -Force | Out-Null }
    catch { Stop-WithError 65 "cannot create the runs root: $RunsRoot" }
    # A fixed, predictable name in a shared temp directory, holding repository
    # contents. On Windows the user's TEMP is already private; elsewhere, tighten
    # it explicitly rather than trusting the ambient umask.
    if (-not (Test-OnWindows)) {
        try { & chmod 700 $RunsRoot }
        catch { Stop-WithError 65 "cannot restrict the runs root: $RunsRoot" }
        if ($LASTEXITCODE -ne 0) { Stop-WithError 65 "cannot restrict the runs root: $RunsRoot" }
    }
    $runDir = Join-Path $RunsRoot ('run.' + [System.IO.Path]::GetRandomFileName().Replace('.', ''))
    try {
        New-Item -ItemType Directory -Path $runDir | Out-Null
        $runDir = Resolve-PhysicalPath $runDir
    }
    catch { Stop-WithError 65 'cannot create a run directory' }

    # An empty FILE, used as null stdin for the worker and, in review mode, for
    # codex itself. It has to be a real file: Start-Process pre-validates every
    # redirect path with File.Exists, and the Windows null device \\.\NUL is a DOS
    # device rather than a file, so naming it there makes the launch throw before
    # RUN_DIR is ever printed. A file also works identically on both platforms,
    # which /dev/null and \\.\NUL never could.
    $nullStdin = Join-Path $runDir 'null-stdin'
    try {
        $emptyEncoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($nullStdin, '', $emptyEncoding)
        Write-RunFile (Join-Path $runDir 'started-at') (Get-EpochSeconds)
        Write-RunFile (Join-Path $runDir 'mode') $Mode
        Write-RunFile (Join-Path $runDir 'work-dir') $WorkDir
        Write-RunFile (Join-Path $runDir 'codex-path') $codexPath
    }
    catch { Stop-WithError 65 "cannot write to the run directory: $runDir" }

    $resultPath = Join-Path $runDir 'result'
    $stdinPath = $nullStdin
    $argv = @()

    if ($Mode -eq 'prompt') {
        $promptFile = $Rest[0]
        if ([string]::IsNullOrWhiteSpace($promptFile)) {
            Remove-RunDirectoryQuietly $runDir
            Write-UsageError
        }
        if (-not (Test-Path -LiteralPath $promptFile -PathType Leaf)) {
            Remove-RunDirectoryQuietly $runDir
            Stop-WithError 64 "prompt file not found: $promptFile"
        }
        # Copy the prompt in so the caller may delete its own temporary copy as
        # soon as start returns, and the run stays self-contained.
        try { Copy-Item -LiteralPath $promptFile -Destination (Join-Path $runDir 'prompt') }
        catch {
            Remove-RunDirectoryQuietly $runDir
            Stop-WithError 65 'cannot copy the prompt file'
        }
        $stdinPath = Join-Path $runDir 'prompt'
        $argv = @('exec', '-', '-s', 'read-only', '--skip-git-repo-check', '-o', $resultPath)
    }
    elseif ($Mode -eq 'review') {
        # `codex exec review` has no -s/--sandbox flag of its own, but it does
        # NOT impose a read-only filesystem policy either: the review task forces
        # the approval policy to Never and inherits everything else. The sandbox
        # must therefore be set on the PARENT command, before `review`.
        # It also rejects a custom prompt combined with a scope flag, so no
        # prompt is composed for this mode.
        $scopeKind = $Rest[0]
        $scopeValue = $Rest[1]
        if ([string]::IsNullOrWhiteSpace($scopeKind)) {
            Remove-RunDirectoryQuietly $runDir
            Write-UsageError
        }
        if ($scopeKind -eq 'uncommitted') {
            if (-not [string]::IsNullOrWhiteSpace($scopeValue)) {
                Remove-RunDirectoryQuietly $runDir
                Stop-WithError 64 'uncommitted takes no scope value'
            }
            $argv = @('exec', '-s', 'read-only', 'review', '--uncommitted', '--skip-git-repo-check', '-o', $resultPath)
        }
        elseif ($scopeKind -eq 'base' -or $scopeKind -eq 'commit') {
            if ([string]::IsNullOrWhiteSpace($scopeValue)) {
                Remove-RunDirectoryQuietly $runDir
                Stop-WithError 64 "$scopeKind requires a scope value"
            }
            $argv = @('exec', '-s', 'read-only', 'review', "--$scopeKind", $scopeValue, '--skip-git-repo-check', '-o', $resultPath)
        }
        else {
            Remove-RunDirectoryQuietly $runDir
            Stop-WithError 64 "unknown scope kind: $scopeKind (expected uncommitted, base or commit)"
        }
    }
    else {
        Remove-RunDirectoryQuietly $runDir
        Write-UsageError
    }

    try {
        Write-RunFile (Join-Path $runDir 'stdin') $stdinPath
        Write-RunFile (Join-Path $runDir 'cmd') ('codex ' + ($argv -join ' '))
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText(
            (Join-Path $runDir 'argv.json'),
            (ConvertTo-Json -InputObject $argv -Compress),
            $utf8NoBom)
    }
    catch { Stop-WithError 65 "cannot write to the run directory: $runDir" }

    # Re-invoke this script for the worker. Every path element is quoted
    # explicitly because Start-Process will not do it.
    $launchArgs = @('-NoProfile')
    if (Test-OnWindows) { $launchArgs += @('-ExecutionPolicy', 'Bypass') }
    $launchArgs += @('-File', (ConvertTo-ProcessArgument $PSCommandPath),
                     '__run', (ConvertTo-ProcessArgument $runDir))

    # Redirecting all three of the worker's streams is what actually detaches it,
    # and it is not optional. Without it the worker inherits our caller's stdout
    # handle; the caller then blocks until that handle closes — that is, until the
    # whole review finishes — which is precisely the 600-second shell-tool timeout
    # this runner exists to escape. This is the PowerShell equivalent of the shell
    # sibling's `</dev/null >/dev/null 2>&1`.
    #
    # It is NOT a logging channel. Start-Process pumps a redirected stream through
    # THIS process, and this process is about to exit, so nothing the worker
    # writes to its own stdout or stderr is ever copied anywhere: worker-log and
    # worker-stderr are created here and then stay empty for the life of the run.
    # That is expected, not a symptom. Everything a controller needs to read comes
    # from worker-err, which the worker writes for itself — see Write-WorkerError.
    #
    # worker-stderr is deliberately NOT named worker-err. Two processes writing
    # one file through two mechanisms is how a sharing violation gets introduced:
    # this process holds its redirect target open until it exits, and a worker
    # that fails in its first milliseconds would then be unable to write its own
    # explanation — silently, since Write-WorkerError may not throw.
    $startArgs = @{
        FilePath = (Get-HostExecutable)
        ArgumentList = $launchArgs
        NoNewWindow = $true
        RedirectStandardInput = $nullStdin
        RedirectStandardOutput = (Join-Path $runDir 'worker-log')
        RedirectStandardError = (Join-Path $runDir 'worker-stderr')
    }
    try { Start-Process @startArgs | Out-Null }
    catch {
        # The worker never started, so nothing will ever write the sentinel.
        # Record why where status looks for it rather than dying silently.
        #
        # This is the one other write to worker-err, and it cannot race the
        # worker's own: reaching it means Start-Process THREW, so no worker
        # exists, and this process exits on the next line.
        [System.IO.File]::WriteAllText(
            (Join-Path $runDir 'worker-err'),
            ($_.Exception.Message + "`n"),
            (New-Object System.Text.UTF8Encoding($false)))
        Stop-WithError 65 "cannot launch the worker: $($_.Exception.Message)"
    }

    Write-Line "RUN_DIR=$runDir"
    return 0
}

function Write-WorkerError {
    # The worker records its OWN diagnostics, because the parent's stream
    # redirection cannot carry them. Start-Process pumps a redirected stream
    # through the PARENT process, so once `start` has exited — which is the entire
    # point of a detached worker — nothing copies the worker's stdout or stderr
    # into worker-log or worker-stderr, and both stay empty however loudly it
    # fails. Verified on Linux; the pumping is done by the same PowerShell code
    # path on Windows. The parent's redirects are still what detaches the worker
    # from the caller's console — they are simply not a logging channel. This
    # file, worker-err, is written by the worker alone and by no other mechanism.
    #
    # What this does NOT cover: a worker that dies before its first statement — a
    # missing interpreter, a blocked execution policy, a script that will not
    # parse. Nothing can report those, because the process that would write the
    # explanation is the one that failed to start, and the parent cannot see it
    # either. The shell sibling does cover them, in launch-err, because there a
    # SHELL owns the redirection. Closing that gap here would mean launching the
    # worker through cmd.exe with its own redirection operators; it is recorded as
    # a known difference instead, because that dispatch cannot be verified on the
    # platform this file is developed on.
    #
    # Nothing here may throw: this runs on the path where something already has.
    param([string] $RunDir, [string] $Message)
    try {
        [System.IO.File]::WriteAllText(
            (Join-Path $RunDir 'worker-err'),
            ($Message + "`n"),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Invoke-RunWorker {
    # The hidden copy: block on codex, then publish the exit status atomically.
    #
    # Everything is wrapped, because any failure in here means the sentinel will
    # never be written, and an unrecorded run with no explanation is exactly the
    # "wait forever" state worker-err exists to prevent.
    param([string] $RunDir)
    try {
        Invoke-RunWorkerCore $RunDir
    }
    catch {
        Write-WorkerError $RunDir $_.Exception.Message
    }
}

function Invoke-RunWorkerCore {
    param([string] $RunDir)

    $workDir = Read-RunFile (Join-Path $RunDir 'work-dir')
    $stdinPath = Read-RunFile (Join-Path $RunDir 'stdin')
    $codexPath = Read-RunFile (Join-Path $RunDir 'codex-path')
    $rawArgv = @(ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $RunDir 'argv.json'))))
    $argv = @()
    foreach ($item in $rawArgv) { $argv += (ConvertTo-ProcessArgument $item) }

    # Launch the exact program the parent resolved, never a bare name.
    #
    # A .cmd or .bat — which is how the documented npm install route puts codex on
    # PATH — cannot be launched directly here: the redirects below force
    # UseShellExecute=false, and CreateProcessW refuses a batch file with Win32
    # 193. Note the trap in that sentence: the redirection this runner needs in
    # order to detach is exactly what disables the ShellExecute path that would
    # otherwise have handled the .cmd. So hand it to the command interpreter.
    #
    # /d skips any AutoRun command from the registry. /s makes cmd strip exactly
    # the outermost quote pair and take the rest verbatim, which is the only
    # reliable form once the program path itself needs quoting — and the temp path
    # holding `result` routinely contains a space on Windows, under a user name
    # like "John Smith".
    $launchFile = $codexPath
    $launchArgs = $argv
    $extension = [System.IO.Path]::GetExtension($codexPath)
    if (($extension -eq '.cmd') -or ($extension -eq '.bat')) {
        # ComSpec is normally set; when it is not, an empty -FilePath throws and
        # the run would be recorded as exit 127 — "codex not found" — for a codex
        # that is present and a command interpreter that is merely unnamed.
        $launchFile = $env:ComSpec
        if ([string]::IsNullOrWhiteSpace($launchFile)) { $launchFile = 'cmd.exe' }
        $inner = '"' + $codexPath + '"'
        if ($argv.Count -gt 0) { $inner = $inner + ' ' + ($argv -join ' ') }
        $launchArgs = @('/d', '/s', '/c', ('"' + $inner + '"'))
    }

    $exitCode = 127
    try {
        $proc = Start-Process -FilePath $launchFile -ArgumentList $launchArgs `
            -WorkingDirectory $workDir -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput (Join-Path $RunDir 'log') `
            -RedirectStandardError (Join-Path $RunDir 'err-log') `
            -RedirectStandardInput $stdinPath
        $exitCode = $proc.ExitCode
    }
    catch {
        [System.IO.File]::WriteAllText((Join-Path $RunDir 'err-log'), $_.Exception.Message)
    }

    # Writing straight to exit-code would create the file before the digit landed
    # in it, and a status call in that window would read an empty sentinel.
    $tmp = Join-Path $RunDir 'exit-code.tmp'
    Write-RunFile $tmp $exitCode
    Move-Item -LiteralPath $tmp -Destination (Join-Path $RunDir 'exit-code') -Force
}

function Get-RunStatus {
    param([string] $RunDir)
    Assert-RunDirectory $RunDir
    $RunDir = Resolve-PhysicalPath $RunDir

    # Field order matches the shell sibling exactly, and WORK_DIR and CMD are
    # printed unconditionally as it prints them, so one parser reads both runners.
    $started = [int] (Read-RunFile (Join-Path $RunDir 'started-at'))
    Write-Line "RUN_DIR=$RunDir"
    Write-Line ('MODE=' + (Read-RunFile (Join-Path $RunDir 'mode')))
    # A recovered run is identified by its recorded metadata — that is the whole
    # justification for the fixed runs root — so status must report which working
    # tree it belongs to and what was actually run, not merely that it exists.
    Write-Line ('WORK_DIR=' + (Read-RunFileOrEmpty (Join-Path $RunDir 'work-dir')))
    Write-Line ('CMD=' + (Read-RunFileOrEmpty (Join-Path $RunDir 'cmd')))
    Write-Line ('ELAPSED_SECONDS=' + ((Get-EpochSeconds) - $started))
    Write-Line ('RESULT=' + (Join-Path $RunDir 'result'))
    # Codex writes its final message to stdout and its progress event stream to
    # stderr, so the stderr log is the large one.
    Write-Line ('STDOUT_LOG=' + (Join-Path $RunDir 'log'))
    Write-Line ('STDERR_LOG=' + (Join-Path $RunDir 'err-log'))

    # A non-empty worker-err means the worker never got as far as running codex,
    # or died before it could record completion. Surfacing it is what stops "no
    # exit-code yet" from reading as "still working". It is the counterpart of the
    # shell sibling's launch-err, and status names it with the same key. The
    # worker writes that file itself; no stream redirect feeds it.
    $workerErr = Join-Path $RunDir 'worker-err'
    if ((Test-Path -LiteralPath $workerErr -PathType Leaf) -and ((Get-Item -LiteralPath $workerErr).Length -gt 0)) {
        Write-Line ('LAUNCH_ERROR=' + $workerErr)
    }

    $sentinel = Join-Path $RunDir 'exit-code'
    if (Test-Path -LiteralPath $sentinel -PathType Leaf) {
        Write-Line 'STATE=done'
        Write-Line ('EXIT_CODE=' + (Read-RunFile $sentinel))
        $result = Join-Path $RunDir 'result'
        if (Test-Path -LiteralPath $result -PathType Leaf) {
            Write-Line ('RESULT_BYTES=' + (Get-Item -LiteralPath $result).Length)
        }
        else {
            Write-Line 'RESULT_BYTES=0'
        }
        return 0
    }

    Write-Line 'STATE=not-recorded'
    return 3
}

function Wait-ForRun {
    param([string] $RunDir, [string] $TimeoutSeconds)
    Assert-RunDirectory $RunDir
    if ($TimeoutSeconds -notmatch '^[0-9]+$') { Write-UsageError }

    # The poll interval arrives from the environment, so hold it to the same
    # standard as the timeout argument — here, where it is the only thing that
    # consumes it. Zero would spin the loop below forever without ever advancing
    # $waited. Leading zeros are accepted because the shell sibling accepts them,
    # and the offending value is quoted back because a caller who exported it in
    # a parent shell may not know what it currently holds.
    if (($PollInterval -notmatch '^[0-9]+$') -or ([int] $PollInterval -le 0)) {
        Stop-WithError 64 "SUPERARTES_CODEX_POLL_INTERVAL must be a positive integer: $PollInterval"
    }
    $poll = [int] $PollInterval

    $timeout = [int] $TimeoutSeconds
    $waited = 0
    $sentinel = Join-Path $RunDir 'exit-code'
    while ($waited -lt $timeout) {
        if (Test-Path -LiteralPath $sentinel -PathType Leaf) { break }
        Start-Sleep -Seconds $poll
        $waited = $waited + $poll
    }

    return (Get-RunStatus $RunDir)
}

function Remove-Run {
    # Removes the run's artifacts. It does NOT stop the reviewer: this runner has
    # no cancellation, so a discarded review keeps running and keeps spending
    # tokens until it finishes on its own. Say so when reporting to the user.
    param([object[]] $Arguments)

    # Accept --force on either side of the run directory: an agent may reasonably
    # write it first, and "not a run directory: --force" is a misleading answer.
    $force = $false
    $target = ''
    foreach ($item in @($Arguments)) {
        if ($item -eq '--force') { $force = $true }
        elseif ([string]::IsNullOrWhiteSpace($target)) { $target = $item }
        else { Write-UsageError }
    }

    $RunDir = $target
    Assert-RunDirectory $RunDir

    $sentinel = Join-Path $RunDir 'exit-code'
    if ((-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) -and (-not $force)) {
        Stop-WithError 66 "completion not recorded for: $RunDir (pass --force to discard the artifacts anyway)"
    }

    # Validate the SHAPE of the canonicalised path rather than comparing against a
    # runs root recomputed from the environment. Every subcommand is a separate
    # process for an agent, so a run started under one TEMP and discarded under
    # another would otherwise be impossible to clean up, and the error would read
    # as a corrupted run rather than an environment mismatch.
    #
    # Canonicalising first is what defeats traversal: a path ending
    # "run.x/../../victim" resolves to a basename of "victim", which fails the
    # run.* test below.
    $canonRun = Resolve-PhysicalPath $RunDir
    if (-not (Split-Path -Leaf $canonRun).StartsWith('run.', [System.StringComparison]::Ordinal)) {
        Stop-WithError 65 "refusing to remove a directory this runner did not create: $canonRun"
    }
    # A drive or share root has no parent, and Split-Path -Leaf throws on the
    # empty string it returns — which would exit 1 instead of the documented 65.
    $canonParent = Split-Path -Parent $canonRun
    if ([string]::IsNullOrEmpty($canonParent) -or
        ((Split-Path -Leaf $canonParent) -ne $RunsDirName)) {
        Stop-WithError 65 "refusing to remove a path outside a ${RunsDirName} directory: $canonRun"
    }

    # rm -rf semantics: the removal itself must not throw. On Windows a still
    # running worker holds log, err-log, worker-log and worker-stderr open, and
    # Remove-Item raises a sharing violation partway through — which is the
    # documented `discard --force` case, so an unguarded call would exit 1 after a
    # partial delete and leave the Test-Path check below unreachable. Let that
    # check be the one that decides.
    #
    # The consequence is a known difference from the shell sibling, where an open
    # file never blocks unlink: on Windows, `discard --force` on an IN-FLIGHT run
    # can leave part of the directory behind and exit 65, "run directory still
    # present after removal", where the sibling exits 0. Discarding a finished run
    # behaves identically on both.
    try { Remove-Item -Recurse -Force -LiteralPath $canonRun }
    catch { }
    if (Test-Path -LiteralPath $canonRun) {
        Stop-WithError 65 "run directory still present after removal: $canonRun"
    }
    Write-Line 'STATE=discarded'
    return 0
}

$command = $null
if ($args.Count -gt 0) { $command = $args[0] }
# The @() is required, not decorative: without it a single-argument subcommand
# such as `status <run-dir>` binds $rest to a string and $rest[0] becomes "/".
$rest = @(Select-Rest $args 1)

if ($command -eq 'start') {
    exit (Start-Run $rest[0] $rest[1] @(Select-Rest $rest 2))
}
elseif ($command -eq 'status') {
    exit (Get-RunStatus $rest[0])
}
elseif ($command -eq 'wait') {
    exit (Wait-ForRun $rest[0] $rest[1])
}
elseif ($command -eq 'discard') {
    exit (Remove-Run @(Select-Rest $args 1))
}
elseif ($command -eq '__run') {
    Invoke-RunWorker $rest[0]
    exit 0
}
elseif (($command -eq '-h') -or ($command -eq '--help')) {
    Write-Usage
}
else {
    Write-UsageError
}
