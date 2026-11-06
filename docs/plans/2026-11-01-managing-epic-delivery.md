# Managing Epic Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:subagent-driven-development (recommended) or superartes:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `managing-epic-delivery` skill (Delivery Manager role: refines and decomposes an epic, sequences its PBIs and briefs executors) and the small hooks in `brainstorming`, `writing-plans`, `using-feature-branches` and `finishing-a-development-branch` that let a fresh executor session pick up a brief and report back after the user accepts the work.

**Architecture:** Skills are Markdown prose that agents execute. The new skill plus two templates hold the manager's workflow; existing skills gain short, conditional hooks; the finishing hook is a one-line gate in `SKILL.md` that sends the agent to a new supporting file `handover.md`. Tests are a deterministic Bash suite (fixtures and protocol strings) plus live headless `claude -p` scenarios run against throw-away toy repositories.

**Tech Stack:** Markdown skills, Bash test scripts, `git`, `jq`, `python3` (UUIDs), Claude Code CLI (`claude -p`), Codex CLI (one review step).

**Spec:** `docs/specs/2026-11-01-managing-epic-delivery-design.md`

---

## Read this first

- **Never create or use a git worktree.** One ordinary feature branch.
- **Only the controller commits**, using `superartes:commit-message`. Implementer subagents never commit. In the context of this plan remember to differentiate between implementer, controller and delivery manager. 
- The session executing this plan runs on the **installed** Superartes 1.5.1 plugin, not on this working tree. Editing `finishing-a-development-branch` and `using-feature-branches` here does not change the skills that drive this execution.
- Live tests run `claude -p` with `--plugin-dir <repository root>` and switch the installed copy off with `--settings '{"enabledPlugins":{"superartes@superartes":false}}'`, so only the working-tree skills load. Task 1 verifies that.
- **Cost control.** Live tests take minutes each and cost tokens. Every live script accepts `ONLY=<scenario>` to run one scenario. RED steps run only the named scenario; GREEN steps run the whole script once. Live tests write only under `${TMPDIR:-/tmp}/superartes-tests/managing-epic-delivery/` and print their output directory.
- **Testing approach.** Prose behaves probabilistically, so a live test is a sample of behaviour, not a proof. Tests follow risk: static checks cover only protocol strings shared across files and the word limit; live tests cover the main paths and assert on git and file outcomes wherever possible; the rarer paths are covered by the two-family prose review (Task 8) and the pilot (Task 9). Live tests are a development tool, run when the skill they cover changes, not a permanent suite. Do not add scenarios beyond those in this plan.
- **Infrastructure failures are not results.** `run_turn` aborts the script with exit status 2 and the words `INFRASTRUCTURE FAILURE` when `claude` exits non-zero or produces no successful result event (timeout, CLI error, turn limit). Fix the environment and re-run; never read such a run as a pass or a fail of the skill.
- Prose rules from the spec ("Writing the prose for both model families"): imperative numbered steps, conditional detail out of frequently loaded skills, no bold or capitals on conditional rules, never forbid a recovery move without a safe alternative. Copy the skill texts below exactly; they were written to these rules and to the word budget.
- A live check can fail because the model phrased something unexpectedly rather than because the skill is wrong. Before changing a skill to satisfy a failing live check, read the transcript: `jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' <file>.jsonl`. Fix the skill when the behaviour is wrong; widen the check's pattern only when the behaviour is right and the pattern too narrow, and report every such pattern change to the controller.

## File map

| Path | Change | Responsibility |
|---|---|---|
| `tests/managing-epic-delivery/lib.sh` | Create | Counters, `run_turn` (headless Claude, working-tree plugin only, infrastructure check), transcript helpers |
| `tests/managing-epic-delivery/fixtures.sh` | Create | Toy repository, file-mode epics, plans, branches |
| `tests/managing-epic-delivery/test-fixtures.sh` | Create | Deterministic self-test of the fixtures |
| `tests/managing-epic-delivery/test-plugin-isolation.sh` | Create | Live: proves the working-tree plugin is the one loaded |
| `tests/managing-epic-delivery/static-checks.sh` | Create, grows per task | Deterministic checks: shared protocol strings, word limit |
| `tests/managing-epic-delivery/test-manager.sh` | Create | Live: intake and dispatch, decomposition, resume with a pending brief |
| `tests/managing-epic-delivery/test-branch-base.sh` | Create | Live: `using-feature-branches` honours `Branch base:` and carries spec and plan |
| `tests/managing-epic-delivery/test-finishing-handover.sh` | Create | Live: accept, fallback |
| `tests/managing-epic-delivery/test-finishing-options.sh` | Create | Live: ordinary finishing unchanged, sampled several times |
| `tests/managing-epic-delivery/README.md` | Create | How to run the suite; baseline observations |
| `tests/skill-triggering/prompts/managing-epic-delivery.txt` | Create | Triggering prompt |
| `tests/skill-triggering/run-all.sh` | Modify | Add the skill; `pipefail` so failures are counted |
| `skills/managing-epic-delivery/SKILL.md` | Create | Manager workflow |
| `skills/managing-epic-delivery/brief-template.md` | Create | Brief contract |
| `skills/managing-epic-delivery/report-template.md` | Create | Report contract |
| `skills/brainstorming/SKILL.md` | Modify | Read a tracker item's brief; spec header metadata |
| `skills/writing-plans/SKILL.md` | Modify | Plan header metadata |
| `skills/using-feature-branches/SKILL.md` | Modify | Honour `Branch base:`; carry spec and plan; pull only with an upstream |
| `skills/finishing-a-development-branch/SKILL.md` | Modify | `Branch base:` first in Step 2, conditional pull, `--base` on PR, Step 2.6 gate, Step 5 pointer |
| `skills/finishing-a-development-branch/handover.md` | Create | Handover check and report steps |
| `README.md` | Modify | "Delivering an Epic" section, skills list line |
| `CLAUDE.md` | Modify | Test commands, tests directory entry |

---

### Task 1: Test harness and fixtures

**Files:**
- Create: `tests/managing-epic-delivery/lib.sh`
- Create: `tests/managing-epic-delivery/fixtures.sh`
- Create: `tests/managing-epic-delivery/test-fixtures.sh`
- Create: `tests/managing-epic-delivery/test-plugin-isolation.sh`

- [ ] **Step 1: Write the fixture self-test (it is the failing test for this task)**

Create `tests/managing-epic-delivery/test-fixtures.sh`:

```bash
#!/usr/bin/env bash
# Deterministic self-test of the shared fixtures. Needs only bash, git, python3 and jq.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/fixtures.sh"

echo "=== managing-epic-delivery: fixture self-test ==="
dir="$(scratch_dir)"
EPIC="docs/handovers/toy-epic"

# Thin epic: a goal and nothing else, to be decomposed
make_toy_repo "$dir/thin"
add_epic "$dir/thin" thin
check "thin epic exists" test -f "$dir/thin/$EPIC/epic.md"
check_not "thin epic has no acceptance criteria" grep -qi "acceptance criteria" "$dir/thin/$EPIC/epic.md"

# Fresh file-mode epic: backlog only, no Mode line, nothing dispatched
make_toy_repo "$dir/fresh"
add_epic "$dir/fresh" fresh
check "fresh epic exists" test -f "$dir/fresh/$EPIC/epic.md"
check_not "fresh epic has no Mode line" grep -q "^Mode:" "$dir/fresh/$EPIC/epic.md"
check_not "fresh epic has no briefs" compgen -G "$dir/fresh/$EPIC/[0-9][0-9]-brief-*.md"
check "toy tests pass" bash -c "cd '$dir/fresh' && ./run-tests.sh"

# Dispatched: brief 01 issued, report pending; plan with Delivery brief; feature branch
make_toy_repo "$dir/finish"
add_epic "$dir/finish" dispatched
add_plan "$dir/finish" delivery
make_feature_branch "$dir/finish"
check "dispatched epic has a Mode line" grep -q "^Mode: file" "$dir/finish/$EPIC/epic.md"
check "dispatched report is pending" grep -qx "Status: awaiting executor" "$dir/finish/$EPIC/01-report-add-tag-command.md"
check "plan carries Delivery brief" grep -q "Delivery brief:" "$dir/finish/docs/plans/2026-11-01-add-tag-command.md"
check "on the feature branch" test "$(git -C "$dir/finish" branch --show-current)" = "feature/add-tag-command"
check_not "feature not merged" git -C "$dir/finish" merge-base --is-ancestor feature/add-tag-command master

# Ordinary work: no metadata, no handovers
make_toy_repo "$dir/plain"
add_plan "$dir/plain" plain
make_feature_branch "$dir/plain"
check_not "plain plan has no Delivery brief" grep -q "Delivery brief:" "$dir/plain/docs/plans/2026-11-01-add-tag-command.md"
check_not "plain repo has no handovers" test -d "$dir/plain/docs/handovers"

# Ticket-linked work without a brief
make_toy_repo "$dir/pbi"
add_plan "$dir/pbi" pbi-only
make_feature_branch "$dir/pbi"
check "pbi-only plan has a PBI line" grep -q "PBI:" "$dir/pbi/docs/plans/2026-11-01-add-tag-command.md"
check_not "pbi-only plan has no Delivery brief" grep -q "Delivery brief:" "$dir/pbi/docs/plans/2026-11-01-add-tag-command.md"

# Branch base: plan on master names an unmerged base branch
make_toy_repo "$dir/base"
make_branch_base_fixture "$dir/base"
check "base plan names the Branch base" grep -q "Branch base:\*\* feature/add-tag-command" "$dir/base/docs/plans/2026-11-02-list-by-tag.md"
check "base fixture is on master" test "$(git -C "$dir/base" branch --show-current)" = "master"
check_not "base branch is unmerged" git -C "$dir/base" merge-base --is-ancestor feature/add-tag-command master

finish_suite
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bash tests/managing-epic-delivery/test-fixtures.sh`
Expected: an error that `lib.sh` cannot be found and a non-zero exit status.

