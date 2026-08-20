#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/test-lib.sh"

trap end_suite EXIT
begin_suite
export FAKE_LOG_DIR="$TEST_TMP/fake-logs"
mkdir -p "$FAKE_LOG_DIR"
write_fake_claude
write_fake_codex
LAST_RUN=""

start_run() {
    local expected_rc="$1"
    shift
    run_captured "$RUNNER" start "$@"
    assert_eq "$expected_rc" "$CAPTURE_RC" "start $* returns $expected_rc"
    LAST_RUN="$(output_field RUN_DIR)"
}

wait_for_run() {
    local run_dir="$1"
    local timeout="$2"
    local expected_rc="$3"
    run_captured "$RUNNER" wait "$run_dir" "$timeout"
    assert_eq "$expected_rc" "$CAPTURE_RC" "wait $timeout returns $expected_rc"
}

test_runner_exists() {
    if [ -x "$RUNNER" ]; then
        pass "POSIX runner exists and is executable"
    else
        fail "POSIX runner exists and is executable"
    fi
}

test_help_contract() {
    local value
    if [ ! -x "$RUNNER" ]; then
        fail "help lists the public contract"
        return
    fi
    run_captured "$RUNNER" --help
    assert_eq "0" "$CAPTURE_RC" "help succeeds"
    for value in check start status wait cancel cleanup \
        '--after-terminal' \
        claude-prompt codex-prompt codex-review \
        0 2 3 4 12 64 65 66 75 127; do
        assert_string_contains "$CAPTURE_OUTPUT" "$value" "help includes $value"
    done
}

test_check_profiles() {
    local profile
    for profile in claude-prompt codex-prompt codex-review; do
        run_captured "$RUNNER" check "$profile"
        assert_eq "0" "$CAPTURE_RC" "$profile passes capability preflight"
    done
}

assert_status_fields() {
    local run_dir="$1"
    local field
    run_captured "$RUNNER" status "$run_dir"
    assert_eq "0" "$CAPTURE_RC" "terminal status succeeds"
    for field in PROFILE PROVIDER STARTED_AT ELAPSED_SECONDS RESULT \
        REVIEWER_OUTPUT REVIEWER_LOG SUPERVISOR_OUTPUT SUPERVISOR_LOG \
        REVIEWER_PID EXIT_CODE COMPLETED_AT; do
        assert_string_contains "$CAPTURE_OUTPUT" "$field=" "status includes $field"
    done
}

test_normal_claude_run() {
    local expected="$TEST_TMP/expected-claude.json"
    local fake_log
    local prompt="$TEST_TMP/prompt.txt"
    local run_dir
    printf 'review this document\n' > "$prompt"
    printf '[{"type":"result","session_id":"fake","result":"fake Claude review"}]\n' > "$expected"
    start_run 0 claude-prompt 'document|project|spec' "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    assert_eq "$run_dir" "$(cat "$run_dir/run-path")" "printed run path is canonical metadata"
    wait_for_run "$run_dir" 10 0
    assert_eq "exited" "$(cat "$run_dir/state")" "normal Claude reaches exited"
    assert_eq "0" "$(cat "$run_dir/exit-code")" "normal Claude records exit zero"
    assert_file_eq "$expected" "$run_dir/result" "Claude native JSON is byte-for-byte retained"
    fake_log="$FAKE_LOG_DIR/claude-$(cat "$run_dir/provider-session")"
    assert_eq "review this document" "$(cat "$fake_log.stdin")" "prompt reaches Claude stdin"
    assert_eq "$TEST_TMP" "$(cat "$fake_log.pwd" 2>/dev/null || true)" \
        "Claude runs in the recorded working directory"
    assert_file_contains "$fake_log.args" '--safe-mode' "Claude safe mode reaches the CLI"
    assert_file_contains "$fake_log.args" '--permission-mode dontAsk' "Claude dontAsk reaches the CLI"
    assert_file_contains "$fake_log.args" '--output-format json' "Claude JSON output reaches the CLI"
    assert_file_contains "$fake_log.args" '--session-id' "Claude session ID reaches the CLI"
    assert_file_contains "$fake_log.args" 'Bash(git diff *)' "Claude Bash allow-list stays intact"
    assert_status_fields "$run_dir"
}

