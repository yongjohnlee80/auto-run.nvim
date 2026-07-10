---auto-run.import — VSCode launch.json interop (ADR-0048 §5).
---
---launch.json is a READ-ONLY import source:
---
---  • **Read-through** is active ONLY while the repo has no
---    `.auto-run/` store in either tier. The moment a store exists,
---    shims go dark — entries surface only through `:AutoRun import`
---    hints. A shim and a store config can never be live together;
---    same-name collisions exist only at import time.
---  • **Import** writes tracked-tier configs stamped
---    `origin = "launch.json"`; per-entry conflict resolution
---    (overwrite / skip / rename) is a PARAMETER — interactive
---    prompting is the caller's job.
---
---Parsing reuses gobugger's proven JSONC handling (comments +
---trailing commas) and upward walk (stop at the first `.bare/` or
---`.git/` DIRECTORY; linked-worktree `.git` FILES are transparent so
---a container-level launch.json serves every worktree), plus
---nvim-dap ext/vscode lessons: current-OS block lifting and
---`inputs` → typed params.
---@module 'auto-run.import'

local fs_path = require("auto-core.fs.path")
local log = require("auto-run.log")

local M = {}

-- ── events + structured errors (mirror auto-run.env) ────────────

local function publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events then pcall(events.publish, topic, payload) end
end

local function structured_err(code, message, fields)
  local e = vim.tbl_extend("force", { code = code, message = message },
    fields or {})
  return setmetatable(e, { __tostring = function(self) return self.message end })
end

-- ── JSONC parsing ───────────────────────────────────────────────

