# Search bar over the conversation list

A search box above the sidebar list that finds a conversation by a simple full-text match over what
is actually in it — not just its title. Type, wait ~300ms, the list narrows.

**What it is for: reaching a conversation the sidebar no longer shows.** The list is capped (or
will be — see `Q_list_cap`), so past the cap a conversation is unreachable by scrolling at all.
Search is the route to it. The target query is *the Postgres thing from six weeks ago*, and that
frames every trade-off below: results are old, few, and remembered vaguely.

Deleting a found conversation comes free — a row already carries its delete form (`D_delete_no_undo`)
— but this is **not** a prune feature and there is no bulk delete. Finding one is the whole job.

Two things the delete work already built that this should reuse rather than reinvent:

- **`refreshSidebar()` in `app.js`** is the single path every list re-render goes through (the
  `reset` and `conversations` SSE events both call it). The "re-send the current query" rule below is
  a change to *that one function*, which is also what keeps a delete or a switch from silently
  un-filtering the list.
- **The `conversations` SSE event** is the bare "the list changed, re-fetch it" signal. A search that
  is open when another tab deletes a row gets the refresh for free, provided the query rides along.

## `Q_list_cap` — the prerequisite, and it does not exist yet

**Open, and it blocks everything else.** `ConversationStore#list` returns *everything* today —
`@root.children.filter_map { row(_1) }.sort_by(&:id).reverse`, no limit — and `_sidebar.erb` renders
whatever it is handed. The cap is a plan, not the code. Which means: without it, search is a
convenience filter over a long list; with it, search is the only way to reach conversation 201. Build
the cap first, or search is solving a problem the app does not have yet.

- **Where it lands.** Lean `#list` itself, so every caller inherits it — but the resident-unsaved
  rows `ConversationRegistry#rows` merges in are exempt, since those are the ones being typed in
  right now.
- **A silent cap is a bug.** If 231 conversations simply stop existing with no affordance, nobody
  ever discovers search. The list needs a status row at the foot of the `<ul>`: *"200 of 431 — search
  to reach the rest."* That is the same slot as the truncated-results row below, so it is one line
  with three states: uncapped (absent), capped, and more-matches-than-shown.
- 200 is a guess. It only has to be larger than "what anyone scrolls" and small enough to render fast.

## The shape

