--!nocheck
--[[
	xpui - Windows XP "Luna" UI library for Roblox executors
	Engine: Roblox client  |  Language: Luau
	Executor extras used if present: gethui, syn.protect_gui, getgenv

	local Library = loadstring(...)()
	local Window  = Library:CreateWindow({ Title = "xpware", Size = Vector2.new(580, 440) })
	local Tab     = Window:AddTab("Main")
	local Group   = Tab:AddGroup("Combat", "Left")      -- "Left" | "Right"
	Group:AddToggle("flag", { Text = "Thing", Default = false, Callback = function(v) end })
	Library.Flags.flag  -> current value
]]

local Players      = game:GetService("Players")
local UIS          = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local TextService  = game:GetService("TextService")
local HttpService  = game:GetService("HttpService")
local GuiService   = game:GetService("GuiService")

local Library = {
	Flags = {},
	Options = {},
	Toggled = true,
	ToggleKey = Enum.KeyCode.RightShift,
	_conns = {},
	_popups = {},
	_onUnload = {},
}

-- re-executing the script replaces the old UI instead of stacking a second one
local env = (typeof(getgenv) == "function" and getgenv()) or _G
if env.__xpui and env.__xpui.Unload then
	pcall(function() env.__xpui:Unload() end)
end
env.__xpui = Library

------------------------------------------------------------------------
-- Theme (sampled from the Luna "blue" visual style)
------------------------------------------------------------------------
local hex = Color3.fromHex

local Theme = {
	Face         = hex("ECE9D8"),
	Panel        = hex("FCFCFE"),
	PanelMid     = hex("F8F8F5"),
	PanelBorder  = hex("919B9C"),
	Text         = hex("000000"),
	TextDim      = hex("ACA899"),
	GroupBorder  = hex("D0D0BF"),
	GroupText    = hex("0046D5"),
	FieldBorder  = hex("7F9DB9"),
	ButtonBorder = hex("003C74"),
	CheckBorder  = hex("1C5180"),
	Check        = hex("21A121"),
	TabTop       = hex("E68B2C"),
	TabTopLight  = hex("FFC73C"),
	Select       = hex("316AC5"),
	Tooltip      = hex("FFFFE1"),
	White        = hex("FFFFFF"),
	Black        = hex("000000"),
	Etch         = hex("ACA899"),
}
Library.Theme = Theme

local G = {
	Title        = {{0,"0997FF"},{0.08,"0053EE"},{0.40,"0050EE"},{0.88,"0066FF"},{0.93,"0066FF"},{0.95,"005BFF"},{0.96,"003DD7"},{1,"003DD7"}},
	Caption      = {{0,"B6D3FF"},{0.12,"6FA4FF"},{0.5,"2F6CF0"},{1,"1C4CC9"}},
	CaptionClose = {{0,"F7C1AE"},{0.12,"EE8A6A"},{0.5,"DA4E2E"},{1,"B32D0E"}},
	Button       = {{0,"FFFFFF"},{0.86,"ECEBE6"},{1,"D6D0C5"}},
	ButtonDown   = {{0,"CDCAC3"},{0.08,"E3E3DB"},{0.94,"E5E5DE"},{1,"F2F2F1"}},
	HoverRing    = {{0,"FFF0CF"},{0.3,"FDD889"},{0.7,"FBC761"},{1,"E5A01A"}},
	Check        = {{0,"DCDCD7"},{1,"FFFFFF"}},
	CheckHover   = {{0,"FFF0CF"},{1,"F8B330"}},
	TabIdle      = {{0,"FFFFFF"},{0.8,"F3F3EF"},{1,"ECEBE5"}},
	Panel        = {{0,"FCFCFE"},{1,"F4F3EE"}},
	Thumb        = {{0,"FFFFFF"},{1,"E2E1D9"}},
	ComboBtn     = {{0,"E6EEFC"},{0.5,"C6D6F7"},{1,"B1C7F5"}},
	ComboHover   = {{0,"FDFFFF"},{0.5,"DDE8FE"},{1,"C3D6FD"}},
}

local FONT        = Font.fromEnum(Enum.Font.Arial)
local FONT_BOLD   = Font.new(FONT.Family, Enum.FontWeight.Bold)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function new(class, props)
	local inst = Instance.new(class)
	if inst:IsA("GuiObject") then inst.BorderSizePixel = 0 end
	if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
		inst.FontFace = FONT
		inst.TextSize = 13
		inst.TextColor3 = Theme.Text
		inst.BackgroundTransparency = 1
		inst.Text = ""
	end
	if inst:IsA("GuiButton") then inst.AutoButtonColor = false end
	local parent
	if props then
		for k, v in pairs(props) do
			if type(k) == "number" then
				v.Parent = inst
			elseif k == "Parent" then
				parent = v
			else
				inst[k] = v
			end
		end
	end
	if parent then inst.Parent = parent end
	return inst
end

local function px(x, y) return UDim2.fromOffset(x, y) end
local function ud(xs, xo, ys, yo) return UDim2.new(xs, xo, ys, yo) end

local function seq(stops)
	local kp = {}
	for i, s in ipairs(stops) do kp[i] = ColorSequenceKeypoint.new(s[1], hex(s[2])) end
	return ColorSequence.new(kp)
end

