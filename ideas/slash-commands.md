# Slash commands

A `/`-prefixed command palette in the composer, pikuri-tui's `Shared::SlashMenuPopup` ported to the
browser. Initial set: `/model`, `/new`, `/trifecta`, `/dark`, `/light`.

The TUI is the shape to copy — a non-modal list floating above the input, filtered by what is typed,
Up/Down + Enter, ESC dismisses, the caret never leaves the field. What does **not** port is its
plumbing, and that is most of what is interesting below.

**Settled** (agreed 2026-08-29): no transcript echo and no `callback` return value; `<dialog>` +
`showModal()` for the modal; v1 adds no new routes; `/model` postponed to a v2 that needs no new
mechanism. The `Q_*` at the bottom are what is still open.

## The five, and what each actually touches

| command | what it does | server involvement |
|---|---|---|
| `/dark` | theme cookie + `data-theme` | none — already a button |
| `/light` | ditto | none — already a button |
| `/new` | `POST /conversations`, follow the id | route exists |
| `/trifecta` | dialog showing this agent's trifecta report | new render, no new route (below) |
| `/model` | dialog listing `[[llm]]` connections, pick one | the whole of `per-conversation-model.md` |

Three of five are a **second front door onto an affordance that already exists** — the theme toggle
and the `+ new conversation` button both live in the drawer footer, which on the phone means opening
the drawer to reach them. `/dark` from the composer is strictly less work than ☰ → scroll → tap.
That is the actual argument for this feature on the phone, more than the two new dialogs are.

So the dispatch for those three is not new code, it is *calling the existing handler*: factor
`applyTheme(theme)` out of the toggle's click listener and `startConversation()` out of `newBtn`'s,
then both the button and the command call them. No second path to keep in sync.

## The shape: catalog on the server, dispatch in the browser

- **The catalog is server-rendered**, once, into `index.erb`: a `<ul id="slash-menu">` with one
  `<li data-command="/trifecta">` per command, name and description in two columns, hidden until
  needed. `D_no_js_build_step` — no client-assembled markup, and no `GET /commands?q=` round trip
  per keystroke for a fixed five-item list (that alternative is server-rendered too, and still
  absurd).
- **`app.js` only filters, selects and dispatches.** Filtering is
  `li.hidden = !li.dataset.command.startsWith(text)`. Dispatch is a `switch` on the command name.
- **The catalog is conditional**: `/model` is listed only when `config.llms.size > 1`, the TUI's
  `Shared::Model::Picker#multiple?` gate, so the palette never offers a no-op pick. That means the
  list is data the host injects, not a constant baked into the template.

