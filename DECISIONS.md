# DECISIONS.md

The *why-we-chose* record for pikuri-web — especially the roads not
taken, which nothing else here has a home for. Never context-loaded; read
when someone asks "why this way?". It is not the how-it-works reference
(the YARD headers), the what-you-must-not-break list (`AGENTS.md`), or
the user-facing promise (`README.md`). An entry links out rather than
restating: `AGENTS.md` states the invariant flat with a `See D_<slug>`
pointer, this file holds the argument behind it, and never two
half-answers. A fork inside the agent loop, a tool, or LLM transport
belongs to `../pikuri/DECISIONS.md` — cite it, don't re-argue it.

**Format.** One entry per decision, newest first. The ID is `D_` plus a
1–4-word snake_case slug, so a citation carries meaning on its own.
Entries carry no dates — nobody reads this for the archaeology, and git
owns the edit history, so never narrate how an entry used to read.
`grep '^## D_' DECISIONS.md` is the index — there is no ToC, and every
`D_<slug>` referenced in the repo must exist as a heading here.

**Two tests before writing an entry, and both must pass:**

- **Is there a real fork?** If nothing was seriously considered and
  rejected, it isn't a decision — it's how the thing works, and that's
  the YARD header. This is the guard against a diary.
- **Would a future change silently break without it?** If rediscovering
  the rejection costs a rebuild anyway, the fork isn't worth an entry.

**A manual is not a decision, and it does not live here.** The tense
tells you which you are holding: past — *"we chose X over Y because Z"* —
is a decision; imperative future — *"change this and those move
together"* — is a manual, and belongs next to the thing, ideally as a
script that cannot drift from what it produces. `bin/regen-icons` is the
worked example: `D_icon_plate` argues the plate, the script holds the
sizes.

**Budget the parts, not the entry.** Some decisions need more room than
others, so there is no line cap — but the compulsory core is short:
Status, Context, Decision, and the rejected alternatives at **one line
each**. A rejection earns a paragraph only when its argument *surprised*
you — when the obvious option failed for a reason a reader could not
reconstruct. Below that, an optional tail may hold only: a measurement
actually run, a mechanism that cannot be re-derived (the iOS compositing
fact, the `pointerup` tap), or constraints binding future work. Prose
that re-explains the decision at greater length is not on that list.

**Entries are mutable — edit in place, don't append addendums.** Keep an
entry current as its decision is refined. Two limits: the
roads-not-taken **stay** (they are live content, not stale history, and
the most valuable thing here); and a decision *reversed after shipping*
forks a tombstone rather than being overwritten — leave the old entry,
set its `Status:` to **Superseded by `D_<slug>`**, and write the
replacement fresh.

---

## D_feature_owns_its_file — A feature that owns a slice of the page owns a script file, paired with the markup it renders from; `app.js` mounts and wires them

**Status:** Accepted, shipped with `public/js/composer.js`, the first
one, then `public/js/statusbar.js` and `public/js/transcript.js`. `app.js`
is not being split further on principle — the next feature moves out when
it earns it.

**Context.** `public/js/app.js` had no organizing principle beyond
"client-side". The composer's auto-grow sat three functions from the
palette's filter, both sat beside the sidebar's delete confirm, and the
only rule about where a function went was `D_no_js_build_step`'s "may name
elements and routes", which every function satisfied. Nothing in it was
wrong; it was a drawer, and a drawer is what a file becomes when the only
alternative is another drawer.

**Decision.** A feature that owns a slice of the page may own a file, and
then it owns that slice *whole*:

- **The file is paired with `views/index.erb`, and says so.** It looks its
  elements up by id, because those ids are the contract the template
  renders and there is no honest way to be loosely coupled to markup you
  are hand-in-glove with. `composer.js` owns `#composer` and everything in
  it — the buffer, the auto-grow, the palette, the keyboard — and owns
  `POST /messages` too, because what happens when you press send is the
  whole reason the feature exists.
- **`app.js` is the composition root.** What stays there is the page's
  spine — one `EventSource` demultiplexed to several features — plus the
  wiring *between* features. The slash `commands` map is the worked
  example: `/theme` is the theme's, `/new` the conversation list's, and
  only the root knows both, so a table of them is wiring rather than a
  leftover.
- **What crosses a boundary goes through the root**, never through the
  DOM: the composer is handed the conversation id (page state, from the
  URL) and hands back an `onsendfailed`, because `#status-state` is not
  its element to write.
- **`dom.js` is unchanged** — the one file that knows no markup at all.
- **Extraction is earned, not routine.** A file is justified when the
  outcome is clearly better code, which means a slice with enough
  behaviour to deserve a header of its own. A fifteen-line `theme.js`
  would be ceremony; the composer at ~230 lines and four concerns is not.

**Rejected: components decoupled from their markup.** The first cut of
`composer.js` was a `Composer` class handed its root element, finding its
parts by ARIA role (`[role="listbox"]`, the form's one `textarea`) so it
named no id — justified as reusability. Nothing will ever mount a second
composer, and paying indirection for an instance that will not exist buys
a *weaker* statement: `querySelector('textarea')` is true by accident
where `#prompt` is true by contract. Reverted before the pattern could be
copied into a second file.

**Rejected: enforcing the partition from the Ruby suite.** A spec can
slice `index.erb` and assert every id `composer.js` names sits inside
`#composer`. But these specs pin the *protocol* — what the server renders
against what the client names — and how the client source is split is not
protocol. A test with an opinion on file layout would make every future
split a spec change, and would be the sole enforcement of a rule whose
value is that it is a judgment call. `client_contract_spec.rb` therefore
scans the scripts jointly and says nothing about which one holds what.

**Rejected: prefixing every id with its feature** (`composer-prompt`,
`composer-menu`). The markup is already half-converted by accident —
`drawer-*` and `status-*` — and it would make ownership visible in the
HTML and in `style.css`. It churns a dozen CSS selectors for a rule
nothing enforces, and the bare ids read better in the stylesheet, which is
the other consumer. Revisit if two features ever want the same short name.

**Consequences.**

- `app.js` no longer names `#prompt`, `#slash-menu` or `/messages`.
- **`Q_composer_edges` is half-answered.** `statusbar.js` took `#cancel`:
  the id is the contract, not the nesting, so a button sitting in
  `#composer`'s markup belongs to whoever the status frame drives. The
  unknown-command dialog stays the root's — it is already reached through
  `onunknown`, which is wiring, and its `<template>` lives outside the
  form with the others.
- **The status bar is the store for the intended connection, and now says
  so.** `/model` used to read `#status-model-pending`'s text straight out
  of the DOM, legal only because both halves sat in one file; it now asks
  `statusbar.intendedModel()`. The DOM-as-store choice survives the split
  — the alternative, keeping the last status frame in the root, would have
  been a second copy of state the bar already renders.
- A moved function stops being covered by anything that scanned only
  `app.js`. `client_contract_spec.rb` reads every script joined, and
  globs `public/js/` rather than listing names — the `statusbar.js` split
  broke it on a hardcoded list, which is the failure mode the rule exists
  to prevent, so a split cannot quietly shrink the protocol check.

---

## D_icon_plate — Every rasterized app icon carries an opaque plate; only the master SVG is transparent

**Status:** Accepted, shipped in `public/images/` (`kuri.svg`,
`favicon.svg`, the five PNGs), `public/manifest.webmanifest`,
`views/index.erb` and `App`'s `mime_type :webmanifest`. Generated by
`bin/regen-icons`.

**Context.** *Who* the icon is was decided upstream — Kuri the pika in
the Talus coat, `../pikuri/DECISIONS.md` `D_kuri_mascot`. What lands on
this side of that line is the consequence the drawing hands its hosts:
Talus is a mid grey (`#a89c8e`), so there is no ground it reliably
contrasts against, and each host has to say where the background comes
from. Under `D_target_browsers` the install path that matters is iOS *Add
to Home Screen*, and iOS composites transparency onto black — a
transparent PNG of a grey animal loses its dark eyes and whiskers into
the fill.

**Decision.** `kuri.svg` is the master: transparent, unplated, tight
`viewBox` on the art's own bounding square, for the README and anywhere a
bare mascot is wanted. Every *rasterized* icon is that drawing centred on
an opaque `#1e1f22` plate. The manifest stays a static file; the only
server-side change is registering the `.webmanifest` MIME type, which
Rack's table lacks and without which every browser refuses to parse it.

**Rejected: transparent PNGs, letting each platform supply the ground** —
on iOS the ground is black whatever the wallpaper, and on a white tab
strip a grey blob with a cream face is a smudge. The alternative was
re-opening the *coat* to suit the file format, which is not this repo's
decision to re-open. The plate is the price of the coat, paid where the
constraint bites; `../pikuri`'s own README still renders it unplated.

**Rejected: SVG-only icons, no PNGs at all** — tempting with no build
step, but `apple-touch-icon` does not accept SVG and manifest SVG support
is uneven enough that the install prompt is the wrong place to find out.

**Rejected: the icon set as a hand procedure**, a table of sizes in prose
for whoever next opens a rasterizer. A table that has to be retyped is a
*manual*, and prose is the one place a manual can be neither executed nor
tested. `bin/regen-icons` holds the geometry, the plate colour, the five
sizes and the maskable ear-clearance bound, and generates `favicon.svg`
too — so the sanctioned duplicate is no longer hand-maintained.
`D_no_js_build_step` is untouched: nothing runs it at boot or on request,
and the PNGs stay committed artifacts.

**Consequences.** `public/images/kuri.svg` is a **verbatim** copy of
`../pikuri/assets/kuri.svg` — byte for byte, comments and all, vendored
because this project ships its own `public/` and has no build step to
sync one. The library is the only source of truth for the drawing, so a
mascot change is re-copy then `bin/regen-icons`, never a redraw here; a
local tweak is lost at the next copy, and silently, because nothing
compares the two.

**This is a sanctioned exception to `D_theme_cookie`'s "nothing outside
`style.css` may read a raw colour", in two places, both unavoidable
rather than sloppy.** An icon is a *file*, rendered by a launcher that
never loads the page, so it cannot resolve a CSS token — `#1e1f22` is
baked into the plate. And `<meta name="theme-color">` is read by the
browser before any stylesheet applies, so `index.erb` writes the literal
for the resolved theme. Neither is a themed *surface*. A *third* raw
colour outside `style.css` should be argued for, not assumed from these
two.

---

## D_per_conversation_model — A conversation's model is `[model, server]` in `meta.json`, minted onto the agent by the factory and written back at turn end from the agent's own transport

**Status:** Accepted, shipped. `/model` switches a live conversation, a
new conversation inherits the one the tab was reading, and the status
bar names the connection.

**Context.** `Config` has always parsed every `[[llm]]`; only the first was
ever used. pikuri's half was done too — `Agent#run_loop(user_message:,
transport:)` applies a switch at the top of a turn, keeping history,
callbacks, tools and controls, and `apply_transport!` is *private*, so the
kwarg is the only way in. That is deliberate upstream: the chat is
single-thread-confined, and a background thread mutating the connection
mid-completion would tear an in-flight stream. The library cannot know
nothing is in flight; `AgentRunner`'s state machine can. The pending-slot
shape was therefore **forced, not chosen** — the open question was only where
the *selection* lives and when it is written.

**Decision, in four parts.**

*Identity is the `[model, api_base]` pair* — never a name (one config edit
from changing, and not recoverable from a transport) and never a model id
alone (two `[[llm]]` entries may run one model on two servers). This is
pikuri-tui's `Shared::Model::Choice.key` ported into `ModelCatalog`, including
its fall back to the raw model id for a transport from outside the catalog.

*It lives in `meta.json`, written at turn end from the agent's own transport.*
`#save` runs from `finish_turn`, under the runner's mutex, on the executor
thread. Reading the field off the agent rather than off the selection makes
the envelope and `history.json`'s last `model_id` agree by construction.

