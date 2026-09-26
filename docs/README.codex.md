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

## Independent Claude Reviews

When Codex uses Superartes's `external-review` or `external-code-review` skill,
it can run an installed and authenticated Claude Code CLI for an independent
review. The review prompt and relevant repository files, plans, or diffs are
sent to Claude. Provider usage may incur charges. Installing Superartes does
not itself authorize sending this material.

For a one-time opt-in across your Codex projects, add the following to your
global `~/.codex/AGENTS.md` (or `$CODEX_HOME/AGENTS.md` if you use a custom
Codex home). Keep any instructions already in that file:

```markdown
## Superartes independent reviews

I authorize Codex, when using Superartes's external-review and
external-code-review skills, to send review prompts and review-relevant
repository files, plans, and diffs from projects I open to Claude Code CLI for
independent review, including any applicable provider usage costs. This
authorization remains in effect until I revoke it. Do not ask again solely for
this disclosure. It does not authorize unrelated file disclosure.
```

This is a broad choice: it covers every project you open with Codex. For
narrower standing authorization, put the same instruction in a project's
`AGENTS.md` instead, or authorize individual reviews in conversation. Restart
Codex after changing either file. [Codex loads global and project instructions
at session start](https://learn.chatgpt.com/docs/agent-configuration/agents-md).
If you use `~/.codex/AGENTS.override.md`, put the instruction there instead;
that file replaces the global `AGENTS.md` while it exists.

This instruction tells Codex your disclosure preference. It does not change
Codex's sandbox or approval policy; running the Claude CLI may still require a
separate host approval. The direct Claude review route is tested on Linux;
macOS and WSL are unverified, and native Windows is unavailable.

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
