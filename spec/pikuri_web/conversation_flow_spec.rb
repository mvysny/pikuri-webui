# frozen_string_literal: true

require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot
require 'tmpdir'

# The whole slice wired as production wires it: a real registry over a real
# factory, real Pikuri::Agents over scripted transports, the real listener
# stack, and a real store over a temp directory. What the unit specs cannot
# show is that the events the agent actually emits drive the transcript, the
# save and the SSE addressing the way the fakes assume.
RSpec.describe 'conversations end to end' do
  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  let(:broadcaster) { PikuriWeb::Broadcaster.new }
  let(:store) do
    PikuriWeb::ConversationStore.new(root: @root, shell: 'pikuri-web-chat')
  end

  # One connection, named after the scripted transport every conversation gets:
  # the catalog keys on [model, api_base], so each factory-built transport
  # resolves to this entry despite carrying its own scripted adapter.
  let(:catalog) do
    PikuriWeb::ModelCatalog.new(
      choices: [PikuriWeb::ModelCatalog::Choice.new(name: 'fake', transport: Pikuri::Testing.fake_transport)]
    )
  end

  # Extensions own the public route to Agent#append_reference_block: a String
  # back from on_user_message is what the agent wraps in <system-reminder> and
  # emits as SystemInjected.
  class SkillInjector
    include Pikuri::Agent::Extension

    def on_user_message(_ctx, _content) = '<skill name="writing-rdoc">the whole SKILL.md body</skill>'
  end

  let(:extensions) { [] }

  # Runs turns inline on the calling thread, so #submit returns with the turn
  # finished and the save landed — no waiting, no timeout, no flake.
  let(:executor) { Concurrent::ImmediateExecutor.new }

  # Everything a conversation owns, wired exactly as bin/pikuri-web-chat wires
  # it — one stack per conversation, sharing only the broadcaster, the store
  # and the executor.
  let(:lock) { PikuriWeb::BigAppLock.new }
  let(:factory) do
    lambda do |conversation|
      interloper = Pikuri::Agent::Control::Interloper.new
      cancellable = Pikuri::Agent::Control::Cancellable.new
      transcript = PikuriWeb::Transcript.new(lock: lock)
      listener = PikuriWeb::SseListener.new(
        transcript: transcript, broadcaster: broadcaster, conversation: conversation.id,
        lock: lock
      )
      transport = Pikuri::Testing.fake_transport do |llm|
        llm.tool_call('calculator', expression: '2 + 2')
        llm.reply('The answer is 4.')
        llm.reply('A fresh start.')
      end
      agent = Pikuri::Agent.new(
        transport: transport,
        system_prompt: 'test agent',
        cancellable: cancellable,
        interloper: interloper
      ) do |c|
        c.add_listener listener
        c.add_tool Pikuri::Tool::CALCULATOR
        extensions.each { |extension| c.add_extension extension }
      end
      agents << agent

      PikuriWeb::AgentRunner.new(
        conversation: conversation, agent: agent, interloper: interloper,
        cancellable: cancellable, broadcaster: broadcaster, conversations: store,
        transcript: transcript, listener: listener, executor: executor, catalog: catalog,
        lock: lock
      )
    end
  end

  let(:agents) { [] }
  let(:registry) do
    guard(PikuriWeb::ConversationRegistry.new(store: store, factory: factory, lock: lock), lock)
  end
  let(:runner) { guard(registry.create, lock) }
  let(:transcript) { guard(runner.transcript, lock) }

  after { agents.each(&:close) }

  def event_types(frames) = frames.map { |f| f[/event: (\w+)/, 1] }

  it 'renders the turn, then saves exactly what the agent holds' do
    dir = runner.conversation.dir
    runner.submit('What is 2 + 2?')

    assert_equal %i[user tool_call tool_result assistant], transcript.to_a.map(&:kind)

    history = Pikuri::Agent::History.load(dir)
    assert_equal %w[user assistant tool assistant], history.messages.map(&:role)
    # The truncation the transcript applies is the shell's, not the file's.
    assert_equal 'What is 2 + 2?', history.messages.first.content
    meta = JSON.parse((dir / 'meta.json').read)
    assert_equal 1, meta.fetch('schema')
    # The connection comes off the agent's own transport at turn end, which is
    # what keeps it agreeing with history.json's model_id.
    assert_equal ['fake-model', 'http://fake.invalid/v1'], meta.values_at('model', 'server')
  end

  # The property this whole design exists for. Two conversations, two agents,
  # two transcripts: work in one is invisible to the other, and a tab reading
  # the second is never sent the first one's frames.
  context 'two conversations at once' do
    it 'keeps transcripts, histories and SSE frames apart' do
      first = guard(registry.create, lock)
      second = guard(registry.create, lock)
      watching_second = broadcaster.subscribe(second.conversation.id)

      first.submit('What is 2 + 2?')

      refute_empty lock.run { first.transcript.to_a }
      assert_empty lock.run { second.transcript.to_a }
      # Not silence: the sidebar signal is addressed to every tab on purpose,
      # because the first conversation's row now has a dot. What must never
      # arrive is a frame carrying the first conversation's content or status.
      assert_equal ['conversations'], event_types(drain_frames(watching_second)).uniq
      refute (second.conversation.dir / 'history.json').exist?
    end

    it 'sends a turn frames only to the tabs reading that conversation' do
      first = guard(registry.create, lock)
      watching_first = broadcaster.subscribe(first.conversation.id)

      first.submit('What is 2 + 2?')

      assert_includes event_types(drain_frames(watching_first)), 'block'
    end

    it 'leaves each conversation with its own turn state' do
      first = guard(registry.create, lock)
      second = guard(registry.create, lock)

      first.submit('What is 2 + 2?')

      assert_equal :idle, first.state
      assert_equal :idle, second.state
      refute second.busy?
    end
  end

  # What Q_store_format (b) rests on: the file holds only messages, and the
  # blocks are re-derived. Reopening is the path a browser takes when it comes
  # back to a conversation after a restart.
  context 'reopening a saved conversation' do
    def rendered(store) = lock.run { store.to_a.map { |b| [b.kind, b.html] } }

    it 'rebuilds the transcript the live turn produced, block for block' do
      conversation = runner.conversation
      runner.submit('What is 2 + 2?')
      produced = rendered(transcript)

      # A second registry over the same folder: what a restarted process sees.
      reopened = guard(PikuriWeb::ConversationRegistry.new(store: store, factory: factory, lock: lock),
                       lock).open_id(conversation.id)

      assert_equal produced, rendered(reopened.transcript)
    end

    context 'with an extension injecting a reference block' do
      let(:extensions) { [SkillInjector.new] }

      it 'renders it as the one-line notice, not the wrapped body' do
        conversation = runner.conversation
        runner.submit('What is 2 + 2?')
        produced = rendered(transcript)

        reopened = guard(PikuriWeb::ConversationRegistry.new(store: store, factory: factory, lock: lock),
                         lock).open_id(conversation.id)

        assert_includes produced.map(&:last).join, 'loaded skill: writing-rdoc'
        assert_equal produced, rendered(reopened.transcript)
      end
    end

    # What reopening does on the way in and a turn end does on the way out,
    # with no turn between: the file the agent writes back has to be the file
    # it was handed.
    it 'round-trips the folder unchanged' do
      dir = runner.conversation.dir
      runner.submit('What is 2 + 2?')
      before = (dir / 'history.json').read

      guard(PikuriWeb::ConversationRegistry.new(store: store, factory: factory, lock: lock), lock)
        .open_id(runner.conversation.id)
      agents.last.export_history.save(dir)

      assert_equal before, (dir / 'history.json').read
    end

    it 'restores nothing, quietly, for a conversation never saved' do
      fresh = registry.create
      assert_empty lock.run { fresh.transcript.to_a }
    end
  end

  context 'deleting' do
    it 'removes the folder and forgets the runner' do
      runner.submit('What is 2 + 2?')
      conversation = runner.conversation

      assert_equal :deleted, registry.delete(conversation)

      refute conversation.dir.exist?
      assert_nil registry.resident(conversation.id)
    end

    it 'does not resurrect the folder from a runner that is gone' do
      runner.submit('What is 2 + 2?')
      conversation = runner.conversation
      registry.delete(conversation)

      # The old runner still exists in this spec's hand, but the registry has
      # dropped it: reopening mints a fresh one over an empty folder.
      reopened = guard(registry.create, lock)
      reopened.submit('and again?')

      refute conversation.dir.exist?
    end
  end
end
