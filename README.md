# auto-run.nvim

Unified run-config / test / debug plugin for the auto-family
(ADR-0048). Manages run configurations, layered env profiles, test
discovery/execution, and DAP orchestration behind one canonical
per-repo store. Supersedes gobugger.nvim at feature parity.

> **On the `gobugger` references throughout this repo:** gobugger.nvim was
> **replaced by auto-run and no longer exists** (ADR-0048 Phase 4). Every
> remaining mention — "gobugger parity", "port", `[provenance: gobugger dD]` —
> records **where a behaviour came from**, never a runtime dependency: nothing
> in `lua/` loads, requires or probes gobugger. The one thing that genuinely
> did depend on it — the smoke suite's gobugger *parity gate*, which compared
> auto-run's keymaps against gobugger's live `default_keymaps()` — was pruned
> when gobugger was deleted, because it had nothing left to compare against.

## Status

Phases 1–3 (store + env engine, execution + DAP, test discovery +
adapters) — under active development. The auto-finder tests/debug
views (the other half of Phase 3) live in auto-finder.nvim. See the
accepted ADR for the full design:
`$AUTO_AGENTS_KB_ROOT/shared/adrs/0048-auto-run-unified-run-test-debug-plugin.md`.

## Store

Two tiers per repo:

- **Tracked** — `<worktree>/.auto-run/{configs,profiles}/*.json`,
  committed with the code.
- **Shared-local** — `<container>/.auto-run/` (linked-worktree
  layouts) or `<repo>/.auto-run/local/` (plain repos): personal
  configs, overrides, breakpoints, session state. Never in git.

Strict JSON, one file per config. Resolution through
`require("auto-run.store").resolve_run_dirs()` — the only path
authority.

## Module layout (Phases 1–3)

```
lua/auto-run/
├── init.lua             -- setup(), topic registration, public facade
├── config.lua           -- plugin opts (not run configs)
├── log.lua              -- auto-core.log wrapper (silent-INFO degrade)
├── store/
│   ├── init.lua         -- CRUD + 7-layer merge assembly + validate/status
│   ├── paths.lua        -- resolve_run_dirs() + set_dir override registry
│   ├── schema.lua       -- config/profile validation
│   └── merge.lua        -- pure merge engine (field rules, tombstones, extends)
├── env/init.lua         -- substitution + profile pipeline + 0600 materialization
├── import/init.lua      -- launch.json JSONC importer + read-through shims
├── exec/
│   ├── init.lua         -- start/test_run/stop/list, pick memory, run_last
│   ├── job.lua          -- vim.system engine, per-run dirs, job table, events
│   └── strategies.lua   -- run|term|dap resolution + terminal provider probe
├── dap/
│   ├── init.lua         -- provider registration, translation, debug_test parity,
│   │                       attach/attach_remote, dap-view + winfixbuf + error capture
│   └── breakpoints.lua  -- §9 persistence + reconcile sweep + restore
├── adapters/
│   ├── init.lua         -- AutoRunAdapter interface + register_adapter() registry
│   ├── go.lua           -- go test -json adapter (treesitter discovery)
│   └── jest.lua         -- jest --json adapter (treesitter discovery)
├── discovery/init.lua   -- position tree, bounded scans, aggregation, run/debug
├── keymaps.lua          -- default_keymaps() (§10 table)
└── mailbox/commands.lua -- run.* verb SPECS + register_all()

plugin/auto-run.lua      -- :AutoRun {list|show|validate|import|doctor|set-dir
                         --          |run|debug|test|stop|jobs|last-error|tests|scan|env}
tests/smoke.lua          -- nvim -n -i NONE --headless -u tests/smoke.lua -c 'qa!'
```

The auto-finder `tests`/`debug` views (the render surface over this
discovery API) land in auto-finder.nvim per the ADR rollout table.

## Usage

