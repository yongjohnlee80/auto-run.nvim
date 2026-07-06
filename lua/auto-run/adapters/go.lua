---auto-run.adapters.go — the Go test adapter (ADR-0048 §7).
---
---Discovery: treesitter (injections disabled) over `*_test.go` —
---`func Test*` / `func Example*` (excluding `TestMain`) plus `t.Run`
---subtests, nested arbitrarily. Interface-inspired by neotest-golang;
---implementation original.
---
---Roots: nearest enclosing `go.mod`, promoted to the enclosing
---`go.work` when one exists above it (workspace mode) — the
---primary-root policy for nested modules, memoized per dir.
---
---Runs: `go test -json` from the root with `^`-anchored slash-split
---`-run` regexes (test), an alternation of the file's top-level
---funcs (file), or a `./rel/...` package pattern (dir). The `-json`
---stream on stdout IS the machine channel — the job engine writes it
---to the per-run `stdout` file, which `results()` parses back to
---position ids. When the store holds a kind=test config for the
---repo, its effective `build_flags` + composed env apply to every
---run (gobugger `run_test` parity).
---@module 'auto-run.adapters.go'

local fs_path = require("auto-core.fs.path")

local M = {}

M.name = "go"

-- ── root detection (primary-root cache) ─────────────────────────

---dir → module/workspace root (false = negative cache).
---@type table<string, string|false>
local _root_cache = {}
---module dir → module path from go.mod (false = unparsable).
---@type table<string, string|false>
local _module_path_cache = {}

---@param dir string
---@param marker string
---@return string? found_dir
local function walk_up_for(dir, marker)
  local cur = fs_path.normalize(dir)
  while cur and cur ~= "" do
    if fs_path.exists(fs_path.join(cur, marker)) then return cur end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

---Nearest enclosing dir carrying a `go.mod` (no go.work promotion) —
---the unit import paths are relative to.
---@param dir string
---@return string?
function M.module_dir(dir)
  return walk_up_for(dir, "go.mod")
end

