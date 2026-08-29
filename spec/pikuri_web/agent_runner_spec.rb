# frozen_string_literal: true

require 'tmpdir'

# Exercises one conversation runner: the start-vs-inject decision, the
# idle/queued/running states and the save at turn end, against a real
# Interloper / Cancellable, a real ConversationStore over a temp directory, and
# a gate-controlled fake agent so turn timing is deterministic.
RSpec.describe PikuriWeb::AgentRunner do
  # Stands in for Pikuri::Agent: records run_loop messages, blocks on a gate
  # until the spec releases it, and serves a real History (so #persist
  # exercises pikuri's own save rather than a stub).
  class FakeAgent
    attr_reader :messages, :injected, :clears, :loaded, :transport, :switches
    attr_accessor :history

    def initialize(interloper, transport)
      @interloper = interloper
      @transport = transport
      @gate = Thread::Queue.new
      @messages = []
      @injected = []
      @switches = []
      @clears = 0
      @loaded = []
      @history = Pikuri::Agent::History.new(messages: [])
    end

    # Run +block+ as the next run_loop returns, and only that one: the spec's
    # way into the window between the loop ending and the runner going idle.
    def at_turn_end(&block) = @at_turn_end = block

    # Drains the Interloper first, as the real run_loop does — a fake that
    # left the queue full would have the runner restarting forever. The
    # transport moves only on a non-nil one, and only at the top, which is what
    # makes +#transport+ mean "what this turn is actually on".
    def run_loop(user_message:, transport: nil)
      @switches << transport
      @transport = transport if transport
      @injected.concat(@interloper.drain!.map(&:content))
      @messages << user_message
      @gate.pop
      @at_turn_end&.call
      @at_turn_end = nil
    end

    def export_history = @history

    def clear_conversation
      @clears += 1
      @history = Pikuri::Agent::History.new(messages: [])
    end

    # As the real one: clears, then adopts what it was handed.
    def load_history!(history)
      clear_conversation
      @loaded << history
      @history = history
      history.messages.size
    end

    def release = @gate.push(:go)
  end

  # Stands in for SseListener: records what the replay fed it.
  class FakeListener
    attr_reader :events

    def initialize = @events = []
    def on_event(event) = @events << event
  end

  # A one-message History — enough to be non-empty, which is what the
  # save-vs-no-op decisions turn on.
  def history_of(text)
    Pikuri::Agent::History.new(
      messages: [
        Pikuri::Agent::History::Message.new(
          id: Pikuri::Agent::History.mint_id, role: 'user', content: text
        )
      ]
    )
  end

  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  let(:interloper) { Pikuri::Agent::Control::Interloper.new }
  # A real catalog: the name ⇄ transport translation is half of what the model
  # selection does, and stubbing it would test the stub.
  let(:catalog) do
    PikuriWeb::ModelCatalog.from_llms(
      [
        PikuriWeb::Config::Llm.new(name: 'local', server: 'http://localhost:8080',
                                   model: 'qwen3.6', api_key: nil, context_window: 32_768),
        PikuriWeb::Config::Llm.new(name: 'remote', server: 'http://remote:8080',
                                   model: 'qwen3.6', api_key: 'k', context_window: nil)
      ]
    )
  end
  let(:agent) { FakeAgent.new(interloper, catalog.primary.transport) }
  let(:cancellable) { Pikuri::Agent::Control::Cancellable.new }
  let(:broadcaster) { PikuriWeb::Broadcaster.new }
  let(:conversations) do
    PikuriWeb::ConversationStore.new(root: @root, shell: 'pikuri-web-chat')
  end
  let(:listener) { FakeListener.new }
  let(:transcript) { PikuriWeb::Transcript.new }
  let(:conversation) { conversations.create }
  let(:runner) do
    described_class.new(
      conversation: conversation,
      agent: agent, interloper: interloper, cancellable: cancellable,
      broadcaster: broadcaster, conversations: conversations, listener: listener,
      transcript: transcript, catalog: catalog,
      # A real thread, not ImmediateExecutor: these examples are *about* the
      # busy state, which needs the turn still running when #submit returns.
      executor: Concurrent::SingleThreadExecutor.new
    )
  end

  # Spin until +condition+ holds, failing the spec on timeout — the
  # worker thread's lifecycle is asynchronous but fast.
  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk 'timed out' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end

  after do
    agent.release while runner.busy?
    wait_until { !runner.busy? }
  end

  context '#submit when idle' do
    it 'starts a worker turn with the message' do
      assert_equal :started, runner.submit('hello')
      wait_until { agent.messages.any? }
      assert_equal ['hello'], agent.messages
      assert runner.busy?
    end

    it 'returns to idle when the turn ends' do
      runner.submit('hello')
      wait_until { runner.state == :running }
      agent.release
      wait_until { !runner.busy? }
      refute runner.busy?
    end
  end

  context '#submit when busy' do
    it 'injects through the Interloper instead of starting a turn' do
      runner.submit('first')
      # Wait for run_loop entry, not just thread liveness — busy? flips
      # true before the fake agent records the message.
      wait_until { agent.messages.any? }
      assert_equal :injected, runner.submit('second')
      assert_equal [:user], interloper.peek.map(&:kind)
      assert_equal ['second'], interloper.peek.map(&:content)
      assert_equal ['first'], agent.messages
    end
  end

  # The window between the loop's last completion and the state reset: #submit
  # still sees a running turn and injects, but no drain is left to deliver it.
  context 'an injection that lands as the turn ends' do
    it 'starts a bare turn that delivers it' do
      agent.at_turn_end { interloper.inject_user_message('late') }
      runner.submit('first')
      wait_until { agent.messages.any? }

      agent.release # the loop returns, and 'late' lands on its way out
      wait_until { agent.messages.size == 2 }

      assert_equal ['first', nil], agent.messages, 'the restart is a bare turn'
      assert_equal ['late'], agent.injected
      assert runner.busy?, 'the restart was claimed before anyone could see idle'
      assert_equal 0, runner.status_data[:pending]
    end

    it 'stays idle when the queue is empty' do
      runner.submit('hello')
      wait_until { agent.messages.any? }

      agent.release
      wait_until { !runner.busy? }

      assert_equal ['hello'], agent.messages
    end

    # A failed turn hands the queue to the next #submit rather than turning an
    # unreachable transport into a restart spin.
    it 'restarts nothing after a turn that raised' do
      interloper.inject_user_message('late')
      def agent.run_loop(user_message:, transport: nil) = raise('transport exploded')

      capture_log do
        runner.submit('first')
        wait_until { !runner.busy? }
      end

      assert_equal 1, interloper.size
      assert_equal :idle, runner.state
    end
  end

  context 'pending count' do
    it 'broadcasts the drop when the agent drains mid-loop, not just on submit' do
      runner.submit('first')
      wait_until { agent.messages.any? }
      runner.submit('second')
      queue = broadcaster.subscribe(conversation.id) # after the injection, so only the drain's frame lands

      interloper.drain! # what Agent does at the next tool-batch boundary

      frames = drain_frames(queue)
      assert_equal %w[status], frames.map { |f| f[/event: (\w+)/, 1] }
      assert_includes frames.fetch(0), '"pending":0'

      agent.release
      wait_until { !runner.busy? }
    end
  end

  context 'status broadcasting' do
    # A `conversations` frame rides along on each busy transition: the
    # sidebar's per-row dot is the only sign a conversation you are not
    # looking at is working, and it is server-rendered.
    it 'broadcasts status on submit and on turn end, and the sidebar signal on each transition' do
      queue = broadcaster.subscribe(conversation.id)
      runner.submit('hello')
      wait_until { runner.state == :running }
      agent.release
      wait_until { !runner.busy? }
      types = drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }

      assert_equal 2, types.count('status')
      assert_equal 2, types.count('conversations')
    end

    it 'sends the sidebar signal to every tab, not just this conversation' do
      elsewhere = broadcaster.subscribe('some-other-conversation')
      runner.submit('hello')
      wait_until { runner.state == :running }

      types = drain_frames(elsewhere).map { |f| f[/event: (\w+)/, 1] }
      assert_equal %w[conversations], types
    end

    it 'stays quiet when status moves without busy changing' do
      runner.submit('first')
      wait_until { runner.state == :running }
      queue = broadcaster.subscribe(conversation.id)

      runner.submit('second') # an injection: still busy before and after

      # Status still moves (the queued count changed); the sidebar did not.
      types = drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }
      assert_includes types, 'status'
      refute_includes types, 'conversations'
    end
  end

  context '#status_data' do
    it 'reports busy state and pending injections' do
      assert_equal({ state: :idle, busy: false, pending: 0, tokens: '',
                     model: 'local', model_pending: nil, model_missing: nil },
                   runner.status_data)
      runner.submit('first')
      wait_until { runner.state == :running }
      runner.submit('second')
      assert_equal({ state: :running, busy: true, pending: 1, tokens: '',
                     model: 'local', model_pending: nil, model_missing: nil },
                   runner.status_data)
    end
  end

  context '#select_model' do
    it 'parks the pick and applies it at the top of the next turn' do
      assert_equal :selected, runner.select_model('remote')
      assert_equal 'remote', runner.status_data[:model_pending]
      assert_equal 'local', runner.status_data[:model], 'advertised a switch that had not landed'

      runner.submit('hello')
      wait_until { agent.messages.any? }

      assert_equal [catalog.find('remote').transport], agent.switches
      assert_equal 'remote', runner.status_data[:model]
      assert_nil runner.status_data[:model_pending]
    end

    it 'sits until a turn happens: picking alone starts nothing' do
      runner.select_model('remote')

      assert_equal :idle, runner.state
      assert_empty agent.messages
      assert_equal catalog.primary.transport, agent.transport
    end

    it 'is drained once — the turn after next keeps the model rather than re-switching' do
      runner.select_model('remote')
      runner.submit('first')
      wait_until { agent.messages.any? }
      agent.release
      wait_until { !runner.busy? }

      runner.submit('second')
      wait_until { agent.messages.size == 2 }

      assert_equal [catalog.find('remote').transport, nil], agent.switches
    end

    # The restart a completed turn claims when the Interloper still holds
    # something is the second way into run_loop, and it drains the same slot.
    it 'reaches a restart turn, not just a submitted one' do
      agent.at_turn_end do
        runner.select_model('remote')
        interloper.inject_user_message('late')
      end
      runner.submit('first')
      wait_until { agent.messages.any? }
      agent.release
      wait_until { agent.messages.size == 2 }

      assert_equal [nil, catalog.find('remote').transport], agent.switches
    end

    it 'clears the pick rather than parking a no-op when it names the current connection' do
      runner.select_model('remote')
      assert_equal 'remote', runner.status_data[:model_pending]

      assert_equal :selected, runner.select_model('local')
      assert_nil runner.status_data[:model_pending], 'an arrow that meant "no change"'
    end

    it 'refuses a name this config does not have, without touching the pick' do
      assert_equal :unknown, runner.select_model('gone')
      assert_nil runner.status_data[:model_pending]
    end

    it 'is refused for a deleted conversation, as a submit is' do
      assert runner.discard!
      assert_equal :discarded, runner.select_model('remote')
      assert_nil runner.status_data[:model_pending]
    end

    it 'accepts a pick while a turn is running — it is the next turn that takes it' do
      runner.submit('first')
      wait_until { agent.messages.any? }

      assert_equal :selected, runner.select_model('remote')
      assert_equal catalog.primary.transport, agent.transport, 'switched under a running turn'
    end

    it 'broadcasts the pick, so every tab reading this conversation sees the arrow' do
      queue = broadcaster.subscribe(conversation.id)
      runner.select_model('remote')

      frames = drain_frames(queue)
      assert_includes frames.join, '"model_pending":"remote"'
    end
  end

  context 'a saved connection that has left the config file' do
    let(:orphaned) do
      described_class.new(
        conversation: conversation, agent: agent, interloper: interloper,
        cancellable: cancellable, broadcaster: broadcaster, conversations: conversations,
        listener: listener, transcript: transcript, catalog: catalog,
        executor: Concurrent::ImmediateExecutor.new,
        missing_connection: 'qwen2 @ http://retired:8080/v1'
      )
    end

    it 'carries the note until something makes it untrue' do
      assert_equal 'qwen2 @ http://retired:8080/v1', orphaned.status_data[:model_missing]
    end

    it 'drops it once a turn saves the fallback into the envelope' do
      agent.history = history_of('hello')
      agent.release
      orphaned.submit('hello')

      assert_equal 'qwen3.6', JSON.parse((conversation.dir / 'meta.json').read).fetch('model')
      assert_nil orphaned.status_data[:model_missing]
    end

    it 'drops it once the user picks for themselves' do
      orphaned.select_model('remote')
      assert_nil orphaned.status_data[:model_missing]
    end
  end

  context '#model' do
    it 'is the pair the next turn will use, which is what a new conversation inherits' do
      assert_equal ['qwen3.6', 'http://localhost:8080/v1'], runner.model

      runner.select_model('remote')
      assert_equal ['qwen3.6', 'http://remote:8080/v1'], runner.model, 'inherited reality, not the pick'
    end
  end

  context '#cancel' do
    it 'asks the agent to stop at a tool boundary once the turn is running' do
      runner.submit('hello')
      wait_until { runner.state == :running }
      runner.cancel
      assert cancellable.cancelled?
    end

    # A turn still waiting for the executor needs nothing from pikuri: the job
    # checks on entry and returns without starting.
    it 'drops a queued turn before it starts, without touching the cancel flag' do
      blocker = Concurrent::SingleThreadExecutor.new
      gate = Thread::Queue.new
      blocker.post { gate.pop }
      queued = described_class.new(
        conversation: conversation, agent: agent, interloper: interloper,
        cancellable: cancellable, broadcaster: broadcaster, conversations: conversations,
        listener: listener, transcript: transcript, catalog: catalog, executor: blocker
      )

      queued.submit('hello')
      assert_equal :queued, queued.state
      queued.cancel
      gate.push(:go) # let the executor reach the abandoned job

      wait_until { queued.state == :idle }
      assert_empty agent.messages
      refute cancellable.cancelled?
    end

    it 'is a no-op when idle' do
      runner.cancel
      refute cancellable.cancelled?
    end
  end

  # What keeps a deleted conversation deleted. ConversationRegistry#delete
  # drops the runner from its map, but whoever resolved that runner a moment
  # earlier still holds it — and a turn started through that stale reference
  # would recreate the folder at its next save.
  context '#discard!' do
    it 'succeeds when idle and leaves nothing that could run' do
      assert runner.discard!
      assert runner.discarded?
    end

    it 'makes submit answer :discarded without starting a turn' do
      runner.discard!

      assert_equal :discarded, runner.submit('hello')
      assert_empty agent.messages
      refute runner.busy?
    end

    it 'writes no folder for a message submitted after it' do
      agent.history = history_of('hi')
      runner.discard!
      runner.submit('hi')

      refute runner.conversation.dir.exist?
      assert_empty @root.children
    end

    it 'queues nothing on the Interloper either' do
      runner.discard!
      runner.submit('hello')
      assert_empty interloper.peek
    end

    it 'refuses while a turn is running, so the delete is refused too' do
      runner.submit('hello')
      wait_until { agent.messages.any? }

      refute runner.discard!
      refute runner.discarded?
      assert_equal :injected, runner.submit('second'), 'a refused discard left the runner crippled'
    end

    # A turn waiting for a slot has started nothing, but cancelling it is still
    # the user's call: retiring the runner under it would strand the job.
    # Queued state comes from a gate job holding the executor, as in #cancel.
    it 'refuses while a turn is queued for an executor slot' do
      blocker = Concurrent::SingleThreadExecutor.new
      gate = Thread::Queue.new
      blocker.post { gate.pop }
      queued = described_class.new(
        conversation: conversation, agent: agent, interloper: interloper,
        cancellable: cancellable, broadcaster: broadcaster, conversations: conversations,
        listener: listener, transcript: transcript, catalog: catalog, executor: blocker
      )

      queued.submit('hello')
      assert_equal :queued, queued.state
      refute queued.discard!, 'retired a runner with a turn still waiting for a slot'

      queued.cancel
      gate.push(:go)
      wait_until { queued.state == :idle }
    end

    it 'is one-way: a second call still reports retired' do
      assert runner.discard!
      assert runner.discard!
      assert runner.discarded?
    end
  end

  context 'persistence at turn end' do
    it 'writes history.json and meta.json into its own conversation' do
      agent.history = history_of('what is 2+2?')
      dir = runner.conversation.dir
      runner.submit('what is 2+2?')
      wait_until { runner.state == :running }
      agent.release
      wait_until { !runner.busy? }

      assert_equal %w[history.json meta.json], dir.children.map { |c| c.basename.to_s }.sort
      assert_equal agent.history, Pikuri::Agent::History.load(dir)
    end

    it 'writes nothing for a turn that left no messages' do
      dir = runner.conversation.dir
      runner.submit('hello')
      wait_until { runner.state == :running }
      agent.release
      wait_until { !runner.busy? }

      refute dir.exist?
      assert_empty @root.children
    end

    it 'logs a save failure instead of killing the turn job' do
      agent.history = history_of('hi')
      def conversations.save(*) = raise(Errno::ENOSPC)

      log = capture_log do
        runner.submit('hi')
        wait_until { runner.state == :running }
        agent.release
        wait_until { !runner.busy? }
      end

      assert_includes log, 'saving conversation'
      refute runner.busy?
    end
  end

  context 'worker errors' do
    it 'logs run_loop failures and returns to idle' do
      def agent.run_loop(user_message:, transport: nil) = raise 'transport exploded'
      log = StringIO.new
      PikuriWeb.logger = Logger.new(log)
      begin
        runner.submit('hello')
        wait_until { !runner.busy? }
        assert_includes log.string, 'transport exploded'
      ensure
        PikuriWeb.logger = Logger.new(File::NULL)
      end
    end
  end
end
