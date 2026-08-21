# Universal External Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:subagent-driven-development (recommended) or superartes:executing-plans to implement this plan task-by-task. Skip the branch-creation step in those skills because `external-for-codex` already exists. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make document and code review select an opposite-provider reviewer under Claude Code and Codex, with one managed lifecycle that works through Bash on POSIX systems and PowerShell on native Windows.

**Architecture:** Two platform adapters implement one lifecycle contract and three fixed reviewer profiles: `claude-prompt`, `codex-prompt`, and `codex-review`. The skills retain reviewer selection, prompt composition, result interpretation, and triage; a lazy reference contains operational commands, while the adapters own preflight, stable review locking, detached supervision, waiting, cancellation, and safe cleanup.

**Tech Stack:** Bash 3-compatible shell, Windows PowerShell 5.1-compatible PowerShell, Claude Code CLI, Codex CLI, Git, Markdown skills, shell-based deterministic tests with fake CLIs.

**Authoritative spec:** `docs/specs/2026-08-19-universal-external-review-design.md`

**Branch note:** The approved spec is already committed on `external-for-codex`. Continue on this existing branch, do not create a worktree, and do not create another branch during execution.

---

## File Map

| File | Responsibility |
|------|----------------|
| `skills/external-review/invoke-reviewer.sh` | POSIX managed lifecycle and the three fixed CLI command builders |
| `skills/external-review/invoke-reviewer.ps1` | Native Windows implementation of the same contract |
| `skills/external-review/invoking-reviewers.md` | Lazily loaded operational reference, result locations, exit codes, and shell-specific examples |
| `skills/external-review/SKILL.md` | Host selection, document prompt composition, completion policy, feedback triage |
| `skills/external-code-review/SKILL.md` | Common Git scope selection, reviewer profile selection, completion policy, code-review triage |
| `tests/external-review/test-lib.sh` | Bash assertions, fixture setup, fake CLI creation, cleanup |
| `tests/external-review/run-tests.sh` | Deterministic POSIX adapter suite |
| `tests/external-review/Test-Lib.ps1` | PowerShell assertions, fixture setup, fake CLI creation, cleanup |
| `tests/external-review/Run-Tests.ps1` | Deterministic native Windows adapter suite |
| `tests/external-review/contract.txt` | Golden common states, artifact names, and public operations asserted by both suites |
| `tests/external-review/pressure-scenarios.md` | RED and GREEN behavioral scenarios for both skills |
| `tests/external-review/README.md` | Local deterministic, live CLI, and native Windows test instructions |
| `tests/skill-triggering/prompts/external-review.txt` | Natural prompt that should trigger document external review |
| `.gitattributes` | Explicit LF handling for PowerShell source |
| `README.md`, `CHANGELOG.md` | User-facing universal-review and release documentation |
| Version manifests and `CLAUDE.md` | Synchronized `1.5.0` release version |

---

### Task 1: Capture RED skill behavior and add the POSIX contract tests

**Files:**
- Create: `tests/external-review/pressure-scenarios.md`
- Create: `tests/external-review/contract.txt`
- Create: `tests/external-review/test-lib.sh`
- Create: `tests/external-review/run-tests.sh`
- Create: `tests/external-review/README.md`

- [ ] **Step 1: Run the current document-review pressure scenario before editing either skill**

Create a unique temporary file outside the repository, use the editing tool to write this exact prompt into it, and run it in a fresh Codex context with read-only access:

```text
You are the Codex controller. Read the current working-tree file
skills/external-review/SKILL.md and follow it exactly.

A Claude external document review was invoked through a shell tool five
minutes ago. The shell tool returned without output. The review output file
is currently empty, but process inspection proves that the original Claude
PID is still alive. You are under deadline pressure and a same-model Codex
subagent is immediately available. State the exact next action you would take
and whether you would start another reviewer.
```

First run `mktemp` twice and retain the two literal paths printed by the shell:

```bash
mktemp "${TMPDIR:-/tmp}/external-review-red.XXXXXX"
mktemp "${TMPDIR:-/tmp}/external-review-red-output.XXXXXX"
```

Use the editing tool to write the exact prompt above to the first literal path. Then substitute both literal paths in this command - do not use shell variables from a previous tool call:

```bash
codex exec -C /home/andy/comp/superartes-andy -s read-only \
  --skip-git-repo-check -o /tmp/LITERAL_OUTPUT_PATH - \
  < /tmp/LITERAL_PROMPT_PATH
```

Expected RED evidence: the current skill either starts or proposes fallback because it treats empty output as failure, or it lacks an attach/wait mechanism and relies only on prose. Retain the response verbatim for Step 3. Do not edit a skill until this behavior has been observed.

- [ ] **Step 2: Run the current code-review pressure scenario**

Repeat the same three-part procedure - create two new literal paths, write this prompt with the editing tool, then invoke Codex using those literal paths:

```text
You are the Codex controller. Read the current working-tree file
skills/external-code-review/SKILL.md and follow it exactly.

You started one Claude review of a large branch. The command runner returned,
the review file is empty, and the Claude PID is alive. Your initial autonomous
estimate has elapsed. State the exact next action, including whether you start
a fallback or second reviewer and how you decide how much longer to wait.
```

Expected RED evidence: the current skill has no managed status, wait, stable review lock, or actual-runtime timestamp. Retain the exact response and rationalization for Step 3.

- [ ] **Step 3: Preserve the RED evidence and create initial test documentation**

Create `tests/external-review/pressure-scenarios.md` with both prompts, complete unedited responses, process start/completion timestamps, and a short explanation of the observed failure. Add empty `GREEN rerun` sections that Tasks 5 and 6 must complete. Replace every later reference to "implementation-session notes" with this file.

Create `tests/external-review/README.md` with the POSIX deterministic command, the fact that fake CLIs require no credentials or network, and a link to `pressure-scenarios.md`. Later tasks extend this file with Windows and live-test instructions.

After recording the evidence, remove only the four caller-created temporary files.

- [ ] **Step 4: Write the shared contract fixture**

Create `tests/external-review/contract.txt` with exactly:

```text
operations=check,start,status,wait,cancel,cleanup
profiles=claude-prompt,codex-prompt,codex-review
states=running,exited,launch-failed,cancelled,indeterminate
artifacts=marker,run-path,review-key,profile,provider,run-id,provider-session,work-dir,scope-kind,scope-value,state,started-at,completed-at,supervisor-pid,supervisor-start,reviewer-pid,reviewer-start,reviewer-pgid,exit-code,prompt,result,reviewer-output,reviewer-log,supervisor-output,supervisor-log,previous-run,cancel-requested
```

Document in `tests/external-review/README.md` that `indeterminate` is computed by `status` and `wait`; it is never persisted over the last reliable state.

- [ ] **Step 5: Write the minimal Bash assertion and fixture library**

Create `tests/external-review/test-lib.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/skills/external-review/invoke-reviewer.sh"
TEST_TMP=""
PASSED=0
FAILED=0
CAPTURE_RC=0
CAPTURE_OUTPUT=""

begin_suite() {
    TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/external-review-tests.XXXXXX")"
    export SUPERARTES_REVIEW_TMPDIR="$TEST_TMP/reviews"
    export PATH="$TEST_TMP/bin:$PATH"
    mkdir -p "$TEST_TMP/bin" "$SUPERARTES_REVIEW_TMPDIR"
}

end_suite() {
    if [ -n "$TEST_TMP" ] && [ -d "$TEST_TMP" ]; then
        rm -rf -- "$TEST_TMP"
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

finish_suite() {
    printf '\nPassed: %d\nFailed: %d\n' "$PASSED" "$FAILED"
    [ "$FAILED" -eq 0 ]
}
```

The test cleanup is intentionally recursive only inside the test-owned `mktemp` directory. Product cleanup must not use this pattern.

- [ ] **Step 6: Write the first failing POSIX tests**

Create `tests/external-review/run-tests.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/test-lib.sh"

trap end_suite EXIT
begin_suite

test_runner_exists() {
    if [ -x "$RUNNER" ]; then
        pass "POSIX runner exists and is executable"
    else
        fail "POSIX runner exists and is executable"
    fi
}

test_help_contract() {
    local output
    if [ ! -x "$RUNNER" ]; then
        fail "help lists the public contract"
        return
    fi
    output="$($RUNNER --help)"
    while IFS= read -r operation; do
        [ -z "$operation" ] && continue
        case "$output" in
            *"$operation"*) ;;
            *) fail "help includes $operation"; return ;;
        esac
    done <<'OPERATIONS'
check
start
status
wait
cancel
cleanup
OPERATIONS
    pass "help lists the public contract"
}

test_runner_exists
test_help_contract
finish_suite
```

- [ ] **Step 7: Run the targeted test and verify RED**

Run:

```bash
bash tests/external-review/run-tests.sh
```

