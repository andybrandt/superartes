# Universal External Review Design

## Overview

Make `external-review` and `external-code-review` work symmetrically under Claude Code and Codex while preserving genuine reviewer independence:

| Controller host | Independent reviewer |
|-----------------|----------------------|
| Claude Code using an Anthropic model | Codex CLI using an OpenAI model |
| Codex using an OpenAI model | Claude Code CLI using an Anthropic model |
| Unknown or conflicting host identity | Stop and ask rather than guessing |

Two platform-native managed reviewer adapters provide a common lifecycle protocol while preserving the different invocation and output contracts of Claude and Codex. The adapters prevent command-runner timeouts and initially empty result files from causing duplicate reviews. Native Windows uses PowerShell and does not require Git Bash.

## Motivation

The existing skills were designed for Claude Code as the controller and Codex as the reviewer. Initial work added a Codex-hosted Claude path, but real reviews exposed two failures:

1. A Codex controller could select Codex as its own supposedly independent reviewer.
2. The command runner returned before long-running `claude -p` processes completed. Their result files were empty at that instant, so the controller incorrectly started additional reviewer sessions. The original Claude processes later wrote complete reviews.

A shell tool returning, a reviewer process terminating, an output artifact becoming substantive, and a review being triaged are distinct events. The universal workflow must track them separately and enforce one active review mechanically.

## Goals

- Select a reviewer from a different model family and harness than the controller.
- Support document and code review in both controller directions.
- Give every review request a stable identity and observable lifecycle.
- Mechanically prevent a second active reviewer for the same request.
- Allow another attempt only after the original is terminal and failure has been demonstrated, or the user explicitly approves it.
- Support Linux, macOS, WSL, and native Windows without requiring Git Bash on Windows.
- Preserve all review artifacts until feedback is triaged or failure is diagnosed.
- Keep CLI-specific invocation and output behavior explicit rather than forcing both CLIs into a lowest-common-denominator command.

## Non-goals

