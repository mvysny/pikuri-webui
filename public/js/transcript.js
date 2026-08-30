/**
 * The conversation pane: block elements keyed by the server's block id, and the
 * scroll that follows a streaming turn.
 *
 *     const transcript = initTranscript();
 *     es.addEventListener('block', (e) => transcript.upsert(JSON.parse(e.data)));
 *
 * Every block arrives as ready-made HTML — kramdown ran on the server
 * (D_no_js_build_step) and this places fragments, never builds them.
 *
 * Markup contract: `#transcript` must exist — a missing one throws at mount. A
 * block is `div.block.<kind>` carrying the block id, which is what `GET /c/:id`
 * server-renders into the initial snapshot; the two must build the same element
 * or a streamed block would style differently from a replayed one. `style.css`
 * owns what each kind looks like.
 *
 * Call once.
 *
 * @returns {{upsert: (block: {id: string, kind: string, html: string}) => void,
 *   remove: (id: string) => void, reset: () => void}}
 */
export const initTranscript = () => {
  const transcript = document.getElementById('transcript');

  // Stick to the bottom only when the user is already there — scrolling up to
  // re-read must survive streaming updates.
  const nearBottom = () =>
    transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 40;

  return {
    /**
     * Upserts one block: the first frame of a streamed message creates the div,
     * every re-render replaces its content in place (D_rerender_and_replace).
     */
    upsert({ id, kind, html }) {
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
    },

    /** Drops one block; a block the page never rendered is not an error. */
    remove(id) {
      document.getElementById(id)?.remove();
    },

    /**
     * Empties the pane, for a history load replaying into this conversation.
     * In place rather than a reload, which would cost the tab a half-typed
     * message.
     */
    reset() {
      transcript.replaceChildren();
    },
  };
};
