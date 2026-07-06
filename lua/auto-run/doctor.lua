---auto-run.doctor — git/worktree diagnostics + repair (ADR-0048 §13,
---gobugger doctor/fix parity).
---
---`git_info()` produces the structured rows gobugger's doctor printed
---that the store resolver doesn't already cover (project root +
---marker, the anchor's `.git` kind incl. gitfile-target health,
---`git status` reachability, the common dir, the go module root).
---`fix_worktree()` ports gobugger's `<leader>dF`: `git worktree
---repair` from the repo's common dir — reached through
---`:AutoRun doctor --fix` ONLY (mutating ⇒ interactive-only, never a
---mailbox verb; the read-only mailbox surface stays `run.status`).
---
---Anchoring: everything resolves off `store.resolve_run_dirs()`
---([[shared-resolver-single-source-of-truth]]) — never `getcwd`.
---Go-module resolution delegates to the go adapter's `module_dir`
---(the one owner of go-root logic). Errors are `(nil, err)`; main
---paths never notify.
---@module 'auto-run.doctor'

local fs_path = require("auto-core.fs.path")

local M = {}

-- ── small git helpers ────────────────────────────────────────────

local function run_git(args)
  return vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()
end

---Parse a `.git` gitfile: `(resolved_gitdir, exists_on_disk)`, or
---`(nil, nil)` when the file isn't a parseable gitfile (gobugger
---git.parse_gitfile port).
---@param path string  absolute path to the `.git` file
---@return string? gitdir, boolean? exists
function M.parse_gitfile(path)
  local f = io.open(path, "r")
  if not f then return nil, nil end
  local content = f:read("*a") or ""
  f:close()
  local gitdir = content:match("^gitdir:%s*(.-)%s*$")
  if not gitdir then return nil, nil end
  if not gitdir:match("^/") then
    gitdir = fs_path.join(fs_path.parent(path), gitdir)
  end
  return gitdir, fs_path.is_dir(gitdir)
end

---Walk up from `start` for a project boundary: the first dir carrying
---`.bare/` or a `.git/` DIRECTORY (gitfiles are transparent — the
---walk must find the container even when the anchor's own gitfile is
---broken). gobugger git.project_root port.
---@param start string
---@return string? boundary
local function boundary_walk(start)
  local cur = fs_path.normalize(start)
  local seen = {}
  while cur and cur ~= "" and not seen[cur] do
    seen[cur] = true
    if fs_path.is_dir(fs_path.join(cur, ".bare")) then return cur end
    if fs_path.is_dir(fs_path.join(cur, ".git")) then return cur end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

---The repo common dir for `anchor`, surviving a BROKEN worktree
---gitfile: the resolver's answer first; when git itself can't answer
---(that is exactly the doctor --fix scenario), fall back to the
---boundary walk — a `.bare/` dir IS the common dir, a `.git/` dir
---answers via git again.
---@param anchor string
---@return string? common
local function resilient_common_dir(anchor)
  local repo = require("auto-core.git.repo")
  local common = repo.common_dir(anchor)
  if common then return common end
  local boundary = boundary_walk(anchor)
  if not boundary then return nil end
  local bare = fs_path.join(boundary, ".bare")
  if fs_path.is_dir(bare) then return bare end
  return repo.common_dir(boundary) or fs_path.join(boundary, ".git")
end

-- ── structured diagnostics (doctor rows) ─────────────────────────

---@class AutoRunGitInfo
---@field anchor string
---@field project_root string?    boundary-walk container/repo dir
---@field root_marker string?     ".bare/" | ".git/ (bare)" | ".git/ (regular repo)"
---@field git_kind string         anchor `.git` kind: "directory" | "gitfile → <target>  [OK|MISSING]" | "gitfile (unparseable)" | "<absent>"
---@field gitfile_broken boolean  anchor gitfile present but target missing/unparseable
---@field status_ok boolean       `git status --porcelain` at the anchor succeeds
---@field status_error string?    first stderr line when not
---@field common_dir string?      repo common dir (broken-gitfile resilient)
---@field go_module_root string?  nearest enclosing go.mod dir (go adapter)

---Gobugger-doctor-parity git diagnostics for the current anchor.
---@return AutoRunGitInfo
function M.git_info()
  local dirs = require("auto-run.store").resolve_run_dirs()
  local anchor = dirs.root or dirs.anchor

  local out = {
    anchor         = anchor,
    gitfile_broken = false,
    status_ok      = false,
  }

  local boundary = boundary_walk(anchor)
  if boundary then
    out.project_root = boundary
    if fs_path.is_dir(fs_path.join(boundary, ".bare")) then
      out.root_marker = ".bare/"
    else
      local repo = require("auto-core.git.repo")
      out.root_marker = repo.is_bare(fs_path.join(boundary, ".git"))
        and ".git/ (bare)" or ".git/ (regular repo)"
    end
  end

  local anchor_git = fs_path.join(anchor, ".git")
  if fs_path.is_dir(anchor_git) then
    out.git_kind = "directory"
  elseif fs_path.is_file(anchor_git) then
    local target, exists = M.parse_gitfile(anchor_git)
    if target then
      out.git_kind = ("gitfile → %s  [%s]"):format(target, exists and "OK" or "MISSING")
      out.gitfile_broken = not exists
    else
      out.git_kind = "gitfile (unparseable)"
      out.gitfile_broken = true
    end
  else
    out.git_kind = "<absent>"
  end

  local res = run_git({ "-C", anchor, "status", "--porcelain" })
  out.status_ok = res.code == 0
  if res.code ~= 0 then
    out.status_error = ("exit %d — %s"):format(res.code,
      (res.stderr or ""):match("([^\n]+)") or "(no stderr)")
  end

  out.common_dir = resilient_common_dir(anchor)

  local okg, go = pcall(require, "auto-run.adapters.go")
  if okg then out.go_module_root = go.module_dir(anchor) end

  return out
end

-- ── fix (git worktree repair — gobugger fix_worktree port) ──────

---Run `git worktree repair` from the anchor repo's common dir. The
---anchor rides along as a path argument when its `.git` is a gitfile
---(repairs a MOVED linked worktree's back-pointer as well as a
---broken gitfile). Interactive-only surface (`:AutoRun doctor
-----fix`) — never exposed over the mailbox.
---@return { common: string, output: string }? result, string? err
function M.fix_worktree()
  local dirs = require("auto-run.store").resolve_run_dirs()
  local anchor = dirs.root or dirs.anchor

  local common = resilient_common_dir(anchor)
  if not common then
    return nil, "not inside a git repo (anchor=" .. anchor .. "); cannot repair"
  end

  local args = { "-C", common, "worktree", "repair" }
  if fs_path.is_file(fs_path.join(anchor, ".git")) then
    args[#args + 1] = anchor
  end
  local res = run_git(args)
  local output = ((res.stdout or "") .. (res.stderr or "")):gsub("%s+$", "")
  if res.code ~= 0 then
    return nil, "git worktree repair failed:\n" .. output
  end

  -- Repair may have re-pointed the anchor's repo identity — drop the
  -- resolver cache so the next resolution sees the healed layout.
  require("auto-run.store.paths").invalidate()
  return { common = common, output = output }, nil
end

return M
