// The page's spine: one EventSource fanned out to the transcript, the status
// bar and the conversation list, plus the composer's mount and the `commands`
// map — the wiring *between* features, which is why `/new` is reachable here
// as `conversations.start` and the palette that lists it is not.
//
// What is left here that is not wiring: the theme, small enough that a file of
// its own would be ceremony, and the dialogs a command opens. Their bodies are
// `<template>`s the server rendered; nothing here builds markup.
import { cloneTemplate, openDialog } from './dom.js';
import { initComposer } from './composer.js';
import { initStatusBar } from './statusbar.js';
import { initTranscript } from './transcript.js';
import { initConversations } from './conversations.js';

// The conversation this tab reads, fixed for the life of the page. The server
// addresses every frame to it, so nothing here filters.
const viewing = document.documentElement.dataset.conversation;

const themeToggle = document.getElementById('theme-toggle');

const statusbar = initStatusBar({ conversation: viewing });
const transcript = initTranscript();
const conversations = initConversations({ conversation: viewing });

const es = new EventSource(`/events?conversation=${encodeURIComponent(viewing)}`);
es.addEventListener('block', (e) => transcript.upsert(JSON.parse(e.data)));
es.addEventListener('remove', (e) => transcript.remove(JSON.parse(e.data).id));
es.addEventListener('status', (e) => statusbar.update(JSON.parse(e.data)));
es.addEventListener('reset', () => transcript.reset());
es.addEventListener('conversations', conversations.refresh);
// An auto-reconnect may have missed frames; reload to re-snapshot from the
// server-authoritative transcript.
es.onopen = () => { if (es.reconnected) location.reload(); es.reconnected = true; };

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

// Same cookie-is-the-store shape as the theme: the server resolves it into
// `data-thinking` on the next GET /, so this only has to move the live page.
// transcript.js owns what that means for the blocks.
const applyThinking = (open) => {
  transcript.setThinkingDefault(open);
  document.cookie = `thinking=${open ? 'expanded' : 'collapsed'}; path=/; max-age=31536000; samesite=lax`;
};

const openThinkingPicker = () => {
  const dialog = openDialog('Reasoning', cloneTemplate('tpl-thinking'));
  const current = document.documentElement.dataset.thinking;
  dialog.querySelectorAll('[data-thinking]').forEach((option) => {
    if (option.dataset.thinking === current) option.setAttribute('aria-current', 'true');
    option.addEventListener('click', () => {
      applyThinking(option.dataset.thinking === 'expanded');
      dialog.close();
    });
  });
};

// The same cookie-is-the-store shape again, and the cheapest of the three:
// every tool block already carries both forms, so the attribute *is* the
// switch — no walk, nothing for transcript.js to do.
const applyTools = (form) => {
  document.documentElement.dataset.tools = form;
  document.cookie = `tools=${form}; path=/; max-age=31536000; samesite=lax`;
};

const openToolLinesPicker = () => {
  const dialog = openDialog('Tool lines', cloneTemplate('tpl-toollines'));
  const current = document.documentElement.dataset.tools;
  dialog.querySelectorAll('[data-tools]').forEach((option) => {
    if (option.dataset.tools === current) option.setAttribute('aria-current', 'true');
    option.addEventListener('click', () => { applyTools(option.dataset.tools); dialog.close(); });
  });
};

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
    '/new': conversations.start,
    '/model': openModelPicker,
    '/theme': openThemePicker,
    '/thinking': openThinkingPicker,
    '/toollines': openToolLinesPicker,
    '/trifecta': () => openDialog('Lethal-trifecta report', cloneTemplate('tpl-trifecta')),
  },
});
