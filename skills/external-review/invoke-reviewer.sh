#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
if [ -n "${SUPERARTES_REVIEW_TMPDIR:-}" ]; then
    RAW_REVIEW_ROOT="$SUPERARTES_REVIEW_TMPDIR"
    mkdir -p "$RAW_REVIEW_ROOT" || exit 65
else
    RAW_REVIEW_ROOT="${TMPDIR:-/tmp}/superartes-external-review-$(id -u)"
    if [ -L "$RAW_REVIEW_ROOT" ]; then
        printf 'Default review root must not be a symlink: %s\n' \
            "$RAW_REVIEW_ROOT" >&2
        exit 65
    fi
    if [ ! -e "$RAW_REVIEW_ROOT" ]; then
        mkdir -m 700 "$RAW_REVIEW_ROOT" || exit 65
    fi
    if [ ! -d "$RAW_REVIEW_ROOT" ] || [ -L "$RAW_REVIEW_ROOT" ] || \
        [ ! -O "$RAW_REVIEW_ROOT" ]; then
        printf 'Default review root must be an owned ordinary directory: %s\n' \
            "$RAW_REVIEW_ROOT" >&2
        exit 65
    fi
    chmod 700 "$RAW_REVIEW_ROOT" || exit 65
fi
REVIEW_ROOT="$(cd "$RAW_REVIEW_ROOT" && pwd -P)" || exit 65
REVIEWER_PID=""
VALIDATED_RUN=""
REGISTRY_OWNED=0
REGISTRY_OWNER_PID=""
REGISTRY_OWNER_START=""
REGISTRY_OBSERVED_PID=""
REGISTRY_OBSERVED_START=""
CANCEL_LOCK_OWNED=0
CANCEL_LOCK_DIR=""
CANCEL_OWNER_PID=""
CANCEL_OWNER_START=""
CANCEL_OBSERVED_PID=""
CANCEL_OBSERVED_START=""

usage() {
    cat <<'USAGE'
Usage:
  invoke-reviewer.sh check <claude-prompt|codex-prompt|codex-review>
  invoke-reviewer.sh start [--after-terminal RUN] PROFILE REVIEW_KEY WORK_DIR PROFILE_ARGS...
  invoke-reviewer.sh start claude-prompt REVIEW_KEY WORK_DIR PROMPT_FILE
  invoke-reviewer.sh start codex-prompt REVIEW_KEY WORK_DIR PROMPT_FILE
  invoke-reviewer.sh start codex-review REVIEW_KEY WORK_DIR uncommitted
  invoke-reviewer.sh start codex-review REVIEW_KEY WORK_DIR base BASE_REF
  invoke-reviewer.sh start codex-review REVIEW_KEY WORK_DIR commit COMMIT_SHA
  invoke-reviewer.sh status RUN
  invoke-reviewer.sh wait RUN TIMEOUT_SECONDS
  invoke-reviewer.sh cancel RUN
  invoke-reviewer.sh cleanup RUN

Exit codes:
  0   terminal state or accepted operation
  2   required CLI capability missing
  3   reviewer still running
  4   lifecycle indeterminate; inspect evidence, do not retry immediately
  12  matching review remains outstanding; attach to printed RUN_DIR
  64  usage or invalid profile arguments
  65  invalid or unsafe run directory
  66  cleanup refused because artifacts remain
  75  registry lock unavailable
  127 reviewer CLI unavailable
USAGE
}

write_atomic() {
    local path="$1"
    local value="$2"
    local temporary="${path}.tmp.$$"
    printf '%s\n' "$value" > "$temporary"
    mv -f -- "$temporary" "$path"
}

copy_atomic() {
    local source="$1"
    local destination="$2"
    local temporary="${destination}.tmp.$$"
    cp -- "$source" "$temporary"
    mv -f -- "$temporary" "$destination"
}

write_empty_atomic() {
    local path="$1"
    local temporary="${path}.tmp.$$"
    : > "$temporary"
    mv -f -- "$temporary" "$path"
}

new_uuid() {
    local hex nibble variant
    hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    [ "${#hex}" -eq 32 ] || return 1
    nibble="$(printf '%s' "$hex" | cut -c17)"
    variant="$(printf '%x' "$(( (16#$nibble & 3) | 8 ))")"
    printf '%s-%s-4%s-%s%s-%s\n' \
        "$(printf '%s' "$hex" | cut -c1-8)" \
        "$(printf '%s' "$hex" | cut -c9-12)" \
        "$(printf '%s' "$hex" | cut -c14-16)" \
        "$variant" "$(printf '%s' "$hex" | cut -c18-20)" \
        "$(printf '%s' "$hex" | cut -c21-32)"
}

require_text() {
    local haystack="$1"
    local needle="$2"
    case "$haystack" in
        *"$needle"*) ;;
        *)
            printf 'Required capability missing: %s\n' "$needle" >&2
            return 2
            ;;
    esac
}

check_profile() {
    [ "$#" -eq 1 ] || return 64
    local profile="$1"
    local help
    local flag
    case "$profile" in
        claude-prompt)
            command -v claude >/dev/null 2>&1 || return 127
            claude --version >/dev/null 2>&1 || return 2
            help="$(claude --help)" || return 2
            for flag in --safe-mode --permission-mode --output-format \
                --session-id --tools --allowedTools; do
                require_text "$help" "$flag" || return $?
            done
            ;;
        codex-prompt)
            command -v codex >/dev/null 2>&1 || return 127
            codex --version >/dev/null 2>&1 || return 2
            help="$(codex exec --help)" || return 2
            for flag in --sandbox --skip-git-repo-check \
                --output-last-message; do
                require_text "$help" "$flag" || return $?
            done
            ;;
        codex-review)
            command -v codex >/dev/null 2>&1 || return 127
            codex --version >/dev/null 2>&1 || return 2
            help="$(codex exec review --help)" || return 2
            for flag in --uncommitted --base --commit \
                --skip-git-repo-check --output-last-message; do
                require_text "$help" "$flag" || return $?
            done
            ;;
        *)
            printf 'Unknown profile: %s\n' "$profile" >&2
            return 64
            ;;
    esac
}

