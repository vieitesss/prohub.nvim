---The rows of the hub, built from the worktrees and their collected status.
---
---A build reads its arguments and writes nothing: it returns the lines of the
---buffer, the highlight of every row that carries one, the worktree of every
---line and the worktrees git reports as missing. The hub applies them to its
---buffer as the last step of a render, so a slow collection never leaves a
---half written hub behind and a row can be checked without a window.
---
---A row shows a name, the path of its worktree and the counts of its status:
---
---    name  path  s u ?  a b  c  p
---
---The name is the branch of the worktree, or the short commit when HEAD is
---detached. The path is the last part of the worktree path, with the directory
---that holds it where two worktrees share that last part. `s`, `u` and `?` are
---the staged, unstaged and untracked entries, `a` and `b` the commits ahead of
---and behind the default branch, `c` the files that differ from the base, and
---`p` the unpushed commits, which a row only shows when its status has them. A
---count that does not apply is a dash, a row without a base ends with the
---reason why, and a worktree git reports as missing is dimmed and ends with
---`missing`.
---
---    local render = require('prohub.hub.render')
---
---    local rows = render.build(worktrees, collections)
---@class prohub.hub.render
local M = {}

---The highlight group of the row of a worktree that is missing. The build
---names it and the hub defines it, because only a render touches the editor.
---@type string
M.missing_group = 'ProhubMissing'

---The counts of a row, in the order the row writes them.
---@type string[]
local count_columns = {
    'staged',
    'unstaged',
    'untracked',
    'ahead',
    'behind',
    'changed',
    'unpushed',
}

---The label of each count in the header of the buffer.
---@type table<string, string>
local count_labels = {
    staged = 's',
    unstaged = 'u',
    untracked = '?',
    ahead = 'a',
    behind = 'b',
    changed = 'c',
    unpushed = 'p',
}

---The status of one worktree as its row shows it: the collected status, or the
---error that kept the collection from finishing.
---@class prohub.hub.Collection
---@field status prohub.Status?
---@field err string?

---The counts of one row. `unpushed` is missing when the status has none.
---@class prohub.hub.Counts
---@field staged string
---@field unstaged string
---@field untracked string
---@field ahead string
---@field behind string
---@field changed string
---@field unpushed string?

---The cells of one row.
---@class prohub.hub.Cells
---@field name string
---@field path string
---@field counts prohub.hub.Counts
---@field note string?

---One row that carries a highlight group.
---@class prohub.hub.Highlight
---@field line integer Line number of the row.
---@field group string Highlight group of the row.

---The rows of a hub.
---@class prohub.hub.Render
---@field lines string[] The lines of the buffer.
---@field highlights prohub.hub.Highlight[] The rows that carry a group.
---@field paths table<integer, string> The worktree of each line of the buffer.
---@field missing table<string, true> The worktrees git reports as missing.

---The number of screen cells a string occupies.
---@param value string
---@return integer
local function width_of(value)
    return vim.api.nvim_strwidth(value)
end

---Pad a cell on the right, so a column of left aligned cells lines up.
---@param value string
---@param width integer
---@return string
local function pad_right(value, width)
    return value .. string.rep(' ', math.max(0, width - width_of(value)))
end

---Pad a cell on the left, so a column of right aligned cells lines up.
---@param value string
---@param width integer
---@return string
local function pad_left(value, width)
    return string.rep(' ', math.max(0, width - width_of(value))) .. value
end

---Write a message on a single line, so every row keeps exactly one line and
---the line of a worktree stays known.
---@param message string
---@return string
local function one_line(message)
    return (vim.trim((message:gsub('%s+', ' '))))
end

---The last part of each worktree path, with the directory that holds it where
---that is not enough to tell two worktrees apart.
---@param worktrees prohub.Worktree[]
---@return table<integer, string>
local function short_paths(worktrees)
    local counts = {}
    for _, record in ipairs(worktrees) do
        local name = vim.fs.basename(record.path)
        counts[name] = (counts[name] or 0) + 1
    end

    local result = {}
    for index, record in ipairs(worktrees) do
        local name = vim.fs.basename(record.path)
        if counts[name] > 1 then
            local directory = vim.fs.basename(vim.fs.dirname(record.path))
            name = vim.fs.joinpath(directory, name)
        end
        result[index] = name
    end
    return result
end

---A count a row shows: the number, or the dash that says it does not apply.
---@param value integer?
---@return string
local function count_of(value)
    if value == nil then
        return '-'
    end
    return tostring(value)
end

