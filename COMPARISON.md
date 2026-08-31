# pikuri-web vs. Open WebUI

A comparison against [Open WebUI](https://github.com/open-webui/open-webui),
the most popular self-hosted LLM chat front-end (~150k GitHub stars as of
August 2026). Written to answer "why does this exist when Open WebUI does?"
— and, in the other direction, to be honest about what choosing pikuri-web
costs you.

## What each one is

**Open WebUI** is a self-hosted AI *platform*: a Python (FastAPI) backend
and a SvelteKit/TypeScript frontend, deployed via Docker/Kubernetes/pip,
backed by SQLite or PostgreSQL plus your choice of nine vector databases.
It speaks to Ollama and any OpenAI-compatible API, and layers on RAG,
multi-user accounts with RBAC and SSO/LDAP/SCIM, web search across a dozen
providers, image generation, voice, team channels, a plugin system
(tools, functions, pipelines, MCP), and an enterprise offering. The
intelligence lives *in the platform*: Open WebUI itself orchestrates
retrieval, tool calls, and model routing around a chat-completions API.

**pikuri-web** is a web *shell* over [pikuri](https://codeberg.org/mvysny/pikuri),
a Ruby LLM agent framework. The agent loop, tool execution, prompts, and
LLM transport all live in the pikuri gems; this project is a Sinatra app
that renders that agent's event stream into a chat page — a transcript, an
input field, a status bar — over one SSE connection. It is ~3k lines of
Ruby and ~600 lines of dependency-free JavaScript, single-user by
construction, talking to whatever OpenAI-compatible server (typically
llama.cpp) you configured in `~/.config/pikuri/config.toml`.

The one-line version: **Open WebUI is a platform that treats the LLM as a
completion endpoint and builds the agent around it in the web app;
pikuri-web treats the agent as the product (pikuri) and builds only the
thinnest possible viewport onto it.**

## Feature comparison

| | Open WebUI | pikuri-web |
|---|---|---|
| Backend | Python / FastAPI | Ruby / Sinatra + Puma |
| Frontend | SvelteKit + Tailwind, Vite build | Server-rendered ERB; hand-written JS, no build step |
| Live updates | WebSockets (Socket.IO) | One SSE stream per tab |
| Deployment | Docker, k8s, pip, uv, desktop app | `bundle install && bin/pikuri-web-chat` |
| Storage | SQLite/PostgreSQL, S3/Azure/GCS, vector DBs | JSON files under `~/.local/state/pikuri/` |
| Users & auth | Multi-user, RBAC, SSO/LDAP/OAuth/SCIM | None; single user, loopback bind by default |
| Model providers | Ollama + any OpenAI-compatible API, per-chat and multi-model | Any OpenAI-compatible server via `[[llm]]` entries; per-conversation `/model` switch |
| Agent / tools | Plugins: tools, functions, pipes, MCP, code execution | pikuri's fixed chat-only set: `web_search`, `web_scrape`, `fetch`, `calculator` |
| RAG / documents | Built-in: embeddings, hybrid search, Tika/Docling extraction | None |
| Web search | ~12 providers, opt-in per message | Always available to the agent; DuckDuckGo/Brave/Exa, rate-limited |
| Image gen, voice | Yes (DALL·E, ComfyUI, …; STT/TTS) | No |
| Mid-turn behavior | Background/asynchronous chats | Turns keep running when you navigate away; mid-turn input is *injected* into the running turn (pikuri's Interloper) |
| Mobile | PWA | PWA manifest; phone layout is the same page restyled by CSS |
| License | Open WebUI License (BSD-3-derived, branding-preservation clause) | MIT |
| Scale of codebase | Hundreds of contributors, enterprise track | ~5k lines total, one author |

## What Open WebUI has that pikuri-web deliberately does not

These are scope decisions, not gaps waiting for contributors — each traces
to an entry in [`DECISIONS.md`](DECISIONS.md):

- **Accounts, sharing, RBAC.** pikuri-web has no session concept and no
  notion of who is asking; anyone who reaches the port owns every
  conversation. Multi-user means a second OS account running its own
  process. See `D_single_shared_conversation`.
- **A client-side app.** Open WebUI ships a full SPA; pikuri-web's
  transcript is server-authoritative — the page arrives rendered, SSE
  carries deltas, and JavaScript is transport and platform mechanics only.
  No npm, no bundler, zero JS dependencies. See
  `D_server_authoritative_transcript`, `D_no_js_build_step`.
- **RAG, file upload, knowledge bases.** Retrieval would live in pikuri
  (the agent framework), not in this shell. Nothing here parses or embeds
  a document.
- **Local capability — code execution, file access.** The chat script's
  tool set is deliberately unable to read your disk or run a shell; in
  lethal-trifecta terms it holds *untrusted content* and *egress* but not
  *private data*, and `/trifecta` shows you that report. Growing hands
  means a separate boot script, never this one. See
  `D_chat_only_entry_point`.
- **A plugin system.** Open WebUI's tools/functions/pipelines are its
  extension surface. pikuri-web has none: new capability is Ruby code in
  pikuri or a new boot script here.
- **A database.** A conversation is a directory holding `history.json`
  plus `meta.json`; `rm -r` is a complete reset, `grep` works on your
  history, and the rendered view is replayed from history on every open,
  so a renderer fix reaches old conversations. See `D_replay_from_history`.

## What pikuri-web has that Open WebUI does not

- **The agent is a first-class, inspectable Ruby object.** Every
  conversation owns a `Pikuri::Agent`; the web page is one listener on its
  event stream, the TUI ([pikuri-tui](https://codeberg.org/mvysny/pikuri-tui))
  is another. The same agent, tools, and prompts run identically in a
  terminal, which no web platform's chat pipeline can offer.
- **A security posture you can state in one sentence.** No auth *because*
  loopback-only single-user; no private-data tool leg *by construction*;
  the boot banner and `/trifecta` print the exact tool/risk map. Open
  WebUI's surface (accounts, plugins, code execution, uploads) is far too
  large to summarize that way — which is fine at team scale and the point
  of avoiding at personal scale. The prompt-injection section below makes
  this concrete.
- **Auditability of the whole stack.** ~5k lines including CSS and
  templates, readable in an afternoon; every behavior decision is written
  down in `DECISIONS.md` with its rejected alternatives.
- **Mid-turn injection.** Sending while the agent is working doesn't queue
  a new chat turn — it is delivered *into* the running loop at the next
  tool-batch boundary (pikuri's `Control::Interloper`), so you can steer a
  long agentic turn rather than wait it out.
- **Nothing to operate.** No containers, no database migrations, no
  Node toolchain, no version treadmill of a 150k-star project. One
  process, one state folder, Ctrl+C exits in about a second.

## Prompt injection and the lethal trifecta

The sharpest difference is not a feature but a security property, so it
gets its own section. The question: what stops a scraped page or an
indexed document from talking the model into exfiltrating your data?

**Open WebUI has no structural guard against the trifecta.** Its security
model is perimeter- and identity-based — who may install what — not
capability-based. Concretely, from its own documentation:

- Tool permissioning governs *installation*, not *invocation*. The
  [tools docs](https://docs.openwebui.com/features/extensibility/plugin/tools/)
  state that granting tool-creation rights "is equivalent to giving them
  shell access to the server" — a tool is unsandboxed Python running
  in-process, with the standard library, the database and the live app in
  reach. The control is "only admins install tools"; on a personal
  instance you are the admin, so the control is vacuous. Once a tool is
  enabled, the *model* decides when to call it — and a scraped page
  decides what the model wants.
- The closest thing to a guard is opt-in human-in-the-loop: an
  experimental `ENABLE_TOOL_PERMISSIONS` Allow/Deny dialog and MCP
  elicitation confirms
  ([discussion](https://github.com/open-webui/open-webui/discussions/16701)).
  An approval prompt, off by default, with the usual approval-fatigue
  failure mode — not a separation.
- The [hardening guide](https://docs.openwebui.com/getting-started/advanced-topics/hardening/)
  never mentions prompt injection. It covers auth, TLS, session cookies,
  an SSRF blocklist for cloud metadata endpoints, and an optional
  `IFRAME_CSP` — nothing on model-mediated exfiltration or on keeping
  untrusted content away from private data.
- [RAG](https://docs.openwebui.com/features/chat-conversations/rag/)
  injects retrieved document content into the message context with no
  provenance separation, so indirect injection rides in through the
  retrieval pipeline — the same leg your documents sit behind.

The structural point: a trifecta guarantee has to be a *static property
of a fixed tool set* — auditable once, reliable after. Open WebUI's tool
surface is mutable at runtime: an admin toggle, a per-chat integrations
click, or a community plugin import can silently re-link the three legs,
and a platform whose value proposition is "connect everything" cannot be
configured out of that. At best you get a snapshot audit, stale after the
next toggle. None of this is carelessness on Open WebUI's part — it is
what "extensible platform" means.

pikuri-web's guarantee is the boot script: the chat entry point wires
*untrusted content* and *egress* and structurally lacks the *private
data* leg, `/trifecta` prints the map, and growing a leg requires a
different executable (`D_chat_only_entry_point`), so the report cannot
drift. This is also why the personal-assistant configuration you would
actually want from Open WebUI — RAG over your files plus web search — is
the trifecta assembled by default, with an experimental confirm dialog as
the only brake.

## When to use which

Use **Open WebUI** when any of these is true: more than one person uses
it; you want RAG over your documents; you want image/voice; you want a UI
over many providers with per-user API keys; you want a plugin ecosystem
and an enterprise support path.

Use **pikuri-web** when: it's you, on your machine, talking to your own
llama.cpp (or one API endpoint); you want a chat that can search and read
the web but provably cannot touch your disk; you value being able to read
and audit the entire thing; or you're already invested in pikuri and want
its agent in a browser and on an iPad's home screen.

They aren't really rivals. Open WebUI competes with hosted ChatGPT-style
products; pikuri-web competes with running `pikuri-tui` in a terminal.
