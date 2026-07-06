---auto-run.discovery — position model + discovery core (ADR-0048 §7).
---
---The core owns everything adapters must NOT re-implement (neotest
---lesson #8/#9): the position tree (`dir → file → namespace → test`,
---ids `path::ns::name`, flat `_nodes` map for O(1) lookup), upward
---status aggregation + missing-result filling, fallback decomposition
---(`build_spec` nil → retry finer), and the discovery lifecycle.
---
---Discovery anchors at the ACTIVE WORKTREE via the store resolver
---(`resolve_run_dirs().root`/`anchor` — never `getcwd`, never the
---workspace root). The walk prunes any subdirectory containing a
---`.git` entry (dir or gitfile) — `list_child_repos()` provides the
---known exclusion set and the walk independently skips unseen nested
---repos — plus hidden dirs and adapter `filter_dir` rejections.
---
---Performance stance (neotest pitfall #1): default discovery = open
---buffers (BufReadPost parse + BufWritePost re-parse) + an explicit
---on-demand full scan. The full scan is BOUNDED (configurable caps,
---default 5,000 candidate files / 200 discovered roots — hitting a
---cap returns a structured cap report and warn-logs, never degrades
---silently) and CANCELABLE (a second `scan()`, a worktree/workspace
---switch, or `cancel()` aborts the in-flight walk); results are
---cached per file mtime so re-scans skip unchanged files.
---
---Execution: `run_position()` routes through the exec job engine
---(machine output in the per-run dir); `debug_position()` routes
---through the Phase 2 `dap.debug_test` path. Results land keyed by
---position id and feed `run.results:changed`.
---@module 'auto-run.discovery'

local fs_path = require("auto-core.fs.path")
local adapters = require("auto-run.adapters")
local log = require("auto-run.log")

local M = {}

-- ── events ──────────────────────────────────────────────────────

local function publish(topic, payload)
  local ok, events = pcall(require, "auto-core.events")
  if ok and events then pcall(events.publish, topic, payload) end
end

-- ── the position tree ───────────────────────────────────────────

---@class AutoRunTreeNode : AutoRunPosition
---@field adapter string?        owning adapter name (file and finer)
---@field parent AutoRunTreeNode?  (never serialized)

---@class AutoRunTree
---@field root AutoRunTreeNode
---@field _nodes table<string, AutoRunTreeNode>  id → node (O(1) lookup)
local Tree = {}
Tree.__index = Tree

---@param root_path string
---@return AutoRunTree
function Tree.new(root_path)
  local root = {
    id       = root_path,
    type     = "dir",
    name     = fs_path.basename(root_path),
    path     = root_path,
    children = {},
  }
  return setmetatable({ root = root, _nodes = { [root_path] = root } }, Tree)
end

---O(1) node lookup by position id.
---@param id string
---@return AutoRunTreeNode?
function Tree:get(id)
  return self._nodes[id]
end

---`{ files, positions }` — file count and namespace+test count.
---@return { files: integer, positions: integer }
function Tree:counts()
  local files, positions = 0, 0
  for _, node in pairs(self._nodes) do
    if node.type == "file" then files = files + 1 end
    if node.type == "test" or node.type == "namespace" then
      positions = positions + 1
    end
  end
  return { files = files, positions = positions }
end

---Sort a node's children in place: dirs first, then files (both by
---name); namespaces/tests by line.
local function sort_children(node)
  local rank = { dir = 1, file = 2, namespace = 3, test = 3 }
  table.sort(node.children, function(a, b)
    if rank[a.type] ~= rank[b.type] then return rank[a.type] < rank[b.type] end
    if a.lnum and b.lnum and a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return (a.name or "") < (b.name or "")
  end)
end

---Detach `node` and every descendant from `_nodes` + its parent, then
---prune ancestor dirs left empty (the root always stays).
---@param id string
---@return boolean removed
function Tree:remove(id)
  local node = self._nodes[id]
  if not node then return false end
  local function drop(n)
    self._nodes[n.id] = nil
    for _, child in ipairs(n.children or {}) do drop(child) end
  end
  drop(node)
  local parent = node.parent
  if parent then
    for i, child in ipairs(parent.children) do
      if child == node then table.remove(parent.children, i) break end
    end
    while parent and parent ~= self.root and #parent.children == 0 do
      local up = parent.parent
      self._nodes[parent.id] = nil
      if up then
        for i, child in ipairs(up.children) do
          if child == parent then table.remove(up.children, i) break end
        end
      end
      parent = up
    end
  end
  return true
