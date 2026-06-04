# frozen_string_literal: true

RSpec.describe PikuriWeb::Broadcaster do
  let(:broadcaster) { described_class.new }

  context '#broadcast' do
    it 'formats an SSE frame with event type and JSON data' do
      queue = broadcaster.subscribe
      broadcaster.broadcast(event: :block, data: { id: 'b1', html: '<p>hi</p>' })
      assert_equal ["event: block\ndata: {\"id\":\"b1\",\"html\":\"<p>hi</p>\"}\n\n"], drain_frames(queue)
    end

    it 'fans out to every subscriber' do
      queues = Array.new(3) { broadcaster.subscribe }
      broadcaster.broadcast(event: :status, data: { busy: true })
      queues.each { |q| assert_equal 1, drain_frames(q).size }
    end

    it 'delivers frames in order' do
      queue = broadcaster.subscribe
      broadcaster.broadcast(event: :block, data: { id: 'b1' })
      broadcaster.broadcast(event: :remove, data: { id: 'b1' })
      assert_equal %w[block remove], drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }
    end
  end

  context '#broadcast_comment' do
    it 'pushes an SSE comment frame' do
      queue = broadcaster.subscribe
      broadcaster.broadcast_comment
      assert_equal [": ping\n\n"], drain_frames(queue)
    end
  end

  context '#unsubscribe' do
    it 'stops delivery to the removed queue' do
      queue = broadcaster.subscribe
      broadcaster.unsubscribe(queue)
      broadcaster.broadcast(event: :log, data: { line: 'x' })
      assert_empty drain_frames(queue)
      assert_equal 0, broadcaster.size
    end
  end

  context '#unsubscribe_all' do
    it 'pushes the nil shutdown sentinel and drops all subscribers' do
      queue = broadcaster.subscribe
      broadcaster.unsubscribe_all
      assert_nil queue.pop
      assert_equal 0, broadcaster.size
    end
  end
end
