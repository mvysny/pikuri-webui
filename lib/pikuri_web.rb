# frozen_string_literal: true

require 'zeitwerk'
require 'logger'

# Boot file: configures Zeitwerk for everything under +lib/pikuri_web/+
# and eager-loads it. After +require 'pikuri_web'+, every constant
# declared in this tree is defined and resolvable. Eager-loading at
# boot keeps the rule "filename matches CamelCase constant" honest
# (any mismatch fails fast at startup, not at first reference inside
# a request).
module PikuriWeb
  class << self
    # Project-internal logger. Writes to $stderr, next to pikuri's own
    # diagnostic loggers — the browser shows the conversation only.
    #
    # @return [Logger]
    def logger
      @logger ||= Logger.new($stderr, progname: 'pikuri-web')
    end

    # @param value [Logger] where diagnostics go from now on
    attr_writer :logger
  end

  loader = Zeitwerk::Loader.for_gem
  loader.setup
  loader.eager_load
end
