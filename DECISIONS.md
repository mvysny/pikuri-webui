# DECISIONS.md

A living record of the design decisions behind pikuri-web — especially
the *roads not taken*. It exists because the graduation pipeline (see
[`AGENTS.md`](AGENTS.md)) had no home for one fact class: a rejected
alternative. Both candidate homes refuse it on their own stated terms —
a source file's YARD header explains the class *as it is* to someone
reading that class, and gains nothing from an argument against a design
that never shipped; and `AGENTS.md` is pulled into *every* session's
context by `CLAUDE.md`, so rationale parked there is paid for on every
turn. This file is the lazy side of that split: never context-loaded,
read only when someone asks "why this way?".

It is the *why-we-chose* record. It is not the *how-it-works* reference
(the YARD headers), the *what-you-must-not-break* list (`AGENTS.md`), or
the user-facing promise (`README.md`). An entry links out rather than
restating.

**Boundaries** — the ones that keep this from becoming a second copy of a
neighbour:

- **vs. `AGENTS.md`.** That file is context-loaded and holds the
  *invariant*: the rule a future change must not break, stated flat, with
  a `See D_<slug>` pointer. This file holds the argument behind it — the
  alternatives, the measurements, the consequence a contributor would
  trip over. One line there, the reasoning here; never two half-answers.
- **vs. the YARD headers.** A header describes its class as it is, for
  someone about to change that class. It keeps the local contract
  ({Transcript}'s thread-safety, {StreamingMessage}'s lifecycle). Only
  the *fork* comes here.
- **vs. `README.md`.** That file is the front door: what the app is,
  the chat-only trifecta promise, how to run it. Why the promise was
  drawn there rather than somewhere else is an entry here.
- **vs. pikuri's own `DECISIONS.md`** (`../pikuri/DECISIONS.md`). This
  project owns the web shell and nothing else, and the same split applies
  to the decision log: a fork inside the agent loop, a tool, the
  Interloper's delivery boundary, LLM transport — that is logged
  upstream, and an entry here cites it rather than re-arguing it. What
  belongs here is the shell's own forks, prominently including *what we
  deliberately did not port* from pikuri-tui.

**Format.** One entry per decision. The ID is a slug, not a number:
`D_` plus a 1–4-word snake_case hint at the subject
(`D_rerender_and_replace`), so a citation carries meaning on its own.
The `(date)` on the heading is *decided* provenance, not a log position —
git owns the edit history, so don't narrate how an entry used to read.
Keep each entry tight: context, the decision, the alternatives rejected
and why, and the consequences a future contributor would trip over. A
decision is worth logging the moment it's *made*; implementation can lag
(the `Status:` line says which).

**No entry without a real fork.** If nothing was seriously considered and
rejected, it isn't a decision — it's how the thing works, and that's the
YARD header. This is the guard against a diary.

**Newest first.** Entries run reverse-chronologically by decided date, so
a scan hits recent decisions first.

**Never read wholesale.** `grep '^## D_' DECISIONS.md` is the index;
there is no ToC (same discipline as `ls ideas/`). Cite an entry by slug.
Grep tripwire: every `D_<slug>` referenced anywhere in the repo must
exist as a `^## D_` heading here.

**Entries are mutable — edit in place, don't append addendums.** Each
entry is the single coherent home for one *live* decision; keep it
current as the decision is refined or extended. Two things this does
*not* license:

- **The roads-not-taken stay.** "We chose X, rejected Y because Z" is
  live content of the current decision, not stale history — never edit it
  away. It's the most valuable thing in the file.
- **A reversed *shipped* decision forks a tombstone, it is not
  overwritten.** When a design was tried, shipped, and then thrown away,
  leave the old entry as the scar, set its `Status:` to **Superseded by
  `D_<slug>`**, and write the replacement fresh. The line: *refined or
  extended* → edit in place; *reversed after shipping* → tombstone + new
  entry.

**Backfill is opportunistic.** Rationale that already sits inline in a
YARD header or in `AGENTS.md`'s **Scope decisions** stays put — this file
is the home going *forward*. Move an old one only when you're already
editing that doc and the inline reasoning is crowding out the live
design or the invariant.

---

## D_conversation_owns_agent — A conversation owns its agent; a tab owns which conversation it views (2026-08-28)

**Status:** Accepted, shipped 2026-08-28. {ConversationRegistry} holds one
{AgentRunner} per conversation opened — its own `Agent`, `Interloper`,
`Cancellable`, `TokenLog`, {Transcript} and {SseListener} — and
{Broadcaster} addresses frames per conversation.

**Context.** Everything before this had *one* agent and one transcript, so
"which conversation is live" was server state and every tab followed it
(`D_single_shared_conversation`). That model has no precedent in any web
app: it is tmux in a browser. Slack is the counter-example — its channel
selection lives in the URL, and the session exists only for auth. A tab
should be free to read one conversation while another works.

**Decision.** A runner *is* a conversation, for its whole life. No
switching, no live pointer. `GET /c/:id` opens one, minting and replaying
its history on first visit; the tab's EventSource subscribes to that id;
`POST /messages` and `POST /cancel` both name their conversation. What
falls out is worth naming, because it is most of the value:

