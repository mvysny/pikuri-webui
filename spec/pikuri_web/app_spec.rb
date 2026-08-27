# frozen_string_literal: true

# Drives the Sinatra app in-process with rack-test. The runner is a fake
# (no agent, no threads); transcript / broadcaster are real except where
# the SSE route needs a pre-loaded queue to avoid blocking the
# synchronous rack-test body read.
RSpec.describe PikuriWeb::App do
  include Rack::Test::Methods

  # Stands in for AgentRunner: records calls, serves canned status.
  class FakeRunner
    attr_reader :submitted, :cancels, :new_conversations
    attr_accessor :busy, :new_conversation_outcome

    def initialize
      @submitted = []
      @cancels = 0
      @new_conversations = 0
      @busy = false
      @new_conversation_outcome = :started
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

  def app = described_class

  before do
    # rack-test requests arrive as host "example.org"; Sinatra's
    # development-mode host authorization would 403 them.
    described_class.set :environment, :test
    described_class.set :transcript, transcript
    described_class.set :broadcaster, broadcaster
    described_class.set :runner, runner
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
      assert_includes last_response.body, '<html lang="en" data-theme="dark">'
      assert_includes last_response.body, '☀ light'
    end

    it 'honours a light theme cookie' do
      set_cookie 'theme=light'
      get '/'
      assert_includes last_response.body, '<html lang="en" data-theme="light">'
      assert_includes last_response.body, '☾ dark'
    end

    it 'falls back to the default theme for an unknown cookie value' do
      set_cookie 'theme=neon'
      get '/'
      assert_includes last_response.body, '<html lang="en" data-theme="dark">'
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

  context 'POST /conversations' do
    it 'forwards to the runner and returns 204' do
      post '/conversations'
      assert_equal 204, last_response.status
      assert_equal 1, runner.new_conversations
    end

    it 'returns 204 for an already-empty conversation' do
      runner.new_conversation_outcome = :empty
      post '/conversations'
      assert_equal 204, last_response.status
    end

    it 'returns 409 when a turn is in flight' do
      runner.new_conversation_outcome = :busy
      post '/conversations'
      assert_equal 409, last_response.status
    end
  end
end
