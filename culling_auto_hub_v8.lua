local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local CoreGui = game:GetService("CoreGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Functions = ReplicatedStorage:WaitForChild("Functions")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- ================= CẤU HÌNH DANH SÁCH MÀN CHO PHÉP =================
local ALLOWED_STAGES = {
	["kagoshima 1"] = 1,
	["kagoshima 2"] = 2,
	["kyoto 1"] = 3,
}

local CFG = {
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

	-- Cấu hình script win dựa theo log SimpleSpy Kagoshima 1 ([1] -> [23])
	startupWait = 3.0,
	spawnWait = 1.35,
	upWait = 0.75,
	retryWait = 1.35,
	moneyTimeout = 4.0,
	autoStartWave = 7,
	autoLoopTick = 0.45,
	minTowerDist = 1.6,
	aiStep = 1.25,
	aiMaxRing = 4,
}

_G.CullingTestState = _G.CullingTestState or {
	currentStageRaw = nil,
	currentStageKey = nil,
	currentSlot = 1,
	lastLivesLeft = nil,
}
local STATE = _G.CullingTestState

-- ================= 1. XÁC ĐỊNH TIỀN & WAVE =================
local function parseNumber(val)
	if typeof(val) == "number" then return val end
	if typeof(val) ~= "string" then return nil end

	local clean = val:gsub(",", ""):gsub("%$", ""):gsub("%s+", "")
	local mult = 1
	local suffix = clean:match("[kKmMbBtT]$")
	if suffix then
		suffix = suffix:upper()
		if suffix == "K" then mult = 1e3
		elseif suffix == "M" then mult = 1e6
		elseif suffix == "B" then mult = 1e9
		elseif suffix == "T" then mult = 1e12 end
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
	if cur then
		return tonumber(cur), tonumber(total)
	end

	local wCur, wTotal = txt:match("[wW][aA][vV][eE]%s*:?%s*(%d+)%s*/%s*(%d+)")
	if wCur then
		return tonumber(wCur), tonumber(wTotal)
	end

	if strictPairOnly then
		return nil, nil
	end

	local single = txt:match("[sS][oó][nN][gG]%s*:?%s*(%d+)")
		or txt:match("[wW][aA][vV][eE]%s*:?%s*(%d+)")
	if single then
		return tonumber(single), nil
	end

	return nil, nil
end

local function getCurrentWave()
	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" then
			if obj.Name == "Wave" or obj.Name == "Sóng" then
				local cur, total = parseWaveText(obj.Text, false)
				if cur then
					return cur, total, obj.Text
				end
			end
		end
	end

	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" then
			local ltxt = obj.Text:lower()
			if ltxt:find("sóng") or ltxt:find("wave") then
				local cur, total = parseWaveText(obj.Text, true)
				if cur then
					return cur, total, obj.Text
				end
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

-- ================= 3. QUÉT & XÁC ĐỊNH KAGOSHIMA / KYOTO CHÍNH XÁC =================
local function normalizeStageKey(rawName)
	if typeof(rawName) ~= "string" or rawName == "" then return nil end
	local clean = rawName
		:gsub("[%c%z]", " ")
		:gsub("%s+", " ")
		:gsub("^%s+", "")
		:gsub("%s+$", "")
		:lower()
	if clean == "" then return nil end

	local area, num = clean:match("^(kagoshima)%s*[-:#/]?%s*(%d+)$")
	if not area then
		area, num = clean:match("^(kyoto)%s*[-:#/]?%s*(%d+)$")
	end
	if area and num then
		return area .. " " .. tostring(tonumber(num))
	end

	area, num = clean:match("(kagoshima)%s*[-:#/]?%s*(%d+)")
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
		if cur:IsA("GuiObject") and not cur.Visible then
			return false
		end
		if cur:IsA("LayerCollector") and not cur.Enabled then
			return false
		end
		cur = cur.Parent
	end
	return true
end

local function detectStageInMatch()
	local stageRaw = nil
	local livesLeft = nil
	local fallbackAllowedRaw = nil
	local fallbackOtherRaw = nil

	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" and isStageUiVisible(obj) then
			local clean = obj.Text:gsub("[%c%z]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
			if obj.Name == "ColonyName" and clean ~= "" then
				local extracted = extractStageCandidateFromText(clean)
				stageRaw = extracted or clean
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

-- ================= 4. TP, ĐI BỘ, TƯƠNG TÁC, BẮT ĐẦU & REJOIN =================
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
		if not curRoot or not curHum then
			return false
		end

		local dist = (curRoot.Position - targetPos).Magnitude
		if dist <= CFG.ARRIVAL_DIST then
			return true
		end

		if os.clock() - startClock >= CFG.WALK_TIMEOUT then
			return false
		end

		if os.clock() - lastMoveCmd >= 0.25 then
			lastMoveCmd = os.clock()
			local dir = (targetPos - curRoot.Position)
			local stepVec = dir.Magnitude > 5 and (dir.Unit * 5) or dir
			local nextGoal = Vector3.new(curRoot.Position.X + stepVec.X, targetPos.Y, curRoot.Position.Z + stepVec.Z)

			pcall(function()
				curHum.PlatformStand = false
				if curHum.WalkSpeed < 16 then
					curHum.WalkSpeed = 16
				end
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
	if parent:IsA("Attachment") then
		return parent.WorldPosition
	elseif parent:IsA("BasePart") then
		return parent.Position
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
	return pcall(function()
		fireproximityprompt(prompt)
	end)
end

local function fireTryToStart()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local cgtRemotes = remotes and remotes:FindFirstChild("CullingGamesTeleporters")
	local tryToStart = cgtRemotes and cgtRemotes:FindFirstChild("TryToStart")
	local teleporters = workspace:FindFirstChild("CullingGamesTeleporters")
	local elevator = teleporters and teleporters:FindFirstChild(CFG.ELEVATOR_NAME)

	if tryToStart and elevator then
		return pcall(function()
			tryToStart:FireServer(elevator)
		end)
	end
	return false
end

local lastRejoinTick = 0
local function triggerRejoin()
	if os.clock() - lastRejoinTick < CFG.REJOIN_COOLDOWN then
		return false
	end
	lastRejoinTick = os.clock()
	return pcall(function()
		if game.JobId and game.JobId ~= "" then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
		else
			TeleportService:Teleport(game.PlaceId, player)
		end
	end)
end

-- ================= 5. SCRIPT WIN DỰA THEO LOG SIMPLESPY (KAGOSHIMA 1) =================
-- Lưu ý log SimpleSpy:
-- [1] ChooseModifiers: FireServer(1, false)
-- [2] SpawnNewTower("3a4f9c5c-dcfc-46aa-ad1e-be37e88c9c66", cf)
-- [3] SpawnNewTower("be8f9440-55fc-4aa6-9317-0b5581a076f6", cf)  -- bỏ log [4] Click trùng
-- [5] SpawnNewTower("be8f9440-55fc-4aa6-9317-0b5581a076f6", cf)  -- bỏ log [6] SpawnNewTower trùng
-- [7] UpgradeTower(workspace.Towers.SorcererAgent)
-- [8] SpawnNewTower("be8f9440-55fc-4aa6-9317-0b5581a076f6", cf)  -- bỏ log [9] UpgradeTower sai tham số (towerId + cf)
-- [10]..[11] UpgradeTower(workspace.Towers.SorcererAgent)
-- [12] SpawnNewTower("348f2cd1-e2e9-48c8-a13b-589f09bc0654", cf)
-- [13]..[16] UpgradeTower(SoulCurse / SorcererAgent2 / SorcererAgent3 / SorcererAgent2)
-- [17] VoteSkip: FireServer()
-- [18] SpawnNewTower("a7976e77-c58a-44c6-bde9-d9710fd14ac2", cf)
-- [19]..[23] UpgradeTower(SoulCurse2 / SorcererAgent2 / SoulCurse3 / FingerBearerAwk / FingerBearerAwk2)

local SPY_STEPS = {
	{ stepId = 2, action = "spawn", towerId = "3a4f9c5c-dcfc-46aa-ad1e-be37e88c9c66", cf = CFrame.new(4.864310264587402, 47.32311248779297, -121.51627349853516) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 3, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-25.062589645385742, 47.15073776245117, -107.02923583984375) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 5, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-26.276447296142578, 47.150733947753906, -111.41389465332031) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 7, action = "upgrade", targetName = "SorcererAgent" },
	{ stepId = 8, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-15.050935745239258, 47.15073776245117, -108.41059875488281) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 10, action = "upgrade", targetName = "SorcererAgent" },
	{ stepId = 11, action = "upgrade", targetName = "SorcererAgent" },
	{ stepId = 12, action = "spawn", towerId = "348f2cd1-e2e9-48c8-a13b-589f09bc0654", cf = CFrame.new(22.122488021850586, 47.150047302246094, -121.02806091308594) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 13, action = "upgrade", targetName = "SoulCurse" },
	{ stepId = 14, action = "upgrade", targetName = "SorcererAgent2" },
	{ stepId = 15, action = "upgrade", targetName = "SorcererAgent3" },
	{ stepId = 16, action = "upgrade", targetName = "SorcererAgent2" },
	{ stepId = 17, action = "skip" },
	{ stepId = 18, action = "spawn", towerId = "a7976e77-c58a-44c6-bde9-d9710fd14ac2", cf = CFrame.new(26.937042236328125, 47.16230010986328, -117.86810302734375) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) },
	{ stepId = 19, action = "upgrade", targetName = "SoulCurse2" },
	{ stepId = 20, action = "upgrade", targetName = "SorcererAgent2" },
	{ stepId = 21, action = "upgrade", targetName = "SoulCurse3" },
	{ stepId = 22, action = "upgrade", targetName = "FingerBearerAwk" },
	{ stepId = 23, action = "upgrade", targetName = "FingerBearerAwk2" },
}

