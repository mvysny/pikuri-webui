# frozen_string_literal: true

module PikuriWeb
  # IO-shaped sink for diagnostic log lines — the web descendant of the
  # TUI's CountingLogIO. The host points +Pikuri.log_io=+ and
  # +PikuriWeb.logger+ at one instance; every line is broadcast to the
  # browser's collapsible log panel (SSE +log+ events) and kept in a
  # bounded ring buffer so +GET /+ can replay recent history into a fresh
  # page. Unread-error counting lives client-side (app.js matches
  # severity in the line text), so this class stays a dumb fan-in.
  #
  # Implements the subset of the IO surface that stdlib +Logger+ and
  # pikuri's loggers actually call. Thread-safe: loggers on the agent
  # worker thread and Sinatra request threads write concurrently.
  class LogIO
    # Lines kept for replay into a freshly-loaded page. Old lines fall
    # off silently — the panel is a diagnostic tail, not an archive.
    MAX_LINES = 500

    # @param broadcaster [Broadcaster] fan-out for +log+ SSE events
    def initialize(broadcaster:)
      @broadcaster = broadcaster
      @mutex = Mutex.new
      @lines = []
    end

    # @param strs [Array<String>] payloads; embedded newlines split into
    #   separate log lines, blank lines are dropped
    # @return [Integer] total bytes accepted (IO#write contract)
    def write(*strs)
      strs.each do |str|
        str.to_s.split("\n").each do |line|
          next if line.strip.empty?

          push(line)
        end
      end
      strs.sum { |s| s.to_s.bytesize }
    end

    # @return [self] (IO#<< contract)
    def <<(str)
      write(str)
      self
    end

    # @return [nil] (IO#puts contract)
    def puts(*strs)
      write(*strs.map { |s| "#{s}\n" })
      nil
    end

    # @return [Array<String>] snapshot of the retained lines, oldest
    #   first; for the +GET /+ replay
    def lines
      @mutex.synchronize { @lines.dup }
    end

    # IO-protocol no-ops: every write is already delivered synchronously.
    def flush = self
    def sync = true
    def sync=(_value); end
    def close; end

    private

    # @param line [String] one non-blank log line
    def push(line)
      @mutex.synchronize do
        @lines << line
        @lines.shift(@lines.size - MAX_LINES) if @lines.size > MAX_LINES
      end
      @broadcaster.broadcast(event: :log, data: { line: line })
    end
  end
end
