# frozen_string_literal: true

require 'tmpdir'

# Exercises the on-disk layout against a real temp directory, including the
# co-habitation with Pikuri::Agent::History#save that the format rests on.
RSpec.describe PikuriWeb::ConversationStore do
  around { |example| Dir.mktmpdir { |dir| @root = Pathname(dir) / 'conversations' and example.run } }

  let(:store) { described_class.new(root: @root, shell: 'pikuri-web-chat', model: 'qwen3.6') }
  let(:at) { Time.utc(2026, 8, 27, 12, 3, 51) }

  def meta_of(conversation)
    JSON.parse((conversation.dir / 'meta.json').read)
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

    it 'writes nothing — an unsaved conversation must not litter the root' do
      store.create(at: at)
      refute @root.exist?
    end
  end

  context '#write_meta' do
    it 'writes the envelope, creating the conversation directory' do
      conversation = store.create(at: at)
      store.write_meta(conversation, updated_at: Time.utc(2026, 8, 27, 12, 41, 2))

      assert_equal(
        {
          'schema' => 1,
          'id' => conversation.id,
          'title' => conversation.title,
          'created_at' => '2026-08-27T12:03:51Z',
          'updated_at' => '2026-08-27T12:41:02Z',
          'shell' => 'pikuri-web-chat',
          'model' => 'qwen3.6'
        },
        meta_of(conversation)
      )
    end

    it 'creates the root and the conversation directory 0700' do
      conversation = store.create(at: at)
      store.write_meta(conversation)
      assert_equal '700', (@root.stat.mode & 0o777).to_s(8)
      assert_equal '700', (conversation.dir.stat.mode & 0o777).to_s(8)
    end

    it 'rewrites in place on the next save, leaving no temp file behind' do
      conversation = store.create(at: at)
      store.write_meta(conversation, updated_at: Time.utc(2026, 8, 27, 12, 10, 0))
      store.write_meta(conversation, updated_at: Time.utc(2026, 8, 27, 13, 20, 0))

      assert_equal '2026-08-27T13:20:00Z', meta_of(conversation).fetch('updated_at')
      assert_equal ['meta.json'], conversation.dir.children.map { |c| c.basename.to_s }
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

      history.save(conversation.dir)
      store.write_meta(conversation)
      # The order the runner uses is history-then-meta; assert the reverse
      # direction too, since History#save is the one that could clobber.
      history.save(conversation.dir)

      assert_equal %w[history.json meta.json], conversation.dir.children.map { |c| c.basename.to_s }.sort
      assert_equal 'pikuri-web-chat', meta_of(conversation).fetch('shell')
      assert_equal history, Pikuri::Agent::History.load(conversation.dir)
    end
  end
end
