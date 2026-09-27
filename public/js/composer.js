// A command being *picked*: a leading slash with no space yet. A space means
// the user has moved on to writing a message, so `/usr/bin/foo is missing`
// still sends.
const picking = (text) => text.startsWith('/') && !/\s/.test(text);

/**
 * Mounts the composer: the message input, the slash palette above it, the
 * keyboard that drives both, and what a sent buffer *means* — a message posted
 * to the conversation, or a command run.
 *
 *     initComposer({ conversation: viewing, commands: { '/new': conversations.start } });
 *
 * Markup contract: `#composer`, `#prompt` and `#slash-menu` must exist and each
 * palette row must carry its name in `data-command` — a missing one throws
 * here rather than half-working. Rows are server-rendered whole; this only
 * toggles `hidden` and `.selected` on them.
 *
 * Call once.
 *
 * @param {object} opts
 * @param {string} opts.conversation the id every send is addressed to; page
 *   state, passed down rather than resolved here.
 * @param {Record<string, () => void>} [opts.commands] one arm per name the
 *   server may render. A rendered row with no arm does nothing; an arm the
 *   server did not render is unreachable, which is how a config-gated command
 *   stays gated in the one place that decides it.
 * @param {(text: string) => void} [opts.onunknown] a `/word` matching no row.
 *   The buffer is left alone, so the typo can be fixed instead of retyped.
 * @param {() => void} [opts.onsend] a message is going out, before its post;
 *   what it renders arrives later over SSE, not from here.
 * @param {() => void} [opts.onsendfailed] a message that did not go out; the
 *   text is already back in the box by then, this is only the telling.
 */
export const initComposer = ({ conversation, commands = {}, onunknown, onsend, onsendfailed }) => {
  const form = document.getElementById('composer');
  const input = document.getElementById('prompt');
  const menu = document.getElementById('slash-menu');
  const rows = [...menu.querySelectorAll('li')];

  // Rows currently passing the filter, and which of them is highlighted.
  let matches = [];
  let selected = -1;

  // `height: 0` first, or scrollHeight reports the current height instead of
  // the content's; the offset/client delta adds back the border a
  // `box-sizing: border-box` height has to include. `max-height` in style.css
  // caps the growth and takes over scrolling from there.
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

  const syncMenu = () => {
    const text = input.value;
    matches = picking(text) ? rows.filter((row) => row.dataset.command.startsWith(text)) : [];
    rows.forEach((row) => { row.hidden = !matches.includes(row); });
    menu.hidden = matches.length === 0;
    // A bare `/` is a menu to read, not an armed trigger: Enter on it must send
    // rather than run whichever command happens to sort first.
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

  // Cleared before the post, so a send that lands leaves no text in the box.
  // Sending is never refused for being busy — a turn queues — so a failure
  // means the conversation went away underneath this tab, and the text comes
  // back rather than being swallowed.
  const send = (text) => {
    input.value = '';
    autogrow();
    input.focus();
    onsend?.();

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

  // A command's own effect is its only feedback (D_slash_command_palette), so
  // the buffer is emptied and the palette closed before the arm runs.
  const run = (name) => {
    input.value = '';
    autogrow();
    closeMenu();
    commands[name]?.();
  };

  // What a sent buffer means: the highlighted row, else the first command the
  // text is a prefix of — the send button blurs the textarea, which closes the
  // palette out from under the very tap being resolved, and the text is what
  // survives that. A `/word` resolving to nothing is a typo, not a message.
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
  // and the ↑ button both — so what the buffer means is decided in one place. A
  // `/trifecta` that runs on Enter but posts as a message when tapped would be
  // two different composers.
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

  // Enter sends only from a real keyboard: the phone's on-screen Return is left
  // to insert its newline, because a Return that sends makes a multi-line
  // message unwritable on the one keyboard with no Shift+Enter — the ↑ button
  // is the phone's send. Caught here rather than at the form so the palette is
  // consulted first, then handed back as a submit so it cannot become a second
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

  // Preventing the pointerdown's default keeps the caret in the textarea — the
  // blur would close the palette out from under the tap — and the cost on iOS
  // is that no `click` follows at all: a prevented pointerdown suppresses the
  // compatibility mouse events a non-interactive `<li>` depends on. Hence
  // `pointerup`, which a tap and a mouse release both deliver. Both halves must
  // be the same row, so a press that slides off one and lifts on another runs
  // neither.
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
