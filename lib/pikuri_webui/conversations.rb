# frozen_string_literal: true

module PikuriWebUI
  # The conversation set seen two ways: what is resident as a live agent
  # ({Registry}), and a saved one turned back into the events that produced it
  # ({HistoryReplay}). The folder itself is pikuri-conversations'
  # +Pikuri::Conversations::Store+, used as it comes.
  #
  # {HistoryReplay} sits here rather than in {Agents} because it is the read
  # half of what the store writes — +history.json+ back into
  # +Pikuri::Agent::Event+s — and it renders nothing itself.
  #
  # Mind the name: this module is +PikuriWebUI::Conversations+, the gem's live
  # list is +Pikuri::Conversations+, and code here always spells the gem's out.
  #
  # Nothing here may name anything under {Web}; see that namespace's one-way
  # rule.
  module Conversations
  end
end
