# frozen_string_literal: true

require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot
require 'tmpdir'

# The whole slice wired as production wires it: a real registry over a real
# factory, real pikuri-conversations over scripted transports, the real
# listener stack, and a real store over a temp directory. What the unit specs
# cannot show is that the events the agent and the gem actually emit drive the
# transcript, the save and the SSE addressing the way the fakes assume.
RSpec.describe 'conversations end to end' do
  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  let(:broadcaster) { PikuriWebUI::Web::Broadcaster.new }
  let(:store) { Pikuri::Conversations::Store.new(root: @root, shell: 'pikuri-webui-chat') }

  # One connection, named after the scripted transport every conversation gets:
  # the catalog keys on [model, api_base], so each factory-built transport
  # resolves to this entry despite carrying its own scripted adapter.
  let(:catalog) do
    PikuriWebUI::Agents::ModelCatalog.new(
      choices: [PikuriWebUI::Agents::ModelCatalog::Choice.new(name: 'fake', transport: Pikuri::Testing.fake_transport)]
    )
  end

  # The public route to a reference block: a String back from on_user_message
  # is what the agent wraps in <system-reminder> and emits as SystemInjected.
  class SkillInjector
    include Pikuri::Agent::Extension

    def on_user_message(_content, _attachments) = '<skill name="writing-rdoc">the whole SKILL.md body</skill>'
  end

  let(:extensions) { [] }
  let(:lock) { PikuriWebUI::BigAppLock.new }

  # Every live list the example built, shut down after it.
  let(:lists) { [] }

  # A live list as the boot script builds one.
  def live_list
    Pikuri::Conversations.new(
      system_prompt: 'test agent',
      configure: lambda { |c, _conversation|
        c.add_tool Pikuri::Tool::CALCULATOR
        extensions.each { |extension| c.add_extension extension.class.new }
      },
      on_turn_end: ->(conversation, history) { conversation.listener.persist(history) }
    ).tap { |list| lists << list }
  end

  # Everything a conversation owns, wired as bin/pikuri-webui-chat wires it,
  # opened on +conversations+.
  def factory_on(conversations)
    lambda do |entry|
      transcript = PikuriWebUI::Web::Transcript.new(lock: lock)
      listener = PikuriWebUI::Web::SseListener.new(
        transcript: transcript, broadcaster: broadcaster, conversation: entry.id, lock: lock
      )
      token_log = Pikuri::Agent::Listener::TokenLog.new
      transport = Pikuri::Testing.fake_transport do |llm|
        llm.tool_call('calculator', expression: '2 + 2')
        llm.reply('The answer is 4.')
        llm.reply('A fresh start.')
      end
      PikuriWebUI::Agents::Runner.new(
        conversation: entry, store: store, catalog: catalog, broadcaster: broadcaster,
        transcript: transcript, listener: listener,
        agent_listeners: [Pikuri::Conversations::RateLimitedListener.new(listener, fps: 15), token_log],
        token_log: token_log, lock: lock
      ).open(conversations, transport: transport)
    end
  end

  def registry_on(conversations)
    guard(PikuriWebUI::Conversations::Registry.new(store: store, factory: factory_on(conversations), lock: lock), lock)
  end

  let(:registry) { registry_on(live_list) }
  let(:runner) { guard(registry.create, lock) }
  let(:transcript) { guard(runner.transcript, lock) }

  after { lists.each { |list| list.shutdown(timeout: 5) } }

  def event_types(frames) = frames.map { |f| f[/event: (\w+)/, 1] }

  # A second live list and registry over the same folder: what a restarted
  # process sees.
  def reopen(id) = guard(registry_on(live_list).open_id(id), lock)

  def send_and_settle(target, message, **)
    target.submit(message, **)
    settle(target, lock)
  end

  it 'renders the turn, then saves exactly what the agent holds' do
    dir = runner.conversation.dir
    send_and_settle(runner, 'What is 2 + 2?')

    assert_equal %i[user tool_call tool_result assistant], transcript.to_a.map(&:kind)

    history = store.history(runner.conversation)
    assert_equal %w[user assistant tool assistant], history.messages.map(&:role)
    assert_equal 'What is 2 + 2?', history.messages.first.content
    meta = JSON.parse((dir / 'meta.json').read)
    assert_equal 1, meta.fetch('schema')
    # The connection comes off the agent's own transport at turn end, which is
    # what keeps it agreeing with history.json's model_id.
    assert_equal ['fake-model', 'http://fake.invalid/v1'], meta.values_at('model', 'server')
  end

  it 'reports the turn on the status bar and goes idle once saved' do
    watching = broadcaster.subscribe(runner.conversation.id)
    send_and_settle(runner, 'What is 2 + 2?')

    frames = drain_frames(watching)
    states = frames.grep(/event: status/).map { |f| JSON.parse(f[/data: (.*)/, 1])['state'] }
    assert_includes states, 'running'
    assert_equal 'idle', states.last
    assert_match(/\Actx \d/, runner.status_data[:tokens])
    refute runner.busy?
  end

  # The property this whole design exists for. Two conversations, two agents,
  # two transcripts: work in one is invisible to the other, and a tab reading
  # the second is never sent the first one's frames.
  context 'two conversations at once' do
    it 'keeps transcripts, histories and SSE frames apart' do
      first = guard(registry.create, lock)
      second = guard(registry.create, lock)
      settle(second, lock)
      watching_second = broadcaster.subscribe(second.conversation.id)

      send_and_settle(first, 'What is 2 + 2?')

      refute_empty(lock.run { first.transcript.to_a })
      assert_empty(lock.run { second.transcript.to_a })
      # Not silence: the sidebar signal is addressed to every tab on purpose,
      # because the first conversation's row now has a dot. What must never
      # arrive is a frame carrying the first conversation's content or status.
      assert_equal ['conversations'], event_types(drain_frames(watching_second)).uniq
      refute (second.conversation.dir / 'history.json').exist?
    end

    it 'leaves each conversation with its own turn state' do
      first = guard(registry.create, lock)
      second = guard(registry.create, lock)

      send_and_settle(first, 'What is 2 + 2?')
      settle(second, lock)

      refute first.busy?
      refute second.busy?
    end
  end

  # What D_replay_from_history rests on: the file holds only messages, and the
  # blocks are re-derived. Reopening is the path a browser takes when it comes
  # back to a conversation after a restart.
  context 'reopening a saved conversation' do
    def rendered(transcript) = lock.run { transcript.to_a.map { |b| [b.kind, b.html] } }

    it 'rebuilds the transcript the live turn produced, block for block' do
      send_and_settle(runner, 'What is 2 + 2?')
      produced = rendered(transcript)

      reopened = reopen(runner.conversation.id)

      assert_equal produced, rendered(reopened.transcript)
    end

    # The whole image path but the browser: stashed, sent, rendered as a strip,
    # saved under the stashed name, and drawn again identically on reopen.
    it 'shows a message\'s images again, from the same files' do
      conversation = runner.conversation
      upload = PikuriWebUI::Conversations::Upload.from(filename: 'shot.png', bytes: "\x89PNG\r\n\x1A\n".b)
      store.stash(conversation, [upload.to_attachment])
      send_and_settle(runner, 'What is 2 + 2?', uploads: [upload])
      produced = rendered(transcript)

      reopened = reopen(conversation.id)

      assert_includes produced.first.last, "/c/#{conversation.id}/attachments/#{upload.stored_name}"
      assert_equal produced, rendered(reopened.transcript)
      assert_equal([upload.stored_name], (conversation.dir / 'attachments').children.map { |c| c.basename.to_s })
    end

    context 'with an extension injecting a reference block' do
      let(:extensions) { [SkillInjector.new] }

      it 'renders it as the one-line notice, not the wrapped body' do
        send_and_settle(runner, 'What is 2 + 2?')
        produced = rendered(transcript)

        reopened = reopen(runner.conversation.id)

        assert_includes produced.map(&:last).join, 'loaded skill: writing-rdoc'
        assert_equal produced, rendered(reopened.transcript)
      end
    end

    it 'restores nothing, quietly, for a conversation never saved' do
      fresh = registry.create
      assert_empty(lock.run { fresh.transcript.to_a })
    end
  end

  context 'deleting' do
    it 'removes the folder and forgets the runner' do
      send_and_settle(runner, 'What is 2 + 2?')
      conversation = runner.conversation

      assert_equal :deleted, registry.delete(conversation)

      refute conversation.dir.exist?
      assert_nil registry.resident(conversation.id)
    end

    it 'answers a stale reference :discarded, and writes nothing back' do
      send_and_settle(runner, 'What is 2 + 2?')
      conversation = runner.conversation
      registry.delete(conversation)

      assert_equal :discarded, runner.submit('and again?')
      refute conversation.dir.exist?
    end
  end
end
