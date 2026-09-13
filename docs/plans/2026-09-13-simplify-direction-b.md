# Direct foreground Claude reviews implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Replace Direction B's managed adapter with direct foreground Claude execution, retaining honest completion and retry rules.

**Architecture:** Codex's command-session facility owns one foreground `claude -p` process. The controller retains the command-session identifier and unique artifact paths, polls that session, and inspects terminal output before triage. There is no detached process manager or project-supplied runner.

**Tech Stack:** Existing Codex command tools, Claude Code CLI, host shell; Python only for existing repository validation/tests.

**Status:** Independent review completed and findings incorporated; awaiting Andy's plan approval. Implementation has not started.

**Protected boundary (reconfirmed by Andy):** Do not touch Direction A. Its scripts, tests, Claude-controller subsections, completion diagram and validator checks remain byte-for-byte unchanged. Running its existing suites is verification, not authorization to change them.

**Branch:** `external-for-codex`, current baseline `44555e6`. No worktree, release, version bump or CHANGELOG edit.

## Evidence and limits

Probes on 2026-09-13: Linux x86_64, kernel 6.18.0-1-default, Codex CLI 0.154.0, Claude Code 2.1.270. Commands used the current Codex tool harness; this is not a guarantee for all clients shipping the same CLI version.

1. An approved foreground Python process slept 12 seconds, yielded a command-session identifier after one second, and completed with exit 0 through `write_stdin`. No PTY or interactive shell was needed.
2. A real approved foreground `claude -p` read a disposable design fixture using Read, returned a substantive review and exit 0 across tool yields, and reported `duration_ms: 47013`. This is provider-reported runtime, not independently measured process wall time. Session UUID: `3e8ebbab-6e9c-41c8-a5c5-f1698755b03f`. Native JSON was a transcript array containing a terminal result. It had no permission denials. Artifacts: `/tmp/superartes-direction-b-probes/` (temporary evidence, not a repository dependency).
3. Ctrl-C sent through `write_stdin` to a disposable foreground Python process in a PTY caused KeyboardInterrupt and exit 1. A separate approved inspection confirmed the process absent. Cancellation of a real Claude process remains a live implementation checkpoint.
4. SIGKILL of a disposable foreground Python parent with a `sleep 120` child caused the command session to return 137. Approved process inspection then found both absent. This establishes abrupt command-parent loss on this host, not full Codex application crash behavior.
5. A restricted process listing cannot see these elevated processes. Absence there proves nothing about reviewer termination.
6. Native Windows is not available in this session. Installed `pwsh` is Linux PowerShell and does not establish Windows execution, cancellation or encoding behavior. No native Windows success claim is authorized by these probes.
7. The independently reviewed plan completed through the approved foreground command in **360.39 seconds**, measured by `/usr/bin/time` after approval, with exit 0, no stderr and no permission denials. Provider UUID: `a22f61af-8bbc-40d3-a009-fa31bb7a4f5f`. The command was silent across repeated bounded polls. This measures a real six-minute review, not a synthetic short process.
8. Baseline `python3 tests/codex-plugin/validate-codex-plugin.py` passes. GitHub inspection through `gh pr status` could not reach the API from the sandbox; local history was inspected.

The host losing a command-session identifier while its command continues is different from the command dying. Neither an unknown identifier nor an empty live output file establishes failure. Full host restart/crash behavior remains unverified and the workflow must fail closed in that case.

## Alternatives and recommendation

| Approach | Benefit | Cost |
|---|---|---|
| **Direct foreground invocation (recommended)** | Removes process-management code and runtime dependencies; uses the proven host mechanism | Controller must retain evidence and obey retry rules; no automatic recovery |
| Small foreground helper | Can write uniform timestamps and completion metadata | Adds an interpreter requirement or separate shell implementations; still cannot restore a lost host session |
| Retain the managed adapter in a persistent shell | Keeps automated duplicate guards and richer recovery | Retains 1,266 lines and a second lifecycle even though the shell must remain alive anyway |

