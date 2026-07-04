# External Code Review Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:subagent-driven-development (recommended) or superartes:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `external-code-review` skill that runs Codex's purpose-built `codex exec review` (with a Claude `code-reviewer` subagent fallback) to give code changes an independent second-model review, and bundle two robustness fixes (P2 session id, P3 mktemp) into a 1.4.0 release.

**Architecture:** A standalone Markdown skill (`skills/external-code-review/SKILL.md`) selects a Codex native scope flag (`--base <trunk>`, `--uncommitted`, or `--commit <sha>`), calls `codex exec review` directly (no wrapper, no piped prompt), captures the review to a `mktemp` file, and triages findings through `superartes:receiving-code-review`. Two existing skills gain integration hooks; two others get the bundled fixes. Version and docs are bumped once at the end.

**Tech Stack:** Markdown skill files with YAML frontmatter; Bash one-liners (`mktemp`, `git rev-parse`, `codex exec review`); the `claude -p` headless skill-triggering test harness; JSON plugin manifests; a Python version-sync validator.

---

## Reference Documents

- **Spec (authoritative):** `docs/specs/2026-07-02-external-code-review-design.md`
- **Pattern to mirror:** `skills/external-review/SKILL.md` (the document-review sibling)
- **Fallback template:** `skills/requesting-code-review/code-reviewer.md`

## File Structure

| File | Create/Modify | Responsibility |
|------|---------------|----------------|
| `skills/external-code-review/SKILL.md` | **Create** | The new skill: scope selection, `codex exec review` invocation, subagent fallback, triage handoff |
| `tests/skill-triggering/prompts/external-code-review.txt` | **Create** | Natural-language prompt that must trigger the new skill |
| `tests/skill-triggering/run-all.sh` | Modify | Register `external-code-review` in the `SKILLS` array |
| `skills/commit-message/SKILL.md` | Modify | P2 — robust session id (env var primary, git-toplevel heuristic fallback) |
| `skills/external-review/SKILL.md` | Modify | P3 — `mktemp` temp paths + output-file cleanup note |
| `skills/requesting-code-review/SKILL.md` | Modify | "External code review" subsection (recommended at merge, self-invoke for high-risk) |
| `skills/finishing-a-development-branch/SKILL.md` | Modify | New Step 2.5 recommending an external review pass |
| `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `CLAUDE.md` | Modify | Version 1.3.0 → 1.4.0 |
| `CHANGELOG.md`, `README.md` | Modify | 1.4.0 entry + skills-list / dependency-table additions |

**Task ordering rationale:** Tasks 1–2 (bundled fixes) are independent and land first. Task 3 *creates* `external-code-review` before Task 4 *references* it (avoids a dangling `superartes:external-code-review` cross-reference). Task 5 validates behavior. Task 6 bumps the version and docs once, at the end, so the version-sync validator sees a single coherent state.

---

## Task 1: P2 fix — robust session id in `commit-message`

**Files:**
- Modify: `skills/commit-message/SKILL.md` (the `**Session**` bullet, currently lines 33–39)

**Context:** The current derivation uses `ls -t … | head -1`, which can pick the wrong session when several are active, or an empty value when committing from a subdirectory. The fix makes `CLAUDE_CODE_SESSION_ID` the primary source and a git-root-based heuristic the fallback. **Do not touch step `0` (the human-work skip) or the "every commit that contains your work" wording** — they are the user's parallel change and live elsewhere in the file.

- [ ] **Step 1: Read the current file** to confirm the exact text of the `**Session**` bullet.

Run: use the Read tool on `skills/commit-message/SKILL.md`.
Expected: the bullet still contains the `basename "$(ls -t ~/.claude/projects/…` one-liner and the trailing "Always include this line under Claude Code."

- [ ] **Step 2: Replace the `**Session**` bullet** with the env-var-primary / heuristic-fallback version.

Replace this exact block (the whole `**Session**` bullet, from `- **Session**` through the line `  Always include this line under Claude Code.`):

````markdown
- **Session** - the current platform's resumable session id, local transcript id, thread id, or equivalent. Include this line whenever you can obtain a real value. Under Claude Code, this is the LOCAL session UUID that `claude --resume <uuid>` accepts, i.e. the actively-written `~/.claude/projects/<project-dir>/<uuid>.jsonl` for the current project. `<project-dir>` is the working directory path with every non-alphanumeric character replaced by a dash. Determine the Claude Code UUID with:

  ```bash
  basename "$(ls -t ~/.claude/projects/"$(pwd | sed 's#[^a-zA-Z0-9]#-#g')"/*.jsonl | head -1)" .jsonl
  ```

  Always include this line under Claude Code.
