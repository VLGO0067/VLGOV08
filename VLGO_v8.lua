-- VLGO | ดึงเจาะไอดีเพลง | Black & White Edition (v8)
-- v8: - หน้าโหลดโลโก้ VLGO ใหญ่: รอสแกน+ยืนยัน ID เสร็จ (ลองซ้ำอัตโนมัติสูงสุด 4 รอบ) แล้วค่อยโชว์ผล
--     - ดึงไฟล์เสียงลองซ้ำ 3 ครั้ง + โหลดไฟล์ของเพลงหลักรอไว้ล่วงหน้า
--     - UI ใหม่: โลโก้ปกใหญ่, ขอบเรืองหมุน, เส้นสแกน, ปกเพลงเบลอเป็นพื้นการ์ด, ปุ่มโลโก้เต้น
-- v7: RAW ที่มี decoy เป็นร้อย: probe ตัวเต็ง (ท้าย/แรก/คะแนนสูง) ก่อน + ตัวที่ไม่ใช่เสียงตกเร็ว (failFast) + probe ได้ 48 ตัว
-- v6: - ดึงไฟล์เสียงด้วยวิธีของ 505 (game:HttpGet assetdelivery ตรง ๆ) ก่อน แล้วค่อย fallback request()
--     - 👤 เปลี่ยนเป็นกรอบสี่เหลี่ยมรูปอวตารคนเปิดเพลง (โหมดทั้งแมพ)
--     - เส้นคั่นเหนือแถบปุ่มด้านล่าง
--     - เสียงคลิกดังขึ้น (Volume 8)
-- v4: แก้ปัญหา probe ไม่ทัน (ติด ถอดรหัส ? ทั้งที่ ID จริงอยู่ใน candidate)
--   - probe เป็นชุดละ PROBE_BATCH ตัว (เดิมโหลดทีเดียว 20 ตัว เครื่องแรมเต็มเลย timeout หมด)
--   - เจอตัวที่ความยาวตรงแล้วหยุดทันที ไม่ต้องโหลดที่เหลือ
--   - ตัด GetProductInfo ออกจากขั้น probe (เดิมต้องรอก่อนโหลด โดนหน่วง/throttle)
--   - เพิ่ม timeout, ปรับ DEAD_RETRY ให้ retry รอบถัดไปได้จริง
--   - การ์ดที่ยังไม่ยืนยันมีปุ่ม RAW คัดลอกสตริง SoundId ดิบ + debug log (DEBUG = true)
--
-- ขั้นตอน: structured parse -> ให้คะแนน -> probe (โหลดจริง) -> เทียบความยาว
--   -> ไม่ตรง: brute (ทุกชุดเลข) -> ยังไม่ตรง: เดาจากคะแนน (พฤติกรรมเดิม)
--
-- ป้ายบนการ์ด:  ถอดรหัส ✓ = ความยาวตรงตัวเดียว (ยืนยัน)
--               ถอดรหัส ~ = ตรงหลายตัว / โหลดได้ตัวเดียว (ตรวจบางส่วน)
--               ถอดรหัส ? = ยืนยันไม่ได้ เดาจากรูปแบบ

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local HttpService = game:GetService("HttpService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

for _, n in ipairs({ "AudioDecoderGUI", "VLGO_AudioDecoder" }) do
	local old = playerGui:FindFirstChild(n)
	if old then old:Destroy() end
end

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local MIN_DIGITS = 4           -- สั้นกว่านี้ไม่ใช่ asset id (กัน decoy เลขสั้น)
local MAX_DIGITS = 15          -- ยาวกว่านี้ tonumber() เพี้ยน และไม่ใช่ id จริง
local MAX_PROBES = 48          -- จำนวน candidate สูงสุดที่โหลดทดสอบต่อ 1 stage (probe เป็นชุดละ PROBE_BATCH)
local PROBE_BATCH = 6          -- candidate ที่โหลดพร้อมกันต่อชุด (เครื่องแรมเต็ม/FPS ต่ำ โหลดเยอะพร้อมกันจะ timeout)
local PROBE_TIMEOUT = 7        -- วิ รอโหลดเสียงทดสอบ 1 ตัว (เดิม 3 สั้นไปสำหรับเครื่องช้า)
local LEN_EPS = 0.1            -- วิ ค่าคลาดเคลื่อนของความยาวเสียง
local RETRY_AFTER = 8          -- วิ ผลที่ยังไม่ยืนยันจะถูกลองใหม่
local DEAD_RETRY = 6           -- วิ candidate ที่โหลดไม่ได้จะถูกลองใหม่ (ต้องน้อยกว่า RETRY_AFTER)
local MAX_PROBED_PER_SCAN = 4  -- จำนวน sound ที่เข้า probe ต่อการสแกน (ที่เหลือเดาจากคะแนน แล้วรอบหน้าค่อยต่อ)
local RESOLVE_DEADLINE = 30    -- วิ รอ resolve ทั้งหมดต่อการสแกน
local LOGO_ID = "rbxassetid://105642202804693"
local AUTO_INTERVAL = 3            -- วิ ระยะห่างสแกนอัตโนมัติ
local WEBHOOK_URL = "https://discord.com/api/webhooks/1560655959657816064/VJyJQJ0tn7uJh1lf1wj6T0rgpELvFAIq2wblrmCIHoLrADwDhRQLytOAaFrBOkZ1ttTL"

-- ตัวกรองเพลงแมพบรูค: เทียบชื่อผู้สร้าง (ตัวพิมพ์เล็ก, ตรงทั้งชื่อหรือมีคำนี้อยู่ในชื่อ)
-- เปิดการ์ดเพลงบรูคดู "ผู้สร้าง:" แล้วใส่ชื่อที่เห็นเพิ่มตรงนี้ได้เลย
local BROOK_CREATORS = { "brookhaven", "voldex", "wolfpaq" }
local BROOK_TITLES = { "brookhaven" }
local DEBUG = true             -- พิมพ์ [AudioDecoder] raw / probe ลง Developer Console (พิมพ์ /console ในแชท)

local function dbg(...)
	if DEBUG then print("[AudioDecoder]", ...) end
end

----------------------------------------------------------------
-- THEME  (ขาว-ดำล้วน)
----------------------------------------------------------------
local C = {
	bg = Color3.fromRGB(8, 8, 8),
	panel = Color3.fromRGB(14, 14, 14),
	card = Color3.fromRGB(20, 20, 20),
	card2 = Color3.fromRGB(28, 28, 28),
	hover = Color3.fromRGB(46, 46, 46),
	line = Color3.fromRGB(46, 46, 46),
	white = Color3.fromRGB(255, 255, 255),
	soft = Color3.fromRGB(205, 205, 205),
	mute = Color3.fromRGB(125, 125, 125),
	black = Color3.fromRGB(0, 0, 0),
}

local CONF_TAG = { [2] = "ถอดรหัส ✓", [1] = "ถอดรหัส ~", [0] = "ถอดรหัส ?" }

-- รายการ ID ที่บล็อก (ใส่เพิ่มได้ เช่น BLOCKED["123456789"] = true)
local BLOCKED = {
	["95092864526864"] = true,
	["76258144163655"] = true,
	["123728962822472"] = true,
	["122929786531506"] = true,
	["74336255090060"] = true,
}

local settings = {
	onlyPlaying = true, -- แสดงเฉพาะเพลงที่เล่นอยู่จริง
	hideBrook = true,   -- ซ่อนเพลงที่มาจากแมพบรูค
}
local renderResults -- ประกาศล่วงหน้า

local connections = {}
local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

----------------------------------------------------------------
-- UI HELPERS
----------------------------------------------------------------
local function new(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do
		obj[k] = v
	end
	obj.Parent = parent
	return obj
end

local function round(obj, r)
	return new("UICorner", { CornerRadius = UDim.new(0, r) }, obj)
end

local function outline(obj, color, thickness, transparency)
	return new("UIStroke", {
		Color = color or C.line,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, obj)
end

local function tween(obj, props, t, style, dir)
	TweenService:Create(obj, TweenInfo.new(t or 0.15, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props):Play()
end

-- เสียงคลิก UI (สร้างจริงหลังสร้าง gui)
local CLICK_SOUND_ID = "rbxassetid://74379627889513"
local clickSnd
local function playClick()
	if not clickSnd then return end
	pcall(function()
		clickSnd.TimePosition = 0
		clickSnd:Play()
	end)
end

local function label(props, parent)
	local p = {
		BackgroundTransparency = 1,
		TextColor3 = C.white,
		Font = Enum.Font.Gotham,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}
	for k, v in pairs(props) do p[k] = v end
	return new("TextLabel", p, parent)
end

-- primary = ขาวตัวดำ | ปกติ = เทาเข้มตัวขาว มีเส้นขอบ
local function button(props, parent, primary)
	local base = primary and C.white or C.card2
	local over = primary and C.soft or C.hover
	local p = {
		BackgroundColor3 = base,
		TextColor3 = primary and C.black or C.white,
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		AutoButtonColor = false,
	}
	for k, v in pairs(props) do p[k] = v end
	local b = new("TextButton", p, parent)
	round(b, 8)
	if not primary then outline(b, C.line) end
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 190, 190)),
		Rotation = 90,
	}, b)
	b:SetAttribute("base", base)
	b:SetAttribute("over", over)
	local sc = new("UIScale", { Scale = 1 }, b)
	connect(b.MouseEnter, function() tween(b, { BackgroundColor3 = b:GetAttribute("over") }) end)
	connect(b.MouseLeave, function()
		tween(b, { BackgroundColor3 = b:GetAttribute("base") })
		tween(sc, { Scale = 1 }, 0.12)
	end)
	-- กดแล้วยุบนิดนึง ปล่อยแล้วเด้งกลับ + เสียงคลิก
	connect(b.MouseButton1Down, function() tween(sc, { Scale = 0.94 }, 0.07) end)
	connect(b.MouseButton1Up, function() tween(sc, { Scale = 1 }, 0.18, Enum.EasingStyle.Back) end)
	connect(b.MouseButton1Click, playClick)
	return b
end

local function setToggle(b, on)
	local base = on and C.white or C.card2
	b:SetAttribute("base", base)
	b:SetAttribute("over", on and C.soft or C.hover)
	tween(b, { BackgroundColor3 = base, TextColor3 = on and C.black or C.white }, 0.15)
end

local function makeDraggable(handle, target, onTap)
	local dragging, moved = false, false
	local startInput, startPos

	connect(handle.InputBegan, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			startInput = input.Position
			startPos = target.Position
			local c
			c = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					c:Disconnect()
					if onTap and not moved then onTap() end
				end
			end)
		end
	end)

	connect(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - startInput
			if d.Magnitude > 5 then moved = true end
			if moved then
				target.Position = UDim2.new(
					startPos.X.Scale, startPos.X.Offset + d.X,
					startPos.Y.Scale, startPos.Y.Offset + d.Y
				)
			end
		end
	end)
end

----------------------------------------------------------------
-- SONG INFO + PROBE
----------------------------------------------------------------
local function fmtTime(sec)
	sec = math.max(0, math.floor(sec or 0))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

