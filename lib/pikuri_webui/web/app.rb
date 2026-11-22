# frozen_string_literal: true

require 'sinatra/base'
require 'socket'

module PikuriWebUI
  module Web
    # The Sinatra app: ten routes around the {Conversations::Registry} /
    # {Broadcaster} pair, which the host injects via class-level settings before
    # boot (see bin/pikuri-webui-chat; specs inject fakes the same way):
    #
    #   PikuriWebUI::Web::App.set :big_app_lock, lock
    #   PikuriWebUI::Web::App.set :registry,    registry
    #   PikuriWebUI::Web::App.set :broadcaster, broadcaster
    #   PikuriWebUI::Web::App.set :store,       store          # where images are written and served from
    #   PikuriWebUI::Web::App.set :models,      catalog.rows   # what /model lists
    #   PikuriWebUI::Web::App.set :trifecta,    html           # the /trifecta dialog's body
    #
    # Every route body that touches server state is one {BigAppLock} task, so
    # what a route reads or mutates together cannot tear — the page snapshot is
    # one consistent picture, and resolve + act is one step. Template rendering
    # and the SSE drain loop stay outside the domain.
    #
    # Every route names the conversation it acts on, and none of them refuse
    # because *another* conversation is working: each has its own agent and its
    # own turns. Delete is the one exception, and it refuses only for the
    # conversation actually in flight.
    #
    # Pikuri-free by design (the seam rule): routes speak ids, kinds, HTML
    # strings, status hashes and the store's saved-conversation envelope, read
    # by field. Everything agent-shaped sits behind Agents::Runner / SseListener.
    #
    # Threading: +GET /events+ parks the serving thread in a queue-drain
    # loop for the lifetime of the EventSource connection — one server
    # thread per connected browser tab. Fine for a single-user localhost
    # tool; bin/pikuri-webui-chat raises Puma's thread pool to make room.
    class App < Sinatra::Base
      # The repo root, three up from lib/pikuri_webui/web/ — where views/ and
      # public/ live. Sinatra derives both from it.
      set :root, File.expand_path('../../..', __dir__)
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

      # The connections +/model+ offers, as {Agents::ModelCatalog#rows} — plain hashes,
      # so this side of the seam never sees a transport. Empty until the host
      # sets it, which is also what keeps +/model+ out of a palette that could
      # not run it.
      set :models, []

      # The rendered trifecta map ({TrifectaView}), one for the process since
      # every agent has the one tool wiring. Empty until the host sets it.
      set :trifecta, ''

      # The two themes style.css knows about. The `theme` cookie is
      # attacker-free (app.js is its only writer) but user-editable, so an
      # unknown value falls back to the default rather than reaching the
      # `data-theme` attribute.
      #
      # @return [Array<String>]
      THEMES = %w[dark light].freeze
      # @return [String]
      DEFAULT_THEME = 'dark'

      # Whether reasoning blocks start open, carried by the `thinking` cookie
      # and user-editable like `theme`, so an unknown value falls back. Unlike
      # the theme it falls back to a *configured* value, not a constant —
      # `[ui] show_thinking` is the config file's say in what a browser with no
      # preference of its own sees (`D_ui_cookie_over_config`).
      #
      # @return [Array<String>]
      THINKING = %w[expanded collapsed].freeze

      # {THINKING} fallback, set by the host from `Config#show_thinking`. True
      # rather than nil so a spec injecting no setting still renders a legal
      # page.
      set :show_thinking, true

      # The two tool-line forms style.css can show, carried by the `tools`
      # cookie — every block ships both and CSS picks
      # (`D_both_forms_in_the_block`). Same shape as {THINKING}; {Config} holds
      # `[ui] tool_lines` to the same pair, so its value needs no fallback.
      #
      # @return [Array<String>]
      TOOL_LINES = %w[short verbose].freeze

      # {TOOL_LINES} fallback, set by the host from `Config#tool_lines`.
      set :tool_lines, :short

      # Images one message may carry, and how large each may be. The browser
      # holds the draft to the same numbers; these are the authority.
      #
      # @return [Integer]
      MAX_IMAGES = 10
      # @return [Integer]
      MAX_IMAGE_BYTES = 5 * 1024 * 1024

      # The largest request body Puma accepts at all (+http_content_length_limit+,
      # set in bin/pikuri-webui-chat): a full set of images plus a MiB for the
      # text and the multipart framing. Without it Puma buffers any body to
      # disk before a route can say no.
      #
      # @return [Integer]
      MAX_BODY_BYTES = (MAX_IMAGES * MAX_IMAGE_BYTES) + (1024 * 1024)

      # What a page may load and run: script only from our own files, so markup
      # that reached the transcript anyway runs nothing (`D_markdown_renders_no_html`
      # is the first line, this the second).
      #
      # +style-src-attr+ allows the one inline style the page has — the
      # +text-align+ kramdown writes on an aligned table column; model text can
      # set no attribute. +img-src+ takes the web, as a Markdown image may link
      # one.
      #
      # @return [String]
      CONTENT_SECURITY_POLICY = [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self'",
        "style-src-attr 'unsafe-inline'",
        "img-src 'self' http: https:",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'self'",
        "frame-ancestors 'none'"
      ].join('; ')

      before do
        headers 'Content-Security-Policy' => CONTENT_SECURITY_POLICY
      end

      # No page of its own: there is no "current" conversation any more, only the
      # one a tab has open, so a bare +/+ picks the newest and hands over a real
      # URL to sit on.
      get '/' do
        redirect to("/c/#{settings.big_app_lock.run { settings.registry.default.id }}"), 303
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
      # SSE reconnect for a color change. The reasoning disclosures are resolved
      # here for the same reason ({#disclosed}).
      get '/c/:id' do
        cookie = request.cookies['theme']
        thinking = request.cookies['thinking']
        tools = request.cookies['tools']
        thinking = THINKING.include?(thinking) ? thinking : default_thinking
        # One task, so the page is an untorn read: the blocks, the status bar
        # and the sidebar rows come from the same instant, never straddling a
        # transition. The blocks are immutable and the rest plain data, so the
        # erb render needs no task of its own.
        snapshot = settings.big_app_lock.run do
          runner = open_conversation(params['id'])
          {
            blocks: runner.transcript.to_a,
            status: runner.status_data,
            conversations: conversation_rows(viewing: runner.conversation.id),
            conversation: runner.conversation.id,
            title: runner.conversation.title,
            trifecta: settings.trifecta
          }
        end
        erb :index, locals: snapshot.merge(
          blocks: disclosed(snapshot[:blocks], thinking),
          theme: THEMES.include?(cookie) ? cookie : DEFAULT_THEME,
          thinking: thinking,
          tools: TOOL_LINES.include?(tools) ? tools : settings.tool_lines.to_s,
          commands: SlashCommand.catalog(connections: settings.models.size),
          models: settings.models
        )
      end

      # The sidebar's list on its own, for app.js to drop back into the page when
      # the set of conversations changes — the same server-rendered markup
      # +GET /c/:id+ embeds, so no conversation state is ever assembled in the
      # browser.
      get '/conversations' do
        rows = settings.big_app_lock.run { conversation_rows(viewing: params['viewing'].to_s) }
        erb :_sidebar, locals: { conversations: rows }
      end

      # SSE feed for the one conversation this tab is showing: the opening
      # +snapshot+, transcript deltas (+block+ / +remove+ / +reset+) and +status+
      # for that conversation, plus the server-wide +conversations+ signal. A
      # turn running in a conversation this tab is *not* showing never reaches
      # it — that is what detaching is.
      #
      # The drain loop blocks on the subscribed queue until the client goes away
      # (write raises) or the broadcaster shuts down (nil sentinel).
      #
      # Opens with the transcript as it stands, because this connection and the
      # +GET /c/:id+ that rendered the page are two separate requests: anything
      # the agent finished in between belongs to neither. Subscribe + catch-up
      # is one task, so nothing can land between them server-side; the
      # subscribe-first order and the duplicate tolerance stay for the
      # page-render-to-connect gap, which no server mechanism reaches
      # (`D_subscribe_then_snapshot`).
      get '/events' do
        content_type 'text/event-stream'
        headers 'Cache-Control' => 'no-cache'
        conversation = params['conversation'].to_s
        socket = env['puma.socket']
        stream do |out|
          uncork(socket)
          queue, catch_up = settings.big_app_lock.run do
            [settings.broadcaster.subscribe(conversation), catch_up_frames(conversation)]
          end
          begin
            catch_up.each { |frame| out << frame }
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
      # renders its own id into the form). The conversation decides
      # start-vs-inject; the browser needs no answer beyond "accepted" —
      # rendering arrives over SSE.
      #
      # Never refused for being busy: a turn waits for the server inside its
      # requests, not here. The 4xx past a blank prompt are images a model is
      # known not to see, and a conversation that has ceased to exist.
      #
      # Images come as multipart +attachments[]+ parts beside +prompt+, and a
      # message may be images alone. They are written into the conversation's
      # folder *before* the submit and outside the domain ({#stash_uploads}),
      # so the block showing them never links to a file not there yet.
      post '/messages' do
        prompt = params['prompt'].to_s
        uploads = uploads_from(params['attachments'])
        halt 422, 'prompt must not be blank' if prompt.strip.empty? && uploads.empty?

        stashed = stash_uploads(params['conversation'], uploads) unless uploads.empty?
        # Resolve + submit is one task, so no delete can land between them.
        # +:discarded+ stays answered: it is the runner's own contract, reachable
        # through a stale reference held from an earlier request.
        outcome = settings.big_app_lock.run do
          settings.registry.open_id(params['conversation'].to_s)&.submit(prompt, uploads: uploads) || :discarded
        end
        case outcome
        when :discarded
          # A delete won the race since the stash: it may have put the folder
          # back, and a deleted conversation's pictures do not outlive it
          # (`D_delete_no_undo`).
          discard_stash(stashed) if stashed
          halt 404, 'no such conversation'
        when :refused
          # The stashed pictures stay: content-addressed and unreferenced, they
          # are the orphans the store already accepts, and a resend reuses them.
          halt 422, 'this model takes no image input'
        end

        status 204
      end

      # One image of a conversation, by the name it is stored under — what a
      # +:user+ block's strip links to. Saved and resident conversations alike:
      # {#stash_uploads} put the file there before the turn began.
      #
      # Content-addressed, so it never changes and the browser may keep it for
      # good; behind the gate like every other route. Only the four image
      # extensions are served, typed by extension and marked +nosniff+, so a
      # file in that folder can never be handed to the browser as a page.
      get '/c/:id/attachments/:name' do
        conversation = settings.big_app_lock.run { settings.registry.find(params['id'].to_s) }
        path = conversation && settings.store.attachment(conversation, params['name'].to_s)
        type = path && Conversations::Upload::TYPES.key(path.extname)
        halt 404, 'no such attachment' if type.nil?

        headers 'X-Content-Type-Options' => 'nosniff'
        cache_control :private, :immutable, max_age: 31_536_000
        send_file path, type: type
      end

      # Put one conversation on another connection, by +[[llm]]+ name. Applied at
      # the top of its next turn, never on the spot — so this is accepted while a
      # turn is running, exactly as a mid-turn send is.
      post '/model' do
        outcome = settings.big_app_lock.run do
          open_conversation(params['conversation']).select_model(params['name'].to_s)
        end
        case outcome
        when :unknown then halt 422, 'no such connection'
        when :discarded then halt 404, 'no such conversation'
        end
        status 204
      end

      # Gentle cancel of one conversation's turn, at its next check — a tool
      # boundary, or a wait for the server — or of its agent's boot. Idempotent;
      # no-op when idle.
      post '/cancel' do
        settings.big_app_lock.run { open_conversation(params['conversation']).cancel }
        status 204
      end

      # Start a fresh conversation, answering with its id so the tab that asked
      # can navigate to it. Never refused: it touches no existing conversation.
      #
      # +viewing+ is what the new conversation inherits its connection from — the
      # server cannot know which conversation the asking tab has open, the same
      # reason +GET /conversations+ is told.
      post '/conversations' do
        conversation = settings.big_app_lock.run do
          settings.registry.create(from: params['viewing'].to_s).conversation
                  .tap { settings.broadcaster.broadcast(event: :conversations, data: {}) }
        end
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
        outcome = settings.big_app_lock.run do
          conversation = settings.registry.find(params['id'])
          next :missing if conversation.nil?

          settings.registry.delete(conversation)
                  .tap { |o| settings.broadcaster.broadcast(event: :conversations, data: {}) if o == :deleted }
        end
        case outcome
        when :missing then halt 404, 'no such conversation'
        when :busy then halt 409, 'a turn is in flight in that conversation'
        when :failed then halt 500, 'that conversation could not be deleted'
        end
        redirect to('/'), 303
      end

      private

      # @return [String] the {THINKING} state a browser with no cookie gets.
      def default_thinking = settings.show_thinking ? 'expanded' : 'collapsed'

      # The snapshot's blocks with every reasoning disclosure in the state this
      # browser's first paint needs ({Disclosure.collapse}).
      #
      # Not left to +transcript.js+: a module script runs after the first paint,
      # so a fold done there is a visible one — and nothing in the suite can go
      # red for it, there being no JS runtime here.
      #
      # @param blocks [Array<Transcript::Block>] the transcript as stored
      # @param thinking [String] one of {THINKING}
      # @return [Array<Transcript::Block>]
      def disclosed(blocks, thinking)
        return blocks if thinking == 'expanded'

        blocks.map { |block| block.with(html: Disclosure.collapse(block.html)) }
      end

      # The message's images, checked against the caps and typed by their bytes.
      #
      # Halts rather than dropping a bad one: the browser checks the same caps
      # before sending, so a refusal here means a client that skipped them,
      # and sending the rest without a word would show the model less than the
      # user meant.
      #
      # @param parts [Array<Hash>, Hash, nil] Rack's multipart file hashes for
      #   +attachments[]+ (+:filename+, +:tempfile+, …)
      # @return [Array<Conversations::Upload>]
      def uploads_from(parts)
        parts = [parts] if parts.is_a?(Hash)
        parts = Array(parts)
        halt 422, "at most #{MAX_IMAGES} images per message" if parts.size > MAX_IMAGES
        parts.map do |part|
          file = part.is_a?(Hash) && part[:tempfile]
          halt 422, 'attachments must be files' unless file
          halt 413, "an image may be at most #{MAX_IMAGE_BYTES / 1024 / 1024} MiB" if file.size > MAX_IMAGE_BYTES

          file.rewind
          Conversations::Upload.from(filename: part[:filename], bytes: file.read) ||
            halt(415, 'attachments must be PNG, JPEG, GIF or WebP images')
        end
      end

      # Write a message's images into its conversation's folder, outside the
      # domain: up to {MAX_BODY_BYTES} of disk is no task's business
      # (`D_global_monitor`).
      #
      # The conversation is resolved in a task of its own, so a delete can
      # land between this and the submit; that is what {#discard_stash} is for.
      #
      # @param id [String, nil] the conversation the message is for
      # @param uploads [Array<Conversations::Upload>]
      # @return [Pikuri::Conversations::Store::Entry] the one written to
      def stash_uploads(id, uploads)
        conversation = settings.big_app_lock.run { open_conversation(id).conversation }
        settings.store.stash(conversation, uploads.map(&:to_attachment))
        conversation
      rescue SystemCallError => e
        PikuriWebUI.logger.error("stashing images for #{conversation&.id} failed (#{e.class}: #{e.message})")
        halt 500, 'the images could not be saved'
      end

      # Remove what {#stash_uploads} wrote for a conversation that was deleted
      # before its message could land. Safe because the submit answered that it
      # no longer exists: nothing else will ever write that folder.
      #
      # @param conversation [Pikuri::Conversations::Store::Entry]
      # @return [void]
      def discard_stash(conversation)
        settings.store.delete(conversation)
      rescue SystemCallError => e
        PikuriWebUI.logger.error("removing images of deleted #{conversation.id} failed (#{e.class}: #{e.message})")
      end

      # Resolve an id and open it, 404ing on anything not listed — which is what
      # keeps user input from ever becoming a path.
      #
      # One registry call, not a resolve followed by an open: a delete landing
      # between the two would be answered by minting a runner for the folder it
      # just removed (`D_delete_no_undo`).
      #
      # @param id [String, nil]
      # @return [Agents::Runner]
      def open_conversation(id)
        runner = settings.registry.open_id(id.to_s)
        halt 404, 'no such conversation' if runner.nil?

        runner
      end

      # Release the +TCP_CORK+ Puma puts on a response's socket, so each SSE
      # frame leaves as it is written.
      #
      # Puma corks when it starts writing a response and uncorks when the body
      # ends — which an event stream never does. Corked, Linux holds a short
      # write for up to 200 ms, so every frame reached the browser that late:
      # a sent message, a status change, and the streamed deltas, batched to
      # ~5 updates a second against the 15 fps pikuri coalesces to. Uncorking
      # once is enough; Puma corks again only for the next response.
      #
      # Mirrors Puma's own +uncork_socket+, so a TLS socket is reached through
      # +to_io+, and a host or spec without Puma's socket is left alone.
      #
      # @param socket [Object, nil] +env['puma.socket']+
      # @return [void]
      def uncork(socket)
        return unless defined?(Socket::TCP_CORK)

        io = socket.respond_to?(:to_io) ? socket.to_io : nil
        io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_CORK, 0) if io.is_a?(TCPSocket)
      rescue IOError, SystemCallError => e
        PikuriWebUI.logger.debug("uncorking the event stream failed (#{e.class}: #{e.message})")
      end

      # What a just-connected tab needs to be level with the server: the whole
      # transcript as one +snapshot+ frame, an ordered block list the browser
      # lays over what its page already rendered, dropping whatever the list
      # does not name. Sent even when empty — that drop is the only way a tab
      # which rendered its page just before a wipe loses the blocks the server
      # has forgotten.
      #
      # Runs in the same task as {Broadcaster#subscribe}, so no server-side gap
      # remains between the two. The duplicate tolerance survives regardless,
      # because the page render and this connection are still two HTTP requests
      # (`D_subscribe_then_snapshot`): blocks are addressed by id, and
      # {Transcript#clear} keeps its id counter so no id is ever reused.
      #
      # Never a +reset+ followed by a +block+ each. The browser paints between
      # event dispatches, so emptying the pane and refilling it blinks a
      # transcript this tab has already rendered correctly — and no spec here
      # can go red for it, there being no JS runtime in the suite.
      #
      # @param conversation [String] id; one nobody has opened has no transcript
      #   and needs no catch-up
      # @return [Array<String>] formatted SSE frames
      def catch_up_frames(conversation)
        runner = settings.registry.resident(conversation)
        return [] if runner.nil?

        blocks = runner.transcript.to_a.map { |b| { id: b.id, kind: b.kind, html: b.html } }
        [settings.broadcaster.frame(event: :snapshot, data: { blocks: blocks })]
      end

      # The sidebar's model.
      #
      # +current+ is the row this tab has open (per tab, from the URL); +busy+ is
      # whether that conversation has a turn in flight (server-wide). They are independent: a turn running in
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
            ago: Util::RelativeTime.humanize(c.created_at),
            current: c.id == viewing,
            busy: row[:busy],
            supported: c.supported
          }
        end
      end
    end
  end
end
