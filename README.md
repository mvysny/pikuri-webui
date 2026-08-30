# pikuri-web

[![status](https://ci.codeberg.org/api/badges/17299/status.svg)](https://ci.codeberg.org/repos/17299)

Web front-end for [pikuri](https://codeberg.org/mvysny/pikuri) — a Ruby
LLM agent framework. The browser sibling of
[pikuri-tui](https://codeberg.org/mvysny/pikuri-tui): same agent, same
tools, rendered as a server-driven chat page instead of a terminal.

Pikuri owns the agent loop, tool execution, and LLM transport. This
project owns nothing but the web shell: a transcript, an input field,
and a status bar — Sinatra + server-side Markdown + one SSE stream.
Diagnostic logs go to stderr. The JavaScript is dependency-free and
hand-written; there is no Node, no bundler, no build step.

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

Then open <http://localhost:4567>. With no config file it talks to the LLM
server at `http://localhost:8080` using model
`unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`. To point it anywhere else, write an
`[[llm]]` entry in `~/.config/pikuri/config.toml` (see
[Configure](#configure)) — there are no `--server` / `--model` flags.
`--port` and `--bind` are this shell's own:

```sh
bin/pikuri-web-chat --port 9292
```

Ctrl+C stops it. Open browser tabs don't delay the exit.

### How many conversations can think at once

One, by default. Send in a second conversation while the first is working
and the message is accepted and *queued* — never refused — and that
conversation says so until its turn starts.

`--turns N` raises the cap. It is there to match your inference server:
one turn per parallel slot, so `--turns 4` against llama.cpp started with
`--parallel 4`. Setting it higher than the server has slots doesn't buy
throughput, it just moves the queue from this process into that one.

```sh
bin/pikuri-web-chat --turns 4
```

Note that web searches still serialize across conversations however high
you set this — the rate limiter that keeps you off provider blocklists is
scoped to your IP, not to a conversation.

### Keeping it on a home screen

The page ships a web manifest, so Safari's **Add to Home Screen** on an
iPad or iPhone gives pikuri its own icon and opens it without browser
chrome. It is still the same server on the same machine: the icon is a
bookmark, not an app, and it opens on nothing if the server isn't
running. Reaching it from a phone also means binding off loopback, which
is the thing the warning further down tells you not to do — on an iPad
sharing the machine's own browser, none of that applies.

In Safari, not in another browser:

1. Open the address the server printed at boot — `http://127.0.0.1:9292`
   on the machine itself, its LAN address from a phone.
2. Tap **Share** — the square with the arrow out of it, in the bottom
   toolbar on an iPhone, the top-right one on an iPad.
3. Scroll the share sheet to **Add to Home Screen**.
4. The name defaults to `pikuri`; change it or don't, then tap **Add**.

Launch it from the icon and you get the page standalone — no address bar,
no tabs, Kuri in the app switcher.

The icon is Kuri, a pika: a small alpine animal that spends the summer
stacking cut grass into a pile under a rock, spends the winter eating it,
and never leaves its own mountain.

## Slash commands

Type `/` in the message box and a list of commands appears above it. Keep
typing to narrow it, `↑`/`↓` to move, `Enter` to run the highlighted one —
or just tap a row, which is the point on a phone: `/t`, tap.

| command | what it does |
|---|---|
| `/new` | start a fresh conversation, as the sidebar button does |
| `/model` | put this conversation on another `[[llm]]` connection |
| `/theme` | pick the dark or light theme |
| `/trifecta` | show this agent's lethal-trifecta report — the same map the boot banner prints |

`/model` only appears when you have more than one `[[llm]]` — with a single
connection there is nothing to pick between.

`Esc` closes the list, and closes a dialog. Nothing a command does is
written into the conversation: they are chrome, not something the model
ever sees.

A message that merely *starts* with a slash is still a message — anything
with a space in it is never read as a command, so `/usr/share/foo is
missing` sends normally. A slash-word that matches no command is not sent
at all; you get a dialog naming the commands there are, and your text
stays where you typed it.

## Conversations

**+ new conversation** in the status bar starts a fresh one and takes this
tab to it. It is never refused, because a new conversation touches no
existing one: a turn already running — including in the conversation you
are leaving — carries on untouched, and other tabs stay where they are.

The sidebar lists every conversation you have had, newest first, with when
each started. The order is by start time, so a conversation stays where it
is however long you keep talking in it. Click a row to open it **in this
tab**; the rows are ordinary links, and no other tab moves. Each row
carries two independent marks: the conversation this tab has open is
highlighted, and a `●` means a turn is running there — in any conversation,
including one nobody is watching. A row labelled *unsupported format* has
details this version can't read; opening it may still work.

**Walking away from a running turn is the intended way to use this.** Open
another conversation, or close the tab: the turn keeps going, its answer
lands in that conversation's transcript, and you see the whole thing when
you come back. The `●` is how you know it finished. Each conversation has
its own agent and its own history, so they neither wait for nor disturb
each other — beyond the shared cap on how many think at once, above.

What comes back when a conversation is reopened is the conversation
itself: what you asked, what the model thought and answered, which tools
it ran and what they returned. What does not is anything that never
became part of the conversation — a `! cancelled` marker, a fallback
notice, or the half-written answer a cancel left on screen. A turn you
cancelled mid-answer reads as your message with no reply under it.

Everything this shell persists lives under
`~/.local/state/pikuri/pikuri-web-chat/` (`$XDG_STATE_HOME` if you set
it), so `rm -r` on that folder is a complete reset. Each conversation
becomes a directory under its `conversations/`, named for when it
started:

```
2026-08-27T12-03-51Z-3f9a/
    history.json   the conversation itself, in pikuri's own format
    attachments/   any file the model was shown
    meta.json      title, timestamps, which shell wrote it, which
                   connection it was last on
```

The `conversations/` folder is there from boot; a conversation's own
directory appears with its first completed turn, so a session you never
said anything in leaves nothing behind. Turns are saved as they finish, so
quitting keeps the conversation, and a restart drops you back into the
newest one with all the others a click away in the sidebar. What a restart
does lose is a turn that was still running when you quit — saves land at
turn end, and shutdown does not wait for one.

Run one at a time. A second `pikuri-web-chat` on another port shares that
folder, and each writes `history.json` whole, so two of them in the same
conversation will quietly overwrite each other's turns — and one of them
can write back a conversation the other just deleted. Nothing stops you,
and nothing will: there is no lock, deliberately. A single process already
serves every tab you care to open and runs turns in different
conversations side by side, so the second one only costs you.

Only `history.json` is stored — what you see on screen is rebuilt from it
each time, so a rendering or styling fix reaches every old conversation
too.

Nothing is encrypted. These files hold everything you typed and everything
the tools fetched, so the directories are created `0700` and that is the
whole of the protection.

To delete a conversation, hover its row in the sidebar and click the `×`.
It asks first, and then the whole directory goes — history, attachments
and all. **There is no undo**, deliberately: a conversation you want gone
is usually one you want gone because of what is in it, so nothing is kept
back for a grace period. Deleting the one you are reading takes you to the
newest conversation left, or to a fresh one if that was the last. The `×`
is disabled while *that* conversation has a turn in flight — only that one,
never the rest — so a delete cannot pull the folder out from under a save
that is about to land. `rm -r` on a conversation directory still works and
does the same thing.

Nothing prunes old conversations for you — there is no cap and no expiry.

## Develop

```sh
bin/pikuri-web-chat --dev
```

`--dev` runs Sinatra in development mode: `views/*.erb` is re-read per
request, and an exception renders in the browser instead of only on
stderr. `public/js/*.js` and `public/style.css` are read off disk on every
request in either mode — a browser reload picks them up.

Ruby under `lib/` is the exception: nothing reloads it, in either mode.
Each conversation's agent and listener stack are long-lived instances built
once by the boot script's factory, so a class change lands only in a fresh
process. That costs you any turn still running, but not the conversations
themselves — the restart reopens the newest one and rebuilds its transcript
from `history.json`, so a rendering change shows up on old conversations
immediately. Let a watcher restart it:

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
literal key is group/other-readable. The first `[[llm]]` is the connection
a conversation starts on when it has no saved one of its own; every other
entry is a `/model` away. Layering runs
`/etc/xdg/pikuri/config.toml` → `$XDG_CONFIG_HOME/pikuri/config.toml`.

There is deliberately no `--server` or `--model` flag: a connection lives in
this file and nowhere else, so there is never a question of which of the two
wins. To talk to a *new* server or model, add an `[[llm]]` entry — no
restart is needed to move between the ones already there.

### Switching model

`/model` moves the conversation you are reading onto another connection.
Every conversation remembers the one it is on, so switching one leaves the
others where they were, and a conversation reopens on the connection it last
spoke on. A new conversation starts on the one the tab was showing when you
asked for it, which makes "switch, then start fresh" do the obvious thing.

The status bar names the connection at all times. A pick made between turns
shows as `Local Qwen 3.6 → Grok` until the next message: pikuri applies a
switch at the *top of a turn*, so nothing changes under a reply that is
already streaming, and picking while the agent is working is fine — the turn
after it takes the new model.

The whole conversation moves with you, which is the point and also the one
sharp edge: 90k of history switched onto a 32k connection is over that
connection's limit immediately, and the next message fails. The picker shows
each connection's context window beside its name so the choice is an informed
one.

Delete an `[[llm]]` that some conversation was on and it opens on the first
connection instead; `/model` says so when you open it.

> [!WARNING]
> There is no authentication of any kind, and no notion of who is asking:
> anyone who can reach the port can read, write and delete every
> conversation. It is single-user by construction — a second person runs
> their own `pikuri-web-chat` under their own OS account. Keep `--bind` at
> its loopback default.

## Layout

```
┌────────────────┬──────────────────────────────────┐
│ Conversations  │ Transcript                       │
│                │                                  │
│ ● today 14:03  │ assistant: markdown, reasoning   │
│   today 09:41 ×│ tool calls & observations        │
│   yesterday    │                                  │
│                ├──────────────────────────────────┤
│ ● a turn runs  │ Input (Enter to send;            │
│   here         │   sending mid-turn injects)      │
│ × delete       ├──────────────────────────────────┤
│                │ status · tokens · + new · theme  │
└────────────────┴──────────────────────────────────┘
```

The URL is `/c/<conversation-id>`, so which conversation a tab is showing
is that tab's own business — bookmark it, open two, keep them on different
conversations. The transcript itself is server-side: the page arrives
rendered, and the SSE stream carries only deltas for the one conversation
this tab subscribed to. A reload, a second tab, or a dropped connection all
converge on the same state without the browser keeping any of it.

Sending a message while the agent is mid-turn injects it via pikuri's
`Control::Interloper` — it's delivered at turn start or once the
in-flight tool batch completes.
Diagnostics (pikuri internals, library errors, agent-loop diagnostics)
are printed to stderr.

## Test

```sh
bundle exec rspec
```
