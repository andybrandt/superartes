# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Superartes is a composable skills library that provides structured development workflows for AI coding agents (Claude Code, Cursor, Codex, OpenCode, Gemini CLI). It enforces discipline through skills that trigger automatically: brainstorming before coding, TDD, systematic debugging, subagent-driven development with two-stage review, and feature branch isolation. Version 1.1.2. Fork of obra/superpowers.

## Repository Structure

```
skills/           # Core product - each subdirectory is one skill with SKILL.md + optional supporting files
agents/           # Agent definitions (e.g., code-reviewer.md) with YAML frontmatter
commands/         # Slash commands (e.g., /brainstorm, /write-plan, /execute-plan) - some deprecated
hooks/            # Session-start hooks for Claude Code and Cursor (hooks.json, hooks-cursor.json)
  session-start   # Bash script that injects using-superartes skill content on session start
  run-hook.cmd    # Windows polyglot wrapper for hooks
tests/            # Test suites organized by test type
  claude-code/    # Automated skill tests using `claude -p` headless mode
  brainstorm-server/  # Node.js tests for the brainstorming WebSocket server
  skill-triggering/   # Tests that skills activate for correct prompts
  explicit-skill-requests/  # Tests for explicit skill invocation
  subagent-driven-dev/      # End-to-end workflow tests with scaffold projects
docs/             # Design specs, implementation plans, and platform-specific READMEs
.claude-plugin/   # Claude Code plugin manifest (plugin.json, marketplace.json)
.cursor-plugin/   # Cursor plugin manifest (plugin.json)
.codex/           # Codex installation instructions
.opencode/        # OpenCode plugin loader
```

## Key Architectural Concepts

- **Skills** are the core product. Each skill is a `SKILL.md` with YAML frontmatter (`name`, `description`) plus optional reference files. Skills are NOT code - they are structured documentation that guides agent behavior.
- **SKILL.md frontmatter** `description` must start with "Use when..." and describe only triggering conditions, never the workflow itself (agents shortcut by following descriptions instead of reading the full skill).
- **Session-start hook** (`hooks/session-start`) injects `using-superartes` skill content into every conversation. This is the bootstrap mechanism - it tells the agent to check for and invoke relevant skills before any action.
- **Multi-platform**: Plugin manifests exist for Claude Code (`.claude-plugin/`), Cursor (`.cursor-plugin/`), Codex (`.codex/`), OpenCode (`.opencode/`), and Gemini (`GEMINI.md`, `gemini-extension.json`). Each platform has its own hook format and tool mapping.
- **Brainstorm server**: `skills/brainstorming/scripts/server.cjs` is a Node.js WebSocket server for visual brainstorming companion. Uses CommonJS (not ESM) due to root `package.json` having `"type": "module"`.

## Running Tests

### Brainstorm server tests (Node.js, fast):
```bash
cd tests/brainstorm-server && npm test
```

### Claude Code skill tests (requires `claude` CLI in PATH):
```bash
cd tests/claude-code
./run-skill-tests.sh                    # Fast tests (~2 min each)
./run-skill-tests.sh --integration      # Full workflow tests (10-30 min)
./run-skill-tests.sh --test <file>.sh   # Single test
./run-skill-tests.sh --verbose          # Show full Claude output
```

### Skill triggering tests:
```bash
cd tests/skill-triggering && ./run-all.sh
cd tests/explicit-skill-requests && ./run-all.sh
```

## Version Files

Version must be updated in all of these files when bumping:
- `package.json` — `version` field
- `.claude-plugin/marketplace.json` — `plugins[0].version` field
- `CLAUDE.md` — version reference in Project Overview paragraph

## Development Guidelines

- **Line endings**: `.gitattributes` enforces LF for all text files. The `run-hook.cmd` is a polyglot (cmd + bash) and must keep LF.
- **Skill creation follows TDD**: Write failing test (baseline without skill), write minimal skill, close loopholes. See `skills/writing-skills/SKILL.md`.
- **Flowcharts use Graphviz DOT syntax** inline in skills. Render with `skills/writing-skills/render-graphs.js`.
- **Cross-references between skills**: Use `superartes:skill-name` notation, never `@` file links (which force-load and burn context).
- **Token efficiency matters**: Skills load into agent context. Target <150 words for frequently-loaded skills, <500 for others.