Choose direct invocation. Reviews are read-only advisory work; automatic cross-session continuation does not justify the existing manager. Shell quoting is still platform-specific even when process ownership is not. Do not replace the adapter with equivalent lifecycle machinery hidden in documentation.

## Deliberate requirement decisions

| Requirement | Decision and reason |
|---|---|
| Duplicate prevention | Keep the controller rule: one outstanding attempt for the same project and review scope. Deliberately remove cross-controller atomic exclusion and stable-key registry guarantees. Independent Codex conversations are not deduplicated. Never retry because polling yielded, output is empty, or the handle was lost. |
| Cancellation | Keep cancellation through the host's command-session interrupt/termination capability where verified. Require terminal acknowledgement before declaring cancellation or retrying. If the current client exposes no usable cancellation, report that limit and keep the evidence. No PID-based kill utility or custom cancellation locks. |
| Cross-session recovery | Retain prompt, scope, provider session UUID, result and stderr artifacts. Remove automatic live reattachment/restart and registry recovery. After loss of the command handle, inspect retained evidence; if termination cannot be established in the correct execution context, stop and request user intervention. Never use a blind `claude --resume` as recovery. |
| Long reviews | Poll in bounded intervals and provide progress updates. An initial tool yield is not a timeout. No arbitrary short reviewer timeout. |
| Native Windows | Candidate direct-command route only, explicitly unverified until a native Codex-hosted test runs. Do not change user documentation to claim verified support based on Linux PowerShell. |
| Reviewer identity/model | Codex selects Claude, Claude selects Codex. Never pin a model; keep the user's provider defaults. |

## Invocation contract to document

1. Validate document or code scope as today. Resolve installed skill paths from the catalog; this repository task deliberately uses the working-tree versions.
2. Check `claude --version` and `claude --help` for the flags below. Missing executable/capability means unavailable, not an invitation to silently remove restrictions.
3. Create a unique directory with `mktemp -d "${TMPDIR:-/tmp}/superartes-claude-review.XXXXXX"`. On Linux, obtain the UUID from `/proc/sys/kernel/random/uuid`; on macOS use `uuidgen` if that platform is being tested. Never invent the UUID. Save the exact prompt plus plain `work-dir`, `scope` and `session-id` files in that directory. Record the directory, working directory, review scope and UUID as literal values in the controller's reply before launch. Every later tool call uses literal paths; shell variables do not survive between calls.
4. Use the host command tool's working-directory parameter and required sandbox approval. The approval request identifies the project/files exposed to Claude, provider network access and model charges. Honor existing explicit authorization without asking for the same consent again; approval enforcement still applies. Request a short initial yield. Run Claude in the foreground, without `&`, `nohup`, `setsid` or a persistent interactive shell. For this Codex harness, enable a PTY on the foreground command itself so `write_stdin` can send Ctrl-C. Validate this exact PTY launch in Task 1 before switching the skill; the completed real reviews above used pipes, so PTY equivalence is not yet established. If the PTY probe fails, stop and revise the plan rather than claiming cancellation support.
All preparation, execution, inspection and cleanup must resolve the same absolute attempt directory. Before a live run, verify that a file created during preparation is readable in the approved execution context; the current Linux fixture proved this for `/tmp`, but do not generalize to another host.

5. POSIX command template (substitute every angle-bracket value with a quoted literal):

```bash
claude -p --safe-mode --permission-mode dontAsk \
  --tools "Read,Glob,Grep,Bash" \
  --allowedTools "Read,Glob,Grep,Bash(git diff *),Bash(git status *),Bash(git rev-parse *),Bash(git cat-file *),Bash(git show *),Bash(git log *)" \
  --output-format json --session-id '<provider-session-uuid>' \
  < '<absolute-prompt-path>' > '<absolute-result-path>' 2> '<absolute-stderr-path>'
```

