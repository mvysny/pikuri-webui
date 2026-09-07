# Conversation titles

Today a conversation's title is its start stamp (`ConversationStore#stamp_title`), rendered in the
sidebar. Two ways to make it say something: the model writes one, or the user does. The v1
conversation sidebar shipped without either; this is what "v2 auto-title" was in
`ideas/multiple-conversations.md`, which has graduated.

`meta.json` already carries `title` and the schema is versioned, so neither option needs a format
change — and the title deliberately never appears in the path, so retitling never moves a directory.

Research lives in `ideas/conversation-titles/` — the probe transcripts and the upstream citations
behind the thinking-off fork below.

## Settled

- **Which model:** the first configured `[[llm]]` to start with, same as a conversation with
  nothing saved, and a `[web] title_model` knob later. *Provisional* — the thinking-off fork below
  may pull that knob forward, because a small non-thinking model is the cleanest way out of it.
- **What runs it:** its own `Pikuri::Agent`, no tools. A *system* agent: no listener that reaches
  the browser, no transcript block, nothing in the UI. Not the conversation's own agent — a titling
  request through that lands in the history and pollutes it.
- **Fresh every time.** There is no conversation to maintain. `Pikuri::Agent#clear_conversation` is
  the reset, not a new `Agent.new`: it resets messages / controls / system prompt without re-running
  the constructor's context-window probe, so one long-lived titler agent costs one probe for the
  process.
- **When:** from the first user message alone. Fire-and-forget; a titling failure must never fail
  the turn — it just leaves the stamp.
- **The system prompt stays trivial.** "You summarize given sentences" territory. The probe's
  version is in the sidecar and needs no cleverness — see *Prompt-following* below.
- **`Q_title_length`: 3–7 words.** The original 10–20 word ask is disregarded — it is long for a
  `clamp(12rem, 20%, 20rem)` sidebar row. Ellipsised in CSS as a backstop.

## Prompt-following is a non-issue

8/8 probes against the configured local Qwen 3.6 obeyed 3–7 words, no quotes, no trailing period,
no preamble, no markdown, and answered in the input's own language. A prompt-injection attempt got
*titled* rather than obeyed. Full transcript: `ideas/conversation-titles/qwen-prompt-probes.md`.

Sanitizing is still needed, but for less than the original note assumed: cap length, single line,
strip a stray `</think>` (see below). The "Sure! Here's a title:" case did not appear once.

**And a title needs `Pikuri::Sanitizer`, not just escaping.** It reaches `_sidebar.erb` as plain
text in four places (link text, the `<a title>`, the delete button's `aria-label` and its `title`),
and `set :erb, escape_html: true` stops markup but not a bidi override reordering it or a
zero-width character hiding in it — the standing rule in AGENTS.md, *Conventions*, same as the tool
lines. Attacker reach is real: the title is derived from the user's own first message, which can
carry pasted content.

## The fork: thinking must be off, and pikuri has no channel for it

This is the blocking decision. Qwen 3.6 thinks *hard* about titles — ~1500 completion tokens and
30–90 s per title on the local 35B MoE. Turning thinking off is 11 tokens and 0.9 s. Two orders of
magnitude, and it decides whether the retro-sweep below is viable at all.

| how | time | completion tokens |
|---|---|---|
| baseline (thinking on) | 82 s | 1493 |
| `reasoning_effort: none` | 37 s | 679 — ignored, still thought |
| `chat_template_kwargs: {enable_thinking: false}` | **0.9 s** | **11** |

The catch: `chat_template_kwargs` needs `RubyLLM::Chat#with_params`, and `Pikuri::Agent` exposes no
extra-params channel — no `params:`, no thinking knob, and its `@chat` has no reader. So the options
are:

- **A smaller, non-thinking model — probably the answer.** A model that does not reason has nothing
  to suppress, so the fork simply doesn't arise: a plain `Pikuri::Agent` on it is fast *and* stays
  inside the scope rule, with no param channel, no `</think>` artifact and no upstream ask. The same
  server already serves two candidates —
  `unsloth/Qwen3-4B-Instruct-2507-GGUF:Q5_K_M` and `bartowski/Qwen2.5-7B-Instruct-GGUF:Q5_K_M`
  (`*-Instruct-*`, non-thinking by construction) — and its router reports `max_instances: 4`, so one
  can be resident beside the 35B. Titling is the easiest job in the app; a 4B is ample for 3–7
  words, and it also stops titles competing with real turns for the big model's slots.
  Unprobed as titlers — do that when testing resumes, against the same 8 messages.

  What it costs: the titler stops being "the first `[[llm]]`", so the config knob moves from
  *later* to *now* — a `[web] title_model = "<[[llm]] name>"` resolved through
  `ModelCatalog#find`, with the first connection as the fallback when it is unset or names
  something the file no longer has (the same shape as `missing_connection`). Note
  `D_schema_complete_config`: `Config` carries the whole shared schema, so this key is a
  pikuri-tui-side addition too, not a pikuri-web-only one. And a cold model load on first use —
  which the lazy retro-sweep below would hide.
- **Prompt-level `/no_think`.** Pure prompt, stays wholly inside `Pikuri::Agent`, no transport
  surface, no new dependency direction. Works on Qwen 3 — *untested here* (the probe was stopped
  before this variant ran; it is the first thing to try when testing resumes). If it works this
  fork closes with nothing owed upstream. Keeps the titler on the one configured model, so no
  config knob is owed yet — but it is Qwen-specific, and silently a no-op on any other model.
- **Raw `RubyLLM::Chat` off the transport's fields.** Fast and certain, but it means this project
  owning LLM transport wiring — against "All LLM transport … that's all pikuri. We own the web shell
  only." Also makes a llama.cpp/Qwen-specific param ours.
- **A feature request to pikuri:** an extra-params channel on `ChatTransport`, or an explicit
  thinking knob. The right long-term home — a titler is exactly the sub-agent case where reasoning
  is waste — but it blocks this on a pikuri release, and the gems are pinned to one minor
  (`D_released_pikuri_gems`).
- **Live with it.** Fire-and-forget means a title landing 60 s late is only cosmetic. The real cost
  is 60 s of inference-server occupancy contending with the user's actual answer — on a
  `--parallel 1` local server the user's own turn stalls behind a title. Bad, and fatal for the
  sweep.

`enable_thinking: false` leaks a stray `</think>\n\n` prefix into the content (llama.cpp template
artifact, seen in the probe). Any path that disables thinking must strip it.

## Retrospective titling

Conversations already on disk are all stamp-titled. Generating theirs some time after boot would
mean the feature isn't only for new conversations.

- **Gated entirely on the fork above.** At 1 s / 11 tokens a title, sweeping N old conversations is
  free; at 60 s / 1500 it occupies the server for minutes and fights every real turn. Don't build
  the sweep until thinking-off is settled.
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
  crosses as a `String`. Add it to `D_pikuri_free_core`'s "pikuri types used freely" list.

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
