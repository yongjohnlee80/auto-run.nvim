---auto-run.adapters.playwright — the Playwright test adapter (ADR 0213 §2.2).
---
---Root: the nearest directory holding a `playwright.config.*`. A file is a
---Playwright spec when it is spec-named, under such a root, AND imports
---`@playwright/test` — the import is the positive signature, since a
---`.spec.ts` is just as likely a Jest file (`auto-run.adapters.js`).
---
---Discovery: treesitter over `test.describe(…)` (and its .only/.skip/.fixme/
---.serial/.parallel forms) as namespaces and `test(…)` (and .only/.skip/
---.fixme/.fail/.slow) as tests, each with a string-literal title.
---
---Runs select by POSITION — `<file>:<line>` runs the test, or every test of
---the describe, declared on that line (verified on VM43) — with
---`--reporter=json` written to `PLAYWRIGHT_JSON_OUTPUT_NAME`. Results map back
---through `config.rootDir + suite.file` and the title chain; a spec's
---per-project tests aggregate (any unexpected → failed, all skipped →
---skipped, else passed; flaky counts as passed).
---
---Debug: pwa-node runs `@playwright/test/cli.js test <file>:<line>
-----workers=1 --timeout=0` — one process tree to follow, and no timeout to
---fail a test while the user steps (verified stopping at a breakpoint).
---@module 'auto-run.adapters.playwright'

local fs_path = require("auto-core.fs.path")
local js = require("auto-run.adapters.js")

local M = {}

M.name = "playwright"
M.summary = "Playwright end-to-end tests, selected by file:line; debug with js-debug"

---@param dir string
---@return string?
function M.root(dir)
  return js.playwright_root(dir)
end

-- The scan keeps a dir when ANY adapter accepts it, so this prunes the
-- cross-ecosystem noise the others prune too (vendor/, target/), or an
-- accepting playwright would re-include them.
local SKIP_DIRS = {
  node_modules = true, coverage = true, dist = true, build = true, out = true,
  ["playwright-report"] = true, ["test-results"] = true,
  vendor = true, target = true,
}

function M.filter_dir(name, _rel, _root)
  return SKIP_DIRS[name] ~= true
end

---@param path string
---@return boolean
function M.is_test_file(path)
  return js.is_playwright_spec(path)
end

-- ── discovery ───────────────────────────────────────────────────