- **The whole switch machinery went away** — `new_conversation`,
  `load_conversation`, `delete_conversation`, and the ordering hazard where
  a `Reset` emitted before the live pointer moved got stamped with the
  outgoing conversation.
- **Nothing refuses because something *else* is busy.** Only delete
  refuses, and only for the conversation actually in flight.

**Rejected: minting a runner only on first *send*, viewing from a
throwaway replay.** Cheaper in memory, and it was what shipped one commit
earlier. Dropped because a tab reading a not-yet-resident conversation
would then apply frames whose block ids agree with its snapshot only
because both replay the same events into a fresh {Transcript} — correct by
an argument spanning two classes, which is the kind of thing this codebase
keeps trying to delete. Minting on view costs one agent per conversation
*opened in a session*, which for a single user is nothing.

**Rejected: reaping idle runners.** Nothing is ever dropped except on
delete. Add reaping if residency ever actually hurts; a cleverer minting
rule is the wrong lever.

**Consequences.**

- The registry and {ConversationStore} are now the only genuinely shared
  mutable state. The registry has a `Monitor`; the folder's own
  consistency is still open (`ideas/conversation-store-locking.md`).
- `HistoryReplay.snapshot` became dead code and was removed.
- Rendering a detached conversation is not optimized: with a serial
  executor only one conversation renders at a time anyway, so the
  accumulate-don't-render idea only pays at pool > 1.

## D_serial_turn_executor — Turns run on one shared serial executor, and pool size 1 is correctness (2026-08-28)

**Status:** Accepted, shipped 2026-08-28 as
`Concurrent::SingleThreadExecutor`, injected into every {AgentRunner}.

**Context.** A turn blocks on the LLM for minutes, so it cannot run on a
Sinatra request thread (`D_worker_thread_agent_loop`). Once conversations
own their own agents, "how many turns at once" stops being implied by
"how many agents".

**Decision.** One process-wide serial executor. Its queue *is* the
admission gate: submitting always succeeds, and a turn waiting for a busy
executor reports `:queued` rather than being rejected. Cancelling a queued
turn needs nothing from pikuri — the job checks a flag on entry and returns
without starting.

**The pool size is not a tunable, and the type says so.** `executor:` is
typed `Concurrent::SerialExecutorService`, which `SingleThreadExecutor` and
`ImmediateExecutor` satisfy and `FixedThreadPool.new(2)` does not. An
`Executor`'s contract is `submit(block) → result`: it holds no state by
design, so single-writer safety at pool 1 is a property of *that number*
rather than of the abstraction, and it would evaporate silently when
someone raised it. Two writers would mean two agents writing the
conversations folder at once, and two agents inside pikuri's shared tool
constants (`CALCULATOR` / `WEB_SCRAPE` / `FETCH`) at once.

**Rejected: exposing pool size as a `--parallel` flag.** Proposed, then
dropped: a dial labelled "how fast" that silently enables data races is a
trap. Raising it needs the owner-thread work in `ideas/event-queue.md`
first, and a thread-safety answer for the tool constants from pikuri.

**Rejected: hand-rolling the pool on stdlib `Queue`.** Ruby ships no
executor, so the alternative is writing a pool, a shutdown protocol and a
backpressure policy by hand. `concurrent-ruby` is a new direct dependency
(the first `Concurrent::` in the pikuri family — pikuri itself is stdlib
`Mutex` throughout) and earns its Gemfile paragraph on exactly that.

**Rejected: treating the executor as the event queue.** They share a
mechanism and have opposite contracts — this one exists *to* block, an
owner thread must never block. See `ideas/event-queue.md`.

**Consequences.**

- Shutdown drops whatever is running: saves land at turn end, and
  `turn_executor.shutdown` from the `:state, :stop` hook deliberately does
  not wait (waiting there would re-create the parked-thread bug
  `D_shutdown_on_state_stop` exists to prevent). Accepted — single user,
  rare restarts.
- Specs inject `ImmediateExecutor` to run turns inline, which deleted one
  hand-rolled spin-waiter. The examples that are *about* the busy state
  keep a real thread.

## D_delete_no_undo — Deleting a conversation is irreversible, and the live one rolls onto a fresh conversation (2026-08-28)

**Status:** Accepted, shipped 2026-08-28 as `ConversationStore#delete`,
`AgentRunner#delete_conversation` and `POST /conversations/:id/delete`.

**Context.** `ConversationStore` grew every verb but this one, so
conversations accumulated until the user ran `rm -r`, which is what
`README.md` told them to do. Three things needed settling before a ✕
could go on a sidebar row: what confirmation looks like, what happens
when the deleted conversation is the *live* one, and whether the removal
is recoverable.

**Decision.** A native `confirm()` naming the conversation — one line of
`app.js` and the only option needing no CSS at all, where a modal
component is exactly the kind of thing that starts arguing for a build
step (`D_no_js_build_step`) — then a real removal: `FileUtils.rm_r` over the whole folder, `meta.json` unlinked
first. Deleting the live conversation is `#new_conversation` *without the
save* — the agent is cleared (its `Event::Reset` empties the transcript
in every tab, the same path a fresh conversation takes) and a fresh id
minted, then the folder goes. Both cases are refused while a turn is in
flight (409), like selecting and starting a conversation.

