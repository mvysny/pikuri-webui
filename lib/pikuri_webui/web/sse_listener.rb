# frozen_string_literal: true

require 'erb'
require 'pikuri-core'
require 'pikuri-conversations'

module PikuriWebUI
  module Web
    # Browser-targeted equivalent of pikuri-tui's TuileListener: renders the
    # normalized event stream into the {Transcript} (the server-side source
    # of truth) and mirrors every mutation to connected browsers through the
    # {Broadcaster} (SSE +block+ / +stream+ / +remove+ events). Part of the Pikuri seam
    # — this class and Agents::Runner are the only lib/ files that know what a
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
    # task during {Agents::Runner#open}'s replay, then the agent's boot and
    # turn threads, which never overlap: the replay finishes before the
    # agent is opened, and a conversation runs one turn at a time. Only
    # agent events reach it; the conversation's own stay with the runner.
    # Per-browser event order comes from each connection's one FIFO queue.
    #
    # Variant coverage mirrors TuileListener:
    #
    # - +UserTurn+ renders as its own block (both the initial turn and
    #   +mid_loop: true+ Interloper injections — the flag isn't
    #   distinguished visually yet), its images as a strip of links under the
    #   text ({#images_html}).
    # - Streaming deltas go through a {StreamingMessage} per turn, which sends
    #   each finished Markdown block once and re-sends only the open tail; the
    #   +Assistant+ / +Thinking+ bookends finalize with the authoritative
    #   content (deltas are preview-only). Reasoning gets the disclosure
    #   {#disclose} wraps it in; the +thinking+ block kind is the CSS hook
    #   that does the TUI's grayscale job.
    # - +ToolCall+ / +ToolResult+ each render as one {ToolLine}, which carries
    #   the short form and the raw one both and leaves CSS to pick
    #   (+D_both_forms_in_the_block+). That class owns the sanitizing and the
    #   escaping those lines need, so nothing here touches them.
    # - +SystemInjected+ (reference text the host injected — a loaded skill,
    #   recalled memory) collapses to a one-line +notice+; see
    #   {#render_system_injection}.
    # - A saved conversation is filled in by {Conversations::HistoryReplay}
    #   replaying through this same listener before its agent boots, so there
    #   is no second renderer for a restored transcript.
    # - +Tokens+ stays silent (TokenLog consumes it; the status bar reads
    #   +TokenLog#status_line+ via Agents::Runner).
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
      # @param event [Data]
      # @return [void]
      def on_event(event)
        case event
        in Pikuri::Agent::Event::UserTurn(content:, attachments:)
          flush_assistant(:wipe)
          release_thinking
          @thinking_streamed = false
          add_block(:user, Util::MarkdownRenderer.escape(content) + images_html(attachments))
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
            add_block(:thinking, Util::MarkdownRenderer.render(content))
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
            add_block(:assistant, Util::MarkdownRenderer.render(content))
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
          add_block(:error, Util::MarkdownRenderer.escape('! cancelled'))
        in Pikuri::Agent::Event::HistoryLoaded
          # Silent on purpose. The {Conversations::HistoryReplay} that preceded it
          # rendered the restored conversation, and a "restored N messages" line
          # would be the only block in the transcript that never came from the agent.
        else
          # Tokens / ModelSwitched: silent here — see the class header for why
          # the last of those draws nothing.
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
        add_block(:notice, Util::MarkdownRenderer.escape("⊕ #{text}"))
      end

      # A user message's images, as the strip CSS lays out under its text:
      #
      #   <div class="attachments"><a href="/c/ID/attachments/3f9a1c8e2b-shot.png" …><img …></a></div>
      #
      # Each one is a URL the server answers from the conversation's folder,
      # never the bytes inline: a snapshot frame goes out whole on every
      # reconnect, and megabytes of base64 in it would go out each time. The
      # link opens the original at full size, with no script involved.
      #
      # No whitespace between the tags, because the +:user+ block is
      # +pre-wrap+ and would show it. A listener with no conversation — one
      # rendering for no tab — has nothing to address a picture by, and draws
      # none.
      #
      # @param attachments [Array<Pikuri::Attachment>] what the model was shown
      # @return [String] the strip's HTML; empty when there is nothing to show
      def images_html(attachments)
        return '' if attachments.empty? || @conversation.nil?

        links = attachments.map do |attachment|
          url = Util::MarkdownRenderer.escape(
            "/c/#{ERB::Util.url_encode(@conversation)}/attachments/#{ERB::Util.url_encode(Pikuri::Conversations::HistoryFile.stored_name(attachment))}"
          )
          name = Util::MarkdownRenderer.escape(Pikuri::Sanitizer.sanitize(attachment.filename.to_s).text)
          %(<a href="#{url}" target="_blank" rel="noopener" title="#{name}">) +
            %(<img src="#{url}" alt="#{name}" loading="lazy" decoding="async"></a>)
        end
        %(<div class="attachments">#{links.join}</div>)
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

      # Wrap a +:thinking+ block in its disclosure ({Disclosure.wrap}, the open
      # form), and pass every other kind through untouched (`D_details_per_block`).
      #
      # @param kind [Symbol] block kind
      # @param html [String] the block's rendered HTML
      # @return [String] +html+, wrapped when it is reasoning
      def disclose(kind, html)
        kind == :thinking ? Disclosure.wrap(html) : html
      end

      # Open a streamed block: an empty transcript block claims the id and
      # the document position; the returned {StreamingMessage} fills it
      # delta by delta.
      #
      # @param kind [Symbol] +:assistant+ or +:thinking+
      # @return [StreamingMessage]
      def open_stream(kind)
        block = @lock.run { @transcript.add(kind: kind, html: '') }
        StreamingMessage.new(id: block.id)
      end

      # Mirror one streamed frame to the store and the browsers: a full frame
      # as a +block+ that replaces the tab's div, a diff as a +stream+ frame
      # that +transcript.js+ applies around the marker (`D_stream_blocks_once`).
      # Store and broadcast share one task, as must be: a diff is not
      # idempotent, so a tab's snapshot has to sit exactly before the first
      # diff it has not yet absorbed.
      #
      # @param kind [Symbol]
      # @param message [StreamingMessage]
      # @param frame [StreamingMessage::Frame, nil] what {StreamingMessage#append}
      #   / +#finalize+ just produced; +nil+ sends nothing
      # @return [void]
      def push_stream(kind, message, frame)
        return unless frame

        html = disclose(kind, frame.html)
        event, data = if frame.full?
                        [:block, { id: message.id, kind: kind, html: html }]
                      else
                        [:stream, { id: message.id, append: frame.append, tail: frame.tail }]
                      end
        @lock.run do
          @transcript.update(message.id, html)
          @broadcaster.broadcast(event: event, data: data, conversation: @conversation)
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
end
