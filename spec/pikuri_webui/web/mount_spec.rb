# frozen_string_literal: true

require 'spec_helper'

# Drives the middleware around a stub that echoes the two halves of the path it
# was handed, so each example reads as "this URL reached the app as that".
describe PikuriWebUI::Web::Mount do
  include Rack::Test::Methods

  let(:app) do
    inner = ->(env) { [200, { 'content-type' => 'text/plain' }, ["#{env['SCRIPT_NAME']}|#{env['PATH_INFO']}"]] }
    described_class.new(inner, '/pikuri-webui')
  end

  it 'hands the app what follows the prefix, the prefix moved into SCRIPT_NAME' do
    get '/pikuri-webui/c/42'
    assert_equal 200, last_response.status
    assert_equal '/pikuri-webui|/c/42', last_response.body
  end

  it "takes the bare prefix as the app's root" do
    get '/pikuri-webui'
    assert_equal '/pikuri-webui|', last_response.body

    get '/pikuri-webui/'
    assert_equal '/pikuri-webui|/', last_response.body
  end

  it 'refuses a path that merely begins with the same letters' do
    get '/pikuri-webuix/c/42'
    assert_equal 404, last_response.status
  end

  # The likeliest way here is a proxy that stripped the prefix, so the refusal
  # names the fix rather than saying only "not found".
  it 'refuses a path outside the prefix, saying where the app lives' do
    get '/c/42'
    assert_equal 404, last_response.status
    assert_includes last_response.body, 'served under /pikuri-webui/'
    assert_includes last_response.body, 'tailscale serve --set-path /pikuri-webui http://127.0.0.1:<port>/pikuri-webui'
    assert_equal 'nosniff', last_response.headers['x-content-type-options']
  end

  # Never a redirect: behind a proxy that strips the prefix, a redirect to it
  # comes straight back without it.
  it 'answers the root with the same 404, never a redirect' do
    get '/'
    assert_equal 404, last_response.status
  end

  describe 'in front of the gate' do
    let(:pair) { PikuriWebUI::Config::Credentials.new(user: 'mavi', password: 'a long passphrase') }
    let(:app) do
      inner = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['transcript']] }
      described_class.new(PikuriWebUI::Web::Gate.new(inner, pair), '/pikuri-webui')
    end

    # A cookie scoped to "/" would ride along to every other app on the host.
    it 'scopes the cookie the gate mints to the prefix' do
      header 'Authorization', "Basic #{['mavi:a long passphrase'].pack('m0')}"
      get '/pikuri-webui/'
      assert_equal 200, last_response.status
      assert_includes Array(last_response.headers['set-cookie']).first, 'path=/pikuri-webui;'
    end
  end
end
