// The composer — the message input, the slash-command palette above it, and
// the one decision about what a sent buffer *means*.
//
// A component over a server-rendered <form>: it is handed that element and
// owns everything inside it — the buffer and its auto-grow, the palette's
// filtering, highlight and pointer handling, and the keyboard that drives
// both. Nothing outside reaches in; it reaches out only through the callbacks
// its constructor was given.
//
// It sits between this project's other two script files on the admission rule
// D_no_js_build_step draws: it names no element id, no route and no
// conversation, so it is not app.js — but unlike dom.js it does know a *shape*
// of markup, which is the contract views/index.erb keeps for it:
//
//   <form>                                        ← the root, passed in
//     <ul role="listbox" hidden>                  ← the palette
//       <li role="option" data-command="/new" id> ← one row per command
//     <textarea role="combobox">                  ← the buffer
//     <button type="submit">                      ← send
//
// Roles rather than ids, because those are the same names the palette's ARIA
// contract is written in — the thing this maintains anyway.
//
// What it never does is render. The rows are the server's (the catalog is
// PikuriWeb::SlashCommand's); this only toggles `hidden` on them.

// The buffer is a command being *picked*: a leading slash with no space yet. A
// space means the user has moved on to writing a message, so the palette gets
// out of the way and stays out — and `/usr/bin/foo is missing` still sends.
const picking = (text) => text.startsWith('/') && !/\s/.test(text);

export class Composer {
  #input;
  #menu;
  #rows;
  #commands;
  #onmessage;
  #onunknown;

  // Rows currently passing the filter, and which of them is highlighted.
  // Per-browser state that never reaches the server (D_no_js_build_step).
  #matches = [];
  #selected = -1;
  // The row a pointer went down on, for the tap-tracking below.
  #pressed = null;

