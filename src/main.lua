--[[
	xpware - Murder Mystery 2
	Engine: Roblox client (executor)  |  Language: Luau

	UI only. Every gameplay callback is a stub; features get wired in one at a time.
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

local Players = game:GetService("Players")
local LP = Players.LocalPlayer

local NAME = "xpware"
local VERSION = "0.2"
local function stub() end

local function otherNames()
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then table.insert(t, p.Name) end
	end
	table.sort(t, function(a, b) return a:lower() < b:lower() end)
	return t
end

local Window = Library:CreateWindow({
	Title = NAME .. " - Murder Mystery 2",
	Size = Vector2.new(620, 460),
	ToggleKey = Enum.KeyCode.RightShift,
	Taskbar = true,
	Status = "Ready",
})

------------------------------------------------------------------------
-- ESP
------------------------------------------------------------------------
local ESP = Window:AddTab("ESP")

local EspPlayers = ESP:AddGroup("Players", "Left")
EspPlayers:AddToggle("esp_murderer", { Text = "Murderer", Default = true, Callback = stub })
EspPlayers:AddToggle("esp_sheriff", { Text = "Sheriff / Hero", Default = true, Callback = stub })
EspPlayers:AddToggle("esp_innocent", { Text = "Innocents", Callback = stub })
EspPlayers:AddToggle("esp_round_only", { Text = "Only Players In Round", Default = true, Tooltip = "Hides people standing in the lobby", Callback = stub })
EspPlayers:AddDropdown("esp_parts", { Text = "Draw", Values = { "Outline", "Name", "Role", "Distance", "Health", "Tracer" }, Multi = true, Default = { "Outline", "Name", "Role" }, Callback = stub })
EspPlayers:AddSlider("esp_distance", { Text = "Max Distance", Min = 50, Max = 2000, Default = 1000, Suffix = " studs", Callback = stub })

local EspStyle = ESP:AddGroup("Outline Style", "Right")
EspStyle:AddToggle("esp_walls", { Text = "Show Through Walls", Default = true, Callback = stub })
EspStyle:AddSlider("esp_fill", { Text = "Fill Opacity", Min = 0, Max = 100, Default = 15, Suffix = "%", Tooltip = "0 = outline only", Callback = stub })
EspStyle:AddLabel("Red = murderer, blue = sheriff, gold = hero, green = innocent.", { Color = Library.Theme.TextDim })

local EspItems = ESP:AddGroup("Items", "Right")
EspItems:AddToggle("gun_esp", { Text = "Dropped Gun", Default = true, Callback = stub })
EspItems:AddToggle("coin_esp", { Text = "Coins", Callback = stub })

------------------------------------------------------------------------
-- Combat
------------------------------------------------------------------------
local Combat = Window:AddTab("Combat")

local Sheriff = Combat:AddGroup("Sheriff", "Left")
Sheriff:AddToggle("silent_aim", { Text = "Silent Aim", Tooltip = "Gun shots land on the murderer wherever you click", Callback = stub })
Sheriff:AddSlider("hit_chance", { Text = "Hit Chance", Min = 0, Max = 100, Default = 100, Suffix = "%", Callback = stub })
Sheriff:AddDropdown("aim_part", { Text = "Aim Part", Values = { "Head", "Torso", "HumanoidRootPart" }, Default = "HumanoidRootPart", Callback = stub })
Sheriff:AddSlider("prediction", { Text = "Prediction", Min = 0, Max = 300, Default = 120, Suffix = " ms", Tooltip = "Leads the target by their velocity", Callback = stub })
Sheriff:AddToggle("auto_shoot", { Text = "Auto Shoot Murderer", Tooltip = "Fires when the murderer is in line of sight. Pair with Silent Aim.", Callback = stub })
Sheriff:AddKeybind("shoot_key", { Text = "Shoot Murderer", Default = Enum.KeyCode.E, Callback = stub })

local Murderer = Combat:AddGroup("Murderer", "Right")
Murderer:AddToggle("knife_aura", { Text = "Knife Aura", Callback = stub })
Murderer:AddSlider("aura_range", { Text = "Aura Range", Min = 5, Max = 25, Default = 12, Suffix = " studs", Callback = stub })
Murderer:AddToggle("auto_equip", { Text = "Auto Equip Knife", Default = true, Callback = stub })
Murderer:AddToggle("throw_assist", { Text = "Throw Assist", Tooltip = "Knife throws hit whoever's closest to your cursor", Callback = stub })
Murderer:AddDivider()
Murderer:AddButton({ Text = "Kill All", Callback = stub })

------------------------------------------------------------------------
-- Teleport
------------------------------------------------------------------------
local Teleport = Window:AddTab("Teleport")

local Places = Teleport:AddGroup("Places", "Left")
Places:AddButton({ Text = "Lobby", Callback = stub })
Places:AddButton({ Text = "Map", Callback = stub })
Places:AddButton({ Text = "Dropped Gun", Callback = stub })
Places:AddDivider()
Places:AddToggle("safe_spot", { Text = "Safe Spot", Tooltip = "Parks you on a platform high above the map. Turn off to go back.", Callback = stub })
Places:AddToggle("click_tp", { Text = "Ctrl + Click Teleport", Callback = stub })

local ToPlayer = Teleport:AddGroup("Players", "Right")
local tpTarget = ToPlayer:AddDropdown("tp_target", { Text = "Player", Values = otherNames(), Callback = stub })
ToPlayer:AddButton({ Text = "Teleport To Player", Callback = stub })
ToPlayer:AddButton({ Text = "Teleport To Murderer", Callback = stub })
ToPlayer:AddButton({ Text = "Teleport To Sheriff", Callback = stub })

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
local listConns = {
	Players.PlayerAdded:Connect(refreshPlayerLists),
	Players.PlayerRemoving:Connect(function() task.defer(refreshPlayerLists) end),
}
Library:OnUnload(function()
	for _, c in ipairs(listConns) do c:Disconnect() end
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
-- Graphics
------------------------------------------------------------------------
local Graphics = Window:AddTab("Graphics")

local LightingGroup = Graphics:AddGroup("Lighting", "Left")
LightingGroup:AddToggle("fullbright", { Text = "Fullbright", Callback = stub })
LightingGroup:AddToggle("no_fog", { Text = "No Fog", Callback = stub })
LightingGroup:AddToggle("no_shadows", { Text = "No Shadows", Callback = stub })
LightingGroup:AddToggle("custom_time", { Text = "Custom Time", Callback = stub })
LightingGroup:AddSlider("clock_time", { Text = "Time Of Day", Min = 0, Max = 24, Default = 14, Rounding = 1, Suffix = "h", Callback = stub })

local CameraGroup = Graphics:AddGroup("Camera", "Right")
CameraGroup:AddSlider("fov", { Text = "Field of View", Min = 70, Max = 120, Default = 70, Callback = stub })
CameraGroup:AddToggle("unlock_zoom", { Text = "Unlock Zoom", Callback = stub })
CameraGroup:AddToggle("fps_boost", { Text = "FPS Boost", Tooltip = "Strips materials, textures and particles", Callback = stub })

local XrayGroup = Graphics:AddGroup("X-Ray", "Right")
XrayGroup:AddToggle("xray", { Text = "X-Ray Map", Callback = stub })
XrayGroup:AddSlider("xray_amount", { Text = "Wall Transparency", Min = 10, Max = 90, Default = 60, Suffix = "%", Callback = stub })

------------------------------------------------------------------------
-- Misc
------------------------------------------------------------------------
local Misc = Window:AddTab("Misc")

local Roles = Misc:AddGroup("Roles", "Left")
Roles:AddToggle("role_notify", { Text = "Role Notifier", Default = true, Callback = stub })
Roles:AddToggle("gun_notify", { Text = "Gun Drop Notifier", Default = true, Callback = stub })
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

local Coins = Autofarm:AddGroup("Coins", "Left")
Coins:AddToggle("coin_farm", { Text = "Auto Collect Coins", Callback = stub })
Coins:AddSlider("farm_speed", { Text = "Farm Speed", Min = 1, Max = 10, Default = 4, Tooltip = "Higher is faster but easier to get kicked for", Callback = stub })
Coins:AddToggle("avoid_murderer", { Text = "Avoid Murderer", Default = true, Callback = stub })
Coins:AddSlider("avoid_radius", { Text = "Avoid Radius", Min = 10, Max = 60, Default = 25, Suffix = " studs", Callback = stub })
Coins:AddToggle("reset_full", { Text = "Reset When Bag Full", Callback = stub })
Coins:AddSlider("bag_size", { Text = "Bag Size", Min = 10, Max = 50, Default = 40, Tooltip = "40 normally, 50 with Elite", Callback = stub })
local coinLabel = Coins:AddLabel("Collected this round: 0")

local Gun = Autofarm:AddGroup("Gun", "Right")
Gun:AddToggle("grab_gun", { Text = "Auto Grab Dropped Gun", Callback = stub })
Gun:AddToggle("gun_return", { Text = "Return After Grabbing", Default = true, Callback = stub })
Gun:AddButton({ Text = "Grab Gun Now", Callback = stub })

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
Menu:AddToggle("show_taskbar", { Text = "Show Taskbar", Default = true, Callback = function(v) Library:SetTaskbar(v) end })
Menu:AddDivider()
Menu:AddButton({ Text = "Test Notification", Callback = function()
	Library:Notify("Murderer found", "This is what a role alert will look like once the features are in.", 5)
end })
Menu:AddButton({ Text = "Unload", Callback = function() Library:Unload() end })

local Config = Settings:AddGroup("Config", "Left")
Config:AddButton({ Text = "Save Config", Callback = stub })
Config:AddButton({ Text = "Load Config", Callback = stub })
Config:AddToggle("autoload", { Text = "Load Config On Start", Callback = stub })

local About = Settings:AddGroup("About", "Right")
About:AddLabel(NAME .. " v" .. VERSION, { Bold = true })
About:AddLabel("Murder Mystery 2", { Color = Library.Theme.TextDim })
About:AddDivider()
About:AddLabel("The X button only minimizes. Use Turn Off in the Start menu to unload.")

-- labels the role/farm features will drive later
local _ = { murdererLabel, sheriffLabel, myRoleLabel, coinLabel }

Library:Notify(NAME, "Loaded. Press " .. Library.ToggleKey.Name .. " to hide or show.", 5)
