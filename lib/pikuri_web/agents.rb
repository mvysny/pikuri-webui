# frozen_string_literal: true

module PikuriWeb
  # Running an LLM turn: a conversation's agent and its lifecycle ({Runner}),
  # the connections it can run on ({ModelCatalog}), and the throwaway agent
  # that names a conversation ({Titler}).
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
