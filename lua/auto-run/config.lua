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
    ---hours (crash leftovers; per-run files are deleted on job exit).
    sweep_max_age_hours = 24,
  },
  ---launch.json interop (ADR-0048 §5).
  import = {
    ---Relative candidates checked at each level of the upward walk.
    launch_paths = { ".vscode/launch.json", "launch.json" },
  },
  ---Store behavior.
  store = {
    ---Scaffold `<repo>/.auto-run/.gitignore` (ignoring `local/`) when
    ---creating the plain-repo shared tier.
    scaffold_gitignore = true,
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