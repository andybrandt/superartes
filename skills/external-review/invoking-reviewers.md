# Invoke Claude directly from a Codex controller

Use this Direction B reference for document or code reviews. Codex selects
Claude; retain the user's default model. Follow the calling skill's scope,
prompt template, Triage and summary instructions. These completion rules
govern Direction B.

Check the host platform before preparation. On native Windows, report independent
Claude review unavailable and stop this invocation path; use the calling skill's
consented fallback if appropriate. On Linux, proceed with the verified path below.
On macOS or WSL, explicitly report that this is an unverified POSIX candidate,
then proceed only if the required CLI capabilities, shared artifact visibility
and foreground PTY session controls are available. Preserve that uncertainty in
the final report; a successful launch alone does not verify the platform's full
polling and cancellation behavior.

## 1. Prepare and check for an existing attempt

Validate the review scope first. Resolve skill paths from the installed catalog.
For code, validate the repository and requested diff or commits, and require the
reviewer to report inspected files and Git/diff evidence. For documents, use the
calling skill's spec or plan review prompt.

Run `claude --version` and `claude --help`. Confirm support for every flag in
the command below. If Claude or a required capability is missing, report the
reviewer unavailable; do not silently remove restrictions.

Resolve the project's physical absolute working directory with `pwd -P` in
the intended directory. Define an exact, repeatable scope description, including
the document paths or Git scope. Before launching, search only
`superartes-claude-review.*` directories in the current `${TMPDIR:-/tmp}` and
any temporary roots recorded for earlier attempts in this conversation. This
is best-effort discovery within those roots, not guaranteed cross-session
deduplication. Match their recorded physical `work-dir` and exact `scope`.
Inspect **every** matching
attempt, never just the newest. If any is live or its termination is unknown,
do not start another. Inspect completed evidence before deciding whether another
review is needed. Missing or ambiguous metadata is not permission to retry a
known outstanding attempt.

Keep at most one outstanding attempt for the same project and scope. This is a
controller rule, not an atomic lock or cross-controller registry. Independent
Codex conversations are not deduplicated; automatic cross-session recovery is
deliberately unavailable.

Create a unique attempt directory:

```bash
mktemp -d "${TMPDIR:-/tmp}/superartes-claude-review.XXXXXX"
```

Resolve that directory to its physical absolute path. Obtain a real provider
session UUID from `/proc/sys/kernel/random/uuid` on Linux, or `uuidgen` when
testing macOS. Never invent it. In the attempt directory save:

- `prompt.txt`: the exact review prompt, encoded as UTF-8.
- `work-dir`: the physical absolute project directory.
- `scope`: the exact review scope. For code, write two labelled lines:
  `kind: <base|uncommitted|commit>` and `value: <scope value>`, with a final
  newline. Use `value: none` for `uncommitted`; otherwise record the detected
  trunk branch or validated commit SHA. The canonical repository is recorded
  separately in `work-dir`. Reuse this exact serialization when matching attempts.
- `session-id`: the Claude UUID.

Reserve `result.json` and `stderr.log` in that same directory. Record the
attempt directory, working directory, scope and UUID as literal values in your
reply before launch. Use literal absolute paths in every later tool call;
shell variables do not survive between calls. All preparation, execution,
inspection and cleanup must resolve the same attempt directory. Before the live
run, verify that a preparation file is readable in the approved execution
context. Shared `/tmp` visibility was verified on Linux, not on every host.

## 2. Launch one foreground command

Use the host command tool's working-directory argument for the recorded project
directory. Obtain required sandbox approval identifying the project/files
exposed to Claude, provider network access and model charges. Honor existing
explicit authorization without asking for the same consent again; host approval
enforcement still applies.

Enable a PTY on this foreground command so the Codex command-session input tool
can send Ctrl-C. Request a short initial yield, such as one second. Substitute
every quoted placeholder below with the corresponding shell-quoted literal;
escape embedded single quotes correctly. Run this command directly:

<!-- direct-claude-command:start -->
```bash
claude -p --safe-mode --permission-mode dontAsk \
  --tools "Read,Glob,Grep,Bash" \
  --allowedTools "Read,Glob,Grep,Bash(git diff *),Bash(git status *),Bash(git rev-parse *),Bash(git cat-file *),Bash(git show *),Bash(git log *)" \
  --output-format json --session-id '<provider-session-uuid>' \
  < '<absolute-prompt-path>' > '<absolute-result-path>' 2> '<absolute-stderr-path>'
```
<!-- direct-claude-command:end -->

Do not add a runner, timeout, model override, `&`, `nohup`, `setsid`, or a
persistent interactive shell. The Git allowances are not an operating-system
read-only sandbox: output flags and configured diff/textconv helpers can have
side effects. Do not claim stronger isolation or widen permissions to let the
reviewer run tests. Run necessary checks as controller and supply their evidence.

## 3. Retain the session and wait

Record the host command-session identifier separately from Claude's UUID and
any orchestration cell ID. Poll that same command using the host session-input
or wait tool. Keep each blocking wait below 60 seconds and give progress updates.
Tool yields, silence and empty live artifacts are not failures or permission to
start a duplicate. Do not impose an arbitrary short reviewer timeout.

At fifteen minutes in interactive work, give a progress checkpoint and ask
whether to continue through a non-blocking user-input mechanism, if available.
Retain the active turn and session while waiting; absent an answer, continue
bounded polling. If no non-blocking question mechanism exists, report that limit
and keep polling. Never end the turn merely to ask: survival across turn ending,
user Esc or full application crash is unverified.

On an abandonment request, interrupt the existing command through the host's
verified cancellation facility, then await terminal acknowledgement. Do not
declare cancellation or retry merely because an interrupt was sent. If the
client cannot terminate the command, say the reviewer may keep spending tokens
and retain its evidence.

## 4. Establish terminal evidence, then triage

On terminal command return, record the shell exit status and inspect both native
JSON and stderr. Accept a result object or a transcript array; locate the final
item whose `type` is `result`. Check error indicators, permission denials and
substantive feedback. Shell exit zero alone is insufficient: real cancellation
has returned zero with `is_error: true`, subtype `error_during_execution` and
`terminal_reason: aborted_streaming`. A nonzero exit can still contain a useful
review; preserve and triage it. Empty, malformed or incomplete terminal JSON
does not establish a successful review. For code, require reported Git/diff
inspection evidence before accepting the review as complete.

Label Claude's `duration_ms` as provider-reported runtime. If independently
measuring a verification run, measure process elapsed time excluding approval
waiting; the surrounding tool-call duration is not reviewer runtime.

If the command handle is lost, inspect retained artifacts and all matching
attempts without launching another reviewer. A missing session is unknown, not
cancelled. Process inspection, if needed, must have the same execution visibility
as the original approved command; absence from a restricted process listing
proves nothing. If termination cannot be established, stop dependent work and
request user intervention. Never automatically restart, blindly use
`claude --resume`, or clean up an unknown/live attempt.

After termination is established, follow the calling skill's Triage and summary
instructions, retaining evidence through triage or failure diagnosis. For
documents, use the calling skill's document fallback templates; for code, use
the code-review fallback specified by the calling skill. Obtain the required
consent for a degraded same-model fallback, only after the original attempt is
confirmed terminal or unavailable. Do not treat unknown state as unavailable. Delete only
the exact attempt directory when termination is established and its evidence is
no longer needed.

## Verified boundary

Linux foreground PTY document/code reviews and real Claude cancellation have
been exercised. A silent foreground PTY process completed after 900 seconds;
this does not establish unlimited command lifetime. macOS and WSL remain
unverified POSIX candidates. Native Windows is unavailable pending native tests
of UTF-8 input, paths with spaces, exit propagation, long polling and cancellation;
Linux PowerShell is not native Windows evidence. Do not provide a guessed native
Windows invocation or claim automatic recovery after host/session loss.
