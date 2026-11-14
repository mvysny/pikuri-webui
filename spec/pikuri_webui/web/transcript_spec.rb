# frozen_string_literal: true

RSpec.describe PikuriWebUI::Web::Transcript do
  let(:lock) { PikuriWebUI::BigAppLock.new }
  let(:transcript) { guard(described_class.new(lock: lock), lock) }

  it 'raises on any call outside a task' do
    bare = described_class.new(lock: lock)
    assert_raises(PikuriWebUI::BigAppLock::OutsideTask) { bare.add(kind: :user, html: 'hi') }
    assert_raises(PikuriWebUI::BigAppLock::OutsideTask) { bare.to_a }
  end

  context '#add' do
    it 'assigns sequential ids' do
      a = transcript.add(kind: :user, html: 'hi')
      b = transcript.add(kind: :assistant, html: 'hello')
      assert_equal 'b1', a.id
      assert_equal 'b2', b.id
    end

    it 'stores kind and html' do
      block = transcript.add(kind: :tool_call, html: '→ calc(1+1)')
      assert_equal :tool_call, block.kind
      assert_equal '→ calc(1+1)', block.html
    end
  end

  context '#update' do
    it 'rewrites the block in place' do
      block = transcript.add(kind: :assistant, html: '')
      transcript.update(block.id, '<p>partial</p>')
      assert_equal ['<p>partial</p>'], transcript.to_a.map(&:html)
    end

    it 'ignores unknown ids' do
      transcript.add(kind: :user, html: 'hi')
      transcript.update('b999', 'nope')
      assert_equal ['hi'], transcript.to_a.map(&:html)
    end
  end

  context '#remove' do
    it 'drops the block' do
      block = transcript.add(kind: :assistant, html: 'preview')
      transcript.add(kind: :tool_call, html: '→ tool()')
      transcript.remove(block.id)
      assert_equal ['→ tool()'], transcript.to_a.map(&:html)
    end

    it 'ignores unknown ids' do
      transcript.add(kind: :user, html: 'hi')
      transcript.remove('b999')
      assert_equal 1, transcript.to_a.size
    end
  end

  context '#to_a' do
    it 'returns a snapshot that does not share the internal list' do
      transcript.add(kind: :user, html: 'hi')
      snapshot = transcript.to_a
      transcript.add(kind: :assistant, html: 'hello')
      assert_equal 1, snapshot.size
      assert_equal 2, transcript.to_a.size
    end

    it 'preserves insertion order' do
      transcript.add(kind: :user, html: 'one')
      transcript.add(kind: :assistant, html: 'two')
      assert_equal %w[one two], transcript.to_a.map(&:html)
    end
  end
end
