# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new

Dir.glob('tasks/*.rake').each { |r| load r }

# The cross-repo standard entry point: `bundle exec rake check` (or bare
# `bundle exec rake`) runs the full verification. Here that is the spec
# suite, the YARD → RBS signatures (tasks/sig.rake), rubocop and the design/
# doc tripwires; the named aggregate exists so every repo answers to the same
# command.
desc 'Full check: the spec suite, the sord signatures, rubocop and the doc tripwires ' \
     '(the cross-repo standard entry point)'
task check: %i[spec sig rubocop design_tripwires]

task default: :check
