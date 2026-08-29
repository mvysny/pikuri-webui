# Per-conversation model

Switch the model without restarting the server, and have each conversation remember the one it is
on. A new conversation inherits the model of the conversation currently shown.

**The UI is deliberately unsettled** — where the control lives (sidebar row, status bar, a
`/model` line in the input, something else) is an open question, and nothing below assumes an
answer. What is decided: the *selection is per conversation and persists*; a new conversation
copies the shown one's.

**Update (2026-08-29): the UI question is closed, and this is now backend-only work.** The slash
palette shipped (`D_slash_command_palette`), so `/model` is one `PikuriWeb::SlashCommand::CATALOG`
entry, one `<template>` in `index.erb`, and one arm in `app.js`'s `runCommand`. The picker markup
already exists — `/theme`'s dialog is a `.picker` list with `aria-current` marking the active row,
which is exactly the shape this wants, and `dom.js`'s `openDialog` opens it. Add the catalog entry
gated on `config.llms.size > 1`, as pikuri-tui gates its own.

Two things the palette settled that this file's "Loose ends" left open:

- **The current-model marker is computed when the dialog opens, not server-rendered.** `/theme`
  had the same problem for the same reason (the value changes in-page after the render) and that is
  how it was solved. So the model dialog can be a static `<template>` and does *not* need the
  `status` SSE frame to carry the model — though it still may, if the model is to be visible in the
  status bar without opening anything.
- **A switch must not draw a transcript block.** `D_slash_command_palette` settles it: a command's
  effect is its own feedback, and a block that is not in `history.json` would vanish on the next
  reopen. `SseListener`'s `ModelSwitched` branch stops being unreachable, but what it does is
  bounded by that. **But see `Q_switch_marker`** — the second half of that reason may not hold
  here, because `history.json` records the model per message.

**Update (2026-08-29, later): a brainstorming pass turned up questions that change the shape of
the backend work, plus a library bug underneath it.** They are gathered under *Open questions* at
the bottom, deliberately unsettled. Several contest lines above and below that read as settled;
those lines are annotated with the slug rather than rewritten. Read the questions before trusting
a nearby "settled".

## Where it stands today

- `bin/pikuri-web-chat:96` takes `config.primary_llm` (`llms.first`) into a local `llm`, and the
  conversation factory closes over it: every agent gets the same
  `ChatTransport.from_openai_server(server:, model:, api_key:, context_window:)`
  (`bin/pikuri-web-chat:180`). The only knobs are `--server` / `--model` at launch
  (`Config.apply_llm_overrides`) or the first `[[llm]]` in the config file.
- `Config` already parses *every* `[[llm]]` and validates it — unique `name`, per-connection
  `server` / `model` / `api_key` / `context_window` — and exposes them as `Config#llms`. Nothing
  reads past `primary_llm`. Both rdocs say so on purpose: "the rest await a model picker this
  shell lacks" (`config.rb:61`), and `SseListener`'s `else` branch,
  "ModelSwitched: unreachable — this shell has no model picker" (`sse_listener.rb:137`).
- `ConversationStore` is constructed once with `model: llm.model` and stamps that one string into
  every `meta.json` (`conversation_store.rb:248`). So the field exists, is already written, and is
  currently a lie waiting to happen: it records the boot model, not the conversation's.

So this is unwired, not unsupported.

## The library half is done — and the agent is never rebuilt

`Pikuri::Agent#run_loop(user_message:, transport:)` — `pikuri-core/lib/pikuri/agent.rb:353` — takes
a transport and calls `apply_transport!` at the top of the turn (`:726`): it no-ops when the
transport is structurally equal (Data equality over the whole transport, `api_key` and
`context_window` included, after a nil-model fill), otherwise installs a fresh `RubyLLM::Context`
when either side has `connection_overrides?` (the cross-server case), calls `Chat#with_model`,
emits `Event::ModelSwitched(from:, to:)` and re-resolves the cap against the *new* `api_base`.
`with_context` / `with_model` both preserve history **and** callbacks, so the same agent keeps its
listener stack, tools, `Cancellable` and `Interloper` across a switch. The conversation is not
re-baselined either: message count and running context size carry over.

**So nothing is reconstructed — not the agent, not the runner, not the transcript.** Only the
transport moves.

**There is no "apply it now" call, and that is deliberate.** `apply_transport!` is private
(below `agent.rb:578`); `Agent#transport` is a read-only reader. The only public way in is
`run_loop`'s `transport:` kwarg, because — its own rdoc, `agent.rb:310` — the chat is
single-thread-confined and "a background thread mutating the connection mid-completion would tear
an in-flight stream". The library can't know nothing is in flight; our `AgentRunner` state machine
can. That makes the pending-slot design **forced rather than chosen**.

