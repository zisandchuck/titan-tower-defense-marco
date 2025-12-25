-- Titan TD Macro · 超级稳定回放版 v4.8 完全修复版
-- 🔥 修复：每个塔使用自己的 UpgradeRem，不再只升级塔1

-- ===== Services =====
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Http = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local UIS = game:GetService("UserInputService")

local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

-- ===== UI Framework =====
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()
local function notify(t, c)
	Rayfield:Notify({ Title = t, Content = c, Duration = 3 })
end

-- ===== Encode / Decode =====
local function encode(v)
	if typeof(v) == "Vector3" then
		return { __type = "Vector3", x = v.X, y = v.Y, z = v.Z }
	end
	return v
end
local function decode(v)
	if type(v) == "table" and v.__type == "Vector3" then
		return Vector3.new(v.x, v.y, v.z)
	end
	return v
end
local function encodeArgs(args)
	local t = {}
	for i, v in ipairs(args) do t[i] = encode(v) end
	return t
end
local function decodeArgs(args)
	local t = {}
	for i, v in ipairs(args) do t[i] = decode(v) end
	return t
end

-- ===== File =====
local FILE = "td_macro.json"

-- ===== State =====
local state = {
	recording = false,
	playing = false,
	macro = {},
	start = 0,

	towerIndex = 1,
	towerById = {},
	idByTower = {},
	pendingQueue = {},
	upgradeCount = {},
	towerNames = {},
	towerTimestamps = {},
	towerPositions = {},
	
	selectedTowerId = nil,
	strictMode = true,
	debugMode = false,
}

local StatusLabel = nil

-- ===== Helpers =====
local function getTableKeys(t)
	local keys = {}
	for k in pairs(t) do table.insert(keys, k) end
	return keys
end

local function waitForWave()
	while true do
		task.wait(0.25)
		for _, v in ipairs(PlayerGui:GetDescendants()) do
			if v:IsA("TextLabel") and v.Text and v.Text:lower():find("wave") then
				return true
			end
		end
	end
end

local function findRemote(name, waitSec)
	local function scan(root)
		for _, v in ipairs(root:GetDescendants()) do
			if (v:IsA("RemoteEvent") or v:IsA("RemoteFunction")) and v.Name == name then
				return v
			end
		end
	end

	local r = scan(RS) or scan(game)
	if r then return r end

	waitSec = waitSec or 0
	local t0 = tick()
	while tick() - t0 < waitSec do
		task.wait(0.25)
		r = scan(RS) or scan(game)
		if r then return r end
	end
	return nil
end

