# frozen_string_literal: true

RSpec.describe PikuriWeb::Broadcaster do
  let(:broadcaster) { described_class.new }

  context '#broadcast' do
    it 'formats an SSE frame with event type and JSON data' do
      queue = broadcaster.subscribe('c-1')
      broadcaster.broadcast(event: :block, data: { id: 'b1', html: '<p>hi</p>' }, conversation: 'c-1')
      assert_equal ["event: block\ndata: {\"id\":\"b1\",\"html\":\"<p>hi</p>\"}\n\n"], drain_frames(queue)
    end

    # The property detaching rests on: a turn running in one conversation never
    # reaches a tab reading another.
    it 'delivers a conversation frame only to that conversation subscribers' do
      mine = broadcaster.subscribe('c-1')
      theirs = broadcaster.subscribe('c-2')
      broadcaster.broadcast(event: :block, data: { id: 'b1' }, conversation: 'c-1')

      assert_equal 1, drain_frames(mine).size
      assert_empty drain_frames(theirs)
    end

    it 'delivers an unaddressed frame to everyone, whatever they are reading' do
      queues = %w[c-1 c-2 c-3].map { |id| broadcaster.subscribe(id) }
      broadcaster.broadcast(event: :conversations, data: {})
      queues.each { |q| assert_equal 1, drain_frames(q).size }
    end

    it 'fans out to every subscriber on the same conversation' do
      queues = Array.new(3) { broadcaster.subscribe('c-1') }
      broadcaster.broadcast(event: :status, data: { busy: true }, conversation: 'c-1')
      queues.each { |q| assert_equal 1, drain_frames(q).size }
    end

    it 'delivers frames in order' do
      queue = broadcaster.subscribe('c-1')
      broadcaster.broadcast(event: :block, data: { id: 'b1' }, conversation: 'c-1')
      broadcaster.broadcast(event: :remove, data: { id: 'b1' }, conversation: 'c-1')
      assert_equal %w[block remove], drain_frames(queue).map { |f| f[/event: (\w+)/, 1] }
    end
  end

  context '#broadcast_comment' do
    it 'pushes an SSE comment frame to every subscriber' do
      queue = broadcaster.subscribe('c-1')
      broadcaster.broadcast_comment
      assert_equal [": ping\n\n"], drain_frames(queue)
    end
  end

  context '#size' do
    it 'counts one conversation subscribers, or all of them' do
      broadcaster.subscribe('c-1')
      broadcaster.subscribe('c-1')
      broadcaster.subscribe('c-2')

      assert_equal 3, broadcaster.size
      assert_equal 2, broadcaster.size('c-1')
      assert_equal 0, broadcaster.size('c-9')
    end
  end

  context '#unsubscribe' do
    it 'stops delivery to the removed queue' do
      queue = broadcaster.subscribe('c-1')
      broadcaster.unsubscribe(queue)
      broadcaster.broadcast(event: :status, data: { busy: false }, conversation: 'c-1')
      assert_empty drain_frames(queue)
      assert_equal 0, broadcaster.size
    end
  end

  context '#close' do
    it 'pushes the nil shutdown sentinel and drops all subscribers' do
      queue = broadcaster.subscribe('c-1')
      broadcaster.close
      assert_nil queue.pop
      assert_equal 0, broadcaster.size
    end

    it 'hands a late subscriber a queue holding only the sentinel' do
      broadcaster.close
      queue = broadcaster.subscribe('c-1')
      assert_nil queue.pop
      assert_equal 0, broadcaster.size
    end

    it 'is idempotent' do
      broadcaster.close
      broadcaster.close
      assert_equal 0, broadcaster.size
    end
  end
end
