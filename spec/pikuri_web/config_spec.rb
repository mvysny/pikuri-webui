# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# Specs for the layered TOML config loader. Each example drives
# PikuriWeb::Config.load with an injected env (so XDG vars never touch the
# host) and temp dirs for the file layers — the same seam the loader exposes
# for exactly this. There is no project-local layer to test: keys live only
# in the XDG config, never inside a repo (see Config's class header).
describe PikuriWeb::Config do
  # Run the block with two empty temp dirs to use as config roots (e.g. a
  # high-priority XDG_CONFIG_HOME and a lower-priority XDG_CONFIG_DIRS entry).
  def with_dirs
    Dir.mktmpdir do |a|
      Dir.mktmpdir do |b|
        yield(a, b)
      end
    end
  end

  # The smallest file that loads. A file defining no [[llm]] raises, so an
  # example about some *other* table still has to carry a connection.
  MINIMAL = <<~TOML
    [[server]]
    id  = "local"
    url = "http://localhost:8080"

    [[llm]]
    name   = "Local"
    server = "local"
    model  = "qwen"

  TOML

  # Write config.toml under dir/pikuri/ (the XDG layout) and return its path,
  # prefixing MINIMAL unless the body brings its own connection — so an
  # example about [ui] or [search] states only the table it is about.
  def write_config(dir, body)
    write_exact_config(dir, body.include?('[[llm]]') ? body : MINIMAL + body)
  end

  # Write the body verbatim — for the examples that are about what a file
  # *lacks*.
  def write_exact_config(dir, body)
    path = File.join(dir, described_class::XDG_SUBDIR, described_class::FILENAME)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    path
  end

  # Env that consults ONLY the given dirs — both XDG vars are pinned (to a
  # nonexistent path by default) so the host's real ~/.config or /etc/xdg can
  # never perturb a spec.
  def env_for(home = '/nonexistent', dirs: '/nonexistent')
    { 'XDG_CONFIG_HOME' => home, 'XDG_CONFIG_DIRS' => dirs }
  end

  # Load a file that states nothing but a connection, with the given
  # overrides — every other setting is then at its built-in default.
  def load_bare(**overrides)
    with_dirs do |home, _|
      write_config(home, '')
      described_class.load(overrides: overrides, env: env_for(home))
    end
  end

  describe 'defaults (a connection and nothing else)' do
    it 'defaults the coding switches on and the mcp list empty' do
      c = load_bare
      assert c.sandbox
      assert c.confirm
      assert_empty c.mcp
    end

    it 'leaves both search provider keys nil, and the engine selection unset' do
      c = load_bare
      assert_nil c.search.brave_key
      assert_nil c.search.exa_key
      assert_nil c.search.engines
    end
  end

  # There is no built-in connection, so the paste-ready block in the raise is
  # where the knowledge of a working file lives.
  describe 'no connection configured' do
    it 'raises with the example config and the path to write it to' do
      err = assert_raises(described_class::Error) { described_class.load(env: env_for('/nonexistent')) }
      assert_includes err.message, 'no config file found'
      assert_includes err.message, '/nonexistent/pikuri/config.toml'
      assert_includes err.message, described_class::EXAMPLE_CONFIG
    end

    it 'raises the same way for a file that defines no [[llm]]' do
      with_dirs do |home, _|
        write_exact_config(home, "[code]\nsandbox = false\n")
        err = assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
        assert_includes err.message, 'no [[llm]] is defined'
        assert_includes err.message, described_class::EXAMPLE_CONFIG
      end
    end
  end

  describe 'CLI overrides (highest precedence)' do
    it 'ignores connection keys — a server/model never comes from the command line' do
      c = load_bare(server: 'http://host:9', model: 'm2')
      assert_equal 'http://localhost:8080', c.primary_llm.server
      assert_equal 'qwen', c.primary_llm.model
    end

    it 'treats false sandbox/confirm overrides as real values (not "absent")' do
      c = load_bare(sandbox: false, confirm: false)
      refute c.sandbox
      refute c.confirm
    end

    it 'wins over a file value' do
      with_dirs do |home, _|
        write_config(home, "[code]\nsandbox = true\n")
        c = described_class.load(overrides: { sandbox: false }, env: env_for(home))
        refute c.sandbox
      end
    end
  end

  describe 'file loading' do
    it 'resolves an [[llm]] server reference into the URL and key of that [[server]]' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [[server]]
          id = "grok"
          url = "https://api.x.ai/v1"
          api_key = "xai-123"

          [[llm]]
          name = "Grok 4 Fast"
          server = "grok"
          model = "grok-4-fast"
        TOML
        c = described_class.load(env: env_for(home))
        assert_equal 'https://api.x.ai/v1', c.primary_llm.server
        assert_equal 'xai-123', c.primary_llm.api_key
        assert_equal 'grok-4-fast', c.primary_llm.model
      end
    end

    # The duplication this schema exists to remove: four models on one
    # provider state its URL and its key once.
    it 'shares one [[server]] across several [[llm]] entries' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [[server]]
          id = "grok"
          url = "https://api.x.ai/v1"
          api_key = "xai-123"

          [[llm]]
          name = "Grok 4 Fast"
          server = "grok"
          model = "grok-4-fast"

          [[llm]]
          name = "Grok 4"
          server = "grok"
          model = "grok-4"
        TOML
        c = described_class.load(env: env_for(home))
        assert_equal %w[xai-123 xai-123], c.llms.map(&:api_key)
        assert_equal %w[grok-4-fast grok-4], c.llms.map(&:model)
      end
    end

    it 'leaves api_key nil when the [[server]] omits it' do
      assert_nil load_bare.primary_llm.api_key
    end

    it 'reads an explicit context_window from an [[llm]] entry' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [[server]]
          id = "x"
          url = "https://api.x.ai"

          [[llm]]
          name = "Grok"
          server = "x"
          model = "grok-4"
          context_window = 2000000
        TOML
        c = described_class.load(env: env_for(home))
        assert_equal 2_000_000, c.primary_llm.context_window
      end
    end

    it 'leaves context_window nil when the entry omits it (pikuri auto-detects)' do
      assert_nil load_bare.primary_llm.context_window
    end

    # What the boot script sizes ServerPermits from — an unreferenced entry
    # included, since rationing a server nobody dials is a no-op and cheaper
    # than filtering by what the [[llm]] list happens to name.
    it 'exposes every [[server]], including one no [[llm]] references' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [[server]]
          id = "spare"
          url = "http://spare:8080"
          max_concurrent_requests = 2
        TOML
        c = described_class.load(env: env_for(home))
        assert_equal %w[local spare], c.servers.map(&:id)
        assert_nil c.servers[0].max_concurrent_requests
        assert_equal 2, c.servers[1].max_concurrent_requests
      end
    end

    it 'builds stdio and http MCP servers' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [[code.mcp]]
          id = "playwright"
          command = ["docker", "run", "-i", "--rm", "mcp/playwright"]

          [[code.mcp]]
          id = "remote"
          url = "https://mcp.example.com/v1"
        TOML
        c = described_class.load(env: env_for(home))
        assert_equal 2, c.mcp.size
        assert c.mcp[0].stdio?
        assert_equal %w[docker run -i --rm mcp/playwright], c.mcp[0].command
        assert c.mcp[1].http?
        assert_equal 'https://mcp.example.com/v1', c.mcp[1].url
        assert_empty c.mcp[0].headers
        assert_empty c.mcp[1].headers
        assert_empty c.mcp[0].env
        assert_empty c.mcp[1].env
      end
    end

    it 'reads an env table for a stdio MCP server' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [[code.mcp]]
          id = "github"
          command = ["github-mcp"]
          [code.mcp.env]
          GITHUB_TOKEN = "ghp-123"
        TOML
        c = described_class.load(env: env_for(home))
        assert_equal({ 'GITHUB_TOKEN' => 'ghp-123' }, c.mcp[0].env)
      end
    end

    it 'turns a bearer_token into an Authorization header' do
      with_dirs do |home, _|
        write_config(home, "[[code.mcp]]\nid = \"remote\"\nurl = \"https://x\"\nbearer_token = \"sk-123\"")
        c = described_class.load(env: env_for(home))
        assert_equal({ 'Authorization' => 'Bearer sk-123' }, c.mcp[0].headers)
      end
    end

    it 'turns basic_auth into a base64 Authorization header' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [[code.mcp]]
          id = "remote"
          url = "https://x"
          [code.mcp.basic_auth]
          username = "user"
          password = "pass"
        TOML
        c = described_class.load(env: env_for(home))
        # base64("user:pass") == "dXNlcjpwYXNz"
        assert_equal({ 'Authorization' => 'Basic dXNlcjpwYXNz' }, c.mcp[0].headers)
      end
    end

    it 'merges custom headers alongside auth' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [[code.mcp]]
          id = "remote"
          url = "https://x"
          bearer_token = "t"
          [code.mcp.headers]
          "X-Api-Key" = "abc"
        TOML
        c = described_class.load(env: env_for(home))
        assert_equal({ 'X-Api-Key' => 'abc', 'Authorization' => 'Bearer t' }, c.mcp[0].headers)
      end
    end

    it 'warns about loose perms when an MCP entry carries a secret' do
      with_dirs do |home, _|
        path = write_config(home, "[[code.mcp]]\nid = \"remote\"\nurl = \"https://x\"\nbearer_token = \"t\"")
        File.chmod(0o644, path)
        out = capture_log { described_class.load(env: env_for(home)) }
        assert_includes out, 'chmod 600'
      end
    end

    it 'reads the brave/exa keys from a [search] table' do
      with_dirs do |home, _|
        write_config(home, "[search]\nbrave_key = \"BSA-123\"\nexa_key = \"exa-456\"")
        c = described_class.load(env: env_for(home))
        assert_equal 'BSA-123', c.search.brave_key
        assert_equal 'exa-456', c.search.exa_key
      end
    end

    it 'reads the engine selection from the [search] table' do
      with_dirs do |home, _|
        write_config(home, "[search]\nbrave_key = \"BSA-123\"\nengines = [\"brave\"]")
        c = described_class.load(env: env_for(home))
        assert_equal %w[brave], c.search.engines
      end
    end

    it 'leaves the unset search key nil when only one provider is configured' do
      with_dirs do |home, _|
        write_config(home, "[search]\nbrave_key = \"BSA-123\"")
        c = described_class.load(env: env_for(home))
        assert_equal 'BSA-123', c.search.brave_key
        assert_nil c.search.exa_key
      end
    end
  end

  # The titler connection and the passthrough that makes it non-thinking. A
  # file that names no titler switches titling off — never a fallback to the
  # primary, whose thinking-on titles are two orders of magnitude slower.
  describe '[titler] and [[llm]] params' do
    # A titler [[llm]] beside MINIMAL's, so `params` and the reference both
    # have somewhere real to point.
    TITLER = <<~TOML
      [[llm]]
      name           = "qwen-titler"
      server         = "local"
      model          = "qwen"
      context_window = 8192
      params         = { chat_template_kwargs = { enable_thinking = false } }
    TOML

    def load_with(body)
      with_dirs do |home, _|
        write_config(home, MINIMAL + body)
        described_class.load(env: env_for(home))
      end
    end

    it 'resolves [titler] llm to the named connection, not the primary' do
      c = load_with("#{TITLER}\n[titler]\nllm = \"qwen-titler\"\n")
      assert_equal 'qwen-titler', c.titler_llm.name
      assert_equal 'Local', c.primary_llm.name
    end

    it 'leaves titler_llm nil when no [titler] names one — titling off, never a fallback' do
      assert_nil load_bare.titler_llm
      assert_nil load_with(TITLER).titler_llm
    end

    it 'carries params through verbatim, frozen' do
      params = load_with(TITLER).llms.last.params
      assert_equal({ 'chat_template_kwargs' => { 'enable_thinking' => false } }, params)
      assert params.frozen?
    end

    it 'defaults params to empty for a connection that declares none' do
      assert_empty load_bare.primary_llm.params
    end

    it 'accepts a titler pointed at a connection with no params (thinking-on, by choice)' do
      c = load_with("[titler]\nllm = \"Local\"\n")
      assert_equal 'Local', c.titler_llm.name
      assert_empty c.titler_llm.params
    end

    it 'rejects a titler naming no [[llm]], listing the names that exist' do
      e = assert_raises(described_class::Error) { load_with("[titler]\nllm = \"nope\"\n") }
      assert_includes e.message, 'titler.llm names no [[llm]]: "nope"'
      assert_includes e.message, '"Local"'
    end

    it 'rejects an empty [titler] table' do
      e = assert_raises(described_class::Error) { load_with("[titler]\n") }
      assert_includes e.message, 'titler.llm: required'
    end

    it 'rejects a blank titler.llm, which a type alone would let through' do
      e = assert_raises(described_class::Error) { load_with("[titler]\nllm = \"  \"\n") }
      assert_includes e.message, 'titler.llm: must not be blank'
    end

    it 'rejects an unknown [titler] key' do
      e = assert_raises(described_class::Error) { load_with("[titler]\nllm = \"Local\"\nmodel = \"x\"\n") }
      assert_includes e.message, 'titler.model: unknown key'
    end

    it 'rejects titler written as an array of tables' do
      e = assert_raises(described_class::Error) { load_with("[[titler]]\nllm = \"Local\"\n") }
      assert_includes e.message, 'titler: expected TitlerTable, got an array of one TitlerTable; ' \
                                 'write [titler], not [[titler]]'
    end

    it 'rejects params that is not a table' do
      e = assert_raises(described_class::Error) { load_with("params = \"enable_thinking=false\"\n") }
      assert_includes e.message, 'llm[0] "Local".params: expected Hash[String, Object]'
    end
  end

  # The [web] gate. Both keys or neither: a half-written table that quietly
  # gated nothing is the one failure this feature cannot have, so every
  # incomplete shape below raises rather than resolving to nil.
  describe '[web] credentials' do
    def load_with(body)
      with_dirs do |home, _|
        write_config(home, body)
        described_class.load(env: env_for(home))
      end
    end

    it 'resolves the pair a file states' do
      c = load_with("[web]\nuser = \"mavi\"\npassword = \"a long passphrase\"\n")
      assert_equal 'mavi', c.credentials.user
      assert_equal 'a long passphrase', c.credentials.password
    end

    it 'leaves credentials nil when no [web] names one — the gate off, never a default password' do
      assert_nil load_bare.credentials
    end

    it 'rejects a [web] table missing either half' do
      { "[web]\nuser = \"mavi\"\n" => 'web.password: required',
        "[web]\npassword = \"a long passphrase\"\n" => 'web.user: required',
        "[web]\n" => 'web.user: required' }.each do |body, message|
        e = assert_raises(described_class::Error) { load_with(body) }
        assert_includes e.message, message
      end
    end

    it 'rejects a blank password' do
      e = assert_raises(described_class::Error) { load_with("[web]\nuser = \"mavi\"\npassword = \"  \"\n") }
      assert_includes e.message, 'web.password: must not be blank'
    end

    it 'rejects an unknown [web] key' do
      e = assert_raises(described_class::Error) do
        load_with("[web]\nuser = \"m\"\npassword = \"p\"\nrealm = \"x\"\n")
      end
      assert_includes e.message, 'web.realm: unknown key'
    end

    it 'rejects web written as an array of tables' do
      e = assert_raises(described_class::Error) { load_with("[[web]]\nuser = \"m\"\npassword = \"p\"\n") }
      assert_includes e.message, 'web: expected Credentials, got an array of one Credentials; write [web], not [[web]]'
    end
  end

  describe 'layering (XDG_CONFIG_DIRS < XDG_CONFIG_HOME)' do
    it 'deep-merges tables so a higher layer adding mcp keeps the lower layer sandbox' do
      with_dirs do |home, sys|
        write_config(sys, "[code]\nsandbox = false\n") # lower priority
        write_config(home, "[[code.mcp]]\nid = \"x\"\nurl = \"u\"\n") # higher priority
        c = described_class.load(env: env_for(home, dirs: sys))
        refute c.sandbox            # survives from the system file
        assert_equal 1, c.mcp.size  # added by the user file
      end
    end

    it 'lets the higher layer override a scalar from the lower layer' do
      with_dirs do |home, sys|
        write_config(sys, "[code]\nconfirm = true\n")
        write_config(home, "[code]\nconfirm = false\n")
        c = described_class.load(env: env_for(home, dirs: sys))
        refute c.confirm
      end
    end

    it 'merges the [search] table key-by-key (system brave + user exa)' do
      with_dirs do |home, sys|
        write_config(sys, "[search]\nbrave_key = \"BSA-sys\"\n")
        write_config(home, "[search]\nexa_key = \"exa-user\"\n")
        c = described_class.load(env: env_for(home, dirs: sys))
        assert_equal 'BSA-sys', c.search.brave_key
        assert_equal 'exa-user', c.search.exa_key
      end
    end
  end

  describe 'cross-shell schema' do
    it 'accepts a file carrying the sections only pikuri-tui reads' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [code]
          sandbox = false

          [[code.mcp]]
          id = "gh"
          url = "https://mcp.example.com"
        TOML
        c = described_class.load(env: env_for(home))
        assert_equal 'Local', c.primary_llm.name
        refute c.sandbox
        assert_equal 1, c.mcp.size
      end
    end

    # The regression this describe existed for and missed: pikuri-tui grew a
    # [ui] table, this shell raised on the unknown top-level key, and anyone
    # who had set a density preference in the TUI could not boot the web shell
    # at all.
    it 'reads the [ui] density table pikuri-tui writes' do
      with_dirs do |home, _|
        write_config(home, <<~TOML)
          [ui]
          show_thinking = false
          tool_lines = "verbose"
        TOML
        c = described_class.load(env: env_for(home))
        refute c.show_thinking
        assert_equal :verbose, c.tool_lines
      end
    end

    it 'defaults the [ui] keys when the table is absent' do
      c = load_bare
      assert c.show_thinking
      assert_equal :short, c.tool_lines
    end

    # Permissive on purpose: pikuri-tui owns what grows in [ui] and its own
    # rdoc already names `markdown` as the next key. Raising here would be the
    # same boot failure with a later date.
    it 'ignores a [ui] key this shell does not read' do
      with_dirs do |home, _|
        write_config(home, "[ui]\nshow_thinking = false\nmarkdown = false\n")
        c = described_class.load(env: env_for(home))
        refute c.show_thinking
      end
    end

    # Shape-checked, never matched against a copy of the vocabulary — a copy
    # would reject a legal file the day pikuri-tui adds a third form. The
    # reader falls back instead, as App does for an unknown `theme` cookie.
    it 'carries an unrecognized tool_lines form through to its reader' do
      with_dirs do |home, _|
        write_config(home, "[ui]\ntool_lines = \"banana\"\n")
        assert_equal :banana, described_class.load(env: env_for(home)).tool_lines
      end
    end
  end

  describe 'load logging (PikuriWeb.logger)' do
    it 'logs each config file it reads, in load order' do
      with_dirs do |home, sys|
        sys_path  = write_exact_config(sys, "[code]\nsandbox = false\n")
        home_path = write_config(home, '')
        out = capture_log { described_class.load(env: env_for(home, dirs: sys)) }
        assert_includes out, "loaded #{sys_path}"
        assert_includes out, "loaded #{home_path}"
        assert_operator out.index(sys_path), :<, out.index(home_path)
      end
    end
  end

  describe 'security advisories' do
    # The key lives on [[server]] now, and this check reads raw pre-merge
    # TOML — so it has to look there. Reading [[llm]] would keep passing on a
    # file full of plaintext keys, with nothing going red.
    it 'warns when a file holding a literal [[server]] api_key is group/other-accessible' do
      with_dirs do |home, _|
        path = write_config(home, "[[server]]\nid = \"keyed\"\nurl = \"http://x\"\napi_key = \"sk-secret\"")
        File.chmod(0o644, path)
        out = capture_log { described_class.load(env: env_for(home)) }
        assert_includes out, 'chmod 600'
      end
    end

    it 'warns when a file holding the [web] password is group/other-accessible' do
      with_dirs do |home, _|
        path = write_config(home, "[web]\nuser = \"mavi\"\npassword = \"a long passphrase\"\n")
        File.chmod(0o644, path)
        out = capture_log { described_class.load(env: env_for(home)) }
        assert_includes out, 'chmod 600'
      end
    end

    it 'stays silent when the secret file is chmod 600' do
      with_dirs do |home, _|
        path = write_config(home, "[[server]]\nid = \"keyed\"\nurl = \"http://x\"\napi_key = \"sk-secret\"")
        File.chmod(0o600, path)
        out = capture_log { described_class.load(env: env_for(home)) }
        refute_includes out, 'chmod 600'
      end
    end

    it 'does not warn about a secret-free file with loose perms' do
      with_dirs do |home, _|
        path = write_config(home, '')
        File.chmod(0o644, path)
        out = capture_log { described_class.load(env: env_for(home)) }
        refute_includes out, 'chmod 600'
      end
    end

    it 'warns when a file holding a [search] provider key is group/other-accessible' do
      with_dirs do |home, _|
        path = write_config(home, "[search]\nbrave_key = \"BSA-secret\"")
        File.chmod(0o644, path)
        out = capture_log { described_class.load(env: env_for(home)) }
        assert_includes out, 'chmod 600'
      end
    end
  end

  describe 'validation' do
    def expect_error(body)
      with_dirs do |home, _|
        write_config(home, body)
        assert_raises(described_class::Error) do
          described_class.load(env: env_for(home))
        end
      end
    end

    it 'rejects env on an HTTP MCP server' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\nurl = \"u\"\nenv = { A = \"b\" }")
      assert_includes e.message, 'stdio servers'
    end

    it 'rejects a non-string env value' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\ncommand = [\"a\"]\nenv = { A = 1 }")
      assert_includes e.message, 'code.mcp[0] "x".env.A: expected String, got 1; quote it to make it a string'
    end

    it 'rejects auth/headers keys on a stdio MCP server' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\ncommand = [\"a\"]\nbearer_token = \"t\"")
      assert_includes e.message, 'HTTP servers'
    end

    it 'rejects both bearer_token and basic_auth on one server' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\nurl = \"u\"\nbearer_token = \"t\"\n" \
                       "[code.mcp.basic_auth]\nusername = \"u\"\npassword = \"p\"")
      assert_includes e.message, 'at most one'
    end

    it 'rejects a bearer_token that also sets Authorization via headers' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\nurl = \"u\"\nbearer_token = \"t\"\n" \
                       "[code.mcp.headers]\nAuthorization = \"Bearer other\"")
      assert_includes e.message, 'conflicts'
    end

    it 'rejects basic_auth without a username' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\nurl = \"u\"\n[code.mcp.basic_auth]\npassword = \"p\"")
      assert_includes e.message, 'username'
    end

    it 'rejects an MCP entry with both command and url' do
      e = expect_error("[[code.mcp]]\nid = \"x\"\ncommand = [\"a\"]\nurl = \"u\"")
      assert_includes e.message, 'exactly one'
    end

    it 'rejects an MCP entry with neither command nor url' do
      e = expect_error("[[code.mcp]]\nid = \"x\"")
      assert_includes e.message, 'exactly one'
    end

    # MINIMAL ends inside its [[llm]] table, so appending a line adds a key to
    # that entry — an example about one key states only that key.
    def expect_llm_error(line) = expect_error(MINIMAL + line)

    it 'rejects an unknown llm key (e.g. the dropped api_key_env)' do
      e = expect_llm_error("api_key_env = \"OPENAI_API_KEY\"\n")
      assert_includes e.message, 'unknown key'
    end

    it 'rejects a non-integer context_window' do
      e = expect_llm_error("context_window = \"2000000\"\n")
      assert_includes e.message, 'llm[0] "Local".context_window: expected Integer, got "2000000"; remove the quotes'
    end

    it 'rejects a non-positive context_window' do
      e = expect_llm_error("context_window = 0\n")
      assert_includes e.message, 'llm[0] "Local".context_window: must be at least 1, got 0'
    end

    it 'rejects duplicate llm names' do
      e = expect_error("#{MINIMAL}\n[[llm]]\nname = \"Local\"\nserver = \"local\"\nmodel = \"m\"\n")
      assert_includes e.message, 'llm[1] "Local".name: duplicate of llm[0], both "Local"'
    end

    it 'rejects duplicate server ids' do
      e = expect_error("#{MINIMAL}\n[[server]]\nid = \"local\"\nurl = \"http://other\"\n")
      assert_includes e.message, 'server[1] "local".id: duplicate of server[0], both "local"'
    end

    it 'rejects duplicate mcp ids' do
      e = expect_error("[[code.mcp]]\nid = \"a\"\nurl = \"u\"\n[[code.mcp]]\nid = \"a\"\nurl = \"u2\"")
      assert_includes e.message, 'code.mcp[1] "a".id: duplicate of code.mcp[0], both "a"'
    end

    # After MINIMAL, not before it: a bare key written below a [[llm]] table
    # would belong to that table rather than to the top level.
    it 'rejects an unknown top-level key' do
      e = expect_error("foo = 1\n\n#{MINIMAL}")
      assert_includes e.message, 'foo: unknown key'
    end

    it 'rejects an llm entry without a name' do
      e = expect_error("[[llm]]\nserver = \"s\"")
      assert_includes e.message, 'llm[0].name: required'
    end

    it 'rejects a blank llm name, which a type alone would let through' do
      e = expect_error("[[llm]]\nname = \"  \"\nserver = \"s\"\nmodel = \"m\"")
      assert_includes e.message, 'llm[0].name: must not be blank'
    end

    it 'rejects an llm entry without a server reference' do
      e = expect_error("[[llm]]\nname = \"a\"\nmodel = \"m\"")
      assert_includes e.message, 'llm[0] "a".server: required'
    end

    it 'rejects an llm entry without a model' do
      e = expect_error("[[llm]]\nname = \"a\"\nserver = \"local\"")
      assert_includes e.message, 'llm[0] "a".model: required'
    end

    it 'rejects a server entry without a url' do
      e = expect_error("[[server]]\nid = \"a\"")
      assert_includes e.message, 'server[1] "a".url: required'
    end

    it 'rejects a non-positive max_concurrent_requests' do
      e = expect_error("[[server]]\nid = \"a\"\nurl = \"http://x\"\nmax_concurrent_requests = 0")
      assert_includes e.message, 'server[1] "a".max_concurrent_requests: must be at least 1, got 0'
    end

    it 'rejects [[server]] written as a plain table' do
      with_dirs do |home, _|
        write_exact_config(home, "[server]\nid = \"a\"\nurl = \"http://x\"\n")
        e = assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
        assert_includes e.message, 'server: expected Array[Server], got a single Server; write [[server]], not [server]'
      end
    end

    it 'rejects [[llm]] written as a plain table' do
      with_dirs do |home, _|
        write_exact_config(home, "[llm]\nname = \"a\"\nserver = \"s\"\nmodel = \"m\"\n")
        e = assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
        assert_includes e.message, 'llm: expected Array[LlmTable], got a single LlmTable; write [[llm]], not [llm]'
      end
    end

    it 'rejects [[code.mcp]] written as a plain table' do
      e = expect_error("[code.mcp]\nid = \"a\"\nurl = \"u\"")
      assert_includes e.message, 'code.mcp: expected Array[McpTable], got a single McpTable; ' \
                                 'write [[code.mcp]], not [code.mcp]'
    end

    # The permissions check reads the raw TOML before the schema does, so it
    # must not assume a table's shape either.
    it 'rejects [code] written as an array of tables' do
      e = expect_error("[[code]]\nsandbox = false")
      assert_includes e.message, 'code: expected CodeTable, got an array of one CodeTable; write [code], not [[code]]'
    end

    it 'rejects a non-boolean sandbox' do
      e = expect_error("[code]\nsandbox = \"yes\"")
      assert_includes e.message, 'code.sandbox: expected bool, got "yes"'
    end

    it 'rejects a non-boolean ui.show_thinking' do
      e = expect_error("[ui]\nshow_thinking = \"yes\"")
      assert_includes e.message, 'ui.show_thinking: expected bool, got "yes"'
    end

    it 'rejects a non-string ui.tool_lines' do
      e = expect_error("[ui]\ntool_lines = 3")
      assert_includes e.message, 'ui.tool_lines: expected String, got 3; quote it to make it a string'
    end

    it 'rejects [ui] declared as an array of tables' do
      e = expect_error("[[ui]]\nshow_thinking = false")
      assert_includes e.message, 'ui: expected UiTable, got an array of one UiTable; write [ui], not [[ui]]'
    end

    it 'rejects an unknown key in the [search] table' do
      e = expect_error("[search]\ngoogle_key = \"g\"")
      assert_includes e.message, 'unknown key'
    end

    it 'rejects a non-string search key' do
      e = expect_error("[search]\nbrave_key = 42")
      assert_includes e.message, 'search.brave_key: expected String, got 42; quote it to make it a string'
    end

    it 'rejects a non-array engine selection' do
      e = expect_error("[search]\nengines = \"brave\"")
      assert_includes e.message, 'search.engines: expected Array[String], got a single String; wrap it in [ ]'
    end

    it 'rejects an engine selection holding a non-string' do
      e = expect_error("[search]\nengines = [\"brave\", 3]")
      assert_includes e.message, 'search.engines[1]: expected String, got 3; quote it to make it a string'
    end

    it 'rejects [search] declared as an array of tables' do
      e = expect_error("[[search]]\nbrave_key = \"b\"")
      assert_includes e.message, 'search: expected Search, got an array of one Search; write [search], not [[search]]'
    end

    it 'wraps malformed TOML in Config::Error' do
      e = expect_error('this is = = not toml')
      assert_includes e.message, 'failed to read'
    end
  end

  # There is no compat path, so the raise is the whole migration experience:
  # each shape an old file fails in gets a message that names the fix.
  describe 'migrating a pre-[[server]] file' do
    def expect_error(body)
      with_dirs do |home, _|
        write_exact_config(home, body)
        assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
      end
    end

    # A URL and an id are both strings, so the old value parses cleanly and
    # fails as a *lookup* — which reads like the user's mistake rather than a
    # key whose meaning changed.
    it 'tells an [[llm]] whose server is a URL that the key now names an id' do
      e = expect_error("[[llm]]\nname = \"a\"\nserver = \"http://localhost:8080\"\nmodel = \"m\"")
      assert_includes e.message, '`server` names a [[server]] `id` now, not a URL'
      assert_includes e.message, 'url = "http://localhost:8080"'
    end

    it 'names the [[server]] an api_key still sitting on an [[llm]] belongs to' do
      e = expect_error("#{MINIMAL}api_key = \"sk-1\"\n")
      assert_includes e.message, '`api_key` belongs on [[server]] "local"'
    end

    # The two halves of an old entry — a URL server and a stray key — fail as
    # one block to paste, not as two round trips.
    it 'folds a stray api_key into the [[server]] block it suggests for a URL' do
      e = expect_error("[[llm]]\nname = \"a\"\nserver = \"http://x:8080\"\nmodel = \"m\"\napi_key = \"sk-1\"")
      assert_includes e.message, 'url = "http://x:8080"'
      assert_includes e.message, 'api_key = "sk-1"'
      assert_includes e.message, 'dropping its `api_key`'
    end

    it 'quotes the example config when no [[server]] is defined at all' do
      e = expect_error("[[llm]]\nname = \"a\"\nserver = \"local\"\nmodel = \"m\"")
      assert_includes e.message, 'no [[server]] is defined'
      assert_includes e.message, described_class::EXAMPLE_CONFIG
    end

    it 'lists the known ids for a reference that is merely misspelt' do
      e = expect_error("#{MINIMAL}\n[[llm]]\nname = \"b\"\nserver = \"locl\"\nmodel = \"m\"\n")
      assert_includes e.message, 'unknown server id "locl"'
      assert_includes e.message, '"local"'
    end
  end
end