Suggested home: `lib/pikuri_web/slash_command.rb` — `SlashCommand = Data.define(:name, :description)`
plus a `.catalog(model_switch:)`, mirroring the TUI's file of the same name minus the `callback`
(see the next section for why the callback doesn't port). Pikuri-free, so it sits on the browser
side of the seam with `App` and `Config`.

### The three-place contract

Because dispatch is client-side, a command's name exists in two places — the Ruby catalog and the
`switch` in `app.js` — plus, for a command with a dialog, its server-rendered fragment. Adding one
means touching all of them. That is the same shape as the existing block-kind contract
(*Conventions*: "adding one means touching all three"), and it should be written down the same way
rather than pretended away.

Rejected: making the markup carry `data-href` / `data-method` so the JS becomes a generic
"do what the `<li>` says" dispatcher. `/dark` isn't a request at all, so the generic form would still
need a special case, and five commands do not pay for an indirection layer.

## No transcript echo — the TUI's outcome mechanism doesn't port

`Shared::SlashCommand#callback` returns a String that `SlashMenuPopup` writes into the conversation
pane as a block. Here that is **forbidden twice over**:

- Client-side would be client-only conversation state — `D_server_authoritative_transcript` says
  never.
- Server-side would put a block in `Transcript` that is not in `history.json`, so
  `D_replay_from_history`'s replay would not reproduce it: the line shows now and is silently gone
  after a reload. Worse than not showing it.

Which is fine, because **every one of the five has a visible effect of its own** — a dialog opens,
the palette closes, the page navigates, the colours change. The TUI needs the echo because `/logs`
and `/trifecta` have nowhere else to speak; here they have a dialog. Drop `callback` and the outcome
String from the port entirely.

Corollary: **no "Command not found" either**, and none is needed — see the Enter rule.

## Enter: one rule, no argument parsing

None of the five takes an argument, so the TUI's `"/name rest"` split is dead weight. The rule:

> The palette is open ⇒ Enter runs the highlighted command. The palette is closed ⇒ Enter sends the
> message, exactly as today.

The palette opens only while the buffer is a leading `/` with no whitespace **and** at least one
command matches. So:

- `/t` → open, `/trifecta` highlighted, Enter runs it (TUI behaviour, and the whole point of
  autocomplete).
- `/usr/share/foo is broken` → space, closed → sends. A path or a code snippet is never swallowed.
- `/typo` → no match, closed → sends as an ordinary message.

That last one is the debatable case: a typo becomes a prompt to the LLM. The alternatives are a
transcript echo (forbidden, above) or a status-bar message — `app.js` already writes transient text
into `#status-state` (`'not sent'`), so the precedent for out-of-band feedback exists. But refusing
to send text the user typed, because it *resembles* a command, is the worse failure. See
`Q_unknown_command`.

## The palette: mechanics

- **Anchoring is CSS's, not JS's.** `#composer` gets `position: relative`, the palette
  `position: absolute; bottom: 100%; left: 0; right: 0`. An absolutely-positioned child is out of
  flex flow, so it costs the composer's layout nothing, and it tracks the textarea's auto-grow for
  free — the TUI needed a `#reposition` hook for exactly this and we get it from the box model.
  Do **not** reach for CSS anchor positioning; this needs nothing it offers.
- On the phone the composer is at the bottom (`order: 1`) with the status bar above it, so the
  palette opens over the status bar. That reads correctly — it is one line, and it is not what you
  are looking at while typing a command.
- `interactive-widget=resizes-content` already keeps the composer above the on-screen keyboard, so
  a palette anchored to the composer is above it too. Nothing extra for iOS.
- **Keys:** ArrowUp / ArrowDown move, Escape closes, Enter runs. The composer's existing
  `keydown` handler claims Enter for submit, so the palette's handler has to get there first —
  one handler on `#prompt` that checks "palette open?" before falling through.
- **Touch:** tapping an `<li>` runs it. `pointerdown` must `preventDefault()` to keep the caret in
  the textarea, with the run on `click`; otherwise the blur closes the palette before the tap lands.
  This is the iPhone story the whole feature is for: type `/t`, tap `/trifecta`.
- **`[hidden]` gotcha:** the rows will have `display: grid` for the two columns, which overrides the
  UA stylesheet's `[hidden] { display: none }`. Needs an explicit `#slash-menu li[hidden]
  { display: none }`.
- **a11y:** the combobox pattern — `role="listbox"` on the `<ul>`, `role="option"` +
  `aria-selected` on rows, `aria-activedescendant` on the textarea. The project already labels
  everything (`aria-label` on every icon button), so this should not be the one place that doesn't.

## The dialog: `<dialog>` and `showModal()`

`D_target_browsers` is Firefox desktop + Safari on iPad/iPhone, greenfield, no polyfills — and both
have had `<dialog>` since early 2022. So the answer to "modal if possible" is **yes, and for free**:

- `showModal()` makes everything outside the dialog inert. No hand-rolled `inert` juggling — the
  drawer needed that (`app.js`'s `chat.inert = open`) precisely because it is a `<div>`, not a
  `<dialog>`.
- ESC closes it and fires `cancel`. Nothing to write.
- `::backdrop` is a real pseudo-element; the scrim needs no extra div.
- Focus goes into the dialog on open. Restore it to `#prompt` on close explicitly rather than
  trusting the browser to.

**Chrome outside, body inside** — the ✕ button and heading live in `index.erb`, wrapping a body
element whose content is swapped. That is exactly the pattern `#drawer` already establishes (its own
comment: the chrome sits *around* the nav because `GET /conversations` replaces the nav's
innerHTML). One `<dialog>` reused by both commands, or one per command; see `Q_one_dialog`.

**Full-screen on the phone** is the same trick as everything else here — `@media (max-width: 40rem)`
giving the dialog `width: 100%; height: 100dvh; max-width: none; margin: 0; border-radius: 0`. Same
markup, placement is CSS's (`D_one_shell_two_layouts`). It is a third occurrence of the breakpoint,
but still inside `style.css`, so the "written twice, and the two move together" note in AGENTS.md
stays true.

Note: `app.js`'s document-level Escape handler currently closes the drawer. With a modal dialog open
it still fires; closing an already-closed drawer is a no-op, so this is harmless — but it wants a
glance rather than a shrug.

## `/trifecta` — pre-rendered, and zero new routes

`Pikuri::Trifecta::Report#render` is plain text on purpose (its rdoc: "a host wanting color or width
walks this tree itself"). v1 should take the cheap, honest option: the `advisory` as a highlighted
paragraph and `render` in a `<pre>`, HTML-escaped, no kramdown. Same words the boot script prints.
Walking the tree into styled rows is a later refinement, not a v1 gate.

The report is **static for the life of the process** — one conversation factory, one tool set, and
the trifecta is about tools, not models. So it can be rendered straight into `GET /c/:id` and sit in
the closed `<dialog>` until wanted. It is a handful of lines for a four-tool agent; the payload cost
is nothing, and it means:

> **v1 adds no new routes at all.** `/new` reuses `POST /conversations`, `/dark` and `/light` are
> pure browser, `/trifecta` ships in the page.

**The seam** (`D_pikuri_free_core`) does need care: `App` must never touch a
`Pikuri::Trifecta::Report`. `AgentRunner#trifecta` returns one today (for the boot script) — so add a
Pikuri-free `#trifecta_html` beside it, rendering through a new server-side-of-the-seam
`PikuriWeb::TrifectaView`, and let `App` pass a String into `locals:`.

Address it per conversation like everything else — `App`'s own rdoc says "every route names the
conversation it acts on", and reading it off the runner the tab already has costs nothing.

## `/model` — the UI half of an idea that already exists

**`ideas/per-conversation-model.md` owns this**, and says outright that the UI is unsettled: "where
the control lives (sidebar row, status bar, a `/model` line in the input, something else) is an open
question". This is a proposed answer to that question — and nothing more. Do not re-derive the
pending-transport slot, the `[model, api_base]` identity, the `meta.json` field, or the inheritance
rule here; that file has them.

The consequence for sequencing: **`/model` cannot ship with the other four.** v1 is the palette plus
`/new` `/dark` `/light` `/trifecta`; `/model` is one more catalog entry, one more dialog and one
`switch` arm, added when the backend lands. The palette is designed to make that a small diff, which
is itself an argument for building it first.

And the dependency runs both ways: **shipping v1 unblocks that idea's UI half.** Its "where does the
control live" question stops being open the moment the palette and the dialog exist — the answer is
"a `/model` entry in the catalog, in the dialog `/trifecta` already built" — which leaves it a
backend-only piece of work. So the two ideas graduate separately, and this one goes first.

The one thing this idea does add: **the dialog is a plausible home for the picker, and it is the
same dialog `/trifecta` needs**, so the second command is nearly free once the first exists.
Whether the model dialog is pre-rendered like the trifecta one or fetched depends on whether the
current-model marker rides the `status` SSE frame — which is a loose end that file already lists.

## The JavaScript budget

`D_no_js_build_step` says JS is "as minimal as possible", ~100 lines (it is ~180 today). This adds
roughly 50–60: filter, select, key handling, dispatch, dialog open/close. That is a real cost and
the idea should not pretend otherwise. The defence:

- No dependency, no build step, no npm — the invariant's actual teeth.
- All rendering stays server-side: the catalog, the descriptions, the trifecta report, the dialog
  chrome are all ERB. The JS toggles `hidden` and calls `showModal()`.
- Two of the five commands add *zero* new behaviour, only a second caller for a function that
  already exists.

If it comes in much above that, the design is wrong somewhere — most likely in hand-rolling
something `<dialog>` already does.

## Open questions

- **`Q_unknown_command`** — `/typo` + Enter: send it as a message (proposed), or refuse it with a
  status-bar note? Sending is proposed because a path or code line must never be swallowed, and
  because there is nowhere legitimate to put an error. Worth a second opinion; it is the one place
  this diverges from the TUI, which echoes a red "Command not found".
- **`Q_one_dialog`** — one reusable `<dialog>` whose body is swapped, or one per command? Two
  dialogs is more markup but no JS at all for content-swapping, and each can be
  server-rendered complete. Lean: one per command, since v1 has exactly one.
- **`Q_command_names`** — `/new` vs `/new-conversation`; two commands (`/dark`, `/light`) vs one
  `/theme`. Two is better for autocomplete (`/d` → `/dark` unambiguously) and is what was asked for.
  The TUI's `/clear` ("clear conversation + context") has no analogue here — conversations are
  separate objects, so `/new` is what `/clear` means in the web shell.
- **`Q_discoverability`** — nothing tells you `/` does anything. The composer's `title` already
  carries a hint ("Enter to send, Shift+Enter for newline; sending mid-turn injects"); appending
  "`/` for commands" is the cheap answer. A placeholder change is not (it costs the auto-grow
  behaviour the current placeholder was chosen to avoid).
- **`Q_drawer_as_dialog`** — once `<dialog>` is in the file, the drawer's hand-rolled
  `inert` + Escape + `matchMedia` juggling is a candidate for deletion. Out of scope, and a
  full-screen overlay is not obviously a modal (you navigate *from* it), so this is a genuine
  question rather than an obvious cleanup. Do not bundle it.

## Where the nuggets go at graduation

- The palette's shape — catalog server-rendered, dispatch client-side, **no transcript echo**, the
  Enter rule — is a real fork with real alternatives rejected: a `DECISIONS.md` entry
  (`D_slash_command_palette`?) plus a flat invariant in *Scope decisions*.
- The three-place contract (catalog / `app.js` dispatch / fragment) → *Conventions*, beside the
  block-kind rule it mirrors.
- `SlashCommand` and `TrifectaView` → one **Layout** line each, and their own rdoc headers.
- `/` for commands, and what the five do → `README.md`.
- `/model`'s arrival → the per-conversation-model idea's graduation, not this one's.
