-- Owns the sidebar window/buffer: creation, options, open/close/toggle and
-- rendering a list of items into it. Knows nothing about treesitter or
-- autocmd scheduling; it only draws whatever it is given.
local M = {}

local ns = vim.api.nvim_create_namespace("codemap")

-- item.kind -> highlight group used for that line in the sidebar.
local kind_highlights = {
  ["function"] = "CodemapFunction",
  method = "CodemapMethod",
  class = "CodemapClass",
  struct = "CodemapStruct",
}

-- item.kind -> single-letter prefix shown before the name, e.g. "f foo (3)".
local kind_prefixes = {
  ["function"] = "f",
  method = "m",
  class = "c",
  struct = "s",
}

-- Linked (not copied) to standard :highlight-groups, so colors follow
-- whatever colorscheme is active; `default = true` lets users override
-- them (e.g. `:hi CodemapClass guifg=...`) without being clobbered here.
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
  -- last rendered items; state.items[i] corresponds to sidebar line i and
  -- is what <CR>/click use to know where to jump.
  items = {},
  -- source buffer the currently rendered items belong to
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
    -- source buffer no longer shown anywhere; reuse the window we were in
    -- before entering the sidebar.
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

-- NOTE: must be scope="local". `vim.wo[winid].x = v` acts like `:set`, which
-- also overwrites the *global* value — every window opened afterwards would
-- inherit nonumber/signcolumn=no etc. for the rest of the session.
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
end

-- Window-local options that apply_win_options touches. They belong to the
-- *window*, not the buffer, so if a regular file ever ends up displayed in
-- the sidebar window they must be reset, or the file is shown without line
-- numbers, signcolumn etc.
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

-- Turn the sidebar window back into a normal window: restore the user's
-- global values for every option we changed and forget about the window.
local function release_window(winid)
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

-- Keeps the sidebar window from silently becoming a regular window.
-- Two situations, both caused by normal editing (e.g. `:bd` closes the
-- window that showed the buffer; closing the file tree can then leave the
-- sidebar as the last window):
--  * the sidebar is the last non-floating window -> hand the window back
--    to normal use (restored options, empty buffer) instead of a
--    fullscreen sidebar;
--  * some other buffer got displayed in the sidebar window -> move it to a
--    real window if one exists, otherwise hand the window over to it.
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
  local shown = vim.api.nvim_win_get_buf(state.winid)

  if #wins == 1 and wins[1] == state.winid then
    local winid = state.winid
    release_window(winid)
    if shown == state.bufnr then
      vim.api.nvim_win_set_buf(winid, vim.api.nvim_create_buf(true, false))
    end
    return
  end

  if shown ~= state.bufnr then
    local other = nil
    for _, win in ipairs(wins) do
      if win ~= state.winid and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
        other = win
        break
      end
    end
    if other then
      local winid = state.winid
      vim.api.nvim_win_set_buf(winid, state.bufnr)
      apply_win_options(winid)
      vim.api.nvim_win_set_buf(other, shown)
      if vim.api.nvim_get_current_win() == winid then
        vim.api.nvim_set_current_win(other)
      end
    else
      release_window(state.winid)
    end
  end
end

local function setup_guard()
  clear_guard()
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinClosed" }, {
    group = guard_group,
    callback = function()
      -- deferred: WinClosed fires before the window is gone, and swapping
      -- buffers from inside the autocmd itself is unsafe
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

  -- No style="minimal" here: a window opened with it re-applies the minimal
  -- style every time the displayed buffer changes, which breaks restoring
  -- normal options if this window ever has to show a regular buffer.
  -- apply_win_options() sets everything the sidebar needs.
  state.winid = vim.api.nvim_open_win(state.bufnr, false, {
    split = "right",
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

-- Exposed for future features (e.g. current-function highlight):
-- state.items[i] <-> sidebar buffer line i, state.source_bufnr is the
-- buffer those items were parsed from.
function M.get_items()
  return state.items
end

function M.get_source_bufnr()
  return state.source_bufnr
end

return M
