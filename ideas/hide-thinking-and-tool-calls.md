# Transcript density: hide thinking, shorten tool lines

**Ported from `../pikuri-tui/ideas/hide-thinking-and-tool-calls.md`**, which is
the design record for the *feature* and can be deleted once this file exists
(that is the condition its own "When this is done" states). Read it once for
the reasoning; this file is only what the web shell does, and it diverges more
than a port usually does — see *What does not port* below.

Two changes, independent of each other:

1. **Thinking becomes collapsible, one disclosure per block**, with the config
   setting whether they start open or closed (`D_details_per_block`). The TUI's
   one-flag-hides-everything shape is deliberately *not* what this became.
2. **Tool lines get a short form, with the raw form one flip away.** v1 is
   web-only from what the events carry today; v2 consumes the summaries pikuri
   will compose (`../pikuri/ideas/tool-summary-lines.md`, still unbuilt).

Never collapsed, never shortened: user echoes (`:user`), assistant prose
(`:assistant`), `⊕` skill injections and `!` fallback notices (`:notice`),
cancel markers (`:error`). `<details>` is for `:thinking` and nothing else —
the invariant matters more now than under a global hide, because a disclosure
per block is an inviting pattern to reach for and a notice behind a triangle is
a notice nobody reads. The TUI's list also protects the
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

### `D_details_per_block` — a disclosure per block; the config sets its default

**Decided.** Each thinking block renders as its own `<details>`, and `[ui]`
`show_thinking` sets whether they start **open or closed** — not whether they
exist. A turn that reasoned twice, with the reader having opened the second
because the answer looked wrong:

```
│ ▍ how many llms are in the config?          │
│ ▸ thinking                                   │  collapsed (the default)
│ → read(path="~/.config/pikuri/config.toml")  │
│ = [[llm]] name = "Local Qwen 3.6" …          │
│ ▾ thinking                                   │  this one clicked open
│   Two entries. Both point at localhost:8080,  │
│   so the /model picker will be offered.       │
│ Two — both on your local llama.cpp.          │
```

The collapsed row is the whole point: it is *both* the "the model reasoned
here" signal and the way in. Short feedback that thinking happened, subtle
enough not to disturb the flow of the conversation.

**So the TUI's `D_no_hidden_marker` flips here, and for its own stated
reason.** It rejected a `· thought` line because grey filler earns nothing and
a terminal has no cheap per-block affordance. A browser has one, which turns
the same row from filler into the affordance — it pays for its line twice.

It also keeps `show_thinking` meaning one thing in both shells — "do I want
reasoning by default" — expressed as each chrome can afford: the TUI omits, the
browser collapses.

Markup, emitted by {SseListener} into the block's html payload:

```html
<div class="block thinking" id="b3">        <!-- the div is transcript.js's -->
  <details><summary>thinking</summary><p>Two entries. Both point at…</p></details>
</div>
```

**Cheaper than the first sketch of this claimed.** `index.erb` and
`transcript.js` both wrap an identical `block.html` in an identical
`div.block.<kind>`, so putting the `<details>` *inside* the payload gets both
paths from one change in {SseListener}. Two places (listener + `style.css`),
not the three the block-kind contract usually costs.

Native `<details>` rather than a hand-rolled `<button aria-expanded>` + body:
keyboard handling and disclosure semantics come free, and `D_target_browsers`
makes it unconditionally available.

**The summary stays a static word.** A live one — a spinner, or the first few
words of the reasoning — is tempting and wrong: a thing moving in the periphery
is the exact flow disruption the collapsed default exists to avoid.

- Rejected `O_global_only` — one hide/show flip for the whole transcript, no
  marker. The straight port, and one CSS rule, but it throws away the
  affordance the browser has and the terminal does not. "That answer looks
  wrong, show me *that* step's reasoning" is the case that matters, and a
  global switch cannot express it.
