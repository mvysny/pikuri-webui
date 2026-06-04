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
# pikuri-tui's chat shell: bin/pikuri-web binds Pikuri::Agent +
# Pikuri::Tool::* into the Sinatra app via the SseListener adapter.
gem 'pikuri-core', '~> 0.0.4'

# Server-side Markdown → HTML for assistant/thinking content. The web
# analogue of the TUI's TTY::Markdown: rendering happens on the server
# so the browser receives plain HTML and ships no Markdown JS.
gem 'kramdown', '~> 2.5'

# GFM input parser for kramdown: LLMs emit backtick fences and pipe
# tables, which kramdown's native syntax doesn't cover.
gem 'kramdown-parser-gfm', '~> 1.1'

# ERB engine Tilt picks over stdlib ERB. Needed for Sinatra's
# +erb, escape_html: true+ auto-escaping and the +<%==+ raw-output tag
# (stdlib ERB supports neither) — index.erb escapes everything except
# the deliberately raw transcript-block HTML.
gem 'erubi', '~> 1.13'

group :test do
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
