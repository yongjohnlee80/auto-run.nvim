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

---Name of the repo's `kind=test` config for `runtime`, or nil: the user's
---PICK when it names a matching config, otherwise the first match in
---`store.list()` order.
---@param runtime string   the adapter's name ("go", "jest", …)
---@return string? name
function M.test_config_name(runtime)
  local ok, store = pcall(require, "auto-run.store")
  if not ok then return nil end
  local matches = {}
  for _, c in ipairs(store.list()) do
    if not c.error and c.kind == "test"
        and (c.runtime == nil or c.runtime == runtime) then
      matches[#matches + 1] = c.name
    end
  end
  if #matches == 0 then return nil end
  -- The user's PICK wins over list order. The pick is the per-repo memory
  -- exec.pick_config already honours (state.picks[kind] in the shared tier's
  -- state.json); read through the store, which owns that file. Only a pick that
  -- still names a matching config counts — a pick for another runtime, or one
  -- whose config is gone, falls back to the first match rather than failing.
  local picked
  pcall(function()
    local picks = store.read_state().picks
    picked = type(picks) == "table" and picks.test or nil
  end)
  if type(picked) == "string" and vim.tbl_contains(matches, picked) then
    return picked
  end
  return matches[1]
end

---The picked `kind=test` config with the user's selections applied —
---the selected launch config merged under it as the active base, the
---selected env file composed in — substituted and env-composed.
---
---`(nil, nil)` only when the repo has no such config AND nothing is selected —
---a normal state, the adapter just runs without one. With no config but a
---selection, the result carries the selection (`name` is nil). `(nil, err)`
---when composition fails: a missing `envFile` or an unresolvable secret must
---fail the run loudly, never silently drop the env the user configured.
---@param runtime string
---@return { name: string, eff: table, env: table<string,string>? }? applied, string? err
function M.test_config(runtime)
  local picked = M.test_config_name(runtime)

  local eff
  if picked then
    local gerr
    eff, gerr = require("auto-run.store").get(picked)
    if not eff then return nil, tostring(gerr) end
  else
    -- No kind=test config is a NORMAL state, but it must not be a SILENT one.
    -- The tests pane lets the user select a launch config and an env file, and
    -- both have to reach the run whether or not the repo has a config. Compose
    -- an empty test eff so they do; without this the selected env file was
    -- dropped outright, because env.compose (which applies it) never ran.
    eff = { kind = "test", runtime = runtime }
  end

  -- The selected launch config is the active BASE, merged UNDER `eff` with
  -- `eff` winning — the same call exec/init.lua, dap.translate and
  -- dap.debug_test already make. This was the one production path without it,
  -- and it is the path the tests pane's own run action takes, so the Config
  -- selected in that pane never reached a position run: neither its env nor
  -- its build flags. apply_selected_base only fills program/args when `eff`
  -- has none, and no adapter reads those from here — a position run targets
  -- the POSITION.
  eff = require("auto-run.import").apply_selected_base(eff)

  local env_mod = require("auto-run.env")
  local ctx = env_mod.context()
  eff = env_mod.substitute_deep(eff, ctx)
  local comp, cerr = env_mod.compose(eff, { ctx = ctx })
  if not comp then
    -- Loud, as before: a missing envFile or an unresolvable secret fails the
    -- run rather than silently dropping env the user asked for.
    return nil, (picked and ("config '" .. picked .. "'") or "test run selections")
      .. ": " .. (cerr and cerr.message or "env composition failed")
  end

  local env = next(comp.env) ~= nil and comp.env or nil
  -- Nothing configured AND nothing selected: keep the historical (nil, nil), so
  -- an adapter's no-config path is unchanged rather than handed an empty table.
  if not picked and env == nil and eff.build_flags == nil then
    return nil, nil
  end

  return { name = picked, eff = eff, env = env }, nil
end

return M
