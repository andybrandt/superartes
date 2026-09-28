# External Review Tests

## Direction B direct foreground checks

On 2026-09-26, a Codex controller on Linux exercised the direct
foreground route with Codex CLI 0.157.1 and Claude Code 2.1.283. A silent PTY
command completed after 900.00 seconds through bounded command-session polls.
A real document review completed in 10.88 seconds with native JSON, exit 0 and
no permission denials. A separate real Claude interruption returned shell exit
0 but its JSON reported `is_error: true` and `terminal_reason:
aborted_streaming`; no process with that provider session UUID remained. A
14.65-second code review of a disposable Git repository reported the Git
commands and files it inspected and found the intentionally removed empty-input
guard in `calculator.py`. These checks establish the foreground mechanism on
this Linux host. They do not establish survival after ending a Codex turn, a
full application crash, or behavior on macOS, WSL or native Windows.

An independent Claude review of the staged switch returned a successful native
JSON result with no stderr or blocking findings (provider-reported runtime:
79.23 seconds). The reviewer inspected the staged Git diff, the handoff, plan,
skills and tests; it did not run the controller's checks.

The active command is tested without provider access by
`python3 tests/external-review/test-direct-claude.py`. Its nine cases execute
the marked command in `skills/external-review/invoking-reviewers.md` against a fake executable,
including success, failure, empty live output and deliberate command sabotage.
The active skills use this direct foreground command.

Three deterministic suites cover the two external-review directions. All of them
use fake CLIs, so none needs credentials or network access.

| Suite | Tests | Covers |
|---|---|---|
| `python3 tests/external-review/test-direct-claude.py` | 9 | The documented direct Claude command - a **Codex controller** obtaining a review from Claude |
| `bash tests/external-review/test-invoke-codex.sh` | 77 | `invoke-codex.sh`, the background runner — a **Claude Code controller** obtaining a review from Codex |
| `pwsh -NoProfile -File tests/external-review/Test-InvokeCodex.ps1` | 117 | `invoke-codex.ps1`, the Windows sibling of that runner |

The first two have run only on Linux; macOS and WSL are unverified for both
directions. The third has not run on its target platform at all:
`Test-InvokeCodex.ps1` is exercised only under PowerShell 7 on Linux and **has
never been run on native Windows**. The direct Claude path is unavailable on
native Windows; that support was withdrawn rather than deferred. The
sections below say so in detail.

## Historical managed-adapter checkpoints

The removed `invoke-reviewer.sh` managed adapter passed 420 deterministic
assertions at the pre-switch baseline. Its suite was removed with the machinery
it tested. The following Task 5/6 evidence and
[pressure-scenarios.md](pressure-scenarios.md) describe that historical adapter,
not the active invocation procedure. Use the direct foreground reference above
for current Direction B reviews. The historical `indeterminate` state and
persistent-shell procedure do not apply to the direct command.

The Task 5 Linux checkpoint was run from a working tree based on checkpoint
commit `74c9054` with Claude Code 2.1.241:

- The external-review trigger test passed outside the Codex sandbox and
  invoked exactly `superartes:external-review`.
- A one-shot elevated managed start returned `running`, after which the host
  reaped both supervisor and reviewer and `wait` correctly returned
  `indeterminate`. A detached `nohup setsid sleep` probe was also reaped,
  isolating the host execution boundary rather than the adapter.
- The same `claude-prompt` profile in one persistent elevated Bash session
  reached `exited`, recorded exit code 0 and a provider-session UUID, retained
  substantive native JSON, and cleaned up successfully after inspection.
- A fresh post-documentation rerun repeated that lifecycle in 13 seconds. It
  recorded provider session `42b37a90-53e3-44e7-a82f-a2eb796a60bb`; the
  13,088-byte native JSON identified an ambiguity in how the fixture defined a
  live reviewer and contained the required `TASK5_LINUX_GREEN` marker. Both
  logs were empty, and cleanup succeeded.

## Historical Codex-controller code-review live checkpoint

Task 6 ran exactly one real `claude-prompt` review against a disposable Git
repository, without running `codex-review` from the Codex controller. The
fixture had one committed safe implementation and one unstaged defect that
removed the empty-input guard from `average()` while leaving its contract and
test unchanged. The approval exposed only that disposable fixture to Claude
and stated that provider network access and model tokens would be used.

