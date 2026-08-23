---auto-run.adapters.config — the shared `kind=test` config resolver for
---adapters (ADR-0048 §7).
---
---An adapter that runs tests needs the repo's picked `kind=test` config
---resolved and composed the same way every other execution path composes it:
---`store.get` → `env.substitute_deep` → `env.compose`. That pipeline is what
---makes `env`, `env_files` (VS Code's `envFile`), the selected env file and
---secret manifests reach a run.
---
---It lives here rather than in an adapter because BOTH baseline adapters need
---it and a second copy would drift ([[shared-resolver-single-source-of-truth]]).
---The Go adapter owned the only implementation, so Jest silently ran with no
---composed env at all — configured `env` reached `go test` and never reached
---`jest`.
---
---Separate module rather than `adapters/init.lua`: the registry requires the
---adapters (they self-register on first access), so an adapter requiring the
---registry back would be circular.
---
---Selection is by `runtime`: a `kind=test` config claims an adapter when its
---`runtime` matches the adapter's name, and a config with NO runtime is
---generic and applies to whichever adapter asks. That is the same rule the Go
---adapter always used, generalised.
---@module 'auto-run.adapters.config'

local M = {}

---Name of the repo's picked `kind=test` config for `runtime`, or nil.
---@param runtime string   the adapter's name ("go", "jest", …)
---@return string? name
function M.test_config_name(runtime)
  local ok, store = pcall(require, "auto-run.store")
  if not ok then return nil end
  for _, c in ipairs(store.list()) do
    if not c.error and c.kind == "test"
        and (c.runtime == nil or c.runtime == runtime) then
      return c.name
    end
  end
  return nil
end

---The picked `kind=test` config, substituted and env-composed.
---
---`(nil, nil)` when the repo has no such config — a normal state, the adapter
---just runs without one. `(nil, err)` when the config EXISTS but composition
---fails: a missing `envFile` or an unresolvable secret must fail the run
---loudly, never silently drop the env the user configured.
---@param runtime string
---@return { name: string, eff: table, env: table<string,string>? }? applied, string? err
function M.test_config(runtime)
  local picked = M.test_config_name(runtime)
  if not picked then return nil, nil end

  local store = require("auto-run.store")
  local eff, gerr = store.get(picked)
  if not eff then return nil, tostring(gerr) end

  local env_mod = require("auto-run.env")
  local ctx = env_mod.context()
  eff = env_mod.substitute_deep(eff, ctx)
  local comp, cerr = env_mod.compose(eff, { ctx = ctx })
  if not comp then
    return nil, "config '" .. picked .. "': "
      .. (cerr and cerr.message or "env composition failed")
  end

  return {
    name = picked,
    eff  = eff,
    env  = next(comp.env) ~= nil and comp.env or nil,
  }, nil
end

return M
