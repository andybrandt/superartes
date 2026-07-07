---
name: external-code-review
description: Use when code changes need an independent external review - before merging a feature, or for any high-risk change (auth, data migrations, money, concurrency, public interfaces) - or when the user requests an external / second-opinion code review of changes
---

# External Code Review

Get an independent second model's review of **code changes** by invoking another AI coding CLI in headless mode. Under Claude Code, invoke [Codex CLI](https://developers.openai.com/codex/)'s purpose-built `codex exec review`. Under Codex, invoke Claude Code headlessly with `claude -p`. In both directions this is a genuinely independent review by a different model family, not another pass by the same model.

This is the sibling of `superartes:external-review` (which reviews *documents*). It **complements — does not replace** — the per-task Claude `code-reviewer` subagent from `superartes:requesting-code-review`.

## When to use

External review earns its cost at these moments — **not** after every task (the Claude `code-reviewer` subagent already covers per-task review cheaply):

- **Before merging a feature (primary)** — recommend it to the user and wait for their decision (a decision gate — see `superartes:finishing-a-development-branch` Step 2.5); if no user is present to make the call (autonomous run), run it automatically. An independent look at the whole integrated feature. Scope: `--base <trunk>`.
- **High-risk changes (self-invoke, without being asked)** — when the change is substantive (e.g. not just comments or documentation) and touches any of: authentication / authorization / cryptography / secrets; data migrations, schema changes, or mass deletion; billing / payments / money; concurrency / locking / async coordination; external API contracts or public interfaces; or an unusually large or structurally complex diff. Scope: `--uncommitted` (catch issues ideally before they are even committed).
- **On explicit user request** — any scope the user asks for.

## Process (Claude Code host)

### Step 1: Check availability

Run `command -v codex` (Bash tool). If it fails, note "Codex CLI not available - running Claude subagent review instead." and skip to Step 5.

### Step 2: Choose the scope flag

- merge / feature-complete → `--base <trunk>` — **detect the trunk name; do not assume `main`.** `master` and `main` are equally valid (some repos deliberately use `master`). Use whichever this repo actually has — check `git rev-parse --verify --quiet master` and `git rev-parse --verify --quiet main`, prefer the one that exists (ask the user if both or neither do), or the branch the user names.
- high-risk / pre-commit / "review my current changes" → `--uncommitted`
- a specific commit the user names → `--commit <sha>`

**Guard — confirm the scope is non-empty before running** (otherwise report "nothing to review" and stop). Use the check matching the scope:

```bash
# --uncommitted: any staged/unstaged/untracked change?
test -n "$(git status --porcelain)" || echo "NOTHING TO REVIEW"
# --base <trunk>: any diff between trunk's merge-base and HEAD?
git diff --quiet "<trunk>"...HEAD && echo "NOTHING TO REVIEW"
# --commit <sha>: does the commit exist?
git cat-file -e "<sha>^{commit}" 2>/dev/null || echo "COMMIT NOT FOUND"
```

For `--base`, `git diff --quiet` exits 0 (and prints `NOTHING TO REVIEW`) when there is no difference; the `...` (three-dot) form compares against the merge-base. Stop if the check reports nothing to review or a missing commit.

Do **not** compose a custom prompt: `codex exec review` rejects a prompt combined with a scope flag (`the argument '[PROMPT]' cannot be used with '--commit <SHA>'`). The reviewer instead relies on repo-resident context it can read — the committed spec in `docs/specs/`, the plan in `docs/plans/`, `CLAUDE.md`, and commit messages.

### Step 3: Run the review

Capture the review to a unique temp file and call Codex directly (no wrapper, no pipe). **Redirect Codex's own stdout/stderr to a log file** — `codex exec review` streams a large exec/event log (often hundreds of KB) to stdout, which overflows the Bash tool's output cap and buries the one line you must see: the `REVIEW FILE:` path. Redirecting keeps the tool's visible output to three short status lines that survive truncation every time:

```bash
OUT="$(mktemp "${TMPDIR:-/tmp}/external-code-review-output.XXXXXX")"
LOG="$OUT.log"
codex exec review <scope-flag> --skip-git-repo-check -o "$OUT" >"$LOG" 2>&1
rc=$?
echo "CODEX EXIT: $rc"
echo "REVIEW FILE: $OUT"
echo "CODEX LOG:   $LOG"
```

