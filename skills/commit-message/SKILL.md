---
name: commit-message
description: Prepare appropriate commit messages. Use when preparing to commit the work into the repository.
model: sonnet
---

# Commit Message Guidelines

## Default format

- One short line, no body, no co-author trailer
- Focus on the **why** or **what changed**, not implementation details

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
