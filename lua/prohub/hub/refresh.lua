---The timer and the events that render a hub again while the user can see it:
---every `refresh_interval` milliseconds while the hub buffer is shown in a
---window of the current tabpage and Neovim has focus, and at once when the
---buffer is entered or Neovim gains focus.
---
---Neovim has no query for the focus of the terminal, so this module follows
---FocusGained and FocusLost, and it assumes focus until the first FocusLost,
---because a terminal without focus events never sends one. Losing focus stops
---the timer, and so does hiding the buffer, closing its window and leaving its
---tabpage. Every tick checks the rule again and stops the timer when it no
---longer holds, so a missed event never keeps a hidden hub refreshing.
---
---This module renders nothing: the hub passes the action that renders the hub
---again, and the action runs on the main loop. One augroup belongs to each hub
---buffer, and `detach` is what a closed hub and a wiped buffer call, so one
---hub never leaves a timer or an autocommand behind.
---
---    local refresh = require('prohub.hub.refresh')
---
---    refresh.attach(buffer, function() return rerender(hub) end)
---    refresh.detach(buffer)
---@class prohub.hub.refresh
local M = {}

local config = require('prohub.config')
local log = require('prohub.log')
local validate = require('prohub.validate')

---The timer and the events that follow one hub buffer.
---@class prohub.hub.refresh.State
---@field buffer integer The buffer of the hub.
---@field refresh fun(): true|nil ok, string? err Render the hub again.
---@field interval integer Milliseconds between two renders of the hub.
---@field group integer The augroup of the buffer.
---@field timer? any The timer, while it runs.
local State = {}
State.__index = State

---The states this module follows, by buffer.
---@type table<integer, prohub.hub.refresh.State>
local states = {}

---Whether Neovim has focus. A terminal without focus events never sends
---FocusLost, so the module assumes focus until one arrives.
---@type boolean
local focused = true

---The events after which the rule may have changed, and that Neovim delivers
---in the middle of the change, so they are checked once the change is over.
---@type string[]
local moved = {
    'TabEnter',
    'TabLeave',
    'TabClosed',
    'WinEnter',
    'WinLeave',
    'WinClosed',
}

---Whether the state still follows its buffer.
---@return boolean
function State:live()
    return states[self.buffer] == self
        and vim.api.nvim_buf_is_valid(self.buffer)
end

---Whether the hub of the state is shown in a window of the current tabpage and
---Neovim has focus, which is the rule the timer obeys.
---@return boolean
function State:holds()
    if not focused or not self:live() then
        return false
    end

    local tabpage = vim.api.nvim_get_current_tabpage()
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if vim.api.nvim_win_get_buf(window) == self.buffer then
            return true
        end
    end
    return false
end

---Close the timer of the state, if it runs.
function State:stop()
    local timer = self.timer
    if not timer then
        return
    end

    self.timer = nil
    pcall(function()
        timer:stop()
        if not timer:is_closing() then
            timer:close()
        end
    end)
end

---Ask the hub to render itself again. A failure that throws is logged,
---because no key asked for this render.
function State:trigger()
    local called, err = pcall(self.refresh)
    if not called then
        log.error(
            'the hub of %s could not be rendered again: %s',
            self.buffer,
            tostring(err)
        )
    end
end

---Start the timer of the state, unless it runs already or the rule fails.
function State:start()
    if self.timer or not self:holds() then
        return
    end

    local timer = vim.uv.new_timer()
    if not timer then
        log.error('no timer could be started for the hub of %s', self.buffer)
        return
    end

    self.timer = timer
    timer:start(self.interval, self.interval, function()
        -- The callback of a timer runs in a fast event, where the editor API
        -- is off limits until the main loop takes over.
        vim.schedule(function()
            if not self:live() or not self:holds() then
                self:stop()
                return
            end
            self:trigger()
        end)
    end)
end

