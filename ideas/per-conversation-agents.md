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

### Stage 0 — the executor — **done 2026-08-28**

`AgentRunner` posts turns to an injected `Concurrent::SerialExecutorService` instead of calling
`Thread.new`; the boot script owns the `SingleThreadExecutor` and shuts it down (non-blocking) from
the same Puma `:state, :stop` hook that closes the `Broadcaster`. Behaviour identical, one
conversation still.

Two simplifications fell out that are worth knowing about before the next stage:

- `busy?` is a plain `@running` flag rather than `@thread&.alive?`, which retired the
  `@thread == Thread.current` guard in the turn's ensure entirely.
- `conversation_flow_spec` injects `ImmediateExecutor` and runs turns inline, deleting its
  deadline-plus-`sleep` spinner. **Only one of the two spinners died**, not both as predicted:
  `agent_runner_spec` is *about* the busy state, so it needs the turn still running when `submit`
  returns, and keeps a real `SingleThreadExecutor` plus `wait_until`.

One gotcha the next reader will hit: `submit` must post **outside** its mutex. `ImmediateExecutor`
runs the job on the calling thread, and the turn's ensure re-takes that same non-reentrant mutex.

### Stage 1 — decouple *viewing* from *liveness* — **done 2026-08-28**

`GET /c/:id` serves any conversation; the live one from {Transcript}, any other replayed per request
by `HistoryReplay.snapshot`. Sending is what makes a conversation live and carries the mid-turn
refusal, so `POST /conversations/:id/select` is gone. Rows are links, which took the
`Q_get_side_effects` prefetch hazard and the un-button-a-button CSS with them. `POST /conversations`
now answers with the fresh id, because a new conversation has an id the asking tab is not on and it
has to navigate.

SSE is still one undivided feed, so **every frame is stamped with the live conversation's id and
app.js drops what is not its own.** Crude on purpose; stage 2's per-conversation `subscribe` deletes
it.

Two things worth carrying into stage 2:

- **Ordering bug, found in a browser and not by the specs.** `AgentRunner` re-pointed `@conversation`
  *after* `load_history!` emitted its `Reset` and after the replayed blocks, so a switch stamped its
  frames with the **outgoing** conversation — dropped by the very tab that asked for the switch, and
  applied by the tabs that did not. Fixed by persisting the outgoing conversation, then re-pointing,
  then emitting; all three of `switch_conversation` / `switch_to` / `discard` now follow that order,
  and `conversation_flow_spec` has a regression test that fails without it. **Any future code that
  emits during a switch has to sit on the right side of that re-point.**
- **`current` and `live` are now different marks** in the sidebar, and the CSS carries both. That
  distinction is what stage 2's "busy elsewhere" affordance builds on.

### Stage 2 — a conversation owns its agent — **done 2026-08-28**

Shipped as `D_conversation_owns_agent` and `D_serial_turn_executor`. What is
left of this file below is the design notes those entries were written from;
**graduate the rest of it** — the remaining live items are the detach-rendering
question and the reaping question, both of which only matter at pool > 1.

Two things worth carrying forward that the decision entries do not say:

- **A bug this stage introduced and fixed:** `submit` held the runner's mutex
  across `inject_user_message`, whose `on_change` callback re-enters through
  `status_data`. Ruby's `Mutex` is not re-entrant, so a mid-turn injection
  deadlocked. Both the post and the inject now happen outside the lock. **Any
  callback pikuri fires synchronously is a re-entry hazard**; the interloper's
  is the one we know about.
- **The busy dot needs its own frame.** A `status` frame reaches only the tabs
  reading that conversation — exactly the ones that can already see the turn.
  The sidebar's per-row dot is the only sign a conversation you are *not*
  looking at is working, and it is server-rendered, so the runner broadcasts an
  unaddressed `conversations` frame on each idle↔busy transition. Found by
  driving a browser; the specs had no opinion.

