#!/usr/bin/env bash
# test-invoke-codex.sh — deterministic tests for the background Codex runner.
#
# Uses a fake `codex` on PATH, so this suite needs no credentials, no network and
# no model tokens. Each test gets its own sandbox, with TMPDIR pointed inside it
# so the runner's runs root is isolated per test.

set -u

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
RUNNER="$ROOT_DIR/skills/external-review/invoke-codex.sh"

# Fail loudly if the runner is missing, instead of letting the harness supply
# the exit codes the assertions expect. `bash <missing-script>` exits 127, which
# is exactly what the missing-codex test expects — so without this guard a
# suite pointed at nothing reports assertions as PASSED for the wrong reason.
if [ ! -f "$RUNNER" ]; then
    printf 'FATAL: runner not found: %s\n' "$RUNNER" >&2
    exit 1
fi

passed=0
failed=0

pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL: %s\n      %s\n' "$1" "${2:-}" >&2; }

assert_status() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected exit $2, got $3"; fi; }
assert_equals() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }
assert_contains() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected '$2' in: $3" ;; esac
}

new_sandbox() {
    local sandbox
    sandbox=$(mktemp -d "${TMPDIR:-/tmp}/invoke-codex-test.XXXXXX") || exit 1
    mkdir -p "$sandbox/bin" "$sandbox/tmp" "$sandbox/work"
    cat > "$sandbox/bin/codex" <<'FAKE'
#!/usr/bin/env bash
# Fake codex. Records argv one per line and its stdin verbatim, optionally
# sleeps, emulates -o, and exits as told.
printf '%s\n' "$@" > "$FAKE_CODEX_ARGV"
cat > "$FAKE_CODEX_STDIN"
printf 'fake codex final message\n'
printf 'fake codex event stream\n' >&2
if [ -n "${FAKE_CODEX_SLEEP:-}" ]; then sleep "$FAKE_CODEX_SLEEP"; fi
out=""; prev=""
for arg in "$@"; do
    if [ "$prev" = "-o" ]; then out="$arg"; fi
    prev="$arg"
done
if [ -n "$out" ]; then printf '%s' "${FAKE_CODEX_RESULT:-fake review body}" > "$out"; fi
exit "${FAKE_CODEX_EXIT:-0}"
FAKE
    chmod +x "$sandbox/bin/codex"
    printf '%s' "$sandbox"
}

run_in() {
    local sandbox="$1"; shift
    PATH="$sandbox/bin:$PATH" TMPDIR="$sandbox/tmp" \
    FAKE_CODEX_ARGV="$sandbox/argv" FAKE_CODEX_STDIN="$sandbox/stdin" \
    FAKE_CODEX_SLEEP="${FAKE_CODEX_SLEEP:-}" FAKE_CODEX_EXIT="${FAKE_CODEX_EXIT:-0}" \
    FAKE_CODEX_RESULT="${FAKE_CODEX_RESULT:-fake review body}" \
    SUPERARTES_CODEX_POLL_INTERVAL="${SUPERARTES_CODEX_POLL_INTERVAL:-1}" \
    SUPERARTES_CODEX_NO_SETSID="${SUPERARTES_CODEX_NO_SETSID:-0}" \
        "$RUNNER" "$@"
}

run_dir_or_fail() {
    # run_dir_or_fail <label> <start-output>
    #
    # Reads the RUN_DIR= line from start's output into the global RUN_DIR and
    # proves it names a real directory. Every test must go through this rather
    # than parsing the line itself: if the runner cannot be resolved or dies
    # early, RUN_DIR comes back EMPTY, and assertions of the form
    # `[ -d "$run_dir" ] || pass` then succeed vacuously — a broken suite that
    # reports itself green. Callers pair it with `|| return` so the rest of the
    # test is skipped rather than run against nothing.
    #
    # It counts the check itself, in THIS shell. A helper invoked inside $( )
    # would increment the counters in a subshell, where the increment dies with
    # the subshell and a genuine failure would still print "0 failed".
    local label="$1" out="$2"
    RUN_DIR=$(printf '%s' "$out" | sed -n 's/^RUN_DIR=//p')
    if [ -z "$RUN_DIR" ]; then
        fail "$label yields a usable run directory" "no RUN_DIR= line in: $out"
        return 1
    fi
    if [ ! -d "$RUN_DIR" ]; then
        fail "$label yields a usable run directory" "RUN_DIR is not a directory: $RUN_DIR"
        return 1
    fi
    pass "$label yields a usable run directory"
}