test_slow_claude_run() {
    local prompt="$TEST_TMP/slow-prompt.txt"
    local reviewer_pid
    local run_dir
    printf 'slow review\n' > "$prompt"
    export FAKE_REVIEW_DELAY=3
    start_run 0 claude-prompt 'slow|project|spec' "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    wait_for_run "$run_dir" 1 3
    assert_string_contains "$CAPTURE_OUTPUT" 'STATE=running' "slow wait reports running"
    reviewer_pid="$(cat "$run_dir/reviewer-pid")"
    if kill -0 "$reviewer_pid" 2>/dev/null; then
        pass "slow reviewer remains alive after timeout"
    else
        fail "slow reviewer remains alive after timeout"
    fi
    wait_for_run "$run_dir" 10 0
    unset FAKE_REVIEW_DELAY
}

test_nonzero_and_truncated_claude() {
    local expected="$TEST_TMP/truncated.json"
    local prompt="$TEST_TMP/failing-prompt.txt"
    local run_dir
    printf 'failing review\n' > "$prompt"
    export FAKE_REVIEW_EXIT=23 FAKE_RESULT_BEFORE_EXIT=1
    start_run 0 claude-prompt 'failure|project|spec' "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    wait_for_run "$run_dir" 10 0
    unset FAKE_REVIEW_EXIT FAKE_RESULT_BEFORE_EXIT
    assert_eq "exited" "$(cat "$run_dir/state")" "nonzero Claude is terminal"
    assert_eq "23" "$(cat "$run_dir/exit-code")" "exact nonzero Claude exit is retained"
    assert_file_contains "$run_dir/result" 'fake Claude partial review' "partial result coexists with failure"

    printf '{"type":"result","broken":' > "$expected"
    export FAKE_REVIEW_EXIT=7 FAKE_RESULT_BEFORE_EXIT=1 FAKE_CLAUDE_PARTIAL_FILE="$expected"
    start_run 0 claude-prompt 'truncated|project|spec' "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    wait_for_run "$run_dir" 10 0
    unset FAKE_REVIEW_EXIT FAKE_RESULT_BEFORE_EXIT FAKE_CLAUDE_PARTIAL_FILE
    assert_file_eq "$expected" "$run_dir/result" "truncated Claude JSON is retained byte-for-byte"
}

test_codex_prompt_run() {
    local fake_log
    local prompt="$TEST_TMP/codex prompt.txt"
    local run_dir
    local work_dir="$TEST_TMP/work dir"
    mkdir -p "$work_dir"
    printf 'review from a spaced path\n' > "$prompt"
    start_run 0 codex-prompt 'document|space project|plan' "$work_dir" "$prompt"
    run_dir="$LAST_RUN"
    wait_for_run "$run_dir" 10 0
    fake_log="$FAKE_LOG_DIR/codex-$(basename "$run_dir")"
    assert_eq "review from a spaced path" "$(cat "$fake_log.stdin")" "prompt reaches Codex stdin"
    assert_eq "$work_dir" "$(cat "$fake_log.pwd" 2>/dev/null || true)" \
        "Codex runs in the spaced working directory"
    assert_file_contains "$fake_log.args" 'exec - -s read-only' "Codex prompt uses read-only sandbox"
    assert_file_contains "$fake_log.args" '--skip-git-repo-check' "Codex prompt skips git check"
    assert_file_contains "$fake_log.args" "-o $run_dir/result" "Codex prompt uses per-run output"
}

