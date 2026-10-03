---auto-run.adapters.dart — the Dart / Flutter adapter (ADR 0196 r3).
---
---One adapter for both: the package KIND (`dart` or `flutter`) decides the
---tool. Kind is read from pub's own resolution, `.dart_tool/package_config.json`
---(strict JSON): a package named `flutter` in the resolved graph means Flutter —
---which is also true of a package whose only Flutter reference is a
---`flutter_test` dev-dependency (verified on VM43). No YAML is parsed (§2.2.2);
---without that file nothing can run and preflight says to run `pub get`. A
---config's `dart_sdk` field overrides detection.
---
---Tests: `*_test.dart` under the package's `test/` (integration_test/ drives a
---device and is out of scope). Discovery: treesitter over `group` / `test` /
---`testWidgets` calls with a string-literal description. Runs: `dart test` /
---`flutter test --reporter=json`, selecting with an ANCHORED `--name '^…$'`
---regex — `--plain-name` is a substring match (VM43). Results come from the
---JSON event stream; a `testWidgets` test reports its location in `root_url`,
---not `url` (which points into flutter_test).
---
---Run configs: `dart run <program>`; Flutter `flutter run -d <device> -t
---<program>` for desktop devices. Debug: the SDK's DAP servers through
---`dap.adapters.dart` (auto-run.dap), with debugged-test results arriving as
---`dart.testNotification` events (auto-run.dap.dart_tests, §2.3.1).
---@module 'auto-run.adapters.dart'

local fs_path = require("auto-core.fs.path")

local M = {}

M.name = "dart"
M.summary = "Dart and Flutter — dart run, flutter run -d <desktop>, dart / flutter test; the SDK debug adapters"

---Desktop device ids `flutter run` may target (ADR 0196 §2.4).
M.DESKTOP_DEVICES = { linux = true, macos = true, windows = true }

---The desktop device of this machine.
---@return string
function M.default_device()
  if vim.fn.has("mac") == 1 then return "macos" end
  if vim.fn.has("win32") == 1 then return "windows" end
  return "linux"
end

-- ── root + package kind ─────────────────────────────────────────

