# `[[server]]` definitions in config.toml

Normalize the config file. Today every `[[llm]]` repeats its whole connection, so four Grok models
means the same URL and the same API key written four times:

```toml
[[llm]]
name = "Grok 4 Fast"
server = "https://api.x.ai/v1"
api_key = "xai-..."
model = "grok-4-fast"

[[llm]]
name = "Grok 4"
server = "https://api.x.ai/v1"   # again
api_key = "xai-..."              # again
model = "grok-4"
```

Split the physical resource out from the model running on it:

```toml
[[server]]
id = "grok"
url = "https://api.x.ai/v1"
api_key = "xai-..."
max_requests = 4

[[llm]]
name = "Grok 4 Fast"
server = "grok"
model = "grok-4-fast"
context_window = 131072   # a *model* fact — stays on [[llm]]
```

**The split.** Server: `url`, `api_key`, `max_requests`. LLM: `name` (displayed), `model` (id),
`context_window`, `server` (reference). `context_window` is per-model, not per-server, and that is
load-bearing below.

## `id`, not `name`

`[[code.mcp]]` already uses `id` for exactly this role — *"unique id the LLM uses to call
`mcp_connect`"* (`config.rb:109`) — while `name` throughout this schema means a human-facing label
(`[[llm]] name` is the model-picker string; `check_unique!(llms.map(&:name), 'llm name')`). So the
file gets a readable rule: **`id` is referenced by machine, `name` is shown to a person.** An
`[[llm]]` then carries both without ambiguity.

**The trap `id` opens: do not put it in `meta.json`.** `D_per_conversation_model` rejects storing a
name because names are renameable, and `id` buys no stability — it is still a user-editable TOML
string. Worse, an id is only meaningful *relative to a config file*, so `[model, "grok"]` on disk
would orphan every conversation minted on a `[[server]]` that later gets deleted, where today's
stored URL is self-contained. **Resolve to the URL inside `Config`; the `id` never reaches disk.**

## This is what the throttle was looking for

`max_requests` is the per-server throttle value that `[[llm]]` had no honest home for (N models, one
physical server, so the file could state two contradictory facts about one resource and the schema
could only answer with a reducer nobody can guess or an error on a DRY violation it forced).

It composes with pikuri's auto-sizing without a precedence rule, because `ServerPermits`' own rdoc
already settles the order:

> `{.limit}` wins over any such default.

So: `max_requests` → `ServerPermits.limit`, the `/props` probe → `ServerPermits.default`, and
`.limit` wins **by decision rather than by ordering** — precisely the fragility
`D_upstream_request_throttle` rejected `.default` over. A server with `max_requests` gets the
operator's number; one without gets probe-sized from its own `total_slots`. Per-server, mixed, no
timing dependency.

**`--turns` retires here.** The turn executor already went unbounded, so the flag's only remaining
duty is the permit limit, which `max_requests` takes over wholesale. Zero residual jobs — this stops
being a tradeoff against a README promise and becomes pure removal. Note this reverses
`D_upstream_request_throttle`'s logged *"Rejected: dropping `--turns`"*, so it needs saying out loud
in the entry rather than quietly.

## Decided: no defaults, no compat, hard failure

A missing or unresolvable server is a config error. Raise `Config::Error`, boot catches it and exits
1 — `bin/pikuri-web-chat:88` already does this, and `parse_file`'s own comment states the rule
(surface at boot rather than let it escape as a bare backtrace). **A backtrace must not be the
first-run experience.**

`DEFAULT_MODEL` dies too, so `model` becomes required on `[[llm]]`. An entry naming a server but no
model is no more meaningful than one naming neither, and `DEFAULT_MODEL =
'unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M'` is a hardcoded model tag — stale by construction, and a
*silent* fallback to it is exactly the second, invisible connection source `D_schema_complete_config`
exists to forbid.

The zero-config path is not a UX consideration here (it does not produce a working session), but the
**code** for it is live and needs deleting: `Config.load` with no file still returns
`Llm(name: "Local Qwen 3.6", server: "http://localhost:8080", model: "unsloth/...")` and logs
*"config: no config file found; using built-in defaults"*.

Still worth doing even so: **raise with the file that would work** — a paste-ready `[[server]]` +
`[[llm]]` block for local llama.cpp, in the error text. Same knowledge, relocated from code the user
cannot see into a message they can edit. The magic fallback becomes documentation.

## Snags — the one that breaks silently comes first

