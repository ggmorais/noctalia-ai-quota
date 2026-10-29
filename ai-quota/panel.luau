--!nonstrict
-- Detail panel for the AI Quota widget. Shows every provider, its primary
-- remaining window, reset time and additional windows reported by the backend.
-- The last snapshot is always shown; stale data is tinted and labelled.

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
    offset = tonumber(offsetHour) * 3600 + tonumber(offsetMinute) * 60
    if sign == "-" then offset = -offset end
  end
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
  if seconds == nil then return "agora" end
  if seconds < 0 then seconds = 0 end
  if seconds < 5 then return "agora" end
  if seconds < 60 then return "há " .. tostring(math.floor(seconds)) .. "s" end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then return "há " .. tostring(minutes) .. "min" end
  local hours = math.floor(minutes / 60)
  if hours < 24 then return "há " .. tostring(hours) .. "h" end
  return "há " .. tostring(math.floor(hours / 24)) .. "d"
end

local function windowName(window)
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

local function percentString(remaining)
  if remaining == nil then return "--" end
  return tostring(math.floor(remaining)) .. "%"
end

local function statusView(snapshot, now)
  if not snapshot or snapshot.connecting or type(snapshot.providers) ~= "table" then
    return { glyph = "clock", color = COLORS.amber, text = "Conectando ao serviço local de quotas…" }
  end
  if snapshot.stale_transport then
    local age = snapshot.transport_stale_at and ageText(now - snapshot.transport_stale_at) or "alguns minutos"
    local updated = tonumber(snapshot.updated_at)
    local suffix = updated and (" · último quadro " .. os.date("%d/%m %H:%M", math.floor(updated))) or ""
    return {
      glyph = "clock-exclamation",
      color = COLORS.amber,
      text = "Sem atualizações " .. age .. " · exibindo os últimos dados conhecidos" .. suffix,
    }
  end
  if snapshot.ok == false then
    return {
      glyph = "alert-triangle",
      color = snapshot.error and COLORS.red or COLORS.amber,
      text = snapshot.error or "Uma ou mais cotas estão desatualizadas.",
    }
  end
  local updated = tonumber(snapshot.updated_at)
  if updated then
    return {
      glyph = "circle-check",
      color = "on_surface_variant",
      text = "Atualizado " .. ageText(now - updated) .. " · " .. os.date("%d/%m %H:%M", math.floor(updated)),
    }
  end
  return { glyph = "info-circle", color = "on_surface_variant", text = "Snapshot recebido." }
end

local function brandIcon(meta, color, stale)
  if meta.image then
    return ui.image({ path = meta.image, width = 20, height = 24, fit = "contain", opacity = stale and 0.55 or 1 })
  end
  return ui.glyph({ name = meta.glyph, size = 20, color = color })
end

