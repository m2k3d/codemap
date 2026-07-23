-- Extracts a flat list of {name, lnum, size, kind} for functions, methods,
-- classes and structs in a buffer, using treesitter. `kind` is one of
-- "function", "method", "class", "struct". Each supported language needs
-- two things below, one pair per kind it supports:
--   1. a capture in `queries` tagging the relevant nodes as @function,
--      @method, @class or @struct
--   2. a matching entry in `name_extractors[lang][kind]` that pulls a
--      display name out of that captured node
-- An extractor may return a second value to override the kind implied by
-- its capture (used where the query alone can't tell a method from a
-- plain function, e.g. C++/Python member functions) — see `cpp_function`
-- and `python_function` below.
-- Add a new language (or a new kind for an existing language) by adding
-- both entries; nothing else in the plugin needs to change.
local M = {}

local queries = {
  go = [[
    (function_declaration) @function
    (method_declaration) @method
    (type_spec
      name: (type_identifier)
      type: (struct_type)) @struct
  ]],
  cpp = [[
    (function_definition) @function
    (class_specifier
      name: (type_identifier)
      body: (field_declaration_list)) @class
    (struct_specifier
      name: (type_identifier)
      body: (field_declaration_list)) @struct
  ]],
  -- `body:` is required on struct_specifier so forward declarations
  -- (`struct Foo;`) are skipped; anonymous structs (no `name:`) are
  -- matched but filtered out later since their extractor returns nil.
  c = [[
    (function_definition) @function
    (struct_specifier
      name: (type_identifier)
      body: (field_declaration_list)) @struct
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
    (class_definition) @class
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
-- Returns name, is_qualified — is_qualified is true for Foo::bar-style
-- out-of-class definitions, which are member functions (methods) even
-- though they're not textually nested inside the class/struct body.
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
      return node_text(current, bufnr), false
    elseif t == "qualified_identifier" then
      local name_field = current:field("name")[1]
      return node_text(name_field, bufnr) or node_text(current, bufnr), true
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

-- True if `node` has an ancestor whose type is a key in `types`. Used to
-- tell member functions defined inline (C++ methods, Python methods) apart
-- from top-level ones, since the query alone captures both the same way.
local function has_ancestor(node, types)
  local current = node:parent()
  while current do
    if types[current:type()] then
      return true
    end
    current = current:parent()
  end
  return false
end

-- name_extractors[lang][kind] = function(node, bufnr) -> name|nil
local name_extractors = {}

-- Shared by any node that exposes its display name via a plain `name`
-- field: lua/python functions, python classes, go struct type_specs.
local function type_name(node, bufnr)
  local name_node = node:field("name")[1]
  return node_text(name_node, bufnr)
end

local function go_function(node, bufnr)
  return node_text(node:field("name")[1], bufnr)
end

-- method_declaration is a distinct node type from function_declaration in
-- go's grammar, so it's captured separately as @method — no ancestor/kind
-- inference needed here, unlike C++/Python.
local function go_method(node, bufnr)
  local name_node = node:field("name")[1]
  if not name_node then
    return nil
  end
  local name = node_text(name_node, bufnr)

  local receiver = node:field("receiver")[1]
  local param = receiver and receiver:named_child(0)
  local rtype = param and param:field("type")[1]
  if rtype then
    name = "(" .. node_text(rtype, bufnr) .. ") " .. name
  end

  return name
end

-- Handles both free functions and methods: `function_definition` is the
-- same node type whether it's a free function, an inline method inside a
-- class/struct body, or an out-of-class `ClassName::method() {}` def, so
-- the method/function distinction is resolved here rather than in the
-- query.
local function cpp_function(node, bufnr)
  local declarator = node:field("declarator")[1]
  if not declarator then
    return nil
  end
  local name, is_qualified = find_declarator_name(declarator, bufnr)
  if not name then
    return nil
  end
  local is_method = is_qualified or has_ancestor(node, { class_specifier = true, struct_specifier = true })
  return name, is_method and "method" or "function"
end

-- Same reasoning as cpp_function: a `def` inside a class body is a method,
-- a top-level one is a plain function.
local function python_function(node, bufnr)
  local name = type_name(node, bufnr)
  if not name then
    return nil
  end
  local is_method = has_ancestor(node, { class_definition = true })
  return name, is_method and "method" or "function"
end

name_extractors.go = {
  ["function"] = go_function,
  method = go_method,
  struct = type_name,
}

name_extractors.cpp = {
  ["function"] = cpp_function,
  class = type_name,
  struct = type_name,
}

name_extractors.c = {
  ["function"] = cpp_function,
  struct = type_name,
}

name_extractors.lua = {
  ["function"] = type_name,
}

name_extractors.python = {
  ["function"] = python_function,
  class = type_name,
}

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

-- Returns a list of { name, lnum, size, kind } sorted by line.
-- kind is one of "function", "method", "class", "struct".
function M.get_functions(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local lang = resolve_lang(bufnr)
  if not lang then
    return {}
  end

  local query_str = queries[lang]
  local extractors = name_extractors[lang]
  if not query_str or not extractors then
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
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    local capture_kind = query.captures[id]
    local extractor = extractors[capture_kind]
    local name, kind_override
    if extractor then
      name, kind_override = extractor(node, bufnr)
    end
    if name and name ~= "" then
      local start_row, _, end_row = node:range()
      table.insert(results, {
        name = name,
        lnum = start_row + 1,
        size = end_row - start_row + 1,
        kind = kind_override or capture_kind,
      })
    end
  end

  table.sort(results, function(a, b)
    return a.lnum < b.lnum
  end)

  return results
end

return M
