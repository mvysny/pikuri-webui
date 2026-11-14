# Architecture

How the pieces compose — what no single symbol can say and what would be expensive to overturn:
dependency direction and wiring, the threading and data-flow story, the flows a newcomer needs,
where to start reading. **Normative: the code conforms.** Change this file first, then the code.
Not here: why (`decisions.md` — cite the `D_`), what upstream does (`research.md` — cite the
`R_`), one symbol's behaviour (its YARD header), the module map (`AGENTS.md`). Only the sections
with content; the first entry in each is the ruler. Cap 12 KB — over it, research or YARD-header
content has crept in.

## Wiring

- **`bin/pikuri-webui-chat` constructs everything once**, and hands it in: no globals, no
  service locator, nothing reloaded (`D_dev_flag_no_reload`).
- **One tool wiring builds every agent** — the `configure` lambda the live list is given, the
  same one the boot-time trifecta report is read off — so that report is true of every agent
  in the process (**A chat, not an agent with hands on your machine**).
- **pikuri-conversations owns the agents and their threads**: `Pikuri::Conversations` (the
  live list) builds each agent, runs its turns on threads of its own, injects a mid-turn
  message, applies a model pick between turns, throttles requests per server and titles a
  conversation after its first turn. This shell owns what a browser sees of that.
- **Dependencies point toward data.** `Web` may name anything; nothing under `agents/` or
  `conversations/` may name a constant under `web/`, so a renderer can never be summoned from
  inside the agent loop (`D_namespaces`, checked by `spec/pikuri_webui/namespaces_spec.rb`).
  Every crossing is an object injected at the boot script and held duck-typed.
- **The split is per conversation, and everything above it is process-wide**: the
  {Agents::ModelCatalog}, the live list (with its titler), the gem's `Store`, the
  {Web::Broadcaster} and the {BigAppLock}, all injected into every runner.
  {Conversations::Registry} mints one {Agents::Runner} per conversation opened; the runner is
  its live `Conversation`'s one listener, and owns its `TokenLog`, {Web::Transcript} and
  {Web::SseListener} (behind pikuri-conversations' `RateLimitedListener`, whose class doc
  owns its reasoning; the runner hands it the agent's events and `TurnEnded`, so a failed
  turn's buffered tail is flushed before its status).
- **No `Pikuri::*` type reaches a browser-facing class** (`D_pikuri_free_core`); translation
  happens at {Web::SseListener}, {Agents::Runner} and {Conversations::HistoryReplay}, and the
  store's `Entry` crosses the rest as a value read by field.

## Flows

**A turn** (a `POST /messages` through to the save):

0. A message with images first has them checked (count, size, type sniffed from the bytes)
   and written into the conversation's `attachments/` **off-domain** (the store's `stash`),
   under the names its save will then skip — so the
   `:user` block's `<img>` never points at a file not there yet. A delete landing between
   the stash and the submit is answered by removing the folder again.
1. `Web::App` runs the route body as one {BigAppLock} task: resolve the runner, `#submit`.
2. `Agents::Runner#submit` hands it to the live `Conversation#submit`, which starts a turn
   on a thread of the gem's own when idle and injects into the agent's `Interloper` when busy
   (`D_interloper_mid_loop_input`). A model known to take no images refuses them here, as 422.
3. `run_loop` runs **off-domain** — LLM round-trips (each holding one of the gem's
   `Throttle` permits for its server), tool calls, `Interloper` drains at each tool-batch
   boundary. The gem's own events (turn started, pending count, …) reach the runner, which
   broadcasts a status frame from a task.
4. `Web::SseListener` renders each agent event off-domain (kramdown, sanitizing) and enters a
   task per finished block: store in the {Web::Transcript} + broadcast, as one unit.
5. The gem's `on_turn_end` is {Agents::Runner#persist}: a task that saves through the store,
   before the conversation goes idle — or restarts a bare turn for an injection that came
   too late. After the first turn of a stamp-titled conversation the gem's titler names it,
   and the runner lands the title (`D_lazy_retro_titling`).

**Opening a conversation** (two requests, and the window between them):

1. `GET /c/:id` → {Conversations::Registry#open_id} mints the runner if it is not resident;
   {Agents::Runner#open} replays `history.json` through {Conversations::HistoryReplay} into
   synthesized events, which the real listener renders into a fresh transcript, then opens
   the live conversation on that history — its agent boots on a gem thread, off-domain.
2. The same task reads blocks, status and sidebar rows, so the page is an untorn snapshot.
3. The browser then opens `GET /events`, which **subscribes before it snapshots** and writes
   the whole transcript as one `snapshot` frame; a block finalized in the gap arrives twice
   rather than not at all (`D_subscribe_then_snapshot`).
4. SSE carries deltas from there; `transcript.js` upserts blocks by id, and splices a
   streaming reply's `stream` diffs around its `<!--tail-->` marker (`D_stream_blocks_once`).

**Shutdown:** Puma's `:state, :stop` fires on the line before the graceful wait —
`broadcaster.close` pushes the sentinel that releases every parked `/events` drain loop and
`Pikuri::Conversations#shutdown` cancels what is running, without waiting. Nothing in that
hook may enter the domain
(`D_shutdown_on_state_stop`, `D_global_monitor`).

## Where to start reading

`bin/pikuri-webui-chat` — every object in the process is constructed there, in order, with the
conversation factory in the middle showing the whole per-conversation graph. Then
{Agents::Runner} for what a conversation reports and {Web::SseListener} for how an event
becomes a block; the turn lifecycle itself is pikuri-conversations' `Conversation`.
