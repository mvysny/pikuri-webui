# frozen_string_literal: true

require 'sinatra/base'

module PikuriWeb
  # The Sinatra app: four routes around the {Transcript} / {Broadcaster}
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

    # The page shell: transcript snapshot and status bar state rendered
    # server-side, so a fresh load (or reload mid-turn) shows the full
    # current state before the EventSource connects.
    get '/' do
      erb :index, locals: {
        blocks: settings.transcript.to_a,
        status: settings.runner.status_data
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
  end
end