- [ ] **Step 3: Write `lib.sh`**

Create `tests/managing-epic-delivery/lib.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for the managing-epic-delivery tests. Source this file; do not run it.
# Results are counted in global variables, never inside $( ), so no count is lost
# to a subshell.

MED_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$MED_TEST_DIR/../.." && pwd)"
PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "  [PASS] $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  [FAIL] $1"; }

# check "<description>" <command> [arguments...]: passes when the command succeeds.
check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

# check_not "<description>" <command> [arguments...]: passes when the command fails.
check_not() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then fail "$description"; else pass "$description"; fi
}

# finish_suite: prints the totals; exits non-zero on any failure, or when nothing ran.
finish_suite() {
    echo ""
    echo "Passed: $PASSED  Failed: $FAILED"
    if [ "$FAILED" -ne 0 ] || [ "$PASSED" -eq 0 ]; then
        exit 1
    fi
    exit 0
}

# want <scenario>: true when no ONLY filter is set, or ONLY names this scenario.
want() {
    [ -z "${ONLY:-}" ] || [ "$ONLY" = "$1" ]
}

# require_live_tools: stops the suite (as a failure) when a live dependency is missing.
require_live_tools() {
    local tool
    for tool in claude jq python3 git; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "FAIL: required tool '$tool' is not on PATH"
            exit 1
        fi
    done
}

new_session_id() { python3 -c 'import uuid; print(uuid.uuid4())'; }

# scratch_dir: prints a fresh directory under the test output root.
scratch_dir() {
    local root="${TMPDIR:-/tmp}/superartes-tests/managing-epic-delivery"
    mkdir -p "$root"
    mktemp -d "$root/run.XXXXXX"
}

# run_turn <repo> <session-id> <first|resume> <transcript> <prompt>
# Runs one headless Claude turn in <repo> with only the working-tree plugin enabled.
# stdout (stream-json) goes to <transcript>, stderr to <transcript>.err.
# Aborts the whole script with exit 2 unless claude exits 0 with a successful result.
run_turn() {
    local repo="$1" session="$2" mode="$3" transcript="$4" prompt="$5"
    local session_args=(--session-id "$session")
    local status=0
    if [ "$mode" = "resume" ]; then
        session_args=(--resume "$session")
    fi
    ( cd "$repo" && timeout 900 claude -p "$prompt" "${session_args[@]}" \
        --plugin-dir "$PLUGIN_DIR" \
        --settings '{"enabledPlugins":{"superartes@superartes":false}}' \
        --dangerously-skip-permissions \
        --max-turns 60 \
        --output-format stream-json --verbose ) > "$transcript" 2> "$transcript.err" || status=$?
    if [ "$status" -ne 0 ] || ! jq -e 'select(.type=="result" and .subtype=="success")' "$transcript" >/dev/null 2>&1; then
        echo "INFRASTRUCTURE FAILURE: claude turn did not complete (exit $status)."
        echo "  transcript: $transcript"
        echo "  stderr:     $transcript.err"
        exit 2
    fi
}

# assistant_text <transcript>...: every text block the assistant wrote.
assistant_text() {
    local file
    for file in "$@"; do
        jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$file" 2>/dev/null
    done
}

# text_matches <extended-regex> <transcript>...: case-insensitive search of the assistant's
# text. The text is captured first, so grep never closes a pipe on a still-writing producer.
text_matches() {
    local pattern="$1"
    shift
    local text
    text="$(assistant_text "$@")"
    grep -qiE -- "$pattern" <<< "$text"
}

# product_code_untouched <repo> <fixture-sha>: no committed, staged, unstaged or new-file
# change to the toy app since the fixture commit.
product_code_untouched() {
    local repo="$1" sha="$2"
    git -C "$repo" diff --quiet "$sha" -- src run-tests.sh README.md \
        && [ -z "$(git -C "$repo" status --porcelain -- src run-tests.sh README.md)" ]
}

# brief_snapshot <epic-dir>: names and checksums of every brief, for before/after comparison.
brief_snapshot() {
    ( cd "$1" && sha256sum [0-9]*-brief-*.md 2>/dev/null )
}

# report_filled <report-file>: no template placeholder left in the report.
report_filled() {
    ! grep -qE '<(date|short summary|merged into|scope changes|changed interfaces|candidate new|the user accepted)' "$1"
}
```

- [ ] **Step 4: Write `fixtures.sh`**

Create `tests/managing-epic-delivery/fixtures.sh`:

````bash
#!/usr/bin/env bash
# Toy-repository fixtures for the managing-epic-delivery tests. Source this file; do not run it.

TOY_EPIC_DIR="docs/handovers/toy-epic"

# make_toy_repo <dir>: a git repository on trunk 'master' with a passing test script.
make_toy_repo() {
    local repo="$1"
    mkdir -p "$repo/src"
    git -C "$repo" init -q -b master
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    cat > "$repo/README.md" <<'EOF'
# Toy notes app

A tiny shell notes tool. Run the tests with `./run-tests.sh`.
EOF
    cat > "$repo/run-tests.sh" <<'EOF'
#!/usr/bin/env bash
echo "all tests passed"
EOF
    chmod +x "$repo/run-tests.sh"
    printf '#!/usr/bin/env bash\necho "notes"\n' > "$repo/src/notes.sh"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "Initial toy app"
}

# write_pbis <with-criteria|without-criteria>: prints the PBI section shared by the epics.
write_pbis() {
    cat <<'EOF'
## PBIs

### add-tag-command: Add a tag to a note

Acceptance criteria:
- `notes.sh tag <id> <tag>` stores the tag
- Tags are stored in lowercase

### list-by-tag: List notes with a tag

Acceptance criteria:
- `notes.sh list --tag <tag>` prints only the notes with that tag

Dependencies: add-tag-command

### tag-colours: Coloured tags

EOF
    if [ "$1" = "with-criteria" ]; then
        printf 'Acceptance criteria:\n- `notes.sh list --colour` prints each tag in a fixed colour\n'
    else
        printf '(No acceptance criteria yet.)\n'
    fi
}

