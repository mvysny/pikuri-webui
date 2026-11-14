# frozen_string_literal: true

require 'pikuri-core'

module PikuriWebUI
  module Conversations
    # Turns a saved conversation back into the +Pikuri::Agent::Event+ stream that
    # produced it, so a loaded conversation renders through the *same*
    # {Web::SseListener} as a live one:
    #
    #   history = store.history(entry)
    #   HistoryReplay.events(history).each { |e| listener.on_event(e) }
    #   conversations.open(id: entry.id, transport:, listener:, history:)
    #
    # One renderer, one event→block-kind mapping, and old conversations get
    # today's Markdown renderer and today's CSS. A `History → blocks` builder
    # would be a second place block kinds are decided.
    #
    # Server-side of the pikuri seam (+D_pikuri_free_core+): it builds
    # +Pikuri::Agent::Event+s and renders nothing.
    #
    # == What a reload cannot show
    #
    # Only messages are stored, so anything that never became one is gone:
    # +! cancelled+ and run-loop failure blocks, and the partial assistant text a
    # cancel deliberately preserves (it raises out of +Chat#ask+ before the
    # message lands). A reloaded turn that was cancelled mid-answer shows the
    # user's message with no reply under it.
    #
    # == Implementation details
    #
    # Events are synthesized in the order the live agent emits them, which is
    # *not* the order the messages sit in: a batch's +ToolResult+ follows its own
    # +ToolCall+ rather than waiting for the batch to finish (pikuri's
    # +before_tool_call+ / +after_tool_result+ hooks fire per call, while the
    # history stores the whole assistant turn ahead of every +tool+ message).
    #
    # +Tokens+ is deliberately not synthesized: +TokenLog+ is reseeded from the
    # +Event::HistoryLoaded+ +Agent.new(history:)+ emits, and a second source
    # would double-count. Empty thinking and empty assistant content are dropped,
    # matching the filters on pikuri's own emit path — otherwise a pure tool-call
    # turn would replay as a blank assistant block.
    module HistoryReplay
      # pikuri's reference-block envelope, which +Agent#append_reference_block+
      # wraps around injected text on its way into the chat log while emitting
      # the block *unwrapped*. Mirrored here because the constant is private
      # upstream; the live-vs-replay spec in conversation_flow_spec.rb is what
      # catches a rename.
      #
      # @return [String]
      REFERENCE_TAG = 'system-reminder'
      # @return [Regexp]
      REFERENCE_ENVELOPE = %r{\A<#{REFERENCE_TAG}>\n(.*)\n</#{REFERENCE_TAG}>\z}m

      module_function

      # The event stream for one stored conversation.
      #
      #   HistoryReplay.events(history).map(&:class)
      #   # => [Event::UserTurn, Event::ToolCall, Event::ToolResult, Event::Assistant]
      #
      # Dangling tool calls are repaired first, exactly as +Agent.new(history:)+
      # repairs them on the way into the chat — so the transcript shows the
      # +[Tool execution was interrupted]+ observation the model is now looking at,
      # rather than a call with nothing under it.
      #
      # @param history [Pikuri::Agent::History]
      # @return [Array<Data>]
      def events(history)
        messages = history.repair_interrupted_tool_calls.messages
        results = messages.select { |m| m.role == 'tool' }.to_h { |m| [m.tool_call_id, m] }
        messages.flat_map { |message| events_for(message, results) }
      end

      # @param message [Pikuri::Agent::History::Message]
      # @param results [Hash{String => Pikuri::Agent::History::Message}] tool-call
      #   id → the +tool+ message answering it
      # @return [Array<Data>]
      def events_for(message, results)
        case message.role
        when 'user' then [user_event(message)]
        when 'assistant' then assistant_events(message, results)
        # Emitted alongside the call that asked for it.
        else []
        end
      end

      # @param message [Pikuri::Agent::History::Message]
      # @return [Data]
      def user_event(message)
        return Pikuri::Agent::Event::SystemInjected.new(content: unwrap(message.content)) if
          message.kind == 'reference'

        # mid_loop is not stored, and nothing renders it differently: an
        # Interloper injection replays as the plain turn it looked like.
        Pikuri::Agent::Event::UserTurn.new(content: message.content, attachments: message.attachments)
      end

      # The tool that composed a call's display strings is gone by replay time,
      # so they come off the file — or, for a file written before them, off
      # +Pikuri::Tool+'s mechanical defaults.
      #
      # @param message [Pikuri::Agent::History::Message]
      # @param results [Hash{String => Pikuri::Agent::History::Message}]
      # @return [Array<Data>]
      def assistant_events(message, results)
        events = []
        thinking = message.thinking&.text.to_s
        events << Pikuri::Agent::Event::Thinking.new(content: thinking) unless thinking.empty?
        events << Pikuri::Agent::Event::Assistant.new(content: message.content) unless message.content.empty?
        message.tool_calls.each do |call|
          events << Pikuri::Agent::Event::ToolCall.new(
            tool_call_id: call.id, name: call.name, arguments: call.arguments,
            display_name: call.display_name || Pikuri::Tool.display_name_for(call.name),
            argument: call.argument || Pikuri::Tool.describe_arguments(call.arguments)
          )
          result = results[call.id]
          next unless result

          events << Pikuri::Agent::Event::ToolResult.new(
            tool_call_id: call.id, name: call.name, content: result.content,
            summary: result.summary || Pikuri::Tool.describe_content(result.content)
          )
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
end