end

---Dir node for `dir_path` (creating the chain from the root).
---@param dir_path string
---@return AutoRunTreeNode?
function Tree:ensure_dir(dir_path)
  local existing = self._nodes[dir_path]
  if existing then return existing end
  if not fs_path.is_under(dir_path, self.root.path) then return nil end
  local parent = self:ensure_dir(fs_path.parent(dir_path))
  if not parent then return nil end
  local node = {
    id       = dir_path,
    type     = "dir",
    name     = fs_path.basename(dir_path),
    path     = dir_path,
    children = {},
    parent   = parent,
  }
  self._nodes[dir_path] = node
  parent.children[#parent.children + 1] = node
  sort_children(parent)
  return node
end

---Attach one parsed file position (from `adapter.discover_positions`)
---under the dir hierarchy, assigning ids (`path` for the file,
---`path::ns::name` below it; duplicate sibling names get a ` #n`
---suffix). Replaces any previous node for the same path.
---@param file_pos AutoRunPosition  adapter-produced (no ids yet)
---@param adapter_name string
---@return AutoRunTreeNode? attached, string? err
function Tree:attach_file(file_pos, adapter_name)
  self:remove(file_pos.path)
  local dir = self:ensure_dir(fs_path.parent(file_pos.path))
  if not dir then
    return nil, "file " .. file_pos.path .. " is outside the tree root "
      .. self.root.path
  end

  local nodes = self._nodes
  local function build(src, parent, id_prefix)
    local id = id_prefix .. "::" .. src.name
    local n = 2
    while nodes[id] ~= nil do
      id = id_prefix .. "::" .. src.name .. " #" .. n
      n = n + 1
    end
    local node = {
      id       = id,
      type     = src.type,
      name     = src.name,
      path     = file_pos.path,
      lnum     = src.lnum,
      end_lnum = src.end_lnum,
      adapter  = adapter_name,
      children = {},
      parent   = parent,
    }
    nodes[id] = node
    parent.children[#parent.children + 1] = node
    for _, child in ipairs(src.children or {}) do
      build(child, node, id)
    end
    sort_children(node)
    return node
  end

  local file_node = {
    id       = file_pos.path,
    type     = "file",
    name     = file_pos.name,
    path     = file_pos.path,
    adapter  = adapter_name,
    children = {},
    parent   = dir,
  }
  nodes[file_pos.path] = file_node
  dir.children[#dir.children + 1] = file_node
  sort_children(dir)
  for _, child in ipairs(file_pos.children or {}) do
    build(child, file_node, file_pos.path)
  end
  sort_children(file_node)
  return file_node, nil
end

---Serializable (parent-free, copied) projection of a node — the
---`run.tests_list` shape.
---@param node AutoRunTreeNode
---@return table
local function to_plain(node)
  local out = {
    id       = node.id,
    type     = node.type,
    name     = node.name,
    path     = node.path,
    lnum     = node.lnum,
    end_lnum = node.end_lnum,
    adapter  = node.adapter,
  }
  if node.children and #node.children > 0 then
    out.children = {}
    for _, child in ipairs(node.children) do
      out.children[#out.children + 1] = to_plain(child)
    end
  end
  return out
end

M.Tree = Tree  -- exposed for consumers that build detached trees (tests)

-- ── module state ────────────────────────────────────────────────

---@type AutoRunTree?
local _tree = nil
---path → { sec: integer, nsec: integer } (mtime parse cache)
local _file_cache = {}
---position id → AutoRunResult (tests carry parsed results, container
---nodes carry aggregated ones)
local _results = {}
---scan generation counter — bumping it cancels the in-flight scan.
local _scan_gen = 0
---event-subscription handles (slot-replace pattern).
local _subs = {}

---Anchor for discovery: the resolver's worktree root (anchor when
---outside a repo). Never getcwd, never the workspace root.
---@return string
local function anchor_root()
  local dirs = require("auto-run.store").resolve_run_dirs()
  return dirs.root or dirs.anchor
end

---The position tree for the current anchor. A root change (worktree
---switch) drops the old tree and cancels any in-flight scan; the
---mtime cache survives (it is keyed by absolute path and re-checked
---against the new tree).
---@return AutoRunTree
function M.tree()
  local root = anchor_root()
  if _tree == nil or _tree.root.path ~= root then
    _scan_gen = _scan_gen + 1
    _tree = Tree.new(root)
  end
  return _tree
end

---Serializable position tree (the `run.tests_list` payload).
---@return table
function M.tree_plain()
  return to_plain(M.tree().root)
end

---Snapshot of the last results, keyed by position id.
---@return table<string, AutoRunResult>
function M.results()
  return vim.deepcopy(_results)
end

local function publish_discovery()
  local tree = M.tree()
  local counts = tree:counts()
  publish("run.discovery:changed", {
    root      = tree.root.path,
    files     = counts.files,
    positions = counts.positions,
  })
end

-- ── per-file parsing (mtime cache) ──────────────────────────────

---Parse one file through its adapter and update the tree.
---Returns `"parsed" | "cached" | "removed" | "skipped"` or
---`(nil, err)` on adapter parse failure.
---@param path string
---@param adapter AutoRunAdapter?  resolved when nil
---@return string? outcome, string? err
function M.parse_file(path, adapter)
  path = fs_path.normalize(path)
  adapter = adapter or adapters.adapter_for(path)
  if not adapter then return "skipped", nil end
  local tree = M.tree()

  local stat = vim.uv.fs_stat(path)
  if not stat then
    _file_cache[path] = nil
    if tree:remove(path) then return "removed", nil end
    return "skipped", nil
  end
  local cached = _file_cache[path]
  if cached and cached.sec == stat.mtime.sec and cached.nsec == stat.mtime.nsec
      and tree:get(path) ~= nil then
    return "cached", nil
  end

  local pos, perr = adapter.discover_positions(path)
  if pos == nil and perr ~= nil then
    return nil, adapter.name .. ": " .. tostring(perr)
  end
  _file_cache[path] = { sec = stat.mtime.sec, nsec = stat.mtime.nsec }
  if pos == nil then
    -- No positions (anymore) — a stale node comes out of the tree.
    if tree:remove(path) then return "removed", nil end
    return "skipped", nil
  end
  local _, aerr = tree:attach_file(pos, adapter.name)
  if aerr then return nil, aerr end
  return "parsed", nil
end

---Parse every loaded, named buffer that an adapter claims as a test
---file under the current root (the open-buffers default discovery).
---Publishes `run.discovery:changed` when anything changed.
---@return integer parsed
function M.refresh_open_buffers()
  local root = M.tree().root.path
  local changed = 0
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and not name:match("^%w+://") then
        local path = fs_path.normalize(name)
        if fs_path.is_under(path, root) then
          local outcome = M.parse_file(path)
          if outcome == "parsed" or outcome == "removed" then
            changed = changed + 1
          end
        end
      end
    end
  end
  if changed > 0 then publish_discovery() end
  return changed
end

-- ── the bounded, cancelable full scan ───────────────────────────

---Known child-repo exclusion set (immediate children only — the walk
---prunes deeper `.git` entries on its own). Prefers `worktree.git`
---(the ADR-named surface) and falls back to the auto-core primitive
---it delegates to.
---@param root string
---@return table<string, boolean>
local function child_repo_set(root)
  local set = {}
  local mod
  local okw, wt_git = pcall(require, "worktree.git")
  if okw and type(wt_git) == "table"
      and type(wt_git.list_child_repos) == "function" then
    mod = wt_git
  else
    local okc, core_wt = pcall(require, "auto-core.git.worktree")
    if okc then mod = core_wt end
  end
  if mod then
    local okl, repos = pcall(mod.list_child_repos, root)
    if okl and type(repos) == "table" then
      for _, r in ipairs(repos) do
        if type(r) == "table" and type(r.path) == "string" then
          set[fs_path.normalize(r.path)] = true
        end
      end
    end
  end
  return set
end

---Should the walk descend into `dir`? Hidden dirs, known child
---repos, and any dir carrying a `.git` entry (dir OR gitfile) are
---pruned unconditionally; adapters then get a `filter_dir` veto — a
---dir survives when at least one adapter (with no filter, or an
---accepting one) wants it.
---@param name string
---@param full string
---@param rel string
---@param root string
---@param excluded table<string, boolean>
---@param adapter_list AutoRunAdapter[]
---@return boolean
local function descend(name, full, rel, root, excluded, adapter_list)
  if name:sub(1, 1) == "." then return false end
  if excluded[full] then return false end
  if vim.uv.fs_stat(full .. "/.git") ~= nil then return false end
  for _, adapter in ipairs(adapter_list) do
    if adapter.filter_dir == nil then return true end
    local ok, keep = pcall(adapter.filter_dir, name, rel, root)
    if ok and keep ~= false then return true end
  end
  return false
end

---@class AutoRunScanReport
---@field status "complete"|"capped"|"canceled"
---@field root string
---@field files integer      candidate files visited
---@field parsed integer     test files (re)parsed
---@field cached integer     test files skipped via the mtime cache
---@field removed integer    stale file nodes dropped
---@field errors { path: string, error: string }[]
---@field roots integer      distinct adapter roots discovered
---@field cap "files"|"roots"|nil   which cap tripped (status=capped)
---@field limit integer?     the tripped cap's limit
---@field seen integer?      the count that tripped it
---@field hint string?       "scope narrowed?" (status=capped)
---@field reason string?     cancel reason (status=canceled)

---Run a bounded, cancelable full scan of the current worktree.
---Asynchronous (chunked over the event loop); `cb(report)` fires
---exactly once. Starting a new scan cancels the previous one, as do
---worktree/workspace switches and `cancel()`. Hitting a cap aborts
---with a structured cap report + a warn log — never silently.
---@param opts { max_files: integer?, max_roots: integer?, chunk: integer? }?
---@param cb fun(report: AutoRunScanReport)?
function M.scan(opts, cb)
  opts = opts or {}
  local cfg = require("auto-run.config").options.discovery or {}
  local max_files = opts.max_files or cfg.max_files or 5000
  local max_roots = opts.max_roots or cfg.max_roots or 200
  local chunk = opts.chunk or 40

  -- Resolve the tree FIRST — a root change inside tree() bumps the
  -- generation itself, and this scan must survive its own anchoring.
  local tree = M.tree()
  local root = tree.root.path
  _scan_gen = _scan_gen + 1
  local gen = _scan_gen

  local excluded = child_repo_set(root)
  local adapter_list = adapters.list()

  ---@type AutoRunScanReport
  local report = {
    status = "complete", root = root,
    files = 0, parsed = 0, cached = 0, removed = 0,
    errors = {}, roots = 0,
  }
  local roots_seen = {}
  local queue, head = { root }, 1
  local done = false

  local function finish(status, extra)
    if done then return end
    done = true
    report.status = status
    for k, v in pairs(extra or {}) do report[k] = v end
    if status == "capped" then
      report.hint = "scope narrowed?"
      log.warn("discovery", ("full scan hit the %s cap (%d ≥ %d) under %s "
        .. "— scope narrowed? Raise discovery.max_%s or scan a subtree.")
        :format(report.cap, report.seen, report.limit, root, report.cap))
    end
    if status ~= "canceled" then publish_discovery() end
    if cb then cb(report) end
  end

  local function handle_file(full)
    report.files = report.files + 1
    if report.files > max_files then
      finish("capped", { cap = "files", limit = max_files, seen = report.files })
      return false
    end
    local adapter = adapters.adapter_for(full)
    if not adapter then return true end

    -- Root accounting (manifest lookups only — the walk already
    -- pruned node_modules/vendor/child repos, so roots are never
    -- enumerated inside them).
    local aroot = adapter.root(fs_path.parent(full))
    if aroot then
      local key = adapter.name .. "\0" .. aroot
      if not roots_seen[key] then
        roots_seen[key] = true
        report.roots = report.roots + 1
        if report.roots > max_roots then
          finish("capped", { cap = "roots", limit = max_roots, seen = report.roots })
          return false
        end
      end
    end

    local outcome, perr = M.parse_file(full, adapter)
    if outcome == "parsed" then
      report.parsed = report.parsed + 1
    elseif outcome == "cached" then
      report.cached = report.cached + 1
    elseif outcome == "removed" then
      report.removed = report.removed + 1
    elseif outcome == nil then
      report.errors[#report.errors + 1] = { path = full, error = perr }
      log.debug("discovery", "parse failed: " .. full .. ": " .. tostring(perr))
    end
    return true
  end

  local function step()
    if done then return end
    if gen ~= _scan_gen then
      finish("canceled", { reason = "superseded" })
      return
    end
    local budget = chunk
    while budget > 0 and head <= #queue do
      local dir = queue[head]
      head = head + 1
      budget = budget - 1
      local scandir = vim.uv.fs_scandir(dir)
      if scandir then
        while true do
          local name, t = vim.uv.fs_scandir_next(scandir)
          if not name then break end
          local full = dir .. "/" .. name
          if t == "directory" then
            local rel = full:sub(#root + 2)
            if descend(name, full, rel, root, excluded, adapter_list) then
              queue[#queue + 1] = full
            end
          elseif t == "file" or t == "link" then
            if not handle_file(full) then return end
          end
        end
      end
    end
    if head > #queue then
      finish("complete")
      return
    end
    vim.schedule(step)
  end

  step()
end

---Cancel the in-flight scan (if any). The scan's callback fires with
---`status = "canceled"`.
---@param reason string?
function M.cancel(reason)
  _scan_gen = _scan_gen + 1
  if reason then
    log.debug("discovery", "scan canceled: " .. tostring(reason))
  end
end

-- ── status aggregation + missing-result filling ─────────────────

---Aggregated status from child statuses: running trumps everything
---(work in flight), then failed, passed, skipped.
---@param counts table<string, integer>
---@return string?
local function combine(counts)
  if (counts.running or 0) > 0 then return "running" end
  if (counts.failed or 0) > 0 then return "failed" end
  if (counts.passed or 0) > 0 then return "passed" end
  if (counts.skipped or 0) > 0 then return "skipped" end
  return nil
end

---Recompute aggregated statuses for every container node (namespace /
---file / dir) bottom-up from the test-level entries in `_results`.
---Containers with no resulted descendants lose their entry.
local function aggregate_all()
  local tree = _tree
  if not tree then return end
  local function visit(node)
    if node.type == "test" and (not node.children or #node.children == 0) then
      local r = _results[node.id]
      return r and r.status or nil
    end
    local counts = {}
    for _, child in ipairs(node.children or {}) do
      local s = visit(child)
      if s then counts[s] = (counts[s] or 0) + 1 end
    end
    -- A test with subtests aggregates its children but keeps its own
    -- parsed result when the runner reported one and no child is
    -- still running.
    if node.type == "test" then
      local own = _results[node.id]
      local agg = combine(counts)
      local status = (own and own.status ~= "running") and own.status or agg
        or (own and own.status)
      if status then
        _results[node.id] = vim.tbl_extend("force", own or {}, { status = status })
      end
      return status
    end
    local status = combine(counts)
    if status then
      _results[node.id] = { status = status }
    else
      _results[node.id] = nil
    end
    return status
  end
  visit(tree.root)
end

---Every test-position id under `node` (inclusive).
---@param node AutoRunTreeNode
---@return string[]
local function scope_test_ids(node)
  local ids = {}
  local function visit(n)
    if n.type == "test" then ids[#ids + 1] = n.id end
    for _, child in ipairs(n.children or {}) do visit(child) end
  end
  visit(node)
  return ids
end

local function publish_results()
  local tree = _tree
  if not tree then return end
  local positions = {}
  for id, r in pairs(_results) do
    positions[id] = { status = r.status, duration_ms = r.duration_ms }
  end
  publish("run.results:changed", { root = tree.root.path, positions = positions })
end

-- ── run a position (exec routing + fallback decomposition) ──────

---Build the run specs for `node`, decomposing when an adapter
---declines (`build_spec` → nil, nil): dir → per-(adapter, root)
---groups → files → tests. `(specs, nil)` or `(nil, err)`.
---@param tree AutoRunTree
---@param node AutoRunTreeNode
---@return { spec: AutoRunSpec, adapter: AutoRunAdapter, run_id: string, run_dir: string, position: AutoRunTreeNode }[]? specs, string? err
local function build_specs(tree, node)
  local job = require("auto-run.exec.job")

  ---@param adapter AutoRunAdapter
  ---@param pos AutoRunTreeNode
  ---@param aroot string
  local function attempt(adapter, pos, aroot)
    local run_id = job.generate_run_id()
    local run_dir = job.run_dir(run_id)
    local okm, merr = pcall(vim.fn.mkdir, run_dir, "p")
    if not okm then
      return nil, "mkdir(" .. run_dir .. "): " .. tostring(merr)
    end
    local spec, serr = adapter.build_spec({
      position = pos, tree = tree, root = aroot,
      run_id = run_id, run_dir = run_dir,
    })
    if spec == nil then
      pcall(vim.uv.fs_rmdir, run_dir)  -- unused (decompose / error)
      if serr ~= nil then return nil, serr end
      return false, nil  -- decompose finer
    end
    return { spec = spec, adapter = adapter, run_id = run_id,
      run_dir = run_dir, position = pos }, nil
  end

  ---Decompose-once-and-retry for non-dir positions.
  ---@param adapter AutoRunAdapter
  ---@param pos AutoRunTreeNode
  ---@param aroot string
  ---@param out table[]
  local function build_fine(adapter, pos, aroot, out)
    local built, err = attempt(adapter, pos, aroot)
    if err then return err end
    if built then
      out[#out + 1] = built
      return nil
    end
    local children = pos.children or {}
    if #children == 0 then
      return "adapter '" .. adapter.name .. "' cannot build a spec for '"
        .. pos.id .. "' (no finer decomposition available)"
    end
    for _, child in ipairs(children) do
      local cerr = build_fine(adapter, child, aroot, out)
      if cerr then return cerr end
    end
    return nil
  end

  local out = {}
  if node.type ~= "dir" then
    local adapter = adapters.get(node.adapter or "")
    if not adapter then
      return nil, "adapter '" .. tostring(node.adapter)
        .. "' is not registered for position '" .. node.id .. "'"
    end
    local aroot = adapter.root(fs_path.parent(node.path))
    if not aroot then
      return nil, "adapter '" .. adapter.name .. "' found no project root for "
        .. node.path
    end
    local err = build_fine(adapter, node, aroot, out)
    if err then return nil, err end
    return out, nil
  end

  -- Dir position: group descendant FILES by (adapter, adapter-root).
  -- A group whose root contains the dir runs as one dir spec; a group
  -- rooted BELOW the dir (nested module/package) runs per file.
  local groups, order = {}, {}
  local function collect(n)
    if n.type == "file" and n.adapter then
      local adapter = adapters.get(n.adapter)
      if adapter then
        local aroot = adapter.root(fs_path.parent(n.path))
        if aroot then
          local key = n.adapter .. "\0" .. aroot
          if not groups[key] then
            groups[key] = { adapter = adapter, root = aroot, files = {} }
            order[#order + 1] = key
          end
          local g = groups[key]
          g.files[#g.files + 1] = n
        end
      end
    end
    for _, child in ipairs(n.children or {}) do collect(child) end
  end
  collect(node)
  if #order == 0 then
    return nil, "no runnable test files under '" .. node.id .. "'"
  end

  for _, key in ipairs(order) do
    local g = groups[key]
    if fs_path.is_under(node.path, g.root) then
      local built, err = attempt(g.adapter, node, g.root)
      if err then return nil, err end
      if built then
        out[#out + 1] = built
      else
        for _, file_node in ipairs(g.files) do
          local ferr = build_fine(g.adapter, file_node, g.root, out)
          if ferr then return nil, ferr end
        end
      end
    else
      for _, file_node in ipairs(g.files) do
        local ferr = build_fine(g.adapter, file_node, g.root, out)
        if ferr then return nil, ferr end
      end
    end
  end
  return out, nil
end

---Run a discovered position through the exec job engine. Specs are
---built up front (any build error aborts before anything spawns);
---each spec becomes one job whose machine output the adapter parses
---back to position ids on exit. Missing results within a run's scope
---fill as `skipped` (or `failed` when the runner itself died without
---reporting), containers aggregate upward, and `run.results:changed`
---publishes both the running and the final states.
---@param id string  position id
---@param opts { timeout_ms: integer?, on_done: fun(results: table<string, AutoRunResult>)? }?
---@return { position: string, runs: { id: string, adapter: string, position: string }[] }? launched, string? err
function M.run_position(id, opts)
  opts = opts or {}
  if type(id) ~= "string" or id == "" then
    return nil, "run_position: id must be a non-empty string"
  end
  local tree = M.tree()
  local node = tree:get(id)
  if not node then
    return nil, "position '" .. id .. "' not found — "
      .. "discovery covers open buffers by default (:AutoRun scan for the full worktree)"
  end

  local specs, berr = build_specs(tree, node)
  if not specs then return nil, berr end

  local job = require("auto-run.exec.job")
  local pending = #specs
  local batch = {}

  -- Mark the scope running up front (feeds the ● glyphs).
  for _, s in ipairs(specs) do
    for _, tid in ipairs(scope_test_ids(s.position)) do
      _results[tid] = { status = "running" }
    end
  end
  aggregate_all()
  publish_results()

  local runs = {}
  for _, s in ipairs(specs) do
    local launched, sperr = job.spawn({
      id         = s.run_id,
      cmd        = s.spec.cmd,
      config     = "test:" .. s.adapter.name,
      strategy   = "run",
      cwd        = s.spec.cwd,
      env        = s.spec.env,
      timeout_ms = opts.timeout_ms,
      on_exit    = function(rec)
        local exit = {
          code        = rec.code,
          signal      = rec.signal,
          stdout_file = fs_path.join(s.run_dir, "stdout"),
          run_dir     = s.run_dir,
        }
        local okr, parsed = pcall(s.adapter.results, s.spec, exit, tree)
        if not okr then
          log.warn("discovery", "results parse failed for " .. s.run_id
            .. ": " .. tostring(parsed))
          parsed = {}
        end
        for rid, res in pairs(parsed) do batch[rid] = res end

        -- Missing-result filling for THIS spec's scope: parsed tests
        -- keep their result; unreported ones fill as skipped — or as
        -- failed when the runner produced nothing and exited non-zero
        -- (build/config failure must not masquerade as skips).
        local runner_died = next(parsed) == nil
          and (rec.code ~= 0 or (rec.signal or 0) ~= 0)
        for _, tid in ipairs(scope_test_ids(s.position)) do
          if batch[tid] == nil then
            batch[tid] = runner_died
              and { status = "failed",
                    output = ("runner exited code=%s signal=%s (see %s)")
                      :format(tostring(rec.code), tostring(rec.signal), s.run_dir) }
              or { status = "skipped" }
          end
        end

        pending = pending - 1
        if pending == 0 then
          for rid, res in pairs(batch) do _results[rid] = res end
          aggregate_all()
          publish_results()
          if type(opts.on_done) == "function" then
            pcall(opts.on_done, vim.deepcopy(batch))
          end
        end
      end,
    })
    if not launched then
      -- Spawn failure: unwind the running marks for a truthful panel.
      for _, tid in ipairs(scope_test_ids(node)) do
        if _results[tid] and _results[tid].status == "running" then
          _results[tid] = nil
        end
      end
      aggregate_all()
      publish_results()
      return nil, sperr
    end
    runs[#runs + 1] = { id = s.run_id, adapter = s.adapter.name,
      position = s.position.id }
  end
  return { position = id, runs = runs }, nil
end

---Debug a discovered test position via the Phase 2 debug-test path
---(dap-go's cursor-driven selection): jump to the position, then
---`dap.debug_test` with the repo's kind=test config (when one
---exists) merged in.
---@param id string
---@return boolean? ok, string? err, table? detail
function M.debug_position(id)
  if type(id) ~= "string" or id == "" then
    return nil, "debug_position: id must be a non-empty string"
  end
  local tree = M.tree()
  local node = tree:get(id)
  if not node then return nil, "position '" .. id .. "' not found" end
  if node.type ~= "test" then
    return nil, "debug_position needs a test position (got " .. node.type .. ")"
  end
  if node.adapter ~= "go" then
    return nil, "debug for '" .. tostring(node.adapter)
      .. "' positions is not supported yet (go only — ADR-0048 Phase 2 dap path)"
  end
  local oke, eerr = pcall(function()
    vim.cmd.edit(vim.fn.fnameescape(node.path))
    vim.api.nvim_win_set_cursor(0, { node.lnum or 1, 0 })
  end)
  if not oke then return nil, "jump to position failed: " .. tostring(eerr) end
  local go_adapter = adapters.get("go")
  local cfg_name = go_adapter and go_adapter.test_config_name
    and go_adapter.test_config_name() or nil
  return require("auto-run.dap").debug_test(cfg_name, {})
end

-- ── nearest-position resolution (rt/rf/dt keymaps) ──────────────

---The discovered position nearest the cursor in a buffer: the
---buffer's file is (re)parsed on demand, then the deepest position
---whose `lnum..end_lnum` range CONTAINS the cursor line wins; with no
---containing position, the last position starting at/above the line;
---with none of those, the file node itself (runs the whole file).
---
---`(nil, err, reason)` when nothing resolves — `reason` is a
---machine key so callers can fall back precisely:
---`"no_file" | "no_adapter" | "outside_root" | "parse_failed" |
---"no_positions"`. `"no_adapter"` is the keymaps' fall-back-to-
---config-path trigger (ADR-0048 §10 / Phase 4 gate).
---@param bufnr integer?  defaults to the current buffer
---@return AutoRunTreeNode? node, string? err, string? reason
function M.nearest(bufnr)
  bufnr = bufnr or 0
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("^%w+://") then
    return nil, "buffer has no file to discover tests in", "no_file"
  end
  local path = fs_path.normalize(name)
  local adapter = adapters.adapter_for(path)
  if not adapter then
    return nil, "no test adapter claims " .. path, "no_adapter"
  end
  local tree = M.tree()
  if not fs_path.is_under(path, tree.root.path) then
    return nil, path .. " is outside the discovery root " .. tree.root.path,
      "outside_root"
  end
  local _, perr = M.parse_file(path, adapter)
  if perr then return nil, perr, "parse_failed" end
  local file_node = tree:get(path)
  if not file_node then
    return nil, "no test positions discovered in " .. path, "no_positions"
  end

  -- Cursor line — only meaningful when the buffer is the current
  -- window's; otherwise the file node is the honest answer.
  if bufnr ~= 0 and bufnr ~= vim.api.nvim_get_current_buf() then
    return file_node, nil, nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local containing, preceding
  local function visit(node)
    for _, child in ipairs(node.children or {}) do
      if (child.type == "test" or child.type == "namespace")
          and type(child.lnum) == "number" then
        if child.lnum <= lnum then
          preceding = child  -- DFS document order → greatest lnum ≤ cursor
          local end_l = child.end_lnum
          if type(end_l) == "number" and lnum <= end_l then
            containing = child  -- later (deeper) containing hit wins
          end
        end
      end
      visit(child)
    end
  end
  visit(file_node)
  return containing or preceding or file_node, nil, nil
end

-- ── setup (autocmds + re-anchor subscriptions) ──────────────────

---Wire the open-buffers default discovery (BufReadPost parse +
---BufWritePost re-parse for test files under the current root) and
---the worktree/workspace-switch scan cancelation. Idempotent —
---the augroup clears and the event subscriptions slot-replace.
function M.setup()
  local cfg = require("auto-run.config").options.discovery or {}
  local group = vim.api.nvim_create_augroup("AutoRunDiscovery", { clear = true })

  if cfg.open_buffers ~= false then
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
      group = group,
      desc = "auto-run: (re)parse open test files (ADR-0048 §7)",
      callback = function(ev)
        local name = ev.file
        if type(name) ~= "string" or name == "" or name:match("^%w+://") then
          return
        end
        local path = fs_path.normalize(name)
        if not adapters.adapter_for(path) then return end
        if not fs_path.is_under(path, anchor_root()) then return end
        local outcome = M.parse_file(path)
        if outcome == "parsed" or outcome == "removed" then
          publish_discovery()
        end
      end,
    })
  end

  local ok, events = pcall(require, "auto-core.events")
  if ok and events then
    for _, handle in ipairs(_subs) do
      pcall(events.unsubscribe, handle)
    end
    _subs = {}
    for _, topic in ipairs({
      "core.active_worktree:changed",
      "core.workspace_root:changed",
    }) do
      _subs[#_subs + 1] = events.subscribe(topic, function()
        M.cancel(topic)
      end)
    end
  end
end

---Test-only: wipe tree, caches, results, and cancel any scan. Not
---part of the public API stability contract.
function M._reset_for_tests()
  _scan_gen = _scan_gen + 1
  _tree, _file_cache, _results = nil, {}, {}
end

return M
