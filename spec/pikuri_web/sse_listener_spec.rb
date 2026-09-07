# frozen_string_literal: true

# Exercises the listener through real Pikuri::Agent::Event variants
# against a real Transcript + Broadcaster — the same surface the agent's
# worker thread drives in production.
RSpec.describe PikuriWeb::SseListener do
  let(:lock) { PikuriWeb::BigAppLock.new }
  # Guarded proxy on both sides: the listener's own tasks re-enter it, and the
  # spec's direct assertions read through it.
  let(:transcript) { guard(PikuriWeb::Transcript.new(lock: lock), lock) }
  let(:broadcaster) { PikuriWeb::Broadcaster.new }
  let(:listener) do
    described_class.new(transcript: transcript, broadcaster: broadcaster, conversation: 'c-1',
                        lock: lock)
  end
  let(:queue) { broadcaster.subscribe('c-1') }

  def event_types(frames)
    frames.map { |f| f[/event: (\w+)/, 1] }
  end

  context 'UserTurn' do
    it 'adds an escaped user block' do
      listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'a <b> & c', mid_loop: false))
      block = transcript.to_a.fetch(0)
      assert_equal :user, block.kind
      assert_equal 'a &lt;b&gt; &amp; c', block.html
    end

    it 'broadcasts the block' do
      queue # subscribe before the event
      listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'hi', mid_loop: false))
      assert_equal %w[block], event_types(drain_frames(queue))
    end
  end

  context 'assistant streaming' do
    it 'opens one block on the first delta and rewrites it on each delta' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'Hello '))
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: '**world**'))
      blocks = transcript.to_a
      assert_equal 1, blocks.size
      assert_equal :assistant, blocks.fetch(0).kind
      assert_includes blocks.fetch(0).html, '<strong>world</strong>'
    end

    # Promoted from the seam audit (PROBE 2): deltas re-send the whole
    # accumulated source under one id (`D_rerender_and_replace`), so a tab
    # that missed deltas 1..n is correct again on n+1.
    it 'lets a late subscriber catch up from the next delta alone' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'Hel'))
      late = broadcaster.subscribe('c-1')
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'lo'))

      frames = drain_frames(late)
      assert_equal 1, frames.size
      assert_includes frames.first, 'Hello'
    end

    it 'finalizes with the authoritative bookend content' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'Helo wrold'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'Hello world'))
      assert_includes transcript.to_a.fetch(0).html, 'Hello world'
    end

    it 'renders a non-streamed Assistant bookend directly' do
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: '# Title'))
      assert_includes transcript.to_a.fetch(0).html, '<h1'
    end

    it 'starts a fresh block for the next streamed turn' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'one'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'one'))
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'two'))
      assert_equal 2, transcript.to_a.size
    end
  end

  context 'thinking streaming' do
    it 'renders deltas into a thinking block, finalized by the bookend' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'pondering'))
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'pondering hard'))
      block = transcript.to_a.fetch(0)
      assert_equal :thinking, block.kind
      assert_includes block.html, 'pondering hard'
    end

    it 'renders a non-streamed Thinking bookend directly' do
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'hmm'))
      assert_equal :thinking, transcript.to_a.fetch(0).kind
    end

    it 'does not render the bookend twice after a streamed turn' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'x'))
      # A ToolCall between deltas and bookend drops the thinking handle…
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'calc', arguments: {}))
      # …so the bookend must not re-add the already-streamed content.
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'x'))
      thinking_blocks = transcript.to_a.select { |b| b.kind == :thinking }
      assert_equal 1, thinking_blocks.size
    end
  end

  # D_details_per_block. What is pinned here is the markup; the `open` in it is
  # the pre-JS state, and resolving it per tab is transcript.js's.
  context 'reasoning disclosure' do
    it 'wraps a non-streamed thinking block in an open disclosure' do
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'I should read the config.'))
      html = transcript.to_a.fetch(0).html
      assert_includes html, '<details open><summary>thinking</summary>'
      assert_includes html, 'I should read the config.'
    end

    # The common path: the bookend finalizes a stream rather than standing
    # alone, and it goes through push_stream instead of add_block.
    it 'wraps a streamed thinking block on every delta and on the bookend' do
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'Two '))
      assert_includes transcript.to_a.fetch(0).html, '<summary>thinking</summary>'

      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'Two entries.'))
      html = transcript.to_a.fetch(0).html
      assert_includes html, '<details open><summary>thinking</summary>'
      assert_includes html, 'Two entries.'
    end

    # A notice behind a triangle is a notice nobody reads, so :thinking is the
    # only kind that gets one.
    it 'wraps no other kind' do
      listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'hi', mid_loop: false))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'Two.'))
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'read', arguments: { path: 'x' }))
      listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'ok'))
      listener.on_event(Pikuri::Agent::Event::FallbackNotice.new(reason: 'retrying'))
      listener.on_event(Pikuri::Agent::Event::Cancelled.new)

      transcript.to_a.each { |block| refute_includes block.html, '<details' }
    end

    it 'sends the disclosure over SSE, not only into the transcript' do
      queue # subscribe before the event
      listener.on_event(Pikuri::Agent::Event::Thinking.new(content: 'hm'))
      assert_includes drain_frames(queue).join, '<summary>thinking</summary>'
    end
  end

  context 'mid-stream interruptions' do
    it 'wipes an unfinished assistant preview when a ToolCall arrives' do
      queue # subscribe before the events
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'partial'))
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'web_search', arguments: { query: 'x' }))
      kinds = transcript.to_a.map(&:kind)
      assert_equal [:tool_call], kinds
      assert_includes event_types(drain_frames(queue)), 'remove'
    end

    it 'preserves the streamed preview on Cancelled' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'partial answer'))
      listener.on_event(Pikuri::Agent::Event::Cancelled.new)
      kinds = transcript.to_a.map(&:kind)
      assert_equal %i[assistant error], kinds
      assert_includes transcript.to_a.fetch(0).html, 'partial answer'
    end
  end

  # What the lines *say* is ToolLine's, and specced there. What is left here
  # is the wiring: one block per event, of the right kind, carrying both forms
  # — a listener that rendered only the current one would put a display
  # preference in server state.
  context 'tool events' do
    it 'puts both forms of a call in one tool_call block' do
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'calc', arguments: { expr: '1+1' }))
      block = transcript.to_a.fetch(0)
      assert_equal :tool_call, block.kind
      assert_includes block.html, '<span class="tool-short">Calc(1+1)</span>'
      assert_includes block.html, 'calc(expr=&quot;1+1&quot;)</span>'
    end

    it 'puts both forms of a result in one tool_result block' do
      listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'x' * 500))
      block = transcript.to_a.fetch(0)
      assert_equal :tool_result, block.kind
      assert_includes block.html, '<span class="tool-short">OK, 500 B</span>'
      assert_includes block.html, '… (500 bytes total)</span>'
    end

    # The sanitizing lives in ToolLine and is specced there; this asserts only
    # that the listener goes through it rather than escaping on its own.
    it 'reaches the transcript sanitized, not merely escaped' do
      listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: "Deleted‮ txet"))
      html = transcript.to_a.fetch(0).html
      assert_includes html, 'u{202e}'
      refute_includes html, "‮"
    end
  end

  context 'SystemInjected' do
    it 'collapses a skill body to its name' do
      listener.on_event(
        Pikuri::Agent::Event::SystemInjected.new(
          content: %(<skill name="writing-rdoc">\nthe whole SKILL.md body\n</skill>)
        )
      )
      block = transcript.to_a.fetch(0)
      assert_equal :notice, block.kind
      assert_equal '⊕ loaded skill: writing-rdoc', block.html
      refute_includes block.html, 'SKILL.md body'
    end

    it 'renders a non-skill reference block verbatim' do
      listener.on_event(Pikuri::Agent::Event::SystemInjected.new(content: 'recalled: <x>'))
      assert_equal '⊕ recalled: &lt;x&gt;', transcript.to_a.fetch(0).html
    end

    it 'drops a path-activation promotion, which the host announces itself' do
      listener.on_event(
        Pikuri::Agent::Event::SystemInjected.new(content: '<available_skills>…</available_skills>')
      )
      assert_empty transcript.to_a
    end
  end

  context 'Reset' do
    it 'empties the transcript and broadcasts one reset frame' do
      listener.on_event(Pikuri::Agent::Event::UserTurn.new(content: 'hi', mid_loop: false))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'hello'))
      queue # subscribe after the conversation, before the reset

      listener.on_event(Pikuri::Agent::Event::Reset.new)

      assert_empty transcript.to_a
      assert_equal %w[reset], event_types(drain_frames(queue))
    end

    it 'drops an open streaming handle instead of wiping its removed block' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'partial'))
      listener.on_event(Pikuri::Agent::Event::Reset.new)
      queue # subscribe after the reset

      # A retained handle would make this delta rewrite a block nothing has.
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'fresh'))

      assert_equal 1, transcript.to_a.size
      assert_equal %w[block], event_types(drain_frames(queue))
    end
  end

  context 'silent events' do
    it 'ignores Tokens' do
      listener.on_event(
        Pikuri::Agent::Event::Tokens.new(
          input: 1, output: 2, cached: 0, cache_creation: 0, thinking: 0, model_id: 'm'
        )
      )
      assert_empty transcript.to_a
    end
  end
end
