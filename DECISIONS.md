# DECISIONS.md

A living record of the design decisions behind pikuri-web — especially
the *roads not taken*. It exists because the graduation pipeline (see
[`AGENTS.md`](AGENTS.md)) had no home for one fact class: a rejected
alternative. Both candidate homes refuse it on their own stated terms —
a source file's YARD header explains the class *as it is* to someone
reading that class, and gains nothing from an argument against a design
that never shipped; and `AGENTS.md` is pulled into *every* session's
context by `CLAUDE.md`, so rationale parked there is paid for on every
turn. This file is the lazy side of that split: never context-loaded,
read only when someone asks "why this way?".

It is the *why-we-chose* record. It is not the *how-it-works* reference
(the YARD headers), the *what-you-must-not-break* list (`AGENTS.md`), or
the user-facing promise (`README.md`). An entry links out rather than
restating.

**Boundaries** — the ones that keep this from becoming a second copy of a
neighbour:

- **vs. `AGENTS.md`.** That file is context-loaded and holds the
  *invariant*: the rule a future change must not break, stated flat, with
  a `See D_<slug>` pointer. This file holds the argument behind it — the
  alternatives, the measurements, the consequence a contributor would
  trip over. One line there, the reasoning here; never two half-answers.
- **vs. the YARD headers.** A header describes its class as it is, for
  someone about to change that class. It keeps the local contract
  ({Transcript}'s thread-safety, {StreamingMessage}'s lifecycle). Only
  the *fork* comes here.
- **vs. `README.md`.** That file is the front door: what the app is,
  the chat-only trifecta promise, how to run it. Why the promise was
  drawn there rather than somewhere else is an entry here.
- **vs. pikuri's own `DECISIONS.md`** (`../pikuri/DECISIONS.md`). This
  project owns the web shell and nothing else, and the same split applies
  to the decision log: a fork inside the agent loop, a tool, the
  Interloper's delivery boundary, LLM transport — that is logged
  upstream, and an entry here cites it rather than re-arguing it. What
  belongs here is the shell's own forks, prominently including *what we
  deliberately did not port* from pikuri-tui.

**Format.** One entry per decision. The ID is a slug, not a number:
`D_` plus a 1–4-word snake_case hint at the subject
(`D_rerender_and_replace`), so a citation carries meaning on its own.
The `(date)` on the heading is *decided* provenance, not a log position —
git owns the edit history, so don't narrate how an entry used to read.
Keep each entry tight: context, the decision, the alternatives rejected
and why, and the consequences a future contributor would trip over. A
decision is worth logging the moment it's *made*; implementation can lag
(the `Status:` line says which).

**No entry without a real fork.** If nothing was seriously considered and
rejected, it isn't a decision — it's how the thing works, and that's the
YARD header. This is the guard against a diary.

**Newest first.** Entries run reverse-chronologically by decided date, so
a scan hits recent decisions first.

**Never read wholesale.** `grep '^## D_' DECISIONS.md` is the index;
there is no ToC (same discipline as `ls ideas/`). Cite an entry by slug.
Grep tripwire: every `D_<slug>` referenced anywhere in the repo must
exist as a `^## D_` heading here.

**Entries are mutable — edit in place, don't append addendums.** Each
entry is the single coherent home for one *live* decision; keep it
current as the decision is refined or extended. Two things this does
*not* license:

- **The roads-not-taken stay.** "We chose X, rejected Y because Z" is
  live content of the current decision, not stale history — never edit it
  away. It's the most valuable thing in the file.
- **A reversed *shipped* decision forks a tombstone, it is not
  overwritten.** When a design was tried, shipped, and then thrown away,
  leave the old entry as the scar, set its `Status:` to **Superseded by
  `D_<slug>`**, and write the replacement fresh. The line: *refined or
  extended* → edit in place; *reversed after shipping* → tombstone + new
  entry.

**Backfill is opportunistic.** Rationale that already sits inline in a
YARD header or in `AGENTS.md`'s **Scope decisions** stays put — this file
is the home going *forward*. Move an old one only when you're already
editing that doc and the inline reasoning is crowding out the live
design or the invariant.

---

## D_no_multi_process_lock — A second process against one state root is a user mistake, not a supported configuration; last-writer-wins stands (2026-08-28)

**Status:** Accepted 2026-08-28. Nothing to ship: this is a decision *not*
to build a cross-process lock. The idea file that argued for one is
graduated into this entry.

**Context.** Two `pikuri-web-chat` processes on different ports share
`~/.local/state/pikuri/pikuri-web-chat/conversations/`, and pikuri's
`History#save` rewrites `history.json` whole. The failure is *not* a torn
file — the save is temp-file-and-rename, so what is on disk is always a
complete valid history. It is a **silently clobbered conversation**: the
loser's turns vanish at the next save with nothing on screen to say so.
Since `D_delete_no_undo` there is a worse shape of it — process A deletes
a folder that process B still holds live, B writes it straight back at its
next turn end, and a conversation the user explicitly confirmed away
reappears in the sidebar.

**Decision.** Accept all of it. Last-writer-wins, no `flock`, no
enforcement anywhere; `README.md` states the limitation under
**Conversations** and that is the whole of the answer.

What settles it is that the second process **buys nothing**. One process
already serves any number of tabs, and a conversation owns its own agent
so turns in different conversations run undisturbed side by side
(`D_conversation_owns_agent`, `D_serial_turn_executor`) — there is no
capability behind a second port, only a second copy of the same
single-user tool pointed at the same home. A failure mode reachable only
by a configuration with no reason to exist does not earn a mechanism.

**Rejected: `flock` the conversation directory on open,** rendering the
locked row read-only in the sidebar. It is the *right* shape if the
collision were worth defending against — a dimmed row with a reason is the
affordance the busy-refusal already uses — but it puts per-conversation
lock state in `ConversationStore`, and file locks are the kind of state
that turns a hard kill into "why can't I open my own conversation".
Permanent cost, hypothetical benefit.

**Rejected: one `flock` on the state root at boot,** refusing a second
instance with `--port` named in the error. The cheap version — one lock in
`bin/pikuri-web-chat` instead of per-conversation state — and it kills the
failure outright rather than degrading it. Still rejected: it converts a
mistake nobody makes into a startup failure everybody can hit (a stale
lock after `kill -9`, a supervisor restarting faster than the old process
exits), and it forbids the one second instance that is harmless, the one
that never opens the same conversation. Refusing to start is a worse
default than a warning in the README.

**Consequences.**

- The resurrection under `D_delete_no_undo` is now decided rather than
  deferred: it stays, and that entry's pointer resolves here.
- `ConversationStore` never grows cross-process consistency. Its atomic
  rename remains all a concurrent reader outside this process gets, and
  the in-process locking question (`ideas/conversation-store-locking.md`)
  is independent of this entry — an in-process lock never bought anything
  across processes anyway.
- **The one trigger that reopens this: a shared state root.**
  `D_per_shell_state_root` deliberately keeps each shell's conversations
  under its own folder, so today's only colliders are two copies of *this*
  shell. If a location shared with pikuri-tui or another shell ever lands,
  the colliders become processes a user has every reason to run at once,
  and the argument above stops holding. Locking is then part of that
  change, not a separate idea.

