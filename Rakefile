# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

Dir.glob('tasks/*.rake').each { |r| load r }

# The cross-repo standard entry point: `bundle exec rake check` (or bare
# `bundle exec rake`) runs the full verification. Here that is the spec
# suite plus the design/ doc tripwires; the named aggregate exists so every
# repo answers to the same command.
desc 'Full check: the spec suite and the doc tripwires (the cross-repo standard entry point)'
task check: %i[spec design_tripwires]

task default: :check
