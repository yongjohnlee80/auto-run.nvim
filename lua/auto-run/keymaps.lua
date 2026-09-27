---auto-run.keymaps — the default keymap set (ADR 0199 §4.2, amending
---ADR-0048 §10).
---
---`<leader>r` LAUNCHES — lowercase runs, the same letter UPPERCASE debugs:
---  rt / rT  nearest test          rf / rF  current file (rF: choose a test in it)
---  rp / rP  pick an entry point   rl / rL  again (the last run / debug)
---`<leader>d` controls what is running: dc resume (never launches), di / do /
---dO step into / over / out, db dB dC breakpoints, dq dR terminate / restart,
---dv dw de view / watch / evaluate; da / dA (delve attach) in go buffers only.
---F-keys unchanged. `<leader>r` is auto-run's alone: remote-sync.nvim's keys
---live under `<leader>R`.
---
---Not keys (moved): new configs → the panes' `a` (adapters.scaffold); the env
---profile → `:AutoRun env profile`; doctor → `:AutoRun doctor`; the last DAP
---failure → `:AutoRun doctor --last-error`; worktree repair → `--fix`.
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
            "no kind=test configs — `a` in the tests pane creates one")
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

  local function log() return require("auto-run.log") end

  ---Pick an entry point (any kind) and hand it to `launch` — the picker with
  ---per-repo pick memory the commands use.
  ---@param kinds string[]
  ---@param launch fun(name: string): any, string?
  local function pick_and(kinds, launch)
    exec().pick_config(kinds, function(name, reason)
      if not name then
        if reason == "no_matches" then
          log().warn("keymaps", "no configs — `a` in the debug pane creates one, :AutoRun import reads launch.json")
        end
        return
      end
      local _, err = launch(name)
      if err then log().error("keymaps", err) end
    end)
  end

  -- ── <leader>r — launch: lowercase runs, UPPERCASE debugs (ADR 0199 §4.2)

  -- rt — run the nearest test. Discovery position nearest the cursor, run
  -- through the position engine; buffers no adapter claims fall back to the
  -- kind=test config path.
  bind("n", "<leader>rt", function()
    local node, fall_back = nearest_or_fallback()
    if node then
      local _, err = discovery().run_position(node.id)
      if err then log().error("keymaps", err) end
      return
    end
    if fall_back then fallback_test_run({}) end
  end, "Run: Nearest Test")

  -- rf — run the current test file (the file position; same fallback).
  bind("n", "<leader>rf", function()
    local node, fall_back = nearest_or_fallback()
    if node then
      -- File-position id = the file's absolute path.
      local _, err = discovery().run_position(node.path)
      if err then log().error("keymaps", err) end
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

  -- rF — choose a test in THIS file to debug. No adapter debugs a whole file
  -- (debug_position takes one test), so this offers the file's tests.
  bind("n", "<leader>rF", function()
    local node = discovery().nearest(0)
    if not node then
      log().warn("keymaps", "no discovered tests in this file")
      return
    end
    local file = discovery().tree():get(node.path)
    local tests = {}
    local function walk(n)
      for _, c in ipairs(n and n.children or {}) do
        if c.type == "test" then tests[#tests + 1] = c end
        walk(c)
      end
    end
    walk(file)
    if #tests == 0 then
      log().warn("keymaps", "no discovered tests in this file")
      return
    end
    vim.ui.select(tests, {
      prompt = "Debug which test?",
      format_item = function(t) return t.id:sub(#node.path + 3) end,
    }, function(t)
      if not t then return end
      local _, err = discovery().debug_position(t.id)
      if err then log().error("keymaps", err) end
    end)
  end, "Debug: Choose a Test in This File")

  -- rp / rP — pick an entry point and run / debug it, dispatching on its kind
  -- (exec.run_config / dap.debug_config — the rule :AutoRun run/debug use).
  bind("n", "<leader>rp", function()
    pick_and({ "run", "test", "debug" }, function(name) return exec().run_config(name) end)
  end, "Run: Pick an Entry Point")
  bind("n", "<leader>rP", function()
    pick_and({ "debug", "run", "test" }, function(name) return bridge().debug_config(name) end)
  end, "Debug: Pick an Entry Point")

  -- rl / rL — again: the last run / debug that actually launched, from any
  -- surface (auto-run.last). rL falls back to nvim-dap's own run_last when
  -- auto-run has launched no debug yet.
  bind("n", "<leader>rl", function()
    local _, err = require("auto-run.last").replay("run")
    if err then log().warn("keymaps", err) end
  end, "Run: Again (last run)")
  bind("n", "<leader>rL", function()
    local last = require("auto-run.last")
    if not last.peek("debug") and dap_ok and type(dap.run_last) == "function" then
      return dap.run_last()
    end
    local _, err = last.replay("debug")
    if err then log().warn("keymaps", err) end
  end, "Debug: Again (last debug)")

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

    -- dc — RESUME ONLY (ADR 0199 §4.2). It used to resume a session or launch
    -- one, and every failure in the 2026-09-23 manual verification began with
    -- the launch branch. With no session it launches nothing and names the
    -- keys that start one. `dap.session` / `dap.continue` are looked up at
    -- keypress time, never captured at bind time.
    bind("n", "<leader>dc", function()
      if require("dap").session() then return require("dap").continue() end
      log().info("keymaps", "no debug session — start one with <leader>rT (a test) or <leader>rP (an entry point)")
    end, "Debug: Continue (resume only)")

    -- di / do / dO — stepping without F-keys (Requirement 3: some keyboards
    -- have none). F7 / F8 / F10 stay as registered.
    bind("n", "<leader>di", function() require("dap").step_into() end, "Debug: Step Into")
    bind("n", "<leader>do", function() require("dap").step_over() end, "Debug: Step Over")
    bind("n", "<leader>dO", function() require("dap").step_out() end, "Debug: Step Out")

    -- <leader>dq / dR — terminate / restart  [provenance: kept]
    -- Terminate must also abort an in-flight debug PREPARATION (e.g. a Cargo
    -- build that has not produced a DAP session yet): without this, the user's
    -- terminate gesture leaves an orphaned build running and only a subsequent
    -- launch would supersede it (ADR 0194 §2.3.4 cancellation ownership).
    bind("n", "<leader>dq", function()
      bridge().cancel_launch()
      dap.terminate()
    end, "Debug: Terminate")
    bind("n", "<leader>dR", function()
      bridge().cancel_launch()
      dap.restart()
    end, "Debug: Restart")
  end

  -- rT — debug the nearest test. Resolution and the fallback contract come
  -- from `nearest_or_fallback()` — the SAME owner rt and rf use — so all three
  -- agree on what "not discovery material" means (no_adapter / no_file fall
  -- back to the config path; every other reason is a warn-logged stop).
  --
  -- The fallback ends in dap-go's `debug_test`, which debugs the GO test at
  -- the cursor, so it must only ever be reached for an UNCLAIMED buffer: a
  -- claimed buffer with no test at the cursor is not a reason to hand a Rust
  -- or jest file to the Go debugger.
  bind("n", "<leader>rT", function()
    local node, fall_back = nearest_or_fallback()
    -- Any discovered test position routes through debug_position, which
    -- dispatches by the adapter's debug capability (ADR 0194 §2.3.3).
    if node and node.type == "test" then
      local _, err = discovery().debug_position(node.id)
      if err then log().error("keymaps", err) end
      return
    end
    if not fall_back then
      if node then log().warn("keymaps", "no test position at the cursor") end
      return
    end
    exec().pick_config("test", function(name, reason)
      if reason == "cancelled" then return end
      -- No kind=test configs → dap-go defaults (cursor test, no overrides).
      local _, err = bridge().debug_test(name)
      if err then log().error("keymaps", err) end
    end)
  end, "Debug: Nearest Test")

  -- da / dA — delve attach (PID / remote dlv server): GO BUFFERS ONLY. They
  -- are delve-specific, so a global binding offered them in every buffer.
  if dap_ok then
    local function attach_keys(buf)
      local function bufbind(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc })
      end
      if pcall(require, "dap-go") then
        bufbind("<leader>da", function()
          local _, err = bridge().attach()
          if err then log().warn("keymaps", err) end
        end, "Debug: Attach to Process (delve)")
      end
      bufbind("<leader>dA", function()
        local _, err = bridge().attach_remote()
        if err then log().warn("keymaps", err) end
      end, "Debug: Attach to Remote dlv Server")
    end
    vim.api.nvim_create_autocmd("FileType", {
      group = vim.api.nvim_create_augroup("auto-run.keymaps.go-attach", { clear = true }),
      pattern = "go",
      callback = function(ev) attach_keys(ev.buf) end,
    })
    -- Go buffers already open when the keymaps are installed (a restored
    -- session) get them too; the autocmd only sees buffers opened later.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "go" then attach_keys(buf) end
    end
  end

  -- <leader>dv / dw / de — dap-view / watch / eval  [provenance: kept]
  if dv_ok then
    bind("n",          "<leader>dv", dv.toggle,   "Debug: Toggle View")
    bind({ "n", "v" }, "<leader>dw", dv.add_expr, "Debug: Watch Expr (add)")
    bind({ "n", "v" }, "<leader>de", dv.eval,     "Debug: Evaluate")
  end

end

return M