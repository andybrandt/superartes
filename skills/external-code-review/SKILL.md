---
name: external-code-review
description: Use when code changes need an independent external review - before merging a feature, or for any high-risk change (auth, data migrations, money, concurrency, public interfaces) - or when the user requests an external / second-opinion code review of changes
---

# External Code Review

Obtain an integrated code-change review from a different model family and harness than the controller. This complements, and does not replace, per-task `superartes:requesting-code-review` review.

## When to use

- Recommend before merging a feature and wait for the user's decision.
- Self-invoke for substantive high-risk auth, secrets, migration, deletion, money, concurrency, or public-interface changes.
- Use whenever the user explicitly requests independent code review.

## Scope

- Feature complete: detect actual trunk, then use `base|<trunk>`.
- Current work: use `uncommitted` and include staged, unstaged, and untracked.
- Named commit: validate and use `commit|<sha>`.

Guard the scope before starting. Stop with "nothing to review" for empty or invalid scope.

## Reviewer selection

| Controller | Independent profile |
|------------|---------------------|
| Claude Code / Anthropic | `codex-review` |
| Codex / OpenAI | `claude-prompt` |
| Unknown or conflicting | Stop and ask |

Determine host from runtime identity, never executable availability. A same-model fallback is degraded.

## Invocation

Read `invoking-reviewers.md` from the sibling `external-review` skill's absolute source directory; never resolve it relative to the user's project. Use a stable code review key containing canonical repository and scope. Codex receives its native scope. Claude receives an explicit review-only prompt with equivalent Git commands and must report inspection evidence: commands used and relevant files inspected.

On native Windows, Claude Code has no OS-level sandbox. Safe mode, `dontAsk`, the restricted PowerShell Git allow-list, and the review-only prompt are primary safeguards; state this limitation when selecting `claude-prompt`.

Use managed `wait`; never treat an empty live result as failure. For `indeterminate`, inspect all evidence and never retry immediately. Interactive fifteen-minute checkpoints and autonomous scope-sensitive judgment follow the shared document-review policy.

## Completion and triage

Inspect all terminal evidence before fallback. No Git/diff evidence means a Claude response is not a substantive code review. Hand valid findings to `superartes:receiving-code-review`, then report Applied / Deferred / Pushed back.
