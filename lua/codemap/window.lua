-- Sidebar window/buffer lifecycle and rendering. Independent of treesitter
-- and autocmd scheduling: it renders whatever item list it is handed.
local M = {}

local ns = vim.api.nvim_create_namespace("codemap")

-- 'winfixbuf' (Neovim >=0.10) pins a window's buffer, so a stray :edit, a
-- file-tree "open file", or :bd fallout cannot replace the sidebar contents.
local has_winfixbuf = vim.fn.exists("+winfixbuf") == 1

-- item.kind -> highlight group
local kind_highlights = {
  ["function"] = "CodemapFunction",
  method = "CodemapMethod",
  class = "CodemapClass",
  struct = "CodemapStruct",
}

-- item.kind -> single-letter line prefix, e.g. "f foo (3)"
local kind_prefixes = {
  ["function"] = "f",
  method = "m",
  class = "c",
  struct = "s",
}

-- Link (not copy) to standard groups so colors track the colorscheme;
-- default = true keeps user overrides (:hi CodemapClass ...) intact.
local function ensure_highlights()
  vim.api.nvim_set_hl(0, "CodemapFunction", { link = "Function", default = true })
  vim.api.nvim_set_hl(0, "CodemapMethod", { link = "Function", default = true })
  vim.api.nvim_set_hl(0, "CodemapClass", { link = "Type", default = true })
  vim.api.nvim_set_hl(0, "CodemapStruct", { link = "Structure", default = true })
end

ensure_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("CodemapHighlights", { clear = true }),
  callback = ensure_highlights,
})

local state = {
  bufnr = nil,
  winid = nil,
  config = nil,
  -- rendered items; items[i] maps to sidebar line i (used by <CR>/click)
  items = {},
  -- buffer the rendered items were parsed from
  source_bufnr = nil,
}

local function find_window_for_buf(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

-- Jumps to the function on the current sidebar line, in the source buffer,
-- and moves focus there. Bound to <CR> and mouse click in the sidebar.
function M.jump_to_current()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local item = state.items[lnum]
  if not item or not state.source_bufnr or not vim.api.nvim_buf_is_valid(state.source_bufnr) then
    return
  end

  local target_win = find_window_for_buf(state.source_bufnr)
  if not target_win then
    -- source no longer visible anywhere; reuse the previous window
    local alt = vim.fn.win_getid(vim.fn.winnr("#"))
    if alt == 0 or not vim.api.nvim_win_is_valid(alt) then
      return
    end
    target_win = alt
    vim.api.nvim_win_set_buf(target_win, state.source_bufnr)
  end

  vim.api.nvim_set_current_win(target_win)
  vim.api.nvim_win_set_cursor(target_win, { item.lnum, 0 })
  vim.cmd("normal! zz")
end

local function create_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "codemap"
  vim.bo[bufnr].modifiable = false
  pcall(vim.api.nvim_buf_set_name, bufnr, "codemap://sidebar")

  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", M.jump_to_current, opts)
  vim.keymap.set("n", "<LeftMouse>", M.jump_to_current, opts)

  return bufnr
end

-- scope must be "local": vim.wo[winid].x behaves like :set and also writes
-- the global value, leaking nonumber/signcolumn=no etc. into later windows.
local function set_local(winid, name, value)
  vim.api.nvim_set_option_value(name, value, { win = winid, scope = "local" })
end

local function apply_win_options(winid)
  set_local(winid, "number", false)
  set_local(winid, "relativenumber", false)
  set_local(winid, "wrap", false)
  set_local(winid, "signcolumn", "no")
  set_local(winid, "foldcolumn", "0")
  set_local(winid, "cursorline", true)
  set_local(winid, "winfixwidth", true)
  set_local(winid, "spell", false)
  set_local(winid, "list", false)
  set_local(winid, "fillchars", "eob: ")
  -- keep files out of the sidebar window (see has_winfixbuf)
  if has_winfixbuf then
    set_local(winid, "winfixbuf", true)
  end
end

-- Window-local options set by apply_win_options; reset when the sidebar
-- window is handed back for normal use, else a file shown there would
-- inherit nonumber/signcolumn=no etc.
local altered_win_options = {
  "number",
  "relativenumber",
  "wrap",
  "signcolumn",
  "foldcolumn",
  "cursorline",
  "spell",
  "list",
  "fillchars",
  "winfixwidth",
}

local guard_group = vim.api.nvim_create_augroup("CodemapWindowGuard", { clear = true })

local function clear_guard()
  vim.api.nvim_clear_autocmds({ group = guard_group })
end

-- Hand the sidebar window back for normal use: restore global option values
-- and drop our reference to it.
local function release_window(winid)
  -- must clear winfixbuf before the buffer switches callers do next, else E1513
  if has_winfixbuf then
    pcall(set_local, winid, "winfixbuf", false)
  end
  for _, opt in ipairs(altered_win_options) do
    pcall(set_local, winid, opt, vim.api.nvim_get_option_value(opt, { scope = "global" }))
  end
  state.winid = nil
  clear_guard()
end

local function list_non_floating_wins()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      table.insert(wins, win)
    end
  end
  return wins
end

-- A non-floating window other than `exclude` that shows a normal editable
-- buffer (buftype == ""), i.e. a real "code" window; nil if there is none.
local function first_normal_win(wins, exclude)
  for _, win in ipairs(wins) do
    if win ~= exclude and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
      return win
    end
  end
  return nil
end

-- Keep the sidebar from being stranded by ordinary editing. winfixbuf stops
-- files from entering the sidebar window, leaving two cases to handle:
--   * no normal (code) window left -> nothing to mirror: close the sidebar,
--     or hand it back empty if it is the last window (which can't be closed);
--   * a file slipped into the sidebar anyway (Neovim <0.10) -> move it to a
--     real window and restore the sidebar; never close it here.
local function check_layout()
  if state.winid and not vim.api.nvim_win_is_valid(state.winid) then
    state.winid = nil
    clear_guard()
    return
  end
  if not M.is_open() then
    return
  end

  local wins = list_non_floating_wins()
  local dest = first_normal_win(wins, state.winid)

  if not dest then
    if #wins == 1 then
      local winid = state.winid
      release_window(winid)
      if vim.api.nvim_win_get_buf(winid) == state.bufnr then
        vim.api.nvim_win_set_buf(winid, vim.api.nvim_create_buf(true, false))
      end
    else
      M.close()
    end
    return
  end

  local shown = vim.api.nvim_win_get_buf(state.winid)
  if shown ~= state.bufnr then
    if has_winfixbuf then
      pcall(set_local, state.winid, "winfixbuf", false)
    end
    vim.api.nvim_win_set_buf(state.winid, state.bufnr)
    apply_win_options(state.winid)
    vim.api.nvim_win_set_buf(dest, shown)
    if vim.api.nvim_get_current_win() == state.winid then
      vim.api.nvim_set_current_win(dest)
    end
  end
end

local function setup_guard()
  clear_guard()
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinClosed" }, {
    group = guard_group,
    callback = function()
      -- defer: WinClosed fires before the window is gone, and swapping
      -- buffers inside the autocmd is unsafe
      vim.schedule(check_layout)
    end,
  })