local QUERY_SRC = [[
  ;; test.describe("name", …)
  ((call_expression
     function: (member_expression
       object: (identifier) @obj
       property: (property_identifier) @ns_func)
     arguments: (arguments . [(string) (template_string)] @ns_name)) @ns_def
   (#eq? @obj "test")
   (#eq? @ns_func "describe"))

  ;; test.describe.only / .skip / .fixme / .serial / .parallel
  ((call_expression
     function: (member_expression
       object: (member_expression
         object: (identifier) @obj
         property: (property_identifier) @ns_func)
       property: (property_identifier) @ns_mod)
     arguments: (arguments . [(string) (template_string)] @ns_name)) @ns_def
   (#eq? @obj "test")
   (#eq? @ns_func "describe")
   (#any-of? @ns_mod "only" "skip" "fixme" "serial" "parallel"))

  ;; test("name", …)
  ((call_expression
     function: (identifier) @test_func
     arguments: (arguments . [(string) (template_string)] @test_name)) @test_def
   (#eq? @test_func "test"))

  ;; test.only / .skip / .fixme / .fail / .slow ("name", …)
  ((call_expression
     function: (member_expression
       object: (identifier) @test_func
       property: (property_identifier) @test_mod)
     arguments: (arguments . [(string) (template_string)] @test_name)) @test_def
   (#eq? @test_func "test")
   (#any-of? @test_mod "only" "skip" "fixme" "fail" "slow"))
]]

local function lang_for(path)
  local ext = path:match("%.([%w]+)$")
  if ext == "ts" or ext == "mts" or ext == "cts" then return "typescript" end
  if ext == "tsx" then return "tsx" end
  return "javascript"
end

local _queries = {}
local function get_query(lang)
  if _queries[lang] == nil then
    _queries[lang] = vim.treesitter.query.parse(lang, QUERY_SRC)
  end
  return _queries[lang]
end

local function literal_name(text)
  return text:match('^"(.*)"$') or text:match("^'(.*)'$") or text:match("^`(.*)`$") or text
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

  local flat = {}
  for _, match in query:iter_matches(trees[1]:root(), source, 0, -1) do
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
        flat[#flat + 1] = { name = name, kind = kind, srow = srow + 1, erow = erow + 1,
          sbyte = sbyte, ebyte = ebyte, children = {} }
      end
    end
  end
  if #flat == 0 then return nil, nil end
  return require("auto-run.adapters.nesting").file_position(path, flat), nil
end

-- ── run ─────────────────────────────────────────────────────────

---The project-local Playwright CLI (`node_modules/.bin/playwright`).
---@param root string
---@return string?
local function cli_bin(root)
  return js.find_module(root, ".bin/playwright")
end

---The `<file>:<line>` / file / dir selector for a position, relative to root.
---@param pos AutoRunPosition
---@param root string
---@return string?
local function selector(pos, root)
  local rel = fs_path.relative(pos.path, root) or pos.path
  if pos.type == "test" or pos.type == "namespace" then
    return rel .. ":" .. tostring(pos.lnum or 1)
  end
  if pos.type == "dir" and (rel == "" or rel == ".") then return nil end
  return rel
end
M._selector = selector

---@param args AutoRunSpecArgs
---@return AutoRunSpec? spec, string? err
function M.build_spec(args)
  local pos, root = args.position, args.root
  local bin = cli_bin(root)
  if not bin then
    return nil, "no project-local Playwright (node_modules/.bin/playwright) under " .. root
  end
  local applied, cfg_err = require("auto-run.adapters.config").test_config(M.name)
  if cfg_err then return nil, cfg_err end
  local output_file = fs_path.join(args.run_dir, "playwright.json")
  local argv = { bin, "test", "--reporter=json" }
  local sel = selector(pos, root)
  if sel then argv[#argv + 1] = sel end
  local env = vim.tbl_extend("force", applied and applied.env or {},
    { PLAYWRIGHT_JSON_OUTPUT_NAME = output_file })
  return {
    cmd = argv,
    cwd = root,
    env = env,
    context = { position_id = pos.id, output_file = output_file },
  }, nil
end

-- ── results ─────────────────────────────────────────────────────

---Name segments of a position id after its path.
local function id_segments(pos)
  return vim.split(pos.id:sub(#pos.path + 3), "::", { plain = true })
end

---Aggregate one spec's per-project tests into one result.
---@param spec table
---@return AutoRunResult
local function spec_result(spec)
  local any_unexpected, all_skipped, duration, out = false, true, 0, nil
  for _, t in ipairs(spec.tests or {}) do
    if t.status ~= "skipped" then all_skipped = false end
    if t.status == "unexpected" then any_unexpected = true end
    for _, r in ipairs(t.results or {}) do
      if type(r.duration) == "number" then duration = duration + r.duration end
      if out == nil and type(r.error) == "table" and type(r.error.message) == "string" then
        out = js.strip_ansi(r.error.message)
      end
    end
  end
  local status = any_unexpected and "failed" or (all_skipped and #(spec.tests or {}) > 0) and "skipped"
    or "passed"
  return { status = status, duration_ms = duration, output = status == "failed" and out or nil }
end

---Parse the JSON report into results keyed by position id.
---@param spec AutoRunSpec
---@param _exit table
---@param tree table
---@return table<string, AutoRunResult>
function M.results(spec, _exit, tree)
  local scope = tree:get(spec.context.position_id)
  if not scope then return {} end
  local f = io.open(spec.context.output_file, "r")
  if not f then return {} end
  local content = f:read("*a")
  f:close()
  local okd, data = pcall(vim.json.decode, content)
  if not okd or type(data) ~= "table" or type(data.suites) ~= "table" then return {} end
  local root_dir = type(data.config) == "table" and data.config.rootDir or nil

  local map = {}
  local function visit(pos)
    if pos.type == "test" then
      map[pos.path .. "\0" .. table.concat(id_segments(pos), "\0")] = pos.id
    end
    for _, c in ipairs(pos.children or {}) do visit(c) end
  end
  visit(scope)

  local results = {}
  local function walk(suite, file, titles)
    for _, sp in ipairs(suite.specs or {}) do
      local f2 = type(sp.file) == "string" and sp.file or file
      local abs = f2 and (f2:sub(1, 1) == "/" and f2 or (root_dir and fs_path.join(root_dir, f2) or f2))
      if abs then
        local segs = vim.list_extend(vim.deepcopy(titles), { sp.title })
        local id = map[fs_path.normalize(abs) .. "\0" .. table.concat(segs, "\0")]
        if id then results[id] = spec_result(sp) end
      end
    end
    for _, child in ipairs(suite.suites or {}) do
      local t2 = vim.deepcopy(titles)
      t2[#t2 + 1] = child.title
      walk(child, type(child.file) == "string" and child.file or file, t2)
    end
  end
  -- Top-level suites are FILES (their title is the file name), so their
  -- title is not part of a test's name.
  for _, file_suite in ipairs(data.suites) do
    walk(file_suite, file_suite.file, {})
  end
  return results
end

---The reconstructed terminal output of a run: each test's stdout/stderr.
---@param exit { run_dir: string }
---@return string
function M.output(exit, _opts)
  local f = io.open(fs_path.join(exit.run_dir, "playwright.json"), "r")
  if not f then return "" end
  local okd, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not okd or type(data) ~= "table" then return "" end
  local lines = {}
  local function walk(suite, prefix)
    for _, sp in ipairs(suite.specs or {}) do
      for _, t in ipairs(sp.tests or {}) do
        for _, r in ipairs(t.results or {}) do
          lines[#lines + 1] = ("%s%s [%s] %s"):format(prefix, sp.title, tostring(t.projectName or ""), tostring(r.status))
          for _, chunk in ipairs(r.stdout or {}) do lines[#lines + 1] = "  " .. tostring(chunk.text or "") end
          for _, chunk in ipairs(r.stderr or {}) do lines[#lines + 1] = "  " .. tostring(chunk.text or "") end
          if type(r.error) == "table" and r.error.message then
            lines[#lines + 1] = "  " .. js.strip_ansi(r.error.message)
          end
        end
      end
    end
    for _, c in ipairs(suite.suites or {}) do walk(c, prefix .. c.title .. " › ") end
  end
  for _, s in ipairs(data.suites or {}) do walk(s, "") end
  return table.concat(lines, "\n")
end

-- ── debug ───────────────────────────────────────────────────────

---@param pos AutoRunPosition
---@param _opts table
---@param cb fun(launch: table|nil, err: table|nil)
function M.prepare_debug(pos, _opts, cb)
  local root = M.root(fs_path.parent(pos.path))
  if not root then return cb(nil, { code = "no_root", message = "no playwright.config above " .. pos.path }) end
  local bin = cli_bin(root)
  if not bin then
    return cb(nil, { code = "playwright_missing",
      message = "@playwright/test is not installed under " .. vim.fn.fnamemodify(root, ":~") })
  end
  local applied, cfg_err = require("auto-run.adapters.config").test_config(M.name)
  if cfg_err then return cb(nil, { code = "config_failed", message = cfg_err }) end
  local args = { "test" }
  local sel = selector(pos, root)
  if sel then args[#args + 1] = sel end
  vim.list_extend(args, { "--workers=1", "--timeout=0" })
  return cb({
    dap_type = "pwa-node",
    request  = "launch",
    -- The CLI script itself, not the .bin symlink: js-debug runs it with node.
    program  = vim.uv.fs_realpath(bin) or bin,
    args     = args,
    cwd      = root,
    env      = applied and applied.env or nil,
    extra    = js.debug_extra(),
  }, nil)
end

-- ── preflight ───────────────────────────────────────────────────

---Where Playwright keeps its browsers.
---@return string
local function browsers_dir()
  local env = vim.env.PLAYWRIGHT_BROWSERS_PATH
  if env and env ~= "" and env ~= "0" then return env end
  if vim.fn.has("mac") == 1 then return vim.fn.expand("~/Library/Caches/ms-playwright") end
  local xdg = vim.env.XDG_CACHE_HOME
  return (xdg and xdg ~= "" and xdg or vim.fn.expand("~/.cache")) .. "/ms-playwright"
end

local BROWSERS = { chromium = true, ["chromium-headless-shell"] = true, firefox = true, webkit = true }

---Which default browsers the INSTALLED Playwright expects but cannot find, at
---the exact revisions its `browsers.json` names (an older cache does not count:
---VM43 held chromium-1228 while Playwright 1.63 needs 1243). `nil` when the
---version file cannot be read.
---@param root string
---@return string[]? missing, integer? expected
function M.missing_browsers(root)
  local file = js.find_module(root, "playwright-core/browsers.json")
  if not file then return nil end
  local f = io.open(file, "r")
  if not f then return nil end
  local okd, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not okd or type(data) ~= "table" or type(data.browsers) ~= "table" then return nil end
  local dir = browsers_dir()
  local missing, expected = {}, 0
  for _, b in ipairs(data.browsers) do
    if type(b) == "table" and BROWSERS[b.name] and b.installByDefault then
      expected = expected + 1
      local install = fs_path.join(dir, b.name:gsub("%-", "_") .. "-" .. tostring(b.revision))
      if not fs_path.is_dir(install) then missing[#missing + 1] = b.name end
    end
  end
  return missing, expected
end

---@param ctx { root: string, purpose: "run"|"test"|"debug", eff: table? }
---@return AutoRunIssue[]
function M.preflight(ctx)
  local root = ctx.root and M.root(ctx.root) or nil
  if not root then return {} end
  local pkg = js.package_root(root) or root
  local issues = js.base_issues(pkg)
  for _, i in ipairs(issues) do
    if i.code == "node_modules_missing" then return issues end
  end
  local pm = js.package_manager(pkg)
  if not cli_bin(root) then
    issues[#issues + 1] = { level = "error", code = "playwright_missing",
      message = "@playwright/test is not installed in " .. vim.fn.fnamemodify(pkg, ":~"),
      fix = js.add_dev_cmd(pm, "@playwright/test") }
    return issues
  end
  local missing, expected = M.missing_browsers(root)
  if missing and #missing > 0 then
    local none = #missing == expected
    issues[#issues + 1] = { level = none and "error" or "warn", code = "browsers_missing",
      message = none and "no Playwright browsers are installed for this Playwright version"
        or ("Playwright browsers missing: " .. table.concat(missing, ", ")),
      fix = (pm == "npm" and "npx" or pm .. " exec") .. " playwright install" }
  end
  if ctx.purpose == "debug" then vim.list_extend(issues, js.debug_issues()) end
  return issues
end

return M
