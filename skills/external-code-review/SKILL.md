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

Choose one scope. Its kind and value are two separate adapter arguments, and two
separate fields of the review key — never a single `kind|value` string.

| Situation | Scope kind | Scope value |
|-----------|------------|-------------|
| Feature complete | `base` | the detected trunk branch |
| Current work | `uncommitted` | none — the scope already covers staged, unstaged and untracked changes |
| Named commit | `commit` | the validated SHA |

Detect the trunk; never assume `main`. `master` and `main` are equally valid and
some repositories deliberately use `master`. Check `git rev-parse --verify --quiet main`
and `git rev-parse --verify --quiet master`, use whichever exists, and ask the
user when both or neither do.

Guard the scope before starting. Stop with "nothing to review" for empty or invalid scope.

```bash
# uncommitted — any staged, unstaged or untracked change?
test -n "$(git status --porcelain)" || echo "NOTHING TO REVIEW"
# base — any difference from the merge-base with the trunk? (three-dot form)
git diff --quiet "<trunk>...HEAD" && echo "NOTHING TO REVIEW"
# commit — does the commit exist?
git cat-file -e "<sha>^{commit}" 2>/dev/null || echo "COMMIT NOT FOUND"
```

## Reviewer selection

| Controller | Independent profile |
|------------|---------------------|
| Claude Code / Anthropic | `codex-review` |
| Codex / OpenAI | `claude-prompt` |
| Unknown or conflicting | Stop and ask |

Determine host from runtime identity, never executable availability. A same-model fallback is degraded.

## Invocation

Read `invoking-reviewers.md` from the sibling `external-review` skill's absolute source directory; never resolve it relative to the user's project. Use a stable code review key containing canonical repository and scope.

`codex-review` runs Codex's own `codex exec review` subcommand with the native
scope flag, so compose no prompt for it. Claude receives an explicit review-only
prompt with equivalent Git commands and must report inspection evidence: commands
used and relevant files inspected.

The managed lifecycle is shared with `superartes:external-review` — follow its
Invocation and Completion sections for key construction, recording `RUN_DIR` as a
literal path across shell calls, bounded `wait` sizing, the fifteen-minute
checkpoint and its cancellation sequence, and the retry preconditions. Never
treat a live process or an empty live result as failure, and never retry
`indeterminate` immediately.

On native Windows, Claude Code has no OS-level sandbox. Safe mode, `dontAsk`, the restricted PowerShell Git allow-list, and the review-only prompt are primary safeguards; state this limitation when selecting `claude-prompt`.

## Completion and triage

Inspect all terminal evidence before fallback. No Git/diff evidence means a Claude response is not a substantive code review. Hand valid findings to `superartes:receiving-code-review`, then report Applied / Deferred / Pushed back.
