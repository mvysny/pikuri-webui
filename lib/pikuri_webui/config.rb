# frozen_string_literal: true

require 'tomlrb'
require 'typemap'

module PikuriWebUI
  # This shell's own `~/.config/pikuri-webui/config.toml` — model connections,
  # provider keys and how the port faces the network — resolved once at boot
  # and read from there on:
  #
  #   config = PikuriWebUI::Config.load
  #   config.primary_llm   # => Llm(name:, server:, model:, api_key:, context_window:)
  #   config.servers       # => [Server(id:, url:, api_key:, max_concurrent_requests:)]
  #   config.search        # => Search(brave_key:, exa_key:, engines:)
  #   config.base_path     # => "/pikuri-webui", or "" at the root
  #
  # The file carries what this shell reads and nothing else, strict
  # throughout: an unknown key anywhere raises. pikuri-tui keeps its own file
  # under +~/.config/pikuri/+, so a key one shell grows never stops the other
  # from booting (+D_own_config_file+).
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
  # Both keys are the *starting* value a browser with no preference of its
  # own sees: a `/thinking` or `/toollines` pick writes a cookie that
  # outranks the file from then on (+D_ui_cookie_over_config+).
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
  #   base_path = "/pikuri-webui"   # served at https://host/pikuri-webui/
  #   user      = "mavi"            # these two together, or neither
  #   password  = "a long passphrase"
  #
  # How the port faces the network; every key is optional. +base_path+
  # becomes {#base_path}, the path every URL the shell serves sits under
  # (+D_base_path_mount+). +user+ and +password+ become {#credentials}, the
  # one pair gating the port — none of them leaves it +nil+, which is no gate
  # at all rather than a default password, and one pair for everyone rather
  # than accounts (+D_one_password_gate+).
  #
  # == Precedence
  #
  # Lowest to highest: built-in defaults → +/etc/xdg/pikuri-webui/config.toml+
  # (each +$XDG_CONFIG_DIRS+ entry, earlier = higher) →
  # +$XDG_CONFIG_HOME/pikuri-webui/config.toml+ (default +~/.config+). Tables
  # merge key-by-key, so a system file can supply +search.brave_key+ while the
  # user file adds +exa_key+; arrays (the +[[server]]+ and +[[llm]]+ lists)
  # replace wholesale, nearest file wins.
  #
  # +server+ references resolve *after* the whole merge. That is what lets a
  # user file add one +[[llm]]+ against a system file's +[[server]]+ instead
  # of re-pasting the block, secrets included. The consequence, since arrays
  # replace: a nearer file that declares +[[server]]+ at all replaces every
  # farther one, which can leave a farther file's +[[llm]]+ dangling. That
  # raises; it never falls back.
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
  # only what no limit can say, "both or neither" and the like. {.load} then
  # resolves the file's shape into the values the app reads: each {LlmTable}
  # with its {Server} looked up becomes an {Llm}, and the {WebTable} splits
  # into {#base_path} and {#credentials}. {Server} and {Search} already match
  # the file and pass through.
  #
  # Names no +Pikuri::*+ constant, so it sits on the Pikuri-free side of
  # the seam (AGENTS.md). {Llm}'s fields match
  # +ChatTransport.from_openai_server+'s keyword arguments and {Search}'s
  # match +Pikuri::Web::Search.build+'s, which keeps the bin's translation a
  # pass-through.
  #
  # Immutable.
  class Config
    # Raised for any unreadable / malformed / schema-invalid config file.
    # Carries a human-readable message naming the offending key or file.
    class Error < StandardError; end

    # @return [Boolean] reasoning blocks are shown unless +[ui]+ says otherwise.
    DEFAULT_SHOW_THINKING = true
    # @return [Symbol] the tool-line form to start on.
    DEFAULT_TOOL_LINES = :short
    # The forms +[ui] tool_lines+ may name: the two +style.css+ can show, the
    # same pair {Web::App::TOOL_LINES} checks a cookie against.
    #
    # @return [Array<String>]
    TOOL_LINES = %w[short verbose].freeze

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
    #     server, becoming a +Pikuri::Conversations::Throttle+ limit, or +nil+ to
    #     let pikuri-conversations' +/props+ probe size it from the box's own
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
    #     connection, or +nil+ to let pikuri-conversations learn it (its llama.cpp
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
    # every request (+D_one_password_gate+).
    #
    # @!attribute [r] user
    #   @return [String] the name the browser's own prompt asks for; non-blank.
    # @!attribute [r] password
    #   @return [String] the password, stored literally — the same file and the
    #     same +chmod 600+ advisory a +[[server]]+ api_key earns; non-blank.
    Credentials = Data.define(:user, :password)

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

    # The +[ui]+ table.
    #
    # @!attribute [r] show_thinking
    #   @return [Boolean] see {Config#show_thinking}
    # @!attribute [r] tool_lines
    #   @return [String] see {Config#tool_lines}; one of {TOOL_LINES}
    UiTable = Data.define(:show_thinking, :tool_lines) do
      extend Typemap::Constrain

      constrain :tool_lines, in: TOOL_LINES

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

    # The +[web]+ table as the file writes it; {.load} splits it into
    # {Config#base_path} and {Config#credentials}.
    #
    # @!attribute [r] base_path
    #   @return [String, nil] see {Config#base_path}; as written, a trailing
    #     +/+ included
    # @!attribute [r] user
    #   @return [String, nil] see {Credentials#user}
    # @!attribute [r] password
    #   @return [String, nil] see {Credentials#password}
    WebTable = Data.define(:base_path, :user, :password) do
      extend Typemap::Constrain

      constrain :user, :password, not_blank: true

      # @param base_path [String, nil] see {#base_path}
      # @param user [String, nil] see {#user}
      # @param password [String, nil] see {#password}
      def initialize(base_path: nil, user: nil, password: nil) = super

      # A half-written pair raises rather than gating nothing in silence.
      # +base_path+ lands in a cookie's +Path+ and in every URL the page
      # builds, so it takes unreserved characters only, with no +.+ or +..+
      # segment and no empty one.
      #
      # @return [void]
      # @raise [RuntimeError] on a lone +user+ or +password+, or a malformed
      #   +base_path+
      def validate
        raise 'set `user` and `password` together, or neither' if user.nil? ^ password.nil?
        return if base_path.nil?

        segments = base_path.delete_suffix('/').split('/', -1).drop(1)
        return if base_path.start_with?('/') && segments.none? { |s| %w[. ..].include?(s) || !s.match?(SEGMENT) }

        raise '`base_path` must be an absolute path such as "/pikuri-webui" — letters, digits ' \
              "and . _ ~ - between the slashes — got #{base_path.inspect}"
      end
    end

    # One +base_path+ segment: RFC 3986's unreserved characters, nothing to
    # escape in a URL, a cookie +Path+ or an HTML attribute.
    #
    # @return [Regexp]
    SEGMENT = /\A[A-Za-z0-9._~-]+\z/
    private_constant :SEGMENT

    # The whole file, every table at its default when the file leaves it out.
    #
    # @!attribute [r] server
    #   @return [Array<Server>] the +[[server]]+ entries, ids unique
    # @!attribute [r] llm
    #   @return [Array<LlmTable>] the +[[llm]]+ entries, names unique
    # @!attribute [r] search
    #   @return [Search] the +[search]+ table
    # @!attribute [r] ui
    #   @return [UiTable] the +[ui]+ table
    # @!attribute [r] titler
    #   @return [TitlerTable, nil] the +[titler]+ table; +nil+ switches titling off
    # @!attribute [r] web
    #   @return [WebTable] the +[web]+ table
    Root = Data.define(:server, :llm, :search, :ui, :titler, :web) do
      extend Typemap::Constrain

      constrain :server, unique_by: :id
      constrain :llm, unique_by: :name

      # @param server [Array<Server>] see {#server}
      # @param llm [Array<LlmTable>] see {#llm}
      # @param search [Search] see {#search}
      # @param ui [UiTable] see {#ui}
      # @param titler [TitlerTable, nil] see {#titler}
      # @param web [WebTable] see {#web}
      def initialize(server: [], llm: [], search: Search.new, ui: UiTable.new, titler: nil, web: WebTable.new)
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
    # config root.
    #
    # @return [String]
    FILENAME   = 'config.toml'
    # @return [String]
    XDG_SUBDIR = 'pikuri-webui'
    # Where this shell's file lived while it shared pikuri-tui's: never read,
    # only named by the no-connection raise when it is there, since that raise
    # is the whole migration.
    #
    # @return [String]
    PIKURI_TUI_SUBDIR = 'pikuri'

    # Types come from sig/ (the YARD tags, through sord), so each is written once.
    #
    # @return [Typemap::Mapper]
    MAPPER = Typemap::Mapper.new(types: Typemap::Mapper::RBSTypes.new)
    private_constant :MAPPER

    # Load and resolve the layered configuration. Nothing is overridable from
    # the command line: a secret there is visible in +ps+ and shell history,
    # and anything else would be a second source for what the file owns
    # (`D_own_config_file`).
    #
    # @param env [#[]] environment consulted for +XDG_CONFIG_HOME+ /
    #   +XDG_CONFIG_DIRS+. Defaults to +ENV+; injectable for tests.
    # @return [Config] the resolved configuration.
    # @raise [Error] on an unreadable / malformed / schema-invalid file, and
    #   when the merged result defines no +[[llm]]+ — the message then quotes
    #   {EXAMPLE_CONFIG} and the path to write it to.
    def self.load(env: ENV)
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
      web = root.web
      new(
        llms:          llms,
        servers:       root.server,
        titler_llm:    root.titler && resolve_titler(root.titler, llms),
        credentials:   web.user && Credentials.new(user: web.user, password: web.password),
        base_path:     web.base_path.to_s.delete_suffix('/'),
        search:        root.search,
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
    # @param show_thinking [Boolean] resolved +[ui]+ reasoning-block default.
    # @param tool_lines [Symbol] resolved +[ui]+ tool-line form.
    # @param titler_llm [Llm, nil] the connection titles are written on, or
    #   +nil+ for no titling. Defaults to +nil+ so a config built in code
    #   opts in the same way a file does.
    # @param credentials [Credentials, nil] the +[web]+ pair gating the app, or
    #   +nil+ for no gate. Defaults to +nil+, as a file with no pair does.
    # @param base_path [String] see {#base_path}; +""+ for the root.
    def initialize(llms:, search:, servers: [], titler_llm: nil, credentials: nil, base_path: '',
                   show_thinking: DEFAULT_SHOW_THINKING, tool_lines: DEFAULT_TOOL_LINES)
      @llms    = llms.freeze
      @servers = servers.freeze
      @search  = search
      @titler_llm    = titler_llm
      @credentials   = credentials
      @base_path     = base_path
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
    # @return [Boolean] whether reasoning blocks start shown (+[ui]+ > default).
    attr_reader :show_thinking
    # @return [Symbol] the tool-line form to start on (+[ui]+ > default), one
    #   of {TOOL_LINES}.
    attr_reader :tool_lines
    # @return [Llm, nil] the connection conversation titles are written on
    #   (+[titler] llm+), or +nil+ when the file names none — which switches
    #   titling off rather than falling back to {#primary_llm}.
    attr_reader :titler_llm
    # @return [Credentials, nil] the +[web]+ pair gating every request, or
    #   +nil+ when the file names none — which switches the gate off rather
    #   than inventing a default password.
    attr_reader :credentials
    # @return [String] the path the shell is served under, +"/pikuri-webui"+ —
    #   never a trailing slash — or +""+ when it sits at the root.
    attr_reader :base_path

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
      paths << File.join(config_home(env), XDG_SUBDIR, FILENAME)
      paths
    end

    # @param env [#[]] environment, for +XDG_CONFIG_HOME+
    # @return [String] the user's config root, +~/.config+ by default
    def self.config_home(env)
      env['XDG_CONFIG_HOME'].to_s.empty? ? File.join(Dir.home, '.config') : env['XDG_CONFIG_HOME']
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
    #   (a +[[server]]+ +api_key+, a +[web]+ +password+, or a +[search]+
    #   +brave_key+/+exa_key+).
    def self.holds_secret?(parsed)
      servers = parsed['server']
      return true if servers.is_a?(Array) && servers.any? { |e| e.is_a?(Hash) && e['api_key'] }

      web = parsed['web']
      return true if web.is_a?(Hash) && web['password']

      search = parsed['search']
      search.is_a?(Hash) && (search.key?('brave_key') || search.key?('exa_key'))
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
    # path to write it to. A pikuri-tui file where this shell's used to be
    # read is named too, since that is the hole the first boot after the move
    # falls into.
    #
    # @param any_loaded [Boolean] whether any file was read, which is the
    #   only difference between the two cases.
    # @param env [#[]] environment, for the path {.candidate_paths} names.
    # @return [String] the message, quoting {EXAMPLE_CONFIG}.
    def self.no_connection_message(any_loaded, env)
      opening = any_loaded ? 'no [[llm]] is defined' : 'no config file found'
      tui = File.join(config_home(env), PIKURI_TUI_SUBDIR, FILENAME)
      moved = " #{tui} is pikuri-tui's and is not read here; copy what this shell needs across." if File.file?(tui)
      "#{opening}, and there is no built-in default connection.#{moved} " \
        "Write #{candidate_paths(env).last}:\n\n#{EXAMPLE_CONFIG}"
    end

    private_class_method :candidate_paths, :config_home, :warn_loose_perms, :holds_secret?, :parse_file,
                         :deep_merge, :map, :resolve_llm, :resolve_server, :server_is_now_an_id,
                         :resolve_titler, :no_connection_message
  end
end
