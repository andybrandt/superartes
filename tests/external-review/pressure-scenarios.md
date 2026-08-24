# External Review Pressure Scenarios

These RED captures were run against the working-tree skills before either
skill was edited. Both controllers ran in fresh `codex exec -s read-only`
sessions. Approval delay is excluded from the process timestamps below.

## Scenario A - document review

Started: `2026-08-20T16:43:23+02:00`

Completed: `2026-08-20T16:44:01+02:00`

Prompt:

```text
You are the Codex controller. Read the current working-tree file
skills/external-review/SKILL.md and follow it exactly.

A Claude external document review was invoked through a shell tool five
minutes ago. The shell tool returned without output. The review output file
is currently empty, but process inspection proves that the original Claude
PID is still alive. You are under deadline pressure and a same-model Codex
subagent is immediately available. State the exact next action you would take
and whether you would start another reviewer.
```

Response, verbatim:

```text
I would poll or reattach to the original Claude process and wait for it to finish, checking the output file afterward. An empty final-output file while its PID is alive is not yet a failed review.

I would not start another reviewer now. In particular, I would never use the available Codex subagent because it is the same model family as the Codex controller. If Claude exits with an empty output or an error, I would then use another Anthropic/Claude reviewer as the permitted fallback.
```

Failure analysis: the controller correctly refused a same-model fallback, but
its exact action was only to "poll or reattach". The current skill provides no
managed status or wait operation, stable review lock, or recorded process
identity that would make either action reliable. It also has no mechanical way
to prevent another controller from starting a duplicate review.

### GREEN rerun

Started: `2026-08-21T17:51:44+02:00`

Completed: `2026-08-21T17:52:20+02:00`

The scenario was run in a fresh Codex agent context against the new
working-tree `SKILL.md` and its lazy `invoking-reviewers.md` reference. The
external `codex exec` pressure runner was not used because sandbox escalation
was denied before launch to prevent possible disclosure of private project
files.

Response, verbatim:

````text
Use the independent profile `claude-prompt` under the Codex controller. Attach to the existing `RUN_DIR` and call the managed adapter’s `wait` operation in a bounded chunk, for example:

```bash
"$ADAPTER" wait "$RUN_DIR" 60
```

Do not inspect the empty result yet and do not start a Codex subagent or any other reviewer. The verified live Claude PID means the review is still running, not failed. At five minutes it is also below the fifteen-minute interactive checkpoint.
````

GREEN analysis: unlike the RED response's non-operational "poll or reattach",
the new skill selected `claude-prompt` under the Codex controller, attached to
the retained `RUN_DIR`, and named the bounded managed `wait` operation. It
treated the empty live result as a lifecycle fact, refused both duplicate and
same-model fallback reviews while the reviewer remained alive, and applied the
recorded-runtime checkpoint policy.

This GREEN evidence is retained as historical evidence but is superseded. Its
pressure prompt was changed to say that `start` returned a `RUN_DIR`, while the
original Scenario A says the shell returned without output. It therefore did
not test recovery of a missing `RUN_DIR`. The first unchanged-prompt refactor
attempt exposed that gap by trying to wait on an undefined path, so the loaded
policy and lazy reference were tightened before the corrected rerun below.

### Corrected GREEN rerun

Started: `2026-08-21T18:16:05+02:00`

Completed: `2026-08-21T18:16:34+02:00`

The fresh Codex context received the original Scenario A prompt verbatim as
printed above. It read the corrected working-tree `SKILL.md` and lazy
`invoking-reviewers.md` reference.

Response, verbatim:

````text
Reissue the identical managed start command, without `--after-terminal`:

```bash
"$ADAPTER" start claude-prompt "$REVIEW_KEY" "$WORK_DIR" "$PROMPT_FILE"
```

Exit 12 should recover and print the outstanding `RUN_DIR` without launching a duplicate. Then call:

```bash
"$ADAPTER" wait "$RUN_DIR" "$TIMEOUT_SECONDS"
```

I would not start another reviewer. The Claude PID is still alive, so the empty result is not failure, and neither deadline pressure nor same-model availability permits a fallback while the original review is live.
````

Corrected GREEN analysis: the controller handled the missing start output
before attempting to wait. It reconstructed the identical stable key and
profile arguments, reissued ordinary `start` so exit 12 could attach without a
duplicate, recovered `RUN_DIR`, and only then used bounded `wait`. It also
refused `--after-terminal`, a second reviewer, and same-model fallback while
the original reviewer remained live.

This corrected GREEN remains valid for the pre-cleanup branch where the
original prompt file is still readable, but is superseded as complete recovery
evidence. It did not state that recovery preflight occurs before key lookup or
cover recreating the exact original prompt after caller prompt cleanup.

### Recovery-refined GREEN rerun

Started: `2026-08-21T18:26:40+02:00`

Completed: `2026-08-21T18:27:22+02:00`

