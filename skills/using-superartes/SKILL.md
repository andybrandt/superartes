---
name: using-superartes
description: Use when starting any conversation - establishes how to find and use skills, requiring Skill tool invocation before ANY response including clarifying questions
---

<SUBAGENT-STOP>
If you were dispatched as a subagent to execute a specific task, skip this skill.
</SUBAGENT-STOP>

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, you ABSOLUTELY MUST invoke the skill.

IF A SKILL APPLIES TO YOUR TASK, YOU DO NOT HAVE A CHOICE. YOU MUST USE IT.

This is not negotiable. This is not optional. You cannot rationalize your way out of this.
</EXTREMELY-IMPORTANT>

## Instruction Priority

Superartes skills override default system prompt behavior, but **user instructions always take precedence**:

1. **User's explicit instructions** (CLAUDE.md, AGENTS.md, direct requests) — highest priority
2. **Superartes skills** — override default system behavior where they conflict
3. **Default system prompt** — lowest priority

If CLAUDE.md or AGENTS.md says "don't use TDD" and a skill says "always use TDD," follow the user's instructions. The user is in control.

## How to Access Skills

**In Claude Code:** Use the `Skill` tool. When you invoke a skill, its content is loaded and presented to you—follow it directly. Never use the Read tool on skill files.

**In other environments:** Check your platform's documentation for how skills are loaded.

## Platform Adaptation

Skills name platform capabilities where possible, use generic language when not. When a skill says **task-list tool**, use whatever visible, user-facing checklist or task tracking capability the current harness exposes. It may be `TodoWrite`, `TaskCreate`/`TaskUpdate`/`TaskList`, `update_plan`, `write_todos`, `todowrite`, or another equivalent. Discover the available tool at runtime instead of assuming a name. 

For other concrete tool names, see `references/codex-tools.md` (Codex) for known equivalents. 

If no such tool exists, check if user has task tracking tool connected via MCP (like Asana, JIRA etc.). If such a tool is available use it to create temporary tasks, ask the user where to place them and inform the user of their existence. 

As a last  resort, if no other option is available, keep the checklist in a temporary Markdown file in the main project directory. Remember to clean-up such temporary file after work is done and never commit it. 

# Using Skills

## The Rule

**Invoke relevant or requested skills BEFORE any response or action.** Even a 1% chance a skill might apply means that you should invoke the skill to check. If an invoked skill turns out to be wrong for the situation, you don't need to use it.

