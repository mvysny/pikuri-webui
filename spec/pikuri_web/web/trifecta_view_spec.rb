# frozen_string_literal: true

RSpec.describe PikuriWeb::Web::TrifectaView do
  # Stands in for Pikuri::Trifecta::Report: only #render is read, and its shape
  # (verdict, blank line, tree) is the whole contract this view depends on.
  def report(text) = Struct.new(:text).new(text).tap { |r| def r.render = text }

  def render(text) = described_class.render(report(text))

  it 'splits the verdict from the map at the report\'s own blank line' do
    html = render("[TRIFECTA: soft] pikuri-web-chat — egress(fetch).\n\nagent []\n  fetch [:egress]")
    assert_includes html, '<p class="trifecta-advisory">[TRIFECTA: soft] pikuri-web-chat — egress(fetch).</p>'
    assert_includes html, "<pre class=\"trifecta-tree\">agent []\n  fetch [:egress]</pre>"
  end

  it 'escapes the report rather than rendering it as Markdown' do
    html = render("verdict <b>&</b>\n\nagent [:private] <tool>")
    refute_includes html, '<b>'
    assert_includes html, '&lt;b&gt;&amp;&lt;/b&gt;'
    assert_includes html, '&lt;tool&gt;'
  end

  it 'keeps the whole report when it carries no tree to split off' do
    html = render('verdict only')
    assert_includes html, 'verdict only'
    refute_includes html, '<pre'
  end
end
