---The lifecycle of the tabpage of a review. prohub owns one tabpage per
---review (docs/adr/0003), so this module opens it, keeps it and closes it, and
---the configured diff viewer renders into it.
---
---A review is keyed by the root of its worktree, which git resolves from any
---directory of it, so the root, a path in a subdirectory, a path with a
---trailing slash and a symbolic link to the same directory all reuse the review
---that is already open. Several reviews can be open at the same time, each in
---its own tabpage, and each of those tabpages has the worktree as its working
---directory.
---
---The scope and the base of a review are computed on every open (docs/adr/0002).
---The diff viewer of an open review is called again only when one of them would
---show something else, and it then replaces the viewer of the same tabpage
---(docs/adr/0003).
---
---When a review closes, the editor returns to the tabpage it was opened from,
---or to the hub tabpage when that one is gone. This module does not build the
---hub: it finds it through `prohub.tab`, which owns the tabpages prohub marks
---and the rule that closes them.
---
---    local review = require('prohub.review')
---
---    local ok, err = review.open(path, { scope = 'unpushed' })
---@class prohub.review
local M = {}

local config = require('prohub.config')
local git = require('prohub.git')
local log = require('prohub.log')
local paths = require('prohub.path')
local scope = require('prohub.scope')
local tab = require('prohub.tab')
local validate = require('prohub.validate')
local viewer = require('prohub.viewer')

---The name of the autocommand group that follows the tabpages of the reviews.
---@type string
local group_name = 'prohub_review'

---An open review.
---@class prohub.review.Review
---@field path string Real path of the worktree the review shows.
---@field tabpage integer The tabpage the review lives in.
---@field opened_from integer The tabpage that was current when it opened.
---@field scope prohub.Scope The scope the diff viewer draws.
---@field base string? The revision the diff viewer draws the changes since,
---missing exactly when the scope is `uncommitted`.
---@field generation integer The viewer instance that draws the review.

---The autocommand group that follows the tabpages, made by the first open.
---@type integer?
local group

---The open reviews, by the real path of their worktree root.
---@type table<string, prohub.review.Review>
local reviews = {}

---The root of the worktree that holds a path. Git decides it, so a directory in
---a subdirectory of a worktree and the root of that worktree are one review.
---@param path string Absolute path of a directory.
---@return string? root
---@return string? err
local function root_of(path)
    local out, err = git.run_sync(path, { 'rev-parse', '--show-toplevel' })
    if not out then
        return nil, err
    end

    local root = vim.trim(out)
    if root == '' then
        return nil, ('prohub: git names no worktree root for %s'):format(path)
    end
    return paths.normalize(root, path)
end

---Go to a tabpage when it is still open.
---@param tabpage integer?
---@return boolean
local function go_to(tabpage)
    if tabpage and vim.api.nvim_tabpage_is_valid(tabpage) then
        vim.api.nvim_set_current_tabpage(tabpage)
        return true
    end
    return false
end

---Go back to where a review was opened from: the tabpage it was opened from,
---else the hub tabpage, else nowhere, so the editor stays where it is.
---@param review prohub.review.Review
local function return_from(review)
    if go_to(review.opened_from) then
        return
    end
    go_to(tab.hub())
end

---Give up on a review: forget it, close its tabpage when there is one to close
---and return to the tabpage it was opened from.
---@param review prohub.review.Review
local function abandon(review)
    reviews[review.path] = nil
    local _, close_err = tab.close(review.tabpage)
    if close_err then
        log.debug(
            'the tabpage of the review could not be closed: %s',
            close_err
        )
    end
    return_from(review)
end

---Forget a review and return from it. A close that arrives from a viewer
---instance that has since been replaced, and one for a review that is already
---closed, are ignored: the diff viewer replaces its own window when it is
---asked for another scope, and the instance it replaced may report the close
---of that window later.
---@param review prohub.review.Review
---@param generation? integer The viewer instance that asked to close.
local function close(review, generation)
    if reviews[review.path] ~= review then
        log.debug('the review of %s is already closed', review.path)
        return
    end
    if generation and generation ~= review.generation then
        log.debug(
            'ignoring the close of %s from a replaced viewer (%d of %d)',
            review.path,
            generation,
            review.generation
        )
        return
    end

    abandon(review)
end

---Forget the reviews whose tabpage was closed by the user and return from
---each of them. `TabClosed` names the closed tabpage by its number, which no
---longer says which review is gone once the tabpages after it have moved, so
---the review is recognised by the handle of its own tabpage.
local function prune()
    local closed = {}
    for path, review in pairs(reviews) do
        if not vim.api.nvim_tabpage_is_valid(review.tabpage) then
            table.insert(closed, path)
        end
    end

    for _, path in ipairs(closed) do
        close(reviews[path])
    end
