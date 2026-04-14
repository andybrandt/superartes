# Review Guidelines by Document Type

Reference material for composing review prompts. Read this before composing a review prompt to calibrate focus areas.

## Spec Reviews

Focus the reviewer on:

- **Architectural soundness** - does the proposed architecture make sense? Are the component boundaries clean? Will it scale to the stated requirements?
- **Completeness** - are there missing sections, undefined behaviors, or gaps that would block implementation planning?
- **Internal consistency** - do different sections contradict each other? Do data flows match component descriptions?
- **Feasibility** - can this actually be built as described? Are there hidden complexity traps?
- **YAGNI** - are there unrequested features, premature abstractions, or over-engineering?
- **DRY** - are we leveraging properly existing code & capabilities?
- **Design patterns** - are we following known design patterns when they would be a good match for the problem?
- **Suggestions** - alternative approaches, simplifications, better decompositions, edge cases worth considering

## Plan Reviews

Focus the reviewer on:

- **Spec alignment** - does the plan cover all spec requirements? Is there scope creep beyond the spec?
- **Task decomposition** - are tasks well-bounded and independent? Could an engineer pick up any task and know exactly what to do?
- **Buildability** - could someone follow this plan without getting stuck? Are there missing steps, unclear instructions, or implicit knowledge?
- **Completeness** - are there placeholders, TODOs, or vague steps? Does every code step have actual code?
- **DRY** - is there unnecessary duplication across tasks?
- **Code quality** - are the algorithms and code snippets in the plan correct and well-designed?
- **Suggestions** - better task ordering, alternative implementation approaches, missed optimizations

## Calibration

**Flag real issues, not style preferences.**

These ARE issues:
- A missing requirement that would cause the implementer to build the wrong thing
- A contradiction between two sections
- A step so vague it can't be acted on
- An architectural choice that will cause problems at scale

These are NOT issues:
- "I'd phrase this differently"
- "This section is less detailed than that section"
- Minor formatting or wording preferences
- Suggestions that add complexity without clear benefit

## Re-Reviews

When composing a re-review prompt (after changes from a previous cycle):
- Tell the reviewer what changed and why
- Ask it to focus on the changes rather than re-reviewing everything
- Mention which previous feedback points were addressed and which were intentionally declined (with reasons)
