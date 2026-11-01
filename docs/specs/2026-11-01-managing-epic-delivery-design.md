# Managing Epic Delivery Design

## Overview

Add a skill, `managing-epic-delivery`, in which an agent acts as **Delivery Manager** for an epic. It does intake on the epic and its product backlog items (PBIs), proposes a sequence, and briefs one fresh **executor** session per PBI. Each executor is an ordinary main session that runs the full Superartes cycle with the user (brainstorming → spec → plan → execution → finishing) and reports back only after the user accepts the work.

The user carries the messages between sessions. Briefs and reports are comments on the PBI when a tracker such as Asana or JIRA is connected, and files in `docs/handovers/<epic-slug>/` otherwise. Two small additions to existing skills make the executor side semi-automatic. `brainstorming` picks up a brief at the start of the cycle, and `finishing-a-development-branch` produces the report at its end.

## Motivation

Superartes orchestrates work *within* one feature: `subagent-driven-development` sends out implementers and reviewers that never talk to the user. Nothing orchestrates work *across* features. The user wants an agent to sequence the PBIs of an epic while each PBI gets the full treatment: its own brainstorming dialogue with the user, spec, plan, reviewed implementation and acceptance by the user.

## Goals

- One session sequences an epic's PBIs and keeps the backlog accurate.
- Each PBI is delivered by a session that can converse with the user and use the full subagent depth.
- No PBI counts as done until the user has accepted it.
- The manager's state can be recovered from the tracker or the handover files, so a new manager session can take over at any time.
- Works on every platform Superartes supports (Claude Code, Codex, Cursor, OpenCode).
- Adds nothing that ordinary non-epic work notices.

## Non-goals

- **Shaping an epic** (turning an idea into an epic with PBIs). This will be a separate skill, specified later. Until then, intake fills gaps with the user in conversation.
- Automated transport between sessions. The user moves between sessions by hand.
- Running several executors in parallel by default.

## Rejected alternatives

Recorded so that later work does not reopen them without new information. The platform facts are from the Claude Code documentation as read on 2026-11-01 (`code.claude.com/docs/en/sub-agents.md`, `agent-teams.md`, `cross-session-messaging.md`).

| Alternative | Why rejected |
|---|---|
| **Executor as a subagent; the manager relays the user's questions** (the executor stops with a question, and the manager asks the user and resumes it with `SendMessage`) | Subagents cannot ask the user anything (`AskUserQuestion` is removed). Brainstorming asks one question per message, so every question would make a round trip through the manager. Manager → executor → its implementers and reviewers also sits exactly at the default nesting limit of three levels below the main conversation. The mechanism exists only in Claude Code. |
| **Executor as an agent-team teammate** | Experimental and disabled by default. One team per session, no nested teams, teammates cannot run background subagents, and in-process teammates cannot be resumed. The documentation does not confirm that plugin skills load for teammates. Claude Code only. |
| **A companion executor skill** (for example `working-from-a-handover`) | Unnecessary. A short brief plus checks at the two ends of the existing cycle make any session an executor. A second skill would add something to trigger, and briefs and skill versions could drift apart. |
| **Relying on the executor to remember to report** | A long executor session may be compacted, and the instruction from the start can be lost. The report is instead triggered by `finishing-a-development-branch`, which every cycle ends with and which is loaded fresh when invoked. |
| **A local "pending" marker file in tracker mode** | The tracker already holds the brief. The executor finds it from the `Delivery brief:` line in its own plan, so a local copy of the state is not needed. |
| **Identifying the PBI at finishing from the branch name, or from any spec or plan in the repository** | Specs and plans are committed on trunk and accumulate, so a repository-wide match can tie ordinary work to an unrelated PBI. The branch may already be gone after a merge. Identity comes only from the plan executed in this session. |
| **Treating every `PBI:` line as a handover** | Ordinary tracker-linked work also carries `PBI:` metadata. Only a `Delivery brief:` line is positive evidence of managed delivery. |
| **Epic shaping inside this skill** | Shaping has a different trigger (it is useful without delivery) and a different output (backlog items, not a delivered PBI). It would also add tokens to a skill that is loaded every time the user returns to the manager. |

## Roles

**Delivery Manager**: a session running `managing-epic-delivery`. It owns the epic: intake, sequencing, briefs, re-planning and close-out. It never writes or edits product code and never does an executor's work, however small. It learns about the code only through reports.

**Executor**: a fresh session per PBI, started by the user with the prompt the manager prints. It runs the standard cycle with the user. It becomes an executor only because a brief exists for the item it is working on. No special skill is involved.

