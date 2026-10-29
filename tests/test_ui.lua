-- Host-side UI checks for the AI Quota widget and panel.
-- Lua 5.5 is enough: the plugin scripts use the portable subset of Luau.

local root = "ai-quota/"
local now = 1700000000
local data = nil
local watches = {}
local values = {}
-- Sandboxed os.time(table) must not be used for ISO conversion: Noctalia's
-- civil-time behavior differs from stock Lua (caught by on-screen validation).
local hostTime = os.time
os.time = function(value)
  assert(type(value) ~= "table", "ISO reset conversion must be timezone-independent")
  return hostTime(value)
end
local colors = {
  red = "#FF7B86",
  amber = "#F4C56A",
  green = "#A6E3A1",
}

noctalia = {
  getConfig = function(key)
    assert(key == "interval", "unexpected setting: " .. tostring(key))
    return 60
  end,
  nowMs = function() return now * 1000 end,
  state = {
    get = function() return data end,
    watch = function(_, fn) table.insert(watches, fn) end,
    set = function(_, snapshot)
      data = snapshot
      for _, fn in ipairs(watches) do fn(snapshot) end
    end,
  },
  pluginDir = function() return "/plugin" end,
  log = function() end,
  setUpdateInterval = function(ms) assert(ms == 15000) end,
  togglePanel = function(id) values.panel = id end,
  openSettings = function() values.settings = true end,
}

ui = setmetatable({}, { __index = function(_, kind)
  return function(props, children) return { kind = kind, props = props, children = children } end
end })

local function find(node, predicate)
  if not node then return nil end
  if predicate(node) then return node end
  for _, child in ipairs(node.children or {}) do
    local found = find(child, predicate)
    if found then return found end
  end
end

local function count(node, predicate)
  if not node then return 0 end
  local total = predicate(node) and 1 or 0
  for _, child in ipairs(node.children or {}) do total = total + count(child, predicate) end
  return total
end

local function textNode(text)
  return function(node)
    return node.kind == "label" and node.props.text == text
  end
end

local function textContains(fragment)
  return function(node)
    return node.kind == "label" and type(node.props.text) == "string"
      and string.find(node.props.text, fragment, 1, true) ~= nil
  end
end

barWidget = {
  render = function(tree) values.bar = tree end,
  setTooltip = function(text) values.tooltip = text end,
}

local function snapshot()
  return {
    ok = true,
    updated_at = now - 30.5,
    providers = {
      {
        id = "openai", name = "OpenAI", window = "five_hour", remaining = 8.9,
        resets_at = "2023-11-15T00:13:20Z", checked_at = now - 120.25, stale = false,
        windows = {
          { window = "five_hour", remaining = 8.9, resets_at = "2023-11-15T00:13:20Z" },
          { window = "month", remaining = 52, resets_at = "2023-12-01T00:00:00Z" },
        },
      },
      {
        id = "anthropic", name = "Anthropic", window = "five_hour", remaining = 20,
        resets_at = "2023-11-16T00:00:00Z", checked_at = now - 300, stale = false,
        windows = {
          { window = "five_hour", remaining = 20, resets_at = "2023-11-16T00:00:00Z" },
          { window = "week", remaining = 73, resets_at = "2023-11-20T00:00:00Z" },
        },
      },
      {
        id = "opencode-go", name = "OpenCode Go", window = "month", remaining = 60,
        resets_at = "2023-12-01T00:00:00Z", checked_at = now - 45, stale = false,
        windows = {
          { window = "month", remaining = 60, resets_at = "2023-12-01T00:00:00Z" },
        },
      },
    },
  }
end

-- Initial state: no snapshot yet. Three distinguishable placeholder logos, no
-- false warning, explicit connection message.
dofile(root .. "widget.luau")
assert(values.bar.props.align == "center")
assert(count(values.bar, textNode("--")) == 3)
assert(find(values.bar, function(node) return node.props.name == "brand-openai" end))
for _, name in ipairs({ "anthropic", "opencode" }) do
  local icon = find(values.bar, function(node) return node.kind == "image" and node.props.path == "icons/" .. name .. ".svg" end)
  assert(icon and icon.props.fit == "contain", "missing brand asset " .. name)
  assert(icon.props.color == nil and icon.props.tint == nil, "preserve brand colors")
end
assert(not find(values.bar, function(node) return node.props.name == "alert-triangle" end))
assert(string.find(values.tooltip, "conectando", 1, true))
assert(string.find(values.tooltip, "consulta a cada 60s", 1, true))

-- Healthy snapshot: percentages are remaining, thresholds and logos are clear.
local healthy = snapshot()
data = healthy
watches[1](data)
assert(find(values.bar, textNode("8%")))
assert(find(values.bar, textNode("20%")))
assert(find(values.bar, textNode("60%")))
assert(find(values.bar, function(node)
  return node.kind == "label" and node.props.text == "8%" and node.props.color == colors.red
end))
assert(find(values.bar, function(node)
  return node.kind == "label" and node.props.text == "20%" and node.props.color == colors.amber
end))
assert(find(values.bar, function(node)
  return node.kind == "label" and node.props.text == "60%" and node.props.color == colors.green
end))
assert(not find(values.bar, function(node)
  return node.kind == "row" and node.props.fill == colors.red .. "1A"
end))
assert(not find(values.bar, function(node)
  return node.kind == "row" and node.props.fill == colors.amber .. "1A"
end))
assert(find(values.bar, function(node)
  return node.kind == "image" and node.props.path == "icons/opencode.svg" and node.props.height == 14
end))
for _, chip in ipairs(values.bar.children) do
  assert(chip.props.fill == "#00000000" and chip.props.paddingH == 0)
