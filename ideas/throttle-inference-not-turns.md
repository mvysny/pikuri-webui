# Throttle inference, not turns

Today the load cap on the inference server is `turn_executor`'s pool size (`D_serial_turn_executor`,
`--turns`, matched to llama.cpp's `--parallel`). That is a proxy, and a leaky one: **a turn holds its
slot across the whole `run_loop`, tool execution included.** So during a five-second `web_search` the
server sits idle while the slot stays taken, and at `--turns 1` nothing else can talk to llama —
not another conversation, not the conversation titler (`ideas/conversation-titles.md`,
`Q_titler_executor`).

The proposal: move the throttle from *who may run a turn* to **who may call the LLM**. A semaphore
with N permits, acquired immediately before the completion request and released immediately after.
Tool execution runs without a permit, so the gaps become usable.

N then means exactly what `--parallel` means, instead of approximately.

## Why a semaphore rather than an executor

The first instinct is "pass `run_loop` an executor to call LLMs on". Reject it: handing
`@chat.complete` to another thread breaks the chat's single-thread confinement, and the streaming
block would fire listener callbacks from the executor's thread rather than the loop's — so every
listener in the stack inherits a threading problem it does not have today.

A semaphore keeps the call on the caller's thread and adds only a wait. Strictly less invasive, and
it is the whole of what is needed: the resource being rationed is the *server*, not a thread.

## Where the permit lives — the real design question

Four candidates, roughly in order of how well they fit.

1. **A new `Control::Throttle`, shared by reference.** `Pikuri::Agent::Control` already houses
   `StepLimit`, `Cancellable` and `Interloper` — "small value-holder[s] the +Agent+ reads from ... at
   fixed points". `Cancellable` is already documented as "shared by reference across the parent,
   sub-agents, and the synthesizer", so a deliberately-shared control is not a new idea in the
   family. Fits the injection style the host already uses.

   **The one way it breaks the family's shape:** every existing control is *read* — a flag, a
   counter, a queue. A throttle **blocks**. `Control`'s own doc says the agent "reads" controls at
   fixed points; a control that parks the loop thread for possibly minutes is a different animal and
   the module doc would have to say so.

2. **A field on `ChatTransport`.** Attractive because the throttle is *per server*, and
   `ChatTransport` is precisely "everything that must travel together for a chat to resolve to the
   same model *on the same server*". It also solves the mid-life model switch for free: `select_model`
   swaps the transport, so the agent automatically starts queueing on the new server's permits. A
   throttle injected at construction would be silently wrong after a switch — this is the wrinkle
   that kills option 1 unless the agent re-resolves per call.

   Precedent for a non-data field: `faraday_adapter` already lives there and is a class, not data.
   The rdoc's "pure data carrier" claim is about *RubyLLM* references specifically.

   Against: a `Data` whose equality now includes a semaphore identity. `ChatTransport` is compared
   (`choice.transport == @agent.transport` in `AgentRunner#select_model`), so this needs thought —
   two transports differing only by throttle instance would compare unequal and park a pointless
   pending switch.

3. **A resolver on the agent**: `Agent.new(throttle_for: ->(transport) { … })`. Handles the switch,
   keeps `ChatTransport` clean, but adds a lambda-shaped seam that is harder to explain than either
   of the above.

4. **Below pikuri entirely — a throttling Faraday adapter.** See *Prove it first*.

## Scope the permit to one `complete` call, and nesting is free

This is the part that has to be right, because getting it wrong deadlocks at N=1.

There are two call sites, `agent.rb:387` (streaming) and `:389` (non-streaming). Wrapping *those*
and nothing else is safe against nesting, because everything that recursively calls an LLM happens
**outside** them:

- `Synthesizer.run_synthesizer` fires from the `StepLimit::Exceeded` rescue — the parent has already
  returned from `complete`.
