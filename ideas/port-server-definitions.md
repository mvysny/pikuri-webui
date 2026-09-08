# Port `[[server]]` from pikuri-tui; retire `--turns`

**Blocked on** `../pikuri-tui/ideas/server-definitions-in-config.md` landing in `Shared::Config`
— the schema is authored there and ported here (`D_schema_complete_config`). Read that file for
the schema, the `id`-not-`name` rule, the resolve-to-URL trap and the `holds_secret?` snag; this
file is only what is *ours* once it exists.

## The port

Same shape as the TUI's: `Config::Server(id, url, api_key, max_concurrent_requests)`,
`Config#servers`,
`Llm` unchanged with `server`/`api_key` already resolved — so `ModelCatalog.from_llms`,
`agent_runner_spec` and `model_catalog_spec` don't move. `holds_secret?` reads `parsed['server']`.
The defaults (`DEFAULT_LLM_NAME` / `DEFAULT_SERVER` / `DEFAULT_MODEL`, `default_llm`, the
`|| DEFAULT_*` fallbacks) die; `config_spec.rb:47-49` and `71-72` invert into "no file raises" /
"no `server` raises". The `cross-shell schema` describe gains the new table. Every `[[llm]]`
fixture in `config_spec.rb` gains a `[[server]]` block — bulky, dumb.

## `--turns` retires here

The turn executor already went unbounded, so the flag's only remaining duty is the permit limit,
which `max_concurrent_requests` takes over wholesale. Zero residual jobs — pure removal:

- the flag, its `< 1` check and the `catalog.servers.each { ServerPermits.limit(server, turns) }`
  loop in `bin/pikuri-web-chat` become
  `config.servers.each { |s| ServerPermits.limit(s.url, s.max_concurrent_requests) if
  s.max_concurrent_requests }`
- `ModelCatalog#servers` **deletes** (the boot loop was its only caller), with its spec
- README's "How many conversations can think at once" section rewrites around
  `max_concurrent_requests`;
  the quick start starts with "write this file"

## On graduation

- One `DECISIONS.md` entry + a flat invariant in **Scope decisions**. It must record **two
  reversals** out loud: `D_upstream_request_throttle`'s *"Rejected: dropping `--turns`"*, and
  `D_schema_complete_config`'s consequence that *"a first run against a stock llama.cpp needs no
  file at all"*. The existing **Scope decisions** bullet on `--turns` / `ServerPermits.limit`
  rewrites.
- "Resolve to URL, never store the `id`" → `D_per_conversation_model`'s *Consequences*, since that
  entry already owns the renameable-name argument.
- Layering rule (resolve after merge; dangling raises) → `Config`'s rdoc **Precedence** section.
- `D_schema_complete_config`'s "noted divergence from pikuri-tui, whose three shells still take
  `--server` / `--model`" is already stale — the TUI followed. Fix the entry while in there.
