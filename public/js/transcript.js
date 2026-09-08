/**
 * The conversation pane: block elements keyed by the server's block id, the
 * scroll that follows a streaming turn, and which reasoning blocks are open.
 *
 *     const transcript = initTranscript();
 *     es.addEventListener('block', (e) => transcript.upsert(JSON.parse(e.data)));
 *     transcript.setThinkingDefault(false);   // /thinking → collapsed
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
 * A `:thinking` block's html carries a `<details open><summary>` the server
 * wrote (Web::SseListener#disclose). The `open` in that markup is only the pre-JS
 * state — the listener is shared by every tab and cannot know a per-browser
 * preference — so resolving it is this file's job, per **Reasoning
 * disclosure** below.
 *
 * Call once.
 *
 * @returns {{upsert: (block: {id: string, kind: string, html: string}) => void,
 *   remove: (id: string) => void, reset: () => void,
 *   setThinkingDefault: (open: boolean) => void}}
 */
export const initTranscript = () => {
  const transcript = document.getElementById('transcript');
  const root = document.documentElement;

  // Stick to the bottom only when the user is already there — scrolling up to
  // re-read must survive streaming updates.
  const nearBottom = () =>
    transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 40;

  // == Reasoning disclosure
  //
  // Whether a block is open lives as `data-disclosure` on the *block div*, and
  // that is load-bearing rather than incidental: `upsert` replaces a block's
  // innerHTML on every delta, so a `<details open>` inside it is destroyed and
  // rebuilt ~15 times a second while reasoning streams. An attribute on the
  // div — which upsert reuses and never rebuilds — survives all of it, so
  // clicking a block open mid-turn sticks. Moving this inside the html payload
  // breaks only mid-turn expansion, which no spec here can catch.
  //
  // Absent attribute means "follow the default", which is what makes
  // setThinkingDefault a delete rather than a walk-and-set of two states.

  const defaultOpen = () => root.dataset.thinking !== 'collapsed';

  const wanted = (el) =>
    el.dataset.disclosure ? el.dataset.disclosure === 'open' : defaultOpen();

  const applyDisclosure = (el) => {
    const details = el.querySelector('details');
    if (details) details.open = wanted(el);
  };

  // `toggle` does not bubble, hence the capture phase. It also fires
  // asynchronously, so a flag set around the programmatic `details.open = …`
  // above would already be false by now — instead this writes an override only
  // when the element disagrees with what applyDisclosure would have set, which
  // is true of a user's click and false of our own write.
  transcript.addEventListener('toggle', (e) => {
    const details = e.target;
    if (details.tagName !== 'DETAILS') return;
    const el = details.closest('.block');
    if (el && details.open !== wanted(el)) {
      el.dataset.disclosure = details.open ? 'open' : 'closed';
    }
  }, true);

  // The server-rendered snapshot never passes through `upsert`, and the SSE
  // catch-up that would re-upsert it is a whole round trip away — long enough
  // for a collapsed-preference reader to watch reasoning they asked to hide.
  transcript.querySelectorAll('.block.thinking').forEach(applyDisclosure);

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
      applyDisclosure(el);
      if (stick) transcript.scrollTop = transcript.scrollHeight;
    },

    /**
     * Sets whether reasoning blocks start open, and moves the blocks already on
     * screen to match by dropping their per-block overrides — collapse-all /
     * expand-all rather than a default for future blocks only
     * (D_details_per_block).
     *
     * Only the live page — app.js owns the cookie that makes it outlast this
     * one, the way it does for the theme.
     */
    setThinkingDefault(open) {
      root.dataset.thinking = open ? 'expanded' : 'collapsed';
      transcript.querySelectorAll('.block.thinking').forEach((el) => {
        delete el.dataset.disclosure;
        applyDisclosure(el);
      });
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
