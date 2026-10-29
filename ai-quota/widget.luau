--!nonstrict
-- Compact bar widget: one glyph + "remaining %" per provider.
-- Percentages always mean REMAINING quota: <=10 red, <=25 amber, otherwise
-- a discreet green. Stale values keep the last number but get "*" and a muted
-- color. Unavailable values are "--".

local META = {
  { id = "openai", name = "OpenAI", glyph = "brand-openai" },
  { id = "anthropic", name = "Anthropic", image = "icons/anthropic.svg" },
  { id = "opencode-go", name = "OpenCode Go", image = "icons/opencode.svg" },
}
local COLORS = {
  red = "#FF7B86",
  amber = "#F4C56A",
  green = "#A6E3A1",
  muted = "on_surface_variant",
}
local WINDOW_NAMES = {
  five_hour = "Janela de 5h",
  week = "Semanal",
  month = "Mensal",
}
local WINDOW_SHORT = {
  five_hour = "5h",
  week = "semana",
  month = "mês",
}

local function configuredInterval()
  local value = tonumber(noctalia.getConfig("interval")) or 60
  if value < 60 then value = 60 elseif value > 600 then value = 600 end
  return math.floor(value)
end

local function nowMilliseconds()
  if noctalia.nowMs then return noctalia.nowMs() end
  return os.time() * 1000
end

local function nowSeconds()
  return math.floor(nowMilliseconds() / 1000)
end

-- Parse ISO-8601 directly to Unix seconds, independent of sandbox/timezone.
local function parseIso(value)
  if type(value) ~= "string" or value == "" then return nil end
  local year, month, day, hour, minute, second, rest =
    string.match(value, "^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
  if not year then
    year, month, day, hour, minute, rest =
      string.match(value, "^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d)(.*)$")
    second = "0"
  end
  if not year then return nil end
  rest = string.gsub(rest or "", "%.%d+", "")
  local offset = 0
  if rest ~= "" and rest ~= "Z" and rest ~= "z" then
    local sign, offsetHour, offsetMinute = string.match(rest, "^([+-])(%d%d):?(%d%d)$")
    if not sign then return nil end
    offset = (tonumber(offsetHour) * 3600 + tonumber(offsetMinute) * 60)
    if sign == "-" then offset = -offset end
  end
  -- Noctalia's sandbox os.time(table) differs from stock Lua. Convert civil
  -- UTC directly so the local timezone is applied only once, by os.date().
  local y, m, d = tonumber(year), tonumber(month), tonumber(day)
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = m + (m > 2 and -3 or 9)
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second) - offset
end

local function resetRelative(seconds)
  if seconds <= 0 then return "renovação pendente" end
  if seconds < 60 then return "em " .. tostring(math.floor(seconds)) .. "s" end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then return "em " .. tostring(minutes) .. "min" end
  local hours = math.floor(minutes / 60)
  local restMinutes = minutes % 60
  if hours < 24 then
    return "em " .. tostring(hours) .. "h" .. (restMinutes > 0 and (" " .. tostring(restMinutes) .. "min") or "")
  end
  local days = math.floor(hours / 24)
  local restHours = hours % 24
  return "em " .. tostring(days) .. "d" .. (restHours > 0 and (" " .. tostring(restHours) .. "h") or "")
end

local function ageText(seconds)
  if seconds == nil then return nil end
  if seconds < 0 then seconds = 0 end
  if seconds < 5 then return "agora" end
  if seconds < 60 then return "há " .. tostring(math.floor(seconds)) .. "s" end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then return "há " .. tostring(minutes) .. "min" end
  local hours = math.floor(minutes / 60)
  if hours < 24 then return "há " .. tostring(hours) .. "h" end
  return "há " .. tostring(math.floor(hours / 24)) .. "d"
end

local function windowName(window, short)
  if short then return WINDOW_SHORT[window] or "período" end
  return WINDOW_NAMES[window] or "Período"
end

local function providerById(snapshot, id)
  for _, provider in ipairs(snapshot and snapshot.providers or {}) do
    if provider.id == id then return provider end
  end
end

local function providerItems(snapshot)
  local items, seen = {}, {}
  for _, meta in ipairs(META) do
    local provider = providerById(snapshot, meta.id)
    local placeholder = provider == nil
    provider = provider or {
      id = meta.id, name = meta.name, remaining = nil, stale = true, windows = {},
    }
    table.insert(items, { meta = meta, provider = provider, placeholder = placeholder })
    seen[meta.id] = true
  end
  for _, provider in ipairs(snapshot and snapshot.providers or {}) do
    if not seen[provider.id] then
      table.insert(items, {
        meta = { id = provider.id, name = provider.name or provider.id, glyph = "chart-pie" },
        provider = provider,
      })
    end
  end
  return items
end

local function primaryValues(provider)
  local window = provider.window
  local remaining = tonumber(provider.remaining)
  local resets = provider.resets_at
  if remaining == nil and window == nil and type(provider.windows) == "table" and provider.windows[1] then
    window = provider.windows[1].window
    remaining = tonumber(provider.windows[1].remaining)
    resets = resets or provider.windows[1].resets_at
  end
  return window, remaining, resets