**`holds_secret?` disarms.** `config.rb:312-313` looks for `api_key` inside `parsed['llm']`. Move
the key to `[[server]]` and that check keeps passing on a file full of plaintext keys — the
`chmod 600` advisory just stops firing, with nothing going red. Must move in the same commit.

**Two arrays that reference each other, under replace-wholesale layering.** `config.rb:43-45`: tables
merge key-by-key, arrays replace wholesale, nearest file wins. References must therefore resolve
*after* the full merge, or a user file adding one `[[llm]]` would have to re-paste the entire
`[[server]]` block, secrets included — the duplication this whole idea removes. Consequence to state
in the entry: a nearer file replacing `[[server]]` can dangle a farther file's `[[llm]]`, and that
**must raise, never fall back**.

**Uniqueness on the URL too, not just the `id`.** `check_unique!` on `id` is obvious. Also check the
*normalized* url — two entries `grok-cheap` / `grok-fast` pointing at one URL with different
`max_requests` would hand one physical server two permit pools, the exact bug upstream's key
normalization fixed (`http://x:8080`, `.../v1`, `.../v1/` are one server). Normalize with pikuri's
own normalizer, reject the collision. An **unused** `[[server]]` stays legal — erroring on it would
make commenting out an `[[llm]]` break the file.

**`ModelCatalog#servers` simplifies.** The distinct-server list stops being scraped out of `[[llm]]`
urls and becomes the `[[server]]` array directly — which is also the list boot sizes permits from.

## What deletes

- `DEFAULT_LLM_NAME` / `DEFAULT_SERVER` / `DEFAULT_MODEL` (`config.rb:160-164`)
- `default_llm` (`config.rb:573`) and its `private_class_method` entry (`config.rb:591`)
- the `empty? ? [default_llm] :` branch (`config.rb:211`)
- the `|| DEFAULT_SERVER` / `|| DEFAULT_MODEL` fallbacks (`config.rb:440-441`)
- `--turns` and its `ServerPermits.limit` loop (`bin/pikuri-web-chat`)
- `config_spec.rb:47-49` and `71-72` assert the defaults directly; they invert into "no file raises"
  and "an `[[llm]]` with no `server` raises"

## `Q_upstream_probe_skip` — separate fix, not blocked by this

`pikuri-core/lib/pikuri/agent.rb:713-723`: one `/props` probe reports two independent facts, and
`context_window` overrides exactly one of them — yet it suppresses both.

```ruby
props = if @transport.context_window
          ContextWindowDetector::Props::NONE      # <- kills total_slots too
        else
          ContextWindowDetector.detect(@transport, openai_base: base)
        end
```

That conflation is the entire reason `D_upstream_request_throttle` argues for sizing explicitly
("an entry that opts out of the probe must not silently opt out of the throttle"). Probe for slots
regardless of `context_window` and every server gets sized from its own truth, which beats any typed
number.

**This schema change makes the wart visible rather than fixing it**: afterwards a key in the *model*
table suppresses a probe that seeds the *server* table, which reads as obviously wrong. Cost of the
upstream fix, honestly: an explicit `context_window` currently also buys *no boot-time network call*,
so a remote paid API would start eating one pointless request per boot (`detect` tolerates the 404
and returns `NONE`, so it is cost, not breakage).

## `Q_where_this_lands` — pikuri-web is the wrong repo for it

`D_schema_complete_config` has the schema authored in the family with this shell carrying all of it,
so a `[[server]]` key no other shell knows inverts the stated direction of flow. This is a
**pikuri-tui `Shared::Config` change** that pikuri-web then ports, and both files' `[[llm]]` sections
break together. Sequence it as: upstream schema → port here → delete `--turns`.

## On graduation

- The fork (normalize the schema; no defaults; hard raise) → a `DECISIONS.md` entry, plus a flat
  invariant + `See D_<slug>` in **Scope decisions**. It must record the two reversals it makes:
  `D_upstream_request_throttle`'s rejection of dropping `--turns`, and the built-in-default path.
- The "resolve to URL, never store the `id`" rule → `D_per_conversation_model`'s *Consequences*,
  since that entry already owns the renameable-name argument.
- The layering rule (resolve after merge; dangling raises) → `Config`'s class rdoc, next to the
  existing **Precedence** section.
- `--turns` removal and the new `[[server]]` block → `README.md`.
- `Q_upstream_probe_skip` → `../pikuri`, not here.
