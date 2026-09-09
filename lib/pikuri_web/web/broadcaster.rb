# frozen_string_literal: true

require 'json'

module PikuriWeb
  module Web
    # Fan-out of SSE frames to every connected EventSource client, addressed by
    # conversation. Each +GET /events+ connection subscribes to the one
    # conversation its tab is showing and blocks popping frames off its queue:
    #
    #   queue = broadcaster.subscribe('2026-08-28T10-01-34Z-3dff')
    #   broadcaster.broadcast(event: :block, data: {…}, conversation: '…-3dff')  # this queue
    #   broadcaster.broadcast(event: :conversations, data: {})                   # every queue
    #
    # A +conversation:+ of +nil+ means the frame is about the server rather than
    # about one conversation — the sidebar's listing changed — and goes to
    # everyone. So does the heartbeat, and so does {#close}'s sentinel.
    #
    # Addressing is what lets a turn run in one conversation while another tab
    # reads a different one: the reader is not subscribed to the running
    # conversation, so its deltas never reach that tab at all. Pikuri-free by
    # design.
    #
    # Frames are formatted here (one place knows the wire format); the SSE
    # route just pops ready-to-write strings. A +nil+ in a queue is the
    # shutdown sentinel — {#close} pushes it so drain loops can exit
    # cleanly on server stop.
    #
    # Thread-safe.
    class Broadcaster
      # One connected client: the queue its drain loop pops, and the conversation
      # it is showing.
      Subscriber = Struct.new(:queue, :conversation, keyword_init: true)

      def initialize
        @mutex = Mutex.new
        @subscribers = []
        @closed = false
      end

      # Register a new client against the conversation its tab is showing. The
      # caller owns the returned queue's drain loop and must {#unsubscribe} it
      # when the connection closes.
      #
      # @param conversation [String, nil] conversation id; +nil+ receives only
      #   the server-wide frames
      # @return [Thread::Queue] frames (Strings) to write to the client;
      #   +nil+ means "stop draining". After {#close} the queue holds
      #   nothing but that sentinel, so a connection that slips in during
      #   shutdown drains immediately instead of parking forever.
      def subscribe(conversation)
        queue = Thread::Queue.new
        @mutex.synchronize do
          if @closed
            queue.push(nil)
          else
            @subscribers << Subscriber.new(queue: queue, conversation: conversation)
          end
        end
        queue
      end

      # @param queue [Thread::Queue] a queue previously returned by
      #   {#subscribe}; unknown queues are ignored
      # @return [void]
      def unsubscribe(queue)
        @mutex.synchronize { @subscribers.reject! { |s| s.queue == queue } }
        nil
      end

      # Format one SSE frame and push it to the subscribers it is addressed to.
      #
      # Never blocks — the queues are unbounded — so it is safe to call while
      # holding a lock; the parked drain loops do the actual network writes.
      #
      # @param event [String, Symbol] SSE event type (the browser-side
      #   +addEventListener+ name): +block+, +remove+, +reset+, +status+,
      #   +conversations+. The protocol's other frame, +snapshot+, is a catch-up
      #   for one connection and goes out through {#frame} instead
      # @param data [Hash] JSON-serialized into the frame's +data:+ line
      # @param conversation [String, nil] the conversation this frame is about;
      #   +nil+ addresses every subscriber
      # @return [void]
      def broadcast(event:, data:, conversation: nil)
        formatted = frame(event: event, data: data)
        each_queue(conversation) { |q| q.push(formatted) }
      end

      # One formatted frame, for a subscriber writing catch-up directly onto its
      # own connection instead of receiving it through a queue. Same wire format
      # as {#broadcast}, which is the point of it living here.
      #
      #   out << broadcaster.frame(event: :snapshot, data: { blocks: [{ id: 'b1', … }] })
      #
      # @param event [String, Symbol] SSE event type
      # @param data [Hash] JSON-serialized into the frame's +data:+ line
      # @return [String]
      def frame(event:, data:)
        "event: #{event}\ndata: #{JSON.generate(data)}\n\n"
      end

      # Push an SSE comment frame (ignored by EventSource) to every subscriber.
      # Used as a heartbeat: a write attempt is the only way to discover a
      # silently vanished client, whose drain loop would otherwise park a server
      # thread forever.
      #
      # @return [void]
      def broadcast_comment(text = 'ping')
        each_queue(nil) { |q| q.push(": #{text}\n\n") }
      end

      # Push the +nil+ shutdown sentinel to every subscriber, drop them all,
      # and refuse further ones. Idempotent.
      #
      # Every drain loop returns, which is what lets the server's graceful
      # stop finish: it waits for in-flight requests, and a parked +/events+
      # thread is one. Call it from the server's stop hook, not +at_exit+ —
      # by then the wait has already happened.
      #
      # @return [void]
      def close
        @mutex.synchronize do
          @closed = true
          @subscribers.each { |s| s.queue.push(nil) }
          @subscribers.clear
        end
        nil
      end

      # @param conversation [String, nil] count only this conversation's
      #   subscribers, or every one
      # @return [Integer] current subscriber count (status-bar affordance, tests)
      def size(conversation = nil)
        @mutex.synchronize do
          conversation.nil? ? @subscribers.size : @subscribers.count { |s| s.conversation == conversation }
        end
      end

      private

      # Snapshot under the mutex, push outside it — Queue#push never blocks
      # (unbounded), but keeping the critical section minimal is free.
      #
      # @param conversation [String, nil] +nil+ selects every subscriber
      def each_queue(conversation)
        @mutex
          .synchronize { @subscribers.select { |s| conversation.nil? || s.conversation == conversation }.map(&:queue) }
          .each { |queue| yield queue }
        nil
      end
    end
  end
end
