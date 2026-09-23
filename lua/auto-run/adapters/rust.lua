---auto-run.adapters.rust — the Rust (Cargo/libtest) test adapter (ADR-0048 §7,
---ADR 0194 Phase 1b).
---
---Discovery: treesitter over `.rs` files — functions carrying a `#[test]`-family
---attribute (`#[test]`, `#[tokio::test]`, `#[rstest]`, …), nested under their
---enclosing `mod` items. Interface-inspired by the Go adapter; implementation
---original.
---
---Roots: nearest enclosing `Cargo.toml`, promoted to the enclosing WORKSPACE
---`Cargo.toml` (the one whose manifest declares `[workspace]`) — the Cargo
---analogue of go.mod → go.work. Memoized per dir.
---
---Runs: `cargo test <selectors> [<TESTNAME>] -- --exact --format pretty
-----color never`. Selectors carry the file's Cargo package + target identity
---(`-p <pkg>` plus `--lib` / `--bin <name>` / `--test <name>`); the positional
---TESTNAME is the test's crate-internal module path. Rust has no stable machine
---test output (libtest JSON is nightly), so `results()` is a VERSIONED PARSER
---over libtest's stable pretty output, scoped to the spec's target identity, and
---returns a structured error (never a silent skip) when a run is ambiguous.
---
---Supported Phase-1 targets (ADR 0194 §2.3.2): lib/unit, binary-target unit
---(`src/main.rs`, `src/bin/*.rs`), and `tests/*.rs` integration. Doctests,
---examples, benches, custom harnesses, and generated tests are out of scope.
---@module 'auto-run.adapters.rust'

local fs_path = require("auto-core.fs.path")

local M = {}

M.name = "rust"

-- ── root detection (crate + workspace, memoized) ────────────────

---dir → workspace/crate root (false = negative cache).
---@type table<string, string|false>
local _root_cache = {}
---crate dir → `[package] name` (false = unparsable / virtual manifest).
---@type table<string, string|false>
local _pkg_cache = {}
---crate dir → true when its Cargo.toml has `src/lib.rs` (memoized).
---@type table<string, boolean|nil>
local _has_lib_cache = {}

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

---Read a Cargo.toml manifest's raw text once. `nil` when unreadable.
---@param crate_dir string
---@return string?
local function read_manifest(crate_dir)
  local f = io.open(fs_path.join(crate_dir, "Cargo.toml"), "r")
  if not f then return nil end
  local src = f:read("*a")
  f:close()
  return src
end

---Nearest enclosing dir carrying a `Cargo.toml`.
---@param dir string
---@return string?
function M.crate_dir(dir)
  return walk_up_for(dir, "Cargo.toml")
end

---Does a manifest text declare `[workspace]`? (TOML section header at BOL.)
---@param manifest string
---@return boolean
local function declares_workspace(manifest)
  return manifest:match("\n%s*%[workspace%]") ~= nil
    or manifest:match("^%s*%[workspace%]") ~= nil
end

---Project root for `dir`: the enclosing WORKSPACE Cargo.toml dir when one
---exists at/above the nearest crate, else that crate dir. Memoized — the
---primary-root cache for workspace layouts.
---@param dir string
---@return string?
function M.root(dir)
  if type(dir) ~= "string" or dir == "" then return nil end
  dir = fs_path.normalize(dir)
  local cached = _root_cache[dir]
  if cached ~= nil then return cached or nil end

  local crate = M.crate_dir(dir)
  local root = nil
  if crate then
    -- Walk up from the crate (inclusive) for a manifest with [workspace].
    local cur = crate
    while cur and cur ~= "" do
      local mani = read_manifest(cur)
      if mani and declares_workspace(mani) then
        root = cur
        break
      end
      local parent = fs_path.parent(cur)
      if parent == cur or parent == "" then break end
      cur = M.crate_dir(parent)  -- jump to the next Cargo.toml above, not every dir
    end
    root = root or crate
  end
  _root_cache[dir] = root or false
  return root
end

