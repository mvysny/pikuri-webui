# frozen_string_literal: true

# Exercises the two directions a picker needs: a browser-facing name into a
# transport, and a transport back into a name. Both are keyed on the
# +[model, api_base]+ pair, which is the whole reason this class exists rather
# than a Hash.
RSpec.describe PikuriWeb::ModelCatalog do
  def llm(name, server:, model: 'qwen3.6', api_key: nil, context_window: nil)
    PikuriWeb::Config::Llm.new(name: name, server: server, model: model,
                               api_key: api_key, context_window: context_window)
  end

  # The case the pair exists for: one model, two servers.
  let(:catalog) do
    described_class.from_llms(
      [llm('local', server: 'http://localhost:8080', context_window: 32_768),
       llm('remote', server: 'http://remote:8080', api_key: 'sk-1')]
    )
  end

  context '.from_llms' do
    it 'normalizes the server into the transport pikuri would build itself' do
      transport = catalog.find('local').transport

      assert_equal 'http://localhost:8080/v1', transport.api_base
      assert_equal :openai, transport.provider
      assert_equal 32_768, transport.context_window
    end

    it 'gives a connection with no key the local-server placeholder' do
      assert_equal 'not-needed', catalog.find('local').transport.api_key
      assert_equal 'sk-1', catalog.find('remote').transport.api_key
    end

    it 'accepts a server that already carries the /v1 suffix' do
      one = described_class.from_llms([llm('local', server: 'http://localhost:8080/v1')])
      assert_equal 'http://localhost:8080/v1', one.primary.transport.api_base
    end

    # Rationing the server is pikuri's now, and nothing rides the transport to
    # do it (`D_upstream_request_throttle`).
    it 'leaves the transports carrying no adapter of ours' do
      assert_nil catalog.find('local').transport.faraday_adapter
    end
  end

  context '#find' do
    it 'answers nil for a name this config does not have' do
      assert_nil catalog.find('gone')
      assert_nil catalog.find('')
    end
  end

  context '#resolve' do
    it 'tells two connections running one model apart by their server' do
      assert_equal 'remote', catalog.resolve(model: 'qwen3.6', server: 'http://remote:8080/v1').name
      assert_equal 'local', catalog.resolve(model: 'qwen3.6', server: 'http://localhost:8080/v1').name
    end

    it 'answers nil for a conversation with no saved connection' do
      assert_nil catalog.resolve(model: nil, server: nil)
    end

    it 'answers nil once a connection leaves the config file' do
      assert_nil catalog.resolve(model: 'qwen3.6', server: 'http://retired:8080/v1')
    end
  end

  context '#name_for' do
    it 'renders a transport as the connection that produced it' do
      assert_equal 'remote', catalog.name_for(catalog.find('remote').transport)
    end

    it 'falls back to the raw model id for a transport from outside the catalog' do
      outside = Pikuri::Agent::ChatTransport.from_openai_server(
        server: 'http://elsewhere:8080', model: 'llama-4'
      )
      assert_equal 'llama-4', catalog.name_for(outside)
    end
  end

  context '#rows' do
    it 'hands the dialog names, model ids and windows — and no transport' do
      assert_equal(
        [{ name: 'local', model: 'qwen3.6', context_window: 32_768 },
         { name: 'remote', model: 'qwen3.6', context_window: nil }],
        catalog.rows
      )
    end
  end

  context '#primary and #multiple?' do
    it 'is the first connection, and a lone one is nothing to pick between' do
      one = described_class.from_llms([llm('local', server: 'http://localhost:8080')])

      assert_equal 'local', catalog.primary.name
      assert catalog.multiple?
      refute one.multiple?
    end
  end
end
