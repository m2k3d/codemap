-- codemap: a sidebar listing functions/methods of the current buffer,
-- extracted via treesitter. See README.md for architecture notes.
local config = require("codemap.config")
local parser = require("codemap.parser")
local window = require("codemap.window")

local M = {}

local uv = vim.uv or vim.loop
local timer = nil

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function refresh()
  if not window.is_open() then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  -- ignore the sidebar's own buffer and anything already gone
  if bufnr == window.get_bufnr() or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ok, items = pcall(parser.get_functions, bufnr)
  window.render(ok and items or {}, bufnr)
end

local function schedule_refresh(delay_ms)
  stop_timer()
  timer = uv.new_timer()
  timer:start(delay_ms, 0, vim.schedule_wrap(function()
    stop_timer()
    refresh()
  end))
end

local function register_autocmds(opts)
  local group = vim.api.nvim_create_augroup("Codemap", { clear = true })

  local instant_events = {}
  local debounced_events = {}
  for _, ev in ipairs(opts.update_events) do
    if ev == "BufEnter" then
      table.insert(instant_events, ev)
    else
      table.insert(debounced_events, ev)
    end
  end

  if #instant_events > 0 then
    vim.api.nvim_create_autocmd(instant_events, {
      group = group,
      callback = function()
        schedule_refresh(0)
      end,
    })
  end

  if #debounced_events > 0 then
    vim.api.nvim_create_autocmd(debounced_events, {
      group = group,
      callback = function()
        schedule_refresh(opts.debounce_ms)
      end,
    })
  end
end

local function register_commands()
  vim.api.nvim_create_user_command("CodemapToggle", function()
    window.toggle()
    refresh()
  end, { desc = "Toggle the codemap sidebar" })

  vim.api.nvim_create_user_command("CodemapOpen", function()
    window.open()
    refresh()
  end, { desc = "Open the codemap sidebar" })

  vim.api.nvim_create_user_command("CodemapClose", function()
    window.close()
  end, { desc = "Close the codemap sidebar" })
end

function M.setup(opts)
  M.options = config.merge(opts)

  window.setup(M.options)
  register_autocmds(M.options)
  register_commands()
end

return M