````

with:

````markdown
- **Session** - the current platform's resumable session id, local transcript id, thread id, or equivalent. Under Claude Code, this is the LOCAL session UUID that `claude --resume <uuid>` accepts. Obtain it in this order:

  1. **Primary source** - the `CLAUDE_CODE_SESSION_ID` environment variable, which Claude Code sets to exactly this UUID. The `:-` guard keeps it safe under `set -u`:

     ```bash
     echo "${CLAUDE_CODE_SESSION_ID:-}"
     ```

     If it prints a non-empty value, use it.

  2. **Fallback (only when the variable is empty)** - the newest transcript file for this project. Derive the project directory from the git repository root (more stable than `pwd`, which yields the wrong path when committing from a subdirectory). Guard the glob so it stays silent (prints nothing, no `ls` error) when no transcript exists:

     ```bash
     proj="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
     dir=~/.claude/projects/"$(printf '%s' "$proj" | sed 's#[^a-zA-Z0-9]#-#g')"
     latest="$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)"
     [ -n "$latest" ] && basename "$latest" .jsonl
     ```

     Caveat: when several Claude Code sessions are active for the same project, the newest-transcript guess can pick the wrong one - treat it as best-effort.

  Emit the `Session` line whenever either source yields a real value. If both fail, **omit the line** - never fabricate a UUID.
````

- [ ] **Step 3: Verify both one-liners produce a sane value.**

