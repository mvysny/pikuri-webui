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

Scaffold complete: Sinatra app, SSE plumbing, listener/runner adapters,
boot script, specs. Not yet exercised against a live llama.cpp server.

Tracks pikuri **master**, not a release: `pikuri-core` / `pikuri-pdf` are
path dependencies on `../pikuri`. Upgrades follow pikuri's `CHANGELOG.md`
— its `**Breaking:**` entries carry the migration instructions, and
pikuri-tui's HEAD is the worked example for anything ambiguous. Reading
that changelog beats bisecting pikuri-tui's git history, which is mostly
Tuile churn this project doesn't share.

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

- **The browser shows the conversation; diagnostics go to stderr.**
  The transcript shows the LLM conversation — assistant Markdown,
  reasoning, tool-call lines, tool observations — driven by our pikuri
  listener. Internal diagnostics — pikuri's per-subsystem loggers,
  PikuriWeb's own logger — stay on their default stderr sinks and never
  reach the page. Never cross the streams.

- **The seam.** All `Pikuri::*` references stay inside
  `bin/pikuri-web-chat` (boot/wiring) and the small adapter set under
  `lib/pikuri_web/`
  ({SseListener}, {AgentRunner}). {Transcript}, {Broadcaster},
  {StreamingMessage}, {MarkdownRenderer} and {App} are
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
  injections are delivered at turn start and once each tool batch
  completes, so one placed mid-response waits for that boundary — which
  is why the input stays enabled while busy and the status bar shows the
  queued count. The count is pushed by `Interloper#on_change`, so the
  agent's own mid-loop drain updates the browser too.

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

- **The chat script stays chat-only; new capability means a new
  script.** `bin/pikuri-web-chat` wires `web_search`, `web_scrape`,
  `fetch` and `calculator` — nothing that reads the disk, runs a
  command or edits a repo, even though pikuri ships `pikuri-os` /
  `pikuri-code` / `pikuri-workspace` right there in the same checkout.
  The absence of the trifecta's *private data* leg is what the README
  sells as the reason you can chat freely, and that promise is attached
  to this entry point — hence the `-chat` suffix in the script's name:
  growing an OS or code shell later is a legitimate direction, but it
  lands as a *separate* boot script with its own tool set and its own
  trifecta report, never as extra tools bolted into this one. Adding a
  disk- or shell-touching tool here silently breaks a guarantee a user
  has already read. The shared plumbing
  ({AgentRunner}, {SseListener}, {Transcript}, {App}) is tool-set
  agnostic and is the part such a sibling script would reuse.

- **Single shared conversation, loopback by default.** One agent, one
  transcript, in-process — the TUI's model rendered in a browser. No
  sessions, no auth; `--bind` defaults to 127.0.0.1 and anything else
  is the operator's risk. Per-session conversations are a rewrite of
  {AgentRunner}/{Transcript} ownership, not a patch — out of scope
  until there's a concrete need.

- **Theme is a cookie, not state.** Dark (the TUI's palette) and light
  are two mappings of the same nine semantic CSS tokens; the whole
  theme lives in `public/style.css` plus a `theme` cookie. `GET /`
  resolves the cookie and renders `data-theme` onto `<html>` so a
  light-theme user never sees a dark first paint, and app.js flips the
  attribute + rewrites the cookie in place — no `POST /theme`, because
  a reload for a color change costs an SSE reconnect. The cookie is a
  browser preference, deliberately outside {Transcript}: it is the one
  piece of per-browser state, and it stays presentational so
  "the transcript is server-authoritative" keeps meaning what it says.
  A new themed color means adding it to both palettes and both
  mappings; nothing outside style.css reads a raw color.

- **One config file for every pikuri shell.** {Config} reads the same
  layered `~/.config/pikuri/config.toml` as pikuri-tui's
  `Shared::Config`, and carries the *whole* schema — `[code]`,
  `[[code.mcp]]` and all — even though this host wires none of it.
  Trimming the schema to what we read would reject a file the TUI
  wrote, because loading raises on an unknown top-level key. Secrets
  (`[[llm]].api_key`, `[search]` provider keys) live only there: never a
  CLI flag (visible in `ps`), never `ENV` (inherited by every subprocess
  pikuri spawns), never a project-local file (git-committable).

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
- `lib/pikuri_web/config.rb` — `PikuriWeb::Config`, the layered TOML
  loader for `~/.config/pikuri/config.toml` (model connections, search
  provider keys). Port of pikuri-tui's `Shared::Config`, schema-complete
  so one file serves every pikuri shell; Pikuri-free.
- `views/index.erb` — the page shell; server-rendered snapshot.
- `public/app.js` — the project's entire JavaScript; see above.
- `public/style.css` — hand-written chat layout; block kinds mirror
  the TUI's visual language (muted thinking, cyan tool lines).
- `bin/pikuri-web-chat` — boot script: config load, agent + tools +
  Interloper wiring, the trifecta report, Puma start. Same flags as the
  TUI plus `--port` / `--bind`. No `--api-key` flag, ever: a secret on
  the command line is visible in `ps` and shell history, so keys come
  only from the config file.

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