-- 🔥 新增：从塔模型内部找到它自己的 UpgradeRem
local function findTowerUpgradeRemote(towerModel)
	if not towerModel then return nil end
	
	-- 方法1: 直接在塔模型下找 UpgradeRem
	local upgradeRem = towerModel:FindFirstChild("UpgradeRem", true)
	if upgradeRem and (upgradeRem:IsA("RemoteEvent") or upgradeRem:IsA("RemoteFunction")) then
		return upgradeRem
	end
	
	-- 方法2: 查找包含 "Upgrade" 的 Remote
	for _, child in ipairs(towerModel:GetDescendants()) do
		if (child:IsA("RemoteEvent") or child:IsA("RemoteFunction")) and child.Name:find("Upgrade") then
			return child
		end
	end
	
	-- 方法3: 查找常见的塔升级路径
	local possiblePaths = {
		towerModel:FindFirstChild("UpgradeRem"),
		towerModel:FindFirstChild("Upgrade"),
		towerModel:FindFirstChild("TowerUpgrade"),
		towerModel:FindFirstChild("Remotes") and towerModel.Remotes:FindFirstChild("UpgradeRem"),
		towerModel:FindFirstChild("Remotes") and towerModel.Remotes:FindFirstChild("Upgrade"),
	}
	
	for _, remote in ipairs(possiblePaths) do
		if remote and (remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction")) then
			return remote
		end
	end
	
	return nil
end

-- ===== 获取塔的显示名称 =====
local function getTowerDisplayName(model)
	if not model then return "Unknown" end
	
	local nameValue = model:FindFirstChild("TowerName") or model:FindFirstChild("Name")
	if nameValue and nameValue:IsA("StringValue") then
		return nameValue.Value
	end
	
	return model.Name or "Unknown"
end

-- ===== 获取塔的位置 =====
local function getTowerPosition(model)
	if not model then return nil end
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	return primary and primary.Position or nil
end

-- ===== 更新UI显示选中的塔 =====
local function updateStatusLabel()
	if StatusLabel then
		if state.selectedTowerId then
			local towerModel = state.towerById[state.selectedTowerId]
			if towerModel then
				local towerName = state.towerNames[state.selectedTowerId] or "Unknown"
				local upgradeCount = state.upgradeCount[state.selectedTowerId] or 0
				local text = "Selected: ID=" .. state.selectedTowerId .. " (" .. towerName .. ") | Upgrades: " .. upgradeCount
				StatusLabel:Set(text)
			else
				local text = "Selected: ID=" .. state.selectedTowerId .. " (Waiting for bind)"
				StatusLabel:Set(text)
			end
		else
			StatusLabel:Set("No tower selected | Click tower to select")
		end
	end
end

-- ===== Tower Binding =====
local seenModels = {}

local function isTowerModel(m)
	if not m or not m:IsA("Model") then return false end
	
	if not m:FindFirstChildWhichIsA("BasePart", true) then return false end
	
	local level = m:FindFirstChild("Level", true)
	if level and level:IsA("IntValue") then return true end
	
	local parent = m.Parent
	if parent and (parent.Name == "Towers" or parent.Name == "Tower") then return true end
	
	return false
end

local function waitForSpecificTowerBind(targetId, maxWait)
	targetId = tostring(targetId)
	maxWait = maxWait or 5
	local waited = 0
	
	print("[Wait] Waiting for tower ID=" .. targetId .. " to bind...")
	
	while not state.towerById[targetId] and waited < maxWait do
		task.wait(0.1)
		waited = waited + 0.1
		
		local foundInQueue = false
		for i, id in ipairs(state.pendingQueue) do
			if id == targetId then
				foundInQueue = true
				break
			end
		end
		
		if not foundInQueue then
			if state.towerById[targetId] then
				break
			end
		end
	end
	
	local success = state.towerById[targetId] ~= nil
	if success then
		local tower = state.towerById[targetId]
		local name = getTowerDisplayName(tower)
		local pos = getTowerPosition(tower)
		print("[OK] Tower ID=" .. targetId .. " (" .. name .. ") bound at " .. tostring(pos))
	else
		warn("[FAIL] Tower ID=" .. targetId .. " bind timeout (" .. maxWait .. "s)")
	end
	
	return success
end

Workspace.DescendantAdded:Connect(function(obj)
	if not (state.recording or state.playing) then return end
	if #state.pendingQueue == 0 then return end

	task.wait(0.2)

	local m = obj:IsA("Model") and obj or obj:FindFirstAncestorWhichIsA("Model")
	if not isTowerModel(m) then return end
	if seenModels[m] then return end
	if state.idByTower[m] then return end

	local id = table.remove(state.pendingQueue, 1)
	state.towerById[id] = m
	state.idByTower[m] = id
	state.towerTimestamps[m] = tick()
	seenModels[m] = true
	
	local towerName = getTowerDisplayName(m)
	local towerPos = getTowerPosition(m)
	state.towerNames[id] = towerName
	state.towerPositions[id] = towerPos

	print("[Bind] Tower ID=" .. id .. ", Name=" .. towerName .. ", Pos=" .. tostring(towerPos))
	
	if state.selectedTowerId == id then
		updateStatusLabel()
	end
end)

-- ===== Click Detection =====
local function getTargetFromScreenPos(screenPos)
	local ray = Workspace.CurrentCamera:ScreenPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Blacklist
	params.FilterDescendantsInstances = { LP.Character }
	params.IgnoreWater = true

	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
	return hit and hit.Instance or nil
end

local function findBoundTowerModel(inst)
	local maxDepth = 20
	local depth = 0
	
	while inst and inst ~= Workspace and depth < maxDepth do
		if state.idByTower[inst] then
			return inst
		end
		inst = inst.Parent
		depth = depth + 1
	end
	
	return nil
end

UIS.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if not state.recording then return end

	local screenPos
	if input.UserInputType == Enum.UserInputType.Touch then
		screenPos = input.Position
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		screenPos = UIS:GetMouseLocation()
	else
		return
	end

	local target = getTargetFromScreenPos(screenPos)
	if not target then return end

	local model = findBoundTowerModel(target)
	if model then
		local id = state.idByTower[model]
		local towerName = state.towerNames[id] or getTowerDisplayName(model)
		state.towerNames[id] = towerName
		
		if state.selectedTowerId == id then
			print("[Select] Already selected ID=" .. id .. " (" .. towerName .. ")")
		else
			local oldId = state.selectedTowerId
			state.selectedTowerId = id
			
			if oldId then
				local oldName = state.towerNames[oldId] or "Unknown"
				print("[Switch] ID=" .. oldId .. " (" .. oldName .. ") -> ID=" .. id .. " (" .. towerName .. ")")
				notify("Tower Switched", oldName .. " -> " .. towerName)
			else
				print("[Select] Tower ID=" .. id .. " (" .. towerName .. ")")
				notify("Tower Selected", "ID=" .. id .. " (" .. towerName .. ")")
			end
			
			updateStatusLabel()
		end
	end
end)

