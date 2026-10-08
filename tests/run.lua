-- Minimal standalone runner for these Busted-style offline specs (no external packages).
package.path = "./?.lua;./tests/?.lua;" .. package.path
local total, failed, before, after = 0, 0
function describe(name, callback)
    io.write(name .. "\n")
    callback()
end
function before_each(callback) before=callback end
function after_each(callback) after=callback end
function it(name, callback)
    total=total+1
    local ok, err = xpcall(function()
        if before then before() end
        callback()
    end, debug.traceback)
    local cleanup_ok, cleanup_err = pcall(function() if after then after() end end)
    if ok and cleanup_ok then io.write("  PASS " .. name .. "\n")
    else
        failed=failed+1
        io.write("  FAIL " .. name .. "\n" .. tostring(err or cleanup_err) .. "\n")
    end
end
dofile("zoteroapi.spec.lua")
dofile("tests/librarycache.spec.lua")
dofile("tests/main.spec.lua")
io.write(("\n%d/%d tests passed\n"):format(total-failed,total))
assert(failed==0, "Regression tests failed")
