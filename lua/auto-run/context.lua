---auto-run.context — the ONE answer to "what will run, and from where".
---
---Both auto-finder panes render a state header (ADR 0199 §5.2): the active
---worktree, the selected env file, the shared base, and — in the tests pane —
---which test config applies per runtime. Every value here is read from the
---owner that EXECUTION reads, never re-derived: the anchor from store.paths,
---the env selection from env, the base from import, and the test config from
---adapters.config.test_config_name — the resolver a test run itself calls. A
---header that computed its own answer could disagree with what runs, which is
---the failure this module exists to prevent.
---
---Cheap enough to call on every render. The one expensive read — the branch,
---which needs git subprocesses — is cached per repository root and dropped
---when the active worktree changes (M.invalidate).
---@module 'auto-run.context'

local M = {}

---root → { branch, label } | false  (false = probed, nothing known)
---@type table<string, table|false>
local _repo_cache = {}

---Drop cached repository identity (branch/label). Called on
---`core.active_worktree:changed`, and by a pane's explicit refresh — a
---checkout inside the same worktree changes the branch without changing the
---root, so a refresh has to be able to re-read it.
function M.invalidate()
  _repo_cache = {}
end

---Branch + workspace-relative label for a repository root, from auto-core's
---`git.graph.repo_at` — the owner of "where am I". `repo_at` is absent from
---older auto-core builds; then there is simply no branch to show, never an
---error.
---@param root string
---@return { branch: string?, label: string? }
local function repo_identity(root)
  local cached = _repo_cache[root]
  if cached ~= nil then return cached or {} end
  ---@type table|false
  local out = false
  local okg, graph = pcall(require, "auto-core.git.graph")
  if okg and type(graph) == "table" and type(graph.repo_at) == "function" then
    local okw, worktree = pcall(require, "auto-core.git.worktree")
    local ws = okw and worktree.get_workspace_root and worktree.get_workspace_root() or nil
    local okr, r = pcall(graph.repo_at, root, ws)
    if okr and type(r) == "table" then out = { branch = r.branch, label = r.label } end
  end
  _repo_cache[root] = out
  return out or {}
end

---Where auto-run is looking, and why.
---@return { anchor: string, source: "active"|"buffer"|"cwd", root: string?, is_repo: boolean, label: string, branch: string? }
function M.worktree()
  local anchor, source = require("auto-run.store.paths").anchor_with_source()
  local dirs = require("auto-run.store").resolve_run_dirs()
  local root = dirs.root
  local id = root and repo_identity(root) or {}
  return {
    anchor  = anchor,
    source  = source,
    root    = root,
    is_repo = root ~= nil,
    label   = id.label or vim.fn.fnamemodify(root or anchor, ":t"),
    branch  = id.branch,
  }
end

---The selected env file, as execution will read it.
---@return { path: string?, exists: boolean }
function M.env()
  local ok, env = pcall(require, "auto-run.env")
  local path = ok and env.get_selected() or nil
  return { path = path, exists = path ~= nil and vim.fn.filereadable(path) == 1 }
end

---The shared base (the selected launch config) — merged under EVERY run,
---debug and test launch (ADR 0199 §6.3), which is why it gets its own row.
---@return { name: string? }
function M.base()
  local ok, import = pcall(require, "auto-run.import")
  return { name = ok and import.get_selected() or nil }
end

---The test config that WILL apply for `runtime`, and why — straight from the
---resolver the test run calls.
---@param runtime string
---@return { name: string?, source: "picked"|"first"|"none", ignored_pick: string? }
function M.test_config(runtime)
  local name, source, ignored = require("auto-run.adapters.config").test_config_name(runtime)
  return { name = name, source = source, ignored_pick = ignored }
end

---Everything a header needs in one call.
---@param opts { runtimes: string[]? }?  runtimes to report a test config for
---@return table
function M.resolve(opts)
  opts = opts or {}
  local tests = {}
  for _, rt in ipairs(opts.runtimes or {}) do tests[rt] = M.test_config(rt) end
  return { worktree = M.worktree(), env = M.env(), base = M.base(), tests = tests }
end

function M._reset_for_tests()
  _repo_cache = {}
end

return M