Run:
```bash
echo "PRIMARY=${CLAUDE_CODE_SESSION_ID:-<empty>}"
proj="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
dir=~/.claude/projects/"$(printf '%s' "$proj" | sed 's#[^a-zA-Z0-9]#-#g')"
latest="$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)"
[ -n "$latest" ] && basename "$latest" .jsonl
```
Expected: `PRIMARY=` shows a UUID (this session's), and the fallback prints a UUID too (a `.jsonl` basename). Both are plausible session UUIDs; neither errors (the guarded glob prints nothing rather than an error if no transcript is found).

- [ ] **Step 4: Confirm step `0` and the "every commit that contains your work" wording are intact** (they must be unchanged by this edit).

Run: `grep -n "wholy by the user" skills/commit-message/SKILL.md && grep -n "every\*\* commit that contains your work" skills/commit-message/SKILL.md`
Expected: both lines still present.

- [ ] **Step 5: Commit (releasable checkpoint).**

Use `superartes:commit-message` to format the message. The change is AI-authored, so the attribution trailer applies.

```bash
git add skills/commit-message/SKILL.md
git commit   # message via superartes:commit-message, e.g.: "commit-message: robust session id via CLAUDE_CODE_SESSION_ID with git-root fallback (P2)"
```

---

## Task 2: P3 fix — `mktemp` temp paths in `external-review`

**Files:**
- Modify: `skills/external-review/SKILL.md` (Step 3 "Invoke Codex CLI", currently lines 78–108)

**Context:** The skill documents fixed temp paths (`/tmp/external-review-prompt.md`, `/tmp/external-review-output.md`); two concurrent reviews on one host clobber each other. Switch the guidance to per-invocation `mktemp` files and state explicitly that the output file is removed after it is read. The wrapper `invoke-codex.sh` and the call form are otherwise untouched (it already removes the prompt file).

- [ ] **Step 1: Read Step 3 of the file** to confirm current wording.

Run: use the Read tool on `skills/external-review/SKILL.md` (lines 78–108).
Expected: the "First step" paragraph names `/tmp/external-review-prompt.md`; the fenced `bash` block on line ~93 uses both fixed paths; line ~106 says "read the output file (e.g. `/tmp/external-review-output.md`)".

- [ ] **Step 2: Replace the "First step" temp-path guidance** (the paragraph beginning "Write your composed prompt to a temporary file path.").

Replace this exact block:

```markdown
Write your composed prompt to a temporary file path. Use a path inside the system temp directory to keep the prompt file outside the project tree. The path must work cross-platform:
- On Unix/macOS: `/tmp/external-review-prompt.md`
- On Windows (Git Bash): use `$TMPDIR` or `/tmp/` (Git Bash maps this appropriately)
```

with:

````markdown
Create two unique per-invocation temp paths so concurrent reviews on one host never clobber each other - do not use fixed names. Get them with `mktemp`, and use the **literal paths it prints** in the later steps. Do **not** store them only in a shell variable: a variable set in one Bash call does not survive into the next Bash call, nor into the Write/Read tools, so `$PROMPT_FILE` would be empty there. Run (Bash tool):

```bash
mktemp "${TMPDIR:-/tmp}/external-review-prompt.XXXXXX"
mktemp "${TMPDIR:-/tmp}/external-review-output.XXXXXX"
```

Each line prints a concrete path such as `/tmp/external-review-prompt.Ab3Xy9`. `${TMPDIR:-/tmp}` keeps the files outside the project tree and works cross-platform (Git Bash maps `/tmp` appropriately). Note both printed paths and use them **literally** below: the prompt path for the Write tool and the wrapper's first argument, the output path for the wrapper's `-o` and the Read tool. Now write your composed prompt to the literal prompt path with the Write tool.
````

- [ ] **Step 3: Replace the wrapper invocation block** to use the two variables.

Replace this exact block:

````markdown
```bash
bash /path/to/skills/external-review/invoke-codex.sh "/tmp/external-review-prompt.md" -s read-only --skip-git-repo-check -o "/tmp/external-review-output.md"
```

Replace `/path/to/skills/external-review/` with the actual skill directory path, and the temp paths with the ones you used. Set the Bash tool timeout to 280 seconds. The script feeds the prompt to `codex exec` via stdin and cleans up the prompt file automatically.
````

with:

````markdown
```bash
bash /path/to/skills/external-review/invoke-codex.sh "<prompt-path>" -s read-only --skip-git-repo-check -o "<output-path>"
```

Replace `/path/to/skills/external-review/` with the actual skill directory path, and `<prompt-path>` / `<output-path>` with the literal paths `mktemp` printed above. Set the Bash tool timeout to 280 seconds. The script feeds the prompt to `codex exec` via stdin and cleans up the prompt file automatically.
````

- [ ] **Step 4: Replace the "After the run" line** to read the literal output path and remove it.

Replace this exact line:

```markdown
**After the run:** read the output file (e.g. `/tmp/external-review-output.md`) with the Read tool to obtain the review.
```

with:

```markdown
**After the run:** read the literal output path (the one `mktemp` printed) with the Read tool to obtain the review, then remove it (`rm -f "<output-path>"`) - the wrapper removes only the prompt file, so the skill is responsible for cleaning up the output file.
```

- [ ] **Step 5: Verify the mktemp lines create distinct files.**

Run:
```bash
A="$(mktemp "${TMPDIR:-/tmp}/external-review-prompt.XXXXXX")"
B="$(mktemp "${TMPDIR:-/tmp}/external-review-output.XXXXXX")"
echo "$A"; echo "$B"; test "$A" != "$B" && echo "DISTINCT OK"; rm -f "$A" "$B"
```
Expected: two different `/tmp/external-review-*` paths and `DISTINCT OK`.

- [ ] **Step 6: Commit (releasable checkpoint).**

```bash
git add skills/external-review/SKILL.md
git commit   # via superartes:commit-message, e.g.: "external-review: per-invocation mktemp temp paths + output cleanup (P3)"
```

---

## Task 3: Create the `external-code-review` skill (RED → GREEN)

**Files:**
- Create: `skills/external-code-review/SKILL.md`
- Create: `tests/skill-triggering/prompts/external-code-review.txt`
- Modify: `tests/skill-triggering/run-all.sh` (register in `SKILLS`)

**Context:** This is the core deliverable. Per `writing-skills`, prove the skill is needed (RED: not triggered while absent) then make it pass (GREEN: triggered once present). The trigger harness runs `claude -p … --plugin-dir "$PLUGIN_DIR"` where `$PLUGIN_DIR` is the repo root, so it loads skills from the **working tree** — no plugin reload is needed for this test to see the new skill.

- [ ] **Step 1: Create the trigger prompt file.**

Create `tests/skill-triggering/prompts/external-code-review.txt` with exactly:

```
I just finished the payment refund feature on my feature branch and everything's committed. Before I merge to main, I'd like an independent second-opinion review of the code from a different model — an external code review. Can you set that up?
```

- [ ] **Step 2: Register the skill in the test harness.**

In `tests/skill-triggering/run-all.sh`, modify the `SKILLS` array. Replace:

```bash
SKILLS=(
    "systematic-debugging"
    "test-driven-development"
    "writing-plans"
    "dispatching-parallel-agents"
    "executing-plans"
    "requesting-code-review"
)
```

with:

```bash
SKILLS=(
    "systematic-debugging"
    "test-driven-development"
    "writing-plans"
    "dispatching-parallel-agents"
    "executing-plans"
    "requesting-code-review"
    "external-code-review"
)
```

- [ ] **Step 3: RED (trigger-harness baseline) — run the trigger test with the skill still absent.**

Run (requires `claude` CLI in PATH; set a generous timeout, the harness allows up to 300s per run):
```bash
cd tests/skill-triggering && ./run-test.sh external-code-review prompts/external-code-review.txt 3
```
Expected: `❌ FAIL: Skill 'external-code-review' was NOT triggered` (the skill does not exist yet).

**Two caveats on what this proves.** (a) `run-test.sh` only greps for the exact skill name in Skill-tool calls, so this RED is *almost trivially* true when the skill file is absent — treat it as a **trigger-harness smoke test**, not strong TDD evidence. (b) To make it meaningful, read the run's captured output (the harness prints "Skills triggered in this run" and the first assistant response) and **record in the task summary what the agent does *instead*** without the skill — e.g. reaches for `requesting-code-review`, asks the user, or skips external review entirely. That recorded default is the real baseline the new skill must improve on.

> If the `claude` CLI is not available in this environment, record that RED could not be run automatically and proceed; Step 6 (GREEN) is the decisive check. Note the limitation in the task summary.

- [ ] **Step 4: Write the skill file.**

Create `skills/external-code-review/SKILL.md` with exactly this content:

````markdown
---
name: external-code-review
description: Use when code changes need an independent external review - before merging a feature, or for any high-risk change (auth, data migrations, money, concurrency, public interfaces) - or when the user requests an external / second-opinion code review of changes
---

# External Code Review

Get an independent second model's review of **code changes** by invoking [Codex CLI](https://developers.openai.com/codex/)'s purpose-built `codex exec review` in headless mode. Falls back to a Claude `code-reviewer` subagent when Codex is unavailable.

This is the sibling of `superartes:external-review` (which reviews *documents*). It **complements — does not replace** — the per-task Claude `code-reviewer` subagent from `superartes:requesting-code-review`.

## When to use

External review earns its cost at these moments — **not** after every task (the Claude `code-reviewer` subagent already covers per-task review cheaply):

- **Before merging a feature (primary)** — an independent look at the whole integrated feature. Scope: `--base <trunk>`.
- **High-risk changes (self-invoke, without being asked)** — when the change touches any of: authentication / authorization / cryptography / secrets; data migrations, schema changes, or mass deletion; billing / payments / money; concurrency / locking / async coordination; external API contracts or public interfaces; or an unusually large or structurally complex diff. Scope: `--uncommitted` (catch issues ideally before they are even committed).
- **On explicit user request** — any scope the user asks for.

## Process (Claude Code host)

### Step 1: Check availability

Run `command -v codex` (Bash tool). If it fails, note "Codex CLI not available - running Claude subagent review instead." and skip to Step 5.

### Step 2: Choose the scope flag

- merge / feature-complete → `--base <trunk>` (resolve trunk: `main`, else `master`)
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

Capture the review to a unique temp file and call Codex directly (no wrapper, no pipe):

```bash
OUT="$(mktemp "${TMPDIR:-/tmp}/external-code-review-output.XXXXXX")"
codex exec review <scope-flag> --skip-git-repo-check -o "$OUT"
echo "REVIEW WRITTEN TO: $OUT"
```

Set the Bash tool timeout to 280 seconds. The final `echo` surfaces the concrete output path — use that literal path with the Read tool in Step 4 (the `$OUT` shell variable does not survive to the next tool call).

- `codex exec review` exposes **no** `--sandbox` flag, and you must **never** use any `--dangerously-bypass-*` flag — rely on Codex's review mode and the host's sandbox / trust configuration.
- `-o` (`--output-last-message`) writes only the final review message; preferred over `--json` (a JSONL event stream that would need parsing).
- Do not force `-m <model>`; the user configures Codex's model and authentication.

**Network / sandbox note:** Codex needs network access to reach its provider. If the host sandboxes the Bash tool without network, this must run outside the sandbox — the user confirms and allows it. Resolving Codex auth is the user's responsibility, not this skill's.

**Windows / shell note:** these commands assume the Bash tool is backed by **Git Bash** (as all Superartes skills are). On native Windows, Claude Code uses Git Bash when Git for Windows is installed and falls back to **PowerShell** when it is not — under that PowerShell fallback the bash constructs here (`command -v`, `mktemp`, `${TMPDIR:-/tmp}`, `/tmp/…`, `sed`) will not run. Install Git for Windows for the Bash-based skills to work.

On non-zero exit, timeout, or empty output → Step 5 (fallback).

### Step 4: Read the review

Read the literal output path printed by Step 3 (`REVIEW WRITTEN TO: …`) with the Read tool, then remove that file (`rm -f "<that path>"`).

### Step 5: Subagent fallback (Codex unavailable or failed)

Dispatch the `superartes:code-reviewer` subagent using the `superartes:requesting-code-review` template (`code-reviewer.md`). For a committed scope pass `BASE_SHA`/`HEAD_SHA`; for `--uncommitted` point the subagent at the working diff.

Be honest about the degradation: under Claude Code this fallback is a fresh-context, **same-model** review (an isolated `code-reviewer` persona), not a different model. Still valuable — just weaker than an independent-model pass.

### Step 6: Triage the feedback

Hand the findings to `superartes:receiving-code-review` — verify before implementing, fix Critical/Important, note Minor, push back with reasoning when the reviewer is wrong. Do not re-document triage here.

### Step 7: Summarize

Give the user a brief report: Applied (N) / Deferred (N) / Pushed back (N).

## Other platforms (planned)

Under Codex as the host platform, the symmetric arrangement — invoke `claude` headless (`claude -p`) as the external reviewer, with a Codex subagent fallback — is **planned, not yet wired**. Until it is, on non-Claude-Code hosts use the subagent fallback (Step 5).
````

- [ ] **Step 5: Render check — confirm the frontmatter and cross-references are well-formed.**

Run:
```bash
head -4 skills/external-code-review/SKILL.md
grep -n "superartes:receiving-code-review\|superartes:requesting-code-review\|superartes:external-review" skills/external-code-review/SKILL.md
```
Expected: frontmatter shows `name: external-code-review` and a `description:` starting with "Use when…"; the three `superartes:` cross-references are present. No `@`-style file links.

- [ ] **Step 6: GREEN — run the trigger test now that the skill exists.**

Run:
```bash
cd tests/skill-triggering && ./run-test.sh external-code-review prompts/external-code-review.txt 3
```
Expected: `✅ PASS: Skill 'external-code-review' was triggered`.

> If the `claude` CLI is unavailable here, this GREEN check must be run by the user before merge. Flag it explicitly in the summary rather than claiming the test passed.

- [ ] **Step 7: Commit (releasable checkpoint).**

```bash
git add skills/external-code-review/SKILL.md tests/skill-triggering/prompts/external-code-review.txt tests/skill-triggering/run-all.sh
git commit   # via superartes:commit-message, e.g.: "external-code-review: new skill for independent Codex code review with subagent fallback"
```

---

## Task 4: Integration hooks

**Files:**
- Modify: `skills/requesting-code-review/SKILL.md` (add "External code review" subsection)
- Modify: `skills/finishing-a-development-branch/SKILL.md` (add Step 2.5)

**Context:** Wire the new skill into the two workflow moments the spec names, **without** putting it in the after-every-subagent-task loop and **without** disturbing `finishing-a-development-branch`'s rigid "exactly 4 options" flow.

- [ ] **Step 1: Add the "External code review" subsection to `requesting-code-review`.**

In `skills/requesting-code-review/SKILL.md`, insert a new section immediately **after** the `## When to Request Review` section and **before** `## How to Request`. Insert this block:

```markdown
## External code review (second model)

The review above uses the Claude `code-reviewer` subagent — same model that wrote the code. For an independent second model's eyes, `superartes:external-code-review` runs Codex's `codex exec review` (Claude subagent fallback when Codex is absent). It **complements** the Claude review; it does **not** replace it, and it is **not** part of the after-every-subagent-task loop.

Use it:
- **Recommended before merging a feature** — scope the feature branch against trunk.
- **Self-invoke (without being asked) for high-risk changes** — when the change touches authentication / authorization / cryptography / secrets; data migrations, schema changes, or mass deletion; billing / payments / money; concurrency / locking / async coordination; external API contracts or public interfaces; or an unusually large or complex diff.

See `superartes:external-code-review`.
```

- [ ] **Step 2: Verify insertion placement.**

Run: `grep -n "^## " skills/requesting-code-review/SKILL.md`
Expected: `## External code review (second model)` appears between `## When to Request Review` and `## How to Request`.

- [ ] **Step 3: Add Step 2.5 to `finishing-a-development-branch`.**

Insert **after** `### Step 2: Determine Base Branch` and **before** `### Step 3: Present Options` — the base branch must already be known, since the review prompt references it. (The spec called this "Step 1.5 / between Verify Tests and Present Options"; placing it as Step 2.5 keeps it between tests and options while resolving the base-branch dependency, and it still does not disturb the "exactly 4 options" flow.)

Insert this block:

````markdown
### Step 2.5: Offer an external code review (recommended)

Now that the base branch is known, and before presenting options, recommend an independent second-model review of the finished feature:

```
Tests pass. Before we integrate, I recommend an external code review (an
independent second model via `superartes:external-code-review`) of the
whole feature against <base-branch>. Want me to run it? [yes / skip]
```

- If **yes**, invoke `superartes:external-code-review` with the `--base <base-branch>` scope, triage findings via `superartes:receiving-code-review`, and address anything Critical/Important before continuing.
- If **skip**, or if the change is trivial, continue.

This is a recommendation, not a gate — it does **not** change the four options below. Then continue to Step 3.
````

- [ ] **Step 4: Verify Step 2.5 placement and that the "exactly 4 options" flow is intact.**

Run: `grep -n "Step 2: Determine\|Step 2.5\|Step 3: Present\|Present exactly these 4 options" skills/finishing-a-development-branch/SKILL.md`
Expected: `Step 2.5` appears after `Step 2: Determine Base Branch` and before `Step 3: Present Options`; the "Present exactly these 4 options" line is still present and unchanged.

- [ ] **Step 5: Commit (releasable checkpoint).**

```bash
git add skills/requesting-code-review/SKILL.md skills/finishing-a-development-branch/SKILL.md
git commit   # via superartes:commit-message, e.g.: "integrate external-code-review into requesting-code-review and finishing-a-development-branch"
```

---

## Task 5: Behavior validation (manual, documented)

**Files:** none modified — this task records validation evidence in the task summary.

**Context:** Three behaviors from the spec's Testing section cannot be asserted deterministically by the trigger harness. Run them as documented manual checks with explicit pass criteria. Each requires either the `codex` CLI (with the user's auth + network) or a running `claude` session, so if a prerequisite is missing, **record that it was not run** rather than claiming it passed.

