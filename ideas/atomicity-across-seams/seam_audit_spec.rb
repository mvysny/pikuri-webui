# frozen_string_literal: true

require 'pikuri/testing'
require 'rack/test'
require 'tmpdir'

# SCRATCH — seam audit probes. Not a suite member; delete or promote.
RSpec.describe 'seam audit' do
  include Rack::Test::Methods

  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  # A broadcaster with a seam to wedge open: a hook between composing a frame
  # and pushing it, which is exactly the window nothing protects today.
  class ProbeBroadcaster < PikuriWeb::Broadcaster
    attr_accessor :before_push
    # rack-test buffers the whole body, so the route's drain loop has to end.
    # The sentinel lands behind whatever catch-up the route writes first.
    attr_accessor :sentinel_on_subscribe

    def broadcast(event:, data:, conversation: nil)
      @before_push&.call(data)
      super
    end

    def subscribe(conversation)
      super.tap { |queue| queue.push(nil) if @sentinel_on_subscribe }
    end
  end

  let(:broadcaster) { ProbeBroadcaster.new }

  # Swap the executor the factory closes over, for the runners minted inside.
  def with_executor(other)
    previous = @executor_override
    @executor_override = other
    yield
  ensure
    @executor_override = previous
  end

  def wait_for(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk 'timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end
  let(:store) { PikuriWeb::ConversationStore.new(root: @root, shell: 'pikuri-web-chat') }
  let(:catalog) do
    PikuriWeb::ModelCatalog.new(
      choices: [PikuriWeb::ModelCatalog::Choice.new(name: 'fake', transport: Pikuri::Testing.fake_transport)]
    )
  end
  let(:agents) { [] }
  let(:factory) do
    lambda do |conversation|
      interloper = Pikuri::Agent::Control::Interloper.new
      cancellable = Pikuri::Agent::Control::Cancellable.new
      transcript = PikuriWeb::Transcript.new
      listener = PikuriWeb::SseListener.new(
        transcript: transcript, broadcaster: broadcaster, conversation: conversation.id
      )
      agent = Pikuri::Agent.new(
        transport: Pikuri::Testing.fake_transport { |llm| llm.reply('hi') },
        system_prompt: 'test agent', cancellable: cancellable, interloper: interloper
      ) { |c| c.add_listener listener }
      agents << agent
      listeners[conversation.id] = listener
      PikuriWeb::AgentRunner.new(
        conversation: conversation, agent: agent, interloper: interloper,
        cancellable: cancellable, broadcaster: broadcaster, conversations: store,
        transcript: transcript, listener: listener, catalog: catalog,
        executor: @executor_override || executor
      )
    end
  end
  let(:listeners) { {} }
  let(:executor) { Concurrent::ImmediateExecutor.new }
  let(:registry) { PikuriWeb::ConversationRegistry.new(store: store, factory: factory) }

  let(:app) do
    # rack-test arrives as host "example.org"; without this Sinatra's host
    # authorization 403s every request — and a probe asserting absence passes
    # vacuously against a rejection.
    PikuriWeb::App.set :environment, :test
    PikuriWeb::App.set :registry, registry
    PikuriWeb::App.set :broadcaster, broadcaster
    PikuriWeb::App.set :models, []
    PikuriWeb::App
  end

  after { agents.each(&:close) }

  def history_of(text)
    Pikuri::Agent::History.new(
      messages: [
        Pikuri::Agent::History::Message.new(
          id: Pikuri::Agent::History.mint_id, role: 'user', content: text
        )
      ]
    )
  end


  # PROBE 1 — snapshot-then-subscribe.
  #
  # GET /c/:id renders the transcript at T1. The browser opens GET /events as a
  # SEPARATE request at T2. A block the agent finalizes in between is in
  # neither: too late for the snapshot, too early for the subscription.
  it 'PROBE 1: recovers a block finalized between the page render and the subscription' do
    conversation = store.create
    runner = registry.open(conversation)
    listener = listeners.fetch(conversation.id)

    get "/c/#{conversation.id}"
    page = last_response.body

    # The window: the agent is mid-turn and finalizes a tool line.
    listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'calculator', arguments: { expression: '2 + 2' }))

    refute_includes page, 'calculator', 'the page snapshot predates the block'
    assert(runner.transcript.to_a.any? { |b| b.html.include?('calculator') }, 'the server has it')

    broadcaster.sentinel_on_subscribe = true
    get "/events?conversation=#{conversation.id}" # the EventSource finally connects
    assert_includes last_response.body, 'calculator', 'and the connection opens with it'
  end

  # PROBE 2 — is a streaming block self-healing? Deltas re-send the whole
  # accumulated source under one id, so a tab that misses deltas 1..n should
  # still be correct once it receives n+1.
  it 'PROBE 2: a streaming block recovers, a finalized one does not' do
    conversation = store.create
    registry.open(conversation)
    listener = listeners.fetch(conversation.id)

    listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'Hel'))
    queue = broadcaster.subscribe(conversation.id)
    listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'lo'))

    frames = drain_frames(queue)
    assert_equal 1, frames.size
    assert_includes frames.first, 'Hello', 'a late subscriber still gets the whole accumulated source'
  end

  # PROBE 4 — the server half of a reconnect: everything sent during the
  # outage is gone, and no frame carries an SSE id, so there is no
  # Last-Event-ID to resume from. NOT a live bug — app.js:33 compensates by
  # reloading the page on any reconnect (`es.reconnected`). Worth recording
  # because that reload lands right back in PROBE 1's window: the compensation
  # narrows the loss, it does not close the seam.
  it 'PROBE 4: the server keeps nothing to replay across a reconnect' do
    conversation = store.create
    registry.open(conversation)
    listener = listeners.fetch(conversation.id)

    first = broadcaster.subscribe(conversation.id)
    listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'calculator', arguments: { expression: '1 + 1' }))
    assert_equal 1, drain_frames(first).size
    broadcaster.unsubscribe(first) # the connection drops

    listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: '2'))

    reconnected = broadcaster.subscribe(conversation.id) # EventSource retries by itself
    assert_empty drain_frames(reconnected), 'the result is gone for good'

    # And nothing could replay it: no frame carries an SSE id, so the browser
    # has no Last-Event-ID to send and the server has nowhere to resume from.
    listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'done'))
    refute_includes drain_frames(reconnected).first, "\nid:"
  end

  # PROBE 5 — the user's own message is invisible while the turn waits for a
  # slot. POST /messages answers 204 as soon as the turn is *claimed*; the user
  # block is rendered by the listener on the agent thread, which has not run.
  it 'PROBE 5: a queued turn shows the user nothing they sent' do
    blocker = Concurrent::SingleThreadExecutor.new
    gate = Thread::Queue.new
    blocker.post { gate.pop }

    conversation = store.create
    runner = nil
    with_executor(blocker) { runner = registry.open(conversation) }
    subscription = broadcaster.subscribe(conversation.id)

    assert_equal :started, runner.submit('where did my message go?')
    assert_equal :queued, runner.state

    assert_empty runner.transcript.to_a, 'nothing rendered'
    types = drain_frames(subscription).map { |f| f[/event: (\w+)/, 1] }
    refute_includes types, 'block', 'and no block frame either — the box is empty and so is the page'

    gate.push(:go)
    wait_for { !runner.busy? }
  end

  # PROBE 6 — the known compose-then-publish seam, forced. Two threads compose
  # a status payload and push it; nothing ties the order they composed in to
  # the order they push in, so the browser can be left holding the older state.
  it 'PROBE 6: an older status frame can land after a newer one' do
    blocker = Concurrent::SingleThreadExecutor.new
    gate = Thread::Queue.new
    blocker.post { gate.pop }

    conversation = store.create
    runner = nil
    with_executor(blocker) { runner = registry.open(conversation) }
    subscription = broadcaster.subscribe(conversation.id)

    # Hold the first status broadcast between composing its payload and pushing.
    held = Thread::Queue.new
    released = Thread::Queue.new
    broadcaster.before_push = lambda do |data|
      next unless data.key?(:state)

      broadcaster.before_push = nil
      held.push(data[:state])
      released.pop
    end

    stale = Thread.new { runner.select_model('fake') } # composes :idle, then blocks
    assert_equal :idle, held.pop

    runner.submit('hello') # composes and pushes :queued, overtaking it
    released.push(:go)
    stale.join

    states = drain_frames(subscription).filter_map { |f| f[/"state":"(\w+)"/, 1] }
    assert_equal %w[queued idle], states, 'the browser is left showing idle over a queued turn'
    assert_equal :queued, runner.state, 'while the server knows better'

    gate.push(:go)
    wait_for { !runner.busy? }
  end

  # PROBE 7 — resolve-then-open racing a delete. AgentRunner#discard! guards
  # the runner that is *already* resident when the delete lands. This opens one
  # afterwards, through a conversation another tab resolved a moment earlier.
  #
  # FIXED for the app, which now goes through ConversationRegistry#open_id and
  # re-resolves under the monitor. STILL TRUE of #open itself, as below: the
  # primitive will happily mint a runner for a conversation whose folder is
  # gone. Nothing in the app reaches it that way any more.
  it 'PROBE 7: #open (the raw primitive) still mints a runner for a deleted conversation' do
    conversation = store.create
    store.save(conversation, history_of('hello'), model: 'm', server: 's')
    assert conversation.dir.exist?

    resolved = registry.find(conversation.id) # tab A resolves it
    assert_equal :deleted, registry.delete(resolved) # tab B deletes it
    refute conversation.dir.exist?, 'the folder is gone'

    runner = registry.open(resolved) # tab A continues, one step late

    assert_equal [], registry.rows.map { |r| r[:conversation].id },
                 'a deleted conversation is back in the sidebar'
    refute runner.discarded?, 'and its runner is live, not retired'
  end

  # PROBE 8 — a tab watching a conversation someone else deletes. The sidebar
  # row goes, but this tab's transcript pane is never told anything.
  it 'PROBE 8: a subscriber to a deleted conversation is left holding it' do
    conversation = store.create
    registry.open(conversation)
    listener = listeners.fetch(conversation.id)
    listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'still here?'))

    subscription = broadcaster.subscribe(conversation.id)
    assert_equal :deleted, registry.delete(conversation)

    types = drain_frames(subscription).map { |f| f[/event: (\w+)/, 1] }
    assert_equal [], types, 'nothing addressed to the conversation that just died'
  end

  # PROBE 3 — two tabs delete the same conversation at once.
  it 'PROBE 3: concurrent deletes of one conversation' do
    conversation = store.create
    registry.open(conversation)

    results = [nil, nil]
    threads = 2.times.map do |i|
      Thread.new { results[i] = registry.delete(conversation) }
    end
    threads.each(&:join)

    assert_equal %i[deleted deleted].sort, results.sort, "got #{results.inspect}"
  end
end
