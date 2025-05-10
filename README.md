# Strive: Minimalist Plugin Manager for Neovim

Strive is a lightweight, feature-rich plugin manager for Neovim with support for lazy loading, dependencies, and asynchronous operations.

## Features

- ✅ Asynchronous installation and updates
- ✅ Lazy loading based on events, filetypes, commands, and keymaps
- ✅ Dependency management
- ✅ Clean and intuitive API
- ✅ Minimal overhead
- ✅ Visual progress tracking

## Installation

### Manual Installation

```bash
git clone https://github.com/nvimdev/strive ~/.local/share/nvim/site/pack/strive/start/strive
```

### Bootstrap Installation

```lua
local strive_path = vim.fn.stdpath('data') .. '/site/pack/strive/start/strive'
if not vim.uv.fs_stat(strive_path) then
  vim.fn.system({
    'git',
    'clone',
    '--depth=1',
    'https://github.com/nvimdev/strive',
    strive_path
  })

  vim.o.rtp = strive_path .. ',' .. vim.o.rtp
end
```

## Basic Usage

```lua
-- Initialize
local use = require('strive').use

-- Add plugins
use 'neovim/nvim-lspconfig':ft({'c', 'lua'})

-- Lazy-load plugins based on events
use 'lewis6991/gitsigns.nvim'
  :on('BufRead')

-- Lazy-load by commands
use 'nvim-telescope/telescope.nvim'
  :cmd('Telescope')

-- Colorscheme
use 'folke/tokyonight.nvim'
  :theme()
```

## Commands

Strive provides these commands:

- `:Strive install` - Install all plugins
- `:Strive update` - Update all plugins
- `:Strive clean` - Remove unused plugins

## Lazy Loading Methods

### Events

```lua
-- Load on specific events
use 'lewis6991/gitsigns.nvim'
  :on('BufRead')

-- Multiple events
use 'luukvbaal/stabilize.nvim'
  :on({'BufRead', 'BufNewFile'})
```

### Filetypes

```lua
-- Load for specific filetypes
use 'fatih/vim-go'
  :ft('go')

-- Multiple filetypes
use 'plasticboy/vim-markdown'
  :ft({'markdown', 'md'})
```

### Commands

```lua
-- Load when command is used
use 'github/copilot.vim'
  :cmd('Copilot')

-- Multiple commands
use 'nvim-telescope/telescope.nvim'
  :cmd({'Telescope', 'Telescope find_files'})
```

### Keymaps

```lua
-- Basic keymap in normal mode
use 'folke/trouble.nvim'
  :keys('<leader>t')

-- Specific mode, key, action and opts
use 'numToStr/Comment.nvim'
  :keys({
    {'n', '<leader>c', '<cmd>CommentToggle<CR>', {silent = true}},
    {'v', '<leader>c', '<cmd>CommentToggle<CR>', {silent = true}}
  })
```

### Conditional Loading

```lua
-- Load based on a condition
use 'gpanders/editorconfig.nvim'
  :cond(function()
    return vim.fn.executable('editorconfig') == 1
  end)

-- Using a Vim expression
use 'junegunn/fzf.vim'
  :cond('executable("fzf")')
```

## Plugin Configuration

### Setup Method

```lua
-- Call the setup function of a plugin
use 'nvim-treesitter/nvim-treesitter'
  :setup({
    ensure_installed = {'lua', 'vim', 'vimdoc'},
    highlight = {enable = true},
    indent = {enable = true}
  })
```

### Init vs Config

```lua
-- Init runs BEFORE the plugin loads
use 'mbbill/undotree'
  :init(function()
    vim.g.undotree_SetFocusWhenToggle = 1
  end)

-- Config runs AFTER the plugin loads
use 'folke/which-key.nvim'
  :config(function()
    require('which-key').setup({
      plugins = {
        spelling = {enabled = true}
      }
    })
  end)
```

### Build Commands

```lua
-- Run a command after installing a plugin
use 'nvim-treesitter/nvim-treesitter'
  :run(':TSUpdate')
```

## Local Plugin Development

```lua
-- Load a local plugin
use 'username/my-plugin'
  :load_path('~/projects/neovim-plugins')

-- Or set a global development path
vim.g.strive_dev_path = '~/projects/neovim-plugins'
use 'my-plugin'
  :load_path()
```

