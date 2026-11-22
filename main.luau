--!strict
-- Filler skip for Ratchet & Clank: Going Commando (NTSC-U v1.01, OpenRAC "ntsc").
--
-- While one of the long story sections is starting or under way, hold L1+R1 for a few
-- seconds to skip it. Let go (or keep playing) to carry on as normal. Nothing is drawn on
-- screen; each skip writes a line to the game's log.
--
-- Addresses are from OpenRAC/rac2-decomp (src/, NTSC-U v1.01). Each skip gives the same
-- progress the game gives for finishing that section.

if openrac.version ~= "ntsc" then
	openrac.warn(`only NTSC-U v1.01 ("ntsc") is supported; this disc is "{openrac.version}", so the mod does nothing`)
	return
end

local read, write, log = openrac.read, openrac.write, openrac.log

local TICKS = 60 -- NTSC-U runs 60 ticks a second

---------------------------------------------------------------------------------------------
-- Addresses (fixed in every level unless noted)
---------------------------------------------------------------------------------------------
local MAP = 0x1A79F0 -- s32 current level
local GAME_MODE = 0x1A8F00 -- s32 in levels: 0 play, 1 movie, 2 scene, 3 pause, 6 loading
local HERO_POS = 0x189EA0 -- f32 x, y, z (hero 0x189E20 + 0x80)
local HERO_STAND_ON = 0x18A15C -- the moby the hero stands on (+0x33C)
local HERO_STAND_ACTIVE = 0x18A160 -- (+0x340)
local HERO_CHAR = 0x18C0D4 -- u8: 0 Ratchet, 1 Clank (+0x22B4)
local HERO_ALONE = 0x18C31C -- u16: set while Ratchet and Clank are apart (+0x24FC)
local FLAGS = 0x1395B8 -- g_game_flag_table, story bytes
local GROUP_FLAGS = 0x19B2E8 -- g_moby_group_flags: + level*16 + group, bit 0x80 = done
local ITEM_OWNED = 0x1A7AF8 -- u8 per item
local ITEM_UNLOCKED = 0x1A7B30 -- u8 per item (the second set the game writes with the owned bytes)

-- Moby arrays (per level program): a pointer to the first moby and one to the last.
local MOBYS_ENDAKO = 0x1B2A1C -- L03
local MOBYS_DOBBO = 0x1B285C -- L09
local MOBYS_ARANOS = 0x1B259C -- L14
local MOBY_SIZE = 0x100
-- Moby fields: +0x10 position, +0x20 state, +0x68 vars pointer, +0x94 previous state,
-- +0x96 state timer (u16), +0xAA class (u16), +0xBE trigger bits (bit 0: state entered).

---------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------
local cfg = {
	hold = 3 * TICKS,
	endako = true,
	dobbo = true,
	aranos = true,
	electrolyzer = false,
	infiltrator = false,
	yeedil = false,
}

local function loadSettings()
	cfg.hold = math.max(1, (openrac.setting("hold_seconds") :: number) or 3) * TICKS
	cfg.endako = openrac.setting("endako") ~= false
	cfg.dobbo = openrac.setting("dobbo") ~= false
	cfg.aranos = openrac.setting("aranos") ~= false
	cfg.electrolyzer = openrac.setting("instant_electrolyzer") == true
	cfg.infiltrator = openrac.setting("instant_infiltrator") == true
	cfg.yeedil = openrac.setting("yeedil_hypnomatic_skip") == true
end
loadSettings()
pcall(function()
	openrac.on_settings(loadSettings) -- interface 1.15; older games just keep the start's values
end)

---------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------
local function u8(a: number): number return read("u8", a) end
local function u16(a: number): number return read("u16", a) end
local function u32(a: number): number return read("u32", a) end
local function i32(a: number): number return read("i32", a) end
local function f32(a: number): number return read("f32", a) end

local function inRam(a: number): boolean
	return a >= 0x100000 and a < 0x2000000
end

local function dist2d(a: number, b: number): number
	local dx = f32(a) - f32(b)
	local dy = f32(a + 4) - f32(b + 4)
	return math.sqrt(dx * dx + dy * dy)
