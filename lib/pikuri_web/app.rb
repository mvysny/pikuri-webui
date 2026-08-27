# frozen_string_literal: true

require 'sinatra/base'

module PikuriWeb
  # The Sinatra app: five routes around the {Transcript} / {Broadcaster}
  # / {AgentRunner} trio, which the host injects via class-level settings
  # before boot (see bin/pikuri-web-chat; specs inject fakes the same way):
  #
  #   PikuriWeb::App.set :transcript,  transcript
  #   PikuriWeb::App.set :broadcaster, broadcaster
  #   PikuriWeb::App.set :runner,      runner
  #
  # Pikuri-free by design (the seam rule): routes speak only ids, kinds,
  # HTML strings and status hashes. Everything Pikuri-shaped sits behind
  # AgentRunner / SseListener.
  #
  # Threading: +GET /events+ parks the serving thread in a queue-drain
  # loop for the lifetime of the EventSource connection — one server
  # thread per connected browser tab. Fine for a single-user localhost
  # tool; bin/pikuri-web-chat raises Puma's thread pool to make room.
  class App < Sinatra::Base
    set :root, File.expand_path('../..', __dir__)
    # Auto-escape <%= %> in templates; pre-rendered transcript HTML is
    # emitted deliberately via <%== %>.
    set :erb, escape_html: true
    # This app is exactly its routes — 404s need no styled page, and the
    # dev-mode path rewriting interferes with rack-test assertions.
    disable :show_exceptions, :static_cache_control

    # The two themes style.css knows about. The `theme` cookie is
    # attacker-free (app.js is its only writer) but user-editable, so an
    # unknown value falls back to the default rather than reaching the
    # `data-theme` attribute.
    THEMES = %w[dark light].freeze
    DEFAULT_THEME = 'dark'

    # The page shell: transcript snapshot and status bar state rendered
    # server-side, so a fresh load (or reload mid-turn) shows the full
    # current state before the EventSource connects.
    #
    # The theme is resolved here too — rendering `data-theme` into the
    # markup is what keeps a light-theme user from a dark first paint;
    # a JS-applied class would flash. There is no matching route: the
    # toggle writes the cookie client-side (see public/app.js), because
    # a POST + reload would cost an SSE reconnect for a color change.
    get '/' do
      cookie = request.cookies['theme']
      erb :index, locals: {
        blocks: settings.transcript.to_a,
        status: settings.runner.status_data,
        theme: THEMES.include?(cookie) ? cookie : DEFAULT_THEME
      }
    end

    # SSE feed of transcript deltas (+block+ / +remove+) and +status+
    # events. The drain loop blocks on the subscribed queue until
    # the client goes away (write raises) or the broadcaster shuts down
    # (nil sentinel).
    get '/events' do
      content_type 'text/event-stream'
      headers 'Cache-Control' => 'no-cache'
      stream do |out|
        queue = settings.broadcaster.subscribe
        begin
          while (frame = queue.pop)
            out << frame
          end
        rescue IOError, Errno::EPIPE
          # Client disconnected mid-write; fall through to cleanup.
        ensure
          settings.broadcaster.unsubscribe(queue)
        end
      end
    end

    # Submit user text. AgentRunner decides start-vs-inject (Interloper);
    # the browser needs no answer beyond "accepted" — rendering arrives
    # over SSE.
    post '/messages' do
      prompt = params['prompt'].to_s
      halt 422, 'prompt must not be blank' if prompt.strip.empty?

      settings.runner.submit(prompt)
      status 204
    end

    # Gentle cancel of the in-flight turn (Cancellable semantics: takes
    # effect at the next tool boundary). Idempotent; no-op when idle.
    post '/cancel' do
      settings.runner.cancel
      status 204
    end

    # Save the current conversation and start a fresh one. No body: the
    # transcript is emptied by the +reset+ SSE event that the agent's own
    # +Event::Reset+ produces.
    #
    # 409 while a turn is in flight — the runner refuses rather than throw the
    # turn away.
    post '/conversations' do
      halt 409, 'a turn is in flight' if settings.runner.new_conversation == :busy
      status 204
    end
  end
end
