# External Code Review Integration — Design Specification

## Overview

Add automated **external code review** by invoking Codex CLI's purpose-built `codex exec review` in headless mode. This introduces a new `external-code-review` skill — a sibling to the existing `external-review` skill (which reviews *documents*) — that reviews *code changes* using Codex's native review scopes.

The skill gives the work a second, independent model's eyes on the code, complementing (not replacing) the existing Claude `code-reviewer` subagent. It is recommended before merging, and the agent invokes it on its own for high-risk changes.

This spec also bundles two robustness fixes surfaced when the mechanism was validated by running `codex exec review` against the `v1.3.0` commit (findings P2 and P3 below).

## When To Use External Code Review

External review is spent where an independent second model pays off — **not** after every task (the Claude `code-reviewer` subagent already covers per-task review, cheaply). The moments:

1. **Before merging a feature (primary).** An independent look at the whole integrated feature as it will land. Scope: the feature branch vs trunk (`--base <trunk>`).
2. **High-risk changes (agent self-invokes).** When a change touches auth/crypto/secrets, data migrations or mass deletion, billing/money, concurrency, or external/public interfaces — catch issues, ideally before they are even committed. Scope: the working tree (`--uncommitted`).
3. **On explicit user request**, anytime, at whatever scope the user asks for.

This matches Codex's own framing of review as something you run "after Codex completes work or when you want a second opinion," not continuously.

## Motivation

- **A different model catches different issues.** The Claude `code-reviewer` subagent reviews with the same model that wrote the code. Codex brings genuinely different training and blind spots — the validation run already found two real issues in shipped code.
- **Mirrors the document-review pattern.** `external-review` established the "external AI CLI, Claude subagent fallback, triage" pattern for specs and plans. Code review is the natural symmetric capability for the post-coding phase.
- **Purpose-built tooling exists.** `codex exec review` is a first-class Codex subcommand with native scopes (`--uncommitted`, `--base <branch>`, `--commit <sha>`) that produces structured, severity-ranked, file-and-line findings out of the box.

## Design Decisions

### Standalone skill (not merged into `external-review`)

The code-review logic lives in a new `external-code-review` skill, distinct from `external-review`.

Rationale: different inputs (a git scope vs. a document path) and different Codex invocations (`codex exec review <scope-flag>` vs. `codex exec` with a freeform prompt). Keeping them separate honours the "one clear purpose per skill" principle. They cross-reference each other.

### Scope via Codex's native flags — no custom prompt

The skill scopes the review with Codex's built-in flags, not by describing scope in a prompt:

- **`--base <trunk>`** — review the feature branch's changes against trunk (the merge/feature-complete case).
- **`--uncommitted`** — review staged + unstaged + untracked working-tree changes (the high-risk / pre-commit case).
- **`--commit <sha>`** — review a specific commit, when the user asks for exactly that.

**Constraint that drove this:** `codex exec review` rejects a custom prompt combined with a scope flag (`the argument '[PROMPT]' cannot be used with '--commit <SHA>'`). The two are mutually exclusive. Rather than fight the tool with a fragile "scope described in the prompt" workaround (which relies on the model reading git itself, and forced a dirty-tree-overlap guard), the skill uses the **tool-enforced scope flags**. Scope is then reliable and simple.

**Consequence — no per-invocation custom context.** The reviewer instead relies on **repo-resident context**: the committed spec in `docs/specs/`, the plan in `docs/plans/`, `CLAUDE.md`, and commit messages — which for this well-documented project is substantial, and Codex's review has read access to all of it. This reverses an earlier decision to compose custom instructions; the docs showed the tool is designed around scopes, and its built-in review prompt is already strong. If reviews later prove context-starved, revisit (see Out of Scope).

### No wrapper needed for this skill

Because there is no prompt to pipe via stdin, `external-code-review` calls Codex **directly** (Bash tool):

```bash
OUT="$(mktemp "${TMPDIR:-/tmp}/external-code-review-output.XXXXXX")"
codex exec review --base "<trunk>" --skip-git-repo-check -o "$OUT"
```

No pipe, so no "Unhandled node type: pipeline" sandbox prompt; no wrapper script; no temp prompt file. `external-review`'s `invoke-codex.sh` is **not** touched by this skill (only by the P3 fix below). Output goes to a `mktemp` file read with the Read tool, then removed.

### No sandbox flag; rely on review mode + host

`codex exec review` exposes no `--sandbox` flag (unlike plain `codex exec`). Do **not** pass a sandbox flag, and **never** use `--dangerously-bypass-*` flags — rely on Codex's review mode and the host environment. (Repository-content trust is handled by Codex's built-in review behaviour, since we pass no prompt of our own.)

### Clean output capture with `--output-last-message`

