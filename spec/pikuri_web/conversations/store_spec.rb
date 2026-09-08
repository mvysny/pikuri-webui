# frozen_string_literal: true

require 'tmpdir'

# Exercises the on-disk layout against a real temp directory, including the
# co-habitation with Pikuri::Agent::History#save that the format rests on.
RSpec.describe PikuriWeb::Conversations::Store do
  # Stands in for Pikuri::Agent::History: +#save(dir)+ is the whole of what the
  # store asks of a payload. Records how the directory looked when it was
  # called — every ordering guarantee #save makes is "before the history" —
  # and writes nothing, so examples can assert on the directory's contents
  # exactly. Pass a block to fail the way a full disk would.
  class SpyHistory
    attr_reader :dir, :mode, :envelope_existed

    def initialize(&fail_with) = @fail_with = fail_with

    def save(dir)
      @dir = dir
      @mode = (dir.stat.mode & 0o777).to_s(8)
      @envelope_existed = (dir / 'meta.json').exist?
      @fail_with&.call
      dir
    end
  end

  # Leaves behind what pikuri's own save would: history.json plus a
  # content-addressed attachments/ tree.
  class HistoryWithAttachment
    def save(dir)
      (dir / 'attachments').mkpath
      (dir / 'attachments' / 'abc-shot.png').write('not really a png')
      (dir / 'history.json').write('{}')
      dir
    end
  end

  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  let(:store) { described_class.new(root: @root, shell: 'pikuri-web-chat') }
  let(:at) { Time.utc(2026, 8, 27, 12, 3, 51) }

  # The connection an example that is not about connections saves on. #save
  # takes it per call — the store holds no model of its own.
  CONNECTION = { model: 'qwen3.6', server: 'http://localhost:8080/v1' }.freeze

  def save(conversation, history, **overrides)
    store.save(conversation, history, **CONNECTION, **overrides)
  end

  def meta_of(conversation)
    JSON.parse((conversation.dir / 'meta.json').read)
  end

  context 'construction' do
    it 'creates the root 0700, so it is there from boot' do
      store
      assert @root.directory?
      assert_equal '700', (@root.stat.mode & 0o777).to_s(8)
      assert_empty @root.children
    end
  end

  context '#create' do
    it 'mints a lexically sortable UTC id with a random suffix' do
      conversation = store.create(at: at)
      assert_match(/\A2026-08-27T12-03-51Z-[0-9a-f]{4}\z/, conversation.id)
      assert_equal @root / conversation.id, conversation.dir
    end

    it 'titles the conversation by local start time' do
      assert_equal at.localtime.strftime('%Y-%m-%d %H:%M'), store.create(at: at).title
    end

    it 'keeps two conversations minted in the same second apart' do
      refute_equal store.create(at: at).id, store.create(at: at).id
    end

    it 'creates no directory — that waits for something to put in it' do
      refute store.create(at: at).dir.exist?
    end

    it 'leaves the caller its own Time, unconverted' do
      given = Time.utc(2026, 8, 27, 12, 3, 51)
      store.create(at: given)
      assert given.utc?, 'create converted the caller\'s Time in place'
    end

    it 'starts on no connection at all unless one is inherited' do
      conversation = store.create(at: at)
      assert_nil conversation.model_at_mint
      assert_nil conversation.server_at_mint
    end

    it 'carries an inherited connection through to the factory' do
      conversation = store.create(at: at, **CONNECTION)
      assert_equal 'qwen3.6', conversation.model_at_mint
      assert_equal 'http://localhost:8080/v1', conversation.server_at_mint
    end
  end

  context '#save' do
    it 'hands the history the conversation directory, already created' do
      conversation = store.create(at: at)
      history = SpyHistory.new
      save(conversation, history)

      assert_equal conversation.dir, history.dir
      assert history.dir.directory?
    end

    it 'creates the directory 0700 before the history goes into it' do
      conversation = store.create(at: at)
      history = SpyHistory.new
      save(conversation, history)

      assert_equal '700', history.mode, 'the history was written into a wider-mode directory'
      assert_equal '700', (conversation.dir.stat.mode & 0o777).to_s(8)
    end

    it 'tightens a directory an earlier History#save left with the default mode' do
      conversation = store.create(at: at)
      FileUtils.mkdir_p(conversation.dir.to_path, mode: 0o755)
      save(conversation, SpyHistory.new)
      assert_equal '700', (conversation.dir.stat.mode & 0o777).to_s(8)
    end

    it 'writes the envelope' do
      conversation = store.create(at: at)
      save(conversation, SpyHistory.new, updated_at: Time.utc(2026, 8, 27, 12, 41, 2))

      assert_equal(
        {
          'schema' => 1,
          'id' => conversation.id,
          'title' => conversation.title,
          'created_at' => '2026-08-27T12:03:51Z',
          'updated_at' => '2026-08-27T12:41:02Z',
          'shell' => 'pikuri-web-chat',
          'model' => 'qwen3.6',
          'server' => 'http://localhost:8080/v1'
        },
        meta_of(conversation)
      )
    end

    it 'commits the envelope only after the history has landed' do
      conversation = store.create(at: at)
      history = SpyHistory.new
      save(conversation, history)

      refute history.envelope_existed, 'meta.json was written before the history'
      assert (conversation.dir / 'meta.json').file?
    end

    it 'leaves a failed history write unlisted rather than half-committed' do
      conversation = store.create(at: at)
      assert_raises(Errno::ENOSPC) { save(conversation, SpyHistory.new { raise Errno::ENOSPC }) }

      refute (conversation.dir / 'meta.json').exist?
      assert_empty store.list
    end

    it 'rewrites in place on the next save, leaving no temp file behind' do
      conversation = store.create(at: at)
      save(conversation, SpyHistory.new, updated_at: Time.utc(2026, 8, 27, 12, 10, 0))
      save(conversation, SpyHistory.new, updated_at: Time.utc(2026, 8, 27, 13, 20, 0))

      assert_equal '2026-08-27T13:20:00Z', meta_of(conversation).fetch('updated_at')
      assert_equal ['meta.json'], conversation.dir.children.map { |c| c.basename.to_s }
    end
  end

  context '#list' do
    # Commits a conversation with an empty payload — #list only ever reads the
    # envelope, and #save writes that either way.
    def commit(at, **overrides)
      conversation = store.create(at: at)
      save(conversation, SpyHistory.new)
      unless overrides.empty?
        meta = meta_of(conversation).merge(overrides.transform_keys(&:to_s))
        (conversation.dir / 'meta.json').write(JSON.generate(meta))
      end
      conversation
    end

    it 'is empty on a fresh root' do
      assert_empty store.list
    end

    it 'orders by start time, newest first' do
      older = commit(Time.utc(2026, 8, 26, 9, 14, 2))
      newer = commit(Time.utc(2026, 8, 27, 12, 3, 51))
      assert_equal [newer.id, older.id], store.list.map(&:id)
    end

    it 'keeps a conversation in place however late it is written to' do
      first = commit(Time.utc(2026, 8, 26, 9, 14, 2))
      second = commit(Time.utc(2026, 8, 27, 12, 3, 51))
      save(first, SpyHistory.new, updated_at: Time.utc(2026, 8, 28, 18, 0, 0))
      assert_equal [second.id, first.id], store.list.map(&:id)
    end

    it 'reads the title from meta.json' do
      commit(at, 'title' => 'Debugging the SSE drain')
      row = store.list.first
      assert_equal 'Debugging the SSE drain', row.title
      assert row.supported
    end

    it 'dates a conversation by its id, not by its envelope' do
      commit(at, 'created_at' => '1999-01-01T00:00:00Z')
      assert_equal at, store.list.first.created_at
    end

    it 'skips a directory with no meta.json — a save interrupted mid-commit' do
      FileUtils.mkdir_p((@root / store.create(at: at).id).to_path)
      assert_empty store.list
    end

    it 'skips directories that are not ours' do
      FileUtils.mkdir_p((@root / 'attachments').to_path)
      (@root / 'attachments' / 'meta.json').write('{"schema":1}')
      assert_empty store.list
    end

    it 'skips a directory shaped like an id but not a date' do
      store
      FileUtils.mkdir_p((@root / '2026-99-99T99-99-99Z-abcd').to_path)
      (@root / '2026-99-99T99-99-99Z-abcd' / 'meta.json').write('{"schema":1}')
      assert_empty store.list
    end

    it 'skips plain files sitting in the root' do
      store
      (@root / 'notes.txt').write('scratch')
      assert_empty store.list
    end

    it 'lists a conversation from a newer schema as unsupported' do
      conversation = commit(at, 'schema' => 99, 'title' => 'from the future')
      row = store.list.first
      refute row.supported
      assert_equal conversation.title, row.title, 'trusted a title from a schema it cannot read'
    end

    it 'lists a conversation with a corrupt envelope as unsupported' do
      conversation = commit(at)
      (conversation.dir / 'meta.json').write('{"schema": 1, "title": ')
      refute store.list.first.supported
    end

    it 'falls back to the stamp title when meta.json has none' do
      conversation = commit(at, 'title' => nil)
      row = store.list.first
      assert row.supported
      assert_equal conversation.title, row.title
    end

    it 'reads the saved connection back out of the envelope' do
      commit(at)
      row = store.list.first
      assert_equal 'qwen3.6', row.model_at_mint
      assert_equal 'http://localhost:8080/v1', row.server_at_mint
    end

    # These values reach the conversation factory, and half a pair is worse
    # than none: an envelope written before this shell recorded a server holds
    # the *boot* model, which matching on alone is the conflation the pair
    # exists to prevent.
    it 'takes half a connection, or a non-string one, as no connection' do
      commit(at, 'server' => nil)
      assert_nil store.list.first.model_at_mint

      commit(Time.utc(2026, 8, 28, 9, 0, 0), 'model' => 42)
      assert store.list.first.supported
      assert_nil store.list.first.model_at_mint
      assert_nil store.list.first.server_at_mint
    end

    it 'points each row at its directory' do
      conversation = commit(at)
      assert_equal conversation.dir, store.list.first.dir
    end
  end

  context '#find' do
    it 'resolves a listed conversation' do
      conversation = store.create(at: at)
      save(conversation, SpyHistory.new)
      assert_equal conversation.id, store.find(conversation.id).id
    end

    it 'answers nil for anything not in the listing, path-shaped ids included' do
      save(store.create(at: at), SpyHistory.new)
      assert_nil store.find('2026-08-27T12-03-51Z-ffff')
      assert_nil store.find('../../etc')
      assert_nil store.find('')
    end
  end

  context '#stamp_titled?' do
    it 'is true for a conversation nothing has named' do
      assert store.stamp_titled?(store.create(at: at))
    end

    it 'is false once something has' do
      refute store.stamp_titled?(store.retitle(store.create(at: at), 'Named Thing'))
    end
  end

  context '#retitle' do
    it 'rewrites the envelope in place, keeping every other key' do
      conversation = store.create(at: at)
      save(conversation, SpyHistory.new)
      before = meta_of(conversation)

      renamed = store.retitle(conversation, 'Sinatra Versus Roda For SSE')

      assert_equal 'Sinatra Versus Roda For SSE', meta_of(conversation)['title']
      assert_equal 'Sinatra Versus Roda For SSE', renamed.title
      assert_equal before.except('title'), meta_of(conversation).except('title')
    end

    it 'leaves the directory where it is — a title is never part of a path' do
      conversation = store.create(at: at)
      save(conversation, SpyHistory.new)
      assert_equal conversation.dir, store.retitle(conversation, 'Named Thing').dir
      assert conversation.dir.directory?
    end

    # A conversation minted but not yet saved: the rename lives in the returned
    # value, and the save that first writes the envelope carries it.
    it 'writes nothing when there is no envelope yet' do
      conversation = store.create(at: at)
      renamed = store.retitle(conversation, 'Named Thing')

      assert_equal 'Named Thing', renamed.title
      refute conversation.dir.exist?
      save(renamed, SpyHistory.new)
      assert_equal 'Named Thing', meta_of(renamed)['title']
    end

    it 'writes nothing over an envelope this reader cannot stand behind' do
      conversation = store.create(at: at)
      save(conversation, SpyHistory.new)
      (conversation.dir / 'meta.json').write('{ this is not json')

      assert_equal 'Named Thing', store.retitle(conversation, 'Named Thing').title
      assert_equal '{ this is not json', (conversation.dir / 'meta.json').read
    end

    it 'survives a round trip through the listing' do
      conversation = store.create(at: at)
      save(conversation, SpyHistory.new)
      store.retitle(conversation, 'Named Thing')

      assert_equal ['Named Thing'], store.list.map(&:title)
    end
  end

  context '#delete' do
    # A committed conversation with pikuri's half beside ours, which is what
    # delete has to take with it.
    def saved(at: self.at)
      conversation = store.create(at: at)
      save(conversation, HistoryWithAttachment.new)
      conversation
    end

    it 'removes the folder, pikuri\'s half and the attachments with it' do
      conversation = saved
      assert store.delete(conversation)
      refute conversation.dir.exist?
    end

    it 'drops the conversation from the listing' do
      kept = saved(at: at - 3600)
      store.delete(saved)
      assert_equal [kept.id], store.list.map(&:id)
    end

    it 'deletes a conversation it could not read, which is how a broken one gets pruned' do
      conversation = saved
      (conversation.dir / 'meta.json').write('{ not json')
      refute store.find(conversation.id).supported
      assert store.delete(store.find(conversation.id))
      assert_empty store.list
    end

    it 'reports nothing removed for a conversation minted but never saved' do
      refute store.delete(store.create(at: at))
    end

    it 'refuses a conversation from outside the root rather than removing it' do
      outside = PikuriWeb::Conversations::Store::Conversation.new(
        id: 'elsewhere', dir: @root.parent / 'elsewhere', title: 'x',
        created_at: at, supported: true
      )
      (@root.parent / 'elsewhere').mkpath
      assert_raises(ArgumentError) { store.delete(outside) }
      assert (@root.parent / 'elsewhere').directory?, 'delete escaped the root'
    end
  end

  context 'sharing the folder with pikuri' do
    it 'leaves history.json and attachments alone, and survives a save' do
      conversation = store.create(at: at)
      history = Pikuri::Agent::History.new(
        messages: [
          Pikuri::Agent::History::Message.new(
            id: Pikuri::Agent::History.mint_id, role: 'user', content: 'hello'
          )
        ]
      )

      save(conversation, history)
      # #save's order is history-then-envelope; assert the reverse direction
      # too, since History#save is the one that could clobber.
      history.save(conversation.dir)

      assert_equal %w[history.json meta.json], conversation.dir.children.map { |c| c.basename.to_s }.sort
      assert_equal 'pikuri-web-chat', meta_of(conversation).fetch('shell')
      assert_equal history, Pikuri::Agent::History.load(conversation.dir)
    end
  end
end