Set the Bash tool timeout to 320 seconds. Why each piece matters:
- **`-o "$OUT"`** writes only the final review message to `$OUT`, so redirecting stdout loses nothing — the review itself is still in `$OUT`.
- **`>"$LOG" 2>&1`** sends Codex's verbose event stream to `$LOG` (derived from the unique `mktemp` path, so parallel sessions never collide) instead of the tool's stdout. Without it, the review's large stream buries the `REVIEW FILE:` line and you cannot recover the random `mktemp` path by guessing.
- **`rc=$?` on its own line** captures Codex's real exit status before any `echo` overwrites `$?` — otherwise the trailing `echo` makes the whole Bash-tool call exit 0 and **masks a Codex failure**.

Read the literal `REVIEW FILE:` path with the Read tool in Step 4 (the `$OUT` / `$LOG` shell variables do not survive to the next tool call — use the printed paths). **If `CODEX EXIT` is non-zero — or the review file is empty — do not treat it as a review; inspect `CODEX LOG` for the cause, then go to Step 5 (fallback).**

- `codex exec review` exposes **no** `--sandbox` flag, and you must **never** use any `--dangerously-bypass-*` flag — rely on Codex's review mode and the host's sandbox / trust configuration.
- `-o` (`--output-last-message`) writes only the final review message; preferred over `--json` (a JSONL event stream that would need parsing).
- Do not force `-m <model>`; the user configures Codex's model and authentication.

**Network / sandbox note:** Codex needs network access to reach its provider. If the host sandboxes the Bash tool without network, this must run outside the sandbox — the user confirms and allows it. Resolving Codex auth is the user's responsibility, not this skill's.

**Windows / shell note:** these commands assume the Bash tool is backed by **Git Bash** (as all Superartes skills are). On native Windows, Claude Code uses Git Bash when Git for Windows is installed and falls back to **PowerShell** when it is not — under that PowerShell fallback the bash constructs here (`command -v`, `mktemp`, `${TMPDIR:-/tmp}`, `/tmp/…`) will not run. Suggest the user install Git for Windows so the Bash-based skills work.

On non-zero exit, timeout, or empty output → Step 5 (fallback).

### Step 4: Read the review

Read the literal output path printed by Step 3 (the `REVIEW FILE:` path) with the Read tool, then remove both temp files (`rm -f "<REVIEW FILE path>" "<CODEX LOG path>"`).

### Step 5: Subagent fallback (Codex unavailable or failed)

Dispatch the `superartes:code-reviewer` subagent using the `superartes:requesting-code-review` template (`code-reviewer.md`). For a committed scope pass `BASE_SHA`/`HEAD_SHA`; for `--uncommitted` point the subagent at the working diff.

When falling back because Codex *failed* (non-zero exit or empty review file), the cause is in the `CODEX LOG` file printed by Step 3 — glance at it and tell the user briefly why Codex failed (e.g. auth, network) before running the subagent review.

Be honest about the degradation: under Claude Code this fallback is a fresh-context, **same-model** review (an isolated `code-reviewer` persona), not a different model. Still valuable — just weaker than an independent-model pass.

### Step 6: Triage the feedback

Hand the findings to `superartes:receiving-code-review` — verify before implementing, fix Critical/Important, note Minor, push back with reasoning when the reviewer is wrong. Do not re-document triage here.

### Step 7: Summarize

Give the user a brief report: Applied (N) / Deferred (N) / Pushed back (N).

## Process (Codex host)

### Step 1: Check availability

Run `command -v claude`. If it fails, note "Claude Code CLI not available - running Codex-host fallback review instead." and skip to Step 5.

### Step 2: Choose the scope and guard it

Use the same scope decision rules as the Claude Code host process:

- merge / feature-complete -> compare the feature branch against `<trunk>`. **Detect the trunk name; do not assume `main`.** `master` and `main` are equally valid. Use whichever this repo actually has - check `git rev-parse --verify --quiet master` and `git rev-parse --verify --quiet main`, prefer the one that exists (ask the user if both or neither do), or the branch the user names.
- high-risk / pre-commit / "review my current changes" -> review staged, unstaged, and untracked changes.
- a specific commit the user names -> review that commit.

