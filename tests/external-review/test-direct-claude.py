#!/usr/bin/env python3
"""Exercise the documented direct Claude command without contacting Claude."""

from __future__ import annotations

import json
import os
import select
import shlex
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Mapping


TEST_DIRECTORY = Path(__file__).resolve().parent
REPOSITORY_ROOT = TEST_DIRECTORY.parent.parent
DEFAULT_REFERENCE = REPOSITORY_ROOT / "skills/external-review/invoking-reviewers.md"
START_MARKER = "<!-- direct-claude-command:start -->"
END_MARKER = "<!-- direct-claude-command:end -->"
SESSION_ID = "123e4567-e89b-12d3-a456-426614174000"
EXPECTED_COMMAND_TOKENS = [
    "claude", "-p", "--safe-mode", "--permission-mode", "dontAsk",
    "--tools", "Read,Glob,Grep,Bash", "--allowedTools",
    "Read,Glob,Grep,Bash(git diff *),Bash(git status *),"
    "Bash(git rev-parse *),Bash(git cat-file *),Bash(git show *),"
    "Bash(git log *)", "--output-format", "json", "--session-id",
    "<provider-session-uuid>", "<", "<absolute-prompt-path>", ">",
    "<absolute-result-path>", "2>", "<absolute-stderr-path>",
]


def reference_path() -> Path:
    """Return the command reference selected for this test invocation."""
    configured = os.environ.get("SUPERARTES_CLAUDE_REFERENCE")
    if configured is None:
        return DEFAULT_REFERENCE
    path = Path(configured)
    if path.is_absolute():
        return path
    return REPOSITORY_ROOT / path


def normalize_bash_line_continuations(command: str) -> str:
    """Remove only Bash backslash-newline continuations before parsing."""
    normalized: list[str] = []
    index = 0
    single_quoted = False
    double_quoted = False
    while index < len(command):
        character = command[index]
        next_character = (
            command[index + 1] if index + 1 < len(command) else None
        )
        if single_quoted:
            normalized.append(character)
            if character == "'":
                single_quoted = False
            index += 1
            continue
        if character == "\\":
            if next_character == "\n":
                index += 2
                continue
            normalized.append(character)
            if next_character is not None:
                normalized.append(next_character)
                index += 2
                continue
            index += 1
            continue
        normalized.append(character)
        if character == '"':
            double_quoted = not double_quoted
        elif character == "'" and not double_quoted:
            single_quoted = True
        index += 1
    return "".join(normalized)


def extract_command(path: Path) -> str:
    """Extract the Bash command block delimited by the required markers."""
    if not path.is_file():
        raise AssertionError(f"direct Claude reference is missing: {path}")

    text = path.read_text(encoding="utf-8")
    if text.count(START_MARKER) != 1 or text.count(END_MARKER) != 1:
        raise AssertionError(
            "direct Claude reference requires one start and end marker"
        )
    start = text.index(START_MARKER) + len(START_MARKER)
    end = text.index(END_MARKER)
    if end <= start:
        raise AssertionError("direct Claude command markers are out of order")

    marked_text = text[start:end]
    blocks = []
    remaining = marked_text
    while "```" in remaining:
        _, _, after_start = remaining.partition("```")
        language, separator, after_language = after_start.partition("\n")
        if not separator:
            break
        block, closing, remaining = after_language.partition("```")
        if not closing:
            break
        if language.strip().lower() in {"bash", "sh", "shell"}:
            blocks.append(block.strip())

    if len(blocks) != 1 or not blocks[0]:
        raise AssertionError(
            "direct Claude reference requires one non-empty Bash command block"
        )
    command = blocks[0]
    try:
        tokens = shlex.split(
            normalize_bash_line_continuations(command), posix=True
        )
    except ValueError as error:
        raise AssertionError(
            "direct Claude command must be exactly one bare foreground "
            "claude command"
        ) from error
    if tokens != EXPECTED_COMMAND_TOKENS:
        raise AssertionError(
            "direct Claude command must be exactly one bare foreground "
            "claude command"
        )
    return command


def shell_quote(value: Path | str) -> str:
    """Represent a value as one POSIX-shell single-quoted argument."""
    return "'" + str(value).replace("'", "'\"'\"'") + "'"


