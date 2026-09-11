# frozen_string_literal: true

require 'spec_helper'

# Drives the middleware with rack-test around a one-line app: the gate never
# looks inside what it wraps, so a stub endpoint proves what Web::App would,
# and the stub's path is any path — which is the point of gating as middleware
# rather than as a route filter.
describe PikuriWeb::Web::Gate do
  include Rack::Test::Methods

  PAIR = PikuriWeb::Config::Credentials.new(user: 'mavi', password: 'a long passphrase')

  let(:gate) do
    inner = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['transcript']] }
    described_class.new(inner, PAIR)
  end
  let(:app) { gate }

  # The header a browser sends once it has the pair — built here rather than
  # via Rack::Test's `authorize` so the malformed cases below can use the same
  # door.
  def basic(user, password)
    "Basic #{["#{user}:#{password}"].pack('m0')}"
  end

  # The Set-Cookie line the response carries, or nil.
  def cookie_set
    Array(last_response.headers['set-cookie']).first
  end

  describe 'the prompt' do
    it 'challenges a request that brings neither cookie nor credentials' do
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

    it 'gates every path, not only the routes — public/ and the SSE feed ride behind it' do
      get '/style.css'
      assert_equal 401, last_response.status

      get '/events?conversation=whatever'
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

  # What spares an iPhone's home-screen app the native dialog on every launch.
  describe 'the cookie' do
    it 'mints one on a passed challenge, http-only and scoped to the whole app' do
      header 'Authorization', basic('mavi', 'a long passphrase')
      get '/'
      assert_includes cookie_set, 'auth='
      assert_includes cookie_set, 'httponly'
      assert_includes cookie_set, 'path=/'
      assert_includes cookie_set, 'samesite=lax'
      assert_includes cookie_set, "max-age=#{described_class::WINDOW}"
    end

    it 'leaves `secure` off over plain http, where the browser would never send it back' do
      header 'Authorization', basic('mavi', 'a long passphrase')
      get '/'
      refute_includes cookie_set, 'secure'
    end

    it 'marks it secure over https' do
      header 'Authorization', basic('mavi', 'a long passphrase')
      get 'https://example.org/'
      assert_includes cookie_set, 'secure'
    end

    it 'mints none for a refused challenge' do
      get '/'
      assert_nil cookie_set
    end

    it 'admits a later request carrying it, with no Authorization header at all' do
      header 'Authorization', basic('mavi', 'a long passphrase')
      get '/'
      header 'Authorization', nil
      get '/'
      assert_equal 200, last_response.status
      assert_equal 'transcript', last_response.body
    end

    it 'leaves a fresh cookie alone, and replaces one past the halfway mark' do
      now = Time.now.to_i
      set_cookie "auth=#{gate.mint(now)}"
      get '/'
      assert_equal 200, last_response.status
      assert_nil cookie_set

      set_cookie "auth=#{gate.mint(now - (described_class::WINDOW / 2) - 60)}"
      get '/'
      assert_equal 200, last_response.status
      assert_includes cookie_set, 'auth='
    end

    it 'falls through to the prompt for an expired one' do
      set_cookie "auth=#{gate.mint(Time.now.to_i - described_class::WINDOW - 60)}"
      get '/'
      assert_equal 401, last_response.status
    end

    it 'falls through to the prompt for a tampered expiry or signature' do
      value = gate.mint(Time.now.to_i)
      expiry, mac = value.split('.')

      set_cookie "auth=#{expiry.to_i + 86_400}.#{mac}"
      get '/'
      assert_equal 401, last_response.status

      set_cookie "auth=#{expiry}.#{'f' * 64}"
      get '/'
      assert_equal 401, last_response.status

      set_cookie 'auth=not-a-ticket'
      get '/'
      assert_equal 401, last_response.status
    end

    it 'stops honouring cookies minted under the old password' do
      stale = described_class
              .new(->(_env) { [200, {}, ['x']] },
                   PikuriWeb::Config::Credentials.new(user: 'mavi', password: 'what it used to be'))
              .mint(Time.now.to_i)

      set_cookie "auth=#{stale}"
      get '/'
      assert_equal 401, last_response.status
    end
  end
end
