# Per-conversation model

Switch the model without restarting the server, and have each conversation remember the one it is
on. A new conversation inherits the model of the conversation currently shown.

Status: **backend-only work, with a designed shape and four open questions.** The UI question is
closed (the slash palette shipped), the library half is done, nothing is blocked on upstream, and
the two questions that gated the implementation shape — where the selection lives and when it is
written — are settled below. What is left open is how loud the edge cases are. The leans under
*Open questions* are leans, not conclusions.

## What is settled

- The selection is **per conversation and persists**; a new conversation copies the shown one's.
- **The pair lives in `meta.json`, and is not derived from `history.json`.** pikuri already records
  `model_id` per message (`history.rb:140`), but that is a model *string*: it cannot express the
  `[model, api_base]` identity below, `#row` would have to parse every stored history to render one
  sidebar (`conversation_store.rb:258` reads the envelope and nothing else), and a conversation
  that inherited a model but has not spoken yet has no `model_id` anywhere.
- **Written at turn end, from the agent's own transport** — not at pick time, and not from the
  selection.
- **A reopened conversation is *minted* on its saved transport**, and the pending slot is only ever
  a switch on a *live* runner. See *Where the state lives*.
- **Three readers, each true of one moment.** `Conversation#model_at_mint` (what disk said when the
  runner was minted; the factory is its only reader), `AgentRunner#model` (intent — what the next
  turn will use), and `@agent.transport` (reality — what the agent is on, read only by `#save`).
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
  (`bin/pikuri-web-chat:181`). The only knob is the first `[[llm]]` in the config file — the
  `--server` / `--model` flags were removed on 2026-08-29.
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

Settled: **the pair is envelope state on the `Conversation`, the factory resolves it at mint, and
the pending slot handles only live switches.** Two mechanisms, each meaning one thing.

- **`ConversationStore#initialize(model:)` goes away** (`conversation_store.rb:109`). It is a
  store-wide field feeding `write_meta`; `#save` takes the model instead, which is in keeping with
  its already owning the whole commit (`D_no_store_lock`). This follows from the turn-end rule
  alone — it was never contingent on how the agent gets minted.
- **Why turn-end, from the transport.** `#save` runs from `finish_turn`, under the runner's mutex,
  on the executor thread; a pick arrives on a request thread. A pick-time save therefore either
  exports history mid-`complete` (what the turn-end rule exists to prevent) or writes `meta.json`
  beside `#save` — which `D_no_store_lock` forbids in as many words ("nothing writes beside it").
  And for a conversation with no turn yet it writes the *commit point* with no `history.json`
  under it: a listed conversation that cannot be opened, the exact failure both `#save`'s and
  `#delete`'s orderings were chosen to prevent. Reading the field off the agent's own transport
  rather than off the selection makes `meta.json` and `history.json`'s last `model_id` agree by
  construction. **Accepted cost:** a pick with no message after it is lost across a restart.
- **`Conversation` gains the pair, named for when it is true** —
  `Data.define(:id, :dir, :title, :created_at, :supported, :model_at_mint, :server_at_mint)`.
  `#create` stamps it (in memory: `#create` mints a value object and touches no disk — the
  directory appears at `#save`), `#row` reads it back out of `meta.json`. This is *mint-time*
  state, like `title`, not the mutable-selection-on-an-immutable-object that would force every
  switch to replace the runner's `@conversation` via `#with` and weaken the "fixed for the runner's
  lifetime" rdoc.
- **The mint-time pair is write-once-read-once, and the name says so.** It is stale not only
  against a live switch but against *disk* — `#save` moves `meta.json` on at turn end and the Data
  never follows. That is harmless because the factory is its only reader, at mint, off a
  `Conversation` that `#row` or `#create` produced moments earlier. The one path that looks like a
  leak isn't: `ConversationRegistry#find` does hand out a resident runner's stale `Conversation`,
  but its caller's next move is `#open`, which is `@runners[id] ||= @factory.call(conversation)` —
  for a resident conversation the passed object is discarded. Reachable, never consumed. The
  `_at_mint` suffix is what keeps that legible at the call site instead of in an rdoc nobody
  re-reads.
- **Everything asking "what model is this conversation on *now*" asks the runner, and there are
  two answers.** They must not collapse into one, because the design already committed to pikuri-
  tui's authority split (`StatusFooterUpdater` moves the displayed name only once `ModelSwitched`
  lands, so a failed switch never advertises a model it never reached):
  - `AgentRunner#model` — **intent**: what this conversation will talk to next, `pending ||
    current`. Consumers: `registry.create(from:)` and the `/model` dialog's `aria-current`. A pick
    made on a busy conversation, followed immediately by "new conversation", should inherit the
    *pick* — that is what the user expressed.
  - **reality** gets no *public* reader: `finish_turn` reads `@agent.transport` directly (a public
    `attr_reader`, `agent.rb:219`, well above `private` at `:578`), and so would `status_data` if
    `Q_status_carries_model` lands — both are inside `AgentRunner`. Deliberate: `#save` writing
    from the transport rather than from the selection is what makes `meta.json` and
    `history.json`'s last `model_id` agree by construction, and not exposing a second runner-level
    reader beside `#model` removes the chance of an outside caller reaching for the wrong one.
  - The sidebar renders **neither**. A row is built from a `Conversation`, whose pair is mint-time;
    if a row ever wants to show a model it must ask the registry for the resident runner.
