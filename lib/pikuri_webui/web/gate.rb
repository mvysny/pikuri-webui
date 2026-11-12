# frozen_string_literal: true

require 'openssl'
require 'rack/auth/basic'
require 'rack/request'
require 'rack/utils'

module PikuriWebUI
  module Web
    # Rack middleware holding the one configured password in front of the whole
    # app — routes and +public/+ both, which a +before+ filter would not reach:
    #
    #   PikuriWebUI::Web::App.use PikuriWebUI::Web::Gate, config.credentials
    #
    # Two doors, and the second one mints the key to the first: a request
    # carrying a valid +auth+ cookie goes straight through, and anything else
    # meets +Rack::Auth::Basic+ — a bare 401 with +WWW-Authenticate+, which the
    # browser answers with its own prompt. Getting through that way sets the
    # cookie, so the prompt is a once-per-browser event rather than a
    # once-per-launch one (+D_gate_cookie+).
    #
    # Still a *gate*, not accounts: one pair for everyone, no server-side
    # session, no logout, no lockout (+D_one_password_gate+). There is
    # deliberately no disabled mode either — a config file with no +[web]+
    # table never +use+s this at all.
    #
    # == The cookie
    #
    #   auth=1775000000.9f86d081…   # <expiry>.<HMAC_SHA256(password, "auth|user|expiry")>
    #
    # Signed with the configured password as the key, so nothing is stored
    # server-side and changing the password (or the user) invalidates every
    # outstanding cookie at once. {#mint} and {#verify} are the pair; a cookie
    # past the halfway mark of its {WINDOW} is replaced on the way out, so an
    # app in regular use never meets the expiry. +GET /events+ needs no special
    # case — the browser sends the cookie on every later request, the
    # EventSource included.
    #
    # Thread-safe.
    class Gate
      # @return [String] the realm string the browser's prompt shows above its
      #   two fields.
      REALM = 'pikuri'

      # @return [String] name of the cookie a passed challenge mints.
      COOKIE = 'auth'

      # @return [Integer] how long a minted cookie is good for, in seconds.
      #   Long on purpose: what it spares is a native dialog on a phone.
      WINDOW = 90 * 24 * 60 * 60

      # @return [Regexp] shape of a cookie value — decimal expiry, dot, hex
      #   SHA-256 MAC. Anything else is refused before a MAC is computed.
      TICKET = /\A(\d{1,12})\.(\h{64})\z/

      # @param app [#call] the Rack app to gate.
      # @param credentials [#user, #password] the one accepted pair, typically
      #   a {Config::Credentials}.
      def initialize(app, credentials)
        @app = app
        @credentials = credentials
      end

      # @param env [Hash] the Rack environment.
      # @return [Array(Integer, Hash, #each)] the gated app's response, or a
      #   401 (no or wrong credentials) / 400 (a header that is not Basic).
      def call(env)
        now = Time.now.to_i
        expiry = verify(Rack::Utils.parse_cookies(env)[COOKIE], now)
        return admitted(env, now, refresh: expiry - now < WINDOW / 2) if expiry

        # The inner app records the pass, rather than the response's status
        # standing in for it: a 404 to an authenticated request still earns a
        # cookie, and a route answering 401 on its own account never would.
        passed = false
        watched = lambda do |inner_env|
          passed = true
          @app.call(inner_env)
        end
        response = Rack::Auth::Basic.new(watched, REALM) { |user, pass| correct?(user, pass) }.call(env)
        passed ? with_cookie(response, env, now) : response
      end

      # The cookie value admitting a browser for the next {WINDOW} seconds.
      #
      # @param now [Integer] the current unix time.
      # @return [String] +"<expiry>.<mac>"+.
      def mint(now)
        expiry = now + WINDOW
        "#{expiry}.#{mac(expiry)}"
      end

      # The expiry a cookie carries, once its signature and freshness check out.
      #
      # @param value [String, nil] the raw cookie value.
      # @param now [Integer] the current unix time.
      # @return [Integer, nil] the expiry, or +nil+ for anything malformed,
      #   expired or wrongly signed — all of which fall through to the prompt
      #   rather than failing the request.
      def verify(value, now)
        found = TICKET.match(value.to_s)
        return nil unless found

        expiry = found[1].to_i
        return nil unless expiry > now
        return nil unless Rack::Utils.secure_compare(mac(expiry), found[2])

        expiry
      end

      private

      # @param user [String] the user name the browser sent.
      # @param password [String] the password the browser sent.
      # @return [Boolean] whether both match the configured pair.
      def correct?(user, password)
        # `&`, not `&&`: both halves are compared on every attempt, so how long
        # the refusal takes says nothing about which half was right.
        Rack::Utils.secure_compare(@credentials.user, user) &
          Rack::Utils.secure_compare(@credentials.password, password)
      end

      # @param env [Hash] the Rack environment.
      # @param now [Integer] the current unix time.
      # @param refresh [Boolean] whether to mint a fresh cookie on the way out.
      # @return [Array(Integer, Hash, #each)] the gated app's response.
      def admitted(env, now, refresh:)
        env['REMOTE_USER'] = @credentials.user
        response = @app.call(env)
        refresh ? with_cookie(response, env, now) : response
      end

      # @param response [Array(Integer, Hash, #each)] the gated app's response.
      # @param env [Hash] the Rack environment.
      # @param now [Integer] the current unix time.
      # @return [Array(Integer, Hash, #each)] +response+ with a fresh cookie set.
      def with_cookie(response, env, now)
        status, headers, body = response
        Rack::Utils.set_cookie_header!(
          headers, COOKIE,
          value: mint(now), path: '/', max_age: WINDOW, httponly: true, same_site: :lax,
          secure: Rack::Request.new(env).ssl?
        )
        [status, headers, body]
      end

      # @param expiry [Integer] the unix time a cookie stops being good.
      # @return [String] the hex HMAC that signs it.
      def mac(expiry)
        OpenSSL::HMAC.hexdigest('SHA256', @credentials.password,
                                "#{COOKIE}|#{@credentials.user}|#{expiry}")
      end
    end
  end
end
