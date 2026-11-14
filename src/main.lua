--[[
	xpware - Murder Mystery 2
	Engine: Roblox client (executor)  |  Language: Luau

	Where the library comes from:
	  - bundled by build.ps1: `Library` is defined above this file
	  - Roblox Studio: ReplicatedStorage.xpware.xpui ModuleScript
	  - executor, unbundled: xpware/xpui.lua in the executor's workspace folder

	Executor functions used when present (each feature says so if one is missing):
	  firetouchinterest  - knife aura, kill all, coin/gun touches
	  hookmetamethod, getnamecallmethod, checkcaller, newcclosure - silent aim, throw assist
	  Drawing            - tracers
	  readfile/writefile/isfile/makefolder/delfile - configs
	  setclipboard, game:HttpGet - copy job id, server hop
]]

local Library = Library
if not Library then
	local folder = game:GetService("ReplicatedStorage"):FindFirstChild("xpware")
	local module = folder and folder:FindFirstChild("xpui")
	if module then
		Library = require(module)
	else
		Library = loadstring(readfile("xpware/xpui.lua"))()
	end
end

local NAME = "xpware"
local VERSION = "0.2"

------------------------------------------------------------------------
-- Services / shared state
------------------------------------------------------------------------
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local Lighting          = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService   = game:GetService("TeleportService")
local HttpService       = game:GetService("HttpService")
local TextChatService   = game:GetService("TextChatService")
local GuiService        = game:GetService("GuiService")

local LP = Players.LocalPlayer
local Flags = Library.Flags
local Options = Library.Options
local GENV = (typeof(getgenv) == "function" and getgenv()) or _G

local function has(fn) return typeof(fn) == "function" end
local touch = has(firetouchinterest) and firetouchinterest or nil

local conns, cleanups = {}, {}
local function on(signal, fn)
	local c = signal:Connect(fn)
	table.insert(conns, c)
	return c
end
local function onUnload(fn) table.insert(cleanups, fn) end
local function running() return not Library.Unloaded end
local function notify(text, title, dur) Library:Notify(title or NAME, text, dur or 4) end

Library:OnUnload(function()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
end)

local function cam() return workspace.CurrentCamera end

------------------------------------------------------------------------
-- Character helpers
------------------------------------------------------------------------
local function humOf(p) local c = p and p.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function rootOf(p) local c = p and p.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function isAlive(p) local h = humOf(p); return h ~= nil and h.Health > 0 and rootOf(p) ~= nil end
local function myRoot() return rootOf(LP) end
local function myHum() return humOf(LP) end

local function teleport(cf)
	local c, r = LP.Character, myRoot()
	if not (c and r) then return false end
	r.AssemblyLinearVelocity = Vector3.zero
	c:PivotTo(cf)
	return true
end

local function partOf(inst)
	if not inst then return nil end
	if inst:IsA("BasePart") then return inst end
	if inst:IsA("Model") then return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true) end
	return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function touchPart(part)
	local r = myRoot()
	if touch and r and part then
		pcall(touch, r, part, 0)
		pcall(touch, r, part, 1)
	end
end