-- ใช้แสดงชื่อ/ผู้สร้างบนการ์ดเท่านั้น (ไม่ได้ใช้ใน probe แล้ว)
local infoCache = {}
local function getSongInfo(id)
	if infoCache[id] then return infoCache[id] end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(tonumber(id))
	end)
	if ok and info then
		local data = {
			name = info.Name or ("Audio ID: " .. id),
			creator = (info.Creator and info.Creator.Name) or "ไม่ทราบ",
			typeId = info.AssetTypeId, -- 3 = Audio
		}
		infoCache[id] = data
		return data
	end
	return { name = "Audio ID: " .. id, creator = "ไม่ทราบ" }
end

local function isBrook(info)
	if not info then return false end
	local creator = tostring(info.creator or ""):lower()
	local name = tostring(info.name or ""):lower()
	for _, k in ipairs(BROOK_CREATORS) do
		if creator:find(k, 1, true) then return true end
	end
	for _, k in ipairs(BROOK_TITLES) do
		if name:find(k, 1, true) then return true end
	end
	return false
end

-- โหลดเสียงทดสอบ vol 0 ใน SoundService แล้วอ่านความยาว (ไม่ Play, ลบทิ้งหลังอ่าน)
-- game ที่ดัก instance ใหม่ใน SoundService จะเห็น Sound ชื่อ _adprobe ชั่วคราว
local function loadLength(soundId, timeout, failFast)
	local s = Instance.new("Sound")
	s.Name = "_adprobe"
	s.Volume = 0
	s.SoundId = soundId
	s.Parent = SoundService

	-- กระตุ้นให้ engine โหลดไฟล์เลย (ไม่ต้องรอ lazy load)
	-- v7: failFast = ตัวหลอกที่ไม่ใช่เสียง engine ตอบ Failure ทันที ไม่ต้องรอ timeout เต็ม
	local failed = false
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync({ s }, function(_, status)
				local st = tostring(status)
				if failFast and (st:find("Fail") or st:find("TimedOut")) then failed = true end
			end)
		end)
	end)

	local t0, len = os.clock(), nil
	while os.clock() - t0 < (timeout or PROBE_TIMEOUT) do
		if s.IsLoaded and s.TimeLength > 0 then
			len = s.TimeLength
			break
		end
		if failed then break end
		task.wait(0.05)
	end
	s:Destroy()
	return len
end

local lenCache, deadAt = {}, {} -- [id] = ความยาว | เวลาที่โหลดไม่ได้
local function needsProbe(id)
	if lenCache[id] then return false end
	local d = deadAt[id]
	return d == nil or os.clock() - d > DEAD_RETRY
end

-- probe หลาย id พร้อมกัน; ผลลง lenCache (โหลดได้) / deadAt (ไม่ใช่เสียงหรือโหลดไม่ได้)
-- ไม่เรียก GetProductInfo ก่อนโหลดแล้ว: ช้า/โดน throttle ตอนยิงพร้อมกันหลายตัว
-- ตัวที่ไม่ใช่เสียงจะไม่โหลดขึ้นเองและตกเป็น dead เมื่อหมดเวลา
local function probeIds(ids)
	local pending = 0
	for _, id in ipairs(ids) do
		if needsProbe(id) then
			pending += 1
			task.spawn(function()
				local ok, len = pcall(loadLength, "rbxassetid://" .. id, nil, true)
				if ok and len then
					lenCache[id] = len
				else
					deadAt[id] = os.clock()
				end
				pending -= 1
			end)
		end
	end
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < PROBE_TIMEOUT + 2 do
		task.wait(0.05)
	end
end

-- โหลด SoundId ดิบ (สตริงเต็มที่เกมใช้) เพื่อได้ความยาวของไฟล์ที่ engine resolve จริง
local rawLen = {}
local function probeRaw(raw)
	if rawLen[raw] then return rawLen[raw] end
	local len = loadLength(raw)
	if len then rawLen[raw] = len end
	return len
end

----------------------------------------------------------------
-- ID DECODER
-- resolveSound(snd, allowProbe) -> { id, protected, conf } | nil
--   conf 2 = ความยาวตรงตัวเดียว | 1 = ตรงหลายตัว/โหลดได้ตัวเดียว | 0 = เดา
----------------------------------------------------------------
local function urlDecode(s)
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

local function stripZeros(d)
	return d:match("^0*(%d+)") or d
end

-- ไอดีปกติ ไม่มีการป้องกัน
local function plainId(raw)
	if type(raw) ~= "string" then return nil end
	local d = raw:match("^%s*rbxassetid://(%d+)%s*$")
		or raw:match("^%s*(%d+)%s*$")
		or raw:match("^%s*https?://www%.roblox%.com/asset/?%?id=(%d+)%s*$")
	return d and stripZeros(d) or nil
end

