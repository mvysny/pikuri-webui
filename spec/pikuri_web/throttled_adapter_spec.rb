# frozen_string_literal: true

require 'socket'

# Driven through a real Faraday stack against a real socket, because the
# property the design rests on is *when* the adapter's #call returns: a permit
# has to span the whole response body, or a streaming completion would release
# the server at its first byte. A test that stubbed the request away could not
# see that.
RSpec.describe PikuriWeb::ThrottledAdapter do
  # A local HTTP server whose handler may block, parking the request inside the
  # adapter the way a slow generation does. One thread per connection, so a
  # spec can have several in flight.
  class ParkableServer
    attr_reader :port

    def initialize(&handler)
      @handler = handler
      @socket = TCPServer.new('127.0.0.1', 0)
      @port = @socket.addr[1]
      @workers = []
      @acceptor = Thread.new do
        loop { @workers << Thread.new(@socket.accept) { |sock| serve(sock) } }
      rescue IOError, Errno::EBADF, Errno::EINVAL
        nil # #close pulled the listener out from under us
      end
    end

    def close
      @acceptor&.kill
      @workers.each(&:kill)
      @socket.close unless @socket.closed?
    end

    private

    def serve(sock)
      head = +''
      head << sock.readpartial(4096) until head.include?("\r\n\r\n")
      answer = @handler.call(head[/\A\S+ (\S+)/, 1])
      answer.is_a?(Array) ? stream(sock, answer) : send_whole(sock, answer.to_s)
    rescue StandardError
      nil
    ensure
      begin
        sock.close
      rescue StandardError
        nil
      end
    end

    def send_whole(sock, body)
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end

    # An SSE-shaped reply, dribbled out: no Content-Length, so net_http reads
    # until close and Faraday's on_data fires per chunk — the shape a streaming
    # completion arrives in.
    def stream(sock, chunks)
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
      chunks.each do |chunk|
        sock.write("data: #{chunk}\n\n")
        sock.flush
        sleep 0.02
      end
    end
  end

  # Built the way RubyLLM::Connection builds one: :json request middleware
  # before the adapter, so the adapter sees a serialized body.
  def connection(adapter, port)
    Faraday.new(url: "http://127.0.0.1:#{port}") do |f|
      f.request :json
      f.response :json
      f.adapter adapter
    end
  end

  def post(conn, path) = conn.post(path, { messages: [] })

  # Spin until `cond` holds, so a spec never sleeps a fixed guess.
  def wait_until(timeout: 5)
    deadline = Time.now + timeout
    sleep 0.005 until yield || Time.now > deadline
    raise 'timed out waiting for condition' unless yield
  end

  context '.with_permits' do
    it 'gives each call a pool of its own, so two servers do not share slots' do
      refute_same described_class.with_permits(2).semaphore,
                  described_class.with_permits(2).semaphore
    end

    it 'refuses a count below one, which would wedge every completion' do
      assert_raises(ArgumentError) { described_class.with_permits(0) }
    end

    it 'leaves the base class throttling nothing' do
      assert_nil described_class.semaphore
      assert_nil described_class.permits
    end

    it 'names itself with its count, for a thread dump' do
      assert_equal 'PikuriWeb::ThrottledAdapter(permits: 3)',
                   described_class.with_permits(3).inspect
    end
  end

  context '#call' do
    it 'holds its permit until the response body is read, capping concurrency' do
      permits = 2
      inflight = Concurrent::AtomicFixnum.new(0)
      peak = Concurrent::AtomicFixnum.new(0)
      release = Queue.new

      server = ParkableServer.new do |_path|
        now = inflight.increment
        peak.update { |p| [p, now].max }
        release.pop # still inside the adapter's #call
        inflight.decrement
        '{}'
      end
      adapter = described_class.with_permits(permits)

      begin
        callers = Array.new(6) do
          Thread.new { post(connection(adapter, server.port), '/v1/chat/completions') }
        end
        wait_until { inflight.value == permits }
        6.times { release << :go }
        callers.each { |t| t.join(5) }

        assert_equal permits, peak.value
      ensure
        server.close
      end
    end

    it 'lets a non-completion past while a completion holds the only permit' do
      parked = Queue.new
      release = Queue.new
      server = ParkableServer.new do |path|
        if path.end_with?('/chat/completions')
          parked << :in
          release.pop
        end
        '{}'
      end
      adapter = described_class.with_permits(1)

      begin
        completion = Thread.new { post(connection(adapter, server.port), '/v1/chat/completions') }
        parked.pop # the one permit is now held, and will be until we say so

        other = Thread.new { post(connection(adapter, server.port), '/v1/models') }
        assert other.join(5), '/v1/models queued behind the completion'

        release << :go
        completion.join(5)
      ensure
        server.close
      end
    end

    # The property the whole design rests on. If #call returned at the first
    # byte, the permit would be handed back while the server was still
    # generating, and N permits would gate nothing at all.
    it 'keeps its permit for the length of a streamed body' do
      server = ParkableServer.new { |_path| Array.new(8) { |i| "chunk-#{i}" } }
      adapter = described_class.with_permits(1)
      chunks = Queue.new

      begin
        streamers = Array.new(2) do |n|
          Thread.new do
            conn = connection(adapter, server.port)
            conn.post('/v1/chat/completions') do |req|
              req.body = '{}'
              req.options.on_data = ->(_chunk, _size, _env) { chunks << [n, Time.now] }
            end
          end
        end
        streamers.each { |t| t.join(10) }

        seen = []
        seen << chunks.pop until chunks.empty?
        order = seen.map(&:first)
        runs = order.chunk_while { |a, b| a == b }.to_a

        # Exactly two unbroken runs: the second stream produced nothing until
        # the first had finished and handed its permit back. Three or more runs
        # means they interleaved, which is what an early release looks like.
        assert_equal 2, runs.size, "streams interleaved: #{order.inspect}"
        refute_equal runs[0].first, runs[1].first
      ensure
        server.close
      end
    end

    it 'returns the permit when the request raises' do
      adapter = described_class.with_permits(1)
      # Nothing listening: every attempt fails inside `super`, after acquiring.
      conn = connection(adapter, 1)

      3.times do
        assert_raises(Faraday::ConnectionFailed) { post(conn, '/v1/chat/completions') }
      end

      # A leak would have hung the second attempt rather than raising, but make
      # the pool's wholeness explicit.
      assert adapter.semaphore.try_acquire(1), 'permit was not returned'
    end
  end
end
