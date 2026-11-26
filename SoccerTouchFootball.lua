--[[
  Soccer: Touch Football - WindUI hub
  PlaceId taken from the URL you gave: 16447934574

  STATUS: written without access to the game, an executor or a Luau compiler.
          Nothing here has been run.

  UNKNOWN game data (nothing is invented; set these from the Setup tab or below):
    - the ball object             -> heuristic scan, or Setup > "Ball object path"
    - goal A / goal B positions   -> Setup > "Set Goal A/B = my position", or object paths
    - how the server registers a kick (touch vs remote) -> verify with "Print status"
    - real units of the game's own "power" stat -> Power here is ball speed in studs/s
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local VirtualUser = game:GetService("VirtualUser")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then return end

local ENV = (type(getgenv) == "function" and getgenv()) or _G
if type(ENV.__STF_UNLOAD) == "function" then pcall(ENV.__STF_UNLOAD) end

----------------------------------------------------------------------
-- Config: game-specific values. nil = unknown / unset.
----------------------------------------------------------------------
local GameConfig = {
    ExpectedPlaceId = 16447934574, -- source: the URL you gave
    BallPath = nil,                -- UNKNOWN, e.g. "Workspace.SomeFolder.Ball"
    GoalAPath = nil,               -- UNKNOWN
    GoalBPath = nil,               -- UNKNOWN
    BallGravityScale = 1.0,        -- UNCALIBRATED: 1 = plain workspace gravity on the ball
}

-- Design values chosen by me, all UNCALIBRATED except POWER_MAX (your number).
local POWER_MAX = 145
local CURVE_DEG_PER_SEC_PER_LEVEL = 6   -- plain curve: level 15 -> 90 deg/s of turning
local CURVE_AIM_DEG_PER_LEVEL = 4       -- goal curve: level 15 -> 60 deg total bend
local GOAL_REACHED_DIST = 4
local JUGGLE_RANGE = 7
local JUGGLE_COOLDOWN = 0.28
local JUGGLE_TRIGGER_REL_Y = -0.5
local PRED_STEPS = 24
local BALL_KEYWORDS = { "ball", "football", "soccer" } -- heuristic only
local SAVE_FOLDER = "SoccerTouchFootball"

local KEYS = {
    ToggleUI = Enum.KeyCode.RightShift,
    GoalA = Enum.KeyCode.Z,
    GoalB = Enum.KeyCode.X,
    GoalAuto = Enum.KeyCode.C,
}

-- "Sneaky" / "Sneaky v2" are not standard hub features; these are humanized presets.
local PRESETS = {
    Sneaky   = { reach = 6,  powerMin = 0.88, powerMax = 1.00, errDeg = 2.0, delayMin = 0.02, delayMax = 0.08 },
    SneakyV2 = { reach = 10, powerMin = 0.95, powerMax = 1.00, errDeg = 1.0, delayMin = 0.01, delayMax = 0.04 },
}

----------------------------------------------------------------------
-- Pure math (no Roblox types)
----------------------------------------------------------------------
local function clamp(x, lo, hi)
    if x < lo then return lo elseif x > hi then return hi end
    return x
end

local function hypot2(x, z) return math.sqrt(x * x + z * z) end

local function isFinite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

local function isFiniteVec(v)
    return isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)
end

-- Heading = angle from +Z toward +X. Increasing heading turns LEFT when facing +Z
-- (Roblox: RightVector = Look x Up, so +X is on the left of a body facing +Z).
local function headingOf(x, z) return math.atan2(x, z) end

local function ballisticVy(y0, targetY, dist, hSpeed, g)
    if hSpeed < 1e-3 then return 0 end
    local t = dist / hSpeed
    if t < 1e-3 then return 0 end
    return (targetY - y0 + 0.5 * g * t * t) / t
end

local function launchVelocity(heading, speed, vyWanted, maxLiftDeg)
    local vyMax = math.tan(math.rad(maxLiftDeg)) * speed
    local vy = clamp(vyWanted, -speed * 0.5, vyMax)
    local hs = math.sqrt(math.max(speed * speed - vy * vy, 0))
    return math.sin(heading) * hs, vy, math.cos(heading) * hs
end

-- Bend toward the goal shrinks linearly with the remaining distance, so the ball
-- starts offset to one side and finishes pointing straight at the goal.
local function curveAimHeading(px, pz, gx, gz, d0, alpha0, sgn)
    local dx, dz = gx - px, gz - pz
    local d = hypot2(dx, dz)
    local phi = headingOf(dx, dz)
    local frac = (d0 > 1e-3) and clamp(d / d0, 0, 1) or 0
    return phi - sgn * (alpha0 * frac) / 2, d
end

local function sideSign(side)
    if side == "Left" then return 1 elseif side == "Right" then return -1 end
    return (math.random() < 0.5) and 1 or -1
end

----------------------------------------------------------------------
-- Settings, goals, persistence
----------------------------------------------------------------------
local Settings = {
    Enabled = true,
    PowerShot = false, Power = 145,
    AimAssist = false, LookFov = 12, LookMaxDist = 250, TargetFilter = "Anyone",
    LeadTargets = true, MaxLiftDeg = 10,
    GoalAimbot = false, GoalSelect = "Auto (facing)",
    Curve = false, CurveLevel = 5, CurveSide = "Left", CurveTime = 1.2,
    CurveAim = false, CurveAimLevel = 8,
    Reach = false, ReachDist = 8,
    Juggle = false, JuggleHeight = 4,
    Sneaky = false, SneakyV2 = false,
    PlayerESP = true, BallESP = true, BallTracer = false, Prediction = false,
    AntiAFK = true,
    ApplyDelay = 0.03, HoldTime = 0.12, Cooldown = 0.35,
    BallPath = "", GoalAPath = "", GoalBPath = "",
}

local Goals = { A = nil, B = nil } -- Vector3, set by calibration

local function savePath() return SAVE_FOLDER .. "/" .. tostring(game.PlaceId) .. ".json" end

local function fsOk()
    return type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
end

local function saveAll()
    if not fsOk() then return false, "writefile/readfile/isfile not available in this executor" end
    pcall(function()
        if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(SAVE_FOLDER) then
            makefolder(SAVE_FOLDER)
        end
    end)
    local goals = {}
    for k, v in pairs(Goals) do goals[k] = { v.X, v.Y, v.Z } end
    return pcall(function()
        writefile(savePath(), HttpService:JSONEncode({ settings = Settings, goals = goals }))
    end)
end

local function loadAll()
    if not fsOk() then return end
    local okExists, exists = pcall(isfile, savePath())
    if not okExists or not exists then return end
    local ok, data = pcall(function() return HttpService:JSONDecode(readfile(savePath())) end)
    if not ok or type(data) ~= "table" then return end
    if type(data.settings) == "table" then
        for k, v in pairs(data.settings) do
            if Settings[k] ~= nil and type(v) == type(Settings[k]) then Settings[k] = v end
        end
    end
    if type(data.goals) == "table" then
        for _, k in ipairs({ "A", "B" }) do
            local g = data.goals[k]
            if type(g) == "table" and isFinite(g[1]) and isFinite(g[2]) and isFinite(g[3]) then
                Goals[k] = Vector3.new(g[1], g[2], g[3])
            end
        end
    end
end

loadAll()

----------------------------------------------------------------------
-- Notifications / logging
----------------------------------------------------------------------
local WindUI = nil
local Window = nil

local function say(...) print("[STF]", ...) end

local function notify(title, content, duration)
    if not WindUI then return end
    pcall(function()
        WindUI:Notify({ Title = title, Content = content, Duration = duration or 3 })
    end)
end

local warned = {}
local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    warn("[STF] " .. msg)
    notify("Touch Football Hub", msg, 5)
end

local lastErrAt = {}
local function logErr(key, err)
    local now = os.clock()
    if lastErrAt[key] and now - lastErrAt[key] < 5 then return end
    lastErrAt[key] = now
    warn("[STF] " .. key .. " error: " .. tostring(err))
end

local conns = {}
local function track(c) conns[#conns + 1] = c return c end

----------------------------------------------------------------------
-- Instance helpers
----------------------------------------------------------------------
local function resolvePath(path)
    if type(path) ~= "string" or path == "" then return nil end
    local cur = game
    local first = true
    for seg in string.gmatch(path, "[^%.]+") do
        if not (first and seg == "game") then
            cur = cur:FindFirstChild(seg)
            if not cur then return nil end
        end
        first = false
    end
    return cur
end

local function positionOf(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.Position end
    if inst:IsA("Model") then
        local ok, cf = pcall(function() return inst:GetBoundingBox() end)
        if ok and cf then return cf.Position end
    end
    return nil
end

local function myRoot()
    local ch = LocalPlayer.Character
    return ch and ch:FindFirstChild("HumanoidRootPart"), ch
end

local function inAnyCharacter(p)
    for _, plr in ipairs(Players:GetPlayers()) do
        local ch = plr.Character
        if ch and p:IsDescendantOf(ch) then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Ball resolver
----------------------------------------------------------------------
local Ball = { part = nil, touched = nil, lastScan = 0 }
local onTouch -- assigned below

local function nameLooksLikeBall(p)
    local n = string.lower(p.Name)
    for _, kw in ipairs(BALL_KEYWORDS) do
        if string.find(n, kw, 1, true) then return true end
    end
    return false
end

local function ballScore(p, fromPos)
    if p.Anchored then return nil end
    local s = p.Size
    local mx, mn = math.max(s.X, s.Y, s.Z), math.min(s.X, s.Y, s.Z)
    if mx > 12 or mx < 0.8 then return nil end
    local round = (mx - mn) / mx < 0.12
    local isBallShape = p:IsA("Part") and p.Shape == Enum.PartType.Ball
    local named = nameLooksLikeBall(p)
    if not (named or isBallShape or round) then return nil end
    if inAnyCharacter(p) then return nil end
    local score = 0
    if named then score = score + 100 end
    if isBallShape then score = score + 30 end
    if round then score = score + 10 end
    if fromPos then score = score - (p.Position - fromPos).Magnitude * 0.01 end
    return score
end

local function scanBalls()
    local root = myRoot()
    local fromPos = root and root.Position
    local list = {}
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("BasePart") then
            local sc = ballScore(inst, fromPos)
            if sc then list[#list + 1] = { part = inst, score = sc } end
        end
    end
    table.sort(list, function(a, b) return a.score > b.score end)
    return list
end

local function setBall(part)
    if Ball.touched then pcall(function() Ball.touched:Disconnect() end) Ball.touched = nil end
    Ball.part = part
    if part then
        Ball.touched = part.Touched:Connect(function(hit)
            local ch = LocalPlayer.Character
            if ch and hit:IsDescendantOf(ch) then onTouch("touched") end
        end)
    end
end

local function getBall()
    local p = Ball.part
    if p and p.Parent then return p end
    if p then setBall(nil) end
    local now = os.clock()
    if now - Ball.lastScan < 2 then return nil end
    Ball.lastScan = now
    local path = (Settings.BallPath ~= "" and Settings.BallPath) or GameConfig.BallPath
    if path then
        local inst = resolvePath(path)
        if inst and inst:IsA("Model") then inst = inst.PrimaryPart end
        if inst and inst:IsA("BasePart") then setBall(inst) return inst end
        warnOnce("ballpath", "Ball path '" .. path .. "' did not resolve to a part.")
        return nil
    end
    local list = scanBalls()
    if list[1] then setBall(list[1].part) return list[1].part end
    return nil
end

----------------------------------------------------------------------
-- Goals
----------------------------------------------------------------------
local function goalPathFor(key)
    if key == "A" then return (Settings.GoalAPath ~= "" and Settings.GoalAPath) or GameConfig.GoalAPath end
    return (Settings.GoalBPath ~= "" and Settings.GoalBPath) or GameConfig.GoalBPath
end

local function goalPos(key)
    if Goals[key] then return Goals[key] end
    local path = goalPathFor(key)
    if path then return positionOf(resolvePath(path)) end
    return nil
end

local function pickGoal()
    local sel = Settings.GoalSelect
    if sel == "Goal A" then return "A", goalPos("A") end
    if sel == "Goal B" then return "B", goalPos("B") end
    local a, b = goalPos("A"), goalPos("B")
    if a and not b then return "A", a end
    if b and not a then return "B", b end
    if not a and not b then return nil, nil end
    local cam = Workspace.CurrentCamera
    if not cam then return "A", a end
    local look, origin = cam.CFrame.LookVector, cam.CFrame.Position
    local function facing(g)
        local dx, dz = g.X - origin.X, g.Z - origin.Z
        local m = hypot2(dx, dz)
        if m < 1e-3 then return -1 end
        return (look.X * dx + look.Z * dz) / m
    end
    if facing(a) >= facing(b) then return "A", a end
    return "B", b
end

----------------------------------------------------------------------
-- Look target
----------------------------------------------------------------------
local function passesFilter(plr)
    local f = Settings.TargetFilter
    if f == "Anyone" then return true end
    local a, b = LocalPlayer.Team, plr.Team
    if a == nil or b == nil then
        warnOnce("team", "Player.Team is nil here, so Teammates/Enemies cannot be told apart; treating everyone as valid.")
        return true
    end
    local same = (a == b)
    if f == "Teammates" then return same end
    return not same
end

local function getLookTarget()
    local cam = Workspace.CurrentCamera
    if not cam then return nil end
    local origin, look = cam.CFrame.Position, cam.CFrame.LookVector
    local best, bestAng
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local ch = plr.Character
            local hum = ch and ch:FindFirstChildOfClass("Humanoid")
            local root = ch and ch:FindFirstChild("HumanoidRootPart")
            if hum and root and hum.Health > 0 and passesFilter(plr) then
                local to = root.Position - origin
                local dist = to.Magnitude
                if dist > 0.5 and dist <= Settings.LookMaxDist then
                    local ang = math.deg(math.acos(clamp(look:Dot(to / dist), -1, 1)))
                    if ang <= Settings.LookFov and (not bestAng or ang < bestAng) then
                        best, bestAng = plr, ang
                    end
                end
            end
        end
    end
    return best
end

local function feetOffset(hum, root)
    if hum.RigType == Enum.HumanoidRigType.R6 then return 2 + root.Size.Y / 2 end
    return hum.HipHeight + root.Size.Y / 2
end

----------------------------------------------------------------------
-- Shot engine
----------------------------------------------------------------------
local ShotState = nil
local lastShotAt = -1e9

local function presetNow()
    if Settings.SneakyV2 then return PRESETS.SneakyV2 end
    if Settings.Sneaky then return PRESETS.Sneaky end
    return nil
end

local function chooseSpeed(ball, preset)
    local cap = clamp(Settings.Power, 1, POWER_MAX)
    local measured = ball.AssemblyLinearVelocity.Magnitude
    local speed
    if Settings.PowerShot then
        speed = cap
    elseif isFinite(measured) and measured >= 8 then
        speed = math.min(measured, POWER_MAX)
    else
        speed = cap
    end
    if preset then
        speed = speed * (preset.powerMin + (preset.powerMax - preset.powerMin) * math.random())
    end
    return math.min(speed, POWER_MAX)
end

local function doShot()
    local ball = Ball.part
    if not (ball and ball.Parent) then return end
    local root, ch = myRoot()
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if not (root and hum and hum.Health > 0) then return end

    local preset = presetNow()
    local g = Workspace.Gravity * GameConfig.BallGravityScale
    local P = ball.Position
    local cur = ball.AssemblyLinearVelocity
    if not (isFiniteVec(P) and isFiniteVec(cur)) then return end
    local speed = chooseSpeed(ball, preset)

    local targetPoint, mode = nil, "free"
    if Settings.GoalAimbot then
        local _, gp = pickGoal()
        if gp then
            targetPoint, mode = gp, "goal"
        else
            warnOnce("goal", "Goal Aimbot is on but Goal A/B is not set (Setup tab).")
        end
    end
    if mode == "free" and Settings.AimAssist then
        local tgt = getLookTarget()
        local tch = tgt and tgt.Character
        local troot = tch and tch:FindFirstChild("HumanoidRootPart")
        local thum = tch and tch:FindFirstChildOfClass("Humanoid")
        if troot and thum then
            local feetY = troot.Position.Y - feetOffset(thum, troot) + ball.Size.Y / 2
            local pos = Vector3.new(troot.Position.X, feetY, troot.Position.Z)
            if Settings.LeadTargets then
                local t = (pos - P).Magnitude / math.max(speed, 1)
                local tv = troot.AssemblyLinearVelocity
                pos = pos + Vector3.new(tv.X, 0, tv.Z) * t
            end
            targetPoint, mode = pos, "player"
        end
    end

    local heading, vyWanted
    local curveAimState = nil
    local omega = 0
    local duration = Settings.HoldTime
    local sgn = sideSign(Settings.CurveSide)
    local liftCap = Settings.MaxLiftDeg

    local dx, dz, d = 0, 0, 0
    if targetPoint then
        dx, dz = targetPoint.X - P.X, targetPoint.Z - P.Z
        d = hypot2(dx, dz)
        if d < 1 then targetPoint, mode = nil, "free" end
    end

    if targetPoint then
        local phi = headingOf(dx, dz)
        heading = phi
        vyWanted = ballisticVy(P.Y, targetPoint.Y, d, speed, g)
        if mode == "goal" and Settings.CurveAim and d > GOAL_REACHED_DIST * 2 then
            local alpha0 = math.rad(Settings.CurveAimLevel * CURVE_AIM_DEG_PER_LEVEL)
            curveAimState = { goal = targetPoint, d0 = d, alpha0 = alpha0, sgn = sgn }
            heading = phi - sgn * alpha0 / 2
            duration = clamp(d / math.max(speed, 1) * 2 + 0.5, 0.5, 4)
        end
    else
        liftCap = 80
        local hs = hypot2(cur.X, cur.Z)
        if hs >= 8 then
            heading = headingOf(cur.X, cur.Z)
            vyWanted = math.sin(math.atan2(cur.Y, hs)) * speed
        else
            local look = root.CFrame.LookVector
            heading = headingOf(look.X, look.Z)
            vyWanted = 0
        end
    end

    if preset and preset.errDeg > 0 then
        heading = heading + math.rad((math.random() * 2 - 1) * preset.errDeg)
    end

    local vx, vy, vz = launchVelocity(heading, speed, vyWanted, liftCap)
    if Settings.Curve and not curveAimState then
        omega = sgn * math.rad(Settings.CurveLevel * CURVE_DEG_PER_SEC_PER_LEVEL)
        duration = math.max(duration, Settings.CurveTime)
    end

    local v = Vector3.new(vx, vy, vz)
    if not isFiniteVec(v) then return end
    ShotState = {
        t0 = os.clock(), v = v, hold = Settings.HoldTime,
        duration = duration, omega = omega, curveAim = curveAimState,
    }
    ball.AssemblyLinearVelocity = v
end

onTouch = function(source)
    if not Settings.Enabled then return end
    if not (Settings.PowerShot or Settings.AimAssist or Settings.GoalAimbot or Settings.Curve) then return end
    local now = os.clock()
    if now - lastShotAt < Settings.Cooldown then return end
    lastShotAt = now
    local preset = presetNow()
    local delay = Settings.ApplyDelay
    if preset then
        delay = delay + preset.delayMin + (preset.delayMax - preset.delayMin) * math.random()
    end
    task.delay(delay, function()
        local ok, err = pcall(doShot)
        if not ok then logErr("doShot", err) end
    end)
end

local function stepShot(dt)
    local sh = ShotState
    if not sh then return end
    local ball = Ball.part
    if not (ball and ball.Parent) then ShotState = nil return end
    local age = os.clock() - sh.t0
    if age > sh.duration then ShotState = nil return end

    local holding = age < sh.hold
    local v = holding and sh.v or ball.AssemblyLinearVelocity
    local hs = hypot2(v.X, v.Z)
    if hs < 3 then
        if not holding then ShotState = nil end
        return
    end

    local psi = headingOf(v.X, v.Z)
    if sh.curveAim then
        local P = ball.Position
        local ca = sh.curveAim
        local newPsi, dist = curveAimHeading(P.X, P.Z, ca.goal.X, ca.goal.Z, ca.d0, ca.alpha0, ca.sgn)
        if dist < GOAL_REACHED_DIST then ShotState = nil return end
        psi = newPsi
    elseif sh.omega ~= 0 then
        psi = psi + sh.omega * dt
    end

    local nv = Vector3.new(math.sin(psi) * hs, v.Y, math.cos(psi) * hs)
    if not isFiniteVec(nv) then ShotState = nil return end
    sh.v = nv
    ball.AssemblyLinearVelocity = nv
end

----------------------------------------------------------------------
-- Reach and juggle
----------------------------------------------------------------------
local lastReachAt = -1e9
local lastJuggleAt = -1e9

local function footPart(ch)
    return ch:FindFirstChild("RightFoot") or ch:FindFirstChild("Right Leg") or ch:FindFirstChild("HumanoidRootPart")
end

local function virtualTouch(ball, ch)
    local foot = footPart(ch)
    if foot and type(firetouchinterest) == "function" then
        task.spawn(function()
            pcall(firetouchinterest, ball, foot, 0)
            task.wait()
            pcall(firetouchinterest, ball, foot, 1)
        end)
    end
end

local function stepReach()
    local preset = presetNow()
    local reach = Settings.Reach and Settings.ReachDist or nil
    if preset then reach = math.max(reach or 0, preset.reach) end
    if not reach then return end
    local ball = Ball.part
    local root, ch = myRoot()
    if not (ball and ball.Parent and root and ch) then return end
    local now = os.clock()
    if now - lastReachAt < Settings.Cooldown then return end
    if (ball.Position - root.Position).Magnitude <= reach then
        lastReachAt = now
        virtualTouch(ball, ch)
        onTouch("reach")
    end
end

local function stepJuggle()
    if not Settings.Juggle or ShotState then return end
    local ball = Ball.part
    local root = myRoot()
    if not (ball and ball.Parent and root) then return end
    local rel = ball.Position - root.Position
    if hypot2(rel.X, rel.Z) > JUGGLE_RANGE then return end
    local now = os.clock()
    if now - lastJuggleAt < JUGGLE_COOLDOWN then return end
    local vel = ball.AssemblyLinearVelocity
    if rel.Y < JUGGLE_TRIGGER_REL_Y and vel.Y <= 2 then
        lastJuggleAt = now
        local g = Workspace.Gravity * GameConfig.BallGravityScale
        local vy = math.sqrt(2 * g * Settings.JuggleHeight)
        ball.AssemblyLinearVelocity = Vector3.new(clamp(-rel.X * 3, -20, 20), vy, clamp(-rel.Z * 3, -20, 20))
    end
end

----------------------------------------------------------------------
-- Visuals
----------------------------------------------------------------------
local guiParent = CoreGui
pcall(function()
    if type(gethui) == "function" then
        local h = gethui()
        if typeof(h) == "Instance" then guiParent = h end
    end
end)

local hasDrawing = false
pcall(function()
    hasDrawing = (type(Drawing) == "table") and Drawing.new ~= nil
end)

local visualInstances = {}
local drawings = {}

local function newHighlight(fill, outline)
    local h = Instance.new("Highlight")
    h.FillColor, h.OutlineColor = fill, outline
    h.FillTransparency, h.OutlineTransparency = 0.6, 0
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.Enabled = false
    h.Parent = guiParent
    visualInstances[#visualInstances + 1] = h
    return h
end

local playerHL = newHighlight(Color3.fromRGB(255, 70, 70), Color3.fromRGB(255, 255, 255))
local ballHL = newHighlight(Color3.fromRGB(255, 220, 60), Color3.fromRGB(255, 255, 255))

local playerBB = Instance.new("BillboardGui")
playerBB.Size = UDim2.fromOffset(160, 24)
playerBB.StudsOffset = Vector3.new(0, 3, 0)
playerBB.AlwaysOnTop = true
playerBB.Enabled = false
local playerTL = Instance.new("TextLabel")
playerTL.Size = UDim2.fromScale(1, 1)
playerTL.BackgroundTransparency = 1
playerTL.TextColor3 = Color3.new(1, 1, 1)
playerTL.TextStrokeTransparency = 0.4
playerTL.Font = Enum.Font.GothamBold
playerTL.TextSize = 14
playerTL.Text = ""
playerTL.Parent = playerBB
playerBB.Parent = guiParent
visualInstances[#visualInstances + 1] = playerBB

local function newLine(color, thickness)
    if not hasDrawing then return nil end
    local ok, ln = pcall(function() return Drawing.new("Line") end)
    if not ok or not ln then return nil end
    ln.Visible, ln.Color, ln.Thickness, ln.Transparency = false, color, thickness, 1
    drawings[#drawings + 1] = ln
    return ln
end

local tracer = newLine(Color3.fromRGB(255, 220, 60), 1.5)
local predLines = {}
for i = 1, PRED_STEPS do predLines[i] = newLine(Color3.fromRGB(120, 220, 255), 2) end

local function hideLine(ln) if ln then ln.Visible = false end end

local function updateVisuals()
    local cam = Workspace.CurrentCamera
    local on = Settings.Enabled

    local tgt = (on and Settings.PlayerESP) and getLookTarget() or nil
    local tch = tgt and tgt.Character
    local troot = tch and tch:FindFirstChild("HumanoidRootPart")
    if tgt and tch and troot then
        playerHL.Adornee, playerHL.Enabled = tch, true
        playerBB.Adornee, playerBB.Enabled = tch:FindFirstChild("Head") or troot, true
        local me = myRoot()
        local dist = me and (me.Position - troot.Position).Magnitude or 0
        playerTL.Text = string.format("%s  [%d]", tgt.DisplayName, math.floor(dist))
    else
        playerHL.Adornee, playerHL.Enabled = nil, false
        playerBB.Adornee, playerBB.Enabled = nil, false
    end

    local ball = Ball.part
    local ballOk = on and ball and ball.Parent
    if ballOk and Settings.BallESP then
        ballHL.Adornee, ballHL.Enabled = ball, true
    else
        ballHL.Adornee, ballHL.Enabled = nil, false
    end

    if not hasDrawing or not cam then return end

    if ballOk and Settings.BallTracer and tracer then
        local sp = cam:WorldToViewportPoint(ball.Position)
        if sp.Z > 0 then
            local vs = cam.ViewportSize
            tracer.From = Vector2.new(vs.X / 2, vs.Y)
            tracer.To = Vector2.new(sp.X, sp.Y)
            tracer.Visible = true
        else
            tracer.Visible = false
        end
    else
        hideLine(tracer)
    end

    if ballOk and Settings.Prediction and ball.AssemblyLinearVelocity.Magnitude > 2 then
        local g = Workspace.Gravity * GameConfig.BallGravityScale
        local p0, v0 = ball.Position, ball.AssemblyLinearVelocity
        local prev = cam:WorldToViewportPoint(p0)
        for i = 1, PRED_STEPS do
            local t = i * 0.05
            local pos = p0 + v0 * t + Vector3.new(0, -0.5 * g * t * t, 0)
            local sp = cam:WorldToViewportPoint(pos)
            local ln = predLines[i]
            if ln then
                if prev.Z > 0 and sp.Z > 0 then
                    ln.From = Vector2.new(prev.X, prev.Y)
                    ln.To = Vector2.new(sp.X, sp.Y)
                    ln.Visible = true
                else
                    ln.Visible = false
                end
            end
            prev = sp
        end
    else
        for i = 1, PRED_STEPS do hideLine(predLines[i]) end
    end
end

----------------------------------------------------------------------
-- Diagnostics
----------------------------------------------------------------------
local function printStatus()
    say("PlaceId:", game.PlaceId, "(expected " .. tostring(GameConfig.ExpectedPlaceId) .. ")", "JobId:", game.JobId)
    local ball = Ball.part
    if ball and ball.Parent then
        say("Ball:", ball:GetFullName(), "| pos", tostring(ball.Position), "| vel", tostring(ball.AssemblyLinearVelocity),
            "| size", tostring(ball.Size), "| anchored", tostring(ball.Anchored))
        if type(isnetworkowner) == "function" then
            local ok, own = pcall(isnetworkowner, ball)
            say("isnetworkowner(ball):", ok and tostring(own) or "call failed")
        else
            say("isnetworkowner: not available in this executor")
        end
    else
        say("Ball: none resolved")
    end
    for _, k in ipairs({ "A", "B" }) do
        local gp = goalPos(k)
        say("Goal " .. k .. ":", gp and tostring(gp) or "NOT SET")
    end
    say("firetouchinterest:", type(firetouchinterest) == "function", "| Drawing:", hasDrawing, "| file API:", fsOk())
end

local function printBallCandidates()
    local list = scanBalls()
    say("Ball candidates (heuristic):", #list)
    for i = 1, math.min(#list, 15) do
        local p = list[i].part
        say(i, p:GetFullName(), "| size", tostring(p.Size), "| score", string.format("%.1f", list[i].score))
    end
end

local function printGoalLike()
    local n = 0
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("BasePart") or inst:IsA("Model") then
            local lower = string.lower(inst.Name)
            if string.find(lower, "goal", 1, true) or string.find(lower, "net", 1, true) then
                n = n + 1
                if n <= 40 then
                    local pos = positionOf(inst)
                    say(inst.ClassName, inst:GetFullName(), pos and tostring(pos) or "")
                end
            end
        end
    end
    say("Goal-like objects found:", n, "(first 40 printed)")
end

local function printRemotes()
    local n = 0
    for _, inst in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
        if inst:IsA("RemoteEvent") or inst:IsA("RemoteFunction") then
            n = n + 1
            if n <= 80 then say(inst.ClassName, inst:GetFullName()) end
        end
    end
    say("Remotes found in ReplicatedStorage:", n, "(first 80 printed)")
end

local function lockNearestPart()
    local root = myRoot()
    if not root then notify("Setup", "No character yet.", 3) return end
    local best, bestD
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("BasePart") and not inst.Anchored then
            local m = math.max(inst.Size.X, inst.Size.Y, inst.Size.Z)
            if m <= 12 and not inAnyCharacter(inst) then
                local dd = (inst.Position - root.Position).Magnitude
                if dd <= 60 and (not bestD or dd < bestD) then best, bestD = inst, dd end
            end
        end
    end
    if best then
        setBall(best)
        say("Ball locked:", best:GetFullName())
        notify("Setup", "Ball locked: " .. best.Name, 4)
    else
        notify("Setup", "No unanchored part within 60 studs.", 4)
    end
end

----------------------------------------------------------------------
-- Unload
----------------------------------------------------------------------
local function unload()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    conns = {}
    if Ball.touched then pcall(function() Ball.touched:Disconnect() end) Ball.touched = nil end
    ShotState = nil
    for _, o in ipairs(visualInstances) do pcall(function() o:Destroy() end) end
    for _, d in ipairs(drawings) do
        pcall(function() d:Remove() end)
    end
    if Window then pcall(function() Window:Destroy() end) end
    ENV.__STF_UNLOAD = nil
end
ENV.__STF_UNLOAD = unload

----------------------------------------------------------------------
-- UI (WindUI)
----------------------------------------------------------------------
local okLib, lib = pcall(function()
    return loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
end)
if not okLib or type(lib) ~= "table" then
    warn("[STF] Could not load WindUI: " .. tostring(lib))
    unload()
    return
end
WindUI = lib

Window = WindUI:CreateWindow({
    Title = "Touch Football Hub",
    Author = "Hacking Everything",
    Folder = SAVE_FOLDER,
    Icon = "star",
    Theme = "Dark",
    Size = UDim2.fromOffset(580, 460),
})
if not Window then
    warn("[STF] WindUI:CreateWindow returned nil (a WindUI window may already exist).")
    unload()
    return
end

local function addToggle(tab, title, desc, key)
    return tab:Toggle({
        Title = title, Desc = desc, Value = Settings[key],
        Callback = function(v) Settings[key] = v and true or false end,
    })
end

local function addSlider(tab, title, desc, key, min, max, step)
    return tab:Slider({
        Title = title, Desc = desc, Step = step or 1,
        Value = { Min = min, Max = max, Default = clamp(Settings[key], min, max) },
        Callback = function(v) Settings[key] = tonumber(v) or Settings[key] end,
    })
end

local function addDropdown(tab, title, key, values)
    return tab:Dropdown({
        Title = title, Values = values, Value = Settings[key],
        Callback = function(v)
            if type(v) == "table" then v = v.Title end
            if type(v) == "string" then Settings[key] = v end
        end,
    })
end

local function addInput(tab, title, key, onSet)
    return tab:Input({
        Title = title, Value = Settings[key],
        Callback = function(v)
            Settings[key] = tostring(v or "")
            if onSet then onSet() end
        end,
    })
end

local TabShoot = Window:Tab({ Title = "Shooting", Icon = "target" })
addToggle(TabShoot, "Master enable", "Turns every feature on or off", "Enabled")
addToggle(TabShoot, "Power Shot", "Ball speed set to Power on every touch (cap 145, studs/s, uncalibrated)", "PowerShot")
addSlider(TabShoot, "Power", "Max 145", "Power", 10, POWER_MAX, 1)
addSlider(TabShoot, "Max lift for aimed shots (deg)", "Lower = flatter, lower shots", "MaxLiftDeg", 0, 45, 1)
addToggle(TabShoot, "Aim Assist", "Touch sends the ball low toward the player you are looking at", "AimAssist")
addSlider(TabShoot, "Look cone (deg)", "How close to the crosshair a player must be", "LookFov", 2, 45, 1)
addDropdown(TabShoot, "Target filter", "TargetFilter", { "Anyone", "Teammates", "Enemies" })
addToggle(TabShoot, "Lead moving targets", nil, "LeadTargets")
addToggle(TabShoot, "Goal Aimbot", "Touch sends the ball to the selected goal (needs Goal A/B set in Setup)", "GoalAimbot")
local goalDropdown = addDropdown(TabShoot, "Goal", "GoalSelect", { "Auto (facing)", "Goal A", "Goal B" })

local TabCurve = Window:Tab({ Title = "Curve", Icon = "zap" })
addToggle(TabCurve, "Curve", "Bends every shot; higher level = curvier", "Curve")
addSlider(TabCurve, "Curve level", "1 to 15", "CurveLevel", 1, 15, 1)
addDropdown(TabCurve, "Curve side", "CurveSide", { "Left", "Right", "Random" })
addSlider(TabCurve, "Curve duration (s)", nil, "CurveTime", 0.3, 3, 0.1)
addToggle(TabCurve, "Curve Aimbot (goal only)", "Needs Goal Aimbot on; ball bends and finishes pointing at the goal", "CurveAim")
addSlider(TabCurve, "Curve Aimbot level", "1 to 15", "CurveAimLevel", 1, 15, 1)

local TabAssist = Window:Tab({ Title = "Assists", Icon = "wrench" })
addToggle(TabAssist, "Reach", "Touches the ball from a distance", "Reach")
addSlider(TabAssist, "Reach distance (studs)", nil, "ReachDist", 3, 30, 1)
addToggle(TabAssist, "Juggle", "Pops the ball back up above you when it drops near your feet", "Juggle")
addSlider(TabAssist, "Juggle height (studs)", nil, "JuggleHeight", 2, 12, 1)
addToggle(TabAssist, "Sneaky", "Small reach, slightly randomized power, aim error and timing", "Sneaky")
addToggle(TabAssist, "Sneaky v2", "Larger reach, near-full power, less error (wins over Sneaky)", "SneakyV2")

local TabVis = Window:Tab({ Title = "Visuals", Icon = "eye" })
addToggle(TabVis, "Look-target ESP", "Marks the player you are looking at", "PlayerESP")
addToggle(TabVis, "Ball ESP", nil, "BallESP")
addToggle(TabVis, "Ball tracer", "Needs the Drawing API", "BallTracer")
addToggle(TabVis, "Ball prediction line", "Simple ballistic, no bounce or drag; needs Drawing", "Prediction")

local TabSetup = Window:Tab({ Title = "Setup", Icon = "settings" })
TabSetup:Button({
    Title = "Set Goal A = my position",
    Callback = function()
        local root = myRoot()
        if not root then notify("Setup", "No character yet.", 3) return end
        Goals.A = root.Position
        saveAll()
        notify("Setup", "Goal A saved: " .. tostring(root.Position), 4)
    end,
})
TabSetup:Button({
    Title = "Set Goal B = my position",
    Callback = function()
        local root = myRoot()
        if not root then notify("Setup", "No character yet.", 3) return end
        Goals.B = root.Position
        saveAll()
        notify("Setup", "Goal B saved: " .. tostring(root.Position), 4)
    end,
})
addInput(TabSetup, "Goal A object path (optional)", "GoalAPath")
addInput(TabSetup, "Goal B object path (optional)", "GoalBPath")
TabSetup:Button({
    Title = "Clear Goal A and B positions",
    Callback = function() Goals.A, Goals.B = nil, nil saveAll() notify("Setup", "Goal positions cleared.", 3) end,
})
addInput(TabSetup, "Ball object path (optional)", "BallPath", function()
    setBall(nil)
    Ball.lastScan = 0
    warned.ballpath = nil
end)
TabSetup:Button({
    Title = "Rescan ball (heuristic)",
    Callback = function()
        Settings.BallPath = ""
        setBall(nil)
        Ball.lastScan = 0
        local b = getBall()
        notify("Setup", b and ("Ball: " .. b:GetFullName()) or "No ball candidate found.", 4)
    end,
})
TabSetup:Button({ Title = "Lock nearest unanchored part as ball", Callback = lockNearestPart })
TabSetup:Button({ Title = "Print status to console (F9)", Callback = printStatus })
TabSetup:Button({ Title = "Print ball candidates", Callback = printBallCandidates })
TabSetup:Button({ Title = "Print goal-like objects", Callback = printGoalLike })
TabSetup:Button({ Title = "Print RemoteEvents/Functions", Callback = printRemotes })
addSlider(TabSetup, "Apply delay (s)", "Wait after a touch before overriding the ball", "ApplyDelay", 0, 0.2, 0.01)
addSlider(TabSetup, "Hold time (s)", "How long the override is re-applied each frame", "HoldTime", 0.05, 0.5, 0.01)
addSlider(TabSetup, "Shot cooldown (s)", nil, "Cooldown", 0.1, 1, 0.05)
addToggle(TabSetup, "Anti-AFK", nil, "AntiAFK")
TabSetup:Button({
    Title = "Save settings and goals",
    Callback = function()
        local ok, err = saveAll()
        notify("Setup", ok and "Saved." or ("Save failed: " .. tostring(err)), 4)
    end,
})
TabSetup:Button({ Title = "Unload script", Callback = unload })

----------------------------------------------------------------------
-- Loops and input
----------------------------------------------------------------------
if game.PlaceId ~= GameConfig.ExpectedPlaceId then
    notify("Touch Football Hub", "PlaceId is " .. tostring(game.PlaceId) .. ", not " .. tostring(GameConfig.ExpectedPlaceId) .. ". Continuing anyway.", 6)
end

track(RunService.Heartbeat:Connect(function(dt)
    local ok, err = pcall(function()
        if not Settings.Enabled then ShotState = nil return end
        getBall()
        stepReach()
        stepJuggle()
        stepShot(dt)
    end)
    if not ok then logErr("heartbeat", err) end
end))

track(RunService.RenderStepped:Connect(function()
    local ok, err = pcall(updateVisuals)
    if not ok then logErr("visuals", err) end
end))

track(LocalPlayer.Idled:Connect(function()
    if Settings.AntiAFK then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end))

local function selectGoal(value)
    Settings.GoalSelect = value
    notify("Goal", value, 2)
    if goalDropdown then
        for _, fn in ipairs({ "Select", "Set" }) do
            if type(goalDropdown[fn]) == "function" then
                if pcall(goalDropdown[fn], goalDropdown, value) then break end
            end
        end
    end
end

track(UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    local k = input.KeyCode
    if k == KEYS.ToggleUI then
        pcall(function() Window:Toggle() end)
    elseif k == KEYS.GoalA then
        selectGoal("Goal A")
    elseif k == KEYS.GoalB then
        selectGoal("Goal B")
    elseif k == KEYS.GoalAuto then
        selectGoal("Auto (facing)")
    end
end))

notify("Touch Football Hub", "Loaded. RightShift = menu, Z/X/C = Goal A / Goal B / Auto.", 5)
say("loaded; call Setup > Print status to check ball, goals and executor features")
