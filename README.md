# auto-run.nvim

Unified run-config / test / debug plugin for the auto-family
(ADR-0048). Manages run configurations, layered env profiles, test
discovery/execution, and DAP orchestration behind one canonical
per-repo store. Supersedes gobugger.nvim at feature parity.

## Status

Phases 1–2 (store + env engine, execution + DAP) — under active
development. See the accepted ADR for the full design:
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

## Module layout (Phases 1–2)

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
├── keymaps.lua          -- default_keymaps() (§10 table)
└── mailbox/commands.lua -- run.* verb SPECS + register_all()

plugin/auto-run.lua      -- :AutoRun {list|show|validate|import|doctor|set-dir
                         --          |run|debug|test|stop|jobs|last-error}
tests/smoke.lua          -- nvim --headless -u tests/smoke.lua -c 'qa!'
```

Phase 3 modules (`adapters/`, `discovery/`, the auto-finder views)
land with their phase per the ADR rollout table.

## Usage

```lua
require("auto-run").setup()
require("auto-run").default_keymaps()   -- optional: the §10 layout below
```

- `:AutoRun run [name]` / `:AutoRun test [name]` / `:AutoRun debug
  [name]` — launch a config (picker with per-repo pick memory when
  the name is omitted).
- `:AutoRun jobs` / `:AutoRun stop <run-id>` — session job inventory
  and control. Stop only ever signals jobs auto-run started.
- `:AutoRun doctor` — resolver output, dap-adapter health,
  breakpoint-store stats, live jobs.
- `:AutoRun last-error` — replay the last failed-start dap capture in
  a scratch buffer.
- `:AutoRun import` — one-shot launch.json migration into the
  tracked tier (`origin = "launch.json"` provenance).
- Mailbox verbs register automatically when the auto-core mailbox
  surface is present. `run.start` / `run.test_run` /
  `run.debug_start` are gated behind the `run.exec` trust capability
  (enabled interactively in the host — never via mailbox);
  `run.stop` is ungated.

### Execution model

Every launch: 7-layer merge → uniform substitution → env composition
(Phase 1 pipeline, incl. trust-gated `command_env`) → strategy:

| Strategy | Default for | Behavior |
|---|---|---|
| `run`  | `kind=run`, plain `kind=test` | background `vim.system` job; `stdout`/`stderr`/`result.json` under `stdpath("cache")/auto-run/runs/<run-id>/` |
| `dap`  | `kind=debug`, debug-test | nvim-dap session via the `auto-run` config provider; go first-class |
| `term` | opt-in | terminal provider: registered fn → `auto-agents.term` probe → `:split` + `jobstart(term=true)` fallback |

Phase 2 test scope: `test_run` drives **kind=test configs** (plain
`go test` on the configured package, or dap-go's `debug_test` with
the config's buildFlags/env merged in). Position-level discovery is
Phase 3.

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

Dropped from keymaps (moved to panel/commands): `dL` reload (store
auto-reloads), `dE` last error (`:AutoRun last-error`), `dF`
fix-worktree, scaffold keys.

## Requirements

- Neovim ≥ 0.10
- auto-core.nvim ≥ v0.1.61 (`events.register_topics` + `auto-core.trust`)
- Optional: nvim-dap (dap strategy + breakpoints), nvim-dap-go
  (debug-test, attach), nvim-dap-view (session UI), auto-agents.nvim
  (preferred terminal provider)

## Phased rollout

1. Store + env engine + launch.json import + `run.*` read/mutate verbs ✓
2. Execution + DAP + breakpoint persistence + keymaps ✓
3. Test discovery (go, jest) + auto-finder tests/debug views
4. gobugger retirement
5. Additional adapters (dart, rust, python)