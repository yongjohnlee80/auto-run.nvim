---auto-run.config — plugin options (NOT run configurations).
---
---Run configs live in the two-tier `.auto-run/` store (ADR-0048 §2)
---and are managed by `auto-run.store`; this module only holds the
---plugin-level knobs that shape how auto-run itself behaves.
---@module 'auto-run.config'

local M = {}

---@class AutoRunOptions
M.defaults = {
  ---Environment-materialization settings (ADR-0048 §4.1).
  env = {
    ---Directory for materialized env files. nil resolves at runtime
    ---to `stdpath("cache") .. "/auto-run/env"` — NEVER inside a repo.
    dir = nil,
    ---Startup sweep removes materialized files older than this many
    ---hours. run-strategy files are deleted on job exit and
    ---term-strategy files on provider failure or via the provider's
    ---`spec.on_exit` cleanup hook — a term provider that accepts a
    ---launch but never signals exit leaves its file to this sweep
    ---(crash-leftover safety net, ADR-0048 §4.1).
    sweep_max_age_hours = 24,
    ---Per-entry timeout (ms) for trust-gated `command_env` commands
    ---during composition. A timeout fails composition with
    ---code=command_env_timeout for required entries and warns +
    ---skips for `required = false`.
    command_timeout_ms = 10000,
  },
  ---launch.json interop (ADR-0048 §5).
  import = {
    ---Relative candidates checked at each level of the upward walk
    ---(worktree root up to — and including — the bare-repo container,
    ---which in a linked-worktree layout usually holds the shared
    ---`.vscode/` / `.config/`). `.config/launch.json` supports repos
    ---that keep editor config under `.config/` instead of `.vscode/`.
    launch_paths = { ".vscode/launch.json", ".config/launch.json", "launch.json" },
  },
  ---Store behavior.
  store = {
    ---Scaffold `<repo>/.auto-run/.gitignore` (ignoring `local/`) when
    ---creating the plain-repo shared tier.
    scaffold_gitignore = true,
  },
  ---Execution engine (ADR-0048 §6).
  exec = {
    ---Directory for per-run output dirs. nil resolves at runtime to
    ---`stdpath("cache") .. "/auto-run/runs"` — NEVER inside a repo.
    runs_dir = nil,
    ---auto-agents playground terminal slot used by the default
    ---auto-agents term-strategy provider (T1..T4).
    term_slot = 1,
  },
  ---Test discovery (ADR-0048 §7).
  discovery = {
    ---Full-scan hard caps (Lector should-fix #4). Hitting either cap
    ---aborts the scan with a structured cap report + warn log —
    ---never a silent degrade.
    max_files = 5000,   ---candidate files visited
    max_roots = 200,    ---distinct adapter roots discovered
    ---Parse open test buffers by default (BufReadPost) and re-parse
    ---on BufWritePost. false → discovery only via explicit scans.
    open_buffers = true,
  },
  ---DAP bridge (ADR-0048 §6).
  dap = {
    ---dap-view wiring: `true` → opinionated layout + auto open/close
    ---(gobugger parity); a table → passed to dap-view setup verbatim;
    ---`false` → no dap-view wiring at all.
    view = true,
  },
  ---Breakpoint reconcile-sweep tuning (ADR-0048 §9, r3 amendment).
  ---`cursorhold = false` disables the editing-time debounced sweep
  ---(CursorHold + BufWritePost); `interval_ms` adds a periodic sweep
  ---when set to a positive number. Session-boundary flushes (dap
  ---session start/stop) and the VimLeavePre exit flush stay active
  ---even when both are disabled.
  breakpoint_sync = {
    cursorhold = true,
    interval_ms = nil,
    ---Debounce window for the editing-time sweep triggers.
    debounce_ms = 500,
  },
}

---@type AutoRunOptions
M.options = vim.deepcopy(M.defaults)

---Merge user opts over the defaults. Re-merges from defaults each
---call so repeated `setup()` calls don't accrete state.
---@param opts table?
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M