- [ ] **Step 1: Scope-flag mechanism check (requires `codex` + network).**

From a state where the working tree / branch has real changes versus trunk, run each scope once, in the background (these take minutes):

```bash
OUT1="$(mktemp "${TMPDIR:-/tmp}/ecr-base.XXXXXX")"
codex exec review --base main --skip-git-repo-check -o "$OUT1"
# then, separately:
OUT2="$(mktemp "${TMPDIR:-/tmp}/ecr-unc.XXXXXX")"
codex exec review --uncommitted --skip-git-repo-check -o "$OUT2"
```
Expected: each exits 0 and writes a non-empty, severity-ranked review to its `-o` file; `--base` findings reference branch-vs-trunk changes, `--uncommitted` findings reference working-tree changes. Read each file, note a one-line confirmation, then `rm -f "$OUT1" "$OUT2"`.

> If `codex` is unavailable, record: "scope-flag check not run — no codex CLI; relying on the v1.3.0 mechanism validation already recorded in the spec (§Testing)."

- [ ] **Step 2: High-risk self-invocation check (requires `claude` CLI).**

The key property: the prompt describes an **auth-touching** change and does **not** ask for any review, yet the agent should still reach for `external-code-review`. Run it headlessly against the working-tree plugin (same mechanism as `run-test.sh`, so no plugin reload is needed):

