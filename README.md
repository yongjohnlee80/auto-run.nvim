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

## Requirements

- Neovim ≥ 0.10
- auto-core.nvim ≥ v0.1.61 (`events.register_topics` + `auto-core.trust`)

## Phased rollout

1. Store + env engine + launch.json import + `run.*` read/mutate verbs
2. Execution + DAP + breakpoint persistence + keymaps
3. Test discovery (go, jest) + auto-finder tests/debug views
4. gobugger retirement
5. Additional adapters (dart, rust, python)