-- แยกทุก "&key=value" แล้วเก็บเฉพาะอันที่โครงสร้างถูกต้องจริง
-- decoy ส่วนใหญ่พังตรงใดตรงหนึ่งอยู่แล้ว:
--   %26 / %3D     -> ไม่มี & หรือ = ตัวจริง ไม่ถูกแยกเป็น pair
--   ZWSP/ZWNJ/ZWJ/WJ ในหรือติด key/value -> มีไบต์ >= 0x80 เลยตกในด่าน charset
--   &%00 padding  -> ไม่มี =
--   ข้อความกับดัก AI ช่วงหัว -> key ว่าง/มี space ตกด่านเดียวกัน (ไม่ต้องอ่านเนื้อหา)
local function collectCandidates(raw)
	local out, order = {}, 0

	-- BiDi override U+202E: ทั้งไบต์จริงและแบบ %E2%80%AE (ไม่ใช่ตัวแบ่ง แค่ติดท้าย segment)
	local s = raw:gsub("\226\128\174", ""):gsub("%%[Ee]2%%80%%[Aa][Ee]", "")

	for seg in (s .. "&"):gmatch("([^&]*)&") do
		local eq = seg:find("=", 1, true)
		if eq then
			local key, val = seg:sub(1, eq - 1), seg:sub(eq + 1)
			if key ~= "" and val ~= ""
				and not key:find("[^0-9A-Za-z%%]")
				and not val:find("[^0-9A-Za-z%%]")
				and urlDecode(key):lower() == "id" then
				local digits = urlDecode(val)
				if digits:match("^%d+$") then
					order += 1
					-- mixed = มี %XX ปนกับเลข literal ในค่าเดียวกัน (เช่น %364 = %36 + "4")
					local rest, n = val:gsub("%%%x%x", "")
					local mixed = n > 0 and rest:find("%d") ~= nil
					local fwd = stripZeros(digits)
					out[#out + 1] = { id = fwd, mixed = mixed, order = order }

					-- สำรอง: เผื่อ id จริงถูกกลับทิศจริง ๆ ไม่ใช่แค่ RLO ตกแต่งให้ดูกลับ
					local rev = stripZeros(digits:reverse())
					if rev ~= fwd then
						out[#out + 1] = { id = rev, mixed = mixed, reversed = true, order = order }
					end
				end
			end
		end
	end
	return out
end

-- stage 1: candidate จากโครงสร้าง ให้คะแนนแทนการเลือกตามลำดับ
--   mixed 100 > เลขนำหน้า 60 > id= ปกติ 30, ซ้ำเพิ่ม +10/ครั้ง
--   ลำดับใช้แค่ตัดสินเสมอ (mixed: ตัวแรก, id= ปกติ: ตัวท้าย) ตรงกับพฤติกรรม v2
local function structuredCands(raw)
	local map, list = {}, {}

	local function add(id, base, tie, order)
		if #id < MIN_DIGITS or #id > MAX_DIGITS then return end
		local c = map[id]
		if not c then
			c = { id = id, base = -1, hits = 0, tie = 0 }
			map[id] = c
			list[#list + 1] = c
		end
		c.hits += 1
		if order then
			c.first = math.min(c.first or order, order)
			c.last = math.max(c.last or order, order)
		end
		if base > c.base then c.base, c.tie = base, tie end
	end

	for _, p in ipairs(collectCandidates(raw)) do
		if p.reversed then
			add(p.id, 15, p.order * 0.001) -- สำรองทิศกลับ: คะแนนต่ำกว่าทุกแบบ แต่ยังเข้ารอบ probe ได้
		elseif p.mixed then
			add(p.id, 100, -p.order * 0.001, p.order)
		else
			add(p.id, 30, p.order * 0.001, p.order)
		end
	end

	-- เลขนำหน้า & ใช้เป็นทางสำรองเท่านั้น ถ้ายังไม่เจอ id= จริงสักตัว
	-- (เดิมให้ 60 แต้มไม่มีเงื่อนไข ทำให้ decoy ที่วางเลขไว้หน้าสุดแซง id= จริงได้ง่ายเกินไป)
	if #list == 0 then
		local leading = raw:match("^%s*(%d+)%s*&") or raw:match("^%s*rbxassetid://(%d+)")
		if leading then add(stripZeros(leading), 60, 0) end
	end

	for _, c in ipairs(list) do
		-- จำกัดโบนัสจากการซ้ำไม่ให้ไม่มีเพดาน (เดิม decoy ที่ซ้ำหลายสิบรอบแซง id จริงที่โผล่ครั้งเดียวได้)
		c.score = c.base + 10 * math.min(c.hits - 1, 2) + c.tie
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.id < b.id
	end)
	-- v7: ตัวเต็งลง probe ก่อน: คะแนนสูงสุด / id= ตัวสุดท้าย / id= ตัวแรก
	-- (ตัวหลอกซ้ำเยอะแซงคะแนนได้ และ parser แต่ละเวอร์ชันเลือกตัวแรกหรือตัวท้ายไม่เหมือนกัน)
	if #list > 3 then
		local firstC, lastC
		for _, c in ipairs(list) do
			if c.first and (not firstC or c.first < firstC.first) then firstC = c end
			if c.last and (not lastC or c.last > lastC.last) then lastC = c end
		end
		local front, used = {}, {}
		for _, c in ipairs({ list[1], lastC, firstC }) do
			if c and not used[c] then
				used[c] = true
				front[#front + 1] = c
			end
		end
		for _, c in ipairs(list) do
			if not used[c] then front[#front + 1] = c end
		end
		list = front
	end
	return list
end

-- stage 2: เผื่อรูปแบบใหม่ที่ parser ไม่รู้จัก — decode ทั้งสตริง, ตัดอักขระล่องหนทุกชนิด,
-- เก็บทุกชุดเลข (ชุดที่ตามหลัง "id=" ได้แต้มเพิ่ม) แล้วให้ probe เป็นคนตัดสิน
local INVISIBLE = {
	"\226\128[\139-\143]", -- U+200B..200F ZWSP ZWNJ ZWJ LRM RLM
	"\226\128[\170-\174]", -- U+202A..202E BiDi embed/override
	"\226\129[\160-\164]", -- U+2060..2064 WJ + invisible operators
	"\226\129[\166-\169]", -- U+2066..2069 BiDi isolates
	"\239\187\191",        -- U+FEFF
	"\194\173",            -- U+00AD
}

local function bruteCands(raw)
	local s = urlDecode(raw)
	for _, pat in ipairs(INVISIBLE) do
		s = s:gsub(pat, "")
	end

	local map, list = {}, {}
	for pos, run in s:gmatch("()(%d+)") do
		local id = stripZeros(run)
		if #id >= MIN_DIGITS and #id <= MAX_DIGITS then
			local c = map[id]
			if not c then
				c = { id = id, score = -pos * 0.000001 }
				map[id] = c
				list[#list + 1] = c
			end
			c.score += 1
			if s:sub(math.max(1, pos - 3), pos - 1):lower() == "id=" then
				c.score += 5
			end
		end
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.id < b.id
	end)
	return list
end

-- โหลดทดสอบ candidate เป็นชุด ๆ (เรียงตามคะแนน) แล้วเทียบกับความยาวจริง
-- เจอตัวที่ตรงในชุดไหนก็หยุดทันที (ตรงตัวเดียวในที่ probe แล้ว = conf 2)
-- -> best, conf | nil (ไม่มีตัวไหนผ่าน ให้ไป stage ถัดไป)
local function pickFrom(cands, targetLen, stage)
	local total = math.min(#cands, MAX_PROBES)
	local alive = {} -- ยังเรียงตามคะแนน

	local i = 1
	while i <= total do
		local j = math.min(i + PROBE_BATCH - 1, total)
		local ids = {}
		for k = i, j do
			ids[#ids + 1] = cands[k].id
		end
		probeIds(ids)

		for k = i, j do
			local len = lenCache[cands[k].id]
			dbg(string.format("[%s] probe %s len=%s target=%s",
				stage, cands[k].id, tostring(len), tostring(targetLen)))
			if len then alive[#alive + 1] = { c = cands[k], len = len } end
		end

		if targetLen then
			local hit = {}
			for _, a in ipairs(alive) do
				if math.abs(a.len - targetLen) <= LEN_EPS then hit[#hit + 1] = a.c end
			end
			if #hit == 1 then return hit[1], 2 end
			if #hit > 1 then return hit[1], 1 end
		end

		i = j + 1
	end

	if targetLen then return nil end

	-- ไม่รู้ความยาวจริง: ตัด candidate ที่โหลดไม่ได้/ไม่ใช่เสียงทิ้งอย่างเดียว
	if #alive == 1 then return alive[1].c, 1 end
	if #alive > 1 then return alive[1].c, 0 end
	return nil
end

local resolved = {} -- [rawSoundId] = result
local function peek(raw)
	local h = resolved[raw]
	if h and (h.conf > 0 or os.clock() - h.t < RETRY_AFTER) then return h end
	return nil
end

local function remember(raw, id, conf, protected)
	local h = { id = id, conf = conf, protected = protected, t = os.clock() }
	resolved[raw] = h
	return h
end

local function resolveSound(snd, allowProbe)
	local raw = snd.SoundId
	if type(raw) ~= "string" or raw == "" then return nil end

	local hit = peek(raw)
	if hit then return hit end

	local plain = plainId(raw)
	if plain then return remember(raw, plain, 2, false) end

	local structured = structuredCands(raw)

	-- เกินโควต้า probe: เดาจากคะแนน ไม่ cache
	if not allowProbe then
		local g = structured[1] or bruteCands(raw)[1]
		if not g then return nil end
		return { id = g.id, conf = 0, protected = true, t = os.clock() }
	end

	dbg("raw:", raw)

	-- ความยาวของไฟล์ที่ engine โหลดจริง: อ่านจากเสียงเอง ถ้ายังไม่โหลดให้โหลดสตริงดิบเอง
	local targetLen = (snd.IsLoaded and snd.TimeLength > 0) and snd.TimeLength or probeRaw(raw)
	dbg(string.format("targetLen=%s structured=%d", tostring(targetLen), #structured))

	local best, conf = pickFrom(structured, targetLen, "structured")
	local brute = {}
	if not best then
		brute = bruteCands(raw)
		dbg(string.format("brute candidates=%d", #brute))
		best, conf = pickFrom(brute, targetLen, "brute")
	end
	if best then
		dbg(string.format("resolved %s conf=%d", best.id, conf))
		return remember(raw, best.id, conf, true)
	end

	local g = structured[1] or brute[1]
	if not g then return nil end
	dbg("unverified, guessing " .. g.id)
	return remember(raw, g.id, 0, true)
end

----------------------------------------------------------------
-- SCANNER
----------------------------------------------------------------
-- หาว่าเสียงนี้เป็นของผู้เล่นคนไหน (ตัวละคร / กระเป๋า / พาหนะที่ชื่อมีชื่อผู้เล่น)
local function ownerOf(snd)
	local a = snd
	while a and a ~= game do
		if a:IsA("Model") then
			local pl = Players:GetPlayerFromCharacter(a)
			if pl then return pl end
		elseif a:IsA("Backpack") and a.Parent and a.Parent:IsA("Player") then
			return a.Parent
		end
		a = a.Parent
	end
	a = snd.Parent
	while a and a ~= workspace and a ~= game do
		local n = a.Name:lower()
		for _, p in ipairs(Players:GetPlayers()) do
			if n:find(p.Name:lower(), 1, true) then return p end
		end
		a = a.Parent
	end
	return nil
end

local function ownerText(r)
	if r.owners and #r.owners > 0 then return table.concat(r.owners, ", ") end
	return "ไม่ทราบ"
end

local function collectSounds(root, tag, entries, seen)
	if not root then return end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("Sound") and not seen[d] and d.SoundId ~= "" then
			seen[d] = true
			entries[#entries + 1] = {
				sound = d,
				playing = d.IsPlaying and d.Volume > 0,
				source = tag .. " (" .. d.Name .. ")",
			}
		end
	end
end

local lastHidden = 0
local function scan(target)
	local entries, seen = {}, {}

	if target then
		collectSounds(target.Character, "ตัวละคร", entries, seen)
		collectSounds(target:FindFirstChild("Backpack"), "กระเป๋า", entries, seen)

		local pname = target.Name:lower()
		for _, obj in ipairs(workspace:GetChildren()) do
			if obj ~= target.Character then
				local n = obj.Name:lower()
				if n:find(pname, 1, true) then
					collectSounds(obj, "พาหนะ: " .. obj.Name, entries, seen)
				elseif n:find("vehicle") or n:find("car") then
					for _, child in ipairs(obj:GetChildren()) do
						if child.Name:lower():find(pname, 1, true) then
							collectSounds(child, "พาหนะ: " .. child.Name, entries, seen)
						end
					end
				end
			end
		end
	else
		collectSounds(workspace, "Workspace", entries, seen)
	end

	-- ตรวจว่าเล่นจริง: ตำแหน่งเวลาต้องเดินหน้า (กันเสียงหลอก/เสียงแฝง)
	local hasCandidate = false
	for _, e in ipairs(entries) do
		if e.playing then
			e.pos0 = e.sound.TimePosition
			hasCandidate = true
		end
	end
	if hasCandidate then
		task.wait(0.35)
		for _, e in ipairs(entries) do
			if e.playing then
				local snd = e.sound
				e.playing = snd.Parent ~= nil and snd.IsPlaying
					and math.abs(snd.TimePosition - e.pos0) > 0.05
			end
		end
	end

	-- resolve เฉพาะที่จะแสดงจริง (ไม่ probe เสียงที่ถูกกรองทิ้ง)
	local keep = {}
	for _, e in ipairs(entries) do
		if e.playing or not settings.onlyPlaying then
			keep[#keep + 1] = e
		end
	end

	local pending, budget = 0, MAX_PROBED_PER_SCAN
	for _, e in ipairs(keep) do
		local raw = e.sound.SoundId
		local allow = true
		if not peek(raw) and not plainId(raw) then
			allow = budget > 0
			budget -= 1
		end
		pending += 1
		task.spawn(function()
			local ok, res = pcall(resolveSound, e.sound, allow)
			e.res = ok and res or nil
			pending -= 1
		end)
	end
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < RESOLVE_DEADLINE do
		task.wait(0.05)
	end

	local results = {}
	for _, e in ipairs(keep) do
		local res = e.res
		if not res then
			local ok, r = pcall(resolveSound, e.sound, false) -- หมดเวลา: เดาจากคะแนน
			res = ok and r or nil
		end
		if res and not BLOCKED[res.id] then
			local ownerPl = ownerOf(e.sound) or target
			results[#results + 1] = {
				ownerName = ownerPl and (ownerPl.DisplayName .. " (@" .. ownerPl.Name .. ")") or nil,
				ownerPl = ownerPl,
				sound = e.sound,
				realId = res.id,
				raw = e.sound.SoundId,
				protected = res.protected,
				conf = res.conf,
				playing = e.playing,
				source = e.source,
			}
		end
	end

	-- เพลงที่กำลังเล่นขึ้นก่อน
	table.sort(results, function(a, b)
		if a.playing ~= b.playing then return a.playing end
		return a.realId < b.realId
	end)

	local final, byId = {}, {}
	for _, r in ipairs(results) do
		local first = byId[r.realId]
		if not first then
			first = r
			first.owners = {}
			first.ownerPls = {}
			byId[r.realId] = first
			final[#final + 1] = r
		end
		-- เพลงเดียวกันหลายคนเปิด: รวมชื่อทุกคน (เฉพาะตัวที่สถานะเล่นตรงกัน)
		if r.ownerName and (r.playing or not first.playing)
			and not table.find(first.owners, r.ownerName) then
			table.insert(first.owners, r.ownerName)
			table.insert(first.ownerPls, r.ownerPl)
		end
	end
	for _, r in ipairs(final) do
		r.ownerKey = table.concat(r.owners, ",")
	end
	-- กรองเพลงแมพบรูค (เช็กเฉพาะ ID ที่ยืนยันแล้ว/ID ปกติ ส่วนที่เดาไม่แตะ)
	lastHidden = 0
	if settings.hideBrook then
		local verdict, pending = {}, 0
		for _, r in ipairs(final) do
			if r.conf > 0 then
				pending += 1
				task.spawn(function()
					local ok, info = pcall(getSongInfo, r.realId)
					verdict[r.realId] = ok and isBrook(info) or false
					pending -= 1
				end)
			end
		end
		local tb = os.clock()
		while pending > 0 and os.clock() - tb < 6 do
			task.wait(0.05)
		end
		local kept = {}
		for _, r in ipairs(final) do
			if verdict[r.realId] then
				lastHidden += 1
			else
				kept[#kept + 1] = r
			end
		end
		final = kept
	end
	return final
end

----------------------------------------------------------------
-- CLIPBOARD / HTTP
----------------------------------------------------------------
local function copyText(text, box)
	local ok = false
	pcall(function()
		if typeof(setclipboard) == "function" then
			setclipboard(tostring(text)); ok = true
		elseif typeof(toclipboard) == "function" then
			toclipboard(tostring(text)); ok = true
		end
	end)
	if box then
		box.Text = tostring(text)
		pcall(function()
			box:CaptureFocus()
			box.CursorPosition = #tostring(text) + 1
		end)
	end
	return ok
end

local function httpRequest(opts)
	local env = (getgenv and getgenv()) or getfenv()
	local fn = env.request or env.http_request
		or (env.syn and env.syn.request)
		or (env.http and env.http.request)
		or (env.fluxus and env.fluxus.request)
	if not fn then return nil, "no_request" end
	local ok, res = pcall(fn, opts)
	if not ok then return nil, tostring(res) end
	return res
end

----------------------------------------------------------------
-- STATE
----------------------------------------------------------------
local selected = localPlayer
local wholeMap = false
local autoScan = false
local lastResults = {}
local heroResult = nil
local lastMainId = nil
local live = {} -- รายการที่ต้องอัปเดตเวลา/ปุ่มฟังสด
local heroListening = nil

----------------------------------------------------------------
-- GUI
----------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "VLGO_AudioDecoder",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

local scanning = false -- กำลังสแกน (ใช้คุมเส้นสแกนใต้ header)

-- ปุ่มวงกลมโลโก้ (ลากได้ แตะเพื่อเปิด/ปิด) v8: ใหญ่ขึ้น + วงคลื่นเต้น
local orb = new("TextButton", {
	Name = "ToggleOrb",
	Size = UDim2.fromOffset(66, 66),
	Position = UDim2.new(0, 16, 0.5, -33),
	BackgroundColor3 = C.black,
	Text = "",
	AutoButtonColor = false,
}, gui)
round(orb, 18)
local orbStroke = outline(orb, C.white, 2)
local orbScale = new("UIScale", { Scale = 0 }, orb)
local orbRing = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	ZIndex = 0,
}, orb)
round(orbRing, 20)
local orbRingStroke = outline(orbRing, C.white, 1.5, 1)
local orbLogo = new("ImageLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(54, 54),
	BackgroundTransparency = 1,
	Image = LOGO_ID,
	ScaleType = Enum.ScaleType.Fit,
}, orb)
round(orbLogo, 12)
tween(orbScale, { Scale = 1 }, 0.35, Enum.EasingStyle.Back)

clickSnd = new("Sound", {
	Name = "VLGO_Click",
	SoundId = CLICK_SOUND_ID,
	Volume = 8, -- Volume สูงสุดของ Roblox = 10
}, gui)
task.spawn(function()
	pcall(function() ContentProvider:PreloadAsync({ clickSnd }) end)
end)

-- หน้าต่างหลัก: พื้นไล่เฉด + ขอบขาวไล่เฉดหมุนวน
local main = new("Frame", {
	Name = "MainFrame",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromScale(0.66, 0.86),
	BackgroundColor3 = C.white,
	Active = true,
}, gui)
new("UISizeConstraint", { MinSize = Vector2.new(520, 330), MaxSize = Vector2.new(800, 500) }, main)
local mainScale = new("UIScale", { Scale = 1 }, main)
round(main, 20)
new("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(22, 22, 22), Color3.fromRGB(5, 5, 5)),
	Rotation = 90,
}, main)
local mainStroke = outline(main, C.white, 1.5, 0.15)
local mainStrokeGrad = new("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(60, 60, 60)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
	}),
	Rotation = 0,
}, mainStroke)

local openToken = 0
local function setOpen(v)
	openToken += 1
	local my = openToken
	if v then
		mainScale.Scale = 0.9
		main.Visible = true
		tween(mainScale, { Scale = 1 }, 0.25, Enum.EasingStyle.Back)
	else
		tween(mainScale, { Scale = 0.92 }, 0.14)
		task.delay(0.14, function()
			if openToken == my then main.Visible = false end
		end)
	end
end

-- Header (v8: สูงขึ้น โลโก้ปก VLGO ใหญ่เด่น)
local HEADER_H = 76
local header = new("Frame", {
	Size = UDim2.new(1, 0, 0, HEADER_H),
	BackgroundColor3 = C.panel,
}, main)
round(header, 20)
new("Frame", {
	Size = UDim2.new(1, 0, 0, 20),
	Position = UDim2.new(0, 0, 1, -20),
	BackgroundColor3 = C.panel,
	BorderSizePixel = 0,
}, header)

local logoWrap = new("Frame", {
	Size = UDim2.fromOffset(58, 58),
	Position = UDim2.new(0, 14, 0.5, -29),
	BackgroundColor3 = C.black,
	ZIndex = 2,
}, header)
round(logoWrap, 15)
outline(logoWrap, C.white, 1.5, 0.1)
local logoImg = new("ImageLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(48, 48),
	BackgroundTransparency = 1,
	Image = LOGO_ID,
	ScaleType = Enum.ScaleType.Fit,
	ZIndex = 3,
}, logoWrap)
round(logoImg, 10)

label({
	Size = UDim2.new(0, 160, 0, 32),
	Position = UDim2.new(0, 86, 0, 12),
	Text = "VLGO",
	Font = Enum.Font.GothamBlack,
	TextSize = 28,
	ZIndex = 2,
}, header)
label({
	Size = UDim2.new(0, 200, 0, 14),
	Position = UDim2.new(0, 88, 0, 46),
	Text = "ดึงเจาะไอดีเพลง  •  v8",
	TextColor3 = C.mute,
	TextSize = 11,
	ZIndex = 2,
}, header)

local liveBadge = new("Frame", {
	Size = UDim2.fromOffset(62, 22),
	Position = UDim2.new(1, -160, 0.5, -11),
	BackgroundColor3 = C.black,
	Visible = false,
	ZIndex = 2,
}, header)
round(liveBadge, 7)
outline(liveBadge, C.white, 1, 0.5)
local liveDot = new("Frame", {
	Size = UDim2.fromOffset(7, 7),
	Position = UDim2.new(0, 10, 0.5, -3),
	BackgroundColor3 = C.white,
	ZIndex = 3,
}, liveBadge)
round(liveDot, 2)
label({
	Size = UDim2.new(1, -24, 1, 0),
	Position = UDim2.new(0, 24, 0, 0),
	Text = "AUTO",
	Font = Enum.Font.GothamBold,
	TextSize = 10,
	ZIndex = 3,
}, liveBadge)

local minBtn = button({
	Size = UDim2.fromOffset(32, 28),
	Position = UDim2.new(1, -82, 0.5, -14),
	Text = "—",
	ZIndex = 2,
}, header)
local closeBtn = button({
	Size = UDim2.fromOffset(32, 28),
	Position = UDim2.new(1, -44, 0.5, -14),
	Text = "X",
	ZIndex = 2,
}, header)

new("Frame", {
	Size = UDim2.new(1, 0, 0, 1),
	Position = UDim2.new(0, 0, 0, HEADER_H),
	BackgroundColor3 = C.white,
	BackgroundTransparency = 0.88,
	BorderSizePixel = 0,
}, main)
-- เส้นสแกนวิ่งใต้ header ตอนกำลังสแกน
local scanTrack = new("Frame", {
	Size = UDim2.new(1, -40, 0, 2),
	Position = UDim2.new(0, 20, 0, HEADER_H),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ClipsDescendants = true,
}, main)
local scanBar = new("Frame", {
	Size = UDim2.fromScale(0.3, 1),
	Position = UDim2.fromScale(-0.3, 0),
	BackgroundColor3 = C.white,
	BorderSizePixel = 0,
	Visible = false,
}, scanTrack)
new("UIGradient", {
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	}),
}, scanBar)

makeDraggable(header, main)
makeDraggable(orb, orb, function()
	playClick()
	setOpen(not main.Visible)
end)
-- ปุ่มโลโก้: เอาเมาส์ชี้แล้วขยาย / กดแล้วยุบ
connect(orb.MouseEnter, function() tween(orbScale, { Scale = 1.08 }, 0.15) end)
connect(orb.MouseLeave, function() tween(orbScale, { Scale = 1 }, 0.15) end)
connect(orb.MouseButton1Down, function() tween(orbScale, { Scale = 0.92 }, 0.07) end)
connect(orb.MouseButton1Up, function() tween(orbScale, { Scale = 1.08 }, 0.18, Enum.EasingStyle.Back) end)
connect(minBtn.MouseButton1Click, function() setOpen(false) end)

-- ===== ซ้าย: ผู้เล่น =====
local PANEL_Y = HEADER_H + 8
local left = new("Frame", {
	Size = UDim2.new(0, 176, 1, -(PANEL_Y + 10)),
	Position = UDim2.new(0, 10, 0, PANEL_Y),
	BackgroundColor3 = C.panel,
}, main)
round(left, 14)
outline(left)

label({
	Size = UDim2.new(1, -78, 0, 28),
	Position = UDim2.new(0, 12, 0, 2),
	Text = "ผู้เล่นในแมพ",
	Font = Enum.Font.GothamBold,
}, left)

local refreshBtn = button({
	Size = UDim2.fromOffset(54, 22),
	Position = UDim2.new(1, -60, 0, 5),
	Text = "รีเฟรช",
}, left)

local searchBox = new("TextBox", {
	Size = UDim2.new(1, -16, 0, 28),
	Position = UDim2.new(0, 8, 0, 34),
	BackgroundColor3 = C.card,
	Text = "",
	PlaceholderText = "ค้นหาผู้เล่น...",
	PlaceholderColor3 = C.mute,
	TextColor3 = C.white,
	Font = Enum.Font.Gotham,
	TextSize = 12,
	ClearTextOnFocus = false,
	TextXAlignment = Enum.TextXAlignment.Left,
}, left)
round(searchBox, 9)
local searchStroke = outline(searchBox)
new("UIPadding", { PaddingLeft = UDim.new(0, 10) }, searchBox)
connect(searchBox.Focused, function() tween(searchStroke, { Color = C.white }, 0.1) end)
connect(searchBox.FocusLost, function() tween(searchStroke, { Color = C.line }, 0.1) end)

local playerList = new("ScrollingFrame", {
	Size = UDim2.new(1, -10, 1, -72),
	Position = UDim2.new(0, 5, 0, 68),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = C.white,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, left)
new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, playerList)

-- ===== ขวา: ผลลัพธ์ =====
local right = new("Frame", {
	Size = UDim2.new(1, -206, 1, -(PANEL_Y + 10)),
	Position = UDim2.new(0, 196, 0, PANEL_Y),
	BackgroundColor3 = C.panel,
}, main)
round(right, 14)
outline(right)

-- โลโก้จางเป็นลายน้ำกลางลิสต์ตอนยังไม่มีเพลง
local watermark = new("ImageLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 74),
	Size = UDim2.fromOffset(130, 130),
	BackgroundTransparency = 1,
	Image = LOGO_ID,
	ImageTransparency = 0.88,
	ScaleType = Enum.ScaleType.Fit,
	Visible = false,
	ZIndex = 0,
}, right)

local targetLabel = label({
	Size = UDim2.new(1, -100, 0, 26),
	Position = UDim2.new(0, 12, 0, 4),
	Text = "เป้าหมาย: -",
	Font = Enum.Font.GothamBold,
}, right)

local rescanBtn = button({
	Size = UDim2.fromOffset(78, 24),
	Position = UDim2.new(1, -86, 0, 5),
	Text = "สแกนซ้ำ",
}, right, true)

-- ---------- การ์ดเพลงหลัก (กระพริบ) ----------
local HERO_H = 132
local hero = new("Frame", {
	Size = UDim2.new(1, -16, 0, HERO_H),
	Position = UDim2.new(0, 8, 0, 34),
	BackgroundColor3 = C.white,
}, right)
round(hero, 16)
local heroScale = new("UIScale", { Scale = 1 }, hero)
local heroStroke = outline(hero, C.white, 1.5, 0.6)
new("UIGradient", {
	Color = ColorSequence.new(Color3.fromRGB(40, 40, 40), Color3.fromRGB(10, 10, 10)),
	Rotation = 125,
}, hero)

-- ปกเพลงเบลอจางเป็นพื้นหลังการ์ด (ตามค่า cover.Image)
local heroBg = new("ImageLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Image = "",
	ImageTransparency = 0.86,
	ScaleType = Enum.ScaleType.Crop,
	ZIndex = 0,
}, hero)
round(heroBg, 16)

local heroFlash = new("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = C.white,
	BackgroundTransparency = 1,
	ZIndex = 10,
}, hero)
round(heroFlash, 16)

local cover = new("ImageLabel", {
	Size = UDim2.fromOffset(100, 100),
	Position = UDim2.new(0, 14, 0, 16),
	BackgroundColor3 = C.black,
	Image = "",
	ScaleType = Enum.ScaleType.Crop,
}, hero)
round(cover, 12)
local coverStroke = outline(cover, C.white, 1, 0.8)
connect(cover:GetPropertyChangedSignal("Image"), function()
	heroBg.Image = cover.Image
end)

local eq = new("Frame", {
	Size = UDim2.fromOffset(34, 18),
	Position = UDim2.new(0, 6, 1, -6),
	AnchorPoint = Vector2.new(0, 1),
	BackgroundTransparency = 1,
	Visible = false,
	ZIndex = 3,
}, cover)
local eqBars = {}
for k = 1, 5 do
	eqBars[k] = new("Frame", {
		Size = UDim2.fromOffset(4, 6),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, (k - 1) * 7, 1, 0),
		BackgroundColor3 = C.white,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, eq)
end

local HERO_TX = 128
local heroTextW = UDim2.new(1, -(HERO_TX + 100), 0, 16)

local heroDot = new("Frame", {
	Size = UDim2.fromOffset(7, 7),
	Position = UDim2.new(0, HERO_TX, 0, 14),
	BackgroundColor3 = C.white,
}, hero)
round(heroDot, 2)
local heroTag = label({
	Size = UDim2.new(1, -(HERO_TX + 112), 0, 14),
	Position = UDim2.new(0, HERO_TX + 12, 0, 10),
	Text = "รอเพลง",
	Font = Enum.Font.GothamBold,
	TextColor3 = C.soft,
	TextSize = 10,
}, hero)
local heroName = label({
	Size = UDim2.new(1, -(HERO_TX + 100), 0, 22),
	Position = UDim2.new(0, HERO_TX, 0, 26),
	Text = "ยังไม่พบเพลง",
	Font = Enum.Font.GothamBold,
	TextSize = 15,
}, hero)
local heroCreator = label({
	Size = heroTextW,
	Position = UDim2.new(0, HERO_TX, 0, 47),
	Text = "กด 'สแกนซ้ำ' เมื่อเขาเปิดเพลง",
	TextColor3 = C.mute,
	TextSize = 11,
}, hero)

-- โหมดทุกคน: ใครเป็นคนเปิดเพลงนี้ (รูปอวตารกรอบสี่เหลี่ยม)
local heroWhoAv = new("ImageLabel", {
	Size = UDim2.fromOffset(18, 18),
	Position = UDim2.new(0, HERO_TX, 0, 62),
	BackgroundColor3 = C.black,
	Image = "",
	ScaleType = Enum.ScaleType.Crop,
	Visible = false,
}, hero)
round(heroWhoAv, 3)
outline(heroWhoAv, C.white, 1, 0.5)

local heroWho = label({
	Size = UDim2.new(1, -(HERO_TX + 124), 0, 16),
	Position = UDim2.new(0, HERO_TX + 24, 0, 63),
	Text = "",
	Font = Enum.Font.GothamBold,
	TextColor3 = C.white,
	TextSize = 11,
	Visible = false,
}, hero)

local idBox = new("TextBox", {
	Size = UDim2.new(1, -(HERO_TX + 150), 0, 24),
	Position = UDim2.new(0, HERO_TX, 0, 82),
	BackgroundTransparency = 1,
	Text = "",
	PlaceholderText = "ID เพลงจะแสดงที่นี่",
	PlaceholderColor3 = C.mute,
	TextColor3 = C.white,
	Font = Enum.Font.GothamBlack,
	TextSize = 19,
	ClearTextOnFocus = false,
	TextEditable = false,
	TextXAlignment = Enum.TextXAlignment.Left,
}, hero)

local rawBtn = button({
	Size = UDim2.fromOffset(40, 18),
	Position = UDim2.new(1, -(100 + 44), 0, 85),
	Text = "RAW",
	TextSize = 9,
	Visible = false,
}, hero)

local heroTrack = new("Frame", {
	Size = UDim2.new(1, -(HERO_TX + 100), 0, 4),
	Position = UDim2.new(0, HERO_TX, 0, 110),
	BackgroundColor3 = C.line,
	BorderSizePixel = 0,
}, hero)
round(heroTrack, 2)
local heroProg = new("Frame", {
	Size = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = C.white,
	BorderSizePixel = 0,
}, heroTrack)
round(heroProg, 2)

local heroTime = label({
	Size = heroTextW,
	Position = UDim2.new(0, HERO_TX, 0, 116),
	Text = "0:00 / 0:00",
	Font = Enum.Font.GothamBold,
	TextSize = 10,
	TextColor3 = C.soft,
}, hero)

local copyMainBtn = button({
	Size = UDim2.fromOffset(80, 28),
	Position = UDim2.new(1, -92, 0, 12),
	Text = "คัดลอก",
}, hero, true)
local listenMainBtn = button({
	Size = UDim2.fromOffset(80, 28),
	Position = UDim2.new(1, -92, 0, 50),
	Text = "▶ ฟัง",
}, hero)
local sendMainBtn = button({
	Size = UDim2.fromOffset(80, 28),
	Position = UDim2.new(1, -92, 0, 88),
	Text = "ส่งดิส",
}, hero)

local LIST_Y = 34 + HERO_H + 24
local statusLabel = label({
	Size = UDim2.new(1, -16, 0, 16),
	Position = UDim2.new(0, 12, 0, 34 + HERO_H + 4),
	Text = "พร้อมใช้งาน",
	TextColor3 = C.mute,
	TextSize = 10,
}, right)

local resultList = new("ScrollingFrame", {
	Size = UDim2.new(1, -16, 1, -(LIST_Y + 42)),
	Position = UDim2.new(0, 8, 0, LIST_Y),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 3,
	ScrollBarImageColor3 = C.white,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, right)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, resultList)

-- เส้นคั่นเหนือแถบปุ่มด้านล่าง
new("Frame", {
	Size = UDim2.new(1, -16, 0, 1),
	Position = UDim2.new(0, 8, 1, -39),
	BackgroundColor3 = C.white,
	BackgroundTransparency = 0.75,
	BorderSizePixel = 0,
}, right)

local footer = new("Frame", {
	Size = UDim2.new(1, -16, 0, 28),
	Position = UDim2.new(0, 8, 1, -36),
	BackgroundTransparency = 1,
}, right)

local function footBtn(i, text)
	return button({
		Size = UDim2.new(0.25, -4, 1, 0),
		Position = UDim2.new(0.25 * i, 0, 0, 0),
		Text = text,
		TextSize = 10,
	}, footer)
end
local autoBtn = footBtn(0, "○ สแกนอัตโนมัติ")
local onlyBtn = footBtn(1, "● เฉพาะที่เล่นอยู่")
local brookBtn = footBtn(2, "● ซ่อนเพลงบรูค")
local copyAllBtn = footBtn(3, "คัดลอกทั้งหมด")
setToggle(onlyBtn, settings.onlyPlaying)
setToggle(brookBtn, settings.hideBrook)

-- ===== หน้าโหลด: โลโก้ VLGO ใหญ่กลางจอ คลุมผลลัพธ์จนกว่ายืนยัน ID เสร็จ =====
local splash = new("CanvasGroup", {
	Name = "Splash",
	Size = UDim2.new(1, -16, 1, -(34 + 42)),
	Position = UDim2.new(0, 8, 0, 34),
	BackgroundColor3 = C.panel,
	GroupTransparency = 1,
	Visible = false,
	Active = true,
	ZIndex = 30,
}, right)
round(splash, 16)
local splashBox = new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(1, 0, 0, 180),
	BackgroundTransparency = 1,
}, splash)
new("UIListLayout", {
	FillDirection = Enum.FillDirection.Vertical,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 7),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, splashBox)
