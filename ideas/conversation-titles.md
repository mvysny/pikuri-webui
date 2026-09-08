# Conversation titles

Today a conversation's title is its start stamp (`ConversationStore#stamp_title`), rendered in the
sidebar. Two ways to make it say something: the model writes one, or the user does. The v1
conversation sidebar shipped without either; this is what "v2 auto-title" was in
`ideas/multiple-conversations.md`, which has graduated.

`meta.json` already carries `title` and the schema is versioned, so neither option needs a format
change — and the title deliberately never appears in the path, so retitling never moves a directory.

Research lives in `ideas/conversation-titles/` — the probe transcripts and the upstream citations
behind the thinking-off fork below. Two runs so far: `qwen-prompt-probes.md` (prompt-following) and
`titler-model-probes.md` (thinking-off, and the small models rejected).

## Settled

- **`Q_titler_threat_model`: an adversarial opener is out of scope.** Decided, not deferred. This is
  a single-user app on `127.0.0.1` with no auth and no sessions; the opening message is one the user
  typed, and a manipulated title is a wrong string on their own sidebar row. The probing in
  `titler-model-probes.md` stands as evidence about *models*, but nothing here is designed around
  resisting an attacker, and a later change must not be blocked for weakening that. Two things
  survive it for reasons that are not security: the length cap (load-bearing, below) and the
  `<opener>` wrapper (functional, below).