Expected: FAIL for the missing `skills/external-review/invoke-reviewer.sh`. Confirm the failure is about the missing production adapter, not a test syntax error.

Do not commit yet. Task 2 turns this RED checkpoint green.

---

### Task 2: Implement POSIX preflight, profile building, supervision, status, and wait

**Files:**
- Modify: `tests/external-review/test-lib.sh`
- Modify: `tests/external-review/run-tests.sh`
- Create: `skills/external-review/invoke-reviewer.sh`

- [ ] **Step 1: Add fake Claude and Codex executables to the test library**

Append these functions to `tests/external-review/test-lib.sh` before `finish_suite`:

```bash
write_fake_claude() {
    cat > "$TEST_TMP/bin/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--version" ]; then printf '2.1.235\n'; exit 0; fi
if [ "${1:-}" = "--help" ]; then
    printf '%s\n' '--safe-mode --permission-mode --output-format --session-id --tools --allowedTools'
    exit 0
fi
session_id=''
previous=''
if [ "$#" -gt 0 ]; then
    for argument in "$@"; do
        if [ "$previous" = '--session-id' ]; then session_id="$argument"; fi
        previous="$argument"
    done
fi
[ -n "$session_id" ] || { printf 'missing fake session id\n' >&2; exit 64; }
log_base="${FAKE_LOG_DIR:?}/claude-$session_id"
printf '%s\n' "$*" > "$log_base.args"
cat > "$log_base.stdin"
sleep "${FAKE_REVIEW_DELAY:-0}"
if [ "${FAKE_REVIEW_EXIT:-0}" -ne 0 ]; then
    if [ "${FAKE_RESULT_BEFORE_EXIT:-0}" -eq 1 ]; then
        printf '[{"type":"result","session_id":"fake","result":"fake Claude partial review"}]\n'
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
if [ "${1:-}" = "--version" ]; then printf 'codex-test\n'; exit 0; fi
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
if [ "$#" -gt 0 ]; then
    for argument in "$@"; do
        if [ "$previous" = '-o' ] || [ "$previous" = '--output-last-message' ]; then output="$argument"; fi
        previous="$argument"
    done
fi
[ -n "$output" ] || { printf 'missing fake output path\n' >&2; exit 64; }
run_name="$(basename "$(dirname "$output")")"
log_base="${FAKE_LOG_DIR:?}/codex-$run_name"
printf '%s\n' "$*" > "$log_base.args"
if [ "${2:-}" != 'review' ]; then cat > "$log_base.stdin"; fi
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
```

- [ ] **Step 2: Add failing tests for preflight and a normal Claude run**

Append calls in `run-tests.sh` after `begin_suite` to initialize fakes:

```bash
export FAKE_LOG_DIR="$TEST_TMP/fake-logs"
mkdir -p "$FAKE_LOG_DIR"
write_fake_claude
write_fake_codex
```

Add these tests before the final calls:

```bash
test_check_profiles() {
    local profile
    for profile in claude-prompt codex-prompt codex-review; do
        run_captured "$RUNNER" check "$profile"
        assert_eq "0" "$CAPTURE_RC" "$profile passes capability preflight"
    done
    pass "all fixed profiles pass capability preflight"
}

test_normal_claude_run() {
    local prompt="$TEST_TMP/prompt.txt"
    local run_dir
    printf 'review this document\n' > "$prompt"
    run_captured "$RUNNER" start claude-prompt 'document|project|spec' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "normal Claude start succeeds"
    run_dir="$(printf '%s\n' "$CAPTURE_OUTPUT" | sed -n 's/^RUN_DIR=//p')"
    run_captured "$RUNNER" wait "$run_dir" 10
    assert_eq "0" "$CAPTURE_RC" "normal Claude wait reaches a terminal state"
    assert_eq "exited" "$(cat "$run_dir/state")" "normal Claude run reaches exited"
    assert_eq "0" "$(cat "$run_dir/exit-code")" "normal Claude exit code is recorded"
    assert_file_contains "$run_dir/result" 'fake Claude review' "Claude native JSON is retained"
    local fake_log="$FAKE_LOG_DIR/claude-$(cat "$run_dir/provider-session")"
    assert_eq "review this document" "$(cat "$fake_log.stdin")" "prompt reaches reviewer stdin"
    assert_file_contains "$fake_log.args" '--safe-mode' "Claude safe mode reaches the CLI"
    assert_file_contains "$fake_log.args" '--permission-mode dontAsk' "Claude dontAsk reaches the CLI"
    assert_file_contains "$fake_log.args" '--output-format json' "Claude JSON output reaches the CLI"
    assert_file_contains "$fake_log.args" '--session-id' "Claude session ID reaches the CLI"
    assert_file_contains "$fake_log.args" 'Bash(git diff *)' "Claude allow-list reaches the CLI intact"
}
```

Add separate failing tests before implementation for:

- A slow `claude-prompt` run where `wait RUN 1` returns `3`, reports `STATE=running`, and leaves the reviewer alive.
- A non-zero Claude run with `FAKE_RESULT_BEFORE_EXIT=1`, proving `state=exited`, the exact non-zero `exit-code`, and substantive native output coexist.
- A `codex-prompt` run proving stdin, `-s read-only`, `--skip-git-repo-check`, and `-o` reach the fake.
- Three `codex-review` runs proving the exact `--uncommitted`, `--base main`, and `--commit <fixture-sha>` arguments, with no stdin prompt and no sandbox flag.
- Unknown operations, missing arguments, unknown profiles, unreadable prompt files, `uncommitted` with a value, `base` without a value, `commit` without a value, and any attempt to add a prompt to `codex-review`; assert exit `64` for usage or invalid combinations.
- A prompt and working directory containing spaces.
- A `SUPERARTES_REVIEW_TMPDIR` that is itself a symlink, proving `start`, printed `RUN_DIR`, `status`, `wait`, and `cleanup` all use one canonical path. This is the Linux regression for macOS's `/var` to `/private/var` temp-path behavior.
- Partial or truncated Claude JSON retained byte-for-byte without helper parsing.

Every adapter invocation must use `run_captured` and assert `CAPTURE_RC`, so one expected failure cannot abort the suite before its assertions execute. Find the per-run fake logs from the run's provider session or run-directory basename; never use a shared overwrite-prone invocation log.

Run and confirm RED because `check`, `start`, and `wait` are not implemented.

- [ ] **Step 3: Create the adapter header, dispatch, atomic writer, UUID generator, and help**

Create `skills/external-review/invoke-reviewer.sh` with this structure:

```bash
#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
RAW_REVIEW_ROOT="${SUPERARTES_REVIEW_TMPDIR:-${TMPDIR:-/tmp}/superartes-external-review}"
mkdir -p "$RAW_REVIEW_ROOT"
REVIEW_ROOT="$(cd "$RAW_REVIEW_ROOT" && pwd -P)"

usage() {
    cat <<'USAGE'
Usage:
  invoke-reviewer.sh check <claude-prompt|codex-prompt|codex-review>
  invoke-reviewer.sh start [--after-terminal RUN] PROFILE REVIEW_KEY WORK_DIR PROFILE_ARGS...
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

new_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return
    fi
    local hex variant
    hex="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    variant="$(printf '%x' "$(( (16#${hex:16:1} & 3) | 8 ))")"
    printf '%s-%s-4%s-%s%s-%s\n' \
        "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
        "$variant" "${hex:17:3}" "${hex:20:12}"
}

require_text() {
    local haystack="$1"
    local needle="$2"
    case "$haystack" in
        *"$needle"*) ;;
        *) printf 'Required capability missing: %s\n' "$needle" >&2; return 2 ;;
    esac
}
```

After creating the script, run `chmod +x skills/external-review/invoke-reviewer.sh` and verify `git ls-files --stage` records mode `100755` after staging.

The final dispatch at the bottom must be:

```bash
case "${1:---help}" in
    --help|-h) usage ;;
    check) shift; check_profile "$@" ;;
    start) shift; start_run "$@" ;;
    status) shift; status_run "$@" ;;
    wait) shift; wait_run "$@" ;;
    cancel) shift; cancel_run "$@" ;;
    cleanup) shift; cleanup_run "$@" ;;
    _supervise) shift; supervise_run "$@" ;;
    *) usage >&2; exit 64 ;;
esac
```

- [ ] **Step 4: Implement profile preflight**

Add:

