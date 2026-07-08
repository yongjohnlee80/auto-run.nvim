---auto-run.env — substitution engine + layered env-profile
---composition pipeline + materialization lifecycle + env-file
---selection/editing (ADR-0048 §3 substitution, §4 pipeline,
---§4.1 lifecycle, §4.2 selection — r5).
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
---   base_env_files → config env_files → SELECTED env file (§4.2 r5
---   per-repo pick — the final, highest-precedence env_files entry)
---   → secret_manifests (Phase 1: parse + surface names only;
---   materialization via a pluggable resolver hook) → command_env
---   (trust-gated `run.command_env`; untrusted entries FAIL
---   composition — never skip) → runtime_env templates →
---   config-level env.
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

-- ── events + structured errors ──────────────────────────────────

local function publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events then pcall(events.publish, topic, payload) end
end

---A structured env error: a table carrying `code` (+ context fields)
---that stringifies to its message (store-module convention), so
---`tostring(err)` call sites keep working while mailbox handlers map
---`err.code` onto envelope codes.
---@param code string
---@param message string
---@param fields table?
---@return table
local function structured_err(code, message, fields)
  local e = vim.tbl_extend("force", { code = code, message = message },
    fields or {})
  return setmetatable(e, { __tostring = function(self) return self.message end })
end

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

-- ── env-file selection (ADR-0048 §4.2, r5) ──────────────────────
-- A per-repo "selected env file" persisted in the shared-local
-- tier's state.json (key `selected_env_file` — same mechanism as
-- exec's pick memory). The selection is applied to EVERY launch as
-- the highest-precedence env_files entry inside `compose()` — every
-- launch path funnels through compose, so that is the one
-- invocation-layer chokepoint (see the compose step 2.5 note).
-- Persistence is worktree-relative when the file sits under the
-- active worktree root (so the selection survives a worktree switch
-- within the same container), absolute otherwise.

---The absolute path of the selected env file for the current repo,
---or nil when none is selected. Relative persistence resolves
---against the CURRENT worktree root.
---@return string? path
function M.get_selected()
  local store = require("auto-run.store")
  local stored = store.read_state().selected_env_file
  if type(stored) ~= "string" or stored == "" then return nil end
  if stored:sub(1, 1) == "/" then return fs_path.normalize(stored) end
  local dirs = store.resolve_run_dirs()
  return fs_path.normalize(fs_path.join(dirs.root or dirs.anchor, stored))
end

