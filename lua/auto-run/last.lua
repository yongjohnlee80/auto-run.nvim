---auto-run.last — what "Again" replays (`<leader>rl` / `<leader>rL`,
---ADR 0199 §4.2a).
---
---One record per mode, `run` and `debug`, written at the TRUE launch boundary
---by the primitives themselves — so a run started from the tests pane, a
---keymap or a command all count:
---  run    `exec.start` once its job / terminal / session is up, and
---         `discovery.run_position` once a job spawned;
---  debug  when a launch reaches nvim-dap: `dap.debug_start`'s `dap.run` (or,
---         on the async path, the `dap.launch` after the adapter's prepare),
---         `dap.debug_test`'s dap-go call, `discovery.debug_position`'s launch.
---Never at the synchronous return of an async prepare, which can still fail
---or be cancelled: a debug that never launched is never replayed.
---
---A record is a DESCRIPTOR, not a closure or a resolved job — a position id or
---a config name, the options to pass again, and the anchor it ran under — so a
---replay re-resolves config, env and selections as they are now. A target that
---no longer exists, or a replay after the active worktree changed, is refused
---with a message naming what and where; nothing is silently substituted.
---@module 'auto-run.last'

local M = {}

---@class AutoRunLastDescriptor
---@field via "position"|"config"|"test_config"
---@field id string?        position id (via = position)
---@field name string?      config name (via = config | test_config)
---@field opts table?       options to pass again (callbacks stripped)
---@field path string?      test_config debug: the file dap-go resolved the test in
---@field lnum integer?     test_config debug: the cursor line it resolved from
---@field anchor string?    the store anchor's root when it launched (filled in by record)

---@type table<"run"|"debug", AutoRunLastDescriptor?>
local _last = { run = nil, debug = nil }

---The root every execution path resolves from: the active worktree, else the
---cwd (store.paths).
---@return string
local function current_anchor()
  local dirs = require("auto-run.store").resolve_run_dirs()
  return dirs.root or dirs.anchor
end

---Drop callbacks: they belong to the invocation that passed them.
---@param opts table?
---@return table?
local function replayable(opts)
  if type(opts) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(opts) do
    if type(v) ~= "function" then out[k] = v end
  end
  return next(out) and out or nil
end

---Record the operation that just launched. Called by the primitives only.
---@param mode "run"|"debug"
---@param desc AutoRunLastDescriptor  (anchor is filled in here)
function M.record(mode, desc)
  local d = vim.deepcopy(desc)
  d.opts = replayable(desc.opts)
  d.anchor = current_anchor()
  _last[mode] = d
end

---A copy of the current record, or nil.
---@param mode "run"|"debug"
---@return AutoRunLastDescriptor?
function M.peek(mode)
  return _last[mode] and vim.deepcopy(_last[mode]) or nil
end

---Replay the last `mode` operation, re-resolved against the current state.
---@param mode "run"|"debug"
---@return any ok, string? err
function M.replay(mode)
  local d = _last[mode]
  local verb = mode == "run" and "run" or "debug"
  if not d then return nil, "nothing to " .. verb .. " again yet" end

  local here = current_anchor()
  if d.anchor ~= here then
    return nil, ("the last %s was in %s, but the active worktree is now %s — switch back, or start it anew")
      :format(verb, d.anchor, here)
  end

  if d.via == "position" then
    -- A position that is gone is refused by the primitive itself, with the
    -- actionable message (how to widen discovery).
    local disc = require("auto-run.discovery")
    if mode == "run" then return disc.run_position(d.id, d.opts) end
    return disc.debug_position(d.id)
  end

  -- Checked BEFORE anything else happens: a test-config debug jumps to the
  -- file first, so a vanished config must be refused before it moves you.
  if d.name ~= nil then
    local ok, eff = pcall(require("auto-run.store").get, d.name)
    if not (ok and eff) then
      return nil, ("the last %s config '%s' no longer exists"):format(verb, d.name)
    end
  end
  if mode == "run" then
    return require("auto-run.exec").start(d.name, d.opts)
  end
  local dap_bridge = require("auto-run.dap")
  if d.via == "test_config" then
    -- dap-go resolves the test from the cursor, so replay from where it was.
    if d.path then
      local oke, eerr = pcall(function()
        vim.cmd.edit(vim.fn.fnameescape(d.path))
        if d.lnum then vim.api.nvim_win_set_cursor(0, { d.lnum, 0 }) end
      end)
      if not oke then return nil, "could not return to the last debugged test: " .. tostring(eerr) end
    end
    return dap_bridge.debug_test(d.name, d.opts)
  end
  return dap_bridge.debug_start(d.name, d.opts)
end

---Test-only: forget both records.
function M._reset_for_tests()
  _last = { run = nil, debug = nil }
end

return M
