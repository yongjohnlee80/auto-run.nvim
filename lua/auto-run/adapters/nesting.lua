---auto-run.adapters.nesting — turn a flat list of matched test/namespace
---calls into a nested `type="file"` position, by byte containment. Shared by
---the treesitter adapters whose positions nest by source range (jest,
---playwright, dart) so they cannot nest differently.
---@module 'auto-run.adapters.nesting'

local fs_path = require("auto-core.fs.path")

local M = {}

---@class AutoRunFlatMatch
---@field name string
---@field kind "namespace"|"test"
---@field srow integer   1-based start line
---@field erow integer   1-based end line
---@field sbyte integer
---@field ebyte integer
---@field children table[]   (empty; filled here)

---Nest `flat` by byte ranges (a match inside another's range is its child)
---and return the file position. `flat` must be non-empty.
---@param path string
---@param flat AutoRunFlatMatch[]
---@return AutoRunPosition
function M.file_position(path, flat)
  table.sort(flat, function(a, b)
    if a.sbyte == b.sbyte then return a.ebyte > b.ebyte end
    return a.sbyte < b.sbyte
  end)
  local top, stack = {}, {}
  for _, item in ipairs(flat) do
    while #stack > 0 and item.sbyte >= stack[#stack].ebyte do
      table.remove(stack)
    end
    local parent = stack[#stack]
    if parent then
      parent.children[#parent.children + 1] = item
    else
      top[#top + 1] = item
    end
    stack[#stack + 1] = item
  end

  local function to_position(item)
    local pos = {
      type     = item.kind,
      name     = item.name,
      path     = path,
      lnum     = item.srow,
      end_lnum = item.erow,
    }
    if #item.children > 0 then
      pos.children = {}
      for _, child in ipairs(item.children) do
        pos.children[#pos.children + 1] = to_position(child)
      end
    end
    return pos
  end

  local file_pos = {
    type     = "file",
    name     = fs_path.basename(path),
    path     = path,
    children = {},
  }
  for _, item in ipairs(top) do
    file_pos.children[#file_pos.children + 1] = to_position(item)
  end
  return file_pos
end

return M
