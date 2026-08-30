# frozen_string_literal: true

# Drives the Sinatra app in-process with rack-test against a fake registry
# (no agents, no threads); the broadcaster is real except where the SSE route
# needs a pre-loaded queue to avoid blocking the synchronous rack-test body
# read.
RSpec.describe PikuriWeb::App do
  include Rack::Test::Methods

  # Builds the store's row type without touching a disk.
  module ConversationRows
    def self.row(id, title, created_at: Time.now, supported: true)
      PikuriWeb::ConversationStore::Conversation.new(
        id: id, dir: Pathname("/nonexistent/#{id}"), title: title,
        created_at: created_at, supported: supported
      )
    end
  end

  # Stands in for AgentRunner: records calls, serves canned status, and owns a
  # real Transcript so the page has blocks to render.
  class FakeRunner
    attr_reader :conversation, :transcript, :submitted, :cancels, :selected
    attr_accessor :busy, :submit_outcome, :select_outcome

    def initialize(conversation)
      @conversation = conversation
      @transcript = PikuriWeb::Transcript.new
      @submitted = []
      @selected = []
      @cancels = 0
      @busy = false
      @submit_outcome = :started
      @select_outcome = :selected
    end

    def submit(message)
      @submitted << message
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
    def trifecta_html = '<p class="trifecta-advisory">Trifecta: 2 of 3 legs</p>'
  end

  # Stands in for ConversationRegistry: a canned set of conversations, each
  # opening to a FakeRunner that outlives the request.
  class FakeRegistry
    attr_accessor :list, :delete_outcome
    attr_reader :deleted, :created, :created_from

    def initialize(list = [])
      @list = list
      @runners = {}
      @deleted = []
      @created = 0
      @created_from = []
      @delete_outcome = :deleted
    end

    def open(conversation) = @runners[conversation.id] ||= FakeRunner.new(conversation)
    def resident(id) = @runners[id]
    def find(id) = @list.find { |c| c.id == id }

    def create(from: nil)
      @created += 1
      @created_from << from
      conversation = ConversationRows.row("minted-#{@created}", "minted #{@created}")
      @list.unshift(conversation)
      open(conversation)
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
  end

  let(:live) { ConversationRows.row('2026-08-27T12-03-51Z-3f9a', 'the open one') }
  let(:stored) { ConversationRows.row('2026-08-26T09-14-02Z-b1c7', "yesterday's", created_at: Time.now - 86_400) }
  let(:broadcaster) { PikuriWeb::Broadcaster.new }
  # Two connections, so /model is in the palette — the one-connection page is
  # its own example below.
  let(:models) do
    [{ name: 'local', model: 'qwen3.6', context_window: 32_768 },
     { name: 'remote', model: 'qwen3.6', context_window: nil }]
  end
  let(:registry) { FakeRegistry.new([live]) }

  # The runner GET /c/:id would open for the default conversation.
  let(:runner) { registry.open(live) }

  def app = described_class

  before do
    # rack-test requests arrive as host "example.org"; Sinatra's
    # development-mode host authorization would 403 them.
    described_class.set :environment, :test
    described_class.set :broadcaster, broadcaster
    described_class.set :registry, registry
    described_class.set :models, models
  end

  def get_live = get("/c/#{live.id}")

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
      runner.transcript.add(kind: :user, html: 'hello there')
      runner.transcript.add(kind: :assistant, html: '<p>general kenobi</p>')
      get_live
      assert last_response.ok?
      assert_includes last_response.body, '<div class="block user" id="b1">hello there</div>'
      assert_includes last_response.body, '<div class="block assistant" id="b2"><p>general kenobi</p></div>'
    end

    it 'renders the status bar from this conversation runner' do
      get_live
      assert_includes last_response.body, 'idle'
      # Both halves of the context readout, each in the span that paints it.
      assert_includes last_response.body, '<span id="status-tokens-ctx">ctx 12.3k/32k (38%)</span>'
      assert_includes last_response.body, '<span id="status-tokens-detail">msg #2  Δ+1.6k  ↑1.0k  ↓0.6k</span>'
    end

    # One place, on the root element: app.js reads it once and names the
    # conversation on every fetch and on the EventSource itself, so no form in
    # the page carries a second copy of it.
    it 'names the conversation for app.js to subscribe to' do
      get_live
      assert_includes last_response.body, %(data-conversation="#{live.id}")
    end

    it 'refuses an id that is not a listed conversation' do
      get '/c/..%2F..%2Fetc'
      assert_equal 404, last_response.status
    end

    it 'serves a conversation while a turn is in flight in it' do
      runner.busy = true
      get_live
      assert last_response.ok?
      assert_includes last_response.body, 'running'
    end

    it 'defaults to the dark theme with no cookie' do
      get_live
      assert_includes last_response.body, 'data-theme="dark"'
      assert_includes last_response.body, '☀ light'
    end

    it 'honours a light theme cookie' do
      set_cookie 'theme=light'
      get_live
      assert_includes last_response.body, 'data-theme="light"'
      assert_includes last_response.body, '☾ dark'
    end

    # theme-color paints the chrome around the page — on iOS, the status bar of
    # the installed app. The manifest carries one value for the whole app and it
    # can only be the dark default, so the resolved theme has to override it
    # here, or a light-theme user gets a dark bar over a paper-white page.
    it 'renders theme-color from the resolved theme, not the manifest default' do
      get_live
      assert_includes last_response.body, '<meta name="theme-color" content="#1e1f22">'
      set_cookie 'theme=light'
      get_live
      assert_includes last_response.body, '<meta name="theme-color" content="#fbfbfa">'
    end

    it 'links the icons and the manifest the install path needs' do
      get_live
      assert_includes last_response.body, '<link rel="icon" href="/favicon.svg" type="image/svg+xml">'
      assert_includes last_response.body, '<link rel="apple-touch-icon" href="/apple-touch-icon.png">'
      assert_includes last_response.body, '<link rel="manifest" href="/manifest.webmanifest">'
    end

    it 'renders the whole slash-command catalog for app.js to filter in place' do
      get_live
      PikuriWeb::SlashCommand.catalog(connections: models.size).each do |command|
        assert_includes last_response.body, %(data-command="#{command.name}")
        assert_includes last_response.body, command.description
      end
    end

    it 'lists every connection in the model dialog, with its model id and window' do
      get_live
      assert_includes last_response.body, '<template id="tpl-model">'
      assert_includes last_response.body, 'data-model="remote"'
      assert_includes last_response.body, '<span class="picker-detail">qwen3.6 · 32k</span>'
      # A connection that leaves its window to pikuri's probe has none to print.
      assert_includes last_response.body, '<span class="picker-detail">qwen3.6</span>'
    end

    it 'renders the status bar with the model, so the dialog can read it back' do
      get_live
      assert_includes last_response.body, '<span id="status-model" data-missing="">local</span>'
      assert_includes last_response.body, '<span id="status-model-pending"></span>'
    end

    context 'with one connection' do
      let(:models) { [{ name: 'local', model: 'qwen3.6', context_window: nil }] }

      it 'leaves /model out of the palette — there is nothing to pick between' do
        get_live
        refute_includes last_response.body, 'data-command="/model"'
        assert_includes last_response.body, 'data-command="/theme"'
      end

      it 'still names the connection on the status bar' do
        get_live
        assert_includes last_response.body, '>local</span>'
      end
    end

    it 'ships the trifecta report in the page, so /trifecta costs no route' do
      get_live
      assert_includes last_response.body, '<template id="tpl-trifecta">'
      assert_includes last_response.body, 'Trifecta: 2 of 3 legs'
    end

    it 'names the known commands in the unknown-command dialog' do
      get_live
      assert_includes last_response.body, 'Known commands: /new, /model, /theme, /trifecta.'
    end

    it 'falls back to the default theme for an unknown cookie value' do
      set_cookie 'theme=neon'
      get_live
      assert_includes last_response.body, 'data-theme="dark"'
    end

    # Nothing is gated on busy any more: a turn queues rather than being
    # refused, and a fresh conversation touches no existing one.
    it 'never disables the new-conversation button' do
      runner.busy = true
      get_live
      assert_includes last_response.body, '+ new conversation'
      refute_match(/id="new-conversation"[^>]*disabled/, last_response.body)
    end

    it 'titles the page and the top bar with the conversation' do
      get_live
      assert_includes last_response.body, '<title>the open one · pikuri-web</title>'
      assert_includes last_response.body, '<span id="topbar-title">the open one</span>'
    end

    # Sending mid-turn injects, so the arrow cannot become the stop button —
    # that would cost the injection (D_interloper_mid_loop_input).
    it 'keeps send and stop as two controls, revealing stop only while busy' do
      get_live
      assert_match(/id="send"/, last_response.body)
      assert_match(/id="cancel"[^>]*hidden/, last_response.body)

      runner.busy = true
      get_live
      assert_match(/id="send"/, last_response.body)
      refute_match(/id="cancel"[^>]*hidden/, last_response.body)
    end

    # One shell, two layouts (D_one_shell_two_layouts): the phone's chrome is
    # in every response, and only CSS decides which half is showing.
    it 'ships the drawer chrome and the top bar to every browser' do
      get_live
      assert_includes last_response.body, 'id="drawer"'
      assert_includes last_response.body, 'id="drawer-open"'
      assert_includes last_response.body, 'id="drawer-close"'
      assert_includes last_response.body, 'id="topbar"'
    end
  end

  context 'the conversation sidebar' do
    before { registry.list = [live, stored] }

    it 'renders a row per conversation, with its age' do
      get_live
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
      get_live
      assert_includes last_response.body, %(href="/c/#{stored.id}")
      refute_includes last_response.body, '/select'
    end

    it 'keeps delete a POST, in its own form beside the link' do
      get_live
      assert_includes last_response.body, %(<form method="post" action="/conversations/#{stored.id}/delete">)
      assert_equal 2, last_response.body.scan('class="conversation-delete"').size
    end

    # The affordance the whole feature needs: a turn running in a row you are
    # not looking at has to be visible, or you would never know.
    it 'marks a busy row busy, and refuses delete on that row alone' do
      registry.open(stored).busy = true
      get_live

      # Twice on that row: the dot, and the delete button explaining its refusal.
      assert_includes last_response.body, 'class="conversation-busy"'
      assert_equal 2, last_response.body.scan('title="a turn is running here"').size
      # Only that row delete is disabled; the row this tab has open is not.
      assert_equal 1, last_response.body.scan('disabled').size
    end

    it 'labels a conversation it cannot read instead of dating it' do
      registry.list = [ConversationRows.row('2026-08-25T08-00-00Z-aaaa', '2026-08-25 10:00', supported: false)]
      get "/c/2026-08-25T08-00-00Z-aaaa"
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
      registry.open(live).busy = true

      post '/messages', prompt: 'meanwhile', conversation: stored.id

      assert_equal 204, last_response.status
      assert_equal ['meanwhile'], registry.open(stored).submitted
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
