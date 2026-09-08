# frozen_string_literal: true

module PikuriWeb
  # The conversation set seen three ways: what is saved ({Store}), what is
  # resident as a running agent ({Registry}), and a saved one turned back into
  # the events that produced it ({HistoryReplay}).
  #
  # {HistoryReplay} sits here rather than in {Agents} because it is the read
  # half of what {Store} writes — +history.json+ back into
  # +Pikuri::Agent::Event+s — and it renders nothing itself.
  #
  # Nothing here may name anything under {Web}; see that namespace's one-way
  # rule.
  module Conversations
  end
end
