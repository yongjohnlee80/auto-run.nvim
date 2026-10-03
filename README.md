# auto-run.nvim

**Run, test and debug any project from Neovim the same way: one config
store, one set of keys, two panes, whatever the language.**

auto-run.nvim covers Go, Rust, Node.js, Jest and React Testing Library,
Playwright, Dart and Flutter desktop, and it is built to take more.

## What it solves

Every language usually brings its own plugins: a test runner, a debugger, a
`launch.json` dialect, its own keymaps and its own idea of where config lives.
Moving from a Go service to the React client that calls it, or to a Flutter
app, means switching all of them. A config that works on one machine is often
hidden in someone's editor setup, so it never reaches the repo.

auto-run replaces that with one model:

- **One store per repo.** `.auto-run/` holds strict-JSON configs, committed
  with the code, plus a local tier for personal overrides.
- **One workflow** for every runtime: choose where to work, then run, test or
  debug with the same keys and see the result in the same place.
- **Discovery, not configuration.** Tests are found from the source (via
  treesitter). A config is needed only for something extra: env vars, flags,
  a script or a device.

## Philosophy

- **Minimal UI.** There are two panes, Tests and Debug (rendered by
  [auto-finder.nvim](https://github.com/yongjohnlee80/auto-finder.nvim)), and
  two key prefixes:
  - `<leader>r` launches (lowercase runs, UPPERCASE debugs);
  - `<leader>d` controls what is running.

  There are no dashboards or floating wizards. State is visible: the working
  directory, the picked configs, running sessions, and each session's pid,
  port and log.
- **Just make it work.** Things that would fail later are caught up front:
  - a program path that does not exist is refused before the debugger
    starts;
  - a missing SDK, an `npm install` or `pub get` that was never run, absent
    Playwright browsers or a missing debug adapter are named, with the
    command that fixes them, before anything spawns;
  - test results come from each runner's machine output (`go test -json`,
    `--reporter=json`, …), never from scraped text, whenever the runner has
    one.
- **One simple, uniform workflow.** These are the same keys for every
  runtime:

  | | Run | Debug |
  |---|---|---|
  | The test under the cursor | `<leader>rt` | `<leader>rT` |
  | The current file | `<leader>rf` | `<leader>rF` |
  | An entry point (a config) | `<leader>rp` | `<leader>rP` |
  | Again | `<leader>rl` | `<leader>rL` |
  | Where to work (worktree / folder) | `<leader>rw` | |

- **Declarative.** Configs are data in the repo, so they can be reviewed,
  shared and written by tools. An agent can scaffold them (every `.auto-run/`
  carries an `AGENTS.md`, below), but nothing at runtime needs one.

## Supported languages and frameworks

| Runtime | Runs | Tests | Debugs with | Needs installed |
|---|---|---|---|---|
| `go` | `go run` / the built program | `go test -json`, exact `-run` | delve (nvim-dap-go) | Go; `delve`; parser `go` |
| `rust` | `cargo run` | `cargo test`, exact names | codelldb | Rust/Cargo; `codelldb`; parser `rust` |
| `node` | `node <file>` (`tsx` for `.ts`), or a `package.json` script via npm / pnpm / yarn / bun | — (see Jest / Playwright) | js-debug (`pwa-node`) | Node; `node_modules` installed; `js-debug-adapter` to debug |
| `jest` | — | Jest, React Testing Library included (`.js/.jsx/.ts/.tsx`) | js-debug (`--runInBand`) | `jest` in the project; parsers `javascript`, `typescript`, `tsx` |
| `playwright` | — | `playwright test`, selected by `file:line` | js-debug (one worker, no timeout) | `@playwright/test`; its browsers (`npx playwright install`) |
| `dart` | `dart run`; Flutter: `flutter run -d linux\|macos\|windows` | `dart test` / `flutter test`, exact `--name` | the SDK's own debug adapters | Dart or Flutter SDK; `pub get` run; parser `dart`; Flutter desktop: its platform toolchain |

How the runtimes are told apart:
- **Dart vs Flutter** is detected per package from pub's resolution
  (`.dart_tool/package_config.json`), and a config's `dart_sdk` can force
  either.
- **Playwright vs Jest:** a spec is Playwright's when it imports
  `@playwright/test` under a `playwright.config.*`, otherwise Jest's.

Not supported (yet):
- Python;
- Flutter on phones, emulators or the web;
- Vitest;
- Node's built-in `node:test`.

[Adding a language](#adding-a-language) is an adapter module.

`:AutoRun doctor` lists what each runtime found at the working directory is
missing, under **toolchains and dependencies**.

## Getting started

### With AutoVim

[AutoVim](https://github.com/yongjohnlee80/autovim) ships everything wired:
- auto-run and auto-finder;
- nvim-dap with dap-view;
- delve, and js-debug through the LazyVim TypeScript extra;
- the LazyVim Dart extra (dartls, the `dart` parser, `dart format`);
- the keymaps above.

To use it:
1. Open a project.
2. Choose the working directory with `<leader>rw`.
3. Open the Tests or Debug pane.

Install the language toolchains you use (Go, Rust, Node, the Dart or Flutter
SDK). AutoVim does not install SDKs.

### Standalone

```lua
-- lazy.nvim
{
  "yongjohnlee80/auto-run.nvim",
  version = "^0.1.0",
  dependencies = {
    "yongjohnlee80/auto-core.nvim",     -- required
    "mfussenegger/nvim-dap",            -- debugging (any runtime)
    "igorlfs/nvim-dap-view",            -- optional: the session UI
    "leoluz/nvim-dap-go",               -- optional: Go debug-test and attach
    "yongjohnlee80/auto-finder.nvim",   -- recommended: the Tests and Debug panes
  },
  event = "VeryLazy",
  opts = {},
  config = function(_, opts)
    require("auto-run").setup(opts)
    require("auto-run").default_keymaps()   -- optional: the <leader>r / <leader>d layout
  end,
}
```

Then, for each language you use:
- **Treesitter parsers** for discovery: `go`, `rust`, `javascript`,
  `typescript`, `tsx`, `dart` (e.g. `:TSInstall dart`).
- **Debug adapters:**
  - Go needs `delve`.
  - Rust needs `codelldb`.
  - JavaScript needs `js-debug-adapter`. auto-run registers
    `dap.adapters["pwa-node"]` itself when that executable is on `PATH` or
    in Mason's `bin`, and nothing else registered it.
  - Dart and Flutter use the SDK's adapters. auto-run registers
    `dap.adapters.dart` when no other plugin owns it.
- Without auto-finder, everything still works from the keys and `:AutoRun`
  commands; the panes are where results and state are shown.

## Project structure

What auto-run keeps in a repo. The layout is the same for AutoVim and
standalone users; only the shared tier's location depends on how the repo is
cloned.

```
<repo>/
├── .auto-run/                        ← tracked: commit it
│   ├── configs/<name>.json           ← run / test / debug configs (strict JSON, one per file)
│   ├── profiles/<name>.json          ← env profiles
│   ├── .env.*                        ← env files may live here (keep secrets out)
│   ├── AGENTS.md                     ← how to scaffold configs here; written by auto-run
│   ├── CLAUDE.md                     ← "read AGENTS.md"; created once, then yours
│   ├── auto-run.nvim-v0.1.19         ← empty; names the version that wrote AGENTS.md
│   ├── AGENTS.local.md               ← optional: your project's own notes (never touched)
│   ├── .gitignore                    ← "local/" (plain clones)
│   └── local/                        ← the shared tier in a plain clone: overrides,
│                                       picks, breakpoints, state (not committed)
└── …
```

- **In a bare repo with worktrees** (`<container>/.bare` plus
  `<container>/<worktree>/`), the shared tier is `<container>/.auto-run/`,
  shared by every worktree, and it gets its own `AGENTS.md` and marker.
- **Projects in folders** (`go-contacts/`, `web/`, `flutter-client/` in one
  repo) keep **one** store at the repo root. Each config sets `cwd` to its
  folder. `<leader>rw` chooses the folder for test discovery and for configs
  without a `cwd`.
- **`AGENTS.md` stays current by itself.** Whenever auto-run writes into a
  `.auto-run/` folder and finds the marker older than the running version, it
  rewrites `AGENTS.md` and renames the marker. A marker from a *newer*
  auto-run is left alone, so two machines never fight over the file. Reads
  never write. A hand-written `AGENTS.md` found there is moved to
  `AGENTS.local.md`, never overwritten.
- **The rendered `AGENTS.md` is the field reference:**
  - every config and profile field, its allowed values, and the runtimes it
    applies to (generated from the schema);
  - a worked config per runtime;
  - the first-time scaffolding procedure;
  - the keys for doing it by hand.

A config, for the record:

```json
{ "name": "web", "kind": "run", "runtime": "node", "script": "dev", "cwd": "${worktree}/web" }
```

## Adding a language

A language is an **adapter**: a plain Lua table of functions, registered
before first use:

```lua
require("auto-run.adapters").register_adapter(require("my.python_adapter"))
```

The required part is the test-adapter interface:

```lua
local M = { name = "python", summary = "Python — pytest" }

function M.root(dir) end                       -- project root for a file's dir, or nil
function M.filter_dir(name, rel, root) end     -- optional: false prunes a dir from the scan
function M.is_test_file(path) end              -- metadata-free: no subprocess
function M.discover_positions(path) end        -- a type="file" position with namespace/test children
function M.build_spec(args) end                -- { cmd, cwd, env, context } for a position
function M.results(spec, exit, tree) end       -- the runner's machine output → { [position id] = result }
```

Optional capabilities turn a test adapter into a full runtime:

| Capability | What it gives the user |
|---|---|
| `default_config(kind, name)` | the runtime appears in the panes' `a` (new config) |
| `build_run_argv(eff, opts)` | `run` / the pane's `r` for a config |
| `prepare_debug_config(eff, opts, cb)` | debugging a config (`d`, `<leader>rP`) |
| `prepare_debug(pos, opts, cb)` | debugging a discovered test (`<leader>rT`, the tests pane's `d`) |
| `preflight(ctx)` | named missing toolchains and dependencies, before anything spawns, and in doctor |
| `output(exit, opts)` | the tests pane's output view (`i`) |

Conventions the builtins follow, which a new adapter should too:

- **Nesting and env:**
  - Discover with treesitter and nest by source range:
    `require("auto-run.adapters.nesting").file_position(path, flat)` turns
    the flat matches into the position.
  - Compose env through `require("auto-run.adapters.config").test_config(name)`,
    so `env`, `env_files`, the selected env file and profiles reach your
    runs exactly as they reach every other runtime.
- **Selecting tests:** select exactly. Anchored regexes, or a `file:line`
  position. A substring filter that also runs a test's prefix siblings is a
  bug.
- **The scan filter:** the scan keeps a directory when **any** adapter's
  `filter_dir` accepts it. Prune the other ecosystems' noise too
  (`node_modules`, `vendor`, `target`). An adapter that claims no test files
  returns `false` always.
- **Debugging:**
  - `prepare_debug*` returns `{ dap_type, request, program, args, cwd, env,
    extra }`, and `extra` is copied into the nvim-dap config verbatim.
  - Validate before returning; nvim-dap's adapter callback has no error
    channel.
- **`preflight`:** it is synchronous and filesystem-only. It never spawns.
  It runs on every launch.
- **New config fields:** add them to `auto-run.store.schema` with a
  `FIELD_DOCS` entry (`help`, `values`, `runtimes`). The panes then show and
  edit them, and every `.auto-run/AGENTS.md` documents them, with no other
  change.

To ship it in auto-run itself, add the module to the builtin roster in
`lua/auto-run/adapters/init.lua`. Order matters: the first adapter to claim a
file owns it. Add smoke cells that run against the real toolchain.

---

The rest of this README is the reference.

## Commands

```lua
require("auto-run").setup()
require("auto-run").default_keymaps()   -- optional: the §10 layout below
```

Six subcommands (ADR 0199 §4.1). Listings — configs, jobs, the discovered
test tree — live in auto-finder's tests and debug panes, which render them
live; a full discovery scan is the tests pane's `S`.

- `:AutoRun run [name]` / `:AutoRun debug [name]` — run or debug a config,
  **dispatching on its kind**: a `kind=test` config runs as a test
  (`exec.test_run`) or debugs the test at the cursor with that config's flags
  and env (`dap.debug_test`); `run`/`debug` configs launch (`exec.start` /
  `dap.debug_start`). With no name, a picker with per-repo pick memory.
- `:AutoRun stop [run-id]` — stop a running job; with no id, the only one, or
  a choice among several. Covers exec jobs (a debug session ends with the
  debugger's terminate). Stop only ever signals jobs auto-run started, and it
  signals the **process group**, not the handle (see below).
- `:AutoRun doctor` — config validation, resolver output, git/worktree health (project
  root + marker, anchor `.git` kind incl. gitfile-target state,
  `git status`, common dir, go module root), configs per kind with
  the remembered session pick, test-adapter roots + discovery
  snapshot, dap-adapter health, breakpoint-store stats, live jobs.
- `:AutoRun doctor --fix` — `git worktree repair` from the repo's
  common dir (gobugger `fix_worktree` parity; survives a broken
  worktree gitfile via the container walk). Interactive-only —
  mutating, so never exposed as a mailbox verb.
- `:AutoRun doctor --last-error` — replay the last failed-start dap capture
  in a scratch buffer.
- `:AutoRun import` — one-shot launch.json migration into the
  tracked tier (`origin = "launch.json"` provenance).
- `:AutoRun env [select <path>|clear]` — list/manage the per-repo
  selected env file (§4.2 below); `*` marks the selection.
  `:AutoRun env profile [name|clear]` lists the store's env profiles or sets
  the one applied to the next launch.
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

### Configuring test runs

Test discovery needs no configuration — the tests pane finds positions as
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

Create them with `a` in auto-finder's tests or debug pane (adapter-aware
scaffolding through `adapters.scaffold`), by hand under
`.auto-run/configs/`, or by importing a `launch.json` (`:AutoRun import` —
its `env` and `envFile` land as `env` and `env_files`).

**Every field and its allowed values** are documented in
`auto-run.store.schema.FIELD_DOCS`; auto-finder's panes show them beside each
field of an expanded config (`o`), and `e` sets one, with a chooser for the
fixed sets (kind, runtime, profile, extends, cargo_target_kind, dart_sdk,
device). Each runtime's own fields (go `build_flags`, rust's Cargo identity,
node `script`, dart `dart_sdk` / `device`) are shown for configs of that
runtime.

**Environment.** Every adapter composes identically, so anything that works
for go works for jest, playwright, rust and dart:

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

## Default keymaps (ADR 0199 §4.2)

`require("auto-run").default_keymaps()`. `<leader>r` **launches** — lowercase
runs, the same letter UPPERCASE debugs; `<leader>d` **controls** what is
running. `<leader>r` is auto-run's alone (remote-sync.nvim's keys live under
`<leader>R`). Bindings are pcall-gated on their dependency and all carry
`desc` strings; override any with `vim.keymap.set` after this call.

| Target | Run | Debug |
|---|---|---|
| Nearest test | `<leader>rt` | `<leader>rT` |
| Current file | `<leader>rf` — run the file | `<leader>rF` — choose a test in it |
| Pick an entry point | `<leader>rp` | `<leader>rP` |
| Again (last) | `<leader>rl` | `<leader>rL` |

`rp` / `rP` dispatch on the picked config's kind, the same rule as
`:AutoRun run` / `debug`: a `kind=test` config runs as a test / debugs the test
at the cursor. `rl` / `rL` replay the last run / debug that **actually
launched**, from any surface — a key, a command or a pane (`auto-run.last`). A
target that no longer exists, or a changed active worktree, is refused with a
message rather than silently substituted. `rL` with no auto-run debug yet falls
back to nvim-dap's own `run_last`.

`<leader>rw` chooses the **working directory**: a worktree from the same list
`<leader>gw` shows, then the worktree root, one of its project folders (a
`go.mod`, `Cargo.toml`, `package.json`, `pubspec.yaml` … within two levels) or
a typed directory. That directory is where test discovery looks and where runs
and debugs start when a config sets no `cwd`; the store stays at the repo root.
The editor's cwd never moves (auto-core's `git.worktree.choose_active`, also the
debug and tests panes' `w`).

| Key | Action |
|---|---|
| `<F9>` / `<F8>` / `<F7>` / `<F10>` | continue / step over / into / out |
| `<leader>dc` | **resume only** — with no session it names the keys that start one |
| `<leader>di` / `do` / `dO` | step into / over / out (no F-keys needed) |
| `<leader>db` / `dB` / `dC` | toggle / conditional / clear-all breakpoints |
| `<leader>dq` / `dR` | terminate / restart |
| `<leader>dv` / `dw` / `de` | dap-view / watch / evaluate |
| `<leader>da` / `dA` | delve attach PID / remote — **go buffers only** |

`<leader>rt` / `<leader>rf` run the discovery position nearest the cursor / the
current file's position through the position engine; `<leader>rT` routes the
same nearest resolution through `debug_position`. Buffers no adapter claims
fall back to the kind=test config path with a logged hint.

Not keys: new configs → `a` in the panes; the env profile → `:AutoRun env
profile`; diagnostics → `:AutoRun doctor` (`--last-error`, `--fix`).

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
  needs an explicit scan: the tests panel's `S`, or
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
  jumps to the test and debugs it through the adapter's `prepare_debug`
  (go, rust, jest, playwright, dart). Results feed `run.results:changed`; container
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
- **rust** (ADR 0194) — `#[test]`-family functions (`#[test]`,
  `#[tokio::test]`, `#[rstest]`, …) nested by `mod`, over `.rs` files;
  root is the nearest `Cargo.toml` promoted to the enclosing
  `[workspace]`; Cargo **package + target identity** (`-p` / `--lib` /
  `--bin` / `--test`) is attached to every position, and runs use
  `cargo test <selectors> [<name>] -- --exact --format pretty --color
  never`. Rust has no stable machine test output (libtest JSON is
  nightly), so `results` is a versioned parser over libtest's pretty
  output, target-scoped, and returns a structured error (never a silent
  skip) when a run is ambiguous. **Debugging** builds the
  identity-matched artifact (`cargo … --no-run --message-format=json`)
  and launches it under **codelldb** (`dap.adapters.rust`); the four
  optional adapter capabilities (`default_config`, `build_run_argv`,
  `prepare_debug`, `prepare_debug_config`) drive scaffolding, `cargo
  run`, debug-a-test, and ordinary `kind=debug` launches.
- **playwright** (ADR 0213) — `test.describe` / `test` (and their
  `.only`/`.skip`/`.fixme`/… forms) in specs that import `@playwright/test`
  under a `playwright.config.*`; runs `playwright test --reporter=json
  <file>:<line>` (exact by position), aggregates a spec's projects (any
  unexpected → failed, flaky → passed), and debugs `@playwright/test/cli.js`
  under js-debug with one worker and no timeout. Preflight checks the
  browsers **at the revisions the installed Playwright expects**.
- **dart** (ADR 0196 r3) — `group` / `test` / `testWidgets` with
  string-literal descriptions under `test/`; the tool (`dart` or `flutter`)
  comes from pub's `.dart_tool/package_config.json` (a `flutter` package in the
  resolved graph means Flutter); `--reporter=json` with an anchored `--name`
  regex; `testWidgets` results reconcile through `root_url`; a suite that
  fails to compile fails its tests with the compiler's message. Debugging
  runs the SDK's `dart debug_adapter` / `flutter debug-adapter` (`--test` for
  tests, whose `dart.testNotification` events feed the tests pane), and
  Flutter apps run on desktop devices only.