canonical_review_root() {
    mkdir -p "$REVIEW_ROOT"
    (cd "$REVIEW_ROOT" && pwd -P)
}

validate_run() {
    [ "$#" -eq 1 ] || return 64
    local requested="$1"
    local canonical
    local root
    [ ! -L "$requested" ] || return 65
    canonical="$(cd "$requested" 2>/dev/null && pwd -P)" || return 65
    root="$(canonical_review_root)" || return 65
    case "$canonical" in
        "$root"/run-*) ;;
        *) return 65 ;;
    esac
    [ "$(cat "$canonical/run-path" 2>/dev/null)" = "$canonical" ] || return 65
    [ "$(cat "$canonical/marker" 2>/dev/null)" = \
        "superartes-external-review:$(cat "$canonical/run-id" 2>/dev/null)" ] || return 65
    VALIDATED_RUN="$canonical"
}

process_start_identity() {
    { LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null || true; } | \
        sed 's/^[[:space:]]*//'
}

process_group_id() {
    { LC_ALL=C ps -o pgid= -p "$1" 2>/dev/null || true; } | \
        tr -d '[:space:]'
}

registry_lock_is_ordinary() {
    local lock_dir="$REVIEW_ROOT/.registry-lock"
    [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ]
}

release_registry() {
    local lock_dir="$REVIEW_ROOT/.registry-lock"
    [ "$REGISTRY_OWNED" -eq 1 ] || return 0
    if registry_lock_is_ordinary && \
        [ -f "$lock_dir/owner-pid" ] && [ ! -L "$lock_dir/owner-pid" ] && \
        [ -f "$lock_dir/owner-start" ] && [ ! -L "$lock_dir/owner-start" ] && \
        [ "$(cat "$lock_dir/owner-pid" 2>/dev/null || true)" = \
        "$REGISTRY_OWNER_PID" ] && \
        [ "$(cat "$lock_dir/owner-start" 2>/dev/null || true)" = \
        "$REGISTRY_OWNER_START" ] && registry_lock_is_ordinary; then
        rm -f -- "$lock_dir/owner-pid" "$lock_dir/owner-start"
        rmdir -- "$lock_dir" 2>/dev/null || true
    fi
    REGISTRY_OWNED=0
}

registry_owner_metadata_valid() {
    local lock_dir="$REVIEW_ROOT/.registry-lock"
    registry_lock_is_ordinary || return 1
    [ -f "$lock_dir/owner-pid" ] && [ ! -L "$lock_dir/owner-pid" ] || \
        return 1
    [ -f "$lock_dir/owner-start" ] && [ ! -L "$lock_dir/owner-start" ] || \
        return 1
    REGISTRY_OBSERVED_PID="$(cat "$lock_dir/owner-pid" 2>/dev/null || true)"
    REGISTRY_OBSERVED_START="$(cat "$lock_dir/owner-start" 2>/dev/null || true)"
    case "$REGISTRY_OBSERVED_PID" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$REGISTRY_OBSERVED_PID" -gt 0 ] 2>/dev/null || return 1
    [ -n "$REGISTRY_OBSERVED_START" ]
}

registry_owner_is_dead() {
    local actual
    registry_owner_metadata_valid || return 1
    kill -0 "$REGISTRY_OBSERVED_PID" 2>/dev/null || return 0
    actual="$(process_start_identity "$REGISTRY_OBSERVED_PID")"
    [ -n "$actual" ] || return 1
    [ "$actual" != "$REGISTRY_OBSERVED_START" ]
}

reclaim_dead_registry() {
    local lock_dir="$REVIEW_ROOT/.registry-lock"
    local observed_pid="$REGISTRY_OBSERVED_PID"
    local observed_start="$REGISTRY_OBSERVED_START"
    registry_lock_is_ordinary || return 1
    [ -f "$lock_dir/owner-pid" ] && [ ! -L "$lock_dir/owner-pid" ] || \
        return 1
    [ -f "$lock_dir/owner-start" ] && [ ! -L "$lock_dir/owner-start" ] || \
        return 1
    [ "$(cat "$lock_dir/owner-pid" 2>/dev/null || true)" = \
        "$observed_pid" ] || return 1
    [ "$(cat "$lock_dir/owner-start" 2>/dev/null || true)" = \
        "$observed_start" ] || return 1
    registry_lock_is_ordinary || return 1
    rm -f -- "$lock_dir/owner-pid" "$lock_dir/owner-start"
    rmdir -- "$lock_dir" 2>/dev/null
}

print_registry_manual_recovery() {
    local lock_dir="$REVIEW_ROOT/.registry-lock"
    printf 'Registry lock owner metadata is missing or malformed: %s\n' \
        "$lock_dir" >&2
    printf 'Inspect owner-pid and owner-start. After proving no owner exists, remove only those files and run: rmdir -- '\''%s'\''\n' \
        "$lock_dir" >&2
}

acquire_registry() {
    local lock_dir="$REVIEW_ROOT/.registry-lock"
    local attempts=0
    REGISTRY_OWNER_PID="$$"
    REGISTRY_OWNER_START="$(process_start_identity "$$")"
    [ -n "$REGISTRY_OWNER_START" ] || return 75
    while ! mkdir "$lock_dir" 2>/dev/null; do
        if registry_owner_is_dead; then
            reclaim_dead_registry || true
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 100 ]; then
            if ! registry_owner_metadata_valid; then
                print_registry_manual_recovery
            else
                printf 'Registry lock unavailable: %s\n' "$lock_dir" >&2
            fi
            return 75
        fi
        sleep 0.01
    done
    registry_lock_is_ordinary || return 75
    REGISTRY_OWNED=1
    trap release_registry EXIT
    write_atomic "$lock_dir/owner-pid" "$REGISTRY_OWNER_PID"
    registry_lock_is_ordinary || return 75
    write_atomic "$lock_dir/owner-start" "$REGISTRY_OWNER_START"
    registry_lock_is_ordinary || return 75
}