local splashLogoWrap = new("Frame", {
	Size = UDim2.fromOffset(104, 104),
	BackgroundColor3 = C.black,
	LayoutOrder = 1,
}, splashBox)
round(splashLogoWrap, 26)
outline(splashLogoWrap, C.white, 2, 0.1)
local splashScale = new("UIScale", { Scale = 1 }, splashLogoWrap)
local splashLogo = new("ImageLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(86, 86),
	BackgroundTransparency = 1,
	Image = LOGO_ID,
	ScaleType = Enum.ScaleType.Fit,
}, splashLogoWrap)
round(splashLogo, 18)
label({
	Size = UDim2.new(1, 0, 0, 26),
	Text = "VLGO",
	Font = Enum.Font.GothamBlack,
	TextSize = 22,
	TextXAlignment = Enum.TextXAlignment.Center,
	LayoutOrder = 2,
}, splashBox)
local splashStatus = label({
	Size = UDim2.new(1, 0, 0, 16),
	Text = "กำลังโหลด...",
	TextColor3 = C.mute,
	TextSize = 11,
	TextXAlignment = Enum.TextXAlignment.Center,
	LayoutOrder = 3,
}, splashBox)
local splashTrack = new("Frame", {
	Size = UDim2.fromOffset(150, 3),
	BackgroundColor3 = C.line,
	BorderSizePixel = 0,
	ClipsDescendants = true,
	LayoutOrder = 4,
}, splashBox)
round(splashTrack, 2)
local splashBar = new("Frame", {
	Size = UDim2.fromScale(0.35, 1),
	Position = UDim2.fromScale(-0.35, 0),
	BackgroundColor3 = C.white,
	BorderSizePixel = 0,
}, splashTrack)
round(splashBar, 2)