One approved persistent Bash PTY hosted `check`, `start`, two bounded `wait`
calls, terminal evidence inspection, triage, and cleanup. Preflight returned
0. The adapter started at `2026-08-26T16:18:18+02:00` and completed at
`2026-08-26T16:19:08+02:00`, recording 50 seconds of reviewer runtime:

```text
STATE=exited
EXIT_CODE=0
RUN_ID=b6c71e7d-5a17-4795-a1fb-2f93f0ab3d38
PROVIDER_SESSION=028b87b8-b0bd-46c1-88a0-87f3b522a803
RESULT_BYTES=48828
```

The provider-session UUID appeared in the retained native JSON. The review
reported these Git commands: `git status --porcelain`, `git diff`,
`git diff --cached`, `git show --stat HEAD`, and `git show HEAD`. It listed
`calculator.py` and `test_calculator.py` as relevant inspected files and tied
its critical finding to the removed guard: `average([])` now evaluates
`0 / 0`, raises `ZeroDivisionError`, contradicts the docstring, and breaks the
existing empty-input test. This was valid fixture-specific review evidence.

`reviewer-log`, `supervisor-output`, and `supervisor-log` were empty;
`reviewer-output` was absent as expected because `claude-prompt` writes its
native JSON to `result`. Claude reported that permission mode denied its
attempt to execute pytest, so it established the deterministic defect by Git
and source inspection. After triage, managed cleanup returned `STATE=cleaned`,
the run directory was absent, and only then did the persistent PTY exit at
`2026-08-26T16:20:51+02:00`.

The historical Task 5 `claude -p` trigger result above is retained only as
implementation history. Normal Claude-controller behavior is a separate
interactive manual plugin check. Headless `claude -p` output is not evidence
for that behavior and is not part of the current validation gate.

## Native Windows is not currently supported for the Codex-controller direction

There is no PowerShell managed adapter and no native Windows suite. The 1,728-line
adapter and its 2,396 lines of tests were removed because they had never been executed on
any machine: the maintainer cannot read PowerShell, and Windows PowerShell 5.1 on the
available Windows host is broken, so the code could be neither reviewed nor run. Shipping
that much unverified code was a liability rather than a feature.

The active direct foreground path has been tested on Linux. macOS and WSL are
unverified POSIX candidates; the reference requires checking CLI capabilities,
artifact visibility and command-session controls before proceeding there.
Native Windows remains unavailable pending native tests of input, paths,
exit propagation, long polling and cancellation. Linux PowerShell tests do
not establish native Windows behavior.

This limitation does not affect the **Claude Code controller**, which reaches Codex
through `skills/external-review/invoke-codex.sh` on POSIX hosts and
`invoke-codex.ps1` on native Windows. Those runners have their own deterministic
suites:

```bash
bash tests/external-review/test-invoke-codex.sh
pwsh -NoProfile -File tests/external-review/Test-InvokeCodex.ps1
```

Both use a fake `codex` and need no credentials or network.

`invoke-codex.ps1` has itself never run on native Windows either — it is written to
the Windows PowerShell 5.1 subset and exercised only under PowerShell 7 on Linux — so
it is worth being exact about why it is kept where the adapter was not. The deleted
adapter had **zero executions on any machine, ever**, and nobody who could read it had
run it; there was no way in to check any part of it. The runner carries **117
assertions that execute on every run** (113 where the host cannot create a symbolic
link) and has been through three rounds of review. It is **additive and optional**:
nothing else depends on it, and when it fails a Windows user loses a Codex review,
loudly, at `start`, and loses nothing else. And what remains unverified in it is a
short enumerable list — `PATHEXT`, `cmd.exe` dispatch, execution policy, sharing
violations, and `TMP`/`TEMP` resolution — which the last section of this file turns
into specific checks a Windows user can run in an afternoon. That is the distinction
being drawn: a bounded, listed, testable gap is not the same liability as an unbounded
unread one.

## How the two invoke-codex runners differ

**The Windows-side behaviour described here is predicted from the code and from Win32
semantics, not observed.** Only the POSIX side and the platform-independent logic have
actually been executed. Every claim below about sharing violations, `cmd.exe` dispatch,
PowerShell 5.1 symlink resolution and the extra exit-65 case is a reasoned expectation
awaiting the checks in the final section of this file.

The two runners present the same subcommands, the same exit codes and the same run-directory
contract, and a controller can drive either without knowing which it has. Underneath, a
detached POSIX shell job and a detached PowerShell process are not the same animal, and the
differences below are deliberate rather than accidental.

