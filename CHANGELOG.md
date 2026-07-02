# Changelog

## [1.3.0] - 2026-07-02

### Changed

- **External review switched from Gemini CLI to Codex CLI**: The `gemini-review` skill was renamed to `external-review` and now drives [Codex CLI](https://developers.openai.com/codex/) (`codex exec`) as the default external reviewer instead of Gemini CLI. The Claude subagent fallback (used when no external CLI is available) is unchanged. Callers `brainstorming` and `writing-plans` now invoke `superartes:external-review`.
  - **Why Gemini was dropped**: the `gemini` CLI command was deprecated for private/consumer accounts and stopped working in headless mode, and its intended replacement (Antigravity CLI) has no non-interactive mode, making it unusable as an automated reviewer. [Announcementi](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/). 
  - Codex is invoked read-only (`--sandbox read-only`) with `--output-last-message` to capture just the final review text (chosen over `--json`, which emits a JSONL event stream that would need parsing). Authentication and model configuration are the user's responsibility — the plugin does not attempt to resolve Codex auth. If the host sandboxes Bash without network access, the wrapper must be run outside the sandbox so Codex can reach its provider.
  - The wrapper script `invoke-gemini.sh` was renamed to `invoke-codex.sh` and now feeds the prompt to `codex exec -` via stdin (still avoiding shell-escaping and the Bash "Unhandled node type: pipeline" sandbox prompt).
- **Commit attribution reversed — commits now record model and session (`commit-message`)**: The prior policy of no AI attribution (no co-author trailer) is reversed. Before composing a message the agent runs an explicit attribution check, then appends a footer trailer to every commit: `Model:` (the exact model identifier, e.g. `claude-opus-4-8[1m]`; always emitted), `Session:` (the platform's resumable session id, local transcript id, or thread id — under Claude Code the local UUID accepted by `claude --resume`, found as the newest `~/.claude/projects/<project-dir>/<uuid>.jsonl`), and `Session-URL:` (a browser/share URL for the exact thread — e.g. a `claude.ai/code` or Codex thread URL — included only when the platform actually exposes one, never invented). This lets a commit be traced back to the exact model and thread that produced it and reopened from the CLI or browser. The `Co-Authored-By:` trailer is intentionally dropped — the `Model` line supersedes it. The scheme is platform-neutral: Codex, Cursor, Gemini, and OpenCode emit `Model` plus their own session identifier and URL when available.

## [1.2.2] - 2026-04-30

### Fixed

- **Codex marketplace plugin visibility**: Changed the self-hosted Codex marketplace entry to use a Git URL source for the root plugin instead of a local `./` source. Codex could clone and register the marketplace, but skipped the plugin entry in `/plugins` when resolving the root plugin as a local source.
- **Codex plugin validation**: Updated the metadata validator to require the Git URL marketplace source shape so this install failure does not regress.

## [1.2.1] - 2026-04-30

### Added

- **Codex plugin manifest**: Added `.codex-plugin/plugin.json` so Superartes can be installed as a Codex plugin rather than only through native skill symlinks.
- **Self-hosted Codex marketplace**: Added `.agents/plugins/marketplace.json` so the repository can be registered with `codex plugin marketplace add andybrandt/superartes`.
- **Codex plugin assets**: Added a composer SVG icon and PNG logo for the Codex plugin install surface.
- **Codex plugin metadata validation**: Added `tests/codex-plugin/run-tests.sh` and validator coverage for JSON shape, referenced assets, skill paths, marketplace metadata, and version synchronization across plugin manifests.

### Changed

- **Codex installation docs**: Updated README and Codex-specific docs to make plugin marketplace installation the primary Codex install path. Manual clone/symlink instructions now live only in Codex fallback docs for older Codex versions or other tools/models that rely on native skill discovery.
- **Version sync**: Bumped package and plugin manifests to `1.2.1`, including Claude, Cursor, and Codex metadata.

## [1.2.0] - 2026-04-30

### Added

- **Handover to a fresh thread (writing-plans)**: Third execution option in the Execution Handoff. After plan approval the user now picks between (1) subagent-driven execution (recommended), (2) inline execution, or (3) handover — the agent prints a self-contained copy-paste prompt that a fresh session can use to execute the plan with a clean context window. Useful when brainstorming and plan-writing have consumed a large fraction of the original context. The handover prompt template covers plan/spec paths, trunk branch + plan commit SHA, suggested feature branch name, execution mode, required sub-skill, and project-specific notes learned in the originating session.
- **Decision rubric in Execution Handoff**: Heuristics for when to recommend handover (many turns consumed, summarization triggered, plan is self-contained) vs. staying in-session (significant project state was learned that isn't captured in the plan or spec).
- **AGENTS.md**: Top-level file mirroring `CLAUDE.md` for agent platforms (Codex, OpenCode, Gemini CLI) that look for `AGENTS.md` rather than `CLAUDE.md`.

### Changed

- **Branch-lifecycle convention made explicit**: The convention — spec on trunk (`main`/`master`), plan on trunk, feature branch created only at execution start (by `using-feature-branches`, called from `executing-plans` or `subagent-driven-development`), branch merged back at finish — is now stated explicitly in `brainstorming`, `writing-plans`, `executing-plans`, and `subagent-driven-development`. Previously this was implicit and contradicted by the wording in some skills.
- **Execution Handoff section restructured (writing-plans)**: Replaced the prose section with a structured layout — menu, decision rubric, per-option subsections, required-content checklist, and fillable handover prompt template. Voice unified to first-person across all three options.
- **README workflow walkthrough**: Rewrote the "Basic Workflow" section to reflect the corrected branch convention and to introduce the three execution choices.
- **README tagline**: Opening paragraph now mentions "designs & plans, reviews" alongside the existing TDD/debugging/subagent-driven keywords.
- **.gitignore cleanup**: Removed stale local scratch entries `inspo` and `triage/`, while keeping dependency directories ignored.

### Fixed

- **writing-plans Context line wrongly attributed branch creation to brainstorming**: The skill said "This should be run in a dedicated feature branch (created by brainstorming skill)" — but brainstorming has never invoked `using-feature-branches`. Corrected to state that writing-plans runs on trunk and the feature branch is created later, by the executor skill.
- **Phantom integration claim in using-feature-branches**: The "Called by:" list included "**brainstorming** (Phase 4) - REQUIRED when design is approved..." — but brainstorming has no Phase 4 and never invokes using-feature-branches. Removed.
- **Stale version references in CLAUDE.md and AGENTS.md**: The Project Overview paragraph in both files said "Version 1.1.2" despite the plugin being at 1.1.3 and 1.1.4 in package.json/marketplace.json. Brought into sync at 1.2.0.

### Removed

- **CODE_OF_CONDUCT.md**: Legacy file from upstream fork; not maintained.
- **RELEASE-NOTES.md**: Superseded by this `CHANGELOG.md`.

## [1.1.4] - 2026-04-30

### Fixed

- **Problem firing Gemini reviews from Codex**: Added instructions for Codex to run review script outside its sandbox always.

## [1.1.3] - 2026-04-18o

### Fixed

- **Incorrect commit messages - skill not used**: Added directive in main SKILL.md to ensure `commit-message` skills is always used whenever AI commits.

## [1.1.2] - 2026-04-17

### Fixed
- **gemini-review permission prompt reduction**: Use Write tool instead of bash heredoc for creating the prompt temp file (eliminates `file_redirect` permission prompt). Inlined `review-guidelines.md` content into SKILL.md (eliminates Read tool permission prompt). Net result: invoking gemini-review now requires only one permission prompt (the `bash:*` for invoke-gemini.sh) instead of three.

## [1.1.1] - 2026-04-16

### Fixed
- **gemini-review cross-platform fix**: Replaced inline pipe invocation (`cat | gemini`) with a two-step approach using a temp file and `invoke-gemini.sh` wrapper script. Eliminates Claude Code's "Unhandled node type: pipeline" sandbox prompt that blocked every Gemini invocation with no way to permanently accept. Also changed `which gemini` to `command -v gemini` for better portability across bash variants.

## [1.1.0] - 2026-04-14

### Added
- **gemini-review skill**: New skill for automated external document review via [Gemini CLI](https://github.com/google-gemini/gemini-cli). Invokes Gemini in headless, read-only mode (`--approval-mode plan -m pro`) to independently review design specs and implementation plans. Falls back to a Claude subagent review (using existing reviewer prompt templates) when Gemini CLI is not available. Triages feedback into accept/reject/escalate buckets. This is the first feature significantly differentiating Superartes from the upstream Superpowers fork.
- **External review step in brainstorming**: After spec self-review, brainstorming now invokes `gemini-review` before the user review gate.
- **External review step in writing-plans**: After plan self-review, writing-plans now invokes `gemini-review` before offering execution options.
- **Explicit user review gate in writing-plans**: Added a proper user review gate between external review and execution handoff (previously users relied on the execution choice prompt as an ad-hoc review point).

## [1.0.4] - 2026-04-13

### Changed
- **verification-before-completion**: Added explicit "Before Committing" section requiring invocation of `commit-message` skill before any `git commit`.
- **writing-skills**: Added "Plugin Version Sync" section to deployment checklist — documents all manifest files that must be kept in sync for marketplace updates to work.

## [1.0.3] - 2026-04-13

### Added
- **using-stitch skill**: New skill for UI/UX design using [Google Stitch](https://stitch.withgoogle.com/) MCP. Covers project setup, design system creation (colors, typography, roundness), screen generation, variant exploration, and iterative preview workflow. Requires the Stitch MCP server to be connected.
- **Stitch integration in brainstorming**: Brainstorming skill now checks for Stitch MCP availability when the work involves UI/UX. If present, Stitch replaces the Visual Companion for UI design work; Visual Companion remains available for non-UI visuals (architecture diagrams, flow charts).

## [1.0.2] - 2026-04-13

### Removed
- **Deprecated commands folder**: Removed `commands/` directory (`brainstorm.md`, `execute-plan.md`, `write-plan.md`) — superseded by the Skill tool system.
- **Legacy skills migration warning**: Removed check for `~/.config/superartes/skills` from `hooks/session-start` — this was carried over from superpowers and never applied to superartes.

## [1.0.1] - 2026-03-29

### Changed
- **Controller commits, not subagents**: In subagent-driven-development, only the main agent (controller) commits — after both reviews pass, using the `commit-message` skill. Subagents no longer commit. This ensures consistent commit messages and gives the controller the opportunity to make additional modifications before committing.
- **Commit-message skill used for all artifacts**: Brainstorming design docs and implementation plans are now committed using the `commit-message` skill for consistent formatting.

## [1.0.0] - 2026-03-27 (superartes)

### Changed
- Renamed plugin from "superpowers" to "superartes" to avoid marketplace name collision with obra/superpowers
- Fresh versioning starting at v1.0.0
- Based on superpowers v5.0.6 fork (5.0.6-andy.2)
- Added commit-message skill with cross-references
- Author changed to Andy Brandt in all manifests

## [5.0.6-andy.2] - 2026-03-27 (andybrandt fork)

### Added

- **commit-message skill**: Bundled commit message formatting skill (short one-line messages, version prefix format, `fixes #N` convention, version tagging). Previously a personal skill, now part of the plugin for consistent use by all agents and subagents.
- Cross-references to `commit-message` skill in `verification-before-completion`, `finishing-a-development-branch`, and `writing-plans` skills.

## [5.0.6-andy.1] - 2026-03-27 (andybrandt fork)

### Changed

- **Feature branches instead of worktrees**: Replaced `using-git-worktrees` skill with `using-feature-branches`. Uses standard `git checkout -b` instead of `git worktree add`. Removed worktree cleanup from `finishing-a-development-branch`. Updated all cross-references.
- **Commit policy**: Replaced "frequent commits" with "commit at releasable checkpoints" — all tests pass, codebase works, change is coherent. Affects `writing-plans` and `subagent-driven-development` skills.
- **Simplified doc paths**: Default paths for specs and plans changed from `docs/superpowers/specs/` and `docs/superpowers/plans/` to `docs/specs/` and `docs/plans/`.
- **Fork metadata**: Plugin description, version, and URLs updated to identify this fork. Installation instructions point to `andybrandt/superpowers-andy`.

### Added

- `CLAUDE.md` for Claude Code project guidance
- `docs/installing-fork-in-claude-code.md` — installation guide for this fork

## [5.0.5] - 2026-03-17

### Fixed

- **Brainstorm server ESM fix**: Renamed `server.js` → `server.cjs` so the brainstorming server starts correctly on Node.js 22+ where the root `package.json` `"type": "module"` caused `require()` to fail. ([PR #784](https://github.com/obra/superpowers/pull/784) by @sarbojitrana, fixes [#774](https://github.com/obra/superpowers/issues/774), [#780](https://github.com/obra/superpowers/issues/780), [#783](https://github.com/obra/superpowers/issues/783))
- **Brainstorm owner-PID on Windows**: Skip `BRAINSTORM_OWNER_PID` lifecycle monitoring on Windows/MSYS2 where the PID namespace is invisible to Node.js. Prevents the server from self-terminating after 60 seconds. The 30-minute idle timeout remains as the safety net. ([#770](https://github.com/obra/superpowers/issues/770), docs from [PR #768](https://github.com/obra/superpowers/pull/768) by @lucasyhzhu-debug)
- **stop-server.sh reliability**: Verify the server process actually died before reporting success. Waits up to 2 seconds for graceful shutdown, escalates to `SIGKILL`, and reports failure if the process survives. ([#723](https://github.com/obra/superpowers/issues/723))

### Changed

- **Execution handoff**: Restore user choice between subagent-driven-development and executing-plans after plan writing. Subagent-driven is recommended but no longer mandatory. (Reverts `5e51c3e`)
