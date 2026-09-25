-- =====================================================================
-- PROJECT MATRIX — SESSION 1 — RECON WATCHDOG (CLIENT)
--
-- ★ 0.00ms IDLE: yalnızca onClientResourceStart'ta bir seferlik init
--   thread'i. Per-frame loop YOK. Mesafe denetimi ox_target tarafından
--   yerel yürütülür — game loop overhead'i YOK.
--
-- ★ LOCAL SQUARED VECTOR MATH: #(a - b)
-- =====================================================================

-- ★ [SESSION1 KALİBRASYON] Yol ortasından kaldırıma/bina önüne çekildi.
-- Oyun içinde istediğin gibi ince ayar yapılabilsin diye koordinatlar
-- tek noktada toplanmıştır. /coords ile yeni değer alıp buraya yaz.
local BROKER_COORDS    = vector4(143.80, -1025.20, 29.3, 210.0)
local COUNSELOR_COORDS = vector4(-521.80, -244.80, 35.1, 305.0)

local BROKER_MODEL    = 'a_m_m_business_01'
local COUNSELOR_MODEL = 'a_m_m_business_02'

local brokerPed, counselorPed = nil, nil
local cachedVariants = nil

local function HasOxLib()
    return type(lib) == 'table' and type(lib.registerContext) == 'function'
end

local function HasOxTarget()
    return exports and exports.ox_target ~= nil
end


local function LoadModelSync(modelName)
    local hash = joaat(modelName)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 5000 do
        Wait(25)
        waited = waited + 25
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

-- ---------------------------------------------------------------------
-- Stationary ped spawner — GRAVITY-BASED placement.
-- Raycast YOK, PlaceObjectOnGroundProperly YOK. NPC 1m havadan bırakılır,
-- GTA fizik motoru gerçek zemine düşürür, sonra kilitlenir.
-- ---------------------------------------------------------------------
local function SpawnStationaryPed(coords, modelName)
    if type(coords) ~= 'vector4' then return nil end
    local hash = LoadModelSync(modelName)
    if not hash then return nil end

    -- 1.0m yukarıdan spawn — gerçek zeminin üstünde olduğu garanti
    local spawnZ = coords.z + 1.0
    local ped = CreatePed(4, hash, coords.x, coords.y, spawnZ, coords.w, false, true)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end

    -- Fizik ve mission flag'leri
    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityCanBeDamaged(ped, false)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 17, true)

    -- Collision yüklensin
    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    local cWait = 0
    while not HasCollisionLoadedAroundEntity(ped) and cWait < 2000 do
        Wait(25)
        cWait = cWait + 25
    end

    -- ★ KRİTİK: Fizik motoru düşürsün (2 saniye settle)
    Wait(2000)

    -- Yerleşen konumu oku
    local final = GetEntityCoords(ped)

    -- Şimdi kilitle
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityHeading(ped, coords.w)

    -- Doğrulama logu — konsolda görünür
    print(('[SESSION1] %s placed at (%.2f, %.2f, %.2f)'):format(
        modelName, final.x, final.y, final.z))

    SetModelAsNoLongerNeeded(hash)
    return ped
end

local function OpenBrokerMenu()
    if not HasOxLib() then return end

    if not cachedVariants then
        local ok, v = pcall(function()
            return lib.callback.await('matrix:callback:session1:getVariants', false)
        end)
        cachedVariants = (ok and type(v) == 'table') and v or {}
    end

    local myCoords   = GetEntityCoords(PlayerPedId())
    local brokerPos  = vector3(BROKER_COORDS.x, BROKER_COORDS.y, BROKER_COORDS.z)
    if #(myCoords - brokerPos) > 2.5 then
        lib.notify({
            title       = 'SECURITY HANDSHAKE',
            description = 'Line disconnected — out of proxy broker range.',
            type        = 'error',
        })
        return
    end

    local function BuildOption(size)
        local v = cachedVariants[size]
        if not v then return nil end
        return {
            title = ('[CELL // %s]'):format(size:upper()),
            description = ('Op cost $%d | Grid %.1f | Odor %.1f | Daily $%d')
                :format(v.cost, v.grid_load, v.odor_mult, v.daily_maintenance),
            icon = 'fa-solid fa-vault',
            onSelect = function()
                local confirm = lib.alertDialog({
                    header   = 'PROXY ASSET REGISTRATION',
                    content  = ('Register a %s cell at $%d? FinCEN audit monitors daily.')
                        :format(size:upper(), v.cost),
                    centered = true,
                    cancel   = true,
                })
                if confirm ~= 'confirm' then return end
                local c = GetEntityCoords(PlayerPedId())
                TriggerServerEvent('matrix:server:proxy:purchaseCell', size, {
                    x = c.x, y = c.y, z = c.z,
                })
            end,
        }
    end

    lib.registerContext({
        id      = 'matrix_session1_broker',
        title   = 'PARAVAN ESTATE // ASSET MENU',
        options = {
            BuildOption('small'),
            BuildOption('medium'),
            BuildOption('large'),
        },
    })
    lib.showContext('matrix_session1_broker')
