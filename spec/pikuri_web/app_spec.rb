# frozen_string_literal: true

# Drives the Sinatra app in-process with rack-test. The runner is a fake
# (no agent, no threads); transcript / broadcaster are real except where
# the SSE route needs a pre-loaded queue to avoid blocking the
# synchronous rack-test body read.
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

  # Stands in for ConversationStore: serves a canned listing, and resolves
  # through it exactly as the real one does.
  class FakeStore
    attr_accessor :list

    def initialize(list = [])
      @list = list
    end

    def find(id) = @list.find { |c| c.id == id }
  end

  # Stands in for AgentRunner: records calls, serves canned status.
  class FakeRunner
    attr_reader :submitted, :cancels, :new_conversations, :loaded, :deleted
    attr_accessor :busy, :new_conversation_outcome, :load_conversation_outcome,
                  :delete_conversation_outcome, :conversation

    def initialize
      @submitted = []
      @cancels = 0
      @new_conversations = 0
      @loaded = []
      @deleted = []
      @busy = false
      @new_conversation_outcome = :started
      @load_conversation_outcome = :loaded
      @delete_conversation_outcome = :deleted
      @conversation = ConversationRows.row('2026-08-27T12-03-51Z-3f9a', 'the live one')
    end

    def load_conversation(conversation)
      @loaded << conversation
      @load_conversation_outcome
    end

    def delete_conversation(conversation)
      @deleted << conversation
      @delete_conversation_outcome
    end

    def submit(message) = @submitted << message
    def cancel = @cancels += 1
    def status_data = { busy: @busy, pending: 0, tokens: '12.3k in / 4.5k out' }

    def new_conversation
      @new_conversations += 1
      @new_conversation_outcome
    end
  end

  # Stands in for Broadcaster on the SSE route: subscribe returns a queue
  # pre-loaded with frames and the nil shutdown sentinel, so the route's
  # drain loop terminates under rack-test's synchronous body read.
  class PreloadedBroadcaster
    attr_reader :unsubscribed

    def initialize(frames)
      @frames = frames
      @unsubscribed = []
    end

    def subscribe
      queue = Thread::Queue.new
      @frames.each { |f| queue.push(f) }
      queue.push(nil)
      queue
    end

    def unsubscribe(queue) = @unsubscribed << queue
  end

  let(:transcript) { PikuriWeb::Transcript.new }
  let(:broadcaster) { PikuriWeb::Broadcaster.new }
  let(:runner) { FakeRunner.new }
  let(:conversations) { FakeStore.new }

  def app = described_class

  before do
    # rack-test requests arrive as host "example.org"; Sinatra's
    # development-mode host authorization would 403 them.
    described_class.set :environment, :test
    described_class.set :transcript, transcript
    described_class.set :broadcaster, broadcaster
    described_class.set :runner, runner
    described_class.set :conversations, conversations
  end

  context 'GET /' do
    it 'renders transcript blocks with kind classes and ids' do
      transcript.add(kind: :user, html: 'hello there')
      transcript.add(kind: :assistant, html: '<p>general kenobi</p>')
      get '/'
      assert last_response.ok?
      assert_includes last_response.body, '<div class="block user" id="b1">hello there</div>'
      assert_includes last_response.body, '<div class="block assistant" id="b2"><p>general kenobi</p></div>'
    end

    it 'renders the status bar from runner status' do
      get '/'
      assert_includes last_response.body, 'idle'
      assert_includes last_response.body, '12.3k in / 4.5k out'
    end

    it 'defaults to the dark theme with no cookie' do
      get '/'
      assert_includes last_response.body, 'data-theme="dark"'
      assert_includes last_response.body, '☀ light'
    end

    it 'honours a light theme cookie' do
      set_cookie 'theme=light'
      get '/'
      assert_includes last_response.body, 'data-theme="light"'
      assert_includes last_response.body, '☾ dark'
    end

    it 'falls back to the default theme for an unknown cookie value' do
      set_cookie 'theme=neon'
      get '/'
      assert_includes last_response.body, 'data-theme="dark"'
    end

    it 'offers the new-conversation button, enabled while idle' do
      get '/'
      assert_includes last_response.body, 'id="new-conversation"'
      refute_includes last_response.body, 'disabled'
    end

    it 'renders the new-conversation button disabled while busy' do
      runner.busy = true
      get '/'
      assert_includes last_response.body, 'disabled>+ new conversation</button>'
    end
  end

  context 'the conversation sidebar' do
    let(:saved) do
      [
        ConversationRows.row('2026-08-27T12-03-51Z-3f9a', 'the live one', created_at: Time.now - 7200),
        ConversationRows.row('2026-08-26T09-14-02Z-b1c7', 'yesterday\'s', created_at: Time.now - 90)
      ]
    end

    it 'renders a row per saved conversation, with its age' do
      conversations.list = saved
      get '/'
      assert_includes last_response.body, 'the live one'
      assert_includes last_response.body, '2 hours ago'
      assert_includes last_response.body, 'yesterday&#39;s'
      assert_includes last_response.body, 'just now'
    end

    it 'marks the row this tab has open, and the live one, separately' do
      conversations.list = saved
      get '/'
      # On GET / the two coincide: the tab is looking at the live conversation.
      assert_includes last_response.body, 'class="conversation current live"'
      assert_includes last_response.body, 'aria-current="page"'
      assert_includes last_response.body, 'aria-current="false"'
    end

    it 'links each row, because opening a conversation is a side-effect-free GET' do
      conversations.list = saved
      get '/'
      assert_includes last_response.body, 'href="/c/2026-08-26T09-14-02Z-b1c7"'
      refute_includes last_response.body, '/select'
    end

    it 'keeps delete a POST, in its own form beside the link' do
      conversations.list = saved
      get '/'
      assert_includes last_response.body,
                      '<form method="post" action="/conversations/2026-08-26T09-14-02Z-b1c7/delete">'
      assert_equal 2, last_response.body.scan('class="conversation-delete"').size
    end

    it 'keeps the rows clickable mid-turn but still refuses delete' do
      conversations.list = saved
      runner.busy = true
      get '/'
      # Reading another conversation while this one works is the point, so only
      # the delete buttons are disabled.
      assert_equal 2, last_response.body.scan('title="the agent is mid-turn"').size
      refute_includes last_response.body, '<a href="/c/2026-08-26T09-14-02Z-b1c7"\n       class="conversation" disabled'
    end

    it 'marks the live row busy while a turn is in flight' do
      runner.busy = true
      get '/'
      assert_includes last_response.body, 'class="conversation-busy"'
    end

    it 'lists the live conversation before its first save, when the store has no row for it' do
      get '/'
      assert_includes last_response.body, 'the live one'
      assert_includes last_response.body, 'aria-current="page"'
    end

    it 'does not list the live conversation twice once it is saved' do
      conversations.list = saved
      get '/'
      assert_equal 1, last_response.body.scan('aria-current="page"').size
    end

    it 'labels a conversation it cannot read instead of dating it' do
      conversations.list = [ConversationRows.row('2026-08-25T08-00-00Z-aaaa', '2026-08-25 10:00',
                                                 supported: false)]
      get '/'
      assert_includes last_response.body, 'class="conversation unsupported"'
      assert_includes last_response.body, 'unsupported format'
    end

    it 'serves the list on its own for app.js to swap in' do
      conversations.list = saved
      get '/conversations'
      assert last_response.ok?
      assert_includes last_response.body, '<ul class="conversations">'
      refute_includes last_response.body, '<html'
    end
  end

  context 'GET /events' do
    before do
      described_class.set :broadcaster,
                          PreloadedBroadcaster.new(["event: block\ndata: {\"id\":\"b1\"}\n\n"])
    end

    it 'serves the SSE content type' do
      get '/events'
      assert_equal 'text/event-stream', last_response.media_type
    end

    it 'streams broadcast frames until the shutdown sentinel' do
      get '/events'
      assert_equal "event: block\ndata: {\"id\":\"b1\"}\n\n", last_response.body
    end

    it 'unsubscribes its queue when the drain loop ends' do
      get '/events'
      assert_equal 1, described_class.settings.broadcaster.unsubscribed.size
    end
  end

  context 'POST /messages' do
    it 'hands the prompt to the runner and returns 204' do
      post '/messages', 'prompt' => 'what is 2+2?'
      assert_equal 204, last_response.status
      assert_equal ['what is 2+2?'], runner.submitted
    end

    it 'rejects a blank prompt with 422' do
      post '/messages', 'prompt' => '   '
      assert_equal 422, last_response.status
      assert_empty runner.submitted
    end

    it 'rejects a missing prompt with 422' do
      post '/messages'
      assert_equal 422, last_response.status
    end
  end

  context 'POST /cancel' do
    it 'forwards to the runner and returns 204' do
      post '/cancel'
      assert_equal 204, last_response.status
      assert_equal 1, runner.cancels
    end
  end

  context 'GET /c/:id' do
    let(:stored) { ConversationRows.row('2026-08-26T09-14-02Z-b1c7', 'yesterday\'s') }

    it 'serves the live conversation from the transcript, marked live' do
      get "/c/#{runner.conversation.id}"
      assert_equal 200, last_response.status
      assert_includes last_response.body, 'data-live="true"'
      assert_includes last_response.body, %(data-conversation="#{runner.conversation.id}")
    end

    it 'refuses an id that is not a listed conversation' do
      conversations.list = [stored]
      get '/c/..%2F..%2Fetc'
      assert_equal 404, last_response.status
    end

    # The fake store points every row at a folder that does not exist, which is
    # the same shape as a half-written save: unreadable, and the tab is told so
    # rather than shown a blank conversation.
    it 'reports a conversation whose history cannot be read' do
      conversations.list = [stored]
      capture_log { get '/c/2026-08-26T09-14-02Z-b1c7' }
      assert_equal 422, last_response.status
    end

    it 'leaves viewing free while a turn is in flight' do
      runner.busy = true
      get "/c/#{runner.conversation.id}"
      assert_equal 200, last_response.status
    end
  end

  context 'POST /conversations' do
    it 'forwards to the runner and answers with the fresh id to navigate to' do
      post '/conversations'
      assert_equal 200, last_response.status
      assert_equal runner.conversation.id, last_response.body
      assert_equal 1, runner.new_conversations
    end

    it 'answers with the id for an already-empty conversation' do
      runner.new_conversation_outcome = :empty
      post '/conversations'
      assert_equal 200, last_response.status
    end

    it 'returns 409 when a turn is in flight' do
      runner.new_conversation_outcome = :busy
      post '/conversations'
      assert_equal 409, last_response.status
    end
  end

  # Selecting a conversation is no longer a route of its own: sending into one
  # the agent is not on is what makes it live, and carries the refusals the old
  # POST /conversations/:id/select carried.
  context 'POST /messages into another conversation' do
    let(:stored) { ConversationRows.row('2026-08-26T09-14-02Z-b1c7', 'yesterday\'s') }

    before { conversations.list = [stored] }

    it 'makes it live, then submits' do
      post '/messages', prompt: 'carry on', conversation: '2026-08-26T09-14-02Z-b1c7'
      assert_equal 204, last_response.status
      assert_equal [stored], runner.loaded
      assert_equal ['carry on'], runner.submitted
    end

    it 'submits without a switch when the target is already live' do
      runner.load_conversation_outcome = :current
      post '/messages', prompt: 'more', conversation: runner.conversation.id
      assert_equal 204, last_response.status
      assert_equal ['more'], runner.submitted
    end

    it 'submits to the live conversation when no target is named' do
      post '/messages', prompt: 'plain'
      assert_equal 204, last_response.status
      assert_empty runner.loaded
      assert_equal ['plain'], runner.submitted
    end

    it 'refuses an id that is not a listed conversation' do
      post '/messages', prompt: 'hi', conversation: '../../etc'
      assert_equal 404, last_response.status
      assert_empty runner.loaded
      assert_empty runner.submitted
    end

    it 'returns 409 without submitting when a turn is in flight elsewhere' do
      runner.load_conversation_outcome = :busy
      post '/messages', prompt: 'hi', conversation: '2026-08-26T09-14-02Z-b1c7'
      assert_equal 409, last_response.status
      assert_empty runner.submitted
    end

    it 'returns 422 when the stored history could not be read' do
      runner.load_conversation_outcome = :failed
      post '/messages', prompt: 'hi', conversation: '2026-08-26T09-14-02Z-b1c7'
      assert_equal 422, last_response.status
      assert_empty runner.submitted
    end
  end

  context 'POST /conversations/:id/delete' do
    let(:stored) { ConversationRows.row('2026-08-26T09-14-02Z-b1c7', 'yesterday\'s') }

    before { conversations.list = [stored] }

    it 'hands the stored conversation to the runner and redirects a no-JS browser home' do
      post '/conversations/2026-08-26T09-14-02Z-b1c7/delete'
      assert_equal 303, last_response.status
      assert_equal 'http://example.org/', last_response.headers['Location']
      assert_equal [stored], runner.deleted
    end

    it 'accepts the live conversation, which is in the sidebar before it is on disk' do
      post "/conversations/#{runner.conversation.id}/delete"
      assert_equal 303, last_response.status
      assert_equal [runner.conversation], runner.deleted
    end

    it 'refuses an id that is not a listed conversation' do
      post '/conversations/..%2F..%2Fetc/delete'
      assert_equal 404, last_response.status
      assert_empty runner.deleted
    end

    it 'returns 409 when a turn is in flight' do
      runner.delete_conversation_outcome = :busy
      post '/conversations/2026-08-26T09-14-02Z-b1c7/delete'
      assert_equal 409, last_response.status
    end

    it 'returns 500 when the folder could not be removed' do
      runner.delete_conversation_outcome = :failed
      post '/conversations/2026-08-26T09-14-02Z-b1c7/delete'
      assert_equal 500, last_response.status
    end
  end
end
