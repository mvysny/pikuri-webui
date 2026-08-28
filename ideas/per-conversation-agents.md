# A conversation owns its agent; browsers browse freely

Was `ideas/background-turns.md`. Renamed because background turns turned out to be a *consequence*
of the structural change rather than the change itself.

**Settled direction** (2026-08-28, superseding the selection half of `D_single_shared_conversation`):

- **Single-user stays single-user.** A second person runs their own `pikuri-web-chat` under their own
  OS account with their own config and their own state root. No accounts, no auth, no sessions, no
  per-user partition of the conversations folder. `D_per_shell_state_root` and
  `D_schema_complete_config` are untouched, and the `--bind` loopback posture stays exactly as it is.
- **Every browser browses freely.** Which conversation a tab is looking at is *view* state belonging
  to that tab, not server state announced to every other tab. Two tabs on the same conversation
  mirror; two tabs on different conversations do not.
- **A conversation owns an agent.** One `Agent`, one history, one transcript per conversation — not
  one per process. It does **not** own a thread; see below.
- **A conversation can be detached and keep running**, with no SSE traffic while nobody is watching.
- **Turns run on a shared single-threaded executor with a job queue.** Pool size **1** to start.
  Ownership is settled; how many turns run *at once* is one integer. See *Ownership vs. execution*.

## Why the old model was wrong, precisely

`D_single_shared_conversation` reasoned correctly from a premise that was never a product decision.
Its clause —

> Selecting a conversation is therefore *server* state, changed by a POST and announced to every tab,
> not a per-URL view: one live agent showing two panes where only one accepts input would be
> confusing in exactly the situation it enabled.

— does not claim mirroring is *good*. It says that **given one agent**, a dead second pane is worse
than mirroring. That inference holds. "One agent" is the part that was inherited from the TUI, where
one terminal forces it, and it was never argued for here on its own merits.

The entry's own rejection paragraph carries the real error: it calls per-session conversations
*"multi-user support in disguise"*, welding two separable things together. Slack is the refutation —
**its channel selection lives in the URL; the session exists only for auth.** What this project needs
is per-tab *view addressing*, which HTTP hands over for free, not sessions. No session store, no
login, no `Rack::Session`, no cookie beyond the ones already here.

Worth naming what the mirroring model *was* buying, so the cost of leaving is on the record: **device
continuity** — pick up the iPad, see what the desktop shows. Real but weak, and better delivered by a
"last viewed conversation" cookie (the `D_theme_cookie` precedent) than by forcing every tab to
mirror.

## The layers, once selection stops being global

| Layer | Holds | Lives in |
|---|---|---|
| Per tab, server never sees it | unsent draft, scroll position, theme | the browser |
| Per tab, server must know | which conversation this tab views | **the URL** (`/c/<id>`) |
| Per conversation | transcript, agent, history, its own lock-or-queue | server, N resident |
| Global | conversations folder, socket fan-out, heartbeat, config, model, **the turn executor** | server, one |

Three of those four already exist here unnamed. The change is not "add sessions" — it is **stop
storing selection in the global layer**, and then let the per-conversation layer grow from one to N.

Note the last row is why a partitioned design is inevitably *hybrid*, and that is a cost, not an
oversight: `Broadcaster`'s fan-out, its heartbeat, its `close` sentinel and `ConversationStore`'s
folder stay global no matter how far this goes.

## Two things the project already built that make this cheap

- **`D_replay_from_history` is an asset, not an obstacle.** Any conversation's transcript can be
  materialized on demand from `history.json` through `HistoryReplay` → `SseListener`. That is exactly
  what "N resident transcripts" needs, and it is already written. The "there is one transcript,
  rebuilt in place" phrasing in that decision is a self-imposed narrowing, not a constraint the
  design imposes.
- **`D_theme_cookie` already established the per-viewer axis** — server-rendered into the markup,
  rewritten client-side, never transcript state. Selection is the same shape of thing; nobody
  noticed.

## Stage it: viewing first, then agents

The two halves are separable, and the intermediate state is coherent and shippable. That matters,
because the N-agent half is the expensive one.

### Stage 1 — decouple *viewing* from *liveness* (small)

Keep exactly one live agent. Make `/c/<id>` a real URL that any tab can sit on, with the transcript
rebuilt from history for a conversation that is not live. What changes is only *which* operation
refuses while busy: today `POST /conversations/:id/select` 409s; instead, **viewing is always free,
and submitting into a non-live conversation is what starts a turn** (making it live) or 409s if
another conversation is mid-turn.

This delivers "every browser browses freely" on its own. It is background-turns' old objection B —
two panes where only one accepts input — but that objection is much weaker once the user *navigated*
there deliberately instead of having a pane forced on them.