local function providerCard(item, snapshot, now)
  local provider = item.provider
  local window, remaining, resets = primaryValues(provider)
  local stale = (provider.stale == true and not item.placeholder) or snapshot.stale_transport == true
  local color = stale and COLORS.muted or thresholdColor(remaining)
  local border = stale and (COLORS.amber .. "66")
    or (provider.error and (COLORS.red .. "66") or "surface_variant")
  local fill = stale and (COLORS.amber .. "14") or "surface_variant"
  local children = {
    ui.row({ gap = 9, align = "center" }, {
      brandIcon(item.meta, color, stale),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = provider.name or item.meta.name, fontSize = 14, fontWeight = "bold" }),
        ui.label({ text = windowName(window), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.label({ text = percentString(remaining), fontSize = 22, fontWeight = "bold", color = color }),
    }),
    ui.label({
      text = remaining == nil and "Indisponível" or "Percentual restante",
      fontSize = 10,
      color = "on_surface_variant",
    }),
  }
  if remaining ~= nil then
    table.insert(children, ui.progress({
      progress = math.max(0, math.min(1, remaining / 100)),
      fill = color,
      track = "surface_variant",
      height = 6,
      radius = 3,
    }))
  end

  local resetEpoch = resets and parseIso(resets) or nil
  if resetEpoch then
    table.insert(children, ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "hourglass", size = 12, color = "on_surface_variant" }),
      ui.label({
        text = "Renova " .. resetRelative(resetEpoch - now) .. " · " .. os.date("%d/%m %H:%M", resetEpoch),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 2,
      }),
    }))
  else
    table.insert(children, ui.label({
      text = "Sem horário de renovação informado",
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end

  if provider.checked_at then
    local checked = tonumber(provider.checked_at)
    if checked then
      table.insert(children, ui.label({
        text = "Verificado " .. ageText(now - checked) .. " · " .. os.date("%d/%m %H:%M", math.floor(checked)),
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
      }))
    end
  end

  if stale then
    table.insert(children, ui.row({ gap = 5, align = "center" }, {
      ui.glyph({ name = "alert-triangle", size = 13, color = COLORS.amber }),
      ui.label({
        text = remaining ~= nil and "Desatualizado · último valor preservado"
          or "Desatualizado · sem leitura confirmada",
        fontSize = 11,
        color = COLORS.amber,
        maxLines = 2,
      }),
    }))
  end
  if provider.error then
    table.insert(children, ui.label({
      text = provider.error,
      fontSize = 11,
      color = stale and COLORS.amber or COLORS.red,
      maxLines = 2,
    }))
  end

  local extra = {}
  for _, itemWindow in ipairs(provider.windows or {}) do
    if itemWindow.window ~= window then table.insert(extra, itemWindow) end
  end
  if #extra > 0 then
    table.insert(children, ui.label({
      text = "Outras janelas",
      fontSize = 11,
      fontWeight = "bold",
      color = "on_surface_variant",
    }))
    for _, itemWindow in ipairs(extra) do
      local itemReset = itemWindow.resets_at and parseIso(itemWindow.resets_at) or nil
      table.insert(children, ui.row({
        key = "quota-window-" .. provider.id .. "-" .. tostring(itemWindow.window),
        gap = 6,
        align = "center",
      }, {
        ui.label({ text = windowName(itemWindow.window), fontSize = 11, color = "on_surface_variant", width = 88 }),
        ui.label({
          text = percentString(tonumber(itemWindow.remaining)),
          fontSize = 12,
          fontWeight = "bold",
          color = stale and COLORS.muted or thresholdColor(tonumber(itemWindow.remaining)),
        }),
        ui.label({
          text = itemReset and resetRelative(itemReset - now) or "sem reset",
          fontSize = 11,
          color = "on_surface_variant",
          flexGrow = 1,
          textAlign = "end",
        }),
      }))
    end
  end

  return ui.column({
    key = "quota-card-" .. provider.id,
    gap = 6,
    padding = 12,
    radius = 10,
    fill = fill,
    border = border,
    borderWidth = 1,
  }, children)
end

local last = noctalia.state.get("snapshot")
local isOpen = false
local render

local function renderContent()
  if not isOpen then return end
  local snapshot = last or {}
  local now = nowSeconds()
  local cards = {}
  for _, item in ipairs(providerItems(last)) do
    table.insert(cards, providerCard(item, snapshot, now))
  end
  local status = statusView(snapshot, now)
  panel.render(ui.column({ gap = 12, flexGrow = 1 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "gauge", size = 24, color = "primary" }),
      ui.column({ gap = 1, flexGrow = 1 }, {
        ui.label({ text = "Cotas de IA", fontSize = 19, fontWeight = "bold" }),
        ui.label({
          text = "Percentual restante · vermelho ≤10% · âmbar ≤25% · verde >25%",
          fontSize = 10,
          color = "on_surface_variant",
          maxLines = 2,
        }),
      }),
      ui.button({ glyph = "settings", tooltip = "Configurações do plugin", onClick = "openSettings" }),
      ui.button({ glyph = "x", tooltip = "Fechar", onClick = "closePanel" }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.glyph({ name = status.glyph, size = 14, color = status.color }),
      ui.label({ text = status.text, color = status.color, fontSize = 12, maxLines = 2, flexGrow = 1 }),
    }),
    ui.scroll({ key = "quota-list", gap = 10, flexGrow = 1 }, cards),
    ui.label({
      text = "Fonte: serviço local @slkiser/opencode-quota · sem cópia de credenciais · consulta a cada "
        .. tostring(configuredInterval()) .. "s",
      fontSize = 10,
      color = "on_surface_variant",
      maxLines = 2,
    }),
  }))
end

render = function()
  if not isOpen then return end
  local ok, message = pcall(renderContent)
  if not ok then
    panel.render(ui.column({ gap = 12 }, {
      ui.label({ text = "Não foi possível exibir as cotas", color = "error", fontWeight = "bold" }),
      ui.label({ text = tostring(message), maxLines = 8 }),
      ui.button({ text = "Fechar", onClick = "closePanel" }),
    }))
  end
end

noctalia.state.watch("snapshot", function(data)
  last = data
  render()
end)

function onOpen()
  isOpen = true
  if panel.setWantsSecondTicks then panel.setWantsSecondTicks(true) end
  render()
end

function onClose()
  isOpen = false
end

function update()
  if isOpen then render() end
end

function closePanel()
  panel.close()
end

function openSettings()
  noctalia.openSettings()
end
