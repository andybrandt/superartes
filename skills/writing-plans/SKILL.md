---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer who will implement them has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Iterative, incremental development. Commit at releasable checkpoints, not after every small step.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Context:** This skill runs on the trunk branch (`main` / `master`) — the same branch where brainstorming wrote and committed the spec. The plan is also written and committed on trunk. The feature branch is created later, by the executor skill (`superartes:executing-plans` or `superartes:subagent-driven-development`) as its first step. Do not create a branch while writing the plan.

**Save plans to:** `docs/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable, potentially releasable software on its own (the "DONE" state).

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:subagent-driven-development (recommended) or superartes:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit (releasable checkpoint)**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

Note: `.py` extension is used in the above example, use correct extensions and naming conventions for the programming language used.

**Commit policy:** A commit step means all tests pass and the codebase is in a releasable state. An incomplete feature is fine to commit as long as what exists works. Do not add commit steps after trivial or intermediate changes — only at releasable checkpoints. Use `superartes:commit-message` for message formatting.

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Remember
- Exact file paths always
- Complete code in every step — if a step changes code, show the code
- Exact commands with expected output
- DRY, YAGNI, TDD, commit at releasable checkpoints (all tests pass, codebase works)

## Self-Review

After writing the complete plan, look at the spec with fresh eyes and check the plan against it. This is a checklist you run yourself — not a subagent dispatch.

**1. Spec coverage:** Skim each section/requirement in the spec. Can you point to a task that implements it? List any gaps.

**2. Placeholder scan:** Search your plan for red flags — any of the patterns from the "No Placeholders" section above. Fix them.

**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.

If you find issues, fix them inline. No need to re-review — just fix and move on. If you find a spec requirement with no task, add the task.

## External Review

After self-review, invoke `superartes:gemini-review` with:
- Document type: "plan"
- The plan document path
- The spec document path (for reference)

## User Review Gate

After the external review is processed, commit the plan using `superartes:commit-message` to prepare the relevant commit message. Then ask the user to review the plan before offering execution options:

> "Plan written and committed to `<path>`. Please review it and let me know if you want to make any changes before we proceed to execution."

Wait for the user's response. If they request changes, make them, re-run self-review, and re-run external review. Only proceed to execution handoff once the user approves.

## Execution Handoff

After the user approves the plan, present this exact menu (consistent first-person voice):

> **Plan complete, saved to `docs/plans/<filename>.md` and committed. Three execution options:**
>
> **1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
>
> **2. Inline Execution** — I execute tasks in this session with checkpoints for review.
>
> **3. Handover to a fresh thread** — I print a copy-paste prompt that lets a new session execute the plan with a clean context window.
>
> **Which approach?**

### Choosing between #1/#2 and #3

Option #3 exists because brainstorming and plan-writing often consume a large fraction of the context window — by execution time, the thread may already be summarized or close to it, which raises cost and can degrade focus. A fresh thread driven only by the (now-authoritative) plan document is often crisper and cheaper. The user decides, but you may recommend, using these heuristics:

- **Lean toward #3 (handover) when:** plan-writing took many turns, summarization has already been triggered this session, OR the plan is fully self-contained (it does not rely on facts learned in chat that aren't written into the plan).
- **Lean toward #1 or #2 when:** important project state was learned this session and is *not* captured in either the plan or the spec/design documents (undocumented test commands, container quirks, user corrections to your initial assumptions, judgment calls about ambiguous spec areas). A fresh thread would not inherit this context and could make wrong calls.

You cannot precisely measure your own context usage — use turn count and whether a summarization event has occurred as soft signals, not exact metrics.

### If Subagent-Driven chosen

- **REQUIRED SUB-SKILL:** Use `superartes:subagent-driven-development`
- Fresh subagent per task + two-stage review

### If Inline Execution chosen

- **REQUIRED SUB-SKILL:** Use `superartes:executing-plans`
- Batch execution with checkpoints for review

### If Handover chosen

Before generating the prompt, ask the user one follow-up question:

> **Which execution mode should the new thread use — subagent-driven (recommended) or inline?**

Then **print the handover prompt inline in the chat** (do not save it to a file — the user can copy it directly from the chat; some agents provide a copy command such as Claude Code's `/copy`). The prompt MUST contain every item in the checklist below.

**Required content checklist:**

- Absolute path to the plan document
- Absolute path to the spec document (so the new thread can resolve ambiguity)
- Trunk branch name (the branch the plan is committed on, typically `main`)
- Short commit hash containing the plan (so the new thread can verify HEAD includes it before branching)
- Suggested feature branch name for the executor to create — a descriptive name based on the feature, e.g. `feature/auth-system`
- Working directory (absolute path)
- Chosen execution mode (subagent-driven or inline)
- Name of the required sub-skill to invoke first (`superartes:subagent-driven-development` or `superartes:executing-plans`)
- Project-specific notes learned this session that are not captured in the plan (e.g. tests run inside a Docker container, language/style constraints, user corrections to early assumptions). If there are none, say so explicitly so the new thread doesn't wonder what's missing.
- Explicit instruction: **do not re-run brainstorming or writing-plans; do not relitigate design decisions; treat the plan as authoritative**

**Template** (fill in every bracketed placeholder before printing — no `[TBD]` left behind):

```
You are taking over execution of an approved implementation plan.

Plan:               [absolute path to plan document]
Spec:               [absolute path to spec document]
Plan committed on:  [trunk branch, typically `main`] @ [short SHA]
Working dir:        [absolute path]

Suggested feature branch name: [e.g. `feature/auth-system`]

Execution mode:     [subagent-driven | inline]
Required sub-skill: superartes:[subagent-driven-development | executing-plans]

Project-specific notes (learned in the originating session,
may not be fully captured in the plan):
- [e.g. tests run inside docker container `app` — use `docker compose exec app ...`]
- [e.g. Python only; type hints and docstrings required]
- [e.g. user corrected the initial assumption that X — actual approach is Y]
- [or: "None — the plan is fully self-contained."]

Begin by invoking the required sub-skill above. Its first step will set
up the feature branch via superartes:using-feature-branches — use the
suggested branch name unless the user prefers another. Before branching,
verify that HEAD on the trunk branch includes the plan commit shown above.

A design and implementation plan have already been approved by the user
(paths above). The brainstorming HARD-GATE is satisfied — do NOT invoke
superartes:brainstorming. Do NOT re-run superartes:writing-plans. Treat
the plan as authoritative — do not relitigate design decisions. If a step
is genuinely ambiguous, consult the spec first; only ask the user if the
spec is silent too.
```

After printing the prompt, tell the user: *"Copy the block above into a fresh agent session to begin execution."*