await_done() {
    # await_done <run-dir> [tries] — poll for the completion sentinel, 0.1s apart.
    # The default ceiling is generous on purpose: the longest fake reviewer in
    # this suite sleeps 10 seconds, and a loaded machine must not turn that into
    # a spurious failure. Pass a small ceiling when proving a run never finishes.
    local run_dir="$1" limit="${2:-300}" tries=0
    while [ "$tries" -lt "$limit" ]; do
        [ -f "$run_dir/exit-code" ] && return 0
        sleep 0.1; tries=$((tries + 1))
    done
    return 1
}

# --------------------------------------------------------------------------
# Preflight and usage
# --------------------------------------------------------------------------

test_missing_codex() {
    # The PATH here is a directory of the test's own making, so `codex` cannot be
    # on it however the machine is set up. Deriving it from where coreutils live
    # instead would silently SKIP on any machine that installs codex alongside
    # them — which is common enough that exit 127 would never be tested at all.
    #
    # The directory holds one symlink, to bash: the shebang's `/usr/bin/env bash`
    # resolves bash through PATH, so a truly empty PATH would fail before the
    # runner ran. Everything the runner touches before the codex check is a
    # shell builtin, so nothing else is needed.
    local sandbox out st
    sandbox=$(new_sandbox)
    mkdir -p "$sandbox/nocodex"
    ln -s "$(command -v bash)" "$sandbox/nocodex/bash"

    out=$(PATH="$sandbox/nocodex" TMPDIR="$sandbox/tmp" \
        "$RUNNER" start review "$sandbox/work" uncommitted 2>&1)
    st=$?
    assert_status "missing codex exits 127" 127 "$st"
    assert_contains "missing codex explains itself" "not on PATH" "$out"
    rm -rf "$sandbox"
}

test_usage_errors() {
    local sandbox st
    sandbox=$(new_sandbox)
    run_in "$sandbox" >/dev/null 2>&1; st=$?
    assert_status "no subcommand exits 64" 64 "$st"
    printf 'old style\n' > "$sandbox/p.md"
    run_in "$sandbox" "$sandbox/p.md" >/dev/null 2>&1; st=$?
    assert_status "legacy single-argument call exits 64" 64 "$st"
    run_in "$sandbox" start review "$sandbox/nope" uncommitted >/dev/null 2>&1; st=$?
    assert_status "absent work directory exits 64" 64 "$st"
    run_in "$sandbox" start prompt "$sandbox/work" "$sandbox/nope.md" >/dev/null 2>&1; st=$?
    assert_status "absent prompt file exits 64" 64 "$st"
    rm -rf "$sandbox"
}

# --------------------------------------------------------------------------
# Document review
# --------------------------------------------------------------------------

test_prompt_lifecycle() {
    local sandbox out run_dir st argv expected
    sandbox=$(new_sandbox)
    printf 'review this document\n' > "$sandbox/prompt.md"

    out=$(run_in "$sandbox" start prompt "$sandbox/work" "$sandbox/prompt.md")
    assert_contains "start prompt prints RUN_DIR" "RUN_DIR=" "$out"
    run_dir_or_fail "start prompt" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"
    assert_equals "prompt is copied into the run directory" \
        "review this document" "$(cat "$run_dir/prompt")"

    await_done "$run_dir" || fail "prompt run finishes" "sentinel never appeared"

    # The prompt must actually reach codex on stdin, not merely sit in a file.
    assert_equals "the prompt is fed to codex on stdin" \
        "review this document" "$(cat "$sandbox/stdin")"

    run_in "$sandbox" status "$run_dir" > "$sandbox/status.txt"; st=$?
    assert_status "status of a finished run exits 0" 0 "$st"
    assert_contains "status reports done" "STATE=done" "$(cat "$sandbox/status.txt")"
    assert_contains "status reports exit code" "EXIT_CODE=0" "$(cat "$sandbox/status.txt")"

    assert_equals "result holds the review body" "fake review body" "$(cat "$run_dir/result")"
    # Codex writes its final message to stdout and its event stream to stderr.
    assert_contains "stdout captures the final message" \
        "fake codex final message" "$(cat "$run_dir/log")"
    assert_contains "stderr captures the event stream" \
        "fake codex event stream" "$(cat "$run_dir/err-log")"

    # Exact argument vector, one per line. A substring test would still pass with
    # `-s` and `read-only` separated, or with the sandbox flag landing after the
    # `-` that makes codex read the prompt from stdin — the precise defect class
    # an earlier review caught in review mode.
    argv=$(cat "$sandbox/argv")
    expected="exec
-
-s
read-only
--skip-git-repo-check
-o
$run_dir/result"
    assert_equals "prompt mode builds the exact argument vector" "$expected" "$argv"
    rm -rf "$sandbox"
}