cancel_lock_metadata_valid() {
    local lock_dir="$1"
    [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
    [ -f "$lock_dir/owner-pid" ] && [ ! -L "$lock_dir/owner-pid" ] || \
        return 1
    [ -f "$lock_dir/owner-start" ] && [ ! -L "$lock_dir/owner-start" ] || \
        return 1
    CANCEL_OBSERVED_PID="$(cat "$lock_dir/owner-pid" 2>/dev/null || true)"
    CANCEL_OBSERVED_START="$(cat "$lock_dir/owner-start" 2>/dev/null || true)"
    case "$CANCEL_OBSERVED_PID" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$CANCEL_OBSERVED_PID" -gt 0 ] 2>/dev/null || return 1
    [ -n "$CANCEL_OBSERVED_START" ]
}

cancel_lock_owner_is_dead() {
    local lock_dir="$1"
    local actual
    cancel_lock_metadata_valid "$lock_dir" || return 1
    kill -0 "$CANCEL_OBSERVED_PID" 2>/dev/null || return 0
    actual="$(process_start_identity "$CANCEL_OBSERVED_PID")"
    [ -n "$actual" ] || return 1
    [ "$actual" != "$CANCEL_OBSERVED_START" ]
}

reclaim_stale_cancel_lock() {
    local lock_dir="$1"
    local observed_pid="$CANCEL_OBSERVED_PID"
    local observed_start="$CANCEL_OBSERVED_START"
    [ "$(cat "$lock_dir/owner-pid" 2>/dev/null || true)" = \
        "$observed_pid" ] || return 1
    [ "$(cat "$lock_dir/owner-start" 2>/dev/null || true)" = \
        "$observed_start" ] || return 1
    rm -f -- "$lock_dir/owner-pid" "$lock_dir/owner-start"
    rmdir -- "$lock_dir" 2>/dev/null
}

release_cancel_lock() {
    [ "$CANCEL_LOCK_OWNED" -eq 1 ] || return 0
    if [ "$(cat "$CANCEL_LOCK_DIR/owner-pid" 2>/dev/null || true)" = \
        "$CANCEL_OWNER_PID" ] && \
        [ "$(cat "$CANCEL_LOCK_DIR/owner-start" 2>/dev/null || true)" = \
        "$CANCEL_OWNER_START" ]; then
        rm -f -- "$CANCEL_LOCK_DIR/owner-pid" \
            "$CANCEL_LOCK_DIR/owner-start"
        rmdir -- "$CANCEL_LOCK_DIR" 2>/dev/null || true
    fi
    CANCEL_LOCK_OWNED=0
}

acquire_cancel_lock() {
    local run_dir="$1"
    CANCEL_LOCK_DIR="$run_dir/.cancel-lock"
    CANCEL_OWNER_PID="$$"
    CANCEL_OWNER_START="$(process_start_identity "$$")"
    [ -n "$CANCEL_OWNER_START" ] || return 4
    if ! mkdir "$CANCEL_LOCK_DIR" 2>/dev/null; then
        if cancel_lock_owner_is_dead "$CANCEL_LOCK_DIR"; then
            reclaim_stale_cancel_lock "$CANCEL_LOCK_DIR" || true
        fi
        if ! mkdir "$CANCEL_LOCK_DIR" 2>/dev/null; then
            printf 'STATE=cancellation-requested\nRUN_DIR=%s\n' "$run_dir"
            return 12
        fi
    fi
    CANCEL_LOCK_OWNED=1
    trap release_cancel_lock EXIT
    write_atomic "$CANCEL_LOCK_DIR/owner-pid" "$CANCEL_OWNER_PID"
    write_atomic "$CANCEL_LOCK_DIR/owner-start" "$CANCEL_OWNER_START"
}

find_matching_runs() {
    local review_key="$1"
    local candidate
    for candidate in "$REVIEW_ROOT"/run-*; do
        [ -d "$candidate" ] || continue
        [ ! -L "$candidate" ] || continue
        [ -f "$candidate/review-key" ] && \
            [ ! -L "$candidate/review-key" ] || continue
        if [ "$(cat "$candidate/review-key" 2>/dev/null || true)" = \
            "$review_key" ]; then
            printf '%s\n' "$candidate"
        fi
    done
}

mark_abandoned_launch_failed() {
    local run_dir="$1"
    local diagnostic="$2"
    printf '%s\n' "$diagnostic" >> "$run_dir/supervisor-log"
    write_atomic "$run_dir/completed-at" "$(date +%s)"
    write_atomic "$run_dir/state" launch-failed
}

reconcile_abandoned_matching_runs() {
    local matching_runs="$1"
    local candidate
    local state
    local publication_guard_seconds
    local publication_guard_started
    publication_guard_seconds="${SUPERARTES_REVIEW_TEST_PUBLICATION_GUARD_SECONDS:-10}"
    case "$publication_guard_seconds" in
        ''|*[!0-9]*) publication_guard_seconds=10 ;;
    esac
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        validate_run "$candidate" || return $?
        state="$(read_artifact "$candidate/state")"
        [ -z "$state" ] || continue
        if supervisor_identity_matches "$candidate"; then
            continue
        fi
        if [ ! -f "$candidate/supervisor-output" ] || \
            [ -L "$candidate/supervisor-output" ] || \
            [ ! -f "$candidate/supervisor-log" ] || \
            [ -L "$candidate/supervisor-log" ]; then
            mark_abandoned_launch_failed "$candidate" \
                'Reconciled abandoned pre-launch run after registry owner death'
            continue
        fi

        # Both supervisor streams are durable launch intent. The creator may
        # have died after spawning a supervisor that has not yet published its
        # identity, so keep the registry and guard that publication window.
        publication_guard_started=$SECONDS
        while [ $((SECONDS - publication_guard_started)) -lt \
            "$publication_guard_seconds" ]; do
            state="$(read_artifact "$candidate/state")"
            [ -z "$state" ] || break
            if supervisor_identity_matches "$candidate"; then
                break
            fi
            sleep 0.1
        done
        state="$(read_artifact "$candidate/state")"
        [ -z "$state" ] || continue
        if supervisor_identity_matches "$candidate"; then
            continue
        fi
        mark_abandoned_launch_failed "$candidate" \
            'Reconciled launch intent without supervisor publication'
    done <<EOF
$matching_runs
EOF
}

