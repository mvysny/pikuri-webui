# Multiple conversations

Today `pikuri-web-chat` is one *live* conversation (`D_single_shared_conversation`). Slices 1–3
below have shipped: conversations are saved to disk, listed in a left sidebar, and
`AgentRunner#load_conversation` can put one back — but **nothing calls it yet**, so the sidebar
rows are still inert and a restart still lands you in an empty transcript. Step 4 is the click.
This idea: **many conversations, persisted on disk, picked from a left sidebar** — roughly Web
Claude's shape, minus multi-user.

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

## The round-trip: shipped upstream, and richer than we asked for

**`Q_history_in_pikuri` — SETTLED, unblocked.** pikuri closed
[mvysny/pikuri#1](https://codeberg.org/mvysny/pikuri/issues/1) on 2026-08-27
(`05ab5e0` + `ad02a97`). What landed is not the `[Hash, ...]` the ticket proposed — the ticket got
argued *up* into `Pikuri::Agent::History`, a `Data` value that owns both directions of its own
serialization, plus five `DECISIONS.md` entries: `D_history_value_type`, `D_history_container`,
`D_history_attachments`, `D_history_local_ids`, `D_history_load_repairs`. Read those, don't
re-argue them here.

The API:

```ruby
agent.export_history                        # => Pikuri::Agent::History
agent.export_history.save(dir)              # dir/history.json + dir/attachments/
agent.load_history!(History.load(dir))      # => Integer, messages restored
```

Everything the sharp-edges list worried about is upstream's problem now — `Message#to_h`'s live
`ToolCall` objects, `Content`-vs-String, base64, the never-restore-the-system-prompt rule. Facts
that change *our* design, rather than merely unblocking it:

- **`save(dir)` writes into a folder and never enumerates or deletes it** (`D_history_attachments`,
  explicitly: "pikuri writes into that folder but does not own everything in it"). So our
  per-conversation directory *is* the history's directory — no nesting, no separate store file, and
  our `meta.json` sits beside `history.json` uncontested. This is the fact that collapses most of
  the "on-disk layout" section below.
- **`load_history!` calls `clear_conversation` itself**, so the switch's clear-then-load is one
  call.
- **Every message carries a pikuri-minted id** (`D_history_local_ids`), lexicographically sortable,
  minted at creation so two exports agree. Upstream added it *for us*: the entry names "the
  render/replay fork" and says without ids nothing can say *this rendered block is that message*.
- **`Event::HistoryLoaded` fires after the `Reset`**, carrying message count and the last assistant
  message's usage, and `Listener::TokenLog` already reseeds from it. That answers `Q_token_readout`
  outright.
- **Repairs happen on the way in, not out** (`D_history_load_repairs`): a tool call whose result
  never arrived gets a synthesized `[Tool execution was interrupted]`, and a thinking signature from
  a different model is dropped. So a conversation killed mid-batch is loadable, which matters for
  `Q_write_shape` — we can save aggressively without worrying about torn tool batches.
- **The scope line is drawn where we drew it.** `D_history_value_type`: "Both shells render the
  `Agent::Event` stream, not the message list … The event log is the *shell's* artifact, because the
  truncation policy is the shell's. Likewise title, timestamps and conversation ordering: the
  shell's envelope wraps ours." That is `Q_folder_ownership`, answered.

One thing the history is *not*: a `History` is a `Pikuri::` type, so it cannot cross into
{ConversationStore} without breaking `D_pikuri_free_core`. The `save(dir)` / `load(dir)` shape makes
that free: **the store deals in paths, {AgentRunner} deals in `History`.** The store creates and
enumerates directories and owns `meta.json`; the runner — already inside the seam — is the only
thing that calls `export_history.save` / `History.load`.

**Done in slices 1 and 3:** `SseListener`'s `else` arm documented `Reset` / `ModelSwitched` as
*unreachable*. `Reset` got an arm (clear the transcript, push a `reset` frame); `HistoryLoaded` got
one too, and it is deliberately silent. Only `ModelSwitched` is left in the `else`.

---

## What gets stored, exactly

**`Q_store_format` — SETTLED (b), shipped, graduated.** Only `history.json` (pikuri's) plus our
`meta.json`; the render half is re-derived by replaying synthesized events through the real
`SseListener`. The argument, the two rejected alternatives and what (b) loses now live in
`DECISIONS.md` `D_replay_from_history` — don't re-argue them here.

---

## On-disk layout

`Pikuri::Paths.state` is the documented home for "state that persists across restarts but isn't
portable enough for XDG_DATA_HOME (logs, history, layout)" — i.e. `~/.local/state/pikuri/`, and it
`mkdir_p`s itself. So:

```
~/.local/state/pikuri/pikuri-web-chat/conversations/
    2026-08-27T12-03-51Z-3f9a/
        meta.json      # ours: title, created_at, updated_at, model, shell, schema version
        history.json   # pikuri's: History#save, rewritten atomically per turn
        attachments/   # pikuri's: content-addressed, only if the conversation has any
        log.jsonl      # ours, only if Q_store_format lands on (c)
    2026-08-26T09-14-02Z-b1c7/
        …
```

Choices baked into that sketch, each arguable:

- **Directory per conversation, and the directory is pikuri's `save(dir)` target.** Not a nesting
  decision we get to make prettier: `save` puts `history.json` at the root of the folder it's given
  and `attachments/` beside it. What makes co-habitation safe rather than lucky is that
  `D_history_attachments` promises it — `save` never deletes and never enumerates the folder, and its
  only read is a `stat` per referenced attachment. Our `meta.json` is not at risk.
- **Timestamp stem as the id.** Sorts lexically, greps by date, readable in `ls`. UTC in the id,
  local time in the UI. The short random suffix is collision insurance (two processes, same
  second) and makes the id a real opaque handle.
- **The title lives in `meta.json`, never in the path.** v2 retitling must not move a directory.
- **The sidebar reads only `meta.json` per conversation** — N tiny reads, fine into the hundreds;
  revisit with an index file only if it ever isn't (and note that an index is a cache that can
  drift, so not in v1).
- ~~**Shared folder, not web-specific.**~~ **REVERSED — `D_per_shell_state_root`.** Everything
  this shell persists lives under `<state>/pikuri-web-chat/`. The "start in the TUI, finish in the
  browser" end state is still the goal, but it is carried by the *format* (pikuri's `history.json`
  plus a documented envelope), which travels wherever the files sit; a shared path would just mean
  two shells writing one directory with no agreement about who owns it. Cross-shell resume now
  needs a deliberate shared location rather than inheriting one by accident.

