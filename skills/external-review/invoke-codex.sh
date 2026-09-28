#!/usr/bin/env bash
#
# invoke-codex.sh — run a Codex review in the background for a Claude Code controller.
#
# Claude Code does not kill background descendants when a Bash tool call ends, so a
# review that outlives the tool's 600-second cap only needs to be detached. It needs
# no supervisor, no PID identity checks and no lock registry.
#
# Completion is signalled by the `exit-code` file appearing in the run directory.
# That file is written last and published atomically with mv(1), so its presence
# always means "finished" and its contents are never half-written. Its ABSENCE is
# weaker evidence: it means completion was not recorded, which covers a running
# reviewer, a failed launch, and a killed wrapper alike. Inspect `launch-err`.
#
# Commands:
#   invoke-codex.sh start prompt <work-dir> <prompt-file>
#   invoke-codex.sh start review <work-dir> uncommitted
#   invoke-codex.sh start review <work-dir> base   <base-ref>
#   invoke-codex.sh start review <work-dir> commit <commit-sha>
#   invoke-codex.sh status  <run-dir>
#   invoke-codex.sh wait    <run-dir> <timeout-seconds>
#   invoke-codex.sh discard <run-dir> [--force]
#   invoke-codex.sh --help
#
# Exit codes (invoke-codex.ps1 uses the same set, so the two never contradict):
#   0    operation succeeded; for status/wait, completion has been recorded
#   3    completion not yet recorded (status/wait only) — a lifecycle fact, not a failure
#   64   usage error
#   65   the run's storage is unusable — it could not be created, written to,
#        validated as a run directory this runner made, or removed
#   66   discard refused because completion is not recorded (--force overrides)
#   127  the `codex` executable is not on PATH

set -u

# All runs live under one predictable parent so a lost run directory can be found
# again by matching recorded metadata, without a registry. The directory NAME is
# the constant; `discard` validates against that name rather than against the
# path below, because TMPDIR can differ between the tool call that starts a run
# and the one that discards it, and a run must stay discardable when it does.
RUNS_DIR_NAME="superartes-codex-runs"
RUNS_ROOT="${TMPDIR:-/tmp}/$RUNS_DIR_NAME"

# Seconds between sentinel checks in `wait`. Overridable for the test suite only,
# and validated in cmd_wait, which is its only consumer.
POLL_INTERVAL="${SUPERARTES_CODEX_POLL_INTERVAL:-2}"

die() {
    printf '%s\n' "$2" >&2
    exit "$1"
}

usage() {
    # Printed to STDOUT, so `--help` is a success path, as it is in the
    # PowerShell sibling invoke-codex.ps1; a controller written against one
    # runner should not trip over the other. usage_error is the failure form.
    cat <<'USAGE'
Usage:
  invoke-codex.sh start prompt <work-dir> <prompt-file>
  invoke-codex.sh start review <work-dir> uncommitted
  invoke-codex.sh start review <work-dir> base   <base-ref>
  invoke-codex.sh start review <work-dir> commit <commit-sha>
  invoke-codex.sh status  <run-dir>
  invoke-codex.sh wait    <run-dir> <timeout-seconds>
  invoke-codex.sh discard <run-dir> [--force]
  invoke-codex.sh --help
USAGE
}

usage_error() {
    usage >&2
    exit 64
}

require_run_dir() {
    # Reject anything that is not a run directory this script created. Both marker
    # files are required: a bare directory with one of them is not enough to earn
    # the rm -rf that `discard` performs.
    [ -n "${1:-}" ] || usage_error
    [ -d "$1" ] || die 65 "not a run directory: $1"
    [ -f "$1/started-at" ] && [ -f "$1/mode" ] || \
        die 65 "run directory is malformed (missing started-at or mode): $1"
}