-- ===== Record Logic =====
local function recordPlaceTower(method, remote, args)
	if not state.recording then return end
	if method ~= "FireServer" then return end
	if not remote or remote.Name ~= "PlaceTower" then return end

	local id = tostring(state.towerIndex)
	state.towerIndex = state.towerIndex + 1
	state.upgradeCount[id] = 0

	table.insert(state.macro, {
		tick() - state.start,
		"PlaceTower",
		encodeArgs(args or {}),
		id,
		false,
		{ 
			targetName = id, 
			originalName = tostring(args[1]),
			towerType = tostring(args[1])
		}
	})

	table.insert(state.pendingQueue, id)
	local queueStr = table.concat(state.pendingQueue, ", ")
	print("[Place] Tower ID=" .. id .. ", Queue: [" .. queueStr .. "]")
	
	task.spawn(function()
		waitForSpecificTowerBind(id, 5)
	end)
end

local function recordUpgrade(method, remote, args)
	if not state.recording then return end
	if method ~= "FireServer" then return end
	if not remote or not remote.Name:lower():find("upgrade") then return end

	local id = state.selectedTowerId
	
	if not id then
		warn("[ERROR] No tower selected! Please click tower first")
		notify("Error", "Please click tower first")
		return
	end

	local towerModel = state.towerById[id]
	if not towerModel then
		warn("[ERROR] Tower ID=" .. id .. " not bound! Wait for tower spawn")
		notify("Error", "Tower not spawned yet")
		return
	end

	state.upgradeCount[id] = (state.upgradeCount[id] or 0) + 1
	local towerName = state.towerNames[id] or getTowerDisplayName(towerModel)

	table.insert(state.macro, {
		tick() - state.start,
		"UpgradeRem",
		{},
		tostring(id),
		false,
		{ 
			u = state.upgradeCount[id], 
			s = 1,
			towerName = towerName
		}
	})

	print("[Upgrade] ID=" .. id .. " (" .. towerName .. ") #" .. state.upgradeCount[id])
	updateStatusLabel()
end

-- ===== Hook Remote =====
local old
old = hookmetamethod(game, "__namecall", function(self, ...)
	local method = getnamecallmethod()
	local args = { ... }
	if typeof(self) == "Instance" then
		pcall(function()
			recordPlaceTower(method, self, args)
			recordUpgrade(method, self, args)
		end)
	end
	return old(self, ...)
end)