**The run directory holds more on Windows.** The shell runner passes its argument vector
straight to the detached child inside a single `sh -c`, so the child needs nothing written
down. The PowerShell worker is a separately launched process that must read back what it was
asked to do, so its run directory also carries `stdin`, `argv.json`, `codex-path` and
`null-stdin`. It also carries `worker-log` and `worker-stderr`, which are the parent's redirect
targets, and `worker-err`, which is the counterpart of the shell runner's `launch-err`. Status
reports it under the same `LAUNCH_ERROR` key on both.

**`worker-log` and `worker-stderr` are always empty, and that is correct.** PowerShell's
`Start-Process` copies a redirected stream through the process that started it, and that
process exits immediately — detaching the worker is the whole point. So nothing the worker
prints is ever copied into those files. They exist because redirecting the worker's three
streams is what stops the caller's shell tool from blocking for the entire review. Everything a
controller needs to read is in `worker-err`, which the worker writes for itself.

**One class of launch failure is invisible on Windows.** If the worker dies before its first
statement — a missing interpreter, a blocked execution policy, a script that will not parse —
nothing can report it, because the process that would write the explanation is the one that
failed to start, and the parent cannot see it either. The shell runner does catch the
equivalent, in `launch-err`, because there a shell owns the redirection. Closing the gap would
mean dispatching the worker through `cmd.exe` with its own redirection operators, which cannot
be verified on the platform this file is developed on.

**Discarding an in-flight run can fail on Windows.** `discard --force` on a run that is still
going asks the operating system to delete files the worker holds open. On POSIX that is
routine; on Windows it raises a sharing violation partway through, so the runner reports exit
65, "run directory still present after removal", where the shell runner reports 0. Discarding a
finished run behaves identically on both.

**The reviewer's stdin differs by one byte in review mode.** The shell runner hands codex
`/dev/null` and codex sees nothing at all. The PowerShell runner hands it an empty file, and
PowerShell's own stdin pump terminates the stream with a newline, so codex sees a single line
ending. The same pump terminates a prompt the same way in prompt mode. `codex exec review` does
not read stdin, and a trailing newline on a prompt is harmless, but the two are not
byte-identical.

**Detachment works differently.** The shell runner uses `nohup setsid`, falling back to a
`set -m` subshell where `setsid` is absent, and it exposes `SUPERARTES_CODEX_NO_SETSID` so the
macOS path can be exercised on Linux. The PowerShell runner relies on redirected streams and
ordinary reparenting; it has no process-group semantics and no equivalent switch.

**codex is resolved at different moments.** The shell runner's detached child looks `codex` up
by name on `PATH` at the moment it executes. The PowerShell parent resolves it once, with
`Get-Command -CommandType Application`, and records the absolute path for the worker — which it
must, because the worker's stream redirects force `CreateProcessW`, and that never consults
`PATHEXT`. A consequence unique to Windows is that a `codex.cmd` or `codex.bat` (how npm
installs it) is dispatched through `cmd.exe`; the shell runner has no such layer.

**Symlinked checkouts resolve less thoroughly on Windows PowerShell 5.1.** Both runners record
a work directory as the path it points at rather than the link. `pwd -P` and PowerShell 7
resolve the entire chain; 5.1 has no `ResolveLinkTarget` and resolves only the final component,
leaving an intermediate link in place.

**Two smaller ones.** The PowerShell runner does not tighten permissions on its runs root,
relying on Windows temp being per-user, whereas the shell runner always sets mode 700. And exit
65 covers one extra case on Windows — a worker that could not be launched at all — which has no
shell equivalent, because a backgrounded shell job always starts.

## Verifying invoke-codex.ps1 on a native Windows host

Nothing below has been run on Windows. Everything in `invoke-codex.ps1` was developed and
tested under PowerShell 7 on Linux, which exercises the logic but cannot reach `PATHEXT`,
`cmd.exe` dispatch, execution policy, or the Win32 rules for temp directories and open files.
If you have a Windows machine, these are the checks worth doing, in this order. Run every
block from the repository root in Windows PowerShell.