end

-- The game's moby_set_state(moby, state, -1).
local function setState(moby: number, state: number)
	local prev = u8(moby + 0x20)
	write("u8", moby + 0x20, state)
	write("u8", moby + 0x94, prev)
	write("u16", moby + 0x96, 0)
	write("u8", moby + 0xBE, bit32.band(u8(moby + 0xBE), 0xFE))
end

local function markGroupDone(level: number, group: number)
	if group < 0 or group > 15 then return end
	local a = GROUP_FLAGS + level * 16 + group
	write("u8", a, bit32.bor(u8(a), 0x80))
end

local function teleportHero(x: number, y: number, z: number)
	write("f32", HERO_POS, x)
	write("f32", HERO_POS + 4, y)
	write("f32", HERO_POS + 8, z)
end

-- Finds the first live moby of a class in a level's moby array. Cached per level.
local cache: { [string]: number } = {}
local nextScan: { [string]: number } = {}
local tick = 0

local function findMoby(key: string, arrayPtr: number, class: number): number?
	local m = cache[key]
	if m and u16(m + 0xAA) == class and u8(m + 0x20) < 0x80 then
		return m
	end
	cache[key] = nil
	if (nextScan[key] or 0) > tick then return nil end
	nextScan[key] = tick + 30 -- rescan at most twice a second
	local first, last = u32(arrayPtr), u32(arrayPtr + 4)
	if not inRam(first) or last < first or (last - first) > 4096 * MOBY_SIZE then return nil end
	local p = first
	while p <= last do
		if u16(p + 0xAA) == class and u8(p + 0x20) < 0x80 then
			cache[key] = p
			return p
		end
		p += MOBY_SIZE
	end
	return nil
end

---------------------------------------------------------------------------------------------
-- The pad: L1 (bit 10) and R1 (bit 11) of pad 0; a bit is clear while held.
---------------------------------------------------------------------------------------------
local comboHeld = false
openrac.on_pad(function(port: number, report: buffer)
	if port ~= 0 or buffer.len(report) < 2 then return end
	local buttons = buffer.readu16(report, 0)
	comboHeld = bit32.band(buttons, 0x0C00) == 0
end)

---------------------------------------------------------------------------------------------
-- Endako: Clank on his own, until he stands on the switch that frees Ratchet
-- (moby class 2568, clank_scene_switch_update: state 2 waits for Clank on it).
---------------------------------------------------------------------------------------------
local endakoJob: { moby: number, t: number, tries: number }? = nil

local function endakoWindow(): number?
	if not cfg.endako or endakoJob then return nil end
	local sw = findMoby("endako", MOBYS_ENDAKO, 2568)
	if sw and u8(sw + 0x20) == 2 and u8(HERO_CHAR) == 1 then
		return sw
	end
	return nil
end

local function endakoTeleport(sw: number)
	teleportHero(f32(sw + 0x10), f32(sw + 0x14), f32(sw + 0x18) + 1.0)
end

local function endakoSkip(sw: number)
	log("Endako: skipping the Clank section (putting Clank on the switch)")
	endakoTeleport(sw)
	endakoJob = { moby = sw, t = 0, tries = 1 }
end

local function endakoUpdate()
	local job = endakoJob
	if not job then return end
	if i32(MAP) ~= 3 or u8(job.moby + 0x20) ~= 2 then
		if i32(MAP) == 3 then log("Endako: Clank section skipped") end
		endakoJob = nil
		return
	end
	if i32(GAME_MODE) ~= 0 then return end -- the ending scene is queued: wait
	job.t += 1
	if job.tries >= 2 then
		-- Landing on it did not register yet: tell the switch Clank stands on it.
		write("u32", HERO_STAND_ON, job.moby)
		write("u32", HERO_STAND_ACTIVE, 1)
	end
	if job.t >= 45 then
		if job.tries >= 4 then
			openrac.warn("Endako: the skip did not take; finish the section normally")
			endakoJob = nil
			return
		end
		job.t = 0
		job.tries += 1
		endakoTeleport(job.moby)
	end
end

