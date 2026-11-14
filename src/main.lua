--[[
	xpware - Murder Mystery 2
	Engine: Roblox client (executor)  |  Language: Luau

	UI only. Every gameplay callback is a stub; features get wired in later.
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

local NAME = "xpware"
local VERSION = "0.1"
local function stub() end

local Window = Library:CreateWindow({
	Title = NAME .. " - Murder Mystery 2",
	Size = Vector2.new(620, 440),
	ToggleKey = Enum.KeyCode.RightShift,
	Taskbar = true,
	Status = "Ready",
})

------------------------------------------------------------------------
-- ESP
------------------------------------------------------------------------
local ESP = Window:AddTab("ESP")

local Players = ESP:AddGroup("Players", "Left")
Players:AddToggle("esp_murderer", { Text = "Murderer", Default = true, Callback = stub })
Players:AddToggle("esp_sheriff", { Text = "Sheriff", Default = true, Callback = stub })
Players:AddToggle("esp_innocent", { Text = "Innocents", Callback = stub })
Players:AddDropdown("esp_parts", { Text = "Draw", Values = { "Box", "Name", "Distance", "Tracer", "Chams" }, Multi = true, Default = { "Box", "Name" }, Callback = stub })
Players:AddSlider("esp_distance", { Text = "Max Distance", Min = 50, Max = 1000, Default = 500, Suffix = " studs", Callback = stub })

local Items = ESP:AddGroup("Items", "Right")
Items:AddToggle("gun_esp", { Text = "Dropped Gun", Callback = stub })
Items:AddToggle("coin_esp", { Text = "Coins", Callback = stub })

------------------------------------------------------------------------
-- Combat
------------------------------------------------------------------------
local Combat = Window:AddTab("Combat")

local Sheriff = Combat:AddGroup("Sheriff", "Left")
Sheriff:AddToggle("silent_aim", { Text = "Silent Aim", Tooltip = "Redirects gun shots to the murderer", Callback = stub })
Sheriff:AddSlider("hit_chance", { Text = "Hit Chance", Min = 0, Max = 100, Default = 100, Suffix = "%", Callback = stub })
Sheriff:AddDropdown("aim_part", { Text = "Aim Part", Values = { "Head", "Torso", "HumanoidRootPart" }, Default = "Torso", Callback = stub })
Sheriff:AddKeybind("aim_key", { Text = "Aim Key", Default = Enum.KeyCode.E, Mode = "Hold", Callback = stub })

local Murderer = Combat:AddGroup("Murderer", "Right")
Murderer:AddToggle("knife_aura", { Text = "Knife Aura", Callback = stub })
Murderer:AddSlider("aura_range", { Text = "Aura Range", Min = 5, Max = 25, Default = 12, Suffix = " studs", Callback = stub })
Murderer:AddToggle("throw_assist", { Text = "Throw Assist", Callback = stub })

------------------------------------------------------------------------
-- Teleport
------------------------------------------------------------------------
local Teleport = Window:AddTab("Teleport")

local Places = Teleport:AddGroup("Places", "Left")
Places:AddButton({ Text = "Lobby", Callback = stub })
Places:AddButton({ Text = "Map", Callback = stub })
Places:AddButton({ Text = "Dropped Gun", Callback = stub })

local ToPlayer = Teleport:AddGroup("Players", "Right")
ToPlayer:AddTextbox("tp_target", { Text = "Player", Placeholder = "player name...", Callback = stub })
ToPlayer:AddButton({ Text = "Teleport To Player", Callback = stub })
ToPlayer:AddButton({ Text = "Teleport To Murderer", Callback = stub })
ToPlayer:AddButton({ Text = "Teleport To Sheriff", Callback = stub })

------------------------------------------------------------------------
-- Trolling
------------------------------------------------------------------------
local Trolling = Window:AddTab("Trolling")

local Target = Trolling:AddGroup("Target", "Left")
Target:AddTextbox("troll_target", { Text = "Player", Placeholder = "player name...", Callback = stub })
Target:AddToggle("spectate", { Text = "Spectate", Callback = stub })
Target:AddToggle("follow", { Text = "Follow", Callback = stub })
Target:AddToggle("orbit", { Text = "Orbit", Callback = stub })
Target:AddSlider("orbit_speed", { Text = "Orbit Speed", Min = 1, Max = 20, Default = 5, Callback = stub })

local Fling = Trolling:AddGroup("Fling", "Right")
Fling:AddButton({ Text = "Fling Target", Callback = stub })
Fling:AddButton({ Text = "Fling Murderer", Callback = stub })

------------------------------------------------------------------------
-- Player
------------------------------------------------------------------------
local PlayerTab = Window:AddTab("Player")

local Movement = PlayerTab:AddGroup("Movement", "Left")
Movement:AddSlider("walkspeed", { Text = "WalkSpeed", Min = 16, Max = 100, Default = 16, Callback = stub })
Movement:AddSlider("jumppower", { Text = "JumpPower", Min = 50, Max = 200, Default = 50, Callback = stub })
Movement:AddToggle("inf_jump", { Text = "Infinite Jump", Callback = stub })
Movement:AddToggle("noclip", { Text = "Noclip", Callback = stub })

local Fly = PlayerTab:AddGroup("Fly", "Right")
Fly:AddToggle("fly", { Text = "Fly", Callback = stub })
Fly:AddKeybind("fly_key", { Text = "Fly Key", Default = Enum.KeyCode.F, Callback = stub })
Fly:AddSlider("fly_speed", { Text = "Fly Speed", Min = 10, Max = 150, Default = 50, Callback = stub })

------------------------------------------------------------------------
-- Graphics
------------------------------------------------------------------------
local Graphics = Window:AddTab("Graphics")

local Lighting = Graphics:AddGroup("Lighting", "Left")
Lighting:AddToggle("fullbright", { Text = "Fullbright", Callback = stub })
Lighting:AddToggle("no_fog", { Text = "No Fog", Callback = stub })
Lighting:AddToggle("no_shadows", { Text = "No Shadows", Callback = stub })

local Camera = Graphics:AddGroup("Camera", "Right")
Camera:AddSlider("fov", { Text = "Field of View", Min = 70, Max = 120, Default = 70, Callback = stub })
Camera:AddToggle("fps_boost", { Text = "FPS Boost", Tooltip = "Strips textures and particles", Callback = stub })

------------------------------------------------------------------------
-- Misc
------------------------------------------------------------------------
local Misc = Window:AddTab("Misc")

local Roles = Misc:AddGroup("Roles", "Left")
Roles:AddToggle("role_notify", { Text = "Role Notifier", Default = true, Callback = stub })
local murdererLabel = Roles:AddLabel("Murderer: -")
local sheriffLabel = Roles:AddLabel("Sheriff: -")

local Server = Misc:AddGroup("Server", "Right")
Server:AddToggle("anti_afk", { Text = "Anti AFK", Default = true, Callback = stub })
Server:AddButton({ Text = "Rejoin Server", Callback = stub })
Server:AddButton({ Text = "Server Hop", Callback = stub })

------------------------------------------------------------------------
-- Autofarm
------------------------------------------------------------------------
local Autofarm = Window:AddTab("Autofarm")

local Coins = Autofarm:AddGroup("Coins", "Left")
Coins:AddToggle("coin_farm", { Text = "Auto Collect Coins", Callback = stub })
Coins:AddSlider("farm_speed", { Text = "Farm Speed", Min = 1, Max = 10, Default = 5, Callback = stub })
Coins:AddToggle("reset_full", { Text = "Reset When Bag Full", Callback = stub })

local Gun = Autofarm:AddGroup("Gun", "Right")
Gun:AddToggle("grab_gun", { Text = "Grab Dropped Gun", Callback = stub })

------------------------------------------------------------------------
-- Fun
------------------------------------------------------------------------
local Fun = Window:AddTab("Fun")

local Character = Fun:AddGroup("Character", "Left")
Character:AddToggle("spin", { Text = "Spin", Callback = stub })
Character:AddSlider("spin_speed", { Text = "Spin Speed", Min = 1, Max = 50, Default = 10, Callback = stub })
Character:AddToggle("jump_spam", { Text = "Jump Spam", Callback = stub })

local Emotes = Fun:AddGroup("Emotes", "Right")
Emotes:AddDropdown("emote", { Text = "Emote", Values = { "Dance", "Dance 2", "Dance 3", "Wave", "Point", "Cheer" }, Default = "Dance", Callback = stub })
Emotes:AddButton({ Text = "Play Emote", Callback = stub })

------------------------------------------------------------------------
-- Settings (these are UI controls, so they actually work)
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

local About = Settings:AddGroup("About", "Right")
About:AddLabel(NAME .. " v" .. VERSION, { Bold = true })
About:AddLabel("Murder Mystery 2", { Color = Library.Theme.TextDim })
About:AddDivider()
About:AddLabel("The X button only minimizes. Use Turn Off in the Start menu to unload.")

Library:Notify(NAME, "Loaded. Press " .. Library.ToggleKey.Name .. " to hide or show.", 5)
