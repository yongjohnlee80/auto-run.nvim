---auto-run.keymaps — the ADR-0048 §10 default keymap set.
---
---Namespace split: `<leader>r` = run/test (new), `<leader>d` =
---debug/DAP only (slimmed). F-keys unchanged. Dropped from keymaps
---per §10 (moved to panel/commands): `dL` reload (store
---auto-reloads), `dE` last error (`:AutoRun last-error`), `dF`
---fix-worktree (`:AutoRun doctor --fix`), scaffold keys.
---
---Call `default_keymaps()` after `setup()`. Every binding is
---pcall-gated on its dependency (gobugger's defensive bind pattern):
---lazy bootstrap order isn't guaranteed to init every dap module
---before this runs, so bindings whose target is nil are skipped
---instead of crashing the whole pass. Override individual maps
---afterwards with `vim.keymap.set` (your call wins since it runs
---last).
---@module 'auto-run.keymaps'

local M = {}

---Register the §10 keymap table. Idempotent (vim.keymap.set
---replaces).
function M.default_keymaps()
  local dap_ok, dap = pcall(require, "dap")
  local dv_ok, dv = pcall(require, "dap-view")
  -- dap-go only gates whether <leader>da is wired (the Attach config
  -- comes out of dap.configurations.go).
  local dg_ok = pcall(require, "dap-go")

  ---Skip any binding whose target is nil instead of crashing the
  ---whole default_keymaps pass (gobugger's defensive bind).
  local function bind(mode, lhs, rhs, desc)
    if type(rhs) ~= "function" and type(rhs) ~= "string" then return end
    vim.keymap.set(mode, lhs, rhs, { desc = desc })
  end

  local function exec() return require("auto-run.exec") end
  local function bridge() return require("auto-run.dap") end
  local function bps() return require("auto-run.dap.breakpoints") end
  local function discovery() return require("auto-run.discovery") end

  ---Nearest discovered position for the current buffer, with the
  ---Phase 4 fallback contract: `(node)` when discovery resolves one;
  ---`(nil, true)` when the buffer isn't discovery material (no
  ---adapter claims it / no file) — callers fall back to the Phase 2
  ---config path with a hint; `(nil, false)` after a warn-logged
  ---discovery error (no fallback — the buffer IS a test file).
  ---@return table? node, boolean? fall_back
  local function nearest_or_fallback()
    local node, nerr, reason = discovery().nearest(0)
    if node then return node, nil end
    if reason == "no_adapter" or reason == "no_file" then
      require("auto-run.log").info("keymaps", tostring(nerr)
        .. " — falling back to the kind=test config path")
      return nil, true
    end
    require("auto-run.log").warn("keymaps", tostring(nerr))
    return nil, false
  end

  ---Shared Phase 2 fallback: pick a kind=test config and run it
  ---(`opts` reach exec.test_run — package/test_name overrides).
  ---@param opts table
  local function fallback_test_run(opts)
    exec().pick_config("test", function(name, reason)
      if not name then
        if reason == "no_matches" then
          require("auto-run.log").warn("keymaps",
            "no kind=test configs — scaffold one with <leader>rc")
        end
        return
      end
      local _, err = exec().test_run(name, opts)
      if err then require("auto-run.log").error("keymaps", err) end
    end)
  end

  -- ── F-keys (kept, unchanged — §10) ─────────────────────────────
  if dap_ok then
    bind("n", "<F9>",  dap.continue,  "Run: Continue / Start (dap)")   -- kept
    bind("n", "<F8>",  dap.step_over, "Run: Step Over (dap)")          -- kept
    bind("n", "<F7>",  dap.step_into, "Run: Step Into (dap)")          -- kept
    bind("n", "<F10>", dap.step_out,  "Run: Step Out (dap)")           -- kept
  end

  -- ── <leader>r — run/test (new namespace) ───────────────────────

  -- <leader>rr — run: pick config & run  [provenance: new]
  bind("n", "<leader>rr", function()
    exec().pick_config({ "run", "test", "debug" }, function(name, reason)
      if not name then
        if reason == "no_matches" then
          require("auto-run.log").warn("keymaps",
            "no run configs — scaffold one with <leader>rc or :AutoRun import")
        end
        return
      end
      local _, err = exec().start(name)
      if err then require("auto-run.log").error("keymaps", err) end
    end)
  end, "Run: Pick Config & Run")

  -- <leader>rl — run last  [provenance: gobugger `dr`]
  bind("n", "<leader>rl", function()
    local _, err = exec().run_last()
    if err then require("auto-run.log").warn("keymaps", err) end
  end, "Run: Run Last")

  -- <leader>rt — run nearest test  [provenance: new]
  -- Discovery position nearest the cursor, run through the Phase 3
  -- position engine (adapter build_spec → job → parsed results).
  -- Buffers no adapter claims fall back to the Phase 2 config path.
  bind("n", "<leader>rt", function()
    local node, fall_back = nearest_or_fallback()
    if node then
      local _, err = discovery().run_position(node.id)
      if err then require("auto-run.log").error("keymaps", err) end
      return
    end
    if fall_back then fallback_test_run({}) end
  end, "Run: Nearest Test")

  -- <leader>rf — run current test file  [provenance: new]
  -- The current file's FILE position (nearest() resolves the file
  -- node's path even when the cursor sits inside a test). Same
  -- fallback contract as <leader>rt.
  bind("n", "<leader>rf", function()
    local node, fall_back = nearest_or_fallback()
    if node then
      -- File-position id = the file's absolute path.
      local _, err = discovery().run_position(node.path)
      if err then require("auto-run.log").error("keymaps", err) end
      return
    end
    if fall_back then
      local opts = {}
      local file = vim.api.nvim_buf_get_name(0)
      if file ~= "" and not file:match("^%w+://") then
        opts.package = vim.fn.fnamemodify(file, ":h")
      end
      fallback_test_run(opts)
    end
  end, "Run: Current Test File")

  -- <leader>rp — pick env profile for next run  [provenance: new]
  bind("n", "<leader>rp", function()
    local store = require("auto-run.store")
    local profiles = {}
    for _, p in ipairs(store.list_profiles()) do profiles[#profiles + 1] = p.name end
    if #profiles == 0 then
      require("auto-run.log").warn("keymaps", "no env profiles in the store")
      return
    end
    table.insert(profiles, "(clear)")
    vim.ui.select(profiles, { prompt = "auto-run: profile for the next run" },
      function(choice)
        if not choice then return end
        exec().set_next_profile(choice ~= "(clear)" and choice or nil)
      end)
  end, "Run: Pick Env Profile for Next Run")

  -- <leader>rc — new run config (scaffold)  [provenance: gobugger `dM`/`dN` merged]
  bind("n", "<leader>rc", function()
    vim.ui.select({ "run", "test", "debug" },
      { prompt = "auto-run: config kind" }, function(kind)
        if not kind then return end
        vim.ui.input({ prompt = "config name: " }, function(name)
          if not name or name == "" then return end
          local store = require("auto-run.store")
          local path, err = store.add({
            name = name,
            kind = kind,
            runtime = "go",
            program = kind == "test" and "${worktree}" or "${worktree}/cmd/" .. name,
          })
          if not path then
            require("auto-run.log").error("keymaps", err)
            return
          end
          vim.cmd.edit(path)
        end)
      end)
  end, "Run: New Run Config (scaffold)")

  -- ── <leader>d — debug/DAP only (slimmed namespace) ─────────────

  if dap_ok then
    -- <leader>db / dB / dC — breakpoints  [provenance: kept]
    -- Routed through auto-run's API so mutations persist to the §9
    -- store synchronously.
    bind("n", "<leader>db", function()
      bps().toggle()
    end, "Debug: Toggle Breakpoint")
    bind("n", "<leader>dB", dap.set_breakpoint and function()
      bps().set({ condition = vim.fn.input("Breakpoint condition: ") })
    end, "Debug: Conditional Breakpoint")
    bind("n", "<leader>dC", function()
      bps().clear_all()
    end, "Debug: Clear Breakpoints")

    -- <leader>dc — continue/start (dap)  [provenance: kept]
    bind("n", "<leader>dc", dap.continue, "Debug: Continue / Start")

    -- <leader>dq / dR — terminate / restart  [provenance: kept]
    bind("n", "<leader>dq", dap.terminate, "Debug: Terminate")
    bind("n", "<leader>dR", dap.restart,   "Debug: Restart")
  end

  -- <leader>dt — debug nearest test  [provenance: gobugger `dt`]
  -- Same nearest resolution as <leader>rt, routed through
  -- debug_position for go test positions (jump + dap-go debug_test
  -- with the repo's kind=test config merged in). Anything else —
  -- non-go positions, undiscovered buffers — takes the Phase 2
  -- config path (dap-go cursor selection).
  bind("n", "<leader>dt", function()
    local node = discovery().nearest(0)
    if node and node.type == "test" and node.adapter == "go" then
      local _, err = discovery().debug_position(node.id)
      if err then require("auto-run.log").error("keymaps", err) end
      return
    end
    exec().pick_config("test", function(name, reason)
      if reason == "cancelled" then return end
      -- No kind=test configs → dap-go defaults (gobugger's
      -- fall-through: cursor test, no buildFlags/env overrides).
      local _, err = bridge().debug_test(name)
      if err then require("auto-run.log").error("keymaps", err) end
    end)
  end, "Debug: Nearest Test")

  -- <leader>dm — debug entry point (pick)  [provenance: gobugger `dm`]
  bind("n", "<leader>dm", function()
    exec().pick_config("debug", function(name, reason)
      if not name then
        if reason == "no_matches" then
          require("auto-run.log").warn("keymaps",
            "no kind=debug configs — scaffold one with <leader>rc")
        end
        return
      end
      local _, err = bridge().debug_start(name)
      if err then require("auto-run.log").error("keymaps", err) end
    end)
  end, "Debug: Entry Point (pick)")

  -- <leader>da — attach PID  [provenance: kept]
  if dg_ok then
    bind("n", "<leader>da", function()
      local _, err = bridge().attach()
      if err then require("auto-run.log").warn("keymaps", err) end
    end, "Debug: Attach to Process (delve)")
  end

  -- <leader>dA — attach remote  [provenance: kept]
  if dap_ok then
    bind("n", "<leader>dA", function()
      local _, err = bridge().attach_remote()
      if err then require("auto-run.log").warn("keymaps", err) end
    end, "Debug: Attach to Remote dlv Server")
  end

  -- <leader>dv / dw / de — dap-view / watch / eval  [provenance: kept]
  if dv_ok then
    bind("n",          "<leader>dv", dv.toggle,   "Debug: Toggle View")
    bind({ "n", "v" }, "<leader>dw", dv.add_expr, "Debug: Watch Expr (add)")
    bind({ "n", "v" }, "<leader>de", dv.eval,     "Debug: Evaluate")
  end

  -- <leader>dD — doctor  [provenance: gobugger `dD`]
  bind("n", "<leader>dD", function()
    vim.cmd("AutoRun doctor")
  end, "Debug: Doctor")
end

return M