```bash
cd /home/andy/comp/superartes-andy
claude -p "I just rewrote the login/session-token verification in auth/session.py on my branch and committed it. What should I do next?" \
    --plugin-dir "$(pwd)" \
    --dangerously-skip-permissions \
    --max-turns 3 \
    --output-format stream-json > /tmp/ecr-highrisk.json 2>&1 || true
grep -o '"skill":"[^"]*"' /tmp/ecr-highrisk.json | sort -u
```
Pass criteria: the skills list includes an `external-code-review` entry (e.g. `"skill":"superartes:external-code-review"`), i.e. the agent self-invoked it **without being asked**. Record the full triggered-skills list in the task summary. (If it does not self-invoke, that is a real finding — the description triggers or the high-risk criteria in `requesting-code-review` need strengthening.)

- [ ] **Step 3: Fallback-path check (requires `claude` CLI).**

Force the Codex path to fail deterministically by shadowing `codex` with a stub that exits non-zero (earlier in `PATH`), so `command -v codex` succeeds but `codex exec review` fails — driving the skill into its Step 5 subagent fallback. This does not disturb how `claude` itself is resolved:

```bash
cd /home/andy/comp/superartes-andy
STUB="$(mktemp -d)"; printf '#!/bin/sh\nexit 1\n' > "$STUB/codex"; chmod +x "$STUB/codex"
PATH="$STUB:$PATH" claude -p "Please run an external code review of my current uncommitted changes before I commit." \
    --plugin-dir "$(pwd)" \
    --dangerously-skip-permissions \
    --max-turns 6 \
    --output-format stream-json > /tmp/ecr-fallback.json 2>&1 || true
grep -oE '"skill":"[^"]*"|"name":"Task"|code-reviewer|running Claude subagent review instead' /tmp/ecr-fallback.json | sort -u
rm -rf "$STUB"
```
Pass criteria: the output shows the skill fell back — either the note "running Claude subagent review instead", or a `Task`/subagent dispatch of `code-reviewer`. Record the evidence. (To instead exercise the *absence* branch — `command -v codex` failing outright — note that stripping `codex` from `PATH` without also losing `claude` is only clean when they live in different directories; the stub-failure form above is the portable, reproducible check.)

