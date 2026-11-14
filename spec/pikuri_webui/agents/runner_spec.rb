# frozen_string_literal: true

require 'pikuri/testing'
require 'tmpdir'

# The runner over a real pikuri-conversations list, real agents on scripted
# transports, and a real store on a temp root. The turn state machine is the
# gem's and has its own specs; these pin what the runner adds on top — the
# status frame, the save, the title, the delete — as a browser would see them.
RSpec.describe PikuriWebUI::Agents::Runner do
  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) and example.run } }

  let(:lock) { PikuriWebUI::BigAppLock.new }
  let(:broadcaster) { PikuriWebUI::Web::Broadcaster.new }
  let(:store) { Pikuri::Conversations::Store.new(root: @root, shell: 'pikuri-webui-chat') }
  let(:entry) { store.create }

  # Engaged by an example that needs a turn held open mid-flight; says so on
  # +parked+ once a response is waiting in it.
  let(:parked) { Queue.new }
  let(:gate) do
    gate = Pikuri::Testing::Gate.new
    signal = parked
    gate.define_singleton_method(:await) do
      signal << true
      super()
    end
    gate
  end
  let(:modalities) { {} }
  let(:local) do
    Pikuri::Testing.fake_transport(gate: gate, modalities: modalities) do |llm|
      llm.reply('hello')
      llm.reply('again')
    end
  end
  let(:remote) { Pikuri::Testing.fake_transport(model: 'remote-model') { |llm| llm.reply('from afar') } }
  let(:catalog) do
    choice = PikuriWebUI::Agents::ModelCatalog::Choice
    PikuriWebUI::Agents::ModelCatalog.new(choices: [choice.new(name: 'Local', transport: local),
                                                    choice.new(name: 'Remote', transport: remote)])
  end

  let(:titler) { nil }
  let(:live) do
    Pikuri::Conversations.new(system_prompt: 'test agent', titler: titler,
                              on_turn_end: ->(conversation, history) { conversation.listener.persist(history) })
  end
  after do
    gate.release!
    live.shutdown(timeout: 5)
  end

  let(:transcript) { PikuriWebUI::Web::Transcript.new(lock: lock) }
  let(:token_log) { Pikuri::Agent::Listener::TokenLog.new }
  let(:missing) { nil }
  let(:raw_runner) do
    listener = PikuriWebUI::Web::SseListener.new(transcript: transcript, broadcaster: broadcaster,
                                                 conversation: entry.id, lock: lock)
    lock.run do
      described_class.new(conversation: entry, store: store, catalog: catalog, broadcaster: broadcaster,
                          transcript: transcript, listener: listener, agent_listeners: [listener, token_log],
                          token_log: token_log, missing_connection: missing, lock: lock)
                     .open(live, transport: local)
    end
  end
  let(:runner) { guard(raw_runner, lock) }

  def kinds = lock.run { transcript.to_a.map(&:kind) }
  def meta = JSON.parse((entry.dir / 'meta.json').read)
  def event_types(frames) = frames.map { |f| f[/event: (\w+)/, 1] }

  # Submit with the gate engaged, and return once the turn is parked in it —
  # past run_loop's opening drain, so a later message is a true injection.
  def hold_turn(message)
    gate.block!
    settle(runner, lock)
    outcome = runner.submit(message)
    parked.pop
    outcome
  end

  def finish
    gate.release!
    settle(runner, lock)
  end

  context '#status_data' do
    it 'starts idle, on the connection it opened on, with nothing measured' do
      settle(runner, lock)

      assert_equal({ state: 'idle', busy: false, pending: 0, tokens: '', tokens_detail: '',
                     model: 'Local', model_pending: nil, model_missing: nil }, runner.status_data)
    end

    it 'reads the context headline against the cap the transport states' do
      runner.submit('hi')
      settle(runner, lock)

      assert_match(%r{\Actx [\d.]+k/8k \(\d+%\)\z}, runner.status_data[:tokens])
      refute_includes runner.status_data[:tokens_detail], 'ctx='
    end
  end

  context '#submit' do
    it 'starts a turn that renders, then goes idle only once saved' do
      assert_equal :started, runner.submit('hi')
      settle(runner, lock)

      assert_equal %i[user assistant], kinds
      assert_equal %w[user assistant], store.history(entry).messages.map(&:role)
    end

    it 'injects into a running turn, counts it as pending, and delivers it' do
      hold_turn('one')

      assert_equal :injected, runner.submit('two')
      assert_equal 1, runner.status_data[:pending]
      assert runner.busy?

      finish
      assert_equal %i[user assistant user assistant], kinds
      assert_equal 0, runner.status_data[:pending]
    end

    context 'on a model that states it takes no images' do
      let(:modalities) { { vision: false } }

      it 'refuses an image up front, starting nothing' do
        settle(runner, lock)
        upload = PikuriWebUI::Conversations::Upload.from(filename: 'shot.png', bytes: "\x89PNG\r\n\x1A\n".b)

        assert_equal :refused, runner.submit('look', uploads: [upload])
        refute runner.busy?
        assert_empty kinds
      end
    end

    context 'on a transport with nothing scripted to answer' do
      let(:local) { Pikuri::Testing.fake_transport }

      it 'logs the failed turn and goes idle' do
        log = capture_log do
          runner.submit('hi')
          settle(runner, lock)
        end

        assert_includes log, 'turn failed'
        refute runner.busy?
      end
    end

    # A turn that fails mid-stream sends no agent event after its last delta,
    # so only TurnEnded can flush the rate limiter's tail. Fed as the gem would,
    # from outside the lock, to pin the frame order the browser sees.
    context 'behind the rate limiter, on a turn that fails mid-stream' do
      let(:raw_runner) do
        listener = PikuriWebUI::Web::SseListener.new(transcript: transcript, broadcaster: broadcaster,
                                                     conversation: entry.id, lock: lock)
        # A clock that never moves: the first delta flushes, every later one buffers.
        limiter = Pikuri::Conversations::RateLimitedListener.new(listener, fps: 15, clock: -> { 0.0 })
        lock.run do
          described_class.new(conversation: entry, store: store, catalog: catalog, broadcaster: broadcaster,
                              transcript: transcript, listener: listener, agent_listeners: [limiter, token_log],
                              token_log: token_log, lock: lock)
                         .open(live, transport: local)
        end
      end

      it "shows the reply's tail before the failure's status, not in the next turn" do
        settle(runner, lock)
        watching = broadcaster.subscribe(entry.id)
        agent = Pikuri::Agent::Event
        conversation = Pikuri::Conversations::Event
        capture_log do
          [agent::UserTurn.new(content: 'hi'),
           agent::AssistantDelta.new(content: 'The ans'),
           agent::AssistantDelta.new(content: 'wer is 42'),
           conversation::TurnEnded.new(outcome: :failed, error: RuntimeError.new('server gone'), restarting: false),
           conversation::TurnStarted.new(user_message: 'again', attachments: []),
           agent::UserTurn.new(content: 'again')].each { |event| raw_runner.on_event(event) }
        end

        frames = drain_frames(watching)
        tail = frames.index { |f| f.include?('wer is 42') }
        failure_status = frames.index { |f| f.start_with?('event: status') }
        next_message = frames.index { |f| f.include?('again') }
        refute_nil tail
        assert_operator tail, :<, failure_status
        assert_operator tail, :<, next_message
      end
    end
  end

  context 'status frames' do
    it 'reports the turn running, then idle' do
      settle(runner, lock)
      watching = broadcaster.subscribe(entry.id)

      runner.submit('hi')
      settle(runner, lock)

      states = drain_frames(watching).grep(/event: status/).map { |f| JSON.parse(f[/data: (.*)/, 1])['state'] }
      assert_includes states, 'running'
      assert_equal 'idle', states.last
    end

    # The per-row dot is the only sign a conversation you are not reading is
    # busy, so its start and its end reach every tab — and nothing else does.
    it 'tells every tab the sidebar changed on the busy transitions alone' do
      settle(runner, lock)
      everyone = broadcaster.subscribe('another-conversation')

      runner.submit('hi')
      settle(runner, lock)

      assert_equal %w[conversations conversations], event_types(drain_frames(everyone))
    end
  end

  context '#select_model' do
    it 'refuses a name this config does not have' do
      assert_equal :unknown, runner.select_model('Nowhere')
    end

    it 'shows the pick as pending, and is what a new conversation inherits' do
      settle(runner, lock)

      assert_equal :selected, runner.select_model('Remote')
      assert_equal 'Remote', runner.status_data[:model_pending]
      assert_equal ['remote-model', 'http://fake.invalid/v1'], runner.model
    end

    it 'clears the pick when it names the connection the agent is on' do
      settle(runner, lock)
      runner.select_model('Remote')

      runner.select_model('Local')

      assert_nil runner.status_data[:model_pending]
    end

    it 'takes effect at the next turn, which saves the new connection' do
      settle(runner, lock)
      runner.select_model('Remote')

      runner.submit('hi')
      settle(runner, lock)

      assert_equal 'Remote', runner.status_data[:model]
      assert_nil runner.status_data[:model_pending]
      assert_equal 'remote-model', meta.fetch('model')
    end
  end

  context 'a saved connection that has left the config file' do
    let(:missing) { 'gone-model @ http://gone.invalid/v1' }

    it 'carries the note until a turn saves the fallback' do
      assert_equal missing, runner.status_data[:model_missing]

      runner.submit('hi')
      settle(runner, lock)

      assert_nil runner.status_data[:model_missing]
    end

    it 'drops it once the user picks for themselves' do
      runner.select_model('Remote')
      assert_nil runner.status_data[:model_missing]
    end
  end

  context '#cancel' do
    it 'stops a running turn, which renders the cancellation and goes idle' do
      hold_turn('hi')

      runner.cancel
      finish

      assert_equal :error, kinds.last
      refute runner.busy?
    end
  end

  context '#discard!' do
    it 'retires an idle conversation: a later message is discarded, and no folder appears' do
      settle(runner, lock)

      assert runner.discard!
      assert runner.discard!, 'a second call still reports retired'
      assert_equal :discarded, runner.submit('hi')
      assert_equal :discarded, runner.select_model('Remote')
      refute entry.dir.exist?
    end

    it 'refuses while a turn runs, and succeeds once it has ended' do
      hold_turn('hi')

      refute runner.discard!

      finish
      assert runner.discard!
    end
  end

  context '#persist' do
    it 'gives a history with no messages no folder' do
      settle(runner, lock)
      raw_runner.persist(Pikuri::Agent::History.new(messages: []))

      refute entry.dir.exist?
    end

    it 'logs a failed save instead of raising into the turn' do
      store.define_singleton_method(:save) { |*, **| raise Errno::ENOSPC }

      log = capture_log do
        runner.submit('hi')
        settle(runner, lock)
      end

      assert_includes log, "saving conversation #{entry.id} failed"
      refute runner.busy?
    end
  end

  context 'titling' do
    let(:titler) do
      Pikuri::Conversations::Titler.new(
        transport: Pikuri::Testing.fake_transport { |llm| llm.reply('Keeping An Avocado') }
      )
    end

    it 'names a stamp-titled conversation after its first turn, on disk and for every tab' do
      settle(runner, lock)
      everyone = broadcaster.subscribe('another-conversation')

      runner.submit('how do I keep an avocado?')
      # By its effect: the title thread names itself only once it runs, so
      # #settle can pass before it exists.
      wait_until { runner.conversation.title == 'Keeping An Avocado' }

      assert_equal 'Keeping An Avocado', runner.conversation.title
      assert_equal 'Keeping An Avocado', meta.fetch('title')
      assert_includes event_types(drain_frames(everyone)), 'conversations'
    end

    context 'for a conversation already named' do
      let(:entry) { store.create.with(title: 'Mine') }

      it 'leaves the name alone' do
        runner.submit('how do I keep an avocado?')
        settle(runner, lock)

        assert_equal 'Mine', meta.fetch('title')
      end
    end
  end
end
