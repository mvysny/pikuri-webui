# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

# Specs for the layered TOML config loader. Each example drives
# PikuriWebUI::Config.load with an injected env (so XDG vars never touch the
# host) and temp dirs for the file layers — the same seam the loader exposes
# for exactly this. There is no project-local layer to test: keys live only
# in the XDG config, never inside a repo (see Config's class header).
describe PikuriWebUI::Config do
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

  # Write config.toml under dir/pikuri-webui/ (the XDG layout) and return its path,
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

  # Load a file that states nothing but a connection — every other setting is
  # then at its built-in default.
  def load_bare
    with_dirs do |home, _|
      write_config(home, '')
      described_class.load(env: env_for(home))
    end
  end

  describe 'defaults (a connection and nothing else)' do
    it 'serves at the root, ungated' do
      c = load_bare
      assert_equal '', c.base_path
      assert_nil c.credentials
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
      assert_includes err.message, '/nonexistent/pikuri-webui/config.toml'
      assert_includes err.message, described_class::EXAMPLE_CONFIG
      refute_includes err.message, 'pikuri-tui'
    end

    it 'raises the same way for a file that defines no [[llm]]' do
      with_dirs do |home, _|
        write_exact_config(home, "[ui]\nshow_thinking = false\n")
        err = assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
        assert_includes err.message, 'no [[llm]] is defined'
        assert_includes err.message, described_class::EXAMPLE_CONFIG
      end
    end

    # The first boot after the move: the connections are still sitting in the
    # file this shell used to share, and nothing reads it any more.
    it "names pikuri-tui's file when one is where this shell's used to be" do
      with_dirs do |home, _|
        tui = File.join(home, 'pikuri', 'config.toml')
        FileUtils.mkdir_p(File.dirname(tui))
        File.write(tui, MINIMAL)
        err = assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
        assert_includes err.message, "#{tui} is pikuri-tui's and is not read here"
        assert_includes err.message, "Write #{home}/pikuri-webui/config.toml"
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

  # How the port faces the network. The pair is both keys or neither: a
  # half-written one that quietly gated nothing is the one failure the gate
  # cannot have, so a lone half raises rather than resolving to nil.
  describe '[web]' do
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

    it 'listens on loopback, port 4567, when the file says nothing' do
      c = load_bare
      assert_equal '127.0.0.1', c.bind
      assert_equal 4567, c.port
    end

    it 'reads the address and port a file states' do
      c = load_with("[web]\nbind = \"0.0.0.0\"\nport = 9292\n")
      assert_equal '0.0.0.0', c.bind
      assert_equal 9292, c.port
    end

    it 'rejects a port outside 1..65535' do
      [0, 65_536].each do |port|
        e = assert_raises(described_class::Error, port.to_s) { load_with("[web]\nport = #{port}\n") }
        assert_includes e.message, "web.port: must be 1 to 65535, got #{port}"
      end
    end

    it 'rejects a port written as a string' do
      e = assert_raises(described_class::Error) { load_with("[web]\nport = \"9292\"\n") }
      assert_includes e.message, 'web.port: expected Integer'
    end

    it 'rejects a blank bind' do
      e = assert_raises(described_class::Error) { load_with("[web]\nbind = \"\"\n") }
      assert_includes e.message, 'web.bind: must not be blank'
    end

    it 'leaves credentials nil when [web] names no pair — the gate off, never a default password' do
      c = load_with("[web]\nbase_path = \"/pikuri-webui\"\n")
      assert_nil c.credentials
      assert_equal '/pikuri-webui', c.base_path
    end

    it 'rejects a pair missing either half' do
      ["[web]\nuser = \"mavi\"\n", "[web]\npassword = \"a long passphrase\"\n"].each do |body|
        e = assert_raises(described_class::Error) { load_with(body) }
        assert_includes e.message, 'set `user` and `password` together, or neither'
      end
    end

    it 'rejects a blank password' do
      e = assert_raises(described_class::Error) { load_with("[web]\nuser = \"mavi\"\npassword = \"  \"\n") }
      assert_includes e.message, 'web.password: must not be blank'
    end

    it 'drops a trailing slash, so "/" is the root' do
      assert_equal '/pikuri-webui', load_with("[web]\nbase_path = \"/pikuri-webui/\"\n").base_path
      assert_equal '/a/b', load_with("[web]\nbase_path = \"/a/b\"\n").base_path
      assert_equal '', load_with("[web]\nbase_path = \"/\"\n").base_path
    end

    # It is written into a cookie's Path and into every URL the page builds,
    # so nothing in it may need escaping in any of them.
    it 'rejects a base_path that is not a plain absolute path' do
      ['pikuri-webui', '', '//x', '/a//b', '/a/../b', '/.', '/a b', '/a;b', '/a?b', '/%41'].each do |path|
        e = assert_raises(described_class::Error, path) { load_with("[web]\nbase_path = #{path.inspect}\n") }
        assert_includes e.message, '`base_path` must be an absolute path such as "/pikuri-webui"'
        assert_includes e.message, "got #{path.inspect}"
      end
    end

    it 'rejects an unknown [web] key' do
      e = assert_raises(described_class::Error) do
        load_with("[web]\nuser = \"m\"\npassword = \"p\"\nrealm = \"x\"\n")
      end
      assert_includes e.message, 'web.realm: unknown key'
    end

    it 'rejects web written as an array of tables' do
      e = assert_raises(described_class::Error) { load_with("[[web]]\nuser = \"m\"\npassword = \"p\"\n") }
      assert_includes e.message, 'web: expected WebTable, got an array of one WebTable; write [web], not [[web]]'
    end
  end

  describe '[ui]' do
    it 'reads both starting values' do
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

    it 'defaults both keys when the table is absent' do
      c = load_bare
      assert c.show_thinking
      assert_equal :short, c.tool_lines
    end

    # Each form App checks a cookie against has to load from the file too, or
    # a `/toollines` pick could name a form the file cannot.
    it 'accepts every form App renders' do
      PikuriWebUI::Web::App::TOOL_LINES.each do |form|
        with_dirs do |home, _|
          write_config(home, "[ui]\ntool_lines = #{form.inspect}\n")
          assert_equal form.to_sym, described_class.load(env: env_for(home)).tool_lines
        end
      end
    end

    it 'rejects a tool_lines form nothing renders' do
      with_dirs do |home, _|
        write_config(home, "[ui]\ntool_lines = \"banana\"\n")
        e = assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
        assert_includes e.message, 'ui.tool_lines: must be one of "short", "verbose", got "banana"'
      end
    end

    it 'rejects a [ui] key this shell does not read' do
      with_dirs do |home, _|
        write_config(home, "[ui]\nshow_thinking = false\nmarkdown = false\n")
        e = assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
        assert_includes e.message, 'ui.markdown: unknown key'
      end
    end
  end

  # pikuri-tui keeps its own file now, so a table only it reads is a typo here
  # like any other unknown key.
  it 'rejects the [code] table pikuri-tui reads' do
    with_dirs do |home, _|
      write_config(home, "[code]\nsandbox = false\n")
      e = assert_raises(described_class::Error) { described_class.load(env: env_for(home)) }
      assert_includes e.message, 'code: unknown key'
    end
  end

  describe 'layering (XDG_CONFIG_DIRS < XDG_CONFIG_HOME)' do
    it 'deep-merges tables so a higher layer adding a key keeps the lower layer\'s' do
      with_dirs do |home, sys|
        write_config(sys, "[web]\nbase_path = \"/pikuri-webui\"\n") # lower priority
        write_config(home, "[web]\nuser = \"mavi\"\npassword = \"p\"\n") # higher priority
        c = described_class.load(env: env_for(home, dirs: sys))
        assert_equal '/pikuri-webui', c.base_path # survives from the system file
        assert_equal 'mavi', c.credentials.user # added by the user file
      end
    end

    it 'lets the higher layer override a scalar from the lower layer' do
      with_dirs do |home, sys|
        write_config(sys, "[ui]\nshow_thinking = true\n")
        write_config(home, "[ui]\nshow_thinking = false\n")
        c = described_class.load(env: env_for(home, dirs: sys))
        refute c.show_thinking
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

  describe 'load logging (PikuriWebUI.logger)' do
    it 'logs each config file it reads, in load order' do
      with_dirs do |home, sys|
        sys_path  = write_exact_config(sys, "[ui]\nshow_thinking = false\n")
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
