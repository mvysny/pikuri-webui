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
      c.add_listener PikuriWeb::SseListener.new(transcript: transcript, broadcaster: broadcaster)
      c.add_tool Pikuri::Tool::CALCULATOR
    end
  end

  let(:runner) do
    PikuriWeb::AgentRunner.new(
      agent: agent, interloper: interloper, cancellable: cancellable,
      broadcaster: broadcaster, conversations: conversations
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
