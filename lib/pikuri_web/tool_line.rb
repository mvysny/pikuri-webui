# frozen_string_literal: true

require 'pikuri-core'

module PikuriWeb
  # One tool event as the two lines a transcript block carries — the short form
  # and the raw one — plus the markup that lets CSS pick between them:
  #
  #   line = ToolLine.for_call(name: 'web_search', arguments: { query: 'rails 8 credentials' })
  #   line.short     # => 'WebSearch(rails 8 credentials)'
  #   line.verbose   # => '→ web_search(query="rails 8 credentials")'
  #   line.to_html   # => '<span class="tool-short">WebSearch(…)</span><span class="tool-verbose">…'
  #
  #   ToolLine.for_result(content: 'x' * 4213).short      # => 'OK, 4.2 kB'
  #   ToolLine.for_result(content: '4').short             # => '4'
  #   ToolLine.for_result(content: 'Error: exit 1').error # => true
  #
  # A block carries both forms and +:root[data-tools]+ shows one, so a flip
  # re-renders nothing and the server holds no display preference
  # (+D_both_forms_in_the_block+).
  #
  # == Implementation details
  #
  # Every string here is model-composed or tool-returned, so *both* forms run
  # through +Pikuri::Sanitizer+ before {MarkdownRenderer.escape}: escaping
  # stops markup, not a bidi override that reorders a filename. +inspect+ is
  # no substitute — it escapes the +ESC+ that escaping already renders inert
  # and passes bidi, zero-width and homoglyphs straight through, which is why
  # pikuri-tui's "verbose arguments are safe on +inspect+ alone" carve-out
  # does not port. Sanitize, then flatten, then cap, in that order, so a cut
  # cannot land inside an escaped +\u{202e}+ token.
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

    # Cap on the raw result line, and on the one line a failure is shown as.
    # A rendered page or a PDF's text would otherwise drown the transcript.
    RESULT_MAX_CHARS = 200

    # A result this short is shown instead of measured; see {.for_result}.
    RESULT_INLINE_MAX_CHARS = 60

    # The two forms for a +ToolCall+.
    #
    #   ToolLine.for_call(name: 'mcp__github__list_prs', arguments: { repo: 'a/b' })
    #   # short: 'McpGithubListPrs(a/b)'
    #   ToolLine.for_call(name: 'enter_plan_mode', arguments: {})
    #   # short: 'EnterPlanMode'          — no argument, so no parentheses
    #
    # The first *value* of +arguments+ stands in for the primary parameter:
    # models emit keys in schema order and the first schema parameter is the
    # primary one for every tool this shell wires (+query+, +url+,
    # +expression+). The event carries no schema, so there is nothing better
    # to pick by until pikuri's own summaries carry the choice.
    #
    # @param name [String] the registered tool name.
    # @param arguments [Hash] the tool-call arguments.
    # @return [ToolLine]
    def self.for_call(name:, arguments:)
      called = display_name(name)
      argument = display_argument(arguments)
      new(short: argument.empty? ? called : "#{called}(#{argument})",
          verbose: verbose_call(name, arguments), error: false)
    end

    # The two forms for a +ToolResult+.
    #
    #   ToolLine.for_result(content: page)   # a 4213-byte scrape
    #   # short: 'OK, 4.2 kB', verbose: '= Results for rails 8: the master key…'
    #   ToolLine.for_result(content: '4')
    #   # short: '4'          — short enough to read, so it is not measured
    #
    # That last case is a deliberate divergence from pikuri-tui, which always
    # measures: this shell's +calculator+ answers in one token, and +OK, 1 B+
    # is not the answer. The size still earns its place on everything longer,
    # where it separates a +fetch+ that returned nothing from one that
    # returned plenty.
    #
    # Failure is read off the +Error:+ prefix, because pikuri's +Tool#run+
    # returns recoverable failures as +"Error: …"+ strings while a genuine
    # raise aborts the turn without ever reaching a +ToolResult+. Still a
    # heuristic — a +web_scrape+ of a page that opens that way misreports —
    # and one pikuri's summaries will retire.
    #
    # @param content [String] the tool observation.
    # @return [ToolLine]
    def self.for_result(content:)
      text = content.to_s
      error = text.start_with?('Error:')
      new(short: short_result(text, error), verbose: "= #{truncate(text)}", error: error)
    end

    # Both forms as one line of markup, escaped, with no whitespace between
    # the spans — the block is +white-space: pre-wrap+, so a newline here is a
    # blank line the moment a stylesheet shows both at once.
    #
    # @return [String] two +<span>+s, +tool-short+ and +tool-verbose+.
    def to_html
      "<span class=\"tool-short#{error ? ' tool-error' : ''}\">" \
        "#{MarkdownRenderer.escape(short)}</span>" \
        "<span class=\"tool-verbose\">#{MarkdownRenderer.escape(verbose)}</span>"
    end

    # @param text [String] the observation.
    # @param error [Boolean] whether it carries pikuri's +Error:+ prefix.
    # @return [String] the short result line.
    def self.short_result(text, error)
      return cap(flatten(text.lines.first.to_s), RESULT_MAX_CHARS) if error

      flat = flatten(text)
      return "OK, #{format_size(text.bytesize)}" if flat.empty? || flat.length > RESULT_INLINE_MAX_CHARS

      flat
    end

    # @param name [String]
    # @param arguments [Hash]
    # @return [String] the raw call line, +→ web_search(query="…")+.
    def self.verbose_call(name, arguments)
      args = arguments.map { |key, value| "#{key}=#{neutralize(value.inspect)}" }.join(', ')
      "→ #{neutralize(name)}(#{args})"
    end

    # +web_search+ → +WebSearch+, +mcp__github__list_prs+ → +McpGithubListPrs+,
    # +EnterPlanMode+ → unchanged.
    #
    # Any run of non-alphanumerics is a word break, which is what makes an MCP
    # name readable.
    #
    # @param name [String] the registered tool name.
    # @return [String]
    def self.display_name(name)
      words = name.to_s.scan(/[[:alnum:]]+/)
      words.empty? ? flatten(name.to_s) : words.map { |word| word.sub(/\A./, &:upcase) }.join
    end

    # @param arguments [Hash] the tool-call arguments.
    # @return [String] the first value as one capped line, or +""+ for a tool
    #   called with none.
    def self.display_argument(arguments)
      value = arguments.values.first
      value.nil? ? '' : cap(flatten(value.to_s), ARGUMENT_MAX_CHARS)
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

    # @param bytes [Integer]
    # @return [String] +"340 B"+ / +"4.9 kB"+ / +"1.2 MB"+ — SI, so a kB is
    #   1000 bytes rather than the common-but-wrong 1024.
    def self.format_size(bytes)
      return "#{bytes} B" if bytes < 1000
      return format('%.1f kB', bytes / 1000.0) if bytes < 1_000_000

      format('%.1f MB', bytes / 1_000_000.0)
    end

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

    private_class_method :short_result, :verbose_call, :display_name, :display_argument,
                         :truncate, :cap, :format_size, :neutralize, :flatten
  end
end