```lua
require("auto-run").setup()
require("auto-run").default_keymaps()   -- optional: the §10 layout below
```

- `:AutoRun run [name]` / `:AutoRun test [name]` / `:AutoRun debug
  [name]` — launch a config (picker with per-repo pick memory when
  the name is omitted).
- `:AutoRun jobs` / `:AutoRun stop <run-id>` — session job inventory
  and control. Stop only ever signals jobs auto-run started, and it
  signals the **process group**, not the handle (see below).
- `:AutoRun tests` / `:AutoRun scan` — render the discovered position
  tree (status glyphs from the last results) / run a bounded full
  scan of the active worktree.
- `:AutoRun doctor` — resolver output, git/worktree health (project
  root + marker, anchor `.git` kind incl. gitfile-target state,
  `git status`, common dir, go module root), configs per kind with
  the remembered session pick, test-adapter roots + discovery
  snapshot, dap-adapter health, breakpoint-store stats, live jobs.
- `:AutoRun doctor --fix` — `git worktree repair` from the repo's
  common dir (gobugger `fix_worktree` parity; survives a broken
  worktree gitfile via the container walk). Interactive-only —
  mutating, so never exposed as a mailbox verb.
- `:AutoRun last-error` — replay the last failed-start dap capture in
  a scratch buffer.
- `:AutoRun import` — one-shot launch.json migration into the
  tracked tier (`origin = "launch.json"` provenance).
- `:AutoRun env [select <path>|clear]` — list/manage the per-repo
  selected env file (§4.2 below); `*` marks the selection.
- Mailbox verbs register automatically when the auto-core mailbox
  surface is present. `run.start` / `run.test_run` /
  `run.debug_start` are gated behind the `run.exec` trust capability
  (enabled interactively in the host — never via mailbox);
  `run.stop` is ungated. `run.tests_list` / `run.results` expose the
  position tree and the last per-position results read-only;
  `run.test_run` accepts either a config `name` or a discovered
  `position` id. `run.env_list` / `run.env_select` manage the §4.2
  env-file selection (ungated — selection is data, not execution)
  and only ever carry file paths + KEY names, never values.

> **Writing a restrictive `run.exec` allowlist? The subject is not always a
> config name.** Each gated handler calls
> `trust.check("run.exec", <subject>)`, and the subject is whatever
> identifies the thing being run:
>
> | call | subject passed to the gate |
> | --- | --- |
> | `run.start` / `run.debug_start` | the config **name** (`api-server`) |
> | `run.test_run` with `name` | the config **name** |
> | `run.test_run` with `position` | the **position id** (`path::ns::name`) |
>
> A discovered position id is *path-shaped* — e.g.
> `internal/api/user_test.go::TestUser::rejects_empty`. So an allowlist
> written only as config-name patterns silently matches nothing for
> positional test runs, and every such run is refused. Restrictive
> allowlists need path-shaped patterns too. Trust is only ever granted
> interactively in the host; no mailbox handler calls `trust.set`, so an
> agent can never bootstrap its own execution trust (ADR-0035 §4.5,
> ADR-0048 §11).

### Configuring test runs (go and jest)

Test discovery needs no configuration — `:AutoRun tests` finds positions as
soon as an adapter recognises the project. A **`kind=test` config is only
needed when a run needs something extra**: environment variables, an env
file, or (go) build flags.

**Which config a run uses.** An adapter picks the first `kind=test` config
whose `runtime` matches its own name; a config with **no** `runtime` is
generic and applies to any adapter. So one repo can serve both:

```jsonc
// .auto-run/configs/jest-tests.json          → jest runs only
{ "name": "jest-tests", "kind": "test", "runtime": "jest",
  "env": { "NODE_ENV": "test", "TZ": "UTC" },
  "env_files": ["${worktree}/.env.test"] }

// .auto-run/configs/go-tests.json            → go runs only
{ "name": "go-tests", "kind": "test", "runtime": "go",
  "build_flags": "-count=1 -race",
  "env_files": ["${worktree}/.env.test"] }
```

