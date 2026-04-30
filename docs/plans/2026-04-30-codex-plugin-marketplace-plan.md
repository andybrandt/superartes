# Codex Plugin Marketplace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:subagent-driven-development (recommended) or superartes:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Superartes installable as a self-hosted Codex plugin marketplace with `codex plugin marketplace add andybrandt/superartes`.

**Architecture:** Keep the repository root as the plugin payload and add Codex metadata beside the existing platform metadata. A repo-scoped `.agents/plugins/marketplace.json` points at the root plugin, and `.codex-plugin/plugin.json` points at the existing `skills/` directory.

**Tech Stack:** JSON manifests, Markdown documentation, Python 3 validation script, shell test runner.

**Commit note:** This plan includes future execution commit checkpoints. Do not commit the spec or plan during the planning turn unless Andy explicitly asks.

---

## File Structure

- Create `.codex-plugin/plugin.json`: Codex plugin manifest for the existing Superartes root package.
- Create `.agents/plugins/marketplace.json`: Codex marketplace manifest exposing the root plugin.
- Create `assets/superartes-small.svg`: lightweight composer icon referenced by the manifest.
- Create `assets/app-icon.png`: deterministic PNG logo generated from a local Python script.
- Create `scripts/generate-codex-app-icon.py`: reproducible generator for `assets/app-icon.png`.
- Create `tests/codex-plugin/validate-codex-plugin.py`: local JSON/path/version validation.
- Create `tests/codex-plugin/run-tests.sh`: shell wrapper for the validation test.
- Modify `README.md`: make Codex plugin marketplace install the only documented Codex path in the main README.
- Modify `docs/README.codex.md`: replace symlink-first documentation with plugin-first documentation.
- Modify `.codex/INSTALL.md`: short install instructions for Codex plugin marketplace use, with manual symlink fallback.

## Task 1: Add Failing Codex Metadata Validation

**Files:**
- Create: `tests/codex-plugin/validate-codex-plugin.py`
- Create: `tests/codex-plugin/run-tests.sh`

- [ ] **Step 1: Create the validator**

Add `tests/codex-plugin/validate-codex-plugin.py`:

