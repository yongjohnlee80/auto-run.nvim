---auto-run.dap — the nvim-dap bridge (ADR-0048 §6).
---
---Responsibilities:
---
---   • **Provider registration** — `dap.providers.configs["auto-run"]`
---     emits store configs with function-valued LAZY fields, resolved
---     (merge → substitution → env composition) only when nvim-dap
---     actually evaluates them. `dap.configurations` is NEVER mutated.
---   • **Translation** — effective config → dap config. Go is
---     first-class (type/mode/buildFlags mapping); every other
---     runtime is a generic passthrough (`type = runtime`).
---   • **debug_test parity** — gobugger's `dap_go.debug_test(cfg)`
---     merge semantics: buildFlags + env (env_files are already part
---     of the composed env — the envFile contract) from the effective
---     config; test selection stays with dap-go's cursor treesitter.
---   • **attach / attach_remote** — the connect-only `go_attach`
---     server adapter (default port 2345) so nvim-dap never races a
---     pre-running dlv by spawning its own.
---   • **UI wiring** — winfixbuf guard before event_stopped, dap-view
---     auto open/close, failed-start stderr capture with scratch-
---     buffer replay (gobugger errors.lua port).
---
---All entry points degrade to `(nil, err)` when nvim-dap (or dap-go)
---is absent — never a hard require at module load. Composed env
---values are handed to dap configs only; they never reach logs,
---events, or the failed-start capture buffers.
---@module 'auto-run.dap'

local log = require("auto-run.log")

local M = {}

local LISTENER_KEY = "auto-run"

-- ── events ──────────────────────────────────────────────────────

local function publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events then pcall(events.publish, topic, payload) end
end

-- ── dap-view (auto open/close — gobugger ui.lua port) ──────────

---Open nvim-dap-view before a session starts. Invoking explicitly at
---the launch call sites (in addition to the before.launch/attach
---listeners) makes the open deterministic even if a user overrides
---those listeners. Respects `dap.view = false`.
local function open_view()
  local cfg = require("auto-run.config").options
  if cfg.dap.view == false then return end
  local ok, dv = pcall(require, "dap-view")
  if ok then pcall(dv.open) end
end

local function setup_dap_view(dap)
  local view_opt = require("auto-run.config").options.dap.view
  if view_opt == false then return end
  local dv_ok, dv = pcall(require, "dap-view")
  if not dv_ok then return end

  local dv_opts
  if type(view_opt) == "table" then
    dv_opts = view_opt
  else
    -- Opinionated defaults (gobugger parity).
    dv_opts = {
      winbar = {
        show = true,
        sections = {
          "watches", "scopes", "exceptions",
          "breakpoints", "threads", "repl",
        },
        default_section = "scopes",
      },
      windows = {
        size = 12,
        terminal = { position = "right" },
      },
    }
  end
  pcall(dv.setup, dv_opts)

  local key = LISTENER_KEY .. "-dap-view"
  dap.listeners.before.attach[key]           = function() dv.open() end
  dap.listeners.before.launch[key]           = function() dv.open() end
  dap.listeners.before.event_terminated[key] = function() dv.close() end
  dap.listeners.before.event_exited[key]     = function() dv.close() end
end

-- ── winfixbuf guard (gobugger ui.lua port) ──────────────────────

---When DAP hits a breakpoint it calls nvim_win_set_buf on the current
---window to show the source. If that window has `winfixbuf` set
---(neo-tree, dap-view panel, help buffers, …) the set-buf fails with
---E1513 and the whole jump_to_frame chain explodes. Before
---event_stopped fires jump_to_frame, bounce focus to a regular
---editing window — opening one if the tab has none.
local function setup_winfixbuf_guard(dap)
  dap.listeners.before.event_stopped[LISTENER_KEY .. "-avoid-winfixbuf"] = function()
    if not vim.wo.winfixbuf then return end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if not vim.wo[win].winfixbuf and vim.bo[buf].buftype == "" then
        vim.api.nvim_set_current_win(win)
        return
      end
    end
    vim.cmd("topleft new")
  end
end

-- ── failed-start error capture (gobugger errors.lua port) ───────

-- Per-session accumulators. Reset on every launch/attach.
local err_lines = {}
local initialized = false
-- Last *failed* session's captured output.
local last_failure = nil

local function append_err(chunk)
  if type(chunk) ~= "string" or chunk == "" then return end
  table.insert(err_lines, chunk)
