---auto-run.dap.dart_tests — the `dart.testNotification` bridge (ADR 0196 r3
---§2.3.1). A debugged Dart / Flutter test reports its results as DAP custom
---events, not on stdout, so without this the tests pane would show nothing for
---a test run under the debugger.
---
---  begin(pos, root)  → run id; the scope's tests turn `running`
---  launch config     → carries `autoRunRunId = <run id>` (the Dart adapter
---                      ignores unknown launch fields, verified on VM43)
---  first event       → binds `session.id` to the run (never "the latest
---                      launch", so two launches cannot cross)
---  testDone          → published at once through discovery.debug_results
---  exited/terminated/disconnect → unreported tests fill (skipped, or failed
---                      when the runner exited non-zero with no reports);
---                      state cleared. The first of them finalises; the rest
---                      find nothing and do nothing.
---
---Events of a session that never bound (foreign, or already finalised) are
---ignored. A pending run that never got a session is cleared by a launch
---failure (dap.launch aborts it), by the launch token's abort, and by its own
---expiry timer (M.EXPIRY_MS, armed at begin).
---@module 'auto-run.dap.dart_tests'

local M = {}

local KEY = "auto-run.dart_tests"
---How long a launched run may wait for its session before it is abandoned.
M.EXPIRY_MS = 10 * 60 * 1000

---run id → { scope_id, root, created }
local _pending = {}
---session.id → { run_id, scope_id, map, state, exit_code }
local _active = {}
local _seq = 0

local function discovery() return require("auto-run.discovery") end
local function dart() return require("auto-run.adapters.dart") end

---Drop pending runs that never bound to a session within the expiry.
local function sweep()
  local now = vim.uv.now()
  for rid, p in pairs(_pending) do
    if now - p.created > M.EXPIRY_MS then M.abort(rid) end
  end
end

---Start a debugged test run for `pos` (a test position) under `root`.
---@param pos table   the discovered position
---@param root string the package root
---@return string run_id
function M.begin(pos, root)
  sweep()
  _seq = _seq + 1
  local run_id = ("dart-%d-%d"):format(os.time(), _seq)
  _pending[run_id] = { scope_id = pos.id, root = root, created = vim.uv.now() }
  discovery().debug_results(pos.id, nil, { running = true })
  -- Its own expiry: a run whose session never arrives (an adapter that fails
  -- to start after dap.run returned) must not stay running until some LATER
  -- debug happens to sweep. abort() is a no-op once the run has bound.
  vim.defer_fn(function()
    if _pending[run_id] then M.abort(run_id) end
  end, M.EXPIRY_MS)
  return run_id
end

---Abandon a run that never reached a session: its running marks unwind.
---@param run_id string
function M.abort(run_id)
  local p = run_id and _pending[run_id]
  if not p then return end
  _pending[run_id] = nil
  discovery().debug_results(p.scope_id, nil, { clear = true })
end

---The run a session belongs to, binding it on first sight.
---@param session table
---@return table?
local function bind(session)
  local st = _active[session.id]
  if st then return st end
  local rid = type(session.config) == "table" and session.config.autoRunRunId or nil
  local p = rid and _pending[rid]
  if not p then return nil end
  _pending[rid] = nil
  local scope = discovery().tree():get(p.scope_id)
  st = {
    run_id = rid,
    scope_id = p.scope_id,
    map = scope and dart().scope_map(scope) or {},
    state = dart().new_state(p.root),
  }
  _active[session.id] = st
  return st
end

---One `dart.testNotification` event body (the package:test reporter event).
---@param session table
---@param body table
function M.on_notification(session, body)
  local st = bind(session)
  if not st then return end
  local key, res = dart().reconcile(st.state, body)
  if key and st.map[key] then
    discovery().debug_results(st.scope_id, { [st.map[key]] = res }, nil)
  end
end

---@param session table
---@param body table?
function M.on_exited(session, body)
  -- Bind here too: a run that failed to compile exits before any event, and
  -- its exit code is what marks it failed rather than skipped.
  local st = bind(session)
  if st and type(body) == "table" then st.exit_code = body.exitCode end
end

---Finalise a session's run: fill what was not reported, then forget it.
---@param session table
function M.finish(session)
  local st = _active[session.id]
  if not st then
    -- A session that ended before its first event still owns a pending run.
    local rid = type(session.config) == "table" and session.config.autoRunRunId or nil
    local p = rid and _pending[rid]
    if not p then return end
    _pending[rid] = nil
    st = { run_id = rid, scope_id = p.scope_id, state = { reported = false } }
  end
  _active[session.id] = nil
  -- The run_position rule: a runner that exited non-zero having reported
  -- nothing failed; otherwise unreported tests were simply not run (skipped).
  local died = (st.exit_code or 0) ~= 0 and not st.state.reported
  discovery().debug_results(st.scope_id, nil, {
    final = true,
    died = died,
    message = died and ("debug session exited code=" .. tostring(st.exit_code) .. " with no test results") or nil,
  })
end

---Install the listeners (idempotent: slot-replaced under one key).
---@param dap table
function M.attach(dap)
  dap.listeners.after["event_dart.testNotification"][KEY] = function(session, body)
    M.on_notification(session, body)
  end
  -- `exited` finalises on its own (ADR 0196 r3 §2.3.1): an adapter or
  -- connection that ends without a later terminated/disconnect must not leave
  -- the scope running. A following terminated/disconnect finds no state.
  dap.listeners.after.event_exited[KEY] = function(session, body)
    M.on_exited(session, body)
    M.finish(session)
  end
  dap.listeners.after.event_terminated[KEY] = function(session)
    M.finish(session)
  end
  dap.listeners.after.disconnect[KEY] = function(session)
    M.finish(session)
  end
end

---Test-only: inspect / reset the bridge state.
function M._state() return { pending = _pending, active = _active } end
function M._reset_for_tests() _pending, _active, _seq = {}, {}, 0 end

return M
