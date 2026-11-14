/**
 * The status bar: what this conversation is doing right now, and the ■ that
 * stops it. A busy bar reads
 *
 *     running   2 queued   Qwen → Remote   ctx 7.4k/64k (12%)   msg #2  Δ+1.6k
 *     <state>   <pending>  <model+pick>    <tokens>             <tokens_detail>
 *
 * and is driven frame by frame from the server:
 *
 *     const statusbar = initStatusBar({ conversation: viewing });
 *     es.addEventListener('status', (e) => statusbar.update(JSON.parse(e.data)));
 *
 * The bar is also where the *intended* connection is kept: the two model spans
 * hold bare names (the → between them is CSS's) and {@link intendedModel} reads
 * them back, so a pick that has not landed yet has one home rather than a copy
 * beside it.
 *
 * Markup contract: `#status-state`, `#status-pending`, `#status-model`,
 * `#status-model-pending`, `#status-tokens-ctx`, `#status-tokens-detail` and
 * `#cancel` must exist — a missing one throws at mount. `#cancel` sits inside
 * `#composer`'s markup but belongs here: what shows it is the status frame's
 * `busy`, which the composer knows nothing about.
 *
 * Call once.
 *
 * @param {object} opts
 * @param {string} opts.conversation the id a cancel is addressed to.
 * @returns {{update: (frame: object) => void, say: (text: string) => void,
 *   intendedModel: () => string, missingModel: () => string}} the handle the
 *   page's SSE fan-out and its /model dialog drive the bar through.
 */
export const initStatusBar = ({ conversation }) => {
  const state = document.getElementById('status-state');
  const pending = document.getElementById('status-pending');
  const model = document.getElementById('status-model');
  const modelPending = document.getElementById('status-model-pending');
  const tokensCtx = document.getElementById('status-tokens-ctx');
  const tokensDetail = document.getElementById('status-tokens-detail');
  const cancelBtn = document.getElementById('cancel');

  cancelBtn.addEventListener('click', () => {
    const body = new FormData();
    body.set('conversation', conversation);
    fetch('/cancel', { method: 'POST', body });
  });

  return {
    /**
     * Renders one status frame, as {Agents::Runner#status_data} shapes it —
     * `state` arrives already worded. Nothing but ■ is gated on `busy`:
     * sending injects rather than refusing, and a delete is refused per row by
     * the server's own re-render of the sidebar.
     */
    update({
      state: stateName, busy, pending: queued, tokens, tokens_detail: detail,
      model: name, model_pending: picked, model_missing: missing,
    }) {
      state.textContent = stateName;
      pending.textContent = queued > 0 ? `${queued} queued` : '';
      model.textContent = name;
      model.dataset.missing = missing ?? '';
      modelPending.textContent = picked ?? '';
      tokensCtx.textContent = tokens;
      tokensDetail.textContent = detail;
      cancelBtn.hidden = !busy;
    },

    /**
     * Writes the state segment, for something the server has no frame for — a
     * message that never went out. Transient: the next frame overwrites it.
     */
    say(text) {
      state.textContent = text;
    },

    /**
     * @returns {string} the connection this conversation is *meant* to be on,
     *   so a pick that has not landed yet wins over the live one.
     */
    intendedModel() {
      return modelPending.textContent || model.textContent;
    },

    /**
     * @returns {string} the connection saved before it left the config file,
     *   or `''` in the ordinary case.
     */
    missingModel() {
      return model.dataset.missing;
    },
  };
};
