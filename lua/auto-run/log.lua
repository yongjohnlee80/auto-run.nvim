---auto-run.log — single-file logging surface for the plugin.
---
---Per ADR-0021 §6 (the "wrapper rule"), every auto-family plugin owns
---exactly one `lua/<plugin>/log.lua` that delegates to `auto-core.log`.
---Feature code in auto-run calls THIS module; feature code MUST NOT
---`require("auto-core").log` directly.
---
---Degrade policy when auto-core is absent (should not happen — it is
---a hard dependency — but the wrapper never crashes over it):
---ERROR / WARN fall back to `vim.notify`; INFO / DEBUG / TRACE are
---silently dropped. auto-run keeps a silent main path (ADR-0048 §13,
---[[auto-core-maintenance]] rule #6) — informational logging must
---never surface as a toast.
---@module 'auto-run.log'

local core_log
do
  local ok, core = pcall(require, "auto-core")
  if ok and type(core) == "table" and type(core.log) == "table" then
    core_log = core.log
  end
end

local NS = "auto-run"

local M = {}

M.levels = core_log and core_log.levels or {
  ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5,
}

---Fully-qualify a component under the plugin namespace.
---@param component string?
---@return string
local function ns(component)
  if type(component) ~= "string" or component == "" then return NS end
  if component == NS or component:sub(1, #NS + 1) == (NS .. ".") then
    return component
  end
  return NS .. "." .. component
end

---Fallback for hosts without auto-core: only ERROR/WARN reach the
---user; everything else is dropped (silent-INFO policy).
---@param component string?
---@param msg string
---@param level integer  vim.log.levels value
local function _degrade(component, msg, level)
  if level ~= vim.log.levels.ERROR and level ~= vim.log.levels.WARN then
    return
  end
  vim.notify("[" .. ns(component) .. "] " .. tostring(msg), level)
end

---@param level_fn function?  auto-core level function (error/warn/…)
---@param fallback_level integer
---@param component string?
local function level_call(level_fn, fallback_level, component, ...)
  if level_fn then
    level_fn(ns(component), ...)
    return
  end
  local parts, out = { ... }, {}
  for i, p in ipairs(parts) do
    out[i] = (type(p) == "table" or type(p) == "boolean")
      and vim.inspect(p) or tostring(p)
  end
  _degrade(component, table.concat(out, " "), fallback_level)
end

function M.error(component, ...)
  level_call(core_log and core_log.error, vim.log.levels.ERROR, component, ...)
end
function M.warn(component, ...)
  level_call(core_log and core_log.warn, vim.log.levels.WARN, component, ...)
end
function M.info(component, ...)
  level_call(core_log and core_log.info, vim.log.levels.INFO, component, ...)
end
function M.debug(component, ...)
  level_call(core_log and core_log.debug, vim.log.levels.DEBUG, component, ...)
end
function M.trace(component, ...)
  level_call(core_log and core_log.trace, vim.log.levels.TRACE, component, ...)
end

return M