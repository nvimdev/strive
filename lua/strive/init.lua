-- Strive: Minimalist Plugin Manager for Neovim
-- A lightweight, feature-rich plugin manager with support for lazy loading,
-- dependencies, and asynchronous operations.

local api, uv, if_nil, Iter, ffi = vim.api, vim.uv, vim.F.if_nil, vim.iter, require('ffi')

-- =====================================================================
-- 1. Configuration and Constants
-- =====================================================================
local M = {}
local plugins = {}
local plugin_map = {}

-- Data paths
local data_dir = vim.fn.stdpath('data')
local START_DIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'strive', 'start')
local OPT_DIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'strive', 'opt')

-- Add to packpath
vim.opt.packpath:prepend(vim.fs.joinpath(data_dir, 'site'))
vim.g.strim_loaded = 0

local DEFAULT_SETTINGS = {
  max_concurrent_tasks = if_nil(vim.g.strive_max_concurrent_tasks, 5),
  auto_install = if_nil(vim.g.strive_auto_install, true),
  log_level = if_nil(vim.g.strive_log_level, 'warn'),
  git_timeout = if_nil(vim.g.strive_git_timeout, 60000),
  install_retry = if_nil(vim.g.strive_install_with_retry, false),
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
local Async = {}

-- Result type to handle errors properly
local Result = {}
Result.__index = Result

function Result.success(value)
  return setmetatable({ success = true, value = value, error = nil }, Result)
end

function Result.failure(err)
  return setmetatable({ success = false, value = nil, error = err }, Result)
end

-- Wrap a function to return a promise
function Async.wrap(func)
  return function(...)
    local args = { ... }
    return function(callback)
      local function handle_result(...)
        local results = { ... }
        if #results == 0 then
          -- No results
          callback(Result.success(nil))
        elseif #results == 1 then
          -- Single result
          callback(Result.success(results[1]))
        else
          -- Multiple results
          callback(Result.success(results))
        end
      end

      -- Handle any errors in the wrapped function
      local status, err = pcall(function()
        table.insert(args, handle_result)
        func(unpack(args))
      end)

      if not status then
        callback(Result.failure(err))
      end
    end
  end
end

-- Wrap vim.system to provide better error handling and cleaner usage
function Async.system(cmd, opts)
  opts = opts or {}
  return function(callback)
    local progress_data = {}
    local error_data = {}
    local stderr_callback = opts.stderr

    -- Setup options
    local system_opts = vim.deepcopy(opts)

    -- Capture stderr for progress if requested
    if stderr_callback then
      system_opts.stderr = function(_, data)
        if data then
          table.insert(error_data, data)
          stderr_callback(_, data)
        end
      end
    end

    -- Call vim.system with proper error handling
    vim.system(cmd, system_opts, function(obj)
      -- Success is 0 exit code
      local success = obj.code == 0

      if success then
        callback(Result.success({
          stdout = obj.stdout,
          stderr = obj.stderr,
          code = obj.code,
          signal = obj.signal,
          progress = progress_data,
        }))
      else
        callback(Result.failure({
          message = 'Command failed with exit code: ' .. obj.code,
          stdout = obj.stdout,
          stderr = obj.stderr,
          code = obj.code,
          signal = obj.signal,
          progress = progress_data,
        }))
      end
    end)
  end
end

-- Await a promise - execution is paused until promise resolves
function Async.await(promise)
  local co = coroutine.running()
  if not co then
    error('Cannot await outside of an async function')
  end

  promise(function(result)
    vim.schedule(function()
      local ok = coroutine.resume(co, result)
      if not ok then
        vim.notify(debug.traceback(co), vim.log.levels.ERROR)
      end
    end)
  end)

  local result = coroutine.yield()

  -- Propagate errors by throwing them
  if not result.success then
    error(result.error)
  end

  return result.value
end

-- Safely await a promise, returning a result instead of throwing
function Async.try_await(promise)
  local co = coroutine.running()
  if not co then
    error('Cannot await outside of an async function')
  end

  promise(function(result)
    vim.schedule(function()
      local ok = coroutine.resume(co, result)
      if not ok then
        vim.notify(debug.traceback(co), vim.log.levels.ERROR)
      end
    end)
  end)

  return coroutine.yield()
end

-- Create an async function that can use await
function Async.async(func)
  return function(...)
    local args = { ... }
    local co = coroutine.create(function()
      local status, result = pcall(function()
        return func(unpack(args))
      end)

      if not status then
        vim.schedule(function()
          vim.notify('Async error: ' .. tostring(result), vim.log.levels.ERROR)
        end)
      end

      return status and result or nil
    end)

    local function step(...)
      local ok, err = coroutine.resume(co, ...)
      if not ok then
        vim.schedule(function()
          vim.notify('Coroutine error: ' .. debug.traceback(co, err), vim.log.levels.ERROR)
        end)
      end
    end

    step()
  end
end

-- Run multiple promises concurrently and wait for all to complete
function Async.all(promises)
  return function(callback)
    if #promises == 0 then
      callback(Result.success({}))
      return
    end

    local results = {}
    local completed = 0
    local had_errors = false
    local first_error = nil

    for i, promise in ipairs(promises) do
      promise(function(result)
        results[i] = result
        completed = completed + 1

        -- Keep track of first error
        if not result.success and not had_errors then
          had_errors = true
          first_error = result.error
        end

        if completed == #promises then
          if had_errors then
            callback(Result.failure(first_error))
          else
            -- Extract values from results
            local values = {}
            for j, res in ipairs(results) do
              values[j] = res.value
            end
            callback(Result.success(values))
          end
        end
      end)
    end
  end
end

-- Simple delay function (sleep)
function Async.delay(ms)
  return function(callback)
    vim.defer_fn(function()
      callback(Result.success(nil))
    end, ms)
  end
end

-- Retry a promise with exponential backoff
function Async.retry(promise_fn, max_retries, initial_delay)
  max_retries = max_retries or 3
  initial_delay = initial_delay or 100

  return function(callback)
    local attempt = 0

    local function try()
      attempt = attempt + 1
      promise_fn()(function(result)
        if result.success or attempt >= max_retries then
          callback(result)
        else
          -- Exponential backoff
          local delay = initial_delay * (2 ^ (attempt - 1))
          vim.defer_fn(try, delay)
        end
      end)
    end

    try()
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
  M.log(
    'debug',
    string.format('TaskQueue status: %d queued, %d active', #self.queue, self.active_tasks)
  )

  if #self.queue == 0 and self.active_tasks == 0 and self.on_empty then
    M.log('debug', 'All tasks completed, calling on_empty callback')
    self.on_empty()
    return
  end
  M.log(
    'debug',
    string.format('Starting new task, active: %d, queued: %d', self.active_tasks, #self.queue)
  )
  while self.active_tasks < self.max_concurrent and #self.queue > 0 do
    local task = table.remove(self.queue, 1)
    self.active_tasks = self.active_tasks + 1

    task(function()
      self.active_tasks = self.active_tasks - 1
      self:process()
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
    title = 'Strive Plugin Manager',
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
  api.nvim_buf_set_name(self.bufnr, 'strive-Progress')

  -- Set key mappings for the buffer
  self:set_keymaps()

  return self
end

-- Set key mappings for the window
function ProgressWindow:set_keymaps()
  local opts = { buffer = self.bufnr }
  for _, key in ipairs({ 'q', '<ESC>' }) do
    vim.keymap.set('n', key, function()
      self:close()
    end, opts)
  end

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
  if vim.startswith(name, vim.env.HOME) then
    spec.dev = true
  end
  local parts = vim.split(name, '/', { trimempty = true })
  local plugin_name = parts[#parts]:gsub('%.git$', '')

  local self = setmetatable({
    id = 0,
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
    setup_opts = spec.setup or {}, -- Options for plugin setup()
    init_opts = spec.init, -- Options for before load plugin
    config_opts = spec.config, -- Config function to run after loading
    after_fn = spec.after, -- Function to run after dependencies load
    colorscheme = spec.theme, -- Theme to apply if this is a colorscheme

    -- Dependencies
    dependencies = spec.depends or {}, -- Dependencies

    user_commands = {}, -- Created user commands
    build_action = spec.build or nil,
  }, Plugin)

  return self
end

-- Get the plugin installation path
function Plugin:get_path()
  if not self.is_dev then
    return vim.fs.joinpath(self.is_lazy and OPT_DIR or START_DIR, self.plugin_name)
  end
  return vim.g.strive_dev_path and vim.fs.joinpath(vim.g.strive_dev_path, self.plugin_name)
    or self.name
end

-- Check if plugin is installed (async version)
function Plugin:is_installed()
  return Async.wrap(function(callback)
    uv.fs_stat(self:get_path(), function(err, stat)
      callback(not err and stat and stat.type == 'directory')
    end)
  end)()
end

local function load_opts(opt)
  if opt then
    if type(opt) == 'string' then
      vim.cmd(opt)
    elseif type(opt) == 'function' then
      opt()
    end
  end
end

function Plugin:packadd()
  -- If it's a lazy-loaded plugin, add it
  if self.is_lazy then
    if not self.is_dev then
      vim.cmd.packadd(self.plugin_name)
    else
      vim.opt.rtp:append(self:get_path())
    end
  end
end

-- Load a plugin and its dependencies
function Plugin:load()
  if self.loaded then
    return true
  end

  -- Check if plugin exists
  local stat = uv.fs_stat(self:get_path())
  if not stat or stat.type ~= 'directory' then
    return false
  end

  -- Prevent recursive loading
  -- Set loaded to true before actual loading to prevent infinite loops
  self.loaded = true
  vim.g.strim_loaded = vim.g.strim_loaded + 1

  Iter(self.dependencies):map(function(d)
    if not d.loaded then
      d:load()
    end
  end)

  load_opts(self.init_opts)

  self:packadd()

  self:call_setup()
  load_opts(self.config_opts)

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
    local pattern
    if event:find('%s') then
      local t = vim.split(event, '%s')
      event, pattern = t[1], t[2]
    end
    api.nvim_create_autocmd(event, {
      group = api.nvim_create_augroup(
        'strive_' .. self.plugin_name .. '_' .. event,
        { clear = true }
      ),
      pattern = pattern,
      once = true,
      callback = function(args)
        -- Don't re-emit the event if we've already loaded the plugin
        if not self.loaded and self:load() and args.event == 'FileType' then
          -- We need to re-emit the event, but carefully to avoid nesting too deep
          -- Instead of exec_autocmds, trigger the event using a different mechanism
          local event_data = args.data and vim.deepcopy(args.data) or {}

          -- Schedule the event emission to avoid nesting too deep
          vim.schedule(function()
            api.nvim_exec_autocmds(event, {
              modeline = false,
              data = event_data,
            })
          end)
        end
      end,
    })
  end

  return self
end

-- Set up lazy loading for specific filetypes
function Plugin:ft(filetypes)
  self.is_lazy = true
  self.filetypes = type(filetypes) ~= 'table' and { filetypes } or filetypes
  api.nvim_create_autocmd('FileType', {
    group = api.nvim_create_augroup('strive_' .. self.plugin_name .. '_ft', { clear = true }),
    pattern = self.filetypes,
    once = true,
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
      complete = function(_, cmd_line, _)
        -- If the plugin has a completion function, load the plugin first
        self:load()

        -- Try to use the original command's completion
        local ok, result = pcall(function()
          return vim.fn.getcompletion(cmd_line, 'cmdline')
        end)
        return ok and result or {}
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

function Plugin:init(opts)
  self.init_opts = opts
  return self
end

-- Set a function to run after plugin loads
function Plugin:config(opts)
  self.config_opts = opts
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
  Async.async(function()
    local installed = Async.await(self:is_installed())
    if installed then
      vim.schedule(function()
        vim.opt.rtp:append(vim.fs.joinpath(START_DIR, self.plugin_name))
        vim.cmd.colorscheme(self.colorscheme)
      end)
    end
  end)()

  return self
end

function Plugin:call_setup()
  local module_name = self.plugin_name:gsub('%.nvim$', ''):gsub('-nvim$', ''):gsub('^nvim%-', '')
  for _, mod in ipairs({ module_name, self.plugin_name }) do
    -- Try to load the module
    local ok, module = pcall(require, mod)
    if ok and type(module) == 'table' then
      local setup = rawget(module, 'setup')
      if setup and type(setup) == 'function' then
        setup(self.setup_opts)
        break
      end
    end
  end
end

function Plugin:load_rtp(callback)
  local path = self:get_path()
  vim.opt.rtp:append(path)
  self:call_setup()
  callback()
end

function Plugin:build(action)
  assert(type(action) == 'string')
  self.build_action = action
  return self
end

-- Add dependency to a plugin
function Plugin:depends(deps)
  deps = type(deps) == 'string' and { deps } or deps
  -- Extend the current dependencies
  for _, dep in ipairs(deps) do
    if not plugins[dep] then
      local d = M.use(dep)
      d.is_lazy = true
      table.insert(self.dependencies, d)
    end
  end
  return self
end

-- Install the plugin
function Plugin:install()
  if self.is_dev or not self.is_remote then
    return Async.wrap(function(cb)
      cb(true)
    end)()
  end

  return Async.wrap(function(callback)
    -- Try to install with proper error handling
    local path = self:get_path()
    local url = ('https://github.com/%s'):format(self.name)
    local cmd = { 'git', 'clone', '--progress', url, path }

    -- Ensure parent directory exists
    vim.fn.mkdir(vim.fs.dirname(path), 'p')

    -- Update status
    self.status = STATUS.INSTALLING
    ui:update_entry(self.name, self.status, 'Starting installation...')

    -- Use our new Async.system wrapper
    local result = Async.try_await(Async.system(cmd, {
      timeout = DEFAULT_SETTINGS.git_timeout,
      stderr = function(_, data)
        if data then
          -- Update progress in UI
          local lines = data:gsub('\r', '\n'):gsub('\n+', '\n')
          lines = vim.split(lines, '\n', { trimempty = true })

          if #lines > 0 then
            vim.schedule(function()
              ui:update_entry(self.name, self.status, lines[#lines])
            end)
          end
        end
      end,
    }))

    if result.success then
      self.status = STATUS.INSTALLED
      ui:update_entry(self.name, self.status, 'Installation complete')

      -- Apply colorscheme if this is a theme
      if self.colorscheme then
        self:theme(self.colorscheme)
      end

      -- Run build command if specified
      if self.build_action then
        self:load_rtp(function()
          vim.cmd(self.build_action)
        end)
      end
    else
      self.status = STATUS.ERROR
      ui:update_entry(
        self.name,
        self.status,
        'Failed: ' .. (result.error.stderr or 'Unknown error') .. ' code: ' .. result.error.code
      )
    end
    callback(result.success)
  end)()
end

function Plugin:has_updates()
  return Async.wrap(function(callback)
    if self.is_dev or not self.is_remote then
      callback(false)
      return
    end

    local path = self:get_path()
    local fetch_result =
      Async.try_await(Async.system({ 'git', '-C', self:get_path(), 'remote', 'update' }))
    if not fetch_result.success then
      callback(false)
      return
    end
    -- Check local status
    local status_result = Async.try_await(Async.system({ 'git', '-C', path, 'status', '-uno' }))
    if not status_result.success then
      callback(false)
      return
    end

    local stdout = status_result.value.stdout
    local behind = stdout:match('behind') ~= nil
    callback(behind)
  end)()
end

function Plugin:update()
  if self.is_dev or not self.is_remote then
    return Async.wrap(function(cb)
      cb(true, 'skip')
    end)()
  end

  return Async.wrap(function(callback)
    local installed
    local install_result = Async.try_await(self:is_installed())

    if install_result.success then
      installed = install_result.value
    else
      self.status = STATUS.ERROR
      ui:update_entry(
        self.name,
        self.status,
        'Error checking installation: ' .. tostring(install_result.error)
      )
      callback(false, 'error_checking')
      return
    end

    if not installed then
      callback(true, 'not_installed')
      return
    end

    -- Check for updates
    local updates_result = Async.try_await(self:has_updates())
    local has_updates

    if updates_result.success then
      has_updates = updates_result.value
    else
      self.status = STATUS.ERROR
      ui:update_entry(
        self.name,
        self.status,
        'Error checking updates: ' .. tostring(updates_result.error)
      )
      callback(false, 'error_checking_updates')
      return
    end

    if not has_updates then
      self.status = STATUS.UPDATED
      ui:update_entry(self.name, self.status, 'Already up to date')
      callback(true, 'up_to_date')
      return
    end

    -- Update the plugin
    self.status = STATUS.UPDATING
    ui:update_entry(self.name, self.status, 'Starting update...')

    local path = self:get_path()
    local cmd = { 'git', '-C', path, 'pull', '--progress' }

    -- Use our new Async.system wrapper
    local result = Async.try_await(Async.system(cmd, {
      timeout = DEFAULT_SETTINGS.git_timeout,
      stderr = function(_, data)
        if data then
          -- Update progress in UI
          local lines = data:gsub('\r', '\n'):gsub('\n+', '\n')
          lines = vim.split(lines, '\n', { trimempty = true })

          if #lines > 0 then
            vim.schedule(function()
              ui:update_entry(self.name, self.status, lines[#lines])
            end)
          end
        end
      end,
    }))

    -- Handle result
    if result.success then
      self.status = STATUS.UPDATED
      ui:update_entry(self.name, self.status, 'Update complete')
      callback(true, 'updated')
    else
      self.status = STATUS.ERROR
      local error_msg = result.error.stderr or 'Unknown error'
      ui:update_entry(self.name, self.status, 'Failed: ' .. error_msg)
      callback(false, error_msg)
    end
  end)()
end

function Plugin:install_with_retry()
  if self.is_dev or not self.is_remote then
    return Async.wrap(function(cb)
      cb(true)
    end)()
  end

  return Async.wrap(function(callback)
    -- Check if already installed
    local installed = Async.await(self:is_installed())
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

    -- Use retry with the system command (3 retries with exponential backoff)
    local result = Async.try_await(Async.retry(function()
      return Async.system(cmd, {
        timeout = DEFAULT_SETTINGS.git_timeout,
        stderr = function(_, data)
          if data then
            -- Update progress in UI
            local lines = data:gsub('\r', '\n'):gsub('\n+', '\n')
            lines = vim.split(lines, '\n', { trimempty = true })

            if #lines > 0 then
              vim.schedule(function()
                ui:update_entry(self.name, self.status, lines[#lines])
              end)
            end
          end
        end,
      })
    end, 3, 1000)) -- 3 retries, starting with 1000ms delay

    -- Handle result
    if result.success then
      self.status = STATUS.INSTALLED
      ui:update_entry(self.name, self.status, 'Installation complete')

      -- Apply colorscheme if this is a theme
      if self.colorscheme then
        self:theme(self.colorscheme)
      end

      -- Run build command if specified
      if self.build_action then
        self:load_rtp(function()
          vim.cmd(self.build_action)
        end)
      end
    else
      self.status = STATUS.ERROR
      ui:update_entry(
        self.name,
        self.status,
        'Failed after retries: '
          .. (result.error.stderr or 'Unknown error')
          .. ' code: '
          .. result.error.code
      )
    end
    callback(result.success)
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
      string.format('[strive] %s', message),
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
  plugin.id = #plugins + 1
  -- Add to collections
  table.insert(plugins, plugin)
  plugin_map[plugin.name] = plugin

  return plugin
end

-- Get plugin from registry
function M.get_plugin(name)
  return plugin_map[name]
end

-- Set up auto-install
local function setup_auto_install()
  api.nvim_create_autocmd('UIEnter', {
    group = api.nvim_create_augroup('strive_auto_install', { clear = true }),
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
  Async.async(function()
    local plugins_to_install = {}

    -- Find plugins that need installation
    for _, plugin in ipairs(plugins) do
      if plugin.is_remote and not plugin.is_dev then
        local result = Async.try_await(plugin:is_installed())

        if result.success and not result.value then
          table.insert(plugins_to_install, plugin)
        elseif not result.success then
          M.log(
            'error',
            string.format(
              'Error checking if %s is installed: %s',
              plugin.name,
              tostring(result.error)
            )
          )
        end
      end
    end

    if #plugins_to_install == 0 then
      M.log('info', 'No plugins to install.')
      return
    end

    M.log('info', string.format('Installing %d plugins...', #plugins_to_install))
    ui:open()

    -- Create installation tasks with proper error handling
    local install_tasks = {}
    for _, plugin in ipairs(plugins_to_install) do
      table.insert(install_tasks, function(done)
        Async.async(function()
          local result = Async.try_await(
            DEFAULT_SETTINGS.install_retry and Plugin:install_with_retry() or plugin:install()
          )
          if not result.success then
            M.log(
              'error',
              string.format('Failed to install %s: %s', plugin.name, tostring(result.error))
            )
          end

          done()
        end)()
      end)
    end

    -- Queue all tasks
    for _, task in ipairs(install_tasks) do
      task_queue:enqueue(task)
    end

    -- Set completion callback
    task_queue:on_complete(function()
      M.log('info', 'Installation completed.')

      -- Close UI after a delay
      Async.await(Async.delay(2000))
      ui:close()
    end)
  end)()
end

-- Update all plugins with concurrent operations
function M.update()
  Async.async(function()
    M.log('info', 'Checking for updates...')
    local plugins_to_update = {}

    -- Add Strive plugin itself to the update list
    local strive_plugin = Plugin.new({
      name = 'nvimdev/strive',
      plugin_name = 'strive',
    })

    -- Find plugins that need updating with proper error handling
    for _, plugin in ipairs(plugins) do
      if plugin.is_remote and not plugin.is_dev then
        local result = Async.try_await(plugin:is_installed())

        if result.success and result.value then
          table.insert(plugins_to_update, plugin)
        elseif not result.success then
          M.log(
            'error',
            string.format(
              'Error checking if %s is installed: %s',
              plugin.name,
              tostring(result.error)
            )
          )
        end
      end
    end

    -- Check if Strive itself is installed
    local strive_result = Async.try_await(strive_plugin:is_installed())
    if strive_result.success and strive_result.value then
      table.insert(plugins_to_update, strive_plugin)
    end

    if #plugins_to_update == 0 then
      M.log('debug', 'No plugins to update.')
      return
    end

    ui:open()

    local updated_count = 0
    local skipped_count = 0
    local error_count = 0

    -- Update plugins in batches for better control and error handling
    local batch_size = DEFAULT_SETTINGS.max_concurrent_tasks
    local total_batches = math.ceil(#plugins_to_update / batch_size)

    for batch = 1, total_batches do
      local start_idx = (batch - 1) * batch_size + 1
      local end_idx = math.min(batch * batch_size, #plugins_to_update)
      local current_batch = {}

      for i = start_idx, end_idx do
        local plugin = plugins_to_update[i]
        table.insert(current_batch, plugin:update())
      end

      -- Wait for current batch to complete with error handling
      local batch_result = Async.try_await(Async.all(current_batch))

      if batch_result.success then
        -- Process successful results
        for _, result in ipairs(batch_result.value) do
          local success, status = unpack(result)
          if success then
            if status == 'updated' then
              updated_count = updated_count + 1
            elseif status == 'up_to_date' then
              skipped_count = skipped_count + 1
            end
          else
            error_count = error_count + 1
          end
        end
      else
        M.log('error', string.format('Error updating batch: %s', tostring(batch_result.error)))
        error_count = error_count + (end_idx - start_idx + 1)
      end
    end

    -- Report results
    if updated_count > 0 then
      M.log(
        'info',
        string.format(
          'Updated %d plugins, %d already up to date, %d errors.',
          updated_count,
          skipped_count,
          error_count
        )
      )
    elseif error_count > 0 then
      M.log('warn', string.format('No plugins updated, %d errors occurred.', error_count))
    else
      M.log('info', 'All plugins already up to date.')
    end

    -- Close UI after a delay
    Async.await(Async.delay(2000))
    ui:close()
  end)()
end

-- Clean unused plugins
function M.clean()
  Async.async(function()
    -- Get all installed plugins in both directories
    local installed_dirs = {}

    local function scan_dir(dir)
      -- Use pcall for error handling
      local ok, handle = pcall(vim.uv.fs_scandir, dir)
      if not ok or not handle then
        M.log('error', string.format('Error scanning directory %s: %s', dir, tostring(handle)))
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

    -- Remove unused plugins with proper error handling
    if #to_remove > 0 then
      M.log('info', string.format('Cleaning %d unused plugins...', #to_remove))

      for _, item in ipairs(to_remove) do
        local path = vim.fs.joinpath(item.dir, item.name)
        M.log('info', string.format('Removing %s', path))

        -- Use async delete with error handling
        local ok, err = pcall(function()
          vim.fn.delete(path, 'rf')
        end)

        if not ok then
          M.log('error', string.format('Error deleting %s: %s', path, tostring(err)))
        end
      end

      M.log('info', 'Clean complete.')
    else
      M.log('info', 'No unused plugins to clean.')
    end
  end)()
end

local function create_commands()
  local t = { install = 1, update = 2, clean = 3 }
  api.nvim_create_user_command('Strive', function(args)
    if t[args.args] then
      M[args.args]()
    end
  end, {
    desc = 'Install plugins',
    nargs = '+',
    complete = function()
      return vim.tbl_keys(t)
    end,
  })
end

-- Setup auto-install if enabled
if DEFAULT_SETTINGS.auto_install then
  setup_auto_install()
end

create_commands()

ffi.cdef([[
  typedef long time_t;
  typedef int clockid_t;
  typedef struct timespec {
    time_t   tv_sec;
    long     tv_nsec;
  } timespec;
  int clock_gettime(clockid_t clk_id, struct timespec *tp);
]])
local CLOCK_PROCESS_CPUTIME_ID = vim.uv.os_uname().sysname:match('Darwin') and 12 or 2

api.nvim_create_autocmd('UIEnter', {
  callback = function()
    if vim.g.strive_startup_time ~= nil then
      return
    end

    local t = assert(ffi.new('timespec[?]', 1))
    ffi.C.clock_gettime(CLOCK_PROCESS_CPUTIME_ID, t)
    vim.g.strive_startup_time = tonumber(t[0].tv_sec) * 1e3 + tonumber(t[0].tv_nsec) / 1e6
  end,
})

return { use = M.use }
