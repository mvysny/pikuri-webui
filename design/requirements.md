# Requirements

What must hold — the promises the README's pitch makes, as official rules. One entry per
promise. A requirement *states*; it never argues: the fork behind it, if there is one, is a
`D_` entry it cites.

- **Owner-written.** An agent never adds, edits or retires an entry here; it proposes one —
  in conversation, or as a drafted entry in `design/ideas/<slug>.md` — and the owner moves
  it in.
- A requirement is a promise the README's pitch makes — what this shell does differently
  from the alternatives. The ruler for a proposal: **allow the opposite everywhere — is it
  still the pitched project?** "It cannot read your disk" → not the same project → an entry.
  "Never summon a renderer from inside the agent loop", "every route body is one task" →
  broken in places, same product → not an entry: an *invariant*, which is an `AGENTS.md`
  one-liner named here under *Enforced by*. A rule true of one class is its YARD header.
- Cite by slug — `R_<slug>`. `grep '^## R_' design/requirements.md` is the index.
- Shape: `## R_<slug> — <the promise in its operational form, one sentence>`, then
  **Status**, **If violated** (the observable failure, not the argument), **Enforced by** (a
  spec, a report, or honestly "review only"), **See** (the pitch passage and the `D_`
  entries behind it).
- A retired requirement stays as a tombstone. One that wants a *Rejected:* section is a
  decision — move it to `decisions.md`. **The first entry is the ruler**: later entries are
  trimmed to its length, never the other way round.

---

## R_chat_only — This shell's tool set holds no tool that reads the disk, runs a command or touches a repository

**Status:** Active.
**If violated.** The agent can go *find* a secret instead of only receiving what you typed:
pikuri's lethal trifecta closes, because this tool set already holds the untrusted-content
and egress legs. The failure is silent by construction — a user who read "there is nothing on
your machine for it to read" has no way to see that a later commit revoked it, and the
boot-time trifecta report is the only thing that says so out loud.
**Enforced by.** `bin/pikuri-web-chat`'s single conversation factory is the only tool wiring
in the process, so the trifecta report it prints at boot describes every agent, and the
`AGENTS.md` invariant routes a new capability to a sibling script. Otherwise review.
**See.** README "It's a chat, not an agent with hands on your machine"; `D_chat_only_entry_point`.

## R_no_build_step — The browser is served hand-written JavaScript with no dependency, no npm, no bundler and no build step

**Status:** Active.
**If violated.** What ships to the browser stops being what is in `public/js/`, and a clone
needs a second toolchain to run the thing at all — the cost the README's pitch says this
shell does not carry. A framework arriving is also how the client quietly becomes the
renderer, which is the state `D_server_authoritative_transcript` rests on not being in.
**Enforced by.** Review, and nothing mechanical: `client_contract_spec.rb` resolves every
*relative* import to a sibling file, but a bare package specifier is invisible to that scan.
What holds this is the `AGENTS.md` invariant — script is mechanics, never a renderer — which
keeps a framework from ever being wanted.
**See.** README's opening ("dependency-free and hand-written; there is no Node, no bundler,
no build step"); `D_no_js_build_step`, `D_feature_owns_its_file`.
