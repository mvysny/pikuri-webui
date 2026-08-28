# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  # Turns a saved conversation back into the +Pikuri::Agent::Event+ stream that
  # produced it, so a loaded conversation renders through the *same*
  # {SseListener} as a live one:
  #
  #   history = Pikuri::Agent::History.load(dir)
  #   agent.load_history!(history)                      # Reset empties the transcript
  #   HistoryReplay.events(history).each { |e| listener.on_event(e) }
  #
  # One renderer, one event→block-kind mapping, and old conversations get
  # today's Markdown renderer and today's CSS. A `History → blocks` builder
  # would be a second place block kinds are decided.
  #
  # Part of the Pikuri seam: this file, {SseListener} and {AgentRunner} are the
  # only lib/ files that know what a +Pikuri::Agent::Event+ is.
  #
  # == What a reload cannot show
  #
  # Only messages are stored, so anything that never became one is gone:
  # +! cancelled+ and run-loop failure blocks, +FallbackNotice+ lines, and the
  # partial assistant text a cancel deliberately preserves (it raises out of
  # +Chat#ask+ before the message lands). A reloaded turn that was cancelled
  # mid-answer shows the user's message with no reply under it.
  #
  # == Implementation details
  #
  # Events are synthesized in the order the live agent emits them, which is
  # *not* the order the messages sit in: a batch's +ToolResult+ follows its own
  # +ToolCall+ rather than waiting for the batch to finish (pikuri's
  # +before_tool_call+ / +after_tool_result+ hooks fire per call, while the
  # history stores the whole assistant turn ahead of every +tool+ message).
  #
  # +Tokens+ is deliberately not synthesized: +TokenLog+ is reseeded from
  # +Event::HistoryLoaded+ by +Agent#load_history!+ itself, and a second source
  # would double-count. Empty thinking and empty assistant content are dropped,
  # matching the filters on pikuri's own emit path — otherwise a pure tool-call
  # turn would replay as a blank assistant block.
  module HistoryReplay
    # pikuri's reference-block envelope, which +Agent#append_reference_block+
    # wraps around injected text on its way into the chat log while emitting
    # the block *unwrapped*. Mirrored here because the constant is private
    # upstream; the live-vs-replay spec in conversation_flow_spec.rb is what
    # catches a rename.
    REFERENCE_TAG = 'system-reminder'
    REFERENCE_ENVELOPE = %r{\A<#{REFERENCE_TAG}>\n(.*)\n</#{REFERENCE_TAG}>\z}m

    module_function

    # The event stream for one stored conversation.
    #
    #   HistoryReplay.events(history).map(&:class)
    #   # => [Event::UserTurn, Event::ToolCall, Event::ToolResult, Event::Assistant]
    #
    # Dangling tool calls are repaired first, exactly as +Agent#load_history!+
    # repairs them on the way into the chat — so the transcript shows the
    # +[Tool execution was interrupted]+ observation the model is now looking at,
    # rather than a call with nothing under it.
    #
    # @param history [Pikuri::Agent::History]
    # @return [Array<Pikuri::Agent::Event::Base>]
    def events(history)
      messages = history.repair_interrupted_tool_calls.messages
      results = messages.select { |m| m.role == 'tool' }.to_h { |m| [m.tool_call_id, m.content] }
      messages.flat_map { |message| events_for(message, results) }
    end

    # Render a stored conversation's blocks without disturbing the live one —
    # what a tab viewing a conversation the agent is *not* on gets:
    #
    #   blocks = HistoryReplay.snapshot(conversation.dir)   # => [Block, …] or nil
    #
    # Still one renderer: this replays {events} through a throwaway
    # {SseListener} over a throwaway {Transcript}, so it is the same event →
    # block-kind mapping a live turn goes through. The throwaway {Broadcaster}
    # is what keeps it silent — it has no subscribers, so the replay's frames
    # fan out to nobody instead of redrawing every open tab.
    #
    # Recomputed per request rather than cached: kramdown over a few dozen
    # messages is milliseconds, and a cache would be the second copy of the
    # transcript that `D_replay_from_history` exists to avoid. Holding these
    # resident is `ideas/per-conversation-agents.md` stage 2.
    #
    # @param dir [Pathname] a conversation folder
    # @return [Array<Transcript::Block>, nil] nil when the history cannot be
    #   read — a corrupt or half-written save is the caller's to render as
    #   unavailable, not to crash on
    def snapshot(dir)
      history = Pikuri::Agent::History.load(dir)
      transcript = Transcript.new
      listener = SseListener.new(transcript: transcript, broadcaster: Broadcaster.new)
      events(history).each { |event| listener.on_event(event) }
      transcript.to_a
    rescue Pikuri::Agent::History::Error, SystemCallError => e
      PikuriWeb.logger.error("previewing conversation at #{dir} failed (#{e.class}: #{e.message})")
      nil
    end

    # @param message [Pikuri::Agent::History::Message]
    # @param results [Hash{String => String}] tool-call id → observation
    # @return [Array<Pikuri::Agent::Event::Base>]
    def events_for(message, results)
      case message.role
      when 'user' then [user_event(message)]
      when 'assistant' then assistant_events(message, results)
      # Emitted alongside the call that asked for it.
      else []
      end
    end

    # @param message [Pikuri::Agent::History::Message]
    # @return [Pikuri::Agent::Event::Base]
    def user_event(message)
      return Pikuri::Agent::Event::SystemInjected.new(content: unwrap(message.content)) if
        message.kind == 'reference'

      # mid_loop is not stored, and nothing renders it differently: an
      # Interloper injection replays as the plain turn it looked like.
      Pikuri::Agent::Event::UserTurn.new(content: message.content)
    end

    # @param message [Pikuri::Agent::History::Message]
    # @param results [Hash{String => String}]
    # @return [Array<Pikuri::Agent::Event::Base>]
    def assistant_events(message, results)
      events = []
      thinking = message.thinking&.text.to_s
      events << Pikuri::Agent::Event::Thinking.new(content: thinking) unless thinking.empty?
      events << Pikuri::Agent::Event::Assistant.new(content: message.content) unless message.content.empty?
      message.tool_calls.each do |call|
        events << Pikuri::Agent::Event::ToolCall.new(name: call.name, arguments: call.arguments)
        result = results[call.id]
        events << Pikuri::Agent::Event::ToolResult.new(content: result) if result
      end
      events
    end

    # Strip the envelope pikuri added, and undo the escaping it applied to a
    # closing tag inside the block. Content that is not enveloped is passed
    # through untouched — a history written before the wrapper existed, or by
    # something else entirely, still renders.
    #
    # @param content [String] a +kind: "reference"+ message as stored
    # @return [String] the block as the live +SystemInjected+ carried it
    def unwrap(content)
      body = REFERENCE_ENVELOPE.match(content)
      return content if body.nil?

      body[1].gsub("<\\/#{REFERENCE_TAG}>", "</#{REFERENCE_TAG}>")
    end

    private_class_method :events_for, :user_event, :assistant_events, :unwrap
  end
end
