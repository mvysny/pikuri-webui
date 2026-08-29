# The drawer as a `<dialog>`

`<dialog>` + `showModal()` is now in the project — `dom.js`'s `openDialog`, shipped with the slash
palette (`D_slash_command_palette`). Which makes the phone drawer's hand-rolled modality the obvious
next thing to look at: it does by hand what the platform now does for us three lines away.

**This is a refactor of shipped code, not part of the slash-command feature. Do not bundle it.**
It touches `D_one_shell_two_layouts`, which is a load-bearing decision; the slash-command work
touches nothing that already works.

## What the drawer hand-rolls today

`app.js`'s `setDrawer(open)` and its neighbours:

- `body.classList.toggle('drawer-open', open)` — CSS shows/hides the overlay.
- `chat.inert = open` — the background must not be tabbable or reachable by a screen reader. This is
  the reason the drawer is not the zero-JS checkbox trick, per its own comment.
- `drawerOpenBtn.setAttribute('aria-expanded', …)`.
- A document-level `keydown` handler for Escape.
- A `matchMedia('(max-width: 40rem)')` `change` handler, whose whole job is to un-strand `inert` on
  a chat column that stops being covered when the window crosses the breakpoint.

A modal `<dialog>` would give the inert background, Escape, focus containment and `::backdrop`
outright — four of those five bullets, and the fifth (`aria-expanded`) stays either way.

## The obstacle, and it is a real one

`#drawer` **is** the desktop sidebar column — same element, same `_sidebar.erb`, restyled by a media
query. That is `D_one_shell_two_layouts`, stated as "different *content* would be a template's job,
different placement never is."

A `<dialog>` cannot be both:

- A `<dialog>` without the `open` attribute is `display: none` from the UA stylesheet. To be the
  desktop's static column it needs a CSS override, and it would then render *without* being open —
  which works visually and is a lie structurally.
- `<dialog>` carries an implicit `role="dialog"`. On the desktop that column is a navigation region,
  not a dialog. So the wide layout would announce a dialog that is not one, and the drawer's whole
  point is that it is one element in two placements.
- `showModal()` puts the element in the top layer, which is exactly right below 40rem and exactly
  wrong above it.

So the honest options are:

1. **Reject.** Keep the `<div>` and the five lines of hand-rolled modality. The cost is real but
   bounded, it is written and working, and `D_one_shell_two_layouts` survives untouched.
2. **Two elements after all** — a `<nav>` column for the desktop and a `<dialog>` for the phone,
   both rendering `_sidebar.erb`. This buys the platform modality at the price of the decision that
   says one shell, and it reintroduces the duplicate-id problem the drawer footer was arranged to
   avoid. Probably worse than what we have.
3. **`<dialog>` with the role suppressed on the desktop** — override `display`, and neutralise the
   implicit role for the wide layout. Feels clever, which here is a warning sign: it makes the
   element's semantics depend on a media query, and nothing else in the codebase does that.

Lean: **(1), reject** — but only after actually trying (3) in a branch, because the prize (deleting
`inert` juggling *and* the `matchMedia` handler *and* the Escape listener) is larger than it looks
and the argument above is from the spec, not from having watched a screen reader.

## What would *not* be saved

Worth being honest before anyone starts:

- The `matchMedia` handler does not fully go away — a dialog open when the window widens past the
  breakpoint still has to `close()`. Same handler, one line different.
- `aria-expanded` on the ☰ button stays.
- The drawer's CSS (`position: fixed; inset: 0`) mostly stays; `::backdrop` replaces no rule that
  currently exists, since a full-screen overlay has no visible scrim today.

So the saving is `chat.inert`, the Escape listener, and getting focus containment we do not
currently have at all. The last of those is the strongest argument — the current drawer does not
trap focus, so tabbing out of an open drawer walks into an `inert` region and stops dead, which is
correct but not the same as containment.

## The helper this would reuse

`dom.js`'s `openDialog(title, body)` builds the chrome, `showModal()`s, and removes the element on
close; `.dialog` / `.dialog::backdrop` in `style.css` paint it, and the phone's full-screen variant
already exists in the `max-width: 40rem` block. The drawer is not shaped like that helper's callers,
though — it is not built-then-discarded, it is a permanent element that changes role — so this would
use the *element* and the CSS, not `openDialog` itself.

## If it graduates

- **Rejected** → a one-line why-not in `DECISIONS.md`'s `D_one_shell_two_layouts` *Consequences*:
  a `<dialog>` cannot be the desktop column and the phone overlay, so the drawer keeps hand-rolled
  modality. The trap is invisible in the code and someone will retry it every time they see
  `chat.inert`.
- **Accepted** → an amendment to `D_one_shell_two_layouts` saying what the one element now is, plus
  the AGENTS.md bullet that quotes it, plus `app.js`'s and `style.css`'s comments, which both narrate
  the current arrangement in detail.
