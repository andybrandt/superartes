---
name: external-review
description: Use when a design spec, implementation plan, or other document needs independent external review, or when the user requests a second opinion on a document
---

# External Document Review

Obtain a review from a different model family and harness than the controller.

## Required input

- Primary document paths and document type
- Related context documents
- Canonical project path

## Reviewer selection

| Controller | Independent profile |
|------------|---------------------|
| Claude Code / Anthropic | `codex-prompt` |
| Codex / OpenAI | `claude-prompt` |
| Unknown or conflicting | Stop and ask |

Use explicit runtime identity first, then corroborating Claude/Codex environment
markers. Executable availability never determines controller identity. A
same-model fallback is degraded, not independent.

## Prompt composition

Compose a contextual prompt covering project role, document paths, review focus,
re-review history, permission to explore read-only context, and collaborative
feedback. Do not impose a response limit, prescribe conclusions, or over-template
the review.

## Invocation

Read `invoking-reviewers.md` from this skill's absolute source directory and use
the selected managed profile. Never resolve it relative to the user's project.
One stable review key permits one outstanding review. A live process or empty
live result is never failure. Lost-output recovery may launch if no key matches,
so preserve exact semantics. Before prompt cleanup, reissue ordinary `start`
with the readable original prompt. After cleanup, recreate a readable temporary
file containing the exact original prompt; its pathname may differ because the
stable key is the lock identity. Use the same profile, key, and work directory,
never `--after-terminal`; exit 12 recovers `RUN_DIR`, then use managed `wait`.
Profile preflight runs before key lookup and must succeed. If exact inputs are
unavailable or preflight fails, do not reissue `start` or substitute a similar
review.

On native Windows, Claude Code has no OS-level sandbox. Safe mode, `dontAsk`,
the restricted tool allow-list, and the review-only prompt are the safeguards;
state this limitation when selecting `claude-prompt` there.

For interactive work, fifteen minutes of recorded reviewer runtime is a status
checkpoint: ask whether to continue or cancel. For autonomous work, judge a
reasonable duration from scope and complexity, and extend it when justified.

## Completion and fallback

Inspect terminal evidence in the order defined by the reference. Triage any
substantive feedback even after a non-zero exit. A fallback or second attempt
requires an unavailable CLI, demonstrated terminal failure with no review, or
explicit user approval. A linked retry additionally requires the original to be
terminal with its reviewer and supervisor absent per validated evidence.
Approval never permits a retry while the original is live. For `indeterminate`,
follow the reference and never retry immediately. Label same-model fallback as
degraded.

## Triage and summary

Accept and apply clear improvements, reject feedback contradicted by deliberate
context, and escalate genuine judgment calls. Summarize Applied / Skipped /
Input needed. Use `superartes:commit-message` for document changes that are
committed.
