# frozen_string_literal: true

require 'sinatra/base'

module PikuriWeb
  # The Sinatra app: nine routes around the {ConversationRegistry} /
  # {Broadcaster} pair, which the host injects via class-level settings before
  # boot (see bin/pikuri-web-chat; specs inject fakes the same way):
  #
  #   PikuriWeb::App.set :registry,    registry
  #   PikuriWeb::App.set :broadcaster, broadcaster
  #   PikuriWeb::App.set :models,      catalog.rows   # what /model lists
  #
  # Every route names the conversation it acts on, and none of them refuse
  # because *another* conversation is working: each has its own agent, and the
  # shared executor queues a turn rather than rejecting it. Delete is the one
  # exception, and it refuses only for the conversation actually in flight.
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

    # Rack's table has no +.webmanifest+ entry, so +public/manifest.webmanifest+
    # would go out as octet-stream and every browser refuses to parse a manifest
    # served as one. Registering the type is the whole server side of the PWA
    # install path — the manifest itself stays a static file like style.css.
    mime_type :webmanifest, 'application/manifest+json'

    # The connections +/model+ offers, as {ModelCatalog#rows} — plain hashes,
    # so this side of the seam never sees a transport. Empty until the host
    # sets it, which is also what keeps +/model+ out of a palette that could
    # not run it.
    set :models, []

    # The two themes style.css knows about. The `theme` cookie is
    # attacker-free (app.js is its only writer) but user-editable, so an
    # unknown value falls back to the default rather than reaching the
    # `data-theme` attribute.
    THEMES = %w[dark light].freeze
    DEFAULT_THEME = 'dark'

    # No page of its own: there is no "current" conversation any more, only the
    # one a tab has open, so a bare +/+ picks the newest and hands over a real
    # URL to sit on.
    get '/' do
      redirect to("/c/#{settings.registry.default.id}"), 303
    end

    # The page shell for one conversation: its transcript and status bar
    # rendered server-side, so a fresh load (or a reload mid-turn) shows the
    # full current state before the EventSource connects.
    #
    # Opening one mints its agent if this is the first visit, which is what
    # makes the tab's SSE subscription meaningful: a turn someone starts here
    # from another tab lands in this page too.
    #
    # The theme is resolved here — rendering `data-theme` into the markup is
    # what keeps a light-theme user from a dark first paint; a JS-applied class
    # would flash. There is no matching route: the toggle writes the cookie
    # client-side (see public/js/app.js), because a POST + reload would cost an
    # SSE reconnect for a color change.
    get '/c/:id' do
      runner = open_conversation(params['id'])
      cookie = request.cookies['theme']
      erb :index, locals: {
        blocks: runner.transcript.to_a,
        status: runner.status_data,
        conversations: conversation_rows(viewing: runner.conversation.id),
        conversation: runner.conversation.id,
        title: runner.conversation.title,
        theme: THEMES.include?(cookie) ? cookie : DEFAULT_THEME,
        commands: SlashCommand.catalog(connections: settings.models.size),
        models: settings.models,
        # Static for the life of the process — one conversation factory, one
        # tool set — so the /trifecta dialog ships in the page rather than
        # costing a route of its own.
        trifecta: runner.trifecta_html
      }
    end

    # The sidebar's list on its own, for app.js to drop back into the page when
    # the set of conversations changes — the same server-rendered markup
    # +GET /c/:id+ embeds, so no conversation state is ever assembled in the
    # browser.
    get '/conversations' do
      erb :_sidebar, locals: { conversations: conversation_rows(viewing: params['viewing'].to_s) }
    end

    # SSE feed for the one conversation this tab is showing: transcript deltas
    # (+block+ / +remove+ / +reset+) and +status+ for that conversation, plus
    # the server-wide +conversations+ signal. A turn running in a conversation
    # this tab is *not* showing never reaches it — that is what detaching is.
    #
    # The drain loop blocks on the subscribed queue until the client goes away
    # (write raises) or the broadcaster shuts down (nil sentinel).
    get '/events' do
      content_type 'text/event-stream'
      headers 'Cache-Control' => 'no-cache'
      conversation = params['conversation'].to_s
      stream do |out|
        queue = settings.broadcaster.subscribe(conversation)
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

    # Submit user text to the conversation named by +conversation+ (the page
    # renders its own id into the form). AgentRunner decides start-vs-inject
    # (Interloper); the browser needs no answer beyond "accepted" — rendering
    # arrives over SSE.
    #
    # Never refused for being busy. A turn submitted when the executor's slots
    # are all taken by other conversations is queued and reported as such,
    # rather than rejected: that wait is the whole reason the executor is the
    # admission gate. The only 4xx past a blank prompt is a conversation that
    # has ceased to exist.
    post '/messages' do
      prompt = params['prompt'].to_s
      halt 422, 'prompt must not be blank' if prompt.strip.empty?

      runner = open_conversation(params['conversation'])
      # A delete can land between resolving the runner and submitting to it,
      # so this is open_conversation's own 404, one step late.
      halt 404, 'no such conversation' if runner.submit(prompt) == :discarded

      status 204
    end

    # Put one conversation on another connection, by +[[llm]]+ name. Applied at
    # the top of its next turn, never on the spot — so this is accepted while a
    # turn is running, exactly as a mid-turn send is.
    post '/model' do
      case open_conversation(params['conversation']).select_model(params['name'].to_s)
      when :unknown then halt 422, 'no such connection'
      when :discarded then halt 404, 'no such conversation'
      end
      status 204
    end

    # Gentle cancel of one conversation's turn: dropped before it starts if it
    # is still queued, stopped at the next tool boundary if it is running.
    # Idempotent; no-op when idle.
    post '/cancel' do
      open_conversation(params['conversation']).cancel
      status 204
    end

    # Start a fresh conversation, answering with its id so the tab that asked
    # can navigate to it. Never refused: it touches no existing conversation.
    #
    # +viewing+ is what the new conversation inherits its connection from — the
    # server cannot know which conversation the asking tab has open, the same
    # reason +GET /conversations+ is told.
    post '/conversations' do
      conversation = settings.registry.create(from: params['viewing'].to_s).conversation
      settings.broadcaster.broadcast(event: :conversations, data: {})
      content_type 'text/plain'
      conversation.id
    end

    # Delete a conversation — its folder, and whatever it had resident.
    # Irreversible: app.js asks first, and there is nowhere here that a deleted
    # conversation could be recovered from.
    #
    # The 303 serves a no-JS browser; app.js declines it and re-fetches the
    # sidebar, while the +conversations+ frame is what un-lists the row in
    # every other tab.
    post '/conversations/:id/delete' do
      conversation = settings.registry.find(params['id'])
      halt 404, 'no such conversation' if conversation.nil?

      case settings.registry.delete(conversation)
      when :busy then halt 409, 'a turn is in flight in that conversation'
      when :failed then halt 500, 'that conversation could not be deleted'
      end
      settings.broadcaster.broadcast(event: :conversations, data: {})
      redirect to('/'), 303
    end

    private

    # Resolve an id and open it, 404ing on anything not listed — which is what
    # keeps user input from ever becoming a path.
    #
    # @param id [String, nil]
    # @return [AgentRunner]
    def open_conversation(id)
      conversation = settings.registry.find(id.to_s)
      halt 404, 'no such conversation' if conversation.nil?

      settings.registry.open(conversation)
    end

    # The sidebar's model.
    #
    # +current+ is the row this tab has open (per tab, from the URL); +busy+ is
    # whether that conversation has a turn in flight (server-wide, and true of
    # as many rows as +--turns+ allows). They are independent: a turn running in
    # a row you are not looking at is the point of the feature.
    #
    # @param viewing [String] id of the conversation this tab has open
    # @return [Array<Hash>] +{id:, title:, ago:, current:, busy:, supported:}+
    def conversation_rows(viewing:)
      settings.registry.rows.map do |row|
        c = row[:conversation]
        {
          id: c.id,
          title: c.title,
          ago: RelativeTime.humanize(c.created_at),
          current: c.id == viewing,
          busy: row[:busy],
          supported: c.supported
        }
      end
    end
  end
end
