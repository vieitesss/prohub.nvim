local M = {}

---Check argument types with the table form of `vim.validate`, the only one
---Neovim 0.10 supports, without throwing.
---@param spec table<string, {[1]: any, [2]: string|function, [3]: boolean|string?}>
---@return true|nil ok
---@return string? err
function M.check(spec)
    local ok, err = pcall(vim.validate, spec)
    if not ok then
        return nil, 'prohub: ' .. tostring(err)
    end
    return true
end

---Whether a value is a list of strings, the shape prohub takes as a list of
---arguments or of paths. It is a predicate for `check`.
---@param value any
---@return boolean
function M.is_string_list(value)
    if not vim.islist(value) then
        return false
    end
    for _, item in ipairs(value) do
        if type(item) ~= 'string' then
            return false
        end
    end
    return true
end

return M
