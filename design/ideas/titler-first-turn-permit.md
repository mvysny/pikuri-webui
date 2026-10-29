# Does the titler take the first turn's only permit?

Status: **suspected, not verified.** Spotted while fixing pikuri-core's
first-turn echo, where the user turn is now emitted before the `/props` probe
(`D_deferred_cap_probe` in pikuri's `design/decisions.md`).

The `[titler]` agent (`lib/pikuri_web/agents/titler.rb`) can sit on the same
`[[server]]` as the conversation's model. When that server has
`max_concurrent_requests = 1`, `Runner#maybe_title` posts the titling job beside
the first turn. If the titler's request reaches `ServerPermits` first, the turn
waits for it, so the first thinking frame is delayed. The echo is not affected.

The titler is a full `Pikuri::Agent`, so its first `run_loop` also probes
`/props` unless its transport states a cap and the server is already sized.
Against a router, that probe may also load the titler's model.

## Open questions

- `Q_titler_order`: does the titler actually win the permit in practice? Try a
  fake server with one slot and a slow titler completion, and time the first
  thinking frame.
- `Q_titler_defer`: if it does, should titling start only after the turn's
  first `Tokens`, or after the turn ends?
