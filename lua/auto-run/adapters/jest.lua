---auto-run.adapters.jest — the Jest/RTL test adapter (ADR-0048 §7).
---
---Discovery: treesitter (injections disabled) over `*.test.*` /
---`*.spec.*` / `__tests__/*` sources — `describe` blocks become
---namespaces, `it`/`test` calls become tests, common aliases and
---`.only`/`.skip` modifiers included. Query shape interface-inspired
---by neotest-jest; written from scratch. RTL is covered implicitly
---(RTL tests are jest tests).
---
---Roots: one root per `package.json` dir (nearest enclosing,
---memoized) — a monorepo worktree renders each package as its own
---top-level folder.
---
---Runs: the project-local `node_modules/.bin/jest` (package dir
---first, then hoisted parents up to the worktree) with
---`--json --outputFile=<per-run file>` as the machine channel and a
---regex-escaped, ancestor-joined `--testNamePattern` for
---test/namespace positions. `results()` parses the output file back
---to position ids via `ancestorTitles` + `title`.
---@module 'auto-run.adapters.jest'

local fs_path = require("auto-core.fs.path")

local M = {}

M.name = "jest"

-- ── root detection (per-package.json, memoized) ─────────────────

---dir → package root (false = negative cache).
---@type table<string, string|false>
local _root_cache = {}

