-- =====================================================================
-- MATRIX CLIENT EVENT GATEWAY / client/matrix_events_handler.lua
--
-- Centralized client-side net-event gateway. Registers every
-- matrix:client:* event named in the PHASE 6 / STEP 3 request that had
-- no dedicated client-side handler in this resource ("orphan" events).
--
-- GROUNDING NOTE (read before shipping):
--   Only ONE of the 20 events below has a verified call site in the
--   server modules attached to this change (server/bureau.lua ->
--   Matrix.Bureau.IssueRaid -> matrix:client:executeRaid). A few more
--   have grounded PARAMETER VALUES from server/matrix_diagnostics.lua's
--   own regression checks (Matrix.ForensicOps.Config, Config.TrapHouseInterior
--   .Shell) even though their trigger site is elsewhere. The rest are
--   fired by modules that were never shared with this change (arson.lua,
--   cyber_ops.lua, recruitment.lua's coercion flow, workbench.lua,
--   vetting/lspd modules, radio.lua). Each section below is labeled
--   GROUNDED or INFERRED. Verify every INFERRED handler's payload shape
--   against its real TriggerClientEvent call site before relying on it.
--
-- Conventions carried over from the server modules in this resource:
--   - every handler body runs through pcall (_SafeHandler) so one bad
--     payload can't kill the resource's event loop.
--   - zero math.random; nothing here is randomized.
--   - proximity/monitor loops tick at 250ms, not per-frame.
-- =====================================================================

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local CreateThread        = CreateThread
local RegisterNetEvent    = RegisterNetEvent
local TriggerServerEvent  = TriggerServerEvent

Matrix = Matrix or {}
Matrix.EventsHandler = Matrix.EventsHandler or {}

-- =====================================================================
-- UTIL
-- =====================================================================
local function _Log(fmt, ...)
    local n = select('#', ...)
    local line = (n == 0) and fmt or fmt:format(...)
    if type(Matrix.Log) == 'function' then
        local ok = pcall(Matrix.Log, 'EVENTS_HANDLER', line)
        if ok then return end
    end
    print(('[MATRIX:EVENTS_HANDLER] %s'):format(line))
end

local function _SafeHandler(name, fn)
    RegisterNetEvent(name, function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            _Log('[HATA] %s handler basarisiz (yutuldu): %s', name, tostring(err))
        end
    end)
end

local function _Clamp(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function _ResolveNetEntity(netId)
    if type(netId) ~= 'number' or netId <= 0 then return nil end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    return entity
end

local function _LoadModel(model)
    local hash = (type(model) == 'string') and joaat(model) or model
    if type(hash) ~= 'number' or not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 5000 do
        Wait(50)
        waited = waited + 50
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

-- =====================================================================
-- [1] BOT YAŞAM DÖNGÜSÜ (INFERRED) —
-- matrix:client:injectBot / matrix:client:extractBot
-- Sunucu tarafta bir saha ajanının (dealer bot) operasyona başlaması/
-- geri çekilmesiyle eşleştiği varsayıldı (Matrix.Bots / Matrix.Dispatches
-- yaşam döngüsüne paralel). Gerçek tetikleyici modül paylaşılmadı;
-- payload şekli botId + netId + (opsiyonel) etiket varsayımıyla yazıldı.
-- =====================================================================
local InjectedBotBlips = {}

local function _OnInjectBot(botId, netId, label)
    botId = tonumber(botId)
    if not botId then return end

    local entity = _ResolveNetEntity(netId)
    if not entity then
        _Log('injectBot: netId=%s entity cozulemedi (henuz senkronize olmamis olabilir).', tostring(netId))
        return
    end

    if InjectedBotBlips[botId] and DoesBlipExist(InjectedBotBlips[botId]) then
        RemoveBlip(InjectedBotBlips[botId])
        InjectedBotBlips[botId] = nil
    end

    local blip = AddBlipForEntity(entity)
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, 5)
    SetBlipScale(blip, 0.75)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName((type(label) == 'string' and label ~= '') and label or ('AJAN #%d'):format(botId))
    EndTextCommandSetBlipName(blip)
    InjectedBotBlips[botId] = blip

    if lib and lib.notify then
        lib.notify({ title = 'SAHA AJANI', description = ('#%d saha operasyonuna enjekte edildi.'):format(botId), type = 'inform' })
    end

    _Log('injectBot: bot #%d saha operasyonuna enjekte edildi (netId=%s).', botId, tostring(netId))