6. Retain the returned host command-session identifier separately from the Claude UUID. Poll the existing command with the host's session-input/wait tool. Do not confuse the orchestration tool's cell ID with the shell tool's command-session ID. Keep each blocking wait under 60 seconds for this harness's communication requirements; other clients use their own documented bounds.
7. On terminal return, record exit status. Production output may report Claude's `duration_ms`, labelled provider-reported. For verification only, instrument the same command with `/usr/bin/time -f %e -o <timing-path>` on this Linux host and record independently measured process runtime, excluding approval time. This optional measurement utility is not a production dependency or a lifecycle wrapper. Preserve stderr and native JSON. Locate the final `type: result` item in either object or array output. Inspect error indicators, permission denials and substantive findings; a nonzero status does not erase a usable review. For code, require reported Git/diff inspection evidence.
8. If interrupted, wait for terminal acknowledgement and inspect partial artifacts before reporting cancelled. A missing session is unknown, not cancelled. If the session is lost, inspect artifacts without launching another reviewer. Search only `superartes-claude-review.*` directories and match the recorded physical `work-dir` and exact `scope`; inspect every matching attempt, never select the newest. These files support diagnosis, not automatic restart or atomic exclusion. Process checks, if needed for diagnosis, must use the same execution visibility as the original approved command.
9. Triage substantive feedback. Retain evidence through triage or failure diagnosis. Delete only the exact attempt directory after termination is established and its evidence is no longer needed. Never clean up an unknown/live attempt.
10. Keep the shared Triage and summary instructions, the existing document fallback templates (spec and plan), and external-code-review's Git-evidence requirement. At fifteen minutes in interactive work, give a progress checkpoint and ask via a non-blocking question while retaining the active turn/session; do not assume it survives ending the turn. Abandon means interrupt, then await terminal acknowledgement. If termination is unavailable, say the reviewer may keep spending tokens and retain its evidence. Follow the existing consent requirement for a degraded same-model fallback, but only after the original attempt is confirmed terminal or unavailable. No automatic retry after unknown state.

Omit a native PowerShell invocation recipe in this change and leave native Windows unavailable pending a native test. Do not ship a guessed invocation as a tested path. A native test must exercise UTF-8 prompt input, paths with spaces, exit status propagation, long-running polling and cancellation. PowerShell-on-Linux testing may establish command construction only.

## Task 1: Establish and test the replacement instructions

**Files:** Create `tests/external-review/direct-claude-candidate.md` and `tests/external-review/test-direct-claude.py`; update `tests/external-review/README.md` only for Direction B evidence.

- [ ] First run a silent 15-minute foreground process in a PTY with bounded polls. Record whether it completes; do not infer an unlimited lifetime from success. Full Codex turn interruption (Esc), ending a turn with a live command and application crash need separate host/user-assisted probes and remain explicitly unverified until performed. The workflow must preserve the turn and fail closed after loss; no survival claim depends on these unverified cases.
- [ ] Re-run a real foreground review **with the PTY enabled as specified above**, with process-level elapsed measurement recorded independently of approval waiting. Exercise a real Claude cancellation separately; use a disposable fixture and unique artifacts. Preserve session identifiers and terminal evidence. Do not cancel a useful completed review.
- [ ] Write the candidate direct-invocation reference using the contract above. Keep this task additive: the old adapter remains until Task 2, and both skill entry points still select the old path until the switch is ready. Save the candidate reference temporarily as `tests/external-review/direct-claude-candidate.md` during test development, then move its content to the final reference in Task 2 and delete the candidate.
- [ ] Create standard-library `unittest` coverage that extracts the actual POSIX command example between unique HTML comment markers and executes it against a fake `claude`. Set PATH to the fixture directory only, use an absolute Bash path, and give the fake an absolute interpreter shebang. Never inherit a PATH that can find the real Claude executable, including in the missing-CLI case. Substitute fixture paths and a fixed valid UUID; invoke Bash with `subprocess.run`, capture its actual return status and artifacts. Assert exact prompt bytes, argv restrictions, UUID, separate stdout/stderr and exit status propagation for both success and exit 23. Use fixture paths containing spaces and non-ASCII text. For a missing CLI, assert exit 127, empty stdout/result and stderr naming `claude`. Working-directory selection is a separate harness setup check, not proof of the prose or shell example. The fake CLI must record arguments without invoking a real provider.
- [ ] Add a delayed fake reviewer that proves the command remains foreground (the invoking process has not completed while the fake sleeps). This is command behavior coverage, not a simulation of the Codex harness.
- [ ] Fail the suite immediately if its source command block is missing. Deliberately remove a required flag from a temporary copy of the source and prove the test fails; point it at a missing reference and prove it fails. Never count test-harness failure as the expected reviewer exit.
- [ ] Run `python3 tests/external-review/test-direct-claude.py`; expected: all cases pass. Record the exact count after execution, not a predicted count.

