---auto-run.store.merge — the layered merge engine (ADR-0048 §3.1).
---
---Effective config = layers applied in fixed precedence (later wins):
---
---   1. extends chain           (deepest base first)
---   2. tracked-tier file
---   3. same-name shared-local file
---   4. launch.json import shim (read-through mode only, §5)
---   5. selected profile        (env-affecting fields only)
---   6. shared-local overrides.json entry
---   7. invocation args
---
---Field-level rules (the §3.1 merge table):
---
---   scalars                                     → replace
---   args / depends                              → replace whole array
---   env_files / base_env_files /
---   secret_manifests / command_env              → append across layers
---   env / runtime_env / params                  → per-key merge
---   tags                                        → append + dedupe
---
---Tombstones: `vim.NIL` (JSON null) at any layer deletes the
---inherited value — a null map key removes that key, a null scalar
---unsets it, an array set to null empties it.
---
---This module is PURE — no IO, no state. `store.init` assembles the
---layer list (file reads, extends resolution) and calls `apply()`.
---@module 'auto-run.store.merge'

local M = {}

-- ── field rules ─────────────────────────────────────────────────

---@alias AutoRunMergeRule "scalar"|"replace_array"|"append_array"|"map"|"append_dedupe"

---@type table<string, AutoRunMergeRule>
M.FIELD_RULES = {
  -- scalars
  name             = "scalar",
  kind             = "scalar",
  runtime          = "scalar",
  extends          = "scalar",
  program          = "scalar",
  cwd              = "scalar",
  build_flags      = "scalar",
  profile          = "scalar",
  origin           = "scalar",
  -- replace-whole-array
  args             = "replace_array",
  depends          = "replace_array",
  -- append across layers (ordered composition pipelines)
  env_files        = "append_array",
  base_env_files   = "append_array",
  secret_manifests = "append_array",
  command_env      = "append_array",
  -- per-key maps
  env              = "map",
  runtime_env      = "map",
  params           = "map",
  -- append + dedupe
  tags             = "append_dedupe",
}

---Fields a profile layer (layer 5) is allowed to contribute —
---profiles affect env composition only (§3.1).
M.PROFILE_LAYER_FIELDS = {
  base_env_files   = true,
  secret_manifests = true,
  command_env      = true,
  runtime_env      = true,
  env_files        = true,
  env              = true,
}

-- ── apply ───────────────────────────────────────────────────────

---@class AutoRunLayer
---@field data table    the layer's field fragment
---@field source string provenance label ("extends:go-base", "tracked", "shared", "launch.json", "profile:prod-db", "overrides", "invocation")

---Merge one layer's field value into the accumulator per the field
---rule, honoring null tombstones.
---@param out table
---@param k string
---@param v any
local function merge_field(out, k, v)
  local rule = M.FIELD_RULES[k] or "scalar"

  if v == vim.NIL then
    if rule == "append_array" or rule == "replace_array" or rule == "append_dedupe" then
      out[k] = {}          -- array set to null empties it
    else
      out[k] = nil         -- scalar / whole-map tombstone unsets
    end
    return
  end

  if rule == "scalar" then
    out[k] = type(v) == "table" and vim.deepcopy(v) or v
  elseif rule == "replace_array" then
    out[k] = vim.deepcopy(v)
  elseif rule == "append_array" then
    local acc = out[k] or {}
    for _, item in ipairs(v) do
      acc[#acc + 1] = type(item) == "table" and vim.deepcopy(item) or item
    end
    out[k] = acc
  elseif rule == "append_dedupe" then
    local acc = out[k] or {}
    local seen = {}
    for _, item in ipairs(acc) do seen[item] = true end
    for _, item in ipairs(v) do
      if not seen[item] then
        acc[#acc + 1] = item
        seen[item] = true
      end
    end
    out[k] = acc
  elseif rule == "map" then
    local acc = out[k] or {}
    for mk, mv in pairs(v) do
      if mv == vim.NIL then
        acc[mk] = nil      -- per-key tombstone
      else
        acc[mk] = type(mv) == "table" and vim.deepcopy(mv) or mv
      end
    end
    out[k] = acc
  end
end

---Apply an ordered layer list (earliest first, later wins) and return
---the effective table plus a per-field provenance map (`field →
---source of the last layer that touched it` — write-routing and the
---panel's tier annotations read this).
---@param layers AutoRunLayer[]
---@return table effective, table<string, string> provenance
function M.apply(layers)
  local out, provenance = {}, {}
  for _, layer in ipairs(layers) do
    if type(layer.data) == "table" then
      for k, v in pairs(layer.data) do
        merge_field(out, k, v)
        provenance[k] = layer.source
      end
    end
  end
  return out, provenance
end

-- ── extends chain resolution ────────────────────────────────────

---Resolve the `extends` chain for `name` into a deepest-base-first
---list of names (excluding `name` itself). `lookup(name)` returns the
---raw own-layers merged fragment for a config name (or nil when the
---name doesn't exist) — the caller owns tier semantics; this function
---owns ordering, cycle detection, and dangling-target diagnostics.
---
---Cycle errors carry the full path: `extends cycle: a -> b -> a`.
---@param name string
---@param lookup fun(name: string): table|nil
---@return string[]? chain, string? err
function M.resolve_extends_chain(name, lookup)
  local chain = {}
  local visited = { [name] = true }
  local path = { name }

  local cur = lookup(name)
  if cur == nil then
    return nil, "config '" .. name .. "' not found"
  end

  while true do
    local ext = cur.extends
    if ext == nil or ext == vim.NIL or ext == "" then break end
    if type(ext) ~= "string" then
      return nil, "config '" .. path[#path] .. "': extends must be a string"
    end
    path[#path + 1] = ext
    if visited[ext] then
      return nil, "extends cycle: " .. table.concat(path, " -> ")
    end
    visited[ext] = true
    local parent = lookup(ext)
    if parent == nil then
      return nil, "dangling extends target '" .. ext
        .. "' (referenced by '" .. path[#path - 1] .. "')"
    end
    table.insert(chain, 1, ext)  -- deepest base first
    cur = parent
  end

  return chain, nil
end

return M