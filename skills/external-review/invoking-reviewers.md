# Invoking Managed Reviewers

This reference describes the **managed adapter**, `invoke-reviewer.sh`. It exists
for one situation: a **Codex controller** obtaining a review from Claude. Codex's
command runner reaps every descendant when a one-shot elevated call ends, including
a supervisor detached with `nohup` and `setsid`, so that direction needs a
supervisor, process-identity validation and a lock registry.

A **Claude Code controller does not need any of it** and must not use it. Claude
Code leaves background descendants alone, so it uses the small background runner
described in `superartes:external-review`'s own Invocation section
(`invoke-codex.sh`, or `invoke-codex.ps1` on native Windows).

**Platform support:** the managed adapter is POSIX only — Linux, macOS and WSL. There
is no native-Windows adapter, so superartes does not *currently* support this direction
on native Windows. That is a project support decision, not a Codex limitation: Codex
itself runs natively on Windows, and a route that avoids POSIX process plumbing
altogether is under investigation. Until one lands, tell the user this direction is
unavailable on native Windows and offer WSL, rather than falling back to a same-model
review without saying so.

Resolve the adapter from the absolute directory containing this reference and its
sibling `SKILL.md`; never resolve it relative to the user's project. Under Codex,
use the absolute skill source directory provided by the skill catalog. Quote every
resolved path. Run the adapter's `check PROFILE` once per session before
model-backed work.

## Codex controller process hosting

This section applies only when a Codex/OpenAI controller selects
`claude-prompt`. It does not change a Claude Code controller's invocation of
either Codex profile. Claude Code controller should skip this section. 

Claude needs provider network access. When that requires approved execution
outside Codex's normal sandbox, open one approved persistent shell session and
keep it alive for the managed lifecycle. Do not run `start` as a standalone
one-shot elevated command: Codex's command runner may reap every descendant
when that call ends, including a supervisor detached with `nohup` and `setsid`.

On POSIX hosts, open a persistent PTY running `bash --noprofile --norc`. Send
the quoted `check` and `start` commands to that session, retain `RUN_DIR`, and
send bounded `wait` calls to the same session. Inspect terminal evidence and
run `cleanup` before exiting the shell. Use the equivalent persistent shell
facility on other supported hosts.

The approval request must identify the project or disposable fixture exposed
to Claude and state that the review uses network access and model tokens. If
the Codex host cannot provide an approved persistent shell, stop before
`start`; do not launch a review that the host is known to reap.

## Stable review keys

A stable review key is the identity of one review request. `start` refuses to
launch a second review whose key matches an outstanding run: it returns exit 12
and that run's `RUN_DIR` instead, so a repeated invocation attaches to the review
already in flight rather than duplicating it. Two invocations that mean the same
review must therefore produce byte-identical keys, which is why every field is
canonicalized and encoded rather than used raw.

Canonicalize every path to its absolute physical filesystem path. Encode every
dynamic field as UTF-8, then RFC 4648 base64url without padding. The base64url
alphabet contains neither `|` nor `,`, so those characters are unambiguous key
separators even when they occur in an original path or value.

For multiple documents, remove duplicate canonical paths, sort the canonical
path UTF-8 byte sequences lexicographically, encode each path separately, and
join the encoded paths with `,`. Construct keys as:

- Document: `document|<project-b64url>|<documents-b64url-list>|<type-b64url>`
- Code: `code|<repository-b64url>|<scope-kind-b64url>|<scope-value-b64url>`

The `uncommitted` scope has no value, so its scope-value field is empty and the
key ends with a trailing `|`.

Canonicalize a path with `cd "$DIR" && pwd -P` or `realpath -e`. Encode one
field with:

```bash
printf '%s' "$FIELD" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
```

Sort document paths with `LC_ALL=C sort` before encoding them; another locale may
not sort by UTF-8 byte sequence.

## Normal lifecycle

1. Create the prompt in a unique temporary file when the profile needs one.
2. Start the fixed profile and retain the printed `RUN_DIR`.
3. Remove only the caller-created prompt copy after start has retained it.
4. Call `wait` in chunks safely below the host shell-tool cap - 540 seconds under
   a 600-second cap. On expiry `wait` calls `status`, which can add a few
   seconds beyond the requested timeout.
5. On terminal state, read `state`, `exit-code`, `result`, and logs.
6. Triage substantive feedback before cleanup.
7. Call `cleanup` only after triage or diagnosed failure.

Never treat an empty live result as failure. Never start another matching
review while one is outstanding. `start` returns the existing run when its
stable key is outstanding.

