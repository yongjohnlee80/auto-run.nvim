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

---Resolve the test config for `runtime` — the ONE implementation of the pick
---rule. `skip_runtime_pick` answers "what would apply if this runtime's pick
---were cleared", so a chooser can say so without a second copy of the rule.
---@param runtime string
---@param skip_runtime_pick boolean
---@return string? name, "picked"|"shared"|"first"|"none" source, string? ignored_pick
local function resolve(runtime, skip_runtime_pick)
  local ok, store = pcall(require, "auto-run.store")
  if not ok then return nil, "none", nil end
  local matches = {}
  for _, c in ipairs(store.list()) do
    if not c.error and c.kind == "test"
        and (c.runtime == nil or c.runtime == runtime) then
      matches[#matches + 1] = c.name
    end
  end
  -- Per-RUNTIME pick first (state.test_picks[runtime], written by M.pick), then
  -- the SHARED per-kind pick (state.picks.test, written by exec.pick_config) so
  -- nothing a user already picked is lost. One name per kind could not hold a
  -- Go choice and a Rust choice at once: picking one silently replaced the
  -- other while the header showed them as independent (ADR 0199 r2 §3.2).
  -- Only a pick that still names a matching config counts.
  local rt_pick, shared
  pcall(function()
    local st = store.read_state()
    rt_pick = type(st.test_picks) == "table" and st.test_picks[runtime] or nil
    shared = type(st.picks) == "table" and st.picks.test or nil
  end)
  if type(rt_pick) ~= "string" or skip_runtime_pick then rt_pick = nil end
  if type(shared) ~= "string" then shared = nil end
  -- Checked one by one, NOT with ipairs({ rt_pick, shared }): ipairs stops at
  -- the first nil, so with no runtime pick it would never reach the shared one.
  if rt_pick and vim.tbl_contains(matches, rt_pick) then return rt_pick, "picked", nil end
  -- A runtime pick that did not apply is REPORTED even when the shared pick
  -- then does — hiding it is the misrepresentation ADR 0199 §5.2 forbids.
  local ignored = rt_pick
  if shared and vim.tbl_contains(matches, shared) then return shared, "shared", ignored end
  ignored = ignored or shared
  if #matches == 0 then return nil, "none", ignored end
  return matches[1], "first", ignored
end

---Name of the repo's `kind=test` config for `runtime`, or nil, and WHY — so a
---pane states the resolver's own reason instead of re-deriving it (a second
---copy of this rule in a view is what would let a header disagree with what
---runs, ADR 0199 §5.2):
---  `source` — `"picked"` (this runtime's pick) | `"shared"` (the per-kind pick
---  every runtime falls back to) | `"first"` (no pick applied) | `"none"`
---  `ignored_pick` — a remembered pick that did NOT apply to `runtime`
---  (another runtime's config, or a config that no longer exists), else nil.
---@param runtime string   the adapter's name ("go", "jest", …)
---@return string? name, "picked"|"shared"|"first"|"none" source, string? ignored_pick
function M.test_config_name(runtime)
  return resolve(runtime, false)
end

---What `test_config_name(runtime)` would return if this runtime's pick were
---cleared — the label a "clear" action must show, because clearing can reveal
---the shared pick rather than the first match.
---@param runtime string
---@return string? name, "shared"|"first"|"none" source, string? ignored_pick
function M.fallback_config_name(runtime)
  return resolve(runtime, true)
end

---Remember the test config for ONE runtime (nil clears it). Refuses a name
---that is not a `kind=test` config for that runtime, and changes nothing when
---it refuses. Publishes `run.config:changed {action="test_picked", runtime,
---name}` so the panes re-render — the same topic `import.set_selected` uses.
---@param runtime string
---@param name string?
---@return true? ok, string? err
function M.pick(runtime, name)
  if type(runtime) ~= "string" or runtime == "" then
    return nil, "pick: runtime must be a non-empty string"
  end
  local store = require("auto-run.store")
  if name ~= nil then
    local valid = false
    for _, c in ipairs(store.list()) do
      if not c.error and c.kind == "test" and c.name == name
          and (c.runtime == nil or c.runtime == runtime) then
        valid = true
        break
      end
    end
    if not valid then
      return nil, ("pick: '%s' is not a test config for %s"):format(tostring(name), runtime)
    end
  end
  -- write_state reports failure by RETURNING (false, err), not by raising, so
  -- a pcall around it alone would call a failed write a success — and then
  -- announce a pick that was never saved. Check both, like import.set_selected.
  local okp, okw, werr = pcall(function()
    local state = store.read_state()
    state.test_picks = type(state.test_picks) == "table" and state.test_picks or {}
    state.test_picks[runtime] = name
    if next(state.test_picks) == nil then state.test_picks = nil end
    return store.write_state(state)
  end)
  if not okp then return nil, "pick: state.json write raised: " .. tostring(okw) end
  if not okw then return nil, "pick: state.json write failed: " .. tostring(werr) end
  local oke, events = pcall(require, "auto-core.events")
  if oke and events then
    pcall(events.publish, "run.config:changed",
      { action = "test_picked", runtime = runtime, name = name })
  end
  return true, nil
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
