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
  # answer, tool call, tool result, injected reference, cancellation marker —
  # lives in its own transcript block, mirroring the TUI's
  # region-per-block model: the "wipe an unfinished preview" path is
  # +Transcript#remove+ plus an SSE +remove+ event, and "preserve the
  # streamed text on cancel" is "just drop the {StreamingMessage} handle."
  #
  # Threading is where this diverges most from the TUI: there is no UI
  # thread to marshal onto. Rendering (kramdown, escaping, the
  # {StreamingMessage} accumulation) runs off-domain, on whichever thread
  # delivers the event; each finished block then enters a {BigAppLock}
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
  #   content (deltas are preview-only). Reasoning gets the disclosure
  #   {#disclose} wraps it in; the +thinking+ block kind is the CSS hook
  #   that does the TUI's grayscale job.
  # - +ToolCall+ / +ToolResult+ each render as one {ToolLine}, which carries
  #   the short form and the raw one both and leaves CSS to pick
  #   (+D_both_forms_in_the_block+). Both halves of each event go over —
  #   the tool's own display strings for the short line, the raw name /
  #   arguments / observation for the verbose one. That class owns the
  #   sanitizing and the escaping those lines need, so nothing here touches
  #   them.
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
    # @param transcript [Transcript] this conversation's block store
    # @param broadcaster [Broadcaster] SSE fan-out to connected browsers
    # @param conversation [String, nil] id every frame is addressed to, so it
    #   reaches only the tabs showing this conversation. +nil+ broadcasts to
    #   everyone, which is what a throwaway listener rendering a snapshot
    #   wants — it has no subscribers at all
    # @param lock [BigAppLock] the domain each store-and-broadcast enters
    def initialize(transcript:, broadcaster:, lock:, conversation: nil)
      super()
      @transcript = transcript
      @broadcaster = broadcaster
      @lock = lock
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
      in Pikuri::Agent::Event::ToolCall(name:, arguments:, display_name:, argument:)
        flush_assistant(:wipe)
        release_thinking
        add_block(:tool_call, ToolLine.for_call(name: name, arguments: arguments,
                                                display_name: display_name, argument: argument).to_html)
      in Pikuri::Agent::Event::ToolResult(content:, summary:)
        flush_assistant(:wipe)
        release_thinking
        add_block(:tool_result, ToolLine.for_result(content: content, summary: summary).to_html)
      in Pikuri::Agent::Event::SystemInjected(content:)
        flush_assistant(:wipe)
        release_thinking
        render_system_injection(content)
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
      @lock.run do
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
      html = disclose(kind, html)
      @lock.run do
        block = @transcript.add(kind: kind, html: html)
        @broadcaster.broadcast(event: :block, data: { id: block.id, kind: kind, html: html },
                               conversation: @conversation)
      end
    end

    # Wrap a +:thinking+ block in the disclosure the browser collapses, and
    # pass every other kind through untouched (`D_details_per_block`):
    #
    #   disclose(:thinking, "<p>The user wants…</p>")
    #   # => "<details open><summary>thinking</summary><p>The user wants…</p></details>"
    #
    # +open+ is unconditional, and cannot become the preference: this listener
    # is per-conversation and shared by every tab reading it, while collapsing
    # is per-browser. It renders the pre-JS state, +transcript.js+ resolves it
    # per tab — expanded, so the default configuration never flashes and a
    # browser running no script still shows everything.
    #
    # @param kind [Symbol] block kind
    # @param html [String] the block's rendered HTML
    # @return [String] +html+, wrapped when it is reasoning
    def disclose(kind, html)
      return html unless kind == :thinking

      "<details open><summary>thinking</summary>#{html}</details>"
    end

    # Open a streamed block: an empty transcript block claims the id and
    # the document position; the returned {StreamingMessage} rewrites it
    # on every delta.
    #
    # @param kind [Symbol] +:assistant+ or +:thinking+
    # @return [StreamingMessage]
    def open_stream(kind)
      block = @lock.run { @transcript.add(kind: kind, html: '') }
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
      html = disclose(kind, html)
      @lock.run do
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
        @lock.run do
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

  end
end
