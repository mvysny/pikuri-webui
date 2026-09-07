# Transcript density: consume pikuri's tool summaries

**Ported from `../pikuri-tui/ideas/hide-thinking-and-tool-calls.md`**, which is
the design record for the *feature*. Everything in it has now landed here
except the last step, which waits on pikuri.

Landed, and nothing about it survives in this file — the design is in
`DECISIONS.md`, the invariant in AGENTS.md's **Scope decisions**, the
user-facing half in `README.md`:

- The `[ui]` config fix (`D_schema_complete_config`, "Amended: the schema
  drifted…").
- The sanitizer on tool lines ({ToolLine}).
- Part 1, the thinking toggle, as a disclosure per block rather than the TUI's
  global hide (`D_details_per_block`, `D_disclosure_state_on_the_block_div`,
  `D_ui_cookie_over_config`).
- Part 2 v1, short-form tool lines: both forms in the block, CSS picking,
  `/toollines` (`D_both_forms_in_the_block`).

## What is left — v2

When `Pikuri::Agent::Event::ToolCall` carries `display_name:` / `argument:`
and `ToolResult` carries `summary:`, print those and delete {ToolLine}'s
CamelCase helper, its first-value pick and its `Error:` check. The v1 look was
chosen so v2 changes no pixels except the result line's wording.

Blocked on `../pikuri/ideas/tool-summary-lines.md`, still unbuilt. Two things
worth knowing before starting:

- **The first-value pick is the part v2 actually fixes.** {ToolLine} shows the
  first *value* of `arguments` because the event carries no schema — a bet on
  models emitting keys in schema order. `display_name:` / `argument:` retire
  the bet.
- **The inline-result divergence may or may not survive.** v1 prints a result
  short enough to read whole instead of measuring it, which pikuri-tui does not
  do (`D_both_forms_in_the_block`). A real `summary:` might make that
  unnecessary — or might not, for `calculator`. Decide it then; it is one
  condition either way.

`markdown` as a third `[ui]` key is still parked, and still needs a feature
first: this shell has no such flag at all, kramdown always runs. pikuri-tui
parked it as `D_markdown_flag_deferred`.

Delete this file — and the pikuri-tui one, whose only remaining reason to exist
is this copy — once v2 has landed.
