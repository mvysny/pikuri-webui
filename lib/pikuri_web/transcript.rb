# frozen_string_literal: true

module PikuriWeb
  # Server-authoritative conversation transcript: an ordered, mutex-guarded
  # list of rendered HTML blocks. The single source of truth for what the
  # browser shows — +GET /+ renders a snapshot into the page, and the SSE
  # stream carries only deltas against it. So page reload, a second tab,
  # and EventSource auto-reconnect all converge on the same state with no
  # client-side bookkeeping.
  #
  # One block per logical unit, mirroring the TUI's region-per-block model:
  # user turn, streamed thinking, streamed assistant answer, tool call,
  # tool result, notice. Streaming updates rewrite a block in place
  # ({#update}); the TUI's "wipe an unfinished preview" path becomes
  # {#remove}.
  #
  # Pikuri-free by design (see the seam rule in AGENTS.md): this class
  # speaks only ids, kinds and HTML strings. Thread-safe — written from
  # the agent's worker thread (via SseListener), read from Sinatra request
  # threads.
  class Transcript
    # One rendered block. +kind+ is the CSS hook (+:user+, +:assistant+,
    # +:thinking+, +:tool_call+, +:tool_result+, +:notice+, +:error+);
    # +html+ is trusted pre-rendered markup (escaped or kramdown output —
    # escaping happened upstream in SseListener / MarkdownRenderer).
    Block = Struct.new(:id, :kind, :html, keyword_init: true)

    def initialize
      @mutex = Mutex.new
      @blocks = []
      @next_id = 0
    end

    # Append a new block and assign it the next sequential id.
    #
    # @param kind [Symbol] block kind (CSS hook)
    # @param html [String] rendered HTML content
    # @return [Block] the stored block (read its +id+ for later
    #   {#update} / {#remove} calls)
    def add(kind:, html:)
      @mutex.synchronize do
        @next_id += 1
        block = Block.new(id: "b#{@next_id}", kind: kind, html: html)
        @blocks << block
        block
      end
    end

    # Rewrite an existing block's content in place (the streaming-delta
    # path). Unknown ids are ignored — the block may have been wiped by a
    # concurrent event; the stale update is harmless either way.
    #
    # @param id [String]
    # @param html [String]
    # @return [void]
    def update(id, html)
      @mutex.synchronize do
        block = @blocks.find { |b| b.id == id }
        block&.html = html
      end
      nil
    end

    # Drop a block (the wipe-an-unfinished-preview path). Unknown ids are
    # ignored.
    #
    # @param id [String]
    # @return [void]
    def remove(id)
      @mutex.synchronize { @blocks.reject! { |b| b.id == id } }
      nil
    end

    # @return [Array<Block>] snapshot copy, in order; never shares state
    #   with the internal list (the blocks themselves are not deep-copied —
    #   treat them as read-only)
    def to_a
      @mutex.synchronize { @blocks.dup }
    end
  end
end