**`Q_folder_ownership` — SETTLED, and upstream drew the line.** `D_history_value_type`: title,
timestamps and conversation ordering are "the shell's envelope wraps ours". pikuri owns
`history.json` and `attachments/`; we own the folder, its name, and `meta.json`. pikuri ships no
conversation *store* and pikuri-tui has not adopted the history yet, so there is nothing to
collide with — and if a shared store ever lands, the per-conversation folder is already the unit it
would want. Where that folder *sits* is now `D_per_shell_state_root`: under this shell's own state
root, not a shared one.

**`Q_write_shape` — near-settled by upstream's own measurement.** `D_history_container` measured the
whole-file atomic rewrite `save` performs: **1.9 ms** for 200 messages (0.39 MB), **15.7 ms** for
2000 (3.86 MB) — 0.05–0.5% of a turn that spends seconds on the model. So there is no reason to
batch: call `export_history.save(dir)` after **every event that added a message** (assistant turn,
each tool result, each user turn), and a crash mid-turn keeps what actually happened rather than
losing the turn. Two facts make that safe rather than reckless: `save` is temp-file-and-rename, so
the file on disk is always a complete valid history; and a dangling tool batch is *legal* on the way
in, repaired at `load_history!` (`D_history_load_repairs`) — the crash case is explicitly the one
they made loadable. Under (c) the event log keeps its own append path; under (b) there is no second
write path at all.

*Slice 1 shipped turn-end saves instead* — see the deviation and its reason under **Smallest
useful slice** step 1.

**`Q_multi_process`** — two `pikuri-web-chat` processes on different ports, or the TUI, sharing the
folder. Both writers rewrite `history.json` wholesale, so the failure is not a torn file (rename is
atomic) but a **silently clobbered conversation**: the loser's turns vanish at the next save.
Options: `flock` on open and show the conversation read-only if held; or last-writer-wins and don't
care (single-user tool). (Lean: `flock`, because losing turns silently is exactly the failure
persistence was added to prevent.)

