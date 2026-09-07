# Transcript density: shorten tool lines

**Ported from `../pikuri-tui/ideas/hide-thinking-and-tool-calls.md`**, which is
the design record for the *feature*. Read it once for the reasoning; this file
is only what the web shell does, and it diverges more than a port usually does.

**Part 1 — the thinking toggle — has landed**, as a disclosure per block rather
than the TUI's global hide. Nothing about it survives here: the design is in
`DECISIONS.md` (`D_details_per_block`, `D_disclosure_state_on_the_block_div`,
`D_ui_cookie_over_config`), the invariant in AGENTS.md's **Scope decisions**,
and the user-facing half in `README.md`'s *Reasoning blocks*. What is left in
this file is **Part 2 only**, which is undecided.

So: tool lines get a short form, with the raw form one flip away. v1 is
web-only from what the events carry today; v2 consumes the summaries pikuri
will compose (`../pikuri/ideas/tool-summary-lines.md`, still unbuilt).

Never shortened: user echoes (`:user`), assistant prose (`:assistant`), `⊕`
skill injections and `!` fallback notices (`:notice`), cancel markers
(`:error`). The TUI's list also protects the `Code::TranscriptConfirmer`
decision block and the `edit` / `write` diff blocks
(`D_diffs_always_visible`) — neither exists here, because this shell is
chat-only (`D_chat_only_entry_point`). A sibling OS/code shell would bring both
back, so the rule is worth stating even while it is vacuous.

Part 1 also left a precedent worth reusing: `D_details_per_block` means a
kind's markup rides inside the html payload, so changing how one renders is
the listener plus `style.css` — not the three places AGENTS.md's block-kind
bullet names for *adding* a kind.

---

## Landed already — the live bugs this port turned up

Both were **pre-existing defects, not parts of this feature**, and both are
fixed and specced. Their durable nuggets are propagated; kept here only as the
trail from this file to them.

1. **`[ui]` broke boot.** pikuri-tui grew a `[ui]` table this shell's
   `validate_top!` rejected, so a TUI user could not start pikuri-web at all.
   → `DECISIONS.md` `D_schema_complete_config` ("Amended: the schema drifted…"),
   the AGENTS.md bullet quoting it, {Config}'s `== The [ui] table` rdoc and
   `.validate_ui!`'s, and the `cross-shell schema` describe in `config_spec.rb`.
2. **Tool lines were never sanitized.** → {SseListener}`#neutralize`'s rdoc and
   the class header's variant list, the **Conventions** bullet in AGENTS.md,
   and five specs in `sse_listener_spec.rb`.

The second one is why the *sanitizer* section below is already settled while
the rest of Part 2 is not.

---

## Part 2 — short-form tool lines

Today's blocks are the *verbose* form already, rendered by `{SseListener}`:

```
→ web_search(query="rails 8 credentials")
= Results for … (4213 bytes total)
```

The target short form, matching what pikuri-tui shipped:

```
WebSearch(rails 8 credentials)
  OK, 4.2 kB
Bash(rm -rf build)
  Error: exit 1: rm: cannot remove 'build': Permission denied
```

The renderers are a near-straight port of pikuri-tui's
`Shared::ConversationTextView::Listener` — `short_call_line` /
`short_result_line` / `verbose_call_line` / `verbose_result_line`,
`display_name` (CamelCase, any run of non-alphanumerics a word break, so MCP
names work), `display_argument` (first *value* of `arguments`, capped at 60),
`format_size` (SI — `5000` → `5.0 kB`, because calling 1024 bytes a kB is the
common-but-wrong thing), and the `Error:` prefix heuristic that v2 retires.
Read that file rather than re-deriving any of it.

### `D_both_forms_in_the_block` — the toggle is CSS, like Part 1

Short-vs-verbose is *content*, not placement, so this does not fall out as
cleanly as thinking — and it is the decision to make first, because it sets
the markup.

- `O_render_both` — the block carries both forms, one wins on a `:root`
  attribute:

  ```html
  <div class="block tool_call" id="b7">
    <span class="tool-short">WebSearch(rails 8 credentials)</span>
    <span class="tool-verbose">→ web_search(query="rails 8 credentials")</span>
  </div>
  ```

  Flip is instant and per-browser, nothing re-renders, no server state. Cost:
  the block's HTML roughly doubles for tool blocks, and `.block.tool_call`'s
  `white-space: pre-wrap` now wraps two spans — the newline between them in
  the source *will* render as a blank line unless the markup is emitted
  without one or the spans are `display: block`.

  **Now that `D_details_per_block` is decided, the obvious variant is
  `O_verbose_in_a_details`** — short line as the `<summary>`, verbose dump as
  the body, one mechanism for both parts of this note and no `:root` attribute
  for tool lines at all. Tempting, and worth deciding at the same time: it
  reuses `D_disclosure_state_on_the_block_div` wholesale, but it makes "show me
  the raw form" a per-call act rather than a mode, which is the *opposite* of
  what a debugging session wants (`D_verbose_toggle`'s whole point was
  reachability of the raw form while reading a whole turn). Probably: both —
  the `:root` mode for "I am debugging now", the disclosure for one curious
  call. But do not build both before trying one.
