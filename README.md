# Superartes

Superartes ("super skills" in Latin) is a composable skills library that provides structured development workflows for AI coding agents (primarily Claude Code, Cursor, and OpenAI's Codex). It enforces discipline through skills that trigger automatically: brainstorming before coding leading to designs & plans, reviews including reviews by another model (very helpful!), TDD, systematic debugging, subagent-driven development with two-stage review and code review by another model, and feature branch isolation.

## How it works

The process is:

1. Brainstorm with AI what we are building -> SPEC
2. Other AI model reviews the spec -> improved SPEC
3. YOU review the spec -> approved SPEC
4. AI creates a detailed implementation plan -> PLAN
5. Other AI model reviews the plan -> improved PLAN
6. YOU reviews the plan -> approved PLAN
7. AI codes (different approaches - most often using subagents), with TDD and regression tests as well as code review at each step -> code
8. Other AI model reviews the plan -> code reviewed
9. YOU review the code and approve it to be merged or PR created

## Installation

### Claude Code

Register this repository as a marketplace, then install:

```bash
/plugin marketplace add andybrandt/superartes
/plugin install superartes@superartes
```

To update after new commits are pushed:

```bash
/plugin marketplace update superartes
```

For local development/testing without pushing to GitHub:

```bash
claude --plugin-dir /path/to/superartes
```

### Codex

Register this repository as a Codex plugin marketplace:

```bash
codex plugin marketplace add andybrandt/superartes
```

Then open the plugin directory and install Superartes:

```bash
/plugins
```

To update after new commits are pushed:

```bash
codex plugin marketplace upgrade superartes
```

*(I test & use this plugin under both `claude` and `codex`)*

### OpenCode

*Caveat: Superartes is not tested with OpenCode. No guarantees it will work.*

Add to your `opencode.json`:

```json
{
  "plugin": ["superartes@git+https://github.com/andybrandt/superartes.git"]
}
```

### Gemini CLI

Gemini support was removed after Google discontinued it in June 2026.

### Verify Installation

Start a new session and ask for something that should trigger a skill (for example, "help me plan this feature" or "let's debug this issue"). The agent should automatically invoke the relevant superartes skill.

## The Basic Workflow

The agent walks through a sequence of skills, each triggering automatically at its phase. Spec, plan, and feature branch each sit at known points in the lifecycle:

1. **brainstorming** — Activates when you describe an idea or openly state that you begin brainstorming sessions. The AI will refine your idea / concept through one-question-at-a-time dialogue, explore 2-3 alternative approaches, then present the design in chunks short enough to read. The resulting specification is then written to `docs/specs/` and committed on the **trunk branch** (`main`/`master`). External review (Codex CLI when available, or a Claude subagent if not) and a user review-gate happen before moving on.

2. **writing-plans** — Activates with the approved spec. Breaks the work into bite-sized tasks (2-5 minutes each), each with exact file paths, complete code, and verification steps — clear enough for an enthusiastic junior engineer with poor taste, no judgement, and no project context to follow. The plan is saved to `docs/plans/` and committed **on trunk**, next to the spec. External review by Codex (or a Claude subagent if Codex is not available) and user review-gate again.

3. **Execution handoff** — After the plan is approved, you pick one of three execution modes:
   - **Subagent-driven (recommended)** — a fresh subagent implements each task, with two-stage review (spec compliance, then code quality) running after each. All in this session.
   - **Inline execution** — all tasks executed in this session with checkpoints for human review.
   - **Handover to a fresh thread** — the agent prints a copy-paste prompt that lets a new session pick up the plan with a clean context window. Useful when brainstorming and planning have consumed a lot of context.

4. **using-feature-branches** — The chosen executor's first step. Creates the feature branch from trunk, runs project setup, verifies the test baseline is clean. The branch only exists from this point forward — spec and plan stay on trunk.

5. **subagent-driven-development** or **executing-plans** — Carries out the tasks on the new branch. **test-driven-development** drives each task (RED-GREEN-REFACTOR: write failing test, watch it fail, write minimal code, watch it pass). **requesting-code-review** runs at task boundaries, reporting issues by severity. **commit-message** ensures consistent message formatting.

6. **finishing-a-development-branch** — Activates when all tasks are done. Verifies tests, presents options (merge / PR / keep / discard).

**The agent checks for relevant skills before any task.** Mandatory workflows, not suggestions. It's not uncommon for the agent to work autonomously for a couple of hours at a time without deviating from the plan you put together.

## What's Inside

### Skills Library

**Testing**
- **test-driven-development** - RED-GREEN-REFACTOR cycle (includes testing anti-patterns reference)

**Debugging**
- **systematic-debugging** - 4-phase root cause process (includes root-cause-tracing, defense-in-depth, condition-based-waiting techniques)
- **verification-before-completion** - Ensure it's actually fixed

**Collaboration**
- **brainstorming** - Socratic design refinement (integrates with Stitch for UI/UX work when available)
- **using-stitch** - UI/UX design via [Google Stitch](https://stitch.withgoogle.com/) MCP (requires [Stitch MCP server](https://stitch.withgoogle.com/docs/mcp/))
- **writing-plans** - Detailed implementation plans
- **executing-plans** - Batch execution with checkpoints
- **dispatching-parallel-agents** - Concurrent subagent workflows
- **requesting-code-review** - Pre-review checklist
- **receiving-code-review** - Responding to feedback
- **using-feature-branches** - Feature branch isolation
- **finishing-a-development-branch** - Merge/PR decision workflow
- **subagent-driven-development** - Fast iteration with two-stage review (spec compliance, then code quality)
- **external-review** - Independent external document review via [Codex CLI](https://developers.openai.com/codex/) with Claude subagent fallback
- **external-code-review** - Independent external review of *code changes*: Claude Code hosts invoke [Codex CLI](https://developers.openai.com/codex/)'s `codex exec review`; Codex hosts invoke Claude Code headlessly with `claude -p`
- **commit-message** - Consistent commit message formatting

**Meta**
- **writing-skills** - Create new skills following best practices (includes testing methodology)
- **using-superartes** - Introduction to the skills system

## Optional Dependencies

Some skills integrate with external tools when available. They are not required — skills gracefully fall back when tools are absent.

| Tool | Skill | Purpose |
|------|-------|---------|
| [Google Stitch MCP](https://stitch.withgoogle.com/docs/mcp/) | using-stitch, brainstorming | AI-powered UI/UX design generation, iteration, and preview |
| [Codex CLI](https://developers.openai.com/codex/) | external-review, external-code-review, brainstorming, writing-plans | Independent second-model review - design specs and plans (`external-review`) and code changes when Claude Code is the host (`external-code-review`, via `codex exec review`) |
| Claude Code CLI | external-code-review | Independent second-model review of code changes when Codex is the host, via `claude -p` |

## Philosophy

- **Test-Driven Development** - Write tests first, always
- **Systematic over ad-hoc** - Process over guessing
- **Complexity reduction** - Simplicity as primary goal
- **Evidence over claims** - Verify before declaring success

## Changes from upstream superpowers

- **Asking second model for reviews**: Both spec and plan documents are reviewed by Codex automatically (if `codex` CLI is installed/available) when running under Claude Code - or by Claude Code (if `claude` CLI is installed/available) when running under Codex.
- **Feature branches instead of worktrees**: Replaced the `using-git-worktrees` skill with `using-feature-branches`. Uses standard `git checkout -b` instead of `git worktree add`. *Worktrees did not behave correctly in my projects which use dockerized components heavily*
- **Commit at releasable checkpoints**: Replaced the "frequent commits" philosophy with a policy of committing only at releasable checkpoints (keeping the code in "DONE" state at every commit).
- **Simplified doc paths**: Default paths changed from `docs/superpowers/specs/` and `docs/superpowers/plans/` to `docs/specs/` and `docs/plans/`.
- **Commit message skill**: Bundled `commit-message` skill for consistent commit message formatting across all artifacts (code, design docs, plans).
- **AI attribution in commits**: The `commit-message` skill records which model and session produced each commit — a `Model:`/`Session:`/`Session-URL:` footer trailer (session id and URL included only when the platform exposes them), replacing the conventional `Co-Authored-By:` trailer. Lets a commit be traced back to the exact model and thread and reopened via `claude --resume`  / `codex --resume` or, when available, in the browser.
- **Using Google Stitch for UX/UI design**: If [Google Stitch MCP](https://stitch.withgoogle.com/docs/mcp/) is installed in the harness it will be automatically used for UI/UX design work.
- **Controller-only commits**: In subagent-driven development, only the main agent commits — after reviews pass. Subagents focus on implementation.

## Attribution

Superartes is a fork of [superpowers](https://github.com/obra/superpowers) by [Jesse Vincent](https://blog.fsck.com) and the team at [Prime Radiant](https://primeradiant.com). The name "Super Artes" is Latin for "super skills" — chosen to avoid marketplace name collision with the original while preserving the spirit. If you find this work useful, consider [sponsoring Jesse's open source work](https://github.com/sponsors/obra).

## License

MIT License - see LICENSE file for details
