/**
 * The conversation pane: block elements keyed by the server's block id, the
 * scroll that follows a streaming turn, and which reasoning blocks are open.
 *
 *     const transcript = initTranscript();
 *     es.addEventListener('block', (e) => transcript.upsert(JSON.parse(e.data)));
 *     es.addEventListener('stream', (e) => transcript.stream(JSON.parse(e.data)));
 *     es.addEventListener('snapshot', (e) => transcript.apply(JSON.parse(e.data).blocks));
 *     transcript.setThinkingDefault(false);   // /thinking → collapsed
 *     transcript.follow();                    // this tab just sent a message
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
 * resolves it before the browser paints it, then leaves it to the reader, per
 * **Reasoning disclosure** below. The blocks already in the page at mount are
 * left alone: `GET /c/:id` knows the browser it renders for and served them
 * resolved.
 *
 * Call once.
 *
 * @returns {{upsert: (block: {id: string, kind: string, html: string}) => void,
 *   stream: (frame: {id: string, append: string, tail: string}) => void,
 *   apply: (blocks: {id: string, kind: string, html: string}[]) => void,
 *   remove: (id: string) => void, reset: () => void,
 *   setThinkingDefault: (open: boolean) => void, follow: () => void}}
 */
export const initTranscript = () => {
  const transcript = document.getElementById('transcript');
  const root = document.documentElement;

  // Stick to the bottom only when the user is already there — scrolling up to
  // re-read must survive streaming updates.
  const nearBottom = () =>
    transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 40;

  const defaultOpen = () => root.dataset.thinking !== 'collapsed';

  // Parses a payload once, so `fill` can take it apart before placing it.
  const scratch = document.createElement('template');

  // == Reasoning disclosure
  //
  // A `<details>` already in the div is never rebuilt: it and its `<summary>`
  // stay, and only what follows the summary is swapped in from the new
  // payload (D_details_survive_rewrites). Replacing the whole innerHTML looks
  // equivalent and breaks clicking a streaming block: a click is a press and a
  // release on the *same* element, and at 15 rewrites a second the summary
  // under the pointer is usually a different one by the time the button comes
  // up, so no click happens at all. A synthetic or instant click never
  // straddles a rewrite, which is how this hides from a quick check. The
  // surviving element also carries `open` itself, so there is no state to
  // re-apply after a rewrite.
  //
  // A fresh `<details>` arrives `open` (the stored form) and is resolved to
  // this browser's default before the browser paints it.
  const fill = (el, html) => {
    scratch.innerHTML = html;
    const details = el.querySelector('details');
    const incoming = scratch.content.querySelector('details');
    if (details && incoming) {
      incoming.querySelector('summary')?.remove();
      details.replaceChildren(details.querySelector('summary'), ...incoming.childNodes);
      return;
    }
    el.replaceChildren(scratch.content);
    const fresh = el.querySelector('details');
    if (fresh) fresh.open = defaultOpen();
  };

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
    fill(el, html);
    return el;
  };

  return {
    /**
     * Upserts one block: a new one is appended, a known one has its content
     * replaced in place — a streamed message's first and last frames
     * (D_stream_blocks_once). A block already in the pane keeps its position —
     * a late update to a block something else has since followed must not move
     * it to the end.
     */
    upsert(block) {
      const stick = nearBottom();
      const el = place(block);
      if (!el.parentNode) transcript.append(el);
      if (stick) transcript.scrollTop = transcript.scrollHeight;
    },

    /**
     * Applies one frame of a message still streaming (D_stream_blocks_once):
     *
     *     <p>Hello.</p> <p>More.</p> <!--tail--> <p>Wor</p>
     *     └ finished, never touched ┘ ← append   └ tail, replaced ┘
     *
     * The blocks this delta finished go in before the `<!--tail-->` comment and
     * stay; only what follows it is swapped, so text selected or a wide code
     * block scrolled in a finished part survives the stream. The marker is a
     * direct child of the block div, or of its `<details>` for reasoning, whose
     * summary this never touches (D_details_survive_rewrites).
     *
     * A block with no marker is skipped rather than guessed at — the full frame
     * that ends the stream replaces it whole.
     *
     * @param {{id: string, append: string, tail: string}} frame
     */
    stream({ id, append, tail }) {
      const el = document.getElementById(id);
      const body = el?.querySelector(':scope > details') ?? el;
      const marker = body && [...body.childNodes].find(
        (node) => node.nodeType === Node.COMMENT_NODE && node.data === 'tail',
      );
      if (!marker) return;
      const stick = nearBottom();
      while (marker.nextSibling) marker.nextSibling.remove();
      scratch.innerHTML = append;
      marker.before(scratch.content);
      scratch.innerHTML = tail;
      marker.after(scratch.content);
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
     * Sets whether reasoning blocks start open, and moves every block already on
     * screen to match, whatever was clicked open or shut — collapse-all /
     * expand-all rather than a default for future blocks only
     * (D_details_per_block).
     *
     * Only the live page — app.js owns the cookie that makes it outlast this
     * one, the way it does for the theme.
     */
    setThinkingDefault(open) {
      root.dataset.thinking = open ? 'expanded' : 'collapsed';
      transcript.querySelectorAll('.block.thinking > details').forEach((details) => {
        details.open = open;
      });
    },

    /**
     * Pins the pane to the bottom, so the blocks that follow scroll into view.
     * For a message this tab just sent: the reader wants to see it land even
     * when a reasoning block expanded since has left them far above the tail,
     * where `upsert` would otherwise leave them be.
     */
    follow() {
      transcript.scrollTop = transcript.scrollHeight;
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