---The name a row starts with: the branch, or the short commit of a detached
---HEAD.
---@param record prohub.Worktree
---@param collection prohub.hub.Collection?
---@return string
local function name_of(record, collection)
    if record.branch then
        return record.branch
    end
    if record.detached then
        return record.detached
    end

    local collected = collection and collection.status
    if collected and collected.head then
        return collected.head
    end
    return '-'
end

---The note a row ends with, when it has one.
---@param record prohub.Worktree
---@param collection prohub.hub.Collection?
---@return string?
local function note_of(record, collection)
    if record.missing then
        return 'missing'
    end
    if collection and collection.err then
        return 'error: ' .. one_line(collection.err)
    end
    if collection and collection.status then
        return collection.status.reason
    end
end

---The cells of the row of one worktree.
---@param record prohub.Worktree
---@param collection prohub.hub.Collection?
---@param path string Short path of the worktree.
---@return prohub.hub.Cells
local function cells_of(record, collection, path)
    local collected = collection and collection.status
    local unpushed
    if collected and collected.unpushed then
        unpushed = tostring(collected.unpushed)
    end

    return {
        name = name_of(record, collection),
        path = path,
        counts = {
            staged = count_of(collected and collected.staged),
            unstaged = count_of(collected and collected.unstaged),
            untracked = count_of(collected and collected.untracked),
            ahead = count_of(collected and collected.ahead),
            behind = count_of(collected and collected.behind),
            changed = count_of(collected and collected.changed),
            unpushed = unpushed,
        },
        note = note_of(record, collection),
    }
end

---The header of the rows, which also names every count.
---@return prohub.hub.Cells
local function header_cells()
    local counts = {}
    for _, column in ipairs(count_columns) do
        counts[column] = count_labels[column]
    end
    return { name = 'name', path = 'path', counts = counts }
end

---The width of each column, wide enough for its label and every value.
---@param rows prohub.hub.Cells[]
---@param header prohub.hub.Cells
---@return table<string, integer>
local function widths_of(rows, header)
    local widths = {
        name = width_of(header.name),
        path = width_of(header.path),
    }
    for _, column in ipairs(count_columns) do
        widths[column] = width_of(header.counts[column])
    end

    for _, cells in ipairs(rows) do
        widths.name = math.max(widths.name, width_of(cells.name))
        widths.path = math.max(widths.path, width_of(cells.path))
        for _, column in ipairs(count_columns) do
            local value = cells.counts[column]
            if value then
                widths[column] = math.max(widths[column], width_of(value))
            end
        end
    end
    return widths
end

---Write the cells of one row as one line. A count a row does not have is left
---out, so no line ends with padding.
---@param cells prohub.hub.Cells
---@param widths table<string, integer>
---@return string
local function line_of(cells, widths)
    local counts = cells.counts
    local changes = table.concat({
        pad_left(counts.staged, widths.staged),
        pad_left(counts.unstaged, widths.unstaged),
        pad_left(counts.untracked, widths.untracked),
    }, ' ')
    local commits = table.concat({
        pad_left(counts.ahead, widths.ahead),
        pad_left(counts.behind, widths.behind),
    }, ' ')

    local parts = {
        pad_right(cells.name, widths.name),
        pad_right(cells.path, widths.path),
        changes,
        commits,
        pad_left(counts.changed, widths.changed),
    }
    if counts.unpushed then
        table.insert(parts, pad_left(counts.unpushed, widths.unpushed))
    end
    if cells.note then
        table.insert(parts, cells.note)
    end
    return table.concat(parts, '  ')
end

---Turn the worktrees and their collected status into the rows of a hub.
---@param worktrees prohub.Worktree[]
---@param collections table<string, prohub.hub.Collection>
---@return prohub.hub.Render
function M.build(worktrees, collections)
    if #worktrees == 0 then
        return { lines = {}, highlights = {}, paths = {}, missing = {} }
    end

    local header = header_cells()
    local short = short_paths(worktrees)
    local cells = {}
    for index, record in ipairs(worktrees) do
        cells[index] = cells_of(record, collections[record.path], short[index])
    end

    local widths = widths_of(cells, header)
    local lines = { line_of(header, widths) }
    local highlights = {}
    local paths = {}
    local missing = {}
    for index, record in ipairs(worktrees) do
        local line = index + 1
        lines[line] = line_of(cells[index], widths)
        paths[line] = record.path
        if record.missing then
            missing[record.path] = true
            table.insert(highlights, {
                line = line,
                group = M.missing_group,
            })
        end
    end

    return {
        lines = lines,
        highlights = highlights,
        paths = paths,
        missing = missing,
    }
end

return M
