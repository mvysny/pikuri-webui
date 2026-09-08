# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  module Web
    # One tool event as the two lines a transcript block carries — the short form
    # and the raw one — plus the markup that lets CSS pick between them:
    #
    #   line = ToolLine.for_call(name: 'web_search', arguments: { query: 'rails 8 credentials' },
    #                            display_name: 'WebSearch', argument: 'rails 8 credentials')
    #   line.short     # => 'WebSearch(rails 8 credentials)'
    #   line.verbose   # => '→ web_search(query="rails 8 credentials")'
    #   line.to_html   # => '<span class="tool-short">WebSearch(…)</span><span class="tool-verbose">…'
    #
    #   ToolLine.for_result(content: page, summary: 'Scraped 4.2 kB').short  # => 'Scraped 4.2 kB'
    #   ToolLine.for_result(content: 'Error: exit 1', summary: 'Error: exit 1').error # => true
    #
    # A block carries both forms and +:root[data-tools]+ shows one, so a flip
    # re-renders nothing and the server holds no display preference
    # (+D_both_forms_in_the_block+).
    #
    # The short form is the *tool's*: +display_name+, +argument+ and +summary+
    # arrive on the event, composed upstream (+../pikuri+ +D_tool_summary_lines+).
    # Defanging them and capping them to a width only a renderer knows are the two
    # jobs left here. The verbose form is ours end to end, off the raw +name+ /
    # +arguments+ / +content+ beside them.
    #
    # == Implementation details
    #
    # Every string here is model-composed or tool-returned, so *both* forms run
    # through +Pikuri::Sanitizer+ before {Util::MarkdownRenderer.escape}: escaping
    # stops markup, not a bidi override that reorders a filename. +inspect+ is
    # no substitute — it escapes the +ESC+ that escaping already renders inert
    # and passes bidi, zero-width and homoglyphs straight through, which is why
    # pikuri-tui's "verbose arguments are safe on +inspect+ alone" carve-out
    # does not port. A tool's own display strings are no exception — composed
    # *from* model text, by a tool that cannot know what chrome will show them.
    # Sanitize, then flatten, then cap, in that order, so a cut cannot land
    # inside an escaped +\u{202e}+ token.
    #
    # @!attribute [r] short
    #   @return [String] the toned-down form: +Fetch(https://example.org)+.
    # @!attribute [r] verbose
    #   @return [String] the raw form: the argument dump, or the observation.
    # @!attribute [r] error
    #   @return [Boolean] whether {#short} reports a failure, which is a CSS
    #     hook rather than control flow — nothing here gates on it.
    class ToolLine < Data.define(:short, :verbose, :error)
      # Cap on the short call line's one argument, so a pasted URL or a page of
      # prompt text cannot push the line past a screen.
      ARGUMENT_MAX_CHARS = 60

      # Cap on the raw result line, and on the short line a tool composed.
      # A rendered page or a PDF's text would otherwise drown the transcript.
      RESULT_MAX_CHARS = 200

      # The two forms for a +ToolCall+.
      #
      #   ToolLine.for_call(name: 'mcp__github__list_prs', arguments: { repo: 'a/b' },
      #                     display_name: 'Github::ListPrs', argument: 'a/b')
      #   # short: 'Github::ListPrs(a/b)'
      #   ToolLine.for_call(name: 'enter_plan_mode', arguments: {},
      #                     display_name: 'EnterPlanMode', argument: '')
      #   # short: 'EnterPlanMode'          — no argument, so no parentheses
      #
      # An empty +argument+ is a tool saying there is nothing worth showing, not
      # a value we failed to find.
      #
      # @param name [String] the registered tool name, for the raw form.
      # @param arguments [Hash] the tool-call arguments, for the raw form.
      # @param display_name [String] the tool's name for itself.
      # @param argument [String] the one argument it wants shown; +""+ renders
      #   the call bare.
      # @return [ToolLine]
      def self.for_call(name:, arguments:, display_name:, argument:)
        called = flatten(display_name.to_s)
        shown = cap(flatten(argument.to_s), ARGUMENT_MAX_CHARS)
        new(short: shown.empty? ? called : "#{called}(#{shown})",
            verbose: verbose_call(name, arguments), error: false)
      end

      # The two forms for a +ToolResult+.
      #
      #   ToolLine.for_result(content: page, summary: 'Scraped 4.2 kB')
      #   # short: 'Scraped 4.2 kB', verbose: '= Results for rails 8: the master key…'
      #   ToolLine.for_result(content: '4', summary: '4')
      #   # short: '4'          — the calculator's answer *is* its status line
      #
      # Failure is read off +content+'s +Error:+ prefix — the same test
      # +Pikuri::Tool::Result#error?+ applies, since +Tool#run+ returns a
      # recoverable failure as an +"Error: …"+ observation while a genuine raise
      # aborts the turn before any +ToolResult+. Not off +summary+: an error's
      # summary carries the prefix too, but only by +Result.error+'s convention.
      #
      # @param content [String] the tool observation, for the raw form.
      # @param summary [String] the tool's own one-line display form.
      # @return [ToolLine]
      def self.for_result(content:, summary:)
        text = content.to_s
        new(short: cap(flatten(summary.to_s), RESULT_MAX_CHARS),
            verbose: "= #{truncate(text)}", error: text.start_with?('Error:'))
      end

      # Both forms as one line of markup, escaped, with no whitespace between
      # the spans — the block is +white-space: pre-wrap+, so a newline here is a
      # blank line the moment a stylesheet shows both at once.
      #
      # @return [String] two +<span>+s, +tool-short+ and +tool-verbose+.
      def to_html
        "<span class=\"tool-short#{error ? ' tool-error' : ''}\">" \
          "#{Util::MarkdownRenderer.escape(short)}</span>" \
          "<span class=\"tool-verbose\">#{Util::MarkdownRenderer.escape(verbose)}</span>"
      end

      # @param name [String]
      # @param arguments [Hash]
      # @return [String] the raw call line, +→ web_search(query="…")+.
      def self.verbose_call(name, arguments)
        args = arguments.map { |key, value| "#{key}=#{neutralize(value.inspect)}" }.join(', ')
        "→ #{neutralize(name)}(#{args})"
      end

      # Flatten and cap, with the *original* byte count as the suffix so a
      # truncated line still says how much there was.
      #
      # @param text [String]
      # @return [String]
      def self.truncate(text)
        flat = flatten(text)
        return flat if flat.length <= RESULT_MAX_CHARS

        "#{flat[0, RESULT_MAX_CHARS]}… (#{text.bytesize} bytes total)"
      end

      # @param text [String]
      # @param limit [Integer]
      # @return [String] +text+ elided to +limit+ characters, ellipsis included.
      def self.cap(text, limit) = text.length <= limit ? text : "#{text[0, limit - 1]}…"

      # Make dangerous codepoints visible: a filename a browser *displays* as
      # +safeexe.png+ comes out spelling the bidi override that reordered it,
      # +.exe+ and all. See the class header for why both forms run through it.
      #
      # Warnings are dropped: nothing in this shell gates a tool on them, and a
      # chat transcript has no confirmation prompt to hang them off.
      #
      # @param text [String] model-composed or tool-returned text.
      # @return [String]
      def self.neutralize(text) = Pikuri::Sanitizer.sanitize(text.to_s).text

      # @param text [String]
      # @return [String] sanitized, then collapsed to one line.
      def self.flatten(text) = neutralize(text).gsub(/\s+/, ' ').strip

      private_class_method :verbose_call, :truncate, :cap, :neutralize, :flatten
    end
  end
end
