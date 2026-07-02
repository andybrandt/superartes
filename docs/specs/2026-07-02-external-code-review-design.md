# External Code Review Integration — Design Specification

## Overview

Add automated **external code review** of committed changes by invoking Codex CLI's purpose-built `codex exec review` in headless mode. This introduces a new `external-code-review` skill — a sibling to the existing `external-review` skill (which reviews *documents*) — that reviews *code changes* after coding.

The skill gives the work a second, independent model's eyes on the code, complementing (not replacing) the existing Claude `code-reviewer` subagent. It is recommended before merging and after a major feature, and the agent invokes it on its own for high-risk changes.

This spec also bundles two robustness fixes surfaced when the `external-code-review` mechanism was validated by running `codex exec review` against the `v1.3.0` commit (findings P2 and P3 below).

## Motivation

- **A different model catches different issues.** The Claude `code-reviewer` subagent reviews with the same model that wrote the code. Codex brings genuinely different training and blind spots — the validation run already found two real issues in shipped code.
- **Mirrors the document-review pattern.** `external-review` already established the "external AI CLI, Claude subagent fallback, triage" pattern for specs and plans. Code review is the natural symmetric capability for the post-coding phase.
- **Purpose-built tooling exists.** `codex exec review` is a first-class Codex subcommand for reviewing a git diff, so we get a strong, structured review with severity-ranked, file-and-line findings out of the box.

## Design Decisions

### Standalone skill (not merged into `external-review`)

The code-review logic lives in a new `external-code-review` skill, distinct from `external-review`.

Rationale: the two have different inputs (a git diff scope vs. a document path) and different Codex invocations (`codex exec review <scope>` vs. `codex exec` with a freeform prompt). Keeping them separate honours the "one clear purpose per skill" principle. They share the wrapper script and cross-reference each other.

### Reviews committed changes (commit-before-review discipline)

The skill defaults to reviewing **committed** work — a specific commit, a commit range, or the current feature branch vs. trunk. It does not review the uncommitted working tree by default.

Rationale: reviewing committed changes means any fixes the review prompts land as their own, separately identifiable diff. This makes it easy to see exactly what the review changed, and keeps the reviewed artifact stable.

### Custom context via scope-in-prompt (works around a CLI constraint)

**Constraint discovered during validation:** `codex exec review` rejects a custom prompt combined with a scope flag (`the argument '[PROMPT]' cannot be used with '--commit <SHA>'`). It is *either* a scope flag with Codex's built-in review prompt, *or* freeform instructions.

**Resolution:** pass custom context as the prompt (via stdin, `codex exec review -`) and **name the scope inside the instructions** — e.g. "review the diff of commit `<sha>`" or "review this branch's changes vs `main`; run `git show`/`git diff` to see them." Codex has read access to the repository, so it scopes itself and can also read related context (the plan in `docs/plans/`, the spec in `docs/specs/`, `CLAUDE.md`).

Rationale: the user requires both commit-scoped review *and* project context. Scope-in-prompt is the only way to have both. Context matters — the reviewer often needs to know what the change is *supposed* to do to judge it well.

### Read-only by nature

`codex exec review` has no `--sandbox` flag; a review never edits files. No sandbox flag is needed (unlike `external-review`, which passes `--sandbox read-only` to plain `codex exec`).

### Clean output capture with `--output-last-message`

The review is captured with `-o <file>` (a `mktemp` path), then read with the Read tool — same choice as `external-review`. Not `--json` (a JSONL event stream that would need parsing).

### Graceful degradation with Claude subagent fallback

Step 1 checks `command -v codex`. If Codex is unavailable or the review fails/produces empty output, the skill falls back to dispatching the existing `superartes:code-reviewer` subagent (the same template `requesting-code-review` uses, with `BASE_SHA`/`HEAD_SHA`).

Rationale: Superartes is a published plugin; not every user has Codex. Everyone still gets a structured external-style review pass.

### Feedback triage reuses `receiving-code-review`

The skill does not re-document how to handle review feedback. It defers to `superartes:receiving-code-review` (verify before implementing, fix Critical/Important, note Minor, push back with reasoning when the reviewer is wrong).

Rationale: DRY — one place defines how code-review feedback is handled.

