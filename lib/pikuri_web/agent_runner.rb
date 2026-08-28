# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  # Owns the agent's worker thread and the submit/inject decision — the
  # web host's answer to the TUI's "the agent loop blocks on the LLM and
  # must not run on the UI thread" rule, where the protected resource is
  # the Sinatra request thread instead.
  #
  # {#submit} is the single entry point for user text:
  #
  # - Agent idle → spawn a worker thread running
  #   +Pikuri::Agent#run_loop(user_message:)+. The listener stack renders
  #   everything the loop emits; nothing here touches the transcript.
  # - Agent busy → +Pikuri::Agent::Control::Interloper#inject_user_message+.
  #   The agent drains the queue at turn start and once each tool batch
  #   completes, emitting +UserTurn(mid_loop: true)+, so the injection
  #   renders through the same listener path as a normal turn. An
  #   injection placed while the model is mid-response still waits for
  #   that boundary, which is why the input stays enabled while busy and
  #   the status bar carries the queued count.
  #
  # The race between "worker finishes" and "submit checks alive?" is
  # benign by pikuri's own design: the queue survives across runs, so a
  # message injected into a just-finished loop is picked up by the next
  # {#submit}'s fresh +run_loop+ drain. The @mutex serializes submits
  # against each other and against {#new_conversation}, and covers the
  # save at turn end — so it is held across a few ms of disk I/O.
  #
  # Status changes (busy/idle/pending counts) are broadcast as SSE
  # +status+ events; {#status_data} serves the same hash to +GET /+ for
  # the initial page render.
  #
  # == Persistence
  #
  # This class owns *which* conversation is live, because it owns the agent
  # whose history that is:
  #
  #   runner.new_conversation                      # => :started — saved, cleared, fresh id
  #   runner.load_conversation(store.list.first)   # => :loaded — saved, then replaced
  #
  # Saves happen at *turn end*, from the worker thread's ensure, so a history
  # is never exported mid-+complete+ and {#busy?} staying true until the save
  # lands makes "idle" mean "saved". The cost is that a process killed mid-turn
  # loses that turn — and saving per *message* instead would not fix it: there
  # is no event to hang that on, because +Event::ToolResult+ fires before
  # ruby_llm appends the tool message and nothing fires when it lands.
  #
  # Part of the Pikuri seam: this class, SseListener and HistoryReplay are the
  # only lib/ files that reference +Pikuri::*+.
  class AgentRunner
    # @param agent [Pikuri::Agent] fully wired agent (listeners, tools,
    #   interloper:, cancellable: — built in bin/pikuri-web-chat)
    # @param interloper [Pikuri::Agent::Control::Interloper] the same
    #   instance passed to the agent's +interloper:+ kwarg
    # @param cancellable [Pikuri::Agent::Control::Cancellable] the same
    #   instance passed to the agent's +cancellable:+ kwarg
    # @param broadcaster [Broadcaster] SSE fan-out for +status+ events
    # @param conversations [ConversationStore] where turns get saved; the
    #   live conversation is minted from it here and re-minted by
    #   {#new_conversation}
    # @param listener [SseListener] the transcript's renderer, fed directly
    #   by {#load_conversation}'s replay — the agent's own listener stack
    #   wraps it in a delta rate-limiter that a replay has nothing to say to
    # @param token_log [Pikuri::Agent::Listener::TokenLog, nil] when
    #   present, its +status_line+ rides along in every status event
    #   (the web status bar's token/context readout)
    def initialize(agent:, interloper:, cancellable:, broadcaster:, conversations:, listener:,
                   token_log: nil)
      @agent = agent
      @interloper = interloper
      @cancellable = cancellable
      @broadcaster = broadcaster
      @conversations = conversations
      @listener = listener
      @token_log = token_log
      @mutex = Mutex.new
      @thread = nil
      @conversation = conversations.create

      # Claims the interloper's single on_change slot. Without it the
      # queued-count badge only moves when a request happens to hit
      # {#submit} or a turn ends — the agent's own mid-loop drain would
      # leave the browser showing a stale "2 queued" for the rest of the
      # turn. Fires on the agent's loop thread; {Broadcaster} is the sink
      # that makes that safe.
      @interloper.on_change = ->(_count) { broadcast_status }
    end

    # Route one user message: start a turn or inject mid-loop.
    #
    # @param message [String] non-blank user text (App rejects blanks
    #   before calling; Interloper/run_loop double-check)
    # @return [:started, :injected]
    def submit(message)
      result = @mutex.synchronize do
        if busy?
          @interloper.inject_user_message(message)
          :injected
        else
          @thread = Thread.new { run_turn(message) }
          :started
        end
      end
      broadcast_status
      result
    end

    # Request a gentle stop of the in-flight turn (next tool boundary —
    # +Cancellable+'s semantic). No-op when idle: the agent resets the
    # flag at the start of each turn, so a stale cancel can't poison the
    # next one — but skipping the set keeps the log honest.
    #
    # @return [void]
    def cancel
      @cancellable.cancel! if busy?
      nil
    end

    # @return [Boolean] whether a turn is currently running
    def busy?
      !@thread.nil? && @thread.alive?
    end

    # @return [ConversationStore::Conversation] the live conversation — the
    #   one the agent's history belongs to and turns are saved into
    def conversation
      @mutex.synchronize { @conversation }
    end

    # Save the live conversation, clear the agent, and mint a fresh one.
    #
    # The transcript is not touched here: +clear_conversation+ emits
    # +Event::Reset+, and {SseListener} is what empties the transcript and
    # every open tab.
    #
    # Refuses while a turn is in flight — pikuri's +clear_conversation+ is
    # explicitly not safe against a running +run_loop+, and discarding
    # someone's turn because they clicked a button is worse than refusing.
    #
    # @return [:started, :busy, :empty] +:empty+ when the conversation holds no
    #   messages: nothing to save, nothing to clear.
    def new_conversation
      outcome = @mutex.synchronize { switch_conversation }
      # TokenLog zeroes its context readout on Reset, so the status bar is
      # stale until this lands.
      broadcast_status if outcome == :started
      outcome
    end

    # Save the live conversation and put a stored one in its place: the agent's
    # history, and the transcript every browser is looking at.
    #
    #   runner.load_conversation(store.list.first)   # => :loaded
    #
    # The transcript is rebuilt rather than swapped: +load_history!+ emits
    # +Event::Reset+, which empties it and every open tab, and {HistoryReplay}
    # then refills it through the same {SseListener} a live turn renders
    # through. So there is only ever one transcript, and a saved conversation
    # comes back with today's Markdown renderer and today's CSS.
    #
    # Refuses while a turn is in flight, for the same reason
    # {#new_conversation} does. The refusal is also what makes feeding the
    # listener from a request thread safe: {SseListener} keeps unguarded
    # per-turn streaming state, and nothing can be emitting into it while this
    # holds the mutex and no loop is running.
    #
    # @param conversation [ConversationStore::Conversation] from
    #   +ConversationStore#list+ — a listed conversation rather than an id, so
    #   no caller ever turns user input into a path
    # @return [:loaded, :busy, :current, :failed] +:current+ when it is
    #   already live (nothing to do); +:failed+ when the stored history could
    #   not be read, in which case the live conversation is untouched
    def load_conversation(conversation)
      outcome = @mutex.synchronize { switch_to(conversation) }
      # TokenLog reseeds its context readout from Event::HistoryLoaded, so the
      # status bar is stale until this lands.
      broadcast_status if outcome == :loaded
      outcome
    end

    # Status payload shared by SSE +status+ events and +GET /+'s initial
    # render.
    #
    # @return [Hash] +{busy:, pending:, tokens:}+ — +pending+ is the
    #   count of queued mid-loop injections; +tokens+ is TokenLog's
    #   preformatted status line ('' when absent)
    def status_data
      {
        busy: busy?,
        pending: @interloper.size,
        tokens: @token_log&.status_line.to_s
      }
    end

    private

    # Worker-thread body. A StandardError out of +run_loop+ (transport
    # hiccup, tool bug) is logged rather than re-raised: an uncaught
    # raise would die silently with the thread and the UI would just
    # look stuck. The ensure broadcasts idle so the browser's input
    # re-enables even on the error path — clearing @thread, since this
    # code runs *on* the worker thread, which is still alive while
    # executing its own ensure and would otherwise report +busy: true+.
    # The +if+ guard keeps a slow ensure from clobbering a successor
    # turn's handle.
    #
    # @param message [String]
    # @return [void]
    def run_turn(message)
      @agent.run_loop(user_message: message)
    rescue StandardError => e
      PikuriWeb.logger.error("agent run_loop failed (#{e.class}: #{e.message})")
    ensure
      # Save before releasing the handle: a #new_conversation slipping into the
      # gap would re-point @conversation, and this save would then land the
      # finished turn in the fresh conversation's folder.
      @mutex.synchronize do
        persist
        @thread = nil if @thread == Thread.current
      end
      broadcast_status
    end

    # {#new_conversation}'s body; the caller holds @mutex.
    #
    # @return [:started, :busy, :empty]
    def switch_conversation
      return :busy if busy?

      history = @agent.export_history
      return :empty if history.messages.empty?

      persist(history)
      @agent.clear_conversation
      @conversation = @conversations.create
      :started
    end

    # {#load_conversation}'s body; the caller holds @mutex.
    #
    # @param conversation [ConversationStore::Conversation]
    # @return [:loaded, :busy, :current, :failed]
    def switch_to(conversation)
      return :busy if busy?
      return :current if conversation.id == @conversation.id

      # Read before writing: a corrupt or missing history.json must leave the
      # live conversation exactly as it was, not half-swapped.
      history = stored_history(conversation)
      return :failed if history.nil?

      persist
      @agent.load_history!(history)
      HistoryReplay.events(history).each { |event| @listener.on_event(event) }
      @conversation = conversation
      :loaded
    end

    # @param conversation [ConversationStore::Conversation]
    # @return [Pikuri::Agent::History, nil] nil when the folder cannot be read
    #   — a file someone edited or a half-written save is the library's to
    #   report and ours to survive, unlike a raise from the load itself
    def stored_history(conversation)
      Pikuri::Agent::History.load(conversation.dir)
    rescue Pikuri::Agent::History::Error, SystemCallError => e
      PikuriWeb.logger.error("loading conversation #{conversation.id} failed (#{e.class}: #{e.message})")
      nil
    end

    # Write the live conversation to disk: pikuri's +history.json+, then our
    # +meta.json+.
    #
    # Filesystem failures are logged, not raised — a full disk must not take
    # the conversation down with it, and this runs inside the worker thread's
    # ensure, where a raise would escape.
    #
    # @param history [Pikuri::Agent::History] the snapshot to write; a
    #   parameter because exporting copies attachment bytes, so a caller
    #   holding one already must not make a second
    # @return [void]
    def persist(history = @agent.export_history)
      return if history.messages.empty?

      history.save(@conversation.dir)
      @conversations.write_meta(@conversation)
    rescue StandardError => e
      PikuriWeb.logger.error("saving conversation #{@conversation.id} failed (#{e.class}: #{e.message})")
    end

    # @return [void]
    def broadcast_status
      @broadcaster.broadcast(event: :status, data: status_data)
    end
  end
end
