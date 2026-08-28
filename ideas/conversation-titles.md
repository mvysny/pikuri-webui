# Conversation titles

Today a conversation's title is its start stamp (`ConversationStore#stamp_title`), rendered in the
sidebar. Two ways to make it say something: the model writes one, or the user does. The v1
conversation sidebar shipped without either; this is what "v2 auto-title" was in
`ideas/multiple-conversations.md`, which has graduated.

`meta.json` already carries `title` and the schema is versioned, so neither option needs a format
change — and the title deliberately never appears in the path, so retitling never moves a directory.

## Auto-title

- **Never on the agent's own chat.** A titling request through `Pikuri::Agent` lands in the
  conversation history and pollutes it. It needs its own one-shot chat — a no-tools second
  `Pikuri::Agent` (lean: reuses `bin/pikuri-web-chat`'s connection/context wiring) or a raw
  `RubyLLM::Chat` off the same connection.
- **When:** from the first user message alone (Web Claude's behaviour — fast, sometimes wrong) or
  after the first assistant reply (better, later). Lean: first user message, fire-and-forget on a
  background thread. A titling failure must never fail the turn — it just leaves the stamp.
- **Sanitizing:** single line, strip markdown/quotes/trailing period, cap length, fall back to the
  stamp on junk or nothing. A model answering "Sure! Here's a title:" is the normal case.
- **`Q_title_length` — unsettled.** The original ask said 10–20 words. That is long for a
  `clamp(12rem, 20%, 20rem)` sidebar row; Web Claude's run 3–7. Suggest ≤60 chars / ~4–8 words,
  one line, ellipsised in CSS. Settle this before building either half — if short titles win, manual
  rename may be the whole feature.
- **Cost:** one extra small request per new conversation. Negligible against a local llama.cpp, but
  another thing to fail on the trifecta-free path. Off by default with a `[web] auto_title` knob?
  Note `D_schema_complete_config` — a new key goes into `Config`'s whole-schema port.

## Manual rename

The cheap alternative, and plausibly auto-title's escape hatch rather than a competitor: a pencil on
the row, `PATCH /conversations/:id`. Worth asking whether v2 should be rename *first*.

Delete has shipped the shape a rename should copy (`D_delete_no_undo`): a second submit button in
the row's existing form, aimed with `formaction` at `/conversations/:id/<verb>`, and a bare
`conversations` SSE event that tells every tab to re-fetch the list through `app.js`'s one
`refreshSidebar()`. A rename needs a text input rather than a button, which is the only part that is
genuinely new — and `ConversationStore` already owns `meta.json`, where the title lives.
