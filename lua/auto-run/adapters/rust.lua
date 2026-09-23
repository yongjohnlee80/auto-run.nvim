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
---workspace root → parsed `cargo metadata --no-deps` (false = cargo absent /
---unreadable). Populated lazily on the first identity lookup per root.
---@type table<string, table|false>
local _meta_cache = {}

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

-- ── Cargo metadata (the authoritative identity source, ADR 0194 §2.3.2) ──

---Load + cache `cargo metadata --no-deps --format-version 1` for a workspace
---root. Synchronous, but called only from build_spec/results/debug — NEVER the
---discovery scan (is_test_file/discover_positions are metadata-free) — and
---memoized per root, so it is one short subprocess per workspace per run.
---`nil` when cargo is absent or the manifest cannot be read.
---@param root string
---@return table? meta
local function cargo_metadata(root)
  local cached = _meta_cache[root]
  if cached ~= nil then return cached or nil end
  local meta = nil
  local ok, res = pcall(function()
    return vim
      .system({ "cargo", "metadata", "--no-deps", "--format-version", "1" },
        { cwd = root, text = true })
      :wait()
  end)
  if ok and res and res.code == 0 and type(res.stdout) == "string" and res.stdout ~= "" then
    local okj, decoded = pcall(vim.json.decode, res.stdout)
    if okj and type(decoded) == "table" then meta = decoded end
  end
  _meta_cache[root] = meta or false
  return meta
end

---The metadata package whose manifest dir is exactly `crate_dir`, or nil.
---@param crate_dir string
---@return table? pkg
local function package_at(crate_dir)
  crate_dir = fs_path.normalize(crate_dir)
  local meta = cargo_metadata(M.root(crate_dir) or crate_dir)
  if not meta then return nil end
  for _, p in ipairs(meta.packages or {}) do
    if fs_path.parent(fs_path.normalize(p.manifest_path)) == crate_dir then return p end
  end
  return nil
end

---`::`-join a src-relative path into a crate-internal module prefix.
---@param relpath string?
---@return string
local function module_from(relpath)
  local p = (relpath or ""):gsub("%.rs$", ""):gsub("/mod$", "")
  if p == "" or p == "lib" or p == "main" then return "" end
  return (p:gsub("/", "::"))
end

-- ── Cargo package/target identity for a file (ADR 0194 §2.3.2) ──

---@class RustTargetIdentity
---@field package string        owning package name
---@field package_id string      metadata package id (disambiguates same-named targets across packages)
---@field crate_dir string       the package's Cargo.toml dir
---@field kind "lib"|"bin"|"test"
---@field target string          metadata target name (renamed [lib], explicit [[bin]] respected)
---@field selectors string[]     cargo selectors: { "-p", pkg, "--lib" | "--bin"|"--test", name }
---@field module_prefix string   crate-internal module path of the FILE ("" at a target root)

