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

## Codex controller process hosting

This section applies only when a Codex/OpenAI controller selects
`claude-prompt`. It does not change a Claude Code controller's invocation of
either Codex profile.

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

Canonicalize every path to its absolute physical filesystem path. Encode every
dynamic field as UTF-8, then RFC 4648 base64url without padding. The base64url
alphabet contains neither `|` nor `,`, so those characters are unambiguous key
separators even when they occur in an original path or value.

For multiple documents, remove duplicate canonical paths, sort the canonical
path UTF-8 byte sequences lexicographically, encode each path separately, and
join the encoded paths with `,`. Construct keys as:

- Document: `document|<project-b64url>|<documents-b64url-list>|<type-b64url>`
- Code: `code|<repository-b64url>|<scope-kind-b64url>|<scope-value-b64url>`

## Normal lifecycle

1. Create the prompt in a unique temporary file when the profile needs one.
2. Start the fixed profile and retain the printed `RUN_DIR`.
3. Remove only the caller-created prompt copy after start has retained it.
4. Call `wait` in chunks shorter than the host shell-tool cap.
5. On terminal state, read `state`, `exit-code`, `result`, and logs.
6. Triage substantive feedback before cleanup.
7. Call `cleanup` only after triage or diagnosed failure.

Never inspect an empty live result as failure. Never start another matching
review while one is outstanding. `start` returns the existing run when its
stable key is outstanding.

## Recover lost start output

An ordinary `start` launches a new review when no matching key exists. Recover
only when every semantic input is exact: profile, stable key, canonical work
directory, and original prompt bytes or code-review scope arguments. If any
input is uncertain, do not reissue `start`; report that recovery is blocked and
ask for or diagnose the missing input. Never substitute a merely similar prompt.

- Before caller prompt cleanup, reissue the original ordinary `start` using
  the still-readable original prompt file.
- After caller prompt cleanup, create a readable temporary file containing the
  exact original prompt, then reissue the same profile, stable key, and work
  directory using that file. The replacement pathname need not match because
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

Native Windows forms, where `$Adapter` is the literal absolute `.ps1` path:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start claude-prompt $ReviewKey $WorkDir $PromptFile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-prompt $ReviewKey $WorkDir $PromptFile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-review $ReviewKey $WorkDir uncommitted
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-review $ReviewKey $WorkDir base $BaseRef
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start codex-review $ReviewKey $WorkDir commit $CommitSha
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter start --after-terminal $PreviousRun claude-prompt $ReviewKey $WorkDir $PromptFile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Adapter wait $RunDir $TimeoutSeconds
```

For a linked retry, place `--after-terminal "$PREVIOUS_RUN"` immediately after
`start` on both adapters, as shown. Use `status`, `cancel`, and `cleanup` with
the same final `$RunDir` argument.

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

Use `--after-terminal` only after the original is terminal, validated process
evidence shows its reviewer and supervisor are absent, and all evidence shows
no usable review. Explicit user approval can authorize that linked retry only
after the same terminal-and-absent precondition. Approval never permits a
linked retry while the original is live. Label same-model fallback as degraded.
