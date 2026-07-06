---auto-run.store — the canonical two-tier run-config store
---(ADR-0048 §2 / §2.1 / §3.1).
---
---Tiers (resolved EXCLUSIVELY through `resolve_run_dirs()`; no other
---code path assembles `.auto-run/` paths):
---
---   tracked      <worktree>/.auto-run/{configs,profiles}/*.json
---                committed with the code; nil outside a git repo.
---   shared-local <container>/.auto-run/ (linked-worktree layouts) or
---                <repo>/.auto-run/local/ (plain repos; gitignored via
---                a scaffolded .gitignore). Also holds overrides.json.
---
---Strict JSON (`vim.json`), one file per config, atomic writes
---(`auto-core.fs.atomic`), deterministic listing order (tier, then
---filename). Public API returns `(value, err)` pairs — no `vim.notify`
---anywhere on these paths, and no `workspace_root` parameter on any
---function (ADR-0031 §3.1).
---@module 'auto-run.store'

local fs_path  = require("auto-core.fs.path")
local fs_atomic = require("auto-core.fs.atomic")
local paths    = require("auto-run.store.paths")
local schema   = require("auto-run.store.schema")
local merge    = require("auto-run.store.merge")
local log      = require("auto-run.log")

local M = {}

M.paths  = paths
M.schema = schema
M.merge  = merge

-- ── resolver re-export (the ONE public path authority) ──────────

---See `auto-run.store.paths.resolve_run_dirs` for the locked §2.1
---contract.
---@return AutoRunDirs
function M.resolve_run_dirs()
  return paths.resolve_run_dirs()
end

-- ── events ──────────────────────────────────────────────────────

local function publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events then pcall(events.publish, topic, payload) end
end

-- ── strict-JSON IO ──────────────────────────────────────────────

---Read + decode one strict-JSON file. `(nil, nil)` when the file
---doesn't exist; `(nil, err)` on read/parse failure.
---@param path string
---@return table? data, string? err
local function read_json(path)
  if not fs_path.is_file(path) then return nil, nil end
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  local content = f:read("*a")
  f:close()
  local okd, data = pcall(vim.json.decode, content)
  if not okd then
    return nil, "invalid JSON in " .. path .. ": " .. tostring(data)
  end
  if type(data) ~= "table" then
    return nil, "expected a JSON object in " .. path
  end
  return data, nil
end

---VSCode-ish stable field order for the pretty printer; unknown keys
---fall to the end alphabetically. Keeps diffs clean across rewrites.
local FIELD_PRIORITY = {
  "name", "kind", "runtime", "extends",
  "program", "args", "cwd", "build_flags",
  "env", "env_files", "profile", "depends", "tags", "params",
  "base_env_files", "secret_manifests", "command_env", "runtime_env",
  "origin",
}
local FIELD_INDEX = {}
for i, k in ipairs(FIELD_PRIORITY) do FIELD_INDEX[k] = i end

local function cmp_keys(a, b)
  local ia, ib = FIELD_INDEX[a], FIELD_INDEX[b]
  if ia and ib then return ia < ib end
  if ia then return true end
  if ib then return false end
  return a < b
end

---Pretty strict-JSON encoder (2-space indent, stable key order).
---@param value any
---@param indent string?
---@return string
local function encode_pretty(value, indent)
  indent = indent or ""
  local next_indent = indent .. "  "
  if value == vim.NIL then return "null" end
  if type(value) == "table" then
    if vim.islist(value) and next(value) ~= nil then
      local parts = {}
      for _, v in ipairs(value) do
        parts[#parts + 1] = next_indent .. encode_pretty(v, next_indent)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end
    local keys = {}
    for k in pairs(value) do
      if type(k) == "string" then keys[#keys + 1] = k end
    end
    if #keys == 0 then
      return vim.islist(value) and "[]" or "{}"
    end
    table.sort(keys, cmp_keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = next_indent .. vim.json.encode(k) .. ": "
        .. encode_pretty(value[k], next_indent)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  elseif type(value) == "string" then
    return vim.json.encode(value)
  elseif type(value) == "number" or type(value) == "boolean" then
    return tostring(value)
  end
  return "null"
end

---Atomically write `data` as pretty strict JSON.
---@param path string
---@param data table
---@return boolean ok, string? err
local function write_json(path, data)
  return fs_atomic.write(path, encode_pretty(data) .. "\n", { mkdir = true })
end

-- ── tier scaffolding ────────────────────────────────────────────

---Ensure the plain-repo shared tier is gitignored: when the shared
---dir is `<repo>/.auto-run/local`, scaffold `<repo>/.auto-run/.gitignore`
---containing `local/` (ADR-0048 §2). Idempotent, best-effort.
---@param dirs AutoRunDirs
local function scaffold_gitignore(dirs)
  local cfg = require("auto-run.config").options
  if not cfg.store.scaffold_gitignore then return end
  if not (dirs.root and fs_path.basename(dirs.shared) == "local") then return end
  local parent = fs_path.parent(dirs.shared)
  if fs_path.parent(parent) ~= dirs.root then return end
  local gi = fs_path.join(parent, ".gitignore")
  if fs_path.is_file(gi) then return end
  local okw, werr = fs_atomic.write(gi, "local/\n", { mkdir = true })
  if not okw then log.debug("store", "gitignore scaffold failed: " .. tostring(werr)) end
end

-- ── raw tier access ─────────────────────────────────────────────

---@alias AutoRunRecordKind "configs"|"profiles"

---Path of one record file inside a tier.
---@param tier_dir string
---@param kind AutoRunRecordKind
---@param name string
---@return string
local function record_path(tier_dir, kind, name)
  local sub = kind == "configs" and paths.configs_dir(tier_dir)
    or paths.profiles_dir(tier_dir)
  return fs_path.join(sub, name .. ".json")
end

---Sorted record names present in one tier dir.
---@param tier_dir string?
---@param kind AutoRunRecordKind
---@return string[]
local function tier_names(tier_dir, kind)
  if not tier_dir then return {} end
  local sub = kind == "configs" and paths.configs_dir(tier_dir)
    or paths.profiles_dir(tier_dir)
  if not fs_path.is_dir(sub) then return {} end
  local out = {}
  for _, f in ipairs(vim.fn.readdir(sub) or {}) do
    local name = f:match("^(.+)%.json$")
    if name and fs_path.is_file(fs_path.join(sub, f)) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---Does either tier hold ANY store content? Gates launch.json
---read-through (§5): the moment a store exists, shims go dark.
---@param dirs AutoRunDirs?
---@return boolean
function M.store_exists(dirs)
  dirs = dirs or paths.resolve_run_dirs()
  for _, tier in ipairs({ dirs.tracked, dirs.shared }) do
    if tier then
      if fs_path.is_dir(paths.configs_dir(tier))
        or fs_path.is_dir(paths.profiles_dir(tier)) then
        return true
      end
    end
  end
  return false
end

---Read-through shims from `auto-run.import` (lazy require — the
---import module requires the store back for `add`).
---@param dirs AutoRunDirs
---@return table<string, table> shims_by_name, string[] names_sorted
local function shim_layer(dirs)
  if M.store_exists(dirs) then return {}, {} end
  local oki, import = pcall(require, "auto-run.import")
  if not oki then return {}, {} end
  local shims = import.shims() or {}
  local by_name, names = {}, {}
  for _, s in ipairs(shims) do
    if type(s.name) == "string" then
      by_name[s.name] = s
      names[#names + 1] = s.name
    end
  end
  table.sort(names)
  return by_name, names
end

-- ── overrides.json (merge layer 6) ──────────────────────────────

---@param dirs AutoRunDirs
---@return table entries, string? err
local function read_overrides(dirs)
  local data, err = read_json(paths.overrides_file(dirs.shared))
  if err then return {}, err end
  return data or {}, nil
end

---@param dirs AutoRunDirs
---@param entries table
---@return boolean ok, string? err
local function write_overrides(dirs, entries)
  scaffold_gitignore(dirs)
  return write_json(paths.overrides_file(dirs.shared), entries)
end

-- ── layer assembly ──────────────────────────────────────────────

---Collect a config's OWN layers (2 tracked, 3 shared, 4 shim) in
---precedence order. Returns nil when the name exists nowhere.
---@param dirs AutoRunDirs
---@param name string
---@param shims table<string, table>
---@return AutoRunLayer[]? layers, string? err
local function own_layers(dirs, name, shims)
  local layers = {}
  if dirs.tracked then
    local data, err = read_json(record_path(dirs.tracked, "configs", name))
    if err then return nil, err end
    if data then layers[#layers + 1] = { data = data, source = "tracked" } end
  end
  do
    local data, err = read_json(record_path(dirs.shared, "configs", name))
    if err then return nil, err end
    if data then layers[#layers + 1] = { data = data, source = "shared" } end
  end
  if shims[name] then
    layers[#layers + 1] = { data = shims[name], source = "launch.json" }
  end
  if #layers == 0 then return nil, nil end
  return layers, nil
end

---Merged own-layers fragment for extends-chain lookups.
---@param dirs AutoRunDirs
---@param shims table<string, table>
---@return fun(name: string): table|nil
local function own_lookup(dirs, shims)
  return function(name)
    local layers = own_layers(dirs, name, shims)
    if not layers then return nil end
    local eff = merge.apply(layers)
    return eff
  end
end

-- ── profiles ────────────────────────────────────────────────────

---Effective profile: tracked-tier file merged under the shared-local
---file with the standard field rules (§3.1 append/map semantics).
---@param name string
---@return table? profile, string? err
function M.get_profile(name)
  if type(name) ~= "string" or name == "" then
    return nil, "get_profile: name must be a non-empty string"
  end
  local dirs = paths.resolve_run_dirs()
  local layers = {}
  if dirs.tracked then
    local data, err = read_json(record_path(dirs.tracked, "profiles", name))
    if err then return nil, err end
    if data then layers[#layers + 1] = { data = data, source = "tracked" } end
  end
  do
    local data, err = read_json(record_path(dirs.shared, "profiles", name))
    if err then return nil, err end
    if data then layers[#layers + 1] = { data = data, source = "shared" } end
  end
  if #layers == 0 then
    return nil, "profile '" .. name .. "' not found"
  end
  local eff = merge.apply(layers)
  eff.name = name
  return eff, nil
end

---Sorted profile inventory: tracked names first, then shared-only
---names (tier-then-filename determinism).
---@return { name: string, tiers: string[] }[]
function M.list_profiles()
  local dirs = paths.resolve_run_dirs()
  local tracked = tier_names(dirs.tracked, "profiles")
  local shared = tier_names(dirs.shared, "profiles")
  local out, seen = {}, {}
  for _, n in ipairs(tracked) do
    seen[n] = { name = n, tiers = { "tracked" } }
    out[#out + 1] = seen[n]
  end
  for _, n in ipairs(shared) do
    if seen[n] then
      table.insert(seen[n].tiers, "shared")
    else
      out[#out + 1] = { name = n, tiers = { "shared" } }
    end
  end
  return out
end

-- ── get (the 7-layer merge) ─────────────────────────────────────

---@class AutoRunGetOpts
---@field profile string?     profile-name override (invocation-level)
---@field args table?         invocation-args layer (7); validated fragment
---@field no_profile boolean? skip layer 5 entirely

---Effective config for `name`. Layers per §3.1; `meta` (third return)
---carries `layers` (source labels applied, in order) and `provenance`
---(field → last source). Errors are structured strings — extends
---cycles include the full path.
---@param name string
---@param opts AutoRunGetOpts?
---@return table? effective, string? err, { layers: string[], provenance: table<string,string> }? meta
function M.get(name, opts)
  opts = opts or {}
  if type(name) ~= "string" or name == "" then
    return nil, "get: name must be a non-empty string"
  end
  local dirs = paths.resolve_run_dirs()
  local shims = shim_layer(dirs)

  local own, oerr = own_layers(dirs, name, shims)
  if oerr then return nil, oerr end
  if not own then return nil, "config '" .. name .. "' not found" end

  -- Layer 1: extends chain (deepest base first).
  local lookup = own_lookup(dirs, shims)
  local chain, cerr = merge.resolve_extends_chain(name, lookup)
  if not chain then return nil, cerr end

  local layers = {}
  for _, base in ipairs(chain) do
    layers[#layers + 1] = { data = lookup(base), source = "extends:" .. base }
  end
  vim.list_extend(layers, own)

  -- Overrides entry (layer 6) + invocation args (layer 7) are known
  -- up front; the profile NAME may come from any of them, so resolve
  -- the name against a preview merge before inserting layer 5.
  local overrides = read_overrides(dirs)
  local override_layer = type(overrides[name]) == "table"
    and { data = overrides[name], source = "overrides" } or nil
  local invocation_layer = type(opts.args) == "table"
    and { data = opts.args, source = "invocation" } or nil

  local preview_layers = vim.deepcopy(layers)
  if override_layer then preview_layers[#preview_layers + 1] = override_layer end
  if invocation_layer then preview_layers[#preview_layers + 1] = invocation_layer end
  local preview = merge.apply(preview_layers)

  -- Layer 5: selected profile (env-affecting fields only).
  if not opts.no_profile then
    local profile_name = opts.profile or preview.profile
    if type(profile_name) == "string" and profile_name ~= "" then
      local prof, perr = M.get_profile(profile_name)
      if not prof then
        return nil, "profile '" .. profile_name .. "': " .. tostring(perr)
      end
      local fragment = {}
      for k in pairs(merge.PROFILE_LAYER_FIELDS) do
        if prof[k] ~= nil then fragment[k] = prof[k] end
      end
      layers[#layers + 1] = { data = fragment, source = "profile:" .. profile_name }
    end
  end

  if override_layer then layers[#layers + 1] = override_layer end
  if invocation_layer then layers[#layers + 1] = invocation_layer end

  local effective, provenance = merge.apply(layers)
  effective.name = name  -- identity is the store key, never merged away

  local applied = {}
  for _, l in ipairs(layers) do applied[#applied + 1] = l.source end
  return effective, nil, { layers = applied, provenance = provenance }
end

-- ── list ────────────────────────────────────────────────────────

---Deterministic inventory: tracked-tier names (sorted) first, then
---shared-only names (sorted), then launch.json shims (only possible
---when no store exists). Each entry is a slim projection; a config
---whose merge fails (cycle, dangling extends) is still listed, with
---`error` set.
---@return { name: string, kind: string?, runtime: string?, tags: string[]?, layers: string[], origin: string?, error: string? }[]
function M.list()
  local dirs = paths.resolve_run_dirs()
  local shims, shim_names = shim_layer(dirs)

  local ordered, seen = {}, {}
  for _, n in ipairs(tier_names(dirs.tracked, "configs")) do
    if not seen[n] then seen[n] = true; ordered[#ordered + 1] = n end
  end
  for _, n in ipairs(tier_names(dirs.shared, "configs")) do
    if not seen[n] then seen[n] = true; ordered[#ordered + 1] = n end
  end
  for _, n in ipairs(shim_names) do
    if not seen[n] then seen[n] = true; ordered[#ordered + 1] = n end
  end

  local out = {}
  for _, name in ipairs(ordered) do
    local eff, err, meta = M.get(name)
    if eff then
      out[#out + 1] = {
        name    = name,
        kind    = eff.kind,
        runtime = eff.runtime,
        tags    = eff.tags,
        layers  = meta and meta.layers or {},
        origin  = eff.origin,
      }
    else
      out[#out + 1] = { name = name, layers = {}, error = err }
    end
  end
  return out
end

-- ── add ─────────────────────────────────────────────────────────

---@class AutoRunAddOpts
---@field tier "tracked"|"shared"|nil  default: tracked when available, else shared
---@field overwrite boolean?           replace an existing same-tier file
---@field kind AutoRunRecordKind?      "configs" (default) | "profiles"

---Create a new config (or profile with `opts.kind = "profiles"`).
---Validates against the schema, refuses same-tier duplicates unless
---`overwrite`, writes atomically, publishes `run.config:changed`.
---@param spec table
---@param opts AutoRunAddOpts?
---@return string? path, string? err
function M.add(spec, opts)
  opts = opts or {}
  local kind = opts.kind or "configs"
  local v = kind == "profiles" and schema.validate_profile(spec)
    or schema.validate_config(spec)
  if not v.ok then
    return nil, "invalid " .. kind:sub(1, -2) .. ": " .. table.concat(v.errors, "; ")
  end

  local dirs = paths.resolve_run_dirs()
  local tier = opts.tier
  if tier == nil then
    tier = dirs.tracked and "tracked" or "shared"
  end
  if tier ~= "tracked" and tier ~= "shared" then
    return nil, "add: tier must be 'tracked' or 'shared'"
  end
  local tier_dir = tier == "tracked" and dirs.tracked or dirs.shared
  if not tier_dir then
    return nil, "add: no tracked tier here (anchor is not inside a git repo); use tier='shared'"
  end

  local path = record_path(tier_dir, kind, spec.name)
  if fs_path.is_file(path) and not opts.overwrite then
    return nil, "add: '" .. spec.name .. "' already exists in the " .. tier
      .. " tier (pass overwrite=true to replace)"
  end

  if tier == "shared" then scaffold_gitignore(dirs) end
  local okw, werr = write_json(path, spec)
  if not okw then return nil, werr end

  paths.upsert_known(tier_dir, dirs.anchor)
  publish("run.config:changed", {
    name = spec.name, action = "add", tier = tier, kind = kind,
  })
  log.debug("store", "added " .. kind .. "/" .. spec.name .. " (" .. tier .. ")")
  return path, nil
end

-- ── update (write-routing, §3.1) ───────────────────────────────

---Patch a config. Write-routing per §3.1: the patch lands on the
---highest WRITABLE layer —
---
---   shared-local config file exists → patch that file  (layer 3)
---   tracked file exists (read-only here) → overrides.json (layer 6)
---   launch.json shim only → structured error naming `:AutoRun import`
---
---Patch semantics WITHIN the routed layer: scalar/array fields are
---replaced whole; map-rule fields (`env` / `runtime_env` / `params`)
---patch per key so an `{ env = { PORT = null } }` tombstone doesn't
---clobber sibling keys already stored in that layer. `vim.NIL`
---values persist as JSON null tombstones; the layered merge rules
---apply at read time.
---@param name string
---@param patch table
---@return { name: string, layer: "shared"|"overrides", config: table }? result, string? err
function M.update(name, patch)
  if type(name) ~= "string" or name == "" then
    return nil, "update: name must be a non-empty string"
  end
  if type(patch) ~= "table" then
    return nil, "update: patch must be a table"
  end
  local v = schema.validate_config_fragment(patch)
  if not v.ok then
    return nil, "invalid patch: " .. table.concat(v.errors, "; ")
  end
  if patch.name ~= nil and patch.name ~= name then
    return nil, "update: patch cannot rename a config (remove + add instead)"
  end

  local dirs = paths.resolve_run_dirs()
  local shims = shim_layer(dirs)
  local shared_path = record_path(dirs.shared, "configs", name)
  local tracked_path = dirs.tracked and record_path(dirs.tracked, "configs", name) or nil

  ---Apply the patch onto one stored layer table (see the docstring
  ---for the per-rule semantics).
  local function apply_patch(data)
    for k, val in pairs(patch) do
      local rule = merge.FIELD_RULES[k]
      if rule == "map" and type(val) == "table" and val ~= vim.NIL
          and type(data[k]) == "table" and data[k] ~= vim.NIL then
        for mk, mv in pairs(val) do data[k][mk] = mv end
      else
        data[k] = val
      end
    end
    return data
  end

  local layer
  if fs_path.is_file(shared_path) then
    local data, rerr = read_json(shared_path)
    if rerr then return nil, rerr end
    data = apply_patch(data or {})
    data.name = name
    local okw, werr = write_json(shared_path, data)
    if not okw then return nil, werr end
    layer = "shared"
  elseif tracked_path and fs_path.is_file(tracked_path) then
    local entries, rerr = read_overrides(dirs)
    if rerr then return nil, rerr end
    local entry = apply_patch(type(entries[name]) == "table" and entries[name] or {})
    entries[name] = entry
    local okw, werr = write_overrides(dirs, entries)
    if not okw then return nil, werr end
    layer = "overrides"
  elseif shims[name] then
    return nil, "config '" .. name .. "' is a read-only launch.json shim; "
      .. "run :AutoRun import to migrate it into the store first"
  else
    return nil, "config '" .. name .. "' not found"
  end

  publish("run.config:changed", { name = name, action = "update", layer = layer })
  local effective, gerr = M.get(name)
  if not effective then return nil, gerr end
  return { name = name, layer = layer, config = effective }, nil
end

-- ── remove ──────────────────────────────────────────────────────

---Remove a config file. `opts.tier` narrows the deletion; default
---removes the shared-local file when present, else the tracked file.
---The config's `overrides.json` entry is dropped once no file
---remains in either tier.
---@param name string
---@param opts { tier: ("tracked"|"shared")? }?
---@return boolean ok, string? err
function M.remove(name, opts)
  opts = opts or {}
  if type(name) ~= "string" or name == "" then
    return false, "remove: name must be a non-empty string"
  end
  local dirs = paths.resolve_run_dirs()
  local shared_path = record_path(dirs.shared, "configs", name)
  local tracked_path = dirs.tracked and record_path(dirs.tracked, "configs", name) or nil

  local target, tier
  if opts.tier == "shared" then
    target, tier = shared_path, "shared"
  elseif opts.tier == "tracked" then
    target, tier = tracked_path, "tracked"
  elseif fs_path.is_file(shared_path) then
    target, tier = shared_path, "shared"
  elseif tracked_path and fs_path.is_file(tracked_path) then
    target, tier = tracked_path, "tracked"
  end
  if not target or not fs_path.is_file(target) then
    return false, "config '" .. name .. "' not found"
      .. (opts.tier and (" in the " .. opts.tier .. " tier") or "")
  end

  local unlinked, derr = vim.uv.fs_unlink(target)
  if not unlinked then return false, "unlink: " .. tostring(derr) end

  -- Drop the overlay entry once the name is gone from both tiers.
  local still_tracked = tracked_path and fs_path.is_file(tracked_path)
  local still_shared = fs_path.is_file(shared_path)
  if not still_tracked and not still_shared then
    local entries = read_overrides(dirs)
    if entries[name] ~= nil then
      entries[name] = nil
      write_overrides(dirs, entries)
    end
  end

  publish("run.config:changed", { name = name, action = "remove", tier = tier })
  log.debug("store", "removed configs/" .. name .. " (" .. tier .. ")")
  return true, nil
end

-- ── set_dir ─────────────────────────────────────────────────────

---Override the shared-local store dir for the anchor's repo
---(`nil`/`""` clears). Thin wrapper over the resolver's registry;
---publishes `run.config:changed` since the visible config set moves.
---@param path string?
---@return AutoRunDirs? dirs, string? err
function M.set_dir(path)
  local dirs, err = paths.set_dir(path)
  if not dirs then return nil, err end
  publish("run.config:changed", { action = "set_dir", shared = dirs.shared, origin = dirs.origin })
  return dirs, nil
end

-- ── validate (whole-store inspection) ───────────────────────────

---Schema-check every config + profile file in both tiers, then run
---extends resolution for every config name (cycles, dangling
---targets). Backs `:AutoRun validate` and the `run.validate` verb.
---@return { ok: boolean, checked: integer, issues: { file: string?, name: string, tier: string?, errors: string[] }[] }
function M.validate()
  local dirs = paths.resolve_run_dirs()
  local issues, checked = {}, 0

  local function check_tier(tier_dir, tier_label)
    if not tier_dir then return end
    for _, kind in ipairs({ "configs", "profiles" }) do
      for _, name in ipairs(tier_names(tier_dir, kind)) do
        checked = checked + 1
        local file = record_path(tier_dir, kind, name)
        local data, rerr = read_json(file)
        if rerr then
          issues[#issues + 1] = { file = file, name = name, tier = tier_label, errors = { rerr } }
        elseif data then
          local v = kind == "configs" and schema.validate_config(data)
            or schema.validate_profile(data)
          local errs = vim.deepcopy(v.errors)
          if type(data.name) == "string" and data.name ~= name then
            errs[#errs + 1] = "name '" .. data.name .. "' does not match filename '" .. name .. ".json'"
          end
          if #errs > 0 then
            issues[#issues + 1] = { file = file, name = name, tier = tier_label, errors = errs }
          end
        end
      end
    end
  end

  check_tier(dirs.tracked, "tracked")
  check_tier(dirs.shared, "shared")

  -- Cross-file checks: extends resolution over the union of names.
  local shims = shim_layer(dirs)
  local lookup = own_lookup(dirs, shims)
  local seen = {}
  for _, tier_dir in ipairs({ dirs.tracked, dirs.shared }) do
    for _, name in ipairs(tier_names(tier_dir, "configs")) do
      if not seen[name] then
        seen[name] = true
        local chain, cerr = merge.resolve_extends_chain(name, lookup)
        if not chain then
          issues[#issues + 1] = { name = name, errors = { cerr } }
        end
      end
    end
  end

  return { ok = #issues == 0, checked = checked, issues = issues }
end

-- ── diagnostics (doctor / run.status) ───────────────────────────

---Structured resolver + store status for the current anchor.
---@return table
function M.status()
  local dirs = paths.resolve_run_dirs()
  local oki, import = pcall(require, "auto-run.import")
  local launch_path = oki and import.find_launch_json() or nil
  local read_through = oki and import.read_through_active() or false
  return {
    anchor       = dirs.anchor,
    root         = dirs.root,
    container    = dirs.container,
    tracked      = dirs.tracked,
    shared       = dirs.shared,
    origin       = dirs.origin,
    store_exists = M.store_exists(dirs),
    launch_json  = launch_path,
    read_through = read_through,
    counts = {
      tracked_configs  = #tier_names(dirs.tracked, "configs"),
      shared_configs   = #tier_names(dirs.shared, "configs"),
      tracked_profiles = #tier_names(dirs.tracked, "profiles"),
      shared_profiles  = #tier_names(dirs.shared, "profiles"),
    },
    known_dirs = paths.known_dirs(),
  }
end

return M