# Changelog

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
