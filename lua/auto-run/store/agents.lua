---auto-run.store.agents — the AGENTS.md every `.auto-run/` folder carries,
---and the empty version marker that keeps it current (ADR 0213 §2.5).
---
---Each `.auto-run/` folder auto-run writes into holds:
---  AGENTS.md               rendered from `templates/AGENTS.md` (plugin-owned)
---  CLAUDE.md               "Read AGENTS.md" — created once, then the user's
---  auto-run.nvim-v<ver>    EMPTY; its name is the version that wrote AGENTS.md
---  AGENTS.local.md         the project's own notes — never touched
---
---`touch(path)` runs after every successful store write (configs, profiles,
---overrides, state, breakpoints, env files, the gitignore scaffold). It finds
---the written path's `.auto-run` folder and, once per folder per session,
---compares the marker with the running version:
---  none / older → (re)write AGENTS.md, create CLAUDE.md if missing, replace marker
---  equal        → nothing
---  newer        → nothing (a tracked folder shared through git must not
---                 ping-pong between two machines on different versions)
---Reads never write: only a write that is already happening carries this.
---
---A hand-written AGENTS.md (no managed header) is moved to AGENTS.local.md
---before the first write; when AGENTS.local.md already exists nothing is
---written and doctor reports the conflict — no user text is ever lost.
---@module 'auto-run.store.agents'

local fs_path = require("auto-core.fs.path")

local M = {}

M.MARKER_PREFIX = "auto-run.nvim-v"
M.MANAGED_HEADER = "<!-- auto-run.nvim managed file"

---folder → the version already checked this session.
local _checked = {}

---The running plugin version.
---@return string
function M.version()
  return require("auto-run").version
end