-- ===== 🔥 核心修复：从塔模型内部调用升级 =====
local function quickUpgrade(targetId, expectedName)
	targetId = tostring(targetId)
	
	local towerModel = state.towerById[targetId]
	if not towerModel then
		warn("[ERROR] Tower model not found: ID=" .. targetId)
		return false
	end

	if expectedName and state.strictMode then
		local actualName = getTowerDisplayName(towerModel)
		if actualName ~= expectedName then
			warn("[SKIP] Type mismatch! ID=" .. targetId .. ", Expected:" .. expectedName .. ", Actual:" .. actualName)
			return false
		end
	end

	-- 🔥 关键修复：从塔模型内部找到它自己的 UpgradeRem
	local towerUpgradeRem = findTowerUpgradeRemote(towerModel)
	
	if not towerUpgradeRem then
		warn("[ERROR] UpgradeRem not found in tower ID=" .. targetId)
		return false
	end
	
	-- 🔥 使用塔自己的 UpgradeRem 进行升级
	local success = pcall(function() 
		towerUpgradeRem:FireServer() 
	end)
	
	if not success then
		warn("[ERROR] Failed to fire UpgradeRem for tower ID=" .. targetId)
		return false
	end
	
	local towerName = state.towerNames[targetId] or getTowerDisplayName(towerModel)
	print("[✓ Upgrade] ID=" .. targetId .. " (" .. towerName .. ") using " .. towerUpgradeRem:GetFullName())
	
	return true
end