---Strip `//` and `/* */` comments (string-literal aware).
---@param s string
---@return string
local function strip_json_comments(s)
  local out, i, n = {}, 1, #s
  local in_string, escape = false, false
  while i <= n do
    local c = s:sub(i, i)
    if in_string then
      out[#out + 1] = c
      if escape then
        escape = false
      elseif c == "\\" then
        escape = true
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "/" and s:sub(i + 1, i + 1) == "/" then
      local nl = s:find("\n", i + 2, true)
      i = nl or (n + 1)
    elseif c == "/" and s:sub(i + 1, i + 1) == "*" then
      local close = s:find("*/", i + 2, true)
      i = close and (close + 2) or (n + 1)
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

---JSONC-tolerant parse: strip comments + trailing commas, then
---strict `vim.json.decode`.
---@param content string
---@return table? data, string? err
function M.parse(content)
  content = strip_json_comments(content)
  content = content:gsub(",(%s*[%]}])", "%1")
  local okd, data = pcall(vim.json.decode, content)
  if not okd then return nil, tostring(data) end
  if type(data) ~= "table" then return nil, "launch.json is not a JSON object" end
  return data, nil
end

-- ── upward walk ─────────────────────────────────────────────────

---Find the nearest launch.json walking UP from the anchor, stopping
---at the first `.bare/` or `.git/` directory boundary (gitfiles are
---transparent).
---@param start string?  defaults to the store resolver's anchor
---@return string? path
function M.find_launch_json(start)
  local cfg = require("auto-run.config").options
  local cur = start and fs_path.normalize(start)
    or require("auto-run.store.paths").anchor()
  local seen = {}
  while cur and cur ~= "" and not seen[cur] do
    seen[cur] = true
    for _, rel in ipairs(cfg.import.launch_paths) do
      local p = fs_path.join(cur, rel)
      if fs_path.is_file(p) then return p end
    end
    if fs_path.is_dir(fs_path.join(cur, ".bare")) then break end
    if fs_path.is_dir(fs_path.join(cur, ".git")) then break end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

-- ── normalization (launch.json entry → auto-run schema) ────────

---Lift the current OS's platform block (`linux` / `osx` / `windows`)
---over the base keys — nvim-dap ext/vscode behavior.
---@param raw table
---@return table
local function lift_os_block(raw)
  local sys = vim.uv.os_uname().sysname
  local key = sys == "Darwin" and "osx"
    or (sys:match("Windows") and "windows" or "linux")
  if type(raw[key]) ~= "table" then return raw end
  local out = vim.deepcopy(raw)
  for k, v in pairs(raw[key]) do out[k] = v end
  out.linux, out.osx, out.windows = nil, nil, nil
  return out
end

---Map a launch.json `inputs` list to typed params (ADR-0048 §3 /
---nvim-dap ext/vscode `promptString` / `pickString` lifting).
---@param inputs table?
---@return table<string, table>?
local function inputs_to_params(inputs)
  if type(inputs) ~= "table" then return nil end
  local params = {}
  local any = false
  for _, input in ipairs(inputs) do
    if type(input) == "table" and type(input.id) == "string" then
      params[input.id] = {
        type        = "string",
        default     = type(input.default) == "string" and input.default or nil,
        choices     = input.type == "pickString" and input.options or nil,
        description = input.description,
      }
      any = true
    end
  end
  return any and params or nil
end

---Normalize one launch.json configuration into an auto-run config
---record. `${workspaceFolder}` is kept verbatim — it is a supported
---substitution alias, resolved uniformly at compose time.
---@param raw table
---@param params table<string, table>?
---@return table
local function normalize_entry(raw, params)
  raw = lift_os_block(raw)
  local out = {
    name    = raw.name,
    kind    = raw.mode == "test" and "test" or "debug",
    runtime = raw.type,
    origin  = "launch.json",
  }
  if type(raw.program) == "string" and raw.program ~= "" then out.program = raw.program end
  if type(raw.cwd) == "string" and raw.cwd ~= "" then out.cwd = raw.cwd end
  if type(raw.args) == "table" then out.args = vim.deepcopy(raw.args) end
  if type(raw.buildFlags) == "string" and raw.buildFlags ~= "" then
    out.build_flags = raw.buildFlags
  end
  if type(raw.env) == "table" and next(raw.env) ~= nil then
    out.env = vim.deepcopy(raw.env)
  end
  if type(raw.envFile) == "string" and raw.envFile ~= "" then
    out.env_files = { raw.envFile }
  end
  if params then
    -- Only attach params the entry actually references.
    local referenced = {}
    local function scan(v)
      if type(v) == "string" then
        for p in v:gmatch("%${input:([^}]+)}") do referenced[p] = true end
      elseif type(v) == "table" then
        for _, item in pairs(v) do scan(item) end
      end
    end
    scan(raw)
    local attached, any = {}, false
    for id, decl in pairs(params) do
      if referenced[id] then attached[id] = decl; any = true end
    end
    if any then out.params = attached end
  end
  return out
end

---Parse + normalize every entry of the nearest launch.json.
---@return table[]? entries, string? err, string? path
function M.entries()
  local path = M.find_launch_json()
  if not path then return nil, "no launch.json found via upward walk", nil end
  local f = io.open(path, "r")
  if not f then return nil, "cannot read " .. path, path end
  local content = f:read("*a")
  f:close()
  local data, perr = M.parse(content)
  if not data then return nil, "parse failed: " .. tostring(perr), path end
  local params = inputs_to_params(data.inputs)
  local out = {}
  for _, raw in ipairs(data.configurations or {}) do
    if type(raw) == "table" and type(raw.name) == "string" and raw.name ~= "" then
      out[#out + 1] = normalize_entry(raw, params)
    end
  end
  return out, nil, path
end

-- ── read-through (§5 precedence / stale-state contract) ────────

---Read-through is active ONLY while a launch.json is reachable AND
---neither store tier exists.
---@return boolean
function M.read_through_active()
  local store = require("auto-run.store")
  if store.store_exists() then return false end
  return M.find_launch_json() ~= nil
end

---Read-only merge-layer-4 shims (empty unless read-through is
---active). Each shim carries `origin = "launch.json"`.
---@return table[]
function M.shims()
  local store = require("auto-run.store")
  if store.store_exists() then return {} end
  local entries = M.entries()
  return entries or {}
end

-- ── launch-config selection (Config section, §8.4 parity) ──────
-- A per-repo "selected launch config" persisted in the shared tier's
-- state.json (key `selected_launch_config` — the same mechanism as
-- env's `selected_env_file`). Unlike env (a path), the selection is a
-- config NAME resolved against `entries()` at launch time (launch.json
-- is re-parsed), so it survives edits and self-heals when the entry is
-- gone. The selected config is merged UNDER every launch's effective
-- config by `apply_selected_base` (called at the dap.translate /
-- dap.debug_test / exec.prepare chokepoints); the selected env file
-- (env.compose step 2.5) still wins highest for env keys.

---The raw stored selection name (no existence check), or nil.
---@return string?
local function stored_name()
  local store = require("auto-run.store")
  local stored = store.read_state().selected_launch_config
  if type(stored) ~= "string" or stored == "" then return nil end
  return stored
end

---The normalized launch.json entry named `name`, or nil.
---@param name string
---@return table?
function M.entry(name)
  local entries = M.entries()
  for _, c in ipairs(entries or {}) do
    if c.name == name then return c end
  end
  return nil
end

---Normalized launch.json entries for the current repo, each annotated
---`selected`. When `kind` is given, only entries of that kind are
---returned ("test" for the tests panel, "debug" for the debug panel).
---Returns `{}` + a reason when no launch.json is reachable (the reason
---drives the view's empty-hint line).
---@param kind string?  "test" | "debug" | nil (all)
---@return table[] configs, string? reason
function M.configs_list(kind)
  local entries, err = M.entries()
  if not entries then return {}, err end
  local stored = stored_name()
  local out = {}
  for _, c in ipairs(entries) do
    if kind == nil or c.kind == kind then
      local rec = vim.deepcopy(c)
      rec.selected = stored ~= nil and c.name == stored
      out[#out + 1] = rec
    end
  end
  return out, nil
end

---The selected config NAME for the current repo, or nil. Self-heals:
---a stored name absent from the current launch.json returns nil.
---@return string?
function M.get_selected()
  local stored = stored_name()
  if not stored then return nil end
  return M.entry(stored) and stored or nil
end

---Select (or clear with nil) the launch config applied as the base of
---every subsequent launch. The name must exist in the current
---launch.json. Publishes `run.config:changed {action="selected", name}`
---(the config NAME only — never any env values).
---@param name string?  config name; nil clears
---@return boolean? ok, table? err  structured {code=...}
function M.set_selected(name)
  local store = require("auto-run.store")
  if name == nil or name == "" then
    local state = store.read_state()
    if state.selected_launch_config ~= nil then
      state.selected_launch_config = nil
      local okw, werr = store.write_state(state)
      if not okw then
        return nil, structured_err("write_failed",
          "set_selected: state.json write failed: " .. tostring(werr))
      end
    end
    publish("run.config:changed", { action = "selected", name = nil })
    return true, nil
  end
  if type(name) ~= "string" then
    return nil, structured_err("invalid_args",
      "set_selected: name must be a string or nil, got " .. type(name))
  end
  if not M.entry(name) then
    return nil, structured_err("not_found",
      "set_selected: no launch.json config named '" .. name .. "'")
  end
  local state = store.read_state()
  state.selected_launch_config = name
  local okw, werr = store.write_state(state)
  if not okw then
    return nil, structured_err("write_failed",
      "set_selected: state.json write failed: " .. tostring(werr))
  end
  publish("run.config:changed", { action = "selected", name = name })
  log.debug("import", "selected launch config changed")
  return true, nil
end

---Mergeable fields of the selected config (the "active base"), or nil
---when nothing is selected / the entry is gone. Raw (unsubstituted) —
---merged BEFORE substitute_deep so `${...}` tokens resolve uniformly
---with the rest of the effective config.
---@return table?
function M.selected_base()
  local stored = stored_name()
  if not stored then return nil end
  local e = M.entry(stored)
  if not e then return nil end
  local base = {}
  for _, f in ipairs({ "env_files", "env", "build_flags", "cwd",
                       "params", "program", "args" }) do
    if e[f] ~= nil then base[f] = vim.deepcopy(e[f]) end
  end
  return next(base) ~= nil and base or nil
end

---Merge the selected config (the "active base") UNDER `eff`,
---field-by-field with `eff` winning. Env-affecting + build fields
---(env_files, env, build_flags, cwd, params) flow into every launch;
---`program`/`args` apply ONLY when `eff` supplies none — so a generated
---test config's program is never overridden (tests panel), while
---launching the selected config itself uses it fully (debug panel).
---No-op when nothing is selected. Mutates and returns `eff`.
---@param eff table  effective config from store.get(...)
---@return table eff
function M.apply_selected_base(eff)
  if type(eff) ~= "table" then return eff end
  local base = M.selected_base()
  if not base then return eff end
  -- env_files: base first, then eff's — compose applies them in order
  -- and later wins, so eff's entries win; the selected .env file
  -- (compose step 2.5) still wins over both.
  if type(base.env_files) == "table" and #base.env_files > 0 then
    local merged = {}
    for _, p in ipairs(base.env_files) do merged[#merged + 1] = p end
    for _, p in ipairs(eff.env_files or {}) do merged[#merged + 1] = p end
    eff.env_files = merged
  end
  -- env map / params: per-key merge, eff wins.
  for _, f in ipairs({ "env", "params" }) do
    if type(base[f]) == "table" then
      local merged = vim.deepcopy(base[f])
      for k, v in pairs(eff[f] or {}) do merged[k] = v end
      eff[f] = merged
    end
  end
  -- scalars: eff wins when present.
  if eff.build_flags == nil and base.build_flags ~= nil then
    eff.build_flags = base.build_flags
  end
  if eff.cwd == nil and base.cwd ~= nil then eff.cwd = base.cwd end
  -- program + args are a COUPLED launch invocation: when eff already
  -- supplies a program (a generated test config, or the config being
  -- launched itself) the base's program AND args are both ignored, so
  -- base program/args never leak into a test-at-cursor run. Only when
  -- eff has no program of its own does the base's invocation apply.
  if eff.program == nil or eff.program == "" then
    if base.program ~= nil then eff.program = base.program end
    if type(base.args) == "table"
        and (type(eff.args) ~= "table" or #eff.args == 0) then
      eff.args = vim.deepcopy(base.args)
    end
  end
  return eff
end

---Resolved (substituted) fields of a launch config for the Config
---section's inline expansion. Env VALUES are MASKED (§8.2): the `env`
---map surfaces as sorted KEY names only (`env_keys`), never values —
---this is the masked config-details surface, NOT the env section's
---deliberate value display.
---@param name string
---@return table? view, string? err
function M.read_config(name)
  local e = M.entry(name)
  if not e then
    return nil, "no launch.json config named '" .. tostring(name) .. "'"
  end
  local env_mod = require("auto-run.env")
  local ctx = env_mod.context()
  local sub = function(v) return env_mod.substitute_deep(v, ctx) end
  local view = {
    name    = e.name,
    kind    = e.kind,
    runtime = e.runtime,
    origin  = e.origin,
  }
  if e.program then view.program = sub(e.program) end
  if e.cwd then view.cwd = sub(e.cwd) end
  if type(e.args) == "table" then view.args = sub(vim.deepcopy(e.args)) end
  if e.build_flags then view.build_flags = sub(e.build_flags) end
  if type(e.env_files) == "table" then
    view.env_files = sub(vim.deepcopy(e.env_files))
  end
  if type(e.env) == "table" then
    local keys = {}
    for k in pairs(e.env) do keys[#keys + 1] = k end
    table.sort(keys)
    view.env_keys = keys   -- names only — values masked (§8.2)
  end
  if type(e.params) == "table" then
    local ids = {}
    for id in pairs(e.params) do ids[#ids + 1] = id end
    table.sort(ids)
    view.param_ids = ids
  end
  return view, nil
end

-- ── import ──────────────────────────────────────────────────────

---@alias AutoRunImportChoice "overwrite"|"skip"|"rename"

---Find a free `<name>-<n>` in the tracked tier for the rename choice.
---@param store table
---@param name string
---@return string
local function free_name(store, name)
  local existing = {}
  for _, entry in ipairs(store.list()) do existing[entry.name] = true end
  local n = 2
  while existing[name .. "-" .. n] do n = n + 1 end
  return name .. "-" .. n
end

---@class AutoRunImportOpts
---@field on_conflict AutoRunImportChoice|fun(name: string): AutoRunImportChoice|nil
---  per-entry conflict choice (default "skip"); interactive prompting
---  is the CALLER's job — pass a function to decide per entry.

---Import launch.json entries into the TRACKED tier with
---`origin = "launch.json"` provenance. `name` narrows to one entry.
---@param name string?
---@param opts AutoRunImportOpts?
---@return { imported: string[], skipped: string[], renamed: table<string,string>, errors: string[], source: string? }? summary, string? err
function M.import(name, opts)
  opts = opts or {}
  local store = require("auto-run.store")
  local dirs = store.resolve_run_dirs()
  if not dirs.tracked then
    return nil, "import: no tracked tier here (anchor is not inside a git repo)"
  end

  local entries, eerr, source = M.entries()
  if not entries then return nil, eerr end

  if name ~= nil then
    local filtered = {}
    for _, e in ipairs(entries) do
      if e.name == name then filtered[#filtered + 1] = e end
    end
    if #filtered == 0 then
      return nil, "import: no launch.json entry named '" .. name .. "'"
    end
    entries = filtered
  end

  local function choice_for(entry_name)
    local c = opts.on_conflict
    if type(c) == "function" then c = c(entry_name) end
    if c ~= "overwrite" and c ~= "rename" then c = "skip" end
    return c
  end

  local summary = {
    imported = {}, skipped = {}, renamed = {}, errors = {}, source = source,
  }
  for _, entry in ipairs(entries) do
    local target = entry.name
    local _, add_err = store.add(entry, { tier = "tracked" })
    if add_err and add_err:match("already exists") then
      local choice = choice_for(entry.name)
      if choice == "overwrite" then
        local _, oerr = store.add(entry, { tier = "tracked", overwrite = true })
        if oerr then
          summary.errors[#summary.errors + 1] = entry.name .. ": " .. oerr
        else
          summary.imported[#summary.imported + 1] = entry.name
        end
      elseif choice == "rename" then
        target = free_name(store, entry.name)
        local renamed = vim.deepcopy(entry)
        renamed.name = target
        local _, rerr = store.add(renamed, { tier = "tracked" })
        if rerr then
          summary.errors[#summary.errors + 1] = entry.name .. ": " .. rerr
        else
          summary.renamed[entry.name] = target
          summary.imported[#summary.imported + 1] = target
        end
      else
        summary.skipped[#summary.skipped + 1] = entry.name
      end
    elseif add_err then
      summary.errors[#summary.errors + 1] = entry.name .. ": " .. add_err
    else
      summary.imported[#summary.imported + 1] = entry.name
    end
  end

  table.sort(summary.imported)
  table.sort(summary.skipped)
  log.debug("import", ("imported %d, skipped %d, errors %d from %s"):format(
    #summary.imported, #summary.skipped, #summary.errors, tostring(source)))
  return summary, nil
end

return M