# frozen_string_literal: true

# The tool-line renderers, ported from pikuri-tui's
# Shared::ConversationTextView::Listener specs. Pure functions of their
# arguments, so nothing here needs a transcript, a broadcaster or a lock —
# which is the reason they live in a class of their own.
RSpec.describe PikuriWeb::ToolLine do
  context 'the short call line' do
    def short(name, arguments = {})
      described_class.for_call(name: name, arguments: arguments).short
    end

    it 'CamelCases a snake_case tool name and shows its first argument' do
      assert_equal 'WebSearch(rails 8 credentials)', short('web_search', query: 'rails 8 credentials')
    end

    it 'treats any run of non-alphanumerics as a word break, so MCP names read' do
      assert_equal 'McpGithubListPrs(a/b)', short('mcp__github__list_prs', repo: 'a/b')
    end

    it 'leaves a name that is already CamelCase alone' do
      assert_equal 'EnterPlanMode', short('EnterPlanMode')
    end

    it 'drops the parentheses for a tool called with no arguments' do
      assert_equal 'Calculator', short('calculator')
    end

    # The first *value*, not the first *key*: the key names the parameter and
    # the value is what was asked for.
    it 'shows the first value even when later ones are longer' do
      assert_equal 'Fetch(https://example.org)', short('fetch', url: 'https://example.org', body: 'x' * 400)
    end

    it 'caps a long argument rather than letting it run past a screen' do
      line = short('web_search', query: 'q' * 200)
      assert_equal 60, line[/\((.*)\)/, 1].length
      assert line.end_with?('…)')
    end

    it 'flattens a multi-line argument onto the one line' do
      assert_equal 'Fetch(a b)', short('fetch', url: "a\n  b")
    end

    # A name of nothing but punctuation has no words to capitalize; it still
    # has to render as *something* rather than an empty line.
    it 'falls back to the sanitized name when there is no word in it' do
      assert_equal '***(x)', short('***', path: 'x')
    end
  end

  context 'the short result line' do
    def short(content) = described_class.for_result(content: content).short

    it 'measures a result too long to read' do
      assert_equal 'OK, 4.2 kB', short('x' * 4213)
    end

    it 'counts a kB as 1000 bytes, not 1024' do
      assert_equal '5.0 kB', short('x' * 5000).split(', ').last
    end

    it 'switches to MB past a million bytes' do
      assert_equal 'OK, 1.5 MB', short('x' * 1_500_000)
    end

    # The divergence from pikuri-tui, which always measures: this shell's
    # calculator answers in one token, and "OK, 1 B" is not the answer.
    it 'shows a result short enough to read whole' do
      assert_equal '4', short('4')
    end

    it 'measures rather than shows once the content passes the inline cap' do
      assert_equal 'OK, 61 B', short('x' * 61)
    end

    it 'measures an empty result, so "returned nothing" still reads as a result' do
      assert_equal 'OK, 0 B', short('')
    end

    it 'measures a result that is nothing but whitespace' do
      assert_equal 'OK, 3 B', short("\n\n\n")
    end

    it 'reports a failure off pikuri\'s Error: prefix' do
      assert_equal 'Error: exit 1: permission denied', short("Error: exit 1: permission denied\nmore")
    end

    it 'marks a failure for the stylesheet' do
      assert described_class.for_result(content: 'Error: nope').error
      refute described_class.for_result(content: 'fine').error
    end

    it 'never marks a call as a failure, whatever it was called with' do
      refute described_class.for_call(name: 'fetch', arguments: { url: 'Error: x' }).error
    end
  end

  context 'the verbose forms' do
    it 'dumps the arguments as pikuri-tui and the terminal listeners do' do
      line = described_class.for_call(name: 'calc', arguments: { expr: '1+1' })
      assert_equal '→ calc(expr="1+1")', line.verbose
    end

    it 'keeps the observation itself' do
      assert_equal '= Results for rails 8: ok', described_class.for_result(content: 'Results for rails 8: ok').verbose
    end

    it 'truncates a long observation with the original byte count' do
      verbose = described_class.for_result(content: 'x' * 500).verbose
      assert_includes verbose, '… (500 bytes total)'
      refute_includes verbose, 'x' * 300
    end
  end

  # Pikuri::Sanitizer, not just HTML-escaping. A browser honors a bidi
  # override exactly as a terminal does: raw, this path displays as
  # "safeexe.png" while really ending in ".exe" — the whole trick.
  context 'sanitizing' do
    it 'neutralizes a bidi override in an argument' do
      html = described_class.for_call(name: 'fetch', arguments: { url: "safe‮gnp.exe" }).to_html
      assert_includes html, 'u{202e}'
      refute_includes html, "‮"
    end

    # The carve-out that does not port: pikuri-tui leaves the verbose argument
    # dump to `inspect`, which escapes ESC (already inert once HTML-escaped)
    # and passes zero-width characters straight through. So both forms
    # sanitize here, the argument dump included.
    it 'neutralizes a zero-width character inspect would have passed through' do
      html = described_class.for_call(name: 'fetch', arguments: { url: "in​visible" }).to_html
      assert_includes html, 'u{200b}'
      refute_includes html, "​"
    end

    it 'neutralizes the tool name as well as its arguments' do
      refute_includes described_class.for_call(name: "ca‭lc", arguments: {}).to_html, "‭"
    end

    it 'neutralizes an observation' do
      html = described_class.for_result(content: "Deleted‮ txet").to_html
      assert_includes html, 'u{202e}'
      refute_includes html, "‮"
    end

    # Sanitize, then cap, in that order: a cut landing inside `\u{202e}` would
    # leave a fragment that means nothing.
    it 'caps after sanitizing, so a cut cannot land inside an escape' do
      line = described_class.for_call(name: 'fetch', arguments: { url: "#{'x' * 55}‮yyy" })
      refute_includes line.short, "‮"
    end
  end

  context 'to_html' do
    let(:line) { described_class.for_call(name: 'calc', arguments: { expr: '1 < 2' }) }

    it 'escapes both forms' do
      assert_includes line.to_html, 'Calc(1 &lt; 2)'
      assert_includes line.to_html, '&quot;1 &lt; 2&quot;'
    end

    # `.block.tool_call` is white-space: pre-wrap, so a newline between the
    # spans renders as a blank line the moment both are shown at once.
    it 'leaves no whitespace between the two spans' do
      assert_includes line.to_html, '</span><span class="tool-verbose">'
    end

    it 'marks the short span for the stylesheet to pick by' do
      assert_includes line.to_html, '<span class="tool-short">'
    end

    it 'adds the error class to a failed result only' do
      assert_includes described_class.for_result(content: 'Error: nope').to_html, 'class="tool-short tool-error"'
      refute_includes described_class.for_result(content: 'fine').to_html, 'tool-error'
    end
  end
end
