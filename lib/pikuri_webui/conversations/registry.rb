# frozen_string_literal: true

module PikuriWebUI
  module Conversations
    # The conversations resident in memory: one {Agents::Runner} — and so one
    # live agent and one transcript — per conversation anyone has opened this
    # run.
    #
    #   runner = registry.open_id(id)          # mint or return the resident one
    #   registry.create(from: viewed_id)       # a brand-new conversation, minted and open
    #   registry.delete(entry)                 # => :deleted | :busy | :failed
    #   registry.rows                          # what the sidebar lists
    #
    # A runner is minted on first *view*, not on first send, so that a tab
    # reading a conversation is subscribed to something real and picks up a turn
    # someone starts there from another tab. Nothing is ever reaped: a single
    # user opens a handful of conversations in a session, and a resident history
    # is small.
    #
    # Speaks the saved-conversation envelope, +Pikuri::Conversations::Store::Entry+,
    # as a value it reads by field and never names; everything agent-shaped lives
    # behind +factory+ (+D_pikuri_free_core+).
    #
    # == Threading
    #
    # Guarded by {BigAppLock}: every call must run inside a task. A mint's task
    # runs the factory *and* the whole restore replay, which keeps a second open
    # of the same conversation from observing a half-restored runner; {#find},
    # {#rows} and {#delete} run the store's disk I/O — the sanctioned
    # rare-and-bounded stalls (+D_global_monitor+).
    class Registry
      # @param store [Pikuri::Conversations::Store] mints ids, lists what is
      #   saved, removes a folder
      # @param factory [#call] +entry → Agents::Runner+, opened; built once in
      #   bin/pikuri-webui-chat so every agent gets the same tool set
      # @param lock [BigAppLock] the domain every call must be inside
      def initialize(store:, factory:, lock:)
        @store = store
        @factory = factory
        @lock = lock
        @runners = {}
      end

      # @param id [String]
      # @return [Agents::Runner, nil] without minting one
      def resident(id)
        @lock.assert!
        @runners[id]
      end

      # Resolve an id and open it as one step.
      #
      #   runner = registry.open_id(params['conversation'])
      #
      # A resolve then an open as two caller-side calls would leave {#delete} a
      # window: the folder goes, and the open that follows mints a live runner
      # for it anyway, written back to disk at its next turn end.
      #
      # @param id [String]
      # @return [Agents::Runner, nil] nil for an id that is neither resident nor
      #   saved — including one deleted a moment ago
      def open_id(id)
        @lock.assert!
        entry = find(id)
        entry && runner_for(entry)
      end

      # Mint a brand-new conversation and open it, on the connection the tab
      # was reading — so "switch model, then start a fresh chat" does the
      # obvious thing.
      #
      #   registry.create(from: params['viewing'])
      #
      # @param from [String, nil] id of the conversation the tab has open; nil,
      #   or one not resident, starts on the catalog's first connection
      # @return [Agents::Runner]
      def create(from: nil)
        @lock.assert!
        model, server = from && resident(from)&.model
        runner_for(@store.create(model: model, server: server))
      end

      # Forget a conversation and remove its folder. Irreversible: no undo, no
      # tombstone (+D_delete_no_undo+). Refused while its turn is in flight.
      #
      # {Agents::Runner#discard!} rather than a busy read, because dropping the
      # runner from the map does not reach a reference a request resolved in an
      # *earlier* task; only the retirement travels with the runner itself.
      #
      # @param entry [Pikuri::Conversations::Store::Entry]
      # @return [:deleted, :busy, :failed]
      def delete(entry)
        @lock.assert!
        runner = @runners[entry.id]
        return :busy if runner && !runner.discard!

        @runners.delete(entry.id)
        @store.delete(entry)
        :deleted
      rescue StandardError => e
        PikuriWebUI.logger.error("deleting conversation #{entry.id} failed (#{e.class}: #{e.message})")
        :failed
      end

      # Resolve an id to a conversation — resident or saved. Callers pass this,
      # never an id, into {#delete}, so no user input becomes a path.
      #
      # @param id [String]
      # @return [Pikuri::Conversations::Store::Entry, nil]
      def find(id)
        @lock.assert!
        @runners[id]&.conversation || @store.find(id)
      end

      # The sidebar's model: everything saved, newest first, plus anything
      # resident not saved yet (a fresh conversation has no +meta.json+ until
      # its first turn lands).
      #
      # @return [Array<Hash>] +{conversation:, busy:}+ per row
      def rows
        @lock.assert!
        saved = @store.list
        extra = @runners.values.map(&:conversation).reject { |c| saved.any? { |s| s.id == c.id } }
        (extra + saved).map { |c| { conversation: c, busy: @runners[c.id]&.busy? || false } }
      end

      # The conversation a bare +GET /+ lands on: the newest there is, or a
      # fresh one when there is none.
      #
      # @return [Pikuri::Conversations::Store::Entry]
      def default
        @lock.assert!
        rows.first&.fetch(:conversation) || create.conversation
      end

      private

      # The resident runner for +entry+, minting one on its first open.
      #
      # Private because an entry held from an earlier task can be stale —
      # deleted since — and this would mint a live runner over the missing
      # folder (+D_delete_no_undo+). {#open_id} re-resolves in its own task and
      # {#create} opens what it just minted.
      #
      # @param entry [Pikuri::Conversations::Store::Entry]
      # @return [Agents::Runner]
      def runner_for(entry)
        @lock.assert!
        @runners[entry.id] ||= @factory.call(entry)
      end
    end
  end
end
