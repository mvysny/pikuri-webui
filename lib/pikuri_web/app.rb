# frozen_string_literal: true

require 'sinatra/base'

module PikuriWeb
  # The Sinatra app: eight routes around the {Transcript} / {Broadcaster}
  # / {AgentRunner} / {ConversationStore} quartet, which the host injects
  # via class-level settings before boot (see bin/pikuri-web-chat; specs
  # inject fakes the same way):
  #
  #   PikuriWeb::App.set :transcript,    transcript
  #   PikuriWeb::App.set :broadcaster,   broadcaster
  #   PikuriWeb::App.set :runner,        runner
  #   PikuriWeb::App.set :conversations, store
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
      render_conversation(settings.runner.conversation)
    end

    # View one conversation, live or not. Always succeeds where the folder is
    # readable: *viewing* is free and needs nothing from the agent, so no
    # 409 — what refuses mid-turn is sending into a conversation the agent is
    # not already on (see +POST /messages+).
    #
    # A GET with no side effects is also why sidebar rows are plain links
    # again; nothing here minds a prefetch.
    get '/c/:id' do
      conversation = resolve_conversation(params['id'])
      halt 404, 'no such conversation' if conversation.nil?

      render_conversation(conversation)
    end

    # The sidebar's list on its own, for app.js to drop back into the page
    # when the live conversation changes (the +reset+ SSE event) — the same
    # server-rendered markup +GET /+ embeds, so no conversation state is ever
    # assembled in the browser.
    get '/conversations' do
      erb :_sidebar, locals: {
        conversations: conversation_rows(viewing: params['viewing'].to_s),
        busy: settings.runner.status_data[:busy]
      }
    end

    # SSE feed of transcript deltas (+block+ / +remove+ / +reset+), +status+
    # events, and +conversations+ — the bare "the sidebar's list changed,
    # re-fetch it" signal. The drain loop blocks on the subscribed queue until
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
    # Submit user text to the conversation named by +conversation+ (the page
    # renders its own id into the form), or to the live one when that is
    # omitted. AgentRunner decides start-vs-inject (Interloper); the browser
    # needs no answer beyond "accepted" — rendering arrives over SSE.
    #
    # Sending into a conversation the agent is *not* on makes it live first.
    # That is the one operation that refuses mid-turn, and it carries the
    # refusal that +select+ used to: switching would have to throw a running
    # turn away. Running a turn *while* viewing another conversation needs an
    # agent per conversation — `ideas/per-conversation-agents.md` stage 2.
    post '/messages' do
      prompt = params['prompt'].to_s
      halt 422, 'prompt must not be blank' if prompt.strip.empty?

      target = params['conversation'].to_s
      make_live(target) unless target.empty?
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
    # Save the live conversation and start a fresh one, answering with the new
    # conversation's id so the tab that asked can navigate to it.
    #
    # It has to navigate rather than clear in place: the fresh conversation has
    # a new id, so its +reset+ frame no longer matches what this tab has open —
    # which is the same rule that correctly leaves *other* tabs sitting on the
    # conversation they were reading, now saved and no longer live.
    #
    # 409 while a turn is in flight — the runner refuses rather than throw the
    # turn away.
    post '/conversations' do
      halt 409, 'a turn is in flight' if settings.runner.new_conversation == :busy

      content_type 'text/plain'
      settings.runner.conversation.id
    end

    # Delete a conversation — the stored folder, and the agent's history too
    # when it is the live one. Irreversible: app.js asks first, and there is
    # nowhere here that a deleted conversation could be recovered from.
    #
    # The 303 serves a no-JS browser, as with +select+; app.js declines it and
    # re-fetches the sidebar, while the +conversations+ SSE frame the runner
    # pushes is what un-lists the row in every *other* tab.
    post '/conversations/:id/delete' do
      conversation = resolve_conversation(params['id'])
      halt 404, 'no such conversation' if conversation.nil?

      case settings.runner.delete_conversation(conversation)
      when :busy then halt 409, 'a turn is in flight'
      when :failed then halt 500, 'that conversation could not be deleted'
      end
      redirect to('/'), 303
    end

    private

    # Render the page shell for one conversation.
    #
    # The live one shows {Transcript}'s blocks — the server-authoritative
    # snapshot SSE then carries deltas against. Any other is replayed from its
    # history for this request alone, which is why it renders as a snapshot
    # nothing updates: no agent is on it, so nothing is arriving.
    #
    # @param conversation [ConversationStore::Conversation]
    # @return [String] the rendered page
    def render_conversation(conversation)
      live = settings.runner.conversation
      viewing_live = conversation.id == live.id
      blocks = viewing_live ? settings.transcript.to_a : HistoryReplay.snapshot(conversation.dir)
      halt 422, 'that conversation could not be read' if blocks.nil?

      cookie = request.cookies['theme']
      erb :index, locals: {
        blocks: blocks,
        status: settings.runner.status_data,
        conversations: conversation_rows(viewing: conversation.id),
        conversation: conversation.id,
        live: viewing_live,
        theme: THEMES.include?(cookie) ? cookie : DEFAULT_THEME
      }
    end

    # Put a conversation under the agent so a message can be sent into it,
    # halting with the same refusals the old +select+ route carried.
    #
    # @param id [String]
    # @return [void]
    def make_live(id)
      conversation = resolve_conversation(id)
      halt 404, 'no such conversation' if conversation.nil?

      case settings.runner.load_conversation(conversation)
      when :busy then halt 409, 'a turn is in flight'
      when :failed then halt 422, 'that conversation could not be read'
      end
      nil
    end

    # @param id [String]
    # @return [ConversationStore::Conversation, nil] the live conversation
    #   included, since it is in the sidebar before it is on disk
    def resolve_conversation(id)
      live = settings.runner.conversation
      live.id == id ? live : settings.conversations.find(id)
    end

    # The sidebar's model: every saved conversation newest first, plus the
    # live one, which has no +meta.json+ until its first turn is saved and so
    # is missing from the store's listing.
    #
    # +current+ and +live+ came apart when viewing stopped implying selection:
    # +current+ is the row this tab is *looking at* (per tab, from the URL),
    # +live+ is the one the agent is on (server-wide, the same in every tab).
    # They coincide until someone navigates away.
    #
    # @param viewing [String] id of the conversation this tab has open
    # @return [Array<Hash>] +{id:, title:, ago:, current:, live:, supported:}+
    def conversation_rows(viewing:)
      # Ask the runner first: it answers under the mutex it switches
      # conversations beneath, so a request racing a +reset+ frame blocks
      # until the switch lands rather than reading the outgoing conversation.
      live = settings.runner.conversation
      rows = settings.conversations.list
      rows.unshift(live) unless rows.any? { |c| c.id == live.id }
      rows.map do |c|
        {
          id: c.id,
          title: c.title,
          ago: RelativeTime.humanize(c.created_at),
          current: c.id == viewing,
          live: c.id == live.id,
          supported: c.supported
        }
      end
    end
  end
end
