# frozen_string_literal: true

module PikuriWeb
  # The conversations resident in memory: one {AgentRunner} — and therefore one
  # agent, one history, one transcript — per conversation anyone has opened
  # this run.
  #
  #   runner = registry.open(conversation)   # mint or return the resident one
  #   registry.create                        # a brand-new conversation, minted and open
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
  # == Where the last global lock lives
  #
  # Per-conversation state is single-writer by construction — one agent, one
  # transcript, and a conversation that admits one turn at a time — so this
  # registry and {ConversationStore} are what is left that several threads
  # genuinely share. That holds at any +--turns+ setting; it comes from the
  # partition, not from the executor's pool size (`D_serial_turn_executor`).
  # The monitor covers the resident map; the store's folder is its own problem
  # (`ideas/conversation-store-locking.md`).
  #
  # +Monitor+ rather than +Mutex+ because it is re-entrant: {#rows} and
  # {#delete} both consult the resident map through helpers that lock, and a
  # plain mutex would deadlock on itself.
  #
  # Thread-safe.
  class ConversationRegistry
    # @param store [ConversationStore] the folder: mints ids, lists what is
    #   saved, removes a folder
    # @param factory [#call] +conversation → AgentRunner+, built once in
    #   bin/pikuri-web-chat so that every agent gets the same tool set and the
    #   boot-time trifecta report stays true of all of them
    def initialize(store:, factory:)
      @store = store
      @factory = factory
      @monitor = Monitor.new
      @runners = {}
    end

    # The resident runner for +conversation+, minting and restoring one if this
    # is the first time it has been opened.
    #
    # @param conversation [ConversationStore::Conversation]
    # @return [AgentRunner]
    def open(conversation)
      @monitor.synchronize do
        @runners[conversation.id] ||= @factory.call(conversation).tap(&:restore!)
      end
    end

    # @param id [String]
    # @return [AgentRunner, nil] without minting one
    def resident(id) = @monitor.synchronize { @runners[id] }

    # Mint a brand-new conversation and open it.
    #
    # @return [AgentRunner]
    def create = open(@store.create)

    # Forget a conversation and remove its folder. Irreversible: no undo, no
    # tombstone (`D_delete_no_undo`).
    #
    # Refused while its turn is in flight, which would otherwise save the
    # folder back moments after it went. The runner is dropped before the
    # folder is removed, so a removal that raises leaves nothing resident that
    # would write the deleted conversation straight back at its next turn end.
    #
    # @param conversation [ConversationStore::Conversation]
    # @return [:deleted, :busy, :failed]
    def delete(conversation)
      @monitor.synchronize do
        return :busy if @runners[conversation.id]&.busy?

        @runners.delete(conversation.id)
        @store.delete(conversation)
        :deleted
      end
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
      @monitor.synchronize { @runners[id]&.conversation } || @store.find(id)
    end

    # The sidebar's model: everything saved, newest first, plus anything
    # resident that has not been saved yet (a fresh conversation has no
    # +meta.json+ until its first turn lands).
    #
    # @return [Array<Hash>] +{conversation:, busy:}+ per row
    def rows
      @monitor.synchronize do
        saved = @store.list
        extra = @runners.values.map(&:conversation).reject { |c| saved.any? { |s| s.id == c.id } }
        (extra + saved).map { |c| { conversation: c, busy: @runners[c.id]&.busy? || false } }
      end
    end

    # The conversation a bare +GET /+ should land on: the newest thing there
    # is, or a fresh one when the store is empty and nothing is resident.
    #
    # @return [ConversationStore::Conversation]
    def default
      @monitor.synchronize do
        rows.first&.fetch(:conversation) || create.conversation
      end
    end

    # Every resident runner, for the shutdown sweep.
    #
    # @return [Array<AgentRunner>]
    def runners = @monitor.synchronize { @runners.values }
  end
end
