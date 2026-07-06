---auto-run.mailbox.commands — register the `run.*` mailbox verbs
---(ADR-0048 §11; SPECS-table blueprint from
---auto-agents/mailbox/todos_commands.lua).
---
---  Read (always allowed):
---    run.list           — config inventory (slim projection)
---    run.show           — one effective (merged) config
---    run.profiles_list  — env-profile inventory
---    run.status         — resolver + store status + LIVE jobs
---    run.validate       — whole-store schema/merge inspection
---    run.jobs           — session job inventory (live + exited)
---    run.tests_list     — discovered position tree (Phase 3, §7)
---    run.results        — last test results keyed by position id
---
---  Store mutations (data, not execution — always allowed):
---    run.add            — create a config
---    run.update         — patch (write-routing per §3.1)
---    run.remove         — delete a config file
---    run.set_dir        — shared-tier dir override
---    run.import         — launch.json → tracked tier
---
---  Control (always allowed):
---    run.stop           — UNGATED per §11: stopping a live job is a
---                         safety/control operation. Only ever
---                         terminates jobs auto-run itself started —
---                         unknown/foreign ids are not_found.
---
---  Execution-starting (trust-gated — auto-core.trust `run.exec`):
---    run.start / run.test_run / run.debug_start
---    Every handler calls trust.check("run.exec", <config name>)
---    FIRST. The mailbox path is hard-wired force-incapable: no verb
---    schema carries a force/bypass flag, handlers never call
---    trust.set, and unknown args can't smuggle one in — an agent can
---    never bootstrap execution trust remotely (ADR-0035 §4.5
---    wiring). run.test_run runs kind=test CONFIGS (Phase 2 form) or
---    a discovered POSITION id (Phase 3 extension — args.position).
---
---Secret values NEVER appear in verb responses — configs carry refs
---only, job records carry no env at all, and this module never
---touches composed env values.
---@module 'auto-run.mailbox.commands'

local M = {}

local OWNER = "auto-run"

-- ── envelopes (mailbox commands convention) ─────────────────────

---@param value any
---@return table
local function ok_response(value)
  return { ok = true, value = value }
end

---@param code string
---@param message string
---@return table
local function err_response(code, message)
  return { ok = false, error = message, code = code }
end

---Lazy + soft store access so this module loads cleanly when
---auto-core is absent at startup.
---@return table? store, table? errenv
local function store_or_err()
  local ok, mod = pcall(require, "auto-run.store")
  if not ok or type(mod) ~= "table" then
    return nil, err_response("dependency_unavailable",
      "auto-run.store is not available")
  end
  return mod
end

---Wrap a `(value, err)` Lua-API result into an envelope.
---@param value any
---@param err string?
---@param code string?
---@return table
local function wrap_two_value(value, err, code)
  if value == nil and err ~= nil then
    return err_response(code or "internal_error", tostring(err))
  end
  return ok_response(value)
end

-- ── handlers ────────────────────────────────────────────────────

