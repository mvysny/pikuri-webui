# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'concurrent'
require 'rspec/core'
require 'minitest'
require 'minitest/assertions'
require 'rack/test'

require 'pikuri-core'
require 'pikuri_web'

# Silence pikuri's default $stderr logging and PikuriWeb's own logger
# during the suite so production log lines don't bleed into rspec output.
# Specs that exercise logging swap the sinks for their own.
Pikuri.log_io = File.open(File::NULL, 'w')
PikuriWeb.logger = Logger.new(File::NULL)

RSpec.configure do |config|
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
# @param lock [PikuriWeb::BigAppLock] the domain it is guarded by
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

# Run the block with PikuriWeb.logger writing to a StringIO, and return
# everything it logged. Restores the silenced suite logger afterwards.
#
# @return [String]
def capture_log
  io = StringIO.new
  previous = PikuriWeb.logger
  PikuriWeb.logger = Logger.new(io)
  yield
  io.string
ensure
  PikuriWeb.logger = previous
end
