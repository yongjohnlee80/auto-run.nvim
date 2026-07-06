-- auto-run.nvim — smoke test driver (ADR-0048 Phase 1)
--
-- Run headless:
--   nvim --headless -u tests/smoke.lua -c 'qa!'
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
--   [33] keymaps — gobugger→auto-run remap audit (ADR §10, programmatic)
--   [34] doctor — gobugger parity rows + `--fix` worktree repair
--   [35] keymaps — rt/rf/dt discovery-position routing + fallback
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

local SEVEN_TOPICS = {
  "run.config:changed", "run.job:started", "run.job:exited",
  "run.results:changed", "run.session:changed",
  "run.breakpoints:changed", "run.discovery:changed",
}
local all_registered = true
for _, topic in ipairs(SEVEN_TOPICS) do
  local spec = core.events.topic_spec(topic)
  if not (spec and spec.registered_by == "auto-run.nvim") then
    all_registered = false
    ok("topic registered: " .. topic, false, vim.inspect(spec))
  end
end
ok("all seven run.* topics registered by auto-run.nvim", all_registered)

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

-- ── [9] mailbox verbs — run.* envelopes ─────────────────────────
print("\n[9] mailbox — run.* verb registration + envelope contracts")
local commands = require("auto-core.mailbox.commands")
local run_cmds = require("auto-run.mailbox.commands")