reviewer_identity_matches() {
    local run_dir="$1"
    local pid
    local expected
    pid="$(cat "$run_dir/reviewer-pid" 2>/dev/null)" || return 1
    expected="$(cat "$run_dir/reviewer-start" 2>/dev/null)" || return 1
    process_identity_matches "$pid" "$expected"
}

process_identity_matches() {
    local pid="$1"
    local expected="$2"
    local actual
    kill -0 "$pid" 2>/dev/null || return 1
    actual="$(process_start_identity "$pid")"
    [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

supervisor_identity_matches() {
    local run_dir="$1"
    local pid
    local expected
    local actual
    pid="$(cat "$run_dir/supervisor-pid" 2>/dev/null)" || return 1
    expected="$(cat "$run_dir/supervisor-start" 2>/dev/null)" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    actual="$(process_start_identity "$pid")"
    [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

reviewer_gate() {
    # Stop the forked job before exec so even an instant reviewer has a stable
    # PID and start token for the supervisor to record. A new sh supplies the
    # real subprocess PID without relying on BASHPID, which is absent in some
    # Bash 3 installations.
    exec sh -c 'kill -STOP "$$"; exec "$@"' reviewer-gate "$@"
}

reap_reviewer() {
    local reviewer_pid="$1"
    REVIEWER_WAIT_EXIT=0
    while true; do
        set +e
        wait "$reviewer_pid"
        REVIEWER_WAIT_EXIT=$?
        set -e
        if ! kill -0 "$reviewer_pid" 2>/dev/null; then
            return 0
        fi
        # Bash job control may report the gate's stop event from wait even
        # after CONT was sent. Release it and wait for actual termination.
        kill -CONT "$reviewer_pid" 2>/dev/null || true
    done
}

run_profile() {
    local run_dir="$1"
    local profile
    local work_dir
    local session_id
    local scope_kind
    local scope_value
    profile="$(cat "$run_dir/profile")"
    work_dir="$(cat "$run_dir/work-dir")"
    session_id="$(cat "$run_dir/provider-session")"
    cd "$work_dir" || return $?
    set -m
    case "$profile" in
        claude-prompt)
            reviewer_gate claude -p --safe-mode --permission-mode dontAsk \
                --tools "Read,Glob,Grep,Bash" \
                --allowedTools "Read,Glob,Grep,Bash(git diff *),Bash(git status *),Bash(git rev-parse *),Bash(git cat-file *),Bash(git show *),Bash(git log *)" \
                --output-format json --session-id "$session_id" \
                < "$run_dir/prompt" > "$run_dir/result" \
                2> "$run_dir/reviewer-log" &
            ;;
        codex-prompt)
            reviewer_gate codex exec - -s read-only --skip-git-repo-check \
                -o "$run_dir/result" \
                < "$run_dir/prompt" > "$run_dir/reviewer-output" \
                2> "$run_dir/reviewer-log" &
            ;;
        codex-review)
            scope_kind="$(cat "$run_dir/scope-kind")"
            scope_value="$(cat "$run_dir/scope-value")"
            if [ "$scope_kind" = uncommitted ]; then
                reviewer_gate codex exec review --uncommitted \
                    --skip-git-repo-check \
                    -o "$run_dir/result" > "$run_dir/reviewer-output" \
                    2> "$run_dir/reviewer-log" &
            else
                reviewer_gate codex exec review \
                    "--$scope_kind" "$scope_value" \
                    --skip-git-repo-check -o "$run_dir/result" \
                    > "$run_dir/reviewer-output" \
                    2> "$run_dir/reviewer-log" &
            fi
            ;;
        *) return 64 ;;
    esac
    REVIEWER_PID=$!
}

