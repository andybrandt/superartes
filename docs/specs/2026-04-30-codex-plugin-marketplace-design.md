# Codex Plugin Marketplace Design

## Context

Superartes currently supports Codex through manual native skill discovery: clone the repository, symlink `skills/` into `~/.agents/skills/superartes`, then restart Codex. The goal is to make Superartes installable as a normal Codex plugin, with this repository acting as the Codex plugin marketplace.

Target user flow:

```bash
codex plugin marketplace add andybrandt/superartes
```

After that, the user should be able to install `superartes` from Codex's plugin interface. Superartes is not targeting the official OpenAI plugin repository in this iteration.

## References

- OpenAI Codex plugin build documentation: https://developers.openai.com/codex/plugins/build
- Local reference implementation: `../superpowers`

Superpowers now ships a first-class `.codex-plugin/plugin.json` with `skills: "./skills/"` and rich `interface` metadata. It does not include a repo-local `.agents/plugins/marketplace.json`; instead, it has a sync script for publishing into `prime-radiant-inc/openai-codex-plugins/plugins/superpowers`. Superartes should follow the manifest shape but not the external sync workflow, because Superartes will be self-hosted as its own marketplace.

## Design Goals

1. Make Superartes installable by Codex as a plugin, not only as a symlinked skills directory.
2. Make the repository itself a Codex marketplace.
3. Preserve the existing multi-platform layout for Claude Code, Cursor, OpenCode, Gemini CLI, and manual Codex installs.
4. Avoid duplicating skills or restructuring the repository around Codex.
5. Keep future official-repository publication possible, without building that workflow now.

## Non-Goals

- Submitting Superartes to OpenAI's official Codex plugin repository.
- Building a sync script like Superpowers' `sync-to-codex-plugin.sh`.
- Changing skill content or skill trigger behavior.
- Removing the existing manual Codex symlink documentation immediately; it can remain as a fallback or troubleshooting path.

## Proposed File Changes

### `.codex-plugin/plugin.json`

Add a first-class Codex plugin manifest at the repository root. It should point directly to the existing skills directory:

```json
{
  "name": "superartes",
  "version": "1.2.2",
  "description": "Composable development workflow skills for AI coding agents.",
  "author": {
    "name": "Andy Brandt"
  },
  "homepage": "https://github.com/andybrandt/superartes",
  "repository": "https://github.com/andybrandt/superartes",
  "license": "MIT",
  "keywords": [
    "brainstorming",
    "subagent-driven-development",
    "skills",
    "planning",
    "tdd",
    "debugging",
    "code-review",
    "workflow"
  ],
  "skills": "./skills/",
  "interface": {
    "displayName": "Superartes",
    "shortDescription": "Planning, TDD, debugging, and delivery workflows for coding agents",
    "longDescription": "Use Superartes to guide agent work through brainstorming, implementation planning, test-driven development, systematic debugging, parallel execution, code review, and finish-the-branch workflows.",
    "developerName": "Andy Brandt",
    "category": "Coding",
    "capabilities": [
      "Interactive",
      "Read",
      "Write"
    ],
    "defaultPrompt": [
      "I've got an idea for something I'd like to build.",
      "Let's add a feature to this project."
    ],
    "brandColor": "#2563EB",
    "composerIcon": "./assets/superartes-small.svg",
    "logo": "./assets/app-icon.png",
    "screenshots": []
  }
}
```

The final wording can be adjusted, but the structure should stay close to Superpowers because that shape is already known to work in Codex plugin distribution.

### `.agents/plugins/marketplace.json`

Add a Codex marketplace manifest:

```json
{
  "name": "superartes",
  "interface": {
    "displayName": "Superartes"
  },
  "plugins": [
    {
      "name": "superartes",
      "source": {
        "source": "url",
        "url": "https://github.com/andybrandt/superartes.git",
        "ref": "main"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Coding"
    }
  ]
}
```