-- squeeze a gradient into the top `k` fraction (used when a frame is taller than what's visible)
local function scaled(stops, k)
	local out = {}
	for i, s in ipairs(stops) do out[i] = {s[1] * k, s[2]} end
	table.insert(out, {1, stops[#stops][2]})
	return out
end

local function gradient(stops, rot)
	return new("UIGradient", { Color = seq(stops), Rotation = rot or 90 })
end
local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function stroke(color, thick)
	return new("UIStroke", { Color = color, Thickness = thick or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end
local function pad(t, r, b, l)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, t), PaddingRight = UDim.new(0, r or t),
		PaddingBottom = UDim.new(0, b or t), PaddingLeft = UDim.new(0, l or r or t),
	})
end
local function list(dir, gap)
	return new("UIListLayout", {
		FillDirection = dir or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end
local function box(parent, pos, size, color, z)
	return new("Frame", { Parent = parent, Position = pos, Size = size, BackgroundColor3 = color, ZIndex = z or 1 })
end

-- a rotated 1-piece line, used for glyphs (check marks, X, chevrons)
local function segment(parent, x1, y1, x2, y2, thick, color, z)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	return new("Frame", {
		Parent = parent, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = px((x1 + x2) / 2, (y1 + y2) / 2), Size = px(len + thick * 0.5, thick),
		Rotation = math.deg(math.atan2(dy, dx)), BackgroundColor3 = color, ZIndex = z or 1,
	})
end

local function textWidth(str, size, bold)
	return TextService:GetTextSize(str, size or 13, bold and Enum.Font.ArialBold or Enum.Font.Arial, Vector2.new(4096, 4096)).X
end

local function tween(obj, t, props)
	local tw = TweenService:Create(obj, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(Library._conns, c)
	return c
end

local function hoverable(gui)
	local state = { hovered = false }
	connect(gui.MouseEnter, function() state.hovered = true end)
	connect(gui.MouseLeave, function() state.hovered = false end)
	return state
end

local function isPress(i) return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch end
local function isMove(i) return i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch end

local function keyName(k)
	if k == nil then return "None" end
	if k.EnumType == Enum.UserInputType then
		return ({ MouseButton1 = "MB1", MouseButton2 = "MB2", MouseButton3 = "MB3" })[k.Name] or k.Name
	end
	return k.Name
end

-- four-pane logo used for the title bar and the compact bar
local function logo(parent, x, y, s, z)
	local holder = new("Frame", { Parent = parent, BackgroundTransparency = 1, Position = px(x, y), Size = px(s, s), ZIndex = z or 1 })
	local h = math.floor((s - 1) / 2)
	local cols = { hex("F65314"), hex("7CBB00"), hex("00A1F1"), hex("FFBB00") }
	for i = 0, 3 do
		new("Frame", {
			Parent = holder, Position = px((i % 2) * (h + 1), math.floor(i / 2) * (h + 1)), Size = px(h, h),
			BackgroundColor3 = cols[i + 1], ZIndex = z or 1, corner(1),
		})
	end
	return holder
end

-- parent the ScreenGui somewhere the game can't easily see it
local function mount(gui)
	if typeof(gethui) == "function" then
		local ok = pcall(function() gui.Parent = gethui() end)
		if ok and gui.Parent then return end
	end
	if typeof(syn) == "table" and typeof(syn.protect_gui) == "function" then
		pcall(syn.protect_gui, gui)
	end
	local ok = pcall(function() gui.Parent = game:GetService("CoreGui") end)
	if ok and gui.Parent then return end
	local lp = Players.LocalPlayer
	if lp then gui.Parent = lp:WaitForChild("PlayerGui") end
end

------------------------------------------------------------------------
-- Classic XP push button (used by buttons, keybinds)
------------------------------------------------------------------------
local function xpButton(parent, pos, size, text)
	local b = new("TextButton", {
		Parent = parent, Position = pos, Size = size, BackgroundColor3 = Theme.White, BackgroundTransparency = 0,
		Text = text or "", corner(3), stroke(Theme.ButtonBorder),
	})
	local g = gradient(G.Button); g.Parent = b
	local ring = new("Frame", { Parent = b, BackgroundTransparency = 1, Position = px(2, 2), Size = ud(1, -4, 1, -4), Visible = false, corner(2) })
	local rs = stroke(hex("F8B330"), 2); rs.Parent = ring
	gradient(G.HoverRing).Parent = rs

	connect(b.MouseEnter, function() ring.Visible = true end)
	connect(b.MouseLeave, function() ring.Visible = false; g.Color = seq(G.Button) end)
	connect(b.MouseButton1Down, function() g.Color = seq(G.ButtonDown) end)
	connect(b.MouseButton1Up, function() g.Color = seq(G.Button) end)
	return b
end

------------------------------------------------------------------------
-- Popups (dropdown lists): one open at a time, click outside closes
------------------------------------------------------------------------
function Library:_openPopup(p)
	for _, other in ipairs(self._popups) do
		if other ~= p then other.close() end
	end
	self._popups = { p }
end

function Library:_closePopups()
	for _, p in ipairs(self._popups) do p.close() end
	self._popups = {}
end

function Library:_tooltip(gui, text)
	if not text then return end
	local token = 0
	connect(gui.MouseEnter, function()
		token += 1
		local my = token
		task.delay(0.5, function()
			if my ~= token or not self._tip or not gui.Parent then return end
			local rp = self._root.AbsolutePosition
			local ap, as = gui.AbsolutePosition, gui.AbsoluteSize
			self._tip.Text = text
			self._tip.Position = px(ap.X - rp.X + 12, ap.Y - rp.Y + as.Y + 4)
			self._tip.Visible = true
		end)
	end)
	connect(gui.MouseLeave, function()
		token += 1
		if self._tip then self._tip.Visible = false end
	end)
end

------------------------------------------------------------------------
-- Group elements
------------------------------------------------------------------------
local Group = {}
Group.__index = Group

function Group:_next()
	self._order += 1
	return self._order
end

local function fire(obj, cb, ...)
	if cb then task.spawn(cb, ...) end
	for _, f in ipairs(obj._changed) do task.spawn(f, ...) end
end

local function element(obj)
	obj._changed = {}
	function obj:OnChanged(f) table.insert(self._changed, f) end
	return obj
end

-- Checkbox ----------------------------------------------------------------
function Group:AddToggle(flag, o)
	o = o or {}
	local T = element({ Type = "Toggle", Value = false })

	local row = new("TextButton", { Parent = self._content, Size = ud(1, 0, 0, 17), LayoutOrder = self:_next() })
	local cb = new("Frame", { Parent = row, Position = px(1, 3), Size = px(11, 11), BackgroundColor3 = Theme.White, stroke(Theme.CheckBorder) })
	local cg = gradient(G.Check, 45); cg.Parent = cb
	new("Frame", { Parent = cb, Position = px(2, 2), Size = px(7, 7), BackgroundColor3 = Theme.White, gradient(G.Check, 45) })
	local mark = new("Frame", { Parent = cb, BackgroundTransparency = 1, Size = ud(1, 0, 1, 0), Visible = false })
	segment(mark, 2, 5, 4.5, 8, 2, Theme.Check)
	segment(mark, 4, 8, 9, 2.5, 2, Theme.Check)
	new("TextLabel", { Parent = row, Position = px(19, 0), Size = ud(1, -19, 1, 0), Text = o.Text or flag, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })

	connect(row.MouseEnter, function() cg.Color = seq(G.CheckHover) end)
	connect(row.MouseLeave, function() cg.Color = seq(G.Check) end)

	local function apply(v, doFire)
		v = v and true or false
		T.Value = v
		Library.Flags[flag] = v
		mark.Visible = v
		if doFire then fire(T, o.Callback, v) end
	end
	function T:Set(v) apply(v, true) end

	connect(row.MouseButton1Click, function() apply(not T.Value, true) end)
	apply(o.Default, false)
	Library:_tooltip(row, o.Tooltip)
	Library.Options[flag] = T
	return T
end

-- Trackbar ----------------------------------------------------------------
function Group:AddSlider(flag, o)
	o = o or {}
	local min, max = o.Min or 0, o.Max or 100
	local rounding = o.Rounding or 0
	local suffix = o.Suffix or ""
	local S = element({ Type = "Slider", Value = min })

	local row = new("Frame", { Parent = self._content, BackgroundTransparency = 1, Size = ud(1, 0, 0, 40), LayoutOrder = self:_next() })
	new("TextLabel", { Parent = row, Size = ud(1, -60, 0, 14), Text = o.Text or flag, TextXAlignment = Enum.TextXAlignment.Left })
	local valueLabel = new("TextLabel", { Parent = row, Position = ud(1, -60, 0, 0), Size = px(60, 14), TextXAlignment = Enum.TextXAlignment.Right })

	local area = new("TextButton", { Parent = row, Position = px(0, 15), Size = ud(1, 0, 0, 25) })
	local track = new("Frame", { Parent = area, Position = px(5, 8), Size = ud(1, -10, 0, 4), BackgroundColor3 = hex("F3F2EC") })
	box(track, px(0, 0), ud(1, 0, 0, 1), hex("9D9C99"))
	box(track, px(0, 0), ud(0, 1, 1, 0), hex("9D9C99"))
	box(track, ud(0, 0, 1, -1), ud(1, 0, 0, 1), Theme.White)
	box(track, ud(1, -1, 0, 0), ud(0, 1, 1, 0), Theme.White)
	for i = 0, 10 do
		box(area, ud(i / 10, 5 - i, 0, 21), px(1, 3), hex("A1A192"))
	end

	local thumb = new("Frame", { Parent = area, AnchorPoint = Vector2.new(0.5, 0), Size = px(9, 15), BackgroundColor3 = Theme.White, corner(2), gradient(G.Thumb) })
	local thumbStroke = stroke(hex("7C8CA8")); thumbStroke.Parent = thumb
	box(thumb, ud(0, 1, 1, -3), ud(1, -2, 0, 2), Theme.Check)

	local function fmt(v)
		if rounding <= 0 then return tostring(math.floor(v + 0.5)) end
		return string.format("%." .. rounding .. "f", v)
	end
	local function round(v)
		local m = 10 ^ rounding
		return math.floor(v * m + 0.5) / m
	end
	local function apply(v, doFire)
		v = math.clamp(round(v), min, max)
		local changed = v ~= S.Value
		S.Value = v
		Library.Flags[flag] = v
		local rel = (max == min) and 0 or (v - min) / (max - min)
		thumb.Position = ud(rel, 5 - 10 * rel, 0, 2)
		valueLabel.Text = fmt(v) .. suffix
		if doFire and changed then fire(S, o.Callback, v) end
	end
	function S:Set(v) apply(v, true) end

	local dragging = false
	local function fromInput(input)
		local rel = math.clamp((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		apply(min + (max - min) * rel, true)
	end
	connect(area.InputBegan, function(input)
		if isPress(input) then dragging = true; fromInput(input) end
	end)
	connect(UIS.InputChanged, function(input)
		if dragging and isMove(input) then fromInput(input) end
	end)
	connect(UIS.InputEnded, function(input)
		if isPress(input) then dragging = false end
	end)
	connect(area.MouseEnter, function() thumbStroke.Color = hex("E5A01A") end)
	connect(area.MouseLeave, function() thumbStroke.Color = hex("7C8CA8") end)

	S.Value = nil
	apply(o.Default or min, false)
	Library:_tooltip(row, o.Tooltip)
	Library.Options[flag] = S
	return S
end

-- Push button -------------------------------------------------------------
function Group:AddButton(o, cb)
	if type(o) == "string" then o = { Text = o, Callback = cb } end
	local holder = new("Frame", { Parent = self._content, BackgroundTransparency = 1, Size = ud(1, 0, 0, 25), LayoutOrder = self:_next() })
	local b = xpButton(holder, px(1, 1), ud(1, -2, 0, 23), o.Text or "Button")
	connect(b.MouseButton1Click, function()
		if o.Callback then task.spawn(o.Callback) end
	end)
	Library:_tooltip(b, o.Tooltip)
	return { Instance = b, SetText = function(_, t) b.Text = t end }
end

-- Combo box ---------------------------------------------------------------
function Group:AddDropdown(flag, o)
	o = o or {}
	local multi = o.Multi
	local values = o.Values or {}
	local D = element({ Type = "Dropdown", Value = multi and {} or nil, Values = values })

	local row = new("Frame", { Parent = self._content, BackgroundTransparency = 1, Size = ud(1, 0, 0, 39), LayoutOrder = self:_next() })
	new("TextLabel", { Parent = row, Size = ud(1, 0, 0, 14), Text = o.Text or flag, TextXAlignment = Enum.TextXAlignment.Left })
	local field = new("TextButton", { Parent = row, Position = px(1, 17), Size = ud(1, -2, 0, 21), BackgroundColor3 = Theme.White, BackgroundTransparency = 0, stroke(Theme.FieldBorder) })
	local fieldText = new("TextLabel", { Parent = field, Position = px(4, 0), Size = ud(1, -26, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
	local arrow = new("Frame", { Parent = field, Position = ud(1, -18, 0, 2), Size = px(16, 17), BackgroundColor3 = Theme.White, corner(2), stroke(hex("B9CDF7")) })
	local ag = gradient(G.ComboBtn); ag.Parent = arrow
	segment(arrow, 4, 7, 8, 11, 2, hex("4D6185"))
	segment(arrow, 8, 11, 12, 7, 2, hex("4D6185"))

	local listFrame = new("ScrollingFrame", {
		Parent = Library._overlay, Visible = false, BackgroundColor3 = Theme.White, ZIndex = 5,
		ScrollBarThickness = 4, ScrollBarImageColor3 = hex("A9B8D9"), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
		stroke(Theme.Black), list(),
	})

	local function display()
		if multi then
			local sel = {}
			for _, v in ipairs(values) do if D.Value[v] then table.insert(sel, v) end end
			return #sel > 0 and table.concat(sel, ", ") or "None"
		end
		return D.Value ~= nil and tostring(D.Value) or "None"
	end

	local function apply(v, doFire)
		if multi then
			local copy = {}
			for k, on in pairs(v or {}) do if on then copy[k] = true end end
			D.Value = copy
		else
			D.Value = v
		end
		Library.Flags[flag] = D.Value
		fieldText.Text = display()
		if doFire then fire(D, o.Callback, D.Value) end
	end
	function D:Set(v) apply(v, true) end

	local open = false
	local popup = {}
	local fieldHover, listHover = hoverable(field), hoverable(listFrame)

	local function rebuild()
		for _, c in ipairs(listFrame:GetChildren()) do
			if c:IsA("GuiButton") then c:Destroy() end
		end
		local lit
		local function highlight(item)
			if lit and lit.Parent then lit.BackgroundTransparency = 1; lit.Label.TextColor3 = Theme.Text end
			lit = item
			if item then item.BackgroundTransparency = 0; item.Label.TextColor3 = Theme.White end
		end
		for i, v in ipairs(values) do
			local it = new("TextButton", { Parent = listFrame, Size = ud(1, 0, 0, 16), LayoutOrder = i, BackgroundTransparency = 1, BackgroundColor3 = Theme.Select })
			new("TextLabel", { Parent = it, Name = "Label", Position = px(multi and 18 or 4, 0), Size = ud(1, -22, 1, 0), Text = tostring(v), TextXAlignment = Enum.TextXAlignment.Left })
			local mark
			if multi then
				mark = new("Frame", { Parent = it, BackgroundTransparency = 1, Size = px(16, 16), Visible = D.Value[v] == true })
				segment(mark, 4, 8, 6.5, 11, 2, Theme.Check)
				segment(mark, 6, 11, 11, 5, 2, Theme.Check)
			end
			if not multi and D.Value == v then highlight(it) end
			connect(it.MouseEnter, function() highlight(it) end)
			connect(it.MouseButton1Click, function()
				if multi then
					local nv = table.clone(D.Value)
					nv[v] = not nv[v] or nil
					mark.Visible = nv[v] == true
					apply(nv, true)
				else
					apply(v, true)
					Library:_closePopups()
				end
			end)
		end
	end

	popup.close = function()
		listFrame.Visible = false
		open = false
		ag.Color = seq(G.ComboBtn)
	end
	popup.hovered = function() return fieldHover.hovered or listHover.hovered end

	connect(field.MouseButton1Click, function()
		if open then Library:_closePopups() return end
		rebuild()
		local rp = Library._root.AbsolutePosition
		local ap, as = field.AbsolutePosition, field.AbsoluteSize
		listFrame.Position = px(ap.X - rp.X, ap.Y - rp.Y + as.Y + 1)
		listFrame.Size = px(as.X, math.max(1, math.min(#values, 8)) * 16)
		listFrame.Visible = true
		open = true
		Library:_openPopup(popup)
	end)
	connect(field.MouseEnter, function() ag.Color = seq(G.ComboHover) end)
	connect(field.MouseLeave, function() if not open then ag.Color = seq(G.ComboBtn) end end)

	function D:SetValues(newValues)
		values = newValues
		D.Values = newValues
		if open then rebuild() end
		fieldText.Text = display()
	end

	if multi then
		local init = {}
		for _, v in ipairs(o.Default or {}) do init[v] = true end
		apply(init, false)
	else
		apply(o.Default == nil and values[1] or o.Default, false)
	end
	Library:_tooltip(field, o.Tooltip)
	Library.Options[flag] = D
	return D
end

-- Keybind -----------------------------------------------------------------
-- o.Mode = "Toggle" (default, Callback(state) on each press) or "Hold" (Callback(true/false))
-- o.Changed(newKey) fires when the user rebinds it
function Group:AddKeybind(flag, o)
	o = o or {}
	local K = element({ Type = "Keybind", Value = o.Default, State = false })
	local mode = o.Mode or "Toggle"

	local row = new("Frame", { Parent = self._content, BackgroundTransparency = 1, Size = ud(1, 0, 0, 23), LayoutOrder = self:_next() })
	new("TextLabel", { Parent = row, Size = ud(1, -92, 1, 0), Text = o.Text or flag, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
	local b = xpButton(row, ud(1, -86, 0, 1), px(85, 21), "")

	local capturing = false
	local function apply(k, doFire)
		K.Value = k
		Library.Flags[flag] = k
		b.Text = keyName(k)
		if doFire then
			if o.Changed then task.spawn(o.Changed, k) end
			for _, f in ipairs(K._changed) do task.spawn(f, k) end
		end
	end
	function K:Set(k) apply(k, true) end

	local function matches(input)
		local k = K.Value
		if not k then return false end
		if k.EnumType == Enum.KeyCode then return input.KeyCode == k end
		return input.UserInputType == k
	end

	connect(b.MouseButton1Click, function()
		if capturing then return end
		capturing = true
		Library._binding = true
		b.Text = "..."
	end)

	connect(UIS.InputBegan, function(input, gp)
		if capturing then
			local k
			if input.UserInputType == Enum.UserInputType.Keyboard then
				if input.KeyCode ~= Enum.KeyCode.Escape and input.KeyCode ~= Enum.KeyCode.Backspace then
					k = input.KeyCode
				end
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.UserInputType == Enum.UserInputType.MouseButton3 then
				k = input.UserInputType
			else
				return
			end
			capturing = false
			task.defer(function() Library._binding = false end)
			apply(k, true)
			return
		end
		if gp or not matches(input) then return end
		if mode == "Hold" then
			K.State = true
		else
			K.State = not K.State
		end
		if o.Callback then task.spawn(o.Callback, K.State) end
	end)

	connect(UIS.InputEnded, function(input)
		if mode == "Hold" and K.State and matches(input) then
			K.State = false
			if o.Callback then task.spawn(o.Callback, false) end
		end
	end)

	apply(o.Default, false)
	Library:_tooltip(b, o.Tooltip)
	Library.Options[flag] = K
	return K
end

-- Text box ----------------------------------------------------------------
function Group:AddTextbox(flag, o)
	o = o or {}
	local X = element({ Type = "Textbox", Value = o.Default or "" })

	local row = new("Frame", { Parent = self._content, BackgroundTransparency = 1, Size = ud(1, 0, 0, 39), LayoutOrder = self:_next() })
	new("TextLabel", { Parent = row, Size = ud(1, 0, 0, 14), Text = o.Text or flag, TextXAlignment = Enum.TextXAlignment.Left })
	local field = new("Frame", { Parent = row, Position = px(1, 17), Size = ud(1, -2, 0, 21), BackgroundColor3 = Theme.White, stroke(Theme.FieldBorder) })
	local tb = new("TextBox", {
		Parent = field, Position = px(4, 0), Size = ud(1, -8, 1, 0), Text = X.Value,
		PlaceholderText = o.Placeholder or "", PlaceholderColor3 = Theme.TextDim,
		ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	})

	local function apply(v, doFire)
		X.Value = v
		Library.Flags[flag] = v
		tb.Text = v
		if doFire then fire(X, o.Callback, v) end
	end
	function X:Set(v) apply(v, true) end

	connect(tb.FocusLost, function(enter)
		if enter or not o.EnterOnly then apply(tb.Text, true) end
	end)

	apply(X.Value, false)
	Library:_tooltip(field, o.Tooltip)
	Library.Options[flag] = X
	return X
end

-- Static text / divider -----------------------------------------------------
function Group:AddLabel(text, o)
	o = o or {}
	local l = new("TextLabel", {
		Parent = self._content, Size = ud(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = self:_next(),
		Text = text, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = o.Color or Theme.Text, FontFace = o.Bold and FONT_BOLD or FONT,
	})
	return { Instance = l, Set = function(_, t) l.Text = t end }
end

function Group:AddDivider()
	local row = new("Frame", { Parent = self._content, BackgroundTransparency = 1, Size = ud(1, 0, 0, 6), LayoutOrder = self:_next() })
	box(row, px(0, 2), ud(1, 0, 0, 1), Theme.Etch)
	box(row, px(0, 3), ud(1, 0, 0, 1), Theme.White)
end

------------------------------------------------------------------------
-- Balloon notifications (tray-style)
------------------------------------------------------------------------
function Library:Notify(title, text, duration)
	if type(title) == "table" then
		title, text, duration = title.Title, title.Text, title.Duration
	end
	if not self._notifs then return end
	title, text, duration = title or "xpware", text or "", duration or 5

	local width = 262
	local textH = TextService:GetTextSize(text, 12, Enum.Font.Arial, Vector2.new(width - 26, 1000)).Y
	local bodyH = 8 + 16 + 4 + textH + 10

	local cg = new("CanvasGroup", {
		Parent = self._notifs, BackgroundTransparency = 1, Size = px(width, bodyH + 12),
		GroupTransparency = 1, LayoutOrder = math.floor(os.clock() * 1000) % 1e9,
	})
	local tx = width - 40
	new("Frame", { Parent = cg, AnchorPoint = Vector2.new(0.5, 0.5), Position = px(tx, bodyH + 1), Size = px(11, 11), Rotation = 45, BackgroundColor3 = Theme.Tooltip, stroke(Theme.Black) })
	local body = new("TextButton", { Parent = cg, Position = px(1, 1), Size = px(width - 2, bodyH), BackgroundTransparency = 0, BackgroundColor3 = Theme.Tooltip, corner(7), stroke(Theme.Black) })
	box(body, px(tx - 7, bodyH - 1), px(12, 2), Theme.Tooltip) -- hides the stroke where the tail joins

	local icon = new("Frame", { Parent = body, Position = px(8, 8), Size = px(16, 16), BackgroundColor3 = hex("FFFFFF"), corner(8), gradient({{0,"6FA8FF"},{0.5,"1F6FE8"},{1,"0E4FC0"}}) })
	new("TextLabel", { Parent = icon, Size = ud(1, 0, 1, 0), Text = "i", FontFace = FONT_BOLD, TextSize = 13, TextColor3 = Theme.White })
	new("TextLabel", { Parent = body, Position = px(30, 8), Size = ud(1, -60, 0, 16), Text = title, FontFace = FONT_BOLD, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
	new("TextLabel", { Parent = body, Position = px(10, 28), Size = ud(1, -20, 0, textH), Text = text, TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })

	local close = new("TextButton", { Parent = body, Position = ud(1, -22, 0, 7), Size = px(14, 14), BackgroundColor3 = Theme.White, BackgroundTransparency = 1, corner(2) })
	local cs = stroke(Theme.Etch); cs.Enabled = false; cs.Parent = close
	segment(close, 4, 4, 10, 10, 1.5, hex("4A4A4A"))
	segment(close, 10, 4, 4, 10, 1.5, hex("4A4A4A"))
	connect(close.MouseEnter, function() cs.Enabled = true; close.BackgroundTransparency = 0 end)
	connect(close.MouseLeave, function() cs.Enabled = false; close.BackgroundTransparency = 1 end)

	local gone = false
	local function dismiss()
		if gone then return end
		gone = true
		tween(cg, 0.25, { GroupTransparency = 1 }).Completed:Wait()
		cg:Destroy()
	end
	connect(close.MouseButton1Click, dismiss)
	connect(body.MouseButton1Click, dismiss)
	tween(cg, 0.2, { GroupTransparency = 0 })
	task.delay(duration, dismiss)
end

------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------
function Library:CreateWindow(opt)
	opt = opt or {}
	local lib = self
	local W = { Tabs = {} }

	local title = opt.Title or "xpware"
	local W0, H0 = 580, 440
	if typeof(opt.Size) == "Vector2" then W0, H0 = opt.Size.X, opt.Size.Y end
	if typeof(opt.Size) == "UDim2" then W0, H0 = opt.Size.X.Offset, opt.Size.Y.Offset end
	local MIN_W, MIN_H = 460, 320
	local tabsWidth = 0
	if opt.ToggleKey then self.ToggleKey = opt.ToggleKey end

	local gui = new("ScreenGui", {
		Name = HttpService:GenerateGUID(false):sub(1, 8), ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 9999,
	})
	mount(gui)
	self.Gui = gui

	local root = new("Frame", { Parent = gui, Name = "Root", BackgroundTransparency = 1, Size = ud(1, 0, 1, 0), ZIndex = 1 })
	local overlay = new("Frame", { Parent = gui, Name = "Overlay", BackgroundTransparency = 1, Size = ud(1, 0, 1, 0), ZIndex = 50 })
	self._root, self._overlay = root, overlay

	self._tip = new("TextLabel", {
		Parent = overlay, Visible = false, BackgroundTransparency = 0, BackgroundColor3 = Theme.Tooltip,
		AutomaticSize = Enum.AutomaticSize.XY, Size = px(0, 0), TextSize = 12, ZIndex = 20,
		stroke(Theme.Black), pad(2, 5, 2, 5),
	})

	self._notifs = new("Frame", {
		Parent = overlay, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1),
		Position = ud(1, -6, 1, -6), Size = px(264, 600), ZIndex = 10,
		new("UIListLayout", {
			Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalAlignment = Enum.HorizontalAlignment.Right,
		}),
	})

	--------------------------------------------------------------------
	-- frame + title bar
	--------------------------------------------------------------------
	-- centered by scale: the camera's ViewportSize is still 1x1 when an early script runs,
	-- so offset math from it lands the window off-screen. Dragging converts this to pure offset.
	local win = new("Frame", {
		Parent = root, Name = "Window", BackgroundTransparency = 1, Size = px(W0, H0),
		Position = ud(0.5, -math.floor(W0 / 2), 0.5, -math.floor(H0 / 2) - 20),
	})
	-- frees the mouse while the window is open (shift-lock / first person)
	new("TextButton", { Parent = win, Modal = true, BackgroundTransparency = 1, Size = px(1, 1) })

	local TITLE_H = 30
	local titleBar = new("Frame", {
		Parent = win, Name = "TitleBar", Size = ud(1, 0, 0, TITLE_H + 8), BackgroundColor3 = Theme.White,
		corner(8), gradient(scaled(G.Title, TITLE_H / (TITLE_H + 8))),
	})
	-- faint vertical sheen on the left edge, like Luna
	new("Frame", {
		Parent = titleBar, Size = px(6, TITLE_H), Position = px(0, 4), BackgroundColor3 = Theme.White, BackgroundTransparency = 0.85,
		new("UIGradient", { Transparency = NumberSequence.new(0, 1) }),
	})

	if opt.Icon then
		new("ImageLabel", { Parent = titleBar, Position = px(7, 7), Size = px(16, 16), BackgroundTransparency = 1, Image = opt.Icon, ZIndex = 2 })
	else
		logo(titleBar, 7, 7, 16, 2)
	end
	new("TextLabel", {
		Parent = titleBar, Position = px(29, 1), Size = ud(1, -110, 0, TITLE_H), Text = title, FontFace = FONT_BOLD,
		TextSize = 14, TextColor3 = hex("0A1883"), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 2,
	})
	new("TextLabel", {
		Parent = titleBar, Position = px(28, 0), Size = ud(1, -110, 0, TITLE_H), Text = title, FontFace = FONT_BOLD,
		TextSize = 14, TextColor3 = Theme.White, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3,
	})

	local captionHovers = {}
	local function captionButton(parent, xRight, isClose)
		local b = new("TextButton", {
			Parent = parent, Position = ud(1, xRight, 0, 5), Size = px(21, 21), BackgroundColor3 = Theme.White, BackgroundTransparency = 0, ZIndex = 4,
			corner(3), stroke(Theme.White), gradient(isClose and G.CaptionClose or G.Caption, 45),
		})
		local shade = new("Frame", { Parent = b, Size = ud(1, 0, 1, 0), BackgroundColor3 = Theme.White, BackgroundTransparency = 1, corner(3) })
		local glyph = new("Frame", { Parent = b, BackgroundTransparency = 1, Size = ud(1, 0, 1, 0), ZIndex = 2 })
		connect(b.MouseEnter, function() shade.BackgroundColor3 = Theme.White; tween(shade, 0.1, { BackgroundTransparency = 0.72 }) end)
		connect(b.MouseLeave, function() tween(shade, 0.1, { BackgroundTransparency = 1 }) end)
		connect(b.MouseButton1Down, function() shade.BackgroundColor3 = Theme.Black; shade.BackgroundTransparency = 0.78 end)
		connect(b.MouseButton1Up, function() shade.BackgroundColor3 = Theme.White; shade.BackgroundTransparency = 0.72 end)
		table.insert(captionHovers, hoverable(b))
		return b, glyph
	end

	local closeBtn, closeGlyph = captionButton(titleBar, -26, true)
	segment(closeGlyph, 6, 6, 15, 15, 2, Theme.White, 2)
	segment(closeGlyph, 15, 6, 6, 15, 2, Theme.White, 2)

	local maxBtn, maxGlyph = captionButton(titleBar, -49)
	local maxIcon = new("Frame", { Parent = maxGlyph, BackgroundTransparency = 1, Size = ud(1, 0, 1, 0) })
	box(maxIcon, px(5, 5), px(11, 3), Theme.White)
	box(maxIcon, px(5, 5), px(1, 11), Theme.White)
	box(maxIcon, px(15, 5), px(1, 11), Theme.White)
	box(maxIcon, px(5, 15), px(11, 1), Theme.White)
	local restoreIcon = new("Frame", { Parent = maxGlyph, BackgroundTransparency = 1, Size = ud(1, 0, 1, 0), Visible = false })
	box(restoreIcon, px(7, 4), px(9, 2), Theme.White)
	box(restoreIcon, px(15, 4), px(1, 8), Theme.White)
	box(restoreIcon, px(7, 4), px(1, 4), Theme.White)
	box(restoreIcon, px(12, 11), px(4, 1), Theme.White)
	box(restoreIcon, px(4, 8), px(8, 2), Theme.White)
	box(restoreIcon, px(4, 8), px(1, 8), Theme.White)
	box(restoreIcon, px(11, 8), px(1, 8), Theme.White)
	box(restoreIcon, px(4, 15), px(8, 1), Theme.White)

	local minBtn, minGlyph = captionButton(titleBar, -72)
	box(minGlyph, px(5, 13), px(7, 3), Theme.White)

	--------------------------------------------------------------------
	-- body: 3px blue frame around the beige face
	--------------------------------------------------------------------
	local body = new("Frame", { Parent = win, Name = "Body", BackgroundTransparency = 1, Position = px(0, TITLE_H), Size = ud(1, 0, 1, -TITLE_H) })
	local face = new("Frame", { Parent = body, Name = "Face", Position = px(3, 0), Size = ud(1, -6, 1, -3), BackgroundColor3 = Theme.Face })
	local leftCols, rightCols = { "0831D9", "166AEE", "0855DD" }, { "00138C", "001EA0", "003BDA" }
	for i = 1, 3 do
		box(body, ud(0, i - 1, 0, 0), ud(0, 1, 1, 0), hex(leftCols[i]))
		box(body, ud(1, -i, 0, 0), ud(0, 1, 1, 0), hex(rightCols[i]))
	end
	for i = 1, 3 do
		box(body, ud(0, i - 1, 1, -i), ud(1, -(i - 1) * 2, 0, 1), hex(rightCols[i]))
	end

	--------------------------------------------------------------------
	-- status bar + size grip
	--------------------------------------------------------------------
	local STATUS_H = 22
	local status = new("Frame", { Parent = face, Position = ud(0, 0, 1, -STATUS_H), Size = ud(1, 0, 0, STATUS_H), BackgroundColor3 = Theme.Face })
	local statusText = new("TextLabel", { Parent = status, Position = px(6, 0), Size = ud(1, -150, 1, 0), Text = opt.Status or "Ready", TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left })
	box(status, ud(1, -140, 0, 3), px(1, 16), Theme.Etch)
	box(status, ud(1, -139, 0, 3), px(1, 16), Theme.White)
	local hintText = new("TextLabel", { Parent = status, Position = ud(1, -134, 0, 0), Size = px(116, STATUS_H), TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left })

	local grip = new("TextButton", { Parent = status, AnchorPoint = Vector2.new(1, 1), Position = ud(1, -1, 1, -1), Size = px(13, 13), ZIndex = 3 })
	for _, d in ipairs({ { 9, 1 }, { 5, 5 }, { 9, 5 }, { 1, 9 }, { 5, 9 }, { 9, 9 } }) do
		box(grip, px(d[1] + 1, d[2] + 1), px(2, 2), Theme.White)
		box(grip, px(d[1], d[2]), px(2, 2), hex("B9B6A6"))
	end

	function W:SetStatus(t) statusText.Text = t end
	function lib:_updateHint() hintText.Text = keyName(lib.ToggleKey) .. " = hide" end
	lib:_updateHint()

	--------------------------------------------------------------------
	-- tab strip + panel
	--------------------------------------------------------------------
	local strip = new("Frame", {
		Parent = face, Name = "Tabs", BackgroundTransparency = 1, Position = px(8, 6), Size = ud(1, -16, 0, 22), ZIndex = 3,
		list(Enum.FillDirection.Horizontal, 0),
	})
	local panel = new("Frame", {
		Parent = face, Name = "Panel", Position = px(6, 27), Size = ud(1, -12, 1, -27 - STATUS_H - 4),
		BackgroundColor3 = Theme.White, ZIndex = 2, gradient(G.Panel),
	})
	box(panel, px(0, 0), ud(1, 0, 0, 1), Theme.PanelBorder)
	box(panel, ud(0, 0, 1, -1), ud(1, 0, 0, 1), Theme.PanelBorder)
	box(panel, px(0, 0), ud(0, 1, 1, 0), Theme.PanelBorder)
	box(panel, ud(1, -1, 0, 0), ud(0, 1, 1, 0), Theme.PanelBorder)
	box(panel, ud(1, -2, 0, 1), ud(0, 1, 1, -2), hex("D6D3CE"))
	box(panel, ud(0, 1, 1, -2), ud(1, -2, 0, 1), hex("D6D3CE"))
	local pages = new("Frame", { Parent = panel, BackgroundTransparency = 1, Position = px(1, 1), Size = ud(1, -3, 1, -3) })

	--------------------------------------------------------------------
	-- compact bar: X and minimize shrink the window into this
	--------------------------------------------------------------------
	local MINI_W = math.clamp(textWidth(title, 14, true) + 74, 170, 280)
	local mini = new("Frame", {
		Parent = root, Name = "Mini", Visible = false, Size = px(MINI_W, TITLE_H),
		BackgroundColor3 = Theme.White, corner(8), stroke(hex("0831D9")), gradient(G.Title),
	})
	-- drag handle / click-to-open area (everything but the restore button)
	local miniHit = new("TextButton", { Parent = mini, Size = ud(1, -30, 1, 0), ZIndex = 5 })
	if opt.Icon then
		new("ImageLabel", { Parent = mini, Position = px(7, 7), Size = px(16, 16), BackgroundTransparency = 1, Image = opt.Icon, ZIndex = 2 })
	else
		logo(mini, 7, 7, 16, 2)
	end
	new("TextLabel", {
		Parent = mini, Position = px(29, 1), Size = ud(1, -60, 1, 0), Text = title, FontFace = FONT_BOLD,
		TextSize = 14, TextColor3 = hex("0A1883"), TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 2,
	})
	new("TextLabel", {
		Parent = mini, Position = px(28, 0), Size = ud(1, -60, 1, 0), Text = title, FontFace = FONT_BOLD,
		TextSize = 14, TextColor3 = Theme.White, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3,
	})
	local miniBtn, miniGlyph = captionButton(mini, -26)
	box(miniGlyph, px(5, 5), px(11, 3), Theme.White)
	box(miniGlyph, px(5, 5), px(1, 11), Theme.White)
	box(miniGlyph, px(15, 5), px(1, 11), Theme.White)
	box(miniGlyph, px(5, 15), px(11, 1), Theme.White)

	--------------------------------------------------------------------
	-- window state: compact / maximize / hide
	--------------------------------------------------------------------
	local minimized, maximized = false, false
	local normalPos, normalSize

	local function relPos(gui)
		local rel = gui.AbsolutePosition - root.AbsolutePosition
		return px(rel.X, rel.Y)
	end

	local function refresh()
		win.Visible = lib.Toggled and not minimized
		mini.Visible = lib.Toggled and minimized
	end

	-- the bar takes the window's place, and the window comes back wherever the bar was left
	function W:Minimize()
		if minimized then return end
		lib:_closePopups()
		if lib._tip then lib._tip.Visible = false end
		mini.Position = relPos(win)
		minimized = true
		refresh()
	end
	function W:Restore()
		if not minimized then return end
		if not maximized then win.Position = relPos(mini) end
		minimized = false
		refresh()
	end
	function W:ToggleMaximize()
		if maximized then
			win.Position, win.Size = normalPos, normalSize
			maximized = false
		else
			normalPos, normalSize = win.Position, win.Size
			win.Position = px(0, 0)
			win.Size = px(root.AbsoluteSize.X, root.AbsoluteSize.Y)
			maximized = true
		end
		maxIcon.Visible = not maximized
		restoreIcon.Visible = maximized
	end

	function lib:Toggle(state)
		if state == nil then state = not self.Toggled end
		self.Toggled = state
		self:_closePopups()
		if self._tip then self._tip.Visible = false end
		refresh()
	end

	local warnedClose = false
	connect(closeBtn.MouseButton1Click, function()
		W:Minimize()
		if not warnedClose then
			warnedClose = true
			lib:Notify(title, "Still running. Click the bar to open it again, or use Unload to stop it.", 6)
		end
	end)
	connect(minBtn.MouseButton1Click, function() W:Minimize() end)
	connect(maxBtn.MouseButton1Click, function() W:ToggleMaximize() end)
	connect(miniBtn.MouseButton1Click, function() W:Restore() end)

	--------------------------------------------------------------------
	-- dragging + resizing
	--------------------------------------------------------------------
	local dragging, resizing = false, false
	local miniDrag, miniMoved = false, false
	local dragStart, startPos, startSize
	local lastClick = 0

	-- the compact bar: drag it around, or click without dragging to open the window
	connect(miniHit.InputBegan, function(input)
		if not isPress(input) then return end
		miniDrag, miniMoved = true, false
		dragStart, startPos = input.Position, relPos(mini)
	end)

	connect(titleBar.InputBegan, function(input)
		if not isPress(input) then return end
		for _, h in ipairs(captionHovers) do
			if h.hovered then return end
		end
		local now = os.clock()
		if now - lastClick < 0.3 then
			lastClick = 0
			W:ToggleMaximize()
			return
		end
		lastClick = now
		if maximized then return end
		dragging = true
		local rel = win.AbsolutePosition - root.AbsolutePosition
		dragStart, startPos = input.Position, px(rel.X, rel.Y)
	end)
	connect(grip.InputBegan, function(input)
		if isPress(input) and not maximized then
			resizing = true
			dragStart, startSize = input.Position, win.AbsoluteSize
		end
	end)
	connect(UIS.InputChanged, function(input)
		if not isMove(input) then return end
		if dragging then
			local d = input.Position - dragStart
			local s = root.AbsoluteSize
			-- keep the title bar out from under Roblox's own topbar buttons
			local topInset = GuiService:GetGuiInset().Y
			local x = math.clamp(startPos.X.Offset + d.X, -win.AbsoluteSize.X + 100, s.X - 100)
			local y = math.clamp(startPos.Y.Offset + d.Y, topInset, math.max(topInset, s.Y - TITLE_H))
			win.Position = px(x, y)
		elseif resizing then
			local d = input.Position - dragStart
			win.Size = px(math.max(MIN_W, startSize.X + d.X), math.max(MIN_H, startSize.Y + d.Y))
		elseif miniDrag then
			local d = input.Position - dragStart
			if d.Magnitude > 4 then miniMoved = true end
			if miniMoved then
				local s = root.AbsoluteSize
				local topInset = GuiService:GetGuiInset().Y
				local x = math.clamp(startPos.X.Offset + d.X, 0, math.max(0, s.X - mini.AbsoluteSize.X))
				local y = math.clamp(startPos.Y.Offset + d.Y, topInset, math.max(topInset, s.Y - TITLE_H))
				mini.Position = px(x, y)
			end
		end
	end)
	connect(UIS.InputEnded, function(input)
		if not isPress(input) then return end
		if miniDrag and not miniMoved then W:Restore() end
		dragging, resizing, miniDrag = false, false, false
	end)

	-- click-outside closes popups, toggle key hides everything
	connect(UIS.InputBegan, function(input, gp)
		if isPress(input) then
			for i = #lib._popups, 1, -1 do
				local p = lib._popups[i]
				if not p.hovered() then
					p.close()
					table.remove(lib._popups, i)
				end
			end
		end
		if not gp and not lib._binding and input.KeyCode == lib.ToggleKey then
			lib:Toggle()
		end
	end)

	--------------------------------------------------------------------
	-- tabs
	--------------------------------------------------------------------
	function W:AddTab(name)
		local tab = { Name = name }
		local index = #W.Tabs + 1

		local slotW = textWidth(name) + 14
		local slot = new("Frame", { Parent = strip, BackgroundTransparency = 1, Size = px(slotW, 22), LayoutOrder = index })

		-- the window can never be narrower than its tab strip (16 strip inset + 6 frame + 4 spare)
		tabsWidth += slotW
		MIN_W = math.max(MIN_W, tabsWidth + 26)
		if win.Size.X.Offset < MIN_W then
			win.Size = px(MIN_W, win.Size.Y.Offset)
			if win.Position.X.Scale == 0.5 then
				win.Position = ud(0.5, -math.floor(MIN_W / 2), win.Position.Y.Scale, win.Position.Y.Offset)
			end
		end
		local btn = new("TextButton", { Parent = slot, Position = px(0, 2), Size = ud(1, 0, 0, 19) })
		local bg = new("Frame", { Parent = btn, Position = px(1, 1), Size = ud(1, -2, 1, -1), BackgroundColor3 = Theme.White })
		local bgGrad = gradient(G.TabIdle); bgGrad.Parent = bg
		box(btn, px(2, 0), ud(1, -4, 0, 1), Theme.PanelBorder)
		box(btn, px(0, 2), ud(0, 1, 1, -2), Theme.PanelBorder)
		box(btn, ud(1, -1, 0, 2), ud(0, 1, 1, -2), Theme.PanelBorder)
		box(btn, px(1, 1), px(1, 1), Theme.PanelBorder)
		box(btn, ud(1, -2, 0, 1), px(1, 1), Theme.PanelBorder)
		local hl = new("Frame", { Parent = btn, BackgroundTransparency = 1, Size = ud(1, 0, 0, 3), Visible = false })
		box(hl, px(2, 0), ud(1, -4, 0, 1), Theme.TabTop)
		box(hl, px(1, 1), ud(1, -2, 0, 2), Theme.TabTopLight)
		new("TextLabel", { Parent = btn, Position = px(0, 1), Size = ud(1, 0, 1, 0), Text = name })

		local page = new("Frame", { Parent = pages, BackgroundTransparency = 1, Size = ud(1, 0, 1, 0), Visible = false })
		local function column(isLeft)
			local col = new("ScrollingFrame", {
				Parent = page, BackgroundTransparency = 1,
				Position = isLeft and px(0, 0) or ud(0.5, 0, 0, 0), Size = ud(0.5, 0, 1, 0),
				CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y,
				ScrollBarThickness = 4, ScrollBarImageColor3 = hex("A9B8D9"), VerticalScrollBarInset = Enum.ScrollBarInset.Always,
				pad(14, isLeft and 6 or 12, 10, isLeft and 12 or 6), list(Enum.FillDirection.Vertical, 18),
			})
			connect(col:GetPropertyChangedSignal("CanvasPosition"), function() lib:_closePopups() end)
			return col
		end
		tab._left, tab._right = column(true), column(false)

		local active = false
		function tab:_setActive(on)
			active = on
			page.Visible = on
			slot.ZIndex = on and 2 or 1
			hl.Visible = on
			if on then
				btn.Position, btn.Size = px(-2, 0), ud(1, 4, 0, 22)
				bgGrad.Enabled = false
				bg.BackgroundColor3 = Theme.Panel
			else
				btn.Position, btn.Size = px(0, 2), ud(1, 0, 0, 19)
				bgGrad.Enabled = true
				bg.BackgroundColor3 = Theme.White
			end
		end
		function tab:Select()
			for _, t in ipairs(W.Tabs) do t:_setActive(t == tab) end
			lib:_closePopups()
		end
		connect(btn.MouseButton1Click, function() tab:Select() end)
		connect(btn.MouseEnter, function() if not active then hl.Visible = true end end)
		connect(btn.MouseLeave, function() if not active then hl.Visible = false end end)

		function tab:AddGroup(gname, side)
			local col = (side == "Right") and tab._right or tab._left
			local frame = new("Frame", {
				Parent = col, BackgroundTransparency = 1, Size = ud(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = #col:GetChildren(), corner(3), stroke(Theme.GroupBorder),
			})
			new("TextLabel", {
				Parent = frame, Position = px(7, -8), Size = px(textWidth(gname) + 6, 15), Text = gname,
				TextColor3 = Theme.GroupText, BackgroundTransparency = 0, BackgroundColor3 = Theme.PanelMid, ZIndex = 2,
			})
			local content = new("Frame", {
				Parent = frame, BackgroundTransparency = 1, Size = ud(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				pad(14, 10, 10, 10), list(Enum.FillDirection.Vertical, 7),
			})
			return setmetatable({ _content = content, _order = 0 }, Group)
		end

		table.insert(W.Tabs, tab)
		if index == 1 then tab:Select() end
		return tab
	end

	refresh()
	return W
end

------------------------------------------------------------------------
function Library:OnUnload(fn) table.insert(self._onUnload, fn) end

function Library:Unload()
	if self.Unloaded then return end
	self.Unloaded = true
	for _, fn in ipairs(self._onUnload) do pcall(fn) end
	for _, c in ipairs(self._conns) do pcall(function() c:Disconnect() end) end
	self._conns = {}
	if self.Gui then self.Gui:Destroy() end
	if env.__xpui == self then env.__xpui = nil end
end

return Library