launch() {
    # launch <run-dir> <work-dir> <stdin-file> <command> [args...]
    #
    # Detach the reviewer so it survives the end of this shell-tool call.
    #
    # `setsid` puts the job in a new session and process group. It ships in
    # util-linux and is therefore ABSENT on stock macOS, so it must be guarded:
    # calling it unconditionally makes every macOS run fail. The fallback runs the
    # job inside a subshell with `set -o monitor` (job control), which gives it
    # its own process group -- the portable approximation of setsid.
    # The long spelling is deliberate: the short spelling of this
    # same builtin collides token-for-token with codex's short model flag, and
    # the plugin validator scans these runners for that flag with no exception
    # carved out. Keep the long form here.
    #
    # The launcher's own stderr goes to `launch-err`, not /dev/null. Swallowing it
    # turns "the reviewer never started" into a silent, permanent wait. A FILE is
    # safe here where a pipe would not be: the caller never blocks on it.
    local run_dir="$1" work_dir="$2" stdin_file="$3"
    shift 3

    # The inner shell runs codex, then publishes the exit status atomically.
    # Writing straight to exit-code would create the file before the digit landed
    # in it, and a status call in that window would read an empty sentinel.
    local inner='
        run_dir="$1"; work_dir="$2"; stdin_file="$3"; shift 3
        if cd "$work_dir"; then
            "$@" < "$stdin_file" > "$run_dir/log" 2> "$run_dir/err-log"
            status=$?
        else
            status=127
            printf "cannot enter work directory: %s\n" "$work_dir" > "$run_dir/err-log"
        fi
        printf "%s\n" "$status" > "$run_dir/exit-code.tmp"
        mv "$run_dir/exit-code.tmp" "$run_dir/exit-code"
    '

    # SUPERARTES_CODEX_NO_SETSID=1 forces the fallback so the macOS path can be
    # exercised on Linux. Compared as a STRING: a numeric test on a knob someone may set to "true" prints
    # "integer expected" onto start's stderr instead of just not matching.
    if [ "${SUPERARTES_CODEX_NO_SETSID:-0}" != 1 ] && command -v setsid >/dev/null 2>&1; then
        nohup setsid sh -c "$inner" _ "$run_dir" "$work_dir" "$stdin_file" "$@" \
            </dev/null >/dev/null 2>"$run_dir/launch-err" &
    else
        (
            set -o monitor
            nohup sh -c "$inner" _ "$run_dir" "$work_dir" "$stdin_file" "$@" \
                </dev/null >/dev/null 2>"$run_dir/launch-err" &
        )
    fi
}

start_prompt() {
    local run_dir="$1" work_dir="$2" prompt_file="${3:-}"
    [ -n "$prompt_file" ] || { rm -rf "$run_dir"; usage_error; }
    [ -f "$prompt_file" ] || { rm -rf "$run_dir"; die 64 "prompt file not found: $prompt_file"; }

    # Copy the prompt in, so the caller may delete its own temporary copy as soon
    # as start returns and the run stays self-contained for later inspection.
    cp "$prompt_file" "$run_dir/prompt" || { rm -rf "$run_dir"; die 65 "cannot copy the prompt file"; }

    set -- codex exec - -s read-only --skip-git-repo-check -o "$run_dir/result"
    printf '%s\n' "$*" > "$run_dir/cmd"
    launch "$run_dir" "$work_dir" "$run_dir/prompt" "$@"
}

start_review() {
    # `codex exec review` has no -s/--sandbox flag of its own, but it does NOT
    # impose a read-only filesystem policy either: the review task forces the
    # approval policy to Never and inherits everything else. The sandbox must
    # therefore be set on the PARENT command, before the `review` subcommand.
    # `codex exec -s read-only review ...` parses and is the enforcing form.
    #
    # `codex exec review` also rejects a custom prompt combined with a scope flag,
    # so no prompt is composed for this mode.
    local run_dir="$1" work_dir="$2" scope_kind="${3:-}" scope_value="${4:-}"
    [ -n "$scope_kind" ] || { rm -rf "$run_dir"; usage_error; }

    case "$scope_kind" in
        uncommitted)
            [ -z "$scope_value" ] || { rm -rf "$run_dir"; die 64 "uncommitted takes no scope value"; }
            set -- codex exec -s read-only review --uncommitted \
                --skip-git-repo-check -o "$run_dir/result"
            ;;
        base|commit)
            [ -n "$scope_value" ] || { rm -rf "$run_dir"; die 64 "$scope_kind requires a scope value"; }
            set -- codex exec -s read-only review "--$scope_kind" "$scope_value" \
                --skip-git-repo-check -o "$run_dir/result"
            ;;
        *)
            rm -rf "$run_dir"
            die 64 "unknown scope kind: $scope_kind (expected uncommitted, base or commit)"
            ;;
    esac

    printf '%s\n' "$*" > "$run_dir/cmd"
    launch "$run_dir" "$work_dir" /dev/null "$@"
}

