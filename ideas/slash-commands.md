# Slash commands

A `/`-prefixed command palette in the composer, pikuri-tui's `Shared::SlashMenuPopup` ported to the
browser. v1 ships `/new`, `/theme`, `/trifecta`; `/model` follows (see below).

The TUI is the shape to copy — a list floating above the input, filtered by what is typed, Up/Down +
Enter, ESC dismisses, the caret never leaves the field. What does **not** port is its plumbing, and
that is most of what is interesting below.

**Settled** (2026-08-29): no transcript echo and no `callback` return value; `<dialog>` +
`showModal()` for the modal, opened through a reusable helper in a second script file; v1 adds no
new routes; an unknown command gets an error dialog; `/theme` is one command with a picker, not
`/dark` + `/light`; `/model` is postponed to a v2 that needs no new mechanism. `D_no_js_build_step`
needs amending on the way in — see *The JavaScript rule*. What is still open is at the bottom.

## The commands, and what each actually touches

| command | what it does | server involvement |
|---|---|---|
| `/new` | `POST /conversations`, follow the id | route exists |
| `/theme` | picker dialog: dark / light, current marked | none — already a button |
| `/trifecta` | dialog showing this agent's trifecta report | new render, no new route (below) |
| `/model` | *v2* — picker dialog over `[[llm]]` connections | the whole of `per-conversation-model.md` |

Two of the three in v1 are a **second front door onto an affordance that already exists** — the
theme toggle and the `+ new conversation` button both live in the drawer footer, which on the phone
means opening the drawer to reach them. `/theme` from the composer is strictly less work than
☰ → scroll → tap. That is the actual argument for this feature on the phone, more than the two new
dialogs are.

So the dispatch for those two is not new code, it is *calling the existing handler*: factor
`applyTheme(theme)` out of the toggle's click listener and `startConversation()` out of `newBtn`'s,
then both the button and the command call them. No second path to keep in sync.

**`/theme` is a picker, not two commands.** `/dark` and `/light` would each be one keystroke shorter,
but a picker is the same shape as `/model`'s dialog and the same shape the toggle button already
has, and it keeps the catalog from growing a row per value of every future setting. Consequence
worth noting: `/t` is now **ambiguous** between `/theme` and `/trifecta`, so it takes `/th` / `/tr`
or an arrow key. That is not a regression — it is precisely the case the palette exists for, and the
iPhone story ("type `/t`, tap the one you want") works better with two rows than with one.

There is no `/clear`. The TUI's means "wipe this conversation's context in place"; here conversations
are separate objects, so `/new` is what `/clear` means in the web shell.

## The shape: catalog on the server, dispatch in the browser

- **The catalog is server-rendered**, once, into `index.erb`: a `<ul id="slash-menu">` with one
  `<li data-command="/trifecta">` per command, name and description in two columns, hidden until
  needed. No client-assembled markup, and no `GET /commands?q=` round trip per keystroke for a fixed
  three-item list.
- **`app.js` only filters, selects and dispatches.** Filtering is
  `li.hidden = !li.dataset.command.startsWith(text)`. Dispatch is a `switch` on the command name.
- **The catalog is conditional**: `/model` will be listed only when `config.llms.size > 1`, the
  TUI's `Shared::Model::Picker#multiple?` gate, so the palette never offers a no-op pick. So the
  list is data the host injects, not a constant baked into the template.