---Stop following the buffer: forget the state, close its timer and clear its
---autocommands.
function State:detach()
    states[self.buffer] = nil
    self:stop()
    if self.group then
        pcall(vim.api.nvim_del_augroup_by_id, self.group)
        self.group = nil
    end
end

---Keep the timer running exactly while the rule holds, and stop following a
---buffer that is gone.
function State:update()
    if not self:live() then
        return M.detach(self.buffer)
    end
    if self:holds() then
        self:start()
    else
        self:stop()
    end
end

---An autocommand that checks the rule once the editor is done with the change
---that fired it.
---@return fun() callback
function State:watched()
    return function()
        vim.schedule(function()
            self:update()
        end)
    end
end

---Follow one buffer: the timer, the events that start and stop it, and the two
---events that render the hub again at once.
function State:install()
    local group = vim.api.nvim_create_augroup(
        ('prohub_hub_refresh_%d'):format(self.buffer),
        { clear = true }
    )
    self.group = group

    -- A wiped buffer cannot be shown again, so it leaves nothing behind.
    vim.api.nvim_create_autocmd('BufWipeout', {
        group = group,
        buffer = self.buffer,
        once = true,
        callback = function()
            M.detach(self.buffer)
        end,
    })

    -- Entering the buffer is the moment the user comes back to the hub.
    vim.api.nvim_create_autocmd('BufEnter', {
        group = group,
        buffer = self.buffer,
        callback = function()
            if not self:live() or not self:holds() then
                return
            end
            self:start()
            self:trigger()
        end,
    })

    -- A hidden buffer is shown in no window.
    vim.api.nvim_create_autocmd('BufHidden', {
        group = group,
        buffer = self.buffer,
        callback = self:watched(),
    })

    -- Focus is what the timer cannot read from the editor.
    vim.api.nvim_create_autocmd('FocusGained', {
        group = group,
        pattern = '*',
        callback = function()
            focused = true
            if not self:live() or not self:holds() then
                return
            end
            self:start()
            self:trigger()
        end,
    })
    vim.api.nvim_create_autocmd('FocusLost', {
        group = group,
        pattern = '*',
        callback = function()
            focused = false
            self:stop()
        end,
    })

    for _, event in ipairs(moved) do
        vim.api.nvim_create_autocmd(event, {
            group = group,
            pattern = '*',
            callback = self:watched(),
        })
    end
end

---Stop following a buffer: close its timer and clear its autocommands.
---@param buffer integer
---@return true|nil ok
---@return string? err
function M.detach(buffer)
    local ok, err = validate.check({ buffer = { buffer, 'number' } })
    if not ok then
        return nil, err
    end

    local state = states[buffer]
    if not state then
        return true
    end

    state:detach()
    return true
end

---Follow a hub buffer: render it again on a timer while it is shown in a
---window of the current tabpage and Neovim has focus, and at once when the
---buffer is entered or Neovim gains focus. Following a buffer again replaces
---what an earlier attach left, so a hub that is opened again keeps one timer
---and one augroup.
---
---Invalid arguments return `nil` and an error, and this function never throws.
---@param buffer integer The buffer of a hub.
---@param refresh fun(): true|nil ok, string? err Render the hub again.
---@return true|nil ok
---@return string? err
function M.attach(buffer, refresh)
    local ok, err = validate.check({
        buffer = { buffer, 'number' },
        refresh = { refresh, 'function' },
    })
    if not ok then
        return nil, err
    end
    if not vim.api.nvim_buf_is_valid(buffer) then
        return nil, 'prohub: the buffer of the hub does not exist'
    end

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    M.detach(buffer)

    local state = setmetatable({
        buffer = buffer,
        refresh = refresh,
        interval = options.refresh_interval,
    }, State)
    states[buffer] = state

    local installed, install_err = pcall(state.install, state)
    if not installed then
        states[buffer] = nil
        return nil,
            ('prohub: the refresh of the hub could not start: %s'):format(
                tostring(install_err)
            )
    end

    if state:holds() then
        state:start()
    end
    return true
end

return M
