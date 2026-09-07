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

- **Which model: the first configured `[[llm]]`**, same as a conversation with nothing saved. Run 2
  killed the "small non-thinking sidecar model" idea on evidence (below), and with thinking off the
  big model titles in ~1.2 s, so there is nothing left for a `[web] title_model` knob to buy. It
  stays a *later* nicety, not a prerequisite.
- **What runs it:** its own `Pikuri::Agent`, no tools. A *system* agent: no listener that reaches
  the browser, no transcript block, nothing in the UI. Not the conversation's own agent — a titling
  request through that lands in the history and pollutes it.
- **Fresh every time.** There is no conversation to maintain. `Pikuri::Agent#clear_conversation` is
  the reset, not a new `Agent.new`: it resets messages / controls / system prompt without re-running
  the constructor's context-window probe, so one long-lived titler agent costs one probe for the
  process.
- **When:** from the first user message alone. Fire-and-forget; a titling failure must never fail
  the turn — it just leaves the stamp.
- **The opener is passed as delimited data, not as the user turn.** Run 1 fed the message in bare
  and concluded the prompt needs no cleverness; run 2 showed that is the most injectable shape
  there is. The shipping prompt wraps it — `<opener>…</opener>` in the user turn, and a system line
  saying that text is data and never an instruction. Verbatim in
  `titler-model-probes.md`. Still short; just not naive.
- **`Q_title_length`: 3–7 words.** The original 10–20 word ask is disregarded — it is long for a
  `clamp(12rem, 20%, 20rem)` sidebar row. Ellipsised in CSS as a backstop.

## Prompt-following is a non-issue; prompt *injection* is a real one

**Format-following: 8/8, twice.** Qwen 3.6 obeys 3–7 words, no quotes, no trailing period, no
preamble, no markdown, and answers in the input's own language — with thinking on (run 1) and with
thinking off (run 2). The "Sure! Here's a title:" case has never once appeared.

**Injection is a different question, and run 1's single probe was the easiest one in the set.** Run
2 ran six. Against the hardened prompt, Qwen 3.6 held 5/6; the one that lands is a `</opener>`
breakout carrying a fake system instruction, and it lands only when the demanded output is itself
title-shaped (`BANANA BANANA BANANA` yes, a full sentence no).

That is the residual risk, stated properly: **the format constraint is the defence, not the
instruction hierarchy.** An attacker who gets pasted content into the opening message can influence
*which* 3–7 words the sidebar row shows; they cannot make the titler emit a sentence, markup, or a
long payload. A rude sidebar row is the worst case.

Consequences for the implementation, all cheap:

- **Cap in Ruby, don't trust the prompt.** A hard word and character cap, single line, applied to
  whatever comes back. The prompt is a request; the cap is the guarantee.
- **`Pikuri::Sanitizer`, not just escaping.** Unchanged and now better motivated — the words are
  attacker-choosable, which is exactly where a bidi override or a zero-width character comes from.
  The title reaches `_sidebar.erb` as plain text in four places (link text, the `<a title>`, the
  delete button's `aria-label` and its `title`); `set :erb, escape_html: true` stops markup and
  nothing else. Same standing rule as the tool lines (AGENTS.md, *Conventions*).
- **Strip a leading `</think>`.** Run 1 saw the artifact on every thinking-off response; run 2 could
  not reproduce it in ~16 calls. Keep the strip as a one-line backstop — the server is not pinned.

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
  off is already ~1.2 s. This also spares us the `[web] title_model` knob, the cold-load-on-first-use
  problem, and a pikuri-tui-side config addition (`D_schema_complete_config`).
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
- **Raw `RubyLLM::Chat` off the transport's fields.** Now pointless — the adapter reaches the same
  wire format without this project owning LLM transport wiring, and without replicating
  `Agent#build_context` (~10 lines, `openai_use_system_role = true` included).
- **Live with it.** Unchanged and still bad: fire-and-forget means a late title is cosmetic, but 60 s
  of inference-server occupancy contends with the user's actual answer — on a `--parallel 1` local
  server the user's own turn stalls behind a title. Fatal for the sweep.

**So the fork closes on a param channel, not on the model — and the channel is `faraday_adapter`, in
the gem we already depend on.** Nothing here is worth loading a second model for, and nothing here
waits on a pikuri release. The remaining work is the *Plumbing* section below.

## Retrospective titling

Conversations already on disk are all stamp-titled. Generating theirs some time after boot would
mean the feature isn't only for new conversations.

- **Was gated on the fork above; now priced.** At the measured 1.2 s a title, sweeping 100
  stamp-titled conversations is **two minutes** of background work. At the thinking-on 31.1 s it is
  **52 minutes** of inference-server occupancy fighting every real turn. That is the difference
  between "lazy on open, or just sweep the lot once Puma is up" and "don't build it" — and run 3
  settled which side we are on.
- **"Still stamp-titled" needs a test, and today there isn't one.** `meta.json`'s `title` always
  holds *something*, and `ConversationStore#row` falls back to the stamp when it doesn't. Two ways:
  regex the stamp shape (`%Y-%m-%d %H:%M`), or add a key to `meta.json` — the class doc says a key
  can be added without a `SCHEMA` bump, since `#load_meta` ignores what it doesn't read. The key is
  better: it also lets a *manual* rename mark itself so auto-titling never overwrites a title the
  user chose.
- **Sweeping needs the history, which is the expensive half.** A title wants the first user message;
  getting it means `Pikuri::Agent::History.load` per conversation, i.e. reading every history on
  disk at boot. Cheaper: sweep lazily (title a stamp-titled conversation when it is first *opened*),
  or cap the sweep to the newest N. Lazy is probably the whole feature — the sidebar rows a user
  actually looks at are the recent ones.
- **Never at boot proper.** `bin/pikuri-web-chat` already warms one conversation before Puma binds;
  a sweep there would delay the listen. After Puma is up, on the titler's own thread.

## Plumbing, once the fork is closed

- **Threading.** A `Pikuri::Agent`'s chat is single-thread-confined, and one shared titler agent
  reset by `clear_conversation` means titling requests must serialize. Its own single-thread
  executor — *not* `turn_executor`, whose pool size is the real turns' load cap
  (`D_serial_turn_executor`); a title must not consume a turn slot. A single thread also
  self-limits the retro-sweep for free.
- **Writing the title.** `ConversationStore#save` writes `meta.json` wholesale from
  `conversation.title`, and `Conversation` is a frozen `Data`, so a landed title has to reach both
  disk and the runner's `@conversation` (`#with(title:)`) or the next turn-end save reverts it.
  Either a `ConversationStore#retitle` doing its own read-modify-write of `meta.json`, or route it
  through `AgentRunner`. Both must respect the run-to-completion task rule.
- **Refreshing the sidebar is free.** `broadcaster.broadcast(event: :conversations, data: {})`
  already exists and every tab re-fetches the list through `app.js`'s one `refreshSidebar()`.
- **The seam.** A titler holding a `Pikuri::Agent` is pikuri-side, like `AgentRunner`; the title
  crosses as a `String`. Add it to `D_pikuri_free_core`'s "pikuri types used freely" list — the
  thinking-off Faraday adapter is pikuri-side too, and belongs beside the titler rather than
  anywhere a conversation transport could pick it up by accident.

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