end
_SafeHandler('matrix:client:injectBot', _OnInjectBot)

local function _OnExtractBot(botId)
    botId = tonumber(botId)
    if not botId then return end

    local blip = InjectedBotBlips[botId]
    if blip and DoesBlipExist(blip) then
        RemoveBlip(blip)
    end
    InjectedBotBlips[botId] = nil

    if lib and lib.notify then
        lib.notify({ title = 'SAHA AJANI', description = ('#%d sahadan cekildi.'):format(botId), type = 'inform' })
    end

    _Log('extractBot: bot #%d sahadan cekildi.', botId)
end
_SafeHandler('matrix:client:extractBot', _OnExtractBot)

-- =====================================================================
-- [2] BASKIN YÜRÜTME (GROUNDED) — matrix:client:executeRaid
-- server/bureau.lua Matrix.Bureau.IssueRaid gerçek çağrısı:
--   TriggerClientEvent('matrix:client:executeRaid', -1, trapHouseId,
--       house.coords, { squad_size, breach_method, escape_window })
-- Broadcast (-1) olduğu için HERKESE gider; yalnızca trap house'a yakın
-- oyuncu fiziksel efekt alır, geri kalanı yalnızca HUD bildirimi görür.
-- =====================================================================
local RAID_NEARBY_RADIUS = 60.0

local function _OnExecuteRaid(trapHouseId, coords, raidInfo)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return end
    raidInfo = type(raidInfo) == 'table' and raidInfo or {}

    local squadSize    = tonumber(raidInfo.squad_size) or 0
    local breachMethod = tostring(raidInfo.breach_method or 'ram')
    local escapeWindow = tonumber(raidInfo.escape_window) or 0

    local myCoords = GetEntityCoords(PlayerPedId())
    local dist = #(myCoords - vector3(coords.x, coords.y, coords.z))

    if dist <= RAID_NEARBY_RADIUS then
        if lib and lib.notify then
            lib.notify({
                title       = 'ŞAFAK BASKINI',
                description = ('%d birim, giriş:%s, kaçış penceresi:%ds'):format(squadSize, breachMethod, escapeWindow),
                type        = 'error',
                duration    = 8000
            })
        end
        PlaySoundFrontend(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', true)
    end

    _Log('executeRaid: trap #%d (%.1f,%.1f,%.1f) squad=%d breach=%s escape=%ds mesafe=%.1fm',
        trapHouseId, coords.x, coords.y, coords.z, squadSize, breachMethod, escapeWindow, dist)
end
_SafeHandler('matrix:client:executeRaid', _OnExecuteRaid)

-- =====================================================================
-- [3] TELSİZ STATİK PARAZİTİ (payload şekli GROUNDED) —
-- matrix:client:applyRadioStatic
-- server/bureau.lua RadioSpectrum ticker'i su cagriyi yapiyor (radio.lua
-- icinde, bu degisikligin disinda):
--   Matrix.Radio.ApplyStatic(src, newJam, 'radio_spectrum')
-- radio.lua paylaşılmadığı için bu event'in TAM OLARAK bu imzayla
-- (jamIntensity, reasonTag) tetiklendiği doğrulanamadı — parametre
-- sırası src hariç aynı varsayıldı.
-- =====================================================================
Matrix.EventsHandler.RadioStaticIntensity = 0.0

