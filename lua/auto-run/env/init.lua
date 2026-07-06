---auto-run.env — substitution engine + layered env-profile
---composition pipeline + materialization lifecycle
---(ADR-0048 §3 substitution, §4 pipeline, §4.1 lifecycle).
---
---Substitution is UNIFORM across all string fields (unlike VSCode's
---partial application). Tokens:
---
---   ${worktree}         active worktree root
---   ${workspaceFolder}  alias of ${worktree} (launch.json compat)
---   ${containerRoot}    repo container (falls back to worktree root)
---   ${file}             current buffer's file
---   ${fileDirname}      its directory
---   ${env:VAR}          process environment
---   ${input:param}      LEFT UNRESOLVED in Phase 1 — recorded in the
---                       structured `needs_params` marker
---
---Composition pipeline (last wins):
---   base_env_files → config env_files → secret_manifests (Phase 1:
---   parse + surface names only; materialization via a pluggable
---   resolver hook) → command_env (trust-gated `run.command_env`;
---   untrusted entries FAIL composition — never skip) → runtime_env
---   templates → config-level env.
---
---Lifecycle (§4.1): one materialized file per run id under
---`stdpath("cache")/auto-run/env/<run-id>.env`, mode 0600 in a 0700
---dir, re-composed per launch, best-effort deleted on job exit, and
---swept at startup when older than 24h. Secret VALUES never enter
---logs, events, or return envelopes reachable from the mailbox —
---composition results stay in-process.
---
---Shell hygiene: composed keys must be valid environment-variable
---names (`[A-Za-z_][A-Za-z0-9_]*` — composition fails otherwise), and
---the materialized file — the ONLY serialization ever sourced by a
---shell (`. <file>` in the term strategy) — single-quotes every value
---with `'\''` escaping so values can never execute as program text.
---The run-strategy path hands the composed table to vim.system
---UNquoted; the two serializations are deliberately separate.
---@module 'auto-run.env'

local fs_path = require("auto-core.fs.path")
local log = require("auto-run.log")

local M = {}

-- ── env-key / shell-value hygiene ───────────────────────────────

---POSIX environment-variable name: letters/digits/underscore, no
---leading digit. Anything else cannot be represented safely in a
---shell-sourced env file, so composition refuses it up front.
local ENV_KEY_PATTERN = "^[A-Za-z_][A-Za-z0-9_]*$"

---Is `key` a valid environment-variable name?
---@param key any
---@return boolean
function M.valid_env_key(key)
  return type(key) == "string" and key:match(ENV_KEY_PATTERN) ~= nil
end

---Single-quote a value for POSIX shell sourcing (`'` → `'\''`).
---ONLY for the materialized-file serialization consumed via
---`. <file>` — the run-strategy path passes env as a vim.system
---table and must never receive quoted values.
---@param value string
---@return string
local function shell_single_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- ── substitution engine ─────────────────────────────────────────

---@class AutoRunSubstCtx
---@field worktree string?   active worktree root
---@field container string?  repo container
---@field file string?       current file (absolute)

---Default substitution context from the store resolver + current
---buffer. Callers may override any field.
---@param overrides AutoRunSubstCtx?
---@return AutoRunSubstCtx
function M.context(overrides)
  local dirs = require("auto-run.store.paths").resolve_run_dirs()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or file:match("^%w+://") then file = nil end
  local ctx = {
    worktree  = dirs.root or dirs.anchor,
    container = dirs.container or dirs.root or dirs.anchor,
    file      = file and fs_path.normalize(file) or nil,
  }
  for k, v in pairs(overrides or {}) do ctx[k] = v end
  return ctx
end

