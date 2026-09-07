# Transcript density: hide thinking, shorten tool lines

**Ported from `../pikuri-tui/ideas/hide-thinking-and-tool-calls.md`**, which is
the design record for the *feature* and can be deleted once this file exists
(that is the condition its own "When this is done" states). Read it once for
the reasoning; this file is only what the web shell does, and it diverges more
than a port usually does — see *What does not port* below.

Two changes, independent of each other:

1. **Thinking becomes hideable** (show / hide), with a config default.
2. **Tool lines get a short form, with the raw form one flip away.** v1 is
   web-only from what the events carry today; v2 consumes the summaries pikuri
   will compose (`../pikuri/ideas/tool-summary-lines.md`, still unbuilt).

Never hidden, never shortened: user echoes (`:user`), assistant prose
(`:assistant`), `⊕` skill injections and `!` fallback notices (`:notice`),
cancel markers (`:error`). The TUI's list also protects the
`Code::TranscriptConfirmer` decision block and the `edit` / `write` diff
blocks (`D_diffs_always_visible`) — neither exists here, because this shell is
chat-only (`D_chat_only_entry_point`). A sibling OS/code shell would bring both
back, so the rule is worth stating even while it is vacuous.

---

## Landed already — the two live bugs this port turned up

Both were **pre-existing defects, not parts of this feature**, and both are
fixed and specced. Their durable nuggets are propagated, so the sections below
are kept only as the design record for the rest of the work; delete them with
the file.

1. **`[ui]` broke boot.** → `DECISIONS.md` `D_schema_complete_config`
   ("Amended: the schema drifted…"), the AGENTS.md **Scope decisions** bullet
   quoting it, {Config}'s `== The [ui] table` rdoc and `.validate_ui!`'s, and
   the `cross-shell schema` describe in `config_spec.rb`.
2. **Tool lines were never sanitized.** → {SseListener}`#neutralize`'s rdoc
   and the class header's variant list, the new **Conventions** bullet in
   AGENTS.md, and five specs in `sse_listener_spec.rb`.

Nothing below depends on either, and nothing below has been built.

### What the `[ui]` fix decided, for the record

`{Config}.validate_top!` allowed `%w[llm search code]` and raised `Error` on
any other top-level key. pikuri-tui's `Shared::Config` now writes and reads a
fourth table:

```toml
[ui]
show_thinking = false
tool_lines    = "verbose"
```

One config file for every pikuri shell (`D_schema_complete_config`), so a
person who set a density preference in the TUI **cannot boot pikuri-web at
all**: `unknown top-level key(s): ui`. `D_schema_complete_config` exists to
prevent exactly this ("Trimming it would break the file"), and the schema has
already drifted. Fix it whether or not Part 1 is ever built.

The naive fix — mirror `validate_ui!` from the TUI verbatim — **re-breaks on
the next key**, and the TUI's own `[ui]` rdoc announces which one: "The
conversation pane's `markdown:` flag is the same shape and has no key here
yet — the natural third entry when someone wants it." A strict unknown-key
check on a table this shell does not own the growth of is the same bug with a
later date. So:

- `validate_top!` accepts `ui`; `Config` exposes `#show_thinking` /
  `#tool_lines`, validated and wired to nothing, exactly as `sandbox` /
  `confirm` / `mcp` already are.
- **Unknown keys inside `[ui]` are logged and ignored, not fatal.** This shell
  carries the table; pikuri-tui owns what grows in it, and it is the shell that
  will catch the typo.
- **`tool_lines` is shape-checked only** (a String), not validated against a
  copy of the vocabulary. The TUI checks it against the pane's own
  `TOOL_DETAIL_MODES` so the names cannot drift, but a copy of that list here
  rejects a legal file the day the TUI adds a third form — the bug again. The
  precedent is in this very class: `search.engines` is shape-only because "an
  unknown name … is pikuri's refusal." The *consumer* falls back on an
  unrecognized value, which is how `App` already treats the `theme` cookie
  (`THEMES.include?(cookie) ? cookie : DEFAULT_THEME`).
- `show_thinking` stays strictly boolean — the one key whose whole domain is
  two values that cannot grow.
- Specs go in the existing `cross-shell schema` describe, which is the test
  that should have caught this and didn't.

**Left unsolved deliberately:** the same hazard one level up. A brand-new
top-level table in pikuri-tui still breaks boot here, and `validate_top!` stays
strict because loosening it would silently swallow a typo'd `[serach]` along
with the Brave key inside it. Inner growth is *announced*; a new top-level
section is a visible feature event more likely to prompt a cross-repo sweep.
That asymmetry is the thing to write down.

