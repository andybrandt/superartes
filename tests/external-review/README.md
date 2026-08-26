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

## Codex-controller Linux live checkpoint

Model-backed commands need provider network access and spend model tokens. A
Codex controller must request approval to run them outside its restricted
sandbox. Run `claude-prompt` through the persistent-shell procedure in
`skills/external-review/invoking-reviewers.md`; a standalone elevated `start`
call is unsafe on Codex hosts that reap all descendants when the call ends.
This hosting constraint is specific to the Codex controller. Normal Claude
Code controller behavior is checked separately in an interactive plugin
session.

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

## Codex-controller code-review live checkpoint

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

## Deferred native Windows PowerShell 5.1 checkpoint

Run these commands from Windows PowerShell 5.1 on native Windows. Do not use
Git Bash, PowerShell 7, or WSL. The first command is the native RED mechanism:
it must report only that the runner is missing and return nonzero before the
suite creates any fixtures. The second command runs the real deterministic
suite with fake CLIs. Open Windows PowerShell 5.1 in the repository root and
run the block exactly as written.

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\external-review\Run-Tests.ps1 -RunnerPath C:\definitely-missing\invoke-reviewer.ps1
if ($LASTEXITCODE -eq 0) { throw 'Missing-runner RED unexpectedly passed' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\external-review\Run-Tests.ps1 -RunnerPath .\skills\external-review\invoke-reviewer.ps1
if ($LASTEXITCODE -ne 0) { throw "Deterministic suite failed with $LASTEXITCODE" }
```

PowerShell 7 is deliberately unsupported. On development hosts where `pwsh` is
available, the focused negative-host test verifies that both the adapter and
the native suite reject it before dispatch or fixture creation:

```bash
bash tests/external-review/test-powershell-version-gate.sh
```

Native Windows verification is explicitly deferred and has not yet been run.
Andy allowed later feature work to proceed without claiming native Windows
support is verified. When this gate resumes, record the checkpoint here
without replacing the placeholders until it has actually completed:

- Commit SHA: `<not yet recorded>`
- Windows version: `<not yet recorded>`
- PowerShell version and edition: `<not yet recorded>`
- Deliberately missing runner RED outcome: `<not yet recorded>`
- Deterministic native parity suite outcome: `<not yet recorded>`
- Parent/child cancellation and cleanup outcomes: `<not yet recorded>`

The deterministic Windows suite supplies fake `claude.cmd` and `codex.cmd`
launchers and needs no credentials or network. `Test-ClaudePromptLifecycle`
parses the fake launcher's JSON argument capture and requires this exact
allowed-tools value as one intact argument:

```text
Read,Glob,Grep,PowerShell(git diff *),PowerShell(git status *),PowerShell(git rev-parse *),PowerShell(git cat-file *),PowerShell(git show *),PowerShell(git log *)
```

No credentialed live-profile procedure is part of this feature's current
native Windows validation gate. If a real-model Windows check is separately
resumed and authorized later, a Codex controller may exercise only
`claude-prompt` against a disposable fixture. Normal Claude-controller
behavior must instead be checked in an interactive Claude Code plugin session;
`claude -p` is not evidence for that controller path.
