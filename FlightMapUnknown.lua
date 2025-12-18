
-- FlightMapUnknown.lua -- Minimal, ASCII-only, balanced
-- Learns unknown taxi nodes and real flight times into FlightMap["Alliance"].

local FMU = CreateFrame("Frame", "FlightMapUnknown")
FMU:RegisterEvent("ADDON_LOADED")
FMU:RegisterEvent("TAXIMAP_OPENED")
FMU:RegisterEvent("TAXIMAP_CLOSED")

-- Index of nodes on the currently open taxi map: i -> { key, name, type, x, y, continent }
FMU.idx = {}
FMU.currentKey = nil

-- Utility: print to chat
local function fmuPrint(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage(msg, 0.85, 1.0, 0.9)
  end
end

-- Build SV key: "C:xxx:yyy" where xxx/yyy are TaxiNodePosition * 1000 rounded
local function fmuKeyFromTaxi(C, x, y)
  local xi = math.floor((x or 0) * 1000 + 0.5)
  local yi = math.floor((y or 0) * 1000 + 0.5)
  return string.format("%d:%d:%d", C or 0, xi, yi)
end

-- Get continent index robustly
local function fmuGetContinent()
  if SetMapToCurrentZone then SetMapToCurrentZone() end
  if GetCurrentMapContinent then
    local C = GetCurrentMapContinent()
    if type(C) == "number" then return C end
  end
  return 0
end

-- Ensure a node entry exists in FlightMap["Alliance"][key]
local function fmuEnsureNode(key, name, C, tx, ty)
  if not FlightMap or not FlightMap["Alliance"] then return end
  local t = FlightMap["Alliance"][key]
  if not t then
    FlightMap["Alliance"][key] = {
      Name = name or "Unknown Node",
      Zone = "Unknown!",
      Continent = C or -1,
      Location = {
        Zone      = { x = 0, y = 0 },
        Continent = { x = 0, y = 0 },
        Taxi      = { x = tx or 0, y = ty or 0 },
      },
      Flights = {},
      Costs   = {},
      Routes  = {},
    }
    fmuPrint(string.format("[FlightMap] Added node: %s (%s)", name or "Unknown", key))
  else
    local loc = t.Location or {}
    t.Location = loc
    loc.Taxi = loc.Taxi or {}
    if tx then loc.Taxi.x = tx end
    if ty then loc.Taxi.y = ty end
    if C and (t.Continent == -1 or t.Continent == 0) then t.Continent = C end
    if name and (t.Name == "Unknown Node" or not t.Name) then t.Name = name end
  end
end

-- Scan taxi map and build index mapping
local function fmuScanTaxi()
  FMU.idx = {}
  FMU.currentKey = nil

  local C = fmuGetContinent()
  local n = NumTaxiNodes and NumTaxiNodes() or 0

  for i = 1, n do
    local name = TaxiNodeName and TaxiNodeName(i)
    local x, y = 0, 0
    if TaxiNodePosition then x, y = TaxiNodePosition(i) end
    local typeStr = TaxiNodeGetType and TaxiNodeGetType(i) or "UNKNOWN"
    if name and name ~= "INVALID" then
      local key = fmuKeyFromTaxi(C, x, y)
      FMU.idx[i] = { key = key, name = name, type = typeStr, x = x, y = y, continent = C }
      fmuEnsureNode(key, name, C, x, y)
      if typeStr == "CURRENT" then FMU.currentKey = key end
    end
  end
end

-- Hook TakeTaxiNode once (captures origin/dest; start timing only after takeoff)
if not FMU._origTakeTaxiNode and TakeTaxiNode then
  FMU._origTakeTaxiNode = TakeTaxiNode
  TakeTaxiNode = function(index)
    -- Ensure we have the latest map scan
    if not FMU.idx[index] then
      if TaxiNodeName and NumTaxiNodes and (NumTaxiNodes() or 0) > 0 then
        fmuScanTaxi()
      end
    end
    local dest = FMU.idx[index]
    local originKey = FMU.currentKey
    if originKey and dest and dest.key then
      FMU._originKey         = originKey
      FMU._destKey           = dest.key
      FMU._destName          = dest.name
      FMU._waitingForTakeoff = 1
      FMU._startTime         = nil
      FMU._onTaxi            = nil
      fmuPrint(string.format("[FlightMap] Taxi requested: %s -> %s", originKey, dest.key))
    end
    return FMU._origTakeTaxiNode(index)
  end
end  -- IMPORTANT: this closes the outer


-- OnUpdate: wait for UnitOnTaxi==true to start; record when it becomes false
FMU:SetScript("OnUpdate", function()
  -- Phase 1: wait for takeoff
  if FMU._waitingForTakeoff then
    local onTaxi = UnitOnTaxi and UnitOnTaxi("player")
    if onTaxi then
      FMU._startTime         = GetTime()
      FMU._onTaxi            = 1
      FMU._waitingForTakeoff = nil
      fmuPrint(string.format("[FlightMap] Takeoff detected; timing %s -> %s",
        FMU._originKey or "?", FMU._destKey or "?"))
    end
    return
  end

  -- Phase 2: mid-flight timing and landing detection
  if FMU._onTaxi then
    local onTaxi = UnitOnTaxi and UnitOnTaxi("player")
    if not onTaxi then
      local start = FMU._startTime
      if start and FlightMap and FlightMap["Alliance"] then
        local dur = GetTime() - start
        local ok = FlightMap["Alliance"][FMU._originKey]
        if ok then
          ok.Flights = ok.Flights or {}
          ok.Flights[FMU._destKey] = dur
          fmuPrint(string.format("[FlightMap] Learned time %s -> %s: %ds",
            FMU._originKey, FMU._destKey, math.floor(dur + 0.5)))
        else
          fmuPrint("[FlightMap] Warning: origin key not found; timing not saved.")
        end
      else
        fmuPrint("[FlightMap] Warning: start time or SV missing; timing not saved.")
      end
      -- Reset all flight state
      FMU._onTaxi, FMU._startTime, FMU._originKey, FMU._destKey, FMU._destName = nil, nil, nil, nil, nil
    end
  end
end)

-- Vanilla-style event handler (uses globals: event, arg1, ...)
FMU:SetScript("OnEvent", function()
  if event == "ADDON_LOADED" and (arg1 == "FlightMap" or arg1 == "FlightMapUnknown") then
    -- nothing required
  elseif event == "TAXIMAP_OPENED" then
    fmuScanTaxi()
  elseif event == "TAXIMAP_CLOSED" then
    -- no-op
  end
end)
