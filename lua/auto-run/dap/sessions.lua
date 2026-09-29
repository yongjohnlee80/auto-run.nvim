---auto-run.dap.sessions — what a debug session is running: the program's pid,
---the port it listens on, and a journal of its output.
---
---nvim-dap keeps none of these. The program's stdout / stderr arrive as DAP
---`output` events and were shown only in dap-view's console; here they are
---also appended to a log file per session, so `tail -f` follows them and they
---survive the session. The pid comes from the adapter's `process` event when
---it sends one, else from the process tree: the adapter (found by the port it
---listens on) runs the program as its child — delve's `__debug_bin…`. The
---port is the one the program listens on, else the launch env's `PORT`.
---
---Journals live in `stdpath("state")/auto-run/sessions/`; files older than
---`M.KEEP_DAYS` are removed when the module attaches.
---@module 'auto-run.dap.sessions'

local fs_path = require("auto-core.fs.path")

local M = {}

M.KEEP_DAYS = 7
local KEY = "auto-run-sessions"

---session id → { started_at, log, fh?, pid?, ended_at? }
local _info = {}

---@return string
function M.journal_dir()
  return fs_path.join(vim.fn.stdpath("state"), "auto-run", "sessions")
end

local function safe(s)
  return (tostring(s or "session"):gsub("[^%w_%-]", "_"))
end

---The session's record, created (with its journal path) on first touch.
---@param session table
local function entry(session)
  local id = session.id
  local e = _info[id]
  if e then return e end
  local dir = M.journal_dir()
  vim.fn.mkdir(dir, "p")
  local name = type(session.config) == "table" and session.config.name or nil
  e = {
    started_at = os.time(),
    log = fs_path.join(dir, os.date("%Y%m%d-%H%M%S") .. "-" .. tostring(id) .. "-" .. safe(name) .. ".log"),
  }
  _info[id] = e
  return e
end

local function append(e, text)
  if not e.fh then
    e.fh = io.open(e.log, "a")
    if not e.fh then return end
  end
  e.fh:write(text)
  e.fh:flush()
end

local function finish(session)
  local e = session and _info[session.id]
  if not e then return end
  if e.fh then e.fh:close(); e.fh = nil end
  e.ended_at = e.ended_at or os.time()
end

---Remove journals older than `M.KEEP_DAYS`.
function M.sweep()
  local dir = M.journal_dir()
  local cutoff = os.time() - M.KEEP_DAYS * 86400
  for _, f in ipairs(vim.fn.globpath(dir, "*.log", false, true)) do
    local st = vim.uv.fs_stat(f)
    if st and st.mtime and st.mtime.sec < cutoff then os.remove(f) end
  end
end

---Hook the session listeners. Idempotent (keyed).
---@param dap table  nvim-dap
function M.attach(dap)
  dap.listeners.after.event_initialized[KEY] = function(session)
    local e = entry(session)
    append(e, "") -- create the file, so the path is real before any output
  end
  dap.listeners.after.event_output[KEY] = function(session, body)
    if type(body) ~= "table" or type(body.output) ~= "string" or body.category == "telemetry" then return end
    local text = body.output
    -- The adapter's own messages are marked, the program's are verbatim.
    if body.category == "console" or body.category == "important" then text = "[dap] " .. text end
    append(entry(session), text)
  end
  dap.listeners.after.event_process[KEY] = function(session, body)
    if type(body) == "table" and tonumber(body.systemProcessId) then
      entry(session).pid = tonumber(body.systemProcessId)
    end
  end
  dap.listeners.after.event_terminated[KEY] = function(session) finish(session) end
  dap.listeners.after.event_exited[KEY] = function(session) finish(session) end
  if type(dap.listeners.on_session) == "table" then
    dap.listeners.on_session[KEY] = function(old, new)
      if type(old) == "table" and old.closed and old ~= new then finish(old) end
    end
  end
  pcall(M.sweep)
end

-- ── the process table and listening sockets (on demand, cached 1s) ──────

local _cache = { at = 0 }

local function run(cmd)
  local ok, r = pcall(function() return vim.system(cmd, { text = true }):wait(2000) end)
  if not ok or not r or r.code ~= 0 then return nil end
  return r.stdout or ""
end