end

---Follow the tabpages of the reviews. One autocommand serves every review.
---Some Neovim versions report `TabClosed` once the tabpage is gone and some
---before that, so the reviews are checked once for the event and once more on
---the next turn of the main loop, which is enough for both.
local function watch_tabpages()
    if group then
        return
    end

    group = vim.api.nvim_create_augroup(group_name, { clear = true })
    vim.api.nvim_create_autocmd('TabClosed', {
        group = group,
        callback = function()
            prune()
            vim.schedule(prune)
        end,
        desc = 'forget the reviews whose tabpage is closed',
    })
end

---Open a review of a worktree that is not open yet, in a tabpage of its own.
---A diff viewer that fails leaves no tabpage behind, and the editor returns to
---the tabpage the review was opened from.
---@param path string Real path of the worktree.
---@param result prohub.ScopeResult
---@return true|nil ok
---@return string? err
local function create(path, result)
    local opened_from = vim.api.nvim_get_current_tabpage()

    vim.cmd('tabnew')
    vim.cmd('tcd ' .. vim.fn.fnameescape(path))

    local review = {
        path = path,
        tabpage = vim.api.nvim_get_current_tabpage(),
        opened_from = opened_from,
        scope = result.scope,
        base = result.base,
        generation = 1,
    }
    reviews[path] = review

    local generation = review.generation
    local ok, err = viewer.open({
        path = path,
        scope = result.scope,
        base = result.base,
        on_close = function()
            close(review, generation)
        end,
    })
    if not ok then
        abandon(review)
        return nil, err
    end
    return true
end

---Go to the tabpage of a review that is already open. The diff viewer is only
---called again when the review would show something else: another scope, or
---another base for the same scope, because the base is computed on every open.
---@param review prohub.review.Review
---@param result prohub.ScopeResult
---@return true|nil ok
---@return string? err
local function reuse(review, result)
    go_to(review.tabpage)

    if review.scope == result.scope and review.base == result.base then
        return true
    end

    -- The viewer instance that draws the new changes replaces the one before
    -- it, and the close that instance reports later belongs to the old
    -- generation.
    review.generation = review.generation + 1
    review.scope = result.scope
    review.base = result.base
    local generation = review.generation
    local ok, err = viewer.open({
        path = review.path,
        scope = result.scope,
        base = result.base,
        on_close = function()
            close(review, generation)
        end,
    })
    if not ok then
        abandon(review)
        return nil, err
    end
    return true
end

---Check the arguments, then resolve the scope of the review. Both happen
---before any tabpage exists, so a mistake never leaves one behind.
---@param path any
---@param opts any
---@return true|nil ok
---@return string? err
local function start(path, opts)
    local ok, err = validate.check({
        path = { path, 'string' },
        opts = { opts, 'table', true },
    })
    if not ok then
        return nil, err
    end

    ok, err = paths.check(path)
    if not ok then
        return nil, err
    end

    local root, root_err = root_of(path)
    if not root then
        return nil, root_err
    end

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    local name = options.default_scope
    if opts and opts.scope ~= nil then
        ok, err = validate.check({ ['opts.scope'] = { opts.scope, 'string' } })
        if not ok then
            return nil, err
        end
        name = opts.scope
    end

    local result, scope_err = scope.resolve_sync(root, name)
    if not result then
        return nil, scope_err
    end

    watch_tabpages()

    local existing = reviews[root]
    if existing and vim.api.nvim_tabpage_is_valid(existing.tabpage) then
        return reuse(existing, result)
    end
    return create(root, result)
end

---Open the review of one worktree, or go to the one that is already open.
---
---`path` is a directory of the worktree, and git resolves the root of that
---worktree, which is the path the review shows and the key that reuses it. A
---path outside a git worktree is an error for every scope. The scope is
---resolved with `prohub.scope`, and the scope the result carries is the one the
---review shows, because a scope that cannot be resolved falls back to another
---one. A path or scope error is returned before a tabpage is created, and a
---viewer that fails leaves none behind. This function never throws.
---@param path string Path of a directory of the worktree to review.
---@param opts? prohub.ReviewOpts
---@return true|nil ok
---@return string? err
function M.open(path, opts)
    local called, ok, err = pcall(start, path, opts)
    if not called then
        log.error('the review could not be opened: %s', tostring(ok))
        return nil,
            ('prohub: the review could not be opened: %s'):format(tostring(ok))
    end
    return ok, err
end

return M