supervise_run() {
    [ "$#" -eq 1 ] || return 64
    validate_run "$1" || return $?
    local run_dir="$VALIDATED_RUN"
    local supervisor_start
    local reviewer_start
    local reviewer_pgid
    local reviewer_exit
    local test_setup_delay
    local test_publication_delay
    local state
    local cancellation_value
    local cancellation_wait=0

    # Publish only this process's durable identity before any scheduling delay
    # or registry acquisition. A competing registry owner can then distinguish
    # a live supervisor from launch intent whose supervisor never started.
    supervisor_start="$(process_start_identity "$$")"
    if [ -z "$supervisor_start" ]; then
        printf 'Could not establish supervisor identity\n' >&2
        return 0
    fi
    write_atomic "$run_dir/supervisor-pid" "$$"
    write_atomic "$run_dir/supervisor-start" "$supervisor_start"

    # Deterministic test hook for the creator/supervisor publication race.
    test_publication_delay="${SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_DELAY:-0}"
    case "$test_publication_delay" in
        ''|*[!0-9]*) test_publication_delay=0 ;;
    esac
    if [ -n "${SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_READY_FILE:-}" ]; then
        write_atomic \
            "$SUPERARTES_REVIEW_TEST_SUPERVISOR_PUBLICATION_READY_FILE" "$$"
    fi
    if [ "$test_publication_delay" -gt 0 ]; then
        sleep "$test_publication_delay"
    fi

    # Fence supervisor ownership against registry reconciliation and linked
    # retry. The parent holds this registry through spawn, so a normally
    # scheduled supervisor waits until the launch command is complete.
    acquire_registry || return $?
    validate_run "$run_dir" || return $?
    run_dir="$VALIDATED_RUN"
    state="$(read_artifact "$run_dir/state")"
    if is_terminal_state "$state"; then
        release_registry
        trap - EXIT
        return 0
    fi

    # Deterministic test hook for proving setup time precedes reviewer timing.
    test_setup_delay="${SUPERARTES_REVIEW_TEST_SETUP_DELAY:-0}"
    case "$test_setup_delay" in
        ''|*[!0-9]*) test_setup_delay=0 ;;
    esac
    if [ "$test_setup_delay" -gt 0 ]; then
        sleep "$test_setup_delay"
    fi

    if ! run_profile "$run_dir"; then
        printf 'Could not launch reviewer profile\n' >&2
        write_atomic "$run_dir/completed-at" "$(date +%s)"
        write_atomic "$run_dir/state" launch-failed
        release_registry
        trap - EXIT
        return 0
    fi
    if [ "${SUPERARTES_REVIEW_TEST_FORCE_IDENTITY_FAILURE:-0}" -eq 1 ]; then
        reviewer_start=""
        reviewer_pgid=""
    else
        reviewer_start="$(process_start_identity "$REVIEWER_PID")"
        reviewer_pgid="$(process_group_id "$REVIEWER_PID")"
    fi
    if [ -z "$reviewer_start" ] || [ -z "$reviewer_pgid" ]; then
        printf 'Could not establish reviewer identity\n' >&2
        # The reviewer gate may still be stopped. Terminate, release, and reap
        # it before publishing failure so no untracked child survives.
        set +e
        kill -TERM "$REVIEWER_PID" 2>/dev/null
        kill -CONT "$REVIEWER_PID" 2>/dev/null
        set -e
        reap_reviewer "$REVIEWER_PID"
        write_atomic "$run_dir/completed-at" "$(date +%s)"
        write_atomic "$run_dir/state" launch-failed
        release_registry
        trap - EXIT
        return 0
    fi

    write_atomic "$run_dir/reviewer-pid" "$REVIEWER_PID"
    write_atomic "$run_dir/reviewer-start" "$reviewer_start"
    write_atomic "$run_dir/reviewer-pgid" "$reviewer_pgid"
    write_atomic "$run_dir/started-at" "$(date +%s)"
    write_atomic "$run_dir/state" running
    release_registry
    trap - EXIT
    kill -CONT "$REVIEWER_PID"

    reap_reviewer "$REVIEWER_PID"
    reviewer_exit="$REVIEWER_WAIT_EXIT"
    write_atomic "$run_dir/exit-code" "$reviewer_exit"
    write_atomic "$run_dir/completed-at" "$(date +%s)"
    cancellation_value="$(read_artifact "$run_dir/cancel-requested")"
    while [ "$cancellation_wait" -lt 30 ]; do
        case "$cancellation_value" in
            pending:*)
                sleep 0.1
                cancellation_value="$(read_artifact \
                    "$run_dir/cancel-requested")"
                cancellation_wait=$((cancellation_wait + 1))
                ;;
            *) break ;;
        esac
    done
    case "$cancellation_value" in
        accepted:*)
        write_atomic "$run_dir/state" cancelled
        ;;
        *)
            write_atomic "$run_dir/state" exited
            ;;
    esac
}

launch_supervisor() {
    local run_dir="$1"
    if [ "${SUPERARTES_REVIEW_NO_SETSID:-0}" -ne 1 ] && \
        command -v setsid >/dev/null 2>&1; then
        nohup setsid "$SCRIPT_PATH" _supervise "$run_dir" \
            </dev/null > "$run_dir/supervisor-output" \
            2> "$run_dir/supervisor-log" &
    else
        (
            set -m
            nohup "$SCRIPT_PATH" _supervise "$run_dir" \
                </dev/null > "$run_dir/supervisor-output" \
                2> "$run_dir/supervisor-log" &
        )
    fi
}

start_run() {
    [ "$#" -ge 1 ] || return 64
    local after_terminal=""
    if [ "${1:-}" = --after-terminal ]; then
        [ "$#" -ge 3 ] || return 64
        after_terminal="$2"
        shift 2
    fi
    local profile="$1"
    local review_key
    local requested_work_dir
    local work_dir
    local prompt_file=""
    local scope_kind=""
    local scope_value=""
    local provider
    local provider_session
    local run_id
    local run_dir
    local state
    local waited
    local matching_run
    local matching_runs
    local candidate
    local previous
    local nonterminal_count=0
    local nonterminal_run=""
    local tail_count=0
    local tail_run=""
    local named

    case "$profile" in
        claude-prompt|codex-prompt)
            [ "$#" -eq 4 ] || return 64
            review_key="$2"
            requested_work_dir="$3"
            prompt_file="$4"
            [ -f "$prompt_file" ] && [ -r "$prompt_file" ] || return 64
            ;;
        codex-review)
            [ "$#" -ge 4 ] || return 64
            review_key="$2"
            requested_work_dir="$3"
            scope_kind="$4"
            case "$scope_kind" in
                uncommitted)
                    [ "$#" -eq 4 ] || return 64
                    scope_value=""
                    ;;
                base|commit)
                    [ "$#" -eq 5 ] || return 64
                    scope_value="$5"
                    [ -n "$scope_value" ] || return 64
                    ;;
                *) return 64 ;;
            esac
            ;;
        *)
            printf 'Unknown profile: %s\n' "$profile" >&2
            return 64
            ;;
    esac
    [ -n "$review_key" ] || return 64
    [ -d "$requested_work_dir" ] || return 64
    work_dir="$(cd "$requested_work_dir" && pwd -P)" || return 64
    check_profile "$profile" || return $?

    case "$profile" in
        claude-prompt)
            provider=claude
            provider_session="$(new_uuid)"
            ;;
        *)
            provider=codex
            provider_session=not-applicable
            ;;
    esac
    run_id="$(new_uuid)"
    run_dir="$REVIEW_ROOT/run-$run_id"
    acquire_registry || return $?
    matching_runs="$(find_matching_runs "$review_key")"
    reconcile_abandoned_matching_runs "$matching_runs"
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        state="$(read_artifact "$candidate/state")"
        if ! is_terminal_state "$state"; then
            nonterminal_count=$((nonterminal_count + 1))
            nonterminal_run="$candidate"
        fi
    done <<EOF
$matching_runs
EOF
    if [ "$nonterminal_count" -gt 1 ]; then
        printf 'Invariant corruption: multiple nonterminal matching runs:\n%s\n' \
            "$matching_runs" >&2
        return 4
    fi
    if [ "$nonterminal_count" -eq 1 ]; then
        printf 'STATE=outstanding\nRUN_DIR=%s\n' "$nonterminal_run"
        return 12
    fi

    if [ -n "$matching_runs" ]; then
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            named=0
            while IFS= read -r matching_run; do
                [ -n "$matching_run" ] || continue
                previous="$(read_artifact "$matching_run/previous-run")"
                if [ "$previous" = "$candidate" ]; then
                    named=1
                    break
                fi
            done <<EOF
