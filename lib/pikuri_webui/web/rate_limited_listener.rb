# frozen_string_literal: true

require 'pikuri-core'

module PikuriWebUI
  module Web
    # Coalesces streaming deltas into at most +fps+ events a second before they
    # reach +inner+; every other event flows straight through.
    #
    #   listener = RateLimitedListener.new(sse_listener, fps: 15)
    #   # 60 deltas/s from a fast llama.cpp → 15 Markdown re-renders/s
    #
    # A buffered delta is dropped when its own bookend (+Assistant+ /
    # +Thinking+) arrives, since the bookend carries the whole text and
    # {SseListener} re-renders from it (+StreamingMessage#finalize+); any other
    # event — a tool call, a cancel — first flushes what is buffered, so the
    # stream reaches the transcript whole and in order.
    #
    # == Implementation details
    #
    # The tick schedule is anchored at construction, not at the first delta, so
    # stream-startup latency doesn't leak into the cadence; after a flush it
    # advances by whole periods, so a long-idle stream doesn't backlog ticks.
    # Assistant and thinking deltas buffer independently.
    #
    # No lock, unlike pikuri-tui's copy: only agent events come through here
    # ({Agents::Runner} keeps the conversation's own events to itself), and an
    # agent emits from one thread at a time — the boot thread, then each turn's.
    # A lock here would also sit outside {BigAppLock}, the domain {SseListener}
    # enters, which the domain-is-outermost rule forbids.
    class RateLimitedListener < Pikuri::Agent::Listener::Base
      # @param inner [Pikuri::Agent::Listener::Base] where the coalesced stream goes
      # @param fps [Integer, Float] the cap on delta events a second; positive
      # @param clock [Proc] zero-arg → monotonic seconds; a spec's seam
      # @raise [ArgumentError] if +fps+ is not positive
      def initialize(inner, fps:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        super()
        raise ArgumentError, "fps must be positive, got #{fps.inspect}" unless fps.positive?

        @inner = inner
        @fps = fps
        @period = 1.0 / fps
        @clock = clock
        @next_tick_at = clock.call
        @assistant_buffer = String.new
        @thinking_buffer = String.new
      end

      # @param event [Data] an agent event
      # @return [void]
      def on_event(event)
        case event
        when Pikuri::Agent::Event::AssistantDelta
          @assistant_buffer << event.content
          tick
        when Pikuri::Agent::Event::ThinkingDelta
          @thinking_buffer << event.content
          tick
        when Pikuri::Agent::Event::Assistant
          flush_thinking
          @assistant_buffer.clear
          @inner.on_event(event)
        when Pikuri::Agent::Event::Thinking
          @thinking_buffer.clear
          flush_assistant
          @inner.on_event(event)
        else
          flush_thinking
          flush_assistant
          @inner.on_event(event)
        end
      end

      # @return [String] e.g. +"RateLimited(15fps, SseListener)"+
      def to_s = "RateLimited(#{@fps}fps, #{@inner})"

      private

      # @return [void]
      def tick
        now = @clock.call
        return if now < @next_tick_at

        flush_thinking
        flush_assistant
        missed = ((now - @next_tick_at) / @period).floor + 1
        @next_tick_at += missed * @period
      end

      # @return [void]
      def flush_assistant
        return if @assistant_buffer.empty?

        @inner.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: @assistant_buffer.dup))
        @assistant_buffer.clear
      end

      # @return [void]
      def flush_thinking
        return if @thinking_buffer.empty?

        @inner.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: @thinking_buffer.dup))
        @thinking_buffer.clear
      end
    end
  end
end
