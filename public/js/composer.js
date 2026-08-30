// The composer: the message input, the slash-command palette above it, the
// keyboard that drives both, and what a sent buffer *means* — a message posted
// to the conversation, or a command run.
//
// One feature, one file. This owns `#composer` and everything inside it, so it
// is paired with views/index.erb by design: it names the ids that template
// renders, and a change to that markup is a change here. That is the coupling
// being made explicit rather than hidden behind an abstraction — what it buys
// is that app.js never touches the input, the palette or the send route, and
// stays the page's wiring rather than a drawer of everything.
//
// What it does not do is render. The palette's rows are server-rendered whole
// (the catalog is PikuriWeb::SlashCommand's) and this only toggles `hidden` on
// them; see D_no_js_build_step.
//
// Still outside, for now: the stop button, which lives in this form but is
// driven by the status frame, and the unknown-command dialog. Both arrive as
// app.js's business until that boundary is settled.

// The buffer is a command being *picked*: a leading slash with no space yet. A
// space means the user has moved on to writing a message, so the palette gets
// out of the way and stays out — and `/usr/bin/foo is missing` still sends.
const picking = (text) => text.startsWith('/') && !/\s/.test(text);

// Mount the composer. What the *app* owns, and hands in:
//
//   conversation — the id every send is addressed to. Page state, read from
//                  the URL once and passed down; this file never resolves it.
//   commands     — { '/new': fn }, one arm per name the server may render. A
//                  rendered row with no arm here does nothing; a name here the
//                  server did not render is simply unreachable, which is how a
//                  config-gated command (/model) stays gated in the one place
//                  that decides it.
//   onunknown    — a `/word` matching no row. The buffer is left alone, so the
//                  typo can be fixed instead of retyped.
//   onsendfailed — a message that did not go out. The text is already back in
//                  the box by then; this is only the telling, and it is the
//                  app's because the status bar is not ours to write.
export const initComposer = ({ conversation, commands = {}, onunknown, onsendfailed }) => {
  const form = document.getElementById('composer');
  const input = document.getElementById('prompt');
  const menu = document.getElementById('slash-menu');
  const rows = [...menu.querySelectorAll('li')];

  // Rows currently passing the filter, and which of them is highlighted.
  // Per-browser state that never reaches the server (D_no_js_build_step).
  let matches = [];
  let selected = -1;

  // One growing row rather than a fixed three, so the phone's composer costs
  // the transcript only the lines actually typed. `height: 0` first, or
  // scrollHeight reports the current height instead of the content's; the
  // offset/client delta adds back the border a `box-sizing: border-box` height
  // has to include. CSS caps the growth (`max-height`) and takes over
  // scrolling from there.
  const autogrow = () => {
    input.style.height = '0';
    input.style.height = `${input.scrollHeight + input.offsetHeight - input.clientHeight}px`;
  };

  const highlight = () => {
    const current = matches[selected];
    rows.forEach((row) => {
      row.classList.toggle('selected', row === current);
      row.setAttribute('aria-selected', String(row === current));
    });
    input.setAttribute('aria-activedescendant', current?.id ?? '');
    input.setAttribute('aria-expanded', String(!menu.hidden));
  };

  // Open while the buffer is still being picked at.
  const syncMenu = () => {
    const text = input.value;
    matches = picking(text) ? rows.filter((row) => row.dataset.command.startsWith(text)) : [];
    rows.forEach((row) => { row.hidden = !matches.includes(row); });
    menu.hidden = matches.length === 0;
    // A bare `/` is a menu to read, not an armed trigger: nothing is
    // highlighted until it is narrowed or arrowed into, so Enter on `/` alone
    // sends rather than running whichever command happens to sort first.
    selected = menu.hidden || text === '/' ? -1 : 0;
    highlight();
  };

  const closeMenu = () => {
    matches = [];
    selected = -1;
    menu.hidden = true;
    highlight();
  };

  const move = (delta) => {
    if (matches.length === 0) return;
    selected = selected < 0
      ? (delta > 0 ? 0 : matches.length - 1)
      : (selected + delta + matches.length) % matches.length;
    highlight();
  };

  // Cleared before the post, because a send that lands must not leave its text
  // sitting in the box. Sending is never refused for being busy — a turn
  // queues — so the failing case is the conversation having gone away
  // underneath this tab, and then the text comes back rather than being
  // swallowed. A rejected fetch (the server gone) counts the same way.
  const send = (text) => {
    input.value = '';
    autogrow();
    input.focus();

    const body = new FormData();
    body.set('conversation', conversation);
    body.set('prompt', text);
    fetch('/messages', { method: 'POST', body })
      .then((r) => r.ok, () => false)
      .then((sent) => {
        if (sent) return;
        input.value = text;
        autogrow();
        onsendfailed?.();
      });
  };

  // A command's own effect is its only feedback — nothing is written to the
  // transcript (D_slash_command_palette) — so the buffer is emptied and the
  // palette closed before the arm runs, leaving the page as the command found
  // it.
  const run = (name) => {
    input.value = '';
    autogrow();
    closeMenu();
    commands[name]?.();
  };

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
  const submit = () => {
    const text = input.value;
    if (!text.trim()) return;
    if (!picking(text) || text === '/') {
      send(text);
      return;
    }
    const command = matches[selected]?.dataset.command
      ?? rows.find((row) => row.dataset.command.startsWith(text))?.dataset.command;
    if (command) run(command);
    else onunknown?.(text);
  };

  // Every way of sending funnels through the form's own submit event — Enter
  // and the send button both end up here — so the one decision about what the
  // buffer means is made in one place. A slash command runs and is never
  // posted: a `/trifecta` that runs on Enter but arrives as a message when
  // tapped would be two different composers.
  //
  // Submit stays enabled while the agent is busy: the server routes mid-turn
  // sends through pikuri's Interloper (delivered at the next tool boundary),
  // so "type while it works" is a feature, not an error.
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    submit();
  });

  input.addEventListener('input', () => {
    autogrow();
    syncMenu();
  });

  // Clicking away leaves an open palette floating over the transcript.
  input.addEventListener('blur', closeMenu);

  // Enter sends only from a real keyboard. The phone's on-screen Return is
  // left alone deliberately — it inserts its newline, as it does in the Claude
  // iPhone app, because a Return that sends makes a multi-line message
  // unwritable on the one keyboard that has no Shift+Enter. The send button is
  // the phone's send, and the palette's rows are its Enter.
  //
  // Enter is caught here rather than at the form so the palette can be
  // consulted first, and leaves as a submit so it cannot become a second
  // sending path.
  input.addEventListener('keydown', (e) => {
    if (!menu.hidden) {
      if (e.key === 'ArrowDown') { e.preventDefault(); move(1); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); return; }
      if (e.key === 'Escape') { e.preventDefault(); closeMenu(); return; }
    }
    if (e.key !== 'Enter' || e.shiftKey) return;
    e.preventDefault();
    form.requestSubmit();
  });

  // Picking a row by pointer. Preventing the pointerdown's default keeps the
  // caret in the textarea — the blur would close the palette out from under
  // the tap before it could land — and the cost of that on iOS is that no
  // `click` follows at all: a prevented pointerdown suppresses the
  // compatibility mouse events a non-interactive `<li>` depends on. So the run
  // hangs off `pointerup`, which a tap and a mouse release both deliver. This
  // is what makes the phone work — type `/t`, tap the row.
  //
  // Both halves must be the same row, so a press that slides off one and lifts
  // on another runs neither; a scroll of the palette cancels the pointer
  // outright.
  let pressed = null;
  rows.forEach((row) => {
    row.addEventListener('pointerdown', (e) => { e.preventDefault(); pressed = row; });
    row.addEventListener('pointercancel', () => { pressed = null; });
    row.addEventListener('pointerup', () => {
      const hit = pressed === row;
      pressed = null;
      if (hit) run(row.dataset.command);
    });
  });

  autogrow();
};