```python
#!/usr/bin/env python3
"""Validate Superartes Codex plugin and marketplace metadata."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]


def fail(message: str) -> None:
    """Report a validation failure and stop."""
    print(f"[FAIL] {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    """Require a condition to be true."""
    if not condition:
        fail(message)


def load_json(path: Path) -> dict[str, Any]:
    """Load a JSON file and require the top-level value to be an object."""
    require(path.is_file(), f"Missing JSON file: {path.relative_to(REPO_ROOT)}")

    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    require(isinstance(data, dict), f"JSON root must be an object: {path}")
    return data


def resolve_plugin_path(base: Path, raw_path: str, field_name: str) -> Path:
    """Resolve a manifest path and require it to stay inside the repository."""
    require(raw_path.startswith("./"), f"{field_name} must start with './'")

    resolved = (base / raw_path[2:]).resolve()
    repo_root = REPO_ROOT.resolve()
    require(
        resolved == repo_root or repo_root in resolved.parents,
        f"{field_name} points outside the repository: {raw_path}",
    )
    return resolved


def validate_plugin_manifest(package: dict[str, Any]) -> dict[str, Any]:
    """Validate .codex-plugin/plugin.json."""
    manifest = load_json(REPO_ROOT / ".codex-plugin" / "plugin.json")

    require(manifest.get("name") == "superartes", "Plugin name must be superartes")
    require(
        manifest.get("version") == package.get("version"),
        "Plugin version must match package.json",
    )
    require(
        manifest.get("description"),
        "Plugin manifest must include a description",
    )

    skills_path = resolve_plugin_path(REPO_ROOT, manifest.get("skills", ""), "skills")
    require(skills_path.is_dir(), "Plugin skills path must exist")
    require(
        (skills_path / "using-superartes" / "SKILL.md").is_file(),
        "Plugin skills path must contain using-superartes",
    )

    interface = manifest.get("interface")
    require(isinstance(interface, dict), "Plugin manifest must include interface")

    for field_name in (
        "displayName",
        "shortDescription",
        "longDescription",
        "developerName",
        "category",
        "brandColor",
    ):
        require(interface.get(field_name), f"interface.{field_name} is required")

    capabilities = interface.get("capabilities")
    require(isinstance(capabilities, list), "interface.capabilities must be a list")
    require("Read" in capabilities, "interface.capabilities must include Read")
    require("Write" in capabilities, "interface.capabilities must include Write")

    for field_name in ("composerIcon", "logo"):
        asset_path = resolve_plugin_path(REPO_ROOT, interface.get(field_name, ""), field_name)
        require(asset_path.is_file(), f"interface.{field_name} asset must exist")

        if field_name == "composerIcon":
            svg_text = asset_path.read_text(encoding="utf-8")
            require(svg_text.lstrip().startswith("<svg"), "composerIcon must be an SVG file")

        if field_name == "logo":
            png_signature = b"\x89PNG\r\n\x1a\n"
            require(
                asset_path.read_bytes().startswith(png_signature),
                "logo must be a PNG file",
            )

    screenshots = interface.get("screenshots", [])
    require(isinstance(screenshots, list), "interface.screenshots must be a list")
    for index, screenshot in enumerate(screenshots):
        screenshot_path = resolve_plugin_path(REPO_ROOT, screenshot, f"screenshots[{index}]")
        require(screenshot_path.is_file(), f"screenshot asset must exist: {screenshot}")

    return manifest


def validate_marketplace(plugin_manifest: dict[str, Any]) -> None:
    """Validate .agents/plugins/marketplace.json."""
    marketplace = load_json(REPO_ROOT / ".agents" / "plugins" / "marketplace.json")

    require(marketplace.get("name") == "superartes", "Marketplace name must be superartes")
    interface = marketplace.get("interface")
    require(isinstance(interface, dict), "Marketplace must include interface")
    require(
        interface.get("displayName") == "Superartes",
        "Marketplace displayName must be Superartes",
    )

    plugins = marketplace.get("plugins")
    require(isinstance(plugins, list), "Marketplace plugins must be a list")
    require(len(plugins) == 1, "Marketplace must expose exactly one plugin")

    entry = plugins[0]
    require(entry.get("name") == plugin_manifest["name"], "Marketplace plugin name mismatch")
    require(entry.get("category") == "Coding", "Marketplace category must be Coding")

    policy = entry.get("policy")
    require(isinstance(policy, dict), "Marketplace plugin must include policy")
    require(policy.get("installation") == "AVAILABLE", "Plugin must be installable")
    require(policy.get("authentication") == "ON_INSTALL", "Authentication policy mismatch")

    source = entry.get("source")
    require(isinstance(source, dict), "Marketplace source must be an object")
    require(source.get("source") == "url", "Marketplace source must be url")
    require(
        source.get("url") == "https://github.com/andybrandt/superartes.git",
        "Marketplace URL must point at the Superartes repository",
    )
    require(source.get("ref") == "main", "Marketplace source must pin ref main")

    source_root = REPO_ROOT.resolve()
    require(
        (source_root / ".codex-plugin" / "plugin.json").is_file(),
        "Repository root must contain .codex-plugin/plugin.json",
    )


def main() -> None:
    """Run all validation checks."""
    package = load_json(REPO_ROOT / "package.json")
    plugin_manifest = validate_plugin_manifest(package)
    validate_marketplace(plugin_manifest)
    print("[PASS] Codex plugin metadata is valid")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Create the test runner**

Add `tests/codex-plugin/run-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$REPO_ROOT"
python3 tests/codex-plugin/validate-codex-plugin.py
```

- [ ] **Step 3: Make the shell runner executable**

Run:

```bash
chmod +x tests/codex-plugin/run-tests.sh
```

- [ ] **Step 4: Run the test and verify it fails**

Run:

```bash
tests/codex-plugin/run-tests.sh
```

Expected: FAIL with a message like:

```text
[FAIL] Missing JSON file: .codex-plugin/plugin.json
```

## Task 2: Add Codex Plugin Manifest And Assets

**Files:**
- Create: `.codex-plugin/plugin.json`
- Create: `assets/superartes-small.svg`
- Create: `assets/app-icon.png`
- Create: `scripts/generate-codex-app-icon.py`
- Test: `tests/codex-plugin/validate-codex-plugin.py`

- [ ] **Step 1: Add the Codex plugin manifest**

Create `.codex-plugin/plugin.json`:

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

- [ ] **Step 2: Add the SVG composer icon**

Create `assets/superartes-small.svg`:

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="Superartes">
  <rect width="64" height="64" rx="14" fill="#2563EB"/>
  <path d="M18 44V20h28v7H26v5h17v7H26v5h20v7H18z" fill="#FFFFFF"/>
  <path d="M14 14h36v6H14z" fill="#F59E0B"/>
</svg>
```

