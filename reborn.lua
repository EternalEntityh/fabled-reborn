--[[
    ⚔️ FABLED AUTOFARM (Universal) — v2.9 (Smart Dodge Edition)

    • Esquiva inteligente: solo esquiva ataques que de verdad te alcanzan
      (aprende el RANGO de cada ataque, no solo el timing) y las ventanas
      de esquiva son mucho más cortas -> pegas mucho más.
    • Anticipación y cola de la esquiva ajustables desde la UI.
    • Respaldo reactivo corto cuando el ataque sí fue identificado.
    • Aprendizaje más limpio (ignora animaciones Idle/Movement, prioriza Action,
      limpia datos viejos sin confirmar).
    • Objetivo "pegajoso": no cambia de enemigo a cada rato.
    • Anti-AFK, contadores de esquivas y botón para borrar lo aprendido.

    Atajos:  RightControl = iniciar / detener  ·  RightShift = ocultar / mostrar UI
]]

-- ============================================================
-- SERVICIOS Y CARGA LIMPIA
-- ============================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local GuiService = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local VERSION = "2.9"
local GUI_NAME = "FabledAutofarmUI"

local sharedEnv = (typeof(getgenv) == "function" and getgenv()) or _G
if type(sharedEnv.FabledAutofarm) == "table" and type(sharedEnv.FabledAutofarm.Unload) == "function" then
    pcall(sharedEnv.FabledAutofarm.Unload)
end
local previousGui = PlayerGui:FindFirstChild(GUI_NAME)
if previousGui then
    previousGui:Destroy()
end

-- ============================================================
-- CONSTANTES OPTIMIZADAS
-- ============================================================
local KEY_HOLD_TIME = 0.01
local KEY_GAP_TIME = 0.01
local CLICK_X, CLICK_Y = 0, 0
local SCAN_INTERVAL = 0.5
local IDLE_SCAN_INTERVAL = 0.5
local WORKSPACE_FALLBACK_INTERVAL = 2
local MAX_SCAN_DEPTH = 6
local MIN_ENEMY_MAX_HEALTH = 500
local UI_REFRESH_INTERVAL = 0.1
local TARGET_STICKY_DISTANCE = 12      -- el objetivo actual se conserva si otro no está al menos 12 studs más cerca

-- Constantes de la esquiva suave
local DODGE_MIN_DAMAGE_PERCENT = 0.02
local DODGE_RISE_SPEED = 60            -- subir casi instantáneo (antes 40)
local DODGE_FALL_SPEED = 18            -- bajar rápido (antes 7: era lo que más tiempo te quitaba)
local DODGE_REACTIVE_MAX = 0.15        -- esquiva reactiva corta cuando el ataque sí se identificó

local HOTKEY_TOGGLE_FARM = Enum.KeyCode.RightControl
local HOTKEY_TOGGLE_UI = Enum.KeyCode.RightShift

local WINDOW_WIDTH = 340
local HEADER_HEIGHT = 46
local BODY_PADDING_Y = 22

-- ============================================================
-- AJUSTES
-- ============================================================
local DEFAULTS = {
    FlightHeight = 7,
    DodgeExtraHeight = 40,
    DodgeDuration = 0.3,   -- Solo se usa como respaldo si NO se identifica la animación del golpe
    DodgeLead = 0.10,      -- Cuánto ANTES del golpe empieza a esquivar (se suma el ping)
    DodgeTail = 0.10,      -- Cuánto DESPUÉS del golpe sigue arriba
    AttackDelay = 0.03,
    ScanRadius = 5000,
    DodgeEnabled = true,
    AttackWhileDodging = false,
    UseSkillF = true,
    UseSkillR = true,
    UseClick = true,
    AutoStart = true,
    AntiAFK = true,
}

local LIMITS = {
    FlightHeight = { min = 2, max = 100, step = 1, decimals = 0 },
    DodgeExtraHeight = { min = 0, max = 300, step = 5, decimals = 0 },
    DodgeDuration = { min = 0.1, max = 5, step = 0.1, decimals = 1 },
    DodgeLead = { min = 0, max = 0.5, step = 0.01, decimals = 2 },
    DodgeTail = { min = 0, max = 0.5, step = 0.01, decimals = 2 },
    AttackDelay = { min = 0.01, max = 5, step = 0.01, decimals = 2 },
    ScanRadius = { min = 50, max = 20000, step = 250, decimals = 0 },
}

local Config = table.clone(DEFAULTS)

local function roundTo(value, decimals)
    local multiplier = 10 ^ decimals
    return math.floor(value * multiplier + 0.5) / multiplier
end

local function clampSetting(key, value)
    local limit = LIMITS[key]
    return roundTo(math.clamp(value, limit.min, limit.max), limit.decimals)
end

local function formatNumber(value)
    return string.format("%g", value)
end

local CONFIG_FILE = "FabledAutofarm_config_v26.json"

local function loadConfig()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
    pcall(function()
        if not isfile(CONFIG_FILE) then return end
        local data = HttpService:JSONDecode(readfile(CONFIG_FILE))
        for key, defaultValue in pairs(DEFAULTS) do
            local value = data[key]
            if type(value) == type(defaultValue) then
                if type(value) == "number" then Config[key] = clampSetting(key, value)
                else Config[key] = value end
            end
        end
    end)
end

local saveQueued = false
local function saveConfig()
    if typeof(writefile) ~= "function" or saveQueued then return end
    saveQueued = true
    task.delay(0.6, function()
        saveQueued = false
        pcall(function() writefile(CONFIG_FILE, HttpService:JSONEncode(Config)) end)
    end)
end

loadConfig()

-- ============================================================
-- LISTAS DE FILTRADO
-- ============================================================
local NAME_BLACKLIST = {
    "stranger", "geoff", "buy bundle", "level milestone", "speedrun leaderboard",
    "change lobby music", "check runs", "promptpart", "wishing well", "sirpixel",
    "healer", "companion", "healercompanion", "dummy", "training", "spawnpoint",
}

local PROP_BLACKLIST = {
    "torch", "torck", "light", "lamp", "fire", "candle", "particle", "effect",
    "prop", "decor", "model", "map", "terrain", "wall", "floor", "door",
    "spawn", "camera", "sound", "beam", "aura", "fx", "hitbox", "trigger",
}

local ENEMY_FOLDERS = {
    "Enemies", "Bosses", "Boss", "DungeonMap", "Mobs", "Monsters", "WaveEnemies",
}

-- ============================================================
-- ESTADO COMPARTIDO
-- ============================================================
local State = {
    running = false, session = 0, minimized = false,
    root = nil, humanoid = nil, target = nil, targetPart = nil, targetHumanoid = nil,
    hoverPos = nil, candidates = 0, dodgeUntil = 0, kills = 0, runSeconds = 0,
    dodges = 0, dodgeSeconds = 0,
    status = "Detenido", statusKind = "stopped",
}

State.dodgeOffset = 0

