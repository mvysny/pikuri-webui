# frozen_string_literal: true

module PikuriWebUI
  # Generic helpers — the Ruby side of what public/js/dom.js is to the scripts.
  #
  # == The admission test
  #
  # A class belongs here only if it knows nothing about this app: no block
  # kinds, no conversation, no route, no +Pikuri::+ type. {MarkdownRenderer}
  # (Markdown in, HTML out) and {RelativeTime} (a Time in, "2 hours ago" out)
  # pass. {Web::ToolLine} and {Web::SlashCommand} look small enough to belong
  # here but fail it — block-kind and palette knowledge — so they live in {Web}.
  #
  # Small by design. Anything failing the test goes to the namespace that owns
  # the knowledge, not here.
  module Util
  end
end
