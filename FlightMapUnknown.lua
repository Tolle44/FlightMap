
-- FlightMapUnknown.lua -- Minimal, ASCII-only, WoW 1.12 Lua 5.0-safe
-- Learns unknown taxi nodes and real flight times into FlightMap["Alliance"].
-- Shows a live elapsed mm:ss bar for unknown routes. Keeps bar full (unknown total).
-- Direction-specific times only (A->B does not update B->A). No string.format or '%' operator.

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

-- ==== Reuse the original FlightMap bar when possible ====
FMU.fmbar = {
  anchor      = nil,   -- the original bar we found
  label       = nil,   -- a FontString region on that bar, if available
  labelBackup = nil,   -- previous text, so we can restore after landing
  minBackup   = nil,   -- previous MinMax (min)
  maxBackup   = nil,   -- previous MinMax (max)
  valBackup   = nil,   -- previous value
  usingOrig   = false, -- true when we drive the original bar
  pad         = 16,    -- extra padding in pixels for optional auto-width
}

-- Try to find the FlightMap timer bar and a label on it
local function fmuFindFlightMapBar()
  local candidates = {
    "FlightMapTimesFrame",
    "FlightMapTimesStatusBar",
    "FlightMapTimes_Bar",
    "FlightMapTimerBar",
  }
  for i = 1, table.getn(candidates) do
    local bar = getglobal(candidates[i])
    if bar and bar.GetWidth and bar.GetHeight then
      -- Try to find a fontstring region on the bar (reuse existing label if present)
      local label = nil
      if bar.GetRegions then
        local r1, r2, r3, r4, r5, r6, r7, r8 = bar:GetRegions()
        local regs = { r1, r2, r3, r4, r5, r6, r7, r8 }
        for i2 = 1, table.getn(regs) do
          local r = regs[i2]
          if r and r.GetObjectType and r:GetObjectType() == "FontString" then
            label = r
            break
          end
        end
      end
      return bar, label
    end
  end
  return nil, nil
end

-- Begin "reuse" mode: drive the original bar during unknown flights, keep it full
local function fmuReuseStart(destName, startTime)
  local bar, label = fmuFindFlightMapBar()
  if not bar then return false end

  FMU.fmbar.anchor = bar
  FMU.fmbar.label  = label

  -- Backup previous state
  if bar.GetMinMaxValues then FMU.fmbar.minBackup, FMU.fmbar.maxBackup = bar:GetMinMaxValues() end
  if bar.GetValue        then FMU.fmbar.valBackup = bar:GetValue() end
  if label and label.GetText then FMU.fmbar.labelBackup = label:GetText() end

  -- Ensure label exists
  if not label then
    label = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("CENTER", bar, "CENTER", 0, 0)
    label:SetJustifyH("CENTER")
    label:SetJustifyV("CENTER")
    FMU.fmbar.label = label
  end

  -- Keep bar full: 0..1 and set value to 1 (unknown duration)
  if bar.SetMinMaxValues then bar:SetMinMaxValues(0, 1) end
  if bar.SetValue        then bar:SetValue(1) end
  if not bar:IsShown() and bar.Show then bar:Show() end

  -- Seed text
  FMU.fmbar.label:SetText((destName or "Unknown destination") .. " - 00:00")

  FMU.fmbar.usingOrig = true
  return true
end

-- Tick the reused bar: update mm:ss (bar stays full)
local function fmuReuseTick(destName, startTime)
  if not (FMU.fmbar.usingOrig and FMU.fmbar.anchor and FMU.fmbar.label) then return end

  local now     = GetTime()
  local start   = startTime or now
  local elapsed = now - start
  if elapsed < 0 then elapsed = 0 end

  local m  = math.floor(elapsed / 60)
  local s  = math.floor(elapsed - (m * 60))
  local mm = (m < 10) and ("0" .. tostring(m)) or tostring(m)
  local ss = (s < 10) and ("0" .. tostring(s)) or tostring(s)

  local dest = destName or "Unknown destination"
  local txt  = dest .. " - " .. mm .. ":" .. ss
  FMU.fmbar.label:SetText(txt)

  -- Bar remains full (Value stays at 1 for unknown duration)
end

-- Stop reuse mode: restore the original bar to previous state
local function fmuReuseStop()
  if not FMU.fmbar.usingOrig then return end
  local bar   = FMU.fmbar.anchor
  local label = FMU.fmbar.label

  -- Restore min/max, value, and text
  if bar and bar.SetMinMaxValues and FMU.fmbar.minBackup and FMU.fmbar.maxBackup then
    bar:SetMinMaxValues(FMU.fmbar.minBackup, FMU.fmbar.maxBackup)
  end
  if bar and bar.SetValue and FMU.fmbar.valBackup then
    bar:SetValue(FMU.fmbar.valBackup)
  end
  if label and FMU.fmbar.labelBackup then
    label:SetText(FMU.fmbar.labelBackup)
  end

  FMU.fmbar.anchor      = nil
  FMU.fmbar.label       = nil
  FMU.fmbar.labelBackup = nil
  FMU.fmbar.minBackup   = nil
  FMU.fmbar.maxBackup   = nil
  FMU.fmbar.valBackup   = nil
  FMU.fmbar.usingOrig   = false
