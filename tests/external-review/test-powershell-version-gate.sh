#!/usr/bin/env bash

set -u

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
ADAPTER="$ROOT_DIR/skills/external-review/invoke-reviewer.ps1"
SUITE="$ROOT_DIR/tests/external-review/Run-Tests.ps1"
EXPECTED='Windows PowerShell 5.1 is required; PowerShell 7 is not supported.'

if ! command -v pwsh >/dev/null 2>&1; then
    echo 'SKIP: pwsh is unavailable for the unsupported-host regression test'
    exit 0
fi

failures=0
probe_root=$(mktemp -d "${TMPDIR:-/tmp}/external-review-pwsh-gate.XXXXXX") || exit 1

cleanup() {
    case "$(basename "$probe_root")" in
        external-review-pwsh-gate.*) rm -rf -- "$probe_root" ;;
    esac
}
trap cleanup EXIT

adapter_output=$(pwsh -NoProfile -File "$ADAPTER" --help 2>&1)
adapter_status=$?
if [ "$adapter_status" -eq 2 ] && printf '%s' "$adapter_output" | grep -Fq "$EXPECTED"; then
    echo 'PASS: adapter rejects PowerShell 7 before dispatch'
else
    echo "FAIL: adapter PowerShell 7 gate returned $adapter_status: $adapter_output" >&2
    failures=$((failures + 1))
fi

suite_output=$(TMPDIR="$probe_root" pwsh -NoProfile -File "$SUITE" -RunnerPath "$ADAPTER" 2>&1)
suite_status=$?
fixture_entry=$(find "$probe_root" -mindepth 1 -print -quit)
if [ "$suite_status" -eq 1 ] && printf '%s' "$suite_output" | grep -Fq "$EXPECTED" &&
    [ -z "$fixture_entry" ]; then
    echo 'PASS: native suite rejects PowerShell 7 before fixture creation'
else
    echo "FAIL: suite PowerShell 7 gate returned $suite_status, fixture=$fixture_entry: $suite_output" >&2
    failures=$((failures + 1))
fi

exit "$failures"
