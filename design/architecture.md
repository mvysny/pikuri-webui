# Architecture

The bird's-eye map of the code as it is: how the pieces are wired, and the flows that cross
several of them. **The code and its YARD headers are the authority; this file describes
them.** When they disagree, fix this file.

Keep it short. Anything true of one class belongs in that class's header, and which class
lives where is `AGENTS.md`'s module map — an agent needs that every turn. This file holds
only what no single symbol can: dependency direction, the threading and data-flow story, and
where to start reading. Cite `R_` for what must hold and `D_` for why; argue nothing here.

## Wiring

- **`bin/pikuri-web-chat` constructs everything once**, and hands it in: no globals, no
  service locator, nothing reloaded (`D_dev_flag_no_reload`).
- **One conversation factory builds every agent** — transport, system prompt, listener stack,
  the four tools — so the trifecta report printed at boot is true of every agent in the
  process (`R_chat_only`).
- **Dependencies point toward data.** `Web` may name anything; nothing under `agents/` or
  `conversations/` may name a constant under `web/`, so a renderer can never be summoned from
  inside the agent loop (`D_namespaces`, checked by `spec/pikuri_web/namespaces_spec.rb`).
  Every crossing is an object injected at the boot script and held duck-typed.
- **The split is per conversation, and everything above it is process-wide**: the
  {Agents::ModelCatalog}, the {Agents::Titler}, {Conversations::Store}, the
  {Web::Broadcaster}, the turn executor (`Concurrent::CachedThreadPool`) and the
  {BigAppLock}, all injected into every runner. {Conversations::Registry} mints one
  {Agents::Runner} per conversation opened, and that runner owns its agent, `Interloper`,
  `Cancellable`, `TokenLog`, {Web::Transcript} and {Web::SseListener}.
- **No `Pikuri::*` type reaches a browser-facing class** (`D_pikuri_free_core`); translation
  happens at {Web::SseListener}, {Agents::Runner}, {Conversations::HistoryReplay} and
  {Conversations::Store#save}.

## Flows

**A turn** (a `POST /messages` through to the save):

1. `Web::App` runs the route body as one {BigAppLock} task: resolve the runner, `#submit`.
2. `Agents::Runner#submit` starts a turn when idle and injects into the `Interloper` when
   busy (`D_interloper_mid_loop_input`); either way it broadcasts a status frame.
3. On a start it posts the turn to the shared executor, and *then* the title job beside it,
   so a title never delays an answer (`D_titler_connection`). `#claim_running` is the turn
   job's first task, the take-pending-model bracket its second.
4. `run_loop` runs **off-domain** — LLM round-trips (each holding one of pikuri's server
   permits), tool calls, `Interloper` drains at each tool-batch boundary.
5. `Web::SseListener` renders each event off-domain (kramdown, sanitizing) and enters a task
   per finished block: store in the {Web::Transcript} + broadcast, as one unit.
6. `#finish_turn` is the closing task: save through {Conversations::Store#save}, then go idle
   — or, when a queue is still pending, claim a bare turn to deliver it.

**Opening a conversation** (two requests, and the window between them):

1. `GET /c/:id` → {Conversations::Registry#open_id} mints the runner if it is not resident;
   `#restore!` replays `history.json` through {Conversations::HistoryReplay} into synthesized
   events, which the real listener renders into a fresh transcript — and posts the title job
   for a conversation still carrying its start stamp (`D_lazy_retro_titling`).
2. The same task reads blocks, status and sidebar rows, so the page is an untorn snapshot.
3. The browser then opens `GET /events`, which **subscribes before it snapshots** and writes
   the whole transcript as one `snapshot` frame; a block finalized in the gap arrives twice
   rather than not at all (`D_subscribe_then_snapshot`).
4. SSE carries deltas from there; `transcript.js` upserts blocks by id.

**Shutdown:** Puma's `:state, :stop` fires on the line before the graceful wait —
`broadcaster.close` pushes the sentinel that releases every parked `/events` drain loop and
`turn_executor.shutdown` drops what is running. Nothing in that hook may enter the domain
(`D_shutdown_on_state_stop`, `D_global_monitor`).

## Where to start reading

`bin/pikuri-web-chat` — every object in the process is constructed there, in order, with the
conversation factory in the middle showing the whole per-conversation graph. Then
{Agents::Runner} for the turn lifecycle and {Web::SseListener} for how an event becomes a
block.