```bash
check_profile() {
    [ "$#" -eq 1 ] || return 64
    local profile="$1"
    local help
    case "$profile" in
        claude-prompt)
            command -v claude >/dev/null 2>&1 || return 127
            claude --version >/dev/null
            help="$(claude --help)"
            for flag in --safe-mode --permission-mode --output-format --session-id --tools --allowedTools; do
                require_text "$help" "$flag"
            done
            ;;
        codex-prompt)
            command -v codex >/dev/null 2>&1 || return 127
            codex --version >/dev/null
            help="$(codex exec --help)"
            for flag in --sandbox --skip-git-repo-check --output-last-message; do
                require_text "$help" "$flag"
            done
            ;;
        codex-review)
            command -v codex >/dev/null 2>&1 || return 127
            codex --version >/dev/null
            help="$(codex exec review --help)"
            for flag in --uncommitted --base --commit --skip-git-repo-check --output-last-message; do
                require_text "$help" "$flag"
            done
            ;;
        *) printf 'Unknown profile: %s\n' "$profile" >&2; return 64 ;;
    esac
}
```

- [ ] **Step 5: Implement minimal run creation and the profile-specific supervisor**

Add `start_run` so it validates the profile and working directory, copies prompt input into `prompt`, writes common metadata, launches a detached `_supervise`, and waits up to five seconds for `state` to become `running`, `exited`, or `launch-failed`. Its positional profile arguments are fixed:

```text
claude-prompt REVIEW_KEY WORK_DIR PROMPT_FILE
codex-prompt  REVIEW_KEY WORK_DIR PROMPT_FILE
codex-review  REVIEW_KEY WORK_DIR uncommitted
codex-review  REVIEW_KEY WORK_DIR base BASE_REF
codex-review  REVIEW_KEY WORK_DIR commit COMMIT_SHA
```

For prompt profiles, reject anything other than exactly one readable regular prompt file. For `codex-review`, reject any scope kind other than `uncommitted`, `base`, or `commit`, reject a value for `uncommitted`, and require exactly one value for `base` or `commit`. Copy the prompt before launching so the caller may remove its temporary input after `start` returns.

Create each run as the canonical path `$REVIEW_ROOT/run-<run-id>` and print that identical path everywhere. A successful `start` prints exactly `STATE=<state>`, `RUN_DIR=<canonical-path>`, and `RUN_ID=<uuid>`. Write each metadata artifact atomically except `result` and logs, which belong to the reviewer process. Before launch, create `marker`, `run-path`, `review-key`, `profile`, `provider`, `run-id`, `provider-session`, `work-dir`, and either `prompt` or `scope-kind` plus `scope-value`. Always create `scope-value`; it is an empty UTF-8 file for `uncommitted`. Set `marker` to `superartes-external-review:<run-id>`. Use a separate generated UUID as `provider-session` for Claude and `not-applicable` for Codex. Store timestamps using `date +%s`, never Bash 5-only `$EPOCHSECONDS`. The supervisor writes `started-at` only after it has established the reviewer PID and start identity, so elapsed time excludes approval and setup delay.

Use this exact profile command builder inside `supervise_run`:

```bash
run_profile() {
    local run_dir="$1"
    local profile work_dir session_id scope_kind scope_value
    profile="$(cat "$run_dir/profile")"
    work_dir="$(cat "$run_dir/work-dir")"
    session_id="$(cat "$run_dir/provider-session")"
    cd "$work_dir"
    set -m
    case "$profile" in
        claude-prompt)
            claude -p --safe-mode --permission-mode dontAsk \
                --tools "Read,Glob,Grep,Bash" \
                --allowedTools "Read,Glob,Grep,Bash(git diff *),Bash(git status *),Bash(git rev-parse *),Bash(git cat-file *),Bash(git show *),Bash(git log *)" \
                --output-format json --session-id "$session_id" \
                < "$run_dir/prompt" > "$run_dir/result" 2> "$run_dir/reviewer-log" &
            ;;
        codex-prompt)
            codex exec - -s read-only --skip-git-repo-check \
                -o "$run_dir/result" \
                < "$run_dir/prompt" > "$run_dir/reviewer-output" \
                2> "$run_dir/reviewer-log" &
            ;;
        codex-review)
            scope_kind="$(cat "$run_dir/scope-kind")"
            scope_value="$(cat "$run_dir/scope-value")"
            if [ "$scope_kind" = uncommitted ]; then
                codex exec review --uncommitted --skip-git-repo-check \
                    -o "$run_dir/result" > "$run_dir/reviewer-output" \
                    2> "$run_dir/reviewer-log" &
            else
                codex exec review "--$scope_kind" "$scope_value" \
                    --skip-git-repo-check -o "$run_dir/result" \
                    > "$run_dir/reviewer-output" 2> "$run_dir/reviewer-log" &
            fi
            ;;
    esac
    REVIEWER_PID=$!
}
```

At the start of `supervise_run`, atomically write the supervisor's own `$$` and `process_start_identity $$` as `supervisor-pid` and `supervisor-start`. Do not trust the launcher's `$!` as the supervisor PID because `setsid` may fork. After `run_profile`, write reviewer PID, reviewer start identity, reviewer process group, and `started-at`, then atomically write `running`. `process_start_identity` must use `LC_ALL=C ps` for stable comparison. If a very fast child is already a zombie, it still has a start identity until `wait` reaps it.

Wait without `set -e`, record the exit code and `completed-at`, and write `exited` unless a `cancel-requested` marker exists, in which case write `cancelled`. If the reviewer cannot be launched or its identity cannot be established before any child exists, write diagnostics, `completed-at`, and `launch-failed` without fabricating reviewer metadata.

Launch the POSIX supervisor with an independent process group:

```bash
launch_supervisor() {
    local run_dir="$1"
    if [ "${SUPERARTES_REVIEW_NO_SETSID:-0}" -ne 1 ] && command -v setsid >/dev/null 2>&1; then
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
```

After launch, `start_run` waits up to ten seconds for `running`, `exited`, or `launch-failed`. If the supervisor identity is valid but no state appears within that guard, retain the run and lock, print `STATE=indeterminate` plus `RUN_DIR`, and return `4`; never delete or retry. If the supervisor disappears before publishing a state, record `launch-failed`. Tests force both launch paths with `SUPERARTES_REVIEW_NO_SETSID=1` and verify the same handshake.

Add these validation helpers before status and wait. Task 3 will add adversarial cleanup coverage without changing their contract:

```bash
canonical_review_root() {
    mkdir -p "$REVIEW_ROOT"
    (cd "$REVIEW_ROOT" && pwd -P)
}

validate_run() {
    local requested="${1:?run directory required}"
    local canonical root
    [ ! -L "$requested" ] || return 65
    canonical="$(cd "$requested" 2>/dev/null && pwd -P)" || return 65
    root="$(canonical_review_root)" || return 65
    case "$canonical" in "$root"/run-*) ;; *) return 65 ;; esac
    [ "$(cat "$canonical/run-path" 2>/dev/null)" = "$canonical" ] || return 65
    [ "$(cat "$canonical/marker" 2>/dev/null)" = \
        "superartes-external-review:$(cat "$canonical/run-id" 2>/dev/null)" ] || return 65
}

process_start_identity() {
    LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//'
}

reviewer_identity_matches() {
    local run_dir="$1"
    local pid expected actual
    pid="$(cat "$run_dir/reviewer-pid" 2>/dev/null)" || return 1
    expected="$(cat "$run_dir/reviewer-start" 2>/dev/null)" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    actual="$(process_start_identity "$pid")"
    [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

supervisor_identity_matches() {
    local run_dir="$1"
    local pid expected actual
    pid="$(cat "$run_dir/supervisor-pid" 2>/dev/null)" || return 1
    expected="$(cat "$run_dir/supervisor-start" 2>/dev/null)" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    actual="$(process_start_identity "$pid")"
    [ -n "$actual" ] && [ "$actual" = "$expected" ]
}
```

- [ ] **Step 6: Implement mechanical status and chunked wait**

Add:

```bash
is_terminal_state() {
    case "$1" in exited|launch-failed|cancelled) return 0 ;; *) return 1 ;; esac
}

status_run() {
    local run_dir="${1:?run directory required}"
    validate_run "$run_dir"
    local state
    state="$(cat "$run_dir/state")"
    if is_terminal_state "$state"; then
        printf 'STATE=%s\nRUN_DIR=%s\n' "$state" "$run_dir"
        return 0
    fi
    if [ "$state" = running ] && reviewer_identity_matches "$run_dir"; then
        printf 'STATE=running\nRUN_DIR=%s\n' "$run_dir"
        return 3
    fi
    if supervisor_identity_matches "$run_dir"; then
        local grace=0
        while [ "$grace" -lt 3 ]; do
            sleep 1
            state="$(cat "$run_dir/state")"
            if is_terminal_state "$state"; then
                printf 'STATE=%s\nRUN_DIR=%s\n' "$state" "$run_dir"
                return 0
            fi
            if [ "$state" = running ] && reviewer_identity_matches "$run_dir"; then
                printf 'STATE=running\nRUN_DIR=%s\n' "$run_dir"
                return 3
            fi
            grace=$((grace + 1))
        done
    fi
    printf 'STATE=indeterminate\nRUN_DIR=%s\n' "$run_dir"
    return 4
}

wait_run() {
    local run_dir="${1:?run directory required}"
    local timeout="${2:?timeout required}"
    local started=$SECONDS state
    validate_run "$run_dir"
    while [ $((SECONDS - started)) -lt "$timeout" ]; do
        state="$(cat "$run_dir/state")"
        if is_terminal_state "$state"; then
            status_run "$run_dir"
            return 0
        fi
        if ! reviewer_identity_matches "$run_dir"; then
            status_run "$run_dir"
            return 4
        fi
        sleep 1
    done
    status_run "$run_dir"
    return 3
}
```