$matching_runs
EOF
            if [ "$named" -eq 0 ]; then
                tail_count=$((tail_count + 1))
                tail_run="$candidate"
            fi
        done <<EOF
$matching_runs
EOF
        if [ "$tail_count" -ne 1 ]; then
            printf 'Invariant corruption: matching chain has %s tails:\n%s\n' \
                "$tail_count" "$matching_runs" >&2
            return 4
        fi
        if [ -z "$after_terminal" ]; then
            printf 'STATE=outstanding\nRUN_DIR=%s\n' "$tail_run"
            return 12
        fi
        validate_run "$after_terminal" || return $?
        [ "$VALIDATED_RUN" = "$tail_run" ] || {
            printf 'Requested previous run is not the unique chain tail: %s\n' \
                "$tail_run" >&2
            return 4
        }
    elif [ -n "$after_terminal" ]; then
        printf 'No retained matching terminal run for --after-terminal\n' >&2
        return 4
    fi
    mkdir "$run_dir"
    run_dir="$(cd "$run_dir" && pwd -P)"

    write_atomic "$run_dir/run-id" "$run_id"
    write_atomic "$run_dir/run-path" "$run_dir"
    write_atomic "$run_dir/marker" "superartes-external-review:$run_id"
    write_atomic "$run_dir/profile" "$profile"
    write_atomic "$run_dir/provider" "$provider"
    write_atomic "$run_dir/provider-session" "$provider_session"
    write_atomic "$run_dir/work-dir" "$work_dir"
    if [ -n "$prompt_file" ]; then
        copy_atomic "$prompt_file" "$run_dir/prompt"
    else
        write_atomic "$run_dir/scope-kind" "$scope_kind"
        if [ "$scope_kind" = uncommitted ]; then
            write_empty_atomic "$run_dir/scope-value"
        else
            write_atomic "$run_dir/scope-value" "$scope_value"
        fi
    fi
    if [ -n "$after_terminal" ]; then
        write_atomic "$run_dir/previous-run" "$tail_run"
    fi

    if [ -n "${SUPERARTES_REVIEW_TEST_PRE_REVIEW_KEY_PAUSE_FILE:-}" ]; then
        write_atomic "$SUPERARTES_REVIEW_TEST_PRE_REVIEW_KEY_PAUSE_FILE" "$$"
        while [ -e "$SUPERARTES_REVIEW_TEST_PRE_REVIEW_KEY_PAUSE_FILE" ]; do
            sleep 0.05
        done
    fi
    # review-key is the atomic commit marker. Every artifact needed to
    # validate and execute this run is durable before the run becomes visible
    # to exact-key registry scans.
    write_atomic "$run_dir/review-key" "$review_key"

    if [ -n "${SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE:-}" ]; then
        write_atomic "$SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE" "$$"
        while [ -e "$SUPERARTES_REVIEW_TEST_PRELAUNCH_PAUSE_FILE" ]; do
            sleep 0.05
        done
    fi
    # The contracted supervisor streams double as durable launch intent. A
    # future registry owner must guard supervisor identity publication once
    # both exist instead of immediately declaring this committed run dead.
    write_empty_atomic "$run_dir/supervisor-output"
    write_empty_atomic "$run_dir/supervisor-log"
    if [ -n "${SUPERARTES_REVIEW_TEST_POST_INTENT_PAUSE_FILE:-}" ]; then
        write_atomic "$SUPERARTES_REVIEW_TEST_POST_INTENT_PAUSE_FILE" "$$"
        while [ -e "$SUPERARTES_REVIEW_TEST_POST_INTENT_PAUSE_FILE" ]; do
            sleep 0.05
        done
    fi
    launch_supervisor "$run_dir"
    release_registry
    trap - EXIT
    waited=0
    while [ "$waited" -lt 10 ]; do
        state="$(cat "$run_dir/state" 2>/dev/null || true)"
        case "$state" in
            running|exited|launch-failed|cancelled)
                printf 'STATE=%s\nRUN_DIR=%s\nRUN_ID=%s\n' \
                    "$state" "$run_dir" "$run_id"
                return 0
                ;;
        esac
        sleep 1
        waited=$((waited + 1))
    done

    if supervisor_identity_matches "$run_dir"; then
        printf 'STATE=indeterminate\nRUN_DIR=%s\n' "$run_dir"
        return 4
    fi
    printf 'Supervisor disappeared before publishing state\n' \
        >> "$run_dir/supervisor-log"
    write_atomic "$run_dir/completed-at" "$(date +%s)"
    write_atomic "$run_dir/state" launch-failed
    printf 'STATE=launch-failed\nRUN_DIR=%s\nRUN_ID=%s\n' \
        "$run_dir" "$run_id"
}

is_terminal_state() {
    case "$1" in
        exited|launch-failed|cancelled) return 0 ;;
        *) return 1 ;;
    esac
}

read_artifact() {
    local path="$1"
    if [ -f "$path" ]; then
        cat "$path"
    fi
}

