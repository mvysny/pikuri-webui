# frozen_string_literal: true

require 'tomlrb'

module PikuriWeb
  # The `~/.config/pikuri/config.toml` model connections and provider
  # keys, resolved once at boot and read from there on:
  #
  #   config = PikuriWeb::Config.load
  #   config.primary_llm   # => Llm(name:, server:, model:, api_key:, context_window:)
  #   config.search        # => Search(brave_key:, exa_key:, engines:)
  #
  # Every load failure — unreadable file, malformed TOML, schema
  # violation — raises {Error}, naming the offending key.
  #
  #   [[llm]]
  #   name = "Local Qwen 3.6"
  #   server = "http://localhost:8080"
  #   model = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
  #
  #   [search]
  #   brave_key = "BSA…"
  #   engines = ["brave"]
  #
  # == The +[ui]+ table
  #
  #   [ui]
  #   show_thinking = false     # start with reasoning blocks collapsed
  #   tool_lines    = "verbose" # start on the raw argument dump
  #
  # Transcript density, one table for every pikuri shell because the
  # preference is per *person* far more than per shell. Parsed and exposed
  # ({#show_thinking} / {#tool_lines}) but wired to nothing here yet — this
  # shell renders reasoning and the verbose tool line unconditionally.
  #
  # == Precedence
  #
  # Lowest to highest: built-in defaults → +/etc/xdg/pikuri/config.toml+
  # (each +$XDG_CONFIG_DIRS+ entry, earlier = higher) →
  # +$XDG_CONFIG_HOME/pikuri/config.toml+ (default +~/.config+) →
  # +overrides:+. Tables merge key-by-key, so a system file can supply
  # +search.brave_key+ while the user file adds +exa_key+; arrays (the
  # +[[llm]]+ and +[[code.mcp]]+ lists) replace wholesale, nearest file
  # wins.
  #
  # No project-local layer, deliberately: a config file inside the repo
  # would be git-committable, and a literal {Llm#api_key} or {Search}
  # provider key must not live where a commit can carry it off.
  #
  # == Implementation details
  #
  # The schema is the *whole* pikuri-shell schema, not the subset this host
  # reads — {#sandbox}, {#confirm}, {#mcp}, {#show_thinking} and
  # {#tool_lines} are validated and exposed with nothing wired to them.
  # Trimming it would break the file: pikuri-tui writes +[code]+ /
  # +[[code.mcp]]+ / +[ui]+ into the same path, and {.load} raises on an
  # unknown top-level key.
  #
  # Names no +Pikuri::*+ constant, so it sits on the Pikuri-free side of
  # the seam (AGENTS.md). {Llm}'s fields match
  # +ChatTransport.from_openai_server+'s keyword arguments, {Search}'s
  # match +Tool::WebSearch.build+'s and {McpServer}'s match
  # +Mcp::Registry+'s entries, which keeps the bin's translation a
  # pass-through; +bearer_token+ / +basic_auth+ resolve into
  # {McpServer#headers} here so that stays true.
  #
  # Immutable.
  class Config
    # Raised for any unreadable / malformed / schema-invalid config file.
    # Carries a human-readable message naming the offending key or file.
    class Error < StandardError; end

    # One model connection; the first {Config#llms} entry is where a
    # conversation with no saved connection starts, and any of them is a
    # +/model+ pick away.
    #
    # @!attribute [r] name
    #   @return [String] unique display name, e.g. +"Local Qwen 3.6"+.
    # @!attribute [r] server
    #   @return [String] LLM server base URL (no +/v1+ suffix; a value
    #     that carries one is normalized by +from_openai_server+).
    # @!attribute [r] model
    #   @return [String] model identifier passed to the transport.
    # @!attribute [r] api_key
    #   @return [String, nil] the API key/token, stored literally, or +nil+
    #     when the entry omits it (the bin then falls back to
    #     +"not-needed"+, fine for a local llama.cpp). This file rather
    #     than an env var on purpose: the environment is inherited by every
    #     subprocess pikuri spawns, so a key there leaks to code the agent
    #     runs.
    # @!attribute [r] context_window
    #   @return [Integer, nil] explicit context-window cap for this
    #     connection, or +nil+ to let pikuri auto-detect it (its llama.cpp
    #     +/props+ probe, which yields +nil+ for a non-llama server). Set
    #     it for a cloud model the probe can't reach so the status bar
    #     shows a real +used/cap+. Rides the connection's
    #     +Pikuri::Agent::ChatTransport+, so it stays correct per-model.
    Llm = Data.define(:name, :server, :model, :api_key, :context_window)

    # One MCP server definition; exactly one of {#command} (local stdio
    # subprocess) / {#url} (remote HTTP) is non-nil. Parsed and validated
    # but wired to nothing — this host binds no MCP tools yet.
    #
    # +bearer_token+ / +basic_auth+ are TOML-level sugar rather than
    # fields: {.build_mcp_headers} folds them into {#headers} at load time,
    # so this exposes only the one hash +Registry::HttpEntry+ consumes 1:1.
    #
    # @!attribute [r] id
    #   @return [String] unique id the LLM uses to call +mcp_connect+.
    # @!attribute [r] command
    #   @return [Array<String>, nil] full argv to spawn a stdio server
    #     (exe first), or +nil+ for an HTTP server.
    # @!attribute [r] url
    #   @return [String, nil] endpoint URL of an HTTP server, or +nil+ for
    #     a stdio server.
    # @!attribute [r] headers
    #   @return [Hash{String => String}] HTTP headers sent on every request
    #     to an HTTP server (auth + custom), frozen. Always empty for a
    #     stdio server.
    # @!attribute [r] env
    #   @return [Hash{String => String}] extra environment variables for a
    #     stdio server's subprocess (merged over the inherited
    #     environment), frozen. Always empty for an HTTP server.
    McpServer = Data.define(:id, :command, :url, :headers, :env) do
      def initialize(id:, command: nil, url: nil, headers: {}, env: {})
        super(id: id, command: command, url: url, headers: headers.freeze, env: env.freeze)
      end

      # @return [Boolean] true for a local-subprocess (stdio) server.
      def stdio? = !command.nil?

      # @return [Boolean] true for a remote HTTP server.
      def http? = !url.nil?
    end

    # The web-search selection: which engines to search with, and the keys
    # the paid ones need. Every field is +nil+ when omitted, leaving pikuri's
    # own default — DuckDuckGo plus whichever key was configured. There is
    # nowhere else to put the keys — pikuri reads no provider key from +ENV+.
    #
    # @!attribute [r] brave_key
    #   @return [String, nil] Brave Search API key, or +nil+ when unset.
    # @!attribute [r] exa_key
    #   @return [String, nil] Exa API key, or +nil+ when unset.
    # @!attribute [r] engines
    #   @return [Array<String>, nil] the engines to search with — any of
    #     +duckduckgo+, +brave+, +exa+ — or +nil+ to derive the set from the
    #     keys. A *set*, not a preference order: pikuri shuffles per query, so
    #     +["brave", "duckduckgo"]+ splits traffic between the two rather than
    #     preferring Brave. Only the shape is checked here — an unknown name
    #     or an engine named without its key is pikuri's refusal.
    Search = Data.define(:brave_key, :exa_key, :engines) do
      def initialize(brave_key: nil, exa_key: nil, engines: nil)
        super(brave_key: brave_key, exa_key: exa_key, engines: engines&.freeze)
      end
    end

    # @return [String] display name of the synthetic default connection.
    DEFAULT_LLM_NAME = 'Local Qwen 3.6'
    # @return [String] default LLM server base URL (local llama.cpp).
    DEFAULT_SERVER = 'http://localhost:8080'
    # @return [String] default model identifier.
    DEFAULT_MODEL = 'unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M'
    # @return [Boolean] sandbox on unless a file says otherwise.
    DEFAULT_SANDBOX = true
    # @return [Boolean] confirm on unless a file says otherwise.
    DEFAULT_CONFIRM = true
    # @return [Boolean] reasoning blocks are shown unless +[ui]+ says otherwise.
    DEFAULT_SHOW_THINKING = true
    # @return [Symbol] the tool-line form to start on. Matches pikuri-tui's
    #   default so one file means one look in both shells.
    DEFAULT_TOOL_LINES = :short

    # Config file basename and the per-app subdirectory under each XDG
    # config root. Shared verbatim with pikuri-tui — same file.
    FILENAME   = 'config.toml'
    XDG_SUBDIR = 'pikuri'

    # Load and resolve the layered configuration.
    #
    # @param overrides [Hash{Symbol => String, Boolean, nil}] CLI
    #   overrides; +nil+ values are ignored (treated as "flag not given").
    #   Recognized keys: +:sandbox+, +:confirm+ — the coding switches, for
    #   a sibling shell that wires them (`D_chat_only_entry_point`).
    #   Nothing about a *connection* is overridable: no server, no model
    #   and no key. A secret must never travel on the command line
    #   (visible in +ps+ and shell history), and server/model would be a
    #   second source of truth for something the file already owns
    #   (`D_schema_complete_config`).
    # @param env [#[]] environment consulted for +XDG_CONFIG_HOME+ /
    #   +XDG_CONFIG_DIRS+. Defaults to +ENV+; injectable for tests.
    # @return [Config] the resolved configuration.
    # @raise [Error] on an unreadable / malformed / schema-invalid file.
    def self.load(overrides: {}, env: ENV)
      merged = {}
      any_loaded = false
      candidate_paths(env).each do |path|
        next unless File.file?(path)

        parsed = parse_file(path)
        PikuriWeb.logger.info("config: loaded #{path}")
        any_loaded = true
        warn_loose_perms(path, parsed)
        merged = deep_merge(merged, parsed)
      end
      PikuriWeb.logger.info('config: no config file found; using built-in defaults') unless any_loaded
      validate_top!(merged)

      llm_tables = merged['llm'] || []
      llms = llm_tables.empty? ? [default_llm] : llm_tables.each_with_index.map { |h, i| build_llm(h, i) }
      check_unique!(llms.map(&:name), 'llm name')

      code = merged['code'] || {}
      validate_code!(code)
      mcp = (code['mcp'] || []).each_with_index.map { |h, i| build_mcp(h, i) }
      check_unique!(mcp.map(&:id), 'code.mcp id')

      ui = merged['ui'] || {}
      validate_ui!(ui)

      new(
        llms:          llms,
        search:        build_search(merged['search']),
        sandbox:       pick(overrides[:sandbox], code['sandbox'], DEFAULT_SANDBOX),
        confirm:       pick(overrides[:confirm], code['confirm'], DEFAULT_CONFIRM),
        mcp:           mcp,
        show_thinking: pick(ui['show_thinking'], DEFAULT_SHOW_THINKING),
        tool_lines:    pick(ui['tool_lines']&.to_sym, DEFAULT_TOOL_LINES)
      )
    end

    # @param llms [Array<Llm>] one or more model connections (never empty).
    # @param search [Search] web-search provider keys (fields may be nil).
    # @param sandbox [Boolean] resolved sandbox switch (parsed, unwired).
    # @param confirm [Boolean] resolved confirmer switch (parsed, unwired).
    # @param mcp [Array<McpServer>] MCP servers (parsed, unwired; may be
    #   empty).
    # @param show_thinking [Boolean] resolved +[ui]+ reasoning-block default
    #   (parsed, unwired).
    # @param tool_lines [Symbol] resolved +[ui]+ tool-line form (parsed,
    #   unwired).
    def initialize(llms:, search:, sandbox:, confirm:, mcp:,
                   show_thinking: DEFAULT_SHOW_THINKING, tool_lines: DEFAULT_TOOL_LINES)
      @llms    = llms.freeze
      @search  = search
      @sandbox = sandbox
      @confirm = confirm
      @mcp     = mcp.freeze
      @show_thinking = show_thinking
      @tool_lines    = tool_lines
      freeze
    end

    # @return [Array<Llm>] all configured connections, declaration order.
    attr_reader :llms
    # @return [Search] the web-search provider keys (fields may be nil).
    attr_reader :search
    # @return [Boolean] sandbox switch (flag > file > default).
    attr_reader :sandbox
    # @return [Boolean] confirmer switch (flag > file > default).
    attr_reader :confirm
    # @return [Array<McpServer>] MCP servers, declaration order.
    attr_reader :mcp
    # @return [Boolean] whether reasoning blocks start shown (+[ui]+ > default).
    attr_reader :show_thinking
    # @return [Symbol] the tool-line form to start on (+[ui]+ > default) —
    #   whatever the file said, symbolized, so an unrecognized form arrives
    #   here unresolved. **The reader falls back**, as {App} does for an
    #   unknown +theme+ cookie; the vocabulary belongs to whoever renders it.
    attr_reader :tool_lines

    # @return [Llm] the boot connection (the first).
    def primary_llm = @llms.first

    # File layers, lowest priority first. +$XDG_CONFIG_DIRS+ (default
    # +/etc/xdg+) is +:+-separated with earlier entries ranking higher, so
    # we append them reversed; +$XDG_CONFIG_HOME+ (default +~/.config+)
    # outranks all of them. No project-local layer — see the class header.
    def self.candidate_paths(env)
      paths = []
      dirs = env['XDG_CONFIG_DIRS'].to_s.empty? ? '/etc/xdg' : env['XDG_CONFIG_DIRS']
      dirs.split(':').reverse_each { |d| paths << File.join(d, XDG_SUBDIR, FILENAME) }
      home = env['XDG_CONFIG_HOME'].to_s.empty? ? File.join(Dir.home, '.config') : env['XDG_CONFIG_HOME']
      paths << File.join(home, XDG_SUBDIR, FILENAME)
      paths
    end

    # Advise (non-fatally, through {PikuriWeb.logger}) when a file carrying
    # a literal secret (an +[[llm]]+ api_key or a +[search]+ provider key)
    # is group/other-accessible — a plaintext secret should be +chmod 600+.
    # Only files that actually contain a secret are checked, so a
    # world-readable but secret-free /etc/xdg config raises no noise.
    def self.warn_loose_perms(path, parsed)
      return unless holds_secret?(parsed)

      mode = File.stat(path).mode
      return if (mode & 0o077).zero?

      PikuriWeb.logger.warn(
        "config: #{path} holds a literal secret but is group/other-accessible " \
        "(mode #{format('%04o', mode & 0o7777)}); run `chmod 600 #{path}`."
      )
    rescue SystemCallError
      # stat failed (race, odd filesystem) — skip the advisory, never fatal.
    end

    # @return [Boolean] true when the parsed file carries any literal secret
    #   (an +[[llm]]+ +api_key+, a +[search]+ +brave_key+/+exa_key+, or an
    #   +[[code.mcp]]+ +bearer_token+/+basic_auth+/+headers+/+env+).
    def self.holds_secret?(parsed)
      llms = parsed['llm']
      return true if llms.is_a?(Array) && llms.any? { |e| e.is_a?(Hash) && e['api_key'] }

      search = parsed['search']
      return true if search.is_a?(Hash) && (search['brave_key'] || search['exa_key'])

      mcp = parsed.dig('code', 'mcp')
      mcp.is_a?(Array) && mcp.any? do |e|
        e.is_a?(Hash) && (e['bearer_token'] || e['basic_auth'] || e['headers'] || e['env'])
      end
    end

    # Parse one file, wrapping any failure (read error, TOML syntax) in
    # {Error} with the path attached — a library exception we surface at
    # boot rather than let escape as a bare backtrace.
    def self.parse_file(path)
      Tomlrb.parse(File.read(path))
    rescue StandardError => e
      raise Error, "failed to read config #{path}: #{e.class}: #{e.message}"
    end

    # Recursive merge: tables merge key-by-key; scalars and arrays take the
    # right-hand (higher-priority) value wholesale.
    def self.deep_merge(lower, higher)
      lower.merge(higher) do |_key, lo, hi|
        lo.is_a?(Hash) && hi.is_a?(Hash) ? deep_merge(lo, hi) : hi
      end
    end

    def self.validate_top!(merged)
      unknown = merged.keys - %w[llm search code ui]
      raise Error, "unknown top-level key(s): #{unknown.join(', ')}" unless unknown.empty?
      if merged.key?('llm') && !merged['llm'].is_a?(Array)
        raise Error, '`llm` must be an array of tables (use [[llm]], not [llm])'
      end
      if merged.key?('search') && !merged['search'].is_a?(Hash)
        raise Error, '`search` must be a table ([search])'
      end
      raise Error, '`code` must be a table ([code])' if merged.key?('code') && !merged['code'].is_a?(Hash)
      return unless merged.key?('ui') && !merged['ui'].is_a?(Hash)

      raise Error, '`ui` must be a table ([ui])'
    end

    # Validate the +[ui]+ table, deliberately more loosely than its
    # neighbours: an unknown key is logged and ignored, and +tool_lines+ is
    # checked for shape but never against a list of forms.
    #
    # pikuri-tui owns what grows here — it defines the keys and its own +[ui]+
    # rdoc already names the next one (+markdown+). Every strict check this
    # method *doesn't* make is one that would reject a legal file the day the
    # sibling shell adds a key or a third form, which is the boot failure the
    # +ui+ entry in {.validate_top!} exists to prevent. Same bargain
    # +search.engines+ takes; +show_thinking+ is strict because two values
    # cannot grow.
    #
    # @param ui [Hash] the raw +[ui]+ table (+{}+ when the section is absent).
    # @return [void]
    # @raise [Error] on a non-boolean +show_thinking+ or a non-string
    #   +tool_lines+.
    def self.validate_ui!(ui)
      unknown = ui.keys - %w[show_thinking tool_lines]
      unless unknown.empty?
        PikuriWeb.logger.info(
          "config: ignoring [ui] key(s) this shell does not read: #{unknown.join(', ')}"
        )
      end
      if ui.key?('show_thinking') && ![true, false].include?(ui['show_thinking'])
        raise Error, 'ui.show_thinking must be true or false'
      end
      return unless ui.key?('tool_lines') && !ui['tool_lines'].is_a?(String)

      raise Error, 'ui.tool_lines must be a string, e.g. tool_lines = "short"'
    end

    # Build the {Search} value object from the +[search]+ table (or +nil+
    # when the section is absent — every field then defaults to +nil+).
    #
    # Shape only, deliberately: *which* engine names are valid, and which of
    # them need a key, is pikuri's to say. Re-deciding it here would copy
    # pikuri's engine list into this Pikuri-free class, to rot the next time
    # a provider lands.
    def self.build_search(table)
      table ||= {}
      unknown = table.keys - %w[brave_key exa_key engines]
      raise Error, "search: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
      %w[brave_key exa_key].each do |k|
        raise Error, "search.#{k} must be a string" if table[k] && !table[k].is_a?(String)
      end
      engines = table['engines']
      if engines && !(engines.is_a?(Array) && engines.all?(String))
        raise Error, 'search.engines must be an array of strings, e.g. engines = ["brave"]'
      end

      Search.new(brave_key: table['brave_key'], exa_key: table['exa_key'], engines: engines)
    end

    def self.validate_code!(code)
      unknown = code.keys - %w[sandbox confirm mcp]
      raise Error, "code: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
      %w[sandbox confirm].each do |k|
        raise Error, "code.#{k} must be true or false" if code.key?(k) && ![true, false].include?(code[k])
      end
      return unless code.key?('mcp') && !code['mcp'].is_a?(Array)

      raise Error, 'code.mcp must be an array of tables (use [[code.mcp]])'
    end

    def self.build_llm(hash, index)
      raise Error, "llm[#{index}] must be a table" unless hash.is_a?(Hash)

      unknown = hash.keys - %w[name server model api_key context_window]
      raise Error, "llm[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      name = hash['name']
      raise Error, "llm[#{index}]: `name` is required and must be a non-empty string" unless non_empty_string?(name)

      %w[server model api_key].each do |k|
        raise Error, "llm #{name.inspect}: `#{k}` must be a string" if hash[k] && !hash[k].is_a?(String)
      end

      cw = hash['context_window']
      if cw && !(cw.is_a?(Integer) && cw.positive?)
        raise Error, "llm #{name.inspect}: `context_window` must be a positive integer"
      end

      Llm.new(
        name:           name,
        server:         hash['server'] || DEFAULT_SERVER,
        model:          hash['model'] || DEFAULT_MODEL,
        api_key:        hash['api_key'], # nil when omitted → "not-needed" at the bin
        context_window: cw # nil when omitted → pikuri auto-detects
      )
    end

    def self.build_mcp(hash, index)
      raise Error, "code.mcp[#{index}] must be a table" unless hash.is_a?(Hash)

      unknown = hash.keys - %w[id command url bearer_token basic_auth headers env]
      raise Error, "code.mcp[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      id = hash['id']
      raise Error, "code.mcp[#{index}]: `id` is required and must be a non-empty string" unless non_empty_string?(id)

      command = hash['command']
      url     = hash['url']
      unless command.nil? ^ url.nil?
        raise Error, "code.mcp #{id.inspect}: set exactly one of `command` (stdio) or `url` (http)"
      end
      if command && !(command.is_a?(Array) && !command.empty? && command.all?(String))
        raise Error, "code.mcp #{id.inspect}: `command` must be a non-empty array of strings"
      end
      raise Error, "code.mcp #{id.inspect}: `url` must be a non-empty string" if url && !non_empty_string?(url)

      auth_keys = hash.keys & %w[bearer_token basic_auth headers]
      if command && !auth_keys.empty?
        raise Error, "code.mcp #{id.inspect}: #{auth_keys.map { |k| "`#{k}`" }.join(', ')} apply only to " \
                     'HTTP servers (set `url`, not `command`)'
      end
      if url && hash.key?('env')
        raise Error, "code.mcp #{id.inspect}: `env` applies only to stdio servers (set `command`, not `url`)"
      end

      McpServer.new(
        id:      id,
        command: command,
        url:     url,
        headers: build_mcp_headers(hash, id),
        env:     build_mcp_env(hash, id)
      )
    end

    # Validate and return a stdio MCP entry's +env+ table (a
    # +Hash{String => String}+ merged over the subprocess's inherited
    # environment), or +{}+ when absent.
    #
    # @param hash [Hash] the raw +[[code.mcp]]+ table.
    # @param id [String] the entry id, for error messages.
    # @return [Hash{String => String}] the env overrides (empty when none).
    # @raise [Error] when +env+ is not a table of string => string.
    def self.build_mcp_env(hash, id)
      env = hash['env']
      return {} if env.nil?
      unless env.is_a?(Hash) && env.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
        raise Error, "code.mcp #{id.inspect}: `env` must be a table of string => string"
      end

      env
    end

    # Resolve an HTTP MCP entry's auth/custom keys into the single
    # +Hash{String => String}+ +HttpEntry+ consumes. +bearer_token+ and
    # +basic_auth+ are convenience sugar that both yield an +Authorization+
    # header, so they are mutually exclusive and also conflict with an
    # explicit +Authorization+ inside +headers+; the +headers+ table carries
    # arbitrary extras verbatim.
    #
    # @param hash [Hash] the raw +[[code.mcp]]+ table.
    # @param id [String] the entry id, for error messages.
    # @return [Hash{String => String}] the merged headers (empty when none).
    # @raise [Error] on a malformed +headers+/+bearer_token+/+basic_auth+
    #   value or an +Authorization+ conflict.
    def self.build_mcp_headers(hash, id)
      headers = {}

      custom = hash['headers']
      unless custom.nil?
        unless custom.is_a?(Hash) && custom.all? { |k, v| k.is_a?(String) && v.is_a?(String) }
          raise Error, "code.mcp #{id.inspect}: `headers` must be a table of string => string"
        end
        headers.merge!(custom)
      end

      bearer = hash['bearer_token']
      basic  = hash['basic_auth']
      raise Error, "code.mcp #{id.inspect}: set at most one of `bearer_token` or `basic_auth`" if bearer && basic

      auth =
        if bearer
          unless non_empty_string?(bearer)
            raise Error, "code.mcp #{id.inspect}: `bearer_token` must be a non-empty string"
          end

          "Bearer #{bearer}"
        elsif basic
          build_basic_auth(basic, id)
        end
      return headers unless auth

      if headers.keys.any? { |k| k.casecmp?('Authorization') }
        raise Error, "code.mcp #{id.inspect}: `bearer_token`/`basic_auth` conflicts with an `Authorization` " \
                     'entry in `headers` — set only one'
      end
      headers['Authorization'] = auth
      headers
    end

    # Build the +Authorization: Basic+ value from a +basic_auth+ table.
    # Encodes +username:password+ with strict (newline-free) Base64 via
    # +Array#pack+ so no +base64+ require is needed.
    #
    # @param basic [Object] the raw +basic_auth+ value (expected a table).
    # @param id [String] the entry id, for error messages.
    # @return [String] the full +"Basic <base64>"+ header value.
    # @raise [Error] when +basic_auth+ is not a table with a non-empty
    #   +username+ and a +password+ string.
    def self.build_basic_auth(basic, id)
      raise Error, "code.mcp #{id.inspect}: `basic_auth` must be a table" unless basic.is_a?(Hash)

      unknown = basic.keys - %w[username password]
      raise Error, "code.mcp #{id.inspect}: basic_auth unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      username = basic['username']
      password = basic['password']
      unless non_empty_string?(username) && password.is_a?(String)
        raise Error, "code.mcp #{id.inspect}: `basic_auth` needs a non-empty `username` and a `password` string"
      end

      "Basic #{["#{username}:#{password}"].pack('m0')}"
    end

    def self.default_llm
      Llm.new(name: DEFAULT_LLM_NAME, server: DEFAULT_SERVER, model: DEFAULT_MODEL, api_key: nil,
              context_window: nil)
    end

    # First non-nil value — precedence resolution that treats +false+ as a
    # real value (so a +sandbox = false+ in a file is not skipped).
    def self.pick(*values) = values.find { |v| !v.nil? }

    def self.check_unique!(values, label)
      dups = values.tally.select { |_, n| n > 1 }.keys
      raise Error, "duplicate #{label}(s): #{dups.join(', ')}" unless dups.empty?
    end

    def self.non_empty_string?(value) = value.is_a?(String) && !value.strip.empty?

    private_class_method :candidate_paths, :warn_loose_perms, :holds_secret?, :parse_file, :deep_merge,
                         :validate_top!, :validate_code!, :validate_ui!, :build_llm, :build_mcp, :build_mcp_headers,
                         :build_basic_auth, :build_mcp_env, :build_search, :default_llm,
                         :pick, :check_unique!, :non_empty_string?
  end
end
