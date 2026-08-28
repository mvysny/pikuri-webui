// The project's entire JavaScript: one EventSource consuming the server's
// SSE feed, plus form/keyboard wiring. All rendering happens server-side
// (kramdown) — this file only places ready-made HTML fragments into the
// page by block id and keeps the status bar in sync.
'use strict';

// Which conversation this tab has open, and whether the agent is on it.
// `viewing` is fixed for the life of the page (it came from the URL); `live`
// moves, because another tab can send into a different conversation and take
// the agent with it — every frame names the live conversation, so each one
// re-answers the question.
const viewing = document.documentElement.dataset.conversation;
let live = document.documentElement.dataset.live === 'true';

// Transcript frames belong to whatever conversation the agent is on. Applying
// one to a tab reading a different conversation would interleave two
// transcripts, so drop them. (Server-side per-conversation subscriptions are
// what replace this; until then the fan-out really is a broadcast.)
const mine = (data) => data.conversation === viewing;

const transcript = document.getElementById('transcript');
const sidebar = document.getElementById('sidebar');
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

const updateStatus = ({ busy, pending, tokens, conversation }) => {
  live = conversation === viewing;
  statusState.textContent = live ? (busy ? 'busy' : 'idle') : (busy ? 'busy elsewhere' : 'not live');
  statusPending.textContent = live && pending > 0 ? `${pending} queued` : '';
  statusTokens.textContent = live ? tokens : '';
  // Cancel would stop whichever turn is running, which from a tab reading
  // another conversation is not the one on screen.
  cancelBtn.hidden = !busy || !live;
  // The server refuses a new conversation mid-turn (409); matching that here
  // keeps the control from looking broken. Rows stay clickable throughout —
  // reading another conversation while this one works is the point — but
  // delete is still refused.
  newBtn.disabled = busy;
  sidebar.querySelectorAll('.conversation-delete').forEach((btn) => {
    btn.disabled = busy;
    btn.title = busy ? 'the agent is mid-turn' : 'Delete this conversation';
  });
};

// The sidebar's list, re-rendered by the server. Every conversation change
// funnels through here rather than reloading the page, which would cost each
// tab its half-typed message. `viewing` rides along so the server can mark
// which row this tab has open, which it cannot know otherwise.
const refreshSidebar = () =>
  fetch(`/conversations?viewing=${encodeURIComponent(viewing)}`)
    .then((r) => r.text())
    .then((html) => { sidebar.innerHTML = html; });

const es = new EventSource('/events');
const onFrame = (handler) => (e) => {
  const data = JSON.parse(e.data);
  if (mine(data)) handler(data);
};
es.addEventListener('block', onFrame(upsertBlock));
es.addEventListener('remove', onFrame(({ id }) => document.getElementById(id)?.remove()));
// Status is not filtered: a frame naming a *different* live conversation is
// precisely how this tab learns it is no longer the live one.
es.addEventListener('status', (e) => updateStatus(JSON.parse(e.data)));
// The live conversation was cleared or swapped out from under this tab, and it
// is still ours — so empty in place rather than reloading, which keeps a
// half-typed message. The sidebar changed too (a row for what was just saved,
// and the live marker moved), so pull the server's markup back in.
es.addEventListener('reset', onFrame(() => {
  transcript.replaceChildren();
  refreshSidebar();
}));
// A conversation was deleted somewhere — this tab or another. Nothing about
// the transcript changed unless a `reset` said so, only the list.
es.addEventListener('conversations', refreshSidebar);
// On EventSource auto-reconnect the page may have missed frames; reload
// to re-snapshot from the server-authoritative transcript.
es.onopen = () => { if (es.reconnected) location.reload(); es.reconnected = true; };

// Submit stays enabled while the agent is busy: the server routes
// mid-turn sends through pikuri's Interloper (delivered at the next
// tool boundary), so "type while it works" is a feature, not an error.
composer.addEventListener('submit', (e) => {
  e.preventDefault();
  const text = promptEl.value;
  if (!text.trim()) return;
  const body = new FormData(composer); // before clearing: it reads the textarea
  promptEl.value = '';
  promptEl.focus();
  fetch('/messages', { method: 'POST', body }).then((r) => {
    if (r.ok) return;
    // 409: a turn is running in another conversation, so this one cannot take
    // the agent yet. Hand the text back instead of swallowing it.
    promptEl.value = text;
    statusState.textContent = r.status === 409 ? 'busy elsewhere — not sent' : 'not sent';
  });
});

promptEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    composer.requestSubmit();
  }
});

cancelBtn.addEventListener('click', () => fetch('/cancel', { method: 'POST' }));

// The fresh conversation has an id this page is not showing, so follow it
// rather than clearing in place. Other tabs stay put, on a conversation that
// is now saved and no longer live — which is the wanted behaviour, not a
// side effect.
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
    // exists; the live conversation is the only safe place to land.
    if (row.querySelector('.conversation').classList.contains('current')) location.href = '/';
    // Refresh otherwise: on 404 this tab's list was the stale thing, and
    // re-fetching is what heals it.
    else refreshSidebar();
  });
});

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
