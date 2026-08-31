# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.3'

# Web framework. Modular style (Sinatra::Base subclass) so the app class
# is an ordinary constant under lib/ and testable with rack-test without
# global DSL pollution.
gem 'sinatra', '~> 4.1'

# Rack server. Threaded: each open EventSource connection parks one
# server thread in the SSE drain loop (see App#GET /events), so bin/
# pikuri-web raises the thread pool above Puma's default.
gem 'puma', '~> 8.0'

# Sinatra 4's run! resolves its server through the rackup handler API,
# which lives in this gem since Rack 3 split it out.
gem 'rackup', '~> 2.2'

# Convention-based autoloader for lib/. Wired up in lib/pikuri_web.rb so
# every file under lib/pikuri_web/ declares exactly the constant matching
# its path without per-file require_relative ceremony.
gem 'zeitwerk', '~> 2.7'

# The pikuri-core gem — Agent, Tool, prompts, listeners. Same wiring as
# pikuri-tui's chat shell: bin/pikuri-web-chat binds Pikuri::Agent +
# Pikuri::Tool::* into the Sinatra app via the SseListener adapter.
#
# Released gems, pinned to one minor: pikuri is pre-1.0, so 0.2 may break
# what 0.1 promised, and an upgrade is a deliberate act with pikuri's
# CHANGELOG open. Both lines move together because pikuri-pdf's gemspec
# pins `pikuri-core = <exact version>` in lockstep.
gem 'pikuri-core', '~> 0.1.0'
gem 'pikuri-pdf', '~> 0.1.0'

# Server-side Markdown → HTML for assistant/thinking content. The web
# analogue of the TUI's TTY::Markdown: rendering happens on the server
# so the browser receives plain HTML and ships no Markdown JS.
gem 'kramdown', '~> 2.5'

# GFM input parser for kramdown: LLMs emit backtick fences and pipe
# tables, which kramdown's native syntax doesn't cover.
gem 'kramdown-parser-gfm', '~> 1.1'

# TOML parser for the layered config file (PikuriWeb::Config), which
# shares its schema and its `~/.config/pikuri/config.toml` location with
# pikuri-tui's Shared::Config — one file configures every pikuri shell on
# the machine. Pure Ruby, parse-only (we only ever READ config, never
# serialize), with ZERO runtime dependencies — chosen over toml-rb after
# vetting: toml-rb pulls in citrus, which was last released in 2015 and
# ships no license. tomlrb is MIT and actively maintained. We parse TOML
# into a Hash and validate that Hash by hand (the schema is tiny); no
# JSON Schema gem.
gem 'tomlrb', '~> 2.0'

# Thread pool for agent turns. A turn blocks on the LLM for minutes, so it
# runs as a job on an executor rather than on a Sinatra request thread —
# and the executor's queue is also the admission gate that keeps concurrent
# turns from outnumbering the inference server's slots.
#
# A genuinely new direct dependency (not previously in the bundle, not even
# transitively), and the first `Concurrent::` reference in the pikuri
# family: pikuri itself is stdlib `Mutex` throughout. It earns that because
# Ruby ships no executor at all, so the alternative is hand-rolling a
# thread pool, a shutdown protocol and a backpressure policy — exactly the
# primitives a well-tested library should own. Concretely we take
# FixedThreadPool (production, sized by --turns), ImmediateExecutor (specs
# run turns inline, which deletes a spin-wait helper), and the
# shutdown/kill protocol. Tuile already depends on it in this family, for
# the same reason one layer down.
#
# MIT, zero runtime dependencies of its own, and a de-facto Ruby standard
# (ActiveSupport depends on it).
gem 'concurrent-ruby', '~> 1.3'

# ERB engine Tilt picks over stdlib ERB. Needed for Sinatra's
# +erb, escape_html: true+ auto-escaping and the +<%==+ raw-output tag
# (stdlib ERB supports neither) — index.erb escapes everything except
# the deliberately raw transcript-block HTML.
gem 'erubi', '~> 1.13'

group :test do
  # Runs the Rakefile's `check` task — the cross-repo standard entry
  # point (`bundle exec rake check`; also the default task).
  gem 'rake', '~> 13.3'

  # Test runner. We use the rspec-core describe/it harness but write
  # assertions in minitest style — see AGENTS.md. Matches pikuri's
  # convention so the codebases read side-by-side.
  gem 'rspec-core', '~> 3.13'

  # Provides the minitest-style assertion methods (assert_equal,
  # assert_includes, refute, …) used throughout spec/.
  gem 'minitest', '~> 6.0'

  # Drives the Sinatra app in-process in specs — no server boot, no
  # sockets.
  gem 'rack-test', '~> 2.1'
end
