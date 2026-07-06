# Changelog

## v0.1.0 (unreleased)

ADR-0048 Phase 1 — core store + env engine.

### Added

- **Two-tier `.auto-run/` store** (`auto-run.store`): tracked tier
  `<worktree>/.auto-run/{configs,profiles}/*.json` (committed) +
  shared-local tier `<container>/.auto-run/` (linked-worktree
  layouts) / `<repo>/.auto-run/local/` (plain repos, `.gitignore`
  scaffolded). Strict JSON, one file per record, atomic writes via
  `auto-core.fs.atomic`, deterministic tier-then-filename listing.
- **`store.resolve_run_dirs()`** — the single override-aware resolver
  (ADR §2.1): anchor = `auto-core.git.worktree.get_active()` (buffer
  dir, then cwd fallback), `run.set_dir` override registry
  (`known_dirs` in `state.namespace("auto-run")`,
  `origin = "override"|"derived"`), cache invalidated on
  `core.active_worktree:changed` / `core.workspace_root:changed`.
  Smoke-covered by the required four-fixture matrix (plain repo,
  linked worktree of a bare container, set_dir override, nested
  child repo).
- **Config schema + 7-layer merge engine** (`store.schema`,
  `store.merge`, ADR §3/§3.1): extends chain → tracked → shared →
  launch.json shim → profile → overrides.json → invocation args.
  Per-field rules (scalars/args/depends replace; env_files +
  pipeline arrays append; env/runtime_env/params merge per key; tags
  append+dedupe), JSON-null tombstones, extends cycle detection with
  path-of-cycle diagnostics, `run.update` write-routing to the
  highest writable layer (reported in the result).
- **Env engine** (`auto-run.env`, ADR §4/§4.1): uniform substitution
  (`${worktree}`, `${containerRoot}`, `${workspaceFolder}`,
  `${file}`, `${fileDirname}`, `${env:VAR}`; `${input:param}` left
  unresolved with a structured `needs_params` marker), profile
  pipeline (base_env_files → secret_manifests [names only; pluggable
  resolver hook] → command_env [trust-gated `run.command_env`,
  untrusted entries fail composition] → runtime_env templates →
  config env), materialization to
  `stdpath("cache")/auto-run/env/<run-id>.env` 0600 (dir 0700),
  startup sweep of files older than 24 h.
- **launch.json interop** (`auto-run.import`, ADR §5): JSONC-tolerant
  parse, upward walk stopping at `.bare`/`.git` boundaries,
  read-through shims ONLY while neither tier has a store, one-shot
  import into the tracked tier with `origin = "launch.json"` and
  per-entry overwrite/skip/rename conflict parameter, launch.json
  `inputs` → typed params, current-OS block lifting.
- **Mailbox verbs** (`auto-run.mailbox.commands`, ADR §11 Phase 1
  tier): `run.list`, `run.show`, `run.profiles_list`, `run.status`,
  `run.validate`, `run.add`, `run.update`, `run.remove`,
  `run.set_dir`, `run.import`. Execution verbs are Phase 2.
- **Event topics** (ADR §12): the seven `run.*` topics registered via
  `auto-core.events.register_topics("auto-run.nvim", …)` on setup.
- **`:AutoRun {list|show|validate|import|doctor|set-dir}`** user
  command with completion; `doctor` prints the resolver output for
  the current anchor (both tiers, origin, override state,
  read-through).
- `tests/smoke.lua` — 169-assertion headless suite covering all of
  the above.

### Requirements

- Neovim ≥ 0.10, auto-core.nvim ≥ v0.1.61
  (`events.register_topics` + `auto-core.trust`).