The review is captured with `-o <mktemp file>` and read with the Read tool — same choice as `external-review`. Not `--json` (a JSONL event stream that would need parsing).

### Graceful degradation with Claude subagent fallback

Step 1 checks `command -v codex`. If Codex is unavailable, or the review fails / produces empty output, the skill falls back to dispatching the existing `superartes:code-reviewer` subagent (the template `requesting-code-review` uses). For a committed scope it passes `BASE_SHA`/`HEAD_SHA`; for `--uncommitted` it points the subagent at the working diff.

Rationale: Superartes is a published plugin; not every user has Codex. Everyone still gets a review pass — but the spec is honest that this **degrades from an independent-model review to a structured same-host review**: under Claude Code the fallback is an isolated `code-reviewer` persona with fresh context, not a different model. Still valuable, just weaker.

### Feedback triage reuses `receiving-code-review`

The skill does not re-document how to handle feedback. It defers to `superartes:receiving-code-review` (verify before implementing, fix Critical/Important, note Minor, push back with reasoning when the reviewer is wrong). DRY.

### Integration: recommended, not mandatory-per-task

- `requesting-code-review` gains an "External code review" subsection: *recommended* before merge; the agent **must self-invoke** it for high-risk changes (criteria above). Complements — does not replace — the per-task Claude review, and stays **out** of the after-every-subagent-task loop.
- `finishing-a-development-branch` gets an explicit **Step 1.5** (between "Verify Tests" and "Present Options") recommending an external review pass, placed so it does **not** disturb that skill's rigid "present exactly these 4 options" flow.

Rationale: a full external review after every 2–5 minute subagent task adds latency and token cost for little marginal value. The value concentrates at merge and on risky changes.

### High-risk self-invocation criteria

The agent invokes `external-code-review` on its own — without being asked — when a change touches any of: authentication/authorization/cryptography/secrets; data migrations, schema changes, or mass deletion; billing/payments/money; concurrency/locking/async coordination; external API contracts or public interfaces; or an unusually large or structurally complex diff.

### Platform neutrality (future Codex-host → `claude`)

Framed as "external code review by another model." Under Claude Code: Codex primary (`codex exec review`), Claude subagent fallback. Under Codex as host (a supported platform): the symmetric arrangement — invoking `claude` headless (`claude -p`) as the external reviewer, with a Codex subagent fallback — is documented as an **"Other platforms" note marked planned / not yet wired**, leaving a defined slot for the command Codex will add later.

## New Skill: `external-code-review`

### File structure

```
skills/external-code-review/
  SKILL.md
```

No supporting files: this skill calls Codex directly (no wrapper), and the fallback template (`code-reviewer.md`) is shared and lives in `agents/`.

### SKILL.md responsibilities

**Frontmatter `description` (triggers only, no workflow):**
> Use when code changes need an independent external review — before merging a feature, or for any high-risk change (auth, data migrations, money, concurrency, public interfaces) — or when the user requests an external / second-opinion code review of changes.

**Process (Claude Code host):**

1. **Check availability** — `command -v codex`. If absent → Step 5 (subagent fallback).
2. **Choose scope** — pick the Codex flag by situation:
   - merge / feature-complete → `--base <trunk>` (resolve trunk: `main`/`master`);
   - high-risk / pre-commit / "review my current changes" → `--uncommitted`;
   - a specific commit the user names → `--commit <sha>`.
   Guard: if the chosen scope has no changes, report "nothing to review" and stop.
3. **Run the review** — call Codex directly, capturing to a `mktemp` output file:
   ```bash
   OUT="$(mktemp "${TMPDIR:-/tmp}/external-code-review-output.XXXXXX")"
   codex exec review <scope-flag> --skip-git-repo-check -o "$OUT"
   ```
   Set the Bash tool timeout to 280s. On non-zero exit / empty output → Step 5. **Network/sandbox note:** Codex needs network access; if the host sandboxes Bash without network, this must run outside the sandbox (user confirms). Codex auth is the user's responsibility.
4. **Read the review** — Read `$OUT`, then remove it.
5. **Subagent fallback** — dispatch `superartes:code-reviewer` with the `requesting-code-review` template (`BASE_SHA`/`HEAD_SHA` for a committed scope; the working diff for `--uncommitted`).
6. **Triage** — hand findings to `superartes:receiving-code-review`.
7. **Summarize** — brief report: Applied (N) / Deferred (N) / Pushed back (N).

## Bundled Fixes

### P3 — `mktemp` temp paths in `external-review`