test_codex_review_scopes() {
    local fake_log
    local fixture_sha='0123456789abcdef0123456789abcdef01234567'
    local run_dir
    start_run 0 codex-review 'code|project|uncommitted' "$TEST_TMP" uncommitted
    run_dir="$LAST_RUN"; wait_for_run "$run_dir" 10 0
    fake_log="$FAKE_LOG_DIR/codex-$(basename "$run_dir")"
    assert_file_contains "$fake_log.args" 'exec review --uncommitted --skip-git-repo-check' "uncommitted scope is exact"
    assert_file_not_contains "$fake_log.args" ' -s ' "Codex review has no sandbox flag"
    if [ ! -e "$fake_log.stdin" ]; then pass "Codex review has no stdin prompt"; else fail "Codex review has no stdin prompt"; fi
    if [ -f "$run_dir/scope-value" ] && [ ! -s "$run_dir/scope-value" ]; then
        pass "uncommitted scope value exists and is zero bytes"
    else
        fail "uncommitted scope value exists and is zero bytes"
    fi
    start_run 0 codex-review 'code|project|base' "$TEST_TMP" base main
    run_dir="$LAST_RUN"; wait_for_run "$run_dir" 10 0
    fake_log="$FAKE_LOG_DIR/codex-$(basename "$run_dir")"
    assert_file_contains "$fake_log.args" 'exec review --base main --skip-git-repo-check' "base main scope is exact"
    assert_file_not_contains "$fake_log.args" ' -s ' \
        "base review has no sandbox flag"
    if [ ! -e "$fake_log.stdin" ]; then
        pass "base review has no stdin prompt"
    else
        fail "base review has no stdin prompt"
    fi
    start_run 0 codex-review 'code|project|commit' "$TEST_TMP" commit "$fixture_sha"
    run_dir="$LAST_RUN"; wait_for_run "$run_dir" 10 0
    fake_log="$FAKE_LOG_DIR/codex-$(basename "$run_dir")"
    assert_file_contains "$fake_log.args" "exec review --commit $fixture_sha --skip-git-repo-check" "commit SHA scope is exact"
    assert_file_not_contains "$fake_log.args" ' -s ' \
        "commit review has no sandbox flag"
    if [ ! -e "$fake_log.stdin" ]; then
        pass "commit review has no stdin prompt"
    else
        fail "commit review has no stdin prompt"
    fi
}

test_invalid_invocations() {
    local prompt="$TEST_TMP/valid-prompt.txt"
    printf 'valid\n' > "$prompt"
    run_captured "$RUNNER" nonsense; assert_eq "64" "$CAPTURE_RC" "unknown operation is usage error"
    run_captured "$RUNNER" check; assert_eq "64" "$CAPTURE_RC" "check requires a profile"
    run_captured "$RUNNER" check unknown-profile; assert_eq "64" "$CAPTURE_RC" "unknown profile is usage error"
    run_captured "$RUNNER" start claude-prompt key "$TEST_TMP"; assert_eq "64" "$CAPTURE_RC" "prompt profile requires a prompt"
    run_captured "$RUNNER" start claude-prompt key "$TEST_TMP" "$TEST_TMP/missing"; assert_eq "64" "$CAPTURE_RC" "unreadable prompt is usage error"
    run_captured "$RUNNER" start codex-review key "$TEST_TMP" uncommitted value; assert_eq "64" "$CAPTURE_RC" "uncommitted rejects a value"
    run_captured "$RUNNER" start codex-review key "$TEST_TMP" base; assert_eq "64" "$CAPTURE_RC" "base requires a value"
    run_captured "$RUNNER" start codex-review key "$TEST_TMP" commit; assert_eq "64" "$CAPTURE_RC" "commit requires a value"
    run_captured "$RUNNER" start codex-review key "$TEST_TMP" base main "$prompt"; assert_eq "64" "$CAPTURE_RC" "Codex review rejects a prompt"
    run_captured "$RUNNER" wait "$TEST_TMP/no-run" 1; assert_eq "65" "$CAPTURE_RC" "wait rejects an unknown run"
    run_captured "$RUNNER" wait "$TEST_TMP/no-run" negative; assert_eq "64" "$CAPTURE_RC" "wait rejects a nonnumeric timeout"
}