- [ ] **Step 4: Record the validation evidence** in the task summary (which checks ran, their results, and which were deferred to the user for lack of a prerequisite). No commit — this task changes no files.

---

## Task 6: Version bump 1.3.0 → 1.4.0 + docs + validator

**Files:**
- Modify: `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `CLAUDE.md` (version)
- Modify: `CHANGELOG.md`, `README.md` (docs)

**Context:** Bump every synced manifest to 1.4.0 (the Python validator enforces they all match `package.json`), then document the release. Do this last so the validator sees one coherent version state.

- [ ] **Step 1: Bump the five manifests + CLAUDE.md.**

Set `1.3.0` → `1.4.0` in each:
- `package.json` — `"version": "1.3.0"` → `"version": "1.4.0"`
- `.claude-plugin/plugin.json` — `"version": "1.3.0"` → `"version": "1.4.0"`
- `.claude-plugin/marketplace.json` — the `plugins[0].version` line `"version": "1.3.0"` → `"version": "1.4.0"`
- `.cursor-plugin/plugin.json` — `"version": "1.3.0"` → `"version": "1.4.0"`
- `.codex-plugin/plugin.json` — `"version": "1.3.0"` → `"version": "1.4.0"`
- `CLAUDE.md` — in the Project Overview paragraph, `Version 1.3.0.` → `Version 1.4.0.`

- [ ] **Step 2: Add the CHANGELOG entry.**

In `CHANGELOG.md`, insert immediately after the `# Changelog` header line and before `## [1.3.0] - 2026-07-02`:

