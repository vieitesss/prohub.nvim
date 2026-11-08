---The tabpages prohub owns, which is the hub tabpage and the rule that closes
---a tabpage.
---
---The hub and the review are the two modules that open and close tabpages, and
---they follow the same rules: the hub marks its tabpage so a review finds it
---again, a review only closes a tabpage when Neovim can close it, and the last
---tabpage of the editor is never closed because Neovim cannot replace it.
---Those rules live here, and the two modules keep only the order of steps
---they take around them.
---
---    local tab = require('prohub.tab')
---
---    tab.mark_hub(tabpage)
---@class prohub.tab
local M = {}

---The tab variable that marks the tabpage of the hub.
---@type string
local hub_variable = 'prohub_hub'

---Mark a tabpage as the tabpage of the hub.
---@param tabpage integer
function M.mark_hub(tabpage)
    vim.t[tabpage][hub_variable] = true
end

---Drop the mark of a tabpage, so a closed hub leaves no hint behind. A
---tabpage that is gone carries no mark already.
---@param tabpage integer
function M.clear_hub(tabpage)
    if vim.api.nvim_tabpage_is_valid(tabpage) then
        vim.t[tabpage][hub_variable] = nil
    end
end

---The tabpage of the hub, or nil when no open tabpage carries its mark.
---@return integer?
function M.hub()
    for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
        if vim.t[tabpage][hub_variable] then
            return tabpage
        end
    end
end

---Close a tabpage when Neovim can close it.
---
---A tabpage that is already gone needs no close, and the last tabpage of the
---editor cannot be closed, so both are left alone and `false` says the caller
---keeps the tabpage.
---@param tabpage integer?
---@return boolean closed
---@return string? err The error that kept Neovim from closing the tabpage.
function M.close(tabpage)
    if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
        return false
    end
    if #vim.api.nvim_list_tabpages() < 2 then
        return false
    end

    vim.api.nvim_set_current_tabpage(tabpage)
    local closed, err = pcall(vim.cmd, 'tabclose')
    if not closed then
        return false, tostring(err)
    end
    return true
end

return M
