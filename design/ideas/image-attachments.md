# Image attachments — show the model a picture

Goal: let the user hand the agent an image ("what's wrong in this screenshot?") from the
browser, before a turn and while one runs. To be brainstormed and built in its own session; the
sibling idea is pikuri-tui's `design/ideas/image-attachments.md`.

## What pikuri already provides (master as of `ddda137`, 2026-11-04)

Bump the pikuri pin to get them (`bundle update pikuri`):

- `Pikuri::Attachment.new(mime:, filename:, bytes:)` — the only attachment type; the upload's
  bytes go straight in (never hand ruby_llm a path or URL).
- `agent.run_loop(user_message:, attachments: [...])` — an attachment-only turn is fine.
- `interloper.inject_user_message(text, attachments: [...])` — the same mid-turn.
- `Event::UserTurn#attachments` — what was actually sent (mid-loop, minus any the model can't
  take; their `[shot.png not shown: …]` notes are then in `content`).
- `agent.modalities` (`{vision: false, …}` from llama.cpp's `/props`): a refused attachment makes
  `run_loop` raise `Pikuri::Agent::UnsupportedAttachmentError` **before** anything is appended;
  mid-turn it is withheld with a note instead. Check `modalities` to disable the affordance.
- `History#save` already writes attachments content-addressed under `attachments/`, and
  `History::Message#attachments` carries them back on load.
- **Breaking:** `Extension#on_user_message(ctx, content, attachments)` grew a third argument —
  check any override here.
- Reference implementation: pikuri's `pikuri-core/bin/chat_attachments.rb` (PNG/JPEG/GIF/WebP,
  5 MiB cap, `📎 shot.png (image/png, 48.3 kB)` line).

## Where it lands here

- `lib/pikuri_web/agents/runner.rb` — the two call sites: the idle `run_loop(user_message:)` job
  and the busy `@interloper.inject_user_message(message)`; both need `attachments:`.
- `lib/pikuri_web/web/app.rb` + `views/` + `public/` — the upload: input, endpoint, size cap.
- `lib/pikuri_web/web/sse_listener.rb` — how a `UserTurn` with attachments reaches the browser
  (inline the bytes, or a URL the server answers?).
- `lib/pikuri_web/conversations/history_replay.rb` — `user_event` builds
  `UserTurn.new(content: message.content)` and **drops `message.attachments`**: a resumed
  conversation would lose its pictures in the transcript (the model still has them).

## Open questions

- `Q_input` — file picker, drag-and-drop onto the composer, clipboard paste (`paste` event with
  an image item), or all three? One image per message or several?
- `Q_transport` — multipart POST beside the text, or upload first and reference an id? Size cap
  enforced where (browser, server, both)?
- `Q_render` — thumbnails in the transcript: serve them from the conversation's `attachments/`
  folder by content hash (cacheable, no base64 in SSE), or inline data URIs?
- `Q_refusal` — on a blind model: disable the affordance via `agent.modalities`, or surface
  `UnsupportedAttachmentError` as an inline error? (`modalities` is `nil` until the first turn's
  probe.)
- `Q_tool_images` — `read` returning an image already works; should the transcript show that
  image too, from the tool result's attachments?