- [ ] **Step 3: Add the deterministic PNG generator**

Create `scripts/generate-codex-app-icon.py`:

```python
#!/usr/bin/env python3
"""Generate the Superartes Codex plugin PNG icon."""

from __future__ import annotations

import struct
import zlib
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_PATH = REPO_ROOT / "assets" / "app-icon.png"
WIDTH = 256
HEIGHT = 256


def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    """Create a PNG chunk with CRC."""
    checksum = zlib.crc32(chunk_type)
    checksum = zlib.crc32(data, checksum)
    return (
        struct.pack(">I", len(data))
        + chunk_type
        + data
        + struct.pack(">I", checksum & 0xFFFFFFFF)
    )


def pixel_at(x_position: int, y_position: int) -> tuple[int, int, int, int]:
    """Return the RGBA color for one icon pixel."""
    margin = 28
    stripe_bottom = 72
    letter_left = 66
    letter_right = 190
    letter_top = 86
    letter_bottom = 184

    if x_position < margin or x_position >= WIDTH - margin:
        return (37, 99, 235, 255)
    if y_position < margin or y_position >= HEIGHT - margin:
        return (37, 99, 235, 255)
    if margin <= y_position < stripe_bottom:
        return (245, 158, 11, 255)
    if letter_left <= x_position < letter_right and letter_top <= y_position < letter_top + 24:
        return (255, 255, 255, 255)
    if letter_left <= x_position < letter_left + 34 and letter_top <= y_position < letter_bottom:
        return (255, 255, 255, 255)
    if letter_left <= x_position < letter_right - 14 and 123 <= y_position < 147:
        return (255, 255, 255, 255)
    if letter_left <= x_position < letter_right and letter_bottom - 24 <= y_position < letter_bottom:
        return (255, 255, 255, 255)
    return (37, 99, 235, 255)


def build_image_data() -> bytes:
    """Build raw filtered RGBA scanlines."""
    rows: list[bytes] = []

    for y_position in range(HEIGHT):
        row = bytearray([0])
        for x_position in range(WIDTH):
            row.extend(pixel_at(x_position, y_position))
        rows.append(bytes(row))

    return b"".join(rows)


def main() -> None:
    """Write the PNG icon."""
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)

    signature = b"\x89PNG\r\n\x1a\n"
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0)
    image_data = zlib.compress(build_image_data(), level=9)

    OUTPUT_PATH.write_bytes(
        signature
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", image_data)
        + png_chunk(b"IEND", b"")
    )
    print(f"Wrote {OUTPUT_PATH.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Generate the PNG asset**

Run:

```bash
python3 scripts/generate-codex-app-icon.py
```

Expected:

```text
Wrote assets/app-icon.png
```

- [ ] **Step 5: Run the metadata test and verify the next failure**

Run:

```bash
tests/codex-plugin/run-tests.sh
```

Expected: FAIL with:

```text
[FAIL] Missing JSON file: .agents/plugins/marketplace.json
```

## Task 3: Add Codex Marketplace Manifest

**Files:**
- Create: `.agents/plugins/marketplace.json`
- Test: `tests/codex-plugin/validate-codex-plugin.py`

- [ ] **Step 1: Add the marketplace manifest**

Create `.agents/plugins/marketplace.json`:

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

- [ ] **Step 2: Run the metadata test and verify it passes**

Run:

```bash
tests/codex-plugin/run-tests.sh
```

Expected:

```text
[PASS] Codex plugin metadata is valid
```

- [ ] **Step 3: Run all fast metadata checks**

Run:

```bash
python3 -m json.tool .codex-plugin/plugin.json >/dev/null
python3 -m json.tool .agents/plugins/marketplace.json >/dev/null
tests/codex-plugin/run-tests.sh
```

Expected: all commands exit with status 0.

- [ ] **Step 4: Commit the plugin metadata checkpoint**

Use `superartes:commit-message`, then commit:

```bash
git add .codex-plugin/plugin.json .agents/plugins/marketplace.json assets/superartes-small.svg assets/app-icon.png scripts/generate-codex-app-icon.py tests/codex-plugin/validate-codex-plugin.py tests/codex-plugin/run-tests.sh
git commit -m "add Codex plugin marketplace metadata"
```

## Task 4: Update Codex Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/README.codex.md`
- Modify: `.codex/INSTALL.md`