```dot
digraph skill_flow {
    "User message received" [shape=doublecircle];
    "Dispatched as subagent\nfor a specific task?" [shape=diamond];
    "Skip using-superartes" [shape=doublecircle];
    "User explicitly overrides\na workflow?" [shape=diamond];
    "Honor the explicit override" [shape=box];
    "Might any other skill apply?" [shape=diamond];
    "About to enter plan mode?" [shape=diamond];
    "Already brainstormed?" [shape=diamond];
    "Invoke brainstorming skill" [shape=box];
    "Might any skill apply?" [shape=diamond];
    "Order applicable skills\n(process before implementation)" [shape=box];
    "Invoke Skill tool" [shape=box];
    "Announce: 'Using [skill] to [purpose]'" [shape=box];
    "Has checklist?" [shape=diamond];
    "Task-list tool available?" [shape=diamond];
    "Create task-list item per checklist item" [shape=box];
    "User task tracker connected?" [shape=diamond];
    "Ask user where to place\ntemporary tasks" [shape=box];
    "Create temporary tasks\nand inform user" [shape=box];
    "Keep temporary Markdown checklist\n(clean up, never commit)" [shape=box];
    "Follow skill exactly" [shape=box];
    "Respond (including clarifications)" [shape=doublecircle];

    "User message received" -> "Dispatched as subagent\nfor a specific task?";
    "Dispatched as subagent\nfor a specific task?" -> "Skip using-superartes" [label="yes"];
    "Dispatched as subagent\nfor a specific task?" -> "User explicitly overrides\na workflow?" [label="no"];
    "User explicitly overrides\na workflow?" -> "Honor the explicit override" [label="yes"];
    "User explicitly overrides\na workflow?" -> "About to enter plan mode?" [label="no"];
    "Honor the explicit override" -> "Might any other skill apply?";
    "Might any other skill apply?" -> "Order applicable skills\n(process before implementation)" [label="yes"];
    "Might any other skill apply?" -> "Respond (including clarifications)" [label="no"];
    "About to enter plan mode?" -> "Already brainstormed?" [label="yes"];
    "About to enter plan mode?" -> "Might any skill apply?" [label="no"];
    "Already brainstormed?" -> "Invoke brainstorming skill" [label="no"];
    "Already brainstormed?" -> "Might any skill apply?" [label="yes"];
    "Invoke brainstorming skill" -> "Might any skill apply?";
    "Might any skill apply?" -> "Order applicable skills\n(process before implementation)" [label="yes, even 1%"];
    "Might any skill apply?" -> "Respond (including clarifications)" [label="definitely not"];
    "Order applicable skills\n(process before implementation)" -> "Invoke Skill tool";
    "Invoke Skill tool" -> "Announce: 'Using [skill] to [purpose]'";
    "Announce: 'Using [skill] to [purpose]'" -> "Has checklist?";
    "Has checklist?" -> "Task-list tool available?" [label="yes"];
    "Has checklist?" -> "Follow skill exactly" [label="no"];
    "Task-list tool available?" -> "Create task-list item per checklist item" [label="yes"];
    "Task-list tool available?" -> "User task tracker connected?" [label="no"];
    "User task tracker connected?" -> "Ask user where to place\ntemporary tasks" [label="yes"];
    "User task tracker connected?" -> "Keep temporary Markdown checklist\n(clean up, never commit)" [label="no"];
    "Ask user where to place\ntemporary tasks" -> "Create temporary tasks\nand inform user";
    "Create task-list item per checklist item" -> "Follow skill exactly";
    "Create temporary tasks\nand inform user" -> "Follow skill exactly";
    "Keep temporary Markdown checklist\n(clean up, never commit)" -> "Follow skill exactly";
    "Follow skill exactly" -> "Respond (including clarifications)";
}
```

Whenever you are about to commit anything to a repository use `superartes:commit-message` skill. Never compose commit message without invoking this skill.

## Red Flags

These thoughts mean STOP—you're rationalizing:

| Thought | Reality |
|---------|---------|
| "This is just a simple question" | Questions are tasks. Check for skills. |
| "I need more context first" | Skill check comes BEFORE clarifying questions. |
| "Let me explore the codebase first" | Skills tell you HOW to explore. Check first. |
| "I can check git/files quickly" | Files lack conversation context. Check for skills. |
| "Let me gather information first" | Skills tell you HOW to gather information. |
| "This doesn't need a formal skill" | If a skill exists, use it. |
| "I remember this skill" | Skills evolve. Read current version. |
| "This doesn't count as a task" | Action = task. Check for skills. |
| "The skill is overkill" | Simple things become complex. Use it. |
| "I'll just do this one thing first" | Check BEFORE doing anything. |
| "This feels productive" | Undisciplined action wastes time. Skills prevent this. |
| "I know what that means" | Knowing the concept ≠ using the skill. Invoke it. |

## Skill Priority

When multiple skills could apply, use this order:

1. **Process skills first** (brainstorming, debugging) - these determine HOW to approach the task
2. **Implementation skills second** (frontend-design, mcp-builder) - these guide execution

"Let's build X" → brainstorming first, then implementation skills.
"Fix this bug" → debugging first, then domain-specific skills.

## Skill Types

**Rigid** (TDD, debugging): Follow exactly. Don't adapt away discipline.

**Flexible** (patterns): Adapt principles to context.

The skill itself tells you which.

## User Instructions

Instructions say WHAT, not HOW. "Add X" or "Fix Y" doesn't mean skip workflows. You can override workflows only when the user explicitly tells you to do it and even then as you work check if other skills do not apply anyway (example: commit message skill).