- **node** (ADR 0213) — a runtime, not a test adapter: `node <file>` (`tsx`
  for TypeScript when installed) or `<pm> run <script>` with the package
  manager its lockfile names; debugs through js-debug's `pwa-node` with
  `outputCapture = "std"` so the program's output reaches the session.

Writing one: see [Adding a language](#adding-a-language).

#### One env convention for every language

A `kind=test` config supplies the environment for test runs, and every
adapter resolves it through the **same** owner
(`auto-run.adapters.config`) and the same Phase 1 pipeline —
`store.get` → `substitute_deep` → `env.compose`. So `env`, `env_files`,
the §4.2 selected env file and secret manifests behave identically
whether you are running `go test`, `jest`, `playwright test`, `cargo test`
or `dart test`.

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

## Module layout

```
lua/auto-run/
├── init.lua             -- setup(), topic registration, public facade
├── config.lua           -- plugin opts (not run configs)
├── log.lua              -- auto-core.log wrapper (silent-INFO degrade)
├── store/
│   ├── init.lua         -- CRUD + 7-layer merge assembly + validate/status
│   ├── paths.lua        -- resolve_run_dirs() + set_dir override registry
│   ├── schema.lua       -- config/profile validation
│   ├── merge.lua        -- pure merge engine (field rules, tombstones, extends)
│   └── agents.lua       -- AGENTS.md + the version marker in every .auto-run/
├── env/init.lua         -- substitution + profile pipeline + 0600 materialization
├── import/init.lua      -- launch.json JSONC importer + read-through shims
├── exec/
│   ├── init.lua         -- start/test_run/stop/list, pick memory, run_last
│   ├── job.lua          -- vim.system engine, per-run dirs, job table, events
│   └── strategies.lua   -- run|term|dap resolution + terminal provider probe
├── dap/
│   ├── init.lua         -- provider registration, translation, debug_test parity,
│   │                       attach/attach_remote, dap-view + winfixbuf + error capture
│   ├── breakpoints.lua  -- §9 persistence + reconcile sweep + restore
│   ├── sessions.lua     -- a session's pid, port and output journal
│   └── dart_tests.lua   -- dart.testNotification → debugged-test results
├── adapters/
│   ├── init.lua         -- AutoRunAdapter interface + register_adapter() registry
│   ├── config.lua       -- the shared kind=test config resolver (env for every adapter)
│   ├── nesting.lua      -- treesitter matches → nested positions (jest, playwright, dart)
│   ├── js.lua           -- what the JS adapters share: package root, lockfile → pm, node_modules
│   ├── go.lua           -- go test -json adapter (treesitter discovery)
│   ├── rust.lua         -- cargo test adapter + Cargo identity, codelldb debug
│   ├── jest.lua         -- jest --json adapter (treesitter discovery), js-debug debug
│   ├── playwright.lua   -- playwright test --reporter=json, file:line selection
│   ├── dart.lua         -- dart / flutter test + run, package kind from package_config.json
│   └── node.lua         -- node runtime: a file or a package.json script
├── discovery/init.lua   -- position tree, bounded scans, aggregation, run/debug
├── keymaps.lua          -- default_keymaps() (§10 table)
└── mailbox/commands.lua -- run.* verb SPECS + register_all()

plugin/auto-run.lua      -- :AutoRun {run|debug|stop|env|doctor|import}
templates/AGENTS.md      -- the .auto-run/AGENTS.md template (fields + runtimes rendered in)
tests/run-all.sh         -- the suite runner; tests/smoke.lua is the suite
```

The Tests and Debug panes (the render surface over this API) live in
auto-finder.nvim.

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
`go`, `javascript`, `typescript`, `tsx`, `rust` and `dart` from pinned grammar
sources — the languages this plugin's discovery adapters have fixtures for.
The Dart and Flutter SDKs are not installed in CI: the real-SDK cells run on
the VM43 gate, where the suite asserts they ran (`dart real-SDK floor`).

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

## A note on `gobugger`

gobugger.nvim was
**replaced by auto-run and no longer exists** (ADR-0048 Phase 4). Every
remaining mention — "gobugger parity", "port", `[provenance: gobugger dD]` —
records **where a behaviour came from**, never a runtime dependency: nothing
in `lua/` loads, requires or probes gobugger. The one thing that genuinely
did depend on it — the smoke suite's gobugger *parity gate*, which compared
auto-run's keymaps against gobugger's live `default_keymaps()` — was pruned
when gobugger was deleted, because it had nothing left to compare against.
