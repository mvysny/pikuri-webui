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
  let(:runner) do
    described_class.new(
      agent: agent, interloper: interloper, cancellable: cancellable,
      broadcaster: broadcaster, conversations: conversations, listener: listener
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

  context '#load_conversation' do
    # A conversation on disk to switch to. Written the way the runner writes
    # one: pikuri's history, then our envelope.
    def saved(text)
      conversation = conversations.create(at: Time.now - 3600)
      history_of(text).save(conversation.dir)
      conversations.write_meta(conversation)
      conversation
    end

    it 'saves what is live, hands the stored history to the agent, and replays it' do
      target = saved('older question')
      agent.history = history_of('current question')
      leaving = runner.conversation

      assert_equal :loaded, runner.load_conversation(target)

      assert_equal target.id, runner.conversation.id
      assert (leaving.dir / 'history.json').file?, 'left without saving the outgoing conversation'
      assert_equal ['older question'], agent.loaded.flat_map { |h| h.messages.map(&:content) }
      assert_equal ['older question'], listener.events.map(&:content)
    end

    it 'broadcasts status, since HistoryLoaded reseeds the token readout' do
      queue = broadcaster.subscribe
      runner.load_conversation(saved('older question'))
      assert_equal %w[status], drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }
    end

    it 'refuses while a turn is in flight, leaving the transcript to the running turn' do
      target = saved('older question')
      runner.submit('first')
      wait_until { agent.messages.any? }

      assert_equal :busy, runner.load_conversation(target)

      assert_empty agent.loaded
      assert_empty listener.events
    end

    it 'does nothing when asked for the conversation already live' do
      assert_equal :current, runner.load_conversation(runner.conversation)
      assert_empty agent.loaded
    end

    it 'leaves the live conversation alone when the stored history is unreadable' do
      target = saved('older question')
      (target.dir / 'history.json').write('not json')
      agent.history = history_of('current question')

      log = capture_log { assert_equal :failed, runner.load_conversation(target) }

      assert_includes log, "loading conversation #{target.id} failed"
      refute_equal target.id, runner.conversation.id
      assert_empty agent.loaded
      assert_empty listener.events
    end
  end

  context '#delete_conversation' do
    def saved(text)
      conversation = conversations.create(at: Time.now - 3600)
      history_of(text).save(conversation.dir)
      conversations.write_meta(conversation)
      conversation
    end

    it 'removes a stored conversation without disturbing the live one' do
      target = saved('old news')
      live = runner.conversation
      agent.history = history_of('current question')

      assert_equal :deleted, runner.delete_conversation(target)

      refute target.dir.exist?
      assert_equal live.id, runner.conversation.id
      assert_equal 0, agent.clears
    end

    it 'clears the agent and mints a fresh conversation when the live one goes' do
      agent.history = history_of('current question')
      live = runner.conversation
      conversations.write_meta(live) # committed by an earlier turn's save

      assert_equal :deleted, runner.delete_conversation(live)

      refute live.dir.exist?
      refute_equal live.id, runner.conversation.id
      assert_equal 1, agent.clears
    end

    it 'does not save the live conversation on the way out — the point is not to keep it' do
      agent.history = history_of('current question')
      live = runner.conversation

      runner.delete_conversation(live)

      refute live.dir.exist?, 'delete saved the conversation it was told to remove'
      assert_empty @root.children
    end

    it 'broadcasts the sidebar signal, and status too when the live one went' do
      target = saved('old news')
      queue = broadcaster.subscribe
      runner.delete_conversation(target)
      assert_equal %w[conversations], drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }

      queue = broadcaster.subscribe
      runner.delete_conversation(runner.conversation)
      assert_equal %w[status conversations], drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }
    end

    it 'refuses while a turn is in flight, which would save the folder straight back' do
      target = saved('old news')
      runner.submit('first')
      wait_until { agent.messages.any? }

      assert_equal :busy, runner.delete_conversation(target)

      assert target.dir.exist?
    end

    it 'reports failure without leaving the agent pointed at a deleted conversation' do
      live = runner.conversation
      agent.history = history_of('current question')
      # A Conversation the store will refuse: not under its root.
      outside = PikuriWeb::ConversationStore::Conversation.new(
        id: live.id, dir: @root.parent / live.id, title: 'x',
        created_at: Time.now, supported: true
      )

      log = capture_log { assert_equal :failed, runner.delete_conversation(outside) }

      assert_includes log, "deleting conversation #{live.id} failed"
      refute_equal live.id, runner.conversation.id, 'left the agent on the conversation it cleared'
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
