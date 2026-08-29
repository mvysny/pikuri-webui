// The app: one EventSource consuming the server's SSE feed, plus form,
// keyboard and command wiring. All rendering happens server-side (kramdown) —
// this file only places ready-made HTML fragments into the page by block id
// and keeps the status bar in sync.
//
// Generic DOM mechanics live next door in dom.js; anything here may name an
// element, a route or a conversation, and that is the difference between the
// two files. A module, so neither leaks a global (and modules are already
// strict, hence no 'use strict').
import { cloneTemplate, openDialog } from './dom.js';

// The conversation this tab has open, fixed for the life of the page: it came
// from the URL, and it is what the EventSource subscribes to. Everything this
// file receives is already about this conversation — the server does the
// addressing, so there is nothing here to filter.
const viewing = document.documentElement.dataset.conversation;

const transcript = document.getElementById('transcript');
const chat = document.getElementById('chat');
const sidebar = document.getElementById('sidebar');
const drawerOpenBtn = document.getElementById('drawer-open');
const drawerCloseBtn = document.getElementById('drawer-close');
const composer = document.getElementById('composer');
const promptEl = document.getElementById('prompt');
const cancelBtn = document.getElementById('cancel');
const newBtn = document.getElementById('new-conversation');
const statusState = document.getElementById('status-state');
const statusPending = document.getElementById('status-pending');
const statusModel = document.getElementById('status-model');
const statusModelPending = document.getElementById('status-model-pending');
const statusTokensCtx = document.getElementById('status-tokens-ctx');
const statusTokensDetail = document.getElementById('status-tokens-detail');
const themeToggle = document.getElementById('theme-toggle');

// Stick to the bottom only when the user is already there — scrolling up
// to re-read must survive streaming updates.
const nearBottom = () =>
  transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 40;

// `block` upserts by id: first frame of a streamed message creates the
// div, every re-render replaces its innerHTML in place.
const upsertBlock = ({ id, kind, html }) => {
  const stick = nearBottom();
  let el = document.getElementById(id);
  if (!el) {
    el = document.createElement('div');
    el.id = id;
    el.className = `block ${kind}`;
    transcript.append(el);
  }
  el.innerHTML = html;
  if (stick) transcript.scrollTop = transcript.scrollHeight;
};

// `queued` means the turn is accepted but another conversation is holding the
// executor. Saying so beats showing "busy" for a turn that has not started.
//
// `model` is what the agent is on; `modelPending` a pick that has not reached
// the top of a turn yet. The arrow between them is CSS's, so this span holds a
// bare name that /model can read back as the intended connection.
const updateStatus = ({
  state, busy, pending, tokens, tokens_detail: tokensDetail, model,
  model_pending: modelPending, model_missing: modelMissing,
}) => {
  statusState.textContent = state === 'queued' ? 'waiting for a free slot' : state;
  statusPending.textContent = pending > 0 ? `${pending} queued` : '';
  statusModel.textContent = model;
  statusModel.dataset.missing = modelMissing ?? '';
  statusModelPending.textContent = modelPending ?? '';
  statusTokensCtx.textContent = tokens;
  statusTokensDetail.textContent = tokensDetail;
  cancelBtn.hidden = !busy;
  // Nothing else is gated on busy any more: sending queues rather than
  // refusing, a new conversation touches no existing one, and delete is
  // refused per row by the server's own re-render of the sidebar.
};

// The sidebar's list, re-rendered by the server. Every conversation change
// funnels through here rather than reloading the page, which would cost each
// tab its half-typed message. `viewing` rides along so the server can mark
// which row this tab has open, which it cannot know otherwise.
const refreshSidebar = () =>
  fetch(`/conversations?viewing=${encodeURIComponent(viewing)}`)
    .then((r) => r.text())
    .then((html) => { sidebar.innerHTML = html; });

