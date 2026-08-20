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

write_valid_run_identity_fixture() {
    local run_dir="$1"
    local run_id="$2"
    local review_key="$3"
    local state="$4"
    printf '%s\n' "$run_id" > "$run_dir/run-id"
    printf '%s\n' "$run_dir" > "$run_dir/run-path"
    printf 'superartes-external-review:%s\n' "$run_id" > "$run_dir/marker"
    printf '%s\n' "$state" > "$run_dir/state"
    # Match production publication order: review-key commits the fixture last.
    printf '%s\n' "$review_key" > "$run_dir/review-key"
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

test_signals_have_branch_local_final_identity_validation() {
    local selection_line
    local branch_line
    local group_validation_line
    local group_signal_line
    local pid_validation_line
    local pid_signal_line
    local diagnostic_line
    local kill_selection_line
    local kill_branch_line
    local group_kill_validation_line
    local group_kill_line
    local pid_kill_validation_line
    local pid_kill_line
    local kill_diagnostic_line
    selection_line="$(awk '/signal_group=1/ { print NR }' "$RUNNER")"
    branch_line="$(awk \
        '/if \[ "\$signal_group" -eq 1 \]; then/ { print NR; exit }' \
        "$RUNNER")"
    group_validation_line="$(awk \
        '/if \[ "\$signal_group" -eq 1 \]; then/ { branch=1; next } branch && /kill -TERM -- "-\$pid"/ { exit } branch && /if ! process_identity_matches "\$pid" "\$expected_start"/ { print NR; exit }' \
        "$RUNNER")"
    group_signal_line="$(awk '/kill -TERM -- "-\$pid"/ { print NR }' \
        "$RUNNER")"
    pid_validation_line="$(awk \
        '/if ! process_identity_matches "\$pid" "\$expected_start"/ { line=NR } /if ! kill -TERM "\$pid"/ { print line; exit }' \
        "$RUNNER")"
    pid_signal_line="$(awk '/if ! kill -TERM "\$pid"/ { print NR }' "$RUNNER")"
    diagnostic_line="$(awk '/Recorded\/current reviewer PGID/ { print NR }' \
        "$RUNNER")"
    kill_selection_line="$(awk '/kill_group=1/ { print NR; exit }' "$RUNNER")"
    kill_branch_line="$(awk \
        '/if \[ "\$kill_group" -eq 1 \]; then/ { print NR; exit }' \
        "$RUNNER")"
    group_kill_validation_line="$(awk \
        '/if \[ "\$kill_group" -eq 1 \]; then/ { branch=1; next } branch && /kill -KILL -- "-\$pid"/ { exit } branch && /if process_identity_matches "\$pid" "\$expected_start"/ { print NR; exit }' \
        "$RUNNER")"
    group_kill_line="$(awk '/kill -KILL -- "-\$pid"/ { print NR; exit }' \
        "$RUNNER")"
    pid_kill_validation_line="$(awk \
        '/if process_identity_matches "\$pid" "\$expected_start"/ { line=NR } /kill -KILL "\$pid"/ { print line; exit }' \
        "$RUNNER")"
    pid_kill_line="$(awk '/kill -KILL "\$pid"/ { print NR; exit }' "$RUNNER")"
    kill_diagnostic_line="$(awk \
        '/Reviewer PGID changed after TERM/ { print NR; exit }' "$RUNNER")"
    if [ -n "$selection_line" ] && [ -n "$branch_line" ] && \
        [ -n "$group_validation_line" ] && [ -n "$group_signal_line" ] && \
        [ "$selection_line" -lt "$branch_line" ] && \
        [ "$branch_line" -lt "$group_validation_line" ] && \
        [ "$group_validation_line" -lt "$group_signal_line" ]; then
        pass "group branch validates identity locally before TERM"
    else
        fail "group branch validates identity locally before TERM"
    fi
    if [ -n "$group_signal_line" ] && [ -n "$pid_validation_line" ] && \
        [ -n "$pid_signal_line" ] && [ -n "$diagnostic_line" ] && \
        [ "$group_signal_line" -lt "$pid_validation_line" ] && \
        [ "$pid_validation_line" -lt "$pid_signal_line" ] && \
        [ "$pid_signal_line" -lt "$diagnostic_line" ]; then
        pass "PID fallback branch validates identity locally before TERM and diagnostic"
    else
        fail "PID fallback branch validates identity locally before TERM and diagnostic"
    fi
    if [ -n "$kill_selection_line" ] && [ -n "$kill_branch_line" ] && \
        [ -n "$group_kill_validation_line" ] && [ -n "$group_kill_line" ] && \
        [ "$kill_selection_line" -lt "$kill_branch_line" ] && \
        [ "$kill_branch_line" -lt "$group_kill_validation_line" ] && \
        [ "$group_kill_validation_line" -lt "$group_kill_line" ]; then
        pass "group escalation validates identity locally before KILL"
    else
        fail "group escalation validates identity locally before KILL"
    fi
    if [ -n "$group_kill_line" ] && [ -n "$pid_kill_validation_line" ] && \
        [ -n "$pid_kill_line" ] && [ -n "$kill_diagnostic_line" ] && \
        [ "$group_kill_line" -lt "$pid_kill_validation_line" ] && \
        [ "$pid_kill_validation_line" -lt "$pid_kill_line" ] && \
        [ "$pid_kill_line" -lt "$kill_diagnostic_line" ]; then
        pass "PID fallback escalation validates identity locally before KILL and diagnostic"
    else
        fail "PID fallback escalation validates identity locally before KILL and diagnostic"
    fi
}

test_shared_contract_parity() {
    local contract="$TEST_DIR/contract.txt"
    local operations
    local profiles
    local artifacts
    local operation
    local profile
    local artifact
    local prompt="$TEST_TMP/contract-prompt.txt"
    local run_dir
    operations="$(sed -n 's/^operations=//p' "$contract")"
    profiles="$(sed -n 's/^profiles=//p' "$contract")"
    artifacts="$(sed -n 's/^artifacts=//p' "$contract")"
    assert_eq 'check,start,status,wait,cancel,cleanup' "$operations" \
        "Bash reads the shared operation contract"
    assert_eq 'claude-prompt,codex-prompt,codex-review' "$profiles" \
        "Bash reads the shared profile contract"

    run_captured "$RUNNER" --help
    assert_eq "0" "$CAPTURE_RC" \
        "Bash help succeeds for shared contract parity"
    for operation in $(printf '%s' "$operations" | tr ',' ' '); do
        assert_string_contains "$CAPTURE_OUTPUT" "$operation" \
            "Bash help advertises contract operation $operation"
    done
    for profile in $(printf '%s' "$profiles" | tr ',' ' '); do
        assert_string_contains "$CAPTURE_OUTPUT" "$profile" \
            "Bash help advertises contract profile $profile"
    done

    printf 'contract artifacts\n' > "$prompt"
    start_run 0 claude-prompt 'contract|artifacts' "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    wait_for_run "$run_dir" 10 0
    for artifact in $(printf '%s' "$artifacts" | tr ',' ' '); do
        case "$artifact" in
            scope-kind|scope-value|reviewer-output|previous-run|cancel-requested)
                pass "contract artifact $artifact is inapplicable to normal prompt run"
                ;;
            *)
                if [ -e "$run_dir/$artifact" ]; then
                    pass "contract artifact $artifact is retained when applicable"
                else
                    fail "contract artifact $artifact is retained when applicable"
                fi
                ;;
        esac
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
    local child_pid
    local child_start
    local fake_log
    local sentinel_pid
    local sentinel_pgid
    local cancel_output="$TEST_TMP/cancel-protocol.out"
    local cancel_rc_file="$TEST_TMP/cancel-protocol.rc"
    local cancel_pid
    printf 'cancel review\n' > "$prompt"

    export FAKE_REVIEW_DELAY=10 FAKE_SPAWN_CHILD=1
    start_run 0 claude-prompt 'cancel-group|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    reviewer_pid="$(cat "$run_dir/reviewer-pid")"
    reviewer_start="$(cat "$run_dir/reviewer-start")"
    assert_eq "$reviewer_pid" "$(cat "$run_dir/reviewer-pgid")" \
        "normal reviewer PGID equals reviewer PID"
    fake_log="$FAKE_LOG_DIR/claude-$(cat "$run_dir/provider-session")"
    if fixture_wait_for_file "$fake_log.child-pid"; then
        pass "fake reviewer child starts"
    else
        fail "fake reviewer child starts"
    fi
    child_pid="$(cat "$fake_log.child-pid")"
    child_start="$(cat "$fake_log.child-start")"
    (
        set +e
        SUPERARTES_REVIEW_TEST_CANCEL_ACCEPT_DELAY=2 \
            "$RUNNER" cancel "$run_dir" > "$cancel_output" 2>&1
        printf '%s\n' "$?" > "$cancel_rc_file"
    ) &
    cancel_pid=$!
    if fixture_wait_for_file_prefix "$run_dir/cancel-requested" pending; then
        pass "cancellation persists pending before signalling completes"
    else
        fail "cancellation persists pending before signalling completes"
    fi
    if fixture_wait_for_identity_loss "$reviewer_pid" "$reviewer_start"; then
        pass "TERM completes while cancellation marker is pending"
    else
        fail "TERM completes while cancellation marker is pending"
    fi
    run_captured "$RUNNER" cancel "$run_dir"
    assert_eq "12" "$CAPTURE_RC" \
        "concurrent cancellation attaches without entering signal protocol"
    assert_file_contains "$run_dir/cancel-requested" 'pending:' \
        "concurrent cancellation cannot overwrite pending evidence"
    assert_eq "running" "$(cat "$run_dir/state")" \
        "supervisor waits for pending cancellation classification"
    wait "$cancel_pid"
    assert_eq "0" "$(cat "$cancel_rc_file")" \
        "validated reviewer group cancellation adapter exit is recorded"
    wait_for_run "$run_dir" 10 0
    assert_eq "cancelled" "$(cat "$run_dir/state")" \
        "accepted group cancellation reaches cancelled"
    assert_eq "143" "$(cat "$run_dir/exit-code")" \
        "TERM cancellation records exact signal exit evidence"
    if fixture_wait_for_file_prefix "$run_dir/cancel-requested" accepted; then
        pass "accepted cancellation records accepted marker content"
    else
        fail "accepted cancellation records accepted marker content"
    fi
    if [ ! -e "$run_dir/.cancel-lock" ]; then
        pass "accepted cancellation releases its private lock"
    else
        fail "accepted cancellation releases its private lock"
    fi
    if fixture_wait_for_identity_loss "$reviewer_pid" "$reviewer_start"; then
        pass "cancelled reviewer identity is absent"
    else
        fail "cancelled reviewer identity is absent"
    fi
    if fixture_wait_for_identity_loss "$child_pid" "$child_start"; then
        pass "cancelled reviewer child identity is absent"
    else
        fail "cancelled reviewer child identity is absent"
    fi
    unset FAKE_SPAWN_CHILD

    export FAKE_REVIEW_DELAY=10
    start_run 0 claude-prompt 'cancel-mismatch|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    reviewer_pid="$(cat "$run_dir/reviewer-pid")"
    reviewer_start="$(cat "$run_dir/reviewer-start")"
    printf 'forged identity\n' > "$run_dir/reviewer-start"
    run_captured "$RUNNER" cancel "$run_dir"
    assert_eq "4" "$CAPTURE_RC" \
        "identity mismatch cancel adapter exit is recorded"
    assert_string_contains "$CAPTURE_OUTPUT" 'STATE=indeterminate' \
        "identity mismatch cancel output is indeterminate"
    assert_file_contains "$run_dir/cancel-requested" 'rejected:' \
        "identity mismatch records non-accepted cancellation evidence"
    if kill -0 "$reviewer_pid" 2>/dev/null; then
        pass "identity mismatch records evidence without signalling reviewer"
    else
        fail "identity mismatch records evidence without signalling reviewer"
    fi
    printf '%s\n' "$reviewer_start" > "$run_dir/reviewer-start"
    wait_for_run "$run_dir" 10 0
    assert_eq "exited" "$(cat "$run_dir/state")" \
        "refused cancellation preserves natural exit state"

    export FAKE_REVIEW_DELAY=2
    start_run 0 claude-prompt 'cancel-abandoned|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    printf 'pending:test-abandoned\n' > "$run_dir/cancel-requested"
    wait_for_run "$run_dir" 10 0
    assert_eq "exited" "$(cat "$run_dir/state")" \
        "unaccepted pending request cannot create false cancelled state"

    export FAKE_REVIEW_DELAY=10
    start_run 0 claude-prompt 'cancel-stale-lock|project|spec' \
        "$TEST_TMP" "$prompt"
    run_dir="$LAST_RUN"
    mkdir "$run_dir/.cancel-lock"
    printf '99999999\n' > "$run_dir/.cancel-lock/owner-pid"
    printf 'Mon Jan  1 00:00:00 2001\n' > \
        "$run_dir/.cancel-lock/owner-start"
    run_captured "$RUNNER" cancel "$run_dir"
    assert_eq "0" "$CAPTURE_RC" \
        "cancellation reclaims a crashed private lock owner"
    assert_file_contains "$run_dir/cancel-requested" 'accepted:' \
        "stale-lock recovery preserves accepted cancellation evidence"
    if [ ! -e "$run_dir/.cancel-lock" ]; then
        pass "stale cancellation lock is removed after accepted request"
    else
        fail "stale cancellation lock is removed after accepted request"
    fi
    wait_for_run "$run_dir" 10 0

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
    assert_file_contains "$run_dir/supervisor-log" \
        'signalling PID only' \
        "PGID mismatch records tree-wide cancellation diagnostic"
    kill -TERM "$sentinel_pid" 2>/dev/null || true
    set +e
    wait "$sentinel_pid" 2>/dev/null
    set -e
    unset FAKE_REVIEW_DELAY
}