## Advanced Configuration

### Custom Settings

```lua
-- Set custom configuration before loading
vim.g.strive_auto_install = true        -- Auto-install plugins on startup
vim.g.strive_max_concurrent_tasks = 8   -- Limit concurrent operations
vim.g.strive_log_level = 'info'         -- Set logging level (debug, info, warn, error)
vim.g.strive_git_timeout = 60000        -- Git operation timeout in ms
vim.g.strive_git_depth = 1              -- Git clone depth
vim.g.strive_install_with_retry = false -- Retry failed installations
```

## Example Configuration

```lua
-- Initialize
local use = require('strive').use

-- UI
use 'folke/tokyonight.nvim'
  :theme('tokyonight-storm')
  
use 'nvim-lualine/lualine.nvim'
  :depends('kyazdani42/nvim-web-devicons')
  :config(function()
    require('lualine').setup({
      options = {
        theme = 'tokyonight'
      }
    })
  end)

-- Editing
use 'tpope/vim-surround'
use 'tpope/vim-commentary'
use 'windwp/nvim-autopairs'
  :config(function()
    require('nvim-autopairs').setup()
  end)

-- Navigation
use 'nvim-telescope/telescope.nvim'
  :depends({
    'nvim-lua/plenary.nvim',
    'nvim-telescope/telescope-fzf-native.nvim'
  })
  :cmd({
    'Telescope',
    'Telescope find_files',
    'Telescope live_grep'
  })
  :keys('<leader>f')
  :config(function()
    require('telescope').setup({
      extensions = {
        fzf = {
          fuzzy = true,
          override_generic_sorter = true,
          override_file_sorter = true,
          case_mode = "smart_case",
        }
      }
    })
    require('telescope').load_extension('fzf')
  end)

-- LSP & Completion
use 'neovim/nvim-lspconfig'
  :config(function()
    local lspconfig = require('lspconfig')
    lspconfig.lua_ls.setup({})
    lspconfig.tsserver.setup({})
  end)

use 'hrsh7th/nvim-cmp'
  :depends({
    'hrsh7th/cmp-nvim-lsp',
    'hrsh7th/cmp-buffer',
    'hrsh7th/cmp-path',
    'L3MON4D3/LuaSnip',
    'saadparwaiz1/cmp_luasnip'
  })
  :config(function()
    local cmp = require('cmp')
    local luasnip = require('luasnip')
    
    cmp.setup({
      snippet = {
        expand = function(args)
          luasnip.lsp_expand(args.body)
        end,
      },
      mapping = cmp.mapping.preset.insert({
        ['<C-b>'] = cmp.mapping.scroll_docs(-4),
        ['<C-f>'] = cmp.mapping.scroll_docs(4),
        ['<C-Space>'] = cmp.mapping.complete(),
        ['<C-e>'] = cmp.mapping.abort(),
        ['<CR>'] = cmp.mapping.confirm({ select = true }),
      }),
      sources = cmp.config.sources({
        { name = 'nvim_lsp' },
        { name = 'luasnip' },
      }, {
        { name = 'buffer' },
      })
    })
  end)

-- Git
use 'lewis6991/gitsigns.nvim'
  :on('BufRead')
  :config(function()
    require('gitsigns').setup()
  end)
```

## Best Practices

1. **Group related plugins**: Use dependencies to manage related plugins
2. **Lazy-load where possible**: This improves startup time
3. **Use appropriate events**: Choose the right events, filetypes, or commands
4. **Keep configuration organized**: Group plugins by functionality
5. **Regular updates**: Run `:Strive update` periodically
6. **Clean unused plugins**: Run `:Strive clean` to remove unused plugins

## Troubleshooting

If you encounter issues:

1. Check the plugin is available on GitHub
2. Verify your internet connection
3. Increase the timeout for Git operations:
   ```lua
   vim.g.strive_git_timeout = 300000  -- 5 minutes
   ```
4. Enable debug logging:
   ```lua
   vim.g.strive_log_level = 'debug'
   ```
5. Try reinstalling:
   ```
   :Strive clean
   :Strive install
   ```