local AUTO_UPGRADE_LOOP = {
	"FingerBearerAwk2",
	"FingerBearerAwk",
	"SoulCurse3",
	"SoulCurse2",
	"SoulCurse",
	"SorcererAgent3",
	"SorcererAgent2",
	"SorcererAgent",
}

local function createWinRunner(stageTitle, activeRef)
	return function(setStatus)
		local winActive = true
		local function isRunning()
			return winActive and activeRef() and detectEnvironment() == "IN_MATCH"
		end

		local function setWinStep(t)
			if isRunning() and setStatus then
				setStatus(string.format("[%s] %s", stageTitle, tostring(t)))
			end
		end

		local aiMem = { badPos = {}, bestDirById = {} }
		local DIRS = { {1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {1,-1}, {-1,1}, {-1,-1} }

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

		local function isPosNearTower(pos)
			for _, t in ipairs(allTowers()) do
				local tp = getTowerPos(t)
				if tp and (Vector3.new(tp.X, pos.Y, tp.Z) - Vector3.new(pos.X, pos.Y, pos.Z)).Magnitude < CFG.minTowerDist then
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

		local function moneyDropped(before)
			if before == nil then return false end
			local dl = os.clock() + CFG.moneyTimeout
			while isRunning() and os.clock() < dl do
				task.wait(0.1)
				local now = getCurrentMoney()
				if now and now < before then return true end
			end
			return false
		end

		local function aiPickCf(baseCf, towerId, idx)
			local _, rx, ry, rz = baseCf:ToEulerAnglesXYZ()
			local p = baseCf.Position

			if idx <= 1 and not isPosNearTower(p) and not aiMem.badPos[posKey(baseCf)] then
				return baseCf, nil
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
					if not aiMem.badPos[posKey(cand)] then
						if not fallbackCand then
							fallbackCand, fallbackDir = cand, d
						end
						if not isPosNearTower(cand.Position) then
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
			if cm then
				pcall(function()
					cm:FireServer(1, false)
				end)
			end
		end

		local function voteSkip()
			local vs = Remotes:FindFirstChild("VoteSkip")
			if vs then
				pcall(function()
					if vs:IsA("RemoteEvent") then
						vs:FireServer()
					elseif vs:IsA("RemoteFunction") then
						vs:InvokeServer()
					end
				end)
			end
		end

		local function doSpawn(id, cf, lbl)
			local tries = 0
			while isRunning() do
				tries += 1
				local targetCf, usedDir = aiPickCf(cf, id, tries)
				local m0 = getCurrentMoney()
				local prev = {}
				for _, t in ipairs(allTowers()) do prev[t] = true end

				local ok, res = pcall(function()
					return Functions.SpawnNewTower:InvokeServer(id, targetCf)
				end)
				local drop = moneyDropped(m0)
				local spawned = (typeof(res) == "Instance")
				if not spawned then
					for _, t in ipairs(allTowers()) do
						if not prev[t] then
							spawned = true
							break
						end
					end
				end

				local shifted = (targetCf.Position - cf.Position).Magnitude > 0.05
				setWinStep(string.format("%s [#%d%s | -tiền=%s]", lbl, tries, shifted and " | ĐỔI VỊ TRÍ" or "", tostring(drop)))

				if ok and res ~= false and (drop or spawned) then
					if usedDir then aiMem.bestDirById[tostring(id or "")] = usedDir end
					task.wait(CFG.spawnWait)
					return true
				end

				if m0 == nil or m0 >= 100 then
					aiMem.badPos[posKey(targetCf)] = true
				end
				if tries % 16 == 0 then
					aiMem.badPos = {}
				end

				task.wait(CFG.retryWait)
			end
			return false
		end

		local function doUpgrade(name, lbl)
			local tries = 0
			while isRunning() and tries < 6 do
				tries += 1
				local tgt = findTower(name)
				if not tgt then
					setWinStep(string.format("%s [chờ %s]", lbl, tostring(name)))
					task.wait(CFG.retryWait)
					continue
				end

				local m0 = getCurrentMoney()
				local ok, res = pcall(function()
					return Functions.UpgradeTower:InvokeServer(tgt)
				end)
				local drop = moneyDropped(m0)
				setWinStep(string.format("%s #%d (-tiền=%s)", lbl, tries, tostring(drop)))

				if ok and res ~= false and drop then
					task.wait(CFG.upWait)
					return true
				end

				task.wait(CFG.retryWait)
			end
			return false
		end

		local t0 = os.clock()
		while isRunning() and (os.clock() - t0) < CFG.startupWait do
			setWinStep(string.format("Đợi %.1fs load xong...", math.max(0, CFG.startupWait - (os.clock() - t0))))
			task.wait(0.1)
		end

		if not isRunning() then return end

		-- [1] ChooseModifiers
		chooseModifiers()
		setWinStep("[1] Đã chọn Modifier, bắt đầu chạy chuỗi [2] -> [23]...")

		for i, s in ipairs(SPY_STEPS) do
			if not isRunning() then break end
			local tag = "#" .. (s.stepId or i)
			if s.action == "spawn" then
				doSpawn(s.towerId, s.cf, tag .. " Đặt")
			elseif s.action == "upgrade" then
				doUpgrade(s.targetName, tag .. " Nâng " .. tostring(s.targetName))
			elseif s.action == "skip" then
				voteSkip()
				setWinStep(tag .. " VoteSkip")
				task.wait(0.5)
			end
		end

		while isRunning() do
			local w = getCurrentWave()
			if w and w >= CFG.autoStartWave then
				voteSkip()
				for _, tName in ipairs(AUTO_UPGRADE_LOOP) do
					if not isRunning() then break end
					local curW = getCurrentWave()
					if not curW or curW < CFG.autoStartWave then break end
					doUpgrade(tName, "Auto W7+ Nâng " .. tName)
					task.wait(0.25)
				end
			else
				setWinStep(string.format("Chờ Wave %d để auto nâng & skip (nay: %s)", CFG.autoStartWave, tostring(w)))
			end
			task.wait(CFG.autoLoopTick)
		end

		winActive = false
	end
end

local STAGE_RUNNERS = {
	["kagoshima 1"] = createWinRunner("Kagoshima 1", function() return _G.CullingHudActive == true end),
	["kagoshima 2"] = createWinRunner("Kagoshima 2", function() return _G.CullingHudActive == true end),
	["kyoto 1"] = createWinRunner("Kyoto 1", function() return _G.CullingHudActive == true end),
}

-- ================= 6. BẢNG TIỀN & WAVE + MENU NHỎ KÉO THẢ ĐƯỢC =================
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
sg.Name = "CullingAutoTestGui"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 999999
pcall(function()
	attachGui(sg)
end)

local statsBox = Instance.new("Frame")
statsBox.Size = UDim2.fromOffset(215, 56)
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
moneyLbl.TextTruncate = Enum.TextTruncate.AtEnd
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
waveLbl.TextTruncate = Enum.TextTruncate.AtEnd
waveLbl.Text = "Wave: ..."
waveLbl.Parent = statsBox

local menuBox = Instance.new("Frame")
menuBox.Size = UDim2.fromOffset(285, 86)
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
modeLbl.TextTruncate = Enum.TextTruncate.AtEnd
modeLbl.Text = "Chế độ: Đang kiểm tra..."
modeLbl.Parent = menuBox

local stageLbl = Instance.new("TextLabel")
stageLbl.Size = UDim2.new(1, -14, 0, 20)
stageLbl.Position = UDim2.fromOffset(7, 24)
stageLbl.BackgroundTransparency = 1
stageLbl.Font = Enum.Font.SourceSansBold
stageLbl.TextSize = 12
stageLbl.TextColor3 = Color3.fromRGB(220, 175, 255)
stageLbl.TextXAlignment = Enum.TextXAlignment.Left
stageLbl.TextTruncate = Enum.TextTruncate.AtEnd
stageLbl.Text = "Màn: Đợi vào trận..."
stageLbl.Parent = menuBox

local actionLbl = Instance.new("TextLabel")
actionLbl.Size = UDim2.new(1, -14, 0, 32)
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
_G.CullingHudActive = true
_G.CullingFullHudStop = function()
	active = false
	_G.CullingHudActive = false
	if sg then
		sg:Destroy()
	end
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

			if money ~= nil then
				moneyLbl.Text = string.format("Tiền: %s (%s)", tostring(money), tostring(moneyRaw or money))
			else
				moneyLbl.Text = "Tiền: 0 (chưa thấy)"
			end

			if wave ~= nil then
				waveLbl.Text = maxWave ~= nil
					and string.format("Wave: %d/%d", wave, maxWave)
					or string.format("Wave: %d", wave)
			else
				waveLbl.Text = "Wave: Sảnh / Chưa có"
			end
		end)
		task.wait(0.25)
	end