Create them with `:AutoRun` scaffolding (`<leader>rc`), by hand under
`.auto-run/configs/`, or by importing a `launch.json` (`:AutoRun import` —
its `env` and `envFile` land as `env` and `env_files`).

**Environment.** Both adapters compose identically, so anything that works
for go works for jest:

| field | what it is |
| --- | --- |
| `env` | inline `KEY: value` map — no file needed |
| `env_files` | list of env files, applied in order |
| selected env file | `:AutoRun env select <path>`, per-repo (§4.2) |

Precedence, lowest to highest: config/profile `env_files` → the selected env
file (the highest-precedence *file*) → secret manifests → `command_env` /
`runtime_env` → config-level `env`. So a key set inline in `env` wins over
the same key in any file, including the selected one (§4.2). The file need
**not** be called `.env` — `env_files` takes any path.

Two things worth knowing before your first config:

- **Anchor `env_files` with `${worktree}`.** A bare relative path
  (`"api.env"`) resolves against the process CWD, not the repo, so it will
  usually fail to open.
- **A missing env file fails the run**, loudly, rather than running your
  tests with a silently incomplete environment.

**Jest specifics.** The adapter needs a **project-local** jest binary — it
probes `node_modules/.bin/jest` from the position's package upward to the
worktree, so both plain repos and hoisted monorepos work; there is no global
fallback by design. Roots are per `package.json`, so a monorepo's packages
are discovered and run independently.

**Verifying.** `:AutoRun doctor` lists configs per kind (with the remembered
session pick) and the test-adapter roots + discovery snapshot — the quickest
way to confirm a config is being seen and which one a run will pick.

### Execution model

Every launch: 7-layer merge → uniform substitution → env composition
(Phase 1 pipeline, incl. trust-gated `command_env`) → strategy:

| Strategy | Default for | Behavior |
|---|---|---|
| `run`  | `kind=run`, plain `kind=test` | background `vim.system` job; `stdout`/`stderr`/`result.json` under `stdpath("cache")/auto-run/runs/<run-id>/` |
| `dap`  | `kind=debug`, debug-test | nvim-dap session via the `auto-run` config provider; go first-class |
| `term` | opt-in | terminal provider: registered fn → `auto-agents.term` probe → `:split` + `jobstart(term=true)` fallback |

`test_run` drives **kind=test configs** (plain `go test` on the
configured package, or dap-go's `debug_test` with the config's
buildFlags/env merged in) — the Phase 2 form. Position-level test
execution goes through the discovery model below.

Jobs are started **detached** so that `stop` can signal the whole process
group with `kill(-pid, sig)`. Both halves are load-bearing and neither
works alone — measured on the two-process shape `sh -c "sleep 30; :"`:

| | outcome |
|---|---|
| no `detach` + `handle:kill` | **no exit event** — the defect: the job stays in the inventory forever |
| `detach` + `handle:kill` | **no exit event** — detach alone is not the fix |
| `detach` + `kill(-pid)` | exit event, `code=0 signal=15` |

`handle:kill` remains the fallback for a record with no pid, or a platform
without process groups. That is the old behaviour, so the worst case is
what shipped before rather than a new failure mode.

## Test discovery (ADR §7)

### Discovery model

Discovery anchors at the **active worktree**
(`resolve_run_dirs().root` — never `getcwd`, never the workspace
root) and builds one position tree per worktree:

```
dir → file → namespace → test        ids: path  |  path::ns::name
```

- **O(1) lookup**: every node lives in the tree's flat `_nodes` map
  (`tree:get(id)`); `discovery.tree_plain()` is the serializable
  projection (the `run.tests_list` payload).
