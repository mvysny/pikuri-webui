# frozen_string_literal: true

require 'concurrent'
require 'faraday'

module PikuriWeb
  # A Faraday adapter that rations concurrent completion requests to one
  # inference server. Bind a permit count, then hand the class to every
  # transport pointing at that server:
  #
  #   adapter = ThrottledAdapter.with_permits(2)
  #   transport = transport.with(faraday_adapter: adapter)
  #   # two completions in flight at once; the third blocks in #call until one returns
  #
  # The permits belong to the *class*: two transports on one server share the
  # server's slots by sharing one class from {.with_permits}, and a second
  # server gets a second class with its own count.
  #
  # **Why not a constructor argument** — the obvious shape, and unreachable.
  # Faraday would allow it (+RackBuilder::Handler#build+ is
  # +klass.new(app, *args, **kwargs)+), but nothing between here and there
  # passes any: ruby_llm builds the adapter as +faraday.adapter(adapter)+, and
  # pikuri's seam (+ChatTransport#faraday_adapter+ → +config.faraday_adapter=+)
  # carries a single value. The class object is the only per-server thing that
  # reaches the instance, so the pool rides on it.
  #
  # Only chat completions are rationed. Anything else on the connection passes
  # straight through: the point is the model's generation slot, not the socket.
  #
  # == Implementation details
  #
  # A permit is held across the whole HTTP request, streaming included —
  # ruby_llm streams through Faraday's +on_data+, which net_http drives from
  # inside the request, so +#call+ spans the generation rather than returning at
  # the first byte. That is the property the whole design rests on; a transport
  # that ever streams some other way would silently release the server early.
  #
  # **Not replaceable by the turn executor's pool size.** That caps concurrent
  # *turns*, and a turn holds its slot across the whole +run_loop+ — tool
  # execution included — so a single slot leaves the server idle for the length
  # of a +web_search+ while nothing else may talk to it. A permit is held only
  # while the server is actually working (`D_throttle_at_the_request`).
  #
  # The scope is one request, which is what makes nesting safe: a sub-agent's
  # completion is a separate +#call+, made while its parent's has already
  # returned its permit. There is nowhere to hoist the acquire to, so the
  # parent-waits-for-its-child deadlock a coarser scope invites cannot be
  # written here.
  #
  # Waiting is not interruptible and the queue is not FIFO
  # (+Concurrent::Semaphore+ makes no fairness guarantee). Both are accepted:
  # cancellation is a tool-boundary stop that does not reach a completion
  # anyway, and starvation across a handful of conversations on one desktop is
  # not a real risk.
  #
  # Thread-safe.
  class ThrottledAdapter < Faraday::Adapter::NetHttp
    # Path suffix that marks a request as one worth a permit.
    #
    # @return [String]
    COMPLETIONS_PATH = '/chat/completions'

    class << self
      # @return [Concurrent::Semaphore, nil] nil on the base class, which
      #   throttles nothing — only a {.with_permits} subclass carries a pool
      attr_reader :semaphore

      # @return [Integer, nil] this subclass's permit count, nil on the base class
      attr_reader :permits

      # Build a subclass owning +count+ permits.
      #
      #   ThrottledAdapter.with_permits(1)   # a llama.cpp started with --parallel 1
      #
      # @param count [Integer] concurrent completions allowed; at least 1
      # @return [Class] a {ThrottledAdapter} subclass, to hand to
      #   +ChatTransport#faraday_adapter+
      # @raise [ArgumentError] if +count+ is below 1
      def with_permits(count)
        raise ArgumentError, "permits must be at least 1, got #{count.inspect}" if count.to_i < 1

        Class.new(self) do
          @semaphore = Concurrent::Semaphore.new(count)
          @permits = count
        end
      end

      # @return [String]
      def inspect = permits ? "#{ThrottledAdapter.name}(permits: #{permits})" : super

      # @return [String]
      def to_s = inspect
    end

    # Run the request, holding a permit for its duration when it is a completion.
    #
    # @param env [Faraday::Env] the request being sent
    # @return [Faraday::Response]
    def call(env)
      semaphore = self.class.semaphore
      return super if semaphore.nil? || !completion?(env)

      semaphore.acquire
      begin
        super
      ensure
        semaphore.release
      end
    end

    private

    # @param env [Faraday::Env]
    # @return [Boolean]
    def completion?(env) = env.url.path.to_s.end_with?(COMPLETIONS_PATH)
  end
end