test_exit_code_is_a_bare_integer() {
    local sandbox out run_dir contents
    sandbox=$(new_sandbox); printf 'x\n' > "$sandbox/p.md"
    out=$(run_in "$sandbox" start prompt "$sandbox/work" "$sandbox/p.md")
    run_dir_or_fail "start prompt" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"
    await_done "$run_dir" || fail "run finishes" "no sentinel"
    contents=$(cat "$run_dir/exit-code")
    case "$contents" in
        ''|*[!0-9]*) fail "exit-code holds a bare integer" "got '$contents'" ;;
        *) pass "exit-code holds a bare integer" ;;
    esac
    rm -rf "$sandbox"
}

test_nonzero_exit_is_recorded() {
    local sandbox out run_dir
    sandbox=$(new_sandbox); printf 'x\n' > "$sandbox/p.md"
    out=$(FAKE_CODEX_EXIT=7 run_in "$sandbox" start prompt "$sandbox/work" "$sandbox/p.md")
    run_dir_or_fail "start prompt" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"
    await_done "$run_dir" || fail "run finishes" "no sentinel"
    assert_equals "non-zero reviewer exit is recorded" "7" "$(cat "$run_dir/exit-code")"
    rm -rf "$sandbox"
}

# --------------------------------------------------------------------------
# Code review
# --------------------------------------------------------------------------

test_review_scopes() {
    local sandbox out run_dir argv expected
    for scope in uncommitted base commit; do
        sandbox=$(new_sandbox)
        case "$scope" in
            uncommitted) out=$(run_in "$sandbox" start review "$sandbox/work" uncommitted) ;;
            base)        out=$(run_in "$sandbox" start review "$sandbox/work" base master) ;;
            commit)      out=$(run_in "$sandbox" start review "$sandbox/work" commit deadbeef) ;;
        esac
        run_dir_or_fail "start review $scope" "$out" || { rm -rf "$sandbox"; continue; }
        run_dir="$RUN_DIR"
        await_done "$run_dir" || fail "$scope run finishes" "no sentinel"
        argv=$(cat "$sandbox/argv")

        # Exact argument vector, one per line — not a substring match, so a flag
        # landing in the wrong position cannot pass.
        case "$scope" in
            uncommitted) expected="exec
-s
read-only
review
--uncommitted
--skip-git-repo-check
-o
$run_dir/result" ;;
            base) expected="exec
-s
read-only
review
--base
master
--skip-git-repo-check
-o
$run_dir/result" ;;
            commit) expected="exec
-s
read-only
review
--commit
deadbeef
--skip-git-repo-check
-o
$run_dir/result" ;;
        esac
        assert_equals "$scope builds the exact argument vector" "$expected" "$argv"
        rm -rf "$sandbox"
    done
}

test_review_scope_validation() {
    local sandbox st
    sandbox=$(new_sandbox)
    run_in "$sandbox" start review "$sandbox/work" uncommitted extra >/dev/null 2>&1; st=$?
    assert_status "uncommitted rejects a scope value" 64 "$st"
    run_in "$sandbox" start review "$sandbox/work" base >/dev/null 2>&1; st=$?
    assert_status "base requires a scope value" 64 "$st"
    run_in "$sandbox" start review "$sandbox/work" commit >/dev/null 2>&1; st=$?
    assert_status "commit requires a scope value" 64 "$st"
    run_in "$sandbox" start review "$sandbox/work" nonsense >/dev/null 2>&1; st=$?
    assert_status "unknown scope kind exits 64" 64 "$st"
    rm -rf "$sandbox"
}

