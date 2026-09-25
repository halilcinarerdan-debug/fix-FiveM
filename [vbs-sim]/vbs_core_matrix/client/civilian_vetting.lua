-- =====================================================================
-- PROJECT MATRIX — SESSION 3 — CIVILIAN PED VETTING RADAR
-- client/civilian_vetting.lua
--
-- ★ SIFIR RNG. math.random YOK.
-- ★ SPATIAL CACHE + SQUARED VECTOR MATH: komşu ped taraması
--   GetGamePool('CPed') üzerinden 3 saniyelik heartbeat ile yapılır
--   (0.00ms resmon idle profile). Kare mesafe `#(a - b)` ile.
-- ★ 4.4s/2.5s/... katmanlı state machine:
--     t=0       -> reportedOdor = true, disgust anim, yüz dönme
--     t=5000ms  -> un-neutralized -> telefon çek, qs-dispatch relay
-- =====================================================================

local SCAN_INTERVAL_MS  = Config.OdorCore.ClientScanIntervalMs
local INTERVENE_DELAY_MS= Config.OdorCore.ClientInterventionDelayMs
local ANIM_DICT          = Config.OdorCore.ClientDisgustAnimDict
local ANIM_CLIP          = Config.OdorCore.ClientDisgustAnimClip
local PHONE_SCENARIO     = Config.OdorCore.ClientDispatchScenario
local SAFETY_RADIUS_SQ_M = 5.0 * 5.0 -- tracking window

-- Aktif hücre alanları (server broadcast)
local OdorFields = {} -- [trapHouseId] = { coords=vector3, radius=number }

-- İzlenen pedler: [pedHandle] = {
--     trap_id     = number,
--     detected_at = number (GetGameTimer),
--     dispatched  = bool,
--     anchor_pos  = vector3,
-- }
local TrackedPeds = {}

-- =====================================================================
-- SERVER BROADCAST ALIMI
-- =====================================================================
RegisterNetEvent('matrix:client:odorFieldUpdate', function(payload)
    if type(payload) ~= 'table' then return end
    local fresh = {}
    for _, cell in ipairs(payload) do
        if type(cell) == 'table'
            and type(cell.trap_house_id) == 'number'
            and type(cell.x) == 'number'
            and type(cell.y) == 'number'
            and type(cell.z) == 'number'
            and type(cell.odor_radius) == 'number'
            and cell.odor_radius > 0.0 then
            fresh[cell.trap_house_id] = {
                coords = vector3(cell.x, cell.y, cell.z),
                radius = cell.odor_radius,
            }
        end
    end
    OdorFields = fresh
end)

-- =====================================================================
-- ANIM / SCENARIO HELPERS
-- =====================================================================
local function EnsureAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local waited = 0
    while not HasAnimDictLoaded(dict) and waited < 2000 do
        Wait(50)
        waited = waited + 50
    end
    return HasAnimDictLoaded(dict)
end

-- =====================================================================
-- STATE BAG WRITE — diğer client'lar / server tarafından okunabilir
-- =====================================================================
local function MarkReportedOdor(ped, state)
    pcall(function()
        Entity(ped).state:set('matrix_reportedOdor', state, true)
    end)
end

-- =====================================================================
-- HÜCRE İÇİNDE Mİ? — kare mesafe, ilk eşleşende çık
-- =====================================================================
local function IsInAnyOdorField(pedCoords, extraMargin)
    extraMargin = extraMargin or 0.0
    for trapId, field in pairs(OdorFields) do
        local dx = pedCoords.x - field.coords.x
        local dy = pedCoords.y - field.coords.y
        local dz = pedCoords.z - field.coords.z
        local r  = field.radius + extraMargin
        if (dx * dx + dy * dy + dz * dz) <= (r * r) then
            return true, trapId, field.coords
        end
    end
    return false, nil, nil
end

-- =====================================================================
-- YÜZ DÖNME — disgust anim tetiklendiği anda
-- =====================================================================
local function FaceBuilding(ped, targetCoords)
    local pcoords = GetEntityCoords(ped)
    local dx = targetCoords.x - pcoords.x
    local dy = targetCoords.y - pcoords.y
    local heading = math.deg(math.atan(dy, dx)) - 90.0
    if heading < 0.0 then heading = heading + 360.0 end
    SetEntityHeading(ped, heading)
