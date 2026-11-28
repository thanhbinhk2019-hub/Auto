local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

if not game:IsLoaded() then game.Loaded:Wait() end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Tắt bản cũ đang chạy (kể cả script win chạy riêng) để không bị đặt trùng
if _G.CullingFullHudStop then pcall(_G.CullingFullHudStop) end
if _G.SeqSkipHudStop then pcall(_G.SeqSkipHudStop) end

-- ================= CẤU HÌNH =================
local CFG = {
	LOBBY_GATE_1 = Vector3.new(-155.45, 17.40, 2933.06),
	CULLING_TP2_POS = Vector3.new(5.52, -128.12, 2926.15),
	CULLING_WALK_POS = Vector3.new(17.46, -127.61, 2926.01),
	-- Gửi lệnh bắt đầu cho từng thang máy trong danh sách
	-- (Elevator4: theo SimpleSpy mới, Elevator5: theo script cũ)
	ELEVATOR_NAMES = { "Elevator4", "Elevator5" },

	ARRIVAL_DIST = 5.5,
	TELEPORT_AWAY_DIST = 25,
	WALK_TIMEOUT = 16,
	MATCH_SCAN_DELAY = 1.5,
	START_RETRY_DELAY = 2.5,
	START_REMOTE_GAP = 0.5,
	LOOP_TICK = 0.35,

	MOD_WAIT = 10,       -- trong trận mà quá từng này giây chưa thấy số wave thì mới bật modifier
	MOD_RETRY = 3,       -- gửi lại mỗi từng này giây cho tới khi thấy số wave
	LOBBY_FALLBACK = 60, -- không thấy thư mục sảnh, chờ quá lâu vẫn không có wave thì coi như ở sảnh

	WAVE_CONFIRM_READS = 4,  -- đọc cùng 1 tổng wave đủ số lần này mới chốt (tránh đọc nhầm lúc load)
	LOBBY_CONFIRM_TIME = 10, -- đã chốt script win thì phải thấy sảnh liên tục từng này giây mới reset
	SHUTDOWN_DELAY = 3,      -- wave lạ: hiện thông báo từng này giây rồi tự tắt
}

-- Cấu hình chung của script win (skipMin riêng từng script, xem WIN_PLANS)
local WIN_CFG = {
	startupWait = 3.0,
	skipMax = 999, skipTick = 0.35,
	spawnWait = 2.0, upWait = 0.9, retryWait = 1.8,
	moneyTimeout = 4.0,
	aiMoney = 2000, aiStep = 1.25, aiMaxRing = 3, minTowerDist = 1.6,
}

_G.CullingTestState = _G.CullingTestState or {
	currentStageRaw = nil,
	lastLivesLeft = nil,
}
local STATE = _G.CullingTestState

local HUD_NAME = "CullingAutoTestGui"
local active = true

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

-- Đổi "Sóng"/"SÓNG"/"Song" thành "wave" và bỏ thẻ RichText.
-- (Mẫu [oó] của script cũ so theo từng byte nên không khớp được chữ "ó" có dấu.)
local function normalizeWaveText(txt)
	local s = txt:gsub("<[^<>]->", ""):lower()
	return (s:gsub("sÓng", "wave"):gsub("sóng", "wave"):gsub("song", "wave"))
end

local function parseWaveText(txt, strictPairOnly)
	if typeof(txt) ~= "string" or txt == "" then return nil, nil end
	local s = normalizeWaveText(txt)

	-- chữ phần thưởng / thành tích, không phải bộ đếm wave của trận
	local low = txt:lower()
	if low:find("waves") or low:find("reward") or low:find("beaten") then
		return nil, nil
	end

	local cur, total = s:match("wave%s*:?%s*(%d+)%s*/%s*(%d+)")
	if cur then
		return tonumber(cur), tonumber(total)
	end

	if strictPairOnly then
		return nil, nil
	end

	-- nhãn tên Wave/Sóng có khi chỉ ghi "3/10"
	cur, total = s:match("(%d+)%s*/%s*(%d+)")
	if cur then
		return tonumber(cur), tonumber(total)
	end

	local single = s:match("wave%s*:?%s*(%d+)")
	if single then
		return tonumber(single), nil
	end

	return nil, nil