// Subscribed to this tab's conversation: the server sends only its frames,
// plus the server-wide `conversations` signal.
const es = new EventSource(`/events?conversation=${encodeURIComponent(viewing)}`);
es.addEventListener('block', (e) => upsertBlock(JSON.parse(e.data)));
es.addEventListener('remove', (e) => document.getElementById(JSON.parse(e.data).id)?.remove());
es.addEventListener('status', (e) => updateStatus(JSON.parse(e.data)));
// This conversation's transcript was emptied — a history load replaying into
// it. Emptying in place rather than reloading keeps a half-typed message.
es.addEventListener('reset', () => transcript.replaceChildren());
// A conversation was deleted somewhere — this tab or another. Nothing about
// the transcript changed unless a `reset` said so, only the list.
es.addEventListener('conversations', refreshSidebar);
// On EventSource auto-reconnect the page may have missed frames; reload
// to re-snapshot from the server-authoritative transcript.
es.onopen = () => { if (es.reconnected) location.reload(); es.reconnected = true; };

// One growing row rather than a fixed three, so the phone's composer costs the
// transcript only the lines actually typed. `height: 0` first, or scrollHeight
// reports the current height instead of the content's; the offset/client delta
// adds back the border a `box-sizing: border-box` height has to include. CSS
// caps the growth (`max-height`) and takes over scrolling from there.
const autogrow = () => {
  promptEl.style.height = '0';
  promptEl.style.height =
    `${promptEl.scrollHeight + promptEl.offsetHeight - promptEl.clientHeight}px`;
};
promptEl.addEventListener('input', autogrow);
autogrow();

// Every way of sending funnels through the form's own submit event — Enter and
// the send button both end up here — so the one decision about what the buffer
// *means* is made in one place. A slash
// command runs and is never posted: a `/trifecta` that runs on Enter but
// arrives as a message when tapped would be two different composers.
//
// Submit stays enabled while the agent is busy: the server routes
// mid-turn sends through pikuri's Interloper (delivered at the next
// tool boundary), so "type while it works" is a feature, not an error.
composer.addEventListener('submit', (e) => {
  e.preventDefault();
  const text = promptEl.value;
  if (!text.trim()) return;
  if (runIfCommand(text)) return;
  const body = new FormData(composer); // before clearing: it reads the textarea
  promptEl.value = '';
  autogrow();
  promptEl.focus();
  fetch('/messages', { method: 'POST', body }).then((r) => {
    if (r.ok) return;
    // Sending is never refused for being busy — a turn queues. So a failure
    // here is the conversation having gone away underneath this tab; hand the
    // text back rather than swallowing it.
    promptEl.value = text;
    autogrow();
    statusState.textContent = 'not sent';
  });
});

// Enter is claimed further down, beside the palette it has to consult; it
// comes back here as a submit.

cancelBtn.addEventListener('click', () => {
  const body = new FormData();
  body.set('conversation', viewing);
  fetch('/cancel', { method: 'POST', body });
});

// The fresh conversation has its own URL, so follow it. Other tabs stay
// exactly where they are — nothing about their conversation changed.
//
// Named rather than inlined into the click: /new dispatches to it too, and the
// button and the command must not become two paths that drift.
const startConversation = () => {
  const body = new FormData();
  // What the new conversation inherits its connection from: the server has no
  // other way to know which conversation this tab is reading.
  body.set('viewing', viewing);
  fetch('/conversations', { method: 'POST', body })
    .then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
    .then((id) => { location.href = `/c/${encodeURIComponent(id)}`; })
    .catch(() => {});
};

newBtn.addEventListener('click', startConversation);

// Deleting a conversation. Delegated to the nav so it survives the sidebar
// being re-rendered from the server; `redirect: 'manual'` declines the 303 the
// route owes a no-JS browser. Selecting needs nothing here any more — rows are
// links, and the browser follows them.
//
// Deletion is irreversible and there is no undo, hence the confirm.
sidebar.addEventListener('submit', (e) => {
  e.preventDefault();
  const row = e.target.closest('li');
  const title = row.querySelector('.conversation-title').textContent;
  if (!confirm(`Delete "${title}"? This cannot be undone.`)) return;
  fetch(e.target.action, { method: 'POST', redirect: 'manual' }).then(() => {
    // Deleting what this tab is reading leaves it on a page that no longer
    // exists; `/` picks the newest conversation left, or mints one.
    if (row.querySelector('.conversation').classList.contains('current')) location.href = '/';
    // Refresh otherwise: on 404 this tab's list was the stale thing, and
    // re-fetching is what heals it.
    else refreshSidebar();
  });
});

