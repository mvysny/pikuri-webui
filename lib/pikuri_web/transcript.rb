# frozen_string_literal: true

module PikuriWeb
  # Server-authoritative conversation transcript: an ordered list of rendered
  # HTML blocks. The single source of truth for what the browser shows —
  # +GET /+ renders a snapshot into the page, and the SSE stream carries only
  # deltas against it. So page reload, a second tab, and EventSource
  # auto-reconnect all converge on the same state with no client-side
  # bookkeeping.
  #
  # One block per logical unit, mirroring the TUI's region-per-block model:
  # user turn, streamed thinking, streamed assistant answer, tool call,
  # tool result, notice. A streaming update replaces a block, keeping its id
  # and position ({#update}); the TUI's "wipe an unfinished preview" path
  # becomes {#remove}.
  #
  # Pikuri-free by design (see the seam rule in AGENTS.md): this class
  # speaks only ids, kinds and HTML strings. Guarded by {AppMonitor}: every
  # call must run inside a task — {#to_a}'s snapshot is what a task hands out.
  class Transcript
    # One rendered block. +kind+ is the CSS hook (+:user+, +:assistant+,
    # +:thinking+, +:tool_call+, +:tool_result+, +:notice+, +:error+);
    # +html+ is trusted pre-rendered markup (escaped or kramdown output —
    # escaping happened upstream in SseListener / MarkdownRenderer).
    #
    # +Data+, so a block handed out by {#to_a} cannot be rewritten under the
    # reader that holds it: {#update} replaces the element instead of mutating
    # it. A mutable Struct made the snapshot a copy of the *list* only, which
    # left a request thread rendering the page able to read a block mid-delta.
    Block = Data.define(:id, :kind, :html)

    # @param monitor [AppMonitor] the domain every call must be inside
    def initialize(monitor:)
      @monitor = monitor
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
      @monitor.assert!
      @next_id += 1
      block = Block.new(id: "b#{@next_id}", kind: kind, html: html)
      @blocks << block
      block
    end

    # Replace an existing block's content, keeping its id and position (the
    # streaming-delta path). Unknown ids are ignored — the block may have been
    # wiped by a concurrent event; the stale update is harmless either way.
    #
    # @param id [String]
    # @param html [String]
    # @return [void]
    def update(id, html)
      @monitor.assert!
      index = @blocks.index { |b| b.id == id }
      @blocks[index] = @blocks[index].with(html: html) if index
      nil
    end

    # Drop a block (the wipe-an-unfinished-preview path). Unknown ids are
    # ignored.
    #
    # @param id [String]
    # @return [void]
    def remove(id)
      @monitor.assert!
      @blocks.reject! { |b| b.id == id }
      nil
    end

    # Drop every block.
    #
    # The id counter is deliberately *not* reset: a browser tab that has not
    # yet applied the clear would otherwise see a fresh +b1+ and upsert it into
    # the block it still has on screen.
    #
    # @return [void]
    def clear
      @monitor.assert!
      @blocks.clear
      nil
    end

    # @return [Array<Block>] snapshot, in order — a consistent one: the list is
    #   copied and the blocks in it are immutable, so the caller's task can end
    #   and the snapshot stays good while a turn streams in behind it
    def to_a
      @monitor.assert!
      @blocks.dup
    end
  end
end
