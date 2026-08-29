# frozen_string_literal: true

module PikuriWeb
  # Renders a walked trifecta report as the body of the +/trifecta+ dialog: the
  # verdict as a paragraph, the tool map beneath it as preformatted text.
  #
  #   TrifectaView.render(agent.trifecta)
  #   # => <p class="trifecta-advisory">Trifecta: pikuri-web-chat — 2 of 3 legs …</p>
  #   #    <pre class="trifecta-tree">pikuri-web-chat [:untrusted_hard, :egress]
  #   #      web_search [:untrusted_hard, :egress]
  #   #      calculator []</pre>
  #
  # Escaped plain text, never Markdown: the map is a fixed-width tree, and
  # kramdown would reflow it into prose.
  #
  # Server-side of the pikuri seam — {App} is handed the String and never the
  # report (+D_pikuri_free_core+).
  module TrifectaView
    module_function

    # @param report [Pikuri::Trifecta::Report] a walked report, from
    #   +Pikuri::Agent#trifecta+
    # @return [String] an HTML fragment, safe to emit unescaped
    def render(report)
      # The report's own layout is advisory, blank line, tree — so a blank line
      # is where one ends and the other starts. A shape change upstream costs
      # the <pre>, not the content.
      advisory, tree = report.render.split("\n\n", 2)
      html = +%(<p class="trifecta-advisory">#{MarkdownRenderer.escape(advisory)}</p>)
      html << %(\n<pre class="trifecta-tree">#{MarkdownRenderer.escape(tree)}</pre>) if tree
      html
    end
  end
end
