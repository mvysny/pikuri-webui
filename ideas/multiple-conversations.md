# Multiple conversations

Today `pikuri-web-chat` is one *live* conversation (`D_single_shared_conversation`). Slice 1 below
has shipped, so a conversation is now saved to disk and "+ new conversation" starts a fresh one —
but nothing loads a saved one back, so a restart still lands you in an empty transcript with the
old conversation sitting unreachable on disk. This idea: **many conversations, persisted on disk,
picked from a left sidebar** — roughly Web Claude's shape, minus multi-user.

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

**New work this creates:** `SseListener`'s `else` arm documented `Reset` / `ModelSwitched` as
*unreachable*. Slice 1 made `Reset` reachable and gave it an arm (clear the transcript, push a
`reset` frame). `HistoryLoaded` still has none — it is where a "restored N messages" notice would
go, if we want one — and becomes reachable the moment step 3 lands.

---

## What gets stored, exactly — the fork, narrowed

The model half is settled: `history.json`, written by `History#save`, and we don't get a vote on its
contents. What's left is the **render** half — `Transcript` blocks (kinds, ids, rendered HTML) — and
whether it needs an artifact of its own at all.

| layer | what it is | who needs it | who owns it |
| --- | --- | --- | --- |
| model | messages, tool calls, results, thinking, attachments | the agent, to continue | pikuri (`history.json`) |
| render | `Transcript` blocks | the browser, to show what happened | us — open question |

Three candidates, re-scored against what actually shipped upstream:

- **(a) Store rendered blocks verbatim** (`blocks.json` beside `history.json`). Exact reload, zero
  replay logic. Still costs what it cost before: HTML strings on disk, so a `MarkdownRenderer` or
  `style.css` fix never reaches old conversations, and two representations of one conversation that
  can disagree. **Dead** — the long lifetime makes the frozen-HTML problem worse than it is today.
- **(b) Store nothing extra; re-derive blocks from `history.json`.** The original objection was that
  this needs "a second renderer that has to guess", *"since `Event::ThinkingDelta` content isn't in
  the history at all"*. **That objection is now factually wrong.** `History::Message` carries
  `thinking` (text + signature), `tool_calls` (name + arguments), `tool_call_id`, full untruncated
  tool-result content, and `kind: "reference"` marking exactly what `SystemInjected` collapses. The
  block kinds map mechanically, one message to one-or-two blocks:

  | history | blocks |
  | --- | --- |
  | `role: user, kind: user` | `:user` |
  | `role: user, kind: reference` | `:notice` (the skill one-liner) |
  | `role: assistant` with `thinking` | `:thinking`, then `:assistant` |
  | `role: assistant` with `tool_calls` | `:tool_call` per call |
  | `role: tool` | `:tool_result` (truncate at render, as today) |

- **(c) Append an event log** (`log.jsonl`, source text not HTML) beside `history.json`, and replay
  it through the real `SseListener` on load.

**Lean flips to (b).** Two reasons, and the second is the real one:

1. It is one artifact plus our envelope, not two artifacts that can disagree — and (b) keeps the
   "old conversations get today's renderer and today's CSS" property that was (c)'s whole selling
   point over (a).
2. **(c) couples us to pikuri's event set; (b) couples us to a versioned file format.** An
   `Event <-> Hash` codec must cover every variant `SseListener` matches on and stay in step as
   pikuri adds variants — and pikuri adds them steadily (`Transient` and `HistoryLoaded` both landed
   in the same unreleased cycle as the history itself). `History` is the opposite: written down,
   `version:`-stamped, additive-only by decision, with unknown keys ignored so a file from a newer
   pikuri still loads. Betting a persistence format on the stable one is not close.

**What (b) actually loses**, stated plainly, because it isn't nothing:

- `:error` blocks — `! cancelled`, and a `run_loop` failure notice. Never messages, so gone on
  reload.
- `FallbackNotice` lines.
- The partial assistant text that cancel deliberately *preserves* (`flush_assistant(:preserve)`).
  Cancel raises out of `Chat#ask`, so that text never became a message — the reloaded conversation
  shows the user turn with no reply under it. Honest, and arguably a better record than a fragment,
  but it is a visible difference between "the tab I have open" and "the tab after a reload".

That is session ephemera plus one real case. If it turns out to matter, (c) is the answer — and the
fallback is cheap to reach, because nothing about (b) forecloses adding `log.jsonl` later.

**`Q_store_format` — lean (b), pending a sanity check that the losses above are acceptable.**

**Sub-question, and it's the same one either way:** does the rebuild go through the real
`SseListener` (with the `Broadcaster` swapped for a null sink) fed *synthesized* events, or through
a separate `History → blocks` builder? (Lean: **synthesize events**. A `HistoryReplay` that turns
each message into the `UserTurn` / `Thinking` / `Assistant` / `ToolCall` / `ToolResult` /
`SystemInjected` events that produced it means there is still exactly **one** renderer and one
event→kind mapping, and the trifecta in *Conventions* — SseListener / index.erb / style.css — stays
a trifecta. A separate builder is a second place block kinds are decided.)

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

