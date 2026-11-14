# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-conversations'

module PikuriWebUI
  module Agents
    # This shell's side of one live conversation: the gem's
    # +Pikuri::Conversations::Conversation+ runs the agent and its turns, and
    # the runner is what it reports to — the envelope on disk, the transcript,
    # the status bar. {Conversations::Registry} holds one per conversation
    # anyone has opened.
    #
    #   runner = Runner.new(conversation: entry, store:, ...).open(live, transport:)
    #   runner.submit('hello')          # => :started, or :injected while a turn runs
    #   runner.select_model('Remote')   # => :selected — the next turn's model
    #   runner.cancel
    #   runner.discard!                 # deleted: retire it, or false while a turn runs
    #
    # The runner is the conversation's one listener: the gem's own events
    # (+Pikuri::Conversations::Event+) land here and move the status bar, the
    # title and the sidebar's busy dot; the agent's pass through to
    # +agent_listeners+, the transcript's renderer among them.
    #
    # == Persistence
    #
    # {#persist} is the gem's +on_turn_end+, run on the turn's thread before the
    # conversation goes idle — so "idle" means "saved". A process killed
    # mid-turn loses that turn; accepted (single user, rare restarts).
    #
    # == The title
    #
    # A conversation still carrying its start stamp is opened +untitled: true+,
    # and the gem's titler names it once its first turn here has ended —
    # a stored one included, so one only read is never titled. The title lands
    # through the store's +retitle+ and the envelope this runner
    # holds, together.
    #
    # Server-side of the pikuri seam, so it names pikuri types freely
    # (+D_pikuri_free_core+).
    #
    # == Threading
    #
    # Guarded by {BigAppLock}: every public method but {#on_event} and
    # {#persist} must run inside a task. Those two are called by the gem from
    # its own threads — the turn's, the title's, or the request thread whose
    # task made the call that fired them — and open a task themselves when they
    # touch shared state.
    #
    # The domain is the *outermost* lock: a task may call into the gem
    # (+Conversation#status+ takes the gem's lock), and the gem never calls out
    # under its own.
    class Runner < Pikuri::Agent::Listener::Base
      # Every +Pikuri::Conversations::Event+ variant: what this runner handles
      # itself rather than forwarding to the agent's listeners.
      #
      # @return [Array<Class>]
      CONVERSATION_EVENTS = Pikuri::Conversations::Event.constants
                                                        .map { |name| Pikuri::Conversations::Event.const_get(name) }
                                                        .freeze

      # What the status bar's state segment says for each gem state.
      #
      # @return [Hash{Symbol => String}]
      STATE_NAMES = {
        new: 'not started', booting: 'starting', idle: 'idle', running: 'running', closed: 'deleted'
      }.freeze

      # @param conversation [Pikuri::Conversations::Store::Entry] the one this
      #   runner is for
      # @param store [Pikuri::Conversations::Store] where turns are saved and
      #   titles land
      # @param catalog [ModelCatalog] the connections {#select_model} picks from,
      #   and what names a transport
      # @param broadcaster [Web::Broadcaster] SSE fan-out for +status+ events
      # @param transcript [Web::Transcript] this conversation's blocks
      # @param listener [Web::SseListener] the transcript's renderer, fed directly
      #   by {#open}'s replay
      # @param agent_listeners [Array<Pikuri::Agent::Listener::Base>] where the
      #   agent's events go: +listener+ behind a delta rate-limiter, and
      #   +token_log+
      # @param token_log [Pikuri::Agent::Listener::TokenLog] the status bar's
      #   context readout; the constructor claims its +on_status_line+ slot
      # @param lock [BigAppLock]
      # @param missing_connection [String, nil] +"model @ server"+ when the
      #   connection this conversation saved has left the config file and it was
      #   opened on {ModelCatalog#primary} instead. Reported until a save or a
      #   pick makes it untrue
      def initialize(conversation:, store:, catalog:, broadcaster:, transcript:, listener:,
                     agent_listeners:, token_log:, lock:, missing_connection: nil)
        super()
        @conversation = conversation
        @store = store
        @catalog = catalog
        @broadcaster = broadcaster
        @transcript = transcript
        @listener = listener
        @agent_listeners = agent_listeners
        @token_log = token_log
        @lock = lock
        @missing_connection = missing_connection
        @live = nil
        @discarded = false
        @announced_busy = false

        # Without it, a multi-step turn's token numbers would all land at its
        # end: nothing else sends a status frame between a turn's start and end.
        @token_log.on_status_line = ->(_id, _line) { @lock.run { broadcast_status } }
      end

      # @return [Pikuri::Conversations::Store::Entry] replaced, not mutated, when
      #   a title lands
      attr_reader :conversation

      # @return [Web::Transcript] this conversation's rendered blocks
      attr_reader :transcript

      # Replay what is stored into the transcript, then open the live
      # conversation on +transport+, resuming that history. The agent boots on a
      # thread of the gem's own.
      #
      # A stored history that cannot be read is logged and opened empty; the
      # next turn's save then replaces it.
      #
      # @param conversations [Pikuri::Conversations] the process's live list
      # @param transport [Pikuri::Agent::ChatTransport] the connection to start on
      # @return [self]
      def open(conversations, transport:)
        @lock.assert!
        history = stored_history
        Conversations::HistoryReplay.events(history).each { |event| @listener.on_event(event) } if history
        @live = conversations.open(id: @conversation.id, transport: transport, listener: self, history: history,
                                   untitled: @store.stamp_titled?(@conversation))
        broadcast_status
        self
      end

      # Route one user message: start a turn, or inject into the running one.
      # Never refused for being busy.
      #
      # Images ride along as pikuri attachments, already on disk (the store's
      # +stash+) so the block that shows them can link to them.
      #
      # @param message [String] blank only when +uploads+ is not
      # @param uploads [Array<Conversations::Upload>] the message's images
      # @return [Symbol] +:started+, +:injected+, +:refused+ (the next turn's
      #   model is known to take no images) or +:discarded+ (deleted)
      def submit(message, uploads: [])
        @lock.assert!
        return :discarded if @discarded

        outcome = @live.submit(message, attachments: uploads.map(&:to_attachment))
        outcome == :ignored ? :started : outcome
      rescue Pikuri::Agent::UnsupportedAttachmentError => e
        PikuriWebUI.logger.info("conversation #{@conversation.id}: #{e.message}")
        :refused
      end

      # Put this conversation on another connection from its next turn. Picking
      # the one it is on undoes a pick.
      #
      # @param name [String] a {ModelCatalog} connection name
      # @return [Symbol] +:selected+, +:unknown+ for a name this config lacks,
      #   or +:discarded+ once deleted
      def select_model(name)
        @lock.assert!
        choice = @catalog.find(name)
        return :unknown if choice.nil?
        return :discarded if @discarded || @live.switch_model(choice.transport) == :discarded

        # Choosing supersedes being told what was lost.
        @missing_connection = nil
        broadcast_status
        :selected
      end

      # The connection the *next* turn talks to — intent rather than reality, so
      # "pick a model, then start a fresh chat" hands the new one the pick.
      #
      # @return [Array(String, String)] the +[model, server]+ pair, as the store
      #   records it and {ModelCatalog#resolve} matches it
      def model
        @lock.assert!
        transport = @live.status.next_model
        [transport.model, transport.api_base]
      end

      # Retire this runner for good, and close its agent. Refused while a turn
      # runs, so a deleter asks for the folder and the turn in one move:
      #
      #   return :busy if runner && !runner.discard!   # then remove the folder
      #
      # A boot under way is cancelled instead: it has saved nothing, and once
      # closing the gem never saves again. A turn starting in the instant
      # between the state read and that forced close is cancelled the same way,
      # unsaved.
      #
      # @return [Boolean] false when a turn is in flight
      def discard!
        @lock.assert!
        return true if @discarded

        outcome = @live.close
        outcome = @live.close(force: true) if outcome == :busy && @live.status.state == :booting
        return false if outcome == :busy

        @discarded = true
      end

      # Stop this conversation's turn, or its boot. Undelivered injections stay
      # pending for the next send.
      #
      # @return [void]
      def cancel
        @lock.assert!
        @live.cancel
        nil
      end

      # @return [Boolean] whether a turn is in flight — running, or a boot with
      #   a message waiting for it
      def busy?
        @lock.assert!
        busy_status?(@live&.status)
      end

      # Status payload shared by SSE +status+ events and the initial page render.
      #
      #   { state: 'running', busy: true, pending: 2,
      #     tokens: 'ctx 7.4k/64k (12%)', tokens_detail: 'msg #2  Δ+1.6k  ↑1.0k  ↓0.6k',
      #     model: 'Local Qwen 3.6', model_pending: 'Remote Qwen', model_missing: nil }
      #
      # @return [Hash] +pending+ counts the injections not yet delivered;
      #   +tokens+ / +tokens_detail+ are the context readout's headline and
      #   muted tail ('' until measured); +model+ is what the agent is on now
      def status_data
        @lock.assert!
        status = @live.status
        {
          state: STATE_NAMES.fetch(status.state),
          busy: busy_status?(status),
          pending: status.pending,
          tokens: token_headline(status.model.context_window),
          tokens_detail: token_detail,
          model: @catalog.name_for(status.model),
          model_pending: same_connection?(status.model, status.next_model) ? nil : @catalog.name_for(status.next_model),
          model_missing: @missing_connection
        }
      end

      # The gem's events update the page; the agent's go to +agent_listeners+.
      #
      # @param event [Data] an agent or conversation event
      # @return [void]
      def on_event(event)
        case event
        when *CONVERSATION_EVENTS then conversation_event(event)
        else @agent_listeners.each { |listener| listener.on_event(event) }
        end
      end

      # Save the conversation as a turn left it — the gem's +on_turn_end+, on the
      # turn's thread. A history with no messages gets no folder.
      #
      # Logged, not raised: a full disk must not take the conversation down.
      #
      # @param history [Pikuri::Agent::History]
      # @return [void]
      def persist(history)
        @lock.run do
          next if @discarded || history.messages.empty?

          transport = @live.status.model
          @store.save(@conversation, history, model: transport.model, server: transport.api_base)
          # The envelope now holds the fallback, so the note describes nothing.
          @missing_connection = nil
        end
      rescue StandardError => e
        PikuriWebUI.logger.error("saving conversation #{@conversation.id} failed (#{e.class}: #{e.message})")
      end

      # @return [String]
      def to_s = "Runner(#{@conversation.id})"

      private

      # @param event [Data] a +Pikuri::Conversations::Event+
      # @return [void]
      def conversation_event(event)
        case event
        in Pikuri::Conversations::Event::Titled(title:)
          @lock.run { land_title(title) }
        in Pikuri::Conversations::Event::Closed
          # Only a delete closes one, and the deleting task said everything.
        in Pikuri::Conversations::Event::TurnEnded(outcome: :failed, error:)
          PikuriWebUI.logger.error("conversation #{@conversation.id}: turn failed (#{error.class}: #{error.message})")
          @lock.run { broadcast_status }
        in Pikuri::Conversations::Event::BootFailed(error:)
          PikuriWebUI.logger.error("conversation #{@conversation.id}: agent failed to boot " \
                                   "(#{error.class}: #{error.message})")
          @lock.run { broadcast_status }
        else
          @lock.run { broadcast_status }
        end
      end

      # @param status [Pikuri::Conversations::Status, nil]
      # @return [Boolean]
      def busy_status?(status)
        return false if status.nil?

        status.state == :running || (status.state == :booting && status.pending.positive?)
      end

      # @param one [Pikuri::Agent::ChatTransport]
      # @param other [Pikuri::Agent::ChatTransport]
      # @return [Boolean] by +[model, api_base]+, since what the probe learnt
      #   may differ between the two
      def same_connection?(one, other)
        one.model == other.model && one.api_base == other.api_base
      end

      # Both halves of a rename in one task — the envelope on disk *and* the one
      # held here, which the next {#persist} writes the title from.
      #
      # @param title [String] capped and sanitized by the gem's titler
      # @return [void]
      def land_title(title)
        return if @discarded

        @conversation = @store.retitle(@conversation, title)
        @broadcaster.broadcast(event: :conversations, data: {})
        nil
      end

      # @return [Pikuri::Agent::History, nil] nil when nothing is stored, or what
      #   is stored cannot be read — a file someone edited, a half-written save
      def stored_history
        return nil unless (@conversation.dir / 'history.json').file?

        @store.history(@conversation)
      rescue Pikuri::Conversations::HistoryFile::Error, SystemCallError => e
        PikuriWebUI.logger.error("loading conversation #{@conversation.id} failed (#{e.class}: #{e.message})")
        nil
      end

      # Nothing to say before {#open} has the live conversation: the gem's
      # +Booting+ arrives while +Conversations#open+ is still returning.
      #
      # @return [void]
      def broadcast_status
        return if @live.nil?

        @broadcaster.broadcast(event: :status, data: status_data, conversation: @conversation.id)
        announce_busy_change
      end

      # Tell *every* tab the sidebar changed when this conversation starts or
      # stops working: the per-row dot is the only sign a conversation you are
      # not looking at is busy, and it is server-rendered. Only on the
      # transition — a status frame fires per injection count.
      #
      # @return [void]
      def announce_busy_change
        now_busy = busy?
        changed = @announced_busy != now_busy
        @announced_busy = now_busy
        @broadcaster.broadcast(event: :conversations, data: {}) if changed
        nil
      end

      # The status bar's context headline, off TokenLog's own number and the cap
      # the conversation knows — stated in config.toml, or learnt by the gem's
      # probe.
      #
      #   'ctx 7.4k/64k (12%)'   # cap known
      #   'ctx 7.4k'             # no cap
      #   ''                     # nothing measured yet
      #
      # @param cap [Integer, nil]
      # @return [String]
      def token_headline(cap)
        return '' if @token_log.status_line.empty?

        used = @token_log.context_window_size
        return "ctx #{format_k(used)}" if cap.to_i.zero?

        "ctx #{format_k(used)}/#{format_k(cap)} (#{(used * 100.0 / cap).round}%)"
      end

      # TokenLog's line with its +ctx=+ segment lifted out, leaving the per-turn
      # tail that sits muted beside {#token_headline}:
      #
      #   'msg #2: ctx=8.4k  Δ+1.6k  ↑1.0k  ↓0.6k' -> 'msg #2  Δ+1.6k  ↑1.0k  ↓0.6k'
      #   'restored: ctx=8.2k'                     -> 'restored'
      #
      # @return [String]
      def token_detail
        @token_log.status_line.to_s.sub(/:?\s*ctx=\S+/, '')
      end

      # 1024-scaled with a +k+ suffix, as pikuri sizes tokens, minus a trailing
      # +.0+ (+64.0k+ reads as a precision the cap does not have).
      #
      # @param count [Integer]
      # @return [String]
      def format_k(count)
        format('%.1fk', count / 1024.0).sub('.0k', 'k')
      end
    end
  end
end
