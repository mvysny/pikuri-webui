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

Tracks pikuri **master**, not a release: `pikuri-core` / `pikuri-pdf` are
path dependencies on `../pikuri`. Upgrades follow pikuri's `CHANGELOG.md`
— its `**Breaking:**` entries carry the migration instructions, and
pikuri-tui's HEAD is the worked example for anything ambiguous. CI must
clone `../pikuri` before bundling. See `DECISIONS.md`
`D_track_pikuri_master`.

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

- **The seam: `Pikuri::*` appears only in `bin/pikuri-web-chat`,
  {SseListener}, {AgentRunner} and {HistoryReplay}.** {Transcript},
  {Broadcaster}, {StreamingMessage}, {MarkdownRenderer},
  {ConversationStore}, {ConversationRegistry}, {Config} and {App} are
  Pikuri-free — they speak ids, kinds, HTML strings, paths and queues. A
  fourth adapter has to argue for itself. See `D_pikuri_free_core`.

- **Deleting a conversation is irreversible.** `confirm()` then `rm_r`,
  `meta.json` unlinked first; no undo, no tombstone, no retention cap.
  {ConversationRegistry} drops the runner before removing the folder, so
  nothing writes it back. Refused while *that* conversation is mid-turn.
  See `D_delete_no_undo`.

- **Firefox on the desktop, Safari on iPad, Safari on iPhone — greenfield
  only.** No polyfills, no prefixes for a fourth browser; `:has()`,
  `:focus-within`, `@media (hover: none)`, `dvh` and
  `SubmitEvent#submitter` are all fair game. iPads count as desktops. The
  iPhone *layout* does not work yet (`ideas/phone-layout.md`).
  See `D_target_browsers`.

- **The transcript is server-authoritative.** {Transcript} holds one
  conversation's rendered blocks; `GET /c/:id` renders the full snapshot
  and SSE carries only deltas. Never introduce client-only conversation
  state.
  See `D_server_authoritative_transcript`.

- **A saved conversation is `history.json` plus our `meta.json`, and
  nothing else.** Blocks are re-derived by replaying synthesized events
  through {SseListener}, never stored — so old conversations get today's
  renderer and today's CSS. A runner replays its history once, when the
  registry mints it. No rendered HTML on disk, no second renderer.
  See `D_replay_from_history`.

- **The threading rule.** The agent loop runs as a job on the shared
  executor — never on a Sinatra request thread. Thread-safety lives in
  the sinks ({Transcript}, {Broadcaster}) and in {ConversationRegistry};
  there is no UI thread and no marshaling.
  See `D_worker_thread_agent_loop`, `D_serial_turn_executor`.

- **No owner thread, and no session concept — but if state ever becomes
  shared, it gets *one global* mechanism.** Single-user server; each
  browser owns its own state (draft, scroll, theme, and which conversation
  it reads — that one lives in the URL). The server's state is partitioned
  per conversation and single-writer for that reason, so there is nothing
  for an event queue or a coarse lock to own. Should something genuinely
  shared appear, the answer is one global queue or one global lock —
  **never a Vaadin-style per-session one**, because a session here owns
  nothing to guard. {Broadcaster} stays outside either, as a sink.
  See `D_no_event_queue`.

- **Nothing in the exit path may rely on `at_exit` or on Sinatra's INT
  trap** — both run on the far side of Puma's unbounded graceful wait,
  which parked `GET /events` drain threads would otherwise never end.
  {Broadcaster} is closed from Puma's `:state, :stop` event, and
  `#close` must stay idempotent *and* keep refusing new subscribers.
  See `D_shutdown_on_state_stop`.

- **The browser shows the conversation; diagnostics go to stderr.**
  {SseListener} renders events, never log lines, and `PikuriWeb.logger`
  is never pointed at the {Broadcaster}. Never cross the streams.
  See `D_diagnostics_to_stderr`.

- **JavaScript is as minimal as possible.** One hand-written
  `public/app.js` (~100 lines), zero JS dependencies, no Node, no build
  step; all rendering is server-side. If a change needs an npm package
  or a bundler, the answer is to render it on the server instead.
  See `D_no_js_build_step`.

