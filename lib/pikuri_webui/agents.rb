# frozen_string_literal: true

module PikuriWebUI
  # Running an LLM turn: this shell's side of one live conversation
  # ({Runner}, over pikuri-conversations' +Conversation+), and the connections
  # it can run on ({ModelCatalog}).
  #
  # Nothing here knows a conversation is a folder on disk — that is
  # {Conversations} — and nothing here may name anything under {Web}; see that
  # namespace's one-way rule.
  #
  # Plural on purpose: a singular +Agent+ sitting beside +Pikuri::Agent+ would
  # shadow it for every file in this tree.
  module Agents
  end
end