## Task 2: Switch Direction B and remove obsolete machinery together

**Files:** Modify both external review `SKILL.md` files, `tests/codex-plugin/validate-codex-plugin.py`, `README.md`, `tests/external-review/README.md`, and `docs/specs/2026-08-19-universal-external-review-design.md`. Remove `skills/external-review/invoke-reviewer.sh`, `tests/external-review/run-tests.sh`, and `tests/external-review/test-lib.sh`, and its otherwise-unused fixture `tests/external-review/contract.txt` with `git rm`.

- [ ] Change the Codex-controller subsections to follow direct foreground invocation and the new reference. Preserve the four pinned strings listed in the handoff verbatim.
- [ ] Correct shared text referring specifically to Direction B's managed profiles, stable keys or `indeterminate`. Preserve the Claude-controller subsections and completion diagram byte-for-byte. Do not edit, relabel or restructure the existing shared completion diagram or its Direction A prose. Put any necessary precedence statement inside the Codex-controller subsection: Direction B uses the reference's own completion rules. Shared clauses may change only where they explicitly describe Direction B.
- [ ] Replace adapter-specific validator assumptions with checks on the documented Claude command: required restrictions, provider UUID, output format, no model override (`--model`, `--fallback-model`, model-bearing `--settings`, or an `ANTHROPIC_MODEL` assignment), correct reviewer mapping. Keep all Direction A runner checks byte-for-byte unchanged. The validator must stop requiring the deleted adapter.
- [ ] Install the tested candidate reference at `skills/external-review/invoking-reviewers.md`, update its test source path, and remove the temporary candidate.
- [ ] Remove the adapter and its suites in this same checkpoint. This also eliminates the known unsandboxed `codex-review` profile rather than carrying it forward. No Codex profiles belong in the Direction B replacement.
- [ ] Audit tracked references using `git grep -n -E 'invoke-reviewer|managed adapter|managed lifecycle|stable review key|indeterminate'`. Update active instructions, including stale project notes; mark historical plans and pressure evidence as superseded rather than rewriting history. If `tests/external-review/pressure-scenarios.md` remains, explicitly label its adapter-specific scenarios historical. Protected Direction A comments referencing the old adapter are deliberate audit exceptions: `invoke-codex.sh`, `invoke-codex.ps1`, `test-invoke-codex.sh`, and the existing Direction A validator block. Do not edit them for cleanup or demand an empty grep. The final Direction-B-only `indeterminate` paragraph in `skills/external-review/SKILL.md` may be updated; the adjacent Direction A diagram and prose must stay intact.
- [ ] Update user-facing Direction B support claims and the old design's supersession notice. State Linux verification separately from unverified macOS/WSL execution and unavailable native Windows support. WSL is a candidate POSIX route, not a separately verified platform. Keep Direction A wording intact.
- [ ] Run the direct-command tests and plugin validator. Then run both unchanged Direction A suites. Commit only this working, fully switched state; do not commit a reference/entry-point mismatch.

## Task 3: Execute the skills and verify the complete change