  // `form` is the root above. The options are what the *app* owns:
  //
  //   commands  — `{ '/new': fn }`, one arm per name the server may render.
  //               A rendered row with no arm here does nothing; a name here
  //               the server did not render is simply unreachable, which is
  //               how a config-gated command (`/model`) stays gated in the one
  //               place that decides it.
  //   onmessage — a composed message, as text. The buffer is cleared first;
  //               resolve falsy (or reject) and it is handed back.
  //   onunknown — a `/word` matching no row. The buffer is left alone, so the
  //               typo can be fixed instead of retyped.
  constructor(form, { commands = {}, onmessage, onunknown } = {}) {
    this.#input = form.querySelector('textarea');
    this.#menu = form.querySelector('[role="listbox"]');
    this.#rows = [...this.#menu.querySelectorAll('[role="option"]')];
    this.#commands = commands;
    this.#onmessage = onmessage;
    this.#onunknown = onunknown;

    // Every way of sending funnels through the form's own submit event — Enter
    // and the send button both end up here — so the one decision about what
    // the buffer means is made in one place. A slash command runs and is never
    // posted: a `/trifecta` that runs on Enter but arrives as a message when
    // tapped would be two different composers.
    //
    // Submit stays enabled while the agent is busy: the server routes mid-turn
    // sends through pikuri's Interloper (delivered at the next tool boundary),
    // so "type while it works" is a feature, not an error.
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      this.#submit();
    });

    this.#input.addEventListener('input', () => {
      this.#autogrow();
      this.#syncMenu();
    });
    // Clicking away leaves an open palette floating over the transcript.
    this.#input.addEventListener('blur', () => this.#closeMenu());
    this.#input.addEventListener('keydown', (e) => this.#onKeydown(e));

    // Picking a row by pointer. Preventing the pointerdown's default keeps the
    // caret in the textarea — the blur would close the palette out from under
    // the tap before it could land — and the cost of that on iOS is that no
    // `click` follows at all: a prevented pointerdown suppresses the
    // compatibility mouse events a non-interactive `<li>` depends on. So the
    // run hangs off `pointerup`, which a tap and a mouse release both deliver.
    // This is what makes the phone work — type `/t`, tap the row.
    //
    // Both halves must be the same row, so a press that slides off one and
    // lifts on another runs neither; a scroll of the palette cancels the
    // pointer outright.
    this.#rows.forEach((row) => {
      row.addEventListener('pointerdown', (e) => { e.preventDefault(); this.#pressed = row; });
      row.addEventListener('pointercancel', () => { this.#pressed = null; });
      row.addEventListener('pointerup', () => {
        const hit = this.#pressed === row;
        this.#pressed = null;
        if (hit) this.#run(row.dataset.command);
      });
    });

    this.#autogrow();
  }

  // One growing row rather than a fixed three, so the phone's composer costs
  // the transcript only the lines actually typed. `height: 0` first, or
  // scrollHeight reports the current height instead of the content's; the
  // offset/client delta adds back the border a `box-sizing: border-box` height
  // has to include. CSS caps the growth (`max-height`) and takes over
  // scrolling from there.
  #autogrow() {
    const input = this.#input;
    input.style.height = '0';
    input.style.height = `${input.scrollHeight + input.offsetHeight - input.clientHeight}px`;
  }

  // What a sent buffer means: the highlighted row if the palette has one, else
  // the first command the text is a prefix of — because the send button blurs
  // the textarea, which closes the palette out from under the very tap being
  // resolved, and the text is what survives that. A bare `/` is excluded for
  // the same reason nothing is highlighted under it: it is a menu to read, not
  // an armed trigger.
  //
  // A `/word` that resolves to nothing is a typo, and quietly sending it to
  // the model is the one outcome that helps nobody — so it is consumed here
  // too, and handed to `onunknown` instead.
  #submit() {
    const text = this.#input.value;
    if (!text.trim()) return;
    if (!picking(text) || text === '/') {
      this.#send(text);
      return;
    }
    const command = this.#matches[this.#selected]?.dataset.command
      ?? this.#rows.find((row) => row.dataset.command.startsWith(text))?.dataset.command;
    if (command) this.#run(command);
    else this.#onunknown?.(text);
  }

  // Cleared optimistically, because the buffer is this component's and a send
  // that lands must not leave the text sitting there. The failing case is the
  // conversation having gone away underneath this tab, and then the text comes
  // back rather than being swallowed.
  #send(text) {
    this.#input.value = '';
    this.#autogrow();
    this.#input.focus();
    Promise.resolve(this.#onmessage?.(text)).catch(() => false).then((sent) => {
      if (sent) return;
      this.#input.value = text;
      this.#autogrow();
    });
  }

  // A command's own effect is its only feedback — nothing is written to the
  // transcript (D_slash_command_palette) — so the buffer is emptied and the
  // palette closed before the arm runs, leaving the page as the command found
  // it.
  #run(name) {
    this.#input.value = '';
    this.#autogrow();
    this.#closeMenu();
    this.#commands[name]?.();
  }

  #highlight() {
    const current = this.#matches[this.#selected];
    this.#rows.forEach((row) => {
      row.classList.toggle('selected', row === current);
      row.setAttribute('aria-selected', String(row === current));
    });
    this.#input.setAttribute('aria-activedescendant', current?.id ?? '');
    this.#input.setAttribute('aria-expanded', String(!this.#menu.hidden));
  }

  // Open while the buffer is still being picked at.
  #syncMenu() {
    const text = this.#input.value;
    this.#matches = picking(text)
      ? this.#rows.filter((row) => row.dataset.command.startsWith(text))
      : [];
    this.#rows.forEach((row) => { row.hidden = !this.#matches.includes(row); });
    this.#menu.hidden = this.#matches.length === 0;
    // A bare `/` is a menu to read, not an armed trigger: nothing is
    // highlighted until it is narrowed or arrowed into, so Enter on `/` alone
    // sends rather than running whichever command happens to sort first.
    this.#selected = this.#menu.hidden || text === '/' ? -1 : 0;
    this.#highlight();
  }

  #closeMenu() {
    this.#matches = [];
    this.#selected = -1;
    this.#menu.hidden = true;
    this.#highlight();
  }

  #move(delta) {
    const count = this.#matches.length;
    if (count === 0) return;
    this.#selected = this.#selected < 0
      ? (delta > 0 ? 0 : count - 1)
      : (this.#selected + delta + count) % count;
    this.#highlight();
  }

  // Enter sends only from a real keyboard. The phone's on-screen Return is
  // left alone deliberately — it inserts its newline, as it does in the Claude
  // iPhone app, because a Return that sends makes a multi-line message
  // unwritable on the one keyboard that has no Shift+Enter. The send button is
  // the phone's send, and the palette's rows are its Enter.
  //
  // Enter arrives here rather than at the form so the palette can be consulted
  // first, and leaves as a submit so it cannot become a second sending path.
  #onKeydown(e) {
    if (!this.#menu.hidden) {
      if (e.key === 'ArrowDown') { e.preventDefault(); this.#move(1); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); this.#move(-1); return; }
      if (e.key === 'Escape') { e.preventDefault(); this.#closeMenu(); return; }
    }
    if (e.key !== 'Enter' || e.shiftKey) return;
    e.preventDefault();
    e.target.form.requestSubmit();
  }
}
