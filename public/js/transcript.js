/**
 * The conversation pane: block elements keyed by the server's block id, the
 * scroll that follows a streaming turn, and which reasoning blocks are open.
 *
 *     const transcript = initTranscript();
 *     es.addEventListener('block', (e) => transcript.upsert(JSON.parse(e.data)));
 *     es.addEventListener('snapshot', (e) => transcript.apply(JSON.parse(e.data).blocks));
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
 * A `:thinking` block's html carries a `<details><summary>` the server wrote
 * (Web::Disclosure). A streamed one always arrives `open` — the listener is
 * shared by every tab and cannot know a per-browser preference — and this file
 * resolves it before the browser paints it, per **Reasoning disclosure** below.
 * The blocks already in the page at mount are left alone: `GET /c/:id` knows
 * the browser it renders for and served them resolved.
 *
 * Call once.
 *
 * @returns {{upsert: (block: {id: string, kind: string, html: string}) => void,
 *   apply: (blocks: {id: string, kind: string, html: string}[]) => void,
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

  // Create-or-fill one block div, without placing it and without scrolling —
  // both are the caller's, so `apply` can place a whole snapshot and scroll
  // once. A returned element with no `parentNode` is a fresh one.
  const place = ({ id, kind, html }) => {
    let el = document.getElementById(id);
    if (!el) {
      el = document.createElement('div');
      el.id = id;
      el.className = `block ${kind}`;
    }
    el.innerHTML = html;
    applyDisclosure(el);
    return el;
  };

  return {
    /**
     * Upserts one block: the first frame of a streamed message creates the div,
     * every re-render replaces its content in place (D_rerender_and_replace).
     * A block already in the pane keeps its position — a late update to a block
     * something else has since followed must not move it to the end.
     */
    upsert(block) {
      const stick = nearBottom();
      const el = place(block);
      if (!el.parentNode) transcript.append(el);
      if (stick) transcript.scrollTop = transcript.scrollHeight;
    },

    /**
     * Makes the pane the server's snapshot — every block in the server's order,
     * anything the server no longer holds dropped — which is what `GET /events`
     * opens with (D_subscribe_then_snapshot).
     *
     * It has to be one call, and it must not empty the pane first: the browser
     * paints between event dispatches, so a `reset` plus a `block` each blinks
     * the tail of an already-rendered conversation out and back. The usual case
     * here is a snapshot the page already agrees with — the cursor walk below
     * leaves such a pane structurally untouched, and refilling a block in place
     * is invisible.
     *
     * Lands the pane at the bottom — this runs once, just after the page loads,
     * and a conversation opens at its newest message.
     *
     * @param {{id: string, kind: string, html: string}[]} blocks in order.
     */
    apply(blocks) {
      // Walk both lists together: `next` is where the pane still agrees with
      // the snapshot, so a block in the right place already costs no mutation,
      // and whatever `next` is left pointing at is the tail the server has
      // dropped.
      let next = transcript.firstElementChild;
      blocks.forEach((block) => {
        const el = place(block);
        if (el === next) next = next.nextElementSibling;
        else transcript.insertBefore(el, next);
      });
      while (next) {
        const after = next.nextElementSibling;
        next.remove();
        next = after;
      }
      transcript.scrollTop = transcript.scrollHeight;
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
