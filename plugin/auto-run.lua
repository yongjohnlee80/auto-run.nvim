---plugin/auto-run.lua — :AutoRun user command.
---
---Six subcommands (ADR 0199 §4.1):
---  run [name]      run a config — a kind=test config runs as a test
---  debug [name]    debug a config — a kind=test config debugs the test at
---                  the cursor with that config's flags and env
---  stop [id]       stop a running job (no id: the only one, or choose)
---  env [select <path> | clear | profile [name|clear]]
---  doctor [--fix | --last-error]   diagnostics, config validation,
---                  worktree repair, the captured DAP failure output
---  import [name]   one-way launch.json onboarding into the store
---Listings the old subcommands printed (configs, jobs, the test tree) live
---in the tests and debug panes; set-dir's role moved to the panes'
---Active-worktree selector. `doctor --fix` runs `git worktree repair`
---from the repo common dir (interactive-only, never a mailbox verb).
---Output goes through
---print()/nvim_echo (user-invoked, not a main path); errors are
---echoed, never vim.notify'd.

if vim.g.loaded_auto_run then
  return
end
vim.g.loaded_auto_run = 1

local SUBCOMMANDS = { "run", "debug", "stop", "env", "doctor", "import" }

local function echo_lines(lines)
  print(table.concat(lines, "\n"))
end

local function echo_err(msg)
  vim.api.nvim_echo({ { "[auto-run] " .. tostring(msg), "ErrorMsg" } }, true, {})
end

local HANDLERS = {}

