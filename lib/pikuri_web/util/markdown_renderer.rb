# frozen_string_literal: true

require 'kramdown'
require 'kramdown-parser-gfm'
require 'streaming_markdown_parser'
require 'cgi'

module PikuriWeb
  module Util
    # Markdown → HTML, the web analogue of the TUI's MarkdownRenderer
    # (Markdown → ANSI). Stateless module function; width is not a concern
    # here — the browser is the layout engine.
    #
    #   MarkdownRenderer.render("| a | b |\n|—-|—-|\n| 1 | 2 |")   # => a table, header and all
    #
    # Parses as pikuri-tui does, so a reply renders alike in both shells:
    # +StreamingMarkdownParser::DEFAULT_OPTIONS+ (GFM, no hard wraps), after
    # +StreamingMarkdownParser::Repair+ — without it, that em-dash separator
    # row makes kramdown read a headerless table with a row of literal +—-+.
    #
    # Degrades to escaped raw text when kramdown raises: on a long-running
    # chat we'd rather show ugly Markdown than lose an in-flight message.
    # Same "library exceptions are logged, our bugs raise" rule as the TUI.
    module MarkdownRenderer
      module_function

      # @param markdown [String] Markdown source (assistant or thinking
      #   content)
      # @return [String] HTML, or the escaped source wrapped in +<pre>+ when
      #   kramdown raises (logged, not raised)
      def render(markdown)
        Kramdown::Document.new(StreamingMarkdownParser::Repair.call(markdown.to_s),
                               **StreamingMarkdownParser::DEFAULT_OPTIONS).to_html
      rescue StandardError => e
        PikuriWeb.logger.warn(
          "MarkdownRenderer.render failed (#{e.class}: #{e.message}); falling back to raw text"
        )
        "<pre>#{escape(markdown)}</pre>"
      end

      # HTML-escape helper for the plain-text block paths (user turns, tool
      # lines, notices) that bypass Markdown entirely.
      #
      # @param text [String]
      # @return [String] HTML-escaped text
      def escape(text)
        CGI.escape_html(text.to_s)
      end
    end
  end
end
