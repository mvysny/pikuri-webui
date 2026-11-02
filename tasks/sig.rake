# frozen_string_literal: true

# Types are written once, as YARD tags in lib/; sord compiles them into sig/pikuri_web.rbs, which
# is committed but never edited by hand. `rake check` runs `sig`, and CI fails when the
# regenerated file differs from the committed one.
#
# There's no `sig:validate`: `rbs validate` would have to resolve every Pikuri::, Sinatra::,
# Rack:: and Concurrent:: name, and none of those gems ships a sig/. Their signatures exist only
# as downloads (`rbs collection`).

SIG_FILE = 'sig/pikuri_web.rbs'

# sord sees only this project, so it warns "wasn't able to be resolved to a constant" for every
# Pikuri:: / Sinatra:: / stdlib name and writes it through unchanged. A warning only passes when
# Ruby, with the whole app and every gem it wires loaded, resolves the name from the top level. A
# bare name that relies on lexical scope or an `include` still fails.
#
# @param line [String] one line of sord's output, ANSI-stripped
# @return [Boolean] true for an unresolved-constant warning about a name Ruby knows
def sig_outside_constant?(line)
  name = line[/\) \S+: (\S+) wasn't able to be resolved to a constant in this project$/, 1]
  return false unless name

  @sig_app_loaded ||= begin
    # The same set bin/pikuri-web-chat wires; pikuri_web eager-loads itself on require.
    %w[pikuri-core pikuri-pdf concurrent rack].each { |gem| require gem }
    $LOAD_PATH.unshift File.expand_path('../lib', __dir__)
    require 'pikuri_web'
    true
  end
  Object.const_defined?(name)
end

namespace :sig do
  desc "Regenerate #{SIG_FILE} from the YARD tags via sord; fails on any sord warning"
  task :generate do
    require 'English'
    rm_rf '.yardoc'
    mkdir_p 'sig'
    out = `bundle exec sord gen #{SIG_FILE} --rbs --regenerate --no-sord-comments 2>&1`
          .gsub(/\e\[[0-9;]*m/, '')
    print out
    raise 'sord exited non-zero' unless $CHILD_STATUS.success?

    # Per-object lines only: the closing "There were N important warnings" repeats them.
    offenders = out.lines.grep(/^\[(OMIT|INFER|WARN|ERROR)\s*\] \(/).reject { |l| sig_outside_constant?(l) } +
                out.lines.grep(/^Parlour warning/)
    raise "sord emitted #{offenders.size} warning(s):\n#{offenders.join}" unless offenders.empty?
  end
end

desc "Regenerate #{SIG_FILE} (sig:generate)"
task sig: 'sig:generate'