## D_no_event_queue — No owner thread: state is partitioned per conversation, browser state stays in the browser, and anything genuinely shared gets *one global* mechanism (2026-08-28)

**Status:** Accepted. Nothing to ship: this is a decision *not* to build
the owner thread that was on the roadmap. The idea file that argued for it
graduated into this entry.

**Context.** The standing plan was to give all mutable state a single
owner thread, Tuile-style: every other thread posts a command, no locks,
because one thread touches the state. The complaint driving it was real —
`Transcript`, `Broadcaster` and `AgentRunner` each held their own lock, and
cross-object consistency rested on a discipline nothing enforced. The idea
file names three options: **(a)** one lock per object, today's shape;
**(b)** one coarse lock over the whole state graph, Vaadin minus the
session axis; **(c)** one owner thread plus a queue, Tuile.

By the time the question came back, `D_conversation_owns_agent` had
shipped, and it had already answered most of it. The exhibits (b) and (c)
existed to fix were audited one by one and had gone:

- **The `SseListener` unguarded per-turn state.** It was safe only by an
  argument spanning three classes, and `AgentRunner#load_conversation` held
  it. That method no longer exists: a runner *is* its conversation, one
  listener per runner, and `#restore!` runs inside the registry's monitor
  before the runner is published. The argument is now "one conversation,
  one writer".
- **The `conversation_rows` tear.** `ConversationRegistry#rows` reads the
  listing and the busy flags inside one monitor. One consistent answer.
- **The refusal routes needing request/reply with a bounded wait.** The
  audit assumed three. `select` is gone with the live pointer, `POST
  /conversations` refuses nothing, and only `delete`'s 409 is left —
  the queue's most expensive machinery, built for one route.
- **The pool-1 precondition.** The file's closing claim was that an owner
  thread is what unlocks more than one turn at a time. Checked and false;
  see `D_serial_turn_executor`'s amendment.

**Decision.** Three parts, and the third is the one with a future in it.

