---auto-run.adapters — the test-adapter registry (ADR-0048 §7).
---
---An adapter is a plain table of plain functions — neotest-shaped,
---simplified (no subprocess RPC in v1). Third parties extend the
---roster via `register_adapter()`; the baseline adapters (go,
---playwright, jest, rust, dart, node) self-register on first registry access.
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
---@field summary string?           one line for docs (the rendered .auto-run/AGENTS.md)
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
---@field output? fun(exit: table, opts: table?): string
---           OPTIONAL: reconstruct the run's human/terminal output from
---           its machine output file (`exit` = { stdout_file, run_dir }).
---           `opts.test` narrows to one test + its subtests. Backs the
---           tests panel's `i` output view via `discovery.run_output`.
---
--- ── Runtime capabilities (ADR 0194 §2.3.4) ─────────────────────
--- All OPTIONAL and backwards-compatible: absence means "unsupported", and the
--- core's public dispatch (scaffold / run argv / debug) is capability-only —
--- no language checks. go, rust, node and dart implement the run/debug ones;
--- jest, playwright and dart implement `prepare_debug` for test positions.
---@field default_config? fun(kind: "run"|"test"|"debug", name: string?): table
---           OPTIONAL, sync. Scaffold defaults for a new config of `kind`
---           (`adapters.scaffold`), so scaffolding is language-generic.
---@field build_run_argv? fun(eff: table, opts: table?): string[]|nil, string?
---           OPTIONAL, sync. argv for the RUN/TERM strategy only — never a DAP
---           launch (that is prepare_debug*). Returns the base command; the
---           caller appends the config's args.
---@field prepare_debug? fun(pos: AutoRunPosition, opts: table, cb: fun(launch: table|nil, err: table|nil))
---           OPTIONAL, async. Resolve ONE launch-ready DAP config for a
---           discovered TEST position. `opts` is the core's launch token: the
---           adapter reads `opts.is_cancelled()` and installs `opts.abort`; the
---           callback fires exactly once. The core owns `dap.run`.
---@field prepare_debug_config? fun(eff: table, opts: table, cb: fun(launch: table|nil, err: table|nil))
---           OPTIONAL, async. Same contract for an effective `kind=debug|run`
---           config (ordinary debug). `eff` is the RESOLVED effective config.
---
---@field preflight? fun(ctx: { root: string, purpose: "run"|"test"|"debug", eff: table? }): AutoRunIssue[]
---           OPTIONAL, sync, filesystem-only (never spawns). What is missing
---           before anything runs — SDK, installed dependencies, runner,
---           browsers, debug adapter (ADR 0213 §2.4). An `error` issue refuses
---           the launch; a `warn` is shown and the launch proceeds. Also
---           listed by `:AutoRun doctor`.
---
---@class AutoRunIssue
---@field level "error"|"warn"
---@field code string          stable key, e.g. "node_modules_missing"
---@field message string       what is wrong, in the user's terms
---@field fix string?          the command or step that fixes it
---
---@class AutoRunDebugLaunch      what prepare_debug* hands back
---@field dap_type string         nvim-dap adapter key (→ dap.adapters[dap_type])
---@field request "launch"|"attach"
---@field program string?
---@field args string[]?
---@field cwd string?
---@field env table<string,string>?
---@field extra table?            adapter-specific dap fields (go: mode/dlvCwd/buildFlags)
---
---@class AutoRunError
---@field code string
---@field message string
---@field detail table?

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

