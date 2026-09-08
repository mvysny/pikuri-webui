# frozen_string_literal: true

require 'tmpdir'

# Exercises residency and deletion against a real Conversations::Store over a temp
# directory, with a stub runner in place of the agent stack — what this class
# owns is the map, not what is in it.
RSpec.describe PikuriWeb::Conversations::Registry do
  # Stands in for Agents::Runner: records that it was restored, and reports
  # whatever busy state the example wants.
  class StubRunner
    attr_reader :conversation, :restores
    attr_accessor :busy

    def initialize(conversation)
      @conversation = conversation
      @restores = 0
      @busy = false
      @discarded = false
    end

    def restore! = @restores += 1
    def busy? = @busy
    # Intent, as the real one reports it: the pair a new conversation inherits.
    def model = ['qwen3.6', 'http://localhost:8080/v1']
    def discarded? = @discarded

    # As the real one: refuses while busy, one-way once taken.
    def discard!
      return false if @busy

      @discarded = true
    end
  end

  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  let(:store) do
    PikuriWeb::Conversations::Store.new(root: @root, shell: 'pikuri-web-chat')
  end
  let(:built) { [] }
  let(:factory) { ->(c) { StubRunner.new(c).tap { |r| built << r } } }
  let(:lock) { PikuriWeb::BigAppLock.new }
  let(:registry) { guard(described_class.new(store: store, factory: factory, lock: lock), lock) }

  # #open itself is private (a caller-held Conversation can be stale — see its
  # doc), so minting is exercised through the two public doors: #create for a
  # brand-new conversation, #open_id for one that is resident or saved.
  context 'minting' do
    it 'mints a runner and restores it once' do
      runner = registry.create

      assert_equal 1, built.size
      assert_equal 1, runner.restores
    end

    it 'mints on first open of a saved conversation' do
      conversation = store.create
      store.save(conversation, Pikuri::Agent::History.new(messages: []),
                 model: 'qwen3.6', server: 'http://localhost:8080/v1')

      runner = registry.open_id(conversation.id)

      assert_equal conversation.id, runner.conversation.id
      assert_equal 1, runner.restores
    end

    it 'hands back the same runner on every later open' do
      first = registry.create

      assert_same first, registry.open_id(first.conversation.id)
      assert_equal 1, built.size
      assert_equal 1, first.restores
    end

    # The property that makes a turn survive being navigated away from: two
    # conversations are two runners, each with its own agent.
    it 'keeps one runner per conversation' do
      a = registry.create
      b = registry.create

      refute_same a, b
      assert_equal 2, built.size
    end
  end

  context '#resident' do
    it 'answers nil rather than minting' do
      assert_nil registry.resident('never-opened')
      conversation = registry.create.conversation
      refute_nil registry.resident(conversation.id)
    end
  end

  context '#find' do
    it 'resolves a resident conversation, and a saved one, and nothing else' do
      resident = registry.create.conversation

      assert_equal resident.id, registry.find(resident.id).id
      assert_nil registry.find('../../etc')
    end
  end

  context '#delete' do
    it 'drops the runner and removes the folder' do
      runner = registry.create
      runner.conversation.dir.mkpath

      assert_equal :deleted, registry.delete(runner.conversation)
      assert_nil registry.resident(runner.conversation.id)
      refute runner.conversation.dir.exist?
    end

    it 'refuses a conversation whose turn is in flight, which would save it back' do
      runner = registry.create
      runner.conversation.dir.mkpath
      runner.busy = true

      assert_equal :busy, registry.delete(runner.conversation)
      refute_nil registry.resident(runner.conversation.id)
      assert runner.conversation.dir.exist?
      refute runner.discarded?, 'retired a runner it went on to refuse the delete of'
    end

    # Dropping the runner from the map is not enough: whoever resolved it a
    # moment earlier still holds it, and would write the folder back at the
    # next turn end. Retiring the runner is what closes that.
    it 'retires the runner it drops, so a stale reference cannot resurrect it' do
      runner = registry.create
      runner.conversation.dir.mkpath

      assert_equal :deleted, registry.delete(runner.conversation)
      assert runner.discarded?
    end

    # Busy is per conversation now: a turn running elsewhere is no reason to
    # refuse this one.
    it 'allows a delete while a different conversation is working' do
      busy = registry.create
      busy.busy = true
      idle = registry.create
      idle.conversation.dir.mkpath

      assert_equal :deleted, registry.delete(idle.conversation)
    end
  end

  context '#rows' do
    it 'lists a resident conversation that has never been saved' do
      conversation = registry.create.conversation
      rows = registry.rows

      assert_equal [conversation.id], rows.map { |r| r[:conversation].id }
      refute rows.fetch(0).fetch(:busy)
    end

    it 'reports which rows are working' do
      runner = registry.create
      runner.busy = true
      assert registry.rows.fetch(0).fetch(:busy)
    end

    it 'does not list a resident conversation twice once it is saved' do
      conversation = registry.create.conversation
      store.save(conversation, Pikuri::Agent::History.new(messages: []),
                 model: 'qwen3.6', server: 'http://localhost:8080/v1')

      assert_equal 1, registry.rows.size
    end
  end

  context '#create' do
    it 'starts a conversation on the connection the tab was reading' do
      viewed = registry.create.conversation

      minted = registry.create(from: viewed.id).conversation

      assert_equal 'qwen3.6', minted.model_at_mint
      assert_equal 'http://localhost:8080/v1', minted.server_at_mint
    end

    it 'starts on the catalog default when nothing is being read, or the id is stale' do
      assert_nil registry.create.conversation.model_at_mint
      assert_nil registry.create(from: 'no-such-conversation').conversation.model_at_mint
    end
  end

  # The second door into the resurrection #discard! closes. That one guards a
  # runner already resident when the delete lands; this is a caller that
  # resolved the conversation a moment earlier and opens it afterwards, when
  # there is no runner for the delete to have retired.
  context '#open_id' do
    it 'opens a conversation in one step' do
      conversation = registry.create.conversation
      assert_equal conversation.id, registry.open_id(conversation.id).conversation.id
    end

    it 'is nil for an id that is neither resident nor saved' do
      assert_nil registry.open_id('no-such-conversation')
    end

    it 'mints nothing for a conversation deleted after the caller resolved it' do
      resolved = registry.create.conversation
      assert_equal :deleted, registry.delete(resolved)

      assert_nil registry.open_id(resolved.id), 'minted a runner for a deleted conversation'
      assert_empty registry.rows, 'and put it back in the sidebar'
    end
  end

  # Promoted from the seam audit (PROBE 3): two tabs delete one conversation
  # at once; the domain serializes them and both learn it is gone.
  context 'concurrent deletes' do
    it 'answers :deleted to both' do
      conversation = registry.create.conversation
      conversation.dir.mkpath

      results = Array.new(2)
      2.times.map { |i| Thread.new { results[i] = registry.delete(conversation) } }.each(&:join)

      assert_equal %i[deleted deleted], results
      assert_nil registry.resident(conversation.id)
      refute conversation.dir.exist?
    end
  end

  context '#default' do
    it 'mints a conversation when there is nothing at all' do
      assert_empty registry.rows

      conversation = registry.default

      refute_nil registry.resident(conversation.id)
      assert_equal [conversation.id], registry.rows.map { |r| r[:conversation].id }
    end

    it 'returns the newest existing one rather than minting' do
      existing = registry.create.conversation
      assert_equal existing.id, registry.default.id
      assert_equal 1, built.size
    end
  end
end