**Start with the suite.**

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\external-review\Test-InvokeCodex.ps1
```

Expect `117 passed, 0 failed` in a symlink-capable session — Developer Mode or elevation —
and otherwise `113 passed, 0 failed` together with one `SKIP:` line, because the symlinked
work-directory test needs to create a link and announces itself rather than passing quietly.
Those are the only two acceptable outcomes: a count of 113 *without* the `SKIP:` line means
four tests vanished rather than skipped, and is a failure however green it looks. This step
needs no credentials, no network and no model tokens — it supplies its own fake `codex`.

**Everything after this point spends money and sends your code to OpenAI.** Each remaining
step starts a real `codex exec review`: it requires Codex authentication, consumes model
tokens, and uploads the diff of whatever repository you point it at. Do not point it at a
real project. Create a disposable fixture first — a scratch `git init` with one committed
file and one uncommitted edit is enough — and use that path everywhere `C:\fixture` appears
below.

**Then confirm the null device is really gone.** The original Windows-only bug was that
`\\.\NUL` is a DOS device rather than a file, and `Start-Process` validates every redirect path
with `File.Exists`, so every `start` threw before it printed anything. Run one for real:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File skills\external-review\invoke-codex.ps1 start review C:\fixture uncommitted
```

It must print a `RUN_DIR=` line and exit 0 — never exit 1 with a redirection error. Inside that
directory, `null-stdin` must exist and be zero bytes. Poll it with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File skills\external-review\invoke-codex.ps1 status <RUN_DIR>
```

until it reports `STATE=done`; the exit code must be codex's own, not 127.

**Then check the npm install route,** which is the one the Codex documentation recommends and
the one that could not work before. With codex installed that way, `where codex` shows a
`codex.cmd` alongside a `codex.ps1`. Start a run and look at three files: `codex-path` must
contain the full path to the `.cmd`, not a bare name; `err-log` must not mention "not a valid
Win32 application" or error 193; and `exit-code` must hold codex's real exit status. Repeat the
run once with a temp directory whose name contains a space —

```powershell
$spaced = 'C:\Temp with space'
New-Item -ItemType Directory -Force -Path $spaced | Out-Null
$env:TMP = $spaced
$env:TEMP = $spaced
```

— because that is what exercises the `cmd /d /s /c` quoting, and a user account named
"John Smith" produces it by default.

**Check that the test suite really isolates itself.** Windows resolves a temporary directory by
consulting `TMP` first and only then `TEMP`, which is why the suite sets both. To see it for
yourself, point them at two different directories and start a run. Create them first —
`GetTempPath` returns the configured path without creating it:

```powershell
$probeA = Join-Path $env:LOCALAPPDATA 'Temp\probe-a'
$probeB = Join-Path $env:LOCALAPPDATA 'Temp\probe-b'
New-Item -ItemType Directory -Force -Path $probeA, $probeB | Out-Null
$env:TMP = $probeA
$env:TEMP = $probeB
powershell.exe -NoProfile -ExecutionPolicy Bypass -File skills\external-review\invoke-codex.ps1 start review C:\fixture uncommitted
```

The printed `RUN_DIR` must be under `probe-a`. If it is under `probe-b`, the assumption behind
the suite's isolation is wrong and the cross-temp discard test is not testing anything.

**Check that the execution-policy bypass reaches child processes.** What is under test is not
the policy on your machine but whether the bypass propagates: the suite and the runner each
launch further PowerShell processes, and `-ExecutionPolicy Bypass` applies per process rather
than being inherited, so every one of those launches has to pass it explicitly. Record the
effective policy first:

```powershell
powershell.exe -NoProfile -Command "Get-ExecutionPolicy -List"
```

Windows clients default to `Restricted` and Windows Server to `RemoteSigned`; either exercises
the check. What matters is that the effective policy is *not* already `Bypass` or
`Unrestricted` machine-wide, because then the step proves nothing. With a restrictive policy in
force, run the suite command from the top of this section again — it must still pass in full. A
child that failed to inherit the bypass surfaces as a "cannot be loaded because running scripts
is disabled" error rather than as an ordinary test failure.

**Finally, check that starting a review returns immediately.** On Windows, `Start-Process -Wait`
waits for an entire process tree through a job object, and no redirect opts out of it — so a
harness that used it would block for the whole review instead of detaching.

```powershell
powershell.exe -NoProfile -Command "Measure-Command { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File skills\external-review\invoke-codex.ps1 start review C:\fixture uncommitted }"
```

That must come back in seconds, not minutes. In the suite, the same property is what these four
assertions protect: `status of an unfinished run exits 3`, `status names the state honestly`,
`wait exits 3 when it times out`, and `discard of an unfinished run exits 66`. If a change ever
makes `start` block, those are the four that will tell you.