---Project root for `dir`: the enclosing `go.work` dir when one exists
---at/above the nearest `go.mod`, else that `go.mod` dir. Memoized —
---the primary-root cache for nested-module layouts.
---@param dir string
---@return string?
function M.root(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  dir = fs_path.normalize(dir)
  local cached = _root_cache[dir]
  if cached ~= nil then return cached or nil end
  local mod = M.module_dir(dir)
  local root = nil
  if mod then
    root = walk_up_for(mod, "go.work") or mod
  end
  _root_cache[dir] = root or false
  return root
end

---`module <path>` from a module dir's go.mod. Memoized.
---@param mod_dir string
---@return string?
local function module_path(mod_dir)
  local cached = _module_path_cache[mod_dir]
  if cached ~= nil then return cached or nil end
  local out = nil
  local f = io.open(fs_path.join(mod_dir, "go.mod"), "r")
  if f then
    for line in f:lines() do
      local m = line:match("^%s*module%s+(%S+)")
      if m then out = m break end
    end
    f:close()
  end
  _module_path_cache[mod_dir] = out or false
  return out
end

---Import path of the package in `dir` (module path + relative dir).
---@param dir string
---@return string?
local function import_path(dir)
  local mod_dir = M.module_dir(dir)
  if not mod_dir then return nil end
  local mp = module_path(mod_dir)
  if not mp then return nil end
  local rel = dir:sub(#mod_dir + 2)
  if rel == nil or rel == "" then return mp end
  return mp .. "/" .. rel
end

-- ── walk filter + file recognition ──────────────────────────────

---@param name string
---@return boolean descend
function M.filter_dir(name, _rel_path, _root)
  return name ~= "vendor" and name ~= "node_modules" and name ~= "testdata"
end

---@param path string
---@return boolean
function M.is_test_file(path)
  return type(path) == "string" and path:match("_test%.go$") ~= nil
end

-- ── discovery (treesitter, injections disabled) ─────────────────

local QUERY_SRC = [[
  ;; top-level test/example functions (TestMain excluded Lua-side).
  ;; NB: #match? is a VIM regex — \v (very magic) makes the
  ;; alternation group behave like PCRE.
  ((function_declaration
     name: (identifier) @func_name) @func_def
   (#match? @func_name "\\v^(Test|Example)"))

  ;; <recv>.Run("name", func(...){...}) subtests, any receiver name
  ((call_expression
     function: (selector_expression
       operand: (identifier)
       field: (field_identifier) @run_method)
     arguments: (argument_list
       [(interpreted_string_literal) (raw_string_literal)] @sub_name
       (func_literal))) @sub_def
   (#eq? @run_method "Run"))
]]

---@type vim.treesitter.Query?
local _query = nil

local function get_query()
  if _query == nil then
    _query = vim.treesitter.query.parse("go", QUERY_SRC)
  end
  return _query
end

---Strip the delimiters off a go string literal's source text.
---@param text string
---@return string
local function literal_name(text)
  local inner = text:match('^"(.*)"$') or text:match("^`(.*)`$")
  return inner or text
end

---Parse one `*_test.go` into a file position with nested test
---children. `(pos, nil)` / `(nil, err)` on parse failure / `(nil,
---nil)` when the file holds no positions.
---@param path string
---@return AutoRunPosition? file_pos, string? err
function M.discover_positions(path)
  local f, oerr = io.open(path, "r")
  if not f then return nil, "open: " .. tostring(oerr) end
  local source = f:read("*a")
  f:close()

  local okq, query = pcall(get_query)
  if not okq then return nil, "go query: " .. tostring(query) end
  local okp, parser = pcall(vim.treesitter.get_string_parser, source, "go",
    { injections = { go = "" } })
  if not okp then return nil, "go parser: " .. tostring(parser) end
  local trees = parser:parse()
  if not trees or not trees[1] then return nil, "go parse produced no tree" end
  local ts_root = trees[1]:root()

  -- Collect raw matches, then nest by byte-range containment.
  ---@type { name: string, srow: integer, erow: integer, sbyte: integer, ebyte: integer, children: table[] }[]
  local flat = {}
  for _, match, _ in query:iter_matches(ts_root, source, 0, -1) do
    local name_node, def_node
    for id, nodes in pairs(match) do
      local cap = query.captures[id]
      local node = nodes[#nodes]
      if cap == "func_name" or cap == "sub_name" then name_node = node end
      if cap == "func_def" or cap == "sub_def" then def_node = node end
    end
    if name_node and def_node then
      local raw = vim.treesitter.get_node_text(name_node, source)
      local name = literal_name(raw)
      if name ~= "TestMain" and name ~= "" then
        local srow, _, sbyte = def_node:start()
        local erow, _, ebyte = def_node:end_()
        flat[#flat + 1] = {
          name = name, srow = srow + 1, erow = erow + 1,
          sbyte = sbyte, ebyte = ebyte, children = {},
        }
      end
    end
  end
  if #flat == 0 then return nil, nil end

  -- Innermost-container nesting via a range stack (matches arrive in
  -- document order per iter_matches; sort defensively anyway).
  table.sort(flat, function(a, b)
    if a.sbyte == b.sbyte then return a.ebyte > b.ebyte end
    return a.sbyte < b.sbyte
  end)
  local top, stack = {}, {}
  for _, item in ipairs(flat) do
    while #stack > 0 and item.sbyte >= stack[#stack].ebyte do
      table.remove(stack)
    end
    local parent = stack[#stack]
    if parent then
      parent.children[#parent.children + 1] = item
    else
      top[#top + 1] = item
    end
    stack[#stack + 1] = item
  end

  local function to_position(item)
    local pos = {
      type     = "test",
      name     = item.name,
      path     = path,
      lnum     = item.srow,
      end_lnum = item.erow,
    }
    if #item.children > 0 then
      pos.children = {}
      for _, child in ipairs(item.children) do
        pos.children[#pos.children + 1] = to_position(child)
      end
    end
    return pos
  end

  local file_pos = {
    type     = "file",
    name     = fs_path.basename(path),
    path     = path,
    children = {},
  }
  for _, item in ipairs(top) do
    file_pos.children[#file_pos.children + 1] = to_position(item)
  end
  return file_pos, nil
end

-- ── run-name / -run regex mapping ───────────────────────────────

---`go test` rewrites spaces in subtest names to underscores before
---matching / reporting.
---@param name string
---@return string
local function go_run_name(name)
  return (name:gsub(" ", "_"))
end

---Escape RE2 metacharacters for a `-run` segment.
---@param s string
---@return string
local function regex_escape(s)
  return (s:gsub("[\\%.%+%*%?%(%)%|%[%]%{%}%^%$]", "\\%0"))
end

---Test-name segments of a position id: everything after the `path`
---head, in order (`path::TestFoo::sub name` → {TestFoo, sub name}).
---@param pos AutoRunPosition
---@return string[]
local function id_segments(pos)
  local rest = pos.id:sub(#pos.path + 3)  -- skip "path::"
  return vim.split(rest, "::", { plain = true })
end

---The name `go test -json` reports for a position
---(`TestFoo/sub_name/deeper`).
---@param pos AutoRunPosition
---@return string
local function reported_name(pos)
  local parts = {}
  for _, seg in ipairs(id_segments(pos)) do
    parts[#parts + 1] = go_run_name(seg)
  end
  return table.concat(parts, "/")
end

---`^`-anchored slash-split -run regex for one test position.
---@param pos AutoRunPosition
---@return string
local function run_regex(pos)
  local parts = {}
  for _, seg in ipairs(id_segments(pos)) do
    parts[#parts + 1] = "^" .. regex_escape(go_run_name(seg)) .. "$"
  end
  return table.concat(parts, "/")
end

-- ── effective kind=test config (gobugger run_test parity) ───────

---Name of the repo's first non-error kind=test config with a go (or
---unset) runtime — the config whose `build_flags`/env apply to every
---adapter-driven test run (and to `debug_position`'s debug_test).
---@return string?
function M.test_config_name()
  local ok, store = pcall(require, "auto-run.store")
  if not ok then return nil end
  for _, c in ipairs(store.list()) do
    if not c.error and c.kind == "test"
        and (c.runtime == nil or c.runtime == "go") then
      return c.name
    end
  end
  return nil
end

---The picked kind=test config as `{ build_flags?, env? }` — composed
---through the Phase 1 pipeline. `(nil, nil)` when the repo has no
---such config; `(nil, err)` when the config exists but composition
---fails (never silently dropped).
---@return { build_flags: string?, env: table<string,string>? }? applied, string? err
local function test_config()
  local picked = M.test_config_name()
  if not picked then return nil, nil end

  local store = require("auto-run.store")
  local eff, gerr = store.get(picked)
  if not eff then return nil, tostring(gerr) end
  local env_mod = require("auto-run.env")
  local ctx = env_mod.context()
  eff = env_mod.substitute_deep(eff, ctx)
  local comp, cerr = env_mod.compose(eff, { ctx = ctx })
  if not comp then
    return nil, "config '" .. picked .. "': "
      .. (cerr and cerr.message or "env composition failed")
  end
  local out = {}
  if type(eff.build_flags) == "string" and eff.build_flags ~= "" then
    out.build_flags = eff.build_flags
  end
  if next(comp.env) ~= nil then out.env = comp.env end
  return out, nil
end

-- ── build_spec ──────────────────────────────────────────────────

---Relative package argument for a file/test position (`./rel`, or
---`.` at the root).
---@param file_dir string
---@param root string
---@return string
local function package_arg(file_dir, root)
  if file_dir == root then return "." end
  return "./" .. file_dir:sub(#root + 2)
end

---@param args AutoRunSpecArgs
---@return AutoRunSpec? spec, string? err
function M.build_spec(args)
  local pos, root = args.position, args.root
  local applied, cfg_err = test_config()
  if cfg_err then return nil, cfg_err end

  local argv = { "go", "test", "-json" }
  if applied and applied.build_flags then
    for _, flag in ipairs(vim.split(applied.build_flags, "%s+", { trimempty = true })) do
      argv[#argv + 1] = flag
    end
  end

  if pos.type == "test" then
    argv[#argv + 1] = "-run"
    argv[#argv + 1] = run_regex(pos)
    argv[#argv + 1] = package_arg(fs_path.parent(pos.path), root)
  elseif pos.type == "file" then
    -- Alternation of the file's TOP-LEVEL funcs (subtests ride along).
    local names = {}
    for _, child in ipairs(pos.children or {}) do
      if child.type == "test" then
        names[#names + 1] = regex_escape(go_run_name(child.name))
      end
    end
    if #names == 0 then return nil, nil end  -- nothing runnable → decompose
    argv[#argv + 1] = "-run"
    argv[#argv + 1] = "^(" .. table.concat(names, "|") .. ")$"
    argv[#argv + 1] = package_arg(fs_path.parent(pos.path), root)
  elseif pos.type == "dir" then
    local rel = pos.path == root and "." or "./" .. pos.path:sub(#root + 2)
    argv[#argv + 1] = rel .. "/..."
  else
    return nil, "go adapter cannot run a '" .. tostring(pos.type) .. "' position"
  end

  return {
    cmd     = argv,
    cwd     = root,
    env     = applied and applied.env or nil,
    context = { position_id = pos.id },
  }, nil
end

-- ── results (go test -json stream → position ids) ───────────────

---Map every test position under `scope` by `(import_path, reported
---name)` so `-json` events key straight back to ids.
---@param scope AutoRunPosition
---@return table<string, string> map  "pkg\0name" → position id
local function scope_map(scope)
  local map = {}
  local function visit(pos)
    if pos.type == "test" then
      local pkg = import_path(fs_path.parent(pos.path))
      if pkg then
        map[pkg .. "\0" .. reported_name(pos)] = pos.id
      end
    end
    for _, child in ipairs(pos.children or {}) do visit(child) end
  end
  visit(scope)
  return map
end

---Parse the per-run stdout file (the `go test -json` event stream).
---@param spec AutoRunSpec
---@param exit { code: integer?, signal: integer?, stdout_file: string, run_dir: string }
---@param tree table  AutoRunTree
---@return table<string, AutoRunResult>
function M.results(spec, exit, tree)
  local scope = tree:get(spec.context.position_id)
  if not scope then return {} end
  local map = scope_map(scope)

  ---per "pkg\0name": { status, elapsed, output_lines }
  local seen = {}
  local f = io.open(exit.stdout_file, "r")
  if not f then return {} end
  for line in f:lines() do
    local okd, ev = pcall(vim.json.decode, line)
    if okd and type(ev) == "table" and type(ev.Test) == "string"
        and type(ev.Package) == "string" then
      local key = ev.Package .. "\0" .. ev.Test
      local rec = seen[key]
      if not rec then
        rec = { output = {} }
        seen[key] = rec
      end
      if ev.Action == "pass" or ev.Action == "fail" or ev.Action == "skip" then
        rec.status = ev.Action == "pass" and "passed"
          or ev.Action == "fail" and "failed" or "skipped"
        if type(ev.Elapsed) == "number" then
          rec.duration_ms = ev.Elapsed * 1000
        end
      elseif ev.Action == "output" and type(ev.Output) == "string" then
        if #rec.output < 50 then rec.output[#rec.output + 1] = ev.Output end
      end
    end
  end
  f:close()

  local results = {}
  for key, rec in pairs(seen) do
    local id = map[key]
    if id and rec.status then
      results[id] = {
        status      = rec.status,
        duration_ms = rec.duration_ms,
        output      = rec.status == "failed"
          and table.concat(rec.output) or nil,
      }
    end
  end
  return results
end

---Test-only: drop the memoized root/module caches.
function M._reset_for_tests()
  _root_cache, _module_path_cache = {}, {}
end

return M
