# Multiple conversations

Today `pikuri-web-chat` is one agent, one transcript, forever (`D_single_shared_conversation`).
Restart the process and the conversation is gone; there is no `/clear` either, so the only way to
start fresh is Ctrl+C. This idea: **many conversations, persisted on disk, picked from a left
sidebar** — roughly Web Claude's shape, minus multi-user.

Scope-wise this reopens `D_single_shared_conversation`, but *not* the part it rejected. That entry
rejected **per-session** conversations (a conversation per browser tab / visitor), which is a
multi-user feature in disguise. This is **one user, many conversations, one live at a time** — a
different shape, and much cheaper. If this ships, `D_single_shared_conversation` needs an
amendment ("one *live* conversation, no sessions, no auth") rather than a reversal, because the
loopback / no-auth half of it is untouched.

Open questions get `Q_` slugs so the rest of the file can cite them.

---

## v1 / v2 as asked

- **v1** — conversations titled by start date+time; stored on disk as JSON; left sidebar listing
  title + "6 hours ago"; click loads it into the main pane and selects it; a "New conversation"
  button that appears-and-selects immediately.
- **v2** — an LLM extracts a short title from the first user message and replaces the timestamp,
  like Web Claude.

Nothing below argues with that split. It argues about what "loads it" means, because that's where
the actual work is.

---

## The hard part: pikuri cannot round-trip its history

This is the crux, and it's worth settling before any UI work.

`Pikuri::Agent` wraps a private `@chat` (`RubyLLM::Chat`). There is **no public reader for the
message history and no way to load one**:

- `Agent#clear_conversation` exists (resets `@chat`, re-assembles the system prompt, emits
  `Event::Reset`, resets controls, drains the interloper) — so "start fresh without re-wiring" is
  already solved, and it's exactly what "New conversation" needs.
- There is no `Agent#history` / `Agent#load_history!`. `@chat.messages` is reachable only via
  `instance_variable_get`, which would put `Pikuri` internals in our store and break
  `D_pikuri_free_core` in spirit even where it survives in letter.
- One level down, RubyLLM has the raw material: `Chat#messages` (reader), `Chat#add_message(hash
  or Message)`, `Chat#reset_messages!`, `Message#to_h`, `ToolCall#to_h`.

