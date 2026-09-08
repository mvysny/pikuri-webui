# CLAUDE.md

## What this project is

A Sinatra-based web front-end wrapping the
[pikuri](https://codeberg.org/mvysny/pikuri) library — the browser
sibling of [pikuri-tui](../pikuri-tui/). `bin/pikuri-web-chat` binds the
same `Pikuri::Agent` and the same `Pikuri::Tool` set as the TUI's chat
shell; the conversation pane / input field / status bar become a
server-rendered page kept live over one SSE connection.

All LLM transport, tool execution, agent loop control, prompts: that's
all pikuri. We own the web shell only.

## Status

Working against a live llama.cpp server: turns stream, conversations save
and reopen, and a turn keeps running while you read another conversation.

Depends on `pikuri-core` / `pikuri-pdf` **by path**, on the `../pikuri`
sibling checkout at master — this shell needs `Agent::ServerPermits`,
which no release carries. So a clone of this repo needs one of pikuri
beside it (CI clones it), master can break the build on any `bundle
install`, and `bundle exec rake check` is what catches that: pikuri's
`CHANGELOG.md` `**Breaking:**` entries carry the migrations, with
pikuri-tui's HEAD as the worked example for anything ambiguous. Going
back to a released pin is a good change the day a release carries that
surface. See `DECISIONS.md` `D_path_deps_on_pikuri_master`.

## Scope decisions

The invariants — what a change here must not break. The reasoning, and
the alternatives that were rejected, live one entry per slug in
[`DECISIONS.md`](DECISIONS.md), which is deliberately not context-loaded;
`grep '^## D_' DECISIONS.md` is its index.

- **Reuse pikuri as runtime; this project owns the web shell.**
  `Pikuri::Agent` is the loop; `Pikuri::Tool::*` are the tools;
  `Pikuri::Agent::Event` is the stream we render. We add an SSE
  listener, an agent runner, and the routes / templates / static files
  around them. Anything beyond that is a bug or scope creep. (The
  project's premise rather than a fork, so no `D_` entry.)

- **The seam: no `Pikuri::*` type reaches what the browser sees.**
  Pikuri-free: {Web::Transcript}, {Web::Broadcaster}, {Web::StreamingMessage},
  {Util::MarkdownRenderer}, {Conversations::Registry}, {Config}, {Web::App}. Pikuri
  types used freely: `bin/pikuri-web-chat`, {Web::SseListener},
  {Web::TrifectaView}, {Agents::Runner}, {Conversations::HistoryReplay},
  {Agents::ModelCatalog}, {Agents::Titler},
  {Conversations::Store#save}. A title crosses as a
  `String`; {Config} carries an `[[llm]]`'s `params` as a plain `Hash`
  and {Agents::ModelCatalog} is where it rides a `ChatTransport`. The catalog
  crosses as names and `[model, server]` pairs, never a `ChatTransport`.
  {Web::ToolLine} is on neither list: it takes Strings and Hashes and only
  *calls* `Pikuri::Sanitizer`, which is a text function, not a type crossing.
  This is a rule about types, never a folder — see `D_namespaces` for why the
  namespaces are not cut along it. See `D_pikuri_free_core`.

- **Four namespaces cut by what a class does, and service never names
  `Web`.** {Web} produces what the browser sees, {Agents} runs a turn,
  {Conversations} is the conversation set, {Util} knows nothing about this
  app; `Config` and {BigAppLock} stay at the root because neither belongs to
  a half. `Web` may name anything; nothing under `agents/` or
  `conversations/` may name anything under `web/` — a component reaching
  down into a service is the sanctioned shape, the reverse is not. Every
  crossing is injected at `bin/pikuri-web-chat`, so the rule is a grep. A
  renderer summoned from inside the agent loop is the thing this forbids.
  See `D_namespaces`.

- **Deleting a conversation is irreversible, and it stays deleted.**
  `confirm()` then `rm_r`, `meta.json` unlinked first; no undo, no
  tombstone, no retention cap. A delete mid-turn *retires* the runner
  ({Agents::Runner#discard!}, one atomic busy-check-and-claim) before
  removing the folder, so nothing can save the conversation back.
  See `D_delete_no_undo`.

- **Firefox on the desktop, Safari on iPad, Safari on iPhone — greenfield
  only.** No polyfills, no fourth browser; `:has()`, `:focus-within`,
  `dvh`, `inert`, `SubmitEvent#submitter` are fair game. iPads count as
  desktops, so no breakpoint may sit at or above 768px. The iPhone layout
  is unverified on hardware. See `D_target_browsers`.

- **One `index.erb` for the phone and the desktop; the difference is
  placement, so it is CSS's.** `#drawer` *is* the desktop sidebar column,
  restyled to an overlay under `@media (max-width: 40rem)`. No UA
  sniffing, no second shell, no device branch in the scripts. The
  breakpoint is written twice (`style.css`, and `conversations.js`'s
  `matchMedia` keeping `inert` from stranding) and the two move together.
  See `D_one_shell_two_layouts`.

- **The transcript is server-authoritative.** {Web::Transcript} holds the
  rendered blocks; `GET /c/:id` renders the full snapshot, `GET /events`
  re-opens with it, and SSE carries deltas after that. Never introduce
  client-only conversation state.
  See `D_server_authoritative_transcript`.

- **`GET /events` subscribes *before* it snapshots.** The page and the
  EventSource are two requests, and a block finalized between them must
  not fall down the gap. Subscribing first makes the overlap a duplicate
  instead of a miss, and duplicates are free because blocks upsert by id
  and {Web::Transcript#clear} never reuses one. The pair now also shares one
  {BigAppLock} task, but the duplicate tolerance is what covers the
  page-render-to-connect gap, which no server mechanism reaches — keep
  it. See `D_subscribe_then_snapshot`.

- **A saved conversation is `history.json` plus our `meta.json`, and
  nothing else.** Blocks are re-derived by replaying synthesized events
  through {Web::SseListener}, never stored, so old conversations get today's
  renderer. No rendered HTML on disk, no second renderer.
  See `D_replay_from_history`.

- **The threading rule.** The agent loop runs as a job on the shared
  executor — never on a Sinatra request thread — and everything shared
  is touched only inside {BigAppLock} tasks: route bodies, the turn
  job's bookkeeping brackets, {Web::SseListener}'s store-and-broadcast per
  block. Tasks are rapid-fire (no network, no waiting on another thread,
  no post-and-wait; disk only where rare and deployment-bounded), the
  domain is the outermost lock against pikuri's, and guarded classes
  enforce with `assert!`. Rendering, `run_loop` and the SSE drain loops
  stay off-domain. See `D_global_monitor`,
  `D_worker_thread_agent_loop`, `D_serial_turn_executor`.

- **No session concept; the one global mechanism is {BigAppLock}** —
  never a Vaadin-style per-session one. Server state is partitioned per
  conversation and single-writer; each browser owns its own view state;
  atomicity across a seam — two objects mutated or read as one unit —
  comes from the domain's run-to-completion tasks. New shared state
  joins the domain (guarded + `assert!`), or states the reason for its
  own lock the way {Web::Broadcaster} does.
  See `D_global_monitor`, `D_no_event_queue`.

- **Nothing in the exit path may rely on `at_exit` or on Sinatra's INT
  trap** — both run on the far side of Puma's unbounded graceful wait.
  {Web::Broadcaster} is closed from Puma's `:state, :stop` event, and `#close`
  must stay idempotent *and* keep refusing new subscribers.
  See `D_shutdown_on_state_stop`.

- **The browser shows the conversation; diagnostics go to stderr.**
  {Web::SseListener} renders events, never log lines, and `PikuriWeb.logger`
  is never pointed at the {Web::Broadcaster}. A wedge is diagnosed with Puma's
  built-in backtrace signal (`SIGPWR`), never a handler of ours.
  See `D_diagnostics_to_stderr`, `D_puma_thread_dump`.

- **JavaScript is mechanics, never a renderer.** Zero JS dependencies, no
  npm, no bundler, no build step. Script is for transport, platform
  mechanics only it can reach, and per-browser state. Markup or
  conversation content the server could have produced is the server's,
  always. The rule is about rendering and state, *not* latency — the
  palette filter stays local. See `D_no_js_build_step`.

- **A feature that owns a slice of the page owns a script file, paired
  with the markup it renders from** and naming its ids. `app.js` is the
  composition root: the page's spine plus the wiring *between* features.
  Anything crossing a boundary goes through the root, never through
  another feature's DOM. `dom.js` knows no markup at all. Extraction is
  earned. See `D_feature_owns_its_file`.

- **Slash commands: the catalog is the server's, the palette is the
  browser's, and a command never writes to the transcript.**
  {Web::SlashCommand}`::CATALOG` renders whole into `#slash-menu`; what each
  name *does* is the `commands` map `app.js` hands the composer. A
  command's own effect is its only feedback, it runs however it was sent
  (Enter, or ↑ — the phone's Enter), and is never posted as a message.
  Rows activate on `pointerup`, because a tap on iOS never becomes a
  `click`. Dialogs are real `<dialog>`s via `openDialog`, which takes a
  *Node*, never an HTML string. See `D_slash_command_palette`.

- **Streaming is re-render-and-replace.** {Web::StreamingMessage} re-renders
  the whole accumulated source per rate-limited delta; coalescing stays
  in pikuri (15 fps). Deltas preview-only, the bookend finalizes with
  authoritative content, dead after finalize. See `D_rerender_and_replace`.

- **Mid-loop input goes through `Control::Interloper`, and the input
  stays enabled while busy.** {Agents::Runner#submit} starts a turn when
  idle and injects when busy; it never refuses for being busy — the one
  non-answer is a conversation deleted under it. A turn ending with a
  queue starts a bare turn to deliver it, so the count never sits above
  zero over an idle conversation; a cancelled or failed turn leaves the
  queue for the next submit. See `D_interloper_mid_loop_input`.

- **The chat script stays chat-only; new capability means a new script.**
  A disk- or shell-touching tool added to `bin/pikuri-web-chat` breaks a
  trifecta guarantee the README has made. An OS or code shell lands as a
  sibling script with its own tool set and report.
  See `D_chat_only_entry_point`.

- **A conversation owns its agent; a tab owns which one it views — and
  single-user for good.** {Conversations::Registry} holds one {Agents::Runner}
  per conversation opened; which one a tab views lives in the URL, and
  SSE frames are addressed per conversation, so a turn runs on undisturbed
  while you read something else. No sessions, no auth, no accounts.
  `--bind` defaults to 127.0.0.1; anything else is the operator's risk.
  See `D_single_shared_conversation`, `D_conversation_owns_agent`.

- **The server is rationed per *request*, by pikuri — and the config file
  sizes it, not a flag.** A `[[server]]`'s `max_concurrent_requests` is
  `ServerPermits.limit(server.url, n)`, one call per sized server at boot;
  the permit is pikuri's, taken for one HTTP request and given back, so a
  turn off running a tool holds no slot. A server naming no ceiling is left
  to pikuri's `/props` probe — which an explicit `context_window` no longer
  suppresses, so there is nothing left for a flag to cover. Never re-add a
  throttle here, never re-add `--turns`, and never tie the turn executor's
  size to this number in either direction.
  See `D_max_concurrent_requests`, `D_upstream_request_throttle`.

- **Turns run on one shared *unbounded* executor, and its size is not a
  correctness device.** Sending never refuses for load. Single-writer
  safety comes from the partition, so it holds at any size — don't rebuild
  a correctness argument on the number, and don't re-bound the pool to cap
  load: a turn holds a thread for its whole `run_loop` but a permit only
  per request, so any capacity-derived bound strands conversations behind
  turns sitting in a tool. `:queued` is now the posting-to-running gap, not
  a wait for the server; that wait is the permit, and it reads `:running`.
  See `D_serial_turn_executor`.

- **The mascot is the library's; the plate is ours.** `public/images/kuri.svg`
  is a **verbatim** copy of `../pikuri/assets/kuri.svg` (`D_kuri_mascot`)
  — re-copy, never redraw. Every rasterized icon is that drawing on an
  opaque `#1e1f22` plate, generated from the master by `bin/regen-icons`,
  which is where the sizes and the plate colour live. That colour and
  `index.erb`'s `theme-color` are the only raw colours outside
  `style.css`, and are exceptions on the record — don't grow a third.
  See `D_icon_plate`.

- **A conversation's title comes from its opening message, on the
  connection `[titler]` names — and no `[titler]` means no titling.**
  Never a fallback to the primary connection. A fresh conversation is
  titled from the message that starts it, a stored one from the opener in
  the history {Agents::Runner#restore!} has already replayed, at most once
  per runner and never by a sweep. The job runs *beside* the turn on the
  shared executor: no `[titler]`, no usable answer, or a raise anywhere in
  it leaves the start stamp and cannot reach the turn.
  See `D_titler_connection`, `D_lazy_retro_titling`.

- **An `[[llm]]`'s `params` reaches the server verbatim, and the caps on a
  title are load-bearing.** `params` is a passthrough — never a
  `thinking = false` boolean, whose wire spelling differs per provider
  *and* per chat template — handed to pikuri's `ChatTransport#params` at
  `Agents::ModelCatalog.from_llms`, the one place a `Config::Llm` becomes a
  transport, so any connection can declare it. The TOML spelling is our
  contract; what carries it to the wire is pikuri's
  (`D_opaque_request_params` there), and no Faraday adapter of ours is
  ever coming back. A server may accept a parameter and ignore it, so a
  short title is never *assumed* — which is why
  {Agents::Titler}'s word and character caps and its `</think>` strip stay: a
  thinking model has been measured putting ~4000 characters of reasoning
  where a title belongs. `thinking_tokens > 0` is watched for exactly
  that, and is diagnostic only — it never discards a title. A table naming
  `messages`, `tools` or `stream` breaks the turn instead of configuring
  it; that edge is pikuri's documented one, not ours to guard.
  See `D_llm_params_passthrough`, `D_canary_severity`.

- **`[model, api_base]` is not unique, and the first `[[llm]]` declared
  owns it.** The recommended titler is a second entry on one model and one
  server, differing only in `params`, so {Agents::ModelCatalog}'s fold runs over
  `choices.reverse` — `to_h` would hand the pair to the *last* and reopen
  every saved conversation on the titler's connection. Shadowed entries
  stay pickable and listed; what they lose is surviving a reopen, because
  `meta.json` stores the pair and nothing finer. Boot logs which they are.
  See `D_shadowed_identity_pair`, `D_per_conversation_model`.

- **Reasoning is collapsible per block, and never hidden.** Every
  `:thinking` block is its own `<details>`; `[ui] show_thinking` sets
  whether blocks *start* open, never whether they render. `<details>` is
  for `:thinking` alone — a notice behind a triangle is a notice nobody
  reads. Which blocks are open lives in `data-disclosure` on the **block
  div**, outside the html `upsert` rewrites 15×/s, or mid-turn expansion
  breaks silently. `/thinking` is collapse-all/expand-all, and nothing
  touches the scroll.
  See `D_details_per_block`, `D_disclosure_state_on_the_block_div`.

- **A tool block carries the short line and the raw one both; CSS picks.**
  {Web::ToolLine} renders the pair as two spans and `:root[data-tools]` shows
  one, so `/toollines` is an attribute write plus a cookie — never a
  server-held mode, never a form chosen at render time, and never a
  `<details>` (that stays `:thinking`'s alone). Both forms sanitize, the
  argument dump included: the TUI's `inspect` carve-out does not port.
  The short form is the *tool's* — `display_name` / `argument` /
  `summary`, composed upstream and carried on the event; {Web::ToolLine}
  defangs and caps it, and never goes back to guessing one from the name
  and arguments. See `D_both_forms_in_the_block`.

- **Theme is a presentational cookie, not transcript state.** Eleven
  semantic tokens, two palettes, both in `public/style.css`; `GET /`
  renders `data-theme` and app.js rewrites the cookie in place. A new
  themed color means both palettes and both mappings, and nothing outside
  `style.css` reads a raw color. Never repurpose a block kind's color for
  a control. See `D_theme_cookie`.

- **{Conversations::Store} has no lock, and does not need one.** One writer
  per conversation directory, temp-file-and-rename for both files, a
  `#row` that takes `ENOENT` as the answer. `#save` owns the whole commit
  — 0700, `History#save`, then `meta.json` as the commit point — so
  nothing writes beside it. Cross-call sequences (`#find` then `#delete`)
  are deliberately *not* atomic. Don't add a `Monitor` for safety.
  See `D_no_store_lock`.

- **One process per state root — and nothing enforces it, ever.** Two
  processes sharing `conversations/` silently overwrite each other;
  last-writer-wins is accepted, `README.md` warns, no `flock` is coming.
  See `D_no_multi_process_lock`.

- **All state under one folder named after the shell.**
  `~/.local/state/pikuri/pikuri-web-chat/`, derived once in the boot
  script as `state_root`; anything new goes beside `conversations/`,
  never straight into `Pikuri::Paths.state`. See `D_per_shell_state_root`.

- **A conversation's model is `[model, server]` in `meta.json`, minted
  onto the agent by the factory and written back at turn end from the
  agent's own transport.** Never a `name` (renameable), never a model id
  alone (two servers can run one model). Three readers that must not
  collapse: `Conversation#model_at_mint` (disk, at mint — the factory is
  its only reader), {Agents::Runner#model} (intent), `@agent.transport`
  (reality, read only inside {Agents::Runner}). A pick parks in the pending
  slot and lands at the top of the next turn; a switch draws no transcript
  block. See `D_per_conversation_model`.

- **One config file for every pikuri shell, and a connection has exactly
  one source.** {Config} carries the *whole* `~/.config/pikuri/config.toml`
  schema, including sections this host never reads. Anything the file has
  a home for comes from the file and nowhere else — no flag, no `ENV`, no
  project-local overlay, and no built-in default connection either — so
  there is never a precedence rule between an override, the file and a
  conversation's saved model. No file, or a file with no `[[llm]]`, is a
  boot error quoting `Config::EXAMPLE_CONFIG`. Schema-completeness
  is a *standing* obligation, not a one-time port: a config-schema
  addition in pikuri-tui is a pikuri-web change, and strictness is
  asymmetric on purpose — strict inside the tables we consume, permissive
  inside the ones we only carry. The one thing the file does *not* own
  outright is a `[ui]` view preference: there it sets the starting value
  and a per-browser cookie outranks it, because view state is the
  browser's by decision.
  See `D_schema_complete_config`, `D_ui_cookie_over_config`.

- **`--dev` is Sinatra's development mode, not code reloading** — the
  agent, its listener stack and the runner thread are wired once at
  boot. See `D_dev_flag_no_reload`.

## Layout

Per-file rationale lives in each source file's YARD header — this is
the package map. Everything we ship lives under the `PikuriWeb::`
namespace; `lib/pikuri_web.rb` boots Zeitwerk over `lib/pikuri_web/`.

Four namespaces, cut by *what a class produces* rather than by what it
imports, plus the root for what belongs to no half (`D_namespaces`). Each
namespace module file carries its own admission rule; `Web` also carries
the one-way rule — **nothing under `agents/` or `conversations/` may name
anything under `web/`**, and it is greppable because every crossing is an
object injected at `bin/pikuri-web-chat`.

- `lib/pikuri_web.rb` — Zeitwerk loader + eager-load; module-level
  `PikuriWeb.logger`.
- `lib/pikuri_web/version.rb` — `PikuriWeb::VERSION`.
- `lib/pikuri_web/big_app_lock.rb` — `PikuriWeb::BigAppLock`, the
  serialization domain: run-to-completion tasks over one re-entrant
  monitor, `assert!` enforcement. Root: it belongs to no namespace.
- `lib/pikuri_web/config.rb` — `PikuriWeb::Config`, the layered TOML
  loader for `~/.config/pikuri/config.toml`; port of pikuri-tui's
  `Shared::Config`, schema-complete, Pikuri-free. Root: read before
  anything else exists.

`Web` — everything whose output is what the browser sees:

- `lib/pikuri_web/web.rb` — the namespace: the one-way rule, and why "web"
  is not a thread boundary.
- `lib/pikuri_web/web/app.rb` — `Web::App`, the Sinatra app:
  `GET /` (redirects to the newest), `GET /c/:id` (one conversation),
  `GET /events?conversation=` (SSE, per conversation), `POST /messages`,
  `POST /cancel`, `POST /model`, `GET`/`POST /conversations`,
  `POST /conversations/:id/delete`. Every route names the conversation it
  acts on, and every route body is one task. Lock, registry,
  broadcaster and the connection rows injected via class-level settings.
- `lib/pikuri_web/web/sse_listener.rb` — `Web::SseListener`, the
  `Pikuri::Agent::Listener::Base` subclass rendering the event stream
  into the transcript + SSE. The TuileListener equivalent.
- `lib/pikuri_web/web/transcript.rb` — one conversation's rendered blocks,
  server-authoritative; thread-safe.
- `lib/pikuri_web/web/broadcaster.rb` — SSE frame formatting + fan-out,
  addressed per conversation so a turn reaches only the tabs reading it;
  thread-safe.
- `lib/pikuri_web/web/streaming_message.rb` — per-turn delta accumulator
  (append / finalize lifecycle), web descendant of the TUI's
  StreamingMarkdownBuffer.
- `lib/pikuri_web/web/tool_line.rb` — `Web::ToolLine`, one tool event as
  its short and verbose lines plus the two-span markup CSS picks between.
- `lib/pikuri_web/web/trifecta_view.rb` — `Web::TrifectaView`, a walked
  trifecta report as the `/trifecta` dialog's escaped HTML body.
- `lib/pikuri_web/web/slash_command.rb` — `Web::SlashCommand`, name +
  description for one palette row, and the `CATALOG` a page is served a
  config-gated subset of.

`Agents` — running an LLM turn:

- `lib/pikuri_web/agents.rb` — the namespace; why it is plural.
- `lib/pikuri_web/agents/runner.rb` — `Agents::Runner`, one
  conversation's agent, transcript and turn lifecycle: restore, the
  start-vs-inject (Interloper) decision, the pending model, the save at
  turn end, the fire-and-forget title job (on a fresh opener or a replayed
  one); broadcasts status.
- `lib/pikuri_web/agents/titler.rb` — `Agents::Titler`, the opening message
  as a 3–7 word title: a throwaway toolless agent per call, the caps, and
  the reasoning canary.
- `lib/pikuri_web/agents/model_catalog.rb` — `Agents::ModelCatalog`, the
  `[[llm]]` list as transports: name ⇄ `[model, api_base]` ⇄ transport,
  each carrying its entry's `params`.

`Conversations` — the conversation set, saved / resident / replayed:

- `lib/pikuri_web/conversations.rb` — the namespace; why `HistoryReplay` sits
  here rather than in `Agents`.
- `lib/pikuri_web/conversations/store.rb` — `Conversations::Store`,
  the conversations folder: mints ids, owns the whole commit (`#save`
  takes the history and writes both halves), lists what is saved, retitles,
  deletes a folder. Nests the `Conversation` row type.
- `lib/pikuri_web/conversations/registry.rb` — `Conversations::Registry`,
  the resident runners: mints one per conversation opened, deletes, and
  serves the sidebar rows. Pikuri-free.
- `lib/pikuri_web/conversations/history_replay.rb` —
  `Conversations::HistoryReplay`, a saved `Agent::History` back into the
  events that produced it.

`Util` — knows nothing about this app (the admission test is in the
namespace file, and it is meant to fail things):

- `lib/pikuri_web/util.rb` — the namespace and that test.
- `lib/pikuri_web/util/markdown_renderer.rb` — kramdown (GFM) → HTML with
  escaped-text fallback; HTML-escape helper for plain-text blocks.
- `lib/pikuri_web/util/relative_time.rb` — coarse "6 hours ago" for sidebar
  rows; server-rendered, hence stale-tolerant.
- `views/index.erb` — the page shell; server-rendered snapshot. Carries
  the phone's `#topbar` and the `#drawer` wrapper around the sidebar in
  every response — CSS decides which layout shows. Also the slash
  palette's `#slash-menu` and the `<template>`s holding each dialog's
  body.
- `views/_sidebar.erb` — the conversation list; embedded by `index.erb`
  and served alone by `GET /conversations` for in-place refresh. The
  drawer's chrome sits *outside* it, so this stays only the list.
- `public/` — the static root, served at the URL root: scripts under
  `js/`, the mascot and every icon under `images/`. `style.css` and the
  manifest stay at the top because each is the only file of its kind.
- `public/js/app.js` — the composition root: the SSE fan-out, the theme,
  the command dialogs, and every feature's mount.
- `public/js/composer.js` — `initComposer`, everything `#composer` does:
  buffer, auto-grow, slash palette, keyboard, `POST /messages`.
- `public/js/statusbar.js` — `initStatusBar`, `#status-bar` and its ■:
  status frames, `POST /cancel`, and the intended model read back.
- `public/js/transcript.js` — `initTranscript`, `#transcript`: blocks
  upserted by id, dropped, emptied, the stick-to-bottom scroll, and which
  reasoning blocks are open.
- `public/js/conversations.js` — `initConversations`, the list and how a
  phone reaches it: `#sidebar` refresh, delete, mint, and the drawer.
- `public/js/dom.js` — generic DOM mechanics (`openDialog`, `cloneTemplate`,
  `el`) with no app knowledge; imported by `app.js` as an ES module.
- `public/style.css` — hand-written chat layout, two layouts off one
  breakpoint; block kinds mirror the TUI's visual language (muted
  thinking, tool lines in Kuri's coat tan) and own the reasoning
  disclosure row.
- `public/images/kuri.svg` — the mascot, transparent and unplated; master
  artwork every icon beside it is rendered from.
- `public/images/favicon.svg` — the tab icon: Kuri on a plate; the one
  sanctioned copy of the master's geometry, generated.
- `public/images/icon-{32,192,512}.png`, `public/images/icon-maskable-512.png`,
  `public/images/apple-touch-icon.png` — the plated raster set; generated by
  `bin/regen-icons`.
- `public/manifest.webmanifest` — the PWA manifest: name, standalone
  display, the three manifest icons.
- `bin/pikuri-web-chat` — boot script: config load, the model catalog, the
  per-server permit sizing, the conversation factory (agent + tools +
  Interloper + the connection this conversation is minted on, one wiring
  for every conversation), the
  shared turn executor, the serialization domain, the trifecta report,
  Puma start (server settings and the shutdown hook). Flags are only what
  the config file has no home for — `--port` / `--bind` / `--dev`.
- `bin/probe-titler` — runs the eight probe openers (and six attacks) through
  {Agents::Titler} on the configured `[titler]` connection; the corpus a candidate
  model is judged against. Maintainer tool, run by hand.
- `bin/regen-icons` — re-renders every plated icon from `kuri.svg`; holds
  the sizes, the plate colour and the maskable bound. Maintainer tool, run
  by hand, not part of boot or any build.

## Conventions

- Tests: rspec-core `describe`/`it` harness with minitest-style
  assertions (`assert_equal`, `refute`, …) — same as pikuri /
  pikuri-tui. `bundle exec rake check` (also the default task) is the
  cross-repo standard full-check entry point and what CI runs; here it
  wraps the spec suite. `bundle exec rspec spec/...` for a targeted
  run.
- `spec/pikuri_web/` mirrors `lib/pikuri_web/`, namespace folders
  included, so a class and its spec stay one path apart. The specs that
  cross namespaces on purpose — `conversation_flow_spec.rb`,
  `client_contract_spec.rb` — sit at the root of that tree, next to the
  specs for the root classes.
- `spec/pikuri_web/namespaces_spec.rb` enforces `D_namespaces`' one-way
  rule by parsing the service files and refusing any constant belonging
  to `Web`. It reads `PikuriWeb::Web.constants`, so a new `Web` class is
  covered without editing it. Doc comments are exempt by construction —
  it walks an AST, and `Agents::Runner` names its injected collaborators
  by type in `@param` tags.
- Library exceptions are logged, our bugs raise: kramdown failures
  degrade to escaped text, `run_loop` failures log and return the UI
  to idle; but contract violations (double finalize, bad flush mode)
  raise.
- rack-test arrives as host `example.org`; without `set :environment,
  :test` Sinatra 403s it, and a spec asserting *absence* passes vacuously
  against "Host not permitted" — confirm a new probe's no-fix failure by
  stashing the fix.
- Every thread we spawn names itself (`Thread.current.name`), and a
  per-job borrow like the turn executor's names the thread for the job's
  duration — Puma's `SIGPWR` dump is the debugger of last resort and
  reads by name (`D_puma_thread_dump`).
- Block kinds (`:user`, `:assistant`, `:thinking`, `:tool_call`,
  `:tool_result`, `:notice`, `:error`) are the contract between
  Web::SseListener, index.erb and style.css — adding one means touching
  all three. Changing how an *existing* kind renders is only two of
  them: a kind's markup rides inside the html payload, and index.erb and
  transcript.js wrap that payload in the same `div.block.<kind>`, so
  whoever built that payload and style.css are the pair that move
  (`D_details_per_block`) — the listener for most kinds, {Web::ToolLine} for
  the two tool ones.
- Attacker-influenced text that reaches a block as **plain text** goes
  through `Pikuri::Sanitizer` *before* `Util::MarkdownRenderer.escape` —
  escaping stops markup, not a bidi override that reorders a filename or
  a zero-width character hiding in one, and `inspect` covers only the
  `ESC` that escaping already made inert. Today that means the tool
  lines, both forms of them ({Web::ToolLine}). Markdown-rendered prose
  (`:assistant`, `:thinking`) is the known exemption: sanitizing the
  source would mangle the Markdown, and kramdown's output is the block.
  The same rule reaches past blocks to a conversation *title*, which
  `_sidebar.erb` renders as plain text in four places: {Agents::Titler} sanitizes
  where model output becomes a title, so what reaches disk is already
  clean and no renderer has to remember.
- Slash commands are the same shape of contract, in three places:
  {Web::SlashCommand}`::CATALOG` (the palette cannot list what it does not
  hold), the `commands` map `public/js/app.js` hands `composer.js` (the
  catalog cannot run it), and
  a `<template>` in `views/index.erb` for one that opens a dialog. A
  command the config can make pointless is dropped in
  {Web::SlashCommand}`.catalog`, never by a fourth place.

## Ideas & their graduation

Loose ideas live one per file in `ideas/`, named after what the idea
*is*; `ls ideas/` is the index, so no index file. An idea file is a
scratchpad, exempt from this project's doc quality rules, because it is
going to be deleted. Details — including the same-stem sidecar folder
for an idea that grows research — are in the `ideas-folder` skill.

**An idea graduates the moment it is acted on, and graduation is not
done until the file is gone** (sidecar folder included — read those too
before deleting). Where the lasting nuggets go, in the order to try:

- **The choice made and the alternatives rejected** → a `DECISIONS.md`
  entry, plus a flat invariant + `See D_<slug>` in **Scope decisions**.
  **No entry without a real fork**, and none for a fork whose loss a
  future change would not notice.
- **A procedure — "change this and those move together"** → next to the
  thing it operates on, as a script wherever one can run it
  (`bin/regen-icons`). A manual in prose cannot be executed or tested,
  and `DECISIONS.md` is the wrong home for it in any case: past tense is
  a decision, imperative future is a manual.
- **Work deferred as a consequence of a logged decision** → that entry's
  *Consequences*, not a surviving idea file.
- **How one class works and why it is shaped that way** → its YARD
  header. Contracts belong with the code, never in a second copy.
- **A new file or a changed responsibility** → its **Layout** line:
  path, name, ~10 words. A pointer, not a paste of the rdoc.
- **A harness or style rule** → **Conventions** above.
- **Anything a *user* must know** — a flag, the trifecta promise, how to
  configure a model → `README.md`.

There is no `CHANGELOG` here; don't create one for a graduated idea. A
fork belonging to the *library* rather than the shell (the agent loop, a
tool, Interloper's delivery boundary) is logged in
`../pikuri/DECISIONS.md` — cite it, don't re-argue it here.
