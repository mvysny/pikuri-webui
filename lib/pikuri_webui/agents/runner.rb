# frozen_string_literal: true

require 'pikuri-core'

module PikuriWebUI
  module Agents
    # One conversation's agent, transcript and turn lifecycle. A runner *is* a
    # conversation — the one it was built for, for as long as it exists — so
    # there is no switching here, and no "live" conversation to switch away
    # from. {Conversations::Registry} holds one per conversation anyone has opened.
    #
    #   runner.restore!               # replay what is on disk, once, at mint time
    #   runner.submit('hello')        # => :started (queued on the executor) or :injected
    #   runner.submit('', uploads: [upload])   # an image-only message
    #   runner.select_model('Remote') # => :selected — applied at the top of the next turn
    #   runner.state                  # => :idle | :queued | :running
    #   runner.cancel                 # dequeue if queued, stop at a tool boundary if running
    #   runner.discard!               # the conversation was deleted; retire this runner
    #
    # {#submit} is the single entry point for user text, and it never refuses
    # while the conversation exists:
    #
    # - Idle → post a job running +Pikuri::Agent#run_loop(user_message:)+ on the
    #   shared executor. The listener stack renders everything the loop emits;
    #   nothing here touches the transcript.
    # - Busy → +Pikuri::Agent::Control::Interloper#inject_user_message+. The
    #   agent drains the queue at turn start and once each tool batch completes,
    #   emitting +UserTurn(mid_loop: true)+, so the injection renders through the
    #   same listener path as a normal turn. An injection placed while the model
    #   is mid-response still waits for that boundary, which is why the input
    #   stays enabled while busy and the status bar carries the queued count.
    #
    # A submit landing between the loop's last completion and the state reset
    # injects into a turn that is over, and no drain is coming for it. The turn
    # job answers that on its way out: a queue left non-empty by a turn that
    # returned normally claims the next turn on the spot, a bare +run_loop+ whose
    # entry drain is the delivery.
    #
    # == Idle, queued, running
    #
    # +:queued+ is the gap between +#submit+ posting the job and the job taking a
    # thread — instant under an unbounded executor, real under a bounded one, so
    # the state stays modelled either way.
    #
    # It is *not* where a turn waits for the server. That wait is pikuri's
    # per-server permit, taken inside +run_loop+ for the length of one HTTP
    # request (+D_upstream_request_throttle+), and a turn parked on one reads
    # +:running+ here — so "thinking" can mean "queued behind another
    # conversation's completion", and nothing in this class can tell the
    # difference.
    #
    # Cancelling a +:queued+ turn needs nothing from pikuri: the job checks on
    # entry whether it was cancelled while waiting and returns without starting.
    # Cancelling a +:running+ one is +Cancellable+'s next-tool-boundary stop — a
    # turn parked on a permit included, because that wait polls it too.
    #
    # == Which model, and when
    #
    # {#select_model} parks a transport; +run_loop+ applies it at the top of the
    # next turn and nothing else can — pikuri confines the switch there because
    # the chat is single-thread-confined, and only this state machine knows
    # nothing is in flight. So a pick while busy is naturally "next turn", the
    # same wait the Interloper's queued count already makes legible.
    #
    # Three questions, three answers, and they must not collapse into one:
    #
    #   conversation.model_at_mint   # what disk said when this runner was minted
    #   runner.model                 # intent — the pair the next turn will use
    #   status_data[:model]          # reality — read off the agent's transport
    #
    # Reality is free: +apply_transport!+ assigns the agent's transport only
    # after the switch succeeds, so the status bar can never advertise a model
    # the switch did not reach and nothing here subscribes to +ModelSwitched+.
    # The pending slot is drained where it is handed to +run_loop+ rather than
    # when the switch lands, which is what keeps that true of a failed switch
    # too — at the cost of losing the pick when a turn dies before its top.
    #
    # == Persistence
    #
    # Saves happen at *turn end*, from the turn job's ensure, so a history is
    # never exported mid-+complete+ and {#busy?} staying true until the save
    # lands makes "idle" mean "saved". The cost is that a process killed mid-turn
    # loses that turn — accepted (single user, rare restarts) — and saving per
    # *message* instead would not fix it: there is no event to hang that on,
    # because +Event::ToolResult+ fires before ruby_llm appends the tool message
    # and nothing fires when it lands.
    #
    # == The title
    #
    # A conversation is named from its opening message, wherever that message
    # turns up: {#submit} posts a {Titler} job *beside* the turn — never inside
    # it — for a fresh one, and {#restore!} posts the same job for a stored one
    # that is still stamp-titled, so a conversation older than the feature is
    # named the first time anyone opens it. Either way the answer lands through
    # a task that rewrites the envelope and {#conversation} together.
    #
    # No +[titler]+ configured, a model that answers nothing usable, or a raise
    # anywhere in that job all leave the start stamp, and none of them can reach
    # the turn.
    #
    # Server-side of the pikuri seam, so it names pikuri types freely
    # (`D_pikuri_free_core`).
    #
    # == Threading
    #
    # Guarded by {BigAppLock}: every public method must run inside a task. Who
    # enters — route tasks ({Web::App}), the turn job's bookkeeping brackets
    # (+run_turn+ opens its own tasks around +run_loop+, which itself runs
    # off-domain), and pikuri's two callbacks — the Interloper's +on_change+ and
    # TokenLog's +on_status_line+ — which open a task from whichever thread fired
    # them, the loop thread included. Composing a status payload and
    # publishing it happen inside one task, so a frame can never overtake a
    # newer one.
    #
    # One ordering rule must survive any edit: the domain is the *outermost*
    # lock. A task may call into pikuri (+Interloper#pending?+,
    # +Cancellable#cancel!+), and pikuri never holds its own lock when calling
    # back — +on_change+ fires outside the Interloper's, and TokenLog holds no
    # lock at all. Consistent order, so no ABBA deadlock.
    class Runner
      # @param conversation [Conversations::Store::Conversation] the one this runner
      #   is for, fixed for its lifetime
      # @param agent [Pikuri::Agent] fully wired agent (listeners, tools,
      #   interloper:, cancellable: — built by the factory in bin/pikuri-webui-chat)
      # @param interloper [Pikuri::Agent::Control::Interloper] the same
      #   instance passed to the agent's +interloper:+ kwarg
      # @param cancellable [Pikuri::Agent::Control::Cancellable] the same
      #   instance passed to the agent's +cancellable:+ kwarg
      # @param broadcaster [Web::Broadcaster] SSE fan-out for +status+ events
      # @param conversations [Conversations::Store] where turns get saved
      # @param transcript [Web::Transcript] this conversation's blocks, which +GET
      #   /c/:id+ renders as its snapshot
      # @param listener [Web::SseListener] the transcript's renderer, fed directly by
      #   {#restore!}'s replay — the agent's own listener stack wraps it in a
      #   delta rate-limiter that a replay has nothing to say to
      # @param executor [Concurrent::ExecutorService] shared by every runner: the
      #   admission gate that keeps concurrent turns from outnumbering the
      #   inference server's slots (+--turns+). Its pool size is that cap and
      #   nothing else — this runner is single-writer over its own conversation
      #   at any size, because {#submit} injects rather than starting a second
      #   turn
      # @param token_log [Pikuri::Agent::Listener::TokenLog, nil] when present, its
      #   +status_line+ rides along in every status event and a freshly measured
      #   one pushes an event of its own — the constructor claims the log's
      #   +on_status_line+ slot
      # @param catalog [ModelCatalog] the connections {#select_model} may pick
      #   from, and what turns the agent's transport into a display name
      # @param titler [Titler, nil] names this conversation from its opening
      #   message, on its own executor job; +nil+ — no +[titler]+ configured —
      #   leaves every conversation on its start stamp
      # @param missing_connection [String, nil] +"model @ server"+ when this
      #   conversation was minted on {ModelCatalog#primary} because the
      #   connection it had saved has left the config file. Reported until a
      #   save or a pick makes it untrue, after which it describes nothing
      # @param lock [BigAppLock] the domain every call must be inside
      def initialize(conversation:, agent:, interloper:, cancellable:, broadcaster:,
                     conversations:, transcript:, listener:, executor:, catalog:,
                     lock:, token_log: nil, titler: nil, missing_connection: nil)
        @conversation = conversation
        @agent = agent
        @interloper = interloper
        @cancellable = cancellable
        @broadcaster = broadcaster
        @conversations = conversations
        @transcript = transcript
        @listener = listener
        @executor = executor
        @catalog = catalog
        @token_log = token_log
        @titler = titler
        @missing_connection = missing_connection
        @lock = lock
        @state = :idle
        @abandon = false
        @discarded = false
        @announced_busy = false
        @pending = nil
        @titling = false

        # Claims the interloper's single on_change slot. Without it the
        # queued-count badge only moves when a request happens to hit {#submit}
        # or a turn ends — the agent's own mid-loop drain would leave the browser
        # showing a stale "2 queued" for the rest of the turn. Opens a task
        # because the drain fires it on the worker, mid-+run_loop+, off-domain;
        # fired from inside {#submit}'s own task it just re-enters.
        @interloper.on_change = ->(_count) { @lock.run { broadcast_status } }

        # The same claim on TokenLog's +on_status_line+ slot, task and all: the
        # readout is composed when a frame goes out, and between a turn's start and
        # its end nothing sends one — so a multi-step loop's numbers would
        # otherwise all land at the end, at once.
        @token_log&.on_status_line = ->(_id, _line) { @lock.run { broadcast_status } }
      end

      # @return [Conversations::Store::Conversation] replaced, not mutated, when a
      #   title lands — so a reader always sees one consistent frozen envelope,
      #   at worst the pre-title one. The +conversations+ SSE event that follows
      #   the landing is what makes every tab re-fetch.
      attr_reader :conversation

      # @return [Web::Transcript] this conversation's rendered blocks
      attr_reader :transcript

      # Replay what is stored for this conversation into the agent and the
      # transcript. Called once, when the registry mints this runner.
      #
      # A conversation with nothing on disk (brand new, or never saved because it
      # holds no messages) restores to empty, which is already correct.
      #
      # Also where a conversation older than the titling feature gets a name: its
      # opener is in the history already in hand, so the retro-title costs no
      # second read and reaches exactly the conversations someone actually opens.
      #
      # @return [Boolean] whether a stored history was found and loaded
      def restore!
        @lock.assert!
        history = stored_history
        return false if history.nil?

        @agent.load_history!(history)
        Conversations::HistoryReplay.events(history).each { |event| @listener.on_event(event) }
        maybe_title(first_user_message(history))
        true
      end

      # Route one user message: start a turn or inject into the running one.
      #
      # Never refuses for being busy: a turn submitted while the executor's slots
      # are all taken is queued, not rejected — the wait is what {#state}
      # reports. +:discarded+ is not a refusal either, but the answer that this
      # conversation no longer exists ({#discard!}).
      #
      # Images ride along as pikuri attachments, already on disk
      # ({Conversations::Store#stash}) so the block that shows them can link to
      # them. A model known to be blind refuses them inside +run_loop+, which
      # this logs like any other failed turn; mid-loop, pikuri withholds them
      # with a note instead.
      #
      # @param message [String] user text — blank only when +uploads+ is not
      #   empty (Web::App rejects the rest before calling; Interloper/run_loop
      #   double-check)
      # @param uploads [Array<Conversations::Upload>] the message's images
      # @return [:started, :injected, :discarded]
      def submit(message, uploads: [])
        @lock.assert!
        return :discarded if @discarded

        attachments = uploads.map(&:to_attachment)
        if busy?
          # An injection landing after the turn ended is delivered by the
          # restart {#finish_turn} claims, not stranded.
          @interloper.inject_user_message(message, attachments: attachments)
          broadcast_status
          :injected
        else
          @abandon = false
          @state = :queued
          @executor.post { run_turn(message, attachments) }
          broadcast_status
          # After the turn is posted, so a title never delays an answer. An
          # image-only opener has no words to name it by.
          maybe_title(message) unless message.strip.empty?
          :started
        end
      end

      # Put this conversation on another connection, from the top of its next
      # turn.
      #
      #   runner.select_model('Remote Qwen')   # => :selected
      #
      # Never applied on the spot: see the class header. Picking the connection
      # the agent is already on clears any pending selection rather than parking
      # a switch that would no-op, so the status bar's arrow means "not yet",
      # never "no change".
      #
      # @param name [String] a {ModelCatalog} connection name
      # @return [:selected, :unknown, :discarded] +:unknown+ for a name this
      #   config does not have; +:discarded+ once the conversation is deleted
      def select_model(name)
        @lock.assert!
        choice = @catalog.find(name)
        return :unknown if choice.nil?
        return :discarded if @discarded

        @pending = choice.transport == @agent.transport ? nil : choice.transport
        # Choosing supersedes being told what was lost.
        @missing_connection = nil
        broadcast_status
        :selected
      end

      # The connection this conversation will talk to *next* — the pick if one
      # is parked, what the agent is on otherwise.
      #
      #   runner.model   # => ['qwen3.6', 'http://localhost:8080/v1']
      #
      # Intent rather than reality on purpose: a pick made on a busy conversation
      # and immediately followed by "new conversation" should hand the new one
      # what the user asked for, not what the old one is still finishing on.
      #
      # @return [Array(String, String)] the +[model, server]+ pair, in the form
      #   {Conversations::Store} stores and {ModelCatalog#resolve} matches
      def model
        @lock.assert!
        transport = @pending || @agent.transport
        [transport.model, transport.api_base]
      end

      # Retire this runner for good: it will start no turn, inject nothing, take
      # no model and write no folder again. One-way, and refused while a turn is
      # in flight — so a deleter asks for the folder and the turn in one move:
      #
      #   return :busy if runner && !runner.discard!   # then remove the folder
      #
      # Deliberately a *claim*, not a {#busy?} read followed by a caller-side
      # flag: the busy check and the retirement are one method, so they share a
      # task — either {#submit} claims the turn first and this refuses, or this
      # wins and {#submit} answers +:discarded+. No interleaving lets both
      # proceed — which is why {#persist} carries no check of its own.
      #
      # Not +@abandon+, which drops one *queued turn* and is reset by the next
      # {#submit}. This is about the conversation, and permanent.
      #
      # @return [Boolean] false when a turn is queued or running, and the caller
      #   must refuse the delete; true once nothing will ever run here again
      def discard!
        @lock.assert!
        return false if busy?

        @discarded = true
        true
      end

      # @return [Boolean] whether a delete has retired this runner
      def discarded?
        @lock.assert!
        @discarded
      end

      # Stop this conversation's turn: drop it before it starts if it is still
      # waiting for the executor, or ask the agent to stop at the next tool
      # boundary if it is already running. No-op when idle.
      #
      # @return [void]
      def cancel
        @lock.assert!
        @abandon = true if @state == :queued
        @cancellable.cancel! if @state == :running
        broadcast_status
        nil
      end

      # @return [:idle, :queued, :running] +:queued+ means the job is posted but
      #   the executor's slots are all taken by other conversations
      def state
        @lock.assert!
        @state
      end

      # @return [Boolean] whether a turn is posted and not yet finished
      def busy?
        @lock.assert!
        @state != :idle
      end

      # Status payload shared by SSE +status+ events and the initial page render.
      #
      #   { state: :running, busy: true, pending: 2,
      #     tokens: 'ctx 7.4k/64k (12%)', tokens_detail: 'msg #2  Δ+1.6k  ↑1.0k  ↓0.6k',
      #     model: 'Local Qwen 3.6', model_pending: 'Remote Qwen', model_missing: nil }
      #
      # @return [Hash] +pending+ is the count of queued mid-loop injections;
      #   +tokens+ and +tokens_detail+ are the two halves of the context-window
      #   readout, the status bar's headline and its muted tail (both '' when
      #   nothing is measured yet); +model+ is what the agent is on *now*;
      #   +model_pending+ and +model_missing+ are nil in the ordinary case (see
      #   {#select_model} and the +missing_connection:+ constructor argument)
      def status_data
        @lock.assert!
        {
          state: @state,
          busy: busy?,
          pending: @interloper.size,
          tokens: token_headline,
          tokens_detail: token_detail,
          model: @catalog.name_for(@agent.transport),
          model_pending: @pending && @catalog.name_for(@pending),
          model_missing: @missing_connection
        }
      end

      # The advisory tool-exposure map, handed out unrendered — callers render
      # it. A +#trifecta_html+ convenience here would point {Agents} at {Web},
      # the one direction that stays closed.
      #
      # @return [Pikuri::Trifecta::Report]
      def trifecta = @agent.trifecta

      private

      # The executor job's body: one turn, then the save. The bookkeeping
      # brackets are tasks; +run_loop+ itself — the LLM round-trips, the tools —
      # runs off-domain.
      #
      # A StandardError out of +run_loop+ (transport hiccup, tool bug) is logged
      # rather than re-raised — an executor swallows a job's exception into a
      # future nobody here holds, so the UI would just look stuck. The ensure
      # broadcasts idle so the browser's input re-enables even on the error path.
      #
      # @param message [String, nil] +nil+ on a restart, where the turn exists
      #   for the Interloper drain +run_loop+ does before its first completion
      # @param attachments [Array<Pikuri::Attachment>] the message's images;
      #   empty on a restart
      # @return [void]
      def run_turn(message, attachments = [])
        # Named for Puma's backtrace-signal dump (`D_puma_thread_dump`): a turn
        # wedged in run_loop then says which conversation it is.
        Thread.current.name = "turn #{@conversation.id}"
        return if @lock.run { claim_running } == :abandoned

        # Both ways into a turn come through here — a submit and the restart
        # {#finish_turn} claims — so one drain covers both; a second entry point
        # into +run_loop+ would silently run the old model.
        @agent.run_loop(user_message: message, attachments: attachments, transport: @lock.run { take_pending })
        completed = true
      rescue StandardError => e
        PikuriWebUI.logger.error("agent run_loop failed (#{e.class}: #{e.message})")
      ensure
        @lock.run { finish_turn(restart: completed) }
        Thread.current.name = 'turn-idle'
      end

      # Save, go idle, and — when the Interloper still holds something — claim
      # the next turn before anyone can observe the gap.
      #
      # Injections are delivered by +run_loop+'s drain and by nothing else, so a
      # message that arrived while this turn was ending would otherwise sit until
      # the user sent another one, with the status bar's queued count stuck above
      # zero over an idle conversation.
      #
      # Only after a turn that returned normally: a cancelled or failed one
      # leaves what is queued for the next {#submit} rather than turning a stop
      # into a fresh round-trip or an unreachable transport into a spin. The
      # queue emptying is likewise +run_loop+'s job — a restart against an agent
      # that does not drain would post turns forever.
      #
      # @param restart [Boolean, nil] whether the turn ran to completion
      # @return [void]
      def finish_turn(restart:)
        persist
        resume = restart && @interloper.pending?
        @state = resume ? :queued : :idle
        broadcast_status
        @executor.post { run_turn(nil) } if resume
        nil
      end

      # Move from queued to running, unless {#cancel} got here first — which is
      # how a queued turn is dropped without the executor needing to support
      # dequeuing.
      #
      # Both paths broadcast. Nothing else reports the start of a turn that
      # really did wait for a slot: {#submit}'s frame says +:running+ only when
      # the executor happens to get here before it.
      #
      # @return [:running, :abandoned]
      def claim_running
        @state = @abandon ? :idle : :running
        broadcast_status
        @abandon ? :abandoned : :running
      end

      # @return [Pikuri::Agent::ChatTransport, nil] the parked selection, taken;
      #   nil — +run_loop+'s "keep the current model" — when there is none
      def take_pending = @pending.tap { @pending = nil }

      # Post a titling job for this conversation's opening message, if it wants
      # one. Called from both places an opener can turn up: {#restore!} with the
      # one on disk, {#submit} with the one starting a fresh conversation.
      #
      # At most once per runner, so a restored conversation is never asked twice
      # and a failure leaves the stamp rather than retrying. Across a restart it
      # does retry, which is what makes a title lost to a server being down
      # recoverable by opening the conversation again.
      #
      # @param opener [String, nil] the opening message; +nil+ when there is none
      #   to read, which titles nothing
      # @return [void]
      def maybe_title(opener)
        return if @titler.nil? || @titling || @discarded || opener.nil?
        return unless @conversations.stamp_titled?(@conversation)

        @titling = true
        @executor.post { run_titling(opener) }
        nil
      end

      # @param history [Pikuri::Agent::History] a restored conversation
      # @return [String, nil] its opening message, or +nil+ for a history that
      #   holds no user text at all
      def first_user_message(history)
        text = history.messages.find { |message| message.role.to_s == 'user' }&.content
        text.is_a?(String) && !text.strip.empty? ? text : nil
      end

      # The titling job's body: ask off-domain, land the answer in a task.
      #
      # Every failure ends here, which is what makes the class header's promise
      # true — so this rescue may never narrow to a specific error class.
      #
      # @param opener [String]
      # @return [void]
      def run_titling(opener)
        Thread.current.name = "title #{@conversation.id}"
        title = @titler.title_for(opener)
        @lock.run { land_title(title) } unless title.nil?
      rescue StandardError => e
        PikuriWebUI.logger.error("titling conversation #{@conversation.id} failed (#{e.class}: #{e.message})")
      ensure
        Thread.current.name = 'turn-idle'
      end

      # Store a landed title and tell every tab the list changed.
      #
      # Both halves of the rename happen here, in one task: the envelope on disk
      # *and* the {#conversation} this runner holds. Writing only disk would be
      # reverted by the next turn-end {#persist}, which writes the title off this
      # object.
      #
      # @param title [String] capped and sanitized by {Titler}
      # @return [void]
      def land_title(title)
        return if @discarded

        @conversation = @conversations.retitle(@conversation, title)
        @broadcaster.broadcast(event: :conversations, data: {})
        nil
      end

      # @return [Pikuri::Agent::History, nil] nil when this conversation has
      #   nothing stored, or when what is stored cannot be read — a file someone
      #   edited or a half-written save is the library's to report and ours to
      #   survive, unlike a raise from the load itself
      def stored_history
        return nil unless (@conversation.dir / 'history.json').file?

        Pikuri::Agent::History.load(@conversation.dir)
      rescue Pikuri::Agent::History::Error, SystemCallError => e
        PikuriWebUI.logger.error("loading conversation #{@conversation.id} failed (#{e.class}: #{e.message})")
        nil
      end

      # Write this conversation to disk. The store owns the how; the only
      # judgement here is that a history with no messages does not deserve a
      # folder.
      #
      # Filesystem failures are logged, not raised — a full disk must not take
      # the conversation down with it, and this runs inside the turn job's
      # ensure, where a raise would escape.
      #
      # @return [void]
      def persist
        history = @agent.export_history
        return if history.messages.empty?

        transport = @agent.transport
        @conversations.save(@conversation, history, model: transport.model, server: transport.api_base)
        # The envelope now holds the fallback, so the note stops describing a
        # deviation from anything stored.
        @missing_connection = nil
      rescue StandardError => e
        PikuriWebUI.logger.error("saving conversation #{@conversation.id} failed (#{e.class}: #{e.message})")
      end

      # @return [void]
      def broadcast_status
        @broadcaster.broadcast(event: :status, data: status_data, conversation: @conversation.id)
        announce_busy_change
      end

      # Tell *every* tab the sidebar changed when this conversation starts or
      # stops working.
      #
      # The status frame above only reaches tabs reading this conversation, and
      # they are precisely the ones that can already see the turn. The per-row
      # dot is the only sign a conversation you are *not* looking at is working,
      # and it is server-rendered, so somebody has to ask for a fresh list.
      #
      # Only on the transition: a status frame fires per streamed injection
      # count, and re-fetching the sidebar for each would be silly.
      #
      # @return [void]
      def announce_busy_change
        now_busy = @state != :idle
        changed = @announced_busy != now_busy
        @announced_busy = now_busy
        @broadcaster.broadcast(event: :conversations, data: {}) if changed
        nil
      end

      # The status bar's context-window headline, off TokenLog's own numbers
      # rather than its formatted line — the percentage is ours, no pikuri shell
      # shows one.
      #
      #   'ctx 7.4k/64k (12%)'   # cap known
      #   'ctx 7.4k'             # no cap reached us
      #   ''                     # nothing measured yet
      #
      # @return [String]
      def token_headline
        return '' if @token_log.nil? || @token_log.status_line.empty?

        used = @token_log.context_window_size
        cap = @token_log.context_window_cap.to_i
        return "ctx #{format_k(used)}" if cap.zero?

        "ctx #{format_k(used)}/#{format_k(cap)} (#{(used * 100.0 / cap).round}%)"
      end

      # TokenLog's line with its own +ctx=+ segment lifted out, leaving the
      # per-turn tail that sits muted beside {#token_headline}:
      #
      #   'msg #2: ctx=8.4k/32.0k  Δ+1.6k  ↑1.0k  ↓0.6k' -> 'msg #2  Δ+1.6k  ↑1.0k  ↓0.6k'
      #   'restored: ctx=8.2k/32.0k'                     -> 'restored'
      #
      # Should that segment ever leave pikuri's format, the whole line survives
      # as the tail — doubled against the headline, never lost.
      #
      # @return [String]
      def token_detail
        @token_log&.status_line.to_s.sub(/:?\s*ctx=\S+/, '')
      end

      # 1024-scaled with a +k+ suffix, as pikuri sizes tokens, minus the trailing
      # +.0+ a round number would carry (+64.0k+ reads as a precision the cap
      # does not have).
      #
      # @param count [Integer]
      # @return [String]
      def format_k(count)
        format('%.1fk', count / 1024.0).sub('.0k', 'k')
      end
    end
  end
end
