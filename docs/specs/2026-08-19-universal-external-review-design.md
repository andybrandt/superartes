# Universal External Review Design

## Overview

Make `external-review` and `external-code-review` work symmetrically under Claude Code and Codex while preserving genuine reviewer independence:

| Controller host | Independent reviewer |
|-----------------|----------------------|
| Claude Code using an Anthropic model | Codex CLI using an OpenAI model |
| Codex using an OpenAI model | Claude Code CLI using an Anthropic model |
| Unknown host | Stop and ask rather than guessing |

The main new mechanism is a managed Claude headless invocation protocol. It prevents a controller from treating an empty result file as failure while `claude -p` is still running. Native Windows is supported with PowerShell rather than requiring Git Bash.

## Motivation

The existing skills were designed for Claude Code as the controller and Codex as the reviewer. Initial work added a Codex-hosted Claude path, but real reviews exposed two failures:

1. A Codex controller could select Codex as its own supposedly independent reviewer.
2. The command runner returned before long-running `claude -p` processes completed. Their result files were empty at that instant, so the controller incorrectly started additional reviewer sessions. The original Claude processes later wrote complete reviews.

A review process returning control, an empty result file, and a completed reviewer session are distinct events. The universal workflow must track them separately.

## Goals

- Select a reviewer from a different model family and harness than the controller.
- Support document and code review in both controller directions.
- Give Claude invocations an explicit identity and observable lifecycle.
- Enforce one external reviewer session per review request unless failure is demonstrated or the user approves another.
- Support Linux, macOS, WSL, and native Windows without requiring Git Bash on Windows.
- Preserve review artifacts until the review is triaged or a failure is diagnosed.
- Keep the established Claude Code to Codex behavior stable except where native Windows needs an equivalent PowerShell path.

## Non-goals

