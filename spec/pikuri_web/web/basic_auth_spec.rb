# frozen_string_literal: true

require 'spec_helper'

# Drives the middleware with rack-test around a one-line app: BasicAuth never
# looks inside what it wraps, so a stub endpoint proves what Web::App would,
# and the stub's path is any path — which is the point of gating as middleware
# rather than as a route filter.
describe PikuriWeb::Web::BasicAuth do
  include Rack::Test::Methods

  PAIR = PikuriWeb::Config::Credentials.new(user: 'mavi', password: 'a long passphrase')

  let(:app) do
    inner = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['transcript']] }
    described_class.new(inner, PAIR)
  end

  # The header a browser sends once it has the pair — built here rather than
  # via Rack::Test's `authorize` so the malformed cases below can use the same
  # door.
  def basic(user, password)
    "Basic #{["#{user}:#{password}"].pack('m0')}"
  end

  it 'challenges a request that brings no credentials' do
    get '/'
    assert_equal 401, last_response.status
    assert_equal 'Basic realm="pikuri"', last_response.headers['www-authenticate']
    refute_includes last_response.body, 'transcript'
  end

  it 'passes the configured pair through to the app' do
    header 'Authorization', basic('mavi', 'a long passphrase')
    get '/'
    assert_equal 200, last_response.status
    assert_equal 'transcript', last_response.body
  end

  it 'refuses a wrong password, and a wrong user with the right password' do
    header 'Authorization', basic('mavi', 'a long passphrasf')
    get '/'
    assert_equal 401, last_response.status

    header 'Authorization', basic('root', 'a long passphrase')
    get '/'
    assert_equal 401, last_response.status
  end

  it 'gates every path, not only the routes — public/ rides behind it' do
    get '/style.css'
    assert_equal 401, last_response.status
  end

  it 'refuses an Authorization header that is not Basic' do
    header 'Authorization', 'Bearer sk-whatever'
    get '/'
    assert_equal 400, last_response.status
  end

  it 'refuses a Basic payload carrying no colon, rather than raising' do
    header 'Authorization', "Basic #{['mavi'].pack('m0')}"
    get '/'
    assert_equal 400, last_response.status
  end
end
