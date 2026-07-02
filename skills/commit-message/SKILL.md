---
name: commit-message
description: Use when preparing to commit work into a repository or writing any git commit message
model: sonnet
---

# Commit Message Guidelines

## Default format

- One short subject line - focus on the **why** or **what changed**, not implementation details
- No body by default (see Exceptions)
- Every commit carries the **attribution trailer** described below

## Attribution trailer

Before composing a commit message, make an explicit attribution check:

1. Identify the exact model identifier you are running as.
2. Check whether the current platform exposes a resumable session id, local transcript id, thread id, or equivalent.
3. Check whether the current platform exposes a browser URL or shareable link for this exact thread/session.

Append this trailer to **every** commit as a footer - placed after the subject line and any body, separated from what precedes it by one blank line. For the usual one-line commit it sits directly under the subject:

```
Model: <model identifier>
Session: <resumable session id, local transcript id, thread id, or equivalent - only if available>
Session-URL: <browser/share URL for this exact thread/session - only if available>
```

- **Model** - the exact model identifier you are running as (for example `claude-opus-4-8[1m]`). Always include this line.
- **Session** - the current platform's resumable session id, local transcript id, thread id, or equivalent. Include this line whenever you can obtain a real value. Under Claude Code, this is the LOCAL session UUID that `claude --resume <uuid>` accepts, i.e. the actively-written `~/.claude/projects/<project-dir>/<uuid>.jsonl` for the current project. `<project-dir>` is the working directory path with every non-alphanumeric character replaced by a dash. Determine the Claude Code UUID with:

  ```bash
  basename "$(ls -t ~/.claude/projects/"$(pwd | sed 's#[^a-zA-Z0-9]#-#g')"/*.jsonl | head -1)" .jsonl
  ```

  Always include this line under Claude Code.
- **Session-URL** - the browser URL or shareable link for this exact thread/session. Include this line when the platform exposes a real URL, such as a `claude.ai/code` session URL, a Codex thread/session URL, or another current conversation link. **Omit the entire line** when no URL is available - do not invent, infer, or guess it.

**Purpose:** lets the author later identify which model and thread produced a commit and reopen it from the CLI (`claude --resume`) or, when a URL exists, in the browser.

**Do not add a `Co-Authored-By:` trailer.** The `Model` line records authorship; the co-author trailer is redundant and is intentionally replaced by this scheme. This reverses the previous "no attribution" policy.

**Other platforms (Codex, Cursor, Gemini, OpenCode):** always emit `Model` with your own model identifier. For `Session`, emit your platform's resumable session id, local transcript id, thread id, or equivalent if it exposes one; otherwise omit the line. For `Session-URL`, actively check whether the current session has a real browser/share URL and include it when available; otherwise omit the line.

## Version number commits

If the changes include a version number change, the message must start with the version:

- Format: `v{version} - {one-line description of the crux of the change}`
- Example: `v3.3.3 - add day-of-week to calculate_time_distance output`

## GitHub issue references

If the work fixes a GitHub issue, append `(fixes #N)` to the commit message:

- Example: `v0.1.16 - fix redundant double elink call per full-text request (fixes #12)`

## Version tagging

If the commit includes a version number change, tag that commit with the version number. If unsure whether a given commit should be tagged, ask the user.

## Exceptions

Longer explanations (multi-line body) are allowed only for major changes involving longer work between commits, especially in multi-developer projects where the additional context provides value to other contributors.

## Project overrides

Project-specific CLAUDE.md or commit conventions (e.g., Conventional Commits) take precedence over these defaults.
