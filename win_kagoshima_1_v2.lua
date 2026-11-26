local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Functions = ReplicatedStorage:WaitForChild("Functions")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- ================= CẤU HÌNH WIN KAGOSHIMA 1 =================
local CFG = {
	startupWait = 3.0,
	spawnWait = 1.25,
	upWait = 0.75,
	retryWait = 1.15,
	moneyTimeout = 4.0,
	autoStartWave = 7,
	autoLoopTick = 0.45,
	minTowerDist = 1.5,
	aiStep = 1.35,
	aiMaxRing = 6,
	maxSpawnAttemptsPerSlot = 60,
}

-- ================= TIỀN & WAVE =================
local MULT = { K = 1e3, M = 1e6, B = 1e9, T = 1e12 }
local function parseNum(v)
	if typeof(v) == "number" then return v end
	if typeof(v) ~= "string" then return nil end
	local s = v:gsub(",", ""):gsub("%$", ""):gsub("%s+", "")
	local m = 1
	local suf = s:match("[kKmMbBtT]$")
	if suf then
		m = MULT[suf:upper()] or 1
		s = s:sub(1, -2)
	end
	local num = tonumber(s:match("%-?%d+%.?%d*"))
	return num and (num * m) or nil
end

local function getMoney()
	for _, o in ipairs(playerGui:GetDescendants()) do
		if (o:IsA("TextLabel") or o:IsA("TextButton")) and o.Name == "Gold" and o.Text ~= "" then
			local n = parseNum(o.Text)
			if n then return n, o.Text end
		end
	end
	local ls = player:FindFirstChild("leaderstats")
	if ls then
		for _, v in ipairs(ls:GetChildren()) do
			if v:IsA("ValueBase") then
				local n = parseNum(v.Value)
				if n then return n, tostring(v.Value) end
			end
		end
	end
	return nil, nil
end

local function getWave()
	local function ext(t)
		if typeof(t) ~= "string" or t == "" then return nil, nil end
		local c, tot = t:match("[sS][oó][nN][gG]%s*:?%s*(%d+)%s*/%s*(%d+)")
		if not c then
			c, tot = t:match("[wW][aA][vV][eE]%s*:?%s*(%d+)%s*/%s*(%d+)")
		end
		if c then return tonumber(c), tonumber(tot) end
		local s = t:match("[sS][oó][nN][gG]%s*:?%s*(%d+)")
			or t:match("[wW][aA][vV][eE]%s*:?%s*(%d+)")
			or t:match("(%d+)")
		return s and tonumber(s) or nil, nil
	end
	for _, o in ipairs(playerGui:GetDescendants()) do
		if (o:IsA("TextLabel") or o:IsA("TextButton")) and o.Text ~= "" then
			if o.Name == "Wave" or o.Name == "Sóng" then
				local c, tot = ext(o.Text)
				if c then return c, tot, o.Text end
			end
		end
	end
	for _, o in ipairs(playerGui:GetDescendants()) do
		if (o:IsA("TextLabel") or o:IsA("TextButton")) and o.Text ~= "" then
			local l = o.Text:lower()
			if l:find("sóng") or l:find("wave") then
				local c, tot = ext(o.Text)
				if c then return c, tot, o.Text end
			end
		end
	end
	return nil, nil, nil
end

-- ================= HUD WIN KAGOSHIMA 1 =================
if _G.CullingActiveWinStop then
	pcall(_G.CullingActiveWinStop)
end

local sg = Instance.new("ScreenGui")
sg.Name = "WinKagoshima1Hud"
sg.ResetOnSpawn = false
sg.IgnoreGuiInset = true
sg.DisplayOrder = 999999
pcall(function()
	if typeof(gethui) == "function" then
		local ok, h = pcall(gethui)
		if ok and typeof(h) == "Instance" then
			sg.Parent = h
			return
		end
	end
	sg.Parent = playerGui or CoreGui
end)

local box = Instance.new("Frame")
box.Size = UDim2.fromOffset(275, 66)
box.Position = UDim2.fromOffset(18, 218)
box.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
box.BorderColor3 = Color3.fromRGB(95, 220, 145)
box.Active = true
box.Draggable = true
box.Parent = sg

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -54, 0, 20)
titleLbl.Position = UDim2.fromOffset(6, 3)
titleLbl.BackgroundTransparency = 1
titleLbl.Font = Enum.Font.SourceSansBold
titleLbl.TextSize = 13
titleLbl.TextColor3 = Color3.fromRGB(115, 245, 165)
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Text = "WIN: Kagoshima 1 (Fix đặt #5)"
titleLbl.Parent = box

