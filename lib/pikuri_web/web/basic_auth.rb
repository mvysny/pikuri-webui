# frozen_string_literal: true

require 'rack/auth/basic'

module PikuriWeb
  module Web
    # Rack middleware holding one username/password in front of the whole app —
    # routes and +public/+ both, which a +before+ filter would not reach:
    #
    #   PikuriWeb::Web::App.use PikuriWeb::Web::BasicAuth, config.credentials
    #
    # A missing or wrong pair earns a bare 401 with +WWW-Authenticate+ and the
    # browser draws its own prompt, so there is nothing here to render. It is a
    # *gate*, not accounts: one pair for everyone, no session, no logout, no
    # lockout (+D_one_password_gate+).
    #
    # There is deliberately no disabled mode: a config file with no +[web]+
    # table never +use+s this at all. +GET /events+ needs no special case
    # either — the browser replays the credentials it cached for the origin on
    # every later request, the EventSource included.
    #
    # Thread-safe.
    class BasicAuth
      # @return [String] the realm string the browser's prompt shows above its
      #   two fields.
      REALM = 'pikuri'

      # @param app [#call] the Rack app to gate.
      # @param credentials [#user, #password] the one accepted pair, typically
      #   a {Config::Credentials}.
      def initialize(app, credentials)
        @guard = Rack::Auth::Basic.new(app, REALM) do |user, password|
          # `&`, not `&&`: both halves are compared on every attempt, so how
          # long the refusal takes says nothing about which half was right.
          Rack::Utils.secure_compare(credentials.user, user) &
            Rack::Utils.secure_compare(credentials.password, password)
        end
      end

      # @param env [Hash] the Rack environment.
      # @return [Array(Integer, Hash, #each)] the gated app's response, or a
      #   401 (no or wrong credentials) / 400 (a header that is not Basic).
      def call(env) = @guard.call(env)
    end
  end
end
