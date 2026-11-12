# frozen_string_literal: true

# Exercises the two directions a picker needs: a browser-facing name into a
# transport, and a transport back into a name. Both are keyed on the
# +[model, api_base]+ pair, which is the whole reason this class exists rather
# than a Hash.
RSpec.describe PikuriWebUI::Agents::ModelCatalog do
  def llm(name, server:, model: 'qwen3.6', api_key: nil, context_window: nil, params: {})
    PikuriWebUI::Config::Llm.new(name: name, server: server, model: model,
                                 api_key: api_key, context_window: context_window, params: params)
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

    it 'leaves a connection with no params carrying an empty table' do
      assert_empty catalog.find('local').transport.params
    end

    # pikuri symbolizes on the way in, so the TOML spelling and what the
    # transport carries differ by key type. The expectation is not a typo.
    it 'rides a params table onto the transport' do
      one = described_class.from_llms(
        [llm('titler', server: 'http://localhost:8080',
                       params: { 'chat_template_kwargs' => { 'enable_thinking' => false } })]
      )
      assert_equal({ chat_template_kwargs: { enable_thinking: false } },
                   one.primary.transport.params)
    end

    # The seam has to stay free for `Pikuri::Testing`'s scripted adapter: it is
    # one slot, so anything this repo parks there costs the ability to fake a
    # connection's HTTP. Rationing is pikuri's (`D_upstream_request_throttle`)
    # and params have their own field, so nothing here needs it.
    it 'installs no Faraday adapter, whatever the connection carries' do
      one = described_class.from_llms(
        [llm('titler', server: 'http://localhost:8080', params: { 'min_p' => 0.05 })]
      )
      assert_nil catalog.find('local').transport.faraday_adapter
      assert_nil one.primary.transport.faraday_adapter
    end
  end

  # The titler recipe is a second [[llm]] on one model and one server,
  # differing only in `params` — so the identity pair is no longer unique, and
  # which entry owns it decides what a saved conversation reopens on.
  context 'two entries sharing the [model, api_base] pair' do
    let(:shadowing) do
      described_class.from_llms(
        [llm('Local Qwen 3.6', server: 'http://localhost:8080'),
         llm('qwen-titler', server: 'http://localhost:8080',
                            params: { 'chat_template_kwargs' => { 'enable_thinking' => false } })]
      )
    end

    it 'resolves the pair to the first entry declared, not the last' do
      choice = shadowing.resolve(model: 'qwen3.6', server: 'http://localhost:8080/v1')
      assert_equal 'Local Qwen 3.6', choice.name
      # The winner is the thinking one — a reopen must not inherit the titler's
      # params along with the pair.
      assert_empty choice.transport.params
    end

    it 'names the first entry for a transport carrying the pair' do
      assert_equal 'Local Qwen 3.6', shadowing.name_for(shadowing.find('qwen-titler').transport)
    end

    it 'keeps the shadowed entry pickable and listed' do
      assert_equal(['Local Qwen 3.6', 'qwen-titler'], shadowing.rows.map { |r| r[:name] })
      refute_empty shadowing.find('qwen-titler').transport.params
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
