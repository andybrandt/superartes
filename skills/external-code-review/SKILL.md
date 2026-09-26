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

Choose one scope. Its kind and value are always two separate arguments — two
positional arguments to the runner under a Claude Code controller, two separate
recorded scope fields under a Codex controller — never a single `kind|value`
string.

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

| Controller | Independent review mode |
|------------|---------------------|
| Claude Code / Anthropic | `codex-review` |
| Codex / OpenAI | `claude-prompt` |
| Unknown or conflicting | Stop and ask |

Determine host from runtime identity, never executable availability. A same-model fallback is degraded.

## Invocation

`codex-review` names Codex's own `codex exec review` subcommand with the native
scope flag, so compose no prompt for it. Claude receives an explicit review-only
prompt with equivalent Git commands and must report inspection evidence: commands
used and relevant files inspected.

### Claude Code controller

Run the background runner from the `external-review` skill's source directory,
passing the scope kind and its value as two separate arguments. Record the printed
`RUN_DIR` as a literal path in your own reply — a shell variable is empty by your
next call.

```bash
"$DIR/invoke-codex.sh" start review "$REPO_DIR" uncommitted
"$DIR/invoke-codex.sh" start review "$REPO_DIR" base "$TRUNK"
"$DIR/invoke-codex.sh" start review "$REPO_DIR" commit "$SHA"
"$DIR/invoke-codex.sh" wait    "<the literal RUN_DIR>" 540
"$DIR/invoke-codex.sh" status  "<the literal RUN_DIR>"
"$DIR/invoke-codex.sh" discard "<the literal RUN_DIR>"
```

Pick ONE `start` line. Every `$NAME` is a placeholder to substitute — `$DIR` the
resolved `external-review` skill directory, `$REPO_DIR` the repository, `$TRUNK` the
detected trunk branch, `$SHA` the validated commit. Only `RUN_DIR` is a literal you
paste back. `status` reports without waiting, and `wait` ends by printing the same
block; take every artifact path from it rather than assembling paths yourself.

Resolve `$DIR` from the sibling skill's absolute source directory as reported by your
skill loader; never resolve it relative to the user's project.

Follow `superartes:external-review`'s Invocation and Completion sections for `wait`
sizing, exit 3 meaning completion-not-recorded rather than failure, the
fifteen-minute checkpoint, what exit 127 means, `discard` semantics, the retry
preconditions, and the rule that both `$DIR` and `RUN_DIR` must be written as absolute
literals because no shell variable survives to your next call. Never treat a live run
as a failure.

Native Windows uses `invoke-codex.ps1` with the same subcommands.

### Codex controller

Read `invoking-reviewers.md` from the sibling `external-review` skill's absolute source directory; never resolve it relative to the user's project. Follow its direct foreground Claude workflow, recording the canonical repository in `work-dir` and the scope kind/value as the reference's labelled lines in `scope`. Include equivalent Git commands in the prompt and require inspected-file and Git/diff evidence. Follow the reference's platform, polling, cancellation and terminal-evidence rules before fallback or cleanup.

## Completion and triage

Inspect all terminal evidence before fallback. The degraded fallback for a code review
is `superartes:requesting-code-review` — a same-model reviewer of the same changes.
`superartes:external-review`'s document templates do not apply here; a diff is not a
document. Label it degraded, never independent. No Git/diff evidence means a Claude response is not a substantive code review. Hand valid findings to `superartes:receiving-code-review`, then report Applied / Deferred / Pushed back.