- Rejected `O_port_kinded_regions` — a server-side visibility gate. It would
  make the *server* hold a display preference, which is per-browser view state
  by decision; two tabs with different preferences would fight over one
  transcript. The TUI needed its `{region, kind, indent, render}` register and
  `#rerender(kind:)` (`D_kinded_regions`) because a hidden region's text had to
  be *recomputed*; here every block is already complete HTML in the DOM, so
  none of that machinery has an equivalent. Nothing new in {Transcript} and
  nothing that can go stale on a reveal.
- Rejected `O_listener_drops_deltas` (the TUI's `D_drop_deltas_while_hidden`):
  the server cannot drop a `ThinkingDelta` for one tab and keep it for another
  without a per-connection filter, and `D_server_authoritative_transcript` says
  the transcript is one picture. The TUI dropped deltas to avoid *rendering*
  work on a hidden pane; here the cost is SSE bytes on localhost, which is
  nothing. **The server always renders and always broadcasts; the browser
  decides what it shows.**
  - Consequence, and a *win* over the TUI: it accepted "a cancel mid-thinking
    while hidden has no bookend, so only what streamed is revealable." Here
    nothing is ever lost — collapsed or not, the block is whole.

### `D_disclosure_state_on_the_block_div` — the mechanism, and why it is required

Collapsed-by-default puts the most likely first action straight onto the one
broken path, so this is **day-one work, not a later refinement**: reasoning
streams *into a collapsed block*, the user gets curious and clicks, and the
next delta rewrites that block's `innerHTML` and slams it shut. At pikuri's
15 fps coalescing that is roughly every 67 ms, so expanding during a turn would
be impossible.

(Note the asymmetry: open-by-default has the mirror problem, where streaming is
fine and only *collapsing* fights the rewrite. The decided default is the one
that has to solve this immediately.)

The fix is nearly free, because `transcript.js`'s upsert **reuses the element
and replaces only its contents**:

```js
let el = document.getElementById(id);
if (!el) { el = document.createElement('div'); … transcript.append(el); }
el.innerHTML = html;          // ← the <details> inside dies here
```

`el` — the `div.block.thinking`, with its id and its attributes — survives
every delta. So per-block disclosure state lives **on the block div**, outside
the html payload, and persists for free:

```js
el.innerHTML = html;
const d = el.querySelector('details');
if (d) d.open = el.dataset.disclosure ? el.dataset.disclosure === 'open' : defaultOpen;
```

A click writes `el.dataset.disclosure`; its *absence* means "follow the
default", which is what makes `D_toggle_moves_everything` below a one-line
operation. No state map, no ids held anywhere, and state dies with the element
on `#remove` / `#reset` — a reopened conversation starts fresh, which is right.

This keeps the seam clean: the server still renders all the markup, and the
browser owns only a boolean. That is per-browser view state, explicitly
script's job under `D_no_js_build_step` ("script is for transport, platform
mechanics only it can reach, and per-browser state") — not rendering.

- Rejected `O_stable_body_slot` — have `transcript.js` replace only an inner
  `.thinking-body` so the `<details>` element itself is never rebuilt. It
  works, but it requires the script to know that `:thinking` blocks have a body
  slot, i.e. markup knowledge in JS, which is the half of
  `D_no_js_build_step` that is not negotiable.
- Rejected `O_server_renders_open` — let {SseListener} emit `<details open>`
  per the preference. The listener is per-*conversation* and shared by every
  tab reading it; the preference is per-*browser*. It cannot know.
  `index.erb`'s snapshot is the one exception and *should* render `open`
  resolved, so a page load has no flash; the SSE path's blocks are brand new
  when they arrive, so applying it in script costs no visible flicker there.

### `D_toggle_moves_everything` — the runtime toggle is collapse-all / expand-all

Flipping the preference at runtime (`/thinking`) **clears every per-block
override and moves the whole transcript**, as well as setting the default for
blocks yet to arrive. Dropping the `data-disclosure` attributes and re-reading
the default is the entire implementation.

- Rejected `O_default_only` — leave blocks already on screen as they are and
  affect only future ones. Cheaper, but it leaves the transcript in a mixed
  state nobody chose, and it makes the command stop feeling like a density
  control.

### `D_ui_cookie_over_config` — where the runtime preference lives

What the cookie holds, under `D_details_per_block`, is the **default open
state** — not visibility. Everything below is unchanged by that; the
precedence question is the same whichever the value means.

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

- `Config` — `[ui]`. **Done**, see *Landed already*.
- `{SseListener}` — wrap a `:thinking` block's html in
  `<details><summary>`. The one `lib/` change, and it serves both render paths.
- `app.rb` `GET /c/:id` — resolve the cookie against the config default on the
  line the theme is resolved on; same `include?`-or-default shape. Render it
  into `<html>` as `data-thinking`, and render `open` on the snapshot's own
  `<details>` so a page load has no flash. `App` needs the config's `[ui]`
  values, arriving as a class-level setting the way `:models` does.
- `index.erb` — the `:root` attribute, and the snapshot's resolved `open`.
- `style.css` — the summary row (muted, subtle) and the collapsed/open marker.
  No visibility rule: `<details>` owns that now.
- `transcript.js` — the three lines of `D_disclosure_state_on_the_block_div`,
  the click that writes `data-disclosure`, and **the re-stick** (below). This
  is the feature's own file by `D_feature_owns_its_file`, since all of it is
  `#transcript`'s business.
- `app.js` — the surface wiring only: the cookie write and the `/thinking`
  command calling into `transcript.js`.

### The scroll re-stick — the one non-obvious mechanic

`transcript.js`'s `nearBottom()` decides whether a streaming update keeps the
pane pinned to the bottom. Every disclosure change moves the document height —
a single click, and `D_toggle_moves_everything` by a lot — so a pinned pane
silently unpins and a scrolled-up reader jumps. The TUI got this free: tuile
0.15's `set_region_text` clamps `scroll_top_row` and re-runs auto-scroll.

So a toggle is *two* things: the state write, and "if we were at the bottom, be
at the bottom again." Both live in `transcript.js`, which is also where the
click lands — so unlike the earlier global-flip sketch, nothing outside has to
reach into `#transcript` to arrange it.

Open: whether an *individual* expand should re-stick at all. Clicking a block
to read it is a deliberate act; yanking the view to the bottom afterwards may
be exactly wrong. Probably re-stick on the global toggle and *not* on a single
click — but that is a feel question, so try both.

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
- `O_details_only` — no global surface at all; the per-block `<details>` *is*
  the whole UI. Now that `D_details_per_block` is decided this is a live
  option rather than a hypothetical, and it is genuinely tempting: the common
  case is one curious click, not a standing preference. But it leaves no way to
  say "always expanded", which is a real taste some people have and which the
  shared `[ui] show_thinking` already promises to honor. So: a surface is still
  needed, just a less prominent one than the global-hide design wanted.

Lean: **`O_two_slash_pickers`**, and — given `O_details_only`'s point stands
partway — *not* a drawer-footer button. With disclosure available per block,
flipping the default is a rare act, and rare acts belong behind a command
rather than beside `#theme-toggle`. Decide the dialogs before the CSS attribute
names, since the `<template>` bodies name the values.

---

## What does not port

Worth being explicit, because the TUI file is long and most of it is answering
a problem this shell does not have:

| pikuri-tui | pikuri-web |
| --- | --- |
| `D_kinded_regions` — `{region, kind, indent, render}` register + `#rerender(kind:)` | Nothing. `<details>` and one `data-` attribute (`D_details_per_block`). |
| `D_drop_deltas_while_hidden` — listener drops `ThinkingDelta` | Nothing. Server always renders; the browser discloses (`O_listener_drops_deltas`, rejected). |
| The `O_replay` trap (`clear` erases a parked decision) | Vacuous — no confirmer in a chat-only shell. |
| `D_pane_owns_flag` — sub-agent listeners share the pane | No flag on the server at all. |
| `#open_thinking_block` registers its own region | Nothing — a streamed block is already whole HTML. |
| `indent_block` returns an empty block unchanged | Nothing — a collapsed `<details>` is genuinely one row. |
| `D_no_hidden_marker` — no `· thought` line | **Flipped.** The marker *is* the affordance (`D_details_per_block`). |
| One mode for the whole transcript | Per block, with the config setting the default. |
| `Pikuri::Sanitizer` on short lines, verbose args exempt on `inspect` | Every tool path, **no exemption** — `inspect` misses the Unicode classes. |
| tuile's `set_region_text` scroll clamping | Hand-rolled: `transcript.js` re-sticks after a toggle. |
| Six specs worth porting | Mostly moot; see below. |

Of the TUI's six specs, the one that survives outright is "prose and tool lines
are untouched by the thinking flip"; for Part 2, the renderer specs port whole
(`display_name`, first-value pick, `OK, N kB` vs `Error:`, the cap, the
sanitizer). Everything about collapse/reveal/re-hide is testing the register
this shell does not have.

What replaces them, and the shape is different — most of Part 1 is now
*client* behaviour, so `spec/js` is where it lands rather than rspec:

- Ruby: {SseListener} wraps a `:thinking` block in `<details><summary>` and
  wraps nothing else; `app.rb` renders the resolved `data-thinking` into
  `<html>` and `open` into the snapshot (the theme's spec is the template).
- JS: a delta rewriting an *expanded* block leaves it expanded — the
  `D_disclosure_state_on_the_block_div` guard, and the one a naive
  implementation fails; a click writes `data-disclosure` and survives the next
  upsert; a block with no override follows the default; the global toggle drops
  every override.

---

## Sequencing

1. ~~The `[ui]` config fix~~ — **done**, see *Landed already*.
2. ~~The sanitizer on tool lines~~ — **done**, see *Landed already*.
3. Part 1 — `D_details_per_block` + `D_disclosure_state_on_the_block_div` +
   `D_toggle_moves_everything`. Decided; ready to build.
4. Part 2 v1 (`O_render_both`).
5. Part 2 v2 when pikuri ships `tool-summary-lines`.

## Open questions

- **Should a single expand re-stick the scroll, or only the global toggle?**
  See *The scroll re-stick*. A feel question — try both.
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
  flat invariant + `See D_<slug>` in **Scope decisions**. The four worth
  logging:
  - `D_details_per_block` — carries `O_global_only` and `O_port_kinded_regions`
    as why-nots, **and the `D_no_hidden_marker` flip**, which is the entry's
    most interesting line: the same argument the TUI used to reject a marker is
    what makes one right here. Also the invariant `<details>` is for
    `:thinking` only.
  - `D_disclosure_state_on_the_block_div` — the stable-div mechanism, why it is
    required rather than an optimization (the 15 fps rewrite), and
    `O_stable_body_slot` / `O_server_renders_open` as why-nots. This one is a
    **trap note**: `el.innerHTML = html` looks like it can carry the state and
    cannot, and a reader who moves the attribute inside the payload breaks
    mid-turn expansion only — which no spec catches unless the JS spec named
    above exists. Write that spec *and* the note.
  - `D_ui_cookie_over_config` — the `D_schema_complete_config` tension is the
    whole entry.
  - `D_both_forms_in_the_block` (Part 2).
  `D_toggle_moves_everything` is small enough to be a *Consequences* line under
  `D_details_per_block` rather than an entry. `D_theme_cookie` gains one too:
  it is no longer the only presentational cookie, and what the second one
  taught.
- ~~The `[ui]` fix~~ and ~~the sanitizer fix~~ → done; see *Landed already*
  for where each nugget went.
- Block-kind markup changes → the **Conventions** block-kinds bullet, **which
  needs amending rather than following**: it says adding a kind means touching
  SseListener + index.erb + style.css, and `D_details_per_block` shows a kind's
  *markup* travels in the html payload, so a change to how one renders is two
  places, not three. `transcript.js`'s markup-contract comment gains the
  disclosure state, since that is the one part of a block the script owns.
- New slash commands → `{SlashCommand}::CATALOG`, the `commands` map, the
  `<template>`s, and the three-place contract note in **Conventions**.
- `[ui]` keys → `README.md`, since a user must know they exist and that they
  are shared with the TUI.

Delete this file — and the pikuri-tui one, whose only remaining reason to exist
is that pikuri-web had not taken this copy — once Part 2 v2 has landed.