---------------------------------------------------------------------------------------------
-- Dobbo: the man (class 3678) who sends Clank to Dobbo Orbit. Skipping marks the battle won,
-- so instead of the trip he gives the reward scene and puts Joba on the map.
---------------------------------------------------------------------------------------------
local ORBIT_UNLOCKED = FLAGS + 0x1D -- 0x1395D5
local ORBIT_STARTED = FLAGS + 0x2D -- 0x1395E5: "Clank went up to orbit". The man sets it when he sends
-- you; on the next Dobbo load a moby (L09 0x407088) plays the Giant Clank shrink scene, puts the hero on
-- the pad and clears it. The skip never goes to orbit, so it must stay clear.
local ORBIT_DONE = FLAGS + 0x2E -- 0x1395E6

local function dobboWindow(): number?
	if not cfg.dobbo then return nil end
	if u8(ORBIT_DONE) ~= 0 or u8(ORBIT_UNLOCKED) ~= 0 then return nil end
	local npc = findMoby("dobbo", MOBYS_DOBBO, 3678)
	if npc and u8(npc + 0x20) == 1 and dist2d(HERO_POS, npc + 0x10) < 25 then
		return npc
	end
	return nil
end

local function dobboSkip(npc: number)
	write("u8", ORBIT_UNLOCKED, 1)
	write("u8", ORBIT_STARTED, 0)
	write("u8", ORBIT_DONE, 1)
	setState(npc, 3)
	log("Dobbo: Giant Clank battle counted as won; talk to the man to finish")
end

---------------------------------------------------------------------------------------------
-- Aranos Prison: one controller (class 4351, lift_scene_update) runs the four sections:
-- state 2 Clank, 3 Ratchet, 4 Clank, 5 Ratchet, 7 reunited; 6 is the fade between them.
---------------------------------------------------------------------------------------------
local LIFT_SCENE_FLAG = 0x1395E1
local ARANOS_DOOR_TABLE = 0x1B268C -- L14 g_platform_projection_table (pointer), 0x80 a record

local aranosJob: { ctl: number, kind: number, t: number }? = nil

local function poolEntry(vars: number, off: number): number?
	local idx = i32(vars + off)
	local pool = u32(MOBYS_ARANOS)
	if idx < 0 or not inRam(pool) then return nil end
	return pool + idx * MOBY_SIZE
end

local function aranosWindow(): number?
	if not cfg.aranos or aranosJob then return nil end
	local ctl = findMoby("aranos", MOBYS_ARANOS, 4351)
	if not ctl then return nil end
	local st = u8(ctl + 0x20)
	if st >= 2 and st <= 5 and bit32.band(u8(ctl + 0xBE), 1) == 1 then
		return ctl
	end
	return nil
end

local function aranosAdvance(ctl: number, flagOff: number, nextState: number)
	local vars = u32(ctl + 0x68)
	markGroupDone(14, i32(vars + flagOff))
	write("i32", vars + 0x70, nextState)
	setState(ctl, 6) -- the game's fade, then the next section's own start
end

local function aranosDoorPos(ctl: number): { number }?
	local vars = u32(ctl + 0x68)
	local tbl = u32(ARANOS_DOOR_TABLE)
	if not inRam(tbl) then return nil end
	local p = tbl + i32(vars + 0x34) * 0x80 + 0x30
	return { f32(p), f32(p + 4), f32(p + 8) }
end

local function finishRatchet2(ctl: number)
	local door = aranosDoorPos(ctl)
	if door then teleportHero(door[1], door[2], door[3]) end
	log("Aranos Prison: last Ratchet section skipped; Ratchet and Clank are reunited")
end