The conversation folder is ours end to end — nothing but pikuri and this
shell writes there — so a delete removes the directory wholesale. That is
deliberately unlike pikuri's refusal to sweep a single unreferenced
attachment (pikuri `DECISIONS.md` `D_history_attachments`): declining to delete a
*file* someone may have put beside the history is compatible with
removing the *conversation* it belongs to. Attachments are never shared
between conversations, so nothing is refcounted.

**`meta.json` goes first because `#write_meta` is the commit point.**
Unlinking the envelope is that commit's exact inverse, so a removal that
dies half-way leaves a conversation *unlisted* rather than one that lists
and then cannot be opened. Orphaned bytes are the better failure.

**Rejected: an undo, and its tombstone variant.** Both need the folder to
survive the click. A conversation holds everything the user typed and
everything the tools fetched, unencrypted (`0700` is the whole of the
protection) — someone deleting one is often deleting it *because* of what
is in it, so keeping it for ten seconds "in case" is a privacy footgun
and keeping it until a sweep is worse. The tombstone shape was
additionally tempting because `#list` already skips a directory with no
`meta.json`; that state currently means *a save interrupted between
pikuri's half and ours*, and overloading it would make a crash and a
deletion indistinguishable forever.

**Rejected: refusing to delete the live conversation.** Consistent with
how switching refuses, and useless: the conversation you most want to
drop is usually the one in front of you. Rolling onto a fresh one is
barely more code and is what the user meant.

**Rejected: `DELETE /conversations/:id`, and a second `<form>` per row.**
The row is already a form that POSTs to `/select`, and a nested form is
invalid HTML while two sibling forms cannot share the row's flex line.
One form with two submit buttons, delete carrying `formaction`, keeps the
no-JS path working and leaves Enter on the row selecting rather than
deleting.

**Consequences.**

- A bare `conversations` SSE event now means "the sidebar's list changed,
  re-fetch it" — deleting a non-live conversation emits no `reset`, so
  without it every *other* tab would keep a row that 404s when clicked.
  `app.js` grew one `refreshSidebar()` that `reset` and the new event
  share; a future titles or search feature should reuse the same signal.
- The ✕ is revealed on hover and `:focus-within`, and shown
  unconditionally under `@media (hover: none)` — on a touch device the row
  itself is a submit button, so a tap selects the conversation instead of
  revealing anything (`D_target_browsers`). The reveal uses `opacity`, not
  `display`/`visibility`, or the button would leave the tab order and
  `:focus-within` could never fire.
- **A second process can resurrect what you deleted**, by saving its own
  live copy at the next turn end. Accepted as a limitation; delete is the
  first destructive operation that makes the case in
  `ideas/multi-process-locking.md`.
- Nothing new serializes the folder. What keeps a delete from racing the
  turn-end save is the runner refusing while busy, which is the same
  discipline `ideas/conversation-store-locking.md` and
  `ideas/event-queue.md` argue should stop being a discipline.
- Deleting is the whole answer to retention: still no cap and no
  auto-prune. `rm -r` on the state folder remains a complete reset.

## D_target_browsers — Firefox on the desktop, Safari on iPad and iPhone; greenfield only, no polyfills (2026-08-28)

**Status:** Accepted 2026-08-28. The iPhone layout is *not* shipped — see
Consequences.

**Context.** The delete button's hover-reveal was the first change whose
correctness depended on which browsers count, and "modern browsers" is
not an answer a CSS reviewer can use.

**Decision.** Three targets: Firefox on the desktop, Safari on iPadOS,
Safari on iOS. Nothing is polyfilled and nothing carries a vendor prefix
for a browser outside that list — `:has()`, `:focus-within`,
`@media (hover: none)`, `dvh` units and `SubmitEvent#submitter` are all
fair game and are used. **The iPad counts as a desktop**: it has the
screen for the sidebar-beside-chat layout as it stands.

**Rejected: "every modern browser".** It reads generous and decides
nothing — every question about a selector or a unit comes back
unanswered, and in practice it means testing on whatever is open.

**Consequences.**

- **The iPhone layout does not work, and that is deferred, not denied.**
  There is a `@media (max-width: 48rem)` fallback that stacks the sidebar
  into a 20vh strip, and nobody has opened it on a phone. Tracked in
  `ideas/phone-layout.md`, which leads with the finding that the real
  blocker is not CSS: reaching this app from a phone means `--bind`
  leaving 127.0.0.1, and there is no auth (`D_single_shared_conversation`).
- That breakpoint is on the wrong side of the iPad: portrait is 768px,
  exactly 48rem, so `max-width: 48rem` matches and an iPad in portrait
  gets the phone fallback today. Contradicts treating iPads as desktops;
  fix belongs with the phone layout.
- A change that needs a polyfill or a build step to reach a fourth browser
  is out of scope twice over — here and under `D_no_js_build_step`.

## D_replay_from_history — Store only pikuri's history; re-derive the transcript by replaying synthesized events (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 as {HistoryReplay}.