end)

-- ================= 7. VÒNG LẶP ĐIỀU PHỐI CHÍNH =================
task.spawn(function()
	local gate1Passed = false
	local tp2Done = false
	local walkToFinalDone = false
	local isWalkingNow = false
	local lastInteractTick = 0
	local lastStartTick = 0
	local inMatchEnteredAt = nil
	local matchVerifiedDone = false
	local startedMatchKey = nil

	while active do
		pcall(function()
			local env = detectEnvironment()
			modeLbl.Text = env == "LOBBY" and "Vị trí: Ở SẢNH" or "Vị trí: TRONG TRẬN"

			if env == "LOBBY" then
				inMatchEnteredAt = nil
				matchVerifiedDone = false
				startedMatchKey = nil
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
					gate1Passed = true
					tp2Done = true
					walkToFinalDone = true
				elseif distTp2 <= CFG.ARRIVAL_DIST then
					gate1Passed = true
					tp2Done = true
				end

				if not gate1Passed then
					if distGate1 > CFG.ARRIVAL_DIST then
						if lastInteractTick > 0 and distGate1 >= CFG.TELEPORT_AWAY_DIST then
							gate1Passed = true
							tp2Done = false
							walkToFinalDone = false
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
						setAction(fired
							and "Đã gửi Bắt đầu, đợi vào trận..."
							or "Chờ Elevator5 / TryToStart sẵn sàng...")
					end
				end

			elseif env == "IN_MATCH" then
				gate1Passed = false
				tp2Done = false
				walkToFinalDone = false
				isWalkingNow = false
				lastInteractTick = 0

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
					if stageRaw then STATE.currentStageRaw = stageRaw end
					if stageKey then STATE.currentStageKey = stageKey end
					if allowedSlot then STATE.currentSlot = allowedSlot end
					if lives ~= nil then STATE.lastLivesLeft = lives end

					stageLbl.Text = string.format(
						"Màn: %s | Mạng: %s",
						tostring(STATE.currentStageRaw or "Đang quét..."),
						STATE.lastLivesLeft ~= nil and tostring(STATE.lastLivesLeft) or "?"
					)

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

				local activeKey = STATE.currentStageKey or "kagoshima 1"
				stageLbl.Text = string.format(
					"Màn: %s | Mạng: %s",
					tostring(STATE.currentStageRaw or activeKey),
					STATE.lastLivesLeft ~= nil and tostring(STATE.lastLivesLeft) or "?"
				)

				if startedMatchKey ~= activeKey then
					startedMatchKey = activeKey
					local runner = STAGE_RUNNERS[activeKey]
					if runner then
						task.spawn(function()
							runner(setAction)
						end)
					else
						setAction("Trong trận " .. tostring(activeKey))
					end
				end
			end
		end)

		task.wait(CFG.LOOP_TICK)
	end
end)