### Stage 2 as originally planned

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
thread. The event-queue idea (graduated; `D_no_event_queue`) used the same observation to say
rendering need not run on the owner thread; here it says rendering need not run *at all* until someone looks. The append is a string
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
- **The pool size is pinned at 1, and it is emphatically not a knob.** The first draft of this file
  proposed exposing it as a CLI flag beside `--port` / `--bind`. That was wrong, and the reason is
  worth keeping: single-writer safety at pool 1 is an *accident of a setting*, not a property of the
  abstraction. A flag labelled "how fast" that silently enables data races is a trap — "correct until
  someone changes a number, with nothing in the code to say so" is the exact failure mode the
  event-queue idea opened by complaining about. (Superseded: `--turns` shipped after all, because
  the safety came from the partition rather than the pool size — `D_serial_turn_executor`.)
  - **Shipped as a type, not a comment.** `AgentRunner#initialize` takes
    `executor: Concurrent::SerialExecutorService`. `SingleThreadExecutor` and `ImmediateExecutor` are
    that; `FixedThreadPool.new(2)` is not. The constraint is checkable rather than remembered.
  - **More concurrency = more agents on more serial executors**, never a wider pool under one agent.
    Two threads over one agent means two `run_loop`s over one history.
  - The ceiling, when that day comes, is the inference server's own slot count (llama.cpp's
    `--parallel`); past it requests just queue inside the server, buying latency variance and no
    throughput.

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

### It is not the event queue — same mechanism, opposite contracts

Both are "a thread pulling jobs off a queue". The *semantics* are what differ, and the semantics are
what counts:

| | Executor | Event queue / owner |
|---|---|---|
| Contract | `submit(block) → result`. A job runner. | "I own this state; post to mutate it." |
| State | **Holds none, by contract.** Must not touch anything but what is passed in. | Owning state *is* the point. |
| Blocking | Exists *to* block — LLM, tools, minutes. | Must **never** block. |
| Thread count | A free performance knob, precisely *because* it holds nothing. | Single-threaded by contract, not configuration. |

So the executor does not and cannot replace the owner — an executor makes no promise about state,
and asking it to keep one is how the pinned-pool trap above got created in the first place. They
compose: **turns are jobs on the executor; the events those jobs emit are posted to the owner** —
which is exactly the event-queue idea's stage 2 (*"the worker thread posts `Event`s instead of
calling the listener stack"*), unchanged.

Corollary: **the owner is the precondition for pool > 1**, not something the executor makes
unnecessary.

> **Both paragraphs above were wrong, 2026-08-28 — `D_no_event_queue`.** The safety never came from
> the executor *or* from an owner; it comes from the partition this idea itself introduced. `--turns`
> shipped with no owner thread.

### Implementation: concurrent-ruby, not hand-rolled

Settled 2026-08-28, and it earns its Gemfile paragraph (see the Gemfile for the full one). Ruby ships
no executor at all, so the alternative is hand-rolling a thread pool, a shutdown protocol and a
backpressure policy. Concretely taken: `SingleThreadExecutor` in the app, `ImmediateExecutor` in
specs, `#shutdown`, and `fallback_policy` / bounded queues if backpressure ever needs a vocabulary.
It is the first `Concurrent::` reference in the pikuri family — pikuri itself is stdlib `Mutex`
throughout, and Tuile already depends on the gem one layer down. **If the executor concept ever moves
*into* pikuri**, that repo faces this dependency question on its own terms; log it in
`../pikuri/DECISIONS.md`, don't assume this decision travels.

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

## What this does to the event-queue idea

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

> **Reversed, 2026-08-28 — `DECISIONS.md` `D_no_event_queue`.** Shipping this idea made the queue
> *moot*, not more necessary. The partition left each conversation single-writer on its own state,
> which retired every defect the queue was for; what stayed shared (the registry map, the
> broadcaster's subscriber list) is sink-shaped and keeps its own small lock. The "global, not
> per-session" ruling above survives, and is now the standing answer should shared state ever appear.

## Explicitly not doing

**Multi-user.** Settled above, and worth keeping the reasons written down because a web UI keeps
inviting the question: it collides with `D_schema_complete_config` (one config, one API key — one
bill, no per-user quota), with the loopback `--bind` posture (network exposure makes auth
load-bearing security rather than a convenience), with `D_per_shell_state_root`, and hardest with
`D_chat_only_entry_point` — the day an OS or code shell sibling exists, every user's tool calls would
run as the *same OS user*. One process per person, own port, own state root, is both cheaper and
safer, and `ideas/multi-process-locking.md` is where the one real consequence of that lives.
