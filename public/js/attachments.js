import { cloneTemplate } from './dom.js';

// What the server takes (PikuriWeb::Conversations::Upload::TYPES); anything
// else the browser can decode is re-encoded as a JPEG rather than refused.
const ACCEPTED = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

// Long sides tried, in order, for an image over the size cap. 2048 keeps text
// in a phone photo readable; the smaller ones exist only for the rare photo
// that still does not fit.
const LONG_SIDES = [2048, 1536, 1024];

/**
 * Mounts the images of the message being written: the `+` button and its file
 * picker, and the tray of previews above the textarea, each with a × to drop
 * it. The composer owns the send and hands images in from paste and drop.
 *
 *     const attachments = initAttachments({ onrefused: statusbar.say });
 *     attachments.add(e.clipboardData.files);
 *     const files = await attachments.take();   // empties the tray
 *
 * Markup contract: `#attachments` carrying `data-max-images` and
 * `data-max-bytes` (the server's own caps, so they live once), `#attach`,
 * `#attach-input`, and `<template id="tpl-attachment">` with an `img` and a
 * `.attachment-remove`.
 *
 * An image over the size cap — a phone photo, typically — is redrawn smaller
 * as a JPEG; one under it is sent untouched, so a screenshot stays sharp and a
 * GIF stays animated. A format the server does not take but the browser can
 * decode (HEIC on Safari) goes through the same redraw.
 *
 * Call once.
 *
 * @param {object} opts
 * @param {(text: string) => void} [opts.onrefused] an image was not added —
 *   over the count, undecodable, or still too large; says which.
 * @returns {{add: (files: Iterable<File>) => void, count: () => number,
 *   take: () => Promise<File[]>, restore: (files: File[]) => void}}
 */
export const initAttachments = ({ onrefused }) => {
  const tray = document.getElementById('attachments');
  const button = document.getElementById('attach');
  const picker = document.getElementById('attach-input');
  const maxImages = Number(tray.dataset.maxImages);
  const maxBytes = Number(tray.dataset.maxBytes);

  // One per preview: the original's object URL, its <li>, and `ready` — the
  // file that will be sent, or null once it has been refused.
  let drafts = [];

  const drop = (draft) => {
    URL.revokeObjectURL(draft.url);
    draft.item.remove();
    drafts = drafts.filter((d) => d !== draft);
    tray.hidden = drafts.length === 0;
  };

  // White under the image first: JPEG has no alpha, and a transparent PNG
  // would otherwise come out on black.
  const redraw = async (file) => {
    let bitmap;
    try {
      bitmap = await createImageBitmap(file);
    } catch {
      return null;
    }
    try {
      for (const side of LONG_SIDES) {
        const scale = Math.min(1, side / Math.max(bitmap.width, bitmap.height));
        const canvas = document.createElement('canvas');
        canvas.width = Math.round(bitmap.width * scale);
        canvas.height = Math.round(bitmap.height * scale);
        const g = canvas.getContext('2d');
        g.fillStyle = '#fff';
        g.fillRect(0, 0, canvas.width, canvas.height);
        g.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
        const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.85));
        if (blob && blob.size <= maxBytes) {
          return new File([blob], `${file.name.replace(/\.[^.]*$/, '') || 'image'}.jpg`, { type: 'image/jpeg' });
        }
      }
      return null;
    } finally {
      bitmap.close();
    }
  };

  const fit = (file) =>
    (ACCEPTED.includes(file.type) && file.size <= maxBytes ? Promise.resolve(file) : redraw(file));

  const add = (files) => {
    const incoming = [...files];
    const room = maxImages - drafts.length;
    if (incoming.length > room) onrefused?.(`at most ${maxImages} images per message`);

    incoming.slice(0, Math.max(room, 0)).forEach((file) => {
      const item = cloneTemplate('tpl-attachment').firstElementChild;
      const url = URL.createObjectURL(file);
      const img = item.querySelector('img');
      img.src = url;
      img.alt = file.name;
      const draft = { url, item, ready: fit(file) };
      item.querySelector('.attachment-remove').addEventListener('click', () => drop(draft));
      drafts.push(draft);
      tray.append(item);
      tray.hidden = false;

      draft.ready.then((ready) => {
        if (ready) return;
        onrefused?.(`${file.name}: not an image this can send`);
        drop(draft);
      });
    });
  };

  button.addEventListener('click', () => picker.click());
  picker.addEventListener('change', () => {
    add(picker.files);
    // Or picking the same file again after removing it fires no `change`.
    picker.value = '';
  });

  return {
    add,
    count: () => drafts.length,

    /**
     * Empties the tray at once, so a second send cannot carry the same images,
     * and resolves once any redraw still running has finished.
     *
     * @returns {Promise<File[]>} what to send, refused ones left out
     */
    async take() {
      const taken = drafts;
      taken.forEach((draft) => { URL.revokeObjectURL(draft.url); draft.item.remove(); });
      drafts = [];
      tray.hidden = true;
      return (await Promise.all(taken.map((draft) => draft.ready))).filter(Boolean);
    },

    /**
     * Puts back what {@link take} handed out, for a send that did not land.
     * They already fit, so nothing is redrawn twice.
     *
     * @param {File[]} files
     */
    restore: (files) => add(files),
  };
};
