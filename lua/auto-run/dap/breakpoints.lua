---auto-run.dap.breakpoints — per-repo breakpoint persistence
---(ADR-0048 §9, incl. the r3 amendment).
---
---**Store:** ALWAYS `resolve_run_dirs().shared .. "/breakpoints.json"`
---(via `store.paths.breakpoints_file`) — one store per repo in both
---layouts (`<container>/.auto-run/breakpoints.json` for linked
---worktrees, `<repo>/.auto-run/local/breakpoints.json` for plain
---repos). Records: `{ path, lnum, condition?, hit_condition?,
---log_message?, enabled }` with `path` relative to the worktree root
---so one saved set rehydrates in whichever worktree is active
---(absolute paths are kept verbatim for files outside the root).
---Writes are atomic (`fs.atomic`).
---
---**Save:** auto-run's own API mutations (`toggle`/`set`/`clear_all`)
---persist synchronously. Direct nvim-dap mutations are caught by the
---**reconcile sweep** — a diff of `dap.breakpoints.get()` against the
---store at the §9 sync points: debounced CursorHold, BufWritePost on
---buffers with known breakpoints, dap session start/stop, and a
---synchronous VimLeavePre flush. Contract: eventual consistency at
---sync points. Loaded buffers are the diff scope — live state wins
---for them; persisted entries for files with no loaded buffer are
---left untouched.
---
---**Tuning (r3):** `breakpoint_sync = { cursorhold = true,
---interval_ms = nil }`. `cursorhold = false` disables the
---editing-time sweep (CursorHold + BufWritePost); `interval_ms`
---adds a periodic sweep. Session-boundary and VimLeavePre flushes
---stay active even when both are disabled.
---
---**Restore:** BufReadPost applies matching records via
---`dap.breakpoints.set` (the persistent-breakpoints.nvim approach).
---Stale records (`lnum` beyond the buffer) are dropped with a
---one-line warn log — never silently kept.
---@module 'auto-run.dap.breakpoints'

local fs_path = require("auto-core.fs.path")
local fs_atomic = require("auto-core.fs.atomic")
local log = require("auto-run.log")

local M = {}

local AUGROUP = "AutoRunBreakpoints"
local LISTENER_KEY = "auto-run-breakpoints"

-- ── events ──────────────────────────────────────────────────────

local function publish(action, count, extra)
  local payload = vim.tbl_extend("force", { action = action, count = count }, extra or {})
  local ok, events = pcall(require, "auto-core.events")
  if ok and events then pcall(events.publish, "run.breakpoints:changed", payload) end
end

-- ── store IO ────────────────────────────────────────────────────

---@class AutoRunBreakpoint
---@field path string          worktree-relative (absolute when outside the root)
---@field lnum integer
---@field condition string?
---@field hit_condition string?
---@field log_message string?
---@field enabled boolean

---The §9 store file — always the shared tier.
---@return string
local function store_file()
  local paths = require("auto-run.store.paths")
  return paths.breakpoints_file(paths.resolve_run_dirs().shared)
end

---Anchor root for relative paths (active worktree).
---@return string
local function worktree_root()
  local dirs = require("auto-run.store.paths").resolve_run_dirs()
  return dirs.root or dirs.anchor
end