end

local function isShown(obj)
	while obj and obj ~= playerGui do
		if obj:IsA("GuiObject") and not obj.Visible then return false end
		if obj:IsA("LayerCollector") and not obj.Enabled then return false end
		obj = obj.Parent
	end
	return true
end

-- Chọn nhãn đáng tin nhất: có tổng wave > đang hiện trên màn hình > tên Wave/Sóng
local function getCurrentWave()
	local best, bestCur, bestTotal, bestText = 0, nil, nil, nil
	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" then
			local named = obj.Name == "Wave" or obj.Name == "Sóng"
			-- bỏ qua bảng của chính script này (tránh tự đọc lại số mình vừa hiện)
			if (named or obj.Text:find("/", 1, true)) and not obj:FindFirstAncestor(HUD_NAME) then
				local cur, total = parseWaveText(obj.Text, not named)
				if cur then
					local score = 1 + (total and 4 or 0) + (isShown(obj) and 2 or 0) + (named and 1 or 0)
					if score > best then
						best, bestCur, bestTotal, bestText = score, cur, total, obj.Text
					end
				end
			end
		end
	end

	return bestCur, bestTotal, bestText
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

-- ================= 3. QUÉT MÀN KHI ĐÃ VÀO TRẬN =================
local function detectStageInMatch()
	local stageRaw = nil
	local livesLeft = nil

	for _, obj in ipairs(playerGui:GetDescendants()) do
		if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" then
			local clean = obj.Text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
			if obj.Name == "ColonyName" and clean ~= "" then
				stageRaw = clean
			elseif obj.Name == "LivesLeft" then
				local n = clean:match("(%d+)")
				if n then livesLeft = tonumber(n) end
			end
		end
	end

	if not stageRaw then
		for _, obj in ipairs(playerGui:GetDescendants()) do
			if (obj:IsA("TextLabel") or obj:IsA("TextButton")) and obj.Text ~= "" then
				local clean = obj.Text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
				local low = clean:lower()
				if low:match("^kagoshima%s*%d+$") or low:match("^kyoto%s*%d+$") or low:match("^sendai%s*%d+$") or low:match("^tokyo%s*%d+$") then
					stageRaw = clean
					break
				end
			end
		end
	end

	return stageRaw, livesLeft
end

-- ================= 4. TP, ĐI BỘ, TƯƠNG TÁC, BẮT ĐẦU =================
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

-- Gửi TryToStart rồi Start (đúng 2 lệnh trong SimpleSpy) cho từng thang máy
local function fireStartRemotes()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local cgtRemotes = remotes and remotes:FindFirstChild("CullingGamesTeleporters")
	if not cgtRemotes then return false end

	local sent = false
	for _, elevatorName in ipairs(CFG.ELEVATOR_NAMES) do
		for _, remoteName in ipairs({ "TryToStart", "Start" }) do
			local teleporters = workspace:FindFirstChild("CullingGamesTeleporters")
			local elevator = teleporters and teleporters:FindFirstChild(elevatorName)
			local remote = cgtRemotes:FindFirstChild(remoteName)
			if active and elevator and remote then
				if pcall(function() remote:FireServer(elevator) end) then
					sent = true
				end
				task.wait(CFG.START_REMOTE_GAP)
			end
		end
	end
	return sent
end

-- Màn 10 wave và 1 trong 2 màn 15 wave: phải bật modifier game mới hiện số wave
local function fireModifier()
	local ok, sent = pcall(function()
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local cg = remotes and remotes:FindFirstChild("CullingGames")
		local cm = cg and cg:FindFirstChild("ChooseModifiers")
		if not cm then return false end
		cm:FireServer(1, false)
		return true
	end)
	return ok and sent
end