**Context.** A saved conversation has two layers: the *model* half
(messages, tool calls, results, thinking, attachments — `history.json`,
written by `Pikuri::Agent::History#save`, whose contents we do not get a
vote on) and the *render* half ({Transcript} blocks: kinds, ids, HTML).
Loading a conversation back means producing the second from something on
disk.

**Decision.** Store nothing beyond `history.json` and our `meta.json`,
and rebuild the blocks by turning each message back into the
`Agent::Event`s that produced it, fed through the real {SseListener}. The
transcript is *rebuilt, not swapped*: `Agent#load_history!` emits
`Event::Reset`, whose existing arm empties the transcript and every open
tab, and the replay refills it — so there is still exactly one
transcript, one renderer, and one event→kind mapping.

**Rejected: store the rendered blocks** (`blocks.json` beside
`history.json`). Exact reload, zero replay logic — and HTML strings on
disk, so a {MarkdownRenderer} or `style.css` fix never reaches an old
conversation, plus two representations of one conversation that can
disagree. The longer these files live, the worse frozen HTML gets.

**Rejected: append an event log** (`log.jsonl`, source text not HTML)
and replay it. It keeps the today's-renderer property, but it prices
persistence on pikuri's *event set*: an `Event ↔ Hash` codec must cover
every variant {SseListener} matches on and stay in step as pikuri adds
more — and pikuri adds them steadily (`Transient` and `HistoryLoaded`
both landed in one unreleased cycle). `History` is the opposite: written
down, `version:`-stamped, additive-only by decision, unknown keys
ignored. Betting the format on the stable one is not close. Nothing here
forecloses adding `log.jsonl` later if the losses below start to matter.

**Rejected: a `History → blocks` builder** instead of synthesized events.
Same output, one more place block kinds are decided — the
SseListener / `index.erb` / `style.css` trifecta would stop being one.

