# lib/pikuri_web — the class map

Loaded beside the root `AGENTS.md` when work touches this tree. Pointers only: the per-class
what and why is each file's YARD header, the argument behind a shape is
`design/decisions.md`, and how the pieces work together is `design/architecture.md`. Cap:
10 KB.

**The root seam this tree lives under:** nothing under `agents/` or `conversations/` may name
a constant under `web/`, and every crossing is an object injected at `bin/pikuri-web-chat`
(`D_namespaces`, checked by `spec/pikuri_web/namespaces_spec.rb`). Membership is decided by
*what a class produces*, never by what it imports — each namespace module file states its own
admission rule, and `Util`'s is meant to fail things.

## Root — belongs to no half

- `pikuri_web.rb` — Zeitwerk loader + eager-load; module-level `PikuriWeb.logger`.
- `config.rb` — {Config}: the layered TOML loader for `~/.config/pikuri/config.toml`, a port
  of pikuri-tui's `Shared::Config`; schema-complete, Pikuri-free, read before anything else
  exists.
- `big_app_lock.rb` — {BigAppLock}: the serialization domain — run-to-completion tasks over
  one re-entrant monitor, `assert!` enforcement.
- `version.rb` — `PikuriWeb::VERSION`.

## `web/` — output is what the browser sees

- `web.rb` — the namespace: the one-way rule, and why "web" is not a thread boundary.
- `app.rb` — {Web::App}: the Sinatra app. `GET /` (redirects to the newest), `GET /c/:id`,
  `GET /events?conversation=`, `POST /messages`, `POST /cancel`, `POST /model`, `GET`/`POST
  /conversations`, `POST /conversations/:id/delete`. A route acting on a conversation names
  it, and every route body is one task.
- `gate.rb` — {Web::Gate}: the `[web]` password as Rack middleware in front of everything,
  plus the signed cookie a passed prompt mints.
- `sse_listener.rb` — {Web::SseListener}: the `Agent::Listener::Base` subclass rendering the
  event stream into transcript + SSE. The TuileListener equivalent.
- `transcript.rb` — {Web::Transcript}: one conversation's rendered blocks,
  server-authoritative; immutable `Block` values, guarded.
- `broadcaster.rb` — {Web::Broadcaster}: SSE frame formatting and fan-out, addressed per
  conversation; its own mutex, deliberately outside the domain.
- `streaming_message.rb` — {Web::StreamingMessage}: per-turn delta accumulator (append /
  finalize lifecycle), web descendant of the TUI's StreamingMarkdownBuffer.
- `tool_line.rb` — {Web::ToolLine}: one tool event as its short and verbose lines, plus the
  two-span markup CSS picks between.
- `disclosure.rb` — {Web::Disclosure}: the `<details>` a reasoning block is stored in, and its
  closed form for a page render.
- `trifecta_view.rb` — {Web::TrifectaView}: a walked trifecta report as the `/trifecta`
  dialog's escaped HTML body.
- `slash_command.rb` — {Web::SlashCommand}: name + description for one palette row, and the
  `CATALOG` a page is served a config-gated subset of.

## `agents/` — running one LLM turn

- `agents.rb` — the namespace; why it is plural.
- `runner.rb` — {Agents::Runner}: one conversation's agent, transcript and turn lifecycle —
  restore, the start-vs-inject decision, the pending model, the save at turn end, the
  fire-and-forget title job; broadcasts status.
- `titler.rb` — {Agents::Titler}: the opening message as a 3–7 word title — a throwaway
  toolless agent per call, the caps, and the reasoning canary.
- `model_catalog.rb` — {Agents::ModelCatalog}: the `[[llm]]` list as transports; name ⇄
  `[model, api_base]` ⇄ transport, each carrying its entry's `params`.

## `conversations/` — the conversation set

- `conversations.rb` — the namespace; why `HistoryReplay` sits here rather than in `Agents`.
- `store.rb` — {Conversations::Store}: the conversations folder — mints ids, owns the whole
  commit, lists what is saved, retitles, deletes a folder. Nests the `Conversation` row type.
- `registry.rb` — {Conversations::Registry}: the resident runners — mints one per
  conversation opened, deletes, serves the sidebar rows. Pikuri-free.
- `history_replay.rb` — {Conversations::HistoryReplay}: a saved `Agent::History` back into
  the events that produced it.

## `util/` — knows nothing about this app

- `util.rb` — the namespace and its admission test.
- `markdown_renderer.rb` — {Util::MarkdownRenderer}: kramdown (GFM) → HTML with escaped-text
  fallback; the HTML-escape helper for plain-text blocks.
- `relative_time.rb` — {Util::RelativeTime}: coarse "6 hours ago" for sidebar rows;
  server-rendered, hence stale-tolerant.