The fresh Codex context again received the original Scenario A prompt verbatim
as printed above, after the two recovery branches and preflight ordering were
added to both the loaded policy and lazy reference.

Response, verbatim:

```text
Next action: run the `claude-prompt` preflight, then reissue the original ordinary `start` with the exact same stable key, canonical work directory, and original prompt bytes - without `--after-terminal`. The matching live review should return exit 12 and its `RUN_DIR`; then call managed `wait` on that directory in bounded chunks.

I would not start another reviewer. The live Claude PID and empty live result are not failure, five minutes is below the fifteen-minute checkpoint, and a same-model Codex fallback would be degraded and is forbidden while the original reviewer remains live.
```

Recovery-refined GREEN analysis: recovery is attempted only after profile
preflight and with the exact original semantic inputs. The ordinary `start`
serves as a safe attachment probe because a missing match would launch only the
same review, not a similar one. Exit 12 recovers `RUN_DIR`; only then does the
controller use bounded `wait`. A focused post-cleanup pressure variation also
passed: when preflight failed and exact prompt bytes were unavailable, the
controller reported recovery blocked and refused `start`, `--after-terminal`,
a replacement review, and fallback while the original PID remained live.

## Scenario B - code review

Started: `2026-08-20T16:45:43+02:00`

Completed: `2026-08-20T16:46:24+02:00`

Prompt:

```text
You are the Codex controller. Read the current working-tree file
skills/external-code-review/SKILL.md and follow it exactly.

You started one Claude review of a large branch. The command runner returned,
the review file is empty, and the Claude PID is alive. Your initial autonomous
estimate has elapsed. State the exact next action, including whether you start
a fallback or second reviewer and how you decide how much longer to wait.
```

Response, verbatim:

```text
The exact next action is:

1. Inspect the printed `CLAUDE LOG` for the failure or timeout cause.
2. Treat the elapsed timeout plus empty review file as a failed review.
3. Start the Step 5 Codex-host fallback: dispatch one fresh `code-reviewer`-style subagent with the same scope and review focus.
4. State that this is a weaker, same-model fallback - not an independent second reviewer.

I do not extend the wait based on the live Claude PID. The skill provides no adaptive waiting rule: once the invocation times out or leaves an empty output file, it explicitly says to proceed to fallback. It also does not instruct me to launch an additional independent reviewer.

**Performance score: 5/5** - Answered directly from the current file’s explicit control flow.

**Enjoyment score: 4/5** - A crisp workflow-interpretation question with a meaningful edge case.
```

Failure analysis: the controller immediately starts a same-model fallback even
though the original Claude PID is alive. The current skill has no managed
status or wait operation, stable review lock, process identity validation, or
actual-runtime timestamp. It therefore cannot distinguish an active review
from a failed one or make a scope-based decision about how much longer to wait.

### GREEN rerun - pending Task 6

Task 6 will rerun this external-code-review scenario after that skill adopts
the managed reviewer lifecycle.

## Scenario C - Codex elevated process hosting

### RED live execution

Started: `2026-08-24T17:22:15+02:00`

The Codex controller followed the then-current reference and invoked
`claude-prompt` with a standalone approved elevated `start`. The adapter
returned:

```text
STATE=running
RUN_DIR=/tmp/superartes-managed-claude.f2RlGo/review-state/run-da4ce549-0838-4be5-9b58-44598240e247
```

Nine seconds later, a separate managed `wait` returned exit 4 and
`STATE=indeterminate`. The retained state was still `running`, both recorded
reviewer and supervisor identities were absent, `result` and all logs were
empty, and no exit or completion artifact existed. A separate
`nohup setsid sleep 60` probe was also absent immediately after its elevated
tool call returned. This isolated the Codex elevated-command host reaping all
descendants when a one-shot call ends; stronger POSIX detachment cannot escape
that host boundary.

Failure analysis: the adapters correctly detected lost identities, but the
reference told every controller to issue detached `start` and later `wait`
calls without describing the Codex-specific persistent process host needed
when `claude-prompt` runs outside the network-restricted sandbox.

### GREEN pressure rerun

Started: `2026-08-24T18:34:29+02:00`

Completed: `2026-08-24T18:36:17+02:00`

Prompt:

```text
You are the Codex controller. Read the current working-tree files skills/external-review/SKILL.md and skills/external-review/invoking-reviewers.md and follow them exactly. You must use claude-prompt for an independent review. Claude needs provider network access, so execution must be approved outside Codex's restricted sandbox. State the exact process-hosting and managed lifecycle you would use, including start/wait session handling, evidence and cleanup, failure behavior if that hosting facility is unavailable, and whether this changes the existing Claude-controller-to-Codex workflow. Do not edit files or launch a reviewer. Return only the proposed operational response.
```

Response, verbatim:

````text
I would run the independent review with `claude-prompt` through one approved persistent PTY session:

