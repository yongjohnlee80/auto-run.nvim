---auto-run — unified run-config / test / debug plugin (ADR-0048).
---
---Phase 1 surface: the two-tier `.auto-run/` store + resolver
---(`auto-run.store`), the substitution + env-profile pipeline
---(`auto-run.env`), launch.json interop (`auto-run.import`), and the
---read/mutate `run.*` mailbox verbs (`auto-run.mailbox.commands`).
---
---Phase 2 surface: the execution engine (`auto-run.exec` — jobs,
---strategies, terminal provider), the DAP bridge (`auto-run.dap` —
---provider registration, debug_test parity, attach flows, UI
---wiring), breakpoint persistence + reconcile sweep
---(`auto-run.dap.breakpoints`), the §10 keymaps
---(`auto-run.keymaps`), and the trust-gated execution verbs.
---
---Phase 3 surface (auto-run half): the test-adapter registry
---(`auto-run.adapters` — go + jest baseline, `register_adapter()`
---for third parties) and the discovery core (`auto-run.discovery` —
---position tree, bounded cancelable scans, results aggregation,
---position execution). The auto-finder tests/debug views live in
---auto-finder.nvim.
---
---auto-run consumes auto-core primitives ONLY (`fs.atomic`, `state`,
---`events`, `git.worktree`/`git.repo`, `trust`, `log`,
---`mailbox.commands`) and never re-derives shared state
---([[auto-family-state-ownership]]).
---
---IO note: every persisted write in this plugin is a synchronous
---atomic write (fs.atomic / the env module's private 0600 writer).
---The one plugin-owned deferred writer — the breakpoint reconcile
---debounce — registers its own synchronous VimLeavePre flush per
---[[auto-core-maintenance]] #9 (see `auto-run.dap.breakpoints`).
---The `auto-run` state namespace (dir overrides, known-dirs
---registry) is debounced by auto-core.state, which owns its own
---VimLeavePre flush.
---@module 'auto-run'

local M = {}

M.version = "0.1.10"

---@type boolean
M._initialized = false

-- ── event topics (ADR-0048 §12) ────────────────────────────────

---The eight run.* topics auto-run owns. Registered via
---`auto-core.events.register_topics` on setup (idempotent).
M.TOPICS = {
  ["run.config:changed"] = {
    doc     = "A run config / profile / store dir changed, or the selected launch config (Config section) changed.",
    payload = "{ name?: string, action: 'add'|'update'|'remove'|'set_dir'|'selected'|'export', tier?: string, layer?: string, shared?: string, origin?: string, path?: string }",
  },
  ["run.job:started"] = {
    doc     = "A run/test job started (exec engine, §6).",
    payload = "{ id: string, config: string, strategy: 'run'|'term'|'dap', pid?: integer }",
  },
  ["run.job:exited"] = {
    doc     = "A run/test job exited (exec engine, §6).",
    payload = "{ id: string, config: string, code: integer, signal?: integer }",
  },
  ["run.results:changed"] = {
    doc     = "Parsed test results changed for one or more positions (Phase 3).",
    payload = "{ root: string, positions: table<string, { status: string, duration_ms?: number }> }",
  },
  ["run.session:changed"] = {
    doc     = "A DAP session started / stopped / changed state (dap bridge, §6).",
    payload = "{ id: string, config?: string, state: string }",
  },
  ["run.breakpoints:changed"] = {
    doc     = "The persisted breakpoint store changed (§9).",
    payload = "{ path?: string, count: integer, action: 'add'|'remove'|'clear'|'reconcile' }",
  },
  ["run.discovery:changed"] = {
    doc     = "Test discovery produced/updated a position tree (Phase 3).",
    payload = "{ root: string, files: integer, positions: integer }",
  },
  ["run.env:changed"] = {
    doc     = "The env-file selection or an env file's contents changed (§4.2, r5). Payloads carry the path + KEY name only — env VALUES never enter events.",
    payload = "{ action: 'selected'|'updated'|'added', path?: string, key?: string }",
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

  -- Phase 2: DAP bridge (quiet no-op without nvim-dap) + breakpoint
  -- persistence sync points (autocmds always; dap listeners when
  -- nvim-dap is present).
  require("auto-run.dap").setup()
  require("auto-run.dap.breakpoints").setup()

  -- Phase 3: test discovery — open-buffer parse autocmds + scan
  -- cancelation on worktree/workspace switches (§7).
  require("auto-run.discovery").setup()

  M._initialized = true
  return true
end

---Register the ADR-0048 §10 default keymaps (`<leader>r*`,
---`<leader>d*`, F7–F10). Call after `setup()`.
function M.default_keymaps()
  require("auto-run.keymaps").default_keymaps()
end

-- ── public facade ───────────────────────────────────────────────

---Lazy sub-module accessors so `require("auto-run").store` works
---without forcing load order at require time.
setmetatable(M, {
  __index = function(_, key)
    if key == "store" then return require("auto-run.store") end
    if key == "env" then return require("auto-run.env") end
    if key == "import" then return require("auto-run.import") end
    if key == "exec" then return require("auto-run.exec") end
    if key == "adapters" then return require("auto-run.adapters") end
    if key == "discovery" then return require("auto-run.discovery") end
    if key == "dap" then return require("auto-run.dap") end
    if key == "breakpoints" then return require("auto-run.dap.breakpoints") end
    if key == "keymaps" then return require("auto-run.keymaps") end
    if key == "log" then return require("auto-run.log") end
    if key == "config" then return require("auto-run.config").options end
    return nil
  end,
})

return M