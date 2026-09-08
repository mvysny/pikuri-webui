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

## D_upstream_request_throttle — pikuri rations the server; this shell only sizes the pool

**Status:** Accepted, shipped. **Supersedes `D_throttle_at_the_request`**,
whose {ThrottledAdapter} this deletes. `--turns N` is now
`Pikuri::Agent::ServerPermits.limit(server, N)`, called once per distinct
server at boot from `ModelCatalog#servers`; the turn executor is still
`N * 2` and still not a load cap.

**Context.** `D_throttle_at_the_request` shipped a Faraday adapter as an
explicit stopgap and named its own retirement condition: the principled home
for a throttle is a control on the agent loop, that home is pikuri's, and
"when it lands, this entry is superseded and {ThrottledAdapter} retires". It
landed — `Agent::ServerPermits` (a process-wide per-server permit registry)
plus `Agent::RequestThrottle` (the acquire site, in ruby_llm's `instrumenter`
slot on the agent's own `RubyLLM::Context`). See `../pikuri/DECISIONS.md`
`D_llm_request_throttle` for the upstream argument and its measurements.

**Decision.** Delete the adapter and take upstream's. Sizing is all this
shell does, and it does it explicitly.

Upstream keeps the two properties the adapter was kept for: the permit's
scope is exactly one HTTP request (so a parent cannot deadlock against the
sub-agent its tool spawns), and it spans the whole streamed response. It
also fixes the two things the adapter could not:

- **The wait is cancellable.** `ServerPermits::Semaphore#take` polls a
  `Control::Cancellable` on `SLICE_SECONDS`, so ■ lands on a turn parked in
  the queue instead of after the server finally answers it. That is
  precisely the consequence `D_throttle_at_the_request` logged as accepted
  and unfixable from an adapter.
- **The key is normalized.** `http://x:8080`, `.../v1` and `.../v1/` are one
  server, so two `[[llm]]` entries written differently share a pool instead
  of silently getting one each. Our own pool keyed on the raw `api_base`.

**Why size explicitly, when pikuri auto-sizes.** The `/props` probe pikuri
already runs for the context cap now also reports `total_slots` and seeds
the permit count from it, so a zero-config local llama.cpp throttles
correctly. This shell still calls `.limit`, because a `[[llm]]` entry
carrying an explicit `context_window` **skips that probe altogether** — its
server would go unsized, and unsized means unlimited. `--turns` is
documented as the operator's word about their own server; an entry that
opts out of the probe must not silently opt out of the throttle.

**Rejected: `ServerPermits.default` rather than `.limit`.** First-writer-wins
rather than authoritative. Boot runs before any probe so it would win in
practice today, which is exactly the fragility — the flag would be
outranking the probe by timing rather than by decision.

**Rejected: dropping `--turns` and trusting auto-sizing alone.** Loses the
`context_window` case above, and the flag is a documented promise in
`README.md`.

**Rejected: keeping {ThrottledAdapter} underneath as a belt.** Two throttles
in series at N permits each gates nothing the outer one doesn't, and the
adapter's `/chat/completions` path test is a narrower net than the
instrumenter's.

**Consequences.**

- **This reverses `D_throttle_at_the_request`'s "rejected: a process-global
  registry keyed by server URL".** That rejection was `D_global_monitor`'s
  rule — process-global mutable state either joins the domain or argues for
  its own lock — and the adapter dodged it with a subclass. The registry now
  arrives with its own `Mutex`, from a library whose thread-safety is its
  own contract, and it is touched only from the turn worker inside
  `run_loop`, never from a {BigAppLock} task. The rule is satisfied the way
  {Broadcaster} satisfies it, not waived.
- **The `faraday_adapter` seam stops being load-bearing in production**,
  back to `Pikuri::Testing`'s use of it alone.
- `:queued` still means two things, both honest: no executor thread, or no
  permit. The status bar does not distinguish them.
- A retried request holds its permit across ruby_llm's backoff, idling the
  slot for a moment — upstream's deliberate trade, so a re-enqueued request
  cannot pile in behind an original that is still generating.
- Sizing is per *server*, so `ModelCatalog#servers` exists to dedupe the
  `[[llm]]` list down to boxes. Everything else about a connection is still
  per entry.

## D_path_deps_on_pikuri_master — Back to `path: '../pikuri'`, for a surface that is not released

**Status:** Accepted, shipped. **Supersedes `D_released_pikuri_gems`**,
whose one-minor pin this removes; the CI clone step comes back with it.

**Context.** `D_upstream_request_throttle` needs `Agent::ServerPermits`,
which exists only on pikuri master — nothing on the 0.1 line has it. The pin
`D_released_pikuri_gems` argued for was sound and is simply out of date: it
rested on "pikuri 0.1.0 ships everything this shell needs", which stopped
being true the moment the throttle landed upstream instead of here.

**Decision.** `gem 'pikuri-core', path: '../pikuri'` and the same for
`pikuri-pdf`, both on the sibling checkout; `.woodpecker.yml` clones it at
depth 1 before bundling. Upgrades are whatever master says, verified by
`rake check`.

**Rejected: waiting for pikuri 0.2.0.** The honest version of "wait" is
"block this change on a release cut to unblock it", between two repos with
one author. Master is what this shell validates against in any case.

**Rejected: a per-machine `bundle config local.pikuri-core` with the Gemfile
still pinned** — `D_released_pikuri_gems`' own suggestion, read in reverse.
It works for a *convenience* (editing both repos together); it does not work
for a dependency the committed code requires, because the committed Gemfile
would then describe a build that cannot run and both a fresh clone and CI
would fail.

**Rejected: vendoring `ServerPermits` / `RequestThrottle` into `lib/`.** A
third copy of a throttle, in the one area `AGENTS.md`'s reuse rule reserves
for pikuri.

**Consequences.**

- CI clones `../pikuri` again, and `Gemfile.lock` carries no checksum for
  the two gems that matter most. Both are what the pin bought; both are back
  on the bill.
- **Master can break this shell on any `bundle install`.** `rake check` is
  what catches it and pikuri's `CHANGELOG.md` `**Breaking:**` entries carry
  the migration — which is how this change also paid for master's tool-event
  reshape (`D_both_forms_in_the_block`'s consequences) and the step-limit
  removal.
- **Revisit at the next pikuri release.** Nothing here argues against a pin
  in principle, so when a release carries this surface, going back to
  `D_released_pikuri_gems`' shape is a one-line change and a good one.

## D_throttle_at_the_request — The server's slots are rationed per completion, by a Faraday adapter, not by the turn pool

**Status:** **Superseded by `D_upstream_request_throttle`.** Held while
pikuri had no throttle of its own; pikuri master shipped one, and
{ThrottledAdapter} is deleted. The reasoning below is why this shell built
its own in the meantime, and which properties the replacement had to keep.

**Context.** `--turns` was the executor's pool size, and a turn holds its
thread across the whole `run_loop` — tool execution included. So a turn off
running a `web_search` for five seconds kept the slot while the inference
server sat idle, and at the default of 1 nothing else in the process could
talk to it. The cap was a proxy for "requests the server is handling", and
the proxy leaked exactly when a tool ran.

**Decision.** Ration the thing being contended: hold a permit for the
length of one HTTP completion request and give it back. `--turns` keeps its
documented meaning — match it to llama.cpp's `--parallel` — and becomes
literally true instead of approximately.

The pool is keyed on `api_base`, **not** on the `[[llm]]` entry: two entries
running different models on one box share that box's slots, because the
slots belong to the server. Two servers get two pools.

The executor is sized `2N` so a turn blocked in a tool has somewhere to
wait without occupying a permit — that is the whole point, and at `1N` the
change would buy nothing. Bounded rather than unbounded so a runaway cannot
spawn threads without limit; a larger factor is harmless and buys nothing.

**Measured** against a local llama.cpp, four identical completions:

| permits | total | completions land at |
|---|---|---|
| 1 | 46.6 s | 11.6, 23.2, 34.9, 46.6 s |
| 4 | 26.0 s | 25.9, 26.0, 26.0, 26.0 s |

Evenly staggered at 1 (serialized), simultaneous at 4.

**Why a Faraday adapter and not `Pikuri::Agent`.** The agent loop is
pikuri's (`AGENTS.md`, the reuse rule), so the principled home for a
throttle is a control on the loop — and that remains the better long-term
answer: pikuri's own `Agent` yardoc invites hosts to run several agents on
one thread each, and offers them nothing to keep those agents off one
server's throat. Filed there as `ideas/llm-request-throttle.md`; when it
lands, this entry is superseded and {ThrottledAdapter} retires. Rejected
*for now* on two grounds: it blocks on a pikuri release against the
one-minor pin (`D_released_pikuri_gems`), and the adapter turns out to have
a property the upstream version would have to be careful to keep.

**That property: an adapter cannot get the scope wrong.** A permit must
cover exactly one completion. Widen it to a step or a whole `run_loop` and a
parent holding the only permit deadlocks against a sub-agent waiting for
one — the synthesizer runs from the `StepLimit::Exceeded` rescue, and
sub-agent tools run between completions, so both are *outside* the
completion and would wait forever. In an adapter there is nowhere to hoist
the acquire to: the scope is one HTTP request, and a nested agent's request
is a separate `#call` made after the parent's returned. The invariant that
would need a regression test upstream is structural here.

**Verified: the permit spans a streamed response.** The design would be
worthless if `#call` returned at the first byte and the tokens arrived
afterwards, since the permit would be released while the server was still
generating. It does not — ruby_llm streams through Faraday's `on_data`,
which net_http drives from inside the request. Measured on a 150-line
streamed completion: the adapter spanned 33.69 s, `run_loop` totalled
33.69 s, and all 491 delta events landed inside the adapter's window. A
transport that ever streamed some other way would silently break this.

**Rejected: a constructor argument for the semaphore.** The obvious shape,
and unreachable. Faraday would allow it — `RackBuilder::Handler#build` is
`klass.new(app, *args, **kwargs)` — but nothing between here and there
passes any: ruby_llm builds the adapter as `faraday.adapter(adapter)`, and
pikuri's seam (`ChatTransport#faraday_adapter` → `config.faraday_adapter=`)
carries a single value. The class object is the only per-server thing that
reaches the instance, so `.with_permits` returns a subclass holding the
pool in a class-level ivar.

**Rejected: a process-global registry keyed by server URL.** Would let one
named class serve every server and read nicer in a backtrace. Not done: it
is process-global mutable state, which `D_global_monitor` says must either
join the domain or argue for its own lock — and this one cannot join the
domain, because a task may not block and acquiring a permit is precisely
blocking. A subclass per server has no global state to argue about.

**Rejected: making the executor unbounded instead.** Removes the
head-of-line problem without a throttle, but then nothing caps requests to
the server at all, which is the one thing the number was for.

**Consequences.**

- **Waiting is not interruptible and the queue is not FIFO.**
  `Concurrent::Semaphore` promises no fairness. Accepted: cancellation is a
  tool-boundary stop that does not reach a completion today either, and
  starvation across a few conversations on one desktop is not a real risk.
  An upstream `Control::Throttle` could fix both, which is the remaining
  argument for building it.
- **Only `/chat/completions` pays a permit.** Anything else on the
  connection passes through — the contended resource is the model's
  generation slot, not the socket. `ContextWindowDetector`'s `/props` probe
  builds its own connection and never sees the adapter.
- **`:queued` now means two things**, both honest: no executor thread, or
  no permit. The status bar does not distinguish them and does not need to.
- The `faraday_adapter` seam is now load-bearing in production, not just in
  `Pikuri::Testing`. A pikuri release that narrowed it would break this.

## D_both_forms_in_the_block — A tool block carries the short line and the raw one both, and CSS picks

**Status:** Accepted, shipped. {ToolLine} renders both,
`:root[data-tools]` shows one, `/toollines` writes the cookie.

**Context.** pikuri-tui shortens tool lines to
`WebSearch(rails 8 credentials)` / `OK, 4.2 kB` and keeps the raw form a
keypress away — its `D_verbose_toggle` for the reachability argument,
`D_kinded_regions` for the machinery: a register of kinded blocks plus
`#rerender(kind:)` redraws every tool line on a flip, because a terminal
block is text that has to be recomputed. This shell rendered the verbose
form only.

**Decision.** {ToolLine} renders **both** forms into every tool block —
two spans, `tool-short` and `tool-verbose` — and
`:root[data-tools='short'|'verbose']` shows one. The flip is one
attribute write plus a cookie: nothing re-renders, the server holds no
display preference, and a tab that flips disturbs no other tab.

**Rejected: `O_verbose_in_a_details`** — the short line as a
`<summary>`, the raw dump as the body. Tempting to the point of being the
obvious move, because `D_details_per_block` had just shipped the whole
mechanism, `data-disclosure` included. Three reasons it loses, and the
first is the one a future reader would not reconstruct: that entry
shipped with `:thinking` is the **only** kind that gets a disclosure, on
the argument that a disclosure is an inviting pattern to reach for — this
is exactly the reach it was written to stop, and reaching would leave the
rule meaning nothing. Then: the pair is *two* blocks, so a disclosure on
the call cannot carry the result's form and the mode would ship anyway;
and `transcript.js` would have to grow past its `.block.thinking`
selectors, which is markup knowledge in JS (`D_no_js_build_step`). The
deeper mismatch is that verbose is not *more detail about the same
thing*, which is what progressive disclosure is for — it is a second
rendering of identical data, and a mode is what a debugging session
wants.

**Rejected: `O_server_mode`** — the server holds one mode and re-renders
tool blocks on a flip. A display preference in server state, shared
across tabs; the objection `D_details_per_block` already makes to a
server-side visibility gate.

**Rejected: `O_mode_at_render_time`** — pick a form as the block is
created, no toggle. The one option that cannot be changed later without
touching the transcript, and it leaves the raw form reachable only
through git.

**Rejected: one `/view` dialog holding both view settings** (the TUI's
`u` submenu). Passed over for `/thinking` already: two independent live
toggles in a dialog that must not close on a click is a widget this app
does not have.

**Rejected: a drawer-footer button beside `#theme-toggle`.** Three
toggles there is a settings bar, and the drawer is about conversations.

**Consequences.**

- **The default look changes**, verbose → short: `Config#tool_lines`
  already resolved to `:short` with nothing reading it, and honouring the
  shared file means honouring that. Said out loud in `README.md` rather
  than left to be discovered.
- **The short form is the tool's, not ours.** It shipped as a guess —
  `CamelCase(first argument)` over the call, a measurement or the whole
  string over the result — because the event carried nothing better. It now
  arrives on the event: pikuri's `Tool#display_name` / `#describe_call` /
  `Result#summary`, composed where the structure still exists
  (`../pikuri/DECISIONS.md` `D_tool_summary_lines`), which retired both
  guesses and the divergence from pikuri-tui the first version of this entry
  argued for — a calculator's `4` reads as `4` because pikuri's calculator
  says so, not because {ToolLine} measures its length. What is left here is
  what only a renderer can do: defang the strings, and cap them to a width
  it alone knows.
- **Both forms sanitize, with no `inspect` carve-out** — the TUI exempts
  its verbose argument dump on the grounds that `inspect` escapes what
  matters, which is true of the terminal threat only: measured against
  Ruby, `inspect` passes bidi overrides, zero-width characters and
  homoglyphs straight through, and escapes exactly the `ESC` that
  HTML-escaping already renders inert. {ToolLine}'s header holds the
  order the two passes run in.
- **`transcript.js` is untouched**, unlike Part 1 — no walk, no override,
  no mount-time resolve, because both forms are already in the DOM. The
  whole client side is one attribute write in `app.js`.
- The third presentational cookie, and the **second** of `D_theme_cookie`'s
  config-backed shape. One wrinkle `thinking` did not have: `show_thinking`
  is a boolean and cannot be nonsense, while `Config.validate_ui!` checks
  `tool_lines`'s shape and not its vocabulary, so `App.default_tool_lines`
  is the only thing between a typo in the shared file and a page showing
  both forms at once.
- The command is `/toollines`, not `/tools`; {SlashCommand}`::CATALOG`
  holds why.
- **v2 retires half of {ToolLine}**: when pikuri's `ToolCall` carries
  `display_name:` / `argument:` and `ToolResult` a `summary:`, the
  CamelCase helper, the first-value pick and the `Error:` heuristic go,
  and no pixel changes but the result line's wording. The v1 look was
  chosen for that.

## D_details_per_block — Reasoning gets a disclosure per block; the config sets its default, not its visibility

**Status:** Accepted, shipped. `SseListener#disclose` wraps a
`:thinking` block, `style.css` styles the row, `transcript.js` resolves
it, `/thinking` picks the default.

**Context.** pikuri-tui hides reasoning behind one flag: `[ui]
show_thinking` sets the starting value and a toggle flips the whole pane,
drawing *nothing* where a hidden block was (its `D_no_hidden_marker` —
grey filler earns nothing, and a terminal has no cheap per-block
affordance). Porting that shape was the obvious move.

**Decision.** Each `:thinking` block renders as its own
`<details open><summary>thinking</summary>`, and the preference sets
whether blocks start **open or closed** — never whether they exist. The
collapsed row is both the "reasoning happened here" signal and the way
in: short feedback that thinking occurred, subtle enough not to disturb
the conversation.

**So pikuri-tui's `D_no_hidden_marker` inverts here, on its own argument.** The TUI
rejected a marker because a line you cannot click is filler. A browser
makes that same row clickable, which turns it from filler into the
affordance — it pays for its line twice. The preference also keeps one
meaning in both shells ("do I want reasoning by default"), expressed as
each chrome can afford: the TUI omits, the browser collapses.

`:thinking` is the **only** kind that gets one. A notice behind a
triangle is a notice nobody reads, and a disclosure is an inviting
pattern to reach for.

**Rejected: the straight port — one hide/show flip, no marker.** One CSS
rule, and it throws away the affordance the terminal lacked. "That answer
looks wrong, show me *that* step's reasoning" is the case that matters,
and a global switch cannot express it.

**Rejected: a server-side visibility gate** (the shape pikuri-tui's
`D_kinded_regions` register serves). It would put a display preference in
server state, which is per-browser by decision — two tabs with different
preferences would fight over one transcript. The TUI needed that register
because a hidden region's text had to be *recomputed*; every block here is
already complete HTML in the DOM, so none of the machinery has an
equivalent and {Transcript} gained nothing.

**Rejected: dropping `ThinkingDelta` while collapsed**, the TUI's
pikuri-tui's `D_drop_deltas_while_hidden`. The server cannot drop a delta for one tab
and keep it for another without a per-connection filter, and
`D_server_authoritative_transcript` says the transcript is one picture.
The TUI dropped deltas to avoid *rendering* work on a hidden pane; the
cost here is SSE bytes on localhost. **The server always renders and
always broadcasts; the browser decides what it shows** — which is also
strictly better than the TUI, where a cancel mid-thinking while hidden
left only what had streamed revealable. Nothing is ever lost here.

**Rejected: brightening an open block's `<summary>`.** Tried, and
reverted after looking at it: the label then competes with the assistant
prose beneath it, inverting the hierarchy the muted reasoning tone exists
to establish. The rotated marker already says which state the block is
in.

**Consequences.**

- `open` is in the markup unconditionally, and that is not a default
  masquerading as one: the listener is per-*conversation* and shared by
  every tab reading it, while collapsing is per-*browser*, so it renders
  the pre-JS state and `transcript.js` resolves it. Expanded is the state
  chosen for it so the default configuration never flashes, and so a
  browser running no script still shows everything.
- **The runtime toggle is collapse-all / expand-all**, not
  default-for-future-blocks-only: `/thinking` drops every per-block
  override and moves the whole transcript. The alternative leaves the
  transcript in a mixed state nobody chose and stops the command feeling
  like a density control.
- **Nothing touches the scroll**, deliberately. Every disclosure change
  moves the document height — a global toggle by a lot — so a pinned pane
  can unpin and a scrolled-up reader's view can shift; tuile gave the TUI
  this free via `set_region_text`'s clamping. No equivalent was built
  because the right feel differs per case: yanking the view to the bottom
  after a deliberate click is plausibly worse than leaving it, and
  guessing means feel-code no spec can justify. Revisit if the pane stops
  following a stream while pinned, or a collapse leaves the reader
  staring at whitespace.
- The block-kind contract is **two** places for a change like this, not
  the three `AGENTS.md` names: a kind's markup travels inside the html
  payload, and `index.erb` and `transcript.js` wrap that payload in an
  identical div. Only the listener and `style.css` moved.

## D_disclosure_state_on_the_block_div — Which reasoning blocks are open lives on the block div, outside the html the server rewrites

**Status:** Accepted, shipped in `transcript.js` alongside
`D_details_per_block`.

**Context.** `upsert` replaces a block's `innerHTML` on every streaming
delta (`D_rerender_and_replace`), and pikuri coalesces those at 15 fps.
A `<details>` inside that payload is therefore destroyed and rebuilt
about every 67 ms while reasoning streams.

**Decision.** The open state lives as `data-disclosure` on the **block
div** — which `upsert` reuses and never rebuilds — and an *absent*
attribute means "follow the default". `transcript.js` re-applies it to
the freshly-written `<details>` after each rewrite.

This is required rather than an optimization, because a collapsed
default puts the likeliest first action straight on the broken path: the
user sees `▸ thinking`, clicks to peek mid-turn, and the next delta would
slam it shut. Open-by-default has the mirror problem, where only
*collapsing* fights the rewrite.

**The trap, which is why this is written down.** `el.innerHTML = html`
looks like it can carry the state, and moving the attribute inside the
payload leaves everything working *except* mid-turn expansion — a case no
spec in this repo can catch, since there is no JS runtime here
(`D_no_js_build_step`). Verified instead in a real browser against the
real module: a click survived 19 consecutive rewrites, in both
directions, with a no-override sibling still following the default.

**Rejected: replacing only an inner `.thinking-body`** so the
`<details>` is never rebuilt. It works, and it requires the script to
know that `:thinking` blocks have a body slot — markup knowledge in JS,
which is the half of `D_no_js_build_step` that is not negotiable.

**Rejected: a state map keyed by block id.** The stable div already *is*
the map, and a side table would need its own eviction on `#remove` /
`#reset`. State dying with the element is a feature: a reopened
conversation starts fresh.

**Rejected: recording the override from the `toggle` event with a
"programmatic" flag.** `<details>`'s toggle event fires
*asynchronously*, so a flag set around `details.open = …` is already
false when the handler runs. What ships instead writes an override only
when the element disagrees with what the default would have set — true of
a user's click, false of our own write. The event also does not bubble,
hence the capture-phase listener.

**Consequence.** The server-rendered snapshot never passes through
`upsert`, so `transcript.js` also resolves the blocks already in the page
at mount. Without it a collapsed-preference reader watches reasoning they
asked to hide until the SSE catch-up arrives — a whole round trip, not a
frame.

## D_ui_cookie_over_config — A `[ui]` preference is a per-browser cookie over a config default, and that is not the precedence rule the config decision forbids

**Status:** Accepted, shipped as the `thinking` cookie resolved against
`Config#show_thinking` in `GET /c/:id`.

**Context.** `D_schema_complete_config` states it flatly: "anything the
file has a home for comes from the file and nowhere else — no flag, no
`ENV`, no project-local overlay — so there is never a precedence rule
between an override, the file and a conversation's saved model."
`[ui] show_thinking` is a key the file has a home for. A cookie that
outranks it looks exactly like the thing that sentence forbids.

**Decision.** The file supplies the **starting value**; a `/thinking`
pick writes a cookie that outranks it from then on, per browser. The
resolving distinction, and the reason this needed writing down rather
than assuming: **`D_schema_complete_config` governs the server's
configuration** — a connection, a key, a switch the agent runs on. A
density preference is *view state*, which `AGENTS.md` already partitions
to the browser ("each browser owns its own view state"). The file says
what a browser that has never expressed a preference sees; nothing about
the agent changes, and no two sources ever describe one connection.

This is also the shape pikuri-tui's `D_config_default` already has — file
sets the default, the runtime toggle overrides and is never written back
— with the cookie standing in for the TUI's session.

**Rejected: a session cookie** (no `max-age`, dying with the browser
session). It maps *exactly* onto the TUI's never-written-back override
and sidesteps the argument above entirely. Passed over because it would
make this cookie behave differently from the `theme` cookie beside it,
which someone will later "fix" without reading this — and a web app
remembering a display preference across restarts is the less surprising
behaviour.

**Rejected: parsing `[ui]` for schema completeness and ignoring it.** A
`show_thinking = false` honored in the TUI and silently dropped in the
browser is worse than either consistent answer, and it makes the shared
config file a half-truth.

**Rejected: the file as the only source, no runtime pick.** A preference
you cannot change without an editor and a restart is not a density
control.

## D_released_pikuri_gems — Released `pikuri-core` / `pikuri-pdf` from RubyGems, pinned to one minor

**Status:** **Superseded by `D_path_deps_on_pikuri_master`.** Held while
pikuri 0.1.0 shipped everything this shell needed; `Agent::ServerPermits`
did not make that release, and the path dependencies are back. The argument
below is not wrong, only out of date — it is the case to re-make at the next
pikuri release.

**Context.** The path dependencies bought one thing: master's unreleased
surface — the boot-time trifecta report, `Interloper#on_change`,
`Testing.fake_transport`. pikuri 0.1.0 ships all three, so the reason is
spent, and what remains is the bill: a checkout every clone of this repo
must also have at the right tip, a CI step that clones it, and a
lockfile that can name no checksum for the two gems that matter most.

**Decision.** `gem 'pikuri-core', '~> 0.1.0'` and the same for
`pikuri-pdf`. One minor, not one major: pikuri is pre-1.0, where semver
lets 0.2 break what 0.1 promised, so an upgrade is a deliberate edit made
with pikuri's `CHANGELOG.md` open at its `**Breaking:**` entries —
pikuri-tui's HEAD stays the worked example for anything ambiguous.

**Rejected: `~> 0.1`.** Reads like the same pin and is not: it admits
0.2, 0.3 and every break they are allowed to carry, silently, on whatever
day someone runs `bundle update`. Pre-1.0 that is the whole risk surface.

**Rejected: staying on path dependencies for the convenience of editing
pikuri and this shell together.** That is a real workflow and it survives
without the Gemfile: `bundle config local.pikuri-core` or a one-line
uncommitted `path:` override does it per-machine, without every other
clone — and CI — paying for a sibling checkout it does not want. The
committed Gemfile should describe what this shell depends on, not one
developer's desk.

**Rejected: pinning `pikuri-core` alone and letting `pikuri-pdf` float.**
Impossible by construction — pikuri-pdf's gemspec pins
`pikuri-core = <exact version>` — and this is the lockstep
`D_track_pikuri_master` cited as a reason to avoid released gems
altogether. It is not one: the two gems are released together from one
repo, so the constraint costs nothing as long as both lines here move in
the same commit. Never bump one alone.

**Consequences.** CI no longer clones anything, `Gemfile.lock` carries
real checksums for both gems, and a pikuri upgrade is now two edited
version constraints plus `bundle update pikuri-core pikuri-pdf`.

## D_subscribe_then_snapshot — `GET /events` subscribes first and opens with the transcript, so the page-render-to-connect window loses nothing

**Status:** Accepted, shipped in `App#GET /events` + `App#catch_up_frames`
and `Broadcaster#frame`.

**Context.** Loading a conversation takes two requests: `GET /c/:id`
renders the transcript at T1, and the browser opens `GET /events` at T2 —
after HTML parse, module fetch and the EventSource handshake. A block the
agent finalized in between belonged to neither: too late for the rendered
snapshot, too early for the subscription. It was silently, permanently
missing from that tab until a reload.

Found by reading during the `D_no_event_queue` seam audit, not by a
report — which is the point of that entry's argument. The damage was
bounded but real: a streaming block self-heals, because every delta
re-sends the whole accumulated source under one id
(`D_rerender_and_replace`), so only *finalized one-shot* blocks were lost
— `tool_call`, `tool_result`, `thinking`, the assistant bookend,
`notice`, `error`. Losing the tool line out of the middle of a turn you
opened the page to watch.

**Decision. Subscribe first, snapshot second, and let the duplicate
absorb the race.** The route registers with the {Broadcaster}, *then*
reads {Transcript}`#to_a`, then writes that snapshot onto the connection
ahead of the drain loop. A block landing between the two is now delivered
**twice** rather than not at all, and a repeat costs nothing: the browser
upserts blocks by id, and {Transcript#clear} deliberately keeps its id
counter so an id is never reused. A miss is permanent; a repeat is a
no-op. The seam closes on *ordering*, with no lock and no new mechanism.

The catch-up leads with `reset`, because the window can swallow one of
those too — a tab that rendered its page a moment before a `/clear` would
otherwise keep showing blocks the server has forgotten.

**Rejected: a lock shared by the writer and the subscriber**, so that
append-and-broadcast and snapshot-and-subscribe are each atomic. It works
and it is what the seam looks like it needs — but it puts {Transcript}
and {Broadcaster} behind one lock, which `D_no_event_queue` keeps the
broadcaster out of on purpose, and it buys nothing that ordering does not.

**Rejected: sequence numbers plus a replay buffer**, with SSE `id:` fields
and `Last-Event-ID` on reconnect. The real answer for a multi-client
system, and far too much machinery here: a ring buffer per conversation,
a retention policy, and a resume path to get wrong — for a single user on
localhost whose reconnects already reload (`app.js`, `es.reconnected`).

**Rejected: leave it, the reload covers it.** It does not. The reload
covers a *reconnect*; the first connection of every page load has no
reconnect to trigger it, and that is the common path. The reload also
lands right back in this same window.

**Consequences.**

- **SSE now carries a snapshot, not only deltas.**
  `D_server_authoritative_transcript` still holds — the server is still
  the only authority — but "GET renders, SSE deltas" is now "GET renders,
  SSE re-opens with the transcript and then deltas".
- **Every connect re-sends the whole transcript.** One extra pass over a
  conversation that was just rendered into HTML. Acceptable on localhost;
  the refinement, if it ever matters, is for the page to pass its last
  block id and the route to send only the tail — which stays correct under
  the same ordering argument.
- **{Broadcaster#frame} is public**, because the route writes catch-up
  straight onto its own connection and one place still has to own the wire
  format.
- **A conversation nobody has resident gets no catch-up** — there is no
  transcript to send, and `GET /events` deliberately does not mint one.

---

## D_feature_owns_its_file — A feature that owns a slice of the page owns a script file, paired with the markup it renders from; `app.js` mounts and wires them

**Status:** Accepted, shipped with `public/js/composer.js`, the first
one, then `public/js/statusbar.js`, `public/js/transcript.js` and
`public/js/conversations.js`. `app.js` is down to the spine, the theme
and the wiring. Whether a fifth file is coming is not a question this
line answers — *Extraction is earned* below is the gate.

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
  there is precedent (`statusbar.say('not sent')`). Shipped as the dialog
  because it can list the known commands and a status line cannot.
  Revisit if it grates.

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
- *The scripts would have to branch.* They reach a dozen elements by id.
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
reader, and `inert` is a DOM property, not a selector. `conversations.js`
owns the toggle for that one attribute's sake, and gets Escape-to-close
with it.
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
  `conversations.js`'s `matchMedia`, which closes the drawer when the
  layout changes so `inert` cannot strand a chat column nothing covers.
  They must move together.
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

**Status:** Superseded in part (2026-08-31) by `D_global_monitor`, which
answers the *Reopened* question at the foot of this entry: one global
re-entrant monitor, work as run-to-completion tasks. The accepted core
below stands — the partition, browser-owned view state, the Broadcaster
as an independent sink — but the per-object locks this entry kept have
since been folded into that domain.

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
shared state in Postgres or Redis, the database doing the locking. And in
that sentence the database is not storage, it is the *concurrency
architecture*: decompose ACID and it is this entry's whole subject —
atomicity is the work packet, isolation is the untorn cross-object read,
serializability is the total order. A Rails app has had an owner queue all
along, spelled `BEGIN` / `COMMIT`. Sinatra offers no opinion because the
opinion was always downstream of it; remove the database and a thread pool
is the entire remaining concurrency model. A live
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

**Amended: the case that reopens this is *reproducibility*, and a
defect-shaped trigger could never have caught it.** Found by inspection:
{AgentRunner#claim_running} moved a turn from `:queued` to `:running`
without broadcasting, so a turn that really waited for an executor slot
left the status bar reading "waiting for a free slot" until it ended.
It survived because `#submit` broadcasts *after* posting the job and the
pool thread usually wins the race to set `:running` first — the frame is
right by luck. A lucky race making the system *usually* work is worse
than one that always fails: what it hides is unreportable ("sometimes the
status bar doesn't move") and, being a statement-level interleaving,
unreproducible on demand. Fixed by broadcasting on both of
`#claim_running`'s paths.

That is a better argument than the hygiene case rejected above, and a
different one. The value of one global queue is not that it serializes
but that it makes a **work packet atomic**: the system is only ever
observed *between* packets, never inside one. It does not buy determinism
— whether a submit lands before or after a turn ends is genuine external
concurrency, and both orders stay reachable — but it shrinks the
reachable set from arbitrary interleavings of *statements* to arbitrary
orderings of *actions*, and an action ordering is finite, enumerable and
writable as a test. This suite can already pin one interleaving, with a
gate job holding the executor; what it cannot do is pin one nobody
thought to look for.

**What still holds it off, and neither reason is comfort.** The owner
thread trades a defect class for a *blast radius*. "The owner must never
block" (below) is reviewable in a way that reasoning about interleavings
is not — the action bodies are a small enumerable set — but it is still
discipline nothing enforces, and the realistic breach is not a blocking
call, which review catches. It is head-of-line stalling behind a packet
that merely runs *long*, and two are already in hand: kramdown, which
`D_rerender_and_replace` runs at 15 fps, and {ConversationStore#save} at
turn end. Both sit on the agent thread today, where a stall costs one
conversation; behind an owner they cost every conversation at once. But
the cost is blast radius only, *not* diagnosis — and that asymmetry cuts
the other way from the paragraph above. A stall is a stable state holding
its own evidence: one dump of `Thread.list` backtraces names the packet
and the line. The race consumes its evidence instead, leaving a system
that has already moved on to a state that looks correct. A freeze you can
read; a lost frame you cannot.

And the seams turned out to want four different
tools. The audit that followed this entry found five and closed three
without a global mechanism: one by putting the broadcast where the
transition is, one by *ordering* (`D_subscribe_then_snapshot` — a seam
whose halves are two HTTP requests, which no server-side serialization
can reach), one with the monitor {ConversationRegistry} already held.
{Transcript} had already solved a fourth the other way, with an immutable
`Block` snapshot no reader can have rewritten underneath it. What is left
is {AgentRunner#status_data}: composed off unlocked state and handed to a
{Broadcaster} that snapshots subscribers under its lock and pushes
*outside* it, so two threads can compose in one order and push in the
other, leaving the browser holding the older frame. One remaining site is
a site to fix, not an architecture — the audit's tally has since been
resolved and folded into `D_global_monitor`'s consequences.

**If one is ever built, these constraints come from decisions already
made** and would otherwise be rediscovered by hitting them:

- **The owner must never block** — not on I/O, a socket, a lock, or a
  reply from a thread that might be waiting on it.
- **The stall must be dumpable.** Ruby has no `jstack`, so the one
  advantage a freeze has over a race — that it holds still and keeps its
  evidence — is not free: a signal trap printing every `Thread.list`
  backtrace is what turns "it hung" into a five-minute read. Nothing about
  it waits for the owner thread, and the hazards `D_shutdown_on_state_stop`
  names — a parked `/events` drain loop, a graceful stop that never
  finishes — have exactly the same shape.
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

- **The trigger to reopen had to be structural, because a defect-shaped
  one cannot work here** — this architecture is good at *hiding* the
  defects that argue against it, so "wait for a live one" waits forever.
  The trigger was **a second site needing atomicity across two objects**,
  and it fired on the second: {AgentRunner#claim_running}, a state change
  and its notification, and {AgentRunner#status_data}, a read from one
  object and a publish to another. Both found by reading, neither by a
  report. The state-volume triggers never got the chance — more server
  state than the transcript and the resident runners, or a second writer
  to one conversation. Raising `--turns` was never one of them.
- **The snapshot-read design was taken, minus the queue.** {Transcript}'s
  `Block` is a `Data`, so `#update` replaces rather than mutates and a
  caller rendering a snapshot cannot have a block rewritten underneath it.
  That was the one piece of the idea that stood on its own.

**Reopened: the target is atomicity, and the mechanism is open.** The
entry above framed the choice as "owner thread, coarse lock, or per-object
locks" and answered it on cost. The framing was wrong. What a database
gives a Rack app is not storage, it is A and I; this app removed the
database and replaced neither, so its seams hold by timing. The two
defects above are the evidence, and both were found by reading the code —
which is the point, because this architecture cannot *report* them.

**Scoped, because "we need ACID" over-buys.** D is already had:
{ConversationStore} commits by temp-file-and-rename with `meta.json` as
the commit point (`D_no_store_lock`), which is durability enough for a
single-user shell. C is domain invariants, and the partition holds most of
them. I is largely had for the same reason — one writer per conversation
(`D_conversation_owns_agent`). **A is the hole**, and specifically A
across a *seam*: two objects mutated or read as one unit. Anything built
should be sized to that and no larger.

**The mechanism is genuinely open, and no plugin exists.** Rack's contract
is `call(env)` — middleware is request-scoped by construction and has no
purchase on a graph that outlives a request — so there is no Sinatra
answer to adopt. The primitive is already in the bundle: an owner queue is
a `Concurrent::SingleThreadExecutor`, from the gem the `Gemfile` already
justifies for the turn executor. Candidates in ascending cost: an atomic
helper per seam; one global `Monitor`; a true owner thread. Vaadin's
`UI.access()` is the middle one and Tuile is the last, as the entry above
already notes.

**What Node.js does and does not prove.** It proves the abstraction is
ergonomic at scale — a single loop is a design people ship on, not a
compromise forced by the lack of threads. It does *not* prove ACID: Node's
atomic unit is a synchronous run-to-completion, and every `await` is an
interleaving point, which is why read-modify-write races are ordinary Node
bugs. So Node is evidence for the mechanism and evidence that the
never-block constraint above is load-bearing — with one asymmetry that
matters here. Node enforces run-to-completion structurally: you cannot
block, you must `await`, and awaiting visibly yields. A Ruby owner thread
*can* block, silently, at any call. Node gets the discipline from the
language; we would have to get it from review.

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

## D_serial_turn_executor — Turns run on one shared executor, and its size is not a load cap

**Status:** **Superseded in part by `D_upstream_request_throttle`**, then
amended to drop sizing altogether. The executor itself stands: one shared
pool injected into every {AgentRunner}, still the admission gate that
reports `:queued`. Two things below no longer describe the code.

*The pool is unbounded* — `Concurrent::CachedThreadPool`, not
`FixedThreadPool.new(turns * 2)`. `2N` was the compromise between two
wrong answers, and once the permit moved to the request it stopped buying
anything: a turn holds a thread for its whole `run_loop` but a permit only
per HTTP request, so **any** number tied to the server's capacity strands
conversations behind turns that are off in a tool using no slot. Doubling
it just moved the stranding threshold. The bound that matters was already
there and is not a number: a conversation admits one turn at a time, so
turns in flight cannot exceed the conversations opened. Unbounded also
retires a deadlock a bounded pool would hit the day a tool spawns a
sub-agent posting back to the same executor.

*`:queued` is no longer where a turn waits for the server.* It is now the
posting-to-running gap, effectively instant; the wait for a slot is
pikuri's permit, taken inside `run_loop`, and a turn parked on one reports
`:running`. So the status bar can say "thinking" for a turn that is queued
behind another conversation's completion — accepted, because the count that
would fix it (`ServerPermits.for(base).available`) is upstream's and no
event carries it. The paragraph below beginning "The pool size caps
concurrent turns" describes a job this pool no longer has.

Everything here about single-writer safety living in the partition rather
than in the number is untouched, and is what makes an unbounded pool safe
rather than merely convenient.

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
  `conversations.js` exposes one `refresh()` that `reset` and the new
  event share; a future titles or search feature should reuse the same
  signal.
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
- **Amended: the resurrection had a second door, and {AgentRunner#discard!}
  could not reach it.** `discard!` retires the runner that is *already*
  resident when the delete lands. A caller that resolved the conversation a
  moment earlier and opened it *afterwards* minted a fresh runner instead —
  no runner existed for the delete to have retired — and that one came back
  in the sidebar as an unsaved resident, then wrote its folder again at the
  next turn end. Fixed by {ConversationRegistry#open_id}: resolve and open
  are one step under the monitor `#delete` already holds, so either the
  delete finds a runner to refuse or retire, or the open finds nothing to
  resolve. `#open(conversation)` itself is unguarded still, and is now only
  reached by `#create`, holding a conversation it just minted. Found by
  reading during the `D_no_event_queue` seam audit, not by a report.
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
gone on reload: `! cancelled` and run-loop failure blocks, and the
partial assistant text a cancel
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

**Consequences.** The theme was the one piece of per-browser state in the
project, and it is the precedent a future per-browser preference should
follow. A new themed colour means adding it to both palettes *and* both
mappings; nothing outside `style.css` may read a raw colour.

**Amended: it is no longer the only presentational cookie.**
`D_details_per_block` added `thinking`, and it followed this precedent
almost exactly — cookie as the store, resolved server-side into a `:root`
attribute so the first paint is right, app.js rewriting both in place, an
unknown value falling back. The one place it *had* to differ: `thinking`'s
fallback is a **config value** (`[ui] show_thinking`) rather than a
constant, because that key exists in the shared config file and a shell
that ignored it would be lying about honoring the file. So
"presentational cookie" has two shapes — one with a default nobody can
configure, one whose default the file owns — and the difference is
whether pikuri's own config schema has a home for the preference.

`D_both_forms_in_the_block` added the third, `tools`, in the
config-backed shape. It also found the shape's sharp edge: a
config-backed fallback is only as good as the file's validation, and
`[ui] tool_lines` is validated for shape and not for vocabulary, so the
*reader* has to fall back too. A fourth one whose config key carries a
vocabulary owes the same double fallback.

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

**Amended: the schema drifted and broke boot, so strictness is now
asymmetric.** pikuri-tui added a `[ui]` transcript-density table
(`show_thinking`, `tool_lines`); `validate_top!` here still allowed only
`llm` / `search` / `code`, so anyone who set a density preference in the
TUI got `unknown top-level key(s): ui` and *could not start pikuri-web at
all*. Exactly the failure the "Rejected: trimming the schema" paragraph
above forbids — carrying the whole schema is not a one-time act, it is a
standing obligation to whatever the sibling shell adds next.

The fix is not just `ui` in the allow-list, because the naive version
re-breaks on the next key and the TUI's own `[ui]` rdoc already names it
("the conversation pane's `markdown:` flag … the natural third entry").
So validation now splits by *who owns the growth*:

- **Tables this shell consumes** (`[[llm]]`, `[search]`) stay strict —
  unknown keys raise. We own the meaning, so a typo is our error to
  report.
- **Inside a table we merely carry** (`[ui]`), an unknown key is logged
  and ignored. The sibling shell defines the keys and will catch the
  typo; raising here only breaks the shared file.
- **A value whose vocabulary is not ours** (`tool_lines`) is
  shape-checked and passed through unresolved, the way `search.engines`
  already is. A copy of the form list here would reject a legal file the
  day a third form ships. `Config#tool_lines`'s *reader* falls back on a
  form it does not recognize — the pattern `App` already uses for the
  `theme` cookie.

**Consequences.** Top-level strictness is deliberately *kept*: a brand-new
pikuri-tui table still breaks boot here. Loosening it would silently
swallow a typo'd `[serach]` along with the Brave key inside it, and a new
top-level section is a visible feature event far likelier to prompt a
cross-repo sweep than one more key in a table that already exists. So the
standing obligation remains a **procedure**: a config-schema addition in
pikuri-tui is a pikuri-web change. The guard is the `cross-shell schema`
describe in `spec/pikuri_web/config_spec.rb` — the test that existed for
this and missed it, now carrying the `[ui]` case; a pikuri upgrade should
read pikuri-tui's `Shared::Config` allow-list against ours.

## D_track_pikuri_master — Path dependencies on `../pikuri`, not released gems

**Status:** **Superseded by `D_released_pikuri_gems`.** Held while the
surface this shell needed existed only on master; pikuri 0.1.0 released
it, and the path dependencies are gone.

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

**Context.** This project tracks pikuri closely
(`D_path_deps_on_pikuri_master`), and pikuri is pre-1.0, so its surface
moves under this shell by design. What that costs depends
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

## D_puma_thread_dump — Thread dumps come from Puma's own backtrace signal; our threads name themselves

**Status:** Accepted, shipped (2026-08-31).

**Context.** Ruby has no `jstack`: when this server wedges — a `/events`
drain loop parked on a queue nobody pushes, a turn stuck in `run_loop`
against an inference server that stopped answering, a save blocked on a
full disk inside `finish_turn` — there was nothing to look *at*. The
`D_no_event_queue` reopening priced dumpability as the compensation for
the coming serialization domain's blast radius: a race consumes its
evidence, but a stall holds still for a dump. The plan was a
Sidekiq-style `TTIN` handler of our own.

**Decision.** No handler of ours. Puma already traps a backtrace signal
— `SIGPWR` on Linux, `SIGINFO` where that exists — in
`Launcher#setup_signals`, on the exact path Sinatra's embedded `run!`
takes, and dumps every thread's name and backtrace to its stdout
(verified end-to-end against Puma 8.0.2). What we own instead is
*legibility*: every thread we spawn or borrow names itself, because an
anonymous `Thread: TID-2e4` costs the reader a source dive that
`sse-heartbeat` or `turn <conversation-id>` does not.

**Rejected: our own `TTIN` handler** (trap pushes a token to a queue, a
dedicated printer thread writes `Thread.list` backtraces to stderr —
the indirection because Ruby trap context cannot take a mutex). It buys
stderr instead of stdout and printing outside trap context, at the price
of ~15 lines to maintain, one more thread, and a signal with a real
collision: Puma's *cluster* mode traps `TTIN`/`TTOU` for worker scaling,
so the Sidekiq convention is only free while this stays single-mode.
Puma's own handler does run in trap context, but its log path is
mutex-free by inspection — accepted. Dump-on-slow-shutdown was also
considered and dropped: `force_shutdown_after: 5` already backstops, and
on-demand is the tool.

**Consequences.**

- Every thread we create sets `Thread.current.name`, and the turn job
  names its pooled thread `turn <conversation-id>` for the duration
  (`turn-idle` after), so a wedged turn names its conversation. A new
  thread without a name is a review miss.
- The dump lands on stdout (Puma's log stream), not stderr — an accepted
  nick in `D_diagnostics_to_stderr`'s wording, whose point is
  browser-vs-terminal, and both streams reach the terminal.
- README's "When it looks stuck" documents the signal; it is the
  operator-facing half of this entry.

## D_global_monitor — One serialization domain: a global re-entrant monitor, work as run-to-completion tasks

**Status:** Accepted, shipped (2026-08-31). Answers the *Reopened* tail of
`D_no_event_queue`; that entry's accepted core — the partition,
browser-owned view state, the Broadcaster as an independent sink — stands.

**Context.** The reopening named the hole: the partition supplies
isolation (one writer per conversation) but not **atomicity across a
seam** — two objects mutated or read as one unit — so the seams held by
timing, and this architecture cannot *report* a seam that fails (a race
consumes its evidence). The atomicity audit closed what it could; seam 2
(compose a status payload + publish it) stayed open, and every future
seam was a thing to find by reading. The owner called it: one mechanism
internal logic can rely on, instead of an audit per seam.

**Decision.** {BigAppLock}: one process-wide re-entrant `Monitor`; work
enters as **tasks** (`lock.run { }`) that run to completion, so the
system is only ever observed *between* tasks, never inside one. The
reachable state space shrinks from arbitrary interleavings of statements
to orderings of tasks. It does **not** buy determinism — whether a submit
lands before or after a turn ends is genuine external concurrency, and
both orders must stay correct — and it does not replace the executor:
`D_serial_turn_executor`'s pool stays the admission gate, two
conversations still stream concurrently, interleaving at task granularity.

The task inventory:

- **Every route body that touches server state is one task** ({App}): the
  page snapshot is an untorn read (blocks + status + rows from one
  instant), resolve + act is one step, and `/events`' subscribe +
  catch-up share a task.
- **The turn job's bookkeeping brackets are tasks** (claim, take-pending,
  finish including the save); `run_loop` itself — LLM round-trips, tool
  execution — runs off-domain.
- **{SseListener} renders off-domain** (kramdown, escaping, the
  {StreamingMessage} accumulation — the domain owns *mutation*, not
  rendering) **and enters a task per finished block**: store + broadcast
  as one unit, ~15 tiny tasks/s per streaming conversation.
- **The Interloper's `on_change` opens a task** from whichever thread
  caused the change; fired from inside a task it just re-enters.

Guarded classes — {AgentRunner}, {ConversationRegistry}, {Transcript} —
lost their own locks and gained a *caller obligation*: every public
method opens with {BigAppLock#assert!}, so a call from outside a task
raises instead of racing. `OutsideTask` is an `Exception`, not a
`StandardError`, so blanket recovery (`rescue StandardError` around the
turn job and the registry's delete) cannot mask a guarding bug as an
operational failure. That assertion is the enforcement Node gets from its
language and Ruby otherwise lacks; specs drive guarded classes through a
`guard` proxy — the spec-side stand-in for the App's route wrapping.

Outside the domain, deliberately: {Broadcaster} (its own small mutex —
`#close` fires from the stop hook, which must never wait on a wedged
domain, so nothing in that hook enters the monitor); the `/events` drain
loops (parked request threads doing the network); all rendering; the
immutable and stateless classes; pikuri's internals.

The rules a change must keep:

- **Tasks are rapid-fire; a stall is eligible only when rare and
  bounded.** Never network, never a wait on another thread, never
  anything unbounded. *Rare* means once-per-conversation-per-process
  class; *bounded* means a ceiling the deployment guarantees, never
  "usually small". The two sanctioned stalls: the turn-end save (two
  small files, temp-and-rename) and the restore replay — measured at
  ~1.6 ms per markdown-heavy turn (≈100 ms at 50 turns; about half a
  second for a 256k-token history, the practical cap of sensible local
  LLMs, on the hardware local llama already mandates). If the replay ever
  bites, the named fallback: replay off-domain into a *detached*
  transcript on the opener's own request thread, a promise in the
  registry map installed by one task and fulfilled by another; a second
  opener waits on the promise on its own thread, outside the domain.
- **No post-and-wait.** A task never blocks on a Future or a worker's
  result; results return as the worker's own follow-up task —
  `monitor.run` from its thread, no API needed. The code already lives in
  this continuation style (`claim_running` / `finish_turn` are the
  worker's re-entry brackets).
- **The domain is the outermost lock.** A task may call into pikuri
  (`Interloper#pending?`, `Cancellable#cancel!`); pikuri never holds its
  own lock when calling back (`on_change` fires outside the Interloper's).
  Consistent order, no ABBA — re-enumerate when a new pikuri callback
  appears.

**Rejected: costume B, the event loop** (the Active Object pattern — a
`Concurrent::SingleThreadExecutor` owner thread draining a mailbox;
precedents Swing's EDT, Node, Tuile). Same atomicity, same enforcement
(thread identity instead of `mon_owned?`), same dumpability — but every
reading route needs `ask` + timeout + a 503 arm where a monitor task
composes the response inline; a task that posts-and-waits on a task
self-deadlocks, so the `on_change` knot (fires synchronously from inside
submit's inject and re-enters the status broadcast) needs restructuring
where a re-entrant monitor dissolves it, and `ImmediateExecutor` specs
deadlock. Its one real advantage — FIFO across threads — solves a problem
we don't have: per-source order comes from each source being one thread,
and cross-source order is the genuine concurrency neither costume
removes. On deadlock the costumes differ in *shape*, not exposure: B
trades ABBA for self-deadlock; A's ABBA exposure collapses to the one
outermost-lock rule above, against exactly one foreign lock family.

**Rejected: per-seam atomic helpers** — and the audit's own finding cut
that way, which this entry must answer: its five seams wanted four
different tools (ordering, broadcast-at-the-transition, a monitor the
registry already had, an immutable snapshot), none of them global, and
two fixes needed no lock at all. The answer: per-seam fixes are
patch-after-reading — each seam must first be *found*, and this
architecture hides exactly the defects that argue against it, so the
per-seam discipline amounts to "hope the next audit reads the right
function". One run-to-completion domain is something internal logic can
rely on without an audit per seam. Two audit fixes survive regardless:
`D_subscribe_then_snapshot`'s duplicate tolerance (the page render and
the EventSource are still two HTTP requests, which no server mechanism
reaches, though the server-side half now also sits in one task), and
`Transcript::Block` staying a `Data`.

**Consequences.**

- Seam 2 closed structurally: composing a status frame and pushing it
  share a task, so composed order *is* push order. The audit's PROBE 6
  flipped into `agent_runner_spec` as the acceptance test that the tear
  can no longer be produced; the monotonic-sequence-number fallback died
  unimplemented.
- Blast radius, priced: a stall inside a task pauses every conversation
  and every request, not one. Compensations: the rapid-fire rule, and
  `D_puma_thread_dump` — the SIGPWR dump shows the stalled task *with its
  caller's stack*.
- Request threads wait on the monitor with no timeout (Ruby's `Monitor`
  has no timed `enter`). Accepted: Puma's pool absorbs, the dump
  diagnoses; a bounded wait is the thing to add if this ever hurts.
- The stop hook's independence is an invariant: `broadcaster.close` +
  `turn_executor.shutdown` and nothing else — nothing in it may enter the
  domain.
- New shared state joins the domain (guarded + `assert!`) or states the
  reason for its own lock the way {Broadcaster}'s header does.
- The registry's `#open` footgun (audit PROBE 7) was untouched by the
  mechanism — the stale `Conversation` is held *across* tasks — and was
  closed right after it by structure instead: `#open` is private, so every
  caller goes through `#open_id` (re-resolves in its own task) or
  `#create` (opens what it just minted), and PROBE 7's premise is gone.
- The request-to-request seams, which no server-side mechanism reaches,
  stay accepted (they were the audit's known-and-accepted list): a queued
  turn shows the user nothing they sent until the listener runs — the
  in-flight window wants a pending state, distinct from busy;
  double-submit has no server-side guard — the answer is an idempotency
  key on `POST /messages`, and composer.js's optimistic clear covers the
  single-tab mash today; a tab watching a conversation someone else
  deletes keeps showing it, cosmetically; and no SSE frame carries an
  `id:`, so a reconnect replays nothing — app.js reloads on reconnect.