So the round-trip is *possible* but the seam is wrong. **Filed upstream** as
[mvysny/pikuri#1](https://codeberg.org/mvysny/pikuri/issues/1) — the two-method history
round-trip belongs in pikuri; everything else stays in-house:

```ruby
agent.export_history          # => [Hash, ...]  plain, JSON-safe, system message excluded
agent.load_history!(array)    # replaces history; re-applies a freshly assembled system prompt
```

Why pikuri and not here: no shell can do it without reaching into `@chat`; pikuri-tui wants the
same thing the moment anyone asks it for `/resume`; and the *meaning* of "a conversation that can
continue" (what must be preserved for the model to behave as if nothing happened) is agent-loop
knowledge, not web-shell knowledge — AGENTS.md already says a library-level fork gets logged in
`../pikuri/DECISIONS.md`, not re-argued here. It also keeps the store Pikuri-free: it stores plain
hashes, and `AgentRunner` (already inside the seam) does the conversion.

Known sharp edges for that request, found while reading RubyLLM 1.16:

- `Message#to_h` emits `tool_calls:` as a Hash of **live `ToolCall` objects**, not their `to_h`.
  `JSON.generate` on it will not round-trip — export must map them, and load must rehydrate
  `ToolCall.new(...)` before `Message.new(tool_calls:)`.
- `Message#content` is a String *or* a `Content` (text + attachments). Chat has no attachments
  today, but the format shouldn't assume String.
- `Message#to_h` carries per-message token counts — useful for `Q_token_readout`.
- The system message must **not** be restored: `clear_conversation` deliberately re-assembles the
  prompt so dynamic sections refresh, and the saved one contains a stale `Current date: …` line
  that `bin/pikuri-web-chat` injects at boot.

**`Q_history_in_pikuri` — FILED, awaiting upstream.**
[mvysny/pikuri#1](https://codeberg.org/mvysny/pikuri/issues/1) carries the request: the two-method
API, the "system message is never restored" rule, and the three RubyLLM sharp edges above. It also
flags `TokenLog` seeding (see `Q_token_readout`) and asks whether `load_history!` should have an
opinion on tool-set drift (`Q_tool_set_drift`) rather than leaving both to each host — so those
two questions may get answered upstream instead of here.

Until it lands, `instance_variable_get(:@chat)` is the only local route. Fine for a throwaway
spike on a branch to prove the replay path; never merge it — the whole reason for the ticket is
that a store full of `RubyLLM::Message` objects breaks `D_pikuri_free_core`.

---

## What gets stored, exactly — the real fork

Two different things are needed and **neither is derivable from the other**:

| layer | what it is | who needs it |
| --- | --- | --- |
| model | LLM message history (roles, tool calls, tool results) | the agent, to continue the conversation |
| render | `Transcript` blocks (rendered HTML, ids, kinds) | the browser, to show what happened |

They diverge on purpose. `SseListener` truncates tool results to `MAX_TOOL_RESULT_CHARS` (200) and
collapses `SystemInjected` to a one-line notice; the model history holds the full text.
Conversely the history has no block ids, no `:thinking` / `:tool_call` kinds, and no notion of a
wiped preview. Rebuilding either from the other is lossy in both directions.

Three candidate formats:

- **(a) Store both, verbatim.** `messages.json` + `blocks.json` (rendered HTML). Exact reload,
  zero replay logic. Costs: HTML strings in the store, so a change to `MarkdownRenderer` or
  `style.css` never reaches old conversations (this is `D_server_authoritative_transcript`'s
  "blocks are stored rendered" consequence, now with a much longer lifetime), and the file holds
  two representations of the same conversation that can disagree.
- **(b) Store the model history only, re-derive blocks.** Smallest file, but the derivation is a
  second renderer that has to guess at thinking/tool-call presentation — a lie by omission, since
  `Event::ThinkingDelta` content isn't in the history at all.
- **(c) Store the event log (source text, not HTML) + the model history.** Append one JSON line
  per `Pikuri::Agent::Event` — the same stream `SseListener` already consumes, serialized to plain
  hashes at the seam. Loading = replay the log through a fresh `SseListener` into a fresh
  `Transcript`, which rebuilds blocks *with today's renderer and today's CSS*, then
  `load_history!` the messages.

**Lean: (c).** It reuses the one renderer we have instead of growing a second, makes old
conversations benefit from renderer fixes, and keeps the store Pikuri-free (plain hashes on both
sides of the seam). It also gives an append-only write path — see `Q_write_shape`. The cost is a
`Event <-> Hash` codec that has to cover every event variant `SseListener` matches on, and stay in
step with pikuri when a variant is added — a real maintenance tax, and the strongest argument for
(a). Deltas need not be stored: only the finalized `Assistant` / `Thinking` bookends, which carry
authoritative content (`D_rerender_and_replace`). That shrinks the log a lot.

**`Q_store_format`** — (a), (b) or (c)? Sub-question if (c): does the replay go through the real
`SseListener` with the `Broadcaster` swapped for a null sink, or through a separate
transcript-builder? (Lean: the real listener + null broadcaster — one renderer, and it's already
built to write into an injected transcript.)

---

## On-disk layout

`Pikuri::Paths.state` is the documented home for "state that persists across restarts but isn't
portable enough for XDG_DATA_HOME (logs, history, layout)" — i.e. `~/.local/state/pikuri/`, and it
`mkdir_p`s itself. So:

```
~/.local/state/pikuri/conversations/
    2026-08-27T12-03-51Z-3f9a/
        meta.json      # title, created_at, updated_at, model, shell, schema version
        log.jsonl      # one event per line (append-only)
        messages.json  # model history, rewritten atomically per turn
    2026-08-26T09-14-02Z-b1c7/
        …
```

Choices baked into that sketch, each arguable:

- **Directory per conversation, not one file.** The event log wants append (`>>` one line, crash-
  safe, no rewrite of a growing file); the message history wants whole-file replacement (atomic
  tmp+rename). Those two want different write strategies, so they want different files.
- **Timestamp stem as the id.** Sorts lexically, greps by date, readable in `ls`. UTC in the id,
  local time in the UI. The short random suffix is collision insurance (two processes, same
  second) and makes the id a real opaque handle.
- **The title lives in `meta.json`, never in the path.** v2 retitling must not move a directory.
- **The sidebar reads only `meta.json` per conversation** — N tiny reads, fine into the hundreds;
  revisit with an index file only if it ever isn't (and note that an index is a cache that can
  drift, so not in v1).
- **Shared folder, not web-specific.** `conversations/`, not `web-conversations/`, so a future
  pikuri-tui `/resume` or a pikuri-level store can read the same files. The attractive end state
  is "start a conversation in the TUI, finish it in the browser."

**`Q_folder_ownership`** — if the format is shared with the TUI, does the *store* belong upstream
too (pikuri owning `conversations/` and its schema) rather than here? Shipping our own layout into
a shared folder means owning a migration if pikuri later ships its own. (Lean: our layout, our
folder, documented as provisional; propose it upstream as the shape when the history round-trip
lands.)

**`Q_write_shape`** — write after every event, or at turn end? (Lean: append events as they
happen — a crash mid-turn then keeps what was said; rewrite `messages.json` once at turn end,
since only then is the history consistent.)

**`Q_multi_process`** — two `pikuri-web-chat` processes on different ports, or the TUI, sharing
the folder. Two processes with the same conversation loaded would interleave appends into
`log.jsonl`. Options: `flock` on open and show the conversation read-only if held; or last-writer-
wins and don't care (single-user tool). (Lean: `flock`, because the failure is silent corruption of
the thing we just added persistence for.)

