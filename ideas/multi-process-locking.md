# Locking against a second process

`Q_multi_process` from `ideas/multiple-conversations.md` (graduated). Two `pikuri-web-chat`
processes on different ports — or, once pikuri-tui adopts the history, the TUI — share
`~/.local/state/pikuri/pikuri-web-chat/conversations/` and both rewrite `history.json` wholesale.

The failure is *not* a torn file: `History#save` is temp-file-and-rename, so what is on disk is
always a complete valid history. It is a **silently clobbered conversation** — the loser's turns
vanish at the next save, with nothing on screen to say so. README now warns about this under
**Conversations**; nothing enforces it.

**Delete makes it worse, and is the first destructive case.** Since `D_delete_no_undo` the loser can
be a conversation that no longer exists: process A deletes the folder, process B still holds it live
and writes it straight back at its next turn end. The user watched it disappear from the sidebar and
it reappears — a resurrection, not just a lost turn. Accepted as a limitation there, and it is the
strongest argument on this page: last-writer-wins is defensible for turns and indefensible for a
deletion the user explicitly confirmed.

Options:

- **`flock` the conversation directory on open**, and render the conversation read-only in the
  sidebar if the lock is held. Lean: losing turns silently is exactly the failure persistence was
  added to prevent, and a dimmed row with a reason is the same affordance the busy-refusal already
  uses.
- **Last-writer-wins and don't care.** It is a single-user tool; the second process is a mistake the
  user made. The README line may be the whole of the honest answer.

Cheaper middle ground worth pricing first: lock the *state root* once at boot and refuse to start a
second instance against it, with `--port` in the error. That is one `flock` in `bin/pikuri-web-chat`
instead of per-conversation state in `ConversationStore`, and it kills the failure outright rather
than degrading it — at the cost of forbidding a legitimate second instance that never touches the
same conversation.

Note `D_per_shell_state_root`: cross-shell sharing is deliberately *not* the current arrangement, so
today's only colliders are two copies of this shell. That gets less true if a shared location ever
lands, which is the moment this stops being optional.
