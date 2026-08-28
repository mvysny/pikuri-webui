# Background turns

Today switching conversations is *refused* while the agent is mid-turn: sidebar rows go dim, and
`POST /conversations/:id/select` answers 409. That was `Q_switch_while_busy` settled for v1 in
`ideas/multiple-conversations.md` (graduated) — honest, because there is one live conversation, and
the only option that doesn't grow topics. Cancelling the turn was rejected outright: silently
throwing away a turn because someone clicked a row is worse than not letting them click.

**The v2 version: let the turn run while the user views another conversation.** Not a patch on v1 —
it rewrites who owns what, which is why it was ordered last. Roughly in dependency order:

- **A conversation id on everything the runner emits.** `SseListener` writes into *the* transcript
  today; it would take the conversation's transcript, and `AgentRunner` would know which
  conversation its worker thread belongs to.
- **Per-conversation topics in `Broadcaster`** — `subscribe(conversation_id)`, and `broadcast` gains
  a topic. This is the "fan-out stops being a broadcast" cost `D_single_shared_conversation` names.
  ~20 lines, but it is the invariant that entry rests on, so it needs its own `D_` entry rather than
  a quiet edit. The heartbeat and the `close` sentinel stay global.
- **N transcripts resident in memory** — the one genuinely new structure, and where a
  `ConversationSession`-shaped thing would finally earn itself. v1 has exactly one, emptied and
  refilled in place (`D_replay_from_history`: rebuilt, not swapped). Nothing built so far assumes
  there can only be one, but nothing provides for two either.
- **A "busy elsewhere" affordance** in the sidebar — a spinner or dot on the row with the live turn,
  or the feature is invisible until the user goes looking.
- **Still one live turn at a time.** Background ≠ parallel: `AgentRunner` owns one agent whose
  history is the conversation's, so a *second* turn elsewhere needs a second agent — second history,
  second `TokenLog`, second interloper. v2 should explicitly refuse it, the way v1 refuses
  switching: submit in a non-live conversation is rejected.

## What this unlocks: per-URL conversations

`D_single_shared_conversation` picked server-global selection (one selected conversation, every tab
follows, changed by POST) and named per-URL `/c/<id>` as "where this goes if background turns ever
make the other pane genuinely alive". That is this idea. Once frames are topic-addressed and
transcripts are resident, a tab sitting on its own conversation is nearly free, and B's real
objection — two panes where only one accepts input — weakens exactly when background turns exist.

Side benefit: with rows as honest links rather than `<form method="post">` submit buttons, the
prefetch hazard (`Q_get_side_effects`, and the ~10 lines of CSS that un-button a button) evaporates.