Expand `status_run`'s output in both branches to include `PROFILE`, `PROVIDER`, `STARTED_AT`, `ELAPSED_SECONDS`, `RESULT`, `REVIEWER_OUTPUT`, `REVIEWER_LOG`, `SUPERVISOR_OUTPUT`, and `SUPERVISOR_LOG`. Include `REVIEWER_PID` only when recorded and `EXIT_CODE` plus `COMPLETED_AT` only when recorded. Calculate elapsed time from `started-at` to `completed-at` for terminal runs and from `started-at` to the current epoch for live runs. Tests must assert these field names and must prove that a delayed caller approval cannot be included because no `started-at` exists until the reviewer is established.

- [ ] **Step 7: Run POSIX tests and verify GREEN**

Run:

```bash
bash -n skills/external-review/invoke-reviewer.sh
bash tests/external-review/run-tests.sh
```

Expected: all Task 1 and Task 2 tests pass with no live fake reviewer processes left behind.

- [ ] **Step 8: Run existing fast regressions**

Run:

```bash
python3 tests/codex-plugin/validate-codex-plugin.py
(cd tests/brainstorm-server && npm test)
```

Expected: both suites pass.

- [ ] **Step 9: Commit the first releasable checkpoint**

Invoke `superartes:commit-message`, then stage only:

```bash
git add tests/external-review skills/external-review/invoke-reviewer.sh
git commit
```

Suggested subject: `Add managed POSIX reviewer lifecycle core`

---

### Task 3: Add mechanical locking, attempt linking, cancellation, and safe cleanup

**Files:**
- Modify: `tests/external-review/run-tests.sh`
- Modify: `tests/external-review/test-lib.sh`
- Modify: `skills/external-review/invoke-reviewer.sh`

- [ ] **Step 1: Add failing tests for duplicate prevention and terminal linking**

Add tests that:

1. Start a slow `claude-prompt` run with key `document|same`.
2. Call `start` again with the same key and assert exit code `12` plus `RUN_DIR=<first>`.
3. Wait for the first run to exit.
4. Assert an unlinked start still exits `12`.
5. Start with `--after-terminal <first-run>` and assert `previous-run` contains the first path.

Use:

```bash
test_duplicate_review_key() {
    local prompt="$TEST_TMP/duplicate-prompt.txt"
    local first duplicate_output duplicate_rc
    printf 'review once\n' > "$prompt"
    run_captured env FAKE_REVIEW_DELAY=3 "$RUNNER" start \
        claude-prompt 'document|same' "$TEST_TMP" "$prompt"
    assert_eq "0" "$CAPTURE_RC" "first matching review starts"
    first="$(printf '%s\n' "$CAPTURE_OUTPUT" | sed -n 's/^RUN_DIR=//p')"
    run_captured "$RUNNER" start \
        claude-prompt 'document|same' "$TEST_TMP" "$prompt"
    duplicate_output="$CAPTURE_OUTPUT"
    duplicate_rc="$CAPTURE_RC"
    assert_eq "12" "$duplicate_rc" "matching outstanding review is refused"
    assert_string_contains "$duplicate_output" "RUN_DIR=$first" "existing run is returned"
}
```

Run and confirm RED.

- [ ] **Step 2: Add an atomic registry lock and exact-key scan**

Implement:

```bash
acquire_registry() {
    mkdir -p "$REVIEW_ROOT"
    local attempts=0
    until mkdir "$REVIEW_ROOT/.registry-lock" 2>/dev/null; do
        if registry_owner_is_dead; then
            rm -f -- "$REVIEW_ROOT/.registry-lock/owner-pid" \
                "$REVIEW_ROOT/.registry-lock/owner-start"
            rmdir "$REVIEW_ROOT/.registry-lock" 2>/dev/null || true
        fi
        attempts=$((attempts + 1))
        [ "$attempts" -lt 100 ] || return 75
        sleep 0.05
    done
    write_atomic "$REVIEW_ROOT/.registry-lock/owner-pid" "$$"
    write_atomic "$REVIEW_ROOT/.registry-lock/owner-start" \
        "$(process_start_identity $$)"
}

release_registry() {
    rm -f -- "$REVIEW_ROOT/.registry-lock/owner-pid" \
        "$REVIEW_ROOT/.registry-lock/owner-start"
    rmdir "$REVIEW_ROOT/.registry-lock" 2>/dev/null || true
}

find_matching_runs() {
    local review_key="$1"
    local candidate
    for candidate in "$REVIEW_ROOT"/run-*; do
        [ -d "$candidate" ] || continue
        [ -f "$candidate/review-key" ] || continue
        if [ "$(cat "$candidate/review-key")" = "$review_key" ]; then
            printf '%s\n' "$candidate"
        fi
    done
}
```

`registry_owner_is_dead` removes nothing unless both owner files exist, the recorded PID is absent or has a different `LC_ALL=C ps -o lstart=` identity, and the current process failed to acquire the lock. An ownerless or malformed lock is retained and produces exit `75`; document its exact manual diagnostic and `rmdir` recovery rather than guessing that it is stale. Add a planted dead-owner test.

Hold this lock only while checking all existing matching keys and creating new metadata. Use a trap to release it on every start-path exit. The selection algorithm is mechanical:

1. Collect every exact-key match; never return the first glob match.
2. If any match is non-terminal, return `12` with that `RUN_DIR`. More than one non-terminal match is invariant corruption: return `4` and list all of them.
3. For terminal matches, derive the chain tail as the matching path not named by another matching run's `previous-run`. Refuse an unlinked start with `12` and return that tail.
4. Permit `--after-terminal RUN` only when every matching run is terminal, `RUN` is the unique chain tail, its key matches exactly, and its artifacts have been retained. Record it in the new run's `previous-run`.
5. If the chain has zero or multiple tails, return `4` without launching.

Add a regression: finish attempt one, start linked attempt two slowly, then issue an unlinked third start. It must return attempt two, never attempt one, and only one reviewer may be alive.

- [ ] **Step 3: Add failing tests for cancellation and process identity**

The fake CLI should optionally spawn a child sleep process and record its PID. Tests must assert:

- `cancel` changes the final state to `cancelled`.
- Reviewer and fake child are absent after cancellation.
- A forged reviewer-start token makes `status` return `4` and `indeterminate` rather than signalling an unrelated PID.
- The recorded reviewer process group equals reviewer PID on the job-control path.
- When a test-only fake forces a mismatched process group, cancellation signals only the validated reviewer PID and records that tree-wide cancellation was unavailable.
- A terminal state is trusted before PID liveness, preventing PID reuse from reverting it to running.
- Killing only the validated supervisor mid-run makes `status` return `4` and preserves every reviewer artifact.
- A zero-delay reviewer never produces a transient `indeterminate`; status re-reads terminal state during its bounded grace interval.
- Empty `result` while a slow reviewer is alive remains `running`, never failure.
- Two distinct review keys can run concurrently without sharing fake logs or locks.
- Signal termination records a terminal state and exact exit evidence.
- Bash reads `contract.txt` and asserts the advertised operations/profiles plus the applicable artifact set, matching the PowerShell parity strategy.
- A nested launcher with distinctive stdin proves supervisor stdin is detached while the retained prompt alone reaches reviewer stdin.

Run and confirm RED.

- [ ] **Step 4: Implement validated process-group cancellation**

Keep the guarded `process_start_identity`, `reviewer_identity_matches`, and `supervisor_identity_matches` definitions from Task 2; do not redefine them. The supervisor records `reviewer-pgid` with `LC_ALL=C ps -o pgid= -p "$REVIEWER_PID"` after launch.

`cancel_run` validates the run, checks terminal state first, writes `cancel-requested`, and verifies reviewer PID plus start identity immediately before signalling. If recorded PGID equals the validated reviewer PID, send `TERM` to that negative PGID. If it differs, send `TERM` only to the validated PID and append a diagnostic rather than risking an unrelated process group. Wait three seconds, revalidate the same target, then escalate to `KILL` only if it remains alive. The supervisor records `cancelled`; cancellation never deletes evidence. If any identity check fails, signal nothing and return `4` with `STATE=indeterminate`.

- [ ] **Step 5: Add failing adversarial cleanup tests**

Test all of these:

- Running runs cannot be cleaned.
- A symlink to a valid run is rejected.
- A copied run directory fails because recorded canonical path differs.
- A directory outside `REVIEW_ROOT` is rejected.
- A wrong marker token is rejected.
- An unknown extra file prevents final `rmdir`, preserving evidence.
- A normal terminal run is removed without affecting a sibling run.

Run and confirm RED.

- [ ] **Step 6: Implement hardened validation and cleanup**

Keep the Task 2 validation contract and test it against all adversarial cases. In particular, validation must enforce:

```bash
validate_run() {
    local requested="${1:?run directory required}"
    [ ! -L "$requested" ] || return 65
    local canonical root
    canonical="$(cd "$requested" 2>/dev/null && pwd -P)" || return 65
    root="$(canonical_review_root)" || return 65
    case "$canonical" in "$root"/run-*) ;; *) return 65 ;; esac
    [ "$(cat "$canonical/run-path" 2>/dev/null)" = "$canonical" ] || return 65
    [ "$(cat "$canonical/marker" 2>/dev/null)" = \
        "superartes-external-review:$(cat "$canonical/run-id" 2>/dev/null)" ] || return 65
}
```

`cleanup_run` refuses `running` and `indeterminate`, removes only the exact documented artifact list from `contract.txt`, and calls `rmdir` without `-r`. Unknown files therefore preserve the directory and produce exit `66`. It removes no global directory and does not delete another matching attempt.

- [ ] **Step 7: Add supervisor-detachment regression tests**

Launch a nested Bash under an isolated process group with `setsid bash -c '…'`, capture that PGID, and assert it differs from the test runner's own PGID before signalling anything. Have the nested shell call `start`, capture its run path, then send `HUP` only to the validated nested-shell group. Assert the detached reviewer reaches `exited` and writes its exit status. Repeat the full lifecycle with `SUPERARTES_REVIEW_NO_SETSID=1` to exercise the macOS fallback on Linux. Never signal the test runner's process group and never make this test optional.

Run and confirm these fail if the independent process-group setup is removed.

- [ ] **Step 8: Run all POSIX and existing fast tests**

Run:

```bash
bash -n skills/external-review/invoke-reviewer.sh
bash tests/external-review/run-tests.sh
python3 tests/codex-plugin/validate-codex-plugin.py
(cd tests/brainstorm-server && npm test)
```

Expected: all pass and `ps` shows no fake reviewer left running.

- [ ] **Step 9: Commit the hardened POSIX lifecycle**

Invoke `superartes:commit-message`, then:

```bash
git add skills/external-review/invoke-reviewer.sh tests/external-review
git commit
```

Suggested subject: `Enforce one managed reviewer per review request`

---

### Task 4: Implement the PowerShell adapter and native Windows contract tests

**Files:**
- Create: `tests/external-review/Test-Lib.ps1`
- Create: `tests/external-review/Run-Tests.ps1`
- Create: `skills/external-review/invoke-reviewer.ps1`
- Modify: `tests/external-review/README.md`
- Modify: `.gitattributes`

- [ ] **Step 1: Add explicit LF handling**

Append to `.gitattributes`:

```gitattributes
# PowerShell source is kept LF like the rest of the plugin text files
*.ps1 text eol=lf
```

- [ ] **Step 2: Write the PowerShell test library and fake CLI shims**

`Test-Lib.ps1` must provide `Assert-Equal`, `Assert-FileContains`, isolated `$env:SUPERARTES_REVIEW_TMPDIR`, and fake `claude.cmd` / `codex.cmd` launchers backed by PowerShell scripts. Create the encoding everywhere with `New-Object System.Text.UTF8Encoding($false)` and use `[System.IO.File]::WriteAllText(path, text, $Utf8NoBom)`, avoiding version-dependent syntax differences.

The fake Claude must support `--help`, `--version`, stdin capture, configurable delay/exit, argument capture, and JSON output. The fake Codex must support `exec --help`, `exec review --help`, prompt stdin, scope arguments, and `-o` result output.

- [ ] **Step 3: Write the failing PowerShell parity suite**

`Run-Tests.ps1` reads `contract.txt` and asserts the same operations, profiles, states, and artifact names as Bash. Port every deterministic behavior from Tasks 2 and 3, including:

- Spaces in `$env:TEMP` and working paths.
- `.cmd` launcher resolution.
- Hidden supervisor survival after the invoking PowerShell exits.
- Parent/child process-tree cancellation through CIM.
- UTF-8 without a byte-order mark.
- Marker, reparse-point, copied-directory, and outside-root rejection.

Include a `-RunnerPath` test parameter so the final native session can first point at a deliberately absent adapter and verify that the harness reports the expected missing-runner RED before it runs against the real adapter. Do not ask Andy for a separate missing-file-only round-trip.

- [ ] **Step 4: Create the PowerShell adapter contract and profile validation**

Start `invoke-reviewer.ps1` with:

```powershell
param(
    [string] $Operation = '--help'
)

$Remaining = @($args)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RawReviewRoot = if ($env:SUPERARTES_REVIEW_TMPDIR) {
    $env:SUPERARTES_REVIEW_TMPDIR
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) 'superartes-external-review'
}
if (-not (Test-Path -LiteralPath $RawReviewRoot)) {
    [void] [System.IO.Directory]::CreateDirectory($RawReviewRoot)
}
$ReviewRoot = (Resolve-Path -LiteralPath $RawReviewRoot).ProviderPath

function Write-AtomicText {
    param([string] $Path, [string] $Value)
    $Temporary = "$Path.tmp.$PID"
    [System.IO.File]::WriteAllText($Temporary, "$Value`n", $Utf8NoBom)
    if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::Replace($Temporary, $Path, $null)
    } else {
        [System.IO.File]::Move($Temporary, $Path)
    }
}
```

Keep this as a simple script entry point. Windows PowerShell 5.1 invoked with
`powershell.exe -File` cannot populate an array-valued script parameter, while
`CmdletBinding` makes the automatic `$args` collection unavailable. The first
positional value binds to `$Operation`; the simple script's `$args` collection
retains every subsequent lifecycle argument.

Implement `Show-Usage`, `Test-Profile`, `Resolve-ReviewerCommand`, and the same public dispatch as Bash. `Test-Profile` uses `Get-Command`, invokes `--version` and profile help, and checks the same required flags.

- [ ] **Step 5: Implement the hidden supervisor and fixed profile builders**

`start` launches another PowerShell process running an internal `Supervise` operation:

```powershell
$PowerShellExe = (Get-Process -Id $PID).Path
$Arguments = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', "`"$PSCommandPath`"",
    'Supervise', "`"$RunDirectory`""
)
$Supervisor = Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments `
    -RedirectStandardOutput (Join-Path $RunDirectory 'supervisor-output') `
    -RedirectStandardError (Join-Path $RunDirectory 'supervisor-log') `
    -WindowStyle Hidden -PassThru