**`Q_perms`** — `chmod 0700` the folder. Conversations hold everything the user typed plus scraped
web content; nothing is encrypted, and that should be a README line, not a surprise.

**`Q_schema_version`** — `schema: 1` in `meta.json`; an unknown version renders the row greyed-out
with "unsupported format" instead of crashing the sidebar. Cheap, do it in v1.

**`Q_retention`** — no cap, no cleanup in v1? A delete button (with what confirmation?) is v2 at
the earliest, and deleting the *currently open* conversation needs a rule.

---

## The switch: what happens in-process

`AgentRunner` owns **the** worker thread and **the** agent; `Transcript` owns **the** block list;
`Broadcaster` fans out to every tab. A conversation switch therefore means:

1. Flush the current conversation's store (should already be current per `Q_write_shape`).
2. `agent.clear_conversation` — resets history, controls, interloper queue; emits `Event::Reset`.
3. `agent.load_history!(saved_messages)` (per `Q_history_in_pikuri`) — unless it's a new one.
4. Swap in a fresh `Transcript` rebuilt by replaying `log.jsonl` (per `Q_store_format`).
5. Tell every tab to re-snapshot.

Step 4 is the one that pokes the architecture: `App` holds its collaborators in **class-level
settings** (`App.set :transcript, …`), set once at boot. Either the setting becomes a
`ConversationSession` object whose `#transcript` is swapped behind it (one indirection, routes
unchanged), or `App` learns to ask a `ConversationStore` for "the current transcript" on each
request. (Lean: the former — routes keep calling `settings.transcript.to_a`, and the swap is one
mutex-guarded assignment in the thing that owns both.)

Step 5 is nearly free given what's already there: `app.js` already does `location.reload()` when
`EventSource` reconnects, precisely because the server is authoritative. A `reload` SSE event
reuses that path, so every open tab follows the switch with no new client state — which keeps
`D_no_js_build_step` and `D_server_authoritative_transcript` intact.

**`Q_switch_while_busy` — SETTLED.** The agent is mid-turn and the user clicks another
conversation. **v1: refuse** — sidebar rows disabled while busy, with a `title` explaining why.
It's honest (one conversation is live), and it's the only option that doesn't grow topics.
Cancelling the turn (`Cancellable`, next tool boundary) is rejected outright: silently throwing
away a turn because someone clicked a row is worse than not letting them click.

**v2: let the turn run in the background** while the user views another conversation. Not a patch
on v1 — it pulls in, roughly in dependency order:

- **A conversation id on everything the runner emits.** `SseListener` writes into *the*
  transcript today; it would take the conversation's transcript, and the runner would know which
  conversation its worker thread belongs to.
- **Per-conversation topics in `Broadcaster`** — `subscribe(conversation_id)`, and `broadcast`
  gains a topic. This is the "fan-out stops being a broadcast" cost `D_single_shared_conversation`
  named; ~20 lines, but it's the invariant that entry rests on, so it needs its own `D_` entry
  rather than a quiet edit. The heartbeat and the `close` sentinel stay global.
- **N transcripts resident in memory**, not one swapped behind an indirection — which means the
  `conversation_session` shape from step 4 above is a v1-only stepping stone, not the end state.
  Worth building it so it doesn't fight this later.
- **A "busy elsewhere" affordance** in the sidebar: the row of a conversation with a live turn
  needs a spinner or a dot, or the feature is invisible until the user goes looking.
