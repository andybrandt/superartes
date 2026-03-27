# Superpowers (andybrandt fork)

This is a personal fork of [obra/superpowers](https://github.com/obra/superpowers) with workflow modifications. See [Changes from upstream](#changes-from-upstream) below.

---

Superpowers is a complete software development workflow for your coding agents, built on top of a set of composable "skills" and some initial instructions that make sure your agent uses them.

## How it works

It starts from the moment you fire up your coding agent. As soon as it sees that you're building something, it *doesn't* just jump into trying to write code. Instead, it steps back and asks you what you're really trying to do. 

Once it's teased a spec out of the conversation, it shows it to you in chunks short enough to actually read and digest. 

After you've signed off on the design, your agent puts together an implementation plan that's clear enough for an enthusiastic junior engineer with poor taste, no judgement, no project context, and an aversion to testing to follow. It emphasizes true red/green TDD, YAGNI (You Aren't Gonna Need It), and DRY. 

Next up, once you say "go", it launches a *subagent-driven-development* process, having agents work through each engineering task, inspecting and reviewing their work, and continuing forward. It's not uncommon for Claude to be able to work autonomously for a couple hours at a time without deviating from the plan you put together.

There's a bunch more to it, but that's the core of the system. And because the skills trigger automatically, you don't need to do anything special. Your coding agent just has Superpowers.


## Sponsorship

If Superpowers has helped you do stuff that makes money and you are so inclined, I'd greatly appreciate it if you'd consider [sponsoring my opensource work](https://github.com/sponsors/obra).

Thanks! 

- Jesse


## Changes from upstream

Based on upstream v5.0.6. This fork introduces the following changes:

- **Feature branches instead of worktrees**: Replaced the `using-git-worktrees` skill with `using-feature-branches`. Uses standard `git checkout -b` instead of `git worktree add`. The `finishing-a-development-branch` skill was updated accordingly (worktree cleanup removed). All cross-references updated.

- **Commit at releasable checkpoints**: Replaced the "frequent commits" philosophy with a policy of committing only at releasable checkpoints — all tests pass, codebase works, change is coherent. Trivial or work-in-progress commits are discouraged. Affects `writing-plans` and `subagent-driven-development` skills.

- **Simplified doc paths**: Default paths for specs and plans changed from `docs/superpowers/specs/` and `docs/superpowers/plans/` to `docs/specs/` and `docs/plans/`.

- **Commit message skill**: Bundled `commit-message` skill for consistent commit message formatting — short one-line messages, version prefix format, `fixes #N` convention, and version tagging. Referenced from `verification-before-completion`, `finishing-a-development-branch`, and `writing-plans` skills.

## Installation

**Note:** This is the andybrandt fork. For the original, see [obra/superpowers](https://github.com/obra/superpowers).

### Claude Code

Register this fork as a marketplace, then install:

```bash
/plugin marketplace add andybrandt/superpowers-andy
/plugin install superpowers@superpowers-andy
```

To update after new commits are pushed:

```bash
/plugin marketplace update superpowers-andy
```

For local development/testing without pushing to GitHub:

```bash
claude --plugin-dir /path/to/superpowers-andy
```

See [docs/installing-fork-in-claude-code.md](docs/installing-fork-in-claude-code.md) for details.

### Codex

```bash
git clone https://github.com/andybrandt/superpowers-andy.git ~/.codex/superpowers
mkdir -p ~/.agents/skills
ln -s ~/.codex/superpowers/skills ~/.agents/skills/superpowers
```

### OpenCode

Add to your `opencode.json`:

```json
{
  "plugin": ["superpowers@git+https://github.com/andybrandt/superpowers-andy.git"]
}
```

### Gemini CLI

```bash
gemini extensions install https://github.com/andybrandt/superpowers-andy
```

### Verify Installation

Start a new session and ask for something that should trigger a skill (for example, "help me plan this feature" or "let's debug this issue"). The agent should automatically invoke the relevant superpowers skill.

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
- **brainstorming** - Socratic design refinement
- **writing-plans** - Detailed implementation plans
- **executing-plans** - Batch execution with checkpoints
- **dispatching-parallel-agents** - Concurrent subagent workflows
- **requesting-code-review** - Pre-review checklist
- **receiving-code-review** - Responding to feedback
- **using-feature-branches** - Feature branch isolation
- **finishing-a-development-branch** - Merge/PR decision workflow
- **subagent-driven-development** - Fast iteration with two-stage review (spec compliance, then code quality)

**Meta**
- **writing-skills** - Create new skills following best practices (includes testing methodology)
- **using-superpowers** - Introduction to the skills system

## Philosophy

- **Test-Driven Development** - Write tests first, always
- **Systematic over ad-hoc** - Process over guessing
- **Complexity reduction** - Simplicity as primary goal
- **Evidence over claims** - Verify before declaring success

Read more: [Superpowers for Claude Code](https://blog.fsck.com/2025/10/09/superpowers/)

## Contributing

Skills live directly in this repository. To contribute:

1. Fork the repository
2. Create a branch for your skill
3. Follow the `writing-skills` skill for creating and testing new skills
4. Submit a PR

See `skills/writing-skills/SKILL.md` for the complete guide.

## Updating

For Claude Code:

```bash
/plugin marketplace update superpowers-andy
```

## License

MIT License - see LICENSE file for details

## Community

Superpowers is built by [Jesse Vincent](https://blog.fsck.com) and the rest of the folks at [Prime Radiant](https://primeradiant.com).

For community support, questions, and sharing what you're building with Superpowers, join us on [Discord](https://discord.gg/Jd8Vphy9jq).

## Support

- **Upstream**: [obra/superpowers](https://github.com/obra/superpowers)
- **Upstream Discord**: [Join on Discord](https://discord.gg/Jd8Vphy9jq)
- **This fork**: https://github.com/andybrandt/superpowers-andy