---The builtin roster, in attribution order: `adapter_for` takes the FIRST
---adapter claiming a file, so playwright precedes jest (a Playwright spec is a
---`*.spec.ts` too, ADR 0213 §2.2) and node — which claims no test files — is
---last. Explicit entries (ADR 0196 §2.2.1, Lector's option 1).
local BUILTINS = {
  "auto-run.adapters.go",
  "auto-run.adapters.playwright",
  "auto-run.adapters.jest",
  "auto-run.adapters.rust",
  "auto-run.adapters.dart",
  "auto-run.adapters.node",
}

---Load the baseline adapters exactly once. Registration is
---replace-by-name, so a third-party adapter registered BEFORE the
---first registry access keeps its slot.
local function ensure_builtins()
  if _builtins_loaded then return end
  _builtins_loaded = true
  for _, mod in ipairs(BUILTINS) do
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

-- ── scaffolding (ADR 0199 §6.2) ─────────────────────────────────

local SCAFFOLD_KINDS = { run = true, test = true, debug = true }

---Adapter names that can scaffold a config (they implement
---`default_config`), in registration order — what a "new config" chooser
---offers.
---@return string[]
function M.scaffold_runtimes()
  local out = {}
  for _, a in ipairs(M.list()) do
    if type(a.default_config) == "function" then out[#out + 1] = a.name end
  end
  return out
end

---Create and store a new config of `kind` named `name`, with the defaults of
---the `runtime` adapter. The ONE scaffold implementation: the panes' `a`
---passes the runtime the user chose (their current buffer is the panel, so no
---filetype can pick it), and any other caller names one. A runtime with no
---`default_config` (or none) gets the historical go-shaped default.
---Publishes `run.config:changed` through `store.add`.
---@param kind "run"|"test"|"debug"
---@param name string
---@param runtime string?  adapter name
---@return string? path, string? err
function M.scaffold(kind, name, runtime)
  if not SCAFFOLD_KINDS[kind] then
    return nil, "scaffold: kind must be run, test or debug (got " .. tostring(kind) .. ")"
  end
  if type(name) ~= "string" or name == "" then
    return nil, "scaffold: name must be a non-empty string"
  end
  local adapter = runtime and M.get(runtime) or nil
  local cfg
  if adapter and type(adapter.default_config) == "function" then
    local ok, res = pcall(adapter.default_config, kind, name)
    if not ok then return nil, "scaffold: " .. tostring(res) end
    cfg = res
  else
    cfg = {
      runtime = "go",
      program = kind == "test" and "${worktree}" or "${worktree}/cmd/" .. name,
    }
  end
  cfg.name = name
  cfg.kind = kind
  return require("auto-run.store").add(cfg)
end

-- ── preflight (ADR 0213 §2.4) ───────────────────────────────────

---An adapter's preflight issues; `{}` when it has none. A throwing check
---becomes a `warn` naming the adapter, never a crash of the launch path.
---@param adapter AutoRunAdapter?
---@param ctx { root: string, purpose: "run"|"test"|"debug", eff: table? }
---@return AutoRunIssue[]
function M.preflight(adapter, ctx)
  if not adapter or type(adapter.preflight) ~= "function" or type(ctx.root) ~= "string" then
    return {}
  end
  local ok, issues = pcall(adapter.preflight, ctx)
  if not ok then
    return { { level = "warn", code = "preflight_failed",
      message = adapter.name .. " preflight failed: " .. tostring(issues) } }
  end
  return type(issues) == "table" and issues or {}
end

---One line per issue: `message — fix`.
---@param issues AutoRunIssue[]
---@return string
function M.format_issues(issues)
  local out = {}
  for _, i in ipairs(issues) do
    out[#out + 1] = i.message .. (i.fix and (" — " .. i.fix) or "")
  end
  return table.concat(out, "\n")
end

---The gate every launch path calls: errors refuse (`nil, message`), warnings
---are logged and the launch proceeds (`true`).
---@param adapter AutoRunAdapter?
---@param ctx { root: string, purpose: "run"|"test"|"debug", eff: table? }
---@return boolean? ok, string? err
function M.check(adapter, ctx)
  local issues = M.preflight(adapter, ctx)
  local errors, warns = {}, {}
  for _, i in ipairs(issues) do
    if i.level == "error" then errors[#errors + 1] = i else warns[#warns + 1] = i end
  end
  if #warns > 0 then
    require("auto-run.log").warn("preflight", adapter.name .. ": " .. M.format_issues(warns))
  end
  if #errors > 0 then
    return nil, adapter.name .. ": " .. M.format_issues(errors)
  end
  return true, nil
end

---Every adapter that claims `dir` as part of one of its projects, with its
---issues for each purpose — `:AutoRun doctor`'s toolchain section.
---@param dir string
---@return { name: string, root: string, issues: AutoRunIssue[] }[]
function M.doctor(dir)
  local out = {}
  for _, a in ipairs(M.list()) do
    if type(a.preflight) == "function" then
      local okr, root = pcall(a.root, dir)
      if okr and type(root) == "string" then
        local seen, issues = {}, {}
        for _, purpose in ipairs({ "run", "test", "debug" }) do
          for _, i in ipairs(M.preflight(a, { root = root, purpose = purpose })) do
            if not seen[i.code] then
              seen[i.code] = true
              issues[#issues + 1] = vim.tbl_extend("force", i, { purpose = purpose })
            end
          end
        end
        out[#out + 1] = { name = a.name, root = root, issues = issues }
      end
    end
  end
  return out
end

---Test-only: wipe the registry (builtins reload on next access). Not
---part of the public API stability contract.
function M._reset_for_tests()
  _adapters, _order, _builtins_loaded = {}, {}, false
end

return M