That fix alone makes the *keys* legal. Honoring them is Part 1 / Part 2.

---

## Part 1 — hiding thinking

### `D_web_css_hides` — visibility is a CSS class, not a re-render

The headline divergence, and it deletes most of the TUI's design. There, a
hidden region's text had to be recomputed, so the pane grew a
`{region, kind, indent, render}` register and a `#rerender(kind:)`
(`D_kinded_regions`) — the single largest piece of that work.

Here, every block is already **complete HTML in the DOM**, kramdown having run
on the server. So:

```css
:root[data-thinking="hidden"] .block.thinking { display: none; }
```

and the whole feature is one rule plus a cookie. No register, no thunk, no
per-block bookkeeping, nothing new in `{Transcript}` or `{SseListener}`,
nothing that can go stale on a reveal. A reveal is free and instant because
the content never left.

This is the same shape as the theme (`D_theme_cookie`): the server renders the
resolved preference into `<html>` so the first paint is already right, and
`app.js` rewrites the attribute and the cookie in place. It also lands on the
right side of `D_no_js_build_step` — placement and presentation are CSS's, and
"markup the server could have produced" never moves.

- Rejected `O_port_kinded_regions`: a server-side visibility gate would make
  the *server* hold a display preference, which is per-browser view state by
  decision. Two tabs with different preferences would fight over one
  transcript.
