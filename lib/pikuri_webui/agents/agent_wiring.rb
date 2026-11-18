# frozen_string_literal: true

require 'pikuri-conversations'

module PikuriWebUI
  module Agents
    # The one system prompt and tool set every conversation's agent is built
    # with — what pikuri-conversations asks a conversation for when it boots.
    #
    #   wiring = AgentWiring.new(system_prompt: prompt, tools: ->(c) { c.add_tool Pikuri::Tool::CALCULATOR })
    #   runner.open(live, transport:, wiring:)
    #
    # One instance per process: the boot-time trifecta report describes every
    # agent only while they all share it.
    #
    # Immutable.
    class AgentWiring
      include Pikuri::Conversations::AgentInitializer

      # @param system_prompt [String] without the date, which {#system_prompt}
      #   appends
      # @param tools [Proc] +(configurator)+ — the +Agent.new+ block
      def initialize(system_prompt:, tools:)
        @system_prompt = system_prompt
        @tools = tools
        freeze
      end

      # Dated per agent built, not per process: a server left running past
      # midnight would otherwise tell every new conversation yesterday's date.
      #
      # @param _conversation [Pikuri::Conversations::Conversation]
      # @return [String]
      def system_prompt(_conversation) = "#{@system_prompt}\n\nCurrent date: #{Time.now.strftime('%Y-%m-%d')}"

      # @param configurator [Pikuri::Agent::Configurator]
      # @param _conversation [Pikuri::Conversations::Conversation]
      # @return [void]
      def configure(configurator, _conversation)
        @tools.call(configurator)
        nil
      end
    end
  end
end
