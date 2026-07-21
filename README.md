# codemap.nvim

A minimal sidebar for Neovim that lists all functions/methods in the current
buffer, extracted via treesitter, with jump-to-definition support.

## Features

- Non-intrusive vertical sidebar on the right, listing function/method names
  with their size in lines, e.g. `handleRequest (42)`.
- Powered by treesitter — no LSP required.
- Supported languages: **Go**, **C**, **C++**, **Lua**, **Python**.
- Auto-refreshes on `BufEnter` and on text changes (debounced).
- Click (or `<CR>`) on a function name jumps to it in the source buffer.

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

## Adding a new language

Support for a language is two entries in `lua/codemap/parser.lua`:

1. A treesitter query in the `queries` table that captures the node(s)
   representing a function/method as `@function`. Find the right node type
   by opening a file in that language and running:
   ```vim
   :lua print(vim.treesitter.get_parser(0, "<lang>"):parse()[1]:root():sexpr())
   ```
2. An entry in `name_extractors` — a function `(node, bufnr) -> string|nil`
   that pulls a display name out of the captured node (usually its `name`
   field; C-family declarators may need to be unwrapped, see the `cpp`
   extractor for an example).

Nothing else needs to change — `window.lua` and `init.lua` are language-agnostic.
