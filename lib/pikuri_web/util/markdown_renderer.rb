# frozen_string_literal: true

require 'kramdown'
require 'kramdown-parser-gfm'
require 'streaming_markdown_parser'
require 'cgi'

module PikuriWeb
  module Util
    # Markdown → HTML for text a model wrote, which a prompt injection can steer,
    # so it renders Markdown and nothing a page could run:
    #
    #   MarkdownRenderer.render("**hi** <img src=x onerror=alert(1)>")
    #   # => "<p><strong>hi</strong> &lt;img src=x onerror=alert(1)&gt;</p>\n"
    #   MarkdownRenderer.render("[a](javascript:alert(1))")   # => "<p><a>a</a></p>\n"
    #
    # A whole text goes through {.render}; a block already parsed (a streamed
    # one) through {.to_html}, with the parser built on {OPTIONS}.
    #
    # Parses as pikuri-tui does, so a reply renders alike in both shells —
    # GFM, no hard wraps, after +StreamingMarkdownParser::Repair+ (an em-dash
    # table separator row) — except for what {Parser} leaves out.
    #
    # Degrades to escaped raw text when kramdown raises: on a long-running
    # chat we'd rather show ugly Markdown than lose an in-flight message.
    # Same "library exceptions are logged, our bugs raise" rule as the TUI.
    #
    # == Implementation details
    #
    # Two layers. {Parser} never recognizes raw HTML, attribute lists or
    # extensions, so they read as the literal text the model wrote. {.scrub}
    # then holds every element to {ATTRIBUTES}, and a link or image to
    # {SCHEMES}, whatever syntax produced it. No heading gets an +id+: one
    # named +composer+ or +b12+ would shadow an element the page script looks
    # up by id.
    module MarkdownRenderer
      # GFM without kramdown's ways of writing HTML: no raw HTML, block or span;
      # no +{: …}+ attribute lists, which set any attribute, +onclick+ included;
      # no +{::nomarkdown}+ extensions, which emit raw output. +<br>+ alone stays,
      # as a line break — models put it in table cells, where Markdown has no
      # other way to break a line.
      class Parser < Kramdown::Parser::GFM
        # @return [Regexp]
        BR_TAG = %r{<br\s*/?>}i

        # @param source [String]
        # @param options [Hash{Symbol => Object}]
        def initialize(source, options)
          super
          @block_parsers -= %i[block_html block_extensions]
          @span_parsers -= %i[span_html span_extensions]
          @span_parsers.unshift(:br_tag)
        end

        # @return [void]
        def configure_parser
          super
          # Looked up by name, not through the lists: kramdown's table parser
          # splits rows with it, and only to find pipes inside <code>.
          @parsers[:span_html] = self.class.parser(:span_html)
        end

        # @return [void]
        def parse_br_tag
          @src.pos += @src.matched_size
          @tree.children << Kramdown::Element.new(:br, nil, nil, location: @src.current_line_number)
        end
        define_parser(:br_tag, BR_TAG, '<')
      end

      # kramdown finds a parser by +input+ name, and only under its own namespace.
      #
      # @return [Class]
      Kramdown::Parser::PikuriWebGfm = Parser

      # kramdown options every parse and conversion here runs with.
      #
      # @return [Hash{Symbol => Object}]
      OPTIONS = StreamingMarkdownParser::DEFAULT_OPTIONS.merge(input: 'PikuriWebGfm', auto_ids: false).freeze

      # The attributes an element may keep; a code block's +class+ is checked
      # apart, in {.scrub}.
      #
      # @return [Array<String>]
      ATTRIBUTES = %w[href src alt title].freeze

      # URL schemes a link or image may carry; a URL with no scheme is relative.
      #
      # @return [Array<String>]
      SCHEMES = %w[http https mailto].freeze

      # Elements {Parser} never produces, removed should one appear anyway: each
      # writes its content to the page as markup.
      #
      # @return [Array<Symbol>]
      RAW_TYPES = %i[html_element xml_comment xml_pi raw].freeze

      private_constant :ATTRIBUTES, :SCHEMES, :RAW_TYPES

      module_function

      # @param markdown [String] Markdown source (assistant or thinking
      #   content)
      # @return [String] HTML, or the escaped source wrapped in +<pre>+ when
      #   kramdown raises (logged, not raised)
      def render(markdown)
        to_html(StreamingMarkdownParser.parse(markdown.to_s, **OPTIONS))
      rescue StandardError => e
        PikuriWeb.logger.warn(
          "MarkdownRenderer.render failed (#{e.class}: #{e.message}); falling back to raw text"
        )
        "<pre>#{escape(markdown)}</pre>"
      end

      # Converts a tree parsed with {OPTIONS}, after {.scrub}bing it.
      #
      # @param root [Kramdown::Element] a +:root+
      # @return [String] HTML
      # @raise [StandardError] whatever kramdown's converter raises
      def to_html(root)
        Kramdown::Converter::Html.convert(scrub(root), OPTIONS).first
      end

      # Holds a tree to what may reach the page, in place.
      #
      #   [x](javascript:alert(1))   # => <a>x</a>, the link's text kept
      #   [x](/c/1?a=1&b=2)          # => href "/c/1?a=1&amp;b=2", as written
      #
      # A URL attribute is checked as the literal text the model wrote, then has
      # its +&+ escaped, so the browser decodes back exactly that text: kramdown
      # writes an entity in an attribute through unescaped, and +&#106;avascript:+
      # would decode to +javascript:+ after the check had passed it as relative.
      #
      # @param element [Kramdown::Element]
      # @return [Kramdown::Element] +element+
      def scrub(element)
        element.children.reject! { |child| RAW_TYPES.include?(child.type) }
        element.attr.select! { |name, value| keep?(element, name, value) }
        %w[href src].each do |name|
          element.attr[name] = element.attr[name].gsub('&', '&amp;') if element.attr.key?(name)
        end
        element.children.each { |child| scrub(child) }
        element
      end

      # @param element [Kramdown::Element]
      # @param name [String] attribute name
      # @param value [String] attribute value
      # @return [Boolean]
      def keep?(element, name, value)
        case name
        when 'href', 'src' then safe_url?(value)
        when 'class' then element.type == :codeblock && value.match?(/\Alanguage-[\w+#.-]+\z/)
        else ATTRIBUTES.include?(name)
        end
      end

      # @param url [String] as written
      # @return [Boolean] true when relative, or of a scheme in {SCHEMES}
      def safe_url?(url)
        scheme = url[%r{\A([^:/?#]*):}, 1]
        scheme.nil? || SCHEMES.include?(scheme.downcase)
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