To cancel, run `cancel`, then `wait` until the state is terminal, inspect the
evidence, and only then `cleanup`. `cleanup` returns 66 while the state is
non-terminal or while a reviewer or supervisor identity still matches, so never
call it directly on a live run.

## Recover lost start output

An ordinary `start` launches a new review when no matching key exists. Recover
only when every semantic input is exact: profile, stable key, canonical work
directory, and original prompt bytes or code-review scope arguments. If any
input is uncertain, do not reissue `start`; report that recovery is blocked and
ask for or diagnose the missing input. Never substitute a merely similar prompt.

- If you have not yet deleted your prompt file, reissue the original ordinary
  `start` with that same still-readable file.
- If you have already deleted it, write the exact original prompt bytes to a new
  temporary file, then reissue the same profile, stable key and work directory
  with that file. The replacement pathname need not match the original, because
  lock identity is the stable key, not the prompt pathname.

Do not use `--after-terminal` for recovery. Recovery still requires profile
preflight to succeed because `start` performs preflight before outstanding-key
lookup. On exit 12, retain the printed outstanding `RUN_DIR`, remove only the
caller-created replacement prompt, and use the recovered path for `wait`.

## Profiles

POSIX forms, where `$ADAPTER` is the quoted absolute script path:

```bash
"$ADAPTER" start claude-prompt "$REVIEW_KEY" "$WORK_DIR" "$PROMPT_FILE"
"$ADAPTER" start codex-prompt "$REVIEW_KEY" "$WORK_DIR" "$PROMPT_FILE"
"$ADAPTER" start codex-review "$REVIEW_KEY" "$WORK_DIR" uncommitted
"$ADAPTER" start codex-review "$REVIEW_KEY" "$WORK_DIR" base "$BASE_REF"
"$ADAPTER" start codex-review "$REVIEW_KEY" "$WORK_DIR" commit "$COMMIT_SHA"
"$ADAPTER" start --after-terminal "$PREVIOUS_RUN" claude-prompt "$REVIEW_KEY" "$WORK_DIR" "$PROMPT_FILE"
"$ADAPTER" status "$RUN_DIR"
"$ADAPTER" wait "$RUN_DIR" "$TIMEOUT_SECONDS"
"$ADAPTER" cancel "$RUN_DIR"
"$ADAPTER" cleanup "$RUN_DIR"
```

For a linked retry, place `--after-terminal "$PREVIOUS_RUN"` immediately after
`start`, as shown. Use `status`, `cancel`, and `cleanup` with the same final
`$RUN_DIR` argument.

Exit codes are: 0 terminal/accepted operation, 2 missing CLI capability, 3
still running, 4 indeterminate, 12 outstanding matching review, 64 usage, 65
invalid run, 66 cleanup evidence remains, 75 registry unavailable, and 127 CLI
unavailable. Exit 3 and 4 are lifecycle facts, not generic tool failures.

## Terminal evidence order

State and validated reviewer/supervisor identity, exit code, native result,
reviewer output and log, supervisor output and log, provider session/transcript,
then already-returned output. Substantive review anywhere means triage it and
do not retry.

`status` prints state, profile, provider, elapsed time, the artifact paths,
`REVIEWER_PID`, `EXIT_CODE` and `COMPLETED_AT`. It does not print supervisor
identity, and once the state is terminal it returns without revalidating either
identity. To establish the absence that a linked retry requires, read
`reviewer-pid`, `reviewer-start`, `supervisor-pid` and `supervisor-start` in
`RUN_DIR` and confirm no live process matches both a recorded PID and its start
token. An artifact file that is absent is itself evidence, not a read failure.

Claude JSON may be one result object or a transcript-style array. In the array
form, locate the terminal item whose `type` is `result`; do not assume a
top-level `.result`. Never parse or judge output while the reviewer is live.

For `indeterminate`, inspect every artifact and process identity. Use substantive
feedback if present. Otherwise record the diagnostic and consider at most one
degraded fallback only after the original reviewer is confirmed absent. Never
retry immediately.

An ownerless registry lock is not auto-deleted. Inspect
`.registry-lock/owner-pid` and `owner-start`; only after proving no owner exists,
remove those two known files and the empty lock directory.

## Fallback

Use `--after-terminal` only after the original is terminal, validated process
evidence shows its reviewer and supervisor are absent, and all evidence shows
no usable review. Explicit user approval can authorize that linked retry only
after the same terminal-and-absent precondition. Approval never permits a
linked retry while the original is live. Label same-model fallback as degraded.