`external-review/SKILL.md` documents fixed temp paths (`/tmp/external-review-prompt.md`, `/tmp/external-review-output.md`); concurrent reviews on one host clobber each other. Change the guidance to per-invocation `mktemp` files for both prompt and output, e.g. `mktemp "${TMPDIR:-/tmp}/external-review-prompt.XXXXXX"`. The wrapper already removes the prompt file; the skill must also state the **output** file is removed after it is read. (This is the only change to `external-review`; its wrapper and call form are otherwise untouched.)

### P2 — robust session id in `commit-message`

`commit-message/SKILL.md`'s `Session:` derivation uses `ls -t … | head -1`, which can select the wrong session (multiple concurrent sessions) or an empty/wrong value (committing from a subdirectory). Fix:

- **Primary:** `${CLAUDE_CODE_SESSION_ID:-}` (confirmed exposed by Claude Code; equals the `claude --resume` UUID; `:-` guard is `set -u`-safe).
- **Fallback (only if empty):** the transcript-directory heuristic, using `git rev-parse --show-toplevel` (more stable than `pwd`) to derive the project dir, with a caveat that multiple active sessions make the newest-transcript guess unreliable.
- **If both fail:** soften "always include Session under Claude Code" — emit the line only when a real value was obtained; never fabricate.

## Integration Changes

| File | Change |
|------|--------|
| `skills/requesting-code-review/SKILL.md` | Add "External code review" subsection: recommended before merge; mandatory self-invoke for high-risk changes; complements the Claude review; not per-subagent-task. Cross-reference `superartes:external-code-review`. |
| `skills/finishing-a-development-branch/SKILL.md` | Insert an explicit **Step 1.5** (between "Verify Tests" and "Present Options") recommending an external review pass, without disturbing the "exactly 4 options" flow. |
| `skills/external-review/SKILL.md` | `mktemp` temp paths + output-file cleanup (P3 only). |
| `skills/commit-message/SKILL.md` | Robust session id via `${CLAUDE_CODE_SESSION_ID:-}` with heuristic fallback (P2). |

## Testing

Testing is **mandatory**, per the `writing-skills` Iron Law (no new/edited skill without RED-GREEN-REFACTOR). Superartes is a published plugin.

- **Mechanism smoke test (done during design):** `codex exec review` produced a clean severity-ranked review to the `-o` file; exit 0. (Validated via scope-in-prompt; the final design uses scope flags, which are the tool's native path and even simpler.)
- **Scope-flag check:** confirm `codex exec review --base <trunk> -o <file>` and `--uncommitted -o <file>` each write a review and scope correctly.
- **Baseline (RED):** run a representative scenario **without** the skill; record that no external code review happens.
- **Trigger test (GREEN):** with the skill present, verify activation for "get an external code review of my feature before I merge." Add `tests/skill-triggering/prompts/external-code-review.txt` **and** register the skill in the hardcoded `SKILLS` array in `tests/skill-triggering/run-all.sh`.
- **High-risk self-invocation test:** verify the agent invokes the skill unprompted when a change matches the high-risk criteria (e.g. touches auth).
- **Fallback path:** with `codex` unavailable (or forced failure), verify the skill dispatches the `code-reviewer` subagent.

## Versioning & Documentation

New skill + bundled fixes → bump **1.3.0 → 1.4.0** in all synced manifests (`package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`) and `CLAUDE.md`. Add a `CHANGELOG.md` `[1.4.0]` entry. Update `README.md`: add `external-code-review` to the Skills Library list and note code review in the Codex optional-dependency row.

## Files Touched

**Created:**
- `skills/external-code-review/SKILL.md`
- `docs/specs/2026-07-02-external-code-review-design.md` (this spec)
- `tests/skill-triggering/prompts/external-code-review.txt`

**Modified:**
- `skills/external-review/SKILL.md` (`mktemp` — P3)
- `skills/commit-message/SKILL.md` (session-id robustness — P2)
- `skills/requesting-code-review/SKILL.md` (integration)
- `skills/finishing-a-development-branch/SKILL.md` (Step 1.5)
- `tests/skill-triggering/run-all.sh` (register new skill in `SKILLS`)
- `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `CLAUDE.md` (version)
- `CHANGELOG.md`, `README.md` (docs)

## Out of Scope (YAGNI)

- **Custom per-invocation review context** (scope-in-prompt). Dropped in favour of tool-enforced scope flags + repo-resident context. Revisit only if reviews prove context-starved; if so, the fallback is a scope-in-prompt path (`codex exec review -` with instructions) reserved for those cases.
- The Codex-host → `claude` external-reviewer command (documented as a planned slot only).
- The wrapper generalization and dirty-tree-overlap guard — both were consequences of scope-in-prompt and are unnecessary under flag-native scoping.
- Custom `--output-schema` structured findings (default review output is structured enough).
- Auto-applying review fixes (triage stays human-gated via `receiving-code-review`).
