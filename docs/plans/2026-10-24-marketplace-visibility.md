# Marketplace Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superartes:subagent-driven-development (recommended) or superartes:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This plan is followed jointly with the user, step by step.** Many steps are outward-facing (pushing to GitHub, changing repository settings, submitting to marketplaces, posting publicly) or must be done by a human (accepting legal terms, identity verification, web forms that refuse automated submission). Steps marked **👤 USER** are done by the user; steps marked **🔒 CONFIRM** need the user's explicit go-ahead in that moment, even if earlier steps were approved.

**Goal:** Make Superartes discoverable by listing it in Anthropic's plugin directory, Cursor's community directory and official marketplace, and OpenAI's Codex plugin directory, and by giving people browsing those catalogues and GitHub a clear reason to choose it over upstream Superpowers.

**Architecture:** Four phases. Phase 1 prepares the repository (license, README positioning and transparency, manifest descriptions, release 1.5.2, GitHub metadata, GitHub Release). Phase 2 is the icon gate: the user supplies the icon, and it ships in release 1.5.3 before any submission, because Anthropic's directory reads the icon only once, on the first submission. Phase 3 submits to the three directories. Phase 4 is outreach: a write-up with real examples, then curated "awesome" lists, which need the social proof the write-up generates.

**Tech Stack:** Git, GitHub CLI (`gh`), Claude Code CLI (`claude plugin validate`), Python 3 (Codex manifest validator), web portals (claude.ai, cursor.directory, platform.openai.com).