**`Q_perms`** — `chmod 0700` the folder. Conversations hold everything the user typed plus scraped
web content; nothing is encrypted, and that should be a README line, not a surprise. Now also
`attachments/` — every image a `read` showed the model, sitting on disk as a plain file.

**`Q_schema_version` — SETTLED and shipped as leaned.** `schema: 1` in `meta.json`; an unknown
version — or a corrupt file — renders the row greyed-out with "unsupported format" instead of
crashing the sidebar. What building it added: the row still needs a *title*, and the envelope is
exactly what can't be trusted to supply one, so an unreadable conversation falls back to the stamp
derived from its id. Which is why the id carries a timestamp at all — it is the one piece of
metadata that cannot be corrupted independently of the directory it names.

**`Q_retention`** — no cap, no cleanup in v1? A delete button (with what confirmation?) is v2 at
the earliest, and deleting the *currently open* conversation needs a rule.

---

## The switch: what happens in-process

**SETTLED and shipped in step 3** — `AgentRunner#load_conversation`. The switch is: read the
history from disk, save the outgoing conversation, `load_history!` (which clears and emits `Reset`,
then `HistoryLoaded`), replay through `SseListener`, re-point the live conversation.

The two hazards this section worried about both dissolved:

- **No transcript swap, so no ordering hazard.** `Reset`'s arm empties the transcript *and* every
  tab; the replay refills both. The `ConversationSession` indirection behind `App.set :transcript`
  is not needed for v1 — only for v2's N resident transcripts.
- **No re-snapshot needed either.** The blocks arrive as ordinary `block` SSE frames behind the
  `reset` frame, which is what slice 1's in-place emptying already made possible (a
  `location.reload()` would throw away a half-typed message in every open tab, including tabs whose
  user is not the one who clicked).

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
- **N transcripts resident in memory** — the one genuinely new structure. v1 has exactly one,
  emptied and refilled in place, so this is where a `ConversationSession`-shaped thing would finally
  earn itself; nothing built so far assumes there can only be one, but nothing provides for two
  either.
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

**`Q_token_readout` — SETTLED upstream, nothing for us to build.** `load_history!` emits
`Event::HistoryLoaded` carrying the last restored assistant message's usage, and `TokenLog` already
has the arm that reseeds its context readout from it (`seed_snapshot`); the reply *counter*
deliberately stays at zero, since restored turns didn't happen this session. A history exported
without usage leaves the zeroed snapshot alone rather than inventing a number. The only thing we
must not do is drop the event: our status bar reads `TokenLog#status_line` via `AgentRunner`, so the
push has to happen *after* `load_history!` returns, not before.

**`Q_tool_set_drift` — mostly answered upstream, and the answer is "relax".**
`D_history_load_repairs`: "A tool the agent no longer wires draws no warning. A recorded call is
never re-executed; it is a record of the harness that made it. The only live risk is the model
retrying a tool it can see in its own context, and ruby_llm already answers that with an observation
naming the tools that *are* available, so the model self-corrects." So refusing to load is off the
table, and so is a load-time warning. What survives for us is presentational only: `meta.json`
records the shell name, and the sidebar *may* label a row "saved by a different harness" — upstream
explicitly left that as a shell concern. The model / context-window half of the question is
untouched by any of this and still ours.

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
  left border. Newest first.
