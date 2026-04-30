# Superartes for Codex

Guide for installing Superartes in OpenAI Codex as a plugin.

## Quick Install

Register this repository as a Codex plugin marketplace:

```bash
codex plugin marketplace add andybrandt/superartes
```

Open the plugin directory:

```bash
/plugins
```

Choose the Superartes marketplace, then install the `superartes` plugin.

## Updating

```bash
codex plugin marketplace upgrade superartes
```

Restart Codex after updating so plugin metadata and skills are reloaded.

## Subagent Support

Skills like `dispatching-parallel-agents` and `subagent-driven-development` require Codex's multi-agent feature. Add this to your Codex config:

```toml
[features]
multi_agent = true
```

## How It Works

This repository is both a Codex marketplace and the Superartes plugin source:

- `.agents/plugins/marketplace.json` exposes the `superartes` plugin.
- `.codex-plugin/plugin.json` describes the plugin and points Codex at `./skills/`.
- `skills/using-superartes/SKILL.md` bootstraps the workflow discipline and directs Codex to invoke relevant skills.

## Usage

Skills are discovered automatically after installation. Codex activates them when:

- You mention a skill by name, such as `superartes:brainstorming`.
- The task matches a skill's description.
- The `using-superartes` skill directs Codex to use one.

## Manual Fallback For Older Codex Versions And Other Tools

Use this only if plugin marketplace installation is unavailable in your Codex version, or when another tool/model can read native skills but cannot install Codex plugins.

### Unix And macOS

```bash
git clone https://github.com/andybrandt/superartes.git ~/.codex/superartes
mkdir -p ~/.agents/skills
ln -s ~/.codex/superartes/skills ~/.agents/skills/superartes
```

Restart Codex after creating the symlink.

### Windows

Use a junction instead of a symlink:

```powershell
git clone https://github.com/andybrandt/superartes.git "$env:USERPROFILE\.codex\superartes"
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.agents\skills"
cmd /c mklink /J "$env:USERPROFILE\.agents\skills\superartes" "$env:USERPROFILE\.codex\superartes\skills"
```

Restart Codex after creating the junction.

## Personal Skills

Create your own skills in `~/.agents/skills/`:

```bash
mkdir -p ~/.agents/skills/my-skill
```

Create `~/.agents/skills/my-skill/SKILL.md`:

```markdown
---
name: my-skill
description: Use when [condition] - [what it does]
---

# My Skill

[Your skill content here]
```

The `description` field is how Codex decides when to activate a skill automatically. Write it as a clear trigger condition.

## Troubleshooting

### Plugin Marketplace Install Fails

1. Verify your Codex CLI supports plugin marketplaces: `codex plugin marketplace --help`
2. Verify the repository is reachable: `https://github.com/andybrandt/superartes`
3. If plugin support is unavailable, use the manual fallback above.

### Skills Not Showing Up After Manual Fallback

1. Verify the symlink or junction: `ls -la ~/.agents/skills/superartes`
2. Check skills exist: `ls ~/.codex/superartes/skills`
3. Restart Codex because skills are discovered at startup.

### Windows Junction Issues

Junctions normally work without special permissions. If creation fails, try running PowerShell as administrator.

## Getting Help

- Report issues: https://github.com/andybrandt/superartes/issues
- Main documentation: https://github.com/andybrandt/superartes