local function _OnApplyRadioStatic(jamIntensity, reasonTag)
    jamIntensity = _Clamp(jamIntensity, 0.0, 1.0)
    Matrix.EventsHandler.RadioStaticIntensity = jamIntensity

    if jamIntensity > 0.05 then
        PlaySoundFrontend(-1, 'GENERIC_CHAT_MESSAGE', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)
    end

    _Log('applyRadioStatic: intensity=%.3f reason=%s', jamIntensity, tostring(reasonTag or '?'))
end
_SafeHandler('matrix:client:applyRadioStatic', _OnApplyRadioStatic)

exports('GetRadioStaticIntensity', function() return Matrix.EventsHandler.RadioStaticIntensity end)

-- =====================================================================
-- [4] COERCION DİZİSİ (payload şekli GROUNDED — görev tanımının kendi
-- açıklamasından) — matrix:client:freezeEntity / gatherCoercionData /
-- beginCoercionProgress
-- Gerçek tetikleyici muhtemelen server/recruitment.lua (Matrix.Recruitment
-- .BeginCoercion, matrix_diagnostics.lua RequiredHooks içinde teyit
-- edildi) ama o dosya bu değişikliğe eklenmedi. Sunucu tarafı payload
-- sırasını recruitment.lua'ya karşı doğrulayın.
-- =====================================================================
local COERCION_ABORT_RADIUS = 3.0

local function _OnFreezeEntity(netId, durationMs)
    local entity = _ResolveNetEntity(netId)
    if not entity then
        _Log('freezeEntity: netId=%s cozulemedi.', tostring(netId))
        return
    end
    durationMs = tonumber(durationMs)
    if not durationMs or durationMs < 0 then durationMs = 0 end

    FreezeEntityPosition(entity, true)
    _Log('freezeEntity: entity netId=%s donduruldu (sure=%dms).', tostring(netId), durationMs)

    if durationMs > 0 then
        CreateThread(function()
            Wait(durationMs)
            if DoesEntityExist(entity) then
                FreezeEntityPosition(entity, false)
                _Log('freezeEntity: entity netId=%s cozuldu (sure doldu).', tostring(netId))
            end
        end)
    end
end
_SafeHandler('matrix:client:freezeEntity', _OnFreezeEntity)

local function _OnGatherCoercionData(targetNetId, dossier)
    Matrix.EventsHandler.CoercionSession = {
        target_net_id = targetNetId,
        dossier       = type(dossier) == 'table' and dossier or {},
        started_at    = GetGameTimer()
    }

    if lib and lib.notify then
        lib.notify({
            title       = 'İSTİHBARAT TOPLANIYOR',
            description = 'Hedef üzerinde zorlama dosyası derleniyor...',
            type        = 'inform'
        })
    end

    _Log('gatherCoercionData: hedef netId=%s icin dosya derlendi.', tostring(targetNetId))
end
_SafeHandler('matrix:client:gatherCoercionData', _OnGatherCoercionData)

