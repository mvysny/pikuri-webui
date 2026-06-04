// The project's entire JavaScript: one EventSource consuming the server's
// SSE feed, plus form/keyboard wiring. All rendering happens server-side
// (kramdown) — this file only places ready-made HTML fragments into the
// page by block id and keeps the status bar / log panel in sync.
'use strict';

const transcript = document.getElementById('transcript');
const composer = document.getElementById('composer');
const promptEl = document.getElementById('prompt');
const cancelBtn = document.getElementById('cancel');
const statusState = document.getElementById('status-state');
const statusPending = document.getElementById('status-pending');
const statusTokens = document.getElementById('status-tokens');
const logPanel = document.getElementById('log-panel');
const logLines = document.getElementById('log-lines');
const logToggle = document.getElementById('log-toggle');
const logBadge = document.getElementById('log-badge');

let unreadErrors = 0;

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
};

const appendLog = (line) => {
  logLines.textContent += `${line}\n`;
  logLines.scrollTop = logLines.scrollHeight;
  // Unread-error badge: counted here (not on the server) while the panel
  // is closed; opening the panel clears it.
  if (logPanel.hidden && /\b(ERROR|FATAL)\b/.test(line)) {
    unreadErrors += 1;
    logBadge.textContent = String(unreadErrors);
    logBadge.hidden = false;
  }
};

const toggleLog = () => {
  logPanel.hidden = !logPanel.hidden;
  if (!logPanel.hidden) {
    unreadErrors = 0;
    logBadge.hidden = true;
    logLines.scrollTop = logLines.scrollHeight;
  }
};

const es = new EventSource('/events');
es.addEventListener('block', (e) => upsertBlock(JSON.parse(e.data)));
es.addEventListener('remove', (e) => document.getElementById(JSON.parse(e.data).id)?.remove());
es.addEventListener('status', (e) => updateStatus(JSON.parse(e.data)));
es.addEventListener('log', (e) => appendLog(JSON.parse(e.data).line));
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
logToggle.addEventListener('click', toggleLog);
document.addEventListener('keydown', (e) => {
  if (e.key === 'l' && e.ctrlKey) {
    e.preventDefault();
    toggleLog();
  }
});
