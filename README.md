# pikuri-web

[![status](https://ci.codeberg.org/api/badges/17299/status.svg)](https://ci.codeberg.org/repos/17299)

Web front-end for [pikuri](https://codeberg.org/mvysny/pikuri) — a Ruby
LLM agent framework. The browser sibling of
[pikuri-tui](https://codeberg.org/mvysny/pikuri-tui): same agent, same
tools, rendered as a server-driven chat page instead of a terminal.

Pikuri owns the agent loop, tool execution, and LLM transport. This
project owns nothing but the web shell: a transcript, an input field,
and a status bar — Sinatra + server-side Markdown + one SSE stream.
Diagnostic logs go to stderr. JavaScript is a single
dependency-free `public/app.js`; there is no Node, no bundler, no build
step.

## Prerequisites

- Ruby ≥ 3.4
- A local LLM server (e.g. [llama.cpp](https://github.com/ggerganov/llama.cpp) `server`)
- A [pikuri](https://codeberg.org/mvysny/pikuri) checkout at `../pikuri`
  — this shell tracks pikuri master, so `pikuri-core` and `pikuri-pdf`
  are path dependencies rather than released gems

## Install

```sh
bundle install
```

## Run

```sh
bin/pikuri-web
```

Then open <http://localhost:4567>. Defaults to the LLM server at
`http://localhost:8080` and model
`unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`. Override with `--server`,
`--model`, `--port` and `--bind`:

```sh
bin/pikuri-web --server http://localhost:8082 --model my-model --port 9292
```

## Configure

Connections and API keys come from `~/.config/pikuri/config.toml` — the
same file pikuri-tui reads, so one file configures every pikuri shell.
There is no `--api-key` flag: a secret on the command line is visible in
`ps` and shell history.

```toml
[[llm]]
name = "Local Qwen 3.6"
server = "http://localhost:8080"
model = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"

[[llm]]
name = "Grok"
server = "https://api.x.ai"
model = "grok-4"
api_key = "xai-…"
context_window = 2000000   # for a server the llama.cpp /props probe can't reach

[search]                   # optional; without them web_search runs DuckDuckGo-only
brave_key = "BSA…"
exa_key = "…"
```

`chmod 600` it — pikuri-web logs an advisory at boot if a file holding a
literal key is group/other-readable. The first `[[llm]]` is the boot
connection; `--server` / `--model` override its fields. Layering runs
`/etc/xdg/pikuri/config.toml` → `$XDG_CONFIG_HOME/pikuri/config.toml` →
CLI flags.

> [!WARNING]
> There is no authentication and one shared conversation. Keep
> `--bind` at its loopback default.

## Layout

```
┌──────────────────────────────────┐
│ Transcript                       │
│                                  │
│ assistant: markdown, reasoning   │
│ tool calls & observations        │
│                                  │
├──────────────────────────────────┤
│ Input (Enter to send;            │
│   sending mid-turn injects)      │
├──────────────────────────────────┤
│ status · tokens                  │
└──────────────────────────────────┘
```

Sending a message while the agent is mid-turn injects it via pikuri's
`Control::Interloper` — it's delivered at turn start or once the
in-flight tool batch completes.
Diagnostics (pikuri internals, library errors, agent-loop diagnostics)
are printed to stderr.

## Test

```sh
bundle exec rspec
```