local stepLbl = Instance.new("TextLabel")
stepLbl.Size = UDim2.new(1, -12, 0, 36)
stepLbl.Position = UDim2.fromOffset(6, 25)
stepLbl.BackgroundTransparency = 1
stepLbl.Font = Enum.Font.SourceSans
stepLbl.TextSize = 12
stepLbl.TextColor3 = Color3.fromRGB(220, 245, 225)
stepLbl.TextXAlignment = Enum.TextXAlignment.Left
stepLbl.TextYAlignment = Enum.TextYAlignment.Top
stepLbl.TextWrapped = true
stepLbl.Text = "Bước: Đợi 3s..."
stepLbl.Parent = box

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(42, 19)
closeBtn.Position = UDim2.new(1, -46, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(185, 55, 65)
closeBtn.BorderSizePixel = 0
closeBtn.Font = Enum.Font.SourceSansBold
closeBtn.TextSize = 11
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Text = "Tắt"
closeBtn.Parent = box

local active = true
_G.CullingActiveWinStop = function()
	active = false
	if sg then sg:Destroy() end
end
closeBtn.MouseButton1Click:Connect(_G.CullingActiveWinStop)

local function setStep(t)
	if stepLbl and active then
		stepLbl.Text = "Bước: " .. tostring(t)
	end
end

-- ================= ĐẶT & NÂNG THÁP (KHÔNG BAO GIỜ KẸT LƯỢT ĐẶT THỨ 5) =================
local aiMem = { badPos = {}, bestDirById = {} }
local DIRS = {
	{1,0}, {-1,0}, {0,1}, {0,-1},
	{1,1}, {1,-1}, {-1,1}, {-1,-1},
	{2,0}, {-2,0}, {0,2}, {0,-2},
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
	while active and os.clock() < dl do
		task.wait(0.1)
		local now = getMoney()
		if now and now < before then return true end
	end
	return false
end

local function aiPickCf(baseCf, towerId, idx, ignoreBadCache)
	local _, rx, ry, rz = baseCf:ToEulerAnglesXYZ()
	local p = baseCf.Position

	if idx <= 1 and not isPosNearTower(p) and (ignoreBadCache or not aiMem.badPos[posKey(baseCf)]) then
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
			if ignoreBadCache or not aiMem.badPos[posKey(cand)] then
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
	local ignoreBad = false
	while active and tries < CFG.maxSpawnAttemptsPerSlot do
		tries += 1
		if tries == 12 then
			aiMem.badPos = {}
			ignoreBad = true
		end

		local targetCf, usedDir = aiPickCf(cf, id, tries, ignoreBad)
		local m0 = getMoney()
		local prevCount = #allTowers()
		local prev = {}
		for _, t in ipairs(allTowers()) do prev[t] = true end

		local ok, res = pcall(function()
			return Functions.SpawnNewTower:InvokeServer(id, targetCf)
		end)
		local drop = moneyDropped(m0)
		local nowTowers = allTowers()
		local spawned = (typeof(res) == "Instance") or (#nowTowers > prevCount)
		if not spawned then
			for _, t in ipairs(nowTowers) do
				if not prev[t] then
					spawned = true
					break
				end
			end
		end

		local shifted = (targetCf.Position - cf.Position).Magnitude > 0.05
		setStep(string.format("%s [#%d/%d%s | -tiền=%s | đặt=%s]",
			lbl, tries, CFG.maxSpawnAttemptsPerSlot,
			shifted and " | ĐỔI Ô" or "",
			tostring(drop), tostring(spawned)))

		if ok and res ~= false and (drop or spawned) then
			if usedDir then aiMem.bestDirById[tostring(id or "")] = usedDir end
			task.wait(CFG.spawnWait)
			return true
		end

		if m0 == nil or m0 >= 100 then
			aiMem.badPos[posKey(targetCf)] = true
		end

		task.wait(CFG.retryWait)
	end

	setStep(lbl .. " [bỏ qua lượt đặt để không kẹt, chuyển tiếp]")
	return false
end

local function doUpgrade(name, lbl)
	local tries = 0
	while active and tries < 6 do
		tries += 1
		local tgt = findTower(name)
		if not tgt then
			setStep(string.format("%s [chờ %s]", lbl, tostring(name)))
			task.wait(CFG.retryWait)
			continue
		end

		local m0 = getMoney()
		local ok, res = pcall(function()
			return Functions.UpgradeTower:InvokeServer(tgt)
		end)
		local drop = moneyDropped(m0)
		setStep(string.format("%s #%d (-tiền=%s)", lbl, tries, tostring(drop)))

		if ok and res ~= false and drop then
			task.wait(CFG.upWait)
			return true
		end

		task.wait(CFG.retryWait)
	end
	return false
end

-- ================= CHUỖI BƯỚC KAGOSHIMA 1 ([2] -> [23]) =================
local STEPS = {
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

task.spawn(function()
	local t0 = os.clock()
	while active and (os.clock() - t0) < CFG.startupWait do
		setStep(string.format("Đợi %.1fs load xong...", math.max(0, CFG.startupWait - (os.clock() - t0))))
		task.wait(0.1)
	end
	if not active then return end

	chooseModifiers()
	setStep("[1] Chọn Modifier, bắt đầu [2] -> [23]...")

	for i, s in ipairs(STEPS) do
		if not active then break end
		local tag = "#" .. (s.stepId or i)
		if s.action == "spawn" then
			doSpawn(s.towerId, s.cf, tag .. " Đặt")
		elseif s.action == "upgrade" then
			doUpgrade(s.targetName, tag .. " Nâng " .. tostring(s.targetName))
		elseif s.action == "skip" then
			voteSkip()
			setStep(tag .. " VoteSkip")
			task.wait(0.5)
		end
	end

	while active do
		local w = getWave()
		if w and w >= CFG.autoStartWave then
			voteSkip()
			for _, tName in ipairs(AUTO_UPGRADE_LOOP) do
				if not active then break end
				local curW = getWave()
				if not curW or curW < CFG.autoStartWave then break end
				doUpgrade(tName, "Auto W7+ Nâng " .. tName)
				task.wait(0.25)
			end
		else
			setStep(string.format("Chờ Wave %d để auto nâng & skip (nay: %s)", CFG.autoStartWave, tostring(w)))
		end
		task.wait(CFG.autoLoopTick)
	end
end)