local function _OnBeginCoercionProgress(targetNetId, durationMs, label)
    local anchor = _ResolveNetEntity(targetNetId)
    if not anchor then
        _Log('beginCoercionProgress: hedef netId=%s cozulemedi -- iptal.', tostring(targetNetId))
        return
    end
    if not lib or not lib.progressCircle then
        _Log('beginCoercionProgress: ox_lib (lib.progressCircle) bulunamadi -- surec calistirilamadi.')
        return
    end

    durationMs = tonumber(durationMs)
    if not durationMs or durationMs <= 0 then durationMs = 15000 end
    label = (type(label) == 'string' and label ~= '') and label or 'AJAN PSIKOLOJIK COERCION SURECI...'

    Matrix.EventsHandler.CoercionSession = Matrix.EventsHandler.CoercionSession
        or { target_net_id = targetNetId, started_at = GetGameTimer() }

    local monitoring = true
    local aborted = false

    CreateThread(function()
        while monitoring do
            if not DoesEntityExist(anchor) then
                aborted = true
                if lib.cancelProgress then lib.cancelProgress() end
                break
            end
            local dist = #(GetEntityCoords(PlayerPedId()) - GetEntityCoords(anchor))
            if dist > COERCION_ABORT_RADIUS then
                aborted = true
                if lib.cancelProgress then lib.cancelProgress() end
                break
            end
            Wait(250)
        end
    end)

    local completed = lib.progressCircle({
        duration     = durationMs,
        label        = label,
        position     = 'bottom',
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true, mouse = false },
        anim         = { dict = 'mp_arresting', clip = 'a_uncuff' },
    })
    monitoring = false

    if aborted or not completed then
        TriggerServerEvent('matrix:server:recruitment:abortCoercion', targetNetId, aborted and 'proximity_break' or 'cancelled')
        if lib.notify then
            lib.notify({ title = 'COERCION', description = 'Süreç kesintiye uğradı.', type = 'error' })
        end
        _Log('beginCoercionProgress: iptal edildi (aborted=%s completed=%s).', tostring(aborted), tostring(completed))
    else
        TriggerServerEvent('matrix:server:recruitment:completeCoercion', targetNetId)
        _Log('beginCoercionProgress: tamamlandi (netId=%s).', tostring(targetNetId))
    end

    Matrix.EventsHandler.CoercionSession = nil
end
_SafeHandler('matrix:client:beginCoercionProgress', _OnBeginCoercionProgress)

-- =====================================================================
-- [5] SİBER OPERASYON (config değerleri GROUNDED; payload sırası
-- INFERRED) — matrix:client:cyberOpStart / cyberOpAborted / cyberOpCompleted
-- server/matrix_diagnostics.lua doğrulanmış Matrix.CyberOps.Config
-- değerleri: BaseDurationSeconds=120, InterruptLeakBump=0.30,
-- ComputeDurationMs(iq=100)=100000ms (IQ-ölçekli süre). cyber_ops.lua
-- paylaşılmadığından durationMs'in bu event ile mi geldiği yoksa
-- clientin kendi varsayılanını mı kullandığı doğrulanamadı; sunucudan
-- gelirse onu, gelmezse 100000ms varsayılanını kullanır.
-- =====================================================================
local CYBER_OP_DEFAULT_DURATION_MS = 100000
local CYBER_OP_INTERRUPT_LEAK_BUMP = 0.30

Matrix.EventsHandler.CyberOpActive = false

local function _OnCyberOpStart(durationMs, label)
    durationMs = tonumber(durationMs) or CYBER_OP_DEFAULT_DURATION_MS
    label = (type(label) == 'string' and label ~= '') and label or 'SİBER SIZMA...'

    Matrix.EventsHandler.CyberOpActive = true

    CreateThread(function()
        local completed = false
        if lib and lib.progressCircle then
            completed = lib.progressCircle({
                duration     = durationMs,
                label        = label,
                position     = 'bottom',
                useWhileDead = false,
                canCancel    = true,
                disable      = { move = true, car = true, combat = true },
            })
        else
            Wait(durationMs)
            completed = true
        end

        if not Matrix.EventsHandler.CyberOpActive then return end
        Matrix.EventsHandler.CyberOpActive = false

        if completed then
            TriggerServerEvent('matrix:server:cyberops:complete')
        else
            TriggerServerEvent('matrix:server:cyberops:abort', 'cancelled', CYBER_OP_INTERRUPT_LEAK_BUMP)
        end
    end)

    _Log('cyberOpStart: sure=%dms baslik=%s', durationMs, label)
end
_SafeHandler('matrix:client:cyberOpStart', _OnCyberOpStart)

local function _OnCyberOpAborted(reason)
    Matrix.EventsHandler.CyberOpActive = false
    if lib and lib.cancelProgress then lib.cancelProgress() end
    if lib and lib.notify then
        lib.notify({ title = 'SİBER OPERASYON', description = ('İptal: %s'):format(tostring(reason or '?')), type = 'error' })
    end
    _Log('cyberOpAborted: reason=%s', tostring(reason))
