# frozen_string_literal: true

module PikuriWeb
  # One row of the composer's slash-command palette: the name as typed, and the
  # hint shown beside it while autocompleting.
  #
  #   /new       start a fresh conversation
  #   /theme     switch between the dark and light theme
  #   /trifecta  lethal-trifecta report for this agent
  #   <name>     <description>
  #
  # The palette runs in the browser, so this side carries only what the page
  # displays — there is no callback. Adding a command is a three-place contract,
  # the same shape as the block kinds: an entry in {CATALOG}, an arm in
  # +runCommand+ (public/app.js), and a +<template>+ in views/index.erb for one
  # that opens a dialog.
  #
  # A command must never write to the transcript. Client-side that is
  # conversation state the server does not hold (+D_server_authoritative_transcript+);
  # server-side it is a block absent from +history.json+, which a reopen would
  # silently drop (+D_replay_from_history+). Each command's own visible effect —
  # a dialog, a navigation, a color change — is the feedback instead.
  #
  # @!attribute [r] name
  #   @return [String] the command as typed, leading slash included; matched
  #     against the input buffer by prefix.
  # @!attribute [r] description
  #   @return [String] the autocomplete hint, the palette row's right column.
  class SlashCommand < Data.define(:name, :description)
    # The commands this shell offers, in the order the palette lists them.
    #
    # +/theme+ is one command with a picker rather than +/dark+ and +/light+, so
    # the catalog does not grow a row per value of every future setting. It
    # leaves +/t+ ambiguous with +/trifecta+, which is precisely the case the
    # palette exists for. There is no +/clear+: the TUI's wipes a conversation's
    # context in place, and here conversations are separate objects, so +/new+ is
    # what that means. +/model+ joins the list once a conversation can carry its
    # own model, gated — as pikuri-tui gates it — on there being more than one
    # +[[llm]]+ connection to pick between.
    #
    # @return [Array<SlashCommand>]
    CATALOG = [
      new(name: '/new', description: 'start a fresh conversation'),
      new(name: '/theme', description: 'switch between the dark and light theme'),
      new(name: '/trifecta', description: 'lethal-trifecta report for this agent')
    ].freeze
  end
end