**Settled: no synthetic bare turn to force the switch early.** A selection made while idle simply
sits until the next real turn. Firing `run_loop(user_message: nil, transport: …)` to apply it
sooner buys a display update at the cost of a round-trip, and raises `EmptyTurnError` against a
prompt-only conversation on a separate-system-field provider.

pikuri-tui is the worked example, and it is small: `Shared::Model::Picker` is a catalog plus a
*pending transport* slot; `Shared::AgentSession#start_turn` calls `take_pending` and hands the
result to `run_loop`; `Shared::StatusFooterUpdater` moves the displayed name only once
`ModelSwitched` lands, so a failed switch never advertises a model it never reached. Copy that
authority split — pikuri owns "what model am I on", we own "what did the user ask for".

## Identity: `[model, api_base]`, not `model`

Two `[[llm]]` entries can name the same model on different servers (the TUI's own example: local
vs. remote Qwen). `Shared::Model::Choice.key` keys on the `[model, api_base]` pair for exactly this
reason, because `name` is the truly unique key but is *not* recoverable from a transport — a landed
`ModelSwitched` carries transports, not names.

Consequences here:

- `meta.json` should record the pair (add a `server`, keep `model`), not just `model`. Storing the
  `name` alone would break the moment someone renames a connection in the config file.
- Reopening a conversation whose saved connection is no longer in `config.toml` needs an answer.
  Falling back to `primary_llm` and saying nothing is the cheap one; the sidebar's existing
  `supported: false` treatment is the precedent for the loud one, but that flag currently means
  "unreadable envelope" and overloading it would be wrong.
- No `SCHEMA` bump needed to add a key: `load_meta` only checks `meta['schema'] == SCHEMA`
  (`conversation_store.rb:292`) and ignores what it doesn't read.

## Where the state lives

Four candidate homes, and they are not interchangeable:

- **`ConversationStore#initialize(model:)` has to go.** It is a store-wide field feeding
  `write_meta`. Either `#save` takes the model (it already owns the whole commit —
  `D_no_store_lock` — so widening its signature is in keeping), or the model rides on the
  `Conversation` Data.
- **`Conversation` is a `Data.define(:id, :dir, :title, :created_at, :supported)`** and
  `AgentRunner#conversation` is documented as fixed for the runner's lifetime. Putting a *mutable*
  selection on an immutable value object means every switch replaces the runner's `@conversation`
  via `#with` — workable, but it turns a "this runner is for that conversation, permanently" rdoc
  into something weaker. Prefer: the model is `AgentRunner` state, and `#save` is told what it is.
  `#row` still reads it back out of `meta.json` for the listing.
- **`AgentRunner` holds the pending selection**, drained and passed to `run_loop(transport:)`. It
  already has the mutex and the `:idle/:queued/:running` state machine to hang this on. Note there
  are **two** paths into `run_loop` and both must drain: `run_turn` (`agent_runner.rb:265`) and the
  restart `finish_turn` claims when a completed turn leaves the Interloper queue non-empty — miss
  the second and a restart turn silently runs the old model. Selecting while busy is naturally
  "next turn", which matches the Interloper's
  existing "your input waits for a boundary" story — the status bar already exists to make that
  wait legible. `#discard!` must refuse a selection the same way it refuses a submit.
- **`ConversationRegistry` must not learn about models beyond an opaque id.** It is Pikuri-free by
  `D_pikuri_free_core`, as are `App` and `Config`.

## The seam

A `ChatTransport` must not reach `App` or `ConversationRegistry`. So the browser-facing side speaks
a connection *name* (or the `[model, server]` pair) as a string, and the resolution
name → `ChatTransport` happens server-side of the seam — in the conversation factory in
`bin/pikuri-web-chat`, which is where `Config::Llm` is already turned into a transport. Concretely:
the factory hands each `AgentRunner` a catalog (name → transport, or a resolver lambda) built once
from `config.llms`, and `App` posts a name to the runner. `Config` stays Pikuri-free because it
never builds a transport itself — it hands out `Llm` value objects, as it does now.

That also keeps the trifecta report honest: one factory, one tool set, and the catalog is a
constructor argument rather than a second wiring.

## Inheriting on "new conversation"

`POST /conversations` (`app.rb:140`) calls `registry.create` and knows nothing about which
conversation the tab is looking at. Three things need to happen:

- The route needs the viewing id. `app.js:135` posts with no body, but the pattern already exists
  next door — `refreshSidebar` sends `?viewing=…` (`app.js:64`), and `POST /messages` /
  `POST /cancel` both carry `conversation`.
- `registry.create` (`= open(@store.create)`) needs to pass an initial model down into the factory,
  which currently takes `conversation` alone.