### Integration: recommended, not mandatory-per-task

- `requesting-code-review` gains an "External code review" subsection: *recommended* before merge and after a major feature; the agent **must self-invoke** it for high-risk changes (criteria below). It explicitly complements — does not replace — the per-task Claude review, and stays **out** of the after-every-subagent-task mandatory loop (to keep that loop fast).
- `finishing-a-development-branch` recommends an external code-review pass before presenting the merge/PR options.

Rationale: a full external review after every 2–5 minute subagent task would add real latency and token cost for little marginal value. The value concentrates at merge and on risky changes.

### High-risk self-invocation criteria

The agent invokes `external-code-review` on its own — without being asked — when a change touches any of:

- Authentication, authorization, cryptography, secrets/credentials handling
- Data migrations, schema changes, or mass deletion of data
- Billing, payments, or anything money-related
- Concurrency, locking, or async coordination
- External API contracts or public interfaces other code depends on
- Unusually large or structurally complex diffs

### Platform neutrality (future Codex-host → `claude`)

The skill is framed as "external code review by another model." Under Claude Code, the external reviewer is Codex (`codex exec review`) with a Claude subagent fallback. Under Codex as host (a supported platform), the symmetric arrangement — invoking `claude` headless (`claude -p`) as the external reviewer, with a Codex subagent fallback — is documented as an **"Other platforms" note marked planned / not yet wired**, leaving a defined slot for the command Codex will add later.

Rationale: the plugin runs under multiple hosts. We do not build the Codex-host path now, but we shape the skill so it drops in cleanly.

## New Skill: `external-code-review`

### File structure

```
skills/external-code-review/
  SKILL.md
```

No supporting files: the wrapper (`invoke-codex.sh`) is shared and lives in `skills/external-review/`; the fallback template (`code-reviewer.md`) is shared and lives in `agents/` (referenced by `requesting-code-review`).

### SKILL.md responsibilities

**Frontmatter `description` (triggers only, no workflow):**
> Use when code changes need an independent external review — after completing a major feature, before merging, or for any high-risk change (auth, data migrations, money, concurrency, public interfaces) — or when the user requests an external / second-opinion code review of changes.

**Inputs:**
- **Scope of committed changes to review** — a commit SHA, a commit range, or "this feature branch vs `<trunk>`."
- **Reviewer context** — what was implemented, the plan/requirements it must satisfy, focus areas, and paths to related context docs (spec/plan).

**Process (Claude Code host):**

1. **Check availability** — `command -v codex`. If absent → Step 5 (subagent fallback).
2. **Resolve scope** — determine the committed range and confirm it is non-empty (`git diff --quiet <range>` guard; if empty, report "no committed changes to review" and stop).
3. **Compose review instructions** — write a tailored prompt to a `mktemp` file that: (a) names the exact committed range to review and tells the reviewer to `git show`/`git diff` it and to ignore unrelated/uncommitted code; (b) gives project + change context and points to relevant docs; (c) states focus areas; (d) asks for severity-ranked findings, real issues over style.
4. **Invoke Codex** via the shared wrapper (Bash tool, 280s timeout):
   ```bash
   bash /path/to/skills/external-review/invoke-codex.sh "$PROMPT_FILE" exec review - --skip-git-repo-check -o "$OUT_FILE"
   ```
   where `$PROMPT_FILE` and `$OUT_FILE` are `mktemp` paths. Then read `$OUT_FILE` with the Read tool. On non-zero exit / empty output → Step 5.
5. **Subagent fallback** — dispatch `superartes:code-reviewer` with the `requesting-code-review` template (`BASE_SHA`/`HEAD_SHA` from the resolved range).
6. **Triage** — hand the findings to `superartes:receiving-code-review`.
7. **Summarize** — brief report to the user: Applied (N) / Deferred (N) / Pushed back (N).

## Shared Wrapper Generalization: `invoke-codex.sh`

The existing `skills/external-review/invoke-codex.sh` hardcodes `codex exec -`. Generalize it so the caller passes the full Codex invocation after the prompt file:

```bash
cat "$PROMPT_FILE" | codex "$@"
```