- `O_server_mode` — the server holds one mode and re-renders tool blocks on a
  flip. That is `O_port_kinded_regions` again with the same objection: a
  display preference in server state, shared across tabs.
- `O_mode_at_render_time` — pick a form when the block is created, no toggle at
  all. Rejected for the reason `D_verbose_toggle` gives: the raw form must stay
  *reachable*, not just present in git history. It is also the one option that
  cannot be changed later without touching the transcript.

Lean: **`O_render_both`**. It is what makes the web version smaller than the
TUI version rather than larger.

### The sanitizer gap — fix it here, and it is not optional

pikuri-tui's Part 2 v1 routes every short line through
`Pikuri::Sanitizer.sanitize(…).text` because dropping `inspect` dropped the
escaping that made the old line safe. **`{SseListener}` calls
`MarkdownRenderer.escape` and never the sanitizer, and that is already a gap —
not one this change creates.**

HTML-escaping neutralizes the terminal's `ESC[` problem, so the *specific* hole
the TUI closed does not exist here. What escaping does **not** touch is
everything else `Pikuri::Sanitizer` is for, and its own rdoc says so outright:
"a bidi override that reorders text so it reads differently than it runs, a
zero-width char, or a Cyrillic `а` posing as Latin `a` … A web chrome adds
`html_escape` on top; the HTML layer is the caller's." A tool-call line is
model-composed text with a filename in it; `U+202E` in that filename reorders
what the user reads in a browser exactly as it does in a terminal.

**The TUI's `inspect` carve-out does not port, and that is measured, not
argued.** Its Part 2 note says "the verbose *arguments* are safe on `inspect`
alone" — true of the terminal threat only. Checked against Ruby:

| input | `inspect` | `Sanitizer` |
| --- | --- | --- |
| `"a\ebz"` | `"a\\ebz"` — escaped | `"a\\x1bbz"` — escaped |
| `"file‮gnp.exe"` | **unchanged** | `"file\\u{202e}gnp.exe"` |
| `"ab​cd"` | **unchanged** | `"ab\\u{200b}cd"` |
| `"Pаypal"` (Cyrillic а) | **unchanged** | unchanged, `:mixed_script` warning |

`inspect` escapes exactly the class HTML-escaping already covers and none of
the class it doesn't. So **both** forms sanitize here — the verbose argument
dump included — which is the opposite of the TUI's split. Sanitize the
*inspected* string rather than the raw value, so `inspect`'s own backslashes
are not re-escaped into `\\u{202e}`.

Order: `sanitize` → flatten → cap, **in that order** (so a cut cannot land
inside an escaped token), with `MarkdownRenderer.escape` on top. `Warning`s are
ignored, as in the TUI — nothing here gates a tool. `{SseListener}` is on the
Pikuri side of the seam (`D_pikuri_free_core`), so naming `Pikuri::Sanitizer`
there is free; a sanitize helper on `{MarkdownRenderer}` would *not* be, since
that class is Pikuri-free.

Two behaviours to expect, both checked: newlines survive sanitizing (so the
verbose call line keeps today's shape and needs no flattening it doesn't
already have), and a tab becomes a literal `\t`. The second is a visible
change on the result line, where a tab used to collapse to a space under
`gsub(/\s+/, ' ')` — the sanitizer runs first now, so `\t` reaches the flatten
as two harmless characters and stays. Faithful over pretty, which is the
sanitizer's stated bargain.

Worth splitting out and shipping before either part, like the `[ui]` fix.

### v2 — consume pikuri's summaries

Unchanged from the TUI note: when `ToolCall` carries `display_name:` /
`argument:` and `ToolResult` carries `summary:`, print those and delete the
CamelCase helper, the first-value pick and the `Error:` check. The v1 look was
chosen so v2 changes no pixels except the result line's wording.

---

## The surface — how a person flips the tool-line form

**Part 1 already settled the shape**, so this is mostly decided by precedent:
`/thinking` ships as a `.picker` dialog with two rows, `aria-current` marked by
`app.js` on open — the same widget `/theme` uses, the same three-place contract
({SlashCommand}`::CATALOG` + the `commands` map + a `<template>`), no new CSS.
`/tools` should be its sibling: two rows, Short / Verbose.

What Part 1 also decided, and is worth not re-litigating:

