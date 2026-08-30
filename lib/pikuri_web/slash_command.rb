# frozen_string_literal: true

module PikuriWeb
  # One row of the composer's slash-command palette: the name as typed, and the
  # hint shown beside it while autocompleting.
  #
  #   /new       start a fresh conversation
  #   /model     put this conversation on another connection
  #   /theme     switch between the dark and light theme
  #   /trifecta  lethal-trifecta report for this agent
  #   <name>     <description>
  #
  #   SlashCommand.catalog(connections: config.llms.size)   # what a page offers
  #
  # The palette runs in the browser, so this side carries only what the page
  # displays — there is no callback. Adding a command is a three-place contract,
  # the same shape as the block kinds: an entry in {CATALOG}, an arm in the
  # +commands+ map public/js/app.js hands the composer, and a +<template>+ in
  # views/index.erb for one that opens a dialog.
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
    # what that means.
    #
    # @return [Array<SlashCommand>] every command this shell can offer; a page
    #   is served {.catalog} instead
    CATALOG = [
      new(name: '/new', description: 'start a fresh conversation'),
      new(name: '/model', description: 'put this conversation on another connection'),
      new(name: '/theme', description: 'switch between the dark and light theme'),
      new(name: '/trifecta', description: 'lethal-trifecta report for this agent')
    ].freeze

    # The catalog as this process will actually offer it.
    #
    # +/model+ is dropped when there is nothing to pick between — as pikuri-tui
    # gates its own picker — so the one-connection user, who is most users, is
    # not offered a dialog that can only tell them what they already have.
    #
    # @param connections [Integer] configured +[[llm]]+ entries
    # @return [Array<SlashCommand>]
    def self.catalog(connections:)
      connections > 1 ? CATALOG : CATALOG.reject { |command| command.name == '/model' }
    end
  end
end