---`[package] name` from a crate dir's Cargo.toml. Memoized. `nil` for a virtual
---workspace manifest (no `[package]`).
---@param crate_dir string
---@return string?
local function package_name(crate_dir)
  local cached = _pkg_cache[crate_dir]
  if cached ~= nil then return cached or nil end
  local out = nil
  local mani = read_manifest(crate_dir)
  if mani then
    -- `[package]` … `name = "..."` — the first name after the package header.
    local pkg_section = mani:match("%[package%](.-)\n%[") or mani:match("%[package%](.*)$")
    if pkg_section then
      out = pkg_section:match('name%s*=%s*"([^"]+)"')
    end
  end
  _pkg_cache[crate_dir] = out or false
  return out
end

---Does the crate at `crate_dir` have a library target (src/lib.rs)? Memoized.
---@param crate_dir string
---@return boolean
local function crate_has_lib(crate_dir)
  local cached = _has_lib_cache[crate_dir]
  if cached ~= nil then return cached end
  local has = fs_path.exists(fs_path.join(crate_dir, "src", "lib.rs"))
  _has_lib_cache[crate_dir] = has
  return has
end

-- ── Cargo package/target identity for a file (ADR 0194 §2.3.2) ──

---@class RustTargetIdentity
---@field package string?      the crate's `[package] name`
---@field crate_dir string     the crate's Cargo.toml dir
---@field kind "lib"|"bin"|"test"
---@field target string        target name (bin/integration name, or the package for lib/main-bin)
---@field selectors string[]   cargo selectors: { "-p", pkg, "--lib" | "--bin", name | "--test", name }
---@field module_prefix string crate-internal module path of the FILE ("" at a crate root), `::`-joined