local reg = run_cmds.register_all()
ok("register_all registers all 17 verbs (idempotent)",
  #reg.registered == 17 and #reg.skipped == 0, vim.inspect(reg))
local expected_verbs = {
  "run.add", "run.debug_start", "run.import", "run.jobs", "run.list",
  "run.profiles_list", "run.remove", "run.results", "run.set_dir",
  "run.show", "run.start", "run.status", "run.stop", "run.test_run",
  "run.tests_list", "run.update", "run.validate",
}
ok("verb roster matches the Phase 1+2+3 tiers exactly",
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
ok(":AutoRun validate runs clean", pcall(vim.cmd, "AutoRun validate"))

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
  store.add({ name = "sleeper", kind = "run", program = "sh",
    args = { "-c", "sleep 30" } }, { tier = "shared" })
  exited_ev = nil
  local sleeper = exec.start("sleeper")
  ok("long-running job starts", sleeper ~= nil and sleeper.pid ~= nil)
  local stop_ok, stop_err = exec.stop(sleeper.id)
  ok("stop() signals a job we started", stop_ok == true, tostring(stop_err))
  local sdone = wait_for(function() return exited_ev end)
  ok("stopped job exits by signal",
    sdone ~= nil and (sdone.signal == 15 or (sdone.code or 0) ~= 0),
    vim.inspect(sdone))
  local ghost_ok, ghost_err = exec.stop("r00000000-000000-9999")
  ok("stop() on an unknown id is not-found",
    ghost_ok == nil and tostring(ghost_err):find("not found", 1, true) ~= nil,
    tostring(ghost_err))

  -- No default timeout: a spawned job spec without timeout_ms passes
  -- none to vim.system (observable only as absence — the sleeper ran
  -- until signalled, not reaped by a default timeout).
  ok("no default timeout (sleeper lived until stop)", sdone ~= nil)

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

  -- default_keymaps: §10 table registered with desc strings.
  auto_run.default_keymaps()
  local descs = {}
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.desc then descs[m.desc] = true end
  end
  local expected_descs = {
    "Run: Pick Config & Run", "Run: Run Last", "Run: Nearest Test",
    "Run: Current Test File", "Run: Pick Env Profile for Next Run",
    "Run: New Run Config (scaffold)",
    "Debug: Toggle Breakpoint", "Debug: Conditional Breakpoint",
    "Debug: Clear Breakpoints", "Debug: Continue / Start",
    "Debug: Nearest Test", "Debug: Entry Point (pick)",
    "Debug: Attach to Remote dlv Server", "Debug: Terminate",
    "Debug: Restart", "Debug: Doctor",
    "Run: Continue / Start (dap)", "Run: Step Over (dap)",
    "Run: Step Into (dap)", "Run: Step Out (dap)",
  }
  local missing = {}
  for _, d in ipairs(expected_descs) do
    if not descs[d] then missing[#missing + 1] = d end
  end
  ok("§10 keymap table registered (desc on everything)",
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
  ok(":AutoRun jobs runs clean", pcall(vim.cmd, "AutoRun jobs"))
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
  ok("builtin roster is go + jest (registration order)",
    vim.deep_equal(names, { "go", "jest" }), vim.inspect(names))

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
  local dbg2, dbg2_err = P3.discovery.debug_position(calc_test .. "::TestFail")
  ok("debug_position degrades structured without dap-go",
    dbg2 == nil and tostring(dbg2_err):find("dap%-go") ~= nil
      or (dbg2 == nil and tostring(dbg2_err):find("not installed", 1, true) ~= nil),
    tostring(dbg2_err))

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
  local out = vim.api.nvim_exec2("AutoRun tests", { output = true }).output
  ok(":AutoRun tests renders the position tree",
    out:find("auto-run tests", 1, true) ~= nil
      and out:find("math", 1, true) ~= nil
      and out:find("adds", 1, true) ~= nil, out:sub(1, 200))
  ok(":AutoRun tests shows result glyphs",
    out:find("✗", 1, true) ~= nil and out:find("✓", 1, true) ~= nil)

  local scan_done
  local h_ev = core.events.subscribe("run.discovery:changed",
    function(p) scan_done = p end)
  ok(":AutoRun scan runs clean", pcall(vim.cmd, "AutoRun scan"))
  wait_for(function() return scan_done end)
  ok(":AutoRun scan completes and republishes discovery",
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
  ok("real sample readable (gate evidence source)", content ~= nil, sample)
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

-- ── [33] keymaps — gobugger→auto-run remap audit (ADR §10) ──────
print("\n[33] keymaps — gobugger→auto-run remap audit (programmatic)")
do
  -- gobugger's ACTUAL default_keymaps list is the source of truth:
  -- capture every lhs it registers (sibling worktree preferred, lazy
  -- install fallback) and assert each one is accounted for by the
  -- ADR §10 disposition table — kept, remapped, or dropped-to-command.
  local gob_root = workspace .. "/gobugger.nvim/main"
  if vim.fn.isdirectory(gob_root) == 0 then gob_root = LAZY .. "/gobugger.nvim" end
  ok("gobugger available for the audit probe",
    vim.fn.isdirectory(gob_root) == 1, gob_root)
  vim.opt.rtp:prepend(gob_root)

  -- Stub the optional dap deps so EVERY dep-gated binding registers
  -- on both sides (restored below).
  local saved_dv, saved_dg = package.loaded["dap-view"], package.loaded["dap-go"]
  package.loaded["dap-view"] = {
    toggle = function() end, add_expr = function() end, eval = function() end,
  }
  package.loaded["dap-go"] = { debug_test = function() end, setup = function() end }

  local gob_lhs = {}
  local real_set = vim.keymap.set
  vim.keymap.set = function(_, lhs, _, _)  -- capture-only: never binds
    gob_lhs[#gob_lhs + 1] = lhs
  end
  local okg, gerr = pcall(function() require("gobugger").default_keymaps() end)
  vim.keymap.set = real_set
  ok("gobugger default_keymaps probe ran", okg, tostring(gerr))
  ok("probe captured the full gobugger surface (24 bindings)",
    #gob_lhs == 24, vim.inspect(gob_lhs))

  -- ADR §10 disposition — every gobugger lhs maps here.
  local REMAP = {  -- gobugger lhs → auto-run lhs (kept / renamed)
    ["<F9>"] = "<F9>", ["<F8>"] = "<F8>", ["<F7>"] = "<F7>", ["<F10>"] = "<F10>",
    ["<leader>db"] = "<leader>db", ["<leader>dB"] = "<leader>dB",
    ["<leader>dC"] = "<leader>dC", ["<leader>dc"] = "<leader>dc",
    ["<leader>dr"] = "<leader>rl",   -- run last → the run namespace
    ["<leader>dq"] = "<leader>dq", ["<leader>dR"] = "<leader>dR",
    ["<leader>dv"] = "<leader>dv", ["<leader>dw"] = "<leader>dw",
    ["<leader>de"] = "<leader>de",
    ["<leader>da"] = "<leader>da", ["<leader>dA"] = "<leader>dA",
    ["<leader>dt"] = "<leader>dt", ["<leader>dm"] = "<leader>dm",
    ["<leader>dM"] = "<leader>rc",   -- scaffold keys merged into rc
    ["<leader>dN"] = "<leader>rc",
    ["<leader>dD"] = "<leader>dD",
  }
  local DROPPED = {  -- moved to the command surface per §10
    ["<leader>dL"] = "(store auto-reloads; :AutoRun list)",
    ["<leader>dE"] = ":AutoRun last-error",
    ["<leader>dF"] = ":AutoRun doctor --fix",
  }

  -- Register auto-run's set with the stubs live so the dep-gated
  -- bindings (da / dv / dw / de) exist for the assertion.
  auto_run.default_keymaps()

  local missing, unaccounted = {}, {}
  for _, lhs in ipairs(gob_lhs) do
    local target = REMAP[lhs]
    if target then
      local m = vim.fn.maparg(target, "n", false, true)
      local bound = type(m) == "table" and (m.callback ~= nil or (m.rhs or "") ~= "")
      if not bound then missing[#missing + 1] = lhs .. " → " .. target end
    elseif DROPPED[lhs] == nil then
      unaccounted[#unaccounted + 1] = lhs
    end
  end
  ok("every KEEP-listed gobugger lhs is registered by auto-run",
    #missing == 0, vim.inspect(missing))
  ok("every gobugger binding is accounted for (keep/remap/drop)",
    #unaccounted == 0, vim.inspect(unaccounted))

  -- The dropped bindings' replacement command surfaces exist.
  local le_out = vim.api.nvim_exec2("AutoRun last-error", { output = true }).output
  ok("dE replacement — :AutoRun last-error responds",
    le_out:find("auto%-run") ~= nil, le_out)
  ok("dF replacement — doctor completion offers --fix",
    contains(vim.fn.getcompletion("AutoRun doctor ", "cmdline"), "--fix"))

  -- Spot-check the remapped targets carry auto-run descs (not stale
  -- gobugger bindings that happened to share the lhs).
  local rl = vim.fn.maparg("<leader>rl", "n", false, true)
  local rc = vim.fn.maparg("<leader>rc", "n", false, true)
  ok("dr → <leader>rl is auto-run's Run Last",
    type(rl) == "table" and rl.desc == "Run: Run Last", vim.inspect(rl.desc))
  ok("dM/dN → <leader>rc is auto-run's scaffold",
    type(rc) == "table" and rc.desc == "Run: New Run Config (scaffold)")

  package.loaded["dap-view"] = saved_dv
  package.loaded["dap-go"] = saved_dg
end

-- ── [34] doctor — gobugger parity rows + --fix repair ───────────
print("\n[34] doctor — gobugger parity rows + --fix worktree repair")
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
end

-- ── [35] keymaps — rt/rf/dt discovery-position routing ──────────
print("\n[35] keymaps — rt/rf/dt discovery-position routing + fallback")
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
  vim.cmd.edit(vim.fn.fnameescape(calc_test))
  local sub_line = line_of('t.Run("sub one"')
  vim.api.nvim_win_set_cursor(0, { sub_line, 0 })
  local ok_dt, dt_err = pcall(cb_of("dt"))
  ok("<leader>dt routes the nearest go test through debug_position",
    ok_dt and captured ~= nil, tostring(dt_err))
  ok("dt jumps the cursor to the resolved position",
    vim.api.nvim_win_get_cursor(0)[1] == sub_line
      and vim.api.nvim_buf_get_name(0) == calc_test)
  ok("dt merges the repo's kind=test config into the payload",
    captured ~= nil and captured.buildFlags == "-count=1", vim.inspect(captured))

  -- dt fallback: unclaimed buffer → Phase 2 pick + debug_test.
  captured = nil
  vim.cmd.edit(vim.fn.fnameescape(gofix .. "/calc/calc.go"))
  local ok_dtf, dtf_err = pcall(cb_of("dt"))
  ok("dt on an unclaimed buffer falls back to the config path",
    ok_dtf and captured ~= nil and captured.buildFlags == "-count=1",
    tostring(dtf_err) .. " " .. vim.inspect(captured))
  package.loaded["dap-go"] = saved_dg
end

-- ── summary ─────────────────────────────────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
os.exit(0)