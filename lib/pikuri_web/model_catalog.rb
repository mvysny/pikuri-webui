# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  # The connections a conversation can be on — the +[[llm]]+ list turned into
  # transports once, plus the three lookups a picker needs to get back and
  # forth between what the browser says and what +run_loop+ takes:
  #
  #   catalog = ModelCatalog.from_llms(config.llms)
  #   catalog.find('Local Qwen 3.6')&.transport   # a name the browser posted
  #   catalog.resolve(model: m, server: s)        # a pair meta.json saved
  #   catalog.name_for(agent.transport)           # → 'Local Qwen 3.6', for the status bar
  #   catalog.rows                                # what the /model dialog lists
  #
  # {#primary} is what a conversation with no saved connection starts on, and
  # the fallback for one whose saved connection has left the config file.
  #
  # == Identity is the +[model, api_base]+ pair
  #
  # {#name} is the unique key ({Config} enforces it) but is *not* recoverable
  # from a transport, so every transport-side lookup keys on the pair instead —
  # two +[[llm]]+ entries may run one model on two servers, and the model alone
  # would conflate them. Port of pikuri-tui's +Shared::Model::Choice.key+,
  # including {#name_for}'s fall back to the raw model id: a transport minted
  # outside this catalog still renders as something.
  #
  # Immutable.
  class ModelCatalog
    # One connection: the display name, and the transport picking it hands to
    # +Pikuri::Agent#run_loop+'s +transport:+.
    #
    # @!attribute [r] name
    #   @return [String] the +[[llm]]+ entry's unique display name
    # @!attribute [r] transport
    #   @return [Pikuri::Agent::ChatTransport]
    Choice = Data.define(:name, :transport) do
      # @return [Array(String, String)] the +[model, api_base]+ identity pair
      def key = [transport.model, transport.api_base]

      # @return [String] model identifier, as the dialog lists it
      def model = transport.model

      # @return [String] normalized server base (the +/v1+ suffix included),
      #   which is what +meta.json+ stores and {#resolve} matches on
      def server = transport.api_base

      # @return [Integer, nil] explicit cap, or nil where pikuri's +/props+
      #   probe decides
      def context_window = transport.context_window
    end

    # The connection (+api_base+ / +api_key+) rides each transport's own
    # per-chat +RubyLLM::Context+, so nothing here touches a process-global
    # +RubyLLM.configure+ and two conversations on two servers coexist.
    #
    # @param llms [Array<Config::Llm>] every configured connection, in
    #   declaration order — {#primary} is the first
    # @return [ModelCatalog]
    def self.from_llms(llms)
      new(choices: llms.map do |llm|
        key = llm.api_key.to_s.strip
        Choice.new(
          name: llm.name,
          transport: Pikuri::Agent::ChatTransport.from_openai_server(
            server: llm.server,
            model: llm.model,
            api_key: key.empty? ? 'not-needed' : key,
            context_window: llm.context_window
          )
        )
      end)
    end

    # @param choices [Array<Choice>] at least one, names already unique
    def initialize(choices:)
      @choices = choices.freeze
      @by_key = choices.to_h { |choice| [choice.key, choice] }.freeze
      freeze
    end

    # @return [Array<Choice>] every connection, declaration order
    attr_reader :choices

    # @return [Choice] the connection a conversation starts on when it has no
    #   saved one, and where a saved one that has left the config falls back to
    def primary = @choices.first

    # @return [Boolean] whether there is anything to pick between — what the
    #   +/model+ palette entry is gated on
    def multiple? = @choices.size > 1

    # @param name [String] as posted by the browser
    # @return [Choice, nil] nil for a name this config does not have
    def find(name) = @choices.find { |choice| choice.name == name }

    # The connection a saved conversation was on.
    #
    # @param model [String, nil] +meta.json+'s +model+
    # @param server [String, nil] +meta.json+'s +server+
    # @return [Choice, nil] nil when the conversation saved no connection, or
    #   when the one it saved is no longer in the config file
    def resolve(model:, server:) = @by_key[[model, server]]

    # @param transport [Pikuri::Agent::ChatTransport]
    # @return [String] its display name, or the raw model id when the
    #   transport came from outside this catalog
    def name_for(transport)
      @by_key[[transport.model, transport.api_base]]&.name || transport.model.to_s
    end

    # @return [Array<Hash>] +{name:, model:, context_window:}+ per connection —
    #   the Pikuri-free form the +/model+ dialog is rendered from
    def rows
      @choices.map do |choice|
        { name: choice.name, model: choice.model, context_window: choice.context_window }
      end
    end
  end
end
