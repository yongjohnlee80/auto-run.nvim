---auto-run.adapters — the test-adapter registry (ADR-0048 §7).
---
---An adapter is a plain table of plain functions — neotest-shaped,
---simplified (no subprocess RPC in v1). Third parties extend the
---roster via `register_adapter()`; the two baseline adapters (go,
---jest) self-register on first registry access.
---
---Adapters stay THIN: position-model bookkeeping, upward status
---aggregation, missing-result filling, and fallback decomposition
---all live in `auto-run.discovery` (neotest lesson #8/#9). An
---adapter only knows how to (a) find its project root, (b) recognize
---and parse its test files, (c) build an argv for a position, and
---(d) parse its runner's machine output back to position ids.
---@module 'auto-run.adapters'

local M = {}

-- ── the interface (ADR §7) ──────────────────────────────────────

---@class AutoRunPosition
---@field id string             `path` (dir/file) | `path::ns::name`
---@field type "dir"|"file"|"namespace"|"test"
---@field name string           display name (test/namespace: as written in source)
---@field path string           absolute file (or dir) path
---@field lnum integer?         1-based start line (file positions and finer)
---@field end_lnum integer?     1-based end line
---@field children AutoRunPosition[]?

---@class AutoRunSpecArgs
---@field position AutoRunPosition   the position to run
---@field tree table                 the AutoRunTree the position belongs to
---@field root string                the adapter root for the position's file
---@field run_id string              pre-generated run id
---@field run_dir string             per-run output dir (already created)

---@class AutoRunSpec
---@field cmd string[]               argv
---@field cwd string?                working dir (defaults to the adapter root)
---@field env table<string,string>?  extra env (merged over the process env)
---@field context table?             adapter-private (output file, id maps, …)

---@class AutoRunResult
---@field status "passed"|"failed"|"skipped"|"running"
---@field duration_ms number?
---@field output string?             short failure output (never full logs)

---@class AutoRunAdapter
---@field name string               "go" | "jest" | …
---@field root fun(dir: string): string|nil
---           project-root detection for a file's dir (go.work/go.mod;
---           nearest package.json). nil → not in a project of this kind.
---@field filter_dir nil|fun(name: string, rel_path: string, root: string): boolean
---           optional walk filter; false prunes the subtree. The core
---           ALWAYS prunes hidden dirs and nested git repos on its own.
---@field is_test_file fun(path: string): boolean
---@field discover_positions fun(path: string): AutoRunPosition|nil, string?
---           parse one file (treesitter, injections disabled) into a
---           `type="file"` position with nested namespace/test children
---           (ids are assigned by the core). nil, err on parse failure;
---           nil, nil for "no positions".
---@field build_spec fun(args: AutoRunSpecArgs): AutoRunSpec|nil, string?
---           nil, nil → the core decomposes (dir→files→tests) and
---           retries finer; nil, err aborts with a structured error.
---@field results fun(spec: AutoRunSpec, exit: table, tree: table): table<string, AutoRunResult>
---           parse the machine output file into results keyed by
---           position id. `exit` = { code, signal, stdout_file, run_dir }.

---Required adapter fields → expected Lua type.
local REQUIRED = {
  name               = "string",
  root               = "function",
  is_test_file       = "function",
  discover_positions = "function",
  build_spec         = "function",
  results            = "function",
}

-- ── registry ────────────────────────────────────────────────────

---name → adapter, plus a stable registration order for deterministic
---`adapter_for` resolution.
---@type table<string, AutoRunAdapter>
local _adapters = {}
---@type string[]
local _order = {}

local _builtins_loaded = false

---Load the two baseline adapters exactly once. Registration is
---replace-by-name, so a third-party adapter registered BEFORE the
---first registry access keeps its slot.
local function ensure_builtins()
  if _builtins_loaded then return end
  _builtins_loaded = true
  for _, mod in ipairs({ "auto-run.adapters.go", "auto-run.adapters.jest" }) do
    local ok, adapter = pcall(require, mod)
    if ok and type(adapter) == "table" and _adapters[adapter.name] == nil then
      M.register_adapter(adapter)
    end
  end
end

---Register (or replace) an adapter. Validates the ADR §7 interface;
---returns `(true)` or `(nil, err)` — never throws on bad input from
---third parties.
---@param adapter AutoRunAdapter
---@return boolean? ok, string? err
function M.register_adapter(adapter)
  if type(adapter) ~= "table" then
    return nil, "register_adapter: adapter must be a table"
  end
  for field, want in pairs(REQUIRED) do
    if type(adapter[field]) ~= want then
      return nil, ("register_adapter: adapter.%s must be a %s (got %s)")
        :format(field, want, type(adapter[field]))
    end
  end
  if adapter.name == "" then
    return nil, "register_adapter: adapter.name must be non-empty"
  end
  if adapter.filter_dir ~= nil and type(adapter.filter_dir) ~= "function" then
    return nil, "register_adapter: adapter.filter_dir must be a function or nil"
  end
  if _adapters[adapter.name] == nil then
    _order[#_order + 1] = adapter.name
  end
  _adapters[adapter.name] = adapter
  return true, nil
end

---One adapter by name (builtins load lazily).
---@param name string
---@return AutoRunAdapter?
function M.get(name)
  ensure_builtins()
  return _adapters[name]
end

---All registered adapters in registration order (builtins first
---unless a third party registered earlier).
---@return AutoRunAdapter[]
function M.list()
  ensure_builtins()
  local out = {}
  for _, name in ipairs(_order) do
    out[#out + 1] = _adapters[name]
  end
  return out
end

---The first adapter that claims `path` as a test file (registration
---order — deterministic).
---@param path string
---@return AutoRunAdapter?
function M.adapter_for(path)
  ensure_builtins()
  for _, name in ipairs(_order) do
    local adapter = _adapters[name]
    local ok, is = pcall(adapter.is_test_file, path)
    if ok and is == true then return adapter end
  end
  return nil
end

---Test-only: wipe the registry (builtins reload on next access). Not
---part of the public API stability contract.
function M._reset_for_tests()
  _adapters, _order, _builtins_loaded = {}, {}, false
end

return M
