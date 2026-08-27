# frozen_string_literal: true

require 'tmpdir'

# Exercises the start-vs-inject decision and the save/clear transition
# against a real Interloper / Cancellable, a real ConversationStore over a
# temp directory, and a gate-controlled fake agent so worker-thread timing
# is deterministic.
RSpec.describe PikuriWeb::AgentRunner do
  # Stands in for Pikuri::Agent: records run_loop messages, blocks on a gate
  # until the spec releases it, and serves a real History (so #persist
  # exercises pikuri's own save rather than a stub).
  class FakeAgent
    attr_reader :messages, :clears
    attr_accessor :history

    def initialize
      @gate = Thread::Queue.new
      @messages = []
      @clears = 0
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

    def release = @gate.push(:go)
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
  let(:runner) do
    described_class.new(
      agent: agent, interloper: interloper, cancellable: cancellable,
      broadcaster: broadcaster, conversations: conversations
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
      wait_until { runner.busy? }
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
      queue = broadcaster.subscribe # after the injection, so only the drain's frame lands

      interloper.drain! # what Agent does at the next tool-batch boundary

      frames = drain_frames(queue)
      assert_equal %w[status], frames.map { |f| f[/event: (\w+)/, 1] }
      assert_includes frames.fetch(0), '"pending":0'

      agent.release
      wait_until { !runner.busy? }
    end
  end

  context 'status broadcasting' do
    it 'broadcasts status on submit and on turn end' do
      queue = broadcaster.subscribe
      runner.submit('hello')
      wait_until { runner.busy? }
      agent.release
      wait_until { !runner.busy? }
      types = drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }
      assert_equal %w[status status], types
    end
  end

  context '#status_data' do
    it 'reports busy state and pending injections' do
      assert_equal({ busy: false, pending: 0, tokens: '' }, runner.status_data)
      runner.submit('first')
      wait_until { runner.busy? }
      runner.submit('second')
      assert_equal({ busy: true, pending: 1, tokens: '' }, runner.status_data)
    end
  end

  context '#cancel' do
    it 'sets the cancel flag while busy' do
      runner.submit('hello')
      wait_until { runner.busy? }
      runner.cancel
      assert cancellable.cancelled?
    end

    it 'is a no-op when idle' do
      runner.cancel
      refute cancellable.cancelled?
    end
  end

  context 'persistence at turn end' do
    it 'writes history.json and meta.json into the live conversation' do
      agent.history = history_of('what is 2+2?')
      dir = runner.conversation.dir
      runner.submit('what is 2+2?')
      wait_until { runner.busy? }
      agent.release
      wait_until { !runner.busy? }

      assert_equal %w[history.json meta.json], dir.children.map { |c| c.basename.to_s }.sort
      assert_equal agent.history, Pikuri::Agent::History.load(dir)
    end

    it 'writes nothing for a turn that left no messages' do
      dir = runner.conversation.dir
      runner.submit('hello')
      wait_until { runner.busy? }
      agent.release
      wait_until { !runner.busy? }

      refute dir.exist?
      assert_empty @root.children
    end

    it 'logs a save failure instead of killing the worker thread' do
      agent.history = history_of('hi')
      def conversations.write_meta(*) = raise(Errno::ENOSPC)

      log = capture_log do
        runner.submit('hi')
        wait_until { runner.busy? }
        agent.release
        wait_until { !runner.busy? }
      end

      assert_includes log, 'saving conversation'
      refute runner.busy?
    end
  end

  context '#new_conversation' do
    it 'saves the old conversation, clears the agent, and mints a fresh id' do
      agent.history = history_of('hello')
      old = runner.conversation

      assert_equal :started, runner.new_conversation

      assert_equal 1, agent.clears
      refute_equal old.id, runner.conversation.id
      assert (old.dir / 'history.json').file?
      refute runner.conversation.dir.exist?
    end

    it 'broadcasts status, since Reset zeroes the token readout' do
      agent.history = history_of('hello')
      queue = broadcaster.subscribe
      runner.new_conversation
      assert_equal %w[status], drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }
    end

    it 'is a no-op on an empty conversation rather than minting a fresh folder' do
      before = runner.conversation

      assert_equal :empty, runner.new_conversation

      assert_equal 0, agent.clears
      assert_equal before.id, runner.conversation.id
      assert_empty @root.children
    end

    it 'refuses while a turn is in flight' do
      agent.history = history_of('first')
      runner.submit('first')
      wait_until { agent.messages.any? }

      assert_equal :busy, runner.new_conversation

      assert_equal 0, agent.clears
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
