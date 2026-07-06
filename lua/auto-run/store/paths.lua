---auto-run.store.paths — the ONE override-aware store-dir resolver
---(ADR-0048 §2.1, [[shared-resolver-single-source-of-truth]]).
---
---No other module — inside auto-run or outside — assembles `.auto-run/`
---paths. External callers go through `auto-run.store.resolve_run_dirs()`
---which delegates here; functions in this module never take a
---`workspace_root` / `cwd` parameter (ADR-0031 §3.1 precedent).
---
---Resolution contract (§2.1):
---
---  1. **Anchor** — `auto-core.git.worktree.get_active()`; only when
---     nil, the current buffer's directory, then `vim.fn.getcwd()`.
---     Never `get_workspace_root()` (conflates sibling repos).
---  2. **Override** — a `run.set_dir` override for the anchor's repo
---     (keyed by the repo's common_dir) replaces the shared-local
---     tier; `origin = "override"`.
---  3. **Tracked tier** — `<anchor worktree root>/.auto-run` (nil when
---     the anchor is not inside a git repo).
---  4. **Shared-local tier** — `repo_container(common_dir)/.auto-run`
---     for linked-worktree layouts; a plain repo degenerates to
---     `<repo>/.auto-run/local`.
---
---Caching: one resolved record per anchor, invalidated on
---`core.active_worktree:changed` / `core.workspace_root:changed`
---(subscriptions installed by `auto-run.setup()`) and on any
---`set_dir` call.
---@module 'auto-run.store.paths'

local fs_path = require("auto-core.fs.path")

local M = {}

local STATE_NS = "auto-run"

-- ── state namespace (override registry) ────────────────────────

local function state_ns()
  return require("auto-core.state").namespace(STATE_NS, {
    schema = nil,
    persist = "json",
  })
end

-- ── anchor resolution ───────────────────────────────────────────

---Resolve the anchor path for store resolution. Active worktree
---first; when unset, the current buffer's directory; last resort
---the cwd. Never the workspace root.
---@return string absolute path
function M.anchor()
  local ok, worktree = pcall(require, "auto-core.git.worktree")
  if ok and worktree then
    local active = worktree.get_active()
    if active and active ~= "" then
      return fs_path.normalize(active)
    end
  end
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname ~= "" and not bufname:match("^%w+://") then
    local dir = fs_path.parent(fs_path.normalize(bufname))
    if dir ~= "" and fs_path.is_dir(dir) then
      return dir
    end
  end
  return fs_path.normalize(vim.fn.getcwd())
end

-- ── override registry (run.set_dir, ADR-0031 §3.3 pattern) ─────

---Stable identity key for the repo containing `anchor`: the git
---common_dir when in a repo, otherwise the anchor itself.
---@param anchor string
---@param common string?
---@return string
local function override_key(anchor, common)
  if common and common ~= "" then return common end
  return anchor
end

---@param key string
---@return string? override_dir
local function get_override(key)
  local overrides = state_ns():get("dir_overrides")
  if type(overrides) ~= "table" then return nil end
  local v = overrides[key]
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

---Record a store dir in the known-dirs registry (mirrors
---`auto-core.todo`'s `known_dirs`; diagnostic surface for doctor /
---`run.status`).
---@param dir string
---@param key string
function M.upsert_known(dir, key)
  local ns = state_ns()
  local known = ns:get("known_dirs")
  known = type(known) == "table" and vim.deepcopy(known) or {}
  local entry = known[dir] or { keys = {} }
  entry.last_touched = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local seen = false
  for _, k in ipairs(entry.keys or {}) do
    if k == key then seen = true break end
  end
  if not seen then table.insert(entry.keys, key) end
  known[dir] = entry
  ns:set("known_dirs", known)
end

---Snapshot of the known-dirs registry, sorted by dir for stable
---iteration.
---@return { dir: string, last_touched: string?, keys: string[] }[]
function M.known_dirs()
  local known = state_ns():get("known_dirs")
  local out = {}
  if type(known) == "table" then
    for dir, entry in pairs(known) do
      out[#out + 1] = {
        dir          = dir,
        last_touched = entry.last_touched,
        keys         = entry.keys or {},
      }
    end
  end
  table.sort(out, function(a, b) return a.dir < b.dir end)
  return out
end

-- ── resolver cache ──────────────────────────────────────────────

---@type { anchor: string, dirs: AutoRunDirs }|nil
local _cache = nil

---Drop the cached resolution. Called on worktree/workspace change
---events and after every `set_dir`.
function M.invalidate()
  _cache = nil
end

-- ── the resolver ────────────────────────────────────────────────

---@class AutoRunDirs
---@field tracked string|nil    tracked tier: `<worktree>/.auto-run` (nil outside a repo)
---@field shared string         shared-local tier (or the override dir)
---@field origin "override"|"derived"
---@field anchor string         resolved anchor path (additive diagnostic field)
---@field root string|nil       anchor's worktree root (additive diagnostic field)
---@field container string|nil  repo container for linked layouts (additive diagnostic field)

---Resolve both store tiers for the current session. See the module
---doc for the locked contract; the return shape's first three fields
---are the ADR-0048 §2.1 contract, the rest are additive diagnostics
---(doctor, `run.status`, substitution context).
---@return AutoRunDirs
function M.resolve_run_dirs()
  local anchor = M.anchor()
  if _cache and _cache.anchor == anchor then
    return _cache.dirs
  end

  local repo = require("auto-core.git.repo")
  local worktree = require("auto-core.git.worktree")

  local root = repo.root(anchor)
  local common = root and repo.common_dir(anchor) or nil
  local container = common and worktree.repo_container(common) or nil

  local tracked = root and fs_path.join(root, ".auto-run") or nil

  local dirs
  local override = get_override(override_key(anchor, common))
  if override then
    dirs = {
      tracked   = tracked,
      shared    = fs_path.normalize(override),
      origin    = "override",
      anchor    = anchor,
      root      = root,
      container = container,
    }
  else
    local shared
    if root and container and container ~= root then
      -- Linked-worktree layout: container-level shared tier.
      shared = fs_path.join(container, ".auto-run")
    elseif root then
      -- Plain repo: degenerate layout, gitignored local/ subdir.
      shared = fs_path.join(root, ".auto-run", "local")
    else
      -- Not in a git repo at all: anchor-local degenerate layout.
      shared = fs_path.join(anchor, ".auto-run", "local")
    end
    dirs = {
      tracked   = tracked,
      shared    = shared,
      origin    = "derived",
      anchor    = anchor,
      root      = root,
      container = container,
    }
  end

  _cache = { anchor = anchor, dirs = dirs }
  return dirs
end

-- ── set_dir (override escape hatch) ─────────────────────────────

---Point the anchor's repo at a different shared-local store dir.
---`nil` / `""` clears the override. Returns the freshly-resolved
---dirs, or `(nil, err)` on invalid input.
---@param path string?
---@return AutoRunDirs? dirs, string? err
function M.set_dir(path)
  if path ~= nil and type(path) ~= "string" then
    return nil, "set_dir: path must be a string or nil, got " .. type(path)
  end

  local anchor = M.anchor()
  local repo = require("auto-core.git.repo")
  local common = repo.common_dir(anchor)
  local key = override_key(anchor, common)

  local ns = state_ns()
  local overrides = ns:get("dir_overrides")
  overrides = type(overrides) == "table" and vim.deepcopy(overrides) or {}
  if path == nil or path == "" then
    overrides[key] = nil
  else
    local abs = fs_path.normalize(vim.fn.expand(path))
    overrides[key] = abs
    M.upsert_known(abs, key)
  end
  ns:set("dir_overrides", overrides)
  M.invalidate()
  return M.resolve_run_dirs(), nil
end

-- ── tier sub-path helpers (internal to auto-run.store) ─────────

---`<tier>/configs` for a tier dir.
---@param tier_dir string
---@return string
function M.configs_dir(tier_dir)
  return fs_path.join(tier_dir, "configs")
end

---`<tier>/profiles` for a tier dir.
---@param tier_dir string
---@return string
function M.profiles_dir(tier_dir)
  return fs_path.join(tier_dir, "profiles")
end

---`<shared>/overrides.json` (merge layer 6 backing file).
---@param shared_dir string
---@return string
function M.overrides_file(shared_dir)
  return fs_path.join(shared_dir, "overrides.json")
end

---Test-only: wipe cache + override registry. Not part of the public
---API stability contract.
function M._reset_for_tests()
  _cache = nil
  local ns = state_ns()
  ns:set("dir_overrides", nil)
  ns:set("known_dirs", nil)
end

return M