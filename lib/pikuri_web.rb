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
    # Project-internal logger. Defaults to $stderr; bin/pikuri-web rewires
    # it to a {LogIO} so PikuriWeb's diagnostics land in the browser's log
    # panel alongside pikuri's own (which arrive via +Pikuri.log_io=+).
    #
    # @return [Logger]
    def logger
      @logger ||= Logger.new($stderr, progname: 'pikuri-web')
    end

    # @param logger [Logger]
    attr_writer :logger
  end

  loader = Zeitwerk::Loader.for_gem
  # The default camelizer would resolve +log_io.rb+ to +LogIo+; the
  # all-caps +LogIO+ reads naturally next to Ruby's own +IO+ (and next to
  # the TUI sibling's +CountingLogIO+). Zeitwerk's inflector matches the
  # whole basename rather than per-segment, so the mapping spells the
  # full word.
  loader.inflector.inflect('log_io' => 'LogIO')
  loader.setup
  loader.eager_load
end