- Treating a same-model subagent as an independent external review.
- Replacing feedback triage in `receiving-code-review`.
- Adding external review after every small implementation task.
- Adding GitHub Actions in this change. Automated native-Windows coverage is tracked in [GitHub issue #4](https://github.com/andybrandt/superartes/issues/4).
- Parsing or judging review feedback inside the process supervisor.
- Providing a universal OS sandbox. Claude reviewer safety primarily relies on Claude Code's tool-permission layer; native Windows currently has no Claude Code OS sandbox.

## Controller and Reviewer Selection

Both skills use this ordered controller-identification procedure:

1. Use explicit host identity provided by the active runtime or system context.
2. When runtime identity is not explicit, use platform markers as corroborating evidence. Claude Code may expose `CLAUDE_CODE_SESSION_ID` or `CLAUDECODE`; Codex may expose `CODEX_SESSION_ID` or `CODEX_THREAD_ID`.
3. If evidence is absent, contradictory, or describes an unsupported host, stop and ask the user.
4. Never choose a reviewer merely because its executable is present.

After identifying the controller, select the opposite provider. A same-provider fallback is allowed only as a degraded review and is never described as independent.

Host detection receives explicit pressure tests because it is a policy boundary, not an assumption hidden inside a command example.

## Managed Reviewer Architecture

### Platform adapters

Add two implementations of the same public protocol:

- `skills/external-review/invoke-reviewer.sh` for Linux, macOS, and WSL.
- `skills/external-review/invoke-reviewer.ps1` for native Windows.

The Bash adapter must not require Python, Node.js, `jq`, or PowerShell. It uses `uuidgen` when available and a pure Bash plus `/dev/urandom` fallback. The Windows adapter targets the Windows PowerShell 5.1 installation included with Windows 10 and later. PowerShell 7 is not supported.

Native Windows prefers the PowerShell adapter even when Git Bash is installed. POSIX systems and WSL use Bash.

### Reviewer profiles

The shared lifecycle wraps three fixed profiles:

| Profile | Used for | CLI-specific invocation |
|---------|----------|-------------------------|
| `claude-prompt` | Claude document and code review | Prompt on stdin, safe mode, restricted tools, JSON output, generated Claude session UUID |
| `codex-prompt` | Codex document review | Prompt on stdin to `codex exec -`, read-only sandbox, final-message output file |
| `codex-review` | Codex code review | Native `codex exec review` with exactly one of `--base`, `--uncommitted`, or `--commit`; no custom prompt and no sandbox flag |

Each adapter contains small profile-specific command builders. The public scripts do not accept an arbitrary command after `--`. Profile validation rejects unknown flags, missing prompt files, invalid scope combinations, or attempts to add a prompt to `codex-review`.

After command construction, every profile enters the same locking, supervision, waiting, cancellation, and cleanup lifecycle.

### Public operations

Both adapters expose equivalent operations:

- `check <profile>` verifies that the selected CLI exists and advertises the options required by that profile.
- `start <profile> <review-key> <profile-arguments>` acquires the request lock, creates a private run directory, starts a detached supervisor, and returns only after the reviewer process is recorded or launch failure is known.
- `status <run-directory>` reports mechanical lifecycle facts, process identity, elapsed time, and artifact paths.
- `wait <run-directory> <timeout-seconds>` waits until a terminal state or the supplied interval expires. Expiry reports "still running" and never cancels the reviewer.
- `cancel <run-directory>` terminates only the validated reviewer process tree and preserves evidence.
- `cleanup <run-directory>` removes only recognized artifacts after triage or diagnosis.

`wait` uses distinct exit codes for terminal, still-running, and indeterminate outcomes. Agents call it in chunks shorter than their shell tool's own execution cap, then repeat as needed. The chosen review deadline remains a controller judgment, not a helper timeout.

Starting another profile after a demonstrated terminal failure requires an explicit `--after-terminal <previous-run-directory>` argument. The helper validates the link, records the attempt chain, and retains the previous artifacts. It cannot determine whether feedback is substantive; the skill must make and explain that judgment before requesting another attempt.

Detailed command syntax and exit codes live in each adapter's `--help` output and in a shared, lazily loaded reference file:

- `skills/external-review/invoking-reviewers.md`

The two `SKILL.md` files contain reviewer selection, review composition, result policy, and triage only. They do not duplicate platform command recipes.

## Stable Review Identity and Locking

Each skill constructs a stable review key:

- Document review: review kind, canonical project path, canonical primary document paths, and document type.
- Code review: review kind, canonical repository root, scope kind, and scope value.

The helper stores the exact key rather than trusting a lossy filename encoding. Under an atomic registry lock, `start` scans outstanding run metadata for an exact key match.

If a matching request has not been cleaned up:

- A running request causes `start` to refuse and print its existing run directory so the controller can attach and wait.
- A terminal request causes `start` to refuse and direct the controller to inspect and triage it.
- A linked post-failure attempt is allowed only through `--after-terminal`.

The review lock remains until explicit cleanup. This prevents an agent from starting another review after process exit but before reading the result. Atomic directory creation provides the cross-process registry lock on both platforms.

## Detached Supervisor

`start` launches a detached supervisor, not the reviewer directly. The supervisor:

1. Starts the profile-specific reviewer with the prompt file connected to reviewer stdin when required.
2. Records the reviewer process identifier, process-start identity, provider, profile, and optional provider session identifier.
3. Writes `running` atomically before `start` returns.
4. Waits for the reviewer process.
5. Records exit status, completion time, and terminal state atomically.

The supervisor must survive the initiating shell returning, SIGHUP, and the command runner terminating its original process group. On POSIX systems it runs with `nohup`, detached standard streams, and an independent process group. Linux may use `setsid`; the macOS-compatible fallback uses Bash job-control process grouping and must pass the same behavioral tests. On Windows a separately launched hidden PowerShell supervisor owns and waits for the reviewer process.

Detachment cannot defeat a host execution service that forcibly reaps every
descendant when an approved one-shot command ends. This occurs on the tested
Codex controller path when `claude-prompt` must run outside Codex's
network-restricted sandbox. That controller keeps one approved persistent
shell session alive across `check`, `start`, bounded `wait`, evidence
inspection, and cleanup. The existing Claude Code controller path continues to
use the normal detached lifecycle and is unchanged.

Supervisor stdin is detached from the controller, but reviewer stdin comes from the retained prompt artifact. Tests explicitly distinguish these two streams.

Process liveness checks examine terminal metadata first and then validate both the recorded process identifier and its start identity. A recycled process identifier cannot make a completed review appear alive.

## Lifecycle and Artifacts

### Mechanical states

Helpers report facts, not review quality:

- `running` - the validated reviewer process is alive.
- `exited` - the reviewer terminated and its exit code was recorded.
- `launch-failed` - no reviewer process was successfully established.
- `cancelled` - the controller deliberately terminated the validated process tree.
- `indeterminate` - metadata disagrees or the supervisor disappeared without a reliable terminal record.

There is no helper-level `succeeded` or `failed` state. A non-zero exit can coexist with substantive output, and an exit of zero can coexist with unusable or content-free output.

In autonomous work, `indeterminate` means: inspect every artifact and process identity; use substantive feedback if present; otherwise record the diagnostic and perform at most one degraded fallback after the original process is confirmed absent. It never means retry immediately.

### Common artifacts

Every run uses a unique private temporary directory and records:

- A marker containing a random token and the run directory's canonical absolute path.
- Stable review key and attempt-chain metadata.
- Provider and profile.
- Helper-generated run UUID.
- Provider session identifier when available. Claude receives a pre-generated UUID through `--session-id`.
- Supervisor and reviewer process identities.
- Lifecycle state and timestamps.
- Exit status when known.
- Original prompt when the profile uses one.
- Native result and diagnostic artifacts.

The adapters use the same common filenames, state values, UTF-8 encoding without a byte-order mark, and line-ending rules.

### Provider-specific outputs

- `claude-prompt` retains raw Claude JSON and standard error. The JSON may be a single result object or a transcript-style array whose terminal item has `type: "result"`; the helper does not parse or normalize it.
- `codex-prompt` retains Codex's final-message file and execution log.
- `codex-review` retains the native review final-message file and execution log.

The controller reads the profile's native result after a terminal state. Output-file size while the reviewer is running has no completion or failure meaning.

## CLI Preflight and Review Evidence

`check` is credential-free. It checks executable discovery, version output, help text, and required profile flags before a model session starts. It does not claim to validate authentication or model access.

The currently installed Claude Code 2.1.235 has already validated `--safe-mode`, `--permission-mode dontAsk`, `--session-id`, restricted tools, and JSON output in a real review. Production still runs preflight because other machines can have older or incompatible CLIs.

Claude runs with:

- `--safe-mode` to disable plugins, hooks, skills, MCP servers, and project customization, preventing the reviewer from recursively following Superartes workflows.
- `--permission-mode dontAsk` so unapproved operations are denied rather than awaiting interaction.
- `--output-format json` and the generated `--session-id`.
- Read, search, and narrowly permitted Git-inspection tools only.

The permission patterns use the current documented Claude Code prefix form, for example `Bash(git diff *)`. Tests assert that the exact reviewed allow-list reaches the fake CLI.

On native Windows the adapter sets `CLAUDE_CODE_USE_POWERSHELL_TOOL=1` only for the child reviewer and uses equivalent PowerShell Git permission rules. It does not change persistent user configuration.

Claude code-review prompts require a short inspection-evidence section listing the Git commands and relevant files actually inspected. An exit-zero response with no diff or file evidence is not accepted as a substantive code review. Codex native review relies on its tool-enforced scope, with its execution log available for diagnosis.

## Waiting and Timeout Policy

The helpers never impose an automatic overall review timeout.

For interactive work:

- Fifteen minutes of actual reviewer runtime is a status checkpoint, not a failure boundary.
- Approval waiting and shell-tool scheduling are not counted as reviewer runtime.
- If the reviewer is still alive, the controller reports elapsed runtime and asks whether to continue or cancel.
- A running reviewer can never be replaced regardless of elapsed time.

For autonomous work:

- The controller chooses a reasonable deadline based on document or diff size, number of files, repository complexity, review depth, and likely tool use.
- The controller may extend an estimate that proves too low.
- If it ultimately judges the review unreasonably long, it cancels the run, records why, and inspects all artifacts before considering fallback.

The helper's recorded start timestamp is authoritative. Tool-call wall time is not, because it may include user approval delay.

## Completion, Failure, and Fallback

Before any post-failure attempt or fallback, inspect in order:

1. Lifecycle state and validated process identity.
2. Exit status.
3. Native result artifact.
4. Diagnostic log.
5. Provider session identifier and available transcript or session metadata.
6. Any output already returned to the controller.

If substantive review feedback exists anywhere, stop and triage it. A non-zero exit or unusual terminal state does not erase a review.

Fallback is allowed only when:

- The selected external CLI was unavailable before a reviewer started.
- The original reviewer is terminal and evidence shows it produced no substantive review.
- The controller cancelled it under the approved timeout policy and confirmed that no usable review exists.

Any same-model fallback is labeled degraded. Another attempt uses the same stable review key and links to the terminal run through `--after-terminal`.

## Document Review Flow

`external-review` composes one contextual, reviewer-neutral prompt containing project context, document paths and type, related documents, review focus, re-review history, permission to inspect relevant files, and collaborative framing.

Invocation then selects:

- `codex-prompt` under a Claude Code controller.
- `claude-prompt` under a Codex controller.

After the managed run becomes terminal, the controller reads the native result, applies the completion rules, triages feedback, updates the document, and summarizes applied, rejected, and escalated points.

## Code Review Flow

`external-code-review` selects and validates a common review scope before starting a reviewer:

- Feature-complete or pre-merge review compares the feature branch with the detected trunk branch.
- High-risk or pre-commit review includes staged, unstaged, and untracked work.
- A user-named commit reviews that exact commit.
- An empty or invalid scope stops before any reviewer starts.

Invocation then selects:

- `codex-review` under a Claude Code controller, using the native Codex scope flag and no custom prompt.
- `claude-prompt` under a Codex controller, using an explicit prompt with equivalent Git commands and inspection-evidence requirements.

Both paths hand substantive findings to `receiving-code-review` and summarize applied, deferred, and rejected feedback.

## Native Windows Details

Native Windows support must not depend on Git Bash.

The PowerShell adapter:

- Uses Windows PowerShell 5.1-compatible syntax and runs natively on Windows.
- Is invoked with a documented `-NoProfile` and appropriate execution-policy form so repository scripts can run without loading user profiles.
- Uses `[guid]::NewGuid()` and native temporary-path APIs.
- Resolves whether `claude` or `codex` is a native executable or launcher shim and records the actual reviewer process tree rather than assuming the first process is the model CLI.
- Uses `Start-Process -RedirectStandardInput` for prompt delivery rather than unsupported POSIX redirection.
- Writes UTF-8 without a byte-order mark through .NET file APIs.
- Implements atomic updates with same-directory temporary files and replace or rename operations appropriate to whether the destination exists.
- Cancels the validated reviewer and descendants by walking process parent relationships when necessary.

Cleanup rejects symlinks or reparse-point redirection, paths outside the fixed helper temp root, mismatched marker tokens, and moved or copied run directories. It removes a fixed set of known artifacts and then the empty directory. It never recursively deletes an arbitrary caller-supplied path.

Claude reviewer safety on all platforms relies primarily on safe mode, restricted tools, `dontAsk`, and a review-only prompt. Native Windows additionally lacks Claude Code OS sandboxing, and the skills state this plainly.

Andy will run the native Windows validation for this release. Automated Windows regression testing remains future work in issue #4.

## Testing Strategy

### RED baseline for skill edits

Before editing either committed skill body, run pressure scenarios against the current version and record exact behavior. Scenarios combine early command-runner return, an empty output artifact, a live reviewer, time pressure, and an easy same-model fallback. This supplies the RED evidence required by `writing-skills`.

The repository has no automated Codex-controller skill harness. Those pressure runs are manual fresh-context scenarios with recorded prompts and responses. Claude-controller triggering regressions continue to use the existing `claude -p` harness.

### RED baseline for adapters

Before writing each adapter behavior, add deterministic tests and verify they fail because the adapter or behavior is absent.

Tests live under `tests/external-review/` with platform entry points and shared golden contract fixtures. The top-level test documentation explains local Bash execution and Andy's native PowerShell execution.

### Deterministic adapter tests

Fake `claude` and `codex` executables require no model credentials or network. Tests cover:

- Supervisor survives initiating shell return, SIGHUP, and original process-group termination.
- Reviewer exit status is recorded after normal exit, non-zero exit, and signal termination.
- Empty output while the reviewer remains running.
- Exactly one active reviewer per stable review key.
- Existing-run attach information and terminal-attempt linking.
- `wait` terminal, still-running, and indeterminate exit codes.
- Generated Claude session UUID passed to Claude.
- Prompt delivered exactly through stdin.
- Claude allow-list passed verbatim.
- Provider-native result and diagnostic capture.
- Partial or truncated JSON retained without being misclassified.
- Stale and recycled process identifiers.
- Cancellation of the validated reviewer tree only.
- Parallel distinct review keys.
- Paths containing spaces.
- UTF-8 without a byte-order mark and contract parity between adapters.
- Atomic state updates.
- Marker, symlink, copied-directory, and outside-temp-root rejection.
- Unknown operations, missing arguments, invalid profile combinations, and `--help` output.

Run Bash tests locally. Commit equivalent PowerShell tests and run them during Andy's native Windows validation. PowerShell execution in a Linux container may supplement review but does not replace native Windows testing.

### Skill pressure tests

Repeat the RED scenarios after each skill edit. Verify the controller:

- Selects the opposite provider from concrete runtime evidence.
- Attaches to an existing matching run.
- Uses chunked `wait` calls rather than inspecting a live result file.
- Applies scope-sensitive autonomous timeout judgment.
- Inspects all terminal artifacts before requesting another attempt.
- Labels same-model fallback as degraded.

### Real CLI integration

Run actual managed reviews for:

- Claude document review.
- Claude code-diff review in a disposable fixture repository.
- Codex prompt-based document review.
- Codex native code review.
- A run whose status and `wait` behavior are observed before completion.

Verify preflight, restricted tools, provider session identity where available, detachment, locking, terminal state, native result capture, attempt linking, and cleanup. Run existing skill-triggering and plugin validation suites as regressions.

The native Windows manual test repeats the deterministic PowerShell suite and the three profiles with real CLIs where credentials are available. It includes a path containing spaces and verifies PowerShell Git permissions.

## Files and Delivery

Expected product changes:

- Add `skills/external-review/invoke-reviewer.sh`.
- Add `skills/external-review/invoke-reviewer.ps1`.
- Add `skills/external-review/invoking-reviewers.md`.
- Remove the superseded `skills/external-review/invoke-codex.sh`.
- Modify `skills/external-review/SKILL.md`.
- Modify `skills/external-code-review/SKILL.md`.
- Add `tests/external-review/` deterministic Bash and PowerShell tests, fixtures, and documentation.
- Add `*.ps1 text eol=lf` to `.gitattributes`.
- Remove `claude under codex problem.md` after its evidence is represented by this specification and tests.
- Update `README.md` and `CHANGELOG.md`.
- Bump version `1.4.5` to `1.5.0` in `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, and `CLAUDE.md`.

The three unrelated untracked planning documents remain untouched.

Implementation stays on the existing `external-for-codex` branch and uses no worktrees. Work proceeds in incremental, tested steps so every checkpoint leaves the repository working.

## Success Criteria

- Both skills select an independent opposite-provider reviewer under Claude Code and Codex.
- All three reviewer profiles use the same managed lifecycle contract.
- A matching review key cannot have two active reviewers.
- Shell-tool return and empty live output cannot trigger another reviewer.
- Supervisors record terminal state after the initiating shell is gone.
- Interactive and autonomous timeout behavior follows the approved judgment-based policy.
- Bash and PowerShell adapters implement the same state and artifact contract.
- Native Windows requires PowerShell but not Git Bash.
- Same-model fallbacks are clearly labeled degraded.
- Artifacts survive until triage or diagnosis, and cleanup cannot target arbitrary paths.
- Deterministic Bash tests, skill pressure tests, real Linux CLI integrations, existing regressions, and Andy's manual native Windows tests pass.
- Version and release documentation are synchronized at `1.5.0`.

## External Review Decisions

The independent Claude review produced several changes incorporated above: explicit supervisors, mechanical review locks, chunked `wait`, mechanical states, capability preflight, process-identity hardening, native PowerShell details, shared lazy reference documentation, expanded lifecycle tests, cross-provider management, and a minor-version release.

The following suggestions were intentionally declined:

- A fixed minimum review duration, because the approved policy requires scope-sensitive controller judgment.
- The proposed `Bash(git diff:*)` permission form, because current official Claude Code documentation and the installed CLI use the space-before-wildcard prefix form.
- Treating `dontAsk`, `--session-id`, or `CLAUDE_CODE_USE_POWERSHELL_TOOL` as speculative. The first two were exercised successfully in the independent review run; Anthropic documents the PowerShell environment variable.
- Automatic stale-directory deletion, because preserving review evidence is more important than background cleanup. A later start points to the outstanding run so a controller can inspect and explicitly clean it.

## Future Work

Add credential-free GitHub Actions coverage on Linux and native Windows for the managed reviewer adapters, tracked in [GitHub issue #4](https://github.com/andybrandt/superartes/issues/4). Real-model integration remains manual and must not place Claude or OpenAI credentials in CI.