local function h_list(_args)
  local store, errenv = store_or_err(); if not store then return errenv end
  local okl, list = pcall(store.list)
  if not okl then return err_response("internal_error", tostring(list)) end
  return ok_response({ count = #list, configs = list })
end

local function h_show(args)
  local store, errenv = store_or_err(); if not store then return errenv end
  if type(args.name) ~= "string" or args.name == "" then
    return err_response("invalid_args", "args.name must be a non-empty string")
  end
  local opts = {}
  if type(args.profile) == "string" and args.profile ~= "" then
    opts.profile = args.profile
  end
  local eff, err, meta = store.get(args.name, opts)
  if not eff then
    -- Structured store errors (e.g. overrides_corrupt) carry their
    -- own envelope code; everything else is a lookup failure.
    local code = (type(err) == "table" and type(err.code) == "string")
      and err.code or "not_found"
    return err_response(code, tostring(err))
  end
  return ok_response({
    config     = eff,
    layers     = meta and meta.layers or {},
    provenance = meta and meta.provenance or {},
  })
end

local function h_profiles_list(_args)
  local store, errenv = store_or_err(); if not store then return errenv end
  local okl, list = pcall(store.list_profiles)
  if not okl then return err_response("internal_error", tostring(list)) end
  return ok_response({ count = #list, profiles = list })
end

local function h_status(_args)
  local store, errenv = store_or_err(); if not store then return errenv end
  local oks, status = pcall(store.status)
  if not oks then return err_response("internal_error", tostring(status)) end
  -- Live jobs (Phase 2 execution engine) — projections carry no env.
  status.jobs = {}
  local okx, exec = pcall(require, "auto-run.exec")
  if okx then
    local okl, jobs = pcall(exec.list, { active_only = true })
    if okl then status.jobs = jobs end
  end
  -- Breakpoint-store stats (§9) — `error` carries the read failure
  -- when the persisted file is corrupt (never masked as 0 records).
  local okb, bstats = pcall(function()
    return require("auto-run.dap.breakpoints").stats()
  end)
  if okb then status.breakpoints = bstats end
  return ok_response(status)
end

local function h_validate(_args)
  local store, errenv = store_or_err(); if not store then return errenv end
  local okv, report = pcall(store.validate)
  if not okv then return err_response("internal_error", tostring(report)) end
  return ok_response(report)
end

local function h_add(args)
  local store, errenv = store_or_err(); if not store then return errenv end
  if type(args.config) ~= "table" then
    return err_response("invalid_args", "args.config must be a table")
  end
  local opts = {}
  if args.tier ~= nil then
    if args.tier ~= "tracked" and args.tier ~= "shared" then
      return err_response("invalid_args", "args.tier must be 'tracked' or 'shared'")
    end
    opts.tier = args.tier
  end
  if args.overwrite ~= nil then opts.overwrite = args.overwrite == true end
  local path, err = store.add(args.config, opts)
  if not path then return err_response("invalid_args", tostring(err)) end
  return ok_response({ name = args.config.name, path = path })
end

local function h_update(args)
  local store, errenv = store_or_err(); if not store then return errenv end
  if type(args.name) ~= "string" or args.name == "" then
    return err_response("invalid_args", "args.name must be a non-empty string")
  end
  if type(args.patch) ~= "table" then
    return err_response("invalid_args", "args.patch must be a table")
  end
  local result, err = store.update(args.name, args.patch)
  if not result then
    local code = (type(err) == "table" and type(err.code) == "string") and err.code
      or (tostring(err):match("launch%.json shim") and "import_required")
      or (tostring(err):match("not found") and "not_found" or "invalid_args")
    return err_response(code, tostring(err))
  end
  return ok_response(result)
end

local function h_remove(args)
  local store, errenv = store_or_err(); if not store then return errenv end
  if type(args.name) ~= "string" or args.name == "" then
    return err_response("invalid_args", "args.name must be a non-empty string")
  end
  local opts = {}
  if args.tier ~= nil then
    if args.tier ~= "tracked" and args.tier ~= "shared" then
      return err_response("invalid_args", "args.tier must be 'tracked' or 'shared'")
    end
    opts.tier = args.tier
  end
  local okr, err = store.remove(args.name, opts)
  if not okr then
    local code = tostring(err):match("not found") and "not_found" or "internal_error"
    return err_response(code, tostring(err))
  end
  return ok_response({ removed = args.name })
end

local function h_set_dir(args)
  local store, errenv = store_or_err(); if not store then return errenv end
  if args.path ~= nil and type(args.path) ~= "string" then
    return err_response("invalid_args", "args.path, when provided, must be a string")
  end
  local dirs, err = store.set_dir(args.path)
  return wrap_two_value(dirs, err, "invalid_args")
end

local function h_import(args)
  local store, errenv = store_or_err(); if not store then return errenv end
  if args.name ~= nil and type(args.name) ~= "string" then
    return err_response("invalid_args", "args.name, when provided, must be a string")
  end
  if args.on_conflict ~= nil
      and args.on_conflict ~= "overwrite"
      and args.on_conflict ~= "skip"
      and args.on_conflict ~= "rename" then
    return err_response("invalid_args",
      "args.on_conflict must be one of overwrite|skip|rename")
  end
  local oki, import = pcall(require, "auto-run.import")
  if not oki then
    return err_response("dependency_unavailable", "auto-run.import is not available")
  end
  local summary, err = import.import(args.name, { on_conflict = args.on_conflict })
  return wrap_two_value(summary, err, "import_failed")
end

-- ── discovery handlers (Phase 3, ADR-0048 §7/§11) ───────────────

---@return table? discovery, table? errenv
local function discovery_or_err()
  local ok, mod = pcall(require, "auto-run.discovery")
  if not ok or type(mod) ~= "table" then
    return nil, err_response("dependency_unavailable",
      "auto-run.discovery is not available")
  end
  return mod
end

local function h_tests_list(_args)
  local discovery, errenv = discovery_or_err(); if not discovery then return errenv end
  local okr, err = pcall(discovery.refresh_open_buffers)
  if not okr then
    return err_response("internal_error", tostring(err))
  end
  local okt, tree = pcall(discovery.tree_plain)
  if not okt then return err_response("internal_error", tostring(tree)) end
  local okc, counts = pcall(function() return discovery.tree():counts() end)
  return ok_response({
    root      = tree.path,
    files     = okc and counts.files or 0,
    positions = okc and counts.positions or 0,
    tree      = tree,
  })
end

local function h_results(_args)
  local discovery, errenv = discovery_or_err(); if not discovery then return errenv end
  local okr, results = pcall(discovery.results)
  if not okr then return err_response("internal_error", tostring(results)) end
  local count = 0
  for _ in pairs(results) do count = count + 1 end
  return ok_response({
    root    = discovery.tree().root.path,
    count   = count,
    results = results,
  })
end

-- ── execution handlers (Phase 2, ADR-0048 §11) ──────────────────

---@return table? exec, table? errenv
local function exec_or_err()
  local ok, mod = pcall(require, "auto-run.exec")
  if not ok or type(mod) ~= "table" then
    return nil, err_response("dependency_unavailable",
      "auto-run.exec is not available")
  end
  return mod
end

---Trust gate shared by every execution-starting verb. Force-incapable
---BY CONSTRUCTION: this helper only ever calls `trust.check`
---(read-only); no schema below carries a force/bypass flag and no
---handler calls `trust.set` — a remote agent cannot bootstrap
---execution trust (ADR-0035 §4.5 wiring, ADR-0048 §11).
---@param config_name string
---@return table? errenv  nil when trusted
local function check_exec_trust(config_name)
  local okt, trust = pcall(require, "auto-core.trust")
  if not okt or type(trust) ~= "table" then
    return err_response("dependency_unavailable",
      "auto-core.trust is not available")
  end
  local allowed, reason = trust.check("run.exec", config_name)
  if not allowed then
    return err_response("trust_required",
      "run.exec capability check failed (" .. tostring(reason) .. ") for '"
      .. config_name .. "' — execution-starting verbs need the workspace "
      .. "run.exec trust capability, enabled interactively in the host "
      .. "(first-run acknowledgment); it cannot be enabled via mailbox")
  end
  return nil
end

---Envelope code for a failed launch: the structured compose-error
---code when present, else a not-found / generic mapping.
---@param err string?
---@param detail table?
---@return string
local function launch_err_code(err, detail)
  if type(detail) == "table" and type(detail.code) == "string" then
    return detail.code
  end
  if tostring(err):match("not found") then return "not_found" end
  return "exec_failed"
end

local function h_start(args)
  local exec, errenv = exec_or_err(); if not exec then return errenv end
  if type(args.name) ~= "string" or args.name == "" then
    return err_response("invalid_args", "args.name must be a non-empty string")
  end
  local trust_err = check_exec_trust(args.name)
  if trust_err then return trust_err end
  local opts = {}
  if type(args.profile) == "string" and args.profile ~= "" then
    opts.profile = args.profile
  end
  if type(args.args) == "table" then opts.args = args.args end
  if args.strategy ~= nil then
    if args.strategy ~= "run" and args.strategy ~= "term" and args.strategy ~= "dap" then
      return err_response("invalid_args",
        "args.strategy must be one of run|term|dap")
    end
    opts.strategy = args.strategy
  end
  local launched, err, detail = exec.start(args.name, opts)
  if not launched then
    return err_response(launch_err_code(err, detail), tostring(err))
  end
  return ok_response(launched)
end

local function h_test_run(args)
  local exec, errenv = exec_or_err(); if not exec then return errenv end

  -- Phase 3 extension: a discovered position id (mutually exclusive
  -- with the Phase 2 config-name form). Same run.exec trust gate —
  -- checked against the position id.
  if args.position ~= nil then
    if type(args.position) ~= "string" or args.position == "" then
      return err_response("invalid_args", "args.position must be a non-empty string")
    end
    if args.name ~= nil then
      return err_response("invalid_args",
        "args.name and args.position are mutually exclusive")
    end
    local trust_err = check_exec_trust(args.position)
    if trust_err then return trust_err end
    local discovery, derr = discovery_or_err(); if not discovery then return derr end
    local launched, err = discovery.run_position(args.position)
    if not launched then
      local code = tostring(err):match("not found") and "not_found" or "exec_failed"
      return err_response(code, tostring(err))
    end
    return ok_response(launched)
  end

  if type(args.name) ~= "string" or args.name == "" then
    return err_response("invalid_args", "args.name must be a non-empty string")
  end
  local trust_err = check_exec_trust(args.name)
  if trust_err then return trust_err end
  local opts = {}
  if type(args.profile) == "string" and args.profile ~= "" then
    opts.profile = args.profile
  end
  if args.package ~= nil then
    if type(args.package) ~= "string" or args.package == "" then
      return err_response("invalid_args", "args.package must be a non-empty string")
    end
    opts.package = args.package
  end
  if args.test_name ~= nil then
    if type(args.test_name) ~= "string" or args.test_name == "" then
      return err_response("invalid_args", "args.test_name must be a non-empty string")
    end
    opts.test_name = args.test_name
  end
  local launched, err, detail = exec.test_run(args.name, opts)
  if not launched then
    local code = launch_err_code(err, detail)
    if tostring(err):match("kind=test configs only") then code = "invalid_args" end
    return err_response(code, tostring(err))
  end
  return ok_response(launched)
end

local function h_debug_start(args)
  local exec, errenv = exec_or_err(); if not exec then return errenv end
  if type(args.name) ~= "string" or args.name == "" then
    return err_response("invalid_args", "args.name must be a non-empty string")
  end
  local trust_err = check_exec_trust(args.name)
  if trust_err then return trust_err end
  local opts = { strategy = "dap" }
  if type(args.profile) == "string" and args.profile ~= "" then
    opts.profile = args.profile
  end
  local launched, err, detail = exec.start(args.name, opts)
  if not launched then
    return err_response(launch_err_code(err, detail), tostring(err))
  end
  return ok_response(launched)
end

local function h_stop(args)
  local exec, errenv = exec_or_err(); if not exec then return errenv end
  if type(args.id) ~= "string" or args.id == "" then
    return err_response("invalid_args", "args.id must be a non-empty string")
  end
  local oks, err = exec.stop(args.id)
  if not oks then
    return err_response("not_found", tostring(err))
  end
  return ok_response({ stopped = args.id })
end

local function h_jobs(_args)
  local exec, errenv = exec_or_err(); if not exec then return errenv end
  local okl, jobs = pcall(exec.list)
  if not okl then return err_response("internal_error", tostring(jobs)) end
  return ok_response({ count = #jobs, jobs = jobs })
end

-- ── command specs ───────────────────────────────────────────────

---@type table<string, table>
local SPECS = {
  ["run.list"] = {
    owner       = OWNER,
    description = "List run configs (both store tiers + launch.json shims while read-through is active). Slim projection {name, kind, runtime, tags, layers, origin, error?}; deterministic tier-then-filename order. Full merged shape via run.show.",
    schema      = {},
    handler     = h_list,
  },
  ["run.show"] = {
    owner       = OWNER,
    description = "Fetch one config's EFFECTIVE (7-layer merged) record plus layer + per-field provenance. Optional `profile` selects the env profile applied as merge layer 5. Extends cycles / dangling targets surface as structured errors.",
    schema      = { name = "string", profile = "string?" },
    handler     = h_show,
  },
  ["run.profiles_list"] = {
    owner       = OWNER,
    description = "List env profiles across both tiers: {name, tiers}. Profiles carry secret NAMES/refs only — never values.",
    schema      = {},
    handler     = h_profiles_list,
  },
  ["run.status"] = {
    owner       = OWNER,
    description = "Resolver + store status for the current anchor: both tier paths, origin (override|derived), launch.json read-through state, config/profile counts, known dirs, `jobs` — the LIVE (still-running) job projections (no env values) — and `breakpoints` (store stats; `error` set when the persisted file is corrupt).",
    schema      = {},
    handler     = h_status,
  },
  ["run.validate"] = {
    owner       = OWNER,
    description = "Schema-check every config + profile file in both tiers and run extends-chain resolution (cycles, dangling targets). Returns {ok, checked, issues[]}.",
    schema      = {},
    handler     = h_validate,
  },

  ["run.tests_list"] = {
    owner       = OWNER,
    description = "Discovered test-position tree for the current worktree (ADR-0048 §7): {root, files, positions, tree}. Nodes are {id, type=dir|file|namespace|test, name, path, lnum, adapter, children}; ids are `path` / `path::ns::name`. Covers open buffers by default — a prior full scan (:AutoRun scan / the tests panel) widens it. Read-only; never launches anything.",
    schema      = {},
    handler     = h_tests_list,
  },
  ["run.results"] = {
    owner       = OWNER,
    description = "Last test results keyed by position id: {root, count, results = {<id> = {status=passed|failed|skipped|running, duration_ms?, output?}}}. Container positions (namespace/file/dir) carry upward-aggregated statuses. Never includes env values.",
    schema      = {},
    handler     = h_results,
  },

  ["run.add"] = {
    owner       = OWNER,
    description = "Create a run config. `config` is the full record (name + kind required). `tier` defaults to tracked when inside a git repo; `overwrite=true` replaces a same-tier file. Data mutation only — never starts anything.",
    schema      = { config = "any", tier = "string?", overwrite = "boolean?" },
    handler     = h_add,
  },
  ["run.update"] = {
    owner       = OWNER,
    description = "Patch a config. Write-routing per ADR-0048 §3.1: lands on the highest writable layer (shared-local file, else shared overrides.json) and reports which (`layer` in the response). launch.json shims are read-only → code=import_required.",
    schema      = { name = "string", patch = "any" },
    handler     = h_update,
  },
  ["run.remove"] = {
    owner       = OWNER,
    description = "Delete a config file (shared tier preferred unless `tier` given); the overrides.json entry is dropped once no tier holds the name.",
    schema      = { name = "string", tier = "string?" },
    handler     = h_remove,
  },
  ["run.set_dir"] = {
    owner       = OWNER,
    description = "Override the shared-local store dir for the anchor's repo (mirrors todos.set_dir). Pass `path = nil`/empty to clear. Returns the re-resolved dirs {tracked, shared, origin}.",
    schema      = { path = "string?" },
    handler     = h_set_dir,
  },
  ["run.import"] = {
    owner       = OWNER,
    description = "Import launch.json entries into the TRACKED tier with origin=launch.json. Optional `name` imports one entry; `on_conflict` ∈ overwrite|skip|rename (default skip) resolves same-name collisions. Returns {imported, skipped, renamed, errors, source}.",
    schema      = { name = "string?", on_conflict = "string?" },
    handler     = h_import,
  },

  -- Execution-starting verbs (trust-gated, ADR-0048 §11). None of
  -- these schemas may EVER grow a force/bypass flag — the mailbox
  -- path is hard-wired force-incapable.
  ["run.start"] = {
    owner       = OWNER,
    description = "TRUST-GATED (auto-core.trust capability run.exec, checked against the config name; enable interactively in the host — never via mailbox). Launch a config with its kind's default strategy (run→run, debug→dap, test→run) or an explicit `strategy` ∈ run|term|dap. Returns the launch descriptor; job records never carry env values.",
    schema      = { name = "string", profile = "string?", args = "any?", strategy = "string?" },
    handler     = h_start,
  },
  ["run.test_run"] = {
    owner       = OWNER,
    description = "TRUST-GATED (run.exec). Two forms: `name` runs a kind=test CONFIG (optional `package` overrides the package under test, `test_name` adds -run ^name$ — Phase 2 form); `position` runs a DISCOVERED position id from run.tests_list (test/file/namespace/dir — Phase 3 form). The forms are mutually exclusive. Results arrive asynchronously via run.results / run.results:changed.",
    schema      = { name = "string?", position = "string?", profile = "string?", package = "string?", test_name = "string?" },
    handler     = h_test_run,
  },
  ["run.debug_start"] = {
    owner       = OWNER,
    description = "TRUST-GATED (run.exec). Start a nvim-dap session for a config (strategy forced to dap). Requires nvim-dap in the host.",
    schema      = { name = "string", profile = "string?" },
    handler     = h_debug_start,
  },

  ["run.stop"] = {
    owner       = OWNER,
    description = "UNGATED control verb (ADR-0048 §11): stopping a live job is a safety operation. Only ever terminates jobs auto-run itself started this session — unknown or foreign ids return not_found.",
    schema      = { id = "string" },
    handler     = h_stop,
  },
  ["run.jobs"] = {
    owner       = OWNER,
    description = "Read-only session job inventory (live + exited): {id, config, strategy, cmd, pid, dir, started_at, exited, code, signal}. Never includes env values.",
    schema      = {},
    handler     = h_jobs,
  },
}

M._SPECS = SPECS  -- exposed for tests / introspection

---Register every run.* command against the auto-core mailbox command
---registry. Idempotent — safe on every setup (re-registering with the
---same owner replaces the spec).
---@return { registered: string[], skipped: string[] }
function M.register_all()
  local okc, core = pcall(require, "auto-core")
  local out = { registered = {}, skipped = {} }
  if not (okc and core and core.mailbox and core.mailbox.commands) then
    for name in pairs(SPECS) do out.skipped[#out.skipped + 1] = name end
    table.sort(out.skipped)
    return out
  end
  for name, spec in pairs(SPECS) do
    local okr, regerr = core.mailbox.commands.register(name, spec)
    if okr then
      out.registered[#out.registered + 1] = name
    else
      out.skipped[#out.skipped + 1] = name
      require("auto-run.log").warn("mailbox",
        string.format("register('%s') failed: %s", name, tostring(regerr)))
    end
  end
  table.sort(out.registered)
  table.sort(out.skipped)
  return out
end

return M