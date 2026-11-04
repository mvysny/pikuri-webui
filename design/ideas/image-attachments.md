# Image attachments — show the model a picture

Goal: let the user hand the agent an image ("what's wrong in this screenshot?") from the
browser, before a turn and while one runs. Brainstormed 2026-11-04; the sibling idea is
pikuri-tui's `design/ideas/image-attachments.md`, and pikuri-tui's HEAD is the worked example
(`lib/shared/agent_session.rb` for the refusal check, `lib/shared/model/picker.rb` for the
eager probe).

## What pikuri provides (master as of `e979f02`, 2026-11-04)

Bump the pikuri pin to get them (`bundle update pikuri-core pikuri-pdf`):

- `Pikuri::Attachment.new(mime:, filename:, bytes:)` — the only attachment type; the upload's
  bytes go straight in (never hand ruby_llm a path or URL). `#digest` (SHA-256) and
  `#stored_name` (digest prefix + stem) are what `History#save` names the file under.
- `agent.run_loop(user_message:, attachments: [...])` — an attachment-only turn is fine.
- `interloper.inject_user_message(text, attachments: [...])` — the same mid-turn.
- `Event::UserTurn#attachments` — what was actually sent (mid-loop, minus any the model can't
  take; their `[shot.png not shown: …]` notes are then in `content`).
- `agent.modalities` (`{vision: false, …}`): a refused attachment makes `run_loop` raise
  `Pikuri::Agent::UnsupportedAttachmentError` **before** anything is appended; mid-turn it is
  withheld with a note instead. Only a reported `vision: false` refuses; `nil` means unknown.
- `ChatTransport#with_detected_modalities` — reads a router's `/v1/models` (or a bare
  `/props`) *without loading the model*; `self` when already stated or nothing reported.
  Network, so off-domain. `Agent#modalities` follows a model switch at once.
- `History#save` writes attachments content-addressed under `attachments/`, never deletes and
  never enumerates the folder; `History::Message#attachments` carries them back on load.
- **Breaking:** `Extension#on_user_message(ctx, content, attachments)` grew a third argument,
  and now fires on an attachment-only turn with `""` — check any override here.
- Reference: pikuri's `pikuri-core/bin/chat_attachments.rb` (PNG/JPEG/GIF/WebP, 5 MiB cap).

## Status

- **Done (server side):** pikuri bumped; `Conversations::Upload` (sniffed type, safe name,
  caps in `Web::App`); `Store#stash` / `#attachment`; `POST /messages` multipart + delete-race
  cleanup; `GET /c/:id/attachments/:name`; `Runner#submit(uploads:)` at both call sites;
  `SseListener` strip + CSS; `HistoryReplay` keeps the pictures; Puma's
  `http_content_length_limit`.
- **Done (browser):** `public/js/attachments.js` owns the tray (`#attachments`, `#attach`,
  `#attach-input`, `tpl-attachment`), caps read off `data-max-*` that `index.erb` renders from
  `Web::App`'s constants; `composer.js` sends `attachments[]`, restores them on a failed send,
  and hands paste (image-only clipboards) and drop to the tray; over-cap or non-accepted
  images are redrawn as JPEG (2048 → 1536 → 1024 long side). Smoke-tested in Chromium at
  desktop and 390px widths; **not yet on a real iPhone/iPad** (the `(hover: none)` ×, the
  photo picker, HEIC).
- **Next:** the eager modality probe (see Open), then graduate this idea.

## Decided

- **Input: a button in the composer, plus clipboard paste and drag-and-drop onto it** — all
  three funnel into one `addFiles(fileList)` in `composer.js`. The button is a hidden
  `<input type=file multiple accept="image/png,image/jpeg,image/gif,image/webp">`; on iOS it
  is the only path in and offers Photo Library and Camera.
- **The draft lives in the browser until send.** Picked images show as a row of small
  previews above/beside the textarea (`URL.createObjectURL`, revoked on remove/send), each
  with an ×. The × shows always under `@media (hover: none)` (iPhone, iPad) and on hover for
  a fine pointer. Nothing reaches the server before send, so there is no draft state there
  and no orphan to collect. The draft is client state the way the textarea text already is —
  mechanics, not rendering.
- **Transport: multipart on the existing `POST /messages`**, `attachments[]` beside `prompt`.
  `submit()` must accept empty text when images are attached (today `composer.js` returns on
  `!text.trim()`); the clear-before-post / restore-on-failure path restores the images too.
