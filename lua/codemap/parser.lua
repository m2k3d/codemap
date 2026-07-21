-- Extracts a flat list of {name, lnum} for functions/methods in a buffer,
-- using treesitter. Each supported language needs two things below:
--   1. an entry in `queries` that captures the relevant nodes as @function
--   2. an entry in `name_extractors` that pulls a display name out of that node
-- Add a new language by adding both entries; nothing else in the plugin
-- needs to change.
local M = {}

local queries = {
  go = [[
    (function_declaration) @function
    (method_declaration) @function
  ]],
  cpp = [[
    (function_definition) @function
  ]],
  c = [[
    (function_definition) @function
  ]],
  -- `local function f() end` is also a plain function_declaration node
  -- (nested under local_declaration), so one pattern covers both forms.
  lua = [[
    (function_declaration) @function
  ]],
  -- methods, decorated defs (@staticmethod, ...) and `async def` are all
  -- plain function_definition nodes too; decorators just wrap them.
  python = [[
    (function_definition) @function
  ]],
}

local function node_text(node, bufnr)
  if not node then
    return nil
  end
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  return ok and text or nil
end

-- Walks a (possibly nested) C/C++ declarator chain to find the actual name.
-- Handles plain identifiers, class methods (field_identifier), out-of-class
-- definitions (qualified_identifier, e.g. Foo::bar), destructors, operator
-- overloads, and pointer/reference return types that wrap the declarator.
local function find_declarator_name(node, bufnr)
  local passthrough = {
    pointer_declarator = true,
    reference_declarator = true,
    parenthesized_declarator = true,
  }

  local current = node
  while current do
    local t = current:type()
    if t == "identifier" or t == "field_identifier" or t == "destructor_name" or t == "operator_name" then
      return node_text(current, bufnr)
    elseif t == "qualified_identifier" then
      local name_field = current:field("name")[1]
      return node_text(name_field, bufnr) or node_text(current, bufnr)
    elseif t == "function_declarator" then
      current = current:field("declarator")[1]
    elseif passthrough[t] then
      current = current:field("declarator")[1]
    else
      return nil
    end
  end
  return nil
end

local name_extractors = {}

function name_extractors.go(node, bufnr)
  local name_node = node:field("name")[1]
  if not name_node then
    return nil
  end
  local name = node_text(name_node, bufnr)

  if node:type() == "method_declaration" then
    local receiver = node:field("receiver")[1]
    local param = receiver and receiver:named_child(0)
    local rtype = param and param:field("type")[1]
    if rtype then
      name = "(" .. node_text(rtype, bufnr) .. ") " .. name
    end
  end

  return name
end

function name_extractors.cpp(node, bufnr)
  local declarator = node:field("declarator")[1]
  return declarator and find_declarator_name(declarator, bufnr) or nil
end
name_extractors.c = name_extractors.cpp

function name_extractors.lua(node, bufnr)
  local name_node = node:field("name")[1]
  return node_text(name_node, bufnr)
end

-- python's function_definition, like lua's function_declaration, just has a
-- plain `name` field to read.
name_extractors.python = name_extractors.lua

local function resolve_lang(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == "" then
    return nil
  end
  local ok, lang = pcall(vim.treesitter.language.get_lang, ft)
  if ok and lang then
    return lang
  end
  return ft
end

-- Returns a list of { name = string, lnum = 1-indexed line } sorted by line.
function M.get_functions(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local lang = resolve_lang(bufnr)
  if not lang then
    return {}
  end

  local query_str = queries[lang]
  local extractor = name_extractors[lang]
  if not query_str or not extractor then
    return {}
  end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok_parser or not parser then
    return {}
  end

  local ok_tree, trees = pcall(parser.parse, parser)
  if not ok_tree or not trees or not trees[1] then
    return {}
  end
  local root = trees[1]:root()

  local ok_query, query = pcall(vim.treesitter.query.parse, lang, query_str)
  if not ok_query or not query then
    return {}
  end

  local results = {}
  for _, node in query:iter_captures(root, bufnr, 0, -1) do
    local name = extractor(node, bufnr)
    if name and name ~= "" then
      local start_row, _, end_row = node:range()
      table.insert(results, {
        name = name,
        lnum = start_row + 1,
        size = end_row - start_row + 1,
      })
    end
  end

  table.sort(results, function(a, b)
    return a.lnum < b.lnum
  end)

  return results
end

return M