- **Scope**: the walk prunes hidden dirs, `list_child_repos()`'s
  known child repos, and — independently — any subdirectory carrying
  a `.git` entry (dir or gitfile), so unseen nested repos never leak
  into the tree. Adapter `filter_dir` drops `node_modules`, `vendor`,
  etc.
- **Lazy by default** (neotest pitfall #1): open test buffers are
  parsed on `BufReadPost` and re-parsed on `BufWritePost`
  (`discovery.open_buffers = false` disables). The full worktree
  needs an explicit scan: `:AutoRun scan`, the tests panel's `S`, or
  `discovery.scan(opts, cb)`.
- **Bounded, cancelable scans**: hard caps
  (`discovery.max_files = 5000` candidate files,
  `discovery.max_roots = 200` adapter roots) abort with a structured
  cap report (`{ status = "capped", cap, limit, seen, hint }`) plus a
  warn log — never a silent degrade. A second `scan()`, a
  worktree/workspace switch, or `discovery.cancel()` supersedes the
  in-flight walk. Re-scans skip unchanged files via a per-file mtime
  cache.
- **Execution**: `discovery.run_position(id, opts)` builds specs via
  the position's adapter (falling back to finer decomposition —
  dir → files → tests — when the adapter declines) and routes them
  through the exec job engine; machine output lands in the per-run
  dir and parses back to position ids. `discovery.debug_position(id)`
  jumps to the test and reuses the Phase 2 `dap.debug_test` path (go
  only for now). Results feed `run.results:changed`; container
  statuses aggregate upward (running > failed > passed > skipped) and
  unreported in-scope tests fill as `skipped` (or `failed` when the
  runner died without reporting anything).

### Adapter interface

Adapters are plain-function tables (no subprocess RPC in v1),
registered via `require("auto-run.adapters").register_adapter(t)`:

```lua
---@class AutoRunAdapter
---@field name string                    -- "go" | "jest" | ...
---@field root fun(dir): string|nil      -- project root (go.work/go.mod; package.json)
---@field filter_dir fun(name, rel_path, root): boolean|nil  -- optional walk veto
---@field is_test_file fun(path): boolean
---@field discover_positions fun(path): position|nil, err?   -- treesitter, injections disabled
---@field build_spec fun(args): spec|nil, err?  -- nil,nil → core decomposes finer
---@field results fun(spec, exit, tree): table<pos_id, result>
```

`discover_positions` returns a `type="file"` position with nested
namespace/test children (the core assigns ids and dir hierarchy).
`build_spec` receives `{ position, tree, root, run_id, run_dir }` and
returns `{ cmd, cwd?, env?, context? }`; `results` receives the exit
record (`{ code, signal, stdout_file, run_dir }`) and maps the
runner's machine output back to position ids. Baseline adapters:

- **go** — `func Test*`/`Example*` (minus `TestMain`) + nested
  `t.Run` subtests; nearest `go.mod` promoted to an enclosing
  `go.work` (memoized primary-root cache); `go test -json` with
  `^`-anchored slash-split `-run` regexes / file alternations /
  `./rel/...` dir patterns; a kind=test config's `build_flags` +
  composed env apply to every run.
- **jest** — `describe`/`it`/`test` + aliases and
  `.only`/`.skip`/`.todo` modifiers over js/jsx/ts/tsx; one root per
  `package.json`; project-local `node_modules/.bin/jest` (hoisted
  parents probed up to the worktree) with
  `--json --outputFile=<per-run file>` and regex-escaped
  ancestor-joined `--testNamePattern`s; a kind=test config's composed
  env applies to every run, exactly as for go.

#### One env convention for every language

A `kind=test` config supplies the environment for test runs, and both
baseline adapters resolve it through the **same** owner
(`auto-run.adapters.config`) and the same Phase 1 pipeline —
`store.get` → `substitute_deep` → `env.compose`. So `env`, `env_files`,
the §4.2 selected env file and secret manifests behave identically
whether you are running `go test` or `jest`.

