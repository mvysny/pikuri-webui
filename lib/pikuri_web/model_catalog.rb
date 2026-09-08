# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  # The connections a conversation can be on — the +[[llm]]+ list turned into
  # transports once, plus the three lookups a picker needs to get back and
  # forth between what the browser says and what +run_loop+ takes:
  #
  #   catalog = ModelCatalog.from_llms(config.llms)
  #   catalog.find('Local Qwen 3.6')&.transport   # from a name the browser posted
  #   catalog.resolve(model: m, server: s)        # from a pair meta.json saved
  #   catalog.name_for(agent.transport)           # => 'Local Qwen 3.6'
  #   catalog.rows                                # => [{name:, model:, context_window:}, …]
  #
  # == Identity is the +[model, api_base]+ pair
  #
  # {Choice#name} is the unique key ({Config} enforces it) but is *not*
  # recoverable from a transport, so every transport-side lookup keys on the
  # pair instead — two +[[llm]]+ entries may run one model on two servers, and
  # the model alone would conflate them. Port of pikuri-tui's
  # +Shared::Model::Choice.key+, including {#name_for}'s fall back to the raw
  # model id: a transport minted outside this catalog still renders as
  # something.
  #
  # The pair is *not* unique, though the name is: the recommended titler is a
  # second +[[llm]]+ on one model and one server, differing only in +params+.
  # So {#resolve} and {#name_for} answer with the **first** entry declared on
  # a pair, and the rest are shadowed — pickable, listed by {#rows}, and good
  # for the session, but a conversation saved onto one reopens on the winner,
  # because +meta.json+ stores the pair and nothing finer
  # (+D_per_conversation_model+). Boot logs which names that affects.
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

      # @return [String] the model identifier the transport talks to
      def model = transport.model

      # @return [String] normalized server base, +/v1+ suffix included — the
      #   form +meta.json+ stores and {ModelCatalog#resolve} matches on
      def server = transport.api_base

      # @return [Integer, nil] explicit cap, or nil where pikuri's +/props+
      #   probe decides
      def context_window = transport.context_window
    end

    # Each transport carries its own connection, which pikuri turns into a
    # per-chat +RubyLLM::Context+ — so no process-global +RubyLLM.configure+ is
    # involved and two conversations on two servers coexist.
    #
    # Nothing here rations the server: how many requests may fly at one
    # +api_base+ is +Pikuri::Agent::ServerPermits+' business, a registry keyed
    # on the server rather than on anything a transport carries
    # (+D_upstream_request_throttle+).
    #
    # An entry's +params+ rides its transport as a {RequestParams} adapter, so
    # a connection configured non-thinking stays non-thinking wherever its
    # transport travels.
    #
    # @param llms [Array<Config::Llm>] every configured connection, in
    #   declaration order
    # @return [ModelCatalog]
    def self.from_llms(llms)
      new(choices: llms.map do |llm|
        key = llm.api_key.to_s.strip
        transport = Pikuri::Agent::ChatTransport.from_openai_server(
          server: llm.server,
          model: llm.model,
          api_key: key.empty? ? 'not-needed' : key,
          context_window: llm.context_window
        )
        adapter = RequestParams.adapter_for(llm.params)
        transport = transport.with(faraday_adapter: adapter) if adapter
        Choice.new(name: llm.name, transport: transport)
      end)
    end

    # @param choices [Array<Choice>] at least one, names already unique
    def initialize(choices:)
      @choices = choices.freeze
      # First declaration wins the identity pair, where +to_h+ would hand it
      # to the last: the recommended titler is a second entry on the *same*
      # model and server as the conversation model it shadows, so last-wins
      # would silently reopen every saved conversation onto the titler's
      # non-thinking connection. Both stay pickable — only which one owns the
      # pair is decided here.
      @by_key = choices.reverse.to_h { |choice| [choice.key, choice] }.freeze
      warn_shadowed_pairs(choices)
      freeze
    end

    # @return [Array<Choice>] every connection, declaration order
    attr_reader :choices

    # @return [Choice] the first +[[llm]]+ — where a conversation with no
    #   saved connection starts, and what a vanished one falls back to
    def primary = @choices.first

    # @return [Boolean] whether there is more than one connection to pick
    #   between
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

    # @return [Array<Hash>] +{name:, model:, context_window:}+ per connection:
    #   everything a picker displays, and nothing that would carry a
    #   +Pikuri::*+ type across the seam
    def rows
      @choices.map do |choice|
        { name: choice.name, model: choice.model, context_window: choice.context_window }
      end
    end

    private

    # Tell the operator, once at boot, which entries cannot survive a reopen.
    # Two +[[llm]]+ names on one +[model, api_base]+ pair are legal and the
    # titler recipe *is* one, but +meta.json+ stores only the pair — so a
    # conversation picked onto a shadowed entry comes back on the winner.
    #
    # @param choices [Array<Choice>] in declaration order.
    # @return [void]
    def warn_shadowed_pairs(choices)
      choices.group_by(&:key).each_value do |sharing|
        next if sharing.one?

        winner, *shadowed = sharing
        PikuriWeb.logger.info(
          "model catalog: #{shadowed.map { |c| c.name.inspect }.join(', ')} " \
          "share #{winner.model.inspect} on #{winner.server} with #{winner.name.inspect}; " \
          'a conversation picked onto one reopens on the first. Expected for a titler entry.'
        )
      end
    end
  end
end
