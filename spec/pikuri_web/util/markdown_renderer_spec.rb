# frozen_string_literal: true

RSpec.describe PikuriWeb::Util::MarkdownRenderer do
  describe '.render' do
    it 'renders GFM: backtick fences and pipe tables' do
      html = PikuriWeb::Util::MarkdownRenderer.render("```ruby\nx = 1\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")

      assert_includes html, '<code class="language-ruby">'
      assert_includes html, '<thead>'
    end

    it 'does not hard-wrap reflowable prose' do
      html = PikuriWeb::Util::MarkdownRenderer.render("one\ntwo\n")

      refute_includes html, '<br'
    end

    # Unrepaired, kramdown reads a headerless table with a row of literal `—-` cells.
    it 'takes an em-dash separator row for the header separator it was meant to be' do
      html = PikuriWeb::Util::MarkdownRenderer.render("| a | b |\n|—-|—-|\n| 1 | 2 |\n")

      assert_includes html, '<thead>'
      refute_includes html, '—'
    end

    it 'leaves an em-dash in prose alone' do
      html = PikuriWeb::Util::MarkdownRenderer.render("a — b\n")

      assert_includes html, 'a — b'
    end
  end
end