## Modes and where things live

| | Tracker mode (connector available, epic in the tracker) | File mode (otherwise) |
|---|---|---|
| Epic and PBI status | The tracker's own status mechanism | `docs/handovers/<epic-slug>/epic.md` |
| Approved sequence and conventions | A comment on the epic headed **"Delivery Manager plan"**; a new one is posted after each re-plan, and the latest wins | `epic.md` |
| Brief | A comment on the PBI headed **"Delivery Manager brief"**, including the report template | `docs/handovers/<epic-slug>/NN-brief-<pbi-slug>.md` |
| Report | A comment on the PBI headed **"Executor report"** | `docs/handovers/<epic-slug>/NN-report-<pbi-slug>.md`, pre-created by the manager as a skeleton with `Status: awaiting executor` |

`NN` is the execution order (`01`, `02`, …), not the backlog order, so the folder records what actually happened when.

The headings and status values in this table are a protocol and must be used verbatim. They let any agent pick out handover messages among ordinary comments, and find pending reports.

`NN` numbers are never reused or renumbered, even when the remaining backlog is reordered or a PBI is retried (a retry gets a new number and a new brief).

In file mode the manager asks once per epic whether the handover files are committed or git-ignored, and records the answer in `epic.md`. Once chosen, an epic's mode is recorded and kept for the rest of the epic. A resumed manager does not switch modes because connector availability changed.

**`epic.md` minimum contents** (file mode): the epic goal; each PBI's definition, acceptance criteria and dependencies; the approved sequence; conventions (storage mode); and a dispatch log linking every issued brief and report with its state. Anything established during intake must end up here, not only in the conversation.

**Connector precondition.** In tracker mode both sessions need the tracker connector. Because an executor without the connector cannot read the brief, the precondition lives in the **printed prompt**, not in the brief: *"Work on PBI \<link\>. Read the Delivery Manager brief in its comments through the tracker connector; if you cannot read it, stop and tell me."* If posting the report fails later, the executor shows the completed report to the user with the recovery action. It never switches to file mode silently or claims the handover succeeded.

**Brief references.** Every brief has a stable reference: the tracker comment's link or ID, or the brief's file path. The executor records it as a `Delivery brief:` line in its spec and plan, and the report names the brief it answers. A brief is **pending** while it has no terminal report (`complete` or `abandoned`).

## Lifecycle

```
Manager: setup → intake → propose sequence → user approves
  repeat while PBIs remain:
    Manager: pick next PBI; propose branch base; user decides;
             write brief (+ report template/skeleton); PBI → in progress;
             print the exact executor prompt
    User:    fresh session; paste prompt
    Executor: full cycle with the user → finishing → user accepts → report
    User:    back to the manager (/resume, or a new session) → "completed"
    Manager: verify report; PBI → done; propose re-plan; user approves
Manager: close-out → epic summary → offer cleanup (file mode)
```

One PBI is in flight at a time by default. If two PBIs are genuinely independent and the user wants to run two executor sessions, the manager may issue both briefs. It suggests this but never does it unprompted. Simultaneous executors need **separate clones** of the repository (worktrees are not used in this project), because two sessions in one checkout share the branch, index and working files. In file mode the handover folder must be reachable from each clone. Without separate clones, execution is serialised.

## Delivery Manager workflow (the skill)

**Entry rule (every time the skill starts).** First look for existing delivery state: a "Delivery Manager plan" comment on the epic, or `docs/handovers/<epic-slug>/epic.md`. If it exists, this is a **resume**: keep the recorded mode, reconcile briefs, reports and tracker status, and finish any outstanding action first, such as an unprocessed report or a pending brief, before proposing a new dispatch. Never issue a second brief for a PBI that already has a pending brief. Only when no state exists does the manager start at step 0.

