-- MinPM: Minimalist Plugin Manager for Neovim
-- A lightweight, feature-rich plugin manager with support for lazy loading,
-- dependencies, and asynchronous operations.

local api, uv, if_nil = vim.api, vim.uv, vim.F.if_nil

-- =====================================================================
-- 1. Configuration and Constants
-- =====================================================================
local M = {}
local plugins = {}
local plugin_map = {}

-- Data paths
local data_dir = vim.fn.stdpath('data')
local START_DIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'minpm', 'start')
local OPT_DIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'minpm', 'opt')

-- Add to packpath
vim.opt.packpath:prepend(vim.fs.joinpath(data_dir, 'site'))

-- Default settings
local DEFAULT_SETTINGS = {
  max_concurrent_tasks = if_nil(vim.g.minpm_max_concurrent_tasks, 5),
  auto_install = if_nil(vim.g.minpm_auto_install, true),
  log_level = if_nil(vim.g.minpm_log_level, 'info'),
  git_timeout = if_nil(vim.g.minpm_git_timeout, 60000),
}

-- Plugin status constants
local STATUS = {
  PENDING = 'pending',
  LOADING = 'loading',
  LOADED = 'loaded',
  INSTALLING = 'installing',
  INSTALLED = 'installed',
  UPDATING = 'updating',
  UPDATED = 'updated',
  ERROR = 'error',
}

-- =====================================================================
-- 2. Async Utilities
-- =====================================================================
local async = {}

-- Wrap a function to return a promise
function async.wrap(func)
  return function(...)
    local args = { ... }
    return function(callback)
      table.insert(args, callback)
      func(unpack(args))
    end
  end
end

-- Await a promise - execution is paused until promise resolves
function async.await(promise)
  local co = coroutine.running()
  if not co then
    error('Cannot await outside of an async function')
  end

  promise(function(...)
    local args = { ... }
    vim.schedule(function()
      assert(coroutine.resume(co, unpack(args)))
    end)
  end)
  return coroutine.yield()
end

-- Create an async function that can use await
function async.async(func)
  return function(...)
    local args = { ... }
    local co = coroutine.create(function()
      func(unpack(args))
    end)

    local function step(...)
      local ok, err = coroutine.resume(co, ...)
      if not ok then
        error(debug.traceback(co, err))
      end
    end

    step()
  end
end

-- Run multiple promises concurrently and wait for all to complete
function async.all(promises)
  return function(callback)
    if #promises == 0 then
      callback({})
      return
    end

    local results = {}
    local completed = 0

    for i, promise in ipairs(promises) do
      promise(function(...)
        results[i] = { ... }
        completed = completed + 1

        if completed == #promises then
          callback(results)
        end
      end)
    end
  end
end

-- =====================================================================
-- 3. Task Queue
-- =====================================================================
local TaskQueue = {}
TaskQueue.__index = TaskQueue

-- Create a new task queue with a maximum number of concurrent tasks
function TaskQueue.new(max_concurrent)
  local self = setmetatable({
    active_tasks = 0,
    max_concurrent = max_concurrent,
    queue = {},
    on_empty = nil,
  }, TaskQueue)

  return self
end

-- Process the queue, starting as many tasks as allowed
function TaskQueue:process()
  if #self.queue == 0 and self.active_tasks == 0 and self.on_empty then
    self.on_empty()
    return
  end

  while self.active_tasks < self.max_concurrent and #self.queue > 0 do
    local task = table.remove(self.queue, 1)
    self.active_tasks = self.active_tasks + 1

    task(function()
      self.active_tasks = self.active_tasks - 1
      self:process() -- Continue processing after task completes
    end)
  end
end

-- Add a task to the queue and start processing
function TaskQueue:enqueue(task)
  table.insert(self.queue, task)
  self:process()
  return self
end

-- Set a callback for when the queue becomes empty
function TaskQueue:on_complete(callback)
  self.on_empty = callback
  -- Check immediately in case the queue is already empty
  if #self.queue == 0 and self.active_tasks == 0 and self.on_empty then
    self.on_empty()
  end
  return self
end

-- Get the current queue status
function TaskQueue:status()
  return {
    queued = #self.queue,
    active = self.active_tasks,
    total = #self.queue + self.active_tasks,
  }
end

-- Create main task queue
local task_queue = TaskQueue.new(DEFAULT_SETTINGS.max_concurrent_tasks)

-- =====================================================================
-- 4. UI Window
-- =====================================================================
local ProgressWindow = {}
ProgressWindow.__index = ProgressWindow

