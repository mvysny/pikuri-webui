// The project's entire JavaScript: one EventSource consuming the server's
// SSE feed, plus form/keyboard wiring. All rendering happens server-side
// (kramdown) — this file only places ready-made HTML fragments into the
// page by block id and keeps the status bar in sync.
'use strict';

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

const updateStatus = ({ busy, pending, tokens }) => {
  statusState.textContent = busy ? 'busy' : 'idle';
  statusPending.textContent = pending > 0 ? `${pending} queued` : '';
  statusTokens.textContent = tokens;
  cancelBtn.hidden = !busy;
  // The server refuses a switch mid-turn (409); matching that here keeps the
  // controls from looking broken.
  newBtn.disabled = busy;
  sidebar.querySelectorAll('.conversation').forEach((row) => {
    row.disabled = busy;
    row.title = busy ? 'the agent is mid-turn' : row.querySelector('.conversation-title').textContent;
  });
  sidebar.querySelectorAll('.conversation-delete').forEach((btn) => {
    btn.disabled = busy;
    btn.title = busy ? 'the agent is mid-turn' : 'Delete this conversation';
  });
};

// The sidebar's list, re-rendered by the server. Every conversation change
// funnels through here rather than reloading the page, which would cost each
// tab its half-typed message.
const refreshSidebar = () =>
  fetch('/conversations')
    .then((r) => r.text())
    .then((html) => { sidebar.innerHTML = html; });

const es = new EventSource('/events');
es.addEventListener('block', (e) => upsertBlock(JSON.parse(e.data)));
es.addEventListener('remove', (e) => document.getElementById(JSON.parse(e.data).id)?.remove());
es.addEventListener('status', (e) => updateStatus(JSON.parse(e.data)));
// A new conversation started: the server's transcript is empty, so ours is
// too. Emptying in place rather than reloading keeps a half-typed message.
// The sidebar changed as well — a row for the conversation just saved, and
// the highlight moved — so pull the server's markup for it back in.
es.addEventListener('reset', () => {
  transcript.replaceChildren();
  refreshSidebar();
});
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
  if (!promptEl.value.trim()) return;
  fetch('/messages', { method: 'POST', body: new FormData(composer) });
  promptEl.value = '';
  promptEl.focus();
});

promptEl.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    composer.requestSubmit();
  }
});

cancelBtn.addEventListener('click', () => fetch('/cancel', { method: 'POST' }));

newBtn.addEventListener('click', () => fetch('/conversations', { method: 'POST' }));

// Selecting or deleting a conversation. Delegated to the nav, so it survives
// the sidebar being re-rendered from the server. `redirect: 'manual'` declines
// the 303 the routes owe a no-JS browser: what redraws the page here is the
// reset + block frames a switch pushes to every tab, this one included.
//
// Which button was pressed decides where it goes — `getAttribute` rather than
// `.formAction`, whose getter falls back to the form's action (and to the
// document URL) when the attribute is absent, so it cannot tell them apart.
// Deletion is irreversible and there is no undo, hence the confirm.
sidebar.addEventListener('submit', (e) => {
  e.preventDefault();
  const deleteAction = e.submitter?.getAttribute('formaction');
  if (!deleteAction) {
    fetch(e.target.action, { method: 'POST', redirect: 'manual' });
    return;
  }
  const title = e.target.querySelector('.conversation-title').textContent;
  if (!confirm(`Delete "${title}"? This cannot be undone.`)) return;
  // Refresh either way: on 404 this tab's list was the stale thing, and
  // re-fetching is what heals it.
  fetch(deleteAction, { method: 'POST', redirect: 'manual' }).then(refreshSidebar);
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
