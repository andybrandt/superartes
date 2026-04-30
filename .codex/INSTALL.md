# Installing Superartes for Codex

Superartes is distributed as a self-hosted Codex plugin marketplace.

## Installation

Register the marketplace:

```bash
codex plugin marketplace add andybrandt/superartes
```

Open the plugin directory:

```bash
/plugins
```

Choose the Superartes marketplace and install the `superartes` plugin.

## Updating

```bash
codex plugin marketplace upgrade superartes
```

Restart Codex after updating.

## Manual Fallback

If your Codex version does not support plugin marketplaces, or another tool/model needs native skill discovery, use:

```bash
git clone https://github.com/andybrandt/superartes.git ~/.codex/superartes
mkdir -p ~/.agents/skills
ln -s ~/.codex/superartes/skills ~/.agents/skills/superartes
```

Then restart Codex.
