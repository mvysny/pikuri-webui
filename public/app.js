// The project's entire JavaScript: one EventSource consuming the server's
// SSE feed, plus form/keyboard wiring. All rendering happens server-side
// (kramdown) — this file only places ready-made HTML fragments into the
// page by block id and keeps the status bar in sync.
'use strict';

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
const statusTokens = document.getElementById('status-tokens');
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
const updateStatus = ({ state, busy, pending, tokens }) => {
  statusState.textContent = state === 'queued' ? 'waiting for a free slot' : state;
  statusPending.textContent = pending > 0 ? `${pending} queued` : '';
  statusTokens.textContent = tokens;
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

// Submit stays enabled while the agent is busy: the server routes
// mid-turn sends through pikuri's Interloper (delivered at the next
// tool boundary), so "type while it works" is a feature, not an error.
composer.addEventListener('submit', (e) => {
  e.preventDefault();
  const text = promptEl.value;
  if (!text.trim()) return;
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

promptEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    composer.requestSubmit();
  }
});

cancelBtn.addEventListener('click', () => {
  const body = new FormData();
  body.set('conversation', viewing);
  fetch('/cancel', { method: 'POST', body });
});

// The fresh conversation has its own URL, so follow it. Other tabs stay
// exactly where they are — nothing about their conversation changed.
newBtn.addEventListener('click', () => {
  fetch('/conversations', { method: 'POST' })
    .then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
    .then((id) => { location.href = `/c/${encodeURIComponent(id)}`; })
    .catch(() => {});
});

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

// Theme toggle. The cookie is the store — the server reads it back on
// the next GET / and renders `data-theme` into the shell, so this only
// has to flip the live page. Label and title name the theme the button
// switches *to*, matching what index.erb rendered.
themeToggle.addEventListener('click', () => {
  const root = document.documentElement;
  const theme = root.dataset.theme === 'light' ? 'dark' : 'light';
  const other = theme === 'dark' ? 'light' : 'dark';
  root.dataset.theme = theme;
  themeToggle.textContent = theme === 'dark' ? '☀ light' : '☾ dark';
  themeToggle.title = themeToggle.ariaLabel = `Switch to the ${other} theme`;
  document.cookie = `theme=${theme}; path=/; max-age=31536000; samesite=lax`;
});