print_status() {
    local run_dir="$1"
    local reported_state="$2"
    local started_at
    local completed_at
    local elapsed=0
    local elapsed_end
    started_at="$(read_artifact "$run_dir/started-at")"
    completed_at="$(read_artifact "$run_dir/completed-at")"
    if [ -n "$started_at" ]; then
        if [ -n "$completed_at" ]; then
            elapsed_end="$completed_at"
        else
            elapsed_end="$(date +%s)"
        fi
        if [ "$elapsed_end" -ge "$started_at" ] 2>/dev/null; then
            elapsed=$((elapsed_end - started_at))
        fi
    fi

    printf 'STATE=%s\n' "$reported_state"
    printf 'RUN_DIR=%s\n' "$run_dir"
    printf 'PROFILE=%s\n' "$(read_artifact "$run_dir/profile")"
    printf 'PROVIDER=%s\n' "$(read_artifact "$run_dir/provider")"
    printf 'STARTED_AT=%s\n' "$started_at"
    printf 'ELAPSED_SECONDS=%s\n' "$elapsed"
    printf 'RESULT=%s\n' "$run_dir/result"
    printf 'REVIEWER_OUTPUT=%s\n' "$run_dir/reviewer-output"
    printf 'REVIEWER_LOG=%s\n' "$run_dir/reviewer-log"
    printf 'SUPERVISOR_OUTPUT=%s\n' "$run_dir/supervisor-output"
    printf 'SUPERVISOR_LOG=%s\n' "$run_dir/supervisor-log"
    if [ -f "$run_dir/reviewer-pid" ]; then
        printf 'REVIEWER_PID=%s\n' "$(read_artifact "$run_dir/reviewer-pid")"
    fi
    if [ -f "$run_dir/exit-code" ]; then
        printf 'EXIT_CODE=%s\n' "$(read_artifact "$run_dir/exit-code")"
    fi
    if [ -f "$run_dir/completed-at" ]; then
        printf 'COMPLETED_AT=%s\n' "$completed_at"
    fi
}

status_run() {
    [ "$#" -eq 1 ] || return 64
    validate_run "$1" || return $?
    local run_dir="$VALIDATED_RUN"
    local state
    local grace=0
    state="$(read_artifact "$run_dir/state")"

    if is_terminal_state "$state"; then
        print_status "$run_dir" "$state"
        return 0
    fi
    if [ "$state" = running ] && reviewer_identity_matches "$run_dir" && \
        supervisor_identity_matches "$run_dir"; then
        print_status "$run_dir" running
        return 3
    fi
    if supervisor_identity_matches "$run_dir"; then
        while [ "$grace" -lt 4 ]; do
            sleep 1
            state="$(read_artifact "$run_dir/state")"
            if is_terminal_state "$state"; then
                print_status "$run_dir" "$state"
                return 0
            fi
            if [ "$state" = running ] && \
                reviewer_identity_matches "$run_dir" && \
                supervisor_identity_matches "$run_dir"; then
                print_status "$run_dir" running
                return 3
            fi
            grace=$((grace + 1))
        done
    fi
    print_status "$run_dir" indeterminate
    return 4
}

wait_run() {
    [ "$#" -eq 2 ] || return 64
    local requested_run="$1"
    local timeout="$2"
    local started=$SECONDS
    local run_dir
    local state
    local status_rc
    case "$timeout" in
        ''|*[!0-9]*) return 64 ;;
    esac
    validate_run "$requested_run" || return $?
    run_dir="$VALIDATED_RUN"

    while [ $((SECONDS - started)) -lt "$timeout" ]; do
        state="$(read_artifact "$run_dir/state")"
        if is_terminal_state "$state"; then
            status_run "$run_dir"
            return 0
        fi
        if ! reviewer_identity_matches "$run_dir" || \
            ! supervisor_identity_matches "$run_dir"; then
            set +e
            status_run "$run_dir"
            status_rc=$?
            set -e
            return "$status_rc"
        fi
        sleep 1
    done
    set +e
    status_run "$run_dir"
    status_rc=$?
    set -e
    return "$status_rc"
}

cancel_run() {
    [ "$#" -eq 1 ] || return 64
    validate_run "$1" || return $?
    local run_dir="$VALIDATED_RUN"
    local state
    local pid
    local expected_start
    local pgid
    local actual_pgid
    local attempt=0
    local pending_delay
    local accept_delay
    local cancellation_value
    acquire_cancel_lock "$run_dir" || return $?
    state="$(read_artifact "$run_dir/state")"
    if is_terminal_state "$state"; then
        print_status "$run_dir" "$state"
        return 0
    fi
    cancellation_value="$(read_artifact "$run_dir/cancel-requested")"
    case "$cancellation_value" in
        accepted:*)
            printf 'STATE=cancellation-requested\nRUN_DIR=%s\n' "$run_dir"
            return 0
            ;;
    esac
    pid="$(read_artifact "$run_dir/reviewer-pid")"
    expected_start="$(read_artifact "$run_dir/reviewer-start")"
    pgid="$(read_artifact "$run_dir/reviewer-pgid")"
    write_atomic "$run_dir/cancel-requested" \
        "pending:$(date +%s)"

    # Deterministic test hook proving pending evidence precedes the final
    # process-identity validation. Invalid values deliberately disable it.
    pending_delay="${SUPERARTES_REVIEW_TEST_CANCEL_PENDING_DELAY:-0}"
    case "$pending_delay" in
        ''|*[!0-9]*) pending_delay=0 ;;
    esac
    if [ "$pending_delay" -gt 0 ]; then
        sleep "$pending_delay"
    fi

    if [ -z "$pid" ] || [ -z "$expected_start" ] || \
        ! process_identity_matches "$pid" "$expected_start"; then
        write_atomic "$run_dir/cancel-requested" \
            "rejected:identity-mismatch:$(date +%s)"
        print_status "$run_dir" indeterminate
        return 4
    fi
    actual_pgid="$(process_group_id "$pid")"
    if [ "$pgid" != "$pid" ] || [ "$actual_pgid" != "$pid" ]; then
        write_atomic "$run_dir/cancel-requested" \
            "rejected:pgid-mismatch:$(date +%s)"
        printf 'Recorded/current reviewer PGID %s/%s does not match validated PID %s; refusing to signal an incomplete tree\n' \
            "$pgid" "$actual_pgid" "$pid" >> "$run_dir/supervisor-log"
        print_status "$run_dir" indeterminate
        return 4
    fi
    # Keep the final identity check immediately adjacent to the signal for
    # this exact, fully validated process-group target.
    if ! process_identity_matches "$pid" "$expected_start"; then
        write_atomic "$run_dir/cancel-requested" \
            "rejected:identity-mismatch:$(date +%s)"
        print_status "$run_dir" indeterminate
        return 4
    fi
    if ! kill -TERM -- "-$pid" 2>/dev/null; then
        write_atomic "$run_dir/cancel-requested" \
            "rejected:signal-failed:$(date +%s)"
        print_status "$run_dir" indeterminate
        return 4
    fi

    # Deterministic test hook for the reviewer-exit race between TERM and
    # accepted publication. The supervisor boundedly waits on pending.
    accept_delay="${SUPERARTES_REVIEW_TEST_CANCEL_ACCEPT_DELAY:-0}"
    case "$accept_delay" in
        ''|*[!0-9]*) accept_delay=0 ;;
    esac
    if [ "$accept_delay" -gt 0 ]; then
        sleep "$accept_delay"
    fi
    write_atomic "$run_dir/cancel-requested" \
        "accepted:$(date +%s)"

    while [ "$attempt" -lt 3 ]; do
        sleep 1
        if ! process_identity_matches "$pid" "$expected_start"; then
            printf 'STATE=cancellation-requested\nRUN_DIR=%s\n' "$run_dir"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    actual_pgid="$(process_group_id "$pid")"
    if [ "$actual_pgid" = "$pid" ]; then
        if process_identity_matches "$pid" "$expected_start"; then
            kill -KILL -- "-$pid" 2>/dev/null || true
        fi
    elif process_identity_matches "$pid" "$expected_start"; then
        printf 'Reviewer PGID changed after TERM; refusing PID-only escalation for incomplete tree %s\n' \
            "$pid" >> "$run_dir/supervisor-log"
    fi
    printf 'STATE=cancellation-requested\nRUN_DIR=%s\n' "$run_dir"
}

