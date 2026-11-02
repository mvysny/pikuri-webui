# frozen_string_literal: true

require 'tomlrb'

module PikuriWeb
  # The `~/.config/pikuri/config.toml` model connections and provider
  # keys, resolved once at boot and read from there on:
  #
  #   config = PikuriWeb::Config.load
  #   config.primary_llm   # => Llm(name:, server:, model:, api_key:, context_window:)
  #   config.servers       # => [Server(id:, url:, api_key:, max_concurrent_requests:)]
  #   config.search        # => Search(brave_key:, exa_key:, engines:)
  #
  # Every load failure — unreadable file, malformed TOML, schema
  # violation — raises {Error}, naming the offending key.
  #
  # == +[[server]]+ and +[[llm]]+
  #
  #   [[server]]
  #   id                      = "grok"
  #   url                     = "https://api.x.ai/v1"
  #   api_key                 = "xai-…"
  #   max_concurrent_requests = 4
  #
  #   [[llm]]
  #   name           = "Grok 4 Fast"
  #   server         = "grok"
  #   model          = "grok-4-fast"
  #   context_window = 131072
  #
  # The box and the model running on it are separate tables, so four models
  # on one provider state its URL and its key once instead of four times.
  # +id+ is referenced by machine, +name+ is shown to a person, and those two
  # are what {.load} checks for uniqueness. Two +[[server]]+ entries may
  # share a URL (two accounts on one provider), and an unreferenced
  # +[[server]]+ is legal, so commenting out an +[[llm]]+ cannot break the
  # file.
  #
  # {Llm#server} is the resolved *URL*; the +id+ leaves this class only in a
  # log line. An id means nothing away from the file that defines it, so a
  # conversation's saved connection stores the URL
  # (+D_per_conversation_model+) — a reference whose referent a later edit
  # can delete would strand it, where a URL stands on its own.
  #
  # There is no built-in connection: no +[[llm]]+ at all, one missing
  # +server+ or +model+, and one whose +server+ resolves to nothing each
  # raise {Error}. A silent fallback to a hardcoded model tag would be a
  # second, invisible connection source — so that knowledge is
  # {EXAMPLE_CONFIG}, quoted by the raise where the user can edit it.
  #
  # == The +[ui]+ table
  #
  #   [ui]
  #   show_thinking = false     # start with reasoning blocks collapsed
  #   tool_lines    = "verbose" # start on the raw argument dump
  #
  # Transcript density, one table for every pikuri shell because the
  # preference is per *person* far more than per shell. Both keys are read
  # here, as the *starting* value a browser with no preference of its own
  # sees: a `/thinking` or `/toollines` pick writes a cookie that outranks
  # the file from then on (+D_ui_cookie_over_config+).
  #
  # == The +[titler]+ table, and +[[llm]]+ +params+
  #
  #   [[llm]]
  #   name           = "qwen-titler"
  #   server         = "local"
  #   model          = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
  #   context_window = 8192
  #   params         = { chat_template_kwargs = { enable_thinking = false } }
  #
  #   [titler]
  #   llm = "qwen-titler"
  #
  # Which connection writes conversation titles, resolved into {#titler_llm}.
  # Naming a *name* is safe where +D_per_conversation_model+ forbids it,
  # because reference and referent live in one file, edited together. No
  # +[titler]+ leaves {#titler_llm} +nil+, which means *no titling* — never a
  # fallback to {#primary_llm}, whose thinking-on titles cost 30 s each.
  #
  # +params+ rides any +[[llm]]+, not only that one, and reaches the server
  # verbatim — a passthrough rather than a +thinking = false+ boolean, because
  # the wire spelling differs per provider *and* per chat template. Only the
  # shape is checked here; what the keys *mean* is the server's to say, the
  # same bargain {.build_search} takes with +engines+.
  #
  # == The +[web]+ table
  #
  #   [web]
  #   user     = "mavi"
  #   password = "a long passphrase"
  #
  # The one password gating the port, resolved into {#credentials}. No +[web]+
  # leaves it +nil+, which is no gate at all rather than a default password —
  # and one pair for everyone rather than accounts (+D_one_password_gate+).
  # Both keys are required once the table exists.
  #
  # == Precedence
  #
  # Lowest to highest: built-in defaults → +/etc/xdg/pikuri/config.toml+
  # (each +$XDG_CONFIG_DIRS+ entry, earlier = higher) →
  # +$XDG_CONFIG_HOME/pikuri/config.toml+ (default +~/.config+) →
  # +overrides:+. Tables merge key-by-key, so a system file can supply
  # +search.brave_key+ while the user file adds +exa_key+; arrays (the
  # +[[server]]+, +[[llm]]+ and +[[code.mcp]]+ lists) replace wholesale,
  # nearest file wins.
  #
  # +server+ references resolve *after* the whole merge. That is what lets a
  # user file add one +[[llm]]+ against a system file's +[[server]]+ instead
  # of re-pasting the block, secrets included — the duplication this schema
  # exists to remove. The consequence, since arrays replace: a nearer file
  # that declares +[[server]]+ at all replaces every farther one, which can
  # leave a farther file's +[[llm]]+ dangling. That raises; it never falls
  # back.
  #
  # No project-local layer, deliberately: a config file inside the repo
  # would be git-committable, and a literal {Llm#api_key} or {Search}
  # provider key must not live where a commit can carry it off.
  #
  # == Implementation details
  #
  # The schema is the *whole* pikuri-shell schema, not the subset this host
  # reads — {#sandbox}, {#confirm} and {#mcp} are validated and exposed
  # with nothing wired to them.
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

    # One inference server: what is true of the box rather than of a model
    # running on it, referenced by {#id} from any number of +[[llm]]+ entries
    # (the class header shows the pair of tables).
    #
    # @!attribute [r] id
    #   @return [String] unique reference an +[[llm]]+ names in its +server+
    #     key; never shown to the user, never stored anywhere outside this
    #     class (see the class header).
    # @!attribute [r] url
    #   @return [String] base URL, with or without the +/v1+ suffix — pikuri
    #     normalizes both the transport's base and the throttle's key by
    #     stripping it, so either spelling names one server.
    # @!attribute [r] api_key
    #   @return [String, nil] the API key/token, stored literally, or +nil+
    #     for a server that needs none (a local llama.cpp). This file rather
    #     than an env var on purpose: the environment is inherited by every
    #     subprocess pikuri spawns, so a key there leaks to code the agent
    #     runs.
    # @!attribute [r] max_concurrent_requests
    #   @return [Integer, nil] ceiling on requests in flight against this
    #     server, becoming a +Pikuri::Agent::ServerPermits+ limit, or +nil+ to
    #     let pikuri's +/props+ probe size it from the box's own
    #     +total_slots+. 1 is the recommended value and the probe's answer is
    #     usually not — see +D_max_concurrent_requests+.
    Server = Data.define(:id, :url, :api_key, :max_concurrent_requests)

    # One model connection: a +[[llm]]+ entry with its +[[server]]+ already
    # resolved into it, so nothing downstream has to hold the reference. The
    # first {Config#llms} entry is where a conversation with no saved
    # connection starts, and any of them is a +/model+ pick away.
    #
    # @!attribute [r] name
    #   @return [String] unique display name, e.g. +"Local Qwen 3.6"+.
    # @!attribute [r] server
    #   @return [String] the referenced {Server}'s {Server#url} — a base
    #     URL, never the +id+ the file wrote.
    # @!attribute [r] model
    #   @return [String] model identifier passed to the transport.
    # @!attribute [r] api_key
    #   @return [String, nil] the referenced {Server}'s {Server#api_key}, or
    #     +nil+ when that server omits it (the bin then falls back to
    #     +"not-needed"+, fine for a local llama.cpp).
    # @!attribute [r] context_window
    #   @return [Integer, nil] explicit context-window cap for this
    #     connection, or +nil+ to let pikuri auto-detect it (its llama.cpp
    #     +/props+ probe, which yields +nil+ for a non-llama server). Set
    #     it for a cloud model the probe can't reach so the status bar
    #     shows a real +used/cap+. Rides the connection's
    #     +Pikuri::Agent::ChatTransport+, so it stays correct per-model.
    # @!attribute [r] params
    #   @return [Hash{String => Object}] extra request parameters merged into
    #     every chat completion on this connection, verbatim — e.g.
    #     +{"chat_template_kwargs" => {"enable_thinking" => false}}+ to turn
    #     Qwen 3.6's reasoning off. Frozen, and +{}+ when the entry omits it,
    #     which is also how "the operator steered this connection" is read.
    Llm = Data.define(:name, :server, :model, :api_key, :context_window, :params) do
      # @param params [Hash{String => Object}] see {#params}; frozen here
      # @param rest [Hash{Symbol => Object}] the other members, by name
      def initialize(params: {}, **rest)
        super(params: params.freeze, **rest)
      end
    end

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
      # @param id [String] see {#id}
      # @param command [Array<String>, nil] see {#command}
      # @param url [String, nil] see {#url}
      # @param headers [Hash{String => String}] see {#headers}; frozen here
      # @param env [Hash{String => String}] see {#env}; frozen here
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
      # @param brave_key [String, nil] see {#brave_key}
      # @param exa_key [String, nil] see {#exa_key}
      # @param engines [Array<String>, nil] see {#engines}; frozen here
      def initialize(brave_key: nil, exa_key: nil, engines: nil)
        super(brave_key: brave_key, exa_key: exa_key, engines: engines&.freeze)
      end
    end

    # The +[web]+ table's pair, checked against the +Authorization+ header of
    # every request (+D_one_password_gate+).
    #
    # @!attribute [r] user
    #   @return [String] the name the browser's own prompt asks for.
    # @!attribute [r] password
    #   @return [String] the password, stored literally — the same file and the
    #     same +chmod 600+ advisory a +[[server]]+ api_key earns.
    Credentials = Data.define(:user, :password)

    # The smallest file that boots — a local llama.cpp. Every "no connection
    # configured" raise quotes it, so a first run ends in a block to paste
    # and edit rather than in a backtrace.
    #
    # @return [String] a paste-ready +config.toml+, newline-terminated.
    EXAMPLE_CONFIG = <<~TOML
      [[server]]
      id  = "local"
      url = "http://localhost:8080"

      [[llm]]
      name   = "Local Qwen 3.6"
      server = "local"
      model  = "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M"
    TOML

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
    #
    # @return [String]
    FILENAME   = 'config.toml'
    # @return [String]
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
    # @raise [Error] on an unreadable / malformed / schema-invalid file, and
    #   when the merged result defines no +[[llm]]+ — the message then quotes
    #   {EXAMPLE_CONFIG} and the path to write it to.
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
      validate_top!(merged)

      servers = (merged['server'] || []).each_with_index.map { |h, i| build_server(h, i) }
      check_unique!(servers.map(&:id), 'server id')

      llm_tables = merged['llm'] || []
      raise Error, no_connection_message(any_loaded, env) if llm_tables.empty?

      by_id = servers.to_h { |s| [s.id, s] }
      llms = llm_tables.each_with_index.map { |h, i| build_llm(h, i, by_id) }
      check_unique!(llms.map(&:name), 'llm name')

      code = merged['code'] || {}
      validate_code!(code)
      mcp = (code['mcp'] || []).each_with_index.map { |h, i| build_mcp(h, i) }
      check_unique!(mcp.map(&:id), 'code.mcp id')

      ui = merged['ui'] || {}
      validate_ui!(ui)

      new(
        llms:          llms,
        servers:       servers,
        titler_llm:    build_titler(merged['titler'], llms),
        credentials:   build_credentials(merged['web']),
        search:        build_search(merged['search']),
        sandbox:       pick(overrides[:sandbox], code['sandbox'], DEFAULT_SANDBOX),
        confirm:       pick(overrides[:confirm], code['confirm'], DEFAULT_CONFIRM),
        mcp:           mcp,
        show_thinking: pick(ui['show_thinking'], DEFAULT_SHOW_THINKING),
        tool_lines:    pick(ui['tool_lines']&.to_sym, DEFAULT_TOOL_LINES)
      )
    end

    # @param llms [Array<Llm>] one or more model connections (never empty).
    # @param servers [Array<Server>] the +[[server]]+ definitions +llms+ was
    #   resolved against. Defaults to empty because the only thing that reads
    #   it is the boot-time permit sizing, which a config built in code (a
    #   spec) has nothing to install.
    # @param search [Search] web-search provider keys (fields may be nil).
    # @param sandbox [Boolean] resolved sandbox switch (parsed, unwired).
    # @param confirm [Boolean] resolved confirmer switch (parsed, unwired).
    # @param mcp [Array<McpServer>] MCP servers (parsed, unwired; may be
    #   empty).
    # @param show_thinking [Boolean] resolved +[ui]+ reasoning-block default
    #   (parsed, unwired).
    # @param tool_lines [Symbol] resolved +[ui]+ tool-line form (parsed,
    #   unwired).
    # @param titler_llm [Llm, nil] the connection titles are written on, or
    #   +nil+ for no titling. Defaults to +nil+ so a config built in code
    #   opts in the same way a file does.
    # @param credentials [Credentials, nil] the +[web]+ pair gating the app, or
    #   +nil+ for no gate. Defaults to +nil+, as a file with no +[web]+ does.
    def initialize(llms:, search:, sandbox:, confirm:, mcp:, servers: [], titler_llm: nil, credentials: nil,
                   show_thinking: DEFAULT_SHOW_THINKING, tool_lines: DEFAULT_TOOL_LINES)
      @llms    = llms.freeze
      @servers = servers.freeze
      @search  = search
      @sandbox = sandbox
      @confirm = confirm
      @mcp     = mcp.freeze
      @titler_llm    = titler_llm
      @credentials   = credentials
      @show_thinking = show_thinking
      @tool_lines    = tool_lines
      freeze
    end

    # @return [Array<Llm>] all configured connections, declaration order;
    #   never empty.
    attr_reader :llms
    # @return [Array<Server>] every +[[server]]+, declaration order,
    #   including any that no +[[llm]]+ references.
    attr_reader :servers
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
    #   here unresolved. **The reader falls back**, as {Web::App} does for an
    #   unknown +theme+ cookie; the vocabulary belongs to whoever renders it.
    attr_reader :tool_lines
    # @return [Llm, nil] the connection conversation titles are written on
    #   (+[titler] llm+), or +nil+ when the file names none — which switches
    #   titling off rather than falling back to {#primary_llm}.
    attr_reader :titler_llm
    # @return [Credentials, nil] the +[web]+ pair gating every request, or
    #   +nil+ when the file names none — which switches the gate off rather
    #   than inventing a default password.
    attr_reader :credentials

    # @return [Llm] the boot connection (the first).
    def primary_llm = @llms.first

    # File layers, lowest priority first. +$XDG_CONFIG_DIRS+ (default
    # +/etc/xdg+) is +:+-separated with earlier entries ranking higher, so
    # we append them reversed; +$XDG_CONFIG_HOME+ (default +~/.config+)
    # outranks all of them. No project-local layer — see the class header.
    #
    # @param env [#[]] environment, for the +XDG_CONFIG_*+ variables
    # @return [Array<String>] candidate file paths, lowest priority first
    def self.candidate_paths(env)
      paths = []
      dirs = env['XDG_CONFIG_DIRS'].to_s.empty? ? '/etc/xdg' : env['XDG_CONFIG_DIRS']
      dirs.split(':').reverse_each { |d| paths << File.join(d, XDG_SUBDIR, FILENAME) }
      home = env['XDG_CONFIG_HOME'].to_s.empty? ? File.join(Dir.home, '.config') : env['XDG_CONFIG_HOME']
      paths << File.join(home, XDG_SUBDIR, FILENAME)
      paths
    end

    # Advise (non-fatally, through {PikuriWeb.logger}) when a file carrying
    # a literal secret (a +[[server]]+ api_key or a +[search]+ provider key)
    # is group/other-accessible — a plaintext secret should be +chmod 600+.
    # Only files that actually contain a secret are checked, so a
    # world-readable but secret-free /etc/xdg config raises no noise.
    #
    # @param path [String] the file +parsed+ came from
    # @param parsed [Hash{String => Object}] its raw TOML
    # @return [void]
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

    # Reads +[[server]]+ for the key, not +[[llm]]+: this check runs per file
    # and pre-merge, on raw TOML, so it sees the table the key is *written*
    # in rather than the {Llm} it is later resolved into.
    #
    # @param parsed [Hash{String => Object}] one file's raw TOML
    # @return [Boolean] true when the parsed file carries any literal secret
    #   (a +[[server]]+ +api_key+, a +[web]+ +password+, a +[search]+
    #   +brave_key+/+exa_key+, or an +[[code.mcp]]+
    #   +bearer_token+/+basic_auth+/+headers+/+env+).
    def self.holds_secret?(parsed)
      servers = parsed['server']
      return true if servers.is_a?(Array) && servers.any? { |e| e.is_a?(Hash) && e['api_key'] }

      web = parsed['web']
      return true if web.is_a?(Hash) && web['password']

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
    #
    # @param path [String] the file to read
    # @return [Hash{String => Object}] its raw TOML
    # @raise [Error] on a read failure or a TOML syntax error
    def self.parse_file(path)
      Tomlrb.parse(File.read(path))
    rescue StandardError => e
      raise Error, "failed to read config #{path}: #{e.class}: #{e.message}"
    end

    # Recursive merge: tables merge key-by-key; scalars and arrays take the
    # right-hand (higher-priority) value wholesale.
    #
    # @param lower [Hash{String => Object}] the lower-priority layer
    # @param higher [Hash{String => Object}] the higher-priority layer
    # @return [Hash{String => Object}] a new hash; neither input is changed
    def self.deep_merge(lower, higher)
      lower.merge(higher) do |_key, lo, hi|
        lo.is_a?(Hash) && hi.is_a?(Hash) ? deep_merge(lo, hi) : hi
      end
    end

    # @param merged [Hash{String => Object}] the merged raw TOML
    # @return [void]
    # @raise [Error] on an unknown top-level key or a table of the wrong shape
    def self.validate_top!(merged)
      unknown = merged.keys - %w[server llm search code ui titler web]
      raise Error, "unknown top-level key(s): #{unknown.join(', ')}" unless unknown.empty?
      %w[server llm].each do |k|
        next unless merged.key?(k) && !merged[k].is_a?(Array)

        raise Error, "`#{k}` must be an array of tables (use [[#{k}]], not [#{k}])"
      end
      if merged.key?('search') && !merged['search'].is_a?(Hash)
        raise Error, '`search` must be a table ([search])'
      end
      raise Error, '`code` must be a table ([code])' if merged.key?('code') && !merged['code'].is_a?(Hash)
      raise Error, '`ui` must be a table ([ui])' if merged.key?('ui') && !merged['ui'].is_a?(Hash)
      raise Error, '`web` must be a table ([web])' if merged.key?('web') && !merged['web'].is_a?(Hash)
      return unless merged.key?('titler') && !merged['titler'].is_a?(Hash)

      raise Error, '`titler` must be a table ([titler])'
    end

    # Resolve the +[web]+ table into the pair gating every request, or +nil+
    # when the file has no such section — the gate off, the way no +[titler]+
    # means no titling. Strict for the reason {.build_titler} is.
    #
    # Both keys are required together: a half-written table resolving to +nil+
    # would gate nothing and say nothing, which is the one failure this feature
    # cannot have.
    #
    # @param table [Hash, nil] the raw +[web]+ table.
    # @return [Credentials, nil] the pair, or +nil+ for +table+ +nil+.
    # @raise [Error] on an unknown key or a missing/blank +user+/+password+.
    def self.build_credentials(table)
      return nil if table.nil?

      unknown = table.keys - %w[user password]
      raise Error, "web: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      user     = table['user']
      password = table['password']
      unless non_empty_string?(user) && non_empty_string?(password)
        raise Error, 'web: `user` and `password` are both required and must be non-empty strings'
      end

      Credentials.new(user: user, password: password)
    end

    # Resolve +[titler] llm+ to the connection titles are written on.
    #
    # Strict, unlike +[ui]+: this shell is the one that consumes the table, so
    # a key it does not know is a mistake rather than a sibling shell's
    # business.
    #
    # @param table [Hash, nil] the raw +[titler]+ table; +nil+ when the file
    #   has no such section.
    # @param llms [Array<Llm>] every configured connection, names already
    #   checked for uniqueness.
    # @return [Llm, nil] the named connection, or +nil+ for +table+ +nil+ —
    #   titling off.
    # @raise [Error] on an unknown key, a missing or blank +llm+, or a name no
    #   +[[llm]]+ defines.
    def self.build_titler(table, llms)
      return nil if table.nil?

      unknown = table.keys - %w[llm]
      raise Error, "titler: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      ref = table['llm']
      unless non_empty_string?(ref)
        raise Error, 'titler.llm is required and must be a non-empty string naming an [[llm]]'
      end

      found = llms.find { |llm| llm.name == ref }
      return found if found

      raise Error, "titler.llm names no [[llm]]: #{ref.inspect}; " \
                   "known: #{llms.map { |llm| llm.name.inspect }.join(', ')}"
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
    #
    # @param table [Hash{String => Object}, nil] the raw +[search]+ table
    # @return [Search]
    # @raise [Error] on an unknown key or a value of the wrong shape
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

    # @param code [Hash{String => Object}] the raw +[code]+ table
    # @return [void]
    # @raise [Error] on an unknown key or a value of the wrong shape
    def self.validate_code!(code)
      unknown = code.keys - %w[sandbox confirm mcp]
      raise Error, "code: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?
      %w[sandbox confirm].each do |k|
        raise Error, "code.#{k} must be true or false" if code.key?(k) && ![true, false].include?(code[k])
      end
      return unless code.key?('mcp') && !code['mcp'].is_a?(Array)

      raise Error, 'code.mcp must be an array of tables (use [[code.mcp]])'
    end

    # @param hash [Object] one raw +[[server]]+ entry; anything but a table raises
    # @param index [Integer] its position, for error messages
    # @return [Server]
    # @raise [Error] on a malformed entry
    def self.build_server(hash, index)
      raise Error, "server[#{index}] must be a table" unless hash.is_a?(Hash)

      unknown = hash.keys - %w[id url api_key max_concurrent_requests]
      raise Error, "server[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      id = hash['id']
      raise Error, "server[#{index}]: `id` is required and must be a non-empty string" unless non_empty_string?(id)

      url = hash['url']
      raise Error, "server #{id.inspect}: `url` is required and must be a non-empty string" unless non_empty_string?(url)

      key = hash['api_key']
      raise Error, "server #{id.inspect}: `api_key` must be a string" if key && !key.is_a?(String)

      max = hash['max_concurrent_requests']
      if max && !(max.is_a?(Integer) && max.positive?)
        raise Error, "server #{id.inspect}: `max_concurrent_requests` must be a positive integer"
      end

      Server.new(id: id, url: url, api_key: key, max_concurrent_requests: max)
    end

    # @param hash [Object] one raw +[[llm]]+ entry; anything but a table raises
    # @param index [Integer] its position, for error messages
    # @param by_id [Hash{String => Server}] every {Server} the merged file
    #   defined
    # @return [Llm]
    # @raise [Error] on a malformed entry or an unresolvable +server+
    def self.build_llm(hash, index, by_id)
      raise Error, "llm[#{index}] must be a table" unless hash.is_a?(Hash)

      # +api_key+ is legal this far so that an old entry reaches the message
      # naming where the key moved to, rather than a bare "unknown key".
      unknown = hash.keys - %w[name server model api_key context_window params]
      raise Error, "llm[#{index}]: unknown key(s): #{unknown.join(', ')}" unless unknown.empty?

      name = hash['name']
      raise Error, "llm[#{index}]: `name` is required and must be a non-empty string" unless non_empty_string?(name)

      %w[server model].each do |k|
        next if non_empty_string?(hash[k])

        raise Error, "llm #{name.inspect}: `#{k}` is required and must be a non-empty string"
      end

      cw = hash['context_window']
      if cw && !(cw.is_a?(Integer) && cw.positive?)
        raise Error, "llm #{name.inspect}: `context_window` must be a positive integer"
      end

      params = hash.fetch('params', {})
      unless params.is_a?(Hash)
        raise Error, "llm #{name.inspect}: `params` must be a table, " \
                     'e.g. params = { chat_template_kwargs = { enable_thinking = false } }'
      end

      key = hash['api_key']
      server = resolve_server(hash['server'], name, by_id, key)
      raise Error, "llm #{name.inspect}: `api_key` belongs on [[server]] #{server.id.inspect}, not here." if key

      Llm.new(
        name:           name,
        server:         server.url,
        model:          hash['model'],
        api_key:        server.api_key, # nil when omitted → "not-needed" at the bin
        context_window: cw, # nil when omitted → pikuri auto-detects
        params:         params
      )
    end

    # Look up the +[[server]]+ an +[[llm]]+ names, raising a message that
    # names the fix when there is none.
    #
    # There is no compatibility path for a file written before +[[server]]+
    # existed, so each shape such a file fails in gets its own message — the
    # raise *is* the migration. A URL left in +server+ earns the most effort:
    # it parses cleanly and fails as a *lookup*, which reads like the user's
    # mistake rather than like a key whose meaning changed under them.
    #
    # @param ref [String] the +[[llm]]+ entry's +server+ value: an +id+ to
    #   look up, or, in an old file, a URL.
    # @param name [String] the entry's +name+, for error messages.
    # @param by_id [Hash{String => Server}] every {Server} the merged file
    #   defined.
    # @param api_key [String, nil] the entry's stray +api_key+, folded into
    #   the suggested block so one edit fixes both halves of an old file.
    # @return [Server] the referenced server.
    # @raise [Error] when +ref+ resolves to nothing.
    def self.resolve_server(ref, name, by_id, api_key)
      found = by_id[ref]
      return found if found

      raise Error, "llm #{name.inspect}: #{server_is_now_an_id(ref, api_key)}" if ref.include?('://')
      raise Error, "llm #{name.inspect}: no [[server]] is defined — add one:\n\n#{EXAMPLE_CONFIG}" if by_id.empty?

      raise Error, "llm #{name.inspect}: unknown server id #{ref.inspect}; " \
                   "known: #{by_id.keys.map(&:inspect).join(', ')}"
    end

    # @param url [String] the URL an old file left in an +[[llm]]+'s +server+
    # @param api_key [String, nil] that entry's stray +api_key+
    # @return [String] the migration advice, with a paste-ready +[[server]]+
    def self.server_is_now_an_id(url, api_key)
      block = +"[[server]]\nid  = \"myserver\"\nurl = #{url.inspect}\n"
      block << "api_key = #{api_key.inspect}\n" if api_key
      "`server` names a [[server]] `id` now, not a URL. Add:\n\n#{block}\n" \
        "and on this [[llm]] set `server = \"myserver\"`" \
        "#{api_key ? ', dropping its `api_key`.' : '.'}"
    end

    # Covers both "no config file at all" and "a file that defines no
    # connection" — the same hole with the same fix, so one message with the
    # path to write it to.
    #
    # @param any_loaded [Boolean] whether any file was read, which is the
    #   only difference between the two cases.
    # @param env [#[]] environment, for the path {.candidate_paths} names.
    # @return [String] the message, quoting {EXAMPLE_CONFIG}.
    def self.no_connection_message(any_loaded, env)
      opening = any_loaded ? 'no [[llm]] is defined' : 'no config file found'
      "#{opening}, and there is no built-in default connection. " \
        "Write #{candidate_paths(env).last}:\n\n#{EXAMPLE_CONFIG}"
    end

    # @param hash [Object] one raw +[[code.mcp]]+ entry; anything but a table
    #   raises
    # @param index [Integer] its position, for error messages
    # @return [McpServer]
    # @raise [Error] on a malformed entry
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

    # First non-nil value — precedence resolution that treats +false+ as a
    # real value (so a +sandbox = false+ in a file is not skipped).
    #
    # @param values [Array<Object>] candidates, highest priority first
    # @return [Object] the first non-nil one, or +nil+ when all are
    def self.pick(*values) = values.find { |v| !v.nil? }

    # @param values [Array<String>] the ids or names to check
    # @param label [String] what they are, for the error message
    # @return [void]
    # @raise [Error] naming every duplicate
    def self.check_unique!(values, label)
      dups = values.tally.select { |_, n| n > 1 }.keys
      raise Error, "duplicate #{label}(s): #{dups.join(', ')}" unless dups.empty?
    end

    # @param value [Object] a raw TOML value
    # @return [Boolean] whether it is a string with a non-blank character
    def self.non_empty_string?(value) = value.is_a?(String) && !value.strip.empty?

    private_class_method :candidate_paths, :warn_loose_perms, :holds_secret?, :parse_file, :deep_merge,
                         :validate_top!, :validate_code!, :validate_ui!, :build_server, :build_llm,
                         :resolve_server, :server_is_now_an_id, :no_connection_message,
                         :build_mcp, :build_mcp_headers, :build_credentials,
                         :build_basic_auth, :build_mcp_env, :build_search,
                         :pick, :check_unique!, :non_empty_string?
  end
end
