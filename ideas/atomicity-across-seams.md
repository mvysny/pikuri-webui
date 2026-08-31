# Atomicity across seams — what is left of the audit

Where this came from: a status bar stuck on "waiting for a free slot" while the agent was
demonstrably working. Chasing it reopened `D_no_event_queue`, which led — via the
(now graduated) global-monitor idea — to `D_global_monitor`: one serialization domain,
run-to-completion tasks. This file is what the audit left behind that the mechanism did *not*
close. Delete it when the last item below is resolved or filed elsewhere.

## The seams (final state)

| # | seam | status |
|---|---|---|
| 1 | state change + its notification (`AgentRunner#claim_running`) | **fixed** — broadcast on both paths, now inside the same task |
| 2 | compose + publish (`AgentRunner#status_data` → `Broadcaster`) | **closed structurally** — `D_global_monitor`; the flipped PROBE 6 in agent_runner_spec is the acceptance test |
| 3 | page snapshot + SSE subscribe | **fixed** — `D_subscribe_then_snapshot`; the server half now shares a task, the duplicate tolerance covers the page-render-to-connect gap |
| 4 | transcript append + broadcast (`SseListener`) | **closed structurally** — one task per block |
| 5 | resolve + open (`App#open_conversation`) | **fixed** — `ConversationRegistry#open_id`, now a task |

## Open: `ConversationRegistry#open` is still a footgun

`#open_id` re-resolves inside its own method (one task); `#open(conversation)` itself will
still mint a live runner for a conversation whose folder was deleted a moment ago — PROBE 7 in
the sidecar still demonstrates it, and `D_global_monitor` notes it is untouched by the
mechanism (the stale `Conversation` value is held *across* tasks). Nothing in the app reaches
it that way now; `#create` is the only remaining lib caller. Making it private is the tidy
answer and costs a sweep of the specs that use it.

## Known and accepted, not bugs

- **A queued turn shows the user nothing they sent** (PROBE 5). `POST /messages` answers 204
  when the turn is *claimed*; the user block is rendered by the listener on the agent thread,
  which has not run yet. With `--turns 1` and a busy conversation the composer has cleared the
  box and the transcript is empty for the whole wait. A request-to-request seam — the domain
  does not reach it. The in-flight window wants a pending state, distinct from "busy".
- **Double-submit has no server-side guard.** Two tabs on one conversation is supported, so no
  client-side button disabling can cover it; the answer is an idempotency key on
  `POST /messages`. The optimistic clear in `composer.js` accidentally covers the single-tab
  mash today.
- **A tab watching a conversation someone else deletes** keeps showing it — the sidebar row
  goes, the transcript pane is never told (PROBE 8). Cosmetic.
- **The server keeps nothing to replay across an SSE reconnect** — no `id:` field, so no
  `Last-Event-ID` (PROBE 4). `app.js`'s `es.reconnected` reload compensates.

## The probes

`ideas/atomicity-across-seams/seam_audit_spec.rb`, updated for the domain (guarded proxies,
per `spec_helper`'s `guard`). Not in `spec/` on purpose: several probes assert what the app
does *today* rather than what it should do, and a suite member that asserts a bug goes red as
a "regression" the day someone fixes it. PROBE 6 graduated into `agent_runner_spec` flipped;
PROBE 7 is *expected to fail* — that is the `#open` footgun above. To run:

    cp ideas/atomicity-across-seams/seam_audit_spec.rb spec/pikuri_web/ && bundle exec rspec spec/pikuri_web/seam_audit_spec.rb

The rack-test host trap (a probe asserting absence passing vacuously against
"Host not permitted") is recorded in AGENTS.md Conventions.
