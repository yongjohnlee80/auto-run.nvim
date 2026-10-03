---auto-run.adapters.node — the Node.js RUNTIME adapter (ADR 0213 §2.1).
---
---Run and debug configs only: tests belong to the jest and playwright
---adapters, so this adapter claims no test files. A config names what runs in
---one of two ways:
---
---  • `program` — a JS/TS entry file  → `node <program> <args>`
---  • `script`  — a package.json script → `<pm> run <script> [-- <args>]`
---
---`<pm>` is the package manager the lockfile names (npm, pnpm, yarn, bun).
---Debugging goes through js-debug's `pwa-node` with `outputCapture = "std"`:
---without it the program's output never reaches the session (VM43, ADR 0213
---N1/N2). A script debugs as `runtimeExecutable = <pm>`, `runtimeArgs =
---{ "run", <script>, … }`; js-debug attaches the node children it spawns.
---@module 'auto-run.adapters.node'

local fs_path = require("auto-core.fs.path")
local js = require("auto-run.adapters.js")

local M = {}

M.name = "node"
M.summary = "Node.js — a file (node, or tsx for .ts) or a package.json script (npm / pnpm / yarn / bun); debug with js-debug"

-- ── test interface (this adapter claims no test files) ──────────

---@param dir string
---@return string?
function M.root(dir)
  return js.package_root(dir)
end

function M.is_test_file(_path) return false end

function M.discover_positions(_path) return nil, nil end

function M.build_spec(_args)
  return nil, "the node adapter runs programs and scripts; tests run through jest or playwright"
end

function M.results(_spec, _exit, _tree) return {} end

-- ── config helpers ──────────────────────────────────────────────

local TS_EXT = { ts = true, mts = true, cts = true }

---The working directory a config runs in: its cwd, else the working directory.
---@param eff table
---@return string?
local function eff_cwd(eff)
  if type(eff.cwd) == "string" and eff.cwd ~= "" then return eff.cwd end
  local dirs = require("auto-run.store").resolve_run_dirs()
  return dirs.workdir or dirs.root or dirs.anchor
end

---Absolute path of a config's program (relative ones resolve against its cwd).
---@param eff table
---@return string?
local function program_path(eff)
  local p = eff.program
  if type(p) ~= "string" or p == "" then return nil end
  if p:sub(1, 1) ~= "/" then
    local cwd = eff_cwd(eff)
    if cwd then p = fs_path.join(cwd, p) end
  end
  return fs_path.normalize(p)
end

---The package a config belongs to: the program's package, else the cwd's.
---@param eff table
---@return string?
local function package_of(eff)
  local prog = program_path(eff)
  if prog then
    local root = js.package_root(fs_path.parent(prog))
    if root then return root end
  end
  local cwd = eff_cwd(eff)
  return cwd and js.package_root(cwd) or nil
end

---The executable that runs a program file: project-local `tsx` for a
---TypeScript entry when installed, else `node` (current Node strips types).
---@param eff table
---@return string exe, boolean via_tsx
local function program_runner(eff)
  local prog = program_path(eff) or ""
  local ext = prog:match("%.([%w]+)$")
  if ext and TS_EXT[ext] then
    local pkg = package_of(eff)
    local tsx = pkg and js.find_module(pkg, ".bin/tsx") or nil
    if tsx then return tsx, true end
  end
  return "node", false
end

