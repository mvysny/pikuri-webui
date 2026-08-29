# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  # One conversation's agent, transcript and turn lifecycle. A runner *is* a
  # conversation — the one it was built for, for as long as it exists — so
  # there is no switching here, and no "live" conversation to switch away
  # from. {ConversationRegistry} holds one per conversation anyone has opened.
  #
  #   runner.restore!               # replay what is on disk, once, at mint time
  #   runner.submit('hello')        # => :started (queued on the executor) or :injected
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
  # The executor is shared and its pool size caps how many conversations run a
  # turn at once, so a turn submitted while that many are already working waits
  # for a slot. That wait is visible — +:queued+ is not +:running+ — because a
  # conversation showing "thinking" when nothing is being thought is a lie the
  # status bar should not tell.
  #
  # Cancelling a +:queued+ turn needs nothing from pikuri: the job checks on
  # entry whether it was cancelled while waiting and returns without starting.
  # Cancelling a +:running+ one is +Cancellable+'s next-tool-boundary stop.
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
  # Server-side of the pikuri seam, so it names pikuri types freely
  # (`D_pikuri_free_core`).
  #
  # Thread-safe.
  class AgentRunner
    # @param conversation [ConversationStore::Conversation] the one this runner
    #   is for, fixed for its lifetime
    # @param agent [Pikuri::Agent] fully wired agent (listeners, tools,
    #   interloper:, cancellable: — built by the factory in bin/pikuri-web-chat)
    # @param interloper [Pikuri::Agent::Control::Interloper] the same
    #   instance passed to the agent's +interloper:+ kwarg
    # @param cancellable [Pikuri::Agent::Control::Cancellable] the same
    #   instance passed to the agent's +cancellable:+ kwarg
    # @param broadcaster [Broadcaster] SSE fan-out for +status+ events
    # @param conversations [ConversationStore] where turns get saved
    # @param transcript [Transcript] this conversation's blocks, which +GET
    #   /c/:id+ renders as its snapshot
    # @param listener [SseListener] the transcript's renderer, fed directly by
    #   {#restore!}'s replay — the agent's own listener stack wraps it in a
    #   delta rate-limiter that a replay has nothing to say to
    # @param executor [Concurrent::ExecutorService] shared by every runner: the
    #   admission gate that keeps concurrent turns from outnumbering the
    #   inference server's slots (+--turns+). Its pool size is that cap and
    #   nothing else — this runner is single-writer over its own conversation
    #   at any size, because {#submit} injects rather than starting a second
    #   turn
    # @param token_log [Pikuri::Agent::Listener::TokenLog, nil] when present,
    #   its +status_line+ rides along in every status event
    # @param catalog [ModelCatalog] the connections {#select_model} may pick
    #   from, and what turns the agent's transport into a display name
    # @param missing_connection [String, nil] +"model @ server"+ when this
    #   conversation was minted on {ModelCatalog#primary} because the
    #   connection it had saved is no longer in the config file — a note for
    #   the +/model+ dialog, and true only until the next save records the
    #   fallback
    def initialize(conversation:, agent:, interloper:, cancellable:, broadcaster:,
                   conversations:, transcript:, listener:, executor:, catalog:,
                   token_log: nil, missing_connection: nil)
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
      @missing_connection = missing_connection
      @mutex = Mutex.new
      @state = :idle
      @abandon = false
      @discarded = false
      @announced_busy = false
      @pending = nil

      # Claims the interloper's single on_change slot. Without it the
      # queued-count badge only moves when a request happens to hit {#submit}
      # or a turn ends — the agent's own mid-loop drain would leave the browser
      # showing a stale "2 queued" for the rest of the turn.
      @interloper.on_change = ->(_count) { broadcast_status }
    end

    # @return [ConversationStore::Conversation]
    attr_reader :conversation

    # @return [Transcript] this conversation's rendered blocks
    attr_reader :transcript

    # Replay what is stored for this conversation into the agent and the
    # transcript. Called once, when the registry mints this runner.
    #
    # A conversation with nothing on disk (brand new, or never saved because it
    # holds no messages) restores to empty, which is already correct.
    #
    # @return [Boolean] whether a stored history was found and loaded
    def restore!
      history = stored_history
      return false if history.nil?

      @agent.load_history!(history)
      HistoryReplay.events(history).each { |event| @listener.on_event(event) }
      true
    end

    # Route one user message: start a turn or inject into the running one.
    #
    # Never refuses for being busy: a turn submitted while the executor's slots
    # are all taken is queued, not rejected — the wait is what {#state}
    # reports. +:discarded+ is not a refusal either, but the answer that this
    # conversation no longer exists ({#discard!}).
    #
    # @param message [String] non-blank user text (App rejects blanks before
    #   calling; Interloper/run_loop double-check)
    # @return [:started, :injected, :discarded]
    def submit(message)
      claim = @mutex.synchronize do
        if @discarded then :discarded
        elsif busy? then :inject
        else
          @abandon = false
          @state = :queued
          :start
        end
      end
      return :discarded if claim == :discarded

      # Both of these run outside the mutex, for the same reason from two
      # directions: they re-enter. An ImmediateExecutor runs the job on this
      # thread, and run_turn's ensure re-takes this non-reentrant mutex;
      # inject_user_message fires the Interloper's on_change synchronously,
      # which broadcasts status and reads back through here. Claiming the
      # state above is what makes the gap safe — and an injection landing in
      # it after the turn ended is delivered by the restart {#finish_turn}
      # claims, not stranded.
      if claim == :start
        @executor.post { run_turn(message) }
      else
        @interloper.inject_user_message(message)
      end
      broadcast_status
      claim == :start ? :started : :injected
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
      choice = @catalog.find(name)
      return :unknown if choice.nil?

      outcome = @mutex.synchronize do
        next :discarded if @discarded

        @pending = choice.transport == @agent.transport ? nil : choice.transport
        @missing_connection = nil
        :selected
      end
      broadcast_status if outcome == :selected
      outcome
    end

    # The connection this conversation will talk to *next* — the pick if one
    # is parked, what the agent is on otherwise.
    #
    #   registry.create(from: viewing)   # a new conversation inherits this
    #
    # Intent rather than reality on purpose: a pick made on a busy conversation
    # and immediately followed by "new conversation" should hand the new one
    # what the user asked for.
    #
    # @return [Array(String, String)] the +[model, server]+ pair, in the form
    #   {ConversationStore} stores and {ModelCatalog#resolve} matches
    def model
      transport = @pending || @agent.transport
      [transport.model, transport.api_base]
    end

    # Retire this runner for good: it will start no turn, inject nothing, take
    # no model and write no folder again. One-way, and refused while a turn is
    # in flight —
    # so a deleter asks for the folder and the turn in one move:
    #
    #   return :busy if runner && !runner.discard!   # then remove the folder
    #
    # Deliberately a *claim*, not a {#busy?} read followed by a flag: the
    # busy check and the retirement are one step under this runner's mutex, so
    # either {#submit} claims the turn first and this refuses, or this wins
    # and {#submit} answers +:discarded+. No interleaving lets both proceed —
    # which is why {#persist} carries no check of its own.
    #
    # Not +@abandon+, which drops one *queued turn* and is reset by the next
    # {#submit}. This is about the conversation, and permanent.
    #
    # @return [Boolean] false when a turn is queued or running, and the caller
    #   must refuse the delete; true once nothing will ever run here again
    def discard!
      @mutex.synchronize do
        return false if busy?

        @discarded = true
      end
      true
    end

    # @return [Boolean] whether a delete has retired this runner
    def discarded? = @discarded

    # Stop this conversation's turn: drop it before it starts if it is still
    # waiting for the executor, or ask the agent to stop at the next tool
    # boundary if it is already running. No-op when idle.
    #
    # @return [void]
    def cancel
      @mutex.synchronize do
        @abandon = true if @state == :queued
        @cancellable.cancel! if @state == :running
      end
      broadcast_status
      nil
    end

    # Deliberately unlocked, like {#busy?}: a single ivar read is atomic under
    # the GVL, and locking here would deadlock the status broadcast that the
    # Interloper's on_change fires from inside pikuri's own enqueue.
    #
    # @return [:idle, :queued, :running] +:queued+ means the job is posted but
    #   the executor's slots are all taken by other conversations
    def state = @state

    # @return [Boolean] whether a turn is posted and not yet finished
    def busy?
      @state != :idle
    end

    # Status payload shared by SSE +status+ events and the initial page render.
    #
    #   { state: :running, busy: true, pending: 2, tokens: '31k / 32k',
    #     model: 'Local Qwen 3.6', model_pending: 'Remote Qwen', model_missing: nil }
    #
    # @return [Hash] +pending+ is the count of queued mid-loop injections;
    #   +tokens+ is TokenLog's preformatted status line ('' when absent);
    #   +model+ is what the agent is on *now*; +model_pending+ and
    #   +model_missing+ are nil in the ordinary case (see {#select_model} and
    #   the +missing_connection:+ constructor argument)
    def status_data
      {
        state: state,
        busy: busy?,
        pending: @interloper.size,
        tokens: @token_log&.status_line.to_s,
        model: @catalog.name_for(@agent.transport),
        model_pending: @pending && @catalog.name_for(@pending),
        model_missing: @missing_connection
      }
    end

    # @return [Pikuri::Agent::Trifecta] the advisory tool-exposure map, for the
    #   boot script's one-time report
    def trifecta = @agent.trifecta

    # @return [String] the same map as the +/trifecta+ dialog's HTML body, which
    #   +GET /c/:id+ renders into the page — {App} never touches the report
    def trifecta_html = TrifectaView.render(@agent.trifecta)

    # @return [Boolean] whether this conversation holds no messages, so nothing
    #   would be saved and its folder need not survive
    def empty? = @agent.export_history.messages.empty?

    private

    # The executor job's body: one turn, then the save.
    #
    # A StandardError out of +run_loop+ (transport hiccup, tool bug) is logged
    # rather than re-raised — an executor swallows a job's exception into a
    # future nobody here holds, so the UI would just look stuck. The ensure
    # broadcasts idle so the browser's input re-enables even on the error path.
    #
    # @param message [String, nil] +nil+ on a restart, where the turn exists
    #   for the Interloper drain +run_loop+ does before its first completion
    # @return [void]
    def run_turn(message)
      return if claim_running == :abandoned

      # Both ways into a turn come through here — a submit and the restart
      # {#finish_turn} claims — so one drain covers both; a second entry point
      # into +run_loop+ would silently run the old model.
      @agent.run_loop(user_message: message, transport: take_pending)
      completed = true
    rescue StandardError => e
      PikuriWeb.logger.error("agent run_loop failed (#{e.class}: #{e.message})")
    ensure
      finish_turn(restart: completed)
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
    # Reading the Interloper under this mutex is safe because its +on_change+ —
    # which broadcasts status and re-enters here — fires outside its own lock.
    #
    # @param restart [Boolean, nil] whether the turn ran to completion
    # @return [void]
    def finish_turn(restart:)
      resume = @mutex.synchronize do
        persist
        @state = :idle
        next false unless restart && @interloper.pending?

        @state = :queued
        true
      end
      broadcast_status
      @executor.post { run_turn(nil) } if resume
      nil
    end

    # Move from queued to running, unless {#cancel} got here first — which is
    # how a queued turn is dropped without the executor needing to support
    # dequeuing.
    #
    # @return [:running, :abandoned]
    def claim_running
      abandoned = @mutex.synchronize do
        @state = :running unless @abandon
        @abandon
      end
      return :running unless abandoned

      @mutex.synchronize { @state = :idle }
      broadcast_status
      :abandoned
    end

    # @return [Pikuri::Agent::ChatTransport, nil] the parked selection, taken;
    #   nil — +run_loop+'s "keep the current model" — when there is none
    def take_pending = @mutex.synchronize { @pending.tap { @pending = nil } }

    # @return [Pikuri::Agent::History, nil] nil when this conversation has
    #   nothing stored, or when what is stored cannot be read — a file someone
    #   edited or a half-written save is the library's to report and ours to
    #   survive, unlike a raise from the load itself
    def stored_history
      return nil unless (@conversation.dir / 'history.json').file?

      Pikuri::Agent::History.load(@conversation.dir)
    rescue Pikuri::Agent::History::Error, SystemCallError => e
      PikuriWeb.logger.error("loading conversation #{@conversation.id} failed (#{e.class}: #{e.message})")
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
      PikuriWeb.logger.error("saving conversation #{@conversation.id} failed (#{e.class}: #{e.message})")
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
      changed = @mutex.synchronize do
        was = @announced_busy
        @announced_busy = busy?
        was != @announced_busy
      end
      @broadcaster.broadcast(event: :conversations, data: {}) if changed
      nil
    end
  end
end
