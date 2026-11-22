# Decisions

Why this project is the way it is and not otherwise — FAQ-shaped: each entry is a question and
its current answer. Rewrite the answer when it changes; delete the entry when nobody asks any
more. An entry is earned by what it would cost to reverse, or by research the next person would
otherwise redo (cited as its `R_`). Not an entry: this red over that red, `get_foo` over
`is_foo?`, the testing library, the CI host, a version bump — a comment at the site of the
choice, or nothing; nothing about `design/` itself. A fork belonging to the *library* — the agent
loop, a tool, Interloper's delivery boundary — is argued in pikuri's own register, not re-argued
here. Cite by slug, `D_<slug>`, never by position; `grep '^## D_' design/decisions.md` is the
index. The first entry is the ruler: every later one trims to its length. When you have written
an entry, re-read it against the one above, check it says nothing the YARD headers already say,
and cut what is left over.

---

## D_no_js_build_step — Why no bundler and no JavaScript dependencies, and why is script mechanics rather than a renderer?

The size budget this entry first carried is gone and the test that replaced it is sharper; how
the client source is partitioned moved to `D_feature_owns_its_file`.

**Context.** The page needs an `EventSource`, form wiring, and a way to
place incoming fragments. That is the entire client-side job, because
Markdown rendering happens server-side in kramdown.

**Decision.** No npm, no bundler, no build step, no dependency. What
JavaScript is *for* here:

- **transport** — the `EventSource`, the `fetch` calls;
- **platform mechanics only exposed to script** — `showModal()`, `inert`,
  `scrollTop`, textarea measurement, `matchMedia`;
- **per-browser state that must never reach the server** — theme, draft,
  scroll position, which palette row is highlighted (`D_no_event_queue`).

And what it is never: a **renderer**. Markup or conversation content the
server could have produced is the server's, always. That clause is not new
— it is what `D_server_authoritative_transcript` and `D_replay_from_history`
have been resting on all along.

**Which file a function belongs in is not this entry's business** —
`D_feature_owns_its_file` owns that. The one clause of it this decision
cares about is `public/js/dom.js`'s: it knows no markup at all, because a
renderer is exactly what that file must never quietly become.

**The qualifier: rendering and state, not latency.** Read absolutely, "if the
server can do it, the server must" argues for fetching the slash palette's
filtered rows on every keystroke — the server certainly *can*. The filter,
the theme flip and the composer's auto-grow stay local because a round trip
would make them feel wrong, not because the server could not do them. The
rule governs where *rendering and state* live; it does not govern the
interaction loop.

**Rejected: a framework and a bundler** (or even a single npm
dependency). It would add a toolchain, a lockfile, a `node_modules` and a
build step to a project whose client-side job is a few hundred lines of
mechanics — and the toolchain, not those lines, is what would then need
maintaining. ES modules are the standing proof this costs nothing: `app.js`
imports `dom.js` with the browser resolving it, no bundler in sight.

**Consequences.** This is a live constraint on future work, not a
starting condition: if a change appears to need an npm package, the
answer is to render it on the server instead. It is also what keeps
`--dev` cheap (`D_dev_flag_no_reload`) — there is nothing to rebuild.

## D_gate_cookie — Why sign the gate cookie with the configured password itself rather than a stored secret?

Lands the remember-me half `D_one_password_gate` deferred.

**Context.** Measured on an iPhone, home-screen app: iOS does not keep
Basic credentials for a standalone web app between launches, so every
launch met the native dialog — and met it slowly, 5–10 seconds of blank
white while the 401 was digested. A password you retype on every launch
is a password that gets shortened until it stops being one.

**Decision.** Getting through the Basic challenge sets an `auth` cookie
of `<expiry>.<HMAC_SHA256(password, "auth|<user>|<expiry>")>`, and a
request carrying a valid one skips the challenge. The configured password
*is* the signing key, so nothing is stored server-side and no secret is
introduced; the window is 90 days, refreshed whenever a cookie is past
its halfway mark, so a browser in regular use never reaches the expiry.
HttpOnly, `SameSite=Lax`, and `Secure` only when the request arrived over
TLS — a `secure` cookie on a plain-HTTP LAN server is one the browser
accepts and then never sends back.

**Rejected: a server-side session store.** A table of live sessions is
the thing `D_no_event_queue` and `D_one_password_gate` both avoid, and it
buys nothing here: there is one credential, so there is nothing per
session to remember.

**Rejected: a login form instead of the Basic challenge.** It would kill
the *first* launch's blank screen too, and it is the road
`D_one_password_gate` rejected — a page to render, and `curl -u` stops
working. Reconsider only if the once-per-install prompt turns out to
annoy; the cookie half would not change.

**Rejected: setting the cookie from JavaScript.** Safari caps
script-writable storage at 7 days, which is the bug this entry exists to
fix, and it would put the password in reach of the page.

**Rejected: a configurable window.** One more key in `[web]` for a number
whose only wrong answers are "shorter than a habit" and "forever".

**Consequences.**

- The first launch after installing to the home screen still prompts, and
  still pauses on the blank screen while it does. That is once per
  browser, not once per launch.
- Changing the password (or the user) invalidates every outstanding
  cookie, which is the closest thing to a logout this app has — there is
  still no logout, and no way to revoke one browser alone.
- The cookie is a bearer token in the clear over plain HTTP, exactly as
  the Basic header was. It is not a smaller exposure, just a rarer one.

## D_one_password_gate — Why one config-file password behind the browser's own prompt rather than accounts?

Overrules the "shipping auth" rejection in `D_single_shared_conversation`; the cookie that
spares the prompt is `D_gate_cookie`.

**Context.** Reaching the page from a phone means binding off loopback,
and off loopback the port is the whole app: read, write and delete every
conversation, plus an agent with egress. The docs called that the
operator's risk, which is a warning nobody can act on — there was nothing
to configure. What is wanted is a gate on the port, not multi-user
support: the second person is still expected to run their own process
under their own OS account (`D_single_shared_conversation`).

**Decision.** One `user`/`password` pair in the config file's `[web]`
table, checked by `Rack::Auth::Basic` wrapped around the whole app. No
pair means no middleware at all, so the loopback default prompts nobody;
a bind off loopback with no pair prints a warning under Puma's banner and
starts anyway. The browser's own prompt is the
entire UI — no login page, no session, no logout, no lockout — and the
credentials it caches for the origin are replayed on the EventSource
too, so `GET /events` needs nothing.

**Rejected: per-user accounts.** The sentence
`D_single_shared_conversation` rejected auth with — "it would look like
multi-user support while delivering none" — is right about accounts and
wrong about a gate. A gate makes no claim about who is asking; it only
decides whether anyone gets in. Conversations stay shared, and the
README says so where the old warning stood.

**Rejected: a login form over a signed session cookie.** A page to
render, a secret to manage and a session concept in an app whose whole
shape is not having one (`D_no_event_queue`) — all to replace a dialog
the browser already draws.

**Rejected: a `--password` flag or an env var.** A secret on the command
line is visible in `ps` and in shell history, and the file already owns
every secret (`D_own_config_file`).

**Rejected: refusing to boot off loopback without a password.** `bind =
"0.0.0.0"` behind a reverse proxy that does the auth is a legitimate
deployment, and a refusal forbids it to protect against a mistake the
warning already names.