**Background (researched 2026-10-24):**
- Anthropic's official marketplace (`claude-plugins-official`, 315 plugins) already lists upstream `superpowers`; inclusion there is at Anthropic's discretion and cannot be applied for. Authors submit to the directory at `claude.ai/directory/manage`. The community marketplace (`claude-community`, 2,283 plugins) holds at least 17 Superpowers derivatives, so the listing must state what Superartes adds.
- Anthropic directory rules: <https://claude.com/docs/plugins/pre-submission-checklist.md>. A local `claude plugin validate .` on 2026-10-24 passed with two warnings: `CLAUDE.md` at plugin root is not loaded (harmless, it is the developer guide), and `ICON_MISSING`.
- Cursor: two separate systems with separate review queues ([staff answer](https://forum.cursor.com/t/cursor-marketplace-submission/170458)). `cursor.directory` is the community directory (self-managed, automated scan, review up to about two weeks), recommended by staff for most plugins; a listing there appears only on cursor.directory. `cursor.com/marketplace/publish` is the only route into Cursor's official, curated marketplace (manual review, no status page, follow-ups to marketplace-publishing@cursor.com). Sources conflict on whether the curated form still accepts most submissions, so the plan submits to both; submitting to each queue once is not a duplicate.
- OpenAI: portal at `platform.openai.com/plugins`; needs identity verification; **lifecycle hooks must be removed for a public listing**; Claude-specific wording should be provider-neutral unless it truly applies to that product. Guide: <https://developers.openai.com/plugins/guides/submit-claude-plugin.md>.
- Awesome lists: `hesreallyhim/awesome-claude-code` accepts recommendations only through its web issue form, submitted by a human, one resource at a time; it explicitly advises getting users first. `travisvn/awesome-claude-skills` closes pull requests automatically below **10 GitHub stars** and refuses pull requests generated or submitted with AI assistance. Both therefore come after the write-up, and the travisvn one is entirely the user's own work.

**Working-tree caution:** the working tree has unrelated uncommitted changes (`skills/writing-plans/SKILL.md`, several untracked `HANDOFF-*.md` and `docs/` files). Every commit in this plan stages **named files only** and inspects the staged diff (`git diff --cached --stat`) before committing. Never use `git add -A` or `git add .`.

**Phases 3 and 4 are independent queues.** Once Phase 2 is done, the three submissions in Phase 3 can run in parallel, and a slow review (or a Codex conversion that needs its own plan) blocks neither the other submissions nor the write-up, which can point to the existing self-hosted install route until listings go live.

---

## Task 0: Execution preflight

- [ ] **Step 1: Inventory the working tree**

Run: `git status --short`
Expected on 2026-10-24: modified `skills/writing-plans/SKILL.md` (unrelated, leave alone); untracked `HANDOFF-*.md`, `docs/2026-07-10-superpowers-port-proposals.md`, `docs/plans/2026-07-10-port-superpowers-p1-p2-p8.md`, `docs/plans/2026-08-19-subagent-driven-development-p1.md` (unrelated, leave alone). This plan and its `CLAUDE_NOTES.md` entry are committed on `main` before execution starts. Report anything else to the user before continuing.

- [ ] **Step 2: Create the feature branch**

Via `superartes:using-feature-branches`, branch name `feature/marketplace-visibility`. Uncommitted unrelated changes carry over into the branch untouched; the named-file staging rule keeps them out of every commit.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `LICENSE` | Modify | Add fork author's copyright line, keep upstream's |
| `README.md` | Modify | New "Why Superartes?" section near top; new "What Superartes runs and sends" section; later, install instructions for the directory listings |
| `.claude-plugin/plugin.json` | Modify | New description, version, later `icon` |
| `.claude-plugin/marketplace.json` | Modify | New descriptions, version |
| `.cursor-plugin/plugin.json` | Modify | New description, version, later possibly `logo` |
| `.codex-plugin/plugin.json` | Modify | New `description` and `shortDescription`, version, later `logo` |
| `package.json` | Modify | Version |
| `CLAUDE.md` | Modify | Version reference |
| `CHANGELOG.md` | Modify | Entries for 1.5.2 and 1.5.3 |
| `assets/icon.png` | Create (👤 USER) | Listing icon, 512–2048 px square PNG |
| `assets/app-icon.png` | Remove after Task 7 once no manifest or code uses it | Old 256 px icon (historical docs may keep mentioning it) |

The canonical one-line description used in every manifest (decided here, change it in one place if the user rewords it). It deliberately does not promise review of *every* change: external code review is a user decision before integration, it has degraded paths, and second-model review is established only for Claude Code and Codex controllers.

> **Development workflow skills for coding agents: brainstorm, spec, plan, TDD and code review, with optional independent review of specs, plans and code by a second AI model. For Claude Code, Codex and Cursor.**

---

## Phase 1 — Repository preparation

### Task 1: Add fork copyright line to LICENSE

**Files:**
- Modify: `LICENSE:3`

- [ ] **Step 1: Edit the copyright lines**

Current line 3:

```
Copyright (c) 2025 Jesse Vincent
```

Replace with:

```
Copyright (c) 2025 Jesse Vincent
Copyright (c) 2026 Andy Brandt
```

The MIT license requires keeping the original notice; adding a second line for the fork's modifications is the usual practice.

- [ ] **Step 2: Check the diff touches only the copyright notice**

Run: `git diff LICENSE`
Expected: exactly one added line, `+Copyright (c) 2026 Andy Brandt`, and nothing else. Whether GitHub still recognises the license is checked after pushing, in Task 5 Step 3 (`hesreallyhim/awesome-claude-code`'s bot relies on that recognition).

No commit yet; Phase 1 commits once in Task 4.

### Task 2: README positioning and transparency

**Files:**
- Modify: `README.md` (intro section; new section after "Optional Dependencies")

- [ ] **Step 1: Insert "Why Superartes?" directly after the intro paragraph (before `## How it works`)**

```markdown
## Why Superartes?

Superartes builds on [Superpowers](https://github.com/obra/superpowers) and adds:

- **Review by a second AI model.** Specs and plans, and code changes before you integrate them, can be reviewed by a different model family: Codex reviews when you work in Claude Code, and Claude reviews when you work in Codex. A second model catches mistakes the first one keeps repeating. It needs the other model's CLI installed; without it, Superartes says so and offers a clearly labelled same-model review instead.
- **One workflow in three tools.** The same skills work in Claude Code, Codex and Cursor (second-model review is available in Claude Code and Codex).
- **Feature branches instead of worktrees,** which behave predictably in Docker-heavy projects.
- **Commits only at releasable checkpoints,** so every commit leaves the project working.

The full list is in [Changes from upstream superpowers](#changes-from-upstream-superpowers).
```

- [ ] **Step 2: Inventory every executable and external integration before writing the disclosure**

A grep for network calls alone is not enough: Markdown skills can direct MCP tool calls, and browser code can open WebSockets. Run all three:

```bash
git ls-files -- hooks .opencode skills agents | grep -v -E '\.md$'
git grep -n -E "mcp__|WebSocket|curl |wget |Invoke-WebRequest|fetch\(|https?\.request|XMLHttpRequest" -- hooks .opencode skills agents
cat hooks/hooks.json hooks/hooks-cursor.json
```

Expected, as of 2026-10-24: the executable files are the hook scripts, the OpenCode loader `.opencode/plugins/superartes.js`, the brainstorming server and its launcher/helper scripts, and the external-review runners; the external integrations are the review CLIs and Google Stitch MCP (`skills/using-stitch`); the brainstorming page's WebSocket connects back to the local server. Any executable or external integration **not** covered by the Step 3 text: stop and extend the text with the user before continuing.

- [ ] **Step 3: Insert "What Superartes runs and sends" after the `## Optional Dependencies` section (before `## Philosophy`)**

Anthropic's security scan looks for undisclosed behaviour, so the plugin's own automatic behaviour and every optional integration are stated here.

```markdown
## What Superartes runs and sends

Superartes is mostly Markdown instructions that your coding agent follows. Like any workflow, those instructions ask the agent to do ordinary development work in your project, such as running tests, installing dependencies your project needs, and making Git commits, using the agent's normal permissions. Beyond that, Superartes itself runs or connects to the following.

**Automatically, at session start:**

- **Claude Code:** a `SessionStart` hook (on startup, clear and compaction) runs `hooks/session-start` through the `hooks/run-hook.cmd` wrapper, which also makes it work on Windows. It reads `skills/using-superartes/SKILL.md` and adds it to the agent's context.
- **Cursor:** a `sessionStart` hook runs `hooks/session-start` directly, with the same effect.
- **OpenCode:** the loader `.opencode/plugins/superartes.js` registers the skills folder and adds the same bootstrap instructions.
- **Codex:** no hook; Codex finds the skills through its own skill discovery.

None of these make network connections.

**Only when you use the corresponding feature:**

- **Brainstorming visual companion.** When you agree to use it, the brainstorming skill starts a small Node.js server (`skills/brainstorming/scripts/server.cjs`) bound by default to `127.0.0.1`, so it is reachable only from your own computer; `start-server.sh --host <address>` binds another interface. It writes the mockups, interaction events and a log to local files for the session.
- **Independent reviews.** If the Codex CLI (under Claude Code) or the Claude Code CLI (under Codex) is installed and signed in, the `external-review` and `external-code-review` skills run it. That sends the review prompt and the relevant files, plans or diffs to that provider (OpenAI or Anthropic) under your own account, and may incur usage costs. Review output is kept in local temporary files until the skill cleans them up. Under Codex this needs your explicit authorization; see [Codex review setup](docs/README.codex.md#independent-claude-reviews).
- **Google Stitch.** If the Google Stitch MCP server is installed in your agent, the `using-stitch` skill sends design instructions to Google Stitch to generate and edit UI designs.

Superartes contains no telemetry: it collects no usage data of its own and reports nothing to its author.
```

- [ ] **Step 4: Check the section order and the anchors**

Run: `grep -n -E "^## (Why Superartes\?|What Superartes runs and sends|Changes from upstream superpowers)" README.md`
Expected: three lines, in the order Why → … → What Superartes runs → … → Changes from upstream. The rendered page and its links are checked on GitHub after pushing (Task 4 Step 6).

### Task 3: Unified description in all manifests

**Files:**
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`

- [ ] **Step 1: Set the description**

In `.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json` and `.codex-plugin/plugin.json`, set `"description"` to the canonical description (see File Structure). In `.claude-plugin/marketplace.json`, set `plugins[0].description` to it, and set the top-level `"description"` to:

```json
"description": "Superartes marketplace: development workflow skills with independent second-model review"
```

- [ ] **Step 2: Update the Codex interface texts**

In `.codex-plugin/plugin.json`, inside `interface`:

```json
"shortDescription": "Planning, TDD and delivery workflows with second-model review",
"longDescription": "Use Superartes to guide agent work through brainstorming, specification, implementation planning, test-driven development, systematic debugging, code review and finishing the branch. Specs, plans and code changes can be independently reviewed by a second AI model through the Claude Code CLI.",
```

- [ ] **Step 3: Validate JSON syntax and that all four descriptions are identical**

The Codex validator accepts any non-empty description, so it cannot catch a typo or a missed file. Run:

```bash
python3 -I - <<'EOF'
import json
expected = ("Development workflow skills for coding agents: brainstorm, spec, plan, TDD and code review, "
            "with optional independent review of specs, plans and code by a second AI model. "
            "For Claude Code, Codex and Cursor.")
found = {
    ".claude-plugin/plugin.json": json.load(open(".claude-plugin/plugin.json"))["description"],
    ".claude-plugin/marketplace.json plugins[0]": json.load(open(".claude-plugin/marketplace.json"))["plugins"][0]["description"],
    ".cursor-plugin/plugin.json": json.load(open(".cursor-plugin/plugin.json"))["description"],
    ".codex-plugin/plugin.json": json.load(open(".codex-plugin/plugin.json"))["description"],
}
bad = [name for name, text in found.items() if text != expected]
print("MISMATCH: " + ", ".join(bad) if bad else "OK: all four descriptions match")
raise SystemExit(1 if bad else 0)
EOF
```

Expected: `OK: all four descriptions match`. A JSON syntax error makes the script fail with a traceback, which also counts as failure.

### Task 4: Release 1.5.2 (releasable checkpoint)

**If the user's icon is already at `assets/icon.png` when this task starts,** do Task 7 Steps 2–4 first and include the icon in this release; Task 7 then shrinks to its verification. Otherwise release now and ship the icon in 1.5.3, so the icon does not hold up the README and metadata work.

**Files:**
- Modify: `package.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json`, `.codex-plugin/plugin.json`, `CLAUDE.md`, `CHANGELOG.md`

- [ ] **Step 1: Bump the version to 1.5.2 in every version file**

The six locations listed in `CLAUDE.md` under "Version Files": `package.json` `version`, `.claude-plugin/plugin.json` `version`, `.claude-plugin/marketplace.json` `plugins[0].version`, `.cursor-plugin/plugin.json` `version`, `.codex-plugin/plugin.json` `version`, and the "Version 1.5.1" text in `CLAUDE.md`'s Project Overview.

- [ ] **Step 2: Add the CHANGELOG entry above `## [1.5.1]`**

```markdown
## [1.5.2] - 2026-10-24

### Changed

- **Clearer positioning for directory listings:** The README now opens with what Superartes adds to Superpowers, and every plugin manifest uses one description that leads with independent second-model review.
- **Disclosure of what the plugin runs and sends:** A new README section lists the session-start hook, the local brainstorming server and the optional review CLIs, and states that Superartes collects no telemetry.
- **License names the fork's author** alongside the upstream copyright.
```

Use the actual date of execution if it differs.

- [ ] **Step 3: Run all validators**

```bash
grep -rn '1\.5\.1' package.json .claude-plugin .cursor-plugin .codex-plugin CLAUDE.md
python3 tests/codex-plugin/validate-codex-plugin.py
claude plugin validate .
```

Expected: the `grep` prints nothing; the Codex validator passes (it enforces matching versions); `claude plugin validate` prints `✔ Validation passed with warnings`, with only the `CLAUDE.md` warning and `ICON_MISSING` (the icon arrives in Phase 2).

- [ ] **Step 4: Commit (releasable checkpoint)**

Use `superartes:commit-message` for the message. Stage named files only:

```bash
git add LICENSE README.md CHANGELOG.md CLAUDE.md package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json .cursor-plugin/plugin.json .codex-plugin/plugin.json
git status --short
```

Expected `git status`: the nine files staged (`M `); the pre-existing unrelated changes still unstaged or untracked.

- [ ] **Step 5: 🔒 CONFIRM — merge to `main` and push**

The directories and GitHub read `main` on GitHub, so this work must be pushed before Phase 3. Follow `superartes:finishing-a-development-branch` to merge the feature branch into `main`, then, after the user confirms: `git push origin main`.

- [ ] **Step 6: 👤 USER — check the rendered README on GitHub**

Open <https://github.com/andybrandt/superartes#why-superartes>. Check that both new sections render, and click the "Changes from upstream superpowers" link and the "Codex review setup" link; both must land on the right place.

### Task 5: GitHub repository metadata

- [ ] **Step 1: 🔒 CONFIRM — set the description and homepage**

The current description ends in "(my modifications)" and says nothing about what is different.

```bash
gh repo edit andybrandt/superartes \
  --description "Development workflow skills for Claude Code, Codex and Cursor: brainstorm, spec, plan, TDD and code review, with optional independent review of specs, plans and code by a second AI model. Fork of obra/superpowers." \
  --homepage "https://github.com/andybrandt/superartes#why-superartes"
```

- [ ] **Step 2: 🔒 CONFIRM — add topics**

```bash
gh repo edit andybrandt/superartes \
  --add-topic claude-code --add-topic claude-code-plugin --add-topic claude-skills \
  --add-topic agent-skills --add-topic codex --add-topic openai-codex \
  --add-topic cursor --add-topic cursor-plugin --add-topic ai-agents \
  --add-topic tdd --add-topic code-review --add-topic developer-workflow
```

- [ ] **Step 3: Verify, including license recognition after the LICENSE change**

Run: `gh repo view andybrandt/superartes --json description,homepageUrl,repositoryTopics,licenseInfo`
Expected: the new description, the homepage URL, twelve topics, and `"licenseInfo":{"key":"mit",...}` (GitHub still recognises the MIT license with two copyright lines).

### Task 6: GitHub Release for 1.5.2

The repository has no GitHub Releases. Origin carries 62 tags, mostly upstream's `v4.x` and `v5.x`, plus `v5.0.6-andy.2`; no Superartes `v1.x` tag exists. Upstream's higher version numbers can make tools that sort tags show `v5.0.6` as "latest".

- [ ] **Step 1: 👤 USER — decide what to do with the upstream tags**

Options:
1. **Keep them (recommended)** and mark each Superartes release as "Latest" explicitly. Nothing is lost; GitHub's "Latest release" badge follows Releases, not tags.
2. Delete the upstream tags from origin (`git push origin --delete <tag>` for each). This is irreversible for anyone who fetched them and gains little.

- [ ] **Step 2: 🔒 CONFIRM — create the tag and the release**

```bash
git tag -a v1.5.2 -m "Superartes 1.5.2"
git push origin v1.5.2
awk '/^## \[1\.5\.2\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md > "$SCRATCHPAD/release-notes-1.5.2.md"
gh release create v1.5.2 --title "Superartes 1.5.2" --notes-file "$SCRATCHPAD/release-notes-1.5.2.md" --latest
```

Set `SCRATCHPAD` to the executing session's scratchpad directory; the notes file does not belong in the repository.

- [ ] **Step 3: Verify the release is latest and points at the pushed release commit**

```bash
gh release list --repo andybrandt/superartes --limit 3 --json tagName,isLatest
git rev-parse v1.5.2^{commit} origin/main
```

Expected: the first entry is `{"isLatest":true,"tagName":"v1.5.2"}` (note: `gh release view` has no `isLatest` field in gh 2.100.0); the two hashes printed by `git rev-parse` are identical.

---

## Phase 2 — Icon gate (must finish before any submission)

### Task 7: Add the user's icon, release 1.5.3

**Why this blocks Phase 3:** Anthropic's directory takes the listing icon from the plugin only the first time the plugin is saved or submitted in the developer portal; adding or changing it later does not change the listing.

**Files:**
- Create (👤 USER): `assets/icon.png`
- Modify: `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, possibly `.cursor-plugin/plugin.json`, version files, `CHANGELOG.md`
- Remove if unreferenced: `assets/app-icon.png`

- [ ] **Step 1: 👤 USER — provide the icon** at `assets/icon.png`: a square PNG, 512 to 2048 pixels on each side, under 2 MB. (SVG and WebP are not accepted by Anthropic's directory.)

- [ ] **Step 2: Verify the file meets the requirements**

Run: `file assets/icon.png && du -k assets/icon.png`
Expected: `PNG image data, N x N` with equal N between 512 and 2048; size under 2048 KB. If not, hand back to the user.

- [ ] **Step 3: Reference the icon in the manifests**

- `.claude-plugin/plugin.json`: add `"icon": "./assets/icon.png",` after `"description"`.
- `.codex-plugin/plugin.json`: change `interface.logo` from `./assets/app-icon.png` to `./assets/icon.png`.
- `.cursor-plugin/plugin.json`: check Cursor's plugin manifest reference (<https://cursor.com/docs/plugins>) for a `logo` field. If it exists, add `"logo": "./assets/icon.png",`. If not, change nothing.

- [ ] **Step 4: Remove the old icon once no live consumer uses it**

Historical specs, plans and `CLAUDE_NOTES.md` mention `app-icon.png` and must stay as they are. Search only the places that load it:

```bash
git grep -n "app-icon.png" -- .claude-plugin .cursor-plugin .codex-plugin .agents hooks skills agents .opencode README.md
```

Expected: no matches (after Step 3 changed `.codex-plugin/plugin.json`). Then `git rm assets/app-icon.png`. If a match remains, update that live reference first.

- [ ] **Step 5: Bump to 1.5.3 and add the CHANGELOG entry**

Same six version locations as Task 4 Step 1. CHANGELOG, above `## [1.5.2]`:

```markdown
## [1.5.3] - <execution date>

### Changed

- **Plugin icon:** Added a directory-ready icon (`assets/icon.png`) to the Claude Code, Codex and, where supported, Cursor manifests, replacing the 256 px `app-icon.png`.
```

- [ ] **Step 6: Run all validators**

```bash
grep -rn '1\.5\.2' package.json .claude-plugin .cursor-plugin .codex-plugin CLAUDE.md
python3 tests/codex-plugin/validate-codex-plugin.py
claude plugin validate .
```

Expected: no `grep` output; Codex validator passes; `claude plugin validate` shows **no** `ICON_MISSING` warning (the `CLAUDE.md` warning remains and is expected).

- [ ] **Step 7: Commit, 🔒 CONFIRM merge and push, then tag and release `v1.5.3`**

Use `superartes:commit-message`. Stage named files: `assets/icon.png`, the manifests, version files, `CHANGELOG.md` (plus the `git rm` from Step 4). Push `main`, then repeat Task 6 Step 2 and Step 3 with `1.5.3`.

---

## Phase 3 — Directory submissions

### Task 8: Anthropic plugin directory

- [ ] **Step 1: 👤 USER — confirm you can submit**

Open <https://claude.com/docs/directory/publish.md>, section "Confirm you can submit to the directory", and check that your claude.ai plan and role allow it. Connect your GitHub account on claude.ai (it needs push access to `andybrandt/superartes`).

- [ ] **Step 2: 👤 USER — validate in the portal**

Open <https://claude.ai/directory/manage> → **Submit new** → **Plugin bundle**. Source: repository `andybrandt/superartes`, plugin path empty (the plugin is the repository root), tracked branch `main`. Select **Validate**.

Expected: no **Blocking** findings. Likely **Notes/Warnings**: `CLAUDE.md` at root. Possible **Policy hold**: none expected; the hook scripts are at the repository root, so the "Scripts the validator couldn't follow" hold does not apply. Paste the report into the session; any Blocking finding goes back to the agent to fix, then **Re-validate**.

- [ ] **Step 3: 👤 USER — listing details**

Check that name (`superartes`) and description come from `plugin.json`, and that the README renders.

- [ ] **Step 4: 👤 USER — data-handling answers**

Answer against the portal's own definitions; the facts to answer from:

- Superartes has no server and collects nothing for its author.
- It reads the user's project files as part of normal agent work. Those files, and therefore review prompts built from them, can contain personal data (names, email addresses in commits or code) that exists in the user's repository. The honest answer to a "reads or stores personal data" question is therefore likely **yes, incidentally**, with this explanation, rather than a flat "no".
- Data sent elsewhere, only when the user has the integration installed: review prompts and relevant files, plans or diffs to OpenAI (Codex CLI) or Anthropic (Claude Code CLI) under the user's own account; design instructions to Google Stitch through its MCP server. Disclosed in README "What Superartes runs and sends".
- Retention: Superartes keeps review output in local temporary files until the skill cleans them up and stores nothing else outside the user's repository. Retention by OpenAI, Anthropic, Google and their CLIs is governed by those providers' terms.
- Intended for people under 18: no.

- [ ] **Step 5: 👤 USER — compliance**

Contact email (your choice; `andy@codesprinters.com` is the obvious one). Read and tick the four acknowledgements yourself; they are legal terms.

- [ ] **Step 6: 👤 USER — choose update delivery and submit**

Recommendation: **GitHub push webhook**, tracking `main`. Each push is scanned, and by default an Anthropic reviewer publishes each version, so nothing reaches users unreviewed. Complete the webhook setup the portal offers (otherwise only the scheduled check runs). Then **Submit for review**.

- [ ] **Step 7: 👤 USER — publish the passing version**

On the plugin's page in the developer portal, open the **Versions** tab. When the version shows as passing (or after a held version is cleared by a reviewer), select **Publish** where the portal offers it; under the default setting this asks an Anthropic reviewer to publish that version. Wait until the version is shown as live.

- [ ] **Step 8: After the version is live — verify where the listing appears**

```bash
curl -s https://raw.githubusercontent.com/anthropics/claude-plugins-community/main/.claude-plugin/marketplace.json \
  | python3 -I -c "import json, sys; print([p['name'] for p in json.load(sys.stdin)['plugins'] if p['name'] == 'superartes'])"
```

Also search <https://claude.com/marketplace/plugins> for Superartes.

- [ ] **Step 9: Smoke-test the listed install route, then document it**

Before writing any install instruction, run Task 13 Step 2 for this listing (the instruction is documented only once it has been seen to work). Then add the verified method (for example `/plugin marketplace add anthropics/claude-plugins-community` followed by `/plugin install superartes@claude-community`, or adding it from the claude.ai directory) as the first option in README's "Claude Code" install section, keeping the self-hosted marketplace as the second option. Commit with `superartes:commit-message`, 🔒 CONFIRM push.

### Task 9: Cursor (community directory and official marketplace)

- [ ] **Step 1: 👤 USER — submit**

Open <https://cursor.directory/plugins/new>, sign in with GitHub, paste `https://github.com/andybrandt/superartes`, submit. The site detects skills, agents and hooks from `.cursor-plugin/plugin.json` and runs an automated security scan. Review takes up to about two weeks.

- [ ] **Step 2: 👤 USER — submit to the official Cursor marketplace too**

Apply once at <https://cursor.com/marketplace/publish> with the same repository. This is a separate queue from cursor.directory, so it is not a duplicate. There is no automatic confirmation; do not resubmit. Follow-ups go to marketplace-publishing@cursor.com.

- [ ] **Step 3: After a listing goes live — smoke-test, then add a Cursor section to the README**

Install Superartes in Cursor from the listing, start a new chat with a prompt such as "help me plan this feature", and confirm a Superartes skill is used. Then add `### Cursor` between `### Codex` and `### OpenCode` in README's Installation section, with the verified install instruction and a link to the listing. Commit with `superartes:commit-message`, 🔒 CONFIRM push.

- [ ] **Step 4: If no response after three weeks** — for cursor.directory, check the forum thread <https://forum.cursor.com/t/cursor-marketplace-submission/170458> for the current escalation contact; for the official marketplace, write once to marketplace-publishing@cursor.com. Never submit the same queue twice.

### Task 10: OpenAI Codex plugin directory (compatibility checks and a decision gate first)

The OpenAI guide requires: no lifecycle hooks, reusable agent procedures converted to skills, provider-neutral wording unless it truly applies to a product, inspection of the generated manifest, and testing the imported skills in a clean environment. All checks below concern **the package that will be submitted**, not the existing Git-backed install.

- [ ] **Step 1: 👤 USER — portal prerequisites**

At <https://platform.openai.com/plugins>: complete individual identity verification, and make sure your account has **Apps Management** write access in the owning organization.

- [ ] **Step 2: Compatibility assessment (no repository changes)**

Run and report to the user:

```bash
git grep -n -i -E "claude code|claude\.ai" -- skills
git grep -n -E "agents/code-reviewer|code-reviewer\.md" -- skills
git grep -h -o -E "docs/[A-Za-z0-9._/-]+\.md" -- README.md skills | sort -u
```

What the results meant on 2026-10-24:
- **Hooks:** `.codex-plugin/plugin.json` declares none; the archive in Step 4 leaves `hooks/` out.
- **Agent procedures:** the code reviewer procedure already lives in a skill (`skills/requesting-code-review/code-reviewer.md`, which `codex-tools.md` lets Codex use as a worker prompt), and the Codex manifest declares no agents. So `agents/` is **left out** of the package and no conversion is needed.
- **Referenced documentation:** `docs/README.codex.md` is referenced by the README and by skills and must be in the package; the other matches (`docs/file1.md`, `docs/plans/feature-plan.md` and similar) are examples inside skill text, not real files.
- **Wording:** 37 lines mention Claude Code or claude.ai. Sort them into (a) platform-adaptation text that truly applies to Claude Code, which the guide allows, and (b) wording that should be provider-neutral.

- [ ] **Step 3: 👤 USER — decision gate**

If category (b) is small, fix it in a 1.5.x release (validators, commit, 🔒 CONFIRM push, as in Task 4) and continue. If it is large, or anything in Step 2 would change behaviour in Claude Code, **stop Task 10** and write a separate plan; do not rewrite skills inside this plan. The other submissions and Phase 4 continue regardless.

- [ ] **Step 4: Build and check the upload archive (skills only, no hooks, no agents)**

Set `SCRATCHPAD` to the executing session's scratchpad directory and `VERSION` to the current version:

```bash
ZIP="$SCRATCHPAD/superartes-codex-$VERSION.zip"
git archive --format=zip -o "$ZIP" HEAD \
  .claude-plugin .codex-plugin skills assets docs/README.codex.md README.md LICENSE
unzip -tq "$ZIP" && {
  if unzip -Z1 "$ZIP" | grep -E '^(hooks|agents)/'; then echo "FAIL: hooks or agents in archive"; else echo "OK: no hooks or agents"; fi
  echo "SKILL.md files: $(unzip -Z1 "$ZIP" | grep -c -E '^skills/[^/]+/SKILL\.md$') (repository: $(git ls-files 'skills/*/SKILL.md' | wc -l))"
  unzip -Z1 "$ZIP" | grep -x 'docs/README.codex.md'
}
```

Expected: `No errors detected in compressed data of …`, `OK: no hooks or agents`, two equal `SKILL.md` counts (18 on 2026-10-24), and `docs/README.codex.md`. A missing or corrupt archive fails at `unzip -tq` and prints none of the later lines.

- [ ] **Step 5: 👤 USER — upload, then inspect the generated manifest and scan results**

**Create plugin** → **Skills only** → upload the archive. Compare the manifest the portal generates with `.codex-plugin/plugin.json`: name `superartes`, the current version, the canonical description, and the `interface` texts and logo. Paste any differences and every scan result into the session; fix each before submitting.

- [ ] **Step 6: Test the imported package in a clean environment before submitting**

If the portal offers a test install or a download of the converted package, install that in Codex with an empty Codex home (`CODEX_HOME="$(mktemp -d)" codex`, signing in when asked), start a session with "help me plan this feature", and confirm that (a) a Superartes skill is invoked, and (b) the skill's referenced files are found, e.g. ask it to open the "Codex review setup" link target `docs/README.codex.md`. If the portal offers no way to test before submission, say so to the user and run this test immediately after the listing goes live, before Step 8.

- [ ] **Step 7: 👤 USER — submit for review**

- [ ] **Step 8: After listing — smoke-test, then update `docs/README.codex.md` and README's Codex section** with the verified directory install path as the first option (Task 13 Step 2 first). Commit with `superartes:commit-message`, 🔒 CONFIRM push.

---

## Phase 4 — Outreach

### Task 11: Write-up about second-model review

- [ ] **Step 1: 👤 USER — choose where it lives**

Recommendation: a platform you own (the Code Sprinters blog), cross-posted to LinkedIn and dev.to. Not in this repository: it is promotional material, not project documentation.

- [ ] **Step 2: Draft from real, verifiable incidents**

Working title: "Letting a second AI model review the first one's work: what it actually catches". Outline:

1. The problem: one model reviewing its own plan repeats its own blind spots.
2. The workflow in nine steps (README "How it works").
3. Three concrete catches, taken from `CLAUDE_NOTES.md`:
   - Eleven defects in one skill rewrite survived a same-model review and were found only when the reviewer *executed* the documented commands, including a flowchart with no exit for a failed launch.
   - A test suite that reported green while testing nothing (`pwsh -File <missing>` exits 64, the same code as a real usage error).
   - A recommended Windows null-device path that would have broken every Windows launch.
4. Cost and limits: it needs both CLIs, it costs usage, and it degrades to a labelled same-model review when the second model is unavailable.
5. How to try it: the install commands from the directory listings.

Before publishing, the user checks each incident's description against the note it came from.

- [ ] **Step 3: 👤 USER — publish and share**

Publish, then post a link: Hacker News as "Show HN: Superartes – a second AI model reviews your coding agent's specs, plans and code" (posting rules: <https://news.ycombinator.com/showhn.html>), r/ClaudeAI (read the subreddit's self-promotion rules first), LinkedIn. These must be posted by the user personally.

### Task 12: Curated lists and aggregators

- [ ] **Step 1: 👤 USER — `hesreallyhim/awesome-claude-code`**

Eligibility: at least 14 days of history with continued development, or 100 stars; Superartes meets the first. Submit through the web form only (pull requests and `gh` submissions are refused): <https://github.com/hesreallyhim/awesome-claude-code/issues/new?template=recommend-resource.yml>. Description, one line, no emojis, descriptive rather than promotional:

> Development workflow skills with optional independent review of specs, plans and code by a second AI model (Codex or Claude); a fork of Superpowers that works in Claude Code, Codex and Cursor.

- [ ] **Step 2: 👤 USER — `travisvn/awesome-claude-skills`, only once the repository has at least 10 stars**

Below 10 stars the pull request is closed automatically. The list also refuses pull requests generated or submitted with AI assistance, so the agent does **not** draft the entry or the pull request for this one; the user reads the current `CONTRIBUTING.md` and writes both personally. The write-up and discussion threads can supplement the star count as social proof. Until the threshold is met, leave this step open.

- [ ] **Step 3: `GetBindu/awesome-claude-code-and-skills` pull request**

Read the list's README for its entry format, then add, in the section that lists plugin collections:

```markdown
- [Superartes](https://github.com/andybrandt/superartes) - Development workflow skills with optional independent review of specs, plans and code by a second AI model. Works in Claude Code, Codex and Cursor.
```

🔒 CONFIRM before opening; it is posted under the user's GitHub account.

- [ ] **Step 4: `ComposioHQ/awesome-claude-skills` — check fit, probably skip**

Its `CONTRIBUTING.md` expects one folder per skill with a `SKILL.md` template, which does not fit a plugin of interdependent skills. Check whether its README has a section listing skill collections or plugins; if yes, propose a one-line entry there (🔒 CONFIRM); if no, skip and note why in this plan.

- [ ] **Step 5: `claudemarketplaces.com` — check automatic listing**

About a week after Task 5, search the site for "superartes". If absent, look for its submission route and add it (🔒 CONFIRM).

### Task 13: Follow-up

- [ ] **Step 1:** Weekly for three weeks after Phase 3: check the Anthropic portal's **Versions** tab, the two Cursor submissions and the OpenAI portal status; answer reviewer questions the same day.
- [ ] **Step 2: Smoke test (required before any README install instruction in Tasks 8–10 is committed).** Install Superartes from the listing in a session where the self-hosted copy is disabled, to avoid duplicate skills (Claude Code: `claude plugin disable superartes@superartes`, re-enable afterwards with `claude plugin enable superartes@superartes`). Start a new session with "help me plan this feature" and confirm a Superartes skill is invoked. Record the exact install commands that worked; those are what the README gets.
- [ ] **Step 3:** If `hesreallyhim/awesome-claude-code` accepts the recommendation, add its badge under the README title (commit with `superartes:commit-message`, 🔒 CONFIRM push):

```markdown
[![Mentioned in Awesome Claude Code](https://awesome.re/mentioned-badge.svg)](https://github.com/hesreallyhim/awesome-claude-code)
```
