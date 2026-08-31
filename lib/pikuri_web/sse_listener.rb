# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  # Browser-targeted equivalent of pikuri-tui's TuileListener: renders the
  # normalized event stream into the {Transcript} (the server-side source
  # of truth) and mirrors every mutation to connected browsers through the
  # {Broadcaster} (SSE +block+ / +remove+ events). Part of the Pikuri seam
  # — this class and AgentRunner are the only lib/ files that know what a
  # +Pikuri::Agent::Event+ is.
  #
  # Each logical block — user turn, streamed reasoning, streamed assistant
  # answer, tool call, tool result, fallback notice, cancellation marker —
  # lives in its own transcript block, mirroring the TUI's
  # region-per-block model: the "wipe an unfinished preview" path is
  # +Transcript#remove+ plus an SSE +remove+ event, and "preserve the
  # streamed text on cancel" is "just drop the {StreamingMessage} handle."
  #
  # Threading is where this diverges most from the TUI: there is no UI
  # thread to marshal onto. Rendering (kramdown, escaping, the
  # {StreamingMessage} accumulation) runs off-domain, on whichever thread
  # delivers the event; each finished block then enters an {AppMonitor}
  # task that stores it and broadcasts it as one unit, so a tab's snapshot
  # and its SSE stream can never disagree about a block. The streaming
  # handles (+@assistant+ / +@thinking+) stay off-domain and unguarded:
  # this class is confined to one event producer at a time — the minting
  # task during {AgentRunner#restore!}'s replay, the turn worker
  # thereafter, which never overlap because the registry publishes the
  # runner only after the replay and a conversation admits one turn at a
  # time. Per-browser event order comes from each connection's one FIFO
  # queue.
  #
  # Variant coverage mirrors TuileListener:
  #
  # - +UserTurn+ renders as its own block (both the initial turn and
  #   +mid_loop: true+ Interloper injections — the flag isn't
  #   distinguished visually yet).
  # - Streaming deltas go through a {StreamingMessage} per turn; the
  #   +Assistant+ / +Thinking+ bookends finalize with the authoritative
  #   content (deltas are preview-only). Thinking gets no special
  #   renderer — the +thinking+ block kind is the CSS hook that does the
  #   TUI's grayscale job.
  # - +SystemInjected+ (reference text the host injected — a loaded skill,
  #   recalled memory) collapses to a one-line +notice+; see
  #   {#render_system_injection}.
  # - +Reset+ empties the transcript and pushes one +reset+ SSE event, so
  #   every open tab drops its blocks without a page reload (and without
  #   losing a half-typed message). Loading a saved conversation rides the
  #   same arm: +Agent#load_history!+ resets first, and {HistoryReplay}
  #   then refills the transcript through this listener — which is why
  #   there is no second transcript to swap in.
  # - +Tokens+ / +ContextCap+ stay silent (TokenLog consumes them; the
  #   status bar reads +TokenLog#status_line+ via AgentRunner).
  # - +ModelSwitched+ stays silent too, and that is a decision rather than
  #   an omission: the status bar carries the model, read off the agent's
  #   own transport. A transcript block for it would need a second producer
  #   on the replay path — +History::Message+ does record +model_id+ — and
  #   two derivations of one block disagree eventually.
  class SseListener < Pikuri::Agent::Listener::Base
    # Cap, in characters, applied to tool-result content before it lands
    # in the transcript. Mirrors the TUI / terminal listeners' cap so the
    # renderers stay visually consistent.
    MAX_TOOL_RESULT_CHARS = 200

    # @param transcript [Transcript] this conversation's block store
    # @param broadcaster [Broadcaster] SSE fan-out to connected browsers
    # @param conversation [String, nil] id every frame is addressed to, so it
    #   reaches only the tabs showing this conversation. +nil+ broadcasts to
    #   everyone, which is what a throwaway listener rendering a snapshot
    #   wants — it has no subscribers at all
    # @param monitor [AppMonitor] the domain each store-and-broadcast enters
    def initialize(transcript:, broadcaster:, monitor:, conversation: nil)
      super()
      @transcript = transcript
      @broadcaster = broadcaster
      @monitor = monitor
      @conversation = conversation
      @assistant = nil
      @thinking = nil
      @thinking_streamed = false
    end

    # Dispatches one event into the transcript + SSE stream. Called from
    # the agent's worker thread; see the class docs for why no marshaling
    # is needed.
    #
    # @param event [Pikuri::Agent::Event::Base]
    # @return [void]
    def on_event(event)
      case event
      in Pikuri::Agent::Event::UserTurn(content:)
        flush_assistant(:wipe)
        release_thinking
        @thinking_streamed = false
        add_block(:user, MarkdownRenderer.escape(content))
      in Pikuri::Agent::Event::ThinkingDelta(content:)
        flush_assistant(:wipe)
        @thinking ||= open_stream(:thinking)
        push_stream(:thinking, @thinking, @thinking.append(content))
        @thinking_streamed = true
      in Pikuri::Agent::Event::Thinking(content:)
        if @thinking
          push_stream(:thinking, @thinking, @thinking.finalize(content))
          release_thinking
        elsif !@thinking_streamed
          add_block(:thinking, MarkdownRenderer.render(content))
        end
        @thinking_streamed = false
      in Pikuri::Agent::Event::AssistantDelta(content:)
        release_thinking
        @assistant ||= open_stream(:assistant)
        push_stream(:assistant, @assistant, @assistant.append(content))
      in Pikuri::Agent::Event::Assistant(content:)
        release_thinking
        if @assistant
          push_stream(:assistant, @assistant, @assistant.finalize(content))
          @assistant = nil
        else
          add_block(:assistant, MarkdownRenderer.render(content))
        end
      in Pikuri::Agent::Event::ToolCall(name:, arguments:)
        flush_assistant(:wipe)
        release_thinking
        args = arguments.map { |k, v| "#{k}=#{v.inspect}" }.join(', ')
        add_block(:tool_call, MarkdownRenderer.escape("→ #{name}(#{args})"))
      in Pikuri::Agent::Event::ToolResult(content:)
        flush_assistant(:wipe)
        release_thinking
        add_block(:tool_result, MarkdownRenderer.escape("= #{truncate_tool_result(content)}"))
      in Pikuri::Agent::Event::SystemInjected(content:)
        flush_assistant(:wipe)
        release_thinking
        render_system_injection(content)
      in Pikuri::Agent::Event::FallbackNotice(reason:)
        flush_assistant(:wipe)
        release_thinking
        add_block(:notice, MarkdownRenderer.escape("! #{reason}"))
      in Pikuri::Agent::Event::Cancelled
        flush_assistant(:preserve)
        release_thinking
        add_block(:error, MarkdownRenderer.escape('! cancelled'))
      in Pikuri::Agent::Event::Reset
        reset_transcript
      in Pikuri::Agent::Event::HistoryLoaded
        # Silent on purpose. The {HistoryReplay} that follows renders the
        # restored conversation itself, and a "restored N messages" line would
        # be the only block in the transcript that never came from the agent.
      else
        # Tokens / ContextCap / ModelSwitched: silent here — see the class
        # header for why the last of those draws nothing.
      end
    end

    # @return [String] short label used by +Pikuri::Agent#to_s+ when this
    #   listener is in its +ListenerList+.
    def to_s = 'SseListener'

    private

    # Render an injected reference block as a one-line +notice+, collapsing
    # the two skill-shaped payloads:
    #
    #   ⊕ loaded skill: writing-rdoc   # was a whole SKILL.md body
    #                                  # a promotion block renders nothing
    #
    # Both are XML-wrapped and sized for the model; pasting either verbatim
    # buries the transcript under a screenful nobody asked for. A promotion
    # is dropped rather than summarized because the host that promoted it
    # announces its own line.
    #
    # @param content [String] the unwrapped reference block
    # @return [void]
    def render_system_injection(content)
      return if content.include?('<available_skills>')

      name = content[/\A<skill name="([^"]*)"/, 1]
      text = name ? "loaded skill: #{name}" : content
      add_block(:notice, MarkdownRenderer.escape("⊕ #{text}"))
    end

    # Empty the transcript and tell every browser to do the same.
    #
    # Streaming handles are dropped rather than flushed: the blocks they point
    # at go with everything else a line later, so +flush_assistant+ would
    # broadcast a +remove+ for an id every tab is about to forget anyway.
    #
    # @return [void]
    def reset_transcript
      @assistant = nil
      @thinking = nil
      @thinking_streamed = false
      @monitor.run do
        @transcript.clear
        @broadcaster.broadcast(event: :reset, data: {}, conversation: @conversation)
      end
    end

    # Append one finished block: store it and announce it.
    #
    # @param kind [Symbol] block kind (CSS hook)
    # @param html [String] rendered/escaped HTML
    # @return [void]
    def add_block(kind, html)
      @monitor.run do
        block = @transcript.add(kind: kind, html: html)
        @broadcaster.broadcast(event: :block, data: { id: block.id, kind: kind, html: html },
                               conversation: @conversation)
      end
    end

    # Open a streamed block: an empty transcript block claims the id and
    # the document position; the returned {StreamingMessage} rewrites it
    # on every delta.
    #
    # @param kind [Symbol] +:assistant+ or +:thinking+
    # @return [StreamingMessage]
    def open_stream(kind)
      block = @monitor.run { @transcript.add(kind: kind, html: '') }
      StreamingMessage.new(id: block.id, render: MarkdownRenderer.method(:render))
    end

    # Mirror a streamed re-render to the store and the browsers.
    #
    # @param kind [Symbol]
    # @param message [StreamingMessage]
    # @param html [String] the render {StreamingMessage#append} /
    #   +#finalize+ just produced (returned rather than re-read so the
    #   no-op append path can't race)
    # @return [void]
    def push_stream(kind, message, html)
      @monitor.run do
        @transcript.update(message.id, html)
        @broadcaster.broadcast(event: :block, data: { id: message.id, kind: kind, html: html },
                               conversation: @conversation)
      end
    end

    # Close out the assistant streaming message.
    #
    # +:wipe+ removes the streamed block entirely (a +ToolCall+ /
    # +UserTurn+ / etc. arrived mid-stream and the preview is no longer
    # what the user should see). +:preserve+ just drops the handle — the
    # block keeps its rendered content (the cancel-preserve case).
    #
    # @param mode [:wipe, :preserve]
    # @return [void]
    def flush_assistant(mode)
      return unless @assistant

      case mode
      when :wipe
        @monitor.run do
          @transcript.remove(@assistant.id)
          @broadcaster.broadcast(event: :remove, data: { id: @assistant.id }, conversation: @conversation)
        end
      when :preserve
        # Block keeps its content; drop the handle below.
      else
        raise ArgumentError, "expected :wipe or :preserve, got #{mode.inspect}"
      end
      @assistant = nil
    end

    # Drop the thinking handle. The block stays in the transcript with
    # its rendered content — bookkeeping only, so the next ThinkingDelta
    # in a later step opens a fresh block rather than extending this one.
    # @return [void]
    def release_thinking
      @thinking = nil
    end

    # Flatten whitespace and cap to {MAX_TOOL_RESULT_CHARS}. Long results
    # (rendered HTML, PDF text) would otherwise drown the transcript; the
    # byte-count suffix distinguishes "tool returned exactly this" from
    # "tool returned much more."
    #
    # @param content [String] tool observation
    # @return [String] single-line display form, possibly truncated
    def truncate_tool_result(content)
      original_bytes = content.to_s.bytesize
      flattened = content.to_s.gsub(/\s+/, ' ').strip
      return flattened if flattened.length <= MAX_TOOL_RESULT_CHARS

      "#{flattened[0, MAX_TOOL_RESULT_CHARS]}… (#{original_bytes} bytes total)"
    end
  end
end