- **`Q_titler_model`: the titler is a `[[llm]]` named by a new `[titler]` table, and no `[titler]`
  means no titling.** `[titler] llm = "qwen-titler"`, referencing a `[[llm]]` by its `name` — legal
  despite `D_per_conversation_model`'s ban on names, because reference and referent live in one file
  edited together, and `.load` already enforces `name` uniqueness. A dangling reference is a boot
  `Config::Error` naming the key, exactly like a dangling `server`. The table rather than a flat
  `titler = "…"` so a later word cap or off-switch has a home without a second top-level key.

  This **overturns** the earlier settled answer ("the first configured `[[llm]]`, same as a
  conversation with nothing saved — so there is nothing left for a `[web] title_model` knob to buy").
  That reasoning holds only while the primary model *can* be made non-thinking. Thinking-only models
  are a real and growing category, and the day the first `[[llm]]` is one, no parameter rescues the
  feature — a second connection is the only exit. The knob is the escape hatch, not a nicety, and
  that is a real fork worth a `D_` entry when this lands.

  **Unset means off, leaving the stamp** — never a fallback to the first `[[llm]]`. So the 31 s
  thinking-on path never ships as a default, an upgrade brings no surprise inference load, and the
  retro-sweep is priced at 1.2 s a title *or nothing*, with no third case.
- **What runs it:** its own `Pikuri::Agent`, no tools. A *system* agent: no listener that reaches
  the browser, no transcript block, nothing in the UI. Not the conversation's own agent — a titling
  request through that lands in the history and pollutes it.
- **Fresh every time — a new `Agent` per title, not one long-lived titler.** The earlier plan was a
  resident agent reset by `clear_conversation`, to dodge the constructor's context-window probe.
  Unnecessary: the probe runs *only* when the transport carries no explicit `context_window`
  (`agent.rb:706` is `@transport.context_window || <probe>`), and a titler does not care what the
  real cap is. Set it on the transport and `Agent.new` does no I/O at all. A per-title agent holds no
  state between calls, so there is nothing to confine to a thread and nothing to serialize — which
  is what lets titles share `turn_executor` at any pool size (`Q_titler_executor`).
- **When:** from the first user message alone. Fire-and-forget; a titling failure must never fail
  the turn — it just leaves the stamp.
- **The opener is passed as delimited data, not as the user turn** — and the reason is functional,
  not defensive. A chat app's first message is very often an imperative: *"write me a poem about
  cats"*, *"summarize this"*, *"fix this stack trace"*. Those are honest users, not attackers, and a
  bare `user_message` invites the titler to **do** them instead of naming them — which is exactly
  what the 4B did, poem and all. Wrapping the opener as `<opener>…</opener>` with a system line
  saying that text is data is what makes an imperative opener get *titled*. It would be worth
  keeping with no adversary anywhere in the picture. Verbatim in `titler-model-probes.md`.
- **`Q_title_length`: 3–7 words.** The original 10–20 word ask is disregarded — it is long for a
  `clamp(12rem, 20%, 20rem)` sidebar row. Ellipsised in CSS as a backstop.

## Prompt-following, and what to do about the model's output

**Format-following: 8/8, twice.** Qwen 3.6 obeys 3–7 words, no quotes, no trailing period, no
preamble, no markdown, and answers in the input's own language — with thinking on (run 1) and with
thinking off (run 2). The "Sure! Here's a title:" case has never once appeared.

**Injection was measured, then scoped out** — see `Q_titler_threat_model`. For the record: run 2 ran
six attacks; Qwen 3.6 held 5/6 and the 4B held 2/6. The one that lands on the 35B is a `</opener>`
breakout carrying a fake system instruction, and only when the demanded output is itself
title-shaped (`BANANA BANANA BANANA` yes, a full sentence no) — i.e. **the format constraint is what
holds, not the instruction hierarchy.** Nobody can make the titler emit a sentence, markup, or a
long payload; they can only choose which 3–7 words. Against the accepted threat model that is a
non-event, and it is recorded here so a later reader does not re-run the experiment.

The implementation consequences survive anyway, because none of them is really about attackers:

- **Cap in Ruby, and treat it as load-bearing.** Not hygiene. The degradation mode of the
  thinking-off adapter is *silently not applied* — a ruby_llm middleware reorder, a template change,
  a titler pointed at a connection that ignores the param — and run 4 caught the thinking-on path
  dumping **~4000 characters of chain-of-thought into `content`** where a title belongs. So the cap
  is what stands between a silent regression and an essay in the sidebar. Hard word *and* character
  cap, single line, applied to whatever comes back.
- **A cheap canary for that same regression — and it can be exact, not a threshold.** The original
  plan was "600 tokens or 30 s means the model thought". Sharper: pikuri already carries
  `thinking_tokens` per assistant message (`agent.rb:1173`, into `Event::Tokens`), and a message the
  history holds exposes `#tokens` (`agent.rb:505`). So the signal is **`thinking_tokens > 0`** — a
  direct statement that the param did not apply, no tuning and no false positives from a merely slow
  server. Latency and `output` ride along as log fields.
- **`Q_canary_severity`: the canary is diagnostic only, its level follows declared intent, and it
  fires once.** Three things that look like one:
  - **It never affects the title.** The earlier "prefer keeping the stamp over storing a suspect
    title" must not hang off this signal, or it punishes an operator who *cannot* turn thinking off
    and accepts slow titles. Suspectness is a property of the string — over the cap, multi-line,
    carrying `</think>` — and the cap / strip / sanitize already decide it. Thinking-on titles are
    real titles, just slow.
  - **Level by intent, not fixed.** `params` declared on the titler's `[[llm]]` and thinking
    happened anyway ⇒ **WARN**: a stated intent silently did not apply, which is a config bug. No
    `params` at all ⇒ **INFO**: they pointed `[titler]` at a thinking model and asked for nothing
    else. The crudeness is deliberate and is `Q_titler_params`' bill coming due — a passthrough
    cannot tell that `chat_template_kwargs.enable_thinking = false` *means* no thinking, where
    `thinking = false` would have. Cost: one spurious line in a config that set `params` for some
    other purpose. Cheaper than the boolean's silent-mistranslation risk, so the trade holds.
  - **Once per titler connection per process, never per title.** A line on every title teaches the
    reader to filter it, which is how the regression it exists to catch goes unseen. One line with
    the numbers in it, naming the recipe, gets read.

  Stderr via `PikuriWeb.logger` either way, never the browser (`D_diagnostics_to_stderr`).
- **Strip a leading `</think>`, and anything before a `</think>`.** Run 1 saw the artifact on the
  thinking-*off* path; runs 2–4 never reproduced that, and run 4 instead found the leak on the
  thinking-*on* path in a much worse form. The strip is a one-line backstop for both shapes.
- **`Pikuri::Sanitizer`, not just escaping.** Unchanged, and it stands on the standing rule rather
  than on this feature's threat model: the title reaches `_sidebar.erb` as plain text in four places
  (link text, the `<a title>`, the delete button's `aria-label` and its `title`), and
  `set :erb, escape_html: true` stops markup but not a bidi override or a zero-width character.
  Same rule as the tool lines (AGENTS.md, *Conventions*). Model output is text of unknown
  provenance whether or not anyone is attacking.

## The fork: thinking must be off — and the channel was there all along

**Closed.** Run 2 narrowed five options to a pikuri feature request; run 3 found the channel already
shipped, so nothing here blocks implementation any more. Qwen 3.6 thinks *hard* about
titles: 800–1500 completion tokens, 30–80 s per title on the local 35B MoE, and the variance between
runs is itself large. Thinking off is ~10 tokens and ~1 s. Two orders of magnitude, and it decides
whether the retro-sweep below is viable at all.

| how | s | completion tokens |
|---|---|---|
| baseline (thinking on) | 40–82 | 843–1493 |
| `reasoning_effort: none` / `low` | 37–66 | 679–1070 — accepted, then ignored |
| `/no_think`, system prompt / appended / prefixed | 40–62 | 804–1266 — **no effect** |
| assistant prefill `<think></think>` | — | HTTP 400 |
| `chat_template_kwargs: {enable_thinking: false}` | **~1** | **~10** |

Run 4 measured the two ends properly — same eight openers, same agent, same code path, only the
injected param differing: **1.2 s and 8 tokens a title against 31.1 s and 625, i.e. 27× on wall
clock and 83× on tokens.** Thinking-off is also the *steadier* of the two (0.9–1.4 s against
1.5–72.2 s) and the safer: with thinking on, one of the eight dumped ~4000 characters of
chain-of-thought straight into `content` where a title belongs. Full tables in
`titler-model-probes.md`.

`chat_template_kwargs` needs `RubyLLM::Chat#with_params`, and `Pikuri::Agent` exposes no extra-params
channel — no `params:`, no thinking knob, and its `@chat` has no reader. Where the options landed:

- ~~**A smaller, non-thinking model.**~~ **Rejected on evidence.** Both `*-Instruct-*` models on the
  server were probed. `Qwen3-4B-Instruct` is fast (0.4 s) and *trivially* injectable — 4 of 6
  attacks landed, including `PWNED` and `OK`. `Qwen2.5-7B-Instruct` answers in the wrong language
  five times in eight (Turkish, German, Chinese) and thinks Australia's capital is Canada's.
  Transcripts in `titler-model-probes.md`. The premise was wrong twice over: a 4B is *not* ample for
  this job, because the job is 90% resisting the opening message rather than summarizing it — and
  the speed argument evaporated anyway, because a 3B-active MoE emitting ten tokens with thinking
  off is already ~1.2 s.

  What is rejected is *hardcoding* a small sidecar, not *allowing* one. `Q_titler_model` now says the
  titler is whichever `[[llm]]` the file names, so this bullet no longer spares us the knob, the
  cold-load-on-first-use problem, or the pikuri-tui-side config addition — all three are accepted
  above. It survives as the reason the docs recommend one model and no small tier.
- ~~**Prompt-level `/no_think`.**~~ **Dead.** Qwen 3.6 dropped Qwen 3's soft switches; all three
  placements still emitted a full reasoning block, and upstream says the API parameter is the
  supported route ([Qwen3.6 discussion #90](https://github.com/QwenLM/Qwen3.6/discussions/90)).
  The assistant-prefill variant is dead in a more interesting way: llama.cpp answers
  `Assistant response prefill is incompatible with enable_thinking` — prefill is available only once
  thinking is *already* off, so it can never be the thing that turns it off.
- **`ChatTransport#faraday_adapter` — the answer, and it already exists.** Run 2 said pikuri has no
  channel. It has one: `faraday_adapter` is documented as "a generic HTTP seam", installed onto the
  agent's per-chat `RubyLLM::Context`, and ruby_llm runs `faraday.request :json` *before* the
  adapter — so an 8-line `Faraday::Adapter::NetHttp` subclass can merge `chat_template_kwargs` into
  the already-serialized body. **Measured end-to-end through a real `Pikuri::Agent`: 0.5–1.3 s with
  it, 40–57 s without.** No pikuri release, no second model, no VRAM, no config knob. Code and the
  four costs (intent stretch, a Qwen-specific string in our repo, coupling to ruby_llm's middleware
  order, per-transport-only) are in `titler-model-probes.md`. The failure mode of every one of those
  costs is *slow titles*, never wrong ones, which is what makes it acceptable here.
- **Server-side `--reasoning-budget 0`, no code at all.** `llama-server` has the knobs
  (`--reasoning-budget 0`, `--reasoning off`, `--chat-template-kwargs`), and the router can alias one
  GGUF twice, so thinking-off becomes a property of a connection and the titler is just a second
  `[[llm]]`. Strictly cleaner than the adapter — declarative, operator-visible, nothing
  Qwen-specific in our repo. Costs a second full copy of the 35B's weights in VRAM (~20 GB), because
  each alias is its own process. The right choice on a box with room; the adapter is the choice on
  this one.
- **A feature request to pikuri — still the right long-term home**, now demoted to a nicety rather
  than a blocker. An explicit extra-params channel on `ChatTransport` would retire the adapter and
  its middleware-order coupling; the ask is *general* (`enable_thinking` is not Qwen-specific
  plumbing once spelled as a params passthrough). No longer blocks anything, so it does not collide
  with the one-minor pin (`D_released_pikuri_gems`).
  **Stale (`D_path_deps_on_pikuri_master`):** there is no pin any more — this shell is back on
  `../pikuri` master by path, so an upstream feature request is now a same-day change, not a
  release away. That makes this option cheaper than the adapter, not merely a nicety.

  **Deliberately deferred anyway** (`Q_titler_params`): prove the config shape works end to end
  behind the adapter first, then go the proper rounds. Doing it upstream first would spend a pikuri
  change and a pikuri-tui change on a design not yet run against a real server, and the config file
  — the part that would be painful to change later — is identical either way.
- **Raw `RubyLLM::Chat` off the transport's fields.** Now pointless — the adapter reaches the same
  wire format without this project owning LLM transport wiring, and without replicating
  `Agent#build_context` (~10 lines, `openai_use_system_role = true` included).
- **Live with it.** Unchanged and still bad: fire-and-forget means a late title is cosmetic, but 60 s
  of inference-server occupancy contends with the user's actual answer — on a `--parallel 1` local
  server the user's own turn stalls behind a title. Fatal for the sweep.

**So the fork closes on a param channel, not on the model — and the channel is `faraday_adapter`, in
the gem we already depend on.** Nothing here is worth loading a second model for, and nothing here
waits on a pikuri release. The remaining work is the *Plumbing* section below.

## `Q_titler_params`: the config carries the params, we carry the hack

The two halves are independent, and only one is hard: **naming the titler** is pure config, while
**turning thinking off** needs a params channel that does not exist. Decided: build *both* here
first, and go the proper rounds only once it works.

- **The config gains `params` on `[[llm]]`** — a passthrough, not a `thinking = false` boolean. The
  wire spelling is not one thing (llama.cpp+Qwen `chat_template_kwargs.enable_thinking`; other GGUF
  templates spell their kwarg differently; OpenAI `reasoning_effort`; Anthropic
  `thinking: {type: "disabled"}`), so a boolean needs translating per provider *and per chat
  template*, and a wrong translation fails in the one way run 4 proved is expensive: **silently not
  applied**, ~4000 characters of chain-of-thought into `content`. A key that promises portability and
  quietly does not apply is worse than a key that says what it sends. The passthrough is also worth
  more than the titler is — it retires `faraday_adapter`-as-params-hack for any future `top_k` /
  `min_p` / vendor flag, and it gives a *conversation* connection thinking-off for free, which
  someone will want.
- **The recipe, and the only model we recommend.** Copy-pasteable, because nobody discovers
  `chat_template_kwargs` on their own:

  ```toml
  [[server]]
  id  = "local"
  url = "http://localhost:8080"

  [[llm]]
  name   = "Local Qwen 3.6"
  server = "local"
  model  = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"

  [[llm]]
  name           = "qwen-titler"
  server         = "local"
  model          = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
  context_window = 8192
  params         = { chat_template_kwargs = { enable_thinking = false } }

  [titler]
  llm = "qwen-titler"
  ```

  `context_window` is in the recipe on purpose: it is what makes `Agent.new` do zero I/O
  (`agent.rb:706` is `@transport.context_window || <probe>`), and it is the reason the titler wants
  its own `[[llm]]` even pointing at the same server *and* the same model. Same `[[server]]` on
  purpose too — permits are keyed by URL, so the titler shares the pool and queues behind real
  requests. **Warn against a second `[[server]]` block for it:** two entries with one URL means two
  `ServerPermits.limit` calls on one key, and the operator silently resizes their own pool.
- **We recommend exactly one model, and admit it.** Qwen 3.6 35B A3B with the kwargs above. There is
  **no validated small-model recommendation** — both models probed were rejected, and the axis is not
  injection (out of scope, `Q_titler_threat_model`) but plain quality: `Qwen2.5-7B-Instruct` answered
  in the wrong language 5 times in 8. So the floor is higher than intuition suggests, and the docs
  say so rather than guessing a tier list. `ideas/conversation-titles/bench-thinking-on-off.rb` is
  the thing an operator re-runs against a candidate; if that gets asked for twice it graduates into
  a script beside `bin/regen-icons` rather than prose (AGENTS.md, *a procedure → a script*).
- **`params` is honoured for every connection, in one place: `ModelCatalog.from_llms`.** It is
  already the single `Config::Llm` → `ChatTransport` translation (`model_catalog.rb:63`), so
  `.with(faraday_adapter: …)` there covers the titler and conversation transports with one
  implementation. Anything narrower makes `params` on a conversation `[[llm]]` a silently ignored
  key, which is the worst kind.
- **The adapter must close over the config hash, not freeze a constant.** The spike's
  `ParamsInjectingAdapter` holds a frozen `EXTRA`; honouring `params` means a factory building an
  anonymous `Faraday::Adapter::NetHttp` subclass per params hash — the shape
  `Pikuri::Testing.fake_transport` already uses for its scripted adapter, so there is precedent
  upstream. One per boot.
- **The TOML shape is the contract; the adapter is a temporary implementation of it.** That is what
  makes prototype-first safe: when pikuri eventually grows a real `params:` on `ChatTransport`, the
  config file does not change at all — only the translation in `ModelCatalog` does, and the adapter
  and its ruby_llm-middleware-order coupling are deleted. Verified today: `ChatTransport` is
  `(model, provider, assume_model_exists, api_base, api_key, context_window, faraday_adapter)` and
  `agent.rb` never calls `with_params`, so there is nothing upstream to lean on yet.
- **The one non-local cost: pikuri-tui stops booting until its allowlists widen — accepted, and
  owned upstream.** Both shells' config parsers are strict and share the file, so `[titler]` and
  `params` make pikuri-tui *refuse to boot*: `lib/shared/config.rb:486` raises
  `unknown top-level key(s)`, `:583` raises `llm[i]: unknown key(s)`. There is no way around it — a
  project-local overlay or an `ENV` escape is exactly what `D_schema_complete_config` forbids — and
  no reason to want one: the fix is two allowlist entries, `titler` and `params`, *carried* and read
  by nothing there. Decided to land this shell first and take the window of a broken TUI; the
  upstream commit follows separately, and is the `D_schema_complete_config` obligation running the
  other way rather than pikuri-tui implementing any of this.
- **`Q_titler_in_the_palette`: the titler shows up in `/model`, and that is left alone.** A titler
  `[[llm]]` is a full entry, so `ModelCatalog#rows` lists it and a user can pick it for a
  conversation. Hiding it costs a new `hidden = true` key; picking it is *legitimately useful* (a
  fast non-thinking conversation) rather than broken. Naming it plainly is the whole mitigation.
- **`Q_shadowed_identity_pair`: the recipe breaks pair uniqueness, and the first entry wins.**
  Found while wiring, not predicted: the recommended titler is a second `[[llm]]` on **one model and
  one server**, differing only in `params`. `ModelCatalog` keys `#resolve` / `#name_for` on
  `[model, api_base]`, built with `to_h` — i.e. **last wins** — so shipping the recipe as-is would
  have made every saved conversation reopen on the *titler's* non-thinking connection, and shown
  `qwen-titler` as the primary's name. `Config` cannot catch it: it enforces unique `name`, and two
  entries on one pair are legal and now *recommended*.

  Fixed by reversing the fold so the **first** declaration owns the pair, with the rest shadowed —
  still pickable, still in `#rows`, good for the session, but a conversation saved onto one reopens
  on the winner, because `meta.json` stores the pair and nothing finer
  (`D_per_conversation_model`). Boot logs which names that affects. Rejected: extending the stored
  identity to distinguish them (a `meta.json` schema change for a case whose whole point is that
  the two are the same model on the same box), and dropping the titler from the catalog (undoes
  `Q_titler_in_the_palette`, and the transport still has to come from somewhere).

  This is a `D_` entry when the feature lands — it is a fork with a rejected alternative, and the
  loss a future change would notice is exactly the silent one: someone re-simplifying the fold back
  to `to_h` gets green specs only because `model_catalog_spec.rb` now pins the direction.

## Retrospective titling

**Built, lazily.** `AgentRunner#restore!` posts the same titling job for a stored conversation that
is still stamp-titled, off the `History` it has just replayed — so an old conversation is named the
first time anyone opens it, no sweep and no second disk read. What follows is the reasoning, kept
until this graduates.

- **Never a bulk sweep, and the lazy form made the choice easy.** Reading every history at boot was
  always the expensive half; `restore!` already holds the one history it needs, which makes the
  per-conversation cost exactly zero until someone opens it. The rejected alternatives — sweep the
  lot after Puma is up, or cap it to the newest N — both pay for conversations nobody looks at.
- **`Q_titler_opener_cap`: the opener is truncated at `Titler::MAX_OPENER_CHARS`.** Not part of the
  original plan, and it is the retro path that forced it: a conversation from months ago can open
  with a pasted stack trace or a whole file, and a title comes out of the first sentence or two
  regardless. Applies to new conversations too, since there is no reason it should not.
- **Was gated on the fork above; now priced.** At the measured 1.2 s a title, sweeping 100
  stamp-titled conversations is **two minutes** of background work. At the thinking-on 31.1 s it is
  **52 minutes** of inference-server occupancy fighting every real turn. That is the difference
  between "lazy on open, or just sweep the lot once Puma is up" and "don't build it" — and run 3
  settled which side we are on.
- **`Q_stamp_test`: regex the stamp shape.** `meta.json`'s `title` always holds *something*, and
  `ConversationStore#row` falls back to the stamp when it doesn't, so "is this still stamp-titled"
  needs a test. Decided: match `%Y-%m-%d %H:%M` against `stamp_title(created_at)` — one line, no
  schema surface, and a model title colliding with that shape is not a real case. The rejected
  alternative was a `title_source` key in `meta.json` (addable without a `SCHEMA` bump, since
  `#load_meta` ignores what it does not read); it is the better answer *once manual rename exists*,
  because it is what stops auto-titling overwriting a title the user chose. Rename is not built, so
  the key would be four lines carrying nothing today. **Revisit when rename lands** — at that point
  the regex is not enough, and existing conversations will need the key backfilled.
- **Sweeping needs the history, which is the expensive half.** A title wants the first user message;
  getting it means `Pikuri::Agent::History.load` per conversation, i.e. reading every history on
  disk at boot. Cheaper: sweep lazily (title a stamp-titled conversation when it is first *opened*),
  or cap the sweep to the newest N. Lazy is probably the whole feature — the sidebar rows a user
  actually looks at are the recent ones.
- **Never at boot proper.** `bin/pikuri-web-chat` already warms one conversation before Puma binds;
  a sweep there would delay the listen. After Puma is up, on the titler's own thread.

## Plumbing

- **`Q_titler_executor`: `turn_executor`, and the question has mostly dissolved.** Re-decided from
  scratch, as the (now removed) stale banner asked: the whole earlier argument — both the "own
  single-thread executor so a title does not consume a turn slot" plan *and* the rebuttal that a
  title is load the pool size must cap — rested on the pool being the load ceiling. It is not, and
  has not been since `D_throttle_at_the_request`: the ceiling is pikuri's `ServerPermits`, one permit
  per HTTP request, and `D_serial_turn_executor` has since made the pool **unbounded** and explicitly
  not a correctness device.

  So a title job gets a thread immediately, holds it ~1.2 s, runs no tools and issues one request,
  and the *permit* is what serializes it against real turns. Nothing is left to decide: post it to
  `turn_executor` like everything else. A per-title agent (above) holds no state between calls, so
  single-thread confinement holds at any pool size and no mutex is needed — which is the reason this
  never needed its own executor in the first place.

  **The recorded head-of-line consequence no longer follows** and is deleted: it was premised on a
  size-1 pool where a title queued behind a whole `run_loop`, tool calls included. Under permits, a
  turn off running `web_search` holds nothing, so a queued title uses exactly that window. The
  retro-sweep is still lazy-on-open, but now for its own reason (reading every history at boot),
  not this one.
- **Writing the title.** `ConversationStore#save` writes `meta.json` wholesale from
  `conversation.title`, and `Conversation` is a frozen `Data`, so a landed title has to reach both
  disk and the runner's `@conversation` (`#with(title:)`) or the next turn-end save reverts it.
  Either a `ConversationStore#retitle` doing its own read-modify-write of `meta.json`, or route it
  through `AgentRunner`. Both must respect the run-to-completion task rule.
- **Refreshing the sidebar is free.** `broadcaster.broadcast(event: :conversations, data: {})`
  already exists and every tab re-fetches the list through `app.js`'s one `refreshSidebar()`.
- **The seam.** A titler holding a `Pikuri::Agent` is pikuri-side, like `AgentRunner`; the title
  crosses as a `String`. Add it to `D_pikuri_free_core`'s "pikuri types used freely" list. The
  Faraday adapter is pikuri-side too, but **not** beside the titler: `Q_titler_params` puts it in
  `ModelCatalog`, which is already on that list, because `params` is a property of a *connection*
  and any conversation transport whose `[[llm]]` declares it should pick it up. (The earlier note
  here said the opposite — keep it away from conversation transports — which only made sense while
  thinking-off was titler-only plumbing rather than a config key.) `Config` stays Pikuri-free: it
  carries `params` as a plain `Hash` and names nothing upstream.

## Manual rename

The cheap alternative, and plausibly auto-title's escape hatch rather than a competitor: a pencil on
the row, `PATCH /conversations/:id`. Worth asking whether v2 should be rename *first* — though with
3–7 word titles landing this well from the model, auto-title looks like the stronger half now, and
rename is the "the model got it wrong" fix.

Delete has shipped the shape a rename should copy (`D_delete_no_undo`): a second submit button in
the row's existing form, aimed with `formaction` at `/conversations/:id/<verb>`, and a bare
`conversations` SSE event that tells every tab to re-fetch the list through `app.js`'s one
`refreshSidebar()`. A rename needs a text input rather than a button, which is the only part that is
genuinely new — and `ConversationStore` already owns `meta.json`, where the title lives. It also
wants the same "don't auto-title over this" mark the sweep above needs.
