# CLAUDE.md

## What this project is

A Sinatra-based web front-end wrapping the
[pikuri](https://codeberg.org/mvysny/pikuri) library — the browser
sibling of [pikuri-tui](../pikuri-tui/). `bin/pikuri-web` binds the
same `Pikuri::Agent` and the same `Pikuri::Tool` set as the TUI's chat
shell; the conversation pane / log pane / input field / status bar
become a server-rendered page kept live over one SSE connection.

All LLM transport, tool execution, agent loop control, prompts: that's
all pikuri. We own the web shell only.

## Status

Scaffold complete: Sinatra app, SSE plumbing, listener/runner adapters,
boot script, specs. Not yet exercised against a live llama.cpp server.

## Scope decisions

- **Reuse pikuri as runtime; this project owns the web shell.**
  `Pikuri::Agent` is the loop; `Pikuri::Tool::*` are the tools;
  `Pikuri::Agent::Event` is the stream we render. We add an SSE
  listener (renders the event stream into the transcript + browsers),
  an agent runner (worker thread + Interloper routing), and the
  routes / templates / static files around them. Anything beyond that
  is a bug or scope creep.

- **JavaScript is as minimal as possible.** One hand-written
  `public/app.js` (~100 lines), zero JS dependencies, no Node, no
  build step. All rendering is server-side (kramdown); the browser
  receives ready-made HTML fragments over SSE and places them by
  block id. If a change needs an npm package or a bundler, the answer
  is to render it on the server instead.

- **The transcript is server-authoritative.** {Transcript} holds the
  rendered blocks; `GET /` renders the full snapshot and SSE carries
  only deltas. Page reload, second tabs, and EventSource reconnects
  converge on the same state with no client-side bookkeeping. Never
  introduce client-only conversation state.

- **Two panes, two purposes.** The transcript shows the LLM
  conversation — assistant Markdown, reasoning, tool-call lines, tool
  observations — driven by our pikuri listener. The collapsible log
  panel shows internal diagnostics — pikuri's per-subsystem loggers
  via `Pikuri.log_io=`, PikuriWeb's own logger — both routed through
  one {LogIO}. Never cross the streams.

- **The seam.** All `Pikuri::*` references stay inside `bin/pikuri-web`
  (boot/wiring) and the small adapter set under `lib/pikuri_web/`
  ({SseListener}, {AgentRunner}). {Transcript}, {Broadcaster},
  {StreamingMessage}, {LogIO}, {MarkdownRenderer} and {App} are
  Pikuri-free — they speak ids, kinds, HTML strings and queues. Same
  fork-or-swap rationale as the TUI: if pikuri's surface shifts, the
  cost is rewriting two files.

- **The threading rule.** The agent loop blocks on the LLM and runs on
  a worker thread owned by {AgentRunner} — never on a Sinatra request
  thread. The listener writes into thread-safe sinks ({Transcript},
  {Broadcaster}); each `GET /events` connection parks its serving
  thread draining one subscribed queue. There is no UI thread and no
  marshaling — thread-safety lives in the sinks, not the callers.

- **Mid-loop input goes through `Control::Interloper`** (which the TUI
  deferred). {AgentRunner#submit} starts a turn when idle and injects
  when busy; the injection renders through the normal listener path as
  `UserTurn(mid_loop: true)`. Remember Interloper's boundary caveat:
  injections take effect at the next `after_tool_result` boundary, so
  the input stays enabled while busy and the status bar shows the
  queued count.

- **Streaming is re-render-and-replace.** The TUI's
  `StreamingMarkdownBuffer` (block-cutter, committed-prefix
  machinery) is deliberately *not* ported: it bounded per-token
  TTY::Markdown cost on a terminal. Here {StreamingMessage} re-renders
  the whole accumulated source through kramdown per (rate-limited)
  delta and the browser replaces one div's innerHTML. Its lifecycle
  contract is the TUI buffer's: deltas are preview-only, the bookend
  finalizes with authoritative content (fast-path when equal), dead
  after finalize. Delta coalescing stays in pikuri
  (`Listener::RateLimited`, 15 fps) — don't reimplement it here.

- **Single shared conversation, loopback by default.** One agent, one
  transcript, in-process — the TUI's model rendered in a browser. No
  sessions, no auth; `--bind` defaults to 127.0.0.1 and anything else
  is the operator's risk. Per-session conversations are a rewrite of
  {AgentRunner}/{Transcript} ownership, not a patch — out of scope
  until there's a concrete need.

## Layout

Per-file rationale lives in each source file's YARD header — this is
the package map. Everything we ship lives under the `PikuriWeb::`
namespace; `lib/pikuri_web.rb` boots Zeitwerk over `lib/pikuri_web/`.

- `lib/pikuri_web.rb` — Zeitwerk loader + eager-load; module-level
  `PikuriWeb.logger`.
- `lib/pikuri_web/version.rb` — `PikuriWeb::VERSION`.
- `lib/pikuri_web/app.rb` — `PikuriWeb::App`, the Sinatra app:
  `GET /` (page shell), `GET /events` (SSE), `POST /messages`,
  `POST /cancel`. Collaborators injected via class-level settings.
- `lib/pikuri_web/sse_listener.rb` — `PikuriWeb::SseListener`, the
  `Pikuri::Agent::Listener::Base` subclass rendering the event stream
  into the transcript + SSE. The TuileListener equivalent.
- `lib/pikuri_web/agent_runner.rb` — `PikuriWeb::AgentRunner`, owns
  the worker thread and the start-vs-inject (Interloper) decision,
  broadcasts status.
- `lib/pikuri_web/transcript.rb` — server-authoritative rendered-block
  store; thread-safe.
- `lib/pikuri_web/broadcaster.rb` — SSE frame formatting + fan-out to
  per-connection queues; thread-safe.
- `lib/pikuri_web/streaming_message.rb` — per-turn delta accumulator
  (append / finalize lifecycle), web descendant of the TUI's
  StreamingMarkdownBuffer.
- `lib/pikuri_web/markdown_renderer.rb` — kramdown (GFM) → HTML with
  escaped-text fallback; HTML-escape helper for plain-text blocks.
- `lib/pikuri_web/log_io.rb` — IO-shaped diagnostic sink: ring buffer
  for page-load replay + `log` SSE events. CountingLogIO's descendant
  (error counting moved client-side).
- `views/index.erb` — the page shell; server-rendered snapshot.
- `public/app.js` — the project's entire JavaScript; see above.
- `public/style.css` — hand-written chat layout; block kinds mirror
  the TUI's visual language (muted thinking, cyan tool lines).
- `bin/pikuri-web` — boot script: RubyLLM config, agent + tools +
  Interloper wiring, Puma start. Same flags as the TUI plus
  `--port` / `--bind`.

## Conventions

- Tests: rspec-core `describe`/`it` harness with minitest-style
  assertions (`assert_equal`, `refute`, …) — same as pikuri /
  pikuri-tui. `rake` runs the suite.
- Library exceptions are logged, our bugs raise: kramdown failures
  degrade to escaped text, `run_loop` failures log and return the UI
  to idle; but contract violations (double finalize, bad flush mode)
  raise.
- Block kinds (`:user`, `:assistant`, `:thinking`, `:tool_call`,
  `:tool_result`, `:notice`, `:error`) are the contract between
  SseListener, index.erb and style.css — adding one means touching
  all three.
