# Search bar over the conversation list

A search box above the sidebar list that filters conversations by a simple full-text match over
what is actually in them — not just titles. Type, wait ~300ms, the list narrows.

This is the answer to **when the sidebar list gets long** — 200 conversations, and v1 answered
"scroll" by doing nothing, which is fine and stays fine for a while. It is also how deleting old
conversations becomes bearable: **filter, then delete.** A prune UI that makes you scroll 200 rows
looking for the one about Postgres is not a prune UI. Delete itself has shipped
(`D_delete_no_undo`), so this is now the missing half rather than a co-design.

Two things delete already built that this should reuse rather than reinvent:

- **`refreshSidebar()` in `app.js`** is the single path every list re-render goes through (the
  `reset` and `conversations` SSE events both call it). The "re-send the current query" rule below
  is a change to *that one function*, which is also what keeps a delete or a switch from silently
  un-filtering the list.
- **The `conversations` SSE event** is the bare "the list changed, re-fetch it" signal. A search
  that is open when another tab deletes a row gets the refresh for free, provided the query rides
  along.

## The shape

- **Blank or whitespace query → today's behaviour**, i.e. everything, newest first, capped at 200.
- **Non-blank → the same list, filtered**, still newest first, still capped at 200. No relevance
  ranking: there are no scores without an index, and ordering by `created_at` is what keeps the list
  holding still (`ConversationStore#list`'s rdoc). Over-200 matches just get truncated — tell the
  user with a row at the bottom rather than silently.
- **Case-insensitive substring.** Not regex, not word-stemming, not AND/OR. Whatever the box holds,
  found anywhere.
- **`Q_debounce`** — 300ms after the last keystroke. 500ms/1s feel sluggish for a local tool; 300ms
  is enough to keep a fast typist from firing eight searches. Settle by trying it.
  - **Last-wins, not first-wins.** Debouncing alone still races: a slow search for `pg` can land
    after a fast one for `pgvector` and overwrite it. Needs an `AbortController` on the previous
    fetch, or a sequence number the handler checks before swapping. ~5 lines, and invisible until
    someone has 200 conversations.

## Route and rendering

`GET /conversations?q=…` — the fragment endpoint app.js already re-fetches after a `reset`, with a
query param. Rendering stays in `_sidebar.erb`; JS debounces, fetches, swaps innerHTML. That is the
same move the existing reset handler makes, so `D_no_js_build_step` is untroubled: no client-side
rendering, no filtering in the browser (the browser doesn't have the conversation bodies and must
not).

A `GET` with a query param has no side effects, so `Q_get_side_effects` doesn't come due — rows stay
`<form method="post">` submit buttons.

**The swap must not eat the search box.** The input sits *above* the list and the list is what gets
replaced, or every re-render (a search, a `reset`, a switch) blows away the user's focus and
half-typed query. So the innerHTML target becomes the `<ul>`, not the `<nav>` — which means moving
the existing reset handler's target too. Also: the reset/switch refresh should re-send the current
query, or switching conversations silently un-filters the list.

## Reading the conversations — `Q_search_reader`

`ConversationStore` is Pikuri-free and deals in paths (`D_pikuri_free_core`). Search has to read
`history.json`, which is pikuri's file. Three ways, and the tension is real:

- **(a) Raw substring scan of the file's bytes.** Zero format knowledge, trivially cheap. **Broken,
  though:** the file is JSON, so text is escaped — a search for `clear notifications` misses a
  source that has `clear\nnotifications`, and a search for `content` matches every key in the file.
  Also matches `role`, `model_id`, ids and digests. Rejected.
- **(b) Parse the JSON, walk known fields.** Lean. The parser un-escapes for free, and the field
  list is short (see below). Costs `ConversationStore` some knowledge of pikuri's *format* — but no
  `Pikuri::*` constant, and `history.json` carries a `version` so the walker can degrade (skip, or
  match titles only) on a version it doesn't know rather than guess.
- **(c) `Pikuri::Agent::History.load`, from a fourth adapter.** Correct and in-seam, and the *worst*
  performer by a distance: `History` holds attachment bytes **eagerly** (its own rdoc says so, and
  says why), so loading one to grep its text pulls every image the model was ever shown into memory.
  Searching 200 conversations that way is absurd. This is the option that looks principled and
  isn't.

**What to match on** (`Q_search_scope_fields`) — from a real `history.json`, a message is:

```json
{ "id": "01a04469f2d4…", "role": "user", "kind": "user",
  "content": "I can open Gnome's notification pane via Super+V, …",
  "thinking": { "text": "The user is asking about a GNOME desktop…" },
  "tool_calls": [ { "name": "web_search", "arguments": { "query": "GNOME clear all notifications" } } ] }
```

- `content` — always a plain String (upstream guarantees it; `Content` objects are split into text +
  attachments at export). Tool *results* are messages too, so scraped web pages are searched, which
  is most of the value.
- `tool_calls[].arguments` — small, and "what did I search for that time" is a real query.
- `thinking.text` — noisy, and matching it shows a row whose match the user can't see in the
  transcript unless they expand. Include it? Lean yes, simpler and the transcript does render
  thinking.
- The title from `meta.json` — **free**, since `#list` already reads it. Two-tier: title hits cost
  nothing, bodies cost a file open.

## Cost, and why no index yet

Newest-first order is a lexical sort on the directory name and opens nothing, so: **iterate
newest-first and stop at 200 hits.** A common query is then cheap regardless of folder size; only a
query matching little or nothing reads everything.

Worst case is real but small: upstream measured `history.json` at 0.39 MB for 200 messages and
3.86 MB for 2000, so 200 fat conversations is ~80 MB of reads — tens of ms warm, worse cold, on a
single-user local tool. Fine. **A full-text index or a database is v2**, and `#list`'s rdoc already
carries the rule: measure a slow sidebar before trading a directory for a cache of one.

## Attachments

**v1: text attachments only, by recorded MIME type.** The mime is in `history.json` beside the
message and the file is `attachments/<digest10>-<stem><ext>` — so having parsed the JSON (option b)
we already know which stored files are text, with no sniffing.

**v2: PDF / ODT / DOC.** Needs extractors; note `pikuri-pdf` is already a path dependency, so the
PDF half may be nearly free — check what it exposes before assuming.

## Loose ends

- **`Q_unsupported_rows`** — a conversation whose `meta.json` is unreadable lists as
  *unsupported format* but still has a `history.json`. Search it? Lean yes: search is exactly how
  you would find a broken one in order to delete it.
- **`Q_highlight`** — show the matching snippet under the title instead of the relative time, the
  way Web Claude does? Nice, and it is the thing that makes a body match legible at all — a row that
  matched on a tool result looks identical to one that matched on its title. Probably v1.5.
- No new block kinds and no new CSS tokens: the search box is chrome beside the transcript, same as
  the sidebar it sits in (`--bg-raised`, `--border`).