-- ================= 5. BỘ CHẠY SCRIPT WIN =================
local aiDirs = { {1,0}, {-1,0}, {0,1}, {0,-1}, {1,1}, {1,-1}, {-1,1}, {-1,-1} }

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
		if tp and (Vector3.new(tp.X, pos.Y, tp.Z) - Vector3.new(pos.X, pos.Y, pos.Z)).Magnitude < WIN_CFG.minTowerDist then
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
	for _, d in ipairs(f:GetDescendants()) do if d.Name == name then return d end end
	local pre = name:match("^(.-)%d+$") or name
	for _, c in ipairs(f:GetChildren()) do if c.Name == pre or c.Name:sub(1, #pre) == pre then return c end end
	return nil
end

local function moneyDropped(ctx, before)
	if before == nil then return false end
	local dl = os.clock() + WIN_CFG.moneyTimeout
	while ctx.alive() and os.clock() < dl do
		task.wait(0.1)
		local now = getCurrentMoney()
		if now and now < before then return true end
	end
	return false
end

local function aiPickCf(aiMem, baseCf, towerId, idx)
	if idx <= 1 then return baseCf, nil end
	local list = {}
	local fav = aiMem.bestDirById[tostring(towerId or "")]
	if fav then table.insert(list, fav) end
	for _, d in ipairs(aiDirs) do
		if not fav or d[1] ~= fav[1] or d[2] ~= fav[2] then table.insert(list, d) end
	end
	local fallbackCand, fallbackDir
	for ring = 1, WIN_CFG.aiMaxRing do
		for _, d in ipairs(list) do
			local rx, ry, rz = baseCf:ToEulerAnglesXYZ()
			local p = baseCf.Position
			local cand = CFrame.new(p.X + d[1] * ring * WIN_CFG.aiStep, p.Y, p.Z + d[2] * ring * WIN_CFG.aiStep) * CFrame.Angles(rx, ry, rz)
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
	local d = list[((idx - 2) % #list) + 1]
	local rx, ry, rz = baseCf:ToEulerAnglesXYZ()
	local p = baseCf.Position
	return CFrame.new(p.X + d[1] * WIN_CFG.aiStep, p.Y, p.Z + d[2] * WIN_CFG.aiStep) * CFrame.Angles(rx, ry, rz), d
end

local function doModifier(ctx, lbl)
	pcall(function()
		local cg = ctx.remotes:FindFirstChild("CullingGames")
		local cm = cg and cg:FindFirstChild("ChooseModifiers")
		if cm then cm:FireServer(1, false) end
	end)
	ctx.setStep(lbl)
	task.wait(0.5)
	return true
end

local function doSpawn(ctx, id, cf, lbl)
	local tries, nIdx = 0, 1
	while ctx.alive() do
		tries += 1
		local m0 = getCurrentMoney()
		local useAi = (m0 ~= nil) and (m0 > WIN_CFG.aiMoney) and (tries > 1)
		local usedDir
		local targetCf = cf
		if useAi then
			nIdx += 1
			targetCf, usedDir = aiPickCf(ctx.aiMem, cf, id, nIdx)
		end

		local prev = {}
		for _, t in ipairs(allTowers()) do prev[t] = true end
		local ok, res = pcall(function() return ctx.functions.SpawnNewTower:InvokeServer(id, targetCf) end)
		local drop = moneyDropped(ctx, m0)
		local spawned = (typeof(res) == "Instance")
		if not spawned then
			for _, t in ipairs(allTowers()) do if not prev[t] then spawned = true; break end end
		end

		ctx.setStep(string.format("%s [#%d | -tiền=%s%s]", lbl, tries, tostring(drop), useAi and (" | AI#" .. (nIdx - 1)) or ""))
		if ok and res ~= false and (drop or (m0 == nil and spawned)) then
			if usedDir then ctx.aiMem.bestDirById[tostring(id or "")] = usedDir end
			task.wait(WIN_CFG.spawnWait)
			return true
		end

		if useAi then ctx.aiMem.badPos[posKey(targetCf)] = true end
		task.wait(WIN_CFG.retryWait)
	end
	return false
end

local function doUpgrade(ctx, name, lbl)
	local tries = 0
	while ctx.alive() do
		tries += 1
		local tgt = findTower(name)
		if not tgt then
			ctx.setStep(string.format("%s [chờ %s]", lbl, tostring(name)))
			task.wait(WIN_CFG.retryWait)
			continue
		end

		local m0 = getCurrentMoney()
		local ok, res = pcall(function() return ctx.functions.UpgradeTower:InvokeServer(tgt) end)
		local drop = moneyDropped(ctx, m0)
		ctx.setStep(string.format("%s [#%d | -tiền=%s]", lbl, tries, tostring(drop)))

		if ok and res ~= false and drop then
			task.wait(WIN_CFG.upWait)
			return true
		end

		task.wait(WIN_CFG.retryWait)
	end
	return false
end

local function doSell(ctx, name, lbl)
	local tries = 0
	while ctx.alive() do
		tries += 1
		local tgt = findTower(name)
		if not tgt then
			ctx.setStep(string.format("%s [chờ %s]", lbl, tostring(name)))
			task.wait(WIN_CFG.retryWait)
			continue
		end

		local ok = pcall(function() return ctx.functions.SellTower:InvokeServer(tgt) end)
		ctx.setStep(string.format("%s [#%d | ok=%s]", lbl, tries, tostring(ok)))
		if ok then
			task.wait(WIN_CFG.upWait)
			return true
		end
		task.wait(WIN_CFG.retryWait)
	end
	return false
end

local function startWinPlan(plan, setStatus)
	local ctx = { dead = false, aiMem = { badPos = {}, bestDirById = {} } }
	ctx.alive = function() return active and not ctx.dead end
	ctx.setStep = function(t)
		if ctx.alive() then setStatus("[" .. plan.tag .. "] " .. tostring(t)) end
	end

	task.spawn(function()
		ctx.functions = ReplicatedStorage:WaitForChild("Functions", 15)
		ctx.remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
		if not ctx.functions or not ctx.remotes then
			ctx.setStep("Lỗi: không thấy Functions / Remotes")
			return
		end

		-- Skip liên tục từ wave plan.skipMin trở đi
		task.spawn(function()
			while ctx.alive() do
				pcall(function()
					local w = getCurrentWave()
					if w and w >= plan.skipMin and w <= WIN_CFG.skipMax then
						local vs = ctx.remotes:FindFirstChild("VoteSkip")
						if vs and vs:IsA("RemoteEvent") then vs:FireServer()
						elseif vs and vs:IsA("RemoteFunction") then vs:InvokeServer() end
					end
				end)
				task.wait(WIN_CFG.skipTick)
			end
		end)

		local t0 = os.clock()
		while ctx.alive() and (os.clock() - t0) < WIN_CFG.startupWait do
			ctx.setStep(string.format("Đợi %.1fs rồi đặt...", math.max(0, WIN_CFG.startupWait - (os.clock() - t0))))
			task.wait(0.1)
		end
		for i, s in ipairs(plan.steps) do
			if not ctx.alive() then break end
			local tag = "#" .. (s.stepId or i)
			if s.action == "modifier" then
				local l = tag .. " Modifiers"; ctx.setStep(l); doModifier(ctx, l)
			elseif s.action == "spawn" then
				local l = tag .. " Đặt"; ctx.setStep(l); doSpawn(ctx, s.towerId, s.cf, l)
			elseif s.action == "upgrade" then
				local l = tag .. " Nâng (" .. tostring(s.targetName) .. ")"; ctx.setStep(l); doUpgrade(ctx, s.targetName, l)
			elseif s.action == "sell" then
				local l = tag .. " Bán (" .. tostring(s.targetName) .. ")"; ctx.setStep(l); doSell(ctx, s.targetName, l)
			end
		end
		ctx.setStep("Xong hết các bước!")
	end)

	return ctx
end

-- ================= 6. DANH SÁCH BƯỚC CỦA TỪNG SCRIPT WIN =================
-- ----- 10 WAVE (win_script_3) -----
local STEPS_10 = {
	{ stepId = 1, action = "modifier" }, -- Log #2
	{ stepId = 2, action = "spawn", towerId = "3a4f9c5c-dcfc-46aa-ad1e-be37e88c9c66", cf = CFrame.new(3.052806854248047, 47.32311248779297, -121.86878967285156) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #8
	{ stepId = 3, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-18.27460479736328, 47.150733947753906, -116.57414245605469) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #17
	{ stepId = 4, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-17.32938003540039, 47.150733947753906, -121.06536865234375) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #27
	{ stepId = 5, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-26.21940040588379, 47.150733947753906, -115.45636749267578) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #33
	{ stepId = 6, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-25.963621139526367, 47.150733947753906, -121.269775390625) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #37
	{ stepId = 7, action = "upgrade", targetName = "SorcererAgent" }, -- Log #40
	{ stepId = 8, action = "upgrade", targetName = "SorcererAgent" }, -- Log #44
	{ stepId = 9, action = "upgrade", targetName = "SorcererAgent" }, -- Log #47
	{ stepId = 10, action = "upgrade", targetName = "SorcererAgent" }, -- Log #56
	{ stepId = 11, action = "spawn", towerId = "348f2cd1-e2e9-48c8-a13b-589f09bc0654", cf = CFrame.new(21.255033493041992, 47.150047302246094, -120.70836639404297) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #63
	{ stepId = 12, action = "upgrade", targetName = "SorcererAgent2" }, -- Log #99
	{ stepId = 13, action = "upgrade", targetName = "SorcererAgent2" }, -- Log #103
	{ stepId = 14, action = "spawn", towerId = "a7976e77-c58a-44c6-bde9-d9710fd14ac2", cf = CFrame.new(17.047821044921875, 47.150047302246094, -118.69709014892578) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #120
	{ stepId = 15, action = "upgrade", targetName = "SorcererAgent2" }, -- Log #129
	{ stepId = 16, action = "upgrade", targetName = "SorcererAgent3" }, -- Log #130
	{ stepId = 17, action = "upgrade", targetName = "SorcererAgent3" }, -- Log #139
	{ stepId = 18, action = "upgrade", targetName = "SoulCurse" }, -- Log #148
	{ stepId = 19, action = "sell", targetName = "FingerBearerAwk" }, -- Log #159
	{ stepId = 20, action = "upgrade", targetName = "StrongestSorcerer" }, -- Log #164
	{ stepId = 21, action = "upgrade", targetName = "SoulCurse2" }, -- Log #167
}

-- ----- 15 WAVE (win_script_wave8) -----
local STEPS_15 = {
	{ stepId = 1, action = "spawn", towerId = "3a4f9c5c-dcfc-46aa-ad1e-be37e88c9c66", cf = CFrame.new(8.750238418579102, 47.32311248779297, -119.43002319335938) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #9
	{ stepId = 2, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-21.148082733154297, 47.150733947753906, -112.11280822753906) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #19
	{ stepId = 3, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-14.196090698242188, 47.150733947753906, -113.06901550292969) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #22
	{ stepId = 4, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-16.41617202758789, 47.150733947753906, -117.56282043457031) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #25
	{ stepId = 5, action = "spawn", towerId = "be8f9440-55fc-4aa6-9317-0b5581a076f6", cf = CFrame.new(-10.647790908813477, 47.150733947753906, -117.10282897949219) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #30
	{ stepId = 6, action = "upgrade", targetName = "SorcererAgent" }, -- Log #39
	{ stepId = 7, action = "upgrade", targetName = "SorcererAgent" }, -- Log #43
	{ stepId = 8, action = "upgrade", targetName = "SorcererAgent" }, -- Log #51
	{ stepId = 9, action = "upgrade", targetName = "SorcererAgent" }, -- Log #55
	{ stepId = 10, action = "spawn", towerId = "3a4f9c5c-dcfc-46aa-ad1e-be37e88c9c66", cf = CFrame.new(-17.098573684692383, 47.32311248779297, -128.77828979492188) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #93
	{ stepId = 11, action = "spawn", towerId = "a7976e77-c58a-44c6-bde9-d9710fd14ac2", cf = CFrame.new(15.270208358764648, 47.150047302246094, -117.4284439086914) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #102
	{ stepId = 12, action = "upgrade", targetName = "SorcererAgent2" }, -- Log #118
	{ stepId = 13, action = "upgrade", targetName = "SorcererAgent2" }, -- Log #121
	{ stepId = 14, action = "upgrade", targetName = "SorcererAgent3" }, -- Log #129
	{ stepId = 15, action = "upgrade", targetName = "SorcererAgent2" }, -- Log #135
	{ stepId = 16, action = "upgrade", targetName = "SorcererAgent2" }, -- Log #138
	{ stepId = 17, action = "upgrade", targetName = "SorcererAgent3" }, -- Log #147
	{ stepId = 18, action = "upgrade", targetName = "SorcererAgent3" }, -- Log #160
	{ stepId = 19, action = "upgrade", targetName = "SorcererAgent4" }, -- Log #175
	{ stepId = 20, action = "upgrade", targetName = "SorcererAgent4" }, -- Log #184
	{ stepId = 21, action = "spawn", towerId = "348f2cd1-e2e9-48c8-a13b-589f09bc0654", cf = CFrame.new(16.377321243286133, 47.150047302246094, -121.58635711669922) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #196
	{ stepId = 22, action = "upgrade", targetName = "SoulCurse" }, -- Log #199
	{ stepId = 23, action = "upgrade", targetName = "SoulCurse2" }, -- Log #200
	{ stepId = 24, action = "upgrade", targetName = "SoulCurse2" }, -- Log #201
	{ stepId = 25, action = "upgrade", targetName = "StrongestSorcerer" }, -- Log #204
	{ stepId = 26, action = "sell", targetName = "FingerBearerAwk" }, -- Log #209
	{ stepId = 27, action = "spawn", towerId = "3a4f9c5c-dcfc-46aa-ad1e-be37e88c9c66", cf = CFrame.new(-11.85224723815918, 47.32311248779297, -122.52899169921875) * CFrame.Angles(-3.1415927410125732, -8.742277657347586e-08, -3.1415927410125732) }, -- Log #217
	{ stepId = 28, action = "upgrade", targetName = "SorcererAgent4" }, -- Log #224
	{ stepId = 29, action = "upgrade", targetName = "SorcererAgent3" }, -- Log #238
	{ stepId = 30, action = "upgrade", targetName = "SorcererAgent4" }, -- Log #239
	{ stepId = 31, action = "upgrade", targetName = "SoulCurse3" }, -- Log #271
	{ stepId = 32, action = "upgrade", targetName = "StrongestSorcerer2" }, -- Log #286
	{ stepId = 33, action = "upgrade", targetName = "StrongestSorcerer3" }, -- Log #299
	{ stepId = 34, action = "upgrade", targetName = "StrongestSorcerer4" }, -- Log #313
	{ stepId = 35, action = "upgrade", targetName = "SoulCurse4" }, -- Log #319
}

-- ----- 15 WAVE CÓ MODIFIER: CHƯA CÓ -> dán các bước vào giữa 2 dấu { } (cùng định dạng như trên) -----
local STEPS_15_MOD = {
}

local WIN_PLANS = {
	w10 = { tag = "10W", skipMin = 6, steps = STEPS_10 },
	w15 = { tag = "15W", skipMin = 8, steps = STEPS_15 },
	w15mod = { tag = "15W-MOD", skipMin = 999, steps = STEPS_15_MOD }, -- khi có script: sửa skipMin = wave bắt đầu skip
}

-- 10 wave -> w10.
-- 15 wave: thấy số wave ngay -> w15 | phải bật modifier mới thấy -> w15mod.
-- Tổng wave khác -> nil (script tự tắt).
local function choosePlan(maxWave, neededModifier)
	if maxWave == 10 then return WIN_PLANS.w10 end
	if maxWave == 15 then
		if neededModifier then return WIN_PLANS.w15mod end
		return WIN_PLANS.w15
	end
	return nil
end

-- ================= 7. BẢNG TIỀN & WAVE + MENU NHỎ KÉO THẢ ĐƯỢC =================
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

local sg = Instance.new("ScreenGui")
sg.Name = HUD_NAME
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

local function stopHub()
	active = false
	if sg then
		sg:Destroy()
	end
end
_G.CullingFullHudStop = stopHub
closeBtn.MouseButton1Click:Connect(stopHub)

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

-- ================= 8. VÒNG LẶP ĐIỀU PHỐI CHÍNH =================
task.spawn(function()
	local gate1Passed = false
	local tp2Done = false
	local walkToFinalDone = false
	local isWalkingNow = false
	local lastInteractTick = 0
	local lastStartTick = 0
	local inMatchEnteredAt = nil
	local matchVerifiedDone = false
	local chosenMax = nil           -- tổng wave đã chốt cho trận hiện tại
	local winCtx = nil              -- script win đang chạy
	local seenMax, seenCount = nil, 0
	local lobbySince = nil
	local lastError = nil
	local noWaveSince, lastModifier = nil, 0

	local function resetMatch()
		if winCtx then winCtx.dead = true end
		winCtx, chosenMax = nil, nil
		seenMax, seenCount = nil, 0
		inMatchEnteredAt = nil
		matchVerifiedDone = false
	end

	local function waitingText(waited)
		if STATE.modifierJob == game.JobId then
			return "Đã bật modifier, đang chờ số wave..."
		end
		if waited then
			return string.format("Chưa thấy số wave, %ds nữa thì bật modifier...", math.max(0, math.ceil(CFG.MOD_WAIT - waited)))
		end
		return "Đang quét tổng số wave..."
	end

	while active do
		local ok, err = pcall(function()
			local _, totalNow = getCurrentWave()
			local hasTotal = totalNow ~= nil and totalNow > 0
			local atLobby = workspace:FindFirstChild("CullingGamesTeleporters") ~= nil

			if atLobby then
				STATE.modifierJob = nil
			end

			-- Đếm thời gian "không ở sảnh mà chưa thấy số wave"
			if chosenMax or hasTotal or atLobby then
				noWaveSince = nil
			else
				noWaveSince = noWaveSince or os.clock()
			end
			local waited = noWaveSince and (os.clock() - noWaveSince)

			local env = detectEnvironment()
			-- Không ở sảnh mà chưa thấy wave: trận đang load / chờ modifier -> không TP theo luồng sảnh
			if env == "LOBBY" and not atLobby and (not waited or waited < CFG.LOBBY_FALLBACK) then
				env = "WAITING"
			end

			if waited and waited >= CFG.MOD_WAIT and os.clock() - lastModifier >= CFG.MOD_RETRY then
				lastModifier = os.clock()
				if fireModifier() then
					STATE.modifierJob = game.JobId -- nhớ là màn này phải bật modifier (kể cả khi chạy lại script)
				end
			end

			if env == "LOBBY" then
				modeLbl.Text = "Vị trí: Ở SẢNH"
			elseif env == "WAITING" then
				modeLbl.Text = "Vị trí: TRONG TRẬN (chờ wave)"
			else
				modeLbl.Text = "Vị trí: TRONG TRẬN"
			end

			if env == "LOBBY" then
				-- Đang chạy trận mà UI wave ẩn chốc lát: chưa reset, tránh chạy trùng script win
				if chosenMax then
					lobbySince = lobbySince or os.clock()
					if os.clock() - lobbySince < CFG.LOBBY_CONFIRM_TIME then return end
				end
				resetMatch()
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