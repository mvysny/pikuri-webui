# frozen_string_literal: true

require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

desc 'Run the web app against the default local llama.cpp server'
task :run do
  sh 'bin/pikuri-web'
end

task default: :spec
