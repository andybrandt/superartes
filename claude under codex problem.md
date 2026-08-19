The key flaw is that the plugin treats “external” as independent, even when it invokes the same Codex family as the active agent.

I would change `external-review` along these lines:

```markdown
## Reviewer independence

Choose a reviewer from a different model provider than the active agent.

- If the active agent is Codex/OpenAI, prefer the Claude CLI.
- If the active agent is Claude/Anthropic, prefer Codex CLI.
- A same-provider review is allowed only when the user explicitly asks for it.
- “Claude subagent” does not satisfy this requirement unless it is actually
  executed by Claude, not merely a subagent in the current harness.
```

Also add a strict result-handling rule:

```markdown
## Review completion and retries

A reviewer process exiting successfully is not by itself a failed review merely
because its captured stdout/output file is empty.

Before retrying, inspect, in order:

1. the command exit status;
2. the configured output artifact;
3. the reviewer session id/transcript, if the CLI created one;
4. any streamed tool output already returned to the parent agent.

If a substantive review exists in any of those places, stop and triage it.
Do not invoke a second reviewer session.

Retry only for a demonstrated invocation failure: non-zero exit status,
authentication failure, timeout with no session result, or an explicit CLI
error. State the failure reason before retrying.
```

And make the tool invocation less ambiguous:

```markdown
## Claude CLI invocation

When Claude is the selected reviewer, use its non-interactive mode with a
machine-readable output format where possible, record the returned Claude
session id, and retain the session transcript path until review triage is
complete. Do not rely solely on terminal stdout.
```

Finally, the workflow should have a hard cap:

```markdown
One document review = one reviewer session. Any additional session requires
either user approval or evidence that the first session produced no review.
```

That would have prevented both mistakes: choosing Codex as a “reviewer” for Codex work, and repeatedly rerunning Claude after it had already reviewed the spec.

## Further comments added on 2026-08-19 by Codes (GPT 5):

The note diagnoses this accurately. We do have a real integration problem, and I compounded it by retrying instead of investigating.

What happened:

- The first two `claude -p` reviews were not empty failures.
- The command runner appeared to finish with empty output, but the Claude processes continued and wrote full review reports later:
  - `/tmp/external-review-claude-output.azRPcV` - 18,460 bytes
  - `/tmp/external-review-claude-output.Bp1I3d` - 26,231 bytes
- I checked the files too early, saw zero bytes, and incorrectly treated that as proof no review existed.
- I then started further reviewer sessions. That violates the rule the note proposes: one document review must correspond to one reviewer session unless there is demonstrated failure.

So the root cause is twofold:

1. `external-review` had no controller-host independence guard, so it directed Codex to use Codex.
2. Its CLI protocol treats foreground command completion and an empty capture file as authoritative, without checking whether the reviewer session or child process is still active and may write its result later.

The proposed changes in [`claude under codex problem.md`](/home/andy/comp/superartes-andy/claude%20under%20codex%20problem.md) are the right starting point:

- Select the reviewer by active host: Codex → Claude; Claude → Codex.
- Never call a same-provider result “external” or “independent.”
- Preserve and inspect exit status, output artifact, session/transcript, and already-streamed content before retrying.
- Enforce one reviewer session per document review unless there is a demonstrated invocation failure.

I would make one addition: generate and record a known session identifier before invoking Claude, then poll that session’s output/transcript until it reaches a terminal result or a real timeout. That gives the controller an identity to inspect instead of guessing from a zero-byte file.

I will not invoke Claude or Codex again for this plan. The two existing Claude reports are sufficient independent-review evidence and contain substantive, actionable findings. I will retain their artifacts until we triage them; the zero-byte artifacts are irrelevant.