0. **Setup.** Detect the mode. In file mode, ask about committing the handover files. In tracker mode, if it is unclear how the board represents status, ask once and record the answer in the "Delivery Manager plan" comment.
1. **Intake.** Read the epic and every PBI. For each PBI, check that it is ready to brief: a clear goal, acceptance criteria and known dependencies. Report gaps. If the epic is too thin, fill the gaps with the user in conversation.
2. **Sequence.** Propose an order with a one-line reason per position (dependency, risk, value). Proposals to split, merge or add PBIs are suggestions only. Backlog *content* changes only after the user approves.
3. **Dispatch** (per PBI). Check whether the PBI depends on unmerged earlier work, and propose a branch base: from trunk, from branch X, or wait for X to merge. The user decides. Write the brief and the report template or skeleton, record the dispatch (plan comment or `epic.md`), and move the PBI to "in progress". Print the exact prompt for the user to paste: the connector-precondition prompt above in tracker mode, or *"Read your instructions from @\<brief path\>"* in file mode.
4. **Receive.** When the user says the PBI is completed, find the report and verify it: it exists, names the active brief, says complete, records the user's acceptance and has its sections filled. Only then mark the PBI done. A report that answers an abandoned or superseded brief is flagged to the user, not acted on. Read its impacts and discovered work, and propose changes to the remaining sequence or PBIs for approval. If the user abandons a PBI, mark the report `Status: abandoned` (file mode) or post a short comment saying so (tracker mode), and settle the PBI's status with the user.
5. **Close-out.** Check the finished PBIs against the epic's goal. Draft an epic summary, and post it to the epic as a comment or status update if the user approves. In file mode, offer to delete the handover folder (`git rm` if committed, a plain delete if ignored).

Routine status moves that follow from the protocol (in progress, done) need no separate approval.

**Red flags:** writing or editing product code; doing an executor's work; marking a PBI done without a verified report; changing backlog content without approval; starting a second executor without being asked.

## Brief and report

Both are templates in the skill folder (`brief-template.md`, `report-template.md`).

**Brief** (heading "Delivery Manager brief"):

1. **Identity:** epic name and link; PBI ID, title and link; position in the sequence ("3 of 7").
2. **What to deliver:** in tracker mode, a *reference* to the ticket's description and acceptance criteria (not a copy, which would drift); in file mode, the PBI text.
3. **Context:** the epic goal in one or two sentences; relevant results of earlier PBIs, linked to their specs or reports rather than retold; known constraints.
4. **Branch base:** the decision made with the user. The executor copies it into the plan header (see below).
5. **Scope guard:** other PBIs in the epic are out of scope. Work that spills into them is recorded in the report, not done.
6. **How to work:** follow the Superartes cycle (brainstorming → spec → plan → execution → finishing); put the `PBI:` and `Delivery brief:` lines in the spec and plan headers, and the `Branch base:` line in the plan header; as a first action, create a task-list item "Report to Delivery Manager after user acceptance" as a backup reminder; work with the user throughout; the PBI is done only when the user accepts it.
7. **Report template** (tracker mode; in file mode the brief points to the skeleton file).

**Report** (heading "Executor report"):

| Section | Purpose for the manager |
|---|---|
| Answers brief: the brief's comment link or file path | Ties the report to one dispatch (retries, late reports) |
| Status: `complete` / `abandoned` (file mode skeleton starts as `awaiting executor`) | Verification gate |
| User acceptance: date, plus a statement that the user accepted | Human confirmation of "done" |
| Delivered: short summary; links to spec, plan, branch | What now exists |
| Integration state: merged / PR open (link) / branch unmerged | Branch-base decision for the next PBI |
| Deviations: scope changes agreed with the user | Keeps the tracker accurate |
| Impacts on later work: changed interfaces, invalidated assumptions, new dependencies | Re-planning input |
| Discovered work: candidate new PBIs | Backlog suggestions for approval |

## Changes to existing skills

Each change is conditional and phrased so an agent on non-epic work can skip it at a glance. `brainstorming` and `writing-plans` are long and frequently loaded, so the additions must be short.

1. **`brainstorming`**
   - *Explore project context:* if the request names a tracker item, read the item and its comments. A comment headed "Delivery Manager brief" is the starting context.
   - *After the design:* the spec header carries optional metadata lines.
     - `**PBI:** <tracker> <ID> — "<title>" (<link>)`, whenever the work comes from a tracker item. This applies to any tracker-linked work, not only epic delivery.
     - `**Delivery brief:** <brief comment link, or brief file path>`, only when a Delivery Manager brief started the work. This line, not `PBI:`, marks managed delivery.