end
assert(string.find(values.tooltip, "RESTANTE", 1, true))
assert(string.find(values.tooltip, "OpenAI · 5h · 8% restante", 1, true))
assert(string.find(values.tooltip, "renova em 2h", 1, true))
assert(string.find(values.tooltip, "atualizado há 2min", 1, true))
assert(string.find(values.tooltip, "Atualizado em:", 1, true))
assert(string.match(values.tooltip, "%d%d/%d%d %d%d:%d%d"))
assert(not find(values.bar, function(node) return node.props.name == "alert-triangle" end))

-- Boundaries are inclusive: 10% is red, 25% is amber, 26% is green.
local boundary = snapshot()
boundary.providers[1].remaining = 10
boundary.providers[2].remaining = 25
boundary.providers[3].remaining = 26
noctalia.state.set("snapshot", boundary)
assert(find(values.bar, function(node)
  return node.kind == "label" and node.props.text == "10%" and node.props.color == colors.red
end))
assert(find(values.bar, function(node)
  return node.kind == "label" and node.props.text == "25%" and node.props.color == colors.amber
end))
assert(find(values.bar, function(node)
  return node.kind == "label" and node.props.text == "26%" and node.props.color == colors.green
end))

-- Stale provider keeps its number but becomes unmistakably stale.
healthy.providers[1].stale = true
healthy.ok = false
noctalia.state.set("snapshot", healthy)
local staleLabel = find(values.bar, textNode("8%*"))
assert(staleLabel and staleLabel.props.color == "on_surface_variant")
assert(find(values.bar, function(node) return node.props.name == "alert-triangle" end))
assert(string.find(values.tooltip, "DADOS DESATUALIZADOS", 1, true))

-- A provider with no reading is "--", never 0%.
data = snapshot()
data.providers[3].remaining = nil
data.providers[3].resets_at = nil
data.providers[3].stale = true
data.ok = false
noctalia.state.set("snapshot", data)
assert(find(values.bar, textNode("--")))
assert(string.find(values.tooltip, "indisponível", 1, true))
assert(string.find(values.tooltip, "sem leitura confirmada", 1, true))

-- Transport timeout preserves values and marks the whole bar.
data = snapshot()
data.ok = false
data.stale_transport = true
data.transport_error = "Sem atualizações do monitor há 150 s."
noctalia.state.set("snapshot", data)
assert(find(values.bar, textNode("8%*")))
assert(string.find(values.tooltip, "dados desatualizados", 1, true))
assert(string.find(values.tooltip, "Sem atualizações do monitor há 150 s.", 1, true))

-- Relative reset text refreshes on the widget tick without a new snapshot.
data = snapshot()
noctalia.state.set("snapshot", data)
now = now + 3600
update()
assert(string.find(values.tooltip, "renova em 1h", 1, true))
now = 1700000000
onClick()
assert(values.panel == "local/ai-quota:details")

-- Panel: three detail cards, extra windows, status, footer and actions.
panel = {
  render = function(tree) values.tree = tree end,
  close = function() values.closed = true end,
  setWantsSecondTicks = function(value) values.ticks = value end,
}
dofile(root .. "panel.luau")
onOpen()
assert(values.ticks == true)
assert(values.tree.kind == "column")
local list = find(values.tree, function(node) return node.props.key == "quota-list" end)
assert(list and #list.children == 3)
local openai = find(values.tree, function(node) return node.props.key == "quota-card-openai" end)
assert(openai and openai.props.border == "surface_variant" and openai.props.fill == "surface_variant")
assert(find(openai, textNode("OpenAI")))
assert(find(openai, textNode("8%")))
assert(find(openai, textNode("Percentual restante")))
assert(find(openai, textContains("Renova em 2h")))
assert(find(openai, textNode("Outras janelas")))
assert(find(openai, textNode("Mensal")))
assert(find(openai, textNode("52%")))
assert(find(openai, textContains("Verificado há 2min")))
assert(find(values.tree, textContains("Atualizado há")))
assert(find(values.tree, textContains("@slkiser/opencode-quota")))
assert(find(values.tree, function(node) return node.props.glyph == "settings" end))
assert(find(values.tree, function(node) return node.props.glyph == "x" end))

-- Stale detail card is visually distinct and names the preserved state.
data.providers[2].stale = true
data.providers[2].error = "Dado antigo; aguardando confirmação."
data.ok = false
noctalia.state.set("snapshot", data)
local anthropic = find(values.tree, function(node) return node.props.key == "quota-card-anthropic" end)
assert(anthropic.props.border == colors.amber .. "66")
assert(anthropic.props.fill == colors.amber .. "14")
assert(find(anthropic, textNode("Desatualizado · último valor preservado")))
assert(find(anthropic, textNode("Dado antigo; aguardando confirmação.")))
assert(find(anthropic, function(node)
  return node.kind == "image" and node.props.path == "icons/anthropic.svg" and node.props.opacity == 0.55
end))

-- Panel tick updates the relative reset time while open.
now = now + 3600
update()
openai = find(values.tree, function(node) return node.props.key == "quota-card-openai" end)
assert(find(openai, textContains("Renova em 1h")))

-- Connecting state still renders the three provider cards without pretending
-- that unavailable data is a zero quota.
data = nil
noctalia.state.set("snapshot", nil)
onOpen()
list = find(values.tree, function(node) return node.props.key == "quota-list" end)
assert(list and #list.children == 3)
assert(find(values.tree, textContains("Conectando ao serviço local")))
assert(count(values.tree, textNode("--")) >= 3)
assert(not find(values.tree, textContains("Desatualizado · último valor")))

openSettings()
assert(values.settings)
closePanel()
assert(values.closed)
onClose()
print("UI: compact remaining percentages, thresholds, stale preservation, tooltips, panel details and fallbacks OK")
