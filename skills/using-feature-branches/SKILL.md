---
name: using-feature-branches
description: Use when starting feature work that needs isolation from the main branch or before executing implementation plans - creates a feature branch with safety verification
---

# Using Feature Branches

## Overview

Create a feature branch to isolate work from the main branch before starting implementation.

**Core principle:** Branch from clean base + verify test baseline = reliable isolation.

**Announce at start:** "I'm using the using-feature-branches skill to set up an isolated branch."

## The Process

### Step 1: Ensure Clean Working State

```bash
git status
```

**If uncommitted changes exist:** Ask the user how to handle them (stash, commit, or discard) before proceeding.

### Step 2: Determine Base Branch

```bash
# Identify the main branch
git branch -l main master 2>/dev/null
```

If ambiguous, ask the user which branch to base the feature on.

### Step 3: Create Feature Branch

```bash
# Update base branch
git checkout <base-branch>
git pull

# Create and switch to feature branch
git checkout -b <feature-branch-name>
```

**Branch naming:** Use descriptive names like `feature/auth-system`, `fix/login-timeout`, `refactor/db-layer`. Ask the user if no name is obvious from context.

### Step 4: Run Project Setup (if needed)

Auto-detect and run appropriate setup if dependencies may be out of date:

```bash
# Node.js
if [ -f package.json ]; then npm install; fi

# Rust
if [ -f Cargo.toml ]; then cargo build; fi

# Python
if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
if [ -f pyproject.toml ]; then poetry install; fi

# Go
if [ -f go.mod ]; then go mod download; fi
```

### Step 5: Verify Clean Baseline

Run tests to ensure the branch starts clean:

```bash
# Use project-appropriate command
npm test / cargo test / pytest / go test ./...
```

**If tests fail:** Report failures, ask whether to proceed or investigate.

**If tests pass:** Report ready.

### Step 6: Report

```
Feature branch ready: <branch-name> (based on <base-branch>)
Tests passing (<N> tests, 0 failures)
Ready to implement <feature-name>
```

## Quick Reference

| Situation | Action |
|-----------|--------|
| Uncommitted changes | Ask user (stash/commit/discard) |
| Base branch unclear | Ask user |
| Tests fail during baseline | Report failures + ask |
| No package.json/Cargo.toml | Skip dependency install |

## Common Mistakes

### Skipping clean state check

- **Problem:** Uncommitted changes get mixed into the feature branch
- **Fix:** Always check `git status` before branching

### Not pulling latest base

- **Problem:** Feature branch starts from stale code, merge conflicts later
- **Fix:** Always `git pull` on base branch before creating feature branch

### Proceeding with failing tests

- **Problem:** Cannot distinguish new bugs from pre-existing issues
- **Fix:** Report failures, get explicit permission to proceed

## Red Flags

**Never:**
- Create a feature branch with uncommitted changes without asking
- Skip baseline test verification
- Proceed with failing tests without asking
- Start work on main/master directly

**Always:**
- Check for clean working state first
- Pull latest base branch
- Auto-detect and run project setup
- Verify clean test baseline

## Integration

**Called by:**
- **brainstorming** (Phase 4) - REQUIRED when design is approved and implementation follows
- **subagent-driven-development** - REQUIRED before executing any tasks
- **executing-plans** - REQUIRED before executing any tasks
- Any workflow needing isolated workspace

**Pairs with:**
- **finishing-a-development-branch** - REQUIRED for completing work after implementation