- [ ] Follow the final document-review instructions against a real bounded document; inspect native JSON and record process elapsed time, CLI versions, platform and permission denials.
- [ ] Follow the final code-review instructions against a disposable Git fixture containing a known defect. Require Claude to report Git commands and inspected files and identify the defect. This exercises the intended Git commands and code scope, which the Read-only document probe did not exercise. Existing Git permissions are not an operating-system read-only sandbox: git output flags and configured diff/textconv helpers can have side effects. Preserve the existing policy in this change and do not claim stronger isolation.
- [ ] Perform controller walkthroughs for failure handling: missing executable, nonzero reviewer exit with substantive output, empty live output, malformed terminal JSON, cancellation, lost handle and unknown process state. Check that none suggests a duplicate or deletes live evidence. Label these as walkthroughs, not independent behavioral verification: the author knows the expected outcome. A real independent behavioral gate requires a fresh Codex worker with the documented scenario and withheld handle, observing duplicate starts and deletions. That separate agent experiment is optional unless Andy requests it; without it, report agent compliance as unverified. The deterministic command tests only prove shell behavior.
- [ ] Request an independent Claude review of the final changes. The controller executes the documented steps against a fake CLI and supplies commands, fixture setup and captured results for Claude to inspect. Do not ask the restricted reviewer to run Python, Bash test scripts or other denied commands, and do not widen its permissions to make that request possible. Apply substantive findings and rerun affected checks.
- [ ] Run:

```bash
python3 tests/codex-plugin/validate-codex-plugin.py
python3 tests/external-review/test-direct-claude.py
bash tests/external-review/test-invoke-codex.sh
pwsh -NoProfile -File tests/external-review/Test-InvokeCodex.ps1
git diff --check
```

Expected: validator and direct-command tests pass; unchanged Direction A suites report 77 and 117 passing assertions on this Linux host. Investigate any deviation rather than editing the protected suites.

- [ ] Compare the protected Direction A scripts, tests, Claude-controller subsections and completion diagram and existing Direction A validator block against `44555e6`; require byte equality. Confirm all version files still report 1.4.5 and `CHANGELOG.md` is untouched.
- [ ] Update `tests/external-review/README.md` with actual evidence and limitations, including what was simulated and what remains unverified. Record transferable discoveries in `CLAUDE_NOTES.md`, replacing conflicting old lifecycle advice rather than merely appending a contradiction.
- [ ] Use the repository commit-message skill for any commits. Stage only intended files; leave supplied handoffs and other pre-existing untracked documents alone. Do not release or push.

## Review and approval

The handoff supplies the governing requirements; this document combines design decisions and the incremental implementation plan. No separate speculative architecture is needed. Obtain independent plan review, apply justified findings, then obtain Andy's approval before product edits. Native Windows and full-host-crash verification remain explicit environmental limits; they are not reasons to recreate the adapter.

The first external plan-review launch was blocked by automatic approval review. Andy then explicitly authorized sending the Direction B plan, handoff and relevant repository files to Claude. The retry launched successfully. The disposable fixture review above is separate mechanism evidence.

## Independent review triage (2026-09-13)

The authorized Claude review returned success after 360.39 seconds. Applied: isolated fake-only PATH, explicit artifact metadata and UUID source, shared artifact visibility check, PTY launch choice and gate, separate production/provider timing and verification/process timing, approval disclosure, completion/fallback continuity, unused contract fixture removal, protected audit exceptions, validator-block protection and precise platform limitations. The controller will run executable checks and supply evidence to the restricted reviewer. Self-authored failure exercises are now explicitly walkthroughs.

The real six-minute review addresses the missing ordinary-duration evidence; a 15-minute silent PTY soak remains the first implementation prerequisite. Full-host crash and user Esc cannot be reproduced by killing a disposable command parent, so those remain unverified and no recovery guarantee is made. Native Windows recipe omission was selected before triage and is retained. We are not restoring the lock registry or changing Direction A. The existing Git-permission limitation is documented rather than expanded into unrelated permission redesign.
