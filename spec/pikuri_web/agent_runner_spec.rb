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
  # Absent for most examples, as it is for a runner nobody metered; the
  # context-readout context overrides it with a real one.
  let(:token_log) { nil }
  let(:lock) { PikuriWeb::BigAppLock.new }
  let(:transcript) { PikuriWeb::Transcript.new(lock: lock) }
  let(:conversation) { conversations.create }
  # A real thread, not ImmediateExecutor: these examples are *about* the busy
  # state, which needs the turn still running when #submit returns. One thread
  # is enough for everything but titling, which posts a second job here.
  let(:executor) { Concurrent::SingleThreadExecutor.new }
  # Absent for most examples, as it is with no [titler] configured.
  let(:titler) { nil }
  # Guarded proxy: the spec drives the runner the way a route task does.
  let(:runner) do
    guard(described_class.new(
            conversation: conversation,
            agent: agent, interloper: interloper, cancellable: cancellable,
            broadcaster: broadcaster, conversations: conversations, listener: listener,
            transcript: transcript, catalog: catalog, token_log: token_log, lock: lock,
            titler: titler, executor: executor
          ), lock)
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
    it 'broadcasts status on submit, on the turn starting and on turn end, the sidebar signal on each transition' do
      queue = broadcaster.subscribe(conversation.id)
      runner.submit('hello')
      wait_until { runner.state == :running }
      agent.release
      wait_until { !runner.busy? }
      types = drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }

      assert_equal 3, types.count('status')
      # Two, not three: the middle frame is queued → running, and both are busy.
      assert_equal 2, types.count('conversations')
    end

    # The frame nothing else can send. A turn that really waited for a slot has
    # no event at all between the queued frame and its end, so a browser left
    # holding ":queued" reads "waiting for a free slot" for the whole turn —
    # which is what shipped until #claim_running broadcast on both paths.
    it 'broadcasts the start of a turn that waited for an executor slot' do
      blocker = Concurrent::SingleThreadExecutor.new
      gate = Thread::Queue.new
      blocker.post { gate.pop }
      queued = guard(described_class.new(
                       conversation: conversation, agent: agent, interloper: interloper,
                       cancellable: cancellable, broadcaster: broadcaster, conversations: conversations,
                       listener: listener, transcript: transcript, catalog: catalog, executor: blocker,
                       lock: lock
                     ), lock)
      subscription = broadcaster.subscribe(conversation.id)

      queued.submit('hello')
      assert_equal :queued, queued.state
      gate.push(:go) # the slot frees and the turn starts

      states = []
      wait_until do
        states.concat(drain_frames(subscription).filter_map { |f| f[/"state":"(\w+)"/, 1] })
        states.include?('running')
      end
      assert_equal %w[queued running], states

      agent.release
      wait_until { !queued.busy? }
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

  # The compose-then-publish seam (the atomicity audit's seam 2), closed
  # structurally: composing a status payload and pushing it happen inside one
  # task, so composed order *is* push order and a browser can never be left
  # holding an older state over a newer one. Flipped from the seam audit's
  # PROBE 6, which forced the tear deterministically before the domain landed.
  context 'status frame ordering' do
    # A broadcaster that can park one caller between composing a frame and
    # pushing it — the window the tear needed. Under the domain that park
    # happens inside the task, so the racer waits at the domain door instead
    # of overtaking.
    class HoldingBroadcaster < PikuriWeb::Broadcaster
      attr_accessor :hold

      def broadcast(event:, data:, conversation: nil)
        @hold&.call(data)
        super
      end
    end

    let(:broadcaster) { HoldingBroadcaster.new }

    it 'an older status frame can no longer land after a newer one' do
      blocker = Concurrent::SingleThreadExecutor.new
      gate = Thread::Queue.new
      blocker.post { gate.pop } # keep the submitted turn :queued throughout
      queued = guard(described_class.new(
                       conversation: conversation, agent: agent, interloper: interloper,
                       cancellable: cancellable, broadcaster: broadcaster, conversations: conversations,
                       listener: listener, transcript: transcript, catalog: catalog, executor: blocker,
                       lock: lock
                     ), lock)
      subscription = broadcaster.subscribe(conversation.id)

      held = Thread::Queue.new
      released = Thread::Queue.new
      broadcaster.hold = lambda do |data|
        next unless data.key?(:state)

        broadcaster.hold = nil
        held.push(data[:state])
        released.pop
      end

      stale = Thread.new { queued.select_model('remote') } # composes :idle, parks pre-push
      assert_equal :idle, held.pop
      racer = Thread.new { queued.submit('hello') } # would overtake; now waits at the door
      sleep 0.02
      released.push(:go)
      stale.join
      racer.join

      states = drain_frames(subscription).filter_map { |f| f[/"state":"(\w+)"/, 1] }
      assert_equal %w[idle queued], states, 'composed order is push order'
      assert_equal :queued, queued.state, 'and the last frame shown is the truth'

      queued.cancel
      gate.push(:go)
      wait_until { queued.state == :idle }
    end
  end

  context '#status_data' do
    it 'reports busy state and pending injections' do
      assert_equal({ state: :idle, busy: false, pending: 0, tokens: '', tokens_detail: '',
                     model: 'local', model_pending: nil, model_missing: nil },
                   runner.status_data)
      runner.submit('first')
      wait_until { runner.state == :running }
      runner.submit('second')
      assert_equal({ state: :running, busy: true, pending: 1, tokens: '', tokens_detail: '',
                     model: 'local', model_pending: nil, model_missing: nil },
                   runner.status_data)
    end
  end

  # Against a real TokenLog, because the tail is pikuri's own line with the
  # +ctx=+ segment lifted out — a stub would only test the lift.
  context '#status_data context readout' do
    let(:token_log) { Pikuri::Agent::Listener::TokenLog.new }

    def meter(cap: nil, input: 8000, output: 400)
      token_log.on_event(Pikuri::Agent::Event::ContextCap.new(cap: cap)) if cap
      token_log.on_event(
        Pikuri::Agent::Event::Tokens.new(input: input, output: output, cached: 0,
                                         cache_creation: 0, thinking: 0, model_id: 'qwen3.6')
      )
    end

    it 'says nothing until a turn is measured' do
      assert_equal ['', ''], runner.status_data.values_at(:tokens, :tokens_detail)
    end

    it 'splits the headline off the per-turn tail' do
      meter(cap: 32_768)
      assert_equal 'ctx 8.2k/32k (26%)', runner.status_data[:tokens]
      assert_equal 'msg #1  Δ+8.2k  ↑7.8k  ↓0.4k', runner.status_data[:tokens_detail]
    end

    it 'drops the percentage when no cap reached the log' do
      meter
      assert_equal 'ctx 8.2k', runner.status_data[:tokens]
      assert_equal 'msg #1  Δ+8.2k  ↑7.8k  ↓0.4k', runner.status_data[:tokens_detail]
    end

    # The line a reopened conversation shows before it says anything: the
    # agent's own +load_history!+ seeds the log, so the split has to hold for
    # a tail that is one word rather than the +msg #N+ shape.
    it 'splits the line a restored conversation is seeded with' do
      token_log.on_event(Pikuri::Agent::Event::ContextCap.new(cap: 65_536))
      token_log.on_event(
        Pikuri::Agent::Event::HistoryLoaded.new(
          messages: 4,
          tokens: Pikuri::Agent::Event::Tokens.new(input: 1500, output: 100, cached: 0,
                                                   cache_creation: 0, thinking: 0, model_id: 'qwen3.6')
        )
      )

      assert_equal 'ctx 1.6k/64k (2%)', runner.status_data[:tokens]
      assert_equal 'restored', runner.status_data[:tokens_detail]
    end

    # The push, not the poll: nothing else broadcasts between a turn's start and
    # its end, so without the on_status_line claim the whole loop's numbers would
    # land at once, at the end.
    it 'broadcasts a status frame when a turn is measured mid-loop' do
      queue = broadcaster.subscribe(conversation.id)
      runner.submit('hello')
      wait_until { runner.state == :running }
      drain_frames(queue)

      meter(cap: 32_768) # as the loop thread would, one round-trip in

      frames = drain_frames(queue)
      assert_equal %w[status], frames.map { |f| f[/event: (\w+)/, 1] }
      assert_includes frames.fetch(0), 'ctx 8.2k/32k (26%)'
      assert_includes frames.fetch(0), '"state":"running"', 'measured mid-turn, not at the end'
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
      guard(described_class.new(
              conversation: conversation, agent: agent, interloper: interloper,
              cancellable: cancellable, broadcaster: broadcaster, conversations: conversations,
              listener: listener, transcript: transcript, catalog: catalog,
              executor: Concurrent::ImmediateExecutor.new, lock: lock,
              missing_connection: 'qwen2 @ http://retired:8080/v1'
            ), lock)
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
      queued = guard(described_class.new(
                       conversation: conversation, agent: agent, interloper: interloper,
                       cancellable: cancellable, broadcaster: broadcaster, conversations: conversations,
                       listener: listener, transcript: transcript, catalog: catalog, executor: blocker,
                       lock: lock
                     ), lock)

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
      queued = guard(described_class.new(
                       conversation: conversation, agent: agent, interloper: interloper,
                       cancellable: cancellable, broadcaster: broadcaster, conversations: conversations,
                       listener: listener, transcript: transcript, catalog: catalog, executor: blocker,
                       lock: lock
                     ), lock)

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

  # Titling is fire-and-forget beside the turn, so every example here asserts
  # two things at once: that the title landed (or didn't), and that the turn
  # was untouched either way.
  context 'titling a new conversation' do
    # Stands in for Titler: records the openers it was asked about and answers
    # from the block.
    class FakeTitler
      attr_reader :openers

      def initialize(&answer)
        @answer = answer
        @openers = []
      end

      def title_for(opener)
        @openers << opener
        @answer.call(opener)
      end
    end

    # Titling posts a *second* job, so a single-thread pool would sit it behind
    # the gated turn and every example here would time out. Production runs an
    # unbounded pool for exactly this reason.
    let(:executor) { Concurrent::CachedThreadPool.new }
    let(:titler) { FakeTitler.new { 'Sinatra Versus Roda For SSE' } }
    let(:stamp) { conversation.title }

    it 'names the conversation from its opening message' do
      runner.submit('Compare Sinatra and Roda for SSE')
      wait_until { runner.conversation.title != stamp }

      assert_equal ['Compare Sinatra and Roda for SSE'], titler.openers
      assert_equal 'Sinatra Versus Roda For SSE', runner.conversation.title
    end

    it 'tells every tab the list changed, addressed to no single conversation' do
      queue = broadcaster.subscribe(nil)
      runner.submit('hello')
      wait_until { drain_frames(queue).any? { |f| f.include?('event: conversations') } }
    end

    it 'leaves the turn alone: the message still ran, and the runner still goes idle' do
      runner.submit('hello')
      wait_until { agent.messages.any? }
      assert_equal ['hello'], agent.messages
      agent.release
      wait_until { !runner.busy? }
    end

    it 'asks once, however many messages follow' do
      runner.submit('first')
      wait_until { titler.openers.any? }
      agent.release
      wait_until { !runner.busy? }
      runner.submit('second')
      wait_until { agent.messages.size == 2 }

      assert_equal ['first'], titler.openers
    end

    it 'titles a stored conversation from its own opener, never the next message' do
      conversations.save(conversation, history_of('an older opener'),
                         model: 'qwen3.6', server: 'http://localhost:8080/v1')
      assert runner.restore!
      runner.submit('a much later message')
      wait_until { runner.conversation.title != stamp }

      assert_equal ['an older opener'], titler.openers
    end

    # Retro-titling reaches a conversation older than the feature the first
    # time someone opens it. Inline execution rather than a pool, so "was the
    # titler asked?" is settled by the time #restore! returns.
    context 'opening a conversation that is already on disk' do
      let(:executor) { Concurrent::ImmediateExecutor.new }

      def stored(history)
        conversations.save(conversation, history,
                           model: 'qwen3.6', server: 'http://localhost:8080/v1')
      end

      it 'names it on open, off the history it just replayed' do
        stored(history_of('an older opener'))
        runner.restore!

        assert_equal ['an older opener'], titler.openers
        assert_equal 'Sinatra Versus Roda For SSE', runner.conversation.title
      end

      it 'leaves one holding no user text alone' do
        stored(Pikuri::Agent::History.new(
                 messages: [Pikuri::Agent::History::Message.new(
                   id: Pikuri::Agent::History.mint_id, role: 'assistant', content: 'orphaned reply'
                 )]
               ))
        runner.restore!

        assert_empty titler.openers
        assert_equal stamp, runner.conversation.title
      end
    end

    it 'leaves an already-named conversation alone' do
      named = conversations.retitle(conversation, 'Named By Hand')
      runner = guard(described_class.new(
                       conversation: named, agent: agent, interloper: interloper,
                       cancellable: cancellable, broadcaster: broadcaster,
                       conversations: conversations, listener: listener, transcript: transcript,
                       catalog: catalog, token_log: token_log, lock: lock,
                       titler: titler, executor: executor
                     ), lock)
      runner.submit('hello')
      wait_until { agent.messages.any? }

      assert_empty titler.openers
      assert_equal 'Named By Hand', runner.conversation.title
    end

    context 'when the titler cannot answer' do
      let(:titler) { FakeTitler.new { nil } }

      it 'keeps the stamp' do
        runner.submit('hello')
        wait_until { titler.openers.any? }
        assert_equal stamp, runner.conversation.title
      end
    end

    context 'when the titler raises' do
      let(:titler) { FakeTitler.new { raise 'titler exploded' } }

      it 'logs, keeps the stamp, and finishes the turn' do
        log = StringIO.new
        PikuriWeb.logger = Logger.new(log)
        begin
          runner.submit('hello')
          wait_until { log.string.include?('titler exploded') }
          assert_includes log.string, "titling conversation #{conversation.id} failed"
          assert_equal stamp, runner.conversation.title
          agent.release
          wait_until { !runner.busy? }
        ensure
          PikuriWeb.logger = Logger.new(File::NULL)
        end
      end
    end
  end
end