local splashOn, splashToken = false, 0
local function setLoading(on, text)
	if text then splashStatus.Text = text end
	if on == splashOn then return end
	splashOn = on
	splashToken += 1
	local my = splashToken
	if on then
		splash.Visible = true
		tween(splash, { GroupTransparency = 0 }, 0.2)
	else
		tween(splash, { GroupTransparency = 1 }, 0.25)
		task.delay(0.27, function()
			if splashToken == my then splash.Visible = false end
		end)
	end
end

-- ข้อความเด้งชั่วคราว
local toast = new("TextLabel", {
	Size = UDim2.fromOffset(300, 28),
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -12),
	BackgroundColor3 = C.white,
	TextColor3 = C.black,
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	Text = "",
	Visible = false,
	ZIndex = 50,
}, main)
round(toast, 9)
local TOAST_REST = UDim2.new(0.5, 0, 1, -12)
local toastToken = 0
local function showToast(text)
	toastToken += 1
	local my = toastToken
	toast.Text = text
	if not toast.Visible then
		toast.Position = UDim2.new(0.5, 0, 1, 6)
		toast.BackgroundTransparency = 1
		toast.TextTransparency = 1
	end
	toast.Visible = true
	tween(toast, { Position = TOAST_REST, BackgroundTransparency = 0, TextTransparency = 0 }, 0.22, Enum.EasingStyle.Back)
	task.delay(1.8, function()
		if toastToken ~= my then return end
		tween(toast, { Position = UDim2.new(0.5, 0, 1, 6), BackgroundTransparency = 1, TextTransparency = 1 }, 0.18)
		task.delay(0.2, function()
			if toastToken == my then toast.Visible = false end
		end)
	end)
