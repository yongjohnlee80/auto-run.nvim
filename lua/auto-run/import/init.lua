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