2. **`writing-plans`**: the plan header carries the same optional `**PBI:**` and `**Delivery brief:**` lines, copied from the spec, plus `**Branch base:** <branch>` when a brief specified a base other than trunk.
3. **`using-feature-branches`**: if the plan header has a `Branch base:` line, create the branch from that base instead of detecting trunk.
4. **`finishing-a-development-branch`**:
   - **Step 2:** if the executed plan has a `Branch base:` line, use it as the base for the review scope and the merge/PR target, instead of detected trunk.
   - **New Step 2.6, handover check** (before the options, while the branch still exists):
     - Identify the handover only from the `Delivery brief:` line of the plan executed in this session. The task-list reminder from the brief is the backup signal. Never search the repository for other specs or plans. **If there is no such line, there is no handover. Finish as today and ask nothing.**
     - Check that the brief is still pending (no terminal report). If it is, ask the user whether they accept the PBI as done.
     - **Not accepted:** stop finishing. No integration, no report; the work continues on the branch.
     - **Accepted:** continue to Step 3 as normal.
     - **Discard chosen at Step 3:** ask whether the PBI is abandoned; if so, write an `abandoned` report instead.
   - **New Step 5, handover report** (after Step 4, when the integration state is known; only if Step 2.6 found an accepted handover): fill in the report, naming the brief it answers, and post it (a comment, or the file with `Status: complete`). Then print the return instruction for the user, for example *"Go back to the Delivery Manager and say: completed PBI \<ID\>, report at \<link\>"*.

## User documentation

- **`README.md`**: a new section "Delivering an Epic" after "The Basic Workflow". It covers the three ways to start the manager (natural language; `/superartes:managing-epic-delivery <epic link>` in Claude Code; naming the skill in Codex, Cursor and OpenCode), the per-PBI loop with the exact prompts, where messages go in each mode, the cleanup option and the connector requirement. Also a line in the Skills Library under Collaboration.
- The user needs to remember only how to start the manager. Every later prompt is printed by the manager or the executor when it is needed.

## Testing

Following the repository's test-first approach to skills (`writing-skills`):

1. **Baseline (RED).** In a scratch repository with a file-mode `epic.md` of three small PBIs, ask an agent without the skill to act as Delivery Manager. Record its failures. These become what the skill must close.
2. **Manager scenario (GREEN).** Same setup, with the skill. Pass criteria:
   - an intake report listing the gaps;
   - a proposed sequence awaiting approval;
   - a brief and a report skeleton written;
   - the exact executor prompt printed;
   - no product code touched.
3. **Triggering.** Add prompts to `tests/skill-triggering/` (for example "act as delivery manager for epic X") that must load `managing-epic-delivery`, and add the skill to `run-all.sh`.
4. **Finishing handover steps.**
   - With a `Delivery brief:` line pointing at a pending skeleton, the agent asks for acceptance before the options, then fills in the report, including the integration state, and prints the return instruction.
   - Acceptance rejected: no integration happens and the branch remains.
   - Discard chosen: an `abandoned` report results, not a `complete` one.
   - **Regressions** (finishing must behave exactly as before and ask no extra question):
     - no plan metadata at all;
     - ordinary tracker-linked work with a `PBI:` line but no `Delivery brief:` line.
5. **Manager recovery.**
   - A fresh manager given only persisted state (`epic.md` plus handover files) resumes the outstanding action and issues no duplicate brief.
   - A retried PBI: an old `abandoned` report does not hide the new brief's pending state.
   - Compaction: simulate lost conversation context while the executed plan remains; the handover is still found.
6. **Execute-the-prose review.** A reviewer performs the manager and executor roles on the toy epic and reports where the instructions stop making sense.
7. **Manual end-to-end, run by the user**, with a checklist in the plan:
   - File mode: the full loop on two tiny PBIs, through cleanup.
   - Tracker mode, in an Asana test project with one epic and two PBIs:
     - the brief comment is posted;
     - "Work on PBI \<link\>" picks it up through `brainstorming`;
     - the spec and plan carry the `PBI:` and `Delivery brief:` lines;
     - the report comment is posted.

   Tracker mode has no automated coverage. It is a manual checkpoint.
8. **Existing checks stay green.** Run `python3 tests/codex-plugin/validate-codex-plugin.py`. Measure the new `SKILL.md`'s word count when writing it (target under 500 words).

## Risks

- **Tracker variety.** Status models differ between Asana, JIRA and others. Mitigation: use the tracker's own mechanism and ask once.
- **Agent ignores the conditional additions.** If an executor skips the `Delivery brief:` line, the report is not triggered. Mitigation: the brief asks for the line explicitly, and the manager's verification in step 4 notices a missing report.
- **Comment noise.** Briefs and reports add comments to tickets that humans also use. Mitigation: fixed headings and concise templates.

## Future work

- An epic-shaping skill; the intake step will then point to it.
- Optional automatic notification from executor to manager on Claude Code through cross-session messaging, if the manual loop proves tedious.
- Release: version bump across the six version files listed in `CLAUDE.md`, as its own step at the end.
