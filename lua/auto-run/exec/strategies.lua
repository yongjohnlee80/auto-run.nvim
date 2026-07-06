---auto-run.exec.strategies — strategy resolution + the terminal
---provider interface (ADR-0048 §6, OQ4).
---
---Strategies: `run` (background job, output to per-run files),
---`term` (interactive terminal), `dap` (nvim-dap session).
---
---Defaults by config `kind` (any launch can override):
---
---   run   → "run"
---   debug → "dap"
---   test  → "dap" when debugging the test, "run" for a plain test run
---
---Terminal strategy (OQ4 — capability probe, no hard dependency):
---the preferred provider is whatever was registered through
---`register_terminal_provider(fn)`; absent that, `auto-agents.term`
---is probed at launch time and adapted when present; the fallback is
---a plain `:split` + `jobstart(..., { term = true })`. Providers
---receive an `AutoRunTermSpec` — composed env reaches the terminal
---as a materialized 0600 env-FILE reference (auto-agents path) or a
---programmatic `env` table (builtin path); secret values never
---appear on a rendered command line.
---@module 'auto-run.exec.strategies'

local M = {}

M.STRATEGIES = { run = true, term = true, dap = true }

-- ── resolution ──────────────────────────────────────────────────

---Resolve the strategy for a launch. `opts.strategy` overrides;
---`opts.debug` selects the dap path for `kind=test`.
---@param kind string        "run"|"test"|"debug"
---@param opts { strategy: string?, debug: boolean? }?
---@return string? strategy, string? err
function M.resolve(kind, opts)
  opts = opts or {}
  if opts.strategy ~= nil then
    if not M.STRATEGIES[opts.strategy] then
      return nil, "strategy must be one of run|term|dap, got '"
        .. tostring(opts.strategy) .. "'"
    end
    return opts.strategy, nil
  end
  if kind == "debug" then return "dap", nil end
  if kind == "test" then
    return opts.debug and "dap" or "run", nil
  end
  return "run", nil
end

-- ── terminal provider interface ─────────────────────────────────

---@class AutoRunTermSpec
---@field cmd string[]                 argv
---@field cmdline string               shell-escaped one-liner (env-file sourcing prefixed when env_file is set)
---@field cwd string?
---@field env table<string, string>?   composed env (builtin provider passes it programmatically)
---@field env_file string?             materialized 0600 env file (path reference only)
---@field config string                config name
---@field run_id string
---@field on_exit fun()?               cleanup hook — providers SHOULD call it when the terminal session ends (discards the materialized env file; idempotent)

---@type (fun(spec: AutoRunTermSpec): boolean?, string?)|nil
local _provider = nil

---Register the preferred terminal provider (auto-agents' floating
---terminals plug in here). `fn(spec) → ok, err`. Pass nil to clear.
---@param fn (fun(spec: AutoRunTermSpec): boolean?, string?)|nil
function M.register_terminal_provider(fn)
  if fn ~= nil and type(fn) ~= "function" then
    error("auto-run.exec.strategies.register_terminal_provider: fn must be a function or nil")
  end
  _provider = fn
end

---auto-agents.term adapter: ensure the playground slot is open, then
---send the command line (env arrives via the sourced env FILE — the
---rendered line only ever shows the file path, never values).
---@param term table  the auto-agents.term module
---@return fun(spec: AutoRunTermSpec): boolean?, string?
local function auto_agents_provider(term)
  return function(spec)
    local slot = require("auto-run.config").options.exec.term_slot or 1
    local okg, gerr = pcall(term.get, slot)
    if not okg then return nil, "auto-agents.term.get: " .. tostring(gerr) end
    local line = spec.cmdline
    if spec.cwd then
      line = ("cd %s && %s"):format(vim.fn.shellescape(spec.cwd), line)
    end
    local oks, serr = pcall(term.send, slot, line)
    if not oks then return nil, "auto-agents.term.send: " .. tostring(serr) end
    return true, nil
  end
end

---Builtin fallback: bottom split + terminal job. env is passed
---programmatically (jobstart `env` opt), so nothing sensitive is
---rendered anywhere. The spec's cleanup hook fires when the terminal
---job exits (env-file lifecycle, §4.1).
---@param spec AutoRunTermSpec
---@return boolean? ok, string? err
local function builtin_provider(spec)
  local okc, cerr = pcall(function()
    vim.cmd("botright 15split")
    vim.cmd("enew")
    local job_opts = { term = true }
    if spec.cwd then job_opts.cwd = spec.cwd end
    if spec.env and next(spec.env) then job_opts.env = spec.env end
    if type(spec.on_exit) == "function" then
      job_opts.on_exit = function() pcall(spec.on_exit) end
    end
    local jid = vim.fn.jobstart(spec.cmd, job_opts)
    if jid <= 0 then error("jobstart failed (" .. tostring(jid) .. ")") end
  end)
  if not okc then return nil, "builtin term: " .. tostring(cerr) end
  return true, nil
end

---Resolve the active terminal provider: registered → preferred;
---else probe `auto-agents.term`; else the builtin split fallback.
---@return fun(spec: AutoRunTermSpec): boolean?, string?, string source
function M.terminal_provider()
  if _provider then return _provider, "registered" end
  local ok, term = pcall(require, "auto-agents.term")
  if ok and type(term) == "table"
      and type(term.get) == "function"
      and type(term.send) == "function" then
    return auto_agents_provider(term), "auto-agents"
  end
  return builtin_provider, "builtin"
end

---Shell-escape an argv into a one-liner, with the env-file sourcing
---prefix when a materialized file is provided (path reference only).
---@param cmd string[]
---@param env_file string?
---@return string
function M.render_cmdline(cmd, env_file)
  local parts = {}
  for _, a in ipairs(cmd) do parts[#parts + 1] = vim.fn.shellescape(a) end
  local line = table.concat(parts, " ")
  if env_file then
    line = ("set -a; . %s; set +a; %s"):format(vim.fn.shellescape(env_file), line)
  end
  return line
end

return M