A config claims an adapter by `runtime`: `runtime = "go"` applies to go
runs, `runtime = "jest"` to jest runs, and a config with **no**
`runtime` is generic and applies to whichever adapter asks.

```jsonc
// .auto-run/configs/jest-tests.json
{
  "name": "jest-tests",
  "kind": "test",
  "runtime": "jest",
  "env": { "NODE_ENV": "test" },
  "env_files": ["${worktree}/.env.test"]
}
```

This mirrors VS Code, which auto-run already interoperates with: a
`launch.json` entry's `env` map and its `envFile` path are imported to
`env` and `env_files` respectively (see *Launch-config selection &
launch.json interop*), and VS Code applies those same two fields
uniformly across its Go and Node/Jest debug configurations. The env
source is therefore **not** tied to a file named `.env` — anything
`env_files` can reference works, and inline `env` needs no file at all.

Anchor `env_files` with `${worktree}` (or another substitution token):
a bare relative path resolves against the process CWD, not the repo. A
referenced env file that cannot be read **fails the run** rather than
running the tests with a silently incomplete environment.

### Env materialization lifecycle (ADR §4.1)

Env is re-composed per launch and only leaves the process as a `0600`
file under `stdpath("cache")/auto-run/env/` when the `term` strategy
needs it. Composed keys must be valid environment-variable names
(`[A-Za-z_][A-Za-z0-9_]*` — anything else fails composition with
`invalid_env_key`), and values in the materialized file are
single-quoted (`'\''`-escaped) so sourcing the file can never execute
value text as shell code. The `run`/`dap` strategies pass env
programmatically (unquoted table) and never touch a file unless
materialized for `term`.

File retention:

- **`run` strategy** — the per-run env file (when any) is deleted on
  job exit.
