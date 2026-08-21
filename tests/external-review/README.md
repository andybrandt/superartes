# External Review Tests

The deterministic POSIX contract suite is the currently verified baseline:

```bash
bash tests/external-review/run-tests.sh
```

The POSIX suite uses fake CLIs, so it needs no credentials or network access.
The pre-implementation pressure evidence is in
[pressure-scenarios.md](pressure-scenarios.md). `indeterminate` is computed
only by `status` and `wait`. It is never persisted over the last reliable
state.

## Mandatory native Windows PowerShell 5.1 checkpoint

Run these commands from Windows PowerShell 5.1 on native Windows. Do not use
Git Bash or WSL. The first command is the native RED mechanism: it must report
only that the runner is missing and return nonzero before the suite creates any
fixtures. The second command runs the real deterministic suite with fake CLIs.
Open Windows PowerShell 5.1 in the repository root and run the block exactly as
written.

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\external-review\Run-Tests.ps1 -RunnerPath C:\definitely-missing\invoke-reviewer.ps1
if ($LASTEXITCODE -eq 0) { throw 'Missing-runner RED unexpectedly passed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\external-review\Run-Tests.ps1 -RunnerPath .\skills\external-review\invoke-reviewer.ps1
if ($LASTEXITCODE -ne 0) { throw "Deterministic suite failed with $LASTEXITCODE" }
```

PowerShell 7 is supplemental only and does not replace the mandatory Windows
PowerShell 5.1 result:

```powershell
& pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\external-review\Run-Tests.ps1 -RunnerPath .\skills\external-review\invoke-reviewer.ps1
```

Native Windows verification is mandatory and has not yet been run. Record the
checkpoint here without replacing the placeholders until it has actually
completed:

- Commit SHA: `<not yet recorded>`
- Windows version: `<not yet recorded>`
- PowerShell version and edition: `<not yet recorded>`
- Claude CLI version / `check claude-prompt`: `<not yet recorded>`
- Codex CLI version / `check codex-prompt` / `check codex-review`: `<not yet recorded>`
- Deliberately missing runner RED outcome: `<not yet recorded>`
- Deterministic native parity suite outcome: `<not yet recorded>`
- Live Claude prompt outcome and session identifier: `<not yet recorded>`
- Live Codex prompt and review-scope outcomes: `<not yet recorded>`
- Parent/child cancellation and cleanup outcomes: `<not yet recorded>`

The deterministic Windows suite supplies fake `claude.cmd` and `codex.cmd`
launchers and needs no credentials or network. `Test-ClaudePromptLifecycle`
parses the fake launcher's JSON argument capture and requires this exact
allowed-tools value as one intact argument:

```text
Read,Glob,Grep,PowerShell(git diff *),PowerShell(git status *),PowerShell(git rev-parse *),PowerShell(git cat-file *),PowerShell(git show *),PowerShell(git log *)
```

## Credentialed native Windows live checkpoint

The commands below contact Claude and Codex. They require installed CLIs,
valid credentials, network access, any provider approval required by the
account, and spend model tokens. Run them only after explicitly accepting
those costs. Keep the checkout and fixture paths with spaces as shown.

Create the disposable repository and prompt from Windows PowerShell 5.1:

```powershell
$Checkout = (Resolve-Path .).ProviderPath
$SourceAdapter = Join-Path $Checkout 'skills\external-review\invoke-reviewer.ps1'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Fixture = Join-Path $env:TEMP ("Superartes live review {0} with spaces" -f [Guid]::NewGuid())
$ReviewRoot = Join-Path $Fixture 'managed review temp with spaces'
$Repository = Join-Path $Fixture 'disposable Git repository with spaces'
$AdapterDirectory = Join-Path $Fixture 'adapter copy with spaces'
[void](New-Item -ItemType Directory -Path $ReviewRoot)
[void](New-Item -ItemType Directory -Path $Repository)
[void](New-Item -ItemType Directory -Path $AdapterDirectory)
$Adapter = Join-Path $AdapterDirectory 'invoke reviewer copy.ps1'
Copy-Item -LiteralPath $SourceAdapter -Destination $Adapter
if (-not $Adapter.Contains(' ') -or -not (Test-Path -LiteralPath $Adapter -PathType Leaf)) {
    throw 'Live checkpoint requires a copied adapter path containing spaces'
}
$env:SUPERARTES_REVIEW_TMPDIR = $ReviewRoot
& git -C $Repository init
& git -C $Repository config user.name 'Superartes Test'
& git -C $Repository config user.email 'superartes-test@example.invalid'
$Document = Join-Path $Repository 'design document.md'
$Prompt = Join-Path $Fixture 'review prompt.txt'
[IO.File]::WriteAllText($Document, "# Design`n`nThe retry limit is undefined.`n", $Utf8NoBom)
[IO.File]::WriteAllText($Prompt, "Review this design document read-only: $Document`nUse the allowed PowerShell tool to run git status --short, then report the exact repository-status evidence, including uncommitted.txt.", $Utf8NoBom)
& git -C $Repository add -- 'design document.md'
& git -C $Repository commit -m 'initial fixture'
$BaseBranch = (& git -C $Repository branch --show-current).Trim()
$InitialCommit = (& git -C $Repository rev-parse HEAD).Trim()
& git -C $Repository checkout -b review-feature
[IO.File]::AppendAllText($Document, "The timeout is also undefined.`n", $Utf8NoBom)
& git -C $Repository add -- 'design document.md'
& git -C $Repository commit -m 'add reviewable defect'
$FeatureCommit = (& git -C $Repository rev-parse HEAD).Trim()
[IO.File]::WriteAllText((Join-Path $Repository 'uncommitted.txt'), "uncommitted review scope`n", $Utf8NoBom)

foreach ($Profile in @('claude-prompt', 'codex-prompt', 'codex-review')) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter check $Profile
    if ($LASTEXITCODE -ne 0) { throw "$Profile preflight failed with $LASTEXITCODE" }
}
```

Exercise `claude-prompt`, including `start`, a zero-time `wait`, `status`, the
native JSON artifact, provider session identity, and cleanup:

```powershell
$Start = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start claude-prompt 'live|claude|document' $Repository $Prompt
if ($LASTEXITCODE -ne 0) { throw "Claude start returned $LASTEXITCODE" }
$ClaudeRun = (($Start | Where-Object { $_ -like 'RUN_DIR=*' }) -replace '^RUN_DIR=', '')
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter wait $ClaudeRun 0
if ($LASTEXITCODE -notin @(0, 3)) { throw "Claude zero-time wait returned $LASTEXITCODE" }
do {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter wait $ClaudeRun 30
    $WaitExit = $LASTEXITCODE
} while ($WaitExit -eq 3)
if ($WaitExit -ne 0) { throw "Claude wait returned $WaitExit" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter status $ClaudeRun
if ($LASTEXITCODE -ne 0) { throw "Claude terminal status returned $LASTEXITCODE" }
$ClaudeState = (Get-Content -LiteralPath (Join-Path $ClaudeRun 'state') -Raw).Trim()
$ClaudeExit = (Get-Content -LiteralPath (Join-Path $ClaudeRun 'exit-code') -Raw).Trim()
if ($ClaudeState -cne 'exited') { throw "Unexpected Claude terminal state: $ClaudeState" }
if ($ClaudeExit -cne '0') { throw "Unexpected Claude reviewer exit evidence: $ClaudeExit" }
$ClaudeSession = (Get-Content -LiteralPath (Join-Path $ClaudeRun 'provider-session') -Raw).Trim()
$ParsedClaudeSession = [Guid]::Empty
if (-not [Guid]::TryParse($ClaudeSession, [ref]$ParsedClaudeSession) -or
    $ParsedClaudeSession -eq [Guid]::Empty) {
    throw "Claude provider-session is not a nonempty GUID: $ClaudeSession"
}
$ClaudeResultPath = Join-Path $ClaudeRun 'result'
if (-not (Test-Path -LiteralPath $ClaudeResultPath -PathType Leaf) -or
    (Get-Item -LiteralPath $ClaudeResultPath).Length -eq 0) {
    throw 'Claude result artifact is missing or empty'
}
$ClaudeResult = Get-Content -LiteralPath $ClaudeResultPath -Raw
try { $ClaudeJson = @($ClaudeResult | ConvertFrom-Json -ErrorAction Stop) }
catch { throw "Claude result is not valid JSON: $($_.Exception.Message)" }
$ClaudeResultSessions = @($ClaudeJson | ForEach-Object { [string]$_.session_id } |
    Where-Object { $_.Length -gt 0 })
if ($ClaudeResultSessions -notcontains $ClaudeSession) {
    throw "Claude result session identity does not match provider-session: $ClaudeSession"
}
$ClaudeReviewText = (($ClaudeJson | ForEach-Object { [string]$_.result }) -join "`n").Trim()
if ($ClaudeReviewText.Length -lt 20) { throw 'Claude JSON contains no substantive review result' }
$ClaudeResult
if ($ClaudeReviewText -notmatch 'uncommitted\.txt') { throw 'Claude result did not report git status evidence for uncommitted.txt' }
Get-Content -LiteralPath (Join-Path $ClaudeRun 'reviewer-log') -Raw
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter cleanup $ClaudeRun
if ($LASTEXITCODE -ne 0) { throw "Claude cleanup returned $LASTEXITCODE" }
if (Test-Path -LiteralPath $ClaudeRun) { throw 'Claude cleanup left its run directory' }
```

Exercise `codex-prompt` and inspect its native final-message artifact:

```powershell
$Start = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-prompt 'live|codex|document' $Repository $Prompt
if ($LASTEXITCODE -ne 0) { throw "Codex prompt start returned $LASTEXITCODE" }
$CodexPromptRun = (($Start | Where-Object { $_ -like 'RUN_DIR=*' }) -replace '^RUN_DIR=', '')
do {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter wait $CodexPromptRun 30
    $WaitExit = $LASTEXITCODE
} while ($WaitExit -eq 3)
if ($WaitExit -ne 0) { throw "Codex prompt wait returned $WaitExit" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter status $CodexPromptRun
if ($LASTEXITCODE -ne 0) { throw "Codex prompt terminal status returned $LASTEXITCODE" }
$CodexPromptState = (Get-Content -LiteralPath (Join-Path $CodexPromptRun 'state') -Raw).Trim()
$CodexPromptExit = (Get-Content -LiteralPath (Join-Path $CodexPromptRun 'exit-code') -Raw).Trim()
$CodexPromptSession = (Get-Content -LiteralPath (Join-Path $CodexPromptRun 'provider-session') -Raw).Trim()
if ($CodexPromptState -cne 'exited') { throw "Unexpected Codex prompt state: $CodexPromptState" }
if ($CodexPromptExit -cne '0') { throw "Unexpected Codex prompt reviewer exit evidence: $CodexPromptExit" }
if ($CodexPromptSession -cne 'not-applicable') { throw "Unexpected Codex prompt provider-session: $CodexPromptSession" }
$CodexPromptResultPath = Join-Path $CodexPromptRun 'result'
if (-not (Test-Path -LiteralPath $CodexPromptResultPath -PathType Leaf) -or
    (Get-Item -LiteralPath $CodexPromptResultPath).Length -eq 0) {
    throw 'Codex prompt result artifact is missing or empty'
}
$CodexPromptResult = (Get-Content -LiteralPath $CodexPromptResultPath -Raw).Trim()
if ($CodexPromptResult.Length -lt 20) { throw 'Codex prompt result is not substantive' }
$CodexPromptResult
Get-Content -LiteralPath (Join-Path $CodexPromptRun 'reviewer-log') -Raw
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter cleanup $CodexPromptRun
if ($LASTEXITCODE -ne 0) { throw "Codex prompt cleanup returned $LASTEXITCODE" }
if (Test-Path -LiteralPath $CodexPromptRun) { throw 'Codex prompt cleanup left its run directory' }
```

Exercise every native `codex-review` scope. The adapter supplies no prompt and
no prompt-profile sandbox flag for these invocations:

```powershell
$Scopes = @(
    @('uncommitted'),
    @('base', $BaseBranch),
    @('commit', $FeatureCommit)
)
foreach ($Scope in $Scopes) {
    $Key = "live|codex-review|$($Scope[0])|$([Guid]::NewGuid())"
    $StartArguments = @('start', 'codex-review', $Key, $Repository) + $Scope
    $Start = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter @StartArguments
    if ($LASTEXITCODE -ne 0) { throw "$($Scope[0]) start returned $LASTEXITCODE" }
    $Run = (($Start | Where-Object { $_ -like 'RUN_DIR=*' }) -replace '^RUN_DIR=', '')
    do {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter wait $Run 30
        $WaitExit = $LASTEXITCODE
    } while ($WaitExit -eq 3)
    if ($WaitExit -ne 0) { throw "$($Scope[0]) wait returned $WaitExit" }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter status $Run
    if ($LASTEXITCODE -ne 0) { throw "$($Scope[0]) terminal status returned $LASTEXITCODE" }
    $ReviewState = (Get-Content -LiteralPath (Join-Path $Run 'state') -Raw).Trim()
    $ReviewExit = (Get-Content -LiteralPath (Join-Path $Run 'exit-code') -Raw).Trim()
    $ReviewSession = (Get-Content -LiteralPath (Join-Path $Run 'provider-session') -Raw).Trim()
    if ($ReviewState -cne 'exited') { throw "$($Scope[0]) has unexpected state: $ReviewState" }
    if ($ReviewExit -cne '0') { throw "$($Scope[0]) has unexpected reviewer exit evidence: $ReviewExit" }
    if ($ReviewSession -cne 'not-applicable') { throw "$($Scope[0]) has unexpected provider-session: $ReviewSession" }
    $ReviewResultPath = Join-Path $Run 'result'
    if (-not (Test-Path -LiteralPath $ReviewResultPath -PathType Leaf) -or
        (Get-Item -LiteralPath $ReviewResultPath).Length -eq 0) {
        throw "$($Scope[0]) result artifact is missing or empty"
    }
    $ReviewResult = (Get-Content -LiteralPath $ReviewResultPath -Raw).Trim()
    if ($ReviewResult.Length -lt 20) { throw "$($Scope[0]) result is not substantive" }
    $ReviewResult
    Get-Content -LiteralPath (Join-Path $Run 'reviewer-log') -Raw
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter cleanup $Run
    if ($LASTEXITCODE -ne 0) { throw "$($Scope[0]) cleanup returned $LASTEXITCODE" }
    if (Test-Path -LiteralPath $Run) { throw "$($Scope[0]) cleanup left its run directory" }
}
```

Exercise explicit cancellation with another Claude run. Inspect the terminal
evidence before cleanup; `cancel-requested` must contain `accepted:<epoch>` and
the final state must be `cancelled`:

```powershell
[IO.File]::WriteAllText($Prompt, "Perform a thorough read-only review of every file under $Repository", $Utf8NoBom)
$Start = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start claude-prompt 'live|claude|cancel' $Repository $Prompt
if ($LASTEXITCODE -ne 0) { throw "Cancellation fixture start returned $LASTEXITCODE" }
$CancelRun = (($Start | Where-Object { $_ -like 'RUN_DIR=*' }) -replace '^RUN_DIR=', '')
$ReviewerPid = [int]((Get-Content -LiteralPath (Join-Path $CancelRun 'reviewer-pid') -Raw).Trim())
$ReviewerStart = (Get-Content -LiteralPath (Join-Path $CancelRun 'reviewer-start') -Raw).Trim()

function Test-RecordedProcessIdentity {
    param([int]$ProcessId, [string]$StartToken)
    try {
        $Actual = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks.ToString()
        return $Actual -ceq $StartToken
    }
    catch { return $false }
}

$RecordedIdentities = @([pscustomobject]@{ ProcessId = $ReviewerPid; StartToken = $ReviewerStart })
$Deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    $AllProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    $Frontier = @($ReviewerPid)
    $Children = @()
    while ($Frontier.Count -gt 0) {
        $Next = @()
        foreach ($ParentPid in $Frontier) {
            foreach ($Child in @($AllProcesses | Where-Object { [int]$_.ParentProcessId -eq $ParentPid })) {
                $ChildPid = [int]$Child.ProcessId
                $ChildStart = (Get-Process -Id $ChildPid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks.ToString()
                $Children += [pscustomobject]@{ ProcessId = $ChildPid; StartToken = $ChildStart }
                $Next += $ChildPid
            }
        }
        $Frontier = $Next
    }
    if ($Children.Count -eq 0) { Start-Sleep -Milliseconds 100 }
} while ($Children.Count -eq 0 -and [DateTime]::UtcNow -lt $Deadline)
if ($Children.Count -eq 0) { throw 'Cancellation fixture published no child identity' }
$RecordedIdentities += $Children
$RecordedIdentities | Format-Table ProcessId, StartToken
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter cancel $CancelRun
if ($LASTEXITCODE -ne 0) { throw "Cancel returned $LASTEXITCODE" }
do {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter wait $CancelRun 10
    $WaitExit = $LASTEXITCODE
} while ($WaitExit -eq 3)
if ($WaitExit -ne 0) { throw "Cancelled wait returned $WaitExit" }
$CancelMarker = (Get-Content -LiteralPath (Join-Path $CancelRun 'cancel-requested') -Raw).Trim()
$CancelState = (Get-Content -LiteralPath (Join-Path $CancelRun 'state') -Raw).Trim()
$CancelExit = (Get-Content -LiteralPath (Join-Path $CancelRun 'exit-code') -Raw).Trim()
if ($CancelMarker -notmatch '^accepted:\d+$') { throw "Unexpected cancellation marker: $CancelMarker" }
if ($CancelState -cne 'cancelled') { throw "Unexpected cancellation state: $CancelState" }
if ($CancelExit -cne '-1') { throw "Unexpected forced-process exit evidence: $CancelExit" }
foreach ($Identity in $RecordedIdentities) {
    if (Test-RecordedProcessIdentity $Identity.ProcessId $Identity.StartToken) {
        throw "Cancellation left recorded process $($Identity.ProcessId) alive"
    }
}
Get-Content -LiteralPath (Join-Path $CancelRun 'reviewer-log') -Raw
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter cleanup $CancelRun
if ($LASTEXITCODE -ne 0) { throw "Cancelled cleanup returned $LASTEXITCODE" }
if (Test-Path -LiteralPath $CancelRun) { throw 'Cancelled cleanup left its run directory' }
```

After recording the required outputs and confirming no retained run still
needs diagnosis, remove only the disposable fixture you created:

```powershell
Remove-Item -LiteralPath $Fixture -Recurse -Force
```
