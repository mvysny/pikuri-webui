# Per-conversation model

Switch the model without restarting the server, and have each conversation remember the one it is
on. A new conversation inherits the model of the conversation currently shown.

**The UI is deliberately unsettled** — where the control lives (sidebar row, status bar, a
`/model` line in the input, something else) is an open question, and nothing below assumes an
answer. What is decided: the *selection is per conversation and persists*; a new conversation
copies the shown one's.

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

## The library half is done

`Pikuri::Agent#run_loop(user_message:, transport:)` — `pikuri-core/lib/pikuri/agent.rb:353` — takes
a transport and calls `apply_transport!` at the top of the turn (`:726`): it no-ops when the
transport is structurally equal, otherwise rebuilds the chat context, emits
`Event::ModelSwitched(from:, to:)` and re-runs the context-cap probe. So a switch always lands on a
turn boundary, which is exactly the granularity we want — no cancelling a turn to change model, no
half-switched history.

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
- **`AgentRunner` holds the pending selection**, drained in `run_turn` and passed to
  `run_loop(transport:)`. It already has the mutex and the `:idle/:queued/:running` state machine
  to hang this on. Selecting while busy is naturally "next turn", which matches the Interloper's
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
- **`SseListener`'s `else` branch** stops being unreachable. Whether a switch draws a `:notice`
  block in the transcript is a real question (it *is* conversation history, unlike a log line —
  `D_diagnostics_to_stderr` doesn't settle it) and touches the block-kind contract if it wants its
  own kind.
- **`restore!`** replays history but sets no transport; a reopened conversation would boot on the
  factory's model and need the saved one applied before its first turn.
- **The boot banner** (`bin/pikuri-web-chat:296`, "agent: model @ server") becomes the *default*
  model, not the model.
- **`--model` / `--server`** keep meaning "override the primary connection", which is now also
  "the default for a conversation that has no saved one". `README.md`'s config section needs the
  distinction; `D_schema_complete_config` is untouched — no new keys, the `[[llm]]` array is
  already the schema.
