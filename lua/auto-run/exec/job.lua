---auto-run.exec.job — the vim.system job engine (ADR-0048 §6).
---
---Every job auto-run starts gets:
---
---   • a run id (path-safe, sortable, unique per session),
---   • a per-run dir `<runs_dir>/<run-id>/` holding `stdout`,
---     `stderr` (streamed as chunks arrive — human-visible output)
---     and `result.json` (the machine-readable result channel,
---     separate from day one per neotest pitfall #2/#3),
---   • a row in the module-local job table — `list()`/`stop()` see
---     ONLY jobs this engine started; foreign pids are unreachable
---     by construction,
---   • `run.job:started` / `run.job:exited` events.
---
---Callbacks follow the ADR-0035 pattern: `vim.schedule`-wrapped exit
---handling, structured events, NO default timeout for user-launched
---runs (`spec.timeout_ms` opts in only when the caller sets it).
---
---Secrets: composed env VALUES are handed to `vim.system` and never
---stored on the job record, logged, or included in events / `list()`
---projections — the record keeps nothing env-related at all.
---@module 'auto-run.exec.job'

local fs_path = require("auto-core.fs.path")
local log = require("auto-run.log")

local M = {}

-- ── events ──────────────────────────────────────────────────────

local function publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events then pcall(events.publish, topic, payload) end
end

-- ── run ids + dirs ──────────────────────────────────────────────

local _seq = 0

---Generate a path-safe, sortable run id (unique within the session).
---@return string
function M.generate_run_id()
  _seq = _seq + 1
  return ("r%s-%04d"):format(os.date("%Y%m%d-%H%M%S"), _seq)
end

---Resolved per-run output root (`stdpath("cache")/auto-run/runs` or
---the configured override). Never inside a repo.
---@return string
function M.runs_dir()
  local cfg = require("auto-run.config").options
  return cfg.exec.runs_dir or (vim.fn.stdpath("cache") .. "/auto-run/runs")
end

---One run's output dir.
---@param run_id string
---@return string
function M.run_dir(run_id)
  return fs_path.join(M.runs_dir(), run_id)
end

-- ── job table ───────────────────────────────────────────────────

---@class AutoRunJobRecord
---@field id string
---@field config string        config name
---@field strategy string      "run" (dap/term jobs live elsewhere)
---@field cmd string[]         argv (never contains composed env values)
---@field cwd string?
---@field pid integer?
---@field dir string           per-run output dir
---@field started_at string    ISO-8601 UTC
---@field exited boolean
---@field code integer?        exit code (once exited)
---@field signal integer?      terminating signal (once exited)
---@field finished_at string?

---id → record. Module-local: the ONLY registry `stop()`/`list()`
---consult, so auto-run can never signal a process it didn't start.
---@type table<string, AutoRunJobRecord>
local _jobs = {}

---handles are kept out of the public record shape.
---@type table<string, vim.SystemObj>
local _handles = {}

local function utc_now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

---Public projection of one record (copy; no handle, no env).
---@param rec AutoRunJobRecord
---@return table
local function project(rec)
  return {
    id          = rec.id,
    config      = rec.config,
    strategy    = rec.strategy,
    cmd         = vim.deepcopy(rec.cmd),
    cwd         = rec.cwd,
    pid         = rec.pid,
    dir         = rec.dir,
    started_at  = rec.started_at,
    exited      = rec.exited,
    code        = rec.code,
    signal      = rec.signal,
    finished_at = rec.finished_at,
  }
end

-- ── output streaming ────────────────────────────────────────────

---Open one append-target file inside the run dir. `(fd, err)`.
---@param dir string
---@param name string
---@return integer? fd, string? err
local function open_stream(dir, name)
  local fd, oerr = vim.uv.fs_open(fs_path.join(dir, name), "w",
    tonumber("644", 8))
  if not fd then return nil, "fs_open(" .. name .. "): " .. tostring(oerr) end
  return fd, nil
end

---vim.system stream callback writing chunks to `fd` as they arrive
---(runs on the loop thread; sync fs_write is fast-context safe).
---@param fd integer
---@return fun(err: string?, data: string?)
local function stream_to(fd)
  return function(_, data)
    if data then pcall(vim.uv.fs_write, fd, data, -1) end
  end
end

-- ── spawn ───────────────────────────────────────────────────────

---@class AutoRunSpawnSpec
---@field cmd string[]                 argv
---@field config string                config name (event/diagnostic key)
---@field strategy string?             defaults to "run"
---@field cwd string?
---@field env table<string, string>?   composed env (merged over the process env)
---@field id string?                   pre-generated run id (default: generate)
---@field timeout_ms integer?          NO default — user-launched runs never time out
---@field on_exit fun(rec: table)?     called (scheduled) after the record is final

---Start a background job. Creates the per-run dir, streams stdout /
---stderr to files, registers the job, publishes `run.job:started`,
---and finalizes (result.json + `run.job:exited` + env discard) on
---exit. Returns the public record projection or `(nil, err)`.
---@param spec AutoRunSpawnSpec
---@return table? job, string? err
function M.spawn(spec)
  if type(spec) ~= "table" or type(spec.cmd) ~= "table" or #spec.cmd == 0 then
    return nil, "spawn: spec.cmd must be a non-empty argv list"
  end
  if type(spec.config) ~= "string" or spec.config == "" then
    return nil, "spawn: spec.config must be a non-empty string"
  end

  local id = spec.id or M.generate_run_id()
  if _jobs[id] then return nil, "spawn: run id '" .. id .. "' already exists" end
  local dir = M.run_dir(id)
  local okm, merr = pcall(vim.fn.mkdir, dir, "p")
  if not okm then return nil, "mkdir(" .. dir .. "): " .. tostring(merr) end

  local out_fd, oerr = open_stream(dir, "stdout")
  if not out_fd then return nil, oerr end
  local err_fd, eerr = open_stream(dir, "stderr")
  if not err_fd then
    pcall(vim.uv.fs_close, out_fd)
    return nil, eerr
  end

  local rec = {
    id         = id,
    config     = spec.config,
    strategy   = spec.strategy or "run",
    cmd        = vim.deepcopy(spec.cmd),
    cwd        = spec.cwd,
    dir        = dir,
    started_at = utc_now(),
    exited     = false,
  }

  local sys_opts = {
    cwd    = spec.cwd,
    env    = spec.env,          -- values go to the process ONLY
    stdout = stream_to(out_fd),
    stderr = stream_to(err_fd),
  }
  if spec.timeout_ms ~= nil then sys_opts.timeout = spec.timeout_ms end

  local on_exit = vim.schedule_wrap(function(res)
    pcall(vim.uv.fs_close, out_fd)
    pcall(vim.uv.fs_close, err_fd)
    rec.exited      = true
    rec.code        = res.code
    rec.signal      = res.signal
    rec.finished_at = utc_now()
    _handles[id] = nil

    -- Machine-readable result channel (never mixes with stdout).
    local result = {
      id          = rec.id,
      config      = rec.config,
      strategy    = rec.strategy,
      cmd         = rec.cmd,
      cwd         = rec.cwd,
      code        = rec.code,
      signal      = rec.signal,
      started_at  = rec.started_at,
      finished_at = rec.finished_at,
    }
    local okw, werr = pcall(function()
      local f = assert(io.open(fs_path.join(dir, "result.json"), "w"))
      f:write(vim.json.encode(result))
      f:write("\n")
      f:close()
    end)
    if not okw then
      log.warn("exec", "result.json write failed for " .. id .. ": " .. tostring(werr))
    end

    -- §4.1: the materialized env file (if any) dies with the run.
    pcall(function() require("auto-run.env").discard(id) end)

    publish("run.job:exited", {
      id = rec.id, config = rec.config, code = rec.code, signal = rec.signal,
    })
    log.debug("exec", ("job %s exited code=%s signal=%s")
      :format(id, tostring(rec.code), tostring(rec.signal)))
    if type(spec.on_exit) == "function" then
      pcall(spec.on_exit, project(rec))
    end
  end)

  local oks, handle_or_err = pcall(vim.system, spec.cmd, sys_opts, on_exit)
  if not oks then
    pcall(vim.uv.fs_close, out_fd)
    pcall(vim.uv.fs_close, err_fd)
    return nil, "vim.system: " .. tostring(handle_or_err)
  end

  rec.pid = handle_or_err.pid
  _jobs[id] = rec
  _handles[id] = handle_or_err

  publish("run.job:started", {
    id = id, config = rec.config, strategy = rec.strategy, pid = rec.pid,
  })
  log.debug("exec", ("job %s started (config=%s pid=%s)")
    :format(id, rec.config, tostring(rec.pid)))
  return project(rec), nil
end

-- ── stop (only ever jobs WE started) ────────────────────────────

---Terminate a running job by run id. Refuses ids the engine didn't
---start (or that already exited) with a not-found error — this is the
---§11 guarantee that `run.stop` can never signal foreign processes.
---@param id string
---@param signal integer?  default SIGTERM (15)
---@return boolean? ok, string? err
function M.stop(id, signal)
  if type(id) ~= "string" or id == "" then
    return nil, "stop: id must be a non-empty string"
  end
  local rec, handle = _jobs[id], _handles[id]
  if not rec or not handle or rec.exited then
    return nil, "job '" .. id .. "' not found among running auto-run jobs"
  end
  local okk, kerr = pcall(function() handle:kill(signal or 15) end)
  if not okk then return nil, "kill: " .. tostring(kerr) end
  log.debug("exec", "job " .. id .. " signalled (" .. tostring(signal or 15) .. ")")
  return true, nil
end

-- ── inventory ───────────────────────────────────────────────────

---Session job inventory (started-at order). `opts.active_only`
---filters to still-running jobs (the `run.status` projection).
---@param opts { active_only: boolean? }?
---@return table[]
function M.list(opts)
  opts = opts or {}
  local out = {}
  for _, rec in pairs(_jobs) do
    if not (opts.active_only and rec.exited) then
      out[#out + 1] = project(rec)
    end
  end
  table.sort(out, function(a, b)
    if a.started_at == b.started_at then return a.id < b.id end
    return a.started_at < b.started_at
  end)
  return out
end

---One job's public record.
---@param id string
---@return table? job, string? err
function M.get(id)
  local rec = _jobs[id]
  if not rec then return nil, "job '" .. tostring(id) .. "' not found" end
  return project(rec), nil
end

---Test-only: drop the session job table (running processes are not
---touched). Not part of the public API stability contract.
function M._reset_for_tests()
  _jobs, _handles = {}, {}
end

return M