end
_SafeHandler('matrix:client:cyberOpAborted', _OnCyberOpAborted)

local function _OnCyberOpCompleted(summary)
    Matrix.EventsHandler.CyberOpActive = false
    if lib and lib.notify then
        lib.notify({ title = 'SİBER OPERASYON', description = 'Sızma tamamlandı.', type = 'success' })
    end
    _Log('cyberOpCompleted: %s', (type(summary) == 'table' and tostring(summary.detail or 'ok')) or tostring(summary))
end
_SafeHandler('matrix:client:cyberOpCompleted', _OnCyberOpCompleted)

-- =====================================================================
-- [6] ADLİ ASİT TEMİZLİĞİ (GROUNDED) — matrix:client:forensicAcidStart
-- server/matrix_diagnostics.lua doğrulanmış Matrix.ForensicOps.Config:
-- DurationMs=90000, PropModel='prop_clean_agent'. forensic_ops.lua'nın
-- kendisi paylaşılmadı; süre/prop değerleri diagnostics kontrolünden
-- birebir alındı.
-- =====================================================================
local FORENSIC_ACID_DURATION_MS = 90000
local FORENSIC_ACID_PROP_MODEL  = 'prop_clean_agent'

local function _OnForensicAcidStart(coords)
    local validCoords = (type(coords) == 'table' or type(coords) == 'vector3' or type(coords) == 'vector4')
        and coords.x and coords.y and coords.z

    local prop = nil
    if validCoords then
        local hash = _LoadModel(FORENSIC_ACID_PROP_MODEL)
        if hash then
            prop = CreateObject(hash, coords.x, coords.y, coords.z, true, true, false)
            PlaceObjectOnGroundProperly(prop)
            SetModelAsNoLongerNeeded(hash)
        end
    end

    local completed = false
    if lib and lib.progressCircle then
        completed = lib.progressCircle({
            duration     = FORENSIC_ACID_DURATION_MS,
            label        = 'ADLİ İZLER ASİTLE TEMİZLENİYOR...',
            position     = 'bottom',
            useWhileDead = false,
            canCancel    = true,
            disable      = { move = true, car = true, combat = true },
        })
    else
        Wait(FORENSIC_ACID_DURATION_MS)
        completed = true
    end

    if prop and DoesEntityExist(prop) then
        DeleteObject(prop)
    end

    TriggerServerEvent('matrix:server:forensicops:acidResult', completed)
    _Log('forensicAcidStart: tamamlandi=%s (sure=%dms)', tostring(completed), FORENSIC_ACID_DURATION_MS)
end
_SafeHandler('matrix:client:forensicAcidStart', _OnForensicAcidStart)

-- =====================================================================
-- [7] VETTING / SAHTE BÜLTEN (INFERRED) —
-- matrix:client:vettingDossier / matrix:client:fakeLspdBulletin
-- server/matrix_diagnostics.lua FAZ 5 bloğu Matrix.Recruitment.
-- EvaluateCoercionConditions'i doğruluyor (recruitment.lua'da bir
-- "vetting" akışı var) ama dosyanın kendisi paylaşılmadı. Bu iki event
-- salt görüntüleme (dossier/bülten metni) varsayımıyla, sunucuya
-- geri-çağrı yapmadan yazıldı.
-- =====================================================================
local function _OnVettingDossier(dossier)
    dossier = type(dossier) == 'table' and dossier or {}
    if lib and lib.alertDialog then
        lib.alertDialog({
            header   = 'VETTING DOSYASI',
            content  = tostring(dossier.text or dossier.summary or 'Dosya içeriği boş.'),
            centered = true,
            cancel   = false
        })
    end
    _Log('vettingDossier: dosya goruntulendi.')
end
_SafeHandler('matrix:client:vettingDossier', _OnVettingDossier)

