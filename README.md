# codemap.nvim

A minimal sidebar for Neovim that lists all functions/methods in the current
buffer, extracted via treesitter, with jump-to-definition support.

## Features

- Non-intrusive vertical sidebar on the right, listing functions, methods,
  classes and structs with a one-letter kind prefix and their size in
  lines, e.g. `f handleRequest (42)`.
- Powered by treesitter — no LSP required.
- Supported languages: **Go**, **C**, **C++**, **Lua**, **Python**.
- Auto-refreshes on `BufEnter` and on text changes (debounced).
- Click (or `<CR>`) on an entry jumps to it in the source buffer.
- Each kind (function/method/class/struct) gets its own prefix letter and
  highlight color (linked to standard highlight groups — see
  [Highlight groups](#highlight-groups)).

## Requirements

- Neovim >= 0.10
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter), with
  parsers installed for the languages you use:
  ```
  :TSInstall go cpp c lua python
  ```
- `vim.opt.mouse = "a"` if you want click-to-jump (keyboard `<CR>` works
  regardless).

## Installation (lazy.nvim)

```lua
return {
  "m2k3d/codemap",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  cmd = { "CodemapOpen", "CodemapToggle", "CodemapClose" },
  event = "VeryLazy", -- load shortly after startup, so auto_open kicks in
  opts = {
    width = 30, -- sidebar width, columns
    update_events = { "BufEnter", "TextChanged", "TextChangedI" }, -- when to refresh the list
    debounce_ms = 300, -- delay before re-parsing after a text edit
    auto_open = true, -- open the sidebar automatically on startup
  },
}
```

## Commands

| Command          | Description                     |
|-------------------|----------------------------------|
| `:CodemapOpen`    | Open the sidebar                |
| `:CodemapClose`   | Close the sidebar                |
| `:CodemapToggle`  | Toggle the sidebar               |

## Configuration

Passed as `opts` to the lazy.nvim spec (or via `require("codemap").setup(opts)`):

| Option           | Default                                       | Description                                  |
|------------------|------------------------------------------------|-----------------------------------------------|
| `width`          | `30`                                           | Sidebar width, in columns                     |
| `update_events`  | `{ "BufEnter", "TextChanged", "TextChangedI" }` | Autocmd events that trigger a refresh         |
| `debounce_ms`    | `300`                                           | Debounce delay for text-change refreshes      |
| `auto_open`      | `false`                                         | Open the sidebar automatically on startup     |

## Highlight groups

Each entry in the sidebar gets a one-letter prefix and a color for its
kind. The highlight groups are linked to standard `:highlight-groups`, so
they follow your colorscheme; override them if you want different colors:

| Kind       | Prefix | Group             | Linked to   |
|------------|--------|-------------------|-------------|
| `function` | `f`    | `CodemapFunction` | `Function`  |
| `method`   | `m`    | `CodemapMethod`   | `Function`  |
| `class`    | `c`    | `CodemapClass`    | `Type`      |
| `struct`   | `s`    | `CodemapStruct`   | `Structure` |

A "method" is a function that belongs to a class/struct — a Go method
(with a receiver), a C++/Python function defined inside a class/struct
body, or a C++ out-of-class `ClassName::method() {}` definition. Lua's
`function obj:name() end` colon syntax is still shown as a plain function,
since Lua has no class construct.

```lua
vim.api.nvim_set_hl(0, "CodemapClass", { fg = "#ffcc00" })
```

## Adding a new language (or kind)

Support for a language/kind pair is two entries in `lua/codemap/parser.lua`:

1. A treesitter query in the `queries` table that captures the relevant
   node(s) as `@function`, `@method`, `@class` or `@struct`. Find the right
   node type by opening a file in that language and running:
   ```vim
   :lua print(vim.treesitter.get_parser(0, "<lang>"):parse()[1]:root():sexpr())
   ```
2. An entry in `name_extractors[lang][kind]` — a function
   `(node, bufnr) -> string|nil, string|nil` that pulls a display name out
   of the captured node (usually its `name` field; C-family declarators may
   need to be unwrapped, see the `cpp` function extractor for an example).
   It may return a second value to override the kind implied by the
   capture, for cases the query alone can't distinguish (e.g. telling a
   C++/Python method apart from a plain function — see `cpp_function` and
   `python_function`).

Nothing else needs to change — `window.lua` and `init.lua` are
kind/language-agnostic.
