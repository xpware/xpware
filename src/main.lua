--[[
	xpware - Murder Mystery 2
	Engine: Roblox client (executor)  |  Language: Luau

	Every tab is built. Each tab after Teleport lives in its own do ... end block:
	the main chunk can only hold 200 live locals.
	Where the library comes from:
	  - bundled by build.ps1: `Library` is defined above this file
	  - Roblox Studio: ReplicatedStorage.xpware.xpui ModuleScript
	  - executor, unbundled: xpware/xpui.lua in the executor's workspace folder
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

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local UIS               = game:GetService("UserInputService")

local LP = Players.LocalPlayer
local Flags = Library.Flags
local Options = Library.Options

local NAME = "xpware"
local VERSION = "1.1.1"
local function notify(text, title, dur) Library:Notify(title or NAME, text, dur or 3) end

------------------------------------------------------------------------
-- Lifetime: every connection and cleanup goes through here so Unload is total
------------------------------------------------------------------------
local conns, cleanups = {}, {}
local function on(signal, fn)
	local c = signal:Connect(fn)
	table.insert(conns, c)
	return c
end
local function onUnload(fn) table.insert(cleanups, fn) end
local function running() return not Library.Unloaded end

Library:OnUnload(function()
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for i = #cleanups, 1, -1 do pcall(cleanups[i]) end
end)

local function cam() return workspace.CurrentCamera end

-- theme: picked once on the first run and kept in its own file, since it has to be applied
-- before the window is built (settings only load after the UI exists)
local THEME_FILE = "xpware/theme.txt"
local canWriteTheme = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"

local function readTheme()
	if not canWriteTheme then return nil end
	local ok, name = pcall(function() return isfile(THEME_FILE) and readfile(THEME_FILE) or nil end)
	name = ok and type(name) == "string" and name:gsub("%s+", "") or nil
	return (name and Library.Themes[name]) and name or nil
end

local function writeTheme(name)
	if not canWriteTheme then return end
	pcall(function()
		if typeof(makefolder) == "function" and not (typeof(isfolder) == "function" and isfolder("xpware")) then
			makefolder("xpware")
		end
		writefile(THEME_FILE, name)
	end)
end

local themeName = readTheme()
if not themeName then
	themeName = Library:PickTheme({ Title = NAME .. " - Murder Mystery 2" })
	writeTheme(themeName)
end
Library:SetTheme(themeName)

-- window first: the ESP folder mounts next to Library.Gui, which only exists after this
local Window = Library:CreateWindow({
	Title = NAME .. " - Murder Mystery 2",
	Size = Vector2.new(620, 460),
	ToggleKey = Enum.KeyCode.RightShift,
	Status = "Ready",
})

------------------------------------------------------------------------
-- Character helpers
------------------------------------------------------------------------
local function humOf(p) local c = p and p.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function rootOf(p) local c = p and p.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function isAlive(p) local h = humOf(p); return h ~= nil and h.Health > 0 and rootOf(p) ~= nil end
local function myRoot() return rootOf(LP) end
local function myHum() return humOf(LP) end

local function partOf(inst)
	if not inst then return nil end
	if inst:IsA("BasePart") then return inst end
	if inst:IsA("Model") then return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true) end
	return inst:FindFirstChildWhichIsA("BasePart", true)
end

------------------------------------------------------------------------
-- MM2 game state (names confirmed from an in-game dump)
--   map:    workspace.<MapName> with CoinContainer + Spawns
--   coins:  CoinContainer.Coin_Server (Part) > CoinVisual (MeshPart), TouchInterest while collectable
--   lobby:  workspace.Lobby
--   roles:  Remotes.Extras.GetPlayerData -> { [name] = { Role, Dead, Killed, Coins, ... } }
--   tools:  Knife / Gun in Backpack or Character
--   gun drop: Workspace.<Map>.GunDrop
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

local function isMapCandidate(m)
	return m.Name ~= "Lobby" and (m:IsA("Model") or m:IsA("Folder")) and not Players:GetPlayerFromCharacter(m)
end

-- MM2 streams the map, so its children show up gradually. Try the cheap checks first, then
-- fall back to a deep search for CoinContainer (rate limited, it walks the whole workspace).
local lastDeepSearch = 0
local function findMap()
	for _, m in ipairs(workspace:GetChildren()) do
		if isMapCandidate(m) and m:FindFirstChild("CoinContainer") then return m end
	end
	for _, m in ipairs(workspace:GetChildren()) do
		if isMapCandidate(m) and m:FindFirstChild("Spawns") then return m end
	end
	if os.clock() - lastDeepSearch > 3 then
		lastDeepSearch = os.clock()
		local cc = workspace:FindFirstChild("CoinContainer", true)
		local top = cc
		while top and top.Parent ~= workspace do top = top.Parent end
		if top and isMapCandidate(top) then return top end
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

-- game data first (knows roles before anyone pulls a weapon), tools as the live override
local function roleOf(p)
	if hasTool(p, "Knife") then return "Murderer" end
	local d = dataOf(p)
	local r = d and d.Role
	if hasTool(p, "Gun") then return (r == nil or r == "Sheriff") and "Sheriff" or "Hero" end
	if r == "Murderer" or r == "Sheriff" or r == "Hero" then return r end
	return "Innocent"
end

local function isDead(p)
	local d = dataOf(p)
	return d ~= nil and (d.Dead == true or d.Killed == true)
end

-- alive, not marked dead by the game, not standing in the lobby. Deliberately does NOT need the
-- map: MM2 streams the map in, so CoinContainer can be missing mid-round and that hid everyone.
local function inRound(p)
	return isAlive(p) and not isDead(p) and not inLobby(p)
end

local function isCoinLive(c)
	if not (c and c.Parent and c:IsA("BasePart")) then return false end
	if not c:FindFirstChildOfClass("TouchTransmitter") then return false end
	local v = c:FindFirstChild("CoinVisual")
	return not (v and v:IsA("BasePart") and v.Transparency >= 1)
end

local function liveCoins()
	local list = {}
	local cc = State.map and State.map:FindFirstChild("CoinContainer", true)
	if cc then
		for _, c in ipairs(cc:GetChildren()) do
			if isCoinLive(c) then table.insert(list, c) end
		end
	end
	return list
end

------------------------------------------------------------------------
-- ESP: Highlight outlines + billboard text + Drawing tracers
------------------------------------------------------------------------
local espFolder = Instance.new("Folder")
espFolder.Name = HttpService:GenerateGUID(false)
if not pcall(function() espFolder.Parent = Library.Gui.Parent end) or not espFolder.Parent then
	espFolder.Parent = LP:WaitForChild("PlayerGui")
end
onUnload(function() espFolder:Destroy() end)

local hasDrawing = typeof(Drawing) == "table" and typeof(Drawing.new) == "function"

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

-- only write when the value actually changes; rewriting render props every frame causes flicker
local function set(obj, prop, value)
	if obj[prop] ~= value then obj[prop] = value end
end

local function outlineAlpha() return 1 - (Flags.esp_outline_opacity or 100) / 100 end
local function fillAlpha() return 1 - (Flags.esp_fill or 0) / 100 end

local function styleHighlight(hl, color, fillOverride)
	set(hl, "OutlineColor", color)
	set(hl, "FillColor", color)
	set(hl, "OutlineTransparency", outlineAlpha())
	set(hl, "FillTransparency", fillOverride or fillAlpha())
	set(hl, "DepthMode", Flags.esp_walls and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded)
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
	set(o.hl, "Enabled", false)
	set(o.bb, "Enabled", false)
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

local function updatePlayerEsp()
	if not Flags.esp_enabled then
		for _, o in pairs(espObjs) do hideEsp(o) end
		return
	end
	local parts = Flags.esp_parts or {}
	local me = myRoot()
	local camera = cam()
	local vp = camera.ViewportSize
	-- as the murderer you see everyone, whatever the role toggles say; it lapses when you stop being it
	local murderMode = Flags.esp_murder_all and roleOf(LP) == "Murderer"
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local o = espObjs[p] or makeEsp(p)
			local c, r, h = p.Character, rootOf(p), humOf(p)
			local role = roleOf(p)
			local show = c ~= nil and r ~= nil and h ~= nil and h.Health > 0 and (murderMode or roleShown(role))
			if show and Flags.esp_round_only and not inRound(p) then show = false end
			local dist = (show and me) and (r.Position - me.Position).Magnitude or 0

			if not show then
				hideEsp(o)
			else
				local color = ROLE_COLORS[role]

				set(o.hl, "Adornee", c)
				styleHighlight(o.hl, color)
				set(o.hl, "Enabled", parts.Chams == true)

				local top, bottom = {}, {}
				if parts.Name then table.insert(top, p.DisplayName) end
				if parts.Role then table.insert(top, "[" .. role .. "]") end
				if parts.Distance then table.insert(bottom, math.floor(dist) .. "m") end
				if parts.Health then table.insert(bottom, math.floor(h.Health) .. " hp") end
				local text = table.concat(top, " ")
				if #bottom > 0 then text = text .. (text ~= "" and "\n" or "") .. table.concat(bottom, "  ") end
				set(o.bb, "Adornee", c:FindFirstChild("Head") or r)
				set(o.label, "Text", text)
				set(o.label, "TextColor3", color)
				set(o.bb, "Enabled", text ~= "")

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
gunBB.StudsOffset = Vector3.new(0, 2, 0)

local function updateGunEsp()
	local gun = State.gun
	if Flags.esp_enabled and Flags.gun_esp and gun and gun.Parent then
		set(gunHl, "Adornee", gun)
		styleHighlight(gunHl, GUN_COLOR, 0.4)
		set(gunHl, "Enabled", true)
		set(gunBB, "Adornee", partOf(gun))
		set(gunBB, "Enabled", true)
	else
		set(gunHl, "Enabled", false)
		set(gunBB, "Enabled", false)
	end
end

-- coins: a Highlight on each coin's mesh, so the outline follows the coin's own shape.
-- Roblox draws at most 255 Highlights at once and the players and the gun use some, so when
-- there are more coins than COIN_ESP_MAX only the nearest ones get an outline.
local COIN_ESP_MAX = 150
local coinHls = {}
local function clearCoinEsp()
	for coin, hl in pairs(coinHls) do hl:Destroy(); coinHls[coin] = nil end
end
onUnload(clearCoinEsp)

local function updateCoinEsp()
	if not (Flags.esp_enabled and Flags.coin_esp) then clearCoinEsp() return end
	local coins = liveCoins()
	if #coins > COIN_ESP_MAX then
		local me = myRoot()
		if me then
			table.sort(coins, function(a, b)
				return (a.Position - me.Position).Magnitude < (b.Position - me.Position).Magnitude
			end)
			for i = #coins, COIN_ESP_MAX + 1, -1 do coins[i] = nil end
		end
	end
	local live = {}
	for _, coin in ipairs(coins) do
		live[coin] = true
		local hl = coinHls[coin]
		if not hl then
			hl = newHighlight()
			local visual = coin:FindFirstChild("CoinVisual")
			hl.Adornee = (visual and visual:IsA("BasePart")) and visual or coin
			coinHls[coin] = hl
		end
		-- same opacity / see-through settings as the player outlines
		styleHighlight(hl, COIN_COLOR)
		set(hl, "Enabled", true)
	end
	for coin, hl in pairs(coinHls) do
		if not live[coin] then hl:Destroy(); coinHls[coin] = nil end
	end
end

------------------------------------------------------------------------
-- Teleport
------------------------------------------------------------------------
local function findPlayer(name)
	if type(name) ~= "string" or name == "" then return nil end
	local p = Players:FindFirstChild(name)
	return (p and p:IsA("Player")) and p or nil
end

local function findRole(role)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and inRound(p) and roleOf(p) == role then return p end
	end
end
local function findSheriff() return findRole("Sheriff") or findRole("Hero") end
-- like findRole, but counts you too (role labels, announcements)
local function anyoneWith(role)
	for _, p in ipairs(Players:GetPlayers()) do
		if inRound(p) and roleOf(p) == role then return p end
	end
end

-- the map streams in, so ask the server to load the destination before we land there
local function streamTo(pos)
	if workspace.StreamingEnabled then
		pcall(function() LP:RequestStreamAroundAsync(pos, 1.5) end)
	end
end

local function teleport(cf, skipStream)
	local c, r, h = LP.Character, myRoot(), myHum()
	if not (c and r) then notify("You don't have a character right now.") return false end
	if not skipStream then streamTo(cf.Position) end
	if h and h.Sit then h.Sit = false end
	r.AssemblyLinearVelocity = Vector3.zero
	c:PivotTo(cf)
	return true
end

local function spawnCFrame(model)
	local spawns = model and model:FindFirstChild("Spawns")
	local list = {}
	if spawns then
		for _, s in ipairs(spawns:GetDescendants()) do
			if s:IsA("BasePart") then table.insert(list, s) end
		end
	end
	if #list > 0 then return list[math.random(#list)].CFrame + Vector3.new(0, 4, 0) end
end

local function tpLobby()
	local lobby = workspace:FindFirstChild("Lobby")
	if not lobby then notify("Couldn't find the lobby.") return end
	local cf = spawnCFrame(lobby) or (lobby:GetPivot() + Vector3.new(0, 5, 0))
	teleport(cf)
end

local function tpMap()
	local map = State.map or findMap()
	if not map then notify("No round running right now.") return end
	-- spawns may not be streamed in yet: load around the map first, then look again
	local cf = spawnCFrame(map)
	if not cf then
		streamTo(map:GetPivot().Position)
		cf = spawnCFrame(map)
	end
	if not cf then notify("The map's spawns haven't loaded yet, try again in a second.") return end
	teleport(cf)
end

local function tpGun()
	local part = partOf(State.gun)
	if not part then notify("The gun isn't dropped.") return end
	teleport(part.CFrame + Vector3.new(0, 3, 0))
end

local function tpPlayer(p, label)
	local r = rootOf(p)
	if not r then notify(label .. " not found.") return end
	teleport(r.CFrame * CFrame.new(0, 0, 3))
end

-- safe spot: a platform only we can see, 300 studs above where we were standing
local safePart, safeReturn
local function setSafeSpot(on)
	if on then
		local r = myRoot()
		if not r then
			notify("You don't have a character right now.")
			task.defer(function() Options.safe_spot:Set(false) end)
			return
		end
		safeReturn = r.CFrame
		safePart = Instance.new("Part")
		safePart.Name = HttpService:GenerateGUID(false)
		safePart.Anchored = true
		safePart.Size = Vector3.new(20, 1, 20)
		safePart.Transparency = 0.5
		safePart.Position = r.Position + Vector3.new(0, 300, 0)
		safePart.Parent = workspace
		teleport(safePart.CFrame + Vector3.new(0, 3.5, 0), true)
	else
		if safeReturn and myRoot() then teleport(safeReturn) end
		if safePart then safePart:Destroy() end
		safePart, safeReturn = nil, nil
	end
end
onUnload(function() if safePart then safePart:Destroy() end end)

local function otherNames()
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then table.insert(t, p.Name) end
	end
	table.sort(t, function(a, b) return a:lower() < b:lower() end)
	return t
end

------------------------------------------------------------------------
-- ESP
------------------------------------------------------------------------
local ESP = Window:AddTab("ESP")
ESP:AddMasterToggle("esp_enabled", { Text = "ESP", Default = true, Tooltip = "Master switch for all ESP: players, gun and coins" })

local EspPlayers = ESP:AddGroup("Players", "Left")
-- these are all read every frame from Flags, so they don't need callbacks
EspPlayers:AddToggle("esp_murderer", { Text = "Murderer", Default = true })
EspPlayers:AddToggle("esp_sheriff", { Text = "Sheriff / Hero", Default = true })
EspPlayers:AddToggle("esp_innocent", { Text = "Innocents" })
EspPlayers:AddToggle("esp_murder_all", { Text = "Everyone While Murderer", Default = true, Tooltip = "While you're the murderer, outline everyone even if Innocents is off" })
EspPlayers:AddToggle("esp_round_only", { Text = "Only Players In Round", Default = true, Tooltip = "Hides dead players and anyone in the lobby" })
EspPlayers:AddDropdown("esp_parts", { Text = "Draw", Values = { "Chams", "Name", "Role", "Distance", "Health", "Tracer" }, Multi = true, Default = { "Chams", "Name", "Role" } })
local dataLabel = EspPlayers:AddLabel("Role data: waiting...", { Color = Library.Theme.TextDim })

local EspStyle = ESP:AddGroup("Chams Style", "Right")
EspStyle:AddSlider("esp_outline_opacity", { Text = "Outline Opacity", Min = 10, Max = 100, Default = 100, Suffix = "%" })
EspStyle:AddSlider("esp_fill", { Text = "Fill Opacity", Min = 0, Max = 100, Default = 0, Suffix = "%", Tooltip = "0 = outline only" })
EspStyle:AddToggle("esp_walls", { Text = "Show Through Walls", Default = true })
EspStyle:AddLabel("Red = murderer, blue = sheriff, gold = hero, green = innocent.", { Color = Library.Theme.TextDim })
if not hasDrawing then
	EspStyle:AddLabel("Tracers need the Drawing library, which this environment doesn't have.", { Color = Library.Theme.TextDim })
end

local EspItems = ESP:AddGroup("Items", "Right")
EspItems:AddToggle("gun_esp", { Text = "Dropped Gun", Default = true })
EspItems:AddToggle("coin_esp", { Text = "Coins", Callback = function(v) if not v then clearCoinEsp() end end })

local busy = false        -- true while a fling is driving the character
local forceNoclip = false -- the coin farm turns on noclip through this while it glides

------------------------------------------------------------------------
-- Combat. Names and arguments come from a remote capture:
--   gun:   Gun.Shoot:FireServer(rootCFrame, CFrame.new(aimPosition))
--   throw: Knife.Events.KnifeThrown:FireServer(CFrame, CFrame.new(aimPosition))
--   stab:  Knife.Events.KnifeStabbed:FireServer(), then Knife.Events.HandleTouched:FireServer(part)
--          for every part the blade touched (the client reports its own hits)
-- Wrapped in do ... end: a Lua chunk holds at most 200 live locals and nothing outside this tab
-- needs these helpers. Do the same for the next tabs.
------------------------------------------------------------------------
do
	local GENV = (typeof(getgenv) == "function" and getgenv()) or _G
	local GUN_COOLDOWN = 3     -- seconds between shots; the server reloads the gun and ignores early ones
	local KNIFE_COOLDOWN = 0.5 -- seconds between swings (aura, kill all)
	local hookReady = typeof(hookmetamethod) == "function" and typeof(getnamecallmethod) == "function"

	local lastGunShot, lastStab = 0, 0
	local Aim = { gun = nil, throw = nil } -- where redirected shots go, refreshed every frame

	------------------------------------------------------------------
	-- helpers
	------------------------------------------------------------------
	-- equip and wait until the tool is in the character (its remotes only work from there)
	local function equip(tool)
		local h = myHum()
		if not (tool and h) then return false end
		if tool.Parent ~= LP.Character then
			h:EquipTool(tool)
			local t0 = os.clock()
			while tool.Parent ~= LP.Character and os.clock() - t0 < 0.4 do task.wait() end
		end
		return tool.Parent == LP.Character
	end

	-- where to aim at a player: the chosen body part, led by their velocity
	local function aimPoint(p, partName)
		local c = p and p.Character
		local root = c and c:FindFirstChild("HumanoidRootPart")
		if not root then return nil end
		local part
		if partName == "Head" then
			part = c:FindFirstChild("Head")
		elseif partName == "Torso" then
			part = c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
		end
		part = part or root
		local v = root.AssemblyLinearVelocity
		local lead = (Flags.prediction or 0) / 1000
		return part.Position + Vector3.new(v.X, v.Y * 0.5, v.Z) * lead
	end

	-- the player nearest the cursor (anyone off screen ranks behind everyone on screen)
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

	local function hasSight(p)
		local me = LP.Character
		local head = me and me:FindFirstChild("Head")
		local r = rootOf(p)
		if not (head and r) then return false end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { me, p.Character, espFolder }
		params.RespectCanCollide = true -- coins, effects and other non-solid parts don't block a shot
		return workspace:Raycast(head.Position, r.Position - head.Position, params) == nil
	end

	------------------------------------------------------------------
	-- sheriff
	------------------------------------------------------------------
	local function fireGun(pos)
		local gun = hasTool(LP, "Gun")
		local shoot = gun and gun:FindFirstChild("Shoot")
		local root = myRoot()
		if not (shoot and root) then return false, "you don't have the gun" end
		if not equip(gun) then return false, "couldn't equip the gun" end
		lastGunShot = os.clock()
		shoot:FireServer(root.CFrame, CFrame.new(pos))
		return true
	end

	-- returns true, or false and why not
	local function shootMurderer(needSight)
		if os.clock() - lastGunShot < GUN_COOLDOWN then return false, "the gun is reloading" end
		if not hasTool(LP, "Gun") then return false, "you don't have the gun" end
		local m = findRole("Murderer")
		if not m then return false, "no murderer to shoot" end
		if needSight and not hasSight(m) then return false, "no line of sight" end
		local pos = aimPoint(m, Flags.aim_part)
		if not pos then return false, "the murderer has no character" end
		return fireGun(pos)
	end

	------------------------------------------------------------------
	-- murderer
	------------------------------------------------------------------
	-- one swing, the way the real client sends it: KnifeStabbed once, then HandleTouched per hit
	local function stab(knife, victims)
		local events = knife and knife:FindFirstChild("Events")
		local stabbed = events and events:FindFirstChild("KnifeStabbed")
		local touched = events and events:FindFirstChild("HandleTouched")
		if not (stabbed and touched) then return false end
		lastStab = os.clock()
		stabbed:FireServer()
		for _, p in ipairs(victims) do
			local c = p.Character
			local root = c and c:FindFirstChild("HumanoidRootPart")
			local torso = c and c:FindFirstChild("UpperTorso")
			if root then touched:FireServer(root) end
			if torso then touched:FireServer(torso) end
		end
		return true
	end

	local function knifeAura()
		if os.clock() - lastStab < KNIFE_COOLDOWN then return end
		local me, knife = myRoot(), hasTool(LP, "Knife")
		if not (me and knife) then return end
		local victims, range = {}, Flags.aura_range or 12
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LP and inRound(p) and (rootOf(p).Position - me.Position).Magnitude <= range then
				table.insert(victims, p)
			end
		end
		if #victims == 0 then return end
		if knife.Parent ~= LP.Character and not (Flags.auto_equip and equip(knife)) then return end
		stab(knife, victims)
	end

	local function aliveOthers()
		local list = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LP and inRound(p) then table.insert(list, p) end
		end
		return list
	end

	-- the aura with no range: one swing with every living player in it, wherever they are.
	-- A couple of follow-up swings catch anyone the first one missed. No teleporting.
	local killing = false
	local function killAll()
		if killing then return end
		if not Flags.combat_enabled then notify("Combat is switched off.") return end
		local knife = hasTool(LP, "Knife")
		if not knife then notify("You're not the murderer.") return end
		local victims = aliveOthers()
		local total = #victims
		if total == 0 then notify("Nobody to kill.") return end
		if not equip(knife) then notify("Couldn't equip the knife.") return end
		killing = true
		for _ = 1, 3 do
			local wait = KNIFE_COOLDOWN - (os.clock() - lastStab)
			if wait > 0 then task.wait(wait) end
			stab(knife, victims)
			task.wait(0.35)
			victims = aliveOthers()
			if #victims == 0 then break end
		end
		killing = false
		notify(string.format("Kill All: %d of %d down.", total - #victims, total))
	end

	------------------------------------------------------------------
	-- aim redirect: silent aim (gun) and throw assist (knife)
	------------------------------------------------------------------
	-- refreshed every frame. The hook below only READS these: it runs inside every network call in
	-- the game, and a method call in there would overwrite the namecall the original is about to use.
	local function updateAim()
		Aim.gun, Aim.throw = nil, nil
		if not Flags.combat_enabled then return end
		if Flags.silent_aim then
			local m = findRole("Murderer")
			if m then Aim.gun = aimPoint(m, Flags.aim_part) end
		end
		if Flags.throw_assist then
			local t = closestToCursor()
			if t then Aim.throw = aimPoint(t, "HumanoidRootPart") end
		end
	end

	-- property reads only, no method calls (see above). Returns true if the arguments were changed.
	local function redirect(remote, args)
		if args.n < 2 or typeof(args[2]) ~= "CFrame" then return false end
		local name = remote.Name
		if name == "Shoot" then
			local tool = remote.Parent
			if tool and tool.Name == "Gun" and tool.Parent == LP.Character then
				lastGunShot = os.clock() -- your own shots start the reload too
				local pos = Aim.gun
				if pos and math.random(1, 100) <= (Flags.hit_chance or 100) then
					args[2] = CFrame.new(pos)
					return true
				end
			end
		elseif name == "KnifeThrown" then
			local events = remote.Parent
			local tool = events and events.Parent
			if tool and tool.Name == "Knife" and tool.Parent == LP.Character then
				local pos = Aim.throw
				if pos then
					args[2] = CFrame.new(pos)
					return true
				end
			end
		end
		return false
	end

	if hookReady then
		GENV.__xpware_redirect = redirect
		onUnload(function()
			if GENV.__xpware_redirect == redirect then GENV.__xpware_redirect = nil end
		end)
		-- installed once per session; a re-run just swaps the function the hook calls
		if not GENV.__xpware_hooked then
			GENV.__xpware_hooked = true
			local wrap = typeof(newcclosure) == "function" and newcclosure or function(f) return f end
			local isOurs = typeof(checkcaller) == "function" and checkcaller or function() return false end
			local setMethod = typeof(setnamecallmethod) == "function" and setnamecallmethod or nil
			local getMethod = getnamecallmethod
			local old
			old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
				local method = getMethod()
				if method == "FireServer" then
					local fn = GENV.__xpware_redirect
					if fn and not isOurs() then
						local args = table.pack(...)
						local ok, changed = pcall(fn, self, args)
						if setMethod then setMethod(method) end
						if ok and changed then return old(self, table.unpack(args, 1, args.n)) end
					end
				end
				return old(self, ...)
			end))
		end
	end

	------------------------------------------------------------------
	-- loops
	------------------------------------------------------------------
	on(RunService.RenderStepped, updateAim)

	task.spawn(function()
		local lastErr
		while running() do
			if Flags.combat_enabled and not busy and inRound(LP) then
				local ok, err = pcall(function()
					if Flags.auto_shoot then shootMurderer(true) end
					if Flags.knife_aura then knifeAura() end
				end)
				if not ok and err ~= lastErr then
					lastErr = err
					warn("[xpware] combat: " .. tostring(err))
				end
			end
			task.wait(0.1)
		end
	end)

	------------------------------------------------------------------
	-- tab
	------------------------------------------------------------------
	local Combat = Window:AddTab("Combat")
	Combat:AddMasterToggle("combat_enabled", { Text = "Combat", Default = true, Tooltip = "Master switch for every combat feature" })

	local SheriffBox = Combat:AddGroup("Sheriff", "Left")
	SheriffBox:AddToggle("silent_aim", { Text = "Silent Aim", Tooltip = "Gun shots land on the murderer wherever you click", Callback = function(v)
		if v and not hookReady then
			notify("Silent aim needs hookmetamethod, which this executor doesn't have. Auto Shoot and the shoot key still work.", nil, 6)
		end
	end })
	SheriffBox:AddSlider("hit_chance", { Text = "Hit Chance", Min = 0, Max = 100, Default = 100, Suffix = "%", Tooltip = "Silent Aim only: how often a shot gets redirected" })
	SheriffBox:AddDropdown("aim_part", { Text = "Aim Part", Values = { "Head", "Torso", "HumanoidRootPart" }, Default = "HumanoidRootPart" })
	SheriffBox:AddSlider("prediction", { Text = "Prediction", Min = 0, Max = 300, Default = 120, Suffix = " ms", Tooltip = "Leads the target by their velocity (gun and knife throws)" })
	SheriffBox:AddToggle("auto_shoot", { Text = "Auto Shoot Murderer", Tooltip = "Shoots as soon as you have line of sight. Works without Silent Aim." })
	SheriffBox:AddKeybind("shoot_key", { Text = "Shoot Murderer", Default = Enum.KeyCode.E, Callback = function()
		if not Flags.combat_enabled then notify("Combat is switched off.", nil, 2) return end
		local ok, why = shootMurderer(false)
		if not ok and why then notify("Can't shoot: " .. why .. ".", nil, 2) end
	end })

	local MurdererBox = Combat:AddGroup("Murderer", "Right")
	MurdererBox:AddToggle("knife_aura", { Text = "Knife Aura", Tooltip = "Stabs everyone inside the range slider" })
	MurdererBox:AddSlider("aura_range", { Text = "Aura Range", Min = 5, Max = 25, Default = 12, Suffix = " studs" })
	MurdererBox:AddToggle("auto_equip", { Text = "Auto Equip Knife", Default = true, Tooltip = "Pulls the knife out when the aura needs it" })
	MurdererBox:AddToggle("throw_assist", { Text = "Throw Assist", Tooltip = "Knife throws hit whoever's closest to your cursor", Callback = function(v)
		if v and not hookReady then
			notify("Throw assist needs hookmetamethod, which this executor doesn't have.", nil, 6)
		end
	end })
	MurdererBox:AddDivider()
	MurdererBox:AddButton({ Text = "Kill All", Tooltip = "Stabs everyone alive at once, wherever they are", Callback = killAll })
end

------------------------------------------------------------------------
-- Teleport
------------------------------------------------------------------------
local Teleport = Window:AddTab("Teleport")

local Places = Teleport:AddGroup("Places", "Left")
Places:AddButton({ Text = "Lobby", Callback = tpLobby })
Places:AddButton({ Text = "Map", Callback = tpMap })
Places:AddButton({ Text = "Dropped Gun", Callback = tpGun })
Places:AddDivider()
Places:AddToggle("safe_spot", { Text = "Safe Spot", Tooltip = "Parks you on a platform 300 studs up. Turn off to go back.", Callback = setSafeSpot })
Places:AddKeybind("safe_spot_key", { Text = "Safe Spot Key", Default = Enum.KeyCode.Z, Callback = function()
	Options.safe_spot:Set(not Flags.safe_spot)
end })
Places:AddToggle("click_tp", { Text = "Ctrl + Click Teleport" })

local ToPlayer = Teleport:AddGroup("Players", "Right")
local tpTarget = ToPlayer:AddDropdown("tp_target", { Text = "Player", Values = otherNames() })
ToPlayer:AddButton({ Text = "Teleport To Player", Callback = function()
	local p = findPlayer(Flags.tp_target)
	if p then tpPlayer(p, "Player") else notify("Pick a player first.") end
end })
ToPlayer:AddButton({ Text = "Teleport To Murderer", Callback = function() tpPlayer(findRole("Murderer"), "Murderer") end })
ToPlayer:AddButton({ Text = "Teleport To Sheriff", Callback = function() tpPlayer(findSheriff(), "Sheriff") end })

-- dropped gun: picked up by touching Workspace.<Map>.GunDrop
do
	local grabbing = false
	local triedGun, tries = nil, 0 -- give up on a gun after a couple of failed attempts

	-- returns true if we ended up holding the gun; `manual` says why it didn't happen
	local function grabGun(manual)
		local function why(msg) if manual then notify(msg) end return false end
		if grabbing then return false end
		local gun = partOf(State.gun)
		if not gun then return why("The gun isn't dropped.") end
		if hasTool(LP, "Gun") then return why("You already have the gun.") end
		if roleOf(LP) == "Murderer" then return why("The murderer can't pick up the gun.") end
		local me = myRoot()
		if not (me and inRound(LP)) then return why("You need to be alive in the round.") end

		grabbing = true
		local home = me.CFrame
		local t0 = os.clock()
		-- stand on it until the touch registers and the gun lands in the backpack
		while os.clock() - t0 < 1.5 and gun.Parent and not hasTool(LP, "Gun") and myRoot() do
			teleport(gun.CFrame + Vector3.new(0, 2.5, 0), true)
			if typeof(firetouchinterest) == "function" then
				pcall(firetouchinterest, myRoot(), gun, 0)
				pcall(firetouchinterest, myRoot(), gun, 1)
			end
			task.wait(0.1)
		end
		local got = hasTool(LP, "Gun") ~= nil
		if Flags.gun_return and myRoot() then teleport(home, true) end
		grabbing = false
		notify(got and "Grabbed the gun." or "Couldn't pick up the gun.", "Gun", 3)
		return got
	end

	task.spawn(function()
		while running() do
			local gun = State.gun
			if Flags.grab_gun and gun and gun.Parent and not grabbing then
				if gun ~= triedGun then triedGun, tries = gun, 0 end
				if tries < 2 and not hasTool(LP, "Gun") and roleOf(LP) ~= "Murderer" and inRound(LP) then
					tries += 1
					pcall(grabGun, false)
				end
			end
			task.wait(0.5)
		end
	end)

	local GunBox = Teleport:AddGroup("Dropped Gun", "Left")
	GunBox:AddToggle("grab_gun", { Text = "Auto Teleport To Gun", Tooltip = "Teleports onto the gun as soon as it drops and picks it up" })
	GunBox:AddToggle("gun_return", { Text = "Return After Grabbing", Default = true, Tooltip = "Takes you back to where you were" })
	GunBox:AddToggle("gun_notify", { Text = "Notify When Dropped", Default = true, Tooltip = "Pops a notification when the sheriff drops the gun" })
	GunBox:AddButton({ Text = "Grab Gun Now", Callback = function() grabGun(true) end })
end

------------------------------------------------------------------------
-- Trolling
------------------------------------------------------------------------
do
	local Trolling = Window:AddTab("Trolling")

	local function target() return findPlayer(Flags.troll_target) end

	-- Target fling, the way the well-known fling scripts do it: snap onto the target every frame
	-- with enormous velocity and spin, so the collision throws THEM. The old version spun our own
	-- body and had no protection, so it threw us instead and we fell into the void. Now:
	--   - the void-kill height is switched off while it runs
	--   - a zero-velocity BodyVelocity holds us in place between the snaps
	--   - the camera watches the target, not our own body
	--   - afterwards every part's velocity is zeroed each frame while we're put back home
	-- busy pauses noclip, anti-fling, follow/orbit and the farm meanwhile (they'd all get in the way).
	local HUGE_V = Vector3.new(9e7, 9e8, 9e7)
	local HUGE_R = Vector3.new(9e8, 9e8, 9e8)

	local function fling(p, label)
		if busy or p == LP then return end
		local c, me, h = LP.Character, myRoot(), myHum()
		local tc, th = p and p.Character, humOf(p)
		if not (tc and th and rootOf(p)) then notify(label .. " not found.") return end
		if not (c and me and h) then notify("You don't have a character right now.") return end

		busy = true
		local home = me.CFrame
		local oldDestroyHeight = workspace.FallenPartsDestroyHeight
		local bv
		local landed = false

		local ok, err = pcall(function()
			pcall(function() workspace.FallenPartsDestroyHeight = 0 / 0 end)
			h:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
			cam().CameraSubject = th

			bv = Instance.new("BodyVelocity")
			bv.Velocity = Vector3.zero
			bv.MaxForce = Vector3.new(9e9, 9e9, 9e9)
			bv.Parent = me

			-- one placement: on top of the target (a little ahead of where they're heading), spun
			-- to a new angle, with the huge velocities set for this physics step
			local function snap(base, offset, angle)
				local v = base.AssemblyLinearVelocity
				local lead = Vector3.new(v.X, 0, v.Z) * 0.12
				c:PivotTo(CFrame.new(base.Position + lead) * offset * CFrame.Angles(math.rad(angle), 0, 0))
				me.AssemblyLinearVelocity = HUGE_V
				me.AssemblyAngularVelocity = HUGE_R
			end

			local angle, t0 = 0, os.clock()
			while running() and os.clock() - t0 < 2.5 do
				local base = rootOf(p)
				if not (base and p.Parent and p.Character == tc and c.Parent) then break end
				if th.Health <= 0 or h.Health <= 0 or th.Sit then break end
				if base.AssemblyLinearVelocity.Magnitude > 500 then landed = true break end -- they're gone
				angle += 100
				snap(base, CFrame.new(0, 1.5, 0), angle)
				task.wait()
				snap(base, CFrame.new(0, -1.5, 0), angle)
				task.wait()
				snap(base, CFrame.new(2, 1.5, 0), angle)
				task.wait()
				snap(base, CFrame.new(-2, -1.5, 0), angle)
				task.wait()
			end
		end)

		-- always runs, even if something above errored
		if bv then bv:Destroy() end
		pcall(function() h:SetStateEnabled(Enum.HumanoidStateType.Seated, true) end)
		if c.Parent and myRoot() then
			-- back home, zeroing every velocity each frame until the physics has settled
			for _ = 1, 15 do
				c:PivotTo(home + Vector3.new(0, 0.5, 0))
				for _, d in ipairs(c:GetDescendants()) do
					if d:IsA("BasePart") then
						d.AssemblyLinearVelocity = Vector3.zero
						d.AssemblyAngularVelocity = Vector3.zero
					end
				end
				pcall(function() h:ChangeState(Enum.HumanoidStateType.GettingUp) end)
				task.wait()
			end
		end
		local mine = (h.Parent and h) or myHum()
		if mine then cam().CameraSubject = mine end
		pcall(function() workspace.FallenPartsDestroyHeight = oldDestroyHeight end)
		busy = false

		if not ok then notify("Fling stopped: " .. tostring(err)) return end
		notify(landed and ("Flung " .. p.DisplayName .. ".") or ("The fling didn't land on " .. p.DisplayName .. "."))
	end

	local function chat(msg)
		local sent = pcall(function()
			local channels = game:GetService("TextChatService"):FindFirstChild("TextChannels")
			local general = channels and channels:FindFirstChild("RBXGeneral")
			assert(general, "no RBXGeneral channel")
			general:SendAsync(msg)
		end)
		if sent then return true end
		return (pcall(function() -- older games still use the legacy chat
			ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(msg, "All")
		end))
	end

	local function announceRoles()
		local m = anyoneWith("Murderer")
		local s = anyoneWith("Sheriff") or anyoneWith("Hero")
		if not (m or s) then notify("Roles aren't known yet.") return end
		local msg = string.format("Murderer: %s | Sheriff: %s", m and m.DisplayName or "?", s and s.DisplayName or "?")
		if not chat(msg) then notify("Couldn't send the chat message.") end
	end

	-- spectate: the camera follows the target until it's turned off, then comes back to you
	local spectating = false
	local function stopSpectate()
		if not spectating then return end
		spectating = false
		local h = myHum()
		if h then cam().CameraSubject = h end
	end
	onUnload(stopSpectate)
	on(RunService.RenderStepped, function()
		local th = humOf(target())
		if Flags.spectate and th then
			if cam().CameraSubject ~= th then cam().CameraSubject = th end
			spectating = true
		else
			stopSpectate()
		end
	end)

	-- follow / orbit (orbit wins if both are on)
	local orbitAngle = 0
	on(RunService.Heartbeat, function(dt)
		if busy or not (Flags.follow or Flags.orbit) then return end
		local me, tr = myRoot(), rootOf(target())
		if not (me and tr) then return end
		if Flags.orbit then
			orbitAngle += dt * (Flags.orbit_speed or 5) * 0.6
			local pos = tr.Position + Vector3.new(math.cos(orbitAngle), 0, math.sin(orbitAngle)) * (Flags.orbit_radius or 6)
			me.CFrame = CFrame.lookAt(pos, tr.Position)
		else
			me.CFrame = tr.CFrame * CFrame.new(0, 0, 3)
		end
		me.AssemblyLinearVelocity = Vector3.zero
	end)

	local TargetBox = Trolling:AddGroup("Target", "Left")
	local trollTarget = TargetBox:AddDropdown("troll_target", { Text = "Player", Values = otherNames() })
	TargetBox:AddToggle("spectate", { Text = "Spectate", Tooltip = "Your camera follows the target" })
	TargetBox:AddToggle("follow", { Text = "Follow", Tooltip = "Stick right behind the target" })
	TargetBox:AddToggle("orbit", { Text = "Orbit", Tooltip = "Circle around the target (wins over Follow)" })
	TargetBox:AddSlider("orbit_speed", { Text = "Orbit Speed", Min = 1, Max = 20, Default = 5 })
	TargetBox:AddSlider("orbit_radius", { Text = "Orbit Radius", Min = 3, Max = 20, Default = 6, Suffix = " studs" })

	local FlingBox = Trolling:AddGroup("Fling", "Right")
	FlingBox:AddButton({ Text = "Fling Target", Callback = function()
		local p = target()
		if p then fling(p, "Target") else notify("Pick a target first.") end
	end })
	FlingBox:AddButton({ Text = "Fling Murderer", Callback = function() fling(findRole("Murderer"), "Murderer") end })
	FlingBox:AddButton({ Text = "Fling Sheriff", Callback = function() fling(findSheriff(), "Sheriff") end })

	local ChatBox = Trolling:AddGroup("Chat", "Right")
	ChatBox:AddButton({ Text = "Announce Roles In Chat", Tooltip = "Says who the murderer and sheriff are in chat", Callback = announceRoles })

	-- keep both player dropdowns in sync with who's in the server
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
end

------------------------------------------------------------------------
-- Player
------------------------------------------------------------------------
do
	local PlayerTab = Window:AddTab("Player")
	local DEFAULT_SPEED, DEFAULT_JUMP = 16, 50

	-- only overridden while a slider is off its default, so the game is left alone otherwise
	on(RunService.Heartbeat, function()
		local h = myHum()
		if not h then return end
		local ws, jp = Flags.walkspeed or DEFAULT_SPEED, Flags.jumppower or DEFAULT_JUMP
		if ws ~= DEFAULT_SPEED and h.WalkSpeed ~= ws then h.WalkSpeed = ws end
		if jp ~= DEFAULT_JUMP and (not h.UseJumpPower or h.JumpPower ~= jp) then
			h.UseJumpPower = true
			h.JumpPower = jp
		end
	end)

	on(UIS.JumpRequest, function()
		if not Flags.inf_jump then return end
		local h = myHum()
		if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
	end)

	-- noclip (also used by the coin farm through forceNoclip). Paused during a fling: it needs collisions.
	local noclipped = {}
	local function restoreCollisions()
		for part in pairs(noclipped) do
			if part.Parent then part.CanCollide = true end
		end
		noclipped = {}
	end
	on(RunService.Stepped, function()
		local c = LP.Character
		if (Flags.noclip or forceNoclip) and not busy and c then
			for _, part in ipairs(c:GetDescendants()) do
				if part:IsA("BasePart") and part.CanCollide then
					noclipped[part] = true
					part.CanCollide = false
				end
			end
		elseif next(noclipped) then
			restoreCollisions()
		end
	end)
	onUnload(restoreCollisions)
	on(LP.CharacterAdded, function() noclipped = {} end)

	-- anti fling: other players' parts can't collide with us, so they can't push or fling us
	on(RunService.Stepped, function()
		if not Flags.anti_fling or busy then return end
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= LP and p.Character then
				for _, part in ipairs(p.Character:GetDescendants()) do
					if part:IsA("BasePart") and part.CanCollide then part.CanCollide = false end
				end
			end
		end
	end)

	local Movement = PlayerTab:AddGroup("Movement", "Left")
	Movement:AddSlider("walkspeed", { Text = "WalkSpeed", Min = 16, Max = 100, Default = 16, Callback = function(v)
		local h = myHum(); if h then h.WalkSpeed = v end
	end })
	Movement:AddSlider("jumppower", { Text = "JumpPower", Min = 50, Max = 200, Default = 50, Callback = function(v)
		local h = myHum(); if h then h.UseJumpPower = true; h.JumpPower = v end
	end })
	Movement:AddToggle("inf_jump", { Text = "Infinite Jump", Tooltip = "Jump again in mid-air" })
	Movement:AddToggle("noclip", { Text = "Noclip", Tooltip = "Walk through walls" })
	Movement:AddToggle("anti_fling", { Text = "Anti Fling", Tooltip = "Other players can't push or fling you" })
end

------------------------------------------------------------------------
-- Misc
------------------------------------------------------------------------
do
	local Misc = Window:AddTab("Misc")
	local TeleportService = game:GetService("TeleportService")
	local GuiService = game:GetService("GuiService")

	local RolesBox = Misc:AddGroup("Roles", "Left")
	RolesBox:AddToggle("role_notify", { Text = "Role Notifier", Default = true, Tooltip = "Tells you who the murderer and sheriff are each round" })
	local murdererLabel = RolesBox:AddLabel("Murderer: -")
	local sheriffLabel = RolesBox:AddLabel("Sheriff: -")
	local myRoleLabel = RolesBox:AddLabel("You: -")

	-- who has already been announced this round. Only forgotten once the round is really over
	-- (nobody holds a role for a few seconds): the murderer can die while the hero is still alive,
	-- and resetting then re-announced the hero every tick.
	local announced = {}
	local emptySince
	task.spawn(function()
		while running() do
			local m = anyoneWith("Murderer")
			local s = anyoneWith("Sheriff") or anyoneWith("Hero")
			murdererLabel:Set("Murderer: " .. (m and m.DisplayName or "-"))
			sheriffLabel:Set("Sheriff: " .. (s and s.DisplayName or "-"))
			myRoleLabel:Set("You: " .. (inRound(LP) and roleOf(LP) or "-"))
			if m or s then
				emptySince = nil
			else
				emptySince = emptySince or os.clock()
				if os.clock() - emptySince > 5 then announced = {} end
			end
			if Flags.role_notify then
				if m and announced.m ~= m then
					announced.m = m
					notify(m == LP and "You're the murderer." or (m.DisplayName .. " is the murderer."), "Murderer", 6)
				end
				if s then
					local r = roleOf(s)
					local key = s.Name .. ":" .. r -- a new person, or the same person becoming hero
					if announced.s ~= key then
						announced.s = key
						notify(s == LP and ("You're the " .. r:lower() .. ".") or (s.DisplayName .. " is the " .. r:lower() .. "."), r, 6)
					end
				end
			end
			task.wait(0.5)
		end
	end)

	local function rejoin()
		pcall(function()
			if #Players:GetPlayers() <= 1 then
				TeleportService:Teleport(game.PlaceId, LP)
			else
				TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
			end
		end)
	end

	local function serverHop()
		local ok, body = pcall(function()
			return game:HttpGet(("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100"):format(game.PlaceId))
		end)
		if not ok then notify("Couldn't get the server list.") return end
		local okJson, data = pcall(function() return HttpService:JSONDecode(body) end)
		local ids = {}
		if okJson and type(data) == "table" and type(data.data) == "table" then
			for _, srv in ipairs(data.data) do
				local playing, max = tonumber(srv.playing), tonumber(srv.maxPlayers)
				if srv.id ~= game.JobId and playing and max and playing < max then table.insert(ids, srv.id) end
			end
		end
		if #ids == 0 then notify("No other servers with space right now.") return end
		notify("Hopping servers...")
		pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, ids[math.random(#ids)], LP) end)
	end

	on(LP.Idled, function()
		if not Flags.anti_afk then return end
		pcall(function()
			local vu = game:GetService("VirtualUser")
			vu:CaptureController()
			vu:ClickButton2(Vector2.new())
		end)
	end)

	local rejoining = false
	on(GuiService.ErrorMessageChanged, function(msg)
		if not Flags.auto_rejoin or rejoining or not msg or msg == "" then return end
		rejoining = true
		notify("Disconnected, rejoining...")
		task.wait(2)
		rejoin()
		rejoining = false
	end)

	local ServerBox = Misc:AddGroup("Server", "Right")
	ServerBox:AddToggle("anti_afk", { Text = "Anti AFK", Default = true, Tooltip = "Stops Roblox kicking you for being idle" })
	ServerBox:AddToggle("auto_rejoin", { Text = "Auto Rejoin On Kick", Tooltip = "Rejoins the same server if you get disconnected" })
	ServerBox:AddButton({ Text = "Rejoin Server", Callback = rejoin })
	ServerBox:AddButton({ Text = "Server Hop", Tooltip = "Joins a different server with space", Callback = serverHop })
	ServerBox:AddButton({ Text = "Copy Server ID", Callback = function()
		if typeof(setclipboard) == "function" then
			setclipboard(game.JobId)
			notify("Server ID copied.")
		else
			notify("Your executor can't copy to the clipboard.")
		end
	end })
end

------------------------------------------------------------------------
-- Autofarm
------------------------------------------------------------------------
do
	local Autofarm = Window:AddTab("Autofarm")
	local TweenService = game:GetService("TweenService")
	Autofarm:AddMasterToggle("autofarm_enabled", { Text = "Autofarm", Default = true, Tooltip = "Master switch for every autofarm feature" })

	local CoinsBox = Autofarm:AddGroup("Coins", "Left")
	CoinsBox:AddToggle("coin_farm", { Text = "Auto Collect Coins", Tooltip = "Collects every coin for you" })
	CoinsBox:AddToggle("farm_hide", { Text = "Stay Under Map", Default = true, Tooltip = "Lies you flat under the map while farming, so the murderer can't reach you" })
	CoinsBox:AddSlider("farm_depth", { Text = "Depth Under Map", Min = 5, Max = 40, Default = 15, Suffix = " studs", Tooltip = "How far below the lowest coin you stay" })
	CoinsBox:AddSlider("farm_speed", { Text = "Farm Speed", Min = 1, Max = 10, Default = 4, Tooltip = "Higher is faster but easier to get kicked for" })
	CoinsBox:AddToggle("avoid_murderer", { Text = "Avoid Murderer", Default = true, Tooltip = "Skips coins near the murderer when you have to pop up to grab one" })
	CoinsBox:AddSlider("avoid_radius", { Text = "Avoid Radius", Min = 10, Max = 60, Default = 25, Suffix = " studs" })
	CoinsBox:AddToggle("reset_full", { Text = "Reset When Bag Full", Tooltip = "Resets your character once the bag is full" })
	CoinsBox:AddSlider("bag_size", { Text = "Bag Size", Min = 10, Max = 50, Default = 40, Tooltip = "40 normally, 50 with Elite" })
	local coinLabel = CoinsBox:AddLabel("Collected this round: 0")

	-- lying on your back keeps the whole body a stud or two tall
	local FLAT = CFrame.Angles(math.rad(90), 0, 0)
	local hasTouch = typeof(firetouchinterest) == "function"

	-- the game's own per-round count when it's in the player data, otherwise our own tally
	local localCount = 0
	local function coinsHeld()
		local d = dataOf(LP)
		return (d and tonumber(d.Coins)) or localCount
	end

	local function stillFarming() return running() and Flags.autofarm_enabled and Flags.coin_farm and not busy end

	local function nextCoin(me, avoid)
		local murderer = avoid and roleOf(LP) ~= "Murderer" and findRole("Murderer")
		local mr = murderer and rootOf(murderer)
		local radius = Flags.avoid_radius or 25
		local best, bestDist
		for _, coin in ipairs(liveCoins()) do
			if not mr or (coin.Position - mr.Position).Magnitude > radius then
				local d = (coin.Position - me.Position).Magnitude
				if not bestDist or d < bestDist then best, bestDist = coin, d end
			end
		end
		return best
	end

	-- fire the touch both ways, like the engine would
	local function touch(coin)
		local me = myRoot()
		if not (hasTouch and me) then return end
		pcall(firetouchinterest, me, coin, 0)
		pcall(firetouchinterest, me, coin, 1)
	end

	------------------------------------------------------------------
	-- stay under the map
	------------------------------------------------------------------
	local hiding, hideY, homeCF, pin = false, nil, nil, nil
	local displaced = 0
	local useRemote, misses = hasTouch, 0

	-- Everything that moves us while hiding just sets `pin`; this puts us there every frame, so
	-- gravity never gets a chance to pull us down into the void (also when there are no coins left).
	on(RunService.Heartbeat, function()
		if not (hiding and pin) then return end
		local c, me = LP.Character, myRoot()
		if c and me then
			c:PivotTo(pin)
			me.AssemblyLinearVelocity = Vector3.zero
		end
	end)

	-- one level under the whole map, so there are no floors, pits or upper decks to worry about:
	-- below the lowest coin (or anyone standing even lower), by the depth slider
	local function hideLevel()
		local cc = State.map and State.map:FindFirstChild("CoinContainer", true)
		if not cc then return nil end
		local lowest = math.huge
		for _, c in ipairs(cc:GetChildren()) do
			if c:IsA("BasePart") and c.Position.Y < lowest then lowest = c.Position.Y end
		end
		for _, p in ipairs(Players:GetPlayers()) do
			local r = rootOf(p)
			if r and inRound(p) and r.Position.Y < lowest then lowest = r.Position.Y end
		end
		if lowest == math.huge then return nil end
		-- never below the height where Roblox destroys anything that falls
		return math.max(lowest - (Flags.farm_depth or 15), workspace.FallenPartsDestroyHeight + 25)
	end

	local function descend()
		local me = myRoot()
		local y = me and hideLevel()
		if not y then return false end
		local h = myHum()
		homeCF, hideY = me.CFrame, y
		if h then h.PlatformStand = true end
		forceNoclip = true
		pin = CFrame.new(me.Position.X, hideY, me.Position.Z) * FLAT
		hiding = true
		return true
	end

	local function surface()
		if not hiding then return end
		hiding, pin = false, nil
		forceNoclip = false
		local c, me, h = LP.Character, myRoot(), myHum()
		if h then h.PlatformStand = false end
		-- alive on the map: back up to where we were. Between rounds the game moves us itself.
		if c and me and homeCF and State.map and inRound(LP) then
			c:PivotTo(homeCF)
			me.AssemblyLinearVelocity = Vector3.zero
			if h then h:ChangeState(Enum.HumanoidStateType.GettingUp) end
		end
		homeCF = nil
	end

	local function glideTo(target, speed)
		local me = myRoot()
		if not me then return end
		local start = me.Position
		local dur = (target - start).Magnitude / speed
		local t0 = os.clock()
		while hiding and stillFarming() do
			local a = dur > 0 and math.min((os.clock() - t0) / dur, 1) or 1
			pin = CFrame.new(start:Lerp(target, a)) * FLAT
			if a >= 1 then return end
			RunService.Heartbeat:Wait()
		end
	end

	local function holdFor(maxTime, done)
		local t0 = os.clock()
		while hiding and stillFarming() and os.clock() - t0 < maxTime and not done() do
			RunService.Heartbeat:Wait()
		end
	end

	-- slide under the nearest coin and take it from there. Returns false if there was nothing to do.
	local function farmStepHidden()
		local me = myRoot()
		if not me then return false end
		if hiding and me.Position.Y > hideY + 10 then
			-- something moved us back up; after a few times give up hiding rather than fight the game
			displaced += 1
			hiding = false
			if displaced >= 3 then
				notify("The game keeps moving you out from under the map. Switching Stay Under Map off.", "Autofarm", 6)
				Options.farm_hide:Set(false)
				return true
			end
		end
		if not hiding and not descend() then return false end

		local coin = nextCoin(myRoot() or me, Flags.avoid_murderer and not useRemote)
		if not coin then return false end

		local under = Vector3.new(coin.Position.X, hideY, coin.Position.Z)
		local hold = CFrame.new(under) * FLAT
		glideTo(under, 10 + (Flags.farm_speed or 4) * 3)
		if not (hiding and isCoinLive(coin) and stillFarming()) then return true end

		-- 1) touch it from underneath
		local got = false
		local remoteTried = useRemote
		if useRemote then
			touch(coin)
			holdFor(0.4, function() return not isCoinLive(coin) end)
			got = not isCoinLive(coin)
			if got then misses = 0 end
		end
		-- 2) otherwise pop up onto it for a moment and drop straight back down
		if not got and isCoinLive(coin) and stillFarming() then
			local t0 = os.clock()
			while hiding and isCoinLive(coin) and os.clock() - t0 < 0.5 and stillFarming() do
				pin = CFrame.new(coin.Position) * FLAT
				touch(coin)
				RunService.Heartbeat:Wait()
			end
			pin = hold
			got = not isCoinLive(coin)
			if got and remoteTried then
				misses += 1
				if misses >= 2 then
					useRemote = false
					notify("Coins aren't registering from underneath, so I'll pop up to grab each one.", "Autofarm", 6)
				end
			end
		end
		if got then localCount += 1 end
		return true
	end

	------------------------------------------------------------------
	-- the plain version: glide coin to coin through the map (Stay Under Map off)
	------------------------------------------------------------------
	local function farmStepFloor()
		local me = myRoot()
		if not me then return false end
		local coin = nextCoin(me, Flags.avoid_murderer)
		if not coin then return false end
		forceNoclip = true
		local speed = 10 + (Flags.farm_speed or 4) * 3
		local tw = TweenService:Create(me, TweenInfo.new((coin.Position - me.Position).Magnitude / speed, Enum.EasingStyle.Linear),
			{ CFrame = CFrame.new(coin.Position) * me.CFrame.Rotation })
		tw:Play()
		while tw.PlaybackState == Enum.PlaybackState.Playing do
			if not (stillFarming() and isCoinLive(coin) and me.Parent) then tw:Cancel() break end
			me.AssemblyLinearVelocity = Vector3.zero
			task.wait()
		end
		if isCoinLive(coin) and me.Parent and stillFarming() then
			touch(coin)
			-- hold still on the coin (noclip is on, so we'd otherwise sink through the floor)
			local t0 = os.clock()
			while isCoinLive(coin) and me.Parent and os.clock() - t0 < 0.5 do
				me.CFrame = CFrame.new(coin.Position) * me.CFrame.Rotation
				me.AssemblyLinearVelocity = Vector3.zero
				task.wait()
			end
			if not isCoinLive(coin) then localCount += 1 end
		end
		return true
	end

	task.spawn(function()
		while running() do
			local active = stillFarming() and inRound(LP)
			if hiding and not (active and Flags.farm_hide) then surface() end
			if active then
				local ok, moved = pcall(Flags.farm_hide and farmStepHidden or farmStepFloor)
				if not ok then warn("[xpware] coin farm: " .. tostring(moved)) end
				if not (ok and moved) then
					if not hiding then forceNoclip = false end
					task.wait(0.3) -- nothing to collect right now; if hiding, the pin keeps us safe meanwhile
				end
				if Flags.reset_full and coinsHeld() >= (Flags.bag_size or 40) then
					local h = myHum()
					if h and h.Health > 0 then
						h.Health = 0
						notify("Bag full, resetting.", "Autofarm", 3)
					end
				end
			else
				if not hiding then forceNoclip = false end
				if not inRound(LP) then localCount, displaced = 0, 0 end
				task.wait(0.3)
			end
			coinLabel:Set("Collected this round: " .. coinsHeld())
		end
	end)

	-- a new character is a fresh start: nothing to pin or put back
	on(LP.CharacterAdded, function()
		hiding, pin, homeCF = false, nil, nil
		forceNoclip = false
	end)
	onUnload(surface)
end

------------------------------------------------------------------------
-- Fun
------------------------------------------------------------------------
do
	local Fun = Window:AddTab("Fun")

	-- MM2's own emotes. The game plays one by firing the local event Remotes.Misc.PlayEmote with
	-- the emote's key ("zen", "sit", "ninja", ...); its animation script then plays the animation
	-- on your character, and Roblox replicates that to everyone. The full list comes from the
	-- game's database (Database.Sync.Emotes and .Toys), not just the emotes you own.
	local gameRemotes = ReplicatedStorage:FindFirstChild("Remotes")
	local gameMisc = gameRemotes and gameRemotes:FindFirstChild("Misc")
	local PlayEmote = gameMisc and gameMisc:FindFirstChild("PlayEmote")

	local emoteByLabel, emoteNames = {}, {}

	local function loadEmotes()
		local ok, sync = pcall(function() return require(ReplicatedStorage.Database.Sync) end)
		if not (ok and type(sync) == "table") then
			ok, sync = pcall(function() return { Emotes = require(ReplicatedStorage.Database.Sync.Emotes) } end)
		end
		if not (ok and type(sync) == "table") then return end

		local custom, basic, toys = {}, {}, {}
		if type(sync.Emotes) == "table" then
			for key, info in pairs(sync.Emotes) do
				-- "Back" is the menu's back button, not an emote
				if type(key) == "string" and key ~= "Back" and type(info) == "table" then
					table.insert(info.AnimationID and custom or basic,
						{ key = key, info = info, name = tostring(info.Name or key) })
				end
			end
		end
		if type(sync.Toys) == "table" then
			for key, info in pairs(sync.Toys) do
				if type(key) == "string" and type(info) == "table" then
					table.insert(toys, { key = key, info = info, toy = true, name = tostring(info.Name or key) .. " (toy)" })
				end
			end
		end
		-- the game's custom animations first, then the Roblox basics, then toys
		for _, group in ipairs({ custom, basic, toys }) do
			table.sort(group, function(a, b) return a.name:lower() < b.name:lower() end)
			for _, e in ipairs(group) do
				local label = e.name
				if emoteByLabel[label] then label = label .. " [" .. e.key .. "]" end
				emoteByLabel[label] = e
				table.insert(emoteNames, label)
			end
		end
	end
	loadEmotes()
	if #emoteNames == 0 then -- no database to read: the Roblox basics still work through the same event
		for _, key in ipairs({ "wave", "cheer", "laugh", "point", "dance1", "dance2", "dance3" }) do
			emoteByLabel[key] = { key = key, info = {}, name = key }
			table.insert(emoteNames, key)
		end
	end

	-- matches the label, or the key, ignoring case (older saved settings hold names like "Dance")
	local function findEmote(label)
		if type(label) ~= "string" then return nil end
		if emoteByLabel[label] then return emoteByLabel[label] end
		local l = label:lower()
		for name, e in pairs(emoteByLabel) do
			if name:lower() == l or e.key:lower() == l then return e end
		end
		return nil
	end

	-- Emote tracks that are playing, the game's or our own fallback. The game names its emote
	-- track after the emote ("ninja"); its idle/walk/jump tracks end in "Anim" or are "Animation1".
	local tracks, ownTrack = {}, nil
	local lastFiredAt = 0

	local function isDefaultTrack(name)
		return name:match("Anim$") ~= nil or name:match("^Animation%d*$") ~= nil
	end

	local function hookAnimator(char)
		local h = char:WaitForChild("Humanoid", 5)
		local animator = h and (h:FindFirstChildOfClass("Animator") or h:WaitForChild("Animator", 5))
		if not animator then return end
		on(animator.AnimationPlayed, function(track)
			if os.clock() - lastFiredAt < 1.5 and not isDefaultTrack(track.Name) then tracks[track] = true end
		end)
	end
	if LP.Character then task.spawn(hookAnimator, LP.Character) end

	local function emoteActive()
		local active = false
		for t in pairs(tracks) do
			local ok, playing = pcall(function() return t.IsPlaying end)
			if ok and playing then active = true else tracks[t] = nil end
		end
		return active
	end

	-- returns true if there was something to stop
	local function stopEmote()
		local stopped = false
		for t in pairs(tracks) do
			pcall(function() t:Stop(0.2) end)
			tracks[t] = nil
			stopped = true
		end
		ownTrack = nil
		return stopped
	end
	onUnload(stopEmote)

	-- our own copy of an emote animation, for when the game's script doesn't play it. Action
	-- priority so it wins over the idle/walk tracks; it replicates like any animation we play.
	local function playOwn(entry)
		local id, h = entry.info.AnimationID, myHum()
		if not (id and h) then return false end
		local anim = Instance.new("Animation")
		anim.Name = entry.key
		anim.AnimationId = "rbxassetid://" .. tostring(id)
		local ok, track = pcall(function()
			return (h:FindFirstChildOfClass("Animator") or h):LoadAnimation(anim)
		end)
		if not (ok and track) then return false end
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = entry.info.Loop == true
		track:Play(0.2)
		ownTrack = track
		tracks[track] = true
		return true
	end

	local function playEmote(label)
		local entry = findEmote(label)
		if not entry then notify("Pick an emote first.") return end
		if not PlayEmote then notify("This game has no emote system.") return end
		if not (myHum() and myRoot()) then return end
		stopEmote()
		lastFiredAt = os.clock()
		local my = lastFiredAt
		PlayEmote:Fire(entry.key)
		-- the game's script plays it the instant it's fired; if nothing has started 0.3s later (it
		-- may only play emotes you own, or its idle animation cut in), play the animation ourselves
		task.delay(0.3, function()
			if my == lastFiredAt and not emoteActive() and not entry.toy then playOwn(entry) end
		end)
	end

	-- Emote When Still: starts the moment you stop (checked every frame; the optional wait is 0 by
	-- default), once each time you stop, and again if the emote ends by itself while you stand there. Anything that isn't plain standing (moving, in the air, seated, pinned by
	-- the coin farm, mid-fling) counts as not still and starts the wait over.
	task.spawn(function()
		local stillSince, playedThisStop, sawTrack = nil, false, false
		while running() do
			local h, r = myHum(), myRoot()
			local still = h ~= nil and r ~= nil and h.Health > 0
				and h.MoveDirection.Magnitude < 0.05
				and Vector3.new(r.AssemblyLinearVelocity.X, 0, r.AssemblyLinearVelocity.Z).Magnitude < 0.5
				and h.FloorMaterial ~= Enum.Material.Air
				and not h.PlatformStand and not h.Sit and not busy
			if Flags.auto_emote and still then
				local now = os.clock()
				stillSince = stillSince or now
				local active = emoteActive()
				if active then sawTrack = true end
				if now - stillSince >= (Flags.emote_wait or 0) and not active then
					if not playedThisStop or (sawTrack and now - lastFiredAt > 2) then
						playedThisStop, sawTrack = true, false
						playEmote(Flags.emote)
					end
				end
			else
				stillSince, playedThisStop, sawTrack = nil, false, false
			end
			RunService.Heartbeat:Wait()
		end
	end)

	local spinning, frozen = false, false
	on(RunService.Heartbeat, function(dt)
		local r, h = myRoot(), myHum()
		if not (r and h) then return end
		if Flags.spin and not busy then
			spinning = true
			h.AutoRotate = false
			r.CFrame *= CFrame.Angles(0, (Flags.spin_speed or 10) * 2 * dt, 0)
		elseif spinning then
			spinning = false
			h.AutoRotate = true
		end
		if Flags.jump_spam and h.FloorMaterial ~= Enum.Material.Air then h.Jump = true end
		if Flags.freeze then
			if not r.Anchored then r.Anchored = true end
			frozen = true
		elseif frozen then
			r.Anchored = false
			frozen = false
		end
		-- the game's emotes stop by themselves when you move; our fallback copy needs telling
		if ownTrack and (h.MoveDirection.Magnitude > 0.1 or h.Jump) then stopEmote() end
	end)
	on(LP.CharacterAdded, function(char)
		spinning, frozen, tracks, ownTrack = false, false, {}, nil
		task.spawn(hookAnimator, char)
	end)
	onUnload(function()
		local r, h = myRoot(), myHum()
		if r and frozen then r.Anchored = false end
		if h and spinning then h.AutoRotate = true end
	end)

	local CharacterBox = Fun:AddGroup("Character", "Left")
	CharacterBox:AddToggle("spin", { Text = "Spin" })
	CharacterBox:AddSlider("spin_speed", { Text = "Spin Speed", Min = 1, Max = 50, Default = 10 })
	CharacterBox:AddToggle("jump_spam", { Text = "Jump Spam" })
	CharacterBox:AddToggle("freeze", { Text = "Freeze In Place", Tooltip = "Pins you where you stand" })
	CharacterBox:AddButton({ Text = "Sit", Callback = function()
		local h = myHum(); if h then h.Sit = true end
	end })

	local EmotesBox = Fun:AddGroup("Emotes", "Right")
	EmotesBox:AddDropdown("emote", { Text = "Emote", Values = emoteNames,
		Default = emoteByLabel["Zen"] and "Zen" or emoteNames[1] })
	EmotesBox:AddButton({ Text = "Play Emote", Callback = function() playEmote(Flags.emote) end })
	EmotesBox:AddButton({ Text = "Stop Emote", Callback = function()
		if not stopEmote() then notify("Walk or jump to stop an emote.", nil, 2) end
	end })
	EmotesBox:AddToggle("auto_emote", { Text = "Emote When Still", Tooltip = "Plays the selected emote every time you stop moving" })
	EmotesBox:AddSlider("emote_wait", { Text = "Still For", Min = 0, Max = 10, Default = 0, Rounding = 1, Suffix = " s",
		Tooltip = "How long you stand still before the emote starts. 0 = the moment you stop" })
	EmotesBox:AddLabel("These are the game's own emotes, so everyone sees them. Walking cancels them.", { Color = Library.Theme.TextDim })
end

------------------------------------------------------------------------
-- Settings (menu controls are UI, so they actually work)
------------------------------------------------------------------------
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
Menu:AddDropdown("theme", { Text = "Theme", Values = Library.ThemeOrder, Default = themeName, Callback = function(v)
	if v == themeName then return end
	writeTheme(v)
	notify("Theme set to " .. v .. ". Re-run the script to apply it.", nil, 6)
end })
Menu:AddDivider()
Menu:AddButton({ Text = "Test Notification", Callback = function()
	Library:Notify("Murderer", "This is what a role alert looks like.", 5)
end })
Menu:AddButton({ Text = "Unload", Callback = function() Library:Unload() end })

local Config = Settings:AddGroup("Config", "Left")
local configLabel = Config:AddLabel("Settings save automatically.", { Color = Library.Theme.TextDim })
local resetButton = Config:AddButton({ Text = "Reset To Defaults" })

local About = Settings:AddGroup("About", "Right")
About:AddLabel(NAME .. " v" .. VERSION, { Bold = true })
About:AddLabel("Murder Mystery 2", { Color = Library.Theme.TextDim })
About:AddDivider()
About:AddLabel("X and _ shrink the window into a small bar. Click the bar to open it again. Unload stops the script.")

------------------------------------------------------------------------
-- Settings persistence: every control saves to xpware/mm2.json when it changes and loads on start
------------------------------------------------------------------------
local CONFIG_DIR = "xpware"
local CONFIG_FILE = CONFIG_DIR .. "/mm2.json"
local canSave = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"

-- session-only state: restoring these would teleport you, lock onto an old target, or float you
local NO_SAVE = {
	tp_target = true, troll_target = true, safe_spot = true,
	spectate = true, follow = true, orbit = true, freeze = true,
	theme = true, -- lives in theme.txt so it can be applied before the window exists
}

local function copyValue(v)
	if type(v) ~= "table" then return v end
	local t = {}
	for k, x in pairs(v) do t[k] = x end
	return t
end

-- JSON can't hold EnumItems (keybinds), so they're stored as "Enum.KeyCode.E" strings
local function encodeValue(v)
	if typeof(v) == "EnumItem" then return { __enum = tostring(v) } end
	return v
end
local function decodeValue(v)
	if type(v) == "table" and type(v.__enum) == "string" then
		local enumType, item = v.__enum:match("^Enum%.(%w+)%.(%w+)$")
		local ok, res = pcall(function() return Enum[enumType][item] end)
		return ok and res or nil
	end
	return v
end

local defaults = {}
for flag in pairs(Options) do defaults[flag] = copyValue(Flags[flag]) end

local applying = false -- true while loading/resetting, so those Sets don't each trigger a save

local function saveSettings()
	if not canSave then return end
	local out = {}
	for flag in pairs(Options) do
		if not NO_SAVE[flag] and Flags[flag] ~= nil then out[flag] = encodeValue(Flags[flag]) end
	end
	pcall(function()
		if typeof(makefolder) == "function" and not (typeof(isfolder) == "function" and isfolder(CONFIG_DIR)) then
			makefolder(CONFIG_DIR)
		end
		writefile(CONFIG_FILE, HttpService:JSONEncode(out))
	end)
end

local savePending = false
local function queueSave()
	if applying or savePending or not canSave then return end
	savePending = true
	task.delay(0.5, function()
		savePending = false
		saveSettings()
	end)
end

local function applySettings(values)
	applying = true
	for flag, v in pairs(values) do
		local opt = Options[flag]
		if opt and opt.Set and not NO_SAVE[flag] then pcall(opt.Set, opt, decodeValue(v)) end
	end
	applying = false
end

if canSave then
	local ok, data = pcall(function()
		if not isfile(CONFIG_FILE) then return nil end
		return HttpService:JSONDecode(readfile(CONFIG_FILE))
	end)
	if ok and type(data) == "table" then
		applySettings(data)
	elseif not ok then
		configLabel:Set("Saved settings were unreadable, starting from defaults.")
	end
	for flag, opt in pairs(Options) do
		if not NO_SAVE[flag] and opt.OnChanged then opt:OnChanged(queueSave) end
	end
	onUnload(function() if savePending then saveSettings() end end)
else
	configLabel:Set("Your executor can't write files, so settings won't be saved.")
end

on(resetButton.Instance.MouseButton1Click, function()
	local values = {}
	for flag, v in pairs(defaults) do values[flag] = copyValue(v) end
	applySettings(values)
	saveSettings()
	notify("Settings reset to defaults.")
end)

------------------------------------------------------------------------
-- Runtime
------------------------------------------------------------------------

-- player data (Role / Dead / Killed) straight from the game. Polled every 2s, re-asked when the
-- game says data changed, and merged from event payloads when they carry it.
local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
local extras = Remotes and Remotes:FindFirstChild("Extras")
local dataRemote = (extras and extras:FindFirstChild("GetPlayerData")) or ReplicatedStorage:FindFirstChild("GetPlayerData", true)
local Data = { at = 0, count = 0, err = nil }

-- re-key by player name whether the game keys entries by name or only carries a UserId
local function rekey(res)
	local byName, n = {}, 0
	for k, v in pairs(res) do
		if type(v) == "table" then
			local plr = type(k) == "string" and Players:FindFirstChild(k)
			if not (plr and plr:IsA("Player")) then
				local id = tonumber(v.UserId)
				plr = id and Players:GetPlayerByUserId(id)
			end
			if plr then byName[plr.Name] = v; n += 1 end
		end
	end
	return byName, n
end

local inflight, inflightAt, lastAsk = false, 0, 0
local function fetchData()
	if not (dataRemote and dataRemote:IsA("RemoteFunction")) then return end
	local now = os.clock()
	if now - lastAsk < 0.5 then return end
	-- a request the server never answers stops blocking new ones after 5s
	if inflight and now - inflightAt < 5 then return end
	inflight, inflightAt, lastAsk = true, now, now
	local ok, res = pcall(dataRemote.InvokeServer, dataRemote)
	if inflightAt == now then inflight = false end
	if ok and type(res) == "table" then
		local byName, n = rekey(res)
		if n > 0 then
			State.data, Data.at, Data.count, Data.err = byName, os.clock(), n, nil
		else
			Data.err = "reply had no players"
		end
	else
		Data.err = ok and ("reply was " .. typeof(res)) or tostring(res)
	end
end

-- field-by-field merge so a partial update (say, just Coins) can't wipe someone's Role
local function mergePayload(...)
	for i = 1, select("#", ...) do
		local a = select(i, ...)
		if type(a) == "table" then
			local byName, n = rekey(a)
			if n > 0 then
				for name, fields in pairs(byName) do
					local entry = State.data[name] or {}
					for k, v in pairs(fields) do entry[k] = v end
					State.data[name] = entry
				end
				Data.at = os.clock()
			end
		end
	end
end

local gameplay = Remotes and Remotes:FindFirstChild("Gameplay")
for _, name in ipairs({ "PlayerDataChanged", "RoundStart", "GameOver", "KillEvent" }) do
	local ev = gameplay and gameplay:FindFirstChild(name)
	if ev and ev:IsA("RemoteEvent") then
		on(ev.OnClientEvent, function(...)
			pcall(mergePayload, ...)
			task.spawn(fetchData)
		end)
	end
end

task.spawn(function()
	while running() do
		task.spawn(fetchData)
		task.wait(2)
	end
end)

local function dataStatus()
	local mapText = " | map: " .. (State.map and State.map.Name or "none")
	if not dataRemote then return "Role data: GetPlayerData not found" .. mapText end
	if Data.at == 0 then return "Role data: waiting..." .. (Data.err and (" (" .. Data.err .. ")") or "") .. mapText end
	local m
	for name, d in pairs(State.data) do if d.Role == "Murderer" then m = name end end
	return string.format("Role data: %d players, %ds ago%s", Data.count, math.floor(os.clock() - Data.at),
		m and (" | murderer: " .. m) or "") .. mapText
end

-- dropped gun tracking + notifier. The map streams in, so the same gun can show up more than
-- once as you move around: one notice per few seconds is plenty.
State.gun = workspace:FindFirstChild("GunDrop", true)
do
	local lastNotice = 0
	on(workspace.DescendantAdded, function(d)
		if d.Name ~= "GunDrop" then return end
		State.gun = d
		if Flags.gun_notify and os.clock() - lastNotice > 5 then
			lastNotice = os.clock()
			notify("The gun was dropped.", "Gun", 4)
		end
	end)
end
on(workspace.DescendantRemoving, function(d)
	if d == State.gun then State.gun = nil end
end)

-- slow tick: map/lobby lookup and coin boxes
task.spawn(function()
	while running() do
		State.map = findMap()
		updateLobbyBox()
		updateCoinEsp()
		dataLabel:Set(dataStatus())
		task.wait(0.5)
	end
end)

-- per frame: players and gun
on(RunService.RenderStepped, function()
	updatePlayerEsp()
	updateGunEsp()
end)

-- ctrl + click teleport (clicks on the UI come through as gameProcessed and are ignored)
on(UIS.InputBegan, function(input, gp)
	if gp or not Flags.click_tp or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	if not (UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl)) then return end
	local mouse = LP:GetMouse()
	local r = myRoot()
	if mouse.Target and r then
		teleport(CFrame.new(mouse.Hit.Position + Vector3.new(0, 3, 0)) * r.CFrame.Rotation, true)
	end
end)

-- respawning: the safe spot belongs to the old body, don't drag the new one back to it
on(LP.CharacterAdded, function()
	if Flags.safe_spot then
		safeReturn = nil
		Options.safe_spot:Set(false)
	end
end)

Library:Notify(NAME, "Loaded. Press " .. Library.ToggleKey.Name .. " to hide or show.", 5)
