local GoodsFinder = {}

local LOG_PREFIX = "[Goods Finder 1.1.0]"
local PUBLIC_DIAGNOSTICS = false

local function log(message)
    local text = tostring(message)
    if PUBLIC_DIAGNOSTICS
        or string.find(text, "Lua loaded", 1, true)
        or string.find(text, "ABORT", 1, true)
        or string.find(text, "COMPLETE | success=false", 1, true)
    then
        system.log(LOG_PREFIX .. " " .. text)
    end
end

local function safe(callback)
    local ok, value = pcall(callback)
    if not ok then return nil, tostring(value) end
    return value, nil
end

local function getProduct(guid)
    if type(guid) ~= "number" or guid <= 0 then return nil end
    local product = safe(function() return GetProductAssetData(guid) end)
    if product == nil then return nil end
    local valid = safe(function() return product.IsValid end)
    if valid ~= true then return nil end
    return {
        guid = guid,
        name = tostring(safe(function() return product.Text end) or "<unnamed product>")
    }
end

local function captureHoveredProduct()
    local refGuid, err = safe(function() return InfoTip and InfoTip.RefGuid end)
    if err ~= nil then
        log("InfoTip.RefGuid read failed | " .. err)
        return nil
    end
    local product = getProduct(refGuid)
    if product == nil then
        log("no valid product detected | warehouse mode may continue without preselection")
        return nil
    end
    log("product detected | productGUID=" .. tostring(product.guid)
        .. " | productName=" .. tostring(product.name)
        .. " | session=" .. tostring((GameSession and GameSession.SessionGUID) or 0))
    return product
end

local function addArea(records, seen, object, source)
    if object == nil then return end
    local owned = safe(function() return object.IsOwnedByCurrentParticipant end)
    if owned ~= true then return end

    local sessionGuid = safe(function() return object.SessionGuid end)
    local currentSession = safe(function() return GameSession and GameSession.SessionGUID end)
    if sessionGuid ~= nil and currentSession ~= nil and sessionGuid ~= currentSession then return end

    local area = safe(function() return object.Area end)
    if area == nil then return end
    local areaId = safe(function() return area.ID end)
    if type(areaId) ~= "number" or areaId <= 0 or seen[areaId] then return end

    seen[areaId] = true
    records[#records + 1] = {
        area = area,
        areaId = areaId,
        areaName = tostring(safe(function() return area.CityName end) or ("Area " .. tostring(areaId))),
        objectId = safe(function() return object.ID end) or 0,
        objectGuid = safe(function() return object.GUID end) or 0,
        source = source
    }
end

local function collectOwnedAreas()
    local records, seen = {}, {}
    local propertyNames = {"KontorFeature", "Warehouse"}

    for _, propertyName in ipairs(propertyNames) do
        local property = Properties and Properties[propertyName]
        if property ~= nil then
            local objects, err = safe(function()
                return Scripts:GetObjectGroupByProperty(property) or {}
            end)
            if err ~= nil then
                log("group query failed | property=" .. propertyName .. " | " .. err)
            else
                local count = 0
                for _, object in pairs(objects or {}) do
                    count = count + 1
                    addArea(records, seen, object, propertyName)
                end
                log("group query | property=" .. propertyName .. " | objects=" .. tostring(count))
            end
        else
            log("property unavailable | " .. propertyName)
        end
    end

    table.sort(records, function(a, b)
        local ak = string.lower(a.areaName) .. "|" .. tostring(a.areaId)
        local bk = string.lower(b.areaName) .. "|" .. tostring(b.areaId)
        return ak < bk
    end)
    return records
end

local function readAreaStock(record, productGuid)
    local amount, amountErr = safe(function()
        return record.area.Economy:GetStorageAmount(productGuid)
    end)
    local capacity, capacityErr = safe(function()
        return record.area.Economy:GetStorageCapacity(productGuid)
    end)
    local free, freeErr = safe(function()
        if record.area.Economy.GetFreeSpace ~= nil then
            return record.area.Economy:GetFreeSpace(productGuid)
        end
        return nil
    end)

    return amount, capacity, free, amountErr, capacityErr, freeErr
end

function GoodsFinder:Load()
    self.nativeClickProbePending = false
    self.nativeClickProbePhase = nil
    self.nativeClickProbeTickCounter = 0
    self.nativeClickProbePreviousStationCount = 0
    self.nativeClickProbeHookCallCount = 0
    self.nativeClickProbeHookRecords = {}
    self.nativeClickProbeHooks = {}
    self.nativeClickProbeAuditDone = false

    self.autoIslandPending = false
    self.autoIslandPhase = nil
    self.autoIslandTickCounter = 0
    self.autoIslandAttemptIndex = 0
    self.autoIslandTargetAreaID = nil
    self.autoIslandTargetName = nil
    self.autoIslandExpectedStationCount = 0
    self.autoIslandHelperAreaID = nil
    self.autoIslandHelperName = nil
    self.autoIslandOriginalInfoTipRefGuid = nil
    self.autoIslandInfoTipRetargeted = false

    self.autoShipListWaitPending = false
    self.autoShipListWaitTickCounter = 0
    self.autoShipListWaitLogged = false
    self.autoShipSelectionPending = false
    self.autoShipSelectionName = nil
    self.autoShipTickCounter = 0
    self.autoShipTickLogged = false
    self.autoGoodsHoverPending = false
    self.autoGoodsHoverTickCounter = 0
    self.autoGoodsHoverLogged = false

    self.autoReturnPending = false
    self.autoReturnSawPopup = false
    self.autoReturnTickCounter = 0
    self.autoReturnCloseTickCounter = 0
    self.autoReturnLogged = false

    self.nativeCloseVerifyPending = false
    self.nativeCloseVerifyTickCounter = 0
    self.nativeCloseBaselineSignature = nil
    self.nativeClosePrecloseSignature = nil
    self.nativeCloseDispatchClock = nil
    self.nativeCloseDispatchTime = nil

    self.directLoadSelectedRowIndex = nil
    self.directLoadSelectedRowWasEmpty = false
    self.trackedRowRemoveDone = false
    self.removeSurfaceProbeDone = false

    self.existingRouteScanPending = false
    self.existingRouteCandidates = {}
    self.existingRouteCandidateIndex = 0
    self.existingRoutePhase = nil
    self.existingRouteTickCounter = 0
    self.existingRouteCurrentId = nil
    self.existingRouteCurrentName = nil
    self.existingRouteCurrentLogged = false
    self.existingRouteExactMatchSeen = false
    self.existingRouteHelperStationIndex = nil
    self.existingRouteHelperStationName = nil
    self.existingRoutePreferredBySession = self.existingRoutePreferredBySession or {}

    self.failureCleanupPending = false
    self.failureCleanupPhase = nil
    self.failureCleanupTickCounter = 0
    self.failureCleanupReason = nil
    self.failureCleanupMode = nil

    log("Lua loaded | Goods Finder ready | Ctrl+Alt+G | anywhere start | optional hovered-good preselection | automatic Latium/Albion popup reopen")
end

local function captureAndLogStock(allowMissingProduct)
    local product = captureHoveredProduct()
    if product == nil then
        if allowMissingProduct == true then
            -- Warehouse-only mode still needs the owned-area list because the
            -- route helper uses lastStockRecords to recognize current-province
            -- station names. Do not read product stock when no product exists.
            local records = collectOwnedAreas()

            GoodsFinder.lastProductGuid = 0
            GoodsFinder.lastProductName = ""
            GoodsFinder.lastSessionGuid = tonumber(
                safe(function()
                    return GameSession and GameSession.SessionGUID
                end)
            ) or 0
            GoodsFinder.lastIslandCount = #records
            GoodsFinder.lastStockRecords = {}

            for _, record in ipairs(records) do
                GoodsFinder.lastStockRecords[#GoodsFinder.lastStockRecords + 1] = {
                    areaId = record.areaId,
                    areaName = record.areaName,
                    amount = 0,
                    capacity = 0
                }
            end

            log("WAREHOUSEMODE PRODUCT"
                .. " | preselection=false"
                .. " | reason=no hovered product"
                .. " | behavior=open full goods list"
                .. " | provinceAreaCount=" .. tostring(#records)
                .. " | provinceFilterPreserved=true"
                .. " | productStockReads=false")
        end
        return nil
    end
    local records = collectOwnedAreas()
    log("owned island areas collected | count=" .. tostring(#records))
    for index, record in ipairs(records) do
        local amount, capacity, free, amountErr, capacityErr, freeErr = readAreaStock(record, product.guid)
        log("island stock"
            .. " | index=" .. tostring(index)
            .. " | areaID=" .. tostring(record.areaId)
            .. " | areaName=" .. tostring(record.areaName)
            .. " | amount=" .. tostring(amount)
            .. " | capacity=" .. tostring(capacity)
            .. " | free=" .. tostring(free)
            .. " | source=" .. tostring(record.source)
            .. " | objectID=" .. tostring(record.objectId)
            .. " | objectGUID=" .. tostring(record.objectGuid)
            .. " | amountError=" .. tostring(amountErr or "")
            .. " | capacityError=" .. tostring(capacityErr or "")
            .. " | freeError=" .. tostring(freeErr or ""))
    end
    GoodsFinder.lastProductGuid = product.guid
    GoodsFinder.lastProductName = product.name
    GoodsFinder.lastSessionGuid = tonumber(
        safe(function()
            return GameSession and GameSession.SessionGUID
        end)
    ) or 0
    GoodsFinder.lastIslandCount = #records
    GoodsFinder.lastStockRecords = {}
    for _, record in ipairs(records) do
        local amount, capacity = readAreaStock(record, product.guid)
        GoodsFinder.lastStockRecords[#GoodsFinder.lastStockRecords + 1] = {
            areaId = record.areaId,
            areaName = record.areaName,
            amount = amount or 0,
            capacity = capacity or 0
        }
    end
    return product
end


local function describeArea(label, area)
    local valid = safe(function() return area and area:isValid() end)
    local id = safe(function() return area and area.ID end)
    local name = safe(function() return area and area.CityName end)
    log("warehouse area candidate | source=" .. label
        .. " | type=" .. type(area)
        .. " | valid=" .. tostring(valid)
        .. " | areaID=" .. tostring(id)
        .. " | areaName=" .. tostring(name))
    if valid == true and type(id) == "number" and id > 0 then
        return { area=area, areaId=id, areaName=tostring(name or ("Area " .. id)) }
    end
    return nil
end

local function captureWarehouseArea()
    local candidates = {
        {"Area.CurrentSelectedArea", safe(function() return Area and Area.CurrentSelectedArea end)},
        {"Area.AreaFromContext", safe(function() return Area and Area.AreaFromContext end)},
        {"Area.Current", safe(function() return Area and Area.Current end)}
    }
    for _, c in ipairs(candidates) do
        local record = describeArea(c[1], c[2])
        if record then
            GoodsFinder.lastWarehouseAreaId = record.areaId
            GoodsFinder.lastWarehouseAreaName = record.areaName
            log("warehouse area remembered | areaID=" .. tostring(record.areaId) .. " | areaName=" .. record.areaName)
            return record
        end
    end
    log("warehouse area unresolved")
    return nil
end

function GoodsFinder:ProbeTradeRouteGoodsPopup()
    log("POPUP PROBE start | expectedProductGUID=" .. tostring(self.lastProductGuid)
        .. " | expectedProductName=" .. tostring(self.lastProductName)
        .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId)
        .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName))
    local hoverGuid, hoverErr = safe(function() return InfoTip and InfoTip.RefGuid end)
    local hoverProduct = getProduct(hoverGuid)
    log("popup hover | refGuid=" .. tostring(hoverGuid)
        .. " | productName=" .. tostring(hoverProduct and hoverProduct.name)
        .. " | matchesRemembered=" .. tostring(hoverGuid == self.lastProductGuid)
        .. " | error=" .. tostring(hoverErr or ""))
    local route, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local valid = safe(function() return route and route:isValid() end)
    local name = safe(function() return route and route.Name end)
    log("popup route context | type=" .. type(route) .. " | valid=" .. tostring(valid)
        .. " | name=" .. tostring(name) .. " | error=" .. tostring(routeErr or ""))
    if valid == true then
        for stationId=0,15 do
            local station = safe(function() return route:GetStation(stationId) end)
            local stationValid = safe(function() return station and station:isValid() end)
            if stationValid == true then
                log("popup route station | stationID=" .. stationId .. " | type=" .. type(station))
                for goodId=0,7 do
                    local has = safe(function() return station:HasGood(goodId) end)
                    local good = safe(function() return station:GetGood(goodId) end)
                    local guid = safe(function() return good and good.Guid end)
                    local amount = safe(function() return good and good.Amount end)
                    local loading = safe(function() return good and good.Loading end)
                    if has == true or (type(guid)=="number" and guid>0) then
                        log("popup route good | stationID="..stationId.." | slot="..goodId
                            .." | has="..tostring(has).." | guid="..tostring(guid)
                            .." | amount="..tostring(amount).." | loading="..tostring(loading))
                    end
                end
            end
        end
    end
    log("POPUP PROBE complete | no writes performed")
    return true
end

function GoodsFinder:OpenMap()
    log("STEP 1 | capture stock + open province MacroMap/TradeRoute overview")
    local product = captureAndLogStock()
    if product == nil then return false end
    captureWarehouseArea()
    local result, err = safe(function()
        Scripts:ToggleTraderouteMenu()
        return true
    end)
    log("STEP 1 result | success=" .. tostring(result == true) .. " | error=" .. tostring(err or "")
        .. " | next=wait until overview is visible, then press Ctrl+Alt+C once")
    return result == true
end

function GoodsFinder:CreateNewRoute()
    log("STEP 2 | request vanilla New Trade Route action | gamepadAction=321")
    local beforeRoute = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local beforeValid = safe(function() return beforeRoute and beforeRoute:isValid() end)
    log("STEP 2 before | UIEditRouteType=" .. tostring(type(beforeRoute))
        .. " | UIEditRouteValid=" .. tostring(beforeValid))

    local result, err = safe(function()
        AutomatedTest:SendFakeGamepadEvents({321}, {0})
        return true
    end)

    local afterRoute = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local afterValid = safe(function() return afterRoute and afterRoute:isValid() end)
    local afterName = safe(function() return afterRoute and afterRoute.Name end)
    log("STEP 2 dispatched | success=" .. tostring(result == true)
        .. " | error=" .. tostring(err or "")
        .. " | UIEditRouteTypeImmediate=" .. tostring(type(afterRoute))
        .. " | UIEditRouteValidImmediate=" .. tostring(afterValid)
        .. " | routeNameImmediate=" .. tostring(afterName)
        .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or "")
        .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | productName=" .. tostring(self.lastProductName or ""))
    return result == true
end

function GoodsFinder:FindAndOpenExistingRoute()
    log("STEP 2 | scan existing route IDs and open the first valid route read-only")
    if type(TradeRoute) ~= "table" or type(TradeRoute.GetRoute) ~= "function" then
        log("STEP 2 failed | TradeRoute.GetRoute unavailable")
        return false
    end

    local firstId = nil
    local found = 0
    for routeId = 1, 4096 do
        local route = safe(function() return TradeRoute:GetRoute(routeId) end)
        local valid = safe(function() return route and route:isValid() end)
        if valid == true then
            found = found + 1
            local name = safe(function() return route.Name end)
            local activeErrors = safe(function() return route.ActiveErrorCount end)
            log("existing route found | scanID=" .. tostring(routeId)
                .. " | name=" .. tostring(name or "")
                .. " | activeErrors=" .. tostring(activeErrors))
            if firstId == nil then firstId = routeId end
            if found >= 25 then break end
        end
    end

    log("route scan complete | found=" .. tostring(found) .. " | firstID=" .. tostring(firstId))
    if firstId == nil then
        log("STEP 2 failed | no valid route found in IDs 1..4096")
        return false
    end

    GoodsFinder.lastExistingRouteId = firstId
    local result, err = safe(function()
        TradeRoute:ShowRouteUI(firstId)
        return true
    end)
    log("STEP 2 open result | routeID=" .. tostring(firstId)
        .. " | success=" .. tostring(result == true)
        .. " | error=" .. tostring(err or ""))
    return result == true
end

local function buildVisibleStockSummary()
    local productName = tostring(GoodsFinder.lastProductName or "Good")
    local records = GoodsFinder.lastStockRecords or {}
    local parts = {}
    for i = 1, math.min(#records, 3) do
        local row = records[i]
        parts[#parts + 1] = tostring(row.areaName) .. " " .. tostring(math.floor(row.amount or 0))
    end
    local suffix = #records > 3 and (" +" .. tostring(#records - 3) .. " islands") or ""
    return "GF " .. productName .. " | " .. table.concat(parts, " | ") .. suffix
end

function GoodsFinder:ApplyVisibleRouteNameProbe()
    local editRoute, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local valid = safe(function() return editRoute and editRoute:isValid() end)
    if valid ~= true then
        log("STEP 3 failed | no valid UIEditRoute | routeError=" .. tostring(routeErr or ""))
        return false
    end
    if self.originalRouteName ~= nil then
        log("STEP 3 blocked | a route name probe is already active | restore with Ctrl+Alt+B")
        return false
    end
    local originalName, nameErr = safe(function() return editRoute.Name end)
    if originalName == nil then
        log("STEP 3 failed | cannot read route name | error=" .. tostring(nameErr or ""))
        return false
    end
    local probeName = buildVisibleStockSummary()
    self.originalRouteName = tostring(originalName)
    self.probeRouteName = probeName
    local result, setErr = safe(function()
        editRoute.Name = probeName
        return true
    end)
    log("STEP 3 route-name binding | success=" .. tostring(result == true)
        .. " | originalName=" .. tostring(originalName)
        .. " | probeName=" .. tostring(probeName)
        .. " | error=" .. tostring(setErr or "")
        .. " | IMPORTANT=restore with Ctrl+Alt+B before closing")
    return result == true
end

function GoodsFinder:RestoreRouteName()
    if self.originalRouteName == nil then
        log("RESTORE skipped | no active route-name probe")
        return false
    end
    local editRoute, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local valid = safe(function() return editRoute and editRoute:isValid() end)
    if valid ~= true then
        log("RESTORE failed | UIEditRoute no longer valid | originalName=" .. tostring(self.originalRouteName)
            .. " | routeError=" .. tostring(routeErr or ""))
        return false
    end
    local restoreName = self.originalRouteName
    local result, setErr = safe(function()
        editRoute.Name = restoreName
        return true
    end)
    log("RESTORE route name | success=" .. tostring(result == true)
        .. " | restoredName=" .. tostring(restoreName)
        .. " | error=" .. tostring(setErr or ""))
    if result == true then
        self.originalRouteName = nil
        self.probeRouteName = nil
    end
    return result == true
end



local function getValidEditRoute()
    local editRoute, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local valid, validErr = safe(function() return editRoute and editRoute:isValid() end)
    if valid ~= true then
        log("binding inspector failed | UIEditRoute invalid | routeError=" .. tostring(routeErr or "")
            .. " | validError=" .. tostring(validErr or ""))
        return nil
    end
    return editRoute
end

local function readCandidateFields(object, label, fields)
    for _, field in ipairs(fields) do
        local value, err = safe(function() return object[field] end)
        log("field probe | object=" .. tostring(label)
            .. " | field=" .. tostring(field)
            .. " | value=" .. tostring(value)
            .. " | valueType=" .. tostring(type(value))
            .. " | error=" .. tostring(err or ""))
    end
end

function GoodsFinder:InspectRouteBindings()
    local editRoute = getValidEditRoute()
    if editRoute == nil then return false end

    log("BINDING INSPECTOR start | read-only scan of route, stations and goods")
    readCandidateFields(editRoute, "UIEditRoute", {
        "Name", "ID", "RouteID", "StationCount", "Stations", "Goods", "Description",
        "SelectedStation", "SelectedGood", "CurrentStation", "CurrentGood", "ActiveErrorCount"
    })

    local stationCount = 0
    local goodCount = 0
    self.lastWritableGood = nil

    for stationId = 0, 63 do
        local station, stationErr = safe(function() return editRoute:GetStation(stationId) end)
        local stationValid, validErr = safe(function() return station and station:isValid() end)
        if stationValid == true then
            stationCount = stationCount + 1
            local cliff = safe(function() return station.IsCliffIsland end)
            local owned = safe(function() return station.StationBelongsToCurrentParticipant end)
            local rights = safe(function() return station.CurrentParticipantHasTradeRights end)
            log("station found | stationID=" .. tostring(stationId)
                .. " | cliff=" .. tostring(cliff)
                .. " | owned=" .. tostring(owned)
                .. " | tradeRights=" .. tostring(rights))
            readCandidateFields(station, "Station[" .. tostring(stationId) .. "]", {
                "Name", "ID", "AreaID", "Area", "StationID", "ObjectID", "Harbor", "Kontor", "Goods"
            })

            for goodId = 0, 63 do
                local hasGood, hasErr = safe(function() return station:HasGood(goodId) end)
                if hasGood == true then
                    local good, goodErr = safe(function() return station:GetGood(goodId) end)
                    if good ~= nil then
                        goodCount = goodCount + 1
                        local loading, loadingErr = safe(function() return good.Loading end)
                        local guid, guidErr = safe(function() return good.Guid end)
                        local amount, amountErr = safe(function() return good.Amount end)
                        local data, dataErr = safe(function() return good.GoodData end)
                        local dataText, dataTextErr = safe(function() return data and data.Text end)
                        log("good found | stationID=" .. tostring(stationId)
                            .. " | goodID=" .. tostring(goodId)
                            .. " | loading=" .. tostring(loading)
                            .. " | guid=" .. tostring(guid)
                            .. " | amount=" .. tostring(amount)
                            .. " | productName=" .. tostring(dataText)
                            .. " | loadingError=" .. tostring(loadingErr or "")
                            .. " | guidError=" .. tostring(guidErr or "")
                            .. " | amountError=" .. tostring(amountErr or "")
                            .. " | dataError=" .. tostring(dataErr or "")
                            .. " | dataTextError=" .. tostring(dataTextErr or ""))
                        readCandidateFields(good, "Good[" .. tostring(stationId) .. ":" .. tostring(goodId) .. "]", {
                            "Loading", "Guid", "Amount", "GoodData", "Name", "Text", "Description",
                            "WaitUntilLoaded", "WaitUntilUnloaded", "Discard", "Slot", "Index"
                        })
                        if self.lastWritableGood == nil and type(guid) == "number" and type(amount) == "number" then
                            self.lastWritableGood = {
                                object = good,
                                stationId = stationId,
                                goodId = goodId,
                                guid = guid,
                                amount = amount,
                                loading = loading
                            }
                        end
                    else
                        log("good read failed | stationID=" .. tostring(stationId)
                            .. " | goodID=" .. tostring(goodId)
                            .. " | error=" .. tostring(goodErr or ""))
                    end
                elseif hasErr ~= nil then
                    log("HasGood failed | stationID=" .. tostring(stationId)
                        .. " | goodID=" .. tostring(goodId)
                        .. " | error=" .. tostring(hasErr))
                end
            end
        elseif stationErr ~= nil and stationId < 4 then
            log("station probe miss | stationID=" .. tostring(stationId)
                .. " | stationError=" .. tostring(stationErr or "")
                .. " | validError=" .. tostring(validErr or ""))
        end
    end

    log("BINDING INSPECTOR complete | stations=" .. tostring(stationCount)
        .. " | goods=" .. tostring(goodCount)
        .. " | sameValueWriteCandidate=" .. tostring(self.lastWritableGood ~= nil))
    return true
end

function GoodsFinder:TestSameValueGoodWrites()
    local editRoute = getValidEditRoute()
    if editRoute == nil then return false end
    local candidate = self.lastWritableGood
    if candidate == nil then
        log("SAME-VALUE WRITE skipped | first press Ctrl+Alt+I to locate a good row")
        return false
    end

    local good = candidate.object
    local validRead, validReadErr = safe(function() return good.Guid end)
    if validRead == nil then
        log("SAME-VALUE WRITE failed | remembered good reference invalid | error=" .. tostring(validReadErr or ""))
        return false
    end

    log("SAME-VALUE WRITE start | no values are intentionally changed"
        .. " | stationID=" .. tostring(candidate.stationId)
        .. " | goodID=" .. tostring(candidate.goodId)
        .. " | guid=" .. tostring(candidate.guid)
        .. " | amount=" .. tostring(candidate.amount)
        .. " | loading=" .. tostring(candidate.loading))

    local guidOK, guidErr = safe(function() good.Guid = candidate.guid return true end)
    local amountOK, amountErr = safe(function() good.Amount = candidate.amount return true end)
    local loadingOK, loadingErr = safe(function() good.Loading = candidate.loading return true end)
    local afterGuid = safe(function() return good.Guid end)
    local afterAmount = safe(function() return good.Amount end)
    local afterLoading = safe(function() return good.Loading end)

    log("SAME-VALUE WRITE result"
        .. " | GuidWritable=" .. tostring(guidOK == true)
        .. " | GuidError=" .. tostring(guidErr or "")
        .. " | AmountWritable=" .. tostring(amountOK == true)
        .. " | AmountError=" .. tostring(amountErr or "")
        .. " | LoadingWritable=" .. tostring(loadingOK == true)
        .. " | LoadingError=" .. tostring(loadingErr or "")
        .. " | afterGuid=" .. tostring(afterGuid)
        .. " | afterAmount=" .. tostring(afterAmount)
        .. " | afterLoading=" .. tostring(afterLoading)
        .. " | IMPORTANT=no changed values; close editor with Escape without saving")
    return guidOK == true or amountOK == true or loadingOK == true
end


function GoodsFinder:InspectUIComponents()
    local editRoute = getValidEditRoute()
    if editRoute == nil then
        log("UI COMPONENT INSPECTOR aborted | open a valid existing route first with Ctrl+Alt+R")
        return false
    end

    log("UI COMPONENT INSPECTOR start | scan global UI/component objects while valid route editor is open")
    local exactNames = {
        "TradeRoute", "UIEditRoute", "SessionTradeRoutesEditor", "TradeRouteSelectGoodPopup",
        "TradeRoutesGoodsBtn", "MacroMapInteractive", "MacroMap", "TradeRouteScene",
        "SessionTradeRoutesScene", "UI", "GUI", "GameUI", "InfoTip", "Input"
    }
    local fields = {
        "Name", "Text", "Label", "Title", "Caption", "Description", "Tooltip", "Visible", "Enabled",
        "Selected", "Value", "Amount", "Guid", "GUID", "ProductGUID", "AreaID", "StationID",
        "SetText", "SetLabel", "SetTitle", "SetVisible", "Show", "Hide", "Open", "Close",
        "GetText", "GetLabel", "GetName", "GetComponent", "FindComponent", "GetChild", "FindChild",
        "Children", "Components", "Scene", "Root", "UIEditRoute"
    }

    for _, name in ipairs(exactNames) do
        local obj, err = safe(function() return _G[name] end)
        log("UI global exact | name=" .. tostring(name) .. " | type=" .. tostring(type(obj))
            .. " | value=" .. tostring(obj) .. " | error=" .. tostring(err or ""))
        if obj ~= nil then
            for _, field in ipairs(fields) do
                local value, ferr = safe(function() return obj[field] end)
                if value ~= nil or ferr ~= nil then
                    log("UI field | object=" .. tostring(name) .. " | field=" .. tostring(field)
                        .. " | type=" .. tostring(type(value)) .. " | value=" .. tostring(value)
                        .. " | error=" .. tostring(ferr or ""))
                end
            end
            if type(obj) == "table" then
                local n = 0
                for k, v in pairs(obj) do
                    n = n + 1
                    if n <= 80 then
                        log("UI table member | object=" .. tostring(name) .. " | key=" .. tostring(k)
                            .. " | type=" .. tostring(type(v)) .. " | value=" .. tostring(v))
                    end
                end
                log("UI table member scan complete | object=" .. tostring(name) .. " | count=" .. tostring(n))
            end
        end
    end

    local matches = 0
    for k, v in pairs(_G) do
        local key = tostring(k)
        local lower = string.lower(key)
        if string.find(lower, "trade", 1, true)
            or string.find(lower, "route", 1, true)
            or string.find(lower, "good", 1, true)
            or string.find(lower, "macro", 1, true)
            or string.find(lower, "scene", 1, true)
            or string.find(lower, "widget", 1, true)
            or string.find(lower, "component", 1, true) then
            matches = matches + 1
            if matches <= 160 then
                log("UI global match | key=" .. key .. " | type=" .. tostring(type(v)) .. " | value=" .. tostring(v))
            end
        end
    end
    log("UI COMPONENT INSPECTOR complete | matchingGlobals=" .. tostring(matches)
        .. " | note=no writes performed")
    return true
end

function GoodsFinder:InspectEditor()
    local editRoute, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local valid, validErr = safe(function() return editRoute and editRoute:isValid() end)
    local id, idErr = safe(function() return editRoute and editRoute.ID end)
    local name, nameErr = safe(function() return editRoute and editRoute.Name end)
    log("STEP 3 inspect | UIEditRouteType=" .. tostring(type(editRoute))
        .. " | valid=" .. tostring(valid)
        .. " | id=" .. tostring(id)
        .. " | name=" .. tostring(name)
        .. " | routeError=" .. tostring(routeErr or "")
        .. " | validError=" .. tostring(validErr or "")
        .. " | idError=" .. tostring(idErr or "")
        .. " | nameError=" .. tostring(nameErr or ""))
    return valid == true
end



function GoodsFinder:StartInteractionRecording()
    log("INTERACTION RECORDER start requested")
    if type(AutomatedTest) ~= "table" or type(AutomatedTest.StartSnippetRecording) ~= "function" then
        log("INTERACTION RECORDER unavailable | AutomatedTest.StartSnippetRecording missing")
        return false
    end
    if self.snippetRecordingActive == true then
        log("INTERACTION RECORDER already active | stop with Ctrl+Alt+2 before starting again")
        return false
    end
    local result, err = safe(function()
        AutomatedTest:StartSnippetRecording()
        return true
    end)
    self.snippetRecordingActive = result == true
    log("INTERACTION RECORDER started | success=" .. tostring(result == true)
        .. " | error=" .. tostring(err or "")
        .. " | now perform the exact vanilla clicks and stop with Ctrl+Alt+2")
    return result == true
end

function GoodsFinder:StopInteractionRecording()
    log("INTERACTION RECORDER stop requested | activeFlag=" .. tostring(self.snippetRecordingActive == true))
    if type(AutomatedTest) ~= "table" or type(AutomatedTest.StopSnippetRecording) ~= "function" then
        log("INTERACTION RECORDER unavailable | AutomatedTest.StopSnippetRecording missing")
        return false
    end
    local value, err = safe(function()
        return AutomatedTest:StopSnippetRecording()
    end)
    self.snippetRecordingActive = false
    log("INTERACTION RECORDER stopped | callSuccess=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(value))
        .. " | returnValue=" .. tostring(value)
        .. " | error=" .. tostring(err or "")
        .. " | recorder output diagnostics follow")
    self:DumpRecorderOutputSurface("after StopSnippetRecording")
    return err == nil
end

function GoodsFinder:DumpInfoTipContext()
    log("INFOTIP CONTEXT DUMP start")
    local refGuid, refGuidErr = safe(function() return InfoTip and InfoTip.RefGuid end)
    local refOid, refOidErr = safe(function() return InfoTip and InfoTip.RefOid end)
    local refTextId, refTextErr = safe(function() return InfoTip and InfoTip.RefTextId end)
    log("infotip refs | RefGuid=" .. tostring(refGuid)
        .. " | RefOid=" .. tostring(refOid)
        .. " | RefTextId=" .. tostring(refTextId)
        .. " | RefGuidError=" .. tostring(refGuidErr or "")
        .. " | RefOidError=" .. tostring(refOidErr or "")
        .. " | RefTextIdError=" .. tostring(refTextErr or ""))
    local sources = {
        "OMKontorWarehouse", "TradeRouteSelectGoodPopup", "SessionTradeRoutesEditor",
        "SessionTradeRoutesScene", "TradeRoutesGoodsBtn", "MacroMapInteractive",
        "MacroMapScene", "TradeRoute", "GenericPopup"
    }
    for _, source in ipairs(sources) do
        local match, err = safe(function() return InfoTip and InfoTip:CheckInfoTipSource(source) end)
        log("infotip source | name=" .. source .. " | match=" .. tostring(match)
            .. " | error=" .. tostring(err or ""))
    end
    local names = {
        "Guid", "GUID", "ProductGuid", "ProductGUID", "GoodGuid", "GoodGUID",
        "AreaID", "StationID", "Slot", "Index", "Name", "Text", "Amount"
    }
    for _, name in ipairs(names) do
        local isSet, setErr = safe(function() return InfoTip and InfoTip:IsContextValueSet(name) end)
        if isSet == true then
            local ctx, ctxErr = safe(function() return InfoTip:GetContextValue(name) end)
            local valid = safe(function() return ctx and ctx:isValid() end)
            local asInt = safe(function() return ctx and ctx.AsInt end)
            local asFloat = safe(function() return ctx and ctx.AsFloat end)
            local asBool = safe(function() return ctx and ctx.AsBool end)
            local asString = safe(function() return ctx and ctx.AsString end)
            log("infotip context | name=" .. name .. " | isSet=true | valid=" .. tostring(valid)
                .. " | AsInt=" .. tostring(asInt) .. " | AsFloat=" .. tostring(asFloat)
                .. " | AsBool=" .. tostring(asBool) .. " | AsString=" .. tostring(asString)
                .. " | setError=" .. tostring(setErr or "") .. " | getError=" .. tostring(ctxErr or ""))
        end
    end
    log("INFOTIP CONTEXT DUMP complete")
    return true
end

function GoodsFinder:Diagnostics()
    local sessionGuid = safe(function() return GameSession and GameSession.SessionGUID end)
    local editRoute = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local editValid = safe(function() return editRoute and editRoute:isValid() end)
    log("DIAGNOSTICS | session=" .. tostring(sessionGuid or 0)
        .. " | ToggleTraderouteMenu=" .. tostring(Scripts and Scripts.ToggleTraderouteMenu)
        .. " | AutomatedTestType=" .. tostring(type(AutomatedTest))
        .. " | SendFakeGamepadEvents=" .. tostring(AutomatedTest and AutomatedTest.SendFakeGamepadEvents)
        .. " | TradeRouteType=" .. tostring(type(TradeRoute))
        .. " | ShowRouteUI=" .. tostring(TradeRoute and TradeRoute.ShowRouteUI)
        .. " | UIEditRouteType=" .. tostring(type(editRoute))
        .. " | UIEditRouteValid=" .. tostring(editValid)
        .. " | lastExistingRouteID=" .. tostring(self.lastExistingRouteId or 0)
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | rememberedIslands=" .. tostring(self.lastIslandCount or 0))
    return true
end



local function explorerRead(object, objectLabel, memberName)
    local value, err = safe(function() return object and object[memberName] end)
    log("EXPLORE member | object=" .. objectLabel
        .. " | member=" .. memberName
        .. " | type=" .. tostring(type(value))
        .. " | value=" .. tostring(value)
        .. " | error=" .. tostring(err or ""))
    return value, err
end

local function explorerValid(object)
    local valid, err = safe(function()
        if object == nil then return false end
        local fn = object.isValid
        if type(fn) == "function" then
            return fn(object)
        end
        return true
    end)
    return valid == true, err
end

local function exploreAsset(asset, label)
    local valid, validErr = explorerValid(asset)
    log("EXPLORE asset root | object=" .. label
        .. " | type=" .. tostring(type(asset))
        .. " | valid=" .. tostring(valid)
        .. " | validError=" .. tostring(validErr or ""))
    if asset == nil then return end
    for _, member in ipairs({"Guid", "GUID", "Text", "Icon", "Name", "Description", "isValid"}) do
        explorerRead(asset, label, member)
    end
end

local function exploreGood(good, stationID, goodID)
    local label = "Station[" .. tostring(stationID) .. "].Good[" .. tostring(goodID) .. "]"
    local valid, validErr = explorerValid(good)
    log("EXPLORE good root | object=" .. label
        .. " | type=" .. tostring(type(good))
        .. " | valid=" .. tostring(valid)
        .. " | validError=" .. tostring(validErr or ""))
    if good == nil then return end

    local goodData = nil
    for _, member in ipairs({
        "Loading", "Guid", "GUID", "Amount", "GoodData", "Name", "ProductGUID",
        "ProductGuid", "Slot", "Index", "ID", "Id", "isValid"
    }) do
        local value = explorerRead(good, label, member)
        if member == "GoodData" then goodData = value end
    end
    if goodData ~= nil then
        exploreAsset(goodData, label .. ".GoodData")
    end
end

local function exploreStation(route, station, stationID)
    local label = "Station[" .. tostring(stationID) .. "]"
    local valid, validErr = explorerValid(station)
    log("EXPLORE station root | object=" .. label
        .. " | type=" .. tostring(type(station))
        .. " | valid=" .. tostring(valid)
        .. " | validError=" .. tostring(validErr or ""))
    if valid ~= true then return 0 end

    for _, member in ipairs({
        "IsCliffIsland", "StationBelongsToCurrentParticipant",
        "CurrentParticipantHasTradeRights", "GetGood", "HasGood", "isValid",
        "ID", "Id", "AreaID", "AreaId", "Name", "Goods", "GoodCount", "Options"
    }) do
        explorerRead(station, label, member)
    end

    local validGoods = 0
    local consecutiveEmpty = 0
    for goodID = 0, 128 do
        local hasGood, hasErr = safe(function()
            local fn = station.HasGood
            if type(fn) ~= "function" then return nil end
            return fn(station, goodID)
        end)
        local good, goodErr = safe(function()
            local fn = station.GetGood
            if type(fn) ~= "function" then return nil end
            return fn(station, goodID)
        end)
        local goodValid, goodValidErr = explorerValid(good)

        if hasGood == true or goodValid == true then
            consecutiveEmpty = 0
            validGoods = validGoods + 1
            log("EXPLORE good accessor | stationID=" .. tostring(stationID)
                .. " | goodID=" .. tostring(goodID)
                .. " | hasGood=" .. tostring(hasGood)
                .. " | hasError=" .. tostring(hasErr or "")
                .. " | getType=" .. tostring(type(good))
                .. " | getValid=" .. tostring(goodValid)
                .. " | getError=" .. tostring(goodErr or "")
                .. " | validError=" .. tostring(goodValidErr or ""))
            exploreGood(good, stationID, goodID)
        else
            consecutiveEmpty = consecutiveEmpty + 1
            if goodID <= 8 or goodID % 16 == 0 then
                log("EXPLORE good accessor empty | stationID=" .. tostring(stationID)
                    .. " | goodID=" .. tostring(goodID)
                    .. " | hasGood=" .. tostring(hasGood)
                    .. " | hasError=" .. tostring(hasErr or "")
                    .. " | getType=" .. tostring(type(good))
                    .. " | getError=" .. tostring(goodErr or "")
                    .. " | validError=" .. tostring(goodValidErr or ""))
            end
        end
    end
    log("EXPLORE station goods complete | stationID=" .. tostring(stationID)
        .. " | validGoods=" .. tostring(validGoods))
    return validGoods
end

function GoodsFinder:ExploreUIEditRouteObjectGraph()
    log("EXPLORE START | recursive read-only object graph scan; no values will be changed")

    local route, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local routeValid, validErr = explorerValid(route)
    log("EXPLORE route root | type=" .. tostring(type(route))
        .. " | valid=" .. tostring(routeValid)
        .. " | routeError=" .. tostring(routeErr or "")
        .. " | validError=" .. tostring(validErr or ""))

    if routeValid ~= true then
        log("EXPLORE ABORT | UIEditRoute is not valid. Create an unsaved route, assign a ship, add stations and a good, close the goods popup, then press Ctrl+Alt+I.")
        return false
    end

    for _, member in ipairs({
        "Name", "NotEnoughStationsActive", "NoGoodsActive", "NoShipsActive",
        "AllShipsPausedActive", "ActiveErrorCount", "GetStation", "GetLostShipName",
        "IsErrorActive", "NotEnoughSlotsErrorActive", "NotEnoughSlotsForShipsErrorActive",
        "IslandUnderSiegeActive", "NoValidPierActive", "NoTradeRightsActive",
        "ConfiguredGoodNotTradedActive", "LoadedGoodNeverUnloadedActive",
        "UnloadedGoodNeverLoadedActive", "GoodsDontMatchActive", "StorageFullActive",
        "StorageEmptyActive", "LongWaitingTimeActive", "MismatchingGoodActive",
        "MismatchingGoodActiveForGood", "isValid", "ID", "Id", "Stations", "Ships",
        "Goods", "StationCount", "ShipCount", "GoodCount"
    }) do
        explorerRead(route, "UIEditRoute", member)
    end

    local validStations = 0
    local validGoods = 0
    for stationID = 0, 128 do
        local station, stationErr = safe(function()
            local fn = route.GetStation
            if type(fn) ~= "function" then return nil end
            return fn(route, stationID)
        end)
        local stationValid, stationValidErr = explorerValid(station)
        if stationValid == true then
            validStations = validStations + 1
            log("EXPLORE station accessor | stationID=" .. tostring(stationID)
                .. " | type=" .. tostring(type(station))
                .. " | valid=true"
                .. " | getError=" .. tostring(stationErr or "")
                .. " | validError=" .. tostring(stationValidErr or ""))
            validGoods = validGoods + exploreStation(route, station, stationID)
        elseif stationID <= 8 or stationID % 16 == 0 then
            log("EXPLORE station accessor empty | stationID=" .. tostring(stationID)
                .. " | type=" .. tostring(type(station))
                .. " | getError=" .. tostring(stationErr or "")
                .. " | validError=" .. tostring(stationValidErr or ""))
        end
    end

    for _, member in ipairs({"UIEditRoute", "TradeRoutesWithIssues", "GetRoute", "ShowRouteUI", "isValid"}) do
        explorerRead(TradeRoute, "TradeRouteManager", member)
    end

    log("EXPLORE COMPLETE | validStations=" .. tostring(validStations)
        .. " | validGoods=" .. tostring(validGoods)
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or "")
        .. " | readOnly=true")
    return true
end



local function probeAssignment(object, objectLabel, memberName, value)
    local before, beforeErr = safe(function() return object and object[memberName] end)
    local writeResult, writeErr = safe(function()
        object[memberName] = value
        return true
    end)
    local after, afterErr = safe(function() return object and object[memberName] end)
    log("MUTABILITY assignment | object=" .. objectLabel
        .. " | member=" .. memberName
        .. " | beforeType=" .. tostring(type(before))
        .. " | before=" .. tostring(before)
        .. " | attempted=" .. tostring(value)
        .. " | writeSuccess=" .. tostring(writeResult == true)
        .. " | writeError=" .. tostring(writeErr or "")
        .. " | afterType=" .. tostring(type(after))
        .. " | after=" .. tostring(after)
        .. " | beforeError=" .. tostring(beforeErr or "")
        .. " | afterError=" .. tostring(afterErr or ""))
    return writeResult == true, before, after, writeErr
end

function GoodsFinder:ProbeGoodFieldMutability()
    log("MUTABILITY START | safe same-value assignments only; route configuration should remain unchanged")
    local route, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local routeValid, validErr = explorerValid(route)
    log("MUTABILITY route root | type=" .. tostring(type(route))
        .. " | valid=" .. tostring(routeValid)
        .. " | routeError=" .. tostring(routeErr or "")
        .. " | validError=" .. tostring(validErr or ""))
    if routeValid ~= true then
        log("MUTABILITY ABORT | create an unsaved route with ship, two stations, and one configured good; close the goods popup; then press Ctrl+Alt+M")
        return false
    end

    local routeName = safe(function() return route.Name end)
    probeAssignment(route, "UIEditRoute", "Name", routeName)

    local foundStations, foundGoods = 0, 0
    for stationID = 0, 32 do
        local station = safe(function() return route:GetStation(stationID) end)
        local stationValid = explorerValid(station)
        if stationValid == true then
            foundStations = foundStations + 1
            for goodID = 0, 32 do
                local hasGood = safe(function() return station:HasGood(goodID) end)
                if hasGood == true then
                    local good, goodErr = safe(function() return station:GetGood(goodID) end)
                    if good ~= nil then
                        foundGoods = foundGoods + 1
                        local label = "Station[" .. tostring(stationID) .. "].Good[" .. tostring(goodID) .. "]"
                        local loading = safe(function() return good.Loading end)
                        local guid = safe(function() return good.Guid end)
                        local amount = safe(function() return good.Amount end)
                        local data = safe(function() return good.GoodData end)
                        log("MUTABILITY target | object=" .. label
                            .. " | Loading=" .. tostring(loading)
                            .. " | Guid=" .. tostring(guid)
                            .. " | Amount=" .. tostring(amount)
                            .. " | GoodData=" .. tostring(data)
                            .. " | getError=" .. tostring(goodErr or ""))
                        probeAssignment(good, label, "Loading", loading)
                        probeAssignment(good, label, "Guid", guid)
                        probeAssignment(good, label, "Amount", amount)
                        probeAssignment(good, label, "GoodData", data)
                    end
                end
            end
        end
    end
    log("MUTABILITY COMPLETE | validStations=" .. tostring(foundStations)
        .. " | validGoods=" .. tostring(foundGoods)
        .. " | sameValueOnly=true | expectedRouteChange=false")
    return foundGoods > 0
end

function GoodsFinder:IntrospectUIEditRoute()
    return self:ExploreUIEditRouteObjectGraph()
end



local function methodResultSummary(value)
    local valueType = type(value)
    if valueType == "table" then
        local count = 0
        local ok, err = pcall(function()
            for _ in pairs(value) do count = count + 1 end
        end)
        if not ok then return "table(unreadable:" .. tostring(err) .. ")" end
        return "table(count=" .. tostring(count) .. ")"
    end
    return tostring(value)
end

local function probeReadOnlyMethod(object, label, methodName)
    local method, readErr = safe(function() return object and object[methodName] end)
    if type(method) ~= "function" then
        log("METHOD missing | object=" .. label
            .. " | method=" .. methodName
            .. " | type=" .. tostring(type(method))
            .. " | readError=" .. tostring(readErr or ""))
        return 0, 0
    end

    local result, callErr = safe(function() return method(object) end)
    local resultValid, validErr = explorerValid(result)
    log("METHOD call | object=" .. label
        .. " | method=" .. methodName
        .. " | success=" .. tostring(callErr == nil)
        .. " | resultType=" .. tostring(type(result))
        .. " | result=" .. methodResultSummary(result)
        .. " | resultValid=" .. tostring(resultValid)
        .. " | readError=" .. tostring(readErr or "")
        .. " | callError=" .. tostring(callErr or "")
        .. " | validError=" .. tostring(validErr or ""))
    return 1, callErr == nil and 1 or 0
end

local function probeReadOnlyMethods(object, label, names)
    log("METHOD progress | scanning=" .. label .. " | candidates=" .. tostring(#names))
    local callable, succeeded = 0, 0
    for _, methodName in ipairs(names) do
        local c, s = probeReadOnlyMethod(object, label, methodName)
        callable = callable + c
        succeeded = succeeded + s
    end
    log("METHOD object complete | object=" .. label
        .. " | callable=" .. tostring(callable)
        .. " | succeeded=" .. tostring(succeeded))
end

function GoodsFinder:ExploreZeroArgumentMethods()
    log("METHOD START | getter/predicate-only zero-argument probe; no mutators and no legacy diagnostics")

    local route, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local routeValid, validErr = explorerValid(route)
    log("METHOD route root | type=" .. tostring(type(route))
        .. " | valid=" .. tostring(routeValid)
        .. " | routeError=" .. tostring(routeErr or "")
        .. " | validError=" .. tostring(validErr or ""))
    if routeValid ~= true then
        log("METHOD ABORT | remain inside an unsaved route with a ship, two stations, and one configured good")
        return false
    end

    -- Only getters and predicates are called. Functions known or suspected to require
    -- arguments may fail harmlessly inside pcall; no Add/Set/Remove/Commit/Apply/Cancel calls exist here.
    probeReadOnlyMethods(route, "UIEditRoute", {
        "isValid", "GetName", "GetID", "GetId", "GetStationCount", "GetShipCount", "GetGoodCount",
        "GetStations", "GetShips", "GetGoods", "GetRoute", "GetOwner", "GetParticipant",
        "GetLostShipName", "IsErrorActive", "NotEnoughSlotsErrorActive",
        "NotEnoughSlotsForShipsErrorActive", "IslandUnderSiegeActive", "NoValidPierActive",
        "NoTradeRightsActive", "ConfiguredGoodNotTradedActive", "LoadedGoodNeverUnloadedActive",
        "UnloadedGoodNeverLoadedActive", "GoodsDontMatchActive", "StorageFullActive",
        "StorageEmptyActive", "LongWaitingTimeActive", "MismatchingGoodActive",
        "MismatchingGoodActiveForGood"
    })

    local stationMethods = {
        "isValid", "GetID", "GetId", "GetAreaID", "GetAreaId", "GetName", "GetArea",
        "GetOwner", "GetParticipant", "GetGoodCount", "GetGoods", "GetOptions"
    }
    local goodMethods = {
        "isValid", "GetGuid", "GetGUID", "GetAmount", "GetLoading", "IsLoading",
        "GetGoodData", "GetProduct", "GetAsset", "GetName", "GetText", "GetIcon",
        "GetSlot", "GetIndex", "GetID", "GetId"
    }

    local validStations, validGoods = 0, 0
    log("METHOD progress | scanning station IDs 0..32")
    for stationID = 0, 32 do
        local station, stationErr = safe(function() return route:GetStation(stationID) end)
        local stationValid = explorerValid(station)
        if stationValid == true then
            validStations = validStations + 1
            local stationLabel = "Station[" .. tostring(stationID) .. "]"
            log("METHOD station found | object=" .. stationLabel .. " | getError=" .. tostring(stationErr or ""))
            probeReadOnlyMethods(station, stationLabel, stationMethods)

            log("METHOD progress | scanning goods for " .. stationLabel .. " | IDs 0..32")
            for goodID = 0, 32 do
                local hasGood = safe(function() return station:HasGood(goodID) end)
                if hasGood == true then
                    local good, goodErr = safe(function() return station:GetGood(goodID) end)
                    if good ~= nil then
                        validGoods = validGoods + 1
                        local goodLabel = stationLabel .. ".Good[" .. tostring(goodID) .. "]"
                        log("METHOD good found | object=" .. goodLabel .. " | getError=" .. tostring(goodErr or ""))
                        probeReadOnlyMethods(good, goodLabel, goodMethods)
                    end
                end
            end
        end
    end

    probeReadOnlyMethods(TradeRoute, "TradeRouteManager", {
        "isValid", "GetRoutes", "GetRouteCount", "GetActiveRoute", "GetUIEditRoute"
    })

    log("METHOD COMPLETE | validStations=" .. tostring(validStations)
        .. " | validGoods=" .. tostring(validGoods)
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | readOnly=true | legacyDiagnosticsRemoved=true")
    return true
end


local function bindingSafeToString(value)
    local ok, result = pcall(tostring, value)
    if ok then return result end
    return "<tostring error: " .. tostring(result) .. ">"
end

local function bindingSortedKeys(tbl)
    local result = {}
    if type(tbl) ~= "table" then return result end
    local ok, err = pcall(function()
        for key, value in pairs(tbl) do
            result[#result + 1] = {
                key = bindingSafeToString(key),
                keyType = type(key),
                valueType = type(value),
                value = value
            }
        end
    end)
    if not ok then
        log("BINDING table iteration failed | error=" .. tostring(err))
        return result
    end
    table.sort(result, function(a,b) return a.key < b.key end)
    return result
end

local function bindingFunctionMetadata(fn, label)
    log("BINDING function | label=" .. label
        .. " | type=" .. tostring(type(fn))
        .. " | tostring=" .. bindingSafeToString(fn))

    local dbg = rawget(_G, "debug")
    if type(dbg) ~= "table" then
        log("BINDING function debug unavailable | label=" .. label)
        return
    end

    if type(dbg.getinfo) == "function" then
        local info, infoErr = safe(function() return dbg.getinfo(fn, "nSlu") end)
        if type(info) == "table" then
            log("BINDING function info | label=" .. label
                .. " | what=" .. tostring(info.what)
                .. " | name=" .. tostring(info.name)
                .. " | namewhat=" .. tostring(info.namewhat)
                .. " | source=" .. tostring(info.source)
                .. " | short_src=" .. tostring(info.short_src)
                .. " | linedefined=" .. tostring(info.linedefined)
                .. " | lastlinedefined=" .. tostring(info.lastlinedefined)
                .. " | nups=" .. tostring(info.nups)
                .. " | nparams=" .. tostring(info.nparams)
                .. " | isvararg=" .. tostring(info.isvararg)
                .. " | error=" .. tostring(infoErr or ""))
        else
            log("BINDING function info unavailable | label=" .. label .. " | error=" .. tostring(infoErr or ""))
        end
    end

    if type(dbg.getupvalue) == "function" then
        for index = 1, 8 do
            local name, value = dbg.getupvalue(fn, index)
            if name == nil then break end
            log("BINDING function upvalue | label=" .. label
                .. " | index=" .. tostring(index)
                .. " | name=" .. tostring(name)
                .. " | type=" .. tostring(type(value))
                .. " | value=" .. bindingSafeToString(value))
        end
    end
end

local function bindingInspectTable(tbl, label, depth, seen)
    if type(tbl) ~= "table" then return end
    depth = depth or 0
    seen = seen or {}
    if seen[tbl] then
        log("BINDING table cycle | label=" .. label)
        return
    end
    seen[tbl] = true

    local entries = bindingSortedKeys(tbl)
    log("BINDING table | label=" .. label .. " | entries=" .. tostring(#entries) .. " | depth=" .. tostring(depth))
    for _, entry in ipairs(entries) do
        log("BINDING member | object=" .. label
            .. " | key=" .. entry.key
            .. " | keyType=" .. entry.keyType
            .. " | valueType=" .. entry.valueType
            .. " | value=" .. bindingSafeToString(entry.value))
        if entry.valueType == "function" then
            bindingFunctionMetadata(entry.value, label .. "." .. entry.key)
        elseif entry.valueType == "table" and depth < 2 then
            bindingInspectTable(entry.value, label .. "." .. entry.key, depth + 1, seen)
        end
    end
end

local function bindingInspectObject(object, label, candidateNames)
    log("BINDING object start | object=" .. label
        .. " | type=" .. tostring(type(object))
        .. " | tostring=" .. bindingSafeToString(object))

    local mt, mtErr = safe(function() return getmetatable(object) end)
    log("BINDING metatable public | object=" .. label
        .. " | type=" .. tostring(type(mt))
        .. " | value=" .. bindingSafeToString(mt)
        .. " | error=" .. tostring(mtErr or ""))
    if type(mt) == "table" then bindingInspectTable(mt, label .. ".metatable", 0, {}) end

    local dbg = rawget(_G, "debug")
    if type(dbg) == "table" and type(dbg.getmetatable) == "function" then
        local dmt, dmtErr = safe(function() return dbg.getmetatable(object) end)
        log("BINDING metatable debug | object=" .. label
            .. " | type=" .. tostring(type(dmt))
            .. " | value=" .. bindingSafeToString(dmt)
            .. " | error=" .. tostring(dmtErr or ""))
        if type(dmt) == "table" and dmt ~= mt then bindingInspectTable(dmt, label .. ".debugMetatable", 0, {}) end
    end

    for _, name in ipairs(candidateNames or {}) do
        local value, readErr = safe(function() return object[name] end)
        log("BINDING candidate | object=" .. label
            .. " | member=" .. name
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value)
            .. " | readError=" .. tostring(readErr or ""))
        if type(value) == "function" then bindingFunctionMetadata(value, label .. "." .. name) end
    end

    log("BINDING object complete | object=" .. label)
end

function GoodsFinder:ExploreTypeInformation()
    log("TYPEINFO START | reflection-only probe; no route values changed and no mutation methods invoked")

    local route, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local routeValid, validErr = explorerValid(route)
    log("TYPEINFO route root | type=" .. tostring(type(route))
        .. " | valid=" .. tostring(routeValid)
        .. " | routeError=" .. tostring(routeErr or "")
        .. " | validError=" .. tostring(validErr or ""))
    if routeValid ~= true then
        log("TYPEINFO ABORT | remain inside an unsaved route with two stations and one configured good")
        return false
    end

    local typeofFn = rawget(_G, "typeof")
    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    local getTypeInfoDeprecatedFn = rawget(_G, "getTypeInfoDeprecated")
    local filterMetaTablesFn = rawget(_G, "filterMetaTables")
    log("TYPEINFO globals | typeof=" .. tostring(type(typeofFn))
        .. " | getTypeInfo=" .. tostring(type(getTypeInfoFn))
        .. " | getTypeInfoDeprecated=" .. tostring(type(getTypeInfoDeprecatedFn))
        .. " | filterMetaTables=" .. tostring(type(filterMetaTablesFn)))

    local targets, seenObjects = {}, {}
    local function addTarget(label, object)
        if object == nil then return end
        local key = bindingSafeToString(object)
        if seenObjects[key] then return end
        seenObjects[key] = true
        targets[#targets + 1] = {label=label, object=object}
    end

    addTarget("UIEditRoute", route)
    addTarget("TradeRouteManager", TradeRoute)

    local validStations, validGoods = 0, 0
    for stationID = 0, 32 do
        local station = safe(function() return route:GetStation(stationID) end)
        local stationValid = explorerValid(station)
        if stationValid == true then
            validStations = validStations + 1
            addTarget("Station[" .. tostring(stationID) .. "]", station)
            for goodID = 0, 32 do
                local hasGood = safe(function() return station:HasGood(goodID) end)
                if hasGood == true then
                    local good = safe(function() return station:GetGood(goodID) end)
                    if good ~= nil then
                        validGoods = validGoods + 1
                        addTarget("Station[" .. tostring(stationID) .. "].Good[" .. tostring(goodID) .. "]", good)
                    end
                end
            end
        end
    end

    local inspectedResults = {}
    local function inspectResult(label, value)
        log("TYPEINFO result | label=" .. label
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value))
        if type(value) == "table" then
            bindingInspectTable(value, "TYPEINFO." .. label, 0, inspectedResults)
        else
            local mt = safe(function() return getmetatable(value) end)
            if type(mt) == "table" then
                bindingInspectTable(mt, "TYPEINFO." .. label .. ".metatable", 0, inspectedResults)
            end
        end
    end

    local function tryCall(fnLabel, fn, argLabel, arg)
        if type(fn) ~= "function" then
            log("TYPEINFO call skipped | function=" .. fnLabel .. " | reason=unavailable")
            return nil
        end
        local result, err = safe(function() return fn(arg) end)
        log("TYPEINFO call | function=" .. fnLabel
            .. " | argument=" .. argLabel
            .. " | argumentType=" .. tostring(type(arg))
            .. " | argumentValue=" .. bindingSafeToString(arg)
            .. " | success=" .. tostring(err == nil)
            .. " | error=" .. tostring(err or ""))
        if err == nil then inspectResult(fnLabel .. "(" .. argLabel .. ")", result) end
        return result
    end

    local discoveredTypeValues, discoveredTypeNames = {}, {}
    for _, target in ipairs(targets) do
        log("TYPEINFO target start | label=" .. target.label
            .. " | luaType=" .. tostring(type(target.object))
            .. " | value=" .. bindingSafeToString(target.object))

        local typeValue = tryCall("typeof", typeofFn, target.label, target.object)
        if typeValue ~= nil then
            discoveredTypeValues[#discoveredTypeValues + 1] = {label=target.label .. ".typeof", value=typeValue}
            local typeName = bindingSafeToString(typeValue)
            if typeName ~= "" then discoveredTypeNames[typeName] = true end
        end

        tryCall("getTypeInfo", getTypeInfoFn, target.label .. ".object", target.object)
        tryCall("getTypeInfoDeprecated", getTypeInfoDeprecatedFn, target.label .. ".object", target.object)

        local mt = safe(function() return getmetatable(target.object) end)
        if mt ~= nil then
            tryCall("getTypeInfo", getTypeInfoFn, target.label .. ".metatable", mt)
            tryCall("getTypeInfoDeprecated", getTypeInfoDeprecatedFn, target.label .. ".metatable", mt)
        end
        log("TYPEINFO target complete | label=" .. target.label)
    end

    for _, item in ipairs(discoveredTypeValues) do
        tryCall("getTypeInfo", getTypeInfoFn, item.label, item.value)
        tryCall("getTypeInfoDeprecated", getTypeInfoDeprecatedFn, item.label, item.value)
    end

    local canonicalNames = {
        "CSessionTradeRoute", "const CSessionTradeRoute",
        "CSessionTradeRouteStationInfo", "const CSessionTradeRouteStationInfo",
        "CSessionTradeRouteGoodInfo", "const CSessionTradeRouteGoodInfo",
        "CTradeRouteManager", "const CTradeRouteManager",
        "GlobalPropertyMT"
    }
    for _, name in ipairs(canonicalNames) do discoveredTypeNames[name] = true end
    local names = {}
    for name in pairs(discoveredTypeNames) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        tryCall("getTypeInfo", getTypeInfoFn, "typeName:" .. name, name)
        tryCall("getTypeInfoDeprecated", getTypeInfoDeprecatedFn, "typeName:" .. name, name)
    end

    if type(filterMetaTablesFn) == "function" then
        local filterArgs = {"TradeRoute", "SessionTradeRoute", "GoodInfo", "StationInfo"}
        for _, text in ipairs(filterArgs) do
            tryCall("filterMetaTables", filterMetaTablesFn, "filter:" .. text, text)
        end
    end

    log("TYPEINFO COMPLETE | targets=" .. tostring(#targets)
        .. " | validStations=" .. tostring(validStations)
        .. " | validGoods=" .. tostring(validGoods)
        .. " | discoveredTypeValues=" .. tostring(#discoveredTypeValues)
        .. " | testedTypeNames=" .. tostring(#names)
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | reflectionOnly=true")
    return true
end


function GoodsFinder:ExploreControllerBindings()
    log("CONTROLLER START | discovery-only probe; no controller actions invoked and no route values changed")

    local route, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local routeValid, validErr = explorerValid(route)
    log("CONTROLLER route root | type=" .. tostring(type(route))
        .. " | valid=" .. tostring(routeValid)
        .. " | routeError=" .. tostring(routeErr or "")
        .. " | validError=" .. tostring(validErr or ""))
    if routeValid ~= true then
        log("CONTROLLER ABORT | remain inside an unsaved route editor")
        return false
    end

    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    local getTypeInfoDeprecatedFn = rawget(_G, "getTypeInfoDeprecated")
    local filterMetaTablesFn = rawget(_G, "filterMetaTables")
    local dbg = rawget(_G, "debug")

    local patterns = {
        "traderoute", "trade_route", "trade route", "routeeditor", "routecontroller",
        "routescene", "routepopup", "selectgood", "goodpopup", "sessiontraderoute",
        "editor", "controller", "popup", "scene"
    }

    local function relevantText(value)
        local text = string.lower(bindingSafeToString(value))
        for _, pattern in ipairs(patterns) do
            if string.find(text, pattern, 1, true) then return true end
        end
        return false
    end

    local seenValues, inspected = {}, 0
    local maxInspected = 140
    local function inspectCandidate(label, value, source)
        if value == nil or inspected >= maxInspected then return end
        local identity = tostring(type(value)) .. "|" .. bindingSafeToString(value)
        if seenValues[identity] then return end
        seenValues[identity] = true
        inspected = inspected + 1
        log("CONTROLLER candidate | index=" .. tostring(inspected)
            .. " | source=" .. tostring(source or "")
            .. " | label=" .. tostring(label)
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value))

        if type(getTypeInfoFn) == "function" and (type(value) == "table" or type(value) == "userdata") then
            local info, infoErr = safe(function() return getTypeInfoFn(value) end)
            log("CONTROLLER typeinfo | label=" .. tostring(label)
                .. " | success=" .. tostring(infoErr == nil)
                .. " | result=" .. bindingSafeToString(info)
                .. " | error=" .. tostring(infoErr or ""))
        end
        if type(getTypeInfoDeprecatedFn) == "function" and (type(value) == "table" or type(value) == "userdata") then
            local oldInfo, oldErr = safe(function() return getTypeInfoDeprecatedFn(value) end)
            log("CONTROLLER typeinfo deprecated | label=" .. tostring(label)
                .. " | success=" .. tostring(oldErr == nil)
                .. " | result=" .. bindingSafeToString(oldInfo)
                .. " | error=" .. tostring(oldErr or ""))
        end
        local mt = safe(function() return getmetatable(value) end)
        if type(mt) == "table" then
            bindingInspectTable(mt, "CONTROLLER." .. tostring(label) .. ".metatable", 0, {})
        end
    end

    local knownNames = {
        "TradeRoute", "TradeRouteEditor", "TradeRouteController", "TradeRouteScene",
        "TradeRouteSceneController", "CTradeRouteSceneController", "TradeRoutePopup",
        "TradeRouteSelectGoodPopup", "SessionTradeRoutesEditor", "SessionTradeRoutesScene",
        "SessionTradeRouteEditor", "SelectGoodPopup", "GoodPopup", "UI", "GUI",
        "InfoTip", "Input", "Automation", "Game", "Session"
    }
    for _, name in ipairs(knownNames) do
        local value, err = safe(function() return _G[name] end)
        log("CONTROLLER known global | name=" .. name
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value)
            .. " | error=" .. tostring(err or ""))
        if value ~= nil then inspectCandidate("_G." .. name, value, "known-global") end
    end

    local visitedTables, scannedEntries = {}, 0
    local maxScannedEntries = 8000
    local function scanTable(tbl, path, depth)
        if type(tbl) ~= "table" or visitedTables[tbl] or depth > 3 or scannedEntries >= maxScannedEntries then return end
        visitedTables[tbl] = true
        local ok, iterErr = pcall(function()
            for key, value in pairs(tbl) do
                scannedEntries = scannedEntries + 1
                if scannedEntries > maxScannedEntries then break end
                local keyText = bindingSafeToString(key)
                local valueText = bindingSafeToString(value)
                local childPath = path .. "." .. keyText
                if relevantText(keyText) or relevantText(valueText) then
                    inspectCandidate(childPath, value, "table-scan")
                end
                if depth < 3 and type(value) == "table" then
                    local descend = relevantText(keyText) or path == "_G"
                        or string.find(string.lower(keyText), "ui", 1, true)
                        or string.find(string.lower(keyText), "game", 1, true)
                        or string.find(string.lower(keyText), "session", 1, true)
                    if descend then scanTable(value, childPath, depth + 1) end
                end
            end
        end)
        if not ok then log("CONTROLLER table scan error | path=" .. path .. " | error=" .. tostring(iterErr)) end
    end
    scanTable(_G, "_G", 0)

    if type(dbg) == "table" and type(dbg.getregistry) == "function" then
        local registry, registryErr = safe(function() return dbg.getregistry() end)
        log("CONTROLLER registry | type=" .. tostring(type(registry))
            .. " | value=" .. bindingSafeToString(registry)
            .. " | error=" .. tostring(registryErr or ""))
        if type(registry) == "table" then scanTable(registry, "debug.registry", 0) end
    end

    local filterCallbackCount, filterMatches = 0, 0
    if type(filterMetaTablesFn) == "function" then
        local function predicate(a, b)
            filterCallbackCount = filterCallbackCount + 1
            local match = relevantText(a) or relevantText(b)
            if match then
                filterMatches = filterMatches + 1
                if filterMatches <= 80 then
                    log("CONTROLLER filter match | callback=" .. tostring(filterCallbackCount)
                        .. " | aType=" .. tostring(type(a)) .. " | a=" .. bindingSafeToString(a)
                        .. " | bType=" .. tostring(type(b)) .. " | b=" .. bindingSafeToString(b))
                    if type(a) == "table" or type(a) == "userdata" then inspectCandidate("filter.a[" .. tostring(filterCallbackCount) .. "]", a, "filterMetaTables") end
                    if type(b) == "table" or type(b) == "userdata" then inspectCandidate("filter.b[" .. tostring(filterCallbackCount) .. "]", b, "filterMetaTables") end
                end
            end
            return match
        end
        local result, filterErr = safe(function() return filterMetaTablesFn(predicate) end)
        log("CONTROLLER filterMetaTables function | success=" .. tostring(filterErr == nil)
            .. " | resultType=" .. tostring(type(result))
            .. " | result=" .. bindingSafeToString(result)
            .. " | callbacks=" .. tostring(filterCallbackCount)
            .. " | matches=" .. tostring(filterMatches)
            .. " | error=" .. tostring(filterErr or ""))
        if type(result) == "table" then bindingInspectTable(result, "CONTROLLER.filterMetaTables.result", 0, {}) end
    end

    log("CONTROLLER COMPLETE | inspectedCandidates=" .. tostring(inspected)
        .. " | scannedEntries=" .. tostring(scannedEntries)
        .. " | filterCallbacks=" .. tostring(filterCallbackCount)
        .. " | filterMatches=" .. tostring(filterMatches)
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | discoveryOnly=true")
    return true
end


function GoodsFinder:CompareGetRouteAndUIEditRoute()
    log("GETROUTE START | read-only comparison of TradeRoute:GetRoute results and TradeRoute.UIEditRoute")

    local manager = rawget(_G, "TradeRoute")
    local uiRoute, uiRouteErr = safe(function() return manager and manager.UIEditRoute end)
    local uiValid, uiValidErr = explorerValid(uiRoute)
    log("GETROUTE manager | type=" .. tostring(type(manager))
        .. " | value=" .. bindingSafeToString(manager))
    log("GETROUTE UIEditRoute | type=" .. tostring(type(uiRoute))
        .. " | value=" .. bindingSafeToString(uiRoute)
        .. " | valid=" .. tostring(uiValid)
        .. " | error=" .. tostring(uiRouteErr or uiValidErr or ""))

    if type(manager) ~= "table" or type(manager.GetRoute) ~= "function" then
        log("GETROUTE ABORT | TradeRoute.GetRoute unavailable")
        return false
    end

    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    local getTypeInfoDeprecatedFn = rawget(_G, "getTypeInfoDeprecated")

    local function inspectRoute(label, value, callErr)
        local valid, validErr = explorerValid(value)
        local name, nameErr = safe(function() return value and value.Name end)
        local activeErrors, activeErr = safe(function() return value and value.ActiveErrorCount end)
        local noGoods, noGoodsErr = safe(function() return value and value.NoGoodsActive end)
        local noShips, noShipsErr = safe(function() return value and value.NoShipsActive end)
        local noStations, noStationsErr = safe(function() return value and value.NotEnoughStationsActive end)
        log("GETROUTE object | label=" .. tostring(label)
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value)
            .. " | valid=" .. tostring(valid)
            .. " | name=" .. tostring(name)
            .. " | activeErrors=" .. tostring(activeErrors)
            .. " | noGoods=" .. tostring(noGoods)
            .. " | noShips=" .. tostring(noShips)
            .. " | notEnoughStations=" .. tostring(noStations)
            .. " | callError=" .. tostring(callErr or "")
            .. " | readErrors=" .. table.concat({tostring(validErr or ""), tostring(nameErr or ""), tostring(activeErr or ""), tostring(noGoodsErr or ""), tostring(noShipsErr or ""), tostring(noStationsErr or "")}, " || "))

        if value ~= nil and type(getTypeInfoFn) == "function" then
            local info, err = safe(function() return getTypeInfoFn(value) end)
            log("GETROUTE typeinfo | label=" .. tostring(label)
                .. " | success=" .. tostring(err == nil)
                .. " | result=" .. bindingSafeToString(info)
                .. " | error=" .. tostring(err or ""))
        end
        if value ~= nil and type(getTypeInfoDeprecatedFn) == "function" then
            local info, err = safe(function() return getTypeInfoDeprecatedFn(value) end)
            log("GETROUTE typeinfo deprecated | label=" .. tostring(label)
                .. " | success=" .. tostring(err == nil)
                .. " | result=" .. bindingSafeToString(info)
                .. " | error=" .. tostring(err or ""))
        end
        local mt = safe(function() return value and getmetatable(value) end)
        if type(mt) == "table" then
            bindingInspectTable(mt, "GETROUTE." .. tostring(label) .. ".metatable", 0, {})
        end
        return valid == true
    end

    inspectRoute("UIEditRoute", uiRoute, uiRouteErr)

    local callForms = {
        {label="GetRoute()", fn=function() return manager:GetRoute() end},
        {label="GetRoute(0)", fn=function() return manager:GetRoute(0) end},
        {label="GetRoute(-1)", fn=function() return manager:GetRoute(-1) end},
        {label="GetRoute(UIEditRoute)", fn=function() return manager:GetRoute(uiRoute) end},
    }
    for _, form in ipairs(callForms) do
        local value, err = safe(form.fn)
        inspectRoute(form.label, value, err)
    end

    local firstValidId, validCount = nil, 0
    local uiString = bindingSafeToString(uiRoute)
    for routeId = 1, 4096 do
        local value, err = safe(function() return manager:GetRoute(routeId) end)
        local valid = safe(function() return value and value:isValid() end)
        if valid == true then
            validCount = validCount + 1
            if firstValidId == nil then firstValidId = routeId end
            local valueString = bindingSafeToString(value)
            local sameLua = (value == uiRoute)
            local sameString = (valueString == uiString)
            local name = safe(function() return value.Name end)
            log("GETROUTE valid route | index=" .. tostring(validCount)
                .. " | routeID=" .. tostring(routeId)
                .. " | value=" .. valueString
                .. " | name=" .. tostring(name or "")
                .. " | sameLuaObjectAsUIEditRoute=" .. tostring(sameLua)
                .. " | sameStringAsUIEditRoute=" .. tostring(sameString)
                .. " | error=" .. tostring(err or ""))
            if validCount <= 3 or sameLua or sameString then
                inspectRoute("GetRoute(" .. tostring(routeId) .. ")", value, err)
            end
            if validCount >= 25 then break end
        end
    end

    if firstValidId ~= nil then
        local routeA, errA = safe(function() return manager:GetRoute(firstValidId) end)
        local routeB, errB = safe(function() return manager:GetRoute(firstValidId) end)
        log("GETROUTE repeat identity | routeID=" .. tostring(firstValidId)
            .. " | a=" .. bindingSafeToString(routeA)
            .. " | b=" .. bindingSafeToString(routeB)
            .. " | luaEqual=" .. tostring(routeA == routeB)
            .. " | stringEqual=" .. tostring(bindingSafeToString(routeA) == bindingSafeToString(routeB))
            .. " | errorA=" .. tostring(errA or "")
            .. " | errorB=" .. tostring(errB or ""))
    end

    log("GETROUTE COMPLETE | validExistingRoutes=" .. tostring(validCount)
        .. " | firstValidID=" .. tostring(firstValidId)
        .. " | UIEditRouteValid=" .. tostring(uiValid)
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | readOnly=true")
    return true
end


function GoodsFinder:ExploreHaloTradeRouteBindings()
    log("HALOTRADE START | read-only targeted scan of halo bindings and metatables")

    local haloRoot = rawget(_G, "halo")
    local getInfo = rawget(_G, "getTypeInfo")
    local getInfoOld = rawget(_G, "getTypeInfoDeprecated")
    local filterFn = rawget(_G, "filterMetaTables")

    log("HALOTRADE globals | halo=" .. tostring(type(haloRoot))
        .. " | getTypeInfo=" .. tostring(type(getInfo))
        .. " | getTypeInfoDeprecated=" .. tostring(type(getInfoOld))
        .. " | filterMetaTables=" .. tostring(type(filterFn)))

    if type(haloRoot) ~= "table" then
        log("HALOTRADE ABORT | _G.halo is unavailable")
        return false
    end

    local patterns = {
        "trade", "route", "good", "product", "cargo", "load", "unload",
        "warehouse", "kontor", "harbor", "harbour", "popup", "scene",
        "station", "island", "map"
    }

    local function relevant(name)
        local s = string.lower(tostring(name or ""))
        for _, p in ipairs(patterns) do
            if string.find(s, p, 1, true) then return true end
        end
        return false
    end

    local matches = {}
    for key, value in pairs(haloRoot) do
        if relevant(key) then
            matches[#matches + 1] = { key=tostring(key), value=value }
        end
    end
    table.sort(matches, function(a,b) return a.key < b.key end)

    log("HALOTRADE halo matches | count=" .. tostring(#matches))

    local limit = math.min(#matches, 300)
    for i = 1, limit do
        local item = matches[i]
        local value = item.value
        log("HALOTRADE candidate | index=" .. tostring(i)
            .. " | key=" .. item.key
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value))

        if type(getInfoOld) == "function" then
            local info, err = safe(function() return getInfoOld(value) end)
            log("HALOTRADE typeinfo deprecated | key=" .. item.key
                .. " | success=" .. tostring(err == nil)
                .. " | result=" .. bindingSafeToString(info)
                .. " | error=" .. tostring(err or ""))
        end

        if type(getInfo) == "function" then
            local info, err = safe(function() return getInfo(value) end)
            log("HALOTRADE typeinfo | key=" .. item.key
                .. " | success=" .. tostring(err == nil)
                .. " | result=" .. bindingSafeToString(info)
                .. " | error=" .. tostring(err or ""))
        end
    end

    if type(filterFn) == "function" then
        local callbackCount = 0
        local callbackMatches = 0
        local function callback(name, mt)
            callbackCount = callbackCount + 1
            if relevant(name) then
                callbackMatches = callbackMatches + 1
                log("HALOTRADE filtered metatable | index=" .. tostring(callbackMatches)
                    .. " | name=" .. tostring(name)
                    .. " | type=" .. tostring(type(mt))
                    .. " | value=" .. bindingSafeToString(mt))
                if type(getInfoOld) == "function" then
                    local info, err = safe(function() return getInfoOld(mt) end)
                    log("HALOTRADE filtered typeinfo | name=" .. tostring(name)
                        .. " | success=" .. tostring(err == nil)
                        .. " | result=" .. bindingSafeToString(info)
                        .. " | error=" .. tostring(err or ""))
                end
            end
            return false
        end
        local result, err = safe(function() return filterFn(callback) end)
        log("HALOTRADE filter complete | callbacks=" .. tostring(callbackCount)
            .. " | matches=" .. tostring(callbackMatches)
            .. " | result=" .. bindingSafeToString(result)
            .. " | error=" .. tostring(err or ""))
    end

    log("HALOTRADE COMPLETE | haloMatches=" .. tostring(#matches)
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | readOnly=true")
    return true
end


function GoodsFinder:ExploreTargetedTradeRouteUIBindings()
    if self.targetedTradeRouteProbeRunning == true then
        log("TARGETROUTE IGNORED | probe already running")
        return false
    end
    self.targetedTradeRouteProbeRunning = true

    local function finish(result)
        self.targetedTradeRouteProbeRunning = false
        return result
    end

    log("TARGETROUTE START | exact read-only scan of TradeRoute and goods-selection UI bindings")

    local haloRoot = rawget(_G, "halo")
    local getInfo = rawget(_G, "getTypeInfo")
    local getInfoOld = rawget(_G, "getTypeInfoDeprecated")
    local filterFn = rawget(_G, "filterMetaTables")

    log("TARGETROUTE globals | halo=" .. tostring(type(haloRoot))
        .. " | getTypeInfo=" .. tostring(type(getInfo))
        .. " | getTypeInfoDeprecated=" .. tostring(type(getInfoOld))
        .. " | filterMetaTables=" .. tostring(type(filterFn)))

    if type(haloRoot) ~= "table" then
        log("TARGETROUTE ABORT | _G.halo is unavailable")
        return finish(false)
    end

    local exactPatterns = {
        "traderoute",
        "trade_route",
        "trade route",
        "selectgood",
        "selectgoods",
        "goodselection",
        "goodsselection",
        "loadgood",
        "unloadgood",
        "goodpopup",
        "goodspopup",
        "routegood",
        "routegoods",
        "routestation",
        "routeisland",
        "routepopup",
        "routescene",
        "routeeditor",
        "routeentry",
        "routepanel"
    }

    local secondaryPatterns = {
        "goodgrid",
        "goodsgrid",
        "goodlist",
        "goodslist",
        "productgrid",
        "productlist",
        "focusedindex",
        "selectedgood",
        "selectedproduct"
    }

    local function containsAny(name, patterns)
        local s = string.lower(tostring(name or ""))
        for _, p in ipairs(patterns) do
            if string.find(s, p, 1, true) then
                return true
            end
        end
        return false
    end

    local matches = {}
    for key, value in pairs(haloRoot) do
        local primary = containsAny(key, exactPatterns)
        local secondary = containsAny(key, secondaryPatterns)
        if primary or secondary then
            matches[#matches + 1] = {
                key = tostring(key),
                value = value,
                priority = primary and 1 or 2
            }
        end
    end
    table.sort(matches, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.key < b.key
    end)

    log("TARGETROUTE halo matches | count=" .. tostring(#matches))

    for i, item in ipairs(matches) do
        local value = item.value
        log("TARGETROUTE candidate | index=" .. tostring(i)
            .. " | priority=" .. tostring(item.priority)
            .. " | key=" .. item.key
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value))

        if type(getInfoOld) == "function" then
            local info, err = safe(function() return getInfoOld(value) end)
            log("TARGETROUTE typeinfo deprecated | key=" .. item.key
                .. " | success=" .. tostring(err == nil)
                .. " | result=" .. bindingSafeToString(info)
                .. " | error=" .. tostring(err or ""))
        end

        if type(getInfo) == "function" then
            local info, err = safe(function() return getInfo(value) end)
            log("TARGETROUTE typeinfo | key=" .. item.key
                .. " | success=" .. tostring(err == nil)
                .. " | result=" .. bindingSafeToString(info)
                .. " | error=" .. tostring(err or ""))
        end
    end

    local route, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local routeValid, routeValidErr = safe(function() return route and route:isValid() end)
    log("TARGETROUTE route context | type=" .. tostring(type(route))
        .. " | value=" .. bindingSafeToString(route)
        .. " | valid=" .. tostring(routeValid)
        .. " | error=" .. tostring(routeErr or routeValidErr or ""))

    if routeValid == true then
        for stationId = 0, 15 do
            local station = safe(function() return route:GetStation(stationId) end)
            local stationValid = safe(function() return station and station:isValid() end)
            if stationValid == true then
                log("TARGETROUTE station | stationID=" .. tostring(stationId)
                    .. " | type=" .. tostring(type(station))
                    .. " | value=" .. bindingSafeToString(station))
                for goodId = 0, 15 do
                    local has = safe(function() return station:HasGood(goodId) end)
                    local good = safe(function() return station:GetGood(goodId) end)
                    local guid = safe(function() return good and good.Guid end)
                    local amount = safe(function() return good and good.Amount end)
                    local loading = safe(function() return good and good.Loading end)
                    if has == true or (tonumber(guid) or 0) ~= 0 then
                        log("TARGETROUTE configured good | stationID=" .. tostring(stationId)
                            .. " | goodID=" .. tostring(goodId)
                            .. " | hasGood=" .. tostring(has)
                            .. " | guid=" .. tostring(guid)
                            .. " | amount=" .. tostring(amount)
                            .. " | loading=" .. tostring(loading)
                            .. " | matchesRemembered=" .. tostring(tonumber(guid) == tonumber(self.lastProductGuid)))
                    end
                end
            end
        end
    end

    if type(filterFn) == "function" then
        local callbackCount = 0
        local callbackMatches = 0
        local function callback(name, mt)
            callbackCount = callbackCount + 1
            if containsAny(name, exactPatterns) or containsAny(name, secondaryPatterns) then
                callbackMatches = callbackMatches + 1
                log("TARGETROUTE filtered metatable | index=" .. tostring(callbackMatches)
                    .. " | name=" .. tostring(name)
                    .. " | type=" .. tostring(type(mt))
                    .. " | value=" .. bindingSafeToString(mt))
                if type(getInfoOld) == "function" then
                    local info, err = safe(function() return getInfoOld(mt) end)
                    log("TARGETROUTE filtered typeinfo deprecated | name=" .. tostring(name)
                        .. " | success=" .. tostring(err == nil)
                        .. " | result=" .. bindingSafeToString(info)
                        .. " | error=" .. tostring(err or ""))
                end
                if type(getInfo) == "function" then
                    local info, err = safe(function() return getInfo(mt) end)
                    log("TARGETROUTE filtered typeinfo | name=" .. tostring(name)
                        .. " | success=" .. tostring(err == nil)
                        .. " | result=" .. bindingSafeToString(info)
                        .. " | error=" .. tostring(err or ""))
                end
            end
            return false
        end

        local result, err = safe(function() return filterFn(callback) end)
        log("TARGETROUTE filter complete | callbacks=" .. tostring(callbackCount)
            .. " | matches=" .. tostring(callbackMatches)
            .. " | result=" .. bindingSafeToString(result)
            .. " | error=" .. tostring(err or ""))
    end

    log("TARGETROUTE COMPLETE | haloMatches=" .. tostring(#matches)
        .. " | UIEditRouteValid=" .. tostring(routeValid)
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | readOnly=true")

    return finish(true)
end


function GoodsFinder:ProbeLiveTradeRoutePopup()
    if self.liveSceneProbeRunning == true then
        log("LIVESCENE IGNORED | probe already running")
        return false
    end
    if self.liveSceneProbeSucceeded == true then
        log("LIVESCENE IGNORED | a successful live popup capture already exists in this game session")
        return true
    end

    self.liveSceneProbeRunning = true

    local function finish(result, succeeded)
        self.liveSceneProbeRunning = false
        if succeeded == true then
            self.liveSceneProbeSucceeded = true
        end
        return result
    end

    log("LIVESCENE START | read-only discovery of the active Trade Route scene and open goods popup")

    local expectedGuid = tonumber(self.lastProductGuid) or 0
    local hoverGuid, hoverErr = safe(function() return InfoTip and InfoTip.RefGuid end)
    log("LIVESCENE context | rememberedProductGUID=" .. tostring(expectedGuid)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | currentInfoTipRefGuid=" .. tostring(hoverGuid)
        .. " | hoverMatchesRemembered=" .. tostring(tonumber(hoverGuid) == expectedGuid)
        .. " | hoverError=" .. tostring(hoverErr or ""))

    local route, routeErr = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local routeValid, routeValidErr = safe(function() return route and route:isValid() end)
    log("LIVESCENE route context | type=" .. tostring(type(route))
        .. " | value=" .. bindingSafeToString(route)
        .. " | valid=" .. tostring(routeValid)
        .. " | error=" .. tostring(routeErr or routeValidErr or ""))

    if routeValid ~= true then
        log("LIVESCENE ABORT | no valid temporary route editor; keep the new route open")
        return finish(false, false)
    end

    local getInfoOld = rawget(_G, "getTypeInfoDeprecated")
    local dbg = rawget(_G, "debug")

    local targetTypeNames = {
        "TradeRouteSceneObject",
        "TradeRouteGoodSelectionData",
        "TradeRouteGoodPopupData",
        "TradeRouteGoodAbsoluteData",
        "TradeRouteAvailableGoodData"
    }

    local stats = {
        scanned = 0,
        managerCandidates = 0,
        targetObjects = 0,
        sceneObjects = 0,
        selectionObjects = 0,
        popupObjects = 0,
        absoluteObjects = 0,
        arrays = 0,
        goods = 0,
        rememberedMatches = 0
    }

    local function lower(value)
        return string.lower(tostring(value or ""))
    end

    local function contains(value, needle)
        return string.find(lower(value), lower(needle), 1, true) ~= nil
    end

    local function readProperty(object, name)
        return safe(function() return object and object[name] end)
    end

    local probed = {}
    local probeArray
    local probeAbsolute
    local probePopup
    local probeSelection
    local probeScene

    local function probeAvailableGood(item, label)
        if item == nil then return end
        local itemType = type(item)
        if itemType ~= "table" and itemType ~= "userdata" then return end

        local guid = readProperty(item, "ProductGuid")
        if type(guid) ~= "number" or guid <= 0 then return end

        local index = readProperty(item, "Index")
        local amount = readProperty(item, "Amount")
        local hovered = readProperty(item, "IsHovered")
        local selected = readProperty(item, "IsSelected")
        local imageId = readProperty(item, "ImageID")
        local primaryEvent = readProperty(item, "PrimaryButtonPressed")
        local matches = guid == expectedGuid

        stats.goods = stats.goods + 1
        if matches then stats.rememberedMatches = stats.rememberedMatches + 1 end

        log("LIVESCENE GOOD | label=" .. tostring(label)
            .. " | productGUID=" .. tostring(guid)
            .. " | index=" .. tostring(index)
            .. " | amount=" .. tostring(amount)
            .. " | isHovered=" .. tostring(hovered)
            .. " | isSelected=" .. tostring(selected)
            .. " | imageID=" .. tostring(imageId)
            .. " | primaryEventType=" .. tostring(type(primaryEvent))
            .. " | matchesRemembered=" .. tostring(matches))

        if matches then
            log("LIVESCENE HEMP MATCH | label=" .. tostring(label)
                .. " | productGUID=" .. tostring(guid)
                .. " | index=" .. tostring(index)
                .. " | isHovered=" .. tostring(hovered)
                .. " | isSelected=" .. tostring(selected)
                .. " | PrimaryButtonPressedAvailable=" .. tostring(type(primaryEvent) == "function"))
        end
    end

    probeArray = function(array, label)
        if array == nil then return end
        local arrayType = type(array)
        if arrayType ~= "table" and arrayType ~= "userdata" then return end
        if probed[array] then return end
        probed[array] = true
        stats.arrays = stats.arrays + 1

        local size, sizeErr = safe(function() return array:GetSize() end)
        log("LIVESCENE ARRAY | label=" .. tostring(label)
            .. " | type=" .. tostring(arrayType)
            .. " | value=" .. bindingSafeToString(array)
            .. " | size=" .. tostring(size)
            .. " | sizeError=" .. tostring(sizeErr or ""))

        local seenItems = {}
        local function inspectItem(item, itemLabel)
            if item == nil then return end
            local itemType = type(item)
            if itemType ~= "table" and itemType ~= "userdata" then return end
            if seenItems[item] then return end
            seenItems[item] = true
            probeAvailableGood(item, itemLabel)
        end

        if type(size) == "number" and size >= 0 then
            local limit = math.min(size, 512)
            for i = 0, limit - 1 do
                local item = safe(function() return array:GetElement(i) end)
                inspectItem(item, tostring(label) .. ".GetElement[" .. tostring(i) .. "]")
            end
            for i = 1, limit do
                local item = safe(function() return array:GetElement(i) end)
                inspectItem(item, tostring(label) .. ".GetElement1[" .. tostring(i) .. "]")
            end
        end

        if arrayType == "table" then
            local count = 0
            local ok, iterErr = pcall(function()
                for key, item in pairs(array) do
                    count = count + 1
                    if count > 1024 then break end
                    inspectItem(item, tostring(label) .. ".pairs[" .. bindingSafeToString(key) .. "]")
                end
            end)
            if not ok then
                log("LIVESCENE ARRAY iteration error | label=" .. tostring(label)
                    .. " | error=" .. tostring(iterErr))
            end
        end

        local nested = readProperty(array, "ArrayData")
        if nested ~= nil and nested ~= array then
            probeArray(nested, tostring(label) .. ".ArrayData")
        end
    end

    probeAbsolute = function(object, label)
        if object == nil then return end
        local objectType = type(object)
        if objectType ~= "table" and objectType ~= "userdata" then return end
        if probed[object] then return end
        probed[object] = true
        stats.absoluteObjects = stats.absoluteObjects + 1

        local focusedIndex = readProperty(object, "FocusedIndex")
        local available = readProperty(object, "AvailableGoodData")
        local filterData = readProperty(object, "GoodsFilterData")

        log("LIVESCENE ABSOLUTE | label=" .. tostring(label)
            .. " | type=" .. tostring(objectType)
            .. " | value=" .. bindingSafeToString(object)
            .. " | focusedIndex=" .. tostring(focusedIndex)
            .. " | availableType=" .. tostring(type(available))
            .. " | availableValue=" .. bindingSafeToString(available)
            .. " | filterType=" .. tostring(type(filterData))
            .. " | filterValue=" .. bindingSafeToString(filterData))

        probeArray(available, tostring(label) .. ".AvailableGoodData")
    end

    probePopup = function(object, label)
        if object == nil then return end
        local objectType = type(object)
        if objectType ~= "table" and objectType ~= "userdata" then return end
        if probed[object] then return end
        probed[object] = true
        stats.popupObjects = stats.popupObjects + 1

        local isVisible = readProperty(object, "IsVisible")
        local focusedIndex = readProperty(object, "FocusedIndex")
        local storageData = readProperty(object, "StorageData")
        local filterGoodsData = readProperty(object, "FilterGoodsData")
        local regionTabsData = readProperty(object, "RegionTabsData")

        log("LIVESCENE POPUP | label=" .. tostring(label)
            .. " | type=" .. tostring(objectType)
            .. " | value=" .. bindingSafeToString(object)
            .. " | isVisible=" .. tostring(isVisible)
            .. " | focusedIndex=" .. tostring(focusedIndex)
            .. " | storageType=" .. tostring(type(storageData))
            .. " | storageValue=" .. bindingSafeToString(storageData)
            .. " | filterGoodsType=" .. tostring(type(filterGoodsData))
            .. " | filterGoodsValue=" .. bindingSafeToString(filterGoodsData)
            .. " | regionTabsType=" .. tostring(type(regionTabsData)))

        probeAbsolute(storageData, tostring(label) .. ".StorageData")
        probeAbsolute(filterGoodsData, tostring(label) .. ".FilterGoodsData")
        probeArray(storageData, tostring(label) .. ".StorageDataArray")
        probeArray(filterGoodsData, tostring(label) .. ".FilterGoodsDataArray")
    end

    probeSelection = function(object, label)
        if object == nil then return end
        local objectType = type(object)
        if objectType ~= "table" and objectType ~= "userdata" then return end
        if probed[object] then return end
        probed[object] = true
        stats.selectionObjects = stats.selectionObjects + 1

        local isPanelVisible = readProperty(object, "IsPanelVisible")
        local focusIndex = readProperty(object, "GoodsIslandFocusIndex")
        local hoveredIndex = readProperty(object, "GoodsIslandHoveredIndex")
        local popupData = readProperty(object, "PopupData")
        local goodData = readProperty(object, "TradeRouteGoodData")
        local requestStationFocus = readProperty(object, "RequestStationFocus")

        log("LIVESCENE SELECTION | label=" .. tostring(label)
            .. " | type=" .. tostring(objectType)
            .. " | value=" .. bindingSafeToString(object)
            .. " | isPanelVisible=" .. tostring(isPanelVisible)
            .. " | goodsIslandFocusIndex=" .. tostring(focusIndex)
            .. " | goodsIslandHoveredIndex=" .. tostring(hoveredIndex)
            .. " | popupType=" .. tostring(type(popupData))
            .. " | popupValue=" .. bindingSafeToString(popupData)
            .. " | tradeRouteGoodDataType=" .. tostring(type(goodData))
            .. " | requestStationFocusType=" .. tostring(type(requestStationFocus)))

        probePopup(popupData, tostring(label) .. ".PopupData")
    end

    probeScene = function(object, label)
        if object == nil then return end
        local objectType = type(object)
        if objectType ~= "table" and objectType ~= "userdata" then return end
        if probed[object] then return end
        probed[object] = true
        stats.sceneObjects = stats.sceneObjects + 1

        local selection = readProperty(object, "TradeGoodSelection")
        local overview = readProperty(object, "TradeOverview")
        local shipSelect = readProperty(object, "TradeShipSelect")
        local requestFocus = readProperty(object, "RequestFocus")

        log("LIVESCENE SCENE | label=" .. tostring(label)
            .. " | type=" .. tostring(objectType)
            .. " | value=" .. bindingSafeToString(object)
            .. " | tradeGoodSelectionType=" .. tostring(type(selection))
            .. " | tradeGoodSelectionValue=" .. bindingSafeToString(selection)
            .. " | tradeOverviewType=" .. tostring(type(overview))
            .. " | tradeShipSelectType=" .. tostring(type(shipSelect))
            .. " | requestFocusType=" .. tostring(type(requestFocus)))

        probeSelection(selection, tostring(label) .. ".TradeGoodSelection")
    end

    local function probeByType(object, label, infoText)
        local text = tostring(infoText or "")
        if contains(text, "TradeRouteSceneObject") then
            stats.targetObjects = stats.targetObjects + 1
            probeScene(object, label)
        elseif contains(text, "TradeRouteGoodSelectionData") then
            stats.targetObjects = stats.targetObjects + 1
            probeSelection(object, label)
        elseif contains(text, "TradeRouteGoodPopupData") then
            stats.targetObjects = stats.targetObjects + 1
            probePopup(object, label)
        elseif contains(text, "TradeRouteGoodAbsoluteData") then
            stats.targetObjects = stats.targetObjects + 1
            probeAbsolute(object, label)
        elseif contains(text, "TradeRouteAvailableGoodData") then
            stats.targetObjects = stats.targetObjects + 1
            probeAvailableGood(object, label)
        end
    end

    local seen = {}
    local queue = {}
    local queueHead = 1
    local maxNodes = 20000
    local maxDepth = 5

    local function enqueue(value, label, depth)
        local valueType = type(value)
        if valueType ~= "table" and valueType ~= "userdata" then return end
        if seen[value] then return end
        seen[value] = true
        queue[#queue + 1] = {
            value = value,
            label = tostring(label),
            depth = tonumber(depth) or 0
        }
    end

    local globalCount = 0
    local globalOk, globalErr = pcall(function()
        for key, value in pairs(_G) do
            globalCount = globalCount + 1
            local keyText = bindingSafeToString(key)
            if keyText ~= "_G" and keyText ~= "halo" and keyText ~= "package" then
                enqueue(value, "_G." .. keyText, 0)
            end
        end
    end)
    log("LIVESCENE global roots | count=" .. tostring(globalCount)
        .. " | success=" .. tostring(globalOk)
        .. " | error=" .. tostring(globalErr or ""))

    if type(dbg) == "table" and type(dbg.getregistry) == "function" then
        local registry, registryErr = safe(function() return dbg.getregistry() end)
        log("LIVESCENE registry root | type=" .. tostring(type(registry))
            .. " | value=" .. bindingSafeToString(registry)
            .. " | error=" .. tostring(registryErr or ""))
        if type(registry) == "table" then
            local registryCount = 0
            local registryOk, registryIterErr = pcall(function()
                for key, value in pairs(registry) do
                    registryCount = registryCount + 1
                    if registryCount > 20000 then break end
                    enqueue(value, "debug.registry[" .. bindingSafeToString(key) .. "]", 0)
                end
            end)
            log("LIVESCENE registry entries | count=" .. tostring(registryCount)
                .. " | success=" .. tostring(registryOk)
                .. " | error=" .. tostring(registryIterErr or ""))
        end
    end

    local managerPropertyNames = {
        "CurrentScene", "CurrentSceneObject", "ActiveScene", "ActiveSceneObject",
        "Scene", "SceneObject", "SceneData", "TradeRouteScene", "TradeRouteSceneObject",
        "StateController", "SceneController", "UIState", "Scenes"
    }

    local managerGetterNames = {
        "GetCurrentScene", "GetCurrentSceneObject", "GetActiveScene",
        "GetActiveSceneObject", "GetSceneObject", "GetSceneData"
    }

    while queueHead <= #queue and stats.scanned < maxNodes do
        local node = queue[queueHead]
        queueHead = queueHead + 1
        stats.scanned = stats.scanned + 1

        local value = node.value
        local valueType = type(value)
        local infoText = ""
        if type(getInfoOld) == "function" then
            local info = safe(function() return getInfoOld(value) end)
            infoText = tostring(info or "")
        end

        local isTarget = false
        for _, targetName in ipairs(targetTypeNames) do
            if contains(infoText, targetName) then
                isTarget = true
                break
            end
        end

        if isTarget then
            log("LIVESCENE TARGET | label=" .. tostring(node.label)
                .. " | depth=" .. tostring(node.depth)
                .. " | type=" .. tostring(valueType)
                .. " | value=" .. bindingSafeToString(value)
                .. " | typeInfo=" .. tostring(infoText))
            probeByType(value, node.label, infoText)
        end

        local infoLower = lower(infoText)
        local managerLike =
            (string.find(infoLower, "scene", 1, true) ~= nil
                or string.find(infoLower, "ui", 1, true) ~= nil
                or string.find(infoLower, "gui", 1, true) ~= nil)
            and (string.find(infoLower, "manager", 1, true) ~= nil
                or string.find(infoLower, "controller", 1, true) ~= nil
                or string.find(infoLower, "state", 1, true) ~= nil)

        if managerLike then
            stats.managerCandidates = stats.managerCandidates + 1
            if stats.managerCandidates <= 120 then
                log("LIVESCENE MANAGER | label=" .. tostring(node.label)
                    .. " | type=" .. tostring(valueType)
                    .. " | value=" .. bindingSafeToString(value)
                    .. " | typeInfo=" .. tostring(infoText))
            end

            for _, propertyName in ipairs(managerPropertyNames) do
                local child = readProperty(value, propertyName)
                enqueue(child, tostring(node.label) .. "." .. propertyName, node.depth + 1)
            end

            for _, getterName in ipairs(managerGetterNames) do
                local getter = readProperty(value, getterName)
                if type(getter) == "function" then
                    local child, getterErr = safe(function() return getter(value) end)
                    if child ~= nil then
                        log("LIVESCENE GETTER | label=" .. tostring(node.label)
                            .. " | getter=" .. getterName
                            .. " | resultType=" .. tostring(type(child))
                            .. " | resultValue=" .. bindingSafeToString(child)
                            .. " | error=" .. tostring(getterErr or ""))
                        enqueue(child, tostring(node.label) .. ":" .. getterName .. "()", node.depth + 1)
                    end
                end
            end
        end

        if valueType == "table" and node.depth < maxDepth then
            local iterCount = 0
            local ok, iterErr = pcall(function()
                for key, child in pairs(value) do
                    iterCount = iterCount + 1
                    if iterCount > 2500 then break end
                    local keyText = bindingSafeToString(key)
                    if not (node.label == "_G.halo" or string.find(node.label, "_G.halo.", 1, true) == 1) then
                        enqueue(child, tostring(node.label) .. "." .. keyText, node.depth + 1)
                    end
                end
            end)
            if not ok then
                log("LIVESCENE scan iteration error | label=" .. tostring(node.label)
                    .. " | error=" .. tostring(iterErr))
            end
        end
    end

    local success = stats.rememberedMatches > 0 and stats.popupObjects > 0
    log("LIVESCENE COMPLETE | scanned=" .. tostring(stats.scanned)
        .. " | managerCandidates=" .. tostring(stats.managerCandidates)
        .. " | targetObjects=" .. tostring(stats.targetObjects)
        .. " | sceneObjects=" .. tostring(stats.sceneObjects)
        .. " | selectionObjects=" .. tostring(stats.selectionObjects)
        .. " | popupObjects=" .. tostring(stats.popupObjects)
        .. " | absoluteObjects=" .. tostring(stats.absoluteObjects)
        .. " | arrays=" .. tostring(stats.arrays)
        .. " | goods=" .. tostring(stats.goods)
        .. " | rememberedMatches=" .. tostring(stats.rememberedMatches)
        .. " | success=" .. tostring(success)
        .. " | readOnly=true")

    if success ~= true then
        log("LIVESCENE RETRY ALLOWED | keep the Load Good popup open, hover Hemp, and press Ctrl+Alt+K again")
    end

    return finish(true, success)
end


function GoodsFinder:ProbeDirectGoodsArray()
    if self.directGoodsArrayProbeRunning == true then
        log("DIRECTARRAY IGNORED | probe already running")
        return false
    end
    if self.directGoodsArrayProbeSucceeded == true then
        log("DIRECTARRAY IGNORED | Hemp was already found during this game session")
        return true
    end

    self.directGoodsArrayProbeRunning = true

    local function finish(result, succeeded)
        self.directGoodsArrayProbeRunning = false
        if succeeded == true then
            self.directGoodsArrayProbeSucceeded = true
        end
        return result
    end

    log("DIRECTARRAY START | direct read-only access to ui.Scenes.TradeRoute goods popup")

    local expectedGuid = tonumber(self.lastProductGuid) or 0
    local expectedName = tostring(self.lastProductName or "")
    log("DIRECTARRAY context | rememberedProductGUID=" .. tostring(expectedGuid)
        .. " | rememberedProductName=" .. expectedName)

    local scene, sceneErr = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection, selectionErr = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local popup, popupErr = safe(function()
        return selection and selection.PopupData
    end)
    local storage, storageErr = safe(function()
        return popup and popup.StorageData
    end)
    local filterData, filterErr = safe(function()
        return popup and popup.FilterGoodsData
    end)

    local route, routeErr = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid, routeValidErr = safe(function()
        return route and route:isValid()
    end)
    local popupVisible, popupVisibleErr = safe(function()
        return popup and popup.IsVisible
    end)
    local popupFocusedIndex, popupFocusErr = safe(function()
        return popup and popup.FocusedIndex
    end)

    log("DIRECTARRAY live path"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | sceneValue=" .. bindingSafeToString(scene)
        .. " | selectionType=" .. tostring(type(selection))
        .. " | selectionValue=" .. bindingSafeToString(selection)
        .. " | popupType=" .. tostring(type(popup))
        .. " | popupValue=" .. bindingSafeToString(popup)
        .. " | popupVisible=" .. tostring(popupVisible)
        .. " | popupFocusedIndex=" .. tostring(popupFocusedIndex)
        .. " | storageType=" .. tostring(type(storage))
        .. " | storageValue=" .. bindingSafeToString(storage)
        .. " | filterType=" .. tostring(type(filterData))
        .. " | filterValue=" .. bindingSafeToString(filterData)
        .. " | routeValid=" .. tostring(routeValid)
        .. " | errors=" .. tostring(sceneErr or selectionErr or popupErr or storageErr
            or filterErr or routeErr or routeValidErr or popupVisibleErr or popupFocusErr or ""))

    if routeValid ~= true then
        log("DIRECTARRAY ABORT | no valid temporary route editor")
        return finish(false, false)
    end
    if popupVisible ~= true then
        log("DIRECTARRAY ABORT | the Load Good popup is not open")
        return finish(false, false)
    end
    if storage == nil then
        log("DIRECTARRAY ABORT | PopupData.StorageData is unavailable")
        return finish(false, false)
    end

    local haloRoot = rawget(_G, "halo")
    local helper = nil
    local helperKey = nil

    if type(haloRoot) == "table" then
        helperKey = "PhoenixArray<halo::CTradeRouteAvailableGoodData>"
        helper = haloRoot[helperKey]

        if helper == nil then
            for key, value in pairs(haloRoot) do
                local text = tostring(key)
                if string.find(text, "PhoenixArray", 1, true)
                    and string.find(text, "TradeRouteAvailableGoodData", 1, true) then
                    helperKey = text
                    helper = value
                    break
                end
            end
        end
    end

    log("DIRECTARRAY helper"
        .. " | key=" .. tostring(helperKey)
        .. " | type=" .. tostring(type(helper))
        .. " | value=" .. bindingSafeToString(helper))

    local getInfoOld = rawget(_G, "getTypeInfoDeprecated")
    if type(getInfoOld) == "function" then
        local storageInfo, storageInfoErr = safe(function()
            return getInfoOld(storage)
        end)
        log("DIRECTARRAY storage typeinfo | success=" .. tostring(storageInfoErr == nil)
            .. " | result=" .. bindingSafeToString(storageInfo)
            .. " | error=" .. tostring(storageInfoErr or ""))

        local filterInfo, filterInfoErr = safe(function()
            return getInfoOld(filterData)
        end)
        log("DIRECTARRAY filter typeinfo | success=" .. tostring(filterInfoErr == nil)
            .. " | result=" .. bindingSafeToString(filterInfo)
            .. " | error=" .. tostring(filterInfoErr or ""))
    end

    local lengthValue, lengthErr = safe(function()
        return #storage
    end)
    local directSize, directSizeErr = safe(function()
        return storage:GetSize()
    end)
    local staticSize, staticSizeErr = safe(function()
        if type(helper) ~= "table" or type(helper.GetSize) ~= "function" then
            return nil
        end
        return helper.GetSize(storage)
    end)

    log("DIRECTARRAY size tests"
        .. " | lengthOperator=" .. tostring(lengthValue)
        .. " | lengthError=" .. tostring(lengthErr or "")
        .. " | directGetSize=" .. tostring(directSize)
        .. " | directGetSizeError=" .. tostring(directSizeErr or "")
        .. " | staticGetSize=" .. tostring(staticSize)
        .. " | staticGetSizeError=" .. tostring(staticSizeErr or ""))

    local seenObjects = {}
    local discovered = {}
    local attempted = 0
    local validGoods = 0
    local rememberedMatches = 0
    local hoveredGoods = 0

    local function objectIdentity(value)
        return type(value) .. "|" .. bindingSafeToString(value)
    end

    local function inspectGood(item, sourceLabel)
        attempted = attempted + 1
        if item == nil then return false end

        local itemType = type(item)
        if itemType ~= "table" and itemType ~= "userdata" then
            return false
        end

        local identity = objectIdentity(item)
        if seenObjects[identity] then
            return false
        end
        seenObjects[identity] = true

        local guid, guidErr = safe(function() return item.ProductGuid end)
        local index, indexErr = safe(function() return item.Index end)
        local amount, amountErr = safe(function() return item.Amount end)
        local isHovered, hoverErr = safe(function() return item.IsHovered end)
        local isSelected, selectedErr = safe(function() return item.IsSelected end)
        local imageId, imageErr = safe(function() return item.ImageID end)
        local eventValue, eventErr = safe(function() return item.PrimaryButtonPressed end)

        if type(guid) ~= "number" or guid <= 0 then
            log("DIRECTARRAY non-good object"
                .. " | source=" .. tostring(sourceLabel)
                .. " | type=" .. tostring(itemType)
                .. " | value=" .. bindingSafeToString(item)
                .. " | productGUID=" .. tostring(guid)
                .. " | error=" .. tostring(guidErr or ""))
            return false
        end

        validGoods = validGoods + 1
        local matches = guid == expectedGuid
        if matches then rememberedMatches = rememberedMatches + 1 end
        if isHovered == true then hoveredGoods = hoveredGoods + 1 end

        discovered[#discovered + 1] = {
            guid = guid,
            index = index,
            source = tostring(sourceLabel),
            hovered = isHovered,
            selected = isSelected,
            matches = matches
        }

        log("DIRECTARRAY GOOD"
            .. " | source=" .. tostring(sourceLabel)
            .. " | productGUID=" .. tostring(guid)
            .. " | index=" .. tostring(index)
            .. " | amount=" .. tostring(amount)
            .. " | isHovered=" .. tostring(isHovered)
            .. " | isSelected=" .. tostring(isSelected)
            .. " | imageID=" .. tostring(imageId)
            .. " | primaryButtonPressedType=" .. tostring(type(eventValue))
            .. " | matchesRemembered=" .. tostring(matches)
            .. " | errors=" .. tostring(guidErr or indexErr or amountErr or hoverErr
                or selectedErr or imageErr or eventErr or ""))

        if matches then
            log("DIRECTARRAY HEMP MATCH"
                .. " | source=" .. tostring(sourceLabel)
                .. " | productGUID=" .. tostring(guid)
                .. " | index=" .. tostring(index)
                .. " | isHovered=" .. tostring(isHovered)
                .. " | isSelected=" .. tostring(isSelected)
                .. " | PrimaryButtonPressedAvailable="
                .. tostring(type(eventValue) == "function"))
        end

        return true
    end

    local staticGetElement = type(helper) == "table"
        and type(helper.GetElement) == "function"

    local function inspectStaticIndex(index, labelPrefix)
        if not staticGetElement then return false, "helper.GetElement unavailable" end
        local item, err = safe(function()
            return helper.GetElement(storage, index)
        end)
        inspectGood(item, labelPrefix .. "[" .. tostring(index) .. "]")
        return item ~= nil, err
    end

    local size = tonumber(staticSize)
    if size == nil then size = tonumber(lengthValue) end
    if size == nil then size = tonumber(directSize) end

    if type(size) == "number" and size >= 0 then
        local limit = math.min(math.floor(size), 512)
        log("DIRECTARRAY enumeration plan | knownSize=" .. tostring(size)
            .. " | limit=" .. tostring(limit))

        for index = 0, limit - 1 do
            inspectStaticIndex(index, "static0")
            local directItem = safe(function() return storage[index] end)
            inspectGood(directItem, "direct0[" .. tostring(index) .. "]")
        end

        for index = 1, limit do
            inspectStaticIndex(index, "static1")
            local directItem = safe(function() return storage[index] end)
            inspectGood(directItem, "direct1[" .. tostring(index) .. "]")
        end
    else
        log("DIRECTARRAY enumeration plan | size unknown; probing indices 0 through 255")

        local consecutiveEmpty = 0
        local foundAny = false
        for index = 0, 255 do
            local staticItem, staticErr = nil, nil
            if staticGetElement then
                staticItem, staticErr = safe(function()
                    return helper.GetElement(storage, index)
                end)
                inspectGood(staticItem, "staticProbe[" .. tostring(index) .. "]")
            end

            local directItem, directErr = safe(function()
                return storage[index]
            end)
            inspectGood(directItem, "directProbe[" .. tostring(index) .. "]")

            if staticItem ~= nil or directItem ~= nil then
                foundAny = true
                consecutiveEmpty = 0
            else
                consecutiveEmpty = consecutiveEmpty + 1
            end

            if foundAny and consecutiveEmpty >= 24 then
                log("DIRECTARRAY probe stopped"
                    .. " | lastIndex=" .. tostring(index)
                    .. " | consecutiveEmpty=" .. tostring(consecutiveEmpty)
                    .. " | staticError=" .. tostring(staticErr or "")
                    .. " | directError=" .. tostring(directErr or ""))
                break
            end
        end
    end

    local pairCount = 0
    local pairErr = nil
    local pairOk, pairFailure = pcall(function()
        for key, value in pairs(storage) do
            pairCount = pairCount + 1
            if pairCount > 512 then break end
            inspectGood(value, "pairs[" .. bindingSafeToString(key) .. "]")
        end
    end)
    if not pairOk then pairErr = tostring(pairFailure) end

    log("DIRECTARRAY pairs test"
        .. " | success=" .. tostring(pairOk)
        .. " | count=" .. tostring(pairCount)
        .. " | error=" .. tostring(pairErr or ""))

    table.sort(discovered, function(a, b)
        local ai = tonumber(a.index) or 999999
        local bi = tonumber(b.index) or 999999
        if ai ~= bi then return ai < bi end
        return tonumber(a.guid) < tonumber(b.guid)
    end)

    for order, item in ipairs(discovered) do
        log("DIRECTARRAY ORDERED"
            .. " | order=" .. tostring(order)
            .. " | productGUID=" .. tostring(item.guid)
            .. " | index=" .. tostring(item.index)
            .. " | isHovered=" .. tostring(item.hovered)
            .. " | isSelected=" .. tostring(item.selected)
            .. " | matchesRemembered=" .. tostring(item.matches)
            .. " | source=" .. tostring(item.source))
    end

    local success = rememberedMatches > 0
    log("DIRECTARRAY COMPLETE"
        .. " | attemptedObjects=" .. tostring(attempted)
        .. " | validGoods=" .. tostring(validGoods)
        .. " | uniqueGoods=" .. tostring(#discovered)
        .. " | hoveredGoods=" .. tostring(hoveredGoods)
        .. " | rememberedMatches=" .. tostring(rememberedMatches)
        .. " | success=" .. tostring(success)
        .. " | readOnly=true")

    if not success then
        log("DIRECTARRAY RETRY ALLOWED | keep the Load Good popup open, hover Hemp, and press Ctrl+Alt+K again")
    end

    return finish(true, success)
end


function GoodsFinder:AutoSelectRememberedGood()
    if self.autoSelectProbeRunning == true then
        log("AUTOSELECT IGNORED | probe already running")
        return false
    end
    if self.autoSelectProbeSucceeded == true then
        log("AUTOSELECT IGNORED | remembered good was already selected during this game session")
        return true
    end

    self.autoSelectProbeRunning = true

    local function finish(result, succeeded)
        self.autoSelectProbeRunning = false
        if succeeded == true then
            self.autoSelectProbeSucceeded = true
        end
        return result
    end

    log("AUTOSELECT START | find remembered product and invoke its vanilla PrimaryButtonPressed event")

    local expectedGuid = tonumber(self.lastProductGuid) or 0
    local expectedName = tostring(self.lastProductName or "")
    log("AUTOSELECT context | rememberedProductGUID=" .. tostring(expectedGuid)
        .. " | rememberedProductName=" .. expectedName)

    if expectedGuid <= 0 then
        log("AUTOSELECT ABORT | no remembered product; first use Ctrl+Alt+G over a warehouse good")
        return finish(false, false)
    end

    local scene, sceneErr = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection, selectionErr = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local popup, popupErr = safe(function()
        return selection and selection.PopupData
    end)
    local storage, storageErr = safe(function()
        return popup and popup.StorageData
    end)
    local popupVisible, popupVisibleErr = safe(function()
        return popup and popup.IsVisible
    end)
    local popupFocusedIndexBefore, popupFocusedIndexErr = safe(function()
        return popup and popup.FocusedIndex
    end)

    local route, routeErr = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid, routeValidErr = safe(function()
        return route and route:isValid()
    end)

    log("AUTOSELECT live path"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | popupType=" .. tostring(type(popup))
        .. " | popupVisible=" .. tostring(popupVisible)
        .. " | popupFocusedIndex=" .. tostring(popupFocusedIndexBefore)
        .. " | storageType=" .. tostring(type(storage))
        .. " | storageValue=" .. bindingSafeToString(storage)
        .. " | routeValid=" .. tostring(routeValid)
        .. " | errors=" .. tostring(sceneErr or selectionErr or popupErr or storageErr
            or popupVisibleErr or popupFocusedIndexErr or routeErr or routeValidErr or ""))

    if routeValid ~= true then
        log("AUTOSELECT ABORT | no valid temporary route editor")
        return finish(false, false)
    end
    if popupVisible ~= true then
        log("AUTOSELECT ABORT | the Load Good popup is not open")
        return finish(false, false)
    end
    if storage == nil then
        log("AUTOSELECT ABORT | PopupData.StorageData is unavailable")
        return finish(false, false)
    end

    local haloRoot = rawget(_G, "halo")
    local arrayHelper = nil
    local availableGoodHelper = nil
    local arrayHelperKey = nil
    local availableGoodHelperKey = nil

    if type(haloRoot) == "table" then
        arrayHelperKey = "PhoenixArray<halo::CTradeRouteAvailableGoodData>"
        arrayHelper = haloRoot[arrayHelperKey]

        for key, value in pairs(haloRoot) do
            local text = tostring(key)
            if arrayHelper == nil
                and string.find(text, "PhoenixArray", 1, true)
                and string.find(text, "TradeRouteAvailableGoodData", 1, true) then
                arrayHelperKey = text
                arrayHelper = value
            end

            if string.find(text, "TradeRouteAvailableGoodData", 1, true)
                and not string.find(text, "PhoenixArray", 1, true) then
                availableGoodHelperKey = text
                availableGoodHelper = value
            end
        end
    end

    log("AUTOSELECT helpers"
        .. " | arrayKey=" .. tostring(arrayHelperKey)
        .. " | arrayType=" .. tostring(type(arrayHelper))
        .. " | goodKey=" .. tostring(availableGoodHelperKey)
        .. " | goodType=" .. tostring(type(availableGoodHelper)))

    if type(arrayHelper) ~= "table"
        or type(arrayHelper.GetSize) ~= "function"
        or type(arrayHelper.GetElement) ~= "function" then
        log("AUTOSELECT ABORT | PhoenixArray helper methods are unavailable")
        return finish(false, false)
    end

    local size, sizeErr = safe(function()
        return arrayHelper.GetSize(storage)
    end)
    log("AUTOSELECT array | size=" .. tostring(size)
        .. " | error=" .. tostring(sizeErr or ""))

    if type(size) ~= "number" or size <= 0 then
        log("AUTOSELECT ABORT | invalid goods-array size")
        return finish(false, false)
    end

    local targetItem = nil
    local targetArrayIndex = nil
    local targetEvent = nil
    local targetHoveredBefore = nil
    local targetSelectedBefore = nil
    local targetReportedIndex = nil
    local targetAmount = nil

    local limit = math.min(math.floor(size), 512)
    for arrayIndex = 0, limit - 1 do
        local item, itemErr = safe(function()
            return arrayHelper.GetElement(storage, arrayIndex)
        end)

        if item ~= nil then
            local guid = safe(function() return item.ProductGuid end)
            if tonumber(guid) == expectedGuid then
                targetItem = item
                targetArrayIndex = arrayIndex
                targetEvent = safe(function() return item.PrimaryButtonPressed end)
                targetHoveredBefore = safe(function() return item.IsHovered end)
                targetSelectedBefore = safe(function() return item.IsSelected end)
                targetReportedIndex = safe(function() return item.Index end)
                targetAmount = safe(function() return item.Amount end)

                log("AUTOSELECT MATCH"
                    .. " | arrayIndex=" .. tostring(targetArrayIndex)
                    .. " | productGUID=" .. tostring(guid)
                    .. " | reportedIndex=" .. tostring(targetReportedIndex)
                    .. " | amount=" .. tostring(targetAmount)
                    .. " | isHoveredBefore=" .. tostring(targetHoveredBefore)
                    .. " | isSelectedBefore=" .. tostring(targetSelectedBefore)
                    .. " | eventType=" .. tostring(type(targetEvent))
                    .. " | itemValue=" .. bindingSafeToString(targetItem)
                    .. " | elementError=" .. tostring(itemErr or ""))
                break
            end
        end
    end

    if targetItem == nil then
        log("AUTOSELECT ABORT | remembered product GUID not found in open goods popup")
        return finish(false, false)
    end
    if type(targetEvent) ~= "function"
        and not (type(availableGoodHelper) == "table"
            and type(availableGoodHelper.PrimaryButtonPressed) == "function") then
        log("AUTOSELECT ABORT | PrimaryButtonPressed is unavailable")
        return finish(false, false)
    end

    local dispatchMode = nil
    local dispatchResult = nil
    local dispatchError = nil

    if type(targetEvent) == "function" then
        dispatchMode = "boundFunctionWithSelf"
        dispatchResult, dispatchError = safe(function()
            return targetEvent(targetItem)
        end)

        if dispatchError ~= nil then
            log("AUTOSELECT dispatch attempt failed"
                .. " | mode=" .. dispatchMode
                .. " | error=" .. tostring(dispatchError))
            dispatchMode = "boundFunctionNoArgs"
            dispatchResult, dispatchError = safe(function()
                return targetEvent()
            end)
        end
    end

    if dispatchError ~= nil
        and type(availableGoodHelper) == "table"
        and type(availableGoodHelper.PrimaryButtonPressed) == "function" then
        log("AUTOSELECT dispatch attempt failed"
            .. " | mode=" .. tostring(dispatchMode)
            .. " | error=" .. tostring(dispatchError))
        dispatchMode = "staticHelperWithSelf"
        dispatchResult, dispatchError = safe(function()
            return availableGoodHelper.PrimaryButtonPressed(targetItem)
        end)
    end

    log("AUTOSELECT dispatch"
        .. " | mode=" .. tostring(dispatchMode)
        .. " | success=" .. tostring(dispatchError == nil)
        .. " | result=" .. bindingSafeToString(dispatchResult)
        .. " | error=" .. tostring(dispatchError or ""))

    local popupVisibleAfter, popupVisibleAfterErr = safe(function()
        return popup and popup.IsVisible
    end)
    local popupFocusedIndexAfter, popupFocusedAfterErr = safe(function()
        return popup and popup.FocusedIndex
    end)
    local targetHoveredAfter, hoverAfterErr = safe(function()
        return targetItem and targetItem.IsHovered
    end)
    local targetSelectedAfter, selectedAfterErr = safe(function()
        return targetItem and targetItem.IsSelected
    end)

    log("AUTOSELECT immediate UI result"
        .. " | popupVisibleAfter=" .. tostring(popupVisibleAfter)
        .. " | popupFocusedIndexAfter=" .. tostring(popupFocusedIndexAfter)
        .. " | isHoveredAfter=" .. tostring(targetHoveredAfter)
        .. " | isSelectedAfter=" .. tostring(targetSelectedAfter)
        .. " | errors=" .. tostring(popupVisibleAfterErr or popupFocusedAfterErr
            or hoverAfterErr or selectedAfterErr or ""))

    local configuredMatches = 0
    local configuredEntries = 0

    if routeValid == true then
        for stationID = 0, 15 do
            local station = safe(function()
                return route:GetStation(stationID)
            end)
            local stationValid = safe(function()
                return station and station:isValid()
            end)

            if stationValid == true then
                for goodID = 0, 15 do
                    local hasGood = safe(function()
                        return station:HasGood(goodID)
                    end)
                    local good = safe(function()
                        return station:GetGood(goodID)
                    end)
                    local guid = safe(function()
                        return good and good.Guid
                    end)
                    local amount = safe(function()
                        return good and good.Amount
                    end)
                    local loading = safe(function()
                        return good and good.Loading
                    end)

                    if hasGood == true or (tonumber(guid) or 0) > 0 then
                        configuredEntries = configuredEntries + 1
                        local matches = tonumber(guid) == expectedGuid
                        if matches then configuredMatches = configuredMatches + 1 end

                        log("AUTOSELECT route good"
                            .. " | stationID=" .. tostring(stationID)
                            .. " | goodID=" .. tostring(goodID)
                            .. " | hasGood=" .. tostring(hasGood)
                            .. " | guid=" .. tostring(guid)
                            .. " | amount=" .. tostring(amount)
                            .. " | loading=" .. tostring(loading)
                            .. " | matchesRemembered=" .. tostring(matches))
                    end
                end
            end
        end
    end

    local dispatched = dispatchError == nil
    local visibleChanged = popupVisibleAfter == false
    local selectedChanged = targetSelectedBefore ~= true and targetSelectedAfter == true
    local routeChanged = configuredMatches > 0
    local success = dispatched and (visibleChanged or selectedChanged or routeChanged)

    log("AUTOSELECT COMPLETE"
        .. " | targetArrayIndex=" .. tostring(targetArrayIndex)
        .. " | dispatched=" .. tostring(dispatched)
        .. " | popupClosed=" .. tostring(visibleChanged)
        .. " | selectedChanged=" .. tostring(selectedChanged)
        .. " | configuredEntries=" .. tostring(configuredEntries)
        .. " | configuredMatches=" .. tostring(configuredMatches)
        .. " | success=" .. tostring(success)
        .. " | modifiesTemporaryRoute=true")

    if not success then
        log("AUTOSELECT RETRY ALLOWED | reopen Load Good popup and press Ctrl+Alt+K once")
    end

    return finish(dispatched, success)
end


function GoodsFinder:FocusRememberedGood()
    if self.focusHighlightProbeRunning == true then
        log("FOCUSPROBE IGNORED | probe already running")
        return false
    end

    self.focusHighlightProbeRunning = true

    local function finish(result)
        self.focusHighlightProbeRunning = false
        return result
    end

    log("FOCUSPROBE START | keep popup open and try to focus/highlight remembered product without selecting it")

    local expectedGuid = tonumber(self.lastProductGuid) or 0
    local expectedName = tostring(self.lastProductName or "")
    log("FOCUSPROBE context | rememberedProductGUID=" .. tostring(expectedGuid)
        .. " | rememberedProductName=" .. expectedName)

    if expectedGuid <= 0 then
        log("FOCUSPROBE ABORT | no remembered product; first use Ctrl+Alt+G over a warehouse good")
        return finish(false)
    end

    local scene, sceneErr = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection, selectionErr = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local popup, popupErr = safe(function()
        return selection and selection.PopupData
    end)
    local storage, storageErr = safe(function()
        return popup and popup.StorageData
    end)
    local popupVisible, popupVisibleErr = safe(function()
        return popup and popup.IsVisible
    end)
    local route, routeErr = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid, routeValidErr = safe(function()
        return route and route:isValid()
    end)

    log("FOCUSPROBE live path"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | popupType=" .. tostring(type(popup))
        .. " | popupVisible=" .. tostring(popupVisible)
        .. " | storageType=" .. tostring(type(storage))
        .. " | storageValue=" .. bindingSafeToString(storage)
        .. " | routeValid=" .. tostring(routeValid)
        .. " | errors=" .. tostring(sceneErr or selectionErr or popupErr or storageErr
            or popupVisibleErr or routeErr or routeValidErr or ""))

    if routeValid ~= true then
        log("FOCUSPROBE ABORT | no valid temporary route editor")
        return finish(false)
    end
    if popupVisible ~= true then
        log("FOCUSPROBE ABORT | the Load Good popup is not open")
        return finish(false)
    end
    if storage == nil then
        log("FOCUSPROBE ABORT | PopupData.StorageData is unavailable")
        return finish(false)
    end

    local haloRoot = rawget(_G, "halo")
    local arrayHelper = nil
    local arrayHelperKey = nil

    if type(haloRoot) == "table" then
        arrayHelperKey = "PhoenixArray<halo::CTradeRouteAvailableGoodData>"
        arrayHelper = haloRoot[arrayHelperKey]

        if arrayHelper == nil then
            for key, value in pairs(haloRoot) do
                local text = tostring(key)
                if string.find(text, "PhoenixArray", 1, true)
                    and string.find(text, "TradeRouteAvailableGoodData", 1, true) then
                    arrayHelperKey = text
                    arrayHelper = value
                    break
                end
            end
        end
    end

    log("FOCUSPROBE helper"
        .. " | key=" .. tostring(arrayHelperKey)
        .. " | type=" .. tostring(type(arrayHelper)))

    if type(arrayHelper) ~= "table"
        or type(arrayHelper.GetSize) ~= "function"
        or type(arrayHelper.GetElement) ~= "function" then
        log("FOCUSPROBE ABORT | PhoenixArray helper methods are unavailable")
        return finish(false)
    end

    local size, sizeErr = safe(function()
        return arrayHelper.GetSize(storage)
    end)
    log("FOCUSPROBE array | size=" .. tostring(size)
        .. " | error=" .. tostring(sizeErr or ""))

    if type(size) ~= "number" or size <= 0 then
        log("FOCUSPROBE ABORT | invalid goods-array size")
        return finish(false)
    end

    local targetItem = nil
    local targetArrayIndex = nil

    local limit = math.min(math.floor(size), 512)
    for arrayIndex = 0, limit - 1 do
        local item = safe(function()
            return arrayHelper.GetElement(storage, arrayIndex)
        end)
        local guid = safe(function()
            return item and item.ProductGuid
        end)

        if tonumber(guid) == expectedGuid then
            targetItem = item
            targetArrayIndex = arrayIndex
            break
        end
    end

    if targetItem == nil then
        log("FOCUSPROBE ABORT | remembered product GUID not found in open goods popup")
        return finish(false)
    end

    local popupFocusedBefore = safe(function() return popup.FocusedIndex end)
    local itemHoveredBefore = safe(function() return targetItem.IsHovered end)
    local itemSelectedBefore = safe(function() return targetItem.IsSelected end)
    local itemReportedIndex = safe(function() return targetItem.Index end)
    local itemAmount = safe(function() return targetItem.Amount end)

    log("FOCUSPROBE MATCH"
        .. " | arrayIndex=" .. tostring(targetArrayIndex)
        .. " | productGUID=" .. tostring(expectedGuid)
        .. " | reportedIndex=" .. tostring(itemReportedIndex)
        .. " | amount=" .. tostring(itemAmount)
        .. " | popupFocusedBefore=" .. tostring(popupFocusedBefore)
        .. " | isHoveredBefore=" .. tostring(itemHoveredBefore)
        .. " | isSelectedBefore=" .. tostring(itemSelectedBefore)
        .. " | itemValue=" .. bindingSafeToString(targetItem))

    local attempts = 0
    local successfulWrites = 0

    local function snapshot(label)
        local visible = safe(function() return popup.IsVisible end)
        local focused = safe(function() return popup.FocusedIndex end)
        local hovered = safe(function() return targetItem.IsHovered end)
        local selected = safe(function() return targetItem.IsSelected end)

        log("FOCUSPROBE SNAPSHOT"
            .. " | label=" .. tostring(label)
            .. " | popupVisible=" .. tostring(visible)
            .. " | popupFocusedIndex=" .. tostring(focused)
            .. " | isHovered=" .. tostring(hovered)
            .. " | isSelected=" .. tostring(selected))

        return visible, focused, hovered, selected
    end

    local function attemptWrite(label, writer)
        attempts = attempts + 1
        local result, err = safe(writer)
        if err == nil then successfulWrites = successfulWrites + 1 end

        log("FOCUSPROBE WRITE"
            .. " | label=" .. tostring(label)
            .. " | success=" .. tostring(err == nil)
            .. " | result=" .. bindingSafeToString(result)
            .. " | error=" .. tostring(err or ""))

        return err == nil
    end

    -- Most likely input used by the popup's controller.
    attemptWrite("popup.FocusedIndex=arrayIndex", function()
        popup.FocusedIndex = targetArrayIndex
        return popup.FocusedIndex
    end)

    local visible1, focused1, hovered1, selected1 = snapshot("after popup focus assignment")
    local focusObserved = focused1 == targetArrayIndex or hovered1 == true

    -- Some generated UI data objects accept direct hover-state writes.
    if not focusObserved and visible1 == true then
        attemptWrite("targetItem.IsHovered=true", function()
            targetItem.IsHovered = true
            return targetItem.IsHovered
        end)
    end

    local visible2, focused2, hovered2, selected2 = snapshot("after hover assignment")
    focusObserved = focusObserved or focused2 == targetArrayIndex or hovered2 == true

    -- Selected is tested only as a visual-state property. PrimaryButtonPressed is
    -- deliberately not called, so this build should not add Hemp to the route.
    if not focusObserved and visible2 == true then
        attemptWrite("targetItem.IsSelected=true", function()
            targetItem.IsSelected = true
            return targetItem.IsSelected
        end)
    end

    local visible3, focused3, hovered3, selected3 = snapshot("final")
    local highlightObserved =
        focused3 == targetArrayIndex
        or hovered3 == true
        or (itemSelectedBefore ~= true and selected3 == true)

    local configuredMatches = 0
    local configuredEntries = 0

    if routeValid == true then
        for stationID = 0, 15 do
            local station = safe(function()
                return route:GetStation(stationID)
            end)
            local stationValid = safe(function()
                return station and station:isValid()
            end)

            if stationValid == true then
                for goodID = 0, 15 do
                    local hasGood = safe(function()
                        return station:HasGood(goodID)
                    end)
                    local good = safe(function()
                        return station:GetGood(goodID)
                    end)
                    local guid = safe(function()
                        return good and good.Guid
                    end)

                    if hasGood == true or (tonumber(guid) or 0) > 0 then
                        configuredEntries = configuredEntries + 1
                        if tonumber(guid) == expectedGuid then
                            configuredMatches = configuredMatches + 1
                        end
                    end
                end
            end
        end
    end

    local popupStillOpen = visible3 == true
    local didNotSelectRouteGood = configuredMatches == 0

    log("FOCUSPROBE COMPLETE"
        .. " | targetArrayIndex=" .. tostring(targetArrayIndex)
        .. " | attempts=" .. tostring(attempts)
        .. " | successfulWrites=" .. tostring(successfulWrites)
        .. " | popupStillOpen=" .. tostring(popupStillOpen)
        .. " | highlightObserved=" .. tostring(highlightObserved)
        .. " | configuredEntries=" .. tostring(configuredEntries)
        .. " | configuredMatches=" .. tostring(configuredMatches)
        .. " | didNotSelectRouteGood=" .. tostring(didNotSelectRouteGood)
        .. " | repeatAllowed=true")

    return finish(highlightObserved)
end


function GoodsFinder:ForceRememberedGoodHover()
    if self.hoverOverlayProbeRunning == true then
        log("HOVERPROBE IGNORED | probe already running")
        return false
    end

    self.hoverOverlayProbeRunning = true

    local function finish(result)
        self.hoverOverlayProbeRunning = false
        return result
    end

    log("HOVERPROBE START | force remembered product hover state and refresh Trade Route scene")

    local expectedGuid = tonumber(self.lastProductGuid) or 0
    local expectedName = tostring(self.lastProductName or "")
    log("HOVERPROBE context | rememberedProductGUID=" .. tostring(expectedGuid)
        .. " | rememberedProductName=" .. expectedName)

    if expectedGuid <= 0 then
        log("HOVERPROBE ABORT | no remembered product; first use Ctrl+Alt+G over a warehouse good")
        return finish(false)
    end

    local scene, sceneErr = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection, selectionErr = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local popup, popupErr = safe(function()
        return selection and selection.PopupData
    end)
    local storage, storageErr = safe(function()
        return popup and popup.StorageData
    end)
    local popupVisible, popupVisibleErr = safe(function()
        return popup and popup.IsVisible
    end)
    local route, routeErr = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid, routeValidErr = safe(function()
        return route and route:isValid()
    end)

    log("HOVERPROBE live path"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | sceneValue=" .. bindingSafeToString(scene)
        .. " | selectionType=" .. tostring(type(selection))
        .. " | popupType=" .. tostring(type(popup))
        .. " | popupVisible=" .. tostring(popupVisible)
        .. " | storageType=" .. tostring(type(storage))
        .. " | storageValue=" .. bindingSafeToString(storage)
        .. " | routeValid=" .. tostring(routeValid)
        .. " | errors=" .. tostring(sceneErr or selectionErr or popupErr or storageErr
            or popupVisibleErr or routeErr or routeValidErr or ""))

    if routeValid ~= true then
        log("HOVERPROBE ABORT | no valid temporary route editor")
        return finish(false)
    end
    if popupVisible ~= true then
        log("HOVERPROBE ABORT | the Load Good popup is not open")
        return finish(false)
    end
    if storage == nil then
        log("HOVERPROBE ABORT | PopupData.StorageData is unavailable")
        return finish(false)
    end

    local haloRoot = rawget(_G, "halo")
    local arrayHelper = nil
    local arrayHelperKey = nil
    local sceneHelper = nil
    local sceneHelperKey = nil

    if type(haloRoot) == "table" then
        arrayHelperKey = "PhoenixArray<halo::CTradeRouteAvailableGoodData>"
        arrayHelper = haloRoot[arrayHelperKey]
        sceneHelperKey = "TradeRouteSceneObject"
        sceneHelper = haloRoot[sceneHelperKey]

        for key, value in pairs(haloRoot) do
            local text = tostring(key)
            if arrayHelper == nil
                and string.find(text, "PhoenixArray", 1, true)
                and string.find(text, "TradeRouteAvailableGoodData", 1, true) then
                arrayHelperKey = text
                arrayHelper = value
            end
            if sceneHelper == nil and text == "TradeRouteSceneObject" then
                sceneHelperKey = text
                sceneHelper = value
            end
        end
    end

    log("HOVERPROBE helpers"
        .. " | arrayKey=" .. tostring(arrayHelperKey)
        .. " | arrayType=" .. tostring(type(arrayHelper))
        .. " | sceneKey=" .. tostring(sceneHelperKey)
        .. " | sceneType=" .. tostring(type(sceneHelper)))

    if type(arrayHelper) ~= "table"
        or type(arrayHelper.GetSize) ~= "function"
        or type(arrayHelper.GetElement) ~= "function" then
        log("HOVERPROBE ABORT | PhoenixArray helper methods are unavailable")
        return finish(false)
    end

    local size, sizeErr = safe(function()
        return arrayHelper.GetSize(storage)
    end)
    log("HOVERPROBE array | size=" .. tostring(size)
        .. " | error=" .. tostring(sizeErr or ""))

    if type(size) ~= "number" or size <= 0 then
        log("HOVERPROBE ABORT | invalid goods-array size")
        return finish(false)
    end

    local targetItem = nil
    local targetArrayIndex = nil
    local limit = math.min(math.floor(size), 512)

    for arrayIndex = 0, limit - 1 do
        local item = safe(function()
            return arrayHelper.GetElement(storage, arrayIndex)
        end)
        local guid = safe(function()
            return item and item.ProductGuid
        end)

        if tonumber(guid) == expectedGuid then
            targetItem = item
            targetArrayIndex = arrayIndex
            break
        end
    end

    if targetItem == nil then
        log("HOVERPROBE ABORT | remembered product GUID not found in open goods popup")
        return finish(false)
    end

    local popupFocusedBefore = safe(function() return popup.FocusedIndex end)
    local hoveredBefore = safe(function() return targetItem.IsHovered end)
    local selectedBefore = safe(function() return targetItem.IsSelected end)
    local reportedIndex = safe(function() return targetItem.Index end)
    local amount = safe(function() return targetItem.Amount end)

    log("HOVERPROBE MATCH"
        .. " | arrayIndex=" .. tostring(targetArrayIndex)
        .. " | productGUID=" .. tostring(expectedGuid)
        .. " | reportedIndex=" .. tostring(reportedIndex)
        .. " | amount=" .. tostring(amount)
        .. " | popupFocusedBefore=" .. tostring(popupFocusedBefore)
        .. " | isHoveredBefore=" .. tostring(hoveredBefore)
        .. " | isSelectedBefore=" .. tostring(selectedBefore)
        .. " | itemValue=" .. bindingSafeToString(targetItem))

    -- Read-only probe. Do not change Interaction state in this build.
    local interaction, interactionErr = safe(function()
        return targetItem and targetItem.Interaction
    end)
    local interactionEnabled, interactionEnabledErr = safe(function()
        return interaction and interaction.IsEnabled
    end)
    local interactionStates, interactionStatesErr = safe(function()
        return interaction and interaction.States
    end)



    local focusResult, focusErr = safe(function()
        popup.FocusedIndex = targetArrayIndex
        return popup.FocusedIndex
    end)
    log("HOVERPROBE WRITE"
        .. " | label=popup.FocusedIndex=arrayIndex"
        .. " | success=" .. tostring(focusErr == nil)
        .. " | result=" .. tostring(focusResult)
        .. " | error=" .. tostring(focusErr or ""))

    local hoverResult, hoverErr = safe(function()
        targetItem.IsHovered = true
        return targetItem.IsHovered
    end)
    log("HOVERPROBE WRITE"
        .. " | label=targetItem.IsHovered=true"
        .. " | success=" .. tostring(hoverErr == nil)
        .. " | result=" .. tostring(hoverResult)
        .. " | error=" .. tostring(hoverErr or ""))

    local refreshMode = nil
    local refreshResult = nil
    local refreshErr = nil

    local boundRequestFocus = safe(function()
        return scene and scene.RequestFocus
    end)

    if type(boundRequestFocus) == "function" then
        refreshMode = "scene.RequestFocus(scene)"
        refreshResult, refreshErr = safe(function()
            return boundRequestFocus(scene)
        end)

        if refreshErr ~= nil then
            log("HOVERPROBE refresh attempt failed"
                .. " | mode=" .. refreshMode
                .. " | error=" .. tostring(refreshErr))
            refreshMode = "scene.RequestFocus()"
            refreshResult, refreshErr = safe(function()
                return boundRequestFocus()
            end)
        end
    end

    if refreshErr ~= nil
        and type(sceneHelper) == "table"
        and type(sceneHelper.RequestFocus) == "function" then
        log("HOVERPROBE refresh attempt failed"
            .. " | mode=" .. tostring(refreshMode)
            .. " | error=" .. tostring(refreshErr))
        refreshMode = "TradeRouteSceneObject.RequestFocus(scene)"
        refreshResult, refreshErr = safe(function()
            return sceneHelper.RequestFocus(scene)
        end)
    end

    log("HOVERPROBE REFRESH"
        .. " | mode=" .. tostring(refreshMode)
        .. " | success=" .. tostring(refreshErr == nil)
        .. " | result=" .. bindingSafeToString(refreshResult)
        .. " | error=" .. tostring(refreshErr or ""))

    local popupVisibleAfter = safe(function() return popup.IsVisible end)
    local popupFocusedAfter = safe(function() return popup.FocusedIndex end)
    local hoveredAfter = safe(function() return targetItem.IsHovered end)
    local selectedAfter = safe(function() return targetItem.IsSelected end)

    local configuredMatches = 0
    local configuredEntries = 0

    for stationID = 0, 15 do
        local station = safe(function()
            return route:GetStation(stationID)
        end)
        local stationValid = safe(function()
            return station and station:isValid()
        end)

        if stationValid == true then
            for goodID = 0, 15 do
                local hasGood = safe(function()
                    return station:HasGood(goodID)
                end)
                local good = safe(function()
                    return station:GetGood(goodID)
                end)
                local guid = safe(function()
                    return good and good.Guid
                end)

                if hasGood == true or (tonumber(guid) or 0) > 0 then
                    configuredEntries = configuredEntries + 1
                    if tonumber(guid) == expectedGuid then
                        configuredMatches = configuredMatches + 1
                    end
                end
            end
        end
    end

    local popupStillOpen = popupVisibleAfter == true
    local hoverApplied = hoveredAfter == true
    local focusApplied = popupFocusedAfter == targetArrayIndex
    local routeUnchanged = configuredMatches == 0
    local success = popupStillOpen and routeUnchanged and (hoverApplied or focusApplied)

    log("HOVERPROBE COMPLETE"
        .. " | targetArrayIndex=" .. tostring(targetArrayIndex)
        .. " | popupStillOpen=" .. tostring(popupStillOpen)
        .. " | popupFocusedAfter=" .. tostring(popupFocusedAfter)
        .. " | isHoveredAfter=" .. tostring(hoveredAfter)
        .. " | isSelectedAfter=" .. tostring(selectedAfter)
        .. " | focusApplied=" .. tostring(focusApplied)
        .. " | hoverApplied=" .. tostring(hoverApplied)
        .. " | configuredEntries=" .. tostring(configuredEntries)
        .. " | configuredMatches=" .. tostring(configuredMatches)
        .. " | routeUnchanged=" .. tostring(routeUnchanged)
        .. " | success=" .. tostring(success)
        .. " | repeatAllowed=true")

    return finish(success)
end


function GoodsFinder:OpenRememberedStationLoadPopupOrHighlight()
    if self.autoLoadPopupProbeRunning == true then
        log("AUTOLOADPOPUP IGNORED | probe already running")
        return false
    end

    self.autoLoadPopupProbeRunning = true

    local function finish(result)
        self.autoLoadPopupProbeRunning = false
        return result
    end

    log("AUTOLOADPOPUP START | focus remembered station, open a Load Good slot, then highlight remembered product")

    local expectedGuid = tonumber(self.lastProductGuid) or 0
    local expectedName = tostring(self.lastProductName or "")
    local expectedIslandName = tostring(self.lastWarehouseAreaName or "")

    log("AUTOLOADPOPUP context"
        .. " | rememberedProductGUID=" .. tostring(expectedGuid)
        .. " | rememberedProductName=" .. expectedName
        .. " | rememberedIslandName=" .. expectedIslandName
        .. " | rememberedAreaID=" .. tostring(self.lastWarehouseAreaId))

    if expectedGuid <= 0 then
        log("AUTOLOADPOPUP ABORT | no remembered product; first use Ctrl+Alt+G over a warehouse good")
        return finish(false)
    end

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local popup = safe(function()
        return selection and selection.PopupData
    end)
    local popupVisible = safe(function()
        return popup and popup.IsVisible
    end)
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)

    log("AUTOLOADPOPUP live path"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | popupType=" .. tostring(type(popup))
        .. " | popupVisible=" .. tostring(popupVisible)
        .. " | routeValid=" .. tostring(routeValid))

    if routeValid ~= true then
        log("AUTOLOADPOPUP ABORT | no valid temporary route editor")
        return finish(false)
    end

    -- If the goods popup is already open, reuse the proven v0.13.8 overlay logic.
    if popupVisible == true then
        log("AUTOLOADPOPUP popup already open | delegate to ForceRememberedGoodHover")
        local result = self:ForceRememberedGoodHover()
        return finish(result)
    end

    local haloRoot = rawget(_G, "halo")

    local function getPhoenixArrayHelper(value)
        if value == nil or type(haloRoot) ~= "table" then
            return nil, nil
        end

        local text = bindingSafeToString(value)
        local key = string.match(text, "^(PhoenixArray<[^>]+>)")
        if key ~= nil and type(haloRoot[key]) == "table" then
            return haloRoot[key], key
        end

        for candidateKey, candidateValue in pairs(haloRoot) do
            local candidateText = tostring(candidateKey)
            if type(candidateValue) == "table"
                and string.find(candidateText, "PhoenixArray", 1, true)
                and string.find(text, candidateText, 1, true) then
                return candidateValue, candidateText
            end
        end

        return nil, nil
    end

    local function enumerateObjects(value, label)
        local results = {}
        if value == nil then
            log("AUTOLOADPOPUP ENUM | label=" .. tostring(label) .. " | value=nil")
            return results
        end

        local helper, helperKey = getPhoenixArrayHelper(value)
        if type(helper) == "table"
            and type(helper.GetSize) == "function"
            and type(helper.GetElement) == "function" then

            local size, sizeErr = safe(function()
                return helper.GetSize(value)
            end)

            log("AUTOLOADPOPUP ENUM"
                .. " | label=" .. tostring(label)
                .. " | mode=PhoenixArray"
                .. " | helperKey=" .. tostring(helperKey)
                .. " | size=" .. tostring(size)
                .. " | error=" .. tostring(sizeErr or ""))

            if type(size) == "number" and size >= 0 then
                local limit = math.min(math.floor(size), 256)
                for index = 0, limit - 1 do
                    local item = safe(function()
                        return helper.GetElement(value, index)
                    end)
                    if item ~= nil then
                        results[#results + 1] = {
                            value = item,
                            arrayIndex = index,
                            label = tostring(label) .. "[" .. tostring(index) .. "]"
                        }
                    end
                end
            end

            return results
        end

        results[#results + 1] = {
            value = value,
            arrayIndex = 0,
            label = tostring(label)
        }

        log("AUTOLOADPOPUP ENUM"
            .. " | label=" .. tostring(label)
            .. " | mode=singleObject"
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value))

        return results
    end

    local stationContainer = safe(function()
        return selection and selection.TradeRouteGoodData
    end)

    log("AUTOLOADPOPUP station container"
        .. " | type=" .. tostring(type(stationContainer))
        .. " | value=" .. bindingSafeToString(stationContainer))

    local stationObjects = enumerateObjects(
        stationContainer,
        "TradeGoodSelection.TradeRouteGoodData"
    )

    local stationMatches = {}
    local normalizedExpected = string.lower(expectedIslandName)

    for _, entry in ipairs(stationObjects) do
        local stationObject = entry.value
        local islandName = safe(function() return stationObject.IslandName end)
        local stationID = safe(function() return stationObject.StationID end)
        local stationListPosition = safe(function() return stationObject.StationListPosition end)
        local requestFocus = safe(function() return stationObject.RequestFocus end)
        local slots = safe(function() return stationObject.TradeRouteLoadandUnloadData end)

        local normalizedIsland = string.lower(tostring(islandName or ""))
        local matches = normalizedExpected ~= ""
            and normalizedIsland == normalizedExpected

        log("AUTOLOADPOPUP STATION"
            .. " | source=" .. tostring(entry.label)
            .. " | arrayIndex=" .. tostring(entry.arrayIndex)
            .. " | islandName=" .. tostring(islandName)
            .. " | stationID=" .. tostring(stationID)
            .. " | stationListPosition=" .. tostring(stationListPosition)
            .. " | requestFocusType=" .. tostring(type(requestFocus))
            .. " | slotsType=" .. tostring(type(slots))
            .. " | slotsValue=" .. bindingSafeToString(slots)
            .. " | matchesRememberedIsland=" .. tostring(matches))

        if matches then
            stationMatches[#stationMatches + 1] = {
                object = stationObject,
                islandName = islandName,
                stationID = stationID,
                arrayIndex = entry.arrayIndex,
                requestFocus = requestFocus,
                slots = slots
            }
        end
    end

    log("AUTOLOADPOPUP station match summary"
        .. " | totalStations=" .. tostring(#stationObjects)
        .. " | matchingStations=" .. tostring(#stationMatches))

    if #stationMatches == 0 then
        log("AUTOLOADPOPUP ABORT | remembered island was not found among the route stations")
        return finish(false)
    end

    local station = stationMatches[1]

    if type(station.requestFocus) == "function" then
        local focusMode = "station.RequestFocus(station)"
        local focusResult, focusErr = safe(function()
            return station.requestFocus(station.object)
        end)

        if focusErr ~= nil then
            log("AUTOLOADPOPUP station focus attempt failed"
                .. " | mode=" .. focusMode
                .. " | error=" .. tostring(focusErr))
            focusMode = "station.RequestFocus()"
            focusResult, focusErr = safe(function()
                return station.requestFocus()
            end)
        end

        log("AUTOLOADPOPUP station focus"
            .. " | mode=" .. tostring(focusMode)
            .. " | success=" .. tostring(focusErr == nil)
            .. " | result=" .. bindingSafeToString(focusResult)
            .. " | error=" .. tostring(focusErr or ""))
    else
        log("AUTOLOADPOPUP station focus unavailable | RequestFocus is not a function")
    end

    local slotObjects = enumerateObjects(
        station.slots,
        "HelperStation.TradeRouteLoadandUnloadData"
    )

    local slotCandidates = {}

    for _, entry in ipairs(slotObjects) do
        local slotObject = entry.value
        local index = safe(function() return slotObject.Index end)
        local stationID = safe(function() return slotObject.StationId end)
        local isBtnVisible = safe(function() return slotObject.IsBtnVisible end)
        local isBtnSelected = safe(function() return slotObject.IsBtnSelected end)
        local isGoodLoaded = safe(function() return slotObject.IsGoodLoaded end)
        local amount = safe(function() return slotObject.Amount end)
        local goodImageID = safe(function() return slotObject.GoodImageID end)
        local addGood = safe(function() return slotObject.AddGood end)
        local removeGood = safe(function() return slotObject.RemoveGood end)

        local candidate =
            type(addGood) == "function"
            and isBtnVisible ~= false
            and (tonumber(amount) or 0) == 0
            and (tonumber(goodImageID) or 0) == 0

        log("AUTOLOADPOPUP SLOT"
            .. " | source=" .. tostring(entry.label)
            .. " | arrayIndex=" .. tostring(entry.arrayIndex)
            .. " | index=" .. tostring(index)
            .. " | stationID=" .. tostring(stationID)
            .. " | isBtnVisible=" .. tostring(isBtnVisible)
            .. " | isBtnSelected=" .. tostring(isBtnSelected)
            .. " | isGoodLoaded=" .. tostring(isGoodLoaded)
            .. " | amount=" .. tostring(amount)
            .. " | goodImageID=" .. tostring(goodImageID)
            .. " | addGoodType=" .. tostring(type(addGood))
            .. " | removeGoodType=" .. tostring(type(removeGood))
            .. " | candidate=" .. tostring(candidate))

        if candidate then
            slotCandidates[#slotCandidates + 1] = {
                object = slotObject,
                addGood = addGood,
                arrayIndex = entry.arrayIndex,
                index = index,
                isGoodLoaded = isGoodLoaded
            }
        end
    end

    table.sort(slotCandidates, function(a, b)
        local ai = tonumber(a.arrayIndex) or 999999
        local bi = tonumber(b.arrayIndex) or 999999
        return ai < bi
    end)

    log("AUTOLOADPOPUP slot candidate summary"
        .. " | totalSlots=" .. tostring(#slotObjects)
        .. " | candidates=" .. tostring(#slotCandidates))

    if #slotCandidates == 0 then
        log("AUTOLOADPOPUP ABORT | no empty visible AddGood slot was found")
        return finish(false)
    end

    local slot = slotCandidates[1]
    local dispatchMode = "slot.AddGood(slot)"
    local dispatchResult, dispatchErr = safe(function()
        return slot.addGood(slot.object)
    end)

    if dispatchErr ~= nil then
        log("AUTOLOADPOPUP AddGood attempt failed"
            .. " | mode=" .. dispatchMode
            .. " | error=" .. tostring(dispatchErr))
        dispatchMode = "slot.AddGood()"
        dispatchResult, dispatchErr = safe(function()
            return slot.addGood()
        end)
    end

    log("AUTOLOADPOPUP AddGood dispatch"
        .. " | mode=" .. tostring(dispatchMode)
        .. " | slotArrayIndex=" .. tostring(slot.arrayIndex)
        .. " | slotIndex=" .. tostring(slot.index)
        .. " | isGoodLoaded=" .. tostring(slot.isGoodLoaded)
        .. " | success=" .. tostring(dispatchErr == nil)
        .. " | result=" .. bindingSafeToString(dispatchResult)
        .. " | error=" .. tostring(dispatchErr or ""))

    local popupVisibleAfter = safe(function()
        return popup and popup.IsVisible
    end)

    log("AUTOLOADPOPUP popup result"
        .. " | popupVisibleAfter=" .. tostring(popupVisibleAfter))

    if popupVisibleAfter == true then
        log("AUTOLOADPOPUP popup opened immediately | apply remembered product hover")
        local overlayResult = self:ForceRememberedGoodHover()
        log("AUTOLOADPOPUP overlay result | success=" .. tostring(overlayResult))
        return finish(overlayResult)
    end

    log("AUTOLOADPOPUP COMPLETE"
        .. " | AddGoodDispatched=" .. tostring(dispatchErr == nil)
        .. " | popupVisibleAfter=" .. tostring(popupVisibleAfter)
        .. " | next=if the popup appears after this log, press Ctrl+Alt+K once more")

    return finish(dispatchErr == nil)
end


function GoodsFinder:ProbeRememberedStationController()
    if self.stationControllerProbeRunning == true then
        log("STATIONCTRL IGNORED | probe already running")
        return false
    end

    self.stationControllerProbeRunning = true

    local function finish(result)
        self.stationControllerProbeRunning = false
        return result
    end

    local stage = tonumber(self.stationControllerProbeStage) or 1
    log("STATIONCTRL START"
        .. " | stage=" .. tostring(stage)
        .. " | stage1=root RequestStationFocus"
        .. " | stage2=StationOptionBtnEvent"
        .. " | no station.RequestFocus")

    local expectedGuid = tonumber(self.lastProductGuid) or 0
    local expectedName = tostring(self.lastProductName or "")
    local expectedIslandName = tostring(self.lastWarehouseAreaName or "")

    log("STATIONCTRL context"
        .. " | rememberedProductGUID=" .. tostring(expectedGuid)
        .. " | rememberedProductName=" .. expectedName
        .. " | rememberedIslandName=" .. expectedIslandName
        .. " | rememberedAreaID=" .. tostring(self.lastWarehouseAreaId))

    if expectedGuid <= 0 then
        log("STATIONCTRL ABORT | no remembered product; first use Ctrl+Alt+G over a warehouse good")
        return finish(false)
    end

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local popup = safe(function()
        return selection and selection.PopupData
    end)
    local popupVisible = safe(function()
        return popup and popup.IsVisible
    end)
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)

    log("STATIONCTRL live path"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | popupType=" .. tostring(type(popup))
        .. " | popupVisible=" .. tostring(popupVisible)
        .. " | routeValid=" .. tostring(routeValid))

    if routeValid ~= true then
        log("STATIONCTRL ABORT | no valid temporary route editor")
        return finish(false)
    end

    if popupVisible == true then
        log("STATIONCTRL popup already open | apply proven remembered-product hover")
        local result = self:ForceRememberedGoodHover()
        return finish(result)
    end

    local haloRoot = rawget(_G, "halo")

    local function getArrayHelper(value)
        if value == nil or type(haloRoot) ~= "table" then return nil, nil end
        local valueText = bindingSafeToString(value)
        local key = string.match(valueText, "^(PhoenixArray<[^>]+>)")
        if key ~= nil and type(haloRoot[key]) == "table" then
            return haloRoot[key], key
        end
        return nil, key
    end

    local function readArray(value, label)
        local result = {}
        local helper, helperKey = getArrayHelper(value)

        if type(helper) ~= "table"
            or type(helper.GetSize) ~= "function"
            or type(helper.GetElement) ~= "function" then
            log("STATIONCTRL ARRAY"
                .. " | label=" .. tostring(label)
                .. " | helperKey=" .. tostring(helperKey)
                .. " | helperUnavailable=true"
                .. " | value=" .. bindingSafeToString(value))
            return result
        end

        local size, sizeErr = safe(function()
            return helper.GetSize(value)
        end)

        log("STATIONCTRL ARRAY"
            .. " | label=" .. tostring(label)
            .. " | helperKey=" .. tostring(helperKey)
            .. " | size=" .. tostring(size)
            .. " | error=" .. tostring(sizeErr or ""))

        if type(size) == "number" and size >= 0 then
            local limit = math.min(math.floor(size), 256)
            for index = 0, limit - 1 do
                local item = safe(function()
                    return helper.GetElement(value, index)
                end)
                if item ~= nil then
                    result[#result + 1] = {
                        value = item,
                        arrayIndex = index
                    }
                end
            end
        end

        return result
    end

    local stationContainer = safe(function()
        return selection and selection.TradeRouteGoodData
    end)
    local stations = readArray(
        stationContainer,
        "TradeGoodSelection.TradeRouteGoodData"
    )

    local normalizedExpected = string.lower(expectedIslandName)
    local target = nil

    for _, entry in ipairs(stations) do
        local object = entry.value
        local islandName = safe(function() return object.IslandName end)
        local stationID = safe(function() return object.StationID end)
        local goodsFocusedIndex = safe(function() return object.GoodsFocusedIndex end)
        local stationOptionEvent = safe(function() return object.StationOptionBtnEvent end)
        local requestFocus = safe(function() return object.RequestFocus end)
        local loadUnload = safe(function() return object.TradeRouteLoadandUnloadData end)
        local matches = string.lower(tostring(islandName or "")) == normalizedExpected

        log("STATIONCTRL STATION"
            .. " | arrayIndex=" .. tostring(entry.arrayIndex)
            .. " | islandName=" .. tostring(islandName)
            .. " | stationID=" .. tostring(stationID)
            .. " | goodsFocusedIndex=" .. tostring(goodsFocusedIndex)
            .. " | requestFocusType=" .. tostring(type(requestFocus))
            .. " | stationOptionBtnEventType=" .. tostring(type(stationOptionEvent))
            .. " | stationOptionBtnEventValue=" .. bindingSafeToString(stationOptionEvent)
            .. " | loadUnloadType=" .. tostring(type(loadUnload))
            .. " | loadUnloadValue=" .. bindingSafeToString(loadUnload)
            .. " | matchesRememberedIsland=" .. tostring(matches))

        if matches then
            target = {
                object = object,
                arrayIndex = entry.arrayIndex,
                islandName = islandName,
                stationID = stationID,
                stationOptionEvent = stationOptionEvent,
                loadUnload = loadUnload
            }
        end
    end

    if target == nil then
        log("STATIONCTRL ABORT | remembered island was not found among route stations")
        return finish(false)
    end

    local function logSelectionState(label)
        local focusIndex = safe(function() return selection.GoodsIslandFocusIndex end)
        local hoverIndex = safe(function() return selection.GoodsIslandHoveredIndex end)
        local panelVisible = safe(function() return selection.IsPanelVisible end)
        local popupNow = safe(function() return popup.IsVisible end)

        log("STATIONCTRL STATE"
            .. " | label=" .. tostring(label)
            .. " | goodsIslandFocusIndex=" .. tostring(focusIndex)
            .. " | goodsIslandHoveredIndex=" .. tostring(hoverIndex)
            .. " | panelVisible=" .. tostring(panelVisible)
            .. " | popupVisible=" .. tostring(popupNow))
    end

    local function inspectGoodIslandArray(label)
        local currentArray = safe(function()
            return target.object.TradeRouteLoadandUnloadData
        end)
        local entries = readArray(currentArray, label)

        for _, entry in ipairs(entries) do
            local item = entry.value
            local bridge = safe(function() return item.Bridge end)
            local contextData = safe(function() return item.ContextData end)
            local bridgeVisible = safe(function() return item.IsBridgeVisible end)
            local highlighted = safe(function() return item.IsHighlighted end)
            local loadGoods = safe(function() return item.LoadGoods end)
            local unloadGoods = safe(function() return item.UnloadGoods end)

            log("STATIONCTRL GOODISLAND"
                .. " | source=" .. tostring(label)
                .. " | arrayIndex=" .. tostring(entry.arrayIndex)
                .. " | bridgeType=" .. tostring(type(bridge))
                .. " | bridgeValue=" .. bindingSafeToString(bridge)
                .. " | contextType=" .. tostring(type(contextData))
                .. " | contextValue=" .. bindingSafeToString(contextData)
                .. " | isBridgeVisible=" .. tostring(bridgeVisible)
                .. " | isHighlighted=" .. tostring(highlighted)
                .. " | loadGoodsType=" .. tostring(type(loadGoods))
                .. " | loadGoodsValue=" .. bindingSafeToString(loadGoods)
                .. " | unloadGoodsType=" .. tostring(type(unloadGoods))
                .. " | unloadGoodsValue=" .. bindingSafeToString(unloadGoods))
        end

        return #entries
    end

    logSelectionState("before stage action")
    local beforeCount = inspectGoodIslandArray("before stage action")

    if stage == 1 then
        local setFocusResult, setFocusErr = safe(function()
            selection.GoodsIslandFocusIndex = target.arrayIndex
            return selection.GoodsIslandFocusIndex
        end)
        log("STATIONCTRL WRITE"
            .. " | label=selection.GoodsIslandFocusIndex"
            .. " | requested=" .. tostring(target.arrayIndex)
            .. " | success=" .. tostring(setFocusErr == nil)
            .. " | result=" .. tostring(setFocusResult)
            .. " | error=" .. tostring(setFocusErr or ""))

        local setHoverResult, setHoverErr = safe(function()
            selection.GoodsIslandHoveredIndex = target.arrayIndex
            return selection.GoodsIslandHoveredIndex
        end)
        log("STATIONCTRL WRITE"
            .. " | label=selection.GoodsIslandHoveredIndex"
            .. " | requested=" .. tostring(target.arrayIndex)
            .. " | success=" .. tostring(setHoverErr == nil)
            .. " | result=" .. tostring(setHoverResult)
            .. " | error=" .. tostring(setHoverErr or ""))

        local requestStationFocus = safe(function()
            return selection.RequestStationFocus
        end)

        local dispatchMode = nil
        local dispatchResult = nil
        local dispatchErr = nil

        if type(requestStationFocus) == "function" then
            dispatchMode = "selection.RequestStationFocus(selection)"
            dispatchResult, dispatchErr = safe(function()
                return requestStationFocus(selection)
            end)

            if dispatchErr ~= nil then
                log("STATIONCTRL stage1 attempt failed"
                    .. " | mode=" .. tostring(dispatchMode)
                    .. " | error=" .. tostring(dispatchErr))
                dispatchMode = "selection.RequestStationFocus()"
                dispatchResult, dispatchErr = safe(function()
                    return requestStationFocus()
                end)
            end
        else
            dispatchErr = "RequestStationFocus is not a function"
        end

        log("STATIONCTRL STAGE1"
            .. " | action=RequestStationFocus"
            .. " | mode=" .. tostring(dispatchMode)
            .. " | success=" .. tostring(dispatchErr == nil)
            .. " | result=" .. bindingSafeToString(dispatchResult)
            .. " | error=" .. tostring(dispatchErr or ""))

        self.stationControllerProbeStage = 2
    else
        local event = safe(function()
            return target.object.StationOptionBtnEvent
        end)

        local dispatchMode = nil
        local dispatchResult = nil
        local dispatchErr = nil

        if type(event) == "function" then
            dispatchMode = "station.StationOptionBtnEvent(station)"
            dispatchResult, dispatchErr = safe(function()
                return event(target.object)
            end)

            if dispatchErr ~= nil then
                log("STATIONCTRL stage2 attempt failed"
                    .. " | mode=" .. tostring(dispatchMode)
                    .. " | error=" .. tostring(dispatchErr))
                dispatchMode = "station.StationOptionBtnEvent()"
                dispatchResult, dispatchErr = safe(function()
                    return event()
                end)
            end
        else
            dispatchErr = "StationOptionBtnEvent is not a function"
        end

        log("STATIONCTRL STAGE2"
            .. " | action=StationOptionBtnEvent"
            .. " | mode=" .. tostring(dispatchMode)
            .. " | success=" .. tostring(dispatchErr == nil)
            .. " | result=" .. bindingSafeToString(dispatchResult)
            .. " | error=" .. tostring(dispatchErr or ""))

        self.stationControllerProbeStage = 1
    end

    logSelectionState("after stage action")
    local afterCount = inspectGoodIslandArray("after stage action")

    local popupAfter = safe(function()
        return popup and popup.IsVisible
    end)

    if popupAfter == true then
        log("STATIONCTRL popup opened | apply proven remembered-product hover")
        local overlayResult = self:ForceRememberedGoodHover()
        log("STATIONCTRL overlay result | success=" .. tostring(overlayResult))
        return finish(overlayResult)
    end

    log("STATIONCTRL COMPLETE"
        .. " | stageExecuted=" .. tostring(stage)
        .. " | rememberedStationArrayIndex=" .. tostring(target.arrayIndex)
        .. " | rememberedStationID=" .. tostring(target.stationID)
        .. " | goodIslandCountBefore=" .. tostring(beforeCount)
        .. " | goodIslandCountAfter=" .. tostring(afterCount)
        .. " | popupVisibleAfter=" .. tostring(popupAfter)
        .. " | nextStage=" .. tostring(self.stationControllerProbeStage)
        .. " | routeProductSelection=false")

    return finish(true)
end


function GoodsFinder:OpenRememberedLoadGoodsPopup()
    if self.directLoadGoodsProbeRunning == true then
        log("DIRECTLOAD IGNORED | probe already running")
        return false
    end

    self.directLoadGoodsProbeRunning = true

    local function finish(result)
        self.directLoadGoodsProbeRunning = false
        return result
    end

    log("DIRECTLOAD START | focus remembered station and invoke its LoadGoods.AddGood method")

    local expectedGuid = tonumber(self.lastProductGuid) or 0
    local expectedName = tostring(self.lastProductName or "")
    local expectedIslandName = tostring(self.lastWarehouseAreaName or "")

    log("DIRECTLOAD context"
        .. " | rememberedProductGUID=" .. tostring(expectedGuid)
        .. " | rememberedProductName=" .. expectedName
        .. " | rememberedIslandName=" .. expectedIslandName
        .. " | rememberedAreaID=" .. tostring(self.lastWarehouseAreaId))

    log("DIRECTLOAD PRESELECTION"
        .. " | enabled=" .. tostring(expectedGuid > 0)
        .. " | productGUID=" .. tostring(expectedGuid)
        .. " | productName=" .. tostring(expectedName)
        .. " | behavior="
            .. tostring(
                expectedGuid > 0
                    and "auto-focus remembered product"
                    or "open full goods list without preselection"
            ))

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local popup = safe(function()
        return selection and selection.PopupData
    end)
    local popupVisible = safe(function()
        return popup and popup.IsVisible
    end)
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)

    log("DIRECTLOAD live path"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | popupType=" .. tostring(type(popup))
        .. " | popupVisible=" .. tostring(popupVisible)
        .. " | routeValid=" .. tostring(routeValid))

    if routeValid ~= true then
        log("DIRECTLOAD ABORT | no valid temporary route editor")
        return finish(false)
    end

    if popupVisible == true then
        log("DIRECTLOAD popup already open | apply proven remembered-product hover")
        local overlayResult = self:ForceRememberedGoodHover()
        log("DIRECTLOAD overlay result | success=" .. tostring(overlayResult))
        return finish(overlayResult)
    end

    local haloRoot = rawget(_G, "halo")

    local function getArrayHelper(value)
        if value == nil or type(haloRoot) ~= "table" then
            return nil, nil
        end

        local text = bindingSafeToString(value)
        local key = string.match(text, "^(PhoenixArray<[^>]+>)")

        if key ~= nil and type(haloRoot[key]) == "table" then
            return haloRoot[key], key
        end

        return nil, key
    end

    local function readArray(value, label)
        local result = {}
        local helper, helperKey = getArrayHelper(value)

        if type(helper) ~= "table"
            or type(helper.GetSize) ~= "function"
            or type(helper.GetElement) ~= "function" then
            log("DIRECTLOAD ARRAY"
                .. " | label=" .. tostring(label)
                .. " | helperKey=" .. tostring(helperKey)
                .. " | helperUnavailable=true"
                .. " | value=" .. bindingSafeToString(value))
            return result
        end

        local size, sizeErr = safe(function()
            return helper.GetSize(value)
        end)

        log("DIRECTLOAD ARRAY"
            .. " | label=" .. tostring(label)
            .. " | helperKey=" .. tostring(helperKey)
            .. " | size=" .. tostring(size)
            .. " | error=" .. tostring(sizeErr or ""))

        if type(size) == "number" and size >= 0 then
            local limit = math.min(math.floor(size), 256)
            for index = 0, limit - 1 do
                local item = safe(function()
                    return helper.GetElement(value, index)
                end)

                if item ~= nil then
                    result[#result + 1] = {
                        value = item,
                        arrayIndex = index
                    }
                end
            end
        end

        return result
    end

    local stationContainer = safe(function()
        return selection and selection.TradeRouteGoodData
    end)
    local stations = readArray(
        stationContainer,
        "TradeGoodSelection.TradeRouteGoodData"
    )

    local normalizedExpected = string.lower(expectedIslandName)
    local helperStationIndex =
        tonumber(self.existingRouteHelperStationIndex)
    local targetStation = nil

    for _, entry in ipairs(stations) do
        local object = entry.value
        local islandName = safe(function() return object.IslandName end)
        local stationID = safe(function() return object.StationID end)
        local matches =
            string.lower(tostring(islandName or ""))
                == normalizedExpected
        local matchesHelper =
            helperStationIndex ~= nil
                and tonumber(entry.arrayIndex)
                    == helperStationIndex

        log("DIRECTLOAD STATION"
            .. " | arrayIndex=" .. tostring(entry.arrayIndex)
            .. " | islandName=" .. tostring(islandName)
            .. " | stationID=" .. tostring(stationID)
            .. " | matchesRememberedIsland="
                .. tostring(matches)
            .. " | matchesHelperStation="
                .. tostring(matchesHelper))

        if matchesHelper
            or (helperStationIndex == nil and matches) then
            targetStation = {
                object = object,
                arrayIndex = entry.arrayIndex,
                islandName = islandName,
                stationID = stationID
            }
        end
    end

    if targetStation == nil then
        log("DIRECTLOAD ABORT | selected helper station was not found among route stations")
        return finish(false)
    end

    local focusWrite, focusWriteErr = safe(function()
        selection.GoodsIslandFocusIndex = targetStation.arrayIndex
        return selection.GoodsIslandFocusIndex
    end)

    log("DIRECTLOAD WRITE"
        .. " | label=selection.GoodsIslandFocusIndex"
        .. " | requested=" .. tostring(targetStation.arrayIndex)
        .. " | success=" .. tostring(focusWriteErr == nil)
        .. " | result=" .. tostring(focusWrite)
        .. " | error=" .. tostring(focusWriteErr or ""))

    local hoverWrite, hoverWriteErr = safe(function()
        selection.GoodsIslandHoveredIndex = targetStation.arrayIndex
        return selection.GoodsIslandHoveredIndex
    end)

    log("DIRECTLOAD WRITE"
        .. " | label=selection.GoodsIslandHoveredIndex"
        .. " | requested=" .. tostring(targetStation.arrayIndex)
        .. " | success=" .. tostring(hoverWriteErr == nil)
        .. " | result=" .. tostring(hoverWrite)
        .. " | error=" .. tostring(hoverWriteErr or ""))

    local requestStationFocus = safe(function()
        return selection.RequestStationFocus
    end)

    local stationFocusMode = nil
    local stationFocusResult = nil
    local stationFocusErr = nil

    if type(requestStationFocus) == "function" then
        stationFocusMode = "selection.RequestStationFocus(selection)"
        stationFocusResult, stationFocusErr = safe(function()
            return requestStationFocus(selection)
        end)

        if stationFocusErr ~= nil then
            log("DIRECTLOAD station focus attempt failed"
                .. " | mode=" .. tostring(stationFocusMode)
                .. " | error=" .. tostring(stationFocusErr))
            stationFocusMode = "selection.RequestStationFocus()"
            stationFocusResult, stationFocusErr = safe(function()
                return requestStationFocus()
            end)
        end
    else
        stationFocusErr = "RequestStationFocus is not a function"
    end

    log("DIRECTLOAD station focus"
        .. " | mode=" .. tostring(stationFocusMode)
        .. " | success=" .. tostring(stationFocusErr == nil)
        .. " | result=" .. bindingSafeToString(stationFocusResult)
        .. " | error=" .. tostring(stationFocusErr or ""))

    local goodIslandContainer = safe(function()
        return targetStation.object.TradeRouteLoadandUnloadData
    end)
    local goodIslands = readArray(
        goodIslandContainer,
        "HelperStation.TradeRouteLoadandUnloadData"
    )

    if #goodIslands == 0 then
        log("DIRECTLOAD ABORT | helper station has no TradeRouteGoodIslandData entry")
        return finish(false)
    end

    local targetGoodIslandEntry = nil
    local selectionMode = nil

    for _, entry in ipairs(goodIslands) do
        local candidate = entry.value
        local candidateLoad = safe(function() return candidate and candidate.LoadGoods end)
        local candidateAddGood = safe(function() return candidateLoad and candidateLoad.AddGood end)
        local candidateLoaded = safe(function() return candidateLoad and candidateLoad.IsGoodLoaded end)
        local candidateImage = safe(function() return candidateLoad and candidateLoad.GoodImageID end)
        local candidateAmount = safe(function() return candidateLoad and candidateLoad.Amount end)
        local candidateVisible = safe(function() return candidateLoad and candidateLoad.IsBtnVisible end)
        local usable = candidateLoad ~= nil and type(candidateAddGood) == "function"
        local empty = usable and candidateLoaded ~= true

        log("DIRECTLOAD ROW CANDIDATE"
            .. " | arrayIndex=" .. tostring(entry.arrayIndex)
            .. " | usable=" .. tostring(usable)
            .. " | empty=" .. tostring(empty)
            .. " | isGoodLoaded=" .. tostring(candidateLoaded)
            .. " | amount=" .. tostring(candidateAmount)
            .. " | goodImageID=" .. tostring(candidateImage)
            .. " | isBtnVisible=" .. tostring(candidateVisible)
            .. " | addGoodType=" .. tostring(type(candidateAddGood)))

        if empty and targetGoodIslandEntry == nil then
            targetGoodIslandEntry = entry
            selectionMode = "empty-load-row"
        end
    end

    if targetGoodIslandEntry == nil then
        log("DIRECTLOAD ABORT | helper station has no empty usable LoadGoods row; occupied cargo instructions are never used as a doorway")
        return finish(false)
    end

    local targetGoodIsland = targetGoodIslandEntry.value
    local loadGoods = safe(function() return targetGoodIsland.LoadGoods end)
    local unloadGoods = safe(function() return targetGoodIsland.UnloadGoods end)
    local highlighted = safe(function() return targetGoodIsland.IsHighlighted end)
    local bridgeVisible = safe(function() return targetGoodIsland.IsBridgeVisible end)

    local loadAddGood = safe(function() return loadGoods and loadGoods.AddGood end)
    local loadAmount = safe(function() return loadGoods and loadGoods.Amount end)
    local loadIndex = safe(function() return loadGoods and loadGoods.Index end)
    local loadStationId = safe(function() return loadGoods and loadGoods.StationId end)
    local loadBtnVisible = safe(function() return loadGoods and loadGoods.IsBtnVisible end)
    local loadBtnSelected = safe(function() return loadGoods and loadGoods.IsBtnSelected end)
    local loadFocused = safe(function() return loadGoods and loadGoods.IsFocused end)
    local loadHovered = safe(function() return loadGoods and loadGoods.IsHovered end)
    local loadGoodLoaded = safe(function() return loadGoods and loadGoods.IsGoodLoaded end)
    local loadGoodImageID = safe(function() return loadGoods and loadGoods.GoodImageID end)

    local unloadAddGood = safe(function() return unloadGoods and unloadGoods.AddGood end)

    self.directLoadSelectedRowIndex = targetGoodIslandEntry.arrayIndex
    self.directLoadSelectedRowWasEmpty = selectionMode == "empty-load-row"

    log("DIRECTLOAD ROW TRACKED"
        .. " | arrayIndex=" .. tostring(self.directLoadSelectedRowIndex)
        .. " | originallyEmpty=" .. tostring(self.directLoadSelectedRowWasEmpty)
        .. " | purpose=inspect or remove only this temporary row after popup closes")

    log("DIRECTLOAD ROW SELECTED"
        .. " | arrayIndex=" .. tostring(targetGoodIslandEntry.arrayIndex)
        .. " | selectionMode=" .. tostring(selectionMode)
        .. " | protectsOccupiedRows=" .. tostring(selectionMode == "empty-load-row")
        .. " | isGoodLoaded=" .. tostring(loadGoodLoaded)
        .. " | amount=" .. tostring(loadAmount)
        .. " | goodImageID=" .. tostring(loadGoodImageID))

    log("DIRECTLOAD GOODISLAND"
        .. " | arrayIndex=" .. tostring(targetGoodIslandEntry.arrayIndex)
        .. " | isHighlighted=" .. tostring(highlighted)
        .. " | isBridgeVisible=" .. tostring(bridgeVisible)
        .. " | loadGoodsType=" .. tostring(type(loadGoods))
        .. " | loadGoodsValue=" .. bindingSafeToString(loadGoods)
        .. " | unloadGoodsType=" .. tostring(type(unloadGoods))
        .. " | unloadGoodsValue=" .. bindingSafeToString(unloadGoods))

    log("DIRECTLOAD LOADDATA"
        .. " | index=" .. tostring(loadIndex)
        .. " | stationId=" .. tostring(loadStationId)
        .. " | amount=" .. tostring(loadAmount)
        .. " | isBtnVisible=" .. tostring(loadBtnVisible)
        .. " | isBtnSelected=" .. tostring(loadBtnSelected)
        .. " | isFocused=" .. tostring(loadFocused)
        .. " | isHovered=" .. tostring(loadHovered)
        .. " | isGoodLoaded=" .. tostring(loadGoodLoaded)
        .. " | goodImageID=" .. tostring(loadGoodImageID)
        .. " | addGoodType=" .. tostring(type(loadAddGood))
        .. " | unloadAddGoodType=" .. tostring(type(unloadAddGood)))

    if loadGoods == nil then
        log("DIRECTLOAD ABORT | LoadGoods object is unavailable")
        return finish(false)
    end

    local focusLoadResult, focusLoadErr = safe(function()
        loadGoods.IsFocused = true
        return loadGoods.IsFocused
    end)

    log("DIRECTLOAD WRITE"
        .. " | label=LoadGoods.IsFocused=true"
        .. " | success=" .. tostring(focusLoadErr == nil)
        .. " | result=" .. tostring(focusLoadResult)
        .. " | error=" .. tostring(focusLoadErr or ""))

    local hoverLoadResult, hoverLoadErr = safe(function()
        loadGoods.IsHovered = true
        return loadGoods.IsHovered
    end)

    log("DIRECTLOAD WRITE"
        .. " | label=LoadGoods.IsHovered=true"
        .. " | success=" .. tostring(hoverLoadErr == nil)
        .. " | result=" .. tostring(hoverLoadResult)
        .. " | error=" .. tostring(hoverLoadErr or ""))

    local dispatchMode = nil
    local dispatchResult = nil
    local dispatchErr = nil

    if type(loadAddGood) == "function" then
        dispatchMode = "LoadGoods.AddGood(loadGoods)"
        dispatchResult, dispatchErr = safe(function()
            return loadAddGood(loadGoods)
        end)

        if dispatchErr ~= nil then
            log("DIRECTLOAD AddGood attempt failed"
                .. " | mode=" .. tostring(dispatchMode)
                .. " | error=" .. tostring(dispatchErr))
            dispatchMode = "LoadGoods.AddGood()"
            dispatchResult, dispatchErr = safe(function()
                return loadAddGood()
            end)
        end
    else
        dispatchErr = "LoadGoods.AddGood is not a function"
    end

    if dispatchErr ~= nil and type(haloRoot) == "table" then
        local helper = haloRoot["TradeRouteLoadAndUnloadData"]
        if type(helper) == "table" and type(helper.AddGood) == "function" then
            log("DIRECTLOAD AddGood attempt failed"
                .. " | mode=" .. tostring(dispatchMode)
                .. " | error=" .. tostring(dispatchErr))
            dispatchMode = "TradeRouteLoadAndUnloadData.AddGood(loadGoods)"
            dispatchResult, dispatchErr = safe(function()
                return helper.AddGood(loadGoods)
            end)
        end
    end

    log("DIRECTLOAD AddGood dispatch"
        .. " | mode=" .. tostring(dispatchMode)
        .. " | success=" .. tostring(dispatchErr == nil)
        .. " | result=" .. bindingSafeToString(dispatchResult)
        .. " | error=" .. tostring(dispatchErr or ""))

    local popupVisibleAfter = safe(function()
        return popup and popup.IsVisible
    end)

    log("DIRECTLOAD popup result"
        .. " | popupVisibleAfter=" .. tostring(popupVisibleAfter))

    if popupVisibleAfter == true then
        self.autoGoodsHoverPending = false
        self.autoGoodsHoverTickCounter = 0
        self.autoGoodsHoverLogged = false

        if expectedGuid > 0 then
            log("DIRECTLOAD popup opened immediately | apply remembered-product preselection")
            local overlayResult = self:ForceRememberedGoodHover()
            log("DIRECTLOAD overlay result | success=" .. tostring(overlayResult))
            return finish(overlayResult)
        end

        log("WAREHOUSEMODE POPUP READY"
            .. " | preselection=false"
            .. " | popupVisible=true"
            .. " | behavior=user may hover any product; warehouse is not required")

        self.autoReturnPending = true
        self.autoReturnSawPopup = true
        self.autoReturnTickCounter = 0
        self.autoReturnCloseTickCounter = 0
        self.autoReturnLogged = false
        self.nativeCloseBaselineSignature =
            nativeCloseHelperRowsSnapshot(self, "baseline")
        self.nativeClosePrecloseSignature = nil

        log("AUTORETURN MONITOR START"
            .. " | popupVisible=true"
            .. " | routeValid=true"
            .. " | behavior=warehouse-only mode; one Escape closes popup, then tracked empty row cleanup and native Trade Route close")

        return finish(true)
    end

    if dispatchErr == nil then
        self.autoGoodsHoverPending = true
        self.autoGoodsHoverTickCounter = 0
        self.autoGoodsHoverLogged = false
    end

    log("DIRECTLOAD COMPLETE"
        .. " | rememberedStationArrayIndex=" .. tostring(targetStation.arrayIndex)
        .. " | rememberedStationID=" .. tostring(targetStation.stationID)
        .. " | goodIslandEntries=" .. tostring(#goodIslands)
        .. " | AddGoodDispatched=" .. tostring(dispatchErr == nil)
        .. " | popupVisibleAfter=" .. tostring(popupVisibleAfter)
        .. " | delayedHoverPending=" .. tostring(self.autoGoodsHoverPending == true)
        .. " | next=Tick waits for popup; remembered product is preselected only when available")

    return finish(dispatchErr == nil)
end


function GoodsFinder:OpenMapAndCreateRoute()
    log("AUTOCREATE START | capture stock, open Trade Route overview, and press the vanilla Create Route button")

    local product = captureAndLogStock()
    if product == nil then
        log("AUTOCREATE ABORT | no valid warehouse product detected")
        return false
    end

    captureWarehouseArea()

    local openResult, openErr = safe(function()
        Scripts:ToggleTraderouteMenu()
        return true
    end)

    log("AUTOCREATE map open"
        .. " | success=" .. tostring(openResult == true)
        .. " | error=" .. tostring(openErr or "")
        .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | productName=" .. tostring(self.lastProductName or "")
        .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or ""))

    if openResult ~= true then
        return false
    end

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local createVisible = safe(function()
        return selection and selection.IsCreateRouteBtnVisible
    end)
    local createEvent = safe(function()
        return selection and selection.CreateRouteBtn_Pressed
    end)

    local routeBefore = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValidBefore = safe(function()
        return routeBefore and routeBefore:isValid()
    end)

    log("AUTOCREATE controller"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | createButtonVisible=" .. tostring(createVisible)
        .. " | createEventType=" .. tostring(type(createEvent))
        .. " | routeValidBefore=" .. tostring(routeValidBefore))

    if selection == nil or type(createEvent) ~= "function" then
        log("AUTOCREATE ABORT | CreateRouteBtn_Pressed is unavailable; use Ctrl+Alt+N as fallback")
        return false
    end

    local dispatchMode = "selection.CreateRouteBtn_Pressed(selection)"
    local dispatchResult, dispatchErr = safe(function()
        return createEvent(selection)
    end)

    if dispatchErr ~= nil then
        log("AUTOCREATE dispatch attempt failed"
            .. " | mode=" .. tostring(dispatchMode)
            .. " | error=" .. tostring(dispatchErr))

        dispatchMode = "selection.CreateRouteBtn_Pressed()"
        dispatchResult, dispatchErr = safe(function()
            return createEvent()
        end)
    end

    if dispatchErr ~= nil then
        local haloRoot = rawget(_G, "halo")
        local helper = type(haloRoot) == "table"
            and haloRoot["TradeRouteGoodSelectionData"]
            or nil

        if type(helper) == "table"
            and type(helper.CreateRouteBtn_Pressed) == "function" then

            log("AUTOCREATE dispatch attempt failed"
                .. " | mode=" .. tostring(dispatchMode)
                .. " | error=" .. tostring(dispatchErr))

            dispatchMode = "TradeRouteGoodSelectionData.CreateRouteBtn_Pressed(selection)"
            dispatchResult, dispatchErr = safe(function()
                return helper.CreateRouteBtn_Pressed(selection)
            end)
        end
    end

    local routeAfter = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValidAfter = safe(function()
        return routeAfter and routeAfter:isValid()
    end)
    local routeNameAfter = safe(function()
        return routeAfter and routeAfter.Name
    end)

    log("AUTOCREATE COMPLETE"
        .. " | mode=" .. tostring(dispatchMode)
        .. " | dispatchSuccess=" .. tostring(dispatchErr == nil)
        .. " | result=" .. bindingSafeToString(dispatchResult)
        .. " | error=" .. tostring(dispatchErr or "")
        .. " | routeValidImmediate=" .. tostring(routeValidAfter)
        .. " | routeNameImmediate=" .. tostring(routeNameAfter)
        .. " | next=choose a temporary ship, add remembered island plus second island, then press Ctrl+Alt+K")

    return dispatchErr == nil
end


function GoodsFinder:OpenMapAndQueueNewRoute()
    log("QUEUECREATE START | capture/open if needed, then queue vanilla New Trade Route gamepad action 321")

    local editRouteBefore = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local editRouteValidBefore = safe(function()
        return editRouteBefore and editRouteBefore:isValid()
    end)

    if editRouteValidBefore == true then
        log("QUEUECREATE COMPLETE | route editor is already valid; no new-route action sent")
        return true
    end

    local capturedNow = false
    local product = captureAndLogStock()

    if product ~= nil then
        capturedNow = true
        captureWarehouseArea()

        local openResult, openErr = safe(function()
            Scripts:ToggleTraderouteMenu()
            return true
        end)

        log("QUEUECREATE map open"
            .. " | success=" .. tostring(openResult == true)
            .. " | error=" .. tostring(openErr or "")
            .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
            .. " | productName=" .. tostring(self.lastProductName or "")
            .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
            .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or ""))

        if openResult ~= true then
            return false
        end

        self.queuedCreatePending = true
    elseif (tonumber(self.lastProductGuid) or 0) > 0
        and self.queuedCreatePending == true then

        log("QUEUECREATE retry"
            .. " | no warehouse product under cursor"
            .. " | reuseRememberedProduct=true"
            .. " | productGUID=" .. tostring(self.lastProductGuid)
            .. " | productName=" .. tostring(self.lastProductName or "")
            .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or ""))
    else
        log("QUEUECREATE ABORT | no valid warehouse product detected and no pending remembered workflow")
        return false
    end

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local createVisible = safe(function()
        return selection and selection.IsCreateRouteBtnVisible
    end)
    local panelVisible = safe(function()
        return selection and selection.IsPanelVisible
    end)

    log("QUEUECREATE readiness"
        .. " | capturedNow=" .. tostring(capturedNow)
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | panelVisible=" .. tostring(panelVisible)
        .. " | createButtonVisible=" .. tostring(createVisible)
        .. " | action321Available=" .. tostring(
            type(AutomatedTest) == "table"
            and type(AutomatedTest.SendFakeGamepadEvents) == "function"
        ))

    if type(AutomatedTest) ~= "table"
        or type(AutomatedTest.SendFakeGamepadEvents) ~= "function" then
        log("QUEUECREATE ABORT | AutomatedTest.SendFakeGamepadEvents is unavailable")
        return false
    end

    local dispatchResult, dispatchErr = safe(function()
        AutomatedTest:SendFakeGamepadEvents({321}, {0})
        return true
    end)

    local editRouteAfter = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local editRouteValidAfter = safe(function()
        return editRouteAfter and editRouteAfter:isValid()
    end)
    local editRouteNameAfter = safe(function()
        return editRouteAfter and editRouteAfter.Name
    end)

    log("QUEUECREATE COMPLETE"
        .. " | action=321"
        .. " | dispatchSuccess=" .. tostring(dispatchResult == true)
        .. " | error=" .. tostring(dispatchErr or "")
        .. " | routeValidImmediate=" .. tostring(editRouteValidAfter)
        .. " | routeNameImmediate=" .. tostring(editRouteNameAfter)
        .. " | pendingRetryAllowed=true"
        .. " | next=wait three seconds; if editor did not open, press Ctrl+Alt+G once more")

    return dispatchResult == true
end


function GoodsFinder:OpenMapThenCreateRoute()
    local editRouteBefore = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local editRouteValidBefore = safe(function()
        return editRouteBefore and editRouteBefore:isValid()
    end)

    if editRouteValidBefore == true then
        self.twoStageCreatePending = false
        log("TWOSTAGE COMPLETE | route editor is already valid; pending state cleared")
        return true
    end

    if self.twoStageCreatePending ~= true then
        log("TWOSTAGE STAGE1 | capture warehouse product and open Trade Route overview only")

        local product = captureAndLogStock()
        if product == nil then
            log("TWOSTAGE ABORT | no valid warehouse product detected")
            return false
        end

        captureWarehouseArea()

        local openResult, openErr = safe(function()
            Scripts:ToggleTraderouteMenu()
            return true
        end)

        if openResult == true then
            self.twoStageCreatePending = true
            self.twoStageCreateAttempts = 0
        end

        local scene = safe(function()
            return ui and ui.Scenes and ui.Scenes.TradeRoute
        end)
        local selection = safe(function()
            return scene and scene.TradeGoodSelection
        end)

        log("TWOSTAGE STAGE1 COMPLETE"
            .. " | openSuccess=" .. tostring(openResult == true)
            .. " | error=" .. tostring(openErr or "")
            .. " | sceneType=" .. tostring(type(scene))
            .. " | selectionType=" .. tostring(type(selection))
            .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
            .. " | productName=" .. tostring(self.lastProductName or "")
            .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
            .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or "")
            .. " | pending=" .. tostring(self.twoStageCreatePending == true)
            .. " | next=wait two seconds and press Ctrl+Alt+G again")

        return openResult == true
    end

    log("TWOSTAGE STAGE2 | reuse remembered product and send vanilla New Trade Route action 321 without toggling the menu")

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local panelVisible = safe(function()
        return selection and selection.IsPanelVisible
    end)
    local createVisible = safe(function()
        return selection and selection.IsCreateRouteBtnVisible
    end)

    self.twoStageCreateAttempts = (tonumber(self.twoStageCreateAttempts) or 0) + 1

    if type(AutomatedTest) ~= "table"
        or type(AutomatedTest.SendFakeGamepadEvents) ~= "function" then
        log("TWOSTAGE ABORT"
            .. " | stage=2"
            .. " | reason=AutomatedTest.SendFakeGamepadEvents unavailable"
            .. " | pendingRetained=true")
        return false
    end

    local dispatchResult, dispatchErr = safe(function()
        AutomatedTest:SendFakeGamepadEvents({321}, {0})
        return true
    end)

    local editRouteAfter = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local editRouteValidAfter = safe(function()
        return editRouteAfter and editRouteAfter:isValid()
    end)
    local editRouteNameAfter = safe(function()
        return editRouteAfter and editRouteAfter.Name
    end)

    if editRouteValidAfter == true then
        self.twoStageCreatePending = false
    end

    log("TWOSTAGE STAGE2 COMPLETE"
        .. " | attempt=" .. tostring(self.twoStageCreateAttempts)
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | panelVisible=" .. tostring(panelVisible)
        .. " | createButtonVisible=" .. tostring(createVisible)
        .. " | action=321"
        .. " | dispatchSuccess=" .. tostring(dispatchResult == true)
        .. " | error=" .. tostring(dispatchErr or "")
        .. " | routeValidImmediate=" .. tostring(editRouteValidAfter)
        .. " | routeNameImmediate=" .. tostring(editRouteNameAfter)
        .. " | pending=" .. tostring(self.twoStageCreatePending == true)
        .. " | menuToggled=false"
        .. " | next=wait three seconds; repeat Ctrl+Alt+G only if editor remains closed")

    return dispatchResult == true
end



local function recorderLogValue(label, value)
    local text = tostring(value)
    local length = #text
    if length == 0 then
        log("RECORDER OUTPUT VALUE | label=" .. tostring(label) .. " | type=" .. tostring(type(value)) .. " | length=0 | value=")
        return
    end

    local chunkSize = 700
    local part = 1
    local position = 1
    while position <= length do
        local chunk = string.sub(text, position, position + chunkSize - 1)
        log("RECORDER OUTPUT VALUE"
            .. " | label=" .. tostring(label)
            .. " | type=" .. tostring(type(value))
            .. " | length=" .. tostring(length)
            .. " | part=" .. tostring(part)
            .. " | value=" .. chunk)
        position = position + chunkSize
        part = part + 1
    end
end

function GoodsFinder:DumpRecorderOutputSurface(context)
    log("RECORDER OUTPUT SURFACE START | context=" .. tostring(context or ""))

    if type(AutomatedTest) ~= "table" then
        log("RECORDER OUTPUT SURFACE ABORT | AutomatedTestType=" .. tostring(type(AutomatedTest)))
        return false
    end

    local interesting = {}
    local iterateOk, iterateErr = pcall(function()
        for key, value in pairs(AutomatedTest) do
            local keyText = tostring(key)
            local lower = string.lower(keyText)
            if string.find(lower, "snippet", 1, true)
                or string.find(lower, "record", 1, true)
                or string.find(lower, "clipboard", 1, true)
                or string.find(lower, "interaction", 1, true)
                or string.find(lower, "input", 1, true)
                or string.find(lower, "event", 1, true)
                or string.find(lower, "mouse", 1, true)
                or string.find(lower, "ui", 1, true) then
                table.insert(interesting, keyText .. ":" .. tostring(type(value)))
            end
        end
    end)

    table.sort(interesting)

    log("RECORDER OUTPUT SURFACE KEYS"
        .. " | iterateSuccess=" .. tostring(iterateOk)
        .. " | error=" .. tostring(iterateErr or "")
        .. " | count=" .. tostring(#interesting))

    if #interesting == 0 then
        log("RECORDER OUTPUT SURFACE KEYCHUNK | none")
    else
        local chunk = {}
        local chunkNumber = 1
        for _, entry in ipairs(interesting) do
            table.insert(chunk, entry)
            if #chunk >= 8 then
                log("RECORDER OUTPUT SURFACE KEYCHUNK"
                    .. " | chunk=" .. tostring(chunkNumber)
                    .. " | values=" .. table.concat(chunk, " ; "))
                chunk = {}
                chunkNumber = chunkNumber + 1
            end
        end
        if #chunk > 0 then
            log("RECORDER OUTPUT SURFACE KEYCHUNK"
                .. " | chunk=" .. tostring(chunkNumber)
                .. " | values=" .. table.concat(chunk, " ; "))
        end
    end

    local meta = getmetatable(AutomatedTest)
    log("RECORDER OUTPUT METATABLE | type=" .. tostring(type(meta)) .. " | value=" .. tostring(meta))
    if type(meta) == "table" then
        local metaEntries = {}
        local metaOk, metaErr = pcall(function()
            for key, value in pairs(meta) do
                local keyText = tostring(key)
                local lower = string.lower(keyText)
                if string.find(lower, "snippet", 1, true)
                    or string.find(lower, "record", 1, true)
                    or string.find(lower, "clipboard", 1, true)
                    or string.find(lower, "interaction", 1, true)
                    or string.find(lower, "input", 1, true)
                    or string.find(lower, "event", 1, true)
                    or string.find(lower, "mouse", 1, true)
                    or string.find(lower, "ui", 1, true) then
                    table.insert(metaEntries, keyText .. ":" .. tostring(type(value)))
                end
            end
        end)
        table.sort(metaEntries)
        log("RECORDER OUTPUT METAKEYS"
            .. " | iterateSuccess=" .. tostring(metaOk)
            .. " | error=" .. tostring(metaErr or "")
            .. " | count=" .. tostring(#metaEntries)
            .. " | values=" .. table.concat(metaEntries, " ; "))
    end

    local propertyCandidates = {
        "LastSnippet",
        "RecordedSnippet",
        "Snippet",
        "SnippetRecording",
        "SnippetRecordingResult",
        "LastRecording",
        "RecordingResult",
        "ClipboardText"
    }

    for _, name in ipairs(propertyCandidates) do
        local value, err = safe(function()
            return AutomatedTest[name]
        end)
        log("RECORDER OUTPUT PROPERTY"
            .. " | name=" .. tostring(name)
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. tostring(value)
            .. " | error=" .. tostring(err or ""))
        if value ~= nil and type(value) ~= "function" then
            recorderLogValue("property." .. name, value)
        end
    end

    local getterCandidates = {
        "GetLastSnippet",
        "GetRecordedSnippet",
        "GetSnippet",
        "GetSnippetRecording",
        "GetSnippetRecordingResult",
        "GetLastRecording",
        "GetRecordingResult",
        "GetClipboardText"
    }

    for _, name in ipairs(getterCandidates) do
        local fn = AutomatedTest[name]
        log("RECORDER OUTPUT GETTER"
            .. " | name=" .. tostring(name)
            .. " | type=" .. tostring(type(fn))
            .. " | value=" .. tostring(fn))

        if type(fn) == "function" then
            local value, err = safe(function()
                return fn(AutomatedTest)
            end)
            local mode = name .. "(AutomatedTest)"

            if err ~= nil then
                value, err = safe(function()
                    return fn()
                end)
                mode = name .. "()"
            end

            log("RECORDER OUTPUT GETTER RESULT"
                .. " | name=" .. tostring(name)
                .. " | mode=" .. tostring(mode)
                .. " | success=" .. tostring(err == nil)
                .. " | returnType=" .. tostring(type(value))
                .. " | returnValue=" .. tostring(value)
                .. " | error=" .. tostring(err or ""))

            if err == nil and value ~= nil then
                recorderLogValue("getter." .. name, value)
            end
        end
    end

    local globals = {
        "Clipboard",
        "SystemClipboard",
        "WindowsClipboard",
        "UIClipboard"
    }
    for _, name in ipairs(globals) do
        local value = rawget(_G, name)
        log("RECORDER OUTPUT GLOBAL"
            .. " | name=" .. tostring(name)
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. tostring(value))
    end

    log("RECORDER OUTPUT SURFACE COMPLETE | context=" .. tostring(context or ""))
    return true
end

function GoodsFinder:ToggleInteractionRecording()
    if self.snippetRecordingActive == true then
        log("INTERACTION TOGGLE | action=stop")
        return self:StopInteractionRecording()
    end

    log("INTERACTION TOGGLE | action=start")
    return self:StartInteractionRecording()
end


local function createSurfaceInspectResult(label, value)
    log("CREATE SURFACE RESULT"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(value))
        .. " | value=" .. bindingSafeToString(value))

    if type(value) == "table" then
        bindingInspectTable(value, "CREATE_SURFACE." .. tostring(label), 0, {})
    elseif type(value) == "userdata" then
        local mt = safe(function() return getmetatable(value) end)
        if type(mt) == "table" then
            bindingInspectTable(mt, "CREATE_SURFACE." .. tostring(label) .. ".metatable", 0, {})
        end
    end
end

function GoodsFinder:ProbeTradeRouteControllerSurface()
    log("CREATE SURFACE START | inspect overview/editor controller bindings without invoking route actions")

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)

    log("CREATE SURFACE ROOT"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | sceneValue=" .. bindingSafeToString(scene)
        .. " | selectionType=" .. tostring(type(selection))
        .. " | selectionValue=" .. bindingSafeToString(selection)
        .. " | routeType=" .. tostring(type(route))
        .. " | routeValid=" .. tostring(routeValid))

    local sceneCandidates = {
        "CreateNewTradeRoute",
        "CreateTradeRoute",
        "NewTradeRoute",
        "CreateRoute",
        "StartCreateRoute",
        "CreateRouteBtn_Pressed",
        "SaveTradeRoute",
        "Controller",
        "SceneController",
        "TradeRouteController",
        "TradeRouteSceneController",
        "RequestFocus",
        "CloseTradeRouteScene",
        "TradeGoodSelection"
    }

    local selectionCandidates = {
        "CreateNewTradeRoute",
        "CreateTradeRoute",
        "NewTradeRoute",
        "CreateRoute",
        "StartCreateRoute",
        "CreateRouteBtn_Pressed",
        "IsCreateRouteBtnVisible",
        "IsPanelVisible",
        "Controller",
        "SceneController",
        "TradeRouteController",
        "TradeRouteSceneController",
        "SubMenuData",
        "IslandOptionPopupData",
        "ShipandCargoData",
        "TradeRouteGoodData",
        "RequestStationFocus"
    }

    if scene ~= nil then
        bindingInspectObject(scene, "TradeRouteScene", sceneCandidates)
    end
    if selection ~= nil then
        bindingInspectObject(selection, "TradeGoodSelection", selectionCandidates)
    end

    local nestedTargets = {
        {"TradeGoodSelection.SubMenuData", safe(function() return selection and selection.SubMenuData end)},
        {"TradeGoodSelection.IslandOptionPopupData", safe(function() return selection and selection.IslandOptionPopupData end)},
        {"TradeGoodSelection.ShipandCargoData", safe(function() return selection and selection.ShipandCargoData end)},
        {"TradeGoodSelection.TradeRouteGoodData", safe(function() return selection and selection.TradeRouteGoodData end)}
    }

    local nestedCandidates = {
        "CreateNewTradeRoute",
        "CreateTradeRoute",
        "NewTradeRoute",
        "CreateRoute",
        "CreateRouteBtn_Pressed",
        "PrimaryButtonPressed",
        "Pressed",
        "OnPressed",
        "Controller",
        "SceneController",
        "IsVisible",
        "IsFocused",
        "IsSelected"
    }

    for _, target in ipairs(nestedTargets) do
        local label, value = target[1], target[2]
        log("CREATE SURFACE NESTED"
            .. " | label=" .. tostring(label)
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value))
        if value ~= nil then
            bindingInspectObject(value, label, nestedCandidates)
        end
    end

    local typeofFn = rawget(_G, "typeof")
    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    local getTypeInfoDeprecatedFn = rawget(_G, "getTypeInfoDeprecated")
    local filterMetaTablesFn = rawget(_G, "filterMetaTables")

    local reflectionTargets = {
        {"scene", scene},
        {"selection", selection},
        {"route", route}
    }

    for _, target in ipairs(reflectionTargets) do
        local label, value = target[1], target[2]
        if value ~= nil and type(typeofFn) == "function" then
            local result, err = safe(function() return typeofFn(value) end)
            log("CREATE SURFACE TYPEOF"
                .. " | label=" .. tostring(label)
                .. " | success=" .. tostring(err == nil)
                .. " | resultType=" .. tostring(type(result))
                .. " | result=" .. bindingSafeToString(result)
                .. " | error=" .. tostring(err or ""))
        end
        if value ~= nil and type(getTypeInfoFn) == "function" then
            local result, err = safe(function() return getTypeInfoFn(value) end)
            log("CREATE SURFACE GETTYPEINFO"
                .. " | label=" .. tostring(label)
                .. " | success=" .. tostring(err == nil)
                .. " | resultType=" .. tostring(type(result))
                .. " | result=" .. bindingSafeToString(result)
                .. " | error=" .. tostring(err or ""))
            if err == nil then createSurfaceInspectResult("getTypeInfo." .. label, result) end
        end
        if value ~= nil and type(getTypeInfoDeprecatedFn) == "function" then
            local result, err = safe(function() return getTypeInfoDeprecatedFn(value) end)
            log("CREATE SURFACE GETTYPEINFO OLD"
                .. " | label=" .. tostring(label)
                .. " | success=" .. tostring(err == nil)
                .. " | resultType=" .. tostring(type(result))
                .. " | result=" .. bindingSafeToString(result)
                .. " | error=" .. tostring(err or ""))
            if err == nil then createSurfaceInspectResult("getTypeInfoDeprecated." .. label, result) end
        end
    end

    local typeNames = {
        "CTradeRouteSceneController",
        "TradeRouteSceneController",
        "TradeRouteSceneObject",
        "TradeRouteGoodSelectionData",
        "CSessionTradeRoute",
        "CTradeRouteManager"
    }

    for _, name in ipairs(typeNames) do
        if type(getTypeInfoFn) == "function" then
            local result, err = safe(function() return getTypeInfoFn(name) end)
            log("CREATE SURFACE TYPE NAME"
                .. " | function=getTypeInfo"
                .. " | name=" .. tostring(name)
                .. " | success=" .. tostring(err == nil)
                .. " | resultType=" .. tostring(type(result))
                .. " | result=" .. bindingSafeToString(result)
                .. " | error=" .. tostring(err or ""))
            if err == nil then createSurfaceInspectResult("typeName." .. name, result) end
        end
        if type(getTypeInfoDeprecatedFn) == "function" then
            local result, err = safe(function() return getTypeInfoDeprecatedFn(name) end)
            log("CREATE SURFACE TYPE NAME"
                .. " | function=getTypeInfoDeprecated"
                .. " | name=" .. tostring(name)
                .. " | success=" .. tostring(err == nil)
                .. " | resultType=" .. tostring(type(result))
                .. " | result=" .. bindingSafeToString(result)
                .. " | error=" .. tostring(err or ""))
            if err == nil then createSurfaceInspectResult("oldTypeName." .. name, result) end
        end
    end

    local haloRoot = rawget(_G, "halo")
    log("CREATE SURFACE HALO ROOT"
        .. " | type=" .. tostring(type(haloRoot))
        .. " | value=" .. bindingSafeToString(haloRoot))

    if type(haloRoot) == "table" then
        for _, name in ipairs(typeNames) do
            local helper, err = safe(function() return haloRoot[name] end)
            log("CREATE SURFACE HALO"
                .. " | name=" .. tostring(name)
                .. " | type=" .. tostring(type(helper))
                .. " | value=" .. bindingSafeToString(helper)
                .. " | error=" .. tostring(err or ""))
            if type(helper) == "table" then
                bindingInspectTable(helper, "CREATE_SURFACE.halo." .. name, 0, {})
            end
        end
    end

    if type(filterMetaTablesFn) == "function" then
        local filters = {
            "TradeRouteSceneController",
            "CTradeRouteSceneController",
            "CreateNewTradeRoute",
            "CreateTradeRoute",
            "TradeRouteScene",
            "TradeRouteGoodSelection"
        }
        for _, text in ipairs(filters) do
            local result, err = safe(function() return filterMetaTablesFn(text) end)
            log("CREATE SURFACE FILTER"
                .. " | text=" .. tostring(text)
                .. " | success=" .. tostring(err == nil)
                .. " | resultType=" .. tostring(type(result))
                .. " | result=" .. bindingSafeToString(result)
                .. " | error=" .. tostring(err or ""))
            if err == nil then createSurfaceInspectResult("filter." .. text, result) end
        end
    end

    local knownGlobals = {
        "CTradeRouteSceneController",
        "TradeRouteSceneController",
        "TradeRouteController",
        "TradeRouteEditor",
        "TradeRouteScene"
    }
    for _, name in ipairs(knownGlobals) do
        local value, err = safe(function() return _G[name] end)
        log("CREATE SURFACE GLOBAL"
            .. " | name=" .. tostring(name)
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. bindingSafeToString(value)
            .. " | error=" .. tostring(err or ""))
        if value ~= nil then
            bindingInspectObject(value, "_G." .. name, sceneCandidates)
        end
    end

    log("CREATE SURFACE COMPLETE"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | noRouteActionInvoked=true"
        .. " | next=run once in overview and once in empty editor")
    return true
end


local function overviewObjectId(value)
    local ok, text = pcall(tostring, value)
    if ok then
        return tostring(type(value)) .. "|" .. tostring(text)
    end
    return tostring(type(value)) .. "|" .. tostring(value)
end

local function overviewDeepInspect(value, label, depth, visited)
    depth = tonumber(depth) or 0
    visited = visited or {}

    if value == nil then
        log("OVERVIEW DEEP NIL | label=" .. tostring(label) .. " | depth=" .. tostring(depth))
        return
    end

    local valueType = type(value)
    local valueText = bindingSafeToString(value)
    log("OVERVIEW DEEP OBJECT"
        .. " | label=" .. tostring(label)
        .. " | depth=" .. tostring(depth)
        .. " | type=" .. tostring(valueType)
        .. " | value=" .. tostring(valueText))

    if depth > 2 then
        log("OVERVIEW DEEP LIMIT | label=" .. tostring(label) .. " | reason=depth")
        return
    end

    if valueType ~= "userdata" and valueType ~= "table" then
        return
    end

    local identity = overviewObjectId(value)
    if visited[identity] then
        log("OVERVIEW DEEP CYCLE | label=" .. tostring(label) .. " | identity=" .. tostring(identity))
        return
    end
    visited[identity] = true

    local typeInfoFn = rawget(_G, "getTypeInfo")
    if type(typeInfoFn) == "function" then
        local info, infoErr = safe(function()
            return typeInfoFn(value)
        end)
        log("OVERVIEW DEEP TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | success=" .. tostring(infoErr == nil)
            .. " | resultType=" .. tostring(type(info))
            .. " | result=" .. tostring(bindingSafeToString(info))
            .. " | error=" .. tostring(infoErr or ""))
    end

    local mt, mtErr = safe(function()
        return getmetatable(value)
    end)
    log("OVERVIEW DEEP METATABLE"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(mt))
        .. " | value=" .. tostring(bindingSafeToString(mt))
        .. " | error=" .. tostring(mtErr or ""))

    if type(mt) ~= "table" then
        return
    end

    local keys = {}
    local keyErr = nil
    local ok, err = pcall(function()
        for key, _ in pairs(mt) do
            if type(key) == "string" and string.sub(key, 1, 2) ~= "__" then
                table.insert(keys, key)
            end
        end
    end)
    if not ok then
        keyErr = err
    end
    table.sort(keys)

    log("OVERVIEW DEEP KEYS"
        .. " | label=" .. tostring(label)
        .. " | count=" .. tostring(#keys)
        .. " | error=" .. tostring(keyErr or "")
        .. " | values=" .. table.concat(keys, " ; "))

    local maxMembers = 80
    local count = 0
    for _, key in ipairs(keys) do
        count = count + 1
        if count > maxMembers then
            log("OVERVIEW DEEP MEMBER LIMIT"
                .. " | label=" .. tostring(label)
                .. " | max=" .. tostring(maxMembers))
            break
        end

        local member, memberErr = safe(function()
            return value[key]
        end)

        log("OVERVIEW DEEP MEMBER"
            .. " | object=" .. tostring(label)
            .. " | key=" .. tostring(key)
            .. " | type=" .. tostring(type(member))
            .. " | value=" .. tostring(bindingSafeToString(member))
            .. " | error=" .. tostring(memberErr or ""))

        if memberErr == nil
            and member ~= nil
            and (type(member) == "userdata" or type(member) == "table")
            and depth < 2 then
            overviewDeepInspect(member, tostring(label) .. "." .. tostring(key), depth + 1, visited)
        end
    end
end

function GoodsFinder:ProbeTradeOverviewDeep()
    log("OVERVIEW PROBE START | deep read-only inspection of TradeOverview and related scene data")

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local overview = safe(function()
        return scene and scene.TradeOverview
    end)
    local groupManager = safe(function()
        return scene and scene.RouteGroupManagerData
    end)
    local shipSelect = safe(function()
        return scene and scene.TradeShipSelect
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)

    log("OVERVIEW PROBE ROOT"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | scene=" .. tostring(bindingSafeToString(scene))
        .. " | overviewType=" .. tostring(type(overview))
        .. " | overview=" .. tostring(bindingSafeToString(overview))
        .. " | groupManagerType=" .. tostring(type(groupManager))
        .. " | groupManager=" .. tostring(bindingSafeToString(groupManager))
        .. " | shipSelectType=" .. tostring(type(shipSelect))
        .. " | shipSelect=" .. tostring(bindingSafeToString(shipSelect))
        .. " | selectionPanelVisible=" .. tostring(safe(function() return selection and selection.IsPanelVisible end))
        .. " | selectionCreateVisible=" .. tostring(safe(function() return selection and selection.IsCreateRouteBtnVisible end))
        .. " | routeValid=" .. tostring(routeValid))

    overviewDeepInspect(overview, "TradeRouteScene.TradeOverview", 0, {})
    overviewDeepInspect(groupManager, "TradeRouteScene.RouteGroupManagerData", 0, {})
    overviewDeepInspect(shipSelect, "TradeRouteScene.TradeShipSelect", 0, {})

    local haloRoot = rawget(_G, "halo")
    if type(haloRoot) == "table" then
        local matches = {}
        local scanOk, scanErr = pcall(function()
            for key, value in pairs(haloRoot) do
                local keyText = tostring(key)
                local lower = string.lower(keyText)
                if string.find(lower, "tradeoverview", 1, true)
                    or string.find(lower, "traderouteoverview", 1, true)
                    or string.find(lower, "routeoverview", 1, true)
                    or string.find(lower, "routegroup", 1, true)
                    or string.find(lower, "routeship", 1, true)
                    or string.find(lower, "newroute", 1, true)
                    or string.find(lower, "createroute", 1, true) then
                    table.insert(matches, {keyText, value})
                end
            end
        end)

        table.sort(matches, function(a, b)
            return tostring(a[1]) < tostring(b[1])
        end)

        log("OVERVIEW PROBE HALO MATCHES"
            .. " | success=" .. tostring(scanOk)
            .. " | error=" .. tostring(scanErr or "")
            .. " | count=" .. tostring(#matches))

        local maxMatches = 60
        for index, item in ipairs(matches) do
            if index > maxMatches then
                log("OVERVIEW PROBE HALO LIMIT | max=" .. tostring(maxMatches))
                break
            end
            local key, value = item[1], item[2]
            log("OVERVIEW PROBE HALO"
                .. " | index=" .. tostring(index)
                .. " | key=" .. tostring(key)
                .. " | type=" .. tostring(type(value))
                .. " | value=" .. tostring(bindingSafeToString(value)))
            if type(value) == "table" then
                overviewDeepInspect(value, "halo." .. tostring(key), 0, {})
            end
        end
    else
        log("OVERVIEW PROBE HALO MATCHES | haloType=" .. tostring(type(haloRoot)) .. " | count=0")
    end

    log("OVERVIEW PROBE COMPLETE"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | noRouteActionInvoked=true"
        .. " | next=compare overview with empty route editor")
    return true
end


function GoodsFinder:PressTradeOverviewCreateButton()
    log("OVERVIEW CREATE START | invoke discovered TradeOverview.CreatButtonPressed method")

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local overview = safe(function()
        return scene and scene.TradeOverview
    end)
    local method = safe(function()
        return overview and overview.CreatButtonPressed
    end)
    local routeBefore = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValidBefore = safe(function()
        return routeBefore and routeBefore:isValid()
    end)
    local panelOpen = safe(function()
        return overview and overview.IsPanelOpen
    end)

    log("OVERVIEW CREATE BEFORE"
        .. " | sceneType=" .. tostring(type(scene))
        .. " | overviewType=" .. tostring(type(overview))
        .. " | methodType=" .. tostring(type(method))
        .. " | panelOpen=" .. tostring(panelOpen)
        .. " | routeValid=" .. tostring(routeValidBefore)
        .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | productName=" .. tostring(self.lastProductName or "")
        .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or ""))

    if routeValidBefore == true then
        log("OVERVIEW CREATE ABORT | reason=route editor already valid")
        return false
    end

    if overview == nil or type(method) ~= "function" then
        log("OVERVIEW CREATE ABORT"
            .. " | reason=CreatButtonPressed unavailable"
            .. " | overviewType=" .. tostring(type(overview))
            .. " | methodType=" .. tostring(type(method)))
        return false
    end

    local focusResult, focusErr = safe(function()
        if scene ~= nil and type(scene.RequestFocus) == "function" then
            return scene.RequestFocus(scene)
        end
        return nil
    end)

    log("OVERVIEW CREATE FOCUS"
        .. " | success=" .. tostring(focusErr == nil)
        .. " | returnType=" .. tostring(type(focusResult))
        .. " | returnValue=" .. tostring(focusResult)
        .. " | error=" .. tostring(focusErr or ""))

    local value, err = safe(function()
        return method(overview)
    end)
    local callMode = "overview.CreatButtonPressed(overview)"

    if err ~= nil then
        value, err = safe(function()
            return method()
        end)
        callMode = "overview.CreatButtonPressed()"
    end

    local routeAfter = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValidAfter = safe(function()
        return routeAfter and routeAfter:isValid()
    end)
    local routeNameAfter = safe(function()
        return routeAfter and routeAfter.Name
    end)

    log("OVERVIEW CREATE DISPATCH"
        .. " | mode=" .. tostring(callMode)
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(value))
        .. " | returnValue=" .. tostring(value)
        .. " | error=" .. tostring(err or "")
        .. " | routeValidImmediate=" .. tostring(routeValidAfter)
        .. " | routeNameImmediate=" .. tostring(routeNameAfter))

    log("OVERVIEW CREATE COMPLETE"
        .. " | dispatchSuccess=" .. tostring(err == nil)
        .. " | expectedNativeMarker=CTradeRouteSceneController::CreateNewTradeRoute"
        .. " | doNotClickCreateManually=true")

    return err == nil
end



local function assistedRouteStationCount()
    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local stations = safe(function()
        return selection and selection.TradeRouteGoodData
    end)
    local haloRoot = rawget(_G, "halo")
    local helper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodData>"]
        or nil

    if stations == nil
        or type(helper) ~= "table"
        or type(helper.GetSize) ~= "function" then
        return nil, "station array/helper unavailable"
    end

    return safe(function()
        return helper.GetSize(stations)
    end)
end



local function existingRouteCurrentProvinceNames(goodsFinder)
    local names = {}
    for _, record in ipairs(goodsFinder.lastStockRecords or {}) do
        local name = string.lower(tostring(record.areaName or ""))
        if name ~= "" then
            names[name] = true
        end
    end
    return names
end


local function existingRouteFindUsableProvinceStation(goodsFinder)
    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local stations = safe(function()
        return selection and selection.TradeRouteGoodData
    end)

    local haloRoot = rawget(_G, "halo")
    local stationHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodData>"]
        or nil
    local rowHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodIslandData>"]
        or nil

    if stations == nil
        or type(stationHelper) ~= "table"
        or type(stationHelper.GetSize) ~= "function"
        or type(stationHelper.GetElement) ~= "function"
        or type(rowHelper) ~= "table"
        or type(rowHelper.GetSize) ~= "function"
        or type(rowHelper.GetElement) ~= "function" then
        return nil, nil, nil, "station/load-row helper unavailable"
    end

    local stationCount, stationCountErr = safe(function()
        return stationHelper.GetSize(stations)
    end)
    if stationCountErr ~= nil then
        return nil, nil, nil, stationCountErr
    end

    local provinceNames = existingRouteCurrentProvinceNames(goodsFinder)
    local sawProvinceStation = false
    local bestError = nil
    local fallbackRowCount = nil
    local fallbackIndex = nil
    local fallbackName = nil

    for index = 0, (tonumber(stationCount) or 0) - 1 do
        local station = safe(function()
            return stationHelper.GetElement(stations, index)
        end)
        local islandName = tostring(safe(function()
            return station and station.IslandName
        end) or "")
        local stationProvinceIcon = tostring(safe(function()
            return station and station.StationProvinceIcon
        end) or "")
        local targetProvinceIcon =
            tostring(goodsFinder.crossProvinceTargetStationIcon or "")
        local inCurrentProvince = false

        if targetProvinceIcon ~= "" then
            inCurrentProvince =
                stationProvinceIcon == targetProvinceIcon
        else
            inCurrentProvince =
                provinceNames[string.lower(islandName)] == true
        end

        if inCurrentProvince then
            sawProvinceStation = true

            local stationHasWarning = safe(function()
                return station and station.StationHasWarning
            end)
            local waitForGoodsActive = safe(function()
                local data = station and station.WaitForGoodsButtonData
                return data and data.IsActive
            end)
            local waitToUnloadActive = safe(function()
                local data = station and station.WaitToUnloadButtonData
                return data and data.IsActive
            end)

            safe(function()
                selection.GoodsIslandFocusIndex = index
                selection.GoodsIslandHoveredIndex = index
                if type(selection.RequestStationFocus) == "function" then
                    selection.RequestStationFocus(selection)
                end
            end)

            local rows = safe(function()
                return station and station.TradeRouteLoadandUnloadData
            end)
            local rowCount, rowCountErr = safe(function()
                return rows and rowHelper.GetSize(rows)
            end)

            if rowCountErr ~= nil then
                bestError = rowCountErr
            elseif (tonumber(rowCount) or 0) > 0 then
                local emptyUsableRows = 0

                for rowIndex = 0, (tonumber(rowCount) or 0) - 1 do
                    local row = safe(function()
                        return rowHelper.GetElement(rows, rowIndex)
                    end)
                    local loadGoods = safe(function()
                        return row and row.LoadGoods
                    end)
                    local addGood = safe(function()
                        return loadGoods and loadGoods.AddGood
                    end)
                    local isLoaded = safe(function()
                        return loadGoods and loadGoods.IsGoodLoaded
                    end)

                    if loadGoods ~= nil
                        and type(addGood) == "function"
                        and isLoaded ~= true then
                        emptyUsableRows = emptyUsableRows + 1
                    end
                end

                if emptyUsableRows > 0 then
                    local warningActive =
                        stationHasWarning == true
                        or waitForGoodsActive == true
                        or waitToUnloadActive == true

                    log("GENERICROUTE HELPER STATION CANDIDATE"
                        .. " | arrayIndex=" .. tostring(index)
                        .. " | islandName=" .. tostring(islandName)
                        .. " | stationProvinceIcon=" .. tostring(stationProvinceIcon)
                        .. " | targetProvinceIcon=" .. tostring(targetProvinceIcon)
                        .. " | emptyUsableRows=" .. tostring(emptyUsableRows)
                        .. " | stationHasWarning=" .. tostring(stationHasWarning)
                        .. " | waitForGoodsActive=" .. tostring(waitForGoodsActive)
                        .. " | waitToUnloadActive=" .. tostring(waitToUnloadActive)
                        .. " | warningActive=" .. tostring(warningActive))

                    if warningActive ~= true then
                        log("GENERICROUTE HELPER STATION SELECT"
                            .. " | mode=prefer-no-native-warning"
                            .. " | arrayIndex=" .. tostring(index)
                            .. " | islandName=" .. tostring(islandName))
                        return tonumber(rowCount) or 0, index, islandName, nil
                    end

                    if fallbackIndex == nil then
                        fallbackRowCount = tonumber(rowCount) or 0
                        fallbackIndex = index
                        fallbackName = islandName
                    end
                else
                    bestError =
                        "current-province station has no empty usable LoadGoods row"
                end
            end
        end
    end

    if fallbackIndex ~= nil then
        log("GENERICROUTE HELPER STATION SELECT"
            .. " | mode=fallback-warning-station"
            .. " | arrayIndex=" .. tostring(fallbackIndex)
            .. " | islandName=" .. tostring(fallbackName))
        return fallbackRowCount, fallbackIndex, fallbackName, nil
    end

    if sawProvinceStation ~= true then
        return 0, nil, nil, "route is not in the current province"
    end

    return 0, nil, nil, bestError or "no empty usable LoadGoods row"
end


local function assistedRememberedLoadRowCount(goodsFinder)
    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local stations = safe(function()
        return selection and selection.TradeRouteGoodData
    end)

    local haloRoot = rawget(_G, "halo")
    local stationHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodData>"]
        or nil
    local rowHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodIslandData>"]
        or nil

    if stations == nil
        or type(stationHelper) ~= "table"
        or type(stationHelper.GetSize) ~= "function"
        or type(stationHelper.GetElement) ~= "function"
        or type(rowHelper) ~= "table"
        or type(rowHelper.GetSize) ~= "function" then
        return nil, nil, "station/load-row helper unavailable"
    end

    local stationCount, stationCountErr = safe(function()
        return stationHelper.GetSize(stations)
    end)
    if stationCountErr ~= nil then
        return nil, nil, stationCountErr
    end

    local rememberedName = tostring(goodsFinder.lastWarehouseAreaName or "")
    local rememberedStation = nil
    local rememberedIndex = nil

    for index = 0, (tonumber(stationCount) or 0) - 1 do
        local station = safe(function()
            return stationHelper.GetElement(stations, index)
        end)
        local islandName = tostring(safe(function()
            return station and station.IslandName
        end) or "")

        if islandName == rememberedName then
            rememberedStation = station
            rememberedIndex = index
            break
        end
    end

    if rememberedStation == nil then
        return nil, nil, "remembered station not found"
    end

    safe(function()
        selection.GoodsIslandFocusIndex = rememberedIndex
        selection.GoodsIslandHoveredIndex = rememberedIndex
        if type(selection.RequestStationFocus) == "function" then
            selection.RequestStationFocus(selection)
        end
    end)

    local rows = safe(function()
        return rememberedStation.TradeRouteLoadandUnloadData
    end)
    local rowCount, rowCountErr = safe(function()
        return rowHelper.GetSize(rows)
    end)

    if rowCountErr ~= nil then
        return nil, rememberedIndex, rowCountErr
    end

    return tonumber(rowCount) or 0, rememberedIndex, nil
end


local function existingRouteStationSnapshot(goodsFinder)
    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local stations = safe(function()
        return selection and selection.TradeRouteGoodData
    end)

    local haloRoot = rawget(_G, "halo")
    local helper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodData>"]
        or nil

    if stations == nil
        or type(helper) ~= "table"
        or type(helper.GetSize) ~= "function"
        or type(helper.GetElement) ~= "function" then
        return nil, "station array/helper unavailable"
    end

    local size, sizeErr = safe(function()
        return helper.GetSize(stations)
    end)
    if sizeErr ~= nil then
        return nil, sizeErr
    end

    local count = tonumber(size) or 0
    local provinceNames = existingRouteCurrentProvinceNames(goodsFinder)
    local rows = {}

    for index = 0, count - 1 do
        local station = safe(function()
            return helper.GetElement(stations, index)
        end)
        local islandName = tostring(safe(function()
            return station and station.IslandName
        end) or "")
        local stationId = safe(function()
            return station and station.StationId
        end)
        if stationId == nil then
            stationId = safe(function()
                return station and station.ID
            end)
        end

        local stationProvinceIcon = tostring(safe(function()
            return station and station.StationProvinceIcon
        end) or "")
        local targetProvinceIcon =
            tostring(goodsFinder.crossProvinceTargetStationIcon or "")
        local inCurrentProvince = false
        if targetProvinceIcon ~= "" then
            inCurrentProvince =
                stationProvinceIcon == targetProvinceIcon
        else
            inCurrentProvince =
                provinceNames[string.lower(islandName)] == true
        end

        rows[#rows + 1] = {
            index = index,
            islandName = islandName,
            stationId = stationId,
            stationProvinceIcon = stationProvinceIcon,
            inCurrentProvince = inCurrentProvince
        }
    end

    return rows, nil
end


local function scheduleFailureCleanup(goodsFinder, reason, mode)
    goodsFinder.existingRouteScanPending = false
    goodsFinder.existingRoutePhase = nil
    goodsFinder.existingRouteTickCounter = 0

    goodsFinder.failureCleanupPending = true
    goodsFinder.failureCleanupPhase = "wait"
    goodsFinder.failureCleanupTickCounter = 0
    goodsFinder.failureCleanupReason = tostring(reason or "")
    goodsFinder.failureCleanupMode =
        tostring(mode or "normal")

    log("ROUTECLEANUP SCHEDULED"
        .. " | mode=" .. tostring(goodsFinder.failureCleanupMode)
        .. " | reason=" .. tostring(goodsFinder.failureCleanupReason)
        .. " | action=close Trade Route and MacroMap automatically"
        .. " | safety=no route, station, ship, or cargo changes")
end


local function failureCleanupTick(goodsFinder)
    goodsFinder.failureCleanupTickCounter =
        (tonumber(goodsFinder.failureCleanupTickCounter) or 0) + 1
    local tickCount = goodsFinder.failureCleanupTickCounter

    if goodsFinder.failureCleanupPhase == "wait" then
        -- A short delay ensures that either the overview or the last inspected
        -- route has fully entered its UI state before it is closed.
        if tickCount < 2 then
            return
        end

        local routeValidBefore = safe(function()
            return TradeRoute
                and TradeRoute.UIEditRoute
                and TradeRoute.UIEditRoute:isValid()
        end)

        local result, err = safe(function()
            Scripts:PopUI()
            return true
        end)

        log("ROUTECLEANUP CLOSE"
            .. " | mode=" .. tostring(goodsFinder.failureCleanupMode or "")
            .. " | reason=" .. tostring(goodsFinder.failureCleanupReason or "")
            .. " | routeValidBefore=" .. tostring(routeValidBefore)
            .. " | success=" .. tostring(err == nil and result == true)
            .. " | result=" .. tostring(result)
            .. " | error=" .. tostring(err or "")
            .. " | popUICalls=1"
            .. " | expected=TradeRoute and MacroMap close; previous warehouse view returns")

        goodsFinder.failureCleanupPhase = "verify"
        goodsFinder.failureCleanupTickCounter = 0
        return
    end

    if goodsFinder.failureCleanupPhase == "verify" then
        if tickCount < 2 then
            return
        end

        local routeValidAfter = safe(function()
            return TradeRoute
                and TradeRoute.UIEditRoute
                and TradeRoute.UIEditRoute:isValid()
        end)

        log("ROUTECLEANUP COMPLETE"
            .. " | mode=" .. tostring(goodsFinder.failureCleanupMode or "")
            .. " | reason=" .. tostring(goodsFinder.failureCleanupReason or "")
            .. " | routeValidAfter=" .. tostring(routeValidAfter)
            .. " | cleanupStateCleared=true")

        goodsFinder.failureCleanupPending = false
        goodsFinder.failureCleanupPhase = nil
        goodsFinder.failureCleanupTickCounter = 0
        goodsFinder.failureCleanupReason = nil
        goodsFinder.failureCleanupMode = nil
    end
end


local function existingRouteBuildCandidateList(goodsFinder)
    local candidates = {}

    if type(TradeRoute) ~= "table"
        or type(TradeRoute.GetRoute) ~= "function"
        or type(TradeRoute.ShowRouteUI) ~= "function" then
        return nil, "TradeRoute.GetRoute/ShowRouteUI unavailable"
    end

    for routeId = 1, 4096 do
        local route = safe(function()
            return TradeRoute:GetRoute(routeId)
        end)
        local valid = safe(function()
            return route and route:isValid()
        end)

        if valid == true then
            candidates[#candidates + 1] = {
                id = routeId,
                name = tostring(safe(function()
                    return route.Name
                end) or ""),
                activeErrors = tonumber(safe(function()
                    return route.ActiveErrorCount
                end)) or 0
            }
        end
    end

    local sessionGuid = tonumber(goodsFinder.lastSessionGuid) or 0
    local preferredRouteID = tonumber(
        goodsFinder.existingRoutePreferredBySession
            and goodsFinder.existingRoutePreferredBySession[sessionGuid]
    )

    table.sort(candidates, function(a, b)
        local aHealthy = (tonumber(a.activeErrors) or 0) == 0
        local bHealthy = (tonumber(b.activeErrors) or 0) == 0

        if aHealthy ~= bHealthy then
            return aHealthy == true
        end

        local aPreferred = preferredRouteID ~= nil
            and tonumber(a.id) == preferredRouteID
        local bPreferred = preferredRouteID ~= nil
            and tonumber(b.id) == preferredRouteID

        if aPreferred ~= bPreferred then
            return aPreferred == true
        end

        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)

    log("GENERICROUTE SCAN START"
        .. " | candidates=" .. tostring(#candidates)
        .. " | sessionGUID=" .. tostring(sessionGuid)
        .. " | rememberedWarehouse="
            .. tostring(goodsFinder.lastWarehouseAreaName or "")
        .. " | productGUID=" .. tostring(goodsFinder.lastProductGuid or 0)
        .. " | productName=" .. tostring(goodsFinder.lastProductName or "")
        .. " | preferredRouteID=" .. tostring(preferredRouteID or "")
        .. " | strategy=error-free routes first, then cached route within the same health class, then ascending route ID")

    log("GENERICROUTE CANDIDATE SUMMARY"
        .. " | total=" .. tostring(#candidates)
        .. " | preferredRouteID=" .. tostring(preferredRouteID or "")
        .. " | firstRouteID="
            .. tostring(candidates[1] and candidates[1].id or "")
        .. " | firstRouteName="
            .. tostring(candidates[1] and candidates[1].name or ""))

    return candidates, nil
end

local function existingRouteAdvance(goodsFinder, reason)
    goodsFinder.existingRouteCandidateIndex =
        (tonumber(goodsFinder.existingRouteCandidateIndex) or 0) + 1
    goodsFinder.existingRoutePhase = "open"
    goodsFinder.existingRouteTickCounter = 0
    goodsFinder.existingRouteCurrentId = nil
    goodsFinder.existingRouteCurrentName = nil
    goodsFinder.existingRouteCurrentLogged = false
    goodsFinder.existingRouteExactMatchSeen = false

    log("GENERICROUTE ADVANCE"
        .. " | nextOrder=" .. tostring(goodsFinder.existingRouteCandidateIndex)
        .. " | reason=" .. tostring(reason or ""))
end


local function existingRouteScanTick(goodsFinder)
    local candidates = goodsFinder.existingRouteCandidates or {}
    local candidateIndex =
        tonumber(goodsFinder.existingRouteCandidateIndex) or 1

    if candidateIndex < 1 then
        candidateIndex = 1
        goodsFinder.existingRouteCandidateIndex = 1
    end

    if candidateIndex > #candidates then
        log("GENERICROUTE EXHAUSTED"
            .. " | candidatesChecked=" .. tostring(#candidates)
            .. " | sessionGUID="
                .. tostring(goodsFinder.lastSessionGuid or 0)
            .. " | result=no current-province route exposed at least two stations and an empty usable LoadGoods row")

        scheduleFailureCleanup(
            goodsFinder,
            "no usable route found after candidate scan",
            "no_usable_route"
        )
        return
    end

    local candidate = candidates[candidateIndex]

    if goodsFinder.existingRoutePhase == "open" then
        goodsFinder.existingRouteCurrentId = candidate.id
        goodsFinder.existingRouteCurrentName = candidate.name
        goodsFinder.existingRouteTickCounter = 0
        goodsFinder.existingRouteCurrentLogged = false
        goodsFinder.existingRouteHelperStationIndex = nil
        goodsFinder.existingRouteHelperStationName = nil

        local result, err = safe(function()
            return TradeRoute:ShowRouteUI(candidate.id)
        end)

        log("GENERICROUTE OPEN"
            .. " | order=" .. tostring(candidateIndex)
            .. " | routeID=" .. tostring(candidate.id)
            .. " | routeName=" .. tostring(candidate.name)
            .. " | activeErrors=" .. tostring(candidate.activeErrors)
            .. " | success=" .. tostring(err == nil)
            .. " | returnType=" .. tostring(type(result))
            .. " | returnValue="
                .. tostring(bindingSafeToString(result))
            .. " | error=" .. tostring(err or ""))

        if err ~= nil then
            existingRouteAdvance(goodsFinder, "ShowRouteUI failed")
            return
        end

        goodsFinder.existingRoutePhase = "wait"
        return
    end

    goodsFinder.existingRouteTickCounter =
        (tonumber(goodsFinder.existingRouteTickCounter) or 0) + 1
    local tickCount = goodsFinder.existingRouteTickCounter

    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)
    local routeName = tostring(safe(function()
        return route and route.Name
    end) or "")

    local rows, stationErr =
        existingRouteStationSnapshot(goodsFinder)
    local stationCount = type(rows) == "table" and #rows or 0
    local currentProvinceStationCount = 0

    for _, row in ipairs(rows or {}) do
        if row.inCurrentProvince == true then
            currentProvinceStationCount =
                currentProvinceStationCount + 1
        end
    end

    if goodsFinder.existingRouteCurrentLogged ~= true
        and (routeValid == true or tickCount >= 3) then
        goodsFinder.existingRouteCurrentLogged = true

        log("GENERICROUTE READY"
            .. " | order=" .. tostring(candidateIndex)
            .. " | routeID=" .. tostring(candidate.id)
            .. " | candidateName=" .. tostring(candidate.name)
            .. " | liveRouteName=" .. tostring(routeName)
            .. " | routeValid=" .. tostring(routeValid)
            .. " | tickCount=" .. tostring(tickCount)
            .. " | stationCount=" .. tostring(stationCount)
            .. " | currentProvinceStations="
                .. tostring(currentProvinceStationCount)
            .. " | stationError=" .. tostring(stationErr or ""))

        for _, row in ipairs(rows or {}) do
            log("GENERICROUTE STATION"
                .. " | routeID=" .. tostring(candidate.id)
                .. " | routeName=" .. tostring(candidate.name)
                .. " | arrayIndex=" .. tostring(row.index)
                .. " | islandName=" .. tostring(row.islandName)
                .. " | stationID=" .. tostring(row.stationId)
                .. " | stationProvinceIcon="
                    .. tostring(row.stationProvinceIcon or "")
                .. " | targetProvinceIcon="
                    .. tostring(goodsFinder.crossProvinceTargetStationIcon or "")
                .. " | inCurrentProvince="
                    .. tostring(row.inCurrentProvince))
        end
    end

    if routeValid == true
        and stationErr == nil
        and stationCount >= 2 then
        local loadRowCount, helperStationIndex,
            helperStationName, helperErr =
            existingRouteFindUsableProvinceStation(goodsFinder)

        log("GENERICROUTE USABLE CHECK"
            .. " | routeID=" .. tostring(candidate.id)
            .. " | routeName=" .. tostring(candidate.name)
            .. " | stationCount=" .. tostring(stationCount)
            .. " | currentProvinceStations="
                .. tostring(currentProvinceStationCount)
            .. " | helperStationIndex="
                .. tostring(helperStationIndex)
            .. " | helperStationName="
                .. tostring(helperStationName)
            .. " | helperLoadRowCount="
                .. tostring(loadRowCount)
            .. " | error=" .. tostring(helperErr or "")
            .. " | tickCount=" .. tostring(tickCount))

        if (tonumber(loadRowCount) or 0) > 0
            and helperStationIndex ~= nil then
            goodsFinder.existingRouteScanPending = false
            goodsFinder.existingRoutePhase = nil
            goodsFinder.existingRouteHelperStationIndex =
                tonumber(helperStationIndex)
            goodsFinder.existingRouteHelperStationName =
                tostring(helperStationName or "")

            local sessionGuid =
                tonumber(goodsFinder.lastSessionGuid) or 0
            goodsFinder.existingRoutePreferredBySession =
                goodsFinder.existingRoutePreferredBySession or {}
            goodsFinder.existingRoutePreferredBySession[sessionGuid] =
                tonumber(candidate.id)

            log("GENERICROUTE CACHE"
                .. " | sessionGUID=" .. tostring(sessionGuid)
                .. " | routeID=" .. tostring(candidate.id)
                .. " | routeName=" .. tostring(candidate.name)
                .. " | helperStationIndex="
                    .. tostring(helperStationIndex)
                .. " | helperStationName="
                    .. tostring(helperStationName))

            log("GENERICROUTE OVERLAY HANDOFF"
                .. " | routeID=" .. tostring(candidate.id)
                .. " | routeName=" .. tostring(candidate.name)
                .. " | stationCount=" .. tostring(stationCount)
                .. " | helperStationIndex="
                    .. tostring(helperStationIndex)
                .. " | helperStationName="
                    .. tostring(helperStationName)
                .. " | helperLoadRowCount="
                    .. tostring(loadRowCount)
                .. " | action=OpenRememberedLoadGoodsPopup"
                .. " | safety=only an originally-empty LoadGoods row is accepted; occupied cargo rows remain unchanged")

            local result, err = safe(function()
                return goodsFinder:OpenRememberedLoadGoodsPopup()
            end)

            log("GENERICROUTE HANDOFF COMPLETE"
                .. " | success="
                    .. tostring(err == nil and result == true)
                .. " | result=" .. tostring(result)
                .. " | error=" .. tostring(err or "")
                .. " | delayedHoverPending="
                    .. tostring(
                        goodsFinder.autoGoodsHoverPending == true
                    )
                .. " | routeID=" .. tostring(candidate.id)
                .. " | routeName=" .. tostring(candidate.name))
            return
        end

        if currentProvinceStationCount == 0 then
            existingRouteAdvance(
                goodsFinder,
                "route does not belong to current province"
            )
            return
        end
    elseif routeValid == true
        and stationErr == nil
        and stationCount > 0
        and stationCount < 2 then
        existingRouteAdvance(
            goodsFinder,
            "route has fewer than two stations"
        )
        return
    end

    if tickCount >= 12 then
        existingRouteAdvance(
            goodsFinder,
            "no empty usable current-province LoadGoods row"
        )
    end
end

local function assistedOpenShipSelector()
    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local shipSelect = safe(function()
        return scene and scene.TradeShipSelect
    end)
    local method = safe(function()
        return shipSelect and shipSelect.ShipSelectBtn_Pressed
    end)

    if shipSelect == nil or type(method) ~= "function" then
        return false, "TradeShipSelect.ShipSelectBtn_Pressed unavailable"
    end

    local _, err = safe(function()
        return method(shipSelect)
    end)

    return err == nil, err
end

function GoodsFinder:CaptureOpenAndCreateRoute()
    log("GENERICROUTE WORKFLOW START"
        .. " | action=capture optional product/current area context, then inspect existing routes"
        .. " | noTemporaryRoute=true"
        .. " | noIslandClicks=true")

    self.nativeClickProbePending = false
    self.autoIslandPending = false
    self.autoShipListWaitPending = false
    self.autoShipSelectionPending = false
    self.autoGoodsHoverPending = false
    self.autoReturnPending = false
    self.autoReturnSawPopup = false
    self.autoReturnTickCounter = 0
    self.autoReturnCloseTickCounter = 0
    self.autoReturnCloseGraceLogged = false
    self.autoReturnLogged = false

    self.nativeCloseVerifyPending = false
    self.nativeCloseVerifyTickCounter = 0
    self.nativeCloseBaselineSignature = nil
    self.nativeClosePrecloseSignature = nil
    self.nativeCloseDispatchClock = nil
    self.nativeCloseDispatchTime = nil
    self.directLoadSelectedRowIndex = nil
    self.directLoadSelectedRowWasEmpty = false
    self.trackedRowRemoveDone = false
    self.removeSurfaceProbeDone = false
    self.failureCleanupPending = false
    self.failureCleanupPhase = nil
    self.failureCleanupTickCounter = 0
    self.failureCleanupReason = nil
    self.failureCleanupMode = nil
    self.existingRouteScanPending = false
    self.existingRouteCandidates = {}
    self.existingRouteCandidateIndex = 0
    self.existingRoutePhase = nil
    self.existingRouteTickCounter = 0
    self.existingRouteCurrentId = nil
    self.existingRouteCurrentName = nil
    self.existingRouteCurrentLogged = false
    self.existingRouteExactMatchSeen = false
    self.existingRouteHelperStationIndex = nil
    self.existingRouteHelperStationName = nil
    self.crossProvinceTargetProvince = nil
    self.crossProvinceTargetTab = nil
    self.crossProvinceTargetStationIcon = nil
    self.crossProvinceReferenceLabel = nil
    self.crossProvinceManualHandoff = false
    self.sameDoorwayReopenPending = false
    self.sameDoorwayReopenTick = 0
    self.sameDoorwayRouteID = nil
    self.sameDoorwayRouteName = nil
    self.sameDoorwayStationIndex = nil
    self.sameDoorwayStationName = nil
    self.crossProvincePopupProvince = nil
    self.crossProvincePopupTab = nil

    -- v1.1 UX improvement:
    -- The warehouse itself is now sufficient to open Goods Finder.
    -- A hovered product is optional and acts only as an automatic preselection.
    local warehouseScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.OMKontorWarehouse
    end)
    local warehouseSceneData = safe(function()
        return warehouseScene and warehouseScene.SceneData
    end)
    local warehouseData = safe(function()
        return warehouseSceneData and warehouseSceneData.NewOMKontorWarehouse
    end)
    local warehouseStorage = safe(function()
        return warehouseData and warehouseData.Storage
    end)

    local hasWarehouseContext = warehouseStorage ~= nil

    log("ANYWHERE CONTEXT"
        .. " | sceneType=" .. tostring(type(warehouseScene))
        .. " | sceneDataType=" .. tostring(type(warehouseSceneData))
        .. " | warehouseDataType=" .. tostring(type(warehouseData))
        .. " | storageType=" .. tostring(type(warehouseStorage))
        .. " | warehouseContextAvailable=" .. tostring(hasWarehouseContext)
        .. " | requirement=none"
        .. " | behavior=Ctrl+Alt+G may open Goods Finder from normal gameplay; warehouse hover remains optional preselection context")

    local warehouse = captureWarehouseArea()
    if warehouse == nil then
        self.lastWarehouseAreaId = 0
        self.lastWarehouseAreaName = ""
        log("ANYWHERE AREA"
            .. " | resolved=false"
            .. " | behavior=continue using owned-area province list and generic helper-station scan")
    else
        log("ANYWHERE AREA"
            .. " | resolved=true"
            .. " | areaID=" .. tostring(warehouse.areaId or 0)
            .. " | areaName=" .. tostring(warehouse.areaName or ""))
    end

    local product = captureAndLogStock(true)
    log("ANYWHERE START"
        .. " | warehouseContextAvailable=" .. tostring(hasWarehouseContext)
        .. " | preselection=" .. tostring(product ~= nil)
        .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | productName=" .. tostring(self.lastProductName or "")
        .. " | contextAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | contextAreaName=" .. tostring(self.lastWarehouseAreaName or "")
        .. " | physicalSessionGUID=" .. tostring(self.lastSessionGuid or 0))

    local openResult, openErr = safe(function()
        Scripts:ToggleTraderouteMenu()
        return true
    end)

    log("GENERICROUTE OVERVIEW OPEN"
        .. " | success=" .. tostring(openResult == true)
        .. " | error=" .. tostring(openErr or "")
        .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | productName=" .. tostring(self.lastProductName or "")
        .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or ""))

    if openResult ~= true then
        return false
    end

    local candidates, candidateErr = existingRouteBuildCandidateList(self)
    if candidates == nil or #candidates == 0 then
        log("GENERICROUTE ABORT"
            .. " | reason=no valid existing routes found"
            .. " | error=" .. tostring(candidateErr or "")
            .. " | cleanupScheduled=true")

        scheduleFailureCleanup(
            self,
            "no valid existing routes found",
            "no_routes"
        )
        return true
    end

    self.existingRouteCandidates = candidates
    self.existingRouteCandidateIndex = 1
    self.existingRoutePhase = "open"
    self.existingRouteTickCounter = 0
    self.existingRouteScanPending = true

    log("GENERICROUTE WORKFLOW ARMED"
        .. " | candidates=" .. tostring(#candidates)
        .. " | firstRouteID=" .. tostring(candidates[1].id)
        .. " | firstRouteName=" .. tostring(candidates[1].name)
        .. " | firstActiveErrors=" .. tostring(candidates[1].activeErrors)
        .. " | next=Tick opens routes until any current-province station with a usable Load/Unload row is found")

    return true
end



local function stationAddLogLong(label, value)
    local text = tostring(value or "")
    local length = #text
    if length == 0 then
        log("STATIONADD TEXT | label=" .. tostring(label) .. " | length=0 | value=")
        return
    end

    local chunkSize = 700
    local position = 1
    local part = 1
    while position <= length do
        local chunk = string.sub(text, position, position + chunkSize - 1)
        log("STATIONADD TEXT"
            .. " | label=" .. tostring(label)
            .. " | length=" .. tostring(length)
            .. " | part=" .. tostring(part)
            .. " | value=" .. tostring(chunk))
        position = position + chunkSize
        part = part + 1
    end
end

local function stationAddInspectType(label, value)
    log("STATIONADD TYPE TARGET"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(value))
        .. " | value=" .. tostring(bindingSafeToString(value)))

    if value == nil then
        return
    end

    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    local getTypeInfoOldFn = rawget(_G, "getTypeInfoDeprecated")

    if type(getTypeInfoFn) == "function" then
        local result, err = safe(function()
            return getTypeInfoFn(value)
        end)
        log("STATIONADD TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | function=getTypeInfo"
            .. " | success=" .. tostring(err == nil)
            .. " | resultType=" .. tostring(type(result))
            .. " | error=" .. tostring(err or ""))
        if err == nil and result ~= nil then
            stationAddLogLong("getTypeInfo." .. tostring(label), result)
        end
    end

    if type(getTypeInfoOldFn) == "function" then
        local result, err = safe(function()
            return getTypeInfoOldFn(value)
        end)
        log("STATIONADD TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | function=getTypeInfoDeprecated"
            .. " | success=" .. tostring(err == nil)
            .. " | resultType=" .. tostring(type(result))
            .. " | error=" .. tostring(err or ""))
        if err == nil and result ~= nil then
            stationAddLogLong("getTypeInfoDeprecated." .. tostring(label), result)
        end
    end
end

function GoodsFinder:ProbeAddStationSurface()
    log("STATIONADD START | inspect empty-route island/station selection surface; no route action invoked")

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local islandOptions = safe(function()
        return selection and selection.IslandOptionPopupData
    end)
    local subMenu = safe(function()
        return selection and selection.SubMenuData
    end)
    local amountPopup = safe(function()
        return selection and selection.AmountPopupData
    end)
    local shipCargo = safe(function()
        return selection and selection.ShipandCargoData
    end)
    local overview = safe(function()
        return scene and scene.TradeOverview
    end)
    local shipSelect = safe(function()
        return scene and scene.TradeShipSelect
    end)
    local routeGroups = safe(function()
        return scene and scene.RouteGroupManagerData
    end)
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)
    local stationData = safe(function()
        return selection and selection.TradeRouteGoodData
    end)

    local stationCount = nil
    local stationCountError = nil
    local haloRoot = rawget(_G, "halo")
    local stationHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodData>"]
        or nil

    if stationData ~= nil
        and type(stationHelper) == "table"
        and type(stationHelper.GetSize) == "function" then
        stationCount, stationCountError = safe(function()
            return stationHelper.GetSize(stationData)
        end)
    end

    log("STATIONADD ROOT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | rememberedAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | rememberedIsland=" .. tostring(self.lastWarehouseAreaName or "")
        .. " | rememberedProductGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | rememberedProductName=" .. tostring(self.lastProductName or "")
        .. " | sceneType=" .. tostring(type(scene))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | panelVisible=" .. tostring(safe(function() return selection and selection.IsPanelVisible end))
        .. " | islandOptionsType=" .. tostring(type(islandOptions))
        .. " | islandOptionsValue=" .. tostring(bindingSafeToString(islandOptions))
        .. " | subMenuType=" .. tostring(type(subMenu))
        .. " | subMenuValue=" .. tostring(bindingSafeToString(subMenu))
        .. " | stationDataType=" .. tostring(type(stationData))
        .. " | stationDataValue=" .. tostring(bindingSafeToString(stationData))
        .. " | stationCount=" .. tostring(stationCount)
        .. " | stationCountError=" .. tostring(stationCountError or ""))

    self:DumpInfoTipContext()

    local targets = {
        {"TradeRouteScene", scene},
        {"TradeGoodSelection", selection},
        {"TradeGoodSelection.IslandOptionPopupData", islandOptions},
        {"TradeGoodSelection.SubMenuData", subMenu},
        {"TradeGoodSelection.AmountPopupData", amountPopup},
        {"TradeGoodSelection.ShipandCargoData", shipCargo},
        {"TradeRouteScene.TradeOverview", overview},
        {"TradeRouteScene.TradeShipSelect", shipSelect},
        {"TradeRouteScene.RouteGroupManagerData", routeGroups},
        {"TradeRoute.UIEditRoute", route},
        {"ui.Scenes.MacroMap", safe(function() return ui and ui.Scenes and ui.Scenes.MacroMap end)},
        {"ui.Scenes.MacroMapInteractive", safe(function() return ui and ui.Scenes and ui.Scenes.MacroMapInteractive end)},
        {"ui.Scenes.MacroMapScene", safe(function() return ui and ui.Scenes and ui.Scenes.MacroMapScene end)},
        {"ui.Scenes.SessionTradeRoutesScene", safe(function() return ui and ui.Scenes and ui.Scenes.SessionTradeRoutesScene end)}
    }

    for _, target in ipairs(targets) do
        local label, value = target[1], target[2]
        stationAddInspectType(label, value)
        if value ~= nil then
            overviewDeepInspect(value, "STATIONADD." .. tostring(label), 0, {})
        end
    end

    local function scanTable(label, root)
        if type(root) ~= "table" then
            log("STATIONADD TABLE SCAN"
                .. " | label=" .. tostring(label)
                .. " | rootType=" .. tostring(type(root))
                .. " | matches=0")
            return
        end

        local matches = {}
        local ok, err = pcall(function()
            for key, value in pairs(root) do
                local keyText = tostring(key)
                local lower = string.lower(keyText)
                local relevant =
                    string.find(lower, "station", 1, true)
                    or string.find(lower, "island", 1, true)
                    or string.find(lower, "traderoute", 1, true)
                    or string.find(lower, "route", 1, true)
                    or string.find(lower, "macromap", 1, true)
                    or string.find(lower, "area", 1, true)
                if relevant then
                    table.insert(matches, {keyText, value})
                end
            end
        end)

        table.sort(matches, function(a, b)
            return tostring(a[1]) < tostring(b[1])
        end)

        log("STATIONADD TABLE SCAN"
            .. " | label=" .. tostring(label)
            .. " | success=" .. tostring(ok)
            .. " | error=" .. tostring(err or "")
            .. " | matches=" .. tostring(#matches))

        local limit = math.min(#matches, 120)
        for index = 1, limit do
            local key, value = matches[index][1], matches[index][2]
            log("STATIONADD TABLE MEMBER"
                .. " | root=" .. tostring(label)
                .. " | index=" .. tostring(index)
                .. " | key=" .. tostring(key)
                .. " | type=" .. tostring(type(value))
                .. " | value=" .. tostring(bindingSafeToString(value)))
            if type(value) == "table" then
                overviewDeepInspect(value, "STATIONADD." .. tostring(label) .. "." .. tostring(key), 0, {})
            end
        end
    end

    scanTable("halo", haloRoot)
    scanTable("Scripts", rawget(_G, "Scripts"))
    scanTable("TradeRoute", rawget(_G, "TradeRoute"))

    local areaCurrent = safe(function()
        return Area and Area.CurrentSelectedArea
    end)
    local areaId = safe(function()
        return areaCurrent and areaCurrent.ID
    end)
    local areaName = safe(function()
        return areaCurrent and areaCurrent.Name
    end)

    log("STATIONADD AREA CONTEXT"
        .. " | currentAreaType=" .. tostring(type(areaCurrent))
        .. " | currentArea=" .. tostring(bindingSafeToString(areaCurrent))
        .. " | currentAreaID=" .. tostring(areaId)
        .. " | currentAreaName=" .. tostring(areaName))

    log("STATIONADD COMPLETE"
        .. " | stationCount=" .. tostring(stationCount)
        .. " | noRouteActionInvoked=true"
        .. " | next=compare while hovering Mytholos and after manually adding Mytholos")

    return true
end


local function islandPressReadPositive(object, keys)
    if object == nil then
        return nil, nil
    end

    for _, key in ipairs(keys or {}) do
        local value = safe(function()
            return object[key]
        end)
        value = tonumber(value)
        if value ~= nil and value > 0 then
            return value, key
        end
    end

    return nil, nil
end

local function islandPressReadText(object, keys)
    if object == nil then
        return nil, nil
    end

    for _, key in ipairs(keys or {}) do
        local value = safe(function()
            return object[key]
        end)
        if value ~= nil then
            local text = tostring(value)
            if text ~= "" and text ~= "nil" then
                return text, key
            end
        end
    end

    return nil, nil
end

local function islandPressArray(value)
    local result = {}
    local haloRoot = rawget(_G, "halo")
    local valueText = bindingSafeToString(value)
    local helperKey = string.match(valueText, "^(PhoenixArray<[^>]+>)")
    local helper = type(haloRoot) == "table" and helperKey and haloRoot[helperKey] or nil

    if type(helper) ~= "table"
        or type(helper.GetSize) ~= "function"
        or type(helper.GetElement) ~= "function" then
        log("ISLANDPRESS ARRAY"
            .. " | helperKey=" .. tostring(helperKey)
            .. " | helperUnavailable=true"
            .. " | value=" .. tostring(valueText))
        return result, helperKey
    end

    local size, sizeErr = safe(function()
        return helper.GetSize(value)
    end)

    log("ISLANDPRESS ARRAY"
        .. " | helperKey=" .. tostring(helperKey)
        .. " | size=" .. tostring(size)
        .. " | error=" .. tostring(sizeErr or "")
        .. " | value=" .. tostring(valueText))

    if type(size) ~= "number" or size < 0 then
        return result, helperKey
    end

    local limit = math.min(math.floor(size), 256)
    for index = 0, limit - 1 do
        local item, itemErr = safe(function()
            return helper.GetElement(value, index)
        end)
        if item ~= nil then
            result[#result + 1] = {
                value = item,
                arrayIndex = index,
                error = itemErr
            }
        end
    end

    return result, helperKey
end

local function islandPressStationCount()
    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local stations = safe(function()
        return selection and selection.TradeRouteGoodData
    end)
    local haloRoot = rawget(_G, "halo")
    local helper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodData>"]
        or nil

    if stations == nil
        or type(helper) ~= "table"
        or type(helper.GetSize) ~= "function" then
        return nil, "station array/helper unavailable"
    end

    return safe(function()
        return helper.GetSize(stations)
    end)
end

local function islandPressDescribeEntries()
    local macroScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.MacroMap
    end)
    local macroData = safe(function()
        return macroScene and macroScene.MacroMapData
    end)
    local islandsList = safe(function()
        return macroData and macroData.IslandsList
    end)

    log("ISLANDPRESS MAP"
        .. " | macroSceneType=" .. tostring(type(macroScene))
        .. " | macroScene=" .. tostring(bindingSafeToString(macroScene))
        .. " | macroDataType=" .. tostring(type(macroData))
        .. " | macroData=" .. tostring(bindingSafeToString(macroData))
        .. " | islandsListType=" .. tostring(type(islandsList))
        .. " | islandsList=" .. tostring(bindingSafeToString(islandsList)))

    local rawEntries, helperKey = islandPressArray(islandsList)
    local entries = {}

    local idKeys = {
        "RefGuid", "AreaID", "AreaId", "IslandID", "IslandId",
        "ID", "Guid", "GUID", "ObjectID", "ObjectId", "RefOid"
    }
    local nameKeys = {
        "IslandName", "AreaName", "CityName", "Name", "Text", "Label", "Title"
    }

    for _, rawEntry in ipairs(rawEntries) do
        local item = rawEntry.value
        local base = safe(function()
            return item and item.BaseData
        end)
        if base == nil then
            base = item
        end

        local context = safe(function()
            return base and base.InfoTipContext
        end)
        local infoTip = safe(function()
            return base and base.InfoTip
        end)

        local areaId, areaSource = islandPressReadPositive(context, idKeys)
        if areaId == nil then
            areaId, areaSource = islandPressReadPositive(infoTip, idKeys)
            if areaSource ~= nil then areaSource = "InfoTip." .. areaSource end
        else
            areaSource = "InfoTipContext." .. tostring(areaSource)
        end
        if areaId == nil then
            areaId, areaSource = islandPressReadPositive(base, idKeys)
            if areaSource ~= nil then areaSource = "BaseData." .. areaSource end
        end
        if areaId == nil then
            areaId, areaSource = islandPressReadPositive(item, idKeys)
            if areaSource ~= nil then areaSource = "IslandItem." .. areaSource end
        end

        local islandName, nameSource = islandPressReadText(context, nameKeys)
        if islandName == nil then
            islandName, nameSource = islandPressReadText(infoTip, nameKeys)
            if nameSource ~= nil then nameSource = "InfoTip." .. nameSource end
        else
            nameSource = "InfoTipContext." .. tostring(nameSource)
        end
        if islandName == nil then
            islandName, nameSource = islandPressReadText(base, nameKeys)
            if nameSource ~= nil then nameSource = "BaseData." .. nameSource end
        end
        if islandName == nil then
            islandName, nameSource = islandPressReadText(item, nameKeys)
            if nameSource ~= nil then nameSource = "IslandItem." .. nameSource end
        end

        local isHovered = safe(function() return base and base.IsHovered end)
        local isTradeDisabled = safe(function() return base and base.IsTradeDisabled end)
        local btnStates = safe(function() return base and base.BtnStates end)
        local onPress = safe(function() return base and base.OnPress end)

        log("ISLANDPRESS ITEM"
            .. " | arrayIndex=" .. tostring(rawEntry.arrayIndex)
            .. " | itemType=" .. tostring(type(item))
            .. " | item=" .. tostring(bindingSafeToString(item))
            .. " | baseType=" .. tostring(type(base))
            .. " | base=" .. tostring(bindingSafeToString(base))
            .. " | contextType=" .. tostring(type(context))
            .. " | context=" .. tostring(bindingSafeToString(context))
            .. " | infoTipType=" .. tostring(type(infoTip))
            .. " | infoTip=" .. tostring(bindingSafeToString(infoTip))
            .. " | areaID=" .. tostring(areaId)
            .. " | areaSource=" .. tostring(areaSource)
            .. " | islandName=" .. tostring(islandName)
            .. " | nameSource=" .. tostring(nameSource)
            .. " | isHovered=" .. tostring(isHovered)
            .. " | isTradeDisabled=" .. tostring(isTradeDisabled)
            .. " | btnStates=" .. tostring(bindingSafeToString(btnStates))
            .. " | onPressType=" .. tostring(type(onPress)))

        entries[#entries + 1] = {
            item = item,
            base = base,
            context = context,
            infoTip = infoTip,
            arrayIndex = rawEntry.arrayIndex,
            areaId = areaId,
            areaSource = areaSource,
            islandName = islandName,
            nameSource = nameSource,
            isHovered = isHovered,
            isTradeDisabled = isTradeDisabled,
            onPress = onPress
        }
    end

    return entries, helperKey
end

local function islandPressInvoke(entry, label)
    if entry == nil then
        log("ISLANDPRESS CALL ABORT"
            .. " | label=" .. tostring(label)
            .. " | reason=no matching island entry")
        return false
    end

    local method = entry.onPress
    if type(method) ~= "function" then
        method = safe(function()
            return entry.base and entry.base.OnPress
        end)
    end

    if type(method) ~= "function" then
        log("ISLANDPRESS CALL ABORT"
            .. " | label=" .. tostring(label)
            .. " | reason=OnPress unavailable"
            .. " | arrayIndex=" .. tostring(entry.arrayIndex)
            .. " | areaID=" .. tostring(entry.areaId))
        return false
    end

    local beforeCount, beforeErr = islandPressStationCount()
    local result, err = safe(function()
        return method(entry.base)
    end)
    local mode = "BaseData.OnPress(baseData)"

    if err ~= nil then
        result, err = safe(function()
            return method()
        end)
        mode = "BaseData.OnPress()"
    end

    local afterCount, afterErr = islandPressStationCount()

    log("ISLANDPRESS CALL"
        .. " | label=" .. tostring(label)
        .. " | mode=" .. tostring(mode)
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(result)
        .. " | error=" .. tostring(err or "")
        .. " | arrayIndex=" .. tostring(entry.arrayIndex)
        .. " | areaID=" .. tostring(entry.areaId)
        .. " | islandName=" .. tostring(entry.islandName)
        .. " | stationCountBefore=" .. tostring(beforeCount)
        .. " | stationCountBeforeError=" .. tostring(beforeErr or "")
        .. " | stationCountAfter=" .. tostring(afterCount)
        .. " | stationCountAfterError=" .. tostring(afterErr or ""))

    return err == nil
end

function GoodsFinder:AutoAddRememberedAndHelperStations()
    log("ISLANDPRESS START | find MacroMap island instances and invoke their vanilla OnPress handlers")

    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)
    local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0
    local rememberedName = tostring(self.lastWarehouseAreaName or "")
    local currentInfoGuid = tonumber(safe(function() return InfoTip and InfoTip.RefGuid end)) or 0
    local stationCountBefore, stationCountBeforeErr = islandPressStationCount()

    log("ISLANDPRESS CONTEXT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
        .. " | rememberedIsland=" .. tostring(rememberedName)
        .. " | InfoTip.RefGuid=" .. tostring(currentInfoGuid)
        .. " | stationCountBefore=" .. tostring(stationCountBefore)
        .. " | stationCountBeforeError=" .. tostring(stationCountBeforeErr or ""))

    if routeValid ~= true then
        log("ISLANDPRESS ABORT | reason=no valid temporary route editor")
        return false
    end

    local entries = islandPressDescribeEntries()
    local rememberedEntry = nil
    local hoveredEntry = nil

    for _, entry in ipairs(entries) do
        if tonumber(entry.areaId) == rememberedAreaId then
            rememberedEntry = entry
        end
        if entry.isHovered == true then
            hoveredEntry = entry
        end
    end

    if rememberedEntry == nil
        and currentInfoGuid == rememberedAreaId
        and hoveredEntry ~= nil then
        rememberedEntry = hoveredEntry
        log("ISLANDPRESS MATCH"
            .. " | label=remembered"
            .. " | mode=hovered fallback"
            .. " | arrayIndex=" .. tostring(hoveredEntry.arrayIndex)
            .. " | areaID=" .. tostring(hoveredEntry.areaId))
    elseif rememberedEntry ~= nil then
        log("ISLANDPRESS MATCH"
            .. " | label=remembered"
            .. " | mode=areaID"
            .. " | arrayIndex=" .. tostring(rememberedEntry.arrayIndex)
            .. " | areaID=" .. tostring(rememberedEntry.areaId)
            .. " | areaSource=" .. tostring(rememberedEntry.areaSource)
            .. " | islandName=" .. tostring(rememberedEntry.islandName))
    end

    local rememberedSuccess = false
    local countNow = stationCountBefore

    if type(countNow) ~= "number" or countNow < 1 then
        rememberedSuccess = islandPressInvoke(rememberedEntry, "remembered")
        countNow = islandPressStationCount()
    else
        rememberedSuccess = true
        log("ISLANDPRESS SKIP"
            .. " | label=remembered"
            .. " | reason=route already has at least one station"
            .. " | stationCount=" .. tostring(countNow))
    end

    local helperTargetId = nil
    for _, record in ipairs(self.lastStockRecords or {}) do
        local candidate = tonumber(record.areaId)
        if candidate ~= nil and candidate > 0 and candidate ~= rememberedAreaId then
            helperTargetId = candidate
            break
        end
    end

    local helperEntry = nil
    if helperTargetId ~= nil then
        local refreshedEntries = islandPressDescribeEntries()
        for _, entry in ipairs(refreshedEntries) do
            if tonumber(entry.areaId) == helperTargetId then
                helperEntry = entry
                break
            end
        end
    end

    log("ISLANDPRESS MATCH"
        .. " | label=helper"
        .. " | requestedAreaID=" .. tostring(helperTargetId)
        .. " | found=" .. tostring(helperEntry ~= nil)
        .. " | arrayIndex=" .. tostring(helperEntry and helperEntry.arrayIndex)
        .. " | areaID=" .. tostring(helperEntry and helperEntry.areaId)
        .. " | islandName=" .. tostring(helperEntry and helperEntry.islandName))

    local countBeforeHelper, countBeforeHelperErr = islandPressStationCount()
    local helperSuccess = false

    if type(countBeforeHelper) == "number" and countBeforeHelper >= 2 then
        helperSuccess = true
        log("ISLANDPRESS SKIP"
            .. " | label=helper"
            .. " | reason=route already has at least two stations"
            .. " | stationCount=" .. tostring(countBeforeHelper))
    else
        helperSuccess = islandPressInvoke(helperEntry, "helper")
    end

    local stationCountAfter, stationCountAfterErr = islandPressStationCount()

    log("ISLANDPRESS COMPLETE"
        .. " | rememberedSuccess=" .. tostring(rememberedSuccess)
        .. " | helperSuccess=" .. tostring(helperSuccess)
        .. " | stationCountAfter=" .. tostring(stationCountAfter)
        .. " | stationCountAfterError=" .. tostring(stationCountAfterErr or "")
        .. " | next=when stationCountAfter is 2, press Ctrl+Alt+K")

    return type(stationCountAfter) == "number" and stationCountAfter >= 2
end


local function hoverpressReadVectorComponent(value, keys)
    if value == nil then return nil, nil end
    for _, key in ipairs(keys or {}) do
        local component = safe(function() return value[key] end)
        component = tonumber(component)
        if component ~= nil then
            return component, key
        end
    end
    return nil, nil
end

local function hoverpressVector(value)
    local x, xKey = hoverpressReadVectorComponent(value, {"X", "x", "Horizontal", "U", "u"})
    local y, yKey = hoverpressReadVectorComponent(value, {"Y", "y", "Vertical", "V", "v"})
    return x, y, xKey, yKey
end

local function hoverpressExtractAliases(value)
    local aliases = {}
    local seen = {}
    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    if value == nil or type(getTypeInfoFn) ~= "function" then
        return aliases, nil
    end

    local typeInfo, err = safe(function()
        return getTypeInfoFn(value)
    end)
    if type(typeInfo) ~= "string" then
        return aliases, err
    end

    for alias in string.gmatch(typeInfo, '"Alias"%s*:%s*"([^"]+)"') do
        if not seen[alias] then
            seen[alias] = true
            aliases[#aliases + 1] = alias
        end
    end
    table.sort(aliases)
    return aliases, err
end

local function hoverpressDumpProperties(label, value)
    log("HOVERPRESS OBJECT"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(value))
        .. " | value=" .. tostring(bindingSafeToString(value)))

    if value == nil then return end

    local aliases, aliasErr = hoverpressExtractAliases(value)
    log("HOVERPRESS ALIASES"
        .. " | label=" .. tostring(label)
        .. " | count=" .. tostring(#aliases)
        .. " | error=" .. tostring(aliasErr or "")
        .. " | values=" .. table.concat(aliases, " ; "))

    for _, alias in ipairs(aliases) do
        local property, propertyErr = safe(function()
            return value[alias]
        end)
        log("HOVERPRESS PROPERTY"
            .. " | object=" .. tostring(label)
            .. " | property=" .. tostring(alias)
            .. " | type=" .. tostring(type(property))
            .. " | value=" .. tostring(bindingSafeToString(property))
            .. " | error=" .. tostring(propertyErr or ""))
    end

    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    if type(getTypeInfoFn) == "function" then
        local typeInfo, typeInfoErr = safe(function()
            return getTypeInfoFn(value)
        end)
        log("HOVERPRESS TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | success=" .. tostring(typeInfoErr == nil)
            .. " | resultType=" .. tostring(type(typeInfo))
            .. " | error=" .. tostring(typeInfoErr or ""))
        if typeInfoErr == nil and typeInfo ~= nil then
            stationAddLogLong("HOVERPRESS." .. tostring(label), typeInfo)
        end
    end
end

local function hoverpressGetEntries()
    local macroScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.MacroMap
    end)
    local macroData = safe(function()
        return macroScene and macroScene.MacroMapData
    end)
    local islandsList = safe(function()
        return macroData and macroData.IslandsList
    end)

    local rawEntries = islandPressArray(islandsList)
    local entries = {}

    for _, rawEntry in ipairs(rawEntries or {}) do
        local item = rawEntry.value
        local base = safe(function()
            return item and item.BaseData
        end)
        if base ~= nil then
            local position = safe(function() return base.Position end)
            local x, y = hoverpressVector(position)
            entries[#entries + 1] = {
                arrayIndex = rawEntry.arrayIndex,
                item = item,
                base = base,
                position = position,
                x = x,
                y = y,
                isHovered = safe(function() return base.IsHovered end),
                isTradeDisabled = safe(function() return base.IsTradeDisabled end),
                infoTip = safe(function() return base.InfoTip end),
                context = safe(function() return base.InfoTipContext end),
                btnStates = safe(function() return base.BtnStates end),
                onPress = safe(function() return base.OnPress end)
            }
        end
    end

    return entries, macroScene, macroData
end

local function hoverpressNearest(entries, mouseX, mouseY)
    if type(mouseX) ~= "number" or type(mouseY) ~= "number" then
        return nil, nil
    end

    local best, bestDistance = nil, nil
    for _, entry in ipairs(entries or {}) do
        if entry.isTradeDisabled ~= true
            and type(entry.x) == "number"
            and type(entry.y) == "number" then
            local dx = entry.x - mouseX
            local dy = entry.y - mouseY
            local distance = dx * dx + dy * dy
            if bestDistance == nil or distance < bestDistance then
                best = entry
                bestDistance = distance
            end
        end
    end
    return best, bestDistance
end

function GoodsFinder:PressHoveredMacroMapIslandStation()
    log("HOVERPRESS START | invoke the vanilla OnPress handler of the island currently under the mouse")

    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)
    local stationCountBefore, stationCountBeforeErr = islandPressStationCount()
    local infoGuid = tonumber(safe(function() return InfoTip and InfoTip.RefGuid end)) or 0
    local infoOid = tonumber(safe(function() return InfoTip and InfoTip.RefOid end)) or 0
    local infoTextId = safe(function() return InfoTip and InfoTip.RefTextId end)

    log("HOVERPRESS CONTEXT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCountBefore=" .. tostring(stationCountBefore)
        .. " | stationCountBeforeError=" .. tostring(stationCountBeforeErr or "")
        .. " | InfoTip.RefGuid=" .. tostring(infoGuid)
        .. " | InfoTip.RefOid=" .. tostring(infoOid)
        .. " | InfoTip.RefTextId=" .. tostring(infoTextId)
        .. " | rememberedAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | rememberedIsland=" .. tostring(self.lastWarehouseAreaName or ""))

    if routeValid ~= true then
        log("HOVERPRESS ABORT | reason=no valid temporary route")
        return false
    end

    local entries, macroScene, macroData = hoverpressGetEntries()
    local hovered = nil
    local hoveredCount = 0

    for _, entry in ipairs(entries or {}) do
        if entry.isHovered == true then
            hovered = entry
            hoveredCount = hoveredCount + 1
        end
    end

    local localMouse = safe(function() return macroData and macroData.LocalMousePosition end)
    local globalMouse = safe(function() return macroData and macroData.GlobalMousePosition end)
    local localX, localY = hoverpressVector(localMouse)
    local globalX, globalY = hoverpressVector(globalMouse)
    local nearest, nearestDistance = hoverpressNearest(entries, localX, localY)

    log("HOVERPRESS MOUSE"
        .. " | localMouse=" .. tostring(bindingSafeToString(localMouse))
        .. " | localX=" .. tostring(localX)
        .. " | localY=" .. tostring(localY)
        .. " | globalMouse=" .. tostring(bindingSafeToString(globalMouse))
        .. " | globalX=" .. tostring(globalX)
        .. " | globalY=" .. tostring(globalY)
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | nearestIndex=" .. tostring(nearest and nearest.arrayIndex)
        .. " | nearestDistanceSquared=" .. tostring(nearestDistance))

    local target = hovered
    local targetMode = "IsHovered=true"
    if target == nil and nearest ~= nil then
        target = nearest
        targetMode = "nearest LocalMousePosition"
    end

    if target == nil then
        log("HOVERPRESS ABORT | reason=no hovered or nearest island marker found")
        return false
    end

    log("HOVERPRESS TARGET"
        .. " | mode=" .. tostring(targetMode)
        .. " | arrayIndex=" .. tostring(target.arrayIndex)
        .. " | isHovered=" .. tostring(target.isHovered)
        .. " | isTradeDisabled=" .. tostring(target.isTradeDisabled)
        .. " | position=" .. tostring(bindingSafeToString(target.position))
        .. " | x=" .. tostring(target.x)
        .. " | y=" .. tostring(target.y)
        .. " | base=" .. tostring(bindingSafeToString(target.base))
        .. " | onPressType=" .. tostring(type(target.onPress)))

    hoverpressDumpProperties("Target.BaseData", target.base)
    hoverpressDumpProperties("Target.InfoTip", target.infoTip)
    hoverpressDumpProperties("Target.InfoTipContext", target.context)
    hoverpressDumpProperties("Target.BtnStates", target.btnStates)
    hoverpressDumpProperties("Target.Position", target.position)

    local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0
    if type(stationCountBefore) == "number"
        and stationCountBefore == 0
        and infoGuid ~= rememberedAreaId then
        log("HOVERPRESS ABORT"
            .. " | reason=first station must be remembered island"
            .. " | hoveredInfoGuid=" .. tostring(infoGuid)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
            .. " | move mouse over Mytholos and retry")
        return false
    end

    if type(stationCountBefore) == "number"
        and stationCountBefore >= 1
        and infoGuid == rememberedAreaId then
        log("HOVERPRESS ABORT"
            .. " | reason=second station must be a different island"
            .. " | hoveredInfoGuid=" .. tostring(infoGuid)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
        return false
    end

    if target.isTradeDisabled == true then
        log("HOVERPRESS ABORT"
            .. " | reason=target island is trade-disabled"
            .. " | arrayIndex=" .. tostring(target.arrayIndex))
        return false
    end

    if type(target.onPress) ~= "function" then
        log("HOVERPRESS ABORT"
            .. " | reason=OnPress unavailable"
            .. " | arrayIndex=" .. tostring(target.arrayIndex))
        return false
    end

    local sceneFocusValue, sceneFocusErr = safe(function()
        if macroScene ~= nil and type(macroScene.RequestFocus) == "function" then
            return macroScene.RequestFocus(macroScene)
        end
        return nil
    end)

    local dataFocusValue, dataFocusErr = safe(function()
        if macroData ~= nil and type(macroData.RequestFocus) == "function" then
            return macroData.RequestFocus(macroData)
        end
        return nil
    end)

    log("HOVERPRESS FOCUS"
        .. " | sceneSuccess=" .. tostring(sceneFocusErr == nil)
        .. " | sceneReturnType=" .. tostring(type(sceneFocusValue))
        .. " | sceneReturnValue=" .. tostring(sceneFocusValue)
        .. " | sceneError=" .. tostring(sceneFocusErr or "")
        .. " | dataSuccess=" .. tostring(dataFocusErr == nil)
        .. " | dataReturnType=" .. tostring(type(dataFocusValue))
        .. " | dataReturnValue=" .. tostring(dataFocusValue)
        .. " | dataError=" .. tostring(dataFocusErr or ""))

    local btnFocusedBefore = safe(function()
        return target.btnStates and target.btnStates.IsFocused
    end)
    local btnSelectedBefore = safe(function()
        return target.btnStates and target.btnStates.IsSelected
    end)

    local setFocusedResult, setFocusedErr = safe(function()
        if target.btnStates ~= nil then
            target.btnStates.IsFocused = true
            return target.btnStates.IsFocused
        end
        return nil
    end)

    log("HOVERPRESS BUTTON STATE"
        .. " | focusedBefore=" .. tostring(btnFocusedBefore)
        .. " | selectedBefore=" .. tostring(btnSelectedBefore)
        .. " | setFocusedSuccess=" .. tostring(setFocusedErr == nil)
        .. " | focusedAfter=" .. tostring(setFocusedResult)
        .. " | setFocusedError=" .. tostring(setFocusedErr or ""))

    local tradeScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local shipSelect = safe(function()
        return tradeScene and tradeScene.TradeShipSelect
    end)
    local currentShip = safe(function()
        return shipSelect and shipSelect.CurrentShipData
    end)
    local selectedShipList = safe(function()
        return shipSelect and shipSelect.SelectedShipList
    end)
    local selectedShips = islandPressArray(selectedShipList)

    log("HOVERCONFIRM SHIP STATE"
        .. " | currentShipType=" .. tostring(type(currentShip))
        .. " | currentShip=" .. tostring(bindingSafeToString(currentShip))
        .. " | selectedShipListType=" .. tostring(type(selectedShipList))
        .. " | selectedShipCount=" .. tostring(#(selectedShips or {}))
        .. " | note=ship presence is logged but not required for the island action")

    log("FOCUSED ONPRESS READY"
        .. " | targetArrayIndex=" .. tostring(target.arrayIndex)
        .. " | targetAreaID=" .. tostring(infoGuid)
        .. " | isHovered=" .. tostring(target.isHovered)
        .. " | focused=" .. tostring(safe(function()
            return target.btnStates and target.btnStates.IsFocused
        end))
        .. " | selected=" .. tostring(safe(function()
            return target.btnStates and target.btnStates.IsSelected
        end))
        .. " | onPressType=" .. tostring(type(target.onPress)))

    if type(target.onPress) ~= "function" then
        log("FOCUSED ONPRESS ABORT | reason=target OnPress unavailable")
        return false
    end

    -- v0.13.25 called OnPress(baseData) while the marker itself was not focused.
    -- v0.13.26 proved that OnPress() is invalid, while also proving that the
    -- marker's BtnStates.IsFocused flag can be written successfully.
    -- This is the previously untested combination:
    -- focused live marker + required MacroMapIslandBaseData argument.
    local result, err = safe(function()
        return target.onPress(target.base)
    end)
    local mode = "BaseData.OnPress(baseData) after BtnStates.IsFocused=true"

    local stationCountAfter, stationCountAfterErr = islandPressStationCount()

    log("FOCUSED ONPRESS DISPATCH"
        .. " | mode=" .. tostring(mode)
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(result)
        .. " | error=" .. tostring(err or "")
        .. " | arrayIndex=" .. tostring(target.arrayIndex)
        .. " | InfoTip.RefGuid=" .. tostring(infoGuid)
        .. " | stationCountBefore=" .. tostring(stationCountBefore)
        .. " | stationCountAfterImmediate=" .. tostring(stationCountAfter)
        .. " | stationCountAfterError=" .. tostring(stationCountAfterErr or ""))

    self.lastPressedIslandArrayIndex = target.arrayIndex
    self.lastPressedIslandAreaId = infoGuid

    log("FOCUSED ONPRESS COMPLETE"
        .. " | dispatchSuccess=" .. tostring(err == nil)
        .. " | next=wait three seconds for a station row; do not click the island manually")

    return err == nil
end


local function manualDiffNormalize(value)
    if value == nil then
        return "<nil>"
    end

    local valueType = type(value)
    if valueType == "boolean" or valueType == "number" or valueType == "string" then
        return valueType .. ":" .. tostring(value)
    end

    local text = tostring(bindingSafeToString(value))
    text = string.gsub(text, "0x[%da-fA-F]+", "0x*")
    return valueType .. ":" .. text
end

local function manualDiffArraySize(value)
    if value == nil then
        return nil, nil
    end

    local haloRoot = rawget(_G, "halo")
    local valueText = bindingSafeToString(value)
    local helperKey = string.match(valueText, "^(PhoenixArray<[^>]+>)")
    local helper = type(haloRoot) == "table" and helperKey and haloRoot[helperKey] or nil

    if type(helper) ~= "table" or type(helper.GetSize) ~= "function" then
        return nil, helperKey
    end

    local size = safe(function()
        return helper.GetSize(value)
    end)
    return size, helperKey
end

local function manualDiffAliases(value)
    local aliases = {}
    local seen = {}
    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    if value == nil or type(getTypeInfoFn) ~= "function" then
        return aliases, nil
    end

    local info, err = safe(function()
        return getTypeInfoFn(value)
    end)
    if type(info) ~= "string" then
        return aliases, err
    end

    for alias in string.gmatch(info, '"Alias"%s*:%s*"([^"]+)"') do
        if not seen[alias] then
            seen[alias] = true
            aliases[#aliases + 1] = alias
        end
    end
    table.sort(aliases)
    return aliases, err
end

local function manualDiffAdd(snapshot, key, value)
    snapshot[key] = manualDiffNormalize(value)
end

local function manualDiffCaptureObject(snapshot, path, value)
    manualDiffAdd(snapshot, path .. ".__type", type(value))
    manualDiffAdd(snapshot, path .. ".__value", value)

    if value == nil then
        return
    end

    local size, helperKey = manualDiffArraySize(value)
    if helperKey ~= nil then
        manualDiffAdd(snapshot, path .. ".__arrayHelper", helperKey)
    end
    if size ~= nil then
        manualDiffAdd(snapshot, path .. ".__arraySize", size)
    end

    local aliases = manualDiffAliases(value)
    for _, alias in ipairs(aliases or {}) do
        local property, err = safe(function()
            return value[alias]
        end)

        manualDiffAdd(snapshot, path .. "." .. tostring(alias) .. ".__readError", err or "")
        manualDiffAdd(snapshot, path .. "." .. tostring(alias), property)

        local propertySize, propertyHelper = manualDiffArraySize(property)
        if propertyHelper ~= nil then
            manualDiffAdd(
                snapshot,
                path .. "." .. tostring(alias) .. ".__arrayHelper",
                propertyHelper
            )
        end
        if propertySize ~= nil then
            manualDiffAdd(
                snapshot,
                path .. "." .. tostring(alias) .. ".__arraySize",
                propertySize
            )
        end
    end
end

local function manualDiffDumpTypeInfo(label, value)
    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    if value == nil or type(getTypeInfoFn) ~= "function" then
        log("MANUALDIFF TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | available=false"
            .. " | valueType=" .. tostring(type(value)))
        return
    end

    local result, err = safe(function()
        return getTypeInfoFn(value)
    end)

    log("MANUALDIFF TYPEINFO"
        .. " | label=" .. tostring(label)
        .. " | success=" .. tostring(err == nil)
        .. " | resultType=" .. tostring(type(result))
        .. " | error=" .. tostring(err or ""))

    if err == nil and result ~= nil then
        stationAddLogLong("MANUALDIFF." .. tostring(label), result)
    end
end

local function manualDiffGetHoveredEntry()
    local entries, macroScene, macroData = hoverpressGetEntries()
    local hovered = nil
    local hoveredCount = 0

    for _, entry in ipairs(entries or {}) do
        if entry.isHovered == true then
            hovered = entry
            hoveredCount = hoveredCount + 1
        end
    end

    return hovered, hoveredCount, entries, macroScene, macroData
end

local function manualDiffCaptureStationData(snapshot, selection)
    local stationArray = safe(function()
        return selection and selection.TradeRouteGoodData
    end)
    manualDiffCaptureObject(snapshot, "TradeGoodSelection.TradeRouteGoodData", stationArray)

    local stations = islandPressArray(stationArray)
    manualDiffAdd(snapshot, "TradeGoodSelection.TradeRouteGoodData.__enumeratedCount", #(stations or {}))

    for _, stationEntry in ipairs(stations or {}) do
        local station = stationEntry.value
        local prefix = "TradeGoodSelection.TradeRouteGoodData[" .. tostring(stationEntry.arrayIndex) .. "]"
        manualDiffCaptureObject(snapshot, prefix, station)

        local loadUnload = safe(function()
            return station and station.TradeRouteLoadandUnloadData
        end)
        manualDiffCaptureObject(snapshot, prefix .. ".TradeRouteLoadandUnloadData", loadUnload)

        local loadUnloadEntries = islandPressArray(loadUnload)
        manualDiffAdd(
            snapshot,
            prefix .. ".TradeRouteLoadandUnloadData.__enumeratedCount",
            #(loadUnloadEntries or {})
        )

        for _, islandEntry in ipairs(loadUnloadEntries or {}) do
            manualDiffCaptureObject(
                snapshot,
                prefix
                    .. ".TradeRouteLoadandUnloadData["
                    .. tostring(islandEntry.arrayIndex)
                    .. "]",
                islandEntry.value
            )
        end
    end
end

local function manualDiffCaptureIslandList(snapshot, macroData)
    local islandsList = safe(function()
        return macroData and macroData.IslandsList
    end)
    manualDiffCaptureObject(snapshot, "MacroMapData.IslandsList", islandsList)

    local rawEntries = islandPressArray(islandsList)
    manualDiffAdd(snapshot, "MacroMapData.IslandsList.__enumeratedCount", #(rawEntries or {}))

    for _, rawEntry in ipairs(rawEntries or {}) do
        local item = rawEntry.value
        local base = safe(function()
            return item and item.BaseData
        end)
        local infoTip = safe(function()
            return base and base.InfoTip
        end)
        local context = safe(function()
            return base and base.InfoTipContext
        end)
        local btnStates = safe(function()
            return base and base.BtnStates
        end)
        local prefix = "MacroMapData.IslandsList[" .. tostring(rawEntry.arrayIndex) .. "]"

        manualDiffCaptureObject(snapshot, prefix, item)
        manualDiffCaptureObject(snapshot, prefix .. ".BaseData", base)
        manualDiffCaptureObject(snapshot, prefix .. ".BaseData.InfoTip", infoTip)
        manualDiffCaptureObject(snapshot, prefix .. ".BaseData.InfoTipContext", context)
        manualDiffCaptureObject(snapshot, prefix .. ".BaseData.BtnStates", btnStates)
    end
end

local function manualDiffCaptureSnapshot(label)
    local snapshot = {}

    local tradeScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return tradeScene and tradeScene.TradeGoodSelection
    end)
    local islandOptions = safe(function()
        return selection and selection.IslandOptionPopupData
    end)
    local subMenu = safe(function()
        return selection and selection.SubMenuData
    end)
    local shipCargo = safe(function()
        return selection and selection.ShipandCargoData
    end)
    local shipSelect = safe(function()
        return tradeScene and tradeScene.TradeShipSelect
    end)
    local overview = safe(function()
        return tradeScene and tradeScene.TradeOverview
    end)
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)

    local hovered, hoveredCount, entries, macroScene, macroData = manualDiffGetHoveredEntry()
    local stationCount, stationCountErr = islandPressStationCount()

    manualDiffAdd(snapshot, "Snapshot.Label", label)
    manualDiffAdd(snapshot, "Route.Valid", routeValid)
    manualDiffAdd(snapshot, "Route.StationCount", stationCount)
    manualDiffAdd(snapshot, "Route.StationCountError", stationCountErr or "")
    manualDiffAdd(snapshot, "Hover.Count", hoveredCount)
    manualDiffAdd(snapshot, "Hover.ArrayIndex", hovered and hovered.arrayIndex)
    manualDiffAdd(snapshot, "Hover.InfoTip.RefGUID", safe(function()
        return hovered and hovered.infoTip and hovered.infoTip.RefGUID
    end))
    manualDiffAdd(snapshot, "Hover.InfoTip.GlobalRefGuid", safe(function()
        return InfoTip and InfoTip.RefGuid
    end))
    manualDiffAdd(snapshot, "Hover.InfoTip.GlobalRefOid", safe(function()
        return InfoTip and InfoTip.RefOid
    end))
    manualDiffAdd(snapshot, "Hover.EntryCount", #(entries or {}))
    manualDiffAdd(snapshot, "Remembered.AreaID", GoodsFinder.lastWarehouseAreaId or 0)
    manualDiffAdd(snapshot, "Remembered.AreaName", GoodsFinder.lastWarehouseAreaName or "")
    manualDiffAdd(snapshot, "Remembered.ProductGUID", GoodsFinder.lastProductGuid or 0)
    manualDiffAdd(snapshot, "Remembered.ProductName", GoodsFinder.lastProductName or "")

    manualDiffCaptureObject(snapshot, "TradeRouteScene", tradeScene)
    manualDiffCaptureObject(snapshot, "TradeGoodSelection", selection)
    manualDiffCaptureObject(snapshot, "TradeGoodSelection.IslandOptionPopupData", islandOptions)
    manualDiffCaptureObject(snapshot, "TradeGoodSelection.SubMenuData", subMenu)
    manualDiffCaptureObject(snapshot, "TradeGoodSelection.ShipandCargoData", shipCargo)
    manualDiffCaptureObject(snapshot, "TradeRouteScene.TradeShipSelect", shipSelect)
    manualDiffCaptureObject(snapshot, "TradeRouteScene.TradeOverview", overview)
    manualDiffCaptureObject(snapshot, "TradeRoute.UIEditRoute", route)
    manualDiffCaptureObject(snapshot, "MacroMapScene", macroScene)
    manualDiffCaptureObject(snapshot, "MacroMapData", macroData)

    if hovered ~= nil then
        manualDiffCaptureObject(snapshot, "HoveredIsland.Item", hovered.item)
        manualDiffCaptureObject(snapshot, "HoveredIsland.BaseData", hovered.base)
        manualDiffCaptureObject(snapshot, "HoveredIsland.InfoTip", hovered.infoTip)
        manualDiffCaptureObject(snapshot, "HoveredIsland.InfoTipContext", hovered.context)
        manualDiffCaptureObject(snapshot, "HoveredIsland.BtnStates", hovered.btnStates)
    end

    manualDiffCaptureStationData(snapshot, selection)
    manualDiffCaptureIslandList(snapshot, macroData)

    log("MANUALDIFF SNAPSHOT"
        .. " | label=" .. tostring(label)
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCount=" .. tostring(stationCount)
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | hoveredAreaID=" .. tostring(safe(function()
            return hovered and hovered.infoTip and hovered.infoTip.RefGUID
        end))
        .. " | keyCount=" .. tostring((function()
            local count = 0
            for _ in pairs(snapshot) do count = count + 1 end
            return count
        end)()))

    return snapshot, {
        tradeScene = tradeScene,
        selection = selection,
        islandOptions = islandOptions,
        subMenu = subMenu,
        route = route,
        macroScene = macroScene,
        macroData = macroData,
        hovered = hovered
    }
end

local function manualDiffDumpChanged(beforeSnapshot, afterSnapshot)
    local keys = {}
    local seen = {}

    for key in pairs(beforeSnapshot or {}) do
        if not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end
    for key in pairs(afterSnapshot or {}) do
        if not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end

    table.sort(keys)

    local changeCount = 0
    for _, key in ipairs(keys) do
        local beforeValue = beforeSnapshot and beforeSnapshot[key] or "<missing>"
        local afterValue = afterSnapshot and afterSnapshot[key] or "<missing>"
        if beforeValue ~= afterValue then
            changeCount = changeCount + 1
            log("MANUALDIFF CHANGE"
                .. " | index=" .. tostring(changeCount)
                .. " | key=" .. tostring(key)
                .. " | before=" .. tostring(beforeValue)
                .. " | after=" .. tostring(afterValue))
        end
    end

    log("MANUALDIFF DIFF COMPLETE"
        .. " | changeCount=" .. tostring(changeCount))

    return changeCount
end

function GoodsFinder:ToggleManualIslandClickStateDiff()
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)
    local stationCount, stationCountErr = islandPressStationCount()

    if routeValid ~= true then
        log("MANUALDIFF ABORT | reason=no valid temporary route editor")
        return false
    end

    if self.manualIslandDiffBefore == nil then
        local hovered, hoveredCount = manualDiffGetHoveredEntry()
        local hoveredAreaId = tonumber(safe(function()
            return hovered and hovered.infoTip and hovered.infoTip.RefGUID
        end)) or 0
        local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0

        log("MANUALDIFF START"
            .. " | stage=before"
            .. " | stationCount=" .. tostring(stationCount)
            .. " | stationCountError=" .. tostring(stationCountErr or "")
            .. " | hoveredCount=" .. tostring(hoveredCount)
            .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
            .. " | instruction=click Mytholos manually exactly once, wait for station row, then press G or D again")

        if stationCount ~= 0 then
            log("MANUALDIFF ABORT"
                .. " | reason=before snapshot requires an empty route"
                .. " | stationCount=" .. tostring(stationCount))
            return false
        end

        if hoveredAreaId ~= rememberedAreaId then
            log("MANUALDIFF ABORT"
                .. " | reason=hover Mytholos before starting snapshot"
                .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
                .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
            return false
        end

        local snapshot, objects = manualDiffCaptureSnapshot("before")
        self.manualIslandDiffBefore = snapshot
        self.manualIslandDiffBeforeObjects = objects

        manualDiffDumpTypeInfo("Before.MacroMapData", objects and objects.macroData)
        manualDiffDumpTypeInfo("Before.HoveredIsland.Item", objects and objects.hovered and objects.hovered.item)
        manualDiffDumpTypeInfo("Before.HoveredIsland.BaseData", objects and objects.hovered and objects.hovered.base)
        manualDiffDumpTypeInfo("Before.TradeGoodSelection", objects and objects.selection)
        manualDiffDumpTypeInfo("Before.IslandOptionPopupData", objects and objects.islandOptions)
        manualDiffDumpTypeInfo("Before.TradeRoute.UIEditRoute", objects and objects.route)

        local recorderStart, recorderStartErr = safe(function()
            if type(AutomatedTest) == "table"
                and type(AutomatedTest.StartSnippetRecording) == "function" then
                return AutomatedTest:StartSnippetRecording()
            end
            return nil
        end)

        log("MANUALDIFF RECORDER START"
            .. " | success=" .. tostring(recorderStartErr == nil)
            .. " | returnType=" .. tostring(type(recorderStart))
            .. " | returnValue=" .. tostring(recorderStart)
            .. " | error=" .. tostring(recorderStartErr or ""))

        log("MANUALDIFF BEFORE COMPLETE"
            .. " | next=manually click Mytholos once, wait for it to appear as a station, then press Ctrl+Alt+G or Ctrl+Alt+D")

        return true
    end

    log("MANUALDIFF STOP"
        .. " | stage=after"
        .. " | stationCount=" .. tostring(stationCount)
        .. " | stationCountError=" .. tostring(stationCountErr or "")
        .. " | instruction=no additional manual clicks")

    local afterSnapshot, objects = manualDiffCaptureSnapshot("after")

    manualDiffDumpTypeInfo("After.MacroMapData", objects and objects.macroData)
    manualDiffDumpTypeInfo("After.HoveredIsland.Item", objects and objects.hovered and objects.hovered.item)
    manualDiffDumpTypeInfo("After.HoveredIsland.BaseData", objects and objects.hovered and objects.hovered.base)
    manualDiffDumpTypeInfo("After.TradeGoodSelection", objects and objects.selection)
    manualDiffDumpTypeInfo("After.IslandOptionPopupData", objects and objects.islandOptions)
    manualDiffDumpTypeInfo("After.TradeRoute.UIEditRoute", objects and objects.route)

    local recorderStop, recorderStopErr = safe(function()
        if type(AutomatedTest) == "table"
            and type(AutomatedTest.StopSnippetRecording) == "function" then
            return AutomatedTest:StopSnippetRecording()
        end
        return nil
    end)

    log("MANUALDIFF RECORDER STOP"
        .. " | success=" .. tostring(recorderStopErr == nil)
        .. " | returnType=" .. tostring(type(recorderStop))
        .. " | returnValue=" .. tostring(recorderStop)
        .. " | error=" .. tostring(recorderStopErr or ""))

    local changeCount = manualDiffDumpChanged(
        self.manualIslandDiffBefore,
        afterSnapshot
    )

    self.manualIslandDiffAfter = afterSnapshot
    self.manualIslandDiffBefore = nil
    self.manualIslandDiffBeforeObjects = nil

    log("MANUALDIFF COMPLETE"
        .. " | stationCountAfter=" .. tostring(stationCount)
        .. " | changeCount=" .. tostring(changeCount)
        .. " | next=cancel the temporary route and upload the logfile")

    return true
end


function GoodsFinder:PulseHoveredIslandButtonAndPress()
    log("STATEPULSE START | reproduce a full button-state edge before OnPress(baseData)")

    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)
    local stationCountBefore, stationCountBeforeErr = islandPressStationCount()
    local hovered, hoveredCount, entries, macroScene, macroData = manualDiffGetHoveredEntry()
    local hoveredAreaId = tonumber(safe(function()
        return hovered and hovered.infoTip and hovered.infoTip.RefGUID
    end)) or 0
    local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0

    log("STATEPULSE CONTEXT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCountBefore=" .. tostring(stationCountBefore)
        .. " | stationCountBeforeError=" .. tostring(stationCountBeforeErr or "")
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
        .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
        .. " | arrayIndex=" .. tostring(hovered and hovered.arrayIndex))

    if routeValid ~= true then
        log("STATEPULSE ABORT | reason=no valid route editor")
        return false
    end

    if stationCountBefore ~= 0 then
        log("STATEPULSE ABORT"
            .. " | reason=probe requires empty route"
            .. " | stationCount=" .. tostring(stationCountBefore))
        return false
    end

    if hovered == nil or hoveredAreaId ~= rememberedAreaId then
        log("STATEPULSE ABORT"
            .. " | reason=hover Mytholos"
            .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
        return false
    end

    local base = hovered.base
    local btn = hovered.btnStates
    local onPress = hovered.onPress

    if base == nil or btn == nil or type(onPress) ~= "function" then
        log("STATEPULSE ABORT"
            .. " | reason=required live island objects unavailable"
            .. " | baseType=" .. tostring(type(base))
            .. " | btnType=" .. tostring(type(btn))
            .. " | onPressType=" .. tostring(type(onPress)))
        return false
    end

    local beforeHovered = safe(function() return base.IsHovered end)
    local beforeFocused = safe(function() return btn.IsFocused end)
    local beforeSelected = safe(function() return btn.IsSelected end)
    local beforeEnabled = safe(function() return btn.IsEnabled end)
    local beforeLocked = safe(function() return btn.IsLocked end)

    log("STATEPULSE BEFORE"
        .. " | IsHovered=" .. tostring(beforeHovered)
        .. " | IsFocused=" .. tostring(beforeFocused)
        .. " | IsSelected=" .. tostring(beforeSelected)
        .. " | IsEnabled=" .. tostring(beforeEnabled)
        .. " | IsLocked=" .. tostring(beforeLocked))

    local resetResult, resetErr = safe(function()
        base.IsHovered = false
        btn.IsFocused = false
        btn.IsSelected = false
        return true
    end)

    log("STATEPULSE RESET"
        .. " | success=" .. tostring(resetErr == nil)
        .. " | returnValue=" .. tostring(resetResult)
        .. " | error=" .. tostring(resetErr or "")
        .. " | IsHovered=" .. tostring(safe(function() return base.IsHovered end))
        .. " | IsFocused=" .. tostring(safe(function() return btn.IsFocused end))
        .. " | IsSelected=" .. tostring(safe(function() return btn.IsSelected end)))

    local sceneFocus, sceneFocusErr = safe(function()
        if macroScene ~= nil and type(macroScene.RequestFocus) == "function" then
            return macroScene.RequestFocus(macroScene)
        end
        return nil
    end)

    local dataFocus, dataFocusErr = safe(function()
        if macroData ~= nil and type(macroData.RequestFocus) == "function" then
            return macroData.RequestFocus(macroData)
        end
        return nil
    end)

    log("STATEPULSE FOCUS ROOTS"
        .. " | sceneSuccess=" .. tostring(sceneFocusErr == nil)
        .. " | sceneReturn=" .. tostring(sceneFocus)
        .. " | sceneError=" .. tostring(sceneFocusErr or "")
        .. " | dataSuccess=" .. tostring(dataFocusErr == nil)
        .. " | dataReturn=" .. tostring(dataFocus)
        .. " | dataError=" .. tostring(dataFocusErr or ""))

    local armResult, armErr = safe(function()
        btn.IsSelected = true
        btn.IsFocused = true
        base.IsHovered = true
        return true
    end)

    log("STATEPULSE ARM"
        .. " | success=" .. tostring(armErr == nil)
        .. " | returnValue=" .. tostring(armResult)
        .. " | error=" .. tostring(armErr or "")
        .. " | IsHovered=" .. tostring(safe(function() return base.IsHovered end))
        .. " | IsFocused=" .. tostring(safe(function() return btn.IsFocused end))
        .. " | IsSelected=" .. tostring(safe(function() return btn.IsSelected end))
        .. " | IsEnabled=" .. tostring(safe(function() return btn.IsEnabled end))
        .. " | IsLocked=" .. tostring(safe(function() return btn.IsLocked end)))

    local result, err = safe(function()
        return onPress(base)
    end)

    local stationCountAfter, stationCountAfterErr = islandPressStationCount()

    log("STATEPULSE DISPATCH"
        .. " | mode=BaseData.OnPress(baseData) after false-to-true state pulse"
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(result)
        .. " | error=" .. tostring(err or "")
        .. " | stationCountBefore=" .. tostring(stationCountBefore)
        .. " | stationCountAfterImmediate=" .. tostring(stationCountAfter)
        .. " | stationCountAfterError=" .. tostring(stationCountAfterErr or ""))

    log("STATEPULSE COMPLETE"
        .. " | next=wait three seconds; when no station appears, cancel and upload logfile")

    return err == nil
end


local function dcrSafe(label, fn)
    local value, err = safe(fn)
    log("DCR VALUE"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(value))
        .. " | value=" .. tostring(bindingSafeToString(value))
        .. " | error=" .. tostring(err or ""))
    return value, err
end

local function dcrDumpTypeInfo(label, value)
    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    if value == nil or type(getTypeInfoFn) ~= "function" then
        log("DCR TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | available=false"
            .. " | valueType=" .. tostring(type(value)))
        return
    end

    local info, err = safe(function()
        return getTypeInfoFn(value)
    end)

    log("DCR TYPEINFO"
        .. " | label=" .. tostring(label)
        .. " | success=" .. tostring(err == nil)
        .. " | resultType=" .. tostring(type(info))
        .. " | error=" .. tostring(err or ""))

    if err == nil and info ~= nil then
        stationAddLogLong("DCR." .. tostring(label), info)
    end
end

local function dcrCapture(label)
    local tradeScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return tradeScene and tradeScene.TradeGoodSelection
    end)
    local macroScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.MacroMap
    end)
    local macroData = safe(function()
        return macroScene and macroScene.MacroMapData
    end)
    local request = safe(function()
        return macroData and macroData.DataChangeRequest
    end)

    local hovered, hoveredCount = manualDiffGetHoveredEntry()
    local stationCount, stationCountErr = islandPressStationCount()

    log("DCR SNAPSHOT"
        .. " | label=" .. tostring(label)
        .. " | routeValid=" .. tostring(safe(function()
            return TradeRoute and TradeRoute.UIEditRoute and TradeRoute.UIEditRoute:isValid()
        end))
        .. " | stationCount=" .. tostring(stationCount)
        .. " | stationCountError=" .. tostring(stationCountErr or "")
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | hoveredAreaID=" .. tostring(safe(function()
            return hovered and hovered.infoTip and hovered.infoTip.RefGUID
        end))
        .. " | requestType=" .. tostring(type(request))
        .. " | requestValue=" .. tostring(bindingSafeToString(request)))

    dcrDumpTypeInfo(label .. ".MacroMapData", macroData)
    dcrDumpTypeInfo(label .. ".DataChangeRequest", request)

    dcrSafe(label .. ".MacroMapData.LocalMousePosition", function()
        return macroData and macroData.LocalMousePosition
    end)
    dcrSafe(label .. ".MacroMapData.GlobalMousePosition", function()
        return macroData and macroData.GlobalMousePosition
    end)
    dcrSafe(label .. ".MacroMapData.LocalCursorPosition", function()
        return macroData and macroData.LocalCursorPosition
    end)
    dcrSafe(label .. ".MacroMapData.GlobalCursorPosition", function()
        return macroData and macroData.GlobalCursorPosition
    end)
    dcrSafe(label .. ".MacroMapData.MapPosition", function()
        return macroData and macroData.MapPosition
    end)
    dcrSafe(label .. ".MacroMapData.MapScale", function()
        return macroData and macroData.MapScale
    end)
    dcrSafe(label .. ".MacroMapData.MapPositionMode", function()
        return macroData and macroData.MapPositionMode
    end)
    dcrSafe(label .. ".TradeGoodSelection.GoodsIslandFocusIndex", function()
        return selection and selection.GoodsIslandFocusIndex
    end)
    dcrSafe(label .. ".TradeGoodSelection.GoodsIslandHoveredIndex", function()
        return selection and selection.GoodsIslandHoveredIndex
    end)
    dcrSafe(label .. ".TradeGoodSelection.IslandOptionPopupData.IsVisible", function()
        return selection
            and selection.IslandOptionPopupData
            and selection.IslandOptionPopupData.IsVisible
    end)

    if request ~= nil then
        local aliases = manualDiffAliases(request)
        log("DCR ALIASES"
            .. " | label=" .. tostring(label)
            .. " | count=" .. tostring(#(aliases or {}))
            .. " | values=" .. table.concat(aliases or {}, " ; "))

        for _, alias in ipairs(aliases or {}) do
            dcrSafe(label .. ".DataChangeRequest." .. tostring(alias), function()
                return request[alias]
            end)
        end
    end

    return {
        macroData = macroData,
        request = request,
        hoveredAreaID = tonumber(safe(function()
            return hovered and hovered.infoTip and hovered.infoTip.RefGUID
        end)) or 0,
        hoveredIndex = hovered and hovered.arrayIndex,
        stationCount = stationCount
    }
end

function GoodsFinder:ToggleDataChangeRequestProbe()
    local routeValid = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute and TradeRoute.UIEditRoute:isValid()
    end)
    if routeValid ~= true then
        log("DCR ABORT | reason=no valid route editor")
        return false
    end

    if self.dataChangeRequestBefore == nil then
        local state = dcrCapture("before")
        local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0

        if state.stationCount ~= 0 then
            log("DCR ABORT"
                .. " | reason=before snapshot requires empty route"
                .. " | stationCount=" .. tostring(state.stationCount))
            return false
        end

        if state.hoveredAreaID ~= rememberedAreaId then
            log("DCR ABORT"
                .. " | reason=hover Mytholos before before-snapshot"
                .. " | hoveredAreaID=" .. tostring(state.hoveredAreaID)
                .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
            return false
        end

        self.dataChangeRequestBefore = {
            requestType = type(state.request),
            requestValue = bindingSafeToString(state.request),
            stationCount = state.stationCount,
            hoveredAreaID = state.hoveredAreaID,
            hoveredIndex = state.hoveredIndex
        }

        local startResult, startErr = safe(function()
            if type(AutomatedTest) == "table"
                and type(AutomatedTest.StartSnippetRecording) == "function" then
                return AutomatedTest:StartSnippetRecording()
            end
            return nil
        end)

        log("DCR RECORDER START"
            .. " | success=" .. tostring(startErr == nil)
            .. " | returnType=" .. tostring(type(startResult))
            .. " | returnValue=" .. tostring(startResult)
            .. " | error=" .. tostring(startErr or ""))

        log("DCR BEFORE COMPLETE"
            .. " | instruction=click Mytholos manually exactly once, wait for one station, then press G or D again")
        return true
    end

    local state = dcrCapture("after")

    local stopResult, stopErr = safe(function()
        if type(AutomatedTest) == "table"
            and type(AutomatedTest.StopSnippetRecording) == "function" then
            return AutomatedTest:StopSnippetRecording()
        end
        return nil
    end)

    log("DCR RECORDER STOP"
        .. " | success=" .. tostring(stopErr == nil)
        .. " | returnType=" .. tostring(type(stopResult))
        .. " | returnValue=" .. tostring(stopResult)
        .. " | error=" .. tostring(stopErr or ""))

    log("DCR COMPARISON"
        .. " | beforeRequestType=" .. tostring(self.dataChangeRequestBefore.requestType)
        .. " | afterRequestType=" .. tostring(type(state.request))
        .. " | beforeRequestValue=" .. tostring(self.dataChangeRequestBefore.requestValue)
        .. " | afterRequestValue=" .. tostring(bindingSafeToString(state.request))
        .. " | beforeStationCount=" .. tostring(self.dataChangeRequestBefore.stationCount)
        .. " | afterStationCount=" .. tostring(state.stationCount)
        .. " | beforeHoveredIndex=" .. tostring(self.dataChangeRequestBefore.hoveredIndex)
        .. " | afterHoveredIndex=" .. tostring(state.hoveredIndex))

    self.dataChangeRequestBefore = nil

    log("DCR COMPLETE"
        .. " | next=cancel route and upload logfile")
    return true
end


local function dcrsigCall(label, fn)
    local beforeCount, beforeErr = islandPressStationCount()
    local result, err = safe(fn)
    local afterCount, afterErr = islandPressStationCount()

    log("DCRSIG CALL"
        .. " | label=" .. tostring(label)
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(bindingSafeToString(result))
        .. " | error=" .. tostring(err or "")
        .. " | stationCountBefore=" .. tostring(beforeCount)
        .. " | stationCountBeforeError=" .. tostring(beforeErr or "")
        .. " | stationCountAfter=" .. tostring(afterCount)
        .. " | stationCountAfterError=" .. tostring(afterErr or ""))

    return err == nil, beforeCount, afterCount
end

function GoodsFinder:ProbeDataChangeRequestSignatures()
    log("DCRSIG START | probe RequestChange signatures on empty temporary route")

    local routeValid = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute and TradeRoute.UIEditRoute:isValid()
    end)
    local stationCount, stationCountErr = islandPressStationCount()
    local hovered, hoveredCount, entries, macroScene, macroData = manualDiffGetHoveredEntry()
    local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0
    local hoveredAreaId = tonumber(safe(function()
        return hovered and hovered.infoTip and hovered.infoTip.RefGUID
    end)) or 0
    local request = safe(function()
        return macroData and macroData.DataChangeRequest
    end)

    log("DCRSIG CONTEXT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCount=" .. tostring(stationCount)
        .. " | stationCountError=" .. tostring(stationCountErr or "")
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
        .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
        .. " | requestType=" .. tostring(type(request))
        .. " | requestChangeType=" .. tostring(safe(function()
            return request and type(request.RequestChange)
        end))
        .. " | changeReadyType=" .. tostring(safe(function()
            return request and type(request.ChangeReady)
        end))
        .. " | changeFinishedType=" .. tostring(safe(function()
            return request and type(request.ChangeFinished)
        end)))

    if routeValid ~= true then
        log("DCRSIG ABORT | reason=no valid route editor")
        return false
    end
    if stationCount ~= 0 then
        log("DCRSIG ABORT | reason=probe requires empty route")
        return false
    end
    if hovered == nil or hoveredAreaId ~= rememberedAreaId then
        log("DCRSIG ABORT"
            .. " | reason=hover Mytholos"
            .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
        return false
    end
    if request == nil or type(request.RequestChange) ~= "function" then
        log("DCRSIG ABORT | reason=DataChangeRequest.RequestChange unavailable")
        return false
    end

    local base = hovered.base
    local item = hovered.item
    local index = hovered.arrayIndex or 0

    local focusScene, focusSceneErr = safe(function()
        if macroScene and type(macroScene.RequestFocus) == "function" then
            return macroScene.RequestFocus(macroScene)
        end
        return nil
    end)
    local focusData, focusDataErr = safe(function()
        if macroData and type(macroData.RequestFocus) == "function" then
            return macroData.RequestFocus(macroData)
        end
        return nil
    end)

    log("DCRSIG FOCUS"
        .. " | sceneSuccess=" .. tostring(focusSceneErr == nil)
        .. " | sceneError=" .. tostring(focusSceneErr or "")
        .. " | dataSuccess=" .. tostring(focusDataErr == nil)
        .. " | dataError=" .. tostring(focusDataErr or ""))

    local attempts = {
        {"RequestChange(request)", function()
            return request.RequestChange(request)
        end},
        {"RequestChange(request, baseData)", function()
            return request.RequestChange(request, base)
        end},
        {"RequestChange(request, islandItem)", function()
            return request.RequestChange(request, item)
        end},
        {"RequestChange(request, areaID)", function()
            return request.RequestChange(request, hoveredAreaId)
        end},
        {"RequestChange(request, arrayIndex)", function()
            return request.RequestChange(request, index)
        end},
        {"RequestChange(request, areaID, arrayIndex)", function()
            return request.RequestChange(request, hoveredAreaId, index)
        end},
        {"RequestChange(request, arrayIndex, areaID)", function()
            return request.RequestChange(request, index, hoveredAreaId)
        end},
        {"RequestChange(request, baseData, areaID)", function()
            return request.RequestChange(request, base, hoveredAreaId)
        end},
        {"RequestChange(request, baseData, arrayIndex)", function()
            return request.RequestChange(request, base, index)
        end},
    }

    for attemptIndex, attempt in ipairs(attempts) do
        log("DCRSIG ATTEMPT"
            .. " | index=" .. tostring(attemptIndex)
            .. " | label=" .. tostring(attempt[1]))

        local ok, beforeCount, afterCount = dcrsigCall(attempt[1], attempt[2])

        if tonumber(afterCount) and tonumber(afterCount) > tonumber(beforeCount or 0) then
            log("DCRSIG SUCCESS"
                .. " | attemptIndex=" .. tostring(attemptIndex)
                .. " | label=" .. tostring(attempt[1])
                .. " | stationCount=" .. tostring(afterCount)
                .. " | next=stop immediately and upload logfile")
            return true
        end
    end

    if type(request.ChangeReady) == "function" then
        dcrsigCall("ChangeReady(request)", function()
            return request.ChangeReady(request)
        end)
    end

    if type(request.ChangeFinished) == "function" then
        dcrsigCall("ChangeFinished(request)", function()
            return request.ChangeFinished(request)
        end)
    end

    log("DCRSIG COMPLETE"
        .. " | result=no signature created a station"
        .. " | next=cancel temporary route and upload logfile")
    return true
end


local function ctrlsurfaceMatches(key)
    local text = string.lower(tostring(key or ""))
    return string.find(text, "trade", 1, true)
        or string.find(text, "route", 1, true)
        or string.find(text, "station", 1, true)
        or string.find(text, "island", 1, true)
        or string.find(text, "harbor", 1, true)
        or string.find(text, "harbour", 1, true)
        or string.find(text, "kontor", 1, true)
        or string.find(text, "add", 1, true)
        or string.find(text, "insert", 1, true)
        or string.find(text, "select", 1, true)
end

local function ctrlsurfaceLogTable(label, value, depth, visited)
    depth = depth or 0
    visited = visited or {}

    if value == nil then
        log("CTRLSCAN OBJECT | label=" .. tostring(label) .. " | type=nil")
        return
    end

    local valueType = type(value)
    log("CTRLSCAN OBJECT"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(valueType)
        .. " | value=" .. tostring(bindingSafeToString(value))
        .. " | depth=" .. tostring(depth))

    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    if type(getTypeInfoFn) == "function" then
        local info, infoErr = safe(function()
            return getTypeInfoFn(value)
        end)
        log("CTRLSCAN TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | success=" .. tostring(infoErr == nil)
            .. " | resultType=" .. tostring(type(info))
            .. " | error=" .. tostring(infoErr or ""))
        if infoErr == nil and info ~= nil then
            stationAddLogLong("CTRLSCAN." .. tostring(label), info)
        end
    end

    if valueType ~= "table" or depth >= 2 or visited[value] then
        return
    end
    visited[value] = true

    local keys = {}
    for key in pairs(value) do
        if ctrlsurfaceMatches(key) then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    log("CTRLSCAN MATCHES"
        .. " | label=" .. tostring(label)
        .. " | count=" .. tostring(#keys))

    for index, key in ipairs(keys) do
        local member, err = safe(function()
            return value[key]
        end)

        log("CTRLSCAN MEMBER"
            .. " | root=" .. tostring(label)
            .. " | index=" .. tostring(index)
            .. " | key=" .. tostring(key)
            .. " | type=" .. tostring(type(member))
            .. " | value=" .. tostring(bindingSafeToString(member))
            .. " | error=" .. tostring(err or ""))

        if type(member) == "table" and depth < 2 then
            ctrlsurfaceLogTable(label .. "." .. tostring(key), member, depth + 1, visited)
        end
    end
end

function GoodsFinder:ScanTradeRouteControllerSurfaces()
    log("CTRLSCAN START | inspect exposed controller and binding surfaces without dispatching actions")

    local tradeScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local macroScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.MacroMap
    end)
    local selection = safe(function()
        return tradeScene and tradeScene.TradeGoodSelection
    end)
    local overview = safe(function()
        return tradeScene and tradeScene.TradeOverview
    end)
    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)

    local stationCount, stationCountErr = islandPressStationCount()
    local hovered, hoveredCount = manualDiffGetHoveredEntry()

    log("CTRLSCAN CONTEXT"
        .. " | routeValid=" .. tostring(safe(function()
            return route and route:isValid()
        end))
        .. " | stationCount=" .. tostring(stationCount)
        .. " | stationCountError=" .. tostring(stationCountErr or "")
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | hoveredAreaID=" .. tostring(safe(function()
            return hovered and hovered.infoTip and hovered.infoTip.RefGUID
        end))
        .. " | rememberedAreaID=" .. tostring(self.lastWarehouseAreaId or 0))

    ctrlsurfaceLogTable("_G", _G, 0, {})
    ctrlsurfaceLogTable("_G.ui", rawget(_G, "ui"), 0, {})
    ctrlsurfaceLogTable("_G.halo", rawget(_G, "halo"), 0, {})
    ctrlsurfaceLogTable("_G.TradeRoute", rawget(_G, "TradeRoute"), 0, {})
    ctrlsurfaceLogTable("_G.AutomatedTest", rawget(_G, "AutomatedTest"), 0, {})

    ctrlsurfaceLogTable("TradeRouteScene", tradeScene, 0, {})
    ctrlsurfaceLogTable("MacroMapScene", macroScene, 0, {})
    ctrlsurfaceLogTable("TradeGoodSelection", selection, 0, {})
    ctrlsurfaceLogTable("TradeOverview", overview, 0, {})
    ctrlsurfaceLogTable("TradeRoute.UIEditRoute", route, 0, {})

    if hovered ~= nil then
        ctrlsurfaceLogTable("HoveredIsland.Item", hovered.item, 0, {})
        ctrlsurfaceLogTable("HoveredIsland.BaseData", hovered.base, 0, {})
        ctrlsurfaceLogTable("HoveredIsland.InfoTipContext", hovered.context, 0, {})
        ctrlsurfaceLogTable("HoveredIsland.BtnStates", hovered.btnStates, 0, {})
    end

    log("CTRLSCAN COMPLETE"
        .. " | result=surface inventory written"
        .. " | next=cancel temporary route and upload logfile")
    return true
end


local function kontorProbeCall(label, fn)
    local beforeCount, beforeErr = islandPressStationCount()
    local result, err = safe(fn)
    local afterCount, afterErr = islandPressStationCount()

    log("KONTORPROBE CALL"
        .. " | label=" .. tostring(label)
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(bindingSafeToString(result))
        .. " | error=" .. tostring(err or "")
        .. " | stationCountBefore=" .. tostring(beforeCount)
        .. " | stationCountBeforeError=" .. tostring(beforeErr or "")
        .. " | stationCountAfter=" .. tostring(afterCount)
        .. " | stationCountAfterError=" .. tostring(afterErr or ""))

    return err == nil, beforeCount, afterCount
end

function GoodsFinder:ProbeSelectIslandKontorPrerequisite()
    log("KONTORPROBE START | test Selection.SelectIslandKontor before live MacroMap OnPress")

    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)
    local stationCount, stationCountErr = islandPressStationCount()
    local hovered, hoveredCount, entries, macroScene, macroData = manualDiffGetHoveredEntry()
    local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0
    local hoveredAreaId = tonumber(safe(function()
        return hovered and hovered.infoTip and hovered.infoTip.RefGUID
    end)) or 0
    local selectionManager = rawget(_G, "Selection")

    local rememberedWarehouse = nil
    local warehouseObjects = safe(function()
        return session and session.getObjectGroupByProperty
            and session:getObjectGroupByProperty("Warehouse")
    end)

    if type(warehouseObjects) == "table" then
        for _, object in pairs(warehouseObjects) do
            local areaId = tonumber(safe(function()
                return object and object.Area and object.Area.ID
            end)) or 0
            if areaId == rememberedAreaId then
                rememberedWarehouse = object
                break
            end
        end
    end

    local warehouseObjectId = tonumber(safe(function()
        return rememberedWarehouse and rememberedWarehouse.ID
    end)) or tonumber(safe(function()
        return rememberedWarehouse and rememberedWarehouse.ObjectID
    end)) or 0

    local warehouseGuid = tonumber(safe(function()
        return rememberedWarehouse and rememberedWarehouse.GUID
    end)) or 0

    log("KONTORPROBE CONTEXT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCount=" .. tostring(stationCount)
        .. " | stationCountError=" .. tostring(stationCountErr or "")
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
        .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
        .. " | selectionType=" .. tostring(type(selectionManager))
        .. " | selectIslandKontorType=" .. tostring(safe(function()
            return selectionManager and type(selectionManager.SelectIslandKontor)
        end))
        .. " | warehouseType=" .. tostring(type(rememberedWarehouse))
        .. " | warehouseObjectID=" .. tostring(warehouseObjectId)
        .. " | warehouseGUID=" .. tostring(warehouseGuid))

    if routeValid ~= true then
        log("KONTORPROBE ABORT | reason=no valid route editor")
        return false
    end
    if stationCount ~= 0 then
        log("KONTORPROBE ABORT | reason=probe requires empty route")
        return false
    end
    if hovered == nil or hoveredAreaId ~= rememberedAreaId then
        log("KONTORPROBE ABORT"
            .. " | reason=hover Mytholos"
            .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
        return false
    end
    if type(selectionManager) ~= "table"
        or type(selectionManager.SelectIslandKontor) ~= "function" then
        log("KONTORPROBE ABORT | reason=Selection.SelectIslandKontor unavailable")
        return false
    end

    local attempts = {
        {"SelectIslandKontor(selection)", function()
            return selectionManager.SelectIslandKontor(selectionManager)
        end},
        {"SelectIslandKontor(selection, areaID)", function()
            return selectionManager.SelectIslandKontor(selectionManager, rememberedAreaId)
        end},
        {"SelectIslandKontor(selection, warehouseObject)", function()
            return selectionManager.SelectIslandKontor(selectionManager, rememberedWarehouse)
        end},
        {"SelectIslandKontor(selection, warehouseObjectID)", function()
            return selectionManager.SelectIslandKontor(selectionManager, warehouseObjectId)
        end},
        {"SelectIslandKontor(selection, warehouseGUID)", function()
            return selectionManager.SelectIslandKontor(selectionManager, warehouseGuid)
        end},
    }

    for index, attempt in ipairs(attempts) do
        log("KONTORPROBE ATTEMPT"
            .. " | index=" .. tostring(index)
            .. " | label=" .. tostring(attempt[1]))

        local ok = kontorProbeCall(attempt[1], attempt[2])

        local picked = safe(function()
            return selectionManager.Picked
        end)
        local selectedObject = safe(function()
            return selectionManager.Object
        end)

        log("KONTORPROBE SELECTION STATE"
            .. " | attemptIndex=" .. tostring(index)
            .. " | pickedType=" .. tostring(type(picked))
            .. " | pickedValue=" .. tostring(bindingSafeToString(picked))
            .. " | objectType=" .. tostring(type(selectedObject))
            .. " | objectValue=" .. tostring(bindingSafeToString(selectedObject)))

        local focusScene, focusSceneErr = safe(function()
            if macroScene and type(macroScene.RequestFocus) == "function" then
                return macroScene.RequestFocus(macroScene)
            end
            return nil
        end)
        local focusData, focusDataErr = safe(function()
            if macroData and type(macroData.RequestFocus) == "function" then
                return macroData.RequestFocus(macroData)
            end
            return nil
        end)

        local onPressResult, onPressErr = safe(function()
            return hovered.onPress(hovered.base)
        end)
        local afterPressCount, afterPressErr = islandPressStationCount()

        log("KONTORPROBE ONPRESS"
            .. " | attemptIndex=" .. tostring(index)
            .. " | prerequisiteSuccess=" .. tostring(ok)
            .. " | sceneFocusSuccess=" .. tostring(focusSceneErr == nil)
            .. " | dataFocusSuccess=" .. tostring(focusDataErr == nil)
            .. " | onPressSuccess=" .. tostring(onPressErr == nil)
            .. " | onPressReturnType=" .. tostring(type(onPressResult))
            .. " | onPressReturnValue=" .. tostring(bindingSafeToString(onPressResult))
            .. " | onPressError=" .. tostring(onPressErr or "")
            .. " | stationCountAfter=" .. tostring(afterPressCount)
            .. " | stationCountAfterError=" .. tostring(afterPressErr or ""))

        if tonumber(afterPressCount) and tonumber(afterPressCount) > 0 then
            log("KONTORPROBE SUCCESS"
                .. " | attemptIndex=" .. tostring(index)
                .. " | label=" .. tostring(attempt[1])
                .. " | stationCount=" .. tostring(afterPressCount)
                .. " | next=stop immediately and upload logfile")
            return true
        end
    end

    log("KONTORPROBE COMPLETE"
        .. " | result=no SelectIslandKontor prerequisite enabled station insertion"
        .. " | next=cancel temporary route and upload logfile")
    return true
end


local function kontorIdentityValue(label, fn)
    local value, err = safe(fn)
    log("KONTORID VALUE"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(value))
        .. " | value=" .. tostring(bindingSafeToString(value))
        .. " | error=" .. tostring(err or ""))
    return value, err
end

local function kontorIdentityDumpObject(label, object)
    log("KONTORID OBJECT"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(object))
        .. " | value=" .. tostring(bindingSafeToString(object)))

    if object == nil then
        return
    end

    kontorIdentityValue(label .. ".isValid", function()
        return object.isValid and object:isValid()
    end)
    kontorIdentityValue(label .. ".ID", function()
        return object.ID
    end)
    kontorIdentityValue(label .. ".ObjectID", function()
        return object.ObjectID
    end)
    kontorIdentityValue(label .. ".GUID", function()
        return object.GUID
    end)
    kontorIdentityValue(label .. ".Area.ID", function()
        return object.Area and object.Area.ID
    end)
    kontorIdentityValue(label .. ".Area.Name", function()
        return object.Area and object.Area.Name
    end)

    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    if type(getTypeInfoFn) == "function" then
        local info, infoErr = safe(function()
            return getTypeInfoFn(object)
        end)
        log("KONTORID TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | success=" .. tostring(infoErr == nil)
            .. " | resultType=" .. tostring(type(info))
            .. " | error=" .. tostring(infoErr or ""))
        if infoErr == nil and info ~= nil then
            stationAddLogLong("KONTORID." .. tostring(label), info)
        end
    end
end

local function kontorIdentityFindWarehouse(areaId)
    local objects, queryErr = safe(function()
        return session and session.getObjectGroupByProperty
            and session:getObjectGroupByProperty("Warehouse")
    end)

    log("KONTORID WAREHOUSE QUERY"
        .. " | type=" .. tostring(type(objects))
        .. " | value=" .. tostring(bindingSafeToString(objects))
        .. " | error=" .. tostring(queryErr or ""))

    if objects == nil then
        return nil
    end

    local count = 0
    for key, object in pairs(objects) do
        count = count + 1
        local objectAreaId = tonumber(safe(function()
            return object and object.Area and object.Area.ID
        end)) or 0

        if objectAreaId == tonumber(areaId) then
            log("KONTORID WAREHOUSE MATCH"
                .. " | key=" .. tostring(key)
                .. " | enumeratedCount=" .. tostring(count)
                .. " | areaID=" .. tostring(objectAreaId)
                .. " | object=" .. tostring(bindingSafeToString(object)))
            return object
        end
    end

    log("KONTORID WAREHOUSE MISS"
        .. " | enumeratedCount=" .. tostring(count)
        .. " | requestedAreaID=" .. tostring(areaId))
    return nil
end

local function kontorIdentityStationCount(label)
    local count, err = islandPressStationCount()
    log("KONTORID STATION COUNT"
        .. " | label=" .. tostring(label)
        .. " | count=" .. tostring(count)
        .. " | error=" .. tostring(err or ""))
    return tonumber(count) or 0
end

function GoodsFinder:ProbeKontorSelectionIdentity()
    log("KONTORID START | isolate island marking and identify the selected Kontor object")

    local route = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return route and route:isValid()
    end)
    local stationCount = kontorIdentityStationCount("before")
    local hovered, hoveredCount, entries, macroScene, macroData = manualDiffGetHoveredEntry()
    local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0
    local hoveredAreaId = tonumber(safe(function()
        return hovered and hovered.infoTip and hovered.infoTip.RefGUID
    end)) or 0
    local selectionManager = rawget(_G, "Selection")

    log("KONTORID CONTEXT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCount=" .. tostring(stationCount)
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
        .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
        .. " | selectionType=" .. tostring(type(selectionManager)))

    if routeValid ~= true then
        log("KONTORID ABORT | reason=no valid route editor")
        return false
    end
    if stationCount ~= 0 then
        log("KONTORID ABORT | reason=probe requires empty route")
        return false
    end
    if hovered == nil or hoveredAreaId ~= rememberedAreaId then
        log("KONTORID ABORT"
            .. " | reason=hover Mytholos"
            .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
        return false
    end
    if type(selectionManager) ~= "table" then
        log("KONTORID ABORT | reason=Selection manager unavailable")
        return false
    end

    local warehouse = kontorIdentityFindWarehouse(rememberedAreaId)
    local warehouseId = tonumber(safe(function()
        return warehouse and (warehouse.ID or warehouse.ObjectID)
    end)) or 35738422870020

    kontorIdentityDumpObject("Before.Selection.Object", safe(function()
        return selectionManager.Object
    end))
    kontorIdentityDumpObject("Before.Selection.Picked", safe(function()
        return selectionManager.Picked
    end))
    kontorIdentityDumpObject("Remembered.Warehouse", warehouse)

    local clearResult, clearErr = safe(function()
        if type(selectionManager.ClearSelection) == "function" then
            return selectionManager.ClearSelection(selectionManager)
        end
        return nil
    end)
    log("KONTORID CLEAR"
        .. " | success=" .. tostring(clearErr == nil)
        .. " | returnValue=" .. tostring(bindingSafeToString(clearResult))
        .. " | error=" .. tostring(clearErr or ""))

    local selectKontorResult, selectKontorErr = safe(function()
        return selectionManager.SelectIslandKontor(selectionManager)
    end)
    log("KONTORID SELECT ISLAND KONTOR"
        .. " | success=" .. tostring(selectKontorErr == nil)
        .. " | returnValue=" .. tostring(bindingSafeToString(selectKontorResult))
        .. " | error=" .. tostring(selectKontorErr or ""))

    local selectedAfterKontor = safe(function()
        return selectionManager.Object
    end)
    kontorIdentityDumpObject("After.SelectIslandKontor.Selection.Object", selectedAfterKontor)
    kontorIdentityDumpObject("After.SelectIslandKontor.Selection.Picked", safe(function()
        return selectionManager.Picked
    end))
    kontorIdentityStationCount("after SelectIslandKontor")

    local selectByIdResult, selectByIdErr = safe(function()
        if type(selectionManager.SelectByID) == "function" then
            return selectionManager.SelectByID(selectionManager, warehouseId)
        end
        return nil
    end)
    log("KONTORID SELECT BY ID"
        .. " | objectID=" .. tostring(warehouseId)
        .. " | success=" .. tostring(selectByIdErr == nil)
        .. " | returnValue=" .. tostring(bindingSafeToString(selectByIdResult))
        .. " | error=" .. tostring(selectByIdErr or ""))

    local selectedAfterId = safe(function()
        return selectionManager.Object
    end)
    kontorIdentityDumpObject("After.SelectByID.Selection.Object", selectedAfterId)
    kontorIdentityDumpObject("After.SelectByID.Selection.Picked", safe(function()
        return selectionManager.Picked
    end))
    kontorIdentityStationCount("after SelectByID")

    local focusScene, focusSceneErr = safe(function()
        if macroScene and type(macroScene.RequestFocus) == "function" then
            return macroScene.RequestFocus(macroScene)
        end
        return nil
    end)
    local focusData, focusDataErr = safe(function()
        if macroData and type(macroData.RequestFocus) == "function" then
            return macroData.RequestFocus(macroData)
        end
        return nil
    end)

    local onPressResult, onPressErr = safe(function()
        return hovered.onPress(hovered.base)
    end)
    local afterPressCount = kontorIdentityStationCount("after SelectByID + OnPress")

    log("KONTORID ONPRESS"
        .. " | sceneFocusSuccess=" .. tostring(focusSceneErr == nil)
        .. " | dataFocusSuccess=" .. tostring(focusDataErr == nil)
        .. " | onPressSuccess=" .. tostring(onPressErr == nil)
        .. " | onPressReturnValue=" .. tostring(bindingSafeToString(onPressResult))
        .. " | onPressError=" .. tostring(onPressErr or "")
        .. " | stationCountAfter=" .. tostring(afterPressCount))

    log("KONTORID COMPLETE"
        .. " | result=island marking and selected-object identity captured"
        .. " | next=note whether Mytholos was visibly highlighted, then cancel and upload logfile")

    return true
end


local function pickingProbeCount(label)
    local count, err = islandPressStationCount()
    log("PICKPROBE STATION COUNT"
        .. " | label=" .. tostring(label)
        .. " | count=" .. tostring(count)
        .. " | error=" .. tostring(err or ""))
    return tonumber(count) or 0
end

local function pickingProbeSelectionState(label, selectionManager)
    local object = safe(function() return selectionManager and selectionManager.Object end)
    local picked = safe(function() return selectionManager and selectionManager.Picked end)
    local objects = safe(function() return selectionManager and selectionManager.Objects end)

    log("PICKPROBE SELECTION"
        .. " | label=" .. tostring(label)
        .. " | object=" .. tostring(bindingSafeToString(object))
        .. " | objectID=" .. tostring(safe(function() return object and object.ID end))
        .. " | objectGUID=" .. tostring(safe(function() return object and object.GUID end))
        .. " | objectAreaID=" .. tostring(safe(function() return object and object.Area and object.Area.ID end))
        .. " | picked=" .. tostring(bindingSafeToString(picked))
        .. " | pickedValid=" .. tostring(safe(function() return picked and picked:isValid() end))
        .. " | objectsType=" .. tostring(type(objects))
        .. " | objectsValue=" .. tostring(bindingSafeToString(objects)))
end

local function pickingProbeCall(label, fn)
    local before = pickingProbeCount(label .. ".before")
    local result, err = safe(fn)
    local after = pickingProbeCount(label .. ".after")

    log("PICKPROBE CALL"
        .. " | label=" .. tostring(label)
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(bindingSafeToString(result))
        .. " | error=" .. tostring(err or "")
        .. " | stationCountBefore=" .. tostring(before)
        .. " | stationCountAfter=" .. tostring(after))

    return err == nil, after
end

function GoodsFinder:ProbePickingStateRouteClick()
    log("PICKPROBE START | test engine picking state before live MacroMap island press")

    local route = safe(function() return TradeRoute and TradeRoute.UIEditRoute end)
    local routeValid = safe(function() return route and route:isValid() end)
    local hovered, hoveredCount, entries, macroScene, macroData = manualDiffGetHoveredEntry()
    local selectionManager = rawget(_G, "Selection")
    local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0
    local hoveredAreaId = tonumber(safe(function()
        return hovered and hovered.infoTip and hovered.infoTip.RefGUID
    end)) or 0
    local warehouseObjectId = 35738422870020

    log("PICKPROBE CONTEXT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCount=" .. tostring(pickingProbeCount("initial"))
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
        .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
        .. " | selectionType=" .. tostring(type(selectionManager))
        .. " | setEnablePickingType=" .. tostring(safe(function()
            return selectionManager and type(selectionManager.SetEnablePicking)
        end))
        .. " | addToSelectionByIDType=" .. tostring(safe(function()
            return selectionManager and type(selectionManager.AddToSelectionByID)
        end))
        .. " | selectByIDType=" .. tostring(safe(function()
            return selectionManager and type(selectionManager.SelectByID)
        end)))

    if routeValid ~= true then
        log("PICKPROBE ABORT | reason=no valid route editor")
        return false
    end
    if pickingProbeCount("guard") ~= 0 then
        log("PICKPROBE ABORT | reason=probe requires empty route")
        return false
    end
    if hovered == nil or hoveredAreaId ~= rememberedAreaId then
        log("PICKPROBE ABORT"
            .. " | reason=hover Mytholos"
            .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
        return false
    end
    if type(selectionManager) ~= "table" then
        log("PICKPROBE ABORT | reason=Selection manager unavailable")
        return false
    end

    pickingProbeSelectionState("before", selectionManager)

    local attempts = {
        {
            "SetEnablePicking(true)",
            function()
                return selectionManager.SetEnablePicking(selectionManager, true)
            end
        },
        {
            "SetEnablePicking(true) + SelectByID(warehouse)",
            function()
                selectionManager.SetEnablePicking(selectionManager, true)
                return selectionManager.SelectByID(selectionManager, warehouseObjectId)
            end
        },
        {
            "SetEnablePicking(true) + AddToSelectionByID(warehouse)",
            function()
                selectionManager.SetEnablePicking(selectionManager, true)
                return selectionManager.AddToSelectionByID(selectionManager, warehouseObjectId)
            end
        },
        {
            "Clear + SetEnablePicking(true) + AddToSelectionByID(warehouse)",
            function()
                if type(selectionManager.ClearSelection) == "function" then
                    selectionManager.ClearSelection(selectionManager)
                end
                selectionManager.SetEnablePicking(selectionManager, true)
                return selectionManager.AddToSelectionByID(selectionManager, warehouseObjectId)
            end
        },
        {
            "Clear + SetEnablePicking(true) + SelectIslandKontor",
            function()
                if type(selectionManager.ClearSelection) == "function" then
                    selectionManager.ClearSelection(selectionManager)
                end
                selectionManager.SetEnablePicking(selectionManager, true)
                return selectionManager.SelectIslandKontor(selectionManager)
            end
        },
    }

    for index, attempt in ipairs(attempts) do
        log("PICKPROBE ATTEMPT"
            .. " | index=" .. tostring(index)
            .. " | label=" .. tostring(attempt[1]))

        local ok = pickingProbeCall(attempt[1], attempt[2])
        pickingProbeSelectionState("after prerequisite " .. tostring(index), selectionManager)

        local focusScene, focusSceneErr = safe(function()
            if macroScene and type(macroScene.RequestFocus) == "function" then
                return macroScene.RequestFocus(macroScene)
            end
            return nil
        end)
        local focusData, focusDataErr = safe(function()
            if macroData and type(macroData.RequestFocus) == "function" then
                return macroData.RequestFocus(macroData)
            end
            return nil
        end)

        local pressResult, pressErr = safe(function()
            return hovered.onPress(hovered.base)
        end)
        local afterPress = pickingProbeCount("after OnPress attempt " .. tostring(index))
        pickingProbeSelectionState("after OnPress " .. tostring(index), selectionManager)

        log("PICKPROBE ONPRESS"
            .. " | attemptIndex=" .. tostring(index)
            .. " | prerequisiteSuccess=" .. tostring(ok)
            .. " | sceneFocusSuccess=" .. tostring(focusSceneErr == nil)
            .. " | dataFocusSuccess=" .. tostring(focusDataErr == nil)
            .. " | onPressSuccess=" .. tostring(pressErr == nil)
            .. " | onPressReturnValue=" .. tostring(bindingSafeToString(pressResult))
            .. " | onPressError=" .. tostring(pressErr or "")
            .. " | stationCountAfter=" .. tostring(afterPress))

        if afterPress > 0 then
            log("PICKPROBE SUCCESS"
                .. " | attemptIndex=" .. tostring(index)
                .. " | label=" .. tostring(attempt[1])
                .. " | stationCount=" .. tostring(afterPress)
                .. " | next=stop immediately and upload logfile")
            return true
        end
    end

    local disableResult, disableErr = safe(function()
        if type(selectionManager.SetEnablePicking) == "function" then
            return selectionManager.SetEnablePicking(selectionManager, false)
        end
        return nil
    end)

    log("PICKPROBE CLEANUP"
        .. " | disablePickingSuccess=" .. tostring(disableErr == nil)
        .. " | returnValue=" .. tostring(bindingSafeToString(disableResult))
        .. " | error=" .. tostring(disableErr or ""))

    log("PICKPROBE COMPLETE"
        .. " | result=no picking-state sequence created a station"
        .. " | next=cancel temporary route and upload logfile")
    return true
end


local function actionScanCount(label)
    local count, err = islandPressStationCount()
    log("ACTIONSCAN STATION COUNT"
        .. " | label=" .. tostring(label)
        .. " | count=" .. tostring(count)
        .. " | error=" .. tostring(err or ""))
    return tonumber(count) or 0
end

local function actionScanRouteValid()
    return safe(function()
        return TradeRoute and TradeRoute.UIEditRoute and TradeRoute.UIEditRoute:isValid()
    end)
end

function GoodsFinder:RunNarrowGamepadActionScan()
    log("ACTIONSCAN START | narrow fake-input scan around previously tested action 321")

    local hovered, hoveredCount, entries, macroScene, macroData = manualDiffGetHoveredEntry()
    local rememberedAreaId = tonumber(self.lastWarehouseAreaId) or 0
    local hoveredAreaId = tonumber(safe(function()
        return hovered and hovered.infoTip and hovered.infoTip.RefGUID
    end)) or 0
    local stationCount = actionScanCount("initial")
    local routeValid = actionScanRouteValid()

    log("ACTIONSCAN CONTEXT"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCount=" .. tostring(stationCount)
        .. " | hoveredCount=" .. tostring(hoveredCount)
        .. " | hoveredIndex=" .. tostring(hovered and hovered.arrayIndex)
        .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
        .. " | rememberedAreaID=" .. tostring(rememberedAreaId)
        .. " | sendFakeGamepadEventsType=" .. tostring(safe(function()
            return AutomatedTest and type(AutomatedTest.SendFakeGamepadEvents)
        end)))

    if routeValid ~= true then
        log("ACTIONSCAN ABORT | reason=no valid route editor")
        return false
    end
    if stationCount ~= 0 then
        log("ACTIONSCAN ABORT | reason=scan requires empty route")
        return false
    end
    if hovered == nil or hoveredAreaId ~= rememberedAreaId then
        log("ACTIONSCAN ABORT"
            .. " | reason=hover Mytholos"
            .. " | hoveredAreaID=" .. tostring(hoveredAreaId)
            .. " | rememberedAreaID=" .. tostring(rememberedAreaId))
        return false
    end
    if type(AutomatedTest) ~= "table"
        or type(AutomatedTest.SendFakeGamepadEvents) ~= "function" then
        log("ACTIONSCAN ABORT | reason=SendFakeGamepadEvents unavailable")
        return false
    end

    local focusScene, focusSceneErr = safe(function()
        if macroScene and type(macroScene.RequestFocus) == "function" then
            return macroScene.RequestFocus(macroScene)
        end
        return nil
    end)
    local focusData, focusDataErr = safe(function()
        if macroData and type(macroData.RequestFocus) == "function" then
            return macroData.RequestFocus(macroData)
        end
        return nil
    end)

    log("ACTIONSCAN FOCUS"
        .. " | sceneSuccess=" .. tostring(focusSceneErr == nil)
        .. " | sceneError=" .. tostring(focusSceneErr or "")
        .. " | dataSuccess=" .. tostring(focusDataErr == nil)
        .. " | dataError=" .. tostring(focusDataErr or ""))

    -- Deliberately narrow neighborhood around action 321.
    -- 321 itself was already proven ineffective and is not repeated.
    local candidates = {318, 319, 320, 322, 323, 324}

    for index, actionId in ipairs(candidates) do
        if actionScanRouteValid() ~= true then
            log("ACTIONSCAN STOP"
                .. " | reason=route editor closed or invalid"
                .. " | actionID=" .. tostring(actionId)
                .. " | candidateIndex=" .. tostring(index))
            return false
        end

        local before = actionScanCount("before action " .. tostring(actionId))
        if before ~= 0 then
            log("ACTIONSCAN SUCCESS"
                .. " | actionID=" .. tostring(actionId)
                .. " | candidateIndex=" .. tostring(index)
                .. " | stationCount=" .. tostring(before)
                .. " | detectedBeforeDispatch=true")
            return true
        end

        log("ACTIONSCAN DISPATCH"
            .. " | candidateIndex=" .. tostring(index)
            .. " | actionID=" .. tostring(actionId)
            .. " | mode=SendFakeGamepadEvents({actionID},{1}) then release")

        local pressResult, pressErr = safe(function()
            return AutomatedTest:SendFakeGamepadEvents({actionId}, {1})
        end)

        local releaseResult, releaseErr = safe(function()
            return AutomatedTest:SendFakeGamepadEvents({actionId}, {0})
        end)

        local after = actionScanCount("after action " .. tostring(actionId))
        local routeValidAfter = actionScanRouteValid()

        log("ACTIONSCAN RESULT"
            .. " | candidateIndex=" .. tostring(index)
            .. " | actionID=" .. tostring(actionId)
            .. " | pressSuccess=" .. tostring(pressErr == nil)
            .. " | pressReturn=" .. tostring(bindingSafeToString(pressResult))
            .. " | pressError=" .. tostring(pressErr or "")
            .. " | releaseSuccess=" .. tostring(releaseErr == nil)
            .. " | releaseReturn=" .. tostring(bindingSafeToString(releaseResult))
            .. " | releaseError=" .. tostring(releaseErr or "")
            .. " | stationCountBefore=" .. tostring(before)
            .. " | stationCountAfter=" .. tostring(after)
            .. " | routeValidAfter=" .. tostring(routeValidAfter))

        if after > before then
            log("ACTIONSCAN SUCCESS"
                .. " | actionID=" .. tostring(actionId)
                .. " | candidateIndex=" .. tostring(index)
                .. " | stationCount=" .. tostring(after)
                .. " | next=stop immediately and upload logfile")
            return true
        end

        if routeValidAfter ~= true then
            log("ACTIONSCAN STOP"
                .. " | reason=action changed UI state"
                .. " | actionID=" .. tostring(actionId)
                .. " | candidateIndex=" .. tostring(index)
                .. " | next=upload logfile")
            return false
        end
    end

    log("ACTIONSCAN COMPLETE"
        .. " | result=no candidate created a station"
        .. " | candidates=318,319,320,322,323,324"
        .. " | next=cancel temporary route and upload logfile")
    return true
end


local function assistedStationCount()
    local count, err = islandPressStationCount()
    return tonumber(count) or 0, err
end

function GoodsFinder:RunAssistedTwoClickWorkflow()
    local routeValid = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute and TradeRoute.UIEditRoute:isValid()
    end)

    if routeValid ~= true then
        log("ASSISTED START | no route editor; using normal capture-and-create stage")
        return self:CaptureOpenAndCreateRoute()
    end

    local stationCount, stationCountErr = assistedStationCount()

    log("ASSISTED STATUS"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | stationCount=" .. tostring(stationCount)
        .. " | stationCountError=" .. tostring(stationCountErr or "")
        .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | productName=" .. tostring(self.lastProductName or "")
        .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or ""))

    if stationCount == 0 then
        log("ASSISTED WAIT"
            .. " | step=1"
            .. " | instruction=click Mytholos once, then click any second island once, then press Ctrl+Alt+G again")
        return true
    end

    if stationCount == 1 then
        log("ASSISTED WAIT"
            .. " | step=2"
            .. " | instruction=click any second island once, then press Ctrl+Alt+G again")
        return true
    end

    log("ASSISTED OPEN"
        .. " | stationCount=" .. tostring(stationCount)
        .. " | instruction=open remembered Mytholos Load Good popup and highlight remembered product")

    local result = self:OpenRememberedLoadGoodsPopup()

    log("ASSISTED COMPLETE"
        .. " | success=" .. tostring(result)
        .. " | stationCount=" .. tostring(stationCount)
        .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
        .. " | productName=" .. tostring(self.lastProductName or "")
        .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
        .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or "")
        .. " | next=inspect strategic-map stock overlay, then cancel the temporary route")

    return result
end


local function autoShipArraySize(arrayValue, helperKey)
    local haloRoot = rawget(_G, "halo")
    local helper = type(haloRoot) == "table" and haloRoot[helperKey] or nil

    if arrayValue == nil
        or type(helper) ~= "table"
        or type(helper.GetSize) ~= "function" then
        return nil, "array/helper unavailable"
    end

    return safe(function()
        return helper.GetSize(arrayValue)
    end)
end

local function autoShipArrayElement(arrayValue, helperKey, index)
    local haloRoot = rawget(_G, "halo")
    local helper = type(haloRoot) == "table" and haloRoot[helperKey] or nil

    if arrayValue == nil
        or type(helper) ~= "table"
        or type(helper.GetElement) ~= "function" then
        return nil, "array/helper unavailable"
    end

    return safe(function()
        return helper.GetElement(arrayValue, index)
    end)
end

local function autoShipSelectedCount(shipSelect)
    local selected = safe(function()
        return shipSelect and shipSelect.SelectedShipList
    end)

    local count, err = autoShipArraySize(
        selected,
        "PhoenixArray<halo::CTradeShipData>"
    )

    return tonumber(count) or 0, err
end

local function autoShipLoadRowCount(goodsFinder)
    local count, _, err = assistedRememberedLoadRowCount(goodsFinder)
    return count, err
end

local function autoShipLogCandidate(label, candidate)
    log("AUTOSHIP CANDIDATE"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(candidate))
        .. " | value=" .. tostring(bindingSafeToString(candidate))
        .. " | ShipName=" .. tostring(safe(function() return candidate and candidate.ShipName end))
        .. " | Name=" .. tostring(safe(function() return candidate and candidate.Name end))
        .. " | MetaID=" .. tostring(safe(function() return candidate and candidate.MetaID end))
        .. " | ID=" .. tostring(safe(function() return candidate and candidate.ID end))
        .. " | GUID=" .. tostring(safe(function() return candidate and candidate.GUID end))
        .. " | IsSelected=" .. tostring(safe(function() return candidate and candidate.IsSelected end))
        .. " | IsDisabled=" .. tostring(safe(function() return candidate and candidate.IsDisabled end))
        .. " | IsAvailable=" .. tostring(safe(function() return candidate and candidate.IsAvailable end))
        .. " | IsFocused=" .. tostring(safe(function() return candidate and candidate.IsFocused end))
        .. " | IsHovered=" .. tostring(safe(function() return candidate and candidate.IsHovered end))
        .. " | PrimaryButtonPressedType=" .. tostring(safe(function()
            return candidate and type(candidate.PrimaryButtonPressed)
        end))
        .. " | SecondaryButtonPressedType=" .. tostring(safe(function()
            return candidate and type(candidate.SecondaryButtonPressed)
        end)))

    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    if candidate ~= nil and type(getTypeInfoFn) == "function" then
        local typeInfo, typeErr = safe(function()
            return getTypeInfoFn(candidate)
        end)
        log("AUTOSHIP TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | success=" .. tostring(typeErr == nil)
            .. " | resultType=" .. tostring(type(typeInfo))
            .. " | error=" .. tostring(typeErr or ""))
        if typeErr == nil and typeInfo ~= nil then
            stationAddLogLong("AUTOSHIP." .. tostring(label), typeInfo)
        end
    end
end

local function autoShipAttempt(label, fn, shipSelect, goodsFinder)
    local selectedBefore = autoShipSelectedCount(shipSelect)
    local loadRowsBefore = autoShipLoadRowCount(goodsFinder)

    local result, err = safe(fn)

    local selectedAfter = autoShipSelectedCount(shipSelect)
    local loadRowsAfter = autoShipLoadRowCount(goodsFinder)

    log("AUTOSHIP ATTEMPT"
        .. " | label=" .. tostring(label)
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(bindingSafeToString(result))
        .. " | error=" .. tostring(err or "")
        .. " | selectedBefore=" .. tostring(selectedBefore)
        .. " | selectedAfter=" .. tostring(selectedAfter)
        .. " | loadRowsBefore=" .. tostring(loadRowsBefore)
        .. " | loadRowsAfter=" .. tostring(loadRowsAfter))

    return (tonumber(selectedAfter) or 0) > (tonumber(selectedBefore) or 0)
        or (tonumber(loadRowsAfter) or 0) > 0
end

function GoodsFinder:ProbeAutoSelectTemporaryShip()
    log("AUTOSHIP START | select the first available ship once, close the selector, and continue after UI refresh")

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local shipSelect = safe(function()
        return scene and scene.TradeShipSelect
    end)
    local routeValid = safe(function()
        return TradeRoute and TradeRoute.UIEditRoute and TradeRoute.UIEditRoute:isValid()
    end)

    if routeValid ~= true or shipSelect == nil then
        log("AUTOSHIP ABORT"
            .. " | routeValid=" .. tostring(routeValid)
            .. " | shipSelectType=" .. tostring(type(shipSelect)))
        return false
    end

    if safe(function() return shipSelect.IsPopupVisible end) ~= true then
        local openResult, openErr = safe(function()
            return shipSelect.ShipSelectBtn_Pressed(shipSelect)
        end)
        log("AUTOSHIP OPEN"
            .. " | success=" .. tostring(openErr == nil)
            .. " | result=" .. tostring(bindingSafeToString(openResult))
            .. " | error=" .. tostring(openErr or "")
            .. " | popupVisibleAfter=" .. tostring(safe(function()
                return shipSelect.IsPopupVisible
            end)))
    end

    local shipList = safe(function()
        return shipSelect.ShipList
    end)
    local shipCount, shipCountErr = autoShipArraySize(
        shipList,
        "PhoenixArray<halo::CTradeShipData>"
    )
    local selectedBefore, selectedBeforeErr = autoShipSelectedCount(shipSelect)

    log("AUTOSHIP CONTEXT"
        .. " | popupVisible=" .. tostring(safe(function() return shipSelect.IsPopupVisible end))
        .. " | shipCount=" .. tostring(shipCount)
        .. " | shipCountError=" .. tostring(shipCountErr or "")
        .. " | selectedBefore=" .. tostring(selectedBefore)
        .. " | selectedBeforeError=" .. tostring(selectedBeforeErr or "")
        .. " | listWaitPendingBefore=" .. tostring(self.autoShipListWaitPending == true)
        .. " | pendingBefore=" .. tostring(self.autoShipSelectionPending == true)
        .. " | pendingShipName=" .. tostring(self.autoShipSelectionName or ""))

    if tonumber(selectedBefore) and tonumber(selectedBefore) > 0 then
        self.autoShipListWaitPending = false
        self.autoShipListWaitTickCounter = 0
        self.autoShipListWaitLogged = false
        self.autoShipSelectionPending = false

        local closeResult, closeErr = safe(function()
            if type(shipSelect.ShipPopup_Close) == "function"
                and safe(function() return shipSelect.IsPopupVisible end) == true then
                return shipSelect.ShipPopup_Close(shipSelect)
            end
            return nil
        end)

        log("AUTOSHIP ALREADY SELECTED"
            .. " | selectedCount=" .. tostring(selectedBefore)
            .. " | closeSuccess=" .. tostring(closeErr == nil)
            .. " | closeResult=" .. tostring(bindingSafeToString(closeResult))
            .. " | closeError=" .. tostring(closeErr or ""))
        return true
    end

    if tonumber(shipCount) == nil or tonumber(shipCount) <= 0 then
        if self.autoShipListWaitPending ~= true then
            self.autoShipListWaitPending = true
            self.autoShipListWaitTickCounter = 0
            self.autoShipListWaitLogged = false
        end

        log("AUTOSHIP WAIT"
            .. " | reason=ship selector opened before ShipList populated"
            .. " | listWaitPending=true"
            .. " | popupVisible=" .. tostring(safe(function()
                return shipSelect.IsPopupVisible
            end))
            .. " | next=Tick will select the first ship when the list becomes available")
        return "wait_list"
    end

    self.autoShipListWaitPending = false
    self.autoShipListWaitTickCounter = 0
    self.autoShipListWaitLogged = false

    local first, firstErr = autoShipArrayElement(
        shipList,
        "PhoenixArray<halo::CTradeShipData>",
        0
    )

    if first == nil then
        log("AUTOSHIP ABORT"
            .. " | reason=first ship unavailable"
            .. " | error=" .. tostring(firstErr or ""))
        return false
    end

    local firstName = tostring(safe(function()
        return first.ShipName
    end) or "")

    log("AUTOSHIP TARGET"
        .. " | arrayIndex=0"
        .. " | shipName=" .. tostring(firstName)
        .. " | shipValue=" .. tostring(bindingSafeToString(first))
        .. " | primaryButtonType=" .. tostring(safe(function()
            return type(first.PrimaryButtonPressed)
        end)))

    local focusResult, focusErr = safe(function()
        shipSelect.ShipsPopupFocusedIndex = 0
        shipSelect.ShipsPopupHoveredIndex = 0
        return tostring(shipSelect.ShipsPopupFocusedIndex)
            .. "/" .. tostring(shipSelect.ShipsPopupHoveredIndex)
    end)

    log("AUTOSHIP FOCUS"
        .. " | success=" .. tostring(focusErr == nil)
        .. " | result=" .. tostring(focusResult)
        .. " | error=" .. tostring(focusErr or ""))

    if type(safe(function() return first.PrimaryButtonPressed end)) ~= "function" then
        log("AUTOSHIP ABORT | reason=first ship PrimaryButtonPressed unavailable")
        return false
    end

    local dispatchResult, dispatchErr = safe(function()
        return first.PrimaryButtonPressed(first)
    end)

    log("AUTOSHIP DISPATCH"
        .. " | mode=ShipList[0].PrimaryButtonPressed(first)"
        .. " | success=" .. tostring(dispatchErr == nil)
        .. " | resultType=" .. tostring(type(dispatchResult))
        .. " | result=" .. tostring(bindingSafeToString(dispatchResult))
        .. " | error=" .. tostring(dispatchErr or ""))

    if dispatchErr ~= nil then
        return false
    end

    self.autoShipListWaitPending = false
    self.autoShipListWaitTickCounter = 0
    self.autoShipListWaitLogged = false
    self.autoShipSelectionPending = true
    self.autoShipSelectionName = firstName
    self.autoShipTickCounter = 0
    self.autoShipTickLogged = false

    local closeResult, closeErr = safe(function()
        if type(shipSelect.ShipPopup_Close) == "function" then
            return shipSelect.ShipPopup_Close(shipSelect)
        end
        return nil
    end)

    local selectedAfter, selectedAfterErr = autoShipSelectedCount(shipSelect)
    local loadRowsAfter, loadRowsAfterErr = autoShipLoadRowCount(self)

    log("AUTOSHIP POST-CLOSE"
        .. " | shipName=" .. tostring(firstName)
        .. " | closeSuccess=" .. tostring(closeErr == nil)
        .. " | closeResult=" .. tostring(bindingSafeToString(closeResult))
        .. " | closeError=" .. tostring(closeErr or "")
        .. " | popupVisibleAfter=" .. tostring(safe(function()
            return shipSelect.IsPopupVisible
        end))
        .. " | selectedAfter=" .. tostring(selectedAfter)
        .. " | selectedAfterError=" .. tostring(selectedAfterErr or "")
        .. " | rememberedLoadRowCount=" .. tostring(loadRowsAfter)
        .. " | loadRowError=" .. tostring(loadRowsAfterErr or ""))

    if (tonumber(selectedAfter) or 0) > 0
        or (tonumber(loadRowsAfter) or 0) > 0 then
        self.autoShipSelectionPending = false
        log("AUTOSHIP SUCCESS"
            .. " | shipName=" .. tostring(firstName)
            .. " | selectedCount=" .. tostring(selectedAfter)
            .. " | rememberedLoadRowCount=" .. tostring(loadRowsAfter))
        return true
    end

    log("AUTOSHIP PENDING"
        .. " | shipName=" .. tostring(firstName)
        .. " | visualSelectionExpected=true"
        .. " | reason=route data refresh occurs after the shortcut returns"
        .. " | next=Tick will recheck automatically after the route data refresh")
    return "pending"
end





local function nativeClickSafePairs(tbl)
    local records = {}
    if type(tbl) ~= "table" then
        return records
    end

    local ok, err = pcall(function()
        for key, value in pairs(tbl) do
            records[#records + 1] = {
                key = tostring(key),
                valueType = type(value),
                value = value
            }
        end
    end)

    if not ok then
        log("NATIVECLICK PAIRS FAILED | error=" .. tostring(err))
        return records
    end

    table.sort(records, function(a, b)
        return a.key < b.key
    end)
    return records
end

local function nativeClickArrayEntries()
    local macroScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.MacroMap
    end)
    local macroData = safe(function()
        return macroScene and macroScene.MacroMapData
    end)
    local islandsList = safe(function()
        return macroData and macroData.IslandsList
    end)
    local rawEntries, helperKey = islandPressArray(islandsList)
    local entries = {}

    for _, rawEntry in ipairs(rawEntries or {}) do
        local item = rawEntry.value
        local base = safe(function()
            return item and item.BaseData
        end)
        if base == nil then
            base = item
        end

        local infoTip = safe(function()
            return base and base.InfoTip
        end)
        local btnStates = safe(function()
            return base and base.BtnStates
        end)
        local areaID = tonumber(safe(function()
            return infoTip and infoTip.RefGUID
        end)) or 0

        entries[#entries + 1] = {
            item = item,
            base = base,
            infoTip = infoTip,
            btnStates = btnStates,
            areaID = areaID,
            arrayIndex = rawEntry.arrayIndex
        }
    end

    return entries, macroScene, macroData, helperKey
end

local function nativeClickFindRemembered(goodsFinder)
    local requested = tonumber(goodsFinder.lastWarehouseAreaId) or 0
    local entries, macroScene, macroData, helperKey = nativeClickArrayEntries()

    for _, entry in ipairs(entries or {}) do
        if tonumber(entry.areaID) == requested then
            entry.macroScene = macroScene
            entry.macroData = macroData
            entry.helperKey = helperKey
            return entry, entries
        end
    end

    return nil, entries
end

local function nativeClickDescribeValue(label, value)
    log("NATIVECLICK VALUE"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(value))
        .. " | value=" .. tostring(bindingSafeToString(value))
        .. " | metatableType=" .. tostring(type(safe(function()
            return getmetatable(value)
        end)))
        .. " | metatableValue=" .. tostring(bindingSafeToString(safe(function()
            return getmetatable(value)
        end))))
end

local function nativeClickDumpTable(label, tbl, limit)
    local records = nativeClickSafePairs(tbl)
    local maximum = math.min(#records, tonumber(limit) or 80)

    log("NATIVECLICK TABLE"
        .. " | label=" .. tostring(label)
        .. " | type=" .. tostring(type(tbl))
        .. " | entries=" .. tostring(#records)
        .. " | limit=" .. tostring(maximum)
        .. " | value=" .. tostring(bindingSafeToString(tbl)))

    for index = 1, maximum do
        local record = records[index]
        log("NATIVECLICK TABLE ENTRY"
            .. " | label=" .. tostring(label)
            .. " | index=" .. tostring(index)
            .. " | key=" .. tostring(record.key)
            .. " | valueType=" .. tostring(record.valueType)
            .. " | value=" .. tostring(bindingSafeToString(record.value)))
    end
end

local function nativeClickSnapshot(goodsFinder, label, entry)
    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local macroScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.MacroMap
    end)
    local macroData = safe(function()
        return macroScene and macroScene.MacroMapData
    end)
    local stationCount, stationErr = assistedRouteStationCount()

    local propertyNames = {
        "FocusedIndex",
        "HoveredIndex",
        "SelectedIndex",
        "IslandFocusedIndex",
        "IslandHoveredIndex",
        "IslandSelectedIndex",
        "CurrentIslandIndex",
        "CurrentIslandData",
        "FocusedIslandData",
        "HoveredIslandData",
        "SelectedIslandData",
        "RouteCreation",
        "IsPopupVisible"
    }

    local propertyText = {}
    for _, name in ipairs(propertyNames) do
        local value, err = safe(function()
            return macroData and macroData[name]
        end)
        propertyText[#propertyText + 1] =
            tostring(name) .. "=" .. tostring(bindingSafeToString(value))
                .. (err and (":" .. tostring(err)) or "")
    end

    log("NATIVECLICK SNAPSHOT"
        .. " | label=" .. tostring(label)
        .. " | stationCount=" .. tostring(stationCount)
        .. " | stationError=" .. tostring(stationErr or "")
        .. " | routeValid=" .. tostring(safe(function()
            return TradeRoute
                and TradeRoute.UIEditRoute
                and TradeRoute.UIEditRoute:isValid()
        end))
        .. " | globalInfoTipRefGuid=" .. tostring(safe(function()
            return InfoTip and InfoTip.RefGuid
        end))
        .. " | rememberedAreaID=" .. tostring(goodsFinder.lastWarehouseAreaId or 0)
        .. " | rememberedIsland=" .. tostring(goodsFinder.lastWarehouseAreaName or "")
        .. " | targetArrayIndex=" .. tostring(entry and entry.arrayIndex or "")
        .. " | targetHovered=" .. tostring(safe(function()
            return entry and entry.base and entry.base.IsHovered
        end))
        .. " | targetFocused=" .. tostring(safe(function()
            return entry and entry.btnStates and entry.btnStates.IsFocused
        end))
        .. " | targetSelected=" .. tostring(safe(function()
            return entry and entry.btnStates and entry.btnStates.IsSelected
        end))
        .. " | macroDataProperties=" .. table.concat(propertyText, ";"))
end

local function nativeClickLogArguments(goodsFinder, source, ...)
    goodsFinder.nativeClickProbeHookCallCount =
        (tonumber(goodsFinder.nativeClickProbeHookCallCount) or 0) + 1

    local callIndex = goodsFinder.nativeClickProbeHookCallCount
    local count = select("#", ...)
    local pieces = {}

    for index = 1, count do
        local value = select(index, ...)
        pieces[#pieces + 1] =
            tostring(index)
                .. ":" .. tostring(type(value))
                .. ":" .. tostring(bindingSafeToString(value))
    end

    local stationCount, stationErr = assistedRouteStationCount()

    log("NATIVECLICK HOOK CALL"
        .. " | source=" .. tostring(source)
        .. " | callIndex=" .. tostring(callIndex)
        .. " | argumentCount=" .. tostring(count)
        .. " | arguments=" .. table.concat(pieces, " || ")
        .. " | stationCountAtEntry=" .. tostring(stationCount)
        .. " | stationError=" .. tostring(stationErr or "")
        .. " | globalInfoTipRefGuid=" .. tostring(safe(function()
            return InfoTip and InfoTip.RefGuid
        end)))
end

local function nativeClickRememberHook(goodsFinder, record)
    goodsFinder.nativeClickProbeHooks =
        goodsFinder.nativeClickProbeHooks or {}
    goodsFinder.nativeClickProbeHooks[
        #goodsFinder.nativeClickProbeHooks + 1
    ] = record
end

local function nativeClickTryInstallTableHook(goodsFinder, label, tbl, key)
    if type(tbl) ~= "table" then
        return false
    end

    local original = rawget(tbl, key)
    if type(original) ~= "function" then
        return false
    end

    local wrapper
    wrapper = function(...)
        nativeClickLogArguments(goodsFinder, label .. "." .. key, ...)
        local beforeCount = assistedRouteStationCount()
        local result = original(...)
        local afterCount = assistedRouteStationCount()

        log("NATIVECLICK HOOK RETURN"
            .. " | source=" .. tostring(label .. "." .. key)
            .. " | beforeCount=" .. tostring(beforeCount)
            .. " | afterCount=" .. tostring(afterCount)
            .. " | returnType=" .. tostring(type(result))
            .. " | returnValue=" .. tostring(bindingSafeToString(result)))
        return result
    end

    local writeResult, writeErr = safe(function()
        tbl[key] = wrapper
        return tbl[key]
    end)
    local installed = writeErr == nil and rawget(tbl, key) == wrapper

    log("NATIVECLICK HOOK INSTALL"
        .. " | source=" .. tostring(label .. "." .. key)
        .. " | success=" .. tostring(installed)
        .. " | writeError=" .. tostring(writeErr or "")
        .. " | original=" .. tostring(bindingSafeToString(original))
        .. " | after=" .. tostring(bindingSafeToString(writeResult)))

    if installed then
        nativeClickRememberHook(goodsFinder, {
            kind = "table",
            label = label,
            target = tbl,
            key = key,
            original = original,
            wrapper = wrapper
        })
    end

    return installed
end

local function nativeClickTryInstallInstanceHook(goodsFinder, label, target, key)
    if target == nil then
        return false
    end

    local original = safe(function()
        return target[key]
    end)
    if type(original) ~= "function" then
        return false
    end

    local wrapper
    wrapper = function(...)
        nativeClickLogArguments(goodsFinder, label .. "." .. key, ...)
        return original(...)
    end

    local writeResult, writeErr = safe(function()
        target[key] = wrapper
        return target[key]
    end)
    local installed = writeErr == nil and writeResult == wrapper

    log("NATIVECLICK INSTANCE HOOK INSTALL"
        .. " | source=" .. tostring(label .. "." .. key)
        .. " | success=" .. tostring(installed)
        .. " | writeError=" .. tostring(writeErr or "")
        .. " | original=" .. tostring(bindingSafeToString(original))
        .. " | after=" .. tostring(bindingSafeToString(writeResult)))

    if installed then
        nativeClickRememberHook(goodsFinder, {
            kind = "instance",
            label = label,
            target = target,
            key = key,
            original = original,
            wrapper = wrapper
        })
    end

    return installed
end

local function nativeClickRestoreHooks(goodsFinder)
    local hooks = goodsFinder.nativeClickProbeHooks or {}

    for index = #hooks, 1, -1 do
        local hook = hooks[index]
        local result, err = safe(function()
            hook.target[hook.key] = hook.original
            return hook.target[hook.key]
        end)

        log("NATIVECLICK HOOK RESTORE"
            .. " | index=" .. tostring(index)
            .. " | kind=" .. tostring(hook.kind)
            .. " | label=" .. tostring(hook.label)
            .. " | key=" .. tostring(hook.key)
            .. " | success=" .. tostring(err == nil)
            .. " | result=" .. tostring(bindingSafeToString(result))
            .. " | error=" .. tostring(err or ""))
    end

    goodsFinder.nativeClickProbeHooks = {}
end

local function nativeClickAudit(goodsFinder, entry)
    if goodsFinder.nativeClickProbeAuditDone == true then
        return
    end
    goodsFinder.nativeClickProbeAuditDone = true

    log("NATIVECLICK AUDIT START"
        .. " | rememberedAreaID=" .. tostring(goodsFinder.lastWarehouseAreaId or 0)
        .. " | rememberedIsland=" .. tostring(goodsFinder.lastWarehouseAreaName or "")
        .. " | arrayIndex=" .. tostring(entry and entry.arrayIndex or "")
        .. " | itemType=" .. tostring(type(entry and entry.item))
        .. " | itemValue=" .. tostring(bindingSafeToString(entry and entry.item))
        .. " | baseType=" .. tostring(type(entry and entry.base))
        .. " | baseValue=" .. tostring(bindingSafeToString(entry and entry.base))
        .. " | onPressType=" .. tostring(safe(function()
            return type(entry.base.OnPress)
        end))
        .. " | onPressValue=" .. tostring(bindingSafeToString(safe(function()
            return entry.base.OnPress
        end))))

    nativeClickDescribeValue("entry.item", entry.item)
    nativeClickDescribeValue("entry.base", entry.base)
    nativeClickDescribeValue("entry.infoTip", entry.infoTip)
    nativeClickDescribeValue("entry.btnStates", entry.btnStates)
    nativeClickDescribeValue("entry.item.metatable", safe(function()
        return getmetatable(entry.item)
    end))
    nativeClickDescribeValue("entry.base.metatable", safe(function()
        return getmetatable(entry.base)
    end))

    local haloRoot = rawget(_G, "halo")
    local matches = {}

    if type(haloRoot) == "table" then
        for key, value in pairs(haloRoot) do
            local keyText = tostring(key)
            if string.find(keyText, "MacroMapIsland", 1, true)
                or string.find(keyText, "TradeRouteScene", 1, true)
                or string.find(keyText, "TradeRouteOverview", 1, true) then
                matches[#matches + 1] = {
                    key = keyText,
                    value = value
                }
            end
        end
    end

    table.sort(matches, function(a, b)
        return a.key < b.key
    end)

    log("NATIVECLICK HALO MATCHES | count=" .. tostring(#matches))
    for index, match in ipairs(matches) do
        log("NATIVECLICK HALO MATCH"
            .. " | index=" .. tostring(index)
            .. " | key=" .. tostring(match.key)
            .. " | valueType=" .. tostring(type(match.value))
            .. " | value=" .. tostring(bindingSafeToString(match.value)))

        if type(match.value) == "table" then
            nativeClickDumpTable("halo." .. match.key, match.value, 100)
            nativeClickTryInstallTableHook(
                goodsFinder,
                "halo." .. match.key,
                match.value,
                "OnPress"
            )
        end
    end

    local itemMetatable = safe(function()
        return getmetatable(entry.item)
    end)
    local baseMetatable = safe(function()
        return getmetatable(entry.base)
    end)

    nativeClickDumpTable("entry.item.metatable", itemMetatable, 100)
    nativeClickDumpTable("entry.base.metatable", baseMetatable, 100)

    nativeClickTryInstallTableHook(
        goodsFinder,
        "entry.item.metatable",
        itemMetatable,
        "OnPress"
    )
    nativeClickTryInstallTableHook(
        goodsFinder,
        "entry.base.metatable",
        baseMetatable,
        "OnPress"
    )
    nativeClickTryInstallInstanceHook(
        goodsFinder,
        "entry.item",
        entry.item,
        "OnPress"
    )
    nativeClickTryInstallInstanceHook(
        goodsFinder,
        "entry.base",
        entry.base,
        "OnPress"
    )

    nativeClickSnapshot(goodsFinder, "before first manual island click", entry)

    log("NATIVECLICK AUDIT COMPLETE"
        .. " | installedHookCount=" .. tostring(
            #(goodsFinder.nativeClickProbeHooks or {})
        )
        .. " | instruction=click Mytholos once, then click one second island once"
        .. " | automaticAfterTwoStations=true")
end

local function nativeClickProbeTick(goodsFinder)
    goodsFinder.nativeClickProbeTickCounter =
        (tonumber(goodsFinder.nativeClickProbeTickCounter) or 0) + 1

    local tickCount = goodsFinder.nativeClickProbeTickCounter
    local routeValid = safe(function()
        return TradeRoute
            and TradeRoute.UIEditRoute
            and TradeRoute.UIEditRoute:isValid()
    end)
    local stationCount, stationErr = assistedRouteStationCount()
    stationCount = tonumber(stationCount) or 0

    if routeValid ~= true then
        if tickCount == 1 or tickCount % 10 == 0 then
            log("NATIVECLICK WAIT ROUTE"
                .. " | tickCount=" .. tostring(tickCount)
                .. " | routeValid=" .. tostring(routeValid)
                .. " | stationCount=" .. tostring(stationCount)
                .. " | stationError=" .. tostring(stationErr or ""))
        end

        if tickCount >= 60 then
            nativeClickRestoreHooks(goodsFinder)
            goodsFinder.nativeClickProbePending = false
            log("NATIVECLICK ABORT"
                .. " | reason=temporary route editor did not become valid")
        end
        return
    end

    local rememberedEntry = nativeClickFindRemembered(goodsFinder)
    if rememberedEntry == nil then
        if tickCount == 1 or tickCount % 10 == 0 then
            log("NATIVECLICK WAIT TARGET"
                .. " | tickCount=" .. tostring(tickCount)
                .. " | rememberedAreaID=" .. tostring(
                    goodsFinder.lastWarehouseAreaId or 0
                )
                .. " | stationCount=" .. tostring(stationCount))
        end
        return
    end

    nativeClickAudit(goodsFinder, rememberedEntry)

    local previousCount =
        tonumber(goodsFinder.nativeClickProbePreviousStationCount) or 0

    if stationCount ~= previousCount then
        log("NATIVECLICK STATION CHANGE"
            .. " | before=" .. tostring(previousCount)
            .. " | after=" .. tostring(stationCount)
            .. " | hookCallCount=" .. tostring(
                goodsFinder.nativeClickProbeHookCallCount or 0
            )
            .. " | tickCount=" .. tostring(tickCount)
            .. " | globalInfoTipRefGuid=" .. tostring(safe(function()
                return InfoTip and InfoTip.RefGuid
            end)))

        nativeClickSnapshot(
            goodsFinder,
            "after station count changed to " .. tostring(stationCount),
            rememberedEntry
        )
        goodsFinder.nativeClickProbePreviousStationCount = stationCount
    end

    if stationCount == 1
        and goodsFinder.nativeClickProbePhase ~= "wait_second" then
        goodsFinder.nativeClickProbePhase = "wait_second"
        log("NATIVECLICK FIRST STATION OBSERVED"
            .. " | hookCallCount=" .. tostring(
                goodsFinder.nativeClickProbeHookCallCount or 0
            )
            .. " | instruction=click one different owned island once")
    end

    if stationCount >= 2 then
        nativeClickSnapshot(
            goodsFinder,
            "after second manual island click",
            rememberedEntry
        )
        nativeClickRestoreHooks(goodsFinder)

        goodsFinder.nativeClickProbePending = false
        goodsFinder.nativeClickProbePhase = "complete"

        log("NATIVECLICK CAPTURE COMPLETE"
            .. " | stationCount=" .. tostring(stationCount)
            .. " | hookCallCount=" .. tostring(
                goodsFinder.nativeClickProbeHookCallCount or 0
            )
            .. " | action=continue through validated automatic ship and goods workflow")

        local result, err = safe(function()
            return goodsFinder:CaptureOpenAndCreateRoute()
        end)

        log("NATIVECLICK HANDOFF"
            .. " | success=" .. tostring(err == nil)
            .. " | result=" .. tostring(result)
            .. " | error=" .. tostring(err or ""))
    end
end



local function discardProbeToString(value)
    local ok, text = pcall(function()
        return tostring(value)
    end)
    if ok then
        return text
    end
    return "<tostring error>"
end


local function discardProbeTypeInfo(label, value)
    local getTypeInfoFn = rawget(_G, "getTypeInfo")
    local getDeprecatedFn =
        rawget(_G, "getTypeInfoDeprecated")

    if type(getTypeInfoFn) == "function" then
        local result, err = safe(function()
            return getTypeInfoFn(value)
        end)

        log("DISCARDPROBE TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | function=getTypeInfo"
            .. " | success=" .. tostring(err == nil)
            .. " | resultType=" .. tostring(type(result))
            .. " | result=" .. tostring(result)
            .. " | error=" .. tostring(err or ""))
    end

    if type(getDeprecatedFn) == "function" then
        local result, err = safe(function()
            return getDeprecatedFn(value)
        end)

        log("DISCARDPROBE TYPEINFO"
            .. " | label=" .. tostring(label)
            .. " | function=getTypeInfoDeprecated"
            .. " | success=" .. tostring(err == nil)
            .. " | resultType=" .. tostring(type(result))
            .. " | result=" .. tostring(result)
            .. " | error=" .. tostring(err or ""))
    end
end


local discardProbeMemberNames = {
    "isValid",
    "IsVisible",
    "IsOpen",
    "IsDirty",
    "HasChanges",
    "HasUnsavedChanges",
    "RouteChanged",
    "CanSave",
    "CanCancel",
    "CanClose",
    "Save",
    "SaveRoute",
    "SaveChanges",
    "Apply",
    "ApplyChanges",
    "Commit",
    "Confirm",
    "Done",
    "Finish",
    "Cancel",
    "CancelEdit",
    "CancelChanges",
    "CancelRoute",
    "Discard",
    "DiscardChanges",
    "DiscardRoute",
    "Reject",
    "Revert",
    "RevertChanges",
    "Reset",
    "ResetChanges",
    "Undo",
    "Close",
    "CloseRoute",
    "CloseRouteUI",
    "Exit",
    "Leave",
    "Back",
    "RequestClose",
    "RequestCancel",
    "RequestDiscard",
    "CloseButtonPressed",
    "BackButtonPressed",
    "CancelButtonPressed",
    "DiscardButtonPressed",
    "SaveButtonPressed",
    "ConfirmButtonPressed",
    "PrimaryButtonPressed",
    "SecondaryButtonPressed",
    "TertiaryButtonPressed",
    "SceneData",
    "TradeOverview",
    "TradeGoodSelection",
    "TradeRouteGoodData",
    "Station",
    "Good",
    "Name",
    "RouteName",
    "ID",
    "RouteID"
}


local function discardProbeMembers(label, object)
    for _, name in ipairs(discardProbeMemberNames) do
        local value, err = safe(function()
            return object and object[name]
        end)

        log("DISCARDPROBE MEMBER"
            .. " | label=" .. tostring(label)
            .. " | name=" .. tostring(name)
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. discardProbeToString(value)
            .. " | error=" .. tostring(err or ""))
    end
end


local function discardProbeTableKeys(label, object, limit)
    if type(object) ~= "table" then
        log("DISCARDPROBE TABLE"
            .. " | label=" .. tostring(label)
            .. " | type=" .. tostring(type(object))
            .. " | result=not a Lua table")
        return
    end

    local entries = {}
    for key, value in pairs(object) do
        entries[#entries + 1] = {
            key = tostring(key),
            valueType = type(value),
            value = value
        }
    end

    table.sort(entries, function(a, b)
        return a.key < b.key
    end)

    log("DISCARDPROBE TABLE SUMMARY"
        .. " | label=" .. tostring(label)
        .. " | entries=" .. tostring(#entries)
        .. " | loggingLimit=" .. tostring(limit or 100))

    for index = 1, math.min(#entries, limit or 100) do
        local entry = entries[index]
        log("DISCARDPROBE TABLE KEY"
            .. " | label=" .. tostring(label)
            .. " | index=" .. tostring(index)
            .. " | key=" .. tostring(entry.key)
            .. " | type=" .. tostring(entry.valueType)
            .. " | value=" .. discardProbeToString(entry.value))
    end
end


local function inspectTradeRouteDiscardSurfaces(goodsFinder)
    local globalTradeRoute = rawget(_G, "TradeRoute")
    local editRoute = safe(function()
        return globalTradeRoute
            and globalTradeRoute.UIEditRoute
    end)
    local routeValid = safe(function()
        return editRoute
            and editRoute.isValid
            and editRoute:isValid()
    end)

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local sceneData = safe(function()
        return scene and scene.SceneData
    end)
    local overview = safe(function()
        return scene and scene.TradeOverview
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)

    log("DISCARDPROBE START"
        .. " | routeID="
            .. tostring(goodsFinder.existingRouteCurrentId or "")
        .. " | routeName="
            .. tostring(goodsFinder.existingRouteCurrentName or "")
        .. " | routeValid=" .. tostring(routeValid)
        .. " | globalTradeRouteType="
            .. tostring(type(globalTradeRoute))
        .. " | editRouteType=" .. tostring(type(editRoute))
        .. " | sceneType=" .. tostring(type(scene))
        .. " | sceneDataType=" .. tostring(type(sceneData))
        .. " | overviewType=" .. tostring(type(overview))
        .. " | selectionType=" .. tostring(type(selection))
        .. " | readOnly=true"
        .. " | no candidate method invoked")

    local surfaces = {
        {"TradeRoute", globalTradeRoute},
        {"TradeRoute.UIEditRoute", editRoute},
        {"ui.Scenes.TradeRoute", scene},
        {"ui.Scenes.TradeRoute.SceneData", sceneData},
        {"ui.Scenes.TradeRoute.TradeOverview", overview},
        {"ui.Scenes.TradeRoute.TradeGoodSelection", selection}
    }

    for _, surface in ipairs(surfaces) do
        local label = surface[1]
        local value = surface[2]

        if value ~= nil then
            discardProbeTypeInfo(label, value)
            discardProbeMembers(label, value)
            discardProbeTableKeys(label, value, 120)
        end
    end

    local haloRoot = rawget(_G, "halo")
    if type(haloRoot) == "table" then
        local classNames = {
            "TradeRouteSceneObject",
            "CSessionTradeRoute",
            "CSessionTradeRouteStationInfo",
            "CSessionTradeRouteGoodInfo",
            "TradeRouteGoodSelectionData",
            "TradeRouteGoodPopupData"
        }

        for _, name in ipairs(classNames) do
            local classValue = haloRoot[name]
            if classValue ~= nil then
                local label = "halo." .. tostring(name)
                discardProbeTypeInfo(label, classValue)
                discardProbeMembers(label, classValue)
                discardProbeTableKeys(label, classValue, 120)
            end
        end
    end

    log("DISCARDPROBE COMPLETE"
        .. " | readOnly=true"
        .. " | next=normal parent close continues"
        .. " | if Save changes appears, choose No manually | removeSurfaceProbe=true")

    return true
end




local removeSurfaceProbeMemberNames = {
    "AddGood",
    "RemoveGood",
    "Remove",
    "DeleteGood",
    "Delete",
    "ClearGood",
    "Clear",
    "ResetGood",
    "Reset",
    "Undo",
    "Cancel",
    "Discard",
    "Revert",
    "RemoveGoodPressed",
    "RemoveGood_Pressed",
    "DeleteGoodPressed",
    "DeleteGood_Pressed",
    "ClearGoodPressed",
    "ClearGood_Pressed",
    "RemoveButtonPressed",
    "RemoveBtnPressed",
    "RemoveBtn_Pressed",
    "OnRemoveGood",
    "OnDeleteGood",
    "IsGoodLoaded",
    "Amount",
    "GoodImageID",
    "Index",
    "StationId",
    "IsBtnVisible",
    "IsBtnSelected",
    "IsFocused",
    "IsHovered"
}

local function removeSurfaceProbeMembers(label, object)
    for _, name in ipairs(removeSurfaceProbeMemberNames) do
        local value, err = safe(function()
            return object and object[name]
        end)

        log("REMOVEPROBE MEMBER"
            .. " | label=" .. tostring(label)
            .. " | name=" .. tostring(name)
            .. " | type=" .. tostring(type(value))
            .. " | value=" .. discardProbeToString(value)
            .. " | error=" .. tostring(err or ""))
    end
end

local function removeTrackedTemporaryLoadGood(goodsFinder)
    if goodsFinder.trackedRowRemoveDone == true then
        log("AUTOREMOVE SKIP | reason=cleanup already attempted")
        return false
    end
    goodsFinder.trackedRowRemoveDone = true

    local rowIndex = tonumber(goodsFinder.directLoadSelectedRowIndex)
    local stationIndex = tonumber(goodsFinder.existingRouteHelperStationIndex) or 0
    local originallyEmpty = goodsFinder.directLoadSelectedRowWasEmpty == true

    log("AUTOREMOVE START"
        .. " | routeID=" .. tostring(goodsFinder.existingRouteCurrentId or "")
        .. " | routeName=" .. tostring(goodsFinder.existingRouteCurrentName or "")
        .. " | helperStationIndex=" .. tostring(stationIndex)
        .. " | selectedRowIndex=" .. tostring(rowIndex)
        .. " | originallyEmpty=" .. tostring(originallyEmpty)
        .. " | safety=only the tracked row that was empty before Goods Finder opened may be changed")

    if rowIndex == nil then
        log("AUTOREMOVE COMPLETE | success=false | reason=no tracked selected row | removeCalls=0")
        return false
    end
    if originallyEmpty ~= true then
        log("AUTOREMOVE COMPLETE | success=false | reason=tracked row was not originally empty | removeCalls=0")
        return false
    end

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local stations = safe(function()
        return selection and selection.TradeRouteGoodData
    end)
    local haloRoot = rawget(_G, "halo")
    local stationHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodData>"]
        or nil
    local rowHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodIslandData>"]
        or nil

    if stations == nil
        or type(stationHelper) ~= "table"
        or type(stationHelper.GetElement) ~= "function"
        or type(rowHelper) ~= "table"
        or type(rowHelper.GetElement) ~= "function" then
        log("AUTOREMOVE COMPLETE | success=false | reason=array helper unavailable | removeCalls=0")
        return false
    end

    local station, stationErr = safe(function()
        return stationHelper.GetElement(stations, stationIndex)
    end)
    local rows = safe(function()
        return station and station.TradeRouteLoadandUnloadData
    end)
    local row, rowErr = safe(function()
        return rowHelper.GetElement(rows, rowIndex)
    end)
    local loadGoods = safe(function()
        return row and row.LoadGoods
    end)
    local isLoaded = safe(function()
        return loadGoods and loadGoods.IsGoodLoaded
    end)
    local amount = safe(function()
        return loadGoods and loadGoods.Amount
    end)
    local image = safe(function()
        return loadGoods and loadGoods.GoodImageID
    end)
    local removeMethod = safe(function()
        return loadGoods and loadGoods.RemoveGood
    end)

    log("AUTOREMOVE TARGET"
        .. " | stationError=" .. tostring(stationErr or "")
        .. " | rowError=" .. tostring(rowErr or "")
        .. " | rowType=" .. tostring(type(row))
        .. " | loadGoodsType=" .. tostring(type(loadGoods))
        .. " | isGoodLoaded=" .. tostring(isLoaded)
        .. " | amount=" .. tostring(amount)
        .. " | goodImageID=" .. tostring(image)
        .. " | removeGoodType=" .. tostring(type(removeMethod)))

    if isLoaded ~= true then
        log("AUTOREMOVE EMPTY DOORWAY"
            .. " | selectedRowIndex=" .. tostring(rowIndex)
            .. " | action=call RemoveGood once anyway"
            .. " | reason=opening AddGood can mark the route dirty even when no product is selected")
    end
    if type(removeMethod) ~= "function" then
        log("AUTOREMOVE COMPLETE | success=false | reason=RemoveGood unavailable | removeCalls=0")
        return false
    end

    local result, removeErr = safe(function()
        return removeMethod(loadGoods)
    end)

    local loadedAfter = safe(function()
        return loadGoods and loadGoods.IsGoodLoaded
    end)
    local amountAfter = safe(function()
        return loadGoods and loadGoods.Amount
    end)
    local imageAfter = safe(function()
        return loadGoods and loadGoods.GoodImageID
    end)

    log("AUTOREMOVE DISPATCH"
        .. " | success=" .. tostring(removeErr == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(result)
        .. " | error=" .. tostring(removeErr or "")
        .. " | removeCalls=1"
        .. " | selectedRowIndex=" .. tostring(rowIndex)
        .. " | targetWasLoaded=" .. tostring(isLoaded == true))
    log("AUTOREMOVE RESULT"
        .. " | isGoodLoadedAfter=" .. tostring(loadedAfter)
        .. " | amountAfter=" .. tostring(amountAfter)
        .. " | goodImageIDAfter=" .. tostring(imageAfter)
        .. " | occupiedRowsProtected=true"
        .. " | targetWasLoadedBefore=" .. tostring(isLoaded == true)
        .. " | note=immediate binding fields may remain stale until the route scene refreshes")

    return removeErr == nil
end

local function nativeCloseHelperRowsSnapshot(goodsFinder, label)
    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local selection = safe(function()
        return scene and scene.TradeGoodSelection
    end)
    local stations = safe(function()
        return selection and selection.TradeRouteGoodData
    end)
    local haloRoot = rawget(_G, "halo")
    local stationHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodData>"]
        or nil
    local rowHelper = type(haloRoot) == "table"
        and haloRoot["PhoenixArray<halo::CTradeRouteGoodIslandData>"]
        or nil

    if stations == nil
        or type(stationHelper) ~= "table"
        or type(stationHelper.GetSize) ~= "function"
        or type(stationHelper.GetElement) ~= "function"
        or type(rowHelper) ~= "table"
        or type(rowHelper.GetSize) ~= "function"
        or type(rowHelper.GetElement) ~= "function" then
        log("NATIVECLOSE SNAPSHOT"
            .. " | label=" .. tostring(label)
            .. " | success=false"
            .. " | reason=station/load-row helper unavailable")
        return nil
    end

    local stationCount, stationCountErr = safe(function()
        return stationHelper.GetSize(stations)
    end)
    local stationIndex = tonumber(goodsFinder.existingRouteHelperStationIndex)
    if stationIndex == nil then
        stationIndex = 0
    end
    local station, stationErr = safe(function()
        return stationHelper.GetElement(stations, stationIndex)
    end)
    local rows = safe(function()
        return station and station.TradeRouteLoadandUnloadData
    end)
    local rowCount, rowCountErr = safe(function()
        return rows and rowHelper.GetSize(rows)
    end)

    local pieces = {}
    local count = tonumber(rowCount) or 0
    for index = 0, count - 1 do
        local row = safe(function()
            return rowHelper.GetElement(rows, index)
        end)
        local loadGoods = safe(function() return row and row.LoadGoods end)
        local unloadGoods = safe(function() return row and row.UnloadGoods end)
        local loadAmount = safe(function() return loadGoods and loadGoods.Amount end)
        local loadImage = safe(function() return loadGoods and loadGoods.GoodImageID end)
        local loadActive = safe(function() return loadGoods and loadGoods.IsGoodLoaded end)
        local unloadAmount = safe(function() return unloadGoods and unloadGoods.Amount end)
        local unloadImage = safe(function() return unloadGoods and unloadGoods.GoodImageID end)
        local unloadActive = safe(function() return unloadGoods and unloadGoods.IsGoodLoaded end)
        local piece = table.concat({
            tostring(index),
            tostring(loadAmount),
            tostring(loadImage),
            tostring(loadActive),
            tostring(unloadAmount),
            tostring(unloadImage),
            tostring(unloadActive)
        }, "^")
        pieces[#pieces + 1] = piece

        log("NATIVECLOSE ROW"
            .. " | label=" .. tostring(label)
            .. " | rowIndex=" .. tostring(index)
            .. " | loadAmount=" .. tostring(loadAmount)
            .. " | loadGoodImageID=" .. tostring(loadImage)
            .. " | loadIsGoodLoaded=" .. tostring(loadActive)
            .. " | unloadAmount=" .. tostring(unloadAmount)
            .. " | unloadGoodImageID=" .. tostring(unloadImage)
            .. " | unloadIsGoodLoaded=" .. tostring(unloadActive))
    end

    local signature = table.concat(pieces, "||")
    log("NATIVECLOSE SNAPSHOT"
        .. " | label=" .. tostring(label)
        .. " | success=" .. tostring(stationCountErr == nil and stationErr == nil and rowCountErr == nil)
        .. " | routeID=" .. tostring(goodsFinder.existingRouteCurrentId or "")
        .. " | routeName=" .. tostring(goodsFinder.existingRouteCurrentName or "")
        .. " | helperStationIndex=" .. tostring(stationIndex)
        .. " | helperStationName=" .. tostring(goodsFinder.existingRouteHelperStationName or "")
        .. " | stationCount=" .. tostring(stationCount)
        .. " | rowCount=" .. tostring(count)
        .. " | signature=" .. tostring(signature)
        .. " | stationCountError=" .. tostring(stationCountErr or "")
        .. " | stationError=" .. tostring(stationErr or "")
        .. " | rowCountError=" .. tostring(rowCountErr or ""))
    return signature
end

local function nativeCloseVerifyTick(goodsFinder)
    goodsFinder.nativeCloseVerifyTickCounter =
        (tonumber(goodsFinder.nativeCloseVerifyTickCounter) or 0) + 1
    local tickCount = goodsFinder.nativeCloseVerifyTickCounter

    local routeValid = safe(function()
        return TradeRoute
            and TradeRoute.UIEditRoute
            and TradeRoute.UIEditRoute:isValid()
    end)
    local tradeScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local macroScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.MacroMap
    end)
    local warehouseScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.OMKontorWarehouse
    end)
    local genericScene = safe(function()
        return ui and ui.Scenes and ui.Scenes.GenericPopup
    end)
    local genericData = safe(function()
        return genericScene and genericScene.SceneData
    end)
    local popupVisible = safe(function()
        return tradeScene
            and tradeScene.TradeGoodSelection
            and tradeScene.TradeGoodSelection.PopupData
            and tradeScene.TradeGoodSelection.PopupData.IsVisible
    end)
    local elapsedClock = safe(function()
        if goodsFinder.nativeCloseDispatchClock ~= nil and os and os.clock then
            return os.clock() - goodsFinder.nativeCloseDispatchClock
        end
        return nil
    end)
    local elapsedTime = safe(function()
        if goodsFinder.nativeCloseDispatchTime ~= nil and os and os.time then
            return os.time() - goodsFinder.nativeCloseDispatchTime
        end
        return nil
    end)

    log("NATIVECLOSE VERIFY"
        .. " | tickCount=" .. tostring(tickCount)
        .. " | ticksResumed=true"
        .. " | routeValid=" .. tostring(routeValid)
        .. " | tradeSceneType=" .. tostring(type(tradeScene))
        .. " | macroMapSceneType=" .. tostring(type(macroScene))
        .. " | warehouseSceneType=" .. tostring(type(warehouseScene))
        .. " | genericPopupSceneType=" .. tostring(type(genericScene))
        .. " | genericPopupSceneDataType=" .. tostring(type(genericData))
        .. " | goodsPopupVisible=" .. tostring(popupVisible)
        .. " | baselineEqualsPreclose="
            .. tostring(goodsFinder.nativeCloseBaselineSignature == goodsFinder.nativeClosePrecloseSignature)
        .. " | elapsedClock=" .. tostring(elapsedClock)
        .. " | elapsedSeconds=" .. tostring(elapsedTime)
        .. " | noFollowUpPopUI=true")

    if routeValid ~= true then
        log("NATIVECLOSE COMPLETE"
            .. " | outcome=route editor closed"
            .. " | macroMapSceneType=" .. tostring(type(macroScene))
            .. " | warehouseSceneType=" .. tostring(type(warehouseScene))
            .. " | next=no automatic UI action; leave resulting screen unchanged and upload logfile")
        goodsFinder.nativeCloseVerifyPending = false
        goodsFinder.nativeCloseVerifyTickCounter = 0
        return
    end

    if tickCount >= 12 then
        log("NATIVECLOSE COMPLETE"
            .. " | outcome=route editor remained open after native close request"
            .. " | routeValid=true"
            .. " | no fallback invoked=true"
            .. " | next=close manually if needed and upload logfile")
        goodsFinder.nativeCloseVerifyPending = false
        goodsFinder.nativeCloseVerifyTickCounter = 0
    end
end


local CROSSPROVINCE_LATIUM_PROVINCE = 1589870007
local CROSSPROVINCE_ALBION_PROVINCE = 1563518157
local CROSSPROVINCE_LATIUM_ICON =
    "data/ui/fhd/base/icon_content/generic/icon_2d_region_heartlands.png"
local CROSSPROVINCE_ALBION_ICON =
    "data/ui/fhd/base/icon_content/generic/icon_2d_region_wetlands.png"


local function crossProvinceTargetForProvince(province)
    province = tonumber(province) or 0
    if province == CROSSPROVINCE_LATIUM_PROVINCE then
        return CROSSPROVINCE_LATIUM_ICON, "Latium"
    end
    if province == CROSSPROVINCE_ALBION_PROVINCE then
        return CROSSPROVINCE_ALBION_ICON, "Albion"
    end
    return nil, nil
end


local function crossProvinceReadMapState()
    local macroData = safe(function()
        return ui
            and ui.Scenes
            and ui.Scenes.MacroMap
            and ui.Scenes.MacroMap.MacroMapData
    end)
    local province = tonumber(safe(function()
        return macroData and macroData.Province
    end)) or 0
    local tab = tonumber(safe(function()
        return macroData
            and macroData.TabsData
            and macroData.TabsData.SelectedTabID
    end))
    if tab == nil then tab = -1 end
    return province, tab
end


local function crossProvinceResetDoorwayTracking(goodsFinder)
    goodsFinder.directLoadSelectedRowIndex = nil
    goodsFinder.directLoadSelectedRowWasEmpty = false
    goodsFinder.trackedRowRemoveDone = false
    goodsFinder.nativeCloseBaselineSignature = nil
    goodsFinder.nativeClosePrecloseSignature = nil
    goodsFinder.nativeClosePostremoveSignature = nil
    goodsFinder.existingRouteHelperStationIndex = nil
    goodsFinder.existingRouteHelperStationName = nil
end


local function autoReturnAfterPopupTick(goodsFinder)
    goodsFinder.autoReturnTickCounter =
        (tonumber(goodsFinder.autoReturnTickCounter) or 0) + 1
    local tickCount = goodsFinder.autoReturnTickCounter

    local routeValid = safe(function()
        return TradeRoute
            and TradeRoute.UIEditRoute
            and TradeRoute.UIEditRoute:isValid()
    end)

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local popupVisible = safe(function()
        return scene
            and scene.TradeGoodSelection
            and scene.TradeGoodSelection.PopupData
            and scene.TradeGoodSelection.PopupData.IsVisible
    end)

    if routeValid ~= true then
        local cleanupAttempted = false
        local cleanupResult = nil
        local cleanupErr = nil
        local restored = nil

        -- Anno can invalidate UIEditRoute before the TradeRoute scene binding
        -- disappears. Test 9 hit this on the final exit. Try the guarded
        -- tracked-row cleanup once while the UI binding may still be alive.
        if goodsFinder.autoReturnSawPopup == true
            and goodsFinder.trackedRowRemoveDone ~= true
            and goodsFinder.directLoadSelectedRowWasEmpty == true
            and tonumber(goodsFinder.directLoadSelectedRowIndex) ~= nil
        then
            cleanupAttempted = true
            goodsFinder.nativeClosePrecloseSignature =
                nativeCloseHelperRowsSnapshot(
                    goodsFinder,
                    "external-close-precleanup"
                )

            cleanupResult, cleanupErr = safe(function()
                return removeTrackedTemporaryLoadGood(
                    goodsFinder
                )
            end)

            goodsFinder.nativeClosePostremoveSignature =
                nativeCloseHelperRowsSnapshot(
                    goodsFinder,
                    "external-close-postcleanup"
                )

            if goodsFinder.nativeCloseBaselineSignature ~= nil
                and goodsFinder.nativeClosePostremoveSignature ~= nil
            then
                restored =
                    goodsFinder.nativeCloseBaselineSignature
                    == goodsFinder.nativeClosePostremoveSignature
            end

            log("AUTORETURN EXTERNAL CLOSE CLEANUP"
                .. " | attempted=true"
                .. " | callSuccess="
                    .. tostring(cleanupErr == nil)
                .. " | callResult="
                    .. tostring(cleanupResult)
                .. " | error="
                    .. tostring(cleanupErr or "")
                .. " | baselineEqualsPostremove="
                    .. tostring(restored)
                .. " | closeTradeRouteCalls=0"
                .. " | popUICalls=0"
                .. " | reason=UIEditRoute became invalid before normal popup-close cleanup")
        end

        log("AUTORETURN CANCEL"
            .. " | reason=Trade Route editor already closed"
            .. " | tickCount=" .. tostring(tickCount)
            .. " | popupVisible=" .. tostring(popupVisible)
            .. " | cleanupAttempted="
                .. tostring(cleanupAttempted)
            .. " | cleanupSuccess="
                .. tostring(cleanupAttempted == true
                    and cleanupErr == nil)
            .. " | noAdditionalClose=true")

        goodsFinder.autoReturnPending = false
        goodsFinder.autoReturnSawPopup = false
        goodsFinder.autoReturnTickCounter = 0
        goodsFinder.autoReturnCloseTickCounter = 0
        goodsFinder.autoReturnCloseGraceLogged = false
        goodsFinder.autoReturnLogged = false
        goodsFinder.sameDoorwayReopenPending = false
        goodsFinder.sameDoorwayReopenTick = 0
        return
    end

    if popupVisible == true then
        goodsFinder.autoReturnSawPopup = true
        goodsFinder.autoReturnCloseTickCounter = 0
        goodsFinder.autoReturnCloseGraceLogged = false

        if goodsFinder.autoReturnLogged ~= true then
            goodsFinder.autoReturnLogged = true
            local macroProvince, macroTab =
                crossProvinceReadMapState()
            goodsFinder.crossProvincePopupProvince =
                macroProvince
            goodsFinder.crossProvincePopupTab =
                macroTab

            log("CROSSPROVINCE POPUP BASELINE"
                .. " | province=" .. tostring(macroProvince)
                .. " | tab=" .. tostring(macroTab)
                .. " | routeID="
                    .. tostring(goodsFinder.existingRouteCurrentId or "")
                .. " | helperStation="
                    .. tostring(goodsFinder.existingRouteHelperStationName or ""))

            log("AUTORETURN ARMED"
                .. " | popupVisible=true"
                .. " | routeValid=true"
                .. " | instruction=press Escape once to close the stock popup"
                .. " | next=Goods Finder will clean the tracked originally-empty doorway row once, even if no product was selected, then close the parent Trade Route view automatically")
        end
        return
    end

    if goodsFinder.autoReturnSawPopup ~= true then
        if tickCount >= 120 then
            log("AUTORETURN TIMEOUT"
                .. " | reason=stock popup was never observed as visible"
                .. " | tickCount=" .. tostring(tickCount))
            goodsFinder.autoReturnPending = false
            goodsFinder.autoReturnTickCounter = 0
            goodsFinder.autoReturnCloseTickCounter = 0
            goodsFinder.autoReturnCloseGraceLogged = false
            goodsFinder.autoReturnLogged = false
        end
        return
    end

    goodsFinder.autoReturnCloseTickCounter =
        (tonumber(goodsFinder.autoReturnCloseTickCounter) or 0) + 1

    local closeTick =
        tonumber(goodsFinder.autoReturnCloseTickCounter) or 0
    local currentMacroProvince, currentMacroTab =
        crossProvinceReadMapState()
    local popupProvince =
        tonumber(goodsFinder.crossProvincePopupProvince) or 0
    local popupTab =
        tonumber(goodsFinder.crossProvincePopupTab)
    if popupTab == nil then popupTab = -1 end

    -- Native province-tab clicks close the Load Good popup before Anno always
    -- publishes the new MacroMap province/tab values. The old implementation
    -- decided immediately and could therefore misclassify a real province
    -- switch as Escape. Wait up to three Tick cycles for the native tab state.
    local provinceChanged =
        (popupProvince > 0
            and currentMacroProvince > 0
            and currentMacroProvince ~= popupProvince)
        or (popupTab >= 0
            and currentMacroTab >= 0
            and currentMacroTab ~= popupTab)

    local graceTicks = 3
    if provinceChanged ~= true and closeTick < graceTicks then
        if goodsFinder.autoReturnCloseGraceLogged ~= true then
            goodsFinder.autoReturnCloseGraceLogged = true
            log("CROSSPROVINCE CLOSE GRACE START"
                .. " | popupProvince=" .. tostring(popupProvince)
                .. " | popupTab=" .. tostring(popupTab)
                .. " | currentMacroProvince=" .. tostring(currentMacroProvince)
                .. " | currentMacroTab=" .. tostring(currentMacroTab)
                .. " | closeTick=" .. tostring(closeTick)
                .. " | graceTicks=" .. tostring(graceTicks)
                .. " | reason=native tab update may lag popup close"
                .. " | action=wait before deciding Escape vs province switch")
        else
            log("CROSSPROVINCE CLOSE GRACE WAIT"
                .. " | popupProvince=" .. tostring(popupProvince)
                .. " | popupTab=" .. tostring(popupTab)
                .. " | currentMacroProvince=" .. tostring(currentMacroProvince)
                .. " | currentMacroTab=" .. tostring(currentMacroTab)
                .. " | closeTick=" .. tostring(closeTick)
                .. " | graceTicks=" .. tostring(graceTicks))
        end
        return
    end

    log("AUTORETURN POPUP CLOSED"
        .. " | popupVisible=false"
        .. " | routeValid=true"
        .. " | popupProvince=" .. tostring(popupProvince)
        .. " | popupTab=" .. tostring(popupTab)
        .. " | currentMacroProvince="
            .. tostring(currentMacroProvince)
        .. " | currentMacroTab="
            .. tostring(currentMacroTab)
        .. " | closeTick=" .. tostring(closeTick)
        .. " | graceTicks=" .. tostring(graceTicks)
        .. " | provinceChanged="
            .. tostring(provinceChanged)
        .. " | action="
            .. tostring(provinceChanged
                and "clean old doorway but keep Trade Route open and reopen Goods Finder in selected province"
                or "grace expired with no tab change; treat as Escape, restore doorway, then close Trade Route")
        .. " | deliberateFrameDelay=true")

    goodsFinder.nativeClosePrecloseSignature =
        nativeCloseHelperRowsSnapshot(goodsFinder, "preclose")

    local removeResult, removeErr = safe(function()
        return removeTrackedTemporaryLoadGood(goodsFinder)
    end)
    goodsFinder.nativeClosePostremoveSignature =
        nativeCloseHelperRowsSnapshot(goodsFinder, "postremove")
    local routeRestored = goodsFinder.nativeCloseBaselineSignature
        == goodsFinder.nativeClosePostremoveSignature

    log("AUTOREMOVE VERIFY"
        .. " | callSuccess=" .. tostring(removeErr == nil)
        .. " | callResult=" .. tostring(removeResult)
        .. " | error=" .. tostring(removeErr or "")
        .. " | baselineEqualsPreclose="
            .. tostring(goodsFinder.nativeCloseBaselineSignature == goodsFinder.nativeClosePrecloseSignature)
        .. " | baselineEqualsPostremove=" .. tostring(routeRestored)
        .. " | next=" .. tostring(provinceChanged
            and "cross-province reopen"
            or "native close"))

    if provinceChanged then
        local targetIcon, targetLabel =
            crossProvinceTargetForProvince(
                currentMacroProvince
            )

        if targetIcon ~= nil then
            local oldRouteID =
                tonumber(goodsFinder.existingRouteCurrentId)
            local oldRouteName =
                tostring(goodsFinder.existingRouteCurrentName or "")
            local oldStationIndex =
                tonumber(goodsFinder.existingRouteHelperStationIndex)
            local oldStationName =
                tostring(goodsFinder.existingRouteHelperStationName or "")

            goodsFinder.autoReturnPending = false
            goodsFinder.autoReturnSawPopup = false
            goodsFinder.autoReturnTickCounter = 0
            goodsFinder.autoReturnCloseTickCounter = 0
            goodsFinder.autoReturnCloseGraceLogged = false
            goodsFinder.autoReturnLogged = false

            crossProvinceResetDoorwayTracking(
                goodsFinder
            )

            goodsFinder.crossProvinceTargetProvince =
                currentMacroProvince
            goodsFinder.crossProvinceTargetTab =
                currentMacroTab
            goodsFinder.crossProvinceReferenceLabel =
                targetLabel

            goodsFinder.sameDoorwayRouteID =
                oldRouteID
            goodsFinder.sameDoorwayRouteName =
                oldRouteName
            goodsFinder.sameDoorwayStationIndex =
                oldStationIndex
            goodsFinder.sameDoorwayStationName =
                oldStationName
            goodsFinder.sameDoorwayReopenPending = true
            goodsFinder.sameDoorwayReopenTick = 0

            log("CROSSPROVINCE SAME DOORWAY ARM"
                .. " | fromProvince="
                    .. tostring(popupProvince)
                .. " | toProvince="
                    .. tostring(currentMacroProvince)
                .. " | toTab="
                    .. tostring(currentMacroTab)
                .. " | targetLabel="
                    .. tostring(targetLabel)
                .. " | oldRouteID="
                    .. tostring(oldRouteID or "")
                .. " | oldRouteName="
                    .. tostring(oldRouteName)
                .. " | oldStationIndex="
                    .. tostring(oldStationIndex or "")
                .. " | oldStationName="
                    .. tostring(oldStationName)
                .. " | oldDoorwayCleanupSuccess="
                    .. tostring(removeErr == nil)
                .. " | oldRouteRestored="
                    .. tostring(routeRestored)
                .. " | nativeTradeRouteCloseSuppressed=true"
                .. " | strategy=reinvoke same AddGood doorway after native tab settles"
                .. " | hardcodedRoute=false"
                .. " | routeSwitch=false"
                .. " | stationSwitch=false")
            return
        end

        log("CROSSPROVINCE SWITCH UNSUPPORTED"
            .. " | toProvince="
                .. tostring(currentMacroProvince)
            .. " | fallback=normal native close")
    end

    log("NATIVECLOSE PREPARE"
        .. " | routeID=" .. tostring(goodsFinder.existingRouteCurrentId or "")
        .. " | routeName=" .. tostring(goodsFinder.existingRouteCurrentName or "")
        .. " | baselineEqualsPreclose="
            .. tostring(goodsFinder.nativeCloseBaselineSignature == goodsFinder.nativeClosePrecloseSignature)
        .. " | baselineEqualsPostremove=" .. tostring(routeRestored)
        .. " | method=ui.Scenes.TradeRoute.CloseTradeRouteScene(scene)"
        .. " | noFollowUpPopUI=true"
        .. " | expected=no Save changes prompt after native RemoveGood succeeds"
        .. " | if Save changes appears, choose No manually")

    local method = safe(function()
        return scene and scene.CloseTradeRouteScene
    end)
    goodsFinder.nativeCloseDispatchClock = safe(function()
        return os and os.clock and os.clock()
    end)
    goodsFinder.nativeCloseDispatchTime = safe(function()
        return os and os.time and os.time()
    end)

    local result, err = safe(function()
        if type(method) ~= "function" then
            error("CloseTradeRouteScene is unavailable")
        end
        return method(scene)
    end)

    log("NATIVECLOSE DISPATCH"
        .. " | success=" .. tostring(err == nil)
        .. " | returnType=" .. tostring(type(result))
        .. " | returnValue=" .. tostring(result)
        .. " | error=" .. tostring(err or "")
        .. " | nativeMethodCalls=1"
        .. " | popUICalls=0"
        .. " | noFallback=true")

    goodsFinder.autoReturnPending = false
    goodsFinder.autoReturnSawPopup = false
    goodsFinder.autoReturnTickCounter = 0
    goodsFinder.autoReturnCloseTickCounter = 0
    goodsFinder.autoReturnLogged = false
    goodsFinder.nativeCloseVerifyPending = err == nil
    goodsFinder.nativeCloseVerifyTickCounter = 0

    if err ~= nil then
        log("NATIVECLOSE COMPLETE"
            .. " | outcome=dispatch failed"
            .. " | no fallback invoked=true"
            .. " | next=close manually and upload logfile")
    end
end




local function sameDoorwayAutoReopenTick(goodsFinder)
    goodsFinder.sameDoorwayReopenTick =
        (tonumber(goodsFinder.sameDoorwayReopenTick) or 0) + 1

    local tickCount =
        tonumber(goodsFinder.sameDoorwayReopenTick) or 0

    -- Give the native Latium/Albion tab one full UI update after the popup
    -- closes and after the old tracked doorway row has been restored.
    if tickCount < 2 then
        return
    end

    local routeValid = safe(function()
        return TradeRoute
            and TradeRoute.UIEditRoute
            and TradeRoute.UIEditRoute:isValid()
    end) == true

    local popupVisible = safe(function()
        return ui
            and ui.Scenes
            and ui.Scenes.TradeRoute
            and ui.Scenes.TradeRoute.TradeGoodSelection
            and ui.Scenes.TradeRoute.TradeGoodSelection.PopupData
            and ui.Scenes.TradeRoute.TradeGoodSelection.PopupData.IsVisible
    end) == true

    local currentProvince, currentTab =
        crossProvinceReadMapState()

    log("SAMEDOORWAY REOPEN WAIT"
        .. " | tick=" .. tostring(tickCount)
        .. " | routeValid=" .. tostring(routeValid)
        .. " | popupVisible=" .. tostring(popupVisible)
        .. " | selectedProvince=" .. tostring(currentProvince)
        .. " | selectedTab=" .. tostring(currentTab)
        .. " | routeID="
            .. tostring(goodsFinder.sameDoorwayRouteID or "")
        .. " | routeName="
            .. tostring(goodsFinder.sameDoorwayRouteName or "")
        .. " | helperStationIndex="
            .. tostring(goodsFinder.sameDoorwayStationIndex or "")
        .. " | helperStationName="
            .. tostring(goodsFinder.sameDoorwayStationName or "")
        .. " | strategy=reinvoke same LoadGoods.AddGood doorway"
        .. " | hardcodedRoute=false"
        .. " | noRouteSwitch=true")

    if popupVisible == true then
        goodsFinder.sameDoorwayReopenPending = false
        goodsFinder.sameDoorwayReopenTick = 0
        return
    end

    if routeValid ~= true then
        if tickCount >= 8 then
            log("SAMEDOORWAY REOPEN ABORT"
                .. " | reason=route no longer valid"
                .. " | noFallbackRoute=true")
            goodsFinder.sameDoorwayReopenPending = false
            goodsFinder.sameDoorwayReopenTick = 0
        end
        return
    end

    -- Restore the exact same helper station that was used before the native
    -- province switch. Test 8 proved the user's successful manual reopen did
    -- not change route/station/focus; only PopupData.IsVisible changed.
    goodsFinder.existingRouteCurrentId =
        tonumber(goodsFinder.sameDoorwayRouteID)
    goodsFinder.existingRouteCurrentName =
        tostring(goodsFinder.sameDoorwayRouteName or "")
    goodsFinder.existingRouteHelperStationIndex =
        tonumber(goodsFinder.sameDoorwayStationIndex)
    goodsFinder.existingRouteHelperStationName =
        tostring(goodsFinder.sameDoorwayStationName or "")

    -- Do NOT apply StationProvinceIcon filtering here. The manual capture
    -- proved that the same Latium station doorway can reopen the popup while
    -- the MacroMap is on Albion. The popup's content follows the selected
    -- native province/tab, not the station icon of this doorway.
    goodsFinder.crossProvinceTargetStationIcon = nil

    local result, openErr = safe(function()
        return goodsFinder:OpenRememberedLoadGoodsPopup()
    end)

    log("SAMEDOORWAY REOPEN DISPATCH"
        .. " | tick=" .. tostring(tickCount)
        .. " | selectedProvince=" .. tostring(currentProvince)
        .. " | selectedTab=" .. tostring(currentTab)
        .. " | routeID="
            .. tostring(goodsFinder.sameDoorwayRouteID or "")
        .. " | routeName="
            .. tostring(goodsFinder.sameDoorwayRouteName or "")
        .. " | helperStationIndex="
            .. tostring(goodsFinder.sameDoorwayStationIndex or "")
        .. " | helperStationName="
            .. tostring(goodsFinder.sameDoorwayStationName or "")
        .. " | success="
            .. tostring(openErr == nil and result == true)
        .. " | result=" .. tostring(result)
        .. " | error=" .. tostring(openErr or "")
        .. " | routeSwitch=false"
        .. " | stationSwitch=false"
        .. " | expected=native goods popup reopens for selected MacroMap province")

    goodsFinder.sameDoorwayReopenPending = false
    goodsFinder.sameDoorwayReopenTick = 0
end


function GoodsFinder:Tick()
    if self.sameDoorwayReopenPending ~= true
        and self.existingRouteScanPending ~= true
        and self.nativeClickProbePending ~= true
        and self.autoShipListWaitPending ~= true
        and self.autoShipSelectionPending ~= true
        and self.autoGoodsHoverPending ~= true
        and self.autoReturnPending ~= true
        and self.nativeCloseVerifyPending ~= true
        and self.failureCleanupPending ~= true then
        return
    end

    if self.sameDoorwayReopenPending == true then
        sameDoorwayAutoReopenTick(self)
        return
    end

    if self.existingRouteScanPending == true then
        existingRouteScanTick(self)
        return
    end

    if self.failureCleanupPending == true then
        failureCleanupTick(self)
        return
    end

    if self.autoReturnPending == true then
        autoReturnAfterPopupTick(self)
        return
    end

    if self.nativeCloseVerifyPending == true then
        nativeCloseVerifyTick(self)
        return
    end

    if self.nativeClickProbePending == true then
        nativeClickProbeTick(self)
        return
    end

    local routeValid = safe(function()
        return TradeRoute
            and TradeRoute.UIEditRoute
            and TradeRoute.UIEditRoute:isValid()
    end)

    if routeValid ~= true then
        log("AUTOTICK CANCEL"
            .. " | reason=temporary route editor is no longer valid"
            .. " | shipListWaitPending=" .. tostring(self.autoShipListWaitPending == true)
            .. " | shipPending=" .. tostring(self.autoShipSelectionPending == true)
            .. " | goodsHoverPending=" .. tostring(self.autoGoodsHoverPending == true)
            .. " | pendingShipName=" .. tostring(self.autoShipSelectionName or ""))

        self.autoShipListWaitPending = false
        self.autoShipListWaitTickCounter = 0
        self.autoShipListWaitLogged = false
        self.autoShipSelectionPending = false
        self.autoShipTickCounter = 0
        self.autoShipTickLogged = false
        self.autoGoodsHoverPending = false
        self.autoGoodsHoverTickCounter = 0
        self.autoGoodsHoverLogged = false
        return
    end

    local scene = safe(function()
        return ui and ui.Scenes and ui.Scenes.TradeRoute
    end)
    local popupVisible = safe(function()
        return scene
            and scene.TradeGoodSelection
            and scene.TradeGoodSelection.PopupData
            and scene.TradeGoodSelection.PopupData.IsVisible
    end)

    -- Phase 0: ShipSelectBtn_Pressed can return before the selector popup and
    -- its PhoenixArray are populated. Wait here instead of requiring another
    -- shortcut press.
    if self.autoShipListWaitPending == true then
        self.autoShipListWaitTickCounter =
            (tonumber(self.autoShipListWaitTickCounter) or 0) + 1
        local waitTickCount = self.autoShipListWaitTickCounter

        local shipSelect = safe(function()
            return scene and scene.TradeShipSelect
        end)
        local shipList = safe(function()
            return shipSelect and shipSelect.ShipList
        end)
        local shipCount, shipCountErr = autoShipArraySize(
            shipList,
            "PhoenixArray<halo::CTradeShipData>"
        )
        local selectedCount, selectedErr = autoShipSelectedCount(shipSelect)
        local selectorVisible = safe(function()
            return shipSelect and shipSelect.IsPopupVisible
        end)

        if self.autoShipListWaitLogged ~= true then
            self.autoShipListWaitLogged = true
            log("AUTOSHIP LIST WAIT START"
                .. " | tickCount=" .. tostring(waitTickCount)
                .. " | popupVisible=" .. tostring(selectorVisible)
                .. " | shipCount=" .. tostring(shipCount)
                .. " | shipCountError=" .. tostring(shipCountErr or "")
                .. " | selectedCount=" .. tostring(selectedCount)
                .. " | selectedError=" .. tostring(selectedErr or ""))
        end

        if (tonumber(shipCount) or 0) > 0
            or (tonumber(selectedCount) or 0) > 0 then
            self.autoShipListWaitPending = false
            self.autoShipListWaitTickCounter = 0
            self.autoShipListWaitLogged = false

            log("AUTOSHIP LIST READY"
                .. " | tickCount=" .. tostring(waitTickCount)
                .. " | popupVisible=" .. tostring(selectorVisible)
                .. " | shipCount=" .. tostring(shipCount)
                .. " | selectedCount=" .. tostring(selectedCount)
                .. " | action=ProbeAutoSelectTemporaryShip")

            local result, resultErr = safe(function()
                return self:ProbeAutoSelectTemporaryShip()
            end)

            log("AUTOSHIP LIST HANDOFF"
                .. " | success=" .. tostring(resultErr == nil)
                .. " | result=" .. tostring(result)
                .. " | error=" .. tostring(resultErr or "")
                .. " | selectionPending=" .. tostring(
                    self.autoShipSelectionPending == true
                ))

            if resultErr == nil
                and result == true
                and self.autoShipSelectionPending ~= true then
                self.autoShipSelectionPending = true
                self.autoShipSelectionName =
                    tostring(self.autoShipSelectionName or "selected ship")
                self.autoShipTickCounter = 0
                self.autoShipTickLogged = false

                log("AUTOSHIP LIST VERIFY"
                    .. " | reason=ship was already selected or route row was immediately available"
                    .. " | action=wait for remembered Load/Unload row")
            end
            return
        end

        if waitTickCount >= 60 then
            log("AUTOSHIP LIST WAIT TIMEOUT"
                .. " | tickCount=" .. tostring(waitTickCount)
                .. " | popupVisible=" .. tostring(selectorVisible)
                .. " | shipCount=" .. tostring(shipCount)
                .. " | shipCountError=" .. tostring(shipCountErr or "")
                .. " | selectedCount=" .. tostring(selectedCount)
                .. " | selectedError=" .. tostring(selectedErr or "")
                .. " | fallback=leave selector open and upload logfile")

            self.autoShipListWaitPending = false
            self.autoShipListWaitTickCounter = 0
            self.autoShipListWaitLogged = false
        end
        return
    end

    -- Phase 2 has priority. AddGood has already been dispatched and the popup
    -- may become visible one or more UI frames later.
    if self.autoGoodsHoverPending == true then
        self.autoGoodsHoverTickCounter =
            (tonumber(self.autoGoodsHoverTickCounter) or 0) + 1
        local hoverTickCount = self.autoGoodsHoverTickCounter

        if self.autoGoodsHoverLogged ~= true then
            self.autoGoodsHoverLogged = true
            log("AUTOHOVER WAIT"
                .. " | tickCount=" .. tostring(hoverTickCount)
                .. " | popupVisible=" .. tostring(popupVisible)
                .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
                .. " | productName=" .. tostring(self.lastProductName or "")
                .. " | warehouseAreaID=" .. tostring(self.lastWarehouseAreaId or 0)
                .. " | warehouseAreaName=" .. tostring(self.lastWarehouseAreaName or ""))
        end

        if popupVisible == true then
            local rememberedGuid = tonumber(self.lastProductGuid) or 0
            local hoverResult = true
            local hoverErr = nil

            if rememberedGuid > 0 then
                log("AUTOHOVER READY"
                    .. " | tickCount=" .. tostring(hoverTickCount)
                    .. " | popupVisible=true"
                    .. " | preselection=true"
                    .. " | action=ForceRememberedGoodHover")

                hoverResult, hoverErr = safe(function()
                    return self:ForceRememberedGoodHover()
                end)

                log("AUTOHOVER COMPLETE"
                    .. " | success=" .. tostring(hoverErr == nil and hoverResult == true)
                    .. " | result=" .. tostring(hoverResult)
                    .. " | error=" .. tostring(hoverErr or "")
                    .. " | productGUID=" .. tostring(self.lastProductGuid or 0)
                    .. " | productName=" .. tostring(self.lastProductName or ""))
            else
                log("WAREHOUSEMODE POPUP READY"
                    .. " | tickCount=" .. tostring(hoverTickCount)
                    .. " | popupVisible=true"
                    .. " | preselection=false"
                    .. " | behavior=user may hover any product; warehouse is not required")
            end

            self.autoGoodsHoverPending = false
            self.autoGoodsHoverTickCounter = 0
            self.autoGoodsHoverLogged = false

            if hoverErr == nil and hoverResult == true then
                self.autoReturnPending = true
                self.autoReturnSawPopup = true
                self.autoReturnTickCounter = 0
                self.autoReturnCloseTickCounter = 0
                self.autoReturnLogged = false

                self.nativeCloseBaselineSignature =
                    nativeCloseHelperRowsSnapshot(self, "baseline")
                self.nativeClosePrecloseSignature = nil

                log("AUTORETURN MONITOR START"
                    .. " | popupVisible=true"
                    .. " | routeValid=true"
                    .. " | behavior=one Escape closes popup; Goods Finder calls RemoveGood once on the tracked originally-empty doorway row, then invokes native CloseTradeRouteScene exactly once"
                    .. " | noFollowUpPopUI=true")
            end
            return
        end

        -- Tick frequency varies with game/UI state. This gives the popup ample
        -- time to appear while retaining the proven manual shortcut fallback.
        if hoverTickCount >= 60 then
            log("AUTOHOVER TIMEOUT"
                .. " | tickCount=" .. tostring(hoverTickCount)
                .. " | popupVisible=" .. tostring(popupVisible)
                .. " | fallback=press Ctrl+Alt+G once to reapply the remembered-product hover")

            self.autoGoodsHoverPending = false
            self.autoGoodsHoverTickCounter = 0
            self.autoGoodsHoverLogged = false
        end
        return
    end

    -- Phase 1: wait for Anno to commit the automatic ship selection to the
    -- route data, then dispatch the already proven Load Good popup workflow.
    self.autoShipTickCounter = (tonumber(self.autoShipTickCounter) or 0) + 1
    local tickCount = self.autoShipTickCounter

    if tickCount < 2 then
        return
    end

    local loadRowCount, rememberedStationIndex, loadRowErr =
        assistedRememberedLoadRowCount(self)

    if self.autoShipTickLogged ~= true then
        self.autoShipTickLogged = true
        log("AUTOTICK START"
            .. " | pendingShipName=" .. tostring(self.autoShipSelectionName or "")
            .. " | tickCount=" .. tostring(tickCount)
            .. " | rememberedStationIndex=" .. tostring(rememberedStationIndex)
            .. " | rememberedLoadRowCount=" .. tostring(loadRowCount)
            .. " | error=" .. tostring(loadRowErr or ""))
    end

    if (tonumber(loadRowCount) or 0) > 0 then
        local pendingShipName = tostring(self.autoShipSelectionName or "")
        self.autoShipSelectionPending = false
        self.autoShipTickCounter = 0
        self.autoShipTickLogged = false

        log("AUTOTICK READY"
            .. " | pendingShipName=" .. pendingShipName
            .. " | rememberedStationIndex=" .. tostring(rememberedStationIndex)
            .. " | rememberedLoadRowCount=" .. tostring(loadRowCount)
            .. " | action=CaptureOpenAndCreateRoute")

        local result, resultErr = safe(function()
            return self:CaptureOpenAndCreateRoute()
        end)

        log("AUTOTICK DISPATCH COMPLETE"
            .. " | success=" .. tostring(resultErr == nil and result == true)
            .. " | result=" .. tostring(result)
            .. " | error=" .. tostring(resultErr or "")
            .. " | pendingShipName=" .. pendingShipName
            .. " | delayedHoverPending=" .. tostring(self.autoGoodsHoverPending == true))
        return
    end

    if tickCount >= 60 then
        log("AUTOTICK TIMEOUT"
            .. " | tickCount=" .. tostring(tickCount)
            .. " | pendingShipName=" .. tostring(self.autoShipSelectionName or "")
            .. " | rememberedStationIndex=" .. tostring(rememberedStationIndex)
            .. " | rememberedLoadRowCount=" .. tostring(loadRowCount)
            .. " | error=" .. tostring(loadRowErr or "")
            .. " | fallback=press Ctrl+Alt+G once")

        self.autoShipSelectionPending = false
        self.autoShipTickCounter = 0
        self.autoShipTickLogged = false
    end
end

return GoodsFinder