---Substitute tokens in one string. `${input:x}` tokens are left
---intact; their names are appended to `needs_params` (deduped).
---Tokens whose context value is missing (e.g. `${file}` with no
---buffer) are also left intact and recorded in `unresolved`.
---@param s string
---@param ctx AutoRunSubstCtx
---@param needs_params string[]?  accumulator (created when nil)
---@param unresolved string[]?    accumulator (created when nil)
---@return string out, string[] needs_params, string[] unresolved
function M.substitute(s, ctx, needs_params, unresolved)
  needs_params = needs_params or {}
  unresolved = unresolved or {}
  if type(s) ~= "string" then return s, needs_params, unresolved end

  local function note(list, item)
    for _, x in ipairs(list) do
      if x == item then return end
    end
    list[#list + 1] = item
  end

  local out = s:gsub("%${([^}]+)}", function(token)
    if token == "worktree" or token == "workspaceFolder" then
      if ctx.worktree then return ctx.worktree end
      note(unresolved, token)
    elseif token == "containerRoot" then
      if ctx.container then return ctx.container end
      note(unresolved, token)
    elseif token == "file" then
      if ctx.file then return ctx.file end
      note(unresolved, token)
    elseif token == "fileDirname" then
      if ctx.file then return fs_path.parent(ctx.file) end
      note(unresolved, token)
    else
      local var = token:match("^env:(.+)$")
      if var then
        local val = vim.env[var]
        if val ~= nil then return val end
        note(unresolved, token)
        return "${" .. token .. "}"
      end
      local param = token:match("^input:(.+)$")
      if param then
        note(needs_params, param)   -- Phase 1: structured marker, no prompt
      else
        note(unresolved, token)     -- unknown token: leave + report
      end
    end
    return "${" .. token .. "}"
  end)
  return out, needs_params, unresolved
end

---Deep substitution over every string field of a table (uniform
---substitution contract). Returns a NEW value; the input is not
---mutated. Table keys are left untouched.
---@param value any
---@param ctx AutoRunSubstCtx
---@return any out, string[] needs_params, string[] unresolved
function M.substitute_deep(value, ctx)
  local needs_params, unresolved = {}, {}
  local function walk(v)
    if type(v) == "string" then
      local out = M.substitute(v, ctx, needs_params, unresolved)
      return out
    elseif type(v) == "table" and v ~= vim.NIL then
      local out = {}
      for k, item in pairs(v) do out[k] = walk(item) end
      return out
    end
    return v
  end
  return walk(value), needs_params, unresolved
end

-- ── env-file / manifest parsing ─────────────────────────────────

---Parse a dotenv-style file: `KEY=VAL`, quoted values stripped,
---leading `export ` tolerated, `#` comment lines skipped.
---@param path string
---@return table<string, string>? env, string? err
function M.parse_env_file(path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  local out = {}
  for line in f:lines() do
    local s = line:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" and s:sub(1, 1) ~= "#" then
      s = s:gsub("^export%s+", "")
      local key, val = s:match("^([%a_][%w_%-%.]*)%s*=%s*(.*)$")
      if key then
        local q = val:sub(1, 1)
        if (q == '"' or q == "'") and #val >= 2 and val:sub(-1) == q then
          val = val:sub(2, -2)
        end
        out[key] = val
      end
    end
  end
  f:close()
  return out, nil
end

---@class AutoRunSecretRef
---@field key string       env var name
---@field secret string    secret-manager name (a REF, never a value)
---@field version string?  optional @version
---@field toml_path string? optional #toml-path selector
---@field manifest string  source manifest file

---Parse a gcp-env-grammar secret manifest:
---`KEY=secret-name[@version][#toml-path]` per line, `#`-prefixed
---comment LINES skipped (a `#` after `=` is the toml-path selector).
---@param path string
---@return AutoRunSecretRef[]? refs, string? err
function M.parse_secret_manifest(path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  local out = {}
  for line in f:lines() do
    local s = line:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" and s:sub(1, 1) ~= "#" then
      local key, rest = s:match("^([%a_][%w_]*)%s*=%s*(.+)$")
      if key then
        local secret = rest:match("^([^@#%s]+)")
        if secret then
          out[#out + 1] = {
            key      = key,
            secret   = secret,
            version  = rest:match("@([^#%s]+)"),
            toml_path = rest:match("#(%S+)"),
            manifest = path,
          }
        end
      end
    end
  end
  f:close()
  return out, nil
end

-- ── pluggable secret resolver (Phase 1 hook) ────────────────────

---@type (fun(refs: AutoRunSecretRef[]): table<string, string>?, string?)|nil
local _secret_resolver = nil

---Register the secret-materialization hook (the gcp-env flow plugs
---in here in a later phase). `fn(refs) → values_by_key | nil, err`.
---Pass nil to clear.
---@param fn (fun(refs: AutoRunSecretRef[]): table<string, string>?, string?)|nil
function M.set_secret_resolver(fn)
  if fn ~= nil and type(fn) ~= "function" then
    error("auto-run.env.set_secret_resolver: fn must be a function or nil")
  end
  _secret_resolver = fn
end

-- ── runtime_env templates ───────────────────────────────────────

---Expand `{{token}}` templates: `home` → $HOME, `app` → the config
---name, otherwise an already-composed env key, otherwise the process
---environment; unknown tokens are left intact.
---@param template string
---@param app string?
---@param composed table<string, string>
---@return string
local function expand_runtime_template(template, app, composed)
  return (template:gsub("{{%s*([%w_]+)%s*}}", function(token)
    if token == "home" then return vim.env.HOME or "" end
    if token == "app" then return app or "" end
    if composed[token] ~= nil then return composed[token] end
    local envv = vim.env[token]
    if envv ~= nil then return envv end
    return "{{" .. token .. "}}"
  end))
end

-- ── composition pipeline ────────────────────────────────────────

---@class AutoRunComposeResult
---@field ok true
---@field env table<string, string>       composed variables (in-process only)
---@field keys string[]                   sorted key names (safe to surface)
---@field secret_refs AutoRunSecretRef[]  manifest entries (names only)
---@field pending_secrets string[]        manifest keys with no resolver registered
---@field warnings string[]
---@field needs_params string[]
---@field unresolved string[]

---@class AutoRunComposeError
---@field code string      "trust_required"|"command_env_failed"|"command_env_timeout"|"env_file_missing"|"manifest_missing"|"secret_resolver_failed"|"invalid_env_key"
---@field message string
---@field capability string?
---@field command string?
---@field key string?
---@field reason string?

---Compose the effective environment for a config (post-merge
---effective table — the profile's pipeline fields are already merged
---onto it as layer 5). Returns `(result, nil)` or `(nil, err)` with a
---structured error; composition failures are hard per §4 — a missing
---required piece aborts, it never silently skips.
---@param cfg table              effective config (from store.get)
---@param opts { ctx: AutoRunSubstCtx? }?
---@return AutoRunComposeResult? result, AutoRunComposeError? err
function M.compose(cfg, opts)
  opts = opts or {}
  if type(cfg) ~= "table" then
    return nil, { code = "invalid_config", message = "compose: cfg must be a table" }
  end
  local ctx = opts.ctx or M.context()

  local composed = {}
  local warnings = {}
  local needs_params, unresolved = {}, {}

  local function sub(s)
    local out = M.substitute(s, ctx, needs_params, unresolved)
    return out
  end

  -- 1 + 2. base_env_files, then config env_files (ordered, later wins).
  for _, field in ipairs({ "base_env_files", "env_files" }) do
    for _, raw_path in ipairs(cfg[field] or {}) do
      local path = fs_path.normalize(vim.fn.expand(sub(raw_path)))
      local parsed, perr = M.parse_env_file(path)
      if not parsed then
        return nil, {
          code = "env_file_missing",
          message = field .. ": " .. tostring(perr),
        }
      end
      for k, v in pairs(parsed) do composed[k] = v end
    end
  end

  -- 3. secret manifests — Phase 1: parse + surface NAMES; values only
  -- through the pluggable resolver hook.
  local secret_refs, pending_secrets = {}, {}
  local secret_keys = {}
  for _, raw_path in ipairs(cfg.secret_manifests or {}) do
    local path = fs_path.normalize(vim.fn.expand(sub(raw_path)))
    local refs, merr = M.parse_secret_manifest(path)
    if not refs then
      return nil, { code = "manifest_missing", message = tostring(merr) }
    end
    vim.list_extend(secret_refs, refs)
  end
  if #secret_refs > 0 then
    if _secret_resolver then
      local values, rerr = _secret_resolver(secret_refs)
      if not values then
        return nil, {
          code = "secret_resolver_failed",
          message = "secret resolver failed: " .. tostring(rerr),
        }
      end
      for _, ref in ipairs(secret_refs) do
        if values[ref.key] ~= nil then
          composed[ref.key] = values[ref.key]
          secret_keys[ref.key] = true
        else
          pending_secrets[#pending_secrets + 1] = ref.key
        end
      end
    else
      for _, ref in ipairs(secret_refs) do
        pending_secrets[#pending_secrets + 1] = ref.key
      end
      if #pending_secrets > 0 then
        warnings[#warnings + 1] = "no secret resolver registered; "
          .. #pending_secrets .. " manifest key(s) not materialized"
      end
    end
  end

  -- 4. command_env — trust-gated per entry; untrusted FAILS.
  for _, entry in ipairs(cfg.command_env or {}) do
    local cmd = sub(entry.command)
    local trust = require("auto-core.trust")
    local allowed, reason = trust.check("run.command_env", cmd)
    if not allowed then
      return nil, {
        code       = "trust_required",
        capability = "run.command_env",
        command    = cmd,
        reason     = reason,
        message    = "command_env entry '" .. entry.key .. "' requires the "
          .. "run.command_env trust capability (" .. tostring(reason) .. "); "
          .. "acknowledge + enable it interactively first",
      }
    end
    -- Timeout policy: composition sits on interactive + mailbox
    -- launch paths, so a hung command must never block the UI
    -- indefinitely (env.command_timeout_ms, default 10000).
    local timeout_ms = require("auto-run.config").options.env.command_timeout_ms
      or 10000
    local res = vim.system({ "sh", "-c", cmd },
      { text = true, timeout = timeout_ms }):wait()
    local timed_out = res.code == 124 and (res.signal == 15 or res.signal == 9)
    if timed_out then
      if entry.required == false then
        warnings[#warnings + 1] = "command_env '" .. entry.key
          .. "' timed out after " .. timeout_ms .. "ms; skipped (required=false)"
      else
        return nil, {
          code    = "command_env_timeout",
          key     = entry.key,
          command = cmd,
          message = "command_env '" .. entry.key .. "' timed out after "
            .. timeout_ms .. "ms (env.command_timeout_ms)",
        }
      end
    elseif res.code ~= 0 then
      if entry.required == false then
        warnings[#warnings + 1] = "command_env '" .. entry.key
          .. "' failed (exit " .. tostring(res.code) .. "); skipped (required=false)"
      else
        return nil, {
          code    = "command_env_failed",
          key     = entry.key,
          message = "command_env '" .. entry.key .. "' failed (exit "
            .. tostring(res.code) .. ")",
        }
      end
    else
      composed[entry.key] = (res.stdout or ""):gsub("%s+$", "")
      secret_keys[entry.key] = true
    end
  end

  -- 5. runtime_env templates.
  for k, template in pairs(cfg.runtime_env or {}) do
    if type(template) == "string" then
      composed[k] = expand_runtime_template(sub(template), cfg.name, composed)
    end
  end

  -- 6. config-level inline env (non-secret; per-key, last wins).
  for k, v in pairs(cfg.env or {}) do
    if type(v) == "string" then composed[k] = sub(v) end
  end

  -- Key hygiene: every composed name must be a valid environment
  -- variable name — anything else cannot be materialized safely and
  -- fails composition up front (never written anywhere).
  for k in pairs(composed) do
    if not M.valid_env_key(k) then
      return nil, {
        code    = "invalid_env_key",
        key     = tostring(k),
        message = "composed env key '" .. tostring(k)
          .. "' is not a valid environment variable name"
          .. " ([A-Za-z_][A-Za-z0-9_]*)",
      }
    end
  end

  local keys = {}
  for k in pairs(composed) do keys[#keys + 1] = k end
  table.sort(keys)
  table.sort(pending_secrets)

  -- Never log values; key names + counts only.
  log.debug("env", "composed " .. #keys .. " var(s) for '"
    .. tostring(cfg.name) .. "' (" .. #secret_refs .. " secret ref(s))")

  return {
    ok              = true,
    env             = composed,
    keys            = keys,
    secret_refs     = secret_refs,
    pending_secrets = pending_secrets,
    warnings        = warnings,
    needs_params    = needs_params,
    unresolved      = unresolved,
  }, nil
end

-- ── materialization lifecycle (§4.1) ────────────────────────────

---Resolved materialization dir (`stdpath("cache")/auto-run/env` or
---the configured override). Never inside a repo.
---@return string
function M.materialize_dir()
  local cfg = require("auto-run.config").options
  return cfg.env.dir or (vim.fn.stdpath("cache") .. "/auto-run/env")
end

---Ensure a directory exists with mode 0700.
---@param dir string
---@return boolean ok, string? err
local function ensure_private_dir(dir)
  local okm, merr = pcall(vim.fn.mkdir, dir, "p", tonumber("700", 8))
  if not okm then return false, "mkdir: " .. tostring(merr) end
  pcall(vim.uv.fs_chmod, dir, tonumber("700", 8))
  return true
end

---Materialize a composed env map to
---`<materialize_dir>/<run-id>.env`, mode 0600 (parent 0700), written
---atomically (temp + rename, both inside the private dir). One file
---per run id; every launch re-composes.
---
---This file is consumed by POSIX `. <file>` sourcing (term strategy):
---keys are validated as env-var names and values are single-quoted
---with `'\''` escaping, so values can never be read as shell program
---text. Do NOT reuse this serializer for the run-strategy path — that
---one hands the composed table to vim.system unquoted.
---@param run_id string
---@param env table<string, string>
---@return string? path, string? err
function M.materialize(run_id, env)
  if type(run_id) ~= "string" or run_id == "" or run_id:match("[/%s]") then
    return nil, "materialize: run_id must be a non-empty path-safe string"
  end
  if type(env) ~= "table" then
    return nil, "materialize: env must be a table"
  end

  local keys = {}
  for k in pairs(env) do
    if not M.valid_env_key(k) then
      return nil, "materialize: invalid env key '" .. tostring(k)
        .. "' (must match [A-Za-z_][A-Za-z0-9_]*); nothing written"
    end
    keys[#keys + 1] = k
  end
  table.sort(keys)

  local dir = M.materialize_dir()
  local okd, derr = ensure_private_dir(dir)
  if not okd then return nil, derr end

  local lines = {}
  for _, k in ipairs(keys) do
    lines[#lines + 1] = k .. "=" .. shell_single_quote(tostring(env[k]))
  end
  local text = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")

  local final = dir .. "/" .. run_id .. ".env"
  local tmp = dir .. "/.tmp-" .. tostring(vim.uv.hrtime())
  local fd, oerr = vim.uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then return nil, "fs_open: " .. tostring(oerr) end
  local _, werr = vim.uv.fs_write(fd, text, 0)
  if werr then
    pcall(vim.uv.fs_close, fd)
    pcall(vim.uv.fs_unlink, tmp)
    return nil, "fs_write: " .. tostring(werr)
  end
  pcall(vim.uv.fs_fsync, fd)
  local _, cerr = vim.uv.fs_close(fd)
  if cerr then
    pcall(vim.uv.fs_unlink, tmp)
    return nil, "fs_close: " .. tostring(cerr)
  end
  local rok, rerr = vim.uv.fs_rename(tmp, final)
  if not rok then
    pcall(vim.uv.fs_unlink, tmp)
    return nil, "fs_rename: " .. tostring(rerr)
  end
  pcall(vim.uv.fs_chmod, final, tonumber("600", 8))

  log.debug("env", "materialized env for run " .. run_id)  -- run id only, never the path/keys
  return final, nil
end

---Best-effort removal of one run's materialized file (job-exit path;
---Phase 2's job engine calls this).
---@param run_id string
function M.discard(run_id)
  if type(run_id) ~= "string" or run_id == "" then return end
  pcall(vim.uv.fs_unlink, M.materialize_dir() .. "/" .. run_id .. ".env")
end

---Startup sweep: remove materialized files (and stale temp files)
---older than the configured max age (default 24h) — crash leftovers
---per §4.1. Silent; returns the number removed for diagnostics.
---@return integer removed
function M.sweep()
  local dir = M.materialize_dir()
  if not fs_path.is_dir(dir) then return 0 end
  local cfg = require("auto-run.config").options
  local max_age = (cfg.env.sweep_max_age_hours or 24) * 3600
  local now = os.time()
  local removed = 0
  for _, f in ipairs(vim.fn.readdir(dir) or {}) do
    if f:match("%.env$") or f:match("^%.tmp%-") then
      local full = dir .. "/" .. f
      local stat = vim.uv.fs_stat(full)
      if stat and stat.mtime and (now - stat.mtime.sec) > max_age then
        local oku = pcall(function() return vim.uv.fs_unlink(full) end)
        if oku and not fs_path.exists(full) then removed = removed + 1 end
      end
    end
  end
  if removed > 0 then
    log.debug("env", "sweep removed " .. removed .. " stale env file(s)")
  end
  return removed
end

return M