#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/skills/external-review/invoke-reviewer.sh"
TEST_TMP=""
TEST_TMP_CANONICAL=""
PASSED=0
FAILED=0
CAPTURE_RC=0
CAPTURE_OUTPUT=""
FAKE_LOG_DIR=""

begin_suite() {
    TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/external-review-tests.XXXXXX")"
    TEST_TMP_CANONICAL="$(cd "$TEST_TMP" && pwd -P)"
    export SUPERARTES_REVIEW_TMPDIR="$TEST_TMP/reviews"
    export PATH="$TEST_TMP/bin:$PATH"
    mkdir -p "$TEST_TMP/bin" "$SUPERARTES_REVIEW_TMPDIR"
}

fixture_process_start_identity() {
    { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null || true; } | \
        sed 's/^[[:space:]]*//'
}

fixture_process_identity_matches() {
    local pid="$1"
    local expected="$2"
    local actual
    kill -0 "$pid" 2>/dev/null || return 1
    actual="$(fixture_process_start_identity "$pid")"
    [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

fixture_wait_for_identity_loss() {
    local pid="$1"
    local expected="$2"
    local attempt=0
    while [ "$attempt" -lt 30 ]; do
        if ! fixture_process_identity_matches "$pid" "$expected"; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    return 1
}

fixture_terminate_process() {
    local pid="$1"
    local expected="$2"
    local use_group="$3"
    fixture_process_identity_matches "$pid" "$expected" || return 0
    if [ "$use_group" -eq 1 ]; then
        kill -TERM -- "-$pid" 2>/dev/null || return 1
    else
        kill -TERM "$pid" 2>/dev/null || return 1
    fi
    if fixture_wait_for_identity_loss "$pid" "$expected"; then
        return 0
    fi
    fixture_process_identity_matches "$pid" "$expected" || return 0
    if [ "$use_group" -eq 1 ]; then
        kill -KILL -- "-$pid" 2>/dev/null || return 1
    else
        kill -KILL "$pid" 2>/dev/null || return 1
    fi
    fixture_wait_for_identity_loss "$pid" "$expected"
}

terminate_test_run() {
    local requested="$1"
    local canonical
    local recorded
    local run_id
    local pid
    local expected
    local pgid
    [ -n "$TEST_TMP_CANONICAL" ] || return 1
    [ ! -L "$requested" ] || return 1
    canonical="$(cd "$requested" 2>/dev/null && pwd -P)" || return 1
    case "$canonical" in
        "$TEST_TMP_CANONICAL"/*/run-*) ;;
        *) return 1 ;;
    esac
    recorded="$(cat "$canonical/run-path" 2>/dev/null)" || return 1
    run_id="$(cat "$canonical/run-id" 2>/dev/null)" || return 1
    [ "$recorded" = "$canonical" ] || return 1
    [ "$(cat "$canonical/marker" 2>/dev/null)" = \
        "superartes-external-review:$run_id" ] || return 1

    pid="$(cat "$canonical/reviewer-pid" 2>/dev/null || true)"
    expected="$(cat "$canonical/reviewer-start" 2>/dev/null || true)"
    if [ -n "$pid" ] && [ -n "$expected" ] && \
        fixture_process_identity_matches "$pid" "$expected"; then
        pgid="$(cat "$canonical/reviewer-pgid" 2>/dev/null || true)"
        if [ "$pgid" = "$pid" ]; then
            fixture_terminate_process "$pid" "$expected" 1 || return 1
        else
            fixture_terminate_process "$pid" "$expected" 0 || return 1
        fi
    fi

    pid="$(cat "$canonical/supervisor-pid" 2>/dev/null || true)"
    expected="$(cat "$canonical/supervisor-start" 2>/dev/null || true)"
    if [ -n "$pid" ] && [ -n "$expected" ]; then
        fixture_terminate_process "$pid" "$expected" 0 || return 1
    fi
}

end_suite() {
    local run_list
    local run_dir
    local safe=1
    if [ -z "$TEST_TMP" ] || [ ! -d "$TEST_TMP" ] || \
        [ -L "$TEST_TMP" ]; then
        return
    fi
    [ "$(cd "$TEST_TMP" && pwd -P)" = "$TEST_TMP_CANONICAL" ] || return
    case "$(basename "$TEST_TMP_CANONICAL")" in
        external-review-tests.*) ;;
        *) return ;;
    esac

    run_list="$TEST_TMP/.teardown-runs.$$"
    find "$TEST_TMP" -type d -name 'run-*' -print > "$run_list"
    while IFS= read -r run_dir; do
        [ -n "$run_dir" ] || continue
        if [ -f "$run_dir/reviewer-pid" ] || \
            [ -f "$run_dir/supervisor-pid" ]; then
            terminate_test_run "$run_dir" || safe=0
        fi
    done < "$run_list"
    if [ "$safe" -eq 1 ]; then
        rm -rf -- "$TEST_TMP"
    else
        printf 'Test teardown retained unsafe fixture directory: %s\n' \
            "$TEST_TMP" >&2
    fi
}

pass() {
    PASSED=$((PASSED + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAILED=$((FAILED + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$message"
    else
        fail "$message (expected '$expected', got '$actual')"
    fi
}

assert_file_contains() {
    local path="$1"
    local text="$2"
    local message="$3"
    if [ -f "$path" ] && grep -Fq -- "$text" "$path"; then
        pass "$message"
    else
        fail "$message"
    fi
}

assert_file_not_contains() {
    local path="$1"
    local text="$2"
    local message="$3"
    if [ -f "$path" ] && ! grep -Fq -- "$text" "$path"; then
        pass "$message"
    else
        fail "$message"
    fi
}

assert_file_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if cmp -s -- "$expected" "$actual"; then
        pass "$message"
    else
        fail "$message"
    fi
}

assert_string_contains() {
    local value="$1"
    local text="$2"
    local message="$3"
    case "$value" in
        *"$text"*) pass "$message" ;;
        *) fail "$message" ;;
    esac
}

run_captured() {
    local capture="$TEST_TMP/capture.$$.txt"
    set +e
    "$@" > "$capture" 2>&1
    CAPTURE_RC=$?
    set -e
    CAPTURE_OUTPUT="$(cat "$capture")"
    rm -f -- "$capture"
}

output_field() {
    local field="$1"
    printf '%s\n' "$CAPTURE_OUTPUT" | sed -n "s/^${field}=//p" | head -n 1
}

write_fake_claude() {
    cat > "$TEST_TMP/bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
    printf '2.1.235\n'
    exit 0
fi
if [ "${1:-}" = "--help" ]; then
    printf '%s\n' '--safe-mode --permission-mode --output-format --session-id --tools --allowedTools'
    exit 0
fi

session_id=''
previous=''
for argument in "$@"; do
    if [ "$previous" = '--session-id' ]; then
        session_id="$argument"
    fi
    previous="$argument"
done
[ -n "$session_id" ] || { printf 'missing fake session id\n' >&2; exit 64; }

log_base="${FAKE_LOG_DIR:?}/claude-$session_id"
printf '%s\n' "$*" > "$log_base.args"
printf '%s\n' "$PWD" > "$log_base.pwd"
cat > "$log_base.stdin"
sleep "${FAKE_REVIEW_DELAY:-0}"
if [ "${FAKE_REVIEW_EXIT:-0}" -ne 0 ]; then
    if [ "${FAKE_RESULT_BEFORE_EXIT:-0}" -eq 1 ]; then
        if [ -n "${FAKE_CLAUDE_PARTIAL_FILE:-}" ]; then
            cat "$FAKE_CLAUDE_PARTIAL_FILE"
        else
            printf '[{"type":"result","session_id":"fake","result":"fake Claude partial review"}]\n'
        fi
    fi
    printf 'fake Claude failure\n' >&2
    exit "$FAKE_REVIEW_EXIT"
fi
printf '[{"type":"result","session_id":"fake","result":"fake Claude review"}]\n'
FAKE_CLAUDE
    chmod +x "$TEST_TMP/bin/claude"
}

write_fake_codex() {
    cat > "$TEST_TMP/bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ]; then
    printf 'codex-test\n'
    exit 0
fi
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "--help" ]; then
    printf '%s\n' '--sandbox --skip-git-repo-check --output-last-message'
    exit 0
fi
if [ "${1:-}" = "exec" ] && [ "${2:-}" = "review" ] && [ "${3:-}" = "--help" ]; then
    printf '%s\n' '--uncommitted --base --commit --skip-git-repo-check --output-last-message'
    exit 0
fi

output=''
previous=''
for argument in "$@"; do
    if [ "$previous" = '-o' ] || [ "$previous" = '--output-last-message' ]; then
        output="$argument"
    fi
    previous="$argument"
done
[ -n "$output" ] || { printf 'missing fake output path\n' >&2; exit 64; }

run_name="$(basename "$(dirname "$output")")"
log_base="${FAKE_LOG_DIR:?}/codex-$run_name"
printf '%s\n' "$*" > "$log_base.args"
printf '%s\n' "$PWD" > "$log_base.pwd"
if [ "${2:-}" != 'review' ]; then
    cat > "$log_base.stdin"
fi
sleep "${FAKE_REVIEW_DELAY:-0}"
if [ "${FAKE_REVIEW_EXIT:-0}" -ne 0 ]; then
    if [ "${FAKE_RESULT_BEFORE_EXIT:-0}" -eq 1 ]; then
        printf 'fake Codex partial review\n' > "$output"
    fi
    printf 'fake Codex failure\n' >&2
    exit "$FAKE_REVIEW_EXIT"
fi
printf 'fake Codex review\n' > "$output"
FAKE_CODEX
    chmod +x "$TEST_TMP/bin/codex"
}

finish_suite() {
    printf '\nPassed: %d\nFailed: %d\n' "$PASSED" "$FAILED"
    [ "$FAILED" -eq 0 ]
}