local function aranosSkip(ctl: number)
	local st = u8(ctl + 0x20)
	local vars = u32(ctl + 0x68)
	if st == 2 then
		-- Clank 1 ends when the guard is beaten: mark him beaten and let the game finish it.
		log("Aranos Prison: skipping Clank's first section")
		local guard = poolEntry(vars, 0x48)
		if guard then
			local gv = u32(guard + 0x68)
			if inRam(gv) then write("i32", gv + 4, 1) end
		end
		aranosJob = { ctl = ctl, kind = 2, t = 0 }
	elseif st == 3 then
		log("Aranos Prison: skipping Ratchet's first section")
		aranosAdvance(ctl, 0x64, 4)
	elseif st == 4 then
		log("Aranos Prison: skipping Clank's second section")
		aranosAdvance(ctl, 0x58, 5)
	elseif st == 5 then
		-- Ratchet 2 ends when its switch moby is gone: remove it as the game does.
		log("Aranos Prison: skipping Ratchet's last section")
		local sw = poolEntry(vars, 0x4C)
		if sw then write("u8", sw + 0x20, 0xFD) end
		aranosJob = { ctl = ctl, kind = 5, t = 0 }
	end
end

local function aranosUpdate()
	local job = aranosJob
	if not job then return end
	if i32(MAP) ~= 14 then
		aranosJob = nil
		return
	end
	local st = u8(job.ctl + 0x20)
	job.t += 1
	if job.kind == 2 then
		if st ~= 2 then
			aranosJob = nil
			return
		end
		if job.t >= 30 then -- the guard did not count as beaten: move on by hand
			write("u8", LIFT_SCENE_FLAG, 1)
			aranosAdvance(job.ctl, 0x54, 3)
			aranosJob = nil
		end
	elseif job.kind == 5 then
		if st == 7 then
			finishRatchet2(job.ctl)
			aranosJob = nil
		elseif job.t >= 60 and st == 5 and i32(GAME_MODE) == 0 then
			-- The switch did not count: do what the section's end does.
			local vars = u32(job.ctl + 0x68)
			markGroupDone(14, i32(vars + 0x5C))
			for _, item in { 2, 3 } do
				write("u8", ITEM_OWNED + item, 1)
				write("u8", ITEM_UNLOCKED + item, 1)
			end
			write("u16", HERO_ALONE, 0)
			setState(job.ctl, 7)
			finishRatchet2(job.ctl)
			aranosJob = nil
		end
	end
end