**Consequences.** Only messages are stored, so what never became one is
gone on reload: `! cancelled` and run-loop failure blocks,
`FallbackNotice` lines, and the partial assistant text a cancel
deliberately preserves (it raises out of `Chat#ask` before the message
lands) — a cancelled turn reloads as a user message with no reply under
it. Two couplings are the price of re-deriving: the replay must emit
events in the order the *agent* emits them rather than the order messages
sit in (a batch's `ToolResult` follows its own `ToolCall`), and it must
strip the `<system-reminder>` envelope `Agent#append_reference_block`
adds, whose tag is a private constant upstream. Both are held by an
end-to-end spec in `conversation_flow_spec.rb` that renders one
conversation live and again from disk and demands the same blocks — the
canary for a rename or a reordering upstream.

---

## D_shutdown_on_state_stop — Close the Broadcaster from Puma's `:state, :stop`, the last hook before the graceful wait (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 in `bin/pikuri-web-chat`.

**Context.** Ctrl+C hung for as long as a browser tab stayed open. Every
open `EventSource` parks a Puma request thread in the `GET /events` drain
loop; Puma's graceful stop waits for in-flight requests **with no
deadline**; and the 15 s SSE heartbeat keeps those parked writes
succeeding, so nothing ever errors the thread out. The wait ended only
when the browser finally dropped the connection. This is the bill for the
threading rule (`D_worker_thread_agent_loop`) — a design that parks
serving threads on purpose has to unpark them on purpose too.

**Decision.** The boot script registers on Puma's `:state` event and
calls `Broadcaster#close` for `:stop` and `:restart`. That event is fired
by the server thread on the line *before* `graceful_shutdown`, which
makes it the last hook that runs on the near side of the wait.
`Broadcaster#unsubscribe_all` became `#close`: the same sentinel push,
idempotent, and it now also refuses *later* subscribers, so a connection
handed out mid-shutdown cannot re-park a thread. `force_shutdown_after:
5` stays as the backstop. Measured: two SSE clients attached, SIGINT and
SIGTERM both exit within the second.

**Rejected: `at_exit`, Sinatra's INT trap, and `Puma::Events#after_stopped`.**
All three are on the *far* side of the wait, so all three are release
valves that open after the thing they would have released has already
finished blocking. The INT trap additionally never fires — Puma
overwrites it during `launcher.run` — and `after_stopped` was measured at
a still-10 s hang, because `Puma::Server#run` performs its own
`graceful_shutdown` in the server thread before the launcher gets to fire
it.

**Consequences.** Nothing in the exit path may rely on `at_exit` or on
Sinatra's own INT trap; a future cleanup that needs to run before the
wait belongs in the same `:state` hook. `Broadcaster#close` must stay
idempotent and must keep refusing new subscribers — the invariant lives
in its YARD header.

## D_dev_flag_no_reload — `--dev` is Sinatra's development mode, not code reloading (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 in `bin/pikuri-web-chat`.

**Context.** A dev flag on a web server usually promises reloading. Here
it can't: the agent, its listener stack and the runner thread are
long-lived instances wired once at boot, so Ruby under `lib/` reloads in
neither mode and re-reading it would leave a live conversation bound to
the old objects. `public/*.js` and `.css` were always read per request
and never needed a flag.

**Decision.** `--dev` flips Sinatra into `:development` and turns on
`show_exceptions` — which is what `views/*.erb` re-reading and in-browser
exception pages hang off, and nothing more. The README documents
restarting under a file watcher as the way to iterate on Ruby, which is
cheap now that shutdown is instant (`D_shutdown_on_state_stop`).

**Rejected: a reloading dev mode** (Zeitwerk reload, `rerun`-style
in-process reloading). Re-wiring the live agent is the actual
requirement, and no amount of reloading does it — the flag would name a
guarantee it cannot keep.

## D_theme_cookie — Theme is a browser cookie, resolved server-side at `GET /` (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 in `public/style.css`,
`views/index.erb` and `public/app.js`.

**Context.** Adding a light theme raised where the preference lives. The
transcript is server-authoritative (`D_server_authoritative_transcript`),
so "state lives on the server" is the house style — but this particular
state is per-*browser*, not per-conversation, and the page it affects is
kept live by one long SSE connection that a reload destroys.

**Decision.** Both palettes live in `public/style.css` as `--dark-*` /
`--light-*`, and the rest of the file reads only the nine semantic tokens
it already used; dark stays the default under `:root`, and
`:root[data-theme='light']` remaps the same nine. `GET /` resolves the
`theme` cookie against an allowlist and renders `data-theme` onto
`<html>`, so a light-theme user never sees a dark first paint. `app.js`
flips the attribute and rewrites the cookie in place.

**Rejected: a `POST /theme` route and server-held theme state.** A round
trip for a colour change means a reload, and a reload costs an SSE
reconnect — paying a transcript resync for a presentational toggle. The
cookie is deliberately *outside* {Transcript} and stays presentational,
which is what lets "the transcript is server-authoritative" keep meaning
what it says rather than becoming "…except theme".

**Consequences.** The theme is the one piece of per-browser state in the
project, and it is the precedent a future per-browser preference should
follow. A new themed colour means adding it to both palettes *and* both
mappings; nothing outside `style.css` may read a raw colour.

## D_chat_only_entry_point — The trifecta promise belongs to the boot script, not to the project (2026-08-27)

**Status:** Accepted, shipped 2026-08-27; `bin/pikuri-web` renamed to
`bin/pikuri-web-chat`, matching pikuri-tui's `bin/pikuri-tui-chat`.

**Context.** The README never said which shape this shell offers — OS
agent, coding agent, or chat. It's a chat, and that turned out to be the
selling point worth leading with: the whole tool set is `web_search`,
`web_scrape`, `fetch` and `calculator`, so in pikuri's lethal-trifecta
terms it holds the *untrusted content* and *egress* legs and **not** the
*private data* leg. Nothing wired here reads the disk, runs a command or
touches a repo — so there is nothing on your machine for it to find, and
you can think out loud at it. But pikuri ships `pikuri-os`,
`pikuri-code` and `pikuri-workspace` in the same checkout, one line away.

**Decision.** The guarantee is attached to an *entry point*, and the
script carries its shape in its name. Should an OS or code shell grow
later it lands as a **sibling script** with its own tool set and its own
boot-time trifecta report, reusing the tool-set-agnostic plumbing
({AgentRunner}, {SseListener}, {Transcript}, {App}) — never as extra
tools bolted into this one.

**Rejected: attaching the promise to the project, and growing this
script's tool set.** A project-level promise is one a future commit
breaks silently: adding a disk- or shell-touching tool here would revoke
a guarantee a user has *already read* in the README, with nothing in the
diff that looks like a revocation. Naming the shape in the script makes
the same change visibly wrong.

**Consequences.** The README keeps only the caveat that survives the
promise: your own typed input still egresses to the configured LLM
server, and a scraped page can try to talk the agent into fetching an
attacker-chosen URL. The boot-time trifecta report stays the *checkable*
answer for whatever tools a script actually wired, so a sibling script
does not need this entry re-argued — it needs its own report.

## D_per_shell_state_root — Every shell keeps its state under one folder named after itself (2026-08-27)

**Status:** Accepted, shipped 2026-08-27. Reverses the layout the first
conversation-store commit shipped the same day, which put `conversations/`
directly under `Pikuri::Paths.state`.

**Context.** `Pikuri::Paths.state` is shared: pikuri writes there, and so
will pikuri-tui and every sibling script AGENTS.md anticipates
(`D_chat_only_entry_point` — a new capability is a new script, not a new
tool). Conversations are the first thing this shell persists, and the
first commit named the folder after its *contents*, on the theory that a
future pikuri-tui `/resume` should read the same files.

**Decision.** One folder per shell, named after the script, and
**everything that shell persists goes inside it**:

```
~/.local/state/pikuri/pikuri-web-chat/conversations/<id>/
```

`bin/pikuri-web-chat` derives a single `state_root` local and composes
every path from it, so the next thing worth persisting lands beside
`conversations/` rather than in a second place. The root is created by
{ConversationStore} at construction — the folder exists from boot, not
from whichever later event happens to save first.

**Rejected: a shared `conversations/` for cross-shell resume.** The
attractive end state is "start a conversation in the TUI, finish it in the
browser", and a shared folder looks like the cheap way there. It isn't:
the *format* is what makes that possible (pikuri's `history.json` plus a
documented envelope), and the format travels regardless of where the files
sit. Meanwhile a shared folder means two shells writing one directory with
no agreement about who owns it, no way to tell whose conversations these
are, and `rm -r` on it destroying more than the shell you meant. Path
sharing is the *last* step of interop, not the first.

**Consequences.** Cross-shell resume now needs a deliberate location — a
shared subfolder both shells opt into, or a pikuri-level store — and
whatever it is, it is a decision rather than an accident of layout. This
folder is also the reset: `rm -r` on it returns the shell to first-run
state and touches nothing else.

## D_schema_complete_config — One config file for every pikuri shell, whole schema, secrets nowhere else (2026-08-27)

**Status:** Accepted, shipped 2026-08-27 as {Config}, a port of
pikuri-tui's `Shared::Config`.

**Context.** A machine can run pikuri-tui and pikuri-web side by side,
and both want the same model connections and the same search-provider
keys. The loader raises on an unknown top-level key.

**Decision.** {Config} reads the same layered
`~/.config/pikuri/config.toml` as the TUI and carries the **whole**
schema — `[code]`, `[[code.mcp]]` and all — even though this host wires
none of it. It names no `Pikuri` constant and logs through
`PikuriWeb.logger`, staying on the Pikuri-free side of the seam
(`D_pikuri_free_core`). Secrets (`[[llm]].api_key`, `[search]` provider
keys) come from that file and from nowhere else; `--api-key-env` was
dropped in the same change.

**Rejected: trimming the schema to the sections this host reads.** It
would make the file *reject* one the TUI wrote — the strict-key check
turns every section we don't consume into a parse error, so the
"one file, every shell" property is only bought by carrying sections we
ignore.

**Rejected: CLI flags, `ENV`, and a project-local file as secret
sources.** A flag is visible in `ps` and in shell history; `ENV` is
inherited by every subprocess pikuri spawns; a project-local file is
git-committable. There is deliberately no `--api-key` flag and there
should never be one.

## D_track_pikuri_master — Path dependencies on `../pikuri`, not released gems (2026-08-27)

**Status:** Accepted, shipped 2026-08-27; `pikuri-core` / `pikuri-pdf`
are path dependencies in the `Gemfile`.

**Context.** This shell already wanted master's surface — the boot-time
trifecta report and `Interloper#on_change`, neither of which was in a
release.

**Decision.** Track pikuri master by path. Upgrades follow pikuri's
`CHANGELOG.md`, whose `**Breaking:**` entries carry the migrations, with
pikuri-tui's HEAD as the worked example for anything ambiguous.

**Rejected: pinning released gems and waiting.** `pikuri-pdf` pins
`pikuri-core` in lockstep, so a released pdf gem refuses the next version
bump — pinning buys stability for exactly one release and then blocks.

**Rejected: bisecting pikuri-tui's git history to find a migration.**
Its history is mostly Tuile churn this project doesn't share; the
changelog is the cheaper and more accurate source.

**Consequences.** CI must clone `../pikuri` before bundling — without it
the path dependency fails the build outright.

## D_diagnostics_to_stderr — The browser shows the conversation; diagnostics stay on stderr (2026-06-06)

**Status:** Accepted, shipped 2026-06-06. This *reverses* a design that
shipped in the 2026-06-04 scaffold: `LogIO`, a Ctrl+L toggle and a
collapsible in-page log panel, all removed.

**Context.** The scaffold piped pikuri's per-subsystem loggers and
`PikuriWeb.logger` into a collapsible panel in the page, on the theory
that a browser front-end should be self-contained. In use it made the
transcript ambiguous: two unrelated streams — the LLM conversation and
the program's internal diagnostics — shared one surface, and the panel
needed its own capture machinery (`LogIO`), its own block kind, its own
keybinding and its own CSS to keep them apart.

**Decision.** The transcript shows the LLM conversation only — assistant
Markdown, reasoning, tool-call lines, tool observations, all driven by
{SseListener}. Internal diagnostics stay on their default stderr sinks
and never reach the page. Never cross the streams.

**Rejected: the in-page log panel** (as shipped). The operator running
`bin/pikuri-web-chat` already has a terminal; routing stderr through a
capture object, an SSE frame and a DOM node to arrive back in front of
the same person is machinery bought for nothing, and it is machinery that
every new block kind and every theme change then has to carry.

**Consequences.** {SseListener} renders *events*, never log lines, and
`PikuriWeb.logger` must never be pointed at the {Broadcaster}. A future
"show me what went wrong in the browser" want is a new decision, not a
resurrection of `LogIO`.

## D_worker_thread_agent_loop — The agent loop owns a worker thread; thread-safety lives in the sinks (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 as {AgentRunner}.

**Context.** The agent loop blocks on the LLM for the length of a turn.
Sinatra hands each request a pooled Puma thread.

**Decision.** {AgentRunner} owns one worker thread and the loop runs
there, never on a request thread. The listener writes into thread-safe
sinks ({Transcript}, {Broadcaster}); each `GET /events` connection parks
*its* serving thread draining one subscribed queue. There is no UI thread
and no marshaling — thread-safety is a property of the sinks, not an
obligation on their callers.

**Rejected: running the loop on the request thread that started it.** It
holds a pooled thread for the whole turn, dies with the client that
posted, and makes "one conversation, many viewers"
(`D_single_shared_conversation`) impossible to state.

**Rejected: a marshaling UI thread, the TUI's model.** A terminal has one
thread that may touch the screen, so the TUI's listener marshals onto it.
There is no such thread here — the "screen" is N browsers reached through
a queue — so importing the pattern would add a hop with nothing on the
far side of it.

**Consequences.** Parked drain threads are what makes graceful shutdown
hang; see `D_shutdown_on_state_stop`. Any new sink the listener writes to
must be thread-safe on its own, because no caller synchronizes.

## D_interloper_mid_loop_input — Mid-loop input goes through `Control::Interloper`, input stays enabled while busy (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 in {AgentRunner}; the queued-count
push was completed 2026-08-27 with `Interloper#on_change`.

**Context.** pikuri-tui deferred mid-loop input. A web page makes the
want sharper: the input field is right there while the agent is working,
and a disabled field is a worse answer in a browser than in a terminal.

**Decision.** {AgentRunner#submit} starts a turn when idle and **injects**
when busy; the injection renders through the normal listener path as
`UserTurn(mid_loop: true)`, so nothing about the display is special-cased.
The input stays enabled while busy and the status bar shows the queued
count, which is pushed by `Interloper#on_change` — so the agent's *own*
mid-loop drain updates the browser too.

**Rejected: disabling the input while the agent works.** It is the
honest-looking option and it is the one that loses work: the user types
during the one period they most want to interrupt, and the field refuses.

**Rejected: queueing submissions client-side and posting them at idle.**
That is client-only conversation state, which
`D_server_authoritative_transcript` forbids — a reload would silently eat
the queue.

**Consequences.** Interloper's delivery boundary is the caveat that
leaks: injections arrive at turn start and once each tool batch
completes, so one placed mid-response waits for that boundary. The
visible queued count exists to make that wait legible rather than to hide
it. The boundary itself is pikuri's decision, not ours — as of 0.0.7 it
moved off `after_tool_result` to tool-batch completion, and AGENTS.md's
documented caveat had to be corrected to match.

## D_pikuri_free_core — All `Pikuri::*` references live in three adapters plus the boot script (2026-06-04)

**Status:** Accepted, shipped 2026-06-04; widened from two adapters to
three on 2026-08-27, when {HistoryReplay} joined to turn a saved
`Agent::History` back into the `Agent::Event` stream. The count is not
the invariant — "translation happens at named boundaries, and nowhere
else" is — but each addition should have to argue for itself, as that
one did: the alternative was a `History → blocks` builder, which puts
block kinds in a second place (`D_rerender_and_replace`'s trifecta
would stop being one).

**Context.** This project tracks pikuri master (`D_track_pikuri_master`),
so pikuri's surface moves under it by design.

**Decision.** `Pikuri::*` appears only in `bin/pikuri-web-chat`
(boot/wiring) and in the adapters — {SseListener}, {AgentRunner} and
{HistoryReplay}. {Transcript}, {Broadcaster}, {StreamingMessage},
{MarkdownRenderer}, {ConversationStore} and {App} are Pikuri-free: they
speak ids, kinds, HTML strings, paths and queues.

**Rejected: letting Pikuri types spread to whatever needs them.** Passing
a `Pikuri::Agent::Event` into {Transcript} is the shortest path and it
prices every future pikuri upgrade at a full-project sweep. With the seam
held, a shifted surface costs rewriting two files — the same fork-or-swap
rationale as the TUI's.

**Consequences.** The adapters translate at the boundary, which
occasionally means a small unwrapping that would be unnecessary if the
event travelled whole. That cost is the decision, not an oversight.
{Config} deliberately joins the Pikuri-free side (`D_schema_complete_config`).

## D_rerender_and_replace — Re-render the whole message per delta; don't port the TUI's block-cutter (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 as {StreamingMessage}.

**Context.** pikuri-tui streams assistant output through a
`StreamingMarkdownBuffer` — a block-cutter with committed-prefix
machinery, easily the most intricate piece of the TUI's rendering. The
obvious move for a sibling front-end is to port it.

**Decision.** Don't. {StreamingMessage} accumulates the source and
re-renders **all** of it through kramdown per (rate-limited) delta; the
browser replaces one div's `innerHTML`. What *is* kept is the TUI
buffer's lifecycle contract, because that part is about correctness
rather than cost: deltas are preview-only, the bookend `finalize` carries
the authoritative content (fast-path when equal), and the object is dead
afterwards — `append` after `finalize` and a second `finalize` both
raise.

**Rejected: porting `StreamingMarkdownBuffer`.** It exists to bound
per-token `TTY::Markdown` cost on a terminal that can only append. The
browser can replace a node, and kramdown over one message is cheap — so
the port would carry the terminal's constraint into a medium that doesn't
have it, along with its bug surface.

**Rejected: coalescing deltas here.** That already lives in pikuri as
`Listener::RateLimited` (15 fps). Reimplementing it would put two rate
limiters in one path and make the effective frame rate a function of
both.

**Consequences.** Per-delta cost is O(message length), which is fine at
chat scale and would not be for a very long single message; that is the
tripwire to watch if this ever changes.

## D_server_authoritative_transcript — The server holds rendered blocks; SSE carries only deltas (2026-06-04)

**Status:** Accepted, shipped 2026-06-04 as {Transcript}.

**Context.** A browser front-end has to answer three things at once:
page reload, a second tab, and `EventSource`'s automatic reconnect.

**Decision.** {Transcript} holds the rendered HTML blocks and is the
single source of truth. `GET /` renders the full snapshot into the page;
SSE carries only deltas against it, placed by block id. All three cases
then converge on the same state with no client-side bookkeeping.

**Rejected: client-side conversation state** (accumulating the
conversation in JS from the event stream). Every one of the three cases
becomes its own problem — the reconnect needs a replay protocol, the
second tab needs a backfill, the reload needs persistence — and the three
solutions interact. Holding the blocks server-side answers all three by
not having the problem.

**Consequences.** Never introduce client-only conversation state; this is
the rule the theme cookie had to be argued *against* (`D_theme_cookie`)
rather than quietly excepted from. Blocks are stored rendered, so a
change to how a block renders does not retroactively re-render history.

## D_single_shared_conversation — One *live* agent, one transcript, loopback by default (2026-06-04)

**Status:** Accepted, shipped 2026-06-04; narrowed on 2026-08-27, when a
sidebar of stored conversations shipped. "One conversation" now means one
**live** conversation — the browser can switch which stored conversation
that is, and every tab follows, because there is still exactly one agent
and one transcript.

**Selection clause repealed and shipped 2026-08-28.** Viewing is now a
per-tab, per-URL concern (`GET /c/:id`), rows are links, and sending into
a conversation the agent is not on is what makes it live — carrying the
mid-turn refusal that `POST /conversations/:id/select`, now gone, used to
carry. A conversation the agent is not on is replayed from history per
request (`HistoryReplay.snapshot`). SSE remains one undivided feed, so
every frame is stamped with the live conversation's id and the client
drops what is not its own; per-conversation subscriptions arrive with the
agent-per-conversation work. The paragraphs below are kept for the
reasoning, not as current behaviour.

**Superseded in direction 2026-08-28, still accurate as shipped.** The
single-user, no-auth, loopback half stands and is now settled rather than
provisional: a second person runs their own process under their own OS
account. What is repealed is the **selection** clause below — that which
conversation a tab views is server state announced to every tab. It is
view state belonging to the tab, and it goes in the URL. The rejection
paragraph is where the error actually sits: it treats a per-tab *view* and
a per-user *session* as the same thing, and Slack is the refutation —
channel selection lives in its URL, the session exists only for auth. The
premise the clause reasons from ("one live agent") is itself scheduled for
replacement by one agent per conversation. Direction, staging and the
hazards it opens: `ideas/per-conversation-agents.md`. Nothing here has
changed in code yet; amend this entry, don't trust it as intent.

**Context.** A web front-end invites the assumption that it is
multi-user. This one is the TUI's single-conversation model rendered in a
browser, and its second "user" is a second tab on the same machine.

**Decision.** One agent, one transcript, in-process. No sessions, no
auth. `--bind` defaults to `127.0.0.1`; anything else is the operator's
risk and is documented as such. Selecting a conversation is therefore
*server* state, changed by a POST and announced to every tab, not a
per-URL view: one live agent showing two panes where only one accepts
input would be confusing in exactly the situation it enabled. Per-URL
`/c/<id>` is where this goes if background turns ever make the other
pane genuinely alive.

**Rejected: per-session conversations.** Not a patch — {AgentRunner} owns
*the* worker thread and {Transcript} owns *the* block list, so sessions
mean rewriting who owns what, and {Broadcaster}'s fan-out stops being a
broadcast. Out of scope until there's a concrete need.

**Rejected: shipping auth to make a non-loopback bind safe.** Auth
without per-session conversations protects an inbox everyone shares; it
would look like multi-user support while delivering none of it.

## D_no_js_build_step — One hand-written `app.js`, zero JS dependencies, render on the server (2026-06-04)

**Status:** Accepted, shipped 2026-06-04.

**Context.** The page needs an `EventSource`, form wiring, and a way to
place incoming fragments. That is the entire client-side job, because
Markdown rendering happens server-side in kramdown.

**Decision.** One hand-written `public/app.js` (~100 lines), no Node, no
bundler, no build step. The browser receives ready-made HTML fragments
over SSE and places them by block id.

**Rejected: a framework and a bundler** (or even a single npm
dependency). It would add a toolchain, a lockfile, a `node_modules` and a
build step to a project whose client-side job is a hundred lines — and
the toolchain, not the hundred lines, is what would then need
maintaining.

**Consequences.** This is a live constraint on future work, not a
starting condition: if a change appears to need an npm package, the
answer is to render it on the server instead. It is also what keeps
`--dev` cheap (`D_dev_flag_no_reload`) — there is nothing to rebuild.