test_status_identity_edge_cases() {
    local prompt="$TEST_TMP/status-edge-prompt.txt"
    local run_dir
    local reviewer_pid
    local reviewer_start
    local iteration=0
    printf 'status edge review\n' > "$prompt"

    run_captured env FAKE_REVIEW_DELAY=10 "$RUNNER" start \
        claude-prompt 'status|forged-start' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "forged-start fixture starts"
    run_dir="$(output_field RUN_DIR)"
    reviewer_pid="$(cat "$run_dir/reviewer-pid")"
    reviewer_start="$(cat "$run_dir/reviewer-start")"
    printf 'forged process start\n' > "$run_dir/reviewer-start"
    run_captured "$RUNNER" status "$run_dir"
    assert_eq "4" "$CAPTURE_RC" "forged reviewer start makes status indeterminate"
    assert_string_contains "$CAPTURE_OUTPUT" 'STATE=indeterminate' \
        "forged reviewer start reports indeterminate"
    if kill -0 "$reviewer_pid" 2>/dev/null; then
        pass "status identity failure sends no signal"
    else
        fail "status identity failure sends no signal"
    fi
    printf '%s\n' "$reviewer_start" > "$run_dir/reviewer-start"
    wait_for_run "$run_dir" 10 0

    run_captured env FAKE_REVIEW_DELAY=3 "$RUNNER" start \
        claude-prompt 'status|empty-result' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "empty-result fixture starts"
    run_dir="$(output_field RUN_DIR)"
    if [ -f "$run_dir/result" ] && [ ! -s "$run_dir/result" ]; then
        pass "live reviewer result is initially empty"
    else
        fail "live reviewer result is initially empty"
    fi
    run_captured "$RUNNER" status "$run_dir"
    assert_eq "3" "$CAPTURE_RC" "empty result with live reviewer stays running"
    assert_string_contains "$CAPTURE_OUTPUT" 'STATE=running' \
        "empty live result is not treated as failure"

    printf 'exited\n' > "$run_dir/state"
    run_captured "$RUNNER" status "$run_dir"
    assert_eq "0" "$CAPTURE_RC" "terminal metadata is trusted before PID liveness"
    assert_string_contains "$CAPTURE_OUTPUT" 'STATE=exited' \
        "terminal state cannot revert to running from live PID"
    printf 'running\n' > "$run_dir/state"
    wait_for_run "$run_dir" 10 0

    while [ "$iteration" -lt 5 ]; do
        run_captured "$RUNNER" start claude-prompt \
            "status|zero-delay|$iteration" "$TEST_TMP" "$prompt"
        assert_eq "0" "$CAPTURE_RC" "zero-delay fixture $iteration starts"
        run_dir="$(output_field RUN_DIR)"
        run_captured "$RUNNER" status "$run_dir"
        assert_one_of "0 3" "$CAPTURE_RC" \
            "zero-delay status $iteration is never indeterminate"
        wait_for_run "$run_dir" 10 0
        iteration=$((iteration + 1))
    done
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

test_duplicate_review_key() {
    local prompt="$TEST_TMP/duplicate-prompt.txt"
    local first
    printf 'review once\n' > "$prompt"

    run_captured env FAKE_REVIEW_DELAY=3 "$RUNNER" start \
        claude-prompt 'document|same' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "first matching review starts"
    first="$(output_field RUN_DIR)"

    run_captured "$RUNNER" start \
        claude-prompt 'document|same' "$TEST_TMP" "$prompt"
    assert_eq "12" "$CAPTURE_RC" "matching live review is refused"
    assert_string_contains "$CAPTURE_OUTPUT" "RUN_DIR=$first" \
        "matching live run is returned"
    wait_for_run "$first" 10 0

    run_captured "$RUNNER" start \
        claude-prompt 'document|same' "$TEST_TMP" "$prompt"
    assert_eq "12" "$CAPTURE_RC" "matching terminal review is retained"
    assert_string_contains "$CAPTURE_OUTPUT" "RUN_DIR=$first" \
        "terminal chain tail is returned"

    run_captured env FAKE_REVIEW_DELAY=3 "$RUNNER" start \
        --after-terminal "$first" \
        claude-prompt 'document|same' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "linked terminal attempt starts"
    LAST_RUN="$(output_field RUN_DIR)"
    assert_eq "$first" "$(cat "$LAST_RUN/previous-run" 2>/dev/null || true)" \
        "linked attempt records exact previous run"
    run_captured "$RUNNER" start \
        claude-prompt 'document|same' "$TEST_TMP" "$prompt"
    assert_eq "12" "$CAPTURE_RC" "unlinked third attempt is refused"
    assert_string_contains "$CAPTURE_OUTPUT" "RUN_DIR=$LAST_RUN" \
        "unlinked third attempt returns attempt two"
    if ! printf '%s\n' "$CAPTURE_OUTPUT" | grep -Fq -- "RUN_DIR=$first"; then
        pass "unlinked third attempt never returns attempt one"
    else
        fail "unlinked third attempt never returns attempt one"
    fi
    assert_eq "1" "$(pgrep -fc "$TEST_TMP/bin/claude" || true)" \
        "only one matching reviewer is live"
    wait_for_run "$LAST_RUN" 10 0

    run_captured "$RUNNER" start --after-terminal "$first" \
        claude-prompt 'document|same' "$TEST_TMP" "$prompt"
    assert_eq "4" "$CAPTURE_RC" \
        "linked attempt rejects an earlier non-tail run"
    run_captured "$RUNNER" start --after-terminal "$LAST_RUN" \
        claude-prompt 'document|different' "$TEST_TMP" "$prompt"
    assert_eq "4" "$CAPTURE_RC" \
        "linked attempt rejects a run with a different exact key"
}

test_chain_invariant_corruption() {
    local prompt="$TEST_TMP/corruption-prompt.txt"
    local live
    local extra="$SUPERARTES_REVIEW_TMPDIR/run-corrupt-live"
    local tail_one="$SUPERARTES_REVIEW_TMPDIR/run-corrupt-tail-one"
    local tail_two="$SUPERARTES_REVIEW_TMPDIR/run-corrupt-tail-two"
    printf 'corruption fixture\n' > "$prompt"

    run_captured env FAKE_REVIEW_DELAY=3 "$RUNNER" start \
        claude-prompt 'corruption|live' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "live corruption fixture starts"
    live="$(output_field RUN_DIR)"
    mkdir "$extra"
    write_valid_run_identity_fixture "$extra" corrupt-live \
        'corruption|live' running
    run_captured "$RUNNER" start claude-prompt 'corruption|live' \
        "$TEST_TMP" "$prompt"
    assert_eq "4" "$CAPTURE_RC" "multiple nonterminal matches are corruption"
    assert_string_contains "$CAPTURE_OUTPUT" "$live" \
        "corruption diagnostic lists real live run"
    assert_string_contains "$CAPTURE_OUTPUT" "$extra" \
        "corruption diagnostic lists extra live run"
    rm -f -- "$extra/review-key" "$extra/state" "$extra/run-id" \
        "$extra/run-path" "$extra/marker"
    rmdir "$extra"
    wait_for_run "$live" 10 0

    mkdir "$tail_one" "$tail_two"
    write_valid_run_identity_fixture "$tail_one" corrupt-tail-one \
        'corruption|tails' exited
    write_valid_run_identity_fixture "$tail_two" corrupt-tail-two \
        'corruption|tails' exited
    run_captured "$RUNNER" start claude-prompt 'corruption|tails' \
        "$TEST_TMP" "$prompt"
    assert_eq "4" "$CAPTURE_RC" "multiple terminal tails are corruption"
    assert_string_contains "$CAPTURE_OUTPUT" "$tail_one" \
        "multiple-tail diagnostic lists first tail"
    assert_string_contains "$CAPTURE_OUTPUT" "$tail_two" \
        "multiple-tail diagnostic lists second tail"
    printf '%s\n' "$tail_two" > "$tail_one/previous-run"
    printf '%s\n' "$tail_one" > "$tail_two/previous-run"
    run_captured "$RUNNER" start claude-prompt 'corruption|tails' \
        "$TEST_TMP" "$prompt"
    assert_eq "4" "$CAPTURE_RC" "zero terminal tails are corruption"
    assert_string_contains "$CAPTURE_OUTPUT" 'matching chain has 0 tails' \
        "zero-tail diagnostic prevents launch"
    rm -f -- "$tail_one/review-key" "$tail_one/state" \
        "$tail_one/previous-run" "$tail_two/review-key" \
        "$tail_two/state" "$tail_two/previous-run" \
        "$tail_one/run-id" "$tail_one/run-path" "$tail_one/marker" \
        "$tail_two/run-id" "$tail_two/run-path" "$tail_two/marker"
    rmdir "$tail_one" "$tail_two"
}

test_distinct_keys_run_concurrently() {
    local prompt="$TEST_TMP/concurrent-prompt.txt"
    local first
    local second
    printf 'concurrent reviews\n' > "$prompt"

    run_captured env FAKE_REVIEW_DELAY=3 "$RUNNER" start \
        claude-prompt 'concurrent|one' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "first distinct key starts"
    first="$(output_field RUN_DIR)"
    run_captured env FAKE_REVIEW_DELAY=3 "$RUNNER" start \
        claude-prompt 'concurrent|two' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "second distinct key starts concurrently"
    second="$(output_field RUN_DIR)"
    if [ "$(cat "$first/reviewer-pid")" != \
        "$(cat "$second/reviewer-pid")" ]; then
        pass "distinct keys have separate reviewer processes"
    else
        fail "distinct keys have separate reviewer processes"
    fi
    if [ "$(cat "$first/provider-session")" != \
        "$(cat "$second/provider-session")" ]; then
        pass "distinct keys have separate fake logs"
    else
        fail "distinct keys have separate fake logs"
    fi
    if [ ! -e "$SUPERARTES_REVIEW_TMPDIR/.registry-lock" ]; then
        pass "registry lock is released after metadata creation"
    else
        fail "registry lock is released after metadata creation"
    fi
    wait_for_run "$first" 10 0
    wait_for_run "$second" 10 0
}

test_registry_serializes_simultaneous_same_key() {
    local prompt="$TEST_TMP/simultaneous-prompt.txt"
    local output_one="$TEST_TMP/simultaneous-one.out"
    local output_two="$TEST_TMP/simultaneous-two.out"
    local rc_one_file="$TEST_TMP/simultaneous-one.rc"
    local rc_two_file="$TEST_TMP/simultaneous-two.rc"
    local launcher_one
    local launcher_two
    local rc_one
    local rc_two
    local successful_run
    local refused_run
    printf 'serialize exact key\n' > "$prompt"

    (
        set +e
        FAKE_REVIEW_DELAY=3 "$RUNNER" start claude-prompt \
            'concurrent|same-key' "$TEST_TMP" "$prompt" > "$output_one" 2>&1
        printf '%s\n' "$?" > "$rc_one_file"
    ) &
    launcher_one=$!
    (
        set +e
        FAKE_REVIEW_DELAY=3 "$RUNNER" start claude-prompt \
            'concurrent|same-key' "$TEST_TMP" "$prompt" > "$output_two" 2>&1
        printf '%s\n' "$?" > "$rc_two_file"
    ) &
    launcher_two=$!
    wait "$launcher_one"
    wait "$launcher_two"
    rc_one="$(cat "$rc_one_file")"
    rc_two="$(cat "$rc_two_file")"
    assert_one_of "0 12" "$rc_one" \
        "first simultaneous adapter exit is recorded and valid"
    assert_one_of "0 12" "$rc_two" \
        "second simultaneous adapter exit is recorded and valid"
    if { [ "$rc_one" = 0 ] && [ "$rc_two" = 12 ]; } || \
        { [ "$rc_one" = 12 ] && [ "$rc_two" = 0 ]; }; then
        pass "simultaneous same-key starts produce one launch and one refusal"
    else
        fail "simultaneous same-key starts produce one launch and one refusal"
    fi
    if [ "$rc_one" = 0 ]; then
        successful_run="$(sed -n 's/^RUN_DIR=//p' "$output_one")"
        refused_run="$(sed -n 's/^RUN_DIR=//p' "$output_two")"
    else
        successful_run="$(sed -n 's/^RUN_DIR=//p' "$output_two")"
        refused_run="$(sed -n 's/^RUN_DIR=//p' "$output_one")"
    fi
    assert_eq "$successful_run" "$refused_run" \
        "serialized refusal returns the sole launched run"
    wait_for_run "$successful_run" 10 0
}

test_registry_lock_recovery_and_malformed_refusal() {
    local lock_dir="$SUPERARTES_REVIEW_TMPDIR/.registry-lock"
    local prompt="$TEST_TMP/registry-prompt.txt"
    local run_dir
    local real_ps
    printf 'registry review\n' > "$prompt"

    mkdir "$lock_dir"
    printf '99999999\n' > "$lock_dir/owner-pid"
    printf 'Mon Jan  1 00:00:00 2001\n' > "$lock_dir/owner-start"
    run_captured "$RUNNER" start claude-prompt 'registry|dead-owner' \
        "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "dead registry owner is reclaimed"
    run_dir="$(output_field RUN_DIR)"
    wait_for_run "$run_dir" 10 0

    mkdir "$lock_dir"
    printf '%s\n' "$$" > "$lock_dir/owner-pid"
    printf 'forged start identity\n' > "$lock_dir/owner-start"
    run_captured "$RUNNER" start claude-prompt 'registry|reused-pid' \
        "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" \
        "registry owner with changed PID identity is reclaimed"
    run_dir="$(output_field RUN_DIR)"
    wait_for_run "$run_dir" 10 0

    mkdir "$lock_dir"
    printf '%s\n' "$$" > "$lock_dir/owner-pid"
    fixture_process_start_identity "$$" > "$lock_dir/owner-start"
    real_ps="$(command -v ps)"
    printf '%s\n' '#!/bin/sh' \
        'if [ "${SUPERARTES_REVIEW_TEST_IDENTITY_UNAVAILABLE_PID:-}" = "${4:-}" ] && [ "${2:-}" = "lstart=" ]; then exit 0; fi' \
        "exec '$real_ps' \"\$@\"" > "$TEST_TMP/bin/ps"
    chmod +x "$TEST_TMP/bin/ps"
    run_captured env SUPERARTES_REVIEW_TEST_IDENTITY_UNAVAILABLE_PID="$$" \
        "$RUNNER" start claude-prompt 'registry|live-unknown-identity' \
        "$TEST_TMP" "$prompt"
    assert_eq "75" "$CAPTURE_RC" \
        "live registry owner with unavailable identity is retained"
    if [ -f "$lock_dir/owner-pid" ]; then
        pass "unverifiable live registry lock is not reclaimed"
    else
        fail "unverifiable live registry lock is not reclaimed"
    fi
    rm -f -- "$TEST_TMP/bin/ps"
    rm -f -- "$lock_dir/owner-pid" "$lock_dir/owner-start"
    rmdir "$lock_dir" 2>/dev/null || true

    mkdir "$lock_dir"
    run_captured "$RUNNER" start claude-prompt 'registry|ownerless' \
        "$TEST_TMP" "$prompt"
    assert_eq "75" "$CAPTURE_RC" "ownerless registry lock is retained"
    assert_string_contains "$CAPTURE_OUTPUT" \
        "Registry lock owner metadata is missing or malformed: $lock_dir" \
        "ownerless lock prints exact manual diagnostic"
    assert_string_contains "$CAPTURE_OUTPUT" "rmdir -- '$lock_dir'" \
        "ownerless lock documents safe rmdir recovery"
    rmdir "$lock_dir"

    mkdir "$lock_dir"
    printf 'not-a-pid\n' > "$lock_dir/owner-pid"
    printf 'not-a-start-token\n' > "$lock_dir/owner-start"
    run_captured "$RUNNER" start claude-prompt 'registry|malformed' \
        "$TEST_TMP" "$prompt"
    assert_eq "75" "$CAPTURE_RC" "malformed registry lock is retained"
    assert_string_contains "$CAPTURE_OUTPUT" \
        "Registry lock owner metadata is missing or malformed: $lock_dir" \
        "malformed lock prints exact manual diagnostic"
    rm -f -- "$lock_dir/owner-pid" "$lock_dir/owner-start"
    rmdir "$lock_dir"
}

test_interrupted_metadata_before_review_key_is_ignored() {
    local prompt="$TEST_TMP/pre-commit-prompt.txt"
    local pause_file="$TEST_TMP/pre-review-key.pause"
    local output="$TEST_TMP/pre-review-key.out"
    local creator_pid
    local creator_rc
    local candidate
    local orphan=""
    local launched
    printf 'ignore uncommitted metadata\n' > "$prompt"

    env SUPERARTES_REVIEW_TEST_PRE_REVIEW_KEY_PAUSE_FILE="$pause_file" \
        "$RUNNER" start claude-prompt 'registry|uncommitted-metadata' \
        "$TEST_TMP" "$prompt" > "$output" 2>&1 &
    creator_pid=$!
    if fixture_wait_for_file "$pause_file"; then
        pass "creator pauses after complete metadata before review-key commit"
        kill -KILL "$creator_pid" 2>/dev/null || true
    else
        fail "creator pauses after complete metadata before review-key commit"
    fi
    set +e
    wait "$creator_pid" 2>/dev/null
    creator_rc=$?
    set -e
    assert_eq "137" "$creator_rc" \
        "pre-commit creator death is deterministic"

    for candidate in "$SUPERARTES_REVIEW_TMPDIR"/run-*; do
        [ -d "$candidate" ] || continue
        if [ -f "$candidate/run-id" ] && [ ! -e "$candidate/review-key" ]; then
            orphan="$candidate"
        fi
    done
    if [ -n "$orphan" ]; then
        pass "uncommitted orphan evidence is retained without review-key"
    else
        fail "uncommitted orphan evidence is retained without review-key"
        rm -f -- "$pause_file"
        return
    fi
    for candidate in marker run-path profile provider run-id \
        provider-session work-dir prompt; do
        if [ -e "$orphan/$candidate" ]; then
            pass "uncommitted orphan retains pre-commit metadata $candidate"
        else
            fail "uncommitted orphan retains pre-commit metadata $candidate"
        fi
    done
    rm -f -- "$pause_file"

    run_captured "$RUNNER" start claude-prompt \
        'registry|uncommitted-metadata' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" \
        "same-key start ignores uncommitted orphan without return 65"
    launched="$(output_field RUN_DIR)"
    if [ "$launched" != "$orphan" ]; then
        pass "same-key start launches a distinct committed run"
    else
        fail "same-key start launches a distinct committed run"
    fi
    if [ -d "$orphan" ] && [ ! -e "$orphan/review-key" ]; then
        pass "same-key start leaves uncommitted orphan evidence intact"
    else
        fail "same-key start leaves uncommitted orphan evidence intact"
    fi
    wait_for_run "$launched" 10 0
}

test_interrupted_prelaunch_run_is_reconciled() {
    local prompt="$TEST_TMP/prelaunch-prompt.txt"
    local pause_file="$TEST_TMP/prelaunch.pause"
    local output="$TEST_TMP/prelaunch.out"
    local creator_pid
    local creator_rc
    local candidate
    local abandoned=""
    printf 'repair interrupted launch\n' > "$prompt"

    env SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE="$pause_file" \
        "$RUNNER" start claude-prompt 'registry|abandoned-prelaunch' \
        "$TEST_TMP" "$prompt" > "$output" 2>&1 &
    creator_pid=$!
    if fixture_wait_for_file "$pause_file"; then
        pass "creator pauses after metadata before supervisor launch"
        kill -KILL "$creator_pid" 2>/dev/null || true
    else
        fail "creator pauses after metadata before supervisor launch"
    fi
    set +e
    wait "$creator_pid" 2>/dev/null
    creator_rc=$?
    set -e
    assert_eq "137" "$creator_rc" \
        "interrupted prelaunch adapter exit is recorded"
    rm -f -- "$pause_file"

    for candidate in "$SUPERARTES_REVIEW_TMPDIR"/run-*; do
        [ -d "$candidate" ] || continue
        if [ "$(cat "$candidate/review-key" 2>/dev/null || true)" = \
            'registry|abandoned-prelaunch' ]; then
            abandoned="$candidate"
        fi
    done
    if [ -n "$abandoned" ]; then
        pass "interrupted creator retains canonical run evidence"
    else
        fail "interrupted creator retains canonical run evidence"
        return
    fi

    run_captured "$RUNNER" start claude-prompt \
        'registry|abandoned-prelaunch' "$TEST_TMP" "$prompt"
    assert_eq "12" "$CAPTURE_RC" \
        "next start repairs abandoned prelaunch and returns terminal tail"
    assert_eq "$abandoned" "$(output_field RUN_DIR)" \
        "repaired abandoned run is the unique terminal tail"
    assert_eq "launch-failed" "$(cat "$abandoned/state" 2>/dev/null || true)" \
        "abandoned prelaunch is mechanically terminalized"
    assert_file_contains "$abandoned/supervisor-log" \
        'Reconciled abandoned pre-launch run after registry owner death' \
        "abandoned prelaunch repair records a diagnostic"

    run_captured "$RUNNER" start --after-terminal "$abandoned" \
        claude-prompt 'registry|abandoned-prelaunch' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" \
        "linked retry proceeds after abandoned prelaunch repair"
    wait_for_run "$(output_field RUN_DIR)" 10 0
}

test_launch_intent_guards_delayed_supervisor_publication() {
    local prompt="$TEST_TMP/delayed-publication-prompt.txt"
    local ready_file="$TEST_TMP/delayed-publication.ready"
    local original_output="$TEST_TMP/delayed-publication.out"
    local original_rc_file="$TEST_TMP/delayed-publication.rc"
    local creator_pid
    local original
    local supervisor_pid
    local supervisor_start
    local reviewer_count_before
    local reviewer_count
    printf 'guard delayed supervisor publication\n' > "$prompt"
    reviewer_count_before="$(find "$FAKE_LOG_DIR" -type f \
        -name 'claude-*.args' | wc -l | tr -d '[:space:]')"

    (
        set +e
        SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_DELAY=3 \
        SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_READY_FILE="$ready_file" \
        FAKE_REVIEW_DELAY=2 "$RUNNER" start claude-prompt \
            'registry|delayed-publication' "$TEST_TMP" "$prompt" \
            > "$original_output" 2>&1
        printf '%s\n' "$?" > "$original_rc_file"
    ) &
    creator_pid=$!
    if fixture_wait_for_file "$ready_file"; then
        pass "supervisor pauses after publishing ownership before registry"
    else
        fail "supervisor pauses after publishing ownership before registry"
    fi
    original="$(sed -n 's/^RUN_DIR=//p' "$original_output" | head -n 1)"
    if [ -z "$original" ]; then
        for original in "$SUPERARTES_REVIEW_TMPDIR"/run-*; do
            [ -d "$original" ] || continue
            if [ "$(cat "$original/review-key" 2>/dev/null || true)" = \
                'registry|delayed-publication' ]; then
                break
            fi
        done
    fi
    supervisor_pid="$(cat "$original/supervisor-pid" 2>/dev/null || true)"
    supervisor_start="$(cat "$original/supervisor-start" 2>/dev/null || true)"
    if [ -n "$supervisor_pid" ] && [ -n "$supervisor_start" ] && \
        fixture_process_identity_matches "$supervisor_pid" "$supervisor_start"; then
        pass "live supervisor identity is visible during pre-registry delay"
    else
        fail "live supervisor identity is visible during pre-registry delay"
    fi

    run_captured env SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS=2 \
        FAKE_REVIEW_DELAY=2 "$RUNNER" start claude-prompt \
        'registry|delayed-publication' "$TEST_TMP" "$prompt"
    assert_eq "12" "$CAPTURE_RC" \
        "competitor returns outstanding while live supervisor delays"
    assert_eq "$original" "$(output_field RUN_DIR)" \
        "live supervisor claim preserves the original run"
    wait "$creator_pid"
    assert_eq "0" "$(cat "$original_rc_file")" \
        "original creator observes supervisor readiness"
    wait_for_run "$original" 10 0
    reviewer_count="$(find "$FAKE_LOG_DIR" -type f \
        -name 'claude-*.args' | wc -l | tr -d '[:space:]')"
    assert_eq "$((reviewer_count_before + 1))" "$reviewer_count" \
        "delayed publication launches only one linked reviewer"
}

test_late_supervisor_cannot_resurrect_launch_failed_run() {
    local prompt="$TEST_TMP/late-supervisor-prompt.txt"
    local ready_file="$TEST_TMP/late-supervisor.ready"
    local original_output="$TEST_TMP/late-supervisor.out"
    local original_rc_file="$TEST_TMP/late-supervisor.rc"
    local creator_pid
    local candidate
    local original=""
    local retry
    local reviewer_count_before
    local reviewer_count
    printf 'prevent late supervisor resurrection\n' > "$prompt"
    reviewer_count_before="$(find "$FAKE_LOG_DIR" -type f \
        -name 'claude-*.args' | wc -l | tr -d '[:space:]')"

    (
        set +e
        SUPERARTES_REVIEW_TEST_SUPERVISOR_START_DELAY=4 \
        SUPERARTES_REVIEW_TEST_SUPERVISOR_START_READY_FILE="$ready_file" \
        FAKE_REVIEW_DELAY=1 "$RUNNER" start claude-prompt \
            'registry|late-supervisor' "$TEST_TMP" "$prompt" \
            > "$original_output" 2>&1
        printf '%s\n' "$?" > "$original_rc_file"
    ) &
    creator_pid=$!
    if fixture_wait_for_file "$ready_file"; then
        pass "late supervisor pauses before internal initialization"
    else
        fail "late supervisor pauses before internal initialization"
    fi
    fixture_wait_for_path_absence "$SUPERARTES_REVIEW_TMPDIR/.registry-lock" || \
        fail "original creator releases registry after supervisor spawn"
    for candidate in "$SUPERARTES_REVIEW_TMPDIR"/run-*; do
        [ -d "$candidate" ] || continue
        if [ "$(cat "$candidate/review-key" 2>/dev/null || true)" = \
            'registry|late-supervisor' ]; then
            original="$candidate"
        fi
    done
    if [ -n "$original" ]; then
        pass "late-supervisor original run is committed"
    else
        fail "late-supervisor original run is committed"
        return
    fi

    run_captured env SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS=1 \
        "$RUNNER" start claude-prompt 'registry|late-supervisor' \
        "$TEST_TMP" "$prompt"
    assert_eq "12" "$CAPTURE_RC" \
        "short guard returns terminalized original tail"
    assert_eq "$original" "$(output_field RUN_DIR)" \
        "short guard identifies the original run"
    assert_eq "launch-failed" \
        "$(cat "$original/state" 2>/dev/null || true)" \
        "reconciler terminalizes original before late supervisor wakes"

    run_captured env FAKE_REVIEW_DELAY=1 "$RUNNER" start \
        --after-terminal "$original" claude-prompt \
        'registry|late-supervisor' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" \
        "linked retry starts before late original supervisor wakes"
    retry="$(output_field RUN_DIR)"
    wait_for_run "$retry" 10 0
    wait "$creator_pid"
    assert_eq "0" "$(cat "$original_rc_file")" \
        "original creator exits after observing terminal evidence"

    # Give the delayed supervisor enough time to attempt stale publication,
    # independent of how quickly the linked retry completes.
    sleep 5
    assert_eq "launch-failed" \
        "$(cat "$original/state" 2>/dev/null || true)" \
        "late supervisor cannot rewrite original terminal state"
    if [ ! -e "$original/reviewer-pid" ]; then
        pass "late original supervisor launches no reviewer"
    else
        fail "late original supervisor launches no reviewer"
    fi
    if [ ! -e "$FAKE_LOG_DIR/claude-$(cat "$original/provider-session").args" ]; then
        pass "late original supervisor produces no reviewer invocation log"
    else
        fail "late original supervisor produces no reviewer invocation log"
    fi
    reviewer_count="$(find "$FAKE_LOG_DIR" -type f \
        -name 'claude-*.args' | wc -l | tr -d '[:space:]')"
    assert_eq "$((reviewer_count_before + 1))" "$reviewer_count" \
        "reconciled original plus linked retry launches exactly one reviewer"
}

test_interrupted_after_launch_intent_is_guarded() {
    local prompt="$TEST_TMP/post-intent-prompt.txt"
    local pause_file="$TEST_TMP/post-intent.pause"
    local output="$TEST_TMP/post-intent.out"
    local creator_pid
    local creator_rc
    local candidate
    local abandoned=""
    local retry
    local guard_line
    printf 'guard interrupted launch intent\n' > "$prompt"

    guard_line="$(grep -F \
        'SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS:-10' \
        "$RUNNER" || true)"
    if [ -n "$guard_line" ]; then
        pass "production supervisor publication guard defaults to 10 seconds"
    else
        fail "production supervisor publication guard defaults to 10 seconds"
    fi

    env SUPERARTES_REVIEW_TEST_POST_INTENT_PAUSE_FILE="$pause_file" \
        "$RUNNER" start claude-prompt 'registry|abandoned-intent' \
        "$TEST_TMP" "$prompt" > "$output" 2>&1 &
    creator_pid=$!
    if fixture_wait_for_file "$pause_file"; then
        pass "creator pauses after durable intent before supervisor spawn"
        kill -KILL "$creator_pid" 2>/dev/null || true
    else
        fail "creator pauses after durable intent before supervisor spawn"
    fi
    set +e
    wait "$creator_pid" 2>/dev/null
    creator_rc=$?
    set -e
    assert_eq "137" "$creator_rc" \
        "post-intent creator death is deterministic"
    rm -f -- "$pause_file"

    for candidate in "$SUPERARTES_REVIEW_TMPDIR"/run-*; do
        [ -d "$candidate" ] || continue
        if [ "$(cat "$candidate/review-key" 2>/dev/null || true)" = \
            'registry|abandoned-intent' ]; then
            abandoned="$candidate"
        fi
    done
    if [ -n "$abandoned" ] && [ -e "$abandoned/supervisor-output" ] && \
        [ -e "$abandoned/supervisor-log" ]; then
        pass "interrupted creator retains both launch-intent artifacts"
    else
        fail "interrupted creator retains both launch-intent artifacts"
        return
    fi

    run_captured env SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS=1 \
        "$RUNNER" start claude-prompt 'registry|abandoned-intent' \
        "$TEST_TMP" "$prompt"
    assert_eq "12" "$CAPTURE_RC" \
        "unlinked start returns guarded launch-failed tail"
    assert_eq "$abandoned" "$(output_field RUN_DIR)" \
        "guarded intent failure remains the unique tail"
    assert_eq "launch-failed" \
        "$(cat "$abandoned/state" 2>/dev/null || true)" \
        "intent without spawn is terminalized after guard"
    if [ -s "$abandoned/completed-at" ]; then
        pass "guard expiry records completion evidence"
    else
        fail "guard expiry records completion evidence"
    fi
    assert_file_contains "$abandoned/supervisor-log" \
        'Reconciled launch intent without supervisor publication' \
        "guard expiry records launch-failed diagnostic"

    run_captured "$RUNNER" start --after-terminal "$abandoned" \
        claude-prompt 'registry|abandoned-intent' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" \
        "linked retry proceeds after guarded intent failure"
    retry="$(output_field RUN_DIR)"
    wait_for_run "$retry" 10 0
}

test_dead_supervisor_is_indeterminate() {
    local prompt="$TEST_TMP/dead-supervisor-prompt.txt"
    local run_dir
    local supervisor_pid
    local supervisor_start
    local artifacts_before="$TEST_TMP/dead-supervisor-artifacts"
    local artifact_path
    local artifact_name
    printf 'preserve reviewer evidence\n' > "$prompt"

    run_captured env FAKE_REVIEW_DELAY=10 "$RUNNER" start \
        claude-prompt 'process|dead-supervisor' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "supervisor-loss fixture starts"
    run_dir="$(output_field RUN_DIR)"
    supervisor_pid="$(cat "$run_dir/supervisor-pid")"
    supervisor_start="$(cat "$run_dir/supervisor-start")"
    for artifact_path in "$run_dir"/*; do
        [ -e "$artifact_path" ] || continue
        basename "$artifact_path" >> "$artifacts_before"
    done
    fixture_terminate_process "$supervisor_pid" "$supervisor_start" 0

    run_captured "$RUNNER" status "$run_dir"
    assert_eq "4" "$CAPTURE_RC" "dead supervisor makes live run indeterminate"
    assert_string_contains "$CAPTURE_OUTPUT" 'STATE=indeterminate' \
        "dead supervisor status reports indeterminate"
    while IFS= read -r artifact_name; do
        if [ -e "$run_dir/$artifact_name" ]; then
            pass "supervisor loss preserves artifact $artifact_name"
        else
            fail "supervisor loss preserves artifact $artifact_name"
        fi
    done < "$artifacts_before"
    terminate_test_run "$run_dir"
}

test_adversarial_cleanup_contract() {
    local prompt="$TEST_TMP/adversarial-cleanup-prompt.txt"
    local running
    local terminal
    local sibling
    local linked="$SUPERARTES_REVIEW_TMPDIR/run-linked-cleanup"
    local copied="$SUPERARTES_REVIEW_TMPDIR/run-copied-cleanup"
    local outside="$TEST_TMP/run-outside-cleanup"
    local marker
    printf 'cleanup safely\n' > "$prompt"

    run_captured env FAKE_REVIEW_DELAY=5 "$RUNNER" start \
        claude-prompt 'cleanup|running' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "running cleanup fixture starts"
    running="$(output_field RUN_DIR)"
    run_captured "$RUNNER" cleanup "$running"
    assert_eq "66" "$CAPTURE_RC" "cleanup refuses running run"
    if [ -d "$running" ]; then
        pass "running cleanup refusal preserves evidence"
    else
        fail "running cleanup refusal preserves evidence"
    fi
    run_captured "$RUNNER" cancel "$running"
    assert_eq "0" "$CAPTURE_RC" "running cleanup fixture cancels"
    wait_for_run "$running" 10 0

    start_run 0 claude-prompt 'cleanup|terminal' "$TEST_TMP" "$prompt"
    terminal="$LAST_RUN"
    wait_for_run "$terminal" 10 0
    ln -s "$terminal" "$linked"
    run_captured "$RUNNER" cleanup "$linked"
    assert_eq "65" "$CAPTURE_RC" "cleanup rejects symlink to valid run"
    rm -f -- "$linked"

    cp -R -- "$terminal" "$copied"
    run_captured "$RUNNER" cleanup "$copied"
    assert_eq "65" "$CAPTURE_RC" \
        "cleanup rejects copied run with recorded path mismatch"
    rm -rf -- "$copied"

    cp -R -- "$terminal" "$outside"
    run_captured "$RUNNER" cleanup "$outside"
    assert_eq "65" "$CAPTURE_RC" "cleanup rejects directory outside review root"
    rm -rf -- "$outside"

    marker="$(cat "$terminal/marker")"
    printf 'wrong-marker\n' > "$terminal/marker"
    run_captured "$RUNNER" cleanup "$terminal"
    assert_eq "65" "$CAPTURE_RC" "cleanup rejects wrong marker token"
    printf '%s\n' "$marker" > "$terminal/marker"

    start_run 0 claude-prompt 'cleanup|sibling' "$TEST_TMP" "$prompt"
    sibling="$LAST_RUN"
    wait_for_run "$sibling" 10 0
    mkdir "$terminal/.cancel-lock"
    printf '99999999\n' > "$terminal/.cancel-lock/owner-pid"
    printf 'Mon Jan  1 00:00:00 2001\n' > \
        "$terminal/.cancel-lock/owner-start"
    run_captured "$RUNNER" cleanup "$terminal"
    assert_eq "0" "$CAPTURE_RC" \
        "terminal cleanup safely reclaims stale cancellation lock"
    assert_string_contains "$CAPTURE_OUTPUT" \
        "Reclaimed stale cancellation lock: $terminal/.cancel-lock" \
        "stale cancellation lock recovery is diagnosed"
    if [ ! -e "$terminal" ] && [ -d "$sibling" ]; then
        pass "terminal cleanup removes only target and preserves sibling"
    else
        fail "terminal cleanup removes only target and preserves sibling"
    fi
    run_captured "$RUNNER" cleanup "$sibling"
    assert_eq "0" "$CAPTURE_RC" "sibling can be cleaned independently"
}

run_detachment_case() {
    local fallback="$1"
    local label="$2"
    local prompt="$TEST_TMP/detachment-$label-prompt.txt"
    local launcher_input="$TEST_TMP/detachment-$label-launcher.stdin"
    local start_output="$TEST_TMP/detachment-$label-start.out"
    local ready="$TEST_TMP/detachment-$label-ready"
    local nested_pid_file="$TEST_TMP/detachment-$label-nested.pid"
    local nested_start_file="$TEST_TMP/detachment-$label-nested.start"
    local nested_pgid_file="$TEST_TMP/detachment-$label-nested.pgid"
    local nested_start_rc_file="$TEST_TMP/detachment-$label-start.rc"
    local nested_pid
    local nested_start
    local nested_pgid
    local runner_pgid
    local launcher_pid
    local run_dir
    local fake_log
    local supervisor_pid
    local supervisor_start
    local supervisor_pgid
    printf 'retained prompt for %s\n' "$label" > "$prompt"
    printf 'distinctive launcher stdin for %s\n' "$label" > "$launcher_input"

    env SUPERARTES_REVIEW_NO_SETSID="$fallback" FAKE_REVIEW_DELAY=3 \
        setsid bash -c '
            printf "%s\n" "$$" > "$7"
            { LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null || true; } | \
                sed "s/^[[:space:]]*//" > "$8"
            { LC_ALL=C ps -o pgid= -p "$$" 2>/dev/null || true; } | \
                tr -d "[:space:]" > "$9"
            set +e
            "$1" start claude-prompt "$2" "$3" "$4" > "$5" 2>&1
            start_rc=$?
            set -e
            printf "%s\n" "$start_rc" > "${10}"
            printf "ready\n" > "$6"
            sleep 30
        ' nested-launcher "$RUNNER" "detachment|$label" "$TEST_TMP" \
            "$prompt" "$start_output" "$ready" "$nested_pid_file" \
            "$nested_start_file" "$nested_pgid_file" \
            "$nested_start_rc_file" \
            < "$launcher_input" &
    launcher_pid=$!

    if fixture_wait_for_file "$ready"; then
        pass "$label nested launcher reaches signalling point"
    else
        fail "$label nested launcher reaches signalling point"
    fi
    nested_pid="$(cat "$nested_pid_file" 2>/dev/null || true)"
    nested_start="$(cat "$nested_start_file" 2>/dev/null || true)"
    nested_pgid="$(cat "$nested_pgid_file" 2>/dev/null || true)"
    runner_pgid="$(LC_ALL=C ps -o pgid= -p "$$" | tr -d '[:space:]')"
    run_dir="$(sed -n 's/^RUN_DIR=//p' "$start_output" | head -n 1)"
    assert_eq "0" "$(cat "$nested_start_rc_file" 2>/dev/null || true)" \
        "$label nested start adapter exit is recorded"
    supervisor_pid="$(cat "$run_dir/supervisor-pid" 2>/dev/null || true)"
    supervisor_start="$(cat "$run_dir/supervisor-start" 2>/dev/null || true)"
    supervisor_pgid="$({ LC_ALL=C ps -o pgid= -p "$supervisor_pid" \
        2>/dev/null || true; } | tr -d '[:space:]')"

    if [ -n "$nested_pgid" ] && [ "$nested_pgid" != "$runner_pgid" ]; then
        pass "$label nested PGID differs from test runner before signalling"
    else
        fail "$label nested PGID differs from test runner before signalling"
    fi
    if [ "$nested_pgid" = "$nested_pid" ] && \
        fixture_process_identity_matches "$nested_pid" "$nested_start"; then
        pass "$label nested process group identity is validated"
        if [ -n "$supervisor_pgid" ] && \
            [ "$supervisor_pgid" != "$nested_pgid" ] && \
            fixture_process_identity_matches \
                "$supervisor_pid" "$supervisor_start"; then
            pass "$label supervisor has an independent validated process group"
        else
            fail "$label supervisor has an independent validated process group"
        fi
        kill -HUP -- "-$nested_pgid"
    else
        fail "$label nested process group identity is validated"
        fixture_terminate_process "$launcher_pid" "$nested_start" 0 || true
    fi
    set +e
    wait "$launcher_pid" 2>/dev/null
    set -e

    run_captured "$RUNNER" wait "$run_dir" 10
    assert_eq "0" "$CAPTURE_RC" "$label detached reviewer reaches terminal state"
    assert_eq "exited" "$(cat "$run_dir/state" 2>/dev/null || true)" \
        "$label detached reviewer records exited"
    assert_eq "0" "$(cat "$run_dir/exit-code" 2>/dev/null || true)" \
        "$label detached reviewer records exit evidence"
    fake_log="$FAKE_LOG_DIR/claude-$(cat "$run_dir/provider-session")"
    assert_eq "retained prompt for $label" "$(cat "$fake_log.stdin")" \
        "$label reviewer receives only retained prompt"
    assert_file_not_contains "$fake_log.stdin" \
        "distinctive launcher stdin for $label" \
        "$label supervisor stdin stays detached"
}

test_supervisor_detachment() {
    run_detachment_case 0 setsid
    run_detachment_case 1 fallback
}

test_no_live_fake_reviewers() {
    local found
    found="$(pgrep -f "$TEST_TMP/bin/claude|$TEST_TMP/bin/codex" || true)"
    assert_eq "" "$found" "no fake reviewer processes remain"
}

test_runner_exists
test_help_contract
if [ -x "$RUNNER" ]; then
    test_signals_have_branch_local_final_identity_validation
    test_check_profiles
    test_shared_contract_parity
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
    test_status_identity_edge_cases
    test_removed_work_dir_causes_launch_failure
    test_duplicate_review_key
    test_chain_invariant_corruption
    test_distinct_keys_run_concurrently
    test_registry_serializes_simultaneous_same_key
    test_registry_lock_recovery_and_malformed_refusal
    test_interrupted_metadata_before_review_key_is_ignored
    test_interrupted_prelaunch_run_is_reconciled
    test_launch_intent_guards_delayed_supervisor_publication
    test_late_supervisor_cannot_resurrect_launch_failed_run
    test_interrupted_after_launch_intent_is_guarded
    test_dead_supervisor_is_indeterminate
    test_adversarial_cleanup_contract
    test_supervisor_detachment
    test_teardown_terminates_validated_run
    test_no_live_fake_reviewers
fi
finish_suite