local function _OnFakeLspdBulletin(bulletin)
    bulletin = type(bulletin) == 'table' and bulletin or {}
    if lib and lib.alertDialog then
        lib.alertDialog({
            header   = tostring(bulletin.title or 'LSPD RESMİ BÜLTEN'),
            content  = tostring(bulletin.text or 'Bülten içeriği boş.'),
            centered = true,
            cancel   = false
        })
    end
    _Log('fakeLspdBulletin: bulten goruntulendi.')
end
_SafeHandler('matrix:client:fakeLspdBulletin', _OnFakeLspdBulletin)

-- =====================================================================
-- [8] KUNDAKLAMA DİZİSİ (INFERRED) — matrix:client:arsonAlertDialog /
-- arsonFrictionStart / arsonIgnite / arsonFireIntensity / arsonResolved
-- arson.lua bu değişikliğe eklenmedi; aşağıdaki akış (uyarı -> sürtünme
-- hazırlığı -> ateşleme -> yoğunluk güncellemesi -> sonuç) yalnızca
-- event isimlerinden ve StartScriptFire/RemoveScriptFire native
-- çiftinin standart kullanımından çıkarıldı. Sunucu tarafı payload
-- sırası doğrulanmadan production'a alınmamalı.
-- =====================================================================
Matrix.EventsHandler.ActiveFireHandle = nil
Matrix.EventsHandler.FireIntensity    = 0.0

local function _OnArsonAlertDialog(warningText)
    if lib and lib.alertDialog then
        local result = lib.alertDialog({
            header   = 'KUNDAKLAMA',
            content  = tostring(warningText or 'Bu yapıyı ateşe vermek geri alınamaz bir eylemdir.'),
            centered = true,
            cancel   = true
        })
        TriggerServerEvent('matrix:server:arson:alertAck', result == 'confirm')
    end
    _Log('arsonAlertDialog: gosterildi.')
end
_SafeHandler('matrix:client:arsonAlertDialog', _OnArsonAlertDialog)

local function _OnArsonFrictionStart(durationMs)
    durationMs = tonumber(durationMs) or 8000
    local completed = false
    if lib and lib.progressCircle then
        completed = lib.progressCircle({
            duration     = durationMs,
            label        = 'SÜRTÜNME İLE ATEŞLEME HAZIRLANIYOR...',
            position     = 'bottom',
            useWhileDead = false,
            canCancel    = true,
            disable      = { move = true, car = true, combat = true },
        })
    else
        Wait(durationMs)
        completed = true
    end

    if completed then
        TriggerServerEvent('matrix:server:arson:frictionComplete')
    else
        TriggerServerEvent('matrix:server:arson:frictionAbort')
    end
    _Log('arsonFrictionStart: tamamlandi=%s', tostring(completed))
end
_SafeHandler('matrix:client:arsonFrictionStart', _OnArsonFrictionStart)

local function _OnArsonIgnite(coords)
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return end

    if Matrix.EventsHandler.ActiveFireHandle then
        pcall(RemoveScriptFire, Matrix.EventsHandler.ActiveFireHandle)
        Matrix.EventsHandler.ActiveFireHandle = nil
    end

    local handle = StartScriptFire(coords.x, coords.y, coords.z, 20, false)
    Matrix.EventsHandler.ActiveFireHandle = handle
    _Log('arsonIgnite: (%.1f,%.1f,%.1f) yaninda ates baslatildi (handle=%s).', coords.x, coords.y, coords.z, tostring(handle))
end
_SafeHandler('matrix:client:arsonIgnite', _OnArsonIgnite)

local function _OnArsonFireIntensity(intensity)
    intensity = _Clamp(intensity, 0.0, 1.0)
    Matrix.EventsHandler.FireIntensity = intensity

    if intensity > 0.75 and lib and lib.notify then
        lib.notify({ title = 'KUNDAKLAMA', description = 'Yangın kontrolden çıkıyor.', type = 'error' })
    end

    _Log('arsonFireIntensity: %.2f', intensity)
