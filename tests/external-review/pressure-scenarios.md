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