---Why a node config cannot run, or nil (ADR 0199 program check, ADR 0213 §2.1).
---@param eff table   substituted effective config
---@return string? err
function M.program_error(eff)
  local name = tostring(eff and eff.name)
  local has_prog = type(eff.program) == "string" and eff.program ~= ""
  local has_script = type(eff.script) == "string" and eff.script ~= ""
  if has_prog and has_script then
    return ("config '%s': set `program` (a file) or `script` (a package.json script), not both"):format(name)
  end
  if not has_prog and not has_script then
    return ("config '%s': set `program` (a file to run with node) or `script` (a package.json script)"):format(name)
  end
  if has_prog then
    if eff.program:find("${", 1, true) then return nil end
    local abs = program_path(eff)
    if abs and not fs_path.is_file(abs) then
      return ("config '%s': program %s does not exist"):format(name, vim.fn.fnamemodify(abs, ":~"))
    end
    return nil
  end
  local pkg = package_of(eff)
  if not pkg then
    return ("config '%s': no package.json at or above %s for script '%s'")
      :format(name, vim.fn.fnamemodify(eff_cwd(eff) or "?", ":~"), eff.script)
  end
  if not vim.tbl_contains(js.scripts(pkg), eff.script) then
    local have = js.scripts(pkg)
    return ("config '%s': package.json in %s has no script '%s'%s"):format(name,
      vim.fn.fnamemodify(pkg, ":~"), eff.script,
      #have > 0 and (" (it has: " .. table.concat(have, ", ") .. ")") or "")
  end
  return nil
end

-- ── runtime capabilities (ADR 0194 §2.3.4) ──────────────────────

---Scaffold defaults: a script when the working directory's package has one
---(the config's name if it is a script, else dev / start / serve), else an
---`index.js` program. The package folder becomes `cwd` when it is not the
---repo root, so the config keeps working after the working directory moves.
---@param kind "run"|"test"|"debug"
---@param name string?
---@return table
function M.default_config(kind, name)
  local dirs = require("auto-run.store").resolve_run_dirs()
  local root, workdir = dirs.root, dirs.workdir or dirs.root or dirs.anchor
  local pkg = workdir and js.package_root(workdir) or nil
  local base = "${worktree}"
  local folder
  local anchor_dir = pkg or workdir
  if root and anchor_dir and anchor_dir ~= root and anchor_dir:sub(1, #root + 1) == root .. "/" then
    folder = anchor_dir:sub(#root + 2)
    base = "${worktree}/" .. folder
  end
  local cfg = { runtime = "node", kind = kind }
  if folder then cfg.cwd = base end
  local scripts = pkg and js.scripts(pkg) or {}
  local pick
  if name and vim.tbl_contains(scripts, name) then
    pick = name
  elseif kind == "test" and vim.tbl_contains(scripts, "test") then
    pick = "test"
  else
    for _, s in ipairs({ "dev", "start", "serve" }) do
      if vim.tbl_contains(scripts, s) then pick = s break end
    end
  end
  if pick then
    cfg.script = pick
  else
    cfg.program = base .. "/index.js"
  end
  return cfg
end

---Base argv for the run / term strategies (the caller appends the args).
---@param eff table
---@param _opts table?
---@return string[]? argv, string? err
function M.build_run_argv(eff, _opts)
  local perr = M.program_error(eff)
  if perr then return nil, perr end
  if type(eff.script) == "string" and eff.script ~= "" then
    local pm = js.package_manager(package_of(eff) or eff_cwd(eff))
    local argv = { pm, "run", eff.script }
    -- npm passes flags to the script only after `--`; the others pass them on.
    if pm == "npm" and type(eff.args) == "table" and #eff.args > 0 then
      argv[#argv + 1] = "--"
    end
    return argv, nil
  end
  local exe = program_runner(eff)
  return { exe, program_path(eff) or eff.program }, nil
end

---Launch-ready pwa-node config for an effective run/debug config.
---@param eff table   resolved effective config (substituted, composed env)
---@param _opts table
---@param cb fun(launch: table|nil, err: table|nil)
function M.prepare_debug_config(eff, _opts, cb)
  local perr = M.program_error(eff)
  if perr then return cb(nil, { code = "program_missing", message = perr }) end
  local cwd = eff_cwd(eff)
  local args = type(eff.args) == "table" and #eff.args > 0 and vim.deepcopy(eff.args) or nil
  local extra = js.debug_extra()
  local launch = { dap_type = "pwa-node", request = "launch", cwd = cwd, env = eff.env, extra = extra }
  if type(eff.script) == "string" and eff.script ~= "" then
    local pm = js.package_manager(package_of(eff) or cwd)
    local rargs = { "run", eff.script }
    if args then
      if pm == "npm" then rargs[#rargs + 1] = "--" end
      vim.list_extend(rargs, args)
    end
    extra.runtimeExecutable = pm
    extra.runtimeArgs = rargs
  else
    local exe, via_tsx = program_runner(eff)
    launch.program = program_path(eff) or eff.program
    launch.args = args
    if via_tsx then extra.runtimeExecutable = exe end
  end
  return cb(launch, nil)
end

---Missing toolchain / dependencies (ADR 0213 §2.4).
---@param ctx { root: string, purpose: "run"|"test"|"debug", eff: table? }
---@return AutoRunIssue[]
function M.preflight(ctx)
  local pkg = ctx.root and js.package_root(ctx.root) or nil
  local issues = pkg and js.base_issues(pkg) or {}
  if ctx.eff then
    local perr = M.program_error(ctx.eff)
    if perr then
      issues[#issues + 1] = { level = "error", code = "program_missing", message = perr }
    else
      local prog = program_path(ctx.eff)
      local ext = prog and prog:match("%.([%w]+)$")
      if ext and TS_EXT[ext] and not select(2, program_runner(ctx.eff)) then
        -- A warning, not an error: node's own version is not checked here
        -- (that would spawn a process; preflight never does, ADR 0213 §2.4).
        issues[#issues + 1] = { level = "warn", code = "ts_runner",
          message = "TypeScript entry " .. vim.fn.fnamemodify(prog, ":t")
            .. " runs on plain node (needs Node ≥ 22.6 type stripping); no project-local tsx",
          fix = js.add_dev_cmd(js.package_manager(pkg or ctx.root), "tsx") }
      end
    end
  end
  if ctx.purpose == "debug" then vim.list_extend(issues, js.debug_issues()) end
  return issues
end

return M