---@param abs string
---@param root string
---@return string
local function to_rel(abs, root)
  if root and root ~= "" and abs:sub(1, #root + 1) == (root .. "/") then
    return abs:sub(#root + 2)
  end
  return abs
end

---@param rel string
---@param root string
---@return string
local function to_abs(rel, root)
  if rel:sub(1, 1) == "/" then return rel end
  return fs_path.join(root, rel)
end

---Read the persisted records. `(list, err)` — a missing file is an
---empty list.
---@return AutoRunBreakpoint[] records, string? err
function M.read()
  local file = store_file()
  local f = io.open(file, "r")
  if not f then return {}, nil end
  local content = f:read("*a")
  f:close()
  local okd, data = pcall(vim.json.decode, content)
  if not okd or type(data) ~= "table" then
    return {}, "invalid JSON in " .. file
  end
  local list = data.breakpoints
  return type(list) == "table" and list or {}, nil
end

local function sort_records(list)
  table.sort(list, function(a, b)
    if a.path == b.path then return (a.lnum or 0) < (b.lnum or 0) end
    return tostring(a.path) < tostring(b.path)
  end)
  return list
end

---Atomically write the store.
---@param records AutoRunBreakpoint[]
---@return boolean ok, string? err
local function write(records)
  sort_records(records)
  return fs_atomic.write(store_file(),
    vim.json.encode({ version = 1, breakpoints = records }) .. "\n",
    { mkdir = true })
end

---Comparable projection (drops vim.NIL noise, normalizes shape).
---@param records AutoRunBreakpoint[]
---@return table[]
local function comparable(records)
  local out = {}
  for _, r in ipairs(records) do
    out[#out + 1] = {
      path          = r.path,
      lnum          = r.lnum,
      condition     = (r.condition ~= vim.NIL) and r.condition or nil,
      hit_condition = (r.hit_condition ~= vim.NIL) and r.hit_condition or nil,
      log_message   = (r.log_message ~= vim.NIL) and r.log_message or nil,
      enabled       = r.enabled ~= false,
    }
  end
  return sort_records(out)
end

-- ── live snapshot + reconcile sweep ─────────────────────────────

---Snapshot the live nvim-dap breakpoint registry as store records,
---plus the set of loaded file-buffer paths (the diff scope).
---@return AutoRunBreakpoint[]? live, table<string, boolean>? loaded_paths
local function snapshot()
  local ok, dap_bps = pcall(require, "dap.breakpoints")
  if not ok then return nil, nil end
  local root = worktree_root()

  local loaded_paths = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local bname = vim.api.nvim_buf_get_name(bufnr)
      if bname ~= "" and not bname:match("^%w+://") then
        loaded_paths[to_rel(fs_path.normalize(bname), root)] = true
      end
    end
  end

  local live = {}
  for bufnr, bps in pairs(dap_bps.get()) do
    local bname = vim.api.nvim_buf_get_name(bufnr)
    if bname ~= "" and not bname:match("^%w+://") then
      local rel = to_rel(fs_path.normalize(bname), root)
      for _, bp in ipairs(bps) do
        live[#live + 1] = {
          path          = rel,
          lnum          = bp.line,
          condition     = bp.condition,
          hit_condition = bp.hitCondition,
          log_message   = bp.logMessage,
          enabled       = true,
        }
      end
    end
  end
  return live, loaded_paths
end

---The reconcile sweep (§9): diff live nvim-dap state against the
---persisted store. Live state wins for every path with a loaded
---buffer; entries for unloaded files are kept as-is. Writes (and
---publishes `run.breakpoints:changed`) only when something changed.
---@return boolean changed, integer count
function M.reconcile()
  local live, loaded_paths = snapshot()
  if live == nil then return false, 0 end

  local persisted, rerr = M.read()
  if rerr then
    -- Never rebuild the store from loaded-buffer state when the
    -- persisted file failed to parse — that would overwrite entries
    -- for unloaded files. Surfaces via stats()/doctor instead.
    log.warn("breakpoints", "reconcile skipped: " .. tostring(rerr))
    return false, 0
  end
  local next_records = {}
  for _, rec in ipairs(persisted) do
    if type(rec.path) == "string" and not loaded_paths[rec.path] then
      next_records[#next_records + 1] = rec
    end
  end
  vim.list_extend(next_records, live)

  if vim.deep_equal(comparable(persisted), comparable(next_records)) then
    return false, #next_records
  end
  local okw, werr = write(next_records)
  if not okw then
    log.warn("breakpoints", "store write failed: " .. tostring(werr))
    return false, #next_records
  end
  publish("reconcile", #next_records)
  log.debug("breakpoints", "reconciled " .. #next_records .. " record(s)")
  return true, #next_records
end

-- ── API mutations (persist synchronously) ───────────────────────

---Toggle a breakpoint at the cursor (routes through nvim-dap so live
---sessions are notified), then persist synchronously.
---@param opts { condition: string?, hit_condition: string?, log_message: string? }?
---@return boolean? ok, string? err
function M.toggle(opts)
  opts = opts or {}
  local okd, dap = pcall(require, "dap")
  if not okd then return nil, "nvim-dap is not installed" end
  dap.toggle_breakpoint(opts.condition, opts.hit_condition, opts.log_message)
  M.reconcile()
  return true, nil
end

---Set (replace) a breakpoint at the cursor, then persist.
---@param opts { condition: string?, hit_condition: string?, log_message: string? }?
---@return boolean? ok, string? err
function M.set(opts)
  opts = opts or {}
  local okd, dap = pcall(require, "dap")
  if not okd then return nil, "nvim-dap is not installed" end
  dap.set_breakpoint(opts.condition, opts.hit_condition, opts.log_message)
  M.reconcile()
  return true, nil
end

---Clear EVERY breakpoint — the live registry and the whole persisted
---store (including entries for files not currently loaded).
---@return boolean? ok, string? err
function M.clear_all()
  local okd, dap = pcall(require, "dap")
  if not okd then return nil, "nvim-dap is not installed" end
  dap.clear_breakpoints()
  local okw, werr = write({})
  if not okw then return nil, werr end
  publish("clear", 0)
  return true, nil
end

---Store stats for `:AutoRun doctor` / `run.status`. `error` carries
---the read failure (e.g. invalid JSON) so a corrupt store never
---masquerades as "0 breakpoints".
---@return { file: string, count: integer, files: integer, error: string? }
function M.stats()
  local records, rerr = M.read()
  local files = {}
  for _, r in ipairs(records) do
    if type(r.path) == "string" then files[r.path] = true end
  end
  local nfiles = 0
  for _ in pairs(files) do nfiles = nfiles + 1 end
  return { file = store_file(), count = #records, files = nfiles, error = rerr }
end

-- ── restore (BufReadPost) ───────────────────────────────────────

---Apply persisted breakpoints to one freshly-read buffer. Relative
---paths are re-anchored at the ACTIVE worktree root, so a set saved
---in one worktree rehydrates in a sibling. Stale records (lnum
---beyond the buffer) are dropped from the store with a warn log.
---@param bufnr integer
---@return integer applied
function M.restore(bufnr)
  local okb, dap_bps = pcall(require, "dap.breakpoints")
  if not okb then return 0 end
  if not vim.api.nvim_buf_is_valid(bufnr) then return 0 end
  local bname = vim.api.nvim_buf_get_name(bufnr)
  if bname == "" or bname:match("^%w+://") then return 0 end

  local records, rerr = M.read()
  if rerr then
    -- A corrupt store must never be applied OR rewritten here (the
    -- stale-drop path below writes); leave the file untouched.
    log.warn("breakpoints", "restore skipped: " .. tostring(rerr))
    return 0
  end
  if #records == 0 then return 0 end
  local root = worktree_root()
  local abs = fs_path.normalize(bname)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local applied, kept, dropped = 0, {}, 0
  for _, rec in ipairs(records) do
    local mine = type(rec.path) == "string" and to_abs(rec.path, root) == abs
    if not mine then
      kept[#kept + 1] = rec
    elseif type(rec.lnum) ~= "number" or rec.lnum > line_count then
      dropped = dropped + 1
      log.warn("breakpoints", ("dropped stale breakpoint %s:%s (buffer has %d lines)")
        :format(rec.path, tostring(rec.lnum), line_count))
    else
      kept[#kept + 1] = rec
      if rec.enabled ~= false then
        dap_bps.set({
          condition     = (rec.condition ~= vim.NIL) and rec.condition or nil,
          hit_condition = (rec.hit_condition ~= vim.NIL) and rec.hit_condition or nil,
          log_message   = (rec.log_message ~= vim.NIL) and rec.log_message or nil,
        }, bufnr, rec.lnum)
        applied = applied + 1
      end
    end
  end

  if dropped > 0 then
    local okw, werr = write(kept)
    if okw then
      publish("remove", #kept, { path = to_rel(abs, root) })
    else
      log.warn("breakpoints", "stale-drop store write failed: " .. tostring(werr))
    end
  end
  return applied
end

-- ── sync-point wiring ───────────────────────────────────────────

---Debounce timer for the editing-time sweep. Single uv timer,
---restarted on every trigger (vim.defer_fn is uncancelable — the
---returned id is nil — so a real uv timer is required here).
---@type uv.uv_timer_t|nil
local _debounce_timer = nil

local function cancel_debounce()
  if _debounce_timer then
    pcall(function()
      _debounce_timer:stop()
      _debounce_timer:close()
    end)
    _debounce_timer = nil
  end
end

local function debounced_reconcile()
  local cfg = require("auto-run.config").options.breakpoint_sync
  cancel_debounce()
  _debounce_timer = vim.uv.new_timer()
  _debounce_timer:start(cfg.debounce_ms or 500, 0, vim.schedule_wrap(function()
    cancel_debounce()
    M.reconcile()
  end))
end

---Does this buffer hold known breakpoints (live registry or the
---persisted store)? Gates the BufWritePost sweep trigger.
---@param bufnr integer
---@return boolean
local function buffer_has_known_breakpoints(bufnr)
  local okb, dap_bps = pcall(require, "dap.breakpoints")
  if okb then
    local live = dap_bps.get(bufnr)
    for _, bps in pairs(live) do
      if #bps > 0 then return true end
    end
  end
  local bname = vim.api.nvim_buf_get_name(bufnr)
  if bname == "" then return false end
  local rel = to_rel(fs_path.normalize(bname), worktree_root())
  for _, rec in ipairs(M.read()) do
    if rec.path == rel then return true end
  end
  return false
end

---@type uv.uv_timer_t|nil
local _interval_timer = nil

local function stop_interval()
  if _interval_timer then
    pcall(function()
      _interval_timer:stop()
      _interval_timer:close()
    end)
    _interval_timer = nil
  end
end

---Restore into every already-loaded file buffer — the lazy-load
---fallback ([[auto-core-maintenance]] #10): when auto-run is loaded
---after VimEnter, BufReadPost for the initial buffers has already
---fired.
local function restore_loaded()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      pcall(M.restore, bufnr)
    end
  end
end

---Wire the §9 sync points. Idempotent (augroup cleared, dap listener
---keys replaced). Safe without nvim-dap — every path degrades to a
---quiet no-op.
function M.setup()
  local cfg = require("auto-run.config").options.breakpoint_sync
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  -- Restore on read.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    desc = "auto-run: restore persisted breakpoints",
    callback = function(ev)
      pcall(M.restore, ev.buf)
    end,
  })

  -- Editing-time sweep (tunable; cursorhold=false disables BOTH
  -- CursorHold and BufWritePost triggers — the r3 "full disable").
  if cfg.cursorhold ~= false then
    vim.api.nvim_create_autocmd("CursorHold", {
      group = group,
      desc = "auto-run: debounced breakpoint reconcile sweep",
      callback = debounced_reconcile,
    })
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      desc = "auto-run: breakpoint sweep on write (buffers with known breakpoints)",
      callback = function(ev)
        if buffer_has_known_breakpoints(ev.buf) then
          debounced_reconcile()
        end
      end,
    })
  end

  -- Optional periodic sweep.
  stop_interval()
  if type(cfg.interval_ms) == "number" and cfg.interval_ms > 0 then
    _interval_timer = vim.uv.new_timer()
    _interval_timer:start(cfg.interval_ms, cfg.interval_ms,
      vim.schedule_wrap(function() M.reconcile() end))
  end

  -- Exit flush — SYNCHRONOUS, always active ([[auto-core-maintenance]]
  -- #9: the debounce above is deferred IO; this is its mandatory
  -- VimLeavePre flush).
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    desc = "auto-run: synchronous breakpoint flush on exit",
    callback = function()
      cancel_debounce()
      stop_interval()
      pcall(M.reconcile)
    end,
  })

  -- Session-boundary flushes — always active, even when the
  -- editing-time sweep is disabled.
  local okd, dap = pcall(require, "dap")
  if okd then
    dap.listeners.before.launch[LISTENER_KEY] = function() pcall(M.reconcile) end
    dap.listeners.before.attach[LISTENER_KEY] = function() pcall(M.reconcile) end
    dap.listeners.after.event_terminated[LISTENER_KEY] = function()
      vim.schedule(function() pcall(M.reconcile) end)
    end
    dap.listeners.after.event_exited[LISTENER_KEY] = function()
      vim.schedule(function() pcall(M.reconcile) end)
    end
  end

  -- Lazy-load fallback (#10): restore for buffers that were read
  -- before this plugin loaded.
  if vim.v.vim_did_enter == 1 then
    restore_loaded()
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      group = group,
      once = true,
      callback = restore_loaded,
    })
  end
end

return M