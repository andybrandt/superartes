# Superartes

Superartes ("super skills" in Latin) is a composable skills library that provides structured development workflows for AI coding agents (Claude Code, Cursor, Codex, OpenCode, Gemini CLI). It enforces discipline through skills that trigger automatically: brainstorming before coding, TDD, systematic debugging, subagent-driven development with two-stage review, and feature branch isolation.

## How it works

It starts from the moment you fire up your coding agent. As soon as it sees that you're building something, it *doesn't* just jump into trying to write code. Instead, it steps back and asks you what you're really trying to do.

Once it's teased a spec out of the conversation, it shows it to you in chunks short enough to actually read and digest.

After you've signed off on the design, your agent puts together an implementation plan that's clear enough for an enthusiastic junior engineer with poor taste, no judgement, no project context, and an aversion to testing to follow. It emphasizes true red/green TDD, YAGNI (You Aren't Gonna Need It), and DRY.

Next up, once you say "go", it launches a *subagent-driven-development* process, having agents work through each engineering task, inspecting and reviewing their work, and continuing forward. It's not uncommon for Claude to be able to work autonomously for a couple hours at a time without deviating from the plan you put together.

There's a bunch more to it, but that's the core of the system. And because the skills trigger automatically, you don't need to do anything special. Your coding agent just has Superartes.

## Installation

### Claude Code

Register this as a marketplace, then install:

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

```bash
git clone https://github.com/andybrandt/superartes.git ~/.codex/superartes
mkdir -p ~/.agents/skills
ln -s ~/.codex/superartes/skills ~/.agents/skills/superartes
```

### OpenCode

Add to your `opencode.json`:

```json
{
  "plugin": ["superartes@git+https://github.com/andybrandt/superartes.git"]
}
```

### Gemini CLI

```bash
gemini extensions install https://github.com/andybrandt/superartes
```

### Verify Installation

Start a new session and ask for something that should trigger a skill (for example, "help me plan this feature" or "let's debug this issue"). The agent should automatically invoke the relevant superartes skill.

## The Basic Workflow

1. **brainstorming** - Activates before writing code. Refines rough ideas through questions, explores alternatives, presents design in sections for validation. Saves design document.

2. **using-feature-branches** - Activates after design approval. Creates feature branch, runs project setup, verifies clean test baseline.

3. **writing-plans** - Activates with approved design. Breaks work into bite-sized tasks (2-5 minutes each). Every task has exact file paths, complete code, verification steps.

4. **subagent-driven-development** or **executing-plans** - Activates with plan. Dispatches fresh subagent per task with two-stage review (spec compliance, then code quality), or executes in batches with human checkpoints.

5. **test-driven-development** - Activates during implementation. Enforces RED-GREEN-REFACTOR: write failing test, watch it fail, write minimal code, watch it pass, commit. Deletes code written before tests.

6. **requesting-code-review** - Activates between tasks. Reviews against plan, reports issues by severity. Critical issues block progress.

7. **finishing-a-development-branch** - Activates when tasks complete. Verifies tests, presents options (merge/PR/keep/discard).

**The agent checks for relevant skills before any task.** Mandatory workflows, not suggestions.

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
- **commit-message** - Consistent commit message formatting

**Meta**
- **writing-skills** - Create new skills following best practices (includes testing methodology)
- **using-superartes** - Introduction to the skills system

## Optional Dependencies

Some skills integrate with external tools when available. They are not required — skills gracefully fall back when tools are absent.

| Tool | Skill | Purpose |
|------|-------|---------|
| [Google Stitch MCP](https://stitch.withgoogle.com/docs/mcp/) | using-stitch, brainstorming | AI-powered UI/UX design generation, iteration, and preview |

## Philosophy

- **Test-Driven Development** - Write tests first, always
- **Systematic over ad-hoc** - Process over guessing
- **Complexity reduction** - Simplicity as primary goal
- **Evidence over claims** - Verify before declaring success

## Changes from upstream superpowers

- **Feature branches instead of worktrees**: Replaced the `using-git-worktrees` skill with `using-feature-branches`. Uses standard `git checkout -b` instead of `git worktree add`.
- **Commit at releasable checkpoints**: Replaced the "frequent commits" philosophy with a policy of committing only at releasable checkpoints.
- **Simplified doc paths**: Default paths changed from `docs/superpowers/specs/` and `docs/superpowers/plans/` to `docs/specs/` and `docs/plans/`.
- **Commit message skill**: Bundled `commit-message` skill for consistent commit message formatting across all artifacts (code, design docs, plans).
- **Controller-only commits**: In subagent-driven development, only the main agent commits — after reviews pass. Subagents focus on implementation.

## Attribution

Superartes is a fork of [superpowers](https://github.com/obra/superpowers) by [Jesse Vincent](https://blog.fsck.com) and the team at [Prime Radiant](https://primeradiant.com). The name "superartes" is Latin for "super skills" — chosen to avoid marketplace name collision with the original while preserving the spirit. If you find this useful, consider [sponsoring Jesse's open source work](https://github.com/sponsors/obra).

For the original superpowers community, join the [Discord](https://discord.gg/Jd8Vphy9jq).

## Updating

```bash
/plugin marketplace update superartes
```

## License

MIT License - see LICENSE file for details