- **Blank or whitespace query → today's behaviour**, i.e. everything, newest first, up to the cap.
- **Non-blank → the same list, filtered**, still newest first, still capped. No relevance ranking:
  there are no scores without an index, and ordering by `created_at` is what keeps the list holding
  still (`ConversationStore#list`'s rdoc). Over-cap matches get truncated — say so in the status row
  rather than silently.
- **Case-insensitive substring.** Not regex, not word-stemming, not AND/OR. Whatever the box holds,
  found anywhere. Match with `Regexp.new(Regexp.escape(q), Regexp::IGNORECASE)` against the parsed
  field strings — `file.downcase.include?` allocates a downcased copy of every history and doubles
  the read budget below.
- **`Q_debounce`** — 300ms after the last keystroke. 500ms/1s feel sluggish for a local tool; 300ms
  is enough to keep a fast typist from firing eight searches. Settle by trying it.
  - **Last-wins, not first-wins.** Debouncing alone still races: a slow search for `pg` can land
    after a fast one for `pgvector` and overwrite it. Needs an `AbortController` on the previous
    fetch, or a sequence number the handler checks before swapping. ~5 lines. Note the client-side
    abort does *not* stop the server read — that scan runs to completion on its Puma thread. Fine for
    one user; just don't claim the abort saves work.

## Route and rendering

`GET /conversations?q=…` — the fragment endpoint app.js already re-fetches after a `reset`, with a
query param. Rendering stays in `_sidebar.erb`; JS debounces, fetches, swaps innerHTML. That is the
same move the existing reset handler makes, so `D_no_js_build_step` is untroubled: no client-side
rendering, no filtering in the browser (the browser does not have the conversation bodies and must
not).

A `GET` with a query param has no side effects, so `Q_get_side_effects` does not come due — rows stay
`<form method="post">` submit buttons for delete, and `<a href>` links for open.

**`Q_query_in_url` — the query belongs in the URL, not just in the box.** Lean settled, worth a
sanity check while building. The innerHTML swap eating the search box is the small half of this; the
big half is that **rows are links**, so opening a result is a full page load and `GET /c/:id` renders
a fresh sidebar that knows nothing about the query. Search, open a hit, come back for the next one —
box empty, list un-filtered.

So `q` rides in the URL:

- Row links become `/c/<id>?q=…`; `GET /c/:id` renders the sidebar already filtered and the box
  pre-filled from `params['q']`.
- The box is a plain `<form method="get">`, which app.js only intercepts in order to debounce — so it
  degrades without JS, the way the delete form's 303 does.
- `refreshSidebar()` re-sends the current query alongside `viewing`.

This keeps the sidebar server-rendered (`D_server_authoritative_transcript`) and puts per-tab state
where this app already puts it — the URL, same as which conversation a tab views (`D_no_event_queue`).
`sessionStorage` would also be legal under the per-browser-state rule, but it invents client state
where a URL already works.

**The swap must not eat the search box.** The input sits *above* the list and the list is what gets
replaced, so the innerHTML target becomes the `<ul>`, not the `<nav>` — which means moving the
existing reset handler's target too.

## `Q_where_search_lives` — not in `ConversationStore`

**Open, but leaning hard.** `ConversationStore`'s own docs swear it does not do this: *"the
`history.json` beside it is pikuri's, and is never read or written here"*, and the class header leans
on being a paths-and-`meta.json` class. Reading histories walks straight through that sentence.

Lean: a collaborator — `ConversationSearch`, or a `HistoryGrep` that takes a directory and answers
about it — with `#list` filtering through an injected predicate. Then exactly one new file knows
pikuri's *format*, and the store keeps its promise.

Whether that new file is a fourth adapter under the AGENTS.md seam rule (`D_pikuri_free_core`) needs
saying out loud, because it is the precedent the next such thing will cite. Reading: the seam is
about `Pikuri::*` *constants*, and this file names none — it knows a JSON shape. That is a weaker
coupling, and `history.json`'s `version` field is what makes it survivable (see below).

## `Q_search_reader` — how to read a conversation

Settled: **(b)**, parse the JSON and walk known fields. The three options and why:

- **(a) Raw substring scan of the file's bytes.** Zero format knowledge, trivially cheap. **Broken,
  though:** the file is JSON, so text is escaped — a search for `clear notifications` misses a source
  that has `clear\nnotifications`, and a search for `content` matches every key in the file. Also
  matches `role`, `model_id`, ids and digests. Rejected.
- **(b) Parse the JSON, walk known fields.** Lean. The parser un-escapes for free, and the field list
  is short (below). Costs knowledge of pikuri's *format* — but no `Pikuri::*` constant, and
  `history.json` carries a top-level `version` (confirmed: `Pikuri::Agent::History::CURRENT_VERSION`
  is 1, and `HistoryFile.load` raises on anything higher) so the walker can degrade on a version it does
  not know — skip the bodies, match titles only — rather than guess.
- **(c) `Pikuri::Conversations::HistoryFile.load`, from a fourth adapter.** Correct and in-seam, and the *worst*
  performer by a distance: `History` holds attachment bytes **eagerly** (its own rdoc says so, and
  says why), so loading one to grep its text pulls every image the model was ever shown into memory.
  Searching hundreds of conversations that way is absurd. This is the option that looks principled
  and is not.

**The reader returns the match, not a boolean** — field plus offset, or the surrounding ±60
characters. See `Q_highlight`: building it boolean-first means re-reading every file when snippets
land, and snippets are v1.

## `Q_search_scope_fields` — what to match on

Settled, except where noted. From a real `history.json`, a message is:

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
- `thinking.text` — noisy, and a thinking match is one the user cannot see in the transcript without
  expanding. Include it: the transcript does render thinking, and with snippets shipping in v1 the
  match is at least legible in the result row.
- The title from `meta.json` — **free**, since `#list` already reads it.

**The free tier stopped being weak — titles landed first.** The sequencing argument here was that
start-stamp titles (`stamp_title`) let the zero-cost tier match only dates, so titles should come
first. They did (`D_titler_connection`, `D_lazy_retro_titling`): a conversation is named from its
opening message, and old ones are named as they are opened. So the cheap tier is now the tier that
actually works, and most searches should never need to open a `history.json`. **Re-cost this feature
against real titles before building anything** — the file-reading tiers below may not be worth it
any more. Note the corollary: a conversation nobody has opened since the titler was configured is
still stamp-titled, so the free tier is not uniformly good yet.

## Cost, and why no index yet

**The early-stop optimization does not fire for the queries this feature exists to serve.** Iterating
newest-first and stopping at the cap is cheap for a query that matches a lot — but the target query
matches three conversations out of five hundred, and finding those three means reading all five
hundred. So: **a full scan is the normal case here, not the worst case.** State it that way; the
optimization is still worth having for the vague queries that match everything, but it is not the
cost argument.

The budget, honestly: upstream measured `history.json` at 0.39 MB for 200 messages and 3.86 MB for
2000, so 200 fat conversations is ~80 MB of reads per search — tens of ms warm, worse cold, on a
single-user local tool. Probably fine. **The thing to measure before shipping is a cold-cache search
over a large folder**, not a warm one; that is where a directory-scan design would actually hurt.

A full-text index or a database is v2, and `#list`'s rdoc already carries the rule: measure a slow
sidebar before trading a directory for a cache of one. The cold-cache number above is that
measurement's trigger.

## `Q_highlight` — the snippet is v1, not a nicety

Promoted from "probably v1.5". With timestamp titles, a result list for `postgres` is five rows
reading `2026-06-14 09:22` / `2026-06-14` — the title, and then the date again. Nothing on the row
says *why it matched*, and for a six-week-old conversation there is no memory to match it against
either. The snippet under the title is what makes a result list usable at all; it replaces the
relative-time label on rows that matched a body.

The other half of this is already done: `RelativeTime.humanize` drops to an absolute `%Y-%m-%d` past
its 30-day `CUTOFF`, which is exactly the right label for results this old.

## Accepted: only what is on disk is searched

Not an open question — a stated limit. Search reads `history.json`; a runner saves at turn end, and
`ConversationRegistry#rows` shows resident-unsaved conversations that have no file yet. So a brand-new
conversation matches nothing and one mid-turn matches its previous state. **Fine:** the purpose is
finding conversations that are days or weeks over and done. The alternative — asking resident runners
in memory — drags search back across the seam for a one-turn window nobody is searching for.

## Attachments — v2, all of it

Cut from v1. "Text attachments only, by recorded MIME type" is cheap in *knowledge* (the mime is in
`history.json` beside the message and the file is `attachments/<digest10>-<stem><ext>`, so having
parsed the JSON we already know which stored files are text) but it multiplies the read budget above
for the rarest kind of match. PDF/ODT/DOC needs extractors; note `pikuri-pdf` is already a path
dependency, so the PDF half may be nearly free — check what it exposes before assuming. All of that
is an argument for a v2, not for a bigger v1.

## Loose ends

- **`Q_unsupported_rows`** — a conversation whose `meta.json` is unreadable lists as *unsupported
  format* but still has a `history.json`. Search it? Yes: past the cap, search is the only way to
  reach a broken one at all, and reaching it is exactly what you want in order to delete it.
- No new block kinds and no new CSS tokens: the search box is chrome beside the transcript, same as
  the sidebar it sits in (`--bg-raised`, `--border`). The snippet may want one muted text style,
  which the existing tokens should already cover.