local function findPlayer(name)
	if type(name) ~= "string" or name == "" then return nil end
	name = name:lower()
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Name:lower() == name or p.DisplayName:lower() == name then return p end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Name:lower():sub(1, #name) == name or p.DisplayName:lower():sub(1, #name) == name then return p end
	end
end

local function otherNames()
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then table.insert(t, p.Name) end
	end
	table.sort(t, function(a, b) return a:lower() < b:lower() end)
	return t
end

------------------------------------------------------------------------
-- MM2 game state: map, lobby, dropped gun, roles
------------------------------------------------------------------------
local State = { map = nil, lobbyBox = nil, gun = nil, data = {} }

local ROLE_COLORS = {
	Murderer = Color3.fromRGB(255, 59, 59),
	Sheriff  = Color3.fromRGB(59, 139, 255),
	Hero     = Color3.fromRGB(255, 200, 59),
	Innocent = Color3.fromRGB(76, 217, 100),
}
local GUN_COLOR = Color3.fromRGB(170, 90, 255)
local COIN_COLOR = Color3.fromRGB(255, 215, 0)

local function findMap()
	for _, m in ipairs(workspace:GetChildren()) do
		if m.Name ~= "Lobby" and (m:IsA("Model") or m:IsA("Folder")) and m:FindFirstChild("CoinContainer") then
			return m
		end
	end
	for _, m in ipairs(workspace:GetChildren()) do
		if m.Name ~= "Lobby" and m:IsA("Model") and m:FindFirstChild("Spawns") then return m end
	end
end

local function updateLobbyBox()
	local lobby = workspace:FindFirstChild("Lobby")
	if lobby and lobby:IsA("Model") then
		local ok, cf, size = pcall(lobby.GetBoundingBox, lobby)
		if ok then State.lobbyBox = { cf = cf, half = size / 2 + Vector3.new(10, 60, 10) } return end
	end
	State.lobbyBox = nil
end

local function inLobby(p)
	local r, box = rootOf(p), State.lobbyBox
	if not (r and box) then return false end
	local rel = box.cf:PointToObjectSpace(r.Position)
	return math.abs(rel.X) <= box.half.X and math.abs(rel.Y) <= box.half.Y and math.abs(rel.Z) <= box.half.Z
end

local function hasTool(p, name)
	local c, b = p.Character, p:FindFirstChildOfClass("Backpack")
	return (c and c:FindFirstChild(name)) or (b and b:FindFirstChild(name)) or nil
end

local function dataOf(p)
	local d = State.data[p.Name]
	return type(d) == "table" and d or nil
end

local function roleOf(p)
	if hasTool(p, "Knife") then return "Murderer" end
	local d = dataOf(p)
	local r = d and d.Role
	if hasTool(p, "Gun") then return r == "Hero" and "Hero" or "Sheriff" end
	if r == "Murderer" or r == "Sheriff" or r == "Hero" then return r end
	return "Innocent"
end

-- alive, on the map, and not marked dead by the game's own player data
local function inRound(p)
	if not State.map or not isAlive(p) then return false end
	local d = dataOf(p)
	if d and (d.Dead or d.Killed) then return false end
	return not inLobby(p)
end

local function findRole(role)
	for _, p in ipairs(Players:GetPlayers()) do
		if isAlive(p) and roleOf(p) == role then return p end
	end
end
local function findSheriff() return findRole("Sheriff") or findRole("Hero") end

local function isCoinLive(c)
	if not (c and c.Parent and c:IsA("BasePart")) then return false end
	local v = c:FindFirstChild("CoinVisual")
	if v and v:IsA("BasePart") and v.Transparency >= 1 then return false end
	return true
end

local function liveCoins()
	local list = {}
	local cc = State.map and State.map:FindFirstChild("CoinContainer")
	if cc then
		for _, c in ipairs(cc:GetChildren()) do
			if isCoinLive(c) then table.insert(list, c) end
		end
	end
	return list
end

------------------------------------------------------------------------
-- ESP (Highlight outlines + billboard text + Drawing tracers)
------------------------------------------------------------------------
local espFolder = Instance.new("Folder")
espFolder.Name = HttpService:GenerateGUID(false)
if not pcall(function() espFolder.Parent = (Library.Gui and Library.Gui.Parent) or game:GetService("CoreGui") end) then
	espFolder.Parent = LP:WaitForChild("PlayerGui")
end
onUnload(function() espFolder:Destroy() end)

local hasDrawing = typeof(Drawing) == "table" and has(Drawing.new)

local function newBillboard()
	local bb = Instance.new("BillboardGui")
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(220, 32)
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.Enabled = false
	bb.Parent = espFolder
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.SourceSansBold
	label.TextSize = 14
	label.TextStrokeTransparency = 0.35
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Parent = bb
	return bb, label
end

local function newHighlight()
	local hl = Instance.new("Highlight")
	hl.Enabled = false
	hl.OutlineTransparency = 0
	hl.Parent = espFolder
	return hl
end

local espObjs = {}

local function makeEsp(p)
	local o = { hl = newHighlight() }
	o.bb, o.label = newBillboard()
	if hasDrawing then
		local ok, line = pcall(Drawing.new, "Line")
		if ok then line.Thickness = 1.5; line.Visible = false; o.line = line end
	end
	espObjs[p] = o
	return o
end

local function hideEsp(o)
	o.hl.Enabled = false
	o.bb.Enabled = false
	if o.line then o.line.Visible = false end
end

local function removeEsp(p)
	local o = espObjs[p]
	if not o then return end
	o.hl:Destroy()
	o.bb:Destroy()
	if o.line then pcall(function() o.line:Remove() end) end
	espObjs[p] = nil
end
onUnload(function() for p in pairs(espObjs) do removeEsp(p) end end)

local function roleShown(role)
	if role == "Murderer" then return Flags.esp_murderer end
	if role == "Sheriff" or role == "Hero" then return Flags.esp_sheriff end
	return Flags.esp_innocent
end

local function styleHighlight(hl, color)
	hl.OutlineColor = color
	hl.FillColor = color
	hl.FillTransparency = 1 - (Flags.esp_fill or 0) / 100
	hl.DepthMode = Flags.esp_walls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
end

local function updatePlayerEsp()
	local parts = Flags.esp_parts or {}
	local me = myRoot()
	local camera = cam()
	local vp = camera.ViewportSize
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local o = espObjs[p] or makeEsp(p)
			local c, r, h = p.Character, rootOf(p), humOf(p)
			local role = roleOf(p)
			local show = c ~= nil and r ~= nil and h ~= nil and h.Health > 0 and roleShown(role)
			local dist = (show and me) and (r.Position - me.Position).Magnitude or 0
			if show and dist > (Flags.esp_distance or 1000) then show = false end
			if show and Flags.esp_round_only and not inRound(p) then show = false end

			if not show then
				hideEsp(o)
			else
				local color = ROLE_COLORS[role]

				o.hl.Adornee = c
				styleHighlight(o.hl, color)
				o.hl.Enabled = parts.Outline == true

				local top, bottom = {}, {}
				if parts.Name then table.insert(top, p.DisplayName) end
				if parts.Role then table.insert(top, "[" .. role .. "]") end
				if parts.Distance then table.insert(bottom, math.floor(dist) .. "m") end
				if parts.Health then table.insert(bottom, math.floor(h.Health) .. " hp") end
				local text = table.concat(top, " ")
				if #bottom > 0 then text = text .. (text ~= "" and "\n" or "") .. table.concat(bottom, "  ") end
				o.bb.Adornee = c:FindFirstChild("Head") or r
				o.label.Text = text
				o.label.TextColor3 = color
				o.bb.Enabled = text ~= ""

				if o.line then
					local pos, onScreen = camera:WorldToViewportPoint(r.Position)
					if parts.Tracer and onScreen then
						o.line.From = Vector2.new(vp.X / 2, vp.Y - 2)
						o.line.To = Vector2.new(pos.X, pos.Y)
						o.line.Color = color
						o.line.Visible = true
					else
						o.line.Visible = false
					end
				end
			end
		end
	end
end

-- dropped gun
local gunHl = newHighlight()
local gunBB, gunLabel = newBillboard()
gunLabel.Text = "GUN"
gunLabel.TextColor3 = GUN_COLOR

local function updateGunEsp()
	local gun = State.gun
	if Flags.gun_esp and gun and gun.Parent then
		gunHl.Adornee = gun
		styleHighlight(gunHl, GUN_COLOR)
		gunHl.FillTransparency = 0.4
		gunHl.Enabled = true
		gunBB.Adornee = partOf(gun)
		gunBB.StudsOffset = Vector3.new(0, 2, 0)
		gunBB.Enabled = true
	else
		gunHl.Enabled = false
		gunBB.Enabled = false
	end
end

-- coins: box adornments, since Highlight caps out at 31 on screen
local coinBoxes = {}
local function clearCoinEsp()
	for coin, box in pairs(coinBoxes) do box:Destroy(); coinBoxes[coin] = nil end
end

local function updateCoinEsp()
	if not Flags.coin_esp then clearCoinEsp() return end
	local live = {}
	for _, coin in ipairs(liveCoins()) do
		live[coin] = true
		if not coinBoxes[coin] then
			local box = Instance.new("BoxHandleAdornment")
			box.Adornee = coin
			box.Size = coin.Size
			box.AlwaysOnTop = true
			box.ZIndex = 5
			box.Transparency = 0.35
			box.Color3 = COIN_COLOR
			box.Parent = espFolder
			coinBoxes[coin] = box
		end
	end
	for coin, box in pairs(coinBoxes) do
		if not live[coin] then box:Destroy(); coinBoxes[coin] = nil end
	end
end

------------------------------------------------------------------------
-- Combat: silent aim / throw assist (one __namecall hook, installed once per session)
------------------------------------------------------------------------
local function aimPoint(p, partName)
	local c = p and p.Character
	if not c then return nil end
	local part = c:FindFirstChild(partName or "HumanoidRootPart")
	if not part and partName == "Torso" then part = c:FindFirstChild("UpperTorso") end
	part = part or c:FindFirstChild("HumanoidRootPart")
	if not part then return nil end
	local root = c:FindFirstChild("HumanoidRootPart")
	local v = root and root.AssemblyLinearVelocity or Vector3.zero
	local t = (Flags.prediction or 0) / 1000
	return part.Position + Vector3.new(v.X, v.Y * 0.5, v.Z) * t
end

local function closestToCursor()
	local camera = cam()
	local mouse = UIS:GetMouseLocation()
	local me = myRoot()
	local best, bestScore
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and inRound(p) then
			local r = rootOf(p)
			local pos, onScreen = camera:WorldToViewportPoint(r.Position)
			local score
			if onScreen then
				score = (Vector2.new(pos.X, pos.Y) - mouse).Magnitude
			elseif me then
				score = 1e5 + (r.Position - me.Position).Magnitude
			end
			if score and (not bestScore or score < bestScore) then best, bestScore = p, score end
		end
	end
	return best
end

-- Replaces aim data in the gun/knife remotes with the target position.
-- Vector3 near our body = shot origin (kept); anything else = aim point (replaced).
local function rewriteArgs(args, target)
	local r = myRoot()
	local origin = r and r.Position
	for i = 1, args.n do
		local a = args[i]
		if typeof(a) == "Vector3" then
			if not origin or (a - origin).Magnitude > 6 then args[i] = target end
		elseif typeof(a) == "CFrame" then
			if origin and (a.Position - origin).Magnitude <= 15 then
				args[i] = CFrame.lookAt(a.Position, target)
			else
				args[i] = CFrame.new(target)
			end
		end
	end
end

local function redirect(remote, args)
	local c = LP.Character
	if not c or typeof(remote) ~= "Instance" or not remote:IsDescendantOf(c) then return false end
	local tool = remote:FindFirstAncestorOfClass("Tool")
	if not tool then return false end
	local target
	if tool.Name == "Gun" and Flags.silent_aim then
		if math.random(1, 100) > (Flags.hit_chance or 100) then return false end
		target = aimPoint(findRole("Murderer"), Flags.aim_part)
	elseif tool.Name == "Knife" and Flags.throw_assist then
		target = aimPoint(closestToCursor(), "HumanoidRootPart")
	end
	if not target then return false end
	rewriteArgs(args, target)
	return true
end

local hookReady = has(hookmetamethod) and has(getnamecallmethod)
if hookReady then
	GENV.__xpware_redirect = redirect
	onUnload(function() if GENV.__xpware_redirect == redirect then GENV.__xpware_redirect = nil end end)
	if not GENV.__xpware_hooked then
		GENV.__xpware_hooked = true
		local wrap = has(newcclosure) and newcclosure or function(f) return f end
		local isOurs = has(checkcaller) and checkcaller or function() return false end
		local getMethod = getnamecallmethod
		local old
		old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
			local method = getMethod()
			if (method == "FireServer" or method == "InvokeServer") and not isOurs() then
				local fn = GENV.__xpware_redirect
				if fn then
					local args = table.pack(...)
					local ok, changed = pcall(fn, self, args)
					if ok and changed then return old(self, table.unpack(args, 1, args.n)) end
				end
			end
			return old(self, ...)
		end))
	end