Suggested home: `lib/pikuri_web/slash_command.rb` — `SlashCommand = Data.define(:name, :description)`
plus a `.catalog(model_switch:)`, mirroring the TUI's file of the same name minus the `callback`
(next section for why the callback doesn't port). Pikuri-free, so it sits on the browser side of the
seam with `App` and `Config`.

### The three-place contract

Because dispatch is client-side, a command's name exists in two places — the Ruby catalog and the
`switch` in `app.js` — plus, for a command with a dialog, its server-rendered `<template>`. Adding
one means touching all of them. That is the same shape as the existing block-kind contract
(*Conventions*: "adding one means touching all three"), and it should be written down the same way
rather than pretended away.

Rejected: making the markup carry `data-href` / `data-method` so the JS becomes a generic "do what
the `<li>` says" dispatcher. `/theme` isn't a request at all, so the generic form would still need a
special case, and three commands do not pay for an indirection layer.

## No transcript echo — the TUI's outcome mechanism doesn't port

`Shared::SlashCommand#callback` returns a String that `SlashMenuPopup` writes into the conversation
pane as a block. Here that is **forbidden twice over**:

- Client-side would be client-only conversation state — `D_server_authoritative_transcript` says
  never.
- Server-side would put a block in `Transcript` that is not in `history.json`, so
  `D_replay_from_history`'s replay would not reproduce it: the line shows now and is silently gone
  after a reload. Worse than not showing it.

Which is fine, because **every command has a visible effect of its own** — a dialog opens, the
palette closes, the page navigates, the colours change. The TUI needs the echo because `/logs` and
`/trifecta` have nowhere else to speak; here they have a dialog. Drop `callback` and the outcome
String from the port entirely.

## Enter, and the unknown command

None of the commands takes an argument, so the TUI's `"/name rest"` split is dead weight. Three
cases, decided by what the buffer looks like when Enter lands:

| buffer | palette | Enter |
|---|---|---|
| `/t`, `/new`, … — leading `/`, no space, ≥1 match | open | runs the highlighted command |
| `/typo` — leading `/`, no space, no match | closed | **error dialog**, nothing sent |
| `/usr/share/foo is broken` — contains a space | closed | sends, exactly as today |
| anything else | closed | sends, exactly as today |

**The error dialog is the answer to `Q_unknown_command`** — better than silently sending a typo to
the model, and there is nowhere else to put the message (a transcript echo is forbidden above). It
lists the known commands, which makes it useful rather than merely obstructive; the catalog is
already in the DOM, so the body is a `<template>` plus one text slot.

Two things this rule has to get right:

- **The space is the escape hatch, and it must be documented.** A message that is *only* a path
  (`/etc/hosts`, alone, no other words) now raises the dialog instead of sending. In a chat-only
  shell with no file tools (`D_chat_only_entry_point`) that is a rare thing to type, and adding any
  surrounding word sends it. But it is a real edge and the error dialog should say so in a clause,
  not leave the user poking at it.
- **The typed name is user input.** It must reach the dialog as `textContent`, never concatenated
  into an HTML string — see the helper's signature below, which is designed to make that the only
  option.

## The dialog: `<dialog>`, `showModal()`, and one helper

`D_target_browsers` is Firefox desktop + Safari on iPad/iPhone, greenfield, no polyfills — and both
have had `<dialog>` since early 2022. So the answer to "modal if possible" is **yes, and for free**:

- `showModal()` makes everything outside the dialog inert. No hand-rolled `inert` — the drawer needs
  that (`app.js`'s `chat.inert = open`) precisely because it is a `<div>`, not a `<dialog>`.
- ESC closes it and fires `cancel`. Nothing to write.
- `::backdrop` is a real pseudo-element; the scrim needs no extra div.
- Focus goes into the dialog on open. Restore it to `#prompt` on close explicitly rather than
  trusting the browser to.

**One helper, not one dialog element** (`Q_one_dialog`, resolved): a reusable function that builds a
`<dialog>`, fills its body, appends it, `showModal()`s it, and removes it from the DOM on `close`.
Three callers already — trifecta, theme, unknown-command — and `/model` makes four, which is well
past the point where a shared shape earns its name. No dialog markup sits in the page at rest.

**Its signature should take a `Node`, not an HTML string.** The bodies come from server-rendered
`<template>` elements in `index.erb`; the caller clones one and, where a value must be filled in,
sets `.textContent` on a slot. A string signature would make the unknown-command dialog a
string-concatenation of user input — an escaping hazard designed into the API. Taking a node makes
the safe path the only path, and costs the caller one `cloneNode(true)`.

The chrome (heading, ✕) belongs to the helper; the `<template>` carries only the body. That mirrors
`#drawer`, whose chrome sits *around* the nav for the same reason.

**Full-screen on the phone** is the same trick as everything else here — `@media (max-width: 40rem)`
giving the dialog `width: 100%; height: 100dvh; max-width: none; margin: 0; border-radius: 0`. Same
markup, placement is CSS's (`D_one_shell_two_layouts`). A third occurrence of the breakpoint, still
inside `style.css`, so AGENTS.md's "written twice, and the two move together" stays true.

**The theme picker's current marker cannot be pre-rendered.** The server renders `data-theme` at
page load, but the theme changes in-page afterwards (the toggle, or an earlier `/theme`), so the
marker must be computed on open from `document.documentElement.dataset.theme`. Small, and exactly
the kind of thing that ships wrong.

Note: `app.js`'s document-level Escape handler currently closes the drawer. With a modal dialog open
it still fires; closing an already-closed drawer is a no-op, so this is harmless — but it wants a
glance rather than a shrug.

## The JavaScript rule — amend `D_no_js_build_step`

The entry today says "One hand-written `public/app.js` (~100 lines), zero JS dependencies, no Node,
no build step; all rendering is server-side." Two of those clauses have to go, and one has to be
sharpened.

- **The line count goes.** It is *already wrong* — the file is ~180 lines against a stated ~100 —
  and it rotted silently, with no change ever rejected for busting it. A budget nobody enforces is a
  fossil, not an invariant; `wc -l public/*.js` never goes stale and a number in prose always does.
- **"One file" goes too.** This idea adds a second script (below), and file count is as arbitrary as
  line count once "no bundler" is said outright.
- **What replaces them has to be a test you can apply at a decision point**, or the entry degrades
  to "as minimal as possible", which is true of any amount of code by its own author's lights.

Proposed replacement, which is only what the existing decisions already lean on:

> No dependency, no npm, no bundler, no build step. JS is **transport** (EventSource, fetch),
> **platform mechanics only exposed to script** (`showModal`, `inert`, `scrollTop`, textarea
> measurement, `matchMedia`), and **per-browser state that must never reach the server** (theme,
> draft, scroll position, the highlighted palette row — `D_no_event_queue`). It is never a
> *renderer*: markup or conversation content the server could have produced is the server's, always.

**The qualifier that has to ride along:** this is about rendering and state, *not* latency. Taken
absolutely, "if it can go to the server, it must" argues for fetching the palette's filtered rows
per keystroke — which this same file calls absurd. The filter, the theme flip and the auto-grow stay
local because a round trip would make them feel wrong, not because the server couldn't do them.

### The second file

`app.js` should stay the *app*: the EventSource, the composer, the sidebar, the drawer, the palette's
dispatch. The dialog helper is none of those — it is DOM mechanics with no app knowledge — so it
goes next door.

**Name it `dom.js`, not `util.js`.** A file called `util` is an open invitation to become the junk
drawer (the `AbstractView` anti-pattern, one namespace up); `dom.js` names its own admission rule.
The test for what may live there: **if a function names an app element or a conversation id, it is
`app.js`'s.** `openDialog` qualifies; `autogrow` and `nearBottom` are candidates to move later, but
not in this change.

Loading: see `Q_script_loading` below.

## `/trifecta` — pre-rendered, and zero new routes

`Pikuri::Trifecta::Report#render` is plain text on purpose (its rdoc: "a host wanting color or width
walks this tree itself"). v1 should take the cheap, honest option: the `advisory` as a highlighted
paragraph and `render` in a `<pre>`, HTML-escaped, no kramdown. Same words the boot script prints.
Walking the tree into styled rows is a later refinement, not a v1 gate.

The report is **static for the life of the process** — one conversation factory, one tool set, and
the trifecta is about tools, not models. So it ships inside a `<template>` in `GET /c/:id`. It is a
handful of lines for a four-tool agent; the payload cost is nothing, and it means:

> **v1 adds no new routes at all.** `/new` reuses `POST /conversations`, `/theme` is pure browser,
> `/trifecta` ships in the page.

**The seam** (`D_pikuri_free_core`) does need care: `App` must never touch a
`Pikuri::Trifecta::Report`. `AgentRunner#trifecta` returns one today (for the boot script) — so add a
Pikuri-free `#trifecta_html` beside it, rendering through a new server-side-of-the-seam
`PikuriWeb::TrifectaView`, and let `App` pass a String into `locals:`.

Address it per conversation like everything else — `App`'s own rdoc says "every route names the
conversation it acts on", and reading it off the runner the tab already has costs nothing.

## `/model` — the UI half of an idea that already exists

**`ideas/per-conversation-model.md` owns this.** Do not re-derive the pending-transport slot, the
`[model, api_base]` identity, the `meta.json` field, or the inheritance rule here; that file has
them, and it has since been sharpened with the library-side mechanics.

Sequencing runs both ways. **`/model` cannot ship with the other three** — it needs that backend.
And **shipping v1 unblocks that idea's UI half**: its "where does the control live" question closes
the moment the palette and the dialog helper exist, leaving it backend-only work plus one catalog
entry, one `<template>` and one `switch` arm. The two graduate separately; the palette goes first.

The one thing this idea adds: the picker dialog `/theme` builds is the picker dialog `/model` wants,
so the fourth command is nearly free. Whether its list is a static `<template>` or fetched depends
on whether the current-model marker rides the `status` SSE frame — a loose end that file already
lists. (`/theme` shows the marker has to be computed on open regardless, which nudges toward
static.)

## The palette: mechanics

- **Anchoring is CSS's, not JS's.** `#composer` gets `position: relative`, the palette
  `position: absolute; bottom: 100%; left: 0; right: 0`. An absolutely-positioned child is out of
  flex flow, so it costs the composer's layout nothing, and it tracks the textarea's auto-grow for
  free — the TUI needed a `#reposition` hook for exactly this and we get it from the box model.
  Do **not** reach for CSS anchor positioning; this needs nothing it offers.
- On the phone the composer is at the bottom (`order: 1`) with the status bar above it, so the
  palette opens over the status bar. That reads correctly — it is one line, and it is not what you
  are looking at while typing a command.
- `interactive-widget=resizes-content` already keeps the composer above the on-screen keyboard, so a
  palette anchored to the composer is above it too. Nothing extra for iOS.
- **Keys:** ArrowUp / ArrowDown move, Escape closes, Enter runs. The composer's existing `keydown`
  handler claims Enter for submit, so the palette's handler has to get there first — one handler on
  `#prompt` that checks "palette open?" before falling through.
- **Touch:** tapping an `<li>` runs it. `pointerdown` must `preventDefault()` to keep the caret in
  the textarea, with the run on `click`; otherwise the blur closes the palette before the tap lands.
  This is the iPhone story the whole feature is for.
- **`[hidden]` gotcha:** the rows will have `display: grid` for the two columns, which overrides the
  UA stylesheet's `[hidden] { display: none }`. Needs an explicit
  `#slash-menu li[hidden] { display: none }`.
- **a11y:** the combobox pattern — `role="listbox"` on the `<ul>`, `role="option"` + `aria-selected`
  on rows, `aria-activedescendant` on the textarea. The project already labels everything
  (`aria-label` on every icon button), so this should not be the one place that doesn't.

## Discoverability

Nothing tells you `/` does anything. The composer's `title` already carries a hint ("Enter to send,
Shift+Enter for newline; sending mid-turn injects"); append "`/` for commands" to it. A placeholder
change is *not* the answer — it costs the auto-grow behaviour the current one-word placeholder was
chosen to protect.

## Open questions

- **`Q_script_loading`** — two `<script src>` tags with `dom.js` first and plain globals, or
  `<script type="module">` with a real `import`? Modules need no build step, give real
  encapsulation (so `dom.js` cannot quietly become a global junk drawer), are always deferred and
  strict, and both target browsers have supported them for years. Cost is one extra request on
  localhost and the strict-MIME requirement, which Rack already satisfies for `.js`. Lean: modules
  — the greenfield target is exactly what makes them free here.
- **`Q_theme_picker_shape`** — the theme dialog with two rows is a heavy way to flip a boolean. Is
  it a *picker* (list, current marked, click to apply-and-close), or two big buttons? The former
  matches `/model`; the latter is one tap fewer. Decide when drawing it, not now.
- **`Q_error_dialog_weight`** — a modal for a typo is intrusive; the alternative that keeps the
  intent (visible, unmissable, nothing swallowed) is a status-bar note, for which `app.js` already
  has precedent (`'not sent'`). Settled as the dialog because it can list the known commands and a
  status line can't; worth revisiting if it feels heavy in the hand.

`Q_drawer_as_dialog` has moved out to `ideas/drawer-as-dialog.md` — it is a refactor of existing
code, not part of this feature, and it must not be bundled.

## Where the nuggets go at graduation

- The palette's shape — catalog server-rendered, dispatch client-side, **no transcript echo**, the
  Enter/unknown-command rule — is a real fork with real alternatives rejected: a `DECISIONS.md`
  entry (`D_slash_command_palette`?) plus a flat invariant in *Scope decisions*.
- **`D_no_js_build_step` gets amended, not superseded**: drop the line count and the one-file
  clause, state the rendering-vs-mechanics test and the latency qualifier. The *Scope decisions*
  bullet in AGENTS.md moves with it — it quotes the "~100 lines" figure too.
- The three-place contract (catalog / `app.js` dispatch / `<template>`) → *Conventions*, beside the
  block-kind rule it mirrors.
- `SlashCommand` and `TrifectaView` → one **Layout** line each, plus their own rdoc headers; and
  `public/dom.js` → a **Layout** line carrying the "no app knowledge" admission rule.
- `/` for commands, and what each does → `README.md`.
- `/model`'s arrival → the per-conversation-model idea's graduation, not this one's.
