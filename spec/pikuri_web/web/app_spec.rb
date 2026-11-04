# frozen_string_literal: true

# Drives the Sinatra app in-process with rack-test against a fake registry
# (no agents, no threads); the broadcaster is real except where the SSE route
# needs a pre-loaded queue to avoid blocking the synchronous rack-test body
# read.
RSpec.describe PikuriWeb::Web::App do
  include Rack::Test::Methods

  # Builds the store's row type without touching a disk.
  module ConversationRows
    def self.row(id, title, created_at: Time.now, supported: true)
      PikuriWeb::Conversations::Store::Conversation.new(
        id: id, dir: Pathname("/nonexistent/#{id}"), title: title,
        created_at: created_at, supported: supported
      )
    end
  end

  # Stands in for Agents::Runner: records calls, serves canned status, and owns a
  # real Transcript so the page has blocks to render.
  class FakeRunner
    attr_reader :conversation, :transcript, :submitted, :uploads, :cancels, :selected
    attr_accessor :busy, :submit_outcome, :select_outcome

    def initialize(conversation, lock:)
      @conversation = conversation
      @transcript = PikuriWeb::Web::Transcript.new(lock: lock)
      @submitted = []
      @uploads = []
      @selected = []
      @cancels = 0
      @busy = false
      @submit_outcome = :started
      @select_outcome = :selected
    end

    def submit(message, uploads: [])
      @submitted << message
      @uploads << uploads
      @submit_outcome
    end

    def select_model(name)
      @selected << name
      @select_outcome
    end

    def cancel = @cancels += 1
    def busy? = @busy

    def status_data
      { state: @busy ? :running : :idle, busy: @busy, pending: 0,
        tokens: 'ctx 12.3k/32k (38%)', tokens_detail: 'msg #2  Δ+1.6k  ↑1.0k  ↓0.6k',
        model: 'local', model_pending: nil, model_missing: nil }
    end

    # Unrendered, the way the real runner hands it over: the route runs it
    # through TrifectaView, so this stands in for Pikuri::Agent::Trifecta and
    # only #render is ever reached.
    def trifecta = Data.define(:render).new(render: 'Trifecta: 2 of 3 legs')
  end

  # Stands in for Conversations::Registry: a canned set of conversations, each
  # opening to a FakeRunner that outlives the request.
  class FakeRegistry
    attr_accessor :list, :delete_outcome
    attr_reader :deleted, :created, :created_from

    def initialize(list = [], lock:)
      @list = list
      @lock = lock
      @runners = {}
      @deleted = []
      @created = 0
      @created_from = []
      @delete_outcome = :deleted
    end

    def runner_for(conversation) = @runners[conversation.id] ||= FakeRunner.new(conversation, lock: @lock)
    def resident(id) = @runners[id]
    def find(id) = @list.find { |c| c.id == id }

    def open_id(id)
      conversation = find(id)
      conversation && runner_for(conversation)
    end

    def create(from: nil)
      @created += 1
      @created_from << from
      conversation = ConversationRows.row("minted-#{@created}", "minted #{@created}")
      @list.unshift(conversation)
      runner_for(conversation)
    end

    def delete(conversation)
      @deleted << conversation
      @delete_outcome
    end

    def default = @list.first || create.conversation

    def rows
      @list.map { |c| { conversation: c, busy: @runners[c.id]&.busy? || false } }
    end
  end

  # Stands in for Broadcaster on the SSE route: subscribe returns a queue
  # pre-loaded with frames and the nil shutdown sentinel, so the route's
  # drain loop terminates under rack-test's synchronous body read.
  class PreloadedBroadcaster
    attr_reader :unsubscribed, :subscribed

    def initialize(frames)
      @frames = frames
      @unsubscribed = []
      @subscribed = []
    end

    def subscribe(conversation)
      @subscribed << conversation
      queue = Thread::Queue.new
      @frames.each { |f| queue.push(f) }
      queue.push(nil)
      queue
    end

    def unsubscribe(queue) = @unsubscribed << queue
    def broadcast(**) = nil
    # The catch-up path writes frames straight onto the connection, so the
    # real formatter is what the route is entitled to here.
    def frame(event:, data:) = PikuriWeb::Web::Broadcaster.new.frame(event: event, data: data)
  end

  let(:live) { ConversationRows.row('2026-08-27T12-03-51Z-3f9a', 'the open one') }
  let(:stored) { ConversationRows.row('2026-08-26T09-14-02Z-b1c7', "yesterday's", created_at: Time.now - 86_400) }
  let(:broadcaster) { PikuriWeb::Web::Broadcaster.new }
  # Two connections, so /model is in the palette — the one-connection page is
  # its own example below.
  let(:models) do
    [{ name: 'local', model: 'qwen3.6', context_window: 32_768 },
     { name: 'remote', model: 'qwen3.6', context_window: nil }]
  end
  let(:lock) { PikuriWeb::BigAppLock.new }
  let(:registry) { FakeRegistry.new([live], lock: lock) }
  # What `[ui] show_thinking` resolved to at boot; the config default.
  let(:show_thinking) { true }
  # Ditto `[ui] tool_lines`, which unlike show_thinking is not validated
  # against this shell's vocabulary — so a nonsense value has to reach here.
  let(:tool_lines) { :short }
  # Only the image examples reach it; they bring a real one on a temp root.
  let(:store) { nil }

  # The runner GET /c/:id would open for the default conversation.
  let(:runner) { registry.runner_for(live) }

  def app = described_class

  before do
    # rack-test requests arrive as host "example.org"; Sinatra's
    # development-mode host authorization would 403 them.
    described_class.set :environment, :test
    described_class.set :big_app_lock, lock
    described_class.set :broadcaster, broadcaster
    described_class.set :registry, registry
    described_class.set :store, store
    described_class.set :models, models
    # Class-level and therefore sticky across examples: set every time, or an
    # example that overrides it leaks into the next.
    described_class.set :show_thinking, show_thinking
    described_class.set :tool_lines, tool_lines
  end

  def visit_live = get("/c/#{live.id}")

  context 'GET /' do
    it 'redirects to the newest conversation, so every tab lands on a real URL' do
      get '/'
      assert_equal 303, last_response.status
      assert_equal "http://example.org/c/#{live.id}", last_response.headers['Location']
    end

    it 'mints one when there is nothing to land on' do
      registry.list = []
      get '/'
      assert_equal 303, last_response.status
      assert_equal 1, registry.created
    end
  end

  context 'GET /c/:id' do
    it 'renders transcript blocks with kind classes and ids' do
      lock.run do
        runner.transcript.add(kind: :user, html: 'hello there')
        runner.transcript.add(kind: :assistant, html: '<p>general kenobi</p>')
      end
      visit_live
      assert last_response.ok?
      assert_includes last_response.body, '<div class="block user" id="b1">hello there</div>'
      assert_includes last_response.body, '<div class="block assistant" id="b2"><p>general kenobi</p></div>'
    end

    it 'renders the status bar from this conversation runner' do
      visit_live
      assert_includes last_response.body, 'idle'
      # Both halves of the context readout, each in the span that paints it.
      assert_includes last_response.body, '<span id="status-tokens-ctx">ctx 12.3k/32k (38%)</span>'
      assert_includes last_response.body, '<span id="status-tokens-detail">msg #2  Δ+1.6k  ↑1.0k  ↓0.6k</span>'
    end

    # One place, on the root element: app.js reads it once and names the
    # conversation on every fetch and on the EventSource itself, so no form in
    # the page carries a second copy of it.
    it 'names the conversation for app.js to subscribe to' do
      visit_live
      assert_includes last_response.body, %(data-conversation="#{live.id}")
    end

    it 'refuses an id that is not a listed conversation' do
      get '/c/..%2F..%2Fetc'
      assert_equal 404, last_response.status
    end

    it 'serves a conversation while a turn is in flight in it' do
      runner.busy = true
      visit_live
      assert last_response.ok?
      assert_includes last_response.body, 'running'
    end

    it 'defaults to the dark theme with no cookie' do
      visit_live
      assert_includes last_response.body, 'data-theme="dark"'
      assert_includes last_response.body, '☀ light'
    end

    it 'honours a light theme cookie' do
      set_cookie 'theme=light'
      visit_live
      assert_includes last_response.body, 'data-theme="light"'
      assert_includes last_response.body, '☾ dark'
    end

    # theme-color paints the chrome around the page — on iOS, the status bar of
    # the installed app. The manifest carries one value for the whole app and it
    # can only be the dark default, so the resolved theme has to override it
    # here, or a light-theme user gets a dark bar over a paper-white page.
    it 'renders theme-color from the resolved theme, not the manifest default' do
      visit_live
      assert_includes last_response.body, '<meta name="theme-color" content="#1e1f22">'
      set_cookie 'theme=light'
      visit_live
      assert_includes last_response.body, '<meta name="theme-color" content="#fbfbfa">'
    end

    it 'links the icons and the manifest the install path needs' do
      visit_live
      assert_includes last_response.body, '<link rel="icon" href="/images/favicon.svg" type="image/svg+xml">'
      assert_includes last_response.body, '<link rel="apple-touch-icon" href="/images/apple-touch-icon.png">'
      assert_includes last_response.body, '<link rel="manifest" href="/manifest.webmanifest">'
    end

    it 'renders the whole slash-command catalog for app.js to filter in place' do
      visit_live
      PikuriWeb::Web::SlashCommand.catalog(connections: models.size).each do |command|
        assert_includes last_response.body, %(data-command="#{command.name}")
        assert_includes last_response.body, command.description
      end
    end

    it 'lists every connection in the model dialog, with its model id and window' do
      visit_live
      assert_includes last_response.body, '<template id="tpl-model">'
      assert_includes last_response.body, 'data-model="remote"'
      assert_includes last_response.body, '<span class="picker-detail">qwen3.6 · 32k</span>'
      # A connection that leaves its window to pikuri's probe has none to print.
      assert_includes last_response.body, '<span class="picker-detail">qwen3.6</span>'
    end

    it 'renders the status bar with the model, so the dialog can read it back' do
      visit_live
      assert_includes last_response.body, '<span id="status-model" data-missing="">local</span>'
      assert_includes last_response.body, '<span id="status-model-pending"></span>'
    end

    context 'with one connection' do
      let(:models) { [{ name: 'local', model: 'qwen3.6', context_window: nil }] }

      it 'leaves /model out of the palette — there is nothing to pick between' do
        visit_live
        refute_includes last_response.body, 'data-command="/model"'
        assert_includes last_response.body, 'data-command="/theme"'
      end

      it 'still names the connection on the status bar' do
        visit_live
        assert_includes last_response.body, '>local</span>'
      end
    end

    it 'ships the trifecta report in the page, so /trifecta costs no route' do
      visit_live
      assert_includes last_response.body, '<template id="tpl-trifecta">'
      assert_includes last_response.body, 'Trifecta: 2 of 3 legs'
    end

    it 'names the known commands in the unknown-command dialog' do
      visit_live
      assert_includes last_response.body,
                      'Known commands: /new, /model, /theme, /thinking, /toollines, /trifecta.'
    end

    it 'falls back to the default theme for an unknown cookie value' do
      set_cookie 'theme=neon'
      visit_live
      assert_includes last_response.body, 'data-theme="dark"'
    end

    # D_details_per_block: streamed blocks arrive as `<details open>` and
    # transcript.js resolves them against this attribute; the blocks in the
    # page itself are served already resolved, because the script runs after
    # the first paint.
    context 'the reasoning-disclosure default' do
      it 'renders the configured default with no cookie' do
        visit_live
        assert_includes last_response.body, 'data-thinking="expanded"'
      end

      context 'with a thinking block in the transcript' do
        let(:stored) { PikuriWeb::Web::Disclosure.wrap('<p>hmm</p>') }
        before { lock.run { runner.transcript.add(kind: :thinking, html: stored) } }

        it 'serves it open to an expanded browser, as stored' do
          visit_live
          assert_includes last_response.body, %(<div class="block thinking" id="b1">#{stored}</div>)
        end

        let(:closed) do
          '<div class="block thinking" id="b1"><details><summary>thinking</summary><p>hmm</p></details></div>'
        end

        it 'serves it closed to a collapsed browser, so nothing folds after the paint' do
          set_cookie 'thinking=collapsed'
          visit_live
          assert_includes last_response.body, closed
        end

        it 'folds for the configured default too, not only for a cookie' do
          described_class.set :show_thinking, false
          visit_live
          assert_includes last_response.body, closed
        end
      end

      context 'when the config file asked for collapsed' do
        let(:show_thinking) { false }

        it 'renders that instead — the file is what a browser with no preference sees' do
          visit_live
          assert_includes last_response.body, 'data-thinking="collapsed"'
        end

        it 'still lets a cookie outrank it (D_ui_cookie_over_config)' do
          set_cookie 'thinking=expanded'
          visit_live
          assert_includes last_response.body, 'data-thinking="expanded"'
        end
      end

      it 'honours a collapsed cookie over the configured default' do
        set_cookie 'thinking=collapsed'
        visit_live
        assert_includes last_response.body, 'data-thinking="collapsed"'
      end

      it 'falls back to the configured default for an unknown cookie value' do
        set_cookie 'thinking=sideways'
        visit_live
        assert_includes last_response.body, 'data-thinking="expanded"'
      end

      it 'offers both states in the picker the command opens' do
        visit_live
        assert_includes last_response.body, '<template id="tpl-thinking">'
        assert_includes last_response.body, 'data-thinking="expanded">Expanded<'
        assert_includes last_response.body, 'data-thinking="collapsed">Collapsed<'
      end
    end

    # D_both_forms_in_the_block: every tool block ships both forms and this
    # attribute is what style.css picks by, so it is the whole of the flip.
    context 'the tool-line form' do
      it 'renders the configured default with no cookie' do
        visit_live
        assert_includes last_response.body, 'data-tools="short"'
      end

      context 'when the config file asked for the raw form' do
        let(:tool_lines) { :verbose }

        it 'renders that instead' do
          visit_live
          assert_includes last_response.body, 'data-tools="verbose"'
        end

        it 'still lets a cookie outrank it (D_ui_cookie_over_config)' do
          set_cookie 'tools=short'
          visit_live
          assert_includes last_response.body, 'data-tools="short"'
        end
      end

      it 'honours a verbose cookie over the configured default' do
        set_cookie 'tools=verbose'
        visit_live
        assert_includes last_response.body, 'data-tools="verbose"'
      end

      it 'falls back to the configured default for an unknown cookie value' do
        set_cookie 'tools=terse'
        visit_live
        assert_includes last_response.body, 'data-tools="short"'
      end

      # `Config` checks this key's shape and not its vocabulary
      # on purpose, so the reader is the only thing between a typo in the
      # shared config file and an unstyled page showing both forms at once.
      context 'when the config file named a form this shell cannot render' do
        let(:tool_lines) { :terse }

        it 'falls back to short rather than rendering it' do
          visit_live
          assert_includes last_response.body, 'data-tools="short"'
        end
      end

      it 'offers both forms in the picker the command opens' do
        visit_live
        assert_includes last_response.body, '<template id="tpl-toollines">'
        assert_includes last_response.body, 'data-tools="short">Short<'
        assert_includes last_response.body, 'data-tools="verbose">Verbose<'
      end
    end

    # Nothing is gated on busy any more: a turn queues rather than being
    # refused, and a fresh conversation touches no existing one.
    it 'never disables the new-conversation button' do
      runner.busy = true
      visit_live
      assert_includes last_response.body, '+ new conversation'
      refute_match(/id="new-conversation"[^>]*disabled/, last_response.body)
    end

    it 'titles the page and the top bar with the conversation' do
      visit_live
      assert_includes last_response.body, '<title>the open one · pikuri-web</title>'
      assert_includes last_response.body, '<span id="topbar-title">the open one</span>'
    end

    # Sending mid-turn injects, so the arrow cannot become the stop button —
    # that would cost the injection (D_interloper_mid_loop_input).
    it 'keeps send and stop as two controls, revealing stop only while busy' do
      visit_live
      assert_match(/id="send"/, last_response.body)
      assert_match(/id="cancel"[^>]*hidden/, last_response.body)

      runner.busy = true
      visit_live
      assert_match(/id="send"/, last_response.body)
      refute_match(/id="cancel"[^>]*hidden/, last_response.body)
    end

    # One shell, two layouts (D_one_shell_two_layouts): the phone's chrome is
    # in every response, and only CSS decides which half is showing.
    it 'ships the drawer chrome and the top bar to every browser' do
      visit_live
      assert_includes last_response.body, 'id="drawer"'
      assert_includes last_response.body, 'id="drawer-open"'
      assert_includes last_response.body, 'id="drawer-close"'
      assert_includes last_response.body, 'id="topbar"'
    end
  end

  context 'the conversation sidebar' do
    before { registry.list = [live, stored] }

    it 'renders a row per conversation, with its age' do
      visit_live
      assert_includes last_response.body, 'the open one'
      assert_includes last_response.body, 'yesterday&#39;s'
      assert_includes last_response.body, 'just now'
    end

    it 'marks the row this tab has open' do
      get "/c/#{stored.id}"
      assert_includes last_response.body, 'class="conversation current"'
      assert_equal 1, last_response.body.scan('aria-current="page"').size
      assert_includes last_response.body, 'aria-current="false"'
    end

    it 'links each row, because opening a conversation is a side-effect-free GET' do
      visit_live
      assert_includes last_response.body, %(href="/c/#{stored.id}")
      refute_includes last_response.body, '/select'
    end

    it 'keeps delete a POST, in its own form beside the link' do
      visit_live
      assert_includes last_response.body, %(<form method="post" action="/conversations/#{stored.id}/delete">)
      assert_equal 2, last_response.body.scan('class="conversation-delete"').size
    end

    # The affordance the whole feature needs: a turn running in a row you are
    # not looking at has to be visible, or you would never know.
    it 'marks a busy row busy, and refuses delete on that row alone' do
      registry.runner_for(stored).busy = true
      visit_live

      # Twice on that row: the dot, and the delete button explaining its refusal.
      assert_includes last_response.body, 'class="conversation-busy"'
      assert_equal 2, last_response.body.scan('title="a turn is running here"').size
      # Only that row delete is disabled; the row this tab has open is not.
      assert_equal 1, last_response.body.scan('disabled').size
    end

    it 'labels a conversation it cannot read instead of dating it' do
      registry.list = [ConversationRows.row('2026-08-25T08-00-00Z-aaaa', '2026-08-25 10:00', supported: false)]
      get '/c/2026-08-25T08-00-00Z-aaaa'
      assert_includes last_response.body, 'class="conversation current unsupported"'
      assert_includes last_response.body, 'unsupported format'
    end

    it 'serves the list on its own for app.js to swap in' do
      get "/conversations?viewing=#{stored.id}"
      assert last_response.ok?
      assert_includes last_response.body, '<ul class="conversations">'
      refute_includes last_response.body, '<html'
      assert_includes last_response.body, 'aria-current="page"'
    end
  end

  context 'GET /events' do
    before do
      described_class.set :broadcaster, PreloadedBroadcaster.new(["event: status\ndata: {}\n\n"])
    end

    it 'serves the SSE content type' do
      get '/events', conversation: live.id
      assert_equal 'text/event-stream', last_response.media_type
    end

    it 'subscribes to the conversation the tab named' do
      get '/events', conversation: live.id
      assert_equal [live.id], described_class.settings.broadcaster.subscribed
    end

    it 'streams broadcast frames until the shutdown sentinel' do
      get '/events', conversation: live.id
      assert_equal "event: status\ndata: {}\n\n", last_response.body
    end

    it 'unsubscribes its queue when the drain loop ends' do
      get '/events', conversation: live.id
      assert_equal 1, described_class.settings.broadcaster.unsubscribed.size
    end

    # The page and this connection are two requests; a block finalized between
    # them is in neither the rendered snapshot nor the queue. Opening with the
    # transcript is what closes that, and subscribing first is what makes the
    # overlap a duplicate rather than a miss.
    #
    # It is one frame because the browser paints between event dispatches and
    # this catch-up lands on a page that has already rendered these blocks.
    it 'opens with the resident transcript as one snapshot frame' do
      lock.run do
        runner.transcript.add(kind: :tool_call, html: '<pre>calculator</pre>')
        runner.transcript.add(kind: :assistant, html: '<p>42</p>')
      end

      get '/events', conversation: live.id

      assert_equal %w[snapshot status], last_response.body.scan(/event: (\w+)/).flatten
      payload = JSON.parse(last_response.body[/^data: (.*)$/, 1])
      assert_equal [{ 'id' => 'b1', 'kind' => 'tool_call', 'html' => '<pre>calculator</pre>' },
                    { 'id' => 'b2', 'kind' => 'assistant', 'html' => '<p>42</p>' }],
                   payload['blocks']
    end

    # Resident with nothing in it still needs the frame: it is what drops
    # whatever this tab's page render caught before a wipe.
    it 'opens with an empty snapshot for a resident conversation with no blocks' do
      runner # the let is lazy: touching it is what makes the conversation resident

      get '/events', conversation: live.id

      assert_equal %w[snapshot status], last_response.body.scan(/event: (\w+)/).flatten
      assert_includes last_response.body, 'data: {"blocks":[]}'
    end

    it 'opens with nothing for a conversation nobody has resident' do
      get '/events', conversation: 'never-opened'
      assert_equal ['status'], last_response.body.scan(/event: (\w+)/).flatten
    end

    # Puma corks a response's socket until the body ends, which an event stream
    # never does — so every frame sat in the kernel for its 200 ms cork ceiling.
    # A real socket, because the cork is the kernel's and nothing else holds it.
    it "uncorks Puma's socket so each frame leaves as it is written" do
      skip 'TCP_CORK is Linux-only' unless defined?(Socket::TCP_CORK)

      server = TCPServer.new('127.0.0.1', 0)
      socket = TCPSocket.new('127.0.0.1', server.addr[1])
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_CORK, 1)

      get '/events', { conversation: live.id }, 'puma.socket' => socket

      assert_equal 0, socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_CORK).int
    ensure
      socket&.close
      server&.close
    end
  end

  context 'POST /messages' do
    it 'hands the prompt to that conversation runner and returns 204' do
      post '/messages', prompt: 'hello', conversation: live.id
      assert_equal 204, last_response.status
      assert_equal ['hello'], runner.submitted
    end

    # The point of the shared executor: a turn elsewhere queues this one
    # rather than rejecting it.
    it 'accepts a message for a conversation while another one is working' do
      registry.list = [live, stored]
      registry.runner_for(live).busy = true

      post '/messages', prompt: 'meanwhile', conversation: stored.id

      assert_equal 204, last_response.status
      assert_equal ['meanwhile'], registry.runner_for(stored).submitted
    end

    it 'accepts a message for a conversation already working, to inject' do
      runner.busy = true
      post '/messages', prompt: 'also this', conversation: live.id
      assert_equal 204, last_response.status
      assert_equal ['also this'], runner.submitted
    end

    it 'rejects a blank prompt with 422' do
      post '/messages', prompt: "   \n", conversation: live.id
      assert_equal 422, last_response.status
      assert_empty runner.submitted
    end

    it 'rejects a missing prompt with 422' do
      post '/messages', conversation: live.id
      assert_equal 422, last_response.status
    end

    it 'refuses an id that is not a listed conversation' do
      post '/messages', prompt: 'hi', conversation: '../../etc'
      assert_equal 404, last_response.status
    end

    # The delete-vs-send race: resolving the runner and submitting to it are
    # separate steps, so the conversation can go in between. The runner says so
    # rather than starting a turn that would write the folder back.
    it 'refuses with 404 when the conversation was deleted after it was resolved' do
      runner.submit_outcome = :discarded

      post '/messages', prompt: 'hi', conversation: live.id

      assert_equal 404, last_response.status
    end
  end

  # A real store on a temp root, and a conversation living in it, so the
  # stash and the serving route touch an actual folder.
  context 'images' do
    around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) and example.run } }

    let(:store) { PikuriWeb::Conversations::Store.new(root: @root, shell: 'pikuri-web-chat') }
    let(:pictured) { store.create }
    let(:registry) { FakeRegistry.new([pictured], lock: lock) }
    let(:runner) { registry.runner_for(pictured) }
    let(:png) { "\x89PNG\r\n\x1A\n#{'pixels' * 10}".b }

    def image(bytes = png, name = 'shot.png')
      Rack::Test::UploadedFile.new(StringIO.new(bytes), 'image/png', original_filename: name)
    end

    def stored_name = PikuriWeb::Conversations::Upload.from(filename: 'shot.png', bytes: png).stored_name

    context 'POST /messages' do
      it 'writes the images into the conversation before handing them over' do
        post '/messages', prompt: 'what is this?', conversation: pictured.id, attachments: [image]

        assert_equal 204, last_response.status
        assert_equal ['what is this?'], runner.submitted
        assert_equal([['shot.png']], runner.uploads.map { |u| u.map(&:filename) })
        assert_equal png, (pictured.dir / 'attachments' / stored_name).binread
      end

      it 'takes images with no text' do
        post '/messages', prompt: '', conversation: pictured.id, attachments: [image]

        assert_equal 204, last_response.status
        assert_equal [''], runner.submitted
      end

      it 'refuses an eleventh image, and writes none of them' do
        post '/messages', prompt: 'hi', conversation: pictured.id, attachments: Array.new(11) { image }

        assert_equal 422, last_response.status
        assert_empty runner.submitted
        refute pictured.dir.exist?
      end

      it 'refuses an image over the cap with 413' do
        big = png + ('x' * PikuriWeb::Web::App::MAX_IMAGE_BYTES)
        post '/messages', prompt: 'hi', conversation: pictured.id, attachments: [image(big)]

        assert_equal 413, last_response.status
        assert_empty runner.submitted
      end

      # The type is the bytes', whatever the part's name and Content-Type claim.
      it 'refuses a file that is not one of the four image types with 415' do
        post '/messages', prompt: 'hi', conversation: pictured.id, attachments: [image('<html>', 'shot.png')]

        assert_equal 415, last_response.status
        assert_empty runner.submitted
      end

      it 'refuses an attachment that is not a file' do
        post '/messages', prompt: 'hi', conversation: pictured.id, attachments: ['just text']

        assert_equal 422, last_response.status
      end

      # A delete landing between the stash and the submit: the stash put the
      # folder back, and the route takes it away again.
      it 'removes what it wrote when the conversation was deleted in between' do
        runner.submit_outcome = :discarded

        post '/messages', prompt: 'hi', conversation: pictured.id, attachments: [image]

        assert_equal 404, last_response.status
        refute pictured.dir.exist?
      end
    end

    context 'GET /c/:id/attachments/:name' do
      before { store.stash(pictured, [PikuriWeb::Conversations::Upload.from(filename: 'shot.png', bytes: png)]) }

      it 'serves the image, typed, unsniffable and cacheable for good' do
        get "/c/#{pictured.id}/attachments/#{stored_name}"

        assert_equal 200, last_response.status
        assert_equal png, last_response.body.b
        assert_equal 'image/png', last_response.content_type
        assert_equal 'nosniff', last_response.headers['X-Content-Type-Options']
        assert_includes last_response.headers['Cache-Control'], 'immutable'
      end

      it 'answers 404 for a name not in the folder' do
        get "/c/#{pictured.id}/attachments/0000000000-other.png"
        assert_equal 404, last_response.status
      end

      it 'answers 404 for a conversation that does not exist' do
        get "/c/nope/attachments/#{stored_name}"
        assert_equal 404, last_response.status
      end

      it 'never walks out of the folder' do
        get "/c/#{pictured.id}/attachments/..%2F..%2Fmeta.json"
        assert_equal 404, last_response.status
      end

      # Something other than our stash may write there; it is never served as
      # a page on this origin.
      it 'serves nothing but the four image types' do
        (pictured.dir / 'attachments' / 'page.html').write('<script>alert(1)</script>')

        get "/c/#{pictured.id}/attachments/page.html"

        assert_equal 404, last_response.status
      end
    end
  end

  context 'POST /cancel' do
    it 'cancels the named conversation and returns 204' do
      post '/cancel', conversation: live.id
      assert_equal 204, last_response.status
      assert_equal 1, runner.cancels
    end

    it 'refuses an id that is not a listed conversation' do
      post '/cancel', conversation: 'nope'
      assert_equal 404, last_response.status
    end
  end

  context 'POST /model' do
    it 'hands the connection name to the named conversation and returns 204' do
      post '/model', conversation: live.id, name: 'remote'
      assert_equal 204, last_response.status
      assert_equal ['remote'], runner.selected
    end

    # Applied at the top of the next turn, so a running one is no reason to
    # refuse — the same story mid-turn sending tells.
    it 'is accepted while a turn is running' do
      runner.busy = true
      post '/model', conversation: live.id, name: 'remote'
      assert_equal 204, last_response.status
    end

    it 'refuses a connection this config does not have' do
      runner.select_outcome = :unknown
      post '/model', conversation: live.id, name: 'gone'
      assert_equal 422, last_response.status
    end

    it 'refuses a conversation deleted under the tab' do
      runner.select_outcome = :discarded
      post '/model', conversation: live.id, name: 'remote'
      assert_equal 404, last_response.status
    end

    it 'refuses an id that is not a listed conversation' do
      post '/model', conversation: 'nope', name: 'remote'
      assert_equal 404, last_response.status
    end
  end

  context 'POST /conversations' do
    it 'mints one and answers with its id to navigate to' do
      post '/conversations'
      assert_equal 200, last_response.status
      assert_equal 1, registry.created
      assert_equal 'minted-1', last_response.body
    end

    # The server cannot know which conversation the asking tab has open, and
    # the new one starts on that one's connection.
    it 'passes the viewed conversation on, so the new one inherits its model' do
      post '/conversations', viewing: live.id
      assert_equal [live.id], registry.created_from
    end

    it 'is never refused, whatever else is working' do
      runner.busy = true
      post '/conversations'
      assert_equal 200, last_response.status
    end
  end

  context 'POST /conversations/:id/delete' do
    before { registry.list = [live, stored] }

    it 'hands the conversation to the registry and redirects a no-JS browser home' do
      post "/conversations/#{stored.id}/delete"
      assert_equal 303, last_response.status
      assert_equal 'http://example.org/', last_response.headers['Location']
      assert_equal [stored], registry.deleted
    end

    it 'refuses an id that is not a listed conversation' do
      post '/conversations/..%2F..%2Fetc/delete'
      assert_equal 404, last_response.status
      assert_empty registry.deleted
    end

    it 'returns 409 when that conversation has a turn in flight' do
      registry.delete_outcome = :busy
      post "/conversations/#{stored.id}/delete"
      assert_equal 409, last_response.status
    end

    it 'returns 500 when the folder could not be removed' do
      registry.delete_outcome = :failed
      post "/conversations/#{stored.id}/delete"
      assert_equal 500, last_response.status
    end
  end
end
