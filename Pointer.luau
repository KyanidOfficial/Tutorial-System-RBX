--[[
This pointer system is used by my open-sourced tutorial system. It shows the player what the current
tutorial step wants them to look at. A bouncing arrow and a pulsing highlight box frame the target,
which can be any GUI element, a part in the workspace, or a tool in the hotbar.
When a world target is off-screen, the arrow moves to the edge of the screen
and points toward it. The position is recalculated every frame so it keeps up with the camera.
--]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Settings = require(script.Parent.Parent.Config).Settings
local Caption = require(script.Parent.Caption)
local Targets = require(script.Parent.Targets)

-- Roblox doesn't expose the default hotbar's slot positions, so these mirror its layout
local HOTBAR_SLOT = 60
local HOTBAR_GAP = 5
local OFFSCREEN_HOLE = 100

local Pointer = {}

local player = Players.LocalPlayer
local container: Frame
local highlight: Frame
local arrow: Frame
local arrowImage: ImageLabel
local arrowScale: UIScale
local shownAt = 0
local outStroke: UIStroke?
local inStroke: UIStroke?
local backupOverlay: GuiObject?
local outDefault = true
local inDefault = true

local function useBackupOverlay(active: boolean) -- When the highlight is pushed off-screen the stroke that I've put on it doesn't show on the screen, so I created a backup frame overlay that takes over
	if outStroke then
		outStroke.Enabled = not active and outDefault
	end
	if inStroke then
		inStroke.Enabled = not active and inDefault
	end
	if backupOverlay then
		backupOverlay.Visible = active
	end
end

local function backOut(alpha: number): number -- "Back out" easing: overshoots past 1 and settles back for a springy pop. 1.70158 gives about a 10% overshoot
	local overshoot = 1.70158
	local shifted = alpha - 1
	return 1 + (overshoot + 1) * shifted ^ 3 + overshoot * shifted ^ 2
end

local function hopPhase(): number -- Shared by the bob and the squash/stretch so both stay in sync
	return os.clock() * Settings.ArrowBobSpeed * 0.5
end

local function bobOffset(): number -- abs(sin) makes the arrow bounce off a floor instead of sinking into the target
	return math.abs(math.sin(hopPhase())) * Settings.ArrowBobHeight
end

local function wiggle(): number
	return math.sin(os.clock() * 2.7) * Settings.ArrowWiggle
end

local function animateArrow()
	local now = os.clock()
	-- Speed follows cos (the derivative of sin), so the arrow is fastest leaving the floor and slowest at the top
	local height = math.abs(math.sin(hopPhase()))
	local speed = math.abs(math.cos(hopPhase()))
	-- Squash only near the floor, and stretch is scaled by (1 - squash) so the two never fight
	local squash = math.max(0, 1 - height / 0.22)
	local stretch = speed * (1 - squash) * 0.14

	arrowImage.Size = UDim2.fromScale(1 + squash * 0.28 - stretch * 0.5, 1 - squash * 0.22 + stretch)
	arrowImage.ImageColor3 = Color3.new(1, 1, 1):Lerp(Settings.ArrowGlowColor, (math.sin(now * 4) + 1) / 2 * 0.45)

	local age = now - shownAt
	if age < Settings.ArrowPopTime then
		arrowScale.Scale = math.max(0, backOut(age / Settings.ArrowPopTime)) -- backOut can dip below 0 at the start, clamping avoids a flipped scale
	else
		arrowScale.Scale = 1
	end
end

local function spinIn(): number -- (1 - alpha)^3 eases out, so the arrow starts with a fast full spin that slows to a stop
	local age = os.clock() - shownAt
	if age >= Settings.ArrowPopTime then
		return 0
	end
	local alpha = age / Settings.ArrowPopTime
	return -360 * (1 - alpha) ^ 3
end

local function breathe(): number
	return (math.sin(os.clock() * 4) + 1) * 2
end

local function guiRect(object: GuiObject): Rect -- The arrow and highlight live inside the container, so absolute positions are made relative to it
	local origin = container.AbsolutePosition
	local position = object.AbsolutePosition - origin
	return Rect.new(position, position + object.AbsoluteSize)
end

local function hide()
	highlight.Visible = false
	arrow.Visible = false
	useBackupOverlay(false)
end

local function placeOver(rect: Rect, boxed: boolean) -- Places the arrow above a screen rect, "boxed" also draws the highlight around it
	local padding = boxed and Settings.HighlightPadding or 0
	local center = (rect.Min + rect.Max) / 2

	highlight.Visible = boxed
	useBackupOverlay(false)
	if boxed then
		local pulse = breathe()
		highlight.Position = UDim2.fromOffset(center.X, center.Y)
		highlight.Size = UDim2.fromOffset(rect.Width + (padding + pulse) * 2, rect.Height + (padding + pulse) * 2)
	end

	animateArrow()
	arrow.Visible = true
	arrow.Rotation = wiggle() + spinIn()
	arrow.Position = UDim2.fromOffset(center.X, rect.Min.Y - padding - arrow.Size.Y.Offset / 2 - 4 - bobOffset())
end

local function placeAtEdge(worldPosition: Vector3) -- Pins the arrow to the screen edge in the direction of an off-screen target
	local camera = Workspace.CurrentCamera
	local viewport = camera.ViewportSize
	local inset = GuiService:GetGuiInset()
	local point = camera:WorldToViewportPoint(worldPosition)
	local center = viewport / 2
	local direction = Vector2.new(point.X, point.Y) - center

	-- Points behind the camera project mirrored, so the direction is flipped back
	if point.Z < 0 then
		direction = -direction
	end
	if direction.Magnitude < 1e-3 then
		direction = Vector2.new(0, 1)
	end

	-- Scale the direction until it hits the nearest screen margin
	local limit = center - Vector2.new(Settings.EdgeMargin, Settings.EdgeMargin)
	local scaleX = direction.X ~= 0 and limit.X / math.abs(direction.X) or math.huge
	local scaleY = direction.Y ~= 0 and limit.Y / math.abs(direction.Y) or math.huge
	local edge = center + direction * math.min(scaleX, scaleY)
	local position = edge - direction.Unit * bobOffset() - inset
	local hole = edge + direction.Unit * (Settings.EdgeMargin + OFFSCREEN_HOLE * 2) - inset

	highlight.Visible = true
	useBackupOverlay(true)
	highlight.Position = UDim2.fromOffset(hole.X, hole.Y)
	highlight.Size = UDim2.fromOffset(OFFSCREEN_HOLE, OFFSCREEN_HOLE)
	animateArrow()
	arrow.Visible = true
	arrow.Rotation = math.deg(math.atan2(direction.Y, direction.X)) - 90 + wiggle() * 0.5 + spinIn() -- -90 because the arrow image points up by default
	arrow.Position = UDim2.fromOffset(position.X, position.Y)
end

local function projectPart(target: Instance): Rect? -- Projects a 3D target into a screen rect, returns nil if it can't be boxed properly
	local camera = Workspace.CurrentCamera
	local inset = GuiService:GetGuiInset()
	local viewport = camera.ViewportSize - inset
	local cframe, size = Targets.Bounds(target)
	local half = size / 2
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge

	for x = -1, 1, 2 do -- Visits all 8 corners of the bounding box and keeps the min/max on screen
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local point = camera:WorldToViewportPoint(cframe * Vector3.new(half.X * x, half.Y * y, half.Z * z))
				if point.Z <= 0 then -- A corner behind the camera projects mirrored and would break the rect
					return nil
				end
				minX = math.min(minX, point.X - inset.X)
				minY = math.min(minY, point.Y - inset.Y)
				maxX = math.max(maxX, point.X - inset.X)
				maxY = math.max(maxY, point.Y - inset.Y)
			end
		end
	end

	-- Only the center is checked so a partly cut off part still gets boxed
	local centerX, centerY = (minX + maxX) / 2, (minY + maxY) / 2
	if centerX < 0 or centerX > viewport.X or centerY < 0 or centerY > viewport.Y then
		return nil
	end
	return Rect.new(minX, minY, maxX, maxY)
end

local function hotbarRect(toolName: string): Rect? -- Rebuilds a tool's hotbar slot rect, since the default backpack is a CoreGui and can't be read
	-- The equipped tool is parented to the character but still has a slot, so both are collected
	local tools = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in backpack:GetChildren() do
			if child:IsA("Tool") then
				table.insert(tools, child)
			end
		end
	end
	if player.Character then
		for _, child in player.Character:GetChildren() do
			if child:IsA("Tool") then
				table.insert(tools, child)
			end
		end
	end

	local index = table.find(tools, Targets.FindTool(toolName))
	if not index then
		return nil
	end

	local camera = Workspace.CurrentCamera
	local inset = GuiService:GetGuiInset()
	local slot = camera.ViewportSize.Y < 500 and 40 or HOTBAR_SLOT
	local width = #tools * slot + (#tools - 1) * HOTBAR_GAP
	local left = camera.ViewportSize.X / 2 - width / 2 + (index - 1) * (slot + HOTBAR_GAP)
	local bottom = camera.ViewportSize.Y - inset.Y - HOTBAR_GAP
	return Rect.new(left, bottom - slot, left + slot, bottom)
end

local function buildUpdater(step): () -> () -- Picks the per-frame function once per step instead of checking the step kind every frame
	if step.Kind == "Text" then
		local holder = Caption.GetHolder()
		return function()
			placeOver(guiRect(holder), false)
		end
	elseif step.Kind == "Gui" then
		local object = step.Instance :: GuiObject
		return function()
			-- A zero size means the GUI isn't rendered yet
			if object.AbsoluteSize.Magnitude > 0 then
				placeOver(guiRect(object), true)
			else
				hide()
			end
		end
	elseif step.Kind == "World" then
		local target = step.Instance
		return function()
			local rect = projectPart(target)
			if rect then
				placeOver(rect, true)
			else
				placeAtEdge(Targets.Position(target))
			end
		end
	end
	return function()
		local rect = hotbarRect(step.Tool)
		if rect then
			placeOver(rect, true)
		else
			hide()
		end
	end
end

function Pointer.Init(root: Frame)
	container = root
	highlight = root:WaitForChild("Highlight") :: Frame
	arrow = root:WaitForChild("Arrow") :: Frame
	arrowImage = arrow:WaitForChild("ImageLabel") :: ImageLabel
	-- Bottom anchor keeps the arrow's tip in place while it squashes and stretches
	arrowImage.AnchorPoint = Vector2.new(0.5, 1)
	arrowImage.Position = UDim2.fromScale(0.5, 1)
	-- UIScale for the pop-in so it doesn't conflict with the squash/stretch driving Size
	arrowScale = arrow:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	arrowScale.Parent = arrow
	outStroke = highlight:FindFirstChild("Out") :: UIStroke?
	inStroke = highlight:FindFirstChild("In") :: UIStroke?
	backupOverlay = highlight:FindFirstChild("BackupOverlay") :: GuiObject?
	outDefault = if outStroke then outStroke.Enabled else true
	inDefault = if inStroke then inStroke.Enabled else true
	hide()
end

function Pointer.Track(trove, step) -- The step's trove owns the loop and the hide, so cleaning it stops and hides the pointer in one go
	local update = buildUpdater(step)
	shownAt = os.clock()
	update() -- Run once right away so the pointer doesn't flash at its old position
	trove:Connect(RunService.RenderStepped, update)
	trove:Add(hide)
end

return Pointer
