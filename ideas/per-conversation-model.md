# Per-conversation model

Switch the model without restarting the server, and have each conversation remember the one it is
on. A new conversation inherits the model of the conversation currently shown.

Status: **backend-only work, with a designed shape and seven open questions.** The UI question is
closed (the slash palette shipped), the library half is done, and nothing is blocked on upstream.
What is unsettled is where the selection lives on disk, when it is written, and how loud the edge
cases are. Read *Open questions* before trusting anything that reads as decided elsewhere in this
file — the leans there are leans, not conclusions.

## What is settled

- The selection is **per conversation and persists**; a new conversation copies the shown one's.
- **No agent, runner or transcript is ever rebuilt** — only the transport moves.
- **No synthetic bare turn to force a switch early.** A selection made while idle sits until the
  next real turn. Firing `run_loop(user_message: nil, transport: …)` to apply it sooner buys a
  display update at the cost of a round-trip, and raises `EmptyTurnError` against a prompt-only
  conversation on a separate-system-field provider.
- **The UI is one catalog entry, one template, one arm.** `/model` is a
  `PikuriWeb::SlashCommand::CATALOG` entry, a `<template>` in `index.erb`, and an arm in `app.js`'s
  `runCommand` (`D_slash_command_palette`). `/theme`'s dialog is already a `.picker` list with
  `aria-current` marking the active row — exactly this shape — and `dom.js`'s `openDialog` opens
  it. Gate the catalog entry on `config.llms.size > 1`, as pikuri-tui gates its own.
- **The current-model marker is computed when the dialog opens, not server-rendered.** `/theme` had
  the same problem for the same reason (the value changes in-page after the render). So the dialog
  is a static `<template>` and needs nothing from the `status` SSE frame — see
  `Q_status_carries_model` for whether the *status bar* wants the model anyway.

## Where it stands today

- `bin/pikuri-web-chat:96` takes `config.primary_llm` (`llms.first`) into a local `llm`, and the
  conversation factory closes over it: every agent gets the same
  `ChatTransport.from_openai_server(server:, model:, api_key:, context_window:)`
  (`bin/pikuri-web-chat:181`). The only knobs are `--server` / `--model` at launch
  (`Config.apply_llm_overrides`) or the first `[[llm]]` in the config file.
- `Config` already parses *every* `[[llm]]` and validates it — unique `name`, per-connection
  `server` / `model` / `api_key` / `context_window` — and exposes them as `Config#llms`. Nothing
  reads past `primary_llm`. Both rdocs say so on purpose: "the rest await a model picker this shell
  lacks" (`config.rb:62`), and `SseListener`'s `else` branch, "ModelSwitched: unreachable — this
  shell has no model picker" (`sse_listener.rb:137`).
- `ConversationStore` is constructed once with `model:` (`conversation_store.rb:109`) and stamps
  that one string into every `meta.json` (`:248`). So the field exists, is already written, and is
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

**There is no "apply it now" call, and that is deliberate.** `apply_transport!` is private (below
`agent.rb:578`); `Agent#transport` is a read-only reader. The only public way in is `run_loop`'s
`transport:` kwarg, because — its own rdoc, `agent.rb:310` — the chat is single-thread-confined and
"a background thread mutating the connection mid-completion would tear an in-flight stream". The
library can't know nothing is in flight; our `AgentRunner` state machine can. That makes the
pending-slot design **forced rather than chosen**.

pikuri-tui is the worked example, and it is small: `Shared::Model::Picker` (`model/picker.rb`) is a
catalog plus a *pending transport* slot; `Shared::AgentSession#start_turn`
(`agent_session.rb:188`) calls `take_pending` and hands the result to `run_loop`;
`Shared::StatusFooterUpdater` moves the displayed name only once `ModelSwitched` lands, so a failed
switch never advertises a model it never reached. Copy that authority split — pikuri owns "what
model am I on", we own "what did the user ask for".

## Identity: `[model, api_base]`, not `model`

Two `[[llm]]` entries can name the same model on different servers (the TUI's own example: local
vs. remote Qwen). `Shared::Model::Choice.key` keys on the `[model, api_base]` pair for exactly this
reason, because `name` is the truly unique key but is *not* recoverable from a transport — a landed
`ModelSwitched` carries transports, not names.

Consequences here:

- `meta.json` should record the pair (add a `server`, keep `model`), not just `model`. Storing the
  `name` alone would break the moment someone renames a connection in the config file.
