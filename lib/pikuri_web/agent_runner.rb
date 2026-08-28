# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  # One conversation's agent, transcript and turn lifecycle. A runner *is* a
  # conversation — the one it was built for, for as long as it exists — so
  # there is no switching here, and no "live" conversation to switch away
  # from. {ConversationRegistry} holds one per conversation anyone has opened.
  #
  #   runner.restore!            # replay what is on disk, once, at mint time
  #   runner.submit('hello')     # => :started (queued on the executor) or :injected
  #   runner.state               # => :idle | :queued | :running
  #   runner.cancel              # dequeue if queued, stop at a tool boundary if running
  #   runner.discard!            # the conversation was deleted; retire this runner
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
  # The race between "the job finishes" and "submit checks {#busy?}" is benign
  # by pikuri's own design: the queue survives across runs, so a message
  # injected into a just-finished loop is picked up by the next {#submit}'s
  # fresh +run_loop+ drain.
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
  # Part of the Pikuri seam: this class, SseListener and HistoryReplay are the
  # only lib/ files that reference +Pikuri::*+.
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
    def initialize(conversation:, agent:, interloper:, cancellable:, broadcaster:,
                   conversations:, transcript:, listener:, executor:, token_log: nil)
      @conversation = conversation
      @agent = agent
      @interloper = interloper
      @cancellable = cancellable
      @broadcaster = broadcaster
      @conversations = conversations
      @transcript = transcript
      @listener = listener
      @executor = executor
      @token_log = token_log
      @mutex = Mutex.new
      @state = :idle
      @abandon = false
      @discarded = false
      @announced_busy = false

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
    # Never refuses while the conversation exists. A turn submitted while the
    # executor's slots are all taken is queued, not rejected — the wait is what
    # {#state} reports. The one non-answer is +:discarded+, which is not a
    # refusal to queue but a statement that there is no longer a conversation
    # to queue into ({#discard!}).
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
      # it after the turn ended is picked up by the next run_loop's drain
      # anyway, which is the benign race described above.
      if claim == :start
        @executor.post { run_turn(message) }
      else
        @interloper.inject_user_message(message)
      end
      broadcast_status
      claim == :start ? :started : :injected
    end

    # Retire this runner for good: after a successful call it will start no
    # turn, inject nothing and write no folder, ever again. Refused while a
    # turn is in flight.
    #
    # This exists because a *deleted* conversation could otherwise come back.
    # +POST /messages+ resolves a runner and then submits to it in separate
    # steps, so a delete landing in between removed the folder while a request
    # thread still held a live runner for it — the next turn's save recreated
    # the directory, and the conversation the user confirmed away was back in
    # the sidebar one turn later.
    #
    # The fix is that this claim and the busy check are *one* step under this
    # runner's mutex, and {ConversationRegistry#delete} drops the runner only
    # when it succeeds. Either {#submit} claims the turn first, and this
    # refuses so the delete is refused too; or this wins, and {#submit} answers
    # +:discarded+ without starting anything. There is no interleaving where
    # both proceed, which is why {#persist} needs no check of its own — no turn
    # can still be in flight past a successful call.
    #
    # Not to be confused with +@abandon+, which drops one *queued turn* and is
    # reset by the next {#submit}. This is one-way and about the conversation.
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
    # @return [Hash] +{state:, busy:, pending:, tokens:}+ — +pending+ is the
    #   count of queued mid-loop injections; +tokens+ is TokenLog's
    #   preformatted status line ('' when absent)
    def status_data
      {
        state: state,
        busy: busy?,
        pending: @interloper.size,
        tokens: @token_log&.status_line.to_s
      }
    end

    # @return [Pikuri::Agent::Trifecta] the advisory tool-exposure map, for the
    #   boot script's one-time report
    def trifecta = @agent.trifecta

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
    # @param message [String]
    # @return [void]
    def run_turn(message)
      return if claim_running == :abandoned

      @agent.run_loop(user_message: message)
    rescue StandardError => e
      PikuriWeb.logger.error("agent run_loop failed (#{e.class}: #{e.message})")
    ensure
      @mutex.synchronize do
        persist
        @state = :idle
      end
      broadcast_status
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

    # Write this conversation to disk, through {ConversationStore#save} — the
    # store owns the directory's mode, the order the two halves land in and
    # which one commits, so all this decides is *whether* to save.
    #
    # An empty history is not worth a folder, and that judgement is the only
    # part of persistence that belongs to the agent rather than to the store.
    #
    # Filesystem failures are logged, not raised — a full disk must not take
    # the conversation down with it, and this runs inside the turn job's
    # ensure, where a raise would escape.
    #
    # @return [void]
    def persist
      history = @agent.export_history
      return if history.messages.empty?

      @conversations.save(@conversation, history)
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
