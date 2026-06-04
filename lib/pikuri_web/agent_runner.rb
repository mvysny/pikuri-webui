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
  #   The agent drains the queue at the next +after_tool_result+ boundary
  #   and emits +UserTurn(mid_loop: true)+, so the injection renders
  #   through the same listener path as a normal turn. Note the boundary
  #   caveat from Interloper's docs: an injection placed while the model
  #   is mid-response takes effect on the *next* round-trip.
  #
  # The race between "worker finishes" and "submit checks alive?" is
  # benign by pikuri's own design: +Interloper#drain!+ runs at every
  # +after_tool_result+ *and* the queue survives across runs, so a
  # message injected into a just-finished loop is picked up by the next
  # {#submit}'s fresh +run_loop+ drain. The @mutex only serializes
  # concurrent submits.
  #
  # Status changes (busy/idle/pending counts) are broadcast as SSE
  # +status+ events; {#status_data} serves the same hash to +GET /+ for
  # the initial page render.
  #
  # Part of the Pikuri seam: this class and SseListener are the only
  # lib/ files that reference +Pikuri::*+.
  class AgentRunner
    # @param agent [Pikuri::Agent] fully wired agent (listeners, tools,
    #   interloper:, cancellable: — built in bin/pikuri-web)
    # @param interloper [Pikuri::Agent::Control::Interloper] the same
    #   instance passed to the agent's +interloper:+ kwarg
    # @param cancellable [Pikuri::Agent::Control::Cancellable] the same
    #   instance passed to the agent's +cancellable:+ kwarg
    # @param broadcaster [Broadcaster] SSE fan-out for +status+ events
    # @param token_log [Pikuri::Agent::Listener::TokenLog, nil] when
    #   present, its +status_line+ rides along in every status event
    #   (the web status bar's token/context readout)
    def initialize(agent:, interloper:, cancellable:, broadcaster:, token_log: nil)
      @agent = agent
      @interloper = interloper
      @cancellable = cancellable
      @broadcaster = broadcaster
      @token_log = token_log
      @mutex = Mutex.new
      @thread = nil
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

    # Status payload shared by SSE +status+ events and +GET /+'s initial
    # render.
    #
    # @return [Hash] +{busy:, pending:, tokens:}+ — +pending+ is the
    #   count of queued mid-loop injections; +tokens+ is TokenLog's
    #   preformatted status line ('' when absent)
    def status_data
      {
        busy: busy?,
        pending: @interloper.peek.size,
        tokens: @token_log&.status_line.to_s
      }
    end

    private

    # Worker-thread body. A StandardError out of +run_loop+ (transport
    # hiccup, tool bug) is logged rather than re-raised: an uncaught
    # raise would die silently with the thread and the UI would just
    # look stuck. The ensure broadcasts idle so the browser's input
    # re-enables even on the error path — clearing @thread first, since
    # this code runs *on* the worker thread, which is still alive while
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
      @mutex.synchronize { @thread = nil if @thread == Thread.current }
      broadcast_status
    end

    # @return [void]
    def broadcast_status
      @broadcaster.broadcast(event: :status, data: status_data)
    end
  end
end
