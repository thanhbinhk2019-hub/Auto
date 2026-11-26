local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local CoreGui = game:GetService("CoreGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Functions = ReplicatedStorage:WaitForChild("Functions")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- ================= CẤU HÌNH CHUNG =================
local ALLOWED_STAGES = {
	["kagoshima 1"] = 1,
	["kagoshima 2"] = 2,
	["kyoto 1"] = 3,
}

-- Dán link raw của Kagoshima 2 và Kyoto 1 vào đây khi có:
local WIN_SCRIPT_URLS = {
	["kagoshima 1"] = "", -- Đã tích hợp sẵn bên dưới
	["kagoshima 2"] = "",
	["kyoto 1"]     = "",
}

local CFG = {
	-- Sảnh
	LOBBY_GATE_1 = Vector3.new(-155.45, 17.40, 2933.06),
	CULLING_TP2_POS = Vector3.new(5.52, -128.12, 2926.15),
	CULLING_WALK_POS = Vector3.new(17.46, -127.61, 2926.01),
	ELEVATOR_NAME = "Elevator5",
	ARRIVAL_DIST = 5.5,
	TELEPORT_AWAY_DIST = 25,
	WALK_TIMEOUT = 16,
	MATCH_SCAN_DELAY = 1.5,
	STAGE_DETECT_TIMEOUT = 8.0,
	START_RETRY_DELAY = 2.5,
	REJOIN_COOLDOWN = 6.0,
	LOOP_TICK = 0.35,

	-- Trong trận (Win)
	startupWait = 3.0,
	spawnWait = 1.25,
	upWait = 0.75,
	retryWait = 1.15,
	moneyTimeout = 4.0,
	autoStartWave = 7,
	autoLoopTick = 0.45,
	minTowerDist = 1.6,
	aiStep = 1.5,
	aiMaxRing = 8,
	maxSpawnAttemptsPerSlot = 60,
}

-- ================= 1. XÁC ĐỊNH TIỀN & WAVE =================
local MULT = { K = 1e3, M = 1e6, B = 1e9, T = 1e12 }
local function parseNumber(val)
	if typeof(val) == "number" then return val end
	if typeof(val) ~= "string" then return nil end

	local clean = val:gsub(",", ""):gsub("%$", ""):gsub("%s+", "")
	local mult = 1
	local suffix = clean:match("[kKmMbBtT]$")
	if suffix then
		mult = MULT[suffix:upper()] or 1
		clean = clean:sub(1, -2)
	end

	local numStr = clean:match("%-?%d+%.?%d*")
	local n = tonumber(numStr)
	return n and (n * mult) or nil
end

local function getCurrentMoney()
	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Name == "Gold" and obj.Text ~= "" then
			local n = parseNumber(obj.Text)
			if n then return n, obj.Text end
		end
	end

	local leaderstats = player:FindFirstChild("leaderstats")
	if leaderstats then
		for _, v in ipairs(leaderstats:GetChildren()) do
			if v:IsA("ValueBase") then
				local n = parseNumber(v.Value)
				if n then return n, tostring(v.Value) end
			end
		end
	end

	return nil, nil
end

local function parseWaveText(txt, strictPairOnly)
	if typeof(txt) ~= "string" or txt == "" then return nil, nil end

	local cur, total = txt:match("[sS][oó][nN][gG]%s*:?%s*(%d+)%s*/%s*(%d+)")
	if cur then return tonumber(cur), tonumber(total) end

	local wCur, wTotal = txt:match("[wW][aA][vV][eE]%s*:?%s*(%d+)%s*/%s*(%d+)")
	if wCur then return tonumber(wCur), tonumber(wTotal) end

	if strictPairOnly then return nil, nil end

	local single = txt:match("[sS][oó][nN][gG]%s*:?%s*(%d+)")
		or txt:match("[wW][aA][vV][eE]%s*:?%s*(%d+)")
	if single then return tonumber(single), nil end

	return nil, nil
end

local function getCurrentWave()
	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" then
			if obj.Name == "Wave" or obj.Name == "Sóng" then
				local cur, total = parseWaveText(obj.Text, false)
				if cur then return cur, total, obj.Text end
			end
		end
	end

	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" then
			local ltxt = obj.Text:lower()
			if ltxt:find("sóng") or ltxt:find("wave") then
				local cur, total = parseWaveText(obj.Text, true)
				if cur then return cur, total, obj.Text end
			end
		end
	end

	return nil, nil, nil
end

-- ================= 2. XÁC ĐỊNH SẢNH VS TRONG TRẬN =================
local function detectEnvironment()
	local wave, maxWave = getCurrentWave()
	local towersFolder = workspace:FindFirstChild("Towers")
	local hasTowers = towersFolder ~= nil and #towersFolder:GetChildren() > 0

	local hasColonyUi = false
	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" then
			local n = obj.Name
			if n == "ColonyName" or n == "ColonyNum" or n == "CurrentColony" or n == "LivesLeft" then
				hasColonyUi = true
				break
			end
		end
	end

	if (wave ~= nil and maxWave ~= nil) or (hasTowers and not hasColonyUi) then
		return "IN_MATCH"
	end

	if hasColonyUi or (workspace:FindFirstChild("CullingGamesTeleporters") ~= nil and wave == nil) then
		return "LOBBY"
	end

	if wave ~= nil then
		return "IN_MATCH"
	end

	return "LOBBY"
end

-- ================= 3. QUÉT & XÁC ĐỊNH MÀN =================
local function normalizeStageKey(rawName)
	if typeof(rawName) ~= "string" or rawName == "" then return nil end
	local clean = rawName:gsub("[%c%z]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""):lower()
	if clean == "" then return nil end

	local area, num = clean:match("(kagoshima)%s*[-:#/]?%s*(%d+)")
	if not area then
		area, num = clean:match("(kyoto)%s*[-:#/]?%s*(%d+)")
	end
	if area and num then
		return area .. " " .. tostring(tonumber(num))
	end
	return clean
end

local function extractStageCandidateFromText(rawText)
	if typeof(rawText) ~= "string" or rawText == "" then return nil end
	local clean = rawText:gsub("[%c%z]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if clean == "" then return nil end

	local area, num = clean:lower():match("(kagoshima)%s*[-:#/]?%s*(%d+)")
	if not area then
		area, num = clean:lower():match("(kyoto)%s*[-:#/]?%s*(%d+)")
	end
	if area and num then
		return area:sub(1, 1):upper() .. area:sub(2) .. " " .. tostring(tonumber(num))
	end

	local otherArea, otherNum = clean:lower():match("(sendai)%s*[-:#/]?%s*(%d+)")
	if not otherArea then
		otherArea, otherNum = clean:lower():match("(tokyo)%s*[-:#/]?%s*(%d+)")
	end
	if otherArea and otherNum then
		return otherArea:sub(1, 1):upper() .. otherArea:sub(2) .. " " .. tostring(tonumber(otherNum))
	end
	return nil
end

local function isStageUiVisible(obj)
	local cur = obj
	while cur and cur ~= playerGui do
		if cur:IsA("GuiObject") and not cur.Visible then return false end
		if cur:IsA("LayerCollector") and not cur.Enabled then return false end
		cur = cur.Parent
	end
	return true
end

local function detectStageInMatch()
	local stageRaw, livesLeft, fallbackAllowedRaw, fallbackOtherRaw = nil, nil, nil, nil

	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" and isStageUiVisible(obj) then
			local clean = obj.Text:gsub("[%c%z]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
			if obj.Name == "ColonyName" and clean ~= "" then
				stageRaw = extractStageCandidateFromText(clean) or clean
			elseif obj.Name == "LivesLeft" then
				local n = clean:match("(%d+)")
				if n then livesLeft = tonumber(n) end
			end
		end
	end

	if not stageRaw then
		for _, obj in ipairs(playerGui:GetDescendants()) do
			if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" and isStageUiVisible(obj) then
				local cand = extractStageCandidateFromText(obj.Text)
				if cand then
					local k = normalizeStageKey(cand)
					if k and ALLOWED_STAGES[k] then
						fallbackAllowedRaw = cand
						break
					elseif not fallbackOtherRaw then
						fallbackOtherRaw = cand
					end
				end
			end
		end
		stageRaw = fallbackAllowedRaw or fallbackOtherRaw
	end

	if not stageRaw then
		for _, attrName in ipairs({ "ColonyName", "StageName", "MapName", "CurrentStage", "CurrentColony" }) do
			local aVal = workspace:GetAttribute(attrName) or player:GetAttribute(attrName)
			if typeof(aVal) == "string" and aVal ~= "" then
				stageRaw = extractStageCandidateFromText(aVal) or aVal
				break
			end
		end
	end

	local key = normalizeStageKey(stageRaw)
	local slot = key and ALLOWED_STAGES[key] or nil
	return stageRaw, key, slot, livesLeft
end

-- ================= 4. SẢNH: TP, ĐI BỘ, TƯƠNG TÁC, BẮT ĐẦU & REJOIN =================
local function getCharacterAndParts()
	local char = player.Character
	if not char then return nil, nil, nil end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	return char, root, hum
end

local function walkToPosition(targetPos, setActionFn, stageLabel, activeRef)
	local _, root, hum = getCharacterAndParts()
	if not root or not hum then return false end

	local startClock = os.clock()
	local lastMoveCmd = 0
	local lastStuckCheck = os.clock()
	local lastCheckPos = root.Position

	while activeRef() do
		local _, curRoot, curHum = getCharacterAndParts()
		if not curRoot or not curHum then return false end

		local dist = (curRoot.Position - targetPos).Magnitude
		if dist <= CFG.ARRIVAL_DIST then return true end
		if os.clock() - startClock >= CFG.WALK_TIMEOUT then return false end

		if os.clock() - lastMoveCmd >= 0.25 then
			lastMoveCmd = os.clock()
			local dir = (targetPos - curRoot.Position)
			local stepVec = dir.Magnitude > 5 and (dir.Unit * 5) or dir
			local nextGoal = Vector3.new(curRoot.Position.X + stepVec.X, targetPos.Y, curRoot.Position.Z + stepVec.Z)

			pcall(function()
				curHum.PlatformStand = false
				if curHum.WalkSpeed < 16 then curHum.WalkSpeed = 16 end
				curHum:MoveTo(nextGoal)
			end)
		end

		if os.clock() - lastStuckCheck >= 1.2 then
			local movedDist = (curRoot.Position - lastCheckPos).Magnitude
			lastCheckPos = curRoot.Position
			lastStuckCheck = os.clock()
			if movedDist < 0.8 then
				pcall(function()
					curHum.Jump = true
					curHum:MoveTo(targetPos)
				end)
			end
		end

		if setActionFn then
			setActionFn(string.format("%s (cách %.1fm)...", stageLabel or "Đang đi bộ tới đích", dist))
		end
		task.wait(0.15)
	end
	return false
end

local function getPromptPosition(prompt)
	local parent = prompt.Parent
	if not parent then return nil end
	if parent:IsA("Attachment") then return parent.WorldPosition
	elseif parent:IsA("BasePart") then return parent.Position
	elseif parent:IsA("Model") then
		local part = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart", true)
		return part and part.Position or nil
	end
	return nil
end

local function findNearestPrompt(maxDistOverride)
	local _, root = getCharacterAndParts()
	if not root then return nil end
	local nearest, nearestDist = nil, math.huge
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("ProximityPrompt") and obj.Enabled then
			local pos = getPromptPosition(obj)
			if pos then
				local d = (root.Position - pos).Magnitude
				local limit = maxDistOverride or obj.MaxActivationDistance
				if d <= limit and d < nearestDist then
					nearest = obj
					nearestDist = d
				end
			end
		end
	end
	return nearest
end

local function triggerPromptSafe(prompt)
	if not prompt or not prompt.Parent or not prompt.Enabled then return false end
	if typeof(fireproximityprompt) ~= "function" then return false end
	return pcall(function() fireproximityprompt(prompt) end)
end

local function fireTryToStart()
	local cgtRemotes = Remotes:FindFirstChild("CullingGamesTeleporters")
	local tryToStart = cgtRemotes and cgtRemotes:FindFirstChild("TryToStart")
	local teleporters = workspace:FindFirstChild("CullingGamesTeleporters")
	local elevator = teleporters and teleporters:FindFirstChild(CFG.ELEVATOR_NAME)

	if tryToStart and elevator then
		return pcall(function() tryToStart:FireServer(elevator) end)
	end
	return false
end

local lastRejoinTick = 0
local function triggerRejoin()
	if os.clock() - lastRejoinTick < CFG.REJOIN_COOLDOWN then return false end
	lastRejoinTick = os.clock()
	return pcall(function()
		if game.JobId and game.JobId ~= "" then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
		else
			TeleportService:Teleport(game.PlaceId, player)
		end
	end)
end

-- ================= 5. HỆ THỐNG ĐẶT & NÂNG THÁP (KAGOSHIMA 1 TÍCH HỢP) =================
local aiMem = { badPos = {}, bestDirById = {} }
local DIRS = {
	{1,0}, {-1,0}, {0,1}, {0,-1},
	{1,1}, {1,-1}, {-1,1}, {-1,-1},
	{2,0}, {-2,0}, {0,2}, {0,-2},
	{2,1}, {2,-1}, {-2,1}, {-2,-1},
	{1,2}, {1,-2}, {-1,2}, {-1,-2},
}

local function posKey(cf)
	local p = cf.Position
	return string.format("%.1f_%.1f_%.1f", p.X, p.Y, p.Z)
end

local function allTowers()
	local f = workspace:FindFirstChild("Towers")
	return f and f:GetChildren() or {}
end

local function getTowerPos(obj)
	if not obj then return nil end
	if obj:IsA("Model") then
		local ok, cf = pcall(function() return obj:GetPivot() end)
		if ok and cf then return cf.Position end
	elseif obj:IsA("BasePart") then
		return obj.Position
	end
	local hrp = obj:FindFirstChildWhichIsA("BasePart", true)
	return hrp and hrp.Position or nil
end

local function isPosOccupied(pos)
	for _, t in ipairs(allTowers()) do
		local tp = getTowerPos(t)
		if tp and (Vector3.new(tp.X, pos.Y, tp.Z) - Vector3.new(pos.X, pos.Y, pos.Z)).Magnitude < CFG.minTowerDist then
			return true
		end
	end

	local ignoreList = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then table.insert(ignoreList, plr.Character) end
	end
	local towersFolder = workspace:FindFirstChild("Towers")
	if towersFolder then table.insert(ignoreList, towersFolder) end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = ignoreList

	local hit = workspace:Raycast(Vector3.new(pos.X, pos.Y + 4.5, pos.Z), Vector3.new(0, -6.5, 0), rayParams)
	if hit and hit.Instance then
		local inst = hit.Instance
		local lname = inst.Name:lower()
		local isWalkableFloor = inst.CanCollide and (lname:find("floor") or lname:find("ground") or lname:find("base") or lname:find("road") or lname:find("path") or lname:find("terrain") or math.abs(hit.Position.Y - pos.Y) <= 1.2)
		if not isWalkableFloor and inst.CanCollide then
			return true
		end
	end
	return false
end

local function findTower(name)
	local f = workspace:FindFirstChild("Towers")
	if not f or not name then return nil end
	if f:FindFirstChild(name) then return f[name] end
	if not name:match("%d+$") then
		for _, suf in ipairs({ "1", "_1", " 1" }) do
			if f:FindFirstChild(name .. suf) then return f[name .. suf] end
		end
	end
	for _, d in ipairs(f:GetDescendants()) do
		if d.Name == name then return d end
	end
	local pre = name:match("^(.-)%d+$") or name
	for _, c in ipairs(f:GetChildren()) do
		if c.Name == pre or c.Name:sub(1, #pre) == pre then return c end
	end
	return nil
end

local function moneyDropped(before, activeRef)
	if before == nil then return false end
	local dl = os.clock() + CFG.moneyTimeout
	while activeRef() and os.clock() < dl do
		task.wait(0.1)
		local now = getCurrentMoney()
		if now and now < before then return true end
	end
	return false
end

local function aiPickCf(baseCf, towerId, idx, forceShift, ignoreBadCache)
	local _, rx, ry, rz = baseCf:ToEulerAnglesXYZ()
	local p = baseCf.Position

	if idx <= 1 and not forceShift then
		if not isPosOccupied(p) and (ignoreBadCache or not aiMem.badPos[posKey(baseCf)]) then
			return baseCf, nil
		end
	end

	local list = {}
	local fav = aiMem.bestDirById[tostring(towerId or "")]
	if fav then table.insert(list, fav) end
	for _, d in ipairs(DIRS) do
		if not fav or d[1] ~= fav[1] or d[2] ~= fav[2] then
			table.insert(list, d)
		end
	end

	local fallbackCand, fallbackDir
	for ring = 1, CFG.aiMaxRing do
		for _, d in ipairs(list) do
			local cand = CFrame.new(p.X + d[1] * ring * CFG.aiStep, p.Y, p.Z + d[2] * ring * CFG.aiStep) * CFrame.Angles(rx, ry, rz)
			if ignoreBadCache or not aiMem.badPos[posKey(cand)] then
				if not fallbackCand then fallbackCand, fallbackDir = cand, d end
				if not isPosOccupied(cand.Position) then
					return cand, d
				end
			end
		end
	end

	if fallbackCand then return fallbackCand, fallbackDir end
	local d = list[((idx - 1) % #list) + 1]
	return CFrame.new(p.X + d[1] * CFG.aiStep, p.Y, p.Z + d[2] * CFG.aiStep) * CFrame.Angles(rx, ry, rz), d
end

local function chooseModifiers()
	local cg = Remotes:FindFirstChild("CullingGames")
	local cm = cg and cg:FindFirstChild("ChooseModifiers")
	if cm then pcall(function() cm:FireServer(1, false) end) end
end

local function voteSkip()
	local vs = Remotes:FindFirstChild("VoteSkip")
	if vs then
		pcall(function()
			if vs:IsA("RemoteEvent") then vs:FireServer()
			elseif vs:IsA("RemoteFunction") then vs:InvokeServer() end
		end)
	end
end

local KAGOSHIMA_1_STEPS = {
	{ stepId = 2,  action = "spawn",   minCost = 1200, towerId = "3a4f9c5c-dcfc-46aa-ad1e-be37e88c9c66", cf = CFrame.new(4.864310264587402, 47.32311248779297, -121.51627349853516) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 3,  action = "spawn",   minCost = 600,  towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-25.062589645385742, 47.15073776245117, -107.02923583984375) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 5,  action = "spawn",   minCost = 600,  towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-26.276447296142578, 47.150733947753906, -111.41389465332031) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 7,  action = "upgrade", minCost = 100,  optional = true, targetName = "SorcererAgent" },
	{ stepId = 8,  action = "spawn",   minCost = 600,  towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-15.050935745239258, 47.15073776245117, -108.41059875488281) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 10, action = "upgrade", minCost = 100,  optional = true, targetName = "SorcererAgent" },
	{ stepId = 11, action = "upgrade", minCost = 100,  optional = true, targetName = "SorcererAgent" },
	{ stepId = 12, action = "spawn",   minCost = 600,  towerId = "348f2cd1-e2e9-48c8-a13b-589f09bc0654", cf = CFrame.new(22.122488021850586, 47.150047302246094, -121.02806091308594) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 13, action = "upgrade", targetName = "SoulCurse" },
	{ stepId = 14, action = "upgrade", targetName = "SorcererAgent2" },
	{ stepId = 15, action = "upgrade", targetName = "SorcererAgent3" },
	{ stepId = 16, action = "upgrade", targetName = "SorcererAgent2" },
	{ stepId = 17, action = "skip" },
	{ stepId = 18, action = "spawn",   minCost = 600,  towerId = "a7976e77-c58a-44c6-bde9-d9710fd14ac2", cf = CFrame.new(26.937042236328125, 47.16230010986328, -117.86810302734375) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 19, action = "upgrade", targetName = "SoulCurse2" },
	{ stepId = 20, action = "upgrade", targetName = "SorcererAgent2" },
	{ stepId = 21, action = "upgrade", targetName = "SoulCurse3" },
	{ stepId = 22, action = "upgrade", targetName = "FingerBearerAwk" },
	{ stepId = 23, action = "upgrade", targetName = "FingerBearerAwk2" },
}

local AUTO_UPGRADE_LOOP = {
	"FingerBearerAwk2", "FingerBearerAwk",
	"SoulCurse3", "SoulCurse2", "SoulCurse",
	"SorcererAgent3", "SorcererAgent2", "SorcererAgent",
}

local function runKagoshima1Win(setActionFn, activeRef)
	aiMem = { badPos = {}, bestDirById = {} }

	local function doSpawn(id, cf, lbl, minCostHint)
		local tries, ignoreBad, forceShift = 0, false, false
		while activeRef() and tries < CFG.maxSpawnAttemptsPerSlot do
			tries += 1
			if tries == 10 then
				aiMem.badPos = {}
				ignoreBad = true
			end

			local curMoney = getCurrentMoney()
			if minCostHint and curMoney and curMoney > minCostHint and tries >= 2 then
				forceShift = true
			end

			local targetCf, usedDir = aiPickCf(cf, id, tries, forceShift, ignoreBad)
			local m0 = getCurrentMoney()
			local prevCount = #allTowers()
			local prev = {}
			for _, t in ipairs(allTowers()) do prev[t] = true end

			local ok, res = pcall(function()
				return Functions.SpawnNewTower:InvokeServer(id, targetCf)
			end)
			local drop = moneyDropped(m0, activeRef)
			local nowTowers = allTowers()
			local spawned = (typeof(res) == "Instance") or (#nowTowers > prevCount)
			if not spawned then
				for _, t in ipairs(nowTowers) do
					if not prev[t] then spawned = true break end
				end
			end

			local shifted = (targetCf.Position - cf.Position).Magnitude > 0.05
			setActionFn(string.format("%s [#%d/%d%s | -tiền=%s]",
				lbl, tries, CFG.maxSpawnAttemptsPerSlot,
				shifted and " | ĐỔI CHỖ TRỐNG" or "", tostring(drop)))

			if ok and res ~= false and (drop or spawned) then
				if usedDir then aiMem.bestDirById[tostring(id or "")] = usedDir end
				task.wait(CFG.spawnWait)
				return true
			end

			forceShift = true
			if m0 == nil or m0 >= 100 then
				aiMem.badPos[posKey(targetCf)] = true
			end
			task.wait(CFG.retryWait)
		end
		setActionFn(lbl .. " [bỏ qua để không kẹt]")
		return false
	end

	local function doUpgrade(name, lbl)
		local tries = 0
		while activeRef() and tries < 6 do
			tries += 1
			local tgt = findTower(name)
			if not tgt then
				setActionFn(string.format("%s [chờ %s]", lbl, tostring(name)))
				task.wait(CFG.retryWait)
				continue
			end
			local m0 = getCurrentMoney()
			local ok, res = pcall(function()
				return Functions.UpgradeTower:InvokeServer(tgt)
			end)
			local drop = moneyDropped(m0, activeRef)
			setActionFn(string.format("%s #%d (-tiền=%s)", lbl, tries, tostring(drop)))
			if ok and res ~= false and drop then
				task.wait(CFG.upWait)
				return true
			end
			task.wait(CFG.retryWait)
		end
		return false
	end

	local t0 = os.clock()
	while activeRef() and (os.clock() - t0) < CFG.startupWait do
		setActionFn(string.format("Vào Kagoshima 1: Đợi %.1fs load...", math.max(0, CFG.startupWait - (os.clock() - t0))))
		task.wait(0.1)
	end
	if not activeRef() then return end

	chooseModifiers()
	setActionFn("[1] Chọn Modifier, chạy [2] -> [23]...")

	for i, s in ipairs(KAGOSHIMA_1_STEPS) do
		if not activeRef() then return end
		local tag = "#" .. (s.stepId or i)
		if s.action == "spawn" then
			doSpawn(s.towerId, s.cf, tag .. " Đặt", s.minCost)
		elseif s.action == "upgrade" then
			if s.optional and not findTower(s.targetName) then
				setActionFn(tag .. " Bỏ qua (" .. tostring(s.targetName) .. " không có)")
				task.wait(0.2)
			else
				doUpgrade(s.targetName, tag .. " Nâng " .. tostring(s.targetName))
			end
		elseif s.action == "skip" then
			voteSkip()
			setActionFn(tag .. " VoteSkip")
			task.wait(0.5)
		end
	end

	while activeRef() do
		local w = getCurrentWave()
		if w and w >= CFG.autoStartWave then
			voteSkip()
			for _, tName in ipairs(AUTO_UPGRADE_LOOP) do
				if not activeRef() then return end
				local curW = getCurrentWave()
				if not curW or curW < CFG.autoStartWave then break end
				doUpgrade(tName, "Auto W7+ Nâng " .. tName)
				task.wait(0.25)
			end
		else
			setActionFn(string.format("Chờ Wave %d để auto nâng & skip (nay: %s)", CFG.autoStartWave, tostring(w)))
		end
		task.wait(CFG.autoLoopTick)
	end
end

-- ================= 6. HUD ĐIỀU PHỐI =================
local function attachGui(gui)
	if typeof(gethui) == "function" then
		local ok, h = pcall(gethui)
		if ok and typeof(h) == "Instance" then
			gui.Parent = h
			return
		end
	end
	gui.Parent = playerGui or CoreGui
end

if _G.CullingFullHudStop then
	pcall(_G.CullingFullHudStop)
end

local sg = Instance.new("ScreenGui")
sg.Name = "CullingAllInOneGui"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 999999
pcall(function() attachGui(sg) end)

local statsBox = Instance.new("Frame")
statsBox.Size = UDim2.fromOffset(220, 56)
statsBox.Position = UDim2.fromOffset(18, 60)
statsBox.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
statsBox.BorderSizePixel = 1
statsBox.BorderColor3 = Color3.fromRGB(90, 160, 255)
statsBox.Active = true
statsBox.Draggable = true
statsBox.Parent = sg

local moneyLbl = Instance.new("TextLabel")
moneyLbl.Size = UDim2.new(1, -10, 0, 24)
moneyLbl.Position = UDim2.fromOffset(6, 2)
moneyLbl.BackgroundTransparency = 1
moneyLbl.Font = Enum.Font.SourceSansBold
moneyLbl.TextSize = 14
moneyLbl.TextColor3 = Color3.fromRGB(255, 215, 70)
moneyLbl.TextXAlignment = Enum.TextXAlignment.Left
moneyLbl.Text = "Tiền: ..."
moneyLbl.Parent = statsBox

local waveLbl = Instance.new("TextLabel")
waveLbl.Size = UDim2.new(1, -10, 0, 24)
waveLbl.Position = UDim2.fromOffset(6, 28)
waveLbl.BackgroundTransparency = 1
waveLbl.Font = Enum.Font.SourceSansBold
waveLbl.TextSize = 14
waveLbl.TextColor3 = Color3.fromRGB(115, 215, 255)
waveLbl.TextXAlignment = Enum.TextXAlignment.Left
waveLbl.Text = "Wave: ..."
waveLbl.Parent = statsBox

local menuBox = Instance.new("Frame")
menuBox.Size = UDim2.fromOffset(300, 90)
menuBox.Position = UDim2.fromOffset(18, 124)
menuBox.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
menuBox.BorderSizePixel = 1
menuBox.BorderColor3 = Color3.fromRGB(130, 95, 255)
menuBox.Active = true
menuBox.Draggable = true
menuBox.Parent = sg

local modeLbl = Instance.new("TextLabel")
modeLbl.Size = UDim2.new(1, -54, 0, 20)
modeLbl.Position = UDim2.fromOffset(7, 3)
modeLbl.BackgroundTransparency = 1
modeLbl.Font = Enum.Font.SourceSansBold
modeLbl.TextSize = 13
modeLbl.TextColor3 = Color3.fromRGB(130, 225, 255)
modeLbl.TextXAlignment = Enum.TextXAlignment.Left
modeLbl.Text = "Vị trí: Đang kiểm tra..."
modeLbl.Parent = menuBox

local stageLbl = Instance.new("TextLabel")
stageLbl.Size = UDim2.new(1, -14, 0, 20)
stageLbl.Position = UDim2.fromOffset(7, 24)
stageLbl.BackgroundTransparency = 1
stageLbl.Font = Enum.Font.SourceSansBold
stageLbl.TextSize = 12
stageLbl.TextColor3 = Color3.fromRGB(220, 175, 255)
stageLbl.TextXAlignment = Enum.TextXAlignment.Left
stageLbl.Text = "Màn: Đợi vào trận..."
stageLbl.Parent = menuBox

local actionLbl = Instance.new("TextLabel")
actionLbl.Size = UDim2.new(1, -14, 0, 36)
actionLbl.Position = UDim2.fromOffset(7, 46)
actionLbl.BackgroundTransparency = 1
actionLbl.Font = Enum.Font.SourceSans
actionLbl.TextSize = 12
actionLbl.TextColor3 = Color3.fromRGB(175, 245, 190)
actionLbl.TextXAlignment = Enum.TextXAlignment.Left
actionLbl.TextYAlignment = Enum.TextYAlignment.Top
actionLbl.TextWrapped = true
actionLbl.Text = "Đang làm: Khởi động..."
actionLbl.Parent = menuBox

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(40, 19)
closeBtn.Position = UDim2.new(1, -45, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(185, 55, 65)
closeBtn.BorderSizePixel = 0
closeBtn.Font = Enum.Font.SourceSansBold
closeBtn.TextSize = 11
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "Tắt"
closeBtn.Parent = menuBox

local active = true
local winToken = 0
_G.CullingFullHudStop = function()
	active = false
	winToken += 1
	if sg then sg:Destroy() end
end
closeBtn.MouseButton1Click:Connect(_G.CullingFullHudStop)

local function setAction(txt)
	if actionLbl and active then
		actionLbl.Text = "Đang làm: " .. tostring(txt)
	end
end

task.spawn(function()
	while active and sg and sg.Parent do
		pcall(function()
			local money, moneyRaw = getCurrentMoney()
			local wave, maxWave = getCurrentWave()
			moneyLbl.Text = money ~= nil and string.format("Tiền: %s (%s)", tostring(money), tostring(moneyRaw or money)) or "Tiền: 0 (chưa thấy)"
			waveLbl.Text = wave ~= nil and (maxWave and string.format("Wave: %d/%d", wave, maxWave) or string.format("Wave: %d", wave)) or "Wave: Sảnh / Chưa có"
		end)
		task.wait(0.25)
	end
end)

-- ================= 7. VÒNG LẶP ĐIỀU PHỐI CHÍNH =================
task.spawn(function()
	local gate1Passed, tp2Done, walkToFinalDone, isWalkingNow = false, false, false, false
	local lastInteractTick, lastStartTick = 0, 0
	local inMatchEnteredAt, matchVerifiedDone, startedMatchKey = nil, false, nil
	local currentStageRaw, currentStageKey, lastLivesLeft = nil, nil, nil

	while active do
		pcall(function()
			local env = detectEnvironment()
			modeLbl.Text = env == "LOBBY" and "Vị trí: Ở SẢNH" or "Vị trí: TRONG TRẬN"

			if env == "LOBBY" then
				if startedMatchKey ~= nil then
					winToken += 1
					startedMatchKey = nil
				end
				inMatchEnteredAt, matchVerifiedDone = nil, false
				currentStageRaw, currentStageKey, lastLivesLeft = nil, nil, nil
				stageLbl.Text = "Màn: Đợi vào trận mới quét..."

				local _, root = getCharacterAndParts()
				if not root then
					setAction("Chờ nhân vật xuất hiện...")
					return
				end

				local distGate1 = (root.Position - CFG.LOBBY_GATE_1).Magnitude
				local distTp2 = (root.Position - CFG.CULLING_TP2_POS).Magnitude
				local distWalkGoal = (root.Position - CFG.CULLING_WALK_POS).Magnitude

				if distWalkGoal <= CFG.ARRIVAL_DIST then
					gate1Passed, tp2Done, walkToFinalDone = true, true, true
				elseif distTp2 <= CFG.ARRIVAL_DIST then
					gate1Passed, tp2Done = true, true
				end

				if not gate1Passed then
					if distGate1 > CFG.ARRIVAL_DIST then
						if lastInteractTick > 0 and distGate1 >= CFG.TELEPORT_AWAY_DIST then
							gate1Passed, tp2Done, walkToFinalDone = true, false, false
							setAction("Đã qua cổng 1! Chuẩn bị TP điểm 2...")
							return
						end
						setAction(string.format("TP tới cổng 1 (%.1fm)...", distGate1))
						root.CFrame = CFrame.new(CFG.LOBBY_GATE_1)
					else
						local prompt = findNearestPrompt(15)
						if prompt then
							if os.clock() - lastInteractTick >= 2.0 then
								lastInteractTick = os.clock()
								triggerPromptSafe(prompt)
								setAction("Đã bấm Tương tác cổng 1, chờ game TP...")
							end
						else
							setAction("Đang tìm nút Tương tác tại cổng 1...")
						end
					end
				elseif not tp2Done then
					if distTp2 > CFG.ARRIVAL_DIST then
						setAction(string.format("TP tới vị trí 2 mới (%.1fm)...", distTp2))
						root.CFrame = CFrame.new(CFG.CULLING_TP2_POS)
					else
						tp2Done = true
						setAction("Đã tới vị trí 2 mới, chuẩn bị đi bộ...")
					end
				elseif not walkToFinalDone then
					if not isWalkingNow then
						isWalkingNow = true
						task.spawn(function()
							local okWalk = walkToPosition(CFG.CULLING_WALK_POS, setAction, "Đi bộ tới vị trí 2 cũ", function() return active end)
							isWalkingNow = false
							if okWalk then
								walkToFinalDone = true
								setAction("Đã đi bộ tới vị trí 2 cũ!")
							else
								setAction("Chưa tới vị trí 2 cũ, thử đi bộ lại...")
							end
						end)
					end
				else
					if os.clock() - lastStartTick >= CFG.START_RETRY_DELAY then
						lastStartTick = os.clock()
						local fired = fireTryToStart()
						setAction(fired and "Đã gửi Bắt đầu, đợi vào trận..." or "Chờ Elevator5 / TryToStart sẵn sàng...")
					end
				end

			elseif env == "IN_MATCH" then
				gate1Passed, tp2Done, walkToFinalDone, isWalkingNow, lastInteractTick = false, false, false, false, 0

				if not inMatchEnteredAt then
					inMatchEnteredAt = os.clock()
					setAction("Đã vào trận, đợi load rồi quét màn...")
					return
				end

				if not matchVerifiedDone then
					local elapsed = os.clock() - inMatchEnteredAt
					if elapsed < CFG.MATCH_SCAN_DELAY then
						setAction("Đang chờ vào trận ổn định để quét màn...")
						return
					end

					local stageRaw, stageKey, allowedSlot, lives = detectStageInMatch()
					if stageRaw then currentStageRaw = stageRaw end
					if stageKey then currentStageKey = stageKey end
					if lives ~= nil then lastLivesLeft = lives end

					stageLbl.Text = string.format("Màn: %s | Mạng: %s", tostring(currentStageRaw or "Đang quét..."), lastLivesLeft ~= nil and tostring(lastLivesLeft) or "?")

					if stageKey ~= nil and not allowedSlot then
						setAction(string.format("Màn '%s' ngoài 3 màn -> Đang Rejoin...", tostring(stageRaw)))
						triggerRejoin()
						return
					end

					if allowedSlot or elapsed >= CFG.STAGE_DETECT_TIMEOUT then
						matchVerifiedDone = true
					else
						setAction("Đang quét tên màn Kagoshima / Kyoto...")
						return
					end
				end

				stageLbl.Text = string.format("Màn: %s | Mạng: %s", tostring(currentStageRaw or currentStageKey or "Chưa rõ"), lastLivesLeft ~= nil and tostring(lastLivesLeft) or "?")

				if currentStageKey and ALLOWED_STAGES[currentStageKey] and startedMatchKey ~= currentStageKey then
					startedMatchKey = currentStageKey
					winToken += 1
					local myToken = winToken
					local isStillRunning = function() return active and winToken == myToken end

					if currentStageKey == "kagoshima 1" then
						task.spawn(function()
							runKagoshima1Win(setAction, isStillRunning)
						end)
					else
						local url = WIN_SCRIPT_URLS[currentStageKey]
						if typeof(url) == "string" and url ~= "" then
							setAction("Đang tải loadstring cho " .. currentStageKey .. "...")
							task.spawn(function()
								local okF, src = pcall(function() return game:HttpGet(url) end)
								if okF and typeof(src) == "string" and src ~= "" then
									local fn = loadstring(src)
									if fn then pcall(fn) end
								end
							end)
						else
							setAction(string.format("Quét trúng '%s' - Chưa dán link loadstring", currentStageKey))
						end
					end
				end
			end
		end)
		task.wait(CFG.LOOP_TICK)
	end
end)