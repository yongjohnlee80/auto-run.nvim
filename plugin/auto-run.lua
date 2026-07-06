---plugin/auto-run.lua — :AutoRun user command.
---
---Subcommands: list | show | validate | import | doctor | set-dir
---(Phase 1) + run | debug | test | stop | jobs | last-error
---(Phase 2). Output goes through print()/nvim_echo (user-invoked,
---not a main path); errors are echoed, never vim.notify'd.

if vim.g.loaded_auto_run then
  return
end
vim.g.loaded_auto_run = 1

local SUBCOMMANDS = {
  "list", "show", "validate", "import", "doctor", "set-dir",
  "run", "debug", "test", "stop", "jobs", "last-error",
}

local function echo_lines(lines)
  print(table.concat(lines, "\n"))
end

local function echo_err(msg)
  vim.api.nvim_echo({ { "[auto-run] " .. tostring(msg), "ErrorMsg" } }, true, {})
end

local HANDLERS = {}

function HANDLERS.list()
  local store = require("auto-run.store")
  local configs = store.list()
  if #configs == 0 then
    echo_lines({ "auto-run: no configs (see :AutoRun doctor / :AutoRun import)" })
    return
  end
  local lines = { "auto-run configs:" }
  for _, c in ipairs(configs) do
    if c.error then
      lines[#lines + 1] = ("  %-24s ERROR: %s"):format(c.name, c.error)
    else
      lines[#lines + 1] = ("  %-24s %-6s %-8s [%s]"):format(
        c.name, c.kind or "?", c.runtime or "-",
        table.concat(c.layers, ","))
    end
  end
  echo_lines(lines)
end

function HANDLERS.show(args)
  local name = args[1]
  if not name or name == "" then
    echo_err("usage: :AutoRun show <name>")
    return
  end
  local store = require("auto-run.store")
  local eff, err, meta = store.get(name)
  if not eff then
    echo_err(err)
    return
  end
  local lines = { "auto-run config '" .. name .. "'"
    .. " (layers: " .. table.concat(meta.layers, " → ") .. ")" }
  lines[#lines + 1] = vim.inspect(eff)
  echo_lines(lines)
end

function HANDLERS.validate()
  local store = require("auto-run.store")
  local report = store.validate()
  local lines = { ("auto-run validate: %d file(s) checked, %s"):format(
    report.checked, report.ok and "all OK" or (#report.issues .. " issue(s)")) }
  for _, issue in ipairs(report.issues) do
    lines[#lines + 1] = "  " .. issue.name
      .. (issue.tier and (" [" .. issue.tier .. "]") or "")
      .. (issue.file and (" (" .. issue.file .. ")") or "")
    for _, e in ipairs(issue.errors) do
      lines[#lines + 1] = "    - " .. e
    end
  end
  echo_lines(lines)
end

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

function HANDLERS.doctor()
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
  if #s.known_dirs > 0 then
    lines[#lines + 1] = "known dirs:"
    for _, entry in ipairs(s.known_dirs) do
      lines[#lines + 1] = "  " .. entry.dir
        .. (entry.last_touched and ("  (" .. entry.last_touched .. ")") or "")
    end
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
      and "captured (:AutoRun last-error)" or "<none>")
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

-- ── Phase 2 subcommands ─────────────────────────────────────────

function HANDLERS.run(args)
  local name = args[1]
  local exec = require("auto-run.exec")
  local function launch(config_name)
    local launched, err = exec.start(config_name)
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
        echo_err("no configs — :AutoRun import or create one under .auto-run/configs/")
      end
      return
    end
    launch(picked)
  end)
end

function HANDLERS.debug(args)
  local name = args[1]
  local exec = require("auto-run.exec")
  local function launch(config_name)
    local ok, err = require("auto-run.dap").debug_start(config_name)
    if not ok then echo_err(err) end
  end
  if name and name ~= "" then
    launch(name)
    return
  end
  exec.pick_config("debug", function(picked, reason)
    if not picked then
      if reason == "no_matches" then
        echo_err("no kind=debug configs")
      end
      return
    end
    launch(picked)
  end)
end

function HANDLERS.test(args)
  local name = args[1]
  local exec = require("auto-run.exec")
  local function launch(config_name)
    local launched, err = exec.test_run(config_name)
    if not launched then
      echo_err(err)
      return
    end
    echo_lines({ ("auto-run: %s (%s strategy)"):format(
      launched.id or config_name, launched.strategy) })
  end
  if name and name ~= "" then
    launch(name)
    return
  end
  exec.pick_config("test", function(picked, reason)
    if not picked then
      if reason == "no_matches" then
        echo_err("no kind=test configs")
      end
      return
    end
    launch(picked)
  end)
end

function HANDLERS.stop(args)
  local id = args[1]
  if not id or id == "" then
    echo_err("usage: :AutoRun stop <run-id>  (see :AutoRun jobs)")
    return
  end
  local ok, err = require("auto-run.exec").stop(id)
  if not ok then
    echo_err(err)
    return
  end
  echo_lines({ "auto-run: stop signal sent to " .. id })
end

function HANDLERS.jobs()
  local jobs = require("auto-run.exec").list()
  if #jobs == 0 then
    echo_lines({ "auto-run: no jobs this session" })
    return
  end
  local lines = { "auto-run jobs:" }
  for _, j in ipairs(jobs) do
    local state = j.exited
      and ("exited code=" .. tostring(j.code)
        .. (j.signal and j.signal ~= 0 and (" signal=" .. j.signal) or ""))
      or ("running pid=" .. tostring(j.pid))
    lines[#lines + 1] = ("  %-24s %-20s %-10s %s"):format(j.id, j.config, j.strategy, state)
    lines[#lines + 1] = "      " .. j.dir
  end
  echo_lines(lines)
end

HANDLERS["last-error"] = function()
  if not require("auto-run.dap").open_last_error() then
    echo_lines({ "auto-run: no captured dap failure output yet" })
  end
end

HANDLERS["set-dir"] = function(args)
  local store = require("auto-run.store")
  local path = args[1]
  if path == "" then path = nil end
  if path == "-" then path = nil end
  local dirs, err = store.set_dir(path)
  if not dirs then
    echo_err(err)
    return
  end
  echo_lines({
    ("auto-run shared tier: %s (origin=%s)"):format(dirs.shared, dirs.origin),
  })
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
  desc = "auto-run: run configs, execution, dap sessions (ADR-0048)",
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
    if sub == "show" or sub == "import" or sub == "run"
        or sub == "debug" or sub == "test" then
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