def render_command(template: str, paths: Mapping[str, Path]) -> str:
    """Substitute documented quoted placeholders with safe shell arguments."""
    replacements = {
        "'<provider-session-uuid>'": shell_quote(SESSION_ID),
        "'<absolute-prompt-path>'": shell_quote(paths["prompt"]),
        "'<absolute-result-path>'": shell_quote(paths["result"]),
        "'<absolute-stderr-path>'": shell_quote(paths["stderr"]),
    }
    rendered = template
    for placeholder, value in replacements.items():
        if rendered.count(placeholder) != 1:
            raise AssertionError(
                f"command must contain exactly one {placeholder}"
            )
        rendered = rendered.replace(placeholder, value)
    if "<provider-session-uuid>" in rendered or \
            "<absolute-prompt-path>" in rendered or \
            "<absolute-result-path>" in rendered or \
            "<absolute-stderr-path>" in rendered:
        raise AssertionError(
            "command has an unreplaced documented placeholder"
        )
    return rendered


class BashCommandParsingTests(unittest.TestCase):
    """Verify parsing normalization matches Bash line-continuation rules."""

    def test_normalizes_bash_line_continuations_outside_single_quotes(
            self
    ) -> None:
        """Bash removes a backslash-newline except inside single quotes."""
        continued = "claude \\\n  --safe-mode"
        literal = "'literal\\\nvalue'"
        self.assertEqual(
            "claude   --safe-mode",
            normalize_bash_line_continuations(continued),
        )
        self.assertEqual(literal, normalize_bash_line_continuations(literal))


