-- Service checks: command contract, retry after launch failure, watchdog at
-- 150 s with preserved data, recovery, bad frames and optional handle restart.

local now = 0
local handler = nil
local last = nil
local commits = 0
local calls = 0
local logs = {}
local decoded = {}
local streamResults = { false, true }

noctalia = {
  nowMs = function() return now end,
  pluginDir = function() return "/plugin" end,
  getConfig = function(key)
    assert(key == "interval", "unexpected setting: " .. tostring(key))
    return 900 -- must be clamped to 600 before it reaches the backend
  end,
  json = {
    decode = function(line)
      if decoded[line] == "bad" then return nil, "bad json" end
      return decoded[line]
    end,
  },
  state = {
    set = function(key, value)
      assert(key == "snapshot")
      last = value
      commits = commits + 1
    end,
  },
  setUpdateInterval = function(ms) assert(ms == 1000) end,
  log = function(message) table.insert(logs, message) end,
  runStream = function(command, callback)
    calls = calls + 1
    assert(string.find(command, "python3 -u ", 1, true))
    assert(string.find(command, "'/plugin/backend.py' serve --interval 600", 1, true))
    assert(not string.find(command, "--interval 900", 1, true))
    handler = callback
    return streamResults[calls] == true
  end,
}

dofile("ai-quota/service.luau")

-- Initial state is explicit and never a fake zero. The mocked launch fails, so
-- the service immediately publishes its launch error on top of that state.
assert(last and last.ok == false and #last.providers == 0)
assert(commits == 2 and calls == 1)

-- A launch failure retries after 30 s instead of staying dead forever.
assert(last.stale_transport and last.connecting == false)
assert(string.find(last.error, "python3", 1, true))
now = 30001
update()
assert(calls == 2)

-- Valid complete snapshot publishes atomically.
decoded.good = {
  ok = true,
  updated_at = 1700000000.75,
  providers = {
    { id = "openai", name = "OpenAI", window = "five_hour", remaining = 34,
      resets_at = "2023-11-15T00:13:20Z", checked_at = 1700000000.25, stale = false,
      windows = { { window = "five_hour", remaining = 34, resets_at = "2023-11-15T00:13:20Z" } } },
    { id = "anthropic", name = "Anthropic", window = "five_hour", remaining = 20,
      resets_at = "2023-11-16T00:00:00Z", checked_at = 1700000000.25, stale = false,
      windows = {} },
    { id = "opencode-go", name = "OpenCode Go", window = "month", remaining = 60,
      resets_at = "2023-12-01T00:00:00Z", checked_at = 1700000000.25, stale = false,
      windows = {} },
  },
}
handler("good")
assert(last.ok == true and last.stale_transport == false and last.connecting == false)
assert(last.updated_at == 1700000000 and last.transport_received_at == 30)
assert(#last.providers == 3 and last.providers[1].remaining == 34)
assert(last.providers[1].checked_at == 1700000000)
assert(last.providers[1].windows[1].window == "five_hour")

-- Invalid frames never replace the last complete snapshot.
local before = commits
handler("bad")
assert(commits == before and #logs > 0)
decoded.badOk = { ok = "yes", providers = {} }
handler("badOk")
assert(commits == before)
local huge = string.rep("x", 1024 * 1024 + 1)
handler(huge)
assert(commits == before)

-- Backend-level failure is published as stale data, not as a transport timeout.
decoded.failure = {
  ok = false,
  updated_at = 1700000000,
  error = "Sem conexão com as quotas do OpenCode.",
  providers = {
    { id = "openai", name = "OpenAI", window = "five_hour", remaining = 34,
      resets_at = nil, checked_at = 1699999000, stale = true,
      error = "Dado antigo; aguardando confirmação.", windows = {} },
  },
}
handler("failure")
assert(last.ok == false and last.stale_transport == false)
assert(last.providers[1].remaining == 34 and last.providers[1].stale == true)
assert(last.providers[1].error == "Dado antigo; aguardando confirmação.")

-- Recovery.
handler("good")
assert(last.ok == true and last.stale_transport == false)

-- Watchdog at 150 s: preserve every last value, mark the transport stale, and
-- do not launch a duplicate API-24 stream (runStream returns a boolean).
now = 30001 + 150001
update()
assert(last.stale_transport == true and last.ok == false)
assert(last.providers[1].remaining == 34 and last.providers[1].stale == true)
assert(string.find(last.transport_error, "150", 1, true))
assert(calls == 2)
local staleCommits = commits
now = now + 1000
update()
assert(commits == staleCommits) -- no repeated state churn while stalled

-- A new complete frame recovers the same helper stream.
handler("good")
assert(last.ok == true and last.stale_transport == false)
assert(last.providers[1].remaining == 34)

-- If a future runStream returns a cancellable handle, the watchdog stops it and
-- restarts after a short delay. This keeps the "restart if the API permits"
-- behavior ready without pretending API 24 supports it.
local handleNow = 100000
local handleStopped = false
local handleCalls = 0
local handleHandler = nil
local handleLast = nil
local handleDecoded = {
  snap = {
    ok = true, updated_at = 100, providers = {
      { id = "openai", name = "OpenAI", window = "five_hour", remaining = 42,
        resets_at = nil, checked_at = 100, stale = false, windows = {} },
    },
  },
}
noctalia = {
  nowMs = function() return handleNow end,
  pluginDir = function() return "/plugin" end,
  getConfig = function() return 60 end,
  json = { decode = function(line) return handleDecoded[line] end },
  state = { set = function(_, value) handleLast = value end },
  setUpdateInterval = function() end,
  log = function() end,
  runStream = function(_, callback)
    handleCalls = handleCalls + 1
    handleHandler = callback
    if handleCalls == 1 then
      return { stop = function() handleStopped = true end }
    end
    return true
  end,
}
dofile("ai-quota/service.luau")
assert(handleCalls == 1)
handleHandler("snap")
assert(handleLast.ok == true)
handleNow = handleNow + 150001
update()
assert(handleStopped == true)
assert(handleCalls == 1)
handleNow = handleNow + 2001
update()
assert(handleCalls == 2)
assert(handleLast.stale_transport == true) -- stays stale until a new frame

print("Service: command, retry, invalid frames, 150 s watchdog, preserved stale data, recovery and optional handle restart OK")
