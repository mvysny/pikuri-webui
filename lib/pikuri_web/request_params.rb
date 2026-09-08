# frozen_string_literal: true

require 'faraday'
require 'json'

module PikuriWeb
  # One connection's extra request parameters, as the Faraday adapter that
  # merges them into every chat completion sent on it:
  #
  #   adapter = RequestParams.adapter_for(
  #     'chat_template_kwargs' => { 'enable_thinking' => false }
  #   )
  #   transport.with(faraday_adapter: adapter)   # Qwen 3.6 stops thinking
  #
  # How an +[[llm]]+'s +params+ table reaches the server: +ChatTransport+ has
  # no params channel, and +faraday_adapter+ is the generic HTTP seam it does
  # have.
  #
  # == Implementation details
  #
  # A stopgap whose *config spelling* is the part meant to outlive it — when
  # pikuri grows a real +params:+ on +ChatTransport+, +[[llm]] params+ keeps
  # its spelling and this file is deleted.
  #
  # Merging needs the body already serialized, which couples this to ruby_llm
  # registering +faraday.request :json+ *before* the adapter
  # (+RubyLLM::Connection#setup_middleware+). Every way that can rot — a
  # middleware reorder, a body that is no longer JSON, a request that is not a
  # chat completion — leaves the request untouched instead of broken. So the
  # failure mode is always a parameter silently not applied, never a request
  # that fails.
  #
  # The merge is shallow and ours wins: a +params+ table names top-level
  # request keys, so +chat_template_kwargs+ replaces any the provider set
  # rather than merging into it.
  module RequestParams
    # The only request path merged into; a +/props+ probe or a model list on
    # the same connection passes through untouched.
    CHAT_PATH = '/chat/completions'

    # @param params [Hash{String => Object}, nil] the connection's +params+
    #   table.
    # @return [Class, nil] a +Faraday::Adapter::NetHttp+ subclass for
    #   +ChatTransport#faraday_adapter+, or +nil+ when there is nothing to
    #   merge — +nil+ being what leaves pikuri on its own default adapter.
    def self.adapter_for(params)
      return nil if params.nil? || params.empty?

      Class.new(Faraday::Adapter::NetHttp) do
        define_method(:call) do |env|
          RequestParams.merge_into!(env, params)
          super(env)
        end
      end
    end

    # Merge +extra+ into an outgoing serialized request body, in place.
    #
    # Public only because the adapter {.adapter_for} builds calls it from an
    # instance method; nothing else should need it.
    #
    # @param env [Faraday::Env] the outgoing request.
    # @param extra [Hash{String => Object}] parameters to merge in.
    # @return [void]
    def self.merge_into!(env, extra)
      return unless env.body.is_a?(String) && env.url.path.to_s.end_with?(CHAT_PATH)

      env.body = JSON.generate(JSON.parse(env.body).merge(extra))
      env.request_headers['Content-Length'] = env.body.bytesize.to_s
    rescue JSON::ParserError => e
      PikuriWeb.logger.warn("params: request body is not JSON, leaving it unchanged: #{e.message}")
    end
  end
end