- No `SCHEMA` bump needed to add a key: `load_meta` only checks `meta['schema'] == SCHEMA`
  (`conversation_store.rb:292`) and ignores what it doesn't read.
- Reopening a conversation whose saved connection is gone from `config.toml` needs an answer —
  `Q_missing_connection`.

## Where the state lives

Four candidate homes, and they are not interchangeable:

- **`ConversationStore#initialize(model:)` has to go.** It is a store-wide field feeding
  `write_meta`. Either `#save` takes the model (it already owns the whole commit —
  `D_no_store_lock` — so widening its signature is in keeping), or the model rides on the
  `Conversation` Data. `Q_mint_vs_pending` is the fork that decides which.
- **`Conversation` is a `Data.define(:id, :dir, :title, :created_at, :supported)`** and
  `AgentRunner#conversation` is documented as fixed for the runner's lifetime. Putting a *mutable*
  selection on an immutable value object means every switch replaces the runner's `@conversation`
  via `#with` — workable, but it turns a "this runner is for that conversation, permanently" rdoc
  into something weaker. A *mint-time* field is a different and milder proposition — that is what
  `Q_mint_vs_pending` proposes and `Q_conversation_model_staleness` prices.
- **`AgentRunner` holds the pending selection**, drained and passed to `run_loop(transport:)`. It
  already has the mutex and the `:idle/:queued/:running` state machine to hang this on. Note there
  are **two** paths into `run_loop` and both must drain: `run_turn` (`agent_runner.rb:266`) and the
  restart `finish_turn` (`:296`) claims when a completed turn leaves the Interloper queue
  non-empty — miss the second and a restart turn silently runs the old model. Selecting while busy
  is naturally "next turn", which matches the Interloper's existing "your input waits for a
  boundary" story; the status bar already exists to make that wait legible. `#discard!` (`:189`)
  must refuse a selection the same way it refuses a submit.
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

`POST /conversations` (`app.rb:145`) calls `registry.create` (`conversation_registry.rb:68`,
`= open(@store.create)`) and knows nothing about which conversation the tab is looking at. Three
things need to happen:

- The route needs the viewing id. `app.js:139` posts with no body, but the pattern already exists
  next door — `refreshSidebar` sends `?viewing=…` (`app.js:69`), and `POST /messages` /
  `POST /cancel` both carry `conversation`.
- `registry.create` needs to pass an initial model down into the factory, which currently takes
  `conversation` alone — or, under `Q_mint_vs_pending`, stamp the pair at `store.create` and let
  the factory read it off the `Conversation`.
- The fallback when nothing is shown, or the shown conversation's connection is gone from the
  config, is `primary_llm`. `registry.default` (`:128`) — the conversation a fresh visitor lands
  on, also what the boot trifecta report opens — goes down that path.

## Knock-on changes

Plain work, no fork in it:

- **`SseListener`'s `else` branch** (`sse_listener.rb:137`) stops being unreachable, and its rdoc
  stops being true. What it *draws* is `Q_switch_marker`.
- **The boot banner** (`bin/pikuri-web-chat:296`, "agent: model @ server") becomes the *default*
  model, not the model.
- **`--model` / `--server`** keep meaning "override the primary connection", which is now also
  "the default for a conversation that has no saved one". `README.md`'s config section needs the
  distinction; `D_schema_complete_config` is untouched — no new keys, the `[[llm]]` array is
  already the schema. Whether saved outranks the override is `Q_saved_vs_cli_override`.
- **`restore!`** (`agent_runner.rb:124`) replays history but sets no transport, so under the
  pending-slot branch a reopened conversation boots on the factory's model. That is the substance
  of `Q_mint_vs_pending`.

## Open questions

None of these are settled. Each names what was checked, so the next session argues rather than
re-greps. Leans are marked as leans.

### `Q_mint_vs_pending` — should a reopened conversation be *minted* on its saved transport?

The pending-slot design mints every agent on the factory's model and seeds the saved one into the
pending slot, where it lands on the first turn. The alternative: put the saved pair on the
`Conversation` Data as *envelope* state (like `title` — a mint-time fact, not the
mutable-selection-on-an-immutable-object problem *Where the state lives* rightly rejects), let the
factory resolve it, and narrow the pending slot to a switch on a *live* runner. Then the factory
signature never changes, `registry.create(from:)` covers inheritance by stamping the pair at
`store.create`, and `ConversationStore#initialize(model:)` goes away rather than moving.

