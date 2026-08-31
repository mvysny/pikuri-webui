# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

# The cross-repo standard entry point: `bundle exec rake check` (or bare
# `bundle exec rake`) runs the full verification. Here that is just the
# spec suite; the named aggregate exists so every repo answers to the
# same command.
desc 'Full check: the whole spec suite (the cross-repo standard entry point)'
task check: :spec

task default: :check
