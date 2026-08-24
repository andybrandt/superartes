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

### GREEN rerun
