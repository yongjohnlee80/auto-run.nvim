---auto-run.adapters.js — what the JavaScript adapters (node, jest, playwright)
---must agree on, owned once (ADR 0213 §3 item 6): the package root, the
---package manager a lockfile names, the hoisted `node_modules` walk, the
---`package.json` read, and the positive identification of a Playwright spec.
---
---A second copy of any of these in an adapter is how two adapters would come
---to disagree about which package a file belongs to, or which `node_modules`
---a run uses ([[shared-resolver-single-source-of-truth]]).
---
---Everything here is synchronous and filesystem-only — preflight calls it on
---every launch (ADR 0213 §2.4), so nothing spawns a process.
---@module 'auto-run.adapters.js'

local fs_path = require("auto-core.fs.path")

local M = {}

---JS/TS source extensions every adapter recognizes.
M.EXTENSIONS = { js = true, jsx = true, ts = true, tsx = true, mjs = true, cjs = true, mts = true, cts = true }

---Nearest enclosing directory (inclusive) that holds `marker`.
---@param dir string
---@param marker string
---@return string?
function M.walk_up_for(dir, marker)
  if type(dir) ~= "string" or dir == "" then return nil end
  local cur = fs_path.normalize(dir)
  while cur and cur ~= "" do
    if fs_path.exists(fs_path.join(cur, marker)) then return cur end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

---Nearest directory (inclusive) holding a `package.json`.
---@param dir string
---@return string?
function M.package_root(dir)
  return M.walk_up_for(dir, "package.json")
end

---Parsed `package.json` of `pkg_root`, or nil plus why.
---@param pkg_root string
---@return table? pkg, string? err
function M.read_package(pkg_root)
  local file = fs_path.join(pkg_root, "package.json")
  local f = io.open(file, "r")
  if not f then return nil, "no package.json in " .. pkg_root end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return nil, file .. " is not valid JSON"
  end
  return data, nil
end