function ProgressWindow.new()
  local self = setmetatable({
    bufnr = nil,
    winid = nil,
    entries = {},
    visible = false,
    title = 'MinPM Plugin Manager',
  }, ProgressWindow)

  return self
end

-- Create the buffer for the window
function ProgressWindow:create_buffer()
  self.bufnr = api.nvim_create_buf(false, true)

  -- Set buffer options
  vim.bo[self.bufnr].buftype = 'nofile'
  vim.bo[self.bufnr].bufhidden = 'wipe'
  vim.bo[self.bufnr].swapfile = false
  vim.bo[self.bufnr].modifiable = false

  -- Set buffer name
  api.nvim_buf_set_name(self.bufnr, 'MinPM-Progress')

  -- Set key mappings for the buffer
  self:set_keymaps()

  return self
end

-- Set key mappings for the window
function ProgressWindow:set_keymaps()
  local opts = { buffer = self.bufnr, noremap = true, silent = true }

  -- Close window with 'q' or <Esc>
  vim.keymap.set('n', 'q', function()
    self:close()
  end, opts)
  vim.keymap.set('n', '<Esc>', function()
    self:close()
  end, opts)

  -- Add other useful keymaps
  vim.keymap.set('n', 'r', function()
    self:refresh()
  end, vim.tbl_extend('force', opts, { desc = 'Refresh display' }))
end

-- Create and open the window
function ProgressWindow:open()
  if self.visible and api.nvim_win_is_valid(self.winid) then
    api.nvim_set_current_win(self.winid)
    return self
  end

  if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then
    self:create_buffer()
  end

  -- Calculate window dimensions (50% of screen)
  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.5)

  -- Create the window
  self.winid = api.nvim_open_win(self.bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = self.title,
    title_pos = 'center',
  })

  -- Set window options
  vim.wo[self.winid].wrap = false
  vim.wo[self.winid].foldenable = false
  vim.wo[self.winid].cursorline = true

  self.visible = true
  self:refresh()

  return self
end

-- Close the window
function ProgressWindow:close()
  if self.visible and self.winid and api.nvim_win_is_valid(self.winid) then
    api.nvim_win_close(self.winid, true)
    self.visible = false
  end
  return self
end

-- Update entry for a plugin
function ProgressWindow:update_entry(plugin_name, status, message)
  self.entries[plugin_name] = {
    status = status,
    message = message,
    time = os.time(),
  }

  if self.visible then
    -- Schedule UI updates to run in the main event loop
    vim.schedule(function()
      self:refresh()
    end)
  end

  return self
end

-- Refresh the window content
function ProgressWindow:refresh()
  -- Ensure we're not in a fast event context
  if not self.visible then
    return self
  end

  -- Check buffer validity safely
  local buf_valid = false
  if self.bufnr then
    -- This could throw in a fast event context, so we need to handle it safely
    local ok, result = pcall(api.nvim_buf_is_valid, self.bufnr)
    buf_valid = ok and result
  end

  if not buf_valid then
    return self
  end

  -- Convert entries to sorted list
  local lines = {}
  local sorted_plugins = {}

  for name, _ in pairs(self.entries) do
    table.insert(sorted_plugins, name)
  end
  table.sort(sorted_plugins)

  -- Header
  table.insert(lines, string.rep('=', 80))
  table.insert(lines, string.format('%-30s %-10s %s', 'Plugin', 'Status', 'Message'))
  table.insert(lines, string.rep('=', 80))

  -- Plugin entries
  for _, name in ipairs(sorted_plugins) do
    local entry = self.entries[name]
    table.insert(
      lines,
      string.format('%-30s %-10s %s', name:sub(1, 30), entry.status, entry.message or '')
    )
  end

  -- Update buffer content
  vim.bo[self.bufnr].modifiable = true
  api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.bo[self.bufnr].modifiable = false

  return self
end

-- Clear all entries
function ProgressWindow:clear()
  self.entries = {}

  if self.visible then
    self:refresh()
  end

  return self
end

-- Create a singleton UI window
local ui = ProgressWindow.new()

-- =====================================================================
-- 5. Plugin Class
-- =====================================================================
local Plugin = {}
Plugin.__index = Plugin

