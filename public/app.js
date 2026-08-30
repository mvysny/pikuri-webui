// The app: one EventSource consuming the server's SSE feed, the sidebar, the
// drawer, the theme, and the composer wired to this page. All rendering
// happens server-side (kramdown) — this file only places ready-made HTML
// fragments into the page by block id and keeps the status bar in sync.
//
// Generic DOM mechanics live next door in dom.js, and the composer — input,
// palette, keyboard — is a component in composer.js; anything here may name an
// element, a route or a conversation, and that is the difference between this
// file and those. What the composer cannot hold is therefore here: where a
// message is posted, and what each slash command does. A module, so none of
// them leaks a global (and modules are already strict, hence no 'use strict').
import { cloneTemplate, openDialog } from './dom.js';
import { Composer } from './composer.js';

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
const composerEl = document.getElementById('composer');
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

// The composer's transport half. It answers whether the message went out, and
// a `false` is what hands the text back to the box it was cleared from.
//
// Sending is never refused for being busy — a turn queues — so a failure here
// is the conversation having gone away underneath this tab.
const sendMessage = (text) => {
  const body = new FormData();
  body.set('conversation', viewing);
  body.set('prompt', text);
  return fetch('/messages', { method: 'POST', body }).then((r) => {
    if (!r.ok) statusState.textContent = 'not sent';
    return r.ok;
  });
};

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

// — the slash commands —
//
// The palette itself is the composer's (see composer.js): it filters the
// server-rendered rows, tracks the highlight, and resolves what was picked.
// What lives here is what each name *does*, because that is the half that
// names dialogs, routes and this tab's conversation.

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

// The composer, wired to this page. The arms below are the other half of the
// contract PikuriWeb::SlashCommand describes: every name in the server's
// catalog needs one here, and a name the config gated out of the catalog keeps
// its arm — it is simply never rendered a row to reach it by.
new Composer(composerEl, {
  onmessage: sendMessage,
  onunknown: reportUnknownCommand,
  commands: {
    '/new': startConversation,
    '/model': openModelPicker,
    '/theme': openThemePicker,
    '/trifecta': () => openDialog('Lethal-trifecta report', cloneTemplate('tpl-trifecta')),
  },
});
