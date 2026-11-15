--[[
	xpware - Murder Mystery 2
	Engine: Roblox client (executor)  |  Language: Luau

	Built tab by tab. Done: ESP, Teleport (incl. dropped gun), Combat, master switches.
	Everything else is still a stub.
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
local VERSION = "0.9.2"
local function stub() end
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

local busy = false -- true while Kill All (and later, fling) is driving the character

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
local Trolling = Window:AddTab("Trolling")

local Target = Trolling:AddGroup("Target", "Left")
local trollTarget = Target:AddDropdown("troll_target", { Text = "Player", Values = otherNames(), Callback = stub })
Target:AddToggle("spectate", { Text = "Spectate", Callback = stub })
Target:AddToggle("follow", { Text = "Follow", Callback = stub })
Target:AddToggle("orbit", { Text = "Orbit", Callback = stub })
Target:AddSlider("orbit_speed", { Text = "Orbit Speed", Min = 1, Max = 20, Default = 5, Callback = stub })
Target:AddSlider("orbit_radius", { Text = "Orbit Radius", Min = 3, Max = 20, Default = 6, Suffix = " studs", Callback = stub })

local Fling = Trolling:AddGroup("Fling", "Right")
Fling:AddButton({ Text = "Fling Target", Callback = stub })
Fling:AddButton({ Text = "Fling Murderer", Callback = stub })
Fling:AddButton({ Text = "Fling Sheriff", Callback = stub })

local Chat = Trolling:AddGroup("Chat", "Right")
Chat:AddButton({ Text = "Announce Roles In Chat", Callback = stub })

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

------------------------------------------------------------------------
-- Player
------------------------------------------------------------------------
local PlayerTab = Window:AddTab("Player")

local Movement = PlayerTab:AddGroup("Movement", "Left")
Movement:AddSlider("walkspeed", { Text = "WalkSpeed", Min = 16, Max = 100, Default = 16, Callback = stub })
Movement:AddSlider("jumppower", { Text = "JumpPower", Min = 50, Max = 200, Default = 50, Callback = stub })
Movement:AddToggle("inf_jump", { Text = "Infinite Jump", Callback = stub })
Movement:AddToggle("noclip", { Text = "Noclip", Callback = stub })
Movement:AddToggle("anti_fling", { Text = "Anti Fling", Tooltip = "Other players can't push or fling you", Callback = stub })

local Fly = PlayerTab:AddGroup("Fly", "Right")
Fly:AddToggle("fly", { Text = "Fly", Tooltip = "WASD, Space up, Ctrl down", Callback = stub })
Fly:AddKeybind("fly_key", { Text = "Fly Key", Default = Enum.KeyCode.F, Callback = stub })
Fly:AddSlider("fly_speed", { Text = "Fly Speed", Min = 10, Max = 150, Default = 50, Callback = stub })

------------------------------------------------------------------------
-- Misc
------------------------------------------------------------------------
local Misc = Window:AddTab("Misc")

local Roles = Misc:AddGroup("Roles", "Left")
Roles:AddToggle("role_notify", { Text = "Role Notifier", Default = true, Callback = stub })
local murdererLabel = Roles:AddLabel("Murderer: -")
local sheriffLabel = Roles:AddLabel("Sheriff: -")
local myRoleLabel = Roles:AddLabel("You: -")

local Server = Misc:AddGroup("Server", "Right")
Server:AddToggle("anti_afk", { Text = "Anti AFK", Default = true, Callback = stub })
Server:AddToggle("auto_rejoin", { Text = "Auto Rejoin On Kick", Callback = stub })
Server:AddButton({ Text = "Rejoin Server", Callback = stub })
Server:AddButton({ Text = "Server Hop", Callback = stub })
Server:AddButton({ Text = "Copy Server ID", Callback = stub })

------------------------------------------------------------------------
-- Autofarm
------------------------------------------------------------------------
local Autofarm = Window:AddTab("Autofarm")
Autofarm:AddMasterToggle("autofarm_enabled", { Text = "Autofarm", Default = true, Tooltip = "Master switch for every autofarm feature" })

local Coins = Autofarm:AddGroup("Coins", "Left")
Coins:AddToggle("coin_farm", { Text = "Auto Collect Coins", Callback = stub })
Coins:AddSlider("farm_speed", { Text = "Farm Speed", Min = 1, Max = 10, Default = 4, Tooltip = "Higher is faster but easier to get kicked for", Callback = stub })
Coins:AddToggle("avoid_murderer", { Text = "Avoid Murderer", Default = true, Callback = stub })
Coins:AddSlider("avoid_radius", { Text = "Avoid Radius", Min = 10, Max = 60, Default = 25, Suffix = " studs", Callback = stub })
Coins:AddToggle("reset_full", { Text = "Reset When Bag Full", Callback = stub })
Coins:AddSlider("bag_size", { Text = "Bag Size", Min = 10, Max = 50, Default = 40, Tooltip = "40 normally, 50 with Elite", Callback = stub })
local coinLabel = Coins:AddLabel("Collected this round: 0")

------------------------------------------------------------------------
-- Fun
------------------------------------------------------------------------
local Fun = Window:AddTab("Fun")

local Character = Fun:AddGroup("Character", "Left")
Character:AddToggle("spin", { Text = "Spin", Callback = stub })
Character:AddSlider("spin_speed", { Text = "Spin Speed", Min = 1, Max = 50, Default = 10, Callback = stub })
Character:AddToggle("jump_spam", { Text = "Jump Spam", Callback = stub })
Character:AddToggle("freeze", { Text = "Freeze In Place", Callback = stub })
Character:AddButton({ Text = "Sit", Callback = stub })

local Emotes = Fun:AddGroup("Emotes", "Right")
Emotes:AddDropdown("emote", { Text = "Emote", Values = { "Dance", "Dance 2", "Dance 3", "Wave", "Point", "Cheer", "Laugh" }, Default = "Dance", Callback = stub })
Emotes:AddButton({ Text = "Play Emote", Callback = stub })
Emotes:AddButton({ Text = "Stop Emote", Callback = stub })
Emotes:AddLabel("Walking cancels the emote.", { Color = Library.Theme.TextDim })

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
	Library:Notify("Murderer found", "This is what a role alert will look like once the features are in.", 5)
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

-- labels the role/farm features will drive later
local _ = { murdererLabel, sheriffLabel, myRoleLabel, coinLabel }

------------------------------------------------------------------------
-- Settings persistence: every control saves to xpware/mm2.json when it changes and loads on start
------------------------------------------------------------------------
local CONFIG_DIR = "xpware"
local CONFIG_FILE = CONFIG_DIR .. "/mm2.json"
local canSave = typeof(writefile) == "function" and typeof(readfile) == "function" and typeof(isfile) == "function"

-- session-only state: restoring these would teleport you, lock onto an old target, or float you
local NO_SAVE = {
	tp_target = true, troll_target = true, safe_spot = true,
	spectate = true, follow = true, orbit = true, fly = true, freeze = true,
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
