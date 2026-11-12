# frozen_string_literal: true

RSpec.describe PikuriWebUI::Util::MarkdownRenderer do
  describe '.render' do
    it 'renders GFM: backtick fences and pipe tables' do
      html = PikuriWebUI::Util::MarkdownRenderer.render("```ruby\nx = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")

      assert_includes html, '<code class="language-ruby">'
      assert_includes html, '<thead>'
    end

    it 'does not hard-wrap reflowable prose' do
      html = PikuriWebUI::Util::MarkdownRenderer.render("one\ntwo\n")

      refute_includes html, '<br'
    end

    # Unrepaired, kramdown reads a headerless table with a row of literal `—-` cells.
    it 'takes an em-dash separator row for the header separator it was meant to be' do
      html = PikuriWebUI::Util::MarkdownRenderer.render("| a | b |\n|—-|—-|\n| 1 | 2 |\n")

      assert_includes html, '<thead>'
      refute_includes html, '—'
    end

    it 'leaves an em-dash in prose alone' do
      html = PikuriWebUI::Util::MarkdownRenderer.render("a — b\n")

      assert_includes html, 'a — b'
    end
  end

  # Model output is attacker-steerable (a prompt injection in a fetched page),
  # so none of kramdown's ways of writing HTML may reach the page.
  describe 'model-written markup' do
    def render(markdown) = PikuriWebUI::Util::MarkdownRenderer.render(markdown)

    it 'shows raw HTML as text, block and span' do
      html = render(%(hi <img src="x" onerror="alert(1)">\n\n<script>alert(2)</script>\n))

      refute_includes html, '<img'
      refute_includes html, '<script'
      assert_includes html, '&lt;script&gt;'
    end

    it 'shows an HTML comment as text, so no reply can forge the streaming marker' do
      refute_includes render("a\n\n<!--tail-->\n\nb\n"), '<!--'
    end

    it 'sets no attribute from an attribute list, block or span' do
      html = render(%(*em*{: onmouseover="alert(1)"}\n\n{: onclick="alert(2)"}\npara\n))

      refute_includes html, 'onmouseover="'
      refute_includes html, 'onclick="'
    end

    it 'emits nothing raw from an extension' do
      refute_includes render("{::nomarkdown}<b>x</b>{:/nomarkdown}\n"), '<b>'
    end

    it 'drops a link or image URL of a scheme that runs script, keeping the text' do
      html = render("[click](javascript:alert(1)) ![pic](JavaScript:alert(2)) [b](data:text/html,x)\n")

      assert_includes html, '<a>click</a>'
      assert_includes html, '<img alt="pic" />'
      refute_includes html, 'alert'
      refute_includes html, 'data:'
    end

    # kramdown writes an entity in an attribute through unescaped, and the
    # browser would decode this one to `javascript:`.
    it 'hands the browser a URL exactly as checked, entities and all' do
      html = render("[a](&#106;avascript:alert(1)) [b](https://x.y/?p=1&q=2)\n")

      assert_includes html, 'href="&amp;#106;avascript:alert(1)"'
      assert_includes html, 'href="https://x.y/?p=1&amp;q=2"'
    end

    it 'keeps http, https, mailto and relative links' do
      html = render("<https://a.b> [c](http://c.d) [m](mailto:x@y.z) [r](/c/1)\n")

      %w[https://a.b http://c.d mailto:x@y.z /c/1].each { |url| assert_includes html, %(href="#{url}") }
    end

    # One named `composer` or `b12` would shadow an element the page script
    # finds by id.
    it 'gives a heading no id, generated or written' do
      refute_includes render("# composer\n\n## b12 {#b12}\n"), 'id='
    end

    # Models break lines in table cells with it, where Markdown has no other way.
    it 'keeps <br> as a line break' do
      html = render("| a |\n|---|\n| one<br>two<br/>three |\n")

      assert_includes html, 'one<br />two<br />three'
    end
  end
end
