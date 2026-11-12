# frozen_string_literal: true

module PikuriWebUI
  module Web
    # The +<details>+ a reasoning block is wrapped in: open as stored, closed
    # for a browser that folds reasoning (+D_details_per_block+):
    #
    #   html = Disclosure.wrap("<p>The user wants…</p>")
    #   # => "<details open><summary>thinking</summary><p>The user wants…</p></details>"
    #   Disclosure.collapse(html)
    #   # => "<details><summary>thinking</summary><p>The user wants…</p></details>"
    #
    # Stored open on purpose: the transcript is shared by every tab reading it
    # and folding is per-browser, so the stored form is what a browser running
    # no script should see. Closing it is a *page render's* edit — the one place
    # that knows which browser it is for — never the transcript's.
    module Disclosure
      # @return [String]
      OPEN = '<details open><summary>thinking</summary>'
      # @return [String]
      CLOSED = '<details><summary>thinking</summary>'
      private_constant :OPEN, :CLOSED

      # @param html [String] the block's rendered reasoning
      # @return [String] +html+ inside an open disclosure
      def self.wrap(html) = "#{OPEN}#{html}</details>"

      # @param html [String] a block as {.wrap} produced it; any other string
      #   comes back unchanged, so a whole transcript can be mapped through this
      # @return [String] the same block, its disclosure closed
      def self.collapse(html) = html.start_with?(OPEN) ? "#{CLOSED}#{html.delete_prefix(OPEN)}" : html
    end
  end
end