**This question used to have a second, stronger argument, and it has been retracted.** The claim
was that minting on the wrong model *degrades history*: `Agent#load_history!` (`agent.rb:503`)
reads `current_model = @chat.model&.id` and drops thinking signatures whose message `model_id`
doesn't match, so a reopen-then-switch would strip signatures on the way in. Investigation in
`../pikuri/ideas/thinking-block-replay.md` (measured, 2026-08-29) found the premise underneath that
repair is false — a stale signature replayed after a switch is *silently ignored*, per Anthropic's
own docs, not a 400; stripping one is closer to the shape that actually is a 400 — and that the
repair is unreachable on the Anthropic wire anyway, because pikuri never enables thinking. Against
llama.cpp there is no signature to strip in the first place. So there is no measured degradation
here, and none is evidenced on any backend we point at. **Do not re-derive the 400 argument** — it
is a plausible-and-wrong that has now cost two sessions.

**Lean: still yes**, on the reasons that survive — the factory signature stays put,
`registry.create(from:)` falls out naturally, `ConversationStore#initialize(model:)` is deleted
rather than relocated, and nothing displays a model the agent is not actually on. Open: whether
those are worth one extra `Conversation` field, given the edge `Q_conversation_model_staleness`
prices.

### `Q_persist_when` — pick time or turn end?

`#save` runs from `finish_turn`, under the runner's mutex, on the executor thread; a pick arrives
on a request thread. A pick-time save therefore either exports history mid-`complete` (what the
turn-end rule exists to prevent), or writes `meta.json` beside `#save` — which `D_no_store_lock`
forbids in as many words ("nothing writes beside it"). And for a conversation with no turn yet it
writes the *commit point* with no `history.json` under it: a listed conversation that cannot be
opened, the exact failure both `#save`'s and `#delete`'s orderings were chosen to prevent.

If instead the field is written at turn end **from the agent's own transport** rather than from the
selection, `meta.json` always names the model that produced the last message — which is what
`load_history!` keys its signature scrub on, so `meta.json` and `history.json`'s `model_id` agree by
construction.

**Lean: turn end.** Open: the accepted cost is that a pick with no message after it is lost across
a restart. Is that actually fine, or does a quiet pick deserve to survive? (If it does, this needs a
mechanism nobody has designed yet — not just the other branch.)

### `Q_switch_marker` — does a switch earn a transcript block?

`D_slash_command_palette`'s rule is that a command's effect is its own feedback, because a block
absent from `history.json` vanishes on reopen. That reason does **not** obviously reach a model
switch: `Pikuri::Agent::History::Message` carries `model_id` (`history.rb:140`, persisted), so
`HistoryReplay` could derive a switch boundary from a change between consecutive assistant
messages — and it would replay.

So this is a live fork. For: it is the only durable record of why the conversation's voice changed
halfway down, and `:notice` already exists (`FallbackNotice` sets the "! something happened"
precedent), so no new block kind. Against: two producers of one block — the live `ModelSwitched`
arm and the replay-derived one — and if they disagree, a reload silently rewrites the transcript.

**No lean.** The interesting question is not whether to show it but whether one derivation can serve
both paths.

### `Q_status_carries_model` — does the model belong on the `status` frame?

The dialog needs nothing from SSE (its marker is computed on open, `/theme`-style). Still open is
whether the **status bar** should show the current model at all. If it should, it rides
`status_data` (`agent_runner.rb:233`), which today carries `state/busy/pending/tokens` and no
model — and `tokens` already moves for the same reason a switch does (`ContextCap` re-emits).

