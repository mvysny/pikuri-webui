# Research — Open WebUI

What the things we don't own actually do. About *them*, never us: a sentence starting "we chose"
is a `D_`. `## R_<slug> — <title>`, one claim per bullet, one provenance marker per claim —
**[docs]**, **[src]**, **[verified <date>, <version>]**, **[unverified]** (a hypothesis; a design
built on it says so). A claim is earned by its provenance, or by having cost real work to find
out. Checked against [Open WebUI](https://github.com/open-webui/open-webui) as documented in
August 2026; a version-sensitive claim names what it was seen on. Cite by slug, `R_<slug>`, never
by position; `grep '^## R_' design/research.md` is the index. The first entry is the ruler: every
later one trims to its length — which is how long this file gets, so keep it short.

---

## R_open_webui_shape — What it is, and what a deployment carries

- A self-hosted AI *platform*, not a chat front-end: a Python/FastAPI backend and a
  SvelteKit/TypeScript frontend with a Vite build, shipped via Docker, Kubernetes, pip, uv and a
  desktop app. **[docs]**
- State is a database — SQLite or PostgreSQL — plus object storage (S3/Azure/GCS) and a choice of
  nine vector databases. **[docs]**
- Live updates run over WebSockets (Socket.IO), not SSE. **[docs]**
- It speaks to Ollama and to any OpenAI-compatible API, with per-chat and multi-model routing,
  per-user API keys, and multi-user accounts carrying RBAC and SSO/LDAP/OAuth/SCIM. **[docs]**
- **The intelligence lives in the platform.** Open WebUI itself orchestrates retrieval, tool calls
  and model routing around a chat-completions endpoint; the model server is a completion API to
  it, not an agent. **[docs]**
- Around that core: RAG with embeddings, hybrid search and Tika/Docling extraction; web search
  across ~12 providers, opt-in per message; image generation and STT/TTS; team channels; a plugin
  system (tools, functions, pipelines, MCP); an enterprise offering. **[docs]**
- Licensed under the Open WebUI License: BSD-3-derived with a branding-preservation clause.
  Hundreds of contributors, ~150k GitHub stars. **[verified 2026-08]**

## R_open_webui_tool_permissions — Tools are unsandboxed, and permissioning gates installation, not invocation

- A tool is unsandboxed Python running in-process, with the standard library, the database and the
  live app in reach. The [tools
  docs](https://docs.openwebui.com/features/extensibility/plugin/tools/) state that granting
  tool-creation rights "is equivalent to giving them shell access to the server". **[docs]**
- The control is therefore *who may install a tool*, and it is admin-gated. On a personal instance
  the user is the admin, so the control is vacuous there. **[docs]**
- Once a tool is enabled, the **model** decides when to call it — installation permissioning says
  nothing about invocation. **[docs]**
- The nearest thing to an invocation guard is opt-in human-in-the-loop: an experimental
  `ENABLE_TOOL_PERMISSIONS` Allow/Deny dialog, plus MCP elicitation confirms
  ([discussion](https://github.com/open-webui/open-webui/discussions/16701)). Off by default, and
  an approval prompt rather than a separation. **[docs]**
- **The tool surface is mutable at runtime**: an admin toggle, a per-chat integrations click or a
  community plugin import changes which tools are live, so an audit of what the model can reach
  is a snapshot, stale after the next toggle. **[docs]**

## R_open_webui_hardening — The hardening guide does not cover prompt injection

- The [hardening
  guide](https://docs.openwebui.com/getting-started/advanced-topics/hardening/) covers auth, TLS,
  session cookies, an SSRF blocklist for cloud metadata endpoints and an optional `IFRAME_CSP`.
  **[docs]**
- It never mentions prompt injection, model-mediated exfiltration, or keeping untrusted content
  away from private data: the security model is perimeter- and identity-based — who may install
  what — not capability-based. **[verified 2026-08]**
- [RAG](https://docs.openwebui.com/features/chat-conversations/rag/) injects retrieved document
  content into the message context with no provenance separation, so indirect injection rides in
  through the retrieval pipeline — the same leg the documents sit behind. **[docs]**