end
-- ==== end "reuse original bar" helpers ====

-- ==== Elapsed-time overlay (fallback when original bar not found) ====
FMU.elapsed = { enabled = true, hiddenOrig = nil, minWidth = 120, maxWidth = 320, pad = 16 }

local function fmuGetOverlayAnchor()
  local candidates = { "FlightMapTimesFrame", "FlightMapTimesStatusBar", "FlightMapTimes_Bar", "FlightMapTimerBar" }
  for i = 1, table.getn(candidates) do
    local f = getglobal(candidates[i])
    if f and f.GetWidth and f.GetHeight then return f end
  end
  return nil
end

local function fmuEnsureOverlay()
  if FMU.elapsed.frame then return end
  local anchor = fmuGetOverlayAnchor()
  local parent = (anchor and anchor:GetParent()) or UIParent

  local frame = CreateFrame("Frame", "FMU_ElapsedOverlay", parent)
  frame:SetFrameStrata("HIGH")
  frame:SetFrameLevel(50)
  frame:Hide()

  -- Position: match the original bar rectangle if available
  if anchor then
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    frame:SetWidth(anchor:GetWidth())
    frame:SetHeight(anchor:GetHeight())
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    frame:SetWidth(250)
    frame:SetHeight(26)
  end

  -- Border + background similar to tooltip frames
  frame:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true, tileSize = 16, edgeSize = 16,
    insets   = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  frame:SetBackdropColor(0, 0, 0, 0.4)

  local bar = CreateFrame("StatusBar", "FMU_ElapsedBar", frame)
  bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4)
  bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)

  -- Copy texture/color from original bar if possible
  local texPath, cr, cg, cb = nil, 0.0, 0.55, 1.0
  if anchor and anchor.GetStatusBarTexture then
    local t = anchor:GetStatusBarTexture()
    if t and t.GetTexture then texPath = t:GetTexture() end
  end
  if anchor and anchor.GetStatusBarColor then
    cr, cg, cb = anchor:GetStatusBarColor()
  end
  bar:SetStatusBarTexture(texPath or "Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(cr, cg, cb)

  -- Keep bar full for unknown duration
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(1)

  local text = bar:CreateFontString("FMU_ElapsedText", "OVERLAY", "GameFontHighlight")
  text:SetPoint("CENTER", bar, "CENTER", 0, 0)

  FMU.elapsed.frame = frame
  FMU.elapsed.bar   = bar
  FMU.elapsed.text  = text
end

local function fmuOverlayStart(destName, startTime)
  if not FMU.elapsed.enabled then return end
  fmuEnsureOverlay()

  FMU.elapsed.dest  = destName or "Unknown destination"
  FMU.elapsed.start = startTime or GetTime()

  -- Hide original FlightMap bar so only our overlay is visible
  local orig = fmuGetOverlayAnchor()
  if orig and orig:IsShown() then
    orig:Hide()
    FMU.elapsed.hiddenOrig = orig
  else
    FMU.elapsed.hiddenOrig = nil
  end

  FMU.elapsed.frame:Show()
end

local function fmuOverlayStop()
  -- Restore original FlightMap bar if we hid it
  if FMU.elapsed.hiddenOrig and FMU.elapsed.hiddenOrig.Show then
    FMU.elapsed.hiddenOrig:Show()
  end
  FMU.elapsed.hiddenOrig = nil

  if FMU.elapsed.frame then FMU.elapsed.frame:Hide() end
  FMU.elapsed.dest, FMU.elapsed.start = nil, nil
end

local function fmuOverlayTick()
  if not FMU.elapsed.frame or not FMU.elapsed.frame:IsShown() then return end

  local now     = GetTime()
  local start   = FMU.elapsed.start or now
  local elapsed = now - start
  if elapsed < 0 then elapsed = 0 end

  local m  = math.floor(elapsed / 60)
  local s  = math.floor(elapsed - (m * 60))
  local mm = (m < 10) and ("0" .. tostring(m)) or tostring(m)
  local ss = (s < 10) and ("0" .. tostring(s)) or tostring(s)

  local dest = FMU.elapsed.dest or "Unknown destination"
  FMU.elapsed.text:SetText(dest .. " - " .. mm .. ":" .. ss)

  -- Auto-size overlay frame width to fit text within min/max bounds
  local w = FMU.elapsed.text:GetStringWidth() + FMU.elapsed.pad
  if w < FMU.elapsed.minWidth then w = FMU.elapsed.minWidth end
  if w > FMU.elapsed.maxWidth then w = FMU.elapsed.maxWidth end
  FMU.elapsed.frame:SetWidth(w)
end
-- ==== end overlay helpers ====

-- Build SV key: "C:xxx:yyy" where xxx/yyy are TaxiNodePosition * 1000 rounded
local function fmuKeyFromTaxi(C, x, y)
  local xi = math.floor((x or 0) * 1000 + 0.5)
  local yi = math.floor((y or 0) * 1000 + 0.5)
  return tostring(C or 0) .. ":" .. tostring(xi) .. ":" .. tostring(yi)
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
    fmuPrint("[FlightMap] Added node: " .. (name or "Unknown") .. " (" .. key .. ")")
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
      -- No chat on click
    end

    return FMU._origTakeTaxiNode(index)
  end
end  -- IMPORTANT: closes the outer "if not FMU._origTakeTaxiNode and TakeTaxiNode then"

-- OnUpdate: wait for UnitOnTaxi==true to start; record when it becomes false
FMU:SetScript("OnUpdate", function()
  -- Phase 1: wait for takeoff
  if FMU._waitingForTakeoff then
    local onTaxi = UnitOnTaxi and UnitOnTaxi("player")
    if onTaxi then
      FMU._startTime         = GetTime()
      FMU._onTaxi            = 1
      FMU._waitingForTakeoff = nil

      -- Only announce/start UI if route time is unknown
      local originEntry = FlightMap and FlightMap["Alliance"] and FMU._originKey and FlightMap["Alliance"][FMU._originKey]
      local originName  = originEntry and originEntry.Name or "Unknown origin"
      local flights     = originEntry and originEntry.Flights or {}
      local destEntry   = FlightMap and FlightMap["Alliance"] and FMU._destKey and FlightMap["Alliance"][FMU._destKey]
      local destName 	= (destEntry and destEntry.Name) or FMU._destName or FMU._destKey
      local expected    = flights and flights[FMU._destKey]
      FMU._expectedTime = expected

      if (not expected) or (expected <= 0) then
        -- Optional: comment out if you want no chat at takeoff
        fmuPrint("[FlightMap] Taking off: " .. originName .. " -> " .. destName .. " (time unknown - measuring)")
        -- Prefer reuse of original bar; fallback overlay
        if not fmuReuseStart(destName, FMU._startTime) then
          fmuOverlayStart(destName, FMU._startTime)
        end
      end
    end
    return -- keep polling until airborne
  end

  -- Phase 2: mid-flight tick
  if FMU._onTaxi then
    if FMU.fmbar.usingOrig then
      fmuReuseTick(FMU._destName or "Unknown destination", FMU._startTime)
    else
      fmuOverlayTick()
    end

    -- Landing detection always runs
    local onTaxi = UnitOnTaxi and UnitOnTaxi("player")
    if not onTaxi then
      local start = FMU._startTime
      if start and FlightMap and FlightMap["Alliance"] then
        local dur    = GetTime() - start
        local origin = FlightMap["Alliance"][FMU._originKey]
        if origin then
          origin.Flights = origin.Flights or {}
          local prev       = origin.Flights[FMU._destKey]
          local destEntry  = FlightMap["Alliance"][FMU._destKey]
          local originName = origin.Name or FMU._originKey
          local destName   = (destEntry and destEntry.Name) or FMU._destName or FMU._          local destName   = (destEntry and destEntry.Name) or FMU._destName or FMU._destKey

          local expected = FMU._expectedTime
          local within   = false
          if expected and expected > 0 then
            within = (math.abs(dur - expected) <= 1.0)
          end

          if not within then
            if (not prev) or (prev <= 0) then
              origin.Flights[FMU._destKey] = dur
              fmuPrint("[FlightMap] Learned time: " .. originName .. " -> " .. destName .. ": " .. tostring(math.floor(dur + 0.5)) .. "s")
            else
              origin.Flights[FMU._destKey] = dur
              fmuPrint("[FlightMap] Updated time: " .. originName .. " -> " .. destName ..
                       ": " .. tostring(math.floor(dur + 0.5)) .. "s (was " .. tostring(math.floor(prev + 0.5)) .. "s)")
            end
          end
        else
          fmuPrint("[FlightMap] Warning: origin key not found; timing not saved.")
        end
      else
        fmuPrint("[FlightMap] Warning: start time or SV missing; timing not saved.")
      end

      -- Stop whichever UI we used and reset state
      if FMU.fmbar.usingOrig then
        fmuReuseStop()
      else
        fmuOverlayStop()
      end

      FMU._onTaxi, FMU._startTime, FMU._originKey, FMU._destKey, FMU._destName, FMU._expectedTime =
        nil, nil, nil, nil, nil, nil
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