end

local function OpenCounselorMenu()
    if not HasOxLib() then return end

    local myCoords      = GetEntityCoords(PlayerPedId())
    local counselorPos  = vector3(COUNSELOR_COORDS.x, COUNSELOR_COORDS.y, COUNSELOR_COORDS.z)
    if #(myCoords - counselorPos) > 2.5 then
        lib.notify({
            title       = 'SECURITY HANDSHAKE',
            description = 'Line disconnected — counselor unavailable at this range.',
            type        = 'error',
        })
        return
    end

    lib.registerContext({
        id    = 'matrix_session1_counselor',
        title = 'CORRUPTED COUNSELOR // RETAINER',
        options = {
            {
                title       = '[RETAINMENT FUND — $50,000 CASH]',
                description = 'Expands legal umbrella. Caps operational cell limit at 3.',
                icon        = 'fa-solid fa-gavel',
                onSelect    = function()
                    local confirm = lib.alertDialog({
                        header   = 'COUNSELOR RETAINER',
                        content  = 'Execute the retainer fund transfer? $50,000 physical cash will be collected. Legal umbrella expands immediately.',
                        centered = true,
                        cancel   = true,
                    })
                    if confirm ~= 'confirm' then return end
                    TriggerServerEvent('matrix:server:proxy:counselorBribe')
                end,
            },
        },
    })
    lib.showContext('matrix_session1_counselor')
end

local function BindTargets()
    if not HasOxTarget() then return end

    if brokerPed and DoesEntityExist(brokerPed) then
        exports.ox_target:addLocalEntity(brokerPed, {
            {
                name     = 'matrix_session1_broker',
                icon     = 'fa-solid fa-building-columns',
                label    = 'Browse Cell Structures',
                distance = 1.8,
                onSelect = OpenBrokerMenu,
            },
        })
    end

    if counselorPed and DoesEntityExist(counselorPed) then
        exports.ox_target:addLocalEntity(counselorPed, {
            {
                name     = 'matrix_session1_counselor',
                icon     = 'fa-solid fa-scale-balanced',
                label    = 'Consult Counselor',
                distance = 1.8,
                onSelect = OpenCounselorMenu,
            },
        })
    end
end

local function InitReconWatchdog()
    brokerPed    = SpawnStationaryPed(BROKER_COORDS, BROKER_MODEL)
    counselorPed = SpawnStationaryPed(COUNSELOR_COORDS, COUNSELOR_MODEL)

    if brokerPed    then SetPedDefaultComponentVariation(brokerPed)    end
    if counselorPed then SetPedDefaultComponentVariation(counselorPed) end

    BindTargets()
end

AddEventHandler('onClientResourceStart', function(resName)
    if resName ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(1500)
        InitReconWatchdog()
    end)
end)

AddEventHandler('onClientResourceStop', function(resName)
    if resName ~= GetCurrentResourceName() then return end
    if HasOxTarget() then
        if brokerPed and DoesEntityExist(brokerPed) then
            pcall(function() exports.ox_target:removeLocalEntity(brokerPed) end)
        end
        if counselorPed and DoesEntityExist(counselorPed) then
            pcall(function() exports.ox_target:removeLocalEntity(counselorPed) end)
        end
    end
    if brokerPed    and DoesEntityExist(brokerPed)    then DeleteEntity(brokerPed)    end
    if counselorPed and DoesEntityExist(counselorPed) then DeleteEntity(counselorPed) end
    brokerPed, counselorPed = nil, nil
end)