cmd_start() {
    local mode="${1:-}" work_dir="${2:-}"
    [ -n "$mode" ] && [ -n "$work_dir" ] || usage_error
    shift 2

    command -v codex >/dev/null 2>&1 || die 127 "codex is not on PATH"
    [ -d "$work_dir" ] || die 64 "work directory does not exist: $work_dir"

    # Canonicalise before storing. Every path this script prints is absolute and
    # physical, because the agent records it as a literal string and reuses it from
    # a different process on a later tool call.
    work_dir=$(cd "$work_dir" && pwd -P) || die 64 "cannot enter work directory: $work_dir"

    mkdir -p "$RUNS_ROOT" || die 65 "cannot create the runs root: $RUNS_ROOT"
    # The runs root has a fixed, predictable name in a directory that is usually
    # shared, and mkdir gives it the ambient umask. Reviews carry repository
    # contents, so narrow it to the owner rather than trusting that umask.
    chmod 700 "$RUNS_ROOT" || die 65 "cannot restrict the runs root: $RUNS_ROOT"
    local run_dir
    run_dir=$(mktemp -d "$RUNS_ROOT/run.XXXXXXXX") || die 65 "cannot create a run directory"
    run_dir=$(cd "$run_dir" && pwd -P)

    date +%s > "$run_dir/started-at"
    printf '%s\n' "$mode" > "$run_dir/mode"
    printf '%s\n' "$work_dir" > "$run_dir/work-dir"

    case "$mode" in
        prompt) start_prompt "$run_dir" "$work_dir" "$@" ;;
        review) start_review "$run_dir" "$work_dir" "$@" ;;
        *) rm -rf "$run_dir"; usage_error ;;
    esac

    printf 'RUN_DIR=%s\n' "$run_dir"
}

cmd_status() {
    require_run_dir "${1:-}"
    local run_dir="$1" started elapsed
    started=$(cat "$run_dir/started-at")
    elapsed=$(( $(date +%s) - started ))

    printf 'RUN_DIR=%s\n' "$run_dir"
    printf 'MODE=%s\n' "$(cat "$run_dir/mode")"
    # A recovered run is identified by its recorded metadata — that is the whole
    # justification for the fixed runs root — so status must report which working
    # tree it belongs to and what was actually run, not just that it exists.
    printf 'WORK_DIR=%s\n' "$(cat "$run_dir/work-dir" 2>/dev/null)"
    printf 'CMD=%s\n' "$(cat "$run_dir/cmd" 2>/dev/null)"
    printf 'ELAPSED_SECONDS=%s\n' "$elapsed"
    printf 'RESULT=%s\n' "$run_dir/result"
    # Codex writes its FINAL MESSAGE to stdout and its progress event stream to
    # stderr, so err-log is the large one — hundreds of kilobytes is normal.
    printf 'STDOUT_LOG=%s\n' "$run_dir/log"
    printf 'STDERR_LOG=%s\n' "$run_dir/err-log"

    # A non-empty launch-err means the reviewer never started. Surfacing it here
    # is what stops "no exit-code yet" from being read as "still working".
    if [ -s "$run_dir/launch-err" ]; then
        printf 'LAUNCH_ERROR=%s\n' "$run_dir/launch-err"
    fi

    if [ -f "$run_dir/exit-code" ]; then
        printf 'STATE=done\n'
        printf 'EXIT_CODE=%s\n' "$(cat "$run_dir/exit-code")"
        if [ -s "$run_dir/result" ]; then
            printf 'RESULT_BYTES=%s\n' "$(wc -c < "$run_dir/result" | tr -d ' ')"
        else
            printf 'RESULT_BYTES=0\n'
        fi
        return 0
    fi

    printf 'STATE=not-recorded\n'
    return 3
}