- **Still one live turn at a time.** Background ≠ parallel: `AgentRunner` owns one agent whose
  history is the conversation's, so starting a *second* turn in another conversation would need a
  second agent (a second history, a second `TokenLog`, a second interloper). That's a separate
  question, and v2 should explicitly refuse it — submit in a non-live conversation is rejected
  the way switching is in v1.

Consequence for `Q_selection_scope`: v2 is where option B (per-URL `/c/<id>`) stops being
speculative. Once frames are topic-addressed and transcripts are resident, a tab sitting on its
own conversation is nearly free — and B's "two panes, one accepts input" objection weakens exactly
when background turns exist, because the other pane is genuinely alive. So v1 should pick A
*without* baking the assumption that one transcript exists at a time into the routes.

**`Q_selection_scope`** — where does "which conversation is selected" live?

- **A: server-global.** One selected conversation, all tabs show it, a switch broadcasts `reload`.
  `Broadcaster` untouched, one transcript in memory, matches "one live agent" exactly. Selection
  is server state changed by `POST`.
- **B: per-URL.** `GET /c/<id>` is a real view, tabs can sit on different conversations, links are
  shareable/bookmarkable. Needs N transcripts in memory and per-conversation SSE topics, and with
  one live agent it shows two panes where only one accepts input — confusing in exactly the
  situation it enables.

(Lean: A for v1, and note that B is where this goes *if* parallel turns ever become a goal.)