*A reopened conversation is **minted** on its saved transport* — the factory
resolves `Conversation#model_at_mint` / `#server_at_mint` against the catalog
and hands the result to `Agent.new`. The pending slot is only ever a live
switch.

*The status bar is the model's only surface, and reality there is free.*
`apply_transport!` assigns the agent's transport only *after* `with_model`
returns, so `status_data[:model]` — read straight off it — can never advertise
a model the switch did not reach. That is pikuri-tui's footer rule satisfied
by construction rather than by a subscription: a footer cannot read the agent,
and we can.

**Rejected: deriving the model from `history.json`'s `model_id`** — it is a
model *string*, so it cannot carry the server half; `#row` would have to parse
every stored history to render one sidebar; and a conversation that inherited
a model but has not spoken yet has no `model_id` at all.

**Rejected: persisting at pick time.** A pick arrives on a request thread, so
this either exports history mid-`complete` or writes `meta.json` beside
`#save`, which `D_no_store_lock` forbids in as many words. For a conversation
with no turn yet it also writes the *commit point* over no `history.json` — a
listed conversation that cannot be opened. **Accepted cost:** a pick with no
message after it is lost across a restart.

**Rejected: seeding the pending slot instead of minting.** Two reasons, and
neither is the tempting one — history integrity via `model_id`-mismatched
thinking signatures is a measured no-op on every backend we point at
(`../pikuri/ideas/thinking-block-replay.md`). First,
`Agent#detect_and_emit_context_cap!` runs in the agent's **constructor**, so
minting on the factory default probes the *wrong* server's window. Second, a
pending slot set on every reopen stops meaning "picked and not yet landed",
which is the meaning the status bar's arrow and the dialog's marker need.

**Rejected: a transcript block for a switch.** It would survive a reopen —
`History::Message#model_id` lets `HistoryReplay` derive a switch boundary —
but that means two producers of one block, and two derivations disagree
eventually, so a reload would silently rewrite the transcript. The status bar
carries the model instead, leaving `SseListener`'s `ModelSwitched` arm silent.

**Rejected: a synthetic bare turn to apply a pick early** — costs a round-trip
and raises `EmptyTurnError` against a prompt-only conversation on a
separate-system-field provider.

**Rejected: subscribing to `ModelSwitched` to clear the arrow at the landing.**
Without it the arrow clears at `finish_turn`, so a pick made while idle leaves
the bar reading `local → remote` for the turn already running. That is early,
not wrong — the bar never claims a model the switch did not reach — and not
worth a non-rendering hook on the renderer. Revisit if the lag grates against
a slow first token.

**Consequences.**

- **Three readers, and they must not collapse into one.**
  `Conversation#model_at_mint` (what disk said at mint; the factory is its only
  reader), `AgentRunner#model` (intent — `pending || current`, what
  `registry.create(from:)` inherits), and `@agent.transport` (reality, read
  only inside `AgentRunner`). The `_at_mint` suffix and the *absence* of a
  runner-level reader for reality are what keep a future convenience accessor
  from merging them.
- **The mint-time pair is stale against disk by design** — `#save` moves
  `meta.json` on and the Data never follows. Harmless because the factory is
  its only reader, at mint.
- **Half a pair is no pair.** An envelope predating this has a `model` naming
  the *boot* connection and no `server`, so `#row` reads it as having nothing
  saved and it opens on the default. No migration, no `SCHEMA` bump.
- **A switch onto a smaller window is accepted, not refused.** Nothing
  re-baselines the history, so 90k of conversation moved onto a 32k connection
  fails on the next turn; the dialog lists each `context_window` so the pick is
  informed rather than discovered, and that is the whole mitigation.