# --------------------------------------------------------------------------
# Portability
# --------------------------------------------------------------------------

test_runs_without_setsid() {
    # Stock macOS has no setsid; the runner must fall back rather than fail, and
    # must not report a launch error when it does.
    local sandbox out run_dir
    sandbox=$(new_sandbox)
    out=$(SUPERARTES_CODEX_NO_SETSID=1 run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start review without setsid" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"
    if await_done "$run_dir"; then pass "the run completes without setsid"; else
        fail "the run completes without setsid" "sentinel never appeared"; fi
    assert_equals "no launcher error without setsid" "" "$(cat "$run_dir/launch-err" 2>/dev/null)"
    rm -rf "$sandbox"
}

test_launch_error_is_surfaced() {
    # A launch failure must not look like a running reviewer.
    #
    # The launcher's stderr is redirected to launch-err instead of /dev/null for
    # exactly one reason: a reviewer that never starts would otherwise be
    # indistinguishable from one still working, and the controller would wait
    # forever. So the launch is made to FAIL FOR REAL — a setsid shim on the
    # sandbox PATH that refuses — rather than hand-writing launch-err, which
    # would test only how status formats a file the test itself created.
    local sandbox out run_dir status_out
    sandbox=$(new_sandbox)
    cat > "$sandbox/bin/setsid" <<'SHIM'
#!/usr/bin/env bash
printf 'setsid: shim refusing to launch\n' >&2
exit 1
SHIM
    chmod +x "$sandbox/bin/setsid"

    out=$(SUPERARTES_CODEX_NO_SETSID=0 run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start with a failing setsid" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"

    # A short ceiling: the shim fails immediately, so the sentinel is not merely
    # late — it must never arrive at all.
    if await_done "$run_dir" 30; then
        fail "a failed launch never records completion" "exit-code appeared anyway"
    else
        pass "a failed launch never records completion"
    fi
    if [ -s "$run_dir/launch-err" ]; then
        pass "the launcher's own stderr reaches launch-err"
    else
        fail "the launcher's own stderr reaches launch-err" "launch-err is empty"
    fi

    status_out=$(run_in "$sandbox" status "$run_dir" 2>&1)
    assert_contains "status surfaces a launcher error" "LAUNCH_ERROR=" "$status_out"
    assert_contains "an unfinished run is not called running" "STATE=not-recorded" "$status_out"
    rm -rf "$sandbox"
}

# --------------------------------------------------------------------------
# status / wait / discard
# --------------------------------------------------------------------------

test_status_and_wait() {
    # The fake reviewer sleeps 10 seconds so that "still unfinished" is a
    # comfortable claim on a loaded machine: the status check below and the
    # 2-second wait both have seconds of headroom before it could finish early.
    local sandbox out run_dir st
    sandbox=$(new_sandbox)
    out=$(FAKE_CODEX_SLEEP=10 run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start review" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"

    run_in "$sandbox" status "$run_dir" > "$sandbox/s.txt" 2>&1; st=$?
    assert_status "status of an unfinished run exits 3" 3 "$st"
    assert_contains "status names the state honestly" "STATE=not-recorded" "$(cat "$sandbox/s.txt")"

    run_in "$sandbox" wait "$run_dir" 2 > "$sandbox/w.txt" 2>&1; st=$?
    assert_status "wait exits 3 when it times out" 3 "$st"

    run_in "$sandbox" wait "$run_dir" 60 > "$sandbox/w.txt" 2>&1; st=$?
    assert_status "wait exits 0 once the run finishes" 0 "$st"
    assert_contains "wait reports done" "STATE=done" "$(cat "$sandbox/w.txt")"

    run_in "$sandbox" wait "$run_dir" soon >/dev/null 2>&1; st=$?
    assert_status "wait rejects a non-numeric timeout" 64 "$st"

    run_in "$sandbox" status "$sandbox/not-a-run" >/dev/null 2>&1; st=$?
    assert_status "status of a missing run directory exits 65" 65 "$st"
    rm -rf "$sandbox"
}

test_discard() {
    local sandbox out run_dir st
    sandbox=$(new_sandbox)
    out=$(FAKE_CODEX_SLEEP=10 run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start review" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"

    run_in "$sandbox" discard "$run_dir" >/dev/null 2>&1; st=$?
    assert_status "discard of an unfinished run exits 66" 66 "$st"
    if [ -d "$run_dir" ]; then pass "a refused discard leaves the run intact"; else
        fail "a refused discard leaves the run intact" "directory was removed"; fi

    run_in "$sandbox" discard "$run_dir" --force > "$sandbox/d.txt" 2>&1; st=$?
    assert_status "forced discard exits 0" 0 "$st"
    assert_contains "discard reports its state" "STATE=discarded" "$(cat "$sandbox/d.txt")"
    if [ -d "$run_dir" ]; then fail "forced discard removes the run" "directory survived"; else
        pass "forced discard removes the run"; fi
    # Nothing to await: the run directory has just been removed, and the reviewer
    # this test discarded is still sleeping. Waiting on the sandbox path (which
    # never holds a sentinel) only burned the full polling ceiling.
    rm -rf "$sandbox"
}

test_discard_after_completion() {
    local sandbox out run_dir st
    sandbox=$(new_sandbox)
    out=$(run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start review" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"
    await_done "$run_dir" || fail "run finishes" "no sentinel"
    run_in "$sandbox" discard "$run_dir" >/dev/null 2>&1; st=$?
    assert_status "discard of a finished run exits 0" 0 "$st"
    if [ -d "$run_dir" ]; then fail "discard removes the run directory" "directory survived"; else
        pass "discard removes the run directory"; fi
    rm -rf "$sandbox"
}

test_discard_rejects_traversal() {
    # ".../run.x/../../victim" matches a naive "$RUNS_ROOT"/run.* glob. Canonical
    # comparison must reject it before rm -rf sees it.
    local sandbox out run_dir victim traversal st
    sandbox=$(new_sandbox)
    out=$(run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start review" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"
    await_done "$run_dir" || fail "run finishes" "no sentinel"

    victim="$sandbox/tmp/victim"
    mkdir -p "$victim"
    date +%s > "$victim/started-at"; printf 'review\n' > "$victim/mode"
    printf '0\n' > "$victim/exit-code"
    traversal="$run_dir/../../victim"

    run_in "$sandbox" discard "$traversal" >/dev/null 2>&1; st=$?
    assert_status "discard rejects a traversal path" 65 "$st"
    if [ -d "$victim" ]; then pass "the traversal target survives"; else
        fail "the traversal target survives" "victim was removed"; fi

    run_in "$sandbox" discard "$victim" >/dev/null 2>&1; st=$?
    assert_status "discard rejects a directory outside the runs root" 65 "$st"
    rm -rf "$sandbox"
}

test_malformed_run_directory() {
    # A directory that exists but carries neither marker file was not produced by
    # this runner. It is the case that stands between `discard` and an rm -rf of
    # something the caller merely mistyped, so both commands must refuse it.
    local sandbox bare st
    sandbox=$(new_sandbox)
    bare="$sandbox/tmp/superartes-codex-runs/run.bare"
    mkdir -p "$bare"

    run_in "$sandbox" status "$bare" >/dev/null 2>&1; st=$?
    assert_status "status of a malformed run directory exits 65" 65 "$st"

    run_in "$sandbox" discard "$bare" >/dev/null 2>&1; st=$?
    assert_status "discard of a malformed run directory exits 65" 65 "$st"
    if [ -d "$bare" ]; then pass "a malformed run directory survives discard"; else
        fail "a malformed run directory survives discard" "it was removed"; fi
    rm -rf "$sandbox"
}

test_discard_rejects_a_foreign_child_of_the_runs_root() {
    # Well-formed enough to pass require_run_dir, and sitting directly inside the
    # runs root, but not named run.* — so this runner did not create it and must
    # not remove it. Only the name check stands between the two cases.
    local sandbox intruder st
    sandbox=$(new_sandbox)
    intruder="$sandbox/tmp/superartes-codex-runs/somebody-elses-data"
    mkdir -p "$intruder"
    date +%s > "$intruder/started-at"; printf 'review\n' > "$intruder/mode"
    printf '0\n' > "$intruder/exit-code"

    run_in "$sandbox" discard "$intruder" >/dev/null 2>&1; st=$?
    assert_status "discard rejects a runs-root child it did not create" 65 "$st"
    if [ -d "$intruder" ]; then pass "the foreign directory survives"; else
        fail "the foreign directory survives" "it was removed"; fi
    rm -rf "$sandbox"
}

test_discard_across_tmpdirs() {
    # Each subcommand is a separate process for an agent, and TMPDIR need not
    # match between the call that starts a run and the call that discards it.
    # Validating against a runs root recomputed from $TMPDIR would make a run
    # started under one TMPDIR permanently undiscardable under another, so the
    # check is on the run directory's shape instead. This is the regression test.
    local sandbox out run_dir st
    sandbox=$(new_sandbox)
    mkdir -p "$sandbox/other-tmp"
    out=$(run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start review" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"
    await_done "$run_dir" || fail "run finishes" "no sentinel"

    PATH="$sandbox/bin:$PATH" TMPDIR="$sandbox/other-tmp" \
        "$RUNNER" discard "$run_dir" >/dev/null 2>&1; st=$?
    assert_status "discard works under a different TMPDIR" 0 "$st"
    if [ -d "$run_dir" ]; then fail "the cross-TMPDIR discard removes the run" "directory survived"; else
        pass "the cross-TMPDIR discard removes the run"; fi
    rm -rf "$sandbox"
}

test_force_flag_position() {
    # `discard --force <run-dir>` and `discard <run-dir> --force` must both work:
    # an agent composing the command from a template should not have to remember
    # which side the flag goes on, and the wrong order used to be reported as
    # "not a run directory: --force".
    local sandbox out run_dir st
    sandbox=$(new_sandbox)
    out=$(FAKE_CODEX_SLEEP=10 run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start review" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"

    run_in "$sandbox" discard --force "$run_dir" > "$sandbox/d.txt" 2>&1; st=$?
    assert_status "--force before the run directory exits 0" 0 "$st"
    assert_contains "--force before the run directory discards" \
        "STATE=discarded" "$(cat "$sandbox/d.txt")"
    rm -rf "$sandbox"
}

test_help() {
    # --help is a success path in both invoke-codex runners, so a controller
    # written against one should not trip over the other.
    local sandbox out st
    sandbox=$(new_sandbox)
    out=$(run_in "$sandbox" --help 2>/dev/null); st=$?
    assert_status "--help exits 0" 0 "$st"
    assert_contains "--help prints usage to stdout" "invoke-codex.sh start prompt" "$out"
    out=$(run_in "$sandbox" -h 2>/dev/null); st=$?
    assert_status "-h exits 0" 0 "$st"
    rm -rf "$sandbox"
}

test_poll_interval_validation() {
    # SUPERARTES_CODEX_POLL_INTERVAL is an environment knob that feeds both a loop
    # guard and shell arithmetic. Zero spins forever; a non-numeric value is read
    # as a variable name and aborts with "unbound variable" and exit 1, outside
    # this runner's documented exit codes. Both must be usage errors instead.
    local sandbox out run_dir st
    sandbox=$(new_sandbox)
    out=$(run_in "$sandbox" start review "$sandbox/work" uncommitted)
    run_dir_or_fail "start review" "$out" || { rm -rf "$sandbox"; return; }
    run_dir="$RUN_DIR"
    await_done "$run_dir" || fail "run finishes" "no sentinel"

    SUPERARTES_CODEX_POLL_INTERVAL=0 run_in "$sandbox" wait "$run_dir" 4 >/dev/null 2>&1; st=$?
    assert_status "a zero poll interval exits 64" 64 "$st"
    SUPERARTES_CODEX_POLL_INTERVAL=soon run_in "$sandbox" wait "$run_dir" 4 >/dev/null 2>&1; st=$?
    assert_status "a non-numeric poll interval exits 64" 64 "$st"
    rm -rf "$sandbox"
}

# --------------------------------------------------------------------------

test_missing_codex
test_usage_errors
test_prompt_lifecycle
test_exit_code_is_a_bare_integer
test_nonzero_exit_is_recorded
test_review_scopes
test_review_scope_validation
test_runs_without_setsid
test_launch_error_is_surfaced
test_status_and_wait
test_discard
test_discard_after_completion
test_discard_rejects_traversal
test_malformed_run_directory
test_discard_rejects_a_foreign_child_of_the_runs_root
test_discard_across_tmpdirs
test_force_flag_position
test_help
test_poll_interval_validation

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
