# pikuri-web

Web front-end for [pikuri](https://codeberg.org/mvysny/pikuri) — a Ruby
LLM agent framework. The browser sibling of
[pikuri-tui](https://codeberg.org/mvysny/pikuri-tui): same agent, same
tools, rendered as a server-driven chat page instead of a terminal.

Pikuri owns the agent loop, tool execution, and LLM transport. This
project owns nothing but the web shell: a transcript, a collapsible
diagnostic log panel, an input field, and a status bar — Sinatra +
server-side Markdown + one SSE stream. JavaScript is a single
dependency-free `public/app.js`; there is no Node, no bundler, no build
step.

## Prerequisites

- Ruby ≥ 3.4
- A local LLM server (e.g. [llama.cpp](https://github.com/ggerganov/llama.cpp) `server`)

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
`--model`, `--api-key-env`, `--port` and `--bind`:

```sh
bin/pikuri-web --server http://localhost:8082 --model my-model --port 9292
```

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
│ status · tokens · log [Ctrl+L]   │
└──────────────────────────────────┘
```

`Ctrl+L` (or the `log` button) toggles the diagnostic log panel
(pikuri internals, library errors, agent-loop diagnostics). Sending a
message while the agent is mid-turn injects it via pikuri's
`Control::Interloper` — it's delivered at the next tool boundary.

## Test

```sh
rake
```