local ui = {}
local connections = {}
local cache = { list = {}, time = 0, fullTime = 0 }
local healthConnection = nil
local lastHealth = 0

local function bind(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end

-- ============================================================
-- DETECCIÓN DE ENEMIGOS
-- ============================================================
local blockedNameCache = {}

local function isBlockedName(name)
    local cached = blockedNameCache[name]
    if cached ~= nil then return cached end
    local lowered = string.lower(name)
    local blocked = false
    for _, word in ipairs(NAME_BLACKLIST) do
        if string.find(lowered, word, 1, true) then blocked = true; break end
    end
    if not blocked then
        for _, word in ipairs(PROP_BLACKLIST) do
            if string.find(lowered, word, 1, true) then blocked = true; break end
        end
    end
    blockedNameCache[name] = blocked
    return blocked
end

local function getEnemyPart(model)
    local circle = model:FindFirstChild("Circle")
    if circle and circle:IsA("BasePart") then return circle end
    local head = model:FindFirstChild("Head")
    if head and head:IsA("BasePart") then return head end
    local rootPart = model:FindFirstChild("HumanoidRootPart")
    if rootPart and rootPart:IsA("BasePart") then return rootPart end
    return model:FindFirstChildWhichIsA("BasePart")
end

local function isEnemy(model)
    if model == LocalPlayer.Character or Players:GetPlayerFromCharacter(model) then return false end
    if isBlockedName(model.Name) then return false end
    local parent = model.Parent
    if parent and isBlockedName(parent.Name) then return false end

    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if humanoid and humanoid.Health > 0 and humanoid.MaxHealth > MIN_ENEMY_MAX_HEALTH then return true end
    local circle = model:FindFirstChild("Circle")
    return circle ~= nil and circle:IsA("BasePart")
end

local function scanContainer(container, depth, found, origin)
    if depth > MAX_SCAN_DEPTH then return end
    for _, object in ipairs(container:GetChildren()) do
        if object:IsA("Model") then
            if isEnemy(object) then
                local part = getEnemyPart(object)
                if part then
                    local dist = (part.Position - origin).Magnitude
                    if dist <= Config.ScanRadius then
                        table.insert(found, { model = object, part = part, dist = dist })
                    end
                end
            end
        elseif object:IsA("Folder") then
            scanContainer(object, depth + 1, found, origin)
        end
    end
end

local function refreshCandidates(origin)
    local now = os.clock()
    local list = cache.list
    local interval = (#list > 0) and SCAN_INTERVAL or IDLE_SCAN_INTERVAL

    if now - cache.time < interval then
        local valid = {}
        for _, entry in ipairs(list) do
            local model = entry.model
            if model.Parent and isEnemy(model) then
                local part = getEnemyPart(model)
                if part then
                    entry.part = part
                    entry.dist = (part.Position - origin).Magnitude
                    table.insert(valid, entry)
                end
            end
        end
        if #valid == 0 and #list > 0 then cache.time = 0 end
        cache.list = valid
        return
    end

    cache.time = now
    local found = {}
    for _, folderName in ipairs(ENEMY_FOLDERS) do
        local folder = workspace:FindFirstChild(folderName)
        if folder then scanContainer(folder, 0, found, origin) end
    end

    if #found == 0 and now - (cache.fullTime or 0) >= WORKSPACE_FALLBACK_INTERVAL then
        cache.fullTime = now
        scanContainer(workspace, 0, found, origin)
    end
    cache.list = found
end

-- Objetivo "pegajoso": se queda con el actual mientras siga vivo y no haya
-- otro claramente más cerca (evita saltar entre enemigos y perder golpes).
local function findClosestEnemy(origin)
    refreshCandidates(origin)
    local list = cache.list
    local best, current = nil, nil
    local currentTarget = State.target
    for index = 1, #list do
        local entry = list[index]
        if not best or entry.dist < best.dist then best = entry end
        if currentTarget and entry.model == currentTarget then current = entry end
    end
    if best and current and current ~= best and current.dist <= best.dist + TARGET_STICKY_DISTANCE then
        best = current
    end
    if best then return best.model, best.part, #list end
    return nil, nil, 0
end

-- ============================================================
-- SIMULACIÓN DE ENTRADAS
-- ============================================================
local function tapKey(keyCode)
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
        task.wait(KEY_HOLD_TIME)
        VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
    end)
end

local function clickMouse()
    pcall(function()
        VirtualInputManager:SendMouseButtonEvent(CLICK_X, CLICK_Y, 0, true, game, 1)
        task.wait(KEY_HOLD_TIME)
        VirtualInputManager:SendMouseButtonEvent(CLICK_X, CLICK_Y, 0, false, game, 1)
    end)
end

-- ============================================================
-- AUTO-START
-- ============================================================
local START_SCAN_INTERVAL = 3
local START_RETRY_INTERVAL = 1.5
local START_NAMES = { start = true, startbutton = true, startbtn = true, btnstart = true, startgame = true }
local StartButton = { cache = nil, lastScan = 0, lastPress = 0, attempts = 0, giveUpUntil = 0 }

local function cleanText(text)
    text = string.gsub(text, "<[^>]->", "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return string.lower(text)
end

local function isShown(obj)
    local current = obj
    while current and current ~= PlayerGui do
        if current:IsA("GuiObject") and not current.Visible then return false end
        if current:IsA("ScreenGui") and not current.Enabled then return false end
        current = current.Parent
    end
    local size = obj.AbsoluteSize
    return size.X > 2 and size.Y > 2
end

local function containsPoint(gui, point)
    local pos, size = gui.AbsolutePosition, gui.AbsoluteSize
    return point.X >= pos.X and point.X <= pos.X + size.X
        and point.Y >= pos.Y and point.Y <= pos.Y + size.Y
end

local function resolveClickable(obj)
    if obj:IsA("GuiButton") then return obj end
    local center = obj.AbsolutePosition + obj.AbsoluteSize / 2
    local node = obj
    for _ = 1, 3 do
        node = node.Parent
        if not node or node == PlayerGui then break end
        if node:IsA("GuiButton") then return node end
        for _, child in ipairs(node:GetDescendants()) do
            if child:IsA("GuiButton") and child.Visible and containsPoint(child, center) then
                return child
            end
        end
    end
    return obj
end

local function findStartButton()
    local scanned = 0
    for _, screen in ipairs(PlayerGui:GetChildren()) do
        if screen ~= ui.gui and screen:IsA("ScreenGui") and screen.Enabled then
            for _, obj in ipairs(screen:GetDescendants()) do
                scanned = scanned + 1
                if scanned % 150 == 0 then
                    task.wait()
                end

                if obj.Parent and obj:IsA("GuiObject") then
                    local byText = false
                    if obj:IsA("TextButton") or obj:IsA("TextLabel") then
                        local text = obj.Text
                        byText = #text <= 40 and cleanText(text) == "start"
                    end
                    local isButton = obj:IsA("GuiButton")
                    local byName = isButton and START_NAMES[string.lower(obj.Name)]
                    local isStartDungeonChild = isButton and obj.Parent.Name == "startDungeon"

                    if (byText or byName or isStartDungeonChild) and isShown(obj) then
                        return resolveClickable(obj)
                    end
                end
            end
        end
    end
    return nil
end

local function tryPressStart()
    if not Config.AutoStart then return false end
    if os.clock() < StartButton.giveUpUntil then return false end

    local now = os.clock()
    local button = StartButton.cache
    if not button or not button.Parent or not isShown(button) then
        StartButton.cache = nil
        if now - StartButton.lastScan < START_SCAN_INTERVAL then return false end
        StartButton.lastScan = now
        button = findStartButton()
        StartButton.cache = button
        if not button then
            StartButton.attempts = 0
            return false
        end
    end

    if now - StartButton.lastPress < START_RETRY_INTERVAL then return true end
    StartButton.lastPress = now
    StartButton.attempts = StartButton.attempts + 1

    if StartButton.attempts > 6 then
        StartButton.attempts = 0
        StartButton.cache = nil
        StartButton.giveUpUntil = now + 15
        return false
    end

    local center = button.AbsolutePosition + button.AbsoluteSize / 2
    if StartButton.attempts % 2 == 1 then
        center = center + GuiService:GetGuiInset()
    end
    local x, y = math.floor(center.X), math.floor(center.Y)

    pcall(function()
        VirtualInputManager:SendMouseMoveEvent(x - 8, y, game)
        task.wait(0.05)
        VirtualInputManager:SendMouseMoveEvent(x, y, game)
        task.wait(0.15)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.06)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)

    return true
end

-- ============================================================
-- COMBATE Y ESQUIVA INTELIGENTE
-- ============================================================
-- Offset por debajo del cual ya se considera que "volviste" y puedes atacar.
local function resumeOffset()
    return math.max(3, Config.DodgeExtraHeight * 0.25)
end

local function isDodging()
    return os.clock() < State.dodgeUntil or State.dodgeOffset > resumeOffset()
end

local function setStatus(text, kind)
    State.status = text
    State.statusKind = kind
end

-- >>> INICIO DEL BLOQUE DE ESQUIVA (V2.9) <<<
local DODGE_LEARN_RANGE = 120      -- distancia máxima a la que se aprende/predice un ataque
local DODGE_DEFAULT_RANGE = 80     -- rango por defecto para datos sin rango aprendido
local DODGE_RANGE_MARGIN = 1.3     -- margen sobre la distancia máxima observada al recibir daño
local DODGE_RANGE_PAD = 6
local DODGE_CLUSTER_TOL = 0.15     -- tolerancia (s) para agrupar golpes del mismo momento de la animación
local DODGE_CONFIRM_HITS = 2       -- golpes necesarios para confirmar un ataque
local DODGE_MAX_CLUSTERS = 8       -- momentos de golpe guardados por animación
local DODGE_STALE_SECONDS = 300    -- los candidatos sin confirmar se borran tras 5 min
local DODGE_DEBUG = true
local DODGE_FILE = "FabledAutofarm_dodge_v29.json"

local Dodge = {
    active = {},   -- [track] = { id, part }
    learned = {},  -- [animationId] = { { t, n, r, last }, ... }
    learnedCount = 0,
    watched = setmetatable({}, { __mode = "k" }),
    ping = 0, pingAt = 0,
}

function Dodge.recount()
    local count = 0
    for _, clusters in pairs(Dodge.learned) do
        for _, cluster in ipairs(clusters) do
            if cluster.n >= DODGE_CONFIRM_HITS then count = count + 1 end
        end
    end
    Dodge.learnedCount = count
end

local function loadDodge()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
    pcall(function()
        if not isfile(DODGE_FILE) then return end
        local data = HttpService:JSONDecode(readfile(DODGE_FILE))
        if type(data) == "table" then Dodge.learned = data end
    end)
    Dodge.recount()
end

local dodgeSaveQueued = false
local function saveDodge()
    if typeof(writefile) ~= "function" or dodgeSaveQueued then return end
    dodgeSaveQueued = true
    task.delay(2, function()
        dodgeSaveQueued = false
        pcall(function() writefile(DODGE_FILE, HttpService:JSONEncode(Dodge.learned)) end)
    end)
end
loadDodge()

function Dodge.reset()
    Dodge.learned = {}
    Dodge.recount()
    saveDodge()
end

local function isPassivePriority(track)
    local p = track.Priority
    return p == Enum.AnimationPriority.Idle or p == Enum.AnimationPriority.Movement
end

local function isActionPriority(track)
    local p = track.Priority
    return p == Enum.AnimationPriority.Action or p == Enum.AnimationPriority.Action2
        or p == Enum.AnimationPriority.Action3 or p == Enum.AnimationPriority.Action4
end

local function trackStarted(track, model)
    if track.Looped or isPassivePriority(track) then return end
    local animation = track.Animation
    local id = animation and animation.AnimationId
    if not id or id == "" then return end
    local part = getEnemyPart(model)
    if not part then return end
    Dodge.active[track] = { id = id, part = part }
    track.Stopped:Once(function() Dodge.active[track] = nil end)
end

function Dodge.watch(list)
    local now = os.clock()
    for index = 1, #list do
        local model = list[index].model
        local state = Dodge.watched[model]
        if state == nil or (type(state) == "number" and now >= state) then
            local humanoid = model:FindFirstChildOfClass("Humanoid")
            local animator = (humanoid and humanoid:FindFirstChildOfClass("Animator"))
                or model:FindFirstChildOfClass("Animator")
            if animator then
                Dodge.watched[model] = animator.AnimationPlayed:Connect(function(track)
                    trackStarted(track, model)
                end)
                for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                    trackStarted(track, model)
                end
            else
                Dodge.watched[model] = now + 2
            end
        end
    end
end

-- Aprende de un golpe recibido. Devuelve true si logró atribuirlo a alguna animación.
function Dodge.onDamage()
    local root = State.root
    if not root then return false end
    local rootPos = root.Position

    -- Candidatos: una muestra por animación (la del enemigo más cercano)
    local candidates = {}
    local anyAction = false
    for track, info in pairs(Dodge.active) do
        if track.IsPlaying and info.part.Parent then
            local dist = (info.part.Position - rootPos).Magnitude
            if dist <= DODGE_LEARN_RANGE then
                local action = isActionPriority(track)
                if action then anyAction = true end
                local current = candidates[info.id]
                if not current or dist < current.dist then
                    candidates[info.id] = { dist = dist, time = track.TimePosition, action = action }
                end
            end
        end
    end

    local attributed = false
    local nowT = os.time()
    for id, sample in pairs(candidates) do
        -- Si hay animaciones tipo "Action", ignora el resto (menos falsos positivos)
        if sample.action or not anyAction then
            attributed = true
            local clusters = Dodge.learned[id]
            if not clusters then clusters = {}; Dodge.learned[id] = clusters end

            -- Limpia candidatos viejos que nunca se confirmaron
            for i = #clusters, 1, -1 do
                local c = clusters[i]
                if c.n < DODGE_CONFIRM_HITS and c.last and nowT - c.last > DODGE_STALE_SECONDS then
                    table.remove(clusters, i)
                end
            end

            local matched = false
            for _, cluster in ipairs(clusters) do
                if math.abs(cluster.t - sample.time) <= DODGE_CLUSTER_TOL then
                    local weight = math.min(cluster.n, 8)
                    cluster.t = (cluster.t * weight + sample.time) / (weight + 1)
                    cluster.n = cluster.n + 1
                    cluster.r = math.max(cluster.r or 0, sample.dist)
                    cluster.last = nowT
                    matched = true
                    if DODGE_DEBUG and cluster.n == DODGE_CONFIRM_HITS then
                        print(string.format("[Fabled Autofarm] Ataque aprendido: %s @ %.2fs (rango ~%.0f)", id, cluster.t, cluster.r))
                    end
                    break
                end
            end
            if not matched then
                if #clusters >= DODGE_MAX_CLUSTERS then
                    local weakestN, weakestIndex = math.huge, nil
                    for i, c in ipairs(clusters) do
                        if c.n < weakestN then weakestN = c.n; weakestIndex = i end
                    end
                    if weakestIndex then table.remove(clusters, weakestIndex) end
                end
                table.insert(clusters, { t = sample.time, n = 1, r = sample.dist, last = nowT })
            end
        end
    end

    if attributed then
        Dodge.recount()
        saveDodge()
    end
    return attributed
end

function Dodge.update(now)
    local root = State.root
    if not root or not Config.DodgeEnabled then return end

    if now - Dodge.pingAt > 1 then
        Dodge.pingAt = now
        local ok, value = pcall(function() return LocalPlayer:GetNetworkPing() end)
        Dodge.ping = (ok and type(value) == "number") and math.clamp(value, 0, 0.4) or 0
    end
    local lead = Config.DodgeLead + Dodge.ping
    local tail = Config.DodgeTail
    local rootPos = root.Position

    for track, info in pairs(Dodge.active) do
        if not track.IsPlaying or not info.part.Parent then
            Dodge.active[track] = nil
        else
            local clusters = Dodge.learned[info.id]
            if clusters then
                local dist = (info.part.Position - rootPos).Magnitude
                if dist <= DODGE_LEARN_RANGE then
                    local speed = math.max(track.Speed, 0.05)
                    local position = track.TimePosition
                    for _, cluster in ipairs(clusters) do
                        if cluster.n >= DODGE_CONFIRM_HITS then
                            -- Solo esquiva si el enemigo está dentro del rango en el que ese golpe ya te alcanzó
                            local range = cluster.r
                                and math.min(cluster.r * DODGE_RANGE_MARGIN + DODGE_RANGE_PAD, DODGE_LEARN_RANGE)
                                or DODGE_DEFAULT_RANGE
                            if dist <= range then
                                local untilHit = (cluster.t - position) / speed
                                if untilHit <= lead and untilHit >= -tail then
                                    local untilClock = now + untilHit + tail
                                    if untilClock > State.dodgeUntil then
                                        if State.dodgeUntil <= now then State.dodges = State.dodges + 1 end
                                        State.dodgeUntil = untilClock
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function Dodge.destroy()
    for _, state in pairs(Dodge.watched) do
        if typeof(state) == "RBXScriptConnection" then pcall(function() state:Disconnect() end) end
    end
    table.clear(Dodge.watched)
    table.clear(Dodge.active)
end
-- >>> FIN DEL BLOQUE DE ESQUIVA <<<

local function canKeepAttacking(session)
    return State.running and State.session == session
        and (Config.AttackWhileDodging or not isDodging())
end

local function attack(session)
    if Config.UseSkillF then
        tapKey(Enum.KeyCode.F)
        task.wait(KEY_GAP_TIME)
        if not canKeepAttacking(session) then return end
    end
    if Config.UseSkillR then
        tapKey(Enum.KeyCode.R)
        task.wait(KEY_GAP_TIME)
        if not canKeepAttacking(session) then return end
    end
    if Config.UseClick then clickMouse() end
end

local function isGone(model)
    if not model:IsDescendantOf(workspace) then return true end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health <= 0
end

local function setTarget(enemy, part)
    local previous = State.target
    if enemy ~= previous then
        if previous and isGone(previous) then State.kills = State.kills + 1 end
        State.target = enemy
        State.targetHumanoid = enemy and enemy:FindFirstChildOfClass("Humanoid") or nil
    end
    State.targetPart = part
    if not enemy then State.hoverPos = nil end
end

local function farmStep(session)
    local root = State.root
    local humanoid = State.humanoid

    if not root or not root.Parent or not humanoid or humanoid.Health <= 0 then
        setTarget(nil, nil)
        State.candidates = 0
        setStatus("Esperando reaparición...", "waiting")
        return
    end

    if tryPressStart() then
        setStatus("Pulsando START...", "waiting")
        return
    end

    local enemy, part, count = findClosestEnemy(root.Position)
    State.candidates = count
    -- Se alimenta el sistema predictivo con los enemigos actuales
    if Config.DodgeEnabled then Dodge.watch(cache.list) end

    setTarget(enemy, part)

    if not enemy then
        setStatus("Buscando enemigos...", "searching")
    elseif isDodging() then
        setStatus("¡Esquivando!", "dodging")
        if Config.AttackWhileDodging then attack(session) end
    elseif UserInputService:GetFocusedTextBox() then
        setStatus("Pausado (escribiendo)", "waiting")
    else
        setStatus("Atacando", "attacking")
        attack(session)
    end
end

local function farmLoop(session)
    local lastWarning = 0
    while State.running and State.session == session do
        local ok, err = pcall(farmStep, session)
        if not ok and os.clock() - lastWarning > 2 then
            lastWarning = os.clock()
            warn("[Fabled Autofarm] " .. tostring(err))
        end
        task.wait(Config.AttackDelay)
    end
end

-- ============================================================
-- PERSONAJE Y VUELO
-- ============================================================
local function watchCharacter(character)
    if healthConnection then healthConnection:Disconnect(); healthConnection = nil end
    State.root = nil; State.humanoid = nil; State.hoverPos = nil; State.dodgeUntil = 0
    State.dodgeOffset = 0

    local humanoid = character:WaitForChild("Humanoid", 10)
    local rootPart = character:WaitForChild("HumanoidRootPart", 10)
    if not humanoid or not rootPart or LocalPlayer.Character ~= character then return end

    State.root = rootPart
    State.humanoid = humanoid
    lastHealth = humanoid.Health

    healthConnection = humanoid.HealthChanged:Connect(function(newHealth)
        local damage = lastHealth - newHealth
        lastHealth = newHealth
        if not (State.running and Config.DodgeEnabled) or damage <= 0 then return end
        if damage < humanoid.MaxHealth * DODGE_MIN_DAMAGE_PERCENT then return end

        -- Si el golpe se pudo atribuir a una animación, el sistema predictivo se encarga
        -- de los siguientes: basta una esquiva reactiva corta. Si no, se usa la duración de respaldo.
        local ok, attributed = pcall(Dodge.onDamage)
        local duration = Config.DodgeDuration
        if ok and attributed then duration = math.min(duration, DODGE_REACTIVE_MAX) end
        State.dodgeUntil = math.max(State.dodgeUntil, os.clock() + duration)
    end)
end

local lastHoverClock = os.clock()
local function hoverStep()
    pcall(function()
        local now = os.clock()
        local dt = math.min(now - lastHoverClock, 0.1)
        lastHoverClock = now

        local root, humanoid = State.root, State.humanoid
        if not root or not root.Parent or not humanoid or humanoid.Health <= 0 then return end

        local part = State.targetPart
        if part and part.Parent then
            State.hoverPos = part.Position + Vector3.new(0, Config.FlightHeight, 0)
        end

        -- Predicción de ataque
        Dodge.update(now)

        -- Altura de esquiva suavizada (sube casi al instante, baja rápido)
        local goal = (now < State.dodgeUntil) and Config.DodgeExtraHeight or 0
        local speed = (goal > State.dodgeOffset) and DODGE_RISE_SPEED or DODGE_FALL_SPEED
        State.dodgeOffset = State.dodgeOffset + (goal - State.dodgeOffset) * (1 - math.exp(-speed * dt))
        if goal == 0 and State.dodgeOffset < 0.05 then State.dodgeOffset = 0 end

        local hoverPos = State.hoverPos
        if not hoverPos then return end
        hoverPos = hoverPos + Vector3.new(0, State.dodgeOffset, 0)

        if hoverPos.X ~= hoverPos.X or hoverPos.Y ~= hoverPos.Y or hoverPos.Z ~= hoverPos.Z then
            return
        end

        root.CFrame = CFrame.new(hoverPos)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
end

-- ============================================================
-- CONTROL
-- ============================================================
local function startFarm()
    if State.running then return end
    State.running = true
    State.session = State.session + 1
    State.dodgeUntil = 0; State.dodgeOffset = 0
    setStatus("Buscando enemigos...", "searching")
    task.spawn(farmLoop, State.session)
end

local function stopFarm()
    if not State.running then return end
    State.running = false
    State.session = State.session + 1
    State.target = nil; State.targetPart = nil; State.targetHumanoid = nil; State.hoverPos = nil
    State.candidates = 0; State.dodgeUntil = 0; State.dodgeOffset = 0; cache.list = {}
    setStatus("Detenido", "stopped")
end

local function toggleFarm()
    if State.running then stopFarm() else startFarm() end
    if ui.refresh then ui.refresh() end
end

local function resetStats()
    State.kills = 0; State.runSeconds = 0
    State.dodges = 0; State.dodgeSeconds = 0
    if ui.refresh then ui.refresh() end
end

local function resetLearned()
    Dodge.reset()
    if ui.refresh then ui.refresh() end
end

local function unload()
    Dodge.destroy()
    State.running = false
    State.session = State.session + 1
    for _, connection in ipairs(connections) do pcall(function() connection:Disconnect() end) end
    table.clear(connections)
    if healthConnection then healthConnection:Disconnect(); healthConnection = nil end
    if ui.pulse then ui.pulse:Cancel() end
    if ui.gui then ui.gui:Destroy(); ui.gui = nil end
    sharedEnv.FabledAutofarm = nil
end

-- ============================================================
-- UI: TEMA Y UTILIDADES
-- ============================================================
local THEME = {
    Background = Color3.fromRGB(17, 19, 26), Surface = Color3.fromRGB(25, 28, 38),
    SurfaceAlt = Color3.fromRGB(34, 38, 51), Stroke = Color3.fromRGB(52, 58, 78),
    Accent = Color3.fromRGB(0, 170, 255), AccentDark = Color3.fromRGB(0, 98, 150),
    Violet = Color3.fromRGB(139, 108, 255), Success = Color3.fromRGB(46, 204, 113),
    SuccessButton = Color3.fromRGB(36, 168, 96), DangerButton = Color3.fromRGB(214, 69, 69),
    Warning = Color3.fromRGB(245, 176, 65), Text = Color3.fromRGB(236, 239, 246),
    TextDim = Color3.fromRGB(146, 154, 176), Muted = Color3.fromRGB(105, 112, 134),
}

local STATUS_COLORS = {
    stopped = THEME.Muted, searching = THEME.Warning, attacking = THEME.Success,
    dodging = THEME.Violet, waiting = THEME.Warning,
}

local TWEEN_FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_MEDIUM = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_PULSE = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

local activeTweens = setmetatable({}, { __mode = "k" })
local function tween(instance, info, properties)
    local previous = activeTweens[instance]
    if previous then previous:Cancel() end
    local newTween = TweenService:Create(instance, info, properties)
    activeTweens[instance] = newTween
    newTween:Play()
    return newTween
end

local function getViewport() return workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720) end
local function merge(base, extra) for key, value in pairs(extra) do base[key] = value end return base end
local function create(className, properties, parent)
    local instance = Instance.new(className)
    for property, value in pairs(properties) do instance[property] = value end
    if parent then instance.Parent = parent end
    return instance
end
local function round(instance, radius) return create("UICorner", { CornerRadius = UDim.new(0, radius) }, instance) end
local function outline(instance, color, thickness)
    return create("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = color or THEME.Stroke, Thickness = thickness or 1 }, instance)
end
local function pad(instance, top, right, bottom, left)
    return create("UIPadding", { PaddingTop = UDim.new(0, top), PaddingRight = UDim.new(0, right), PaddingBottom = UDim.new(0, bottom), PaddingLeft = UDim.new(0, left) }, instance)
end
local function makeLabel(parent, properties)
    return create("TextLabel", merge({ BackgroundTransparency = 1, BorderSizePixel = 0, Font = Enum.Font.Gotham, Text = "", TextColor3 = THEME.Text, TextSize = 12, TextTruncate = Enum.TextTruncate.AtEnd, TextXAlignment = Enum.TextXAlignment.Left }, properties), parent)
end
local function makeButton(parent, properties)
    return create("TextButton", merge({ AutoButtonColor = false, BackgroundColor3 = THEME.SurfaceAlt, BorderSizePixel = 0, Font = Enum.Font.GothamBold, Text = "", TextColor3 = THEME.Text, TextSize = 12 }, properties), parent)
end
local function attachButtonFeedback(button, getBaseColor)
    local hovering, pressed = false, false
    local function apply()
        local color = getBaseColor()
        if pressed then color = color:Lerp(Color3.new(0,0,0), 0.15)
        elseif hovering then color = color:Lerp(Color3.new(1,1,1), 0.1) end
        tween(button, TWEEN_FAST, { BackgroundColor3 = color })
    end
    bind(button.MouseEnter, function() hovering = true; apply() end)
    bind(button.MouseLeave, function() hovering = false; pressed = false; apply() end)
    bind(button.MouseButton1Down, function() pressed = true; apply() end)
    bind(button.MouseButton1Up, function() pressed = false; apply() end)
    return apply
end
local function attachTextHover(button, normalColor, hoverColor)
    bind(button.MouseEnter, function() tween(button, TWEEN_FAST, { TextColor3 = hoverColor }) end)
    bind(button.MouseLeave, function() tween(button, TWEEN_FAST, { TextColor3 = normalColor }) end)
end
local function setText(label, text) if label.Text ~= text then label.Text = text end end
local function formatTime(totalSeconds)
    local seconds = math.floor(totalSeconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    return hours > 0 and string.format("%d:%02d:%02d", hours, minutes, secs) or string.format("%02d:%02d", minutes, secs)
end

-- ============================================================
-- UI: COMPONENTES
-- ============================================================
local function makeSectionHeader(parent, order, text, actionText, onAction)
    local row = create("Frame", { BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.new(1, 0, 0, 14) }, parent)
    makeLabel(row, { Font = Enum.Font.GothamBold, Size = UDim2.new(0.6, 0, 1, 0), Text = text, TextColor3 = THEME.TextDim, TextSize = 10 })
    if actionText then
        local action = makeButton(row, { AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, Position = UDim2.new(1, 0, 0, 0), Size = UDim2.new(0.4, 0, 1, 0), Text = actionText, TextColor3 = THEME.Accent, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Right })
        attachTextHover(action, THEME.Accent, THEME.Text)
        bind(action.Activated, onAction)
    end
    return row
end

local function makeStat(parent, order, caption)
    local card = create("Frame", { BackgroundColor3 = THEME.Surface, BorderSizePixel = 0, LayoutOrder = order }, parent)
    round(card, 10); outline(card)
    local value = makeLabel(card, { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 22), Text = "0", TextSize = 18 })
    makeLabel(card, { Font = Enum.Font.GothamMedium, Position = UDim2.fromOffset(10, 29), Size = UDim2.new(1, -20, 0, 14), Text = caption, TextColor3 = THEME.TextDim, TextSize = 10 })
    return value
end

local function makeChip(parent, order, text, key)
    local function getBase() return Config[key] and THEME.AccentDark or THEME.SurfaceAlt end
    local chip = makeButton(parent, { BackgroundColor3 = getBase(), LayoutOrder = order, Name = key, Text = text, TextSize = 11 })
    round(chip, 8)
    local stroke = outline(chip)
    local feedback = attachButtonFeedback(chip, getBase)
    local function render()
        local enabled = Config[key]
        chip.TextColor3 = enabled and THEME.Text or THEME.TextDim
        tween(stroke, TWEEN_FAST, { Color = enabled and THEME.Accent or THEME.Stroke })
        feedback()
    end
    render()
    bind(chip.Activated, function()
        Config[key] = not Config[key]
        render()
        saveConfig()
    end)
end

local function makeStepper(parent, order, labelText, key)
    local limit = LIMITS[key]
    local cell = create("Frame", { BackgroundTransparency = 1, LayoutOrder = order }, parent)
    makeLabel(cell, { Font = Enum.Font.GothamMedium, Size = UDim2.new(1, 0, 0, 14), Text = labelText, TextColor3 = THEME.TextDim, TextSize = 11 })
    local row = create("Frame", { BackgroundColor3 = THEME.SurfaceAlt, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 18), Size = UDim2.new(1, 0, 0, 28) }, cell)
    round(row, 8); outline(row)
    local minus = makeButton(row, { BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 28), Text = "-", TextColor3 = THEME.TextDim, TextSize = 16 })
    local plus = makeButton(row, { AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(28, 28), Text = "+", TextColor3 = THEME.TextDim, TextSize = 16 })
    local box = create("TextBox", { BackgroundTransparency = 1, ClearTextOnFocus = false, Font = Enum.Font.GothamMedium, Position = UDim2.fromOffset(28, 0), Size = UDim2.new(1, -56, 1, 0), Text = formatNumber(Config[key]), TextColor3 = THEME.Text, TextSize = 13 }, row)
    attachTextHover(minus, THEME.TextDim, THEME.Accent); attachTextHover(plus, THEME.TextDim, THEME.Accent)

    local function apply(value)
        value = clampSetting(key, value)
        Config[key] = value
        box.Text = formatNumber(value)
        saveConfig()
    end
    bind(minus.Activated, function() apply(Config[key] - limit.step) end)
    bind(plus.Activated, function() apply(Config[key] + limit.step) end)
    bind(box.FocusLost, function()
        local value = tonumber(box.Text)
        if value then apply(value) else box.Text = formatNumber(Config[key]) end
    end)
