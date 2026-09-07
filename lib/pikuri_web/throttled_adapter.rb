# frozen_string_literal: true

require 'concurrent'
require 'faraday'

module PikuriWeb
  # A Faraday adapter that rations concurrent completions to one inference
  # server. One pool per server, memoized on the way in:
  #
  #   adapter = pools[transport.api_base] ||= ThrottledAdapter.with_permits(2)
  #   transport = transport.with(faraday_adapter: adapter)
  #   # two completions in flight against that server; a third blocks in #call
  #
  # The permits ride on the *class*, so sharing a pool means sharing one
  # {.with_permits} class — which two +[[llm]]+ entries on one box must, since
  # the slots are the server's. Only +/chat/completions+ pays a permit;
  # everything else on the connection passes straight through.
  #
  # Why the throttle lives here rather than in the turn executor or in
  # +Pikuri::Agent+, and why the pool cannot arrive through the constructor:
  # `D_throttle_at_the_request`.
  #
  # == Implementation details
  #
  # Two properties hold this up, and breaking either is quiet.
  #
  # **A permit spans the whole response, streamed or not** — ruby_llm streams
  # through Faraday's +on_data+, which net_http drives from inside the request.
  # A transport streaming some other way would hand the server back at the first
  # byte and gate nothing.
  #
  # **The scope is exactly one request**, which is what keeps nesting safe: a
  # sub-agent's completion is a separate +#call+, made after its parent's has
  # returned its permit. Widening the acquire would deadlock a parent against
  # its own child — there is nowhere here to widen it to, and that is the point.
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

      # Names the permit count, so a log line or a thread dump says which pool
      # this is rather than +#<Class:0x…>+. {.to_s} follows, for interpolation.
      #
      # @return [String]
      def inspect = permits ? "#{ThrottledAdapter.name}(permits: #{permits})" : super

      # @return [String]
      def to_s = inspect
    end

    # Run the request, holding a permit for its duration when it is a completion.
    #
    # Blocks until a permit frees, with no timeout and no cancellation, and the
    # wait order is whatever +Concurrent::Semaphore+ gives — so a caller may
    # wait as long as everything ahead of it takes.
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
