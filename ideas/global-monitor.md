# One serialization domain — a global monitor, or an event loop

Where this came from: `D_no_event_queue` is **Reopened** (its foot carries the whole argument),
`ideas/atomicity-across-seams.md` holds the audit, and the owner has now called it (2026-08-31):
stop patching seams one at a time and give the project a real atomicity primitive, so internal
logic has something to rely on instead of a loose band of threads hopefully not racing. This
file establishes the course; the final shape graduates into a new `DECISIONS.md` entry and a
rewrite of `D_no_event_queue`'s status.

**Terminology.** Nicknamed "The Loop" in the kickoff discussion; proper names from here on.
The two candidate mechanisms are one pattern in two costumes (`D_no_event_queue` already says
so): **(A) a global monitor** — the monitor pattern applied to the whole app state, i.e. a
*giant lock* (precedents: Linux's Big Kernel Lock, CPython's GIL, Vaadin's per-UI lock behind
`UI.access()`); **(B) an event loop** — the Active Object pattern, one owner thread draining a
mailbox (precedents: Swing's EDT, Node, Tuile). The unit of work is a **task** with
**run-to-completion semantics**: a critical section under A, a queued task under B. In the ACID
framing the task *is* the transaction. The marking discipline is JCiP vocabulary:
**guarded-by** (A) / **thread confinement** (B).

## Ground rules (set by the owner — constraints, not open questions)

- **Architecture: one serialization domain + background workers.** The domain executes tasks
  to completion; everything long-running is a worker that enters the domain only via tasks.
- **All web requests go straight into the domain.** A route's body is a task (or a short
  sequence of them).
- **Tasks are rapid-fire.** A task must never block on network (LLM calls; SSE fan-out — which
  is already non-blocking, see below) nor on long-running processing (the agent loop). It *may*
  touch disk — but only because our disk work is small and bounded (two little JSON files,
  temp-and-rename). The web server must never stall for an extended period; the client stays
  snappy. So "may block on disk" is a *bounded-latency budget*, not a licence: anything
  unbounded or proportional-to-history (kramdown over a whole replay) is off-domain by the
  same rule as the agent loop.
- **Everything gets marked.** Every class/function is either *guarded* (runs inside a task) or
  a *worker task* (background thread, enters the domain only via tasks) — per the writing-rdoc
  thread-safety vocabulary; details below.

## What it buys (and what it doesn't)

The target is **A** — atomicity across a seam, two objects mutated or read as one unit
(`D_no_event_queue`, Reopened section). Run-to-completion is the guarantee: the system is only
ever *observed between tasks, never inside one*. The reachable state space shrinks from
arbitrary interleavings of statements to orderings of tasks — finite, enumerable, testable.

It does **not** buy determinism (whether a submit lands before or after a turn ends is genuine
external concurrency — both orders stay reachable, both must be correct), and it does not
replace the executor: `D_serial_turn_executor`'s pool stays the admission gate for LLM work.
Two conversations still stream concurrently; their tasks interleave at task granularity.

## The two costumes

Crucially, **the marking is costume-independent**: "guarded" means "the caller is inside a
task", whether a task is a held monitor or a job on the owner thread. So the class-by-class
classification below can proceed — and even land — before the costume is final.

**Costume A — global monitor**: `PikuriWeb::AppMonitor` wraps a `Monitor` (re-entrant);
`monitor.run { ... }` executes the block inline under it, on the calling thread.

**Costume B — event loop**: a `Concurrent::SingleThreadExecutor` (already in the bundle via
concurrent-ruby); `loop.post { ... }` fire-and-forget, `loop.ask { ... }` = post + future +
bounded wait for tasks that must answer.