end

local function visible(p)
	local me, r = LP.Character, rootOf(p)
	local head = me and me:FindFirstChild("Head")
	if not (head and r) then return false end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { me, p.Character, espFolder }
	return workspace:Raycast(head.Position, r.Position - head.Position, params) == nil
end

local lastShot = 0
local function shootMurderer(needSight)
	local h = myHum()
	local gun = hasTool(LP, "Gun")
	local m = findRole("Murderer")
	if not (h and gun and m and inRound(m)) then return false end
	if needSight and not visible(m) then return false end
	if os.clock() - lastShot < 1.2 then return false end
	lastShot = os.clock()
	if gun.Parent ~= LP.Character then h:EquipTool(gun); task.wait(0.05) end
	if not Flags.silent_aim then
		local r = myRoot()
		local target = aimPoint(m, Flags.aim_part)
		if r and target then r.CFrame = CFrame.lookAt(r.Position, Vector3.new(target.X, r.Position.Y, target.Z)) end
	end
	gun:Activate()
	return true
end

local function getKnife(equip)
	local knife = hasTool(LP, "Knife")
	local h = myHum()
	if knife and equip and h and knife.Parent ~= LP.Character then
		h:EquipTool(knife)
		task.wait(0.05)
	end
	return knife
end

local function stab(knife, p)
	local handle = knife and knife:FindFirstChild("Handle")
	local r = rootOf(p)
	if not (handle and r) then return end
	knife:Activate()
	if touch then
		pcall(touch, handle, r, 0)
		pcall(touch, handle, r, 1)
	end
end

local lastAura = 0
local function knifeAura()
	if not touch or os.clock() - lastAura < 0.12 then return end
	local knife = getKnife(Flags.auto_equip)
	if not knife or knife.Parent ~= LP.Character then return end
	local me = myRoot()
	if not me then return end
	lastAura = os.clock()
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and inRound(p) and (rootOf(p).Position - me.Position).Magnitude <= Flags.aura_range then
			stab(knife, p)
		end
	end
end

local busy = false -- kill all / fling / gun grab own the character while true
local function killAll()
	if busy then return end
	if not touch then notify("Your executor has no firetouchinterest.") return end
	local knife = getKnife(true)
	if not knife then notify("You're not the murderer.") return end
	local me = myRoot()
	if not me then return end
	busy = true
	local home = me.CFrame
	for _, p in ipairs(Players:GetPlayers()) do
		if not running() then break end
		if p ~= LP and inRound(p) then
			local r = rootOf(p)
			for _ = 1, 4 do
				if not (r.Parent and isAlive(p)) then break end
				teleport(r.CFrame * CFrame.new(0, 0, 2))
				stab(knife, p)
				task.wait(0.1)
			end
		end
	end
	teleport(home)
	busy = false
end

------------------------------------------------------------------------
-- Teleports
------------------------------------------------------------------------
local function spawnIn(model)
	if not model then return nil end
	local spawns = model:FindFirstChild("Spawns")
	local list = {}
	if spawns then
		for _, s in ipairs(spawns:GetChildren()) do
			if s:IsA("BasePart") then table.insert(list, s) end
		end
	end
	if #list > 0 then return list[math.random(#list)].CFrame + Vector3.new(0, 3, 0) end
	return model:GetPivot() + Vector3.new(0, 5, 0)
end

local function tpLobby()
	local cf = spawnIn(workspace:FindFirstChild("Lobby"))
	if cf then teleport(cf) else notify("Couldn't find the lobby.") end
end

local function tpMap()
	local cf = spawnIn(State.map)
	if cf then teleport(cf) else notify("No round running.") end
end

local function tpGun()
	local part = partOf(State.gun)
	if part then teleport(part.CFrame + Vector3.new(0, 2, 0)) else notify("The gun isn't dropped.") end
end

local function tpPlayer(p, label)
	local r = rootOf(p)
	if r then teleport(r.CFrame * CFrame.new(0, 0, 3)) else notify((label or "Player") .. " not found.") end
end

local safePart, safeReturn
local function setSafeSpot(on)
	local me = myRoot()
	if on then
		if not me then return end
		safeReturn = me.CFrame
		local base = (State.map and State.map:GetPivot().Position) or me.Position
		safePart = Instance.new("Part")
		safePart.Anchored = true
		safePart.Size = Vector3.new(16, 1, 16)
		safePart.Transparency = 0.6
		safePart.Position = base + Vector3.new(0, 350, 0)
		safePart.Parent = workspace
		teleport(safePart.CFrame + Vector3.new(0, 3, 0))
	else
		if safeReturn then teleport(safeReturn) end
		if safePart then safePart:Destroy() end
		safePart, safeReturn = nil, nil
	end
end
onUnload(function() if safePart then safePart:Destroy() end end)

------------------------------------------------------------------------
-- Trolling
------------------------------------------------------------------------
local function fling(p)
	if busy then return end
	local me, tr = myRoot(), rootOf(p)
	if not (me and tr) then notify("Target has no character.") return end
	busy = true
	local home = me.CFrame
	local bav = Instance.new("BodyAngularVelocity")
	bav.MaxTorque = Vector3.new(0, math.huge, 0)
	bav.P = math.huge
	bav.AngularVelocity = Vector3.new(0, 9e5, 0)
	bav.Parent = me
	local t0 = os.clock()
	while running() and os.clock() - t0 < 2.5 and tr.Parent and isAlive(p) and myRoot() == me do
		if tr.AssemblyLinearVelocity.Magnitude > 400 then break end -- they're gone
		me.CFrame = CFrame.new(tr.Position + tr.AssemblyLinearVelocity * 0.12)
		me.AssemblyLinearVelocity = Vector3.zero
		RunService.Heartbeat:Wait()
	end
	bav:Destroy()
	if me.Parent then
		me.AssemblyAngularVelocity = Vector3.zero
		me.AssemblyLinearVelocity = Vector3.zero
		me.CFrame = home
		local h = myHum()
		if h then h:ChangeState(Enum.HumanoidStateType.GettingUp) end
	end
	busy = false
