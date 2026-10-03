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

---Filenames are `<name>.json`; keep names path-safe. Spaces, colons
---and parens are allowed — real-world launch.json entries carry all
---three (e.g. "Go: Debug Test (LM)"; VSCode's own scaffolds use the
---"<lang>: <verb>" convention) and the Phase 4 parity gate imports
---them verbatim. Slashes and other path separators are not.
local NAME_PATTERN = "^[%w][%w%._%- :%(%)]*$"

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
  -- Layer-level marker (ADR 0199 §6.5): append-rule fields whose value in
  -- THIS layer replaces what lower layers accumulated. Never in an
  -- effective record.
  replace          = "string_list",
  params           = "params_map",
  origin           = "string",
  -- Profile-pipeline fields may also appear directly on a config
  -- (they merge with append semantics per §3.1).
  base_env_files   = "string_list",
  secret_manifests = "string_list",
  command_env      = "command_env_list",
  runtime_env      = "string_map",
  -- Cargo target identity for Rust configs (ADR 0194 §2.3.4). A generic
  -- run/debug/test config must be unambiguous in a multi-package /
  -- multi-bin workspace, so it carries the package and (optionally) the
  -- exact target the `-p` / `--lib|--bin|--test` selectors are built from.
  cargo_package     = "string",
  cargo_target      = "string",
  cargo_target_kind = "string",
  -- Node (ADR 0213 §2.1): a package.json script to run instead of a program.
  script            = "string",
  -- Dart / Flutter (ADR 0196 r3): an explicit package-kind override, and the
  -- desktop device a Flutter app runs on.
  dart_sdk          = "dart_sdk",
  device            = "string",
}

---Env-profile fields (ADR-0048 §4).
local PROFILE_FIELDS = {
  name             = "name",
  base_env_files   = "string_list",
  secret_manifests = "string_list",
  command_env      = "command_env_list",
  runtime_env      = "string_map",
  tags             = "string_list",
  -- Layer-level marker (ADR 0199 §6.5): append-rule fields whose value in
  -- THIS layer replaces what lower layers accumulated. Never in an
  -- effective record.
  replace          = "string_list",
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

VALIDATORS.dart_sdk = function(v)
  if v == "dart" or v == "flutter" then return true end
  return false, "must be one of dart|flutter"
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

---Validate a profile PATCH (store.update with kind=profiles): the profile
---field catalog, nothing required.
---@param t table
---@return { ok: boolean, errors: string[] }
function M.validate_profile_fragment(t)
  return validate_against(t, PROFILE_FIELDS, {}, "profile fragment")
end

-- ── field documentation ─────────────────────────────────────────

---What each field means, for the people editing configs: a one-line `help`,
---and where the field takes a fixed set, `values` (or `values_from`, a set the
---caller resolves: `runtimes`, `configs`, `profiles`). `kinds` limits a config
---field to the kinds it matters for; `runtimes` to the runtimes. The panes
---show this beside each field. Every field in the catalogs above has an
---entry (smoke asserts it), so a new field cannot ship undocumented.
M.FIELD_DOCS = {
  config = {
    name        = { help = "the config's name — also its file name" },
    kind        = { help = "what it is for", values = { "run", "test", "debug" } },
    runtime     = { help = "the adapter that runs it", values_from = "runtimes" },
    extends     = { help = "another config whose fields this one inherits", values_from = "configs" },
    program     = { help = "go: the package directory to build · rust: unset (Cargo builds it) or an executable · node: the entry file · dart: the entry file (bin/<name>.dart, Flutter lib/main.dart) · other: the command" },
    args        = { help = "arguments for the program (test config: the test runner; node script: the script; flutter: flags for flutter run, e.g. --dart-define=K=V)" },
    cwd         = { help = "where it runs — unset: the working directory (w / <leader>rw)" },
    build_flags = { help = "go build / test flags, e.g. -tags=integration -count=1", runtimes = { "go" } },
    env         = { help = "inline KEY=value pairs — win over every env file" },
    env_files   = { help = "env files applied in order — anchor with ${worktree}/" },
    profile     = { help = "an env profile applied to this config", values_from = "profiles" },
    tags        = { help = "labels — informational" },
    depends     = { help = "reserved — not used by auto-run yet" },
    params      = { help = "launch-time parameters (imported launch.json inputs)" },
    origin      = { help = "where the config came from (import) — informational" },
    replace     = { help = "append fields this layer replaces instead of extending (written by the panes)" },
    base_env_files   = { help = "profile pipeline: env files applied first" },
    secret_manifests = { help = "profile pipeline: secret manifests resolved at launch" },
    command_env      = { help = "profile pipeline: values taken from commands' output" },
    runtime_env      = { help = "profile pipeline: literal KEY=value pairs" },
    cargo_package     = { help = "rust: the Cargo package (-p)", runtimes = { "rust" } },
    cargo_target      = { help = "rust: a target of that package — set with cargo_target_kind", runtimes = { "rust" } },
    cargo_target_kind = { help = "rust: the target's kind", values = { "lib", "bin", "test" }, runtimes = { "rust" } },
    script      = { help = "node: a package.json script to run (npm/pnpm/yarn/bun run <script>) — instead of program", runtimes = { "node" } },
    dart_sdk    = { help = "dart: force the tool — unset: detected from pub's package_config (flutter when the package uses Flutter)", values = { "dart", "flutter" }, runtimes = { "dart" } },
    device      = { help = "dart: the Flutter desktop device to run on (unset: this machine's)", values = { "linux", "macos", "windows" }, runtimes = { "dart" } },
  },
  profile = {
    name             = { help = "the profile's name — also its file name" },
    base_env_files   = { help = "env files applied first, in order" },
    secret_manifests = { help = "secret manifests resolved at launch" },
    command_env      = { help = "values taken from commands' output ({ key, command, required? })" },
    runtime_env      = { help = "literal KEY=value pairs" },
    tags             = { help = "labels — informational" },
    replace          = { help = "append fields this layer replaces instead of extending (written by the panes)" },
    origin           = { help = "where the profile came from — informational" },
  },
}

---The documentation of `field` on a `record` ("config" or "profile"), or nil.
---@param record "config"|"profile"
---@param field string
---@return { help: string, values: string[]?, values_from: string?, kinds: string[]?, runtimes: string[]? }?
function M.field_doc(record, field)
  local docs = M.FIELD_DOCS[record]
  return docs and docs[field] or nil
end

---The value SHAPE a record's field takes — the catalog kind its validator
---checks: "string", "string_list", "string_map", "name", "run_kind", … — or
---nil for an unknown field. Editors use it to decide how to edit a field, so a
---new plain-string field is editable without a second list to keep in step.
---@param record "config"|"profile"
---@param field string
---@return string?
function M.field_kind(record, field)
  return (record == "profile" and PROFILE_FIELDS or CONFIG_FIELDS)[field]
end

---Every field name a record accepts, sorted (for completeness checks).
---@param record "config"|"profile"
---@return string[]
function M.field_names(record)
  local out = {}
  for k in pairs(record == "profile" and PROFILE_FIELDS or CONFIG_FIELDS) do out[#out + 1] = k end
  table.sort(out)
  return out
end

---Is `name` usable as a config/profile name (and therefore filename)?
---@param name any
---@return boolean ok, string? err
function M.valid_name(name)
  return VALIDATORS.name(name)
end

return M