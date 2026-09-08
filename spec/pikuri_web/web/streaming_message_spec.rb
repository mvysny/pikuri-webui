# frozen_string_literal: true

RSpec.describe PikuriWeb::Web::StreamingMessage do
  # Counting renderer: assertions about the fast path need to observe
  # whether a render actually ran.
  let(:render_calls) { [] }
  let(:render) do
    lambda do |src|
      render_calls << src
      "<r>#{src}</r>"
    end
  end

  def build
    described_class.new(id: 'b1', render: render)
  end

  context 'construction' do
    it 'is not finalized and has empty source' do
      msg = build
      refute msg.finalized?
      assert_equal '', msg.source
    end
  end

  context '#append' do
    it 'accumulates source and re-renders the whole of it' do
      msg = build
      msg.append('Hello ')
      html = msg.append('world')
      assert_equal '<r>Hello world</r>', html
      assert_equal 'Hello world', msg.source
    end

    it 'is a no-op on nil and empty content' do
      msg = build
      msg.append('hi')
      assert_equal '<r>hi</r>', msg.append(nil)
      assert_equal '<r>hi</r>', msg.append('')
      assert_equal 1, render_calls.size
    end

    it 'raises after finalize' do
      msg = build
      msg.finalize('done')
      assert_raises(RuntimeError) { msg.append('more') }
    end
  end

  context '#finalize' do
    it 'replaces the accumulated source with the authoritative content' do
      msg = build
      msg.append('Helo wrold')
      html = msg.finalize('Hello world')
      assert_equal '<r>Hello world</r>', html
      assert_equal 'Hello world', msg.source
      assert msg.finalized?
    end

    it 'skips the re-render when authoritative equals the source (fast path)' do
      msg = build
      msg.append('Hello')
      html = msg.finalize('Hello')
      assert_equal '<r>Hello</r>', html
      assert_equal 1, render_calls.size
    end

    it 'raises when called twice' do
      msg = build
      msg.finalize('done')
      assert_raises(RuntimeError) { msg.finalize('again') }
    end
  end
end