- **Not a drawer-footer button.** Considered for `/thinking` and passed over:
  with disclosure available per block, flipping a default is a rare act, and
  rare acts belong behind a command rather than beside `#theme-toggle`. Three
  toggles in that footer is a settings bar, and the drawer is about
  *conversations*. A `/tools` button has even less claim.
- **Not one `/view` dialog holding both settings** — the direct analogue of the
  TUI's `u` submenu (`D_which_key_submenu`). Fewer catalog rows, but a dialog
  with two independent live-state toggles that does *not* close on click is a
  widget this app still does not have, which is precisely why the TUI rejected
  `O_checkbox_dialog`. `CATALOG`'s own rdoc argues for a picker per setting
  rather than a row per value, and two pickers is that.

The one thing genuinely open is whether `/tools` is needed *at all* under
`O_verbose_in_a_details`, where the raw form is a click on the call itself. See
the markup fork above — this follows it rather than leading it.

---

## What does not port

Worth being explicit, because the TUI file is long and part of it answers a
problem this shell does not have. Part 1's rows are gone with Part 1; these
are Part 2's:

| pikuri-tui | pikuri-web |
| --- | --- |
| `D_kinded_regions` — a register + `#rerender(kind:)` to redraw on a flip | Nothing: both forms ship in the block and CSS picks (`O_render_both`). |
| `Pikuri::Sanitizer` on short lines, verbose args exempt on `inspect` | Every tool path, **no exemption** — `inspect` misses the Unicode classes. **Done.** |
| `MAX_TOOL_RESULT_CHARS` / `truncate_tool_result` on the pane | Already on {SseListener}, already sanitizing. |
| `TOOL_RESULT_INDENT` as the pane's business | A CSS rule on `.block.tool_result`; see the open question. |
| `Code::EditFormatter` / `WriteFormatter` keep their diff block | Vacuous — no formatters in a chat-only shell. |

Of the TUI's specs, the renderer ones port whole: `display_name`,
first-value pick, `OK, N kB` vs `Error:`, the cap, the sanitizer. Plus one
asserting both forms land in the block, if `O_render_both` wins.

**There is no JS runtime in this suite** and `D_no_js_build_step` keeps it that
way, so anything client-side is checked either by `client_contract_spec.rb`
(which reads the scripts as text) or in a real browser by hand. Part 1's
disclosure guard was verified the second way; expect the same for a
`:root`-attribute flip.

## Sequencing

1. ~~The `[ui]` config fix~~ — **done**.
2. ~~The sanitizer on tool lines~~ — **done**.
3. ~~Part 1~~ — **done**, as `D_details_per_block`.
4. Part 2 v1 — decide `O_render_both` vs `O_verbose_in_a_details` first.
5. Part 2 v2 when pikuri ships `tool-summary-lines`.

## Open questions

- **`O_render_both` or `O_verbose_in_a_details`, or both?** The one that sets
  the markup, so it goes first.
- **Does the short form want the `:tool_call` / `:tool_result` split at all?**
  The short form is a call line with its result indented under it — visually
  one unit. Two blocks is what makes the result upsertable independently, and
  the indent is the pane's business in the TUI (`add_kinded_block(indent:)`);
  here it is a CSS rule on `.block.tool_result`. Probably keep the two kinds
  and do it in CSS, but confirm the blank-line-between-blocks spacing does not
  make the pair read as two things.
- **The default look changes.** The TUI's `tool_lines` default is `:short`;
  this shell's current look is verbose, and `Config#tool_lines` already
  resolves to `:short` with nothing reading it. Honouring the shared file means
  the default look here changes, which is right — but say so, rather than
  discover it.
- Should `markdown` become the third `[ui]` key here? The TUI parked it
  (`D_markdown_flag_deferred`); this shell has no such flag at all — kramdown
  always runs — so the key would need a feature first.

## When this is done

Per AGENTS.md's graduation map:

- `D_both_forms_in_the_block` (or whatever the markup fork resolves to) →
  a `DECISIONS.md` entry plus a flat invariant + `See D_<slug>` in **Scope
  decisions**. `D_verbose_toggle`'s reachability argument is the part a future
  reader will not reconstruct.
- A new `:root` attribute + cookie → follow `D_theme_cookie`'s amended
  *Consequences*, which now records the two shapes a presentational cookie
  comes in and which one a config-backed preference needs.
- New slash commands → {SlashCommand}`::CATALOG`, the `commands` map, the
  `<template>`s, and the three-place contract note in **Conventions**.
- `[ui] tool_lines` becoming *read* → tighten `Config.validate_ui!`? **No** —
  re-read its rdoc first: shape-only is deliberate, and the reader falling
  back is the contract. Document the fallback where the reader lives.
- Anything a user must know → `README.md`, beside *Reasoning blocks*.

Delete this file — and the pikuri-tui one, whose only remaining reason to
exist is that pikuri-web had not taken this copy — once Part 2 v2 has landed.
