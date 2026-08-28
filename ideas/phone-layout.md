# A layout that works on a phone

Deferred out of `D_target_browsers`. The support matrix is Firefox on the desktop, Safari on the
iPad and Safari on the iPhone — and the iPhone is the one that does not work. iPads count as
desktop: enough screen for the sidebar-beside-chat layout as it stands.

## The blocker is not CSS

Reaching this app from an iPhone means the phone talks to a server running on the *desktop*, so
`--bind` has to leave 127.0.0.1 for a LAN address. There is no auth and no sessions
(`D_single_shared_conversation`), and the conversations folder is unencrypted by design, so a LAN
bind hands the whole history to anything else on the wifi. Today that is "the operator's risk" in
one README sentence, which is a fine answer for a deliberate `--bind 0.0.0.0` and a weak one for a
documented, encouraged phone workflow.

So before any of the layout work: **what makes phone access safe enough to recommend?** Options, none
costed yet — a bearer token in the URL the desktop prints as a QR code; HTTP basic over TLS with a
self-signed cert (iOS trust-store friction); an SSH tunnel from the phone (Blink/Termius, power-user
only); tailnet-only bind. Possibly the honest answer is that the phone layout lands and the README
still says "you are exposing your conversations, here is the flag". Decide this first — it may
change whether the layout is worth building.

## What is actually broken

There *is* a narrow-screen fallback already: `@media (max-width: 48rem)` stacks the sidebar into a
`max-height: 20vh` strip above the chat. Nobody has opened it on a real iPhone. Suspects, roughly
in order of how much they hurt:

- **`html, body { height: 100% }` vs. iOS's shrinking viewport.** Safari's URL bar and bottom
  toolbar change size as you scroll, so a `100%`-height flex column overshoots and pushes the
  composer and status bar under the browser chrome. `100dvh` / `min-height: 100dvh` is the lever
  (Safari 15.4+, inside the matrix — no polyfill needed, `D_target_browsers`).
- **The 16px form-control rule.** Body font is 15px and `#prompt` inherits it, so tapping the
  textarea makes iOS zoom the whole page in. Bump the textarea to 16px (not the body) and the zoom
  stops.
- **The on-screen keyboard.** With a fixed-height flex column the composer can end up behind the
  keyboard. `interactive-widget=resizes-content` on the viewport meta is the cheap first try; the
  VisualViewport API is the fallback and costs JS.
- **20vh of sidebar, permanently.** On a 667pt phone that is ~130px of conversation list you did not
  ask for, above the thing you came for. Wants to be a drawer. The existing CSS comment already
  rejects `<details>` (CSS cannot force it open, so it would be collapsible on the desktop too) —
  on a phone the shapes left are a checkbox/`:has()` toggle or ~6 lines of `app.js`, and `app.js`
  has room in its budget (`D_no_js_build_step` bans a *build step*, not hand-written JS).
- **Tap targets.** `.conversation` rows are `0.3rem 0.75rem` and the status-bar buttons are smaller;
  both are well under iOS's 44pt guidance. The delete ✕ is always visible under
  `@media (hover: none)` (`D_delete_no_undo`), so on a narrow row it competes for width too.

## The iPad is on the wrong side of the breakpoint

iPad portrait is 768px CSS = exactly 48rem, and `max-width: 48rem` matches at 768px. So an iPad in
portrait gets the stacked phone fallback *today*, which is the opposite of treating iPads as
desktop. Whatever else happens, the breakpoint moves below the iPad (40rem?) or the drawer replaces
it. Check on a real device rather than trusting this arithmetic.

## Installable / PWA

Separate from the layout, and only worth it once the security question above has an answer, because
an installed icon that opens a dead page whenever the desktop is asleep is worse than a bookmark.

Needs a `manifest.json` (`display: standalone`, icons) — plus the legacy
`apple-mobile-web-app-*` metas, since Safari's manifest support has historically been partial;
verify what current iOS actually honours rather than trusting either this note or memory. Standalone
mode also removes the URL bar, which takes the shrinking-viewport problem above with it, so the two
halves are friendlier together than apart.

Service worker: **probably not.** There is nothing to cache usefully — the page is a server-rendered
snapshot of server-authoritative state (`D_server_authoritative_transcript`) and an offline shell
would have no transcript to show. Skip it unless installability turns out to require one.