---{ procs = { {pid, ppid, command} }, listen = { [pid] = { "addr:port", … } } }
function M._snapshot()
  local now = vim.uv.now()
  if _cache.data and now - _cache.at < 1000 then return _cache.data end
  local procs = {}
  for line in (run({ "ps", "-A", "-o", "pid=,ppid=,command=" }) or ""):gmatch("[^\n]+") do
    local pid, ppid, cmd = line:match("^%s*(%d+)%s+(%d+)%s+(.*)$")
    if pid then procs[#procs + 1] = { pid = tonumber(pid), ppid = tonumber(ppid), command = cmd } end
  end
  local listen = {}
  local ss = run({ "ss", "-ltnpH" })
  if ss then
    for line in ss:gmatch("[^\n]+") do
      local fields = vim.split(line, "%s+", { trimempty = true })
      local addr = fields[4]
      for p in line:gmatch("pid=(%d+)") do
        local n = tonumber(p)
        listen[n] = listen[n] or {}
        if addr and not vim.tbl_contains(listen[n], addr) then table.insert(listen[n], addr) end
      end
    end
  else
    -- macOS / no iproute2: lsof's field output, "p<pid>" then "n<addr>" lines.
    local cur
    for line in (run({ "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn" }) or ""):gmatch("[^\n]+") do
      local kind, val = line:sub(1, 1), line:sub(2)
      if kind == "p" then
        cur = tonumber(val)
      elseif kind == "n" and cur then
        listen[cur] = listen[cur] or {}
        if not vim.tbl_contains(listen[cur], val) then table.insert(listen[cur], val) end
      end
    end
  end
  _cache = { at = now, data = { procs = procs, listen = listen } }
  return _cache.data
end

local function port_of(addr) return tonumber(tostring(addr):match(":(%d+)$")) end

---The adapter's pid: the process listening on its port.
local function adapter_pid(snap, port)
  if not port then return nil end
  for pid, addrs in pairs(snap.listen) do
    for _, a in ipairs(addrs) do if port_of(a) == port then return pid end end
  end
end

---The program the adapter runs: its child that is not the adapter binary
---itself (delve forks a telemetry helper of its own executable).
local function program_pid(snap, parent, adapter_cmd)
  if not parent then return nil end
  local own
  for _, p in ipairs(snap.procs) do
    if p.pid == parent then own = p.command:match("^(%S+)") end
  end
  for _, p in ipairs(snap.procs) do
    if p.ppid == parent then
      local exe = p.command:match("^(%S+)") or ""
      local base = vim.fn.fnamemodify(exe, ":t")
      local is_adapter = (own and vim.fn.fnamemodify(own, ":t") == base)
        or (adapter_cmd and vim.fn.fnamemodify(adapter_cmd, ":t") == base)
      if not is_adapter then return p.pid end
    end
  end
end

---What a session is running. Every field may be nil.
---@param session table  an nvim-dap session
---@return { pid: integer?, port: integer?, port_source: "listening"|"env"|nil, log: string?, started_at: integer?, ended_at: integer?, commands: { tail: string?, kill: string? } }
function M.info(session)
  local out = { commands = {} }
  if type(session) ~= "table" then return out end
  local e = _info[session.id] or {}
  out.log, out.started_at, out.ended_at = e.log, e.started_at, e.ended_at

  local pid = e.pid
  local snap = M._snapshot()
  if not pid then
    local a = type(session.adapter) == "table" and session.adapter or {}
    local cmd = a.command or (type(a.executable) == "table" and a.executable.command) or nil
    pid = program_pid(snap, adapter_pid(snap, tonumber(a.port)), cmd)
  end
  out.pid = pid

  local addrs = pid and snap.listen[pid] or nil
  if addrs and addrs[1] then
    out.port, out.port_source = port_of(addrs[1]), "listening"
  else
    local env = type(session.config) == "table" and session.config.env or nil
    local p = type(env) == "table" and tonumber(env.PORT) or nil
    if p then out.port, out.port_source = p, "env" end
  end

  if out.log then out.commands.tail = "tail -f " .. vim.fn.shellescape(out.log) end
  if pid then out.commands.kill = "kill " .. pid end
  return out
end

---Test-only.
function M._reset_for_tests()
  for _, e in pairs(_info) do if e.fh then pcall(e.fh.close, e.fh) end end
  _info = {}
  _cache = { at = 0 }
end

return M
