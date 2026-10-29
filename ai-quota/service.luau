--!nonstrict
-- AI Quota service: owns the backend stream and the stale watchdog.
--
-- Backend contract (see backend.py):
--   python3 -u <pluginDir>/backend.py serve --interval 60
-- prints one complete JSON snapshot per line, roughly every 15 seconds.
--
-- The last snapshot is preserved when the stream stops producing frames. It is
-- never presented as fresh: every provider is marked stale and the snapshot
-- carries stale_transport = true until a new complete frame arrives.

local quote = function(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end
local helper = noctalia.pluginDir() .. "/backend.py"
local STALE_AFTER_MS = 150000
local RETRY_AFTER_MS = 30000
local MAX_LINE_BYTES = 1024 * 1024

local lastCompleteAt = noctalia.nowMs()
local lastWarningAt = -RETRY_AFTER_MS
local last = {
  ok = false,
  connecting = true,
  updated_at = nil,
  error = "Conectando ao serviço local de quotas…",
  providers = {},
}
local stalled = false
local streamRunning = false
local streamHandle = nil
local retryAt = 0

local function nowSeconds()
  return math.floor(noctalia.nowMs() / 1000)
end

local function logThrottled(message)
  local now = noctalia.nowMs()
  if now - lastWarningAt >= RETRY_AFTER_MS then
    lastWarningAt = now
    noctalia.log(message)
  end
end

local function safeText(value, limit)
  if type(value) ~= "string" then return nil end
  local text = string.gsub(value, "%s+", " ")
  if #text > limit then text = string.sub(text, 1, limit - 3) .. "..." end
  return text
end

local function seconds(value)
  local number = tonumber(value)
  if number == nil then return nil end
  return math.floor(number)
end

local function normalizeProvider(raw)
  if type(raw) ~= "table" then return nil end
  local provider = {
    id = type(raw.id) == "string" and raw.id or "unknown",
    name = safeText(raw.name, 80),
    window = type(raw.window) == "string" and raw.window or nil,
    remaining = tonumber(raw.remaining),
    resets_at = type(raw.resets_at) == "string" and raw.resets_at or nil,
    checked_at = seconds(raw.checked_at),
    stale = raw.stale == true,
    error = safeText(raw.error, 240),
    windows = {},
  }
  if type(raw.windows) == "table" then
    for _, item in ipairs(raw.windows) do
      if type(item) == "table" then
        table.insert(provider.windows, {
          window = type(item.window) == "string" and item.window or nil,
          remaining = tonumber(item.remaining),
          resets_at = type(item.resets_at) == "string" and item.resets_at or nil,
        })
      end
    end
  end
  return provider
end

local function normalizeSnapshot(raw)
  if type(raw) ~= "table" or type(raw.ok) ~= "boolean" then return nil end
  local snapshot = {
    ok = raw.ok,
    updated_at = seconds(raw.updated_at),
    error = safeText(raw.error, 240),
    providers = {},
  }
  if type(raw.providers) == "table" then
    for _, item in ipairs(raw.providers) do
      local provider = normalizeProvider(item)
      if provider then table.insert(snapshot.providers, provider) end
    end
  end
  return snapshot
end

local function publish(snapshot)
  snapshot.connecting = false
  snapshot.stale_transport = false
  snapshot.transport_error = nil
  snapshot.transport_stale_at = nil
  snapshot.transport_received_at = nowSeconds()
  last = snapshot
  lastCompleteAt = noctalia.nowMs()
  stalled = false
  noctalia.state.set("snapshot", last)
end

local function invalidateTransport(message)
  if stalled then return end
  stalled = true
  last.ok = false
  last.connecting = false
  last.stale_transport = true
  last.transport_error = message
  last.error = message
  last.transport_stale_at = nowSeconds()
  for _, provider in ipairs(last.providers or {}) do
    provider.stale = true
  end
  noctalia.state.set("snapshot", last)
end

local function receive(line)
  if type(line) ~= "string" or #line == 0 then return end
  if #line > MAX_LINE_BYTES then
    logThrottled("AI Quota: quadro maior que o limite; ignorado.")
    return
  end
  local decoded, packet = pcall(noctalia.json.decode, line)
  if not decoded or type(packet) ~= "table" then
    logThrottled("AI Quota: atualização inválida; mantendo o último snapshot.")
    return
  end
  local snapshot = normalizeSnapshot(packet)
  if not snapshot then
    logThrottled("AI Quota: snapshot sem o campo ok; ignorado.")
    return
  end
  publish(snapshot)
end

local function configuredInterval()
  local value = tonumber(noctalia.getConfig("interval")) or 60
  if value < 60 then value = 60 elseif value > 600 then value = 600 end
  return math.floor(value)
end

local function startStream()
  local command = "python3 -u " .. quote(helper) .. " serve --interval " .. tostring(configuredInterval())
  local called, result = pcall(noctalia.runStream, command, receive)
  if not called or not result then
    streamRunning = false
    streamHandle = nil
    retryAt = noctalia.nowMs() + RETRY_AFTER_MS
    local message = "Não foi possível iniciar o monitor local (python3)."
    logThrottled("AI Quota: " .. message)
    invalidateTransport(message)
    return false
  end
  streamRunning = true
  streamHandle = type(result) == "table" and result or nil
  lastCompleteAt = noctalia.nowMs()
  stalled = false
  retryAt = 0
  return true
end

noctalia.state.set("snapshot", last)
noctalia.setUpdateInterval(1000)

function update()
  local now = noctalia.nowMs()
  if not streamRunning then
    if now >= retryAt then startStream() end
    return
  end
  if now - lastCompleteAt <= STALE_AFTER_MS then return end
  invalidateTransport("Sem atualizações do monitor há 150 s. Os últimos dados foram preservados e marcados como desatualizados.")
  -- API 24's runStream returns a boolean, not a cancellable handle. A hung
  -- process cannot be stopped safely without risking a duplicate poller. If a
  -- future API returns a handle with stop(), restart it here; otherwise just
  -- keep the stale state visible until a new frame arrives or the plugin reloads.
  if streamHandle and type(streamHandle.stop) == "function" then
    pcall(streamHandle.stop)
    streamHandle = nil
    streamRunning = false
    retryAt = now + 2000
    stalled = false
  end
end

startStream()
