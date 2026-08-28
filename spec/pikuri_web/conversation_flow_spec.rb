# frozen_string_literal: true

require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot
require 'tmpdir'

# The whole slice wired as production wires it: a real Pikuri::Agent over a
# scripted transport, the real listener stack, and a real store over a temp
# directory. What the unit specs cannot show is that the events the agent
# actually emits drive the transcript and the save the way the fakes assume.
RSpec.describe 'saving a conversation and starting a new one' do
  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  let(:transcript) { PikuriWeb::Transcript.new }
  let(:broadcaster) { PikuriWeb::Broadcaster.new }
  let(:interloper) { Pikuri::Agent::Control::Interloper.new }
  let(:cancellable) { Pikuri::Agent::Control::Cancellable.new }
  let(:conversations) do
    PikuriWeb::ConversationStore.new(root: @root, shell: 'pikuri-web-chat', model: 'fake-model')
  end

  # Extensions own the public route to Agent#append_reference_block: a String
  # back from on_user_message is what the agent wraps in <system-reminder> and
  # emits as SystemInjected.
  class SkillInjector
    include Pikuri::Agent::Extension

    def on_user_message(_ctx, _content) = '<skill name="writing-rdoc">the whole SKILL.md body</skill>'
  end

  let(:listener) { PikuriWeb::SseListener.new(transcript: transcript, broadcaster: broadcaster) }
  let(:extensions) { [] }

  let(:agent) do
    transport = Pikuri::Testing.fake_transport do |llm|
      llm.tool_call('calculator', expression: '2 + 2')
      llm.reply('The answer is 4.')
      llm.reply('A fresh start.')
    end
    Pikuri::Agent.new(
      transport: transport,
      system_prompt: 'test agent',
      cancellable: cancellable,
      interloper: interloper
    ) do |c|
      c.add_listener listener
      c.add_tool Pikuri::Tool::CALCULATOR
      extensions.each { |extension| c.add_extension extension }
    end
  end

  let(:runner) do
    PikuriWeb::AgentRunner.new(
      agent: agent, interloper: interloper, cancellable: cancellable,
      broadcaster: broadcaster, conversations: conversations, listener: listener
    )
  end

  after { agent.close }

  # The runner's turn is on a worker thread; #busy? stays true until the save
  # has landed, so this is also "saved".
  def run_turn(message)
    runner.submit(message)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    while runner.busy?
      flunk 'turn did not finish' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end

  it 'renders the turn, then saves exactly what the agent holds' do
    dir = runner.conversation.dir
    run_turn('What is 2 + 2?')

    assert_equal %i[user tool_call tool_result assistant], transcript.to_a.map(&:kind)

    history = Pikuri::Agent::History.load(dir)
    assert_equal %w[user assistant tool assistant], history.messages.map(&:role)
    assert_equal history, agent.export_history
    # The truncation the transcript applies is the shell's, not the file's.
    assert_equal 'What is 2 + 2?', history.messages.first.content
    assert_equal 1, JSON.parse((dir / 'meta.json').read).fetch('schema')
  end

  it 'clears the live conversation and keeps the saved one readable' do
    saved = runner.conversation
    run_turn('What is 2 + 2?')
    queue = broadcaster.subscribe

    assert_equal :started, runner.new_conversation

    assert_empty transcript.to_a
    assert_includes drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }, 'reset'
    assert_empty agent.export_history.messages
    assert_equal 4, Pikuri::Agent::History.load(saved.dir).messages.size
  end

  # What Q_store_format (b) rests on: the file holds only messages, and the
  # blocks are re-derived. These are the specs that catch a drift between what
  # the agent emits live and what HistoryReplay synthesizes — including the
  # <system-reminder> envelope, whose tag is a private constant upstream that
  # HistoryReplay has to mirror.
  context 'replaying a saved conversation' do
    def rendered(store) = store.to_a.map { |b| [b.kind, b.html] }

    # A listener with nowhere to broadcast, fed only from disk.
    def replay_into(transcript, dir)
      listener = PikuriWeb::SseListener.new(transcript: transcript, broadcaster: PikuriWeb::Broadcaster.new)
      PikuriWeb::HistoryReplay.events(Pikuri::Agent::History.load(dir)).each { |e| listener.on_event(e) }
    end

    it 'rebuilds the transcript the live turn produced, block for block' do
      dir = runner.conversation.dir
      run_turn('What is 2 + 2?')

      restored = PikuriWeb::Transcript.new
      replay_into(restored, dir)

      assert_equal rendered(transcript), rendered(restored)
    end

    context 'with an extension injecting a reference block' do
      let(:extensions) { [SkillInjector.new] }

      it 'renders it as the one-line notice, not the wrapped body' do
        dir = runner.conversation.dir
        run_turn('What is 2 + 2?')

        restored = PikuriWeb::Transcript.new
        replay_into(restored, dir)

        assert_includes rendered(transcript).map(&:last).join, 'loaded skill: writing-rdoc'
        assert_equal rendered(transcript), rendered(restored)
      end
    end

    it 'round-trips the folder unchanged' do
      dir = runner.conversation.dir
      run_turn('What is 2 + 2?')
      before = (dir / 'history.json').read

      agent.load_history!(Pikuri::Agent::History.load(dir))
      agent.export_history.save(dir)

      assert_equal before, (dir / 'history.json').read
    end
  end

  context '#load_conversation' do
    it 'brings back the transcript and the history of a conversation left behind' do
      first = runner.conversation
      run_turn('What is 2 + 2?')
      was_rendered = transcript.to_a.map { |b| [b.kind, b.html] }
      runner.new_conversation
      run_turn('Hello again')

      saved = conversations.list.find { |c| c.id == first.id }
      assert_equal :loaded, runner.load_conversation(saved)

      assert_equal first.id, runner.conversation.id
      assert_equal was_rendered, transcript.to_a.map { |b| [b.kind, b.html] }
      assert_equal Pikuri::Agent::History.load(first.dir), agent.export_history
    end

    it 'saves the conversation it is leaving' do
      first = runner.conversation
      run_turn('What is 2 + 2?')
      runner.new_conversation
      second = runner.conversation
      run_turn('Hello again')

      runner.load_conversation(conversations.list.find { |c| c.id == first.id })

      assert_equal %w[user assistant], Pikuri::Agent::History.load(second.dir).messages.map(&:role)
    end

    it 'tells every tab to empty before the restored blocks arrive' do
      first = runner.conversation
      run_turn('What is 2 + 2?')
      runner.new_conversation
      queue = broadcaster.subscribe

      runner.load_conversation(conversations.list.find { |c| c.id == first.id })

      events = drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }
      assert_equal 'reset', events.first
      assert_equal 4, events.count('block')
    end

    it 'is a no-op on the conversation already live' do
      run_turn('What is 2 + 2?')
      rendered_before = transcript.to_a.map(&:id)
      saved = conversations.list.find { |c| c.id == runner.conversation.id }

      assert_equal :current, runner.load_conversation(saved)
      assert_equal rendered_before, transcript.to_a.map(&:id)
    end

    it 'leaves the live conversation alone when the stored history is unreadable' do
      first = runner.conversation
      run_turn('What is 2 + 2?')
      runner.new_conversation
      run_turn('Hello again')
      (first.dir / 'history.json').write('{"version": 1, "messages": ')

      saved = conversations.list.find { |c| c.id == first.id }
      log = capture_log { assert_equal :failed, runner.load_conversation(saved) }

      assert_includes log, 'loading conversation'
      assert_equal %w[user assistant], agent.export_history.messages.map(&:role)
      assert_equal :assistant, transcript.to_a.last.kind
    end
  end

  context '#delete_conversation' do
    it 'empties the transcript and takes the folder, when the live one goes' do
      live = runner.conversation
      run_turn('What is 2 + 2?')
      queue = broadcaster.subscribe

      assert_equal :deleted, runner.delete_conversation(live)

      # The reset arrives from the agent's own Event::Reset through the real
      # listener — the same path #new_conversation uses.
      assert_includes drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }, 'reset'
      assert_empty transcript.to_a
      assert_empty agent.export_history.messages
      refute live.dir.exist?
      refute_equal live.id, runner.conversation.id
      assert_empty conversations.list
    end

    it 'removes a stored conversation without touching the live transcript' do
      first = runner.conversation
      run_turn('What is 2 + 2?')
      runner.new_conversation
      run_turn('Hello again')

      assert_equal :deleted, runner.delete_conversation(conversations.find(first.id))

      refute first.dir.exist?
      assert_equal [runner.conversation.id], conversations.list.map(&:id)
      assert_equal %w[user assistant], agent.export_history.messages.map(&:role)
      assert_equal :assistant, transcript.to_a.last.kind
    end

    it 'does not resurrect the folder on the next turn' do
      live = runner.conversation
      run_turn('What is 2 + 2?')
      runner.delete_conversation(live)
      run_turn('Hello again')

      refute live.dir.exist?, 'the turn-end save wrote the deleted conversation back'
      assert_equal [runner.conversation.id], conversations.list.map(&:id)
    end
  end

  it 'saves the next turn into the new conversation, leaving the old alone' do
    first = runner.conversation
    run_turn('What is 2 + 2?')
    runner.new_conversation
    second = runner.conversation
    run_turn('Hello again')

    refute_equal first.dir, second.dir
    assert_equal %w[user assistant], Pikuri::Agent::History.load(second.dir).messages.map(&:role)
    assert_equal 4, Pikuri::Agent::History.load(first.dir).messages.size
  end
end
