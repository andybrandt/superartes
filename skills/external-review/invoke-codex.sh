#!/usr/bin/env bash
# invoke-codex.sh — Cross-platform wrapper for invoking Codex CLI headlessly with a prompt file.
#
# Usage: invoke-codex.sh <prompt-file> [codex-args...]
#
# Reads the review prompt from the given file and feeds it to `codex exec`
# via stdin (avoiding shell escaping issues for large, multi-line prompts),
# then cleans up the prompt file. All additional arguments are forwarded to
# `codex exec` (e.g. --sandbox read-only, --output-last-message <file>).
#
# The pipe lives inside this script so it does not trigger Claude Code's
# "Unhandled node type: pipeline" sandbox prompt on every invocation.

set -euo pipefail

PROMPT_FILE="$1"
shift

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: prompt file not found: $PROMPT_FILE" >&2
    exit 1
fi

# Clean up the prompt temp file on exit regardless of success or failure.
cleanup() {
    rm -f "$PROMPT_FILE"
}
trap cleanup EXIT

# Feed the prompt file to Codex via stdin. `codex exec -` reads the prompt
# from stdin instead of taking it as a command-line argument.
cat "$PROMPT_FILE" | codex exec - "$@"
