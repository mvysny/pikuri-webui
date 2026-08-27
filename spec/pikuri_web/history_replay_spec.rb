# frozen_string_literal: true

# The message → event mapping, driven from Histories built in Ruby (the
# constructor is public, so no fixture files). That the mapping matches what a
# live agent actually emits is conversation_flow_spec's job, not this one's.
RSpec.describe PikuriWeb::HistoryReplay do
  def message(role, content = '', **rest)
    Pikuri::Agent::History::Message.new(
      id: Pikuri::Agent::History.mint_id, role: role, content: content, **rest
    )
  end

  def tool_call(id, name, **arguments)
    Pikuri::Agent::History::ToolCall.new(id: id, name: name, arguments: arguments.transform_keys(&:to_s))
  end

  def replay(*messages) = described_class.events(Pikuri::Agent::History.new(messages: messages))

  # Event variants by bare name — the whole assertion is "which events, in
  # which order", and the namespace adds nothing to that.
  def kinds(events) = events.map { |e| e.class.name.split('::').last }

  it 'renders a plain user turn' do
    events = replay(message('user', 'What is 2 + 2?'))
    assert_equal %w[UserTurn], kinds(events)
    assert_equal 'What is 2 + 2?', events.first.content
  end

  it 'renders an assistant answer' do
    events = replay(message('assistant', 'Four.'))
    assert_equal %w[Assistant], kinds(events)
    assert_equal 'Four.', events.first.content
  end

  it 'puts thinking before the answer it preceded' do
    thinking = Pikuri::Agent::History::Thinking.new(text: 'hmm', signature: 'sig')
    events = replay(message('assistant', 'Four.', thinking: thinking))
    assert_equal %w[Thinking Assistant], kinds(events)
    assert_equal 'hmm', events.first.content
  end

  it 'drops empty thinking and empty content, as pikuri does on the way out' do
    thinking = Pikuri::Agent::History::Thinking.new(text: '', signature: nil)
    assert_empty replay(message('assistant', '', thinking: thinking))
  end

  context 'tool batches' do
    let(:call_a) { tool_call('call_1', 'calculator', expression: '2 + 2') }
    let(:call_b) { tool_call('call_2', 'fetch') }

    it 'pairs each call with its own result, in call order' do
      events = replay(
        message('assistant', '', tool_calls: [call_a, call_b]),
        message('tool', '4', tool_call_id: 'call_1'),
        message('tool', 'a page', tool_call_id: 'call_2')
      )

      assert_equal %w[ToolCall ToolResult ToolCall ToolResult], kinds(events)
      assert_equal %w[calculator 4 fetch a\ page],
                   [events[0].name, events[1].content, events[2].name, events[3].content]
    end

    it 'carries the call arguments through' do
      events = replay(message('assistant', '', tool_calls: [call_a]), message('tool', '4', tool_call_id: 'call_1'))
      assert_equal({ 'expression' => '2 + 2' }, events.first.arguments)
    end

    it 'shows the interruption the model is looking at for a call that never returned' do
      events = replay(message('assistant', '', tool_calls: [call_a]))
      assert_equal %w[ToolCall ToolResult], kinds(events)
      assert_equal Pikuri::Agent::History::INTERRUPTED_RESULT, events.last.content
    end
  end

  context 'injected reference blocks' do
    # What Agent#append_reference_block writes into the chat log.
    def wrapped(body) = message('user', "<system-reminder>\n#{body}\n</system-reminder>", kind: 'reference')

    it 'unwraps the envelope pikuri added, since the live event never carried it' do
      events = replay(wrapped('<skill name="writing-rdoc">body</skill>'))
      assert_equal %w[SystemInjected], kinds(events)
      assert_equal '<skill name="writing-rdoc">body</skill>', events.first.content
    end

    it 'restores a closing tag the envelope had to escape' do
      events = replay(wrapped('a nested <\\/system-reminder> inside'))
      assert_equal 'a nested </system-reminder> inside', events.first.content
    end

    it 'passes unenveloped reference text through untouched' do
      events = replay(message('user', 'bare reference', kind: 'reference'))
      assert_equal 'bare reference', events.first.content
    end
  end

  it 'orders a whole conversation the way the agent emitted it' do
    events = replay(
      message('user', 'What is 2 + 2?'),
      message('assistant', '', tool_calls: [tool_call('call_1', 'calculator')]),
      message('tool', '4', tool_call_id: 'call_1'),
      message('assistant', 'Four.')
    )

    assert_equal %w[UserTurn ToolCall ToolResult Assistant], kinds(events)
  end

  it 'synthesizes no Tokens events — HistoryLoaded is what reseeds the readout' do
    tokens = Pikuri::Agent::History::Tokens.new(input: 10, output: 20, cached: 0, cache_creation: 0, thinking: 0)
    assert_equal %w[Assistant], kinds(replay(message('assistant', 'Four.', tokens: tokens)))
  end
end