test_symlink_root_and_cleanup() {
    local canonical_root="$TEST_TMP/canonical reviews"
    local linked_root="$TEST_TMP/linked-reviews"
    local prompt="$TEST_TMP/symlink-prompt.txt"
    local run_dir
    mkdir -p "$canonical_root"
    ln -s "$canonical_root" "$linked_root"
    printf 'symlink root review\n' > "$prompt"
    export SUPERARTES_REVIEW_TMPDIR="$linked_root"
    start_run 0 claude-prompt 'symlink|project|spec' "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    assert_string_contains "$run_dir" "$canonical_root/run-" "start prints canonical symlink-root path"
    run_captured "$RUNNER" status "$run_dir"; assert_eq "0" "$CAPTURE_RC" "status accepts canonical run under symlink root"
    run_captured "$RUNNER" wait "$run_dir" 10; assert_eq "0" "$CAPTURE_RC" "wait accepts canonical run under symlink root"
    run_captured "$RUNNER" cleanup "$run_dir"; assert_eq "0" "$CAPTURE_RC" "cleanup accepts canonical run under symlink root"
    if [ ! -e "$run_dir" ]; then pass "cleanup removes the one terminal run"; else fail "cleanup removes the one terminal run"; fi
    export SUPERARTES_REVIEW_TMPDIR="$TEST_TMP/reviews"
}

test_cleanup_preserves_unknown_evidence() {
    local prompt="$TEST_TMP/cleanup-evidence-prompt.txt"
    local run_dir
    printf 'cleanup evidence review\n' > "$prompt"
    start_run 0 claude-prompt 'cleanup-evidence|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    wait_for_run "$run_dir" 10 0
    printf 'keep this evidence\n' > "$run_dir/unknown-evidence"
    run_captured "$RUNNER" cleanup "$run_dir"
    assert_eq "66" "$CAPTURE_RC" \
        "cleanup refuses a run containing unknown evidence"
    if [ -f "$run_dir/unknown-evidence" ]; then
        pass "cleanup preserves unknown evidence"
    else
        fail "cleanup preserves unknown evidence"
    fi
}

test_supervisor_fallback_and_started_at() {
    local prompt="$TEST_TMP/fallback-prompt.txt"
    local run_dir
    printf 'fallback supervisor\n' > "$prompt"
    export SUPERARTES_REVIEW_NO_SETSID=1
    start_run 0 claude-prompt 'fallback|project|spec' "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    unset SUPERARTES_REVIEW_NO_SETSID
    if [ -s "$run_dir/reviewer-pid" ] && [ -s "$run_dir/reviewer-start" ] && [ -s "$run_dir/started-at" ]; then
        pass "started-at is published only with reviewer identity"
    else
        fail "started-at is published only with reviewer identity"
    fi
    wait_for_run "$run_dir" 10 0
    assert_file_contains "$run_dir/state" 'exited' "fallback supervisor completes handshake"
}

test_identity_failure_reaps_reviewer() {
    local prompt="$TEST_TMP/identity-failure-prompt.txt"
    local run_dir
    local found
    printf 'identity failure review\n' > "$prompt"
    export SUPERARTES_REVIEW_TEST_FORCE_IDENTITY_FAILURE=1
    start_run 0 claude-prompt 'identity-failure|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    unset SUPERARTES_REVIEW_TEST_FORCE_IDENTITY_FAILURE
    assert_eq "launch-failed" "$(cat "$run_dir/state")" \
        "identity failure records launch-failed"
    if [ ! -e "$run_dir/reviewer-pid" ] && \
        [ ! -e "$run_dir/reviewer-start" ]; then
        pass "identity failure does not fabricate reviewer metadata"
    else
        fail "identity failure does not fabricate reviewer metadata"
    fi
    found="$(pgrep -f "$TEST_TMP/bin/claude" || true)"
    assert_eq "" "$found" "identity failure reaps the stopped reviewer"
}

