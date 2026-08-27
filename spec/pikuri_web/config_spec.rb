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

  # Write config.toml under dir/pikuri/ (the XDG layout) and return its path.
  def write_config(dir, body)
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

  # Load with no files present and the given overrides.
  def load_bare(**overrides)
    described_class.load(overrides: overrides, env: env_for)
  end

  describe 'defaults (no files)' do
    it 'synthesizes the default Local Qwen connection with no key' do
      c = load_bare
      assert_equal 1, c.llms.size
      assert_equal described_class::DEFAULT_LLM_NAME, c.primary_llm.name
      assert_equal described_class::DEFAULT_SERVER, c.primary_llm.server
      assert_equal described_class::DEFAULT_MODEL, c.primary_llm.model
      assert_nil c.primary_llm.api_key
    end

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

  describe 'CLI overrides (highest precedence)' do
    it 'overrides the primary connection server/model, leaving the key untouched' do
      c = load_bare(server: 'http://host:9', model: 'm2')
      assert_equal 'http://host:9', c.primary_llm.server
      assert_equal 'm2', c.primary_llm.model
      assert_nil c.primary_llm.api_key
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
    it 'reads a literal api_key from an [[llm]] entry' do
      with_dirs do |home, _|
        write_config(home, "[[llm]]\nname = \"Remote\"\nserver = \"https://x\"\napi_key = \"sk-123\"")
        c = described_class.load(env: env_for(home))
        assert_equal 'Remote', c.primary_llm.name
        assert_equal 'sk-123', c.primary_llm.api_key
      end
    end

    it 'leaves api_key nil when the entry omits it' do
      with_dirs do |home, _|
        write_config(home, "[[llm]]\nname = \"Local\"\nserver = \"http://x\"")
        c = described_class.load(env: env_for(home))
        assert_nil c.primary_llm.api_key
      end
    end

    it 'reads an explicit context_window from an [[llm]] entry' do
      with_dirs do |home, _|
        write_config(home, "[[llm]]\nname = \"Grok\"\nserver = \"https://api.x.ai\"\ncontext_window = 2000000")
        c = described_class.load(env: env_for(home))
        assert_equal 2_000_000, c.primary_llm.context_window
      end
    end

    it 'leaves context_window nil when the entry omits it (pikuri auto-detects)' do
      with_dirs do |home, _|
        write_config(home, "[[llm]]\nname = \"Local\"\nserver = \"http://x\"")
        c = described_class.load(env: env_for(home))
        assert_nil c.primary_llm.context_window
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

  describe 'layering (XDG_CONFIG_DIRS < XDG_CONFIG_HOME)' do
    it 'deep-merges tables so a higher layer adding mcp keeps the lower layer sandbox' do
      with_dirs do |home, sys|
        write_config(sys, "[code]\nsandbox = false\n")        # lower priority
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
          [[llm]]
          name = "Local"

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
  end

  describe 'load logging (PikuriWeb.logger)' do
    it 'logs each config file it reads, in load order' do
      with_dirs do |home, sys|
        sys_path  = write_config(sys, "[code]\nsandbox = false\n")
        home_path = write_config(home, "[[llm]]\nname = \"a\"\n")
        out = capture_log { described_class.load(env: env_for(home, dirs: sys)) }
        assert_includes out, "loaded #{sys_path}"
        assert_includes out, "loaded #{home_path}"
        assert_operator out.index(sys_path), :<, out.index(home_path)
      end
    end

    it 'logs a defaults notice when no config file is found' do
      out = capture_log { load_bare }
      assert_includes out, 'no config file found'
    end
  end

  describe 'security advisories' do
    it 'warns when a file holding a literal api_key is group/other-accessible' do
      with_dirs do |home, _|
        path = write_config(home, "[[llm]]\nname = \"a\"\napi_key = \"sk-secret\"")
        File.chmod(0o644, path)
        out = capture_log { described_class.load(env: env_for(home)) }
        assert_includes out, 'chmod 600'
      end
    end

    it 'stays silent when the secret file is chmod 600' do
      with_dirs do |home, _|
        path = write_config(home, "[[llm]]\nname = \"a\"\napi_key = \"sk-secret\"")
        File.chmod(0o600, path)
        out = capture_log { described_class.load(env: env_for(home)) }
        refute_includes out, 'chmod 600'
      end
    end

    it 'does not warn about a secret-free file with loose perms' do
      with_dirs do |home, _|
        path = write_config(home, "[[llm]]\nname = \"a\"\nserver = \"s\"")
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
      assert_includes e.message, '`env` must be a table'
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

    it 'rejects an unknown llm key (e.g. the dropped api_key_env)' do
      e = expect_error("[[llm]]\nname = \"a\"\napi_key_env = \"OPENAI_API_KEY\"")
      assert_includes e.message, 'unknown key'
    end

    it 'rejects a non-integer context_window' do
      e = expect_error("[[llm]]\nname = \"a\"\ncontext_window = \"2000000\"")
      assert_includes e.message, '`context_window` must be a positive integer'
    end

    it 'rejects a non-positive context_window' do
      e = expect_error("[[llm]]\nname = \"a\"\ncontext_window = 0")
      assert_includes e.message, '`context_window` must be a positive integer'
    end

    it 'rejects duplicate llm names' do
      e = expect_error("[[llm]]\nname = \"a\"\n[[llm]]\nname = \"a\"")
      assert_includes e.message, 'duplicate'
    end

    it 'rejects duplicate mcp ids' do
      e = expect_error("[[code.mcp]]\nid = \"a\"\nurl = \"u\"\n[[code.mcp]]\nid = \"a\"\nurl = \"u2\"")
      assert_includes e.message, 'duplicate'
    end

    it 'rejects an unknown top-level key' do
      e = expect_error("foo = 1")
      assert_includes e.message, 'unknown top-level'
    end

    it 'rejects an llm entry without a name' do
      e = expect_error("[[llm]]\nserver = \"s\"")
      assert_includes e.message, '`name` is required'
    end

    it 'rejects a non-boolean sandbox' do
      e = expect_error("[code]\nsandbox = \"yes\"")
      assert_includes e.message, 'true or false'
    end

    it 'rejects an unknown key in the [search] table' do
      e = expect_error("[search]\ngoogle_key = \"g\"")
      assert_includes e.message, 'unknown key'
    end

    it 'rejects a non-string search key' do
      e = expect_error("[search]\nbrave_key = 42")
      assert_includes e.message, 'must be a string'
    end

    it 'rejects a non-array engine selection' do
      e = expect_error("[search]\nengines = \"brave\"")
      assert_includes e.message, 'must be an array of strings'
    end

    it 'rejects an engine selection holding a non-string' do
      e = expect_error("[search]\nengines = [\"brave\", 3]")
      assert_includes e.message, 'must be an array of strings'
    end

    it 'rejects [search] declared as an array of tables' do
      e = expect_error("[[search]]\nbrave_key = \"b\"")
      assert_includes e.message, 'must be a table'
    end

    it 'wraps malformed TOML in Config::Error' do
      e = expect_error("this is = = not toml")
      assert_includes e.message, 'failed to read'
    end
  end
end
