# One event queue as the server's concurrency model

Today: N Puma request threads, one parked writer thread per open `GET /events`, one agent worker
thread, and Puma's own state-hook thread — all reaching into a handful of individually thread-safe
objects (`Transcript`, `Broadcaster`, `AgentRunner`'s mutex). Each class is defensible on its own;
the *system* is only correct if you hold every interleaving in your head at once. That does not
survive more state.

**The alternative: a single event-loop thread owns all mutation.** Every other thread becomes a
producer that posts a command. No locks, because there is nothing to lock — one thread touches the
state. Tuile's `EventQueue` already states the thesis in its own rdoc: *"all UI-related updates run
from the thread which runs the event queue only; this removes any need for locking and/or need for
thread-safety mechanisms."*

## Two questions, settled

**Per *conversation* — not per session, and not global for much longer.** The partition unit is the
thing that owns state, and that is neither the process nor the browser: it is the conversation.
`ideas/per-conversation-agents.md` settles this — a conversation gets its own agent, history,
transcript and worker thread; tabs address one by URL and browse freely. Today there is exactly one
resident conversation, so "global" and "per conversation" are the same object, which is the only
reason the question looked open.

Per-*session* stays wrong, but note the reason has changed. It is **not** "because state is
deliberately shared across tabs" — that half of `D_single_shared_conversation` is repealed. It is
that a browser session owns no server-side state worth a lock: an unsent draft, a scroll position and
a theme cookie all live in the browser, and the only thing the server needs per tab is *which*
conversation it is viewing, which is a URL, not a lock. Vaadin can partition per session because a
session there owns a whole component tree; here it owns nothing.

A partitioned design is inevitably *hybrid*, and that is a cost to price rather than an oversight:
`Broadcaster`'s fan-out, the heartbeat, the `close` sentinel and `ConversationStore`'s folder stay
global however far this goes.

**"Event-queue vs locking" is a false dichotomy — there are three options, and today's problem is
the *fine-grained* part, not the locking part.** The `SseListener` exhibit below is a complaint
about per-object locks; both (b) and (c) collapse its three-class argument to one clause.

- **(a) One lock per object** — today. `Transcript`'s mutex, `Broadcaster`'s mutex, `AgentRunner`'s
  `@mutex`, and cross-object consistency held together by a discipline nothing enforces.
- **(b) One coarse lock over the state graph** — the Vaadin model minus the session axis. The
  transcript, the listener's per-turn state, the live conversation and the agent sit behind one app
  lock; per-object mutexes come out.
- **(c) One owner thread plus a queue** — Tuile. No locks at all on the owned state.

**Recommendation: (c) is the destination, (b) is a cheap step that is not wasted, and neither is the
next commit** (see *When not to do this*, which still holds).

Why (b) is not wasted work if it happens first: it is mostly *deletion*, it changes not one route
signature, and (c) later replaces "take the app lock" with "post to the owner" mechanically — the
expensive half of both changes is the same, namely naming the state graph and giving it one owner.

Why (b) is not sufficient: the coarse lock must be released across the LLM call and across tool
execution, so you still reason about *where* mid-turn the graph is consistent. That is precisely the
interleaving reasoning (c) eliminates. Vaadin lives with exactly this and it is a known bug source
there — hold the session lock across a slow call and the UI freezes; call `access()` from the wrong
side and you deadlock.

## What the neighbours do, and why Sinatra has no answer

Worth writing down, because the absence of guidance is itself the finding.

- **Sinatra offers nothing.** It is a routing DSL over Rack: no concurrency model, no session lock,
  no server-side state model. `session` is a signed cookie, so there is nothing to lock. The only
  built-in coarse lock is `Rack::Lock`, a single mutex around the whole app — Vaadin's coarse lock
  with no session axis — which exists to run non-thread-safe apps under threaded servers and is
  regarded as a legacy throughput disaster.
- **Mainstream Rack/Rails practice is to not have this problem**: stateless process, shared mutable
  state in Postgres/Redis, the database's transactions doing the locking, threads sharing only
  immutable config.
- **So this app is the outlier, and that is why the folklore is missing.** A live in-memory object
  graph plus a worker thread is structurally a desktop app that speaks HTTP. The precedents are
  Tuile / Swing / Vaadin, not Sinatra — which is the real reason cribbing Tuile's design is the
  serious option rather than a terminal-UI curiosity.
- **Vaadin's `UI.access()` is already this idea.** A background thread never touches the component
  tree; it *posts* a command that runs under the session lock. The lock is the enforcement
  mechanism; single ownership is the design. Vaadin is not the counterexample to a queue — it is the
  same design with a lock instead of a dedicated thread. What does not transfer is the session axis;
  what does transfer, and what this project currently lacks, is *coarseness*: one lock for the whole
  graph, deliberately, not one per component.

## The current model is already past comfortable — one concrete exhibit

`SseListener` **keeps unguarded per-turn streaming state**, and it is fed both by the agent worker
thread and, during `load_conversation`, by a Sinatra request thread. What makes that safe today is an
argument spanning three classes: `AgentRunner` refuses a switch while busy (409), holds `@mutex`
across the whole replay, and no loop can be emitting while it does. Nothing in `SseListener` says
any of this; the guarantee lives in `AgentRunner#load_conversation`'s rdoc. It is correct, and it is
exactly the kind of correctness that quietly stops being true when someone adds a fourth caller.

With one loop thread, that entire argument collapses to "it runs on the loop thread."

## Shape

- **One loop thread**, started by `bin/pikuri-web-chat`, owning: the transcript, the listener's
  per-turn state, which conversation is live, and the decision to emit SSE frames.
- **Mutating routes become producers** — but only two of them can be fire-and-forget; see the route
  audit below.
- **Reads take a published snapshot, not a reply.** Also below — this is the correction that deletes
  a whole stage.
- **The agent worker thread stays** (`D_worker_thread_agent_loop` is not repealed). It must: the loop
  blocks on the LLM and on tools for minutes, so running it on the queue thread freezes the server.
  The change is the direction of the call — today the agent thread reaches into
  `SseListener` → `Transcript` → `Broadcaster`; with a queue it *posts* its events and the loop
  thread renders them.
- **The per-connection SSE queues stay too.** The loop must never write to a socket — one slow client
  would stall every other tab. Loop → per-connection queue → parked writer thread is already
  `Broadcaster`'s design, and it is already right.
- **`Broadcaster` keeps its own mutex, under (b) *and* (c).** Do not fold it into the owned state.
  Its lock guards the subscriber list, which request threads touch on `subscribe` / `unsubscribe`
  and which Puma's `:state, :stop` hook clears. Behind one app lock, a new tab's `/events` subscribe
  would contend with the agent's rendering, and the shutdown path would queue behind whatever a
  wedged turn is holding — the exact parked-thread hazard `D_shutdown_on_state_stop` exists to
  prevent. It is a *sink*, and it stays one.

### Route audit: three of five mutating routes need an answer

The file used to say the mutating routes "post a command and return 204 without waiting". Checked
against `app.rb`, that is already true for two and impossible for three:

- `POST /messages` and `POST /cancel` **already** answer bare 204 — the browser needs nothing back,
  rendering arrives over SSE. These are free.
- `POST /conversations`, `POST /conversations/:id/select` and `POST /conversations/:id/delete` exist
  in part to **report refusal**: 409 busy, 422 unreadable, 500 undeletable, 404 unknown. The no-JS
  path then wants a 303 back. So they need request/reply with a bounded wait, at *stage one* rather
  than stage three — or the busy-refusal moves to the client, which is a behaviour change that
  `D_delete_no_undo`'s "both refuse while busy" and the 303 fallback both lean on.

That is the real cost of the queue, and it lands earlier than the staging below used to imply.

### Reads: publish an immutable snapshot, don't reply

`GET /` and `GET /conversations` do **not** need to post a request and block. Make the transcript's
block list an immutable array that the owner *replaces* wholesale per mutation, and let readers grab
the current reference. Reference assignment is atomic under the GVL, so a reader takes no lock, never
blocks, and cannot wedge behind the loop. That deletes the entire bounded-wait / 503 path for reads,
which was the ugliest part of stage three.

Two bonuses:

- **It fixes a real tear.** `App#conversation_rows` today reads `runner.conversation` and then
  `conversations.list` as two separately-locked ops with a gap; its comment reasons carefully about
  the first one blocking on the switch, which does not make the *pair* consistent. One snapshot is
  one consistent answer.
- **It is orthogonal, so it pays under (b) too**: writers take the coarse lock, readers take nothing.

Cost: one array allocation per delta, at 15 fps, over a few hundred blocks. Nothing.

## Hard constraints, each from an existing decision or a real hazard

- **The loop thread must never block.** Not on I/O, not on a socket, not on a lock, and never on a
  reply from a thread that might be waiting on it. This is the one rule that, if broken, turns the
  whole design from "easy to reason about" into a deadlock hunt.
- **Bounded waits on the reply path.** Reads escape this via snapshots, but the three refusing routes
  do not. A request thread blocking forever on a wedged loop exhausts Puma's pool and takes the
  server down instead of one route. Every reply gets a timeout and a 503.
- **Backpressure has asymmetric answers.** Blocking a *request* thread on a full queue is fine;
  blocking the *agent* thread stalls the turn, and blocking Puma's `:state, :stop` hook recreates the
  exact parked-thread bug `D_shutdown_on_state_stop` exists to prevent. So: unbounded, or bounded
  with a documented drop policy for the non-blockable producers.
- **Shutdown is part of the design, not an afterthought.** The loop is closed from the same
  `:state, :stop` hook that closes the `Broadcaster`, and must exit *before* Puma's unbounded
  graceful wait. Nothing in the exit path may rely on `at_exit` (`D_shutdown_on_state_stop`).
- **Posted commands should be frozen.** Tuile's `post` asks for this explicitly; an unfrozen object
  crossing the boundary is shared mutable state smuggled past the model.

## Where rendering runs — the one thing to measure

`D_rerender_and_replace` re-renders the whole accumulated message through kramdown per delta, rate
limited to 15 fps. On the loop thread that competes with `POST /cancel` for responsiveness. A 2 KB
message is nothing; a 50 KB one re-parsed fifteen times a second may not be.

Escape hatch if it measures badly: **the loop owns state mutation, but pure rendering need not run
on it.** Markdown → HTML is a pure function of the accumulated source, so it can stay on the agent
thread and post the finished HTML string. Worth knowing the option exists before committing.

Also worth a look: Tuile's `tick_fps(15)` fires on the loop thread, which is the natural home for the
coalescing that `Listener::RateLimited` does today. Might collapse two mechanisms into one — or might
be a layer violation, since the rate limiter is pikuri's. Undecided.

## Build it in stages, not as a big bang

0. **Optional but cheap: collapse to one coarse lock (option (b)).** Delete `Transcript`'s mutex,
   promote `AgentRunner`'s `@mutex` to the app lock, hold it across the listener path,
   leave `Broadcaster` alone. Retires the `SseListener` exhibit on its own, touches no route, and is
   a strict subset of the work stages 1–2 need anyway. Skip it only if the queue is going in
   immediately.
1. **Conversation lifecycle first** — submit / cancel / new / select / delete move onto the loop,
   replacing the app lock. Self-contained, and it is where the mutating routes already are. Carries
   the request/reply-with-timeout machinery, because select / delete / new must still refuse.
2. **Agent events second** — the worker thread posts `Event`s instead of calling the listener stack.
   This is the one that retires the `SseListener` unguarded-state argument above.
3. **Reads, via snapshots** — `Transcript` publishes an immutable list; `GET /` and
   `GET /conversations` read a reference and take no lock. Smaller than the old stage three, and it
   is the one stage that could equally well go first.

Each stage leaves the app working, which is the only reason a change this wide is affordable.

## What this supersedes and reorders

- **`ideas/conversation-store-locking.md` is the interim answer, and this idea eats it** — under (b)
  as much as under (c). A `Monitor` on the store is dead weight whether one thread does all the
  mutating or one lock covers all of it. Take only the `row` TOCTOU fix, which is about a *second
  process* and survives either way.
- **`ideas/per-conversation-agents.md` comes *first*, and this reordering is a reversal.** The old
  reading — queue first, background turns on top — assumed the queue would own global state. It
  won't: per-conversation agents is a settled direction, so there is no point building a global owner
  for state that is about to stop being global. Build the partition, then give each partition an
  owner. The one piece worth extracting early is the snapshot-read design, which is orthogonal to
  both.
- **Two decisions need amending, not quiet edits.** `D_worker_thread_agent_loop`'s second half —
  *"thread-safety lives in the sinks, not in their callers"* — is reversed **for the transcript and
  the listener**, and **retained for the `Broadcaster`**, which stays a self-guarding sink. Say it
  that precisely; a flat "this reverses it" would licence folding the broadcaster in.
  `D_server_authoritative_transcript` gains "…and exactly one thread mutates it".

## Implementation options

- **Hand-rolled on stdlib `Queue`** — the loop is `while (cmd = queue.pop)`, plus a latch for
  replies. Maybe 80 lines. No new dependency, and stdlib `Queue` is already the `Broadcaster`'s
  primitive.
- **Crib Tuile's design.** Its API is the right one and battle-tested in a real app: `post`,
  `submit(&block)`, `await_empty`, `tick` / `tick_fps`, `run`, `stop`. The one gap for us is
  request/reply — nothing there returns a *value* to the caller, which the three refusing routes
  need.
  - **`await_empty` is a genuine testability win, but a partial one — don't oversell it.** Two spec
    files hand-roll the same deadline-plus-`sleep 0.005` spinner (`agent_runner_spec.rb:86`
    `wait_until`, `conversation_flow_spec.rb:62` `run_turn`). `await_empty` deterministically
    retires the *render* half of that race — "has everything posted been applied". It cannot retire
    the *turn* half: the worker thread still blocks on the LLM outside the queue, so a
    `wait_until { !runner.busy? }` equivalent survives. One of the two waits goes away, not both.
- **Depend on Tuile.** No: dragging a terminal-UI gem into a web app to get a queue.
- **Extract Tuile's queue into a shared gem.** The tempting one, and not ours to decide — that is a
  pikuri-family conversation and would be logged in `../pikuri/DECISIONS.md`, not here.

`concurrent-ruby` would earn its Gemfile paragraph *here* if anywhere: latches, atomics and the
shared timer thread are what Tuile actually pulls it for. That is a better justification than the
lock it was originally proposed for. Note the snapshot-read design needs no atomic reference — plain
reference assignment under the GVL is enough — so it does not add to the case.

## When not to do this

Right now there are five mutating routes and one worker thread, and the whole discipline fits in one
rdoc paragraph. The triggers that make the queue pay for itself:

- a **second agent** — always the strongest one, and as of 2026-08-28 it has fired *in principle*:
  `ideas/per-conversation-agents.md` commits to one agent per conversation. It fires *in code* when
  that idea's stage 2 lands, and the two should be designed together — per-conversation ownership is
  what a per-conversation queue is for;
- **more server state** than the transcript and the live conversation: a search index, generated
  titles, background jobs, anything with a cache to invalidate;
- the day the `SseListener` argument above needs a fourth clause.

So this is no longer "the direction, not the next commit" — it is the second half of a change already
decided. But it still must not go first. Two pieces are worth taking early because they are
orthogonal to the partition and pay off either way:

- **the snapshot reads**, which stand alone and fix a real tear in `conversation_rows` today;
- **option (b)'s deletions** — dropping `Transcript`'s mutex in favour of one owner — but only for
  the *live* conversation, and only if per-conversation agents is more than a sprint away. Doing (b)
  globally and then re-partitioning it would be work done twice.