test_setup_delay_is_excluded_from_elapsed() {
    local timing_root="$TEST_TMP/timing-reviews"
    local prompt="$TEST_TMP/timing-prompt.txt"
    local observation="$TEST_TMP/timing-observation"
    local observer_pid
    local before
    local after
    local wall_elapsed
    local run_dir
    local recorded_elapsed
    printf 'timing review\n' > "$prompt"
    mkdir -p "$timing_root"

    (
        local candidate
        local attempt=0
        while [ "$attempt" -lt 100 ]; do
            for candidate in "$timing_root"/run-*; do
                [ -d "$candidate" ] || continue
                if [ -s "$candidate/supervisor-pid" ]; then
                    if [ ! -e "$candidate/reviewer-pid" ] && \
                        [ ! -e "$candidate/started-at" ]; then
                        printf 'observed\n' > "$observation"
                    fi
                    exit 0
                fi
            done
            sleep 0.05
            attempt=$((attempt + 1))
        done
    ) &
    observer_pid=$!

    before="$(date +%s)"
    run_captured env SUPERARTES_REVIEW_TMPDIR="$timing_root" \
        SUPERARTES_REVIEW_TEST_SETUP_DELAY=2 \
        "$RUNNER" start claude-prompt 'timing|project|spec' \
        "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "delayed supervisor start succeeds"
    run_dir="$(output_field RUN_DIR)"
    wait "$observer_pid"
    after="$(date +%s)"
    wall_elapsed=$((after - before))
    if [ -f "$observation" ]; then
        pass "started-at is absent during supervisor setup delay"
    else
        fail "started-at is absent during supervisor setup delay"
    fi

    run_captured env SUPERARTES_REVIEW_TMPDIR="$timing_root" \
        "$RUNNER" wait "$run_dir" 10
    assert_eq "0" "$CAPTURE_RC" "delayed supervisor reaches terminal state"
    run_captured env SUPERARTES_REVIEW_TMPDIR="$timing_root" \
        "$RUNNER" status "$run_dir"
    assert_eq "0" "$CAPTURE_RC" "delayed supervisor status succeeds"
    recorded_elapsed="$(output_field ELAPSED_SECONDS)"
    if [ "$wall_elapsed" -ge 2 ] && \
        [ "$recorded_elapsed" -lt "$wall_elapsed" ]; then
        pass "elapsed reviewer time excludes supervisor setup delay"
    else
        fail "elapsed reviewer time excludes supervisor setup delay"
    fi
}

test_cancel_validates_identity_and_group() {
    local prompt="$TEST_TMP/cancel-prompt.txt"
    local run_dir
    local reviewer_pid
    local reviewer_start
    local sentinel_pid
    local sentinel_pgid
    printf 'cancel review\n' > "$prompt"

    export FAKE_REVIEW_DELAY=10
    start_run 0 claude-prompt 'cancel-group|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    run_captured "$RUNNER" cancel "$run_dir"
    assert_eq "0" "$CAPTURE_RC" "validated reviewer group cancellation is accepted"
    wait_for_run "$run_dir" 10 0
    assert_eq "cancelled" "$(cat "$run_dir/state")" \
        "accepted group cancellation reaches cancelled"

    export FAKE_REVIEW_DELAY=2
    start_run 0 claude-prompt 'cancel-mismatch|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    reviewer_pid="$(cat "$run_dir/reviewer-pid")"
    reviewer_start="$(cat "$run_dir/reviewer-start")"
    printf 'forged identity\n' > "$run_dir/reviewer-start"
    run_captured "$RUNNER" cancel "$run_dir"
    assert_eq "4" "$CAPTURE_RC" "identity mismatch refuses cancellation"
    if [ ! -e "$run_dir/cancel-requested" ] && \
        kill -0 "$reviewer_pid" 2>/dev/null; then
        pass "identity mismatch neither marks nor signals reviewer"
    else
        fail "identity mismatch neither marks nor signals reviewer"
    fi
    printf '%s\n' "$reviewer_start" > "$run_dir/reviewer-start"
    wait_for_run "$run_dir" 10 0
    assert_eq "exited" "$(cat "$run_dir/state")" \
        "refused cancellation preserves natural exit state"

    export FAKE_REVIEW_DELAY=10
    start_run 0 claude-prompt 'cancel-pgid-mismatch|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    setsid sleep 20 &
    sentinel_pid=$!
    sleep 0.1
    sentinel_pgid="$(LC_ALL=C ps -o pgid= -p "$sentinel_pid" | tr -d '[:space:]')"
    printf '%s\n' "$sentinel_pgid" > "$run_dir/reviewer-pgid"
    run_captured "$RUNNER" cancel "$run_dir"
    assert_eq "0" "$CAPTURE_RC" "PGID mismatch uses safe PID-only cancellation"
    if kill -0 "$sentinel_pid" 2>/dev/null; then
        pass "PGID mismatch does not signal unrelated process group"
    else
        fail "PGID mismatch does not signal unrelated process group"
    fi
    wait_for_run "$run_dir" 10 0
    assert_eq "cancelled" "$(cat "$run_dir/state")" \
        "PID-only fallback reaches cancelled"
    kill -TERM "$sentinel_pid" 2>/dev/null || true
    set +e
    wait "$sentinel_pid" 2>/dev/null
    set -e
    unset FAKE_REVIEW_DELAY
}

