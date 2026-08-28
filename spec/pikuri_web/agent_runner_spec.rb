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
    attr_reader :messages, :clears, :loaded
    attr_accessor :history

    def initialize
      @gate = Thread::Queue.new
      @messages = []
      @clears = 0
      @loaded = []
      @history = Pikuri::Agent::History.new(messages: [])
    end

    def run_loop(user_message:)
      @messages << user_message
      @gate.pop
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

  let(:agent) { FakeAgent.new }
  let(:interloper) { Pikuri::Agent::Control::Interloper.new }
  let(:cancellable) { Pikuri::Agent::Control::Cancellable.new }
  let(:broadcaster) { PikuriWeb::Broadcaster.new }
  let(:conversations) do
    PikuriWeb::ConversationStore.new(root: @root, shell: 'pikuri-web-chat', model: 'qwen3.6')
  end
  let(:listener) { FakeListener.new }
  let(:transcript) { PikuriWeb::Transcript.new }
  let(:conversation) { conversations.create }
  let(:runner) do
    described_class.new(
      conversation: conversation,
      agent: agent, interloper: interloper, cancellable: cancellable,
      broadcaster: broadcaster, conversations: conversations, listener: listener,
      transcript: transcript,
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
      assert_equal({ state: :idle, busy: false, pending: 0, tokens: '' }, runner.status_data)
      runner.submit('first')
      wait_until { runner.state == :running }
      runner.submit('second')
      assert_equal({ state: :running, busy: true, pending: 1, tokens: '' }, runner.status_data)
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
        listener: listener, transcript: transcript, executor: blocker
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
      def conversations.write_meta(*) = raise(Errno::ENOSPC)

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
      def agent.run_loop(user_message:) = raise 'transport exploded'
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
