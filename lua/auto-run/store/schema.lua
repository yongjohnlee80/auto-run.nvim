---auto-run.store.schema — validation for run configs + env profiles
---(ADR-0048 §3 / §4).
---
---Both record kinds are strict-JSON files, one per config/profile.
---Validation is shape-only: reference EXISTENCE (a dangling `extends`
---target, a missing env file) is a load/merge-time concern surfaced
---by `store.get()` / `store.validate()`, not by this module.
---
---`vim.NIL` is legal anywhere a field is optional — JSON `null` is
---the tombstone marker in the layered merge (§3.1), and tombstones
---may live in on-disk shared-tier files, not just `overrides.json`.
---@module 'auto-run.store.schema'

local M = {}

---@type table<string, boolean>
M.VALID_KIND = { run = true, test = true, debug = true }

---Filenames are `<name>.json`; keep names path-safe. Spaces are
---allowed (imported launch.json entries commonly carry them, e.g.
---"Debug Gold"); slashes and other separators are not.
local NAME_PATTERN = "^[%w][%w%._%- ]*$"

-- ── field catalogs ──────────────────────────────────────────────

---Run-config fields (ADR-0048 §3). `kind` entries key into the
---validators below.
local CONFIG_FIELDS = {
  name             = "name",
  kind             = "run_kind",
  runtime          = "string",
  extends          = "string",
  program          = "string",
  args             = "string_list",
  cwd              = "string",
  build_flags      = "string",
  env              = "string_map",
  env_files        = "string_list",
  profile          = "string",
  depends          = "string_list",
  tags             = "string_list",
  params           = "params_map",
  origin           = "string",
  -- Profile-pipeline fields may also appear directly on a config
  -- (they merge with append semantics per §3.1).
  base_env_files   = "string_list",
  secret_manifests = "string_list",
  command_env      = "command_env_list",
  runtime_env      = "string_map",
}

---Env-profile fields (ADR-0048 §4).
local PROFILE_FIELDS = {
  name             = "name",
  base_env_files   = "string_list",
  secret_manifests = "string_list",
  command_env      = "command_env_list",
  runtime_env      = "string_map",
  tags             = "string_list",
  origin           = "string",
}

-- ── validators ──────────────────────────────────────────────────

local function is_nil_like(v)
  return v == nil or v == vim.NIL
end

local VALIDATORS = {}

VALIDATORS.name = function(v)
  if type(v) ~= "string" or v == "" then
    return false, "must be a non-empty string"
  end
  if not v:match(NAME_PATTERN) then
    return false, "must match " .. NAME_PATTERN .. " (filename-safe)"
  end
  return true
end

VALIDATORS.run_kind = function(v)
  if type(v) == "string" and M.VALID_KIND[v] then return true end
  return false, "must be one of run|test|debug"
end

VALIDATORS.string = function(v)
  if type(v) == "string" then return true end
  return false, "must be a string"
end

VALIDATORS.string_list = function(v)
  if type(v) ~= "table" then return false, "must be a list of strings" end
  local n = 0
  for k, item in pairs(v) do
    if type(k) ~= "number" then
      return false, "must be a list (found non-numeric key '" .. tostring(k) .. "')"
    end
    if type(item) ~= "string" then
      return false, "list entries must be strings (entry " .. k .. " is " .. type(item) .. ")"
    end
    n = n + 1
  end
  if n ~= #v then return false, "must be a contiguous list" end
  return true
end

VALIDATORS.string_map = function(v)
  if type(v) ~= "table" then return false, "must be a map of string keys" end
  for k, item in pairs(v) do
    if type(k) ~= "string" then
      return false, "map keys must be strings (found " .. type(k) .. ")"
    end
    -- vim.NIL values are per-key tombstones (§3.1) — legal.
    if item ~= vim.NIL and type(item) ~= "string" then
      return false, "value for '" .. k .. "' must be a string or null tombstone"
    end
  end
  return true
end

VALIDATORS.params_map = function(v)
  if type(v) ~= "table" then return false, "must be a map of param declarations" end
  for k, decl in pairs(v) do
    if type(k) ~= "string" then
      return false, "param names must be strings"
    end
    if decl == vim.NIL then
      -- per-key tombstone
    elseif type(decl) ~= "table" then
      return false, "param '" .. k .. "' must be a table {type, default?, choices?, description?}"
    else
      if decl.type ~= nil and type(decl.type) ~= "string" then
        return false, "param '" .. k .. "'.type must be a string"
      end
      if decl.choices ~= nil and decl.choices ~= vim.NIL and type(decl.choices) ~= "table" then
        return false, "param '" .. k .. "'.choices must be a list"
      end
    end
  end
  return true
end

VALIDATORS.command_env_list = function(v)
  if type(v) ~= "table" then
    return false, "must be a list of {key, command, required?} entries"
  end
  for i, entry in ipairs(v) do
    if type(entry) ~= "table" then
      return false, "entry " .. i .. " must be a table"
    end
    if type(entry.key) ~= "string" or entry.key == "" then
      return false, "entry " .. i .. ".key must be a non-empty string"
    end
    if type(entry.command) ~= "string" or entry.command == "" then
      return false, "entry " .. i .. ".command must be a non-empty string"
    end
    if entry.required ~= nil and type(entry.required) ~= "boolean" then
      return false, "entry " .. i .. ".required must be a boolean"
    end
  end
  return true
end

-- ── validation core ─────────────────────────────────────────────

---@param t table
---@param fields table<string, string>
---@param required table<string, boolean>
---@param label string
---@return { ok: boolean, errors: string[] }
local function validate_against(t, fields, required, label)
  local errors = {}
  if type(t) ~= "table" then
    return { ok = false, errors = { label .. " must be a table, got " .. type(t) } }
  end
  for k in pairs(t) do
    if type(k) ~= "string" or not fields[k] then
      errors[#errors + 1] = "unknown field '" .. tostring(k) .. "'"
    end
  end
  for field, kind in pairs(fields) do
    local v = t[field]
    if is_nil_like(v) then
      if required[field] and v == nil then
        errors[#errors + 1] = "missing required field '" .. field .. "'"
      elseif required[field] and v == vim.NIL then
        errors[#errors + 1] = "required field '" .. field .. "' cannot be null"
      end
    else
      local okv, why = VALIDATORS[kind](v)
      if not okv then
        errors[#errors + 1] = "field '" .. field .. "': " .. why
      end
    end
  end
  table.sort(errors)
  return { ok = #errors == 0, errors = errors }
end

---Validate a run-config record. `name` and `kind` are required; every
---other field is optional (tombstones welcome).
---@param t table
---@return { ok: boolean, errors: string[] }
function M.validate_config(t)
  return validate_against(t, CONFIG_FIELDS,
    { name = true, kind = true }, "run config")
end

---Validate a layer FRAGMENT (an `overrides.json` entry, an update
---patch, invocation args): same field catalog, nothing required.
---@param t table
---@return { ok: boolean, errors: string[] }
function M.validate_config_fragment(t)
  return validate_against(t, CONFIG_FIELDS, {}, "config fragment")
end

---Validate an env-profile record. Only `name` is required.
---@param t table
---@return { ok: boolean, errors: string[] }
function M.validate_profile(t)
  return validate_against(t, PROFILE_FIELDS, { name = true }, "env profile")
end

---Is `name` usable as a config/profile name (and therefore filename)?
---@param name any
---@return boolean ok, string? err
function M.valid_name(name)
  return VALIDATORS.name(name)
end

return M