# write_brief <NN> <file>: a filled file-mode brief for add-tag-command.
write_brief() {
    local nn="$1" file="$2"
    cat > "$file" <<EOF
# Delivery Manager brief $nn

Epic: Notes tagging ($TOY_EPIC_DIR/epic.md)
PBI: add-tag-command — "Add a tag to a note"
Position: 1 of 3
Brief reference: $TOY_EPIC_DIR/$nn-brief-add-tag-command.md

## What to deliver

\`notes.sh tag <id> <tag>\` stores the tag. Tags are stored in lowercase.

## Context

- Epic goal: Let users tag notes and list notes by tag.
- Earlier results that matter: None
- Constraints: None

## Branch base

trunk

## Scope

The other PBIs of this epic are out of scope. If the work spills into them, record it under "Discovered work" in the report instead of doing it.

## How to work

1. If you have a task-list tool, first create an item: "Report to Delivery Manager after user acceptance — brief: $TOY_EPIC_DIR/$nn-brief-add-tag-command.md".
2. Follow the Superartes cycle with the user: brainstorming → spec → plan → execution → finishing.
3. In the spec header and the plan header, add:
   **PBI:** add-tag-command — "Add a tag to a note"
   **Delivery brief:** $TOY_EPIC_DIR/$nn-brief-add-tag-command.md
4. The PBI is done only when the user accepts it. Finishing the branch will ask the user and write the report.

## Report

Fill in $TOY_EPIC_DIR/$nn-report-add-tag-command.md.
EOF
}

# write_report <NN> <file>: a report skeleton awaiting its executor.
write_report() {
    local nn="$1" file="$2"
    cat > "$file" <<EOF
# Executor report

Answers brief: $TOY_EPIC_DIR/$nn-brief-add-tag-command.md
Status: awaiting executor
User acceptance: <date> — <the user accepted the PBI as done | the user abandoned the PBI>

## Delivered

<short summary; links to spec, plan and branch>

## Integration state

<merged into <branch> | PR open: <link> | branch <name> kept unmerged | branch discarded>

## Deviations

<scope changes agreed with the user, or "None">

## Impacts on later work

<changed interfaces, invalidated assumptions, new dependencies, or "None">

## Discovered work

<candidate new PBIs, or "None">
EOF
}

# add_epic <repo> <thin|fresh|dispatched>: a file-mode epic, committed on master.
#   thin:       a goal only, no PBIs yet
#   fresh:      backlog only, no Mode line
#   dispatched: approved sequence; brief 01 issued; report 01 pending
add_epic() {
    local repo="$1" variant="$2"
    local epic_dir="$repo/$TOY_EPIC_DIR"
    mkdir -p "$epic_dir"
    if [ "$variant" = "thin" ]; then
        printf '# Epic: Notes tagging\n\nGoal: Let users tag notes and list notes by tag.\n' > "$epic_dir/epic.md"
    elif [ "$variant" = "fresh" ]; then
        {
            printf '# Epic: Notes tagging\n\nGoal: Let users tag notes and list notes by tag.\n\n'
            write_pbis without-criteria
        } > "$epic_dir/epic.md"
    else
        {
            printf '# Epic: Notes tagging\n\nMode: file\nHandover files: committed\n\nGoal: Let users tag notes and list notes by tag.\n\n'
            write_pbis with-criteria
            printf '\n## Sequence (approved)\n\n1. add-tag-command: the other PBIs build on it\n2. list-by-tag: depends on add-tag-command\n3. tag-colours: cosmetic, last\n\n'
            printf '## Dispatch log\n\n| NN | PBI | Brief | Report | State |\n|----|-----|-------|--------|-------|\n'
            printf '| 01 | add-tag-command | 01-brief-add-tag-command.md | 01-report-add-tag-command.md | brief issued, awaiting report |\n'
        } > "$epic_dir/epic.md"
        write_brief 01 "$epic_dir/01-brief-add-tag-command.md"
        write_report 01 "$epic_dir/01-report-add-tag-command.md"
    fi
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "Add toy epic ($variant)"
}

# add_plan <repo> <delivery|pbi-only|plain>: an executed plan, committed on master.
add_plan() {
    local repo="$1" variant="$2"
    local metadata=""
    mkdir -p "$repo/docs/plans"
    case "$variant" in
        delivery)
            metadata="**PBI:** add-tag-command — \"Add a tag to a note\"
**Delivery brief:** $TOY_EPIC_DIR/01-brief-add-tag-command.md" ;;
        pbi-only)
            metadata='**PBI:** Asana 1209876543210 — "Add a tag to a note" (https://app.asana.com/0/0/1209876543210)' ;;
    esac
    cat > "$repo/docs/plans/2026-11-01-add-tag-command.md" <<EOF
# Add Tag Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:subagent-driven-development (recommended) or superartes:executing-plans to implement this plan task-by-task.

**Goal:** Add \`notes.sh tag <id> <tag>\`.

**Architecture:** One new script in \`src/\`.

**Tech Stack:** Bash

$metadata

---

### Task 1: Tag script

- [x] Create \`src/tag.sh\` that stores a lowercase tag for a note
- [x] Run \`./run-tests.sh\`
EOF
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "Add plan ($variant)"
}

# make_feature_branch <repo>: feature/add-tag-command with one commit; left checked out.
make_feature_branch() {
    local repo="$1"
    git -C "$repo" checkout -q -b feature/add-tag-command
    printf '#!/usr/bin/env bash\necho "tagged $1 as ${2,,}"\n' > "$repo/src/tag.sh"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "Add tag command"
}

# write_list_plan <file>: plan for list-by-tag whose header names the unmerged base branch.
# It has no Delivery brief line, so the handover steps stay out of the branch-base tests.
write_list_plan() {
    cat > "$1" <<'EOF'
# List By Tag Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:subagent-driven-development (recommended) or superartes:executing-plans to implement this plan task-by-task.

**Goal:** Add `notes.sh list --tag <tag>`.

**Architecture:** One new script in `src/`, using the tags written by `src/tag.sh`.

**Tech Stack:** Bash

**PBI:** list-by-tag — "List notes with a tag"
**Branch base:** feature/add-tag-command

---

### Task 1: List script

- [ ] Create `src/list.sh` that prints notes with a given tag
- [ ] Run `./run-tests.sh`
EOF
}

# make_branch_base_fixture <repo>: unmerged feature/add-tag-command; on master, the
# list-by-tag plan naming it as base. Leaves master checked out.
make_branch_base_fixture() {
    local repo="$1"
    make_feature_branch "$repo"
    git -C "$repo" checkout -q master
    mkdir -p "$repo/docs/plans"
    write_list_plan "$repo/docs/plans/2026-11-02-list-by-tag.md"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "Add list-by-tag plan"
}
````

- [ ] **Step 5: Run the self-test and watch it pass**

Run: `bash tests/managing-epic-delivery/test-fixtures.sh`
Expected: every line `[PASS]`, then `Passed: 18  Failed: 0`, exit status 0.

- [ ] **Step 6: Sabotage-check the harness**

Run: `bash -c 'source tests/managing-epic-delivery/lib.sh; finish_suite'; echo "exit=$?"`
Expected: `Passed: 0  Failed: 0` and `exit=1`. A suite where nothing ran must not pass.

Run: `bash -c 'source tests/managing-epic-delivery/lib.sh; d=$(mktemp -d); printf "%s\n" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Merge back to master\"}]}}" > "$d/t.jsonl"; text_matches "merge back" "$d/t.jsonl" && echo MATCH; text_matches "nothing here" "$d/t.jsonl" || echo NOMATCH'`
Expected: `MATCH` then `NOMATCH`.

- [ ] **Step 7: Write the plugin-isolation live test**

Create `tests/managing-epic-delivery/test-plugin-isolation.sh`:

```bash
#!/usr/bin/env bash
# Live: proves run_turn loads this working tree's skills, not the installed plugin's copy.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/fixtures.sh"
require_live_tools

echo "=== managing-epic-delivery: plugin isolation ==="
dir="$(scratch_dir)"
echo "Output: $dir"
make_toy_repo "$dir/repo"
run_turn "$dir/repo" "$(new_session_id)" first "$dir/turn.jsonl" \
    "Use the Skill tool to load superartes:writing-skills. Then reply with only the word DONE."
check "skill loaded from the working tree" grep -qF "$PLUGIN_DIR/skills/writing-skills" "$dir/turn.jsonl"
check_not "installed copy not loaded" grep -qF "plugins/cache/superartes" "$dir/turn.jsonl"
finish_suite
```

- [ ] **Step 8: Run it**

Run: `chmod +x tests/managing-epic-delivery/*.sh && bash tests/managing-epic-delivery/test-plugin-isolation.sh`
Expected: `Passed: 2  Failed: 0`. If "installed copy not loaded" fails, stop and report to the controller. Every later live result would be meaningless, so do not work around it.

- [ ] **Step 9: Commit (releasable checkpoint)**

```bash
git add tests/managing-epic-delivery/lib.sh tests/managing-epic-delivery/fixtures.sh \
        tests/managing-epic-delivery/test-fixtures.sh tests/managing-epic-delivery/test-plugin-isolation.sh
git commit   # message via superartes:commit-message
```

---

### Task 2: The `managing-epic-delivery` skill

**Files:**
- Create: `tests/managing-epic-delivery/static-checks.sh`
- Create: `tests/managing-epic-delivery/test-manager.sh`
- Create: `tests/managing-epic-delivery/README.md`
- Create: `skills/managing-epic-delivery/SKILL.md`
- Create: `skills/managing-epic-delivery/brief-template.md`
- Create: `skills/managing-epic-delivery/report-template.md`

- [ ] **Step 1: Write the static checks**

Create `tests/managing-epic-delivery/static-checks.sh`. Later tasks insert their blocks directly above the final `finish_suite` line.

```bash
#!/usr/bin/env bash
# Deterministic checks: the protocol strings several files must agree on, and the word limit.
# Do not add checks that only confirm a sentence was pasted in.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
SKILL="$PLUGIN_DIR/skills/managing-epic-delivery"

echo "=== managing-epic-delivery: static checks ==="

# --- Skill files (Task 2) ---
check "SKILL.md exists" test -f "$SKILL/SKILL.md"
check "brief template exists" test -f "$SKILL/brief-template.md"
check "report template exists" test -f "$SKILL/report-template.md"
check "name matches directory" grep -qx "name: managing-epic-delivery" "$SKILL/SKILL.md"
check "description starts with Use when" grep -q "^description: Use when" "$SKILL/SKILL.md"
check "SKILL.md under 650 words" test "$(wc -w < "$SKILL/SKILL.md")" -lt 650
check "SKILL.md names the plan heading" grep -q "Delivery Manager plan" "$SKILL/SKILL.md"
check "SKILL.md names the brief heading" grep -q "Delivery Manager brief NN" "$SKILL/SKILL.md"
check "SKILL.md names the report heading" grep -q "Executor report" "$SKILL/SKILL.md"
check "SKILL.md resumes from a Mode line" grep -q "\`Mode:\` line" "$SKILL/SKILL.md"
check "brief heading" grep -q "^# Delivery Manager brief NN" "$SKILL/brief-template.md"
check "brief asks for the Delivery brief line" grep -q "Delivery brief:" "$SKILL/brief-template.md"
check "brief asks for the Branch base line" grep -q "Branch base:" "$SKILL/brief-template.md"
check "brief asks for the task-list reminder" grep -q "Report to Delivery Manager after user acceptance" "$SKILL/brief-template.md"
check "report heading" grep -q "^# Executor report" "$SKILL/report-template.md"
check "report starts pending" grep -qx "Status: awaiting executor" "$SKILL/report-template.md"
check "report names its brief" grep -q "^Answers brief:" "$SKILL/report-template.md"
check "report has an integration state" grep -q "^## Integration state" "$SKILL/report-template.md"

finish_suite
```

- [ ] **Step 2: Write the manager scenario test**

Create `tests/managing-epic-delivery/test-manager.sh`:

```bash
#!/usr/bin/env bash
# Live scenarios for managing-epic-delivery in file mode.
#   intake:            setup, intake, approval, first dispatch (three turns)
#   decompose:         an epic with no PBIs: proposes them, adds them only once accepted
#   resume-pending:    a fresh manager finds brief 01 still awaiting its report
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/fixtures.sh"
require_live_tools

echo "=== managing-epic-delivery: manager scenarios ==="
dir="$(scratch_dir)"
echo "Output: $dir"

if want intake; then
    repo="$dir/intake"
    make_toy_repo "$repo"
    add_epic "$repo" fresh
    fixture_sha="$(git -C "$repo" rev-parse HEAD)"
    session="$(new_session_id)"

    run_turn "$repo" "$session" first "$dir/intake-1.jsonl" \
        "Act as Delivery Manager for the epic in docs/handovers/toy-epic/epic.md."
    echo "Intake, turn 1 (setup):"
    check "asks whether handover files are committed" text_matches "commit|git-?ignor" "$dir/intake-1.jsonl"
    check_not "writes no brief yet" compgen -G "$repo/docs/handovers/toy-epic/[0-9][0-9]-brief-*.md"
    check "leaves product code alone" product_code_untouched "$repo" "$fixture_sha"

    run_turn "$repo" "$session" resume "$dir/intake-2.jsonl" \
        "Commit the handover files."
    echo "Intake, turn 2 (intake and sequence):"
    check "flags the PBI without acceptance criteria" text_matches "tag-colours" "$dir/intake-1.jsonl" "$dir/intake-2.jsonl"
    check "proposes an order" text_matches "sequence|order" "$dir/intake-1.jsonl" "$dir/intake-2.jsonl"
    check "records the mode" grep -q "^Mode:" "$repo/docs/handovers/toy-epic/epic.md"
    check_not "writes no brief before approval" compgen -G "$repo/docs/handovers/toy-epic/[0-9][0-9]-brief-*.md"
    check "leaves product code alone" product_code_untouched "$repo" "$fixture_sha"

    run_turn "$repo" "$session" resume "$dir/intake-3.jsonl" \
        "Acceptance criteria for tag-colours: 'notes.sh list --colour' prints each tag in a fixed colour. The order add-tag-command, list-by-tag, tag-colours is approved. Dispatch the first PBI; its branch base is trunk."
    echo "Intake, turn 3 (dispatch):"
    brief="$(compgen -G "$repo/docs/handovers/toy-epic/01-brief-*.md" | head -1)"
    report="$(compgen -G "$repo/docs/handovers/toy-epic/01-report-*.md" | head -1)"
    check "brief 01 written" test -n "$brief"
    check "brief has the protocol heading" grep -q "^# Delivery Manager brief" "$brief"
    check "brief asks for the Delivery brief line" grep -q "Delivery brief:" "$brief"
    check "report skeleton is pending" grep -qx "Status: awaiting executor" "$report"
    check "report names its brief" grep -q "^Answers brief:" "$report"
    check "dispatch logged in epic.md" grep -q "01-brief-" "$repo/docs/handovers/toy-epic/epic.md"
    check "handover files committed on master" bash -c "[ \"\$(git -C '$repo' branch --show-current)\" = master ] && [ -z \"\$(git -C '$repo' status --porcelain -- docs/handovers)\" ]"
    check "prints the executor prompt" text_matches "Read your instructions from @docs/handovers/toy-epic/01-brief-" "$dir/intake-3.jsonl"
    check "leaves product code alone" product_code_untouched "$repo" "$fixture_sha"
fi

if want decompose; then
    repo="$dir/decompose"
    epic="$repo/docs/handovers/toy-epic/epic.md"
    make_toy_repo "$repo"
    add_epic "$repo" thin
    fixture_sha="$(git -C "$repo" rev-parse HEAD)"
    session="$(new_session_id)"

    # The slug format only makes the proposal machine-readable; it does not hint at the workflow
    run_turn "$repo" "$session" first "$dir/decompose-1.jsonl" \
        "Act as Delivery Manager for the epic in docs/handovers/toy-epic/epic.md. Commit the handover files. The goal is clear, so do not ask about it. Name each PBI you propose with a slug of the form pbi-<word>."
    proposed="$(assistant_text "$dir/decompose-1.jsonl" | grep -oE 'pbi-[a-z0-9-]+' | sort -u)"
    echo "Decompose, turn 1 (proposal):"
    check "proposes at least two PBIs" test "$(grep -c . <<< "$proposed")" -ge 2
    check_not "adds no named PBI before acceptance" grep -q "pbi-" "$epic"
    check_not "adds no PBI heading before acceptance" grep -q "^###" "$epic"
    check_not "adds no criteria before acceptance" grep -qi "acceptance criteria" "$epic"
    check_not "writes no brief" compgen -G "$repo/docs/handovers/toy-epic/[0-9][0-9]-brief-*.md"
    check "leaves product code alone" product_code_untouched "$repo" "$fixture_sha"

    run_turn "$repo" "$session" resume "$dir/decompose-2.jsonl" \
        "Your proposed PBIs are accepted: add them to the epic, each with its acceptance criteria. Do not dispatch anything yet."
    echo "Decompose, turn 2 (accepted):"
    check "every proposed PBI is in the epic" bash -c 'while read -r slug; do grep -q "$slug" "$1" || exit 1; done <<< "$2"' _ "$epic" "$proposed"
    check "criteria for every PBI" test "$(grep -ci "acceptance criteria" "$epic")" -ge "$(grep -c . <<< "$proposed")"
    check_not "dispatches nothing" compgen -G "$repo/docs/handovers/toy-epic/[0-9][0-9]-brief-*.md"
    check "leaves product code alone" product_code_untouched "$repo" "$fixture_sha"
fi

if want resume-pending; then
    repo="$dir/resume-pending"
    make_toy_repo "$repo"
    add_epic "$repo" dispatched
    fixture_sha="$(git -C "$repo" rev-parse HEAD)"
    before="$(brief_snapshot "$repo/docs/handovers/toy-epic")"
    run_turn "$repo" "$(new_session_id)" first "$dir/resume-pending.jsonl" \
        "Act as Delivery Manager for the epic in docs/handovers/toy-epic/."
    echo "Resume with a pending brief:"
    check "briefs unchanged (none added, none rewritten)" test "$(brief_snapshot "$repo/docs/handovers/toy-epic")" = "$before"
    check "names PBI 01 as outstanding" text_matches "add-tag-command" "$dir/resume-pending.jsonl"
    check "report still pending" grep -qx "Status: awaiting executor" "$repo/docs/handovers/toy-epic/01-report-add-tag-command.md"
    check "leaves product code alone" product_code_untouched "$repo" "$fixture_sha"
fi

finish_suite
```

- [ ] **Step 3: Record the baseline (RED), cheaply**

Run: `chmod +x tests/managing-epic-delivery/*.sh && bash tests/managing-epic-delivery/static-checks.sh; ONLY=intake bash tests/managing-epic-delivery/test-manager.sh`
Expected: the static checks fail (no skill yet), and the intake scenario fails at least one check. Read the three intake transcripts and write down what the agent did without the skill. Did it write code, invent a handover format, dispatch without approval, skip asking about storage? These observations go into the README in Step 4.

- [ ] **Step 4: Write the tests README with the baseline**

Create `tests/managing-epic-delivery/README.md`, replacing the three bracketed baseline bullets with the Step 3 observations (one line each, saying what the agent actually did):

````markdown
# managing-epic-delivery tests

Tests for the Delivery Manager skill and the handover hooks in `brainstorming`,
`writing-plans`, `using-feature-branches` and `finishing-a-development-branch`.

## Deterministic (seconds, no model)

```bash
tests/managing-epic-delivery/static-checks.sh   # protocol strings, word budget
tests/managing-epic-delivery/test-fixtures.sh   # toy-repository fixtures
```

## Live (minutes each, uses `claude -p` and tokens)

Run the isolation check first; the rest assume it passed.

```bash
for t in plugin-isolation manager branch-base finishing-handover finishing-options; do
    bash "tests/managing-epic-delivery/test-$t.sh" || break
done
```

These are a development tool: a live test is one sample of how a model behaved, not a proof.
Run a script when the skill it covers changes, using the table below.

`ONLY=<scenario>` runs one scenario of a script, for example
`ONLY=accept bash tests/managing-epic-delivery/test-finishing-handover.sh`.
`RUNS=<n>` sets how many times `test-finishing-options.sh` samples each case (default 3).
Exit status 2 with `INFRASTRUCTURE FAILURE` means the model run itself failed (timeout,
CLI error, turn limit): fix the environment and re-run.

| Skill text changed | Re-run |
|---|---|
| `managing-epic-delivery/*` | `test-manager.sh` |
| `brainstorming`, `writing-plans` hooks | static checks only; covered by the prose review and the pilot |
| `using-feature-branches` | `test-branch-base.sh` |
| `finishing-a-development-branch/*` | `test-finishing-handover.sh`, `test-finishing-options.sh` |

Live tests run in throw-away repositories under
`${TMPDIR:-/tmp}/superartes-tests/managing-epic-delivery/` and print that directory.
Tracker mode (Asana, JIRA) has no automated coverage; it is covered by the pilot in
`docs/plans/2026-11-01-managing-epic-delivery.md`, Task 9.

## Baseline without the skill (2026-11-01)

What an agent did when asked to "act as Delivery Manager" before the skill existed:

- [observation 1]
- [observation 2]
- [observation 3]
````

- [ ] **Step 5: Write `SKILL.md`**

Create `skills/managing-epic-delivery/SKILL.md` with exactly this content:

````markdown
---
name: managing-epic-delivery
description: Use when asked to act as Delivery Manager, to orchestrate, sequence or deliver the backlog items (PBIs, stories, tickets) of an epic one after another, or to refine or decompose an epic for delivery
---

# Managing Epic Delivery

As **Delivery Manager** you sequence an epic's PBIs and brief a fresh executor session for each; the user relays messages. This may include refining the epic, decomposing it into PBIs, adding PBIs or splitting existing ones, when needed or asked.

**Never write or edit product code or do an executor's work;** you may **read** the code when needed.

## Where state lives

- **Tracker mode** (epic in a connected tracker): status in the tracker. PBIs are subtasks of the epic, or a flat backlog linked to it by a tag or name prefix (such as "E7"). An epic comment headed `Delivery Manager plan` records these conventions and the approved sequence (latest wins). Briefs and reports are PBI comments headed `Delivery Manager brief NN` and `Executor report`.
- **File mode** (no connected tracker): `docs/handovers/<epic-slug>/` holds `epic.md`, `NN-brief-<pbi-slug>.md` and `NN-report-<pbi-slug>.md`. If they are committed, only you commit them, on trunk.

`NN` is the dispatch number, never reused. Use headings and `Status:` values verbatim.

## Start

1. Look for a `Delivery Manager plan` comment, or a `Mode:` line in `epic.md`. If found, resume: keep that mode, reconcile briefs, reports and statuses, finish outstanding work first. Never brief a PBI whose last brief has no `complete` or `abandoned` report.
2. Otherwise choose the mode. File mode: ask whether handover files are committed or git-ignored. Tracker mode: if unclear, ask once how the board shows status and whether the user prefers subtasks or a flat backlog. Always record the conventions (plan comment, or `epic.md` starting with `Mode:`).

## Intake and sequence

3. Read the epic and its PBIs. Resolve missing goals, acceptance criteria or dependencies with the user.
4. Check that the backlog is complete. Propose what it lacks: a more precise epic, PBIs for an undecomposed epic, missing PBIs, splits of PBIs too large for one executor. Apply only what the user accepts.
5. Propose an order, one reason per position, and wait for approval. Record it in the plan comment and, if the tracker has an order, there too. `epic.md` keeps the PBIs, sequence and a dispatch log.

## Dispatch, one PBI at a time

6. If the tracker has an order, compare it with the recorded sequence. If they differ, ask which to follow and record the answer.
7. If the PBI depends on unmerged work, propose a branch base (trunk, an earlier PBI's branch, or wait for its merge). The user decides.
8. Write the brief from `brief-template.md` in this skill's directory; in file mode also create the report from `report-template.md`. Log the dispatch; set the PBI in progress.
9. Print the executor prompt:
   - Tracker mode: `Work on PBI <link>. Read the Delivery Manager brief in its comments through the tracker connector; if you cannot read it, stop and tell me.`
   - File mode: `Read your instructions from @docs/handovers/<epic-slug>/NN-brief-<pbi-slug>.md`

Parallel executors: independent PBIs, separate clones sharing the handover folder.

## Receive

10. Mark a PBI done only if its report names the active brief, says `complete`, records user acceptance and fills every section. Flag reports for abandoned or superseded briefs.
11. Propose changes from its impacts and discovered work (new or split PBIs, epic edits) as in steps 3 to 5, apply what is accepted and record the revised sequence.
12. Abandoned PBI: settle its status with the user and record `abandoned` in its report or a comment.
13. Repeat from step 6 until every PBI is done or dropped.

## Close-out

14. Check results against the epic goal; draft a summary; post it to the epic if approved. Tracker mode: close the epic. File mode: offer to delete the handover folder (`git rm` if committed).
````

- [ ] **Step 6: Write `brief-template.md`**

Create `skills/managing-epic-delivery/brief-template.md`:

````markdown
# Delivery Manager brief NN

<!-- Delivery Manager: replace every <...>, delete lines that do not apply, and delete
     every HTML comment like this one.
     Tracker mode: post everything from the heading above down, with the report template
     pasted at the end, as one comment on the PBI.
     File mode: save as docs/handovers/<epic-slug>/NN-brief-<pbi-slug>.md, and create
     NN-report-<pbi-slug>.md from report-template.md. -->

Epic: <name> (<link, or epic.md path>)
PBI: <tracker> <ID> — "<title>" (<link>)
<!-- File mode instead: PBI: <pbi-slug> — "<title>" -->
Position: <n> of <total>
Brief reference: <tracker> <ID> / brief NN
<!-- File mode instead: Brief reference: <this file's path> -->

## What to deliver

Deliver the PBI's description and acceptance criteria as written in the tracker; they are authoritative.
<!-- File mode instead: paste the PBI's definition and acceptance criteria from epic.md. -->

## Context

- Epic goal: <one or two sentences>
- Earlier results that matter: <one line each, linking the spec or report, or "None">
- Constraints: <or "None">

## Branch base

<trunk | branch <name> | wait until branch <name> is merged before starting>

## Scope

The other PBIs of this epic are out of scope. If the work spills into them, record it under "Discovered work" in the report instead of doing it.

## How to work

1. If you have a task-list tool, first create an item: "Report to Delivery Manager after user acceptance — brief: <brief reference>".
2. Follow the Superartes cycle with the user: brainstorming → spec → plan → execution → finishing.
3. In the spec header and the plan header, add:
   **PBI:** <the PBI line above, without "PBI: ">
   **Delivery brief:** <brief reference>
   In the plan header only, when the branch base is not trunk, also add:
   **Branch base:** <branch>
4. The PBI is done only when the user accepts it. Finishing the branch will ask the user and write the report.

## Report

<!-- Tracker mode: paste report-template.md here; the executor posts it, filled in, as a new comment on the PBI. -->
<!-- File mode: replace both comments with the line: Fill in <report path>. -->
````

- [ ] **Step 7: Write `report-template.md`**

Create `skills/managing-epic-delivery/report-template.md`:

````markdown
# Executor report

Answers brief: <brief reference>
Status: awaiting executor
User acceptance: <date> — <the user accepted the PBI as done | the user abandoned the PBI>

## Delivered

<short summary; links to spec, plan and branch>

## Integration state

<merged into <branch> | PR open: <link> | branch <name> kept unmerged | branch discarded>

## Deviations

<scope changes agreed with the user, or "None">

## Impacts on later work

<changed interfaces, invalidated assumptions, new dependencies, or "None">

## Discovered work

<candidate new PBIs, or "None">
````

- [ ] **Step 8: Run the static checks (GREEN)**

Run: `bash tests/managing-epic-delivery/static-checks.sh`
Expected: `Passed: 18  Failed: 0`. The `SKILL.md` text above measures 649 words; a word-count failure means the file differs from Step 5.

- [ ] **Step 9: Run the manager scenarios (GREEN)**

Run: `bash tests/managing-epic-delivery/test-manager.sh`
Expected: `Failed: 0`. On a failure, follow "Read this first" on reading transcripts before changing anything. Any skill change must keep `SKILL.md` under 650 words, so re-run Step 8 after it.

- [ ] **Step 10: Commit (releasable checkpoint)**

```bash
git add skills/managing-epic-delivery tests/managing-epic-delivery/static-checks.sh \
        tests/managing-epic-delivery/test-manager.sh tests/managing-epic-delivery/README.md
git commit   # message via superartes:commit-message
```

---

### Task 3: Skill triggering

**Files:**
- Create: `tests/skill-triggering/prompts/managing-epic-delivery.txt`
- Modify: `tests/skill-triggering/run-all.sh` (`set -e` line; the `SKILLS=(` array)
- Possibly modify: `skills/managing-epic-delivery/SKILL.md` (frontmatter `description` only)

- [ ] **Step 1: Write the prompt**

Create `tests/skill-triggering/prompts/managing-epic-delivery.txt`:

```text
Our "Notes tagging" epic has three backlog items listed in docs/handovers/toy-epic/epic.md. I want you to be the delivery manager for it: work out the order, then hand the items one at a time to fresh sessions that will build them with me.
```

- [ ] **Step 2: Fix `run-all.sh` failure counting and add the skill**

`run-all.sh` runs `if "$SCRIPT_DIR/run-test.sh" ... | tee ...; then`. Without `pipefail` the `if` sees the exit status of `tee`, so a failed triggering test is counted as passed. In `tests/skill-triggering/run-all.sh`, replace:

```bash
set -e
```

with:

```bash
set -eo pipefail
```

Then replace the end of the `SKILLS` array:

```bash
    "external-code-review"
    "external-review"
)
```

with:

```bash
    "external-code-review"
    "external-review"
    "managing-epic-delivery"
)
```

- [ ] **Step 3: Run the triggering test**

Run: `cd tests/skill-triggering && ./run-test.sh managing-epic-delivery prompts/managing-epic-delivery.txt`
Expected: it prints `✅ PASS: Skill 'managing-epic-delivery' was triggered`. The installed 1.5.1 plugin has no skill of this name, so `run-test.sh` needs no isolation here. If the skill does not trigger, read the logged first response, then adjust only the frontmatter `description` in `SKILL.md` (it must still start with "Use when" and describe only triggering conditions), re-run the static checks for the word budget, and re-run the trigger test.

- [ ] **Step 4: Commit (releasable checkpoint)**

```bash
git add tests/skill-triggering/prompts/managing-epic-delivery.txt tests/skill-triggering/run-all.sh \
        skills/managing-epic-delivery/SKILL.md
git commit   # message via superartes:commit-message
```

---

### Task 4: Header metadata in `brainstorming` and `writing-plans`

**Files:**
- Modify: `tests/managing-epic-delivery/static-checks.sh`
- Modify: `skills/brainstorming/SKILL.md` (two bullets)
- Modify: `skills/writing-plans/SKILL.md` (after the plan-header code block)

- [ ] **Step 1: Add the static checks**

Insert above the final `finish_suite` line of `static-checks.sh`:

```bash
# --- Header metadata (Task 4) ---
BRAIN="$PLUGIN_DIR/skills/brainstorming/SKILL.md"
PLANS="$PLUGIN_DIR/skills/writing-plans/SKILL.md"
check "brainstorming reads a Delivery Manager brief" grep -q "Delivery Manager brief" "$BRAIN"
check "brainstorming names the PBI line" grep -q "PBI:\*\*" "$BRAIN"
check "brainstorming names the Delivery brief line" grep -q "Delivery brief:\*\*" "$BRAIN"
check "writing-plans names the Delivery brief line" grep -q "Delivery brief:\*\*" "$PLANS"
check "writing-plans names the Branch base line" grep -q "Branch base:\*\*" "$PLANS"
```

- [ ] **Step 2: Run them and watch them fail**

Run: `bash tests/managing-epic-delivery/static-checks.sh`
Expected: the five new checks fail. Behaviour is covered by the prose review (Task 8) and the pilot (Task 9), not by a live test here.

- [ ] **Step 3: Edit `brainstorming`, project context**

In `skills/brainstorming/SKILL.md`, replace:

```markdown
- Check out the current project state first (files, docs, recent plans, recent commits)
```

with:

```markdown
- Check out the current project state first (files, docs, recent plans, recent commits)
- If the request names a tracker item (Asana, JIRA, ...), read the item and its comments. A comment headed `Delivery Manager brief` is your starting context; follow it alongside this skill.
```

- [ ] **Step 4: Edit `brainstorming`, spec header**

In the same file, replace:

```markdown
  - (User preferences for spec location override this default)
```

with:

```markdown
  - (User preferences for spec location override this default)
  - Header metadata, only when it applies: `**PBI:** <tracker> <ID> — "<title>" (<link>)` for work from a tracker item; `**Delivery brief:** <brief reference>` for work started by a Delivery Manager brief
```

- [ ] **Step 5: Edit `writing-plans`**

In `skills/writing-plans/SKILL.md`, replace:

````markdown
---
```

## Task Structure
````

with:

````markdown
---
```

**Optional header lines**, right after **Tech Stack:** and only when they apply: copy `**PBI:**` and `**Delivery brief:**` from the spec; when the spec has a `**Delivery brief:**`, read that brief and, if its branch base is not trunk, add `**Branch base:** <branch>`.

## Task Structure
````

- [ ] **Step 6: Run the static checks (GREEN)**

Run: `bash tests/managing-epic-delivery/static-checks.sh`
Expected: `Failed: 0`.

- [ ] **Step 7: Commit (releasable checkpoint)**

```bash
git add skills/brainstorming/SKILL.md skills/writing-plans/SKILL.md tests/managing-epic-delivery/static-checks.sh
git commit   # message via superartes:commit-message
```

---

### Task 5: `using-feature-branches` honours `Branch base:`

**Files:**
- Create: `tests/managing-epic-delivery/test-branch-base.sh`
- Modify: `tests/managing-epic-delivery/static-checks.sh`
- Modify: `skills/using-feature-branches/SKILL.md` (Step 2, Step 3, Common Mistakes, Red Flags)

- [ ] **Step 1: Add the static check**

Insert above the final `finish_suite` line of `static-checks.sh`:

```bash
# --- Branch base (Task 5) ---
check "using-feature-branches honours Branch base" grep -q "Branch base:\*\*" "$PLUGIN_DIR/skills/using-feature-branches/SKILL.md"
```

- [ ] **Step 2: Write the live test**

Create `tests/managing-epic-delivery/test-branch-base.sh`:

```bash
#!/usr/bin/env bash
# Live: the new branch is cut from the plan's Branch base, and the plan comes along.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/fixtures.sh"
require_live_tools

echo "=== managing-epic-delivery: branch base ==="
dir="$(scratch_dir)"
echo "Output: $dir"
repo="$dir/repo"
make_toy_repo "$repo"
make_branch_base_fixture "$repo"
run_turn "$repo" "$(new_session_id)" first "$dir/turn.jsonl" \
    "Use the superartes:using-feature-branches skill to create the feature branch feature/list-by-tag for executing docs/plans/2026-11-02-list-by-tag.md. Only set up the branch; do not implement anything."
check "new branch checked out" test "$(git -C "$repo" branch --show-current)" = "feature/list-by-tag"
check "new branch contains the base branch" git -C "$repo" merge-base --is-ancestor feature/add-tag-command feature/list-by-tag
check "plan committed on the new branch" git -C "$repo" cat-file -e feature/list-by-tag:docs/plans/2026-11-02-list-by-tag.md
check "base branch still unmerged into master" bash -c "! git -C '$repo' merge-base --is-ancestor feature/add-tag-command master"
finish_suite
```

- [ ] **Step 3: Run both and watch them fail**

Run: `chmod +x tests/managing-epic-delivery/test-branch-base.sh && bash tests/managing-epic-delivery/static-checks.sh; bash tests/managing-epic-delivery/test-branch-base.sh`
Expected: the new static check fails; the live test fails "new branch contains the base branch" or "plan committed on the new branch". If it passes anyway, the agent improvised; note that in the report and continue, since the edit makes the behaviour explicit.

- [ ] **Step 4: Edit Step 2**

In `skills/using-feature-branches/SKILL.md`, replace:

````markdown
### Step 2: Determine Base Branch

```bash
# Identify the main branch
````

with:

````markdown
### Step 2: Determine Base Branch

If the plan header has a `**Branch base:**` line, use that branch as the base and skip the detection below.

```bash
# Identify the main branch
````

- [ ] **Step 5: Edit Step 3**

In the same file, replace:

```markdown
**Branch naming:** Use descriptive names like `feature/auth-system`, `fix/login-timeout`, `refactor/db-layer`. Ask the user if no name is obvious from context.
```

with:

```markdown
If the base branch has no upstream (a local branch), skip `git pull`.

If the base is not trunk, this work's spec and plan (committed on trunk) are not on the new branch yet. Bring them over and commit them: `git checkout <trunk> -- <spec path> <plan path>`.

**Branch naming:** Use descriptive names like `feature/auth-system`, `fix/login-timeout`, `refactor/db-layer`. Ask the user if no name is obvious from context.
```

- [ ] **Step 6: Reconcile the pull rules**

In the same file, replace:

```markdown
- **Fix:** Always `git pull` on base branch before creating feature branch
```

with:

```markdown
- **Fix:** Always `git pull` on base branch before creating feature branch (when it has an upstream)
```

Then replace:

```markdown
- Pull latest base branch
```

with:

```markdown
- Pull latest base branch (when it has an upstream)
```

- [ ] **Step 7: Run both (GREEN)**

Run: `bash tests/managing-epic-delivery/static-checks.sh && bash tests/managing-epic-delivery/test-branch-base.sh`
Expected: both end with `Failed: 0`.

- [ ] **Step 8: Commit (releasable checkpoint)**

```bash
git add skills/using-feature-branches/SKILL.md \
        tests/managing-epic-delivery/static-checks.sh tests/managing-epic-delivery/test-branch-base.sh
git commit   # message via superartes:commit-message
```

---

### Task 6: Handover steps in `finishing-a-development-branch`

**Files:**
- Create: `tests/managing-epic-delivery/test-finishing-handover.sh`
- Create: `tests/managing-epic-delivery/test-finishing-options.sh`
- Create: `skills/finishing-a-development-branch/handover.md`
- Modify: `tests/managing-epic-delivery/static-checks.sh`
- Modify: `skills/finishing-a-development-branch/SKILL.md` (Step 2, before Step 3, Option 1 pull, Option 2 PR command, after Option 4, Integration)

- [ ] **Step 1: Add the static checks**

Insert above the final `finish_suite` line of `static-checks.sh`:

```bash
# --- Finishing handover (Task 6) ---
FIN="$PLUGIN_DIR/skills/finishing-a-development-branch"
check "finishing has handover.md" test -f "$FIN/handover.md"
check "gate points to handover.md" grep -q "handover.md" "$FIN/SKILL.md"
check "gate checks the Delivery brief line" grep -q "Delivery brief:\*\*" "$FIN/SKILL.md"
check "gate checks pending reports" grep -q "Status: awaiting executor" "$FIN/SKILL.md"
check "Step 2 honours Branch base" grep -q "Branch base:\*\*" "$FIN/SKILL.md"
check "handover finds tracker reports by first line" grep -q "first line is \`# Executor report\`" "$FIN/handover.md"
check_not "SKILL.md does not inline the acceptance question" grep -q "not yet / abandon" "$FIN/SKILL.md"
```

- [ ] **Step 2: Write the handover scenario test**

Create `tests/managing-epic-delivery/test-finishing-handover.sh`:

```bash
#!/usr/bin/env bash
# Live: finishing with a pending Delivery Manager handover (file mode).
#   accept:   two turns: acceptance asked first, then the report is written
#   fallback: fresh session, no plan named, no task-list reminder -> confirms ownership first
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/fixtures.sh"
require_live_tools

echo "=== managing-epic-delivery: finishing with a handover ==="
dir="$(scratch_dir)"
echo "Output: $dir"
EPIC="docs/handovers/toy-epic"
FINISH_PROMPT="I executed the plan docs/plans/2026-11-01-add-tag-command.md in this session; all its tasks are done and committed on this branch. Finish the development branch. Skip the external code review."

# new_repo <name> <epic-variant> <plan-variant>: prints the path of a repo at finishing time
new_repo() {
    local repo="$dir/$1"
    make_toy_repo "$repo"
    add_epic "$repo" "$2"
    add_plan "$repo" "$3"
    make_feature_branch "$repo"
    echo "$repo"
}

# first_turn_checks <repo> <transcript> <report>: acceptance asked before any integration
first_turn_checks() {
    local repo="$1" transcript="$2" report="$3"
    check "asks for acceptance" text_matches "accept" "$transcript"
    check_not "options not offered before acceptance" text_matches "Merge back to" "$transcript"
    check_not "nothing merged" git -C "$repo" merge-base --is-ancestor feature/add-tag-command master
    check "report still pending" grep -qx "Status: awaiting executor" "$repo/$report"
}

if want accept; then
    report="$EPIC/01-report-add-tag-command.md"
    repo="$(new_repo accept dispatched delivery)"
    session="$(new_session_id)"
    run_turn "$repo" "$session" first "$dir/accept-1.jsonl" "$FINISH_PROMPT"
    echo "Accept, turn 1:"
    first_turn_checks "$repo" "$dir/accept-1.jsonl" "$report"
    run_turn "$repo" "$session" resume "$dir/accept-2.jsonl" "Accept. Then option 3: keep the branch as-is."
    echo "Accept, turn 2:"
    check "report complete" grep -qx "Status: complete" "$repo/$report"
    check "report names its brief" grep -q "^Answers brief: $EPIC/01-brief-add-tag-command.md" "$repo/$report"
    check "acceptance recorded" grep -qE "^User acceptance: [0-9]{4}-[0-9]{2}-[0-9]{2}" "$repo/$report"
    check "every section filled" report_filled "$repo/$report"
    check "integration state names the kept branch" bash -c "grep -A3 '^## Integration state' '$repo/$report' | grep -q 'feature/add-tag-command'"
    check "report not committed by the executor" bash -c "[ -n \"\$(git -C '$repo' status --porcelain -- '$report')\" ]"
    check "branch kept" git -C "$repo" rev-parse --verify --quiet feature/add-tag-command
    check "prints the return instruction" text_matches "Delivery Manager" "$dir/accept-2.jsonl"
fi

if want fallback; then
    repo="$(new_repo fallback dispatched delivery)"
    run_turn "$repo" "$(new_session_id)" first "$dir/fallback-1.jsonl" \
        "All work on this branch is done and committed. Finish the development branch. Skip the external code review."
    echo "Fallback:"
    check "names the pending PBI" text_matches "add-tag-command|Add a tag to a note" "$dir/fallback-1.jsonl"
    check "asks the user to confirm before using it" text_matches "belong|confirm|is this (work )?(for|part of)|does this (work|branch)" "$dir/fallback-1.jsonl"
    check "report still pending" grep -qx "Status: awaiting executor" "$repo/$EPIC/01-report-add-tag-command.md"
    check_not "nothing merged" git -C "$repo" merge-base --is-ancestor feature/add-tag-command master
fi

finish_suite
```

- [ ] **Step 3: Write the options test**

Create `tests/managing-epic-delivery/test-finishing-options.sh`:

```bash
#!/usr/bin/env bash
# Live: finishing without a handover behaves as before: all four options, no acceptance
# question. A stray question is a matter of how often, so each case is sampled RUNS times.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/fixtures.sh"
require_live_tools

echo "=== managing-epic-delivery: finishing options ==="
dir="$(scratch_dir)"
echo "Output: $dir"
FINISH_PROMPT="I executed the plan docs/plans/2026-11-01-add-tag-command.md in this session; all its tasks are done and committed on this branch. Finish the development branch. Skip the external code review."

# four_options <transcript>: all four standard options appear
four_options() {
    text_matches "Merge back to" "$1" && text_matches "Pull Request" "$1" \
        && text_matches "Keep the branch" "$1" && text_matches "Discard" "$1"
}

for variant in plain pbi-only; do
    if want "$variant"; then
        for run in $(seq 1 "${RUNS:-3}"); do
            repo="$dir/$variant-$run"
            make_toy_repo "$repo"
            add_plan "$repo" "$variant"
            make_feature_branch "$repo"
            run_turn "$repo" "$(new_session_id)" first "$dir/$variant-$run.jsonl" "$FINISH_PROMPT"
            echo "$variant, run $run:"
            check "offers all four options" four_options "$dir/$variant-$run.jsonl"
            check_not "no acceptance question" text_matches "accept .*as done|accept (the|this) PBI|not yet / abandon" "$dir/$variant-$run.jsonl"
            check_not "nothing merged yet" git -C "$repo" merge-base --is-ancestor feature/add-tag-command master
        done
    fi
done

finish_suite
```

- [ ] **Step 4: Record RED, cheaply**

Run: `chmod +x tests/managing-epic-delivery/test-finishing-*.sh && bash tests/managing-epic-delivery/static-checks.sh; ONLY=accept bash tests/managing-epic-delivery/test-finishing-handover.sh; RUNS=1 bash tests/managing-epic-delivery/test-finishing-options.sh`
Expected:
- six of the seven new static checks fail (the `check_not` one already passes);
- the accept scenario fails at least "options not offered before acceptance" and the turn-2 report checks;
- `plain` and `pbi-only` **pass**. They run against the unchanged skill, which shows the regression checks are sound. If they fail now, fix the test, not the skill.

- [ ] **Step 5: Edit Step 2 of `finishing-a-development-branch`**

In `skills/finishing-a-development-branch/SKILL.md`, replace:

```markdown
### Step 2: Determine Base Branch

Determine the trunk this branch was cut from
```

with:

```markdown
### Step 2: Determine Base Branch

If the header of the plan you executed has a `**Branch base:**` line, that branch is the base: use it for the review scope and as the merge or PR target, and skip the trunk detection below.

Determine the trunk this branch was cut from
```

- [ ] **Step 6: Make the local-merge pull conditional**

In the same file, replace:

```markdown
# Pull latest
git pull
```

with:

```markdown
# Pull latest (skip when the base has no upstream)
git pull
```

- [ ] **Step 7: Insert the Step 2.6 gate**

In the same file, replace:

```markdown
### Step 3: Present Options
```

with:

```markdown
### Step 2.6: Handover check

Read `handover.md` in this skill's directory and follow its Step 2.6 if any of these holds:
- the header of the plan you executed has a `**Delivery brief:**` line;
- your task list has a "Report to Delivery Manager" item;
- `grep -rl "Status: awaiting executor" docs/handovers 2>/dev/null` prints a file.

Otherwise continue to Step 3.

### Step 3: Present Options
```

- [ ] **Step 8: Make the PR target the base branch**

In the same file, replace:

```markdown
gh pr create --title "<title>" --body "$(cat <<'EOF'
```

with:

```markdown
gh pr create --base <base-branch> --title "<title>" --body "$(cat <<'EOF'
```

- [ ] **Step 9: Add the Step 5 pointer**

In the same file, replace:

```markdown
## Quick Reference
```

with:

```markdown
### Step 5: Handover report

Only if Step 2.6 recorded Accept or Abandon: follow Step 5 of `handover.md`.

## Quick Reference
```

- [ ] **Step 10: Add the integration note**

In the same file, replace:

```markdown
- **commit-message** - Use for commit and merge commit message formatting
```

with:

```markdown
- **commit-message** - Use for commit and merge commit message formatting
- **managing-epic-delivery** - Issues the briefs that Step 2.6 and Step 5 report on (`handover.md`)
```

- [ ] **Step 11: Write `handover.md`**

Create `skills/finishing-a-development-branch/handover.md`:

````markdown
# Handover steps

Supporting file for `finishing-a-development-branch`. Read it only when the Step 2.6 gate in `SKILL.md` sent you here. Do Step 2.6 now and Step 5 after Step 4.

## Step 2.6: Handover check

1. Find the brief reference. Try these in order and stop at the first that gives one:
   1. the `**Delivery brief:**` line in the header of the plan you executed in this session;
   2. a task-list item "Report to Delivery Manager after user acceptance — brief: <reference>";
   3. a report file printed by `grep -rl "Status: awaiting executor" docs/handovers`. Read its `Answers brief:` line and ask the user: "Does this work belong to <the PBI named in that brief>?" Use it only if they say yes.

   Do not look through other specs or plans for a reference. If none of these gives one, there is no handover: return to Step 3.
2. Find the report for that brief:
   - File mode (the reference is a path): the report sits in the same folder with the same number and slug, `NN-report-<pbi-slug>.md`.
   - Tracker mode (the reference reads `<tracker> <ID> / brief NN`): read the PBI's comments through the tracker connector. The brief is the comment whose first line is `# Delivery Manager brief NN`, and it ends with the report template. The report is a comment whose first line is `# Executor report` and whose `Answers brief:` line matches the reference.
   - If you cannot read the tracker, tell the user that the handover cannot be checked and ask whether to stop here (fix the connector, then finish again) or continue to Step 3 without reporting. Either way the handover stays outstanding.
3. If that report exists with `Status: complete` or `Status: abandoned`, nothing is pending: return to Step 3.
4. Ask the user: "Do you accept <PBI title> as done? (accept / not yet / abandon)"
   - not yet: stop finishing here. Do not integrate and do not write a report; the work continues on this branch.
   - accept: remember Accept and return to Step 3.
   - abandon: remember Abandon and return to Step 3.

   If the user then picks Discard in Step 3 after answering accept, confirm that the PBI is abandoned and switch to Abandon.

## Step 5: Handover report

Run this after Step 4.

1. Fill in the report: the report file in file mode, or the template from the brief comment in tracker mode. Set:
   - `Answers brief:` to the reference from Step 2.6;
   - `Status: complete` for Accept, or `Status: abandoned` for Abandon;
   - `User acceptance:` to today's date (YYYY-MM-DD) and what the user answered;
   - "Integration state" to what Step 4 did: merged into <branch>, PR open: <link>, branch <name> kept unmerged, or branch discarded;
   - every other section from the spec, the plan and this session, writing "None" where nothing applies.
2. Deliver it:
   - File mode: save the file. Do not commit it; the Delivery Manager commits handover files on trunk.
   - Tracker mode: post it as a new comment on the PBI.
3. If delivery failed: show the user the whole report, tell them how to deliver it by hand (save it as the report file, or paste it as a comment on the PBI), keep the task-list reminder open, and stop here.
4. Mark the task-list reminder complete, if there is one.
5. Tell the user: "Go back to the Delivery Manager and say: completed <PBI title>, report at <report path or PBI link>."
````

- [ ] **Step 12: Run all three (GREEN)**

Run: `bash tests/managing-epic-delivery/static-checks.sh && bash tests/managing-epic-delivery/test-finishing-handover.sh; bash tests/managing-epic-delivery/test-finishing-options.sh`
Expected: all three end with `Failed: 0`, with `plain` and `pbi-only` sampled three times each. A stray question in even one run counts as a failure. If they fail, the agent is acting on the handover text for ordinary work, which is exactly the over-application risk the gate exists to prevent. Make the gate wording plainer; do not add emphasis. Narration such as "no handover pending" is acceptable; a question is not.

- [ ] **Step 13: Commit (releasable checkpoint)**

```bash
git add skills/finishing-a-development-branch/SKILL.md skills/finishing-a-development-branch/handover.md \
        tests/managing-epic-delivery/static-checks.sh \
        tests/managing-epic-delivery/test-finishing-handover.sh tests/managing-epic-delivery/test-finishing-options.sh
git commit   # message via superartes:commit-message
```

---

### Task 7: User documentation

**Files:**
- Modify: `README.md` (before `## What's Inside`; Skills Library, Collaboration list)
- Modify: `CLAUDE.md` (Repository Structure `tests/` list; Running Tests)

- [ ] **Step 1: Add the README section**

In `README.md`, replace:

```markdown
## What's Inside
```

with:

```markdown
## Delivering an Epic

For work larger than one feature, such as an epic of several PBIs in Asana or JIRA, one session can act as **Delivery Manager**. It helps you refine the epic and complete its backlog, decomposing work and adding PBIs once you accept them. It then sequences the PBIs and briefs a fresh *executor* session for each one. Every executor runs the full workflow above with you, and you carry the result back.

**Start the manager**, in any of these ways:
- Say: *"Act as Delivery Manager for epic \<link or name\>"*
- Claude Code: `/superartes:managing-epic-delivery <epic link>`
- Codex, Cursor, OpenCode: mention `superartes:managing-epic-delivery` by name

**The loop, once per PBI:**
1. The manager writes a brief and prints a prompt for you to copy.
2. Start a fresh session (`/clear`, or a second terminal) and paste the prompt. With a tracker it reads *"Work on PBI \<link\>…"*; without one, *"Read your instructions from @docs/handovers/\<epic\>/\<NN\>-brief-\<pbi\>.md"*.
3. Work through brainstorming, plan and implementation as usual. When you finish the branch, the executor asks whether you accept the PBI as done and then writes its report.
4. Go back to the manager (`/resume`, or a new session saying *"Act as Delivery Manager for epic \<link\>"*) and say *"completed"*. The executor prints this prompt for you too.

**Where the plan and messages go:** with Asana or JIRA connected, PBIs are subtasks of the epic or a flat backlog linked to it by a tag or name prefix, whichever you prefer. The approved sequence is kept in a comment on the epic and applied to the tracker's own order; if you rearrange the PBIs, the manager notices and asks which order to follow. Briefs and reports are comments on the PBI. Without a tracker, they are files in `docs/handovers/<epic>/`, and at the end of the epic you can delete them.

**Requirement:** in tracker mode, both the manager and the executor sessions need the tracker's MCP connector.

## What's Inside
```

- [ ] **Step 2: Add the skills-list line**

In `README.md`, replace:

```markdown
- **finishing-a-development-branch** - Merge/PR decision workflow
```

with:

```markdown
- **finishing-a-development-branch** - Merge/PR decision workflow
- **managing-epic-delivery** - Delivery Manager role: refines and decomposes an epic, sequences its PBIs and briefs a fresh executor session for each, through tracker comments or handover files
```

- [ ] **Step 3: Update `CLAUDE.md`**

In `CLAUDE.md`, replace:

```markdown
  subagent-driven-dev/      # End-to-end workflow tests with scaffold projects
```

with:

```markdown
  subagent-driven-dev/      # End-to-end workflow tests with scaffold projects
  managing-epic-delivery/   # Delivery Manager and handover hooks: static checks plus live claude -p scenarios
```

Then, in the same file, replace:

````markdown
### Skill triggering tests:
````

with:

````markdown
### Managing-epic-delivery tests:
```bash
tests/managing-epic-delivery/static-checks.sh   # deterministic, seconds
tests/managing-epic-delivery/test-fixtures.sh   # deterministic, seconds
# Live claude -p scenarios, minutes each; run when the skill they cover changes (see the suite's README.md):
for t in plugin-isolation manager branch-base finishing-handover finishing-options; do
    bash "tests/managing-epic-delivery/test-$t.sh" || break
done
```

### Skill triggering tests:
````

- [ ] **Step 4: Commit (releasable checkpoint)**

```bash
git add README.md CLAUDE.md
git commit   # message via superartes:commit-message
```

---

### Task 8: Execute-the-prose review with both model families

**Files:**
- Possibly modify: any skill file from Tasks 2-6, according to findings

This task is controller work: dispatching the reviewers and triaging what they find. Skill fixes go to an implementer. It is also the main coverage for the paths that have no live test: not yet, abandon, retry, a late report, an unprocessed report, discovered work, a stacked branch base and the plan-header metadata.

- [ ] **Step 1: Prepare a review sandbox**

Run this. It prints the sandbox path; record that path literally for the next steps, since a shell variable does not survive between calls.

```bash
bash -c 'source tests/managing-epic-delivery/lib.sh; source tests/managing-epic-delivery/fixtures.sh; d="$(scratch_dir)"; make_toy_repo "$d/repo"; add_epic "$d/repo" fresh; echo "SANDBOX=$d/repo"'
```

- [ ] **Step 2: Write the review prompt**

Write this prompt to a temporary file in the session scratchpad, replacing `<SANDBOX>` with the printed path and `<REPO>` with the absolute path of this repository:

```text
You are reviewing agent skills by performing them. Skills are Markdown instructions that AI coding agents execute; their prose is the product.

Read these files from <REPO>:
- skills/managing-epic-delivery/SKILL.md, brief-template.md, report-template.md
- skills/finishing-a-development-branch/SKILL.md and handover.md
- skills/using-feature-branches/SKILL.md
- the header-metadata lines in skills/brainstorming/SKILL.md and skills/writing-plans/SKILL.md

Then walk through these roles against the toy repository <SANDBOX>, step by step. At each step state exactly what you would do: commands, files written with their full contents, messages to the user. Do not modify any file. Assume you have no task-list tool.

1. Delivery Manager, file mode: setup, intake of docs/handovers/toy-epic/epic.md, the sequence proposal, and the first dispatch after the user approves the sequence with handover files committed and branch base trunk.
2. Executor: a fresh session given the printed prompt. Name the header lines its spec and plan get, and how its feature branch is created, both from trunk and from an earlier PBI's unmerged branch. Then a session working on an ordinary Asana task with no brief: which header lines its spec gets.
3. Executor at finishing time, five times: the user answers accept and then keeps the branch; the user answers not yet; the user answers abandon; the session was compacted and the plan path is unknown; the plan has a `Branch base:` line naming an earlier PBI's branch.
4. Delivery Manager again, in a new session told "completed": verification and the next step. Then a new session that finds a complete report nobody has processed, whose "Discovered work" names a PBI that must come before the next one: what is proposed, applied and recorded.
5. Delivery Manager and executor when PBI 01's brief was abandoned and the PBI is retried as brief 02: which brief is pending, and what happens when a late report for brief 01 arrives.
6. The same Delivery Manager in tracker mode (an Asana epic), from setup through dispatch and receiving the report to closing the epic: what is asked, what is posted where, where the sequence is recorded for subtasks, for a flat backlog and for a tracker with no ordering, what happens when the user has rearranged the PBIs before a dispatch, and how the executor finds the brief and the report template. Then a fresh manager in that tracker with no ordering: how it recovers the sequence from the plan comment and picks the next PBI.
7. Delivery Manager given an epic with a goal but no PBIs, and later a PBI too large for one executor: what is proposed, and what is changed only after the user accepts it.

Report every point where the instructions were ambiguous, contradictory, or missing, so that you had to guess, and what you guessed. Also report any instruction you think an agent would apply when its condition is false. Quote the passage each time. Do not report wording preferences without a concrete failure.
```

- [ ] **Step 3: Run the Claude reviewer**

Claude Code controller: dispatch a general-purpose subagent with `model: opus` and the prompt file's full text as its prompt. Codex controller: run the same prompt through the foreground Claude invocation in `skills/external-review/invoking-reviewers.md` instead. Record the report.

- [ ] **Step 4: Run the Codex reviewer**

Claude Code controller: use this repository's runner. Record the printed `RUN_DIR` literally, run `status` once a few seconds later, then `wait` until done:

```bash
skills/external-review/invoke-codex.sh start prompt "<REPO>" "<prompt file>"
skills/external-review/invoke-codex.sh status "<RUN_DIR>"
skills/external-review/invoke-codex.sh wait "<RUN_DIR>" 540
```

Read the `RESULT=` file, then run `skills/external-review/invoke-codex.sh discard "<RUN_DIR>"`. Codex controller: dispatch a Codex subagent (`spawn_agent`) with the prompt instead. If Codex is unavailable (exit 127 or `LAUNCH_ERROR`), report that to the user and continue with the Claude review alone, labelled single-family.

- [ ] **Step 5: Triage**

For every finding, decide fix or no change, with a reason. Check each accepted fix against the other model family's reading habits, using the four prose rules in "Read this first". A finding raised by only one family is still fixed if the behaviour it describes is wrong.

- [ ] **Step 6: Apply fixes and re-verify**

Dispatch an implementer with the accepted fixes as a list of exact old/new passages. Then run:
- `bash tests/managing-epic-delivery/static-checks.sh` (word budget included);
- the live tests mapped to each changed skill in the tests README.

Expected: all `Failed: 0`.

- [ ] **Step 7: Run the repository's existing checks**

Run: `python3 tests/codex-plugin/validate-codex-plugin.py && bash tests/managing-epic-delivery/test-fixtures.sh`
Expected: the validator reports success, and the fixtures `Failed: 0`.

- [ ] **Step 8: Commit (releasable checkpoint, only if Step 6 changed files)**

```bash
git add skills/ tests/managing-epic-delivery/
git commit   # message via superartes:commit-message
```

---

### Task 9: Pilot on a real epic (the user)

**Files:** none, unless defects are found.

This task is for the user. It is the only test with an interactive session, a real tracker and real work, so it replaces a scripted checklist. Keep the feature branch unmerged during the pilot, and turn every defect into a fix (test first where a live test exists) before finishing the branch.

- [ ] Choose a small real epic in Asana, with at least three PBIs.
- [ ] Run the manager and each executor against this working tree, with this feature branch checked out: `claude --plugin-dir /home/andy/comp/superartes-andy`.
- [ ] Deliver the epic as normal, using the loop in the README. Note anything surprising.

Watch for these along the way:

- [ ] The manager asks about subtasks or a flat backlog, proposes what the epic lacks, and changes the tracker only after you accept.
- [ ] The "Delivery Manager plan" comment records the conventions and the approved sequence. The tracker's own order matches it.
- [ ] Rearrange two undispatched PBIs by hand. Before the next dispatch, the manager notices and asks which order to follow.
- [ ] The printed prompt starts an executor that finds the brief in the comments. Its spec and plan carry the `PBI:` and `Delivery brief:` lines.
- [ ] At finishing, acceptance is asked **before** the merge/PR options, and a comment starting `# Executor report` appears, with every section filled.
- [ ] Between PBIs, use a brand-new manager session instead of `/resume`. It picks up correctly, and issues no second brief for a PBI that is still in progress.
- [ ] Close-out posts the summary you approve and closes the epic.
- [ ] Ordinary work during the same period finishes with the usual four options and no acceptance question.

---

---

## Out of scope for this plan

- Version bump and release (six version files, per `CLAUDE.md`): a separate step after the user accepts this work.
- Creating an epic from scratch: the manager starts from an existing epic, however thin.
- A separate epic-shaping skill. If one is introduced later, the manager will call it when appropriate.
- Automated executor-to-manager notification.
