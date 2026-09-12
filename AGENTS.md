# AGENTS.md

This file is loaded on every turn of every session, so it is an **index, not a manual**:
one-line invariants and pointers, never the explanation behind one. The argument lives in
`design/decisions.md`, the mechanism in the chokepoint's YARD header, and a rule true of one
symbol in that symbol's own header. **Cap: 34 KB** here, 10 KB for a nested file — when it
gets close, garbage-collect by *moving* a line to one of those homes, never by summarising it
here, and trim every new line to the shape of the first one in its section. Two nested files
load on top of this one when work touches their tree: `lib/pikuri_web/AGENTS.md` (the class
map) and `public/AGENTS.md` (the client). Each has a `CLAUDE.md` beside it holding exactly
`@AGENTS.md` — nothing else ever goes in a `CLAUDE.md`, even though `/init` and the `#`
shortcut target that name.

## What this is

A Sinatra web front-end wrapping the [pikuri](https://codeberg.org/mvysny/pikuri) library —
the browser sibling of [pikuri-tui](../pikuri-tui/). `bin/pikuri-web-chat` binds the same
`Pikuri::Agent` and the same `Pikuri::Tool` set as the TUI's chat shell; the conversation
pane / input field / status bar become a server-rendered page kept live over one SSE
connection. All LLM transport, tool execution, agent loop control and prompts are pikuri's.
We own the web shell only — an SSE listener, a turn runner, and the routes, templates and
static files around them.

## Design docs

Rationale and reference live under `design/`; this file holds only what its header says it
may. Each file has one audience and *what it is allowed to own*; every file's preamble states
its entry shape and how to cite it. This section is the whole contract — nothing outside the
repo is needed to follow it.

| File | Owns | Loaded? |
|---|---|---|
| `README.md` | the operator: what this is, install, config, how to run, the trifecta promise | — |
| `AGENTS.md` (this) | what you must not break from a distance; the module map; this table — its rules are in its header | **every turn** |
| `design/requirements.md` | what must hold — `R_` entries, the README pitch's promises, stated not argued | lazy |
| `design/architecture.md` | **the map** of the code as it is — wiring, flows, where to start; **the code and its YARD headers are the truth** | lazy |
| `design/decisions.md` | why this and not that — `D_` entries, roads not taken | lazy |
| `design/comparison.md` | what Open WebUI does, descriptively — prior art, not our reasoning | lazy |
| `design/ideas/` | not yet decided — one file per idea, `ls` is the index, deleted on graduation | transient |
| YARD headers | per-symbol truth and its local rationale; a `bin/` script's flags and prerequisites | source of truth |

Rules that keep the split from drifting:

- **One home per fact; the others link.** A one-line restatement that saves a jump is fine —
  repeat the *fact*, defer the *explanation*. Compressing a `D_` entry into a bullet here is
  a third copy, not a summary.
- **`decisions.md` argues, `requirements.md` states, `architecture.md` composes and never
  argues, `comparison.md` is about *them*.** A paragraph explaining *why* in any file but
  `decisions.md` has drifted; move it and cite the `D_`. A fork belonging to the *library*
  — the agent loop, a tool, Interloper's delivery boundary — is logged in
  `../pikuri/DECISIONS.md`; cite it, don't re-argue it here.
- **A `D_` is earned by what happened, not by having had an alternative:** it shaped what
  this shell is, or it cost research the next person would otherwise redo. A testing library,
  a version bump, git-vs-`find` in a script: a comment at the site of the choice, never an
  entry. Only decisions already taken; ideas and open questions go to `design/ideas/`. A
  shipped decision that is reversed keeps its entry as a tombstone. Nothing about `design/`
  itself is an entry.
- **An `R_` is a promise the README's pitch makes, made an official rule — and the owner
  writes it.** An agent never adds, edits or retires one; it proposes, in conversation or as
  a drafted entry in `design/ideas/`. The ruler: allow the opposite everywhere — is it still
  the pitched project? "It cannot read your disk" → no → `R_`. "The transcript is
  server-authoritative", "every route body is one task" → broken in places, same product →
  an *invariant*: one line below, named in the promise's *Enforced by*, no `R_`.
- **An invariant is one line below, and nothing more:** the rule, at most one clause of
  consequence, `See D_<slug>` only when a `D_` exists — no fork, no cite; the agent has the
  code. A line that will not fit belongs in the chokepoint's YARD header.
- **Slugs:** `D_` decisions, `R_` requirements, `Q_` open questions inside `design/ideas/`
  only — a durable doc never cites a `Q_`. Underscores throughout, backticked in prose, cited
  by slug never by position; `grep '^## D_' design/decisions.md` is the index. A slug owned
  by a sibling repo is declared in `design/foreign-slugs.txt` with the repo that defines it.
- **`design/verify_design_tripwires.sh`** (also `rake design_tripwires`, part of `rake
  check`) fails on any cited `D_` / `R_` without a heading, an oversized `AGENTS.md`, or a
  `CLAUDE.md` that isn't the shim. Run it before committing a doc change.

### Ideas & their graduation

An idea file is named after what the idea *is*, and is a scratchpad exempt from this
project's doc quality rules, because it is going to be deleted. **An idea graduates the
moment it is acted on, and graduation is not done until the file is gone** — sidecar folder
`design/ideas/<name>/` included, so read those too before deleting. Where the lasting nuggets
land, in the order to try:

- the choice made + the alternatives rejected → a `D_` entry if it passes the gate above;
  otherwise a comment at the site of the choice
- a promise the pitch makes that must hold from now on → a proposal for the owner, who writes
  the `R_`; the invariant that keeps one → one line below
- **a procedure — "change this and those move together"** → next to the thing it operates on,
  as a script wherever one can run it (`bin/regen-icons`). A manual in prose can be neither
  executed nor tested, and `decisions.md` is the wrong home in any case: past tense is a
  decision, imperative future is a manual
- how the pieces work together — wiring, a flow crossing several of them →
  `design/architecture.md`
- how one class works and why it is shaped that way → its YARD header
- a new file or a changed responsibility → its line in the module map (here, or the module's
  own `AGENTS.md`)
- what a *user* must know — a flag, the trifecta promise, how to configure a model →
  `README.md`
- work deferred *as a consequence of a logged decision* → that entry's *Consequences*

There is no `CHANGELOG` here; don't create one for a graduated idea.

*Layout seeded from the `design-docs` skill (mvysny, `~/.claude/skills`); this project needs
nothing from it.*

## Invariants

What a change must not break from a distance.

- **Reuse pikuri as the runtime; this project owns the web shell.** `Pikuri::Agent` is the
  loop, `Pikuri::Tool::*` the tools, `Pikuri::Agent::Event` the stream we render; anything
  beyond the listener, the runner and the routes around them is scope creep.
- **No `Pikuri::*` type reaches what the browser sees.** Translation happens at
  {Web::SseListener}, {Agents::Runner}, {Conversations::HistoryReplay} and
  {Conversations::Store#save}, and it is a rule about types, never a folder. See
  `D_pikuri_free_core`.
- **Nothing under `agents/` or `conversations/` may name a constant under `web/`** — a
  component reaching down into a service is the sanctioned shape, the reverse is not. Checked
  by `spec/pikuri_web/namespaces_spec.rb`. See `D_namespaces`.
- **The transcript is server-authoritative** — {Web::Transcript} holds the rendered blocks;
  never introduce client-only conversation state. See `D_server_authoritative_transcript`.
- **`GET /events` subscribes *before* it snapshots, and the snapshot is one frame** — never a
  `reset` plus a `block` each, which blinks the tail. The duplicate that ordering buys is what
  covers the page-render-to-connect gap. See `D_subscribe_then_snapshot`.
- **A saved conversation is `history.json` plus our `meta.json`, and nothing else.** Blocks
  are re-derived by replaying synthesized events, never stored, so old conversations get
  today's renderer. See `D_replay_from_history`.
- **The agent loop runs as a job on the shared executor, never on a request thread**, and
  everything shared is touched only inside a {BigAppLock} task. See
  `D_worker_thread_agent_loop`, `D_global_monitor`.
- **Tasks are rapid-fire** — no network, no waiting on another thread, no post-and-wait, disk
  only where rare and deployment-bounded; the domain is the outermost lock against pikuri's,
  and guarded classes enforce with `assert!`. Rendering, `run_loop` and the SSE drain loops
  stay off-domain. See `D_global_monitor`.
- **New shared state joins the domain, or states the reason for its own lock** the way
  {Web::Broadcaster} does — and never a per-session mechanism, because there are no sessions.
  See `D_no_event_queue`.
- **Turns run on one shared *unbounded* executor, and its size is not a correctness device.**
  Sending never refuses for load; never re-bound the pool to cap load, and never re-add
  `--turns`. See `D_serial_turn_executor`.
- **The server is rationed per *request*, by pikuri; a `[[server]]`'s
  `max_concurrent_requests` sizes it** — never a throttle of ours, never a flag. See
  `D_max_concurrent_requests`, `D_upstream_request_throttle`.
- **Deleting a conversation is irreversible, and it stays deleted.** A delete mid-turn
  *retires* the runner ({Agents::Runner#discard!}) before removing the folder, so nothing can
  save the conversation back. See `D_delete_no_undo`.
- **{Conversations::Store} has no lock and does not need one** — one writer per directory,
  temp-file-and-rename, `#save` owns the whole commit; don't add a `Monitor` for safety. See
  `D_no_store_lock`.
- **One process per state root — and nothing enforces it, ever.** Last-writer-wins is
  accepted and the README warns; no `flock` is coming. See `D_no_multi_process_lock`.
- **All state lives under `~/.local/state/pikuri/pikuri-web-chat/`**, derived once as
  `state_root`; anything new goes beside `conversations/`, never straight into
  `Pikuri::Paths.state`. See `D_per_shell_state_root`.
- **Nothing in the exit path may rely on `at_exit` or on Sinatra's INT trap** — both run on
  the far side of Puma's unbounded graceful wait. {Web::Broadcaster#close} must stay
  idempotent *and* keep refusing new subscribers. See `D_shutdown_on_state_stop`.
- **The browser shows the conversation; diagnostics go to stderr.** {Web::SseListener}
  renders events, never log lines, and `PikuriWeb.logger` is never pointed at the
  {Web::Broadcaster}. See `D_diagnostics_to_stderr`.
- **A wedge is diagnosed with Puma's own backtrace signal (`SIGPWR`), never a handler of
  ours.** See `D_puma_thread_dump`.
- **JavaScript is mechanics, never a renderer.** Markup or conversation content the server
  could have produced is the server's, always; the rule is about rendering and state, *not*
  latency. See `R_no_build_step`, `D_no_js_build_step`.
- **A feature that owns a slice of the page owns a script file**, paired with the markup it
  renders from; anything crossing a boundary goes through `app.js`, never through another
  feature's DOM. See `D_feature_owns_its_file`, and `public/AGENTS.md`.
- **One `index.erb` for the phone and the desktop; the difference is placement, so it is
  CSS's.** The 40rem breakpoint is written twice (`style.css`, `conversations.js`) and moves
  together; none may sit at or above 768px, which is iPad portrait. See
  `D_one_shell_two_layouts`.
- **Firefox on the desktop, Safari on iPad and iPhone — greenfield only**, no polyfills and
  no fourth browser. See `D_target_browsers`.
- **Slash commands: the catalog is the server's, the palette is the browser's, and a command
  never writes to the transcript.** Rows activate on `pointerup` (a tap on iOS never becomes
  a `click`), and `openDialog` takes a *Node*, never an HTML string. See
  `D_slash_command_palette`.
- **Streaming is re-render-and-replace** — deltas preview-only, the bookend finalizes with
  authoritative content, dead after finalize; coalescing stays in pikuri at 15 fps. See
  `D_rerender_and_replace`.
- **Mid-loop input goes through `Control::Interloper`, and the input stays enabled while
  busy.** {Agents::Runner#submit} injects when busy and never refuses for it; the one
  non-answer is a conversation deleted under it. See `D_interloper_mid_loop_input`.
- **The chat script stays chat-only; new capability means a new sibling script** with its own
  tool set and its own trifecta report. See `R_chat_only`, `D_chat_only_entry_point`.
- **A conversation owns its agent; a tab owns which one it views** — no sessions, no
  accounts, single-user for good, and `--bind` defaults to 127.0.0.1. See
  `D_conversation_owns_agent`, `D_single_shared_conversation`.
- **One `[web]` password gates the port as middleware around everything**, and it is a gate,
  not accounts — no `[web]` means no middleware at all; never a `--password` flag (visible in
  `ps`), never a default password. See `D_one_password_gate`.
- **The cookie a passed prompt mints is signed with the configured password itself, never
  stored**, so a changed password invalidates every outstanding one. See `D_gate_cookie`.
- **Reasoning is collapsible per block and never hidden** — `<details>` is `:thinking`'s
  alone, and `[ui] show_thinking` sets whether blocks *start* open. See
  `D_details_per_block`.
- **Which reasoning blocks are open lives in `data-disclosure` on the block div**, outside
  the html `upsert` rewrites 15×/s, or mid-turn expansion breaks silently. See
  `D_disclosure_state_on_the_block_div`.
- **A tool block carries the short line and the raw one both; CSS picks.** Both forms
  sanitize, the argument dump included — the TUI's `inspect` carve-out does not port. See
  `D_both_forms_in_the_block`.
- **Theme is a presentational cookie, not transcript state.** A new themed colour means both
  palettes *and* both mappings; never repurpose a block kind's colour for a control. See
  `D_theme_cookie`.
- **The mascot is the library's; the plate is ours.** `public/images/kuri.svg` is a
  **verbatim** copy of `../pikuri/assets/kuri.svg` — re-copy, never redraw — and
  `bin/regen-icons` holds the sizes and the plate colour. See `D_icon_plate`.
- **Nothing outside `style.css` reads a raw colour**, but for two exceptions on the record:
  the plate colour in `bin/regen-icons`, and `index.erb`'s `theme-color`, which the browser
  reads before any stylesheet. Argue for a third; don't assume it. See `D_theme_cookie`,
  `D_icon_plate`.
- **One config file for every pikuri shell, and a connection has exactly one source.**
  {Config} carries the *whole* schema including sections this host never reads; no flag, no
  `ENV`, no project-local overlay, so there is never a precedence rule. Schema-completeness
  is a *standing* obligation: a config addition in pikuri-tui is a pikuri-web change. See
  `D_schema_complete_config`.
- **A `[ui]` view preference is the one thing the file does not own outright** — it sets the
  starting value and a per-browser cookie outranks it. See `D_ui_cookie_over_config`.
- **An `[[llm]]`'s `params` reaches the server verbatim** — never a `thinking = false`
  boolean, whose wire spelling differs per provider *and* per chat template. See
  `D_llm_params_passthrough`.
- **{Agents::Titler}'s word and character caps and its `</think>` strip are load-bearing**,
  because a server may accept a parameter and ignore it; `thinking_tokens > 0` is diagnostic
  only and never discards a title. See `D_canary_severity`.
- **`[model, api_base]` is not unique, and the first `[[llm]]` declared owns it** — the
  catalog folds over `choices.reverse`, and a "simplification" back to `to_h` reopens every
  saved conversation on the titler's connection. See `D_shadowed_identity_pair`.
- **A conversation's model is `[model, server]` in `meta.json`**, minted onto the agent by
  the factory and written back at turn end from the agent's own transport; three readers that
  must not collapse. See `D_per_conversation_model`.
- **A title comes from the opening message on the connection `[titler]` names, at most once
  per runner** — no `[titler]` means no titling, never a fallback to the primary connection.
  See `D_titler_connection`, `D_lazy_retro_titling`.
- **`--dev` is Sinatra's development mode, not code reloading** — the agent and its listener
  stack are wired once at boot. See `D_dev_flag_no_reload`.

## Module map

Everything we ship is under `PikuriWeb::`; `lib/pikuri_web.rb` boots Zeitwerk over
`lib/pikuri_web/` and carries `PikuriWeb.logger`. Four namespaces cut by *what a class
produces*, plus the root for what belongs to no half (`D_namespaces`); each namespace module
file carries its own admission rule. One line per module here — the class map is
`lib/pikuri_web/AGENTS.md`.

- `lib/pikuri_web/web/` — {Web}: everything whose output is what the browser sees.
- `lib/pikuri_web/agents/` — {Agents}: running one LLM turn.
- `lib/pikuri_web/conversations/` — {Conversations}: the conversation set, saved / resident /
  replayed.
- `lib/pikuri_web/util/` — {Util}: knows nothing about this app, and the admission test is
  meant to fail things.
- `lib/pikuri_web/{config,big_app_lock,version}.rb` — the root: {Config} (the whole shared
  TOML schema, Pikuri-free), {BigAppLock} (the serialization domain), `VERSION`.
- `bin/pikuri-web-chat` — boot: config, catalog, permit sizing, the one conversation factory,
  the turn executor, the domain, the trifecta report, the gate, Puma and its shutdown hook.
- `bin/probe-titler`, `bin/regen-icons` — maintainer tools, run by hand; each holds what it
  generates (the title corpus; the icon sizes and plate colour).
- `views/index.erb`, `views/_sidebar.erb` — the page shell (both layouts, `#slash-menu`, the
  dialog `<template>`s) and the conversation list, also served alone for in-place refresh.
- `public/` — the static root, served at the URL root. See `public/AGENTS.md`.
- `spec/pikuri_web/` — mirrors `lib/pikuri_web/`, namespace folders included; the specs that
  cross namespaces on purpose sit at its root.

## Conventions

- **Tests:** rspec-core `describe`/`it` with minitest-style assertions (`assert_equal`,
  `refute`, …), the same as pikuri and pikuri-tui.
- **A class and its spec stay one path apart**; `conversation_flow_spec.rb` and
  `client_contract_spec.rb` are the deliberate cross-namespace pair.
- **Block kinds** (`:user`, `:assistant`, `:thinking`, `:tool_call`, `:tool_result`,
  `:notice`, `:error`) are the contract between {Web::SseListener}, `index.erb` and
  `style.css` — adding one means touching all three. Changing how an *existing* kind renders
  is two: whoever built that html payload, and `style.css`.
- **Slash commands are a three-place contract:** {Web::SlashCommand}`::CATALOG`, the
  `commands` map `app.js` hands `composer.js`, and a `<template>` in `index.erb` for one that
  opens a dialog. A command the config can make pointless is dropped in
  {Web::SlashCommand}`.catalog`, never by a fourth place.
- **Attacker-influenced text reaching a block as plain text goes through `Pikuri::Sanitizer`
  *before* `Util::MarkdownRenderer.escape`** — escaping stops markup, not a bidi override.
  Markdown-rendered prose (`:assistant`, `:thinking`) is the known exemption; a title is
  sanitized where model output becomes one, so no renderer has to remember.
- **Library exceptions are logged, our bugs raise:** kramdown failures degrade to escaped
  text and `run_loop` failures return the UI to idle, but contract violations (double
  finalize, bad flush mode, a call from outside a task) raise.
- **rack-test arrives as host `example.org`** — without `set :environment, :test` Sinatra
  403s it, so a spec asserting *absence* passes vacuously against "Host not permitted";
  confirm a new probe's no-fix failure by stashing the fix.
- **Every thread we spawn names itself** (`Thread.current.name`), and a per-job borrow like
  the turn executor's names the thread for the job's duration.
- **Doc comments** carry the per-symbol what *and* why, complete standalone; the
  `writing-rdoc` skill has the rules.
- **Components are self-sufficient** — no MVC/MVP layering, a component may reach a service
  directly, and inheritance is for *being* a component, never for sharing code; the `cop`
  skill has the rules.
- **pikuri is pre-1.0 and this shell tracks its master**, so break freely in step with it:
  migrate on pikuri's `CHANGELOG.md` `**Breaking:**` entries, with pikuri-tui's HEAD as the
  worked example for anything ambiguous. See `D_path_deps_on_pikuri_master`.

## Commands

A clone needs `../pikuri` beside it at master — the Gemfile's path dependency, which CI
clones itself.

- `bundle exec rake check` — the full check (the spec suite plus the doc tripwires), the
  default task, the cross-repo standard entry point, and what `.woodpecker.yml` runs.
- `bundle exec rspec spec/pikuri_web/web/app_spec.rb` — one file; `-e 'name'` for one example.
- `design/verify_design_tripwires.sh` — the doc tripwires alone (`rake design_tripwires`).
- `bin/pikuri-web-chat [--port N] [--bind ADDR] [--dev]` — the shell itself, on
  <http://localhost:4567>; needs `~/.config/pikuri/config.toml` with at least one `[[llm]]`.

## Working on this codebase

- **Flags are only what the config file has no home for.** `--turns`, `--server`, `--model`
  and `--api-key-env` were removed deliberately and `--password` was refused outright;
  re-adding one reopens a precedence rule or puts a secret in `ps`.
- **A build that was green yesterday can break on `bundle install` alone**, because the
  Gemfile follows pikuri master. Run `rake check` before assuming a failure is yours.
- **The boot script is wiring, not logic.** A tool added there breaks a promise the README
  has already made (`R_chat_only`); behaviour added there is a class that should have owned
  it.
- **Nothing here is verified on real iPhone hardware.** The layout was measured in a resized
  desktop browser; `dvh`, the on-screen keyboard and `env(safe-area-inset-*)` are open.