class DirectClaudeCommandTests(unittest.TestCase):
    """Run the reference command against a local fake Claude executable."""

    def setUp(self) -> None:
        """Create an isolated fixture after validating the reference."""
        self.command = extract_command(reference_path())
        self.assertIn("--safe-mode", self.command)
        self.assertIn("--permission-mode dontAsk", self.command)
        self.assertIn("--output-format json", self.command)
        self.assertIn("--session-id", self.command)
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="direct-claude-test-"
        )
        self.sandbox = Path(self.temporary_directory.name)
        self.bin_directory = self.sandbox / "only-fake-cli"
        self.bin_directory.mkdir()
        self.argv_file = self.sandbox / "argv.json"
        self.stdin_file = self.sandbox / "stdin.bin"
        self.started_file = self.sandbox / "started"
        self.write_fake_claude()

    def tearDown(self) -> None:
        """Remove this test's fake executable and result files."""
        self.temporary_directory.cleanup()

    def write_fake_claude(self) -> None:
        """Install a fake CLI with an absolute Python interpreter shebang."""
        fake_cli = self.bin_directory / "claude"
        program = f'''#!{sys.executable}
import json
import os
import pathlib
import sys
import time

pathlib.Path(os.environ["FAKE_CLAUDE_ARGV"]).write_text(
    json.dumps(sys.argv[1:]), encoding="utf-8"
)
pathlib.Path(os.environ["FAKE_CLAUDE_STDIN"]).write_bytes(
    sys.stdin.buffer.read()
)
pathlib.Path(os.environ["FAKE_CLAUDE_STARTED"]).write_text(
    "started", encoding="utf-8"
)
mode = os.environ.get("FAKE_CLAUDE_MODE", "success")
if mode == "delayed":
    time.sleep(2.0)
if mode == "failure":
    sys.stdout.write("substantive failed review\\n")
    sys.stderr.write("substantive failure diagnostics\\n")
    raise SystemExit(23)
sys.stdout.write("substantive successful review\\n")
sys.stderr.write("separate diagnostics\\n")
'''
        fake_cli.write_text(program, encoding="utf-8")
        fake_cli.chmod(0o755)

    def command_paths(self) -> dict[str, Path]:
        """Create names with spaces, Unicode, and apostrophes."""
        special_directory = self.sandbox / "żółw's files"
        special_directory.mkdir()
        return {
            "prompt": special_directory / "prompt ' input.txt",
            "result": special_directory / "result ' output.json",
            "stderr": special_directory / "stderr ' output.log",
        }

    def execute(
            self, mode: str = "success"
    ) -> tuple[subprocess.CompletedProcess[bytes], dict[str, Path]]:
        """Run the reference command using only the fake CLI on PATH."""
        paths = self.command_paths()
        prompt_text = "Review: żółw and apostrophe ' remain exact.\n"
        prompt_bytes = prompt_text.encode("utf-8")
        paths["prompt"].write_bytes(prompt_bytes)
        environment = {
            "PATH": str(self.bin_directory),
            "FAKE_CLAUDE_ARGV": str(self.argv_file),
            "FAKE_CLAUDE_STDIN": str(self.stdin_file),
            "FAKE_CLAUDE_STARTED": str(self.started_file),
            "FAKE_CLAUDE_MODE": mode,
        }
        command = render_command(self.command, paths)
        result = subprocess.run(
            ["/bin/bash", "-c", command],
            cwd=self.sandbox,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        return result, paths

    def expected_argv(self) -> list[str]:
        """Return the approved CLI argument vector expected by the contract."""
        return [
            "-p", "--safe-mode", "--permission-mode", "dontAsk", "--tools",
            "Read,Glob,Grep,Bash", "--allowedTools",
            "Read,Glob,Grep,Bash(git diff *),Bash(git status *),"
            "Bash(git rev-parse *),Bash(git cat-file *),Bash(git show *),"
            "Bash(git log *)", "--output-format", "json", "--session-id",
            SESSION_ID,
        ]

    def sabotaged_reference_text(self, old: str, new: str) -> str:
        """Return the reference with one change made inside its command block."""
        original = reference_path().read_text(encoding="utf-8")
        start = original.index(START_MARKER) + len(START_MARKER)
        end = original.index(END_MARKER)
        marked_text = original[start:end]
        if marked_text.count(self.command) != 1:
            raise AssertionError(
                "test sabotage requires exactly one extracted command block"
            )
        if self.command.count(old) != 1:
            raise AssertionError(
                f"test sabotage requires one occurrence of {old!r}"
            )
        sabotaged_command = self.command.replace(old, new, 1)
        return (
            original[:start]
            + marked_text.replace(self.command, sabotaged_command, 1)
            + original[end:]
        )

    def test_command_uses_exact_restrictions_and_preserves_streams(
            self
    ) -> None:
        """The command has fixed arguments and redirects both streams."""
        result, paths = self.execute()
        self.assertEqual(0, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertEqual(b"", result.stderr)
        actual_argv = json.loads(self.argv_file.read_text("utf-8"))
        self.assertEqual(self.expected_argv(), actual_argv)
        self.assertEqual(
            "Review: żółw and apostrophe ' remain exact.\n".encode("utf-8"),
            self.stdin_file.read_bytes(),
        )
        self.assertEqual(
            b"substantive successful review\n", paths["result"].read_bytes()
        )
        self.assertEqual(
            b"separate diagnostics\n", paths["stderr"].read_bytes()
        )

    def test_command_retains_substantive_output_when_claude_exits_23(
            self
    ) -> None:
        """A provider failure keeps its exit code and diagnostic streams."""
        result, paths = self.execute("failure")
        self.assertEqual(23, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertEqual(b"", result.stderr)
        self.assertEqual(
            b"substantive failed review\n", paths["result"].read_bytes()
        )
        self.assertEqual(
            b"substantive failure diagnostics\n", paths["stderr"].read_bytes()
        )

    def test_missing_claude_exits_127_and_leaves_empty_result(self) -> None:
        """A missing Claude exits 127 after Bash creates its result file."""
        self.bin_directory.joinpath("claude").unlink()
        result, paths = self.execute()
        self.assertEqual(127, result.returncode)
        self.assertEqual(b"", result.stdout)
        self.assertEqual(b"", paths["result"].read_bytes())
        self.assertIn(b"claude", paths["stderr"].read_bytes().lower())

    def test_delayed_claude_keeps_the_documented_command_foreground(
            self
    ) -> None:
        """A slow CLI keeps Bash alive while redirected output is empty."""
        paths = self.command_paths()
        paths["prompt"].write_bytes(b"wait for the fake\n")
        environment = {
            "PATH": str(self.bin_directory),
            "FAKE_CLAUDE_ARGV": str(self.argv_file),
            "FAKE_CLAUDE_STDIN": str(self.stdin_file),
            "FAKE_CLAUDE_STARTED": str(self.started_file),
            "FAKE_CLAUDE_MODE": "delayed",
        }
        process = subprocess.Popen(
            ["/bin/bash", "-c", render_command(self.command, paths)],
            cwd=self.sandbox,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            start_deadline = time.monotonic() + 2.0
            while (
                not self.started_file.exists()
                and time.monotonic() < start_deadline
            ):
                time.sleep(0.02)
            self.assertTrue(self.started_file.exists())
            self.assertIsNone(process.poll())
            readable, _, _ = select.select(
                [process.stdout, process.stderr], [], [], 0
            )
            self.assertEqual([], readable)
            self.assertEqual(b"", paths["result"].read_bytes())
            self.assertEqual(b"", paths["stderr"].read_bytes())
            stdout, stderr = process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        self.assertEqual(0, process.returncode)
        self.assertEqual(b"", stdout)
        self.assertEqual(b"", stderr)
        self.assertEqual(
            b"substantive successful review\n", paths["result"].read_bytes()
        )

    def test_sabotaged_reference_without_safe_mode_fails_in_a_subprocess(
            self
    ) -> None:
        """The suite rejects a reference missing the safe-mode flag."""
        damaged = self.sandbox / "damaged-reference.md"
        damaged.write_text(
            self.sabotaged_reference_text("--safe-mode", ""),
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment["SUPERARTES_CLAUDE_REFERENCE"] = str(damaged)
        result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "DirectClaudeCommandTests."
                "test_command_uses_exact_restrictions_and_preserves_streams",
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            b"exactly one bare foreground claude command", result.stderr.lower()
        )

    def test_missing_reference_fails_before_any_command_assertion(self) -> None:
        """A missing reference makes an isolated command test fail in setup."""
        missing = self.sandbox / "missing-reference.md"
        environment = os.environ.copy()
        environment["SUPERARTES_CLAUDE_REFERENCE"] = str(missing)
        result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "DirectClaudeCommandTests."
                "test_command_uses_exact_restrictions_and_preserves_streams",
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b"FAILED (failures=1)", result.stderr)
        self.assertIn(b"direct Claude reference is missing", result.stderr)
        self.assertNotIn(b" OK", result.stderr)

    def test_sabotaged_shell_wrappers_fail_in_subprocesses(self) -> None:
        """Only one bare foreground Claude command is allowed in the reference."""
        sabotages = {
            "absolute executable": self.sabotaged_reference_text(
                "claude ", "/tmp/claude "
            ),
            "PATH override": self.sabotaged_reference_text(
                "claude ", "PATH=/tmp claude "
            ),
            "preliminary command": self.sabotaged_reference_text(
                "claude ", "claude --version\nclaude "
            ),
        }
        for name, damaged_text in sabotages.items():
            with self.subTest(name=name):
                damaged = self.sandbox / f"{name}.md"
                damaged.write_text(damaged_text, encoding="utf-8")
                environment = os.environ.copy()
                environment["SUPERARTES_CLAUDE_REFERENCE"] = str(damaged)
                result = subprocess.run(
                    [
                        sys.executable,
                        str(Path(__file__).resolve()),
                        "DirectClaudeCommandTests."
                        "test_command_uses_exact_restrictions_and_preserves_streams",
                    ],
                    cwd=REPOSITORY_ROOT,
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertNotEqual(0, result.returncode)
                self.assertIn(
                    b"exactly one bare foreground claude command",
                    result.stderr.lower(),
                )

    def test_backgrounded_claude_fails_in_a_subprocess(self) -> None:
        """A shell that waits after backgrounding Claude cannot pass as foreground."""
        damaged = self.sandbox / "backgrounded-reference.md"
        damaged.write_text(
            self.sabotaged_reference_text(
                "2> '<absolute-stderr-path>'",
                "2> '<absolute-stderr-path>' & sleep 1",
            ),
            encoding="utf-8",
        )
        environment = os.environ.copy()
        environment["SUPERARTES_CLAUDE_REFERENCE"] = str(damaged)
        result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "DirectClaudeCommandTests."
                "test_delayed_claude_keeps_the_documented_command_foreground",
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            b"exactly one bare foreground claude command", result.stderr.lower()
        )


if __name__ == "__main__":
    unittest.main()