test_removed_work_dir_causes_launch_failure() {
    local review_root="$TEST_TMP/removed-work-reviews"
    local work_dir="$TEST_TMP/removed work dir"
    local prompt="$TEST_TMP/removed-work-prompt.txt"
    local observer_pid
    local candidate
    local run_dir
    local fake_log
    mkdir -p "$review_root" "$work_dir"
    printf 'removed work directory review\n' > "$prompt"

    (
        local observed_run
        local attempt=0
        while [ "$attempt" -lt 100 ]; do
            for observed_run in "$review_root"/run-*; do
                [ -d "$observed_run" ] || continue
                if [ -s "$observed_run/supervisor-pid" ]; then
                    rmdir "$work_dir"
                    exit 0
                fi
            done
            sleep 0.05
            attempt=$((attempt + 1))
        done
        exit 1
    ) &
    observer_pid=$!

    run_captured env SUPERARTES_REVIEW_TMPDIR="$review_root" \
        SUPERARTES_REVIEW_TEST_SETUP_DELAY=2 \
        "$RUNNER" start claude-prompt 'removed-work|project|spec' \
        "$work_dir" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "removed working directory start is accepted"
    run_dir="$(output_field RUN_DIR)"
    wait "$observer_pid"
    assert_eq "launch-failed" "$(cat "$run_dir/state")" \
        "removed working directory records launch-failed"
    candidate="$(cat "$run_dir/provider-session")"
    fake_log="$FAKE_LOG_DIR/claude-$candidate"
    if [ ! -e "$fake_log.args" ]; then
        pass "removed working directory does not invoke reviewer"
    else
        fail "removed working directory does not invoke reviewer"
    fi
}

test_teardown_terminates_validated_run() {
    local prompt="$TEST_TMP/teardown-prompt.txt"
    local run_dir
    local reviewer_pid
    local reviewer_start
    local supervisor_pid
    local supervisor_start
    if ! declare -F terminate_test_run >/dev/null 2>&1; then
        fail "test teardown provides validated process termination"
        return
    fi

    printf 'teardown review\n' > "$prompt"
    export FAKE_REVIEW_DELAY=10
    start_run 0 claude-prompt 'teardown|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    reviewer_pid="$(cat "$run_dir/reviewer-pid")"
    reviewer_start="$(cat "$run_dir/reviewer-start")"
    supervisor_pid="$(cat "$run_dir/supervisor-pid")"
    supervisor_start="$(cat "$run_dir/supervisor-start")"
    terminate_test_run "$run_dir"
    if ! fixture_process_identity_matches "$reviewer_pid" "$reviewer_start" && \
        ! fixture_process_identity_matches "$supervisor_pid" "$supervisor_start"; then
        pass "test teardown terminates reviewer and supervisor identities"
    else
        fail "test teardown terminates reviewer and supervisor identities"
    fi
    unset FAKE_REVIEW_DELAY
}

test_no_live_fake_reviewers() {
    local found
    found="$(pgrep -f "$TEST_TMP/bin/claude|$TEST_TMP/bin/codex" || true)"
    assert_eq "" "$found" "no fake reviewer processes remain"
}

test_runner_exists
test_help_contract
if [ -x "$RUNNER" ]; then
    test_check_profiles
    test_normal_claude_run
    test_slow_claude_run
    test_nonzero_and_truncated_claude
    test_codex_prompt_run
    test_codex_review_scopes
    test_invalid_invocations
    test_cleanup_preserves_unknown_evidence
    test_symlink_root_and_cleanup
    test_supervisor_fallback_and_started_at
    test_identity_failure_reaps_reviewer
    test_setup_delay_is_excluded_from_elapsed
    test_cancel_validates_identity_and_group
    test_removed_work_dir_causes_launch_failure
    test_teardown_terminates_validated_run
    test_no_live_fake_reviewers
fi
finish_suite