Also collects the side benefit the old file noted: sidebar rows become honest links instead of
`<form method="post">` submit buttons, so the `Q_get_side_effects` prefetch hazard and the ~10 lines
of CSS that un-button a button both evaporate.

### Stage 2 — a conversation owns its agent (the expensive one)

- **Topic-addressed fan-out.** `Broadcaster#subscribe(conversation_id)`, and `broadcast` gains a
  topic. This is the "fan-out stops being a broadcast" cost `D_single_shared_conversation` named.
  ~20 lines, but it is the invariant that entry rests on, so it needs its own `D_` entry.
  The heartbeat and the `close` sentinel stay global.
- **`AgentRunner` becomes per-conversation, plus a registry that holds them.** The registry mints,
  finds, and reaps runners; it never touches `Pikuri::*` itself, so `D_pikuri_free_core`'s three
  adapters stay three — the registry holds `AgentRunner`s, which are already inside the seam.
- **A conversation factory, not N hand-wired agents.** Everything the boot script currently builds
  once and would now need N of: `Cancellable`, `Interloper`, `TokenLog`, `SseListener`,
  `Listener::RateLimited`, `Agent`. That has to become one closure in `bin/pikuri-web-chat` that the
  registry calls, for a reason beyond tidiness: **the trifecta report is printed once, for one
  agent** (`agent.trifecta.render`). One factory with one tool set is what keeps that boot-time
  report true of every agent, and therefore keeps `D_chat_only_entry_point`'s promise honest.
- **A "busy elsewhere" affordance** in the sidebar — a dot or spinner on rows with a running turn, or
  the feature is invisible until someone goes looking.

## Detachment: what "no SSE events for it" should mean

There are three readings, and they differ in what they waste. Worth deciding deliberately rather
than discovering.

1. **Render always, fan out selectively.** Every conversation keeps a live rendered transcript; only
   the frames are topic-filtered. Re-attach is instant. But it re-runs kramdown at 15 fps for a
   conversation nobody is looking at — pure waste, and `D_rerender_and_replace` makes that the single
   most expensive thing the server does.
2. **Drop the transcript, replay on attach.** A detached conversation renders nothing; `HistoryReplay`
   rebuilds on attach. Cheapest while detached. But `history.json` has no *in-flight partial message*
   in it, so attaching mid-turn shows the completed messages and a hole where the streaming answer
   is, until the next delta lands.
3. **Accumulate, don't render** — recommended. A detached conversation keeps appending streaming
   source into its `StreamingMessage` and accrues block *structure*, but skips the Markdown render
   and the broadcast. On attach, render once from the accumulation and you have everything including
   the in-flight partial.

(3) works because of a property `D_rerender_and_replace` already establishes: **rendering is a pure
function of the accumulated source**, so it can be deferred as easily as it can be moved to another
thread. `ideas/event-queue.md` uses the same observation to say rendering need not run on the owner
thread; here it says rendering need not run *at all* until someone looks. The append is a string
concat; the kramdown pass is the cost. So detached ≈ free, and memory stays modest because the HTML
is the big part and it is derived.

Open: whether `Listener::RateLimited`'s 15 fps timer should even be wired for a detached
conversation, given nothing downstream renders. Probably not — but it is pikuri's class, so check
before assuming a listener stack can be rebuilt mid-life.

## Ownership vs. execution — the executor is the whole answer

The old file said "still one live turn at a time" as though it were a *view* policy. It is a
**resource** policy, and separating the two is what makes N agents affordable:

- **Ownership (settled):** each conversation has its own agent, history and transcript.
- **Execution (one integer):** how many turns may be *running* at once.

**The mental model is a single-threaded Java `Executor` with a job queue, running agent turns.**
Pool size 1 to start. That is not a placeholder for something better — it is the design, and it is
simpler than what exists today:

- **A conversation does not own a thread.** It owns an agent and a transcript, and *borrows* a worker
  when its turn runs. So `AgentRunner` stops calling `Thread.new` altogether; N conversations do not
  mean N parked threads.
- **The job queue *is* the admission gate.** No separate throttle, no semaphore, no "refuse while
  another conversation is busy". Submitting always succeeds; it just may not start yet.