end

local function flush_if_failed(reason_prefix)
  if initialized then return end
  if #err_lines == 0 then return end

  last_failure = {
    text = table.concat(err_lines),
    at = os.date("%H:%M:%S"),
  }

  local full = last_failure.text
  local preview = full
  local trailer = ""
  if #full > 600 then
    preview = full:sub(1, 600)
    trailer = "\n\n...(truncated; :AutoRun last-error for full output)"
  end

  vim.schedule(function()
    log.error("dap", ("%s\n\n%s%s"):format(reason_prefix, preview, trailer))
  end)
end

local function setup_error_capture(dap)
  local key = LISTENER_KEY .. "-errors"

  dap.listeners.before.launch[key] = function()
    err_lines = {}
    initialized = false
  end
  dap.listeners.before.attach[key] = function()
    err_lines = {}
    initialized = false
  end
  dap.listeners.after.event_initialized[key] = function()
    initialized = true
  end
  -- stderr + console stream (stdout is the DAP protocol channel;
  -- build errors from delve arrive on stderr).
  dap.listeners.after.event_output[key] = function(_, body)
    if not body or initialized then return end
    local cat = body.category or ""
    if cat == "stderr" or cat == "console" or cat == "important" then
      append_err(body.output)
    end
  end
  dap.listeners.after.event_terminated[key] = function()
    flush_if_failed("debug session failed to start")
  end
  dap.listeners.after.event_exited[key] = function(_, body)
    local code = body and body.exitCode or "?"
    flush_if_failed(("adapter exited with code %s before initializing")
      :format(tostring(code)))
  end
end

---Full text of the last failed-start capture, or nil if none yet.
---@return string?
function M.last_error()
  return last_failure and last_failure.text or nil
end

---Open the last captured failure text in a scratch buffer for
---scrolling / copy-paste.
---@return boolean opened
function M.open_last_error()
  local txt = M.last_error()
  if not txt or txt == "" then
    log.info("dap", "no captured error output yet")
    return false
  end
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(txt, "\n", { plain = true }))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "log"
  pcall(vim.api.nvim_buf_set_name, buf,
    ("auto-run://last-error-%s"):format(last_failure.at))
  return true
end

-- ── run.session:changed events ──────────────────────────────────

local function session_payload(session, state)
  local id, config_name
  if type(session) == "table" then
    id = session.id
    config_name = type(session.config) == "table" and session.config.name or nil
  end
  return { id = tostring(id or "?"), config = config_name, state = state }
end

local function setup_session_events(dap)
  local key = LISTENER_KEY .. "-session-events"
  dap.listeners.after.event_initialized[key] = function(session)
    publish("run.session:changed", session_payload(session, "running"))
  end
  dap.listeners.after.event_terminated[key] = function(session)
    publish("run.session:changed", session_payload(session, "terminated"))
  end
  dap.listeners.after.event_exited[key] = function(session)
    publish("run.session:changed", session_payload(session, "exited"))
  end
end

-- ── translation (effective config → dap config) ─────────────────

