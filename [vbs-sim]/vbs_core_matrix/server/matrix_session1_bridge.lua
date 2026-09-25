-- =====================================================================
-- PROJECT MATRIX — SESSION 1 — PROXY ASSET BRIDGE
--
-- ★ LEGACY CORE KORUNUR (kitchen.lua, bureau.lua, bots, forensic,
--   ballistic). Yalnızca PARALEL bridge katmanı. Interceptor'lar pcall
--   sarmallama ile legacy gövdelerine DOKUNMADAN uygulanır.
--
-- ★ ZERO-RNG: tüm ID/hesap os.time + deterministik checksum ile.
--   math.random YASAK.
-- =====================================================================

Matrix        = Matrix        or {}
Matrix.Bridge = Matrix.Bridge or {}

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor                              = math.floor
local os_time                                 = os.time
local json                                    = json
local TriggerClientEvent                      = TriggerClientEvent
local RegisterNetEvent                        = RegisterNetEvent
local RegisterCommand                         = RegisterCommand

-- ---------------------------------------------------------------------
-- CELL VARIANT SPECIFICATION (Strict Determinism — SIFIR RNG)
-- ---------------------------------------------------------------------
local CELL_VARIANTS = {
    small  = { cost = 25000,  grid_load = 1.0, odor_mult = 1.0, daily_maintenance = 500  },
    medium = { cost = 60000,  grid_load = 2.2, odor_mult = 1.8, daily_maintenance = 1200 },
    large  = { cost = 130000, grid_load = 4.5, odor_mult = 3.0, daily_maintenance = 2800 },
}

local BUREAU_AUDIT_INTERVAL_SECONDS = 24 * 60 * 60
local BUREAU_AUDIT_TICK_MS          = 60 * 1000
local MAX_HOUSE_LIMIT_HARD_CAP      = 3
local COUNSELOR_BRIBE_CASH_EXACT    = 50000
local COUNSELOR_BRIBE_TARGET_LIMIT  = 3

-- =====================================================================
-- [A] ACTIVE STATE CACHING
-- =====================================================================
local LocalCache   = { TrapHouses = {} }
local CitizenIndex = {}

local function ParseCoords(rawJson)
    if type(rawJson) ~= 'string' or rawJson == '' then return nil end
    local ok, decoded = pcall(json.decode, rawJson)
    if not ok or type(decoded) ~= 'table' then return nil end
    local x, y, z = tonumber(decoded.x), tonumber(decoded.y), tonumber(decoded.z)
    if not x or not y or not z then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    return vector3(x, y, z)
end

local function EncodeCoords(vec)
    if type(vec) ~= 'vector3' and type(vec) ~= 'vector4' then return nil end
    if vec.x ~= vec.x or vec.y ~= vec.y or vec.z ~= vec.z then return nil end
    return json.encode({ x = vec.x, y = vec.y, z = vec.z })
end

local function CoordsHash(vec, epoch)
    local raw
    if vec then
        raw = ('%.3f#%.3f#%.3f#%d'):format(vec.x, vec.y, vec.z, epoch or os_time())
    else
        raw = ('NULL#%d'):format(epoch or os_time())
    end
    local sum = 0
    for i = 1, #raw do
        sum = (sum * 31 + raw:byte(i)) % 0x7FFFFFFF
    end
    return ('%08X'):format(sum)
end