// The phone's conversation drawer: a full-screen overlay over the chat. Only
// the class is CSS's business — `inert` is the reason this is not the zero-JS
// checkbox trick, since an overlay that is not a modal leaves the chat behind
// it tabbable and readable to a screen reader.
//
// Opening a conversation needs nothing here: rows are links, so a tap is a page
// load and the page that arrives has the drawer closed by construction.
const setDrawer = (open) => {
  document.body.classList.toggle('drawer-open', open);
  chat.inert = open;
  drawerOpenBtn.setAttribute('aria-expanded', String(open));
};

drawerOpenBtn.addEventListener('click', () => setDrawer(true));
drawerCloseBtn.addEventListener('click', () => setDrawer(false));
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') setDrawer(false); });
// Leaving the phone layout with the drawer open would strand `inert` on a chat
// column that is no longer covered by anything. Keep the query in sync with
// style.css's own breakpoint.
matchMedia('(max-width: 40rem)').addEventListener('change', () => setDrawer(false));

// The cookie is the store — the server reads it back on the next GET / and
// renders `data-theme` into the shell, so this only has to flip the live page.
// The toggle's label and title name the theme it switches *to*, matching what
// index.erb rendered. Shared with /theme, so the button and the command cannot
// disagree about what applying a theme means.
const applyTheme = (theme) => {
  const other = theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  themeToggle.textContent = theme === 'dark' ? '☀ light' : '☾ dark';
  themeToggle.title = themeToggle.ariaLabel = `Switch to the ${other} theme`;
  document.cookie = `theme=${theme}; path=/; max-age=31536000; samesite=lax`;
};

themeToggle.addEventListener('click', () =>
  applyTheme(document.documentElement.dataset.theme === 'light' ? 'dark' : 'light'));

// — the slash-command palette —
//
// The catalog is server-rendered into #slash-menu (see PikuriWeb::SlashCommand);
// this filters it, tracks the highlighted row, and runs what was picked. A
// command never writes to the transcript — its own effect is the feedback.

const menu = document.getElementById('slash-menu');
const rows = [...menu.querySelectorAll('li')];
let matches = [];
let selected = -1;

const highlight = () => {
  rows.forEach((row) => {
    const on = row === matches[selected];
    row.classList.toggle('selected', on);
    row.setAttribute('aria-selected', String(on));
  });
  promptEl.setAttribute('aria-activedescendant', matches[selected]?.id ?? '');
  promptEl.setAttribute('aria-expanded', String(!menu.hidden));
};

// The buffer is a command being *picked*: a leading slash with no space yet. A
// space means the user has moved on to writing a message, so the palette gets
// out of the way and stays out — and `/usr/bin/foo is missing` still sends.
const picking = (text) => text.startsWith('/') && !/\s/.test(text);