---Resolve the Cargo package/target identity for a `.rs` file from cached
---`cargo metadata` (authoritative package id / target name / kind) plus the
---file's location within the target. `nil` outside a package's `src/`|`tests/`
---tree, for an out-of-scope target kind (example/bench/…), or when cargo is
---unavailable.
---@param path string
---@return RustTargetIdentity?
function M.identity(path)
  path = fs_path.normalize(path)
  local root = M.root(fs_path.parent(path))
  if not root then return nil end
  local meta = cargo_metadata(root)
  if not meta then return nil end

  -- The package whose manifest dir is the NEAREST ancestor of `path`.
  local pkg, pkg_dir, best = nil, nil, -1
  for _, p in ipairs(meta.packages or {}) do
    local pdir = fs_path.parent(fs_path.normalize(p.manifest_path))
    if (path .. "/"):sub(1, #pdir + 1) == pdir .. "/" and #pdir > best then
      pkg, pkg_dir, best = p, pdir, #pdir
    end
  end
  if not pkg then return nil end
  local rel = path:sub(#pkg_dir + 2)

  local function first_of_kind(kind)
    for _, t in ipairs(pkg.targets or {}) do
      for _, k in ipairs(t.kind) do
        if k == kind then return t end
      end
    end
  end

  -- Bind the file to a metadata target: an entry file matches a target's
  -- `src_path` exactly; a submodule belongs to its enclosing target.
  local t, prefix
  for _, tt in ipairs(pkg.targets or {}) do
    if fs_path.normalize(tt.src_path) == path then t, prefix = tt, "" break end
  end
  if not t then
    local test_top = rel:match("^tests/([^/]+)/")
    if test_top then
      for _, tt in ipairs(pkg.targets or {}) do
        for _, k in ipairs(tt.kind) do
          if k == "test" and tt.name == test_top then t = tt end
        end
      end
      prefix = module_from(rel:match("^tests/[^/]+/(.+)$"))
    elseif rel:match("^src/") then
      t = first_of_kind("lib") or first_of_kind("bin")
      prefix = module_from(rel:match("^src/(.+)$"))
    end
  end
  if not t then return nil end

  -- Normalize the kind and build selectors from the metadata target.
  local is_lib = false
  for _, k in ipairs(t.kind) do
    if k == "lib" or k == "rlib" or k == "dylib" or k == "proc-macro" then is_lib = true end
  end
  local kind, selectors = nil, { "-p", pkg.name }
  if is_lib then
    kind = "lib"
    selectors[#selectors + 1] = "--lib"
  elseif t.kind[1] == "bin" then
    kind = "bin"
    selectors[#selectors + 1] = "--bin"
    selectors[#selectors + 1] = t.name
  elseif t.kind[1] == "test" then
    kind = "test"
    selectors[#selectors + 1] = "--test"
    selectors[#selectors + 1] = t.name
  else
    return nil -- example / bench / custom-build → out of Phase-1 scope
  end

  return {
    package = pkg.name,
    package_id = pkg.id,
    crate_dir = pkg_dir,
    kind = kind,
    target = t.name,
    selectors = selectors,
    module_prefix = prefix or "",
  }
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
  if type(path) ~= "string" or not path:match("%.rs$") then return false end
  local crate = M.crate_dir(fs_path.parent(path))
  if not crate then return false end
  local rel = fs_path.normalize(path):sub(#fs_path.normalize(crate) + 2)
  -- Under src/ or tests/, excluding the build script. Metadata (M.identity) is
  -- deliberately NOT consulted here: the discovery scan must stay
  -- subprocess-free, so a file whose target is out of scope is filtered later
  -- when discover_positions finds no #[test]s / build_spec resolves no target.
  return rel ~= "build.rs"
    and (rel:match("^src/") ~= nil or rel:match("^tests/") ~= nil)
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

-- Attribute-PATH terminals that mark a test function. Gate on the path (before
-- any `(args)`), so `#[cfg(test)]` — whose path is `cfg`, with `test` only an
-- ARGUMENT — is correctly NOT treated as a test.
local TEST_ATTR_TERMINALS = { test = true, rstest = true, test_case = true }

---Does a function node carry a `#[test]`-family attribute on a preceding
---sibling? Matches `#[test]`, `#[tokio::test]`, `#[async_std::test]`,
---`#[rstest]`, `#[test_case(...)]` — by the attribute PATH's terminal segment.
---Excludes `#[cfg(test)]` (a false positive under naive text search) and
---`#[ignore]` (but an `#[ignore]` test still has its `#[test]` sibling).
---@param fn_node TSNode
---@param source string
---@return boolean
local function has_test_attr(fn_node, source)
  local sib = fn_node:prev_sibling()
  while sib and sib:type() == "attribute_item" do
    local text = vim.treesitter.get_node_text(sib, source)
    -- `#[<path>(<args>)]` (or inner attribute `#![…]`) → the path only.
    local inner = text:match("^#!?%[%s*(.-)%s*%]$") or text
    local path = inner:match("^[%w_:]+") or ""
    local terminal = path:match("([%w_]+)$")
    if terminal and TEST_ATTR_TERMINALS[terminal] then
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
  local pos = args.position

  -- A directory / root scope has no single Cargo target — return (nil, nil) so
  -- the discovery core DECOMPOSES to files rather than aborting on an error
  -- (P1-2). identity() must not run first for a directory path.
  if pos.type == "dir" then return nil, nil end

  local identity = M.identity(pos.path)
  if not identity then
    return nil, "rust adapter: no Cargo target for " .. tostring(pos.path)
  end
  local applied, cfg_err = test_config()
  if cfg_err then return nil, cfg_err end

  local reported = scope_reported(pos, identity)

  local argv = { "cargo", "test" }
  for _, s in ipairs(identity.selectors) do argv[#argv + 1] = s end

  if pos.type == "test" then
    -- Exactly one test: its full crate-internal path + --exact.
    argv[#argv + 1] = reported[1]
    argv[#argv + 1] = "--"
    argv[#argv + 1] = "--exact"
  elseif pos.type == "file" or pos.type == "namespace" then
    if #reported == 0 then return nil, nil end -- no tests here → decompose
    -- Narrow the run to the selected module with libtest's positional prefix
    -- (the file's module_prefix + a namespace's in-file mod path). libtest's
    -- positional is a SUBSTRING match, so results are still reconciled
    -- precisely by target identity in results(). A crate-root file with no
    -- prefix (e.g. src/lib.rs) has no narrowing token — return (nil, nil) so
    -- the core decomposes to per-test --exact runs and unrelated tests in the
    -- same target never execute (P1-2).
    local segs = {}
    if identity.module_prefix ~= "" then
      for _, s in ipairs(vim.split(identity.module_prefix, "::", { plain = true })) do
        segs[#segs + 1] = s
      end
    end
    local rest = pos.id:sub(#pos.path + 1) -- "" for a file, "::mod…" for a namespace
    if rest:sub(1, 2) == "::" then
      for _, s in ipairs(vim.split(rest:sub(3), "::", { plain = true })) do
        if s ~= "" then segs[#segs + 1] = s end
      end
    end
    if #segs == 0 then return nil, nil end
    -- Trailing `::` is LOAD-BEARING: libtest's positional is a SUBSTRING match,
    -- so a bare `util` also runs `util_extra::*`. The `util::` boundary matches
    -- only the requested module (ADR §2.3.2; proven by the util_extra cell).
    argv[#argv + 1] = table.concat(segs, "::") .. "::"
    argv[#argv + 1] = "--"
  else
    return nil, "rust adapter cannot run a '" .. tostring(pos.type) .. "' position"
  end

  -- Pinned, stable, parseable output (ADR 0194 §2.5): default pretty format,
  -- --color never at the libtest layer (after --), and NO --nocapture on the
  -- results run so program stdout can't interleave with harness summary lines.
  argv[#argv + 1] = "--format"
  argv[#argv + 1] = "pretty"
  argv[#argv + 1] = "--color"
  argv[#argv + 1] = "never"

  return {
    cmd = argv,
    cwd = identity.crate_dir,
    env = applied and applied.env or nil,
    context = {
      position_id = pos.id,
      package_id = identity.package_id,
      target = identity.kind .. ":" .. identity.target,
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
  -- Count matching LINES per reported name (not a unique-name set), so two
  -- harness lines with the same name are detectable (P2).
  local results = {}
  local line_count = {}
  for line in f:lines() do
    local name, status = line:match("^test%s+(%S+)%s+%.%.%.%s+(%w+)")
    if name and status then
      line_count[name] = (line_count[name] or 0) + 1
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

  -- Ambiguity guard (ADR 0194 §2.3.2 / §2.3.4): an --exact single-test run must
  -- match EXACTLY ONE harness line. Zero or many means the target/name did not
  -- resolve to one test — a structured failure carrying the package/target
  -- identity, never a silent skip.
  if scope.type == "test" then
    local want = next(reported_to_id)
    local n = line_count[want] or 0
    if n ~= 1 then
      return results, {
        code = "ambiguous_test",
        message = ("cargo test matched %d harness lines for '%s' (expected exactly 1)")
          :format(n, tostring(want)),
        detail = { package_id = identity.package_id, target = spec.context.target },
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

---Normalize a metadata target's kind to one of lib|bin|test, or nil.
---@param t table
---@return string?
local function normalized_kind(t)
  for _, k in ipairs(t.kind or {}) do
    if k == "lib" or k == "rlib" or k == "dylib" or k == "proc-macro" then return "lib" end
    if k == "bin" then return "bin" end
    if k == "test" then return "test" end
  end
  return nil
end

---The ONE authoritative Cargo identity for a GENERIC (non-position) config,
---shared by `build_run_argv` and `prepare_debug_config` so run and debug can
---never resolve different workspace members (ADR 0194 §2.3.4).
---
---Metadata-backed and validating:
---  • `cargo_package` SELECTS the metadata package by name — its targets,
---    `default-run` and manifest dir all come from THAT package, rather than
---    being a label pasted onto whatever crate encloses `cwd`. A workspace-root
---    cwd therefore still resolves a named member.
---  • `cargo_target` / `cargo_target_kind` must be COMPLETE, the kind
---    supported, and the target must belong to the resolved package — a typo
---    is a structured error, never a silent degrade to `-p <pkg>`.
---  • With no pinned target: a test config needs none; run/debug take Cargo's
---    own rule (a sole bin, else `default-run`, else refuse).
---@param eff table
---@return { package: string, package_id: string, crate_dir: string, kind: string?, target: string?, selectors: string[] }? id, string? err
local function config_identity(eff)
  local from = (type(eff.cwd) == "string" and eff.cwd ~= "") and eff.cwd or vim.uv.cwd()
  local root = M.root(from) or M.crate_dir(from) or from
  local meta = cargo_metadata(root)
  if not meta then
    return nil, "rust: no Cargo metadata at " .. tostring(root)
  end

  -- 1. The package — a configured name selects the METADATA package.
  local pkg
  if type(eff.cargo_package) == "string" and eff.cargo_package ~= "" then
    for _, p in ipairs(meta.packages or {}) do
      if p.name == eff.cargo_package then pkg = p break end
    end
    if not pkg then
      return nil, ("rust: package '%s' is not a member of the Cargo workspace at %s")
        :format(eff.cargo_package, root)
    end
  else
    local crate = M.crate_dir(from)
    pkg = crate and package_at(crate) or nil
    if not pkg then
      return nil, "rust: cannot resolve a Cargo package for config '"
        .. tostring(eff.name) .. "' — set `cargo_package`"
    end
  end
  local crate_dir = fs_path.parent(fs_path.normalize(pkg.manifest_path))

  local function selectors_for(kind, target)
    local s = { "-p", pkg.name }
    if kind == "lib" then
      s[#s + 1] = "--lib"
    elseif kind == "bin" then
      s[#s + 1] = "--bin"
      s[#s + 1] = target
    elseif kind == "test" then
      s[#s + 1] = "--test"
      s[#s + 1] = target
    end
    return s
  end

  -- 2. A pinned target must be complete, supported, and a member of THIS package.
  local has_t = type(eff.cargo_target) == "string" and eff.cargo_target ~= ""
  local has_k = type(eff.cargo_target_kind) == "string" and eff.cargo_target_kind ~= ""
  if has_t ~= has_k then
    return nil, ("rust: config '%s' half-specifies its Cargo target — set BOTH "
      .. "`cargo_target` and `cargo_target_kind`"):format(tostring(eff.name))
  end
  if has_t then
    local kind = eff.cargo_target_kind
    if kind ~= "lib" and kind ~= "bin" and kind ~= "test" then
      return nil, ("rust: config '%s' has unsupported cargo_target_kind '%s' "
        .. "(expected lib|bin|test)"):format(tostring(eff.name), tostring(kind))
    end
    local found = false
    for _, t in ipairs(pkg.targets or {}) do
      if t.name == eff.cargo_target and normalized_kind(t) == kind then found = true break end
    end
    if not found then
      return nil, ("rust: package '%s' has no %s target named '%s'")
        :format(pkg.name, kind, eff.cargo_target)
    end
    return {
      package = pkg.name, package_id = pkg.id, crate_dir = crate_dir,
      kind = kind, target = eff.cargo_target,
      selectors = selectors_for(kind, eff.cargo_target),
    }, nil
  end

  -- 3. No pinned target.
  if eff.kind == "test" then
    return {
      package = pkg.name, package_id = pkg.id, crate_dir = crate_dir,
      kind = nil, target = nil, selectors = { "-p", pkg.name },
    }, nil
  end
  local bins = {}
  for _, t in ipairs(pkg.targets or {}) do
    if normalized_kind(t) == "bin" then bins[#bins + 1] = t.name end
  end
  local chosen = (#bins == 1 and bins[1])
    or (type(pkg.default_run) == "string" and pkg.default_run ~= "" and pkg.default_run)
    or nil
  if not chosen then
    return nil, ("rust: package '%s' has %d bin targets and no default-run — set "
      .. "`cargo_target` (+ `cargo_target_kind=\"bin\"`) on config '%s'")
      :format(pkg.name, #bins, tostring(eff.name))
  end
  return {
    package = pkg.name, package_id = pkg.id, crate_dir = crate_dir,
    kind = "bin", target = chosen, selectors = selectors_for("bin", chosen),
  }, nil
end

---Scaffold defaults for a new Rust config (`<leader>rc`), carrying Cargo
---identity so the generated config is unambiguous in a workspace.
---@param kind "run"|"test"|"debug"
---@param _name string?
---@return table
function M.default_config(kind, _name)
  local cfg = { runtime = "rust", kind = kind, program = "${worktree}" }
  -- Carry Cargo identity so a scaffolded config is unambiguous in a
  -- multi-package / multi-bin workspace (ADR 0194 §2.3.4).
  local buf = vim.api.nvim_buf_get_name(0)
  local from = (type(buf) == "string" and buf:match("%.rs$")) and fs_path.parent(buf)
    or vim.uv.cwd()
  local pkg = from and M.crate_dir(from) and package_at(M.crate_dir(from)) or nil
  if pkg then
    cfg.cargo_package = pkg.name
    if kind ~= "test" then
      local bins = {}
      for _, t in ipairs(pkg.targets or {}) do
        if t.kind[1] == "bin" then bins[#bins + 1] = t.name end
      end
      -- Same rule as generic_identity: a sole bin or the manifest default-run.
      -- A multi-bin crate is left UNPINNED so the user names the target rather
      -- than inheriting a guess.
      local chosen = (#bins == 1 and bins[1])
        or (type(pkg.default_run) == "string" and pkg.default_run ~= "" and pkg.default_run)
        or nil
      if chosen then
        cfg.cargo_target = chosen
        cfg.cargo_target_kind = "bin"
      end
    end
  end
  return cfg
end

---argv for the run/term strategy (NEVER a DAP launch — that is prepare_debug*).
---A `kind=test` config runs the crate's tests; otherwise `cargo run`.
---@param eff table
---@param _opts table?
---@return string[]? argv, string? err
function M.build_run_argv(eff, _opts)
  -- Base command only; the caller (exec.build_argv / command_line) appends the
  -- config's args. Cargo identity is REQUIRED here: a bare `cargo run`/`cargo
  -- test` is ambiguous in a multi-package / multi-bin workspace, so emit
  -- `-p <pkg>` plus the target selector, and fail structurally when the target
  -- cannot be resolved (ADR 0194 §2.3.4).
  local id, err = config_identity(eff)
  if not id then return nil, err end
  local argv = { "cargo", eff.kind == "test" and "test" or "run" }
  for _, s in ipairs(id.selectors) do argv[#argv + 1] = s end
  return argv, nil
end

-- ── debug capabilities (async: cargo build → artifact → codelldb) ─

-- `AutoRunDebugLaunch` / `AutoRunError` are declared once on the interface, in
-- `auto-run.adapters` (ADR 0194 §2.3.4).

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
  -- Baseline: build via the SAME resolved identity `build_run_argv` uses, so
  -- run and debug can never target different workspace members (Lector r2 P1).
  local id, ierr = config_identity(eff)
  if not id then
    return cb(nil, { code = "no_target", message = ierr })
  end
  if id.kind == "lib" then
    return cb(nil, {
      code = "no_target",
      message = ("rust: config '%s' targets a lib, which produces no executable to debug")
        :format(tostring(eff.name)),
    })
  end
  local identity = {
    package = id.package,
    package_id = id.package_id,
    crate_dir = id.crate_dir,
    kind = id.kind or "bin",
    target = id.target,
    selectors = id.selectors,
    module_prefix = "",
  }
  cargo_build_exe("build", id.kind == "test", identity, id.crate_dir, opts,
    function(exe, err)
      if err then return cb(nil, err) end
      cb({
        dap_type = "rust", request = "launch", program = exe,
        args = eff.args, cwd = id.crate_dir, env = eff.env,
      }, nil)
    end)
end

---Test-only: drop the memoized caches.
function M._reset_for_tests()
  _root_cache, _meta_cache = {}, {}
end

return M