The critical design choice is using a Git-backed URL source for the plugin. Codex clones this same repository as the marketplace; the plugin entry then points Codex back to the repository root, where `.codex-plugin/plugin.json` lives.

### `assets/`

Add minimal plugin assets referenced by the manifest:

- `assets/superartes-small.svg`
- `assets/app-icon.png`

The first iteration can use simple branded assets. These should be stable files committed with the plugin metadata, not generated during installation.

### Documentation

Update Codex install documentation in:

- `README.md`
- `docs/README.codex.md`
- `.codex/INSTALL.md`

Primary installation should become:

```bash
codex plugin marketplace add andybrandt/superartes
```

The main `README.md` should not include Codex clone, pull, or symlink installation instructions. Those legacy instructions should remain only in Codex-specific fallback documentation (`docs/README.codex.md` and `.codex/INSTALL.md`) for users on older Codex versions or other tools/models that still rely on native skill discovery.

### Validation

Add a small validation script or test that checks:

- `.codex-plugin/plugin.json` parses as JSON.
- `.agents/plugins/marketplace.json` parses as JSON.
- Plugin version matches `package.json`.
- Referenced `skills`, `composerIcon`, and `logo` paths exist.
- Marketplace plugin name matches Codex plugin manifest name.
- Marketplace source points to `https://github.com/andybrandt/superartes.git` at `main`, and the repository root contains `.codex-plugin/plugin.json`.

This can be a shell test using `python3 -m json.tool` or a small Python script. It should be runnable locally without network access.

## Alternatives Considered

### Only Add `.codex-plugin/plugin.json`

This matches the Superpowers repository itself, but it does not satisfy the goal that `andybrandt/superartes` acts as the Codex marketplace. Superpowers relies on external publication into another repository; Superartes does not want that workflow yet.

### Copy Superpowers' External Sync Workflow

This would prepare Superartes for an official or shared plugin repository, but it adds moving parts before there is a distribution need. It also introduces GitHub CLI and remote repository assumptions that do not help the current install path.

### Move Plugin Payload Under `plugins/superartes/`

This mirrors a centralized marketplace repository, but it would duplicate or relocate the existing skills. The repository already works well as a multi-platform root package, so adding Codex metadata at the root is simpler.

## Risks and Open Questions

### Marketplace Source Behavior

The design uses `source: "url"` rather than `source: "local"` for the plugin entry. This matches the Codex documentation guidance for Git-backed plugin sources and avoids ambiguity around resolving `./` when the marketplace itself is the repository root.

If Codex rejects a Git-backed root plugin source, use a shallow `plugins/superartes/` wrapper that copies the plugin payload into the layout shown in Codex's examples.

### Manifest Schema Drift

Codex plugin metadata is new and may evolve. The implementation should stay close to the official documentation and Superpowers' current manifest shape, and validation should avoid over-enforcing fields that Codex treats as optional.

### Asset Quality

Minimal assets are enough for functionality, but the plugin browser will look more polished with real branded icon work. This is not required for the first functional iteration.

## Testing Strategy

1. Run the local JSON/path validation test.
2. If the installed Codex CLI supports plugin marketplace commands in the local environment, test:

   ```bash
   codex plugin marketplace add andybrandt/superartes
   ```

3. If network or CLI support blocks that test, document the limitation and verify all local files against the Codex documentation and Superpowers reference.
4. Start a fresh Codex session after installation and confirm that `superartes:using-superartes` and at least one workflow skill are visible or invokable.

## Recommended Implementation Order

1. Add `.codex-plugin/plugin.json` and minimal assets.
2. Add `.agents/plugins/marketplace.json`.
3. Add validation script or test.
4. Update Codex-facing documentation.
5. Run validation and, if possible, a real Codex marketplace install test.

Each step leaves the repository usable: existing platform integrations remain untouched, and Codex manual symlink installation continues to work until the plugin path is verified.