---------------------------------------------------------------------------------------------
-- Instant puzzles (settings, no buttons). Both puzzles run in game mode 7; while it is on, the
-- mod finds the puzzle's moby and moves it to its own "solved" step, so the game runs its real
-- success path (door or lift powered, puzzle saved as done).
--   Electrolyzer: controller class 2198 (challenge_controller_update). State 6 = playing,
--     state 8 = solved; with its timer at 241 state 8 finishes at once.
--   Infiltrator: lock class 2857 (state 6 = playing); its ball (class 2856, pointer at the
--     lock's vars +0x58) has state 5 = solved; with +0xBE bit 0 set and timer 0 it finishes at
--     once and sets the lock's "completed" (vars +0x60).
---------------------------------------------------------------------------------------------
local PUZZLE_MODE = 7
local ELECTROLYZER = 2198
local INFILTRATOR_LOCK = 2857
local INFILTRATOR_BALL = 2856
local HERO_MOBY = 0x18C0B0 -- u32: the player's moby, in the level's moby array

local puzzleScan = { pos = 0, done = false, found = {} :: { number } }
local puzzleDone: { [number]: boolean } = {}

local function resetPuzzleScan()
	puzzleScan.pos = 0
	puzzleScan.done = false
	table.clear(puzzleScan.found)
end

-- Scans the moby array around the player's moby, 256 places a tick, for the puzzle classes.
local SCAN_RANGE = 2048
local function scanPuzzles()
	if puzzleScan.done then return end
	local hero = u32(HERO_MOBY)
	if not inRam(hero) then return end
	local stop = math.min(puzzleScan.pos + 256, 2 * SCAN_RANGE)
	for i = puzzleScan.pos, stop - 1 do
		local p = hero + (i - SCAN_RANGE) * MOBY_SIZE
		if inRam(p) then
			local c = u16(p + 0xAA)
			if (c == ELECTROLYZER and cfg.electrolyzer) or (c == INFILTRATOR_LOCK and cfg.infiltrator) then
				if u8(p + 0x20) < 0x80 then table.insert(puzzleScan.found, p) end
			end
		end
	end
	puzzleScan.pos = stop
	if stop >= 2 * SCAN_RANGE then puzzleScan.done = true end
end

local function puzzleUpdate()
	if not (cfg.electrolyzer or cfg.infiltrator) then return end
	if i32(GAME_MODE) ~= PUZZLE_MODE then
		if puzzleScan.pos > 0 then resetPuzzleScan() end
		table.clear(puzzleDone)
		return
	end
	scanPuzzles()
	for _, m in puzzleScan.found do
		if not puzzleDone[m] and u8(m + 0x20) == 6 then
			local class = u16(m + 0xAA)
			if class == ELECTROLYZER then
				write("u8", m + 0x94, 6)
				write("u8", m + 0x20, 8)
				write("u16", m + 0x96, 241)
				write("u8", m + 0xBE, bit32.band(u8(m + 0xBE), 0xFE))
				puzzleDone[m] = true
				log("Electrolyzer puzzle solved instantly")
			elseif class == INFILTRATOR_LOCK then
				local vars = u32(m + 0x68)
				local ball = if inRam(vars) then u32(vars + 0x58) else 0
				if inRam(ball) and u16(ball + 0xAA) == INFILTRATOR_BALL then
					local bs = u8(ball + 0x20)
					if bs >= 2 and bs <= 4 then -- the ball has finished setting up
						write("u32", vars + 0x60, 1)
						write("u8", ball + 0x94, bs)
						write("u8", ball + 0x20, 5)
						write("u16", ball + 0x96, 0)
						write("u8", ball + 0xBE, bit32.bor(u8(ball + 0xBE), 1))
						puzzleDone[m] = true
						log("Infiltrator puzzle solved instantly")
					end
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------
-- Yeedil Hypnomatic skip (setting; hold L1+R1). The two places a hypnotised Receiver Bot is
-- needed, for players who skipped Damosel's Hypnomatic:
--   1. Near the first Megacorp Vendor (class 11), on the bridge: the Swingshot nodes across the
--      gap (classes 758/803) wait in state 2 until their group's flag is set (vars +0x30 = the
--      group). The skip sets it, as the bot's pad does, and fires that pad.
--   2. Near the large door to the teleporter: the bot pad or switch that opens it (classes 3792 /
--      4617) is fired, as the bot standing on it would.
-- Pads (rotating_trigger_update, 3792): state 0 = waiting; a touch counts in its save nibble
-- (0x19B4A8 + 20*0x400 + uid/2), then +0x20 = 1, +0xBC = 1, linked moby (vars +0) +0xBE |= 4.
-- Switches (floor_l20_switch_update, 4617, robot ones have vars +0x2C set): state 1 = waiting;
-- state 2, its four links (vars +0..+0xC, modes +0x10..) signalled, event group flag (+0x28) set.
---------------------------------------------------------------------------------------------
local YEEDIL = 20
local Y_MOBYS = 0x1B2F9C -- L20 moby array: first, then last (+4)
local Y_GROUP_LISTS = 0x1FBB20 -- L20: a u32 pointer a group to its u16 member list
local Y_NIBBLES = 0x19B4A8 + YEEDIL * 0x400
local Y_GROUP_FLAGS = GROUP_FLAGS + YEEDIL * 16
local VENDOR = 11
local NODE_A, NODE_B = 758, 803
local BOT_PAD = 3792
local BOT_SWITCH = 4617
local VENDOR_REACH = 12 -- Ratchet this close to the vendor
local NODE_REACH = 120 -- the gap's Swingshot nodes this close to the vendor
local DOOR_REACH = 15 -- Ratchet this close to what a pad opens

local yScan = { pos = -1, first = 0, last = 0, nextAt = 0, found = {} :: { number }, list = {} :: { number } }

local function resetYeedil()
	yScan.pos = -1
	yScan.nextAt = 0
	table.clear(yScan.found)
	table.clear(yScan.list)
end

local function yMoby(idx: number): number?
	if idx < 0 then return nil end
	local first = u32(Y_MOBYS)
	if not inRam(first) then return nil end
	return first + idx * MOBY_SIZE
end

local function yNear(m: number?, reach: number): boolean
	return m ~= nil and dist2d(HERO_POS, (m :: number) + 0x10) < reach