- **`Q_sort_key` — SETTLED: `created_at`**, against the earlier lean. `updated_at` reshuffles the
  list under the user every turn; a list that holds still is one you can build a habit on ("mine is
  third from the top"). The consequence is free: the id *is* the created-at stamp, so ordering is a
  lexical sort on the directory name and never opens a file. `updated_at` stays in `meta.json` as a
  record; nothing reads it. The displayed time is `created_at` too, so the column and the order
  agree.
- **Relative time** ("6 hours ago", "yesterday", "2 days ago") — a ~15-line helper, no gem. Rendered
  server-side, so it goes stale in a tab left open for a day. **`Q_relative_time_staleness` —
  SETTLED: accept.** JS formatting is client-side rendering, which `D_no_js_build_step` pushes back
  on — the theme toggle was the *argued* exception, not a precedent. It self-heals anyway: every
  conversation change re-fetches the whole list.
- ~~**New CSS tokens.**~~ **None needed** — `--bg-raised` (the status bar's surface) and `--border`
  already say "chrome beside the transcript", and `--accent` marks the current row. So
  `D_theme_cookie`'s both-palettes-both-mappings cost never came due.
- **`Q_narrow_layout` — SETTLED: a media query, not a drawer.** Under 48rem the sidebar stacks on
  top as a `max-height: 20vh` scrolling strip. `<details>` was the tempting zero-JS drawer and
  doesn't work: CSS can't force it open on wide screens, so it would either be collapsible where it
  shouldn't be or start collapsed everywhere. Revisit if 20vh turns out to be too much of a phone.
- **No new block kinds**, so the `SseListener` / `index.erb` / `style.css` trifecta stays put — the
  sidebar is a new region, not a new block.
- **`Q_conversation_count`** — 200 conversations in the sidebar: scroll only, or search / "load
  more"? (v1: scroll. Just don't paint ourselves out of a search box later.)

---

## Files this would add (Layout lines to write at graduation)

- ~~`lib/pikuri_web/conversation_store.rb`~~ — **done**; `delete` is the only verb left, and it
  belongs to `Q_retention`.
- ~~`lib/pikuri_web/conversation.rb`~~ — **not a file.** `ConversationStore::Conversation` is a
  `Data` nested in the store, which is the only thing that mints or reads one.
- ~~`lib/pikuri_web/conversation_session.rb`~~ — **not a file, and not one in v1 at all.** See
  **The switch** above; it comes back only if v2's resident transcripts do.
- ~~`lib/pikuri_web/history_replay.rb`~~ — **done**, and it did cost `D_pikuri_free_core` an
  amendment (three adapters in the seam, not two).
- ~~`lib/pikuri_web/relative_time.rb`~~ — **done**, and it did earn its own file: `App` is the
  routes, not a helper drawer, and a pure function of two Times is trivially spec'd on its own.
- ~~`views/_sidebar.erb`, plus `index.erb` gaining the two-column shell.~~ — **done.**
- Routes: ~~`POST /conversations` (new)~~, ~~`GET /conversations` (the list fragment)~~,
  `POST /conversations/:id/select`, later `DELETE`/`PATCH` for delete/rename.
- ~~Specs.~~ **done** — `history_replay_spec.rb` builds Histories in Ruby for the mapping, and
  `conversation_flow_spec.rb` renders one conversation live and again from disk over a
  `Pikuri::Testing.fake_transport` agent and demands the same blocks. That last one is the spec
  that matters: it is what catches an upstream event reorder or a renamed `<system-reminder>` tag.

---

## Smallest useful slice

The blocker is gone — [mvysny/pikuri#1](https://codeberg.org/mvysny/pikuri/issues/1) is closed and
`../pikuri` is a path dependency, so the round-trip is available right now with no version bump to
wait for. The order that keeps each stage shippable:

1. ~~**Store + "New conversation" only.**~~ **SHIPPED.** `ConversationStore` (folder layout +
   `meta.json`), `AgentRunner#new_conversation`, `POST /conversations`, the `Reset` arm in
   `SseListener`, a `reset` SSE event, and a status-bar button. What it settled beyond the plan:

   - **`AgentRunner` owns the live conversation; the store is stateless.** The planned
     `conversation_session.rb` was not needed — the runner owns the agent whose history it is, so
     it owns *which* conversation that history belongs to, and the store stays a pure
     folder-layout object (which is also what makes slice 2's listing a plain read-only method).
     The session object comes back in step 3, when a *transcript* has to be swapped rather than
     cleared.
   - **Saves happen at turn end, not per message** — a deliberate deviation from `Q_write_shape`'s
     lean. There is no clean per-message event to hang it on: `Event::ToolResult` fires *before*
     ruby_llm appends the tool message (pikuri's own `tool_batch_complete?` comment says so), and
     no event fires for a tool message landing at all. Turn end needs no ordering assumptions, and
     nothing reads these files back yet. Revisit with step 3, where a lost turn becomes visible.
   - **"Idle" means "saved".** `#busy?` stays true until the turn's save lands, because a
     `new_conversation` slipping into the gap would re-point the live conversation and the save
     would land in the fresh folder. The save runs under the same mutex as the submit decision.
   - **`Q_new_conversation_litter` and `Q_perms` are implemented as leaned**: `#create` mints
     without writing, the button is a no-op (`:empty`) on a conversation with no messages, and
     directories are 0700. The split that fell out: the *root* is created eagerly, at store
     construction, so the folder is visible from boot rather than appearing on the first save —
     "where does this go?" should not need a completed turn to answer. Conversation folders stay
     lazy.
   - **`Q_switch_while_busy`'s refusal is already live** for the clear case: `POST /conversations`
     answers 409 while a turn is in flight, and the button renders `disabled`.
2. ~~**Sidebar, read-only list.**~~ **SHIPPED.** `ConversationStore#list`, `RelativeTime`,
   `views/_sidebar.erb`, the two-column shell, `GET /conversations`. What it settled beyond the
   plan:

   - **The live conversation is not in the listing**, because `#create` mints without writing and
     `#write_meta` is the commit point. So the sidebar's model is *store listing ∪ the runner's live
     conversation*, assembled in `App#conversation_rows` — the one place that holds both
     collaborators. `App.set :conversations` is the new injected setting.
   - **`meta.json` is the commit marker, and `#list` enforces it**: a directory with `history.json`
     and no `meta.json` is a save interrupted between pikuri's half and ours, and is not listed.
     That was already `#write_meta`'s documented ordering; the listing is what makes it load-bearing.
   - **The refresh path is a fetch, not a new SSE frame.** "+ new conversation" changes the sidebar
     (a row for the conversation just saved, and the highlight moves), so app.js's `reset` handler
     re-fetches `GET /conversations` and swaps the `<nav>`'s innerHTML. Rendering stays in ERB —
     pushing sidebar HTML through `Broadcaster` would have meant `AgentRunner` rendering markup, and
     the seam says no. Correct by construction against the race, too: `AgentRunner#conversation`
     answers under the same mutex `new_conversation` holds, so a request landing between the `reset`
     frame and the switch's end *blocks* rather than reading the outgoing conversation — which is
     why `#conversation_rows` asks the runner first and the store second.
   - **Rows are `<li>`, not links or forms**, so `Q_get_side_effects` doesn't come due until
     step 4.
3. ~~**Loading.**~~ **SHIPPED** — `HistoryReplay`, `AgentRunner#load_conversation`,
   `HistoryLoaded`'s arm. Graduated to `D_replay_from_history` + a **Scope decisions** invariant;
   `Q_store_format` is settled there, not here. Nothing calls `#load_conversation` yet — step 4 is
   the UI on top of it. What it settled beyond the plan:

   - **No `conversation_session.rb`, in this step or the next.** The transcript is *rebuilt*, not
     swapped: `load_history!` emits `Reset`, whose arm (slice 1) already empties the transcript and
     every open tab, and the replay refills it through the same listener. So the "one indirection
     behind `App.set :transcript`" idea is dead for v1 — it only comes back for v2's *resident*
     transcripts, where the point is N of them, not a swap.
   - **The replay feeds `SseListener` directly, not the agent's listener list**, which wraps it in
     the 15 fps delta rate-limiter a replay has nothing to say to. That is why `AgentRunner` gained
     a `listener:` — and why the busy-refusal is load-bearing beyond politeness: `SseListener` keeps
     unguarded per-turn streaming state, and the mutex plus "no loop is running" is what makes
     feeding it from a *request* thread safe.
   - **`load_conversation` takes a listed `Conversation`, never an id.** Resolving the id against
     `store.list` is step 4's job, which means no route ever turns user input into a path.
   - **Read before write.** `History.load` runs before the outgoing conversation is saved and before
     `load_history!` clears anything, so a corrupt `history.json` returns `:failed` with the live
     conversation untouched rather than half-swapped.
   - **`HistoryLoaded` renders nothing.** The replay shows the conversation; a "restored N messages"
     line would be the only block in the transcript that never came from the agent. `Q_token_readout`
     still holds — `TokenLog` reseeds off the event, and the status broadcast happens after
     `load_history!` returns.
   - **The interrupted-tool-call repair is replayed, not skipped**, so the transcript shows the
     `[Tool execution was interrupted]` observation the model is actually looking at.
4. **Switching** (`Q_switch_while_busy`, `Q_selection_scope`) — the UI on top of a load path that
   already works.
5. **v2 auto-title**, or manual rename first if `Q_title_length` says the sidebar wants short
   titles anyway.
6. **v2 background turns** (`Q_switch_while_busy`) — conversation-tagged emissions, topics in
   `Broadcaster`, resident transcripts, a busy dot on the row. Last, because it's the step that
   rewrites who owns what, and every earlier step is useful without it.
