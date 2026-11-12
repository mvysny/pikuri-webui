# frozen_string_literal: true

module PikuriWebUI
  # The web shell: the Sinatra app, the SSE fan-out, the server-authoritative
  # transcript, and the renderers that turn agent events into blocks.
  #
  # Membership is decided by *what a class produces*, not by what it imports —
  # {SseListener} belongs here because its output is HTML, though it subclasses
  # +Pikuri::Agent::Listener::Base+. Reaching down into pikuri, {Agents} or
  # {Conversations} is the sanctioned shape.
  #
  # == The one-way rule
  #
  # This namespace may name anything under +PikuriWebUI+; nothing under {Agents}
  # or {Conversations} may name anything under here. Where the service side
  # needs to reach the browser it takes a collaborator injected at
  # bin/pikuri-webui-chat and never names its class.
  #
  # == Not a thread boundary
  #
  # "Web" says what a class produces, not which thread calls it: {SseListener},
  # {Transcript} and {Broadcaster} are all touched from the turn worker under
  # {BigAppLock} (+D_global_monitor+). Reading this namespace as "request thread
  # only" is how an +assert!+ guard gets dropped as redundant.
  module Web
  end
end
