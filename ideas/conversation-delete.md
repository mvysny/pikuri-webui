# Deleting conversations

`Q_retention` from `ideas/multiple-conversations.md` (graduated), the one verb `ConversationStore`
never grew. There is no cap and no cleanup: conversations accumulate until the user runs `rm -r`,
which is what README tells them to do.

What a delete button needs settled:

- **Confirmation, and of what kind?** A native `confirm()` is one line of `app.js` and the only
  zero-CSS option; an undo-style "deleted, undo" needs somewhere to hold the folder. Note
  `D_no_js_build_step` — `confirm()` is fine, a modal component is the kind of thing that argues for
  a build step.
- **Deleting the *live* conversation needs a rule.** `AgentRunner` holds it, so delete has to either
  refuse (the way switching refuses while busy) or roll the runner onto a fresh conversation the way
  `#new_conversation` does. The latter is more useful and is probably just
  `new_conversation` + `rm -rf` in the right order.
- **Refuse while busy**, same as `POST /conversations` and select — 409 and a disabled control.
- `ConversationStore#find` resolves through `#list`, so a delete route never turns user input into a
  path. Keep it that way: `delete(conversation)`, never `delete(id)`.

## `Q_conversation_count` — when the list gets long

200 conversations in the sidebar: scroll only, or search / "load more"? v1 answered "scroll" by
doing nothing, which is fine and stays fine for a while. The thing not to do is paint ourselves out
of a search box — and note the listing cost is already recorded in `ConversationStore#list`'s rdoc
(one `meta.json` per conversation, no index, measure before caching).

Delete is the cheaper half of the same pressure: a list you can prune may never need a search box.
