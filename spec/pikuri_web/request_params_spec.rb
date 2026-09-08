# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'json'

# Specs for the stopgap that carries an [[llm]]'s `params` table to the
# server. The merge itself is unit-tested against a hand-built Faraday::Env,
# which is what the adapter sees; that the parameter actually reaches a model
# and silences it needs a live server, which is bin/probe-titler's job.
describe PikuriWeb::RequestParams do
  THINKING_OFF = { 'chat_template_kwargs' => { 'enable_thinking' => false } }.freeze

  def env_for(body, path: '/v1/chat/completions')
    Faraday::Env.from(
      method: :post, body: body, url: URI("http://host:8080#{path}"), request_headers: {}
    )
  end

  describe '.adapter_for' do
    it 'builds a net_http adapter subclass for a non-empty table' do
      klass = described_class.adapter_for(THINKING_OFF)
      assert_operator klass, :<, Faraday::Adapter::NetHttp
    end

    it 'returns nil for a connection with no params, leaving pikuri its own default' do
      assert_nil described_class.adapter_for({})
      assert_nil described_class.adapter_for(nil)
    end

    it 'builds a fresh class per connection, so two never share params' do
      refute_equal described_class.adapter_for('a' => 1), described_class.adapter_for('a' => 1)
    end
  end

  describe '.merge_into!' do
    it 'merges the params into a chat-completion body and re-lengths it' do
      env = env_for('{"model":"m","messages":[]}')
      described_class.merge_into!(env, THINKING_OFF)

      body = JSON.parse(env.body)
      assert_equal false, body.dig('chat_template_kwargs', 'enable_thinking')
      assert_equal 'm', body['model']
      assert_equal env.body.bytesize.to_s, env.request_headers['Content-Length']
    end

    it 'wins over a key the provider already set' do
      env = env_for('{"chat_template_kwargs":{"enable_thinking":true}}')
      described_class.merge_into!(env, THINKING_OFF)
      assert_equal false, JSON.parse(env.body).dig('chat_template_kwargs', 'enable_thinking')
    end

    it 'leaves a request that is not a chat completion alone' do
      env = env_for('{"model":"m"}', path: '/props')
      described_class.merge_into!(env, THINKING_OFF)
      assert_equal '{"model":"m"}', env.body
    end

    # The coupling to ruby_llm registering `request :json` before the adapter:
    # if that order ever changes the body arrives unserialized, and the
    # parameter must go unapplied rather than blow up the turn.
    it 'leaves an unserialized body alone' do
      env = env_for({ 'model' => 'm' })
      described_class.merge_into!(env, THINKING_OFF)
      assert_equal({ 'model' => 'm' }, env.body)
    end

    it 'logs and leaves the request unchanged when the body is not JSON' do
      env = env_for('not json at all')
      described_class.merge_into!(env, THINKING_OFF)
      assert_equal 'not json at all', env.body
    end
  end
end