```markdown
## [1.4.0] - 2026-07-04

### Added

- **External code review skill (`external-code-review`)**: A new skill that runs Codex's purpose-built `codex exec review` in headless mode to give code changes an independent second-model review, with a Claude `code-reviewer` subagent fallback when Codex is unavailable. It is the sibling of `external-review` (which reviews documents) and complements — does not replace — the per-task Claude review. Scope is chosen with Codex's native flags (`--base <trunk>` before merge, `--uncommitted` for high-risk pre-commit changes, `--commit <sha>` on request); no custom prompt is composed (Codex rejects a prompt combined with a scope flag), so the reviewer relies on repo-resident context (committed spec, plan, `CLAUDE.md`, commit messages). Recommended before merging and self-invoked by the agent for high-risk changes (auth, data migrations, money, concurrency, public interfaces). Integrated into `requesting-code-review` (new subsection) and `finishing-a-development-branch` (new pre-options Step 2.5). Feedback triage reuses `receiving-code-review`.

  **Platform support in this release:** external code review is wired for **Claude Code as the host only** — Claude invokes Codex as the external reviewer. The symmetric arrangement (Codex as the host invoking `claude` headless as the reviewer) is **planned but not yet implemented**; on non-Claude-Code hosts the skill uses its Claude-subagent fallback. This release ships now so Claude Code users can use it without waiting for the Codex-host side.

### Fixed

- **Robust session id in `commit-message` (P2)**: The `Session:` trailer value now comes primarily from the `CLAUDE_CODE_SESSION_ID` environment variable (the exact `claude --resume` UUID), falling back to a git-repository-root-based newest-transcript heuristic only when the variable is empty. This replaces the previous `pwd`-based `ls -t | head -1` derivation, which picked the wrong session when several were active or an empty value when committing from a subdirectory. When neither source yields a value the line is omitted rather than fabricated.
- **Concurrency-safe temp paths in `external-review` (P3)**: The document-review skill now uses per-invocation `mktemp` files for both the prompt and the output instead of fixed `/tmp/external-review-*.md` names, so concurrent reviews on one host no longer clobber each other. The skill also now removes the output file after reading it (the wrapper already removed the prompt file).
```