- **Caps: 5 MiB per image, 10 images per message.** The browser enforces both for instant
  feedback (an 11th image or an over-cap one is refused with a note in the composer); the
  server enforces both as the authority (Puma has no default body limit) and checks the mime
  is one of the four.
- **Downscale, don't refuse.** An image over 5 MiB (an iPhone photo, typically) is redrawn in
  the browser — `createImageBitmap` (EXIF orientation applied) → `<canvas>` → JPEG ~0.85,
  long side 2048 px, stepping down if still over — and renamed `.jpg`. An image under the cap
  is sent untouched, so a screenshot stays crisp and a GIF stays animated. Text in a photo
  is usually big enough to survive.
- **Bytes on disk at submit (option b).** The `POST` handler writes each image to
  `<conversation dir>/attachments/<stored_name>` *before* the domain task, off-domain, then
  submits. `History#save` writing the same content-addressed name later is harmless. The
  cost — an orphan file if the process dies mid-turn — is accepted. This keeps one serving
  path (disk) for resident and saved conversations alike.
  - Amends the invariant "a saved conversation is `history.json` plus `meta.json`, and
    nothing else" (and `D_replay_from_history`) to include pikuri's `attachments/`.
  - A brand-new conversation may have no folder yet — the write creates it.
  - Interacts with `D_delete_no_undo`: a delete racing a submit must not resurrect the
    folder. Check the order against {Agents::Runner#discard!}.
- **Serving: `GET /conversations/:id/attachments/:name`**, `Cache-Control: immutable` since
  the name is content-addressed; behind the password gate for free. `:name` is validated
  against `stored_name`'s shape (no path traversal). Originals are served; the browser scales
  them — no image library for thumbnails.
- **Transcript: images inside the `:user` block, below the text, in one row.** The strip is
  `display: flex; overflow-x: auto`; each image `max-height` ~12rem (desktop), ~7rem under the
  40rem breakpoint, `width: auto; max-width: 100%`, `loading="lazy"`. Each is wrapped in
  `<a href=… target=_blank>` for full size — no JS, no lightbox. An existing block kind, so
  two places: {Web::SseListener} (builds the `<img>` from `UserTurn#attachments`, translating
  to URLs — no `Pikuri::*` type reaches the browser) and `style.css`.
- **Replay keeps the pictures:** {Conversations::HistoryReplay}`#user_event` passes
  `message.attachments` into the synthesized `UserTurn` (today it drops them).
- **Blind model: detect modalities eagerly** via `transport.with_detected_modalities`, so the
  attach button is hidden (or disabled) *before* the first turn, not after a refusal.
  - Network → off-domain, on a worker; never in a task. Modalities are a property of a
    catalog connection, not of a conversation — so probe each `[[llm]]` once (at boot, in
    the background, and on a `/model` pick of one not yet probed), and let the factory mint
    the detected transport.
  - The browser learns it through the status frame (a `vision` flag beside the model), which
    `app.js` hands to `composer.js` — crossing features only through `app.js`.
  - The refusal check mirrors pikuri-tui's: a *pending* model switch's modalities win over
    the agent's current ones; only `vision: false` hides the button.
  - The residual case (probe not back yet, or reported nothing) still lets a blind model
    raise `UnsupportedAttachmentError` in the job → render it as an `:error` block; the
    composer has already cleared. Mid-turn, pikuri's withheld-with-a-note path needs nothing.

## Later (v2)

- `Q_tool_images` — showing an image a tool returned (`Tool::Result#attachments`) in the
  transcript. The chat's tool set reads no disk, so only web-fetched images; not now.

## Open

- A blind model on a **brand-new** conversation with an image-only opener: `run_loop` raises
  before anything is appended, so no save happens and the stashed folder has no `meta.json` —
  an unlisted orphan holding the image. Fix with the probe: `POST /messages` refuses images
  (422) when the conversation's model is known `vision: false`, *before* stashing. Today the
  refusal also shows nothing in the browser (logged to stderr only) — give it an `:error`
  block.

- Where the previews sit at phone width — a row above the textarea is the likely answer.
- Does the eager probe report anything for a non-llama.cpp server (OpenAI-compatible SaaS)?
  If not, `nil` — the button stays, and the residual path covers it.
