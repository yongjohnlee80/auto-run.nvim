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
for _, dep in ipairs({ "plenary.nvim" }) do
  local p = LAZY .. "/" .. dep
  if vim.fn.isdirectory(p) == 1 then vim.opt.rtp:prepend(p) end
end

-- State isolation FIRST — before ANY setup() claims a namespace
-- ([[auto-family-state-ownership]] rule #7).
require("auto-core.state").configure({
  persist_dir = vim.fn.tempname() .. "_state-isolation",
})

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
ok("materialized content is KEY=VALUE lines",
  table.concat(vim.fn.readfile(mat_path), "\n") == "KEY_A=va\nKEY_B=vb")
local bad_id = envmod.materialize("../escape", { A = "1" })
ok("path-unsafe run ids refused", bad_id == nil)

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
ok("register_all registers all 10 Phase 1 verbs (idempotent)",
  #reg.registered == 10 and #reg.skipped == 0, vim.inspect(reg))
local expected_verbs = {
  "run.add", "run.import", "run.list", "run.profiles_list", "run.remove",
  "run.set_dir", "run.show", "run.status", "run.update", "run.validate",
}
ok("verb roster matches the Phase 1 read/mutate tier exactly",
  vim.deep_equal(reg.registered, expected_verbs), vim.inspect(reg.registered))
local no_exec = true
for _, v in ipairs({ "run.start", "run.test_run", "run.debug_start", "run.stop" }) do
  if commands.get(v) ~= nil then no_exec = false end
end
ok("NO execution verbs registered in Phase 1", no_exec)
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
ok("run.status Phase 1: jobs always empty",
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

-- ── summary ─────────────────────────────────────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
os.exit(0)