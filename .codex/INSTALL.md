# Installing Superartes for Codex

Enable superartes skills in Codex via native skill discovery. Just clone and symlink.

## Prerequisites

- Git

## Installation

1. **Clone the superartes repository:**
   ```bash
   git clone https://github.com/obra/superartes.git ~/.codex/superartes
   ```

2. **Create the skills symlink:**
   ```bash
   mkdir -p ~/.agents/skills
   ln -s ~/.codex/superartes/skills ~/.agents/skills/superartes
   ```

   **Windows (PowerShell):**
   ```powershell
   New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.agents\skills"
   cmd /c mklink /J "$env:USERPROFILE\.agents\skills\superartes" "$env:USERPROFILE\.codex\superartes\skills"
   ```

3. **Restart Codex** (quit and relaunch the CLI) to discover the skills.

## Migrating from old bootstrap

If you installed superartes before native skill discovery, you need to:

1. **Update the repo:**
   ```bash
   cd ~/.codex/superartes && git pull
   ```

2. **Create the skills symlink** (step 2 above) — this is the new discovery mechanism.

3. **Remove the old bootstrap block** from `~/.codex/AGENTS.md` — any block referencing `superartes-codex bootstrap` is no longer needed.

4. **Restart Codex.**

## Verify

```bash
ls -la ~/.agents/skills/superartes
```

You should see a symlink (or junction on Windows) pointing to your superartes skills directory.

## Updating

```bash
cd ~/.codex/superartes && git pull
```

Skills update instantly through the symlink.

## Uninstalling

```bash
rm ~/.agents/skills/superartes
```

Optionally delete the clone: `rm -rf ~/.codex/superartes`.
