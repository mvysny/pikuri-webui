# Throttle inference in pikuri, not just in this host

**The host-side half of this idea has shipped** — {ThrottledAdapter} rations completions per server
with a Faraday adapter, `--turns` is now a permit count, and the turn executor is `2N`. The argument,
the measurements and the rejected alternatives are in `DECISIONS.md` `D_throttle_at_the_request`;
don't re-argue them here.

What is left is the part that belongs upstream: **`Pikuri::Agent` should be able to throttle its own
LLM calls**, so every pikuri host gets this instead of only the one that wrote an adapter.

## Why bother, given it works here

- **pikuri-tui has the same problem and no fix.** Its turns contend for the same llama.cpp, and
  nothing in it rations them.
- **Two things the adapter structurally cannot do:**
  - **Interruptible waiting.** A request parked on a permit cannot be cancelled — the adapter never
    sees `Cancellable`. It acquires, then discovers the turn is dead. (Smaller than it sounds today:
    pikuri's cancel is a tool-boundary stop that does not interrupt a completion either. It stops
    being small if cancellation ever gets finer.)
  - **Priority.** No way to let a user's turn jump a queue of background work. Relevant the moment
    something like the conversation titler starts issuing many small requests.
- **It rests on ruby_llm internals.** Middleware order (`:json` before the adapter) and the fact
  that net_http drives `on_data` from inside the request. Both are verified and neither is
  documented as a contract.

## Shape

A `Control::Throttle`, shared by reference, acquired around the two completion call sites
(`agent.rb:387` streaming, `:389` not) and nowhere wider. `Pikuri::Agent::Control` already holds
`StepLimit`, `Cancellable` and `Interloper`, and `Cancellable` is already documented as shared
across parent, sub-agents and synthesizer — so a deliberately-shared control is not a new idea in
the family.

Open questions, roughly in order of how much they matter:

- **The scope invariant needs a test upstream.** The adapter gets it for free because an HTTP
  request *is* one completion; a control does not. Widen the acquire to a step or a `run_loop` and a
  parent deadlocks against its own sub-agent. See `D_throttle_at_the_request` for why.
- **Every existing control is *read*; this one blocks.** `Control`'s own rdoc says the agent "reads"
  controls at fixed points. A control that parks the loop thread for minutes wants that doc widened,
  or it wants to not be a control.
- **A constructor-injected throttle is wrong after a model switch.** `run_loop(transport:)` can move
  an agent to another server mid-life, and the permits are the *server's*. So either the throttle
  rides on `ChatTransport` (which already carries `faraday_adapter`, so a non-data field is not
  unprecedented) or the agent resolves it per call. The transport option has a snag: `ChatTransport`
  is a `Data` and `AgentRunner#select_model` compares two of them, so a semaphore identity inside it
  changes equality.
- **The dependency.** pikuri is stdlib `Mutex` throughout; `concurrent-ruby` is this host's
  dependency, not pikuri's. A counting semaphore is ~20 lines on `Mutex` + `ConditionVariable`.
  Probably hand-roll rather than add the gem.
- **Fairness.** Worth deciding deliberately upstream, having accepted "no guarantee" here.

## Graduation

The decision goes in `../pikuri/DECISIONS.md` — this is the agent loop, which AGENTS.md puts on the
library's side of the seam. This side would then record only the consequence: `ThrottledAdapter`
retires, `D_throttle_at_the_request` gets a `Superseded by` status, and the wiring moves from
`ModelCatalog.from_llms(permits:)` to whatever the control's injection point is. It lands here only
after a pikuri release (`D_released_pikuri_gems`).

Consider moving this file to `../pikuri/ideas/` — it is now entirely an upstream idea. Kept here
while the motivating evidence is freshest on this side.