- Rejected `O_listener_drops_deltas` (the TUI's `D_drop_deltas_while_hidden`):
  the server cannot drop a `ThinkingDelta` for one tab and keep it for
  another without a per-connection filter, and
  `D_server_authoritative_transcript` says the transcript is one picture. The
  TUI dropped deltas to avoid *rendering* work on a hidden pane; here the cost
  is SSE bytes on localhost, which is nothing. **The server always renders and
  always broadcasts; the browser decides what it paints.**
  - Consequence, and it is a *win* over the TUI: the TUI accepted "a cancel
    mid-thinking while hidden has no bookend, so only what streamed is
    revealable." Here nothing is ever lost — hidden or not, the block is whole.
- Rejected `O_display_none_on_the_block_element` (JS walking the blocks and
  setting `style.display`): the same effect, but it has to run again on every
  `upsert`, so a streamed thinking block would flash before the walk caught it.
  A `:root` attribute applies to blocks that do not exist yet.

### `D_no_hidden_marker` — **flips on the web**

The TUI decided against a `· thought` line where reasoning was: grey filler,
nothing about its absence confuses, and a terminal has no cheap per-block
affordance anyway.

The browser has one, and *needs* one if we ever want per-block reveal. So the
question re-opens as a genuine fork, and it is really the shape question:

- `O_global_only` — one hidden/shown flip for the whole transcript, no marker
  at all. Straight port, one CSS rule, done.
- `O_details_per_block` — `.block.thinking` becomes
  `<details><summary>thinking</summary>…</details>`. Native disclosure, zero
  JS, per-call granularity, and the global flip becomes "start them closed."
  Costs: the block-kind markup contract now differs between `{SseListener}`
  and `index.erb`'s snapshot (both must build the same element — that is
  already `transcript.js`'s stated contract), `<details>` open-state is
  per-element so a *global* flip of already-rendered blocks needs either JS
  touching each one or a CSS override of `details > :not(summary)`, and an
  open `<details>` re-collapses on nothing when a delta rewrites the block's
  `innerHTML`.
- `O_both` — global default via the `:root` attribute, per-block override via
  `<details>`. The honest answer for a web chrome and the one the TUI note
  guessed at, but it is the most markup and the most CSS.

Lean: **`O_global_only` first**, because it is the port and it is one rule, and
the markup shape it lands on does not preclude `O_details_per_block` later.
Worth deciding before writing the CSS, though — `O_both` wants the `<details>`
markup from day one, and retrofitting it means touching the kind contract
twice.

### `D_ui_cookie_over_config` — where the runtime preference lives

The TUI's `D_config_default` is *file sets the default, the runtime toggle
overrides for the session and is never written back*. The web's store for a
runtime view preference is a cookie, and the theme's is `max-age=31536000`.

Which makes a precedence question `D_schema_complete_config` appears to
forbid — "anything the file has a home for comes from the file and nowhere
else … so there is never a precedence rule between an override, the file and a
conversation's saved model."

The resolving argument, and it needs to go into a `D_` entry rather than be
assumed: **that rule is about the server's configuration — a connection, a
key, a switch the agent runs on. A density cookie is per-browser view state,
which AGENTS.md already partitions to the browser** ("each browser owns its
own view state"). The file says what a browser that has never expressed a
preference sees; nothing about the agent changes.

- `O_session_cookie` (no `max-age`, dies with the browser session) maps
  *exactly* onto the TUI's never-written-back session override and sidesteps
  the precedence argument entirely. But it makes the density cookie behave
  differently from the theme cookie sitting beside it, which someone will
  later "fix" without reading this.
- `O_ignore_the_file` (parse `[ui]` for schema completeness, honor only the
  cookie): rejected. A `show_thinking = false` honored in the TUI and silently
  dropped in the browser is worse than either consistent answer.
- `O_no_cookie_at_all` (the file is the only source, no runtime flip): rejected
  for the reason `D_config_default` gives — a flip you cannot make without an
  editor and a restart is not a density control.

### Where the code goes

Small, and mostly not in `lib/`:

- `Config` — `[ui]` (the blocker above).
- `app.rb` `GET /c/:id` — resolve the cookie against the config default the
  same line the theme is resolved on, render it into `<html>`. The two
  fallbacks are the same shape, so this is one more `include?`-or-default.
  `App` needs the config's `[ui]` values, which arrive as class-level
  settings like `:models` does.
- `index.erb` — the `:root` attribute.
- `style.css` — the rule.
- `app.js` / a new file — the flip, the cookie, and **the re-stick** (below).

### The scroll re-stick — the one non-obvious mechanic

`transcript.js`'s `nearBottom()` decides whether a streaming update keeps the
pane pinned to the bottom. A global flip changes the document height by
however much reasoning is on screen, so a pinned pane silently unpins and a
scrolled-up reader jumps. The TUI got this free — tuile 0.15's
`set_region_text` clamps `scroll_top_row` and re-runs auto-scroll.

So the flip is *two* things: an attribute write, and "if we were at the bottom,
be at the bottom again." That second half is `#transcript`'s business, which is
`transcript.js`'s file by `D_feature_owns_its_file` — so `initTranscript`
returns a `restick()` (or the flip itself moves in there and `app.js` only
wires the surface to it). Do not let a density feature reach into `#transcript`
directly.

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

  Flip is instant and per-browser, nothing re-renders, no server state, the
  same one-rule CSS as Part 1, and it composes with `O_details_per_block` (the
  verbose form is exactly what a disclosure triangle wants to hold). Cost: the
  block's HTML roughly doubles for tool blocks, and `.block.tool_call`'s
  `white-space: pre-wrap` now wraps two spans — the newline between them in
  the source *will* render as a blank line unless the markup is emitted
  without one or the spans are `display: block`.
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

## Surfaces — how a person flips these

The TUI answer was a `u` which-key submenu with live-state labels plus
`/thinking` / `/tools` typed halves (`D_which_key_submenu`). Here:

- `O_two_slash_pickers` — `/thinking` and `/tools`, each opening the existing
  `.picker` dialog with two rows (Shown / Hidden, Short / Verbose), current row
  marked `aria-current` by `app.js` on open. **Reuses `/theme`'s shape
  exactly** — same widget, same three-place contract (`{SlashCommand}::CATALOG`
  + the `commands` map + a `<template>`), no new CSS. And `CATALOG`'s own rdoc
  already argues for a picker per setting rather than a row per value.
- `O_one_view_dialog` — one `/view` dialog holding both toggles, the direct
  analogue of the TUI's `u` submenu. Fewer catalog rows, but a dialog with two
  independent live-state toggles that does *not* close on click is a widget
  this app does not otherwise have — which is precisely why the TUI rejected
  `O_checkbox_dialog`.
- `O_drawer_footer_buttons` — flat-buttons beside `#theme-toggle`. Free
  discoverability on the desktop (the footer is always visible), reachable on
  the phone through the drawer, and no dialog at all. But three toggles in a
  footer is a settings bar, and the drawer is about *conversations*.
- `O_details_only` — no global surface; per-block `<details>` is the whole UI.
  Only coherent if `O_details_per_block` wins Part 1, and it gives no way to
  say "always hide."

Lean: **`O_two_slash_pickers`**, plus keeping `#theme-toggle` company in the
drawer footer *only* for thinking, if it turns out to be a thing worth flipping
mid-read. Decide the dialogs before the CSS attribute names, since the
`<template>` bodies name the values.

---

## What does not port

Worth being explicit, because the TUI file is long and most of it is answering
a problem this shell does not have:

| pikuri-tui | pikuri-web |
| --- | --- |
| `D_kinded_regions` — `{region, kind, indent, render}` register + `#rerender(kind:)` | Nothing. One CSS rule (`D_web_css_hides`). |
| `D_drop_deltas_while_hidden` — listener drops `ThinkingDelta` | Nothing. Server always renders; the browser paints (`O_listener_drops_deltas`, rejected). |
| The `O_replay` trap (`clear` erases a parked decision) | Vacuous — no confirmer in a chat-only shell. |
| `D_pane_owns_flag` — sub-agent listeners share the pane | No flag on the server at all. |
| `#open_thinking_block` registers its own region | Nothing — a streamed block is already whole HTML. |
| `indent_block` returns an empty block unchanged | Nothing — `display: none` is genuinely zero height. |
| `Pikuri::Sanitizer` on short lines, verbose args exempt on `inspect` | Every tool path, **no exemption** — `inspect` misses the Unicode classes. |
| tuile's `set_region_text` scroll clamping | Hand-rolled: `transcript.js` re-sticks after a flip. |
| Six specs worth porting | Mostly moot; see below. |

Of the TUI's six specs, the ones that survive are "prose and tool lines are
untouched by the thinking flip" and, for Part 2, the renderer specs
(`display_name`, first-value pick, `OK, N kB` vs `Error:`, the cap, the
sanitizer). Everything about collapse/reveal/re-hide is testing the register
this shell does not have. What replaces them is a `Config` `[ui]` spec, an
`app.rb` spec that the resolved attribute reaches `<html>` (the theme's spec is
the template), and — if `O_render_both` wins — one asserting both forms land in
the block.

---

## Sequencing

1. ~~The `[ui]` config fix~~ — **done**, see *Landed already*.
2. ~~The sanitizer on tool lines~~ — **done**, see *Landed already*.
3. Part 1 (`O_global_only`), once the `O_details_per_block` fork is decided.
4. Part 2 v1 (`O_render_both`).
5. Part 2 v2 when pikuri ships `tool-summary-lines`.

## Open questions

- **`O_details_per_block` or not** — decide before writing the kind markup,
  because `O_both` wants `<details>` from day one and a retrofit touches the
  three-place block-kind contract twice.
- **Does the short form want the `:tool_call` / `:tool_result` split at all?**
  The short form is a call line with its result indented under it — visually
  one unit. Two blocks is what makes the result upsertable independently, and
  the indent is the pane's business in the TUI (`add_kinded_block(indent:)`);
  here it is a CSS rule on `.block.tool_result`. Probably keep the two kinds
  and do it in CSS, but confirm the blank-line-between-blocks spacing does not
  make the pair read as two things.
- **Do the two `[ui]` keys need to mean the same thing in both shells?** The
  TUI's `tool_lines` default is `:short`; this shell's *current* look is
  verbose. Honoring the shared file means the default look here changes, which
  is right — but say so, rather than discover it.
- Should `markdown` become the third `[ui]` key here? The TUI parked it
  (`D_markdown_flag_deferred`); this shell has no such flag at all — kramdown
  always runs — so the key would need a feature first.

## When this is done

Per AGENTS.md's graduation map:

- Every `D_` above with a real fork → one `DECISIONS.md` entry each, plus a
  flat invariant + `See D_<slug>` in **Scope decisions**. The ones that carry a
  fork worth logging: `D_web_css_hides` (with `O_port_kinded_regions` /
  `O_listener_drops_deltas` as the why-nots), `D_ui_cookie_over_config` (the
  `D_schema_complete_config` tension is the whole entry), `D_both_forms_in_the_block`,
  and whatever `D_no_hidden_marker` resolves to. `D_theme_cookie` gains a
  *Consequences* line: it is no longer the only presentational cookie, and what
  the second one taught.
- ~~The `[ui]` fix~~ and ~~the sanitizer fix~~ → done; see *Landed already*
  for where each nugget went.
- Block-kind markup changes → the **Conventions** block-kinds bullet (which
  already names the three places) and `transcript.js`'s markup-contract
  comment.
- New slash commands → `{SlashCommand}::CATALOG`, the `commands` map, the
  `<template>`s, and the three-place contract note in **Conventions**.
- `[ui]` keys → `README.md`, since a user must know they exist and that they
  are shared with the TUI.

Delete this file — and the pikuri-tui one, whose only remaining reason to exist
is that pikuri-web had not taken this copy — once Part 2 v2 has landed.
