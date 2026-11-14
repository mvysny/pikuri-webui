# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'rspec/core'
require 'minitest'
require 'minitest/assertions'
require 'rack/test'

require 'pikuri-core'
require 'pikuri_webui'

# Silence pikuri's default $stderr logging and PikuriWebUI's own logger
# during the suite so production log lines don't bleed into rspec output.
# Specs that exercise logging swap the sinks for their own.
Pikuri.log_io = File.open(File::NULL, 'w')
PikuriWebUI.logger = Logger.new(File::NULL)

RSpec.configure do |config|
  # Pikuri::Testing.fake_transport states its cap and modalities; with its
  # server sized too, pikuri-conversations' probe never dials it. Process-wide
  # state on both, so every example starts from none.
  config.before do
    Pikuri::Conversations::Throttle.limit('http://fake.invalid', nil)
  end
  config.after do
    Pikuri::Conversations::Throttle.reset!
    Pikuri::Conversations::Probe.reset!
  end

  config.include Minitest::Assertions
  config.include(Module.new do
    attr_writer :assertions

    def assertions
      @assertions ||= 0
    end
  end)
end

# The spec-side stand-in for App's route wrapping: every method call on the
# wrapped object runs as its own BigAppLock task, so a spec drives guarded
# classes the way a route does. Returned values come back raw — a chained
# call on one needs its own wrap.
class Guarded
  def initialize(object, lock)
    @object = object
    @lock = lock
  end

  def method_missing(name, ...)
    @lock.run { @object.public_send(name, ...) }
  end

  def respond_to_missing?(name, include_private = false)
    @object.respond_to?(name, include_private)
  end
end

# @param object [Object] a guarded instance (Agents::Runner, Web::Transcript, …)
# @param lock [PikuriWebUI::BigAppLock] the domain it is guarded by
# @return [Guarded]
def guard(object, lock) = Guarded.new(object, lock)

# Drain every frame currently sitting in a Broadcaster subscription
# queue, non-blocking. Specs subscribe, poke the producer, then assert
# on the drained frames.
#
# @param queue [Thread::Queue]
# @return [Array<String>]
def drain_frames(queue)
  frames = []
  frames << queue.pop(true) until queue.empty?
  frames
rescue ThreadError
  frames
end

# Wait until the block is truthy, polling; raises after +timeout+ seconds.
#
#   wait_until { lock.run { !runner.busy? } }
#
# @param timeout [Numeric]
# @return [Object] the block's truthy value
def wait_until(timeout: 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    value = yield
    return value if value
    raise 'timed out waiting for a condition' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.005
  end
end

# Wait until a runner's conversation is at rest: booted, no turn running, and
# neither of the gem's threads for it (+boot <id>+, +turn <id>+) still alive —
# so whatever the last turn reported, its save and its status frames included,
# has landed. The state check comes first because a thread names itself only
# once it runs, which is also why a title is not covered: the turn spawns its
# thread on the way out, so wait for a title by its effect.
#
# @param runner [PikuriWebUI::Agents::Runner] unguarded
# @param lock [PikuriWebUI::BigAppLock]
# @return [void]
def settle(runner, lock)
  id = lock.run { runner.conversation.id }
  names = %w[boot turn].map { |kind| "#{kind} #{id}" }
  wait_until do
    lock.run { %w[starting running].none?(runner.status_data[:state]) } &&
      Thread.list.none? { |t| t.alive? && names.include?(t.name) }
  end
  nil
end

# Run the block with PikuriWebUI.logger writing to a StringIO, and return
# everything it logged. Restores the silenced suite logger afterwards.
#
# @return [String]
def capture_log
  io = StringIO.new
  previous = PikuriWebUI.logger
  PikuriWebUI.logger = Logger.new(io)
  yield
  io.string
ensure
  PikuriWebUI.logger = previous
end
