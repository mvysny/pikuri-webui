/**
 * Creates an element and assigns properties in one expression, so building a
 * tree reads as a tree:
 *
 *     header.append(el('h2', { textContent: title }), close);
 *
 * @param {string} tag
 * @param {object} [props] assigned as *properties*, not attributes — `aria-*`
 *   still needs `setAttribute`.
 * @returns {HTMLElement}
 */
export const el = (tag, props = {}) => Object.assign(document.createElement(tag), props);

/**
 * The content of the `<template>` with this id, cloned so the template survives
 * being opened again.
 *
 * @param {string} id
 * @returns {DocumentFragment}
 */
export const cloneTemplate = (id) => document.getElementById(id).content.cloneNode(true);

/**
 * Opens `body` as a modal dialog titled `title` and returns the `<dialog>`, so
 * the caller can wire up what it just put inside:
 *
 *     const dialog = openDialog('Theme', cloneTemplate('tpl-theme'));
 *     dialog.querySelectorAll('[data-theme]').forEach(...);
 *
 * Cleanup: the dialog removes itself on close and hands focus back to the
 * opener, so none of them sit in the page at rest.
 *
 * @param {string} title
 * @param {Node} body never an HTML string, so a caller filling in a value can
 *   only do it through textContent and no dialog becomes a concatenation of
 *   something the user typed.
 * @returns {HTMLDialogElement} already open; `showModal` owns ESC, focus
 *   containment and `::backdrop`.
 */
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