---Compare two `x.y.z` versions: -1, 0 or 1.
---@param a string
---@param b string
---@return integer
function M.compare(a, b)
  local pa, pb = vim.split(a, ".", { plain = true }), vim.split(b, ".", { plain = true })
  for i = 1, math.max(#pa, #pb) do
    local x, y = tonumber(pa[i]) or 0, tonumber(pb[i]) or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

---The `.auto-run` folder a path is in (the path itself when it is one), or nil.
---@param path string
---@return string?
function M.folder_of(path)
  if type(path) ~= "string" or path == "" then return nil end
  local cur = fs_path.normalize(path)
  while cur and cur ~= "" do
    if fs_path.basename(cur) == ".auto-run" then return cur end
    local parent = fs_path.parent(cur)
    if parent == cur or parent == "" then return nil end
    cur = parent
  end
  return nil
end

---The marker files in a folder, and the highest version among them.
---@param folder string
---@return string? version, string[] markers
function M.marker(folder)
  local best, files = nil, {}
  for _, name in ipairs(vim.fn.readdir(folder) or {}) do
    local v = name:match("^" .. vim.pesc(M.MARKER_PREFIX) .. "(%d+%.%d+%.%d+)$")
    if v then
      files[#files + 1] = name
      if not best or M.compare(v, best) > 0 then best = v end
    end
  end
  return best, files
end

---The plugin root (…/auto-run.nvim), from this file's location.
---@return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(src, ":p:h:h:h:h")
end

---Markdown-table-safe text.
local function cell(s)
  return (tostring(s or ""):gsub("|", "\\|"):gsub("\n", " "))
end

---The field table of a record, from the schema's own documentation — so the
---rendered file cannot list a field the schema lacks, or miss one it has.
---@param record "config"|"profile"
---@return string
function M.field_table(record)
  local schema = require("auto-run.store.schema")
  local names = schema.field_names(record)
  local first = { name = 1, kind = 2, runtime = 3 }
  table.sort(names, function(a, b)
    local fa, fb = first[a] or 99, first[b] or 99
    if fa ~= fb then return fa < fb end
    return a < b
  end)
  local from = {
    runtimes = "a registered runtime (§4)", configs = "another config's name",
    profiles = "an env profile's name",
  }
  local lines = { "| Field | Values | Applies to | Meaning |", "|---|---|---|---|" }
  for _, n in ipairs(names) do
    local d = schema.field_doc(record, n) or { help = "" }
    local values = d.values and ("`" .. table.concat(d.values, "` · `") .. "`")
      or (d.values_from and from[d.values_from]) or ""
    local applies = d.runtimes and table.concat(d.runtimes, ", ")
      or d.kinds and ("kind " .. table.concat(d.kinds, ", ")) or "all"
    lines[#lines + 1] = ("| `%s` | %s | %s | %s |"):format(n, cell(values), cell(applies), cell(d.help))
  end
  return table.concat(lines, "\n")
end

---The registered runtimes and what each can do.
---@return string
function M.runtime_table()
  local lines = { "| Runtime | Runs / debugs configs | Test files | What it is |", "|---|---|---|---|" }
  for _, a in ipairs(require("auto-run.adapters").list()) do
    local runs = (type(a.default_config) == "function" or type(a.build_run_argv) == "function")
      and (type(a.prepare_debug_config) == "function" and "run + debug" or "run") or "—"
    local tests = type(a.prepare_debug) == "function" and "run + debug" or "run"
    if a.name == "node" then tests = "— (jest / playwright)" end
    lines[#lines + 1] = ("| `%s` | %s | %s | %s |"):format(a.name, runs, tests, cell(a.summary or ""))
  end
  return table.concat(lines, "\n")
end

---The rendered AGENTS.md, or nil + err.
---@return string? text, string? err
function M.render()
  local f, oerr = io.open(fs_path.join(plugin_root(), "templates", "AGENTS.md"), "r")
  if not f then return nil, "AGENTS.md template: " .. tostring(oerr) end
  local text = f:read("*a")
  f:close()
  local subs = {
    version = M.version(),
    fields = M.field_table("config"),
    profile_fields = M.field_table("profile"),
    runtimes = M.runtime_table(),
  }
  text = text:gsub("{{(%w+_?%w*)}}", function(k) return subs[k] end)
  return text, nil
end

M.CLAUDE_MD = "Read [AGENTS.md](AGENTS.md) before creating or changing any run, debug,\n"
  .. "test or env configuration here — it is the single source for these\n"
  .. "instructions. Read [AGENTS.local.md](AGENTS.local.md) too, if it exists.\n"

---Bring one folder's AGENTS.md in line with the running version.
---@param folder string   a `.auto-run` directory
---@return string action  "created"|"updated"|"current"|"newer"|"conflict"|"failed"
---@return string? detail
function M.refresh(folder)
  if not fs_path.is_dir(folder) then return "failed", "not a directory: " .. folder end
  local ver = M.version()
  local have, markers = M.marker(folder)
  if have then
    local c = M.compare(have, ver)
    if c == 0 then return "current" end
    if c > 0 then return "newer", have end
  end
  local atomic = require("auto-core.fs.atomic")
  local agents = fs_path.join(folder, "AGENTS.md")
  local localmd = fs_path.join(folder, "AGENTS.local.md")
  if fs_path.is_file(agents) then
    local f = io.open(agents, "r")
    local head = f and f:read(#M.MANAGED_HEADER) or ""
    if f then f:close() end
    if head ~= M.MANAGED_HEADER then
      if fs_path.exists(localmd) then
        return "conflict", "a hand-written AGENTS.md and an AGENTS.local.md both exist in " .. folder
      end
      local okr, rerr = os.rename(agents, localmd)
      if not okr then return "failed", "moving AGENTS.md aside: " .. tostring(rerr) end
    end
  end
  local text, rerr = M.render()
  if not text then return "failed", rerr end
  local okw, werr = atomic.write(agents, text)
  if not okw then return "failed", tostring(werr) end
  local claude = fs_path.join(folder, "CLAUDE.md")
  if not fs_path.exists(claude) then atomic.write(claude, M.CLAUDE_MD) end
  local okm, merr = atomic.write(fs_path.join(folder, M.MARKER_PREFIX .. ver), "")
  if not okm then return "failed", tostring(merr) end
  for _, m in ipairs(markers) do
    if m ~= M.MARKER_PREFIX .. ver then os.remove(fs_path.join(folder, m)) end
  end
  return have and "updated" or "created", have
end

---After a store write: refresh the written path's `.auto-run` folder, once per
---folder per session. Best-effort — a failure is logged, never raised into
---the write that triggered it.
---@param path string  the file just written
function M.touch(path)
  local folder = M.folder_of(path)
  if not folder then return end
  local ver = M.version()
  if _checked[folder] == ver then return end
  _checked[folder] = ver
  local ok, action, detail = pcall(M.refresh, folder)
  if not ok then
    require("auto-run.log").warn("agents", "AGENTS.md refresh failed: " .. tostring(action))
  elseif action == "failed" or action == "conflict" then
    require("auto-run.log").warn("agents", "AGENTS.md not written: " .. tostring(detail))
  end
end

---Doctor's view of a folder: its marker version and what a write would do.
---@param folder string
---@return { folder: string, marker: string?, state: string }
function M.status(folder)
  if not fs_path.is_dir(folder) then return { folder = folder, state = "absent" } end
  local have = M.marker(folder)
  local ver = M.version()
  local state
  if not have then
    state = "no marker — the next write adds AGENTS.md"
  else
    local c = M.compare(have, ver)
    state = c == 0 and "current" or c > 0 and ("written by a newer auto-run (v" .. have .. "); you run v" .. ver)
      or ("older (v" .. have .. ") — the next write updates AGENTS.md")
  end
  local agents = fs_path.join(folder, "AGENTS.md")
  if fs_path.is_file(agents) and fs_path.exists(fs_path.join(folder, "AGENTS.local.md")) then
    local f = io.open(agents, "r")
    local head = f and f:read(#M.MANAGED_HEADER) or ""
    if f then f:close() end
    if head ~= M.MANAGED_HEADER then state = "conflict: hand-written AGENTS.md and AGENTS.local.md both exist" end
  end
  return { folder = folder, marker = have, state = state }
end

---Test-only: forget which folders were checked.
function M._reset_for_tests() _checked = {} end

return M
