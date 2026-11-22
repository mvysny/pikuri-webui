/**
 * The conversation list: the sidebar the server re-renders, deleting a row, and
 * starting a fresh conversation — plus the phone's drawer, which is how that
 * same list is reached under the 40rem breakpoint.
 *
 *     const conversations = initConversations({ base, conversation: viewing });
 *     es.addEventListener('conversations', conversations.refresh);
 *     initComposer({ commands: { '/new': conversations.start } });
 *
 * Rows are `_sidebar.erb`'s and are never built here; this reads
 * `.conversation-title` and the `.current` mark off them, and posts to the
 * `action` each row's own delete form carries.
 *
 * Markup contract: `#sidebar`, `#chat`, `#drawer-open`, `#drawer-close` and
 * `#new-conversation` must exist — a missing one throws at mount. `.drawer-open`
 * on `<body>` is the overlay's visible state and `style.css` owns what that
 * looks like. `#new-conversation` sits in `#drawer-footer` beside
 * `#theme-toggle`, which is the root's: the id is the contract, not the nesting.
 *
 * Ctrl+Shift+O (⌘⇧O) starts a conversation from anywhere on the page, the input
 * included, as the button does.
 *
 * Call once. Cleanup: nothing drops the `keydown` this puts on `document` or
 * the `matchMedia` change listener — both are meant to live as long as the page.
 *
 * @param {object} opts
 * @param {string} opts.base the path the shell is served under, `data-base` —
 *   `"/pikuri-webui"`, or empty at the root; every URL here starts with it.
 * @param {string} opts.conversation the id this tab reads, which marks its own
 *   row and decides where a delete leaves the tab.
 * @returns {{refresh: () => Promise<void>, start: () => void}}
 */
export const initConversations = ({ base, conversation }) => {
  const sidebar = document.getElementById('sidebar');
  const chat = document.getElementById('chat');
  const openBtn = document.getElementById('drawer-open');
  const closeBtn = document.getElementById('drawer-close');
  const newBtn = document.getElementById('new-conversation');

  /**
   * Re-renders the list from the server. In place rather than a reload, which
   * would cost every open tab its half-typed message.
   *
   * @returns {Promise<void>} resolves once the new rows are in the page.
   */
  const refresh = () =>
    fetch(`${base}/conversations?viewing=${encodeURIComponent(conversation)}`)
      .then((r) => r.text())
      .then((html) => { sidebar.innerHTML = html; });

  /**
   * Mints a conversation and follows it. The fresh one has its own URL, so only
   * this tab moves; the others stay where they are.
   */
  const start = () => {
    const body = new FormData();
    // What the new conversation inherits its connection from.
    body.set('viewing', conversation);
    fetch(`${base}/conversations`, { method: 'POST', body })
      .then((r) => (r.ok ? r.text() : Promise.reject(r.status)))
      .then((id) => { location.href = `${base}/c/${encodeURIComponent(id)}`; })
      .catch(() => {});
  };

  // `inert` is why the drawer is not the zero-JS checkbox trick: an overlay that
  // is not a modal leaves the chat behind it tabbable and readable to a screen
  // reader.
  const setDrawer = (open) => {
    document.body.classList.toggle('drawer-open', open);
    chat.inert = open;
    openBtn.setAttribute('aria-expanded', String(open));
  };

  newBtn.addEventListener('click', start);
  openBtn.addEventListener('click', () => setDrawer(true));
  closeBtn.addEventListener('click', () => setDrawer(false));
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') setDrawer(false);
    // Claude's own new-chat chord: Ctrl on Linux, ⌘ on an iPad's keyboard.
    // Matched on `key`, not `code`, so it follows the letter on any layout;
    // a held chord's repeats would each mint a conversation.
    if ((e.ctrlKey || e.metaKey) && e.shiftKey && !e.altKey && !e.repeat
        && e.key.toLowerCase() === 'o') {
      e.preventDefault();
      start();
    }
  });
  // Leaving the phone layout with the drawer open would strand `inert` on a chat
  // column nothing covers any more. Keep the query in sync with style.css's own
  // breakpoint.
  matchMedia('(max-width: 40rem)').addEventListener('change', () => setDrawer(false));

  // Delegated to the nav so it survives the list being re-rendered from the
  // server; `redirect: 'manual'` declines the 303 the route owes a no-JS
  // browser.
  sidebar.addEventListener('submit', (e) => {
    e.preventDefault();
    const row = e.target.closest('li');
    const title = row.querySelector('.conversation-title').textContent;
    if (!confirm(`Delete "${title}"? This cannot be undone.`)) return;
    fetch(e.target.action, { method: 'POST', redirect: 'manual' }).then(() => {
      // Deleting what this tab reads leaves it on a page that no longer exists;
      // The root picks the newest conversation left, or mints one.
      if (row.querySelector('.conversation').classList.contains('current')) location.href = `${base}/`;
      else refresh();
    });
  });

  return { refresh, start };
};