-- Create a new plugin instance
function Plugin.new(spec)
  if type(spec) == 'string' then
    spec = { name = spec }
  end

  -- Extract plugin name from repo
  local name = vim.fs.normalize(spec.name)
  local parts = vim.split(name, '/', { trimempty = true })
  local plugin_name = parts[#parts]:gsub('%.git$', '')

  local self = setmetatable({
    -- Basic properties
    name = name, -- Full repo name (user/repo)
    plugin_name = plugin_name, -- Just the repo part (for loading)
    is_remote = not name:find(vim.env.HOME), -- Is it a remote or local plugin
    is_dev = spec.dev or false, -- Development mode flag
    is_lazy = false, -- Whether to lazy load

    -- States
    status = STATUS.PENDING, -- Current plugin status
    loaded = false, -- Is the plugin loaded

    -- Loading options
    events = {}, -- Events to trigger loading
    filetypes = {}, -- Filetypes to trigger loading
    commands = {}, -- Commands to trigger loading
    keys = {}, -- Keys to trigger loading

    -- Configuration
    setup_opts = spec.setup or nil, -- Options for plugin setup()
    config_fn = spec.config, -- Config function to run after loading
    after_fn = spec.after, -- Function to run after dependencies load
    colorscheme = spec.theme, -- Theme to apply if this is a colorscheme

    -- Dependencies
    dependencies = spec.depends or {}, -- Dependencies

    -- Internal state
    autocmd_ids = {}, -- Autocmd IDs for cleanup
    user_commands = {}, -- Created user commands
  }, Plugin)

  return self
end

-- Get the plugin installation path
function Plugin:get_path()
  return vim.fs.joinpath(self.is_lazy and OPT_DIR or START_DIR, self.plugin_name)
end

-- Check if plugin is installed (async version)
function Plugin:is_installed()
  return async.wrap(function(callback)
    uv.fs_stat(self:get_path(), function(err, stat)
      callback(not err and stat and stat.type == 'directory')
    end)
  end)()
end

-- Load a plugin and its dependencies
function Plugin:load()
  if self.loaded then
    return true
  end

  local path = self:get_path()

  -- Check if plugin exists
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'directory' then
    return false
  end

  -- Prevent recursive loading
  -- Set loaded to true before actual loading to prevent infinite loops
  self.loaded = true

  -- If it's a lazy-loaded plugin, add it
  if self.is_lazy then
    vim.cmd.packadd(self.plugin_name)
  end

  if self.setup_opts then
    local module_name = self.plugin_name:gsub('%.nvim$', ''):gsub('-nvim$', ''):gsub('^nvim%-', '')
    -- Try to load the module
    local ok, module = pcall(require, module_name)
    if ok and type(module) == 'table' and type(module.setup) == 'function' then
      module.setup(self.setup_opts)
    end
  end

  -- Run config function if provided
  if type(self.config_fn) == 'function' then
    self.config_fn()
  end
  -- Update status
  self.status = STATUS.LOADED

  return true
end

-- Set up lazy loading on specific events
function Plugin:on(events)
  self.is_lazy = true
  self.events = type(events) ~= 'table' and { events } or events

  -- Create autocmds for each event
  for _, event in ipairs(self.events) do
    local autocmd_id = api.nvim_create_autocmd(event, {
      group = api.nvim_create_augroup(
        'minpm_' .. self.plugin_name .. '_' .. event,
        { clear = true }
      ),
      callback = function(args)
        -- Don't re-emit the event if we've already loaded the plugin
        if not self.loaded and self:load() then
          -- We need to re-emit the event, but carefully to avoid nesting too deep
          -- Instead of exec_autocmds, trigger the event using a different mechanism
          local event_data = args.data and vim.deepcopy(args.data) or {}

          -- Schedule the event emission to avoid nesting too deep
          vim.schedule(function()
            api.nvim_exec_autocmds(event, {
              modeline = false,
              data = event_data,
              group = vim.api.nvim_create_augroup(
                'minpm_' .. self.plugin_name .. '_after_load',
                { clear = true }
              ),
            })
          end)
        end
      end,
    })
    table.insert(self.autocmd_ids, autocmd_id)
  end

  return self
end

-- Set up lazy loading for specific filetypes
function Plugin:ft(filetypes)
  self.is_lazy = true
  self.filetypes = type(filetypes) ~= 'table' and { filetypes } or filetypes

  local autocmd_id = api.nvim_create_autocmd('FileType', {
    group = api.nvim_create_augroup('minpm_' .. self.plugin_name .. '_ft', { clear = true }),
    pattern = self.filetypes,
    callback = function(args)
      -- Don't re-emit the event if we've already loaded the plugin
      if not self.loaded and self:load() then
        api.nvim_exec_autocmds('FileType', {
          modeline = false,
          pattern = args.match,
        })
      end
    end,
  })
  table.insert(self.autocmd_ids, autocmd_id)

  return self
end

-- Set up lazy loading for specific commands
function Plugin:cmd(commands)
  self.is_lazy = true
  self.commands = type(commands) ~= 'table' and { commands } or commands

  for _, cmd_name in ipairs(self.commands) do
    -- Create a user command that loads the plugin and then executes the real command
    api.nvim_create_user_command(cmd_name, function(cmd_args)
      self:load()

      -- Execute the original command with the arguments
      local args = cmd_args.args ~= '' and ' ' .. cmd_args.args or ''
      local bang = cmd_args.bang and '!' or ''

      vim.cmd(cmd_name .. bang .. args)
    end, {
      nargs = '*',
      bang = true,
      complete = function(arg_lead, cmd_line, cursor_pos)
        -- If the plugin has a completion function, load the plugin first
        self:load()

        -- Try to use the original command's completion
        local ok, result = pcall(function()
          return vim.fn.getcompletion(cmd_line, 'cmdline')
        end)

        if ok then
          return result
        else
          return {}
        end
      end,
    })

    table.insert(self.user_commands, cmd_name)
  end

  return self
end

-- Set up lazy loading for specific keymaps
function Plugin:keys(mappings)
  self.is_lazy = true
  self.keys = type(mappings) ~= 'table' and { mappings } or mappings

  for _, mapping in ipairs(self.keys) do
    local mode, lhs, rhs, opts

    if type(mapping) == 'table' then
      mode = mapping[1] or 'n'
      lhs = mapping[2]
      rhs = mapping[3] or function() end
      opts = mapping[4] or {}
    else
      mode, lhs = 'n', mapping
      rhs = function() end
      opts = {}
    end

    -- Create a keymap that loads the plugin first
    vim.keymap.set(mode, lhs, function()
      if self:load() and type(rhs) == 'function' then
        rhs()
      elseif self:load() and type(rhs) == 'string' then
        -- If rhs is a string command
        vim.cmd(rhs)
      end
    end, opts)
  end

  return self
end

-- Mark plugin as a development plugin
function Plugin:dev()
  self.is_dev = true
  self.is_remote = false
  return self
end

-- Set plugin configuration options
function Plugin:setup(opts)
  self.setup_opts = opts
  return self
end

-- Set a function to run after plugin loads
function Plugin:config(fn)
  assert(type(fn) == 'function', 'Config must be a function')
  self.config_fn = fn
  return self
end

-- Set a function to run after dependencies load
function Plugin:after(fn)
  assert(type(fn) == 'function', 'After must be a function')
  self.after_fn = fn
  return self
end

-- Set plugin as a theme
function Plugin:theme(name)
  self.colorscheme = name or self.plugin_name

  -- If already installed, apply the theme
  async.async(function()
    local installed = async.await(self:is_installed())
    if installed then
      vim.schedule(function()
        vim.opt.rtp:append(vim.fs.joinpath(START_DIR, self.plugin_name))
        vim.cmd.colorscheme(self.colorscheme)
      end)
    end
  end)()

  return self
end

-- Install the plugin
function Plugin:install()
  if self.is_dev or not self.is_remote then
    return async.wrap(function(cb)
      cb(true)
    end)()
  end

  return async.wrap(function(callback)
    -- Check if already installed
    local installed = async.await(self:is_installed())
    if installed then
      callback(true)
      return
    end

    self.status = STATUS.INSTALLING
    ui:update_entry(self.name, self.status, 'Starting installation...')

    local path = self:get_path()
    local url = ('https://github.com/%s'):format(self.name)
    local cmd = { 'git', 'clone', '--progress', url, path }

    -- Ensure parent directory exists
    vim.fn.mkdir(vim.fs.dirname(path), 'p')

    local co = coroutine.running()
    vim.system(cmd, {
      timeout = DEFAULT_SETTINGS.git_timeout,
      stderr = function(_, data)
        if data and co then
          coroutine.resume(co, nil, data)
        end
      end,
    }, function(obj)
      -- Use schedule for UI updates in callbacks
      vim.schedule(function()
        if obj.code == 0 then
          self.status = STATUS.INSTALLED
          ui:update_entry(self.name, self.status, 'Installation complete')

          -- Apply colorscheme if this is a theme
          -- Make sure the plugin is loaded first
          if self.colorscheme then
            self:theme(self.colorscheme)
          end

          callback(true)
        else
          self.status = STATUS.ERROR
          ui:update_entry(self.name, self.status, 'Failed: ' .. (obj.stderr or 'Unknown error'))
          callback(false)
        end
      end)
    end)

    -- Process progress updates
    while true do
      local err, data = coroutine.yield()
      if not data then
        break
      end

      local lines = data:gsub('\r', '\n'):gsub('\n+', '\n')
      lines = vim.split(lines, '\n', { trimempty = true })

      if #lines > 0 then
        -- Schedule UI updates from coroutine callbacks
        vim.schedule(function()
          ui:update_entry(self.name, self.status, lines[#lines])
        end)
      end
    end
  end)()
end

-- Update the plugin
function Plugin:update()
  if self.is_dev or not self.is_remote then
    return async.wrap(function(cb)
      cb(true)
    end)()
  end

  return async.wrap(function(callback)
    -- Check if plugin is installed
    local installed = async.await(self:is_installed())
    if not installed then
      callback(true)
      return
    end

    self.status = STATUS.UPDATING
    ui:update_entry(self.name, self.status, 'Starting update...')

    local path = self:get_path()
    local cmd = { 'git', '-C', path, 'pull', '--progress' }

    local co = coroutine.running()
    vim.system(cmd, {
      timeout = DEFAULT_SETTINGS.git_timeout,
      stderr = function(_, data)
        if data and co then
          coroutine.resume(co, nil, data)
        end
      end,
    }, function(obj)
      -- Use schedule for UI updates in callbacks
      vim.schedule(function()
        if obj.code == 0 then
          self.status = STATUS.UPDATED
          ui:update_entry(self.name, self.status, 'Update complete')
          callback(true)
        else
          self.status = STATUS.ERROR
          ui:update_entry(self.name, self.status, 'Failed: ' .. (obj.stderr or 'Unknown error'))
          callback(false)
        end
      end)
    end)

    -- Process progress updates
    while true do
      local err, data = coroutine.yield()
      if not data then
        break
      end

      local lines = data:gsub('\r', '\n'):gsub('\n+', '\n')
      lines = vim.split(lines, '\n', { trimempty = true })

      if #lines > 0 then
        -- Schedule UI updates from coroutine callbacks
        vim.schedule(function()
          ui:update_entry(self.name, self.status, lines[#lines])
        end)
      end
    end
  end)()
end

-- =====================================================================
-- 6. Manager Functions
-- =====================================================================

-- Log a message
function M.log(level, message)
  local levels = { debug = 1, info = 2, warn = 3, error = 4 }
  local current_level = levels[DEFAULT_SETTINGS.log_level] or 2

  if levels[level] and levels[level] >= current_level then
    vim.notify(
      string.format('[minpm] %s', message),
      level == 'error' and vim.log.levels.ERROR
        or level == 'warn' and vim.log.levels.WARN
        or level == 'info' and vim.log.levels.INFO
        or vim.log.levels.DEBUG
    )
  end
end

-- Register a plugin
function M.use(spec)
  local plugin = Plugin.new(spec)

  -- Check for duplicate
  if plugin_map[plugin.name] then
    M.log('warn', string.format('Plugin %s is already registered, skipping duplicate', plugin.name))
    return plugin_map[plugin.name]
  end

  -- Add to collections
  table.insert(plugins, plugin)
  plugin_map[plugin.name] = plugin

  return plugin
end

-- Get plugin from registry
function M.get_plugin(name)
  return plugin_map[name]
end

-- Process dependencies for all plugins
local function resolve_dependencies()
  local resolved = {}
  local function resolve_plugin(name, chain)
    if resolved[name] then
      return true
    end

    -- Detect circular dependencies
    chain = chain or {}
    if vim.tbl_contains(chain, name) then
      local cycle = table.concat(chain, ' -> ') .. ' -> ' .. name
      M.log('error', 'Circular dependency detected: ' .. cycle)
      return false
    end

    -- Get the plugin
    local plugin = plugin_map[name]
    if not plugin then
      -- Auto-register missing dependency
      plugin = M.use(name)
    end

    -- Resolve dependencies first
    local new_chain = vim.list_extend({}, chain)
    table.insert(new_chain, name)

    for _, dep_name in ipairs(plugin.dependencies) do
      resolve_plugin(dep_name, new_chain)
    end

    resolved[name] = true
    return true
  end

  -- Resolve each plugin
  for name, _ in pairs(plugin_map) do
    resolve_plugin(name)
  end
end

-- Set up auto-install
local function setup_auto_install()
  api.nvim_create_autocmd('UIEnter', {
    group = api.nvim_create_augroup('minpm_auto_install', { clear = true }),
    callback = function()
      -- We're already in a UIEnter event, so we should be careful about recursion
      -- We want to install plugins but not trigger another UIEnter event
      -- Use vim.schedule to avoid nesting too deep
      vim.schedule(function()
        M.install()
      end)
    end,
    once = true, -- Only trigger once to avoid recursion
  })
end

-- Install all plugins
function M.install()
  resolve_dependencies()

  local plugins_to_install = {}

  -- Create installation tasks
  async.async(function()
    -- Find plugins that need installation
    for _, plugin in ipairs(plugins) do
      if plugin.is_remote and not plugin.is_dev then
        local installed = async.await(plugin:is_installed())
        if not installed then
          table.insert(plugins_to_install, plugin)
        end
      end
    end

    if #plugins_to_install == 0 then
      return
    end

    M.log('info', 'Installing plugins...')
    ui:open()

    for _, plugin in ipairs(plugins_to_install) do
      task_queue:enqueue(function(done)
        async.async(function()
          async.await(plugin:install())
          done()
        end)()
      end)
    end

    -- Set completion callback
    task_queue:on_complete(function()
      M.log('info', 'All plugins installed successfully.')

      -- Close UI after a delay
      vim.defer_fn(function()
        ui:close()
      end, 2000)
    end)
  end)()
end

-- Update all plugins
function M.update()
  resolve_dependencies()

  M.log('info', 'Updating plugins...')
  local plugins_to_update = {}

  -- Create update tasks
  async.async(function()
    -- Find plugins that need updating
    for _, plugin in ipairs(plugins) do
      if plugin.is_remote and not plugin.is_dev then
        local installed = async.await(plugin:is_installed())
        if installed then
          table.insert(plugins_to_update, plugin)
        end
      end
    end

    if #plugins_to_update == 0 then
      M.log('info', 'No plugins to update.')
      return
    end

    ui:open()

    for _, plugin in ipairs(plugins_to_update) do
      task_queue:enqueue(function(done)
        async.async(function()
          async.await(plugin:update())
          done()
        end)()
      end)
    end

    -- Set completion callback
    task_queue:on_complete(function()
      M.log('info', 'All plugins updated successfully.')

      -- Close UI after a delay
      vim.defer_fn(function()
        ui:close()
      end, 2000)
    end)
  end)()
end

-- Load all installed plugins
function M.load_all()
  async.async(function()
    for _, plugin in ipairs(plugins) do
      if not plugin.is_lazy then
        local installed = async.await(plugin:is_installed())
        if installed then
          plugin:load()
        end
      end
    end
  end)()
end

-- Clean unused plugins
function M.clean()
  -- Get all installed plugins in both directories
  local installed_dirs = {}

  local function scan_dir(dir)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end

    while true do
      local name, type = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end

      if type == 'directory' then
        installed_dirs[name] = dir
      end
    end
  end

  scan_dir(START_DIR)
  scan_dir(OPT_DIR)

  -- Find plugins not in our registry
  local to_remove = {}
  for name, dir in pairs(installed_dirs) do
    local found = false
    for _, plugin in ipairs(plugins) do
      if plugin.plugin_name == name then
        found = true
        break
      end
    end

    if not found then
      table.insert(to_remove, { name = name, dir = dir })
    end
  end

  -- Remove unused plugins
  if #to_remove > 0 then
    M.log('info', string.format('Cleaning %d unused plugins...', #to_remove))

    for _, item in ipairs(to_remove) do
      local path = vim.fs.joinpath(item.dir, item.name)
      M.log('info', string.format('Removing %s', path))

      -- Use async version of delete
      async.async(function()
        vim.fn.delete(path, 'rf')
      end)()
    end

    M.log('info', 'Clean complete.')
  else
    M.log('info', 'No unused plugins to clean.')
  end
end

-- Create user commands
local function create_commands()
  vim.api.nvim_create_user_command('MinPMInstall', function()
    M.install()
  end, {
    desc = 'Install plugins',
  })

  vim.api.nvim_create_user_command('MinPMUpdate', function()
    M.update()
  end, {
    desc = 'Update plugins',
  })

  vim.api.nvim_create_user_command('MinPMClean', function()
    M.clean()
  end, {
    desc = 'Clean unused plugins',
  })
end

-- Setup auto-install if enabled
if DEFAULT_SETTINGS.auto_install then
  setup_auto_install()
end

-- Create commands
create_commands()