- **The knob is the pool size**, and it must not exceed the inference server's own slot count
  (llama.cpp's `--parallel`) — past that, requests queue inside the server instead, which buys no
  throughput and only makes latency and the status bar harder to read. Cheapest home for it is a CLI
  flag alongside `--port` / `--bind`, which the boot script already documents as "ours alone, no
  config-file home", since it is a property of the machine rather than of the model. A `[web]`
  config section is the alternative if it ever wants to be sticky.

### What the executor changes that a thread-per-conversation model doesn't

- **`busy?` becomes three states, and it is user-visible.** Today it is `@thread&.alive?`. With a
  queue it is idle / **queued** / running, and a queued conversation must not render as "thinking" —
  it is waiting for a slot, and saying so is the same honesty the queued-injection count already buys
  in `D_interloper_mid_loop_input`.
- **Cancel gains a second, easier path.** `Cancellable` stops a *running* turn at the next tool
  boundary. A *queued* turn is cancelled by dequeuing it — instant, and it never touches pikuri at
  all. Two paths behind one button.
- **`Interloper` already fits, unchanged.** Its queue survives across `run_loop` calls (see
  `AgentRunner`'s rdoc on the benign submit race), so "submit into a conversation whose turn is still
  queued" is just an injection that gets drained when the job finally starts. Nothing new to build —
  worth writing down because it is the one piece of the current design that gets *more* correct here.
- **FIFO, no priority.** A turn submitted from the tab you happen to be looking at does not jump the
  queue. Surprise-free beats clever, and with pool size 1 the queue is rarely deeper than one.

### It is not the event queue — do not merge them

`ideas/event-queue.md` proposes an owner thread for *state mutation*, whose defining rule is that it
**must never block**. This executor exists precisely *to* block — on the LLM, on tools, for minutes.
Same word, opposite contracts, and merging them would wreck both. If both land: turns are jobs on the
executor, and the events those jobs emit are posted to the conversation's owner.

## New hazards this creates, each against an existing decision

- **Shutdown loses in-flight turns — accepted, don't build anything.** `AgentRunner` saves at *turn
  end* only, and its rdoc explains why per-message saving is impossible (nothing fires when the tool
  message lands), so `force_shutdown_after: 5` will drop whatever is running. With an executor pool of
  1 that is at most one running turn plus a queue of not-yet-started jobs, which lose nothing because
  they never began. Single user, infrequent restarts, small damage: no save-on-stop, no drain phase.
  Worth a line in whatever `D_` entry this idea graduates into, so the next reader knows it was
  weighed rather than missed. Raising the pool size raises this cost linearly — the one thing to
  re-check if the knob ever moves.
- **The conversations folder becomes genuinely multi-writer.** This is exactly the trigger
  `ideas/conversation-store-locking.md` predicted — *"the moment there are N agents there are N
  writers, and 'one serialized writer in `AgentRunner`' stops being true in a way no reader of
  `ConversationStore` would ever guess."* That file's "only if the queue is far off" hedge expires
  here: with N agents, the store owning its own consistency stops being optional.
- **Tool instances get shared across concurrent agents — deferred, and the pool size is why.**
  `Pikuri::Tool::CALCULATOR`, `WEB_SCRAPE` and `FETCH` are *constants*, so pikuri already shares one
  instance per process. With a pool of 1 no two agents can be inside a tool at the same time, so this
  cannot bite today. It becomes a precondition the moment the knob goes above 1. Being tracked as a
  pikuri-side question (thread-safety of the shared tool constants); the answer belongs in
  `../pikuri/DECISIONS.md`, cited from here, never re-argued in this repo.
- **Is `ChatTransport` per-agent or shareable?** The connection rides a per-chat
  `RubyLLM::Context`, which reads as safe to share, but the factory should mint one per agent unless
  pikuri says otherwise. Check, don't assume.

## What this does to `ideas/event-queue.md`

Its "global, not per-session" answer was right for today but for a shaky reason: not *"because state
is shared"* but *"because there is currently exactly one conversation"*. Under this direction the
unit that owns a lock-or-queue is **the conversation**, and the global layer keeps only the sink-style
guards it already has. That is Vaadin's architecture with `conversation` substituted for `session` —
which is also the answer to "no web server has a singular lock": Redis executes commands on one
thread, Node is one event loop, Postgres orders commits through one WAL, and Vaadin's lock is
singular *per session*. Web-shaped means partitioned with one owner per partition, not lock-free.

So: per-conversation ownership makes the queue *more* necessary, not moot — and it moves this idea
ahead of that one in the ordering, since there is no point building a global owner for state that is
about to stop being global.

## Explicitly not doing

**Multi-user.** Settled above, and worth keeping the reasons written down because a web UI keeps
inviting the question: it collides with `D_schema_complete_config` (one config, one API key — one
bill, no per-user quota), with the loopback `--bind` posture (network exposure makes auth
load-bearing security rather than a convenience), with `D_per_shell_state_root`, and hardest with
`D_chat_only_entry_point` — the day an OS or code shell sibling exists, every user's tool calls would
run as the *same OS user*. One process per person, own port, own state root, is both cheaper and
safer, and `ideas/multi-process-locking.md` is where the one real consequence of that lives.