end

function M.setup(config)
  state.config = config
end

function M.is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

function M.open()
  if M.is_open() then
    return
  end

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    state.bufnr = create_buffer()
  end

  -- Not style="minimal": it re-applies on every buffer change and would
  -- fight option restoration if the window ever shows a real file.
  -- apply_win_options() covers what the sidebar needs.
  -- win = -1 makes the split relative to the whole editor (like :botright
  -- vsplit), so the sidebar is always full-height at the far right; the
  -- default (current window) would place it mid-layout in a split.
  state.winid = vim.api.nvim_open_win(state.bufnr, false, {
    split = "right",
    win = -1,
    width = state.config.width,
  })

  apply_win_options(state.winid)
  setup_guard()
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.winid = nil
  clear_guard()
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- items: list of { name = string, lnum = number, size = number|nil,
-- kind = "function"|"class"|"struct"|nil }
function M.render(items, source_bufnr)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  items = items or {}
  local lines = {}
  for _, item in ipairs(items) do
    local prefix = kind_prefixes[item.kind]
    local text = prefix and (prefix .. " " .. item.name) or item.name
    if item.size then
      text = text .. " (" .. item.size .. ")"
    end
    table.insert(lines, text)
  end
  if #lines == 0 then
    lines = { "(no functions)" }
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
  for i, item in ipairs(items) do
    local hl = kind_highlights[item.kind]
    if hl then
      vim.api.nvim_buf_set_extmark(state.bufnr, ns, i - 1, 0, {
        end_row = i,
        hl_group = hl,
        hl_eol = true,
      })
    end
  end

  state.items = items
  state.source_bufnr = source_bufnr
end

function M.get_bufnr()
  return state.bufnr
end

function M.get_winid()
  return state.winid
end

-- items[i] <-> sidebar line i; source is the buffer they were parsed from.
function M.get_items()
  return state.items
end

function M.get_source_bufnr()
  return state.source_bufnr
end

return M