**`Q_schema_version`** — `schema: 1` in `meta.json`; an unknown version renders the row greyed-out
with "unsupported format" instead of crashing the sidebar. Cheap, do it in v1.

**`Q_retention`** — no cap, no cleanup in v1? A delete button (with what confirmation?) is v2 at
the earliest, and deleting the *currently open* conversation needs a rule.

---

## The switch: what happens in-process

`AgentRunner` owns **the** worker thread and **the** agent; `Transcript` owns **the** block list;
`Broadcaster` fans out to every tab. A conversation switch therefore means:

1. Flush the current conversation's store (should already be current per `Q_write_shape`).
2. `agent.load_history!(History.load(dir))` — which runs `clear_conversation` itself (history,
   controls, interloper queue, re-assembled system prompt, `Event::Reset`), then restores and emits
   `Event::HistoryLoaded`. For a *new* conversation it's `agent.clear_conversation` alone.
3. Swap in a fresh `Transcript` rebuilt from the store (per `Q_store_format`).
4. Tell every tab to re-snapshot.

Note the ordering hazard in step 2→3: `load_history!` emits `Reset` and `HistoryLoaded` **into the
live `SseListener`**, which is about to have its transcript swapped underneath it. Either swap the
transcript first, or have the `Reset` arm be what clears it — but it has to be decided, not
discovered. (Lean: swap first, and let `Reset`'s arm be a no-op on an already-empty transcript.)

Step 3 is the one that pokes the architecture: `App` holds its collaborators in **class-level
settings** (`App.set :transcript, …`), set once at boot. Either the setting becomes a
`ConversationSession` object whose `#transcript` is swapped behind it (one indirection, routes
unchanged), or `App` learns to ask a `ConversationStore` for "the current transcript" on each
request. (Lean: the former — routes keep calling `settings.transcript.to_a`, and the swap is one
mutex-guarded assignment in the thing that owns both.)

Step 4 is nearly free, and **slice 1 already built it**: a `reset` SSE event, whose handler is
`transcript.replaceChildren()`. The earlier lean was to reuse app.js's existing
`location.reload()` reconnect path, and that was wrong for one reason found while building —
**a reload throws away a half-typed message** in every open tab, including tabs whose user is not
the one who clicked. Emptying in place costs one more line of JS and no client state, so
`D_no_js_build_step` and `D_server_authoritative_transcript` hold either way. A *switch* (as
opposed to a clear) needs blocks to arrive as well as leave, so it either follows the `reset` with
the new snapshot's blocks or reuses the reload after all — decide that in step 3, not here.

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
  `conversation_session` shape from step 3 above is a v1-only stepping stone, not the end state.
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

- `lib/pikuri_web/conversation_store.rb` — enumerate / create / delete conversation folders, read
  and write `meta.json`. Pikuri-free: it deals in **paths and plain hashes**, never a `History`.
- `lib/pikuri_web/conversation.rb` — one conversation's metadata + paths; the sidebar's row model.
- `lib/pikuri_web/conversation_session.rb` (name TBD) — holds the *current* transcript + store
  handle, does the switch under a mutex; what `App.set :transcript` becomes.
- `lib/pikuri_web/history_replay.rb` — `Pikuri::Agent::History` → the events that produced it, fed
  to a real `SseListener` with a null broadcaster (per `Q_store_format`'s sub-question). Under (c)
  this is an `event_codec.rb` instead. Either way it's a **fourth file inside the Pikuri seam**, so
  `D_pikuri_free_core`'s "only three files" invariant needs amending — and `AgentRunner` is where
  `export_history.save` / `History.load` are called from.
- `lib/pikuri_web/relative_time.rb` — or a helper in `App`; too small for its own file, probably.
- `views/_sidebar.erb`, plus `index.erb` gaining the two-column shell.
- Routes: `POST /conversations` (new), `POST /conversations/:id/select`, later
  `DELETE`/`PATCH` for delete/rename.
- Specs: store round-trip against a stubbed `XDG_STATE_HOME` (`Paths.state` reads env at call time,
  deliberately, so stubbing works); a replay spec building a `History` in Ruby (its constructor is
  public — no fixture file needed), replaying it, and asserting the rebuilt blocks. Note
  `Pikuri::Testing.fake_transport` exists for driving a real `Agent` end-to-end with no server, so
  a save→load→save fixpoint spec is cheap.

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
2. **Sidebar, read-only list** — titles + relative time, current one highlighted, no switching.
   Proves the layout and the metadata reads. No `History.load` yet, so no replay risk.
3. **Loading** — `History.load` + the replay path (`Q_store_format`) + `HistoryLoaded`'s arm. This is
   the only genuinely new engineering left, and it's worth doing as a spec-first fixpoint
   (save → load → save produces an identical folder) before any route touches it.
4. **Switching** (`Q_switch_while_busy`, `Q_selection_scope`) — the UI on top of a load path that
   already works.
5. **v2 auto-title**, or manual rename first if `Q_title_length` says the sidebar wants short
   titles anyway.
6. **v2 background turns** (`Q_switch_while_busy`) — conversation-tagged emissions, topics in
   `Broadcaster`, resident transcripts, a busy dot on the row. Last, because it's the step that
   rewrites who owns what, and every earlier step is useful without it.