end

-- แอนิเมชันตกแต่ง: ขอบหน้าต่างหมุนเฉด + วงคลื่นปุ่มโลโก้
task.spawn(function()
	local t = 0
	while gui.Parent do
		t += 1
		mainStrokeGrad.Rotation = (t * 2) % 360
		if t % 50 == 0 then
			orbRingStroke.Transparency = 0.35
			orbRing.Size = UDim2.fromScale(1, 1)
			tween(orbRing, { Size = UDim2.fromScale(1.45, 1.45) }, 1.2)
			tween(orbRingStroke, { Transparency = 1 }, 1.2)
		end
		task.wait(0.03)
	end
end)

-- เส้นสแกนใต้ header + แถบโหลด + โลโก้เต้นบนหน้าโหลด
task.spawn(function()
	while gui.Parent do
		if splashOn then
			splashBar.Position = UDim2.fromScale(-0.35, 0)
			tween(splashBar, { Position = UDim2.fromScale(1, 0) }, 0.9, Enum.EasingStyle.Sine)
			tween(splashScale, { Scale = 1.07 }, 0.45, Enum.EasingStyle.Sine)
			task.delay(0.45, function()
				tween(splashScale, { Scale = 1 }, 0.45, Enum.EasingStyle.Sine)
			end)
		end
		if scanning then
			scanBar.Visible = true
			scanBar.Position = UDim2.fromScale(-0.3, 0)
			tween(scanBar, { Position = UDim2.fromScale(1, 0) }, 0.8, Enum.EasingStyle.Sine)
		else
			scanBar.Visible = false
		end
		task.wait(0.95)
	end
end)

----------------------------------------------------------------
-- ฟัง / หยุด  (เล่นในเครื่องเราเอง ผ่าน SoundService)
----------------------------------------------------------------
local listen = { id = nil, sound = nil }

local function stopListen()
	if listen.sound then
		pcall(function()
			listen.sound:Stop()
			listen.sound:Destroy()
		end)
	end
	listen.id, listen.sound = nil, nil
end

local function toggleListen(id)
	if listen.id == id then
		stopListen()
		return
	end
	stopListen()
	local s = Instance.new("Sound")
	s.Name = "_adlisten"
	s.Volume = 0.7
	s.SoundId = "rbxassetid://" .. id
	s.Parent = SoundService
	listen.id, listen.sound = id, s
	s:Play()
	s.Ended:Connect(function()
		if listen.sound == s then stopListen() end
	end)
	task.delay(7, function()
		if listen.sound == s and not s.IsPlaying then
			stopListen()
			showToast("เล่นเสียงนี้ไม่ได้")
		end
	end)
end

----------------------------------------------------------------
-- WEBHOOK  (รูปแบบ embed ตาม buildAudioEmbed ใน bot-1.js)
----------------------------------------------------------------
local thumbCache = {}
local function getThumbUrl(id)
	if thumbCache[id] ~= nil then return thumbCache[id] or nil end
	local res = httpRequest({
		Url = "https://thumbnails.roblox.com/v1/assets?assetIds=" .. id
			.. "&returnPolicy=PlaceholderSmartThumbnail&size=420x420&format=Png&isCircular=false",
		Method = "GET",
	})
	local url
	if res and res.Body then
		local ok, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
		local item = ok and data and data.data and data.data[1]
		if item and item.state == "Completed" and item.imageUrl then url = item.imageUrl end
	end
	thumbCache[id] = url or false
	return url
end

local function clean(s, n)
	s = tostring(s or ""):gsub("`", "'")
	return #s > n and (s:sub(1, n) .. "…") or s
end

-- ดึงไฟล์เสียงจริงจาก Roblox -> bytes, "ogg"/"mp3" | nil
-- v6: ใช้วิธีเดียวกับ 505 ก่อน (game:HttpGet assetdelivery v1 ตรง ๆ ไม่ต้องมี header)
--     ไม่ติดก็ fallback request() แบบเดิม (v2 location -> v1)
local MAX_FILE = 9 * 1024 * 1024 -- Discord จำกัดไฟล์แนบ ถ้าใหญ่กว่านี้ข้าม
local audioCache = {}
local function audioKind(b)
	if type(b) ~= "string" or #b < 200 then return nil end
	if b:sub(1, 4) == "OggS" then return "ogg" end
	local b1, b2 = b:byte(1), b:byte(2)
	if b:sub(1, 3) == "ID3" or (b1 == 0xFF and b2 and b2 >= 0xE0) then return "mp3" end
	return nil
end

-- magic ไม่ตรง แต่ก้อนใหญ่และไม่ใช่ JSON/HTML error -> ถือเป็น mp3 เหมือน 505
local function kindOf(b)
	local k = audioKind(b)
	if k then return k end
	if type(b) == "string" and #b > 2000 and not b:find("^%s*[{<]") then return "mp3" end
	return nil
end