end

local function signal(m: number?)
	if m then write("u8", m + 0xBE, bit32.bor(u8(m + 0xBE), 4)) end
end

local function setGroupFlag(group: number)
	if group >= 0 and group < 16 then
		write("u8", Y_GROUP_FLAGS + group, bit32.bor(u8(Y_GROUP_FLAGS + group), 0x80))
	end
end

local function groupMembers(group: number): { number }
	local out = {}
	local list = u32(Y_GROUP_LISTS + group * 4)
	if group < 0 or group > 255 or not inRam(list) then return out end
	for k = 0, 255 do
		local e = read("i16", list + k * 2)
		local m = yMoby(bit32.band(e, 0x7FFF))
		if m then table.insert(out, m) end
		if e < 0 then break end
	end
	return out
end

-- Lists the vendors, Swingshot nodes and bot pads, 256 mobys a tick, every few seconds.
local function yeedilScan()
	if yScan.pos < 0 then
		if tick < yScan.nextAt then return end
		local first, last = u32(Y_MOBYS), u32(Y_MOBYS + 4)
		if not inRam(first) or last < first or (last - first) > 4096 * MOBY_SIZE then return end
		yScan.first, yScan.last, yScan.pos = first, last, first
		table.clear(yScan.found)
	end
	local p = yScan.pos
	local stop = math.min(p + 256 * MOBY_SIZE, yScan.last + MOBY_SIZE)
	while p < stop do
		local c = u16(p + 0xAA)
		if (c == VENDOR or c == NODE_A or c == NODE_B or c == BOT_PAD or c == BOT_SWITCH) and u8(p + 0x20) < 0x80 then
			table.insert(yScan.found, p)
		end
		p += MOBY_SIZE
	end
	yScan.pos = p
	if p > yScan.last then
		yScan.list, yScan.found = yScan.found, {}
		yScan.pos = -1
		yScan.nextAt = tick + 2 * TICKS
	end
end

local function padWaiting(m: number): boolean
	local c = u16(m + 0xAA)
	if c == BOT_PAD then return u8(m + 0x20) == 0 end
	if c == BOT_SWITCH then
		local vars = u32(m + 0x68)
		return u8(m + 0x20) == 1 and inRam(vars) and i32(vars + 0x2C) ~= 0
	end
	return false
end

-- What a pad or switch opens.
local function padTargets(m: number): { number }
	local out = {}
	local vars = u32(m + 0x68)
	if not inRam(vars) then return out end
	if u16(m + 0xAA) == BOT_PAD then
		local t = yMoby(i32(vars))
		if t then table.insert(out, t) end
	else
		for k = 0, 3 do
			local t = yMoby(i32(vars + k * 4))
			if t then table.insert(out, t) end
		end
	end
	return out
end

local function firePad(m: number)
	local vars = u32(m + 0x68)
	if not inRam(vars) then return end
	if u8(vars + 0x10) == 0 then -- the touch, counted in the pad's save nibble
		local uid = u16(m + 0xB2)
		local a = Y_NIBBLES + bit32.rshift(uid, 1)
		local v = u8(a)
		if bit32.band(uid, 1) == 1 then
			if bit32.band(bit32.rshift(v, 4), 7) ~= 7 then write("u8", a, v + 0x10) end
		elseif bit32.band(v, 7) ~= 7 then
			write("u8", a, v + 1)
		end
	end
	local group = u8(m + 0xB0)
	if u8(vars + 0x12) ~= 0 and group ~= 0xFF then setGroupFlag(group) end
	write("u8", m + 0x20, 1)
	write("u8", m + 0xBC, 1)
	signal(yMoby(i32(vars)))
	if u8(vars + 0xB) ~= 0 then
		local value = u8(vars + 0xA)
		for _, g in groupMembers(u8(vars + 0xC)) do
			signal(g)
			if value ~= 0xFF then write("u8", g + 0xBC, value) end
		end
	end
end

