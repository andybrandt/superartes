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


def validate_version_surfaces(package: dict[str, Any]) -> None:
    """Validate plugin and marketplace versions match package.json."""
    expected_version = package.get("version")
    require(expected_version, "package.json must include a version")

    version_checks = (
        (REPO_ROOT / ".claude-plugin" / "plugin.json", ("version",)),
        (REPO_ROOT / ".claude-plugin" / "marketplace.json", ("plugins", 0, "version")),
        (REPO_ROOT / ".cursor-plugin" / "plugin.json", ("version",)),
        (REPO_ROOT / ".codex-plugin" / "plugin.json", ("version",)),
    )

    for path, key_path in version_checks:
        data: Any = load_json(path)
        for key in key_path:
            require(
                isinstance(data, list | dict),
                f"Cannot read version from {path.relative_to(REPO_ROOT)}",
            )
            data = data[key]

        require(
            data == expected_version,
            f"{path.relative_to(REPO_ROOT)} version must match package.json",
        )


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
    validate_version_surfaces(package)
    plugin_manifest = validate_plugin_manifest(package)
    validate_marketplace(plugin_manifest)
    print("[PASS] Codex plugin metadata is valid")


if __name__ == "__main__":
    main()
