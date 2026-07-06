# Changelog

## [Unreleased]

ADR-0048 Phase 3 (auto-run half) — test discovery + adapters — plus
the Phase 4 gobugger-parity gate (§14.2). The auto-finder
`tests`/`debug` views are the separate auto-finder half of Phase 3.
Smoke 520/0.

### Added (Phase 4 — parity gate)

- **`:AutoRun doctor --fix`** (`auto-run.doctor`, ADR §13/§14):
  gobugger `fix_worktree` port — `git worktree repair` from the
  repo's common dir, with the anchor passed along when its `.git` is
  a gitfile (repairs moved worktrees too). Common-dir resolution
  survives a BROKEN worktree gitfile via a container boundary walk
  (`.bare/` dir = the common dir). Interactive-only — mutating, so
  never a mailbox verb; the read-only mailbox surface stays
  `run.status`. `--fix` completes on `:AutoRun doctor <Tab>`.
- **Doctor parity rows** (gobugger doctor coverage): a `git /
  worktree` section (project root + `.bare/`/`.git/` marker, anchor
  `.git` kind incl. gitfile target `[OK|MISSING]`, `git status`
  health with a `--fix` hint on failure, git common dir, go module
  root via the go adapter's `module_dir`) and a `configs by kind`
  section with `[session pick]` markers (`exec.picks()`, new
  diagnostic accessor over the per-repo pick memory).
- **`discovery.nearest(bufnr?)`**: nearest-position resolution by
  buffer line — on-demand parse, deepest position containing the
  cursor line, else the last position starting at/above it, else the
  file node; structured `(nil, err, reason)` misses
  (`no_file|no_adapter|outside_root|parse_failed|no_positions`).
- **`<leader>rt` / `<leader>rf` / `<leader>dt` rewired onto
  discovery positions** (ADR §10 as-designed): rt runs the nearest
  position and rf the current file's position through the Phase 3
  position engine (`run_position` — adapter build_spec, parsed
  per-position results); dt routes the same nearest resolution
  through `debug_position` for go test positions (jump + dap-go
  merge payload). Buffers no adapter claims fall back to the Phase 2
  kind=test config path with a logged hint.

### Changed (Phase 4 — parity gate)

- **Store name pattern widened** to accept colons and parens
  (`Go: Debug Test (LM)`) — real-world launch.json entry names (and
  VSCode's own `"<lang>: <verb>"` convention) now import verbatim;
  path separators remain rejected.

### Gate evidence (smoke sections [30]–[35])

- [30] the REAL LabelManager launch.json (copied into a fixture)
  imports with correct kind/build_flags/env_files mapping; the
  outside-the-worktree `${workspaceFolder}/../` envFile path
  survives substitution unnormalized.
- [31] a launch.json matching the go-test-env skill's documented
  emission imports and `debug_test` carries
  buildFlags/env/envFile-contents into the dap-go merge payload
  (config env winning over the env file), through both the dap
  bridge and `exec.test_run(debug=true)`.
- [32] `pick_config` kind filtering + per-repo pick memory
  round-trip (state.json on disk, worktree switch, stale-pick
  fall-through, `clear_pick`).
- [33] programmatic gobugger→auto-run keymap audit: every lhs
  gobugger's actual `default_keymaps()` registers is asserted
  kept/remapped/dropped per the ADR §10 table.
- [34] doctor parity rows + `--fix` against a deliberately-broken
  worktree gitfile fixture (git_info flags it, repair heals it,
  structured error outside a repo).
- [35] rt/rf/dt end-to-end through real `go test -json` runs +
  the no-adapter fallback path.

### Added (Phase 3 — discovery + adapters)

- **Adapter registry** (`auto-run.adapters`, ADR §7): the
  `AutoRunAdapter` interface as plain functions — `root`,
  `filter_dir`, `is_test_file`, `discover_positions`, `build_spec`,
  `results` (no subprocess RPC in v1); `register_adapter()` for
  third parties (validated, replace-by-name); go + jest baseline
  adapters self-register lazily.
- **Go adapter** (`auto-run.adapters.go`): treesitter discovery
  (injections disabled) of `func Test*`/`Example*` (excluding
  `TestMain`) plus `t.Run` subtests nested arbitrarily; primary-root
  policy for nested modules (nearest `go.mod`, promoted to an
  enclosing `go.work`, memoized); `go test -json` runs with
  `^`-anchored slash-split `-run` regexes (test), top-level
  alternation (file), and `./rel/...` package patterns (dir); the
  `-json` stream lands in the per-run `stdout` file and parses back
  to position ids via `(import path, reported name)`; an existing
  kind=test config's effective `build_flags` + composed env apply to
  every adapter run (gobugger `run_test` parity).
- **Jest adapter** (`auto-run.adapters.jest`): treesitter discovery
  of `describe` (namespace) and `it`/`test` (+ `fdescribe`/`xit`/…
  aliases and `.only`/`.skip`/`.todo`/`.failing` modifiers) across
  js/jsx/ts/tsx; one root per `package.json` (memoized); runs the
  project-local `node_modules/.bin/jest` (package dir first, hoisted
  parents up to the worktree) with `--json --outputFile=<per-run
  file>` and a regex-escaped ancestor-joined `--testNamePattern`;
  results parse from the output file via `ancestorTitles` + `title`.
- **Discovery core** (`auto-run.discovery`, ADR §7): position tree
  `dir → file → namespace → test` with ids `path::ns::name` and a
  flat `_nodes` map (O(1) lookup); worktree-anchored via
  `resolve_run_dirs()` (never getcwd); the walk prunes hidden dirs,
  `list_child_repos()`'s known child repos AND any dir carrying a
  `.git` entry (dir or gitfile) independently; open-buffers default
  discovery (BufReadPost parse + BufWritePost re-parse) plus a
  bounded, cancelable, chunked full `scan()` — caps (default 5,000
  candidate files / 200 roots, `discovery.max_*` config) abort with
  a structured cap report + warn log, a second scan / worktree
  switch / `cancel()` supersedes the in-flight walk, and re-scans
  skip unchanged files via a per-file mtime cache; core-side upward
  status aggregation + missing-result filling (unreported scope
  positions fill `skipped`, or `failed` when the runner died without
  reporting) and fallback decomposition (`build_spec` nil → dir →
  files → tests); `run_position()` routes through the exec job
  engine, `debug_position()` through the Phase 2 `dap.debug_test`
  path.
- **Events live**: `run.discovery:changed` (parse/scan) and
  `run.results:changed` (running marks + parsed results) now publish
  on the topics registered in Phase 1.
- **Mailbox** (ADR §11): `run.tests_list` (serializable position
  tree) and `run.results` (last results keyed by position id) go
  live; `run.test_run` gains the trust-gated `position` form
  (mutually exclusive with the Phase 2 `name` form, same `run.exec`
  capability, still force-incapable).
- **:AutoRun** gains `tests` (rendered position tree with status
  glyphs) and `scan` (bounded full scan with a printed report);
  `doctor` gains the test-discovery section (adapter roster,
  per-adapter root at the anchor, discovery snapshot).
- **Config**: `discovery = { max_files = 5000, max_roots = 200,
  open_buffers = true }`.

## [v0.1.0] — 2026-07-06

ADR-0048 Phases 1–2 — core store + env engine, execution + DAP.
Lector-reviewed: two implementation reviews (`change_requested`) with
all five findings fixed and re-reviewed `approved` at `17caebe`
(shell-quoted sourced env files, fatal `overrides_corrupt`
diagnostics, term env cleanup hooks, breakpoint-store error
surfacing, `command_env` timeout). Smoke 315/0.

### Added (Phase 2 — execution + DAP)

- **Job engine** (`auto-run.exec.job`, ADR §6): `vim.system`-based
  async jobs with per-run dirs under
  `stdpath("cache")/auto-run/runs/<run-id>/` (streamed `stdout` +
  `stderr` files and a separate machine-readable `result.json`),
  session job table (`list`/`stop` see ONLY jobs auto-run started —
  foreign pids unreachable by construction), `run.job:started` /
  `run.job:exited` events, env from the Phase 1 composition pipeline,
  NO default timeout for user-launched runs. Job records/events never
  carry env values.
- **Strategies** (`auto-run.exec.strategies`, ADR §6/OQ4): kind →
  default strategy (run→`run`, debug→`dap`, test→`dap` when
  debugging / `run` for a plain test run) with per-launch override;
  `term` strategy behind a provider interface —
  `register_terminal_provider(fn)` preferred, `auto-agents.term`
  capability-probed at launch, plain split + `jobstart(term=true)`
  fallback. Composed env reaches terminals as a materialized 0600
  env-file reference (never values on a rendered command line).
- **Exec facade** (`auto-run.exec`): `start(name, opts)`,
  `test_run(name, opts)` (Phase 2 scope: kind=test CONFIGS — plain
  `go test` on the configured package, or the dap-go debug-test path
  with `debug = true`), `stop(id)`, `list()`, `run_last()`,
  mode-filtered `pick_config` with per-repo pick memory (shared-tier
  `state.json` — gobugger session-pick parity), one-shot
  `set_next_profile()`.
- **DAP bridge** (`auto-run.dap`, ADR §6): registers
  `dap.providers.configs["auto-run"]` (never mutates
  `dap.configurations`) emitting lazy function-valued fields;
  effective-config → dap-config translation (go first-class, generic
  passthrough for other runtimes); `debug_test` parity with
  gobugger's `dap_go.debug_test(cfg)` merge (buildFlags + composed
  env incl. env_files); `attach()` (dap-go "Attach" PID picker) +
  `attach_remote(port?)` (connect-only `go_attach` server adapter,
  default port 2345); winfixbuf guard before `event_stopped`;
  dap-view auto open/close wiring; failed-start stderr capture with
  scratch-buffer replay (`:AutoRun last-error`);
  `run.session:changed` events.
- **Breakpoint persistence** (`auto-run.dap.breakpoints`, ADR §9
  incl. r3): store ALWAYS at
  `resolve_run_dirs().shared .. "/breakpoints.json"` (one per repo,
  both layouts), records worktree-RELATIVE so one saved set
  rehydrates in any sibling worktree; auto-run API mutations persist
  synchronously; **reconcile sweep** diffs `dap.breakpoints.get()`
  against the store at debounced CursorHold, BufWritePost (buffers
  with known breakpoints), dap session start/stop, and a synchronous
  VimLeavePre flush; restore on BufReadPost via
  `dap.breakpoints.set` with stale-lnum records dropped + warn-logged;
  tunable `breakpoint_sync = { cursorhold = true, interval_ms = nil }`
  (session-boundary + exit flushes stay active even when disabled).
- **Keymaps** (`auto-run.keymaps.default_keymaps()`, ADR §10):
  `<leader>r*` run/test namespace + slimmed `<leader>d*` debug
  namespace + F7–F10, provenance-commented, pcall-gated per
  dependency, desc strings on everything (table in the README).
- **Execution mailbox verbs** (ADR §11): trust-gated `run.start`,
  `run.test_run`, `run.debug_start` (`auto-core.trust` capability
  `run.exec`, checked against the config name; the mailbox path is
  hard-wired force-incapable — no schema carries a force/bypass
  flag); UNGATED `run.stop` (only ever terminates jobs auto-run
  started; foreign ids → not_found); read-only `run.jobs`;
  `run.status` now includes live jobs.
- **`:AutoRun {run|debug|test|stop|jobs|last-error}`** subcommands
  with config-name/run-id completion; `doctor` gains dap-adapter
  health (dap/dap-go/dap-view presence, adapter roster, provider
  registration) + breakpoint-store stats + live-jobs snapshot (§13).
- `tests/smoke.lua` extended to 270 assertions: job engine
  end-to-end, strategy resolution + terminal-provider probe,
  trust-gated exec verbs (untrusted → structured error; ack+enable →
  runs; ungated stop; foreign-id refusal; schema force-flag audit),
  breakpoint persistence against REAL nvim-dap, reconcile sweep +
  sync tunables, stale-line drop, two-worktree rehydration.

### Added (Phase 1 — core store + env engine)

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
  `run.set_dir`, `run.import`.
- **Event topics** (ADR §12): the seven `run.*` topics registered via
  `auto-core.events.register_topics("auto-run.nvim", …)` on setup.
- **`:AutoRun {list|show|validate|import|doctor|set-dir}`** user
  command with completion; `doctor` prints the resolver output for
  the current anchor (both tiers, origin, override state,
  read-through).
- `tests/smoke.lua` — headless suite covering all of the above
  (169 assertions at the Phase 1 gate).

### Requirements

- Neovim ≥ 0.10, auto-core.nvim ≥ v0.1.61
  (`events.register_topics` + `auto-core.trust`).
- Optional (Phase 2 dap surface): nvim-dap (dap strategy, breakpoint
  persistence), nvim-dap-go (debug-test + attach), nvim-dap-view
  (auto open/close UI). Everything degrades to quiet no-ops /
  structured errors when absent.