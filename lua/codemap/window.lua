-- Owns the sidebar window/buffer: creation, options, open/close/toggle and
-- rendering a list of items into it. Knows nothing about treesitter or
-- autocmd scheduling; it only draws whatever it is given.
local M = {}

local state = {
  bufnr = nil,
  winid = nil,
  config = nil,
  -- last rendered items, kept for future features (jump-to-line, highlight
  -- current function): state.items[i] corresponds to sidebar line i.
  items = {},
  -- source buffer the currently rendered items belong to
  source_bufnr = nil,
  bounce_group = nil,
}

local function create_buffer()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "codemap"
  vim.bo[bufnr].modifiable = false
  pcall(vim.api.nvim_buf_set_name, bufnr, "codemap://sidebar")
  return bufnr
end

local function apply_win_options(winid)
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].wrap = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldcolumn = "0"
  vim.wo[winid].cursorline = true
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].spell = false
  vim.wo[winid].list = false
end

-- Best-effort "non-focusable" window: it opens without focus, and if the
-- user still manages to enter it (e.g. <C-w>l), we bounce focus back to the
-- previously active window on the next event-loop tick.
local function install_focus_bounce()
  if state.bounce_group then
    return
  end
  state.bounce_group = vim.api.nvim_create_augroup("CodemapNoFocus", { clear = true })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = state.bounce_group,
    callback = function()
      if state.winid and vim.api.nvim_get_current_win() == state.winid then
        vim.schedule(function()
          if not (state.winid and vim.api.nvim_win_is_valid(state.winid)) then
            return
          end
          if vim.api.nvim_get_current_win() ~= state.winid then
            return
          end
          local alt = vim.fn.win_getid(vim.fn.winnr("#"))
          if alt ~= 0 and vim.api.nvim_win_is_valid(alt) then
            vim.api.nvim_set_current_win(alt)
          end
        end)
      end
    end,
  })
end

function M.setup(config)
  state.config = config
  install_focus_bounce()
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

  state.winid = vim.api.nvim_open_win(state.bufnr, false, {
    split = "right",
    width = state.config.width,
    style = "minimal",
  })

  apply_win_options(state.winid)
end

function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.winid = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- items: list of { name = string, lnum = number }
function M.render(items, source_bufnr)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  items = items or {}
  local lines = {}
  for _, item in ipairs(items) do
    if item.size then
      table.insert(lines, item.name .. " (" .. item.size .. ")")
    else
      table.insert(lines, item.name)
    end
  end
  if #lines == 0 then
    lines = { "(no functions)" }
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  state.items = items
  state.source_bufnr = source_bufnr
end

function M.get_bufnr()
  return state.bufnr
end

function M.get_winid()
  return state.winid
end

-- Exposed for future features (jump-to-line on click, current-function
-- highlight): state.items[i] <-> sidebar buffer line i, state.source_bufnr
-- is the buffer those items were parsed from.
function M.get_items()
  return state.items
end

function M.get_source_bufnr()
  return state.source_bufnr
end

return M
