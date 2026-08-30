# fx.nvim

Use [fx](https://github.com/vercel-labs/fx.git) in neovim:

![fx.nvim](assets/screenshot.svg)

## Installation

Requires the [fx](https://github.com/vercel-labs/fx.git) CLI on your `$PATH`.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "stanfish06/fx.nvim",
  cmd = "Fx",
  opts = {},
}
```

With built-in `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/stanfish06/fx.nvim" })
```

## Configuration

lazy.nvim:

```lua
{
  "stanfish06/fx.nvim",
  cmd = "Fx",
  opts = {
    border = "rounded",
    output = { width = 80 },
  },
}
```

Standard:

```lua
require("fx").setup({ border = "rounded" })
```

Defaults (see [config.lua](./lua/fx/config.lua))

## Context captured and sent to agent
- position
- text selection
- treesitter node
- diagnostics

```c
int main() {
  printf("hello world! %d", "not int");
  int sum = 0;
  for (int i = 1; i < n; ++i) {
    sum += i;
  }
  return 0;
}
```

```lua
{
  buf = 13,
  diagnostics = { "2:3 error Call to undeclared library function 'printf' with type 'int (const char *, ...)'; ISO C99 and later do not support implicit function declarations (fix available) [clang]", "4:23 error Use of undeclared identifier 'n' [clang]", "2:29 warn Format specifies type 'int' but the argument has type 'char *' (fix available) [clang]" },
  label = "hello.c:1-8",
  lnum1 = 1,
  lnum2 = 8,
  path = "/home/stan/Git/fx.nvim/hello.c",
  rel = "hello.c",
  row = 1,
  summary = "hello.c, selected lines 1-8\nts: function_definition 1:1-8:1\nparent: translation_unit\nscope: function_definition 1:1-8:1\ndiagnostics:\n2:3 error Call to undeclared library function 'printf' with type 'int (const char *, ...)'; ISO C99 and later do not support implicit function declarations (fix available) [clang]\n4:23 error Use of undeclared identifier 'n' [clang]\n2:29 warn Format specifies type 'int' but the argument has type 'char *' (fix available) [clang]",
  text = 'int main() {\n  printf("hello world! %d", "not int");\n  int sum = 0;\n  for (int i = 1; i < n; ++i) {\n    sum += i;\n  }\n  return 0;\n}',
  ts = {
    parent = "translation_unit",
    range = { 1, 1, 8, 1 },
    scope = {
      range = { 1, 1, 8, 1 },
      type = "function_definition"
    },
    type = "function_definition"
  },
  win = 1002
}
```

## Commands

| Command | Action |
| --- | --- |
| `:Fx` | open the prompt overlay at the cursor (visual selection becomes context) |
| `:Fx ask <text>` | send a request directly, skipping the overlay |
| `:Fx stop` | stop the running turn |
| `:Fx restart` | restart fx and reload the current session (replay session history as well) |
| `:Fx new` | start a fresh session |
| `:Fx resume` | pick a saved session and continue it (without replaying session history, same as acp method session/resume) |
| `:Fx load` | load and replay current session's history (same as acp method session/load) |
| `:Fx rewind` | show the last request/response transcript |
| `:Fx history` | pick a past prompt of this session and view its transcript |
| `:Fx list` | list fx sessions |
| `:Fx model` | pick the model |

## Key binds

| Where | Key | Action |
| --- | --- | --- |
| prompt overlay | `<CR>` | submit |
| prompt overlay | `q` / `<Esc>` | cancel |
| transcript hover | `q` / `<Esc>` | close |
| transcript hover | `<leader>s` / `<leader>t` | export (make a copy) transcript to a new split/window |

Example settings (leader k for inline prompt)
```lua
vim.keymap.set("n", "<leader>k", "<Cmd>Fx<CR>", { silent = true, desc = "fx: inline request" })
vim.keymap.set("x", "<leader>k", ":Fx<CR>", { silent = true, desc = "fx: inline request" })
vim.keymap.set("n", "<leader>K", "<Cmd>Fx rewind<CR>", { silent = true, desc = "fx: rewind" })

vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("FxTheme", { clear = true }),
    pattern = "*",
    desc = "fx",
    callback = function()
        vim.api.nvim_set_hl(0, "FxSpinner", { fg = "#98C379" })
        vim.api.nvim_set_hl(0, "FxNormal", { fg = "#D8D4CD", bg = "#1A2132" })
        vim.api.nvim_set_hl(0, "FxBorder", { fg = "#3E8FB0" })
        vim.api.nvim_set_hl(0, "FxTitle", { fg = "#E5C07B", bold = true })
    end,
})
```

## Color groups

| Group | Controls | Default link |
| --- | --- | --- |
| `FxNormal` | hover window text/background | `NormalFloat` |
| `FxBorder` | hover window border | `FloatBorder` |
| `FxTitle` | hover window title | `FloatTitle` |
| `FxSpinner` | request-line spinner | `DiagnosticVirtualTextInfo` |