- **Streaming is re-render-and-replace.** {StreamingMessage} re-renders
  the whole accumulated source per (rate-limited) delta; the TUI's
  `StreamingMarkdownBuffer` is deliberately not ported, and delta
  coalescing stays in pikuri (`Listener::RateLimited`, 15 fps). Its
  lifecycle contract is the TUI buffer's: deltas preview-only, the
  bookend finalizes with authoritative content, dead after finalize.
  See `D_rerender_and_replace`.

- **Mid-loop input goes through `Control::Interloper`, and the input
  stays enabled while busy.** {AgentRunner#submit} starts a turn when
  idle and injects when busy; it never refuses. Interloper delivers at turn start and at
  tool-batch completion, so the status bar's queued count (pushed by
  `Interloper#on_change`) exists to make that wait legible.
  See `D_interloper_mid_loop_input`.

- **The chat script stays chat-only; new capability means a new
  script.** A disk- or shell-touching tool added to
  `bin/pikuri-web-chat` breaks a trifecta guarantee the README has
  already made. An OS or code shell lands as a sibling script with its
  own tool set and its own trifecta report.
  See `D_chat_only_entry_point`.

- **A conversation owns its agent; a tab owns which one it views — and
  single-user for good.** {ConversationRegistry} holds one {AgentRunner}
  per conversation opened, each with its own agent, history and
  transcript. Which conversation a tab views is that tab's own state and
  lives in the URL (`GET /c/:id`), and SSE frames are addressed per
  conversation, so a turn runs on undisturbed while you read something
  else. No sessions, no auth, no accounts: a second person runs their own
  process under their own OS account. `--bind` defaults to 127.0.0.1 and
  anything else is the operator's risk.
  See `D_single_shared_conversation`, `D_conversation_owns_agent`.

- **Turns run on one shared executor, and its pool size is a load cap, not
  a correctness device.** Sending never refuses: a turn submitted when the
  slots are taken is *queued*, which the status bar says out loud. `--turns`
  exists so turns don't outnumber the inference server's parallel slots;
  match it to llama.cpp's `--parallel`. Single-writer safety comes from the
  partition instead — one agent per conversation, and a conversation admits
  one turn at a time — so it holds at any pool size. Don't rebuild a
  correctness argument on that number.
  See `D_serial_turn_executor`.

- **Theme is a presentational cookie, not transcript state.** Nine
  semantic CSS tokens, two palettes, both in `public/style.css`; `GET /`
  renders `data-theme` onto `<html>` and app.js rewrites the cookie in
  place. A new themed color means both palettes and both mappings, and
  nothing outside `style.css` reads a raw color.
  See `D_theme_cookie`.

- **All state under one folder named after the shell.**
  `~/.local/state/pikuri/pikuri-web-chat/`, derived once in the boot
  script as `state_root`; anything new this shell persists goes beside
  `conversations/`, never straight into `Pikuri::Paths.state`. A shared
  path is the last step of cross-shell interop, not the first — the
  *format* is what travels. See `D_per_shell_state_root`.

- **One config file for every pikuri shell, and secrets live only
  there.** {Config} carries the *whole* `~/.config/pikuri/config.toml`
  schema, including sections this host never reads. No `--api-key`
  flag, ever; no `ENV`; no project-local file.
  See `D_schema_complete_config`.

- **`--dev` is Sinatra's development mode, not code reloading** — the
  agent, its listener stack and the runner thread are wired once at
  boot. See `D_dev_flag_no_reload`.

## Layout

Per-file rationale lives in each source file's YARD header — this is
the package map. Everything we ship lives under the `PikuriWeb::`
namespace; `lib/pikuri_web.rb` boots Zeitwerk over `lib/pikuri_web/`.

- `lib/pikuri_web.rb` — Zeitwerk loader + eager-load; module-level
  `PikuriWeb.logger`.
