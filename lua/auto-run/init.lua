---auto-run — unified run-config / test / debug plugin (ADR-0048).
---
---Phase 1 surface: the two-tier `.auto-run/` store + resolver
---(`auto-run.store`), the substitution + env-profile pipeline
---(`auto-run.env`), launch.json interop (`auto-run.import`), and the
---read/mutate/stop-tier `run.*` mailbox verbs
---(`auto-run.mailbox.commands`). Execution, DAP, discovery, and
---keymaps arrive in Phases 2–3.
---
---auto-run consumes auto-core primitives ONLY (`fs.atomic`, `state`,
---`events`, `git.worktree`/`git.repo`, `trust`, `log`,
---`mailbox.commands`) and never re-derives shared state
---([[auto-family-state-ownership]]).
---
---Phase 1 IO note: every persisted write in this plugin is a
---synchronous atomic write (fs.atomic / the env module's private
---0600 writer) — there is no plugin-owned deferred IO to flush on
---VimLeavePre. The `auto-run` state namespace (dir overrides,
---known-dirs registry) is debounced by auto-core.state, which owns
---its own VimLeavePre flush. Any future deferred writer added here
---MUST register its own flush per [[auto-core-maintenance]] #9.
---@module 'auto-run'

local M = {}

M.version = "0.1.0"

---@type boolean
M._initialized = false

-- ── event topics (ADR-0048 §12) ────────────────────────────────

---The seven run.* topics auto-run owns. Registered via
---`auto-core.events.register_topics` on setup (idempotent).
M.TOPICS = {
  ["run.config:changed"] = {
    doc     = "A run config / profile / store dir changed (add, update, remove, set_dir).",
    payload = "{ name?: string, action: 'add'|'update'|'remove'|'set_dir', tier?: string, layer?: string, shared?: string, origin?: string }",
  },
  ["run.job:started"] = {
    doc     = "A run/test job started (Phase 2 execution engine).",
    payload = "{ id: string, config: string, strategy: 'run'|'term'|'dap', pid?: integer }",
  },
  ["run.job:exited"] = {
    doc     = "A run/test job exited (Phase 2 execution engine).",
    payload = "{ id: string, config: string, code: integer, signal?: integer }",
  },
  ["run.results:changed"] = {
    doc     = "Parsed test results changed for one or more positions (Phase 3).",
    payload = "{ root: string, positions: table<string, { status: string, duration_ms?: number }> }",
  },
  ["run.session:changed"] = {
    doc     = "A DAP session started / stopped / changed state (Phase 2).",
    payload = "{ id: string, config?: string, state: string }",
  },
  ["run.breakpoints:changed"] = {
    doc     = "The persisted breakpoint store changed (Phase 2).",
    payload = "{ path?: string, count: integer, action: 'add'|'remove'|'clear'|'reconcile' }",
  },
  ["run.discovery:changed"] = {
    doc     = "Test discovery produced/updated a position tree (Phase 3).",
    payload = "{ root: string, files: integer, positions: integer }",
  },
}

-- ── resolver-cache invalidation subscriptions ──────────────────
-- Slot-replace pattern: keep the live handles module-local and
-- unsubscribe before re-subscribing so repeated setup() calls never
-- stack duplicate subscribers (and never boolean-gate a subscribe —
-- the gate would mask bus resets).

---@type table[]
local _subs = {}

local function resubscribe(events)
  for _, handle in ipairs(_subs) do
    pcall(events.unsubscribe, handle)
  end
  _subs = {}
  local paths = require("auto-run.store.paths")
  for _, topic in ipairs({
    "core.active_worktree:changed",
    "core.workspace_root:changed",
  }) do
    _subs[#_subs + 1] = events.subscribe(topic, function()
      paths.invalidate()
    end)
  end
end

-- ── setup ───────────────────────────────────────────────────────

---Attach the Phase 1 subsystems. Idempotent — safe to call from
---every plugin-manager reload. Returns `(true)` on success or
---`(nil, err)` when auto-core is missing/too old; never notifies.
---@param opts table?  see `auto-run.config`
---@return boolean? ok, string? err
function M.setup(opts)
  local okc, core = pcall(require, "auto-core")
  if not okc or type(core) ~= "table" then
    return nil, "auto-run requires auto-core.nvim (>= v0.1.61)"
  end

  require("auto-run.config").setup(opts)

  -- Topic registration (§12). register_topics is idempotent for the
  -- same plugin; a too-old auto-core (< v0.1.61) lacks the API.
  if type(core.events) ~= "table"
      or type(core.events.register_topics) ~= "function"
      or type(core.trust) ~= "table" then
    return nil, "auto-run requires auto-core >= v0.1.61 "
      .. "(events.register_topics + auto-core.trust)"
  end
  local okt, terr = pcall(core.events.register_topics, "auto-run.nvim", M.TOPICS)
  if not okt then
    require("auto-run.log").warn("setup",
      "register_topics failed: " .. tostring(terr))
  end

  -- Resolver re-anchoring on workspace / worktree switches (§2.1).
  resubscribe(core.events)
  require("auto-run.store.paths").invalidate()

  -- Mailbox verbs — registered when the auto-core mailbox surface is
  -- present (the registry accepts registrations independent of
  -- transport configuration; verbs become reachable once the host
  -- configures the mailbox).
  if type(core.mailbox) == "table" and type(core.mailbox.commands) == "table" then
    require("auto-run.mailbox.commands").register_all()
  end

  -- Materialized-env startup sweep (§4.1). Best-effort + silent.
  pcall(function() require("auto-run.env").sweep() end)

  M._initialized = true
  return true
end

-- ── public facade ───────────────────────────────────────────────

---Lazy sub-module accessors so `require("auto-run").store` works
---without forcing load order at require time.
setmetatable(M, {
  __index = function(_, key)
    if key == "store" then return require("auto-run.store") end
    if key == "env" then return require("auto-run.env") end
    if key == "import" then return require("auto-run.import") end
    if key == "log" then return require("auto-run.log") end
    if key == "config" then return require("auto-run.config").options end
    return nil
  end,
})

return M