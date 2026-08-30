// The page's spine: one EventSource fanned out to the transcript, the status
// bar, the sidebar, the drawer and the theme, plus the composer's mount and the
// arms of its slash commands — the wiring *between* features, which is why
// `/theme` and `/new` live here and the palette does not.
//
// Rendering is the server's: what markup this places, it was handed.
import { cloneTemplate, openDialog } from './dom.js';
import { initComposer } from './composer.js';
import { initStatusBar } from './statusbar.js';
import { initTranscript } from './transcript.js';

// The conversation this tab reads, fixed for the life of the page. The server
// addresses every frame to it, so nothing here filters.
const viewing = document.documentElement.dataset.conversation;

const chat = document.getElementById('chat');
const sidebar = document.getElementById('sidebar');
const drawerOpenBtn = document.getElementById('drawer-open');
const drawerCloseBtn = document.getElementById('drawer-close');
const newBtn = document.getElementById('new-conversation');
const themeToggle = document.getElementById('theme-toggle');

const statusbar = initStatusBar({ conversation: viewing });
const transcript = initTranscript();

// The sidebar's list, re-rendered by the server; `viewing` rides along so it
// can mark this tab's row. In place rather than a reload, which would cost each
// tab its half-typed message.
const refreshSidebar = () =>
  fetch(`/conversations?viewing=${encodeURIComponent(viewing)}`)
    .then((r) => r.text())
    .then((html) => { sidebar.innerHTML = html; });

const es = new EventSource(`/events?conversation=${encodeURIComponent(viewing)}`);
es.addEventListener('block', (e) => transcript.upsert(JSON.parse(e.data)));
es.addEventListener('remove', (e) => transcript.remove(JSON.parse(e.data).id));
es.addEventListener('status', (e) => statusbar.update(JSON.parse(e.data)));
es.addEventListener('reset', () => transcript.reset());
es.addEventListener('conversations', refreshSidebar);
// An auto-reconnect may have missed frames; reload to re-snapshot from the
// server-authoritative transcript.
es.onopen = () => { if (es.reconnected) location.reload(); es.reconnected = true; };

// The fresh conversation has its own URL, so this tab follows it; other tabs
// stay where they are.
const startConversation = () => {
  const body = new FormData();
  // What the new conversation inherits its connection from.
  body.set('viewing', viewing);
  fetch('/conversations', { method: 'POST', body })
    .then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
    .then((id) => { location.href = `/c/${encodeURIComponent(id)}`; })
    .catch(() => {});
};

newBtn.addEventListener('click', startConversation);

// Deleting a conversation, delegated to the nav so it survives the sidebar
// being re-rendered from the server; `redirect: 'manual'` declines the 303 the
// route owes a no-JS browser.
sidebar.addEventListener('submit', (e) => {
  e.preventDefault();
  const row = e.target.closest('li');
  const title = row.querySelector('.conversation-title').textContent;
  if (!confirm(`Delete "${title}"? This cannot be undone.`)) return;
  fetch(e.target.action, { method: 'POST', redirect: 'manual' }).then(() => {
    // Deleting what this tab reads leaves it on a page that no longer exists;
    // `/` picks the newest conversation left, or mints one.
    if (row.querySelector('.conversation').classList.contains('current')) location.href = '/';
    else refreshSidebar();
  });
});

// The phone's conversation drawer, a full-screen overlay over the chat. `inert`
// is why this is not the zero-JS checkbox trick: an overlay that is not a modal
// leaves the chat behind it tabbable and readable to a screen reader.
const setDrawer = (open) => {
  document.body.classList.toggle('drawer-open', open);
  chat.inert = open;
  drawerOpenBtn.setAttribute('aria-expanded', String(open));
};

drawerOpenBtn.addEventListener('click', () => setDrawer(true));
drawerCloseBtn.addEventListener('click', () => setDrawer(false));
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') setDrawer(false); });
// Leaving the phone layout with the drawer open would strand `inert` on a chat
// column nothing covers any more. Keep the query in sync with style.css's own
// breakpoint.
matchMedia('(max-width: 40rem)').addEventListener('change', () => setDrawer(false));

// The cookie is the store — the server reads it back on the next GET / and
// renders `data-theme` into the shell, so this only has to flip the live page.
// The toggle's label names the theme it switches *to*, matching index.erb.
const applyTheme = (theme) => {
  const other = theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = theme;
  themeToggle.textContent = theme === 'dark' ? '☀ light' : '☾ dark';
  themeToggle.title = themeToggle.ariaLabel = `Switch to the ${other} theme`;
  document.cookie = `theme=${theme}; path=/; max-age=31536000; samesite=lax`;
};

themeToggle.addEventListener('click', () =>
  applyTheme(document.documentElement.dataset.theme === 'light' ? 'dark' : 'light'));

const openThemePicker = () => {
  const dialog = openDialog('Theme', cloneTemplate('tpl-theme'));
  const current = document.documentElement.dataset.theme;
  dialog.querySelectorAll('[data-theme]').forEach((option) => {
    if (option.dataset.theme === current) option.setAttribute('aria-current', 'true');
    option.addEventListener('click', () => { applyTheme(option.dataset.theme); dialog.close(); });
  });
};

// The server answers 204 and the switch arrives on the status bar's own frame,
// so there is nothing to apply here.
const openModelPicker = () => {
  const dialog = openDialog('Model', cloneTemplate('tpl-model'));
  const current = statusbar.intendedModel();
  const missing = statusbar.missingModel();
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

// One arm per name in PikuriWeb::SlashCommand's catalog — the other half of
// that contract. A name the config gated out keeps its arm; it is simply never
// rendered a row to reach it by.
initComposer({
  conversation: viewing,
  onunknown: reportUnknownCommand,
  onsendfailed: () => statusbar.say('not sent'),
  commands: {
    '/new': startConversation,
    '/model': openModelPicker,
    '/theme': openThemePicker,
    '/trifecta': () => openDialog('Lethal-trifecta report', cloneTemplate('tpl-trifecta')),
  },
});