- `lib/pikuri_web/version.rb` — `PikuriWeb::VERSION`.
- `lib/pikuri_web/app.rb` — `PikuriWeb::App`, the Sinatra app:
  `GET /` (redirects to the newest), `GET /c/:id` (one conversation),
  `GET /events?conversation=` (SSE, per conversation), `POST /messages`,
  `POST /cancel`, `GET`/`POST /conversations`,
  `POST /conversations/:id/delete`. Every route names the conversation it
  acts on. Registry + broadcaster injected via class-level settings.
- `lib/pikuri_web/sse_listener.rb` — `PikuriWeb::SseListener`, the
  `Pikuri::Agent::Listener::Base` subclass rendering the event stream
  into the transcript + SSE. The TuileListener equivalent.
- `lib/pikuri_web/agent_runner.rb` — `PikuriWeb::AgentRunner`, one
  conversation's agent, transcript and turn lifecycle: restore, the
  start-vs-inject (Interloper) decision, idle/queued/running, the save at
  turn end; broadcasts status.
- `lib/pikuri_web/conversation_registry.rb` — `PikuriWeb::ConversationRegistry`,
  the resident runners: mints one per conversation opened, deletes, and
  serves the sidebar rows. Pikuri-free.
- `lib/pikuri_web/history_replay.rb` — `PikuriWeb::HistoryReplay`, a
  saved `Agent::History` back into the events that produced it.
- `lib/pikuri_web/conversation_store.rb` — `PikuriWeb::ConversationStore`,
  the conversations folder: mints ids, owns `meta.json`, lists what is
  saved, deletes a folder. Pikuri-free.
- `lib/pikuri_web/relative_time.rb` — `PikuriWeb::RelativeTime`, coarse
  "6 hours ago" for sidebar rows; server-rendered, hence stale-tolerant.
- `lib/pikuri_web/transcript.rb` — one conversation's rendered blocks,
  server-authoritative; thread-safe.
- `lib/pikuri_web/broadcaster.rb` — SSE frame formatting + fan-out,
  addressed per conversation so a turn reaches only the tabs reading it;
  thread-safe.
- `lib/pikuri_web/streaming_message.rb` — per-turn delta accumulator
  (append / finalize lifecycle), web descendant of the TUI's
  StreamingMarkdownBuffer.
- `lib/pikuri_web/markdown_renderer.rb` — kramdown (GFM) → HTML with
  escaped-text fallback; HTML-escape helper for plain-text blocks.
- `lib/pikuri_web/config.rb` — `PikuriWeb::Config`, the layered TOML
  loader for `~/.config/pikuri/config.toml`; port of pikuri-tui's
  `Shared::Config`, schema-complete, Pikuri-free.
- `views/index.erb` — the page shell; server-rendered snapshot.
- `views/_sidebar.erb` — the conversation list; embedded by `index.erb`
  and served alone by `GET /conversations` for in-place refresh.
- `public/app.js` — the project's entire JavaScript; see above.
- `public/style.css` — hand-written chat layout; block kinds mirror
  the TUI's visual language (muted thinking, cyan tool lines).
- `bin/pikuri-web-chat` — boot script: config load, the conversation
  factory (agent + tools + Interloper, one wiring for every
  conversation), the shared turn executor, the trifecta report, Puma start (server settings and
  the shutdown hook). Same flags as the TUI plus `--port` / `--bind` /
  `--dev`; never an `--api-key`.

## Conventions

- Tests: rspec-core `describe`/`it` harness with minitest-style
  assertions (`assert_equal`, `refute`, …) — same as pikuri /
  pikuri-tui. `bundle exec rspec` runs the suite — no Rakefile, same
  as pikuri-tui.
- Library exceptions are logged, our bugs raise: kramdown failures
  degrade to escaped text, `run_loop` failures log and return the UI
  to idle; but contract violations (double finalize, bad flush mode)
  raise.
- Block kinds (`:user`, `:assistant`, `:thinking`, `:tool_call`,
  `:tool_result`, `:notice`, `:error`) are the contract between
  SseListener, index.erb and style.css — adding one means touching
  all three.

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
  **No entry without a real fork.**
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