**No owner thread, and no coarse lock either.** The partition does the
work: one agent, one history, one transcript and one listener per
conversation, and a conversation admits one turn at a time
({AgentRunner#submit} injects rather than starting a second). Per-object
locks survive where they guard genuinely shared things — the registry's
monitor over the resident map, the broadcaster's over the subscriber list
— and each now guards one small thing with a stated owner, which is not
the failure the idea file opened by describing.

**This is a single-user server, and each browser owns its own state.**
No sessions, no auth, no accounts; a second person runs their own process
under their own OS account. What a tab holds — an unsent draft, scroll
position, the theme cookie, and *which* conversation it is reading — lives
in the browser and in the URL. Two tabs may read different conversations,
or the same one, and neither disturbs the other. The server holds the
conversations; the browser holds the view of them.

**If server state ever does become genuinely shared, it gets one global
mechanism — a single event queue, or a single lock — and never a
per-session one.** Stated now because the tempting wrong answer is
specific and has a famous precedent. Vaadin partitions its lock per
session because a session there owns a whole component tree; here a
session owns nothing, so a per-session lock would guard the empty set
while adding a session concept this app has deliberately refused. The
`Broadcaster` stays outside whatever is built, in either shape: it is a
sink, its lock guards the subscriber list that request threads and the
`:state, :stop` hook touch, and folding it in would put a new tab's
subscribe behind a running turn and the shutdown path behind a wedged one
— the exact parked-thread hazard `D_shutdown_on_state_stop` prevents.

**Why there is no guidance to crib, and what the real precedents are.**
Worth recording, because the absence is itself the finding. **Sinatra
offers nothing**: it is a routing DSL over Rack with no concurrency model
and no server-side state model — `session` is a signed cookie, so there is
nothing to lock — and its only coarse lock is `Rack::Lock`, one mutex
around the whole app, which exists to run non-thread-safe apps under
threaded servers and is regarded as a throughput disaster. **Mainstream
Rack/Rails practice is to not have this problem**: stateless processes,
shared mutable state in Postgres or Redis, the database's transactions
doing the locking. **So this app is the outlier**, which is why the
folklore is missing: a live in-memory object graph plus a worker thread is
structurally a desktop app that speaks HTTP, and its precedents are Tuile,
Swing and Vaadin rather than Rails. That is also why "one global queue" and
"one global lock" are the same decision wearing different clothes —
Vaadin's `UI.access()` *is* this design, a background thread posting a
command instead of touching the tree, with a lock as the enforcement
mechanism where Tuile uses a dedicated thread. What does not transfer from
Vaadin is the session axis; what does is the *coarseness*.

**Rejected: build it anyway, because the current model is past
comfortable.** The honest form of the pro-queue case: it was a good
argument, and true when written. It loses to having each of its exhibits
checked and found already fixed. Rebuild the case from *live* defects if it
comes back — the old examples are spent.

**Rejected: option (b), one coarse lock, as a cheap step toward (c).** It
was cheap, and mostly deletion. But it buys nothing once the state is
partitioned — it would re-coarsen a graph that was just split, putting one
conversation's kramdown pass behind another's — and its own file admits
the lock must be released across the LLM call and across tool execution,
which is the interleaving reasoning it was meant to remove.

**Rejected: a per-session lock or a per-session queue, Vaadin-style.** See
above; recorded as a rejection rather than an omission because it is what
a reader who knows Vaadin will reach for first.

**If one is ever built, these are the constraints** — the surviving half
of the graduated idea file, kept because they were derived from this app's
existing decisions and would otherwise be rediscovered by hitting them.

- **The owner must never block.** Not on I/O, not on a socket, not on a
  lock, and never on a reply from a thread that might be waiting on it.
  Break this one and the design stops being "easy to reason about" and
  becomes a deadlock hunt.
- **The agent loop still gets its own thread** — it blocks on the LLM and
  on tools for minutes, so running it on the owner freezes the server
  (`D_worker_thread_agent_loop`). The change is the *direction*: it posts
  events rather than calling the listener stack inline.
- **Per-connection SSE queues stay.** The owner must never write to a
  socket; one slow client would stall every tab. Owner → per-connection
  queue → parked writer thread is already {Broadcaster}'s shape, and it is
  already right.
- **Every reply path gets a bounded wait and a 503.** A request thread
  blocking forever on a wedged owner exhausts Puma's pool and takes the
  whole server down instead of one route. Reads can escape this entirely
  by publishing an immutable snapshot instead of replying — the trick
  {Transcript} already uses.
- **Backpressure has asymmetric answers.** Blocking a *request* thread on a
  full queue is fine; blocking the *agent* thread stalls a turn; blocking
  Puma's `:state, :stop` hook recreates the exact parked-thread bug
  `D_shutdown_on_state_stop` exists to prevent. So: unbounded, or bounded
  with a documented drop policy for the producers that cannot block.
- **Shutdown is part of the design.** Close the owner from the same
  `:state, :stop` hook that closes the broadcaster, before Puma's unbounded
  graceful wait. Nothing in the exit path may rely on `at_exit`.
- **Posted commands should be frozen** — an unfrozen object crossing the
  boundary is shared mutable state smuggled past the model.
- **Measure where rendering runs before committing.**
  `D_rerender_and_replace` re-renders the whole accumulated message through
  kramdown per delta at 15 fps; on the owner that competes with `POST
  /cancel` for responsiveness, and a 50 KB message may not be free. The
  escape hatch is that the owner owns *mutation*, not rendering: markdown →
  HTML is a pure function of the accumulated source, so it can stay on the
  agent thread and post the finished string.
- **Build it on `concurrent-ruby`, or hand-roll on stdlib `Queue`** (~80
  lines: `while (cmd = queue.pop)` plus a latch for replies). Tuile's API
  is the right shape to crib — `post`, `submit(&block)`, `await_empty`,
  `tick_fps`, `run`, `stop` — with one gap: nothing there returns a value
  to the caller, which the refusing route needs. Do **not** take a
  dependency on Tuile to get it; extracting its queue into a shared gem is
  a pikuri-family conversation, logged in `../pikuri/DECISIONS.md`, not
  decided here.

**Consequences.**

- **The triggers to reopen are named, and none has fired.** More server
  state than the transcript and the resident runners — a search index,
  generated titles, a cache to invalidate — or a second writer to one
  conversation. Raising `--turns` is *not* one of them.
- **The snapshot-read design was taken, minus the queue.** {Transcript}'s
  `Block` is a `Data`, so `#update` replaces rather than mutates and a
  caller rendering a snapshot cannot have a block rewritten underneath it.
  That was the one piece of the idea that stood on its own.

## D_conversation_owns_agent — A conversation owns its agent; a tab owns which conversation it views (2026-08-28)

**Status:** Accepted, shipped 2026-08-28. {ConversationRegistry} holds one
{AgentRunner} per conversation opened — its own `Agent`, `Interloper`,
`Cancellable`, `TokenLog`, {Transcript} and {SseListener} — and
{Broadcaster} addresses frames per conversation.

**Context.** Everything before this had *one* agent and one transcript, so
"which conversation is live" was server state and every tab followed it
(`D_single_shared_conversation`). That model has no precedent in any web
app: it is tmux in a browser. Slack is the counter-example — its channel
selection lives in the URL, and the session exists only for auth. A tab
should be free to read one conversation while another works.

**Decision.** A runner *is* a conversation, for its whole life. No
switching, no live pointer. `GET /c/:id` opens one, minting and replaying
its history on first visit; the tab's EventSource subscribes to that id;
`POST /messages` and `POST /cancel` both name their conversation. What
falls out is worth naming, because it is most of the value:

- **The whole switch machinery went away** — `new_conversation`,
  `load_conversation`, `delete_conversation`, and the ordering hazard where
  a `Reset` emitted before the live pointer moved got stamped with the
  outgoing conversation.
- **Nothing refuses because something *else* is busy.** Only delete
  refuses, and only for the conversation actually in flight.

**Rejected: minting a runner only on first *send*, viewing from a
throwaway replay.** Cheaper in memory, and it was what shipped one commit
earlier. Dropped because a tab reading a not-yet-resident conversation
would then apply frames whose block ids agree with its snapshot only
because both replay the same events into a fresh {Transcript} — correct by
an argument spanning two classes, which is the kind of thing this codebase
keeps trying to delete. Minting on view costs one agent per conversation
*opened in a session*, which for a single user is nothing.

**Rejected: reaping idle runners.** Nothing is ever dropped except on
delete. Add reaping if residency ever actually hurts; a cleverer minting
rule is the wrong lever.

**Rejected: device continuity, and it was never wanted.** Mirroring's one
apparent benefit was that every browser showed the same conversation, so
opening the iPad landed you where the desktop was. Independent browsers
are the *goal*, not the price: two tabs reading two conversations is the
feature, and a view that follows you between devices is the same
behaviour wearing a friendlier name. So this is not a cost to be paid
back later — do not reintroduce global selection state to buy it. If some
future ask genuinely needs a landing spot better than "the newest
conversation" ({ConversationRegistry#default}), it is a per-browser
`last_viewed` cookie on the `D_theme_cookie` precedent, which leaves other
tabs alone; server-side last-viewed is this decision reversed.

**Consequences.**

- The registry and {ConversationStore} are now the only genuinely shared
  mutable state. The registry has a `Monitor`; the folder's own
  consistency is still open (`ideas/conversation-store-locking.md`).
- `HistoryReplay.snapshot` became dead code and was removed.
- Rendering a detached conversation is not optimized: the
  accumulate-don't-render idea only pays at `--turns` > 1, which
  `D_serial_turn_executor` now allows but does not default to. If it is
  ever built, the choice is already made and the two losing readings are
  why. *Render always, fan out selectively* (what ships today) re-runs
  kramdown at 15 fps for a conversation nobody is watching — the single
  most expensive thing the server does, per `D_rerender_and_replace`.
  *Drop the transcript and replay on attach* is cheapest while detached
  but shows a hole where the streaming answer is, because `history.json`
  holds no in-flight partial message. **Accumulate, don't render** wins
  by keeping the {StreamingMessage} appends and the block structure while
  skipping the kramdown pass and the broadcast, then rendering once on
  attach — which works because `D_rerender_and_replace` already makes the
  HTML a pure function of the accumulated source, so it defers as easily
  as it moves threads. Open when it is picked up: whether
  `Listener::RateLimited`'s 15 fps timer should be wired at all for a
  detached conversation. Probably not, but it is pikuri's class — check
  whether a listener stack can be rebuilt mid-life before assuming.

## D_serial_turn_executor — Turns run on one shared executor, whose pool size is the inference server's slot count (2026-08-28)

**Status:** Accepted, shipped 2026-08-28 as a `Concurrent::FixedThreadPool`
sized by `--turns` (default 1), injected into every {AgentRunner}.

**Context.** A turn blocks on the LLM for minutes, so it cannot run on a
Sinatra request thread (`D_worker_thread_agent_loop`). Once conversations
own their own agents, "how many turns at once" stops being implied by
"how many agents".

**Decision.** One process-wide executor shared by every runner. Its queue
*is* the admission gate: submitting always succeeds, and a turn waiting for
a free slot reports `:queued` rather than being rejected. Cancelling a
queued turn needs nothing from pikuri — the job checks a flag on entry and
returns without starting.

**The pool size caps concurrent turns, and nothing else depends on it.**
It exists so turns do not outnumber the inference server's parallel slots
— match it to llama.cpp's `--parallel`. It is an operator setting about
load, with no correctness claim resting on it.

**Rejected: pinning the pool at 1 as a correctness precondition.** The
position this decision was first taken with, and the one to expect back —
it is what the abstraction invites. The argument was that an `Executor`'s
contract is `submit(block) → result`, a job runner that holds no state by
design, so single-writer safety at pool 1 is a property of *that number*
rather than of the abstraction, and would evaporate silently when someone
raised it. The premise is correct and worth keeping: **never rest a
correctness claim on a pool size.** The conclusion was not, because the
executor was not carrying single-writer safety in the first place. Raising
the pool was said to put two agents in two places at once — the
conversations folder, and pikuri's shared tool constants. Both were audited
when `--turns` was added, and neither holds.

- **The folder.** Two turn-ends write two *disjoint subdirectories*.
  {ConversationStore#save} touches only that one conversation's directory —
  `history.json` and `meta.json` both, each through a sibling temp file and
  a rename inside it; the shared root is created in the constructor and
  otherwise only enumerated.
  A listing concurrent with a save was already correct by design — `#row`
  takes a read's own `ENOENT` as the answer rather than checking first. And
  one directory can never have two writers, because a conversation admits
  one turn at a time.
- **The tool constants.** pikuri answers this itself now: every tool
  declares a sharing posture in its yardoc (its `DECISIONS.md`, "Every tool
  declares one of four postures"). `CALCULATOR` is `P_stateless`, and says
  outright to hand it to every agent in the VM; `FETCH` and `WEB_SCRAPE`
  are `P_shared_benign`, sharing a process-wide URL cache whose race that
  doc argues is harmless. `WebSearch` is built per wiring for its API keys,
  but is `P_shared_locked` on class-level per-provider limiters, so a
  per-agent instance would throttle no differently.

Single-writer safety was never located in the pool size. It comes from the
*partition*: per-conversation agents (`D_conversation_owns_agent`) plus a
conversation admitting one turn at a time ({AgentRunner#submit} injects
rather than starting a second). Two turns are two agents, two histories,
two transcripts, two listeners and two disjoint folders. That property is
independent of how many turns run at once, which is why `--turns` needed no
owner thread to go with it (`D_no_event_queue`).

**Rejected: deriving the pool size by probing the server's slot count.**
llama.cpp reports `--parallel` on `/props`, so this is possible and would
remove a way to misconfigure the pair. Not done: the probe would have to
happen at boot, before any conversation exists, and would make an
unreachable server fatal to *starting* rather than to the first turn.
A flag the operator sets alongside the one they already set on the server
is the cheaper half of that trade. Reopen if `--turns` is routinely wrong.

**Rejected: hand-rolling the pool on stdlib `Queue`.** Ruby ships no
executor, so the alternative is writing a pool, a shutdown protocol and a
backpressure policy by hand. `concurrent-ruby` is a new direct dependency
(the first `Concurrent::` in the pikuri family — pikuri itself is stdlib
`Mutex` throughout) and earns its Gemfile paragraph on exactly that.

**Rejected: treating the executor as the event queue.** They share a
mechanism and have opposite contracts — this one exists *to* block, an
owner thread must never block. See `D_no_event_queue`.

**Consequences.**

- Shutdown drops whatever is running: saves land at turn end, and
  `turn_executor.shutdown` from the `:state, :stop` hook deliberately does
  not wait (waiting there would re-create the parked-thread bug
  `D_shutdown_on_state_stop` exists to prevent). Accepted — single user,
  rare restarts.
- Specs inject `ImmediateExecutor` to run turns inline, which deleted one
  hand-rolled spin-waiter. The examples that are *about* the busy state
  keep a real thread.
- **Nothing enforces the pool size, and nothing should need to.** The
  `executor:` parameter is typed `Concurrent::ExecutorService`, which any
  pool satisfies; what carries the intent is the boot script's paragraph
  saying the number is a load cap. A future reader who finds a correctness
  argument resting on it should distrust the argument, not tighten the
  type.
- **`--turns > 1` buys overlapping inference, not overlapping search.**
  pikuri's search rate limiter holds its mutex across the HTTP call and is
  scoped to the egress IP, so two agents searching at once serialize
  anyway, and one tripping a provider's circuit breaker cools down the
  other. Documented at the tool wiring; it is upstream's design
  (`P_shared_locked`), not something to work around here.
- **The accumulate-don't-render idea for detached conversations becomes
  reachable**, since more than one conversation can now render at once —
  see `D_conversation_owns_agent`'s consequences, which parked it at pool 1.

## D_delete_no_undo — Deleting a conversation is irreversible, and the live one rolls onto a fresh conversation (2026-08-28)

**Status:** Accepted, shipped 2026-08-28 as `ConversationStore#delete`,
`AgentRunner#delete_conversation` and `POST /conversations/:id/delete`.

**Context.** `ConversationStore` grew every verb but this one, so
conversations accumulated until the user ran `rm -r`, which is what
`README.md` told them to do. Three things needed settling before a ✕
could go on a sidebar row: what confirmation looks like, what happens
when the deleted conversation is the *live* one, and whether the removal
is recoverable.

**Decision.** A native `confirm()` naming the conversation — one line of
`app.js` and the only option needing no CSS at all, where a modal
component is exactly the kind of thing that starts arguing for a build
step (`D_no_js_build_step`) — then a real removal: `FileUtils.rm_r` over the whole folder, `meta.json` unlinked
first. Deleting the live conversation is `#new_conversation` *without the
save* — the agent is cleared (its `Event::Reset` empties the transcript
in every tab, the same path a fresh conversation takes) and a fresh id
minted, then the folder goes. Both cases are refused while a turn is in
flight (409), like selecting and starting a conversation.

The conversation folder is ours end to end — nothing but pikuri and this
shell writes there — so a delete removes the directory wholesale. That is
deliberately unlike pikuri's refusal to sweep a single unreferenced
attachment (pikuri `DECISIONS.md` `D_history_attachments`): declining to delete a
*file* someone may have put beside the history is compatible with
removing the *conversation* it belongs to. Attachments are never shared
between conversations, so nothing is refcounted.

**`meta.json` goes first because `#write_meta` is the commit point.**
Unlinking the envelope is that commit's exact inverse, so a removal that
dies half-way leaves a conversation *unlisted* rather than one that lists
and then cannot be opened. Orphaned bytes are the better failure.

**Rejected: an undo, and its tombstone variant.** Both need the folder to
survive the click. A conversation holds everything the user typed and
everything the tools fetched, unencrypted (`0700` is the whole of the
protection) — someone deleting one is often deleting it *because* of what
is in it, so keeping it for ten seconds "in case" is a privacy footgun
and keeping it until a sweep is worse. The tombstone shape was
additionally tempting because `#list` already skips a directory with no
`meta.json`; that state currently means *a save interrupted between
pikuri's half and ours*, and overloading it would make a crash and a
deletion indistinguishable forever.

**Rejected: refusing to delete the live conversation.** Consistent with
how switching refuses, and useless: the conversation you most want to
drop is usually the one in front of you. Rolling onto a fresh one is
barely more code and is what the user meant.

**Rejected: `DELETE /conversations/:id`, and a second `<form>` per row.**
The row is already a form that POSTs to `/select`, and a nested form is
invalid HTML while two sibling forms cannot share the row's flex line.
One form with two submit buttons, delete carrying `formaction`, keeps the
no-JS path working and leaves Enter on the row selecting rather than
deleting.

**Consequences.**

- A bare `conversations` SSE event now means "the sidebar's list changed,
  re-fetch it" — deleting a non-live conversation emits no `reset`, so
  without it every *other* tab would keep a row that 404s when clicked.
  `app.js` grew one `refreshSidebar()` that `reset` and the new event
  share; a future titles or search feature should reuse the same signal.
- The ✕ is revealed on hover and `:focus-within`, and shown
  unconditionally under `@media (hover: none)` — on a touch device the row
  itself is a submit button, so a tap selects the conversation instead of
  revealing anything (`D_target_browsers`). The reveal uses `opacity`, not
  `display`/`visibility`, or the button would leave the tab order and
  `:focus-within` could never fire.
- **A second process can resurrect what you deleted**, by saving its own
  live copy at the next turn end. Accepted as a limitation, and the
  strongest case anything made for a cross-process lock — which was
  weighed on exactly that basis and rejected in `D_no_multi_process_lock`.
- Nothing new serializes the folder. What keeps a delete from racing the
  turn-end save is the runner refusing while busy, which is the same
  discipline `ideas/conversation-store-locking.md` argues should stop
  being a discipline.
- Deleting is the whole answer to retention: still no cap and no
  auto-prune. `rm -r` on the state folder remains a complete reset.

## D_target_browsers — Firefox on the desktop, Safari on iPad and iPhone; greenfield only, no polyfills (2026-08-28)

**Status:** Accepted 2026-08-28. The iPhone layout is *not* shipped — see
Consequences.

**Context.** The delete button's hover-reveal was the first change whose
correctness depended on which browsers count, and "modern browsers" is
not an answer a CSS reviewer can use.

**Decision.** Three targets: Firefox on the desktop, Safari on iPadOS,
Safari on iOS. Nothing is polyfilled and nothing carries a vendor prefix
for a browser outside that list — `:has()`, `:focus-within`,
`@media (hover: none)`, `dvh` units and `SubmitEvent#submitter` are all
fair game and are used. **The iPad counts as a desktop**: it has the
screen for the sidebar-beside-chat layout as it stands.

**Rejected: "every modern browser".** It reads generous and decides
nothing — every question about a selector or a unit comes back
unanswered, and in practice it means testing on whatever is open.

**Consequences.**

- **The iPhone layout does not work, and that is deferred, not denied.**
  There is a `@media (max-width: 48rem)` fallback that stacks the sidebar
  into a 20vh strip, and nobody has opened it on a phone. Tracked in
  `ideas/phone-layout.md`, which leads with the finding that the real
  blocker is not CSS: reaching this app from a phone means `--bind`
  leaving 127.0.0.1, and there is no auth (`D_single_shared_conversation`).
- That breakpoint is on the wrong side of the iPad: portrait is 768px,
  exactly 48rem, so `max-width: 48rem` matches and an iPad in portrait
  gets the phone fallback today. Contradicts treating iPads as desktops;
  fix belongs with the phone layout.
- A change that needs a polyfill or a build step to reach a fourth browser
  is out of scope twice over — here and under `D_no_js_build_step`.

## D_replay_from_history — Store only pikuri's history; re-derive the transcript by replaying synthesized events (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 as {HistoryReplay}.

**Context.** A saved conversation has two layers: the *model* half
(messages, tool calls, results, thinking, attachments — `history.json`,
written by `Pikuri::Agent::History#save`, whose contents we do not get a
vote on) and the *render* half ({Transcript} blocks: kinds, ids, HTML).
Loading a conversation back means producing the second from something on
disk.

**Decision.** Store nothing beyond `history.json` and our `meta.json`,
and rebuild the blocks by turning each message back into the
`Agent::Event`s that produced it, fed through the real {SseListener}. The
transcript is *rebuilt, not swapped*: `Agent#load_history!` emits
`Event::Reset`, whose existing arm empties the transcript and every open
tab, and the replay refills it — so there is still exactly one
transcript, one renderer, and one event→kind mapping.

**Rejected: store the rendered blocks** (`blocks.json` beside
`history.json`). Exact reload, zero replay logic — and HTML strings on
disk, so a {MarkdownRenderer} or `style.css` fix never reaches an old
conversation, plus two representations of one conversation that can
disagree. The longer these files live, the worse frozen HTML gets.

**Rejected: append an event log** (`log.jsonl`, source text not HTML)
and replay it. It keeps the today's-renderer property, but it prices
persistence on pikuri's *event set*: an `Event ↔ Hash` codec must cover
every variant {SseListener} matches on and stay in step as pikuri adds
more — and pikuri adds them steadily (`Transient` and `HistoryLoaded`
both landed in one unreleased cycle). `History` is the opposite: written
down, `version:`-stamped, additive-only by decision, unknown keys
ignored. Betting the format on the stable one is not close. Nothing here
forecloses adding `log.jsonl` later if the losses below start to matter.

**Rejected: a `History → blocks` builder** instead of synthesized events.
Same output, one more place block kinds are decided — the
SseListener / `index.erb` / `style.css` trifecta would stop being one.

**Consequences.** Only messages are stored, so what never became one is
gone on reload: `! cancelled` and run-loop failure blocks,
`FallbackNotice` lines, and the partial assistant text a cancel
deliberately preserves (it raises out of `Chat#ask` before the message
lands) — a cancelled turn reloads as a user message with no reply under
it. Two couplings are the price of re-deriving: the replay must emit
events in the order the *agent* emits them rather than the order messages
sit in (a batch's `ToolResult` follows its own `ToolCall`), and it must
strip the `<system-reminder>` envelope `Agent#append_reference_block`
adds, whose tag is a private constant upstream. Both are held by an
end-to-end spec in `conversation_flow_spec.rb` that renders one
conversation live and again from disk and demands the same blocks — the
canary for a rename or a reordering upstream.

---

## D_shutdown_on_state_stop — Close the Broadcaster from Puma's `:state, :stop`, the last hook before the graceful wait (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 in `bin/pikuri-web-chat`.

**Context.** Ctrl+C hung for as long as a browser tab stayed open. Every
open `EventSource` parks a Puma request thread in the `GET /events` drain
loop; Puma's graceful stop waits for in-flight requests **with no
deadline**; and the 15 s SSE heartbeat keeps those parked writes
succeeding, so nothing ever errors the thread out. The wait ended only
when the browser finally dropped the connection. This is the bill for the
threading rule (`D_worker_thread_agent_loop`) — a design that parks
serving threads on purpose has to unpark them on purpose too.

**Decision.** The boot script registers on Puma's `:state` event and
calls `Broadcaster#close` for `:stop` and `:restart`. That event is fired
by the server thread on the line *before* `graceful_shutdown`, which
makes it the last hook that runs on the near side of the wait.
`Broadcaster#unsubscribe_all` became `#close`: the same sentinel push,
idempotent, and it now also refuses *later* subscribers, so a connection
handed out mid-shutdown cannot re-park a thread. `force_shutdown_after:
5` stays as the backstop. Measured: two SSE clients attached, SIGINT and
SIGTERM both exit within the second.

**Rejected: `at_exit`, Sinatra's INT trap, and `Puma::Events#after_stopped`.**
All three are on the *far* side of the wait, so all three are release
valves that open after the thing they would have released has already
finished blocking. The INT trap additionally never fires — Puma
overwrites it during `launcher.run` — and `after_stopped` was measured at
a still-10 s hang, because `Puma::Server#run` performs its own
`graceful_shutdown` in the server thread before the launcher gets to fire
it.

**Consequences.** Nothing in the exit path may rely on `at_exit` or on
Sinatra's own INT trap; a future cleanup that needs to run before the
wait belongs in the same `:state` hook. `Broadcaster#close` must stay
idempotent and must keep refusing new subscribers — the invariant lives
in its YARD header.

## D_dev_flag_no_reload — `--dev` is Sinatra's development mode, not code reloading (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 in `bin/pikuri-web-chat`.

**Context.** A dev flag on a web server usually promises reloading. Here
it can't: the agent, its listener stack and the runner thread are
long-lived instances wired once at boot, so Ruby under `lib/` reloads in
neither mode and re-reading it would leave a live conversation bound to
the old objects. `public/*.js` and `.css` were always read per request
and never needed a flag.

**Decision.** `--dev` flips Sinatra into `:development` and turns on
`show_exceptions` — which is what `views/*.erb` re-reading and in-browser
exception pages hang off, and nothing more. The README documents
restarting under a file watcher as the way to iterate on Ruby, which is
cheap now that shutdown is instant (`D_shutdown_on_state_stop`).

**Rejected: a reloading dev mode** (Zeitwerk reload, `rerun`-style
in-process reloading). Re-wiring the live agent is the actual
requirement, and no amount of reloading does it — the flag would name a
guarantee it cannot keep.

## D_theme_cookie — Theme is a browser cookie, resolved server-side at `GET /` (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 in `public/style.css`,
`views/index.erb` and `public/app.js`.

**Context.** Adding a light theme raised where the preference lives. The
transcript is server-authoritative (`D_server_authoritative_transcript`),
so "state lives on the server" is the house style — but this particular
state is per-*browser*, not per-conversation, and the page it affects is
kept live by one long SSE connection that a reload destroys.

**Decision.** Both palettes live in `public/style.css` as `--dark-*` /
`--light-*`, and the rest of the file reads only the nine semantic tokens
it already used; dark stays the default under `:root`, and
`:root[data-theme='light']` remaps the same nine. `GET /` resolves the
`theme` cookie against an allowlist and renders `data-theme` onto
`<html>`, so a light-theme user never sees a dark first paint. `app.js`
flips the attribute and rewrites the cookie in place.

**Rejected: a `POST /theme` route and server-held theme state.** A round
trip for a colour change means a reload, and a reload costs an SSE
reconnect — paying a transcript resync for a presentational toggle. The
cookie is deliberately *outside* {Transcript} and stays presentational,
which is what lets "the transcript is server-authoritative" keep meaning
what it says rather than becoming "…except theme".

**Consequences.** The theme is the one piece of per-browser state in the
project, and it is the precedent a future per-browser preference should
follow. A new themed colour means adding it to both palettes *and* both
mappings; nothing outside `style.css` may read a raw colour.

## D_chat_only_entry_point — The trifecta promise belongs to the boot script, not to the project (2026-08-27)

**Status:** Accepted, shipped 2026-08-27; `bin/pikuri-web` renamed to
`bin/pikuri-web-chat`, matching pikuri-tui's `bin/pikuri-tui-chat`.

**Context.** The README never said which shape this shell offers — OS
agent, coding agent, or chat. It's a chat, and that turned out to be the
selling point worth leading with: the whole tool set is `web_search`,
`web_scrape`, `fetch` and `calculator`, so in pikuri's lethal-trifecta
terms it holds the *untrusted content* and *egress* legs and **not** the
*private data* leg. Nothing wired here reads the disk, runs a command or
touches a repo — so there is nothing on your machine for it to find, and
you can think out loud at it. But pikuri ships `pikuri-os`,
`pikuri-code` and `pikuri-workspace` in the same checkout, one line away.

**Decision.** The guarantee is attached to an *entry point*, and the
script carries its shape in its name. Should an OS or code shell grow
later it lands as a **sibling script** with its own tool set and its own
boot-time trifecta report, reusing the tool-set-agnostic plumbing
({AgentRunner}, {SseListener}, {Transcript}, {App}) — never as extra
tools bolted into this one.

**Rejected: attaching the promise to the project, and growing this
script's tool set.** A project-level promise is one a future commit
breaks silently: adding a disk- or shell-touching tool here would revoke
a guarantee a user has *already read* in the README, with nothing in the
diff that looks like a revocation. Naming the shape in the script makes
the same change visibly wrong.

**Consequences.** The README keeps only the caveat that survives the
promise: your own typed input still egresses to the configured LLM
server, and a scraped page can try to talk the agent into fetching an
attacker-chosen URL. The boot-time trifecta report stays the *checkable*
answer for whatever tools a script actually wired, so a sibling script
does not need this entry re-argued — it needs its own report.

## D_per_shell_state_root — Every shell keeps its state under one folder named after itself (2026-08-27)

**Status:** Accepted, shipped 2026-08-27. Reverses the layout the first
conversation-store commit shipped the same day, which put `conversations/`
directly under `Pikuri::Paths.state`.

**Context.** `Pikuri::Paths.state` is shared: pikuri writes there, and so
will pikuri-tui and every sibling script AGENTS.md anticipates
(`D_chat_only_entry_point` — a new capability is a new script, not a new
tool). Conversations are the first thing this shell persists, and the
first commit named the folder after its *contents*, on the theory that a
future pikuri-tui `/resume` should read the same files.

**Decision.** One folder per shell, named after the script, and
**everything that shell persists goes inside it**:

```
~/.local/state/pikuri/pikuri-web-chat/conversations/<id>/
```

`bin/pikuri-web-chat` derives a single `state_root` local and composes
every path from it, so the next thing worth persisting lands beside
`conversations/` rather than in a second place. The root is created by
{ConversationStore} at construction — the folder exists from boot, not
from whichever later event happens to save first.

**Rejected: a shared `conversations/` for cross-shell resume.** The
attractive end state is "start a conversation in the TUI, finish it in the
browser", and a shared folder looks like the cheap way there. It isn't:
the *format* is what makes that possible (pikuri's `history.json` plus a
documented envelope), and the format travels regardless of where the files
sit. Meanwhile a shared folder means two shells writing one directory with
no agreement about who owns it, no way to tell whose conversations these
are, and `rm -r` on it destroying more than the shell you meant. Path
sharing is the *last* step of interop, not the first.

**Consequences.** Cross-shell resume now needs a deliberate location — a
shared subfolder both shells opt into, or a pikuri-level store — and
whatever it is, it is a decision rather than an accident of layout. This
folder is also the reset: `rm -r` on it returns the shell to first-run
state and touches nothing else.

## D_schema_complete_config — One config file for every pikuri shell, whole schema, secrets nowhere else (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 as {Config}, a port of
pikuri-tui's `Shared::Config`.

**Context.** A machine can run pikuri-tui and pikuri-web side by side,
and both want the same model connections and the same search-provider
keys. The loader raises on an unknown top-level key.

**Decision.** {Config} reads the same layered
`~/.config/pikuri/config.toml` as the TUI and carries the **whole**
schema — `[code]`, `[[code.mcp]]` and all — even though this host wires
none of it. It names no `Pikuri` constant and logs through
`PikuriWeb.logger`, staying on the Pikuri-free side of the seam
(`D_pikuri_free_core`). Secrets (`[[llm]].api_key`, `[search]` provider
keys) come from that file and from nowhere else; `--api-key-env` was
dropped in the same change.

**Rejected: trimming the schema to the sections this host reads.** It
would make the file *reject* one the TUI wrote — the strict-key check
turns every section we don't consume into a parse error, so the
"one file, every shell" property is only bought by carrying sections we
ignore.

**Rejected: CLI flags, `ENV`, and a project-local file as secret
sources.** A flag is visible in `ps` and in shell history; `ENV` is
inherited by every subprocess pikuri spawns; a project-local file is
git-committable. There is deliberately no `--api-key` flag and there
should never be one.

## D_track_pikuri_master — Path dependencies on `../pikuri`, not released gems (2026-08-27)

**Status:** Accepted, shipped 2026-08-27; `pikuri-core` / `pikuri-pdf`
are path dependencies in the `Gemfile`.

**Context.** This shell already wanted master's surface — the boot-time
trifecta report and `Interloper#on_change`, neither of which was in a
release.

**Decision.** Track pikuri master by path. Upgrades follow pikuri's
`CHANGELOG.md`, whose `**Breaking:**` entries carry the migrations, with
pikuri-tui's HEAD as the worked example for anything ambiguous.

**Rejected: pinning released gems and waiting.** `pikuri-pdf` pins
`pikuri-core` in lockstep, so a released pdf gem refuses the next version
bump — pinning buys stability for exactly one release and then blocks.

**Rejected: bisecting pikuri-tui's git history to find a migration.**
Its history is mostly Tuile churn this project doesn't share; the
changelog is the cheaper and more accurate source.

**Consequences.** CI must clone `../pikuri` before bundling — without it
the path dependency fails the build outright.

## D_diagnostics_to_stderr — The browser shows the conversation; diagnostics stay on stderr (2026-06-06)

**Status:** Accepted, shipped 2026-06-06. This *reverses* a design that
shipped in the 2026-06-04 scaffold: `LogIO`, a Ctrl+L toggle and a
collapsible in-page log panel, all removed.

**Context.** The scaffold piped pikuri's per-subsystem loggers and
`PikuriWeb.logger` into a collapsible panel in the page, on the theory
that a browser front-end should be self-contained. In use it made the
transcript ambiguous: two unrelated streams — the LLM conversation and
the program's internal diagnostics — shared one surface, and the panel
needed its own capture machinery (`LogIO`), its own block kind, its own
keybinding and its own CSS to keep them apart.

**Decision.** The transcript shows the LLM conversation only — assistant
Markdown, reasoning, tool-call lines, tool observations, all driven by
{SseListener}. Internal diagnostics stay on their default stderr sinks
and never reach the page. Never cross the streams.

**Rejected: the in-page log panel** (as shipped). The operator running
`bin/pikuri-web-chat` already has a terminal; routing stderr through a
capture object, an SSE frame and a DOM node to arrive back in front of
the same person is machinery bought for nothing, and it is machinery that
every new block kind and every theme change then has to carry.

**Consequences.** {SseListener} renders *events*, never log lines, and
`PikuriWeb.logger` must never be pointed at the {Broadcaster}. A future
"show me what went wrong in the browser" want is a new decision, not a
resurrection of `LogIO`.

## D_worker_thread_agent_loop — The agent loop owns a worker thread; thread-safety lives in the sinks (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 as {AgentRunner}.

**Context.** The agent loop blocks on the LLM for the length of a turn.
Sinatra hands each request a pooled Puma thread.

**Decision.** {AgentRunner} owns one worker thread and the loop runs
there, never on a request thread. The listener writes into thread-safe
sinks ({Transcript}, {Broadcaster}); each `GET /events` connection parks
*its* serving thread draining one subscribed queue. There is no UI thread
and no marshaling — thread-safety is a property of the sinks, not an
obligation on their callers.

**Rejected: running the loop on the request thread that started it.** It
holds a pooled thread for the whole turn, dies with the client that
posted, and makes "one conversation, many viewers"
(`D_single_shared_conversation`) impossible to state.

**Rejected: a marshaling UI thread, the TUI's model.** A terminal has one
thread that may touch the screen, so the TUI's listener marshals onto it.
There is no such thread here — the "screen" is N browsers reached through
a queue — so importing the pattern would add a hop with nothing on the
far side of it.

**Consequences.** Parked drain threads are what makes graceful shutdown
hang; see `D_shutdown_on_state_stop`. Any new sink the listener writes to
must be thread-safe on its own, because no caller synchronizes.

## D_interloper_mid_loop_input — Mid-loop input goes through `Control::Interloper`, input stays enabled while busy (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 in {AgentRunner}; the queued-count
push was completed 2026-08-27 with `Interloper#on_change`.

**Context.** pikuri-tui deferred mid-loop input. A web page makes the
want sharper: the input field is right there while the agent is working,
and a disabled field is a worse answer in a browser than in a terminal.

**Decision.** {AgentRunner#submit} starts a turn when idle and **injects**
when busy; the injection renders through the normal listener path as
`UserTurn(mid_loop: true)`, so nothing about the display is special-cased.
The input stays enabled while busy and the status bar shows the queued
count, which is pushed by `Interloper#on_change` — so the agent's *own*
mid-loop drain updates the browser too.

**Rejected: disabling the input while the agent works.** It is the
honest-looking option and it is the one that loses work: the user types
during the one period they most want to interrupt, and the field refuses.

**Rejected: queueing submissions client-side and posting them at idle.**
That is client-only conversation state, which
`D_server_authoritative_transcript` forbids — a reload would silently eat
the queue.

**Consequences.** Interloper's delivery boundary is the caveat that
leaks: injections arrive at turn start and once each tool batch
completes, so one placed mid-response waits for that boundary. The
visible queued count exists to make that wait legible rather than to hide
it. The boundary itself is pikuri's decision, not ours — as of 0.0.7 it
moved off `after_tool_result` to tool-batch completion, and AGENTS.md's
documented caveat had to be corrected to match.

## D_pikuri_free_core — No `Pikuri::*` type reaches what the browser sees; server-side classes use them freely (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 as "three adapters plus the boot
script"; widened to include {HistoryReplay} on 2026-08-27; **restated
2026-08-28 as a boundary rather than a list of classes**, when
{ConversationStore#save} took over writing `history.json` and therefore
took a `Pikuri::Agent::History`. The count was never the invariant —
"translation happens at named boundaries, and nowhere else" is — and the
list of names had begun to read as the rule.

**Context.** This project tracks pikuri master (`D_track_pikuri_master`),
so pikuri's surface moves under it by design. What that costs depends
entirely on *where* the types are: a pikuri type in the rendering path
prices an upgrade at a sweep of every file the browser's state flows
through, while one in a disk utility prices it at that utility.

**Decision.** The line is the browser, not a file count. **Nothing that
reaches what the browser sees speaks a pikuri type:** {Transcript},
{Broadcaster}, {StreamingMessage}, {MarkdownRenderer},
{ConversationRegistry}, {Config} and {App} deal in ids, kinds, HTML
strings, paths and queues. **Server-side of that line, pikuri types are
used freely** — `bin/pikuri-web-chat` (boot/wiring), {SseListener},
{AgentRunner}, {HistoryReplay}, and {ConversationStore#save}.

**Rejected: keeping {ConversationStore} on the Pikuri-free side by taking
a block** — `store.save(conversation) { |dir| history.save(dir) }`, the
store yielding a `Pathname` and never holding a `History`. Built first,
then reverted: it preserved the letter of the old list at the cost of an
indirection that explained nothing, and the seam it was defending is not
one the store sits on. What settles it is that the refactor *relocates* a
pikuri call rather than adding one — `History#save` had exactly one call
site before ({AgentRunner#persist}) and has exactly one after (the
store), so the upgrade cost the seam exists to bound did not move at all.
A utility method that owns a directory is the right owner of what goes
into it.

**Rejected: letting Pikuri types spread to whatever needs them.** Passing
a `Pikuri::Agent::Event` into {Transcript} is the shortest path and it
prices every future pikuri upgrade at a full-project sweep. With the seam
held, a shifted surface costs rewriting the adapters — the same
fork-or-swap rationale as the TUI's.

**Consequences.** The adapters translate at the boundary, which
occasionally means a small unwrapping that would be unnecessary if the
event travelled whole. That cost is the decision, not an oversight.
{Config} deliberately stays on the Pikuri-free side even though it is
server-side, because its schema is the *file's*, not pikuri's
(`D_schema_complete_config`) — the boundary licenses pikuri types where
they help, it does not require them.

## D_rerender_and_replace — Re-render the whole message per delta; don't port the TUI's block-cutter (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 as {StreamingMessage}.

**Context.** pikuri-tui streams assistant output through a
`StreamingMarkdownBuffer` — a block-cutter with committed-prefix
machinery, easily the most intricate piece of the TUI's rendering. The
obvious move for a sibling front-end is to port it.

**Decision.** Don't. {StreamingMessage} accumulates the source and
re-renders **all** of it through kramdown per (rate-limited) delta; the
browser replaces one div's `innerHTML`. What *is* kept is the TUI
buffer's lifecycle contract, because that part is about correctness
rather than cost: deltas are preview-only, the bookend `finalize` carries
the authoritative content (fast-path when equal), and the object is dead
afterwards — `append` after `finalize` and a second `finalize` both
raise.

**Rejected: porting `StreamingMarkdownBuffer`.** It exists to bound
per-token `TTY::Markdown` cost on a terminal that can only append. The
browser can replace a node, and kramdown over one message is cheap — so
the port would carry the terminal's constraint into a medium that doesn't
have it, along with its bug surface.

**Rejected: coalescing deltas here.** That already lives in pikuri as
`Listener::RateLimited` (15 fps). Reimplementing it would put two rate
limiters in one path and make the effective frame rate a function of
both.

**Consequences.** Per-delta cost is O(message length), which is fine at
chat scale and would not be for a very long single message; that is the
tripwire to watch if this ever changes.

## D_server_authoritative_transcript — The server holds rendered blocks; SSE carries only deltas (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 as {Transcript}.

**Context.** A browser front-end has to answer three things at once:
page reload, a second tab, and `EventSource`'s automatic reconnect.

**Decision.** {Transcript} holds the rendered HTML blocks and is the
single source of truth. `GET /` renders the full snapshot into the page;
SSE carries only deltas against it, placed by block id. All three cases
then converge on the same state with no client-side bookkeeping.

**Rejected: client-side conversation state** (accumulating the
conversation in JS from the event stream). Every one of the three cases
becomes its own problem — the reconnect needs a replay protocol, the
second tab needs a backfill, the reload needs persistence — and the three
solutions interact. Holding the blocks server-side answers all three by
not having the problem.

**Consequences.** Never introduce client-only conversation state; this is
the rule the theme cookie had to be argued *against* (`D_theme_cookie`)
rather than quietly excepted from. Blocks are stored rendered, so a
change to how a block renders does not retroactively re-render history.

## D_single_shared_conversation — One *live* agent, one transcript, loopback by default (2026-06-04)

**Status:** Accepted, shipped 2026-06-04; narrowed on 2026-08-27, when a
sidebar of stored conversations shipped. "One conversation" now means one
**live** conversation — the browser can switch which stored conversation
that is, and every tab follows, because there is still exactly one agent
and one transcript.

**Selection clause repealed and shipped 2026-08-28.** Viewing is now a
per-tab, per-URL concern (`GET /c/:id`), rows are links, and sending into
a conversation the agent is not on is what makes it live — carrying the
mid-turn refusal that `POST /conversations/:id/select`, now gone, used to
carry. A conversation the agent is not on is replayed from history per
request (`HistoryReplay.snapshot`). SSE remains one undivided feed, so
every frame is stamped with the live conversation's id and the client
drops what is not its own; per-conversation subscriptions arrive with the
agent-per-conversation work. The paragraphs below are kept for the
reasoning, not as current behaviour.

**Superseded in direction 2026-08-28, still accurate as shipped.** The
single-user, no-auth, loopback half stands and is now settled rather than
provisional: a second person runs their own process under their own OS
account. What is repealed is the **selection** clause below — that which
conversation a tab views is server state announced to every tab. It is
view state belonging to the tab, and it goes in the URL. The rejection
paragraph is where the error actually sits: it treats a per-tab *view* and
a per-user *session* as the same thing, and Slack is the refutation —
channel selection lives in its URL, the session exists only for auth. The
premise the clause reasons from ("one live agent") is itself scheduled for
replacement by one agent per conversation. Direction, staging and the
hazards it opens: `ideas/per-conversation-agents.md`. Nothing here has
changed in code yet; amend this entry, don't trust it as intent.

**Context.** A web front-end invites the assumption that it is
multi-user. This one is the TUI's single-conversation model rendered in a
browser, and its second "user" is a second tab on the same machine.

**Decision.** One agent, one transcript, in-process. No sessions, no
auth. `--bind` defaults to `127.0.0.1`; anything else is the operator's
risk and is documented as such. Selecting a conversation is therefore
*server* state, changed by a POST and announced to every tab, not a
per-URL view: one live agent showing two panes where only one accepts
input would be confusing in exactly the situation it enabled. Per-URL
`/c/<id>` is where this goes if background turns ever make the other
pane genuinely alive.

**Rejected: per-session conversations.** Not a patch — {AgentRunner} owns
*the* worker thread and {Transcript} owns *the* block list, so sessions
mean rewriting who owns what, and {Broadcaster}'s fan-out stops being a
broadcast. Out of scope until there's a concrete need.

**Rejected: shipping auth to make a non-loopback bind safe.** Auth
without per-session conversations protects an inbox everyone shares; it
would look like multi-user support while delivering none of it.

## D_no_js_build_step — One hand-written `app.js`, zero JS dependencies, render on the server (2026-06-04)

**Status:** Accepted, shipped 2026-06-04.

**Context.** The page needs an `EventSource`, form wiring, and a way to
place incoming fragments. That is the entire client-side job, because
Markdown rendering happens server-side in kramdown.

**Decision.** One hand-written `public/app.js` (~100 lines), no Node, no
bundler, no build step. The browser receives ready-made HTML fragments
over SSE and places them by block id.

**Rejected: a framework and a bundler** (or even a single npm
dependency). It would add a toolchain, a lockfile, a `node_modules` and a
build step to a project whose client-side job is a hundred lines — and
the toolchain, not the hundred lines, is what would then need
maintaining.

**Consequences.** This is a live constraint on future work, not a
starting condition: if a change appears to need an npm package, the
answer is to render it on the server instead. It is also what keeps
`--dev` cheap (`D_dev_flag_no_reload`) — there is nothing to rebuild.