local function fetchAudioOnce(id)
	local c = audioCache[id]
	if c then return c.bytes, c.ext end

	-- 1) วิธีของ 505
	local ok, body = pcall(function()
		return game:HttpGet("https://assetdelivery.roblox.com/v1/asset/?id=" .. id)
	end)
	if ok and type(body) == "string" and #body <= MAX_FILE then
		local ext = kindOf(body)
		if ext then
			audioCache[id] = { bytes = body, ext = ext }
			dbg("fetchAudio HttpGet ok " .. id .. " " .. #body .. "B " .. ext)
			return body, ext
		end
	end

	-- 2) fallback: request() ของ executor
	local hdr = {
		["Roblox-Place-Id"] = tostring(game.PlaceId),
		["User-Agent"] = "Roblox/WinInet",
	}
	local urls = {}
	local res = httpRequest({
		Url = "https://assetdelivery.roblox.com/v2/assetId/" .. id,
		Method = "GET",
		Headers = hdr,
	})
	if res and res.Body then
		local jok, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
		local loc = jok and data and data.locations and data.locations[1] and data.locations[1].location
		if loc then urls[#urls + 1] = loc end
	end
	urls[#urls + 1] = "https://assetdelivery.roblox.com/v1/asset/?id=" .. id

	for _, u in ipairs(urls) do
		local r = httpRequest({ Url = u, Method = "GET", Headers = hdr })
		local ext = r and kindOf(r.Body)
		if ext and #r.Body <= MAX_FILE then
			audioCache[id] = { bytes = r.Body, ext = ext }
			return r.Body, ext
		end
	end
	dbg("fetchAudio failed for " .. id)
	return nil
end

-- ลองซ้ำ: ครั้งแรกมักดึงไม่ได้ (เครือข่าย/โหลดยังไม่นิ่ง) กดซ้ำถึงได้
local function fetchAudio(id)
	for attempt = 1, 3 do
		local b, e = fetchAudioOnce(id)
		if b then return b, e end
		task.wait(0.5)
	end
	return nil
end

local sentAt = {}
-- -> true, แนบไฟล์ไหม | false, เหตุผล
local function sendWebhook(r, who)
	if sentAt[r.realId] and os.clock() - sentAt[r.realId] < 3 then return false, "ช้าหน่อย" end
	sentAt[r.realId] = os.clock()

	local info = infoCache[r.realId] or getSongInfo(r.realId)
	local length = (r.sound and r.sound.Parent and r.sound.TimeLength > 0) and r.sound.TimeLength
		or lenCache[r.realId]

	local fields = {
		{ name = "Title", value = "`" .. clean(info.name, 200) .. "`", inline = true },
		{ name = "Artist", value = "`" .. clean(info.creator, 100) .. "`", inline = true },
		{ name = "Audio ID", value = "`" .. r.realId .. "`", inline = true },
		{ name = "Duration", value = "`" .. (length and fmtTime(length) or "N/A") .. "`", inline = true },
		{ name = "Verify", value = "`" .. (r.protected and CONF_TAG[r.conf] or "ID ปกติ") .. "`", inline = true },
		{ name = "From", value = "`" .. clean(who, 80) .. "`", inline = true },
		{ name = "Links", value = "[View on Roblox](https://www.roblox.com/library/" .. r.realId .. ")", inline = false },
	}
	local embed = {
		title = "🎵 พบ ID เพลงใหม่ Roblox",
		color = 0x00C853,
		timestamp = DateTime.now():ToIsoDate(),
		fields = fields,
		footer = { text = "VLGO  •  ดึงเจาะไอดีเพลง" },
	}
	local th = getThumbUrl(r.realId)
	if th then embed.thumbnail = { url = th } end

	local json = HttpService:JSONEncode({ username = "VLGO", embeds = { embed } })

	-- แนบไฟล์เสียงเป็น <ID>.ogg/.mp3 (multipart) ถ้าดึงไฟล์ไม่ได้ส่งเฉพาะข้อมูลเหมือนเดิม
	local bytes, ext = fetchAudio(r.realId)
	local function post(withFile)
		if withFile and bytes then
			local bd = "VLGO" .. HttpService:GenerateGUID(false):gsub("-", "")
			local body = "--" .. bd .. "\r\n"
				.. 'Content-Disposition: form-data; name="payload_json"\r\n'
				.. "Content-Type: application/json\r\n\r\n"
				.. json .. "\r\n"
				.. "--" .. bd .. "\r\n"
				.. 'Content-Disposition: form-data; name="files[0]"; filename="' .. r.realId .. "." .. ext .. '"\r\n'
				.. "Content-Type: " .. (ext == "ogg" and "audio/ogg" or "audio/mpeg") .. "\r\n\r\n"
				.. bytes .. "\r\n"
				.. "--" .. bd .. "--\r\n"
			return httpRequest({
				Url = WEBHOOK_URL,
				Method = "POST",
				Headers = { ["Content-Type"] = "multipart/form-data; boundary=" .. bd },
				Body = body,
			})
		end
		return httpRequest({
			Url = WEBHOOK_URL,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = json,
		})
	end

	local attached = bytes ~= nil
	local res, err = post(attached)
	if res and attached then
		local c = res.StatusCode or 0
		if c == 400 or c == 413 then -- ไฟล์โดนปฏิเสธ: ส่งซ้ำแบบไม่มีไฟล์
			attached = false
			res, err = post(false)
		end
	end
	if not res then
		return false, err == "no_request" and "executor ไม่มี request" or "ส่งไม่ได้"
	end
	local code = res.StatusCode or 0
	if res.Success or (code >= 200 and code < 300) then return true, attached end
	if code == 429 then return false, "ส่งถี่เกิน รอสักครู่" end
	return false, "ล้มเหลว (" .. tostring(code) .. ")"
end

local function whoLabel()
	if wholeMap then return "ทั้งแมพ" end
	return selected and (selected.DisplayName .. " (@" .. selected.Name .. ")") or "-"
end

local function doSend(r, btn, idleText)
	if r.protected and r.conf == 0 then
		showToast("ยังไม่ยืนยัน ไม่ส่งเข้าดิส")
		return
	end
	btn.Text = "กำลังส่ง…"
	task.spawn(function()
		local who = whoLabel()
		if wholeMap then who = who .. " • เปิดโดย " .. ownerText(r) end
		local ok, extra = sendWebhook(r, who)
		if btn.Parent then btn.Text = ok and "ส่งแล้ว ✓" or "ไม่สำเร็จ" end
		if ok then
			showToast(extra and "ส่ง ID + ไฟล์เสียงเข้า Discord แล้ว" or "ส่ง ID แล้ว (ดึงไฟล์เสียงไม่ได้)")
		else
			showToast(tostring(extra))
		end
		task.delay(1.4, function()
			if btn.Parent then btn.Text = idleText end
		end)
	end)
end

----------------------------------------------------------------
-- RENDER
----------------------------------------------------------------
local function flashHero()
	heroFlash.BackgroundTransparency = 0.72
	tween(heroFlash, { BackgroundTransparency = 1 }, 0.8)
	heroStroke.Thickness = 3.5
	tween(heroStroke, { Thickness = 1.5 }, 0.8)
end

local function sameResults(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do
		local x, y = a[i], b[i]
		if x.realId ~= y.realId or x.playing ~= y.playing or x.conf ~= y.conf or x.sound ~= y.sound
			or x.ownerKey ~= y.ownerKey then
			return false
		end
	end
	return true
end

local function clearQueue()
	for _, c in ipairs(resultList:GetChildren()) do
		if c:IsA("GuiObject") then c:Destroy() end
	end
	table.clear(live)
end

local function setHero(r)
	local prev = heroResult
	heroResult = r
	heroWho.Visible = wholeMap and r ~= nil
	local opener = r and r.ownerPls and r.ownerPls[1]
	heroWhoAv.Visible = wholeMap and opener ~= nil
	if r and wholeMap then
		heroWho.Text = "เปิดโดย: " .. ownerText(r)
		if opener then
			heroWhoAv.Image = "rbxthumb://type=AvatarHeadShot&id=" .. opener.UserId .. "&w=150&h=150"
		end
	end
	if r and (not prev or prev.realId ~= r.realId) then
		heroScale.Scale = 0.96
		tween(heroScale, { Scale = 1 }, 0.3, Enum.EasingStyle.Back)
	end
	if not r then
		heroWho.Text = ""
		heroWhoAv.Visible = false
		idBox.Text = ""
		cover.Image = ""
		eq.Visible = false
		rawBtn.Visible = false
		heroTag.Text = "รอเพลง"
		heroName.Text = "ยังไม่พบเพลง"
		heroCreator.Text = "กด 'สแกนซ้ำ' เมื่อเขาเปิดเพลง"
		heroTime.Text = "0:00 / 0:00"
		heroProg.Size = UDim2.new(0, 0, 1, 0)
		return
	end

	local isGuess = r.protected and r.conf == 0
	idBox.Text = r.realId
	rawBtn.Visible = isGuess
	eq.Visible = r.playing
	heroTag.Text = (r.playing and "กำลังเล่น" or "หยุดอยู่")
		.. (r.protected and ("  •  " .. CONF_TAG[r.conf]) or "")

	if isGuess then
		-- ห้ามโชว์ชื่อ/ผู้สร้าง/รูปจริง: decoy ที่บังเอิญโหลดเป็นเพลงจริงจะดูน่าเชื่อถือ
		cover.Image = ""
		heroName.Text = "⚠ ยังไม่ยืนยัน — ห้ามเชื่อ ID นี้"
		heroCreator.Text = "เดาจากคะแนนเท่านั้น ไม่มีการเทียบความยาวเสียงจริง"
	else
		cover.Image = "rbxthumb://type=Asset&id=" .. r.realId .. "&w=150&h=150"
		heroName.Text = "กำลังโหลดชื่อเพลง..."
		heroCreator.Text = "ผู้สร้าง: ..."
		local id = r.realId
		task.spawn(function()
			local info = getSongInfo(id)
			if heroResult and heroResult.realId == id then
				heroName.Text = info.name
				heroCreator.Text = "ผู้สร้าง: " .. info.creator
			end
		end)
	end
end

local function makeQueueCard(r, i)
	local isGuess = r.protected and r.conf == 0

	local card = new("Frame", {
		Size = UDim2.new(1, -6, 0, 60),
		BackgroundColor3 = C.card,
		LayoutOrder = i,
	}, resultList)
	round(card, 12)
	outline(card, r.playing and C.soft or C.line, 1, r.playing and 0.55 or 0)
	-- เด้งเข้าทีละใบ
	local cardScale = new("UIScale", { Scale = 0.94 }, card)
	task.delay(math.min((i - 2) * 0.04, 0.3), function()
		if cardScale.Parent then tween(cardScale, { Scale = 1 }, 0.25, Enum.EasingStyle.Back) end
	end)
	local whoPre = wholeMap and ("เปิดโดย " .. ownerText(r) .. "  •  ") or ""

	local cv = new("ImageLabel", {
		Size = UDim2.fromOffset(44, 44),
		Position = UDim2.new(0, 8, 0.5, -22),
		BackgroundColor3 = C.bg,
		Image = isGuess and "" or ("rbxthumb://type=Asset&id=" .. r.realId .. "&w=150&h=150"),
		ScaleType = Enum.ScaleType.Crop,
	}, card)
	round(cv, 8)
	outline(cv)

	local tx = 60
	local tw = UDim2.new(1, -(tx + 152), 0, 15)
	local nameLbl = label({
		Size = tw,
		Position = UDim2.new(0, tx, 0, 8),
		Text = "กำลังโหลดชื่อเพลง...",
		Font = Enum.Font.GothamBold,
		TextSize = 12,
	}, card)
	local creatorLbl = label({
		Size = tw,
		Position = UDim2.new(0, tx, 0, 24),
		Text = whoPre .. "ผู้สร้าง: ...",
		TextColor3 = C.mute,
		TextSize = 10,
	}, card)
	local subLbl = label({
		Size = tw,
		Position = UDim2.new(0, tx, 0, 39),
		Text = "ID " .. r.realId,
		TextColor3 = C.soft,
		TextSize = 10,
	}, card)

	local function slot(k) return UDim2.new(1, -148 + (k - 1) * 48, 0.5, -13) end
	local function btn(k, text, primary)
		return button({ Size = UDim2.fromOffset(44, 26), Position = slot(k), Text = text, TextSize = 10 }, card, primary)
	end

	local copyBtn = btn(1, "คัดลอก", true)
	local listenBtn = btn(2, "▶ ฟัง", false)

	connect(copyBtn.MouseButton1Click, function()
		copyBtn.Text = copyText(r.realId, idBox) and "แล้ว ✓" or "เลือกแล้ว"
		task.delay(1.2, function()
			if copyBtn.Parent then copyBtn.Text = "คัดลอก" end
		end)
	end)
	connect(listenBtn.MouseButton1Click, function() toggleListen(r.realId) end)

	if isGuess then
		nameLbl.Text = "⚠ ยังไม่ยืนยัน"
		creatorLbl.Text = whoPre .. "เดาจากคะแนนเท่านั้น"
		local rb = btn(3, "RAW", false)
		connect(rb.MouseButton1Click, function()
			local ok = copyText(r.raw, nil)
			if not ok then copyText(r.raw, idBox) end
			rb.Text = ok and "แล้ว ✓" or "เลือกแล้ว"
			task.delay(1.2, function()
				if rb.Parent then rb.Text = "RAW" end
			end)
		end)
	else
		local sb = btn(3, "ส่งดิส", false)
		connect(sb.MouseButton1Click, function() doSend(r, sb, "ส่งดิส") end)
		task.spawn(function()
			local info = getSongInfo(r.realId)
			if nameLbl.Parent then
				nameLbl.Text = info.name
				creatorLbl.Text = whoPre .. "ผู้สร้าง: " .. info.creator .. (isBrook(info) and "  •  แมพบรูค" or "")
			end
		end)
	end

	live[#live + 1] = { r = r, sub = subLbl, listenBtn = listenBtn, wasListening = nil }
	return card
end

local function doRender(force)
	local target = (not wholeMap) and selected or nil

	if wholeMap then
		targetLabel.Text = "เป้าหมาย: ทั้งแมพ"
	elseif target and target.Parent then
		targetLabel.Text = "เป้าหมาย: " .. target.DisplayName .. " (@" .. target.Name .. ")"
	else
		targetLabel.Text = "เป้าหมาย: ผู้เล่นออกจากแมพแล้ว"
		statusLabel.Text = "-"
		clearQueue()
		setHero(nil)
		lastResults, lastMainId = {}, nil
		return
	end

	if force or #lastResults == 0 then
		statusLabel.Text = "กำลังสแกนและยืนยัน ID..."
	end
	local quiet = not (force or #lastResults == 0)
	local results
	local tStart = os.clock()
	for attempt = 1, quiet and 2 or 4 do
		if not quiet then
			setLoading(true, attempt == 1 and "กำลังสแกนเสียงและยืนยัน ID..." or ("ยังยืนยันไม่ครบ ลองใหม่ รอบ " .. attempt))
		end
		results = scan(target)
		local unsure = false
		for _, r in ipairs(results) do
			if r.protected and r.conf == 0 then unsure = true break end
		end
		if not unsure or os.clock() - tStart > 35 then break end
		-- ยังเป็นแค่เดา: ล้างแคชที่ล้มเหลว แล้วโหลดใหม่ (รอบแรกเครื่องมักโหลดไม่ทัน)
		for k, h in pairs(resolved) do
			if h.conf == 0 then resolved[k] = nil end
		end
		table.clear(deadAt)
		task.wait(0.4)
	end
	setLoading(false)

	local playingCount, decodedCount, verifiedCount = 0, 0, 0
	for _, r in ipairs(results) do
		if r.playing then playingCount += 1 end
		if r.protected then
			decodedCount += 1
			if r.conf == 2 then verifiedCount += 1 end
		end
	end
	statusLabel.Text = string.format(
		"พบ %d เพลง  •  กำลังเล่น %d  •  ถอดรหัส %d (ยืนยัน %d)%s  •  อัปเดต %s",
		#results, playingCount, decodedCount, verifiedCount,
		lastHidden > 0 and ("  •  ซ่อนบรูค " .. lastHidden) or "", os.date("%H:%M:%S")
	)

	-- ผลเหมือนเดิม + เป็นรอบอัตโนมัติ: ไม่ล้างลิสต์ (กันปุ่มหายตอนกด + ไม่รีเซ็ตแอนิเมชัน)
	if not force and #results > 0 and sameResults(results, lastResults) then return end

	lastResults = results
	clearQueue()
	watermark.Visible = #results == 0

	if #results == 0 then
		setHero(nil)
		lastMainId = nil
		label({
			Size = UDim2.new(1, 0, 0, 56),
			Text = (settings.onlyPlaying
				and "ไม่พบเพลงที่เล่นอยู่จริง\n(ปิด 'เฉพาะที่เล่นอยู่' เพื่อดูทั้งหมด)"
				or "ไม่พบเสียงเพลง\n(กด 'สแกนซ้ำ' เมื่อเขาเปิดเพลง)")
				.. (lastHidden > 0 and ("\nซ่อนเพลงของแมพบรูคไว้ " .. lastHidden .. " รายการ") or ""),
			TextColor3 = C.mute,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextWrapped = true,
		}, resultList)
		return
	end

	local mainId = results[1].realId
	local changed = lastMainId ~= nil and lastMainId ~= mainId
	lastMainId = mainId

	setHero(results[1])
	local top = results[1]
	if top and not (top.protected and top.conf == 0) then
		task.spawn(function() pcall(fetchAudio, top.realId) end) -- โหลดไฟล์เสียงรอไว้ล่วงหน้า
	end
	for i = 2, #results do
		makeQueueCard(results[i], i)
	end

	if changed then
		flashHero()
		showToast("เพลงเปลี่ยน → " .. mainId)
	end
end

local rendering = false
renderResults = function(force)
	if rendering then return end
	rendering = true
	scanning = true
	local ok, err = pcall(doRender, force)
	rendering = false
	scanning = false
	setLoading(false)
	if not ok then warn("[VLGO] " .. tostring(err)) end
end

----------------------------------------------------------------
-- รายชื่อผู้เล่น
----------------------------------------------------------------
local function renderPlayers()
	for _, c in ipairs(playerList:GetChildren()) do
		if c:IsA("TextButton") then c:Destroy() end
	end

	local function item(title, sub, thumb, order, active, onClick)
		local base = active and C.white or C.card
		local b = new("TextButton", {
			Size = UDim2.new(1, -4, 0, 38),
			BackgroundColor3 = base,
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = order,
		}, playerList)
		round(b, 10)
		if not active then outline(b, C.line) end
		connect(b.MouseEnter, function() tween(b, { BackgroundColor3 = active and C.soft or C.hover }) end)
		connect(b.MouseLeave, function() tween(b, { BackgroundColor3 = base }) end)

		local textX = 10
		if thumb then
			local av = new("ImageLabel", {
				Size = UDim2.fromOffset(26, 26),
				Position = UDim2.new(0, 6, 0.5, -13),
				BackgroundColor3 = C.bg,
				Image = thumb,
			}, b)
			round(av, 7)
			textX = 38
		end
		label({
			Size = UDim2.new(1, -(textX + 6), 0, 15),
			Position = UDim2.new(0, textX, 0, sub and 5 or 11),
			Text = title,
			Font = Enum.Font.GothamBold,
			TextSize = 11,
			TextColor3 = active and C.black or C.white,
		}, b)
		if sub then
			label({
				Size = UDim2.new(1, -(textX + 6), 0, 12),
				Position = UDim2.new(0, textX, 0, 21),
				Text = sub,
				TextSize = 9,
				TextColor3 = active and Color3.fromRGB(70, 70, 70) or C.mute,
			}, b)
		end
		connect(b.MouseButton1Click, function()
			playClick()
			onClick()
		end)
	end

	item("ทั้งแมพ (ทุกคน)", nil, nil, 0, wholeMap, function()
		wholeMap = true
		lastMainId = nil
		renderPlayers()
		renderResults(true)
	end)

	local q = searchBox.Text:lower()
	for i, p in ipairs(Players:GetPlayers()) do
		if q == "" or p.Name:lower():find(q, 1, true) or p.DisplayName:lower():find(q, 1, true) then
			item(
				p.DisplayName, "@" .. p.Name,
				"rbxthumb://type=AvatarHeadShot&id=" .. p.UserId .. "&w=48&h=48",
				i, (not wholeMap) and selected == p,
				function()
					wholeMap = false
					selected = p
					lastMainId = nil
					renderPlayers()
					renderResults(true)
				end
			)
		end
	end
end

----------------------------------------------------------------
-- WIRING
----------------------------------------------------------------
connect(copyMainBtn.MouseButton1Click, function()
	if idBox.Text == "" then return end
	copyMainBtn.Text = copyText(idBox.Text, idBox) and "สำเร็จ ✓" or "ไฮไลต์แล้ว"
	task.delay(1.2, function()
		if copyMainBtn.Parent then copyMainBtn.Text = "คัดลอก" end
	end)
end)

connect(listenMainBtn.MouseButton1Click, function()
	if idBox.Text == "" then return end
	toggleListen(idBox.Text)
end)

connect(sendMainBtn.MouseButton1Click, function()
	if not heroResult then return showToast("ยังไม่มี ID ให้ส่ง") end
	doSend(heroResult, sendMainBtn, "ส่งดิส")
end)

connect(rawBtn.MouseButton1Click, function()
	if not heroResult then return end
	local ok = copyText(heroResult.raw, nil)
	if not ok then copyText(heroResult.raw, idBox) end
	rawBtn.Text = ok and "✓" or "เลือก"
	task.delay(1.2, function()
		if rawBtn.Parent then rawBtn.Text = "RAW" end
	end)
end)

connect(copyAllBtn.MouseButton1Click, function()
	if #lastResults == 0 then return end
	local ids = {}
	for _, r in ipairs(lastResults) do table.insert(ids, r.realId) end
	copyAllBtn.Text = copyText(table.concat(ids, "\n"), nil) and "คัดลอกแล้ว ✓" or "คัดลอกไม่ได้"
	task.delay(1.2, function()
		if copyAllBtn.Parent then copyAllBtn.Text = "คัดลอกทั้งหมด" end
	end)
end)

connect(autoBtn.MouseButton1Click, function()
	autoScan = not autoScan
	autoBtn.Text = (autoScan and "● " or "○ ") .. "สแกนอัตโนมัติ"
	setToggle(autoBtn, autoScan)
	liveBadge.Visible = autoScan
end)

connect(onlyBtn.MouseButton1Click, function()
	settings.onlyPlaying = not settings.onlyPlaying
	onlyBtn.Text = (settings.onlyPlaying and "● " or "○ ") .. "เฉพาะที่เล่นอยู่"
	setToggle(onlyBtn, settings.onlyPlaying)
	task.spawn(renderResults, true)
end)

connect(brookBtn.MouseButton1Click, function()
	settings.hideBrook = not settings.hideBrook
	brookBtn.Text = (settings.hideBrook and "● " or "○ ") .. "ซ่อนเพลงบรูค"
	setToggle(brookBtn, settings.hideBrook)
	task.spawn(renderResults, true)
end)

connect(refreshBtn.MouseButton1Click, renderPlayers)
connect(rescanBtn.MouseButton1Click, function() task.spawn(renderResults, true) end)
connect(searchBox:GetPropertyChangedSignal("Text"), renderPlayers)
connect(Players.PlayerAdded, renderPlayers)
connect(Players.PlayerRemoving, function(p)
	if selected == p then selected = localPlayer end
	task.defer(renderPlayers)
end)

local function shutdown()
	stopListen()
	for _, c in ipairs(connections) do c:Disconnect() end
	table.clear(connections)
end

connect(closeBtn.MouseButton1Click, function()
	shutdown()
	gui:Destroy()
end)
gui.Destroying:Connect(shutdown)

-- สแกนอัตโนมัติ
task.spawn(function()
	while gui.Parent do
		task.wait(AUTO_INTERVAL)
		if autoScan and main.Visible then
			renderResults(false)
		end
	end
end)

-- เวลา/แถบความคืบหน้า/ปุ่มฟัง อัปเดตสด (ลูปเดียวสำหรับทั้งหน้าจอ)
task.spawn(function()
	while gui.Parent do
		local hr = heroResult
		if hr then
			local snd = hr.sound
			if snd and snd.Parent then
				local len = snd.TimeLength
				heroTime.Text = fmtTime(snd.TimePosition) .. " / " .. fmtTime(len)
				heroProg.Size = UDim2.new(len > 0 and math.clamp(snd.TimePosition / len, 0, 1) or 0, 0, 1, 0)
			else
				heroTime.Text = "-"
			end
			local now = listen.id == hr.realId
			if now ~= heroListening then
				heroListening = now
				listenMainBtn.Text = now and "■ หยุด" or "▶ ฟัง"
				setToggle(listenMainBtn, now)
			end
		end
		for _, it in ipairs(live) do
			if it.sub.Parent then
				local snd = it.r.sound
				local t = (snd and snd.Parent)
					and (fmtTime(snd.TimePosition) .. " / " .. fmtTime(snd.TimeLength)) or "-"
				it.sub.Text = "ID " .. it.r.realId .. "  •  " .. (it.r.playing and "▶ " or "❚❚ ") .. t
				local now = listen.id == it.r.realId
				if now ~= it.wasListening then
					it.wasListening = now
					it.listenBtn.Text = now and "■ หยุด" or "▶ ฟัง"
					setToggle(it.listenBtn, now)
				end
			end
		end
		task.wait(0.3)
	end
end)

-- กระพริบ: การ์ดเพลงหลัก (+ปก + จุด) ตลอดที่เพลงเล่นอยู่, เร็ว/แรงขึ้นตอนสแกนอัตโนมัติ
task.spawn(function()
	local on = false
	while gui.Parent do
		on = not on
		local playingMain = heroResult and heroResult.playing
		if playingMain then
			local dim = autoScan and 0.9 or 0.65
			tween(heroStroke, { Transparency = on and 0 or dim }, 0.4)
			tween(coverStroke, { Transparency = on and 0 or 0.85 }, 0.4)
			tween(heroDot, { BackgroundTransparency = on and 0 or 0.85 }, 0.4)
		else
			heroStroke.Transparency = 0.6
			coverStroke.Transparency = 0.8
			heroDot.BackgroundTransparency = 0.6
		end
		if autoScan then
			tween(liveDot, { BackgroundTransparency = on and 0 or 0.8 }, 0.4)
			tween(orbStroke, { Transparency = on and 0 or 0.7 }, 0.4)
		else
			orbStroke.Transparency = 0
			liveDot.BackgroundTransparency = 0
		end
		task.wait(0.45)
	end
end)

-- equalizer บนปกเพลงหลัก
task.spawn(function()
	while gui.Parent do
		if eq.Visible then
			for _, b in ipairs(eqBars) do
				tween(b, { Size = UDim2.fromOffset(4, math.random(3, 16)) }, 0.2)
			end
		end
		task.wait(0.22)
	end
end)

renderPlayers()
setOpen(true)
task.spawn(renderResults, true)