- **`term` strategy** — deleted immediately when the provider refuses
  the launch; accepted launches hand the provider a `spec.on_exit`
  cleanup hook to call when the terminal session ends (the builtin
  fallback wires it to the terminal job's exit). A provider that
  accepts but never signals exit leaves the file to the startup sweep
  (`env.sweep_max_age_hours`, default 24h).
- **`command_env` entries** run with a per-entry budget of
  `env.command_timeout_ms` (default 10000 ms): a timeout fails
  composition with `command_env_timeout` for required entries and
  warns + skips entries with `required = false`.
  A timeout is detected two ways, because `SystemObj:wait()` returns
  `state.result` and that is **`nil` on the timeout path** — the only route
  to `nil` is "we stopped waiting after killing it", which is what a
  timeout is. So `res == nil` maps onto the timeout branch alongside
  `code == 124 and signal is 15 or 9`. Reading `res.code` first was an
  uncaught error on an interactive or mailbox launch, in place of the
  structured `command_env_timeout` the design calls for.

### Env-file selection (ADR §4.2, r5)

A per-repo **selected env file** applies to every subsequent launch
as the highest-precedence `env_files` entry — it wins over every
config/profile env file, while the later §3.1 stages (secret
manifests, `command_env`, `runtime_env`, config-level `env`) still
win last. Every launch path (interactive, mailbox, debug-test,
discovery positions) composes through the same pipeline, so the
selection reaches all of them; a selection whose file vanished fails
composition (`env_file_missing`), never a silent skip.

```
:AutoRun env                  " list candidates ('*' = selected)
:AutoRun env select <path>    " select (file must exist; tab-completes)
:AutoRun env clear            " clear the selection
```

Candidates are the env files referenced by configs/profiles plus a
bounded **non-recursive** glob over **both the worktree root and the
bare-repo container**, each scanned at its root plus `.config/` and
`.vscode/` (`{.env,.env.*,*.env}`) — in a linked-worktree layout the
shared editor config usually lives at the container. The selection
persists in the
shared-local tier's `state.json`, worktree-relative when the file
sits under the worktree root — switching worktrees within the same
container re-anchors the pick to the new worktree's copy. `:AutoRun
doctor` shows a `selected env` row.

Lua surface (consumed by the auto-finder Env section):
`env.files_list()`, `env.get_selected()` /
`env.set_selected(path|nil)`, `env.read_file(path)` (entries with
line numbers — panel display only; callers must never log values),
and `env.update_var(path, key, value)` / `env.add_var(path, key,
value)` (atomic rewrites preserving comments, blank lines, entry
order and each entry's quoting style; structured
`not_found`/`already_exists`/`invalid_key`/`invalid_value` errors).
Changes publish `run.env:changed` carrying the path + KEY name only —
env **values** never enter logs, events, or mailbox responses
(`run.env_list` returns file paths + sorted key names only).

### Launch-config selection & launch.json interop

The config-side companion to the env-file selection, consumed by the
auto-finder **Config** section. `auto-run.import` gains a selection
surface mirroring `auto-run.env`:

- `import.configs_list(kind?)` — the reachable `launch.json` configs
  (`entries()`), optionally filtered to `test` / `debug`, each annotated
  `selected`; `import.get_selected()` / `import.set_selected(name|nil)`
  persist a config **name** in the shared tier's `state.json`
  (self-heals when the entry vanishes) and fire `run.config:changed`
  `{action="selected"}`.
- `import.apply_selected_base(eff)` merges the selected config **under**
  the effective config at the launch chokepoints (`dap.translate`,
  `dap.debug_test`, `exec.prepare`): `env_files` / `env` / `build_flags`
  / `cwd` / `params` flow into every run/debug; `program`/`args` apply
  only when the invoked config has none. `import.read_config(name)`
  returns resolved fields for panel display with env **values masked**.
- `import.export(name)` serializes a store config to a `launch.json`
  entry (VSCode field order), appending — or replacing the same-name
  entry — in the nearest reachable `launch.json`, else creating
  `<worktree>/.config/launch.json`.

Two more launch-time surfaces back the auto-finder debug panel:

- `exec.command_line(name)` — a terminal-ready shell command for running
  a config without launching (`go run` / `go test` + `build_flags`, env
  sourced from a file so secrets stay off the command line, `cd`-prefixed).
- `discovery.run_output(run_id, adapter)` — a run's human/terminal output,
  reconstructed via the adapter's optional `output(exit, opts?)` hook (the
  go adapter re-joins the `go test -json` `Output` events).

> **delve `dlvCwd`:** `dap.translate` sets both `cwd` (the debugged
> program's run dir) **and** `dlvCwd` (delve's own build dir) to the
> config's cwd, else the worktree root. Without `dlvCwd`, delve runs
> `go build` from Neovim's cwd — outside the module in a multi-repo
> parent — and the launch dies "go.mod not found / Failed to launch".

### Breakpoint persistence

Breakpoints persist per repo at
`resolve_run_dirs().shared .. "/breakpoints.json"` with
worktree-relative paths — one saved set rehydrates in whichever
worktree is active (restore on `BufReadPost`; stale line numbers are
dropped with a warn log). Direct `dap.toggle_breakpoint()` calls are
picked up by a reconcile sweep (debounced CursorHold, BufWritePost,
dap session start/stop, synchronous VimLeavePre flush). Tune or
disable the editing-time sweep:

```lua
require("auto-run").setup({
  breakpoint_sync = {
    cursorhold = true,    -- false: disable CursorHold/BufWritePost sweeps
    interval_ms = nil,    -- optional periodic sweep
  },
})
-- Session-boundary + VimLeavePre flushes stay active even when disabled.
```

## Default keymaps (ADR §10)

`require("auto-run").default_keymaps()` — `<leader>r` = run/test,
`<leader>d` = debug/DAP only, F-keys unchanged. Bindings are
pcall-gated on their dependency and all carry `desc` strings.

| Key | Action | Provenance |
|---|---|---|
| `<F9>` / `<F8>` / `<F7>` / `<F10>` | continue / step over / into / out | kept |
| `<leader>rr` | run: pick config & run | new |
| `<leader>rl` | run last | gobugger `dr` |
| `<leader>rt` | run nearest test | new |
| `<leader>rf` | run current test file | new |
| `<leader>rp` | pick env profile for next run | new |
| `<leader>rc` | new run config (scaffold) | gobugger `dM`/`dN` merged |
| `<leader>db` / `dB` / `dC` | toggle / conditional / clear-all breakpoints | kept |
| `<leader>dc` | continue/start (dap) | kept |
| `<leader>dt` | debug nearest test | gobugger `dt` |
| `<leader>dm` | debug entry point (pick) | gobugger `dm` |
| `<leader>da` / `dA` | attach PID / attach remote | kept |
| `<leader>dv` / `dw` / `de` | dap-view / watch / eval | kept |
| `<leader>dq` / `dR` | terminate / restart | kept |
| `<leader>dD` | doctor | gobugger `dD` |

`<leader>rt` / `<leader>rf` run the discovery position nearest the
cursor / the current file's position through the Phase 3 position
engine; `<leader>dt` routes the same nearest resolution through
`debug_position` for go test positions. Buffers no adapter claims
fall back to the Phase 2 kind=test config path with a logged hint.

Dropped from keymaps (moved to panel/commands): `dL` reload (store
auto-reloads), `dE` last error (`:AutoRun last-error`), `dF`
fix-worktree (`:AutoRun doctor --fix`), scaffold keys.

## Requirements

- Neovim ≥ 0.10
- auto-core.nvim ≥ v0.1.61 (`events.register_topics` + `auto-core.trust`)
- Treesitter parsers for `go` (go adapter) and
  `javascript`/`typescript`/`tsx` (jest adapter) — test discovery
  degrades to structured parse errors without them
- Optional: nvim-dap (dap strategy + breakpoints), nvim-dap-go
  (debug-test, attach), nvim-dap-view (session UI), auto-agents.nvim
  (preferred terminal provider), worktree.nvim (preferred
  `list_child_repos` surface; falls back to the auto-core primitive)

## Phased rollout

1. Store + env engine + launch.json import + `run.*` read/mutate verbs ✓
2. Execution + DAP + breakpoint persistence + keymaps ✓
3. Test discovery (go, jest) ✓ + auto-finder tests/debug views (auto-finder side)
4. gobugger retirement
5. Additional adapters (dart, rust, python)

## Continuous integration

`.github/workflows/ci.yml` runs two jobs, and the split between them is
the point.

**`lua` — the gate.** Every push to `main` and every pull request. It
installs a pinned toolchain and hands the verdict to `tests/run-all.sh`.
Everything is pinned, so a red run means *this change* rather than
something that moved underneath it:

| Pinned by | What | Why |
|---|---|---|
| commit SHA | `actions/checkout` | a tag can be moved to different code under the same name |
| version **and SHA-256** | Neovim `v0.12.5` | a release asset can be replaced under the same tag and name, so the version alone is not reproducible |
| commit SHA | `auto-core.nvim`, `plenary.nvim`, `nvim-dap` | reproducibility; the pin's age is reported (see below) |

A runner's Neovim ships tree-sitter parsers for `c`, `lua`, `vim`,
`vimdoc`, `markdown` and `query` **only** — every other parser is something
a developer installed once and stopped seeing. So a suite that renders
tree-sitter output is green on every machine with a parser lying around and
red on the first runner without one. `.github/install-parsers.sh` builds
`go`, `javascript`, `typescript` and `tsx` from pinned grammar sources.
Those four are the languages this plugin's discovery adapters
have fixtures for.

**`drift` — the early warning.** The same suite, with **auto-core resolved
at its default branch** instead of the commit `lua` pins. A regression in
auto-core reaches its consumers before anyone notices, and a consumer
pinned to a frozen auto-core is precisely the thing that cannot notice.
Both properties are wanted and they conflict, so they are split rather
than traded.

`drift` runs on a **schedule (Mondays, 06:00 UTC) and manual dispatch
only** — deliberately *not* on push or pull request. On push it would
redden the merge run for an upstream change unrelated to the PR being
merged, and would put a code path on the merge that no PR run exercised.

### `tests/run-all.sh` is the whole verdict

CI does not reimplement the gate; it supplies the environment and lets the
runner be the judge. `run-all.sh` runs every suite and treats a **missing**
`N passed, M failed` summary line as a hard failure, rather than parsing
whatever partial PASS lines a suite emitted before it stopped. That
sentinel is the only thing that catches a C-level crash mid-run, which is
why running a single suite by hand is **not** a substitute:

```sh
./tests/run-all.sh                              # the gate
nvim --headless -u NONE -l tests/smoke.lua      # one suite, while iterating
```

### A failing `drift` run has an addressee

A red row in the Actions tab is not a signal — nobody is obliged to open
it, and the one time a drift job caught a real regression in this family,
it was caught because somebody dispatched it by hand while investigating
something unrelated. Left to the schedule it would have gone red and sat
there. So on failure the job opens an **issue**, which has an addressee
that outlives a run's log retention and records *when* divergence started:

- **One issue per repo**, found by the **`ci-drift` label**, not by title.
  Title matching breaks the moment somebody edits the title — the next
  failure opens a duplicate instead of commenting.
- Reopened and commented rather than duplicated, so a month of Mondays is
  one thread instead of four issues nobody triages.
- **Closed automatically on the next green** drift run, with a comment
  saying the divergence cleared.

A `ci-drift` issue does **not** mean this plugin is broken for its users:
the gating job pins auto-core and is green. It means auto-core has moved in
a way this suite does not accept yet, and one of the two has to change
before the pin is bumped.

### Exercising the notifier, and the pin's age

`workflow_dispatch` takes a **`force_drift_failure`** boolean that fails the
drift job deliberately:

```sh
gh workflow run ci.yml --repo yongjohnlee80/auto-run.nvim --ref main \
  -f force_drift_failure=true
```

The whole premise of the notifier is that an unread signal is not a signal
— so an untested notifier is the same bug one layer up, and there has to be
a way to make it fire without waiting for auto-core to break something.

Proven here, both halves, on the real runner: a forced dispatch opened
[#7](https://github.com/yongjohnlee80/auto-run.nvim/issues/7)
and the next green drift run closed it again. The design was piloted
in
[auto-finder.nvim](https://github.com/yongjohnlee80/auto-finder.nvim) and
rolled out unchanged.

The `lua` job also reports **how stale the auto-core pin is**, as routine
output rather than something discovered while debugging.
It is
reported and never acted on: **bumping the pin is a deliberate, reviewed
change, never automatic.** A gating job that changes under a PR
reintroduces exactly the mystery failure on unrelated work that pinning was
adopted to prevent.

Two guards keep that report honest, and both exist because the first
version was wrong:

- It reads the compare API's **`ahead_by`**, not `behind_by`. For
  `compare/PIN...main`, `behind_by` is always `0` when the pin is an
  ancestor — the first version printed `0` on a pin eight commits stale,
  ran green, and would have called the pin current for as long as the repo
  existed. An unparseable answer now emits a `::warning` saying staleness
  was **not determined**, because `0` reads as "current".
- It **counts the `AUTO_CORE_REF` values in the file** and fails with
  `::error` if there is more than one. When this design was rolled out
  across the family, the step arrived carrying the pilot repo's SHA — every
  copy would have reported the age of a pin it does not use, in a step
  whose whole job is noticing staleness, with nothing about the copy
  looking wrong.
