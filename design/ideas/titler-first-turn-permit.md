# Does the titler take the first turn's only permit?

Status: **verified with a fake server (2026-10-29); fix not chosen.** Spotted while fixing pikuri-core's
first-turn echo, where the user turn is now emitted before the `/props` probe
(the deferred cap probe entry in pikuri's `design/decisions.md`).

The `[titler]` agent (`lib/pikuri_web/agents/titler.rb`) can sit on the same
`[[server]]` as the conversation's model. When that server has
`max_concurrent_requests = 1`, `Runner#maybe_title` posts the titling job beside
the first turn. If the titler's request reaches `ServerPermits` first, the turn
waits for it, so the first thinking frame is delayed. The echo is not affected.

The titler is a full `Pikuri::Agent`, so its first `run_loop` also probes
`/props` unless its transport states a cap and the server is already sized.
Against a router, that probe may also load the titler's model.

## Measured: yes, the titler wins

Fake llama server, `max_concurrent_requests = 1`, titler and chat on the same
server, the titler's `[[llm]]` with a `context_window` (the README recipe).
The title completion takes 2 s; times are from `POST /messages`:

| | warm model (`/props` 0.05 s) | cold model (`/props` 3 s) |
|---|---|---|
| titler's completion sent | +0.01 s | +0.01 s |
| turn's completion sent | +2.01 s (waited for the title) | +3.01 s (after the probe) |
| first thinking frame | +2.73 s | +3.74 s |

The titler always gets there first, not by luck. Its transport states a cap
and boot's `ServerPermits.limit` has already sized the server, so its
`run_loop` skips `/props` and goes straight to the request. The turn's
transport states no cap, so a fresh agent probes `/props` first. On a warm
model the turn then waits for the whole title, here 2 s.

The cold column flatters us. The fake serves completions while `/props`
"loads", and a real router does not. There, the title request waits on the
same model load, takes the slot right after it, and the turn waits for the
title on top of the load.

## Proposed fix: title at the turn end

Post the titling job from `Runner#finish_turn` instead of beside the turn in
`#submit`. A turn's requests are then all done before the title asks for the
slot, so the race is gone, not just less likely.

- `#submit` stops calling `maybe_title`. It keeps the opener (an ivar, set only
  when the conversation is still stamp-titled and none is kept yet) for
  `finish_turn` to pass on.
- `finish_turn` calls `maybe_title(opener)` after `persist`. Its guards stay as
  they are: at most once per runner, never for a discarded conversation.
- A cancelled or failed first turn still titles: the opener was the user's
  either way, and a title is no request the turn could still be waiting for.
- The cost is that the sidebar shows the start stamp until the first answer
  completes. That is a cosmetic delay; the race delayed the answer itself.
- `Runner`'s class header (== The title) and `D_lazy_retro_titling` say the job
  goes *beside* the turn; both change with it.

Rejected: starting on the turn's first `Tokens` (TokenLog's `on_status_line`)
so a title slips into a tool gap. It is earlier, but it mixes titling into the
token readout's hook, and after a fast tool it races the next completion
anyway.

## Open questions

- `Q_titler_restore`: `#restore!` also titles an old, stamp-titled conversation
  when it is opened, so typing right after opening one hits the same race.
  Deferring that path to the first turn end too would make the two paths one,
  at the cost of an old conversation that is only read never getting titled.
