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

## Install

pikuri itself is a **path dependency on a sibling checkout**, not a
released gem — this shell uses `Agent::ServerPermits`, which no pikuri
release carries yet. So clone the two side by side:

```sh
git clone https://codeberg.org/mvysny/pikuri.git
git clone https://codeberg.org/mvysny/pikuri-web.git
cd pikuri-web
bundle install
```

`../pikuri` at master is what `bundle install` reads; `bundle exec rake
check` is how you find out whether master still fits.

## Run

There is no built-in connection, so start by writing
`~/.config/pikuri/config.toml`:

```toml
[[server]]
id  = "local"
url = "http://localhost:8080"
max_concurrent_requests = 1   # one reply at a time, at full speed

[[llm]]
name   = "Local Qwen 3.6"
server = "local"
model  = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
```

Then:

```sh
bin/pikuri-web-chat
```

and open <http://localhost:4567>. Boot without that file and it exits
printing the block above plus the path to write it to — there are no
`--server` / `--model` flags, because a connection lives in the file and
nowhere else (see [Configure](#configure)). `--port` and `--bind` are this
shell's own — `--bind` off its loopback default wants a password with it,
see [Locking the port](#locking-the-port):

```sh
bin/pikuri-web-chat --port 9292
```

Ctrl+C stops it. Open browser tabs don't delay the exit.

### How many conversations can think at once

A `[[server]]`'s `max_concurrent_requests` is the number of **requests in
flight against that inference server**. On a local box, write `1`:

```toml
[[server]]
id  = "local"
url = "http://localhost:8080"
max_concurrent_requests = 1
```

**Why 1, even on a `llama-server --parallel 4`.** You are reading one
conversation at a time, so what you feel is the speed of *that* reply, not
the throughput of the box. A reply crawling at 5 tok/s while another
conversation you are not looking at also crawls is worse than one at
20 tok/s while the other waits its turn. Waiting is cheap; watching
something slow is not.

Generation speed is bound by memory bandwidth, not compute, so whether a
second concurrent stream is cheap depends entirely on how much spare
bandwidth the box has. On a big discrete GPU, some. On an iGPU reading
through system DRAM — which is the machine you run a large MoE on, because
what you need there is capacity to hold the weights — essentially none, and
a second stream costs close to its full share.

MoE makes that worse rather than better. Decode reads only the experts each
token routes to, which is the whole reason a 35B-A3B fits your bandwidth at
all; but two sequences in a batch route to *different* experts, so the set
that must be read grows with the batch. Batching un-skips the weights MoE
exists to skip. It pays off at batch sizes far beyond anything a chat shell
produces, and in the two-to-eight range it is a straight loss.

`--parallel` also **splits the context window**: llama.cpp divides
`--ctx-size` by the slot count, so `--parallel 4 -c 32768` leaves each
conversation 8k instead of 32k. That cost is unconditional, and in this
shell it lands early — the whole history moves with the conversation.

Raise it for a server whose bandwidth is somebody else's problem — a cloud
endpoint, or a box big enough that you are not the only thing on it — where
total completion time across several conversations is what you are buying.
Setting it higher than the server has slots buys nothing either way; it just
moves the queue from this process into that one.

It sits on the `[[server]]` rather than the `[[llm]]` because the slots
belong to the box: two `[[llm]]` entries running two models on one server
share the same ceiling.

Omit the key and pikuri probes the server's own `/props` for the slot count
— which means a server started `--parallel 4` gets sized **4**, so omission
is how you end up with four half-speed replies without having chosen them.
Writing `1` is the ceiling being *your* word rather than the server's, and
the server's report is about what the box *can* do, not what you want it
doing while you watch one of the answers. Two more reasons
to write it: a request queued here is cancellable — ■ lands on a turn
waiting for a permit — whereas one queued inside llama.cpp is not, so you
would wait out the reply ahead of it; and a server that answers no `/props`
at all is left unlimited, which is right for a cloud endpoint and wrong for
anything you host.

Send in a second conversation while the first is working and the message
is accepted — never refused.

The ceiling caps requests to the server, not conversations: any number of them may
have a turn running, because a turn is not only inference, it also runs
tools. A conversation waiting on a web search is not using the server, so
its slot goes to somebody who is — which is why the cap is on the request,
and why a fast second conversation can answer while a first is off
fetching a page.

■ works on a conversation still waiting for a slot, not only on one the
server is already answering. Such a conversation reads as working rather
than waiting, though: the status bar cannot see the difference between
thinking and queueing for the server.

Note that web searches still serialize across conversations however high
you set this — the rate limiter that keeps you off provider blocklists is
scoped to your IP, not to a conversation.

### Keeping it on a home screen

The page ships a web manifest, so Safari's **Add to Home Screen** on an
iPad or iPhone gives pikuri its own icon and opens it without browser
chrome. It is still the same server on the same machine: the icon is a
bookmark, not an app, and it opens on nothing if the server isn't
running. Reaching it from a phone also means binding off loopback, so put
a password on it first — see [Locking the port](#locking-the-port). On an
iPad sharing the machine's own browser, none of that applies.

In Safari, not in another browser:

1. Open the address the server printed at boot — `http://127.0.0.1:9292`
   on the machine itself, its LAN address from a phone.
2. Tap **Share** — the square with the arrow out of it, in the bottom
   toolbar on an iPhone, the top-right one on an iPad.
3. Scroll the share sheet to **Add to Home Screen**.
4. The name defaults to `pikuri`; change it or don't, then tap **Add**.

Launch it from the icon and you get the page standalone — no address bar,
no tabs, Kuri in the app switcher. A home-screen app keeps its own
cookies, separate from Safari's, so a gated server asks for the password
once more the first time you open it from the icon — iOS sits on a blank
screen for a few seconds before putting that dialog up. Answer it once
and the cookie takes over; later launches go straight in.

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
| `/thinking` | whether reasoning blocks start expanded or collapsed |
| `/toollines` | show tool calls short, or in full |
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

### Reasoning blocks

Models that think out loud get a `▸ thinking` row for each stretch of
reasoning. Click it to read that stretch, click again to fold it away — one
block at a time, so you can open the step that produced a wrong answer
without wading through the rest.

`/thinking` sets whether they *start* open or folded, and moves everything
already on screen to match. Reasoning is never thrown away: folding it only
folds it, and reopening a saved conversation gets it back either way.

Which way they start also comes from the config file, shared with pikuri-tui:

```toml
[ui]
show_thinking = false      # start every reasoning block folded
```

`/thinking` overrides that in the browser you clicked it in, and remembers.
Clear your cookies and the file's value is what you get back.

### Tool lines

When the agent reaches for a tool, the transcript says so in two lines —
what it called, and what came back:

```
WebSearch(rails 8 credentials)
  OK, 4.2 kB
Calculator(4212 / 1024)
  4.11328125
Fetch(https://example.org/missing)
  Error: 404 Not Found
```

Every one of those lines is the tool's own: it says what it is called,
which argument is worth showing, and how to describe what it came back
with — a line count, a byte count, or the answer itself, because the size
of `4` is not the interesting thing about it. Nothing there is the model
narrating its own success. This shell only defangs the strings and cuts
them to the width of the page; a failure says so in red.

`/toollines` switches to the raw form, which is the same two lines with
nothing left out:

```
→ web_search(query="rails 8 credentials")
= Results for rails 8 credentials: the master key lives in config/master.key…
```

That is worth reaching for when a tool did something surprising and you
want the arguments exactly as the model wrote them. Both forms are always
in the page, so the switch is instant and changes nothing on the server —
the tab beside you keeps whichever form it was on.

Which form you start on comes from the same shared config file:

```toml
[ui]
tool_lines = "verbose"     # start on the raw form; "short" is the default
```

## Conversations

**+ new conversation** in the status bar starts a fresh one and takes this
tab to it. It is never refused, because a new conversation touches no
existing one: a turn already running — including in the conversation you
are leaving — carries on untouched, and other tabs stay where they are.

The sidebar lists every conversation you have had, newest first, titled by
when each started unless something has named it (see *Naming conversations*
below). The order is by start time, so a conversation stays where it is
however long you keep talking in it. Click a row to open it **in this
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

### Naming conversations

A conversation is titled with its start stamp — `2026-09-08 14:03` — until
something names it. Name a connection under `[titler]` and the opening
message becomes a real title instead, three to seven words, in whatever
language you wrote in:

```toml
[[llm]]
name           = "qwen-titler"
server         = "local"
model          = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
context_window = 8192
params         = { chat_template_kwargs = { enable_thinking = false } }

[titler]
llm = "qwen-titler"
```

That is the whole recipe, and the model in it is the only one recommended:
Qwen 3.6 35B A3B **with thinking turned off**. Thinking off is not a detail —
it is the difference between a title in about a second and one in half a
minute, and the half-minute version spends that time competing with your own
messages for the server. `params` goes to the server verbatim, so the spelling
above is llama.cpp's; another server may want something else, and the log says
so at boot if the model reasons anyway.

Point `[titler]` at a *second* `[[llm]]` even when it names the same model on
the same server, as above — it is `params` that differs. Keep both on one
`[[server]]` so titles queue behind your own requests instead of racing them,
and set `context_window` so the titler skips a round trip on every title.

The titler entry appears in `/model` like any other connection. Picking it
gives you a conversation that does not think, which is a legitimate thing to
want; it lasts as long as you stay in that conversation, because reopening
resolves to the *first* entry naming that model on that server.

Conversations from before you configured a titler get named too — each one
the first time you open it, off the history it loads anyway. So the sidebar
fills in as you revisit things rather than all at once, and a folder full of
old conversations costs you nothing until you go looking. Nothing touches a
conversation that already has a name, and there is no way to rename one by
hand yet.

Titling is best-effort and cannot break anything. No `[titler]`, a model that
answers nothing usable, a server that is down — the conversation keeps its
stamp, your turn is untouched, and nothing appears in the transcript. A title
lost that way is retried the next time the conversation is opened in a fresh
process.

If your model cannot be talked out of thinking at all, `llama-server` can do it
from its side instead — `--reasoning-budget 0`, or `--reasoning off` — and then
the titler is just an `[[llm]]` pointed at that alias with no `params` at all.
It costs a second full copy of the weights in VRAM, since each alias is its own
process, so it is the better answer only on a box with room.

**On smaller models: there is no recommendation to give.** A 4B is fast, but
titling is mostly a test of following instructions rather than of knowing
anything, and both small instruct models tried were rejected — one answered in
the wrong language five times out of eight. If you have a candidate, point
`[titler]` at it and run:

```
bin/probe-titler            # eight openers: short, long, code, a backtrace, Russian
bin/probe-titler --attacks  # six attempts to talk it out of titling
```

It drives the real titler, so what you see is what the sidebar would get.

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

### When it looks stuck

Puma answers `SIGPWR` (`SIGINFO` on macOS) with a backtrace of every
thread, printed to its stdout. The process carries on — it is a
snapshot, not a stop:

```sh
kill -PWR $(pgrep -f pikuri-web-chat)
```

Threads name themselves: `turn <conversation-id>` is that conversation's
turn in flight (`turn-idle`, a worker between turns), `sse-heartbeat` is
the keepalive, and the `puma srv tp *` threads serve requests — one of
them parked in the `/events` drain loop is a connected tab, which is
normal.

## Configure

Connections and API keys come from `~/.config/pikuri/config.toml` — the
same file pikuri-tui reads, so one file configures every pikuri shell.
There is no `--api-key` flag: a secret on the command line is visible in
`ps` and shell history.

A `[[server]]` is a box; an `[[llm]]` is a model running on one, naming it
by `id`. Splitting them means several models on one provider state its URL
and its key once:

```toml
[[server]]
id  = "local"
url = "http://localhost:8080"
max_concurrent_requests = 1   # see "How many conversations can think at once"

[[server]]
id  = "xai"
url = "https://api.x.ai"
api_key = "xai-…"

[[llm]]
name   = "Local Qwen 3.6"
server = "local"              # a [[server]] id, not a URL
model  = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"

[[llm]]
name   = "Grok"
server = "xai"
model  = "grok-4"
context_window = 2000000   # for a server the llama.cpp /props probe can't reach

[[llm]]
name   = "Grok 4 Fast"
server = "xai"             # same box, same key, written once
model  = "grok-4-fast"

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
literal key or password is group/other-readable. The first `[[llm]]` is the connection
a conversation starts on when it has no saved one of its own; every other
entry is a `/model` away. Layering runs
`/etc/xdg/pikuri/config.toml` → `$XDG_CONFIG_HOME/pikuri/config.toml`.
`server` references resolve after that merge, so a user file can add one
`[[llm]]` against a system file's `[[server]]` instead of re-pasting the
block — but since arrays replace wholesale, a file that declares
`[[server]]` at all replaces every lower layer's, and an `[[llm]]` left
pointing at a vanished `id` is a boot error rather than a silent fallback.

There is deliberately no `--server` or `--model` flag: a connection lives in
this file and nowhere else, so there is never a question of which of the two
wins. To talk to a *new* server or model, add an `[[llm]]` entry — no
restart is needed to move between the ones already there.

If you are coming from a config written before `[[server]]` existed — an
`[[llm]]` carrying a URL in `server` and its own `api_key` — boot fails with
the `[[server]]` block to paste, built from that URL and with the stray key
folded in. There is no compatibility shim; the error message is the
migration.

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

### Locking the port

Bound to its loopback default, the server is reachable only from the
machine it runs on and asks nobody for anything. Bind it anywhere else —
to reach it from a phone, say — and the port *is* the app: whoever finds
it can read, write and delete every conversation. So gate it:

```toml
[web]
user     = "mavi"
password = "a long passphrase"
```

The browser asks in its own dialog the first time, then sets a cookie and
stops asking — 90 days, renewed as you keep using it, so a phone's
home-screen icon opens straight into the conversation instead of stopping
for a password on every launch. The cookie is signed with the password
itself, so changing the password in the file logs every browser out
again.

Both keys are required together; without the table there is no password
at all (and no prompt), which is why binding off loopback without one
prints a warning at boot and starts anyway — you may well have a reverse
proxy in front doing this job already.

It is a gate, not accounts. One password for everyone, no logout, no
lockout on repeated guesses — pick a passphrase, not a word — and
everyone who gets in shares the same conversations. It stays single-user
by construction: a second person runs their own `pikuri-web-chat` under
their own OS account.

> [!WARNING]
> Basic credentials are sent on every request, in the clear over plain
> HTTP, so anyone who can watch the traffic can lift them. On a home LAN
> that is usually an acceptable trade; anywhere else, put TLS in front of
> it (a reverse proxy) or reach it over a private overlay such as
> Tailscale or WireGuard.

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
bundle exec rake check   # the spec suite plus the doc-layer tripwires; what CI runs
bundle exec rspec        # the spec suite alone
```

Why the code is the way it is lives under [`design/`](design/): the
decisions and the roads not taken in
[`decisions.md`](design/decisions.md), what must hold in
[`requirements.md`](design/requirements.md), the wiring and the flows in
[`architecture.md`](design/architecture.md), and how this compares with
Open WebUI in [`comparison.md`](design/comparison.md). `AGENTS.md` is the
must-not-break list a contributor — or their agent — reads first.
