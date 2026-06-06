# frozen_string_literal: true

require 'json'

module PikuriWeb
  # Fan-out of SSE frames to every connected EventSource client. Producers
  # (SseListener, AgentRunner) call {#broadcast} from any thread;
  # each +GET /events+ connection holds one subscribed +Thread::Queue+ and
  # blocks popping frames off it (see App). Pikuri-free by design.
  #
  # Frames are formatted here (one place knows the wire format); the SSE
  # route just pops ready-to-write strings. A +nil+ in a queue is the
  # shutdown sentinel — {#unsubscribe_all} pushes it so drain loops can
  # exit cleanly on server stop.
  class Broadcaster
    def initialize
      @mutex = Mutex.new
      @queues = []
    end

    # Register a new client. The caller owns the returned queue's drain
    # loop and must {#unsubscribe} it when the connection closes.
    #
    # @return [Thread::Queue] frames (Strings) to write to the client;
    #   +nil+ means "stop draining"
    def subscribe
      queue = Thread::Queue.new
      @mutex.synchronize { @queues << queue }
      queue
    end

    # @param queue [Thread::Queue] a queue previously returned by
    #   {#subscribe}; unknown queues are ignored
    # @return [void]
    def unsubscribe(queue)
      @mutex.synchronize { @queues.delete(queue) }
      nil
    end

    # Format one SSE frame and push it to every subscriber.
    #
    # @param event [String, Symbol] SSE event type (the browser-side
    #   +addEventListener+ name): +block+, +remove+, +status+
    # @param data [Hash] JSON-serialized into the frame's +data:+ line
    # @return [void]
    def broadcast(event:, data:)
      frame = "event: #{event}\ndata: #{JSON.generate(data)}\n\n"
      each_queue { |q| q.push(frame) }
    end

    # Push an SSE comment frame (ignored by EventSource). Used as a
    # heartbeat: a write attempt is the only way to discover a silently
    # vanished client, whose drain loop would otherwise park a server
    # thread forever.
    #
    # @return [void]
    def broadcast_comment(text = 'ping')
      each_queue { |q| q.push(": #{text}\n\n") }
    end

    # Push the +nil+ shutdown sentinel to every subscriber and drop them.
    # @return [void]
    def unsubscribe_all
      @mutex.synchronize do
        @queues.each { |q| q.push(nil) }
        @queues.clear
      end
      nil
    end

    # @return [Integer] current subscriber count (status-bar affordance,
    #   tests)
    def size
      @mutex.synchronize { @queues.size }
    end

    private

    # Snapshot under the mutex, push outside it — Queue#push never blocks
    # (unbounded), but keeping the critical section minimal is free.
    def each_queue(&block)
      @mutex.synchronize { @queues.dup }.each(&block)
      nil
    end
  end
end