---Select (or clear with nil/"") the env file applied to every
---subsequent launch. The file must exist. Publishes
---`run.env:changed` {action="selected", path} — the path only, never
---file contents.
---@param path string?  absolute or ~-expandable path; nil clears
---@return boolean? ok, table? err  structured {code=...}
function M.set_selected(path)
  local store = require("auto-run.store")
  if path == nil or path == "" then
    local state = store.read_state()
    if state.selected_env_file ~= nil then
      state.selected_env_file = nil
      local okw, werr = store.write_state(state)
      if not okw then
        return nil, structured_err("write_failed",
          "set_selected: state.json write failed: " .. tostring(werr))
      end
    end
    publish("run.env:changed", { action = "selected", path = nil })
    return true, nil
  end
  if type(path) ~= "string" then
    return nil, structured_err("invalid_args",
      "set_selected: path must be a string or nil, got " .. type(path))
  end
  local abs = fs_path.normalize(vim.fn.expand(path))
  if not fs_path.is_file(abs) then
    return nil, structured_err("not_found",
      "set_selected: no such env file: " .. abs)
  end
  local dirs = store.resolve_run_dirs()
  local root = dirs.root or dirs.anchor
  local stored = abs
  if root and fs_path.is_under(abs, root) then
    stored = abs:sub(#root + 2)   -- worktree-relative (container-portable)
  end
  local state = store.read_state()
  state.selected_env_file = stored
  local okw, werr = store.write_state(state)
  if not okw then
    return nil, structured_err("write_failed",
      "set_selected: state.json write failed: " .. tostring(werr))
  end
  publish("run.env:changed", { action = "selected", path = abs })
  log.debug("env", "selected env file changed")  -- never the path/keys
  return true, nil
end

---@class AutoRunEnvCandidate
---@field path string      absolute normalized path
---@field source string    "config:<name>" | "profile:<name>" | "discovered"
---@field exists boolean
---@field selected boolean

---Ordered candidate env files for the current repo (§4.2):
---
---  1. files referenced by any config's effective `env_files` and
---     any profile's `base_env_files`, resolved through substitution
---     with the current anchor (paths still carrying unresolved
---     `${...}` tokens are skipped — they cannot be selected);
---  2. a bounded NON-recursive glob: `<container>/.config/*.env` and
---     `<worktree>/{.env,.env.*,*.env}` (dirs skipped; node_modules
---     never entered — the glob does not recurse).
---
---Deterministic order: referenced first (store listing order), then
---discovered alphabetically; deduped by normalized path (first
---source wins). The `selected` flag marks the per-repo pick.
---@return AutoRunEnvCandidate[]
function M.files_list()
  local store = require("auto-run.store")
  local ctx = M.context()
  local out, seen = {}, {}

  local function add_referenced(raw, source)
    if type(raw) ~= "string" or raw == "" then return end
    local sub = M.substitute(raw, ctx)
    if sub:find("${", 1, true) then return end
    local abs = fs_path.normalize(vim.fn.expand(sub))
    if seen[abs] then return end
    seen[abs] = true
    out[#out + 1] = { path = abs, source = source, exists = fs_path.is_file(abs) }
  end

  for _, c in ipairs(store.list()) do
    if not c.error then
      local eff = store.get(c.name)
      if eff then
        for _, p in ipairs(eff.env_files or {}) do
          add_referenced(p, "config:" .. c.name)
        end
      end
    end
  end
  for _, pr in ipairs(store.list_profiles()) do
    local prof = store.get_profile(pr.name)
    if prof then
      for _, p in ipairs(prof.base_env_files or {}) do
        add_referenced(p, "profile:" .. pr.name)
      end
    end
  end

  -- Bounded non-recursive glob (top-level readdir only).
  local dirs = store.resolve_run_dirs()
  local found = {}
  local function scan_dir(dir, match)
    if not dir or not fs_path.is_dir(dir) then return end
    for _, f in ipairs(vim.fn.readdir(dir) or {}) do
      if match(f) then
        local full = fs_path.join(dir, f)
        if fs_path.is_file(full) and not seen[full] then
          seen[full] = true
          found[#found + 1] = full
        end
      end
    end
  end
  if dirs.container then
    scan_dir(fs_path.join(dirs.container, ".config"), function(f)
      return f:match("%.env$") ~= nil
    end)
  end
  scan_dir(dirs.root or dirs.anchor, function(f)
    return f == ".env" or f:match("^%.env%.") ~= nil or f:match("%.env$") ~= nil
  end)
  table.sort(found)
  for _, p in ipairs(found) do
    out[#out + 1] = { path = p, source = "discovered", exists = true }
  end

  local selected = M.get_selected()
  for _, e in ipairs(out) do
    e.selected = selected ~= nil and e.path == selected
  end
  return out
end

-- ── env-file inspection + editing (ADR-0048 §4.2, r5) ───────────
-- Panel-local surfaces: read_file returns VALUES (with line numbers)
-- for interactive display ONLY — equivalent to `:e`-ing the file.
-- Callers must never log values or put them in events / mailbox
-- responses; the masking boundary (§4.2 r5) is unchanged.

---@class AutoRunEnvFileEntry
---@field key string
---@field value string   for panel display only — never log/forward
---@field lnum integer   1-based line number in the file

---Parse an env file for panel display, RETAINING line numbers. Same
---dotenv semantics as `parse_env_file` (leading `export ` tolerated,
---surrounding quotes stripped, `#` comment lines skipped). Non-blank
---non-comment lines that don't parse land in `errors`.
---@param path string
---@return { entries: AutoRunEnvFileEntry[], errors: { lnum: integer, message: string }[] }? result, table? err
function M.read_file(path)
  if type(path) ~= "string" or path == "" then
    return nil, structured_err("invalid_args",
      "read_file: path must be a non-empty string")
  end
  local f = io.open(path, "r")
  if not f then
    return nil, structured_err("not_found", "read_file: cannot open " .. path)
  end
  local entries, errors = {}, {}
  local lnum = 0
  for line in f:lines() do
    lnum = lnum + 1
    local s = line:gsub("^%s+", ""):gsub("%s+$", "")
    if s ~= "" and s:sub(1, 1) ~= "#" then
      s = s:gsub("^export%s+", "")
      local key, val = s:match("^([%a_][%w_%-%.]*)%s*=%s*(.*)$")
      if key then
        local q = val:sub(1, 1)
        if (q == '"' or q == "'") and #val >= 2 and val:sub(-1) == q then
          val = val:sub(2, -2)
        end
        entries[#entries + 1] = { key = key, value = val, lnum = lnum }
      else
        errors[#errors + 1] = { lnum = lnum, message = "unparseable entry" }
      end
    end
  end
  f:close()
  return { entries = entries, errors = errors }, nil
end

---Parse one raw line as a dotenv entry for REWRITING: `head` is
---everything before the value text (leading whitespace, optional
---`export `, the key, `=` with its surrounding spacing) and `quote`
---is the entry's current quoting style (`'` | `"` | "" for bare).
---@param line string
---@return { key: string, head: string, quote: string }?
local function parse_entry_line(line)
  local head, key, val =
    line:match("^(%s*export%s+([%a_][%w_%-%.]*)%s*=%s*)(.*)$")
  if not head then
    head, key, val = line:match("^(%s*([%a_][%w_%-%.]*)%s*=%s*)(.*)$")
  end
  if not head then return nil end
  local trimmed = val:gsub("%s+$", "")
  local q = trimmed:sub(1, 1)
  local quote = ""
  if (q == '"' or q == "'") and #trimmed >= 2 and trimmed:sub(-1) == q then
    quote = q
  end
  return { key = key, head = head, quote = quote }
end

---Render `value` preserving `prefer`red quote style ("'" | '"' | ""
---for bare/new): a quoted entry stays in its quote style (falling
---back to the other quote char when the value contains it); bare/new
---entries are quoted only when the value needs it (empty, spaces,
---`#`, quotes). nil when the value contains BOTH quote characters —
---the quote-stripping parser cannot round-trip that.
---@param value string
---@param prefer string
---@return string? rendered
local function render_entry_value(value, prefer)
  local function wrap(q)
    if value:find(q, 1, true) ~= nil then return nil end
    return q .. value .. q
  end
  if prefer == "'" or prefer == '"' then
    return wrap(prefer) or wrap(prefer == "'" and '"' or "'")
  end
  if value ~= "" and not value:match("[%s#'\"]") then return value end
  return wrap('"') or wrap("'")
end

---Rewrite one env file atomically, preserving every untouched line
---byte-for-byte (comments, blanks, entry order) and the original
---file mode. `mutate(lines) → true|nil, err` edits the line array in
---place.
---@param path string
---@param mutate fun(lines: string[]): boolean?, table?
---@return boolean? ok, table? err
local function rewrite_env_file(path, mutate)
  local f = io.open(path, "r")
  if not f then
    return nil, structured_err("not_found", "cannot open " .. path)
  end
  local content = f:read("*a") or ""
  f:close()
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end

  local okm, merr = mutate(lines)
  if not okm then return nil, merr end

  local st = vim.uv.fs_stat(path)
  local fs_atomic = require("auto-core.fs.atomic")
  local text = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
  local okw, werr = fs_atomic.write(path, text)
  if not okw then
    return nil, structured_err("write_failed",
      "atomic write failed: " .. tostring(werr))
  end
  if st then  -- fs.atomic's rename resets the mode; restore it
    pcall(vim.uv.fs_chmod, path, require("bit").band(st.mode, 511))
  end
  return true, nil
end

---Update an existing KEY's value in an env file. Preserves comment
---lines, blank lines, entry order and the entry's quoting style;
---when the file holds duplicate keys, the LAST occurrence (the
---effective one under dotenv last-wins parsing) is updated. Publishes
---`run.env:changed` {action="updated", path, key} — the KEY name
---only, NEVER the value.
---@param path string
---@param key string
---@param value string
---@return boolean? ok, table? err  structured {code="invalid_key"|"invalid_args"|"not_found"|"invalid_value"|"write_failed"}
function M.update_var(path, key, value)
  if not M.valid_env_key(key) then
    return nil, structured_err("invalid_key",
      "update_var: '" .. tostring(key)
      .. "' is not a valid environment variable name"
      .. " ([A-Za-z_][A-Za-z0-9_]*)", { key = tostring(key) })
  end
  if type(path) ~= "string" or path == "" or type(value) ~= "string" then
    return nil, structured_err("invalid_args",
      "update_var: path and value must be strings")
  end
  path = fs_path.normalize(path)
  local ok, err = rewrite_env_file(path, function(lines)
    local idx, entry
    for i, line in ipairs(lines) do
      local e = parse_entry_line(line)
      if e and e.key == key then idx, entry = i, e end
    end
    if not idx then
      return nil, structured_err("not_found",
        "update_var: key '" .. key .. "' not found in " .. path,
        { key = key })
    end
    local rendered = render_entry_value(value, entry.quote)
    if not rendered then
      return nil, structured_err("invalid_value",
        "update_var: the value contains both quote characters — "
        .. "not representable in a dotenv file", { key = key })
    end
    lines[idx] = entry.head .. rendered
    return true
  end)
  if not ok then return nil, err end
  publish("run.env:changed", { action = "updated", path = path, key = key })
  return true, nil
end

---Append a NEW KEY=VALUE entry to an env file. The key must not
---already exist (structured already_exists otherwise — the caller
---decides to update instead). New entries are quoted only when the
---value needs it. Publishes `run.env:changed` {action="added", path,
---key} — the KEY name only, NEVER the value.
---@param path string
---@param key string
---@param value string
---@return boolean? ok, table? err  structured {code="invalid_key"|"invalid_args"|"not_found"|"already_exists"|"invalid_value"|"write_failed"}
function M.add_var(path, key, value)
  if not M.valid_env_key(key) then
    return nil, structured_err("invalid_key",
      "add_var: '" .. tostring(key)
      .. "' is not a valid environment variable name"
      .. " ([A-Za-z_][A-Za-z0-9_]*)", { key = tostring(key) })
  end
  if type(path) ~= "string" or path == "" or type(value) ~= "string" then
    return nil, structured_err("invalid_args",
      "add_var: path and value must be strings")
  end
  path = fs_path.normalize(path)
  local ok, err = rewrite_env_file(path, function(lines)
    for _, line in ipairs(lines) do
      local e = parse_entry_line(line)
      if e and e.key == key then
        return nil, structured_err("already_exists",
          "add_var: key '" .. key .. "' already exists in " .. path
          .. " (use update_var)", { key = key })
      end
    end
    local rendered = render_entry_value(value, "")
    if not rendered then
      return nil, structured_err("invalid_value",
        "add_var: the value contains both quote characters — "
        .. "not representable in a dotenv file", { key = key })
    end
    lines[#lines + 1] = key .. "=" .. rendered
    return true
  end)
  if not ok then return nil, err end
  publish("run.env:changed", { action = "added", path = path, key = key })
  return true, nil
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
---@param opts { ctx: AutoRunSubstCtx?, no_selected: boolean? }?
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

  -- 2.5. The per-repo SELECTED env file (§4.2, r5) — applied as the
  -- final, highest-precedence env_files entry. Every launch path
  -- (exec.prepare, dap.translate / debug_test, the go adapter's
  -- test_config for discovery run_position) funnels through
  -- compose(), so this is the one invocation-layer chokepoint. The
  -- later pipeline stages (secret_manifests, command_env,
  -- runtime_env, config-level `env`) still win per §3.1 —
  -- config-level env keys beat the selection. A selection whose file
  -- vanished is a hard error, never a silent skip.
  -- `opts.no_selected = true` opts a caller out (raw composition).
  if not opts.no_selected then
    local selected = M.get_selected()
    if selected then
      local parsed, perr = M.parse_env_file(selected)
      if not parsed then
        return nil, {
          code = "env_file_missing",
          message = "selected env file: " .. tostring(perr)
            .. " (clear with :AutoRun env clear)",
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