---Runtime → dap `type`. Go is first-class; anything else passes
---through as-is (the user's dap.adapters entry is the contract).
---@param runtime string?
---@return string
local function dap_type(runtime)
  return runtime or "go"
end

---Translate one effective config into a fully-resolved dap config
---(merge → substitution → env composition all applied eagerly).
---@param name string
---@param opts { profile: string?, args: table? }?
---@return table? dap_cfg, string? err, table? detail
function M.translate(name, opts)
  opts = opts or {}
  local store = require("auto-run.store")
  local eff, gerr = store.get(name, { profile = opts.profile, args = opts.args })
  if not eff then
    return nil, tostring(gerr), type(gerr) == "table" and gerr or nil
  end

  local env_mod = require("auto-run.env")
  local ctx = env_mod.context()
  eff = env_mod.substitute_deep(eff, ctx)
  local comp, cerr = env_mod.compose(eff, { ctx = ctx })
  if not comp then
    return nil, cerr and cerr.message or "env composition failed", cerr
  end

  local dap_cfg
  if eff.runtime == "go" or eff.runtime == nil then
    dap_cfg = {
      type    = "go",
      request = "launch",
      mode    = eff.kind == "test" and "test" or "debug",
      name    = eff.name,
      program = eff.program,
      cwd     = eff.cwd,
    }
    if type(eff.args) == "table" and #eff.args > 0 then
      dap_cfg.args = eff.args
    end
    if type(eff.build_flags) == "string" and eff.build_flags ~= "" then
      dap_cfg.buildFlags = eff.build_flags
    end
  else
    -- Generic passthrough for other runtimes.
    dap_cfg = {
      type    = dap_type(eff.runtime),
      request = "launch",
      name    = eff.name,
      program = eff.program,
      cwd     = eff.cwd,
    }
    if type(eff.args) == "table" and #eff.args > 0 then
      dap_cfg.args = eff.args
    end
  end
  if next(comp.env) ~= nil then
    dap_cfg.env = comp.env
  end
  return dap_cfg, nil
end

-- ── provider (dap.providers.configs — NEVER dap.configurations) ──

---The registered provider function. Emits one entry per store config
---whose runtime matches the buffer's filetype (kind debug/run — test
---configs go through debug_test), with function-valued LAZY fields:
---nothing is merged/substituted/composed until nvim-dap evaluates
---the picked config's fields.
---@param bufnr integer
---@return table[]
function M.provider(bufnr)
  local ok, store = pcall(require, "auto-run.store")
  if not ok then return {} end
  local ft = vim.bo[bufnr].filetype
  local out = {}
  for _, c in ipairs(store.list()) do
    if not c.error and (c.kind == "debug" or c.kind == "run")
        and (c.runtime or "go") == ft then
      local cfg_name = c.name
      local resolved, resolve_err
      local function field(key)
        return function()
          if resolved == nil and resolve_err == nil then
            local cfg, terr = M.translate(cfg_name)
            resolved, resolve_err = cfg or false, terr
          end
          if not resolved then
            error("auto-run: " .. tostring(resolve_err))
          end
          return resolved[key]
        end
      end
      out[#out + 1] = {
        type    = dap_type(c.runtime),
        request = "launch",
        name    = "[auto-run] " .. cfg_name,
        mode    = field("mode"),
        program = field("program"),
        args    = field("args"),
        cwd     = field("cwd"),
        env     = field("env"),
        buildFlags = field("buildFlags"),
      }
    end
  end
  return out
end

-- ── launch flows ────────────────────────────────────────────────

---Start a dap session for a (kind=debug|run) config.
---@param name string
---@param opts { profile: string?, args: table? }?
---@return boolean? ok, string? err, table? detail
function M.debug_start(name, opts)
  local okd, dap = pcall(require, "dap")
  if not okd then return nil, "nvim-dap is not installed" end
  local cfg, terr, detail = M.translate(name, opts)
  if not cfg then return nil, terr, detail end
  open_view()
  local okr, rerr = pcall(dap.run, cfg)
  if not okr then return nil, "dap.run: " .. tostring(rerr) end
  return true, nil
end

---Debug the test under the cursor with the effective config's
---buildFlags/env (incl. env_files — the envFile contract) merged in
---via `dap_go.debug_test(cfg)` — gobugger parity, validated against
---the go-test-env skill's emitted configs. Test selection
---(`-test.run ^Name$`) is always driven by dap-go at runtime from
---the cursor position. `name = nil` falls through to dap-go's
---defaults (no buildFlags / env overrides).
---@param name string?  kind=test config name
---@param opts { profile: string?, args: table? }?
---@return boolean? ok, string? err, table? detail
function M.debug_test(name, opts)
  opts = opts or {}
  local okg, dap_go = pcall(require, "dap-go")
  if not okg then return nil, "nvim-dap-go is not installed" end

  local custom
  if name ~= nil then
    local store = require("auto-run.store")
    local eff, gerr = store.get(name, { profile = opts.profile, args = opts.args })
    if not eff then
      return nil, tostring(gerr), type(gerr) == "table" and gerr or nil
    end
    if eff.kind ~= "test" then
      return nil, "debug_test needs a kind=test config (got kind="
        .. tostring(eff.kind) .. ")"
    end
    local env_mod = require("auto-run.env")
    local ctx = env_mod.context()
    eff = env_mod.substitute_deep(eff, ctx)
    local comp, cerr = env_mod.compose(eff, { ctx = ctx })
    if not comp then
      return nil, cerr and cerr.message or "env composition failed", cerr
    end
    custom = {}
    if type(eff.build_flags) == "string" and eff.build_flags ~= "" then
      custom.buildFlags = eff.build_flags
    end
    if next(comp.env) ~= nil then
      custom.env = comp.env
    end
    if next(custom) == nil then custom = nil end
  end

  open_view()
  local okr, rerr = pcall(dap_go.debug_test, custom)
  if not okr then return nil, "dap_go.debug_test: " .. tostring(rerr) end
  return true, nil
