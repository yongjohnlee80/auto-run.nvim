# auto-run.nvim

Unified run-config / test / debug plugin for the auto-family
(ADR-0048). Manages run configurations, layered env profiles, test
discovery/execution, and DAP orchestration behind one canonical
per-repo store. Supersedes gobugger.nvim at feature parity.

## Status

Phase 1 (store + env engine) — under active development. See the
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

## Module layout (Phase 1)

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
└── mailbox/commands.lua -- run.* verb SPECS + register_all()

plugin/auto-run.lua      -- :AutoRun {list|show|validate|import|doctor|set-dir}
tests/smoke.lua          -- nvim --headless -u tests/smoke.lua -c 'qa!'
```

Phase 2–3 modules (`exec/`, `adapters/`, `discovery/`, `dap/`,
`keymaps.lua`) land with their phases per the ADR rollout table.

## Usage

```lua
require("auto-run").setup()
```

- `:AutoRun doctor` — resolver output for the current anchor (both
  tiers, origin, override state, launch.json read-through).
- `:AutoRun import` — one-shot launch.json migration into the
  tracked tier (`origin = "launch.json"` provenance).
- Mailbox verbs (`run.list` … `run.import`) register automatically
  when the auto-core mailbox surface is present; execution verbs
  arrive in Phase 2 behind the `run.exec` trust capability.

## Requirements

- Neovim ≥ 0.10
- auto-core.nvim ≥ v0.1.61 (`events.register_topics` + `auto-core.trust`)

## Phased rollout

1. Store + env engine + launch.json import + `run.*` read/mutate verbs
2. Execution + DAP + breakpoint persistence + keymaps
3. Test discovery (go, jest) + auto-finder tests/debug views
4. gobugger retirement
5. Additional adapters (dart, rust, python)