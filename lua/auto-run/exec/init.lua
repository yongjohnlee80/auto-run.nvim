---auto-run.exec — the execution facade (ADR-0048 §6).
---
---Public flows:
---
---   start(name, opts)     launch a config with its resolved strategy
---   test_run(name, opts)  Phase 2 test surface: kind=test CONFIGS
---                         only (plain `go test` on the configured
---                         package, or the dap-go debug-test path
---                         with `debug = true`). Discovered test
---                         positions are Phase 3.
---   stop(id) / list()     job control — jobs auto-run started ONLY
---   pick_config(...)      mode-filtered pick with per-repo memory
---                         (gobugger session-pick parity, persisted
---                         in the shared tier's state.json)
---
---Every launch: effective config via `store.get` (7-layer merge) →
---uniform substitution → env composition (Phase 1 pipeline, incl.
---the trust-gated `command_env` stage) → strategy dispatch. Errors
---are `(nil, message, detail?)` — `detail` is the structured compose
---error table when composition failed (mailbox handlers map its
---`code` to envelope codes). Secret values never appear in returns,
---logs, or events.
---@module 'auto-run.exec'

local fs_path = require("auto-core.fs.path")
local job = require("auto-run.exec.job")
local strategies = require("auto-run.exec.strategies")
local log = require("auto-run.log")

local M = {}

M.job = job
M.strategies = strategies

-- re-exports (one obvious surface for callers)
M.register_terminal_provider = strategies.register_terminal_provider
M.generate_run_id = job.generate_run_id

-- ── session launch memory (module-local, declared before any
--    closure that captures it — [[auto-core-maintenance]] #8) ─────

---Last successful launch `{ name, opts }` (for run_last).
---@type { name: string, opts: table }|nil
local _last_launch = nil

---One-shot profile override set by `<leader>rp` (consumed by the
---next start() whose opts carry no explicit profile).
---@type string|nil
local _next_profile = nil

---Set (or clear with nil) the env profile applied to the NEXT launch
---that doesn't pass an explicit `opts.profile`.
---@param name string|nil
function M.set_next_profile(name)
  if name ~= nil and (type(name) ~= "string" or name == "") then
    error("set_next_profile: name must be a non-empty string or nil")
  end
  _next_profile = name
end

-- ── launch preparation (shared by every strategy) ───────────────

---Resolve name → effective config, substitute uniformly, compose the
---environment. `(prep, nil, nil)` or `(nil, err, detail?)`.
---@param name string
---@param opts table
---@return { eff: table, ctx: table, comp: table }? prep, string? err, table? detail
local function prepare(name, opts)
  if type(name) ~= "string" or name == "" then
    return nil, "config name must be a non-empty string"
  end
  local store = require("auto-run.store")
  local eff, gerr = store.get(name, { profile = opts.profile, args = opts.args })
  if not eff then
    -- Structured store errors (e.g. overrides_corrupt) ride along as
    -- `detail` so mailbox handlers can map their code.
    return nil, tostring(gerr), type(gerr) == "table" and gerr or nil
  end
  -- Selected launch config (Config section) as the active base.
  eff = require("auto-run.import").apply_selected_base(eff)

  local env_mod = require("auto-run.env")
  local ctx = env_mod.context()
  local substituted = env_mod.substitute_deep(eff, ctx)
  local comp, cerr = env_mod.compose(substituted, { ctx = ctx })
  if not comp then
    return nil, cerr and cerr.message or "env composition failed", cerr
  end
  return { eff = substituted, ctx = ctx, comp = comp }, nil, nil
end

---Build the argv for a run-strategy launch.
---@param eff table   substituted effective config
---@param opts { package: string?, test_name: string? }
---@return string[]? argv, string? err
local function build_argv(eff, opts)
  if eff.kind == "test" and (eff.runtime == "go" or eff.runtime == nil) then
    -- Plain test run: `go test` on the configured package (Phase 2
    -- scope — position-level selection arrives with Phase 3).
    local argv = { "go", "test" }
    if type(eff.build_flags) == "string" and eff.build_flags ~= "" then
      for _, flag in ipairs(vim.split(eff.build_flags, "%s+", { trimempty = true })) do
        argv[#argv + 1] = flag
      end
    end
    if type(opts.test_name) == "string" and opts.test_name ~= "" then
      argv[#argv + 1] = "-run"
      argv[#argv + 1] = "^" .. opts.test_name .. "$"
    end
    argv[#argv + 1] = opts.package or eff.program or "./..."
    for _, a in ipairs(eff.args or {}) do argv[#argv + 1] = a end
    return argv, nil
  end

  if type(eff.program) ~= "string" or eff.program == "" then
    return nil, "config '" .. tostring(eff.name) .. "' has no program to run"
  end
  local argv = { eff.program }
  for _, a in ipairs(eff.args or {}) do argv[#argv + 1] = a end
  return argv, nil
end

---Working dir for a launch: the config's cwd, else the anchor's
---worktree root.
---@param eff table
---@return string?
local function launch_cwd(eff)
  if type(eff.cwd) == "string" and eff.cwd ~= "" then return eff.cwd end
  local dirs = require("auto-run.store").resolve_run_dirs()
  return dirs.root or dirs.anchor
end

-- ── start ───────────────────────────────────────────────────────

---@class AutoRunStartOpts
---@field profile string?      env-profile override (merge layer 5)
---@field args table?          invocation-args fragment (merge layer 7)
---@field strategy string?     per-launch strategy override (run|term|dap)
---@field debug boolean?       kind=test: pick the dap debug-test path
---@field package string?      kind=test (go): override the package under test
---@field test_name string?    kind=test (go): -run ^name$ filter
---@field timeout_ms integer?  job timeout — NO default for user launches
---@field on_exit fun(rec: table)?

---Launch a config. Strategy = the config kind's default unless
---overridden (§6). Returns a launch descriptor:
---
---   run  → the job record projection ({ id, pid, dir, ... })
---   term → { id, strategy = "term", provider = source }
---   dap  → { strategy = "dap", config = name }
---@param name string
---@param opts AutoRunStartOpts?
---@return table? launched, string? err, table? detail
function M.start(name, opts)
  opts = opts or {}
  -- One-shot profile override (<leader>rp): consumed by the first
  -- launch that doesn't pass its own profile.
  if opts.profile == nil and _next_profile ~= nil then
    opts = vim.tbl_extend("force", {}, opts, { profile = _next_profile })
    _next_profile = nil
  end
  -- Kind is needed before prepare() so dap delegation happens before
  -- env composition (the dap bridge composes on its own path).
  local store = require("auto-run.store")
  local eff0, gerr = store.get(name, { profile = opts.profile, args = opts.args })
  if not eff0 then
    return nil, tostring(gerr), type(gerr) == "table" and gerr or nil
  end

  local strategy, serr = strategies.resolve(eff0.kind, opts)
  if not strategy then return nil, serr end

  -- Replay memory for run_last (callbacks stripped — they belong to
  -- the original invocation only).
  local replay_opts = {}
  for k, v in pairs(opts) do
    if k ~= "on_exit" then replay_opts[k] = v end
  end

  if strategy == "dap" then
    local dap_bridge = require("auto-run.dap")
    if eff0.kind == "test" then
      local okd, derr, detail = dap_bridge.debug_test(name, opts)
      if not okd then return nil, derr, detail end
    else
      local okd, derr, detail = dap_bridge.debug_start(name, opts)
      if not okd then return nil, derr, detail end
    end
    M.remember_pick(eff0.kind, name)
    _last_launch = { name = name, opts = replay_opts }
    return { strategy = "dap", config = name }, nil
  end

  local prep, perr, detail = prepare(name, opts)
  if not prep then return nil, perr, detail end
  local argv, aerr = build_argv(prep.eff, opts)
  if not argv then return nil, aerr end
  local cwd = launch_cwd(prep.eff)
  local run_id = job.generate_run_id()

  if strategy == "term" then
    local env_mod = require("auto-run.env")
    local env_file
    if next(prep.comp.env) ~= nil then
      local path, m_err = env_mod.materialize(run_id, prep.comp.env)
      if not path then return nil, m_err end
      env_file = path
    end
    -- §4.1 cleanup hook: handed to the provider as `spec.on_exit` so
    -- the materialized env file dies with the terminal session; also
    -- invoked directly when the provider refuses the launch.
    -- Idempotent (discard is best-effort). A provider that accepts
    -- but never calls it leaves the file to the startup sweep.
    local function cleanup()
      if env_file then env_mod.discard(run_id) end
    end
    local provider, source = strategies.terminal_provider()
    local spec = {
      cmd      = argv,
      cmdline  = strategies.render_cmdline(argv, env_file),
      cwd      = cwd,
      env      = next(prep.comp.env) ~= nil and prep.comp.env or nil,
      env_file = env_file,
      config   = name,
      run_id   = run_id,
      on_exit  = cleanup,
    }
    local okp, p_err = provider(spec)
    if not okp then
      cleanup()  -- provider failure: the env file is discarded NOW
      return nil, p_err or "terminal provider failed"
    end
    M.remember_pick(prep.eff.kind, name)
    _last_launch = { name = name, opts = replay_opts }
    log.debug("exec", ("term launch %s via %s provider"):format(run_id, source))
    return { id = run_id, strategy = "term", provider = source, config = name }, nil
  end

  -- strategy == "run"
  local launched, sp_err = job.spawn({
    id         = run_id,
    cmd        = argv,
    config     = name,
    strategy   = "run",
    cwd        = cwd,
    env        = next(prep.comp.env) ~= nil and prep.comp.env or nil,
    timeout_ms = opts.timeout_ms,
    on_exit    = opts.on_exit,
  })
  if not launched then return nil, sp_err end
  M.remember_pick(prep.eff.kind, name)
  _last_launch = { name = name, opts = replay_opts }
  return launched, nil
end

---Re-run the most recent auto-run launch (any strategy). When this
---session hasn't launched anything yet, falls back to nvim-dap's
---`run_last()` — the gobugger `<leader>dr` behavior the `<leader>rl`
---binding inherits.
---@return table? launched, string? err, table? detail
function M.run_last()
  if _last_launch then
    return M.start(_last_launch.name, _last_launch.opts)
  end
  local okd, dap = pcall(require, "dap")
  if okd and type(dap.run_last) == "function" then
    local okr, rerr = pcall(dap.run_last)
    if not okr then return nil, "dap.run_last: " .. tostring(rerr) end
    return { strategy = "dap" }, nil
  end
  return nil, "nothing to re-run yet (no launch this session)"
end

-- ── test_run (Phase 2 scope: kind=test configs only) ────────────

---Run a kind=test config. `opts.debug = true` routes through the
---dap-go debug-test parity path; otherwise a plain `go test` job on
---the configured package. Discovered positions are Phase 3 — a
---non-test config is a structured error here.
---@param name string
---@param opts AutoRunStartOpts?
---@return table? launched, string? err, table? detail
function M.test_run(name, opts)
  opts = opts or {}
  local store = require("auto-run.store")
  local eff, gerr = store.get(name, { profile = opts.profile, args = opts.args })
  if not eff then
    return nil, tostring(gerr), type(gerr) == "table" and gerr or nil
  end
  if eff.kind ~= "test" then
    return nil, "run.test_run supports kind=test configs only in Phase 2 "
      .. "(config '" .. name .. "' is kind=" .. tostring(eff.kind) .. ")"
  end
  return M.start(name, opts)
end

-- ── job control ─────────────────────────────────────────────────

---Stop a running job. Only ever terminates jobs auto-run started —
---unknown/foreign ids are a not-found error (ADR §11).
---@param id string
---@return boolean? ok, string? err
function M.stop(id)
  return job.stop(id)
end

---Session job inventory. See `exec.job.list`.
---@param opts { active_only: boolean? }?
---@return table[]
function M.list(opts)
  return job.list(opts)
end

-- ── pick memory (gobugger session-pick parity, per repo) ────────

---Shared-tier state.json accessors — the store owns the one
---read/write pair (the env module's selection memory shares the same
---file; [[shared-resolver-single-source-of-truth]]).
---@return table state
local function read_state()
  return require("auto-run.store").read_state()
end

---@param state table
local function write_state(state)
  require("auto-run.store").write_state(state)
end

---Remember the last-picked config for a kind (persisted per repo in
---the shared tier's state.json). Best-effort + silent.
---@param kind string?
---@param name string
function M.remember_pick(kind, name)
  if type(kind) ~= "string" or type(name) ~= "string" then return end
  pcall(function()
    local state = read_state()
    state.picks = type(state.picks) == "table" and state.picks or {}
    if state.picks[kind] == name then return end
    state.picks[kind] = name
    write_state(state)
  end)
end

---Snapshot of the remembered per-repo picks (`kind → config name`,
---from the shared tier's state.json). Diagnostic surface for the
---doctor's per-kind config listing. Best-effort — `{}` on any error.
---@return table<string, string>
function M.picks()
  local out = {}
  pcall(function()
    local picks = read_state().picks
    if type(picks) == "table" then
      for k, v in pairs(picks) do
        if type(k) == "string" and type(v) == "string" then out[k] = v end
      end
    end
  end)
  return out
end

---Clear the remembered pick for one kind (nil clears all).
---@param kind string?
function M.clear_pick(kind)
  pcall(function()
    local state = read_state()
    if kind == nil then
      state.picks = nil
    elseif type(state.picks) == "table" then
      state.picks[kind] = nil
    end
    write_state(state)
  end)
end

---Mode-filtered config pick with per-repo memory. Resolution order:
---remembered pick (when it still matches) → single match → prompt
---via `vim.ui.select` (remembering the choice). The callback gets
---`(name, reason?)` — `name = nil` with reason `"no_matches"` or
---`"cancelled"`.
---@param kind string|string[]  config kind(s) to include
---@param cb fun(name: string?, reason: string?)
function M.pick_config(kind, cb)
  local kinds = {}
  for _, k in ipairs(type(kind) == "table" and kind or { kind }) do
    kinds[k] = true
  end
  local store = require("auto-run.store")
  local matches = {}
  for _, c in ipairs(store.list()) do
    if not c.error and kinds[c.kind] then matches[#matches + 1] = c.name end
  end
  if #matches == 0 then
    cb(nil, "no_matches")
    return
  end

  local remembered
  pcall(function()
    local picks = read_state().picks
    if type(picks) == "table" then
      for k in pairs(kinds) do
        local p = picks[k]
        if p and vim.tbl_contains(matches, p) then remembered = p break end
      end
    end
  end)
  if remembered then
    cb(remembered)
    return
  end
  if #matches == 1 then
    cb(matches[1])
    return
  end

  vim.ui.select(matches, { prompt = "auto-run: pick a config" }, function(choice)
    if not choice then
      cb(nil, "cancelled")
      return
    end
    cb(choice)
  end)
end

return M