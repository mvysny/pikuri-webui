# frozen_string_literal: true

# Hooks the design/ doc-layer checks into rake (the layout is described in AGENTS.md, "Design
# docs"). The bash script is the single implementation; this task only runs it, so it rides
# in `rake check` — the agent's inner loop and CI both — rather than firing a session later.
# It needs bash and git, which the ruby:3.3 CI image has because bundler fetches pikuri with git.

desc 'Design docs: cited slugs resolve, headings and caps hold, CLAUDE.md is a symlink'
task :design_tripwires do
  sh 'design/verify_design_tripwires.sh'
end
