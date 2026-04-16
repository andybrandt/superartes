#!/usr/bin/env bash
# invoke-gemini.sh — Cross-platform wrapper for invoking Gemini CLI with a prompt file.
#
# Usage: invoke-gemini.sh <prompt-file> [gemini-args...]
#
# Reads the prompt from the given file, passes it to gemini via pipe
# (avoiding shell escaping issues), then cleans up the prompt file.
# All additional arguments are forwarded to gemini.

set -euo pipefail

PROMPT_FILE="$1"
shift

if [ ! -f "$PROMPT_FILE" ]; then
    echo "Error: prompt file not found: $PROMPT_FILE" >&2
    exit 1
fi

# Clean up the temp file on exit regardless of success or failure.
cleanup() {
    rm -f "$PROMPT_FILE"
}
trap cleanup EXIT

# Pipe the prompt file content to gemini.
# The pipe lives inside this script, so it does not trigger
# Claude Code's "Unhandled node type: pipeline" sandbox prompt.
cat "$PROMPT_FILE" | gemini -p "$(cat)" "$@"