end

local function makeDraggable(handle, frame)
    local dragging, dragStart, startPosition = false, Vector2.zero, UDim2.new()
    bind(handle.InputBegan, function(input)
        local inputType = input.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = Vector2.new(input.Position.X, input.Position.Y); startPosition = frame.Position
        end
    end)
    bind(UserInputService.InputChanged, function(input)
        if not dragging then return end
        local inputType = input.UserInputType
        if inputType == Enum.UserInputType.MouseMovement or inputType == Enum.UserInputType.Touch then
            local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStart
            local viewport = getViewport()
            local x = math.clamp(startPosition.X.Offset + delta.X, 60 - frame.AbsoluteSize.X, viewport.X - 60)
            local y = math.clamp(startPosition.Y.Offset + delta.Y, 0, viewport.Y - HEADER_HEIGHT)
            frame.Position = UDim2.fromOffset(x, y)
        end
    end)
    bind(UserInputService.InputEnded, function(input)
        local inputType = input.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then dragging = false end
    end)
end

-- ============================================================
-- UI: VENTANA PRINCIPAL
-- ============================================================
local function buildUI()
    local viewport = getViewport()
    local width = math.clamp(viewport.X - 24, 260, WINDOW_WIDTH)
    local gui = create("ScreenGui", { DisplayOrder = 50, IgnoreGuiInset = true, Name = GUI_NAME, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, PlayerGui)
    ui.gui = gui

    local window = create("Frame", { Active = true, AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = THEME.Background, BorderSizePixel = 0, Name = "Window", Position = UDim2.fromOffset(math.floor((viewport.X - width) / 2), math.floor(viewport.Y * 0.12)), Size = UDim2.fromOffset(width, HEADER_HEIGHT) }, gui)
    round(window, 12)
    local border = outline(window, Color3.new(1, 1, 1), 1.5)
    create("UIGradient", { Color = ColorSequence.new(THEME.Accent, THEME.Violet), Rotation = 45 }, border)
    create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, window)
    ui.window = window

    local header = create("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = 1, Name = "Header", Size = UDim2.new(1, 0, 0, HEADER_HEIGHT) }, window)
    makeLabel(header, { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(14, 7), Size = UDim2.new(1, -90, 0, 18), Text = "⚔️ Fabled Autofarm", TextSize = 15 })
    makeLabel(header, { Position = UDim2.fromOffset(14, 25), Size = UDim2.new(1, -90, 0, 14), Text = "Smart Dodge · v" .. VERSION, TextColor3 = THEME.TextDim, TextSize = 11 })
    create("Frame", { BackgroundColor3 = THEME.Stroke, BorderSizePixel = 0, Name = "Divider", Position = UDim2.new(0, 12, 1, -1), Size = UDim2.new(1, -24, 0, 1) }, header)

    local minimizeButton = makeButton(header, { AnchorPoint = Vector2.new(1, 0.5), Name = "Minimize", Position = UDim2.new(1, -42, 0.5, 0), Size = UDim2.fromOffset(26, 26), Text = "-", TextSize = 16 })
    round(minimizeButton, 8); attachButtonFeedback(minimizeButton, function() return THEME.SurfaceAlt end)
    local closeButton = makeButton(header, { AnchorPoint = Vector2.new(1, 0.5), Name = "Close", Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(26, 26), Text = "×", TextSize = 18 })
    round(closeButton, 8); attachButtonFeedback(closeButton, function() return THEME.SurfaceAlt end)
    ui.minimizeButton = minimizeButton

    local body = create("ScrollingFrame", { AutomaticCanvasSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, BorderSizePixel = 0, CanvasSize = UDim2.new(), ElasticBehavior = Enum.ElasticBehavior.Never, LayoutOrder = 2, Name = "Body", ScrollBarImageColor3 = THEME.Stroke, ScrollBarThickness = 3, ScrollingDirection = Enum.ScrollingDirection.Y, Size = UDim2.new(1, 0, 0, 0) }, window)
    pad(body, 10, 12, 12, 12)
    local list = create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, body)
    ui.body = body; ui.list = list

    local statusRow = create("Frame", { BackgroundTransparency = 1, LayoutOrder = 1, Name = "StatusRow", Size = UDim2.new(1, 0, 0, 18) }, body)
    local dot = create("Frame", { AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = STATUS_COLORS.stopped, BorderSizePixel = 0, Name = "Dot", Position = UDim2.new(0, 2, 0.5, 0), Size = UDim2.fromOffset(10, 10) }, statusRow)
    round(dot, 5)
    ui.statusDot = dot
    ui.pulse = TweenService:Create(dot, TWEEN_PULSE, { BackgroundTransparency = 0.6 })
    ui.statusLabel = makeLabel(statusRow, { Font = Enum.Font.GothamMedium, Position = UDim2.fromOffset(20, 0), Size = UDim2.new(1, -20, 1, 0), Text = State.status })

    local mainButton = makeButton(body, { BackgroundColor3 = THEME.SuccessButton, LayoutOrder = 2, Name = "ToggleButton", Size = UDim2.new(1, 0, 0, 40), Text = "INICIAR AUTOFARM", TextSize = 14 })
    round(mainButton, 10)
    ui.mainButton = mainButton
    ui.mainFeedback = attachButtonFeedback(mainButton, function() return State.running and THEME.DangerButton or THEME.SuccessButton end)
    bind(mainButton.Activated, toggleFarm)

    local card = create("Frame", { BackgroundColor3 = THEME.Surface, BorderSizePixel = 0, LayoutOrder = 3, Name = "TargetCard", Size = UDim2.new(1, 0, 0, 62) }, body)
    round(card, 10); outline(card)
    makeLabel(card, { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(10, 8), Size = UDim2.new(0.5, -10, 0, 12), Text = "OBJETIVO", TextColor3 = THEME.TextDim, TextSize = 10 })
    ui.candidatesLabel = makeLabel(card, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8), Size = UDim2.new(0.5, -10, 0, 12), Text = "0 candidatos", TextColor3 = THEME.TextDim, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Right })
    ui.targetName = makeLabel(card, { Font = Enum.Font.GothamBold, Position = UDim2.fromOffset(10, 22), Size = UDim2.new(1, -64, 0, 18), Text = "Ninguno", TextColor3 = THEME.TextDim, TextSize = 14 })
    ui.targetHp = makeLabel(card, { AnchorPoint = Vector2.new(1, 0), Font = Enum.Font.Code, Position = UDim2.new(1, -10, 0, 23), Size = UDim2.fromOffset(44, 16), Text = "", TextColor3 = THEME.TextDim, TextXAlignment = Enum.TextXAlignment.Right })
    local hpTrack = create("Frame", { BackgroundColor3 = THEME.SurfaceAlt, BorderSizePixel = 0, Name = "HpTrack", Position = UDim2.new(0, 10, 0, 46), Size = UDim2.new(1, -20, 0, 8) }, card)
    round(hpTrack, 4)
    ui.hpFill = create("Frame", { BackgroundColor3 = THEME.Success, BorderSizePixel = 0, Name = "HpFill", Size = UDim2.fromScale(0, 1) }, hpTrack)
    round(ui.hpFill, 4)

    makeSectionHeader(body, 4, "ESTADÍSTICAS", "Reiniciar", resetStats)
    local statsRow = create("Frame", { BackgroundTransparency = 1, LayoutOrder = 5, Name = "Stats", Size = UDim2.new(1, 0, 0, 50) }, body)
    create("UIGridLayout", { CellPadding = UDim2.fromOffset(9, 0), CellSize = UDim2.new(1 / 3, -6, 1, 0), SortOrder = Enum.SortOrder.LayoutOrder }, statsRow)
    ui.killsLabel = makeStat(statsRow, 1, "KILLS")
    ui.timeLabel = makeStat(statsRow, 2, "TIEMPO")
    ui.kpmLabel = makeStat(statsRow, 3, "KILLS/MIN")

    makeSectionHeader(body, 6, "COMBATE", "Borrar aprendido", resetLearned)
    local chipsRow = create("Frame", { BackgroundTransparency = 1, LayoutOrder = 7, Name = "Chips", Size = UDim2.new(1, 0, 0, 66) }, body)
    create("UIGridLayout", { CellPadding = UDim2.fromOffset(6, 6), CellSize = UDim2.new(0.25, -5, 0, 30), SortOrder = Enum.SortOrder.LayoutOrder }, chipsRow)
    makeChip(chipsRow, 1, "Esquiva", "DodgeEnabled")
    makeChip(chipsRow, 2, "Skill F", "UseSkillF")
    makeChip(chipsRow, 3, "Skill R", "UseSkillR")
    makeChip(chipsRow, 4, "Click", "UseClick")
    makeChip(chipsRow, 5, "Start", "AutoStart")
    makeChip(chipsRow, 6, "Anti-AFK", "AntiAFK")
    makeChip(chipsRow, 7, "Atk+Esq", "AttackWhileDodging")

    ui.dodgeInfo = makeLabel(body, { LayoutOrder = 8, Name = "DodgeInfo", Size = UDim2.new(1, 0, 0, 14), Text = "", TextColor3 = THEME.TextDim, TextSize = 10 })

    makeSectionHeader(body, 9, "AJUSTES")
    local grid = create("Frame", { BackgroundTransparency = 1, LayoutOrder = 10, Name = "Settings", Size = UDim2.new(1, 0, 0, 4 * 46 + 3 * 6) }, body)
    create("UIGridLayout", { CellPadding = UDim2.fromOffset(8, 6), CellSize = UDim2.new(0.5, -4, 0, 46), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
    makeStepper(grid, 1, "Altura base", "FlightHeight")
    makeStepper(grid, 2, "Extra esquiva", "DodgeExtraHeight")
    makeStepper(grid, 3, "Anticipación (s)", "DodgeLead")
    makeStepper(grid, 4, "Cola esquiva (s)", "DodgeTail")
    makeStepper(grid, 5, "Esquiva respaldo (s)", "DodgeDuration")
    makeStepper(grid, 6, "Delay de ataque", "AttackDelay")
    makeStepper(grid, 7, "Radio de escaneo", "ScanRadius")

    makeLabel(body, { LayoutOrder = 11, Name = "Footer", Size = UDim2.new(1, 0, 0, 14), Text = HOTKEY_TOGGLE_FARM.Name .. ": iniciar/detener  ·  " .. HOTKEY_TOGGLE_UI.Name .. ": ocultar UI", TextColor3 = THEME.Muted, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Center })

    makeDraggable(header, window)
    bind(closeButton.Activated, unload)
    bind(minimizeButton.Activated, function()
        State.minimized = not State.minimized
        minimizeButton.Text = State.minimized and "+" or "-"
        ui.relayout(true)
    end)
    bind(list:GetPropertyChangedSignal("AbsoluteContentSize"), function() ui.relayout(false) end)
    local camera = workspace.CurrentCamera
    if camera then bind(camera:GetPropertyChangedSignal("ViewportSize"), function() ui.relayout(false) end) end
end

function ui.relayout(animated)
    local body, list = ui.body, ui.list
    if not body or not list then return end
    local contentHeight = list.AbsoluteContentSize.Y + BODY_PADDING_Y
    local maxHeight = math.max(120, getViewport().Y * 0.9 - HEADER_HEIGHT)
    local height = State.minimized and 0 or math.min(contentHeight, maxHeight)
    local size = UDim2.new(1, 0, 0, height)
    if not State.minimized then body.Visible = true end
    if animated then
        local sizeTween = tween(body, TWEEN_MEDIUM, { Size = size })
        if State.minimized then sizeTween.Completed:Once(function() if State.minimized then body.Visible = false end end) end
    else
        body.Size = size
        body.Visible = not State.minimized
    end
end

function ui.refresh()
    pcall(function()
        local gui = ui.gui
        if not gui or not gui.Parent then return end
        local running = State.running
        if running ~= ui.shownRunning then
            ui.shownRunning = running
            ui.mainButton.Text = running and "DETENER AUTOFARM" or "INICIAR AUTOFARM"
            ui.mainFeedback()
            if running then ui.pulse:Play() else ui.pulse:Cancel(); ui.statusDot.BackgroundTransparency = 0 end
        end
        local kind = State.statusKind
        if kind ~= ui.shownKind then
            ui.shownKind = kind
            tween(ui.statusDot, TWEEN_FAST, { BackgroundColor3 = STATUS_COLORS[kind] })
        end
        setText(ui.statusLabel, State.status)

        local name = "Ninguno"
        local nameColor = THEME.TextDim
        local fraction, percentText, fillColor = 0, "", THEME.Success

        local target = State.target
        if target then
            name = target.Name; nameColor = THEME.Text
            local humanoid = State.targetHumanoid
            if humanoid and humanoid.Parent then
                fraction = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
                percentText = string.format("%d%%", math.floor(fraction * 100 + 0.5))
                fillColor = Color3.fromHSV(fraction * 0.33, 0.75, 0.95)
            else
                fraction = 1; percentText = "--"; fillColor = THEME.Accent
            end
        elseif running then name = "Sin objetivo · muévete por la mazmorra" end

        setText(ui.targetName, name)
        ui.targetName.TextColor3 = nameColor
        setText(ui.targetHp, percentText)
        if fraction ~= ui.shownFraction then
            ui.shownFraction = fraction
            ui.hpFill.Size = UDim2.fromScale(fraction, 1)
            ui.hpFill.BackgroundColor3 = fillColor
        end
        setText(ui.candidatesLabel, State.candidates == 1 and "1 candidato" or (State.candidates .. " candidatos"))
        setText(ui.killsLabel, tostring(State.kills))
        setText(ui.timeLabel, formatTime(State.runSeconds))
        local minutes = State.runSeconds / 60
        setText(ui.kpmLabel, string.format("%.1f", minutes > 0.05 and State.kills / minutes or 0))

        local airPercent = State.runSeconds > 1 and (State.dodgeSeconds / State.runSeconds * 100) or 0
        setText(ui.dodgeInfo, string.format("Aprendidos %d · Esquivas %d · Esquivando %d%% del tiempo",
            Dodge.learnedCount, State.dodges, math.floor(airPercent + 0.5)))
    end)
end

-- ============================================================
-- ARRANQUE
-- ============================================================
pcall(buildUI)

local uiClock = 0
bind(RunService.Heartbeat, function(dt)
    pcall(function()
        if State.running then
            State.runSeconds = State.runSeconds + dt
            if os.clock() < State.dodgeUntil or State.dodgeOffset > 0.5 then
                State.dodgeSeconds = State.dodgeSeconds + dt
            end
            hoverStep()
        end
        uiClock = uiClock + dt
        if uiClock >= UI_REFRESH_INTERVAL then uiClock = 0; ui.refresh() end
    end)
end)

bind(UserInputService.InputBegan, function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == HOTKEY_TOGGLE_FARM then
        toggleFarm()
    elseif input.KeyCode == HOTKEY_TOGGLE_UI and ui.gui then
        ui.gui.Enabled = not ui.gui.Enabled
    end
end)

-- Anti-AFK: evita la expulsión por inactividad (~20 min)
bind(LocalPlayer.Idled, function()
    if not Config.AntiAFK then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

bind(LocalPlayer.CharacterAdded, function(character) task.spawn(watchCharacter, character) end)
if LocalPlayer.Character then task.spawn(watchCharacter, LocalPlayer.Character) end

sharedEnv.FabledAutofarm = { Version = VERSION, Start = startFarm, Stop = stopFarm, Unload = unload }

ui.refresh()
print(string.format("✅ Fabled Autofarm v%s (Smart Dodge) cargado · %s: iniciar/detener · %s: ocultar UI", VERSION, HOTKEY_TOGGLE_FARM.Name, HOTKEY_TOGGLE_UI.Name))