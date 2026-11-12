# frozen_string_literal: true

# The tool-line renderers. Pure functions of their arguments, so nothing here
# needs a transcript, a broadcaster or a lock — which is the reason they live
# in a class of their own.
#
# What is *not* tested here any more: how `WebSearch(rails 8 credentials)` gets
# picked out of a call in the first place. That is the tool's own
# `display_name` / `describe_call` / `Result#summary`, tested in pikuri, and it
# arrives on the event. What is left for this class — and so for this file — is
# defanging those strings, capping them to a width only a renderer knows, the
# raw forms beside them, and the two-span markup.
RSpec.describe PikuriWebUI::Web::ToolLine do
  # A call as the agent hands it over: the raw name and arguments, plus the
  # display strings the tool composed from them.
  def call(name: 'web_search', arguments: {}, display_name: nil, argument: nil)
    described_class.for_call(
      name: name, arguments: arguments,
      display_name: display_name || Pikuri::Tool.display_name_for(name),
      argument: argument || Pikuri::Tool.describe_arguments(arguments)
    )
  end

  # A result as the agent hands it over: the observation, plus the tool's
  # one-line form of it.
  def result(content, summary: nil)
    described_class.for_result(content: content, summary: summary || Pikuri::Tool.describe_content(content))
  end

  context 'the short call line' do
    it 'shows the tool\'s own name and the one argument it chose' do
      assert_equal 'WebSearch(rails 8 credentials)',
                   call(display_name: 'WebSearch', argument: 'rails 8 credentials').short
    end

    # An empty argument is a tool saying there is nothing worth showing, not a
    # value we failed to find.
    it 'drops the parentheses when the tool offers no argument' do
      assert_equal 'EnterPlanMode', call(display_name: 'EnterPlanMode', argument: '').short
    end

    it 'caps a long argument rather than letting it run past a screen' do
      line = call(display_name: 'WebSearch', argument: 'q' * 200).short
      assert_equal 60, line[/\((.*)\)/, 1].length
      assert line.end_with?('…)')
    end

    # `Tool.one_line` already flattens upstream, but the cap is ours and a cap
    # over an unflattened string is a cap over the wrong length.
    it 'flattens a multi-line argument onto the one line' do
      assert_equal 'Fetch(a b)', call(display_name: 'Fetch', argument: "a\n  b").short
    end

    it 'renders what the agent derives for a tool that overrides neither' do
      assert_equal 'WebSearch(query=rails 8)', call(name: 'web_search', arguments: { query: 'rails 8' }).short
    end
  end

  context 'the short result line' do
    it 'shows the tool\'s own summary' do
      assert_equal 'Scraped 4.2 kB', result('x' * 4213, summary: 'Scraped 4.2 kB').short
    end

    # The calculator's answer *is* its status line, and pikuri's calculator
    # summarizes it as itself — nothing here measures it into "OK, 1 B".
    it 'leaves a one-token answer as the answer' do
      assert_equal '4', result('4', summary: '4').short
    end

    it 'caps a summary long enough to drown the transcript' do
      line = result('body', summary: "Error: #{'x' * 400}").short
      assert_equal 200, line.length
      assert line.end_with?('…')
    end

    it 'reports a failure off pikuri\'s Error: prefix on the observation' do
      assert result("Error: exit 1: permission denied\nmore").error
      refute result('fine').error
    end

    it 'never marks a call as a failure, whatever it was called with' do
      refute call(name: 'fetch', arguments: { url: 'Error: x' }).error
    end
  end

  context 'the verbose forms' do
    it 'dumps the arguments as pikuri-tui and the terminal listeners do' do
      assert_equal '→ calc(expr="1+1")', call(name: 'calc', arguments: { expr: '1+1' }).verbose
    end

    it 'keeps the observation itself' do
      assert_equal '= Results for rails 8: ok', result('Results for rails 8: ok').verbose
    end

    it 'truncates a long observation with the original byte count' do
      verbose = result('x' * 500).verbose
      assert_includes verbose, '… (500 bytes total)'
      refute_includes verbose, 'x' * 300
    end
  end

  # Pikuri::Sanitizer, not just HTML-escaping. A browser honors a bidi
  # override exactly as a terminal does: raw, this path displays as
  # "safeexe.png" while really ending in ".exe" — the whole trick.
  context 'sanitizing' do
    it 'neutralizes a bidi override in an argument' do
      html = call(name: 'fetch', arguments: { url: 'safe‮gnp.exe' }).to_html
      assert_includes html, 'u{202e}'
      refute_includes html, '‮'
    end

    # A tool composes its display strings out of the same model text, and
    # defangs nothing — it cannot know what chrome will show them.
    it 'neutralizes the display strings a tool composed, not just the raw dump' do
      html = described_class.for_call(name: 'fetch', arguments: {},
                                      display_name: 'Fe‮tch', argument: 'safe‮gnp.exe').to_html
      assert_includes html, 'u{202e}'
      refute_includes html, '‮'
    end

    it 'neutralizes a summary a tool composed out of the observation' do
      refute_includes result('ok', summary: 'Scraped‮ 4 kB').to_html, '‮'
    end

    # The carve-out that does not port: pikuri-tui leaves the verbose argument
    # dump to `inspect`, which escapes ESC (already inert once HTML-escaped)
    # and passes zero-width characters straight through. So both forms
    # sanitize here, the argument dump included.
    it 'neutralizes a zero-width character inspect would have passed through' do
      html = call(name: 'fetch', arguments: { url: 'in​visible' }).to_html
      assert_includes html, 'u{200b}'
      refute_includes html, '​'
    end

    it 'neutralizes the tool name as well as its arguments' do
      refute_includes call(name: 'ca‭lc', arguments: {}).to_html, '‭'
    end

    it 'neutralizes an observation' do
      html = result('Deleted‮ txet').to_html
      assert_includes html, 'u{202e}'
      refute_includes html, '‮'
    end

    # Sanitize, then cap, in that order: a cut landing inside `\u{202e}` would
    # leave a fragment that means nothing.
    it 'caps after sanitizing, so a cut cannot land inside an escape' do
      line = call(display_name: 'Fetch', argument: "#{'x' * 55}‮yyy")
      refute_includes line.short, '‮'
    end
  end

  context 'to_html' do
    let(:line) { call(name: 'calc', arguments: { expr: '1 < 2' }, display_name: 'Calc', argument: '1 < 2') }

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
      assert_includes result('Error: nope').to_html, 'class="tool-short tool-error"'
      refute_includes result('fine').to_html, 'tool-error'
    end
  end
end
