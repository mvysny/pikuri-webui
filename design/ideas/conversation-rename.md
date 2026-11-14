# Renaming a conversation by hand

Auto-titling shipped (`D_titler_connection`), so this is no longer the cheap
alternative to it — it is the "the model got it wrong" fix, plus the only way to
name a conversation on a box with no `[titler]` configured.

A pencil on the sidebar row, `PATCH /conversations/:id`.

## What already exists

- `ConversationStore#retitle(conversation, title)` — the whole write, in memory
  and on disk, tolerant of a conversation with no envelope yet. Built for the
  titler; a rename needs nothing more from the store.
- `Agents::Runner#land_title` is the shape the route body copies: rewrite the
  envelope *and* the runner's `@conversation` in one task, because the next
  turn-end save writes the title off that object and would revert a disk-only
  rename.
- The `conversations` SSE event plus `app.js`'s one `refreshSidebar()` — every
  tab re-fetches the list, already used by delete and by a landed title.

## The shape to copy, and the one new part

Delete shipped the pattern (`D_delete_no_undo`): a second submit button in the
row's existing form, aimed with `formaction` at `/conversations/:id/<verb>`. A
rename wants a **text input** rather than a button, which is the only genuinely
new piece — where it lives (inline on the row? a `<dialog>` like the slash
commands use?) is undecided. `openDialog` takes a Node, never an HTML string.

## The bit that is not optional

**`Q_stamp_test` has to be re-decided when this lands.** Today "has this been
titled?" is `ConversationStore#stamp_titled?`, matching the title against
`stamp_title(created_at)` — one line, no schema surface. That is enough only
while nothing but the titler writes titles. Once a person can name a
conversation, a name that happens to look like a stamp is indistinguishable
from an untitled one, and worse: `D_lazy_retro_titling` titles a stamp-shaped
conversation the next time it is opened, so auto-titling would overwrite a name
someone chose.

The answer is the alternative that entry rejected: a `title_source` key in
`meta.json`. Addable without a `SCHEMA` bump, because `#load_meta` ignores what
it does not read — but existing conversations need it backfilled, and
`stamp_titled?` becomes a read of that key instead of a regex.

## Open

- Does a rename count as a `/rename` slash command as well as a pencil? The
  catalog is `SlashCommand::CATALOG` and a command never writes to the
  transcript, which fits — but a command has no way to say *which* conversation
  other than "the one you are reading", which is probably fine.
- Length: the titler caps at 7 words / 80 chars for a sidebar row that
  `clamp(12rem, 20%, 20rem)` wide. A hand-written name wants the same cap, or
  the row layout is the thing that breaks.