- `external-review` call becomes: `invoke-codex.sh "$PROMPT" exec - -s read-only --skip-git-repo-check -o "$OUT"`
- `external-code-review` call is: `invoke-codex.sh "$PROMPT" exec review - --skip-git-repo-check -o "$OUT"`

`external-review/SKILL.md` must be updated to the new call form. The wrapper keeps its `set -euo pipefail`, prompt-file existence check, and cleanup trap. Validated: this generalized form works for both subcommands.

## Bundled Fixes

### P3 — `mktemp` temp paths in `external-review`

`external-review/SKILL.md` currently documents fixed temp paths (`/tmp/external-review-prompt.md`, `/tmp/external-review-output.md`). Concurrent reviews on one host clobber each other. Change the guidance to create per-invocation temp files with `mktemp` for both the prompt and the output. `external-code-review` follows the same `mktemp` guidance from the start.

### P2 — robust session id in `commit-message`

`commit-message/SKILL.md`'s `Session:` derivation uses `ls -t … | head -1`, which can select the wrong session (multiple concurrent sessions) or an empty/wrong value (committing from a subdirectory whose sanitized `pwd` has no transcript dir). Fix: prefer the authoritative environment variable, fall back to the existing heuristic.

- **Primary:** `$CLAUDE_CODE_SESSION_ID` (confirmed exposed by Claude Code; equals the `claude --resume` UUID).
- **Fallback (only if the env var is unset):** the transcript-directory heuristic, using `git rev-parse --show-toplevel` (more stable than `pwd`) to derive the project dir, with an explicit caveat that if multiple sessions are active in one project the newest-transcript guess may be wrong.

## Integration Changes

| File | Change |
|------|--------|
| `skills/requesting-code-review/SKILL.md` | Add "External code review" subsection: recommended before merge / after major feature; mandatory self-invoke for high-risk changes; complements the Claude review; not per-subagent-task. Cross-reference `superartes:external-code-review`. |
| `skills/finishing-a-development-branch/SKILL.md` | Recommend an external code-review pass before presenting merge/PR options. |
| `skills/external-review/SKILL.md` | Update wrapper call form; switch to `mktemp` temp paths (P3). |
| `skills/commit-message/SKILL.md` | Robust session id via `$CLAUDE_CODE_SESSION_ID` with heuristic fallback (P2). |

## Testing

- **Mechanism smoke test (done during design):** `codex exec review -` with scope-in-prompt produced a clean severity-ranked review to the `-o` file; the generalized wrapper worked for the `review` subcommand; temp prompt was cleaned up. Exit 0.
- **Wrapper regression:** verify `external-review`'s generalized call still works (`exec - -s read-only …`).
- **Skill-triggering test:** add a case under `tests/skill-triggering/` that `external-code-review` activates for a prompt like "get an external code review of my last commit."
- **Fallback path:** verify that with `codex` unavailable the skill dispatches the `code-reviewer` subagent.
- Formal subagent pressure-testing (per `writing-skills`) is optional for this reference/technique skill; the mechanism is already validated.

## Versioning & Documentation

New skill + bundled fixes → bump **1.3.0 → 1.4.0** in all synced manifests (`package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`) and `CLAUDE.md`. Add a `CHANGELOG.md` `[1.4.0]` entry. Update `README.md`: add `external-code-review` to the Skills Library list and note code review in the Codex optional-dependency row.

## Files Touched

**Created:**
- `skills/external-code-review/SKILL.md`
- `docs/specs/2026-07-02-external-code-review-design.md` (this spec)

**Modified:**
- `skills/external-review/invoke-codex.sh` (generalize)
- `skills/external-review/SKILL.md` (call form + `mktemp`)
- `skills/commit-message/SKILL.md` (session-id robustness)
- `skills/requesting-code-review/SKILL.md` (integration)
- `skills/finishing-a-development-branch/SKILL.md` (integration)
- `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `CLAUDE.md` (version)
- `CHANGELOG.md`, `README.md` (docs)

## Out of Scope (YAGNI)

- The Codex-host → `claude` external-reviewer command (documented as a planned slot only).
- Reviewing uncommitted working-tree changes by default (commit-before-review is the discipline).
- Custom `--output-schema` structured findings (the default review output is already structured enough).
- Auto-applying review fixes (triage stays human-gated via `receiving-code-review`).
