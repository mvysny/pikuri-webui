# frozen_string_literal: true

require 'tomlrb'
require 'typemap'

module PikuriWebUI
  # The `~/.config/pikuri/config.toml` model connections and provider
  # keys, resolved once at boot and read from there on:
  #
  #   config = PikuriWebUI::Config.load
  #   config.primary_llm   # => Llm(name:, server:, model:, api_key:, context_window:)
  #   config.servers       # => [Server(id:, url:, api_key:, max_concurrent_requests:)]
  #   config.search        # => Search(brave_key:, exa_key:, engines:)
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
  # pikuri-tui owns what grows in this table, so it is the one table that is
  # lenient: {UiTable} says +unknown :ignore+, so Typemap drops a key this
  # shell does not read, silently, and +tool_lines+ is checked to be a String,
  # never against a list of forms (+D_schema_complete_config+).
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
  # same bargain {Search#engines} takes.
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
  # == Errors
  #
  # Every load failure — unreadable file, malformed TOML, schema violation —
  # raises {Error}. A schema message starts with the offending value's path,
  # an array entry named after its index by its +entry_name+:
  #
  #   llm[1] "Grok 4 Fast".context_window: must be at least 1, got 0
  #   server: expected Array[Server], got a single Server; write [[server]], not [server]
  #
  # == Implementation details
  #
  # Typemap maps the merged TOML onto {Root} and the classes nested in it,
  # checking every value against the type its YARD tag gives — read back at
  # runtime from +sig/pikuri_webui.rbs+, which +rake sig+ generates, so a stale
  # +sig/+ means stale config types (+D_config_through_typemap+). Typemap's
  # limits add non-blank names and unique ids; a class's +validate+ keeps
  # only what no limit can say, "exactly one of +command+ / +url+" and the
  # like. {.load} then resolves the file's shape
  # into the values the app reads: each {LlmTable} with its {Server} looked up
  # becomes an {Llm}, each {McpTable} with its auth sugar folded into
  # +headers+ becomes an {McpServer}. {Server}, {Search} and {Credentials}
  # already match the file and pass through.
  #
  # The schema is the *whole* pikuri-shell schema, not the subset this host
  # reads — {#sandbox}, {#confirm} and {#mcp} are validated and exposed
  # with nothing wired to them. Trimming it would break the file: pikuri-tui
  # writes +[code]+ / +[[code.mcp]]+ / +[ui]+ into the same path, and an
  # unknown top-level key raises.
  #
  # Names no +Pikuri::*+ constant, so it sits on the Pikuri-free side of
  # the seam (AGENTS.md). {Llm}'s fields match
  # +ChatTransport.from_openai_server+'s keyword arguments, {Search}'s
  # match +Tool::WebSearch.build+'s and {McpServer}'s match
  # +Mcp::Registry+'s entries, which keeps the bin's translation a
  # pass-through.
  #
  # Immutable.
  class Config
    # Raised for any unreadable / malformed / schema-invalid config file.
    # Carries a human-readable message naming the offending key or file.
    class Error < StandardError; end

    # @return [Boolean] sandbox on unless a file says otherwise.
    DEFAULT_SANDBOX = true
    # @return [Boolean] confirm on unless a file says otherwise.
    DEFAULT_CONFIRM = true
    # @return [Boolean] reasoning blocks are shown unless +[ui]+ says otherwise.
    DEFAULT_SHOW_THINKING = true
    # @return [Symbol] the tool-line form to start on. Matches pikuri-tui's
    #   default so one file means one look in both shells.
    DEFAULT_TOOL_LINES = :short

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
    Server = Data.define(:id, :url, :api_key, :max_concurrent_requests) do
      extend Typemap::Constrain

      constrain :id, :url, not_blank: true
      constrain :max_concurrent_requests, in: (1..)

      # @param id [String] see {#id}
      # @param url [String] see {#url}
      # @param api_key [String, nil] see {#api_key}
      # @param max_concurrent_requests [Integer, nil] see {#max_concurrent_requests}
      def initialize(id:, url:, api_key: nil, max_concurrent_requests: nil) = super

      # Names the entry in a schema error, +server[1] "grok".url: required+.
      #
      # @param raw [Hash{String => Object}] the entry as the file wrote it, unchecked
      # @return [Object] its +id+, which Typemap strips; a blank or missing one
      #   leaves the bare index
      def self.entry_name(raw) = raw['id']
    end

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
    # fields: {McpTable#resolve} folds them into {#headers}, so this exposes
    # only the one hash +Registry::HttpEntry+ consumes 1:1.
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
    #     or an engine named without its key is pikuri's refusal, so no engine
    #     list here can rot.
    Search = Data.define(:brave_key, :exa_key, :engines) do
      # @param brave_key [String, nil] see {#brave_key}
      # @param exa_key [String, nil] see {#exa_key}
      # @param engines [Array<String>, nil] see {#engines}; frozen here
      def initialize(brave_key: nil, exa_key: nil, engines: nil)
        super(brave_key: brave_key, exa_key: exa_key, engines: engines&.freeze)
      end
    end

    # The +[web]+ table's pair, checked against the +Authorization+ header of
    # every request (+D_one_password_gate+). Both keys are required: a
    # half-written table resolving to no gate would gate nothing and say
    # nothing.
    #
    # @!attribute [r] user
    #   @return [String] the name the browser's own prompt asks for; non-blank.
    # @!attribute [r] password
    #   @return [String] the password, stored literally — the same file and the
    #     same +chmod 600+ advisory a +[[server]]+ api_key earns; non-blank.
    Credentials = Data.define(:user, :password) do
      extend Typemap::Constrain

      constrain :user, :password, not_blank: true
    end

    # One +[[llm]]+ table as the file writes it; {.load} resolves it into an {Llm}.
    #
    # @!attribute [r] name
    #   @return [String] see {Llm#name}
    # @!attribute [r] server
    #   @return [String] the {Server#id} this model runs on
    # @!attribute [r] model
    #   @return [String] see {Llm#model}
    # @!attribute [r] api_key
    #   @return [String, nil] never valid here: read only so {.load} can name the
    #     +[[server]]+ it belongs on, where an unknown-key error would not
    # @!attribute [r] context_window
    #   @return [Integer, nil] see {Llm#context_window}
    # @!attribute [r] params
    #   @return [Hash{String => Object}] see {Llm#params}; checked to be a table,
    #     its contents the server's business
    LlmTable = Data.define(:name, :server, :model, :api_key, :context_window, :params) do
      extend Typemap::Constrain

      constrain :name, :server, :model, not_blank: true
      constrain :context_window, in: (1..)

      # @param name [String] see {#name}
      # @param server [String] see {#server}
      # @param model [String] see {#model}
      # @param api_key [String, nil] see {#api_key}
      # @param context_window [Integer, nil] see {#context_window}
      # @param params [Hash{String => Object}] see {#params}
      def initialize(name:, server:, model:, api_key: nil, context_window: nil, params: {}) = super

      # @param raw [Hash{String => Object}] see {Server.entry_name}
      # @return [Object] its +name+
      def self.entry_name(raw) = raw['name']
    end

    # A +[[code.mcp]]+ entry's +basic_auth+ table.
    #
    # @!attribute [r] username
    #   @return [String] non-blank
    # @!attribute [r] password
    #   @return [String]
    BasicAuth = Data.define(:username, :password) do
      extend Typemap::Constrain

      constrain :username, not_blank: true

      # @return [String] the +Authorization+ value, strict (newline-free) Base64
      #   through +Array#pack+, so no +base64+ require
      def header = "Basic #{["#{username}:#{password}"].pack('m0')}"
    end

    # One +[[code.mcp]]+ table as the file writes it; {#resolve} turns it into
    # an {McpServer}.
    #
    # +bearer_token+ and +basic_auth+ are sugar for an +Authorization+ header,
    # so they exclude each other and an +Authorization+ entry in +headers+.
    #
    # @!attribute [r] id
    #   @return [String] see {McpServer#id}
    # @!attribute [r] command
    #   @return [Array<String>, nil] see {McpServer#command}
    # @!attribute [r] url
    #   @return [String, nil] see {McpServer#url}
    # @!attribute [r] bearer_token
    #   @return [String, nil] becomes +Authorization: Bearer …+
    # @!attribute [r] basic_auth
    #   @return [BasicAuth, nil] becomes +Authorization: Basic …+
    # @!attribute [r] headers
    #   @return [Hash{String => String}, nil] extra HTTP headers, sent verbatim
    # @!attribute [r] env
    #   @return [Hash{String => String}, nil] see {McpServer#env}
    McpTable = Data.define(:id, :command, :url, :bearer_token, :basic_auth, :headers, :env) do
      extend Typemap::Constrain

      constrain :id, :url, :bearer_token, not_blank: true
      constrain :command, not_empty: true

      # @param id [String] see {#id}
      # @param command [Array<String>, nil] see {#command}
      # @param url [String, nil] see {#url}
      # @param bearer_token [String, nil] see {#bearer_token}
      # @param basic_auth [BasicAuth, nil] see {#basic_auth}
      # @param headers [Hash{String => String}, nil] see {#headers}
      # @param env [Hash{String => String}, nil] see {#env}
      def initialize(id:, command: nil, url: nil, bearer_token: nil, basic_auth: nil, headers: nil, env: nil) = super

      # @param raw [Hash{String => Object}] see {Server.entry_name}
      # @return [Object] its +id+
      def self.entry_name(raw) = raw['id']

      # @return [void]
      # @raise [RuntimeError] on a stdio/HTTP mix-up, or two sources for
      #   +Authorization+
      def validate
        raise 'set exactly one of `command` (stdio) or `url` (http)' unless command.nil? ^ url.nil?

        http_only = { bearer_token:, basic_auth:, headers: }.compact.keys
        if command && !http_only.empty?
          raise "#{http_only.map { |k| "`#{k}`" }.join(', ')} apply only to HTTP servers (set `url`, not `command`)"
        end
        raise '`env` applies only to stdio servers (set `command`, not `url`)' if url && env
        raise 'set at most one of `bearer_token` or `basic_auth`' if bearer_token && basic_auth
        return unless (bearer_token || basic_auth) && headers&.keys&.any? { |k| k.casecmp?('Authorization') }

        raise '`bearer_token`/`basic_auth` conflicts with an `Authorization` entry in `headers` — set only one'
      end

      # @return [McpServer] this entry with its auth sugar folded into +headers+
      def resolve
        auth = bearer_token ? "Bearer #{bearer_token}" : basic_auth&.header
        all_headers = headers || {}
        all_headers = all_headers.merge('Authorization' => auth) if auth
        McpServer.new(id:, command:, url:, headers: all_headers, env: env || {})
      end
    end

    # The +[code]+ table.
    #
    # @!attribute [r] sandbox
    #   @return [Boolean] see {Config#sandbox}; +overrides:+ outrank it
    # @!attribute [r] confirm
    #   @return [Boolean] see {Config#confirm}; +overrides:+ outrank it
    # @!attribute [r] mcp
    #   @return [Array<McpTable>] the +[[code.mcp]]+ entries, ids unique
    CodeTable = Data.define(:sandbox, :confirm, :mcp) do
      extend Typemap::Constrain

      constrain :mcp, unique_by: :id

      # @param sandbox [Boolean] see {#sandbox}
      # @param confirm [Boolean] see {#confirm}
      # @param mcp [Array<McpTable>] see {#mcp}
      def initialize(sandbox: DEFAULT_SANDBOX, confirm: DEFAULT_CONFIRM, mcp: []) = super
    end

    # The +[ui]+ table; a key it has no member for is dropped, never raised
    # on, so one pikuri-tui adds cannot stop this shell from booting (the
    # class header has the why).
    #
    # @!attribute [r] show_thinking
    #   @return [Boolean] see {Config#show_thinking}
    # @!attribute [r] tool_lines
    #   @return [String] see {Config#tool_lines}; any String, its vocabulary
    #     being pikuri-tui's
    UiTable = Data.define(:show_thinking, :tool_lines) do
      extend Typemap::Constrain

      unknown :ignore

      # @param show_thinking [Boolean] see {#show_thinking}
      # @param tool_lines [String] see {#tool_lines}
      def initialize(show_thinking: DEFAULT_SHOW_THINKING, tool_lines: DEFAULT_TOOL_LINES.to_s) = super
    end

    # The +[titler]+ table.
    #
    # @!attribute [r] llm
    #   @return [String] the {Llm#name} titles are written on; non-blank
    TitlerTable = Data.define(:llm) do
      extend Typemap::Constrain

      constrain :llm, not_blank: true
    end

    # The whole file, every table at its default when the file leaves it out.
    #
    # @!attribute [r] server
    #   @return [Array<Server>] the +[[server]]+ entries, ids unique
    # @!attribute [r] llm
    #   @return [Array<LlmTable>] the +[[llm]]+ entries, names unique
    # @!attribute [r] search
    #   @return [Search] the +[search]+ table
    # @!attribute [r] code
    #   @return [CodeTable] the +[code]+ table
    # @!attribute [r] ui
    #   @return [UiTable] the +[ui]+ table
    # @!attribute [r] titler
    #   @return [TitlerTable, nil] the +[titler]+ table; +nil+ switches titling off
    # @!attribute [r] web
    #   @return [Credentials, nil] the +[web]+ table; +nil+ switches the gate off
    Root = Data.define(:server, :llm, :search, :code, :ui, :titler, :web) do
      extend Typemap::Constrain

      constrain :server, unique_by: :id
      constrain :llm, unique_by: :name

      # @param server [Array<Server>] see {#server}
      # @param llm [Array<LlmTable>] see {#llm}
      # @param search [Search] see {#search}
      # @param code [CodeTable] see {#code}
      # @param ui [UiTable] see {#ui}
      # @param titler [TitlerTable, nil] see {#titler}
      # @param web [Credentials, nil] see {#web}
      def initialize(server: [], llm: [], search: Search.new, code: CodeTable.new, ui: UiTable.new,
                     titler: nil, web: nil)
        super
      end
    end

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

    # Config file basename and the per-app subdirectory under each XDG
    # config root. Shared verbatim with pikuri-tui — same file.
    #
    # @return [String]
    FILENAME   = 'config.toml'
    # @return [String]
    XDG_SUBDIR = 'pikuri'

    # Types come from sig/ (the YARD tags, through sord), so each is written once.
    #
    # @return [Typemap::Mapper]
    MAPPER = Typemap::Mapper.new(types: Typemap::Mapper::RBSTypes.new)
    private_constant :MAPPER

    # Load and resolve the layered configuration.
    #
    # @param overrides [Hash{Symbol => Boolean, nil}] CLI overrides; +nil+
    #   values are ignored (treated as "flag not given"). Recognized keys:
    #   +:sandbox+, +:confirm+ — the coding switches, for a sibling shell that
    #   wires them (`D_chat_only_entry_point`). Nothing about a *connection*
    #   is overridable: no server, no model and no key. A secret must never
    #   travel on the command line (visible in +ps+ and shell history), and
    #   server/model would be a second source of truth for something the file
    #   already owns (`D_schema_complete_config`).
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
        PikuriWebUI.logger.info("config: loaded #{path}")
        any_loaded = true
        warn_loose_perms(path, parsed)
        merged = deep_merge(merged, parsed)
      end

      root = map(merged)
      raise Error, no_connection_message(any_loaded, env) if root.llm.empty?

      by_id = root.server.to_h { |s| [s.id, s] }
      llms = root.llm.map { |table| resolve_llm(table, by_id) }
      new(
        llms:          llms,
        servers:       root.server,
        titler_llm:    root.titler && resolve_titler(root.titler, llms),
        credentials:   root.web,
        search:        root.search,
        sandbox:       overrides[:sandbox].nil? ? root.code.sandbox : overrides[:sandbox],
        confirm:       overrides[:confirm].nil? ? root.code.confirm : overrides[:confirm],
        mcp:           root.code.mcp.map(&:resolve),
        show_thinking: root.ui.show_thinking,
        tool_lines:    root.ui.tool_lines.to_sym
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
    # @param show_thinking [Boolean] resolved +[ui]+ reasoning-block default.
    # @param tool_lines [Symbol] resolved +[ui]+ tool-line form.
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

    # Advise (non-fatally, through {PikuriWebUI.logger}) when a file carrying
    # a literal secret is group/other-accessible — a plaintext secret should
    # be +chmod 600+. Only files that actually contain a secret are checked,
    # so a world-readable but secret-free /etc/xdg config raises no noise.
    #
    # @param path [String] the file +parsed+ came from
    # @param parsed [Hash{String => Object}] its raw TOML
    # @return [void]
    def self.warn_loose_perms(path, parsed)
      return unless holds_secret?(parsed)

      mode = File.stat(path).mode
      return if (mode & 0o077).zero?

      PikuriWebUI.logger.warn(
        "config: #{path} holds a literal secret but is group/other-accessible " \
        "(mode #{format('%04o', mode & 0o7777)}); run `chmod 600 #{path}`."
      )
    rescue SystemCallError => e
      # A race or an odd filesystem: the advisory is a courtesy, never fatal.
      PikuriWebUI.logger.debug("config: skipped the permissions check of #{path}: #{e.message}")
    end

    # Reads +[[server]]+ for the key, not +[[llm]]+: this check runs per file
    # and pre-merge, on raw TOML the schema has not checked yet, so it sees
    # the table the key is *written* in and must not assume any table's shape.
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

      code = parsed['code']
      mcp = code['mcp'] if code.is_a?(Hash)
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

    # @param merged [Hash{String => Object}] the merged TOML
    # @return [Root]
    # @raise [Error] on any schema violation, its message starting with the
    #   offending value's path
    def self.map(merged)
      MAPPER.load(Root, merged, source: :toml)
    rescue Typemap::DataError => e
      raise Error, e.message
    end

    # @param table [LlmTable] one +[[llm]]+ entry
    # @param by_id [Hash{String => Server}] every +[[server]]+, by id — the
    #   whole layered set, not just the file the entry was written in
    # @return [Llm]
    # @raise [Error] on a +server+ that resolves to nothing, or a stray +api_key+
    def self.resolve_llm(table, by_id)
      server = resolve_server(table.server, table.name, by_id, table.api_key)
      if table.api_key
        raise Error, "llm #{table.name.inspect}: `api_key` belongs on [[server]] #{server.id.inspect}, not here."
      end

      Llm.new(
        name:           table.name,
        server:         server.url,
        model:          table.model,
        api_key:        server.api_key, # nil when omitted → "not-needed" at the bin
        context_window: table.context_window, # nil when omitted → pikuri auto-detects
        params:         table.params
      )
    end

    # Each way a reference can fail gets its own message, since with no compat
    # path the raise *is* the whole migration. A URL in +server+ earns the most
    # effort: it parses cleanly and fails as a *lookup*, which reads like the
    # user's mistake rather than a key whose meaning changed. The entry's stray
    # +api_key+ rides along into the suggested block, so one edit fixes both
    # halves of an old file instead of two round trips.
    #
    # @param ref [String] the entry's +server+ value
    # @param name [String] the entry's +name+, for messages
    # @param by_id [Hash{String => Server}] every +[[server]]+, by id
    # @param api_key [String, nil] the entry's stray +api_key+, quoted in the migration hint
    # @return [Server] the referenced server
    # @raise [Error] when +ref+ names no server
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
        'and on this [[llm]] set `server = "myserver"`' \
        "#{api_key ? ', dropping its `api_key`.' : '.'}"
    end

    # @param table [TitlerTable] the +[titler]+ table
    # @param llms [Array<Llm>] every configured connection, names already
    #   checked for uniqueness.
    # @return [Llm] the connection +table+ names
    # @raise [Error] on a name no +[[llm]]+ defines
    def self.resolve_titler(table, llms)
      found = llms.find { |llm| llm.name == table.llm }
      return found if found

      raise Error, "titler.llm names no [[llm]]: #{table.llm.inspect}; " \
                   "known: #{llms.map { |llm| llm.name.inspect }.join(', ')}"
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

    private_class_method :candidate_paths, :warn_loose_perms, :holds_secret?, :parse_file, :deep_merge,
                         :map, :resolve_llm, :resolve_server, :server_is_now_an_id,
                         :resolve_titler, :no_connection_message
  end
end