---Nearest enclosing dir carrying a `package.json`.
---@param dir string
---@return string?
function M.root(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  dir = fs_path.normalize(dir)
  local cached = _root_cache[dir]
  if cached ~= nil then return cached or nil end
  local cur, root = dir, nil
  while cur and cur ~= "" do
    if fs_path.is_file(fs_path.join(cur, "package.json")) then
      root = cur
      break
    end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then break end
    cur = parent
  end
  _root_cache[dir] = root or false
  return root
end

-- ── walk filter + file recognition ──────────────────────────────

local SKIP_DIRS = {
  node_modules = true, coverage = true, dist = true,
  build = true, out = true, vendor = true,
}

---@param name string
---@return boolean descend
function M.filter_dir(name, _rel_path, _root)
  return SKIP_DIRS[name] ~= true
end

local EXTENSIONS = { js = true, jsx = true, ts = true, tsx = true, mjs = true, cjs = true }

---@param path string
---@return boolean
function M.is_test_file(path)
  if type(path) ~= "string" then return false end
  local ext = path:match("%.([%w]+)$")
  if not ext or not EXTENSIONS[ext] then return false end
  if path:match("%.test%.[%w]+$") or path:match("%.spec%.[%w]+$") then
    return true
  end
  return path:match("/__tests__/[^/]+$") ~= nil
end

-- ── discovery (treesitter, injections disabled) ─────────────────

local QUERY_SRC = [[
  ;; describe("name", …) and alias forms
  ((call_expression
     function: (identifier) @ns_func
     arguments: (arguments . [(string) (template_string)] @ns_name)) @ns_def
   (#any-of? @ns_func "describe" "fdescribe" "xdescribe"))

  ;; describe.only / describe.skip
  ((call_expression
     function: (member_expression
       object: (identifier) @ns_func
       property: (property_identifier) @ns_mod)
     arguments: (arguments . [(string) (template_string)] @ns_name)) @ns_def
   (#any-of? @ns_func "describe" "fdescribe" "xdescribe")
   (#any-of? @ns_mod "only" "skip"))

  ;; it("name", …) / test("name", …) and alias forms
  ((call_expression
     function: (identifier) @test_func
     arguments: (arguments . [(string) (template_string)] @test_name)) @test_def
   (#any-of? @test_func "it" "test" "fit" "xit" "xtest"))

  ;; it.only / it.skip / test.todo / test.failing
  ((call_expression
     function: (member_expression
       object: (identifier) @test_func
       property: (property_identifier) @test_mod)
     arguments: (arguments . [(string) (template_string)] @test_name)) @test_def
   (#any-of? @test_func "it" "test" "fit" "xit" "xtest")
   (#any-of? @test_mod "only" "skip" "todo" "failing"))
]]

---Language for a source path.
---@param path string
---@return string
local function lang_for(path)
  local ext = path:match("%.([%w]+)$")
  if ext == "ts" then return "typescript" end
  if ext == "tsx" then return "tsx" end
  return "javascript"
end

---lang → parsed query (parsed lazily; a missing parser degrades to a
---structured error from discover_positions).
---@type table<string, vim.treesitter.Query>
local _queries = {}

local function get_query(lang)
  if _queries[lang] == nil then
    _queries[lang] = vim.treesitter.query.parse(lang, QUERY_SRC)
  end
  return _queries[lang]
end

---Strip quotes/backticks off a string / template_string node's text.
---@param text string
---@return string
local function literal_name(text)
  local inner = text:match('^"(.*)"$') or text:match("^'(.*)'$")
    or text:match("^`(.*)`$")
  return inner or text
end

---@param path string
---@return AutoRunPosition? file_pos, string? err
function M.discover_positions(path)
  local f, oerr = io.open(path, "r")
  if not f then return nil, "open: " .. tostring(oerr) end
  local source = f:read("*a")
  f:close()

  local lang = lang_for(path)
  local okq, query = pcall(get_query, lang)
  if not okq then return nil, lang .. " query: " .. tostring(query) end
  local okp, parser = pcall(vim.treesitter.get_string_parser, source, lang,
    { injections = { [lang] = "" } })
  if not okp then return nil, lang .. " parser: " .. tostring(parser) end
  local trees = parser:parse()
  if not trees or not trees[1] then return nil, lang .. " parse produced no tree" end
  local ts_root = trees[1]:root()

  ---@type { name: string, kind: string, srow: integer, erow: integer, sbyte: integer, ebyte: integer, children: table[] }[]
  local flat = {}
  for _, match, _ in query:iter_matches(ts_root, source, 0, -1) do
    local name_node, def_node, kind
    for id, nodes in pairs(match) do
      local cap = query.captures[id]
      local node = nodes[#nodes]
      if cap == "ns_name" then name_node, kind = node, "namespace" end
      if cap == "test_name" then name_node, kind = node, "test" end
      if cap == "ns_def" or cap == "test_def" then def_node = node end
    end
    if name_node and def_node then
      local name = literal_name(vim.treesitter.get_node_text(name_node, source))
      if name ~= "" then
        local srow, _, sbyte = def_node:start()
        local erow, _, ebyte = def_node:end_()
        flat[#flat + 1] = {
          name = name, kind = kind, srow = srow + 1, erow = erow + 1,
          sbyte = sbyte, ebyte = ebyte, children = {},
        }
      end
    end
  end
  if #flat == 0 then return nil, nil end

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
      type     = item.kind,
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

-- ── build_spec ──────────────────────────────────────────────────

---Escape JS-regex metacharacters (testNamePattern / path patterns).
---@param s string
---@return string
local function regex_escape(s)
  return (s:gsub("[%^%$%.%*%+%?%(%)%[%]%{%}%|\\/]", "\\%0"))
end

---Project-local jest binary: the package dir first, then hoisted
---parents up to (and including) the worktree root.
---@param pkg_root string
---@return string? bin
local function jest_bin(pkg_root)
  local dirs = require("auto-run.store").resolve_run_dirs()
  local stop = dirs.root or dirs.anchor
  local cur = pkg_root
  while cur and cur ~= "" do
    local candidate = fs_path.join(cur, "node_modules", ".bin", "jest")
    if fs_path.is_file(candidate) then return candidate end
    if cur == stop then break end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" or not fs_path.is_under(cur, stop) then
      break
    end
    cur = parent
  end
  return nil
end

---Name segments of a position id after the path head.
---@param pos AutoRunPosition
---@return string[]
local function id_segments(pos)
  local rest = pos.id:sub(#pos.path + 3)
  return vim.split(rest, "::", { plain = true })
end

---Ancestor-joined jest full-name prefix for a position (`Desc inner
---test name`, space-joined — jest's fullName convention).
---@param pos AutoRunPosition
---@return string
local function full_name(pos)
  return table.concat(id_segments(pos), " ")
end

---@param args AutoRunSpecArgs
---@return AutoRunSpec? spec, string? err
function M.build_spec(args)
  local pos, root = args.position, args.root
  local bin = jest_bin(root)
  if not bin then
    return nil, "no project-local jest binary (node_modules/.bin/jest) "
      .. "under " .. root
  end

  local output_file = fs_path.join(args.run_dir, "jest-output.json")
  local argv = { bin, "--json", "--outputFile=" .. output_file }

  if pos.type == "test" or pos.type == "namespace" then
    local pat = "^" .. regex_escape(full_name(pos))
    if pos.type == "test" then pat = pat .. "$" end
    argv[#argv + 1] = "--testNamePattern=" .. pat
    argv[#argv + 1] = regex_escape(fs_path.relative(pos.path, root) or pos.path)
  elseif pos.type == "file" then
    argv[#argv + 1] = regex_escape(fs_path.relative(pos.path, root) or pos.path)
  elseif pos.type == "dir" then
    local rel = fs_path.relative(pos.path, root)
    if rel and rel ~= "" then
      argv[#argv + 1] = regex_escape(rel)
    end
    -- dir == root → no path pattern: the whole package runs.
  else
    return nil, "jest adapter cannot run a '" .. tostring(pos.type) .. "' position"
  end

  return {
    cmd     = argv,
    cwd     = root,
    context = { position_id = pos.id, output_file = output_file },
  }, nil
end

-- ── results (outputFile JSON → position ids) ────────────────────

---@param spec AutoRunSpec
---@param exit { code: integer?, signal: integer?, stdout_file: string, run_dir: string }
---@param tree table  AutoRunTree
---@return table<string, AutoRunResult>
function M.results(spec, exit, tree)
  local scope = tree:get(spec.context.position_id)
  if not scope then return {} end

  local f = io.open(spec.context.output_file, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local okd, data = pcall(vim.json.decode, content)
  if not okd or type(data) ~= "table" or type(data.testResults) ~= "table" then
    return {}
  end

  -- Map every test position under scope by (file, \0-joined segments).
  local map = {}
  local function visit(pos)
    if pos.type == "test" then
      map[pos.path .. "\0" .. table.concat(id_segments(pos), "\0")] = pos.id
    end
    for _, child in ipairs(pos.children or {}) do visit(child) end
  end
  visit(scope)

  local results = {}
  for _, file_res in ipairs(data.testResults) do
    local file = type(file_res.name) == "string"
      and fs_path.normalize(file_res.name) or nil
    for _, a in ipairs(file_res.assertionResults or {}) do
      if file and type(a.title) == "string" then
        local segs = {}
        for _, t in ipairs(a.ancestorTitles or {}) do segs[#segs + 1] = t end
        segs[#segs + 1] = a.title
        local id = map[file .. "\0" .. table.concat(segs, "\0")]
        if id then
          local status = a.status == "passed" and "passed"
            or a.status == "failed" and "failed" or "skipped"
          results[id] = {
            status      = status,
            duration_ms = type(a.duration) == "number" and a.duration or nil,
            output      = status == "failed"
              and table.concat(a.failureMessages or {}, "\n") or nil,
          }
        end
      end
    end
  end
  return results
end

---Test-only: drop the memoized package-root cache.
function M._reset_for_tests()
  _root_cache = {}
end

return M