end

local function chat(msg)
	local ok = pcall(function()
		local channels = TextChatService:FindFirstChild("TextChannels")
		local general = channels and channels:FindFirstChild("RBXGeneral")
		assert(general)
		general:SendAsync(msg)
	end)
	if ok then return end
	pcall(function()
		ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(msg, "All")
	end)
end

local function announceRoles()
	local m, s = findRole("Murderer"), findSheriff()
	if not (m or s) then notify("Roles aren't known yet.") return end
	chat(string.format("Murderer: %s | Sheriff: %s", m and m.DisplayName or "?", s and s.DisplayName or "?"))
end

------------------------------------------------------------------------
-- Player: movement, fly, noclip, anti-fling
------------------------------------------------------------------------
local flyBV, flyBG
local function stopFly()
	if flyBV then flyBV:Destroy() end
	if flyBG then flyBG:Destroy() end
	flyBV, flyBG = nil, nil
	local h = myHum()
	if h then h.PlatformStand = false end
end
onUnload(stopFly)

local function updateFly()
	if not Flags.fly then
		if flyBV then stopFly() end
		return
	end
	local r, h = myRoot(), myHum()
	if not (r and h) then return end
	if not flyBV or flyBV.Parent ~= r then
		stopFly()
		flyBV = Instance.new("BodyVelocity")
		flyBV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
		flyBV.Velocity = Vector3.zero
		flyBV.Parent = r
		flyBG = Instance.new("BodyGyro")
		flyBG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
		flyBG.P = 9e4
		flyBG.Parent = r
	end
	h.PlatformStand = true
	local cf = cam().CFrame
	local dir = Vector3.zero
	if not UIS:GetFocusedTextBox() then
		if UIS:IsKeyDown(Enum.KeyCode.W) then dir += cf.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.S) then dir -= cf.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.D) then dir += cf.RightVector end
		if UIS:IsKeyDown(Enum.KeyCode.A) then dir -= cf.RightVector end
		if UIS:IsKeyDown(Enum.KeyCode.Space) then dir += Vector3.yAxis end
		if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
	end
	flyBV.Velocity = dir.Magnitude > 0 and dir.Unit * Flags.fly_speed or Vector3.zero
	flyBG.CFrame = cf
end

