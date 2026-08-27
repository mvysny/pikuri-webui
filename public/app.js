// The project's entire JavaScript: one EventSource consuming the server's
// SSE feed, plus form/keyboard wiring. All rendering happens server-side
// (kramdown) — this file only places ready-made HTML fragments into the
// page by block id and keeps the status bar in sync.
'use strict';

const transcript = document.getElementById('transcript');
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
  // button from looking broken.
  newBtn.disabled = busy;
};

const es = new EventSource('/events');
es.addEventListener('block', (e) => upsertBlock(JSON.parse(e.data)));
es.addEventListener('remove', (e) => document.getElementById(JSON.parse(e.data).id)?.remove());
es.addEventListener('status', (e) => updateStatus(JSON.parse(e.data)));
// A new conversation started: the server's transcript is empty, so ours is
// too. Emptying in place rather than reloading keeps a half-typed message.
es.addEventListener('reset', () => transcript.replaceChildren());
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