| | A: global monitor | B: event loop |
|---|---|---|
| HTTP replies | free — the route's task runs on the request thread, composes the response inline | every reading route needs `future.value(timeout)` + a 503 arm |
| re-entrancy | `Monitor` re-enters: the Interloper `on_change` knot (fires synchronously from inside `#submit`'s inject and re-enters `broadcast_status`) just dissolves | a task that posts-and-waits on another task deadlocks; the knot needs restructuring |
| specs | `ImmediateExecutor` (runs the job on the submitting thread, re-entering the task) keeps working | deadlocks under B; specs need a real executor or a test pump |
| enforcement | `raise unless @monitor.mon_owned?` in guarded methods | `raise unless Thread.current == owner` — parity |
| dumpability | TTIN dump (`ideas/thread-dump-signal.md` — now nearly a prerequisite) shows the stalled task *with its caller's stack*, so provenance is free | one owner stack; tasks need labels to say who posted them |
| ordering | no FIFO across threads — but per-source order comes from each source being one thread, and cross-source order is the genuine concurrency neither costume removes | FIFO, which buys nothing extra here |
| never-block discipline | any thread can silently block while holding it | same hazard, one thread — identical review burden (Node comparison in `D_no_event_queue`) |

**Lean: Costume A, the global monitor.** Same atomicity, same enforcement, same dumpability;
free synchronous replies, and it dissolves rather than aggravates the two re-entrancy knots we
actually have. B's one real advantage — FIFO — solves a problem we don't have.

## The classification

### Guarded (mutable state; every touch happens inside a task)

| class | consequence |
|---|---|
| {AgentRunner} | **`@mutex` deleted.** `#submit`'s claim + broadcast become one task — seam 2 dies. `#claim_running`, `#finish_turn`, `#cancel`, `#select_model`, `#discard!` each become a task entered from whatever thread they're on. The unlocked-`#state` deadlock dance and its comments go. |
| {ConversationRegistry} | **`Monitor` deleted** (modulo the shutdown question below). Mint/delete/rows are tasks; `#open_id`'s resolve+open atomicity comes from the task now. |
| {Transcript} | **`@mutex` deleted.** Writes (listener tasks) and reads (`GET /c/:id`, catch-up) all sit in tasks. `Block` stays a `Data` — an immutable snapshot handed *out* of a task is still the right shape. |
| {ConversationStore} | already lock-free; now additionally always called from tasks (`#save` from the turn-end task, `#list`/`#delete` from registry tasks). The "blocking I/O under locks" item in the atomicity file becomes "bounded disk I/O inside tasks" — same latency, now by decision. |

### Workers (background threads; enter the domain only via tasks)

- **The turn job** (`AgentRunner#run_turn` on the shared `FixedThreadPool`): `run_loop` itself —
  the LLM round-trips, tool execution — runs off-domain, unchanged. Its *bookkeeping* brackets
  (`claim_running`, `finish_turn` incl. the save, per `D_worker_thread_agent_loop`'s "posts
  events instead of calling inline") are tasks.
- **{SseListener}`#on_event`** runs on the turn worker. **Rendering stays off-domain**
  (`D_no_event_queue` constraint: the mechanism owns *mutation*, not rendering): kramdown /
  escaping / {StreamingMessage} accumulate on the worker; the finished HTML string enters a
  task that does `transcript.add/update/remove` + `broadcaster.broadcast` as one unit —
  seam 4 goes from "safe by single-writer" to "safe by construction". ~15 tasks/sec per
  streaming conversation, each tiny. {StreamingMessage} stays worker-confined, untagged.
- **`GET /events` drain loops**: the request thread parks popping its subscriber queue and
  writing to the socket — the "executor + 1 thread" the ground rules ask for **already exists**:
  {Broadcaster} pushes to unbounded per-connection queues (non-blocking) and the parked request
  threads do the network. Nothing to build here. The *open* of `/events` — subscribe +
  catch-up snapshot — becomes one task, closing the server-side half of that seam by
  atomicity instead of ordering (`D_subscribe_then_snapshot`'s ordering becomes redundant
  server-side; the upsert-by-id duplicate tolerance **stays**, because page-render → connect is
  still two HTTP requests and no server mechanism can reach across that gap).

### Outside the domain entirely

- **{Broadcaster}** — stays a thread-safe sink with its own small mutex, exactly as
  `D_no_event_queue` insists: `#close` fires from Puma's `:state, :stop` and must never wait on
  a wedged domain (`D_shutdown_on_state_stop`); `Queue#push` never blocks, so calling
  `#broadcast` from inside a task respects the never-block rule.
- **Immutable / stateless**: {Config}, {ModelCatalog}, {SlashCommand}, {TrifectaView},
  {RelativeTime}, {MarkdownRenderer}, {HistoryReplay} — callable from anywhere, no tag beyond
  what they carry.
- **Pikuri internals** — the agent, Interloper, Cancellable keep their own contracts; we call
  them both from tasks (`inject_user_message`, `cancel!`, `#size`) and from workers
  (`run_loop`'s drain). See the lock-ordering question below.

### The marking itself (writing-rdoc)

Class-level tag from the fixed vocabulary. Under A it is a guarded-by contract:
**"Guarded by {AppMonitor}."** — a *caller* obligation ("you must be inside a task"), never a
self-marshaling promise. Under B the same classes read **"Event-loop-confined."**
(`<Role>`-thread-confined, role named abstractly per the skill). Workers get a `== Threading`
section naming which of their calls enter tasks. The tag is enforceable, not just
documentation: guarded mutators open with `AppMonitor.assert!` (`mon_owned?` under A, thread
identity under B) — cheap enough to keep on permanently, and it turns a forgotten `run` from a
latent race into an immediate raise. That assertion is the enforcement story
`D_no_event_queue` said Ruby lacks and Node gets from the language.

## What this closes (the atomicity file's table, updated)

- Seam 2 (compose + publish): **closed structurally** — `status_data` + broadcast is one task.
  The monotonic-sequence-number candidate dies unimplemented.
- Seam 4 (append + broadcast): from "safe by single-writer discipline" to atomic.
- `GET /c/:id`: the page snapshot (transcript + status + rows) becomes an *untorn read* — today
  it's three separate reads that can straddle a transition; nobody has noticed, but it's the
  isolation we currently get only per-object.
- Registry `#open` footgun (PROBE 7): unchanged by the mechanism per se — still wants `#open`
  private.
- Double-submit / queued-turn-shows-nothing (known-and-accepted items): unchanged; these are
  request-to-request seams, same class as the page→EventSource gap. No server-side
  serialization reaches them.

## The rejected alternative the D entry must answer

The audit's own finding cuts the other way, and the graduating entry has to say so: five seams
wanted four different tools — ordering (seam 3), broadcast-at-the-transition (seam 1), a
monitor the registry already had (seam 5), an immutable snapshot (`Transcript::Block`) — and
none of them wanted a global mechanism. That is the case for per-seam atomic helpers, the
cheapest candidate on `D_no_event_queue`'s list. The owner's answer, and why this file exists:
per-seam fixes are patch-after-reading — each seam must first be *found*, and this architecture
hides exactly the defects that argue against it (the lucky-race argument in the Reopened
section), so the per-seam discipline amounts to "hope the next audit reads the right function".
One run-to-completion domain is something internal logic can *rely on* without an audit per
seam. Record both halves. And note two of the audit's fixes survive regardless: ordering for
seam 3 (its halves are two HTTP requests — no server-side mechanism reaches it), and `Block`
staying a `Data`.

## Testing — the audit's probe method, inherited

`ideas/atomicity-across-seams/seam_audit_spec.rb` already demonstrates the technique this
mechanism makes systematic: pin one ordering with a gate job holding the executor, then assert
the observed state. Under run-to-completion that generalizes — task orderings are finite and
enumerable, so probes stop being "assert today's bug" scratch files and become spec/-worthy
ordering tests:

- **PROBE 6 is the acceptance test**: it currently forces seam 2's torn status frame
  deterministically; after the mechanism lands it flips to asserting the tear can no longer be
  produced, and moves into spec/.
- **`AppMonitor.assert!` makes new probes cheap**: a spec calls a guarded method off-task and
  expects the raise, instead of hunting an interleaving.
- **Inherit the harness trap verbatim**: rack-test arrives as host `example.org` and Sinatra
  403s it outside `set :environment, :test`, so a probe asserting *absence* passes happily
  against "Host not permitted" — confirm every new probe's no-fix failure by stashing the fix.

## Open questions

1. **Costume A vs B** — leaning A (global monitor); see table. Decide before implementation,
   but the classification and rdoc sweep don't wait on it.
2. **`restore!`'s replay is the one long task in hand**: kramdown over a whole saved history,
   inside the mint (registry task). Under the rapid-fire rule it must move off-domain —
   e.g. replay into a detached transcript on the minting thread *outside* the task, then
   attach runner+transcript atomically — but that reopens "a second tab opening the same
   conversation mid-replay sees what?". Cheapest correct answer might be: keep replay in the
   task but measure it first (a big history on a slow machine — how bad, actually?).
3. **Turn-end save inside the task**: keeps "idle means saved" (`AgentRunner` Persistence
   header) and is the sanctioned disk-in-task case, but it's also the biggest one — is
   `export_history` + two-file write always inside the latency budget, or does the export
   happen in-task and the write on the worker with the state flip on completion?
4. **Shutdown vs the domain**: `:state, :stop` must never wait on a wedged monitor/loop.
   Broadcaster is already independent; audit what else the stop hook touches (the registry
   sweep via `#runners`?) and either keep that path lock-free/best-effort or give it a timed
   acquire.
5. **Lock ordering (ABBA) with pikuri's own locks**: a task calling into pikuri
   (`inject_user_message` → fires `on_change` → re-enters the monitor: fine under A) vs the
   worker inside pikuri's locks entering a task. Enumerate every task→pikuri call and every
   pikuri→task callback and check the order is consistent. The existing comments (`#submit`'s
   outside-the-mutex block, `#finish_turn`'s "on_change fires outside its own lock") are the
   audit's starting points.
6. **Timed acquire / 503s**: under A, a request thread waits on the Monitor with no timeout
   (Ruby `Monitor` has no timed `enter`). Is Puma's pool + the TTIN dump enough, or do routes
   want a bounded wait? (Under B this is forced anyway — every `ask` needs a timeout.)
7. **Blast radius, accepted**: a stall inside a task now pauses *every* conversation and every
   request, not one — that's the trade `D_no_event_queue` prices. The compensations are
   (a) the rapid-fire rule above and (b) dumpability: land `ideas/thread-dump-signal.md`'s TTIN
   handler first or together with this.
8. **Name and API surface**: one class, two-or-three methods (`run`/`assert!`, maybe `ask`),
   injected the same way broadcaster/registry are. `AppMonitor` under A (`EventLoop` under B);
   where does it live in the wiring — bin/pikuri-web-chat mints it and hands it to everything
   guarded?

## Graduation targets (when acted on)

- New `DECISIONS.md` entry (`D_global_monitor` / `D_event_loop`, per costume): the costume
  chosen, the task inventory, the never-block + bounded-disk budget, the rejected costume's
  rationale.
- `D_no_event_queue`: Reopened → superseded-by note pointing at the new entry.
- AGENTS.md scope bullet: replace the "reopened" paragraph in *No session concept…* with the
  landed mechanism; update the threading-rule bullet.
- rdoc sweep: the guarded-by tags, deleted-mutex headers rewritten (AgentRunner's Thread-safe
  tag, Transcript's, Registry's `== Thread-safety` section).
- `ideas/atomicity-across-seams.md`: seam 2 closes; fold what remains (PROBE 7, the
  known-and-accepted list) or graduate it too.