Confirm the selected scope is non-empty before running:

```bash
# uncommitted: any staged/unstaged/untracked change?
test -n "$(git status --porcelain)" || echo "NOTHING TO REVIEW"
# base: any diff between trunk's merge-base and HEAD?
git diff --quiet "<trunk>"...HEAD && echo "NOTHING TO REVIEW"
# commit: does the commit exist?
git cat-file -e "<sha>^{commit}" 2>/dev/null || echo "COMMIT NOT FOUND"
```

Stop if the check reports nothing to review or a missing commit.

### Step 3: Compose the Claude review prompt

Claude does not have a `codex exec review`-style scope flag, so the scope must be explicit in the prompt. Write the prompt to a unique temp file so long prompts do not hit shell quoting or command-line length limits:

```bash
PROMPT="$(mktemp "${TMPDIR:-/tmp}/external-code-review-claude-prompt.XXXXXX")"
OUT="$(mktemp "${TMPDIR:-/tmp}/external-code-review-claude-output.XXXXXX")"
LOG="$OUT.log"
echo "PROMPT FILE: $PROMPT"
echo "REVIEW FILE: $OUT"
echo "CLAUDE LOG:  $LOG"
```

Use the Write tool to put a prompt like this into the literal `PROMPT FILE:` path:

```text
You are performing an external code review for a developer working under Codex.

Repository: <absolute repository path>
Primary context files you may read:
- CLAUDE.md
- AGENTS.md, if present
- docs/specs/ and docs/plans/, if relevant to the reviewed work

Review scope:
<one of the following>
- Review all changes on the current branch against <trunk>. Use git diff <trunk>...HEAD.
- Review current uncommitted changes. Use git status --porcelain and git diff, and include staged changes with git diff --cached.
- Review commit <sha>. Use git show --stat --find-renames <sha> and git show --find-renames <sha>.

Focus on correctness, regressions, missing tests, security issues, data loss,
concurrency problems, API contract breaks, and maintainability problems that
matter for this change. Lead with findings ordered by severity. For each finding,
include file/line evidence where possible and explain the concrete risk. Avoid
style-only comments unless they hide a real defect. If you find no substantive
issues, say that clearly and mention residual risks or test gaps.

Do not edit files. This is review only.
```

### Step 4: Run Claude headlessly

Feed the prompt through stdin and capture stdout/stderr separately:

```bash
claude -p --safe-mode \
  --allowedTools "Read,Bash(git diff *),Bash(git status *),Bash(git rev-parse *),Bash(git cat-file *),Bash(git show *)" \
  <"$PROMPT" >"$OUT" 2>"$LOG"
rc=$?
rm -f "$PROMPT"
echo "CLAUDE EXIT: $rc"
echo "REVIEW FILE: $OUT"
echo "CLAUDE LOG:  $LOG"
```

Set the shell timeout to at least 320 seconds. Read the literal `REVIEW FILE:` path with the Read tool. If `CLAUDE EXIT` is non-zero - or the review file is empty - do not treat it as a review; inspect `CLAUDE LOG` for the cause, then go to Step 5.

- Do **not** pass `--model` in the production skill command. The user configures Claude's model and authentication. Test harnesses may add a model flag outside this production guidance when cost control is required.
- Do **not** use `--dangerously-skip-permissions`. The review should be read-only.
- `--safe-mode` keeps Claude from loading project plugins and hooks recursively. The prompt explicitly names the repository context Claude should inspect.

After reading the review, remove both remaining temp files (`rm -f "<REVIEW FILE path>" "<CLAUDE LOG path>"`).

### Step 5: Codex-host fallback

If Claude is unavailable or fails, use the best review isolation available in the current Codex host:

- If a subagent or multi-agent review tool is available, dispatch a fresh `code-reviewer`-style subagent with the same scope and prompt focus.
- If no subagent facility is available, perform the review in the current session using the same prompt focus.

Be honest about the degradation: under Codex this fallback is a same-model review, not a different-model pass. Still useful, but weaker than the Claude headless review.

### Step 6: Triage and summarize

Hand the findings to `superartes:receiving-code-review` - verify before implementing, fix Critical/Important, note Minor, and push back with reasoning when the reviewer is wrong. Then give the user a brief report: Applied (N) / Deferred (N) / Pushed back (N).