- **Why mint rather than seed the pending slot.** Not for history integrity — see the warning
  below. Because `Agent#detect_and_emit_context_cap!` runs in the agent's **constructor**
  (`agent.rb:647`), so minting on the factory default probes the *wrong* server's context window
  and re-probes on the first turn: a reopened conversation would show the wrong token cap until it
  was used, and pay an extra probe. And because a pending slot that is set on every reopen stops
  meaning "you picked something and it has not landed yet" — which is the meaning
  `Q_status_carries_model` and the `/model` dialog's `aria-current` marker both need it to have.
- **Do not re-derive the history-integrity argument.** This fork was once argued from
  `load_history!` (`agent.rb:503`) dropping thinking signatures whose `model_id` doesn't match the
  agent's current model, so that minting on the wrong model would degrade a reopened conversation.
  That premise is retracted — see *The upstream question* at the bottom. There is no measured
  degradation on any backend we point at, and the decision above does not rest on it.
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
- `registry.create` becomes `create(from:)` and stamps the pair at `store.create`; the factory's
  signature (`bin/pikuri-web-chat:148`, `lambda do |conversation|`) never changes, because it reads
  `conversation.model_at_mint` / `#server_at_mint` off the value object it already receives. The
  pair being inherited comes from `from.model` — the *runner*, and its intent reader — never from
  `from.conversation`, which is mint-time.
- The fallback when nothing is shown, or the shown conversation's connection is gone from the
  config, is `primary_llm`. `registry.default` (`:128`) — the conversation a fresh visitor lands
  on, also what the boot trifecta report opens — goes down that path.

## Knock-on changes

Plain work, no fork in it:

- **`SseListener`'s `else` branch** (`sse_listener.rb:137`) stops being unreachable, and its rdoc
  stops being true. What it *draws* is `Q_switch_marker`.
- **The boot banner** (`bin/pikuri-web-chat:296`, "agent: model @ server") becomes the *default*
  model, not the model.
- **`--model` / `--server` are gone** (2026-08-29, ahead of this work rather than as part of it).
  They were a second source for a connection, and this feature was about to add a third; the
  three-way precedence question is deleted rather than documented. So the first `[[llm]]` is
  simply "the connection a conversation starts on when it has no saved one", with nothing
  outranking it. See the 2026-08-29 amendment to `D_schema_complete_config`.
- **`restore!`** (`agent_runner.rb:124`) needs no change: the agent is already on the right
  transport when it runs, because the factory resolved it at mint.

## Open questions

None of these are settled, and none of them gate starting the work — they are edge-case loudness,
not shape. Each names what was checked, so the next session argues rather than re-greps. Leans are
marked as leans.

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
boundary" story the queued count already tells. Because minting resolves the saved transport, a
reopen never sets it, so the common case shows one unambiguous name — that is the property the
minting decision was made to protect, so don't trade it away here.

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
  connection too (edit the `[[llm]]`'s `model`, restart, reopen an old conversation — same
  load-time scrub). A picker makes it routine, not new.

Nothing to re-argue here; if the behaviour changes, it changes under us and the CHANGELOG says how.

## Where the nuggets go at graduation

- **The settled decisions** → one `DECISIONS.md` entry, flat invariant + `See D_<slug>` in
  **Scope decisions**. Roughly: *a conversation's model is `[model, server]` in `meta.json`, minted
  onto the agent by the factory and written back at turn end from the agent's own transport.* Its
  *Alternatives rejected* owes three things, because all three are plausible-and-wrong a future
  reader would otherwise re-derive:
  - **deriving the model from `history.json`'s `model_id`** — cannot express the server half,
    and would make the sidebar parse every history;
  - **persisting at pick time** — writes beside `#save`, or writes a commit point over no
    history;
  - **the retracted 400 argument** for minting on the saved transport. The real reasons are the
    constructor-time cap probe and keeping "pending" meaning one thing.
- **The three-reader split** — mint-time / intent / reality — is the thing most likely to be
  re-collapsed by someone adding a convenience accessor later, so it goes in the decision entry
  *and* is visible in the code: `_at_mint` in the field names, and no runner reader for reality.
- `meta.json` gaining a `server` key, `#save` owning the model, and why `Conversation`'s pair is
  named `_at_mint` → `ConversationStore`'s rdoc.
- The pending slot's lifecycle, the two drain points, and `#model` meaning intent rather than
  reality → `AgentRunner`'s rdoc.
- The catalog-as-constructor-argument seam → the **Layout** line for `bin/pikuri-web-chat`, and a
  sentence in the `D_pikuri_free_core` invariant if the wording no longer covers it.
- The picker itself, and "the first `[[llm]]` is what a conversation with no saved connection
  starts on" → `README.md`.
- Anything about the library's repair → `../pikuri`, never here.
