# frozen_string_literal: true

RSpec.describe PikuriWeb::Web::StreamingMessage do
  let(:marker) { described_class::MARKER }

  def build = described_class.new(id: 'b1')

  # What transcript.js#stream does to a block's DOM, done to its html.
  def splice(html, frame)
    done, = html.split(marker, 2)
    "#{done}#{frame.append}#{marker}#{frame.tail}"
  end

  context '#append' do
    it 'sends the first render as a full frame, marker included' do
      frame = build.append("Hello.\n\nWor")

      assert frame.full?
      assert_equal "#{marker}<p>Hello.</p>\n<p>Wor</p>\n", frame.html
    end

    it 'sends a finished block once, then only the open tail' do
      msg = build
      msg.append("Hello.\n\nWor")
      frame = msg.append("ld.\n\nAnd")

      refute frame.full?
      assert_equal "<p>Hello.</p>\n", frame.append
      assert_equal "<p>World.</p>\n<p>And</p>\n", frame.tail

      frame = msg.append(' more')
      assert_equal '', frame.append
      assert_equal "<p>World.</p>\n<p>And more</p>\n", frame.tail
    end

    # The contract the client rests on: a tab holding the last frame's html and
    # applying this diff around the marker holds this frame's html.
    it 'diffs that, spliced around the marker, give the stored html' do
      msg = build
      html = msg.append("# Title\n\nSome ").html
      ["prose.\n\n- one\n", "- two\n\n```ruby\nx = 1\n", "```\n\n| a | b |\n|---|---|\n", "| 1 | 2 |\n\nEnd"]
        .each do |delta|
          frame = msg.append(delta)
          html = splice(html, frame)
          assert_equal frame.html, html
        end
      assert_includes html, '<h1'
      assert_includes html, '<table>'
    end

    # Streamed blocks are converted one by one, not through MarkdownRenderer.render.
    it 'escapes model-written markup in streamed blocks as in a whole render' do
      msg = build
      msg.append(%(<img src="x" onerror="alert(1)">\n\n[a](javascript:alert(2))\n\n<!--tail-->\n\nend))

      html = msg.append("\n\nmore").html
      refute_includes html, '<img'
      refute_includes html, 'javascript:'
      assert_equal 1, html.scan(marker).size
    end

    it 'sends nothing for a delta that changes nothing' do
      msg = build
      msg.append('hi')

      assert_nil msg.append(nil)
      assert_nil msg.append('')
    end

    it 'raises after finalize' do
      msg = build
      msg.finalize('done')
      assert_raises(RuntimeError) { msg.append('more') }
    end
  end

  context '#finalize' do
    it 'renders the authoritative content whole, as a full frame with no marker' do
      msg = build
      msg.append("Helo wrold.\n\nNext")
      frame = msg.finalize("Hello world.\n\nNext")

      assert frame.full?
      assert_includes frame.html, 'Hello world.'
      refute_includes frame.html, marker
      assert msg.finalized?
    end

    # A block alone can't see a definition a block away; the whole text can.
    it 'resolves a reference whose definition streamed a block away' do
      msg = build
      text = "See [the docs][1].\n\nMore.\n\n[1]: https://example.com\n"
      streamed = msg.append(text)
      refute_includes streamed.html, 'href'

      assert_includes msg.finalize(text).html, 'href="https://example.com"'
    end

    it 'raises when called twice' do
      msg = build
      msg.finalize('done')
      assert_raises(RuntimeError) { msg.finalize('again') }
    end
  end
end