- The fallback when nothing is shown, or the shown conversation's connection is gone from the
  config, is `primary_llm`. `registry.default` — the conversation a fresh visitor lands on, also
  what the boot trifecta report opens — goes down that path.

## Loose ends

- **`status_data`** (`agent_runner.rb:233`) carries `state/busy/pending/tokens` and no model. If
  the current model is to be visible anywhere live, it goes here, and it must be repointed off a
  landed `ModelSwitched` — not off the selection — per the TUI's footer rule.
  See `Q_status_carries_model`.
- **`SseListener`'s `else` branch** stops being unreachable. Whether a switch draws a `:notice`
  block in the transcript is a real question (it *is* conversation history, unlike a log line —
  `D_diagnostics_to_stderr` doesn't settle it) and touches the block-kind contract if it wants its
  own kind. See `Q_switch_marker`.
- **`restore!`** replays history but sets no transport. A reopened conversation boots on the
  factory's model, so the saved one is seeded into the pending slot at mint time and lands on the
  first turn — which is fine for the turn, and a lie for anything displaying the model before it.
  **"Fine for the turn" is contested** — see `Q_mint_vs_pending`.
- **Selection outruns reality while quiet.** Between a pick and the next turn the agent is still on
  the old model. If the selection is persisted at pick time, `meta.json` records *intent* ahead of
  what the conversation last actually talked to; persisting at turn end instead loses a pick the
  user never sent a message after. Neither is obviously right — pick one deliberately.
  `Q_persist_when` argues this may not be a taste call at all.
- **The boot banner** (`bin/pikuri-web-chat:296`, "agent: model @ server") becomes the *default*
  model, not the model.
- **`--model` / `--server`** keep meaning "override the primary connection", which is now also
  "the default for a conversation that has no saved one". `README.md`'s config section needs the
  distinction; `D_schema_complete_config` is untouched — no new keys, the `[[llm]]` array is
  already the schema. See `Q_saved_vs_cli_override`.

## Open questions (2026-08-29 brainstorm — none of these are settled)

Raised in one pass and left open on purpose. Each names what was checked, so the next session
argues rather than re-greps. Leans are marked as leans.

### `Q_mint_vs_pending` — should a reopened conversation be *minted* on its saved transport?

The plan above mints every agent on the factory's model and seeds the saved one into the pending
slot. `Pikuri::Agent#load_history!` (`pikuri-core/lib/pikuri/agent.rb:503`) reads
`current_model = @chat.model&.id` and **drops thinking signatures whose message `model_id` doesn't
match**. So minting on the wrong model and switching on the first turn means a reopened
conversation is loaded against the wrong model and its signatures are stripped on the way in —
history degradation before the first turn, not just a display lie.

The alternative: put the saved pair on the `Conversation` Data (envelope state, like `title` — not
the mutable-selection-on-an-immutable-object problem *Where the state lives* rightly rejects), let
the factory resolve it, and narrow the pending slot to a switch on a *live* runner. Then the
factory signature never changes, `registry.create(from:)` covers inheritance by stamping the pair
at `store.create`, and `ConversationStore#initialize(model:)` goes away rather than moving.

**Lean: yes.** Open: whether the degradation is real against llama.cpp (it emits no signatures, so
this may be entirely latent here — see `Q_pikuri_signature_repair`), and whether the two minting
paths are worth one extra `Conversation` field.

### `Q_persist_when` — pick time or turn end?

*Loose ends* calls this a coin flip. It may not be. `#save` runs from `finish_turn`, under the
runner's mutex, on the executor thread; a pick arrives on a request thread. A pick-time save
therefore either exports history mid-`complete` (what the turn-end rule exists to prevent), or
writes `meta.json` beside `#save` — which `D_no_store_lock` forbids in as many words ("nothing
writes beside it"). And for a conversation with no turn yet it writes the *commit point* with no
`history.json` under it: a listed conversation that cannot be opened, the exact failure both
`#save`'s and `#delete`'s orderings were chosen to prevent.

If instead the field is written at turn end **from the agent's own transport** rather than from the
selection, `meta.json` always names the model that produced the last message — which is what
`load_history!` keys its signature scrub on, so `meta.json` and `history.json`'s `model_id` agree
by construction.

**Lean: turn end.** Open: the accepted cost is that a pick with no message after it is lost across
a restart. Is that actually fine, or does a quiet pick deserve to survive? (If it does, this needs
a mechanism nobody has designed yet — not just the other branch.)

### `Q_switch_marker` — does a switch earn a transcript block after all?

The palette's rule is that a command's effect is its own feedback, because a block absent from
`history.json` vanishes on reopen. That reason does **not** obviously reach a model switch:
`Pikuri::Agent::History::Message` carries `model_id` (`history.rb:140`, persisted), so
`HistoryReplay` could derive a switch boundary from a change between consecutive assistant messages
— and it would replay.

So this is a live fork, not a closed one. For: it is the only durable record of why the
conversation's voice changed halfway down, and `:notice` already exists (`FallbackNotice` sets the
"! something happened" precedent), so no new block kind. Against: two producers of one block — the
live `ModelSwitched` arm and the replay-derived one — and if they disagree, a reload silently
rewrites the transcript.

**No lean.** The interesting question is not whether to show it but whether one derivation can
serve both paths.

### `Q_status_carries_model` — does the model belong on the `status` frame?

Partly answered above: the *dialog's* marker is computed on open, `/theme`-style, so the dialog
needs nothing from SSE. Still open is whether the **status bar** should show the current model at
all. If it should, it rides `status_data` — which already carries `tokens`, and that field moves
for the same reason (a switch re-emits `ContextCap`).

Shape if so: `model:` (landed) plus `model_pending:` (non-nil only until a live pick lands). Note
what the second field *is* — the pending model is the Interloper of models, the same "your pick
waits for a boundary" story the queued count already tells. Under `Q_mint_vs_pending`'s answer a
reopen never sets it, so the common case shows one unambiguous name.

**No lean on whether the status bar wants this at all.** It may be clutter for a single-`[[llm]]`
user, who is most users.

### `Q_cap_after_switch` — what happens to a conversation switched onto a smaller window?

`apply_transport!` ends in `detect_and_emit_context_cap!`, which re-emits `Event::ContextCap`;
`TokenLog` consumes it and `status_data[:tokens]` is its preformatted line. So the token readout
self-corrects on a switch for free — nice, and worth not breaking.

The flip side: nothing re-baselines the history. 90k of conversation switched onto a 32k connection
is over cap immediately, and the next turn fails.

**Lean: accept it** — the readout says so and the user did it deliberately — but that is an
argument for the dialog listing each connection's `context_window` beside its name, so the pick is
informed rather than discovered. Open: is a legible failure good enough, or should the dialog
refuse / warn on a pick that cannot hold the current conversation?

### `Q_missing_connection` — how loud is a saved connection that is gone from the config?

Falling back to `primary_llm` is the cheap answer and probably right. Where it gets *said* is the
question: not the transcript (a block absent from `history.json` — the same trap as
`Q_switch_marker`, minus that question's escape hatch, since nothing on disk records the
fallback), and not `supported: false` (that flag means "unreadable envelope"; overloading it
would be wrong).

**Lean: say it in the dialog** — "qwen-remote — not in config, using llama-local" — and nowhere
else. Open: is a silent fallback actually fine, given the identity is the `[model, server]` pair,
so a config edit that only renames a connection is invisible by design?

### `Q_saved_vs_cli_override` — does a saved model outrank `--model` / `--server`?

Someone who boots `--model Z` to try Z, then opens an old conversation, silently gets that
conversation's saved model instead. Which is the feature working as designed, and also a surprise.

**Lean: saved wins on reopen; the override is the default for *new* conversations** — one
README sentence. Open: whether `--model` should instead mean "this run, everything", which is
what it means today and what a user who has never seen the picker will assume.

### `Q_conversation_model_staleness` — what does `Conversation.model` mean after a live switch?

Only bites if `Q_mint_vs_pending` lands. `AgentRunner#conversation` is fixed for the runner's
lifetime, so after a live switch `runner.conversation.model` is stale. Workable rule:
`Conversation.model` means "what disk said at mint" and the runner is the authority for "current",
so anything asking for current — `registry.create(from:)` especially — asks the runner.

**Lean: that rule, unwritten cost noted** — the sidebar must never render the model off a
`Conversation`, or a resident switched conversation lists the wrong one. Open: is a Data field
that is *only* correct at mint time too sharp an edge to leave lying around?

### `Q_pikuri_signature_repair` — a library bug this sits on top of

Underneath `Q_mint_vs_pending`: `load_history!`'s repair keeps the thinking *text* and drops only
the signature, which is not a wire shape Anthropic accepts — and the scrub runs only at load, so a
mid-session switch (which is exactly what this feature adds) replays old signatures untouched.
Investigated and filed as **`../pikuri/ideas/thinking-block-replay.md`**; do not re-argue it here.

For this shell it is latent: `from_openai_server` against llama.cpp yields no signature, so
keep-vs-drop is a no-op and nothing here is blocked. What is open is only whether pikuri-web should
wait for the library fix before shipping a picker that makes mid-session switches routine, or ship
and let llama.cpp's silence cover it.
