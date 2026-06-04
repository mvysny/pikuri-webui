# frozen_string_literal: true

RSpec.describe PikuriWeb::LogIO do
  let(:broadcaster) { PikuriWeb::Broadcaster.new }
  let(:log_io) { described_class.new(broadcaster: broadcaster) }

  context '#write' do
    it 'retains lines and broadcasts each as a log event' do
      queue = broadcaster.subscribe
      log_io.write("INFO booted\n")
      assert_equal ['INFO booted'], log_io.lines
      frames = drain_frames(queue)
      assert_equal 1, frames.size
      assert_includes frames.fetch(0), 'event: log'
      assert_includes frames.fetch(0), 'INFO booted'
    end

    it 'splits embedded newlines into separate lines and drops blanks' do
      log_io.write("one\n\ntwo\n")
      assert_equal %w[one two], log_io.lines
    end

    it 'returns total bytes accepted' do
      assert_equal 4, log_io.write('four')
    end
  end

  context '#puts and #<<' do
    it 'supports the Logger-facing IO surface' do
      log_io.puts('via puts')
      log_io << 'via shovel'
      assert_equal ['via puts', 'via shovel'], log_io.lines
    end
  end

  context 'ring buffer' do
    it 'caps retained lines at MAX_LINES, dropping the oldest' do
      (described_class::MAX_LINES + 10).times { |i| log_io.write("line #{i}\n") }
      assert_equal described_class::MAX_LINES, log_io.lines.size
      assert_equal 'line 10', log_io.lines.first
    end
  end

  it 'works as a Logger sink' do
    logger = Logger.new(log_io)
    logger.warn('be careful')
    assert(log_io.lines.any? { |l| l.include?('be careful') })
  end
end
