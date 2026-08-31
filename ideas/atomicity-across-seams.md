# Atomicity across seams — the audit, and what is left of it

Where this came from: a status bar stuck on "waiting for a free slot" while the agent was
demonstrably working. Chasing it reopened `D_no_event_queue` (see its **Reopened** section, which
carries the argument and is the durable half of this). This file is the *working* half — the audit
results and the open items. Delete it when the last row of the table below is closed.

**The frame.** A database is not storage for a Rack app, it is the concurrency architecture: A is
the work packet, I is the untorn cross-object read, serializability is the total order. This app
removed the database and replaced neither. The partition (`D_conversation_owns_agent`) does supply
**I** — one writer per conversation — and that is why so much of this holds up. **A across a seam
is the hole**: two objects that must be mutated or read as one unit.

## The seams

| # | seam | status |
|---|---|---|
| 1 | state change + its notification (`AgentRunner#claim_running`) | **fixed** — broadcast on both paths |
| 2 | compose + publish (`AgentRunner#status_data` → `Broadcaster`) | **open** |
| 3 | page snapshot + SSE subscribe | **fixed** — `D_subscribe_then_snapshot` |
| 4 | transcript append + broadcast (`SseListener`) | safe — single-writer |
| 5 | resolve + open (`App#open_conversation`) | **fixed** — `ConversationRegistry#open_id` |

Two of the three fixes needed no lock at all, which is the most useful thing the audit turned up:
seam 3 closed on **ordering** (subscribe first, so the overlap is a duplicate and duplicates are
free), seam 1 on putting the broadcast where the transition is. Only seam 5 wanted a lock, and the
registry already had it.

## Open: seam 2, compose + publish

`broadcast_status` composes `status_data` off unlocked state and hands it to a `Broadcaster` that
snapshots subscribers under its lock and pushes *outside* it. Two threads can compose in one order
and push in the other, and the browser keeps the last frame it received — so it can be left showing
`idle` over a running turn. Forced deterministically in PROBE 6.

**Not a low-hanging fix.** The obvious move — compose under the runner's mutex — risks the deadlock
`agent_runner.rb`'s `#state` comment exists to avoid: `broadcast_status` is re-entered from the
Interloper's `on_change`, which fires from inside pikuri's own enqueue. Candidates:

- A monotonic sequence stamped inside the same critical section as the state change, with
  `statusbar.js` dropping any frame below the highest seen. Transport mechanics, so it is on the
  right side of `D_no_js_build_step`. ~3 lines each side.
- Compose-and-push as one unit under a lock that is *not* the runner's, taken only by the status
  path.
- Whatever the `D_no_event_queue` mechanism turns out to be, if it lands first.

**Direction chosen (2026-08-31): the third.** The owner reopened the mechanism question for
real — see `ideas/global-monitor.md`, which designs it. Seam 2 waits for it; the sequence
number is parked as the fallback if that work stalls.

## Open: `ConversationRegistry#open` is still a footgun

`#open_id` fixed the app's path by re-resolving under the monitor. `#open(conversation)` itself will
still mint a live runner for a conversation whose folder was deleted a moment ago — PROBE 7 in the
sidecar still demonstrates it. Nothing in the app reaches it that way now; `#create` is the only
remaining caller and it holds a conversation it just minted. Making it private is the tidy answer
and costs a sweep of the specs that use it.

## Known and accepted, not bugs

- **A queued turn shows the user nothing they sent** (PROBE 5). `POST /messages` answers 204 when
  the turn is *claimed*; the user block is rendered by the listener on the agent thread, which has
  not run yet. With `--turns 1` and a busy conversation the composer has cleared the box and the
  transcript is empty for the whole wait. The in-flight window wants a pending state — and note it
  is a *different* window from "busy", so it does not collide with
  `D_interloper_mid_loop_input`'s "input stays enabled while busy".
- **Double-submit has no server-side guard.** Two tabs on one conversation is supported, so no
  client-side button disabling can cover it; the answer is an idempotency key on `POST /messages`,
  which is what Vaadin's client-to-server message id does. The optimistic clear in `composer.js`
  accidentally covers the single-tab mash today.
- **A tab watching a conversation someone else deletes** keeps showing it — the sidebar row goes,
  the transcript pane is never told (PROBE 8). Cosmetic.
- **The server keeps nothing to replay across an SSE reconnect** — no `id:` field, so no
  `Last-Event-ID` (PROBE 4). `app.js`'s `es.reconnected` reload compensates.
- **Blocking I/O under locks.** `ConversationStore#list` / `#delete` run under the registry monitor;
  `#persist` runs under the runner mutex that `#submit` also takes, so a slow disk parks request
  threads. Not a correctness bug; it is the never-block hazard already present, before any owner
  thread exists.

## The probes

`ideas/atomicity-across-seams/seam_audit_spec.rb`. Not in `spec/` on purpose: several probes assert
what the app does *today* rather than what it should do, and a suite member that asserts a bug goes
red as a "regression" the day someone fixes it. To run:

    cp ideas/atomicity-across-seams/seam_audit_spec.rb spec/pikuri_web/ && bundle exec rspec spec/pikuri_web/seam_audit_spec.rb

PROBE 7 is expected to fail — that is the `#open` footgun above. The rest pass.

**Harness trap, learned the hard way:** rack-test requests arrive as host `example.org` and Sinatra
403s them unless the app is `set :environment, :test`. A probe asserting *absence* passes happily
against `"Host not permitted"`. Any new probe wants its no-fix failure confirmed by stashing the fix.

## Next

Superseded (2026-08-31): the owner decided `D_no_event_queue` the other way — one global
serialization domain, being designed in `ideas/global-monitor.md`. That file inherits this one's
probe method and carries the per-seam-vs-global argument (this audit's finding, recorded there
as the alternative the graduating D entry must answer). What remains *here* is the working
state: seam 2 stays open until the mechanism closes it, PROBE 7 / the `#open` footgun stands,
and the known-and-accepted list above is untouched by the mechanism (request-to-request seams).