end

local function thresholdColor(remaining)
  if remaining == nil then return COLORS.muted end
  if remaining <= 10 then return COLORS.red end
  if remaining <= 25 then return COLORS.amber end
  return COLORS.green
end

local function label(text, color)
  return ui.label({ text = text, color = color, fontSize = 12, baseline = "inkCentered", height = 18 })
end

local function glyph(name, color)
  return ui.glyph({ name = name, color = color, size = 14, width = 15, height = 18 })
end

local function brandIcon(meta, color, stale)
  if meta.image then
    local height = meta.id == "opencode-go" and 14 or 18
    return ui.image({ path = meta.image, width = 16, height = height, fit = "contain", opacity = stale and 0.55 or 1 })
  end
  return glyph(meta.glyph, color)
end

local function providerChip(item, snapshot)
  local provider = item.provider
  local _, remaining = primaryValues(provider)
  local stale = provider.stale == true or snapshot.stale_transport == true
  local color = stale and COLORS.muted or thresholdColor(remaining)
  local text
  if remaining == nil then
    text = "--"
  else
    text = tostring(math.floor(remaining)) .. "%" .. (stale and "*" or "")
  end
  return ui.row({
    key = "quota-" .. item.meta.id,
    gap = 3,
    align = "center",
    height = 18,
    paddingH = 0,
    fill = "#00000000",
  }, {
    brandIcon(item.meta, color, stale),
    label(text, color),
  })
end

local function tooltipLines(snapshot)
  local now = nowSeconds()
  local lines = {}
  if not snapshot or snapshot.connecting then
    table.insert(lines, "Cotas de IA · conectando ao serviço local…")
  elseif snapshot.stale_transport then
    table.insert(lines, "Cotas de IA · dados desatualizados")
  elseif snapshot.ok == false then
    table.insert(lines, "Cotas de IA · falha ao consultar as quotas")
  else
    table.insert(lines, "Cotas de IA · percentual RESTANTE")
  end

  for _, item in ipairs(providerItems(snapshot)) do
    local provider = item.provider
    local name = provider.name or item.meta.name
    local window, remaining, resets = primaryValues(provider)
    local stale = provider.stale == true or (snapshot and snapshot.stale_transport == true)
    local value
    if remaining == nil then
      value = "indisponível"
    else
      value = tostring(math.floor(remaining)) .. "% restante"
    end
    table.insert(lines, name .. " · " .. windowName(window, true) .. " · " .. value)
    local details = {}
    if resets then
      local epoch = parseIso(resets)
      if epoch then
        table.insert(details, "renova " .. resetRelative(epoch - now)
          .. " (" .. os.date("%d/%m %H:%M", math.floor(epoch)) .. ")")
      end
    end
    if provider.checked_at then
      local checked = tonumber(provider.checked_at)
      if checked then
        table.insert(details, "atualizado " .. ageText(now - checked)
          .. " (" .. os.date("%d/%m %H:%M", math.floor(checked)) .. ")")
      end
    end
    if #details > 0 then table.insert(lines, "  " .. table.concat(details, " · ")) end
    if stale then
      table.insert(lines, remaining ~= nil
        and "  DADOS DESATUALIZADOS · último valor conhecido"
        or "  DADOS DESATUALIZADOS · sem leitura confirmada")
    end
    if provider.error then table.insert(lines, "  erro: " .. provider.error) end
  end

  if snapshot and snapshot.updated_at then
    local updated = tonumber(snapshot.updated_at)
    if updated then
      table.insert(lines, (snapshot.stale_transport and "Último quadro: " or "Atualizado em: ")
        .. os.date("%d/%m %H:%M", math.floor(updated)) .. " (" .. ageText(now - updated) .. ")")
    end
  end
  if snapshot and snapshot.transport_error then
    table.insert(lines, snapshot.transport_error)
  elseif snapshot and snapshot.ok == false and snapshot.error then
    table.insert(lines, snapshot.error)
  end
  table.insert(lines, "Clique para detalhes · consulta a cada " .. tostring(configuredInterval()) .. "s")
  return lines
end

local last = noctalia.state.get("snapshot")

local function render()
  local content = {}
  local anyStale = last and not last.connecting and (last.stale_transport == true or last.ok == false)
  for _, item in ipairs(providerItems(last)) do
    table.insert(content, providerChip(item, last or {}))
    if not item.placeholder and item.provider.stale == true then anyStale = true end
  end
  if anyStale then table.insert(content, glyph("alert-triangle", COLORS.amber)) end
  local vertical = barWidget.isVertical and barWidget.isVertical()
  local props = { gap = 7, align = "center" }
  if not vertical then props.height = 18 end
  local container = vertical and ui.column or ui.row
  barWidget.render(container(props, content))
  barWidget.setTooltip(table.concat(tooltipLines(last), "\n"))
end

noctalia.state.watch("snapshot", function(data)
  last = data
  render()
end)
noctalia.setUpdateInterval(15000)
function update()
  render()
end
render()

function onClick()
  noctalia.togglePanel("local/ai-quota:details")
end