**`Q_get_side_effects`** — with A, a sidebar row must not be a plain `GET` link that switches
server state: a prefetching browser would change the user's conversation. So each row is a
`<form method="post">` styled as a list item (no JS, works everywhere), redirecting 303 to `/`.
Slightly awkward CSS; correctness worth it. (With B, rows are honest links and this evaporates —
which is B's real argument.)

**`Q_new_conversation_litter`** — "New conversation" must appear and be selected immediately, but
persisting an empty conversation per click litters the folder. (Lean: hold it unsaved in memory,
render it as "New conversation", write on the first submit; and make the button a no-op — or a
re-select — when the current conversation is already empty, like Web Claude.)

**`Q_token_readout`** — the status bar's token/context line comes from
`Pikuri::Agent::Listener::TokenLog`, which is per-process and knows nothing about a loaded history.
After a switch it will read as if the conversation were empty, then jump after the first turn.
Options: accept the jump; seed `TokenLog` from the token counts in `Message#to_h`; or blank the
readout until the first turn of the loaded conversation. (Lean: seed if pikuri makes it seedable,
blank otherwise — a stale-looking "0 tokens" on a 40k-token conversation is a lie the user will act
on.)

**`Q_tool_set_drift`** — a conversation saved by `pikuri-web-chat` (calculator / web_search /
web_scrape / fetch) loaded by a future `pikuri-web-code` with a different tool set: the history
holds `tool_calls` naming tools that no longer exist. `meta.json` records the shell name and tool
list; on mismatch, warn in the sidebar / refuse to load? Same question for a different model or a
smaller context window than the saved conversation needs. (Lean: record it, warn, allow — the
model tolerates unknown tool names in history better than the user tolerates a refusal.)

---

## v2: the LLM-generated title

- **Never on the agent's own chat.** A titling request through `Pikuri::Agent` would land in the
  conversation history and pollute it. It needs its own one-shot chat — a second `Pikuri::Agent`
  with no tools and a tiny system prompt, or a raw `RubyLLM::Chat` off the same connection.
  (Lean: a no-tools `Agent`, so the connection/context wiring in `bin/pikuri-web-chat` isn't
  duplicated.)
- **When:** from the first user message alone (Web Claude's behaviour — title appears fast, is
  sometimes wrong) or after the first assistant reply (better, later). (Lean: first user message,
  fire-and-forget on a background thread; a titling failure must never fail the turn — it just
  leaves the timestamp title.)
- **Length:** the ask says 10–20 words. That's long for a ~20%-wide sidebar row; Web Claude's are
  more like 3–7. Suggest **≤60 chars / ~4–8 words**, one line, ellipsised in CSS.
  **`Q_title_length`** — settle this.
- **Sanitizing:** single line, strip markdown/quotes/trailing period, cap length, fall back to the
  timestamp if the model returns junk or nothing. A model that returns "Sure! Here's a title:" is
  the normal case, not the edge case.
- **Cost:** one extra small request per new conversation, against a local llama.cpp — negligible,
  but it's another thing to see fail on the trifecta-free path. Should it be off by default with a
  config knob (`[web] auto_title = true`)? Note that `D_schema_complete_config` means any new key
  goes into `Config`'s whole-schema port.
- **Manual rename** (a pencil on the row) is the cheap alternative to the whole feature. Worth
  asking whether v2 should be *rename* rather than *auto-title* — or whether auto-title needs
  rename anyway as its escape hatch.

---

## Sidebar UI

- **Width:** the ask says ~20% of the viewport. Suggest `clamp(12rem, 20%, 20rem)` so it doesn't
  become a stripe on a laptop or a canyon on a 4K monitor. Full height, own `overflow-y`, transcript
  column keeps its current max-width.
- **Rows:** title (ellipsised) + relative time, muted and smaller. Selected row gets a background +
  left border. Newest first — **`Q_sort_key`**: by `updated_at` (last activity, Web Claude) or
  `created_at` (stable order)? (Lean: `updated_at`.)
- **Relative time** ("6 hours ago", "yesterday", "2 days ago") — a ~15-line helper, no gem. Rendered
  server-side, so it goes stale in a tab left open for a day. **`Q_relative_time_staleness`**:
  accept (the app already reloads on every switch), refresh via the existing SSE `status` event, or
  emit `<time datetime>` and format in JS. (Lean: accept in v1; JS formatting is client-side
  rendering, which `D_no_js_build_step` pushes back on — the theme toggle was the *argued*
  exception, not a precedent.)
- **New CSS tokens.** A sidebar background/border almost certainly isn't in the existing nine
  semantic tokens, and `D_theme_cookie` requires both palettes + both mappings, with nothing outside
  `style.css` reading a raw colour.
- **Narrow viewports:** `<details>`/`<summary>` drawer, or hide the sidebar under a media query —
  both achievable with zero JS. **`Q_narrow_layout`**.
- **No new block kinds**, so the `SseListener` / `index.erb` / `style.css` trifecta stays put — the
  sidebar is a new region, not a new block.
- **`Q_conversation_count`** — 200 conversations in the sidebar: scroll only, or search / "load
  more"? (v1: scroll. Just don't paint ourselves out of a search box later.)

---

## Files this would add (Layout lines to write at graduation)

- `lib/pikuri_web/conversation_store.rb` — enumerate / create / read / append; owns the on-disk
  layout. Pikuri-free (plain hashes).
- `lib/pikuri_web/conversation.rb` — one conversation's metadata + paths; the sidebar's row model.
- `lib/pikuri_web/conversation_session.rb` (name TBD) — holds the *current* transcript + store
  handle, does the switch under a mutex; what `App.set :transcript` becomes.
- `lib/pikuri_web/event_codec.rb` — `Event <-> Hash`, only if `Q_store_format` lands on (c). Lives
  inside the Pikuri seam, so `D_pikuri_free_core`'s "only three files" invariant becomes four.
- `lib/pikuri_web/relative_time.rb` — or a helper in `App`; too small for its own file, probably.
- `views/_sidebar.erb`, plus `index.erb` gaining the two-column shell.
- Routes: `POST /conversations` (new), `POST /conversations/:id/select`, later
  `DELETE`/`PATCH` for delete/rename.
- Specs: store round-trip against a stubbed `XDG_STATE_HOME` (`Paths.state` reads env at call time,
  deliberately, so stubbing works); a replay spec feeding a canned log through `SseListener` and
  asserting the rebuilt blocks.

---

## Smallest useful slice

If this gets built in stages, the order that keeps each stage shippable:

1. **Wait on [mvysny/pikuri#1](https://codeberg.org/mvysny/pikuri/issues/1)** — nothing here works
   without the round-trip, so this is a blocker, not a first task.
2. **Store + "New conversation" only.** No sidebar: one button that saves the current conversation
   and clears the agent. Already useful (it's the missing `/clear`), and it exercises the whole
   write path.
3. **Sidebar, read-only list** — titles + relative time, current one highlighted, no switching.
   Proves the layout and the metadata reads.
4. **Switching** (`Q_switch_while_busy`, `Q_selection_scope`, the replay path).
5. **v2 auto-title**, or manual rename first if `Q_title_length` says the sidebar wants short
   titles anyway.
6. **v2 background turns** (`Q_switch_while_busy`) — conversation-tagged emissions, topics in
   `Broadcaster`, resident transcripts, a busy dot on the row. Last, because it's the step that
   rewrites who owns what, and every earlier step is useful without it.