```

The explicit embedded quotes are required because Windows PowerShell joins `-ArgumentList` elements without quoting; the deterministic test must exercise both `$PSCommandPath` and `$RunDirectory` containing spaces. The internal supervisor, not its parent, writes its own PID and `StartTime` as `supervisor-pid` and `supervisor-start` before launching the reviewer.

The internal supervisor resolves the actual launcher returned by `Get-Command`, starts the reviewer with `-RedirectStandardInput`, `-RedirectStandardOutput`, and `-RedirectStandardError` as required by the profile, records the launched shim PID and `StartTime`, waits with `WaitForExit()`, captures `ExitCode`, and writes the terminal state. Descendants are discovered dynamically for cancellation rather than assuming a `.cmd` shim is the model process. `start` uses the same ten-second readiness handshake and exit mapping as Bash; a guard expiry retains the run and returns `4`.

For `claude-prompt`, set `$env:CLAUDE_CODE_USE_POWERSHELL_TOOL = '1'` only in the supervisor environment. Pass `--tools "Read,Glob,Grep,PowerShell"` and the exact allow-list `Read,Glob,Grep,PowerShell(git diff *),PowerShell(git status *),PowerShell(git rev-parse *),PowerShell(git cat-file *),PowerShell(git show *),PowerShell(git log *)`. Tests assert each permission reaches the fake as one intact argument. For Codex profiles, build the same fixed commands as Bash without accepting arbitrary arguments.

- [ ] **Step 6: Implement registry locking, wait, cancellation, and cleanup**

Use atomic directory creation for `.registry-lock`, owner PID plus `StartTime` stale-lock recovery, all-match chain-tail selection, `--after-terminal`, and the same return codes as Bash. Validate process identity using PID plus `StartTime` immediately before signalling.

Cancellation first snapshots descendants whose creation time is not earlier than their recorded parent's creation time. Revalidate the root, stop the root first so it cannot spawn more children, then stop the captured descendants deepest-first:

```powershell
function Get-ValidatedDescendants {
    param([int] $RootPid, [datetime] $RootStartTime)
    $All = @(Get-CimInstance Win32_Process)
    $Result = New-Object 'System.Collections.Generic.List[object]'

    function Add-Children {
        param(
            [int] $ParentPid,
            [datetime] $ParentStart,
            [object[]] $Processes,
            [System.Collections.Generic.List[object]] $Output
        )
        $Children = @($Processes | Where-Object {
            [int] $_.ParentProcessId -eq $ParentPid -and
            [datetime] $_.CreationDate -ge $ParentStart
        })
        foreach ($Child in $Children) {
            $ChildStart = [datetime] $Child.CreationDate
            Add-Children -ParentPid ([int] $Child.ProcessId) `
                -ParentStart $ChildStart -Processes $Processes -Output $Output
            $Output.Add([pscustomobject] @{
                ProcessId = [int] $Child.ProcessId
                StartTime = $ChildStart
            })
        }
    }

    Add-Children -ParentPid $RootPid -ParentStart $RootStartTime `
        -Processes $All -Output $Result
    return $Result
}

function Stop-ValidatedProcessTree {
    param([int] $RootPid, [datetime] $ExpectedStartTime)
    $Root = Get-Process -Id $RootPid -ErrorAction SilentlyContinue
    if ($null -eq $Root -or $Root.StartTime -ne $ExpectedStartTime) {
        return $false
    }
    $Descendants = @(Get-ValidatedDescendants -RootPid $RootPid -RootStartTime $ExpectedStartTime)
    Stop-Process -Id $RootPid -Force -ErrorAction SilentlyContinue
    foreach ($Child in $Descendants) {
        Stop-Process -Id $Child.ProcessId -Force -ErrorAction SilentlyContinue
    }
    return $true
}
```

If root validation fails, kill nothing and return `4`. Cleanup uses `Remove-Item -LiteralPath` only for the fixed artifact list and `Remove-Item -LiteralPath $RunDirectory` only after verifying the directory is empty. It must never use `-Recurse` on a caller-supplied run directory.

- [ ] **Step 7: Verify locally and commit a Windows test candidate**

Run:

```bash
bash tests/external-review/run-tests.sh
python3 tests/codex-plugin/validate-codex-plugin.py
git diff --check
```

Expected: pass. If `pwsh` is available, also parse and run the PowerShell files, but record that this supplements rather than replaces native Windows PowerShell 5.1.

Invoke `superartes:commit-message`, then:

```bash
git add .gitattributes skills/external-review/invoke-reviewer.ps1 tests/external-review
git commit
```

Suggested subject: `Add native PowerShell reviewer lifecycle candidate`

- [ ] **Step 8: Hand the committed candidate to Andy for one native Windows validation session**

Ask Andy how he wants the committed branch made available on his Windows machine. Do not assume permission to push; push only if he explicitly authorizes it. Once the same commit is present in a checkout path containing spaces, Andy runs:

```powershell
# Harness RED check against a deliberately absent runner - this command must fail for that reason.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/external-review/Run-Tests.ps1 -RunnerPath C:\definitely-missing\invoke-reviewer.ps1

# Complete deterministic suite against the real adapter.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/external-review/Run-Tests.ps1
```

Then, with an explicit warning that these commands require credentials, network access, user approval, and spend model tokens, run the documented native Windows live checks for `claude-prompt`, `codex-prompt`, and `codex-review`. Use a disposable Git repository and document fixture under a path containing spaces. Verify Claude's PowerShell Git permissions, all three native results, provider session identity, process-tree cancellation, and cleanup.

This is the single mandatory native Windows checkpoint. Do not claim PowerShell support complete and do not begin Task 5 until Andy reports the deterministic result and the available live-profile results. Record exact commands, commit SHA, PowerShell version, CLI versions, and outcomes in `tests/external-review/README.md`.

- [ ] **Step 9: Fix native failures test-first and commit Windows-verified parity**

For each reported defect, add or tighten the failing deterministic case before changing the adapter. Rerun the native affected case with Andy, then rerun locally:

```bash
bash tests/external-review/run-tests.sh
python3 tests/codex-plugin/validate-codex-plugin.py
git diff --check
```

If fixes or validation documentation changed tracked files, invoke `superartes:commit-message`, stage only `.gitattributes`, `skills/external-review/invoke-reviewer.ps1`, and `tests/external-review`, then commit. Suggested subject: `Verify native Windows reviewer lifecycle parity`. If no tracked files changed, retain the Task 7 candidate commit and proceed without an empty commit.

---

### Task 5: Add the lazy operational reference and deploy `external-review`

**Files:**
- Create: `skills/external-review/invoking-reviewers.md`
- Modify: `skills/external-review/SKILL.md`
- Create: `tests/skill-triggering/prompts/external-review.txt`
- Modify: `tests/skill-triggering/run-all.sh`

- [ ] **Step 1: Add and run the external-review trigger test before changing its description**

Create `tests/skill-triggering/prompts/external-review.txt`:

```text
I have finished a design specification in docs/specs/payment-reconciliation.md. Before planning implementation, please arrange an independent review by a different model family and process the feedback.
```

Register `external-review` in `tests/skill-triggering/run-all.sh`, then run:

```bash
(cd tests/skill-triggering && ./run-test.sh external-review prompts/external-review.txt 3)
```

Expected: current description should trigger. Record the exact triggered-skill list. This is a regression baseline, not the lifecycle RED already captured in Task 1.

- [ ] **Step 2: Write the shared operational reference**

Create `skills/external-review/invoking-reviewers.md` with this operational content, substituting only the adapter's finalized exit-code table if implementation adds a diagnosed code:

````markdown
# Invoking Managed Reviewers

## Select the platform adapter

- Native Windows: `invoke-reviewer.ps1`
- Linux, macOS, and WSL: `invoke-reviewer.sh`

Resolve the adapter from the absolute directory containing this reference and
its sibling `SKILL.md`; never resolve it relative to the user's project. Under
Claude Code, `${CLAUDE_PLUGIN_ROOT}/skills/external-review` is the preferred
root when available. Under Codex, use the absolute skill source directory
provided by the skill catalog. Quote every resolved path.

Run the selected adapter's `check PROFILE` before model-backed work.

## Stable review keys

- Document: `document|<canonical-project>|<canonical-documents>|<type>`
- Code: `code|<canonical-repository>|<scope-kind>|<scope-value>`

## Normal lifecycle

1. Create the prompt in a unique temporary file when the profile needs one.
2. Start the fixed profile and retain the printed `RUN_DIR`.
3. Remove only the caller-created prompt copy after start has retained it.
4. Call `wait` in chunks shorter than the host shell-tool cap.
5. On terminal state, read `state`, `exit-code`, `result`, and logs.
6. Triage substantive feedback before cleanup.
7. Call `cleanup` only after triage or diagnosed failure.

Never inspect an empty live result as failure. Never start another matching
review. `start` returns the existing run when its stable key is outstanding.

## Profiles

POSIX forms, where `$ADAPTER` is the quoted absolute script path:

```bash
"$ADAPTER" start claude-prompt REVIEW_KEY WORK_DIR PROMPT_FILE
"$ADAPTER" start codex-prompt REVIEW_KEY WORK_DIR PROMPT_FILE
"$ADAPTER" start codex-review REVIEW_KEY WORK_DIR uncommitted
"$ADAPTER" start codex-review REVIEW_KEY WORK_DIR base BASE_REF
"$ADAPTER" start codex-review REVIEW_KEY WORK_DIR commit COMMIT_SHA
"$ADAPTER" start --after-terminal PREVIOUS_RUN PROFILE REVIEW_KEY WORK_DIR PROFILE_ARGS
"$ADAPTER" status RUN_DIR
"$ADAPTER" wait RUN_DIR TIMEOUT_SECONDS
"$ADAPTER" cancel RUN_DIR
"$ADAPTER" cleanup RUN_DIR
```

Native Windows forms, where `$Adapter` is the literal absolute `.ps1` path:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start claude-prompt $ReviewKey $WorkDir $PromptFile
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-prompt $ReviewKey $WorkDir $PromptFile
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-review $ReviewKey $WorkDir uncommitted
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-review $ReviewKey $WorkDir base $BaseRef
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-review $ReviewKey $WorkDir commit $CommitSha
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter wait $RunDir $TimeoutSeconds
```

Use `--after-terminal PREVIOUS_RUN` immediately after `start` on both adapters.
Use `status`, `cancel`, and `cleanup` with the same final `$RunDir` argument.

Exit codes are: 0 terminal/accepted operation, 2 missing CLI capability, 3
still running, 4 indeterminate, 12 outstanding matching review, 64 usage, 65
invalid run, 66 cleanup evidence remains, 75 registry unavailable, and 127 CLI
unavailable. Exit 3 and 4 are lifecycle facts, not generic tool failures.

## Terminal evidence order

State and validated reviewer/supervisor identity, exit code, native result,
reviewer output and log, supervisor output and log, provider session/transcript,
then already-returned output. Substantive review anywhere means triage it and
do not retry.

Claude JSON may be one result object or a transcript-style array. In the array
form, locate the terminal item whose `type` is `result`; do not assume a
top-level `.result`. Never parse or judge output while the reviewer is live.

For `indeterminate`, inspect every artifact and process identity. Use substantive
feedback if present. Otherwise record the diagnostic and consider at most one
degraded fallback only after the original reviewer is confirmed absent. Never
retry immediately.

On native Windows, Claude Code does not provide OS-level sandboxing. Safe mode,
`dontAsk`, the restricted tool allow-list, and the review-only prompt are the
primary safeguards. Inspect `reviewer-log` for permission denials.

An ownerless registry lock is not auto-deleted. Inspect
`.registry-lock/owner-pid` and `owner-start`; only after proving no owner exists,
remove those two known files and the empty lock directory.

## Fallback

Use `--after-terminal` only after the original is terminal and all evidence
shows no usable review, or after explicit user approval. Label same-model
fallback as degraded.
````

- [ ] **Step 3: Replace external-review with the host-neutral policy**

Keep the frontmatter description limited to triggering conditions:

```yaml
---
name: external-review
description: Use when a design spec, implementation plan, or other document needs independent external review, or when the user requests a second opinion on a document
---
```

The body must contain:

```markdown
# External Document Review

Obtain a review from a different model family and harness than the controller.

## Required input

- Primary document paths and document type
- Related context documents
- Canonical project path

## Reviewer selection

| Controller | Independent profile |
|------------|---------------------|
| Claude Code / Anthropic | `codex-prompt` |
| Codex / OpenAI | `claude-prompt` |
| Unknown or conflicting | Stop and ask |

Use explicit runtime identity first, then corroborating Claude/Codex environment
markers. Executable availability never determines controller identity. A
same-model fallback is degraded, not independent.

## Prompt composition

Compose a contextual prompt covering project role, document paths, review focus,
re-review history, permission to explore read-only context, and collaborative
feedback. Do not impose a response limit, prescribe conclusions, or over-template
the review.

## Invocation

Read `invoking-reviewers.md` from this skill's absolute source directory and use
the selected managed profile. Never resolve it relative to the user's project.
One stable review key permits one outstanding review. A live process or empty
live result is never failure.

On native Windows, Claude Code has no OS-level sandbox. Safe mode, `dontAsk`,
the restricted tool allow-list, and the review-only prompt are the safeguards;
state this limitation when selecting `claude-prompt` there.

For interactive work, fifteen minutes of recorded reviewer runtime is a status
checkpoint: ask whether to continue or cancel. For autonomous work, judge a
reasonable duration from scope and complexity, and extend it when justified.

## Completion and fallback

Inspect terminal evidence in the order defined by the reference. Triage any
substantive feedback even after a non-zero exit. A second attempt requires an
unavailable CLI, demonstrated terminal failure with no review, or explicit user
approval. For `indeterminate`, follow the reference and never retry immediately.
Label same-model fallback as degraded.

## Triage and summary

Accept and apply clear improvements, reject feedback contradicted by deliberate
context, and escalate genuine judgment calls. Summarize Applied / Skipped /
Input needed. Use `superartes:commit-message` for document changes that are
committed.
```

- [ ] **Step 4: Run GREEN pressure and trigger tests**

Repeat Task 1's document scenario in a fresh context with the new skill. Expected: the agent selects `claude-prompt` under Codex, attaches to the existing run, uses `wait`, and refuses fallback while the reviewer is alive.

Append the complete GREEN response, process timestamps, and comparison with the RED behavior to `tests/external-review/pressure-scenarios.md`.

Run:

```bash
(cd tests/skill-triggering && ./run-test.sh external-review prompts/external-review.txt 3)
```

Expected: PASS.

- [ ] **Step 5: Run a real managed document review**

Use the new `claude-prompt` profile under the current Codex controller to review a small disposable document. Verify:

- `check` passes before launch.
- `start` returns one run directory and recorded runtime starts after approval.
- One short `wait` returns `3` while running or `0` if already terminal.
- Final state is `exited` with a provider session UUID and substantive native JSON.
- Cleanup succeeds only after reading the review.

Use one actual Claude session. Do not retry on empty live output.

- [ ] **Step 6: Run deterministic and plugin regressions**

Run:

```bash
bash tests/external-review/run-tests.sh
python3 tests/codex-plugin/validate-codex-plugin.py
```

Expected: pass.

- [ ] **Step 7: Commit the verified external-review skill before editing the sibling skill**

Invoke `superartes:commit-message`, then:

```bash
git add skills/external-review tests/skill-triggering \
  tests/external-review/pressure-scenarios.md
git commit
```

Suggested subject: `Make document external review provider-independent`

Do not begin Task 6 until this skill's trigger, pressure, deterministic, and real integration checks pass.

---

### Task 6: Deploy `external-code-review` against the managed lifecycle

**Files:**
- Modify: `skills/external-code-review/SKILL.md`
- Modify: `tests/skill-triggering/prompts/external-code-review.txt` only if the current trigger prompt does not cover an explicit independent-model request
- Modify: `tests/codex-plugin/validate-codex-plugin.py`

- [ ] **Step 1: Re-run the existing trigger test before editing**

Run:

```bash
(cd tests/skill-triggering && ./run-test.sh external-code-review prompts/external-code-review.txt 3)
```

Expected: PASS. Record triggered skills.

- [ ] **Step 2: Update the plugin validator contract and observe RED**

Replace the legacy `validate_external_code_review_skill` assertions for the heading `## Process (Codex host)`, the literal `claude -p`, and the literal `Do **not** pass --model` text. The new assertions must require:

- Both `codex-review` and `claude-prompt` controller mappings in `skills/external-code-review/SKILL.md`.
- A reference to `invoking-reviewers.md` resolved from the sibling skill directory.
- No `-m` or `--model` argument in either reviewer adapter's fixed profile builders; user CLI configuration continues to own model selection.
- No stale `planned, not yet wired` wording.

Run:

```bash
python3 tests/codex-plugin/validate-codex-plugin.py
```

Expected RED: the current skill body does not yet meet the new provider-profile contract. Confirm that unrelated manifest and version checks still pass.

- [ ] **Step 3: Replace duplicated host-specific shell recipes with concise policy**

Preserve the current triggering-only frontmatter description. Replace the body with these responsibilities:

```markdown
# External Code Review

Obtain an integrated code-change review from a different model family and
harness than the controller. This complements, and does not replace, per-task
`superartes:requesting-code-review` review.

## When to use

- Recommend before merging a feature and wait for the user's decision.
- Self-invoke for substantive high-risk auth, secrets, migration, deletion,
  money, concurrency, or public-interface changes.
- Use whenever the user explicitly requests independent code review.

## Scope

- Feature complete: detect actual trunk, then use `base|<trunk>`.
- Current work: use `uncommitted` and include staged, unstaged, and untracked.
- Named commit: validate and use `commit|<sha>`.

Guard the scope before starting. Stop with "nothing to review" for empty scope.

## Reviewer selection

| Controller | Independent profile |
|------------|---------------------|
| Claude Code / Anthropic | `codex-review` |
| Codex / OpenAI | `claude-prompt` |
| Unknown or conflicting | Stop and ask |

Determine host from runtime identity, never executable availability. A
same-model fallback is degraded.

## Invocation

Read `invoking-reviewers.md` from the sibling `external-review` skill's absolute
source directory; never resolve it relative to the user's project. Use a stable
code review key containing canonical repository and scope. Codex receives its
native scope. Claude receives an explicit review-only prompt with equivalent Git
commands and must report inspection evidence: commands used and relevant files
inspected.

On native Windows, Claude Code has no OS-level sandbox. Safe mode, `dontAsk`,
the restricted PowerShell Git allow-list, and the review-only prompt are the
primary safeguards; state this limitation when selecting `claude-prompt`.

Use managed `wait`; never treat an empty live result as failure. For
`indeterminate`, inspect all evidence and never retry immediately. Interactive
fifteen-minute checkpoints and autonomous scope-sensitive judgment follow the
shared document-review policy.

## Completion and triage

Inspect all terminal evidence before fallback. No Git/diff evidence means a
Claude response is not a substantive code review. Hand valid findings to
`superartes:receiving-code-review`, then report Applied / Deferred / Pushed back.
```

- [ ] **Step 4: Run GREEN pressure and trigger tests**

Repeat Task 1's code-review pressure scenario. Expected: the Codex controller selects `claude-prompt`, uses recorded reviewer runtime, attaches/waits, and does not start a second session.

Append the complete GREEN response, process timestamps, and comparison with the RED behavior to `tests/external-review/pressure-scenarios.md`.

Run the existing trigger test again and expect PASS.

- [ ] **Step 5: Run real managed code reviews for both provider profiles**

Create a disposable Git fixture with one committed base and one small uncommitted defect. Run:

1. `claude-prompt` with the exact Git-scope prompt under Codex.
2. `codex-review --uncommitted` under a Claude-controller-compatible invocation context.

For Claude, verify the review contains the required inspection evidence and a finding tied to the fixture. For Codex, verify its result and log correspond to the native uncommitted scope. Each profile starts once.

- [ ] **Step 6: Run deterministic, trigger, and plugin regressions**

Run:

```bash
bash tests/external-review/run-tests.sh
(cd tests/skill-triggering && ./run-test.sh external-code-review prompts/external-code-review.txt 3)
python3 tests/codex-plugin/validate-codex-plugin.py
```

Expected: pass.

- [ ] **Step 7: Commit the verified code-review skill**

Invoke `superartes:commit-message`, then:

```bash
git add skills/external-code-review tests/skill-triggering \
  tests/codex-plugin/validate-codex-plugin.py \
  tests/external-review/pressure-scenarios.md
git commit
```

Suggested subject: `Route code review through managed independent reviewers`

---

### Task 7: Remove superseded evidence and validate the integrated feature

**Files:**
- Remove: `skills/external-review/invoke-codex.sh`
- Remove: `claude under codex problem.md`
- Modify: `tests/external-review/README.md`

- [ ] **Step 1: Prove the legacy wrapper has no remaining consumers**

Run:

```bash
git grep -n -e 'invoke-codex\.sh' -e 'claude under codex problem' -- . \
  ':!docs/specs/2026-08-19-universal-external-review-design.md' \
  ':!docs/plans/2026-08-19-universal-external-review.md'
```

Expected: only the legacy file itself and historical documents, with no active skill or test dependency.

- [ ] **Step 2: Remove superseded files with Git**

Run:

```bash
git rm skills/external-review/invoke-codex.sh
git rm "claude under codex problem.md"
```

- [ ] **Step 3: Complete test documentation**

Update `tests/external-review/README.md` with:

- POSIX deterministic command.
- Native Windows deterministic command.
- Required manual Windows path-with-spaces run.
- Credentialed live-test commands for all three profiles.
- Explicit warning that live tests spend model tokens and require network approval.
- Artifact diagnosis and exact cleanup procedure.
- Link to GitHub issue #4 for future automated Windows CI.

- [ ] **Step 4: Run the complete local verification set**

Run:

```bash
git diff --check
bash -n skills/external-review/invoke-reviewer.sh
bash tests/external-review/run-tests.sh
python3 tests/codex-plugin/validate-codex-plugin.py
(cd tests/brainstorm-server && npm test)
(cd tests/skill-triggering && ./run-test.sh external-review prompts/external-review.txt 3)
(cd tests/skill-triggering && ./run-test.sh external-code-review prompts/external-code-review.txt 3)
```

Expected: all pass. Do not claim the complete feature is verified until Andy's Task 4 Windows results are also recorded.

- [ ] **Step 5: Inspect repository state**

Run:

```bash
git status --short
git diff --stat
git diff --cached --stat
git diff --stat main...HEAD
```

Expected: only intentional universal-review changes plus the three pre-existing unrelated untracked planning files. Do not add those files.

- [ ] **Step 6: Commit the integrated cleanup checkpoint**

Invoke `superartes:commit-message`, then:

```bash
git add tests/external-review/README.md
git commit
```

Suggested subject: `Remove superseded external review launch path`

---

### Task 8: Release documentation and version 1.5.0

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `package.json`
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `.cursor-plugin/plugin.json`
- Modify: `.codex-plugin/plugin.json`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update README workflow and dependency descriptions**

Change external-review descriptions to say:

```markdown
- **external-review** - Independent document review through a managed opposite-provider CLI: Claude Code invokes Codex, while Codex invokes Claude
- **external-code-review** - Independent managed review of code changes: native Codex review under Claude Code, equivalent Claude headless review under Codex
```

Update the optional dependency table so both Claude Code CLI and Codex CLI list both external-review skills where appropriate. Add a short native Windows note: PowerShell is supported directly and Git Bash is not required for managed review invocation.

- [ ] **Step 2: Add the 1.5.0 changelog entry**

Insert at the top after `# Changelog`:

```markdown
## [1.5.0] - 2026-08-19

### Added

- Cross-provider managed external review with stable request locks, detached supervisors, resumable waiting, native result preservation, and safe cleanup.
- Native Windows PowerShell 5.1+ adapter with the same contract as the POSIX Bash adapter.

### Changed

- `external-review` and `external-code-review` now select the opposite model provider from the active controller and share three fixed reviewer profiles.
- External review timeout decisions use recorded reviewer runtime and scope-sensitive controller judgment instead of shell-tool wall time or empty live output.

### Removed

- The superseded Codex-only wrapper and temporary Claude-under-Codex problem report after their behavior was captured in the specification and regression tests.
```

- [ ] **Step 3: Bump every synchronized version**

Change `1.4.5` to `1.5.0` in exactly:

```text
package.json
.claude-plugin/plugin.json
.claude-plugin/marketplace.json
.cursor-plugin/plugin.json
.codex-plugin/plugin.json
CLAUDE.md
```

- [ ] **Step 4: Run version and full verification**

Run:

```bash
python3 tests/codex-plugin/validate-codex-plugin.py
git diff --check
bash tests/external-review/run-tests.sh
(cd tests/brainstorm-server && npm test)
```

Expected: version validator reports all manifests at `1.5.0`; all deterministic tests pass.

Confirm Andy's native Windows test result is PASS. If it is not yet available, stop here and wait rather than committing the release.

- [ ] **Step 5: Invoke final verification and external code review**

Use `superartes:verification-before-completion`, then invoke `superartes:external-code-review` against `main...HEAD`. This is the feature's completed integrated review. Triage every substantive finding through `superartes:receiving-code-review`, add a regression test before any bug fix, and rerun the affected suite.

- [ ] **Step 6: Commit any review-driven fixes separately**

If Step 5 changes product or test files, invoke `superartes:commit-message`, stage exactly those review-driven files, and commit them before the version release. Rerun the complete affected verification and `git diff --check`. If there are no fixes, do not create an empty commit.

- [ ] **Step 7: Commit the version release**

Invoke `superartes:commit-message`. Because versions change, the subject must begin with the version:

```bash
git add README.md CHANGELOG.md package.json \
  .claude-plugin/plugin.json .claude-plugin/marketplace.json \
  .cursor-plugin/plugin.json .codex-plugin/plugin.json CLAUDE.md
git commit
```

Suggested subject: `v1.5.0 - make external review cross-provider and cross-platform`

- [ ] **Step 8: Tag locally after verifying the commit**

Run:

```bash
git status --short
git tag v1.5.0
```

Expected: only the three pre-existing unrelated untracked planning files remain. Do not push the branch or tag unless Andy explicitly asks.

---

## Independent Plan Review Record

Claude session `502300ec-1bdf-4ec9-b17e-e595c2b6a080` reviewed this plan read-only for 847 seconds. Its architecture verdict was positive; the plan needed execution corrections rather than redesign.

- Applied: validator migration, all-match attempt-chain locking, fast-exit grace handling, canonical temp paths, validated supervisor identity, safe process-group cancellation, stale registry ownership, full three-profile deterministic coverage, per-run fake logs, native Windows quoting and process-tree validation, one explicit Windows handoff, installed-skill path resolution, Claude JSON-array handling, `indeterminate` policy, and a separate commit path for final review fixes.
- Skipped: a retroactive `1.4.5` changelog entry because it is unrelated pre-existing history; changing the exercised comma-separated Claude allow-list to repeated arguments because the installed CLI and the successful independent review already verified the combined form.
- Input needed: none for implementation. Task 4 deliberately stops for Andy's chosen Windows transfer method and native validation result.

---

## Definition of Done

- RED pressure evidence was observed before either skill edit.
- Each adapter behavior was added through a failing deterministic test.
- Bash and native PowerShell implement the same public contract and golden artifact schema.
- Andy reports the native Windows suite and real profile checks passing.
- Both skills select the opposite provider from controller identity, never executable availability.
- Stable review locks mechanically prevent duplicate active reviews.
- Detached supervisors survive the initiating shell and record terminal state.
- Empty live output and approval-inclusive wall time cannot trigger fallback.
- Same-model fallback is explicitly labeled degraded.
- Legacy wrapper and temporary problem report are removed only after tests cover their lessons.
- Existing plugin, trigger, and brainstorm-server tests pass.
- Independent integrated code review is processed.
- All version files and release documentation are synchronized at `1.5.0`.
- The version commit is tagged locally as `v1.5.0`; nothing is pushed without explicit approval.