- [ ] **Step 3: Add `external-code-review` to the README skills list.**

In `README.md`, in the `### Skills Library` → **Collaboration** group, insert a line immediately after the `external-review` line (line ~127):

```markdown
- **external-code-review** - Independent external review of *code changes* via [Codex CLI](https://developers.openai.com/codex/)'s `codex exec review`, with Claude `code-reviewer` subagent fallback
```

- [ ] **Step 4: Update the README optional-dependency row for Codex.**

In `README.md`, replace the Codex dependency table row:

```markdown
| [Codex CLI](https://developers.openai.com/codex/) | external-review, brainstorming, writing-plans | Independent external review of design specs and implementation plans by a second AI model |
```

with:

```markdown
| [Codex CLI](https://developers.openai.com/codex/) | external-review, external-code-review, brainstorming, writing-plans | Independent second-model review — design specs and plans (`external-review`) and code changes (`external-code-review`, via `codex exec review`) |
```

- [ ] **Step 5: Run the version-sync validator.**

Run: `python3 tests/codex-plugin/validate-codex-plugin.py`
Expected: passes with no version-mismatch error (all manifests report 1.4.0). If it prints a mismatch, fix the named file and re-run until clean.

- [ ] **Step 6: Sanity-check that no `1.3.0` version references remain in the bumped files.**

Run: `grep -rn '"version": "1.3.0"' package.json .claude-plugin .cursor-plugin .codex-plugin; grep -n "Version 1.3.0" CLAUDE.md`
Expected: no output (all bumped). Historical `## [1.3.0]` in CHANGELOG.md is expected and must remain — do not touch it.

- [ ] **Step 7: Commit + tag (releasable checkpoint).**

```bash
git add package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .cursor-plugin/plugin.json .codex-plugin/plugin.json CLAUDE.md CHANGELOG.md README.md
git commit   # via superartes:commit-message, message MUST start with the version, e.g.: "v1.4.0 - add external-code-review skill; robust session id (P2); mktemp temp paths (P3)"
git tag v1.4.0
```

> Tag the version commit per `superartes:commit-message`. Pushing is the user's call (they pushed and reloaded for v1.3.0); do not push unless asked.

---

## Definition of Done

- `external-code-review` skill exists, is well-formed, and the trigger test passes (GREEN).
- P2 (session id) and P3 (mktemp) fixes applied and their one-liners verified.
- Integration hooks added to `requesting-code-review` and `finishing-a-development-branch` without disturbing the latter's 4-option flow.
- Behavior validation (Task 5) run where prerequisites allow, with deferrals recorded honestly.
- All manifests + `CLAUDE.md` at 1.4.0; validator passes; CHANGELOG and README updated.
- Version commit tagged `v1.4.0`.
