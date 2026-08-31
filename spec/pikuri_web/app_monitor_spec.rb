# frozen_string_literal: true

RSpec.describe PikuriWeb::AppMonitor do
  let(:monitor) { described_class.new }

  context '#run' do
    it 'runs the task inline on the calling thread and returns its value' do
      ran_on = nil
      value = monitor.run do
        ran_on = Thread.current
        42
      end
      assert_equal 42, value
      assert_same Thread.current, ran_on
    end

    it 're-enters: a task may open a task' do
      assert_equal :ok, monitor.run { monitor.run { :ok } }
    end
  end

  context '#assert!' do
    it 'passes inside a task' do
      assert_nil monitor.run { monitor.assert! }
    end

    it 'raises outside one' do
      assert_raises(described_class::OutsideTask) { monitor.assert! }
    end

    it 'raises on a thread that is not the one inside the task' do
      inside = Thread::Queue.new
      release = Thread::Queue.new
      holder = Thread.new do
        monitor.run do
          inside.push(:in)
          release.pop
        end
      end
      inside.pop
      assert_raises(described_class::OutsideTask) { monitor.assert! }
      release.push(:go)
      holder.join
    end

    # The blanket `rescue StandardError` recovery paths (the turn job, the
    # registry's delete) must never mask a guarding bug as an operational
    # failure.
    it 'raises something a rescue StandardError cannot swallow' do
      refute_includes described_class::OutsideTask.ancestors, StandardError
    end
  end
end