-- ===== Playback =====
local function play()
	if state.playing then return end
	if not isfile(FILE) then notify("Error", "Macro file not found") return end

	state.playing = true
	state.towerById = {}
	state.idByTower = {}
	state.pendingQueue = {}
	state.upgradeCount = {}
	state.towerNames = {}
	state.towerTimestamps = {}
	state.towerPositions = {}
	seenModels = {}

	print("=== Playback Start ===")
	waitForWave()

	local data
	local ok = pcall(function() data = Http:JSONDecode(readfile(FILE)) end)
	if not ok or type(data) ~= "table" then
		notify("Error", "JSON parse failed")
		state.playing = false
		return
	end
	
	print("[Load] Macro loaded, commands: " .. #data)

	local PlaceRem = findRemote("PlaceTower", 8)
	if not PlaceRem then
		notify("Error", "PlaceTower remote not found")
		state.playing = false
		return
	end
	
	print("[OK] PlaceTower remote found")

	local placeCount = 0
	local upgradeCount = 0
	local upgradeByTower = {}

	local last = 0
	for i, it in ipairs(data) do
		local t, r, a, target, _, meta = it[1], it[2], it[3], it[4], it[5], it[6]
		local dt = t - last
		if dt > 0 then task.wait(dt) end

		if r == "PlaceTower" then
			placeCount = placeCount + 1
			print("[" .. i .. "/" .. #data .. "] Place tower ID=" .. target)
			table.insert(state.pendingQueue, tostring(target))
			local args = decodeArgs(a or {})
			pcall(function()
				PlaceRem:FireServer(unpack(args))
			end)
			
			waitForSpecificTowerBind(target, 5)

		elseif r == "UpgradeRem" then
			upgradeCount = upgradeCount + 1
			upgradeByTower[target] = (upgradeByTower[target] or 0) + 1
			
			local towerName = (meta and meta.towerName) or target
			print("[" .. i .. "/" .. #data .. "] Upgrade ID=" .. target .. " (" .. towerName .. ") #" .. upgradeByTower[target])
			
			if not state.towerById[tostring(target)] then
				print("[Wait] Tower ID=" .. target .. " not bound, waiting...")
				waitForSpecificTowerBind(target, 3)
			end

			local expectedName = meta and meta.towerName or nil
			quickUpgrade(target, expectedName)
		end

		last = t
	end

	state.playing = false
	print("=== Playback Complete ===")
	print("[Stats] Placed: " .. placeCount .. ", Upgraded: " .. upgradeCount)
	
	print("[Stats] Upgrades by tower:")
	for towerId, count in pairs(upgradeByTower) do
		local name = state.towerNames[towerId] or "Unknown"
		print("  Tower" .. towerId .. " (" .. name .. "): " .. count .. "x")
	end
	
	notify("Complete", "Placed: " .. placeCount .. "\nUpgrades: " .. upgradeCount)
end

-- ===== UI Panel =====
local Window = Rayfield:CreateWindow({
	Name = "TD Macro v4.8 Fixed",
	LoadingTitle = "TD Macro v4.8",
	LoadingSubtitle = "Each tower uses its own UpgradeRem",
	KeySystem = false
})

local Tab = Window:CreateTab("Main", 4483362458)

StatusLabel = Tab:CreateLabel("No tower selected | Click tower to select")

Tab:CreateLabel("Instructions:")
Tab:CreateLabel("1. Place tower -> Auto wait for bind")
Tab:CreateLabel("2. Click tower to select before upgrade")
Tab:CreateLabel("3. Each tower uses its own UpgradeRem")

Tab:CreateButton({
	Name = "Start Recording",
	Callback = function()
		if state.recording then notify("Info", "Already recording") return end
		waitForWave()

		state.macro = {}
		state.start = tick()
		state.towerIndex = 1
		state.towerById = {}
		state.idByTower = {}
		state.pendingQueue = {}
		state.upgradeCount = {}
		state.towerNames = {}
		state.towerTimestamps = {}
		state.towerPositions = {}
		state.selectedTowerId = nil
		seenModels = {}

		state.recording = true
		updateStatusLabel()
		notify("Recording", "Place tower -> Auto bind\nClick to select tower")
		print("=== Recording Started ===")
	end
})

Tab:CreateButton({
	Name = "Save Macro",
	Callback = function()
		if not state.recording then notify("Error", "Not recording") return end
		state.recording = false
		
		local placeCount, upgradeCount = 0, 0
		local upgradeByTower = {}
		
		for _, it in ipairs(state.macro) do
			if it[2] == "PlaceTower" then 
				placeCount = placeCount + 1
			elseif it[2] == "UpgradeRem" then 
				upgradeCount = upgradeCount + 1
				local towerId = it[4]
				upgradeByTower[towerId] = (upgradeByTower[towerId] or 0) + 1
			end
		end
		
		print("[Stats] Recording:")
		print("  Commands: " .. #state.macro)
		print("  Placed: " .. placeCount)
		print("  Upgrades: " .. upgradeCount)
		print("[Stats] Upgrades per tower:")
		for towerId, count in pairs(upgradeByTower) do
			local name = state.towerNames[towerId] or "Unknown"
			print("  Tower" .. towerId .. " (" .. name .. "): " .. count .. "x")
		end
		
		local ok = pcall(function()
			writefile(FILE, Http:JSONEncode(state.macro))
		end)
		
		if ok then 
			notify("Saved", "Towers: " .. placeCount .. "\nUpgrades: " .. upgradeCount)
			print("[Save] Macro saved")
		else 
			notify("Error", "Save failed") 
		end
	end
})

Tab:CreateButton({
	Name = "Play Macro",
	Callback = function()
		if state.recording then notify("Error", "Stop recording first") return end
		play()
	end
})

Tab:CreateButton({
	Name = "Deselect Tower",
	Callback = function()
		if not state.recording then notify("Info", "Start recording first") return end
		state.selectedTowerId = nil
		updateStatusLabel()
		notify("Deselected", "Click tower to select")
	end
})

Tab:CreateButton({
	Name = "Monitor Status",
	Callback = function()
		if not state.recording then notify("Info", "Start recording first") return end
		
		local upgradeStats = {}
		for _, it in ipairs(state.macro) do
			if it[2] == "UpgradeRem" then
				local towerId = it[4]
				upgradeStats[towerId] = (upgradeStats[towerId] or 0) + 1
			end
		end
		
		local statsText = ""
		for towerId, count in pairs(upgradeStats) do
			local name = state.towerNames[towerId] or "Unknown"
			statsText = statsText .. "\nTower" .. towerId .. " (" .. name .. "): " .. count .. "x"
		end
		
		local msg = "Commands: " .. #state.macro .. "\n" ..
			"Bound: " .. #getTableKeys(state.towerById) .. "\n" ..
			"Pending: " .. #state.pendingQueue .. "\n" ..
			"Selected: " .. (state.selectedTowerId or "None") ..
			statsText
		
		notify("Status", msg)
		print("[Status] " .. msg)
	end
})

local Tab2 = Window:CreateTab("Settings", 4483362458)

Tab2:CreateToggle({
	Name = "Strict Mode (Type Check)",
	CurrentValue = true,
	Flag = "StrictMode",
	Callback = function(Value)
		state.strictMode = Value
		notify(Value and "Strict ON" or "Strict OFF", Value and "Skip type mismatch" or "Force upgrade")
	end
})

Tab2:CreateToggle({
	Name = "Debug Mode (Verbose Log)",
	CurrentValue = false,
	Flag = "DebugMode",
	Callback = function(Value)
		state.debugMode = Value
		notify(Value and "Debug ON" or "Debug OFF", Value and "Detailed logs" or "Key info only")
	end
})

Tab2:CreateButton({
	Name = "View Macro Info",
	Callback = function()
		if not isfile(FILE) then notify("Error", "File not found") return end
		
		local ok, data = pcall(function() return Http:JSONDecode(readfile(FILE)) end)
		
		if ok and type(data) == "table" then
			local placeCount, upgradeCount = 0, 0
			local upgradeByTower = {}
			
			for _, it in ipairs(data) do
				if it[2] == "PlaceTower" then 
					placeCount = placeCount + 1
				elseif it[2] == "UpgradeRem" then 
					upgradeCount = upgradeCount + 1
					local towerId = it[4]
					upgradeByTower[towerId] = (upgradeByTower[towerId] or 0) + 1
				end
			end
			
			print("[Info] Macro file:")
			print("  Commands: " .. #data)
			print("  Placed: " .. placeCount)
			print("  Upgrades: " .. upgradeCount)
			print("[Info] Upgrade distribution:")
			for towerId, count in pairs(upgradeByTower) do
				print("  Tower" .. towerId .. ": " .. count .. "x")
			end
			
			notify("Macro Info", "Commands: " .. #data .. "\nTowers: " .. placeCount .. " | Upgrades: " .. upgradeCount)
		end
	end
})

Tab2:CreateButton({
	Name = "Delete Macro",
	Callback = function()
		if isfile(FILE) then delfile(FILE) notify("Deleted", "File deleted") 
		else notify("Info", "File not found") end
	end
})

Tab2:CreateButton({
	Name = "Debug: View Bound Towers",
	Callback = function()
		local keys = getTableKeys(state.towerById)
		if #keys == 0 then
			notify("Debug", "No bound towers")
		else
			print("=== Bound Towers ===")
			for _, id in ipairs(keys) do
				local tower = state.towerById[id]
				local name = state.towerNames[id] or getTowerDisplayName(tower)
				local upgrades = state.upgradeCount[id] or 0
				local pos = state.towerPositions[id]
				local upgradeRem = findTowerUpgradeRemote(tower)
				local upgradeRemPath = upgradeRem and upgradeRem:GetFullName() or "NOT FOUND"
				print("ID=" .. id .. ", Name=" .. name .. ", Upgrades=" .. upgrades .. ", Pos=" .. tostring(pos))
				print("  UpgradeRem: " .. upgradeRemPath)
			end
			notify("Debug", "Bound: " .. #keys .. " towers\nCheck console")
		end
	end
})

Tab2:CreateButton({
	Name = "Debug: View Queue",
	Callback = function()
		if #state.pendingQueue == 0 then
			notify("Debug", "Queue empty")
		else
			local queueStr = table.concat(state.pendingQueue, ", ")
			print("=== Pending Queue ===")
			print("Queue: [" .. queueStr .. "]")
			notify("Debug", "Pending: " .. #state.pendingQueue .. "\n[" .. queueStr .. "]")
		end
	end
})

notify("v4.8 Loaded", "Each tower uses its own UpgradeRem\nNo more Tower1 only issue!")
print("=== TD Macro v4.8 Loaded ===")
print("[Fix] Each tower uses its internal UpgradeRem")
print("[Fix] Correct upgrade targeting for all towers")
