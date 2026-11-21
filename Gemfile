# frozen_string_literal: true

source 'https://rubygems.org'

ruby '>= 3.3'

# Web framework. Modular style (Sinatra::Base subclass) so the app class
# is an ordinary constant under lib/ and testable with rack-test without
# global DSL pollution.
gem 'sinatra', '~> 4.1'

# Rack server. Threaded: each open EventSource connection parks one
# server thread in the SSE drain loop (see App#GET /events), so bin/
# pikuri-webui raises the thread pool above Puma's default.
gem 'puma', '~> 8.0'

# Sinatra 4's run! resolves its server through the rackup handler API,
# which lives in this gem since Rack 3 split it out.
gem 'rackup', '~> 2.2'

# Convention-based autoloader for lib/. Wired up in lib/pikuri_webui.rb so
# every file under lib/pikuri_webui/ declares exactly the constant matching
# its path without per-file require_relative ceremony.
gem 'zeitwerk', '~> 2.7'

# The pikuri gems come from two repos: pikuri's released gems from RubyGems,
# and pikuri-workshop's git master, which has no release yet
# (`D_pikuri_gem_sources`). `bundle update pikuri-core pikuri-pdf pikuri-web
# pikuri-conversations` moves both.
#
# pikuri itself: pikuri-core (Agent, Tool, prompts, listeners), pikuri-pdf
# (PDF text for fetch) and pikuri-web (web_search, web_scrape, fetch, and,
# through pikuri-html, the extractor that renders a fetched page as Markdown).
# `~> 0.2.0` admits patch releases only, since while pikuri is 0.x a minor
# release carries breaking changes; it is the requirement the workshop's
# gemspecs state, so a workshop that moves on to pikuri 0.3 fails to resolve
# here rather than calling into a pikuri that lacks what it needs.
gem 'pikuri-core', '~> 0.2.0'
gem 'pikuri-pdf', '~> 0.2.0'
gem 'pikuri-web', '~> 0.2.0'

# pikuri-workshop's pikuri-conversations: the live conversations (an agent
# each, turns on threads of their own, mid-turn messages, cancel, the model
# switch), the per-server request throttle and /props probe, the titler, and
# the folder of saved conversations. What this shell used to build itself.
# Gemfile.lock pins the commit.
gem 'pikuri-conversations', git: 'https://github.com/mvysny/pikuri-workshop.git', branch: 'master'

# Server-side Markdown → HTML for assistant/thinking content. The web
# analogue of the TUI's TTY::Markdown: rendering happens on the server
# so the browser receives plain HTML and ships no Markdown JS.
gem 'kramdown', '~> 2.5'

# GFM input parser for kramdown: LLMs emit backtick fences and pipe
# tables, which kramdown's native syntax doesn't cover.
gem 'kramdown-parser-gfm', '~> 1.1'

# Cuts a streamed reply into finished kramdown blocks for
# Web::StreamingMessage, so each is rendered and sent once and only the open
# tail re-renders per delta (D_stream_blocks_once) — the library pikuri-tui's
# streaming buffer runs on. Its options and Repair (em-dash table separators)
# also run in Util::MarkdownRenderer, so both shells render a reply alike.
gem 'streaming-markdown-parser', '~> 0.1'

# TOML parser for the layered config file (PikuriWebUI::Config), which
# shares its schema and its `~/.config/pikuri/config.toml` location with
# pikuri-tui's Shared::Config — one file configures every pikuri shell on
# the machine. Pure Ruby, parse-only (we only ever READ config, never
# serialize), with ZERO runtime dependencies — chosen over toml-rb after
# vetting: toml-rb pulls in citrus, which was last released in 2015 and
# ships no license. tomlrb is MIT and actively maintained. typemap, below,
# checks the parsed Hash; no JSON Schema gem.
gem 'tomlrb', '~> 3.0'

# Maps the parsed TOML onto PikuriWebUI::Config's Data classes, checking every
# value against the type its YARD tag gives. Typemap reads those types from
# sig/pikuri_webui.rbs through rbs's parser, so rbs is a runtime gem here (about
# 0.2 s of `require` at boot).
gem 'rbs', '~> 4.2'
gem 'typemap', '~> 0.1'

# ERB engine Tilt picks over stdlib ERB. Needed for Sinatra's
# +erb, escape_html: true+ auto-escaping and the +<%==+ raw-output tag
# (stdlib ERB supports neither) — index.erb escapes everything except
# the deliberately raw transcript-block HTML.
gem 'erubi', '~> 1.13'

# Types are written once, as YARD tags; sord compiles them into the committed
# sig/pikuri_webui.rbs, and `rake sig` (part of `rake check`) fails on any tag
# sord cannot type. redcarpet renders the Markdown that .yardopts selects;
# rubocop is `rake check`'s style gate. Versions track pikuri-tui's.
group :development do
  gem 'redcarpet', '~> 3.6'
  gem 'rubocop', '~> 1.92', require: false
  gem 'sord', '~> 7.1', require: false
  gem 'yard', '~> 0.9.45'
end

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