Shape if so: `model:` (landed, repointed off `ModelSwitched` and never off the selection, per the
TUI's footer rule) plus `model_pending:` (non-nil only until a live pick lands). Note what the
second field *is* — the pending model is the Interloper of models, the same "your pick waits for a
boundary" story the queued count already tells. Under `Q_mint_vs_pending`'s lean a reopen never
sets it, so the common case shows one unambiguous name.

**No lean on whether the status bar wants this at all.** It may be clutter for a single-`[[llm]]`
user, who is most users.

### `Q_cap_after_switch` — what happens to a conversation switched onto a smaller window?

`apply_transport!` ends in `detect_and_emit_context_cap!` (`agent.rb:694`), which re-emits
`Event::ContextCap`; `TokenLog` consumes it and `status_data[:tokens]` is its preformatted line. So
the token readout self-corrects on a switch for free — nice, and worth not breaking.

The flip side: nothing re-baselines the history. 90k of conversation switched onto a 32k connection
is over cap immediately, and the next turn fails.

**Lean: accept it** — the readout says so and the user did it deliberately — but that is an argument
for the dialog listing each connection's `context_window` beside its name, so the pick is informed
rather than discovered. Open: is a legible failure good enough, or should the dialog refuse / warn
on a pick that cannot hold the current conversation?

### `Q_missing_connection` — how loud is a saved connection that is gone from the config?

Falling back to `primary_llm` is the cheap answer and probably right. Where it gets *said* is the
question: not the transcript (a block absent from `history.json` — the same trap as
`Q_switch_marker`, minus that question's escape hatch, since nothing on disk records the fallback),
and not `supported: false` (that flag means "unreadable envelope"; overloading it would be wrong).

**Lean: say it in the dialog** — "qwen-remote — not in config, using llama-local" — and nowhere
else. Open: is a silent fallback actually fine, given the identity is the `[model, server]` pair, so
a config edit that only renames a connection is invisible by design?

### `Q_saved_vs_cli_override` — does a saved model outrank `--model` / `--server`?

Someone who boots `--model Z` to try Z, then opens an old conversation, silently gets that
conversation's saved model instead. Which is the feature working as designed, and also a surprise.

**Lean: saved wins on reopen; the override is the default for *new* conversations** — one README
sentence. Open: whether `--model` should instead mean "this run, everything", which is what it means
today and what a user who has never seen the picker will assume.

### `Q_conversation_model_staleness` — what does `Conversation.model` mean after a live switch?

Only bites if `Q_mint_vs_pending` lands. `AgentRunner#conversation` is fixed for the runner's
lifetime, so after a live switch `runner.conversation.model` is stale. Workable rule:
`Conversation.model` means "what disk said at mint" and the runner is the authority for "current",
so anything asking for current — `registry.create(from:)` especially — asks the runner.

**Lean: that rule, unwritten cost noted** — the sidebar must never render the model off a
`Conversation`, or a resident switched conversation lists the wrong one. Open: is a Data field that
is *only* correct at mint time too sharp an edge to leave lying around?

## The upstream question, answered: not blocked

`../pikuri/ideas/thinking-block-replay.md` is an open pikuri note about `load_history!`'s thinking-
signature repair, found while designing this picker. **It does not gate this work**, and the reasons
are worth recording so nobody re-opens the coupling:

- **The surface we build against is untouched by every likely fix.** We consume
  `run_loop(transport:)`, `Event::ModelSwitched` and the `Agent::History` round-trip. Five of the
  six options in that note (fix the false premise, repair the whole block instead of the signature,
  move the repair to request-build time, fix ruby_llm upstream, do nothing) change what pikuri puts
  on the wire, not what we hand it or read back. The one that would reach us — `api_base` per
  message, a `History` schema change — is the option that note itself demotes as the most expensive
  resting on the weakest evidence. If it ever lands it arrives as a `**Breaking:**` CHANGELOG entry
  with migration instructions, which is the upgrade path `D_track_pikuri_master` already describes.
- **The repair is a measured no-op on our documented target.** It has exactly one live consumer:
  OpenAI-compatible servers that populate `reasoning_signature`. llama.cpp does not. On the
  Anthropic path nothing is emitted at all, because pikuri never calls `with_thinking` and both
  serialization paths gate on it.
- **The one place it does reach us** is that `[[llm]]` is provider-generic, so an OpenRouter /
  DeepSeek / vLLM entry *is* that live consumer — and that is precisely the user who has more than
  one connection, i.e. the one this picker is for. But it is reachable today with a single
  connection too (boot `--model Z`, reopen an old conversation, same load-time scrub). A picker
  makes it routine, not new.

Nothing to re-argue here; if the behaviour changes, it changes under us and the CHANGELOG says how.

## Where the nuggets go at graduation

- The shape chosen for the pending slot and the state's home, plus the branches rejected in
  `Q_mint_vs_pending` / `Q_persist_when` → a `DECISIONS.md` entry with a flat invariant + `See
  D_<slug>` in **Scope decisions**. The retracted 400 argument belongs in its *Alternatives
  rejected*: it is exactly the kind of plausible-and-wrong a future reader would re-derive.
- `meta.json` gaining a `server` key, and `#save` owning the model → `ConversationStore`'s rdoc.
- The pending slot's lifecycle and the two drain points → `AgentRunner`'s rdoc.
- The catalog-as-constructor-argument seam → the **Layout** line for `bin/pikuri-web-chat`, and a
  sentence in the `D_pikuri_free_core` invariant if the wording no longer covers it.
- `--model` as "default for new conversations", and the picker itself → `README.md`.
- Anything about the library's repair → `../pikuri`, never here.
