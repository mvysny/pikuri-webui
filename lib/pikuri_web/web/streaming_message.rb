# frozen_string_literal: true

require 'streaming_markdown_parser'

module PikuriWeb
  module Web
    # One streamed message (assistant answer or thinking block), rendered as it
    # arrives: each top-level block the reply finishes is rendered once and sent
    # once, and only the open tail after it is re-rendered per delta
    # (+D_stream_blocks_once+).
    #
    #   msg = StreamingMessage.new(id: 'b7')
    #   msg.append("Hello.\n\nWor")    # full: "<!--tail--><p>Hello.</p>\n<p>Wor</p>\n"
    #   msg.append("ld.\n\nAnd")       # diff: append "<p>Hello.</p>\n"
    #                                  #       tail   "<p>World.</p>\n<p>And</p>\n"
    #   msg.finalize(final_markdown)   # full: the whole reply rendered afresh, no marker
    #
    # "Hello." stays in the tail until a complete line after the blank one shows
    # kramdown it is finished.
    #
    # Every {Frame} carries the block's whole html, for {Transcript#update}, and
    # says what a tab must do: replace the block (a full frame — the first one,
    # and the last) or apply a diff around the {MARKER} comment the html carries
    # between the finished blocks and the tail.
    #
    # {#finalize} renders the authoritative text whole, never the concatenated
    # blocks: deltas are only a preview of it, and only the whole text resolves a
    # reference link or footnote whose definition is a block away.
    #
    # == Implementation details
    #
    # A kramdown failure inside the parser is logged, and the message falls back
    # to rendering its whole source per delta through {Util::MarkdownRenderer}
    # (which degrades to escaped text), sent as full frames with no marker — the
    # parser's state after a raise mid-scan is not something to keep appending
    # to.
    #
    # Dead after {#finalize}: {#append} and a second {#finalize} raise.
    class StreamingMessage
      include StreamingMarkdownParser::Listener

      # Where the finished blocks end and the open tail begins, in the stored
      # html and in the tab's DOM. A comment, so neither CSS nor layout sees it;
      # +transcript.js+ matches its text.
      #
      # @return [String]
      MARKER = '<!--tail-->'

      # What one {#append} / {#finalize} produced.
      #
      # @!attribute [r] html
      #   @return [String] the block's whole html as it now stands
      # @!attribute [r] append
      #   @return [String, nil] html of the blocks this delta finished, to insert
      #     before {MARKER}; +nil+ for a full frame, which replaces the block
      # @!attribute [r] tail
      #   @return [String, nil] the open tail's html, replacing what follows
      #     {MARKER}; +nil+ for a full frame
      Frame = Data.define(:html, :append, :tail) do
        # @return [Boolean] true when a tab replaces the whole block with {#html}
        def full? = append.nil?
      end

      # @return [String] transcript block id this message renders into
      attr_reader :id

      # @param id [String] transcript block id (assigned by Transcript#add)
      def initialize(id:)
        @id = id
        @parser = StreamingMarkdownParser.new(self, **Util::MarkdownRenderer::OPTIONS)
        @source = +''
        @done = +''
        @fresh = +''
        @tail = ''
        @sent = false
        @broken = false
        @finalized = false
      end

      # Feeds one streamed Markdown chunk.
      #
      # @param content [String, nil] the delta payload
      # @return [Frame, nil] what to store and send; +nil+ when nothing a tab
      #   shows changed (an empty delta, or one that only grew a line not yet
      #   rendering differently)
      # @raise [RuntimeError] if called after {#finalize}
      def append(content)
        raise 'StreamingMessage#append called after #finalize' if @finalized
        return if content.nil? || content.empty?

        @source << content
        return full(Util::MarkdownRenderer.render(@source)) if @broken

        before = @tail
        @fresh = +''
        begin
          @parser.append(content)
        rescue StandardError => e
          PikuriWeb.logger.warn("StreamingMessage: streamed parse failed (#{e.class}: #{e.message}); " \
                                'rendering whole from here on')
          @broken = true
          return full(Util::MarkdownRenderer.render(@source))
        end
        return full(html) unless @sent
        return if @fresh.empty? && @tail == before

        Frame.new(html: html, append: @fresh, tail: @tail)
      end

      # Ends the stream with the authoritative bookend content, rendered whole.
      #
      # @param authoritative [String] the final Markdown for this turn
      # @return [Frame] a full frame
      # @raise [RuntimeError] if called more than once
      def finalize(authoritative)
        raise 'StreamingMessage#finalize called twice' if @finalized

        @finalized = true
        full(Util::MarkdownRenderer.render(authoritative))
      end

      # @return [Boolean] +true+ after {#finalize} has run
      def finalized? = @finalized

      # @param root [Kramdown::Element] one finished top-level block
      # @return [void]
      def on_block(root)
        block = convert(root)
        @done << block
        @fresh << block
      end

      # @param root [Kramdown::Element] the open tail
      # @return [void]
      def on_open(root)
        @tail = convert(root)
      end

      private

      # @return [String] the block's html: finished blocks, marker, open tail
      def html = "#{@done}#{MARKER}#{@tail}"

      # @param html [String]
      # @return [Frame] a frame that replaces the whole block
      def full(html)
        @sent = true
        Frame.new(html: html, append: nil, tail: nil)
      end

      # @param root [Kramdown::Element]
      # @return [String] html
      def convert(root) = Util::MarkdownRenderer.to_html(root)
    end
  end
end