---Nearest directory (inclusive) holding a `pubspec.yaml`.
---@param dir string
---@return string?
function M.root(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  local cur = fs_path.normalize(dir)
  while cur and cur ~= "" do
    if fs_path.is_file(fs_path.join(cur, "pubspec.yaml")) then return cur end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then break end
    cur = parent
  end
  return nil
end

---root → { sec, nsec, size, kind } (keyed on package_config.json's stat).
local _kind_cache = {}

---The package kind from pub's resolution: `"flutter"` when the resolved graph
---contains the `flutter` package, else `"dart"`. `(nil, code, message)` when it
---cannot be known: `"not_fetched"` (no package_config.json) or `"malformed"`.
---@param root string
---@return ("dart"|"flutter")? kind, string? code, string? message
function M.package_kind(root)
  local file = fs_path.join(root, ".dart_tool", "package_config.json")
  local st = vim.uv.fs_stat(file)
  if not st then
    _kind_cache[root] = nil
    return nil, "not_fetched", "dependencies are not fetched in " .. vim.fn.fnamemodify(root, ":~")
      .. " (no .dart_tool/package_config.json)"
  end
  local c = _kind_cache[root]
  if c and c.sec == st.mtime.sec and c.nsec == st.mtime.nsec and c.size == st.size then
    return c.kind
  end
  local f = io.open(file, "r")
  if not f then return nil, "malformed", "cannot read " .. file end
  local okd, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if not okd or type(data) ~= "table" or type(data.packages) ~= "table" then
    return nil, "malformed", file .. " is not a valid package config"
  end
  local kind = "dart"
  for _, p in ipairs(data.packages) do
    if type(p) == "table" and p.name == "flutter" then kind = "flutter" break end
  end
  _kind_cache[root] = { sec = st.mtime.sec, nsec = st.mtime.nsec, size = st.size, kind = kind }
  return kind
end

---Does `pubspec.yaml` declare an `sdk: flutter` dependency? A bounded line
---check used ONLY to word the "run pub get" hint before any resolution exists
---(§2.2.2) — it never selects a runner.
---@param root string
---@return boolean
function M.pubspec_mentions_flutter(root)
  local f = io.open(fs_path.join(root, "pubspec.yaml"), "r")
  if not f then return false end
  for line in f:lines() do
    -- Drop a comment: `#` at line start or after whitespace (YAML's rule).
    local code = line:gsub("^%s*#.*$", ""):gsub("%s+#.*$", "")
    if code:match("sdk%s*:%s*[\"']?flutter[\"']?%s*[,}]?%s*$")
        or code:match("sdk%s*:%s*[\"']?flutter[\"']?%s*[,}]") then
      f:close()
      return true
    end
  end
  f:close()
  return false
end

---The package's `name:` from pubspec.yaml (scaffold defaults only).
---@param root string
---@return string?
local function package_name(root)
  local f = io.open(fs_path.join(root, "pubspec.yaml"), "r")
  if not f then return nil end
  for line in f:lines() do
    local n = line:match("^name%s*:%s*[\"']?([%w_]+)")
    if n then f:close() return n end
  end
  f:close()
  return nil
end

---The repo's composed `kind=test` config for dart (its `dart_sdk` overrides).
local function test_config()
  return require("auto-run.adapters.config").test_config(M.name)
end

---Effective kind: an explicit `dart_sdk` override, else pub's resolution.
---@param root string
---@param override string?
---@return ("dart"|"flutter")? kind, string? message
local function effective_kind(root, override)
  if override == "dart" or override == "flutter" then return override end
  local kind, _, msg = M.package_kind(root)
  if not kind then return nil, msg end
  return kind
end

---The pub command a package needs (for hints).
---@param root string
---@return string
local function pub_get_cmd(root)
  local kind = M.package_kind(root)
  if kind == "flutter" or (kind == nil and M.pubspec_mentions_flutter(root)) then
    return "flutter pub get"
  end
  return "dart pub get"
end

-- ── test files + discovery ──────────────────────────────────────

-- The scan keeps a dir when ANY adapter accepts it, so this also prunes the
-- other ecosystems' noise (node_modules/, vendor/, target/).
local SKIP_DIRS = {
  build = true, [".dart_tool"] = true, integration_test = true,
  node_modules = true, vendor = true, target = true,
}

function M.filter_dir(name, _rel, _root)
  return SKIP_DIRS[name] ~= true
end

---@param path string
---@return boolean
function M.is_test_file(path)
  if type(path) ~= "string" or not path:match("_test%.dart$") then return false end
  local root = M.root(fs_path.parent(path))
  if not root then return false end
  local rel = fs_path.relative(path, root) or ""
  return rel:sub(1, 5) == "test/"
end

local QUERY_SRC = [[
  ((expression_statement
     (identifier) @func
     .
     (selector (argument_part (arguments . (argument (string_literal) @name))))) @def
   (#any-of? @func "group" "test" "testWidgets"))
]]

local _query
local function get_query()
  if not _query then _query = vim.treesitter.query.parse("dart", QUERY_SRC) end
  return _query
end

local ESCAPES = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ["'"] = "'", ['"'] = '"', ["$"] = "$" }

---Decode a Dart string literal's source text (possibly adjacent pieces) to
---its value, or nil when it interpolates (its runtime name is unknowable).
---@param text string
---@return string?
function M.decode_literal(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      local raw = false
      if c == "r" or c == "R" then raw, i = true, i + 1 end
      local q3 = text:sub(i, i + 2)
      local quote
      if q3 == "'''" or q3 == '"""' then quote = q3 else quote = text:sub(i, i) end
      if quote ~= "'" and quote ~= '"' and #quote ~= 3 then return nil end
      i = i + #quote
      local piece = {}
      while true do
        if i > n then return nil end
        if text:sub(i, i + #quote - 1) == quote then i = i + #quote break end
        local ch = text:sub(i, i)
        if not raw and ch == "\\" then
          local nx = text:sub(i + 1, i + 1)
          piece[#piece + 1] = ESCAPES[nx] or nx
          i = i + 2
        elseif not raw and ch == "$" then
          return nil
        else
          piece[#piece + 1] = ch
          i = i + 1
        end
      end
      out[#out + 1] = table.concat(piece)
    end
  end
  return table.concat(out)
end

---@param path string
---@return AutoRunPosition? file_pos, string? err
function M.discover_positions(path)
  local f, oerr = io.open(path, "r")
  if not f then return nil, "open: " .. tostring(oerr) end
  local source = f:read("*a")
  f:close()
  local okq, query = pcall(get_query)
  if not okq then return nil, "dart query: " .. tostring(query) end
  local okp, parser = pcall(vim.treesitter.get_string_parser, source, "dart",
    { injections = { dart = "" } })
  if not okp then return nil, "dart parser: " .. tostring(parser) end
  local trees = parser:parse()
  if not trees or not trees[1] then return nil, "dart parse produced no tree" end
  local flat = {}
  for _, match in query:iter_matches(trees[1]:root(), source, 0, -1) do
    local func, name_node, def
    for id, nodes in pairs(match) do
      local cap, node = query.captures[id], nodes[#nodes]
      if cap == "func" then func = vim.treesitter.get_node_text(node, source) end
      if cap == "name" then name_node = node end
      if cap == "def" then def = node end
    end
    if func and name_node and def then
      local name = M.decode_literal(vim.treesitter.get_node_text(name_node, source))
      if name and name ~= "" then
        local srow, _, sbyte = def:start()
        local erow, _, ebyte = def:end_()
        flat[#flat + 1] = { name = name, kind = func == "group" and "namespace" or "test",
          srow = srow + 1, erow = erow + 1, sbyte = sbyte, ebyte = ebyte, children = {} }
      end
    end
  end
  if #flat == 0 then return nil, nil end
  return require("auto-run.adapters.nesting").file_position(path, flat), nil
end

-- ── selection + run ─────────────────────────────────────────────

---Dart's full test name for a position: ancestor names space-joined.
---@param pos AutoRunPosition
---@return string
local function full_name(pos)
  local rest = pos.id:sub(#pos.path + 3)
  return table.concat(vim.split(rest, "::", { plain = true }), " ")
end
M._full_name = full_name

local function regex_escape(s)
  return (s:gsub("[%^%$%.%*%+%?%(%)%[%]%{%}%|\\/]", "\\%0"))
end

---The anchored `--name` regex for a test (exact) or group (prefix).
---@param pos AutoRunPosition
---@return string?
function M.name_pattern(pos)
  if pos.type == "test" then return "^" .. regex_escape(full_name(pos)) .. "$" end
  if pos.type == "namespace" then return "^" .. regex_escape(full_name(pos)) .. "( |$)" end
  return nil
end

---@param args AutoRunSpecArgs
---@return AutoRunSpec? spec, string? err
function M.build_spec(args)
  local pos, root = args.position, args.root
  local applied, cfg_err = test_config()
  if cfg_err then return nil, cfg_err end
  local kind, kerr = effective_kind(root, applied and applied.eff and applied.eff.dart_sdk)
  if not kind then return nil, kerr .. " — run `" .. pub_get_cmd(root) .. "`" end
  local argv = { kind, "test", "--reporter=json" }
  local rel = fs_path.relative(pos.path, root)
  if pos.type ~= "dir" or (rel and rel ~= "" and rel ~= ".") then
    argv[#argv + 1] = rel or pos.path
  end
  local pat = M.name_pattern(pos)
  if pat then
    argv[#argv + 1] = "--name"
    argv[#argv + 1] = pat
  end
  return {
    cmd = argv,
    cwd = root,
    env = applied and applied.env or nil,
    context = { position_id = pos.id, root = root },
  }, nil
end

-- ── reconciliation (shared by the stdout and DAP channels) ──────

---A fresh reconciliation state for one run.
---@param root string
---@return table
function M.new_state(root)
  return { root = root, suites = {}, tests = {}, reported = false }
end

---Absolute file of a reporter test: `root_url` (where testWidgets really is),
---else `url` unless it points into a package, else the suite path.
---@param state table
---@param test table
---@return string?
local function test_file(state, test)
  for _, u in ipairs({ test.root_url, test.url }) do
    if type(u) == "string" and u:sub(1, 7) == "file://" then
      return fs_path.normalize(vim.uri_to_fname(u))
    end
  end
  local sp = test.suiteID and state.suites[test.suiteID]
  if type(sp) == "string" then
    if sp:sub(1, 7) == "file://" then return fs_path.normalize(vim.uri_to_fname(sp)) end
    if sp:sub(1, 1) ~= "/" then sp = fs_path.join(state.root, sp) end
    return fs_path.normalize(sp)
  end
  return nil
end

---Feed one reporter event. Returns `(key, result)` when a test finished,
---where key = `<abs file>\0<full name>`; nil otherwise.
---@param state table
---@param ev table
---@return string? key, AutoRunResult? result
function M.reconcile(state, ev)
  if type(ev) ~= "table" then return nil end
  local t = ev.type
  if t == "suite" and type(ev.suite) == "table" then
    state.suites[ev.suite.id] = ev.suite.path
  elseif t == "testStart" and type(ev.test) == "table" then
    state.tests[ev.test.id] = { name = ev.test.name, file = test_file(state, ev.test), start = ev.time }
  elseif t == "error" then
    local rec = state.tests[ev.testID]
    if rec then
      rec.err = (rec.err and (rec.err .. "\n") or "") .. tostring(ev.error or "")
        .. (ev.stackTrace and ("\n" .. tostring(ev.stackTrace)) or "")
    end
  elseif t == "print" then
    local rec = state.tests[ev.testID]
    if rec then rec.out = (rec.out or "") .. tostring(ev.message or "") .. "\n" end
  elseif t == "testDone" then
    local rec = state.tests[ev.testID]
    if not rec or ev.hidden or not rec.file or type(rec.name) ~= "string" then return nil end
    state.reported = true
    local status = ev.skipped and "skipped" or (ev.result == "success" and "passed" or "failed")
    local dur = (type(ev.time) == "number" and type(rec.start) == "number") and (ev.time - rec.start) or nil
    return rec.file .. "\0" .. rec.name, {
      status = status, duration_ms = dur, output = status == "failed" and rec.err or nil,
    }
  end
  return nil
end

---Map every test position under `scope` by the reconciliation key.
---@param scope table
---@return table<string, string>
function M.scope_map(scope)
  local map = {}
  local function visit(pos)
    if pos.type == "test" then map[pos.path .. "\0" .. full_name(pos)] = pos.id end
    for _, c in ipairs(pos.children or {}) do visit(c) end
  end
  visit(scope)
  return map
end

---Each JSON event line of a stdout file (non-JSON lines skipped).
---@param file string
---@return fun(): table?
local function events(file)
  local f = io.open(file, "r")
  if not f then return function() return nil end end
  return function()
    while true do
      local line = f:read("*l")
      if not line then f:close() return nil end
      if line:sub(1, 1) == "{" then
        local ok, ev = pcall(vim.json.decode, line)
        if ok and type(ev) == "table" then return ev end
      end
    end
  end
end

---@param spec AutoRunSpec
---@param exit { stdout_file: string }
---@param tree table
---@return table<string, AutoRunResult>
function M.results(spec, exit, tree)
  local scope = tree:get(spec.context.position_id)
  if not scope then return {} end
  local map = M.scope_map(scope)
  local state = M.new_state(spec.context.root)
  local results = {}
  for ev in events(exit.stdout_file) do
    local key, res = M.reconcile(state, ev)
    if key and map[key] then results[map[key]] = res end
  end
  return results
end

---The terminal-like output of a run: each test's prints and errors.
---@param exit { stdout_file: string }
---@param opts { test: string? }?
---@return string
function M.output(exit, opts)
  local lines = {}
  local names = {}
  for ev in events(exit.stdout_file) do
    if ev.type == "testStart" and type(ev.test) == "table" then
      names[ev.test.id] = ev.test.name
    elseif (ev.type == "print" or ev.type == "error") and names[ev.testID] then
      local name = names[ev.testID]
      if not (opts and opts.test) or name:find(opts.test, 1, true) then
        lines[#lines + 1] = ev.type == "print" and tostring(ev.message)
          or (name .. ": " .. tostring(ev.error))
      end
    elseif ev.type == "testDone" and names[ev.testID] and not ev.hidden then
      local name = names[ev.testID]
      if not (opts and opts.test) or name:find(opts.test, 1, true) then
        lines[#lines + 1] = (ev.skipped and "SKIP " or ev.result == "success" and "PASS " or "FAIL ") .. name
      end
    end
  end
  return table.concat(lines, "\n")
end

-- ── configs (ADR 0194 §2.3.4 capabilities) ──────────────────────

---The working directory a config runs in.
local function eff_cwd(eff)
  if type(eff.cwd) == "string" and eff.cwd ~= "" then return eff.cwd end
  local dirs = require("auto-run.store").resolve_run_dirs()
  return dirs.workdir or dirs.root or dirs.anchor
end

local function program_path(eff)
  local p = eff.program
  if type(p) ~= "string" or p == "" then return nil end
  if p:sub(1, 1) ~= "/" then p = fs_path.join(eff_cwd(eff), p) end
  return fs_path.normalize(p)
end

---The package a config belongs to.
local function package_of(eff)
  local prog = program_path(eff)
  local root = prog and M.root(fs_path.parent(prog)) or nil
  return root or M.root(eff_cwd(eff))
end

---@param kind "run"|"test"|"debug"
---@param _name string?
---@return table
function M.default_config(kind, _name)
  local dirs = require("auto-run.store").resolve_run_dirs()
  local root, workdir = dirs.root, dirs.workdir or dirs.root or dirs.anchor
  local pkg = workdir and M.root(workdir) or workdir
  local base = "${worktree}"
  if root and pkg and pkg ~= root and pkg:sub(1, #root + 1) == root .. "/" then
    base = "${worktree}/" .. pkg:sub(#root + 2)
  end
  local cfg = { runtime = "dart", kind = kind, cwd = base }
  if kind == "test" then return cfg end
  local flutter = pkg and (M.package_kind(pkg) == "flutter"
    or (M.package_kind(pkg) == nil and M.pubspec_mentions_flutter(pkg)))
  if flutter then
    cfg.program = base .. "/lib/main.dart"
    cfg.device = M.default_device()
  else
    cfg.program = base .. "/bin/" .. (pkg and package_name(pkg) or "main") .. ".dart"
  end
  return cfg
end

---Why a dart config cannot run, or nil.
---@param eff table
---@return string?
function M.program_error(eff)
  local name = tostring(eff and eff.name)
  if eff.kind == "test" then return nil end
  if type(eff.program) ~= "string" or eff.program == "" then
    return ("config '%s': set `program` to the entry file (bin/<name>.dart, or lib/main.dart for Flutter)"):format(name)
  end
  if eff.program:find("${", 1, true) then return nil end
  local abs = program_path(eff)
  if abs and not fs_path.is_file(abs) then
    return ("config '%s': program %s does not exist"):format(name, vim.fn.fnamemodify(abs, ":~"))
  end
  if not package_of(eff) then
    return ("config '%s': no pubspec.yaml at or above %s"):format(name, vim.fn.fnamemodify(abs or eff_cwd(eff), ":~"))
  end
  return nil
end

---Why a Flutter device is refused, or nil (ADR 0196 §2.4).
---@param device string
---@return string?
function M.device_error(device)
  if M.DESKTOP_DEVICES[device] then return nil end
  return ("device '%s' is not supported — auto-run runs Flutter on desktop devices only"
    .. " (linux, macos, windows; ADR 0196 §2.4)"):format(tostring(device))
end

---@param eff table
---@param _opts table?
---@return string[]? argv, string? err
function M.build_run_argv(eff, _opts)
  local root = package_of(eff)
  if eff.kind == "test" then
    local kind, kerr = effective_kind(root or eff_cwd(eff), eff.dart_sdk)
    if not kind then return nil, kerr end
    local argv = { kind, "test" }
    if type(eff.program) == "string" and eff.program ~= "" then argv[#argv + 1] = eff.program end
    return argv, nil
  end
  local perr = M.program_error(eff)
  if perr then return nil, perr end
  local kind, kerr = effective_kind(root, eff.dart_sdk)
  if not kind then return nil, kerr .. " — run `" .. pub_get_cmd(root) .. "`" end
  if kind == "flutter" then
    local device = eff.device or M.default_device()
    local derr = M.device_error(device)
    if derr then return nil, derr end
    return { "flutter", "run", "-d", device, "-t", program_path(eff) }, nil
  end
  return { "dart", "run", program_path(eff) }, nil
end

---Launch-ready DAP config for a Dart / Flutter run|debug config.
---@param eff table
---@param _opts table
---@param cb fun(launch: table|nil, err: table|nil)
function M.prepare_debug_config(eff, _opts, cb)
  local perr = M.program_error(eff)
  if perr then return cb(nil, { code = "program_missing", message = perr }) end
  local root = package_of(eff)
  local kind, kerr = effective_kind(root, eff.dart_sdk)
  if not kind then
    return cb(nil, { code = "not_fetched", message = kerr .. " — run `" .. pub_get_cmd(root) .. "`" })
  end
  local args = type(eff.args) == "table" and #eff.args > 0 and vim.deepcopy(eff.args) or nil
  local launch = {
    dap_type = "dart", request = "launch", program = program_path(eff), cwd = root, env = eff.env,
    extra = { autoRunDartKind = kind, autoRunDartMode = "run" },
  }
  if kind == "flutter" then
    local device = eff.device or M.default_device()
    launch.extra.autoRunDartDevice = device
    -- Flutter's `args` are flutter-tool flags (--dart-define=…, --release),
    -- the same as for `flutter run`.
    launch.extra.toolArgs = vim.list_extend({ "-d", device }, args or {})
  else
    launch.args = args
  end
  return cb(launch, nil)
end

---Launch-ready DAP config for a discovered TEST position. Results of the
---debugged run reach the tests pane through the dart.testNotification bridge.
---@param pos AutoRunPosition
---@param opts table  core launch token
---@param cb fun(launch: table|nil, err: table|nil)
function M.prepare_debug(pos, opts, cb)
  local root = M.root(fs_path.parent(pos.path))
  if not root then return cb(nil, { code = "no_root", message = "no pubspec.yaml above " .. pos.path }) end
  local applied, cfg_err = test_config()
  if cfg_err then return cb(nil, { code = "config_failed", message = cfg_err }) end
  local kind, kerr = effective_kind(root, applied and applied.eff and applied.eff.dart_sdk)
  if not kind then
    return cb(nil, { code = "not_fetched", message = kerr .. " — run `" .. pub_get_cmd(root) .. "`" })
  end
  local bridge = require("auto-run.dap.dart_tests")
  local run_id = bridge.begin(pos, root)
  if type(opts) == "table" then
    opts.abort = function() bridge.abort(run_id) end
  end
  local tool_args = {}
  local pat = M.name_pattern(pos)
  if pat then tool_args = { "--name", pat } end
  return cb({
    dap_type = "dart", request = "launch", program = pos.path, cwd = root,
    env = applied and applied.env or nil,
    extra = { autoRunDartKind = kind, autoRunDartMode = "test", autoRunRunId = run_id,
      toolArgs = #tool_args > 0 and tool_args or nil },
  }, nil)
end

-- ── preflight (ADR 0196 §2.5) ───────────────────────────────────

---Linux desktop toolchain pieces `flutter run -d linux` needs.
local LINUX_DESKTOP = { "clang", "cmake", "ninja", "pkg-config" }

---@param ctx { root: string, purpose: "run"|"test"|"debug", eff: table? }
---@return AutoRunIssue[]
function M.preflight(ctx)
  local issues = {}
  local root = ctx.root and M.root(ctx.root) or nil
  if not root then return issues end
  local override = ctx.eff and ctx.eff.dart_sdk
  local kind, code = M.package_kind(root)
  local tool = override or kind or (M.pubspec_mentions_flutter(root) and "flutter" or "dart")
  if vim.fn.executable(tool) ~= 1 then
    issues[#issues + 1] = { level = "error", code = tool .. "_missing",
      message = (tool == "flutter" and "the Flutter SDK" or "the Dart SDK") .. " is not on PATH (`" .. tool .. "`)",
      fix = tool == "flutter" and "install Flutter (https://docs.flutter.dev/get-started/install) and add flutter/bin to PATH"
        or "install the Dart SDK (https://dart.dev/get-dart), or Flutter, which bundles it" }
  end
  if not kind then
    issues[#issues + 1] = { level = "error", code = code == "malformed" and "package_config_malformed" or "not_fetched",
      message = select(3, M.package_kind(root)) or "dependencies are not fetched",
      fix = "cd " .. vim.fn.fnamemodify(root, ":~") .. " && " .. pub_get_cmd(root) }
  else
    local ps = vim.uv.fs_stat(fs_path.join(root, "pubspec.yaml"))
    local pc = vim.uv.fs_stat(fs_path.join(root, ".dart_tool", "package_config.json"))
    if ps and pc and ps.mtime.sec > pc.mtime.sec then
      issues[#issues + 1] = { level = "warn", code = "pubspec_changed",
        message = "pubspec.yaml changed since the last pub get",
        fix = "cd " .. vim.fn.fnamemodify(root, ":~") .. " && " .. pub_get_cmd(root) }
    end
  end
  local eff = ctx.eff
  if eff and eff.kind ~= "test" and tool == "flutter" then
    local device = eff.device or M.default_device()
    local derr = M.device_error(device)
    if derr then
      issues[#issues + 1] = { level = "error", code = "device_unsupported", message = derr }
    elseif device == "linux" then
      local missing = {}
      for _, exe in ipairs(LINUX_DESKTOP) do
        if vim.fn.executable(exe) ~= 1 then missing[#missing + 1] = exe end
      end
      if #missing > 0 then
        issues[#issues + 1] = { level = "error", code = "linux_toolchain",
          message = "the Linux desktop toolchain is incomplete: missing " .. table.concat(missing, ", "),
          fix = "install clang, cmake, ninja-build, pkg-config and the GTK 3 headers (see `flutter doctor`)" }
      end
    end
  end
  if ctx.purpose ~= "run" and not pcall(vim.treesitter.language.inspect, "dart") then
    issues[#issues + 1] = { level = "warn", code = "dart_parser_missing",
      message = "no treesitter dart parser — Dart tests cannot be discovered",
      fix = ":TSInstall dart" }
  end
  if ctx.purpose == "debug" then
    local okd, dap = pcall(require, "dap")
    if okd and dap.adapters.dart ~= nil and not require("auto-run.dap").owns_dart_adapter(dap) then
      issues[#issues + 1] = { level = "warn", code = "dart_adapter_foreign",
        message = "dap.adapters.dart is registered by another plugin; auto-run uses it as is, "
          .. "so debugged tests may not report results" }
    end
  end
  return issues
end

---Test-only: drop the package-kind cache.
function M._reset_for_tests()
  _kind_cache = {}
end

return M
