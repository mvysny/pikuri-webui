# frozen_string_literal: true

module PikuriWeb
  module Web
    # Delta accumulator for one streamed message (assistant answer or
    # thinking block): the web descendant of the TUI's
    # StreamingMarkdownBuffer, keeping its lifecycle contract but none of
    # its machinery.
    #
    # What carries over from the TUI buffer:
    #
    # - One instance per streamed turn; {#append} per delta, {#finalize}
    #   exactly once with the authoritative bookend content. Deltas are
    #   preview-only — pikuri makes no guarantee that +deltas.join ==
    #   Assistant#content+ — so finalize replaces the accumulated source
    #   and re-renders.
    # - The fast path: {#finalize} with content equal to {#source} (the
    #   cancel-preserve case) skips the re-render and returns the cached
    #   HTML.
    # - Dead after finalize: further calls raise.
    #
    # What doesn't, and why: the block-cutter / committed-prefix machinery
    # existed to bound per-token TTY::Markdown cost on a terminal that
    # re-splices regions per hard line. Here each {#append} re-renders the
    # whole accumulated source through kramdown (~1 ms at chat sizes) and
    # the browser replaces one div's innerHTML — at the 15 fps the
    # RateLimited listener delivers, that's negligible, and Markdown's
    # retroactive reformatting (a closing fence, a widening table row)
    # falls out for free. If pathological message sizes ever bite, the
    # surface to optimize is {#append}'s render call — the API stays put.
    #
    # Render failures inside +render+ are the renderer's concern
    # (Util::MarkdownRenderer degrades to escaped text rather than raising);
    # this class treats the callable as total.
    #
    # Not thread-safe; driven only from the agent worker thread via
    # SseListener.
    class StreamingMessage
      # @return [String] transcript block id this message renders into
      attr_reader :id

      # @param id [String] transcript block id (assigned by Transcript#add)
      # @param render [#call] Markdown +String+ → HTML +String+; typically
      #   +Util::MarkdownRenderer.method(:render)+
      def initialize(id:, render:)
        @id = id
        @render = render
        @source = +''
        @html = ''
        @finalized = false
      end

      # Feed one streamed Markdown chunk and re-render.
      #
      # @param content [String, nil] the delta payload; nil/empty is a
      #   no-op returning the current HTML
      # @return [String] HTML of the full accumulated source
      # @raise [RuntimeError] if called after {#finalize}
      def append(content)
        raise 'StreamingMessage#append called after #finalize' if @finalized
        return @html if content.nil? || content.empty?

        @source << content
        @html = @render.call(@source)
      end

      # Replace the accumulated source with the authoritative bookend
      # content and render once more. Fast path: when +authoritative+
      # equals {#source} the cached HTML is returned without re-rendering.
      #
      # @param authoritative [String] the final Markdown for this turn
      # @return [String] final HTML
      # @raise [RuntimeError] if called more than once
      def finalize(authoritative)
        raise 'StreamingMessage#finalize called twice' if @finalized

        @finalized = true
        return @html if authoritative == @source

        @source = authoritative.to_s.dup
        @html = @render.call(@source)
      end

      # @return [Boolean] +true+ after {#finalize} has run
      def finalized? = @finalized

      # @return [String] the accumulated Markdown source. Exposed so the
      #   owner can call +finalize(source)+ on a cancellation path to
      #   commit the preview as-is.
      attr_reader :source
    end
  end
end
