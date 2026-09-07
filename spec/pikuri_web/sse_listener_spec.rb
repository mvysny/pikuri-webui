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

  # D_details_per_block. `open` is unconditional because the listener is shared
  # by every tab reading the conversation and cannot know a per-browser
  # preference; transcript.js resolves it.
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

  context 'tool events' do
    it 'renders the call with inspected arguments' do
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: 'calc', arguments: { expr: '1+1' }))
      assert_includes transcript.to_a.fetch(0).html, 'calc(expr=&quot;1+1&quot;)'
    end

    it 'truncates long tool results with a byte-count suffix' do
      listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'x' * 500))
      html = transcript.to_a.fetch(0).html
      assert_includes html, '… (500 bytes total)'
      refute_includes html, 'x' * 300
    end

    # Pikuri::Sanitizer, not just HTML-escaping. A browser honors a bidi
    # override exactly as a terminal does: raw, this path displays as
    # "safeexe.png" while really ending in ".exe" — the whole trick.
    it 'neutralizes a bidi override in a tool argument' do
      listener.on_event(
        Pikuri::Agent::Event::ToolCall.new(name: 'read', arguments: { path: "safe‮gnp.exe" })
      )
      html = transcript.to_a.fetch(0).html
      assert_includes html, 'u{202e}'
      refute_includes html, "‮"
    end

    # The carve-out that does not port: pikuri-tui leaves the verbose argument
    # dump to `inspect`, which escapes ESC (already inert once HTML-escaped)
    # and passes zero-width characters straight through.
    it 'neutralizes a zero-width character inspect would have passed through' do
      listener.on_event(
        Pikuri::Agent::Event::ToolCall.new(name: 'read', arguments: { path: "in​visible" })
      )
      html = transcript.to_a.fetch(0).html
      assert_includes html, 'u{200b}'
      refute_includes html, "​"
    end

    it 'neutralizes the tool name as well as its arguments' do
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(name: "ca‭lc", arguments: {}))
      refute_includes transcript.to_a.fetch(0).html, "‭"
    end

    it 'neutralizes a tool result' do
      listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: "Deleted‮ txet"))
      html = transcript.to_a.fetch(0).html
      assert_includes html, 'u{202e}'
      refute_includes html, "‮"
    end

    it 'leaves ordinary tool output alone' do
      listener.on_event(Pikuri::Agent::Event::ToolResult.new(content: 'Results for rails 8: ok (200)'))
      assert_equal '= Results for rails 8: ok (200)', transcript.to_a.fetch(0).html
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