---Resolve the Cargo target identity for a `.rs` file, from its path within the
---crate. Covers the supported Phase-1 target set; returns nil for a file that
---is not inside a `src/` or `tests/` tree of a crate.
---@param path string
---@return RustTargetIdentity?
function M.identity(path)
  path = fs_path.normalize(path)
  local crate = M.crate_dir(fs_path.parent(path))
  if not crate then return nil end
  local pkg = package_name(crate)
  local rel = path:sub(#crate + 2)  -- path relative to the crate dir

  -- Strip a trailing "/mod.rs" or ".rs" and turn "/" into "::" to build a
  -- crate-internal module prefix from a src-relative path.
  local function module_from(relpath)
    local p = relpath:gsub("%.rs$", "")
    p = p:gsub("/mod$", "")
    if p == "" then return "" end
    return (p:gsub("/", "::"))
  end

  local selectors = {}
  if pkg then selectors[#selectors + 1] = "-p"; selectors[#selectors + 1] = pkg end

  -- tests/<...>.rs → an integration target named after the FIRST path segment.
  local test_rel = rel:match("^tests/(.+)$")
  if test_rel then
    local name = test_rel:match("^([^/]+)"):gsub("%.rs$", "")
    selectors[#selectors + 1] = "--test"
    selectors[#selectors + 1] = name
    -- The integration file IS its target's crate root → empty prefix for that
    -- file; a submodule under tests/<name>/ keeps its sub-path as the prefix.
    local sub = test_rel:match("^[^/]+/(.+)$")
    return {
      package = pkg, crate_dir = crate, kind = "test", target = name,
      selectors = selectors, module_prefix = sub and module_from(sub) or "",
    }
  end

  -- src/bin/<name>.rs → a bin target named <name>.
  local bin_name = rel:match("^src/bin/([^/]+)%.rs$")
  if bin_name then
    selectors[#selectors + 1] = "--bin"
    selectors[#selectors + 1] = bin_name
    return {
      package = pkg, crate_dir = crate, kind = "bin", target = bin_name,
      selectors = selectors, module_prefix = "",
    }
  end

  -- src/main.rs → the crate's default bin (named after the package).
  if rel == "src/main.rs" then
    if pkg then selectors[#selectors + 1] = "--bin"; selectors[#selectors + 1] = pkg end
    return {
      package = pkg, crate_dir = crate, kind = "bin", target = pkg or "",
      selectors = selectors, module_prefix = "",
    }
  end

  -- Anything else under src/ → the lib target when the crate has one, else the
  -- default bin. The module prefix is the file's path under src/.
  local src_rel = rel:match("^src/(.+)$")
  if src_rel then
    local prefix = module_from(src_rel == "lib.rs" and "" or src_rel)
    if crate_has_lib(crate) then
      selectors[#selectors + 1] = "--lib"
      return {
        package = pkg, crate_dir = crate, kind = "lib", target = pkg or "",
        selectors = selectors, module_prefix = prefix,
      }
    end
    if pkg then selectors[#selectors + 1] = "--bin"; selectors[#selectors + 1] = pkg end
    return {
      package = pkg, crate_dir = crate, kind = "bin", target = pkg or "",
      selectors = selectors, module_prefix = prefix,
    }
  end

  return nil
end

-- ── walk filter + file recognition ──────────────────────────────

---@param name string
---@return boolean descend
function M.filter_dir(name, _rel_path, _root)
  -- Prune Cargo's build dir + vendored crates, and — because the scan keeps a
  -- dir when ANY adapter accepts it — the common cross-ecosystem noise the
  -- other adapters prune too (else an accepting rust re-includes node_modules).
  return name ~= "target" and name ~= "vendor" and name ~= "node_modules"
end

---@param path string
---@return boolean
function M.is_test_file(path)
  if type(path) ~= "string" or path:match("%.rs$") == nil then return false end
  -- Only files that resolve to a supported target are ours; build scripts and
  -- files outside src/|tests/ are not test material.
  return M.identity(path) ~= nil
end

-- ── discovery (treesitter, injections disabled) ─────────────────

-- Functions and modules; the #[test]-family attribute is detected in Lua from
-- each function's preceding `attribute_item` siblings (attributes are siblings
-- of the function_item in tree-sitter-rust, not children, so a pure query
-- cannot bind "function with a #[test] attribute").
local QUERY_SRC = [[
  (function_item name: (identifier) @fn_name) @fn_def
  (mod_item name: (identifier) @mod_name) @mod_def
]]

---@type vim.treesitter.Query?
local _query = nil
local function get_query()
  if _query == nil then
    _query = vim.treesitter.query.parse("rust", QUERY_SRC)
  end
  return _query
end

---Does a function node carry a `#[test]`-family attribute on a preceding
---sibling? Matches `#[test]`, `#[tokio::test]`, `#[rstest]`, `#[test_case(...)]`,
---etc. — any attribute whose leaf path ends in `test`.
---@param fn_node TSNode
---@param source string
---@return boolean
local function has_test_attr(fn_node, source)
  local sib = fn_node:prev_sibling()
  while sib and sib:type() == "attribute_item" do
    local text = vim.treesitter.get_node_text(sib, source)
    -- The attribute's identifier path — e.g. `test`, `tokio::test`, `rstest`.
    -- Match a word `test` at an attribute-path boundary.
    if text:match("%f[%w]test%f[^%w]") then
      return true
    end
    sib = sib:prev_sibling()
  end
  return false
end

---The `mod` names enclosing a node, outermost-first (crate-internal module path
---WITHIN the file).
---@param node TSNode
---@param source string
---@return string[]
local function enclosing_mods(node, source)
  local mods = {}
  local cur = node:parent()
  while cur do
    if cur:type() == "mod_item" then
      local name_node = cur:field("name")[1]
      if name_node then
        table.insert(mods, 1, vim.treesitter.get_node_text(name_node, source))
      end
    end
    cur = cur:parent()
  end
  return mods
end

---Parse one `.rs` file into a file position with nested namespace(mod)/test
---children. `(pos, nil)` / `(nil, err)` on parse failure / `(nil, nil)` when the
---file holds no test functions.
---@param path string
---@return AutoRunPosition? file_pos, string? err
function M.discover_positions(path)
  local f, oerr = io.open(path, "r")
  if not f then return nil, "open: " .. tostring(oerr) end
  local source = f:read("*a")
  f:close()

  local okq, query = pcall(get_query)
  if not okq then return nil, "rust query: " .. tostring(query) end
  local okp, parser = pcall(vim.treesitter.get_string_parser, source, "rust",
    { injections = { rust = "" } })
  if not okp then return nil, "rust parser: " .. tostring(parser) end
  local trees = parser:parse()
  if not trees or not trees[1] then return nil, "rust parse produced no tree" end
  local ts_root = trees[1]:root()

  -- Collect test functions with their enclosing-mod path.
  ---@type { name: string, mods: string[], srow: integer, erow: integer }[]
  local tests = {}
  for _, match in query:iter_matches(ts_root, source, 0, -1) do
    local name_node, def_node, is_fn
    for id, nodes in pairs(match) do
      local cap = query.captures[id]
      local node = nodes[#nodes]
      if cap == "fn_name" then name_node = node; is_fn = true end
      if cap == "fn_def" then def_node = node end
      if cap == "mod_name" then name_node = node end
      if cap == "mod_def" then def_node = node end
    end
    if is_fn and name_node and def_node and has_test_attr(def_node, source) then
      local srow = def_node:start()
      local erow = def_node:end_()
      tests[#tests + 1] = {
        name = vim.treesitter.get_node_text(name_node, source),
        mods = enclosing_mods(def_node, source),
        srow = srow + 1, erow = erow + 1,
      }
    end
  end
  if #tests == 0 then return nil, nil end

  -- Build a namespace tree: file → mod → … → test. Namespaces are keyed by
  -- their full mod-path so sibling tests in the same mod share one node.
  local file_pos = {
    type = "file", name = fs_path.basename(path), path = path, children = {},
  }
  local ns_index = {}  -- "mod1::mod2" → namespace position
  local function ns_for(mods)
    if #mods == 0 then return file_pos end
    local key = table.concat(mods, "::")
    if ns_index[key] then return ns_index[key] end
    -- Ensure the parent chain exists, then attach this namespace under it.
    local parent = ns_for({ unpack(mods, 1, #mods - 1) })
    local pos = { type = "namespace", name = mods[#mods], path = path, children = {} }
    parent.children[#parent.children + 1] = pos
    ns_index[key] = pos
    return pos
  end

  for _, t in ipairs(tests) do
    local parent = ns_for(t.mods)
    parent.children[#parent.children + 1] = {
      type = "test", name = t.name, path = path, lnum = t.srow, end_lnum = t.erow,
    }
  end
  return file_pos, nil
end

-- ── run-name mapping (position id → libtest reported path) ──────

---Test-name segments of a position id: everything after the `path` head
---(`path::modA::modB::test_name` → { modA, modB, test_name }).
---@param pos AutoRunPosition
---@return string[]
local function id_segments(pos)
  local rest = pos.id:sub(#pos.path + 3)  -- skip "path::"
  return vim.split(rest, "::", { plain = true })
end

---The full crate-internal path libtest reports for a position:
---`<file module prefix>::<in-file mods>::<fn>`. `module_prefix` comes from the
---file's location in its target; the id segments are the in-file mod path + fn.
---@param pos AutoRunPosition
---@param identity RustTargetIdentity
---@return string
local function reported_path(pos, identity)
  local parts = {}
  if identity.module_prefix ~= "" then
    for _, seg in ipairs(vim.split(identity.module_prefix, "::", { plain = true })) do
      parts[#parts + 1] = seg
    end
  end
  for _, seg in ipairs(id_segments(pos)) do parts[#parts + 1] = seg end
  return table.concat(parts, "::")
end

-- ── build_spec ──────────────────────────────────────────────────

---Collect the reported paths for every `test` position under `scope`, and the
---identity that governs the run (all positions in one build_spec share a file,
---hence a target).
---@param scope AutoRunPosition
---@param identity RustTargetIdentity
---@return string[] names, table<string,string> reported_to_id
local function scope_reported(scope, identity)
  local names, map = {}, {}
  local function visit(pos)
    if pos.type == "test" then
      local rp = reported_path(pos, identity)
      names[#names + 1] = rp
      map[rp] = pos.id
    end
    for _, child in ipairs(pos.children or {}) do visit(child) end
  end
  visit(scope)
  return names, map
end

---Effective `kind=test` config (env only — Cargo has no build_flags analogue we
---thread here). `(nil, nil)` when the repo has none; `(nil, err)` on failure.
---@return { env: table<string,string>? }? applied, string? err
local function test_config()
  local applied, err = require("auto-run.adapters.config").test_config(M.name)
  if not applied then return nil, err end
  return { env = applied.env }, nil
end

---@param args AutoRunSpecArgs
---@return AutoRunSpec? spec, string? err
function M.build_spec(args)
  local pos, root = args.position, args.root
  local file = pos.path
  local identity = M.identity(file)
  if not identity then
    return nil, "rust adapter: no Cargo target for " .. tostring(file)
  end
  local applied, cfg_err = test_config()
  if cfg_err then return nil, cfg_err end

  local argv = { "cargo", "test" }
  for _, s in ipairs(identity.selectors) do argv[#argv + 1] = s end

  local reported, _ = scope_reported(pos, identity)

  if pos.type == "test" then
    -- Exactly one test: its reported path as the positional filter + --exact.
    argv[#argv + 1] = reported[1]
    argv[#argv + 1] = "--"
    argv[#argv + 1] = "--exact"
  elseif pos.type == "file" or pos.type == "namespace" then
    if #reported == 0 then return nil, nil end  -- nothing runnable → decompose
    -- No positional filter: run the whole target and reconcile by identity in
    -- results(). (A per-name alternation is not expressible to libtest.)
    argv[#argv + 1] = "--"
  elseif pos.type == "dir" then
    argv[#argv + 1] = "--"
  else
    return nil, "rust adapter cannot run a '" .. tostring(pos.type) .. "' position"
  end

  -- Pinned, stable, parseable output (ADR 0194 §2.5). --color never at the
  -- libtest layer (after --); default pretty format; NO --nocapture on the
  -- results run so program stdout can't interleave with harness summary lines.
  argv[#argv + 1] = "--format"
  argv[#argv + 1] = "pretty"
  argv[#argv + 1] = "--color"
  argv[#argv + 1] = "never"

  return {
    cmd = argv,
    cwd = identity.crate_dir ~= "" and identity.crate_dir or root,
    env = applied and applied.env or nil,
    context = {
      position_id = pos.id,
      target = identity.kind .. ":" .. (identity.target or ""),
      package = identity.package,
    },
  }, nil
end

-- ── results (libtest pretty stream → position ids) ──────────────

---Parse the per-run stdout file (libtest's pretty output) into results keyed by
---position id, scoped to the spec's target. Returns `(map, err?)` — a structured
---error (ADR 0194 §2.3.4) when the run is ambiguous, never a silent skip.
---@param spec AutoRunSpec
---@param exit { code: integer?, signal: integer?, stdout_file: string, run_dir: string }
---@param tree table
---@return table<string, AutoRunResult> map, AutoRunError? err
function M.results(spec, exit, tree)
  local scope = tree:get(spec.context.position_id)
  if not scope then return {} end
  local identity = M.identity(scope.path)
  if not identity then
    return {}, { code = "no_target", message = "no Cargo target for " .. tostring(scope.path) }
  end
  local _, reported_to_id = scope_reported(scope, identity)

  local f = io.open(exit.stdout_file, "r")
  if not f then
    return {}, { code = "no_output", message = "results: run produced no stdout file" }
  end

  -- libtest pretty lines: `test <path> ... ok` / `... FAILED` / `... ignored`.
  local results = {}
  local seen_reported = {}
  for line in f:lines() do
    local name, status = line:match("^test%s+(%S+)%s+%.%.%.%s+(%w+)")
    if name and status then
      seen_reported[name] = true
      local id = reported_to_id[name]
      if id then
        local st = status == "ok" and "passed"
          or (status == "FAILED" or status == "failed") and "failed"
          or (status == "ignored") and "skipped"
          or nil
        if st then results[id] = { status = st } end
      end
    end
  end
  f:close()

  -- Ambiguity guard (ADR 0194 §2.3.2 / §2.3.4): for an --exact single-test run,
  -- exactly one reported line must match the requested test. Zero or many means
  -- the target/name did not resolve to one test — a structured failure, not a
  -- silent skip.
  if scope.type == "test" then
    local want = next(reported_to_id)
    local n = 0
    for r in pairs(seen_reported) do if r == want then n = n + 1 end end
    if n ~= 1 then
      return results, {
        code = "ambiguous_test",
        message = ("cargo test matched %d harness lines for '%s' (expected exactly 1)")
          :format(n, tostring(want)),
        detail = { target = spec.context.target },
      }
    end
  end
  return results, nil
end

---Reconstruct the human/terminal output of a run from its libtest stdout.
---@param exit { stdout_file: string }
---@return string
function M.output(exit)
  local f = exit and exit.stdout_file and io.open(exit.stdout_file, "r")
  if not f then return "" end
  local text = f:read("*a")
  f:close()
  return text or ""
end

-- ── scaffold + generic-run capabilities (ADR 0194 §2.3.4) ───────

---Scaffold defaults for a new Rust config (`<leader>rc`). `kind=test` targets
---the crate; `run`/`debug` name the default binary program token.
---@param kind "run"|"test"|"debug"
---@param _name string?
---@return table
function M.default_config(kind, _name)
  return { runtime = "rust", kind = kind, program = "${worktree}" }
end

---argv for the run/term strategy (NEVER a DAP launch — that is prepare_debug*).
---A `kind=test` config runs the crate's tests; otherwise `cargo run`.
---@param eff table
---@param _opts table?
---@return string[]? argv, string? err
function M.build_run_argv(eff, _opts)
  -- Base command only; the caller (exec.build_argv / command_line) appends the
  -- config's args, same as it does for every runtime.
  if eff.kind == "test" then
    return { "cargo", "test" }, nil
  end
  return { "cargo", "run" }, nil
end

-- ── debug capabilities (async: cargo build → artifact → codelldb) ─

---@class AutoRunDebugLaunch
---@field dap_type string             nvim-dap adapter key (→ dap.adapters[dap_type])
---@field request "launch"|"attach"
---@field program string             absolute path to the built executable
---@field args string[]?
---@field cwd string?
---@field env table<string,string>?

---@class AutoRunError
---@field code string
---@field message string
---@field detail table?

---Build via `cargo <sub> --message-format=json <selectors>` and select the ONE
---executable matching `identity.target` (and, for tests, `profile.test`). Async
---(vim.system). The callback fires EXACTLY ONCE (Lector r4 caution #2); a
---cancel through `opts.is_cancelled()` or `opts.abort()` drops a late build and
---never launches. `want_test` picks the test harness binary vs the plain bin.
---@param sub "test"|"build"
---@param want_test boolean
---@param identity RustTargetIdentity
---@param cwd string
---@param opts table
---@param cb fun(exe: string|nil, err: AutoRunError|nil)
local function cargo_build_exe(sub, want_test, identity, cwd, opts, cb)
  local done = false
  local function finish(exe, err)
    if done then return end
    done = true
    cb(exe, err)
  end

  local cmd = { "cargo", sub, "--no-run", "--message-format=json" }
  if sub == "build" then cmd = { "cargo", "build", "--message-format=json" } end
  for _, s in ipairs(identity.selectors) do cmd[#cmd + 1] = s end

  local ok, handle = pcall(vim.system, cmd, { cwd = cwd, text = true }, function(res)
    if type(opts.is_cancelled) == "function" and opts.is_cancelled() then
      return finish(nil, { code = "cancelled", message = "debug build cancelled" })
    end
    if res.code ~= 0 then
      return finish(nil, {
        code = "build_failed",
        message = "cargo " .. sub .. " failed (exit " .. tostring(res.code) .. ")",
        detail = { stderr = (res.stderr or ""):sub(1, 2000) },
      })
    end
    local exes = {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      local okj, m = pcall(vim.json.decode, line)
      if okj and type(m) == "table" and m.reason == "compiler-artifact" and m.executable then
        local t = m.target or {}
        local is_test = (m.profile or {}).test == true
        local target_matches = (identity.target == nil or identity.target == ""
          or t.name == identity.target)
        if want_test == is_test and target_matches then
          exes[#exes + 1] = m.executable
        end
      end
    end
    if #exes == 0 then
      return finish(nil, {
        code = "ambiguous_artifact",
        message = "no " .. (want_test and "test " or "") .. "executable for target '"
          .. tostring(identity.target) .. "'",
      })
    end
    if #exes > 1 then
      return finish(nil, {
        code = "ambiguous_artifact",
        message = ("%d executables matched target '%s' (expected exactly 1)")
          :format(#exes, tostring(identity.target)),
        detail = { executables = exes },
      })
    end
    finish(exes[1], nil)
  end)
  if not ok then
    return finish(nil, { code = "spawn_failed", message = "cargo: " .. tostring(handle) })
  end
  -- The adapter owns the build job; install an abort the core can call.
  opts.abort = function() pcall(function() handle:kill(15) end) end
end

---Prepare a launch-ready DAP config for a discovered TEST position: build the
---test binary, select the identity-matched artifact, and target the one test
---with `--exact`. Baseline = Cargo prebuild (ADR 0194 §2.3.4); an explicit
---`program` on `opts.eff` is an override that skips the build.
---@param pos AutoRunPosition
---@param opts table
---@param cb fun(launch: AutoRunDebugLaunch|nil, err: AutoRunError|nil)
function M.prepare_debug(pos, opts, cb)
  opts = opts or {}
  local identity = M.identity(pos.path)
  if not identity then
    return cb(nil, { code = "no_target", message = "no Cargo target for " .. tostring(pos.path) })
  end
  local reported = reported_path(pos, identity)
  local applied = select(1, test_config())
  cargo_build_exe("test", true, identity, identity.crate_dir, opts, function(exe, err)
    if err then return cb(nil, err) end
    cb({
      dap_type = "rust",
      request = "launch",
      program = exe,
      args = { "--exact", reported, "--nocapture" },
      cwd = identity.crate_dir,
      env = applied and applied.env or nil,
    }, nil)
  end)
end

---Prepare a launch-ready DAP config for an effective `kind=debug` config
---(ordinary debug, ADR 0194 §2.3.4 r4). Baseline = `cargo build` the config's
---bin target → identity-matched artifact → codelldb; an explicit `program`
---(already a built executable) is the override and skips the build.
---@param eff table
---@param opts table
---@param cb fun(launch: AutoRunDebugLaunch|nil, err: AutoRunError|nil)
function M.prepare_debug_config(eff, opts, cb)
  opts = opts or {}
  -- Override: an explicit, already-built executable path.
  if type(eff.program) == "string" and eff.program:match("/") and eff.kind ~= "test"
      and vim.fn.filereadable(eff.program) == 1 then
    return cb({
      dap_type = "rust", request = "launch", program = eff.program,
      args = eff.args, cwd = eff.cwd, env = eff.env,
    }, nil)
  end
  -- Baseline: build the crate's bin at cwd (or a named bin) and launch it.
  local cwd = (type(eff.cwd) == "string" and eff.cwd ~= "") and eff.cwd or nil
  local crate = M.crate_dir(cwd or vim.uv.cwd())
  if not crate then
    return cb(nil, { code = "no_target", message = "no Cargo crate for the debug config's cwd" })
  end
  local pkg = package_name(crate)
  local bin = eff.cargo_bin or pkg
  local identity = {
    package = pkg, crate_dir = crate, kind = "bin", target = bin,
    selectors = pkg and (bin == pkg and { "-p", pkg, "--bin", pkg }
      or { "-p", pkg, "--bin", bin }) or {},
    module_prefix = "",
  }
  cargo_build_exe("build", false, identity, crate, opts, function(exe, err)
    if err then return cb(nil, err) end
    cb({
      dap_type = "rust", request = "launch", program = exe,
      args = eff.args, cwd = crate, env = eff.env,
    }, nil)
  end)
end

---Test-only: drop the memoized caches.
function M._reset_for_tests()
  _root_cache, _pkg_cache, _has_lib_cache = {}, {}, {}
end

return M