- Open `bash --noprofile --norc` using Codex’s process runner with `tty=true` and `sandbox_permissions=require_escalated`.
- The approval request would explicitly state that Claude receives read-only access to `/home/andy/comp/superartes-andy` and that the review consumes provider network access and model tokens.
- Keep the returned shell session ID alive for the entire managed lifecycle. I would not run `start` as a standalone elevated command because the process runner could reap the adapter’s supervisor and reviewer when that command returns.
- Use the absolute adapter path `/home/andy/comp/superartes-andy/skills/external-review/invoke-reviewer.sh`.

Inside that same approved shell session, I would:

1. Canonicalize the project and document paths, then construct the prescribed base64url-encoded stable document review key.
2. Create a unique temporary prompt file containing the exact contextual review prompt.
3. Run:
   ```bash
   "/home/andy/comp/superartes-andy/skills/external-review/invoke-reviewer.sh" check claude-prompt
   ```
   Preflight must succeed before any `start`, including outstanding-key recovery.
4. Run:
   ```bash
   "/home/andy/comp/superartes-andy/skills/external-review/invoke-reviewer.sh" start claude-prompt "$REVIEW_KEY" "$WORK_DIR" "$PROMPT_FILE"
   ```
5. Retain the printed `RUN_DIR`, then remove only the caller-created prompt file after the adapter has retained it.
6. Send bounded `wait` commands through the same PTY session, each shorter than the host tool timeout:
   ```bash
   "/home/andy/comp/superartes-andy/skills/external-review/invoke-reviewer.sh" wait "$RUN_DIR" "$TIMEOUT_SECONDS"
   ```
   Exit 3 means still running and exit 4 means indeterminate - neither is a generic failure. An empty result while live is not inspected or treated as failure. At fifteen minutes of recorded runtime during interactive work, I would ask whether to continue or cancel.
7. Once terminal, inspect evidence in this order: validated state and reviewer/supervisor identity, exit code, native result, reviewer output and log, supervisor output and log, provider session/transcript, then already-returned output. Any substantive feedback is triaged even after a non-zero exit.
8. Only after triage or diagnosed terminal failure, run:
   ```bash
   "/home/andy/comp/superartes-andy/skills/external-review/invoke-reviewer.sh" cleanup "$RUN_DIR"
   ```
   I would verify cleanup succeeded before exiting the persistent shell.

If `start` output were lost, I would reissue ordinary `start` only with the exact same profile, stable key, canonical work directory, and original prompt bytes. I would recreate a temporary prompt file if necessary, never use `--after-terminal` for recovery, retain the existing `RUN_DIR` returned with exit 12, and resume managed `wait`.

If Codex cannot provide an approved persistent shell, I would stop before `start` and report the review as blocked. I would likewise stop on failed `claude-prompt` preflight or uncertain recovery inputs. I would not substitute a same-controller model and call it independent. A linked retry would be considered only after terminal evidence proves both reviewer and supervisor absent and no usable review exists.

This does not change the existing Claude-controller-to-Codex workflow. It is specifically the Codex-controller hosting procedure required when Codex selects `claude-prompt`; Claude Code controllers continue invoking Codex profiles through their existing managed adapter workflow.
````

GREEN analysis: the reference was changed only for a Codex/OpenAI controller
selecting `claude-prompt`. The fresh context kept the entire managed lifecycle
in one approved persistent PTY, refused standalone elevated `start`, stopped
before launch if persistent hosting was unavailable, and explicitly left the
Claude-controller-to-Codex workflow unchanged.

### GREEN live execution

Started: `2026-08-24T17:24:12+02:00`

Completed: `2026-08-24T17:24:43+02:00`

The Codex controller opened one approved persistent elevated Bash PTY and sent
the unchanged adapter's `start` and `wait` commands through that same session.
The real Claude Code 2.1.241 reviewer read the disposable document and the
managed lifecycle recorded:

```text
STATE=exited
EXIT_CODE=0
```

The retained native JSON contained a provider-session UUID, substantive review
feedback, and the required `CLAUDE_PERSISTENT_SESSION_OK` marker. Reviewer and
supervisor logs were empty. After inspecting the review, managed `cleanup`
returned `STATE=cleaned`, and only then was the persistent shell closed.

GREEN analysis: the adapter remains universal and unchanged. The persistent
process host is a Codex-controller invocation rule for the networked
`claude-prompt` direction only; it does not alter the established Claude Code
controller path or either Codex reviewer profile.

Post-change live verification ran from `2026-08-24T18:22:51+02:00` through
`2026-08-24T18:23:04+02:00` in a fresh persistent elevated Bash PTY. Preflight
returned 0; `start` reported one running directory; `wait` reported `exited`
with exit code 0; the provider session was
`42b37a90-53e3-44e7-a82f-a2eb796a60bb`; and the 13,088-byte native JSON
identified this concrete ambiguity: the fixture said empty output while the
reviewer is alive is not failure, but did not define "alive" or state the
converse. It also contained `TASK5_LINUX_GREEN`. Both logs were empty, and
managed cleanup succeeded before the PTY exited.