end
_SafeHandler('matrix:client:arsonFireIntensity', _OnArsonFireIntensity)

local function _OnArsonResolved(outcome)
    if Matrix.EventsHandler.ActiveFireHandle then
        pcall(RemoveScriptFire, Matrix.EventsHandler.ActiveFireHandle)
        Matrix.EventsHandler.ActiveFireHandle = nil
    end
    Matrix.EventsHandler.FireIntensity = 0.0

    if lib and lib.notify then
        lib.notify({ title = 'KUNDAKLAMA', description = tostring(outcome or 'Olay sonuçlandı.'), type = 'inform' })
    end
    _Log('arsonResolved: %s', tostring(outcome))
end
_SafeHandler('matrix:client:arsonResolved', _OnArsonResolved)

-- =====================================================================
-- [9] WORKBENCH NAMLU PROP'U (GROUNDED) —
-- matrix:client:workbench:materializeBarrel / workbench:dematerializeBarrel
-- Config.TrapHouseInterior.Shell zaten server/forensics.lua içinde
-- EnterCoords/ExitCoords/RouterPos alanlarıyla doğrulandı (aynı Shell
-- tablosu); WorkbenchPos aynı tablonun doğal bir sibling alanı olarak
-- varsayıldı. Prop modeli görev tanımından birebir: prop_gun_barrel_01.
-- =====================================================================
local WORKBENCH_BARREL_MODEL = 'prop_gun_barrel_01'
local _workbenchBarrelProp = nil

local function _OnMaterializeBarrel()
    local shell = Config.TrapHouseInterior and Config.TrapHouseInterior.Shell
    local pos = shell and shell.WorkbenchPos
    if not pos then
        _Log('workbench:materializeBarrel: Config.TrapHouseInterior.Shell.WorkbenchPos tanimsiz.')
        return
    end

    if _workbenchBarrelProp and DoesEntityExist(_workbenchBarrelProp) then
        DeleteObject(_workbenchBarrelProp)
        _workbenchBarrelProp = nil
    end

    local hash = _LoadModel(WORKBENCH_BARREL_MODEL)
    if not hash then
        _Log('workbench:materializeBarrel: model yuklenemedi (%s).', WORKBENCH_BARREL_MODEL)
        return
    end

    local heading = tonumber(pos.w) or 0.0
    local prop = CreateObject(hash, pos.x, pos.y, pos.z, true, true, false)
    SetEntityHeading(prop, heading)
    FreezeEntityPosition(prop, true)
    SetModelAsNoLongerNeeded(hash)

    _workbenchBarrelProp = prop
    _Log('workbench:materializeBarrel: %s WorkbenchPos (%.2f,%.2f,%.2f) uzerinde sabitlendi.',
        WORKBENCH_BARREL_MODEL, pos.x, pos.y, pos.z)
end
_SafeHandler('matrix:client:workbench:materializeBarrel', _OnMaterializeBarrel)

local function _OnDematerializeBarrel()
    if _workbenchBarrelProp and DoesEntityExist(_workbenchBarrelProp) then
        DeleteObject(_workbenchBarrelProp)
        _Log('workbench:dematerializeBarrel: prop temizlendi.')
    end
    _workbenchBarrelProp = nil
end
_SafeHandler('matrix:client:workbench:dematerializeBarrel', _OnDematerializeBarrel)

-- =====================================================================
-- KAYNAK DURDURMA TEMİZLİĞİ
-- =====================================================================
AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    if _workbenchBarrelProp and DoesEntityExist(_workbenchBarrelProp) then
        DeleteObject(_workbenchBarrelProp)
    end
    if Matrix.EventsHandler.ActiveFireHandle then
        pcall(RemoveScriptFire, Matrix.EventsHandler.ActiveFireHandle)
    end
    for _, blip in pairs(InjectedBotBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
end)
