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

## It's a chat, not an agent with hands on your machine

The whole tool set is `web_search`, `web_scrape`, `fetch` and
`calculator` — search the web, read a page, download a payload, do
arithmetic. That's the entire surface.

It cannot read your disk, run a shell command, edit a file, or touch a
repository. Pikuri ships gems for all of that — `pikuri-os`,
`pikuri-code`, `pikuri-workspace` — and this shell wires none of them.
In pikuri's lethal-trifecta terms the tool set holds the *untrusted
content* and *egress* legs and **not** the *private data* leg.

That's what makes it somewhere to think out loud. No approval prompts,
no "which directory did I start this in", no wondering what the model
just read — there is nothing on your machine for it to read.

This is a property of the boot script, not a phase the project is
passing through. Should pikuri-web ever grow OS or code capability, it
arrives as a *separate* script with its own tool set and its own
trifecta report; this one stays chat-only.

The boundary that does remain: everything *you type* still goes to the
LLM server you configured, and the agent reaches the network on its own
— a page it scrapes can try to talk it into fetching an attacker-chosen
URL. Untrusted-in, egress-out is a real pair, so don't paste a secret
into the conversation. What this shell gives you is that the agent can't
go *find* one.

## Prerequisites

- Ruby ≥ 3.3
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
bin/pikuri-web-chat
```

Then open <http://localhost:4567>. Defaults to the LLM server at
`http://localhost:8080` and model
`unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`. Override with `--server`,
`--model`, `--port` and `--bind`:

```sh
bin/pikuri-web-chat --server http://localhost:8082 --model my-model --port 9292
```

Ctrl+C stops it. Open browser tabs don't delay the exit.

## Conversations

**+ new conversation** in the status bar saves what you have and clears the
page — the `/clear` this shell used to lack. It is refused (and the button
disabled) while the agent is mid-turn: a click must not throw a running
turn away.

The sidebar lists every conversation you have had, newest first, with when
each started. The order is by start time, so a conversation stays where it
is however long you keep talking in it. The rows don't do anything yet —
clicking one to open it is the next step. A row greyed out as *unsupported
format* was written by a version this one can't read.

Everything this shell persists lives under
`~/.local/state/pikuri/pikuri-web-chat/` (`$XDG_STATE_HOME` if you set
it), so `rm -r` on that folder is a complete reset. Each conversation
becomes a directory under its `conversations/`, named for when it
started:

```
2026-08-27T12-03-51Z-3f9a/
    history.json   the conversation itself, in pikuri's own format
    attachments/   any file the model was shown
    meta.json      title, timestamps, which shell and model wrote it
```

The `conversations/` folder is there from boot; a conversation's own
directory appears with its first completed turn, so a session you never
said anything in leaves nothing behind. Turns are saved as they finish, so
quitting keeps the conversation — but **nothing loads one back yet**: a
restart still starts you empty, with the old conversations listed in the
sidebar and not yet openable. Loading them is what
`ideas/multiple-conversations.md` plans next.

Nothing is encrypted. These files hold everything you typed and everything
the tools fetched, so the directories are created `0700` and that is the
whole of the protection. Delete a conversation with `rm -r`.

## Develop

```sh
bin/pikuri-web-chat --dev
```

`--dev` runs Sinatra in development mode: `views/*.erb` is re-read per
request, and an exception renders in the browser instead of only on
stderr. `public/app.js` and `public/style.css` are read off disk on every
request in either mode — a browser reload picks them up.

Ruby under `lib/` is the exception: nothing reloads it, in either mode.
The agent, its listener stack and the runner's worker thread are
long-lived instances wired once in the boot script, so a class change
lands only in a fresh process — which is also a fresh transcript (the old
one is saved, per **Conversations** above, but not reloaded). Let a
watcher restart it:

```sh
find bin lib views -type f | entr -r bin/pikuri-web-chat --dev
# or: rerun --dir bin,lib,views -- bin/pikuri-web-chat --dev
```

Both restart by signalling the process, which takes the same path as
Ctrl+C — about a second, tabs open or not.

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

[search]                   # optional; omit it and web_search runs DuckDuckGo-only
brave_key = "BSA…"
exa_key = "…"
engines = ["brave"]        # who gets searched, out of duckduckgo / brave / exa;
                           # omit for DuckDuckGo + every keyed provider
```

`engines` is a *set*, not a preference order — pikuri picks at random per
query, so `["brave", "duckduckgo"]` splits your traffic between the two
rather than trying Brave first. List `brave` alone to keep every query away
from DuckDuckGo (and so from Bing, which fulfils its web results). Naming an
engine whose key you did not set aborts at boot.

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
│ status · tokens · + new · theme  │
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