prepare_cancel_lock_for_cleanup() {
    local run_dir="$1"
    local lock_dir="$run_dir/.cancel-lock"
    [ -e "$lock_dir" ] || [ -L "$lock_dir" ] || return 0
    if cancel_lock_owner_is_dead "$lock_dir" && \
        reclaim_stale_cancel_lock "$lock_dir"; then
        printf 'Reclaimed stale cancellation lock: %s\n' "$lock_dir" >&2
        return 0
    fi
    printf 'Cleanup refused: cancellation lock is live, unverifiable, or malformed: %s\n' \
        "$lock_dir" >&2
    return 66
}

is_known_cleanup_artifact() {
    case "$1" in
        marker|run-path|review-key|profile|provider|run-id|\
        provider-session|work-dir|scope-kind|scope-value|state|started-at|\
        completed-at|supervisor-pid|supervisor-start|reviewer-pid|\
        reviewer-start|reviewer-pgid|exit-code|prompt|result|\
        reviewer-output|reviewer-log|supervisor-output|supervisor-log|\
        previous-run|cancel-requested)
            return 0
            ;;
    esac
    return 1
}

preflight_cancel_lock_for_cleanup() {
    local lock_dir="$1"
    local path
    local name
    [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 66
    for path in "$lock_dir"/* "$lock_dir"/.[!.]* "$lock_dir"/..?*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        name="${path##*/}"
        case "$name" in
            owner-pid|owner-start)
                [ -f "$path" ] && [ ! -L "$path" ] || return 66
                ;;
            *) return 66 ;;
        esac
    done
    [ -f "$lock_dir/owner-pid" ] && [ ! -L "$lock_dir/owner-pid" ] || return 66
    [ -f "$lock_dir/owner-start" ] && [ ! -L "$lock_dir/owner-start" ] || return 66
    cancel_lock_owner_is_dead "$lock_dir" || return 66
}

preflight_cleanup_run() {
    local run_dir="$1"
    local path
    local name
    for path in "$run_dir"/* "$run_dir"/.[!.]* "$run_dir"/..?*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        name="${path##*/}"
        if [ "$name" = '.cancel-lock' ]; then
            preflight_cancel_lock_for_cleanup "$path" || return $?
        elif is_known_cleanup_artifact "$name"; then
            [ -f "$path" ] && [ ! -L "$path" ] || return 66
        else
            return 66
        fi
    done
}

cleanup_run() {
    [ "$#" -eq 1 ] || return 64
    validate_run "$1" || return $?
    local run_dir="$VALIDATED_RUN"
    local state
    local artifact
    local path
    state="$(read_artifact "$run_dir/state")"
    is_terminal_state "$state" || return 66
    reviewer_identity_matches "$run_dir" && return 66
    supervisor_identity_matches "$run_dir" && return 66
    preflight_cleanup_run "$run_dir" || return $?
    prepare_cancel_lock_for_cleanup "$run_dir" || return $?
    for artifact in marker run-path review-key profile provider run-id \
        provider-session work-dir scope-kind scope-value state started-at \
        completed-at supervisor-pid supervisor-start reviewer-pid \
        reviewer-start reviewer-pgid exit-code prompt result \
        reviewer-output reviewer-log supervisor-output supervisor-log \
        previous-run cancel-requested; do
        path="$run_dir/$artifact"
        if [ -d "$path" ] && [ ! -L "$path" ]; then
            return 66
        fi
        rm -f -- "$path" || return 66
    done
    rmdir -- "$run_dir" 2>/dev/null || return 66
    printf 'STATE=cleaned\nRUN_DIR=%s\n' "$run_dir"
}

supervisor_entry() {
    local test_start_delay
    test_start_delay="${SUPERARTES_REVIEW_TEST_SUPERVISOR_START_DELAY:-0}"
    case "$test_start_delay" in
        ''|*[!0-9]*) test_start_delay=0 ;;
    esac
    if [ -n "${SUPERARTES_REVIEW_TEST_SUPERVISOR_START_READY_FILE:-}" ]; then
        write_atomic "$SUPERARTES_REVIEW_TEST_SUPERVISOR_START_READY_FILE" "$$"
    fi
    if [ "$test_start_delay" -gt 0 ]; then
        sleep "$test_start_delay"
    fi
    supervise_run "$@"
}

case "${1:---help}" in
    --help|-h) usage ;;
    check) shift; check_profile "$@" ;;
    start) shift; start_run "$@" ;;
    status) shift; status_run "$@" ;;
    wait) shift; wait_run "$@" ;;
    cancel) shift; cancel_run "$@" ;;
    cleanup) shift; cleanup_run "$@" ;;
    _supervise) shift; supervisor_entry "$@" ;;
    *) usage >&2; exit 64 ;;
esac