- [ ] **Step 1: Update README Codex install section**

In `README.md`, replace the current Codex clone-and-symlink block with:

````markdown
### Codex

Register this repository as a Codex plugin marketplace:

```bash
codex plugin marketplace add andybrandt/superartes
```

Then open the plugin directory and install Superartes:

```bash
/plugins
```

To update after new commits are pushed:

```bash
codex plugin marketplace upgrade superartes
```

Manual clone, pull, and symlink installation is intentionally not shown in the main README. It remains documented in [docs/README.codex.md](docs/README.codex.md) only as a fallback for older Codex versions or other tools/models that still need native skill discovery.
````

- [ ] **Step 2: Rewrite docs/README.codex.md around plugin installation**

Replace the top sections of `docs/README.codex.md` with plugin-first instructions:

````markdown
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

## Manual Fallback For Older Codex Versions And Other Tools

Use this only if plugin marketplace installation is unavailable in your Codex version, or when another tool/model can read native skills but cannot install Codex plugins.

1. Clone the repo:

   ```bash
   git clone https://github.com/andybrandt/superartes.git ~/.codex/superartes
   ```

2. Create the skills symlink:

   ```bash
   mkdir -p ~/.agents/skills
   ln -s ~/.codex/superartes/skills ~/.agents/skills/superartes
   ```

3. Restart Codex.
````

Keep the existing sections that explain subagent config, Windows junctions, usage, troubleshooting, and getting help, but adjust any `obra/superartes` URLs to `andybrandt/superartes`.

- [ ] **Step 3: Rewrite .codex/INSTALL.md as the short install entry point**

Replace `.codex/INSTALL.md` with:

````markdown
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

If your Codex version does not support plugin marketplaces, use native skill discovery:

```bash
git clone https://github.com/andybrandt/superartes.git ~/.codex/superartes
mkdir -p ~/.agents/skills
ln -s ~/.codex/superartes/skills ~/.agents/skills/superartes
```

Then restart Codex.
````

- [ ] **Step 4: Verify documentation references**

Run:

```bash
rg -n "obra/superartes|~/.agents/skills|codex plugin marketplace" README.md docs/README.codex.md .codex/INSTALL.md
```

