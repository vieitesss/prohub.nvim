---The rules a worktree path obeys, spec'd on their own so `prohub.git`,
---`prohub.workset` and `prohub.scope` share one answer.
local path = require('prohub.path')

describe('prohub.path', function()
    local dir

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        dir = assert(vim.uv.fs_realpath(dir))
    end)

    after_each(function()
        vim.fn.delete(dir, 'rf')
    end)

    describe('normalize', function()
        it('resolves a relative path against the base it is given', function()
            vim.fn.mkdir(dir .. '/inner', 'p')

            assert.are.equal(dir .. '/inner', path.normalize('inner', dir))
            assert.are.equal(dir .. '/inner', path.normalize('./inner', dir))
        end)

        it('drops a trailing slash', function()
            assert.are.equal(dir, path.normalize(dir .. '/', '/'))
        end)

        it('resolves the symbolic links of a path that exists', function()
            local target = dir .. '/target'
            local link = dir .. '/link'
            vim.fn.mkdir(target, 'p')
            assert(vim.uv.fs_symlink(target, link))

            assert.are.equal(target, path.normalize(link, '/'))
        end)

        it('keeps a path that does not exist', function()
            local missing = dir .. '/missing'

            assert.are.equal(missing, path.normalize(missing, '/'))
            assert.are.equal(missing, path.normalize('missing', dir))
        end)

        it('returns an absolute path for an absolute one', function()
            assert.are.equal(dir, path.normalize(dir, '/'))
        end)
    end)

    describe('check', function()
        it('accepts an absolute directory', function()
            assert.is_true(path.check(dir))
        end)

        it('returns an error for a path that cannot be a worktree', function()
            local file = dir .. '/file'
            vim.fn.writefile({ 'prohub' }, file)
            local cases = {
                { nil, 'path' },
                { 'relative/dir', 'must be absolute' },
                { dir .. '/missing', 'does not exist' },
                { file, 'is not a directory' },
            }

            for _, case in ipairs(cases) do
                local ok, err = path.check(case[1])

                assert.is_nil(ok)
                assert.is_truthy(err:find(case[2], 1, true))
            end
        end)

        if vim.fn.has('win32') ~= 1 then
            it('rejects a drive-prefixed path on this host', function()
                local ok, err = path.check('C:/project')

                assert.is_nil(ok)
                assert.is_truthy(err:find('must be absolute', 1, true))
            end)
        end
    end)
end)