---Script names of a package, sorted.
---@param pkg_root string
---@return string[]
function M.scripts(pkg_root)
  local pkg = M.read_package(pkg_root)
  local out = {}
  if pkg and type(pkg.scripts) == "table" then
    for k, v in pairs(pkg.scripts) do
      if type(k) == "string" and type(v) == "string" then out[#out + 1] = k end
    end
  end
  table.sort(out)
  return out
end

---Lockfile → package manager, in the order a mixed tree is most likely meant.
local LOCKFILES = {
  { "pnpm-lock.yaml", "pnpm" },
  { "yarn.lock", "yarn" },
  { "bun.lock", "bun" },
  { "bun.lockb", "bun" },
  { "package-lock.json", "npm" },
}

---The package manager for a package: the lockfile next to its `package.json`,
---else the nearest one above (a workspace root), else npm.
---@param pkg_root string
---@return "npm"|"pnpm"|"yarn"|"bun"
function M.package_manager(pkg_root)
  local cur = pkg_root
  while cur and cur ~= "" do
    for _, lf in ipairs(LOCKFILES) do
      if fs_path.is_file(fs_path.join(cur, lf[1])) then return lf[2] end
    end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return "npm"
end

---The highest directory the hoisted `node_modules` walk may reach: the working
---directory's repo root (a monorepo hoists to it), else the package root.
---@param pkg_root string
---@return string
local function walk_stop(pkg_root)
  local ok, store = pcall(require, "auto-run.store")
  if ok then
    local dirs = store.resolve_run_dirs()
    local stop = dirs.root or dirs.anchor
    if stop and fs_path.is_under(pkg_root, stop) then return stop end
  end
  return pkg_root
end

---First existing `node_modules/<rel>` from the package dir up to the repo root
---(hoisted installs), or nil.
---@param pkg_root string
---@param rel string   e.g. ".bin/jest", "jest/bin/jest.js"
---@return string?
function M.find_module(pkg_root, rel)
  local stop = walk_stop(pkg_root)
  local cur = pkg_root
  while cur and cur ~= "" do
    local candidate = fs_path.join(cur, "node_modules", rel)
    if fs_path.exists(candidate) then return candidate end
    if cur == stop then break end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" or not fs_path.is_under(parent, stop) then break end
    cur = parent
  end
  return nil
end

---Does the package declare dependencies that need installing? (A package.json
---with none has nothing for `node_modules` to hold.)
---@param pkg_root string
---@return boolean
function M.has_dependencies(pkg_root)
  local pkg = M.read_package(pkg_root)
  if not pkg then return false end
  for _, key in ipairs({ "dependencies", "devDependencies", "optionalDependencies" }) do
    if type(pkg[key]) == "table" and next(pkg[key]) ~= nil then return true end
  end
  return false
end

---Is a `node_modules` directory reachable from the package (next to it, or
---hoisted above it within the repo)?
---@param pkg_root string
---@return boolean
function M.has_node_modules(pkg_root)
  local stop = walk_stop(pkg_root)
  local cur = pkg_root
  while cur and cur ~= "" do
    if fs_path.is_dir(fs_path.join(cur, "node_modules")) then return true end
    if cur == stop then break end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" or not fs_path.is_under(parent, stop) then break end
    cur = parent
  end
  return false
end

---The install command for a package manager (`npm install`, `pnpm install`…).
---@param pm string
---@return string
function M.install_cmd(pm)
  return pm .. " install"
end

---The "add a dev dependency" command for a package manager.
---@param pm string
---@param pkg string
---@return string
function M.add_dev_cmd(pm, pkg)
  if pm == "npm" then return "npm install -D " .. pkg end
  return pm .. " add -D " .. pkg
end

---Preflight issues every JavaScript adapter shares: node itself, and installed
---dependencies (ADR 0213 §2.4).
---@param pkg_root string
---@return AutoRunIssue[]
function M.base_issues(pkg_root)
  local issues = {}
  if vim.fn.executable("node") ~= 1 then
    issues[#issues + 1] = { level = "error", code = "node_missing",
      message = "node is not on PATH", fix = "install Node.js (https://nodejs.org)" }
  end
  if M.has_dependencies(pkg_root) and not M.has_node_modules(pkg_root) then
    local pm = M.package_manager(pkg_root)
    issues[#issues + 1] = { level = "error", code = "node_modules_missing",
      message = "dependencies are not installed in " .. vim.fn.fnamemodify(pkg_root, ":~")
        .. " (no node_modules)",
      fix = "cd " .. vim.fn.fnamemodify(pkg_root, ":~") .. " && " .. M.install_cmd(pm) }
  end
  return issues
end

---The debug-side preflight: a `pwa-node` adapter must be registered, or
---registrable (`js-debug-adapter` on PATH or in Mason's bin).
---@return AutoRunIssue[]
function M.debug_issues()
  local okd, dap = pcall(require, "dap")
  if okd and dap.adapters["pwa-node"] ~= nil then return {} end
  if require("auto-run.dap").js_debug_command() then return {} end
  return { { level = "error", code = "js_debug_missing",
    message = "no JavaScript debug adapter (pwa-node / js-debug-adapter)",
    fix = "install js-debug-adapter (:MasonInstall js-debug-adapter, or the LazyVim lang.typescript extra)" } }
end

---The `pwa-node` launch fields every JavaScript debug launch carries. Without
---`outputCapture = "std"` the program's stdout/stderr never reach the session
---(VM43, ADR 0213 N1/N2), so the journal and the REPL would stay empty.
---@return table
function M.debug_extra()
  return {
    outputCapture = "std",
    sourceMaps = true,
    skipFiles = { "<node_internals>/**" },
  }
end

-- ── Playwright identification ───────────────────────────────────

M.PLAYWRIGHT_CONFIGS = {
  "playwright.config.ts", "playwright.config.js", "playwright.config.mjs",
  "playwright.config.cjs", "playwright.config.mts", "playwright.config.cts",
}

---Nearest directory (inclusive) holding a Playwright config.
---@param dir string
---@return string?
function M.playwright_root(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  local cur = fs_path.normalize(dir)
  while cur and cur ~= "" do
    for _, name in ipairs(M.PLAYWRIGHT_CONFIGS) do
      if fs_path.is_file(fs_path.join(cur, name)) then return cur end
    end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

---Does the file at `path` import `@playwright/test`? The positive signature of
---a Playwright spec (ADR 0213 §2.2): a `.spec.ts` alone is just as likely Jest.
---@param path string
---@return boolean
function M.imports_playwright(path)
  local f = io.open(path, "r")
  if not f then return false end
  local text = f:read(65536) or ""
  f:close()
  return text:find("[\"']@playwright/test[\"']") ~= nil
end

---Is `path` a JS/TS spec-or-test file by name (`*.spec.*`, `*.test.*`)?
---@param path string
---@return boolean
function M.is_spec_name(path)
  if type(path) ~= "string" then return false end
  local ext = path:match("%.([%w]+)$")
  if not ext or not M.EXTENSIONS[ext] then return false end
  return path:match("%.test%.[%w]+$") ~= nil or path:match("%.spec%.[%w]+$") ~= nil
end

---Is `path` a Playwright spec: a spec-named file under a Playwright config
---root that imports `@playwright/test`?
---@param path string
---@return boolean
function M.is_playwright_spec(path)
  if not M.is_spec_name(path) then return false end
  if not M.playwright_root(fs_path.parent(path)) then return false end
  return M.imports_playwright(path)
end

---Strip ANSI escape sequences (runner error messages carry colour codes).
---@param s string
---@return string
function M.strip_ansi(s)
  return (tostring(s):gsub("\27%[[%d;]*[A-Za-z]", ""))
end

---Escape JS-regex metacharacters.
---@param s string
---@return string
function M.regex_escape(s)
  return (s:gsub("[%^%$%.%*%+%?%(%)%[%]%{%}%|\\/]", "\\%0"))
end

return M