Expected:
- No `obra/superartes` results.
- `codex plugin marketplace add andybrandt/superartes` appears in all three files.
- `~/.agents/skills`, `git clone`, and `git pull` do not appear in `README.md`.
- `~/.agents/skills` appears only in fallback/manual sections of Codex-specific docs.

- [ ] **Step 5: Run validation after docs update**

Run:

```bash
tests/codex-plugin/run-tests.sh
```

Expected:

```text
[PASS] Codex plugin metadata is valid
```

- [ ] **Step 6: Commit the documentation checkpoint**

Use `superartes:commit-message`, then commit:

```bash
git add README.md docs/README.codex.md .codex/INSTALL.md
git commit -m "document Codex plugin marketplace installation"
```

## Task 5: Run Codex Marketplace Smoke Checks

**Files:**
- No planned file changes unless a smoke check reveals a required manifest adjustment.

- [ ] **Step 1: Check Codex CLI support**

Run:

```bash
codex plugin marketplace --help
```

Expected: help output includes `add`, `upgrade`, and `remove`.

- [ ] **Step 2: Try local marketplace registration first**

Run from the repository root:

```bash
codex plugin marketplace add ./
```

Expected: Codex accepts the local marketplace root. If Codex reports that a marketplace with the same name already exists, remove or upgrade the existing local entry before retrying.

- [ ] **Step 3: If local registration works, inspect plugin visibility manually**

Open a fresh Codex session and run:

```bash
/plugins
```

Expected:
- A marketplace named `Superartes` is visible.
- A plugin named `Superartes` is installable.
- The install surface shows the manifest description and icon.

- [ ] **Step 4: Test GitHub marketplace registration if network is available**

Run:

```bash
codex plugin marketplace add andybrandt/superartes
```

Expected: Codex accepts the GitHub shorthand marketplace source. If network access is blocked in the local environment, record that limitation in the final summary rather than changing code.

- [ ] **Step 5: Verify installed skill visibility**

After installing the plugin, start a fresh Codex session and ask:

```text
Use superartes:using-superartes to explain what Superartes skills are available.
```

Expected: Codex can invoke `superartes:using-superartes`, and the installed skills include `brainstorming`, `writing-plans`, `test-driven-development`, and `systematic-debugging`.

- [ ] **Step 6: Apply fallback only if needed**

If the Git-backed root plugin source fails but Codex accepts the marketplace file, update the repository to use a `plugins/superartes/` wrapper matching the layout shown in Codex's examples.

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
        "source": "local",
        "path": "./plugins/superartes"
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

Then update `tests/codex-plugin/validate-codex-plugin.py` so `validate_marketplace()` validates that wrapper path:

```python
    require(source.get("source") == "local", "Marketplace source must be local")
    source_root = resolve_plugin_path(REPO_ROOT, source.get("path", ""), "source.path")
    require(
        (source_root / ".codex-plugin" / "plugin.json").is_file(),
        "Marketplace source path must contain .codex-plugin/plugin.json",
    )
```

Run:

```bash
tests/codex-plugin/run-tests.sh
```

Expected:

```text
[PASS] Codex plugin metadata is valid
```

- [ ] **Step 7: Commit any smoke-test adjustment**

Only if Task 5 changed files, use `superartes:commit-message`, then commit:

```bash
git add .agents/plugins/marketplace.json tests/codex-plugin/validate-codex-plugin.py
git commit -m "fix Codex marketplace source metadata"
```

## Self-Review Checklist

- [ ] The plan implements the spec's first-class `.codex-plugin/plugin.json`.
- [ ] The plan implements the spec's self-hosted `.agents/plugins/marketplace.json`.
- [ ] The plan preserves existing `skills/` and does not duplicate skill content.
- [ ] The plan updates all Codex-facing documentation.
- [ ] The plan includes a local validation test that does not require network access.
- [ ] The plan includes a live Codex smoke test when CLI/network support allows it.
- [ ] The plan includes a fallback if Codex rejects Git-backed root plugin sources.