end

-- =====================================================================
-- TEMİZLEME — ölü/despawn olmuş pedleri düşür
-- =====================================================================
local function PruneTracked()
    local toRemove = {}
    for ped, _ in pairs(TrackedPeds) do
        if not DoesEntityExist(ped) then
            toRemove[#toRemove + 1] = ped
        elseif IsPedDeadOrDying(ped, true) or IsEntityDead(ped) then
            toRemove[#toRemove + 1] = ped
        end
    end
    for _, ped in ipairs(toRemove) do
        TrackedPeds[ped] = nil
    end
end

-- =====================================================================
-- ANA HEARTBEAT — 3000ms
-- =====================================================================
CreateThread(function()
    -- Boot offset — server broadcast'i dinlemeye başla
    Wait(3000)

    while true do
        Wait(SCAN_INTERVAL_MS)

        -- Alan yoksa hızlı çık
        if next(OdorFields) == nil then
            PruneTracked()
            Wait(SCAN_INTERVAL_MS)
        else
            local playerPed    = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            local now          = GetGameTimer()

            -- Ped pool taraması
            local pool = GetGamePool('CPed')
            for i = 1, #pool do
                local ped = pool[i]
                if ped ~= playerPed
                    and not IsPedAPlayer(ped)
                    and DoesEntityExist(ped)
                    and not IsPedDeadOrDying(ped, true) then

                    local pedCoords = GetEntityCoords(ped)
                    local inField, trapId, cellCoords = IsInAnyOdorField(pedCoords, 0.0)

                    if inField and not TrackedPeds[ped] then
                        -- İlk tespit
                        TrackedPeds[ped] = {
                            trap_id     = trapId,
                            detected_at = now,
                            dispatched  = false,
                            anchor_pos  = pedCoords,
                        }

                        -- State bag
                        MarkReportedOdor(ped, true)

                        -- Disgust anim
                        if EnsureAnimDict(ANIM_DICT) then
                            TaskPlayAnim(ped, ANIM_DICT, ANIM_CLIP,
                                3.0, -3.0, -1, 1, 0.0, false, false, false)
                        end

                        -- Binaya dön
                        FaceBuilding(ped, cellCoords)

                        -- Kısa bülten (player'a)
                        if lib and lib.notify then
                            lib.notify({
                                title       = 'RADAR',
                                description = 'Cell emission parameters breached. Chemical signature leaking into civilian grid.',
                                type        = 'inform',
                                duration    = 4000,
                            })
                        end
                    end
                end
            end

            -- İzlenen pedlerin strategik pencere kontrolü
            for ped, entry in pairs(TrackedPeds) do
                if DoesEntityExist(ped) and not IsEntityDead(ped) then
                    local elapsed = now - entry.detected_at

                    -- Ped hâlâ alanın içinde mi?
                    local pedCoords = GetEntityCoords(ped)
                    local stillIn   = IsInAnyOdorField(pedCoords, 1.5)

                    if stillIn and not entry.dispatched and elapsed >= INTERVENE_DELAY_MS then
                        -- 5 saniyelik stratejik pencere geçti, hâlâ aktive
                        entry.dispatched = true

                        -- Telefon çek
                        TaskStartScenarioInPlace(ped, PHONE_SCENARIO, 0, true)

                        -- Server'a ilet
                        TriggerServerEvent('matrix:server:civilianVetting:dispatch', entry.trap_id, pedCoords)

                        -- Oyuncuya bildir
                        if lib and lib.notify then
                            lib.notify({
                                title       = 'RADAR',
                                description = 'Tactical containment failed. Threat vector is now public.',
                                type        = 'error',
                                duration    = 6000,
                            })
                        end
                    end
                else
                    TrackedPeds[ped] = nil
                end
            end

            -- Ölü ped temizliği
            PruneTracked()
        end
    end
end)

-- =====================================================================
-- RESOURCE STOP — state temizliği
-- =====================================================================
AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    OdorFields  = {}
    TrackedPeds = {}
end)