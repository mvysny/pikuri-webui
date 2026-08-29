// DOM mechanics the platform exposes only to script, with no knowledge of this
// app: no element ids, no conversation, no routes. That is the admission rule —
// a function that names something in index.erb belongs in app.js instead, or
// this file becomes the junk drawer its name is meant to prevent.
//
// Nothing here renders content. Markup the server can produce is the server's;
// what is left for script is the part HTML cannot declare — opening a modal,
// measuring a textarea — and that is what lives here.

// Create an element and assign properties in one expression, so building a
// tree reads as a tree.
export const el = (tag, props = {}) => Object.assign(document.createElement(tag), props);

// The content of a <template>, ready to append. Cloned, so the template stays
// intact for the next time the same dialog is opened.
export const cloneTemplate = (id) => document.getElementById(id).content.cloneNode(true);

// Open `body` as a modal dialog titled `title`, and return the <dialog> so the
// caller can wire up whatever it just put inside:
//
//   const dialog = openDialog('Theme', cloneTemplate('tpl-theme'));
//   dialog.querySelectorAll('button').forEach(...);
//
// `body` is a Node — never an HTML string — so a caller filling in a value can
// only do it through textContent, and no dialog can become a concatenation of
// something the user typed.
//
// showModal() is doing the heavy lifting: it makes the rest of the page inert,
// handles ESC, contains focus, and gives ::backdrop something to paint. The
// dialog is removed from the DOM when it closes, so none of them sit in the
// page at rest.
export const openDialog = (title, body) => {
  const opener = document.activeElement;

  const close = el('button', { type: 'button', className: 'dialog-close', textContent: '×' });
  close.setAttribute('aria-label', 'Close');
  const header = el('header', { className: 'dialog-header' });
  header.append(el('h2', { textContent: title }), close);

  const content = el('div', { className: 'dialog-body' });
  content.append(body);

  const dialog = el('dialog', { className: 'dialog' });
  dialog.append(header, content);
  close.addEventListener('click', () => dialog.close());
  // Fires for ESC and for #close alike, so this is the only teardown path.
  dialog.addEventListener('close', () => {
    dialog.remove();
    opener?.focus?.();
  });

  document.body.append(dialog);
  dialog.showModal();
  return dialog;
};