cmd_wait() {
    require_run_dir "${1:-}"
    local run_dir="$1" timeout="${2:-}" waited=0
    case "$timeout" in
        ''|*[!0-9]*) usage_error ;;
    esac

    # The poll interval arrives from the environment, so hold it to the same
    # standard as the timeout argument. Zero would spin the loop below forever
    # without ever advancing `waited`, and a non-numeric value is read as a
    # variable name by the arithmetic, aborting with "unbound variable" and
    # exit 1 — a failure outside this script's documented contract.
    case "$POLL_INTERVAL" in
        ''|*[!0-9]*) die 64 "SUPERARTES_CODEX_POLL_INTERVAL must be a positive integer: $POLL_INTERVAL" ;;
    esac
    [ "$POLL_INTERVAL" -gt 0 ] || \
        die 64 "SUPERARTES_CODEX_POLL_INTERVAL must be a positive integer: $POLL_INTERVAL"

    while [ "$waited" -lt "$timeout" ]; do
        [ -f "$run_dir/exit-code" ] && break
        sleep "$POLL_INTERVAL"
        waited=$(( waited + POLL_INTERVAL ))
    done

    cmd_status "$run_dir"
}

cmd_discard() {
    # Removes the run's artifacts. It does NOT stop the reviewer: this runner has
    # no cancellation, so a discarded review keeps running and keeps spending
    # tokens until it finishes on its own. Say so when reporting to the user.
    #
    # --force is accepted on either side of the run directory, so an agent
    # composing the command from a template need not remember which.
    local run_dir="" force="" arg
    for arg in "$@"; do
        case "$arg" in
            --force) force="--force" ;;
            *)
                [ -z "$run_dir" ] || usage_error
                run_dir="$arg"
                ;;
        esac
    done
    require_run_dir "$run_dir"

    if [ ! -f "$run_dir/exit-code" ] && [ "$force" != "--force" ]; then
        die 66 "completion not recorded for: $run_dir (pass --force to discard the artifacts anyway)"
    fi

    # Canonicalise before checking, because a test on the raw argument accepts
    # traversal: ".../run.x/../../victim" matches a "$RUNS_ROOT"/run.* glob.
    #
    # The check is on the resolved path's SHAPE — a "run.*" directory whose parent
    # is named superartes-codex-runs — and deliberately not on $RUNS_ROOT, which is
    # recomputed from $TMPDIR on every invocation. Comparing against that path
    # makes a run started under one TMPDIR undiscardable under another, and each
    # subcommand is a separate process for an agent, so the two need not agree.
    # A shape check also survives /var versus /private/var on macOS for free.
    # require_run_dir has already demanded both marker files, so a directory that
    # merely borrows the naming cannot reach the removal below.
    local canon_run parent
    canon_run=$(cd "$run_dir" 2>/dev/null && pwd -P) || die 65 "not a run directory: $run_dir"
    parent="${canon_run%/*}"

    case "${canon_run##*/}" in
        run.*) ;;
        *) die 65 "refusing to remove a directory this runner did not create: $canon_run" ;;
    esac
    [ "${parent##*/}" = "$RUNS_DIR_NAME" ] || \
        die 65 "refusing to remove a path outside a $RUNS_DIR_NAME directory: $canon_run"

    rm -rf "$canon_run"
    [ ! -d "$canon_run" ] || die 65 "run directory still present after removal: $canon_run"
    printf 'STATE=discarded\n'
}

case "${1:-}" in
    start)     shift; cmd_start "$@" ;;
    status)    shift; cmd_status "$@" ;;
    wait)      shift; cmd_wait "$@" ;;
    discard)   shift; cmd_discard "$@" ;;
    -h|--help) usage ;;
    *)         usage_error ;;
esac