local farmNoclip = false
local noclipped = {}
local function updateNoclip()
	local c = LP.Character
	if (Flags.noclip or farmNoclip) and c then
		for _, part in ipairs(c:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide then
				noclipped[part] = true
				part.CanCollide = false
			end
		end
	elseif next(noclipped) then
		for part in pairs(noclipped) do
			if part.Parent then part.CanCollide = true end
		end
		noclipped = {}
	end
end

local function updateAntiFling()
	if not Flags.anti_fling or busy then return end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and p.Character then
			for _, part in ipairs(p.Character:GetDescendants()) do
				if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
			end
		end
	end
end

------------------------------------------------------------------------
-- Graphics
------------------------------------------------------------------------
local savedLight, savedAtmo = {}, {}
local function setLight(k, v)
	if savedLight[k] == nil then savedLight[k] = Lighting[k] end
	if Lighting[k] ~= v then Lighting[k] = v end
end
local function restoreLight(k)
	if savedLight[k] ~= nil then Lighting[k] = savedLight[k]; savedLight[k] = nil end
end

local function updateLighting()
	if Flags.fullbright then
		setLight("Brightness", 2)
		setLight("Ambient", Color3.fromRGB(178, 178, 178))
		setLight("OutdoorAmbient", Color3.fromRGB(178, 178, 178))
	else
		restoreLight("Brightness"); restoreLight("Ambient"); restoreLight("OutdoorAmbient")
	end
	if Flags.no_fog then
		setLight("FogEnd", 1e6); setLight("FogStart", 1e6)
		for _, a in ipairs(Lighting:GetChildren()) do
			if a:IsA("Atmosphere") then
				if savedAtmo[a] == nil then savedAtmo[a] = a.Density end
				a.Density = 0
			end
		end
	else
		restoreLight("FogEnd"); restoreLight("FogStart")
		for a, d in pairs(savedAtmo) do if a.Parent then a.Density = d end end
		savedAtmo = {}
	end
	if Flags.no_shadows then setLight("GlobalShadows", false) else restoreLight("GlobalShadows") end
	if Flags.custom_time then setLight("ClockTime", Flags.clock_time) else restoreLight("ClockTime") end
end

local function restoreAllLighting()
	for k in pairs(savedLight) do restoreLight(k) end
	for a, d in pairs(savedAtmo) do if a.Parent then a.Density = d end end
	savedAtmo = {}
end
onUnload(restoreAllLighting)

local boosted = {}
local boostConn
local function boostOne(d)
	if boosted[d] then return end
	if d:IsA("BasePart") then
		if d.Material ~= Enum.Material.SmoothPlastic then
			boosted[d] = { Material = d.Material }
			d.Material = Enum.Material.SmoothPlastic
		end
	elseif d:IsA("Decal") or d:IsA("Texture") then
		boosted[d] = { Transparency = d.Transparency }
		d.Transparency = 1
	elseif d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke") or d:IsA("Fire") or d:IsA("Sparkles") or d:IsA("PostEffect") then
		boosted[d] = { Enabled = d.Enabled }
		d.Enabled = false
	end
end

local function setFpsBoost(enabled)
	if enabled then
		if boostConn then return end
		boostConn = workspace.DescendantAdded:Connect(boostOne)
		task.spawn(function()
			for i, d in ipairs(workspace:GetDescendants()) do
				if not boostConn then return end
				pcall(boostOne, d)
				if i % 3000 == 0 then task.wait() end
			end
			for _, d in ipairs(Lighting:GetChildren()) do pcall(boostOne, d) end
		end)
	else
		if boostConn then boostConn:Disconnect(); boostConn = nil end
		for inst, props in pairs(boosted) do
			if inst.Parent then
				for k, v in pairs(props) do pcall(function() inst[k] = v end) end
			end
		end
		boosted = {}
	end
end
onUnload(function() setFpsBoost(false) end)

local xrayParts = {}
local function clearXray()
	for part in pairs(xrayParts) do if part.Parent then part.LocalTransparencyModifier = 0 end end
	xrayParts = {}
end
local function updateXray()
	if not Flags.xray or not State.map then clearXray() return end
	local amount = Flags.xray_amount / 100
	for _, d in ipairs(State.map:GetDescendants()) do
		if d:IsA("BasePart") then
			xrayParts[d] = true
			d.LocalTransparencyModifier = amount
		end
	end
end
onUnload(clearXray)

local savedZoom = LP.CameraMaxZoomDistance
onUnload(function() LP.CameraMaxZoomDistance = savedZoom end)

------------------------------------------------------------------------
-- Server
------------------------------------------------------------------------
local function rejoin()
	if #Players:GetPlayers() <= 1 then
		TeleportService:Teleport(game.PlaceId, LP)
	else
		TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
	end
end

local function serverHop()
	local ok, body = pcall(function()
		return game:HttpGet(("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100"):format(game.PlaceId))
	end)
	if not ok then notify("Server list request failed.") return end
	local okJson, data = pcall(HttpService.JSONDecode, HttpService, body)
	local ids = {}
	if okJson and type(data) == "table" and type(data.data) == "table" then
		for _, s in ipairs(data.data) do
			if s.id ~= game.JobId and tonumber(s.playing) and tonumber(s.maxPlayers) and s.playing < s.maxPlayers then
				table.insert(ids, s.id)
			end
		end
	end
	if #ids == 0 then notify("No other open servers found.") return end
	notify("Hopping servers...")
	TeleportService:TeleportToPlaceInstance(game.PlaceId, ids[math.random(#ids)], LP)
end

------------------------------------------------------------------------
-- Autofarm
------------------------------------------------------------------------
local collected = 0
local coinLabel -- set in the UI section

local function setCollected(n)
	collected = n
	if coinLabel then coinLabel:Set("Collected this round: " .. n) end
end

local function nextCoin()
	local me = myRoot()
	if not me then return nil end
	local murderer = Flags.avoid_murderer and roleOf(LP) ~= "Murderer" and findRole("Murderer")
	local mr = murderer and rootOf(murderer)
	local best, bestD
	for _, coin in ipairs(liveCoins()) do
		local safe = not mr or (coin.Position - mr.Position).Magnitude > Flags.avoid_radius
		if safe then
			local d = (coin.Position - me.Position).Magnitude
			if not bestD or d < bestD then best, bestD = coin, d end
		end
	end
	return best
end

local function farmStep()
	local coin = nextCoin()
	if not coin then farmNoclip = false; task.wait(0.3) return end
	local me = myRoot()
	farmNoclip = true
	local speed = 10 + Flags.farm_speed * 3
	local goal = CFrame.new(coin.Position) * me.CFrame.Rotation
	local tw = TweenService:Create(me, TweenInfo.new((coin.Position - me.Position).Magnitude / speed, Enum.EasingStyle.Linear), { CFrame = goal })
	tw:Play()
	while tw.PlaybackState == Enum.PlaybackState.Playing do
		if not (running() and Flags.coin_farm and isCoinLive(coin) and me.Parent) or busy then tw:Cancel() break end
		me.AssemblyLinearVelocity = Vector3.zero
		task.wait()
	end
	if isCoinLive(coin) and Flags.coin_farm then
		touchPart(coin)
		local t0 = os.clock()
		while isCoinLive(coin) and os.clock() - t0 < 0.4 do task.wait() end
	end
	if not isCoinLive(coin) then
		setCollected(collected + 1)
		if Flags.reset_full and collected >= Flags.bag_size then
			local h = myHum()
			if h then h.Health = 0 end
			notify("Bag full - resetting.")
			setCollected(0)
		end
	end
end

local function grabGun()
	if busy then return end
	local part = partOf(State.gun)
	local me = myRoot()
	if not (part and me) then return end
	if roleOf(LP) == "Murderer" then return end
	busy = true
	local home = me.CFrame
	teleport(part.CFrame + Vector3.new(0, 1.5, 0))
	touchPart(part)
	local t0 = os.clock()
	while State.gun and State.gun.Parent and os.clock() - t0 < 1 do
		touchPart(partOf(State.gun))
		task.wait(0.05)
	end
	if Flags.gun_return then teleport(home) end
	busy = false
end

------------------------------------------------------------------------
-- Fun
------------------------------------------------------------------------
local EMOTES = {
	["Dance"]   = { "dance", "Animation1" },
	["Dance 2"] = { "dance2", "Animation1" },
	["Dance 3"] = { "dance3", "Animation1" },
	["Wave"]    = { "wave", "WaveAnim" },
	["Point"]   = { "point", "PointAnim" },
	["Cheer"]   = { "cheer", "CheerAnim" },
	["Laugh"]   = { "laugh", "LaughAnim" },
}
local EMOTE_ORDER = { "Dance", "Dance 2", "Dance 3", "Wave", "Point", "Cheer", "Laugh" }

local emoteTrack
local function stopEmote()
	if emoteTrack then pcall(function() emoteTrack:Stop() end) end
	emoteTrack = nil
end
onUnload(stopEmote)

local function playEmote(name)
	local c, h = LP.Character, myHum()
	local e = EMOTES[name]
	if not (c and h and e) then return end
	local animate = c:FindFirstChild("Animate")
	local holder = animate and animate:FindFirstChild(e[1])
	local anim = holder and (holder:FindFirstChild(e[2]) or holder:FindFirstChildOfClass("Animation"))
	if not anim then notify("This character has no " .. name .. " animation.") return end
	stopEmote()
	local animator = h:FindFirstChildOfClass("Animator") or h
	emoteTrack = animator:LoadAnimation(anim)
	emoteTrack.Priority = Enum.AnimationPriority.Action
	emoteTrack:Play()
end

local spinning, frozen = false, false
local function updateFun(dt)
	local r, h = myRoot(), myHum()
	if not (r and h) then return end
	if Flags.spin and not busy then
		spinning = true
		h.AutoRotate = false
		r.CFrame *= CFrame.Angles(0, Flags.spin_speed * 2 * dt, 0)
	elseif spinning then
		spinning = false
		h.AutoRotate = true
	end
	if Flags.jump_spam and h.FloorMaterial ~= Enum.Material.Air then h.Jump = true end
	if Flags.freeze then
		r.Anchored = true
		frozen = true
	elseif frozen then
		r.Anchored = false
		frozen = false
	end
	if emoteTrack and h.MoveDirection.Magnitude > 0 then stopEmote() end
end
onUnload(function()
	local r, h = myRoot(), myHum()
	if r and frozen then r.Anchored = false end
	if h and spinning then h.AutoRotate = true end
end)

------------------------------------------------------------------------
-- Configs
------------------------------------------------------------------------
local CONFIG_DIR = "xpware"
local CONFIG_FILE = CONFIG_DIR .. "/mm2.json"
local AUTOLOAD_FILE = CONFIG_DIR .. "/mm2.autoload"
local canSave = has(writefile) and has(readfile) and has(isfile)
local NO_SAVE = { tp_target = true, troll_target = true, autoload = true, spectate = true, follow = true,
	orbit = true, safe_spot = true, freeze = true, fly = true }

local function encodeValue(v)
	if typeof(v) == "EnumItem" then return { __enum = tostring(v) } end
	return v
end
local function decodeValue(v)
	if type(v) == "table" and type(v.__enum) == "string" then
		local et, item = v.__enum:match("^Enum%.(%w+)%.(%w+)$")
		local ok, res = pcall(function() return Enum[et][item] end)
		return ok and res or nil
	end
	return v
end

local function saveConfig()
	if not canSave then notify("Your executor can't write files.") return end
	local out = {}
	for flag in pairs(Options) do
		if not NO_SAVE[flag] and Flags[flag] ~= nil then out[flag] = encodeValue(Flags[flag]) end
	end
	if has(makefolder) and not (has(isfolder) and isfolder(CONFIG_DIR)) then pcall(makefolder, CONFIG_DIR) end
	local ok = pcall(writefile, CONFIG_FILE, HttpService:JSONEncode(out))
	notify(ok and "Config saved." or "Saving failed.")
end

local function loadConfig(silent)
	if not (canSave and isfile(CONFIG_FILE)) then
		if not silent then notify("No saved config yet.") end
		return
	end
	local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CONFIG_FILE)) end)
	if not ok or type(data) ~= "table" then notify("Config file is broken.") return end
	for flag, v in pairs(data) do
		local opt = Options[flag]
		if opt and opt.Set and not NO_SAVE[flag] then pcall(opt.Set, opt, decodeValue(v)) end
	end
	if not silent then notify("Config loaded.") end
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local Window = Library:CreateWindow({
	Title = NAME .. " - Murder Mystery 2",
	Size = Vector2.new(620, 460),
	ToggleKey = Enum.KeyCode.RightShift,
	Taskbar = true,
	Status = "Ready",
})

-- ESP -------------------------------------------------------------------
local ESP = Window:AddTab("ESP")

local EspPlayers = ESP:AddGroup("Players", "Left")
EspPlayers:AddToggle("esp_murderer", { Text = "Murderer", Default = true })
EspPlayers:AddToggle("esp_sheriff", { Text = "Sheriff / Hero", Default = true })
EspPlayers:AddToggle("esp_innocent", { Text = "Innocents" })
EspPlayers:AddToggle("esp_round_only", { Text = "Only Players In Round", Default = true, Tooltip = "Hides people standing in the lobby" })
EspPlayers:AddDropdown("esp_parts", { Text = "Draw", Values = { "Outline", "Name", "Role", "Distance", "Health", "Tracer" }, Multi = true, Default = { "Outline", "Name", "Role" } })
EspPlayers:AddSlider("esp_distance", { Text = "Max Distance", Min = 50, Max = 2000, Default = 1000, Suffix = " studs" })

local EspStyle = ESP:AddGroup("Outline Style", "Right")
EspStyle:AddToggle("esp_walls", { Text = "Show Through Walls", Default = true })
EspStyle:AddSlider("esp_fill", { Text = "Fill Opacity", Min = 0, Max = 100, Default = 15, Suffix = "%", Tooltip = "0 = outline only" })
EspStyle:AddLabel("Red = murderer, blue = sheriff, gold = hero, green = innocent.", { Color = Library.Theme.TextDim })
if not hasDrawing then EspStyle:AddLabel("Tracers need the Drawing library, your executor doesn't have it.", { Color = Library.Theme.TextDim }) end

local EspItems = ESP:AddGroup("Items", "Right")
EspItems:AddToggle("gun_esp", { Text = "Dropped Gun", Default = true })
EspItems:AddToggle("coin_esp", { Text = "Coins", Callback = function(v) if not v then clearCoinEsp() end end })

-- Combat ------------------------------------------------------------------
local Combat = Window:AddTab("Combat")

local Sheriff = Combat:AddGroup("Sheriff", "Left")
Sheriff:AddToggle("silent_aim", { Text = "Silent Aim", Tooltip = "Gun shots land on the murderer wherever you click", Callback = function(v)
	if v and not hookReady then notify("Silent aim needs hookmetamethod, your executor doesn't have it.") end
end })
Sheriff:AddSlider("hit_chance", { Text = "Hit Chance", Min = 0, Max = 100, Default = 100, Suffix = "%" })
Sheriff:AddDropdown("aim_part", { Text = "Aim Part", Values = { "Head", "Torso", "HumanoidRootPart" }, Default = "HumanoidRootPart" })
Sheriff:AddSlider("prediction", { Text = "Prediction", Min = 0, Max = 300, Default = 120, Suffix = " ms", Tooltip = "Leads the target by their velocity" })
Sheriff:AddToggle("auto_shoot", { Text = "Auto Shoot Murderer", Tooltip = "Fires when the murderer is in line of sight. Pair with Silent Aim." })
Sheriff:AddKeybind("shoot_key", { Text = "Shoot Murderer", Default = Enum.KeyCode.E, Callback = function()
	if not shootMurderer(false) then notify("Need the gun and a living murderer.", nil, 2) end
end })

local Murderer = Combat:AddGroup("Murderer", "Right")
Murderer:AddToggle("knife_aura", { Text = "Knife Aura", Callback = function(v)
	if v and not touch then notify("Knife aura needs firetouchinterest, your executor doesn't have it.") end
end })
Murderer:AddSlider("aura_range", { Text = "Aura Range", Min = 5, Max = 25, Default = 12, Suffix = " studs" })
Murderer:AddToggle("auto_equip", { Text = "Auto Equip Knife", Default = true })
Murderer:AddToggle("throw_assist", { Text = "Throw Assist", Tooltip = "Knife throws hit whoever's closest to your cursor", Callback = function(v)
	if v and not hookReady then notify("Throw assist needs hookmetamethod, your executor doesn't have it.") end
end })
Murderer:AddDivider()
Murderer:AddButton({ Text = "Kill All", Callback = killAll })

-- Teleport ----------------------------------------------------------------
local Teleport = Window:AddTab("Teleport")

local Places = Teleport:AddGroup("Places", "Left")
Places:AddButton({ Text = "Lobby", Callback = tpLobby })
Places:AddButton({ Text = "Map", Callback = tpMap })
Places:AddButton({ Text = "Dropped Gun", Callback = tpGun })
Places:AddDivider()
Places:AddToggle("safe_spot", { Text = "Safe Spot", Tooltip = "Parks you on a platform high above the map. Turn off to go back.", Callback = setSafeSpot })
Places:AddToggle("click_tp", { Text = "Ctrl + Click Teleport" })

local ToPlayer = Teleport:AddGroup("Players", "Right")
local tpTarget = ToPlayer:AddDropdown("tp_target", { Text = "Player", Values = otherNames() })
ToPlayer:AddButton({ Text = "Teleport To Player", Callback = function() tpPlayer(findPlayer(Flags.tp_target), "Player") end })
ToPlayer:AddButton({ Text = "Teleport To Murderer", Callback = function() tpPlayer(findRole("Murderer"), "Murderer") end })
ToPlayer:AddButton({ Text = "Teleport To Sheriff", Callback = function() tpPlayer(findSheriff(), "Sheriff") end })

-- Trolling ----------------------------------------------------------------
local Trolling = Window:AddTab("Trolling")

local Target = Trolling:AddGroup("Target", "Left")
local trollTarget = Target:AddDropdown("troll_target", { Text = "Player", Values = otherNames() })
Target:AddToggle("spectate", { Text = "Spectate" })
Target:AddToggle("follow", { Text = "Follow" })
Target:AddToggle("orbit", { Text = "Orbit" })
Target:AddSlider("orbit_speed", { Text = "Orbit Speed", Min = 1, Max = 20, Default = 5 })
Target:AddSlider("orbit_radius", { Text = "Orbit Radius", Min = 3, Max = 20, Default = 6, Suffix = " studs" })

local Fling = Trolling:AddGroup("Fling", "Right")
Fling:AddButton({ Text = "Fling Target", Callback = function()
	local p = findPlayer(Flags.troll_target)
	if p then fling(p) else notify("Pick a target first.") end
end })
Fling:AddButton({ Text = "Fling Murderer", Callback = function()
	local p = findRole("Murderer")
	if p then fling(p) else notify("Murderer not found.") end
end })
Fling:AddButton({ Text = "Fling Sheriff", Callback = function()
	local p = findSheriff()
	if p then fling(p) else notify("Sheriff not found.") end
end })

local Chat = Trolling:AddGroup("Chat", "Right")
Chat:AddButton({ Text = "Announce Roles In Chat", Callback = announceRoles })

local function refreshPlayerLists()
	local names = otherNames()
	tpTarget:SetValues(names)
	trollTarget:SetValues(names)
end
on(Players.PlayerAdded, refreshPlayerLists)
on(Players.PlayerRemoving, function(p)
	removeEsp(p)
	task.defer(refreshPlayerLists)
end)

-- Player ------------------------------------------------------------------
local PlayerTab = Window:AddTab("Player")

local Movement = PlayerTab:AddGroup("Movement", "Left")
Movement:AddSlider("walkspeed", { Text = "WalkSpeed", Min = 16, Max = 100, Default = 16, Callback = function(v)
	local h = myHum(); if h then h.WalkSpeed = v end
end })
Movement:AddSlider("jumppower", { Text = "JumpPower", Min = 50, Max = 200, Default = 50, Callback = function(v)
	local h = myHum(); if h then h.UseJumpPower = true; h.JumpPower = v end
end })
Movement:AddToggle("inf_jump", { Text = "Infinite Jump" })
Movement:AddToggle("noclip", { Text = "Noclip" })
Movement:AddToggle("anti_fling", { Text = "Anti Fling", Tooltip = "Other players can't push or fling you" })

local Fly = PlayerTab:AddGroup("Fly", "Right")
Fly:AddToggle("fly", { Text = "Fly", Tooltip = "WASD, Space up, Ctrl down" })
Fly:AddKeybind("fly_key", { Text = "Fly Key", Default = Enum.KeyCode.F, Callback = function()
	Options.fly:Set(not Flags.fly)
end })
Fly:AddSlider("fly_speed", { Text = "Fly Speed", Min = 10, Max = 150, Default = 50 })

-- Graphics ----------------------------------------------------------------
local Graphics = Window:AddTab("Graphics")

local LightingGroup = Graphics:AddGroup("Lighting", "Left")
LightingGroup:AddToggle("fullbright", { Text = "Fullbright" })
LightingGroup:AddToggle("no_fog", { Text = "No Fog" })
LightingGroup:AddToggle("no_shadows", { Text = "No Shadows" })
LightingGroup:AddToggle("custom_time", { Text = "Custom Time" })
LightingGroup:AddSlider("clock_time", { Text = "Time Of Day", Min = 0, Max = 24, Default = 14, Rounding = 1, Suffix = "h" })

local CameraGroup = Graphics:AddGroup("Camera", "Right")
CameraGroup:AddSlider("fov", { Text = "Field of View", Min = 70, Max = 120, Default = 70, Callback = function(v) cam().FieldOfView = v end })
CameraGroup:AddToggle("unlock_zoom", { Text = "Unlock Zoom", Callback = function(v)
	LP.CameraMaxZoomDistance = v and 1000 or savedZoom
end })
CameraGroup:AddToggle("fps_boost", { Text = "FPS Boost", Tooltip = "Strips materials, textures and particles", Callback = setFpsBoost })

local XrayGroup = Graphics:AddGroup("X-Ray", "Right")
XrayGroup:AddToggle("xray", { Text = "X-Ray Map", Callback = function(v) if not v then clearXray() end end })
XrayGroup:AddSlider("xray_amount", { Text = "Wall Transparency", Min = 10, Max = 90, Default = 60, Suffix = "%" })

-- Misc --------------------------------------------------------------------
local Misc = Window:AddTab("Misc")

local Roles = Misc:AddGroup("Roles", "Left")
Roles:AddToggle("role_notify", { Text = "Role Notifier", Default = true })
Roles:AddToggle("gun_notify", { Text = "Gun Drop Notifier", Default = true })
local murdererLabel = Roles:AddLabel("Murderer: -")
local sheriffLabel = Roles:AddLabel("Sheriff: -")
local myRoleLabel = Roles:AddLabel("You: -")

local Server = Misc:AddGroup("Server", "Right")
Server:AddToggle("anti_afk", { Text = "Anti AFK", Default = true })
Server:AddToggle("auto_rejoin", { Text = "Auto Rejoin On Kick" })
Server:AddButton({ Text = "Rejoin Server", Callback = rejoin })
Server:AddButton({ Text = "Server Hop", Callback = serverHop })
Server:AddButton({ Text = "Copy Server ID", Callback = function()
	if has(setclipboard) then setclipboard(game.JobId); notify("Server ID copied.") else notify("Your executor has no setclipboard.") end
end })

-- Autofarm ----------------------------------------------------------------
local Autofarm = Window:AddTab("Autofarm")

local Coins = Autofarm:AddGroup("Coins", "Left")
Coins:AddToggle("coin_farm", { Text = "Auto Collect Coins", Callback = function(v) if not v then farmNoclip = false end end })
Coins:AddSlider("farm_speed", { Text = "Farm Speed", Min = 1, Max = 10, Default = 4, Tooltip = "Higher is faster but easier to get kicked for" })
Coins:AddToggle("avoid_murderer", { Text = "Avoid Murderer", Default = true })
Coins:AddSlider("avoid_radius", { Text = "Avoid Radius", Min = 10, Max = 60, Default = 25, Suffix = " studs" })
Coins:AddToggle("reset_full", { Text = "Reset When Bag Full" })
Coins:AddSlider("bag_size", { Text = "Bag Size", Min = 10, Max = 50, Default = 40, Tooltip = "40 normally, 50 with Elite" })
coinLabel = Coins:AddLabel("Collected this round: 0")

local Gun = Autofarm:AddGroup("Gun", "Right")
Gun:AddToggle("grab_gun", { Text = "Auto Grab Dropped Gun" })
Gun:AddToggle("gun_return", { Text = "Return After Grabbing", Default = true })
Gun:AddButton({ Text = "Grab Gun Now", Callback = function()
	if State.gun then task.spawn(grabGun) else notify("The gun isn't dropped.") end
end })

-- Fun ---------------------------------------------------------------------
local Fun = Window:AddTab("Fun")

local Character = Fun:AddGroup("Character", "Left")
Character:AddToggle("spin", { Text = "Spin" })
Character:AddSlider("spin_speed", { Text = "Spin Speed", Min = 1, Max = 50, Default = 10 })
Character:AddToggle("jump_spam", { Text = "Jump Spam" })
Character:AddToggle("freeze", { Text = "Freeze In Place" })
Character:AddButton({ Text = "Sit", Callback = function() local h = myHum(); if h then h.Sit = true end end })

local Emotes = Fun:AddGroup("Emotes", "Right")
Emotes:AddDropdown("emote", { Text = "Emote", Values = EMOTE_ORDER, Default = "Dance" })
Emotes:AddButton({ Text = "Play Emote", Callback = function() playEmote(Flags.emote) end })
Emotes:AddButton({ Text = "Stop Emote", Callback = stopEmote })
Emotes:AddLabel("Walking cancels the emote.", { Color = Library.Theme.TextDim })

-- Settings ----------------------------------------------------------------
local Settings = Window:AddTab("Settings")

local Menu = Settings:AddGroup("Menu", "Left")
Menu:AddKeybind("menu_key", {
	Text = "Toggle UI",
	Default = Library.ToggleKey,
	Changed = function(key)
		if key and key.EnumType == Enum.KeyCode then
			Library.ToggleKey = key
			Library:_updateHint()
		end
	end,
})
Menu:AddToggle("show_taskbar", { Text = "Show Taskbar", Default = true, Callback = function(v) Library:SetTaskbar(v) end })
Menu:AddDivider()
Menu:AddButton({ Text = "Unload", Callback = function() Library:Unload() end })

local Config = Settings:AddGroup("Config", "Left")
Config:AddButton({ Text = "Save Config", Callback = saveConfig })
Config:AddButton({ Text = "Load Config", Callback = function() loadConfig(false) end })
Config:AddToggle("autoload", { Text = "Load Config On Start", Default = canSave and isfile(AUTOLOAD_FILE), Callback = function(v)
	if not canSave then return end
	if v then
		if has(makefolder) then pcall(makefolder, CONFIG_DIR) end
		pcall(writefile, AUTOLOAD_FILE, "1")
	elseif has(delfile) and isfile(AUTOLOAD_FILE) then
		pcall(delfile, AUTOLOAD_FILE)
	end
end })

local About = Settings:AddGroup("About", "Right")
About:AddLabel(NAME .. " v" .. VERSION, { Bold = true })
About:AddLabel("Murder Mystery 2", { Color = Library.Theme.TextDim })
About:AddDivider()
About:AddLabel("The X button only minimizes. Use Turn Off in the Start menu to unload.")

------------------------------------------------------------------------
-- Runtime loops
------------------------------------------------------------------------

-- player data (role, dead) straight from the game, when the remote exists
local dataRemote = ReplicatedStorage:FindFirstChild("GetPlayerData", true)
task.spawn(function()
	while running() do
		if dataRemote and dataRemote:IsA("RemoteFunction") then
			local ok, res = pcall(dataRemote.InvokeServer, dataRemote)
			if ok and type(res) == "table" then State.data = res end
		end
		task.wait(1)
	end
end)

-- dropped gun tracking
State.gun = workspace:FindFirstChild("GunDrop", true)
on(workspace.DescendantAdded, function(d)
	if d.Name == "GunDrop" then
		State.gun = d
		if Flags.gun_notify then notify("The gun was dropped.", "Gun") end
	end
end)
on(workspace.DescendantRemoving, function(d)
	if d == State.gun then State.gun = nil end
end)

-- round state, labels, notifier, slow-tick features
local announced = {}
task.spawn(function()
	while running() do
		local hadMap = State.map ~= nil
		State.map = findMap()
		updateLobbyBox()
		if hadMap and not State.map then
			announced = {}
			setCollected(0)
		end

		local m, s = findRole("Murderer"), findSheriff()
		murdererLabel:Set("Murderer: " .. (m and m.DisplayName or "-"))
		sheriffLabel:Set("Sheriff: " .. (s and s.DisplayName or "-"))
		myRoleLabel:Set("You: " .. (State.map and inRound(LP) and roleOf(LP) or "-"))
		Window:SetStatus(State.map and ("Round live  |  Murderer: " .. (m and m.DisplayName or "?")) or "Waiting for round")

		if Flags.role_notify and State.map then
			if m and announced.m ~= m then
				announced.m = m
				notify(m.DisplayName .. (m == LP and " (you)" or ""), "Murderer", 6)
			end
			if s and announced.s ~= s then
				announced.s = s
				notify(s.DisplayName .. (s == LP and " (you)" or ""), roleOf(s), 6)
			end
		end

		updateLighting()
		updateXray()
		updateCoinEsp()
		if Flags.grab_gun and State.gun and inRound(LP) and not busy then task.spawn(grabGun) end
		task.wait(0.5)
	end
end)

-- combat ticks
task.spawn(function()
	while running() do
		if inRound(LP) and not busy then
			if Flags.knife_aura then pcall(knifeAura) end
			if Flags.auto_shoot then pcall(shootMurderer, true) end
		end
		task.wait(0.05)
	end
end)

-- coin farm
task.spawn(function()
	while running() do
		if Flags.coin_farm and inRound(LP) and not busy then
			local ok, err = pcall(farmStep)
			if not ok then warn("[xpware] farm:", err); task.wait(0.5) end
		else
			farmNoclip = false
			task.wait(0.3)
		end
	end
	farmNoclip = false
end)

-- per-frame: ESP, fly, camera, target tools
local spectating = false
on(RunService.RenderStepped, function()
	updatePlayerEsp()
	updateGunEsp()
	updateFly()
	if Flags.fov ~= 70 then cam().FieldOfView = Flags.fov end

	local target = findPlayer(Flags.troll_target)
	local th = humOf(target)
	if Flags.spectate and th then
		cam().CameraSubject = th
		spectating = true
	elseif spectating then
		spectating = false
		local h = myHum()
		if h then cam().CameraSubject = h end
	end
end)
onUnload(function()
	local h = myHum()
	if spectating and h then cam().CameraSubject = h end
end)

local orbitAngle = 0
on(RunService.Heartbeat, function(dt)
	local h, r = myHum(), myRoot()
	if h then
		if Flags.walkspeed ~= 16 and h.WalkSpeed ~= Flags.walkspeed then h.WalkSpeed = Flags.walkspeed end
		if Flags.jumppower ~= 50 and h.JumpPower ~= Flags.jumppower then h.UseJumpPower = true; h.JumpPower = Flags.jumppower end
	end
	if r and not busy then
		local tr = rootOf(findPlayer(Flags.troll_target))
		if tr and Flags.orbit then
			orbitAngle += dt * Flags.orbit_speed * 0.6
			local pos = tr.Position + Vector3.new(math.cos(orbitAngle), 0, math.sin(orbitAngle)) * Flags.orbit_radius
			r.CFrame = CFrame.lookAt(pos, tr.Position)
			r.AssemblyLinearVelocity = Vector3.zero
		elseif tr and Flags.follow then
			r.CFrame = tr.CFrame * CFrame.new(0, 0, 3)
			r.AssemblyLinearVelocity = Vector3.zero
		end
	end
	updateFun(dt)
end)

on(RunService.Stepped, function()
	updateNoclip()
	updateAntiFling()
end)

on(UIS.JumpRequest, function()
	local h = myHum()
	if Flags.inf_jump and h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

on(UIS.InputBegan, function(input, gp)
	if gp or not Flags.click_tp then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 and UIS:IsKeyDown(Enum.KeyCode.LeftControl) then
		local hit = LP:GetMouse().Hit
		if hit then teleport(CFrame.new(hit.Position + Vector3.new(0, 3, 0))) end
	end
end)

on(LP.Idled, function()
	if not Flags.anti_afk then return end
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
end)

on(GuiService.ErrorMessageChanged, function(msg)
	if Flags.auto_rejoin and msg and msg ~= "" then
		task.wait(2)
		rejoin()
	end
end)

-- new character: walkspeed/jump re-applied by Heartbeat, but fly/emote state belongs to the old body
on(LP.CharacterAdded, function()
	stopFly()
	stopEmote()
	noclipped = {}
	spinning, frozen = false, false
	safeReturn = nil -- don't drag the new body back to where the old one was
	if Flags.safe_spot then Options.safe_spot:Set(false) end
end)

if canSave and isfile(AUTOLOAD_FILE) then loadConfig(true) end

local missing = {}
if not touch then table.insert(missing, "firetouchinterest") end
if not hookReady then table.insert(missing, "hookmetamethod") end
if not hasDrawing then table.insert(missing, "Drawing") end
local extra = #missing > 0 and ("\nMissing: " .. table.concat(missing, ", ") .. " (some features are off).") or ""
notify("Loaded. Press " .. Library.ToggleKey.Name .. " to hide or show." .. extra, NAME, 6)
