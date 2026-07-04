---
name: external-code-review
description: Use when code changes need an independent external review - before merging a feature, or for any high-risk change (auth, data migrations, money, concurrency, public interfaces) - or when the user requests an external / second-opinion code review of changes
---

# External Code Review

Get an independent second model's review of **code changes** by invoking [Codex CLI](https://developers.openai.com/codex/)'s purpose-built `codex exec review` in headless mode. Because Codex runs on one of OpenAI's GPT-series models, this is a genuinely independent review by a *different model family*, not another pass by the same model. Falls back to a Claude `code-reviewer` subagent when Codex CLI is unavailable.

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

## Other platforms (planned)

Under Codex as the host platform, the symmetric arrangement — invoke `claude` headless (`claude -p`) as the external reviewer, with a Codex subagent fallback — is **planned, not yet wired**. Until it is, on non-Claude-Code hosts use the subagent fallback (Step 5).
