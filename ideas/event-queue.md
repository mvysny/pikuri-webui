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
- **Routes become producers.** `POST /messages` / `/cancel` / `/conversations` /
  `:id/select` / `:id/delete` post a command and return 204 without waiting. `GET /` and
  `GET /conversations` need an answer, so they post a *request* and block on a reply.
- **The agent worker thread stays** (`D_worker_thread_agent_loop` is not repealed). It must: the loop
  blocks on the LLM and on tools for minutes, so running it on the queue thread freezes the server.
  The change is the direction of the call — today the agent thread reaches into
  `SseListener` → `Transcript` → `Broadcaster`; with a queue it *posts* its events and the loop
  thread renders them.
- **The per-connection SSE queues stay too.** The loop must never write to a socket — one slow client
  would stall every other tab. Loop → per-connection queue → parked writer thread is already
  `Broadcaster`'s design, and it is already right.

## Hard constraints, each from an existing decision or a real hazard

- **The loop thread must never block.** Not on I/O, not on a socket, not on a lock, and never on a
  reply from a thread that might be waiting on it. This is the one rule that, if broken, turns the
  whole design from "easy to reason about" into a deadlock hunt.
- **Bounded waits on the reply path.** A request thread blocking forever on a wedged loop exhausts
  Puma's pool and takes the server down instead of one route. Every reply gets a timeout and a 503.
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

1. **Conversation lifecycle first** — submit / cancel / new / select / delete move onto the loop,
   replacing `AgentRunner`'s `@mutex`. Self-contained, and it is where the mutating routes already
   are.
2. **Agent events second** — the worker thread posts `Event`s instead of calling the listener stack.
   This is the one that retires the `SseListener` unguarded-state argument above.
3. **Reads last** — `GET /` and `GET /conversations` become reply-commands, and the remaining locks
   come out of `Transcript` and `Broadcaster`.

Each stage leaves the app working, which is the only reason a change this wide is affordable.

## What this supersedes and reorders

- **`ideas/conversation-store-locking.md` is the interim answer, and this idea eats it.** Locks *or*
  an event queue, not both — a lock on `ConversationStore` is dead weight once one thread does all
  the mutating. Do the lock only if the queue is far off; if the queue is next, skip it and take the
  `row` TOCTOU fix (which is about a *second process* and survives either way).
- **`ideas/background-turns.md` probably depends on this.** N conversations with N agents is the
  scenario that kills the single-writer discipline outright, and the queue is what makes it
  tractable. That reorders the two: queue first, background turns on top.
- **Two decisions need amending, not quiet edits.** `D_worker_thread_agent_loop`'s second half —
  *"thread-safety lives in the sinks, not in their callers"* — is precisely what this reverses.
  `D_server_authoritative_transcript` gains "…and exactly one thread mutates it".

## Implementation options

- **Hand-rolled on stdlib `Queue`** — the loop is `while (cmd = queue.pop)`, plus a latch for
  replies. Maybe 80 lines. No new dependency, and stdlib `Queue` is already the `Broadcaster`'s
  primitive.
- **Crib Tuile's design.** Its API is the right one and battle-tested in a real app: `post`,
  `submit(&block)`, `await_empty` (**the testability win — deterministic specs with no `sleep`
  polling**), `tick` / `tick_fps`, `run`, `stop`. The one gap for us is request/reply — nothing there
  returns a *value* to the caller, which `GET /` needs.
- **Depend on Tuile.** No: dragging a terminal-UI gem into a web app to get a queue.
- **Extract Tuile's queue into a shared gem.** The tempting one, and not ours to decide — that is a
  pikuri-family conversation and would be logged in `../pikuri/DECISIONS.md`, not here.

`concurrent-ruby` would earn its Gemfile paragraph *here* if anywhere: latches, atomics and the
shared timer thread are what Tuile actually pulls it for. That is a better justification than the
lock it was originally proposed for.

## When not to do this

Right now there are five mutating routes and one worker thread, and the whole discipline fits in one
rdoc paragraph. The triggers that make the queue pay for itself:

- a **second agent** (background turns, parallel turns) — the strongest one;
- **more server state** than the transcript and the live conversation: a search index, generated
  titles, background jobs, anything with a cache to invalidate;
- the day the `SseListener` argument above needs a fourth clause.

Until one of those, this is the direction, not the next commit.
