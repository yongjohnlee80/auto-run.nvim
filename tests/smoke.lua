-- auto-run.nvim — smoke test driver (ADR-0048 Phase 1)
--
-- Run headless:
--   nvim --headless -u NONE -l tests/smoke.lua
--
-- Use `-u NONE -l`, NOT `-u tests/smoke.lua -c 'qa!'`: under `-c 'qa!'`
-- an uncaught throw that aborts the suite mid-run is swallowed and the
-- trailing `qa!` still quits EXIT 0 — a silent, green, partial run. Under
-- `-l` the error propagates and nvim exits 1. (Convention §2/§3.)
--
-- Per [[lua-nvim-plugin-development]] every iteration extends this
-- driver and runs it green before reporting complete. Sections:
--
--   [0] environment
--   [1] setup + topic registration
--   [2] resolver matrix (ADR §2.1 — four distinct fixtures)
--   [3] schema validation
--   [4] merge engine (precedence, tombstones, extends cycles)
--   [5] store CRUD + write-routing + validate
--   [6] substitution tokens
--   [7] env pipeline (trust gate, materialization, sweep)
--   [8] launch.json import + read-through contract
--   [8.5] import — launch-config selection + active-base merge
--   [8.6] discovery.run_output + go.output — terminal-log reconstruction
--   [8.7] detection — .config/.vscode dirs for launch.json + env
--   [8.8] exec.command_line + import.export (launch.json)
--   [9] mailbox verb envelopes (handlers called in-process)
--   [10] exec — job engine end-to-end (§6)
--   [11] exec — strategy resolution + terminal provider probe
--   [12] mailbox — trust-gated exec verbs + ungated run.stop (§11)
--   [13] breakpoints — API persistence (real nvim-dap, §9)
--   [14] breakpoints — reconcile sweep + sync tunables
--   [15] breakpoints — stale-line drop on restore
--   [16] breakpoints — worktree-relative rehydration (two worktrees)
--   [17] :AutoRun Phase 2 subcommands
--   [18] store — corrupt overrides.json is fatal (layer 6 must-fix)
--   [19] exec — term strategy env-file cleanup lifecycle
--   [20] breakpoints — corrupt breakpoints.json diagnostics
--   [21] adapters — registry + AutoRunAdapter interface (§7)
--   [22] discovery — go fixture, position tree, child-repo pruning
--   [23] discovery — scan bounds (caps) + cancelation
--   [24] discovery — per-file mtime cache
--   [25] discovery — open-buffers default + BufWritePost re-parse
--   [26] discovery — go END-TO-END (real `go test -json` runs)
--   [27] adapters — jest fixture, build_spec, stubbed end-to-end
--   [28] mailbox — run.tests_list / run.results / positional test_run
--   [29] :AutoRun tests|scan + doctor adapter diagnostics
--   [30] import — REAL launch.json sample (LabelManager copy)
--   [31] import + debug_test — go-test-env skill shape → dap-go merge
--   [32] exec — pick_config kind filter + per-repo pick memory
--   [33] keymaps — auto-run remap-target surface + gobugger-absent guard (ADR §10)
--   [34] doctor — git/worktree + config rows + `--fix` worktree repair
--   [35] keymaps — rt/rf/dt discovery-position routing + fallback
--   [36] env — §4.2 (r5) selection, candidates, var editing, masking
--   [37] dap failed-start capture — false-positive regression
--
-- Discipline: assert the public contract, never internals; every
-- fixture lives under one tempname-derived root we control (no
-- ancestor-marker leakage); auto-core state persist_dir is isolated
-- BEFORE any setup() runs.

vim.o.columns = 200
vim.o.lines = 60

-- ── runtime setup ────────────────────────────────────────────────
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.rtp:prepend(plugin_root)

-- Sibling deps resolve via :h:h (workspace is two levels up from
-- <plugin>.nvim/<worktree>). Guard with isdirectory + a visible warn.
local workspace = vim.fn.fnamemodify(plugin_root, ":h:h")
local auto_core_root = workspace .. "/auto-core.nvim/main"
if vim.fn.isdirectory(auto_core_root) == 1 then
  vim.opt.rtp:prepend(auto_core_root)
else
  print("WARN: sibling auto-core.nvim/main not found at " .. auto_core_root
    .. " — falling back to whatever is installed")
end

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
-- Real nvim-dap on the rtp for the §9 breakpoint sections — the
-- persistence + reconcile paths run against the actual
-- dap.breakpoints get/set surface, not a stub.
for _, dep in ipairs({ "plenary.nvim", "nvim-dap" }) do
  local p = LAZY .. "/" .. dep
  if vim.fn.isdirectory(p) == 1 then vim.opt.rtp:prepend(p) end
end

-- State isolation FIRST — before ANY setup() claims a namespace
-- ([[auto-family-state-ownership]] rule #7).
require("auto-core.state").configure({
  persist_dir = vim.fn.tempname() .. "_state-isolation",
})

-- Ring-only logging: WARN paths (e.g. the §9 stale-breakpoint drop)
-- must not stripe headless stderr — clean-stderr rule.
require("auto-core.log").configure({ notify = false })

-- ── runner harness ───────────────────────────────────────────────
local pass_count, fail_count = 0, 0

local function ok(name, cond, detail)
  if cond then
    print("  PASS  " .. name)
    pass_count = pass_count + 1
  else
    print("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
    fail_count = fail_count + 1
  end
end

local function contains(list, item)
  for _, x in ipairs(list or {}) do
    if x == item then return true end
  end
  return false
end

-- Fixture root we fully control (no ancestor-marker leakage: its
-- only ancestor above tempname is /tmp itself).
local fx = vim.fn.tempname() .. "-auto-run-fixtures"
vim.fn.mkdir(fx, "p")

-- Git helper — vim.system only, never vim.fn.system.
local function git(cwd, ...)
  local args = { "git", "-C", cwd,
    "-c", "user.email=smoke@test", "-c", "user.name=smoke",
    ... }
  local res = vim.system(args, { text = true }):wait()
  return res.code == 0, res
end

local function make_plain_repo(path)
  vim.fn.mkdir(path, "p")
  local ok1 = git(path, "init", "-q", "-b", "main")
  local ok2 = git(path, "commit", "-q", "--allow-empty", "-m", "init")
  return ok1 and ok2
end

local function write_file(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local worktree = require("auto-core.git.worktree")

-- ── [0] environment ─────────────────────────────────────────────
print("\n[0] environment")
ok("auto-core sibling on rtp", vim.fn.isdirectory(auto_core_root) == 1)
local ok_core, core = pcall(require, "auto-core")
ok("require('auto-core') succeeds", ok_core, tostring(core))
ok("auto-core has events.register_topics (>= v0.1.61)",
  ok_core and type(core.events.register_topics) == "function")
ok("auto-core has trust (>= v0.1.61)",
  ok_core and type(core.trust) == "table" and type(core.trust.check) == "function")
ok("git binary available",
  vim.system({ "git", "--version" }):wait().code == 0)

-- ── [1] setup + topic registration ──────────────────────────────
print("\n[1] setup() — idempotent + run.* topics registered")
local auto_run = require("auto-run")
ok("M.version is a semver string",
  type(auto_run.version) == "string" and auto_run.version:match("^%d+%.%d+%.%d+$") ~= nil)

local setup_ok, setup_err = auto_run.setup()
ok("setup() returns true", setup_ok == true, tostring(setup_err))
ok("M._initialized true after setup", auto_run._initialized == true)

local RUN_TOPICS = {
  "run.config:changed", "run.job:started", "run.job:exited",
  "run.results:changed", "run.session:changed",
  "run.breakpoints:changed", "run.discovery:changed",
  "run.env:changed",
}
local all_registered = true
for _, topic in ipairs(RUN_TOPICS) do
  local spec = core.events.topic_spec(topic)
  if not (spec and spec.registered_by == "auto-run.nvim") then
    all_registered = false
    ok("topic registered: " .. topic, false, vim.inspect(spec))
  end
end
ok("all eight run.* topics registered by auto-run.nvim", all_registered)

local setup2_ok = auto_run.setup()
ok("second setup() is idempotent (returns true)", setup2_ok == true)
ok("run.config:changed still registered after re-setup",
  core.events.topic_spec("run.config:changed") ~= nil)

-- ── [2] resolver matrix (ADR §2.1) ──────────────────────────────
print("\n[2] resolve_run_dirs() — the §2.1 four-fixture matrix")
local store = require("auto-run.store")
local store_paths = require("auto-run.store.paths")
store_paths._reset_for_tests()

-- Fixture 1: plain repo.
local plain = fx .. "/plain"
ok("fixture 1: plain repo created", make_plain_repo(plain))
worktree.set_active(plain)
local d1 = store.resolve_run_dirs()
ok("plain: tracked = <repo>/.auto-run", d1.tracked == plain .. "/.auto-run",
  tostring(d1.tracked))
ok("plain: shared = <repo>/.auto-run/local", d1.shared == plain .. "/.auto-run/local",
  tostring(d1.shared))
ok("plain: origin = derived", d1.origin == "derived")
ok("plain: root diagnostic = repo", d1.root == plain, tostring(d1.root))

-- Fixture 2: linked worktree of a bare-container repo.
local src = fx .. "/src"
ok("fixture 2: source repo created", make_plain_repo(src))
local container = fx .. "/container"
vim.fn.mkdir(container, "p")
local ok_clone = git(fx, "clone", "-q", "--bare", src, container .. "/.bare")
ok("fixture 2: bare clone created", ok_clone)
local ok_wt = git(fx, "--git-dir=" .. container .. "/.bare",
  "worktree", "add", "-q", container .. "/main", "main")
ok("fixture 2: linked worktree added", ok_wt)
worktree.set_active(container .. "/main")
local d2 = store.resolve_run_dirs()
ok("linked: tracked = <worktree>/.auto-run",
  d2.tracked == container .. "/main/.auto-run", tostring(d2.tracked))
ok("linked: shared = <container>/.auto-run",
  d2.shared == container .. "/.auto-run", tostring(d2.shared))
ok("linked: tracked dir ≠ shared parent (two real tiers)",
  d2.tracked ~= d2.shared and d2.container == container,
  tostring(d2.container))
ok("linked: origin = derived", d2.origin == "derived")

-- Fixture 3: run.set_dir override branch.
local override_dir = fx .. "/override-store"
vim.fn.mkdir(override_dir, "p")
local d3, sd_err = store.set_dir(override_dir)
ok("set_dir returns dirs", d3 ~= nil, tostring(sd_err))
ok("override: origin = override", d3 and d3.origin == "override")
ok("override: shared = override dir", d3 and d3.shared == override_dir,
  d3 and tostring(d3.shared))
ok("override: tracked tier still derived",
  d3 and d3.tracked == container .. "/main/.auto-run")
local d3b = store.resolve_run_dirs()
ok("override survives re-resolution", d3b.origin == "override")
local d3c = store.set_dir(nil)
ok("clearing the override restores derived",
  d3c and d3c.origin == "derived" and d3c.shared == container .. "/.auto-run")

-- Fixture 4: anchor inside a nested child repo resolves to the child.
local umbrella = fx .. "/umbrella"
ok("fixture 4: umbrella repo created", make_plain_repo(umbrella))
local child = umbrella .. "/child"
ok("fixture 4: nested child repo created", make_plain_repo(child))
vim.fn.mkdir(child .. "/pkg", "p")
worktree.set_active(child .. "/pkg")
local d4 = store.resolve_run_dirs()
ok("nested: tracked anchors at the CHILD repo",
  d4.tracked == child .. "/.auto-run", tostring(d4.tracked))
ok("nested: shared anchors at the CHILD repo (plain layout)",
  d4.shared == child .. "/.auto-run/local", tostring(d4.shared))
ok("nested: never the umbrella", d4.root == child, tostring(d4.root))

-- Cache invalidation on worktree switch.
worktree.set_active(plain)
local d5 = store.resolve_run_dirs()
ok("core.active_worktree:changed re-anchors the resolver",
  d5.tracked == plain .. "/.auto-run", tostring(d5.tracked))

-- ── [3] schema validation ───────────────────────────────────────
print("\n[3] schema — config + profile validation")
local schema = require("auto-run.store.schema")

local v = schema.validate_config({
  name = "gold-http", kind = "debug", runtime = "go",
  program = "${containerRoot}/cmd/gold-http",
  args = { "-c=${containerRoot}/.config/gold.toml" },
  cwd = "${worktree}", build_flags = "-tags=gold",
  env = { PORT = "8081" }, env_files = { "${containerRoot}/.config/.env" },
  profile = "prod-db", depends = { "build-assets" }, tags = { "service" },
  params = { region = { type = "string", default = "us", choices = { "us", "eu" } } },
})
ok("ADR §3 example config validates", v.ok, table.concat(v.errors or {}, "; "))

v = schema.validate_config({ name = "x" })
ok("missing kind rejected", not v.ok and contains(v.errors, "missing required field 'kind'"),
  table.concat(v.errors, "; "))
v = schema.validate_config({ name = "x", kind = "banana" })
ok("bad kind rejected", not v.ok)
v = schema.validate_config({ name = "bad/name", kind = "run" })
ok("path-unsafe name rejected", not v.ok)
v = schema.validate_config({ name = "x", kind = "run", args = "not-a-list" })
ok("non-list args rejected", not v.ok)
v = schema.validate_config({ name = "x", kind = "run", nonsense = 1 })
ok("unknown field rejected", not v.ok and contains(v.errors, "unknown field 'nonsense'"))
v = schema.validate_config({ name = "x", kind = "run", env = { PORT = vim.NIL } })
ok("null map-key tombstone is schema-legal", v.ok, table.concat(v.errors or {}, "; "))

v = schema.validate_profile({
  name = "prod-db",
  base_env_files = { "${containerRoot}/.config/.env" },
  secret_manifests = { "${containerRoot}/.config/.env.secrets" },
  command_env = { { key = "PG_PASS", command = "pass pg/gold-prod", required = true } },
  runtime_env = { APP_HOME = "{{home}}/.cache/{{app}}" },
})
ok("ADR §4 example profile validates", v.ok, table.concat(v.errors or {}, "; "))
v = schema.validate_profile({ name = "p", command_env = { { key = "K" } } })
ok("command_env entry without command rejected", not v.ok)

-- ── [4] merge engine ────────────────────────────────────────────
print("\n[4] merge — precedence, per-field rules, tombstones, cycles")
local merge = require("auto-run.store.merge")

local eff, prov = merge.apply({
  { data = { program = "a", args = { "1" }, env = { A = "1", B = "1" },
      env_files = { "f1" }, tags = { "t1", "t2" } }, source = "tracked" },
  { data = { program = "b", args = { "2", "3" }, env = { B = "2", C = "2" },
      env_files = { "f2" }, tags = { "t2", "t3" } }, source = "shared" },
})
ok("scalar replaces (later wins)", eff.program == "b")
ok("args replaces the whole array", #eff.args == 2 and eff.args[1] == "2")
ok("env merges per key", eff.env.A == "1" and eff.env.B == "2" and eff.env.C == "2")
ok("env_files appends across layers",
  #eff.env_files == 2 and eff.env_files[1] == "f1" and eff.env_files[2] == "f2")
ok("tags append + dedupe",
  #eff.tags == 3 and contains(eff.tags, "t1") and contains(eff.tags, "t3"))
ok("provenance tracks the winning layer",
  prov.program == "shared" and prov.env_files == "shared")

eff = merge.apply({
  { data = { program = "a", env = { A = "1", B = "1" }, args = { "1" } }, source = "base" },
  { data = { program = vim.NIL, env = { A = vim.NIL }, args = vim.NIL }, source = "over" },
})
ok("null scalar tombstone unsets", eff.program == nil)
ok("null map key removes that key", eff.env.A == nil and eff.env.B == "1")
ok("array set to null empties it", type(eff.args) == "table" and #eff.args == 0)

eff = merge.apply({
  { data = { env = { A = "1" } }, source = "base" },
  { data = { env = vim.NIL }, source = "over" },
})
ok("whole-map null tombstone clears the map", eff.env == nil)

local registry = {
  a = { extends = "b", program = "pa" },
  b = { extends = "c" },
  c = { program = "pc" },
  loop1 = { extends = "loop2" },
  loop2 = { extends = "loop1" },
  dangling = { extends = "ghost" },
}
local lookup = function(n) return registry[n] end
local chain, cerr = merge.resolve_extends_chain("a", lookup)
ok("extends chain resolves deepest-base-first",
  chain and #chain == 2 and chain[1] == "c" and chain[2] == "b", tostring(cerr))
chain, cerr = merge.resolve_extends_chain("loop1", lookup)
ok("extends cycle is a hard error", chain == nil)
ok("cycle diagnostic carries the path",
  type(cerr) == "string" and cerr:find("loop1 -> loop2 -> loop1", 1, true) ~= nil,
  tostring(cerr))
chain, cerr = merge.resolve_extends_chain("dangling", lookup)
ok("dangling extends target is a hard error",
  chain == nil and tostring(cerr):find("ghost", 1, true) ~= nil, tostring(cerr))

-- ── [5] store CRUD + write-routing + validate ───────────────────
print("\n[5] store — CRUD, tier routing, deterministic listing")
worktree.set_active(plain)

local path1, aerr = store.add(
  { name = "go-base", kind = "run", runtime = "go",
    program = "${worktree}/cmd/app", env = { PORT = "8080", MODE = "base" },
    env_files = { "base.env" }, tags = { "base" } },
  { tier = "tracked" })
ok("add writes a tracked-tier config", path1 ~= nil, tostring(aerr))
ok("config file exists at <repo>/.auto-run/configs/go-base.json",
  vim.fn.filereadable(plain .. "/.auto-run/configs/go-base.json") == 1)
local decoded = vim.json.decode(
  table.concat(vim.fn.readfile(plain .. "/.auto-run/configs/go-base.json"), "\n"))
ok("stored file is strict JSON with the config", decoded.name == "go-base")

-- config_file(): the public resolver consumers use instead of rebuilding
-- `configs_dir() .. "/" .. name .. ".json"` themselves (ADR-0048 Phase 3
-- follow-up). It must agree with where add() actually wrote.
ok("config_file() resolves the tracked config's own file",
  store.config_file("go-base") == plain .. "/.auto-run/configs/go-base.json",
  tostring(store.config_file("go-base")))
ok("config_file() agrees with the path add() returned",
  store.config_file("go-base") == path1, tostring(path1))
ok("config_file() returns nil for a name with no stored file",
  store.config_file("no-such-config") == nil,
  tostring(store.config_file("no-such-config")))
ok("config_file() rejects a non-string / empty name",
  store.config_file(nil) == nil and store.config_file("") == nil)

local _, dup_err = store.add({ name = "go-base", kind = "run" }, { tier = "tracked" })
ok("same-tier duplicate refused without overwrite",
  dup_err ~= nil and dup_err:match("already exists") ~= nil, tostring(dup_err))

local bad, bad_err = store.add({ name = "nope" })
ok("invalid config refused with a structured error",
  bad == nil and tostring(bad_err):match("missing required field 'kind'") ~= nil,
  tostring(bad_err))

store.add(
  { name = "svc-a", kind = "debug", runtime = "go", extends = "go-base",
    env = { MODE = "svc" }, env_files = { "svc.env" }, tags = { "svc" } },
  { tier = "tracked" })
local eff_a, gerr, meta_a = store.get("svc-a")
ok("get() merges the extends chain", eff_a ~= nil, tostring(gerr))
ok("extends: scalar inherited from base",
  eff_a and eff_a.program == "${worktree}/cmd/app")
ok("extends: env merged per key",
  eff_a and eff_a.env.PORT == "8080" and eff_a.env.MODE == "svc")
ok("extends: env_files appended base-first",
  eff_a and #eff_a.env_files == 2 and eff_a.env_files[1] == "base.env")
ok("meta.layers records extends + tracked",
  meta_a and contains(meta_a.layers, "extends:go-base") and contains(meta_a.layers, "tracked"))

-- Shared-tier same-name overlay (layer 3 over layer 2).
store.add({ name = "svc-a", kind = "debug", program = "/shared/bin" },
  { tier = "shared" })
local eff_a2 = store.get("svc-a")
ok("shared-local layer wins over tracked",
  eff_a2 and eff_a2.program == "/shared/bin")
-- config_file() answers "which file DEFINES this name's own layer", and its
-- tier precedence is the store's (tracked first) — deliberately NOT the merge
-- precedence above, where the shared overlay wins the VALUE. `e` on a config
-- row must open the tracked definition, not the overlay.
ok("config_file() prefers the tracked tier when both tiers hold the name",
  store.config_file("svc-a") == plain .. "/.auto-run/configs/svc-a.json",
  tostring(store.config_file("svc-a")))
ok("plain-repo shared tier scaffolds .auto-run/.gitignore",
  vim.fn.filereadable(plain .. "/.auto-run/.gitignore") == 1
    and table.concat(vim.fn.readfile(plain .. "/.auto-run/.gitignore"), "\n"):match("local/") ~= nil)

-- Write-routing: shared file exists → patch it.
local up1, up1_err = store.update("svc-a", { cwd = "/tmp" })
ok("update routes to the shared config file when one exists",
  up1 ~= nil and up1.layer == "shared", tostring(up1_err))
-- Write-routing: tracked-only config → overrides.json.
local up2, up2_err = store.update("go-base", { env = { PORT = "9999" } })
ok("update on a tracked-only config routes to overrides.json",
  up2 ~= nil and up2.layer == "overrides", tostring(up2_err))
ok("overrides.json exists in the shared tier",
  vim.fn.filereadable(plain .. "/.auto-run/local/overrides.json") == 1)
local eff_base = store.get("go-base")
ok("overrides layer wins at read time", eff_base and eff_base.env.PORT == "9999")

-- Tombstone through the overrides layer.
store.update("go-base", { env = { MODE = vim.NIL } })
eff_base = store.get("go-base")
ok("null tombstone in overrides strips an inherited env key",
  eff_base and eff_base.env.MODE == nil and eff_base.env.PORT == "9999")

local up3, up3_err = store.update("ghost", { cwd = "/x" })
ok("update on unknown config errors not-found",
  up3 == nil and tostring(up3_err):match("not found") ~= nil, tostring(up3_err))

-- Deterministic listing: tracked names sorted first, then shared-only.
store.add({ name = "zz-personal", kind = "run" }, { tier = "shared" })
local inventory = store.list()
local names = {}
for _, c in ipairs(inventory) do names[#names + 1] = c.name end
ok("list is tier-then-filename ordered",
  names[1] == "go-base" and names[2] == "svc-a" and names[3] == "zz-personal",
  vim.inspect(names))

-- Profiles.
store.add(
  { name = "prod-db", base_env_files = { "b.env" },
    runtime_env = { APP_HOME = "{{home}}/.cache/{{app}}" } },
  { tier = "tracked", kind = "profiles" })
local profs = store.list_profiles()
ok("list_profiles sees the tracked profile",
  #profs == 1 and profs[1].name == "prod-db" and contains(profs[1].tiers, "tracked"))
local prof = store.get_profile("prod-db")
ok("get_profile returns the merged record",
  prof and prof.base_env_files[1] == "b.env")

-- Profile applied as merge layer 5 (env-affecting fields only).
store.update("go-base", { profile = "prod-db" })
local eff_p, _, meta_p = store.get("go-base")
ok("profile layer contributes pipeline fields",
  eff_p and eff_p.base_env_files and eff_p.base_env_files[1] == "b.env")
ok("profile layer recorded in meta.layers",
  meta_p and contains(meta_p.layers, "profile:prod-db"))

-- Extends cycle through real files surfaces in get() + validate().
store.add({ name = "cyc-a", kind = "run", extends = "cyc-b" }, { tier = "tracked" })
store.add({ name = "cyc-b", kind = "run", extends = "cyc-a" }, { tier = "tracked" })
local cyc, cyc_err = store.get("cyc-a")
ok("get() surfaces extends cycles with the path",
  cyc == nil and tostring(cyc_err):find("cyc%-a %-> cyc%-b %-> cyc%-a") ~= nil,
  tostring(cyc_err))
local report = store.validate()
ok("validate() flags the cycle", report.ok == false)
local cycle_flagged = false
for _, issue in ipairs(report.issues) do
  for _, e in ipairs(issue.errors) do
    if e:find("extends cycle", 1, true) then cycle_flagged = true end
  end
end
ok("validate() issue names the cycle", cycle_flagged, vim.inspect(report.issues))

-- Corrupt file detection.
write_file(plain .. "/.auto-run/configs/broken.json", "{ not json !!")
report = store.validate()
local broken_flagged = false
for _, issue in ipairs(report.issues) do
  if issue.name == "broken" then broken_flagged = true end
end
ok("validate() flags invalid JSON files", broken_flagged)
vim.uv.fs_unlink(plain .. "/.auto-run/configs/broken.json")

-- Remove: shared file first, then tracked; overrides entry dropped.
store.remove("cyc-a")
store.remove("cyc-b")
ok("validate green after removing the cycle", store.validate().ok == true)
local rm_ok = store.remove("svc-a")             -- removes the SHARED file
ok("remove prefers the shared tier", rm_ok == true
  and vim.fn.filereadable(plain .. "/.auto-run/local/configs/svc-a.json") == 0
  and vim.fn.filereadable(plain .. "/.auto-run/configs/svc-a.json") == 1)
store.remove("svc-a")                           -- now the tracked file
local _, rm_err = store.remove("svc-a")
ok("remove on a gone config errors not-found",
  tostring(rm_err):match("not found") ~= nil, tostring(rm_err))

-- ── [6] substitution tokens ─────────────────────────────────────
print("\n[6] env.substitute — uniform token engine")
local envmod = require("auto-run.env")
local ctx = { worktree = "/wt", container = "/ct", file = "/src/pkg/main.go" }

local out = envmod.substitute("${worktree}/bin", ctx)
ok("${worktree} resolves", out == "/wt/bin", out)
out = envmod.substitute("${workspaceFolder}/bin", ctx)
ok("${workspaceFolder} aliases ${worktree}", out == "/wt/bin", out)
out = envmod.substitute("${containerRoot}/.config", ctx)
ok("${containerRoot} resolves", out == "/ct/.config", out)
out = envmod.substitute("run ${file}", ctx)
ok("${file} resolves", out == "run /src/pkg/main.go", out)
out = envmod.substitute("cd ${fileDirname}", ctx)
ok("${fileDirname} resolves", out == "cd /src/pkg", out)

vim.env.AUTO_RUN_SMOKE_VAR = "hello"
out = envmod.substitute("v=${env:AUTO_RUN_SMOKE_VAR}", ctx)
ok("${env:VAR} resolves from the process env", out == "v=hello", out)
vim.env.AUTO_RUN_SMOKE_VAR = nil

local np
out, np = envmod.substitute("--region=${input:region}", ctx)
ok("${input:param} is LEFT unresolved (Phase 1)",
  out == "--region=${input:region}", out)
ok("…and recorded in the structured needs_params marker",
  contains(np, "region"), vim.inspect(np))

local deep, deep_np = envmod.substitute_deep({
  program = "${worktree}/cmd", args = { "-c=${containerRoot}/x", "${input:mode}" },
  env = { HOME_DIR = "${env:HOME}" },
}, ctx)
ok("substitute_deep covers ALL string fields uniformly",
  deep.program == "/wt/cmd" and deep.args[1] == "-c=/ct/x"
    and deep.env.HOME_DIR == (vim.env.HOME or ""))
ok("substitute_deep aggregates needs_params", contains(deep_np, "mode"))

-- ── [7] env pipeline — trust gate + materialization ─────────────
print("\n[7] env.compose — pipeline, command_env trust, 0600 files")
local trust = require("auto-core.trust")
trust._reset_for_tests()

local envfx = fx .. "/env"
write_file(envfx .. "/base.env", [[
# comment
export FROM_FILE=file-value
SHARED_KEY="file-wins-not"
]])
write_file(envfx .. "/secrets.manifest", [[
# gcp-env grammar
DB_PASS=projects/x/secrets/db@3#creds.pass
API_KEY=projects/x/secrets/api
]])

local pipeline_cfg = {
  name = "gold-http",
  kind = "run",
  base_env_files = { envfx .. "/base.env" },
  secret_manifests = { envfx .. "/secrets.manifest" },
  command_env = { { key = "CMD_SECRET", command = "echo sekrit-value", required = true } },
  runtime_env = { APP_HOME = "{{home}}/.cache/{{app}}" },
  env = { SHARED_KEY = "config-wins" },
}

-- Trust disabled → composition FAILS with a structured error (never skips).
local res, cerr = envmod.compose(pipeline_cfg, { ctx = ctx })
ok("untrusted command_env fails composition", res == nil)
ok("…with code=trust_required", cerr and cerr.code == "trust_required",
  vim.inspect(cerr))
ok("…naming the capability", cerr and cerr.capability == "run.command_env")
ok("…and the command", cerr and cerr.command == "echo sekrit-value")

-- Mailbox can never force-enable: set without ack refuses.
local set_ok, set_err = trust.set("run.command_env", { enabled = true })
ok("trust.set without first-run ack refuses",
  set_ok == false and set_err == "trust_not_acknowledged", tostring(set_err))

-- Interactive path: ack, then enable.
trust.acknowledge_first_run("run.command_env")
set_ok = trust.set("run.command_env", { enabled = true })
ok("trust.set after ack succeeds", set_ok == true)

res, cerr = envmod.compose(pipeline_cfg, { ctx = ctx })
ok("trusted composition succeeds", res ~= nil and res.ok == true, vim.inspect(cerr))
ok("base env file parsed", res and res.env.FROM_FILE == "file-value")
ok("config env wins last", res and res.env.SHARED_KEY == "config-wins")
ok("command_env value captured", res and res.env.CMD_SECRET == "sekrit-value")
ok("runtime_env template expanded",
  res and res.env.APP_HOME == (vim.env.HOME or "") .. "/.cache/gold-http",
  res and res.env.APP_HOME)
ok("secret manifest surfaced as NAMES (no resolver → pending)",
  res and contains(res.pending_secrets, "DB_PASS") and contains(res.pending_secrets, "API_KEY"))
ok("secret refs carry manifest metadata",
  res and res.secret_refs[1].secret == "projects/x/secrets/db"
    and res.secret_refs[1].version == "3"
    and res.secret_refs[1].toml_path == "creds.pass")
ok("no secret VALUE leaks into pending/refs",
  res and vim.inspect(res.secret_refs):find("sekrit", 1, true) == nil)

-- Pluggable resolver hook.
envmod.set_secret_resolver(function(refs)
  local values = {}
  for _, ref in ipairs(refs) do values[ref.key] = "resolved:" .. ref.secret end
  return values
end)
res = envmod.compose(pipeline_cfg, { ctx = ctx })
ok("registered resolver materializes manifest keys",
  res and res.env.DB_PASS == "resolved:projects/x/secrets/db"
    and #res.pending_secrets == 0)
envmod.set_secret_resolver(nil)

-- Allowlist: enabled + allowlist that doesn't match → structured failure.
trust.set("run.command_env", { allowlist = { "^pass " } })
res, cerr = envmod.compose(pipeline_cfg, { ctx = ctx })
ok("allowlist rejection also fails composition with trust_required",
  res == nil and cerr and cerr.code == "trust_required" and cerr.reason == "allowlist_rejected",
  vim.inspect(cerr))
trust.set("run.command_env", { allowlist = false })

-- required=false degrades with a warning instead of aborting.
local soft_cfg = {
  name = "soft", kind = "run",
  command_env = { { key = "SOFT", command = "exit 3", required = false } },
}
res = envmod.compose(soft_cfg, { ctx = ctx })
ok("required=false command failure degrades with a warning",
  res ~= nil and res.env.SOFT == nil and #res.warnings > 0,
  res and vim.inspect(res.warnings))

-- command_env timeout policy (env.command_timeout_ms knob).
do
  require("auto-run.config").setup({ env = { command_timeout_ms = 100 } })
  local tres, terr = envmod.compose(
    { name = "slow", kind = "run",
      command_env = { { key = "SLOW", command = "sleep 5", required = true } } },
    { ctx = ctx })
  ok("command_env timeout fails composition (100ms vs sleep 5)", tres == nil)
  ok("…with code=command_env_timeout naming key + command",
    terr and terr.code == "command_env_timeout" and terr.key == "SLOW"
      and terr.command == "sleep 5", vim.inspect(terr))
  local sres = envmod.compose(
    { name = "slow-soft", kind = "run",
      command_env = { { key = "SLOW", command = "sleep 5", required = false } } },
    { ctx = ctx })
  ok("required=false timeout degrades with a warning (skip, no abort)",
    sres ~= nil and sres.env.SLOW == nil and #sres.warnings > 0
      and tostring(sres.warnings[1]):find("timed out", 1, true) ~= nil,
    sres and vim.inspect(sres.warnings))
  require("auto-run.config").setup({})
end

-- vim.system():wait() returning NIL is a real outcome, not an impossible one.
--
-- Neovim's own SystemObj:wait (runtime/lua/vim/_core/system.lua) returns
-- `state.result`, which the exit handler fills in. On the timeout path it
-- SIGKILLs the process and then waits a SECOND time for the same
-- `state.timeout` — so with a small command_timeout_ms on a loaded machine
-- the reap can miss that window and wait() hands back nil. Found by CI on a
-- GitHub runner: `attempt to index local 'res' (a nil value)` at
-- env/init.lua, which aborted the suite MID-RUN rather than failing a cell.
--
-- Driven by stubbing vim.system rather than by racing a real one: the
-- production question is "does composition survive a nil result", and a cell
-- that has to lose a race to ask it would be flaky in exactly the way the
-- thing it tests is.
do
  require("auto-run.config").setup({ env = { command_timeout_ms = 100 } })
  local real_system = vim.system
  vim.system = function() return { wait = function() return nil end } end
  local nres, nerr = envmod.compose(
    { name = "nilwait", kind = "run",
      command_env = { { key = "NILW", command = "sleep 5", required = true } } },
    { ctx = ctx })
  vim.system = real_system
  ok("nil from vim.system():wait() is treated as a timeout, not a crash",
    nres == nil and nerr and nerr.code == "command_env_timeout",
    vim.inspect(nerr))

  vim.system = function() return { wait = function() return nil end } end
  local sres2 = envmod.compose(
    { name = "nilwait-soft", kind = "run",
      command_env = { { key = "NILW", command = "sleep 5", required = false } } },
    { ctx = ctx })
  vim.system = real_system
  ok("…and required=false still degrades with a warning rather than aborting",
    sres2 ~= nil and sres2.env.NILW == nil and #sres2.warnings > 0
      and tostring(sres2.warnings[1]):find("timed out", 1, true) ~= nil,
    sres2 and vim.inspect(sres2.warnings))
  require("auto-run.config").setup({})
end

-- Missing env file aborts composition.
res, cerr = envmod.compose(
  { name = "x", kind = "run", env_files = { envfx .. "/missing.env" } },
  { ctx = ctx })
ok("missing env file aborts with env_file_missing",
  res == nil and cerr and cerr.code == "env_file_missing", vim.inspect(cerr))

-- Materialization lifecycle (§4.1).
require("auto-run.config").setup({ env = { dir = fx .. "/env-cache" } })
local mat_path, mat_err = envmod.materialize("run-0001",
  { KEY_A = "va", KEY_B = "vb" })
ok("materialize writes <dir>/<run-id>.env",
  mat_path == fx .. "/env-cache/run-0001.env"
    and vim.fn.filereadable(mat_path) == 1, tostring(mat_err))
local st = vim.uv.fs_stat(mat_path)
local dir_st = vim.uv.fs_stat(fx .. "/env-cache")
local bit = require("bit")
ok("materialized file is 0600",
  st and bit.band(st.mode, 511) == 384,
  st and ("mode=%o"):format(bit.band(st.mode, 511)))
ok("parent dir is 0700",
  dir_st and bit.band(dir_st.mode, 511) == 448,
  dir_st and ("mode=%o"):format(bit.band(dir_st.mode, 511)))
ok("materialized content is KEY='VALUE' lines (shell-quoted values)",
  table.concat(vim.fn.readfile(mat_path), "\n") == "KEY_A='va'\nKEY_B='vb'")
local bad_id = envmod.materialize("../escape", { A = "1" })
ok("path-unsafe run ids refused", bad_id == nil)

-- Shell-safety: hostile values must round-trip LITERALLY through the
-- sourced env file (the term-strategy consumption path) and can never
-- execute; invalid keys fail composition/materialization up front.
do
  local marker = fx .. "/env-cache-pwn-marker"
  local hostile = {
    name = "hostile", kind = "run",
    env = {
      V_SPACES   = "hello world",
      V_DQUOTE   = 'say "hi"',
      V_SQUOTE   = "it's a value",
      V_DOLLAR   = "$HOME literal",
      V_BACKTICK = "`id`",
      V_SUBST    = "$(touch " .. marker .. ")",
    },
  }
  local hres, herr = envmod.compose(hostile, { ctx = ctx })
  ok("hostile values compose", hres ~= nil, vim.inspect(herr))
  local hpath, hmerr = envmod.materialize("run-hostile", hres.env)
  ok("hostile env materializes", hpath ~= nil, tostring(hmerr))
  local script = ("set -a; . %s; set +a; "
    .. "printf '%%s\\n' \"$V_SPACES\" \"$V_DQUOTE\" \"$V_SQUOTE\""
    .. " \"$V_DOLLAR\" \"$V_BACKTICK\" \"$V_SUBST\"")
    :format(vim.fn.shellescape(hpath))
  local sres = vim.system({ "sh", "-c", script }, { text = true }):wait()
  ok("sourcing the materialized file succeeds",
    sres.code == 0, tostring(sres.stderr))
  local got = vim.split(sres.stdout or "", "\n")
  ok("spaces round-trip literally", got[1] == "hello world", got[1])
  ok("double quotes round-trip literally", got[2] == 'say "hi"', got[2])
  ok("single quotes round-trip literally", got[3] == "it's a value", got[3])
  ok("$VAR stays literal (no expansion)", got[4] == "$HOME literal", got[4])
  ok("backticks stay literal", got[5] == "`id`", got[5])
  ok("command substitution stays literal",
    got[6] == "$(touch " .. marker .. ")", got[6])
  ok("marker file was NOT created (no code execution)",
    vim.fn.filereadable(marker) == 0)
  envmod.discard("run-hostile")

  -- Invalid keys: composition fails structured, materialize refuses.
  write_file(envfx .. "/badkey.env", "BAD-KEY=1\n")
  local bres, berr = envmod.compose(
    { name = "x", kind = "run", env_files = { envfx .. "/badkey.env" } },
    { ctx = ctx })
  ok("invalid env key fails composition", bres == nil)
  ok("…with code=invalid_env_key naming the key",
    berr and berr.code == "invalid_env_key" and berr.key == "BAD-KEY",
    vim.inspect(berr))
  local mpath, mkerr = envmod.materialize("run-badkey", { ["BAD KEY"] = "x" })
  ok("materialize refuses invalid keys (structured error names the key)",
    mpath == nil and tostring(mkerr):find("BAD KEY", 1, true) ~= nil,
    tostring(mkerr))
  ok("nothing written for the refused materialization",
    vim.fn.filereadable(fx .. "/env-cache/run-badkey.env") == 0)
end

-- Startup sweep: >24h-old files removed, fresh ones kept.
local old_path = envmod.materialize("run-old", { A = "1" })
local stale = os.time() - 25 * 3600
vim.uv.fs_utime(old_path, stale, stale)
local removed = envmod.sweep()
ok("sweep removes files older than 24h",
  removed >= 1 and vim.fn.filereadable(old_path) == 0, "removed=" .. removed)
ok("sweep keeps fresh files", vim.fn.filereadable(mat_path) == 1)
envmod.discard("run-0001")
ok("discard removes a run's file", vim.fn.filereadable(mat_path) == 0)
require("auto-run.config").setup({})  -- restore defaults

-- ── [8] launch.json import + read-through contract ──────────────
print("\n[8] import — JSONC parse, read-through, one-shot migration")
local import = require("auto-run.import")

local lj = fx .. "/lj-repo"
-- The launch.json's "Debug Gold" builds ${workspaceFolder}/cmd/gold: give it
-- that package directory, or the go adapter refuses the missing program
-- before launch (v0.1.18) — as it should for a config that could never build.
vim.fn.mkdir(lj .. "/cmd/gold", "p")
ok("launch.json fixture repo created", make_plain_repo(lj))
write_file(lj .. "/.vscode/launch.json", [[
{
  // JSONC: comments must survive parsing
  "version": "0.2.0",
  "inputs": [
    { "id": "region", "type": "pickString", "description": "Region",
      "default": "us", "options": ["us", "eu"], },
  ],
  "configurations": [
    {
      "name": "Debug Gold", /* block comment */
      "type": "go",
      "request": "launch",
      "mode": "debug",
      "program": "${workspaceFolder}/cmd/gold",
      "args": ["--region=${input:region}"],
      "buildFlags": "-tags=gold",
      "env": { "PORT": "8081" },
      "envFile": "${workspaceFolder}/../.config/test.env",
    },
    {
      "name": "Test Gold",
      "type": "go",
      "request": "launch",
      "mode": "test",
      "program": "${workspaceFolder}",
    },
  ],
}
]])
worktree.set_active(lj)

ok("read-through active while NO store exists", import.read_through_active() == true)
local lj_list = store.list()
ok("shims listed while read-through is active", #lj_list == 2, vim.inspect(lj_list))
local shim_eff, _, shim_meta = store.get("Debug Gold")
ok("shim config resolves through get()",
  shim_eff ~= nil and shim_eff.origin == "launch.json"
    and shim_eff.kind == "debug" and shim_eff.runtime == "go")
ok("shim is merge layer 4 only",
  shim_meta and #shim_meta.layers == 1 and shim_meta.layers[1] == "launch.json")
ok("mode=test maps to kind=test",
  (store.get("Test Gold") or {}).kind == "test")
ok("envFile becomes env_files", shim_eff.env_files[1] == "${workspaceFolder}/../.config/test.env")
ok("buildFlags becomes build_flags", shim_eff.build_flags == "-tags=gold")
ok("inputs lift into typed params on referencing entries",
  shim_eff.params and shim_eff.params.region
    and shim_eff.params.region.choices[2] == "eu")

-- Shims are read-only: update names :AutoRun import.
local _, shim_up_err = store.update("Debug Gold", { cwd = "/x" })
ok("update against a shim is a structured read-only error",
  tostring(shim_up_err):find(":AutoRun import", 1, true) ~= nil, tostring(shim_up_err))

-- One-shot migration into the tracked tier.
local summary, imp_err = import.import(nil, { on_conflict = "skip" })
ok("import succeeds", summary ~= nil, tostring(imp_err))
ok("both entries imported", summary and #summary.imported == 2,
  summary and vim.inspect(summary))
ok("imported files land in the TRACKED tier",
  vim.fn.filereadable(lj .. "/.auto-run/configs/Debug Gold.json") == 1)
local imported_eff = store.get("Debug Gold")
ok("imported config carries origin=launch.json provenance",
  imported_eff and imported_eff.origin == "launch.json")

-- The moment a store exists, read-through disables (§5).
ok("read-through DISABLES once a store exists",
  import.read_through_active() == false)
local post_list = store.list()
local from_store = true
for _, c in ipairs(post_list) do
  if not contains(c.layers, "tracked") then from_store = false end
end
ok("listing now comes from the store, not shims",
  #post_list == 2 and from_store, vim.inspect(post_list))
local _, up_after_err = store.update("Debug Gold", { cwd = "${worktree}" })
ok("imported configs are updatable (no longer shims)", up_after_err == nil,
  tostring(up_after_err))

-- Per-entry conflict choices are a parameter.
summary = import.import(nil, { on_conflict = "skip" })
ok("re-import with skip skips both", summary and #summary.skipped == 2)
summary = import.import("Test Gold", { on_conflict = "rename" })
ok("per-entry rename picks a free name",
  summary and summary.renamed["Test Gold"] == "Test Gold-2"
    and vim.fn.filereadable(lj .. "/.auto-run/configs/Test Gold-2.json") == 1,
  summary and vim.inspect(summary))
summary = import.import("Test Gold", {
  on_conflict = function(_name) return "overwrite" end,
})
ok("per-entry function choice (overwrite) works",
  summary and contains(summary.imported, "Test Gold"), summary and vim.inspect(summary))
local _, missing_err = import.import("No Such Entry", {})
ok("import of an unknown entry errors",
  tostring(missing_err):find("No Such Entry", 1, true) ~= nil, tostring(missing_err))

-- ── [8.5] launch-config selection (Config section runtime) ──────
-- Direct-parse selection surface + apply_selected_base merge, over the
-- lj fixture (worktree still active). launch.json has "Debug Gold"
-- (mode=debug) and "Test Gold" (mode=test).
print("\n[8.5] import — launch-config selection + active-base merge")
do
  -- configs_list: kind filter + selected annotation.
  local all = import.configs_list()
  ok("configs_list() returns every entry", #all == 2, vim.inspect(all))
  local tests = import.configs_list("test")
  ok("configs_list('test') filters to mode=test",
    #tests == 1 and tests[1].name == "Test Gold", vim.inspect(tests))
  local debugs = import.configs_list("debug")
  ok("configs_list('debug') filters to mode=debug",
    #debugs == 1 and debugs[1].name == "Debug Gold", vim.inspect(debugs))

  -- selection round-trips through state.json.
  ok("get_selected() nil before any selection", import.get_selected() == nil)
  local seln, selerr = import.set_selected("Debug Gold")
  ok("set_selected('Debug Gold') ok", seln == true, tostring(selerr))
  ok("selection persists in state.json's selected_launch_config",
    store.read_state().selected_launch_config == "Debug Gold")
  ok("get_selected() returns the name", import.get_selected() == "Debug Gold")
  ok("configs_list annotates the selected entry",
    import.configs_list("debug")[1].selected == true)
  local _, bad = import.set_selected("No Such Config")
  ok("set_selected of an unknown name → not_found",
    type(bad) == "table" and bad.code == "not_found", vim.inspect(bad))

  -- selected_base surfaces the mergeable fields.
  local base = import.selected_base()
  ok("selected_base carries build_flags/env/env_files/args",
    base and base.build_flags == "-tags=gold" and base.env.PORT == "8081"
      and base.env_files[1] == "${workspaceFolder}/../.config/test.env"
      and base.args[1] == "--region=${input:region}", vim.inspect(base))

  -- apply_selected_base merge semantics (pure — no compose).
  local merged = import.apply_selected_base({ kind = "test", name = "gen",
    program = "own-prog" })
  ok("base build_flags fills an eff that lacks them",
    merged.build_flags == "-tags=gold")
  ok("base env merges into an eff that lacks it",
    merged.env and merged.env.PORT == "8081")
  ok("base program/args do NOT override an eff that has a program",
    merged.program == "own-prog" and merged.args == nil)
  local kept = import.apply_selected_base({ kind = "debug", name = "x",
    build_flags = "-tags=own", env = { PORT = "9090" } })
  ok("eff wins over base for build_flags + env keys",
    kept.build_flags == "-tags=own" and kept.env.PORT == "9090")

  -- read_config masks env VALUES (§8.2): keys only, never "8081".
  local view = import.read_config("Debug Gold")
  ok("read_config surfaces env KEYS only",
    view and view.env_keys and view.env_keys[1] == "PORT")
  ok("read_config never carries an env VALUE",
    vim.inspect(view):find("8081", 1, true) == nil, vim.inspect(view))
  ok("read_config substitutes + keeps build_flags",
    view.build_flags == "-tags=gold"
      and view.program == lj .. "/cmd/gold", vim.inspect(view))

  -- run.config:changed fires on selection (action="selected").
  local seen_action
  local h = core.events.subscribe("run.config:changed", function(p)
    if p and p.action == "selected" then seen_action = p end
  end)
  import.set_selected("Test Gold")
  ok("set_selected publishes run.config:changed {action=selected}",
    seen_action ~= nil and seen_action.action == "selected"
      and seen_action.name == "Test Gold", vim.inspect(seen_action))
  core.events.unsubscribe(h)

  -- self-heal: a stored name absent from launch.json resolves to nil.
  local st = store.read_state()
  st.selected_launch_config = "Ghost Config"
  store.write_state(st)
  ok("get_selected self-heals a vanished selection", import.get_selected() == nil)

  -- End-to-end: with "Debug Gold" selected, translating a kind=test
  -- config that lacks build_flags/env picks the base up through
  -- compose. Create the referenced env file so compose resolves it.
  write_file(fx .. "/.config/test.env", "BASE_ENV_KEY=base-val\n")
  import.set_selected("Debug Gold")
  local dap_cfg, terr = require("auto-run.dap").translate("Test Gold-2")
  ok("translate picks up the selected base's build_flags",
    dap_cfg and dap_cfg.buildFlags == "-tags=gold", tostring(terr))
  ok("translate picks up the selected base's env (config + env_file)",
    dap_cfg and dap_cfg.env and dap_cfg.env.PORT == "8081"
      and dap_cfg.env.BASE_ENV_KEY == "base-val", vim.inspect(dap_cfg and dap_cfg.env))

  -- Leave no selection behind for later sections.
  import.set_selected(nil)
  ok("selection cleared for downstream sections",
    import.get_selected() == nil
      and store.read_state().selected_launch_config == nil)
end

-- ── [8.6] run output reconstruction (tests-panel `i` backing) ───
-- go adapter output() rejoins the `go test -json` Output events into
-- what the terminal would print; discovery.run_output dispatches to it.
print("\n[8.6] discovery.run_output + go.output — terminal-log reconstruction")
do
  local go = require("auto-run.adapters.go")
  local discovery = require("auto-run.discovery")
  local job = require("auto-run.exec.job")

  local rid = "smoke-output-0001"
  local dir = job.run_dir(rid)
  vim.fn.mkdir(dir, "p")
  local jf = assert(io.open(dir .. "/stdout", "w"))
  jf:write(table.concat({
    vim.json.encode({ Action="output", Package="p", Test="TestA", Output="=== RUN   TestA\n" }),
    vim.json.encode({ Action="output", Package="p", Test="TestA", Output="    a_test.go:5: hello\n" }),
    vim.json.encode({ Action="output", Package="p", Test="TestA/sub", Output="=== RUN   TestA/sub\n" }),
    vim.json.encode({ Action="output", Package="p", Test="TestB", Output="=== RUN   TestB\n" }),
    vim.json.encode({ Action="output", Package="p", Output="PASS\n" }),
    vim.json.encode({ Action="pass", Package="p", Test="TestA", Elapsed=0.01 }),
  }, "\n") .. "\n")
  jf:close()

  local full = go.output({ stdout_file = dir .. "/stdout" })
  ok("go.output rejoins Output events into terminal text",
    full:find("=== RUN   TestA", 1, true) and full:find("hello", 1, true)
      and full:find("=== RUN   TestB", 1, true) and full:find("PASS", 1, true) ~= nil,
    vim.inspect(full))
  ok("go.output omits non-output events (no JSON leaks)",
    full:find("Elapsed", 1, true) == nil, full)

  local scoped = go.output({ stdout_file = dir .. "/stdout" }, { test = "TestA" })
  ok("go.output test filter keeps the test + subtests + package lines",
    scoped:find("TestA/sub", 1, true) and scoped:find("PASS", 1, true) ~= nil, scoped)
  ok("go.output test filter drops sibling tests",
    scoped:find("TestB", 1, true) == nil, scoped)

  local text, rerr = discovery.run_output(rid, "go")
  ok("discovery.run_output returns reconstructed text",
    type(text) == "string" and text:find("=== RUN   TestA", 1, true) ~= nil,
    tostring(rerr))
  local _, e1 = discovery.run_output(rid, "nope")
  ok("run_output errors on an unknown adapter",
    tostring(e1):find("unknown adapter", 1, true) ~= nil, tostring(e1))
  local _, e2 = discovery.run_output("no-such-run-xyz", "go")
  ok("run_output errors when no stdout exists",
    tostring(e2):find("no stdout", 1, true) ~= nil, tostring(e2))

  vim.fn.delete(dir, "rf")
end

-- ── [8.7] detection paths — .config / .vscode dirs ──────────────
-- launch.json + .env are discovered under a repo's root, `.config/`,
-- and `.vscode/` (and, via the same loop / upward walk, the bare-repo
-- container). Restores the active worktree so [9] still sees `lj`.
print("\n[8.7] detection — .config/.vscode dirs for launch.json + env")
do
  local prev_wt = worktree.get_active()
  local det = fx .. "/det-repo"
  ok("detection fixture repo created", make_plain_repo(det))
  write_file(det .. "/.env", "ROOT=1\n")
  write_file(det .. "/.config/svc.env", "CFG=1\n")
  write_file(det .. "/.vscode/dbg.env", "VSC=1\n")
  worktree.set_active(det)
  store_paths.invalidate()

  local names = {}
  for _, c in ipairs(require("auto-run.env").files_list()) do
    names[vim.fn.fnamemodify(c.path, ":t")] = true
  end
  ok("env discovery finds worktree-root .env", names[".env"], vim.inspect(names))
  ok("env discovery finds .config/*.env", names["svc.env"], vim.inspect(names))
  ok("env discovery finds .vscode/*.env", names["dbg.env"], vim.inspect(names))

  write_file(det .. "/.config/launch.json",
    '{ "version": "0.2.0", "configurations": [ '
    .. '{ "name": "Cfg", "type": "go", "request": "launch", '
    .. '"mode": "test", "program": "${workspaceFolder}" } ] }')
  local found_path = import.find_launch_json()
  ok("find_launch_json locates .config/launch.json",
    type(found_path) == "string"
      and found_path:find("/.config/launch.json", 1, true) ~= nil,
    tostring(found_path))
  local cfgs = import.configs_list()
  ok("configs parse from .config/launch.json",
    #cfgs == 1 and cfgs[1].name == "Cfg", vim.inspect(cfgs))

  worktree.set_active(prev_wt)
  store_paths.invalidate()
end

-- ── [8.8] exec.command_line (debug panel `r`) + import.export (`a`) ──
print("\n[8.8] exec.command_line + import.export (launch.json)")
do
  local exec = require("auto-run.exec")
  -- command_line: go debug config → `go run` + tags, env sourced from a
  -- FILE (secrets off the command line), cd-prefixed.
  -- render_cmdline shell-escapes each token, so argv reads `'go' 'run'`.
  local cmd, cerr = exec.command_line("Debug Gold")
  ok("command_line builds a go-run line for a debug config",
    type(cmd) == "string" and cmd:find("'go' 'run'", 1, true)
      and cmd:find("tags=gold", 1, true) and cmd:find("cmd/gold", 1, true) ~= nil,
    tostring(cerr or cmd))
  ok("command_line sources env from a FILE (no inline secret values)",
    type(cmd) == "string" and cmd:find("set -a; .", 1, true) ~= nil, tostring(cmd))
  ok("command_line prefixes cd <cwd>",
    type(cmd) == "string" and cmd:find("^cd ", 1) ~= nil, tostring(cmd))
  local tcmd = exec.command_line("Test Gold-2")
  ok("command_line builds a go-test line for a test config",
    type(tcmd) == "string" and tcmd:find("'go' 'test'", 1, true) ~= nil, tostring(tcmd))

  -- translate defaults cwd to the worktree root when the config sets
  -- none — WITHOUT this, delve builds in nvim's cwd (outside the module
  -- in a multi-repo parent) and dies "Failed to launch".
  local dcfg = require("auto-run.dap").translate("Debug Gold")
  ok("translate defaults cwd to the worktree root (program run dir)",
    type(dcfg) == "table" and type(dcfg.cwd) == "string"
      and dcfg.cwd:find("lj%-repo") ~= nil, vim.inspect(dcfg and dcfg.cwd))
  ok("translate sets dlvCwd = cwd (delve build dir → in-module go build)",
    type(dcfg) == "table" and dcfg.dlvCwd == dcfg.cwd, vim.inspect(dcfg and dcfg.dlvCwd))

  -- export: append/replace into the reachable launch.json (lj/.vscode).
  local path, xerr = import.export("Debug Gold")
  ok("export returns the target launch.json path",
    type(path) == "string" and path:find("launch.json", 1, true) ~= nil, tostring(xerr))
  local body = ""
  if type(path) == "string" then
    local jf = io.open(path, "r")
    if jf then body = jf:read("*a"); jf:close() end
  end
  ok("exported launch.json carries the entry + buildFlags",
    body:find('"Debug Gold"', 1, true) and body:find("tags=gold", 1, true) ~= nil, body)
  local round = false
  for _, c in ipairs(import.configs_list()) do
    if c.name == "Debug Gold" then round = true break end
  end
  ok("exported entry re-parses back through configs_list", round)

  -- export with NO launch.json → creates <worktree>/.config/launch.json.
  local prev_wt = worktree.get_active()
  local fresh = fx .. "/export-fresh"
  ok("fresh repo created", make_plain_repo(fresh))
  worktree.set_active(fresh)
  store_paths.invalidate()
  local padd = store.add({ name = "Solo", kind = "debug", runtime = "go",
    program = "${worktree}/cmd/solo" })
  ok("config added to fresh repo", padd ~= nil)
  local np, nerr = import.export("Solo")
  ok("export with no launch.json creates <root>/.config/launch.json",
    type(np) == "string" and np:find("/.config/launch.json", 1, true) ~= nil
      and vim.fn.filereadable(np) == 1, tostring(nerr or np))
  worktree.set_active(prev_wt)
  store_paths.invalidate()
end

-- ── [9] mailbox verbs — run.* envelopes ─────────────────────────
print("\n[9] mailbox — run.* verb registration + envelope contracts")
local commands = require("auto-core.mailbox.commands")
local run_cmds = require("auto-run.mailbox.commands")

local reg = run_cmds.register_all()
ok("register_all registers all 19 verbs (idempotent)",
  #reg.registered == 19 and #reg.skipped == 0, vim.inspect(reg))
local expected_verbs = {
  "run.add", "run.debug_start", "run.env_list", "run.env_select",
  "run.import", "run.jobs", "run.list",
  "run.profiles_list", "run.remove", "run.results", "run.set_dir",
  "run.show", "run.start", "run.status", "run.stop", "run.test_run",
  "run.tests_list", "run.update", "run.validate",
}
ok("verb roster matches the Phase 1+2+3 (+§4.2 env) tiers exactly",
  vim.deep_equal(reg.registered, expected_verbs), vim.inspect(reg.registered))
local spec = commands.get("run.list")
ok("registry entry owned by auto-run",
  spec ~= nil and spec.owner == "auto-run")

-- Call handlers in-process against the lj fixture.
local env_list = commands.get("run.list").handler({})
ok("run.list envelope: {ok=true, value.count}",
  env_list.ok == true and env_list.value.count == 3, vim.inspect(env_list))

local env_show = commands.get("run.show").handler({ name = "Debug Gold" })
ok("run.show returns the effective config + provenance",
  env_show.ok == true and env_show.value.config.name == "Debug Gold"
    and type(env_show.value.layers) == "table")
env_show = commands.get("run.show").handler({})
ok("run.show without name → invalid_args",
  env_show.ok == false and env_show.code == "invalid_args")
env_show = commands.get("run.show").handler({ name = "ghost" })
ok("run.show unknown name → not_found",
  env_show.ok == false and env_show.code == "not_found")

local env_status = commands.get("run.status").handler({})
ok("run.status reports resolver + store state",
  env_status.ok == true
    and env_status.value.tracked == lj .. "/.auto-run"
    and env_status.value.origin == "derived"
    and env_status.value.read_through == false)
ok("run.status jobs empty before any launch",
  type(env_status.value.jobs) == "table" and next(env_status.value.jobs) == nil)

local env_add = commands.get("run.add").handler({
  config = { name = "via-mailbox", kind = "run" }, tier = "shared",
})
ok("run.add creates a config", env_add.ok == true
  and env_add.value.name == "via-mailbox")
env_add = commands.get("run.add").handler({ config = { name = "bad" } })
ok("run.add invalid config → invalid_args",
  env_add.ok == false and env_add.code == "invalid_args")

local env_up = commands.get("run.update").handler({
  name = "via-mailbox", patch = { tags = { "agent" } },
})
ok("run.update reports the layer it wrote",
  env_up.ok == true and env_up.value.layer == "shared", vim.inspect(env_up))
env_up = commands.get("run.update").handler({ name = "ghost", patch = {} })
ok("run.update unknown → not_found",
  env_up.ok == false and env_up.code == "not_found")

local env_val = commands.get("run.validate").handler({})
ok("run.validate returns the report envelope",
  env_val.ok == true and env_val.value.ok == true
    and type(env_val.value.checked) == "number")

local env_profiles = commands.get("run.profiles_list").handler({})
ok("run.profiles_list envelope",
  env_profiles.ok == true and env_profiles.value.count == 0)

local env_sd = commands.get("run.set_dir").handler({ path = fx .. "/mb-override" })
ok("run.set_dir applies the override",
  env_sd.ok == true and env_sd.value.origin == "override"
    and env_sd.value.shared == fx .. "/mb-override")
env_sd = commands.get("run.set_dir").handler({})
ok("run.set_dir with no path clears the override",
  env_sd.ok == true and env_sd.value.origin == "derived")

local env_imp = commands.get("run.import").handler({ on_conflict = "skip" })
ok("run.import envelope carries the summary",
  env_imp.ok == true and type(env_imp.value.skipped) == "table")
env_imp = commands.get("run.import").handler({ on_conflict = "banana" })
ok("run.import invalid on_conflict → invalid_args",
  env_imp.ok == false and env_imp.code == "invalid_args")

local env_rm = commands.get("run.remove").handler({ name = "via-mailbox" })
ok("run.remove removes", env_rm.ok == true and env_rm.value.removed == "via-mailbox")
env_rm = commands.get("run.remove").handler({ name = "via-mailbox" })
ok("run.remove gone → not_found",
  env_rm.ok == false and env_rm.code == "not_found")

-- :AutoRun user command (plugin file sourced manually — plugins load
-- after the -u phase in headless mode).
vim.cmd("runtime! plugin/auto-run.lua")
local ucmds = vim.api.nvim_get_commands({})
ok(":AutoRun user command registered", ucmds.AutoRun ~= nil)
ok(":AutoRun doctor runs clean (it carries the config validation that was :AutoRun validate)",
  pcall(vim.cmd, "AutoRun doctor"))

-- ═════════════════════════ Phase 2 ══════════════════════════════
-- Cross-section carriers live on ONE table (sections below run in
-- do-blocks so the main chunk stays under Lua's 200-local cap).
local P2 = {}
P2.exec = require("auto-run.exec")
P2.strategies = require("auto-run.exec.strategies")
P2.bps = require("auto-run.dap.breakpoints")

---Wait until fn() is truthy (returns the final value).
local function wait_for(fn, ms)
  vim.wait(ms or 8000, function() return fn() and true or false end, 25)
  return fn()
end

---Decode the container-store breakpoints.json → records list.
local function read_bp_store()
  local file = container .. "/.auto-run/breakpoints.json"
  if vim.fn.filereadable(file) == 0 then return {} end
  local okd, data = pcall(vim.json.decode,
    table.concat(vim.fn.readfile(file), "\n"))
  return (okd and type(data) == "table" and type(data.breakpoints) == "table")
    and data.breakpoints or {}
end

---Find a record by path+lnum in a record list.
local function find_bp(records, path, lnum)
  for _, r in ipairs(records) do
    if r.path == path and r.lnum == lnum then return r end
  end
  return nil
end

-- ── [10] exec — job engine end-to-end ───────────────────────────
print("\n[10] exec — job engine (per-run dirs, events, env, stop)")
do
  worktree.set_active(plain)
  require("auto-run.config").setup({
    env  = { dir = fx .. "/env-cache" },
    exec = { runs_dir = fx .. "/runs" },
  })
  local exec = P2.exec

  store.add({
    name = "echo-run", kind = "run", program = "sh",
    args = { "-c", "echo out-line; echo val=$SMOKE_ENV_VAL; echo err-line 1>&2; exit 3" },
    env = { SMOKE_ENV_VAL = "hello-env" },
  }, { tier = "shared" })

  local started_ev, exited_ev
  local h1 = core.events.subscribe("run.job:started", function(p) started_ev = p end)
  local h2 = core.events.subscribe("run.job:exited", function(p) exited_ev = p end)

  local launched, lerr = exec.start("echo-run")
  ok("start() launches a run-strategy job", launched ~= nil, tostring(lerr))
  ok("job record: id + pid + strategy=run",
    launched and launched.id:match("^r%d") ~= nil
      and type(launched.pid) == "number" and launched.strategy == "run",
    vim.inspect(launched))
  ok("run.job:started published with the pid",
    started_ev ~= nil and started_ev.id == launched.id
      and started_ev.config == "echo-run" and started_ev.pid == launched.pid,
    vim.inspect(started_ev))

  local done = wait_for(function() return exited_ev end)
  ok("run.job:exited published with the exit code",
    done ~= nil and done.id == launched.id and done.code == 3,
    vim.inspect(done))

  local run_dir = fx .. "/runs/" .. launched.id
  ok("per-run dir exists under the configured runs root",
    vim.fn.isdirectory(run_dir) == 1, run_dir)
  local out_txt = table.concat(vim.fn.readfile(run_dir .. "/stdout"), "\n")
  local err_txt = table.concat(vim.fn.readfile(run_dir .. "/stderr"), "\n")
  ok("stdout streamed to its own file", out_txt:find("out-line", 1, true) ~= nil, out_txt)
  ok("stderr streamed SEPARATELY", err_txt:find("err-line", 1, true) ~= nil
    and out_txt:find("err-line", 1, true) == nil, err_txt)
  ok("composed env reached the process (Phase 1 pipeline)",
    out_txt:find("val=hello-env", 1, true) ~= nil, out_txt)
  local result = vim.json.decode(
    table.concat(vim.fn.readfile(run_dir .. "/result.json"), "\n"))
  ok("result.json is the machine-readable channel (code=3)",
    result.id == launched.id and result.code == 3 and result.config == "echo-run")
  ok("result.json carries NO env values",
    vim.inspect(result):find("hello-env", 1, true) == nil)

  local jobs = exec.list()
  ok("list() sees the exited job", #jobs >= 1 and jobs[#jobs].exited == true)
  ok("job projections carry no env",
    vim.inspect(jobs):find("hello%-env") == nil)
  ok("materialized env file discarded on exit",
    vim.fn.filereadable(fx .. "/env-cache/" .. launched.id .. ".env") == 0)

  -- run_last replays the previous launch.
  exited_ev = nil
  local relaunched, rerr = exec.run_last()
  ok("run_last() replays the last launch", relaunched ~= nil
    and relaunched.id ~= launched.id, tostring(rerr))
  ok("replayed job exits too",
    wait_for(function() return exited_ev end) ~= nil)

  -- stop() — only jobs auto-run started.
  -- The fixture has to BE the two-process shape, and the cell has to wait
  -- until it actually is. Two separate traps, and the second one nearly
  -- cost the finding.
  --
  -- (1) With a SINGLE simple command every shell exec-optimises `sh -c` —
  -- it replaces itself with sleep, so there is one process and killing it
  -- closes the pipes. `sh -c "sleep 30"` is therefore the one shape stop()
  -- always handled, and this cell could only fail where /bin/sh happens
  -- NOT to optimise (a runner's dash; not this laptop's bash). A fixture
  -- that avoids the shape real `run` configs have passes everywhere and
  -- proves nothing.
  --
  -- (2) The cell then RACED THE FORK. stop() ran ~1 ms after start —
  -- measured — which is before the shell has forked anything, so there was
  -- still only one process and the kill still worked. The fixture was
  -- two-process on paper and single-process in practice, which is why
  -- reverting the group-kill left this cell green while the primitive says
  -- it cannot be.
  --
  -- So: sleep goes to the BACKGROUND and the marker is written after it,
  -- with the shell parked in `wait`. When the marker exists, the child is
  -- forked and the parent is alive — the shape is real, not merely
  -- requested — and only then do we signal.
  local sleeper_marker = fx .. "/sleeper.forked"
  vim.fn.delete(sleeper_marker)
  store.add({ name = "sleeper", kind = "run", program = "sh",
    args = { "-c", "sleep 30 & touch " .. sleeper_marker .. "; wait" } },
    { tier = "shared" })
  exited_ev = nil
  local sleeper = exec.start("sleeper")
  ok("long-running job starts", sleeper ~= nil and sleeper.pid ~= nil)
  -- Do not signal until the descendant exists; see (2) above.
  ok("sleeper reached the two-process shape before we signal it",
    wait_for(function() return vim.fn.filereadable(sleeper_marker) == 1 end) ~= nil,
    "marker never appeared: " .. sleeper_marker)
  local stop_ok, stop_err = exec.stop(sleeper.id)
  ok("stop() signals a job we started", stop_ok == true, tostring(stop_err))
  local sdone = wait_for(function() return exited_ev end)
  -- The detail has to say WHY when sdone is nil. It used to render as the
  -- bare string "nil", which is the least diagnosable failure a cell can
  -- produce: it cannot distinguish "the job never exited" from "the event
  -- never published" from "stop() signalled the wrong process", and on a
  -- machine you cannot log into, that difference is the whole investigation.
  -- CI reported exactly that string, and this is what I could not read.
  local function stop_detail()
    if sdone ~= nil then return vim.inspect(sdone) end
    local rec
    for _, r in ipairs(exec.list() or {}) do
      if r.id == sleeper.id then rec = r end
    end
    local alive = sleeper.pid
      and vim.system({ "sh", "-c", "kill -0 " .. sleeper.pid .. " 2>/dev/null" }):wait()
    -- ONE LINE, deliberately. tests/run-all.sh surfaces a failing cell with
    -- `grep -E "^  FAIL"`, so every continuation line of a multi-line detail
    -- is dropped before it reaches CI's log — which is exactly what happened
    -- to the first version of this message. A detail that only renders where
    -- you already have the output is not a detail.
    return table.concat({
      "no run.job:exited within the wait",
      "record=" .. vim.inspect(rec, { newline = " ", indent = "" }),
      "pid=" .. tostring(sleeper.pid),
      "alive=" .. tostring(alive and alive.code == 0),
      "sh=" .. (vim.uv.fs_realpath("/bin/sh") or "?"),
      "stop=" .. tostring(stop_ok) .. "/" .. tostring(stop_err),
    }, " | ")
  end
  ok("stopped job exits by signal",
    sdone ~= nil and (sdone.signal == 15 or (sdone.code or 0) ~= 0),
    stop_detail())
  local ghost_ok, ghost_err = exec.stop("r00000000-000000-9999")
  ok("stop() on an unknown id is not-found",
    ghost_ok == nil and tostring(ghost_err):find("not found", 1, true) ~= nil,
    tostring(ghost_err))

  -- No default timeout: a spawned job spec without timeout_ms passes
  -- none to vim.system (observable only as absence — the sleeper ran
  -- until signalled, not reaped by a default timeout).
  -- Same sdone, so this reddens with the cell above rather than
  -- independently — collateral, not a second defect.
  ok("no default timeout (sleeper lived until stop)", sdone ~= nil,
    "collateral of the cell above when sdone is nil")

  core.events.unsubscribe(h1)
  core.events.unsubscribe(h2)
end

-- ── [11] exec — strategies + terminal provider probe ────────────
print("\n[11] exec — strategy resolution + terminal provider")
do
  local strategies = P2.strategies

  local s = strategies.resolve("run")
  ok("kind=run defaults to strategy run", s == "run")
  ok("kind=debug defaults to dap", strategies.resolve("debug") == "dap")
  ok("kind=test defaults to run (plain test run)",
    strategies.resolve("test") == "run")
  ok("kind=test with debug=true resolves dap",
    strategies.resolve("test", { debug = true }) == "dap")
  ok("per-launch override wins",
    strategies.resolve("run", { strategy = "term" }) == "term")
  local bad, bad_err = strategies.resolve("run", { strategy = "banana" })
  ok("invalid strategy is a structured error",
    bad == nil and tostring(bad_err):find("run|term|dap") ~= nil, tostring(bad_err))

  -- Provider probe order: registered > auto-agents (absent headless)
  -- > builtin fallback.
  local _, source0 = strategies.terminal_provider()
  ok("no registered provider → builtin fallback (auto-agents absent)",
    source0 == "builtin", tostring(source0))

  local captured
  strategies.register_terminal_provider(function(spec)
    captured = spec
    return true
  end)
  local _, source1 = strategies.terminal_provider()
  ok("registered provider is preferred", source1 == "registered")

  store.add({
    name = "term-cfg", kind = "run", program = "sh",
    args = { "-c", "echo terminal" },
    env = { TERM_SECRET = "sekrit-terminal-value" },
  }, { tier = "shared" })
  local launched, lerr = P2.exec.start("term-cfg", { strategy = "term" })
  ok("term-strategy launch routes through the provider",
    launched ~= nil and launched.strategy == "term"
      and launched.provider == "registered", tostring(lerr))
  ok("provider received the spec (argv + cmdline + run id)",
    captured ~= nil and captured.cmd[1] == "sh"
      and type(captured.cmdline) == "string" and captured.run_id == launched.id,
    vim.inspect(captured and captured.cmd))
  ok("composed env arrives as a materialized env FILE",
    captured.env_file ~= nil and vim.fn.filereadable(captured.env_file) == 1)
  local est = vim.uv.fs_stat(captured.env_file)
  ok("term env file is 0600", est and bit.band(est.mode, 511) == 384)
  ok("secret VALUE never appears on the rendered command line",
    captured.cmdline:find("sekrit-terminal-value", 1, true) == nil
      and captured.cmdline:find(captured.env_file, 1, true) ~= nil,
    captured.cmdline)

  strategies.register_terminal_provider(nil)
  local _, source2 = strategies.terminal_provider()
  ok("clearing the provider restores the probe", source2 == "builtin")
end

-- ── [12] mailbox — trust-gated exec verbs (§11) ─────────────────
print("\n[12] mailbox — run.exec trust gate, ungated run.stop")
do
  trust._reset_for_tests()
  local h_start = commands.get("run.start").handler
  local h_test_run = commands.get("run.test_run").handler
  local h_debug_start = commands.get("run.debug_start").handler
  local h_stop = commands.get("run.stop").handler
  local h_jobs = commands.get("run.jobs").handler
  local h_status = commands.get("run.status").handler

  -- Untrusted → structured trust error; nothing runs.
  local env1 = h_start({ name = "echo-run" })
  ok("untrusted run.start → trust_required",
    env1.ok == false and env1.code == "trust_required", vim.inspect(env1))
  ok("trust error names the capability",
    tostring(env1.error):find("run.exec", 1, true) ~= nil)
  ok("untrusted run.test_run → trust_required",
    h_test_run({ name = "echo-run" }).code == "trust_required")
  ok("untrusted run.debug_start → trust_required",
    h_debug_start({ name = "echo-run" }).code == "trust_required")

  -- Mailbox can never force-enable (no ack → set refuses; no schema
  -- carries a force flag).
  local set_ok, set_err = trust.set("run.exec", { enabled = true })
  ok("trust.set without first-run ack refuses",
    set_ok == false and set_err == "trust_not_acknowledged", tostring(set_err))
  for _, verb in ipairs({ "run.start", "run.test_run", "run.debug_start", "run.stop" }) do
    local schema = commands.get(verb).schema or {}
    local clean = true
    for k in pairs(schema) do
      if tostring(k):lower():find("force") or tostring(k):lower():find("bypass") then
        clean = false
      end
    end
    ok(verb .. " schema carries NO force/bypass flag", clean, vim.inspect(schema))
  end

  -- Interactive ack + enable → the verb runs.
  trust.acknowledge_first_run("run.exec")
  ok("trust.set after ack succeeds", trust.set("run.exec", { enabled = true }) == true)

  local exited_ev
  local h_ev = core.events.subscribe("run.job:exited", function(p) exited_ev = p end)
  local env2 = h_start({ name = "echo-run" })
  ok("trusted run.start launches", env2.ok == true and env2.value.id ~= nil,
    vim.inspect(env2))
  ok("verb response carries no env values",
    vim.inspect(env2):find("hello%-env") == nil)
  ok("mailbox-started job exits",
    wait_for(function() return exited_ev and exited_ev.id == env2.value.id end) ~= nil)

  -- Allowlist scopes trust to config-name patterns.
  trust.set("run.exec", { allowlist = { "^echo%-" } })
  local env3 = h_start({ name = "sleeper" })
  ok("allowlist-rejected config → trust_required",
    env3.ok == false and env3.code == "trust_required"
      and tostring(env3.error):find("allowlist_rejected", 1, true) ~= nil,
    vim.inspect(env3))
  trust.set("run.exec", { allowlist = false })

  -- test_run: Phase 2 scope is kind=test configs only.
  local env4 = h_test_run({ name = "echo-run" })
  ok("run.test_run on a kind=run config → invalid_args",
    env4.ok == false and env4.code == "invalid_args"
      and tostring(env4.error):find("kind=test", 1, true) ~= nil,
    vim.inspect(env4))
  store.add({ name = "pkg-tests", kind = "test", runtime = "go",
    build_flags = "-count=1", program = "./..." }, { tier = "shared" })
  exited_ev = nil
  local env5 = h_test_run({ name = "pkg-tests" })
  ok("run.test_run on a kind=test config launches `go test` on the package",
    env5.ok == true
      and vim.deep_equal(env5.value.cmd, { "go", "test", "-count=1", "./..." }),
    vim.inspect(env5))
  ok("test job exits",
    wait_for(function() return exited_ev and exited_ev.id == env5.value.id end) ~= nil)

  -- test_name/package plumbed through to the argv.
  exited_ev = nil
  local env5b = h_test_run({ name = "pkg-tests", package = "./pkg/x", test_name = "TestFoo" })
  ok("run.test_run plumbs test_name + package into the argv",
    env5b.ok == true and vim.deep_equal(env5b.value.cmd,
      { "go", "test", "-count=1", "-run", "^TestFoo$", "./pkg/x" }),
    vim.inspect(env5b))
  wait_for(function() return exited_ev and exited_ev.id == env5b.value.id end)

  -- run.debug_start reaches the exec layer once trusted (structured
  -- not_found for unknown configs; a live dap session needs an
  -- adapter + UI, out of headless scope).
  local env6 = h_debug_start({ name = "no-such-config" })
  ok("trusted run.debug_start unknown config → not_found",
    env6.ok == false and env6.code == "not_found", vim.inspect(env6))

  -- run.stop is UNGATED: disable exec trust, stop a live job.
  local sleeper = P2.exec.start("sleeper")
  ok("live job for the stop test", sleeper ~= nil)
  local env_status = h_status({})
  local live_seen = false
  for _, j in ipairs(env_status.value.jobs) do
    if j.id == sleeper.id then live_seen = true end
  end
  ok("run.status includes live jobs", env_status.ok == true and live_seen,
    vim.inspect(env_status.value.jobs))

  trust.set("run.exec", { enabled = false })
  exited_ev = nil
  local env7 = h_stop({ id = sleeper.id })
  ok("run.stop works with exec trust DISABLED (ungated)",
    env7.ok == true and env7.value.stopped == sleeper.id, vim.inspect(env7))
  wait_for(function() return exited_ev and exited_ev.id == sleeper.id end)
  local env8 = h_stop({ id = "r19990101-000000-0001" })
  ok("run.stop foreign/unknown id → not_found",
    env8.ok == false and env8.code == "not_found", vim.inspect(env8))

  local env9 = h_jobs({})
  ok("run.jobs lists the session inventory",
    env9.ok == true and env9.value.count >= 4
      and env9.value.jobs[1].id ~= nil, vim.inspect(env9.value.count))

  -- Re-enable for nothing further — leave trust OFF (default-deny).
  core.events.unsubscribe(h_ev)
end

-- ── [13] breakpoints — API persistence (real nvim-dap) ──────────
print("\n[13] breakpoints — §9 store, API mutations persist synchronously")
do
  local okd, dap = pcall(require, "dap")
  ok("real nvim-dap on rtp", okd, tostring(dap))

  -- Re-run setup with dap present: provider + listeners + sync points.
  ok("setup() re-wires with dap present", auto_run.setup() == true)
  ok("dap.providers.configs['auto-run'] registered (never dap.configurations)",
    dap.providers.configs["auto-run"] ~= nil)
  ok("winfixbuf guard listener registered",
    dap.listeners.before.event_stopped["auto-run-avoid-winfixbuf"] ~= nil)
  ok("failed-start capture listeners registered",
    dap.listeners.after.event_output["auto-run-errors"] ~= nil)
  ok("breakpoint session-boundary listeners registered",
    dap.listeners.before.launch["auto-run-breakpoints"] ~= nil)

  -- Provider emits lazy configs for matching-filetype buffers.
  worktree.set_active(plain)
  local go_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[go_buf].filetype = "go"
  local provided = require("auto-run.dap").provider(go_buf)
  local echo_entry
  for _, c in ipairs(provided) do
    if c.name == "[auto-run] echo-run" then echo_entry = c end
  end
  ok("provider emits store configs for the buffer's filetype",
    echo_entry ~= nil, vim.inspect(#provided))
  ok("provider fields are function-valued (lazy)",
    echo_entry and type(echo_entry.program) == "function")
  ok("lazy field resolves through merge+substitution on evaluation",
    echo_entry and echo_entry.program() == "sh")

  -- default_keymaps: the ADR 0199 §4.2 table (amending ADR-0048 §10)
  -- registered with desc strings. Global maps only — the go-only attach keys
  -- are buffer-local and asserted in [36i].
  auto_run.default_keymaps()
  local descs = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.desc then descs[m.desc] = true end
  end
  local expected_descs = {
    "Run: Nearest Test", "Debug: Nearest Test",
    "Run: Current Test File", "Debug: Choose a Test in This File",
    "Run: Pick an Entry Point", "Debug: Pick an Entry Point",
    "Run: Again (last run)", "Debug: Again (last debug)",
    "Debug: Toggle Breakpoint", "Debug: Conditional Breakpoint",
    "Debug: Clear Breakpoints", "Debug: Continue (resume only)",
    "Debug: Step Into", "Debug: Step Over", "Debug: Step Out",
    "Debug: Terminate", "Debug: Restart",
    "Run: Continue / Start (dap)", "Run: Step Over (dap)",
    "Run: Step Into (dap)", "Run: Step Out (dap)",
  }
  local missing = {}
  for _, d in ipairs(expected_descs) do
    if not descs[d] then missing[#missing + 1] = d end
  end
  ok("§4.2 keymap table registered (desc on everything)",
    #missing == 0, vim.inspect(missing))

  -- Breakpoint persistence in the linked-worktree fixture.
  local main_wt = container .. "/main"
  vim.fn.mkdir(main_wt .. "/src", "p")
  local lines = {}
  for i = 1, 10 do lines[i] = ("local line_%d = %d"):format(i, i) end
  write_file(main_wt .. "/src/app.lua", table.concat(lines, "\n") .. "\n")
  ok("app fixture committed",
    git(main_wt, "add", ".") and git(main_wt, "commit", "-q", "-m", "app"))
  ok("second worktree created",
    git(fx, "--git-dir=" .. container .. "/.bare", "worktree", "add", "-q",
      "-b", "smoke-wt2", container .. "/wt2", "main"))

  worktree.set_active(main_wt)
  local dirs = store.resolve_run_dirs()
  ok("shared tier is the container store", dirs.shared == container .. "/.auto-run")

  vim.cmd.edit(main_wt .. "/src/app.lua")
  local app_buf = vim.api.nvim_get_current_buf()
  P2.app_buf = app_buf

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local t_ok, t_err = P2.bps.toggle()
  ok("API toggle succeeds", t_ok == true, tostring(t_err))
  local records = read_bp_store()
  ok("toggle persists SYNCHRONOUSLY to <container>/.auto-run/breakpoints.json",
    #records == 1 and records[1].path == "src/app.lua" and records[1].lnum == 3,
    vim.inspect(records))

  vim.api.nvim_win_set_cursor(0, { 5, 0 })
  P2.bps.set({ condition = "x > 1" })
  records = read_bp_store()
  local cond_rec = find_bp(records, "src/app.lua", 5)
  ok("conditional breakpoint persists its condition",
    #records == 2 and cond_rec ~= nil and cond_rec.condition == "x > 1",
    vim.inspect(records))

  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  P2.bps.toggle()   -- off
  records = read_bp_store()
  ok("toggle-off removes the record", #records == 1
    and find_bp(records, "src/app.lua", 3) == nil, vim.inspect(records))

  local stats = P2.bps.stats()
  ok("stats() reports the store",
    stats.file == container .. "/.auto-run/breakpoints.json"
      and stats.count == 1 and stats.files == 1, vim.inspect(stats))

  -- ── remove(path, lnum): cursor-independent single removal ──────
  -- toggle/set act at the cursor and clear_all is all-or-nothing, so this is
  -- the only way to drop ONE known breakpoint. Both branches are exercised,
  -- because the store's rule ("live wins for loaded paths") makes the loaded
  -- and unloaded cases genuinely different code paths.
  ok("remove() rejects a bad path", (P2.bps.remove("", 3)) == nil)
  ok("remove() rejects a non-integer lnum",
    (P2.bps.remove("src/app.lua", 0)) == nil
      and (P2.bps.remove("src/app.lua", 1.5)) == nil)

  -- (a) LOADED buffer. Control first: the record is present before we act,
  -- otherwise "gone afterwards" would pass against an empty store.
  ok("remove() CONTROL — the target record exists before removal",
    find_bp(read_bp_store(), "src/app.lua", 5) ~= nil)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })   -- cursor deliberately elsewhere
  local r_ok, r_err = P2.bps.remove("src/app.lua", 5)
  ok("remove() succeeds on a loaded buffer regardless of cursor",
    r_ok == true, tostring(r_err))
  ok("remove() drops the record from the store",
    find_bp(read_bp_store(), "src/app.lua", 5) == nil,
    vim.inspect(read_bp_store()))
  ok("remove() also clears nvim-dap's live registry for that line",
    (function()
      local okb, dbp = pcall(require, "dap.breakpoints")
      if not okb then return false end
      for _, bp in ipairs((dbp.get(P2.app_buf) or {})[P2.app_buf] or {}) do
        if bp.line == 5 then return false end
      end
      return true
    end)())

  -- (b) UNLOADED path — nvim-dap holds nothing, and reconcile deliberately
  -- preserves records for unloaded files, so this must go through the store.
  write_file(main_wt .. "/src/other.lua", "local a = 1\nlocal b = 2\nlocal c = 3\n")
  vim.cmd.edit(main_wt .. "/src/other.lua")
  local other_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  P2.bps.toggle()
  ok("remove() CONTROL — a record exists for the second file",
    find_bp(read_bp_store(), "src/other.lua", 2) ~= nil,
    vim.inspect(read_bp_store()))
  vim.cmd.edit(main_wt .. "/src/app.lua")
  pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
  ok("remove() CONTROL — that file's buffer is now unloaded",
    vim.fn.bufloaded(main_wt .. "/src/other.lua") == 0)
  local u_ok, u_err = P2.bps.remove("src/other.lua", 2)
  ok("remove() succeeds for an unloaded path", u_ok == true, tostring(u_err))
  ok("remove() drops the unloaded file's record from the store",
    find_bp(read_bp_store(), "src/other.lua", 2) == nil,
    vim.inspect(read_bp_store()))

  ok("remove() is a no-op (not an error) when nothing matches",
    (P2.bps.remove("src/other.lua", 99)) == true)
end

-- ── [14] breakpoints — reconcile sweep ──────────────────────────
print("\n[14] breakpoints — reconcile sweep + tunables")
do
  local dap = require("dap")
  local bp_ev
  local h_ev = core.events.subscribe("run.breakpoints:changed",
    function(p) bp_ev = p end)

  -- Direct nvim-dap mutation (bypasses auto-run's API) …
  vim.api.nvim_set_current_buf(P2.app_buf)
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  dap.toggle_breakpoint()
  local records = read_bp_store()
  ok("direct dap toggle is NOT yet persisted", find_bp(records, "src/app.lua", 7) == nil)

  -- … the sweep persists it.
  local changed = P2.bps.reconcile()
  records = read_bp_store()
  ok("reconcile() persists direct dap mutations",
    changed == true and find_bp(records, "src/app.lua", 7) ~= nil,
    vim.inspect(records))
  ok("run.breakpoints:changed published with action=reconcile",
    bp_ev ~= nil and bp_ev.action == "reconcile", vim.inspect(bp_ev))

  -- Entries for files with NO loaded buffer survive the sweep.
  local raw = vim.json.decode(table.concat(
    vim.fn.readfile(container .. "/.auto-run/breakpoints.json"), "\n"))
  table.insert(raw.breakpoints,
    { path = "src/ghost.lua", lnum = 1, enabled = true })
  write_file(container .. "/.auto-run/breakpoints.json", vim.json.encode(raw))
  local changed2 = P2.bps.reconcile()
  records = read_bp_store()
  ok("sweep keeps records for unloaded files (diff scope = loaded buffers)",
    changed2 == false and find_bp(records, "src/ghost.lua", 1) ~= nil,
    vim.inspect(records))

  -- CursorHold → debounced sweep (wiring end-to-end).
  vim.api.nvim_win_set_cursor(0, { 9, 0 })
  dap.toggle_breakpoint()
  vim.api.nvim_exec_autocmds("CursorHold", {})
  local swept = wait_for(function()
    return find_bp(read_bp_store(), "src/app.lua", 9)
  end, 5000)
  ok("CursorHold debounce sweeps within the window", swept ~= nil)

  -- Tunable full-disable: editing-time sweeps off, boundary flushes stay.
  require("auto-run.config").setup({
    env  = { dir = fx .. "/env-cache" },
    exec = { runs_dir = fx .. "/runs" },
    breakpoint_sync = { cursorhold = false },
  })
  P2.bps.setup()
  local function count_auto(event)
    return #vim.api.nvim_get_autocmds({ group = "AutoRunBreakpoints", event = event })
  end
  ok("cursorhold=false removes the CursorHold sweep", count_auto("CursorHold") == 0)
  ok("cursorhold=false removes the BufWritePost sweep", count_auto("BufWritePost") == 0)
  ok("VimLeavePre exit flush STAYS active when disabled", count_auto("VimLeavePre") == 1)
  ok("BufReadPost restore stays active", count_auto("BufReadPost") == 1)
  ok("session-boundary flush listener stays active",
    require("dap").listeners.before.launch["auto-run-breakpoints"] ~= nil)

  -- interval_ms sweep.
  require("auto-run.config").setup({
    env  = { dir = fx .. "/env-cache" },
    exec = { runs_dir = fx .. "/runs" },
    breakpoint_sync = { cursorhold = false, interval_ms = 100 },
  })
  P2.bps.setup()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  dap.toggle_breakpoint()
  local interval_swept = wait_for(function()
    return find_bp(read_bp_store(), "src/app.lua", 2)
  end, 5000)
  ok("interval_ms periodic sweep persists direct mutations", interval_swept ~= nil)

  -- Restore the default sync config for the remaining sections.
  require("auto-run.config").setup({
    env  = { dir = fx .. "/env-cache" },
    exec = { runs_dir = fx .. "/runs" },
  })
  P2.bps.setup()
  core.events.unsubscribe(h_ev)

  -- clear_all wipes live + store (incl. unloaded-file records).
  P2.bps.clear_all()
  ok("clear_all empties the store (incl. unloaded files)", #read_bp_store() == 0)
  local live = require("dap.breakpoints").get()
  local live_count = 0
  for _, bps_list in pairs(live) do live_count = live_count + #bps_list end
  ok("clear_all empties the live registry", live_count == 0)
end

-- ── [15] breakpoints — stale-line drop on restore ───────────────
print("\n[15] breakpoints — restore + stale-lnum drop")
do
  local main_wt = container .. "/main"
  write_file(main_wt .. "/src/stale.lua", "-- one\n-- two\n-- three\n")
  write_file(main_wt .. "/src/fresh.lua", "-- one\n-- two\n-- three\n-- four\n")

  -- Seed the store directly (simulates a previous session).
  write_file(container .. "/.auto-run/breakpoints.json", vim.json.encode({
    version = 1,
    breakpoints = {
      { path = "src/stale.lua", lnum = 99, enabled = true },
      { path = "src/fresh.lua", lnum = 2, enabled = true, condition = "y == 2" },
    },
  }))

  vim.cmd.edit(main_wt .. "/src/fresh.lua")
  local fresh_buf = vim.api.nvim_get_current_buf()
  local live = require("dap.breakpoints").get(fresh_buf)[fresh_buf] or {}
  ok("restore applies persisted breakpoints on BufReadPost",
    #live == 1 and live[1].line == 2, vim.inspect(live))
  ok("restore preserves the condition", live[1] and live[1].condition == "y == 2")

  vim.cmd.edit(main_wt .. "/src/stale.lua")
  local stale_buf = vim.api.nvim_get_current_buf()
  local stale_live = require("dap.breakpoints").get(stale_buf)[stale_buf]
  ok("stale lnum (99 > 3 lines) is NOT applied",
    stale_live == nil or #stale_live == 0, vim.inspect(stale_live))
  local records = read_bp_store()
  ok("stale record dropped from the store (with a warn log)",
    find_bp(records, "src/stale.lua", 99) == nil, vim.inspect(records))
  ok("fresh record survives the drop rewrite",
    find_bp(records, "src/fresh.lua", 2) ~= nil)
end

-- ── [16] breakpoints — rehydration across two worktrees ─────────
print("\n[16] breakpoints — worktree-relative paths, one container store")
do
  local wt2 = container .. "/wt2"
  ok("wt2 checkout has the committed app file",
    vim.fn.filereadable(wt2 .. "/src/app.lua") == 1)

  -- Save a set while MAIN is active.
  worktree.set_active(container .. "/main")
  write_file(container .. "/.auto-run/breakpoints.json", vim.json.encode({
    version = 1,
    breakpoints = {
      { path = "src/app.lua", lnum = 5, enabled = true, condition = "x > 1" },
      { path = "src/app.lua", lnum = 7, enabled = true },
    },
  }))

  -- Switch to WT2 — same container store, paths re-anchor.
  worktree.set_active(wt2)
  local dirs = store.resolve_run_dirs()
  ok("wt2 resolves to the SAME shared store",
    dirs.shared == container .. "/.auto-run" and dirs.root == wt2,
    vim.inspect(dirs))

  vim.cmd.edit(wt2 .. "/src/app.lua")
  local buf2 = vim.api.nvim_get_current_buf()
  local live = require("dap.breakpoints").get(buf2)[buf2] or {}
  table.sort(live, function(a, b) return a.line < b.line end)
  ok("saved set rehydrates in the sibling worktree",
    #live == 2 and live[1].line == 5 and live[2].line == 7, vim.inspect(live))
  ok("condition rehydrates too", live[1] and live[1].condition == "x > 1")

  -- And the reconcile sweep in wt2 keeps the store worktree-relative.
  P2.bps.reconcile()
  local records = read_bp_store()
  ok("post-sweep records stay worktree-RELATIVE",
    find_bp(records, "src/app.lua", 5) ~= nil
      and find_bp(records, "src/app.lua", 7) ~= nil, vim.inspect(records))
end

-- :AutoRun Phase 2 subcommands (plugin file already sourced in [9]).
print("\n[17] :AutoRun — Phase 2 subcommands + doctor additions")
do
  ok(":AutoRun doctor (with dap + breakpoint sections) runs clean",
    pcall(vim.cmd, "AutoRun doctor"))
  local okc = pcall(vim.cmd, "AutoRun stop not-a-job")
  ok(":AutoRun stop unknown id errors gracefully", okc)
end

-- ── [18] store — corrupt overrides.json is FATAL (layer 6) ──────
print("\n[18] store — corrupt overrides.json fails get/show/validate/start")
do
  worktree.set_active(plain)
  local ofile = plain .. "/.auto-run/local/overrides.json"
  local original = table.concat(vim.fn.readfile(ofile), "\n")
  write_file(ofile, "{ this is not json !!")

  -- get() of ANY config fails — the overlay is meaningful config.
  local eff, gerr = store.get("go-base")
  ok("store.get fails on a corrupt overrides layer", eff == nil)
  ok("…with structured code=overrides_corrupt + file",
    type(gerr) == "table" and gerr.code == "overrides_corrupt"
      and gerr.file == ofile, vim.inspect(gerr))
  ok("…that stringifies to a readable message",
    tostring(gerr):find("overrides layer unreadable", 1, true) ~= nil,
    tostring(gerr))

  -- list() annotates every entry rather than aborting the listing.
  local inv = store.list()
  local annotated = #inv > 0
  for _, c in ipairs(inv) do
    if not (type(c.error) == "table" and c.error.code == "overrides_corrupt") then
      annotated = false
    end
  end
  ok("store.list annotates every config with the overrides error",
    annotated, vim.inspect(inv))

  -- run.show surfaces the code through the envelope.
  local env_show = commands.get("run.show").handler({ name = "go-base" })
  ok("run.show surfaces code=overrides_corrupt",
    env_show.ok == false and env_show.code == "overrides_corrupt",
    vim.inspect(env_show))

  -- validate() reports the file (parse issue).
  local report = store.validate()
  local flagged = false
  for _, issue in ipairs(report.issues) do
    if issue.file == ofile then flagged = true end
  end
  ok("validate() reports the overrides.json file",
    report.ok == false and flagged, vim.inspect(report.issues))
  local env_val = commands.get("run.validate").handler({})
  local verb_flagged = false
  for _, issue in ipairs(env_val.value and env_val.value.issues or {}) do
    if issue.file == ofile then verb_flagged = true end
  end
  ok("run.validate reports the file too",
    env_val.ok == true and verb_flagged, vim.inspect(env_val))

  -- exec refuses to launch on a corrupt overrides layer.
  local launched, lerr, detail = P2.exec.start("go-base")
  ok("exec.start refuses to launch",
    launched == nil and type(detail) == "table"
      and detail.code == "overrides_corrupt", tostring(lerr))

  -- …and the trust-gated mailbox verb maps the code ([12] ack'd).
  trust.set("run.exec", { enabled = true })
  local env_start = commands.get("run.start").handler({ name = "go-base" })
  ok("run.start refuses with code=overrides_corrupt",
    env_start.ok == false and env_start.code == "overrides_corrupt",
    vim.inspect(env_start))
  trust.set("run.exec", { enabled = false })

  -- Shape issues (valid JSON, non-object entry) surface in validate().
  write_file(ofile, '{ "go-base": "not-an-object" }')
  report = store.validate()
  local shape_flagged = false
  for _, issue in ipairs(report.issues) do
    if issue.file == ofile then
      for _, e in ipairs(issue.errors) do
        if e:find("must be a JSON object", 1, true) then shape_flagged = true end
      end
    end
  end
  ok("validate() flags a non-object overrides entry",
    shape_flagged, vim.inspect(report.issues))

  write_file(ofile, original .. "\n")
  ok("restored overrides → get() recovers",
    store.get("go-base") ~= nil)
end

-- ── [19] exec — term strategy env-file cleanup lifecycle ────────
print("\n[19] exec — term env-file cleanup (should-fix, §4.1)")
do
  worktree.set_active(plain)
  local strategies = P2.strategies

  -- Provider failure → the materialized file is discarded NOW.
  local failed_spec
  strategies.register_terminal_provider(function(spec)
    failed_spec = spec
    return nil, "provider exploded"
  end)
  local launched, lerr = P2.exec.start("term-cfg", { strategy = "term" })
  ok("provider failure fails the launch",
    launched == nil and tostring(lerr):find("provider exploded", 1, true) ~= nil,
    tostring(lerr))
  ok("provider saw a materialized env file",
    failed_spec ~= nil and failed_spec.env_file ~= nil)
  ok("env file discarded immediately on provider failure",
    failed_spec and vim.fn.filereadable(failed_spec.env_file) == 0)

  -- Provider success: the cleanup hook rides in the spec; invoking it
  -- (terminal session end) discards the file.
  local live_spec
  strategies.register_terminal_provider(function(spec)
    live_spec = spec
    return true
  end)
  local launched2, lerr2 = P2.exec.start("term-cfg", { strategy = "term" })
  ok("term launch succeeds", launched2 ~= nil, tostring(lerr2))
  ok("cleanup hook handed to the provider (spec.on_exit)",
    live_spec ~= nil and type(live_spec.on_exit) == "function")
  ok("env file live while the session runs",
    vim.fn.filereadable(live_spec.env_file) == 1)
  live_spec.on_exit()
  ok("provider-invoked cleanup discards the env file",
    vim.fn.filereadable(live_spec.env_file) == 0)
  ok("cleanup hook is idempotent", pcall(live_spec.on_exit) == true)

  strategies.register_terminal_provider(nil)
end

-- ── [20] breakpoints — corrupt breakpoints.json diagnostics ─────
print("\n[20] breakpoints — corrupt store surfaces, never overwritten")
do
  worktree.set_active(container .. "/main")
  local bfile = container .. "/.auto-run/breakpoints.json"
  local corrupt = "{ definitely not json ]]"
  write_file(bfile, corrupt)
  local function slurp(p)
    local f = assert(io.open(p, "r"))
    local s = f:read("*a")
    f:close()
    return s
  end

  local stats = P2.bps.stats()
  ok("stats() surfaces the read error",
    type(stats.error) == "string"
      and stats.error:find("invalid JSON", 1, true) ~= nil, vim.inspect(stats))
  ok("stats() reports zero counts alongside the error",
    stats.count == 0 and stats.files == 0)

  -- restore(): applies nothing, writes nothing.
  vim.cmd.edit(container .. "/main/src/app.lua")
  local buf = vim.api.nvim_get_current_buf()
  local applied = P2.bps.restore(buf)
  ok("restore() skips a corrupt store (applies nothing)", applied == 0)
  ok("restore() left the corrupt file byte-identical",
    slurp(bfile) == corrupt)

  -- reconcile(): live registry untouched, store never overwritten.
  local live_before = vim.deepcopy(require("dap.breakpoints").get())
  local changed, count = P2.bps.reconcile()
  ok("reconcile() refuses to write over a corrupt store",
    changed == false and count == 0)
  ok("reconcile() left the corrupt file byte-identical",
    slurp(bfile) == corrupt)
  ok("live registry untouched by the skipped reconcile",
    vim.deep_equal(require("dap.breakpoints").get(), live_before))

  -- Diagnostics render it: doctor + run.status.
  local doc = vim.api.nvim_exec2("AutoRun doctor", { output = true }).output
  ok(":AutoRun doctor mentions the corrupt breakpoint store",
    doc:find("invalid JSON", 1, true) ~= nil)
  local env_status = commands.get("run.status").handler({})
  ok("run.status carries breakpoint stats with the error",
    env_status.ok == true
      and type(env_status.value.breakpoints) == "table"
      and tostring(env_status.value.breakpoints.error)
        :find("invalid JSON", 1, true) ~= nil,
    vim.inspect(env_status.value and env_status.value.breakpoints))

  -- Restore a valid empty store for a clean exit flush.
  write_file(bfile, vim.json.encode({ version = 1, breakpoints = {} }) .. "\n")
end

-- ═════════════════════════ Phase 3 ══════════════════════════════
-- Cross-section carriers (same pattern as P2).
local P3 = {}
P3.adapters = require("auto-run.adapters")
P3.discovery = require("auto-run.discovery")

-- ── [21] adapters — registry + interface (§7) ───────────────────
print("\n[21] adapters — registry, interface validation, third parties")
do
  local adapters = P3.adapters
  adapters._reset_for_tests()

  local names = {}
  for _, a in ipairs(adapters.list()) do names[#names + 1] = a.name end
  ok("builtin roster is go + playwright + jest + rust + dart + node (registration order)",
    vim.deep_equal(names, { "go", "playwright", "jest", "rust", "dart", "node" }), vim.inspect(names))

  local go = adapters.get("go")
  local iface_ok = go ~= nil
  for _, fname in ipairs({ "root", "is_test_file", "discover_positions",
    "build_spec", "results", "filter_dir" }) do
    if not go or type(go[fname]) ~= "function" then iface_ok = false end
  end
  ok("go adapter implements the AutoRunAdapter interface", iface_ok)

  local bad_ok, bad_err = adapters.register_adapter({ name = "broken" })
  ok("register_adapter rejects a shape missing the interface",
    bad_ok == nil and tostring(bad_err):find("must be a function") ~= nil,
    tostring(bad_err))
  ok("register_adapter rejects non-tables",
    select(2, adapters.register_adapter("nope")) ~= nil)

  local fake = {
    name = "fake",
    root = function() return nil end,
    is_test_file = function(p) return p:match("%.fake$") ~= nil end,
    discover_positions = function() return nil end,
    build_spec = function() return nil end,
    results = function() return {} end,
  }
  ok("third-party register_adapter succeeds",
    adapters.register_adapter(fake) == true)
  ok("adapter_for routes to the third-party adapter",
    adapters.adapter_for("/x/y.fake") == fake)
  ok("adapter_for still routes go files to the go adapter",
    adapters.adapter_for("/x/y_test.go") == adapters.get("go"))
  ok("adapter_for is nil for unclaimed files",
    adapters.adapter_for("/x/y.txt") == nil)

  adapters._reset_for_tests()
  ok("registry reset restores the builtin roster lazily",
    adapters.get("go") ~= nil and adapters.get("fake") == nil)
end

-- ── [22] discovery — go fixture + position tree ─────────────────
print("\n[22] discovery — go tree, ids, O(1) lookup, child-repo pruning")
local gofix = fx .. "/gofix"
local calc_test = gofix .. "/calc/calc_test.go"
local nested_test = gofix .. "/nestedmod/n_test.go"
do
  ok("go fixture repo created", make_plain_repo(gofix))
  write_file(gofix .. "/go.mod", "module example.com/gofix\n\ngo 1.21\n")
  write_file(gofix .. "/calc/calc.go", [[
package calc

func Add(a, b int) int { return a + b }
]])
  write_file(calc_test, [[
package calc

import (
	"fmt"
	"testing"
)

func TestMain(m *testing.M) {
	m.Run()
}

func TestAdd(t *testing.T) {
	t.Run("sub one", func(t *testing.T) {
		if Add(1, 2) != 3 {
			t.Fatal("nope")
		}
	})
	t.Run("group", func(t *testing.T) {
		t.Run("inner", func(t *testing.T) {
			if Add(2, 2) != 4 {
				t.Fatal("nope")
			}
		})
	})
}

func TestFail(t *testing.T) {
	t.Fatal("boom: intentional failure")
}

func TestSkipped(t *testing.T) {
	t.Skip("not today")
}

func ExampleAdd() {
	fmt.Println(Add(1, 1))
	// Output: 2
}

func ExampleAdd_noOutput() {
	_ = Add(0, 0)
}
]])
  -- Nested go.mod module (primary-root cache exercise).
  write_file(gofix .. "/nestedmod/go.mod", "module example.com/nested\n\ngo 1.21\n")
  write_file(nested_test, [[
package nested

import "testing"

func TestNested(t *testing.T) {
	if 1+1 != 2 {
		t.Fatal("math broke")
	}
}
]])
  -- Nested CHILD REPO (immediate child — list_child_repos sees it).
  ok("nested child repo created", make_plain_repo(gofix .. "/childrepo"))
  write_file(gofix .. "/childrepo/child_test.go", [[
package child

import "testing"

func TestChild(t *testing.T) {}
]])
  -- DEEP nested repo (NOT an immediate child — only the walk's own
  -- .git pruning can catch it).
  ok("deep nested repo created", make_plain_repo(gofix .. "/deep/innerrepo"))
  write_file(gofix .. "/deep/innerrepo/deep_test.go", [[
package deep

import "testing"

func TestDeep(t *testing.T) {}
]])
  -- vendor/ (adapter filter_dir pruning).
  write_file(gofix .. "/vendor/v_test.go", [[
package v

import "testing"

func TestVendored(t *testing.T) {}
]])

  worktree.set_active(gofix)
  P3.discovery._reset_for_tests()
  require("auto-run.adapters.go")._reset_for_tests()

  local report
  P3.discovery.scan(nil, function(r) report = r end)
  wait_for(function() return report end)
  ok("scan completes", report ~= nil and report.status == "complete",
    vim.inspect(report))
  ok("scan parsed exactly the two module test files",
    report.parsed == 2, vim.inspect(report))
  ok("scan discovered two adapter roots (module + nested module)",
    report.roots == 2, vim.inspect(report))
  ok("scan reports zero parse errors", #report.errors == 0,
    vim.inspect(report.errors))

  local tree = P3.discovery.tree()
  ok("tree anchors at the active worktree", tree.root.path == gofix)

  -- O(1) id lookup on the flat _nodes map.
  local file_node = tree:get(calc_test)
  ok("file id = path (O(1) lookup)",
    file_node ~= nil and file_node.type == "file" and file_node.adapter == "go")
  local t_add = tree:get(calc_test .. "::TestAdd")
  ok("test id = path::name", t_add ~= nil and t_add.type == "test"
    and t_add.name == "TestAdd" and type(t_add.lnum) == "number")
  local sub = tree:get(calc_test .. "::TestAdd::sub one")
  ok("t.Run subtest id = path::TestAdd::sub one",
    sub ~= nil and sub.type == "test" and sub.name == "sub one")
  local inner = tree:get(calc_test .. "::TestAdd::group::inner")
  ok("NESTED t.Run id = path::TestAdd::group::inner",
    inner ~= nil and inner.type == "test")
  ok("TestMain is excluded from discovery",
    tree:get(calc_test .. "::TestMain") == nil)
  ok("Example* funcs are discovered",
    tree:get(calc_test .. "::ExampleAdd") ~= nil
      and tree:get(calc_test .. "::ExampleAdd_noOutput") ~= nil)

  -- Hierarchy: root dir → calc dir → file → test → subtest.
  ok("dir chain hierarchy (root → calc → file)",
    file_node.parent ~= nil and file_node.parent.id == gofix .. "/calc"
      and file_node.parent.parent == tree.root)
  ok("subtest hangs off its parent test",
    sub.parent == t_add and inner.parent ~= nil
      and inner.parent.id == calc_test .. "::TestAdd::group")

  -- Pruning: child repos (immediate + deep) and vendor NEVER appear.
  ok("immediate child repo pruned (list_child_repos + .git entry)",
    tree:get(gofix .. "/childrepo/child_test.go") == nil
      and tree:get(gofix .. "/childrepo") == nil)
  ok("DEEP nested repo pruned by the walk's own .git check",
    tree:get(gofix .. "/deep/innerrepo/deep_test.go") == nil)
  ok("vendor/ pruned by adapter filter_dir",
    tree:get(gofix .. "/vendor/v_test.go") == nil)

  -- Nested module resolves its OWN root (primary-root cache).
  local go = P3.adapters.get("go")
  ok("go.root at calc → the umbrella module", go.root(gofix .. "/calc") == gofix)
  ok("go.root at nestedmod → the nested module",
    go.root(gofix .. "/nestedmod") == gofix .. "/nestedmod")
  ok("nested module file discovered under its own dir",
    tree:get(nested_test) ~= nil)

  -- build_spec: ^-anchored slash-split -run regex per position type.
  local spec = go.build_spec({ position = inner, tree = tree, root = gofix,
    run_id = "spec-probe", run_dir = fx .. "/spec-probe" })
  ok("test spec: slash-split ^-anchored -run regex (spaces → _)",
    spec ~= nil and vim.deep_equal(spec.cmd,
      { "go", "test", "-json", "-run", "^TestAdd$/^group$/^inner$", "./calc" }),
    vim.inspect(spec and spec.cmd))
  local sub_spec = go.build_spec({ position = sub, tree = tree, root = gofix,
    run_id = "spec-probe", run_dir = fx .. "/spec-probe" })
  ok("subtest with spaces maps to underscores in -run",
    sub_spec ~= nil and sub_spec.cmd[5] == "^TestAdd$/^sub_one$",
    vim.inspect(sub_spec and sub_spec.cmd))
  local f_spec = go.build_spec({ position = file_node, tree = tree, root = gofix,
    run_id = "spec-probe", run_dir = fx .. "/spec-probe" })
  ok("file spec: top-level alternation regex",
    f_spec ~= nil and f_spec.cmd[4] == "-run"
      and f_spec.cmd[5]:match("^%^%(") ~= nil
      and f_spec.cmd[5]:find("TestAdd", 1, true) ~= nil
      and f_spec.cmd[5]:find("TestFail", 1, true) ~= nil
      and f_spec.cmd[5]:find("TestMain", 1, true) == nil,
    vim.inspect(f_spec and f_spec.cmd))
  local d_spec = go.build_spec({
    position = { type = "dir", id = gofix .. "/calc", path = gofix .. "/calc" },
    tree = tree, root = gofix, run_id = "spec-probe", run_dir = fx .. "/spec-probe",
  })
  ok("dir spec: relative package pattern ./calc/...",
    d_spec ~= nil and vim.deep_equal(d_spec.cmd,
      { "go", "test", "-json", "./calc/..." }),
    vim.inspect(d_spec and d_spec.cmd))
  local root_spec = go.build_spec({
    position = { type = "dir", id = gofix, path = gofix },
    tree = tree, root = gofix, run_id = "spec-probe", run_dir = fx .. "/spec-probe",
  })
  ok("root dir spec: ./...",
    root_spec ~= nil and root_spec.cmd[4] == "./...",
    vim.inspect(root_spec and root_spec.cmd))

  -- Serializable projection (the run.tests_list shape).
  local plain_tree = P3.discovery.tree_plain()
  local okj = pcall(vim.json.encode, plain_tree)
  ok("tree_plain() is JSON-serializable (no parent refs)", okj)
  ok("tree_plain() carries ids + types",
    plain_tree.id == gofix and plain_tree.type == "dir"
      and #plain_tree.children > 0)
end

-- ── [23] discovery — scan bounds + cancelation ──────────────────
print("\n[23] discovery — bounded caps (structured, loud) + cancel")
do
  worktree.set_active(gofix)

  -- files cap: structured report, never a silent degrade.
  local capped
  P3.discovery.scan({ max_files = 2 }, function(r) capped = r end)
  wait_for(function() return capped end)
  ok("tiny files cap → status=capped", capped ~= nil and capped.status == "capped",
    vim.inspect(capped))
  ok("cap report is structured (cap/limit/seen/hint)",
    capped.cap == "files" and capped.limit == 2 and capped.seen == 3
      and capped.hint == "scope narrowed?", vim.inspect(capped))

  -- roots cap (two go roots in the fixture).
  local rcapped
  P3.discovery.scan({ max_roots = 1 }, function(r) rcapped = r end)
  wait_for(function() return rcapped end)
  ok("tiny roots cap → status=capped cap=roots",
    rcapped ~= nil and rcapped.status == "capped" and rcapped.cap == "roots"
      and rcapped.limit == 1 and rcapped.seen == 2, vim.inspect(rcapped))

  -- A second scan() cancels the first (one in flight per repo).
  local first, second
  P3.discovery.scan({ chunk = 1 }, function(r) first = r end)
  P3.discovery.scan(nil, function(r) second = r end)
  wait_for(function() return first and second end)
  ok("second scan cancels the first",
    first ~= nil and first.status == "canceled"
      and first.reason == "superseded", vim.inspect(first))
  ok("…and the second completes", second ~= nil and second.status == "complete")

  -- A worktree switch cancels the in-flight scan.
  local switched
  P3.discovery.scan({ chunk = 1 }, function(r) switched = r end)
  worktree.set_active(plain)
  wait_for(function() return switched end)
  ok("worktree switch cancels the in-flight scan",
    switched ~= nil and switched.status == "canceled", vim.inspect(switched))
  worktree.set_active(gofix)
  ok("re-anchored tree follows the active worktree",
    P3.discovery.tree().root.path == gofix)
end

-- ── [24] discovery — per-file mtime cache ───────────────────────
print("\n[24] discovery — mtime cache (re-scan skips unchanged files)")
do
  worktree.set_active(gofix)
  local r1
  P3.discovery.scan(nil, function(r) r1 = r end)
  wait_for(function() return r1 end)
  ok("baseline scan green", r1 ~= nil and r1.status == "complete")

  local r2
  P3.discovery.scan(nil, function(r) r2 = r end)
  wait_for(function() return r2 end)
  ok("re-scan parses NOTHING (all mtime-cached)",
    r2 ~= nil and r2.parsed == 0 and r2.cached == 2, vim.inspect(r2))

  -- Touch one file (content change → new mtime) → exactly one parse.
  write_file(nested_test, [[
package nested

import "testing"

func TestNested(t *testing.T) {
	if 1+1 != 2 {
		t.Fatal("math broke")
	}
}

func TestMtime(t *testing.T) {}
]])
  local r3
  P3.discovery.scan(nil, function(r) r3 = r end)
  wait_for(function() return r3 end)
  ok("changed file re-parses; unchanged file stays cached",
    r3 ~= nil and r3.parsed == 1 and r3.cached == 1, vim.inspect(r3))
  ok("re-parse picked up the new position",
    P3.discovery.tree():get(nested_test .. "::TestMtime") ~= nil)
end

-- ── [25] discovery — open buffers + BufWritePost ────────────────
print("\n[25] discovery — open-buffers default + BufWritePost re-parse")
do
  worktree.set_active(gofix)
  P3.discovery._reset_for_tests()

  -- Fresh read of a test file → BufReadPost parse (no scan needed).
  pcall(vim.cmd, "silent! bwipeout! " .. vim.fn.fnameescape(calc_test))
  local disco_ev
  local h_ev = core.events.subscribe("run.discovery:changed",
    function(p) disco_ev = p end)
  vim.cmd.edit(vim.fn.fnameescape(calc_test))
  local tree = P3.discovery.tree()
  ok("BufReadPost parses an opened test file (open-buffers default)",
    tree:get(calc_test .. "::TestAdd") ~= nil)
  ok("only the open buffer is discovered (no implicit full scan)",
    tree:counts().files == 1, vim.inspect(tree:counts()))
  ok("run.discovery:changed published on parse",
    disco_ev ~= nil and disco_ev.root == gofix
      and disco_ev.files == 1 and disco_ev.positions > 0,
    vim.inspect(disco_ev))

  -- Edit the buffer, :write → BufWritePost re-parse.
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
    "", "func TestBufAdded(t *testing.T) {", "\tt.Log(\"added\")", "}",
  })
  vim.cmd("silent write")
  ok("BufWritePost re-parses the open test file",
    P3.discovery.tree():get(calc_test .. "::TestBufAdded") ~= nil)

  -- refresh_open_buffers covers buffers opened before setup.
  P3.discovery._reset_for_tests()
  local n = P3.discovery.refresh_open_buffers()
  ok("refresh_open_buffers re-discovers loaded test buffers",
    n >= 1 and P3.discovery.tree():get(calc_test .. "::TestAdd") ~= nil,
    tostring(n))
  core.events.unsubscribe(h_ev)
end

-- ── [26] discovery — go END-TO-END (real go test runs) ──────────
print("\n[26] discovery — real `go test -json` → per-position results")
do
  worktree.set_active(gofix)
  P3.discovery._reset_for_tests()
  local scanned
  P3.discovery.scan(nil, function(r) scanned = r end)
  wait_for(function() return scanned end)
  ok("fixture rescanned for the run", scanned ~= nil and scanned.status == "complete")
  local tree = P3.discovery.tree()

  -- gobugger parity: a kind=test config's build_flags + env apply.
  store.add({ name = "gofix-tests", kind = "test", runtime = "go",
    build_flags = "-count=1", env = { SMOKE_GO_MARKER = "yes" } },
    { tier = "shared" })
  local go = P3.adapters.get("go")
  ok("kind=test config picked for adapter runs",
    go.test_config_name() == "gofix-tests")
  local cfg_spec = go.build_spec({
    position = tree:get(calc_test .. "::TestFail"), tree = tree, root = gofix,
    run_id = "cfg-probe", run_dir = fx .. "/cfg-probe",
  })
  ok("effective config's build_flags land in the argv",
    cfg_spec ~= nil and cfg_spec.cmd[4] == "-count=1", vim.inspect(cfg_spec and cfg_spec.cmd))
  ok("effective config's env rides the spec (composed, not logged)",
    cfg_spec ~= nil and cfg_spec.env ~= nil
      and cfg_spec.env.SMOKE_GO_MARKER == "yes")

  -- FILE run: pass/fail/skip + subtests + missing-fill + aggregation.
  local results_ev
  local h_ev = core.events.subscribe("run.results:changed",
    function(p) results_ev = p end)
  local batch
  local launched, lerr = P3.discovery.run_position(calc_test, {
    on_done = function(b) batch = b end,
  })
  ok("run_position(file) launches", launched ~= nil, tostring(lerr))
  ok("one spec for a single-package file run",
    launched and #launched.runs == 1 and launched.runs[1].adapter == "go",
    vim.inspect(launched))
  local running_now = P3.discovery.results()
  ok("scope marked running immediately (glyph feed)",
    running_now[calc_test .. "::TestFail"] ~= nil
      and running_now[calc_test .. "::TestFail"].status == "running")
  ok("running status aggregates upward while in flight",
    running_now[calc_test] ~= nil and running_now[calc_test].status == "running")

  wait_for(function() return batch end, 60000)
  ok("go test run completed (on_done fired)", batch ~= nil)
  local res = P3.discovery.results()
  local function status_of(id) return res[id] and res[id].status end
  ok("TestAdd passed", status_of(calc_test .. "::TestAdd") == "passed",
    vim.inspect(res[calc_test .. "::TestAdd"]))
  ok("subtest 'sub one' passed (slash-split name mapping)",
    status_of(calc_test .. "::TestAdd::sub one") == "passed")
  ok("NESTED subtest 'inner' passed",
    status_of(calc_test .. "::TestAdd::group::inner") == "passed")
  ok("TestFail FAILED and maps back to its position id",
    status_of(calc_test .. "::TestFail") == "failed")
  ok("failure output captured from the -json stream",
    res[calc_test .. "::TestFail"].output ~= nil
      and res[calc_test .. "::TestFail"].output:find("boom", 1, true) ~= nil)
  ok("TestSkipped skipped (runner-reported)",
    status_of(calc_test .. "::TestSkipped") == "skipped")
  ok("ExampleAdd (with Output) passed",
    status_of(calc_test .. "::ExampleAdd") == "passed")
  ok("no-output Example (compiled, never run) missing-result FILLED as skipped",
    status_of(calc_test .. "::ExampleAdd_noOutput") == "skipped")
  ok("upward aggregation: file failed",
    status_of(calc_test) == "failed")
  ok("upward aggregation: dir failed", status_of(gofix .. "/calc") == "failed")
  ok("upward aggregation: worktree root failed", status_of(gofix) == "failed")
  ok("run.results:changed published with the positions map",
    results_ev ~= nil and results_ev.root == gofix
      and results_ev.positions[calc_test .. "::TestFail"] ~= nil,
    vim.inspect(results_ev and results_ev.positions and "map-present"))
  ok("durations parsed from Elapsed",
    type(res[calc_test .. "::TestAdd"].duration_ms) == "number")

  -- SINGLE nested-subtest run.
  batch = nil
  local one, oerr = P3.discovery.run_position(
    calc_test .. "::TestAdd::group::inner", { on_done = function(b) batch = b end })
  ok("run_position(nested subtest) launches", one ~= nil, tostring(oerr))
  wait_for(function() return batch end, 60000)
  ok("nested subtest run resolves to passed",
    batch ~= nil and batch[calc_test .. "::TestAdd::group::inner"] ~= nil
      and batch[calc_test .. "::TestAdd::group::inner"].status == "passed",
    vim.inspect(batch))

  -- WORKTREE-ROOT dir run: umbrella module via ./... + the nested
  -- module via its own per-file spec (two specs, one batch).
  batch = nil
  local all, aerr = P3.discovery.run_position(gofix, {
    on_done = function(b) batch = b end,
  })
  ok("run_position(root dir) launches", all ~= nil, tostring(aerr))
  ok("root run decomposes into umbrella + nested-module specs",
    all and #all.runs == 2, vim.inspect(all))
  wait_for(function() return batch end, 60000)
  local res2 = P3.discovery.results()
  ok("nested module's test ran and passed (own module root)",
    res2[nested_test .. "::TestNested"] ~= nil
      and res2[nested_test .. "::TestNested"].status == "passed")
  ok("root aggregation stays failed (TestFail)",
    res2[gofix] ~= nil and res2[gofix].status == "failed")

  -- Structured errors on the execution surface.
  local missing, merr = P3.discovery.run_position("no::such::position")
  ok("run_position unknown id is a structured error",
    missing == nil and tostring(merr):find("not found", 1, true) ~= nil)
  local dbg, dbg_err = P3.discovery.debug_position(calc_test)
  ok("debug_position refuses non-test positions",
    dbg == nil and tostring(dbg_err):find("test position", 1, true) ~= nil)
  -- Go test debug now runs through the adapter capability (ADR 0194 §2.3.4,
  -- Lector P1-5) instead of a `node.adapter == "go"` branch. Capture the launch
  -- the core would run and assert it is CONFIG-EQUIVALENT to the dap-go test
  -- launch: mode=test on the position's package, a -test.run anchored at the
  -- position, and the repo's kind=test config's build_flags merged in.
  local dapmod = require("auto-run.dap")
  local saved_launch = dapmod.launch
  local captured_launch
  dapmod.launch = function(l) captured_launch = l return true end
  local dbg2, dbg2_err = P3.discovery.debug_position(calc_test .. "::TestFail")
  dapmod.launch = saved_launch
  ok("debug_position launches a go test through the adapter capability",
    dbg2 == true and captured_launch ~= nil, tostring(dbg2_err))
  ok("go prepare_debug is config-equivalent to the dap-go test launch",
    captured_launch ~= nil
      and captured_launch.dap_type == "go"
      and captured_launch.extra.mode == "test"
      and captured_launch.program == gofix .. "/calc"
      and captured_launch.args[1] == "-test.run"
      and captured_launch.args[2] == "^TestFail$"
      and captured_launch.extra.buildFlags == "-count=1",
    vim.inspect(captured_launch))

  core.events.unsubscribe(h_ev)
  store.remove("gofix-tests")
end

-- ── [27] adapters — jest fixture + stubbed end-to-end ───────────
print("\n[27] jest — per-package roots, query, argv, results parse")
local jestfix = fx .. "/jestfix"
local foo_test = jestfix .. "/pkg-a/src/foo.test.js"
local bar_test = jestfix .. "/pkg-b/__tests__/bar.test.ts"
do
  ok("jest fixture repo created", make_plain_repo(jestfix))
  write_file(jestfix .. "/package.json", '{ "name": "umbrella", "private": true }\n')
  write_file(jestfix .. "/pkg-a/package.json", '{ "name": "pkg-a" }\n')
  write_file(jestfix .. "/pkg-b/package.json", '{ "name": "pkg-b" }\n')
  write_file(foo_test, [[
describe("math", () => {
  it("adds", () => {
    expect(1 + 1).toBe(2);
  });
  it.skip("skips", () => {});
});

test("standalone", () => {
  expect(true).toBe(false);
});
]])
  write_file(bar_test, [[
describe("bar", () => {
  test("works", () => {
    expect(true).toBe(true);
  });
});
]])
  -- node_modules DECOY: a test file that must never be discovered.
  write_file(jestfix .. "/pkg-a/node_modules/decoy/decoy.test.js",
    'test("decoy", () => {});\n')

  -- Stub jest binaries: real executables that honor --outputFile= and
  -- emit canned jest --json output (a trivially-provisioned runner —
  -- no npm install in the smoke). pkg-a gets a local one; pkg-b
  -- resolves the HOISTED umbrella binary.
  local canned = vim.json.encode({
    numTotalTests = 3,
    testResults = {
      {
        name = foo_test,
        assertionResults = {
          { ancestorTitles = { "math" }, title = "adds",
            status = "passed", duration = 5 },
          { ancestorTitles = { "math" }, title = "skips",
            status = "pending" },
          { ancestorTitles = {}, title = "standalone", status = "failed",
            failureMessages = { "expected true to be false" } },
        },
      },
    },
  })
  write_file(jestfix .. "/pkg-a/canned.json", canned)
  local stub = table.concat({
    "#!/bin/sh",
    'out=""',
    'for a in "$@"; do',
    '  case "$a" in',
    '    --outputFile=*) out="${a#--outputFile=}" ;;',
    "  esac",
    "done",
    'cat "' .. jestfix .. '/pkg-a/canned.json" > "$out"',
    "exit 1",  -- jest exits 1 when any test failed
    "",
  }, "\n")
  write_file(jestfix .. "/pkg-a/node_modules/.bin/jest", stub)
  vim.uv.fs_chmod(jestfix .. "/pkg-a/node_modules/.bin/jest", tonumber("755", 8))
  write_file(jestfix .. "/node_modules/.bin/jest", stub)
  vim.uv.fs_chmod(jestfix .. "/node_modules/.bin/jest", tonumber("755", 8))

  worktree.set_active(jestfix)
  P3.discovery._reset_for_tests()
  require("auto-run.adapters.jest")._reset_for_tests()

  local report
  P3.discovery.scan(nil, function(r) report = r end)
  wait_for(function() return report end)
  ok("jest scan completes", report ~= nil and report.status == "complete",
    vim.inspect(report))
  ok("both packages' test files parsed (js + ts)",
    report.parsed == 2, vim.inspect(report))
  ok("two per-package roots discovered under one worktree",
    report.roots == 2, vim.inspect(report))

  local tree = P3.discovery.tree()
  local jest = P3.adapters.get("jest")
  ok("node_modules decoy is NOT discovered",
    tree:get(jestfix .. "/pkg-a/node_modules/decoy/decoy.test.js") == nil)
  ok("jest.root resolves the nearest package.json",
    jest.root(jestfix .. "/pkg-a/src") == jestfix .. "/pkg-a"
      and jest.root(jestfix .. "/pkg-b/__tests__") == jestfix .. "/pkg-b")

  local ns = tree:get(foo_test .. "::math")
  local adds = tree:get(foo_test .. "::math::adds")
  local skips = tree:get(foo_test .. "::math::skips")
  local standalone = tree:get(foo_test .. "::standalone")
  ok("describe → namespace position", ns ~= nil and ns.type == "namespace")
  ok("it → test position under the namespace",
    adds ~= nil and adds.type == "test" and adds.parent == ns)
  ok("it.skip alias discovered", skips ~= nil and skips.type == "test")
  ok("top-level test() discovered", standalone ~= nil and standalone.type == "test")
  ok("ts file parsed with the typescript grammar",
    tree:get(bar_test .. "::bar::works") ~= nil)

  -- build_spec: binary resolution + regex-escaped testNamePattern.
  local a_spec = jest.build_spec({ position = adds, tree = tree,
    root = jestfix .. "/pkg-a", run_id = "probe", run_dir = fx .. "/jest-probe" })
  ok("package-local jest binary picked",
    a_spec ~= nil and a_spec.cmd[1] == jestfix .. "/pkg-a/node_modules/.bin/jest",
    vim.inspect(a_spec and a_spec.cmd))
  ok("test spec: --json --outputFile into the per-run dir",
    a_spec ~= nil and a_spec.cmd[2] == "--json"
      and a_spec.cmd[3] == "--outputFile=" .. fx .. "/jest-probe/jest-output.json")
  ok("test spec: anchored ancestor-joined --testNamePattern",
    a_spec ~= nil and a_spec.cmd[4] == "--testNamePattern=^math adds$",
    vim.inspect(a_spec and a_spec.cmd))
  local ns_spec = jest.build_spec({ position = ns, tree = tree,
    root = jestfix .. "/pkg-a", run_id = "probe", run_dir = fx .. "/jest-probe" })
  ok("namespace pattern is prefix-anchored only (no trailing $)",
    ns_spec ~= nil and ns_spec.cmd[4] == "--testNamePattern=^math",
    vim.inspect(ns_spec and ns_spec.cmd))
  local b_spec = jest.build_spec({
    position = tree:get(bar_test .. "::bar::works"), tree = tree,
    root = jestfix .. "/pkg-b", run_id = "probe", run_dir = fx .. "/jest-probe" })
  ok("hoisted umbrella binary resolves for the bare package",
    b_spec ~= nil and b_spec.cmd[1] == jestfix .. "/node_modules/.bin/jest",
    vim.inspect(b_spec and b_spec.cmd))

  -- ── composed env reaches a jest run (parity with the go adapter) ──
  -- Before this, `env` / `env_files` / the selected env file reached
  -- `go test` and silently never reached `jest`: build_spec returned no
  -- `env` field at all. The CONTROL is the spec built above, before any
  -- kind=test config exists — without it, an adapter that always attached
  -- some env would pass the positive case.
  ok("jest CONTROL — no kind=test config ⇒ spec carries no env",
    a_spec ~= nil and a_spec.env == nil, vim.inspect(a_spec and a_spec.env))

  write_file(jestfix .. "/api.env", "FROM_FILE=file-value\nSHARED=from-file\n")
  local jt_path, jt_err = store.add({
    name = "jest-tests", kind = "test", runtime = "jest",
    env = { FROM_CONFIG = "cfg-value", SHARED = "from-config" },
    -- `${worktree}`-anchored, the form a real config uses: a bare relative
    -- env_file resolves against CWD, not the worktree.
    env_files = { "${worktree}/api.env" },
  }, { tier = "tracked" })
  ok("jest kind=test config added", jt_path ~= nil, tostring(jt_err))

  local e_spec, e_err = jest.build_spec({ position = adds, tree = tree,
    root = jestfix .. "/pkg-a", run_id = "probe", run_dir = fx .. "/jest-probe" })
  ok("jest build_spec still succeeds with a config applied",
    e_spec ~= nil, tostring(e_err))
  ok("jest spec carries config-level env",
    e_spec ~= nil and e_spec.env ~= nil and e_spec.env.FROM_CONFIG == "cfg-value",
    vim.inspect(e_spec and e_spec.env))
  ok("jest spec carries env_files (VS Code's envFile) values",
    e_spec ~= nil and e_spec.env ~= nil and e_spec.env.FROM_FILE == "file-value",
    vim.inspect(e_spec and e_spec.env))
  ok("jest env precedence matches the rest of auto-run: config wins over file",
    e_spec ~= nil and e_spec.env ~= nil and e_spec.env.SHARED == "from-config",
    vim.inspect(e_spec and e_spec.env))
  ok("jest spec keeps its argv/context while carrying env",
    e_spec ~= nil and e_spec.cmd[2] == "--json"
      and e_spec.context.position_id == adds.id, vim.inspect(e_spec and e_spec.cmd))

  -- A config that exists but cannot compose must FAIL the run, not run the
  -- tests with the wrong environment.
  store.update("jest-tests", { env_files = { "does-not-exist.env" } })
  local bad_spec, bad_env_err = jest.build_spec({ position = adds, tree = tree,
    root = jestfix .. "/pkg-a", run_id = "probe", run_dir = fx .. "/jest-probe" })
  ok("jest build_spec fails loudly when a referenced envFile is missing",
    bad_spec == nil and bad_env_err ~= nil, tostring(bad_env_err))
  store.remove("jest-tests", { tier = "tracked" })

  -- Regex-escaping probe on a hostile name.
  local hostile = { type = "test", path = foo_test,
    id = foo_test .. "::a.b (c) [d]" }
  local h_spec = jest.build_spec({ position = hostile, tree = tree,
    root = jestfix .. "/pkg-a", run_id = "probe", run_dir = fx .. "/jest-probe" })
  ok("testNamePattern regex-escapes metacharacters",
    h_spec ~= nil
      and h_spec.cmd[4] == "--testNamePattern=^a\\.b \\(c\\) \\[d\\]$",
    vim.inspect(h_spec and h_spec.cmd))

  -- END-TO-END with the STUB runner (spawn → outputFile → parse).
  -- Note: canned output, real process — an npm-installed jest is not
  -- provisioned in the smoke environment.
  local batch
  local launched, lerr = P3.discovery.run_position(foo_test, {
    on_done = function(b) batch = b end,
  })
  ok("run_position(jest file) launches the stub runner",
    launched ~= nil and #launched.runs == 1, tostring(lerr))
  wait_for(function() return batch end, 30000)
  local res = P3.discovery.results()
  ok("jest results parse keyed to position ids",
    res[foo_test .. "::math::adds"] ~= nil
      and res[foo_test .. "::math::adds"].status == "passed"
      and res[foo_test .. "::math::adds"].duration_ms == 5)
  ok("pending maps to skipped", res[foo_test .. "::math::skips"] ~= nil
    and res[foo_test .. "::math::skips"].status == "skipped")
  ok("failed test carries failureMessages output",
    res[foo_test .. "::standalone"] ~= nil
      and res[foo_test .. "::standalone"].status == "failed"
      and tostring(res[foo_test .. "::standalone"].output)
        :find("expected true", 1, true) ~= nil)
  ok("namespace aggregates from its own children only",
    res[foo_test .. "::math"] ~= nil
      and res[foo_test .. "::math"].status == "passed")
  ok("file aggregates failed (exit 1 + parsed results ≠ runner death)",
    res[foo_test] ~= nil and res[foo_test].status == "failed")
end

-- ── [28] mailbox — Phase 3 verbs live (§11) ─────────────────────
print("\n[28] mailbox — run.tests_list, run.results, positional test_run")
do
  worktree.set_active(jestfix)
  local h_tests_list = commands.get("run.tests_list").handler
  local h_results = commands.get("run.results").handler
  local h_test_run = commands.get("run.test_run").handler

  local env_t = h_tests_list({})
  ok("run.tests_list envelope: {root, files, positions, tree}",
    env_t.ok == true and env_t.value.root == jestfix
      and env_t.value.files == 2 and env_t.value.positions > 0,
    vim.inspect(env_t.ok and {
      root = env_t.value.root, files = env_t.value.files } or env_t))
  local function find_node(node, id)
    if node.id == id then return node end
    for _, child in ipairs(node.children or {}) do
      local hit = find_node(child, id)
      if hit then return hit end
    end
    return nil
  end
  local node = find_node(env_t.value.tree, foo_test .. "::math::adds")
  ok("tree payload is the serializable position shape",
    node ~= nil and node.type == "test" and node.adapter == "jest"
      and type(node.lnum) == "number")
  ok("tree payload JSON-encodes",
    pcall(vim.json.encode, env_t.value.tree))

  local env_r = h_results({})
  ok("run.results envelope keyed by position id",
    env_r.ok == true and env_r.value.count > 0
      and env_r.value.results[foo_test .. "::standalone"] ~= nil
      and env_r.value.results[foo_test .. "::standalone"].status == "failed",
    vim.inspect(env_r.ok and env_r.value.count or env_r))

  -- Positional test_run: same run.exec trust gate as every
  -- execution-starting verb ([12] left trust ack'd but DISABLED).
  local env_gate = h_test_run({ position = foo_test .. "::math::adds" })
  ok("positional run.test_run is trust-gated",
    env_gate.ok == false and env_gate.code == "trust_required",
    vim.inspect(env_gate))
  ok("run.test_run schema still carries NO force/bypass flag", (function()
    for k in pairs(commands.get("run.test_run").schema or {}) do
      local lk = tostring(k):lower()
      if lk:find("force") or lk:find("bypass") then return false end
    end
    return true
  end)())

  trust.set("run.exec", { enabled = true })
  local env_both = h_test_run({ name = "x", position = "y" })
  ok("name + position are mutually exclusive → invalid_args",
    env_both.ok == false and env_both.code == "invalid_args")
  local env_ghost = h_test_run({ position = "no::such" })
  ok("unknown position → not_found",
    env_ghost.ok == false and env_ghost.code == "not_found", vim.inspect(env_ghost))

  local exited
  local h_ev = core.events.subscribe("run.job:exited", function(p) exited = p end)
  local env_run = h_test_run({ position = foo_test .. "::math::adds" })
  ok("trusted positional run.test_run launches",
    env_run.ok == true and env_run.value.position == foo_test .. "::math::adds"
      and #env_run.value.runs == 1, vim.inspect(env_run))
  wait_for(function() return exited and exited.id == env_run.value.runs[1].id end)
  ok("positional run's job exits (results flow via run.results)",
    exited ~= nil)
  core.events.unsubscribe(h_ev)
  trust.set("run.exec", { enabled = false })

  -- Phase 2 config form still works through the same verb (regression
  -- guard for the extension).
  trust.set("run.exec", { enabled = true })
  worktree.set_active(plain)
  local exited2
  local h_ev2 = core.events.subscribe("run.job:exited", function(p) exited2 = p end)
  local env_cfg = h_test_run({ name = "pkg-tests", test_name = "TestNope" })
  ok("config-name form still runs (Phase 2 compatibility)",
    env_cfg.ok == true and contains(env_cfg.value.cmd, "^TestNope$"),
    vim.inspect(env_cfg))
  wait_for(function() return exited2 and exited2.id == env_cfg.value.id end)
  core.events.unsubscribe(h_ev2)
  trust.set("run.exec", { enabled = false })
end

-- ── [29] :AutoRun {tests|scan} + doctor diagnostics ─────────────
print("\n[29] :AutoRun — tests/scan subcommands, doctor adapter rows")
do
  worktree.set_active(jestfix)
  -- `:AutoRun tests` and `:AutoRun scan` are gone (ADR 0199 §4.1): the tests
  -- pane renders the tree and its `S` scans. The scan API they fronted stays.
  local scan_done
  local h_ev = core.events.subscribe("run.discovery:changed",
    function(p) scan_done = p end)
  ok("discovery.scan runs clean", pcall(P3.discovery.scan, nil, function() end))
  wait_for(function() return scan_done end)
  ok("discovery.scan completes and republishes discovery",
    scan_done ~= nil and scan_done.root == jestfix, vim.inspect(scan_done))
  core.events.unsubscribe(h_ev)

  local doc = vim.api.nvim_exec2("AutoRun doctor", { output = true }).output
  ok("doctor renders the test-discovery section",
    doc:find("test discovery", 1, true) ~= nil)
  ok("doctor lists adapter roots for the anchor",
    doc:find("adapter go", 1, true) ~= nil
      and doc:find("adapter jest", 1, true) ~= nil
      and doc:find("root " .. jestfix, 1, true) ~= nil, doc)
  ok("doctor reports the discovery snapshot",
    doc:find("discovered", 1, true) ~= nil)
end

-- ═════════════════════ Phase 4 — parity gate ════════════════════

-- ── [30] import — REAL launch.json sample (LabelManager copy) ───
print("\n[30] import — real LabelManager launch.json sample (copy)")
do
  -- The richest real-world launch.json known to this machine, copied
  -- into a fixture repo (the real repo is NEVER touched). When the
  -- sample is unreachable (other machines) a verbatim embedded copy
  -- keeps the assertions meaningful.
  local sample = "/home/johno/Source/Projects/LabelManager/lm/.vscode/launch.json"
  local content
  local sf = io.open(sample, "r")
  if sf then
    content = sf:read("*a")
    sf:close()
  end
  -- The real file lives on ONE machine. Asserting it is readable makes a
  -- claim about that machine, not about the product, so the cell was
  -- unconditionally red everywhere else — CI reported the absolute path as
  -- its own failure detail. The embedded copy below is what actually keeps
  -- the assertions meaningful, and it is always present.
  --
  -- So the assertion moves to the thing that matters, and the real file is
  -- promoted from a precondition to a DRIFT CHECK: where it is readable, the
  -- embedded copy must still match it, which is the only reason to read it
  -- at all. Where it is not, the cell says so and moves on.
  local have_real = content ~= nil
  local real_content = content
  content = content or [[
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Go: Debug Test (LM)",
      "type": "go",
      "request": "launch",
      "mode": "test",
      "program": "${fileDirname}",
      "envFile": "${workspaceFolder}/../.config/test.env",
      "buildFlags": "-tags=test,gold"
    },
    {
      "name": "Go: Debug Main (gold-http)",
      "type": "go",
      "request": "launch",
      "mode": "debug",
      "program": "${workspaceFolder}/cmd/gold-http",
      "args": [
        "start",
        "-c=/home/johno/Source/Projects/LabelManager/lm/.config/gold-prod.toml"
      ],
      "buildFlags": "-buildvcs=false"
    }
  ]
}
]]

  ok("launch.json sample available (embedded copy is always present)",
    type(content) == "string" and content:find('"configurations"', 1, true) ~= nil,
    "content is " .. type(content))
  -- Drift check, and the only reason to touch the real file. It is absent on
  -- every machine but one, so this is a bonus assertion where it exists, not
  -- a precondition anywhere.
  if have_real then
    ok("embedded copy still matches the real sample (drift check)",
      real_content:find('"buildFlags": "-buildvcs=false"', 1, true) ~= nil
        and real_content:find('"Go: Debug Test (LM)"', 1, true) ~= nil,
      "the real sample changed shape; re-copy the embedded fixture")
  else
    print("  [30] real sample not on this machine (" .. sample
      .. ") — embedded copy in use, drift check skipped")
  end

  local lmfix = fx .. "/lmfix"
  ok("sample fixture repo created", make_plain_repo(lmfix))
  write_file(lmfix .. "/.vscode/launch.json", content)
  worktree.set_active(lmfix)

  ok("read-through active on the sample (no store yet)",
    import.read_through_active() == true)
  local names = {}
  for _, c in ipairs(store.list()) do names[#names + 1] = c.name end
  table.sort(names)
  ok("both real entries surface as shims", vim.deep_equal(names,
    { "Go: Debug Main (gold-http)", "Go: Debug Test (LM)" }), vim.inspect(names))

  local test_eff = store.get("Go: Debug Test (LM)")
  ok("test entry: mode=test → kind=test, type → runtime",
    test_eff ~= nil and test_eff.kind == "test" and test_eff.runtime == "go",
    vim.inspect(test_eff))
  ok("test entry: buildFlags → build_flags (real tag set)",
    test_eff.build_flags == "-tags=test,gold")
  ok("test entry: program keeps the skill's ${fileDirname}",
    test_eff.program == "${fileDirname}")
  ok("test entry: envFile OUTSIDE the worktree → env_files verbatim",
    type(test_eff.env_files) == "table"
      and test_eff.env_files[1] == "${workspaceFolder}/../.config/test.env",
    vim.inspect(test_eff.env_files))

  local main_eff = store.get("Go: Debug Main (gold-http)")
  ok("main entry: mode=debug → kind=debug + args + buildFlags",
    main_eff ~= nil and main_eff.kind == "debug"
      and main_eff.build_flags == "-buildvcs=false"
      and type(main_eff.args) == "table" and main_eff.args[1] == "start",
    vim.inspect(main_eff))
  ok("main entry: ${workspaceFolder} program kept verbatim at rest",
    main_eff.program == "${workspaceFolder}/cmd/gold-http")

  -- Substitution shape: the outside-the-worktree envFile keeps its
  -- `/../` hop after ${workspaceFolder} resolves (never normalized
  -- away), and ${fileDirname} resolves to the buffer file's dir.
  local env_mod = require("auto-run.env")
  local ctx = env_mod.context({
    worktree = lmfix, file = lmfix .. "/internal/dao/dao_test.go",
  })
  local sub_eff, _, unresolved = env_mod.substitute_deep(test_eff, ctx)
  ok("${workspaceFolder}/../ envFile path survives substitution",
    sub_eff.env_files[1] == lmfix .. "/../.config/test.env",
    vim.inspect(sub_eff.env_files))
  ok("${fileDirname} resolves to the test file's package dir",
    sub_eff.program == lmfix .. "/internal/dao")
  ok("no unresolved tokens in the substituted sample",
    #unresolved == 0, vim.inspect(unresolved))

  -- One-shot import of the real sample into the tracked tier.
  local summary, imp_err = import.import(nil, { on_conflict = "skip" })
  ok("real sample imports", summary ~= nil and #summary.imported == 2,
    tostring(imp_err))
  local imported = store.get("Go: Debug Test (LM)")
  ok("imported real entry keeps kind/build_flags/env_files mapping",
    imported ~= nil and imported.kind == "test"
      and imported.build_flags == "-tags=test,gold"
      and imported.env_files[1] == "${workspaceFolder}/../.config/test.env"
      and imported.origin == "launch.json")
  ok("read-through disabled after the import", import.read_through_active() == false)

  -- The name pattern was widened for real-world entry names (colons,
  -- parens); path separators must still be rejected.
  local bad, bad_err = store.add({ name = "bad/name", kind = "run" })
  ok("schema still rejects path separators in names",
    bad == nil and tostring(bad_err):find("name", 1, true) ~= nil,
    tostring(bad_err))
end

-- ── [31] go-test-env skill shape → dap-go merge payload ─────────
print("\n[31] import + debug_test — go-test-env skill shape → dap-go merge")
do
  -- launch.json EXACTLY as the go-test-env skill documents its
  -- emission (SKILL.md configuration template: version 0.2.0, type
  -- go, mode test, program ${fileDirname}, buildFlags/env/envFile).
  local skillfix = fx .. "/skillfix"
  ok("skill fixture repo created", make_plain_repo(skillfix))
  write_file(skillfix .. "/.env.test",
    "FROM_ENV_FILE=yes\nDATABASE_URL=env-file-loses\n")
  write_file(skillfix .. "/.vscode/launch.json", [[
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Go: Debug Test (current)",
      "type": "go",
      "request": "launch",
      "mode": "test",
      "program": "${fileDirname}",
      "buildFlags": "-tags=integration,gold",
      "env": { "DATABASE_URL": "postgres://localhost/app_test" },
      "envFile": "${workspaceFolder}/.env.test"
    }
  ]
}
]])
  worktree.set_active(skillfix)

  local shim = store.get("Go: Debug Test (current)")
  ok("skill emission imports with full field mapping",
    shim ~= nil and shim.kind == "test" and shim.runtime == "go"
      and shim.program == "${fileDirname}"
      and shim.build_flags == "-tags=integration,gold"
      and shim.env.DATABASE_URL == "postgres://localhost/app_test"
      and shim.env_files[1] == "${workspaceFolder}/.env.test",
    vim.inspect(shim))
  local summary = import.import(nil, { on_conflict = "skip" })
  ok("skill entry lands in the tracked tier",
    summary ~= nil and contains(summary.imported, "Go: Debug Test (current)"))

  -- debug_test translation: the payload handed to dap_go.debug_test
  -- (stubbed — real nvim-dap-go isn't on the headless rtp) must carry
  -- buildFlags + composed env (envFile CONTENTS included, config env
  -- winning over the env file — the pipeline's last-wins order).
  local saved_dg = package.loaded["dap-go"]
  local captured
  package.loaded["dap-go"] = {
    debug_test = function(cfg) captured = cfg end,
    setup = function() end,
  }
  local okd, derr = require("auto-run.dap").debug_test("Go: Debug Test (current)")
  ok("debug_test accepts the skill-shaped config", okd == true, tostring(derr))
  ok("dap-go merge payload carries buildFlags",
    captured ~= nil and captured.buildFlags == "-tags=integration,gold",
    vim.inspect(captured))
  ok("envFile contents reach the merge payload env",
    captured.env ~= nil and captured.env.FROM_ENV_FILE == "yes")
  ok("config env WINS over the envFile (last-wins pipeline)",
    captured.env.DATABASE_URL == "postgres://localhost/app_test")

  -- Same payload through the exec facade (`test_run` debug route).
  captured = nil
  local launched, lerr = P2.exec.test_run("Go: Debug Test (current)", { debug = true })
  ok("exec.test_run debug=true routes to the same merge payload",
    launched ~= nil and launched.strategy == "dap"
      and captured ~= nil and captured.buildFlags == "-tags=integration,gold"
      and captured.env.FROM_ENV_FILE == "yes",
    tostring(lerr))
  package.loaded["dap-go"] = saved_dg
end

-- ── [32] exec — pick_config filter + per-repo pick memory ───────
print("\n[32] exec — pick_config kind filter + per-repo pick memory")
do
  local pickfix = fx .. "/pickfix"
  ok("pick fixture repo created", make_plain_repo(pickfix))
  worktree.set_active(pickfix)
  store.add({ name = "t-one", kind = "test", program = "./..." }, { tier = "tracked" })
  store.add({ name = "t-two", kind = "test", program = "./..." }, { tier = "tracked" })
  store.add({ name = "d-only", kind = "debug", runtime = "go",
    program = "./cmd/x" }, { tier = "tracked" })

  -- Kind filtering.
  local picked_d
  P2.exec.pick_config("debug", function(n) picked_d = n end)
  ok("single kind=debug match returns without prompting", picked_d == "d-only")
  local nm_reason
  P2.exec.pick_config("run", function(_, r) nm_reason = r end)
  ok("kind with no configs → reason no_matches", nm_reason == "no_matches")

  -- Multi-match prompts with ONLY the kind-filtered candidates.
  local real_select = vim.ui.select
  local prompt_items
  vim.ui.select = function(items, _opts, cb)
    prompt_items = items
    cb("t-two")
  end
  local picked_t
  P2.exec.pick_config("test", function(n) picked_t = n end)
  ok("multi-match prompt is kind-filtered (no d-only)",
    vim.deep_equal(prompt_items, { "t-one", "t-two" }), vim.inspect(prompt_items))
  ok("prompt choice reaches the callback", picked_t == "t-two")

  -- Pick memory: persisted per repo in the shared tier's state.json,
  -- surviving a full state round-trip (disk + worktree switch).
  P2.exec.remember_pick("test", "t-two")
  local state_file = pickfix .. "/.auto-run/local/state.json"
  local persisted = vim.fn.filereadable(state_file) == 1
    and vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n")) or {}
  ok("pick persists to the shared tier state.json",
    type(persisted.picks) == "table" and persisted.picks.test == "t-two",
    vim.inspect(persisted))
  ok("picks() diagnostic snapshot reads it back",
    P2.exec.picks().test == "t-two", vim.inspect(P2.exec.picks()))
  prompt_items = nil
  local picked_mem
  P2.exec.pick_config("test", function(n) picked_mem = n end)
  ok("remembered pick short-circuits the prompt",
    picked_mem == "t-two" and prompt_items == nil)
  worktree.set_active(plain)
  worktree.set_active(pickfix)
  local picked_rt
  P2.exec.pick_config("test", function(n) picked_rt = n end)
  ok("pick survives a worktree round-trip (re-read from disk)",
    picked_rt == "t-two" and prompt_items == nil)

  -- A stale remembered pick (config gone) falls through to the prompt.
  P2.exec.remember_pick("test", "ghost")
  local picked_stale
  P2.exec.pick_config("test", function(n) picked_stale = n end)
  ok("stale remembered pick falls through to the prompt",
    picked_stale == "t-two" and vim.deep_equal(prompt_items, { "t-one", "t-two" }))

  -- clear_pick drops the memory.
  P2.exec.remember_pick("test", "t-one")
  P2.exec.clear_pick("test")
  ok("clear_pick clears the persisted pick", P2.exec.picks().test == nil)
  vim.ui.select = real_select
end

-- ── [33] keymaps — auto-run remap-target surface (ADR §10) ──────
-- gobugger.nvim was fully replaced by auto-run (ADR-0048 Phase 4) and is
-- permanently gone, so the old "probe gobugger's live default_keymaps and
-- prove parity" audit has no counterpart left to compare against — it
-- produced 3 hard FAILs and, worse, 2 assertions that passed VACUOUSLY
-- over an empty captured-keymap list (a vacuous green hides more than a
-- red does). Pruned. What survives defends auto-run's OWN surface: the
-- command replacements for the dropped bindings (dE → :AutoRun
-- last-error, dF → doctor --fix) and the descriptions on the remapped
-- run-namespace keys (dr → <leader>rl, dM/dN → <leader>rc), per the ADR
-- §10 disposition.
print("\n[33] keymaps — auto-run remap-target surface (ADR §10)")
do
  -- Guard (P6): gobugger must STAY gone. If it is ever reintroduced,
  -- fail loudly here rather than silently re-enabling a parity gate that
  -- iterates over nothing.
  local gob_present = vim.fn.isdirectory(workspace .. "/gobugger.nvim/main") == 1
    or vim.fn.isdirectory(LAZY .. "/gobugger.nvim") == 1
    or (pcall(require, "gobugger"))
  ok("gobugger stays absent (replaced by auto-run, ADR-0048 P4)",
    not gob_present,
    "gobugger reappeared — the §10 parity audit was pruned on its removal; restore a real gate")

  -- Register auto-run's keymaps so the remapped targets exist.
  auto_run.default_keymaps()

  -- Dropped gobugger bindings (dL/dE/dF) moved to the command surface
  -- per §10 — their replacements must respond.
  local le_out = vim.api.nvim_exec2("AutoRun doctor --last-error", { output = true }).output
  ok("dE replacement — :AutoRun doctor --last-error responds",
    le_out:find("auto%-run") ~= nil, le_out)
  ok("dF replacement — doctor completion offers --fix",
    contains(vim.fn.getcompletion("AutoRun doctor ", "cmdline"), "--fix"))

  -- The run-namespace targets carry auto-run's own descs (not a stale
  -- binding that happened to share the lhs). The full table is [36i].
  local rl = vim.fn.maparg("<leader>rl", "n", false, true)
  ok("dr → <leader>rl is auto-run's Again (last run)",
    type(rl) == "table" and rl.desc == "Run: Again (last run)", vim.inspect(rl.desc))
end

-- ── [34] doctor — git/worktree + config rows + --fix repair ─────
print("\n[34] doctor — git/worktree + config rows + --fix worktree repair")
do
  -- Parity rows on the go fixture: project root + marker, anchor
  -- .git kind, git status, common dir, go module root, configs per
  -- kind with the session-pick marker (gobugger doctor coverage).
  worktree.set_active(gofix)
  store.add({ name = "gofix-tests", kind = "test", runtime = "go",
    build_flags = "-count=1", program = "./calc" }, { tier = "tracked" })
  P2.exec.remember_pick("test", "gofix-tests")

  local doc = vim.api.nvim_exec2("AutoRun doctor", { output = true }).output
  ok("doctor renders the git/worktree section",
    doc:find("git / worktree", 1, true) ~= nil)
  ok("doctor shows the project root + marker",
    doc:find("project root", 1, true) ~= nil
      and doc:find(gofix .. "  [.git/ (regular repo)]", 1, true) ~= nil, doc)
  ok("doctor shows the anchor .git kind",
    doc:find("anchor .git", 1, true) ~= nil
      and doc:find("directory", 1, true) ~= nil)
  ok("doctor shows git status health", doc:find("git status", 1, true) ~= nil)
  ok("doctor shows the git common dir",
    doc:find("git common dir", 1, true) ~= nil
      and doc:find(gofix .. "/.git", 1, true) ~= nil)
  ok("doctor shows the go module root",
    doc:find("go module root", 1, true) ~= nil
      and doc:find(gofix .. "  [go.mod present]", 1, true) ~= nil)
  ok("doctor lists configs per kind with the session pick",
    doc:find("configs by kind", 1, true) ~= nil
      and doc:find("kind=test", 1, true) ~= nil
      and doc:find("gofix-tests  [session pick]", 1, true) ~= nil, doc)

  -- --fix: a bare-container worktree with a DELIBERATELY broken
  -- gitfile (the gobugger fix_worktree scenario).
  local doctor_mod = require("auto-run.doctor")
  local fixc = fx .. "/fixcontainer"
  vim.fn.mkdir(fixc, "p")
  ok("--fix fixture: bare clone",
    git(fx, "clone", "-q", "--bare", src, fixc .. "/.bare"))
  ok("--fix fixture: linked worktree",
    git(fx, "--git-dir=" .. fixc .. "/.bare", "worktree", "add", "-q",
      fixc .. "/wt", "main"))
  write_file(fixc .. "/wt/.git", "gitdir: /nonexistent/worktrees/wt\n")
  ok("--fix fixture: git is broken at the worktree",
    git(fixc .. "/wt", "status", "--porcelain") == false)

  worktree.set_active(fixc .. "/wt")
  local ginfo = doctor_mod.git_info()
  ok("git_info flags the broken gitfile",
    ginfo.gitfile_broken == true and ginfo.status_ok == false
      and type(ginfo.git_kind) == "string"
      and ginfo.git_kind:find("MISSING", 1, true) ~= nil,
    vim.inspect(ginfo))
  ok("git_info resolves the common dir THROUGH the breakage",
    ginfo.common_dir == fixc .. "/.bare", tostring(ginfo.common_dir))
  ok("git_info project root = the .bare container",
    ginfo.project_root == fixc and ginfo.root_marker == ".bare/")
  local doc2 = vim.api.nvim_exec2("AutoRun doctor", { output = true }).output
  ok("doctor surfaces the broken gitfile + --fix hint",
    doc2:find("MISSING", 1, true) ~= nil
      and doc2:find("doctor --fix", 1, true) ~= nil, doc2)

  local result, ferr = doctor_mod.fix_worktree()
  ok("fix_worktree repairs from the common dir",
    result ~= nil and result.common == fixc .. "/.bare", tostring(ferr))
  ok("worktree is healthy after the repair",
    git(fixc .. "/wt", "status", "--porcelain") == true)
  local ginfo2 = doctor_mod.git_info()
  ok("git_info confirms the heal",
    ginfo2.gitfile_broken == false and ginfo2.status_ok == true,
    vim.inspect(ginfo2))
  local fix_out = vim.api.nvim_exec2("AutoRun doctor --fix", { output = true }).output
  ok(":AutoRun doctor --fix runs clean (idempotent when healthy)",
    fix_out:find("worktree repair @ " .. fixc .. "/.bare", 1, true) ~= nil, fix_out)

  -- Outside a repo: structured error, no crash.
  local norepo = fx .. "/norepo"
  vim.fn.mkdir(norepo, "p")
  worktree.set_active(norepo)
  local nres, nerr = doctor_mod.fix_worktree()
  ok("fix outside a repo is a structured error",
    nres == nil and tostring(nerr):find("cannot repair", 1, true) ~= nil,
    tostring(nerr))
  local nofix_out = vim.api.nvim_exec2("AutoRun doctor --fix", { output = true }).output
  ok(":AutoRun doctor --fix outside a repo errors gracefully",
    nofix_out:find("cannot repair", 1, true) ~= nil, nofix_out)

  -- An ANCESTOR holding a `.git` DIRECTORY that is not a repository.
  --
  -- The two assertions above only exercised this when the host happened to
  -- have one -- a stray /tmp/.git was enough to flip them, because
  -- boundary_walk stops at any ancestor with a `.git` dir and the resolver
  -- then FABRICATED `<boundary>/.git` as the common dir. The result was
  -- `git -C /tmp/.git worktree repair` and a confusing "git worktree repair
  -- failed: fatal: not a git repository" in place of the structured error.
  -- Worse in principle: a real but unrelated repository up the tree would
  -- have been repaired instead of the caller's.
  --
  -- Build the condition instead of hoping for it, so this holds on any host.
  local bogus = fx .. "/bogus"
  vim.fn.mkdir(bogus .. "/.git", "p")        -- a .git DIR that is not a repo
  vim.fn.mkdir(bogus .. "/nested/deep", "p")
  worktree.set_active(bogus .. "/nested/deep")
  local bres, berr = doctor_mod.fix_worktree()
  ok("an ancestor .git that is NOT a repo yields the structured error, not a git failure",
    bres == nil and tostring(berr):find("cannot repair", 1, true) ~= nil,
    tostring(berr))
  ok("and it never shells out to repair the unrelated ancestor",
    tostring(berr):find("worktree repair failed", 1, true) == nil,
    tostring(berr))
end

-- ── [35] keymaps — rt/rf/dt discovery-position routing ──────────
print("\n[35] keymaps — rt/rf/rT discovery-position routing + fallback")
do
  worktree.set_active(gofix)
  P3.discovery._reset_for_tests()
  local disc = P3.discovery

  -- nearest(): containment (deepest), func-line hit, file fallback.
  vim.cmd.edit(vim.fn.fnameescape(calc_test))
  local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local function line_of(pat)
    for i, l in ipairs(buf_lines) do
      if l:find(pat, 1, true) then return i end
    end
    error("fixture line not found: " .. pat)
  end

  vim.api.nvim_win_set_cursor(0, { line_of("if Add(2, 2)"), 0 })
  local n1 = disc.nearest()
  ok("nearest resolves the deepest containing subtest",
    n1 ~= nil and n1.id == calc_test .. "::TestAdd::group::inner",
    vim.inspect(n1 and n1.id))
  vim.api.nvim_win_set_cursor(0, { line_of("func TestFail"), 0 })
  local n2 = disc.nearest()
  ok("nearest on a func line resolves that test",
    n2 ~= nil and n2.id == calc_test .. "::TestFail", vim.inspect(n2 and n2.id))
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local n3 = disc.nearest()
  ok("cursor above every test → the file position",
    n3 ~= nil and n3.type == "file" and n3.id == calc_test)

  -- Structured fallback reasons.
  vim.cmd.edit(vim.fn.fnameescape(gofix .. "/calc/calc.go"))
  local nn, _, reason = disc.nearest()
  ok("unclaimed buffer → reason no_adapter",
    nn == nil and reason == "no_adapter", tostring(reason))

  -- The bound callbacks, straight off the registered maps.
  auto_run.default_keymaps()
  local function cb_of(suffix)
    local m = vim.fn.maparg("<leader>" .. suffix, "n", false, true)
    return type(m) == "table" and m.callback or nil
  end

  -- <leader>rt: nearest position through the Phase 3 job engine
  -- (real `go test -json` run; [34]'s gofix-tests config applies its
  -- -count=1 build flag to the run).
  vim.cmd.edit(vim.fn.fnameescape(calc_test))
  vim.api.nvim_win_set_cursor(0, { line_of("func TestFail"), 0 })
  local exited
  local h1 = core.events.subscribe("run.job:exited", function(p) exited = p end)
  local ok_rt, rt_err = pcall(cb_of("rt"))
  wait_for(function() return exited end, 20000)
  ok("<leader>rt launches the nearest discovered position",
    ok_rt and exited ~= nil and exited.config == "test:go",
    tostring(rt_err) .. " " .. vim.inspect(exited))
  ok("…and the parsed result lands on that position",
    (disc.results()[calc_test .. "::TestFail"] or {}).status == "failed",
    vim.inspect(disc.results()[calc_test .. "::TestFail"]))

  -- <leader>rf: the FILE position even with the cursor inside a test.
  vim.api.nvim_win_set_cursor(0, { line_of("if Add(2, 2)"), 0 })
  exited = nil
  local ok_rf, rf_err = pcall(cb_of("rf"))
  wait_for(function() return exited end, 20000)
  ok("<leader>rf launches the current file's position",
    ok_rf and exited ~= nil and exited.config == "test:go", tostring(rf_err))
  local res = disc.results()
  ok("file run parses per-test results (pass + fail)",
    (res[calc_test .. "::TestAdd"] or {}).status == "passed"
      and (res[calc_test .. "::TestFail"] or {}).status == "failed",
    vim.inspect({ add = res[calc_test .. "::TestAdd"],
      fail = res[calc_test .. "::TestFail"] }))
  ok("file position aggregates failed",
    (res[calc_test] or {}).status == "failed")

  -- Fallback: an unclaimed buffer routes rt to the Phase 2 config
  -- path (the repo's kind=test config launches instead).
  vim.cmd.edit(vim.fn.fnameescape(gofix .. "/calc/calc.go"))
  P2.exec.remember_pick("test", "gofix-tests")
  exited = nil
  local started
  local h2 = core.events.subscribe("run.job:started", function(p) started = p end)
  local ok_fb, fb_err = pcall(cb_of("rt"))
  wait_for(function() return exited end, 20000)
  ok("rt on an unclaimed buffer falls back to the kind=test config",
    ok_fb and started ~= nil and started.config == "gofix-tests"
      and exited ~= nil and exited.config == "gofix-tests",
    tostring(fb_err) .. " " .. vim.inspect(started))
  core.events.unsubscribe(h1)
  core.events.unsubscribe(h2)

  -- <leader>dt: nearest test routed through debug_position → the
  -- dap-go merge payload (stubbed dap-go captures it).
  local saved_dg = package.loaded["dap-go"]
  local captured
  package.loaded["dap-go"] = {
    debug_test = function(cfg) captured = cfg end,
    setup = function() end,
  }
  -- A DISCOVERED position now routes through the adapter capability, so the
  -- launch (not a dap-go payload) is what to capture. The dap-go stub above
  -- stays for the UNCLAIMED-buffer fallback asserted below.
  local dapmod_dt = require("auto-run.dap")
  local saved_launch_dt = dapmod_dt.launch
  local captured_launch_dt
  dapmod_dt.launch = function(l) captured_launch_dt = l return true end
  vim.cmd.edit(vim.fn.fnameescape(calc_test))
  local sub_line = line_of('t.Run("sub one"')
  vim.api.nvim_win_set_cursor(0, { sub_line, 0 })
  local ok_dt, dt_err = pcall(cb_of("rT"))
  dapmod_dt.launch = saved_launch_dt
  ok("<leader>rT routes the nearest go test through debug_position",
    ok_dt and captured_launch_dt ~= nil, tostring(dt_err))
  ok("rT jumps the cursor to the resolved position",
    vim.api.nvim_win_get_cursor(0)[1] == sub_line
      and vim.api.nvim_buf_get_name(0) == calc_test)
  ok("rT anchors -test.run at the nearest SUBTEST position",
    captured_launch_dt ~= nil and captured_launch_dt.args[1] == "-test.run"
      and captured_launch_dt.args[2] == "^TestAdd$/^sub_one$",
    vim.inspect(captured_launch_dt and captured_launch_dt.args))
  ok("rT merges the repo's kind=test config into the launch",
    captured_launch_dt ~= nil and captured_launch_dt.extra
      and captured_launch_dt.extra.buildFlags == "-count=1",
    vim.inspect(captured_launch_dt))

  -- rT fallback: unclaimed buffer → Phase 2 pick + debug_test.
  captured = nil
  vim.cmd.edit(vim.fn.fnameescape(gofix .. "/calc/calc.go"))
  local ok_dtf, dtf_err = pcall(cb_of("rT"))
  ok("rT on an unclaimed buffer falls back to the config path",
    ok_dtf and captured ~= nil and captured.buildFlags == "-count=1",
    tostring(dtf_err) .. " " .. vim.inspect(captured))

  package.loaded["dap-go"] = saved_dg
end

-- ── [35b] keymaps — rT language leak + dc resume-only ─────────────
-- Runs inside a FUNCTION, not a plain do-block: [35] already carries enough
-- locals that adding these tipped the main chunk over Lua's 200-local cap —
-- the same reason [36] is a function.
print("\n[35b] keymaps — rT language leak + dc resume-only")
local section35b = function()
  local disc = P3.discovery
  auto_run.default_keymaps()
  local function cb_of(suffix)
    local m = vim.fn.maparg("<leader>" .. suffix, "n", false, true)
    return type(m) == "table" and m.callback or nil
  end

  -- dt must never hand a NON-GO buffer to the Go debugger. The fallback in
  -- <leader>dt ends in dap-go's `debug_test`, which debugs the GO test at the
  -- cursor; `nearest` documents ONE trigger for it (`no_adapter`), but dt fell
  -- back on ANY non-test outcome. A CLAIMED buffer with no position at the
  -- cursor is the exact shape.
  local saved_dg = package.loaded["dap-go"]
  local dg_calls = 0
  package.loaded["dap-go"] = {
    debug_test = function() dg_calls = dg_calls + 1 end,
    setup = function() end,
  }

  local leakdir = fx .. "/dt-leak"
  vim.fn.mkdir(leakdir, "p")
  write_file(leakdir .. "/app.test.js", "// no test() calls at all\nconst x = 1;\n")
  worktree.set_active(leakdir)
  vim.cmd.edit(vim.fn.fnameescape(leakdir .. "/app.test.js"))
  local _, _, why = disc.nearest()
  ok("[35b] a CLAIMED buffer with no position reports a non-no_adapter reason",
    why ~= nil and why ~= "no_adapter", tostring(why))

  -- COUNT invocations. A capture-based assertion (`captured == nil`) cannot
  -- tell "never called" from "called with nil" — and with no kind=test config
  -- here the pre-fix path called debug_test(nil), so such a cell passed under
  -- the mutation. Counting is the noun in the claim.
  ok("[35b] rT does NOT invoke the go debugger for a claimed non-go buffer",
    select(1, pcall(cb_of("rT"))) and dg_calls == 0,
    "dap-go invocations: " .. tostring(dg_calls))

  -- POSITIVE CONTROL: the same stub must still record the legitimate
  -- no_adapter fallback, so 0 above means "blocked", not "stub dead".
  worktree.set_active(gofix)
  P2.exec.remember_pick("test", "gofix-tests")
  vim.cmd.edit(vim.fn.fnameescape(gofix .. "/calc/calc.go"))
  ok("[35b] …while an UNCLAIMED buffer still reaches it (control)",
    select(1, pcall(cb_of("rT"))) and dg_calls == 1,
    "dap-go invocations: " .. tostring(dg_calls))

  -- ONE OWNER: dt must share rt/rf's fallback contract, not re-derive it.
  -- The previous head claimed this refactor but production still gated on
  -- `why ~= "no_adapter"` inline, which had ALREADY drifted: `nearest_or_fallback`
  -- treats `no_file` as fallback too, so on an unnamed buffer rt fell through to
  -- the config path while dt stopped. Assert the two agree, which a duplicated
  -- gate cannot satisfy by accident.
  vim.cmd("enew!")            -- an unnamed buffer → reason `no_file`
  local _, _, unnamed_why = disc.nearest()
  ok("[35b] an unnamed buffer reports no_file", unnamed_why == "no_file",
    tostring(unnamed_why))
  local rt_ran = false
  local saved_pick = P2.exec.pick_config
  P2.exec.pick_config = function() rt_ran = true end
  pcall(cb_of("rt"))
  local rt_fell_back = rt_ran
  rt_ran = false
  pcall(cb_of("rT"))
  ok("[35b] rT and rt agree on the no_file fallback (one owner, not two gates)",
    rt_ran == rt_fell_back, ("rt=%s dt=%s"):format(tostring(rt_fell_back), tostring(rt_ran)))
  P2.exec.pick_config = saved_pick
  package.loaded["dap-go"] = saved_dg

  -- dc is RESUME-ONLY (ADR 0199 §4.2). It used to resume a session OR launch
  -- one, and every failure in the 2026-09-23 manual verification began with
  -- the launch branch; a v0.1.14 interception rewrote nvim-dap's "No
  -- configuration found" prose to cope. With no session dc now launches
  -- nothing — it evaluates NO provider — and names the keys that start one.
  local dapm = require("dap")
  local saved_providers = dapm.providers.configs
  local provider_calls = 0
  dapm.providers.configs = {
    ["smoke-counter"] = function() provider_calls = provider_calls + 1; return {} end,
  }
  local saved_continue, saved_session = dapm.continue, dapm.session
  local continued = 0
  dapm.continue = function() continued = continued + 1 end
  dapm.session = function() return nil end
  local msgs = {}
  local logmod = require("auto-run.log")
  local saved_warn, saved_info, saved_notify = logmod.warn, logmod.info, vim.notify
  logmod.warn = function(_, m) msgs[#msgs + 1] = tostring(m) end
  logmod.info = function(_, m) msgs[#msgs + 1] = tostring(m) end
  vim.notify = function(m) msgs[#msgs + 1] = tostring(m) end
  pcall(cb_of("dc"))
  local said = table.concat(msgs, "\n")
  ok("[35b] dc with no session launches nothing: no continue, no provider read",
    continued == 0 and provider_calls == 0,
    ("continue=%d provider_calls=%d"):format(continued, provider_calls))
  ok("[35b] …and names the keys that start a session",
    said:find("<leader>rT", 1, true) ~= nil and said:find("<leader>rP", 1, true) ~= nil, "said: " .. said)
  ok("[35b] …and never sends the user to dap.configurations",
    said:find("dap.configurations", 1, true) == nil, said)
  -- With a session, dc resumes it — looked up at KEYPRESS time, so a stub
  -- installed after binding is consulted (a raw `dap.continue` bound at setup
  -- would not be).
  dapm.session = function() return { id = 1 } end
  pcall(cb_of("dc"))
  ok("[35b] dc with a session resumes it", continued == 1, "continue=" .. continued)
  logmod.warn, logmod.info, vim.notify = saved_warn, saved_info, saved_notify
  dapm.continue, dapm.session = saved_continue, saved_session
  dapm.providers.configs = saved_providers
end
section35b()

-- ── [36] env — §4.2 (r5) selection, candidates, var editing ─────
-- Runs inside a FUNCTION (not a plain do-block): the section carries
-- ~50 locals and the main chunk is close to Lua's 200-local cap.
print("\n[36] env — §4.2 (r5) selection, candidates, var editing, masking")
local section36 = function()
  require("auto-run.config").setup({
    env  = { dir = fx .. "/env-cache" },
    exec = { runs_dir = fx .. "/runs" },
  })

  -- Linked-worktree fixture: one container, two worktrees — the
  -- selection must survive a worktree switch within the container.
  local envsrc = fx .. "/env-src"
  ok("env fixture source repo created", make_plain_repo(envsrc))
  local envc = fx .. "/env-container"
  vim.fn.mkdir(envc, "p")
  ok("env fixture bare clone",
    git(fx, "clone", "-q", "--bare", envsrc, envc .. "/.bare"))
  ok("env fixture worktree A", git(fx, "--git-dir=" .. envc .. "/.bare",
    "worktree", "add", "-q", envc .. "/wt-a", "main"))
  ok("env fixture worktree B", git(fx, "--git-dir=" .. envc .. "/.bare",
    "worktree", "add", "-q", "-b", "alt", envc .. "/wt-b"))
  local wta, wtb = envc .. "/wt-a", envc .. "/wt-b"
  worktree.set_active(wta)

  -- Candidate surface: referenced (config env_files + profile
  -- base_env_files) + the bounded NON-recursive glob.
  write_file(wta .. "/.env", "DOT=1\n")
  write_file(wta .. "/.env.local", "DOTLOCAL=1\n")
  write_file(wta .. "/gold.env", table.concat({
    "# gold test env",
    "SEL_VAR=from-selected",
    "CONF_KEY=from-selected-file",
    "SECRET_TOKEN='sekrit-env-value-xyz'",
    "",
  }, "\n"))
  write_file(wta .. "/referenced.env", "REF=1\n")
  write_file(wta .. "/sub/deep.env", "DEEP=1\n")           -- below top level
  vim.fn.mkdir(wta .. "/fake.env", "p")                    -- a DIRECTORY
  write_file(wta .. "/node_modules/pkg/x.env", "NM=1\n")   -- never entered
  write_file(envc .. "/.config/app.env", "APP=1\n")
  write_file(envc .. "/.config/notes.txt", "not an env file\n")

  store.add({ name = "env-echo", kind = "run", program = "sh",
    args = { "-c", "echo sel=$SEL_VAR conf=$CONF_KEY" },
    env = { CONF_KEY = "config-wins" } }, { tier = "tracked" })
  store.add({ name = "ref-cfg", kind = "run", program = "sh",
    env_files = { "${worktree}/referenced.env", "${worktree}/missing-ref.env" },
  }, { tier = "tracked" })
  store.add({ name = "p-base",
    base_env_files = { "${containerRoot}/.config/app.env" } },
    { kind = "profiles", tier = "tracked" })

  local cands = envmod.files_list()
  local cand_paths = {}
  for _, c in ipairs(cands) do cand_paths[#cand_paths + 1] = c.path end
  ok("candidates: referenced first (source order), then discovered alphabetical",
    vim.deep_equal(cand_paths, {
      wta .. "/referenced.env",
      wta .. "/missing-ref.env",
      envc .. "/.config/app.env",
      wta .. "/.env",
      wta .. "/.env.local",
      wta .. "/gold.env",
    }), vim.inspect(cand_paths))
  ok("config-referenced candidate: source config:<name>, exists=true",
    cands[1].source == "config:ref-cfg" and cands[1].exists == true)
  ok("missing referenced file listed with exists=false",
    cands[2].exists == false and cands[2].source == "config:ref-cfg")
  ok("profile base_env_files candidate: source profile:<name>",
    cands[3].source == "profile:p-base" and cands[3].exists == true)
  local app_seen = 0
  for _, c in ipairs(cands) do
    if c.path == envc .. "/.config/app.env" then app_seen = app_seen + 1 end
  end
  ok("glob hit deduped under its referencing source (listed once)",
    app_seen == 1)
  ok("bounded glob does NOT recurse (sub/deep.env, node_modules absent)",
    not contains(cand_paths, wta .. "/sub/deep.env")
      and not contains(cand_paths, wta .. "/node_modules/pkg/x.env"))
  ok("a DIRECTORY named *.env is skipped",
    not contains(cand_paths, wta .. "/fake.env"))
  local none_selected = true
  for _, c in ipairs(cands) do
    if c.selected then none_selected = false end
  end
  ok("no candidate selected before any pick", none_selected)

  -- Composition BEFORE any selection: config's own env only.
  local exited_ev
  local h_exit = core.events.subscribe("run.job:exited",
    function(p) exited_ev = p end)
  local run1, r1err = P2.exec.start("env-echo")
  ok("baseline run launches", run1 ~= nil, tostring(r1err))
  wait_for(function() return exited_ev and exited_ev.id == run1.id end)
  local out1 = table.concat(
    vim.fn.readfile(fx .. "/runs/" .. run1.id .. "/stdout"), "\n")
  ok("without a selection the file's var is absent (conf = config env)",
    out1:find("sel= conf=config-wins", 1, true) ~= nil, out1)

  -- Selection: validation, event, persistence shape.
  local env_events = {}
  local h_env = core.events.subscribe("run.env:changed", function(p)
    env_events[#env_events + 1] = vim.deepcopy(p)
  end)

  local bad_sel, bad_sel_err = envmod.set_selected(wta .. "/nope.env")
  ok("set_selected on a missing file is a structured not_found",
    bad_sel == nil and type(bad_sel_err) == "table"
      and bad_sel_err.code == "not_found", vim.inspect(bad_sel_err))
  ok("…that stringifies to its message",
    tostring(bad_sel_err):find("no such env file", 1, true) ~= nil)

  local sel_ok, sel_err = envmod.set_selected(wta .. "/gold.env")
  ok("set_selected picks an existing file", sel_ok == true, tostring(sel_err))
  ok("get_selected returns the absolute path",
    envmod.get_selected() == wta .. "/gold.env",
    tostring(envmod.get_selected()))
  ok("run.env:changed published {action=selected, path}",
    #env_events == 1 and env_events[1].action == "selected"
      and env_events[1].path == wta .. "/gold.env", vim.inspect(env_events))

  local sfile = envc .. "/.auto-run/state.json"
  local sdata = vim.fn.filereadable(sfile) == 1
    and vim.json.decode(table.concat(vim.fn.readfile(sfile), "\n")) or {}
  ok("selection persists WORKTREE-RELATIVE in the shared tier's state.json",
    sdata.selected_env_file == "gold.env", vim.inspect(sdata))

  local cands2 = envmod.files_list()
  local marked
  for _, c in ipairs(cands2) do
    if c.selected then marked = (marked == nil) and c.path or "multiple" end
  end
  ok("files_list marks exactly the selected candidate",
    marked == wta .. "/gold.env", tostring(marked))

  -- Composition WITH the selection: the selected file is the
  -- highest-precedence env_files entry; config-level env wins last.
  exited_ev = nil
  local run2, r2err = P2.exec.start("env-echo")
  ok("re-run launches with the selection", run2 ~= nil, tostring(r2err))
  wait_for(function() return exited_ev and exited_ev.id == run2.id end)
  local out2 = table.concat(
    vim.fn.readfile(fx .. "/runs/" .. run2.id .. "/stdout"), "\n")
  ok("selected env file reaches the process on re-run",
    out2:find("sel=from-selected", 1, true) ~= nil, out2)
  ok("config-level env key still beats the selected file (§3.1)",
    out2:find("conf=config-wins", 1, true) ~= nil, out2)

  -- A selection whose file vanished is a HARD compose error.
  write_file(wta .. "/victim.env", "V=1\n")
  envmod.set_selected(wta .. "/victim.env")
  vim.uv.fs_unlink(wta .. "/victim.env")
  local cres, ccerr = envmod.compose({ name = "x", kind = "run" }, {})
  ok("vanished selected file fails composition (never silently skipped)",
    cres == nil and ccerr and ccerr.code == "env_file_missing"
      and tostring(ccerr.message):find("selected env file", 1, true) ~= nil,
    vim.inspect(ccerr))
  ok("opts.no_selected opts raw composition out",
    (envmod.compose({ name = "x", kind = "run" }, { no_selected = true })) ~= nil)

  -- Worktree switch WITHIN the container re-resolves the relative pick.
  envmod.set_selected(wta .. "/gold.env")
  write_file(wtb .. "/gold.env", "SEL_VAR=from-wtb\n")
  worktree.set_active(wtb)
  ok("selection survives a worktree switch (re-anchored to the new worktree)",
    envmod.get_selected() == wtb .. "/gold.env",
    tostring(envmod.get_selected()))
  worktree.set_active(wta)
  ok("…and re-anchors back", envmod.get_selected() == wta .. "/gold.env")

  -- read_file: lnum fidelity + parse errors (panel display surface).
  local display = wta .. "/edit.env"
  write_file(display, table.concat({
    "# header comment",
    'export API_URL="https://example.com"',
    "",
    "PLAIN=hello",
    "SINGLE='keep me'",
    "not a valid line !!",
    "# trailing comment",
    "",
  }, "\n"))
  local rf, rf_err = envmod.read_file(display)
  ok("read_file parses entries", rf ~= nil, vim.inspect(rf_err))
  ok("entries retain 1-based line numbers",
    rf and vim.deep_equal(
      { { rf.entries[1].key, rf.entries[1].lnum },
        { rf.entries[2].key, rf.entries[2].lnum },
        { rf.entries[3].key, rf.entries[3].lnum } },
      { { "API_URL", 2 }, { "PLAIN", 4 }, { "SINGLE", 5 } }),
    vim.inspect(rf and rf.entries))
  ok("quote stripping matches the dotenv parser",
    rf and rf.entries[1].value == "https://example.com"
      and rf.entries[3].value == "keep me")
  ok("unparseable lines land in errors with their lnum",
    rf and #rf.errors == 1 and rf.errors[1].lnum == 6,
    vim.inspect(rf and rf.errors))
  local _, rf_missing = envmod.read_file(wta .. "/nope.env")
  ok("read_file on a missing file is structured not_found",
    type(rf_missing) == "table" and rf_missing.code == "not_found")

  -- update_var / add_var: atomic rewrite preserving layout + quoting.
  ok("update_var rewrites a bare entry (stays bare)",
    envmod.update_var(display, "PLAIN", "world") == true)
  ok("update_var preserves double-quote style + export prefix",
    envmod.update_var(display, "API_URL", "https://new.example/a b") == true)
  ok("update_var preserves single-quote style",
    envmod.update_var(display, "SINGLE", "sekrit-var-value-abc") == true)
  ok("add_var appends bare when no quoting is needed",
    envmod.add_var(display, "NEW_PLAIN", "simple") == true)
  ok("add_var quotes only when the value needs it",
    envmod.add_var(display, "NEW_SPACED", "a b") == true)
  ok("add_var falls to single quotes when the value carries double quotes",
    envmod.add_var(display, "QUOTEY", 'say "hi"') == true)

  local after = vim.fn.readfile(display)
  ok("edited file — byte-level line asserts (comments/blanks/order intact)",
    vim.deep_equal(after, {
      "# header comment",
      'export API_URL="https://new.example/a b"',
      "",
      "PLAIN=world",
      "SINGLE='sekrit-var-value-abc'",
      "not a valid line !!",
      "# trailing comment",
      "NEW_PLAIN=simple",
      'NEW_SPACED="a b"',
      "QUOTEY='say \"hi\"'",
    }), vim.inspect(after))
  local reparsed = envmod.parse_env_file(display)
  ok("edited file round-trips through the dotenv parser",
    reparsed ~= nil and reparsed.PLAIN == "world"
      and reparsed.API_URL == "https://new.example/a b"
      and reparsed.SINGLE == "sekrit-var-value-abc"
      and reparsed.NEW_PLAIN == "simple"
      and reparsed.NEW_SPACED == "a b"
      and reparsed.QUOTEY == 'say "hi"', vim.inspect(reparsed))

  local up_missing, up_missing_err = envmod.update_var(display, "GHOST", "x")
  ok("update_var on a missing key → structured not_found",
    up_missing == nil and up_missing_err.code == "not_found",
    vim.inspect(up_missing_err))
  local add_dup, add_dup_err = envmod.add_var(display, "PLAIN", "x")
  ok("add_var on an existing key → structured already_exists",
    add_dup == nil and add_dup_err.code == "already_exists",
    vim.inspect(add_dup_err))
  local bad_key, bad_key_err = envmod.update_var(display, "BAD-KEY", "x")
  ok("invalid key → structured invalid_key",
    bad_key == nil and bad_key_err.code == "invalid_key")
  local both, both_err = envmod.add_var(display, "BOTH_QUOTES", [[a 'x' "y"]])
  ok("value with BOTH quote chars → structured invalid_value",
    both == nil and both_err.code == "invalid_value", vim.inspect(both_err))

  -- Event masking: payloads carry paths + KEY names, never values.
  local ev_dump = vim.inspect(env_events)
  ok("run.env:changed payloads carry NO values (keys/paths only)",
    ev_dump:find("sekrit-var-value-abc", 1, true) == nil
      and ev_dump:find("sekrit-env-value-xyz", 1, true) == nil
      and ev_dump:find("SINGLE", 1, true) ~= nil, ev_dump)

  -- Mailbox verbs: run.env_list (names only) + run.env_select.
  local h_env_list = commands.get("run.env_list").handler
  local h_env_select = commands.get("run.env_select").handler
  local list_env = h_env_list({})
  ok("run.env_list envelope lists candidates with the selection",
    list_env.ok == true and list_env.value.count >= 6
      and list_env.value.selected == wta .. "/gold.env",
    vim.inspect(list_env.value and list_env.value.selected))
  local gold_entry
  for _, fentry in ipairs(list_env.value.files) do
    if fentry.path == wta .. "/gold.env" then gold_entry = fentry end
  end
  ok("env_list carries per-file KEY NAMES (sorted)",
    gold_entry ~= nil and vim.deep_equal(gold_entry.keys,
      { "CONF_KEY", "SECRET_TOKEN", "SEL_VAR" }), vim.inspect(gold_entry))
  ok("env_list NEVER serializes values (secret-looking string absent)",
    vim.inspect(list_env):find("sekrit-env-value-xyz", 1, true) == nil)

  local clear_env = h_env_select({ path = vim.NIL })
  ok("run.env_select null clears the selection",
    clear_env.ok == true and clear_env.value.selected == nil
      and envmod.get_selected() == nil, vim.inspect(clear_env))
  local sel_env = h_env_select({ path = wta .. "/gold.env" })
  ok("run.env_select selects by path",
    sel_env.ok == true and sel_env.value.selected == wta .. "/gold.env",
    vim.inspect(sel_env))
  local sel_bad = h_env_select({ path = wta .. "/nope.env" })
  ok("run.env_select missing path → not_found",
    sel_bad.ok == false and sel_bad.code == "not_found", vim.inspect(sel_bad))

  -- :AutoRun env — listing with the '*' marker, select/clear, doctor.
  local listing = vim.api.nvim_exec2("AutoRun env", { output = true }).output
  ok(":AutoRun env lists candidates with the '*' selected marker",
    listing:find("* " .. wta .. "/gold.env", 1, true) ~= nil, listing)
  ok(":AutoRun env clear clears",
    pcall(vim.cmd, "AutoRun env clear") and envmod.get_selected() == nil)
  ok(":AutoRun env select re-selects",
    pcall(vim.cmd, "AutoRun env select "
      .. vim.fn.fnameescape(wta .. "/gold.env"))
      and envmod.get_selected() == wta .. "/gold.env")
  local doc_out = vim.api.nvim_exec2("AutoRun doctor", { output = true }).output
  ok("doctor shows the selected env row",
    doc_out:find("selected env:", 1, true) ~= nil
      and doc_out:find(wta .. "/gold.env", 1, true) ~= nil, doc_out)

  -- Leave no global state behind.
  envmod.set_selected(nil)
  core.events.unsubscribe(h_env)
  core.events.unsubscribe(h_exit)
  require("auto-run.config").setup({})
end
section36()

-- ── [36c] selections reach a POSITION run — the tests pane's own run ──
-- The tests pane lets the user pick a launch config (`import.set_selected`,
-- auto-finder _config_section.lua) and an env file (`env.set_selected`), and its
-- `r` runs a position (`discovery.run_position`). Before this section existed,
-- the suite proved the selected base reaches `dap.translate` ([30]) and never
-- that it reaches a POSITION run — and it did not:
--   • the selected launch config never reached a position run, env or build
--     flags, because `adapters/config.lua:test_config` never called
--     `import.apply_selected_base` (its three siblings do);
--   • the selected env file reached one only when a kind=test config existed,
--     because `test_config` returned before `env.compose` otherwise.
-- ASSERT THE NOUN: what `job.spawn` receives is what the test process gets.
-- Runs inside a FUNCTION — the main chunk is near Lua's 200-local cap.
print("\n[36c] selections reach a position run (tests pane r)")
local section36c = function()
  local sel = fx .. "/sel-go"
  ok("[36c] fixture repo", make_plain_repo(sel))
  write_file(sel .. "/go.mod", "module selgo\n\ngo 1.22\n")
  write_file(sel .. "/calc.go", "package selgo\n\nfunc Add(a, b int) int { return a + b }\n")
  write_file(sel .. "/calc_test.go",
    "package selgo\n\nimport \"testing\"\n\nfunc TestAdd(t *testing.T) { if Add(1, 2) != 3 { t.Fatal() } }\n")
  write_file(sel .. "/.vscode/launch.json", vim.json.encode({ version = "0.2.0", configurations = {
    { name = "SelBase", type = "go", request = "launch", mode = "debug",
      program = "${workspaceFolder}/cmd/SELBASE_PROGRAM_MARKER",
      args = { "--selbase-arg-marker" },
      buildFlags = "-tags=selbase",
      env = { SEL_FROM_BASE = "1", SEL_SHARED = "from-base" } } } }))
  write_file(sel .. "/probe.env", "SEL_FROM_ENVFILE=1\n")
  git(sel, "add", "."); git(sel, "commit", "-q", "-m", "fixture")

  local prev_active = worktree.get_active()
  worktree.set_active(sel)
  import.set_selected(nil); envmod.set_selected(nil)

  local disc = P3.discovery
  local job = require("auto-run.exec.job")
  local real_spawn, captured = job.spawn, nil
  job.spawn = function(spec) captured = spec; return { id = spec.id }, nil end
  local id = sel .. "/calc_test.go::TestAdd"
  local function run_add()
    captured = nil
    disc._reset_for_tests()
    disc.parse_file(sel .. "/calc_test.go", require("auto-run.adapters").get("go"))
    local _, err = disc.run_position(id)
    local argv = captured and table.concat(captured.cmd or {}, " ") or ""
    return (captured and captured.env) or {}, argv, err, captured ~= nil
  end

  -- CONTROL — the instrument observes: a kind=test config's OWN env reaches
  -- the spawn. If this is false every "absent" below means nothing.
  store.add({ name = "sel-tests", kind = "test", runtime = "go",
    env = { SEL_FROM_CONFIG = "1", SEL_SHARED = "from-config" } }, { tier = "tracked" })
  local env, argv, err, spawned = run_add()
  ok("[36c] control: a position run spawns", spawned, tostring(err))
  ok("[36c] control: the kind=test config's own env reaches the spawn",
    env.SEL_FROM_CONFIG == "1", vim.inspect(env))

  -- A — the selected launch config reaches a position run.
  ok("[36c] set_selected('SelBase')", import.set_selected("SelBase") == true)
  env, argv = run_add()
  ok("[36c] the selected base's env reaches a position run",
    env.SEL_FROM_BASE == "1", vim.inspect(env))
  ok("[36c] the selected base's build flags reach the position argv",
    argv:find("-tags=selbase", 1, true) ~= nil, argv)
  -- Precedence is apply_selected_base's, not a new rule: the config wins.
  ok("[36c] the kind=test config's own key still wins over the base",
    env.SEL_SHARED == "from-config", tostring(env.SEL_SHARED))

  -- B — the selected env file, with a config present.
  ok("[36c] env.set_selected(probe.env)", envmod.set_selected(sel .. "/probe.env") == true)
  env = run_add()
  ok("[36c] the selected env file reaches a position run (config present)",
    env.SEL_FROM_ENVFILE == "1", vim.inspect(env))

  -- C — NO kind=test config: both selections must still apply.
  store.remove("sel-tests", { tier = "tracked" })
  env, argv = run_add()
  ok("[36c] with NO kind=test config the selected env file still applies",
    env.SEL_FROM_ENVFILE == "1", vim.inspect(env))
  ok("[36c] with NO kind=test config the selected base's env still applies",
    env.SEL_FROM_BASE == "1", vim.inspect(env))
  ok("[36c] with NO kind=test config the selected base's build flags still apply",
    argv:find("-tags=selbase", 1, true) ~= nil, argv)
  -- The base's program/args fill a config that has none — a position run must
  -- never pick them up (the adapter targets the POSITION, not a program).
  ok("[36c] the base's program never reaches a position argv",
    argv:find("SELBASE_PROGRAM_MARKER", 1, true) == nil, argv)
  ok("[36c] the base's args never reach a position argv",
    argv:find("selbase-arg-marker", 1, true) == nil, argv)

  -- D — nothing selected, nothing configured: the run is unchanged and
  -- nothing is injected (the "no config is a normal state" contract).
  import.set_selected(nil); envmod.set_selected(nil)
  env, argv, err, spawned = run_add()
  ok("[36c] no selection, no config: the run still spawns", spawned, tostring(err))
  ok("[36c] no selection, no config: nothing is injected",
    env.SEL_FROM_BASE == nil and env.SEL_FROM_ENVFILE == nil
      and argv:find("selbase", 1, true) == nil, vim.inspect({ env = env, argv = argv }))
  -- The documented contract itself. Every current adapter behaves the same
  -- given nil or an empty table, so without this cell the (nil, nil) guard
  -- would be a claim nothing checks.
  local applied, aerr = require("auto-run.adapters.config").test_config("go")
  ok("[36c] test_config is (nil, nil) when nothing is configured or selected",
    applied == nil and aerr == nil, vim.inspect({ applied = applied, err = aerr }))

  job.spawn = real_spawn
  import.set_selected(nil); envmod.set_selected(nil)
  disc._reset_for_tests()
  if prev_active then worktree.set_active(prev_active) end
end
section36c()

-- ── [36d] the SELECTED test config is the one that applies ──────────
-- `test_config_name` returned the FIRST kind=test config in store.list()
-- order and never read the per-repo pick memory (`state.picks[kind]`, written
-- by exec.remember_pick and already honoured by exec.pick_config) — though its
-- docstring called the result "the repo's picked config". With two test
-- configs, list order silently decided which env and build flags a test got.
-- Asserts the noun: what job.spawn receives.
print("\n[36d] the selected test config is the one that applies")
local section36d = function()
  local d = fx .. "/pick-go"
  ok("[36d] fixture repo", make_plain_repo(d))
  write_file(d .. "/go.mod", "module pickgo\n\ngo 1.22\n")
  write_file(d .. "/calc.go", "package pickgo\n\nfunc Add(a, b int) int { return a + b }\n")
  write_file(d .. "/calc_test.go",
    "package pickgo\n\nimport \"testing\"\n\nfunc TestAdd(t *testing.T) { if Add(1, 2) != 3 { t.Fatal() } }\n")
  git(d, "add", "."); git(d, "commit", "-q", "-m", "fixture")

  local prev_active = worktree.get_active()
  worktree.set_active(d)
  import.set_selected(nil); envmod.set_selected(nil)
  local exec = require("auto-run.exec")
  exec.clear_pick(nil)

  for _, n in ipairs({ "pick-alpha", "pick-beta" }) do
    store.add({ name = n, kind = "test", runtime = "go", env = { PICK_WHICH = n } }, { tier = "tracked" })
  end
  -- A test config for ANOTHER runtime: picking it must not hijack a go run.
  store.add({ name = "pick-jest", kind = "test", runtime = "jest", env = { PICK_WHICH = "pick-jest" } },
    { tier = "tracked" })

  local disc = P3.discovery
  local job = require("auto-run.exec.job")
  local real_spawn, captured = job.spawn, nil
  job.spawn = function(spec) captured = spec; return { id = spec.id }, nil end
  local function which()
    captured = nil
    disc._reset_for_tests()
    disc.parse_file(d .. "/calc_test.go", require("auto-run.adapters").get("go"))
    disc.run_position(d .. "/calc_test.go::TestAdd")
    return captured and captured.env and captured.env.PICK_WHICH or nil
  end

  -- The fallback, stated rather than assumed: with no pick, the first go test
  -- config in store.list() order.
  local first
  for _, c in ipairs(store.list()) do
    if c.kind == "test" and (c.runtime == nil or c.runtime == "go") then first = c.name break end
  end
  local other = (first == "pick-alpha") and "pick-beta" or "pick-alpha"
  ok("[36d] control: with no pick, the first go test config applies",
    first ~= nil and which() == first, ("first=%s got=%s"):format(tostring(first), tostring(which())))

  exec.remember_pick("test", other)
  ok("[36d] the PICKED test config applies, not the first in list order",
    which() == other, ("picked=%s got=%s"):format(other, tostring(which())))

  exec.remember_pick("test", "pick-jest")
  ok("[36d] a pick for another runtime does not hijack a go run",
    which() == first, ("got=%s"):format(tostring(which())))

  exec.remember_pick("test", "pick-vanished")
  ok("[36d] a stale pick (config gone) falls back to the first, with no error",
    which() == first, ("got=%s"):format(tostring(which())))

  job.spawn = real_spawn
  exec.clear_pick(nil)
  for _, n in ipairs({ "pick-alpha", "pick-beta", "pick-jest" }) do store.remove(n, { tier = "tracked" }) end
  disc._reset_for_tests()
  if prev_active then worktree.set_active(prev_active) end
end
section36d()

-- ── [36e] context — the one answer the pane headers read ─────────────
-- ADR 0199 §5.2: the header states the active worktree, env file, shared base
-- and per-runtime test config. The contract that matters is AGREEMENT: what the
-- header reports must be what executes. So the test-config cells compare the
-- context's answer with the env that actually reaches job.spawn, rather than
-- asserting the context against a copy of the rule.
print("\n[36e] context — the header's answer agrees with what runs")
local section36e = function()
  local ctxm = require("auto-run.context")
  local d = fx .. "/ctx-go"
  ok("[36e] fixture repo", make_plain_repo(d))
  write_file(d .. "/go.mod", "module ctxgo\n\ngo 1.22\n")
  write_file(d .. "/calc.go", "package ctxgo\n\nfunc Add(a, b int) int { return a + b }\n")
  write_file(d .. "/calc_test.go",
    "package ctxgo\n\nimport \"testing\"\n\nfunc TestAdd(t *testing.T) { if Add(1, 2) != 3 { t.Fatal() } }\n")
  write_file(d .. "/.vscode/launch.json", vim.json.encode({ version = "0.2.0", configurations = {
    { name = "CtxBase", type = "go", request = "launch", mode = "debug", program = "${workspaceFolder}" } } }))
  write_file(d .. "/ctx.env", "CTX_ENV=1\n")
  git(d, "add", "."); git(d, "commit", "-q", "-m", "fixture")

  local prev_active = worktree.get_active()
  local exec = require("auto-run.exec")
  import.set_selected(nil); envmod.set_selected(nil); exec.clear_pick(nil)
  ctxm._reset_for_tests()

  -- Active worktree: where auto-run looks, and why.
  worktree.set_active(d)
  local w = ctxm.worktree()
  ok("[36e] an active worktree is reported with source=active",
    w.source == "active" and w.root == d and w.is_repo == true, vim.inspect(w))

  local plain = fx .. "/ctx-not-a-repo"; vim.fn.mkdir(plain, "p")
  worktree.set_active(plain)
  w = ctxm.worktree()
  ok("[36e] a directory that is not a repository says so (is_repo=false, no root)",
    w.is_repo == false and w.root == nil and w.anchor == plain, vim.inspect(w))

  worktree.set_active(nil)
  vim.cmd("enew!")   -- an unnamed buffer: nothing to anchor on but the cwd
  w = ctxm.worktree()
  ok("[36e] with no active worktree and no file buffer the source is cwd",
    w.source == "cwd", vim.inspect(w))

  -- The anchor must NOT follow the current buffer (ADR 0199 §7.2). It used
  -- to fall back to the buffer's directory, so the same pane resolved a
  -- different repository depending on which window was current, and the
  -- discovery tree was dropped and rebuilt whenever focus crossed a repo.
  do
    local paths_mod = require("auto-run.store.paths")
    local cwd0 = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(plain))
    vim.cmd("edit " .. vim.fn.fnameescape(d .. "/calc_test.go"))
    paths_mod.invalidate()
    local a1, s1 = paths_mod.anchor_with_source()
    ok("[36e] no active worktree: a file buffer in another repo does NOT move the anchor",
      a1 == plain and s1 == "cwd", ("anchor=%s source=%s"):format(tostring(a1), tostring(s1)))
    vim.cmd("enew!")
    paths_mod.invalidate()
    local a2 = paths_mod.anchor_with_source()
    ok("[36e] …and switching buffers leaves it where it was", a2 == a1,
      ("before=%s after=%s"):format(tostring(a1), tostring(a2)))
    worktree.set_active(d)
    vim.cmd("edit " .. vim.fn.fnameescape(plain .. "/elsewhere.txt"))
    paths_mod.invalidate()
    local a3, s3 = paths_mod.anchor_with_source()
    ok("[36e] an active worktree wins over the current buffer",
      a3 == d and s3 == "active", ("anchor=%s source=%s"):format(tostring(a3), tostring(s3)))
    vim.cmd("enew!")
    vim.cmd("cd " .. vim.fn.fnameescape(cwd0))
    paths_mod.invalidate()
  end
  worktree.set_active(d)

  -- Branch: from auto-core's repo_at when this auto-core has it.
  local has_repo_at = type(require("auto-core.git.graph").repo_at) == "function"
  ctxm.invalidate()
  w = ctxm.worktree()
  if has_repo_at then
    ok("[36e] the branch is reported (auto-core repo_at present)", w.branch == "main", vim.inspect(w))
    git(d, "checkout", "-q", "-b", "ctx-other")
    ok("[36e] the branch is cached per root until invalidated",
      ctxm.worktree().branch == "main")
    ctxm.invalidate()
    ok("[36e] invalidate re-reads the branch after a checkout",
      ctxm.worktree().branch == "ctx-other", vim.inspect(ctxm.worktree()))
    git(d, "checkout", "-q", "main")
  else
    ok("[36e] no repo_at in this auto-core: no branch, and no error", w.branch == nil, vim.inspect(w))
  end

  -- Env file: selected, missing, none.
  ok("[36e] no env selected -> path nil", ctxm.env().path == nil)
  envmod.set_selected(d .. "/ctx.env")
  local e = ctxm.env()
  ok("[36e] the selected env file is reported and exists", e.path == d .. "/ctx.env" and e.exists, vim.inspect(e))
  os.remove(d .. "/ctx.env")
  ok("[36e] a selected env file that vanished is reported as MISSING, not hidden",
    ctxm.env().path == d .. "/ctx.env" and ctxm.env().exists == false, vim.inspect(ctxm.env()))
  envmod.set_selected(nil)

  -- Shared base.
  ok("[36e] no base selected -> nil", ctxm.base().name == nil)
  import.set_selected("CtxBase")
  ok("[36e] the selected base is reported", ctxm.base().name == "CtxBase", vim.inspect(ctxm.base()))
  import.set_selected(nil)

  -- Test config — AGREEMENT with what reaches the spawn.
  for _, n in ipairs({ "ctx-alpha", "ctx-beta" }) do
    store.add({ name = n, kind = "test", runtime = "go", env = { CTX_WHICH = n } }, { tier = "tracked" })
  end
  store.add({ name = "ctx-jest", kind = "test", runtime = "jest", env = { CTX_WHICH = "ctx-jest" } },
    { tier = "tracked" })
  local disc = P3.discovery
  local job = require("auto-run.exec.job")
  local real_spawn, captured = job.spawn, nil
  job.spawn = function(spec) captured = spec; return { id = spec.id }, nil end
  local function ran()
    captured = nil
    disc._reset_for_tests()
    disc.parse_file(d .. "/calc_test.go", require("auto-run.adapters").get("go"))
    disc.run_position(d .. "/calc_test.go::TestAdd")
    return captured and captured.env and captured.env.CTX_WHICH or nil
  end
  local first
  for _, c in ipairs(store.list()) do
    if c.kind == "test" and (c.runtime == nil or c.runtime == "go") then first = c.name break end
  end
  local other = (first == "ctx-alpha") and "ctx-beta" or "ctx-alpha"
  local cases = {
    { label = "no pick",            pick = nil,           source = "first",  ignored = nil },
    { label = "shared pick applies", pick = other,        source = "shared", ignored = nil },
    { label = "pick is jest's",     pick = "ctx-jest",    source = "first",  ignored = "ctx-jest" },
    { label = "pick has vanished",  pick = "ctx-gone",    source = "first",  ignored = "ctx-gone" },
    -- A runtime pick that no longer applies must stay VISIBLE even when the
    -- shared pick then does: the header would otherwise show the shared pick
    -- as if it were this runtime's choice (Lector, M3a review).
    { label = "stale runtime pick, shared applies", pick = other, rt_pick = "ctx-gone",
      source = "shared", ignored = "ctx-gone" },
  }
  local function set_rt_pick(name)
    -- Written straight to state.json: pick() refuses a name that is not a
    -- config, and a pick going STALE later is exactly the case under test.
    local st = store.read_state()
    st.test_picks = name and { go = name } or nil
    store.write_state(st)
  end
  for _, c in ipairs(cases) do
    exec.clear_pick(nil)
    set_rt_pick(c.rt_pick)
    if c.pick then exec.remember_pick("test", c.pick) end
    local t = ctxm.test_config("go")
    local executed = ran()
    ok(("[36e] %s: the header's test config IS the one that runs"):format(c.label),
      t.name ~= nil and t.name == executed, ("header=%s ran=%s"):format(tostring(t.name), tostring(executed)))
    ok(("[36e] %s: source=%s, ignored_pick=%s"):format(c.label, c.source, tostring(c.ignored)),
      t.source == c.source and t.ignored_pick == c.ignored, vim.inspect(t))
  end
  set_rt_pick(nil)

  -- One call for the whole header. After ran() the go test file is in the
  -- discovery tree, so resolve()'s DEFAULT runtimes must find go by itself.
  ok("[36e] test_runtimes() reports the runtimes that have test positions",
    vim.deep_equal(ctxm.test_runtimes(), { "go" }), vim.inspect(ctxm.test_runtimes()))
  local all = ctxm.resolve()
  ok("[36e] resolve() defaults to the discovered runtimes and carries every header field",
    all.worktree and all.env and all.base and vim.deep_equal(all.runtimes, { "go" })
      and all.tests.go ~= nil, vim.inspect(all))
  disc._reset_for_tests()
  ok("[36e] with nothing discovered, test_runtimes() is empty (the header shows the absence)",
    vim.deep_equal(ctxm.test_runtimes(), {}), vim.inspect(ctxm.test_runtimes()))

  job.spawn = real_spawn
  exec.clear_pick(nil)
  for _, n in ipairs({ "ctx-alpha", "ctx-beta", "ctx-jest" }) do store.remove(n, { tier = "tracked" }) end
  disc._reset_for_tests(); ctxm._reset_for_tests()
  worktree.set_active(prev_active)
end
section36e()

-- ── [36f] test picks are per RUNTIME (ADR 0199 r2 §3.2) ─────────────
-- The pick memory held one name per KIND, so choosing a Rust test config
-- silently replaced the Go one while the header showed them as independent —
-- a hidden state change. Picks now persist per runtime (state.test_picks);
-- the legacy per-kind pick stays as a fallback, so nothing already picked is
-- lost.
print("\n[36f] test picks are per runtime")
local section36f = function()
  local cfgm = require("auto-run.adapters.config")
  local exec = require("auto-run.exec")
  local d = fx .. "/picks-rt"
  ok("[36f] fixture repo", make_plain_repo(d))
  local prev_active = worktree.get_active()
  worktree.set_active(d)
  exec.clear_pick(nil)
  if type(cfgm.pick) == "function" then cfgm.pick("go", nil); cfgm.pick("rust", nil) end
  for _, c in ipairs({ { "go-unit", "go" }, { "go-int", "go" }, { "rs-unit", "rust" }, { "rs-int", "rust" } }) do
    store.add({ name = c[1], kind = "test", runtime = c[2] }, { tier = "tracked" })
  end
  local function eff(rt) local n, src = cfgm.test_config_name(rt); return n, src end
  local function first(rt)
    for _, c in ipairs(store.list()) do
      if c.kind == "test" and c.runtime == rt then return c.name end
    end
  end
  local go_other = first("go") == "go-unit" and "go-int" or "go-unit"
  local rs_other = first("rust") == "rs-unit" and "rs-int" or "rs-unit"

  ok("[36f] the setter exists", type(cfgm.pick) == "function")
  -- Without the setter every later call would raise and ABORT the suite, hiding
  -- every section after this one. A regression must read as red, not as silence.
  if type(cfgm.pick) ~= "function" then worktree.set_active(prev_active); return end
  local changed
  local h = core.events.subscribe("run.config:changed", function(p)
    if p and p.action == "test_picked" then changed = p end
  end)
  local okp, perr = cfgm.pick("go", go_other)
  ok("[36f] pick(go) succeeds", okp == true, tostring(perr))
  ok("[36f] pick publishes run.config:changed {action=test_picked, runtime, name}",
    changed and changed.runtime == "go" and changed.name == go_other, vim.inspect(changed))
  core.events.unsubscribe(h)

  cfgm.pick("rust", rs_other)
  local gn, gs = eff("go"); local rn, rs = eff("rust")
  ok("[36f] choosing for rust does NOT change go's pick",
    gn == go_other and gs == "picked", ("go=%s (%s)"):format(tostring(gn), tostring(gs)))
  ok("[36f] rust has its own pick", rn == rs_other and rs == "picked",
    ("rust=%s (%s)"):format(tostring(rn), tostring(rs)))

  local bad_ok, bad_err = cfgm.pick("go", rs_other)
  ok("[36f] pick refuses a config that is not a test config for that runtime",
    bad_ok == nil and type(bad_err) == "string", tostring(bad_err))
  ok("[36f] …and the refused pick changed nothing", (eff("go")) == go_other)

  -- Legacy per-kind pick: still honoured as a fallback, beaten by a runtime pick.
  cfgm.pick("go", nil)
  exec.remember_pick("test", go_other)
  gn, gs = eff("go")
  ok("[36f] the shared per-kind pick still applies when no runtime pick exists, and says so",
    gn == go_other and gs == "shared", ("go=%s (%s)"):format(tostring(gn), tostring(gs)))
  cfgm.pick("go", first("go"))
  ok("[36f] a runtime pick wins over the shared pick", (eff("go")) == first("go"))

  -- "Clear" does not mean "use the first" while a shared pick exists — it
  -- reveals the shared pick. The chooser must be able to SAY that, from the
  -- same resolver, before the user picks it.
  local has_fb = type(cfgm.fallback_config_name) == "function"
  ok("[36f] fallback_config_name exists", has_fb)
  if has_fb then
    local fn, fsrc = cfgm.fallback_config_name("go")
    ok("[36f] with a runtime pick set, the fallback names the shared pick",
      fn == go_other and fsrc == "shared", ("fallback=%s (%s)"):format(tostring(fn), tostring(fsrc)))
    ok("[36f] …and asking for the fallback changed nothing", (eff("go")) == first("go"))
    cfgm.pick("go", nil)
    ok("[36f] clearing the runtime pick lands exactly on the announced fallback",
      (eff("go")) == fn, ("now=%s announced=%s"):format(tostring((eff("go"))), tostring(fn)))
    cfgm.pick("go", first("go"))
  end

  -- A FAILED write must not read as success. store.write_state reports failure
  -- by returning (false, err) — it does not raise — so a bare pcall around it
  -- reported success and announced a pick that was never saved.
  local real_write = store.write_state
  local fired
  local hw = core.events.subscribe("run.config:changed", function(p)
    if p and p.action == "test_picked" then fired = p end
  end)
  store.write_state = function() return false, "injected: disk full" end
  local wok, werr = cfgm.pick("go", go_other)
  store.write_state = real_write
  core.events.unsubscribe(hw)
  ok("[36f] a failed state write fails the pick", wok == nil and type(werr) == "string"
    and werr:find("injected", 1, true) ~= nil, ("ok=%s err=%s"):format(tostring(wok), tostring(werr)))
  ok("[36f] …publishes nothing", fired == nil, vim.inspect(fired))
  ok("[36f] …and the previous pick still applies", (eff("go")) == first("go"))

  -- The shared pick must ANNOUNCE its changes, as pick() does: a pane showing
  -- it (the tests pane's Test configs section) otherwise never re-renders
  -- after the shared pick is cleared or set elsewhere.
  do
    exec.clear_pick(nil)
    local evs = {}
    local hp = core.events.subscribe("run.config:changed", function(pl)
      if pl and (pl.action == "picked" or pl.action == "pick_cleared") then evs[#evs + 1] = pl end
    end)
    exec.remember_pick("test", go_other)
    exec.remember_pick("test", go_other)
    exec.clear_pick("test")
    exec.clear_pick("test")
    core.events.unsubscribe(hp)
    ok("[36f] remember_pick announces a CHANGED shared pick, once",
      #evs >= 1 and evs[1].action == "picked" and evs[1].kind == "test" and evs[1].name == go_other,
      vim.inspect(evs))
    ok("[36f] clear_pick announces a cleared pick, once; repeats announce nothing",
      #evs == 2 and evs[2].action == "pick_cleared" and evs[2].kind == "test", vim.inspect(evs))
    -- A failed write is not a change: nothing may be announced.
    local real_ws = store.write_state
    store.write_state = function() return false, "injected: disk full" end
    local fired = {}
    local hf = core.events.subscribe("run.config:changed", function(pl) fired[#fired + 1] = pl end)
    exec.remember_pick("test", go_other)
    store.write_state = real_ws
    core.events.unsubscribe(hf)
    ok("[36f] a remember_pick whose write fails announces nothing", #fired == 0, vim.inspect(fired))
    -- clear_pick must REPORT its outcome: a caller that tells the user "cleared"
    -- must not say so when the write failed and the pick is still there
    -- (Lector M5b). Existing callers ignore the return, so this is additive.
    exec.remember_pick("test", go_other)
    store.write_state = function() return false, "injected: read-only" end
    local cok, cerr = exec.clear_pick("test")
    store.write_state = real_ws
    ok("[36f] a clear_pick whose write fails returns (nil, err)",
      cok == nil and type(cerr) == "string" and cerr:find("injected", 1, true) ~= nil,
      ("ok=%s err=%s"):format(tostring(cok), tostring(cerr)))
    ok("[36f] …and the pick is still there", (exec.picks() or {}).test == go_other, vim.inspect(exec.picks()))
    local sok = exec.clear_pick("test")
    ok("[36f] a successful clear_pick returns true", sok == true, tostring(sok))
    ok("[36f] clearing nothing is not a failure either", exec.clear_pick("test") == true)
  end

  cfgm.pick("go", nil); exec.clear_pick(nil)
  gn, gs = eff("go")
  ok("[36f] clearing falls back to the first match", gn == first("go") and gs == "first",
    ("go=%s (%s)"):format(tostring(gn), tostring(gs)))

  cfgm.pick("rust", nil)
  for _, n in ipairs({ "go-unit", "go-int", "rs-unit", "rs-int" }) do store.remove(n, { tier = "tracked" }) end
  worktree.set_active(prev_active)
end
section36f()

-- ── [36g] one scaffold implementation (ADR 0199 §6.2) ───────────────
-- Scaffolding lived inside the <leader>rc keymap callback, keyed on the
-- CURRENT BUFFER's filetype. The panes' `a` runs with the panel as the
-- current buffer, so it could not reuse it — a second copy would drift.
-- adapters.scaffold(kind, name, runtime) is the one implementation.
print("\n[36g] adapters.scaffold — one scaffold implementation")
local section36g = function()
  local reg = require("auto-run.adapters")
  local d = fx .. "/scaffold-api"
  ok("[36g] fixture repo", make_plain_repo(d))
  local prev = worktree.get_active()
  worktree.set_active(d)
  require("auto-run.store.paths").invalidate()
  ok("[36g] adapters.scaffold exists", type(reg.scaffold) == "function")
  ok("[36g] adapters.scaffold_runtimes exists", type(reg.scaffold_runtimes) == "function")
  if type(reg.scaffold) ~= "function" or type(reg.scaffold_runtimes) ~= "function" then
    worktree.set_active(prev); return
  end
  local rts = reg.scaffold_runtimes()
  ok("[36g] scaffold_runtimes lists the adapters that scaffold (go, rust), not jest",
    vim.tbl_contains(rts, "go") and vim.tbl_contains(rts, "rust") and not vim.tbl_contains(rts, "jest"),
    vim.inspect(rts))
  local changed
  local h = core.events.subscribe("run.config:changed", function(pl) changed = pl end)
  local path, err = reg.scaffold("debug", "sc-go", "go")
  core.events.unsubscribe(h)
  local eff = path and store.get("sc-go")
  ok("[36g] scaffold(debug, name, go) stores a go debug config and returns its file",
    type(path) == "string" and vim.fn.filereadable(path) == 1 and eff and eff.kind == "debug"
      and eff.runtime == "go", tostring(err) .. " " .. vim.inspect(eff))
  ok("[36g] …and announces it (the panes re-render)", changed ~= nil, vim.inspect(changed))
  -- The runtime must SELECT the adapter: with go alone, the adapter's defaults
  -- and the go-shaped fallback both say runtime=go, so a scaffold that ignored
  -- `runtime` would pass. Rust's defaults say rust and carry no program.
  local pr, er = reg.scaffold("test", "sc-rs", "rust")
  local effr = pr and store.get("sc-rs")
  ok("[36g] the runtime selects the adapter's defaults (rust → runtime=rust, no program)",
    effr and effr.runtime == "rust" and effr.kind == "test" and effr.program == nil,
    tostring(er) .. " " .. vim.inspect(effr))
  local p2, e2 = reg.scaffold("run", "sc-plain", nil)
  local eff2 = p2 and store.get("sc-plain")
  ok("[36g] no runtime → the historical go-shaped default", eff2 and eff2.kind == "run"
    and eff2.runtime == "go" and eff2.program == "${worktree}/cmd/sc-plain", tostring(e2) .. vim.inspect(eff2))
  local p3, e3 = reg.scaffold("debug", "sc-go", "go")
  ok("[36g] a duplicate name is refused, not overwritten", p3 == nil and type(e3) == "string", tostring(e3))
  local p4, e4 = reg.scaffold("bogus", "sc-bad", "go")
  ok("[36g] an unknown kind is refused", p4 == nil and type(e4) == "string", tostring(e4))
  local p5, e5 = reg.scaffold("run", "", "go")
  ok("[36g] an empty name is refused", p5 == nil and type(e5) == "string", tostring(e5))
  for _, n in ipairs({ "sc-go", "sc-plain", "sc-rs" }) do pcall(store.remove, n) end
  worktree.set_active(prev)
  require("auto-run.store.paths").invalidate()
end
section36g()

-- ── [36h] six commands, dispatching on kind (ADR 0199 §4.1) ──────────
-- Fifteen subcommands shrink to six: run, debug, stop, env, doctor,
-- import. `run` absorbs `test` and `debug` debugs a test config — both
-- dispatch on the config's KIND. What the removed ones did lives in the panes
-- (tests, jobs, list, show, scan), in doctor (validate, last-error) or in the
-- Active-worktree selector (set-dir).
print("\n[36h] :AutoRun — six commands, kind dispatch")
local section36h = function()
  local exec = require("auto-run.exec")
  local darp = require("auto-run.dap")
  local d = fx .. "/cmds"
  ok("[36h] fixture repo", make_plain_repo(d))
  local prev = worktree.get_active()
  worktree.set_active(d)
  require("auto-run.store.paths").invalidate()

  local subs = vim.fn.getcompletion("AutoRun ", "cmdline")
  table.sort(subs)
  ok("[36h] :AutoRun offers exactly six subcommands",
    vim.deep_equal(subs, { "debug", "doctor", "env", "import", "run", "stop" }), vim.inspect(subs))
  for _, gone in ipairs({ "list", "show", "validate", "test", "jobs", "last-error", "tests", "scan", "set-dir" }) do
    local out = vim.api.nvim_exec2("AutoRun " .. gone, { output = true }).output
    ok(("[36h] :AutoRun %s is refused with the usage line"):format(gone),
      out:find("usage: :AutoRun {", 1, true) ~= nil, out)
  end

  -- Kind dispatch, observed at the primitives each path must reach.
  for _, c in ipairs({ { "cmd-test", "test" }, { "cmd-run", "run" }, { "cmd-debug", "debug" } }) do
    store.add({ name = c[1], kind = c[2], runtime = "go", program = "${worktree}" }, { tier = "tracked" })
  end
  local calls = {}
  local real = { tr = exec.test_run, st = exec.start, dt = darp.debug_test, ds = darp.debug_start }
  exec.test_run = function(n) calls[#calls + 1] = "exec.test_run:" .. n; return { id = "x", strategy = "run" } end
  exec.start = function(n) calls[#calls + 1] = "exec.start:" .. n; return { id = "x", strategy = "run" } end
  darp.debug_test = function(n) calls[#calls + 1] = "dap.debug_test:" .. tostring(n); return true end
  darp.debug_start = function(n) calls[#calls + 1] = "dap.debug_start:" .. n; return true end
  local function via(cmd) calls = {}; pcall(vim.cmd, cmd); return calls[1] end
  ok("[36h] run <test config> → exec.test_run", via("AutoRun run cmd-test") == "exec.test_run:cmd-test", vim.inspect(calls))
  ok("[36h] run <run config> → exec.start", via("AutoRun run cmd-run") == "exec.start:cmd-run", vim.inspect(calls))
  ok("[36h] debug <test config> → dap.debug_test", via("AutoRun debug cmd-test") == "dap.debug_test:cmd-test", vim.inspect(calls))
  ok("[36h] debug <debug config> → dap.debug_start", via("AutoRun debug cmd-debug") == "dap.debug_start:cmd-debug", vim.inspect(calls))
  exec.test_run, exec.start, darp.debug_test, darp.debug_start = real.tr, real.st, real.dt, real.ds

  -- stop with no id: exec jobs only (a debug session has its own terminate).
  local real_list, real_stop, real_select = exec.list, exec.stop, vim.ui.select
  local stopped
  exec.stop = function(id) stopped = id; return true end
  exec.list = function() return { { id = "job-1", config = "a", pid = 1 } } end
  stopped = nil; pcall(vim.cmd, "AutoRun stop")
  ok("[36h] stop with no id and one running job stops it", stopped == "job-1", tostring(stopped))
  exec.list = function() return { { id = "job-1", config = "a", pid = 1 }, { id = "job-2", config = "b", pid = 2 } } end
  vim.ui.select = function(items, _, cb) cb(items[2], 2) end
  stopped = nil; pcall(vim.cmd, "AutoRun stop")
  ok("[36h] stop with no id and several running jobs asks which", stopped == "job-2", tostring(stopped))
  exec.list = function() return {} end
  local none = vim.api.nvim_exec2("AutoRun stop", { output = true }).output
  ok("[36h] stop with nothing running says so", none:find("no running jobs", 1, true) ~= nil, none)
  exec.list, exec.stop, vim.ui.select = real_list, real_stop, real_select

  -- doctor absorbs validate and last-error.
  -- A broken config file must SHOW in doctor, by name: a header alone would
  -- pass with the validation report emptied (measured — mutant K4 survived).
  local tracked = store.resolve_run_dirs().tracked
  write_file(tracked .. "/configs/cmd-broken.json", vim.json.encode({ name = "cmd-broken", kind = "nope" }) .. "\n")
  local doc = vim.api.nvim_exec2("AutoRun doctor", { output = true }).output
  ok("[36h] doctor carries the config validation, naming a broken config",
    doc:find("config validation", 1, true) ~= nil and doc:find("file(s) checked", 1, true) ~= nil
      and doc:find("cmd-broken", 1, true) ~= nil, doc:sub(1, 600))
  os.remove(tracked .. "/configs/cmd-broken.json")
  local real_ole, opened = darp.open_last_error, false
  darp.open_last_error = function() opened = true; return true end
  pcall(vim.cmd, "AutoRun doctor --last-error")
  darp.open_last_error = real_ole
  ok("[36h] doctor --last-error opens the captured DAP failure output", opened)

  -- env profile replaces the old <leader>rp profile picker.
  local real_snp, next_p = exec.set_next_profile, "unset"
  exec.set_next_profile = function(n) next_p = n end
  pcall(vim.cmd, "AutoRun env profile clear")
  ok("[36h] env profile clear clears the next-run profile", next_p == nil, tostring(next_p))
  exec.set_next_profile = real_snp
  local ecomp = vim.fn.getcompletion("AutoRun env ", "cmdline")
  ok("[36h] env completes select / clear / profile", vim.tbl_contains(ecomp, "profile"), vim.inspect(ecomp))

  -- No message may send the user to a command that no longer exists.
  local stale = {}
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local files = vim.fn.globpath(root, "lua/**/*.lua", false, true)
  vim.list_extend(files, vim.fn.globpath(root, "plugin/*.lua", false, true))
  files[#files + 1] = root .. "/README.md"
  for _, f in ipairs(files) do
    for lnum, line in ipairs(vim.fn.readfile(f)) do
      for _, gone in ipairs({ "list", "show", "validate", "test", "jobs", "last-error", "tests", "scan", "set-dir" }) do
        if line:find(":AutoRun " .. gone:gsub("%-", "%%-") .. "%f[^%w%-]") then
          stale[#stale + 1] = vim.fn.fnamemodify(f, ":~:.") .. ":" .. lnum
        end
      end
    end
  end
  ok("[36h] no message, doc comment or README line names a removed :AutoRun subcommand",
    #stale == 0, vim.inspect(stale))

  for _, n in ipairs({ "cmd-test", "cmd-run", "cmd-debug" }) do pcall(store.remove, n, { tier = "tracked" }) end
  worktree.set_active(prev)
  require("auto-run.store.paths").invalidate()
end
section36h()

-- ── [36i] keymaps — the ADR 0199 §4.2 table ─────────────────────────
-- Lowercase runs, UPPERCASE debugs, under <leader>r — which is auto-run's
-- alone now: remote-sync moved to <leader>R (Johno, 2026-09-27) after its
-- rp / rc / rl turned out to be shadowed by these very keys.
print("\n[36i] keymaps — the ADR 0199 §4.2 table")
local section36i = function()
  auto_run.default_keymaps()
  local want = {
    rt = "Run: Nearest Test",        rT = "Debug: Nearest Test",
    rf = "Run: Current Test File",   rF = "Debug: Choose a Test in This File",
    rp = "Run: Pick an Entry Point", rP = "Debug: Pick an Entry Point",
    rl = "Run: Again (last run)",    rL = "Debug: Again (last debug)",
    rw = "Run: Working Directory (worktree / folder)",
    dc = "Debug: Continue (resume only)",
    di = "Debug: Step Into", ["do"] = "Debug: Step Over", dO = "Debug: Step Out",
  }
  local bad = {}
  for k, d in pairs(want) do
    local m = vim.fn.maparg("<leader>" .. k, "n", false, true)
    if type(m) ~= "table" or m.desc ~= d then bad[#bad + 1] = k .. " = " .. tostring(m.desc) end
  end
  table.sort(bad)
  ok("[36i] every key in the table is bound, with its description", #bad == 0, vim.inspect(bad))
  local ours = function(m) return type(m) == "table" and type(m.desc) == "string"
    and (m.desc:match("^Run:") or m.desc:match("^Debug:")) end
  local lingering = {}
  for _, k in ipairs({ "rr", "rc", "dt", "dm", "dD" }) do
    if ours(vim.fn.maparg("<leader>" .. k, "n", false, true)) then lingering[#lingering + 1] = k end
  end
  ok("[36i] the replaced keys are gone (rr, rc, dt, dm, dD)", #lingering == 0, vim.inspect(lingering))
  -- …and nothing still TELLS the user to press one.
  local stale = {}
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
  local files = vim.fn.globpath(root, "lua/**/*.lua", false, true)
  vim.list_extend(files, vim.fn.globpath(root, "plugin/*.lua", false, true))
  files[#files + 1] = root .. "/README.md"
  for _, f in ipairs(files) do
    for lnum, line in ipairs(vim.fn.readfile(f)) do
      for _, k in ipairs({ "rr", "rc", "dt", "dm", "dD" }) do
        if line:find("<leader>" .. k .. "%f[^%w]") then
          stale[#stale + 1] = vim.fn.fnamemodify(f, ":~:.") .. ":" .. lnum .. " " .. k
        end
      end
    end
  end
  ok("[36i] no message, doc comment or README line names a removed key", #stale == 0, vim.inspect(stale))
  local leader = vim.g.mapleader or "\\"
  local under_R = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.lhs:sub(1, #leader + 1) == leader .. "R" and ours(m) then under_R[#under_R + 1] = m.lhs end
  end
  ok("[36i] auto-run binds nothing under <leader>R (remote-sync's prefix)", #under_R == 0, vim.inspect(under_R))

  -- da / dA are delve-only: bound in go buffers, never globally.
  ok("[36i] dA is not a global mapping", not ours(vim.fn.maparg("<leader>dA", "n", false, true)))
  vim.cmd("enew!")
  vim.bo.filetype = "go"
  local dA = vim.fn.maparg("<leader>dA", "n", false, true)
  ok("[36i] dA is bound in a go buffer", ours(dA) and dA.buffer == 1, vim.inspect(dA))
  vim.cmd("enew!")

  -- rF: choose a test IN THIS FILE to debug.
  worktree.set_active(gofix)
  require("auto-run.store.paths").invalidate()
  local disc = P3.discovery
  disc._reset_for_tests()
  disc.parse_file(calc_test, P3.adapters.get("go"))
  vim.cmd.edit(vim.fn.fnameescape(calc_test))
  local offered, debugged
  local real_select, real_dp = vim.ui.select, disc.debug_position
  vim.ui.select = function(items, opts, cb)
    offered = items
    for i, it in ipairs(items) do
      local label = opts and opts.format_item and opts.format_item(it) or tostring(it)
      if label:find("TestFail", 1, true) then return cb(it, i) end
    end
    cb(nil, nil)
  end
  disc.debug_position = function(id) debugged = id; return true end
  pcall(vim.fn.maparg("<leader>rF", "n", false, true).callback)
  vim.ui.select, disc.debug_position = real_select, real_dp
  ok("[36i] rF offers this file's tests and debugs the chosen one",
    debugged == calc_test .. "::TestFail" and type(offered) == "table" and #offered >= 2,
    tostring(debugged) .. " " .. vim.inspect(offered))

  -- rp / rP: pick an entry point, dispatching on kind (the :AutoRun run/debug rule).
  local exec, darp = P2.exec, require("auto-run.dap")
  -- Own fixture: the dispatch reads the config's kind, so it must exist here.
  if not store.get("gofix-tests") then
    store.add({ name = "gofix-tests", kind = "test", runtime = "go", program = "./calc" }, { tier = "tracked" })
  end
  local calls = {}
  local real = { pc = exec.pick_config, tr = exec.test_run, st = exec.start, dt = darp.debug_test, ds = darp.debug_start }
  exec.pick_config = function(_, cb) cb("gofix-tests") end
  exec.test_run = function(n) calls[#calls + 1] = "test_run:" .. n; return { id = "x", strategy = "run" } end
  exec.start = function(n) calls[#calls + 1] = "start:" .. n; return { id = "x", strategy = "run" } end
  darp.debug_test = function(n) calls[#calls + 1] = "debug_test:" .. tostring(n); return true end
  darp.debug_start = function(n) calls[#calls + 1] = "debug_start:" .. n; return true end
  pcall(vim.fn.maparg("<leader>rp", "n", false, true).callback)
  pcall(vim.fn.maparg("<leader>rP", "n", false, true).callback)
  exec.pick_config, exec.test_run, exec.start = real.pc, real.tr, real.st
  darp.debug_test, darp.debug_start = real.dt, real.ds
  ok("[36i] rp / rP dispatch a picked test config to test_run / debug_test",
    vim.deep_equal(calls, { "test_run:gofix-tests", "debug_test:gofix-tests" }), vim.inspect(calls))
end
section36i()

-- ── [36j] Again: replay the last run / debug (ADR 0199 §4.2a) ──────────
-- Recorded once, at the TRUE launch boundary: a run when its job spawned, a
-- debug when the launch reached nvim-dap — never at the synchronous return of
-- an async prepare, which can still fail or be cancelled. The record is a
-- descriptor (position id / config name + the anchor it ran under), so a
-- replay re-resolves; a target that is gone, or a changed active worktree, is
-- refused rather than silently substituted.
print("\n[36j] Again — the last-run recorder")
local section36j = function()
  local okl, last = pcall(require, "auto-run.last")
  ok("[36j] auto-run.last exists", okl, tostring(last))
  if not okl then return end
  last._reset_for_tests()
  worktree.set_active(gofix)
  require("auto-run.store.paths").invalidate()
  local disc = P3.discovery
  disc._reset_for_tests()
  disc.parse_file(calc_test, P3.adapters.get("go"))
  local job = require("auto-run.exec.job")
  local real_spawn = job.spawn
  local spawned = {}
  job.spawn = function(spec) spawned[#spawned + 1] = spec; return { id = spec.id }, nil end
  local function ran(needle)
    for _, sp in ipairs(spawned) do
      if table.concat(sp.cmd or {}, " "):find(needle, 1, true) then return true end
    end
    return false
  end
  local fail_id = calc_test .. "::TestFail"

  -- A position run — what the tests pane's `r` calls — is recorded.
  disc.run_position(fail_id)
  local d = last.peek("run")
  ok("[36j] a position run (the tests pane's path) is recorded as a descriptor",
    d and d.via == "position" and d.id == fail_id and d.anchor == gofix, vim.inspect(d))
  spawned = {}
  local okr, rerr = last.replay("run")
  ok("[36j] Again re-runs that position", okr and ran("TestFail"), tostring(rerr) .. vim.inspect(spawned))

  -- A config run is recorded, and replays by name.
  store.add({ name = "last-run", kind = "run", runtime = "go", program = "${worktree}/calc" }, { tier = "tracked" })
  P2.exec.start("last-run")
  d = last.peek("run")
  ok("[36j] a config run is recorded by name", d and d.via == "config" and d.name == "last-run", vim.inspect(d))

  -- Refusals: a vanished config, a vanished position, a changed worktree.
  store.remove("last-run", { tier = "tracked" })
  spawned = {}
  okr, rerr = last.replay("run")
  ok("[36j] a config that no longer exists is refused, not substituted",
    okr == nil and tostring(rerr):find("last-run", 1, true) ~= nil and #spawned == 0, tostring(rerr))
  disc.run_position(fail_id)
  disc._reset_for_tests()
  spawned = {}
  okr, rerr = last.replay("run")
  ok("[36j] a position that is no longer discovered is refused",
    okr == nil and tostring(rerr):find("TestFail", 1, true) ~= nil and #spawned == 0, tostring(rerr))
  disc.parse_file(calc_test, P3.adapters.get("go"))
  disc.run_position(fail_id)
  worktree.set_active(jestfix)
  require("auto-run.store.paths").invalidate()
  spawned = {}
  okr, rerr = last.replay("run")
  ok("[36j] after a worktree change, Again refuses and names where the last run was",
    okr == nil and tostring(rerr):find(gofix, 1, true) ~= nil and #spawned == 0, tostring(rerr))
  -- The anchor check on its own: a config NAME present in both worktrees would
  -- otherwise re-run silently in the other repo (the position case above is
  -- also refused by the discovery tree, so it cannot isolate this).
  worktree.set_active(gofix); require("auto-run.store.paths").invalidate()
  store.add({ name = "both-trees", kind = "run", runtime = "go", program = "${worktree}" }, { tier = "tracked" })
  worktree.set_active(jestfix); require("auto-run.store.paths").invalidate()
  store.add({ name = "both-trees", kind = "run", runtime = "go", program = "${worktree}" }, { tier = "tracked" })
  worktree.set_active(gofix); require("auto-run.store.paths").invalidate()
  P2.exec.start("both-trees")
  worktree.set_active(jestfix); require("auto-run.store.paths").invalidate()
  spawned = {}
  okr, rerr = last.replay("run")
  ok("[36j] a config name that exists in BOTH worktrees is not re-run in the other one",
    okr == nil and tostring(rerr):find(gofix, 1, true) ~= nil and #spawned == 0,
    tostring(rerr) .. " spawned=" .. #spawned)
  store.remove("both-trees", { tier = "tracked" })
  worktree.set_active(gofix); require("auto-run.store.paths").invalidate()
  store.remove("both-trees", { tier = "tracked" })
  worktree.set_active(gofix)
  require("auto-run.store.paths").invalidate()
  disc._reset_for_tests()
  disc.parse_file(calc_test, P3.adapters.get("go"))
  job.spawn = real_spawn

  -- Debug: recorded only when the launch reaches nvim-dap.
  local go = P3.adapters.get("go")
  local darp = require("auto-run.dap")
  local real_pd, real_launch = go.prepare_debug, darp.launch
  local launched = 0
  darp.launch = function() launched = launched + 1; return true end
  last._reset_for_tests()
  go.prepare_debug = function(_, _, cb) cb(nil, { message = "injected build failure" }) end
  disc.debug_position(fail_id)
  ok("[36j] a debug whose async prepare FAILS is not recorded", last.peek("debug") == nil, vim.inspect(last.peek("debug")))
  go.prepare_debug = function(_, token, cb) token.cancelled = true; cb({ dap_type = "go", program = "x" }) end
  disc.debug_position(fail_id)
  ok("[36j] a debug CANCELLED mid-prepare is not recorded", last.peek("debug") == nil and launched == 0,
    vim.inspect(last.peek("debug")) .. " launched=" .. launched)
  darp.launch = function() launched = launched + 1; return nil, "injected dap.run failure" end
  go.prepare_debug = function(_, _, cb) cb({ dap_type = "go", program = "x" }) end
  disc.debug_position(fail_id)
  ok("[36j] a debug whose launch FAILS is not recorded", last.peek("debug") == nil, vim.inspect(last.peek("debug")))
  darp.launch = function() launched = launched + 1; return true end
  disc.debug_position(fail_id)
  d = last.peek("debug")
  ok("[36j] a debug that reaches nvim-dap is recorded, once", d and d.via == "position" and d.id == fail_id,
    vim.inspect(d))
  local replayed_id
  local real_dp = disc.debug_position
  disc.debug_position = function(id) replayed_id = id; return true end
  okr, rerr = last.replay("debug")
  disc.debug_position = real_dp
  ok("[36j] Again (debug) debugs the same position", okr and replayed_id == fail_id, tostring(rerr))
  -- Lector M6 P2: an async debug started in worktree A and completed after a
  -- switch to B must be recorded as A's — never B's, which would let Again in
  -- B replay A's debug against B's configs.
  do
    local paths_mod = require("auto-run.store.paths")
    local pending
    go.prepare_debug = function(_, _, cb) pending = cb end
    last._reset_for_tests()
    worktree.set_active(gofix); paths_mod.invalidate()
    disc.debug_position(fail_id)
    worktree.set_active(jestfix); paths_mod.invalidate()
    pending({ dap_type = "go", program = "x" })
    local dd = last.peek("debug")
    ok("[36j] an async position debug is recorded under the worktree it STARTED in",
      dd and dd.anchor == gofix, vim.inspect(dd))
    local okx, errx = last.replay("debug")
    ok("[36j] …so Again in the other worktree refuses it, naming where it ran",
      okx == nil and tostring(errx):find(gofix, 1, true) ~= nil, tostring(errx))

    worktree.set_active(gofix); paths_mod.invalidate()
    store.add({ name = "dbg-a", kind = "debug", runtime = "go", program = "${worktree}/calc" }, { tier = "tracked" })
    local real_pdc = go.prepare_debug_config
    go.prepare_debug_config = function(_, _, cb) pending = cb end
    last._reset_for_tests()
    pending = nil
    darp.debug_start("dbg-a")
    worktree.set_active(jestfix); paths_mod.invalidate()
    if pending then pending({ dap_type = "go", program = "x" }) end
    dd = last.peek("debug")
    ok("[36j] an async config debug is recorded under the worktree it STARTED in",
      dd and dd.anchor == gofix and dd.name == "dbg-a", vim.inspect(dd))
    go.prepare_debug_config = real_pdc
    worktree.set_active(gofix); paths_mod.invalidate()
    store.remove("dbg-a", { tier = "tracked" })
  end
  go.prepare_debug, darp.launch = real_pd, real_launch

  -- A test-config debug replays from its file; a vanished config must be
  -- refused BEFORE that jump moves the user.
  local saved_dg = package.loaded["dap-go"]
  package.loaded["dap-go"] = { debug_test = function() end, setup = function() end }
  store.add({ name = "last-dbg", kind = "test", runtime = "go", program = "./calc" }, { tier = "tracked" })
  vim.cmd.edit(vim.fn.fnameescape(calc_test))
  darp.debug_test("last-dbg")
  d = last.peek("debug")
  ok("[36j] a test-config debug is recorded with where it resolved the test",
    d and d.via == "test_config" and d.name == "last-dbg" and d.path == calc_test, vim.inspect(d))
  store.remove("last-dbg", { tier = "tracked" })
  vim.cmd("enew!")
  local here_buf = vim.api.nvim_get_current_buf()
  okr, rerr = last.replay("debug")
  ok("[36j] a vanished test config is refused before the jump (the buffer stays put)",
    okr == nil and tostring(rerr):find("last-dbg", 1, true) ~= nil and vim.api.nvim_get_current_buf() == here_buf,
    tostring(rerr) .. " buf=" .. vim.api.nvim_buf_get_name(0))
  package.loaded["dap-go"] = saved_dg

  -- rL with nothing recorded falls back to nvim-dap's own run_last.
  last._reset_for_tests()
  local dapm = require("dap")
  local real_rl, rl_calls = dapm.run_last, 0
  dapm.run_last = function() rl_calls = rl_calls + 1 end
  auto_run.default_keymaps()
  pcall(vim.fn.maparg("<leader>rL", "n", false, true).callback)
  dapm.run_last = real_rl
  ok("[36j] rL with nothing recorded falls back to nvim-dap's run_last", rl_calls == 1, "calls=" .. rl_calls)
end
section36j()

-- ── [36k] the store and env APIs the panes' management needs (ADR 0199 §6.5)
-- After v0.1.15 a user still had to open files to delete an env variable,
-- create an env file, or edit / delete an env profile. The panes can only
-- offer those if the owner has them.
print("\n[36k] env.create_file / remove_var, store profile update / remove")
local section36k = function()
  local envm = require("auto-run.env")
  local d = fx .. "/mgmt"
  ok("[36k] fixture repo", make_plain_repo(d))
  local prev = worktree.get_active()
  worktree.set_active(d)
  require("auto-run.store.paths").invalidate()
  ok("[36k] the APIs exist", type(envm.create_file) == "function" and type(envm.remove_var) == "function")
  if type(envm.create_file) ~= "function" or type(envm.remove_var) ~= "function" then
    worktree.set_active(prev); return
  end
  local evs = {}
  local h = core.events.subscribe("run.env:changed", function(pl) evs[#evs + 1] = pl end)

  -- create_file
  local nf = d .. "/.env.local"
  local cok, cerr = envm.create_file(nf)
  ok("[36k] create_file makes an empty env file", cok == true and vim.fn.filereadable(nf) == 1
    and #vim.fn.readfile(nf) == 0, tostring(cerr and cerr.message or cerr))
  local listed = false
  for _, c in ipairs(envm.files_list()) do if c.path == nf then listed = true end end
  ok("[36k] …which env discovery lists at once", listed)
  ok("[36k] …and it is announced", evs[#evs] and evs[#evs].action == "created" and evs[#evs].path == nf,
    vim.inspect(evs[#evs]))
  local c2, e2 = envm.create_file(nf)
  ok("[36k] an existing file is refused, never truncated", c2 == nil and e2 and e2.code == "already_exists",
    vim.inspect(e2))
  local c3, e3 = envm.create_file(fx .. "/outside-the-worktree.env")
  ok("[36k] a path outside the worktree is refused", c3 == nil and e3 and e3.code == "outside_worktree",
    vim.inspect(e3))
  local nested = d .. "/.config/dev.env"
  ok("[36k] a missing parent directory under the worktree is created", envm.create_file(nested) == true
    and vim.fn.filereadable(nested) == 1)

  -- Lector r7: the bound is checked on REAL paths, and the create is exclusive.
  local outside = fx .. "/mgmt-outside"
  vim.fn.mkdir(outside, "p")
  vim.uv.fs_symlink(outside, d .. "/.vscode")
  local c4, e4 = envm.create_file(d .. "/.vscode/escape.env")
  ok("[36k] a symlinked parent that leads outside the worktree is refused, and nothing is written there",
    c4 == nil and e4 and e4.code == "outside_worktree" and vim.fn.filereadable(outside .. "/escape.env") == 0,
    vim.inspect(e4))
  local c5, e5 = envm.create_file(d .. "/deep/sub/x.env")
  ok("[36k] a location env discovery does not scan is refused (the file would be invisible)",
    c5 == nil and e5 and e5.code == "not_discoverable", vim.inspect(e5))
  local c6, e6 = envm.create_file(d .. "/notes.txt")
  ok("[36k] a name env discovery does not recognise is refused", c6 == nil and e6 and e6.code == "invalid_name",
    vim.inspect(e6))
  -- Exclusivity: fool the existence pre-check (a file appearing between check
  -- and create); the create itself must still refuse rather than truncate.
  write_file(d .. "/.env.race", "KEEP=1\n")
  local real_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(pth, ...) if pth == d .. "/.env.race" then return nil end return real_stat(pth, ...) end
  local c7, e7 = envm.create_file(d .. "/.env.race")
  vim.uv.fs_stat = real_stat
  ok("[36k] the create is exclusive: a file that appears after the check is never truncated",
    c7 == nil and e7 and e7.code == "already_exists" and vim.deep_equal(vim.fn.readfile(d .. "/.env.race"), { "KEEP=1" }),
    vim.inspect(e7) .. vim.inspect(vim.fn.readfile(d .. "/.env.race")))

  -- remove_var
  write_file(nf, "# keep this comment\nA=1\nSECRET=hunter2\nB=2\n")
  evs = {}
  local rok, rerr = envm.remove_var(nf, "SECRET")
  ok("[36k] remove_var drops exactly that line", rok == true
    and vim.deep_equal(vim.fn.readfile(nf), { "# keep this comment", "A=1", "B=2" }),
    tostring(rerr and rerr.message) .. vim.inspect(vim.fn.readfile(nf)))
  ok("[36k] …and announces it without the value", evs[1] and evs[1].action == "removed" and evs[1].key == "SECRET"
    and not vim.inspect(evs):find("hunter2", 1, true), vim.inspect(evs))
  -- Lector #13 P1: a duplicated key. parse_env_file is last-wins, so removing
  -- only the last line would resurrect the older value — for a secret, a
  -- credential the user believes deleted.
  write_file(nf, "SECRET=old-credential\nA=1\nSECRET=new-credential\n")
  envm.remove_var(nf, "SECRET")
  local parsed = envm.parse_env_file(nf)
  ok("[36k] remove_var removes EVERY occurrence of a duplicated key (none resurfaces)",
    type(parsed) == "table" and parsed.SECRET == nil and vim.deep_equal(vim.fn.readfile(nf), { "A=1" }),
    vim.inspect(parsed) .. vim.inspect(vim.fn.readfile(nf)))
  local r2, re2 = envm.remove_var(nf, "SECRET")
  ok("[36k] removing a key that is not there is not_found", r2 == nil and re2 and re2.code == "not_found", vim.inspect(re2))
  local r3, re3 = envm.remove_var(nf, "not a key")
  ok("[36k] an invalid key is refused", r3 == nil and re3 and re3.code == "invalid_key", vim.inspect(re3))
  core.events.unsubscribe(h)

  -- profiles: update / remove, never rewriting a committed (tracked) file
  local tracked_path = store.add({ name = "mgmt-prof", base_env_files = { "${worktree}/.env" } }, { kind = "profiles", tier = "tracked" })
  ok("[36k] fixture: a tracked profile", type(tracked_path) == "string", tostring(tracked_path))
  local before = table.concat(vim.fn.readfile(tracked_path), "\n")
  local up, uerr = store.update("mgmt-prof", { runtime_env = { MODE = "dev" } }, { kind = "profiles" })
  local prof = store.get_profile("mgmt-prof")
  ok("[36k] store.update patches a profile (kind=profiles)", up ~= nil and prof and prof.runtime_env
    and prof.runtime_env.MODE == "dev" and vim.deep_equal(prof.base_env_files, { "${worktree}/.env" }),
    tostring(uerr) .. vim.inspect(prof))
  ok("[36k] …in the local tier: the committed file is untouched",
    table.concat(vim.fn.readfile(tracked_path), "\n") == before)
  local bad, berr = store.update("mgmt-prof", { program = "x" }, { kind = "profiles" })
  ok("[36k] a field profiles do not have is refused", bad == nil and type(berr) == "string", tostring(berr))
  local nf2, nferr = store.update("no-such-prof", { runtime_env = { A = "1" } }, { kind = "profiles" })
  ok("[36k] updating a profile that does not exist is refused", nf2 == nil and tostring(nferr):find("not found", 1, true) ~= nil,
    tostring(nferr))
  -- Where a record lives, per tier — what a pane's delete confirm must name
  -- (it never rebuilds the store's layout itself).
  local okf = type(store.files) == "function"
  ok("[36k] store.files exists", okf)
  if okf then
    local tiers = store.files("mgmt-prof", { kind = "profiles" })
    ok("[36k] store.files names both tiers of a profile with a local overlay",
      tiers and tiers.tracked == tracked_path and type(tiers.shared) == "string" and vim.fn.filereadable(tiers.shared) == 1,
      vim.inspect(tiers))
    ok("[36k] config_file(name, {kind=profiles}) finds the profile's file",
      store.config_file("mgmt-prof", { kind = "profiles" }) == tracked_path,
      tostring(store.config_file("mgmt-prof", { kind = "profiles" })))
    ok("[36k] store.files is empty for a name that is not there",
      vim.deep_equal(store.files("no-such", { kind = "profiles" }), {}), vim.inspect(store.files("no-such", { kind = "profiles" })))
  end
  -- Lector #13 P1/P2: an APPEND-rule list (env_files, base_env_files,
  -- secret_manifests) edited as a whole. The pane shows the EFFECTIVE list, so
  -- what the user enters must become the effective list: without a replace
  -- marker the overlay APPENDS to the tracked layer — [A] edited to [A,B]
  -- became [A,A,B], and edited to [B] left A active.
  store.update("mgmt-prof", { base_env_files = { "${worktree}/.env", "${worktree}/.env.b" } },
    { kind = "profiles", replace = { "base_env_files" } })
  ok("[36k] a replace edit makes a profile's list exactly what was entered",
    vim.deep_equal(store.get_profile("mgmt-prof").base_env_files, { "${worktree}/.env", "${worktree}/.env.b" }),
    vim.inspect(store.get_profile("mgmt-prof").base_env_files))
  store.update("mgmt-prof", { base_env_files = { "${worktree}/.env.b" } }, { kind = "profiles", replace = { "base_env_files" } })
  ok("[36k] …including dropping an inherited (tracked) entry",
    vim.deep_equal(store.get_profile("mgmt-prof").base_env_files, { "${worktree}/.env.b" }),
    vim.inspect(store.get_profile("mgmt-prof").base_env_files))
  ok("[36k] …and the marker never reaches the effective record", store.get_profile("mgmt-prof").replace == nil)
  -- The same for a CONFIG (the debug pane's env_files row, shipped in v0.1.15
  -- / auto-finder v0.5.1): a tracked config's edit routes to overrides.json.
  store.add({ name = "mgmt-cfg", kind = "run", runtime = "go", program = "sh", env_files = { "${worktree}/.env" } },
    { tier = "tracked" })
  store.update("mgmt-cfg", { env_files = { "${worktree}/.env.b" } }, { replace = { "env_files" } })
  local ce = store.get("mgmt-cfg")
  ok("[36k] a config's env_files edit (overrides layer) replaces the inherited list exactly",
    ce and vim.deep_equal(ce.env_files, { "${worktree}/.env.b" }) and ce.replace == nil, vim.inspect(ce and ce.env_files))
  store.update("mgmt-cfg", { env_files = { "${worktree}/.env.c" } })
  ok("[36k] CONTROL — without replace, a list edit still appends (the layering rule is unchanged)",
    vim.deep_equal(store.get("mgmt-cfg").env_files, { "${worktree}/.env", "${worktree}/.env.c" }),
    vim.inspect(store.get("mgmt-cfg").env_files))
  store.remove("mgmt-cfg", { tier = "tracked" })
  local rm1 = store.remove("mgmt-prof", { kind = "profiles" })
  local after1 = store.get_profile("mgmt-prof")
  ok("[36k] store.remove (kind=profiles) removes the local layer first", rm1 == true and after1
    and after1.runtime_env == nil, vim.inspect(after1))
  local rm2 = store.remove("mgmt-prof", { kind = "profiles" })
  ok("[36k] …then the committed one; the profile is gone", rm2 == true and store.get_profile("mgmt-prof") == nil)
  local cfg_left = store.get("mgmt-prof")
  ok("[36k] removing a profile never touches a config of the same name", cfg_left == nil)

  worktree.set_active(prev)
  require("auto-run.store.paths").invalidate()
end
section36k()

-- ── [37] dap failed-start capture — no false positive on success ──
-- Runs LAST: the genuine-failure assertion persists `last_failure` in the
-- dap module, so keeping it here avoids polluting the `:AutoRun last-error`
-- expectation earlier in the suite (which assumes nothing captured yet).
-- Regression: `initialized` was reset in before.launch, which races the
-- adapter's `initialized` event — that event can land BEFORE the launch
-- request, so the launch-time reset clobbered the latch for the whole
-- (successful) session, and delve's harmless teardown chatter
-- ("Type 'dlv help' …") was misreported as a failed start. Baseline now
-- resets on `initialize` (guaranteed pre-init) and launch clears only output.
print("\n[37] dap failed-start capture — false-positive regression")
do
  local okd, dap = pcall(require, "dap")
  ok("real nvim-dap on rtp (§37)", okd, tostring(dap))
  local darp = require("auto-run.dap")
  local L, K = dap.listeners, "auto-run-errors"
  local baseline = darp.last_error()
  -- Successful session, driven in the racy order: initialized BEFORE launch.
  L.before.initialize[K](nil)
  L.after.event_initialized[K](nil)
  L.before.launch[K](nil)
  L.after.event_output[K](nil,
    { category = "console", output = "Type 'dlv help' for list of commands." })
  L.after.event_terminated[K](nil, {})
  ok("successful session records NO false-positive failed-start",
    darp.last_error() == baseline, tostring(darp.last_error()))
  -- Genuine failed start (no `initialized` event) is still captured.
  L.before.initialize[K](nil)
  L.before.launch[K](nil)
  L.after.event_output[K](nil,
    { category = "stderr", output = "Build error: could not launch process\n" })
  L.after.event_terminated[K](nil, {})
  local captured = darp.last_error()
  ok("genuine failed start is still captured",
    type(captured) == "string" and captured:find("Build error", 1, true) ~= nil,
    tostring(captured))
end
-- ══ Rust §7 acceptance matrix (ADR 0194) ════════════════════════
-- A real TWO-PACKAGE Cargo workspace carrying every shape the review calls
-- for: a RENAMED [lib] target, an explicit [[bin]] at a custom path, a src
-- submodule, an integration target, DUPLICATE test names across targets, an
-- #[ignore] test, a failing test, and a #[cfg(test)] helper that is NOT a test.
local rustws = fx .. "/rustws"
local rust_cells = 0
local function rok(name, cond, detail)
  rust_cells = rust_cells + 1
  ok(name, cond, detail)
end
local HAVE_CARGO = vim.fn.executable("cargo") == 1
local HAVE_RUST_TS = pcall(vim.treesitter.get_string_parser, "fn f(){}", "rust")

make_plain_repo(rustws)
write_file(rustws .. "/Cargo.toml",
  '[workspace]\nmembers = ["cratea", "crateb", "cratec"]\nresolver = "2"\n')
-- cratec has exactly ONE bin, so a workspace-ROOT cwd plus a named package
-- must still resolve it (the cwd crate cannot supply targets there).
write_file(rustws .. "/cratec/Cargo.toml",
  '[package]\nname = "cratec"\nversion = "0.1.0"\nedition = "2021"\n')
write_file(rustws .. "/cratec/src/main.rs", "fn main() {}\n")
write_file(rustws .. "/cratea/Cargo.toml",
  '[package]\nname = "cratea"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\nname = "cratea_lib"\n')
write_file(rustws .. "/cratea/src/lib.rs", table.concat({
  "pub mod util;",
  "pub mod util_extra;",
  "pub fn add(a: i32, b: i32) -> i32 { a + b }",
  "#[cfg(test)]",
  "mod tests {",
  "    use super::*;",
  "    fn helper() -> i32 { 3 }",
  "    #[test] fn adds() { assert_eq!(add(1, 2), helper()); }",
  "    #[test] fn fails() { assert_eq!(add(1, 1), 3); }",
  "    #[test] #[ignore] fn skipped() {}",
  "}",
}, "\n") .. "\n")
write_file(rustws .. "/cratea/src/util.rs", table.concat({
  "pub fn double(x: i32) -> i32 { x * 2 }",
  "#[cfg(test)]",
  "mod tests {",
  "    use super::*;",
  "    #[test] fn util_only() { assert_eq!(double(2), 4); }",
  "}",
}, "\n") .. "\n")
-- A PREFIX-COLLIDING sibling module: `util_extra` shares the `util` prefix, so
-- a boundary-less libtest filter (`util`) would execute it. Its test PANICS, so
-- any run that reaches it fails loudly — this is the cell that falsifies a
-- missing `::` boundary (Lector r1 P1-2).
write_file(rustws .. "/cratea/src/util_extra.rs", table.concat({
  "#[cfg(test)]",
  "mod tests {",
  "    #[test] fn must_not_run() { panic!(\"unrelated sibling module executed\"); }",
  "}",
}, "\n") .. "\n")
write_file(rustws .. "/cratea/tests/it.rs", "#[test] fn adds() { assert!(true); }\n")
write_file(rustws .. "/crateb/Cargo.toml",
  '[package]\nname = "crateb"\nversion = "0.1.0"\nedition = "2021"\n\n[[bin]]\nname = "customtool"\npath = "src/tool.rs"\n')
write_file(rustws .. "/crateb/src/main.rs",
  "fn main() {}\n#[cfg(test)]\nmod tests { #[test] fn main_unit() { assert!(true); } }\n")
write_file(rustws .. "/crateb/src/tool.rs", "fn main() {}\n")

local function assign_ids(n)
  for _, c in ipairs(n.children or {}) do
    c.id = (n.type == "file" and n.path or n.id) .. "::" .. c.name
    assign_ids(c)
  end
end

print("\n[38] rust — cargo-metadata identity, discovery, position scoping")
do
  local R = P3.adapters.get("rust")
  R._reset_for_tests()
  rok("rust adapter self-registered", R ~= nil and R.name == "rust")
  rok("adapter_for(.rs) resolves to rust",
    (P3.adapters.adapter_for(rustws .. "/cratea/src/lib.rs") or {}).name == "rust")
  rok("root() promotes a member crate to the [workspace] root",
    R.root(rustws .. "/cratea/src") == rustws, tostring(R.root(rustws .. "/cratea/src")))
  rok("is_test_file accepts a crate .rs", R.is_test_file(rustws .. "/cratea/src/lib.rs"))
  rok("is_test_file rejects Cargo.toml", not R.is_test_file(rustws .. "/cratea/Cargo.toml"))
  rok("is_test_file rejects a build script", not R.is_test_file(rustws .. "/cratea/build.rs"))

  if not HAVE_CARGO then
    print("  [38] cargo not on PATH — identity/scoping cells skipped")
  else
    local lib = R.identity(rustws .. "/cratea/src/lib.rs")
    rok("identity binds the RENAMED [lib] target from cargo metadata",
      lib ~= nil and lib.kind == "lib" and lib.target == "cratea_lib"
        and lib.package == "cratea", vim.inspect(lib))
    rok("identity carries the metadata package_id",
      lib ~= nil and type(lib.package_id) == "string"
        and lib.package_id:find("cratea", 1, true) ~= nil, lib and lib.package_id)
    rok("lib selectors are -p <pkg> --lib",
      lib ~= nil and contains(lib.selectors, "-p") and contains(lib.selectors, "cratea")
        and contains(lib.selectors, "--lib"), vim.inspect(lib and lib.selectors))
    local util = R.identity(rustws .. "/cratea/src/util.rs")
    rok("a src submodule inherits the lib target with its module prefix",
      util ~= nil and util.kind == "lib" and util.module_prefix == "util", vim.inspect(util))
    local it = R.identity(rustws .. "/cratea/tests/it.rs")
    rok("identity binds the integration target (--test it)",
      it ~= nil and it.kind == "test" and it.target == "it"
        and contains(it.selectors, "--test"), vim.inspect(it))
    local tool = R.identity(rustws .. "/crateb/src/tool.rs")
    rok("identity binds an EXPLICIT [[bin]] at a custom path (customtool)",
      tool ~= nil and tool.kind == "bin" and tool.target == "customtool", vim.inspect(tool))
    local mainbin = R.identity(rustws .. "/crateb/src/main.rs")
    rok("identity binds the default bin of the SECOND workspace package",
      mainbin ~= nil and mainbin.kind == "bin" and mainbin.package == "crateb",
      vim.inspect(mainbin))

    local dir_spec, dir_err = R.build_spec({
      position = { type = "dir", path = rustws .. "/cratea", id = rustws .. "/cratea" } })
    rok("a DIR scope returns (nil, nil) so the core decomposes to files",
      dir_spec == nil and dir_err == nil,
      tostring(dir_spec) .. "/" .. tostring(dir_err))

    local libfile = rustws .. "/cratea/src/lib.rs"
    local file_spec, file_err = R.build_spec({
      position = { type = "file", path = libfile, id = libfile,
        children = { { type = "test", name = "adds", path = libfile,
          id = libfile .. "::tests::adds" } } } })
    rok("a crate-ROOT file with no module prefix decomposes (never a whole-target run)",
      file_spec == nil and file_err == nil, vim.inspect(file_spec and file_spec.cmd))

    local utilfile = rustws .. "/cratea/src/util.rs"
    local mod_spec = R.build_spec({
      position = { type = "namespace", name = "tests", path = utilfile,
        id = utilfile .. "::tests",
        children = { { type = "test", name = "util_only", path = utilfile,
          id = utilfile .. "::tests::util_only" } } } })
    rok("a namespace scope filters by <module_prefix>::<mod>:: (boundary-safe)",
      mod_spec ~= nil and contains(mod_spec.cmd, "util::tests::"),
      vim.inspect(mod_spec and mod_spec.cmd))

    local ufile_spec = R.build_spec({
      position = { type = "file", path = utilfile, id = utilfile,
        children = { { type = "test", name = "util_only", path = utilfile,
          id = utilfile .. "::tests::util_only" } } } })
    rok("a file scope emits the `util::` module BOUNDARY, not a bare `util`",
      ufile_spec ~= nil and contains(ufile_spec.cmd, "util::")
        and not contains(ufile_spec.cmd, "util"),
      vim.inspect(ufile_spec and ufile_spec.cmd))

    local one = R.build_spec({
      position = { type = "test", name = "util_only", path = utilfile,
        id = utilfile .. "::tests::util_only" } })
    rok("a single test runs --exact with valid Cargo/libtest ordering",
      one ~= nil and table.concat(one.cmd, " ") ==
        "cargo test -p cratea --lib util::tests::util_only -- --exact --format pretty --color never",
      vim.inspect(one and one.cmd))
    rok("the spec carries the package_id for result scoping",
      one ~= nil and type(one.context.package_id) == "string")
  end

  if HAVE_RUST_TS then
    local pos = R.discover_positions(rustws .. "/cratea/src/lib.rs")
    local names = {}
    local function walk(n)
      if n.type == "test" then names[#names + 1] = n.name end
      for _, c in ipairs(n.children or {}) do walk(c) end
    end
    if pos then walk(pos) end
    table.sort(names)
    rok("discovery finds the #[test] fns", contains(names, "adds")
      and contains(names, "fails") and contains(names, "skipped"), vim.inspect(names))
    rok("a #[cfg(test)] helper is NOT discovered as a test",
      not contains(names, "helper"), vim.inspect(names))
  else
    print("  [38] rust treesitter parser unavailable — discovery cells skipped")
  end
end

print("\n[39] rust — target-scoped results, duplicate names, structured errors")
do
  local R = P3.adapters.get("rust")
  if not (HAVE_CARGO and HAVE_RUST_TS) then
    print("  [39] cargo / rust parser unavailable — result cells skipped")
  else
    local libfile = rustws .. "/cratea/src/lib.rs"
    local pos = R.discover_positions(libfile)
    pos.id = pos.path
    assign_ids(pos)
    local tree = { get = function(_, id) return id == pos.id and pos or nil end }

    local out = fx .. "/rust_lib.txt"
    os.execute("cd " .. rustws .. "/cratea && cargo test -p cratea --lib -- "
      .. "--format pretty --color never >" .. out .. " 2>&1")
    local map, rerr = R.results(
      { context = { position_id = pos.id, target = "lib:cratea_lib" } },
      { stdout_file = out, run_dir = fx }, tree)
    rok("real libtest results parse without a structured error", rerr == nil,
      rerr and rerr.message)
    local function st(n)
      local r = map[libfile .. "::tests::" .. n]
      return r and r.status
    end
    rok("real cargo: adds → passed", st("adds") == "passed", vim.inspect(map))
    rok("real cargo: fails → failed", st("fails") == "failed")
    rok("real cargo: #[ignore] → skipped", st("skipped") == "skipped")
    local mapped = 0
    for _ in pairs(map) do mapped = mapped + 1 end
    rok("a DUPLICATE test name in another target does not leak into this scope",
      mapped == 3, vim.inspect(map))

    -- Run the ACTUAL build_spec argv for the util.rs file scope against the
    -- PREFIX-COLLIDING sibling `util_extra` (whose test panics if executed).
    -- A boundary-less `util` filter would run it and fail the run.
    local ufile = rustws .. "/cratea/src/util.rs"
    local uspec = R.build_spec({
      position = { type = "file", path = ufile, id = ufile,
        children = { { type = "test", name = "util_only", path = ufile,
          id = ufile .. "::tests::util_only" } } } })
    local uout = fx .. "/rust_util.txt"
    os.execute("cd " .. uspec.cwd .. " && "
      .. table.concat(uspec.cmd, " ") .. " >" .. uout .. " 2>&1")
    local utext = table.concat(vim.fn.readfile(uout), "\n")
    rok("the module-filtered spec executes the selected module's test",
      utext:find("util::tests::util_only", 1, true) ~= nil, utext:sub(1, 400))
    rok("the `util::` boundary EXCLUDES the prefix-colliding util_extra sibling",
      utext:find("util_extra", 1, true) == nil, utext:sub(1, 400))
    rok("the module-filtered run passes (the panicking sibling never executed)",
      utext:find("test result: ok", 1, true) ~= nil, utext:sub(1, 400))
    rok("the module-filtered run does NOT execute the crate-root module's tests",
      utext:find("\ntest tests::adds ", 1, true) == nil, utext:sub(1, 400))

    local single = { type = "test", path = libfile, id = libfile .. "::tests::adds",
      children = {} }
    local stub = { get = function(_, id) return id == single.id and single or nil end }
    local empty = fx .. "/rust_empty.txt"
    write_file(empty, "running 0 tests\n")
    local m2, e2 = R.results({ context = { position_id = single.id, target = "lib:cratea_lib" } },
      { stdout_file = empty, run_dir = fx }, stub)
    rok("zero matching lines → structured ambiguity error (never a silent skip)",
      e2 ~= nil and e2.code == "ambiguous_test", vim.inspect(e2))
    rok("the ambiguity error carries the package identity",
      e2 ~= nil and e2.detail ~= nil and e2.detail.package_id ~= nil, vim.inspect(e2))
    rok("no phantom results on the error path", next(m2) == nil)

    local dup = fx .. "/rust_dup.txt"
    write_file(dup, "test tests::adds ... ok\ntest tests::adds ... ok\n")
    local _, e3 = R.results({ context = { position_id = single.id, target = "lib:cratea_lib" } },
      { stdout_file = dup, run_dir = fx }, stub)
    rok("TWO identical harness lines are ambiguous (counts LINES, not unique names)",
      e3 ~= nil and e3.code == "ambiguous_test", vim.inspect(e3))
  end
end

print("\n[40] rust — debug capabilities, integrated launch routing, cancellation")
do
  local R = P3.adapters.get("rust")
  local dapmod = require("auto-run.dap")
  local okd, dap = pcall(require, "dap")
  if okd then
    dapmod.ensure_rust_adapter(dap)
    rok("dap.adapters.rust is a codelldb server adapter",
      type(dap.adapters.rust) == "table" and dap.adapters.rust.type == "server"
        and dap.adapters.rust.executable.command:match("codelldb") ~= nil,
      vim.inspect(dap.adapters.rust))
  end

  if not (HAVE_CARGO and HAVE_RUST_TS) then
    print("  [40] cargo / rust parser unavailable — debug cells skipped")
  else
    local libfile = rustws .. "/cratea/src/lib.rs"
    local pos = R.discover_positions(libfile)
    pos.id = pos.path
    assign_ids(pos)
    local adds = pos.children[1].children[1]

    local launch, perr, fired
    R.prepare_debug(adds, dapmod.new_launch_token(),
      function(l, e) launch, perr, fired = l, e, true end)
    wait_for(function() return fired end, 180000)
    rok("prepare_debug builds and returns a launch", perr == nil and launch ~= nil,
      perr and perr.message)
    rok("prepare_debug targets codelldb via dap_type=rust",
      launch ~= nil and launch.dap_type == "rust")
    rok("prepare_debug program is the BUILT test executable",
      launch ~= nil and vim.fn.filereadable(launch.program) == 1,
      launch and launch.program)
    rok("prepare_debug selects the one test with --exact",
      launch ~= nil and launch.args[1] == "--exact",
      vim.inspect(launch and launch.args))

    -- REGRESSION — v0.1.12 shipped Rust debugging that could never start.
    --
    -- `cargo_build_exe` hands its result back from a `vim.system` callback,
    -- which is a FAST EVENT CONTEXT. The core launches a DAP session from that
    -- callback, and nvim-dap touches windows and buffers; each such call raises
    -- `E5560: … must not be called in a fast event context`. Because that is
    -- raised INSIDE the libuv callback it never reaches the core's
    -- `pcall(dap.run, …)`: the callback dies, `debug_start` has already
    -- returned `true`, and the user gets no session and no message.
    --
    -- Why every cell above missed it: they assert the launch TABLE, and the
    -- integrated cell below STUBS `dapmod.launch`. Both observe the value;
    -- neither observes the CONTEXT it is delivered in. So the assertions were
    -- written against the harness rather than against the behaviour.
    local ctx, ctx_fired = {}, false
    R.prepare_debug(adds, dapmod.new_launch_token(), function(_l, _e)
      ctx.fast = vim.in_fast_event()
      -- The noun in the claim is "the core can start a DAP session here", and
      -- the capability that stands for is calling the window API without E5560.
      ctx.api_ok, ctx.api_err = pcall(vim.api.nvim_get_current_win)
      ctx_fired = true
    end)
    wait_for(function() return ctx_fired end, 180000)
    rok("prepare_debug delivers its callback OFF the fast event context",
      ctx.fast == false, "vim.in_fast_event() = " .. tostring(ctx.fast))
    rok("a DAP launch is possible from prepare_debug's callback",
      ctx.api_ok == true,
      "nvim_get_current_win: " .. tostring(ctx.api_err))

    -- INTEGRATED: the real discovery path → debug_position → dap.launch.
    worktree.set_active(rustws)
    P3.discovery._reset_for_tests()
    local scanned
    P3.discovery.scan(nil, function(r) scanned = r end)
    wait_for(function() return scanned end, 60000)
    local rtree = P3.discovery.tree()
    local rust_id = libfile .. "::tests::adds"
    rok("the scan discovered the rust test position", rtree:get(rust_id) ~= nil, rust_id)

    local saved_launch = dapmod.launch
    local captured
    dapmod.launch = function(l) captured = l return true end
    local dbg_ok, dbg_err = P3.discovery.debug_position(rust_id)
    wait_for(function() return captured ~= nil end, 180000)
    dapmod.launch = saved_launch
    rok("discovery.debug_position(rust) routes through the capability to dap.launch",
      dbg_ok == true and captured ~= nil, tostring(dbg_err))
    rok("the launched rust config's type resolves to a registered dap adapter",
      captured ~= nil and captured.dap_type == "rust"
        and okd and dap.adapters[captured.dap_type] ~= nil,
      vim.inspect(captured and captured.dap_type))

    -- CANCELLATION: a superseded build must never reach dap.launch.
    local late = nil
    local saved2 = dapmod.launch
    dapmod.launch = function(l) late = l return true end
    local tok = dapmod.new_launch_token()
    local reached = false
    R.prepare_debug(adds, tok, function(l, _e)
      if tok.cancelled then return end
      reached = true
      dapmod.launch(l)
    end)
    dapmod.new_launch_token()  -- supersede: cancels + aborts the pending build
    vim.wait(2500)
    dapmod.launch = saved2
    rok("a superseded launch token is cancelled", tok.cancelled == true)
    rok("a superseded build never reaches dap.launch (no late session)",
      late == nil and reached == false, vim.inspect(late))

    -- EXPLICIT cancel through the PRODUCTION surface (what <leader>dq calls),
    -- not just supersession (Lector r1 P1-3).
    local late2 = nil
    local saved3 = dapmod.launch
    dapmod.launch = function(l) late2 = l return true end
    local tok2 = dapmod.new_launch_token()
    local reached2 = false
    R.prepare_debug(adds, tok2, function(l, _e)
      if tok2.cancelled then return end
      reached2 = true
      dapmod.launch(l)
    end)
    dapmod.cancel_launch()
    vim.wait(2500)
    dapmod.launch = saved3
    rok("cancel_launch() cancels an in-flight preparation", tok2.cancelled == true)
    rok("an explicitly cancelled build never reaches dap.launch",
      late2 == nil and reached2 == false, vim.inspect(late2))

    -- …and the terminate keymap is a real production caller of it.
    require("auto-run.keymaps").default_keymaps()
    local leader = vim.g.mapleader or "\\"
    local dq = vim.fn.maparg(leader .. "dq", "n", false, true)
    local saved_cancel = dapmod.cancel_launch
    local cancel_called = false
    dapmod.cancel_launch = function() cancel_called = true end
    if type(dq) == "table" and type(dq.callback) == "function" then
      pcall(dq.callback)
    end
    dapmod.cancel_launch = saved_cancel
    rok("<leader>dq routes through cancel_launch before dap.terminate",
      cancel_called == true, vim.inspect(dq and dq.lhs))
  end
end

print("\n[41] rust — provider effective-config gating + assertion floor")
do
  local dapmod = require("auto-run.dap")
  if not HAVE_CARGO then
    print("  [41] cargo unavailable — provider cells skipped")
  else
    worktree.set_active(rustws)
    store.add({ name = "rust-build", kind = "debug", runtime = "rust" }, { tier = "shared" })
    local exe = rustws .. "/prebuilt-bin"
    write_file(exe, "#!/bin/sh\nexit 0\n")
    store.add({ name = "rust-explicit", kind = "debug", runtime = "rust", program = exe },
      { tier = "shared" })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "rust"
    local names = {}
    for _, e in ipairs(dapmod.provider(buf)) do names[#names + 1] = e.name end
    rok("the SYNC provider omits a build-requiring rust config",
      not contains(names, "[auto-run] rust-build"), vim.inspect(names))
    rok("the SYNC provider includes an explicit-program rust config",
      contains(names, "[auto-run] rust-explicit"), vim.inspect(names))
    store.remove("rust-build")
    store.remove("rust-explicit")

    -- Generic (non-position) run/term configs must carry Cargo identity, and
    -- ambiguity must be a structured error rather than a Cargo guess.
    local R = P3.adapters.get("rust")
    local amb, amb_err = R.build_run_argv(
      { name = "amb", kind = "run", runtime = "rust", cwd = rustws .. "/crateb" })
    rok("a multi-bin crate with no pinned target is a STRUCTURED error (no guess)",
      amb == nil and type(amb_err) == "string"
        and amb_err:find("bin targets", 1, true) ~= nil, tostring(amb_err))
    local pinned = R.build_run_argv({ name = "p", kind = "run", runtime = "rust",
      cwd = rustws .. "/crateb", cargo_package = "crateb",
      cargo_target = "customtool", cargo_target_kind = "bin" })
    rok("a pinned generic run config emits -p <pkg> --bin <target>",
      pinned ~= nil and table.concat(pinned, " ") == "cargo run -p crateb --bin customtool",
      vim.inspect(pinned))
    local tcfg = R.build_run_argv({ name = "t", kind = "test", runtime = "rust",
      cwd = rustws .. "/cratea" })
    rok("a generic test config emits -p <pkg> (package-unambiguous)",
      tcfg ~= nil and table.concat(tcfg, " ") == "cargo test -p cratea", vim.inspect(tcfg))

    -- default_config scaffolds that identity rather than a bare shell.
    vim.cmd.edit(vim.fn.fnameescape(rustws .. "/crateb/src/main.rs"))
    local scaffold = R.default_config("run", "x")
    rok("default_config scaffolds the Cargo package identity",
      scaffold.runtime == "rust" and scaffold.cargo_package == "crateb",
      vim.inspect(scaffold))
    rok("default_config leaves a MULTI-BIN crate's target unpinned (no guess)",
      scaffold.cargo_target == nil, vim.inspect(scaffold))

    -- The integrated TERM strategy carries the selectors end-to-end.
    store.add({ name = "rust-run", kind = "run", runtime = "rust",
      cwd = rustws .. "/crateb", cargo_package = "crateb",
      cargo_target = "customtool", cargo_target_kind = "bin" }, { tier = "shared" })
    local cmdline = require("auto-run.exec").command_line("rust-run")
    -- command_line shell-quotes each token, so match the quoted argv.
    rok("the TERM-strategy command line carries the cargo selectors",
      type(cmdline) == "string"
        and cmdline:find("'cargo' 'run' '-p' 'crateb' '--bin' 'customtool'", 1, true) ~= nil,
      tostring(cmdline))
    store.remove("rust-run")

    -- ── ONE authoritative identity, shared by run and ordinary debug ──
    local cratea_cwd = rustws .. "/cratea"
    -- CROSS-PACKAGE: cwd is inside cratea while the config names crateb's
    -- target. The resolver must follow the NAMED package, not the cwd crate.
    local xcfg = { name = "x", kind = "run", runtime = "rust", cwd = cratea_cwd,
      cargo_package = "crateb", cargo_target = "customtool", cargo_target_kind = "bin" }
    local xargv = R.build_run_argv(xcfg)
    rok("a cross-package config resolves the NAMED package, not the cwd crate",
      xargv ~= nil and table.concat(xargv, " ") == "cargo run -p crateb --bin customtool",
      vim.inspect(xargv))

    -- WORKSPACE-ROOT cwd + a named package: the cwd crate cannot supply targets.
    local rargv = R.build_run_argv({ name = "r", kind = "run", runtime = "rust",
      cwd = rustws, cargo_package = "cratec" })
    rok("a workspace-ROOT cwd still resolves the named package's sole bin",
      rargv ~= nil and table.concat(rargv, " ") == "cargo run -p cratec --bin cratec",
      vim.inspect(rargv))

    -- Validation: half-specified pair, unsupported kind, non-member target,
    -- non-member package — each a structured error, never a silent degrade.
    local _, half_err = R.build_run_argv({ name = "h", kind = "run", runtime = "rust",
      cwd = cratea_cwd, cargo_package = "crateb", cargo_target = "customtool" })
    rok("a HALF-specified target identity is a structured error",
      type(half_err) == "string" and half_err:find("half-specifies", 1, true) ~= nil,
      tostring(half_err))
    local _, kind_err = R.build_run_argv({ name = "k", kind = "run", runtime = "rust",
      cwd = cratea_cwd, cargo_package = "crateb", cargo_target = "customtool",
      cargo_target_kind = "banana" })
    rok("an UNSUPPORTED cargo_target_kind is a structured error (no silent degrade)",
      type(kind_err) == "string" and kind_err:find("unsupported", 1, true) ~= nil,
      tostring(kind_err))
    local _, mem_err = R.build_run_argv({ name = "m", kind = "run", runtime = "rust",
      cwd = cratea_cwd, cargo_package = "cratea", cargo_target = "customtool",
      cargo_target_kind = "bin" })
    rok("a target that does NOT belong to the named package is rejected",
      type(mem_err) == "string" and mem_err:find("no bin target named", 1, true) ~= nil,
      tostring(mem_err))
    local _, pkg_err = R.build_run_argv({ name = "n", kind = "run", runtime = "rust",
      cwd = cratea_cwd, cargo_package = "nosuchpkg" })
    rok("a package outside the workspace is rejected",
      type(pkg_err) == "string" and pkg_err:find("not a member", 1, true) ~= nil,
      tostring(pkg_err))

    -- OPERATION-AWARE target validation: `cargo run` accepts only --bin, so a
    -- lib/test target pinned on a run config must be refused rather than
    -- emitted as an argv Cargo rejects.
    local _, librun_err = R.build_run_argv({ name = "lr", kind = "run", runtime = "rust",
      cwd = cratea_cwd, cargo_package = "cratea", cargo_target = "cratea_lib",
      cargo_target_kind = "lib" })
    rok("`cargo run` REFUSES a pinned lib target (invalid --lib argv)",
      type(librun_err) == "string" and librun_err:find("cannot launch", 1, true) ~= nil,
      tostring(librun_err))
    local _, testrun_err = R.build_run_argv({ name = "tr", kind = "run", runtime = "rust",
      cwd = cratea_cwd, cargo_package = "cratea", cargo_target = "it",
      cargo_target_kind = "test" })
    rok("`cargo run` REFUSES a pinned test target (invalid --test argv)",
      type(testrun_err) == "string" and testrun_err:find("cannot launch", 1, true) ~= nil,
      tostring(testrun_err))
    -- Positive control: the SAME lib pin is legal for `cargo test`, so the rule
    -- is operation-aware rather than a blanket ban on lib/test targets.
    local libtest_argv = R.build_run_argv({ name = "lt", kind = "test", runtime = "rust",
      cwd = cratea_cwd, cargo_package = "cratea", cargo_target = "cratea_lib",
      cargo_target_kind = "lib" })
    rok("`cargo test` ACCEPTS the same lib pin (operation-aware, not a blanket ban)",
      libtest_argv ~= nil
        and table.concat(libtest_argv, " ") == "cargo test -p cratea --lib",
      vim.inspect(libtest_argv))

    -- RUN/DEBUG EQUIVALENCE: the same effective config must resolve the same
    -- package+target in BOTH capabilities (debug must build crateb's
    -- customtool, never a cratea target).
    local dlaunch, derr, dfired
    R.prepare_debug_config(xcfg, {}, function(l, e) dlaunch, derr, dfired = l, e, true end)
    wait_for(function() return dfired end, 180000)
    rok("ordinary debug resolves the SAME cross-package target as run",
      derr == nil and dlaunch ~= nil and type(dlaunch.program) == "string"
        and dlaunch.program:find("customtool", 1, true) ~= nil,
      derr and derr.message or (dlaunch and dlaunch.program))
    rok("ordinary debug builds in the NAMED package's crate dir",
      dlaunch ~= nil and dlaunch.cwd == rustws .. "/crateb", dlaunch and dlaunch.cwd)

    -- Same regression on the ordinary-debug path (<leader>dm). Both debug
    -- capabilities funnel through cargo_build_exe, so both were broken.
    local cctx, cfired = {}, false
    R.prepare_debug_config(xcfg, {}, function(_l, _e)
      cctx.fast = vim.in_fast_event()
      cctx.api_ok = pcall(vim.api.nvim_get_current_win)
      cfired = true
    end)
    wait_for(function() return cfired end, 180000)
    rok("prepare_debug_config delivers its callback OFF the fast event context",
      cctx.fast == false, "vim.in_fast_event() = " .. tostring(cctx.fast))
    rok("a DAP launch is possible from prepare_debug_config's callback",
      cctx.api_ok == true)

    -- SCAFFOLD (<leader>rc): a crate BELOW the project root must still resolve.
    -- Every fixture before this one put the Cargo workspace AT the project
    -- root, so `config_identity`'s fallback to nvim's cwd always happened to
    -- land on a manifest — the failure was unreachable in the suite while being
    -- the first thing a real nested project hits ("no Cargo metadata at …").
    -- `default_config` resolves the crate from the CURRENT BUFFER when it is a
    -- .rs file, so open one from the nested fixture crate to make this
    -- deterministic rather than dependent on the runner's cwd.
    vim.cmd.edit(vim.fn.fnameescape(rustws .. "/crateb/src/main.rs"))
    local scaffold = R.default_config("debug", "dbg")
    vim.cmd("enew!")
    rok("default_config pins cwd to the crate, not the project root",
      scaffold.cwd == rustws .. "/crateb", "cwd = " .. tostring(scaffold.cwd))
    rok("default_config scaffolds NO program (the cargo prebuild is the baseline)",
      scaffold.program == nil, "program = " .. tostring(scaffold.program))

    -- Resolution follows the ACTIVE WORKTREE, not nvim's cwd (ADR 0199 §7.2).
    -- The rust adapter fell back to vim.uv.cwd() when a config had no cwd and
    -- (for scaffolding) no .rs buffer was current. The panes' `w` sets the
    -- active worktree WITHOUT a cd, so the ordinary state is cwd=$WORKSPACE
    -- with a Cargo project active — and that resolved "no Cargo metadata at
    -- $WORKSPACE". A single-crate repo is the common shape. Own function
    -- scope: the main chunk is at Lua's 200-local limit here.
    ;(function()
      local single = fx .. "/rs-single"
      make_plain_repo(single)
      write_file(single .. "/Cargo.toml", '[package]\nname = "single"\nversion = "0.1.0"\nedition = "2021"\n')
      write_file(single .. "/src/main.rs", "fn main() {}\n")
      local elsewhere = fx .. "/rs-elsewhere"; vim.fn.mkdir(elsewhere, "p")
      local cwd0 = vim.fn.getcwd()
      local prev = worktree.get_active()
      worktree.set_active(single)
      require("auto-run.store.paths").invalidate()
      vim.cmd("cd " .. vim.fn.fnameescape(elsewhere))
      vim.cmd("enew!")
      local argv, aerr = R.build_run_argv({ name = "s", kind = "run", runtime = "rust" })
      rok("a rust config with no cwd resolves Cargo from the ACTIVE worktree, not nvim's cwd",
        argv ~= nil and table.concat(argv, " "):find("-p single", 1, true) ~= nil,
        vim.inspect(argv) .. " err=" .. tostring(aerr))
      local sc = R.default_config("run", "s")
      rok("scaffolding with no .rs buffer resolves the crate from the ACTIVE worktree",
        sc.cargo_package == "single" and sc.cwd == single, vim.inspect(sc))
      vim.cmd("cd " .. vim.fn.fnameescape(cwd0))
      worktree.set_active(prev)
      require("auto-run.store.paths").invalidate()
    end)()
  end

  local RUST_MIN = (HAVE_CARGO and HAVE_RUST_TS) and 74 or 6
  ok(("rust assertion floor: ran %d, expected at least %d"):format(rust_cells, RUST_MIN),
    rust_cells >= RUST_MIN, "a rust section stopped contributing assertions")
end
-- ── [42] working directory — a chosen folder inside a repo ─────────
-- A multi-project repo (go-contacts/, rust-contacts/ ... in one repo) is one
-- worktree. auto-core's choose_active (the panes' `w`, <leader>rw) can make a
-- FOLDER of it the active directory; that folder is then where test discovery
-- looks and where runs and debugs start, while the store stays at the repo
-- root. Before, every path collapsed the anchor to the repo root, so choosing
-- a folder changed nothing.
print("\n[42] working directory — a chosen folder scopes discovery, runs and debugs")
;(function()
  local prev_wt = worktree.get_active()
  local mono = fx .. "/mono42"
  ok("[42] fixture: a repo with a project folder", make_plain_repo(mono))
  vim.fn.mkdir(mono .. "/svc/cmd/x", "p")
  store_paths.invalidate()

  worktree.set_active(mono .. "/svc")
  local d = store.resolve_run_dirs()
  ok("[42] a chosen folder is the working directory", d.workdir == mono .. "/svc", tostring(d.workdir))
  ok("[42] the store stays at the repo root",
    d.root == mono and d.tracked == mono .. "/.auto-run", vim.inspect({ d.root, d.tracked }))
  local w = require("auto-run.context").worktree()
  ok("[42] the context names the folder inside the repo",
    w.folder == "svc" and w.workdir == mono .. "/svc" and w.root == mono, vim.inspect(w))
  ok("[42] test discovery looks in the folder",
    require("auto-run.discovery").tree().root.path == mono .. "/svc",
    tostring(require("auto-run.discovery").tree().root.path))

  local okr, rerr = store.add({ name = "wd-run", kind = "run", program = "./cmd/x" }, { tier = "tracked" })
  local okd, derr = store.add({ name = "wd-debug", kind = "debug", runtime = "go", program = "./cmd/x" },
    { tier = "tracked" })
  ok("[42] fixture: configs with no cwd", okr and okd, tostring(rerr or derr))
  local cmd = require("auto-run.exec").command_line("wd-run")
  ok("[42] a run with no cwd starts in the folder",
    type(cmd) == "string" and cmd:find("^cd ") ~= nil and cmd:find(mono .. "/svc", 1, true) ~= nil, tostring(cmd))
  local dcfg = require("auto-run.dap").translate("wd-debug")
  ok("[42] a debug with no cwd starts in the folder",
    type(dcfg) == "table" and dcfg.cwd == mono .. "/svc", vim.inspect(dcfg and dcfg.cwd))

  -- The repo root chosen (as <leader>gw sets it): everything as before.
  worktree.set_active(mono)
  local r = store.resolve_run_dirs()
  ok("[42] the repo root chosen: the working directory is the root", r.workdir == mono, tostring(r.workdir))
  ok("[42] ... and the context names no folder", require("auto-run.context").worktree().folder == nil)

  -- No choice at all: the cwd fallback keeps the repo root, even from a folder.
  worktree.set_active(nil)
  local cwd = vim.fn.getcwd()
  vim.cmd.cd(vim.fn.fnameescape(mono .. "/svc"))
  local c = store.resolve_run_dirs()
  vim.cmd.cd(vim.fn.fnameescape(cwd))
  ok("[42] with no choice, a cwd inside the repo still works at the repo root",
    c.workdir == mono and c.root == mono, vim.inspect({ c.workdir, c.root }))

  worktree.set_active(prev_wt)
  store_paths.invalidate()
end)()

-- ── [42b] <leader>rw — auto-core's choose_active, for real ─────────
-- Drives the REAL choose_active through both prompts (worktree, then folder):
-- against an auto-core without it (< v0.2.32) the key only warns and these
-- cells go red. An earlier version replaced choose_active with a stub, which
-- stayed green on the old auto-core CI pinned (Zen, PR #14 r0).
print("\n[42b] <leader>rw — the working directory, through auto-core's real picker")
;(function()
  auto_run.default_keymaps()
  local m = vim.fn.maparg("<leader>rw", "n", false, true)
  ok("[42b] <leader>rw is bound", type(m) == "table" and m.desc == "Run: Working Directory (worktree / folder)",
    vim.inspect(m and m.desc))
  ok("[42b] this auto-core has git.worktree.choose_active (>= v0.2.32)", type(worktree.choose_active) == "function")

  local ws = fx .. "/ws42b"
  vim.fn.mkdir(ws, "p")
  ok("[42b] fixture: a repo in a workspace", make_plain_repo(ws .. "/mono"))
  vim.fn.mkdir(ws .. "/mono/svc", "p")
  local f = assert(io.open(ws .. "/mono/svc/go.mod", "w")); f:write("module example.com/svc\n"); f:close()

  local prev_ws, prev_wt = worktree.get_workspace_root(), worktree.get_active()
  worktree.set_workspace_root(ws)
  worktree.set_active(nil)
  local real_select = vim.ui.select
  local prompts, answers = {}, { "mono", "svc" }
  vim.ui.select = function(items, o, cb)
    prompts[#prompts + 1] = o.prompt
    local want = table.remove(answers, 1)
    for _, it in ipairs(items) do
      local label = o.format_item and o.format_item(it) or tostring(it)
      if want and label:find(want, 1, true) then return cb(it) end
    end
    cb(nil)
  end
  local cwd_before = vim.fn.getcwd()
  local okcall, cerr = pcall(m.callback)
  vim.ui.select = real_select
  ok("[42b] <leader>rw runs", okcall, tostring(cerr))
  ok("[42b] it asks for a worktree, then a folder in it",
    prompts[1] == "Active worktree (cwd stays):" and prompts[2] == "Working directory in mono:", vim.inspect(prompts))
  ok("[42b] the chosen folder is auto-run's working directory",
    store.resolve_run_dirs().workdir == ws .. "/mono/svc", tostring(store.resolve_run_dirs().workdir))
  ok("[42b] the cwd did not move", vim.fn.getcwd() == cwd_before, vim.fn.getcwd())

  worktree.set_workspace_root(prev_ws)
  worktree.set_active(prev_wt)
  store_paths.invalidate()
end)()

-- ── [42c] working directory — a nested Cargo folder ───────────────
-- rust-contacts/ in a repo whose root has no Cargo.toml: with the folder
-- chosen, run and debug resolve the folder's package; with the root chosen
-- there is no Cargo manifest to resolve and the error says so. Before, Cargo
-- resolved from the repo root regardless of the choice (Zen, PR #14 r0).
print("\n[42c] working directory — a nested Cargo folder resolves from the folder")
if not HAVE_CARGO then
  print("  SKIP  [42c] cargo is not installed")
else
  (function()
    local prev_wt = worktree.get_active()
    local mono = fx .. "/mono42c"
    ok("[42c] fixture: a repo with no Cargo.toml at its root", make_plain_repo(mono))
    vim.fn.mkdir(mono .. "/rust-app/src", "p")
    local f = assert(io.open(mono .. "/rust-app/Cargo.toml", "w"))
    f:write('[package]\nname = "rustapp"\nversion = "0.1.0"\nedition = "2021"\n'); f:close()
    f = assert(io.open(mono .. "/rust-app/src/main.rs", "w")); f:write("fn main() {}\n"); f:close()
    local R = require("auto-run.adapters.rust")

    worktree.set_active(mono .. "/rust-app")
    store_paths.invalidate()
    local argv, aerr = R.build_run_argv({ name = "r", kind = "run", runtime = "rust" })
    ok("[42c] a run with no cwd resolves the chosen folder's package",
      argv ~= nil and table.concat(argv, " ") == "cargo run -p rustapp --bin rustapp", vim.inspect(argv or aerr))
    local dl, de, fired
    R.prepare_debug_config({ name = "d", kind = "debug", runtime = "rust" }, {}, function(l, e)
      dl, de, fired = l, e, true
    end)
    vim.wait(180000, function() return fired end, 50)
    ok("[42c] a debug with no cwd builds the folder's package in the folder",
      de == nil and dl ~= nil and dl.cwd == mono .. "/rust-app" and type(dl.program) == "string"
        and dl.program:find("rustapp", 1, true) ~= nil, vim.inspect(de or (dl and { dl.cwd, dl.program })))

    worktree.set_active(mono)
    store_paths.invalidate()
    local rargv, rerr = R.build_run_argv({ name = "r", kind = "run", runtime = "rust" })
    ok("[42c] with the repo root chosen there is no Cargo manifest, and the error says so",
      rargv == nil and tostring(rerr):find("no Cargo metadata", 1, true) ~= nil, vim.inspect(rargv or rerr))

    worktree.set_active(prev_wt)
    store_paths.invalidate()
  end)()
end

-- ── [43] field docs, folder-aware scaffolds, env files in .auto-run/ ──
-- Johno, 2026-09-29: a scaffolded config said nothing about what else it
-- could hold ("what are the available fields and allowed values"), a Go
-- scaffold in a chosen folder pointed at the repo root (no go.mod there), and
-- a new env file could not live in .auto-run/.
print("\n[43] field docs, folder-aware scaffolds, env files in .auto-run/")
;(function()
  local schema = require("auto-run.store.schema")
  for _, rec in ipairs({ "config", "profile" }) do
    local missing = {}
    for _, f in ipairs(schema.field_names(rec)) do
      local d = schema.field_doc(rec, f)
      if not (d and type(d.help) == "string" and d.help ~= "") then missing[#missing + 1] = f end
    end
    ok("[43] every " .. rec .. " field has a help text", #missing == 0, vim.inspect(missing))
    local stray = {}
    local known = {}
    for _, f in ipairs(schema.field_names(rec)) do known[f] = true end
    for f in pairs(schema.FIELD_DOCS[rec]) do if not known[f] then stray[#stray + 1] = f end end
    ok("[43] no " .. rec .. " doc names a field the schema rejects", #stray == 0, vim.inspect(stray))
  end
  local kinds = {}
  for k in pairs(schema.VALID_KIND) do kinds[#kinds + 1] = k end
  table.sort(kinds)
  local kv = vim.deepcopy(schema.field_doc("config", "kind").values); table.sort(kv)
  ok("[43] kind's allowed values are exactly the ones validation accepts", vim.deep_equal(kinds, kv), vim.inspect(kv))
  ok("[43] cargo_target_kind lists lib, bin, test",
    vim.deep_equal(schema.field_doc("config", "cargo_target_kind").values, { "lib", "bin", "test" }))

  -- The Go scaffold, anchored at the working directory.
  local prev_wt = worktree.get_active()
  local mono = fx .. "/mono43"
  ok("[43] fixture: a repo with a Go folder", make_plain_repo(mono))
  vim.fn.mkdir(mono .. "/svc", "p")
  local go = require("auto-run.adapters.go")
  worktree.set_active(mono .. "/svc")
  store_paths.invalidate()
  local t = go.default_config("test", "unit")
  local r = go.default_config("debug", "server")
  ok("[43] in a chosen folder, a Go test config targets the folder and runs there",
    t.program == "${worktree}/svc" and t.cwd == "${worktree}/svc", vim.inspect(t))
  ok("[43] ... and a Go entry point sits under the folder's cmd/",
    r.program == "${worktree}/svc/cmd/server" and r.cwd == "${worktree}/svc", vim.inspect(r))
  worktree.set_active(mono)
  store_paths.invalidate()
  local t2 = go.default_config("test", "unit")
  ok("[43] at the repo root the scaffold is unchanged (no cwd)",
    t2.program == "${worktree}" and t2.cwd == nil, vim.inspect(t2))

  -- An env file in .auto-run/: created, and listed by discovery.
  local env = require("auto-run.env")
  local path, cerr = env.create_file(mono .. "/.auto-run/.env")
  ok("[43] an env file can be created in .auto-run/ (the directory is made)",
    path ~= nil and vim.fn.filereadable(mono .. "/.auto-run/.env") == 1, vim.inspect(cerr))
  local listed = false
  for _, c in ipairs(env.files_list() or {}) do
    if c.path == require("auto-core.fs.path").normalize(mono .. "/.auto-run/.env") then listed = true end
  end
  ok("[43] env discovery lists it", listed)
  local bad, berr = env.create_file(mono .. "/.auto-run/configs/.env")
  ok("[43] a deeper directory is still refused", bad == nil and tostring(berr and berr.message):find("not one of them", 1, true) ~= nil,
    vim.inspect(berr))

  worktree.set_active(prev_wt)
  store_paths.invalidate()
end)()

-- ── [44] a session that closes without terminated/exited ─────────
-- Johno, 2026-09-29: delve failed its build ("directory not found"), the
-- session closed before `initialized`, and the debug pane kept listing it:
-- run.session:changed fired only on the adapter's terminated / exited events,
-- which such a session never sends. nvim-dap drops every session through
-- set_session → listeners.on_session; that is announced now.
print("\n[44] a session that closes without terminated/exited is announced")
;(function()
  local okd, dap = pcall(require, "dap")
  if not (okd and type(dap.listeners.on_session) == "table") then
    print("  SKIP  [44] this nvim-dap has no listeners.on_session")
    return
  end
  local seen = {}
  local sub = core.events.subscribe("run.session:changed", function(p) seen[#seen + 1] = p end)
  -- The real path: a closed session is current, and <leader>dq terminates it.
  local fake = { id = 4242, closed = true, config = { name = "[auto-run] go" }, on_close = {}, capabilities = {} }
  dap.set_session(fake)
  vim.wait(100, function() return false end)
  seen = {}
  dap.terminate()
  vim.wait(500, function() return #seen > 0 end)
  ok("[44] terminating an already-closed session announces it as closed",
    #seen == 1 and seen[1].id == "4242" and seen[1].state == "closed" and seen[1].config == "[auto-run] go",
    vim.inspect(seen))
  ok("[44] ... and nvim-dap no longer holds it", dap.session() == nil and dap.sessions()[4242] == nil)

  -- A switch between two live sessions is not a close.
  seen = {}
  local a = { id = 4301, closed = false, config = { name = "a" }, on_close = {} }
  local b = { id = 4302, closed = false, config = { name = "b" }, on_close = {} }
  dap.set_session(a)
  dap.set_session(b)
  vim.wait(100, function() return false end)
  local closed = vim.tbl_filter(function(p) return p.state == "closed" end, seen)
  ok("[44] switching between live sessions announces no close", #closed == 0, vim.inspect(seen))
  dap.sessions()[4301], dap.sessions()[4302] = nil, nil
  dap.set_session(nil)
  core.events.unsubscribe(sub)
end)()

-- ── [45] a Go program directory that does not exist is refused ──────
-- Johno, 2026-09-29: `program: ${worktree}/cmd/server` in a repo whose server
-- lives in go-contacts/ — delve failed its build ("directory not found") and
-- nvim-dap kept a dead session. Checked before delve is ever started now.
print("\n[45] a Go program directory that does not exist is refused before launch")
;(function()
  local go = require("auto-run.adapters.go")
  local root = fx .. "/prog45"
  vim.fn.mkdir(root .. "/svc/cmd/server", "p")
  local function eff(program, cwd) return { name = "c45", kind = "debug", runtime = "go", program = program, cwd = cwd } end

  local e1 = go.program_error(eff(root .. "/cmd/server", root))
  ok("[45] a missing absolute program directory is refused, naming it",
    type(e1) == "string" and e1:find("does not exist", 1, true) ~= nil and e1:find("cmd/server", 1, true) ~= nil, tostring(e1))
  ok("[45] an existing absolute directory passes", go.program_error(eff(root .. "/svc/cmd/server", root)) == nil)
  ok("[45] a relative path resolves against cwd (exists → passes)", go.program_error(eff("./cmd/server", root .. "/svc")) == nil)
  ok("[45] a relative path resolves against cwd (missing → refused)",
    type(go.program_error(eff("./cmd/server", root))) == "string")
  ok("[45] import paths, ... patterns and unresolved tokens are left to go",
    go.program_error(eff("example.com/x/cmd/y", root)) == nil and go.program_error(eff("./...", root)) == nil
      and go.program_error(eff("${worktree}/cmd/x", root)) == nil and go.program_error(eff(nil, root)) == nil)

  local argv, aerr = go.build_run_argv({ name = "r45", kind = "run", runtime = "go", program = root .. "/cmd/server", cwd = root })
  ok("[45] a run is refused the same way", argv == nil and tostring(aerr):find("does not exist", 1, true) ~= nil, tostring(aerr))
  local targv = go.build_run_argv({ name = "t45", kind = "test", runtime = "go", program = root .. "/nope", cwd = root },
    { package = "./svc/..." })
  ok("[45] a test run with a position's package does not consult program", targv ~= nil, vim.inspect(targv))

  local got, gerr, fired
  go.prepare_debug_config(eff(root .. "/cmd/server", root), {}, function(l, e) got, gerr, fired = l, e, true end)
  ok("[45] a debug is refused before delve, with code program_missing",
    fired and got == nil and gerr and gerr.code == "program_missing", vim.inspect(gerr))

  -- translate (nvim-dap's own picker path) refuses too, and no session starts.
  local prev_wt = worktree.get_active()
  ok("[45] fixture: a repo for translate", make_plain_repo(root .. "/repo"))
  worktree.set_active(root .. "/repo")
  store_paths.invalidate()
  store.add({ name = "missing-prog", kind = "debug", runtime = "go", program = "${worktree}/cmd/server" }, { tier = "tracked" })
  local cfg, terr = require("auto-run.dap").translate("missing-prog")
  ok("[45] translate refuses a missing program", cfg == nil and tostring(terr):find("does not exist", 1, true) ~= nil,
    tostring(terr))
  local okd, dap = pcall(require, "dap")
  if okd then
    local before = vim.tbl_count(dap.sessions())
    require("auto-run.dap").debug_start("missing-prog")
    vim.wait(200, function() return false end)
    ok("[45] debug_start on it leaves nvim-dap without a new session", vim.tbl_count(dap.sessions()) == before,
      vim.inspect(vim.tbl_keys(dap.sessions())))
  end
  store.remove("missing-prog")
  worktree.set_active(prev_wt)
  store_paths.invalidate()
end)()

-- ── [46] a session's pid, port and output journal ─────────────────
-- Johno, 2026-09-29: the debug pane's Active Sessions showed id / config /
-- state only — "display the port number and pid … including how to journal
-- the logs, with commands". nvim-dap keeps none of these.
print("\n[46] dap.sessions — the program's pid, port and an output journal")
;(function()
  local okd, dap = pcall(require, "dap")
  if not okd then print("  SKIP  [46] nvim-dap is not installed"); return end
  local S = require("auto-run.dap.sessions")
  S._reset_for_tests()
  ok("[46] the listeners are attached by setup",
    dap.listeners.after.event_output["auto-run-sessions"] ~= nil
      and dap.listeners.after.event_process["auto-run-sessions"] ~= nil)

  -- The journal: program output verbatim, the adapter's marked, telemetry dropped.
  local s = { id = 7701, config = { name = "go server", env = { PORT = "9999" } }, adapter = { type = "server" } }
  dap.listeners.after.event_initialized["auto-run-sessions"](s)
  local out = dap.listeners.after.event_output["auto-run-sessions"]
  out(s, { category = "stdout", output = "listening on :9999\n" })
  out(s, { category = "stderr", output = "warn: slow\n" })
  out(s, { category = "console", output = "Type 'dlv help' for list of commands.\n" })
  out(s, { category = "telemetry", output = "{\"secret\":1}\n" })
  local info = S.info(s)
  ok("[46] a journal file is named for the session, under stdpath('state')/auto-run/sessions",
    type(info.log) == "string" and vim.startswith(info.log, S.journal_dir()) and info.log:find("7701%-go_server%.log$") ~= nil,
    tostring(info.log))
  local body = info.log and table.concat(vim.fn.readfile(info.log), "\n") or ""
  ok("[46] program output lands verbatim, the adapter's is marked, telemetry is not written",
    body == "listening on :9999\nwarn: slow\n[dap] Type 'dlv help' for list of commands.", body)
  ok("[46] with no process to read, the port comes from the launch env's PORT",
    info.port == 9999 and info.port_source == "env", vim.inspect(info))
  ok("[46] tail -f is offered for the journal", info.commands.tail == "tail -f " .. vim.fn.shellescape(info.log))

  -- The adapter's process event names the pid.
  dap.listeners.after.event_process["auto-run-sessions"](s, { systemProcessId = 424242, name = "x" })
  info = S.info(s)
  ok("[46] a process event's systemProcessId is the pid, and kill is offered",
    info.pid == 424242 and info.commands.kill == "kill 424242", vim.inspect(info))

  -- The process tree: the program is the adapter's child that is not the adapter itself.
  local real_snap = S._snapshot
  S._snapshot = function()
    return {
      procs = {
        { pid = 500, ppid = 1, command = "/opt/dlv dap -l 127.0.0.1:38439" },
        { pid = 501, ppid = 500, command = "/opt/dlv ** telemetry **" },
        { pid = 502, ppid = 500, command = "/w/go-contacts/__debug_bin123" },
      },
      listen = { [500] = { "127.0.0.1:38439" }, [502] = { "*:8081" } },
    }
  end
  local t = { id = 7702, config = { name = "t", env = { PORT = "1" } }, adapter = { type = "server", port = 38439, executable = { command = "dlv" } } }
  local ti = S.info(t)
  ok("[46] without a process event: the adapter's child that is not the adapter (delve's telemetry fork skipped)",
    ti.pid == 502, vim.inspect(ti))
  ok("[46] ... and the port it listens on wins over the env's", ti.port == 8081 and ti.port_source == "listening",
    vim.inspect(ti))
  S._snapshot = real_snap

  -- The real snapshot parses this machine's process table and sockets.
  local srv = vim.uv.new_tcp()
  srv:bind("127.0.0.1", 0)
  srv:listen(1, function() end)
  local port = srv:getsockname().port
  local snap = S._snapshot(true) -- fresh: an earlier info() cached one without this port
  local me = vim.fn.getpid()
  local listed = false
  for _, p in ipairs(snap.procs) do if p.pid == me then listed = true end end
  local mine = false
  for _, a in ipairs(snap.listen[me] or {}) do if a:match(":" .. port .. "$") then mine = true end end
  ok("[46] the real process table lists this nvim", listed)
  ok("[46] the real socket table finds a port this nvim listens on", mine, vim.inspect(snap.listen[me]))
  srv:close()

  -- A closed session finishes its journal.
  dap.listeners.on_session["auto-run-sessions"]({ id = 7701, closed = true }, nil)
  ok("[46] a closed session's journal is finished", S.info(s).ended_at ~= nil)
  os.remove(info.log)
  S._reset_for_tests()

  -- delve forwards the program's output only with outputMode "remote".
  local go = require("auto-run.adapters.go")
  local root = fx .. "/out46"
  vim.fn.mkdir(root .. "/cmd/srv", "p")
  local launch
  go.prepare_debug_config({ name = "o46", kind = "debug", runtime = "go", program = root .. "/cmd/srv", cwd = root }, {},
    function(l) launch = l end)
  ok("[46] a Go debug launch asks delve to forward the program's output (outputMode remote)",
    launch and launch.extra and launch.extra.outputMode == "remote", vim.inspect(launch and launch.extra))
end)()

-- ── shared helpers for [47]–[52] (ADR 0213 / ADR 0196 r3) ──────────
local NEW = {}
---Capture dap.run calls (the real nvim-dap stays loaded) for the duration of fn.
function NEW.capture_dap_run(fn)
  local okd, dap = pcall(require, "dap")
  if not okd then return nil, "nvim-dap missing" end
  local calls = {}
  local real = dap.run
  dap.run = function(cfg) calls[#calls + 1] = cfg end
  local okf, ferr = pcall(fn, dap)
  dap.run = real
  if not okf then error(ferr) end
  return calls
end
function NEW.repo(path)
  vim.fn.delete(path, "rf")
  local okr = make_plain_repo(path)
  worktree.set_active(path)
  store_paths.invalidate()
  return okr
end
function NEW.restore(prev)
  worktree.set_active(prev)
  store_paths.invalidate()
end
function NEW.ids_by_name(node, out)
  out = out or {}
  out[node.name] = out[node.name] or node.id
  for _, c in ipairs(node.children or {}) do NEW.ids_by_name(c, out) end
  return out
end

-- ── [47] the node runtime adapter ────────────────────────────────
-- Johno, 2026-10-03: "are we equiped with running ndoe application… like
-- running the playground web". ADR 0213 §2.1.
print("\n[47] node runtime — a file or a package.json script, run and debugged")
;(function()
  local js = require("auto-run.adapters.js")
  local node = require("auto-run.adapters.node")
  local prev = worktree.get_active()
  local root = fx .. "/node47"
  ok("[47] fixture repo", NEW.repo(root))
  write_file(root .. "/web/package.json", vim.json.encode({ name = "web", scripts = { dev = "vite", start = "node server.js" } }))
  write_file(root .. "/web/server.js", "console.log('hi')\n")

  -- the package manager comes from the lockfile
  ok("[47] no lockfile → npm", js.package_manager(root .. "/web") == "npm")
  write_file(root .. "/web/pnpm-lock.yaml", "")
  ok("[47] pnpm-lock.yaml → pnpm", js.package_manager(root .. "/web") == "pnpm")
  os.remove(root .. "/web/pnpm-lock.yaml")
  write_file(root .. "/yarn.lock", "")
  ok("[47] a yarn.lock above the package (workspace root) → yarn", js.package_manager(root .. "/web") == "yarn")
  os.remove(root .. "/yarn.lock")
  write_file(root .. "/web/bun.lockb", "")
  ok("[47] bun.lockb → bun", js.package_manager(root .. "/web") == "bun")
  os.remove(root .. "/web/bun.lockb")

  local function eff(t) return vim.tbl_extend("force", { name = "n47", kind = "run", runtime = "node", cwd = root .. "/web" }, t) end
  local a1 = node.build_run_argv(eff({ program = root .. "/web/server.js" }))
  ok("[47] a program runs as `node <file>`", vim.deep_equal(a1, { "node", root .. "/web/server.js" }), vim.inspect(a1))
  local a2 = node.build_run_argv(eff({ script = "dev", args = { "--port", "1" } }))
  ok("[47] an npm script with args gets the `--` separator", vim.deep_equal(a2, { "npm", "run", "dev", "--" }), vim.inspect(a2))
  write_file(root .. "/web/pnpm-lock.yaml", "")
  local a3 = node.build_run_argv(eff({ script = "dev", args = { "--port", "1" } }))
  ok("[47] pnpm passes script args without `--`", vim.deep_equal(a3, { "pnpm", "run", "dev" }), vim.inspect(a3))
  os.remove(root .. "/web/pnpm-lock.yaml")
  write_file(root .. "/web/src/main.ts", "")
  write_file(root .. "/web/node_modules/.bin/tsx", "#!/bin/sh\n")
  local a4 = node.build_run_argv(eff({ program = "src/main.ts" }))
  ok("[47] a .ts entry runs through the project's tsx", a4 and a4[1] == root .. "/web/node_modules/.bin/tsx", vim.inspect(a4))
  vim.fn.delete(root .. "/web/node_modules", "rf")

  local e1 = node.program_error(eff({ program = root .. "/web/nope.js" }))
  ok("[47] a missing program is refused", tostring(e1):find("does not exist", 1, true) ~= nil, tostring(e1))
  local e2 = node.program_error(eff({ script = "build" }))
  ok("[47] an unknown script is refused, listing the package's scripts",
    tostring(e2):find("no script 'build'", 1, true) ~= nil and tostring(e2):find("dev, start", 1, true) ~= nil, tostring(e2))
  ok("[47] program and script together are refused",
    tostring(node.program_error(eff({ program = "server.js", script = "dev" }))):find("not both", 1, true) ~= nil)
  ok("[47] neither is refused", tostring(node.program_error(eff({}))):find("set `program`", 1, true) ~= nil)

  -- scaffolding from the working directory's package.json
  worktree.set_active(root .. "/web")
  store_paths.invalidate()
  local d1 = node.default_config("run", "start")
  ok("[47] scaffold: a name that is a script becomes `script`, cwd is the package folder",
    d1.script == "start" and d1.cwd == "${worktree}/web" and d1.program == nil, vim.inspect(d1))
  local d2 = node.default_config("debug", "server")
  ok("[47] scaffold: otherwise dev/start/serve", d2.script == "dev", vim.inspect(d2))
  ok("[47] the `a` chooser offers node", vim.tbl_contains(require("auto-run.adapters").scaffold_runtimes(), "node"))

  -- debug launch fields (pwa-node), through the public debug_start path
  local cb_launch
  node.prepare_debug_config(eff({ script = "dev", args = { "--x" } }), {}, function(l) cb_launch = l end)
  ok("[47] a script debugs as runtimeExecutable npm + runtimeArgs run dev -- args, with outputCapture std",
    cb_launch and cb_launch.dap_type == "pwa-node" and cb_launch.extra.runtimeExecutable == "npm"
      and vim.deep_equal(cb_launch.extra.runtimeArgs, { "run", "dev", "--", "--x" })
      and cb_launch.extra.outputCapture == "std", vim.inspect(cb_launch))
  worktree.set_active(root)
  store_paths.invalidate()
  store.add({ name = "web-dev", kind = "debug", runtime = "node", script = "dev", cwd = "${worktree}/web" }, { tier = "tracked" })
  local calls = NEW.capture_dap_run(function(dap)
    local had = dap.adapters["pwa-node"]
    dap.adapters["pwa-node"] = had or { type = "server", host = "127.0.0.1", port = 1 }
    local okd, derr = require("auto-run.dap").debug_start("web-dev")
    ok("[47] debug_start on a node config succeeds", okd == true, tostring(derr))
    dap.adapters["pwa-node"] = had
  end)
  local c = calls and calls[1]
  ok("[47] nvim-dap receives type pwa-node with the verified fields",
    c and c.type == "pwa-node" and c.runtimeExecutable == "npm" and c.outputCapture == "std"
      and c.cwd == root .. "/web" and vim.deep_equal(c.runtimeArgs, { "run", "dev" }), vim.inspect(c))
  local calls2 = NEW.capture_dap_run(function(dap)
    local had = dap.adapters["pwa-node"]
    dap.adapters["pwa-node"] = nil
    local real_cmd = require("auto-run.dap").js_debug_command
    require("auto-run.dap").js_debug_command = function() return nil end
    local okd, derr = require("auto-run.dap").debug_start("web-dev")
    ok("[47] without any JavaScript debug adapter the debug is refused, naming the fix",
      okd == nil and tostring(derr):find("js-debug-adapter", 1, true) ~= nil, tostring(derr))
    require("auto-run.dap").js_debug_command = real_cmd
    dap.adapters["pwa-node"] = had
  end)
  ok("[47] ... and nvim-dap is never called", calls2 and #calls2 == 0)
  store.remove("web-dev")
  NEW.restore(prev)
end)()

-- ── [48] jest: RTL, debug, preflight, Playwright exclusion ───────
print("\n[48] jest — debug a test, preflight, and Playwright specs are not Jest's")
;(function()
  local prev = worktree.get_active()
  local root = fx .. "/jest48"
  ok("[48] fixture repo", NEW.repo(root))
  write_file(root .. "/package.json", vim.json.encode({ name = "j48" }))
  write_file(root .. "/node_modules/.bin/jest", "#!/bin/sh\nexit 0\n")
  vim.uv.fs_chmod(root .. "/node_modules/.bin/jest", tonumber("755", 8))
  write_file(root .. "/node_modules/jest/bin/jest.js", "")
  local tfile = root .. "/test/App.test.tsx"
  write_file(tfile, table.concat({
    "import { render } from '@testing-library/preact';",
    "describe('outer', () => {",
    "  test('adds (one)', () => { render(<p/>); });",
    "  test('adds', () => {});",
    "});", "" }, "\n"))
  P3.discovery._reset_for_tests()
  require("auto-run.adapters.jest")._reset_for_tests()
  local outcome, perr = P3.discovery.parse_file(tfile)
  ok("[48] an RTL .tsx test file is discovered by jest", outcome == "parsed", tostring(perr))
  local ids = NEW.ids_by_name(P3.discovery.tree().root)
  local calls = NEW.capture_dap_run(function(dap)
    local had = dap.adapters["pwa-node"]
    dap.adapters["pwa-node"] = had or { type = "server", host = "127.0.0.1", port = 1 }
    local okd, derr = P3.discovery.debug_position(ids["adds (one)"])
    ok("[48] debug_position on a jest test succeeds", okd == true, tostring(derr))
    dap.adapters["pwa-node"] = had
  end)
  local c = calls and calls[1]
  local args = c and table.concat(c.args or {}, " ") or ""
  ok("[48] jest debug runs jest/bin/jest.js under pwa-node, --runInBand first, output captured",
    c and c.type == "pwa-node" and c.program == root .. "/node_modules/jest/bin/jest.js"
      and c.args[1] == "--runInBand" and c.outputCapture == "std" and c.cwd == root, vim.inspect(c))
  ok("[48] ... selecting exactly that test (anchored, escaped) in that file",
    args:find("--testNamePattern=^outer adds \\(one\\)$", 1, true) ~= nil and args:find("App\\.test\\.tsx", 1, true) ~= nil, args)

  -- preflight: dependencies declared, node_modules absent → refused, nothing spawns
  local root2 = fx .. "/jest48b"
  ok("[48] fixture repo b", NEW.repo(root2))
  write_file(root2 .. "/package.json", vim.json.encode({ name = "b", devDependencies = { jest = "^30" } }))
  write_file(root2 .. "/a.test.js", "test('x', () => {})\n")
  P3.discovery._reset_for_tests()
  require("auto-run.adapters.jest")._reset_for_tests()
  P3.discovery.parse_file(root2 .. "/a.test.js")
  local before = #require("auto-run.exec").list()
  local launched, lerr = P3.discovery.run_position(root2 .. "/a.test.js")
  ok("[48] a missing node_modules refuses the run with the install command",
    launched == nil and tostring(lerr):find("dependencies are not installed", 1, true) ~= nil
      and tostring(lerr):find("npm install", 1, true) ~= nil, tostring(lerr))
  ok("[48] ... and no job spawned", #require("auto-run.exec").list() == before)
  local rs = P3.discovery.results()
  ok("[48] ... and nothing was left marked running", rs[root2 .. "/a.test.js::x"] == nil, vim.inspect(rs))
  vim.fn.mkdir(root2 .. "/node_modules", "p")
  local issues = require("auto-run.adapters").preflight(require("auto-run.adapters.jest"), { root = root2, purpose = "test" })
  ok("[48] node_modules present but no jest → jest_missing with its install command",
    #issues == 1 and issues[1].code == "jest_missing" and issues[1].fix == "npm install -D jest", vim.inspect(issues))
  local doc = require("auto-run.adapters").doctor(root2)
  local jrow
  for _, r in ipairs(doc) do if r.name == "jest" then jrow = r end end
  ok("[48] doctor lists jest's issue for this directory", jrow and #jrow.issues >= 1, vim.inspect(doc))

  -- a spec importing @playwright/test under a Playwright root is Playwright's
  local root3 = fx .. "/pw48"
  write_file(root3 .. "/package.json", "{}")
  write_file(root3 .. "/e2e/a.spec.ts", "import { test } from '@playwright/test';\ntest('t', async () => {});\n")
  write_file(root3 .. "/unit/b.spec.ts", "test('u', () => {});\n")
  local jest = require("auto-run.adapters.jest")
  ok("[48] without a playwright config, a @playwright/test spec is still jest-shaped (no Playwright root)",
    jest.is_test_file(root3 .. "/e2e/a.spec.ts"))
  write_file(root3 .. "/playwright.config.ts", "export default {}\n")
  ok("[48] with a playwright config, jest declines the @playwright/test spec", not jest.is_test_file(root3 .. "/e2e/a.spec.ts"))
  ok("[48] ... and keeps the plain spec beside it", jest.is_test_file(root3 .. "/unit/b.spec.ts"))
  local a_pw = P3.adapters.adapter_for(root3 .. "/e2e/a.spec.ts")
  local a_js = P3.adapters.adapter_for(root3 .. "/unit/b.spec.ts")
  ok("[48] adapter_for attributes them: playwright / jest",
    a_pw and a_pw.name == "playwright" and a_js and a_js.name == "jest",
    vim.inspect({ a_pw and a_pw.name, a_js and a_js.name }))
  NEW.restore(prev)
end)()

-- ── [49] playwright ──────────────────────────────────────────────
print("\n[49] playwright — discovery, file:line runs, the JSON report, browsers, debug")
;(function()
  local pw = require("auto-run.adapters.playwright")
  local prev = worktree.get_active()
  local root = fx .. "/pw49"
  ok("[49] fixture repo", NEW.repo(root))
  write_file(root .. "/package.json", vim.json.encode({ name = "pw", devDependencies = { ["@playwright/test"] = "^1" } }))
  write_file(root .. "/playwright.config.ts", "export default { testDir: './tests' }\n")
  local cli = root .. "/node_modules/@playwright/test/cli.js"
  write_file(cli, "")
  vim.fn.mkdir(root .. "/node_modules/.bin", "p")
  vim.uv.fs_symlink("../@playwright/test/cli.js", root .. "/node_modules/.bin/playwright")
  local spec = root .. "/tests/a.spec.ts"
  write_file(spec, table.concat({
    "import { test, expect } from '@playwright/test';", -- 1
    "test.describe('outer', () => {",                   -- 2
    "  test('adds', async () => {});",                  -- 3
    "  test.fixme('later', async () => {});",           -- 4
    "  test.skip('skipped', async () => {});",          -- 5
    "  test.describe('inner', () => {",                 -- 6
    "    test('deep', async () => { test.skip(); });",  -- 7
    "  });",                                            -- 8
    "});",                                              -- 9
    "test('top', async ({ page }) => {});",             -- 10
    "" }, "\n"))
  P3.discovery._reset_for_tests()
  local outcome, perr = P3.discovery.parse_file(spec)
  ok("[49] a Playwright spec is discovered by the playwright adapter", outcome == "parsed", tostring(perr))
  local file_node = P3.discovery.tree():get(spec)
  ok("[49] ... owned by playwright", file_node and file_node.adapter == "playwright")
  if not (file_node and file_node.adapter == "playwright") then
    -- Every cell below needs Playwright's positions; stop here (failed above).
    NEW.restore(prev)
    return
  end
  local ids = NEW.ids_by_name(P3.discovery.tree().root)
  ok("[49] describes nest; test / test.fixme / test.skip are tests; a title-less test.skip() is not",
    ids["outer"] == spec .. "::outer" and ids["deep"] == spec .. "::outer::inner::deep"
      and ids["later"] ~= nil and ids["skipped"] ~= nil and ids["top"] == spec .. "::top"
      and #(P3.discovery.tree():get(ids["deep"]).children or {}) == 0, vim.inspect(ids))

  local run_dir = fx .. "/pw49-run"
  vim.fn.mkdir(run_dir, "p")
  local tree = P3.discovery.tree()
  local s1 = pw.build_spec({ position = tree:get(ids["deep"]), tree = tree, root = root, run_id = "r", run_dir = run_dir })
  ok("[49] a test runs by position: playwright test --reporter=json tests/a.spec.ts:7",
    s1 and s1.cmd[1] == root .. "/node_modules/.bin/playwright"
      and vim.deep_equal({ unpack(s1.cmd, 2) }, { "test", "--reporter=json", "tests/a.spec.ts:7" })
      and s1.env.PLAYWRIGHT_JSON_OUTPUT_NAME == run_dir .. "/playwright.json", vim.inspect(s1))
  local s2 = pw.build_spec({ position = tree:get(ids["outer"]), tree = tree, root = root, run_id = "r", run_dir = run_dir })
  ok("[49] a describe runs by its line", s2 and s2.cmd[#s2.cmd] == "tests/a.spec.ts:2", vim.inspect(s2 and s2.cmd))

  -- the report: the real shape recorded on VM43 (ADR 0213 P2)
  local report = {
    config = { rootDir = root .. "/tests" },
    suites = { {
      title = "a.spec.ts", file = "a.spec.ts", line = 0,
      specs = { { title = "top", line = 10, file = "a.spec.ts", tests = {
        { projectName = "chromium", status = "expected", results = { { status = "passed", duration = 5 } } },
        { projectName = "firefox", status = "unexpected", results = { { status = "failed", duration = 3,
          error = { message = "\27[31mbrowserType.launch: Executable doesn't exist\27[39m" } } } },
      } } },
      suites = { {
        title = "outer", file = "a.spec.ts", line = 2,
        specs = {
          { title = "adds", line = 3, file = "a.spec.ts", tests = { { projectName = "chromium", status = "expected",
            results = { { status = "passed", duration = 1, stdout = { { text = "hello\n" } } } } } } },
          { title = "skipped", line = 5, file = "a.spec.ts", tests = { { projectName = "chromium", status = "skipped",
            results = { { status = "skipped" } } } } },
        },
        suites = { { title = "inner", file = "a.spec.ts", line = 6, specs = {
          { title = "deep", line = 7, file = "a.spec.ts", tests = { { projectName = "chromium", status = "flaky",
            results = { { status = "failed" }, { status = "passed" } } } } },
        } } },
      } },
    } },
  }
  write_file(run_dir .. "/playwright.json", vim.json.encode(report))
  local res = pw.results({ context = { position_id = spec, output_file = run_dir .. "/playwright.json" } }, {}, tree)
  ok("[49] a test failing in ONE project is failed, its error de-coloured",
    res[ids["top"]] and res[ids["top"]].status == "failed"
      and res[ids["top"]].output == "browserType.launch: Executable doesn't exist", vim.inspect(res[ids["top"]]))
  ok("[49] nested describes map by title chain + rootDir-relative file",
    res[ids["adds"]] and res[ids["adds"]].status == "passed", vim.inspect(res))
  ok("[49] skipped is skipped; flaky counts as passed",
    res[ids["skipped"]] and res[ids["skipped"]].status == "skipped" and res[ids["deep"]] and res[ids["deep"]].status == "passed")
  ok("[49] the output view carries the test's stdout",
    pw.output({ run_dir = run_dir }):find("hello", 1, true) ~= nil)

  -- browsers: the installed Playwright's revisions, not "anything in the cache"
  write_file(root .. "/node_modules/playwright-core/browsers.json", vim.json.encode({ browsers = {
    { name = "chromium", revision = "1243", installByDefault = true },
    { name = "chromium-headless-shell", revision = "1243", installByDefault = true },
    { name = "firefox", revision = "1543", installByDefault = true },
    { name = "webkit", revision = "2359", installByDefault = true },
    { name = "ffmpeg", revision = "1011", installByDefault = true },
  } }))
  local cache = fx .. "/pw49-browsers"
  vim.fn.mkdir(cache .. "/chromium-1228", "p")
  vim.fn.mkdir(cache .. "/chromium_headless_shell-1228", "p")
  local prev_env = vim.env.PLAYWRIGHT_BROWSERS_PATH
  vim.env.PLAYWRIGHT_BROWSERS_PATH = cache
  local i1 = require("auto-run.adapters").preflight(pw, { root = root, purpose = "test" })
  local b1
  for _, i in ipairs(i1) do if i.code == "browsers_missing" then b1 = i end end
  ok("[49] an OLDER browser revision in the cache still counts as missing → error with the install command",
    b1 and b1.level == "error" and b1.fix == "npx playwright install", vim.inspect(i1))
  vim.fn.mkdir(cache .. "/chromium-1243", "p")
  vim.fn.mkdir(cache .. "/chromium_headless_shell-1243", "p")
  local i2 = require("auto-run.adapters").preflight(pw, { root = root, purpose = "test" })
  local b2
  for _, i in ipairs(i2) do if i.code == "browsers_missing" then b2 = i end end
  ok("[49] chromium at the right revision → a warning naming the others",
    b2 and b2.level == "warn" and b2.message:find("firefox, webkit", 1, true) ~= nil, vim.inspect(i2))
  vim.fn.mkdir(cache .. "/firefox-1543", "p")
  vim.fn.mkdir(cache .. "/webkit-2359", "p")
  local i3 = require("auto-run.adapters").preflight(pw, { root = root, purpose = "test" })
  ok("[49] all present → no browser issue", #vim.tbl_filter(function(i) return i.code == "browsers_missing" end, i3) == 0,
    vim.inspect(i3))
  vim.env.PLAYWRIGHT_BROWSERS_PATH = prev_env

  -- debug: the CLI script under pwa-node, one worker, no timeout
  local calls = NEW.capture_dap_run(function(dap)
    local had = dap.adapters["pwa-node"]
    dap.adapters["pwa-node"] = had or { type = "server", host = "127.0.0.1", port = 1 }
    vim.env.PLAYWRIGHT_BROWSERS_PATH = cache
    local okd, derr = P3.discovery.debug_position(ids["deep"])
    vim.env.PLAYWRIGHT_BROWSERS_PATH = prev_env
    ok("[49] debug_position on a playwright test succeeds", okd == true, tostring(derr))
    dap.adapters["pwa-node"] = had
  end)
  local c = calls and calls[1]
  ok("[49] playwright debug: cli.js (the real file, not the .bin link), test file:line --workers=1 --timeout=0",
    c and c.type == "pwa-node" and c.program == vim.uv.fs_realpath(cli)
      and vim.deep_equal(c.args, { "test", "tests/a.spec.ts:7", "--workers=1", "--timeout=0" })
      and c.outputCapture == "std", vim.inspect(c))
  NEW.restore(prev)
end)()

-- ── [50] dart / flutter adapter ──────────────────────────────────
-- ADR 0196 r3. Package kind from pub's package_config.json; anchored --name;
-- testWidgets locations in root_url. Real-SDK cells run when `dart` is on PATH
-- (VM43 has Flutter 3.47.5); their count is asserted so an absent SDK on a
-- machine that has one cannot pass silently.
local HAVE_DART_TS = pcall(vim.treesitter.language.inspect, "dart")
local HAVE_DART = vim.fn.executable("dart") == 1
local HAVE_FLUTTER = vim.fn.executable("flutter") == 1
local dart_real = 0
print("\n[50] dart / flutter — package kind, discovery, selection, results"
  .. (HAVE_DART and "" or "  (no dart on PATH: real-SDK cells skipped)"))
;(function()
  local dart = require("auto-run.adapters.dart")
  local prev = worktree.get_active()
  local root = fx .. "/dart50"
  ok("[50] fixture repo", NEW.repo(root))
  local pkg = root .. "/pkg"
  local function pubspec(body) write_file(pkg .. "/pubspec.yaml", "name: d50\nenvironment:\n  sdk: ^3.0.0\n" .. body) end
  pubspec("dev_dependencies:\n  test: any\n")
  dart._reset_for_tests()

  -- package kind
  local k0, code0 = dart.package_kind(pkg)
  ok("[50] no package_config.json → no kind (not_fetched), never a guess", k0 == nil and code0 == "not_fetched")
  local issues0 = require("auto-run.adapters").preflight(dart, { root = pkg, purpose = "test" })
  local nf
  for _, i in ipairs(issues0) do if i.code == "not_fetched" then nf = i end end
  ok("[50] preflight: not fetched → error with `dart pub get`", nf and nf.level == "error" and nf.fix:find("dart pub get", 1, true) ~= nil,
    vim.inspect(issues0))
  local function hint() return dart.pubspec_mentions_flutter(pkg) end
  pubspec("dev_dependencies:\n  flutter_test: {sdk: flutter}  # inline\n")
  ok("[50] pub-get hint: an inline `{sdk: flutter}` mapping reads as Flutter", hint())
  pubspec("dependencies:\n  flutter:\n    sdk: flutter\n")
  ok("[50] pub-get hint: a block `sdk: flutter` reads as Flutter", hint())
  pubspec("dependencies:\n  flutter:\n    sdk: \"flutter\"\n")
  ok("[50] pub-get hint: a quoted value reads as Flutter", hint())
  pubspec("# this used to depend on sdk: flutter\ndependencies:\n  path: any\n")
  ok("[50] pub-get hint: a comment mentioning it does not", not hint())
  pubspec("dev_dependencies:\n  test: any\n")

  local pc = pkg .. "/.dart_tool/package_config.json"
  write_file(pc, vim.json.encode({ configVersion = 2, packages = { { name = "test", rootUri = "file:///x" }, { name = "d50", rootUri = "../" } } }))
  ok("[50] resolved graph without `flutter` → dart", dart.package_kind(pkg) == "dart")
  write_file(pc, vim.json.encode({ configVersion = 2, packages = { { name = "flutter", rootUri = "file:///sdk/packages/flutter" },
    { name = "flutter_test", rootUri = "file:///sdk/packages/flutter_test" }, { name = "d50", rootUri = "../" } } }))
  ok("[50] the same package after re-resolution with `flutter` (flutter_test pulls it in) → flutter, the cache re-read",
    dart.package_kind(pkg) == "flutter")
  write_file(pc, "{ not json")
  local km, cm = dart.package_kind(pkg)
  ok("[50] malformed package_config.json → a structured error, not a fallback", km == nil and cm == "malformed")
  write_file(pc, vim.json.encode({ configVersion = 2, packages = { { name = "test", rootUri = "file:///x" } } }))

  -- test files + discovery
  local tfile = pkg .. "/test/calc_test.dart"
  write_file(tfile, table.concat({
    "import 'package:test/test.dart';",
    "void main() {",
    "  group('outer', () {",
    "    group(\"inner\", () {",
    "      test('add', () => expect(1 + 1, 2));",
    "      test('adds', () => expect(2 + 2, 4));",
    "    });",
    "    test('fails', () => expect(1, 2));",
    "    test('skipped', () {}, skip: 'not now');",
    "    final x = 1;",
    "    test('interp $x', () {});",
    "    test(r'raw $not (interp)', () {});",
    "  });",
    "}", "" }, "\n"))
  write_file(pkg .. "/integration_test/app_test.dart", "void main() {}\n")
  write_file(pkg .. "/lib/x_test.dart", "void main() {}\n")
  ok("[50] *_test.dart under test/ is a test file", dart.is_test_file(tfile))
  ok("[50] integration_test/ and lib/ are not", not dart.is_test_file(pkg .. "/integration_test/app_test.dart")
    and not dart.is_test_file(pkg .. "/lib/x_test.dart"))
  ok("[50] literal decoding: adjacent, triple, raw, escapes; interpolation → nil",
    dart.decode_literal("'adj' 'acent'") == "adjacent" and dart.decode_literal("'''tri'''") == "tri"
      and dart.decode_literal("r'a$b'") == "a$b" and dart.decode_literal([['it\'s']]) == "it's"
      and dart.decode_literal("'v $x'") == nil and dart.decode_literal("'v ${x}'") == nil)
  if not HAVE_DART_TS then
    ok("[50] dart treesitter parser available (install it: see .github/install-parsers.sh)", false)
    NEW.restore(prev)
    return
  end
  P3.discovery._reset_for_tests()
  local outcome, perr = P3.discovery.parse_file(tfile)
  ok("[50] the dart adapter discovers the file", outcome == "parsed" and (P3.discovery.tree():get(tfile) or {}).adapter == "dart",
    tostring(perr))
  local ids = NEW.ids_by_name(P3.discovery.tree().root)
  ok("[50] nested groups → namespaces; interpolated description → no position; raw `$` kept",
    ids["add"] == tfile .. "::outer::inner::add" and ids["interp $x"] == nil and ids["raw $not (interp)"] ~= nil,
    vim.inspect(ids))
  local tree = P3.discovery.tree()
  ok("[50] selection: an anchored --name regex — exact for a test, a word prefix for a group, metachars escaped",
    dart.name_pattern(tree:get(ids["add"])) == "^outer inner add$"
      and dart.name_pattern(tree:get(ids["inner"])) == "^outer inner( |$)"
      and dart.name_pattern(tree:get(ids["raw $not (interp)"])) == "^outer raw \\$not \\(interp\\)$")
  local spec = dart.build_spec({ position = tree:get(ids["add"]), tree = tree, root = pkg, run_id = "r", run_dir = fx })
  ok("[50] a test runs as `dart test --reporter=json test/calc_test.dart --name ^outer inner add$` in the package",
    spec and vim.deep_equal(spec.cmd, { "dart", "test", "--reporter=json", "test/calc_test.dart", "--name", "^outer inner add$" })
      and spec.cwd == pkg, vim.inspect(spec))
  store.add({ name = "dt50", kind = "test", runtime = "dart", dart_sdk = "flutter" }, { tier = "tracked" })
  local spec2 = dart.build_spec({ position = tree:get(tfile), tree = tree, root = pkg, run_id = "r", run_dir = fx })
  ok("[50] the dart test config's dart_sdk overrides detection", spec2 and spec2.cmd[1] == "flutter", vim.inspect(spec2))
  store.remove("dt50")

  -- results from the reporter stream (shape verified on VM43)
  local wfile = pkg .. "/test/w_test.dart"
  write_file(wfile, "import 'package:flutter_test/flutter_test.dart';\nvoid main() {\n  group('g', () {\n"
    .. "    test('adds', () {});\n    testWidgets('widget', (t) async {});\n  });\n  test('top skip', () {}, skip: true);\n}\n")
  P3.discovery.parse_file(wfile)
  tree = P3.discovery.tree()
  local wids = NEW.ids_by_name(tree:get(wfile))
  local furl = vim.uri_from_fname(wfile)
  local lines = {
    { type = "suite", suite = { id = 0, path = "test/w_test.dart" } },
    { type = "testStart", test = { id = 1, name = "loading test/w_test.dart", suiteID = 0 }, time = 0 },
    { type = "testDone", testID = 1, result = "success", skipped = false, hidden = true, time = 5 },
    { type = "testStart", test = { id = 3, name = "g adds", suiteID = 0, line = 4, url = furl }, time = 10 },
    { type = "testDone", testID = 3, result = "success", skipped = false, hidden = false, time = 12 },
    { type = "testStart", test = { id = 4, name = "g widget", suiteID = 0, line = 160,
      url = "file:///sdk/packages/flutter_test/lib/src/widget_tester.dart", root_line = 5, root_url = furl }, time = 13 },
    { type = "error", testID = 4, error = "Expected: 1\n  Actual: 2", stackTrace = "at w_test.dart:5", time = 14 },
    { type = "testDone", testID = 4, result = "failure", skipped = false, hidden = false, time = 15 },
    { type = "testStart", test = { id = 5, name = "top skip", suiteID = 0, line = 7, url = furl }, time = 16 },
    { type = "testDone", testID = 5, result = "success", skipped = true, hidden = false, time = 16 },
    { type = "done", success = false },
  }
  local stdout = fx .. "/dart50-stdout"
  local enc = {}
  for _, l in ipairs(lines) do enc[#enc + 1] = vim.json.encode(l) end
  write_file(stdout, "Resolving dependencies...\n" .. table.concat(enc, "\n") .. "\n")
  local res = dart.results({ context = { position_id = wfile, root = pkg } }, { stdout_file = stdout }, tree)
  ok("[50] a testWidgets result lands on its position through root_url (url points into flutter_test)",
    res[wids["widget"]] and res[wids["widget"]].status == "failed"
      and tostring(res[wids["widget"]].output):find("Expected: 1", 1, true) ~= nil, vim.inspect(res))
  ok("[50] passed, and skip (result=success, skipped=true) → skipped; the hidden loading test is ignored",
    res[wids["adds"]] and res[wids["adds"]].status == "passed" and res[wids["top skip"]] and res[wids["top skip"]].status == "skipped"
      and vim.tbl_count(res) == 3, vim.inspect(res))
  local lerr_lines = {
    vim.json.encode({ type = "suite", suite = { id = 0, path = "test/w_test.dart" } }),
    vim.json.encode({ type = "testStart", test = { id = 1, name = "loading test/w_test.dart", suiteID = 0 }, time = 0 }),
    vim.json.encode({ type = "error", testID = 1, error = "Failed to load: Error: Undefined name 'x'.", time = 1 }),
    vim.json.encode({ type = "testDone", testID = 1, result = "error", skipped = false, hidden = false, time = 2 }),
  }
  write_file(stdout, table.concat(lerr_lines, "\n") .. "\n")
  local lres = dart.results({ context = { position_id = wfile, root = pkg } }, { stdout_file = stdout }, tree)
  ok("[50] a file that fails to load (compile error) fails its tests WITH the compiler's message",
    lres[wids["adds"]] and lres[wids["adds"]].status == "failed"
      and tostring(lres[wids["adds"]].output):find("Undefined name", 1, true) ~= nil and vim.tbl_count(lres) == 3, vim.inspect(lres))

  -- real SDK: a pure Dart package, the whole file, then ONE test by its exact name
  if HAVE_DART then
    vim.fn.delete(pc)
    local pg = vim.system({ "dart", "pub", "get", "--offline" }, { cwd = pkg, text = true }):wait()
    dart_real = dart_real + 1
    ok("[50][real] dart pub get --offline resolves the fixture", pg.code == 0, (pg.stderr or "") .. (pg.stdout or ""))
    os.remove(wfile)
    P3.discovery._reset_for_tests()
    P3.discovery.parse_file(tfile)
    tree = P3.discovery.tree()
    ids = NEW.ids_by_name(tree:get(tfile))
    local done
    local launched, lerr = P3.discovery.run_position(tfile, { on_done = function(b) done = b end })
    ok("[50][real] dart test runs the file", launched ~= nil, tostring(lerr))
    wait_for(function() return done end, 120000)
    dart_real = dart_real + 1
    ok("[50][real] add / adds passed, fails failed, skipped skipped — from real `dart test` JSON",
      done and done[ids["add"]] and done[ids["add"]].status == "passed" and done[ids["adds"]].status == "passed"
        and done[ids["fails"]].status == "failed" and done[ids["skipped"]].status == "skipped", vim.inspect(done))
    done = nil
    local l2 = P3.discovery.run_position(ids["add"], { on_done = function(b) done = b end })
    wait_for(function() return done end, 120000)
    local out = ""
    if l2 and l2.runs[1] then
      local f = io.open(require("auto-run.exec.job").run_dir(l2.runs[1].id) .. "/stdout", "r")
      if f then out = f:read("*a") f:close() end
    end
    dart_real = dart_real + 1
    ok("[50][real] running `outer inner add` does NOT also run its prefix sibling `outer inner adds` (anchored --name)",
      out:find('"name":"outer inner add"', 1, true) ~= nil and out:find('"name":"outer inner adds"', 1, true) == nil
        and done and done[ids["add"]] and done[ids["add"]].status == "passed", out:sub(1, 400))
  end
  if HAVE_FLUTTER then
    local fpkg = root .. "/fpkg"
    write_file(fpkg .. "/pubspec.yaml", "name: f50\nenvironment:\n  sdk: ^3.0.0\ndependencies:\n  flutter:\n    sdk: flutter\n"
      .. "dev_dependencies:\n  flutter_test:\n    sdk: flutter\n")
    local ffile = fpkg .. "/test/widget_test.dart"
    write_file(ffile, "import 'package:flutter/widgets.dart';\nimport 'package:flutter_test/flutter_test.dart';\n"
      .. "void main() {\n  group('w', () {\n    testWidgets('pumps', (tester) async {\n"
      .. "      await tester.pumpWidget(const SizedBox());\n    });\n  });\n}\n")
    local pg = vim.system({ "flutter", "pub", "get", "--offline" }, { cwd = fpkg, text = true }):wait()
    dart_real = dart_real + 1
    ok("[50][real] flutter pub get --offline resolves the Flutter fixture", pg.code == 0, (pg.stderr or "") .. (pg.stdout or ""))
    dart_real = dart_real + 1
    ok("[50][real] pub's resolution says flutter", dart.package_kind(fpkg) == "flutter")
    P3.discovery.parse_file(ffile)
    local fid = NEW.ids_by_name(P3.discovery.tree():get(ffile))["pumps"]
    local done
    P3.discovery.run_position(ffile, { on_done = function(b) done = b end })
    wait_for(function() return done end, 240000)
    dart_real = dart_real + 1
    ok("[50][real] flutter test: the testWidgets test passes on its own position", done and done[fid] and done[fid].status == "passed",
      vim.inspect(done))
  end
  NEW.restore(prev)
end)()

-- ── [51] dart debug: the launch matrix and the testNotification bridge ──
-- ADR 0196 r3 §2.3 / §2.3.1 (Lector r2 MF1 + MF2): refusals happen before
-- dap.run; debugged-test results reach the canonical results through the
-- bridge, per session, with stale and foreign events ignored.
print("\n[51] dart debug — launch matrix, refusals before dap.run, the testNotification bridge")
;(function()
  if not HAVE_DART_TS then
    ok("[51] dart treesitter parser available", false)
    return
  end
  local okd, dap = pcall(require, "dap")
  if not okd then ok("[51] nvim-dap available", false) return end
  local bridge_mod = require("auto-run.dap")
  bridge_mod.setup() -- idempotent: attaches the bridge listeners
  -- The synthetic part below tests the launch matrix and the bridge, not the
  -- SDK: preflight would (rightly) refuse every Dart debug on a machine without
  -- one (CI), before the bridge is ever reached. So `dart` / `flutter` read as
  -- installed until the real-SDK block, which uses the real PATH.
  local real_executable = vim.fn.executable
  vim.fn.executable = function(x)
    if x == "dart" or x == "flutter" then return 1 end
    return real_executable(x)
  end
  local prev = worktree.get_active()
  local root = fx .. "/dart51"
  ok("[51] fixture repo", NEW.repo(root))
  local pkg = root .. "/pkg"
  write_file(pkg .. "/pubspec.yaml", "name: d51\nenvironment:\n  sdk: ^3.0.0\ndev_dependencies:\n  test: any\n")
  write_file(pkg .. "/.dart_tool/package_config.json", vim.json.encode({ configVersion = 2, packages = { { name = "test", rootUri = "file:///x" } } }))
  local tfile = pkg .. "/test/b_test.dart"
  write_file(tfile, "import 'package:test/test.dart';\nvoid main() {\n  group('g', () {\n    test('one', () {});\n"
    .. "    test('two', () {});\n    test('three', () {});\n    test('four', () {});\n  });\n}\n")
  require("auto-run.adapters.dart")._reset_for_tests()
  require("auto-run.dap.dart_tests")._reset_for_tests()
  P3.discovery._reset_for_tests()
  P3.discovery.parse_file(tfile)
  local ids = NEW.ids_by_name(P3.discovery.tree():get(tfile))

  -- the adapter: registered when free, rows by discriminant, never overwriting another plugin's
  local had_dart = dap.adapters.dart
  dap.adapters.dart = nil
  bridge_mod.ensure_dart_adapter(dap)
  ok("[51] auto-run registers dap.adapters.dart when the key is free", bridge_mod.owns_dart_adapter(dap))
  local rows = {}
  for _, r in ipairs({ { "dart", "run" }, { "dart", "test" }, { "flutter", "run" }, { "flutter", "test" } }) do
    dap.adapters.dart(function(a) rows[#rows + 1] = a.command .. " " .. table.concat(a.args, " ") end,
      { autoRunDartKind = r[1], autoRunDartMode = r[2] })
  end
  ok("[51] the four rows: dart debug_adapter [--test], flutter debug-adapter [--test]",
    vim.deep_equal(rows, { "dart debug_adapter", "dart debug_adapter --test", "flutter debug-adapter", "flutter debug-adapter --test" }),
    vim.inspect(rows))
  local foreign = function(cb) cb({ type = "executable", command = "x" }) end
  dap.adapters.dart = foreign
  bridge_mod.ensure_dart_adapter(dap)
  ok("[51] another plugin's dap.adapters.dart is never overwritten", dap.adapters.dart == foreign)
  local fi = require("auto-run.adapters").preflight(require("auto-run.adapters.dart"), { root = pkg, purpose = "debug" })
  ok("[51] ... and debug preflight warns about it", #vim.tbl_filter(function(i) return i.code == "dart_adapter_foreign" and i.level == "warn" end, fi) == 1,
    vim.inspect(fi))
  dap.adapters.dart = nil
  bridge_mod.ensure_dart_adapter(dap)

  -- refusals before dap.run (MF1): through the public launch and debug_start
  local calls = NEW.capture_dap_run(function()
    local l1, e1 = bridge_mod.launch({ dap_type = "dart", program = "lib/main.dart",
      extra = { autoRunDartKind = "flutter", autoRunDartMode = "run", autoRunDartDevice = "android" } })
    ok("[51] a Flutter app launch on a non-desktop device is refused with the boundary named",
      l1 == nil and tostring(e1):find("desktop devices only", 1, true) ~= nil, tostring(e1))
    local l2, e2 = bridge_mod.launch({ dap_type = "dart", extra = { autoRunDartKind = "kotlin", autoRunDartMode = "run" } })
    ok("[51] an unknown kind is refused", l2 == nil and tostring(e2):find("unknown kind", 1, true) ~= nil, tostring(e2))
    write_file(pkg .. "/lib/main.dart", "void main() {}\n")
    store.add({ name = "f51", kind = "debug", runtime = "dart", dart_sdk = "flutter", device = "chrome",
      program = "${worktree}/pkg/lib/main.dart", cwd = "${worktree}/pkg" }, { tier = "tracked" })
    local l3, e3 = bridge_mod.debug_start("f51")
    ok("[51] debug_start of a Flutter config on chrome is refused", l3 == nil and tostring(e3):find("desktop devices only", 1, true) ~= nil,
      tostring(e3))
    store.remove("f51")
  end)
  ok("[51] ... none of them reached dap.run", calls and #calls == 0, vim.inspect(calls))

  -- a debugged test: the launch carries the run id; events flow through nvim-dap's listener table
  local cfgs = NEW.capture_dap_run(function()
    for _, n in ipairs({ "one", "two", "three", "four" }) do
      local okp, perr = P3.discovery.debug_position(ids[n])
      ok("[51] debug_position(" .. n .. ")", okp == true, tostring(perr))
    end
  end)
  local c1 = cfgs and cfgs[1]
  ok("[51] the launch: type dart, test mode, a run id, the exact --name, the file as program",
    c1 and c1.type == "dart" and c1.autoRunDartKind == "dart" and c1.autoRunDartMode == "test" and type(c1.autoRunRunId) == "string"
      and vim.deep_equal(c1.toolArgs, { "--name", "^g one$" }) and c1.program == tfile and c1.cwd == pkg, vim.inspect(c1))
  local function status(id) local r = P3.discovery.results()[id] return r and r.status end
  local rs = P3.discovery.results()
  ok("[51] the debugged tests show running until their session reports", status(ids["one"]) == "running",
    vim.inspect({ ids = ids, results = rs, root = P3.discovery.tree().root.path }))
  local L = dap.listeners.after
  local KEY = "auto-run.dart_tests"
  local function notify(sess, body) L["event_dart.testNotification"][KEY](sess, body) end
  local s1 = { id = 99001, config = cfgs[1] }
  local s2 = { id = 99002, config = cfgs[2] }
  local furl = vim.uri_from_fname(tfile)
  -- interleaved: two sessions at once
  notify(s1, { type = "testStart", test = { id = 3, name = "g one", url = furl }, time = 1 })
  notify(s2, { type = "testStart", test = { id = 3, name = "g two", url = furl }, time = 1 })
  notify(s2, { type = "error", testID = 3, error = "boom", time = 2 })
  notify(s1, { type = "testDone", testID = 3, result = "success", skipped = false, hidden = false, time = 3 })
  notify(s2, { type = "testDone", testID = 3, result = "failure", skipped = false, hidden = false, time = 3 })
  rs = P3.discovery.results()
  ok("[51] two concurrent sessions land only in their own scopes (same testID 3 in both)",
    status(ids["one"]) == "passed" and status(ids["two"]) == "failed" and (rs[ids["two"]] or {}).output == "boom", vim.inspect(rs))
  ok("[51] a run's result is published (run.results:changed reached the canonical table)", rs[ids["g"]] ~= nil)
  L.event_terminated[KEY](s1)
  notify(s1, { type = "testStart", test = { id = 9, name = "g three", url = furl }, time = 5 })
  notify(s1, { type = "testDone", testID = 9, result = "success", skipped = false, hidden = false, time = 6 })
  rs = P3.discovery.results()
  ok("[51] events after a session terminated are dropped (three stays running)", status(ids["three"]) == "running")
  notify({ id = 99099, config = { autoRunRunId = "dart-forged-1" } },
    { type = "testDone", testID = 1, result = "failure", skipped = false, hidden = false, time = 1 })
  ok("[51] an event from an unknown session changes nothing", status(ids["three"]) == "running")
  -- a runner that exits non-zero having reported nothing → failed, not skipped
  local s3 = { id = 99003, config = cfgs[3] }
  L.event_exited[KEY](s3, { exitCode = 254 })
  L.event_terminated[KEY](s3)
  rs = P3.discovery.results()
  ok("[51] exit 254 with no reports → failed, with the reason", status(ids["three"]) == "failed"
    and tostring((rs[ids["three"]] or {}).output):find("code=254", 1, true) ~= nil, vim.inspect(rs[ids["three"]]))
  local s4 = { id = 99004, config = cfgs[4] }
  L.event_exited[KEY](s4, { exitCode = 0 })
  L.disconnect[KEY](s4)
  ok("[51] a clean exit with nothing reported → skipped", status(ids["four"]) == "skipped")
  L.event_terminated[KEY](s2)
  local st = require("auto-run.dap.dart_tests")._state()
  ok("[51] every session's state is cleared after it ends", next(st.active) == nil and next(st.pending) == nil, vim.inspect(st))
  -- Lector r1 (PR #16) finding 1: a session that ends with `exited` ALONE
  -- finalises (no terminated / disconnect ever arrives).
  local ex = NEW.capture_dap_run(function() P3.discovery.debug_position(ids["two"]) end)
  local s5 = { id = 99005, config = ex and ex[1] }
  ok("[51] exited-only: the debugged test is running first", status(ids["two"]) == "running")
  L.event_exited[KEY](s5, { exitCode = 2 })
  ok("[51] exited-only: `exited` alone finalises — failed (exit 2, nothing reported)",
    status(ids["two"]) == "failed" and tostring((P3.discovery.results()[ids["two"]] or {}).output):find("code=2", 1, true) ~= nil,
    vim.inspect(P3.discovery.results()[ids["two"]]))
  ok("[51] exited-only: its session state is cleared", next(require("auto-run.dap.dart_tests")._state().active) == nil)
  L.event_terminated[KEY](s5)
  L.disconnect[KEY](s5)
  ok("[51] a terminated / disconnect after exited changes nothing (idempotent)", status(ids["two"]) == "failed")

  -- Lector r1 finding 2: a dap.run that throws leaves no pending run behind.
  local real_run = dap.run
  dap.run = function() error("adapter exploded") end
  local okp2 = P3.discovery.debug_position(ids["three"])
  dap.run = real_run
  ok("[51] dap.run throwing: debug_position itself returned (the launch failed in its callback)", okp2 == true)
  ok("[51] dap.run throwing: the test's running mark is unwound", P3.discovery.results()[ids["three"]] == nil
    or status(ids["three"]) ~= "running", vim.inspect(P3.discovery.results()[ids["three"]]))
  ok("[51] dap.run throwing: no pending run is left", next(require("auto-run.dap.dart_tests")._state().pending) == nil,
    vim.inspect(require("auto-run.dap.dart_tests")._state().pending))

  -- ... and a run whose session never arrives expires on its own timer, with
  -- no later debug needed to sweep it.
  local DT = require("auto-run.dap.dart_tests")
  local prev_exp = DT.EXPIRY_MS
  DT.EXPIRY_MS = 60
  DT.begin(P3.discovery.tree():get(ids["four"]), pkg)
  ok("[51] expiry: begin marks running", status(ids["four"]) == "running")
  wait_for(function() return next(DT._state().pending) == nil end, 2000)
  DT.EXPIRY_MS = prev_exp
  ok("[51] expiry: a run with no session unwinds by itself", P3.discovery.results()[ids["four"]] == nil
    and next(DT._state().pending) == nil, vim.inspect(P3.discovery.results()[ids["four"]]))

  -- a launch that never got a session unwinds its marks
  local rid = require("auto-run.dap.dart_tests").begin(P3.discovery.tree():get(ids["one"]), pkg)
  ok("[51] begin marks running", status(ids["one"]) == "running")
  require("auto-run.dap.dart_tests").abort(rid)
  ok("[51] abort (no session) unwinds the running mark", P3.discovery.results()[ids["one"]] == nil)

  vim.fn.executable = real_executable
  -- real SDK, real nvim-dap: debug one test end to end through the public path
  if HAVE_DART then
    vim.fn.delete(pkg .. "/.dart_tool", "rf")
    local pg = vim.system({ "dart", "pub", "get", "--offline" }, { cwd = pkg, text = true }):wait()
    dart_real = dart_real + 1
    ok("[51][real] pub get", pg.code == 0, pg.stderr)
    local okp, perr = P3.discovery.debug_position(ids["two"])
    ok("[51][real] debug_position starts a real dart debug_adapter --test session", okp == true, tostring(perr))
    wait_for(function()
      local r = P3.discovery.results()[ids["two"]]
      return r and r.status ~= "running"
    end, 120000)
    wait_for(function() return next(require("auto-run.dap.dart_tests")._state().active) == nil end, 30000)
    local r = P3.discovery.results()[ids["two"]]
    dart_real = dart_real + 1
    ok("[51][real] its dart.testNotification events reached the tests' results: passed", r and r.status == "passed", vim.inspect(r))
    dart_real = dart_real + 1
    ok("[51][real] the other tests in the file were not touched by the debugged run",
      P3.discovery.results()[ids["one"]] == nil, vim.inspect(P3.discovery.results()[ids["one"]]))
  end
  dap.adapters.dart = had_dart
  if had_dart == nil then bridge_mod.ensure_dart_adapter(dap) end
  NEW.restore(prev)
end)()

local DART_REAL_MIN = (HAVE_DART and 6 or 0) + (HAVE_FLUTTER and 3 or 0)
ok(("dart real-SDK floor: ran %d, expected %d (dart %s, flutter %s)"):format(dart_real, DART_REAL_MIN,
  HAVE_DART and "on PATH" or "absent", HAVE_FLUTTER and "on PATH" or "absent"), dart_real == DART_REAL_MIN)

-- ── [52] AGENTS.md + the version marker in every .auto-run/ ───────
-- Johno, 2026-10-03: "the AGENTS.md should be copied into each .auto-run
-- folders…", "each .auto-run folder should have a empty text file that
-- indicates .auto-run.nvim version, so when the version updates the agents.md
-- file should be updated as well", "whenever the autorun plugin touches the
-- folder again". ADR 0213 §2.5.
print("\n[52] AGENTS.md, CLAUDE.md and the auto-run.nvim-v<version> marker")
;(function()
  local agents = require("auto-run.store.agents")
  local ver = require("auto-run").version
  local marker = agents.MARKER_PREFIX .. ver
  local prev = worktree.get_active()
  local root = fx .. "/agents52"
  ok("[52] fixture repo", NEW.repo(root))
  agents._reset_for_tests()
  local folder = root .. "/.auto-run"

  store.list()
  ok("[52] reading the store writes nothing", vim.fn.isdirectory(folder) == 0)

  store.add({ name = "a52", kind = "run", runtime = "go", program = "${worktree}" }, { tier = "tracked" })
  local function read(p) local f = io.open(p, "r") if not f then return nil end local t = f:read("*a") f:close() return t end
  local text = read(folder .. "/AGENTS.md")
  ok("[52] the first write creates AGENTS.md (managed header, this version)",
    text and text:sub(1, #agents.MANAGED_HEADER) == agents.MANAGED_HEADER and text:find("v" .. ver, 1, true) ~= nil)
  ok("[52] ... CLAUDE.md pointing at it", tostring(read(folder .. "/CLAUDE.md")):find("[AGENTS.md](AGENTS.md)", 1, true) ~= nil)
  ok("[52] ... and the EMPTY marker " .. marker, vim.fn.filereadable(folder .. "/" .. marker) == 1 and read(folder .. "/" .. marker) == "")
  local missing = {}
  for _, rec in ipairs({ "config", "profile" }) do
    for _, f in ipairs(schema.field_names(rec)) do
      if not text:find("| `" .. f .. "` |", 1, true) then missing[#missing + 1] = rec .. "." .. f end
    end
  end
  ok("[52] every schema field is documented in the rendered file", #missing == 0, table.concat(missing, ", "))
  ok("[52] no placeholder is left unrendered", text:find("{{", 1, true) == nil)
  ok("[52] every registered runtime is listed",
    text:find("| `node` |", 1, true) ~= nil and text:find("| `playwright` |", 1, true) ~= nil and text:find("| `dart` |", 1, true) ~= nil)

  local st1 = vim.uv.fs_stat(folder .. "/AGENTS.md")
  agents._reset_for_tests()
  store.add({ name = "b52", kind = "run", runtime = "go", program = "${worktree}" }, { tier = "tracked" })
  local st2 = vim.uv.fs_stat(folder .. "/AGENTS.md")
  ok("[52] a write at the same version leaves AGENTS.md alone", st1.mtime.nsec == st2.mtime.nsec and st1.mtime.sec == st2.mtime.sec)

  -- an older marker: rewritten, marker replaced, CLAUDE.md (now the user's) kept
  write_file(folder .. "/AGENTS.md", agents.MANAGED_HEADER .. " -->\nold text\n")
  write_file(folder .. "/CLAUDE.md", "my own CLAUDE notes\n")
  os.rename(folder .. "/" .. marker, folder .. "/" .. agents.MARKER_PREFIX .. "0.1.1")
  agents._reset_for_tests()
  store.remove("b52")
  ok("[52] an older marker: the next write (here a remove) rewrites AGENTS.md",
    tostring(read(folder .. "/AGENTS.md")):find("old text", 1, true) == nil)
  ok("[52] ... replaces the marker", vim.fn.filereadable(folder .. "/" .. marker) == 1
    and vim.fn.filereadable(folder .. "/" .. agents.MARKER_PREFIX .. "0.1.1") == 0)
  ok("[52] ... and leaves CLAUDE.md as the user wrote it", read(folder .. "/CLAUDE.md") == "my own CLAUDE notes\n")

  -- a newer marker (another machine): untouched
  os.rename(folder .. "/" .. marker, folder .. "/" .. agents.MARKER_PREFIX .. "9.9.9")
  write_file(folder .. "/AGENTS.md", agents.MANAGED_HEADER .. " -->\nfrom the future\n")
  agents._reset_for_tests()
  store.add({ name = "c52", kind = "run", runtime = "go", program = "${worktree}" }, { tier = "tracked" })
  ok("[52] a newer marker: nothing rewritten (no ping-pong between versions)",
    tostring(read(folder .. "/AGENTS.md")):find("from the future", 1, true) ~= nil
      and vim.fn.filereadable(folder .. "/" .. marker) == 0)
  ok("[52] ... doctor says so", agents.status(folder).state:find("newer", 1, true) ~= nil, agents.status(folder).state)

  -- a hand-written AGENTS.md with no marker: moved to AGENTS.local.md, never lost
  os.remove(folder .. "/" .. agents.MARKER_PREFIX .. "9.9.9")
  write_file(folder .. "/AGENTS.md", "# our own notes\n")
  agents._reset_for_tests()
  store.remove("c52")
  ok("[52] a hand-written AGENTS.md is moved to AGENTS.local.md", read(folder .. "/AGENTS.local.md") == "# our own notes\n")
  ok("[52] ... and the managed one written", tostring(read(folder .. "/AGENTS.md")):sub(1, #agents.MANAGED_HEADER) == agents.MANAGED_HEADER)
  -- both exist and the marker is old: nothing is overwritten
  os.rename(folder .. "/" .. marker, folder .. "/" .. agents.MARKER_PREFIX .. "0.0.1")
  write_file(folder .. "/AGENTS.md", "# hand-written again\n")
  agents._reset_for_tests()
  store.remove("a52")
  ok("[52] hand-written AGENTS.md + AGENTS.local.md: neither is overwritten",
    read(folder .. "/AGENTS.md") == "# hand-written again\n" and read(folder .. "/AGENTS.local.md") == "# our own notes\n")
  ok("[52] ... and doctor reports the conflict", agents.status(folder).state:find("conflict", 1, true) ~= nil, agents.status(folder).state)

  -- Lector r1 (PR #16) finding 3: editing an existing env file in .auto-run/
  -- is a write into the folder, so an old marker refreshes on it.
  os.remove(folder .. "/AGENTS.md")
  os.remove(folder .. "/AGENTS.local.md")
  for _, n in ipairs(vim.fn.readdir(folder) or {}) do
    if n:find(agents.MARKER_PREFIX, 1, true) == 1 then os.remove(folder .. "/" .. n) end
  end
  write_file(folder .. "/.env", "A=1\n")
  write_file(folder .. "/" .. agents.MARKER_PREFIX .. "0.1.2", "")
  write_file(folder .. "/AGENTS.md", agents.MANAGED_HEADER .. " -->\nstale\n")
  local function env_edit_refreshes(label, fn)
    agents._reset_for_tests()
    os.rename(folder .. "/" .. marker, folder .. "/" .. agents.MARKER_PREFIX .. "0.1.2")
    write_file(folder .. "/AGENTS.md", agents.MANAGED_HEADER .. " -->\nstale\n")
    local okv, verr = fn()
    ok("[52] " .. label .. " on .auto-run/.env refreshes AGENTS.md and the marker",
      okv and tostring(read(folder .. "/AGENTS.md")):find("stale", 1, true) == nil
        and vim.fn.filereadable(folder .. "/" .. marker) == 1
        and vim.fn.filereadable(folder .. "/" .. agents.MARKER_PREFIX .. "0.1.2") == 0, tostring(verr))
  end
  -- first refresh needs the current marker to exist for the rename helper
  agents._reset_for_tests()
  local okf = envmod.add_var(folder .. "/.env", "B", "2")
  ok("[52] add_var on .auto-run/.env refreshes AGENTS.md (old marker → current)",
    okf and tostring(read(folder .. "/AGENTS.md")):find("stale", 1, true) == nil and vim.fn.filereadable(folder .. "/" .. marker) == 1)
  env_edit_refreshes("update_var", function() return envmod.update_var(folder .. "/.env", "B", "3") end)
  env_edit_refreshes("remove_var", function() return envmod.remove_var(folder .. "/.env", "B") end)

  -- the bare-repo layout: the container's shared .auto-run gets its own copy
  worktree.set_active(container .. "/main")
  store_paths.invalidate()
  agents._reset_for_tests()
  -- Earlier cells' state writes may already have stamped it: start clean.
  vim.fn.delete(container .. "/.auto-run/AGENTS.md")
  for _, n in ipairs(vim.fn.readdir(container .. "/.auto-run") or {}) do
    if n:find(agents.MARKER_PREFIX, 1, true) == 1 then os.remove(container .. "/.auto-run/" .. n) end
  end
  store.write_state(store.read_state())
  ok("[52] the container-level shared .auto-run (bare + worktrees) gets AGENTS.md on its first write",
    vim.fn.filereadable(container .. "/.auto-run/AGENTS.md") == 1 and vim.fn.filereadable(container .. "/.auto-run/" .. marker) == 1)
  NEW.restore(prev)
end)()

-- ── summary ─────────────────────────────────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
os.exit(0)