// Open while the buffer is still being picked at.
const syncMenu = () => {
  const text = promptEl.value;
  matches = picking(text) ? rows.filter((row) => row.dataset.command.startsWith(text)) : [];
  rows.forEach((row) => { row.hidden = !matches.includes(row); });
  menu.hidden = matches.length === 0;
  // A bare `/` is a menu to read, not an armed trigger: nothing is highlighted
  // until it is narrowed or arrowed into, so Enter on `/` alone sends rather
  // than running whichever command happens to sort first.
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

const openThemePicker = () => {
  const dialog = openDialog('Theme', cloneTemplate('tpl-theme'));
  const current = document.documentElement.dataset.theme;
  dialog.querySelectorAll('[data-theme]').forEach((option) => {
    if (option.dataset.theme === current) option.setAttribute('aria-current', 'true');
    option.addEventListener('click', () => { applyTheme(option.dataset.theme); dialog.close(); });
  });
};

// The connection picker. The marked row is the *intended* one — a pick that has
// not landed yet is still what the user asked for — which is why the pending
// span is consulted before the live one. Both are read out of the status bar
// for the theme picker's reason: the server rendered the page before either
// could move.
//
// The server answers 204 and the switch shows up on the status bar's own
// frame, so there is nothing to apply here.
const openModelPicker = () => {
  const dialog = openDialog('Model', cloneTemplate('tpl-model'));
  const current = statusModelPending.textContent || statusModel.textContent;
  const missing = statusModel.dataset.missing;
  if (missing) {
    const note = dialog.querySelector('.model-missing');
    note.textContent = `${missing} is no longer in the config file; this conversation is on ${current}.`;
    note.hidden = false;
  }
  dialog.querySelectorAll('[data-model]').forEach((option) => {
    if (option.dataset.model === current) option.setAttribute('aria-current', 'true');
    option.addEventListener('click', () => {
      const body = new FormData();
      body.set('conversation', viewing);
      body.set('name', option.dataset.model);
      fetch('/model', { method: 'POST', body });
      dialog.close();
    });
  });
};

// textContent, never markup: `name` is whatever was typed.
const reportUnknownCommand = (name) => {
  const body = cloneTemplate('tpl-unknown-command');
  body.querySelector('.unknown-name').textContent = name;
  openDialog('No such command', body);
};

// The other half of the contract PikuriWeb::SlashCommand describes: every name
// in the server's catalog needs an arm here.
const runCommand = (name) => {
  promptEl.value = '';
  autogrow();
  closeMenu();
  switch (name) {
    case '/new': startConversation(); break;
    case '/model': openModelPicker(); break;
    case '/theme': openThemePicker(); break;
    case '/trifecta': openDialog('Lethal-trifecta report', cloneTemplate('tpl-trifecta')); break;
  }
};

// What a sent buffer means, for the composer's submit handler: the highlighted
// row if the palette has one, else the first command the text is a prefix of —
// because the send button blurs the textarea, which closes the palette out from
// under the very tap being resolved, and the text is what survives that. A bare
// `/` is excluded for the same reason nothing is highlighted under it: it is a
// menu to read, not an armed trigger.
//
// A `/word` that resolves to nothing is a typo, and quietly sending it to the
// model is the one outcome that helps nobody — so this consumes it too, and
// answers true for it: true means "dealt with; do not post this".
const runIfCommand = (text) => {
  if (!picking(text) || text === '/') return false;
  const command = matches[selected]?.dataset.command
    ?? rows.find((row) => row.dataset.command.startsWith(text))?.dataset.command;
  if (command) runCommand(command);
  else reportUnknownCommand(text);
  return true;
};

promptEl.addEventListener('input', syncMenu);
// Clicking away leaves an open palette floating over the transcript.
promptEl.addEventListener('blur', closeMenu);

// Enter sends only from a real keyboard. The phone's on-screen Return is left
// alone deliberately — it inserts its newline, as it does in the Claude iPhone
// app, because a Return that sends makes a multi-line message unwritable on the
// one keyboard that has no Shift+Enter. The send button is the phone's send,
// and the palette's rows are its Enter.
promptEl.addEventListener('keydown', (e) => {
  if (!menu.hidden) {
    if (e.key === 'ArrowDown') { e.preventDefault(); move(1); return; }
    if (e.key === 'ArrowUp') { e.preventDefault(); move(-1); return; }
    if (e.key === 'Escape') { e.preventDefault(); closeMenu(); return; }
  }
  if (e.key !== 'Enter' || e.shiftKey) return;
  e.preventDefault();
  composer.requestSubmit();
});

// Picking a row by pointer. Preventing the pointerdown's default keeps the
// caret in the textarea — the blur would close the palette out from under the
// tap before it could land — and the cost of that on iOS is that no `click`
// follows at all: a prevented pointerdown suppresses the compatibility mouse
// events a non-interactive `<li>` depends on. So the run hangs off `pointerup`,
// which a tap and a mouse release both deliver. This is what makes the phone
// work — type `/t`, tap the row.
//
// Both halves must be the same row, so a press that slides off one and lifts on
// another runs neither; a scroll of the palette cancels the pointer outright.
let pressed = null;
rows.forEach((row) => {
  row.addEventListener('pointerdown', (e) => { e.preventDefault(); pressed = row; });
  row.addEventListener('pointercancel', () => { pressed = null; });
  row.addEventListener('pointerup', () => {
    const hit = pressed === row;
    pressed = null;
    if (hit) runCommand(row.dataset.command);
  });
});