end

---Attach to a local process via delve: runs dap-go's registered
---"Attach" config (processId PID picker). gobugger keymap parity.
---@return boolean? ok, string? err
function M.attach()
  local okd, dap = pcall(require, "dap")
  if not okd then return nil, "nvim-dap is not installed" end
  for _, cfg in ipairs(dap.configurations.go or {}) do
    if cfg.name == "Attach" then
      open_view()
      local okr, rerr = pcall(dap.run, cfg)
      if not okr then return nil, "dap.run: " .. tostring(rerr) end
      return true, nil
    end
  end
  return nil, "no 'Attach' config found in dap.configurations.go — "
    .. "is dap-go.setup() running?"
end

---Connect to a pre-running `dlv --headless --listen=:PORT` server
---(gobugger attach_remote port). Registers `dap.adapters.go_attach`
---as a pure server adapter — no `executable`, so nvim-dap just
---TCP-connects instead of racing the existing dlv by spawning its
---own (dap-go's default `go` adapter always spawns `dlv dap`).
---@param port number?  dlv listen port; prompts when nil (default 2345)
---@return boolean? ok, string? err
function M.attach_remote(port)
  local okd, dap = pcall(require, "dap")
  if not okd then return nil, "nvim-dap is not installed" end
  if not dap.adapters.go_attach then
    dap.adapters.go_attach = function(cb, cfg)
      cb({ type = "server", host = cfg.host or "127.0.0.1", port = cfg.port or 2345 })
    end
  end

  if port == nil then
    local input = vim.fn.input("dlv server port: ", "2345")
    port = tonumber(input)
    if not port then
      return nil, "invalid port"
    end
  end

  open_view()
  local okr, rerr = pcall(dap.run, {
    type = "go_attach",
    name = ("Attach remote :%d"):format(port),
    mode = "remote",
    request = "attach",
    host = "127.0.0.1",
    port = port,
    -- dlv's --api-version=2 DAP bridge errors on
    -- setExceptionBreakpoints; an empty list skips the request.
    exceptionBreakpoints = {},
  })
  if not okr then return nil, "dap.run: " .. tostring(rerr) end
  return true, nil
end

-- ── doctor surface ──────────────────────────────────────────────

---Structured dap health snapshot for `:AutoRun doctor`.
---@return table
function M.health()
  local okd, dap = pcall(require, "dap")
  local okg = pcall(require, "dap-go")
  local okv = pcall(require, "dap-view")
  local adapters = {}
  if okd then
    for adapter_name in pairs(dap.adapters or {}) do
      adapters[#adapters + 1] = adapter_name
    end
    table.sort(adapters)
  end
  return {
    dap_installed      = okd,
    dap_go_installed   = okg,
    dap_view_installed = okv,
    adapters           = adapters,
    go_adapter         = okd and dap.adapters.go ~= nil or false,
    provider_registered = okd and dap.providers.configs["auto-run"] ~= nil or false,
    last_error_captured = last_failure ~= nil,
  }
end

-- ── setup ───────────────────────────────────────────────────────

---Wire the dap bridge. Idempotent (listener keys + provider slot are
---replaced, never stacked); silently a no-op when nvim-dap is not
---installed.
---@return boolean wired
function M.setup()
  local okd, dap = pcall(require, "dap")
  if not okd then return false end

  -- Provider registration (§6): providers.configs is the sanctioned
  -- extension point; dap.configurations is never mutated.
  dap.providers.configs["auto-run"] = M.provider

  -- dap-go registers its default `dap.configurations.go` entries
  -- ("Debug", "Attach", …) from inside its setup(); attach() needs
  -- them. Idempotent, so calling unconditionally is safe.
  local dg_ok, dg = pcall(require, "dap-go")
  if dg_ok and type(dg.setup) == "function" then
    pcall(dg.setup)
  end

  setup_dap_view(dap)
  setup_winfixbuf_guard(dap)
  setup_error_capture(dap)
  setup_session_events(dap)
  return true
end

return M