- **A saved connection gone from the config falls back to `primary_llm`, said
  only in the `/model` dialog** — not the transcript (a block absent from
  `history.json`) and not `supported: false` (which means "unreadable
  envelope"). Cleared on the first save or pick, by when `meta.json` holds the
  fallback and the note would describe a deviation from nothing.
- **`--server` / `--model` were removed ahead of this**, so there is no
  precedence rule between a flag, the file and a conversation's saved model.
  See the amendment to `D_schema_complete_config`.
- **The catalog is a constructor argument, not a second wiring** — one factory
  still means one tool set, so the boot trifecta report stays true of every
  agent.

---

## D_slash_command_palette — The catalog is the server's, the palette is the browser's, and a command never writes to the transcript

**Status:** Accepted, shipped with `/new`, `/theme` and `/trifecta`;
`/model` joined them (`D_per_conversation_model`) and is the first
command gated on the config — `SlashCommand.catalog(connections:)` drops
it when there is nothing to pick between. The palette's mechanics live in
`public/js/composer.js` (`D_feature_owns_its_file`).

**Context.** pikuri-tui has a slash palette (`Shared::SlashMenuPopup`) and it
is the obvious thing to port: a list above the input, filtered as you type,
Up/Down + Enter. It is worth more on the phone than on the desktop, because
the drawer footer's two buttons — new conversation, theme — cost a drawer
open to reach, where `/theme` costs three keystrokes from where the caret
already is.

**Decision, in four parts.**

*The catalog is server-rendered; the dispatch is not.* `SlashCommand::CATALOG`
renders whole into `#slash-menu` and the browser filters it by toggling
`hidden` per row. A command *runs* in the browser because most of them are
browser-side anyway (a navigation, a cookie, a dialog); `/model`, the one that
is not, still opens its dialog there and posts a name. Adding a command is
therefore a three-place contract — catalog, an arm, and a `<template>` for one
with a dialog — the same shape the block kinds have, and written down in
`AGENTS.md` beside them.

*The palette is the composer's; the arms are the app's.* The mechanics —
filter, highlight, resolving a buffer to a name — are the component's. What
each name *does* could not follow: `/new` posts a route, `/model` opens a
dialog over this tab's conversation, `/theme` writes a cookie, all of it page
knowledge the component may not hold. So `app.js` hands it a `commands` map
and the component dispatches into it. A name in that map which the config
gated out of the catalog is simply never rendered a row to reach it by — which
is how `/model` stays gated in the one place that decides it.

*A command never writes to the transcript.* This is where the TUI's design
stops porting: its `SlashCommand#callback` returns a String echoed into the
conversation pane. Here the client-side form of that is conversation state the
server does not hold (`D_server_authoritative_transcript`), and the
server-side form is a block absent from `history.json` that
`D_replay_from_history`'s replay would silently drop — the line would show now
and be gone after a reload. So `SlashCommand` carries no callback and no
outcome String; each command's own visible effect is the feedback.

*Every dialog is a real `<dialog>`, opened through one helper.* `showModal()`
gives modality, ESC, focus containment and `::backdrop` outright under
`D_target_browsers`, where the drawer had to hand-roll `inert` for the same
job. `dom.js`'s `openDialog(title, body)` builds the chrome, appends,
`showModal()`s and removes the element on close, so no dialog sits in the page
at rest.

**Rejected: `/dark` and `/light` as two commands** — the catalog would grow a
row per *value* of every future setting, and the picker is the shape `/model`
wants anyway. The cost is that `/t` stops resolving uniquely, which is
precisely the case a palette exists for.

**Rejected: `GET /commands?q=` per keystroke** — absurd for a three-item list,
and the worked example of `D_no_js_build_step`'s latency qualifier.

**Rejected: an HTML-string signature for `openDialog`.** The unknown-command
dialog interpolates *what the user typed*, so a string API would make that
caller a concatenation of user input — an escaping hazard designed into the
helper. Taking a `Node` cloned from a `<template>`, with values set through
`textContent`, makes the safe path the only path.

**Rejected: sending an unknown `/word` to the model** — a typo would silently
become a prompt. Enter on a leading `/word` matching nothing opens a dialog
naming the known commands, and the text stays in the composer to be fixed. The
escape hatch is the space: anything containing whitespace is never read as a
command, so `/usr/share/foo is broken` sends normally.

**Consequences.**

- **A bare `/` arms nothing.** It opens the palette as a menu with no row
  highlighted, so Enter sends rather than running whichever command sorts
  first — `/new` navigating away on a stray keystroke is not a thing that
  should be possible.
- **A message that is *only* a path** (`/etc/hosts`, alone, no other word)
  now raises the unknown-command dialog instead of sending. Accepted: this is
  a chat-only shell with no file tools (`D_chat_only_entry_point`), and the
  dialog names the fix.
- **`/trifecta` costs no route.** The report is static for the life of the
  process — one factory, one tool set — so it ships pre-rendered in a
  `<template>`. `App` must not touch a `Pikuri::Trifecta::Report`
  (`D_pikuri_free_core`), hence `TrifectaView` and `AgentRunner#trifecta_html`.
- **The theme picker's current marker is computed on open**, never
  server-rendered: the theme changes in the page after it was served.
- **Picking a row is a `pointerup`, not a `click`.** The row's `pointerdown`
  is prevented so the caret stays in the textarea — the blur would close the
  palette out from under the tap before it could land — and iOS answers a
  prevented pointerdown by synthesizing no compatibility mouse events at all,
  `click` among them, which is the only thing a non-interactive `<li>` had to
  fire on. So the phone's tap did nothing. `pointerup` is delivered by a tap
  and by a mouse release both, and is the row's *only* listener, so a desktop
  click cannot run the command twice.
- **Every send path is the form's `submit` event, and a command is resolved
  before anything is posted.** `/trifecta` tapped on ↑ opens the dialog
  exactly as Enter does; a command is never a message, whichever way it was
  sent. The resolution reads the *text* rather than the highlighted row,
  because tapping ↑ blurs the textarea and the blur has already emptied the
  palette's selection — the buffer is what survives that.
- **The phone's on-screen Return keeps inserting a newline**, matching the
  Claude iPhone app. Binding it to send was tried and reverted: it is the one
  keyboard with no Shift+Enter, so a Return that sends makes a two-line
  message unwritable. On the phone ↑ is Enter's send, and tapping a palette
  row is Enter's run.
- **`Q_error_dialog_weight` stays open.** A modal for a typo is intrusive;
  the alternative that keeps the intent is a status-bar note, for which
  `app.js` has precedent (`'not sent'`). Shipped as the dialog because it can
  list the known commands and a status line cannot. Revisit if it grates.

---

## D_one_shell_two_layouts — One `index.erb` for the phone and the desktop; the difference is placement, so it is CSS's

**Status:** Accepted, shipped. The phone layout is the Claude-Mobile
shape: `#topbar`'s ☰ opens `#drawer` as a full-screen conversation list,
the composer is one growing row with a yellow ↑, and the status bar
drops to a line of text.

**Context.** The iPhone was the one target in `D_target_browsers` that
did not work, and the shape asked for is visibly a different screen from
the desktop's sidebar-beside-chat. The obvious move is a second template
picked per device.

**Decision.** One markup tree, two layouts, selected by `@media
(max-width: 40rem)` in `public/style.css`. `#drawer` *is* the desktop
sidebar column — the same element and the same `_sidebar.erb` partial —
restyled to `position: fixed; inset: 0`; `#topbar` and `#drawer-header`
are each hidden in the layout that has no use for them. Nothing is
per-device: resizing a window crosses the breakpoint live.

The breakpoint is **40rem**, not the 48rem it replaces, because iPad
portrait is 768px = exactly 48rem — so the old query matched on an iPad
and handed a *desktop* target the phone fallback.

**Rejected: a second `index.erb` (or `mobile.erb`).** Four arguments, any
one of which is close to sufficient:

- *The block-kind contract triples.* `AGENTS.md` **Conventions** already
  says a new block kind means touching {SseListener}, `index.erb` and
  `style.css`. A second shell makes that four files forever, to buy a
  divergence that is one media query.
- *`app.js` would have to branch.* It reaches a dozen elements by id.
  Two shells means either the same ids in both — in which case the second
  file is a copy, not a variant — or per-layout branches in the one file
  whose whole premise is minimalism (`D_no_js_build_step`).
- *Choosing a shell means UA sniffing, and UA is the wrong signal here
  specifically.* iPadOS Safari reports as a Mac, so the one distinction
  this project's browser decision turns on — iPad counts as desktop — is
  the one the UA string lies about. Width is the real signal, it is free
  in CSS, and it stays testable by resizing a desktop window.
- *A response that varies by device needs `Vary`*, and cannot fix itself
  when the device rotates.

**The line, for the next time this comes up:** different *placement* is
CSS's; different *content* — a shorter transcript, thinking blocks
suppressed, a summarized view — would be a template's. If content ever
diverges, the split is by *fragment* (`_composer.erb`, `_topbar.erb`)
shared between two thin shells, never two copies of the page, and
selected by an explicit URL or cookie rather than by UA.

**Rejected: dropping the status bar on the phone,** which is what Claude
Mobile does. The queued count is load-bearing here — it is how a
mid-turn injection's wait is made legible
(`D_interloper_mid_loop_input`) and how a *queued* turn is distinguished
from a refused one (`D_serial_turn_executor`). It stays, as one line of
text; its two buttons move instead.

**Rejected: one button that is ↑ when idle and ■ when busy.** The
prettier phone composer, and it silently costs the feature: sending
mid-turn *injects*, so an arrow that becomes a stop button takes
injection away exactly when it is useful. Send and stop stay two
controls, stop revealed by `busy`.

**Rejected: the zero-JS checkbox drawer** (`:has(:checked)` and two
`<label for>`s) — it genuinely covers open, close and select, since
tapping a row is a page load. But a full-screen overlay that is not a
modal leaves the chat behind it tabbable and readable to a screen
reader, and `inert` is a DOM property, not a selector. `app.js` owns the
toggle for that one attribute's sake, and gets Escape-to-close with it.
**Rejected alongside it: `<dialog>` + `showModal()`**, which would hand
over focus containment for free but has to be an in-flow sidebar on the
desktop and a top-layer modal on the phone; mixing the `open` attribute
with `showModal()` for that is worse than the ten lines it saves.

**Consequences.**

- **`+ new conversation` and the theme toggle now live in the drawer
  footer on *both* layouts.** They could not be duplicated per layout
  (one id, one element), and the phone's status bar is text-only. This is
  the one change the desktop sees, and it reads better anyway: starting a
  conversation belongs with the list of conversations.
- The breakpoint is written twice — `style.css`'s media query and
  `app.js`'s `matchMedia`, which closes the drawer when the layout
  changes so `inert` cannot strand a chat column nothing covers. They
  must move together.
- The composer is one auto-grown row on the desktop too, and its
  keyboard hint moved from the placeholder to a `title`: a paragraph of
  placeholder wraps to three lines at phone width, and Chrome sizes an
  empty textarea to its *wrapped placeholder*, so auto-grow opened the
  box at three lines before a character was typed.
- **Phone landscape is what a width-only query gets wrong.** An iPhone 15
  landscape is 852×393: it passes 40rem onto the desktop layout, with a
  20rem sidebar taking a third of the width and a 393px column holding
  transcript, composer and status bar. Unfixed on purpose — adding
  `(max-height: 26rem)` to the query is the cheap catch if anyone
  actually chats in landscape.
- **Verified in a resized desktop Chromium, not on a phone.** What is
  measured: the 40rem/48rem breakpoint against iPad portrait, 44px tap
  targets, auto-grow capping at 40vh, no horizontal page scroll at 320px,
  `inert`/Escape/resize-guard, both palettes. What a real iPhone still
  owes an answer on: `dvh` against Safari's shrinking chrome, the
  on-screen keyboard under `interactive-widget=resizes-content`,
  `env(safe-area-inset-*)`, and whether an always-visible per-row ✕
  mis-taps in practice (see `D_delete_no_undo`).

## D_no_store_lock — `ConversationStore` gets no lock; the folder is consistent by construction, and the store owns the whole write path

**Status:** Accepted. Nothing to ship *as a lock*: this is a decision
not to build one. What did ship in the same pass is the thing that made
the decision honest — {ConversationStore#save} taking the history and
owning the whole commit — plus the rdoc that stops overclaiming. The
idea file that argued for the lock across three rewrites is graduated
into this entry.

**Context.** The store's consistency rested on a *discipline* nobody
stated: writes went through {AgentRunner}'s mutex, reads ran from
Sinatra request threads, and the class's rdoc said "Thread-safe:
stateless past its constructor arguments" — a true claim about the
*object*, sitting exactly where a reader looks for a claim about the
*folder*. Every mechanical argument for a lock has since been settled
elsewhere:

- **N writers arrived and were audited clean.** Per-conversation agents
  (`D_conversation_owns_agent`) mean several turn-ends write at once, but
  into *disjoint subdirectories*, and one directory can never have two
  writers because a conversation admits one turn at a time. The audit is
  in `D_serial_turn_executor`, and it is why `--turns > 1` shipped
  without a lock.
- **Reads are already serialized.** Nothing in {App} holds a store;
  every call goes through {ConversationRegistry}, whose monitor wraps
  `#list`, `#find`, `#create` and `#delete`.
- **The listing already tolerates concurrency.** `#row` takes a read's
  own `ENOENT` as the answer instead of checking `file?` first, so a scan
  concurrent with a save or a delete is correct with no coordination.

**Decision.** No lock in `ConversationStore`, and no plan for one. What
holds the folder together is named in the class's `== Thread-safety`
section: the partition gives one writer per directory, both files are
written temp-file-and-rename, `#row` absorbs the races a listing can
see, and cross-call sequences are explicitly *not* atomic — `#find` then
`#delete` has a gap and callers tolerate the conversation vanishing
inside it.

**The store owns the whole write path, history included.** Previously
{AgentRunner#persist} wrote both halves itself — `history.save(dir)`
then `store.write_meta` — which left the store claiming a folder it
wrote half of. `#save` now creates the directory 0700, calls
`History#save`, then writes `meta.json` as the commit point, and
`write_meta` is private. This is what lets the decision above rest on
"unnecessary" rather than on "impossible": a lock that could only ever
guard our half of the directory would have been the same
claim-wider-than-the-mechanism problem in a new place. Two things fell
out of it beyond the lock question — a history is no longer written into
a default-mode directory and tightened afterwards (`History#save`
creates `attachments/` *before* it `mkpath`s the conversation directory,
so the contents were briefly world-readable), and "an interrupted save
leaves the conversation unlisted" became a spec instead of a comment,
because the store can now be interrupted between the two halves where
two separate calls could not be. The seam question this raised — a
pikuri type in the store — is `D_pikuri_free_core`.

**Rejected: `Concurrent::ReentrantReadWriteLock`.** An RWLock buys
parallel readers, which pays only under read contention with long read
critical sections; `#list` is a directory scan of a few hundred `stat`s
for a single user with a handful of tabs. **Do not re-argue this on
dependency cost** — the note that killed it for two rewrites ("a
genuinely new direct dependency, and the only non-stdlib lock in the
pikuri family") is void: `concurrent-ruby` is in the bundle for the turn
executor (`D_serial_turn_executor`), so the gem is free and it *still*
loses. If a sidebar ever measures badly the fix is the index file
`#list` already rejects, not a fancier lock.

**Rejected: a plain stdlib `Monitor`** (re-entrant, because `#find` calls
`#list` and a `Mutex` would deadlock on itself — the accidental
threading bug the lock was meant to prevent, introduced by the lock).
Four reasons, past the fact that it fixes nothing:

- It would serialize operations that are already safe to interleave.
- **It invites the false argument it was meant to prevent.** A monitor in
  the store reads as *the* reason the folder is consistent, and the next
  reader relaxes the atomic rename or puts the `file?` check back — the
  only two mechanisms that work against a second process or against
  pikuri's own writes. `D_serial_turn_executor` warns in exactly this
  shape: distrust a correctness claim resting on the wrong mechanism.
- It would be the third lock, needing a documented ordering (registry or
  runner outermost, store innermost, never the reverse). Forced in
  practice, still a cost to carry for no benefit.
- Since `#save` owns the history write, any lock around it would hold
  across `history.json` + `attachments/` — the longest filesystem
  operation here — where it would once have held only a rename. That is
  the one argument an RWLock has left, and it argues for no lock around
  the write at all.

**Consequences.**

- **Adding a lock later is a two-line diff**, now that one method owns
  the write path. Nothing is deferred at a cost, which is the whole
  reason not to speculate.
- **The trigger to reopen:** a store operation spanning two directories
  (a move, a merge, an index file), or a second writer to one
  conversation's folder. Either breaks the disjointness the audit rests
  on.
- **An in-process lock was never the answer to a second process** and
  cannot be sold as one (`D_no_multi_process_lock`).
- The one real bug this re-audit turned up was not a store problem at
  all: a request thread holding a runner across a delete could resurrect
  the conversation, fixed as runner state ({AgentRunner#discard!}) and
  written up in `D_delete_no_undo`'s consequences. A store lock would not
  have caught it — a lock per method is not a transaction.

## D_no_multi_process_lock — A second process against one state root is a user mistake, not a supported configuration; last-writer-wins stands

**Status:** Accepted. Nothing to ship: this is a decision *not* to build
a cross-process lock. The idea file that argued for one is graduated
into this entry.

**Context.** Two `pikuri-web-chat` processes on different ports share
`~/.local/state/pikuri/pikuri-web-chat/conversations/`, and pikuri's
`History#save` rewrites `history.json` whole. The failure is *not* a torn
file — the save is temp-file-and-rename, so what is on disk is always a
complete valid history. It is a **silently clobbered conversation**: the
loser's turns vanish at the next save with nothing on screen to say so.
Since `D_delete_no_undo` there is a worse shape of it — process A deletes
a folder that process B still holds live, B writes it straight back at its
next turn end, and a conversation the user explicitly confirmed away
reappears in the sidebar.

**Decision.** Accept all of it. Last-writer-wins, no `flock`, no
enforcement anywhere; `README.md` states the limitation under
**Conversations** and that is the whole of the answer.

What settles it is that the second process **buys nothing**. One process
already serves any number of tabs, and a conversation owns its own agent
so turns in different conversations run undisturbed side by side
(`D_conversation_owns_agent`, `D_serial_turn_executor`) — there is no
capability behind a second port, only a second copy of the same
single-user tool pointed at the same home. A failure mode reachable only
by a configuration with no reason to exist does not earn a mechanism.

**Rejected: `flock` the conversation directory on open,** rendering the
locked row read-only in the sidebar. It is the *right* shape if the
collision were worth defending against — a dimmed row with a reason is the
affordance the busy-refusal already uses — but it puts per-conversation
lock state in `ConversationStore`, and file locks are the kind of state
that turns a hard kill into "why can't I open my own conversation".
Permanent cost, hypothetical benefit.

**Rejected: one `flock` on the state root at boot,** refusing a second
instance with `--port` named in the error. The cheap version — one lock in
`bin/pikuri-web-chat` instead of per-conversation state — and it kills the
failure outright rather than degrading it. Still rejected: it converts a
mistake nobody makes into a startup failure everybody can hit (a stale
lock after `kill -9`, a supervisor restarting faster than the old process
exits), and it forbids the one second instance that is harmless, the one
that never opens the same conversation. Refusing to start is a worse
default than a warning in the README.

**Consequences.**

- The resurrection under `D_delete_no_undo` is now decided rather than
  deferred: it stays, and that entry's pointer resolves here. Its
  *in-process* twin — a request thread holding a runner across a delete —
  was a separate bug with a separate fix ({AgentRunner#discard!}) and no
  bearing on this entry: one process cannot claim another's runner.
- `ConversationStore` never grows cross-process consistency. Its atomic
  rename remains all a concurrent reader outside this process gets, and
  the in-process locking question is independent of this entry — settled
  separately in `D_no_store_lock`, and an in-process lock never bought
  anything across processes anyway.
- **The one trigger that reopens this: a shared state root.**
  `D_per_shell_state_root` deliberately keeps each shell's conversations
  under its own folder, so today's only colliders are two copies of *this*
  shell. If a location shared with pikuri-tui or another shell ever lands,
  the colliders become processes a user has every reason to run at once,
  and the argument above stops holding. Locking is then part of that
  change, not a separate idea.

## D_no_event_queue — No owner thread: state is partitioned per conversation, browser state stays in the browser, and anything genuinely shared gets *one global* mechanism

**Status:** Accepted. Nothing to ship: this is a decision *not* to build
the owner thread that was on the roadmap. The idea file that argued for it
graduated into this entry.

**Context.** The standing plan was to give all mutable state a single
owner thread, Tuile-style: every other thread posts a command, no locks,
because one thread touches the state. The complaint driving it was real —
`Transcript`, `Broadcaster` and `AgentRunner` each held their own lock, and
cross-object consistency rested on a discipline nothing enforced. Three
options were on the table: **(a)** one lock per object, today's shape;
**(b)** one coarse lock over the whole state graph, Vaadin minus the
session axis; **(c)** one owner thread plus a queue, Tuile.

`D_conversation_owns_agent` shipped before the question came back, and
answered most of it: every exhibit that motivated (b) or (c) was audited
and found already fixed by the partition — the unguarded `SseListener`
state (one listener per runner now), the `conversation_rows` tear (one
monitor), two of the three refusal routes (gone), and the claim that an
owner thread was the precondition for concurrent turns (false, see
`D_serial_turn_executor`).

**Decision.** Three parts, and the third is the one with a future in it.

**No owner thread, and no coarse lock either.** The partition does the
work: one agent, one history, one transcript and one listener per
conversation, and a conversation admits one turn at a time
({AgentRunner#submit} injects rather than starting a second). Per-object
locks survive where they guard genuinely shared things — the registry's
monitor over the resident map, the broadcaster's over the subscriber list
— and each now guards one small thing with a stated owner, which is not
the failure the idea file opened by describing.

**This is a single-user server, and each browser owns its own state.**
No sessions, no auth, no accounts; a second person runs their own process
under their own OS account. What a tab holds — an unsent draft, scroll
position, the theme cookie, and *which* conversation it is reading — lives
in the browser and in the URL. Two tabs may read different conversations,
or the same one, and neither disturbs the other. The server holds the
conversations; the browser holds the view of them.

**If server state ever does become genuinely shared, it gets one global
mechanism — a single event queue, or a single lock — and never a
per-session one.** Stated now because the tempting wrong answer is
specific and has a famous precedent. Vaadin partitions its lock per
session because a session there owns a whole component tree; here a
session owns nothing, so a per-session lock would guard the empty set
while adding a session concept this app has deliberately refused. The
`Broadcaster` stays outside whatever is built, in either shape: it is a
sink, its lock guards the subscriber list that request threads and the
`:state, :stop` hook touch, and folding it in would put a new tab's
subscribe behind a running turn and the shutdown path behind a wedged one
— the exact parked-thread hazard `D_shutdown_on_state_stop` prevents.

**Why there is no guidance to crib.** The absence is itself the finding.
Sinatra has no concurrency model and no server-side state model —
`session` is a signed cookie, so there is nothing to lock — and mainstream
Rack/Rails practice is to *not have this problem*: stateless processes,
shared state in Postgres or Redis, the database doing the locking. A live
in-memory object graph plus a worker thread is structurally a desktop app
that speaks HTTP, so the precedents are Tuile, Swing and Vaadin rather
than Rails. It is also why a global queue and a global lock are one
decision in two costumes: Vaadin's `UI.access()` *is* this design, with a
lock where Tuile uses a dedicated thread. The *coarseness* transfers; the
session axis does not.

**Rejected: build it anyway, because the current model is past
comfortable** — a good argument, and true when written, that loses to
every one of its exhibits being fixed by the partition instead. Rebuild
the case from *live* defects if it returns; the old examples are spent.

**Rejected: option (b), one coarse lock, as a cheap step toward (c)** — it
buys nothing once the state is partitioned, re-coarsening a graph just
split so one conversation's kramdown pass waits behind another's, and it
must be released across the LLM call and across tool execution anyway,
which is the interleaving reasoning it was meant to remove.

**Rejected: a per-session lock or queue, Vaadin-style** — a session here
owns nothing, so it would guard the empty set while adding the session
concept this app refuses. Recorded as a rejection rather than an omission
because it is what a reader who knows Vaadin reaches for first.

**If one is ever built, these constraints come from decisions already
made** and would otherwise be rediscovered by hitting them:

- **The owner must never block** — not on I/O, a socket, a lock, or a
  reply from a thread that might be waiting on it.
- **The agent loop keeps its own thread** (`D_worker_thread_agent_loop`);
  what changes is direction — it posts events instead of calling the
  listener stack inline.
- **Per-connection SSE queues stay.** One slow client must not stall every
  tab; owner → queue → parked writer is already {Broadcaster}'s shape.
- **Every reply path gets a bounded wait and a 503,** or escapes replying
  altogether by publishing an immutable snapshot — {Transcript}'s trick.
- **Backpressure is asymmetric:** blocking a request thread is fine,
  blocking the agent thread stalls a turn, and blocking `:state, :stop`
  recreates the bug `D_shutdown_on_state_stop` exists to prevent.
- **Rendering need not move.** `D_rerender_and_replace` re-renders through
  kramdown at 15 fps; the owner owns *mutation*, not rendering, so
  markdown → HTML can stay on the agent thread and post the finished
  string.

**Consequences.**

- **The triggers to reopen are named, and none has fired.** More server
  state than the transcript and the resident runners — a search index,
  generated titles, a cache to invalidate — or a second writer to one
  conversation. Raising `--turns` is *not* one of them.
- **The snapshot-read design was taken, minus the queue.** {Transcript}'s
  `Block` is a `Data`, so `#update` replaces rather than mutates and a
  caller rendering a snapshot cannot have a block rewritten underneath it.
  That was the one piece of the idea that stood on its own.

## D_conversation_owns_agent — A conversation owns its agent; a tab owns which conversation it views

**Status:** Accepted, shipped. {ConversationRegistry} holds one
{AgentRunner} per conversation opened — its own `Agent`, `Interloper`,
`Cancellable`, `TokenLog`, {Transcript} and {SseListener} — and
{Broadcaster} addresses frames per conversation.

**Context.** Everything before this had *one* agent and one transcript, so
"which conversation is live" was server state and every tab followed it
(`D_single_shared_conversation`). That model has no precedent in any web
app: it is tmux in a browser. Slack is the counter-example — its channel
selection lives in the URL, and the session exists only for auth. A tab
should be free to read one conversation while another works.

**Decision.** A runner *is* a conversation, for its whole life. No
switching, no live pointer. `GET /c/:id` opens one, minting and replaying
its history on first visit; the tab's EventSource subscribes to that id;
`POST /messages` and `POST /cancel` both name their conversation. What
falls out is worth naming, because it is most of the value:

- **The whole switch machinery went away** — `new_conversation`,
  `load_conversation`, `delete_conversation`, and the ordering hazard where
  a `Reset` emitted before the live pointer moved got stamped with the
  outgoing conversation.
- **Nothing refuses because something *else* is busy.** Only delete
  refuses, and only for the conversation actually in flight.

**Rejected: minting a runner only on first *send*, viewing from a
throwaway replay.** Cheaper in memory, and it was what shipped one commit
earlier. Dropped because a tab reading a not-yet-resident conversation
would then apply frames whose block ids agree with its snapshot only
because both replay the same events into a fresh {Transcript} — correct by
an argument spanning two classes, which is the kind of thing this codebase
keeps trying to delete. Minting on view costs one agent per conversation
*opened in a session*, which for a single user is nothing.

**Rejected: reaping idle runners.** Nothing is ever dropped except on
delete. Add reaping if residency ever actually hurts; a cleverer minting
rule is the wrong lever.

**Rejected: device continuity, and it was never wanted.** Mirroring's one
apparent benefit was that every browser showed the same conversation, so
opening the iPad landed you where the desktop was. Independent browsers
are the *goal*, not the price: two tabs reading two conversations is the
feature, and a view that follows you between devices is the same
behaviour wearing a friendlier name. So this is not a cost to be paid
back later — do not reintroduce global selection state to buy it. If some
future ask genuinely needs a landing spot better than "the newest
conversation" ({ConversationRegistry#default}), it is a per-browser
`last_viewed` cookie on the `D_theme_cookie` precedent, which leaves other
tabs alone; server-side last-viewed is this decision reversed.

**Consequences.**

- The registry and {ConversationStore} are now the only genuinely shared
  mutable state. The registry has a `Monitor`; the folder needs no lock of
  its own, for the reasons in `D_no_store_lock`.
- `HistoryReplay.snapshot` became dead code and was removed.
- Rendering a detached conversation is not optimized: the
  accumulate-don't-render idea only pays at `--turns` > 1, which
  `D_serial_turn_executor` now allows but does not default to. If it is
  ever built, the choice is already made and the two losing readings are
  why. *Render always, fan out selectively* (what ships today) re-runs
  kramdown at 15 fps for a conversation nobody is watching — the single
  most expensive thing the server does, per `D_rerender_and_replace`.
  *Drop the transcript and replay on attach* is cheapest while detached
  but shows a hole where the streaming answer is, because `history.json`
  holds no in-flight partial message. **Accumulate, don't render** wins
  by keeping the {StreamingMessage} appends and the block structure while
  skipping the kramdown pass and the broadcast, then rendering once on
  attach — which works because `D_rerender_and_replace` already makes the
  HTML a pure function of the accumulated source, so it defers as easily
  as it moves threads. Open when it is picked up: whether
  `Listener::RateLimited`'s 15 fps timer should be wired at all for a
  detached conversation. Probably not, but it is pikuri's class — check
  whether a listener stack can be rebuilt mid-life before assuming.

## D_serial_turn_executor — Turns run on one shared executor, whose pool size is the inference server's slot count

**Status:** Accepted, shipped as a `Concurrent::FixedThreadPool` sized
by `--turns` (default 1), injected into every {AgentRunner}.

**Context.** A turn blocks on the LLM for minutes, so it cannot run on a
Sinatra request thread (`D_worker_thread_agent_loop`). Once conversations
own their own agents, "how many turns at once" stops being implied by
"how many agents".

**Decision.** One process-wide executor shared by every runner. Its queue
*is* the admission gate: submitting always succeeds, and a turn waiting for
a free slot reports `:queued` rather than being rejected. Cancelling a
queued turn needs nothing from pikuri — the job checks a flag on entry and
returns without starting.

**The pool size caps concurrent turns, and nothing else depends on it.**
It exists so turns do not outnumber the inference server's parallel slots
— match it to llama.cpp's `--parallel`. It is an operator setting about
load, with no correctness claim resting on it.

**Rejected: pinning the pool at 1 as a correctness precondition.** The
position this decision was first taken with, and the one to expect back —
it is what the abstraction invites. The argument was that an `Executor`'s
contract is `submit(block) → result`, a job runner that holds no state by
design, so single-writer safety at pool 1 is a property of *that number*
rather than of the abstraction, and would evaporate silently when someone
raised it. The premise is correct and worth keeping: **never rest a
correctness claim on a pool size.** The conclusion was not, because the
executor was not carrying single-writer safety in the first place. Raising
the pool was said to put two agents in two places at once — the
conversations folder, and pikuri's shared tool constants. Both were audited
when `--turns` was added, and neither holds.

- **The folder.** Two turn-ends write two *disjoint subdirectories*.
  {ConversationStore#save} touches only that one conversation's directory —
  `history.json` and `meta.json` both, each through a sibling temp file and
  a rename inside it; the shared root is created in the constructor and
  otherwise only enumerated.
  A listing concurrent with a save was already correct by design — `#row`
  takes a read's own `ENOENT` as the answer rather than checking first. And
  one directory can never have two writers, because a conversation admits
  one turn at a time.
- **The tool constants.** pikuri answers this itself now: every tool
  declares a sharing posture in its yardoc (its `DECISIONS.md`, "Every tool
  declares one of four postures"). `CALCULATOR` is `P_stateless`, and says
  outright to hand it to every agent in the VM; `FETCH` and `WEB_SCRAPE`
  are `P_shared_benign`, sharing a process-wide URL cache whose race that
  doc argues is harmless. `WebSearch` is built per wiring for its API keys,
  but is `P_shared_locked` on class-level per-provider limiters, so a
  per-agent instance would throttle no differently.

Single-writer safety was never located in the pool size. It comes from the
*partition*: per-conversation agents (`D_conversation_owns_agent`) plus a
conversation admitting one turn at a time ({AgentRunner#submit} injects
rather than starting a second). Two turns are two agents, two histories,
two transcripts, two listeners and two disjoint folders. That property is
independent of how many turns run at once, which is why `--turns` needed no
owner thread to go with it (`D_no_event_queue`).

**Rejected: deriving the pool size by probing the server's slot count.**
llama.cpp reports `--parallel` on `/props`, so this is possible and would
remove a way to misconfigure the pair. Not done: the probe would have to
happen at boot, before any conversation exists, and would make an
unreachable server fatal to *starting* rather than to the first turn.
A flag the operator sets alongside the one they already set on the server
is the cheaper half of that trade. Reopen if `--turns` is routinely wrong.

**Rejected: hand-rolling the pool on stdlib `Queue`.** Ruby ships no
executor, so the alternative is writing a pool, a shutdown protocol and a
backpressure policy by hand. `concurrent-ruby` is a new direct dependency
(the first `Concurrent::` in the pikuri family — pikuri itself is stdlib
`Mutex` throughout) and earns its Gemfile paragraph on exactly that.

**Rejected: treating the executor as the event queue.** They share a
mechanism and have opposite contracts — this one exists *to* block, an
owner thread must never block. See `D_no_event_queue`.

**Consequences.**

- Shutdown drops whatever is running: saves land at turn end, and
  `turn_executor.shutdown` from the `:state, :stop` hook deliberately does
  not wait (waiting there would re-create the parked-thread bug
  `D_shutdown_on_state_stop` exists to prevent). Accepted — single user,
  rare restarts.
- Specs inject `ImmediateExecutor` to run turns inline, which deleted one
  hand-rolled spin-waiter. The examples that are *about* the busy state
  keep a real thread.
- **Nothing enforces the pool size, and nothing should need to.** The
  `executor:` parameter is typed `Concurrent::ExecutorService`, which any
  pool satisfies; what carries the intent is the boot script's paragraph
  saying the number is a load cap. A future reader who finds a correctness
  argument resting on it should distrust the argument, not tighten the
  type.
- **`--turns > 1` buys overlapping inference, not overlapping search.**
  pikuri's search rate limiter holds its mutex across the HTTP call and is
  scoped to the egress IP, so two agents searching at once serialize
  anyway, and one tripping a provider's circuit breaker cools down the
  other. Documented at the tool wiring; it is upstream's design
  (`P_shared_locked`), not something to work around here.
- **The accumulate-don't-render idea for detached conversations becomes
  reachable**, since more than one conversation can now render at once —
  see `D_conversation_owns_agent`'s consequences, which parked it at pool 1.

## D_delete_no_undo — Deleting a conversation is irreversible, and the live one rolls onto a fresh conversation

**Status:** Accepted, shipped as `ConversationStore#delete`,
`AgentRunner#delete_conversation` and `POST /conversations/:id/delete`.

**Context.** `ConversationStore` grew every verb but this one, so
conversations accumulated until the user ran `rm -r`, which is what
`README.md` told them to do. Three things needed settling before a ✕
could go on a sidebar row: what confirmation looks like, what happens
when the deleted conversation is the *live* one, and whether the removal
is recoverable.

**Decision.** A native `confirm()` naming the conversation — one line of
`app.js` and the only option needing no CSS at all, where a modal
component is exactly the kind of thing that starts arguing for a build
step (`D_no_js_build_step`) — then a real removal: `FileUtils.rm_r` over the whole folder, `meta.json` unlinked
first. Deleting the live conversation is `#new_conversation` *without the
save* — the agent is cleared (its `Event::Reset` empties the transcript
in every tab, the same path a fresh conversation takes) and a fresh id
minted, then the folder goes. Both cases are refused while a turn is in
flight (409), like selecting and starting a conversation.

The conversation folder is ours end to end — nothing but pikuri and this
shell writes there — so a delete removes the directory wholesale. That is
deliberately unlike pikuri's refusal to sweep a single unreferenced
attachment (pikuri `DECISIONS.md` `D_history_attachments`): declining to delete a
*file* someone may have put beside the history is compatible with
removing the *conversation* it belongs to. Attachments are never shared
between conversations, so nothing is refcounted.

**`meta.json` goes first because it is `#save`'s commit point.**
Unlinking the envelope is that commit's exact inverse, so a removal that
dies half-way leaves a conversation *unlisted* rather than one that lists
and then cannot be opened. Orphaned bytes are the better failure.

**Rejected: an undo, and its tombstone variant.** Both need the folder to
survive the click. A conversation holds everything the user typed and
everything the tools fetched, unencrypted (`0700` is the whole of the
protection) — someone deleting one is often deleting it *because* of what
is in it, so keeping it for ten seconds "in case" is a privacy footgun
and keeping it until a sweep is worse. The tombstone shape was
additionally tempting because `#list` already skips a directory with no
`meta.json`; that state currently means *a save interrupted between
pikuri's half and ours*, and overloading it would make a crash and a
deletion indistinguishable forever.

**Rejected: refusing to delete the live conversation.** Consistent with
how switching refuses, and useless: the conversation you most want to
drop is usually the one in front of you. Rolling onto a fresh one is
barely more code and is what the user meant.

**Rejected: `DELETE /conversations/:id`, and a second `<form>` per row.**
The row is already a form that POSTs to `/select`, and a nested form is
invalid HTML while two sibling forms cannot share the row's flex line.
One form with two submit buttons, delete carrying `formaction`, keeps the
no-JS path working and leaves Enter on the row selecting rather than
deleting.

**Consequences.**

- A bare `conversations` SSE event now means "the sidebar's list changed,
  re-fetch it" — deleting a non-live conversation emits no `reset`, so
  without it every *other* tab would keep a row that 404s when clicked.
  `app.js` grew one `refreshSidebar()` that `reset` and the new event
  share; a future titles or search feature should reuse the same signal.
- The ✕ is revealed on hover and `:focus-within`, and shown
  unconditionally under `@media (hover: none)` — on a touch device the row
  itself is a link, so a tap opens the conversation instead of revealing
  anything (`D_target_browsers`). The reveal uses `opacity`, not
  `display`/`visibility`, or the button would leave the tab order and
  `:focus-within` could never fire.
- **Every row keeps its own ✕ on the phone, at 44px**
  (`D_one_shell_two_layouts`). *Rejected: the ✕ on the current row only.*
  It reads as a mis-tap defense, and there is already a `confirm()` by
  name in front of the delete, so a mis-tap costs a dialog and not a
  conversation — while a full-screen drawer has the width the 12rem
  sidebar did not. It also degrades badly: delete is refused mid-turn, so
  the row you are viewing is the likeliest one to be undeletable, and
  "only the current row is deletable" can mean nothing is. *Also
  rejected: an iOS-style `Edit` toggle* revealing all the ✕s — the
  fallback if 44px targets turn out to mis-tap on hardware, not the
  starting point.
- **A second process can resurrect what you deleted**, by saving its own
  live copy at the next turn end. Accepted as a limitation, and the
  strongest case anything made for a cross-process lock — which was
  weighed on exactly that basis and rejected in `D_no_multi_process_lock`.
- Nothing new serializes the folder. What keeps a delete from racing the
  turn-end save is the runner refusing while busy — see the bullet below
  for why that refusal had to become a *claim* rather than a read.
- **Amended: dropping the runner is not enough; it has to be retired.**
  `POST /messages` resolves a runner and submits to it in separate steps,
  so a delete landing in between removed the folder while
  a request thread still held a live runner — the next turn's save
  recreated the directory, and the conversation the user confirmed away
  came back in the sidebar one turn later, openable, holding its old
  history plus the new turn. `busy?` could not close it: once the runner
  is out of {ConversationRegistry}'s map, the registry can never see it
  busy again. The fix is {AgentRunner#discard!} — one atomic
  busy-check-and-claim on the *runner's* mutex, called inside the
  registry's monitor, with the runner dropped only if it succeeds. Either
  `#submit` claims the turn first and the delete is refused, or the
  discard wins and `#submit` answers `:discarded` (404 from the route);
  there is no interleaving where both proceed, so `#persist` needs no
  check of its own. This is the *in-process* twin of the cross-process
  resurrection two bullets up, and unlike that one it was reachable by a
  single user with two tabs — which is why it is fixed rather than
  accepted.
- Deleting is the whole answer to retention: still no cap and no
  auto-prune. `rm -r` on the state folder remains a complete reset.

## D_target_browsers — Firefox on the desktop, Safari on iPad and iPhone; greenfield only, no polyfills

**Status:** Accepted. All three targets have a layout
(`D_one_shell_two_layouts`); the iPhone's is unverified on a real device
— see Consequences.

**Context.** The delete button's hover-reveal was the first change whose
correctness depended on which browsers count, and "modern browsers" is
not an answer a CSS reviewer can use.

**Decision.** Three targets: Firefox on the desktop, Safari on iPadOS,
Safari on iOS. Nothing is polyfilled and nothing carries a vendor prefix
for a browser outside that list — `:has()`, `:focus-within`,
`@media (hover: none)`, `dvh` units and `SubmitEvent#submitter` are all
fair game and are used. **The iPad counts as a desktop**: it has the
screen for the sidebar-beside-chat layout as it stands.

**Rejected: "every modern browser".** It reads generous and decides
nothing — every question about a selector or a unit comes back
unanswered, and in practice it means testing on whatever is open.

**Consequences.**

- **The iPhone has a layout, and it is still unverified on hardware.**
  `D_one_shell_two_layouts` is the shape and what it measured in a
  resized desktop browser; what it could not measure is exactly the
  iOS-specific half (`dvh` against Safari's shrinking chrome, the
  on-screen keyboard, `env(safe-area-inset-*)`).
- **A phone layout is not a phone *recommendation*, and the split is
  deliberate.** Reaching this app from a phone means `--bind` leaving
  127.0.0.1 with no auth and no sessions
  (`D_single_shared_conversation`) and an unencrypted conversations
  folder — a LAN bind hands the whole history to anything on the wifi.
  The layout exposes nothing on its own, so it shipped ahead of that
  question; what must not follow from it is `README.md` starting to
  suggest the phone, or a nice phone UI becoming the argument for a
  casual `--bind 0.0.0.0`. The options nobody has costed: a bearer token
  the desktop prints as a QR code, basic auth over a self-signed cert
  (iOS trust-store friction), an SSH tunnel from the phone, a
  tailnet-only bind. An honest outcome is that none of them land and the
  README keeps saying "you are exposing your conversations, here is the
  flag".
- **A PWA is downstream of that same question,** and only worth it once
  it has an answer: an installed icon that opens a dead page whenever the
  desktop is asleep is worse than a bookmark. It would need a
  `manifest.json` plus the legacy `apple-mobile-web-app-*` metas (verify
  what current iOS honours rather than trusting a note), and standalone
  mode removes the URL bar — which takes the shrinking-viewport problem
  with it, so the two halves are friendlier together than apart. **No
  service worker**: the page is a server-rendered snapshot of
  server-authoritative state (`D_server_authoritative_transcript`), so an
  offline shell would have no transcript to show.
- A change that needs a polyfill or a build step to reach a fourth browser
  is out of scope twice over — here and under `D_no_js_build_step`.

## D_replay_from_history — Store only pikuri's history; re-derive the transcript by replaying synthesized events

**Status:** Accepted, shipped as {HistoryReplay}.

**Context.** A saved conversation has two layers: the *model* half
(messages, tool calls, results, thinking, attachments — `history.json`,
written by `Pikuri::Agent::History#save`, whose contents we do not get a
vote on) and the *render* half ({Transcript} blocks: kinds, ids, HTML).
Loading a conversation back means producing the second from something on
disk.

**Decision.** Store nothing beyond `history.json` and our `meta.json`,
and rebuild the blocks by turning each message back into the
`Agent::Event`s that produced it, fed through the real {SseListener}. The
transcript is *rebuilt, not swapped*: `Agent#load_history!` emits
`Event::Reset`, whose existing arm empties the transcript and every open
tab, and the replay refills it — so there is still exactly one
transcript, one renderer, and one event→kind mapping.

**Rejected: store the rendered blocks** (`blocks.json` beside
`history.json`). Exact reload, zero replay logic — and HTML strings on
disk, so a {MarkdownRenderer} or `style.css` fix never reaches an old
conversation, plus two representations of one conversation that can
disagree. The longer these files live, the worse frozen HTML gets.

**Rejected: append an event log** (`log.jsonl`, source text not HTML)
and replay it. It keeps the today's-renderer property, but it prices
persistence on pikuri's *event set*: an `Event ↔ Hash` codec must cover
every variant {SseListener} matches on and stay in step as pikuri adds
more — and pikuri adds them steadily (`Transient` and `HistoryLoaded`
both landed in one unreleased cycle). `History` is the opposite: written
down, `version:`-stamped, additive-only by decision, unknown keys
ignored. Betting the format on the stable one is not close. Nothing here
forecloses adding `log.jsonl` later if the losses below start to matter.

**Rejected: a `History → blocks` builder** instead of synthesized events.
Same output, one more place block kinds are decided — the
SseListener / `index.erb` / `style.css` trifecta would stop being one.

**Consequences.** Only messages are stored, so what never became one is
gone on reload: `! cancelled` and run-loop failure blocks,
`FallbackNotice` lines, and the partial assistant text a cancel
deliberately preserves (it raises out of `Chat#ask` before the message
lands) — a cancelled turn reloads as a user message with no reply under
it. Two couplings are the price of re-deriving: the replay must emit
events in the order the *agent* emits them rather than the order messages
sit in (a batch's `ToolResult` follows its own `ToolCall`), and it must
strip the `<system-reminder>` envelope `Agent#append_reference_block`
adds, whose tag is a private constant upstream. Both are held by an
end-to-end spec in `conversation_flow_spec.rb` that renders one
conversation live and again from disk and demands the same blocks — the
canary for a rename or a reordering upstream.

---

## D_shutdown_on_state_stop — Close the Broadcaster from Puma's `:state, :stop`, the last hook before the graceful wait

**Status:** Accepted, shipped in `bin/pikuri-web-chat`.

**Context.** Ctrl+C hung for as long as a browser tab stayed open. Every
open `EventSource` parks a Puma request thread in the `GET /events` drain
loop; Puma's graceful stop waits for in-flight requests **with no
deadline**; and the 15 s SSE heartbeat keeps those parked writes
succeeding, so nothing ever errors the thread out. The wait ended only
when the browser finally dropped the connection. This is the bill for the
threading rule (`D_worker_thread_agent_loop`) — a design that parks
serving threads on purpose has to unpark them on purpose too.

**Decision.** The boot script registers on Puma's `:state` event and
calls `Broadcaster#close` for `:stop` and `:restart`. That event is fired
by the server thread on the line *before* `graceful_shutdown`, which
makes it the last hook that runs on the near side of the wait.
`Broadcaster#unsubscribe_all` became `#close`: the same sentinel push,
idempotent, and it now also refuses *later* subscribers, so a connection
handed out mid-shutdown cannot re-park a thread. `force_shutdown_after:
5` stays as the backstop. Measured: two SSE clients attached, SIGINT and
SIGTERM both exit within the second.

**Rejected: `at_exit`, Sinatra's INT trap, and `Puma::Events#after_stopped`.**
All three are on the *far* side of the wait, so all three are release
valves that open after the thing they would have released has already
finished blocking. The INT trap additionally never fires — Puma
overwrites it during `launcher.run` — and `after_stopped` was measured at
a still-10 s hang, because `Puma::Server#run` performs its own
`graceful_shutdown` in the server thread before the launcher gets to fire
it.

**Consequences.** Nothing in the exit path may rely on `at_exit` or on
Sinatra's own INT trap; a future cleanup that needs to run before the
wait belongs in the same `:state` hook. `Broadcaster#close` must stay
idempotent and must keep refusing new subscribers — the invariant lives
in its YARD header.

## D_dev_flag_no_reload — `--dev` is Sinatra's development mode, not code reloading

**Status:** Accepted, shipped in `bin/pikuri-web-chat`.

**Context.** A dev flag on a web server usually promises reloading. Here
it can't: the agent, its listener stack and the runner thread are
long-lived instances wired once at boot, so Ruby under `lib/` reloads in
neither mode and re-reading it would leave a live conversation bound to
the old objects. `public/js/*.js` and `.css` were always read per request
and never needed a flag.

**Decision.** `--dev` flips Sinatra into `:development` and turns on
`show_exceptions` — which is what `views/*.erb` re-reading and in-browser
exception pages hang off, and nothing more. The README documents
restarting under a file watcher as the way to iterate on Ruby, which is
cheap now that shutdown is instant (`D_shutdown_on_state_stop`).

**Rejected: a reloading dev mode** (Zeitwerk reload, `rerun`-style
in-process reloading). Re-wiring the live agent is the actual
requirement, and no amount of reloading does it — the flag would name a
guarantee it cannot keep.

## D_theme_cookie — Theme is a browser cookie, resolved server-side at `GET /`

**Status:** Accepted, shipped in `public/style.css`, `views/index.erb`
and `public/js/app.js`.

**Context.** Adding a light theme raised where the preference lives. The
transcript is server-authoritative (`D_server_authoritative_transcript`),
so "state lives on the server" is the house style — but this particular
state is per-*browser*, not per-conversation, and the page it affects is
kept live by one long SSE connection that a reload destroys.

**Decision.** Both palettes live in `public/style.css` as `--dark-*` /
`--light-*`, and the rest of the file reads only the semantic tokens
(nine at first, eleven since the send button — see Consequences); dark
stays the default under `:root`, and `:root[data-theme='light']` remaps
the same set. `GET /` resolves the
`theme` cookie against an allowlist and renders `data-theme` onto
`<html>`, so a light-theme user never sees a dark first paint. `app.js`
flips the attribute and rewrites the cookie in place.

**Rejected: a `POST /theme` route and server-held theme state.** A round
trip for a colour change means a reload, and a reload costs an SSE
reconnect — paying a transcript resync for a presentational toggle. The
cookie is deliberately *outside* {Transcript} and stays presentational,
which is what lets "the transcript is server-authoritative" keep meaning
what it says rather than becoming "…except theme".

**Consequences.** The theme is the one piece of per-browser state in the
project, and it is the precedent a future per-browser preference should
follow. A new themed colour means adding it to both palettes *and* both
mappings; nothing outside `style.css` may read a raw colour.

`--send` / `--send-fg` are the procedure's first exercise —
the phone composer's yellow ↑ (`D_one_shell_two_layouts`). Two tokens
rather than one because the glyph needs its own value per palette, and
**not `--notice`**, tempting as it is for already being yellow:
`--notice` means "the agent said something noteworthy", and spending it
on a control muddies the kind→colour mapping that block kinds are
contracted on. Both palettes carry a real yellow with a dark glyph
(≥8:1) rather than a darkened one with white — the light theme's button
has to still read as yellow.

## D_chat_only_entry_point — The trifecta promise belongs to the boot script, not to the project

**Status:** Accepted, shipped; `bin/pikuri-web` renamed to
`bin/pikuri-web-chat`, matching pikuri-tui's `bin/pikuri-tui-chat`.

**Context.** The README never said which shape this shell offers — OS
agent, coding agent, or chat. It's a chat, and that turned out to be the
selling point worth leading with: the whole tool set is `web_search`,
`web_scrape`, `fetch` and `calculator`, so in pikuri's lethal-trifecta
terms it holds the *untrusted content* and *egress* legs and **not** the
*private data* leg. Nothing wired here reads the disk, runs a command or
touches a repo — so there is nothing on your machine for it to find, and
you can think out loud at it. But pikuri ships `pikuri-os`,
`pikuri-code` and `pikuri-workspace` in the same checkout, one line away.

**Decision.** The guarantee is attached to an *entry point*, and the
script carries its shape in its name. Should an OS or code shell grow
later it lands as a **sibling script** with its own tool set and its own
boot-time trifecta report, reusing the tool-set-agnostic plumbing
({AgentRunner}, {SseListener}, {Transcript}, {App}) — never as extra
tools bolted into this one.

**Rejected: attaching the promise to the project, and growing this
script's tool set.** A project-level promise is one a future commit
breaks silently: adding a disk- or shell-touching tool here would revoke
a guarantee a user has *already read* in the README, with nothing in the
diff that looks like a revocation. Naming the shape in the script makes
the same change visibly wrong.

**Consequences.** The README keeps only the caveat that survives the
promise: your own typed input still egresses to the configured LLM
server, and a scraped page can try to talk the agent into fetching an
attacker-chosen URL. The boot-time trifecta report stays the *checkable*
answer for whatever tools a script actually wired, so a sibling script
does not need this entry re-argued — it needs its own report.

## D_per_shell_state_root — Every shell keeps its state under one folder named after itself

**Status:** Accepted, shipped. Reverses the layout the first
conversation-store commit shipped, which put `conversations/` directly
under `Pikuri::Paths.state`.

**Context.** `Pikuri::Paths.state` is shared: pikuri writes there, and so
will pikuri-tui and every sibling script AGENTS.md anticipates
(`D_chat_only_entry_point` — a new capability is a new script, not a new
tool). Conversations are the first thing this shell persists, and the
first commit named the folder after its *contents*, on the theory that a
future pikuri-tui `/resume` should read the same files.

**Decision.** One folder per shell, named after the script, and
**everything that shell persists goes inside it**:

```
~/.local/state/pikuri/pikuri-web-chat/conversations/<id>/
```

`bin/pikuri-web-chat` derives a single `state_root` local and composes
every path from it, so the next thing worth persisting lands beside
`conversations/` rather than in a second place. The root is created by
{ConversationStore} at construction — the folder exists from boot, not
from whichever later event happens to save first.

**Rejected: a shared `conversations/` for cross-shell resume.** The
attractive end state is "start a conversation in the TUI, finish it in the
browser", and a shared folder looks like the cheap way there. It isn't:
the *format* is what makes that possible (pikuri's `history.json` plus a
documented envelope), and the format travels regardless of where the files
sit. Meanwhile a shared folder means two shells writing one directory with
no agreement about who owns it, no way to tell whose conversations these
are, and `rm -r` on it destroying more than the shell you meant. Path
sharing is the *last* step of interop, not the first.

**Consequences.** Cross-shell resume now needs a deliberate location — a
shared subfolder both shells opt into, or a pikuri-level store — and
whatever it is, it is a decision rather than an accident of layout. This
folder is also the reset: `rm -r` on it returns the shell to first-run
state and touches nothing else.

## D_schema_complete_config — One config file for every pikuri shell, whole schema, secrets nowhere else

**Status:** Accepted, shipped as {Config}, a port of pikuri-tui's
`Shared::Config`.

**Context.** A machine can run pikuri-tui and pikuri-web side by side,
and both want the same model connections and the same search-provider
keys. The loader raises on an unknown top-level key.

**Decision.** {Config} reads the same layered
`~/.config/pikuri/config.toml` as the TUI and carries the **whole**
schema — `[code]`, `[[code.mcp]]` and all — even though this host wires
none of it. It names no `Pikuri` constant and logs through
`PikuriWeb.logger`, staying on the Pikuri-free side of the seam
(`D_pikuri_free_core`). Secrets (`[[llm]].api_key`, `[search]` provider
keys) come from that file and from nowhere else; `--api-key-env` was
dropped in the same change.

**Rejected: trimming the schema to the sections this host reads.** It
would make the file *reject* one the TUI wrote — the strict-key check
turns every section we don't consume into a parse error, so the
"one file, every shell" property is only bought by carrying sections we
ignore.

**Rejected: CLI flags, `ENV`, and a project-local file as secret
sources.** A flag is visible in `ps` and in shell history; `ENV` is
inherited by every subprocess pikuri spawns; a project-local file is
git-committable. There is deliberately no `--api-key` flag and there
should never be one.

**Amended: `--server` and `--model` dropped too, so a connection has
exactly one source.** They overlaid the primary `[[llm]]`
via `Config.apply_llm_overrides`, which meant a connection had two
sources and a precedence rule between them — and the per-conversation
model picker was about to add a third, saved one, turning the rule into
a three-way question ("I booted `--model Z`, then opened an old
conversation — what am I talking to?"). Removing the flags deletes the
question rather than documenting it. Consequences: pointing the shell at
a different server now requires writing `~/.config/pikuri/config.toml`,
which is a handful of lines and a thing the user does once; the built-in
`Config.default_llm` still covers the zero-config case on the defaults,
so a first run against a stock llama.cpp needs no file at all.
`Config.load(overrides:)` survives for `:sandbox` / `:confirm`, which a
sibling shell may wire (`D_chat_only_entry_point`).

**Rejected as an alternative to dropping them: keeping the flags and
writing the precedence down** (saved wins on reopen; the flag is the
default for new conversations). It costs no code, but it leaves a shell
whose behaviour needs a paragraph to explain — complexity *plus*
documentation of that complexity, where removal leaves neither.

**Noted divergence from pikuri-tui**, whose three shells still take
`--server` / `--model`. Accepted: a TUI is invoked ad-hoc many times a
day, where a flag is genuinely the fastest path; pikuri-web is started
once and lives, so the flag buys almost nothing and the ambiguity costs
the same as anywhere. The intent is for the TUI to follow.

## D_track_pikuri_master — Path dependencies on `../pikuri`, not released gems

**Status:** Accepted, shipped; `pikuri-core` / `pikuri-pdf` are path
dependencies in the `Gemfile`.

**Context.** This shell already wanted master's surface — the boot-time
trifecta report and `Interloper#on_change`, neither of which was in a
release.

**Decision.** Track pikuri master by path. Upgrades follow pikuri's
`CHANGELOG.md`, whose `**Breaking:**` entries carry the migrations, with
pikuri-tui's HEAD as the worked example for anything ambiguous.

**Rejected: pinning released gems and waiting.** `pikuri-pdf` pins
`pikuri-core` in lockstep, so a released pdf gem refuses the next version
bump — pinning buys stability for exactly one release and then blocks.

**Rejected: bisecting pikuri-tui's git history to find a migration.**
Its history is mostly Tuile churn this project doesn't share; the
changelog is the cheaper and more accurate source.

**Consequences.** CI must clone `../pikuri` before bundling — without it
the path dependency fails the build outright.

## D_diagnostics_to_stderr — The browser shows the conversation; diagnostics stay on stderr

**Status:** Accepted, shipped. This *reverses* a design that shipped in
the original scaffold: `LogIO`, a Ctrl+L toggle and a collapsible in-page
log panel, all removed.

**Context.** The scaffold piped pikuri's per-subsystem loggers and
`PikuriWeb.logger` into a collapsible panel in the page, on the theory
that a browser front-end should be self-contained. In use it made the
transcript ambiguous: two unrelated streams — the LLM conversation and
the program's internal diagnostics — shared one surface, and the panel
needed its own capture machinery (`LogIO`), its own block kind, its own
keybinding and its own CSS to keep them apart.

**Decision.** The transcript shows the LLM conversation only — assistant
Markdown, reasoning, tool-call lines, tool observations, all driven by
{SseListener}. Internal diagnostics stay on their default stderr sinks
and never reach the page. Never cross the streams.

**Rejected: the in-page log panel** (as shipped). The operator running
`bin/pikuri-web-chat` already has a terminal; routing stderr through a
capture object, an SSE frame and a DOM node to arrive back in front of
the same person is machinery bought for nothing, and it is machinery that
every new block kind and every theme change then has to carry.

**Consequences.** {SseListener} renders *events*, never log lines, and
`PikuriWeb.logger` must never be pointed at the {Broadcaster}. A future
"show me what went wrong in the browser" want is a new decision, not a
resurrection of `LogIO`.

## D_worker_thread_agent_loop — The agent loop owns a worker thread; thread-safety lives in the sinks

**Status:** Accepted, shipped as {AgentRunner}.

**Context.** The agent loop blocks on the LLM for the length of a turn.
Sinatra hands each request a pooled Puma thread.

**Decision.** {AgentRunner} owns one worker thread and the loop runs
there, never on a request thread. The listener writes into thread-safe
sinks ({Transcript}, {Broadcaster}); each `GET /events` connection parks
*its* serving thread draining one subscribed queue. There is no UI thread
and no marshaling — thread-safety is a property of the sinks, not an
obligation on their callers.

**Rejected: running the loop on the request thread that started it.** It
holds a pooled thread for the whole turn, dies with the client that
posted, and makes "one conversation, many viewers"
(`D_single_shared_conversation`) impossible to state.

**Rejected: a marshaling UI thread, the TUI's model.** A terminal has one
thread that may touch the screen, so the TUI's listener marshals onto it.
There is no such thread here — the "screen" is N browsers reached through
a queue — so importing the pattern would add a hop with nothing on the
far side of it.

**Consequences.** Parked drain threads are what makes graceful shutdown
hang; see `D_shutdown_on_state_stop`. Any new sink the listener writes to
must be thread-safe on its own, because no caller synchronizes.

## D_interloper_mid_loop_input — Mid-loop input goes through `Control::Interloper`, input stays enabled while busy

**Status:** Accepted, shipped in {AgentRunner}; the queued-count push was
completed with `Interloper#on_change`, and the end-of-turn restart closed
the stranding window.

**Context.** pikuri-tui deferred mid-loop input. A web page makes the
want sharper: the input field is right there while the agent is working,
and a disabled field is a worse answer in a browser than in a terminal.

**Decision.** {AgentRunner#submit} starts a turn when idle and **injects**
when busy; the injection renders through the normal listener path as
`UserTurn(mid_loop: true)`, so nothing about the display is special-cased.
The input stays enabled while busy and the status bar shows the queued
count, which is pushed by `Interloper#on_change` — so the agent's *own*
mid-loop drain updates the browser too.

**Rejected: disabling the input while the agent works.** It is the
honest-looking option and it is the one that loses work: the user types
during the one period they most want to interrupt, and the field refuses.

**Rejected: queueing submissions client-side and posting them at idle.**
That is client-only conversation state, which
`D_server_authoritative_transcript` forbids — a reload would silently eat
the queue.

**Decision: a turn that ends holding a queue starts another one.** Only
`run_loop` drains the Interloper, so an injection accepted in the window
between the loop's last completion and {AgentRunner}'s state
reset — where `#submit` correctly still reads `:running` — had nothing
left to deliver it. It sat until the user happened to send again, with
the status bar promising "1 queued" over a conversation doing nothing.
{AgentRunner#finish_turn} claims the restart in the same critical section
that goes idle, so no `#submit` and no `#discard!` ever observes the gap,
and the restart is a *bare* turn: `run_loop(user_message: nil)` drains
before its first completion, which is the entire job.

**Restricted to a turn that returned normally.** A cancelled or failed
turn leaves what is queued for the next `#submit`. Restarting after a
cancel would make the stop button look broken — the user asks for quiet
and gets a fresh round-trip — and restarting after a transport failure
turns an unreachable server into a spin. Termination rests on `run_loop`
draining what it was restarted for; against an agent that does not, the
restart would post turns forever, which is why the fake agent in the spec
drains too.

**Rejected: draining the queue on `#cancel`.** It kills the same
stranding for the cancel path and makes "cancel" mean "stop everything",
badge back to zero. But it silently discards user-typed text that was
never rendered anywhere, and it widens a bug fix into a semantic change
to cancellation. Left as it was: the messages survive and the next
`#submit` delivers them.

**Consequences.** Interloper's delivery boundary is the caveat that
leaks: injections arrive at turn start and once each tool batch
completes, so one placed mid-response waits for that boundary. The
visible queued count exists to make that wait legible rather than to hide
it. The boundary itself is pikuri's decision, not ours — as of 0.0.7 it
moved off `after_tool_result` to tool-batch completion, and AGENTS.md's
documented caveat had to be corrected to match.

## D_pikuri_free_core — No `Pikuri::*` type reaches what the browser sees; server-side classes use them freely

**Status:** Accepted, shipped as "three adapters plus the boot script";
widened to include {HistoryReplay}; **restated as a boundary rather than
a list of classes**, when {ConversationStore#save} took over writing
`history.json` and therefore took a `Pikuri::Agent::History`. The count
was never the invariant — "translation happens at named boundaries, and
nowhere else" is — and the list of names had begun to read as the rule.

**Context.** This project tracks pikuri master (`D_track_pikuri_master`),
so pikuri's surface moves under it by design. What that costs depends
entirely on *where* the types are: a pikuri type in the rendering path
prices an upgrade at a sweep of every file the browser's state flows
through, while one in a disk utility prices it at that utility.

**Decision.** The line is the browser, not a file count. **Nothing that
reaches what the browser sees speaks a pikuri type:** {Transcript},
{Broadcaster}, {StreamingMessage}, {MarkdownRenderer},
{ConversationRegistry}, {Config} and {App} deal in ids, kinds, HTML
strings, paths and queues. **Server-side of that line, pikuri types are
used freely** — `bin/pikuri-web-chat` (boot/wiring), {SseListener},
{AgentRunner}, {HistoryReplay}, and {ConversationStore#save}.

**Rejected: keeping {ConversationStore} on the Pikuri-free side by taking
a block** — `store.save(conversation) { |dir| history.save(dir) }`, the
store yielding a `Pathname` and never holding a `History`. Built first,
then reverted: it preserved the letter of the old list at the cost of an
indirection that explained nothing, and the seam it was defending is not
one the store sits on. What settles it is that the refactor *relocates* a
pikuri call rather than adding one — `History#save` had exactly one call
site before ({AgentRunner#persist}) and has exactly one after (the
store), so the upgrade cost the seam exists to bound did not move at all.
A utility method that owns a directory is the right owner of what goes
into it.

**Rejected: letting Pikuri types spread to whatever needs them.** Passing
a `Pikuri::Agent::Event` into {Transcript} is the shortest path and it
prices every future pikuri upgrade at a full-project sweep. With the seam
held, a shifted surface costs rewriting the adapters — the same
fork-or-swap rationale as the TUI's.

**Consequences.** The adapters translate at the boundary, which
occasionally means a small unwrapping that would be unnecessary if the
event travelled whole. That cost is the decision, not an oversight.
{Config} deliberately stays on the Pikuri-free side even though it is
server-side, because its schema is the *file's*, not pikuri's
(`D_schema_complete_config`) — the boundary licenses pikuri types where
they help, it does not require them.

## D_rerender_and_replace — Re-render the whole message per delta; don't port the TUI's block-cutter

**Status:** Accepted, shipped as {StreamingMessage}.

**Context.** pikuri-tui streams assistant output through a
`StreamingMarkdownBuffer` — a block-cutter with committed-prefix
machinery, easily the most intricate piece of the TUI's rendering. The
obvious move for a sibling front-end is to port it.

**Decision.** Don't. {StreamingMessage} accumulates the source and
re-renders **all** of it through kramdown per (rate-limited) delta; the
browser replaces one div's `innerHTML`. What *is* kept is the TUI
buffer's lifecycle contract, because that part is about correctness
rather than cost: deltas are preview-only, the bookend `finalize` carries
the authoritative content (fast-path when equal), and the object is dead
afterwards — `append` after `finalize` and a second `finalize` both
raise.

**Rejected: porting `StreamingMarkdownBuffer`.** It exists to bound
per-token `TTY::Markdown` cost on a terminal that can only append. The
browser can replace a node, and kramdown over one message is cheap — so
the port would carry the terminal's constraint into a medium that doesn't
have it, along with its bug surface.

**Rejected: coalescing deltas here.** That already lives in pikuri as
`Listener::RateLimited` (15 fps). Reimplementing it would put two rate
limiters in one path and make the effective frame rate a function of
both.

**Consequences.** Per-delta cost is O(message length), which is fine at
chat scale and would not be for a very long single message; that is the
tripwire to watch if this ever changes.

## D_server_authoritative_transcript — The server holds rendered blocks; SSE carries only deltas

**Status:** Accepted, shipped as {Transcript}.

**Context.** A browser front-end has to answer three things at once:
page reload, a second tab, and `EventSource`'s automatic reconnect.

**Decision.** {Transcript} holds the rendered HTML blocks and is the
single source of truth. `GET /` renders the full snapshot into the page;
SSE carries only deltas against it, placed by block id. All three cases
then converge on the same state with no client-side bookkeeping.

**Rejected: client-side conversation state** (accumulating the
conversation in JS from the event stream). Every one of the three cases
becomes its own problem — the reconnect needs a replay protocol, the
second tab needs a backfill, the reload needs persistence — and the three
solutions interact. Holding the blocks server-side answers all three by
not having the problem.

**Consequences.** Never introduce client-only conversation state; this is
the rule the theme cookie had to be argued *against* (`D_theme_cookie`)
rather than quietly excepted from. Blocks are stored rendered, so a
change to how a block renders does not retroactively re-render history.

## D_single_shared_conversation — One *live* agent, one transcript, loopback by default

**Status:** Accepted, shipped; narrowed when a sidebar of stored
conversations shipped. "One conversation" now means one **live**
conversation — the browser can switch which stored conversation that is,
and every tab follows, because there is still exactly one agent and one
transcript.

**Selection clause repealed and shipped.** Viewing is now a
per-tab, per-URL concern (`GET /c/:id`), rows are links, and sending into
a conversation the agent is not on is what makes it live — carrying the
mid-turn refusal that `POST /conversations/:id/select`, now gone, used to
carry. A conversation the agent is not on is replayed from history per
request (`HistoryReplay.snapshot`). SSE remains one undivided feed, so
every frame is stamped with the live conversation's id and the client
drops what is not its own; per-conversation subscriptions arrive with the
agent-per-conversation work. The paragraphs below are kept for the
reasoning, not as current behaviour.

**Superseded in direction, still accurate as shipped.** The
single-user, no-auth, loopback half stands and is now settled rather than
provisional: a second person runs their own process under their own OS
account. What is repealed is the **selection** clause below — that which
conversation a tab views is server state announced to every tab. It is
view state belonging to the tab, and it goes in the URL. The rejection
paragraph is where the error actually sits: it treats a per-tab *view* and
a per-user *session* as the same thing, and Slack is the refutation —
channel selection lives in its URL, the session exists only for auth. The
premise the clause reasons from ("one live agent") is itself scheduled for
replacement by one agent per conversation. Direction, staging and the
hazards it opens: `ideas/per-conversation-agents.md`. Nothing here has
changed in code yet; amend this entry, don't trust it as intent.

**Context.** A web front-end invites the assumption that it is
multi-user. This one is the TUI's single-conversation model rendered in a
browser, and its second "user" is a second tab on the same machine.

**Decision.** One agent, one transcript, in-process. No sessions, no
auth. `--bind` defaults to `127.0.0.1`; anything else is the operator's
risk and is documented as such. Selecting a conversation is therefore
*server* state, changed by a POST and announced to every tab, not a
per-URL view: one live agent showing two panes where only one accepts
input would be confusing in exactly the situation it enabled. Per-URL
`/c/<id>` is where this goes if background turns ever make the other
pane genuinely alive.

**Rejected: per-session conversations.** Not a patch — {AgentRunner} owns
*the* worker thread and {Transcript} owns *the* block list, so sessions
mean rewriting who owns what, and {Broadcaster}'s fan-out stops being a
broadcast. Out of scope until there's a concrete need.

**Rejected: shipping auth to make a non-loopback bind safe.** Auth
without per-session conversations protects an inbox everyone shares; it
would look like multi-user support while delivering none of it.

## D_no_js_build_step — No bundler and no dependencies; JS is mechanics, never a renderer

**Status:** Accepted, shipped; amended twice since — the size budget is
gone and the test that replaces it is sharper, and how the client source
is partitioned moved to `D_feature_owns_its_file`.

**Context.** The page needs an `EventSource`, form wiring, and a way to
place incoming fragments. That is the entire client-side job, because
Markdown rendering happens server-side in kramdown.

**Decision.** No npm, no bundler, no build step, no dependency. What
JavaScript is *for* here:

- **transport** — the `EventSource`, the `fetch` calls;
- **platform mechanics only exposed to script** — `showModal()`, `inert`,
  `scrollTop`, textarea measurement, `matchMedia`;
- **per-browser state that must never reach the server** — theme, draft,
  scroll position, which palette row is highlighted (`D_no_event_queue`).

And what it is never: a **renderer**. Markup or conversation content the
server could have produced is the server's, always. That clause is not new
— it is what `D_server_authoritative_transcript` and `D_replay_from_history`
have been resting on all along.

**Which file a function belongs in is not this entry's business** —
`D_feature_owns_its_file` owns that. The one clause of it this decision
cares about is `public/js/dom.js`'s: it knows no markup at all, because a
renderer is exactly what that file must never quietly become.

**The qualifier: rendering and state, not latency.** Read absolutely, "if the
server can do it, the server must" argues for fetching the slash palette's
filtered rows on every keystroke — the server certainly *can*. The filter,
the theme flip and the composer's auto-grow stay local because a round trip
would make them feel wrong, not because the server could not do them. The
rule governs where *rendering and state* live; it does not govern the
interaction loop.

**Rejected: a framework and a bundler** (or even a single npm
dependency). It would add a toolchain, a lockfile, a `node_modules` and a
build step to a project whose client-side job is a few hundred lines of
mechanics — and the toolchain, not those lines, is what would then need
maintaining. ES modules are the standing proof this costs nothing: `app.js`
imports `dom.js` with the browser resolving it, no bundler in sight.

**Consequences.** This is a live constraint on future work, not a
starting condition: if a change appears to need an npm package, the
answer is to render it on the server instead. It is also what keeps
`--dev` cheap (`D_dev_flag_no_reload`) — there is nothing to rebuild.