- Treating a same-model subagent as an independent external review.
- Replacing the existing feedback triage in `receiving-code-review`.
- Adding an external review after every small implementation task.
- Adding GitHub Actions in this change. Automated native-Windows coverage is tracked in [GitHub issue #4](https://github.com/andybrandt/superartes/issues/4).
- Providing OS-level sandboxing for Claude Code on native Windows. Claude Code does not currently provide it there; this design applies the strongest available application-level restrictions and documents the limitation.

## Reviewer Selection

Both skills start with the same mandatory decision:

1. Determine the active controller host and model family from the current runtime.
2. Select the opposite provider's CLI.
3. If the host is unknown, stop and ask the user.
4. Never describe a same-provider fallback as independent.

If the external CLI is unavailable before a session starts, the skill may use the best isolated same-model fallback available in the controller. It must label that result as degraded, not independent.

## Shared Claude Invocation Protocol

### Components

Add two platform-native implementations with the same public contract:

- `skills/external-review/invoke-claude.sh` for Linux, macOS, and WSL.
- `skills/external-review/invoke-claude.ps1` for native Windows.

The Bash implementation must not require Python, Node.js, `jq`, or PowerShell. The PowerShell implementation targets Windows PowerShell 5.1 and must also work under PowerShell 7.

On native Windows, the skills prefer the PowerShell adapter even when Git Bash is installed. On POSIX systems and WSL, they use the Bash adapter. Detailed command syntax lives in each helper's `--help` output so both skills can reference one protocol without duplicating fragile shell instructions.

### Operations

Both helpers provide four operations:

- `start <prompt-file>` creates a private run directory, launches exactly one detached Claude process, and prints literal identifiers and artifact paths.
- `status <run-directory>` reports lifecycle state, session identity, elapsed time, process liveness, and artifact paths.
- `cancel <run-directory>` terminates only the recorded reviewer process and its descendants, while preserving evidence.
- `cleanup <run-directory>` removes only recognized helper artifacts after triage or diagnosis.

The helpers report lifecycle facts. They do not choose timeouts, start fallbacks, parse review findings, or decide whether feedback is correct.

### Run artifacts

Every run uses a unique private temporary directory and records at least:

- A helper marker used to validate later operations.
- A pre-generated UUID passed to Claude through `--session-id`.
- The Claude process identifier.
- Current lifecycle state.
- Start and completion timestamps.
- Exit status when known.
- The original prompt.
- Raw JSON result output.
- Standard error and diagnostic log.

The two adapters use the same filenames and state values so the skills can describe one result-handling protocol.

### Lifecycle states

The normal states are:

- `starting` - the run directory exists but the Claude process is not yet confirmed.
- `running` - the process identifier is recorded and the process is alive.
- `succeeded` - Claude reached a terminal state with a zero exit status and non-empty JSON output.
- `failed` - Claude reached a terminal state without satisfying the success conditions.
- `cancelled` - the controller deliberately terminated the run.
- `indeterminate` - artifacts disagree, for example a recorded running state with no live process and no terminal metadata.

Status updates are atomic so polling does not read partially written metadata. `indeterminate` requires investigation and is never an automatic reason to retry.

### Claude command restrictions

Claude runs with:

- `--safe-mode` to disable recursive loading of project plugins, hooks, skills, MCP servers, and project customizations.
- `--permission-mode dontAsk` so unapproved operations are denied instead of waiting for interactive permission.
- `--output-format json` for a machine-readable result containing review text and session metadata.
- The pre-generated `--session-id`.
- A restricted tool set containing file reading and searching plus narrowly allowed Git inspection commands.

On POSIX systems, Git inspection uses restricted Bash permission rules. On native Windows, it uses equivalent PowerShell permission rules. Edit and write tools are unavailable. The prompt explicitly says the task is review-only and forbids file modification.

The PowerShell adapter sets `CLAUDE_CODE_USE_POWERSHELL_TOOL=1` for the reviewer process. This makes the selected Claude shell match the PowerShell tool restrictions even on native Windows machines where Git Bash is also installed. It does not change the user's persistent Claude configuration.

## Waiting and Timeout Policy

The helpers never impose an automatic review timeout.

For interactive work:

- Fifteen minutes is a status checkpoint, not a failure boundary.
- If Claude is still alive, the controller reports the elapsed time and asks whether to continue waiting or cancel.
- It must not start another reviewer while the first remains alive.

For autonomous work:

- Before or shortly after launch, the controller chooses a reasonable deadline based on the document or diff size, number of files, repository complexity, review depth, and likely tool use.
- The controller may extend its estimate when the initial judgment was clearly too low.
- A live reviewer is not a failed reviewer merely because an estimate elapsed.
- If the controller ultimately decides the review has exceeded a reasonable bound, it terminates that run, records the timeout decision, inspects all artifacts, and starts a fallback only when no substantive review exists.

This language intentionally leaves room for controller judgment. A small document and a repository-wide code review should not inherit the same arbitrary hard limit.

## Completion, Failure, and Retry Rules

One review request starts one external reviewer session. Another reviewer session requires either explicit user approval or evidence that the first produced no usable review.

Before any retry or fallback, inspect in this order:

1. Helper lifecycle state and process liveness.
2. Exit status.
3. JSON result artifact.
4. Diagnostic log.
5. Recorded session identifier and available session metadata or transcript.
6. Any reviewer output already streamed or returned to the controller.

If substantive review feedback exists anywhere, stop and triage it. A non-zero exit or an unusual terminal state does not erase a completed review.

Fallback is allowed only when:

- The selected external CLI was unavailable before a reviewer session started.
- The original process is terminal and the evidence shows it produced no substantive review.
- The controller cancelled the run under the approved timeout policy and confirmed that no usable review was produced.

An empty result file while the process is alive has no failure meaning.

## Document Review Flow

`external-review` composes one contextual, reviewer-neutral prompt containing:

- Project and document context.
- Primary and related document paths.
- Document type and review focus.
- Re-review history when applicable.
- Permission to inspect relevant project files.
- Collaborative framing that asks for issues, alternatives, and improvements without prescribing conclusions.

Invocation then branches by controller:

- Claude Code controller uses Codex CLI through the existing `invoke-codex.sh` on POSIX systems.
- Claude Code controller on native Windows uses a new `invoke-codex.ps1` equivalent.
- Codex controller uses Claude through the managed Bash or PowerShell adapter.

The current Codex-only process diagram and fallback text are replaced with the host-neutral selection and shared completion rules.

## Code Review Flow

`external-code-review` keeps common scope selection and validation before reviewer-specific invocation:

- Feature-complete or pre-merge review compares the feature branch with the detected trunk branch.
- High-risk or pre-commit review includes staged, unstaged, and untracked work.
- A user-named commit reviews that exact commit.
- An empty or invalid scope stops before any external session starts.

Invocation then branches:

- A Claude Code controller uses `codex exec review` with Codex's native `--base`, `--uncommitted`, or `--commit` scope. Native Windows gets PowerShell command guidance rather than Bash syntax.
- A Codex controller composes an explicit Claude prompt with the corresponding Git commands and sends it through the managed Claude adapter.

Both paths hand substantive findings to `receiving-code-review` and summarize applied, deferred, and rejected feedback.

## Native Windows Support

Native Windows support must not depend on Git Bash.

PowerShell scripts use native facilities for GUID generation, private temporary directories, process launch, status inspection, timestamping, and safe file removal. They avoid syntax introduced after Windows PowerShell 5.1.

PowerShell cancellation validates the run marker and recorded numeric process identifier before terminating the reviewer and its descendants. Cleanup validates the helper-owned directory and removes a fixed set of known artifacts before removing the empty directory. It never recursively deletes an arbitrary caller-supplied path.

Claude Code's lack of native Windows OS sandboxing is stated in both relevant skills. Safety relies on safe mode, a restricted tool list, `dontAsk`, and a review-only prompt. The skills must not imply equivalence with an OS sandbox.

Andy will perform the native Windows validation for this release. Automated Windows regression testing remains future work in issue #4.

## Security and Cleanup

Both managed Claude adapters:

- Create private artifacts with owner-only permissions where the platform supports them.
- Quote paths and avoid shell evaluation.
- Keep prompts, output, and logs outside the repository.
- Preserve all evidence until review triage or failure diagnosis completes.
- Separate cancellation from cleanup.
- Reject unrecognized run directories.
- Remove only known helper artifacts and then the empty run directory.

The skills never use Claude's `--dangerously-skip-permissions` option.

## Testing Strategy

### RED baseline

Before changing the committed skill bodies, run pressure scenarios against their current versions and record the behavior. Scenarios combine an early command-runner return, an empty result file, a live Claude process, time pressure, and an easy same-model fallback. The current skills should expose the missing lifecycle rules or the temptation to retry. This is the RED evidence required for editing skills.

Before writing each new helper, add deterministic tests and verify they fail because the helper or required behavior is absent.

### Deterministic adapter tests

Use fake `claude` and `codex` executables so tests require no model credentials or network. Cover:

- Empty output while a slow reviewer remains running.
- Exactly one reviewer process per start operation.
- Generated session UUID passed to Claude.
- Successful JSON result capture.
- Non-zero exit with preserved diagnostics.
- Cancellation of the recorded reviewer only.
- Parallel runs with distinct private directories.
- Paths containing spaces.
- Atomic and consistent state reporting.
- Safe cleanup and rejection of forged run directories.

Run Bash tests locally in the development environment. Commit equivalent PowerShell tests and execute them during Andy's native Windows validation. PowerShell execution in a Linux container may supplement review but does not replace the native Windows test.

### Skill pressure tests

Repeat the RED scenarios after editing each skill. Verify the controller:

- Selects the opposite provider.
- Treats a live process as running even when output is empty.
- Inspects artifacts before fallback.
- Applies scope-sensitive timeout judgment during autonomous work.
- Does not start a duplicate external session.
- Labels a same-model fallback as degraded.

### Real CLI integration

Run actual `claude -p` through the managed adapter for:

- A small document review.
- A small code-diff review in a disposable fixture repository.
- A run whose status is checked before completion.

Verify safe mode, restricted tools, JSON output, session identity, detached execution, terminal status, result capture, and cleanup. Also run the existing Codex review and plugin validation suites as regressions.

The native Windows manual test repeats the deterministic PowerShell suite, at least one real Claude review, and both PowerShell Codex invocation forms used by the skills. It also checks a path containing spaces and the correct PowerShell Git permissions.

## Files and Delivery

Expected product changes:

- Add `skills/external-review/invoke-claude.sh`.
- Add `skills/external-review/invoke-claude.ps1`.
- Add `skills/external-review/invoke-codex.ps1`.
- Modify `skills/external-review/SKILL.md`.
- Modify `skills/external-code-review/SKILL.md`.
- Add deterministic Bash and PowerShell helper tests and test documentation.
- Remove the temporary `claude under codex problem.md` after its evidence is represented by this specification and the tests.
- Update `CHANGELOG.md`.
- Bump version `1.4.5` to `1.4.6` in all synchronized manifests and `CLAUDE.md`.

The three unrelated untracked planning documents remain untouched.

Implementation stays on the existing `external-for-codex` branch and uses no worktrees. Work proceeds in incremental, tested steps so every checkpoint leaves the repository in a working state.

## Success Criteria

- Both review skills select an independent opposite-provider reviewer under Claude Code and Codex.
- Claude reviews have explicit session identity and observable lifecycle state.
- A live Claude process with empty output cannot trigger a retry.
- Interactive and autonomous timeout behavior follows the approved judgment-based policy.
- Bash and PowerShell adapters implement the same external contract.
- Native Windows requires PowerShell but not Git Bash.
- Same-model fallbacks are clearly labeled as degraded.
- Artifacts survive until triage or diagnosis and cleanup cannot target arbitrary paths.
- Deterministic Bash tests, skill pressure tests, real Linux Claude integration tests, existing regressions, and Andy's manual native Windows tests pass.
- Version and release documentation are synchronized at `1.4.6`.

## Future Work

Add credential-free GitHub Actions coverage on Linux and native Windows for the external-review helpers, tracked in [GitHub issue #4](https://github.com/andybrandt/superartes/issues/4). Real-model integration remains manual and must not place Claude or OpenAI credentials in CI.
