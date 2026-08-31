# frozen_string_literal: true

module PikuriWeb
  # The conversations resident in memory: one {AgentRunner} — and therefore one
  # agent, one history, one transcript — per conversation anyone has opened
  # this run.
  #
  #   runner = registry.open(conversation)   # mint or return the resident one
  #   registry.create(from: viewed_id)       # a brand-new conversation, minted and open
  #   registry.delete(conversation)          # => :deleted | :busy
  #   registry.rows                          # what the sidebar lists
  #
  # A runner is minted on first *view*, not on first send, so that a tab
  # reading a conversation is subscribed to something real and picks up a turn
  # someone starts there from another tab. Nothing is ever reaped: a single
  # user opens a handful of conversations in a session, and a resident history
  # is small. Reaping is the thing to add if that stops being true, not a
  # cleverer minting rule.
  #
  # Pikuri-free: the agent-shaped work lives entirely behind +factory+, so this
  # class only ever holds and hands out {AgentRunner}s.
  #
  # == Threading
  #
  # Guarded by {AppMonitor}: every call must run inside a task. Per-conversation
  # state is single-writer by construction — one agent, one transcript, and a
  # conversation that admits one turn at a time — and that holds at any
  # +--turns+ setting; it comes from the partition, not from the executor's
  # pool size (`D_serial_turn_executor`). {ConversationStore}'s own doc covers
  # the folder. This class still never reaches inside a runner — hence
  # {AgentRunner#discard!} for the one place that must.
  #
  # A mint's task runs the factory *and* the whole restore replay (which is
  # what keeps a second open of the same conversation from observing a
  # half-restored runner), and {#find} / {#rows} / {#delete} run the store's
  # disk I/O — the sanctioned rare-and-bounded stalls (`D_global_monitor`).
  class ConversationRegistry
    # @param store [ConversationStore] the folder: mints ids, lists what is
    #   saved, removes a folder
    # @param factory [#call] +conversation → AgentRunner+, built once in
    #   bin/pikuri-web-chat so that every agent gets the same tool set and the
    #   boot-time trifecta report stays true of all of them
    # @param monitor [AppMonitor] the domain every call must be inside
    def initialize(store:, factory:, monitor:)
      @store = store
      @factory = factory
      @monitor = monitor
      @runners = {}
    end

    # The resident runner for +conversation+, minting and restoring one if this
    # is the first time it has been opened.
    #
    # @param conversation [ConversationStore::Conversation]
    # @return [AgentRunner]
    def open(conversation)
      @monitor.assert!
      @runners[conversation.id] ||= @factory.call(conversation).tap(&:restore!)
    end

    # @param id [String]
    # @return [AgentRunner, nil] without minting one
    def resident(id)
      @monitor.assert!
      @runners[id]
    end

    # Resolve an id and open it as one step.
    #
    #   runner = registry.open_id(params['conversation'])
    #
    # {#find} then {#open} as two caller-side calls would leave a window for
    # {#delete}: the folder goes, and the open that follows mints a live
    # runner for it anyway — back in the sidebar as an unsaved resident, and
    # written to disk again at its next turn end. {AgentRunner#discard!}
    # cannot help, because it retires the runner that is *already* resident
    # and this one does not exist yet. One method means one task: either the
    # delete finds a runner to refuse or retire, or this finds nothing to
    # resolve.
    #
    # @param id [String]
    # @return [AgentRunner, nil] nil for an id that is neither resident nor
    #   saved — including one deleted a moment ago
    def open_id(id)
      @monitor.assert!
      conversation = find(id)
      conversation && open(conversation)
    end

    # Mint a brand-new conversation and open it.
    #
    #   registry.create(from: params['viewing'])
    #
    # A conversation starts on the connection the tab was reading, which is
    # what makes "switch model, then start a fresh chat" do the obvious thing.
    # The pair travels as two opaque strings — this class knows connections
    # only by them.
    #
    # @param from [String, nil] id of the conversation the tab has open; nil,
    #   or one not resident, starts on the catalog's first connection
    # @return [AgentRunner]
    def create(from: nil)
      @monitor.assert!
      model, server = from && resident(from)&.model
      open(@store.create(model: model, server: server))
    end

    # Forget a conversation and remove its folder. Irreversible: no undo, no
    # tombstone (`D_delete_no_undo`).
    #
    # Refused while its turn is in flight, which would otherwise save the
    # folder back moments after it went.
    #
    # {AgentRunner#discard!} rather than a {AgentRunner#busy?} read, because
    # dropping the runner from the map does not reach the copy a request
    # resolved in an *earlier* task — a submit through that stale reference
    # lands in a later task, after this one, and would resurrect the
    # conversation at its next turn end; only a flag on the runner itself
    # travels with the reference. Retire it, then remove the folder: a removal
    # that raises leaves an inert runner rather than a live one pointing at a
    # half-deleted conversation.
    #
    # @param conversation [ConversationStore::Conversation]
    # @return [:deleted, :busy, :failed]
    def delete(conversation)
      @monitor.assert!
      runner = @runners[conversation.id]
      return :busy if runner && !runner.discard!

      @runners.delete(conversation.id)
      @store.delete(conversation)
      :deleted
    rescue StandardError => e
      PikuriWeb.logger.error("deleting conversation #{conversation.id} failed (#{e.class}: #{e.message})")
      :failed
    end

    # Resolve an id to a conversation — resident or saved.
    #
    # Callers pass this rather than an id into {#open} / {#delete}, so no
    # caller ever turns user input into a path.
    #
    # @param id [String]
    # @return [ConversationStore::Conversation, nil]
    def find(id)
      @monitor.assert!
      @runners[id]&.conversation || @store.find(id)
    end

    # The sidebar's model: everything saved, newest first, plus anything
    # resident that has not been saved yet (a fresh conversation has no
    # +meta.json+ until its first turn lands).
    #
    # @return [Array<Hash>] +{conversation:, busy:}+ per row
    def rows
      @monitor.assert!
      saved = @store.list
      extra = @runners.values.map(&:conversation).reject { |c| saved.any? { |s| s.id == c.id } }
      (extra + saved).map { |c| { conversation: c, busy: @runners[c.id]&.busy? || false } }
    end

    # The conversation a bare +GET /+ should land on: the newest thing there
    # is, or a fresh one when the store is empty and nothing is resident.
    #
    # @return [ConversationStore::Conversation]
    def default
      @monitor.assert!
      rows.first&.fetch(:conversation) || create.conversation
    end

    # Every resident runner, for the shutdown sweep.
    #
    # @return [Array<AgentRunner>]
    def runners
      @monitor.assert!
      @runners.values
    end
  end
end