function HANDLERS.import(args)
  local import = require("auto-run.import")
  local name = args[1]
  local summary, err = import.import(name ~= "" and name or nil, {
    on_conflict = "skip",
  })
  if not summary then
    echo_err(err)
    return
  end
  local lines = { "auto-run import from " .. tostring(summary.source) }
  lines[#lines + 1] = "  imported: "
    .. (#summary.imported > 0 and table.concat(summary.imported, ", ") or "(none)")
  if #summary.skipped > 0 then
    lines[#lines + 1] = "  skipped (name exists — re-run per-entry with overwrite/rename): "
      .. table.concat(summary.skipped, ", ")
  end
  for from, to in pairs(summary.renamed) do
    lines[#lines + 1] = "  renamed: " .. from .. " → " .. to
  end
  for _, e in ipairs(summary.errors) do
    lines[#lines + 1] = "  error: " .. e
  end
  echo_lines(lines)
end

---Config validation lines for doctor (the report the removed validate subcommand printed).
---@return string[]
local function validation_lines()
  local report = require("auto-run.store").validate()
  local lines = { ("%d file(s) checked, %s"):format(
    report.checked, report.ok and "all OK" or (#report.issues .. " issue(s)")) }
  for _, issue in ipairs(report.issues) do
    lines[#lines + 1] = "  " .. issue.name
      .. (issue.tier and (" [" .. issue.tier .. "]") or "")
      .. (issue.file and (" (" .. issue.file .. ")") or "")
    for _, e in ipairs(issue.errors) do
      lines[#lines + 1] = "    - " .. e
    end
  end
  return lines
end

function HANDLERS.doctor(args)
  -- `--last-error`: the captured output of the last failed DAP start.
  if args and args[1] == "--last-error" then
    if not require("auto-run.dap").open_last_error() then
      echo_lines({ "auto-run: no captured dap failure output yet" })
    end
    return
  end
  -- `--fix`: gobugger fix_worktree port — `git worktree repair` from
  -- the repo's common dir. Interactive-only (mutating): reachable
  -- here and nowhere on the mailbox surface.
  if args and args[1] == "--fix" then
    local result, ferr = require("auto-run.doctor").fix_worktree()
    if not result then
      echo_err(ferr)
      return
    end
    echo_lines({
      "auto-run: git worktree repair @ " .. result.common
        .. (result.output ~= "" and ("\n" .. result.output) or ""),
    })
    return
  end

  local store = require("auto-run.store")
  local s = store.status()
  local function row(k, v) return ("%-16s %s"):format(k .. ":", tostring(v)) end
  local lines = {
    "auto-run doctor",
    "───────────────",
    row("anchor", s.anchor),
    row("worktree root", s.root or "<not in a git repo>"),
    row("container", s.container or "<none>"),
    row("tracked tier", s.tracked or "<none — not in a git repo>"),
    row("shared tier", s.shared),
    row("origin", s.origin .. (s.origin == "override" and "  [run.set_dir]" or "")),
    row("store exists", tostring(s.store_exists)),
    row("launch.json", s.launch_json or "<not found via upward walk>"),
    row("read-through", tostring(s.read_through)),
    row("configs", ("tracked=%d shared=%d"):format(
      s.counts.tracked_configs, s.counts.shared_configs)),
    row("profiles", ("tracked=%d shared=%d"):format(
      s.counts.tracked_profiles, s.counts.shared_profiles)),
  }
  -- §4.2 (r5): the per-repo selected env file (highest-precedence
  -- env_files entry on every launch; `:AutoRun env` manages it).
  local oke_sel, sel = pcall(function()
    return require("auto-run.env").get_selected()
  end)
  lines[#lines + 1] = row("selected env",
    (oke_sel and sel) and sel or "<none — :AutoRun env select <path>>")
  if #s.known_dirs > 0 then
    lines[#lines + 1] = "known dirs:"
    for _, entry in ipairs(s.known_dirs) do
      lines[#lines + 1] = "  " .. entry.dir
        .. (entry.last_touched and ("  (" .. entry.last_touched .. ")") or "")
    end
  end

  -- Phase 4 (§13/§14 gobugger doctor parity): git/worktree health +
  -- go module root, from the resolver-anchored doctor module.
  lines[#lines + 1] = ""
  lines[#lines + 1] = "git / worktree"
  lines[#lines + 1] = "──────────────"
  local okg_info, g = pcall(function()
    return require("auto-run.doctor").git_info()
  end)
  if okg_info then
    lines[#lines + 1] = row("project root", g.project_root
      and (g.project_root .. "  [" .. tostring(g.root_marker) .. "]")
      or "<not found>")
    lines[#lines + 1] = row("anchor .git", g.git_kind)
    lines[#lines + 1] = row("git status", g.status_ok and "OK"
      or (tostring(g.status_error) .. "  (:AutoRun doctor --fix)"))
    lines[#lines + 1] = row("git common dir", g.common_dir or "<not in a git repo>")
    lines[#lines + 1] = row("go module root",
      g.go_module_root and (g.go_module_root .. "  [go.mod present]")
      or "<no go.mod found>")
  else
    lines[#lines + 1] = row("git info", "unavailable (" .. tostring(g) .. ")")
  end

  -- ADR 0213 §2.4: what each runtime found here is missing.
  lines[#lines + 1] = ""
  lines[#lines + 1] = "toolchains and dependencies"
  lines[#lines + 1] = "───────────────────────────"
  local okt, tool_rows = pcall(function()
    local dirs = store.resolve_run_dirs()
    return require("auto-run.adapters").doctor(dirs.workdir or dirs.root or dirs.anchor)
  end)
  if not okt then
    lines[#lines + 1] = row("preflight", "unavailable (" .. tostring(tool_rows) .. ")")
  elseif #tool_rows == 0 then
    lines[#lines + 1] = "  no node / playwright / jest / dart project at the working directory"
  else
    for _, r in ipairs(tool_rows) do
      lines[#lines + 1] = ("  %-11s %s%s"):format(r.name, vim.fn.fnamemodify(r.root, ":~"),
        #r.issues == 0 and "  — ok" or "")
      for _, i in ipairs(r.issues) do
        lines[#lines + 1] = ("    %s %s%s"):format(i.level == "error" and "✗" or "!", i.message,
          i.fix and ("  → " .. i.fix) or "")
      end
    end
  end

  -- ADR 0213 §2.5: each .auto-run folder's AGENTS.md / version marker.
  lines[#lines + 1] = ""
  lines[#lines + 1] = "AGENTS.md (auto-run v" .. require("auto-run").version .. ")"
  lines[#lines + 1] = "──────────────────────────"
  do
    local agents = require("auto-run.store.agents")
    local seen = {}
    for _, tier in ipairs({ s.tracked, s.shared }) do
      local folder = tier and agents.folder_of(tier)
      if folder and not seen[folder] then
        seen[folder] = true
        local st = agents.status(folder)
        lines[#lines + 1] = ("  %s  %s"):format(vim.fn.fnamemodify(folder, ":~"), st.state)
      end
    end
    if next(seen) == nil then lines[#lines + 1] = "  no .auto-run folder yet" end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "config validation"
  lines[#lines + 1] = "─────────────────"
  local okv, vlines = pcall(validation_lines)
  if okv then
    for _, l in ipairs(vlines) do lines[#lines + 1] = l end
  else
    lines[#lines + 1] = row("validation", "unavailable (" .. tostring(vlines) .. ")")
  end

  -- Per-kind config listing with the remembered pick markers
  -- (gobugger's "Configs: mode=…" block, generalized to the store's
  -- three kinds).
  lines[#lines + 1] = ""
  lines[#lines + 1] = "configs by kind"
  lines[#lines + 1] = "───────────────"
  local okp, picks = pcall(function() return require("auto-run.exec").picks() end)
  if not okp then picks = {} end
  local by_kind = { run = {}, test = {}, debug = {} }
  for _, c in ipairs(store.list()) do
    if not c.error and by_kind[c.kind] then
      table.insert(by_kind[c.kind], c.name)
    end
  end
  for _, kind in ipairs({ "run", "test", "debug" }) do
    local names = by_kind[kind]
    local rendered = {}
    for _, n in ipairs(names) do
      rendered[#rendered + 1] = n .. (picks[kind] == n and "  [session pick]" or "")
    end
    lines[#lines + 1] = ("  kind=%-6s (%d): %s"):format(kind, #names,
      #names > 0 and table.concat(rendered, ", ") or "<none>")
  end

  -- Phase 3 (§13): test-adapter roster + per-adapter root resolution
  -- for the current anchor, plus the discovery snapshot.
  lines[#lines + 1] = ""
  lines[#lines + 1] = "test discovery"
  lines[#lines + 1] = "──────────────"
  local okd_disc, disc = pcall(function()
    local adapters = require("auto-run.adapters")
    local discovery = require("auto-run.discovery")
    local anchor = s.root or s.anchor
    local out = { adapters = {}, counts = discovery.tree():counts() }
    for _, a in ipairs(adapters.list()) do
      local okr_root, aroot = pcall(a.root, anchor)
      out.adapters[#out.adapters + 1] = {
        name = a.name,
        root = (okr_root and aroot) and aroot or nil,
      }
    end
    return out
  end)
  if okd_disc then
    if #disc.adapters == 0 then
      lines[#lines + 1] = row("adapters", "<none registered>")
    end
    for _, a in ipairs(disc.adapters) do
      lines[#lines + 1] = row("adapter " .. a.name,
        a.root and ("root " .. a.root) or "<no project root at anchor>")
    end
    lines[#lines + 1] = row("discovered", ("%d file(s), %d position(s)")
      :format(disc.counts.files, disc.counts.positions))
  else
    lines[#lines + 1] = row("discovery", "unavailable (" .. tostring(disc) .. ")")
  end

  -- Phase 2 (§13): dap adapter health + breakpoint-store stats.
  local okh, health = pcall(function() return require("auto-run.dap").health() end)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "dap bridge"
  lines[#lines + 1] = "──────────"
  if okh then
    lines[#lines + 1] = row("nvim-dap", health.dap_installed and "installed" or "MISSING")
    lines[#lines + 1] = row("nvim-dap-go", health.dap_go_installed and "installed" or "missing")
    lines[#lines + 1] = row("nvim-dap-view", health.dap_view_installed and "installed" or "missing")
    lines[#lines + 1] = row("go adapter", health.go_adapter and "registered" or "not registered")
    lines[#lines + 1] = row("provider", health.provider_registered
      and "dap.providers.configs['auto-run'] registered" or "not registered")
    if #health.adapters > 0 then
      lines[#lines + 1] = row("adapters", table.concat(health.adapters, ", "))
    end
    lines[#lines + 1] = row("last error", health.last_error_captured
      and "captured (:AutoRun doctor --last-error)" or "<none>")
  else
    lines[#lines + 1] = row("dap bridge", "unavailable (" .. tostring(health) .. ")")
  end

  local okb, bp = pcall(function() return require("auto-run.dap.breakpoints").stats() end)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "breakpoint store"
  lines[#lines + 1] = "────────────────"
  if okb then
    lines[#lines + 1] = row("file", bp.file)
    lines[#lines + 1] = row("breakpoints", ("%d across %d file(s)"):format(bp.count, bp.files))
    if bp.error then
      lines[#lines + 1] = row("store error", tostring(bp.error))
    end
  else
    lines[#lines + 1] = row("store", "unavailable (" .. tostring(bp) .. ")")
  end

  -- Live jobs snapshot.
  local okj, jobs = pcall(function()
    return require("auto-run.exec").list({ active_only = true })
  end)
  if okj and #jobs > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("live jobs (%d):"):format(#jobs)
    for _, j in ipairs(jobs) do
      lines[#lines + 1] = ("  %s  %s  pid=%s"):format(j.id, j.config, tostring(j.pid))
    end
  end
  echo_lines(lines)
end

-- ── run / debug / stop ─────────────────────────────────────────

---Run a config, dispatching on its kind (exec.run_config — the one
---implementation <leader>rp shares): a kind=test config runs as a test,
---anything else launches. `run` absorbed the old `test` subcommand.
function HANDLERS.run(args)
  local name = args[1]
  local exec = require("auto-run.exec")
  local function launch(config_name)
    local launched, err = exec.run_config(config_name)
    if not launched then
      echo_err(err)
      return
    end
    if launched.strategy == "dap" then
      echo_lines({ "auto-run: dap session starting for '" .. config_name .. "'" })
    else
      echo_lines({ ("auto-run: %s (%s strategy%s)"):format(
        launched.id or config_name, launched.strategy,
        launched.pid and (", pid " .. launched.pid) or "") })
    end
  end
  if name and name ~= "" then
    launch(name)
    return
  end
  exec.pick_config({ "run", "test", "debug" }, function(picked, reason)
    if not picked then
      if reason == "no_matches" then
        echo_err("no configs — :AutoRun import, or `a` in the debug pane")
      end
      return
    end
    launch(picked)
  end)
end

---Debug a config, dispatching on its kind (dap.debug_config — the one
---implementation <leader>rP shares): a kind=test config debugs the test at the
---cursor with the config's flags and env; anything else starts a session.
function HANDLERS.debug(args)
  local name = args[1]
  local exec = require("auto-run.exec")
  local function launch(config_name)
    local ok, err = require("auto-run.dap").debug_config(config_name)
    if not ok then echo_err(err) end
  end
  if name and name ~= "" then
    launch(name)
    return
  end
  exec.pick_config({ "debug", "run", "test" }, function(picked, reason)
    if not picked then
      if reason == "no_matches" then
        echo_err("no configs — :AutoRun import, or `a` in the debug pane")
      end
      return
    end
    launch(picked)
  end)
end

---Stop a running job. With no id: the only running job, or a choice among
---several. Covers exec jobs (run / test / term strategies) — a debug
---session is ended by its own terminate (nvim-dap), not from here.
function HANDLERS.stop(args)
  local exec = require("auto-run.exec")
  local function stop(id)
    local ok, err = exec.stop(id)
    if not ok then
      echo_err(err)
      return
    end
    echo_lines({ "auto-run: stop signal sent to " .. id })
  end
  local id = args[1]
  if id and id ~= "" then return stop(id) end
  local jobs = exec.list({ active_only = true })
  if #jobs == 0 then
    echo_lines({ "auto-run: no running jobs (a debug session ends with the debugger's terminate)" })
    return
  end
  if #jobs == 1 then return stop(jobs[1].id) end
  local labels = {}
  for i, j in ipairs(jobs) do
    labels[i] = ("%s  %s  pid=%s"):format(j.id, tostring(j.config), tostring(j.pid))
  end
  vim.ui.select(labels, { prompt = "auto-run: stop which job?" }, function(_, idx)
    if idx then stop(jobs[idx].id) end
  end)
end

-- ── env-file selection (§4.2, r5) ───────────────────────────────

function HANDLERS.env(args)
  local envmod = require("auto-run.env")
  local action = args[1]
  if action == nil or action == "" then
    local files = envmod.files_list()
    if #files == 0 then
      echo_lines({ "auto-run: no candidate env files (referenced or discovered)" })
      return
    end
    local lines = {
      "auto-run env files ('*' = selected — applied to every launch):",
    }
    for _, f in ipairs(files) do
      lines[#lines + 1] = ("  %s %-48s %s%s"):format(
        f.selected and "*" or " ", f.path, f.source,
        f.exists and "" or "  [missing]")
    end
    echo_lines(lines)
    return
  end
  if action == "select" then
    local path = args[2]
    if not path or path == "" then
      echo_err("usage: :AutoRun env select <path>")
      return
    end
    local oks, err = envmod.set_selected(path)
    if not oks then
      echo_err(err)
      return
    end
    echo_lines({ "auto-run: selected env file " .. envmod.get_selected() })
    return
  end
  if action == "profile" then
    -- The env PROFILE for the next launch (the old profile-picker keymap's job).
    local exec = require("auto-run.exec")
    local pname = args[2]
    if pname == nil or pname == "" then
      local names = {}
      for _, pr in ipairs(require("auto-run.store").list_profiles()) do names[#names + 1] = pr.name end
      echo_lines({ #names > 0 and ("auto-run env profiles: " .. table.concat(names, ", ")
        .. "  (:AutoRun env profile <name> applies one to the next launch)")
        or "auto-run: no env profiles in the store" })
      return
    end
    if pname == "clear" then
      exec.set_next_profile(nil)
      echo_lines({ "auto-run: next-launch profile cleared" })
      return
    end
    local oks, perr = pcall(exec.set_next_profile, pname)
    if not oks then
      echo_err(perr)
      return
    end
    echo_lines({ "auto-run: profile '" .. pname .. "' applies to the next launch" })
    return
  end
  if action == "clear" then
    local oks, err = envmod.set_selected(nil)
    if not oks then
      echo_err(err)
      return
    end
    echo_lines({ "auto-run: env-file selection cleared" })
    return
  end
  echo_err("usage: :AutoRun env [select <path>|clear|profile [name|clear]]")
end

vim.api.nvim_create_user_command("AutoRun", function(cmd)
  local fargs = cmd.fargs
  local sub = fargs[1]
  if not sub or not vim.tbl_contains(SUBCOMMANDS, sub) then
    echo_err("usage: :AutoRun {" .. table.concat(SUBCOMMANDS, "|") .. "}")
    return
  end
  local rest = {}
  for i = 2, #fargs do rest[#rest + 1] = fargs[i] end
  local okh, herr = pcall(HANDLERS[sub], rest)
  if not okh then
    echo_err(herr)
  end
end, {
  nargs = "*",
  desc = "auto-run: run / debug / stop / env / doctor / import (ADR 0199 §4.1)",
  complete = function(arglead, cmdline, _)
    -- Complete the subcommand in position 1; config names for the
    -- config-taking subcommands; run ids for `stop`.
    local words = vim.split(cmdline, "%s+", { trimempty = true })
    local at_sub = #words == 1 or (#words == 2 and arglead ~= "")
    if at_sub then
      return vim.tbl_filter(function(s)
        return s:sub(1, #arglead) == arglead
      end, SUBCOMMANDS)
    end
    local sub = words[2]
    if sub == "import" or sub == "run" or sub == "debug" then
      local ok, store = pcall(require, "auto-run.store")
      if not ok then return {} end
      local names = {}
      for _, c in ipairs(store.list()) do
        if c.name:sub(1, #arglead) == arglead then
          names[#names + 1] = c.name
        end
      end
      return names
    end
    if sub == "doctor" then
      return vim.tbl_filter(function(s)
        return s:sub(1, #arglead) == arglead
      end, { "--fix", "--last-error" })
    end
    if sub == "env" then
      if words[3] == "profile" and (#words == 3 or #words == 4 and arglead ~= "") then
        local ok, store = pcall(require, "auto-run.store")
        if not ok then return {} end
        local names = { "clear" }
        for _, pr in ipairs(store.list_profiles()) do names[#names + 1] = pr.name end
        return vim.tbl_filter(function(n) return n:sub(1, #arglead) == arglead end, names)
      end
      if words[3] == "select" and (#words == 3 or #words >= 4) then
        local ok, envmod = pcall(require, "auto-run.env")
        if not ok then return {} end
        local paths = {}
        for _, f in ipairs(envmod.files_list()) do
          if f.exists and f.path:sub(1, #arglead) == arglead then
            paths[#paths + 1] = f.path
          end
        end
        return paths
      end
      return vim.tbl_filter(function(s)
        return s:sub(1, #arglead) == arglead
      end, { "select", "clear", "profile" })
    end
    if sub == "stop" then
      local ok, exec = pcall(require, "auto-run.exec")
      if not ok then return {} end
      local ids = {}
      for _, j in ipairs(exec.list({ active_only = true })) do
        if j.id:sub(1, #arglead) == arglead then
          ids[#ids + 1] = j.id
        end
      end
      return ids
    end
    return {}
  end,
})