local function LoadCellIntoCache(row)
    if type(row) ~= 'table' or not row.id then return end
    local cell = {
        id               = tonumber(row.id),
        citizenid        = row.citizenid,
        house_name       = row.house_name,
        coords           = ParseCoords(row.coords),
        house_size       = row.house_size or 'small',
        max_house_limit  = tonumber(row.max_house_limit) or 1,
        last_tax_payment = tonumber(row.last_tax_payment) or os_time(),
        is_sealed        = tonumber(row.is_sealed) or 0,
    }
    LocalCache.TrapHouses[cell.id] = cell
    CitizenIndex[cell.citizenid] = CitizenIndex[cell.citizenid] or {}
    CitizenIndex[cell.citizenid][#CitizenIndex[cell.citizenid] + 1] = cell.id
end

local function UnloadCellFromCache(proxyId)
    local cell = LocalCache.TrapHouses[proxyId]
    if not cell then return end
    LocalCache.TrapHouses[proxyId] = nil
    local list = CitizenIndex[cell.citizenid]
    if list then
        for i = #list, 1, -1 do
            if list[i] == proxyId then table.remove(list, i); break end
        end
    end
end

local function HydrateCacheForCitizen(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    local ok, rows = pcall(function()
        return MySQL.query.await(
            'SELECT * FROM `matrix_traphouses` WHERE `citizenid` = ?',
            { citizenid })
    end)
    if not ok or type(rows) ~= 'table' then return end
    for _, proxyId in ipairs(CitizenIndex[citizenid] or {}) do
        UnloadCellFromCache(proxyId)
    end
    for _, row in ipairs(rows) do
        LoadCellIntoCache(row)
    end
    Matrix.Log('SESSION1', '[CACHE] %s -> %d proxy cell hydrate.', citizenid, #rows)
end

local function HydrateCacheAll()
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM `matrix_traphouses`')
    end)
    if not ok or type(rows) ~= 'table' then
        Matrix.Log('SESSION1', '[CACHE] Full hydrate FAILED — DB unreachable.')
        return
    end
    LocalCache.TrapHouses = {}
    CitizenIndex = {}
    for _, row in ipairs(rows) do LoadCellIntoCache(row) end
    Matrix.Log('SESSION1', '[CACHE] Full hydrate: %d proxy cell.', #rows)
end

-- =====================================================================
-- [B] ID SPACE ISOLATION — Proxy stash namespace
-- =====================================================================
local function ProxyStashId(proxyId)
    return ('matrix_proxy_stash_%d'):format(tonumber(proxyId) or 0)
end

local function EnsureProxyStash(proxyId)
    local stashId = ProxyStashId(proxyId)
    local cell = LocalCache.TrapHouses[proxyId]
    local label = cell and cell.house_name or ('Proxy Cell #' .. tostring(proxyId))
    pcall(function()
        exports['ox_inventory']:RegisterStash(stashId, label, 100, 200000)
    end)
    return stashId
end

-- =====================================================================
-- [C] INTERCEPTOR GUARD CLAUSE API
-- =====================================================================
function Matrix.Bridge.IsCellOperational(houseId)
    houseId = tonumber(houseId)
    if not houseId then return true end
    local cell = LocalCache.TrapHouses[houseId]
    if not cell then return true end
    return cell.is_sealed ~= 1
end

exports('IsCellOperational', function(houseId)
    return Matrix.Bridge.IsCellOperational(houseId)
end)

local function InstallInterceptorWrappers()
    local wrapped = 0

    if Matrix.Kitchen and type(Matrix.Kitchen.ProcessCook) == 'function' then
        local orig = Matrix.Kitchen.ProcessCook
        Matrix.Kitchen.ProcessCook = function(actorRef, trapHouseId, ...)
            if not Matrix.Bridge.IsCellOperational(trapHouseId) then
                Matrix.Log('SESSION1', '[INTERCEPT] Kitchen.ProcessCook ABORT (sealed) trap=%s',
                    tostring(trapHouseId))
                return nil
            end
            return orig(actorRef, trapHouseId, ...)
        end
        wrapped = wrapped + 1
    end

    if Matrix.Kitchen and type(Matrix.Kitchen.PackageBatch) == 'function' then
        local orig = Matrix.Kitchen.PackageBatch
        Matrix.Kitchen.PackageBatch = function(trapHouseId, ...)
            if not Matrix.Bridge.IsCellOperational(trapHouseId) then
                return nil, 'cell_sealed'
            end
            return orig(trapHouseId, ...)
        end
        wrapped = wrapped + 1
    end

    if Matrix.Bureau and type(Matrix.Bureau.AdvanceDecryption) == 'function' then
        local orig = Matrix.Bureau.AdvanceDecryption
        Matrix.Bureau.AdvanceDecryption = function(trapHouseId, amount)
            if not Matrix.Bridge.IsCellOperational(trapHouseId) then return end
            return orig(trapHouseId, amount)
        end
        wrapped = wrapped + 1
    end

    if Matrix.Bureau and type(Matrix.Bureau.LogPatternEvent) == 'function' then
        local orig = Matrix.Bureau.LogPatternEvent
        Matrix.Bureau.LogPatternEvent = function(trapHouseId, ...)
            if not Matrix.Bridge.IsCellOperational(trapHouseId) then return false end
            return orig(trapHouseId, ...)
        end
        wrapped = wrapped + 1
    end

    if Matrix.Bureau and type(Matrix.Bureau.TriggerPropaganda) == 'function' then
        local orig = Matrix.Bureau.TriggerPropaganda
        Matrix.Bureau.TriggerPropaganda = function(trapHouseId, ...)
            if not Matrix.Bridge.IsCellOperational(trapHouseId) then return 0.0, 0.0 end
            return orig(trapHouseId, ...)
        end
        wrapped = wrapped + 1
    end

    if Matrix.Bureau and type(Matrix.Bureau.RecordRadioBreach) == 'function' then
        local orig = Matrix.Bureau.RecordRadioBreach
        Matrix.Bureau.RecordRadioBreach = function(trapHouseId, ...)
            if not Matrix.Bridge.IsCellOperational(trapHouseId) then return end
            return orig(trapHouseId, ...)
        end
        wrapped = wrapped + 1
    end

    if Matrix.Bureau and type(Matrix.Bureau.RecordPurityIntercepted) == 'function' then
        local orig = Matrix.Bureau.RecordPurityIntercepted
        Matrix.Bureau.RecordPurityIntercepted = function(trapHouseId, ...)
            if not Matrix.Bridge.IsCellOperational(trapHouseId) then return end
            return orig(trapHouseId, ...)
        end
        wrapped = wrapped + 1
    end

    Matrix.Log('SESSION1', '[INTERCEPT] %d legacy processing loop guard altina alindi.', wrapped)
end

-- =====================================================================
-- [D] REAL-TIME AUDITING ENGINE (os.time)
-- =====================================================================
local function ApplyBankDeduction(citizenid, src, amount)
    if amount <= 0 then return false end
    if type(src) == 'number' and src > 0 then
        local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
        if ok and player and player.PlayerData then
            local bank = (player.PlayerData.money and player.PlayerData.money.bank) or 0
            if bank < amount then return false end
            local remOk, remRes = pcall(function()
                return player.Functions.RemoveMoney('bank', amount, 'session1-fincen-audit')
            end)
            return remOk and remRes == true
        end
    end
    local updOk, affected = pcall(function()
        return MySQL.update.await(
            "UPDATE `players` SET `money` = JSON_SET(`money`, '$.bank', " ..
            "GREATEST(0, COALESCE(JSON_EXTRACT(`money`, '$.bank'), 0) - ?)) " ..
            "WHERE `citizenid` = ? AND COALESCE(JSON_EXTRACT(`money`, '$.bank'), 0) >= ?",
            { amount, citizenid, amount })
    end)
    return updOk and type(affected) == 'number' and affected > 0
end

local function SealCell(proxyId, reason)
    local cell = LocalCache.TrapHouses[proxyId]
    if not cell then return end
    cell.is_sealed = 1
    pcall(function()
        MySQL.prepare(
            'UPDATE `matrix_traphouses` SET `is_sealed` = 1 WHERE `id` = ?',
            { proxyId })
    end)
    Matrix.Log('SESSION1',
        '[FINCEN SEAL] Proxy #%d (%s) — %s. Facility locked down, production aborted.',
        proxyId, tostring(cell.citizenid), tostring(reason))
end

local function AuditCell(proxyId, src)
    local cell = LocalCache.TrapHouses[proxyId]
    if not cell or cell.is_sealed == 1 then return end

    local variant = CELL_VARIANTS[cell.house_size] or CELL_VARIANTS.small
    local now = os_time()
    local elapsed = now - (cell.last_tax_payment or now)
    if elapsed < BUREAU_AUDIT_INTERVAL_SECONDS then return end

    local daysElapsed = math_floor(elapsed / BUREAU_AUDIT_INTERVAL_SECONDS)
    if daysElapsed < 1 then return end

    local owed = variant.daily_maintenance * daysElapsed
    local charged = ApplyBankDeduction(cell.citizenid, src, owed)

    if charged then
        cell.last_tax_payment = cell.last_tax_payment + (daysElapsed * BUREAU_AUDIT_INTERVAL_SECONDS)
        pcall(function()
            MySQL.prepare(
                'UPDATE `matrix_traphouses` SET `last_tax_payment` = ? WHERE `id` = ?',
                { cell.last_tax_payment, proxyId })
        end)
        Matrix.Log('SESSION1',
            '[AUDIT OK] Proxy #%d — $%d collected (%d day cycle).',
            proxyId, owed, daysElapsed)
    else
        SealCell(proxyId, 'insufficient_balance')
        if type(src) == 'number' and src > 0 then
            TriggerClientEvent('matrix:client:actionNotify', src, false,
                'Asset frozen by FinCEN audit; facility locked down, production aborted.')
        end
    end
end

local function ProcessRetroactiveTaxes(src, citizenid)
    local list = CitizenIndex[citizenid]
    if not list or #list == 0 then
        HydrateCacheForCitizen(citizenid)
        list = CitizenIndex[citizenid] or {}
    end
    for _, proxyId in ipairs(list) do
        AuditCell(proxyId, src)
    end
end

-- =====================================================================
-- [E] ANTI-EXPLOIT QUANTUM ENFORCEMENT
-- =====================================================================
local function CountActiveCellsForCitizen(citizenid)
    local n = 0
    for _, proxyId in ipairs(CitizenIndex[citizenid] or {}) do
        if LocalCache.TrapHouses[proxyId] then n = n + 1 end
    end
    return n
end

local function LogExploitAttempt(citizenid, attemptedSize, activeCount, maxLimit, coords)
    pcall(function()
        MySQL.insert.await(
            'INSERT INTO `matrix_exploit_log` ' ..
            '(`citizenid`, `attempted_size`, `active_count`, `max_limit`, `coords_hash`) ' ..
            'VALUES (?, ?, ?, ?, ?)',
            { citizenid, attemptedSize, activeCount, maxLimit, CoordsHash(coords, os_time()) })
    end)
    Matrix.Log('SESSION1',
        '[EXPLOIT FLAG] %s attempted=%s active=%d/%d — secure log written.',
        tostring(citizenid), tostring(attemptedSize), activeCount, maxLimit)
end

-- =====================================================================
-- [F] PURCHASE FLOW
-- =====================================================================
RegisterNetEvent('matrix:server:proxy:purchaseCell', function(size, coordsPayload)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    if type(size) ~= 'string' or not CELL_VARIANTS[size] then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Security handshake failed. Line disconnected.')
        return
    end

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Security handshake failed. Line disconnected.')
        return
    end

    if not CitizenIndex[citizenid] then HydrateCacheForCitizen(citizenid) end
    local active = CountActiveCellsForCitizen(citizenid)

    local maxLimit = 1
    for _, pid in ipairs(CitizenIndex[citizenid] or {}) do
        local c = LocalCache.TrapHouses[pid]
        if c and c.max_house_limit and c.max_house_limit > maxLimit then
            maxLimit = c.max_house_limit
        end
    end

    if active >= maxLimit then
        LogExploitAttempt(citizenid, size, active, maxLimit, nil)
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Cell operational limit reached. Proxy asset registration required.')
        return
    end

    local cellCoords
    if type(coordsPayload) == 'table' then
        local x, y, z = tonumber(coordsPayload.x), tonumber(coordsPayload.y), tonumber(coordsPayload.z)
        if x and y and z and x == x and y == y and z == z then
            cellCoords = vector3(x, y, z)
        end
    end
    if not cellCoords then
        cellCoords = vector3(142.12, -1024.45, 29.3)
    end

    local variant = CELL_VARIANTS[size]

    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Security handshake failed. Line disconnected.')
        return
    end

    local bank = (player.PlayerData.money and player.PlayerData.money.bank) or 0
    if bank < variant.cost then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            ('Retainment fund insufficient. Required: $%d.'):format(variant.cost))
        return
    end

    local chargeOk, chargeRes = pcall(function()
        return player.Functions.RemoveMoney('bank', variant.cost, 'session1-proxy-purchase')
    end)
    if not chargeOk or chargeRes ~= true then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Security handshake failed. Line disconnected.')
        return
    end

    local houseName = ('Proxy Cell %s'):format(size:upper())
    local coordsJson = EncodeCoords(cellCoords)
    local nowEpoch = os_time()

    local insertOk, insertId = pcall(function()
        return MySQL.insert.await([[
            INSERT INTO `matrix_traphouses`
                (`citizenid`, `house_name`, `coords`, `house_size`,
                 `max_house_limit`, `last_tax_payment`, `is_sealed`)
            VALUES (?, ?, ?, ?, ?, ?, 0)
        ]], { citizenid, houseName, coordsJson, size, maxLimit, nowEpoch })
    end)

    if not insertOk or type(insertId) ~= 'number' then
        pcall(function()
            player.Functions.AddMoney('bank', variant.cost, 'session1-proxy-refund')
        end)
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Asset registration rejected by database shield.')
        return
    end

    LoadCellIntoCache({
        id               = insertId,
        citizenid        = citizenid,
        house_name       = houseName,
        coords           = coordsJson,
        house_size       = size,
        max_house_limit  = maxLimit,
        last_tax_payment = nowEpoch,
        is_sealed        = 0,
    })
    EnsureProxyStash(insertId)

    TriggerClientEvent('matrix:client:actionNotify', src, true,
        ('Proxy asset registered. Grid load: %.1f, Odor: %.1f.'):format(variant.grid_load, variant.odor_mult))
    Matrix.Log('SESSION1',
        '[PURCHASE] %s -> proxy #%d (size=%s, cost=$%d)',
        citizenid, insertId, size, variant.cost)
end)

-- =====================================================================
-- [G] CORRUPT COUNSELOR ARBITRAGE
-- =====================================================================
RegisterNetEvent('matrix:server:proxy:counselorBribe', function()
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end

    local state = Matrix.GetOrCreatePlayerState(src)
    local citizenid = state and state.citizenid
    if not citizenid then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Security handshake failed. Line disconnected.')
        return
    end

    local ok, player = pcall(function() return Matrix.QBX:GetPlayer(src) end)
    if not ok or not player or not player.PlayerData then return end

    local cash = (player.PlayerData.money and player.PlayerData.money.cash) or 0
    if cash < COUNSELOR_BRIBE_CASH_EXACT then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Retainment fund shortfall. Counselor requires exact $50,000 physical cash.')
        return
    end

    local removeOk, removeRes = pcall(function()
        return player.Functions.RemoveMoney('cash', COUNSELOR_BRIBE_CASH_EXACT, 'session1-counselor-retainer')
    end)
    if not removeOk or removeRes ~= true then
        TriggerClientEvent('matrix:client:actionNotify', src, false,
            'Security handshake failed. Line disconnected.')
        return
    end

    local updOk, affected = pcall(function()
        return MySQL.update.await([[
            UPDATE `matrix_traphouses`
            SET `max_house_limit` = ?
            WHERE `citizenid` = ? AND `max_house_limit` < ?
        ]], { COUNSELOR_BRIBE_TARGET_LIMIT, citizenid, COUNSELOR_BRIBE_TARGET_LIMIT })
    end)

    if not CitizenIndex[citizenid] then HydrateCacheForCitizen(citizenid) end
    for _, pid in ipairs(CitizenIndex[citizenid] or {}) do
        local c = LocalCache.TrapHouses[pid]
        if c then c.max_house_limit = COUNSELOR_BRIBE_TARGET_LIMIT end
    end

    TriggerClientEvent('matrix:client:actionNotify', src, true,
        'Counselor cleared the retainment fund. Legal umbrella expanded.')
    Matrix.Log('SESSION1',
        '[COUNSELOR] %s -> limit raised to %d (affected=%s)',
        citizenid, COUNSELOR_BRIBE_TARGET_LIMIT, tostring(affected))
end)

-- =====================================================================
-- [H] LIFECYCLE
-- =====================================================================
AddEventHandler('onResourceStart', function(resName)
    if resName ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(2000)
        HydrateCacheAll()
        InstallInterceptorWrappers()

        while true do
            Wait(BUREAU_AUDIT_TICK_MS)
            for proxyId, cell in pairs(LocalCache.TrapHouses) do
                if cell.is_sealed ~= 1 then
                    local src
                    for s, cid in pairs(Matrix.PlayerSourceIndex or {}) do
                        if cid == cell.citizenid then src = s; break end
                    end
                    AuditCell(proxyId, src)
                end
            end
        end
    end)
end)

AddEventHandler('qbx_core:server:onPlayerLoaded', function(payload)
    local src
    if type(payload) == 'table' then
        src = tonumber(payload.source or payload.src or payload[1])
    else
        src = tonumber(payload)
    end
    if not src or src <= 0 then return end
    CreateThread(function()
        Wait(2500)
        local state = Matrix.GetOrCreatePlayerState(src)
        local citizenid = state and state.citizenid
        if not citizenid then return end
        HydrateCacheForCitizen(citizenid)
        ProcessRetroactiveTaxes(src, citizenid)
    end)
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if type(player) ~= 'table' or not player.PlayerData then return end
    local src = tonumber(player.PlayerData.source)
    if not src or src <= 0 then return end
    CreateThread(function()
        Wait(2500)
        local state = Matrix.GetOrCreatePlayerState(src)
        local citizenid = state and state.citizenid
        if not citizenid then return end
        HydrateCacheForCitizen(citizenid)
        ProcessRetroactiveTaxes(src, citizenid)
    end)
end)

-- =====================================================================
-- [I] READ-ONLY VARIANTS EXPORT
-- =====================================================================
lib.callback.register('matrix:callback:session1:getVariants', function(src)
    return CELL_VARIANTS
end)

-- =====================================================================
-- [J] OPERATOR DIAGNOSTICS
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[SESSION1]', msg } })
    else
        print(('[MATRIX:SESSION1] %s'):format(msg))
    end
end

RegisterCommand('proxy_audit', function(src)
    local total, sealed = 0, 0
    for _, cell in pairs(LocalCache.TrapHouses) do
        total = total + 1
        if cell.is_sealed == 1 then sealed = sealed + 1 end
    end
    Reply(src, ('=== PROXY ASSET REGISTRY === Total:%d  Active:%d  Sealed:%d')
        :format(total, total - sealed, sealed))
    for _, cell in pairs(LocalCache.TrapHouses) do
        local v = CELL_VARIANTS[cell.house_size] or {}
        Reply(src, ('#%d %s [%s] owner=%s limit=%d grid=%.1f odor=%.1f sealed=%d')
            :format(cell.id, cell.house_name, cell.house_size, cell.citizenid,
                    cell.max_house_limit, v.grid_load or 0.0,
                    v.odor_mult or 0.0, cell.is_sealed))
    end
end, false)

RegisterCommand('proxy_unseal', function(src, args)
    local proxyId = tonumber(args[1])
    if not proxyId then Reply(src, 'Usage: /proxy_unseal [proxyId]'); return end
    local cell = LocalCache.TrapHouses[proxyId]
    if not cell then Reply(src, 'Proxy not found.'); return end
    cell.is_sealed = 0
    cell.last_tax_payment = os_time()
    pcall(function()
        MySQL.prepare(
            'UPDATE `matrix_traphouses` SET `is_sealed` = 0, `last_tax_payment` = ? WHERE `id` = ?',
            { cell.last_tax_payment, proxyId })
    end)
    Reply(src, ('Proxy #%d operational status restored.'):format(proxyId))
end, false)

Matrix.Log('SESSION1', 'Proxy Asset Bridge armed — 0-RNG, interceptor pcall-wrapped, cache-resident.')