local function fireSwitch(m: number)
	local vars = u32(m + 0x68)
	if not inRam(vars) then return end
	setState(m, 2)
	for k = 0, 3 do
		local target = yMoby(i32(vars + k * 4))
		if target then
			if i32(vars + 0x10 + k * 4) ~= 0 then
				signal(target)
			else
				write("u8", target + 0xBC, 1)
			end
		end
	end
	local event = u32(vars + 0x28)
	if event ~= 255 then setGroupFlag(event) end
end

local function fire(m: number)
	if u16(m + 0xAA) == BOT_PAD then firePad(m) else fireSwitch(m) end
end

-- 1. The bridge: a vendor Ratchet stands by, with waiting Swingshot nodes near it.
local function yeedilBridge(): { number }?
	for _, v in yScan.list do
		if u16(v + 0xAA) == VENDOR and yNear(v, VENDOR_REACH) then
			local groups = {}
			for _, n in yScan.list do
				local c = u16(n + 0xAA)
				if (c == NODE_A or c == NODE_B) and u8(n + 0x20) == 2 and dist2d(v + 0x10, n + 0x10) < NODE_REACH then
					local vars = u32(n + 0x68)
					local g = if inRam(vars) then i32(vars + 0x30) else -1
					if g >= 0 and g < 16 and u8(Y_GROUP_FLAGS + g) == 0 then
						groups[g] = true
					end
				end
			end
			local out = {}
			for g in groups do table.insert(out, g) end
			if #out > 0 then return out end
		end
	end
	return nil
end

local function yeedilBridgeSkip(groups: { number })
	for _, g in groups do
		setGroupFlag(g)
		for _, m in yScan.list do -- the bot pad of that group, so it stays done
			if u16(m + 0xAA) == BOT_PAD and u8(m + 0xB0) == g and padWaiting(m) then firePad(m) end
		end
	end
	log("Yeedil: the bridge's Swingshot targets are on")
end

-- 2. The door: a waiting bot pad or switch whose door Ratchet stands by.
local function yeedilDoor(): number?
	for _, m in yScan.list do
		if padWaiting(m) then
			for _, t in padTargets(m) do
				local c = u16(t + 0xAA)
				if c ~= NODE_A and c ~= NODE_B and yNear(t, DOOR_REACH) then return m end
			end
		end
	end
	return nil
end

local function yeedilWindow(): (() -> ())?
	if not cfg.yeedil or u8(HERO_CHAR) == 4 then return nil end
	yeedilScan()
	local groups = yeedilBridge()
	if groups then
		return function() yeedilBridgeSkip(groups :: { number }) end
	end
	local pad = yeedilDoor()
	if pad then
		return function()
			fire(pad :: number)
			log("Yeedil: the robot's door switch pressed for you")
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------
-- Each tick: find the open skip window, count the hold, run pending jobs.
---------------------------------------------------------------------------------------------
local holdTicks = 0
local armed = true -- the buttons must be let go between two skips
local lastMap = -1

openrac.on_frame(function()
	tick += 1
	local map = i32(MAP)
	if map ~= lastMap then
		lastMap = map
		table.clear(cache)
		table.clear(nextScan)
		endakoJob = nil
		aranosJob = nil
		resetPuzzleScan()
		resetYeedil()
	end

	endakoUpdate()
	aranosUpdate()
	puzzleUpdate()

	if not comboHeld then
		holdTicks = 0
		armed = true
	end

	if i32(GAME_MODE) ~= 0 then
		holdTicks = 0
		return
	end

	local action: (() -> ())? = nil
	if map == 3 then
		local sw = endakoWindow()
		if sw then action = function() endakoSkip(sw) end end
	elseif map == 9 then
		local npc = dobboWindow()
		if npc then action = function() dobboSkip(npc) end end
	elseif map == 20 then
		action = yeedilWindow()
	elseif map == 14 then
		local ctl = aranosWindow()
		if ctl then action = function() aranosSkip(ctl) end end
	end

	if not action then
		holdTicks = 0
		return
	end
	if comboHeld and armed then
		holdTicks += 1
		if holdTicks >= cfg.hold then
			holdTicks, armed = 0, false
			action()
		end
	end
end)

log("Filler skip ready: hold L1+R1 during a skippable section")
