local log = require('prohub.log')

local levels = vim.log.levels

---@param path string
---@return string
local function read(path)
    local lines = vim.fn.readfile(path)
    return table.concat(lines, '\n')
end

describe('prohub.log', function()
    -- Runs before any other spec of this file configures the log.
    it('writes to the log directory of Neovim by default', function()
        local path = log.path()

        assert.are.equal(vim.fn.stdpath('log') .. '/prohub.log', path)
    end)

    describe('configured', function()
        local dir, file

        before_each(function()
            dir = vim.fn.tempname()
            file = dir .. '/nested/prohub.log'
            assert(log.configure({ level = levels.WARN, file = file }))
        end)

        after_each(function()
            vim.fn.delete(dir, 'rf')
        end)

        it('writes a line with the time, the level and the message', function()
            log.warn('cannot read %s', 'the index')

            local text = read(file)

            assert.is_truthy(
                text:match(
                    '^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d WARN  cannot read the index$'
                )
            )
            assert.are.equal(file, log.path())
        end)

        it('writes one line per message, in order', function()
            log.warn('first')
            log.error('second')

            local lines = vim.fn.readfile(file)

            assert.are.equal(2, #lines)
            assert.is_truthy(lines[1]:find('WARN  first', 1, true))
            assert.is_truthy(lines[2]:find('ERROR second', 1, true))
        end)

        it('drops the messages below the level', function()
            log.debug('quiet')
            log.info('quiet')

            assert.are.equal(0, vim.fn.filereadable(file))

            assert(log.configure({ level = levels.DEBUG }))
            log.debug('loud')
            log.info('louder')

            local text = read(file)
            assert.is_truthy(text:find('DEBUG loud', 1, true))
            assert.is_truthy(text:find('INFO  louder', 1, true))
        end)

        it('is silenced by the level OFF', function()
            assert(log.configure({ level = levels.OFF }))

            log.error('quiet')

            assert.are.equal(0, vim.fn.filereadable(file))
        end)

        it('returns true for a good configuration', function()
            local next_file = dir .. '/other/prohub.log'

            assert.is_true(
                log.configure({ level = levels.DEBUG, file = next_file })
            )
            assert.is_true(log.configure({}))
            log.debug('configured')

            assert.are.equal(next_file, log.path())
            assert.is_truthy(read(next_file):find('DEBUG configured', 1, true))
        end)

        it(
            'returns an error for a bad table without changing the log',
            function()
                local ok, err = log.configure('not a table')

                assert.is_nil(ok)
                assert.is_truthy(err:find('opts', 1, true))
                ok, err = log.configure(nil)
                assert.is_nil(ok)
                assert.is_truthy(err:find('opts', 1, true))
                assert.are.equal(file, log.path())
                log.debug('quiet')
                assert.are.equal(0, vim.fn.filereadable(file))
                log.warn('still here')
                assert.is_truthy(read(file):find('WARN  still here', 1, true))
            end
        )

        it(
            'returns an error for a bad level without changing the log',
            function()
                local ok, err = log.configure({
                    level = 'loud',
                    file = dir .. '/other/prohub.log',
                })

                assert.is_nil(ok)
                assert.is_truthy(err:find('level', 1, true))
                assert.are.equal(file, log.path())
                log.debug('quiet')
                assert.are.equal(0, vim.fn.filereadable(file))
                log.warn('still here')
                assert.is_truthy(read(file):find('WARN  still here', 1, true))
            end
        )

        it(
            'returns an error for an empty file without changing the log',
            function()
                local ok, err =
                    log.configure({ level = levels.DEBUG, file = '' })

                assert.is_nil(ok)
                assert.is_truthy(err:find('file', 1, true))
                assert.are.equal(file, log.path())
                log.debug('quiet')
                assert.are.equal(0, vim.fn.filereadable(file))
                log.warn('still here')
                assert.is_truthy(read(file):find('WARN  still here', 1, true))
            end
        )

        it(
            'returns an error for a non-string file without changing the log',
            function()
                local ok, err =
                    log.configure({ level = levels.DEBUG, file = 5 })

                assert.is_nil(ok)
                assert.is_truthy(err:find('file', 1, true))
                assert.are.equal(file, log.path())
                log.debug('quiet')
                assert.are.equal(0, vim.fn.filereadable(file))
                log.warn('still here')
                assert.is_truthy(read(file):find('WARN  still here', 1, true))
            end
        )

        it('does not throw on a message it cannot format', function()
            assert.has_no.errors(function()
                log.warn('%d', 'not a number')
                log.warn('%s %s', 'one argument')
            end)

            assert.is_truthy(read(file):find('WARN', 1, true))
        end)

        it('does not throw when the file cannot be written', function()
            vim.fn.mkdir(dir, 'p')
            vim.fn.writefile({ 'a file, not a directory' }, dir .. '/blocker')
            assert(log.configure({ file = dir .. '/blocker/prohub.log' }))

            assert.has_no.errors(function()
                log.error('nowhere to go')
            end)
        end)

        it('writes a message logged from a fast event', function()
            local timer = assert(vim.uv.new_timer())
            local fast

            timer:start(0, 0, function()
                fast = vim.in_fast_event()
                log.warn('from a timer')
                timer:close()
            end)

            assert(vim.wait(5000, function()
                return vim.fn.filereadable(file) == 1
            end))
            assert.is_true(fast)
            assert.is_truthy(read(file):find('from a timer', 1, true))
        end)
    end)
end)