- A tool that spawns a sub-agent (pikuri's research tools) runs during tool execution, between
  completions.

Widen the permit to a *step*, or to the whole `run_loop`, and both of those become a parent holding
the only permit while a child waits for one. **Write the deadlock case into the test suite**, because
this is exactly the invariant a later "optimization" would break by hoisting the acquire.

Streaming must hold the permit for the *entire* stream, not just the request — the server slot is
occupied until the last token.

## Open questions

- **Cancellation while parked.** A turn cancelled while blocked in `acquire` should abort, not sit
  there. Needs `try_acquire` with a timeout in a loop that re-checks `Cancellable`, or an
  interruptible wait. What is the granularity — 100 ms? And does a cancel *during* a completion
  behave any differently than today?
- **Fairness.** `Concurrent::Semaphore` makes no FIFO guarantee. At N=1 with three conversations,
  can one starve? Probably acceptable (single user), but worth knowing before it is a bug report.
  A fair queue is a different data structure.
- **The dependency.** `D_serial_turn_executor` notes pikuri is "stdlib `Mutex` throughout" and that
  `concurrent-ruby` is pikuri-web's dependency, not pikuri's. Pulling `Concurrent::Semaphore` into
  `pikuri-core` for this is a real cost; a counting semaphore on `Mutex` + `ConditionVariable` is
  ~20 lines and keeps that property. Probably hand-roll it.
- **Timeout / bound.** Should a permit wait be bounded at all, or is an unbounded queue right? An
  unbounded one means a burst of titles delays a real turn indefinitely (see below).
- **Priority.** Nothing here distinguishes a user's turn from a background title. If the sweep ever
  gets big, an unbounded FIFO of titles sits in front of the user. Does the throttle need two
  classes of permit, or does the host solve that by not queueing many titles? Prefer the latter —
  priority inside a throttle is a lot of machinery.
- **Does the probe count?** `ContextWindowDetector`'s `/props` is a request to the same server. It is
  trivial and not inference; almost certainly leave it unpermitted, but say so explicitly.

## What it does to pikuri-web

Mostly good, and it is a real change to a shipped decision rather than an addition.

- **`D_serial_turn_executor` loses its stated purpose.** "The pool size caps concurrent turns ... so
  turns do not outnumber the inference server's parallel slots" stops being why the number exists.
  The executor becomes a thread-count limit; the *permit* count becomes the `--parallel` match. That
  is two knobs where there is one today — probably `--turns` (threads, can be generous) and a new
  one for permits. The decision needs amending, not deleting: everything it says about single-writer
  safety coming from the partition rather than the pool size stays true, and gets *more* true.
- **`:queued` gets more honest.** Today it means "no executor slot". It would come to mean "waiting
  for the server", which is what the status bar is really trying to tell the user.
- **The titler stops being a special case.** `Q_titler_executor` resolved to "titles share
  `turn_executor` because it is the load cap". With permits, titles share the *permits*, and a title
  can slip into the gap while a real turn is running a tool — which is the outcome that discussion
  actually wanted and could not reach.

## Prove it first, without touching pikuri

`ChatTransport#faraday_adapter` already lets this project wrap the HTTP call
(`ideas/conversation-titles/titler-model-probes.md` — the thinking-off adapter uses it). A
throttling adapter would `acquire` around `super` and release in an `ensure`. Zero upstream change,
runnable this week.

That would give real numbers for the upstream ask: how much wall-clock does filling the tool-call
gaps actually buy on a `--parallel 1` box, with a couple of conversations and a titler? If the answer
is "not much", the refactor is not worth anyone's time. If it is "a lot", the pikuri issue writes
itself and comes with evidence.

Caveats to the spike: HTTP granularity is the right granularity by luck rather than design; the
adapter cannot see `Cancellable`, so a parked request is uninterruptible; and it is more behaviour in
an adapter than the field's rdoc pictures. Fine for measurement, not for shipping.

## Graduation

The implementation home is **`../pikuri`**, not here — this is the agent loop, which AGENTS.md puts
squarely on the library's side of the seam. So:

- The decision, when taken, goes in `../pikuri/DECISIONS.md`.
- pikuri-web records only the *consequence*: an amendment to `D_serial_turn_executor` and whatever
  `--turns` becomes.
- It lands here only after a pikuri release, because of the one-minor pin (`D_released_pikuri_gems`).
- Consider moving this file to `../pikuri/ideas/` if the brainstorm gets much further — it already
  has an `ideas/` folder and this is its idea. Kept here for now because the motivating evidence
  (`D_serial_turn_executor`, the titler discussion) is all on this side.