**Rejected: TLS of our own** (Puma's `ssl_bind`). Certificate lifecycle
for a chat shell; a proxy or a private overlay does it better, and the
warning points at both.

**Rejected: a `before` filter.** Middleware is what puts the gate in
front of `public/` as well as the routes.

**Consequences.**

- Basic credentials travel in the clear on every request, the long-lived
  SSE connection included. That is the accepted trade on a trusted LAN
  and the reason the warning names TLS; nothing here should ever be
  called "secure" without it.
- The deferred remember-me cookie was needed, and shipped:
  `D_gate_cookie`. The trigger fired on the first iPhone that tried it.

## D_namespaces — Why four namespaces cut by what a class produces, and why may a service never name `Web`?

**Context.** Nineteen classes sat flat under `PikuriWebUI`. Coupling was already
low — the wiring lives in `bin/pikuri-webui-chat`, and most classes named one or
two neighbours — so the question was purely where to draw lines, not how to
untangle.

**Decision.** Membership is decided by **what a class produces**, the SOA
frontend/service reading:

- `Web` — everything whose output is what the browser sees.
- `Agents` — running an LLM turn.
- `Conversations` — the conversation set: saved, resident, replayed.
- `Util` — knows nothing about this app.

`Config` and `BigAppLock` stay at the root because neither belongs to a half:
`Config` is read before anything else exists and carries the config file's
schema (`D_own_config_file`), and `BigAppLock` is *the* one global
mechanism (`D_global_monitor`) that every namespace asserts into. Filing either
under a namespace would assert an ownership that does not exist.

**The one-way rule is the load-bearing half.** `Web` may name anything under
`PikuriWebUI`; nothing under `Agents` or `Conversations` may name anything under
`Web`. A component reaching *down* into a service — or into pikuri — is the
sanctioned shape, so the permissive direction costs nothing; the closed
direction is what keeps a renderer from being summoned from inside the agent
loop. It held on the first pass but for one method, and the fix was an
improvement on its own: `Agents::Runner#trifecta_html` became
`Web::App` calling `Web::TrifectaView.render(runner.trifecta)`, so the runner
hands out the report and renders nothing. Today every crossing is an object
injected at `bin/pikuri-webui-chat` and held duck-typed, which makes the rule
greppable: no constant under `agents/` or `conversations/` names one under
`web/`.

**Rejected: cutting along `Pikuri::`.** The first proposal, and it is the
tempting one — the seam is already documented (`D_pikuri_free_core`) and a
grep would enforce it exactly. It is a *layering* cut, which is the thing
component-oriented design overrules: whether a class imports pikuri says
nothing about what it is for. It also put `Web::SseListener` — whose entire
output is HTML — on the service side, which is backwards. The seam survives as
what it always was, a rule about types reaching the browser, not a folder.

**Rejected: one `Service` namespace instead of `Agents` + `Conversations`.**
`Service` names a layer, not a subject. The split is also real: nothing in
`Agents` knows a conversation is a folder on disk, and nothing in
`Conversations` touches a transport.

**Rejected: folding `Util` into `Web`.** Two members is thin, and the risk is
that it becomes the drawer for whatever has no home. It earns its place by
having an admission test sharp enough to fail things — no block kinds, no
conversation, no route, no `Pikuri::` type, the same test `public/js/dom.js`
passes. `Web::ToolLine` and `Web::SlashCommand` are the classes that look small
enough to belong there and do not.

**Singular `Agent` was never on the table.** It would shadow `Pikuri::Agent`
for every file in the tree.

**Consequences.**

- **`Web` is not a thread boundary.** `Web::SseListener`, `Web::Transcript` and
  `Web::Broadcaster` are all touched from the turn worker under `BigAppLock`.
  Reading the namespace as "request thread only" is how an `assert!` guard gets
  dropped as redundant, so each namespace module states its own contract.
- **`Web::App`'s `:root` is three levels up**, not two. Sinatra derives `views/`
  and `public/` from it, and the move silently repointed it at `lib/`.
- **`PikuriWebUI::Conversations` sits beside the gem's `Pikuri::Conversations`**, a module
  beside a class of the same last name. Inside our namespace the gem's is always spelled out
  in full; renaming ours was not worth the churn of every cite.

---

## D_titler_connection — Why must titling name its own `[[llm]]` rather than fall back to the primary connection?

**Context.** A conversation was titled by its start stamp. Naming it from the
opening message needs a model, and the first instinct was to reuse the
conversation's own — "the first configured `[[llm]]`, same as a conversation
with nothing saved", with the measured 1.2 s a title (`D_llm_params_passthrough`)
as the argument that no knob was left to buy.

**Decision.** A knob after all, because that argument holds only while the
primary model *can* be made non-thinking. Thinking-only models are a real and
growing category, and the day someone's first `[[llm]]` is one, no parameter
rescues the feature — a second connection is the only exit. `[titler]` is that
exit. Referencing by `name` rather than an id is safe here where
`D_per_conversation_model` forbids it, because reference and referent live in
one file, edited together, and `.load` already enforces `name` uniqueness.

**Unset means off, never a fallback to `#primary_llm`.** So a file that says
nothing never spends 30 s of a thinking model on a sidebar row, an upgrade
brings no surprise inference load, and retro-titling (`D_lazy_retro_titling`)
is priced at 1.2 s a title or nothing, with no third case.

**Rejected: a hardcoded small sidecar model.** Probed and rejected on evidence,
and the premise was wrong twice over. `Qwen3-4B-Instruct` is fast (0.4 s) and
obeyed 4 of 6 delimiter attacks including a bare `PWNED`; `Qwen2.5-7B-Instruct`
answered in the wrong language 5 times in 8 (Turkish, German, Chinese) and
placed Australia's capital in Canada. The job is mostly instruction-following
rather than knowledge, so a 4B is not ample — and the speed case evaporated
anyway, because a 3B-active MoE emitting ten tokens with thinking off is
already ~1.2 s, of which most is prefill and HTTP. What is rejected is
*hardcoding* one, not *allowing* one: the whole point of this entry is that the
file chooses.

**Rejected: a `[web] title_model` key.** Titling is not web-specific — `[web]`
is how the port faces the network — so the table is top-level.

**Rejected: a flat `titler = "name"`.** A table gives a later word cap or
explicit off-switch a home without a second top-level key.

**Rejected: excluding the titler entry from `Agents::ModelCatalog`.** Its transport has
to come from somewhere, and picking it for a conversation is a legitimate thing
to want — a conversation that does not think. The cost of leaving it visible is
`D_shadowed_identity_pair`.

## D_llm_params_passthrough — Why does an `[[llm]]`'s `params` table reach the server verbatim rather than through named options?

The config spelling outlived the mechanism that first carried it, exactly as planned. The
Faraday adapter this project shipped first (`Agents::RequestParams`) is **deleted**, along
with our `faraday` dependency: pikuri grew the params channel this entry deferred asking for,
so the road logged below as "rejected: asking pikuri first" is now simply what happened. What
a parameter *means* stays nobody's business here — pikuri's own register carries that fork,
under opaque request params.

**Context.** Titling on the local 35B needs reasoning off, and that is not a
detail: matched benchmark, same eight openers and the same agent, only the
injected parameter differing — **1.2 s and 8 completion tokens a title against
31.1 s and 625**, i.e. 27× on wall clock and 83× on tokens. Thinking-off is also
the steadier (0.9–1.4 s against 1.5–72.2 s, a 48× spread on identical work) and
the safer: with thinking on, one of the eight put ~4000 characters of
chain-of-thought into `content` where a title belongs, and `reasoning_content`
did not catch it. Only `chat_template_kwargs: {enable_thinking: false}`
suppresses it, and `Pikuri::Agent` exposes no channel for an extra request
parameter.

**Decision.** Carry the parameter in the config as an opaque table keyed by the
*wire* spelling, and let the connection carry it to the server. The config
spelling was declared the part meant to last, and it was: `params = {
chat_template_kwargs = { enable_thinking = false } }` reads today exactly as it
did when a hand-rolled Faraday adapter was doing the merging, because pikuri's
`ChatTransport#params` took the same shape. Nothing in this repo parses,
validates or translates the table — `from_llms` passes it through and that is
the whole implementation.

**Rejected: `thinking = false` as the config key.** The obvious option, and the
one originally asked for. The wire spelling is not one thing — llama.cpp+Qwen
is `chat_template_kwargs.enable_thinking`, other GGUF templates spell their
kwarg differently, OpenAI is `reasoning_effort`, Anthropic is
`thinking: {type: "disabled"}` — so a boolean needs translating per provider
*and per chat template*. A wrong translation fails in the one direction that is
expensive here: **silently not applied**, which is the 4000-character essay
above. A key that promises portability and quietly does not apply is worse than
a key that says exactly what it sends. Sugar can still be added later, in the
shell's config parser rather than as semantics in `ChatTransport` — at the cost
of being written twice, once per shell (`D_own_config_file`).

**Rejected: `reasoning_effort`.** Accepted by the server and then effectively
ignored — `"none"` and `"low"` both still emitted a full reasoning block
(679–1070 tokens against a 1493-token baseline).

**Rejected: prompt-level `/no_think`.** Qwen 3.6 dropped Qwen 3's soft switches.
All three placements — system prompt, appended to the user message, prefixed to
it — emitted a full reasoning block, and upstream says the API parameter is the
supported route. The assistant-prefill variant (`<think></think>`) is dead more
interestingly: llama.cpp answers `Assistant response prefill is incompatible
with enable_thinking`, so prefill is available only once thinking is *already*
off and can never be the thing that turns it off.

**Rejected: making it the server's property instead, with no code at all.**
`llama-server` has the flags (`--reasoning-budget 0`, `--reasoning off`,
`--chat-template-kwargs`) and a router can alias one GGUF twice, so thinking-off
becomes a connection and the titler is just a second `[[llm]]`. Strictly
cleaner than the adapter — declarative, operator-visible, nothing
provider-specific in this repo — and still the right choice on a box with room.
It costs a second full copy of the weights in VRAM (~20 GB at Q4_K_M), because
each alias is its own process, and a swap-on-demand router does not help when
what you want is a title *during* a turn. The recipe stays available to anyone
with the VRAM; `params` is what works on one box.

**Rejected: reaching past pikuri to `RubyLLM::Chat#with_params` from here.**
Would make this project own LLM transport wiring and replicate
`Agent#build_context`, `openai_use_system_role = true` included, for a result
the adapter already reached. Note what this rejection was *not*: an argument
against `with_params` itself, which is precisely what pikuri now calls — the
objection was to this shell reaching around pikuri to call it.

**Deferred, then done: asking pikuri for the params channel.** Always the right
long-term home; deferred deliberately, because doing it upstream first would
spend a pikuri change *and* a pikuri-tui change on a design not yet run against
a real server, and the config file — the expensive half to change later — was
identical either way. Once the design had a live server behind it the deferral
expired, and the upstream change turned out to be a field plus one
`with_params` call. Keep the lesson, not the deferral: validate the config
spelling against a real server *before* spending a change in the library that
two shells depend on.

**Consequence — the silent failure is the *server's* now, and it is the one the
canary still watches.** The adapter's rot paths (a middleware reorder, a body
that is no longer JSON, a request that is not a chat completion) are gone with
the adapter; a well-formed table is merged before serialization, and a table
naming `messages` / `tools` / `stream` breaks the turn loudly instead. What
survives untouched is the failure that motivated `D_canary_severity`: a server
may accept a parameter and ignore it — `reasoning_effort` did exactly that — so
a short title is still never *assumed*, and the titler's caps and `</think>`
strip (pikuri-conversations' `Titler`) stay load-bearing.

**Consequence — `faraday` left the Gemfile.** It was declared only because
`Agents::RequestParams` subclassed `Faraday::Adapter::NetHttp`; nothing in this
repo compiles against Faraday any more, so the shell is back to naming no HTTP
library at all.

## D_shadowed_identity_pair — Why does the first `[[llm]]` declared win a shadowed `[model, api_base]` pair?

**Context.** `D_per_conversation_model` made `[model, api_base]` a
conversation's stored identity because a name is renameable and a model id alone
cannot tell two servers apart. The pair was assumed unique. The recommended
titler recipe (`D_titler_connection`) breaks that assumption: it is a second
`[[llm]]` on **the same model and the same server**, differing only in `params`.
`Config` cannot catch it — it enforces unique `name`, and two entries on one
pair are legal and now recommended.

**Decision.** Give the pair to the first declaration. Found by wiring rather
than predicted: `to_h` is last-wins, so shipping the recipe as written would
have reopened every saved conversation on the titler's non-thinking connection
and shown `qwen-titler` as the primary's name in the status bar. The shadowed
entries stay pickable and in `#rows`; what they lose is durability, because
`meta.json` stores the pair and nothing finer — a conversation picked onto one
comes back on the winner. Boot says which names that affects, ending "Expected
for a titler entry."

**Rejected: widening the stored identity to tell them apart.** A `meta.json`
schema change for a case whose entire point is that the two *are* one model on
one box.

**Rejected: keeping `to_h` and declaring the titler first.** Rests the whole
behaviour on config file ordering, which nothing states or checks.

**Why this needs an entry:** the fold reads as an arbitrary `.reverse`, and
`model_catalog_spec.rb` is the only other thing standing between a plausible
"simplification" back to `to_h` and the silent failure above.

## D_canary_severity — Why are reasoning tokens on a title diagnostic only, rather than grounds for discarding it?

**Context.** The degradation mode of a thinking-off parameter is *silently not
applied* (`D_llm_params_passthrough`), so it wants a signal. pikuri already
carries `thinking_tokens` per assistant message, which makes the signal exact —
`> 0` — rather than the threshold ("600 tokens or 30 s") first planned, with no
tuning and no false positive from a merely slow server.

**Decision.** Three separate things, which look like one:

- **It never affects the title.** The earlier plan — "prefer keeping the stamp
  over storing a suspect title" — must not hang off this signal, or it punishes
  an operator who *cannot* turn thinking off and accepts slow titles.
  Suspectness is a property of the string (over the cap, multi-line, carrying
  `</think>`) and the caps decide it. A thinking-on title is a real title.
- **Level by intent.** `params` declared and it reasoned anyway ⇒ WARN, a stated
  intent silently not applied. No `params` ⇒ INFO, a connection nobody steered
  doing what it was told.
- **Once per process, never per title.** A line on every title teaches the
  reader to filter it, which is how the regression it exists to catch goes
  unseen.

**Rejected: one fixed level.** WARN nags the operator with a thinking-only
model on every boot; INFO buries a real config bug.

**Known crudeness, accepted:** intent is read as "`params` is non-empty",
because a passthrough cannot know that `chat_template_kwargs.enable_thinking`
*means* thinking. This is `D_llm_params_passthrough`'s bill coming due, and it
costs one spurious line in a config that set `params` for something else.

## D_lazy_retro_titling — Why is a stored conversation titled at its next turn rather than by a sweep?

**Context.** Titling only new conversations leaves every conversation from
before the feature stamp-titled with no path to a name. A title needs the
opening message, and the obvious way to get one for an old conversation is to
load its history — which, done in bulk, means reading every history on disk.

**Decision.** Every conversation still carrying its start stamp is opened `untitled: true` on
pikuri-conversations' list, and the gem's titler names it from the history it already holds,
once a turn there has ended — a new conversation after its first answer, an old one at its next
turn. The per-conversation cost is zero until someone *uses* it, needs no second disk read, and
reaches precisely the conversations a person is working in. "Is this still stamp-titled" is the
store's `stamp_titled?`, comparing against the stamp the id was minted with.

**Rejected: titling on open**, what this shell did with its own titler: the history replayed
for the transcript was in hand, so an old conversation was named the moment anyone looked at it.
It went with the move to the gem, whose titler fires after a turn rather than beside one: on a
server with one slot, a title asked beside the first turn wins the permit and the answer waits
for it (~2 s, measured). After the turn, the turn's requests are done before the title asks. The
cost is that a conversation only read, never continued, keeps its stamp.

**Rejected: a bulk sweep after Puma binds.** Priced, and affordable — 100
conversations at 1.2 s is two minutes of background work — but it pays for
conversations nobody opens, and it reads every history at boot. (At the
thinking-on 31.1 s it would be 52 minutes of inference-server occupancy
fighting every real turn, which is what made this a gate rather than a
preference before `D_llm_params_passthrough`.)

**Rejected: a sweep capped to the newest N.** Same cost shape, plus a number
nobody can choose.

**Rejected: a `title_source` key in `meta.json`.** The better answer *once
manual rename exists*, because it is what stops auto-titling overwriting a name
a person chose. Rename is not built, so the key would carry nothing today, and
the stamp-shape test costs one line. **Revisit when rename lands:** the regex is
not enough then, and existing conversations need the key backfilled.

**Consequence — the opener is capped** (the gem's `Titler::MAX_OPENER_CHARS`): a conversation
from months ago can open with a pasted stack trace or a whole file, where a title still comes
out of the first sentence or two.

**Consequence — retry is per process, not per message.** The gem asks once per opened
conversation, so a title lost to an unreachable server is not retried on the next turn, but
*is* retried at a turn after the conversation is opened in a fresh process.

## D_max_concurrent_requests — Why does a `[[server]]` table size the permits rather than a `--turns` flag?

Refines `D_upstream_request_throttle`, whose `--turns` flag this deletes and whose "why size
explicitly" argument no longer holds.

**Context.** Two pressures arrived together.

The schema was authored in pikuri-tui
(`../pikuri-tui`, `Shared::Config`) and ported here: every
`[[llm]]` used to repeat its whole connection, so four models on one provider
meant the same URL and the same key written four times. The box and the model
are now separate tables, joined by an `id`.

Independently, upstream fixed the thing `--turns` existed for. That flag's
remaining duty was the permit count, justified by *"an `[[llm]]` carrying an
explicit `context_window` skips the `/props` probe, so its server would go
unsized, and unsized means unlimited."* That premise is now false: the probe
(pikuri-conversations' `Probe`, at a turn's start) is skipped only when the
cap is stated **and** the server is already sized. An unsized server always
gets probed, so it always gets llama.cpp's own `total_slots`.

**Decision.** Take the table, and let `max_concurrent_requests` carry the
ceiling alone. A server naming none is left to the probe. `--turns`, its `< 1`
check, and `Agents::ModelCatalog#servers` (whose only caller was the boot loop) all
delete.

**Rejected: keeping `--turns` as an override on top of the file.** The
precedence rule `D_own_config_file` exists to prevent, for a key the
file now has a home for.

**Rejected: `Shared::RequestPermits` as a class here too.** pikuri-tui extracted
one because three `App`s install permits; we have one boot script, so the loop
is six lines in it plus the log line that is the only visible confirmation the
ceiling took.

**Rejected: a spelling for "explicitly unlimited".** It would suppress the
probe, and the only server worth typing it against is a cloud endpoint the
probe already declines to answer for — where unsized already means unlimited.

**Rejected: defaulting an unsized server to 1 ourselves**, rather than letting
the probe answer. The probe reports what the *box* can do, and that is the
honest number for a registry keyed on the box; a shell substituting its own
opinion for the server's own report would be lying to every other consumer of
the `Throttle` in the process. The preference for 1 is real (below) but it is
advice about how to configure a server, so it lives in `README.md` where a
user reads it, not in a default that silently contradicts `/props`.

**Consequences.**

- **This reverses two published promises, both worth stating.**
  `D_upstream_request_throttle` rejected *"dropping `--turns` and trusting
  auto-sizing alone"* on the `context_window` argument above — upstream's fix,
  not a change of our mind, is what retired it. And
  the old promise that *"a first run against a stock llama.cpp needs no file
  at all"* is gone: there is no built-in connection,
  and `README.md`'s quick start now opens with the file to write.
- **The default changed, not just the spelling.** `--turns` defaulted to 1 and
  the loop ran unconditionally, so *every* server was sized at 1. Omitting
  `max_concurrent_requests` now means probe-sized, and unlimited only against
  a server that answers no `/props`.
- **So the recommended value is 1, and the README argues for it** — the one
  place where losing the old default costs something. A single user reads one
  conversation at a time, so what they feel is that reply's latency, not the
  box's throughput. The target hardware is what settles it: decode is
  memory-bandwidth-bound, and a large MoE is run on an iGPU against system
  DRAM precisely because what it needs is capacity, so there is no spare
  bandwidth for a second stream to hide in. MoE compounds it — batching grows
  the set of experts that must be read, un-skipping the weights the
  architecture exists to skip, and only pays at batch sizes a chat shell never
  reaches. `--parallel N` also divides `--ctx-size` by N, which this shell
  feels early because the whole history moves with the conversation. The probe
  reports `total_slots`, so a `--parallel 4` server left unsized gets 4 — the
  behaviour to avoid, reached by omission. Writing 1 also keeps the queue on
  our side of the wire, where the permit wait is cancellable and ■ lands on a
  parked turn.
- The permit key is safe against the two URL spellings: `Throttle.key_for`
  strips a trailing `/` and `/v1`, so `Server#url` as written and
  `Choice#server` (a normalized `api_base`, `/v1` included) name one server.
  That is why the loop could move off the catalog and onto the config.
- Boot now fails on a pre-`[[server]]` file, and the raise *is* the migration:
  a URL still in `server` earns a paste-ready `[[server]]` block built from it,
  with a stray `api_key` folded in.
- `Config.holds_secret?` had to move to `parsed['server']` in the same change,
  or a file full of plaintext keys would keep passing with the `chmod 600`
  advisory silently disarmed.

## D_upstream_request_throttle — Why does upstream ration the server while this shell only sizes it?

**Context.** This shell first throttled requests itself, with a Faraday adapter holding a
semaphore per `api_base` — an explicit stopgap that named its own retirement: the principled
home for a throttle is a control around the agent loop's requests, and that home is upstream.
It moved upstream twice: into pikuri-core (`Agent::ServerPermits`), then out of core into
pikuri-conversations as `Throttle`, which is the `Agent.new(around_request:)` hook every agent
the gem builds carries — its titler's included. pikuri's register, under the LLM request
throttle, and the workshop's under the throttle, carry the upstream argument.

**Decision.** Ration nothing here. The gem's `Throttle` does; this shell only sizes a server
with `Throttle.limit` from `[[server]] max_concurrent_requests` (`D_max_concurrent_requests`).

Upstream keeps the two properties the adapter was kept for — the permit's scope is exactly one
HTTP request (so a parent cannot deadlock against the sub-agent its tool spawns), and it spans
the whole streamed response — and fixes the two it could not:

- **The wait is cancellable.** A turn parked on a permit polls its `Cancellable`, so ■ lands on
  a turn waiting in the queue instead of after the server finally answers it.
- **The key is normalized.** `http://x:8080`, `.../v1` and `.../v1/` are one server, so two
  `[[llm]]` entries written differently share a pool instead of silently getting one each.

**Why size at all, when the probe auto-sizes.** The `/props` probe also reports `total_slots`
and seeds the permit count from it, so a zero-config local llama.cpp throttles correctly.
Sizing stays available as the operator's word about their own server — a ceiling below what
the box reports, or one for a server the probe cannot reach.

**Rejected: `Throttle.default` rather than `.limit`.** First-writer-wins rather than
authoritative. Boot runs before any probe so it would win in practice, which is exactly the
fragility — the file would be outranking the probe by timing rather than by decision.

**Rejected: keeping our adapter underneath as a belt.** Two throttles in series at N permits
each gate nothing the outer one doesn't, and are two sizings to keep in step.

**Consequences.**

- **The registry is process-global mutable state with its own `Mutex`** — `D_global_monitor`'s
  rule satisfied the way {Web::Broadcaster} satisfies it, not waived: it is a library's own
  thread-safety contract, touched from turn threads inside `run_loop`, never from a
  {BigAppLock} task.
- A turn parked on a permit reads `running`; the status bar cannot tell "generating" from
  "queued behind another conversation's request".
- A retried request holds its permit across ruby_llm's backoff, idling the
  slot for a moment — upstream's deliberate trade, so a re-enqueued request
  cannot pile in behind an original that is still generating.
- Sizing is per *server*, not per `[[llm]]`: two entries running two models on
  one box share its slots. That is where `max_concurrent_requests` sits
  (`D_max_concurrent_requests`); everything else about a connection is still
  per entry.

## D_pikuri_gem_sources — Why pikuri's released gems from RubyGems, but pikuri-workshop's git master?

**Context.** This shell tracks pikuri and pikuri-workshop closely, and both are pre-1.0. It ran
on pikuri 0.1.0 from RubyGems first, then on a path dependency on a sibling `../pikuri`
checkout, then on both repos' git masters while it needed surface no release carried: one agent
per conversation, `ChatTransport#params`, the tool display strings in pikuri; the whole of
pikuri-conversations in the workshop. pikuri 0.2.0 released its half on 2026-11-22; the
workshop has no release yet.

**Decision.** pikuri's `pikuri-core`, `pikuri-pdf` and `pikuri-web` from RubyGems at
`~> 0.2.0`; pikuri-workshop's `pikuri-conversations` from a `git … branch: 'master'` source.
The requirement admits patch releases only, because while pikuri is 0.x a minor release
carries breaking changes, and it is the one the workshop's gemspecs state
(`Pikuri::Workshop::PIKURI`): a workshop master that moves on to pikuri 0.3 fails to resolve
here instead of calling into a pikuri that lacks what it needs. `Gemfile.lock` pins pikuri's
versions and the workshop's commit, `bundle update pikuri-core pikuri-pdf pikuri-web
pikuri-conversations` moves both, and `rake check` verifies.

**Rejected: pikuri's git master, as before.** It bought surface ahead of a release, and now
nothing this shell uses waits on one. The workshop builds against pikuri's releases, so a pikuri
commit past one is a pikuri no workshop gem was tested with, and our pin had to be kept at or
past the workshop's by hand. A released gem also locks with a checksum; a git commit does not.

**Rejected: waiting for a workshop release.** The honest version of "wait" is "block this
change on a release cut to unblock it", between repos with one author. Master is what this
shell validates against in any case.

**Rejected: path dependencies on `../pikuri` and `../pikuri-workshop`.** A clone could not
build alone and CI had to clone the siblings itself. The lock pinned nothing, so whatever the
checkout held went into the build, and master could break this shell on any `bundle install`.

**Rejected: vendoring what this shell needs from upstream** — the throttle, the turn state
machine, the store. Each was built here first and moved upstream; a copy here is a third one to
keep in step.

**Consequences.**

- **A bump is a commit of its own**, the lock diff included. Each repo's `CHANGELOG.md`
  `**Breaking:**` entries carry the migration, and `rake check` is what says it is done. A
  pikuri minor release also edits the `~> 0.2.0` on the three Gemfile lines, and lands with the
  workshop commit built against it.
- **Editing the workshop alongside** is Bundler's local override, per machine and never
  committed: `bundle config set local.pikuri-conversations ../pikuri-workshop`. The checkout
  must sit on `master`, and the lock then follows its HEAD.
- **Editing pikuri alongside** takes a Gemfile edit instead, because Bundler's local override
  applies to git sources only: the three pikuri lines become one `path '../pikuri' do … end`
  block, which takes pikuri-html and pikuri-workspace from the checkout too, and both the
  Gemfile and the lock go back before a commit.
- **Revisit at the workshop's first release.** Nothing here argues against a pin in principle,
  so `pikuri-conversations` then goes to a version requirement too, a one-line change.

## D_both_forms_in_the_block — Why does a tool block carry the short line and the raw one both, with CSS picking?

**Context.** pikuri-tui shortens tool lines to
`WebSearch(rails 8 credentials)` / `OK, 4.2 kB` and keeps the raw form a
keypress away — its own register carries the reachability argument and
the machinery: a register of kinded blocks plus
`#rerender(kind:)` redraws every tool line on a flip, because a terminal
block is text that has to be recomputed. This shell rendered the verbose
form only.

**Decision.** {Web::ToolLine} renders **both** forms into every tool block —
two spans, `tool-short` and `tool-verbose` — and
`:root[data-tools='short'|'verbose']` shows one. The flip is one
attribute write plus a cookie: nothing re-renders, the server holds no
display preference, and a tab that flips disturbs no other tab.

**Rejected: `O_verbose_in_a_details`** — the short line as a
`<summary>`, the raw dump as the body. Tempting to the point of being the
obvious move, because `D_details_per_block` had just shipped the whole
mechanism. Three reasons it loses, and the
first is the one a future reader would not reconstruct: that entry
shipped with `:thinking` is the **only** kind that gets a disclosure, on
the argument that a disclosure is an inviting pattern to reach for — this
is exactly the reach it was written to stop, and reaching would leave the
rule meaning nothing. Then: the pair is *two* blocks, so a disclosure on
the call cannot carry the result's form and the mode would ship anyway;
and `transcript.js` would have to grow past its `.block.thinking`
selectors, which is markup knowledge in JS (`D_no_js_build_step`). The
deeper mismatch is that verbose is not *more detail about the same
thing*, which is what progressive disclosure is for — it is a second
rendering of identical data, and a mode is what a debugging session
wants.

**Rejected: `O_server_mode`** — the server holds one mode and re-renders
tool blocks on a flip. A display preference in server state, shared
across tabs; the objection `D_details_per_block` already makes to a
server-side visibility gate.

**Rejected: `O_mode_at_render_time`** — pick a form as the block is
created, no toggle. The one option that cannot be changed later without
touching the transcript, and it leaves the raw form reachable only
through git.

**Rejected: one `/view` dialog holding both view settings** (the TUI's
`u` submenu). Passed over for `/thinking` already: two independent live
toggles in a dialog that must not close on a click is a widget this app
does not have.

**Rejected: a drawer-footer button beside `#theme-toggle`.** Three
toggles there is a settings bar, and the drawer is about conversations.

**Consequences.**

- **The default look changes**, verbose → short: `Config#tool_lines`
  already resolved to `:short` with nothing reading it, and honouring the
  shared file means honouring that. Said out loud in `README.md` rather
  than left to be discovered.
- **The short form is the tool's, not ours.** It shipped as a guess —
  `CamelCase(first argument)` over the call, a measurement or the whole
  string over the result — because the event carried nothing better. It now
  arrives on the event: pikuri's `Tool#display_name` / `#describe_call` /
  `Result#summary`, composed where the structure still exists
  (pikuri's own register, under tool summary lines), which retired both
  guesses and the divergence from pikuri-tui the first version of this entry
  argued for — a calculator's `4` reads as `4` because pikuri's calculator
  says so, not because {Web::ToolLine} measures its length. What is left here is
  what only a renderer can do: defang the strings, and cap them to a width
  it alone knows.
- **Both forms sanitize, with no `inspect` carve-out** — the TUI exempts
  its verbose argument dump on the grounds that `inspect` escapes what
  matters, which is true of the terminal threat only: measured against
  Ruby, `inspect` passes bidi overrides, zero-width characters and
  homoglyphs straight through, and escapes exactly the `ESC` that
  HTML-escaping already renders inert. {Web::ToolLine}'s header holds the
  order the two passes run in.
- **`transcript.js` is untouched**, unlike Part 1 — no walk, no override,
  no mount-time resolve, because both forms are already in the DOM. The
  whole client side is one attribute write in `app.js`.
- The third presentational cookie, and the **second** of `D_theme_cookie`'s
  config-backed shape. One wrinkle `thinking` did not have: `show_thinking`
  is a boolean and cannot be nonsense, while `Config` checks
  `tool_lines`'s shape and not its vocabulary, so `Web::App.default_tool_lines`
  is the only thing between a typo in the shared file and a page showing
  both forms at once.
- The command is `/toollines`, not `/tools`; {Web::SlashCommand}`::CATALOG`
  holds why.
- **What the event's arrival did *not* retire is the `Error:` check.** The
  CamelCase helper and the first-value pick went the day pikuri composed
  those strings, but failure is still read off `content`'s prefix rather
  than off `summary` — {Web::ToolLine}`.for_result`'s rdoc holds why — and so is
  the cap, because a width is the renderer's alone to know.

## D_details_per_block — Why a disclosure per reasoning block rather than one global show-thinking switch?

**Context.** pikuri-tui hides reasoning behind one flag: `[ui]
show_thinking` sets the starting value and a toggle flips the whole pane,
drawing *nothing* where a hidden block was (its own argument —
grey filler earns nothing, and a terminal has no cheap per-block
affordance). Porting that shape was the obvious move.

**Decision.** Each `:thinking` block renders as its own
`<details open><summary>thinking</summary>`, and the preference sets
whether blocks start **open or closed** — never whether they exist. The
collapsed row is both the "reasoning happened here" signal and the way
in: short feedback that thinking occurred, subtle enough not to disturb
the conversation.

**So pikuri-tui's no-marker call inverts here, on its own argument.** The TUI
rejected a marker because a line you cannot click is filler. A browser
makes that same row clickable, which turns it from filler into the
affordance — it pays for its line twice. The preference also keeps one
meaning in both shells ("do I want reasoning by default"), expressed as
each chrome can afford: the TUI omits, the browser collapses.

`:thinking` is the **only** kind that gets one. A notice behind a
triangle is a notice nobody reads, and a disclosure is an inviting
pattern to reach for.

**Rejected: the straight port — one hide/show flip, no marker.** One CSS
rule, and it throws away the affordance the terminal lacked. "That answer
looks wrong, show me *that* step's reasoning" is the case that matters,
and a global switch cannot express it.

**Rejected: a server-side visibility gate** (the shape pikuri-tui's
density-thunk register serves). It would put a display preference in
server state, which is per-browser by decision — two tabs with different
preferences would fight over one transcript. The TUI needed that register
because a hidden region's text had to be *recomputed*; every block here is
already complete HTML in the DOM, so none of the machinery has an
equivalent and {Web::Transcript} gained nothing.

**Rejected: dropping `ThinkingDelta` while collapsed**, as the TUI does.
The server cannot drop a delta for one tab
and keep it for another without a per-connection filter, and
`D_server_authoritative_transcript` says the transcript is one picture.
The TUI dropped deltas to avoid *rendering* work on a hidden pane; the
cost here is SSE bytes on localhost. **The server always renders and
always broadcasts; the browser decides what it shows** — which is also
strictly better than the TUI, where a cancel mid-thinking while hidden
left only what had streamed revealable. Nothing is ever lost here.

**Rejected: brightening an open block's `<summary>`.** Tried, and
reverted after looking at it: the label then competes with the assistant
prose beneath it, inverting the hierarchy the muted reasoning tone exists
to establish. The rotated marker already says which state the block is
in.

**Consequences.**

- `open` is in the *stored* markup unconditionally, and that is not a
  default masquerading as one: the listener is per-*conversation* and
  shared by every tab reading it, while collapsing is per-*browser*.
  Expanded is the stored state so a browser running no script still shows
  everything. Who resolves it depends on how a block reaches the page: a
  streamed one is set by `transcript.js` before it is painted; the blocks
  `GET /c/:id` renders are folded *in the markup* by `Web::App#disclosed`
  (`Web::Disclosure.collapse`) when the cookie says collapsed, because the
  page paints before the module graph has loaded — a collapsed reader
  otherwise watches a screen of reasoning fold away, ~100 ms in, on every
  conversation switch. A CSS gate off `data-thinking` was the other
  candidate and lost: `details[open]` with its content hidden is a control
  that closes when clicked to open.
- **The runtime toggle is collapse-all / expand-all**, not
  default-for-future-blocks-only: `/thinking` sets every block, whatever
  was clicked, and moves the whole transcript. The alternative leaves the
  transcript in a mixed state nobody chose and stops the command feeling
  like a density control.
- **A disclosure change never touches the scroll; sending re-pins it.**
  Every disclosure change moves the document height — a global toggle by
  a lot — so a pinned pane can unpin and a scrolled-up reader's view can
  shift; tuile gave the TUI this free via `set_region_text`'s clamping.
  Yanking the view to the bottom after a deliberate click is plausibly
  worse than leaving it, so a click moves nothing. The cost shows on the
  *next* turn: expand a long block at the tail and the pane sits
  thousands of pixels above it, where `upsert` rightly declines to follow
  — so your own message and its answer land out of sight. Hence
  `transcript.follow()` on every send from this tab: a message you just
  sent is one you want to watch land. Revisit if a collapse leaves the
  reader staring at whitespace.
- The block-kind contract is **two** places for a change like this, not
  the three `AGENTS.md` names: a kind's markup travels inside the html
  payload, and `index.erb` and `transcript.js` wrap that payload in an
  identical div. Only the listener and `style.css` moved.

## D_details_survive_rewrites — Why does a rewrite keep a block's `<details>` rather than replace the whole html?

**Context.** `upsert` refills a block whenever a full frame arrives: a
stream's first and last, a snapshot, and every delta of a stream that fell
back to whole renders (`D_stream_blocks_once`) — at pikuri's 15 fps. A
reasoning block's payload is a `<details><summary>` around the body, so a
plain `innerHTML` swap destroys and rebuilds the summary about every 67 ms
while such a stream runs. The ordinary diff path (`stream`) never reaches
the summary at all.

**Decision.** When the block div already holds a `<details>` and the new
payload has one, `transcript.js` keeps the element and its `<summary>` and
swaps in only what follows the summary. The element's own `open` is then
the state: nothing to store beside it, nothing to re-apply. A fresh
`<details>` arrives `open` (the stored form) and is set to the browser's
default before it is painted; `/thinking` sets every block's `open`.

**The trap, which is why this is written down.** A click is a press and a
release on the *same* element. With the summary rebuilt at 15 fps, the one
under the pointer is usually a different element by the time the button
comes up, and the browser fires no click at all — the reader sees the
triangle ignore them. A synthetic `el.click()` or an instant scripted click
never straddles a rewrite, so the whole-`innerHTML` version passes a quick
check, and there is no JS runtime in this suite to go red
(`D_no_js_build_step`). Verified instead in Firefox against the real
module with a press held 120 ms: every click on a streaming block toggled
it, where the whole-html swap lost about half.

**Rejected: the whole-html swap with the state on the block div**
(`data-disclosure`, re-applied after each rewrite). It keeps a click that
lands from being slammed shut by the next delta, which is half the
problem; it cannot make the click land.

**Rejected: a slot class such as `.thinking-body`** for the part to
replace. That is this app's markup known in JS. Keeping the element HTML
itself defines — `<details>` and its `<summary>` — is platform semantics,
the same knowledge `open` already needed.

**Rejected: a state map keyed by block id.** The surviving element already
*is* the state, and a side table would need its own eviction on `#remove`
/ `#reset`. State dying with the element is a feature: a reopened
conversation starts fresh.

**Consequence.** The server-rendered snapshot never passes through
`upsert`, and `transcript.js` does *not* resolve it at mount either: the
script runs after the first paint, so any mount-time pass is a visible
fold. `GET /c/:id` serves those blocks already resolved
(`D_details_per_block`), and the `snapshot` frame refills them through the
same keep-the-`<details>` path, so a reader's clicks survive it.

## D_ui_cookie_over_config — Why may a `[ui]` cookie outrank the config file when nothing else may?

**Context.** `D_own_config_file` states it flatly: "anything the
file has a home for comes from the file and nowhere else — no flag, no
`ENV`, no project-local overlay — so there is never a precedence rule
between an override, the file and a conversation's saved model."
`[ui] show_thinking` is a key the file has a home for. A cookie that
outranks it looks exactly like the thing that sentence forbids.

**Decision.** The file supplies the **starting value**; a `/thinking`
pick writes a cookie that outranks it from then on, per browser. The
resolving distinction, and the reason this needed writing down rather
than assuming: **`D_own_config_file` governs the server's
configuration** — a connection, a key, a switch the agent runs on. A
density preference is *view state*, which `AGENTS.md` already partitions
to the browser ("each browser owns its own view state"). The file says
what a browser that has never expressed a preference sees; nothing about
the agent changes, and no two sources ever describe one connection.

This is also the shape pikuri-tui already has — its `[ui]` table sets the
default, the runtime toggle overrides and is never written back (a rule of
`Shared::Config`, not a decision entry over there)
— with the cookie standing in for the TUI's session.

**Rejected: a session cookie** (no `max-age`, dying with the browser
session). It maps *exactly* onto the TUI's never-written-back override
and sidesteps the argument above entirely. Passed over because it would
make this cookie behave differently from the `theme` cookie beside it,
which someone will later "fix" without reading this — and a web app
remembering a display preference across restarts is the less surprising
behaviour.

**Rejected: parsing `[ui]` for schema completeness and ignoring it.** A
`show_thinking = false` honored in the TUI and silently dropped in the
browser is worse than either consistent answer, and it makes the shared
config file a half-truth.

**Rejected: the file as the only source, no runtime pick.** A preference
you cannot change without an editor and a restart is not a density
control.

## D_subscribe_then_snapshot — Why does `GET /events` subscribe before it snapshots, and why is the snapshot one frame?

**Context.** Loading a conversation takes two requests: `GET /c/:id`
renders the transcript at T1, and the browser opens `GET /events` at T2 —
after HTML parse, module fetch and the EventSource handshake. A block the
agent finalized in between belonged to neither: too late for the rendered
snapshot, too early for the subscription. It was silently, permanently
missing from that tab until a reload.

Found by reading during the `D_no_event_queue` seam audit, not by a
report — which is the point of that entry's argument. The damage was
bounded but real: a streaming block self-healed, because every delta then
re-sent the whole accumulated source under one id, so only *finalized
one-shot* blocks were lost — `tool_call`, `tool_result`, `thinking`, the
assistant bookend, `notice`, `error`. Losing the tool line out of the
middle of a turn you opened the page to watch. Deltas are diffs now
(`D_stream_blocks_once`), which do not self-heal, so the one-task
subscribe-and-snapshot below is load-bearing for streams too.

**Decision. Subscribe first, snapshot second, and let the duplicate
absorb the race.** The route registers with the {Web::Broadcaster}, *then*
reads {Web::Transcript}`#to_a`, then writes that snapshot onto the connection
ahead of the drain loop. A block landing between the two is now delivered
**twice** rather than not at all, and a repeat costs nothing: the browser
upserts blocks by id, and {Web::Transcript} never reuses an id. A miss is permanent; a repeat is a
no-op. The seam closes on *ordering*, with no lock and no new mechanism.

**The catch-up is one `snapshot` frame** carrying the whole ordered block
list, which `transcript.js`'s `apply` places over what the page rendered
and then drops whatever the list does not name. The drop half is why the
frame is sent even when it is empty: the window can swallow a wipe too, and
a tab that rendered its page a moment before one would otherwise keep
showing blocks the server has forgotten.

**Rejected: `reset` plus one `block` per block** — the first shape of this,
and the source of a visible flash. Opening a stored conversation showed
the transcript, blinked its tail out, and put it back: the browser paints
between event dispatches, and the frames arrive across more than one read,
so `reset` emptied a pane the page had *just* rendered correctly and a
paint landed part-way through the refill. What is visible is the tail,
because the pane is scrolled to the bottom. One frame is one dispatch, and
placing a block whose html has not changed is invisible — so the fix is the
frame count, not a client-side diff. No spec here can catch this
(`D_no_js_build_step` — there is no JS runtime in the suite), which is why
`Web::App#catch_up_frames` says so in prose.

**Rejected: a lock shared by the writer and the subscriber**, so that
append-and-broadcast and snapshot-and-subscribe are each atomic. It works
and it is what the seam looks like it needs — but it puts {Web::Transcript}
and {Web::Broadcaster} behind one lock, which `D_no_event_queue` keeps the
broadcaster out of on purpose, and it buys nothing that ordering does not.

**Rejected: sequence numbers plus a replay buffer**, with SSE `id:` fields
and `Last-Event-ID` on reconnect. The real answer for a multi-client
system, and far too much machinery here: a ring buffer per conversation,
a retention policy, and a resume path to get wrong — for a single user on
localhost whose reconnects already reload (`app.js`, `es.reconnected`).

**Rejected: leave it, the reload covers it.** It does not. The reload
covers a *reconnect*; the first connection of every page load has no
reconnect to trigger it, and that is the common path. The reload also
lands right back in this same window.

**Consequences.**

- **SSE now carries a snapshot, not only deltas.**
  `D_server_authoritative_transcript` still holds — the server is still
  the only authority — but "GET renders, SSE deltas" is now "GET renders,
  SSE re-opens with the transcript and then deltas".
- **Every connect re-sends the whole transcript.** One extra pass over a
  conversation that was just rendered into HTML, and now one JSON payload
  the size of it. Acceptable on localhost; the refinement, if it ever
  matters, is for the page to pass its last block id and the route to send
  only the tail — which stays correct under the same ordering argument.
- **The client owns a whole-snapshot operation**, `transcript.apply`,
  distinct from the per-block `upsert` — and it is the one place that
  removes blocks it was not told to remove. `reset` stays a live event of
  its own, for the history load that {Web::SseListener} broadcasts it from.
- **The pane lands at the bottom on connect.** `apply` scrolls there
  unconditionally rather than sticking to where the reader is, because it
  runs once per page load and a conversation opens at its newest message —
  nothing else scrolls a freshly rendered page.
- **{Web::Broadcaster#frame} is public**, because the route writes catch-up
  straight onto its own connection and one place still has to own the wire
  format.
- **A conversation nobody has resident gets no catch-up** — there is no
  transcript to send, and `GET /events` deliberately does not mint one.

---

## D_feature_owns_its_file — Why does a feature that owns a slice of the page own a script file, rather than everything living in `app.js`?

`app.js` is down to the spine, the theme and the wiring. Whether a fifth file is coming is not
a question this entry answers — *Extraction is earned* below is the gate.

**Context.** `public/js/app.js` had no organizing principle beyond
"client-side". The composer's auto-grow sat three functions from the
palette's filter, both sat beside the sidebar's delete confirm, and the
only rule about where a function went was `D_no_js_build_step`'s "may name
elements and routes", which every function satisfied. Nothing in it was
wrong; it was a drawer, and a drawer is what a file becomes when the only
alternative is another drawer.

**Decision.** A feature that owns a slice of the page may own a file, and
then it owns that slice *whole*:

- **The file is paired with `views/index.erb`, and says so.** It looks its
  elements up by id, because those ids are the contract the template
  renders and there is no honest way to be loosely coupled to markup you
  are hand-in-glove with. `composer.js` owns `#composer` and everything in
  it — the buffer, the auto-grow, the palette, the keyboard — and owns
  `POST /messages` too, because what happens when you press send is the
  whole reason the feature exists.
- **`app.js` is the composition root.** What stays there is the page's
  spine — one `EventSource` demultiplexed to several features — plus the
  wiring *between* features. The slash `commands` map is the worked
  example: `/theme` is the theme's, `/new` the conversation list's, and
  only the root knows both, so a table of them is wiring rather than a
  leftover.
- **What crosses a boundary goes through the root**, never through the
  DOM: the composer is handed the conversation id (page state, from the
  URL) and hands back an `onsendfailed`, because `#status-state` is not
  its element to write.
- **`dom.js` is unchanged** — the one file that knows no markup at all.
- **Extraction is earned, not routine.** A file is justified when the
  outcome is clearly better code, which means a slice with enough
  behaviour to deserve a header of its own. A fifteen-line `theme.js`
  would be ceremony; the composer at ~230 lines and four concerns is not.

**Rejected: components decoupled from their markup.** The first cut of
`composer.js` was a `Composer` class handed its root element, finding its
parts by ARIA role (`[role="listbox"]`, the form's one `textarea`) so it
named no id — justified as reusability. Nothing will ever mount a second
composer, and paying indirection for an instance that will not exist buys
a *weaker* statement: `querySelector('textarea')` is true by accident
where `#prompt` is true by contract. Reverted before the pattern could be
copied into a second file.

**Rejected: enforcing the partition from the Ruby suite.** A spec can
slice `index.erb` and assert every id `composer.js` names sits inside
`#composer`. But these specs pin the *protocol* — what the server renders
against what the client names — and how the client source is split is not
protocol. A test with an opinion on file layout would make every future
split a spec change, and would be the sole enforcement of a rule whose
value is that it is a judgment call. `client_contract_spec.rb` therefore
scans the scripts jointly and says nothing about which one holds what.

**Rejected: prefixing every id with its feature** (`composer-prompt`,
`composer-menu`). The markup is already half-converted by accident —
`drawer-*` and `status-*` — and it would make ownership visible in the
HTML and in `style.css`. It churns a dozen CSS selectors for a rule
nothing enforces, and the bare ids read better in the stylesheet, which is
the other consumer. Revisit if two features ever want the same short name.

**Consequences.**

- `app.js` no longer names `#prompt`, `#slash-menu` or `/messages`.
- **Where the composer's edges lie is half-answered.** `statusbar.js` took `#cancel`:
  the id is the contract, not the nesting, so a button sitting in
  `#composer`'s markup belongs to whoever the status frame drives. The
  unknown-command dialog stays the root's — it is already reached through
  `onunknown`, which is wiring, and its `<template>` lives outside the
  form with the others.
- **The status bar is the store for the intended connection, and now says
  so.** `/model` used to read `#status-model-pending`'s text straight out
  of the DOM, legal only because both halves sat in one file; it now asks
  `statusbar.intendedModel()`. The DOM-as-store choice survives the split
  — the alternative, keeping the last status frame in the root, would have
  been a second copy of state the bar already renders.
- A moved function stops being covered by anything that scanned only
  `app.js`. `client_contract_spec.rb` reads every script joined, and
  globs `public/js/` rather than listing names — the `statusbar.js` split
  broke it on a hardcoded list, which is the failure mode the rule exists
  to prevent, so a split cannot quietly shrink the protocol check.

---

## D_icon_plate — Why does every rasterized app icon carry an opaque plate?

**Context.** *Who* the icon is was decided upstream — Kuri the pika in
the Talus coat, in pikuri's own register. What lands on
this side of that line is the consequence the drawing hands its hosts:
Talus is a mid grey (`#a89c8e`), so there is no ground it reliably
contrasts against, and each host has to say where the background comes
from. Under `D_target_browsers` the install path that matters is iOS *Add
to Home Screen*, and iOS composites transparency onto black — a
transparent PNG of a grey animal loses its dark eyes and whiskers into
the fill.

**Decision.** `kuri.svg` is the master: transparent, unplated, tight
`viewBox` on the art's own bounding square, for the README and anywhere a
bare mascot is wanted. Every *rasterized* icon is that drawing centred on
an opaque `#1e1f22` plate. The manifest stays a static file; the only
server-side change is registering the `.webmanifest` MIME type, which
Rack's table lacks and without which every browser refuses to parse it.

**Rejected: transparent PNGs, letting each platform supply the ground** —
on iOS the ground is black whatever the wallpaper, and on a white tab
strip a grey blob with a cream face is a smudge. The alternative was
re-opening the *coat* to suit the file format, which is not this repo's
decision to re-open. The plate is the price of the coat, paid where the
constraint bites; `../pikuri`'s own README still renders it unplated.

**Rejected: SVG-only icons, no PNGs at all** — tempting with no build
step, but `apple-touch-icon` does not accept SVG and manifest SVG support
is uneven enough that the install prompt is the wrong place to find out.

**Rejected: the icon set as a hand procedure**, a table of sizes in prose
for whoever next opens a rasterizer. A table that has to be retyped is a
*manual*, and prose is the one place a manual can be neither executed nor
tested. `bin/regen-icons` holds the geometry, the plate colour, the five
sizes and the maskable ear-clearance bound, and generates `favicon.svg`
too — so the sanctioned duplicate is no longer hand-maintained.
`D_no_js_build_step` is untouched: nothing runs it at boot or on request,
and the PNGs stay committed artifacts.

**Consequences.** `public/images/kuri.svg` is a **verbatim** copy of
`../pikuri/assets/kuri.svg` — byte for byte, comments and all, vendored
because this project ships its own `public/` and has no build step to
sync one. The library is the only source of truth for the drawing, so a
mascot change is re-copy then `bin/regen-icons`, never a redraw here; a
local tweak is lost at the next copy, and silently, because nothing
compares the two.

**This is a sanctioned exception to `D_theme_cookie`'s "nothing outside
`style.css` may read a raw colour", in two places, both unavoidable
rather than sloppy.** An icon is a *file*, rendered by a launcher that
never loads the page, so it cannot resolve a CSS token — `#1e1f22` is
baked into the plate. And `<meta name="theme-color">` is read by the
browser before any stylesheet applies, so `index.erb` writes the literal
for the resolved theme. Neither is a themed *surface*. A *third* raw
colour outside `style.css` should be argued for, not assumed from these
two.

---

## D_per_conversation_model — Why is a conversation's model `[model, server]` in `meta.json` rather than one process-wide setting?

**Context.** `Config` has always parsed every `[[llm]]`; only the first was
ever used. pikuri's half was done too — `Agent#run_loop(user_message:,
transport:)` applies a switch at the top of a turn, keeping history,
callbacks, tools and controls, and `apply_transport!` is *private*, so the
kwarg is the only way in. That is deliberate upstream: the chat is
single-thread-confined, and a background thread mutating the connection
mid-completion would tear an in-flight stream. The library cannot know
nothing is in flight; `Agents::Runner`'s state machine can. The pending-slot
shape was therefore **forced, not chosen** — the open question was only where
the *selection* lives and when it is written.

**Decision, in four parts.**

*Identity is the `[model, api_base]` pair* — never a name (one config edit
from changing, and not recoverable from a transport) and never a model id
alone (two `[[llm]]` entries may run one model on two servers). This is
pikuri-tui's `Shared::Model::Choice.key` ported into `Agents::ModelCatalog`, including
its fall back to the raw model id for a transport from outside the catalog.

*It lives in `meta.json`, written at turn end from the agent's own transport.*
{Agents::Runner#save}, the conversation's `Saver`, runs on the turn's thread before the
conversation goes idle; it reads the pair off `Conversation#status.model`, the transport the
agent is on, rather than off a selection — so the envelope and `history.json`'s last `model_id`
agree by construction.

*A reopened conversation is **opened** on its saved transport* — the factory resolves the
entry's `model` / `server` against the catalog and hands the result to the gem's `open`. A
pending pick is only ever a live switch.

*The status bar is the model's only surface, and reality there is free.* The gem moves a pick
onto the conversation's current transport only at the next turn's start, so
`status_data[:model]` — read off `status.model` — never advertises a model no turn has run on
yet. That is pikuri-tui's footer rule satisfied by construction rather than by a subscription.

**Rejected: deriving the model from `history.json`'s `model_id`** — it is a
model *string*, so it cannot carry the server half; `#row` would have to parse
every stored history to render one sidebar; and a conversation that inherited
a model but has not spoken yet has no `model_id` at all.

**Rejected: persisting at pick time.** A pick arrives on a request thread, so
this either exports history mid-`complete` or writes `meta.json` beside
`#save`, which `D_no_store_lock` forbids in as many words. For a conversation
with no turn yet it also writes the *commit point* over no `history.json` — a
listed conversation that cannot be opened. **Accepted cost:** a pick with no
message after it is lost across a restart.

**Rejected: opening on the default with a pick pending instead.** History integrity via
`model_id`-mismatched thinking signatures is a measured no-op on every backend we point at, so
that is not the reason. The reasons: the gem's boot probe asks the *wrong* server what inputs
its model takes, and a pick set on every reopen stops meaning "picked and not yet landed",
which is the meaning the status bar's arrow and the dialog's marker need.

**Rejected: a transcript block for a switch.** It would survive a reopen —
`History::Message#model_id` lets `Conversations::HistoryReplay` derive a switch boundary —
but that means two producers of one block, and two derivations disagree
eventually, so a reload would silently rewrite the transcript. The status bar
carries the model instead, leaving `Web::SseListener`'s `ModelSwitched` arm silent.

**Rejected: a synthetic bare turn to apply a pick early** — costs a round-trip
and draws the provider's own 400 against a prompt-only conversation on a
separate-system-field provider (Anthropic, Bedrock).

**No `ModelSwitched` subscription.** The gem reports the landing as `ModelPending(nil)` at the
turn's start, and the runner's status frame follows it; the agent's own `ModelSwitched` stays
silent in {Web::SseListener}.

**Consequences.**

- **Three readers, and they must not collapse into one.** The entry's
  `model` / `server` (what disk said when it was listed; the factory is its only
  reader), {Agents::Runner#model} (intent — `status.next_model`, what
  `registry.create(from:)` inherits), and `status.model` (reality, read only
  inside {Agents::Runner}). The *absence* of a runner-level reader for reality is
  what keeps a future convenience accessor from merging them.
- **The entry's pair is stale against disk by design** — `save` moves
  `meta.json` on and the Data never follows. Harmless because the factory is
  its only reader, at open.
- **The saved `server` is a URL, never a `[[server]]` `id`** — the same
  renameable-reference argument as the `name`, one step sharper: an id means
  nothing away from the config file that defines it, so a saved id is a
  reference whose referent the next edit can delete, where a URL stands on its
  own. `Config` resolves the reference into `Llm#server` and the id never
  leaves that class (`D_max_concurrent_requests`).
- **Half a pair is no pair.** An envelope predating this has a `model` naming
  the *boot* connection and no `server`, so `#row` reads it as having nothing
  saved and it opens on the default. No migration, no `SCHEMA` bump.
- **A switch onto a smaller window is accepted, not refused.** Nothing
  re-baselines the history, so 90k of conversation moved onto a 32k connection
  fails on the next turn; the dialog lists each `context_window` so the pick is
  informed rather than discovered, and that is the whole mitigation.
- **A saved connection gone from the config falls back to `primary_llm`, said
  only in the `/model` dialog** — not the transcript (a block absent from
  `history.json`) and not `supported: false` (which means "unreadable
  envelope"). Cleared on the first save or pick, by when `meta.json` holds the
  fallback and the note would describe a deviation from nothing.
- **`--server` / `--model` were removed ahead of this**, so there is no
  precedence rule between a flag, the file and a conversation's saved model.
  See `D_own_config_file`.
- **The catalog is a constructor argument, not a second wiring** — one factory
  still means one tool set, so the boot trifecta report stays true of every
  agent.

---

## D_slash_command_palette — Why is the slash-command catalog the server's and the palette the browser's?

`/model` (`D_per_conversation_model`) was the first command gated on the config:
`Web::SlashCommand.catalog(connections:)` drops it when there is nothing to pick between.

**Context.** pikuri-tui has a slash palette (`Shared::SlashMenuPopup`) and it
is the obvious thing to port: a list above the input, filtered as you type,
Up/Down + Enter. It is worth more on the phone than on the desktop, because
the drawer footer's two buttons — new conversation, theme — cost a drawer
open to reach, where `/theme` costs three keystrokes from where the caret
already is.

**Decision, in four parts.**

*The catalog is server-rendered; the dispatch is not.* `Web::SlashCommand::CATALOG`
renders whole into `#slash-menu` and the browser filters it by toggling
`hidden` per row. A command *runs* in the browser because most of them are
browser-side anyway (a navigation, a cookie, a dialog); `/model`, the one that
is not, still opens its dialog there and posts a name. Adding a command is
therefore a three-place contract — catalog, an arm, and a `<template>` for one
with a dialog — the same shape the block kinds have, and written down in
`AGENTS.md` beside them.

*The palette is the composer's; the arms are the app's.* The mechanics —
filter, highlight, resolving a buffer to a name — are the component's. What
each name *does* could not follow: `/new` posts a route, `/model` opens a
dialog over this tab's conversation, `/theme` writes a cookie, all of it page
knowledge the component may not hold. So `app.js` hands it a `commands` map
and the component dispatches into it. A name in that map which the config
gated out of the catalog is simply never rendered a row to reach it by — which
is how `/model` stays gated in the one place that decides it.

*A command never writes to the transcript.* This is where the TUI's design
stops porting: its `Web::SlashCommand#callback` returns a String echoed into the
conversation pane. Here the client-side form of that is conversation state the
server does not hold (`D_server_authoritative_transcript`), and the
server-side form is a block absent from `history.json` that
`D_replay_from_history`'s replay would silently drop — the line would show now
and be gone after a reload. So `Web::SlashCommand` carries no callback and no
outcome String; each command's own visible effect is the feedback.

*Every dialog is a real `<dialog>`, opened through one helper.* `showModal()`
gives modality, ESC, focus containment and `::backdrop` outright under
`D_target_browsers`, where the drawer had to hand-roll `inert` for the same
job. `dom.js`'s `openDialog(title, body)` builds the chrome, appends,
`showModal()`s and removes the element on close, so no dialog sits in the page
at rest.

**Rejected: `/dark` and `/light` as two commands** — the catalog would grow a
row per *value* of every future setting, and the picker is the shape `/model`
wants anyway. The cost is that `/t` stops resolving uniquely, which is
precisely the case a palette exists for.

**Rejected: `GET /commands?q=` per keystroke** — absurd for a three-item list,
and the worked example of `D_no_js_build_step`'s latency qualifier.

**Rejected: an HTML-string signature for `openDialog`.** The unknown-command
dialog interpolates *what the user typed*, so a string API would make that
caller a concatenation of user input — an escaping hazard designed into the
helper. Taking a `Node` cloned from a `<template>`, with values set through
`textContent`, makes the safe path the only path.

**Rejected: sending an unknown `/word` to the model** — a typo would silently
become a prompt. Enter on a leading `/word` matching nothing opens a dialog
naming the known commands, and the text stays in the composer to be fixed. The
escape hatch is the space: anything containing whitespace is never read as a
command, so `/usr/share/foo is broken` sends normally.

**Consequences.**

- **A bare `/` arms nothing.** It opens the palette as a menu with no row
  highlighted, so Enter sends rather than running whichever command sorts
  first — `/new` navigating away on a stray keystroke is not a thing that
  should be possible.
- **A message that is *only* a path** (`/etc/hosts`, alone, no other word)
  now raises the unknown-command dialog instead of sending. Accepted: this is
  a chat-only shell with no file tools (`D_chat_only_entry_point`), and the
  dialog names the fix.
- **`/trifecta` costs no route.** The report is static for the life of the
  process — one factory, one tool set — so it ships pre-rendered in a
  `<template>`, rendered by `Web::TrifectaView` from the unrendered report
  `Agents::Runner#trifecta` hands over. The rendering sits on the `Web` side
  because `Agents` may not name anything under `Web` (`D_namespaces`).
- **The theme picker's current marker is computed on open**, never
  server-rendered: the theme changes in the page after it was served.
- **Picking a row is a `pointerup`, not a `click`.** The row's `pointerdown`
  is prevented so the caret stays in the textarea — the blur would close the
  palette out from under the tap before it could land — and iOS answers a
  prevented pointerdown by synthesizing no compatibility mouse events at all,
  `click` among them, which is the only thing a non-interactive `<li>` had to
  fire on. So the phone's tap did nothing. `pointerup` is delivered by a tap
  and by a mouse release both, and is the row's *only* listener, so a desktop
  click cannot run the command twice.
- **Every send path is the form's `submit` event, and a command is resolved
  before anything is posted.** `/trifecta` tapped on ↑ opens the dialog
  exactly as Enter does; a command is never a message, whichever way it was
  sent. The resolution reads the *text* rather than the highlighted row,
  because tapping ↑ blurs the textarea and the blur has already emptied the
  palette's selection — the buffer is what survives that.
- **The phone's on-screen Return keeps inserting a newline**, matching the
  Claude iPhone app. Binding it to send was tried and reverted: it is the one
  keyboard with no Shift+Enter, so a Return that sends makes a two-line
  message unwritable. On the phone ↑ is Enter's send, and tapping a palette
  row is Enter's run.
- **Whether a modal is too much weight for a typo stays open.** It is intrusive;
  the alternative that keeps the intent is a status-bar note, for which
  there is precedent (`statusbar.say('not sent')`). Shipped as the dialog
  because it can list the known commands and a status line cannot.
  Revisit if it grates.

---

## D_one_shell_two_layouts — Why one `index.erb` for the phone and the desktop rather than two templates?

The phone layout is the Claude-Mobile shape: `#topbar`'s ☰ opens `#drawer` as a full-screen
conversation list, and the status bar drops to a line of text.

**Context.** The iPhone was the one target in `D_target_browsers` that
did not work, and the shape asked for is visibly a different screen from
the desktop's sidebar-beside-chat. The obvious move is a second template
picked per device.

**Decision.** One markup tree, two layouts, selected by `@media
(max-width: 40rem)` in `public/style.css`. `#drawer` *is* the desktop
sidebar column — the same element and the same `_sidebar.erb` partial —
restyled to `position: fixed; inset: 0`; `#topbar` and `#drawer-header`
are each hidden in the layout that has no use for them. Nothing is
per-device: resizing a window crosses the breakpoint live.

The breakpoint is **40rem**, not the 48rem it replaces, because iPad
portrait is 768px = exactly 48rem — so the old query matched on an iPad
and handed a *desktop* target the phone fallback.

**Rejected: a second `index.erb` (or `mobile.erb`).** Four arguments, any
one of which is close to sufficient:

- *The block-kind contract triples.* `AGENTS.md` **Conventions** already
  says a new block kind means touching {Web::SseListener}, `index.erb` and
  `style.css`. A second shell makes that four files forever, to buy a
  divergence that is one media query.
- *The scripts would have to branch.* They reach a dozen elements by id.
  Two shells means either the same ids in both — in which case the second
  file is a copy, not a variant — or per-layout branches in the one file
  whose whole premise is minimalism (`D_no_js_build_step`).
- *Choosing a shell means UA sniffing, and UA is the wrong signal here
  specifically.* iPadOS Safari reports as a Mac, so the one distinction
  this project's browser decision turns on — iPad counts as desktop — is
  the one the UA string lies about. Width is the real signal, it is free
  in CSS, and it stays testable by resizing a desktop window.
- *A response that varies by device needs `Vary`*, and cannot fix itself
  when the device rotates.

**The line, for the next time this comes up:** different *placement* is
CSS's; different *content* — a shorter transcript, thinking blocks
suppressed, a summarized view — would be a template's. If content ever
diverges, the split is by *fragment* (`_composer.erb`, `_topbar.erb`)
shared between two thin shells, never two copies of the page, and
selected by an explicit URL or cookie rather than by UA.

**Rejected: dropping the status bar on the phone,** which is what Claude
Mobile does. The queued count is load-bearing here — it is how a
mid-turn injection's wait is made legible
(`D_interloper_mid_loop_input`). It stays, as one line of
text; its two buttons move instead.

**Rejected: one button that is ↑ when idle and ■ when busy.** The
prettier phone composer, and it silently costs the feature: sending
mid-turn *injects*, so an arrow that becomes a stop button takes
injection away exactly when it is useful. Send and stop stay two
controls, stop revealed by `busy`.

**Rejected: the zero-JS checkbox drawer** (`:has(:checked)` and two
`<label for>`s) — it genuinely covers open, close and select, since
tapping a row is a page load. But a full-screen overlay that is not a
modal leaves the chat behind it tabbable and readable to a screen
reader, and `inert` is a DOM property, not a selector. `conversations.js`
owns the toggle for that one attribute's sake, and gets Escape-to-close
with it.
**Rejected alongside it: `<dialog>` + `showModal()`**, which would hand
over focus containment for free but has to be an in-flow sidebar on the
desktop and a top-layer modal on the phone; mixing the `open` attribute
with `showModal()` for that is worse than the ten lines it saves.

**Consequences.**

- **`+ new conversation` and the theme toggle now live in the drawer
  footer on *both* layouts.** They could not be duplicated per layout
  (one id, one element), and the phone's status bar is text-only. This is
  the one change the desktop sees, and it reads better anyway: starting a
  conversation belongs with the list of conversations.
- The breakpoint is written twice — `style.css`'s media query and
  `conversations.js`'s `matchMedia`, which closes the drawer when the
  layout changes so `inert` cannot strand a chat column nothing covers.
  They must move together.
- The composer is one auto-grown row on the desktop too, and its
  keyboard hint moved from the placeholder to a `title`: a paragraph of
  placeholder wraps to three lines at phone width, and Chrome sizes an
  empty textarea to its *wrapped placeholder*, so auto-grow opened the
  box at three lines before a character was typed.
- **Phone landscape is what a width-only query gets wrong.** An iPhone 15
  landscape is 852×393: it passes 40rem onto the desktop layout, with a
  20rem sidebar taking a third of the width and a 393px column holding
  transcript, composer and status bar. Unfixed on purpose — adding
  `(max-height: 26rem)` to the query is the cheap catch if anyone
  actually chats in landscape.
- **Verified in a resized desktop Chromium, not on a phone.** What is
  measured: the 40rem/48rem breakpoint against iPad portrait, 44px tap
  targets, auto-grow capping at 40vh, no horizontal page scroll at 320px,
  `inert`/Escape/resize-guard, both palettes. What a real iPhone still
  owes an answer on: `dvh` against Safari's shrinking chrome, the
  on-screen keyboard under `interactive-widget=resizes-content`,
  `env(safe-area-inset-*)`, and whether an always-visible per-row ✕
  mis-taps in practice (see `D_delete_no_undo`).

## D_no_store_lock — Why does the conversation store get no lock of ours?

**Context.** pikuri-conversations' `Store` — the folder of saved conversations, which this shell
wrote itself before the gem took it over — is `Thread-safe` in the narrow sense its header
states: it holds no mutable state past its constructor arguments. That is a true claim about the
*object*, sitting where a reader looks for a claim about the *folder*. Every mechanical argument
for wrapping it in a lock of ours is settled elsewhere:

- **N writers, audited clean.** Per-conversation agents (`D_conversation_owns_agent`) mean
  several turn-ends write at once, but into *disjoint subdirectories*, and one directory never
  has two writers because a conversation admits one turn at a time
  (`D_serial_turn_executor`).
- **Reads are already serialized where it matters.** {Conversations::Registry}'s calls —
  `list`, `find`, `create`, `delete` — run inside {BigAppLock} tasks; {Web::App} reaches the
  store directly only to stash and serve attachments, content-addressed files written by
  temp-file-and-rename.
- **The listing tolerates concurrency.** A listing row takes a read's own `ENOENT` as the
  answer instead of checking first, so a scan concurrent with a save or a delete is correct
  with no coordination.

**Decision.** No lock around the store, and no plan for one. What holds the folder together is
named in the gem's header: one writer per directory (the host's guarantee, which ours is), both
files written temp-file-and-rename, `meta.json` the commit point, and cross-call sequences
explicitly *not* atomic — `find` then `delete` has a gap and callers tolerate the conversation
vanishing inside it. `save` owns the whole write path, history included, which is what lets
this rest on "unnecessary" rather than "impossible": a lock that could guard only half a
directory would claim more than its mechanism.

**Rejected: a read-write lock.** It buys parallel readers, which pays only under read
contention with long critical sections; a listing is a directory scan of a few hundred `stat`s
for a single user with a handful of tabs. If a sidebar ever measures badly, the fix is the index
file the store's `list` already rejects, not a fancier lock.

**Rejected: a plain stdlib `Monitor` around it** (re-entrant, because `find` calls `list`).
Past the fact that it fixes nothing:

- It would serialize operations that are already safe to interleave.
- **It invites the false argument it was meant to prevent.** A monitor reads as *the* reason
  the folder is consistent, and the next reader relaxes the atomic rename or puts a `file?`
  check back — the only two mechanisms that work against a second process.
- It would be another lock, needing a documented ordering against the domain and the gem's.
- It would hold across `history.json` + `attachments/` — the longest filesystem operation here.

**Consequences.**

- **The trigger to reopen:** a store operation spanning two directories (a move, a merge, an
  index file), or a second writer to one conversation's folder. Either breaks the disjointness
  the audit rests on — and either is now a pikuri-conversations change first.
- **An in-process lock was never the answer to a second process** and cannot be sold as one
  (`D_no_multi_process_lock`).
- The one real bug the first audit turned up was not a store problem at all: a request thread
  holding a runner across a delete could resurrect the conversation, fixed as runner state
  ({Agents::Runner#discard!}) and written up in `D_delete_no_undo`. A store lock would not
  have caught it — a lock per method is not a transaction.

## D_no_multi_process_lock — Why no cross-process lock on the state root?

Nothing shipped: this is a decision *not* to build a cross-process lock.

**Context.** Two `pikuri-webui-chat` processes on different ports share
`~/.local/state/pikuri/pikuri-web-chat/conversations/`, and the store's
`save` rewrites `history.json` whole. The failure is *not* a torn
file — the save is temp-file-and-rename, so what is on disk is always a
complete valid history. It is a **silently clobbered conversation**: the
loser's turns vanish at the next save with nothing on screen to say so.
Since `D_delete_no_undo` there is a worse shape of it — process A deletes
a folder that process B still holds live, B writes it straight back at its
next turn end, and a conversation the user explicitly confirmed away
reappears in the sidebar.

**Decision.** Accept all of it. Last-writer-wins, no `flock`, no
enforcement anywhere; `README.md` states the limitation under
**Conversations** and that is the whole of the answer.

What settles it is that the second process **buys nothing**. One process
already serves any number of tabs, and a conversation owns its own agent
so turns in different conversations run undisturbed side by side
(`D_conversation_owns_agent`, `D_serial_turn_executor`) — there is no
capability behind a second port, only a second copy of the same
single-user tool pointed at the same home. A failure mode reachable only
by a configuration with no reason to exist does not earn a mechanism.

**Rejected: `flock` the conversation directory on open,** rendering the
locked row read-only in the sidebar. It is the *right* shape if the
collision were worth defending against — a dimmed row with a reason is the
affordance the busy-refusal already uses — but it puts per-conversation
lock state in the store, and file locks are the kind of state
that turns a hard kill into "why can't I open my own conversation".
Permanent cost, hypothetical benefit.

**Rejected: one `flock` on the state root at boot,** refusing a second
instance with the port named in the error. The cheap version — one lock in
`bin/pikuri-webui-chat` instead of per-conversation state — and it kills the
failure outright rather than degrading it. Still rejected: it converts a
mistake nobody makes into a startup failure everybody can hit (a stale
lock after `kill -9`, a supervisor restarting faster than the old process
exits), and it forbids the one second instance that is harmless, the one
that never opens the same conversation. Refusing to start is a worse
default than a warning in the README.

**Consequences.**

- The resurrection under `D_delete_no_undo` is now decided rather than
  deferred: it stays, and that entry's pointer resolves here. Its
  *in-process* twin — a request thread holding a runner across a delete —
  was a separate bug with a separate fix ({Agents::Runner#discard!}) and no
  bearing on this entry: one process cannot claim another's runner.
- The store never grows cross-process consistency from us. Its atomic
  rename remains all a concurrent reader outside this process gets, and
  the in-process locking question is independent of this entry — settled
  separately in `D_no_store_lock`, and an in-process lock never bought
  anything across processes anyway.
- **The one trigger that reopens this: a shared state root.**
  `D_per_shell_state_root` deliberately keeps each shell's conversations
  under its own folder, so today's only colliders are two copies of *this*
  shell. If a location shared with pikuri-tui or another shell ever lands,
  the colliders become processes a user has every reason to run at once,
  and the argument above stops holding. Locking is then part of that
  change, not a separate idea.

## D_no_event_queue — Why no owner thread and no event queue?

`D_global_monitor` has since answered the *Reopened* question at the foot of this entry — one
global re-entrant monitor, work as run-to-completion tasks. The core below stands — the
partition, browser-owned view state, the Broadcaster as an independent sink — but the
per-object locks this entry kept have been folded into that domain.

**Context.** The standing plan was to give all mutable state a single
owner thread, Tuile-style: every other thread posts a command, no locks,
because one thread touches the state. The complaint driving it was real —
`Web::Transcript`, `Web::Broadcaster` and `Agents::Runner` each held their own lock, and
cross-object consistency rested on a discipline nothing enforced. Three
options were on the table: **(a)** one lock per object, today's shape;
**(b)** one coarse lock over the whole state graph, Vaadin minus the
session axis; **(c)** one owner thread plus a queue, Tuile.

`D_conversation_owns_agent` shipped before the question came back, and
answered most of it: every exhibit that motivated (b) or (c) was audited
and found already fixed by the partition — the unguarded `Web::SseListener`
state (one listener per runner now), the `conversation_rows` tear (one
monitor), two of the three refusal routes (gone), and the claim that an
owner thread was the precondition for concurrent turns (false, see
`D_serial_turn_executor`).

**Decision.** Three parts, and the third is the one with a future in it.

**No owner thread, and no coarse lock either.** The partition does the
work: one agent, one history, one transcript and one listener per
conversation, and a conversation admits one turn at a time
(pikuri-conversations' `submit` injects rather than starting a second). Per-object
locks survive where they guard genuinely shared things — the registry's
monitor over the resident map, the broadcaster's over the subscriber list
— and each now guards one small thing with a stated owner, which is not
the failure the idea file opened by describing.

**This is a single-user server, and each browser owns its own state.**
No sessions, no auth, no accounts; a second person runs their own process
under their own OS account. What a tab holds — an unsent draft, scroll
position, the theme cookie, and *which* conversation it is reading — lives
in the browser and in the URL. Two tabs may read different conversations,
or the same one, and neither disturbs the other. The server holds the
conversations; the browser holds the view of them.

**If server state ever does become genuinely shared, it gets one global
mechanism — a single event queue, or a single lock — and never a
per-session one.** Stated now because the tempting wrong answer is
specific and has a famous precedent. Vaadin partitions its lock per
session because a session there owns a whole component tree; here a
session owns nothing, so a per-session lock would guard the empty set
while adding a session concept this app has deliberately refused. The
`Web::Broadcaster` stays outside whatever is built, in either shape: it is a
sink, its lock guards the subscriber list that request threads and the
`:state, :stop` hook touch, and folding it in would put a new tab's
subscribe behind a running turn and the shutdown path behind a wedged one
— the exact parked-thread hazard `D_shutdown_on_state_stop` prevents.

**Why there is no guidance to crib.** The absence is itself the finding.
Sinatra has no concurrency model and no server-side state model —
`session` is a signed cookie, so there is nothing to lock — and mainstream
Rack/Rails practice is to *not have this problem*: stateless processes,
shared state in Postgres or Redis, the database doing the locking. And in
that sentence the database is not storage, it is the *concurrency
architecture*: decompose ACID and it is this entry's whole subject —
atomicity is the work packet, isolation is the untorn cross-object read,
serializability is the total order. A Rails app has had an owner queue all
along, spelled `BEGIN` / `COMMIT`. Sinatra offers no opinion because the
opinion was always downstream of it; remove the database and a thread pool
is the entire remaining concurrency model. A live
in-memory object graph plus a worker thread is structurally a desktop app
that speaks HTTP, so the precedents are Tuile, Swing and Vaadin rather
than Rails. It is also why a global queue and a global lock are one
decision in two costumes: Vaadin's `UI.access()` *is* this design, with a
lock where Tuile uses a dedicated thread. The *coarseness* transfers; the
session axis does not.

**Rejected: build it anyway, because the current model is past
comfortable** — a good argument, and true when written, that loses to
every one of its exhibits being fixed by the partition instead. Rebuild
the case from *live* defects if it returns; the old examples are spent.

**Rejected: option (b), one coarse lock, as a cheap step toward (c)** — it
buys nothing once the state is partitioned, re-coarsening a graph just
split so one conversation's kramdown pass waits behind another's, and it
must be released across the LLM call and across tool execution anyway,
which is the interleaving reasoning it was meant to remove.

**Rejected: a per-session lock or queue, Vaadin-style** — a session here
owns nothing, so it would guard the empty set while adding the session
concept this app refuses. Recorded as a rejection rather than an omission
because it is what a reader who knows Vaadin reaches for first.

**Amended: the case that reopens this is *reproducibility*, and a
defect-shaped trigger could never have caught it.** Found by inspection,
in the runner's own turn state machine of the time: the step that moved a turn
from queued to running did not broadcast, so a turn that really waited for a
pool thread left the status bar reading "waiting for a free slot" until it
ended. It survived because the submit broadcast *after* posting the job and
the pool thread usually won the race to set running first — the frame was
right by luck. A lucky race making the system *usually* work is worse
than one that always fails: what it hides is unreportable ("sometimes the
status bar doesn't move") and, being a statement-level interleaving,
unreproducible on demand. Fixed by broadcasting on both of that step's paths;
the state machine itself has since moved into pikuri-conversations, whose
`Conversation` emits from one place per transition.

That is a better argument than the hygiene case rejected above, and a
different one. The value of one global queue is not that it serializes
but that it makes a **work packet atomic**: the system is only ever
observed *between* packets, never inside one. It does not buy determinism
— whether a submit lands before or after a turn ends is genuine external
concurrency, and both orders stay reachable — but it shrinks the
reachable set from arbitrary interleavings of *statements* to arbitrary
orderings of *actions*, and an action ordering is finite, enumerable and
writable as a test. This suite can already pin one interleaving, with a
gated transport holding a turn open; what it cannot do is pin one nobody
thought to look for.

**What still holds it off, and neither reason is comfort.** The owner
thread trades a defect class for a *blast radius*. "The owner must never
block" (below) is reviewable in a way that reasoning about interleavings
is not — the action bodies are a small enumerable set — but it is still
discipline nothing enforces, and the realistic breach is not a blocking
call, which review catches. It is head-of-line stalling behind a packet
that merely runs *long*, and two are already in hand: kramdown, which
`D_stream_blocks_once` runs at 15 fps, and the store's `save` at
turn end. Both sit on the agent thread today, where a stall costs one
conversation; behind an owner they cost every conversation at once. But
the cost is blast radius only, *not* diagnosis — and that asymmetry cuts
the other way from the paragraph above. A stall is a stable state holding
its own evidence: one dump of `Thread.list` backtraces names the packet
and the line. The race consumes its evidence instead, leaving a system
that has already moved on to a state that looks correct. A freeze you can
read; a lost frame you cannot.

And the seams turned out to want four different
tools. The audit that followed this entry found five and closed three
without a global mechanism: one by putting the broadcast where the
transition is, one by *ordering* (`D_subscribe_then_snapshot` — a seam
whose halves are two HTTP requests, which no server-side serialization
can reach), one with the monitor {Conversations::Registry} already held.
{Web::Transcript} had already solved a fourth the other way, with an immutable
`Block` snapshot no reader can have rewritten underneath it. What is left
was the runner's status frame: composed off unlocked state and handed to a
{Web::Broadcaster} that snapshots subscribers under its lock and pushes
*outside* it, so two threads can compose in one order and push in the
other, leaving the browser holding the older frame. One remaining site is
a site to fix, not an architecture — the audit's tally has since been
resolved and folded into `D_global_monitor`'s consequences.

**If one is ever built, these constraints come from decisions already
made** and would otherwise be rediscovered by hitting them:

- **The owner must never block** — not on I/O, a socket, a lock, or a
  reply from a thread that might be waiting on it.
- **The stall must be dumpable.** Ruby has no `jstack`, so the one
  advantage a freeze has over a race — that it holds still and keeps its
  evidence — is not free: a signal trap printing every `Thread.list`
  backtrace is what turns "it hung" into a five-minute read. Nothing about
  it waits for the owner thread, and the hazards `D_shutdown_on_state_stop`
  names — a parked `/events` drain loop, a graceful stop that never
  finishes — have exactly the same shape.
- **The agent loop keeps its own thread** (`D_worker_thread_agent_loop`);
  what changes is direction — it posts events instead of calling the
  listener stack inline.
- **Per-connection SSE queues stay.** One slow client must not stall every
  tab; owner → queue → parked writer is already {Web::Broadcaster}'s shape.
- **Every reply path gets a bounded wait and a 503,** or escapes replying
  altogether by publishing an immutable snapshot — {Web::Transcript}'s trick.
- **Backpressure is asymmetric:** blocking a request thread is fine,
  blocking the agent thread stalls a turn, and blocking `:state, :stop`
  recreates the bug `D_shutdown_on_state_stop` exists to prevent.
- **Rendering need not move.** `D_stream_blocks_once` re-renders through
  kramdown at 15 fps; the owner owns *mutation*, not rendering, so
  markdown → HTML can stay on the agent thread and post the finished
  string.

**Consequences.**

- **The trigger to reopen had to be structural, because a defect-shaped
  one cannot work here** — this architecture is good at *hiding* the
  defects that argue against it, so "wait for a live one" waits forever.
  The trigger was **a second site needing atomicity across two objects**,
  and it fired on the second: the runner's claim-running step, a state change
  and its notification, and its status frame, a read from one object and a
  publish to another. Both found by reading, neither by a
  report. The state-volume triggers never got the chance — more server
  state than the transcript and the resident runners, or a second writer
  to one conversation. Raising `--turns` was never one of them.
- **The snapshot-read design was taken, minus the queue.** {Web::Transcript}'s
  `Block` is a `Data`, so `#update` replaces rather than mutates and a
  caller rendering a snapshot cannot have a block rewritten underneath it.
  That was the one piece of the idea that stood on its own.

**Reopened: the target is atomicity, and the mechanism is open.** The
entry above framed the choice as "owner thread, coarse lock, or per-object
locks" and answered it on cost. The framing was wrong. What a database
gives a Rack app is not storage, it is A and I; this app removed the
database and replaced neither, so its seams hold by timing. The two
defects above are the evidence, and both were found by reading the code —
which is the point, because this architecture cannot *report* them.

**Scoped, because "we need ACID" over-buys.** D is already had:
the store commits by temp-file-and-rename with `meta.json` as
the commit point (`D_no_store_lock`), which is durability enough for a
single-user shell. C is domain invariants, and the partition holds most of
them. I is largely had for the same reason — one writer per conversation
(`D_conversation_owns_agent`). **A is the hole**, and specifically A
across a *seam*: two objects mutated or read as one unit. Anything built
should be sized to that and no larger.

**The mechanism is genuinely open, and no plugin exists.** Rack's contract
is `call(env)` — middleware is request-scoped by construction and has no
purchase on a graph that outlives a request — so there is no Sinatra
answer to adopt. Candidates in ascending cost: an atomic
helper per seam; one global `Monitor`; a true owner thread. Vaadin's
`UI.access()` is the middle one and Tuile is the last, as the entry above
already notes.

**What Node.js does and does not prove.** It proves the abstraction is
ergonomic at scale — a single loop is a design people ship on, not a
compromise forced by the lack of threads. It does *not* prove ACID: Node's
atomic unit is a synchronous run-to-completion, and every `await` is an
interleaving point, which is why read-modify-write races are ordinary Node
bugs. So Node is evidence for the mechanism and evidence that the
never-block constraint above is load-bearing — with one asymmetry that
matters here. Node enforces run-to-completion structurally: you cannot
block, you must `await`, and awaiting visibly yields. A Ruby owner thread
*can* block, silently, at any call. Node gets the discipline from the
language; we would have to get it from review.

## D_conversation_owns_agent — Why does a conversation own its agent, and a tab only own which one it views?

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
because both replay the same events into a fresh {Web::Transcript} — correct by
an argument spanning two classes, which is the kind of thing this codebase
keeps trying to delete. Minting on view costs one agent per conversation
*opened in a session*, which for a single user is nothing.

**Rejected: reaping idle runners.** Nothing is ever dropped except on
delete. Add reaping if residency ever actually hurts; a cleverer minting
rule is the wrong lever.

**Rejected: device continuity, and it was never wanted.** Mirroring's one
apparent benefit was that every browser showed the same conversation, so
opening the iPad landed you where the desktop was. Independent browsers
are the *goal*, not the price: two tabs reading two conversations is the
feature, and a view that follows you between devices is the same
behaviour wearing a friendlier name. So this is not a cost to be paid
back later — do not reintroduce global selection state to buy it. If some
future ask genuinely needs a landing spot better than "the newest
conversation" ({Conversations::Registry#default}), it is a per-browser
`last_viewed` cookie on the `D_theme_cookie` precedent, which leaves other
tabs alone; server-side last-viewed is this decision reversed.

**Consequences.**

- The registry and the store are now the only genuinely shared
  mutable state. The registry has a `Monitor`; the folder needs no lock of
  its own, for the reasons in `D_no_store_lock`.
- `Conversations::HistoryReplay.snapshot` became dead code and was removed.
- Rendering a detached conversation is not optimized: the
  accumulate-don't-render idea pays once several conversations stream at
  once, which `D_serial_turn_executor` allows. If it is
  ever built, the choice is already made and the two losing readings are
  why. *Render always, fan out selectively* (what ships today) re-runs
  kramdown at 15 fps for a conversation nobody is watching — the single
  most expensive thing the server does, per `D_stream_blocks_once`.
  *Drop the transcript and replay on attach* is cheapest while detached
  but shows a hole where the streaming answer is, because `history.json`
  holds no in-flight partial message. **Accumulate, don't render** wins
  by keeping the {Web::StreamingMessage} appends and the block structure while
  skipping the kramdown pass and the broadcast, then rendering once on
  attach — which works because `D_stream_blocks_once` already makes the
  HTML a pure function of the accumulated source, so it defers as easily
  as it moves threads. Open when it is picked up: whether
  the gem's `RateLimitedListener` should be wired at all for a detached
  conversation. Probably not — but a conversation's listener is fixed at
  `open`, so detaching means a switch inside the runner, not a new stack.

## D_serial_turn_executor — Why are turns unbounded, with no count of them a load cap?

**Context.** A turn blocks on the LLM for minutes, so it cannot run on a Sinatra request thread
(`D_worker_thread_agent_loop`). Once conversations own their own agents
(`D_conversation_owns_agent`), "how many turns at once" stops being implied by "how many agents",
and something has to decide whether that number is bounded.

**Decision.** Unbounded: every turn runs on a thread of its own, started by pikuri-conversations'
`Conversation` — one per boot, per turn, per title, per agent release — and nothing in front of
`submit` counts them. Sending always succeeds. The wait for the server is the gem's per-server
`Throttle`, taken around each HTTP request inside `run_loop` (`D_upstream_request_throttle`); a
turn parked on one reads `running`.

**Never rest a correctness claim on a thread count.** Single-writer safety comes from the
*partition*: per-conversation agents plus a conversation admitting one turn at a time (the gem's
`submit` injects rather than starting a second). Two turns are two agents, two histories, two
transcripts, two listeners and two disjoint folders, at any concurrency — which is why there is
no owner thread (`D_no_event_queue`). Audited when concurrent turns were first allowed:

- **The folder.** Two turn-ends write two *disjoint subdirectories*: the store's `save` touches
  only that conversation's directory, through a sibling temp file and a rename; the shared root
  is created in the constructor and otherwise only enumerated, and a listing concurrent with a
  save takes a read's own `ENOENT` as its answer.
- **The tool constants.** Every pikuri tool declares a sharing posture in its yardoc.
  `CALCULATOR` is `P_stateless`; `FETCH` and `SCRAPE` are `P_shared_benign`, sharing a
  process-wide URL cache whose race that doc argues is harmless; `web_search` is built per agent
  for its keys, but is `P_shared_locked` on class-level per-provider limiters.

**Rejected: a bounded pool sized to the server.** This shell ran turns on a fixed pool of
`turns * 2` threads first, a `--turns` flag beside it. A turn holds its thread for the whole
`run_loop` but a server slot only per HTTP request, so **any** number tied to the server's
capacity strands conversations behind turns that are off in a tool using no slot — doubling it
only moved the threshold. A bounded pool also deadlocks the day a tool spawns a sub-agent that
waits on the same pool, and holds a thread through waits that are not load at all (a human
confirming a tool call). The bound that matters is not a number: turns in flight cannot exceed
the conversations opened.

**Rejected: an unbounded pool of our own (`concurrent-ruby`'s `CachedThreadPool`).** What this
shell ran between the fixed pool and the gem. It was right about the size and wrong about the
owner: a pool here meant a turn state machine here too — `:queued`, claim-running, the restart
after a late injection, the cancel reset — rebuilt in every pikuri host. pikuri-conversations
owns that once, and a thread per task names itself (`turn <id>`) and needs no shutdown protocol.

**Rejected: deriving a bound by probing the server's slot count.** llama.cpp reports
`--parallel` on `/props`, and the gem does read it — to size the `Throttle` per request, which is
where a slot count means something.

**Consequences.**

- Shutdown drops whatever is running: saves land at turn end, and `Pikuri::Conversations#shutdown`
  from the `:state, :stop` hook cancels without waiting (waiting there would re-create the
  parked-thread bug `D_shutdown_on_state_stop` exists to prevent). Accepted — single user, rare
  restarts.
- Specs run turns on the gem's real threads and wait for them to settle (`settle` in
  `spec_helper.rb`), since there is no executor to swap for an inline one.
- **Concurrent turns buy overlapping inference, not overlapping search.** pikuri's search rate
  limiter holds its mutex across the HTTP call, so two agents searching at once serialize, and
  one tripping a provider's circuit breaker cools down the other — upstream's design
  (`P_shared_locked`), documented at the tool wiring.

## D_delete_no_undo — Why is deleting a conversation irreversible, with no undo and no trash?

**Context.** The conversation store grew every verb but this one, so
conversations accumulated until the user ran `rm -r`, which is what
`README.md` told them to do. Three things needed settling before a ✕
could go on a sidebar row: what confirmation looks like, what happens
when the deleted conversation is the *live* one, and whether the removal
is recoverable.

**Decision.** A native `confirm()` naming the conversation — one line of
`app.js` and the only option needing no CSS at all, where a modal
component is exactly the kind of thing that starts arguing for a build
step (`D_no_js_build_step`) — then a real removal: `FileUtils.rm_r` over the whole folder, `meta.json` unlinked
first. The conversation's runner is retired first ({Agents::Runner#discard!}): its live
conversation is closed, after which pikuri-conversations never saves it again, and a tab still
reading it moves to the newest one. Refused while a turn is in flight (409); an agent still
booting is cancelled instead, having saved nothing.

The conversation folder is ours end to end — nothing but pikuri and this
shell writes there — so a delete removes the directory wholesale. That is
deliberately unlike pikuri's refusal to sweep a single unreferenced
attachment (pikuri's own register, under history attachments): declining to delete a
*file* someone may have put beside the history is compatible with
removing the *conversation* it belongs to. Attachments are never shared
between conversations, so nothing is refcounted.

**`meta.json` goes first because it is `#save`'s commit point.**
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
  `conversations.js` exposes one `refresh()` that `reset` and the new
  event share; a future titles or search feature should reuse the same
  signal.
- The ✕ is revealed on hover and `:focus-within`, and shown
  unconditionally under `@media (hover: none)` — on a touch device the row
  itself is a link, so a tap opens the conversation instead of revealing
  anything (`D_target_browsers`). The reveal uses `opacity`, not
  `display`/`visibility`, or the button would leave the tab order and
  `:focus-within` could never fire.
- **Every row keeps its own ✕ on the phone, at 44px**
  (`D_one_shell_two_layouts`). *Rejected: the ✕ on the current row only.*
  It reads as a mis-tap defense, and there is already a `confirm()` by
  name in front of the delete, so a mis-tap costs a dialog and not a
  conversation — while a full-screen drawer has the width the 12rem
  sidebar did not. It also degrades badly: delete is refused mid-turn, so
  the row you are viewing is the likeliest one to be undeletable, and
  "only the current row is deletable" can mean nothing is. *Also
  rejected: an iOS-style `Edit` toggle* revealing all the ✕s — the
  fallback if 44px targets turn out to mis-tap on hardware, not the
  starting point.
- **A second process can resurrect what you deleted**, by saving its own
  live copy at the next turn end. Accepted as a limitation, and the
  strongest case anything made for a cross-process lock — which was
  weighed on exactly that basis and rejected in `D_no_multi_process_lock`.
- Nothing new serializes the folder. What keeps a delete from racing the
  turn-end save is the runner refusing while busy — see the bullet below
  for why that refusal had to become a *claim* rather than a read.
- **Dropping the runner is not enough; it has to be retired.** A request
  thread can hold a runner resolved in an earlier task, so a delete that only
  dropped it from {Conversations::Registry}'s map once let the next turn's save
  recreate the directory — the conversation the user confirmed away came back
  in the sidebar one turn later. The fix is {Agents::Runner#discard!}: the
  live conversation's `close`, which refuses while a turn runs and otherwise
  closes for good in one critical section of the gem's. Either a submit starts
  the turn first and the delete is refused, or the close wins and every later
  submit answers `:discarded` (404 from the route); and once closing, the gem
  never calls the `Saver`, so no save can follow. This is the *in-process* twin of the cross-process
  resurrection two bullets up, and unlike that one it was reachable by a
  single user with two tabs — which is why it is fixed rather than
  accepted.
- **Amended: the resurrection had a second door, and {Agents::Runner#discard!}
  could not reach it.** `discard!` retires the runner that is *already*
  resident when the delete lands. A caller that resolved the conversation a
  moment earlier and opened it *afterwards* minted a fresh runner instead —
  no runner existed for the delete to have retired — and that one came back
  in the sidebar as an unsaved resident, then wrote its folder again at the
  next turn end. Fixed by {Conversations::Registry#open_id}: resolve and open
  are one step under the monitor `#delete` already holds, so either the
  delete finds a runner to refuse or retire, or the open finds nothing to
  resolve. `#runner_for(entry)` is private, reached only by `#open_id` and by
  `#create`, holding a conversation it just minted. Found by
  reading during the `D_no_event_queue` seam audit, not by a report.
- Deleting is the whole answer to retention: still no cap and no
  auto-prune. `rm -r` on the state folder remains a complete reset.

## D_target_browsers — Why only Firefox on the desktop and Safari on iPad and iPhone?

All three targets have a layout (`D_one_shell_two_layouts`); the iPhone's is unverified on a
real device — see Consequences.

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

- **The iPhone has a layout, and it is still unverified on hardware.**
  `D_one_shell_two_layouts` is the shape and what it measured in a
  resized desktop browser; what it could not measure is exactly the
  iOS-specific half (`dvh` against Safari's shrinking chrome, the
  on-screen keyboard, `env(safe-area-inset-*)`).
- **A phone layout is not a phone *recommendation*, and the split is
  deliberate.** Reaching this app from a phone means `[web] bind` leaving
  127.0.0.1 with no auth and no sessions
  (`D_single_shared_conversation`) and an unencrypted conversations
  folder — a LAN bind hands the whole history to anything on the wifi.
  The layout exposes nothing on its own, so it shipped ahead of that
  question; what must not follow from it is `README.md` starting to
  suggest the phone, or a nice phone UI becoming the argument for a
  casual `bind = "0.0.0.0"`. The options nobody has costed: a bearer token
  the desktop prints as a QR code, basic auth over a self-signed cert
  (iOS trust-store friction), an SSH tunnel from the phone, a
  tailnet-only bind. An honest outcome is that none of them land and the
  README keeps saying "you are exposing your conversations, here is the
  key".
- **A PWA is downstream of that same question,** and only worth it once
  it has an answer: an installed icon that opens a dead page whenever the
  desktop is asleep is worse than a bookmark. It would need a
  `manifest.json` plus the legacy `apple-mobile-web-app-*` metas (verify
  what current iOS honours rather than trusting a note), and standalone
  mode removes the URL bar — which takes the shrinking-viewport problem
  with it, so the two halves are friendlier together than apart. **No
  service worker**: the page is a server-rendered snapshot of
  server-authoritative state (`D_server_authoritative_transcript`), so an
  offline shell would have no transcript to show.
- A change that needs a polyfill or a build step to reach a fourth browser
  is out of scope twice over — here and under `D_no_js_build_step`.

## D_replay_from_history — Why store only pikuri's history and re-derive the transcript, rather than save the rendered blocks?

**Context.** A saved conversation has two layers: the *model* half
(messages, tool calls, results, thinking, attachments — `history.json`,
written by pikuri-conversations' `HistoryFile`, whose contents we do not get a
vote on) and the *render* half ({Web::Transcript} blocks: kinds, ids, HTML).
Loading a conversation back means producing the second from something on
disk.

**Decision.** Store nothing beyond `history.json` and our `meta.json`,
and rebuild the blocks by turning each message back into the
`Agent::Event`s that produced it, fed through the real {Web::SseListener} into the
conversation's fresh transcript before its agent is opened on the same history — so there is
exactly one transcript, one renderer, and one event→kind mapping.

**Rejected: store the rendered blocks** (`blocks.json` beside
`history.json`). Exact reload, zero replay logic — and HTML strings on
disk, so a {Util::MarkdownRenderer} or `style.css` fix never reaches an old
conversation, plus two representations of one conversation that can
disagree. The longer these files live, the worse frozen HTML gets.

**Rejected: append an event log** (`log.jsonl`, source text not HTML)
and replay it. It keeps the today's-renderer property, but it prices
persistence on pikuri's *event set*: an `Event ↔ Hash` codec must cover
every variant {Web::SseListener} matches on and stay in step as pikuri adds
more — and pikuri changes them steadily (`Transient` and `HistoryLoaded`
both landed in one unreleased cycle, and `Transient` was gone again a few
cycles later). `History` is the opposite: written
down, `version:`-stamped, additive-only by decision, unknown keys
ignored. Betting the format on the stable one is not close. Nothing here
forecloses adding `log.jsonl` later if the losses below start to matter.

**Rejected: a `History → blocks` builder** instead of synthesized events.
Same output, one more place block kinds are decided — the
Web::SseListener / `index.erb` / `style.css` trifecta would stop being one.

**Consequences.** Only messages are stored, so what never became one is
gone on reload: `! cancelled` and run-loop failure blocks, and the
partial assistant text a cancel
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

## D_shutdown_on_state_stop — Why close the Broadcaster from Puma's `:state, :stop` rather than `at_exit` or Sinatra's INT trap?

**Context.** Ctrl+C hung for as long as a browser tab stayed open. Every
open `EventSource` parks a Puma request thread in the `GET /events` drain
loop; Puma's graceful stop waits for in-flight requests **with no
deadline**; and the 15 s SSE heartbeat keeps those parked writes
succeeding, so nothing ever errors the thread out. The wait ended only
when the browser finally dropped the connection. This is the bill for the
threading rule (`D_worker_thread_agent_loop`) — a design that parks
serving threads on purpose has to unpark them on purpose too.

**Decision.** The boot script registers on Puma's `:state` event and
calls `Web::Broadcaster#close` for `:stop` and `:restart`. That event is fired
by the server thread on the line *before* `graceful_shutdown`, which
makes it the last hook that runs on the near side of the wait.
`Web::Broadcaster#unsubscribe_all` became `#close`: the same sentinel push,
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
wait belongs in the same `:state` hook. `Web::Broadcaster#close` must stay
idempotent and must keep refusing new subscribers — the invariant lives
in its YARD header.

## D_dev_flag_no_reload — Why is `--dev` Sinatra's development mode rather than code reloading?

**Context.** A dev flag on a web server usually promises reloading. Here
it can't: the agent, its listener stack and the runner thread are
long-lived instances wired once at boot, so Ruby under `lib/` reloads in
neither mode and re-reading it would leave a live conversation bound to
the old objects. `public/js/*.js` and `.css` were always read per request
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

## D_theme_cookie — Why is theme a browser cookie resolved server-side rather than transcript state?

**Context.** Adding a light theme raised where the preference lives. The
transcript is server-authoritative (`D_server_authoritative_transcript`),
so "state lives on the server" is the house style — but this particular
state is per-*browser*, not per-conversation, and the page it affects is
kept live by one long SSE connection that a reload destroys.

**Decision.** Both palettes live in `public/style.css` as `--dark-*` /
`--light-*`, and the rest of the file reads only the semantic tokens
(nine at first, eleven since the send button — see Consequences); dark
stays the default under `:root`, and `:root[data-theme='light']` remaps
the same set. `GET /` resolves the
`theme` cookie against an allowlist and renders `data-theme` onto
`<html>`, so a light-theme user never sees a dark first paint. `app.js`
flips the attribute and rewrites the cookie in place.

**Rejected: a `POST /theme` route and server-held theme state.** A round
trip for a colour change means a reload, and a reload costs an SSE
reconnect — paying a transcript resync for a presentational toggle. The
cookie is deliberately *outside* {Web::Transcript} and stays presentational,
which is what lets "the transcript is server-authoritative" keep meaning
what it says rather than becoming "…except theme".

**Consequences.** The theme was the one piece of per-browser state in the
project, and it is the precedent a future per-browser preference should
follow. A new themed colour means adding it to both palettes *and* both
mappings; nothing outside `style.css` may read a raw colour.

**Amended: it is no longer the only presentational cookie.**
`D_details_per_block` added `thinking`, and it followed this precedent
almost exactly — cookie as the store, resolved server-side into a `:root`
attribute so the first paint is right, app.js rewriting both in place, an
unknown value falling back. The one place it *had* to differ: `thinking`'s
fallback is a **config value** (`[ui] show_thinking`) rather than a
constant, because that key exists in the config file and a shell
that ignored it would be lying about honoring the file. So
"presentational cookie" has two shapes — one with a default nobody can
configure, one whose default the file owns — and the difference is
whether pikuri's own config schema has a home for the preference.

`D_both_forms_in_the_block` added the third, `tools`, in the
config-backed shape. It also found the shape's sharp edge: a
config-backed fallback is only as good as the file's validation, and
`[ui] tool_lines` is validated for shape and not for vocabulary, so the
*reader* has to fall back too. A fourth one whose config key carries a
vocabulary owes the same double fallback.

`--send` / `--send-fg` are the procedure's first exercise —
the phone composer's yellow ↑ (`D_one_shell_two_layouts`). Two tokens
rather than one because the glyph needs its own value per palette, and
**not `--notice`**, tempting as it is for already being yellow:
`--notice` means "the agent said something noteworthy", and spending it
on a control muddies the kind→colour mapping that block kinds are
contracted on. Both palettes carry a real yellow with a dark glyph
(≥8:1) rather than a darkened one with white — the light theme's button
has to still read as yellow.

## D_chat_only_entry_point — Why does the trifecta promise belong to the boot script rather than to the project?

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
({Agents::Runner}, {Web::SseListener}, {Web::Transcript}, {Web::App}) — never as extra
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

## D_per_shell_state_root — Why does every shell keep its state under a folder named after itself?

Reverses the layout the first conversation-store commit shipped, which put `conversations/`
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

The folder is named after the script as it was first called,
`pikuri-web-chat`, and kept that name when the project was renamed to
pikuri-webui (the `pikuri-web` name went to pikuri's web-tools gem).
Renaming the folder would orphan every saved conversation or need a
migration, for nothing: the name only has to be unique among pikuri's
shells, and stable.

`bin/pikuri-webui-chat` derives a single `state_root` local and composes
every path from it, so the next thing worth persisting lands beside
`conversations/` rather than in a second place. The root is created by
the store at construction — the folder exists from boot, not
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

## D_own_config_file — Why does this shell read a config file of its own, carrying only what it reads?

Reverses the shared `~/.config/pikuri/config.toml` this shell used to read beside pikuri-tui.

**Context.** One file gave both shells one place for the connections and keys they both want,
and cost a schema neither owned. Each loader raises on an unknown key, so each shell carried every
table the other grew — `[code]`, `[[code.mcp]]` and pikuri-tui's `[ui]` keys here, `[web]` and
`[titler]` there — and a key added on one side stopped the other from booting until a cross-repo
sweep caught up. It happened in both directions: `[ui]` broke this shell, `[titler]` and `params`
broke pikuri-tui. `[ui]` went lenient to survive it, and
`tool_lines` could not be checked against the forms `style.css` renders, the vocabulary being the
other shell's.

**Decision.** `$XDG_CONFIG_HOME/pikuri-webui/config.toml`, layered over
`/etc/xdg/pikuri-webui/config.toml`, and nothing else. {Config} carries the tables this shell
reads, strict throughout: an unknown key anywhere raises with its path, a table only pikuri-tui
reads included, and `[ui] tool_lines` must name a form `style.css` can show. The folder is named
after the project, not after the script as the state root is (`D_per_shell_state_root`): a config
file has no saved data to strand, so it takes the name a user would guess.

Kept from the shared file: anything the file has a home for comes from the file and nowhere
else — no flag, no `ENV`, no project-local overlay — so there is never a precedence rule between
an override, the file and a conversation's saved model. A flag is visible in `ps` and shell
history, `ENV` is inherited by every subprocess pikuri spawns, and a project-local file is
git-committable, so `--api-key`, `--api-key-env`, `--server`, `--model` and `--turns` stay gone.
There is no built-in connection either: no `[[llm]]` raises with `EXAMPLE_CONFIG` and the path to
write it to.

The same rule took `--port` and `--bind` into `[web]`, beside the base path and the password —
the table about how the port faces the network. A flag next to the key would be exactly the
precedence rule above, and the off-loopback warning already pointed into this table for its fix.
The bind default stays `127.0.0.1`. `--dev` stays a flag because it says how one run is launched,
not where the deployment lives (`D_dev_flag_no_reload`).

**Rejected: keeping the shared file and carrying the whole schema.** Its standing obligation — a
config addition in pikuri-tui is a pikuri-webui change — is a procedure nothing enforces, and
each time it was missed the symptom was a shell that would not start.

**Rejected: reading the old file as a fallback.** A second location is a second source, with a
precedence rule between the two. The no-connection raise names `~/.config/pikuri/config.toml`
when one is there instead: the raise is the migration, as it is for a pre-`[[server]]` file.

**Consequences.** A machine running both shells writes its connections and keys twice — the
duplication the shared file existed to remove, accepted for two shells that now boot
independently.

## D_base_path_mount — Why does `[web] base_path` mount the app, rather than trust a proxy to strip the prefix?

**Context.** One HTTPS name on a tailnet serves several apps by path, `https://host/pikuri-webui/`,
and `tailscale serve --set-path` strips the mount point before proxying unless the target names it
again (`R_tailscale_serve_path`). Every URL the page carried was root-absolute, so the first click
left the mount whichever way the proxy was set.

**Decision.** `base_path` is a context root: {Web::Mount} serves the app under it and only under
it, moving the prefix from `PATH_INFO` into `SCRIPT_NAME`. The proxy sends the prefix on
(`tailscale serve --set-path /pikuri-webui http://127.0.0.1:4567/pikuri-webui`), and the same URL
works straight on the port. Every URL starts with the prefix, taken from whatever knows it:

- markup and redirects through Sinatra's `url` / `to`, off `SCRIPT_NAME`;
- script-built ones off `data-base`, which `app.js` reads once and hands each feature;
- the image links {Web::SseListener} renders on a turn thread, where no request is there to ask,
  off {Config#base_path};
- cookie paths — the gate's off `SCRIPT_NAME`, the view preferences' off `data-base` — so a host
  serving other apps beside this one never hands them ours;
- the manifest, whose URLs are relative to itself. Its `id` is omitted: `"/"` resolves against the
  origin and would claim the whole host, while the default, `start_url`, is the same `/` at the root.

A request outside the prefix is a plain-text 404 naming the fix — never a redirect to the prefix,
which loops behind a proxy that strips it.

**Rejected: routing at `/` and treating `base_path` as the public prefix only** (the proxy strips,
the app prepends). Every link a direct visit to the port renders would then point at a path the
app does not answer, and which way a deployment works would hang on a proxy setting the app cannot
see — Tailscale sends no `X-Forwarded-Prefix` to learn it from.

**Rejected: accepting a request with or without the prefix.** One more mode to explain, and a
prefix whose first segment is also a route's (`/c`, `/js`) becomes ambiguous.

**Consequences.** A root-absolute URL works in development and breaks only behind the proxy, so
`client_contract_spec.rb` fails any script URL, navigation or cookie path not built on `base`. A
path is not an origin: cookies scoped by path stop the browser sending ours to a sibling app, but
a script on a sibling path is same-origin with this page, and the gate and the CSP are all that
stand between them.

## D_diagnostics_to_stderr — Why do diagnostics stay on stderr rather than reaching the browser?

This *reverses* a design that shipped in the original scaffold: `LogIO`, a Ctrl+L toggle and a
collapsible in-page log panel, all removed.

**Context.** The scaffold piped pikuri's per-subsystem loggers and
`PikuriWebUI.logger` into a collapsible panel in the page, on the theory
that a browser front-end should be self-contained. In use it made the
transcript ambiguous: two unrelated streams — the LLM conversation and
the program's internal diagnostics — shared one surface, and the panel
needed its own capture machinery (`LogIO`), its own block kind, its own
keybinding and its own CSS to keep them apart.

**Decision.** The transcript shows the LLM conversation only — assistant
Markdown, reasoning, tool-call lines, tool observations, all driven by
{Web::SseListener}. Internal diagnostics stay on their default stderr sinks
and never reach the page. Never cross the streams.

**Rejected: the in-page log panel** (as shipped). The operator running
`bin/pikuri-webui-chat` already has a terminal; routing stderr through a
capture object, an SSE frame and a DOM node to arrive back in front of
the same person is machinery bought for nothing, and it is machinery that
every new block kind and every theme change then has to carry.

**Consequences.** {Web::SseListener} renders *events*, never log lines, and
`PikuriWebUI.logger` must never be pointed at the {Web::Broadcaster}. A future
"show me what went wrong in the browser" want is a new decision, not a
resurrection of `LogIO`.

## D_worker_thread_agent_loop — Why does the agent loop run on pikuri-conversations' threads rather than on a request thread?

**Context.** The agent loop blocks on the LLM for the length of a turn.
Sinatra hands each request a pooled Puma thread.

**Decision.** pikuri-conversations runs each turn on a thread of its own, never on a request
thread; a request only calls `Conversation#submit`, which returns at once. The listener writes
into thread-safe sinks ({Web::Transcript}, {Web::Broadcaster}, each entered through a
{BigAppLock} task); each `GET /events` connection parks *its* serving thread draining one
subscribed queue. There is no UI thread and no marshaling — thread-safety is a property of the
sinks, not an obligation on their callers.

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

## D_interloper_mid_loop_input — Why does mid-loop input go through `Control::Interloper` rather than queue a new turn?

**Context.** pikuri-tui deferred mid-loop input. A web page makes the
want sharper: the input field is right there while the agent is working,
and a disabled field is a worse answer in a browser than in a terminal.

**Decision.** pikuri-conversations' `Conversation#submit` starts a turn when idle and
**injects** into the agent's `Interloper` when busy; the injection renders through the normal
listener path as `UserTurn(mid_loop: true)`, so nothing about the display is special-cased. The
input stays enabled while busy and the status bar shows the pending count, which the gem reports
as `PendingChanged` — the agent's *own* mid-loop drain included.

**Rejected: disabling the input while the agent works.** It is the
honest-looking option and it is the one that loses work: the user types
during the one period they most want to interrupt, and the field refuses.

**Rejected: queueing submissions client-side and posting them at idle.**
That is client-only conversation state, which
`D_server_authoritative_transcript` forbids — a reload would silently eat
the queue.

**A turn that ends holding a queue starts another one** — the gem's rule, and the one this
shell built first. Only `run_loop` drains the Interloper, so an injection accepted between the
loop's last completion and going idle has nothing left to deliver it; the gem restarts a *bare*
turn in the same critical section that would go idle, and `run_loop` drains before its first
completion. **Only after a turn that completed:** restarting after a cancel would make the stop
button look broken, and after a transport failure would turn an unreachable server into a spin.

**Rejected: draining the queue on cancel.** It makes "cancel" mean "stop everything", badge back
to zero — but silently discards user-typed text that was never rendered anywhere. The messages
survive, and the next send delivers them with it.

**Consequences.** Interloper's delivery boundary is the caveat that
leaks: injections arrive at turn start and once each tool batch
completes, so one placed mid-response waits for that boundary. The
visible pending count exists to make that wait legible rather than to hide
it. The boundary itself is pikuri's decision, not ours.

## D_pikuri_free_core — Why may no `Pikuri::*` type reach what the browser sees?

**Context.** This project tracks pikuri and pikuri-workshop closely
(`D_pikuri_gem_sources`), and both are pre-1.0, so their surface
moves under this shell by design. What that costs depends
entirely on *where* the types are: a pikuri type in the rendering path
prices an upgrade at a sweep of every file the browser's state flows
through, while one in a disk utility prices it at that utility.

**Decision.** The line is the browser, not a file count. **Nothing that
reaches what the browser sees speaks a pikuri type:** {Web::Transcript},
{Web::Broadcaster}, {Web::StreamingMessage}, {Util::MarkdownRenderer} and {Config} deal in ids,
kinds, HTML strings, paths and queues. **Server-side of that line, pikuri types are used
freely** — `bin/pikuri-webui-chat` (boot/wiring), {Web::SseListener}, {Agents::Runner} and
{Conversations::HistoryReplay}.

**The saved-conversation envelope is the one value that crosses.** {Conversations::Registry}
and {Web::App} hold pikuri-conversations' `Store::Entry` — the conversation's id, title, start
time, folder and saved connection — and read it by field, never naming the constant; App turns
it into sidebar hashes before anything renders. The alternative was a webui-side copy of the
entry, translated at the registry: a second type for one frozen value, kept in step with the
gem by hand. The upgrade cost the seam bounds is the few fields read, which a copy would pay
too.

**Rejected: keeping the store on the Pikuri-free side by taking a block** —
`store.save(conversation) { |dir| history.save(dir) }`, the store yielding a `Pathname` and never
holding a `History`. Built once, then reverted: it preserved the letter of an older list of
classes at the cost of an indirection that explained nothing. A utility that owns a directory is
the right owner of what goes into it — the reasoning the gem's `Store` now embodies.

**Rejected: letting Pikuri types spread to whatever needs them.** Passing
a `Pikuri::Agent::Event` into {Web::Transcript} is the shortest path and it
prices every future pikuri upgrade at a full-project sweep. With the seam
held, a shifted surface costs rewriting the adapters — the same
fork-or-swap rationale as the TUI's.

**Consequences.** The adapters translate at the boundary, which
occasionally means a small unwrapping that would be unnecessary if the
event travelled whole. That cost is the decision, not an oversight.
{Config} deliberately stays on the Pikuri-free side even though it is
server-side, because its schema is the *file's*, not pikuri's
(`D_own_config_file`) — the boundary licenses pikuri types where
they help, it does not require them.

## D_stream_blocks_once — Why send a streamed reply's finished blocks once, and only re-send its tail?

**Context.** A streamed reply arrives at 15 fps (pikuri-conversations' `RateLimitedListener`). The
obvious web shape is to re-render the whole accumulated Markdown per delta and replace the
block's div, since a browser, unlike a terminal, can replace a node. Measured, that costs
~6 ms of kramdown per frame at 5 KB and ~32 ms at 48 KB (half a core for one long reply),
and the same O(length) in SSE bytes to every tab — ~1 MB/s at 48 KB, which a phone feels.
And replacing the div 15×/s destroys a text selection or a sideways-scrolled code block in
the part of the reply that is already finished.

**Decision.** {Web::StreamingMessage} feeds deltas to `streaming-markdown-parser` (the
same library pikuri-tui's streaming buffer runs on): each top-level block the reply
finishes is rendered once, and only the open tail re-renders. The stored html is
`finished + <!--tail--> + tail`. A tab gets the first render as a `block` frame, then
`stream` frames `{id, append, tail}`: `transcript.js` inserts `append` before the marker
comment and replaces everything after it, never touching what precedes it. The bookend
`finalize` renders the authoritative text **whole**, a fresh parse, and sends it as a
`block` frame with no marker — deltas are only a preview, and only the whole text resolves
a reference link or footnote whose definition is a block away. The object is dead after
`finalize`: `append` after it and a second `finalize` both raise.

**Why this is safe without client bookkeeping.** A diff is not idempotent, but nothing can
deliver one twice or out of place: {Web::SseListener} stores and broadcasts each frame in
one {BigAppLock} task, and `GET /events` subscribes and snapshots in one task
(`D_subscribe_then_snapshot`), so a tab's snapshot sits exactly before the first diff it
has not absorbed. The marker rides in the stored html, so a snapshot or a page rendered
mid-stream carries the boundary too; the DOM is the state, as with
`D_details_survive_rewrites`. A tab that somehow lacks the marker skips the diff, and the
bookend's full frame heals it.

**Rejected: whole re-render per delta,** what shipped first. Simple, and wrong on cost
for long replies and on selection for every reply; the numbers are above.

**Rejected: re-rendering only the tail on the server but still sending the whole html.**
It fixes the CPU and neither of the things a reader notices.

**Rejected: counting top-level nodes instead of a marker.** One Markdown block is not one
element — a footnote list, raw HTML, a math block — so an index drifts; a comment is
invisible to CSS (`p + p` skips it) and to layout.

**Rejected: coalescing deltas here.** That is the gem's `RateLimitedListener`'s, one listener
ahead (15 fps); a second limiter makes the frame rate a function of both.

**Consequences.** While streaming, a reference or footnote a block from its definition
shows literal, and footnote numbers restart per block; the bookend fixes both, at the cost
of one whole-block replace per message. A kramdown raise inside the parser drops the
message to whole renders through {Util::MarkdownRenderer} as full frames for the rest of
the stream (logged).

## D_markdown_renders_no_html — Why does model-written Markdown render no HTML of its own?

**Context.** The model's text is attacker-steerable: a page a tool fetched can carry a prompt
injection. kramdown, as configured for GFM, passes raw HTML through (`<img onerror=…>`), sets
any attribute from a `{: …}` list, emits `{::nomarkdown}` verbatim, and keeps a
`javascript:` link. Any of those runs script in the chat tab, as the user, behind the gate —
read every conversation, delete them, send messages. That is a capability the trifecta
reasoning never granted the agent (`D_chat_only_entry_point`): it has egress, not the
conversation store.

**Decision.** {Util::MarkdownRenderer} renders Markdown and nothing a page could run. Its
parser recognizes no raw HTML, no attribute list and no extension, so each reads as the
literal text the model wrote; `<br>` alone becomes a line break, as models break table-cell
lines with it. A scrub then holds every element to `href`/`src`/`alt`/`title` (and a code
block's `language-` class), and every URL to http, https, mailto or relative, checked as
written and handed to the browser with its `&` escaped. No heading gets an `id`, which would
shadow an element `app.js` finds by id. Both render paths, whole and streamed, share it.

**Rejected: an HTML sanitizer on the output** (Loofah and kin). A native dependency to
undo what we asked kramdown to produce; not recognizing the syntax at all is smaller, and
shows the reader what the model actually wrote.

**Second line: a Content-Security-Policy** ({Web::App}`::CONTENT_SECURITY_POLICY`) runs
script only from our own files, so markup that gets past the renderer anyway runs nothing.
Alone it would not do: it stops the script, not the markup — a fake form or a restyled page
still renders. It allows inline style as an attribute only, for kramdown's own table
`text-align`, and images from the web, which a Markdown image may link.

**Consequences.** A model that answers in HTML shows HTML source. The streaming marker
(`D_stream_blocks_once`) cannot be forged, since a comment is text too.

## D_server_authoritative_transcript — Why does the server hold the rendered blocks rather than the browser?

**Context.** A browser front-end has to answer three things at once:
page reload, a second tab, and `EventSource`'s automatic reconnect.

**Decision.** {Web::Transcript} holds the rendered HTML blocks and is the
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

## D_single_shared_conversation — Why one live agent and one transcript, on loopback by default?

Narrowed when a sidebar of stored conversations shipped: "one conversation" now means one
**live** conversation — the browser can switch which stored conversation that is, and every
tab follows, because there is still exactly one agent and one transcript.

**Selection clause repealed and shipped.** Viewing is now a
per-tab, per-URL concern (`GET /c/:id`), rows are links, and sending into
a conversation the agent is not on is what makes it live — carrying the
mid-turn refusal that `POST /conversations/:id/select`, now gone, used to
carry. A conversation the agent is not on is replayed from history per
request (`Conversations::HistoryReplay.snapshot`). SSE remains one undivided feed, so
every frame is stamped with the live conversation's id and the client
drops what is not its own; per-conversation subscriptions arrive with the
agent-per-conversation work. The paragraphs below are kept for the
reasoning, not as current behaviour.

**Superseded in direction, still accurate as shipped.** The
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
hazards it opens: `D_conversation_owns_agent`, which the idea file that
argued this graduated into. Nothing here has
changed in code yet; amend this entry, don't trust it as intent.

**Context.** A web front-end invites the assumption that it is
multi-user. This one is the TUI's single-conversation model rendered in a
browser, and its second "user" is a second tab on the same machine.

**Decision.** One agent, one transcript, in-process. No sessions, no
auth (the second half now narrowed by `D_one_password_gate`: one password
gates the port, and sessions still do not exist). `[web] bind` defaults to
`127.0.0.1`; anything else is the operator's risk and is documented as
such. Selecting a conversation is therefore
*server* state, changed by a POST and announced to every tab, not a
per-URL view: one live agent showing two panes where only one accepts
input would be confusing in exactly the situation it enabled. Per-URL
`/c/<id>` is where this goes if background turns ever make the other
pane genuinely alive.

**Rejected: per-session conversations.** Not a patch — {Agents::Runner} owns
*the* worker thread and {Web::Transcript} owns *the* block list, so sessions
mean rewriting who owns what, and {Web::Broadcaster}'s fan-out stops being a
broadcast. Out of scope until there's a concrete need.

**Rejected: shipping auth to make a non-loopback bind safe.** Auth
without per-session conversations protects an inbox everyone shares; it
would look like multi-user support while delivering none of it.
**Overruled by `D_one_password_gate`**, which took that argument as a
constraint rather than a veto: one password for everyone, gating the port
and claiming nothing about who is asking. The shared inbox stays shared.

## D_puma_thread_dump — Why diagnose a wedge with Puma's own backtrace signal rather than a handler of ours?

**Context.** Ruby has no `jstack`: when this server wedges — a `/events`
drain loop parked on a queue nobody pushes, a turn stuck in `run_loop`
against an inference server that stopped answering, a save blocked on a
full disk inside a turn-end save — there was nothing to look *at*. The
`D_no_event_queue` reopening priced dumpability as the compensation for
the coming serialization domain's blast radius: a race consumes its
evidence, but a stall holds still for a dump. The plan was a
Sidekiq-style `TTIN` handler of our own.

**Decision.** No handler of ours. Puma already traps a backtrace signal
— `SIGPWR` on Linux, `SIGINFO` where that exists — in
`Launcher#setup_signals`, on the exact path Sinatra's embedded `run!`
takes, and dumps every thread's name and backtrace to its stdout
(verified end-to-end against Puma 8.0.2). What we own instead is
*legibility*: every thread we spawn or borrow names itself, because an
anonymous `Thread: TID-2e4` costs the reader a source dive that
`sse-heartbeat` or `turn <conversation-id>` does not.

**Rejected: our own `TTIN` handler** (trap pushes a token to a queue, a
dedicated printer thread writes `Thread.list` backtraces to stderr —
the indirection because Ruby trap context cannot take a mutex). It buys
stderr instead of stdout and printing outside trap context, at the price
of ~15 lines to maintain, one more thread, and a signal with a real
collision: Puma's *cluster* mode traps `TTIN`/`TTOU` for worker scaling,
so the Sidekiq convention is only free while this stays single-mode.
Puma's own handler does run in trap context, but its log path is
mutex-free by inspection — accepted. Dump-on-slow-shutdown was also
considered and dropped: `force_shutdown_after: 5` already backstops, and
on-demand is the tool.

**Consequences.**

- Every thread we create sets `Thread.current.name`, and the turn job
  names its pooled thread `turn <conversation-id>` for the duration
  (`turn-idle` after), so a wedged turn names its conversation. A new
  thread without a name is a review miss.
- The dump lands on stdout (Puma's log stream), not stderr — an accepted
  nick in `D_diagnostics_to_stderr`'s wording, whose point is
  browser-vs-terminal, and both streams reach the terminal.
- README's "When it looks stuck" documents the signal; it is the
  operator-facing half of this entry.

## D_global_monitor — Why one global re-entrant monitor with run-to-completion tasks, rather than a lock per seam?

Answers the *Reopened* tail of `D_no_event_queue`; that entry's core — the partition,
browser-owned view state, the Broadcaster as an independent sink — stands.

**Context.** The reopening named the hole: the partition supplies
isolation (one writer per conversation) but not **atomicity across a
seam** — two objects mutated or read as one unit — so the seams held by
timing, and this architecture cannot *report* a seam that fails (a race
consumes its evidence). The atomicity audit closed what it could; seam 2
(compose a status payload + publish it) stayed open, and every future
seam was a thing to find by reading. The owner called it: one mechanism
internal logic can rely on, instead of an audit per seam.

**Decision.** {BigAppLock}: one process-wide re-entrant `Monitor`; work
enters as **tasks** (`lock.run { }`) that run to completion, so the
system is only ever observed *between* tasks, never inside one. The
reachable state space shrinks from arbitrary interleavings of statements
to orderings of tasks. It does **not** buy determinism — whether a submit
lands before or after a turn ends is genuine external concurrency, and
both orders must stay correct — and it does not serialize turns: each
still runs on its own thread (`D_serial_turn_executor`), and two
conversations stream concurrently, interleaving at task granularity.

The task inventory:

- **Every route body that touches server state is one task** ({Web::App}): the
  page snapshot is an untorn read (blocks + status + rows from one
  instant), resolve + act is one step, and `/events`' subscribe +
  catch-up share a task.
- **What pikuri-conversations reports from its threads becomes a task in the runner**: the
  turn-end save ({Agents::Runner#save}), a landed title, every status change. `run_loop`
  itself — LLM round-trips, tool execution — and the gem's own state machine run off-domain.
- **{Web::SseListener} renders off-domain** (kramdown, escaping, the
  {Web::StreamingMessage} accumulation — the domain owns *mutation*, not
  rendering) **and enters a task per finished block**: store + broadcast
  as one unit, ~15 tiny tasks/s per streaming conversation.
- **A conversation event fired by a call made inside a task** — a submit's pending count —
  is emitted on that same thread after the gem drops its lock, and its task just re-enters.

Guarded classes — {Agents::Runner}, {Conversations::Registry}, {Web::Transcript} —
lost their own locks and gained a *caller obligation*: every public
method opens with {BigAppLock#assert!}, so a call from outside a task
raises instead of racing. `OutsideTask` is an `Exception`, not a
`StandardError`, so blanket recovery (`rescue StandardError` around the
turn job and the registry's delete) cannot mask a guarding bug as an
operational failure. That assertion is the enforcement Node gets from its
language and Ruby otherwise lacks; specs drive guarded classes through a
`guard` proxy — the spec-side stand-in for the App's route wrapping.

Outside the domain, deliberately: {Web::Broadcaster} (its own small mutex —
`#close` fires from the stop hook, which must never wait on a wedged
domain, so nothing in that hook enters the monitor); the `/events` drain
loops (parked request threads doing the network); all rendering; the
immutable and stateless classes; pikuri's internals.

The rules a change must keep:

- **Tasks are rapid-fire; a stall is eligible only when rare and
  bounded.** Never network, never a wait on another thread, never
  anything unbounded. *Rare* means once-per-conversation-per-process
  class; *bounded* means a ceiling the deployment guarantees, never
  "usually small". The two sanctioned stalls: the turn-end save (two
  small files, temp-and-rename) and the restore replay — measured at
  ~1.6 ms per markdown-heavy turn (≈100 ms at 50 turns; about half a
  second for a 256k-token history, the practical cap of sensible local
  LLMs, on the hardware local llama already mandates). If the replay ever
  bites, the named fallback: replay off-domain into a *detached*
  transcript on the opener's own request thread, a promise in the
  registry map installed by one task and fulfilled by another; a second
  opener waits on the promise on its own thread, outside the domain.
- **No post-and-wait.** A task never blocks on a Future or a worker's
  result; results return as the worker's own follow-up task —
  `monitor.run` from its thread, no API needed. The runner's event handling
  is exactly this continuation style.
- **The domain is the outermost lock.** A task may call into
  pikuri-conversations (`Conversation#submit`, `#status`, `#close`), whose lock is taken
  inside ours; the gem never calls out — no listener, no `Saver` — under its own lock,
  and documents the order host → gem → `Interloper`. Consistent order, no ABBA —
  re-enumerate when a new upstream callback appears.

**Rejected: costume B, the event loop** (the Active Object pattern — a
`Concurrent::SingleThreadExecutor` owner thread draining a mailbox;
precedents Swing's EDT, Node, Tuile). Same atomicity, same enforcement
(thread identity instead of `mon_owned?`), same dumpability — but every
reading route needs `ask` + timeout + a 503 arm where a monitor task
composes the response inline; a task that posts-and-waits on a task
self-deadlocks, so the pending-count knot (fires synchronously from inside
submit's inject and re-enters the status broadcast) needs restructuring
where a re-entrant monitor dissolves it. Its one real advantage — FIFO across threads — solves a problem
we don't have: per-source order comes from each source being one thread,
and cross-source order is the genuine concurrency neither costume
removes. On deadlock the costumes differ in *shape*, not exposure: B
trades ABBA for self-deadlock; A's ABBA exposure collapses to the one
outermost-lock rule above, against exactly one foreign lock family.

**Rejected: per-seam atomic helpers** — and the audit's own finding cut
that way, which this entry must answer: its five seams wanted four
different tools (ordering, broadcast-at-the-transition, a monitor the
registry already had, an immutable snapshot), none of them global, and
two fixes needed no lock at all. The answer: per-seam fixes are
patch-after-reading — each seam must first be *found*, and this
architecture hides exactly the defects that argue against it, so the
per-seam discipline amounts to "hope the next audit reads the right
function". One run-to-completion domain is something internal logic can
rely on without an audit per seam. Two audit fixes survive regardless:
`D_subscribe_then_snapshot`'s duplicate tolerance (the page render and
the EventSource are still two HTTP requests, which no server mechanism
reaches, though the server-side half now also sits in one task), and
`Web::Transcript::Block` staying a `Data`.

**Consequences.**

- Seam 2 closed structurally: composing a status frame and pushing it
  share a task, so composed order *is* push order; the monotonic-sequence-number
  fallback died unimplemented.
- Blast radius, priced: a stall inside a task pauses every conversation
  and every request, not one. Compensations: the rapid-fire rule, and
  `D_puma_thread_dump` — the SIGPWR dump shows the stalled task *with its
  caller's stack*.
- Request threads wait on the monitor with no timeout (Ruby's `Monitor`
  has no timed `enter`). Accepted: Puma's pool absorbs, the dump
  diagnoses; a bounded wait is the thing to add if this ever hurts.
- The stop hook's independence is an invariant: `broadcaster.close` +
  `Pikuri::Conversations#shutdown` (no wait) and nothing else — nothing in it may enter the
  domain.
- New shared state joins the domain (guarded + `assert!`) or states the
  reason for its own lock the way {Web::Broadcaster}'s header does.
- The registry's `#open` footgun (audit PROBE 7; the method is `#runner_for` now) was untouched by the
  mechanism — the stale entry is held *across* tasks — and was
  closed right after it by structure instead: it is private, so every
  caller goes through `#open_id` (re-resolves in its own task) or
  `#create` (opens what it just minted), and PROBE 7's premise is gone.
- The request-to-request seams, which no server-side mechanism reaches,
  stay accepted (they were the audit's known-and-accepted list): a queued
  turn shows the user nothing they sent until the listener runs — the
  in-flight window wants a pending state, distinct from busy;
  double-submit has no server-side guard — the answer is an idempotency
  key on `POST /messages`, and composer.js's optimistic clear covers the
  single-tab mash today; a tab watching a conversation someone else
  deletes keeps showing it, cosmetically; and no SSE frame carries an
  `id:`, so a reconnect replays nothing — app.js reloads on reconnect.

## D_config_through_typemap — Why map the config file through Typemap rather than check it by hand?

**Context.** {Config} checked its TOML with hand-written `is_a?` tests and unknown-key lists,
about 150 lines restating what the value objects' YARD tags already said — and pikuri-tui's
`Shared::Config` had just moved off the same code.

**Decision.** Typemap maps the merged Hash onto `Data` classes shaped like the file (`Root`,
`LlmTable`, `McpTable`, `BasicAuth`, `CodeTable`, `UiTable`, `TitlerTable`; `Server`, `Search`
and `Credentials` as they were) and checks each value against its YARD type, read back from
`sig/pikuri_webui.rbs`. A type is written once, in the doc comment; `constrain` adds the limits a
type can't say — ranges, `not_blank:`, `not_empty:`, `unique_by:` — and a class's `validate`
keeps only what no limit can, such as `[web]`'s both-or-neither pair. A table both shells read is
the same class under the same Typemap pin, so a schema change ports between the two by copying.

**Rejected: `constrain type:` lines and no `rbs` at runtime.** Every type would be written twice,
in YARD and in `constrain`, and the two would drift.

**Consequences.** `rbs` loads at boot, about 0.2 s. A stale `sig/` hands the running app stale
types, so `rake check` regenerates it before the specs run. Messages are Typemap's, led by the
value's path (`llm[0] "Local".context_window: must be at least 1, got 0`), and a TOML shape
mistake names its fix (`write [[server]], not [server]`).
