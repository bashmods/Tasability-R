--[[
-modified 1.25 by bash
⠀variant:test by bash⠀
]]


--//Changelogs

-- Added Keyboard Overlay themes, fixed a bug that randomaly played animations during idling. Semi-handling fling frames animations, linked keyboard overlay to reading instead of writing.

-- Config
local FPS = 144 -- Put whatever FPS you want here, changes fps cap for the tas.
local PlaybackInputs = true -- Sets if you want replays to playback your inputs when playing them (AHK connection is required for mouse scroll playback)
local PlaybackMouseLocation = false -- Sets if you want replays to move your mouse when playing them (glitchy when loading checkpoints)
local RoundDigits = 50 -- Rounds all numbers when writing, to greatly decrease file size (set to 50 to disable rounding)
local ReplayStartTime = 1 -- Number of seconds to wait before starting to read the replay
local FrameBacktrackCount = 150 -- Number of frames to backtrack when frozen to see which keys are currently pressed. Increase as much as your computer can handle
local MinimumJSONFPS = 1/144 -- Lowest you want your FPS to go while encoding/decoding (higher = faster encoding/decoding, lower = better fps) 1/30: 30 fps, 1/60: 60 fps\
local BypassAntiExploit = false -- If this is true games with anti cheat (like beans) will not kick you, but there is a chance animations will be broken



-- Inputs that will not be recorded
local InputBlacklist = {
	["Q"] = true;
	["T"] = true;
	["F"] = true;
	["G"] = true;
	["E"] = true;
	["U"] = true;
	["Z"] = true;
	["R"] = true;
	["V"] = true;
	["Y"] = true;
	["X"] = true;
}

-- Color codes for the color code frame
local ColorCodes = {
	WaitingForInput = Color3.new(1,1,0);
	Recording = Color3.new(1,0,0);
	Reading = Color3.new(0,0.5,1);
	Paused = Color3.new(1,0.7,0);
	Idle = Color3.new(1,1,1);
	Frozen = Color3.new(0,1,1);
	LookAround = Color3.new(0.65,0.45,1);
	
	None = Color3.new(0,0,0);
}

-- data roblox cursor xD
local Cursors = {
	["ArrowFarCursor"] = {
		Icon = "rbxasset://textures/Cursors/KeyboardMouse/ArrowFarCursor.png";
		Size = UDim2.fromOffset(64,64);
		Offset = Vector2.new(4, 4);
	};
	["MouseLockedCursor"] = {
		Icon = "rbxasset://textures/MouseLockedCursor.png";
		Size = UDim2.fromOffset(32,32);
		Offset = Vector2.new(-16,-16);
	};
}

-- Constants
local Version = "V1.2.5"
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Player = game.Players.LocalPlayer
local Mouse = Player:GetMouse()
local random = math.random
local min = math.min
local max = math.max
local floor = math.floor
local ceil = math.ceil
local ReplayFileBeginning = "{\"Replay\":"
local ReplayFileEnding = "}"
-- The stock camera module is not present in every game, and an unbounded WaitForChild there
-- stalls the whole load on a warning. Bound the wait and carry on without the shift-lock
-- bindings when the game does not ship the stock module.
local PlayerModule = Player.PlayerScripts:FindFirstChild("PlayerModule")
if not PlayerModule then
	PlayerModule = Player.PlayerScripts:WaitForChild("PlayerModule", 5)
end
local ShiftLockBoundKeys = PlayerModule and PlayerModule:FindFirstChild("CameraModule")
if ShiftLockBoundKeys then
	ShiftLockBoundKeys = ShiftLockBoundKeys:FindFirstChild("MouseLockController")
end
if ShiftLockBoundKeys then
	ShiftLockBoundKeys = ShiftLockBoundKeys:FindFirstChild("BoundKeys")
end
local ShiftLockEnabled = false
local GuiInset = GuiService:GetGuiInset()

-- Variables
local InterpHRPPrev    = nil
local InterpHRPTarget  = nil
local InterpStart      = 0
local InterpDuration   = 1/60
local pathVisualsEnabled = false
local pathLines = {}
local pathStartText = nil
local pathEndText = nil
local PlaybackPressedKeys = {}
local ReplayNeedsReload = true -- Flag to track if we need to reload from file
local LastLoadedPath = nil -- Track which file was last loaded
local ExecutionTick = tick()
local PlaceId = game.PlaceId
-- These will be set later --
local Character = nil
local Humanoid = nil
local RootPart = nil
local DefaultGravity = nil
local DefaultJumpPower = nil
local DefaultWalkSpeed = nil
local Resolution = nil
local ConsoleMessage = print
-----------------------------
local Reading = false
local Paused = false
local PlaybackCtl = {} -- Pause / Unpause / Take over (filled in below)
-- Slow-motion recording aid. Only the live game is slowed (never playback) and the
-- recorder drops the extra samples, so a replay recorded in slow motion plays at normal speed.
local SpeedHack = {
	Enabled = false,
	Speed = 0.50,        -- 1.00 = normal, 0.10 = ten times slower
	AppliedScale = 1,    -- scale currently written to the humanoid / gravity
	Accumulator = 0,     -- frame-drop accumulator used by the recorder
	NormalTime = 0,      -- replay timeline in normal-time ticks (Frame[14]); lets the speed optimizer resample
	-- Capture rate, measured from the gaps between recorded frames. The configured FPS is a
	-- target, not a fact: a client that renders at 120 while the cap says 144 samples the world
	-- every 1/120 s, so a replay that plays one frame per 1/144 s runs 20% fast. The gaps say
	-- what the run actually was; they are stored with the file so playback matches it.
	Rate = { Sum = 0, Count = 0, Prev = nil, Scaled = false, Session = 0, Loaded = false },
	PendingAnimations = {},
	PendingBegan = {},
	PendingEnded = {},
	HeldInputs = {},     -- keys the keyboard currently has down, so a repeat down is not recorded twice
	OpenKeys = {},       -- keys the tape has pressed with no release behind them yet
	AnimationScale = function() return 1 end, -- replaced below once the runtime is ready
}
local Writing = false
local Saving = false
local AnimateDisabled = false
local Checkpoints = {}
local RenderSteppedConnections = {}
local SteppedConnections = {}
local FolderPath = "Tasability\\"..tostring(PlaceId)
local ReplayPath = isfolder(FolderPath) and #listfiles(FolderPath) >= 1 and listfiles(FolderPath)[1] or FolderPath.."\\Replay.json"
local AHKConnectionFolderPath = "Replayability+_AHK"
local AHKConnectionRequestPath = "Replayability+_AHK/Request"
local ReplayTable = {} -- Should always be used instead of the json string except when encoding or decoding
local RecordingTable = {} -- List of frames that will be added to ReplayTable if recording is saved
local ReplayTableIndex = 0 -- The index in ReplayTable that will be read from
local AnimationQueue = {} -- Functions that were called by the animation script (clear every frame)
local RunSpeed = 0 -- Set in the onRunning function, reset to 0 every frame (AnimationId 2)
local ClimbSpeed = 0 -- Set in the onClimbing function, reset to 0 every frame (AnimationId 4)
local HumanoidStateQueue = {} -- States that were activated on the humanoid (clear every frame)
local InputBeganQueue = {} -- Inputs that have just began (for recording inputs) (clear every frame)
local InputEndedQueue = {} -- Inputs that have just ended (for recording inputs) (clear every frame)
local Cursor = Instance.new("ImageLabel") -- Fake cursor so the icon doesnt change all the time
local CursorIcon = nil -- Icon of the cursor
local CursorSize = nil -- Size of the cursor
local CursorOffset = nil -- Offset of the cursor from UserInputService:GetMouseLocation()
local Dead = false -- If the player is dead this is true
local CameraCFrame = workspace.CurrentCamera.CFrame -- Used when reading so that nothing else can change the camera's CFrame
local Pressed = {} -- Current keys that are pressed
local IgnoreGameProcessed = false -- To ignore GameProcessed in InputBegan, InputChanged, InputEnded

-- Tasability update
local Frozen = false
local FreezeFrame = 1 -- Frame to render while frozen
local SeekDirection = 0 -- Stays 0 normally, -1 when going backwards while frozen, 1 when going fowards
local SeekDirectionMultiplier = 1 -- To go faster or slower when seeking with R and T

-- Converting inputs
-- To add to this table, use https://docs.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes
local InputCodes = {
	["A"] = 0x41;
	["B"] = 0x42;
	["C"] = 0x43;
	["D"] = 0x44;
	["E"] = 0x45;
	["F"] = 0x46;
	["G"] = 0x47;
	["H"] = 0x48;
	["I"] = 0x49;
	["J"] = 0x4A;
	["K"] = 0x4B;
	["L"] = 0x4C;
	["M"] = 0x4D;
	["N"] = 0x4E;
	["O"] = 0x4F;
	["P"] = 0x50;
	["Q"] = 0x51;
	["R"] = 0x52;
	["S"] = 0x53;
	["T"] = 0x54;
	["U"] = 0x55;
	["V"] = 0x56;
	["W"] = 0x57;
	["X"] = 0x58;
	["Y"] = 0x59;
	["Z"] = 0x5A;
	["Space"] = 0x20;
	["LeftShift"] = 0x10;
	["RightShift"] = 0x10;
}

-- Compatibility
mouse1press = mouse1press or mouse1down
mouse2press = mouse2press or mouse2down
mouse1release = mouse1release or mouse1up
mouse2release = mouse2release or mouse2up
keypress = keypress or keydown
keyrelease = keyrelease or keyup

-- Variables used in Animate script
local pose = "Standing" -- The pose that is used in the move function
local currentAnimSpeed = 1.0 -- Animation speed

-- Other
local GUIParent = Player:WaitForChild("PlayerGui")
local json
do -- Overwriting JSON
	json = (function()
																			--
																			-- json.lua
																			--
																			-- Copyright (c) 2020 rxi
																			--
																			-- Permission is hereby granted, free of charge, to any person obtaining a copy of
																			-- this software and associated documentation files (the "Software"), to deal in
																			-- the Software without restriction, including without limitation the rights to
																			-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
																			-- of the Software, and to permit persons to whom the Software is furnished to do
																			-- so, subject to the following conditions:
																			--
																			-- The above copyright notice and this permission notice shall be included in all
																			-- copies or substantial portions of the Software.
																			--
																			-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
																			-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
																			-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
																			-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
																			-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
																			-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
																			-- SOFTWARE.
																			--

																			local json = { _version = "0.1.2" }
																			
																			local t = tick()
																			local currentstr
																			local lasti
																			local function checkwait(i)
																				if tick() - t > MinimumJSONFPS then
																					lasti = lasti or i
																					if i >= lasti then
																						local Type = (type(currentstr) == "table" and "En") or (type(currentstr) == "string" and "De")
																						if Type then
																							ConsoleMessage(Type.."coding... ("..tostring(i).."/"..tostring(#currentstr)..")")
																						end
																						game:GetService("RunService").Stepped:Wait()
																						t = tick()
																						lasti = i
																					end
																				end
																			end

																			-------------------------------------------------------------------------------
																			-- Encode
																			-------------------------------------------------------------------------------

																			

																			local encode

																			local escape_char_map = {
																				[ "\\" ] = "\\",
																				[ "\"" ] = "\"",
																				[ "\b" ] = "b",
																				[ "\f" ] = "f",
																				[ "\n" ] = "n",
																				[ "\r" ] = "r",
																				[ "\t" ] = "t",
																			}

																			local escape_char_map_inv = { [ "/" ] = "/" }
																			for k, v in pairs(escape_char_map) do
																				escape_char_map_inv[v] = k
																			end


																			local function escape_char(c)
																				return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
																			end


																			local function encode_nil(val)
																				return "null"
																			end


																			local function encode_table(val, stack)
																				local res = {}
																				stack = stack or {}

																				-- Circular reference?
																				if stack[val] then error("circular reference") end

																				stack[val] = true

																				if rawget(val, 1) ~= nil or next(val) == nil then
																					-- Treat as array -- check keys are valid and it is not sparse
																					local n = 0
																					for k in pairs(val) do
																						if type(k) ~= "number" then
																							error("invalid table: mixed or invalid key types")
																						end
																						n = n + 1
																					end
																					if n ~= #val then
																						error("invalid table: sparse array")
																					end
																					-- Encode
																					for i, v in ipairs(val) do
																						checkwait(i)
																						table.insert(res, encode(v, stack))
																					end
																					stack[val] = nil
																					
																					return "[" .. table.concat(res, ",") .. "]"

																				else
																					-- Treat as an object
																					local i = 0
																					for k, v in pairs(val) do
																						i = i + 1
																						if type(k) ~= "string" then
																							error("invalid table: mixed or invalid key types")
																						end
																						checkwait(i)
																						table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
																					end
																					stack[val] = nil
																					
																					return "{" .. table.concat(res, ",") .. "}"
																				end
																			end


																			local function encode_string(val)
																				return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
																			end


																			local function encode_number(val)
																				-- Check for NaN, -inf and inf
																				if val ~= val or val <= -math.huge or val >= math.huge then
																					error("unexpected number value '" .. tostring(val) .. "'")
																				end
																				return string.format("%.14g", val)
																			end


																			local type_func_map = {
																				[ "nil"     ] = encode_nil,
																				[ "table"   ] = encode_table,
																				[ "string"  ] = encode_string,
																				[ "number"  ] = encode_number,
																				[ "boolean" ] = tostring,
																			}


																			encode = function(val, stack)
																				local t = type(val)
																				local f = type_func_map[t]
																				if f then
																					t = tick()
																					return f(val, stack)
																				end
																				error("unexpected type '" .. t .. "'")
																			end


																			function json.encode(val)
																				currentstr = val
																				lasti = nil
																				return ( encode(val) )
																			end


																			-------------------------------------------------------------------------------
																			-- Decode
																			-------------------------------------------------------------------------------

																			local parse

																			local function create_set(...)
																				local res = {}
																				for i = 1, select("#", ...) do
																					res[ select(i, ...) ] = true
																				end
																				return res
																			end

																			local space_chars   = create_set(" ", "\t", "\r", "\n")
																			local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
																			local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
																			local literals      = create_set("true", "false", "null")

																			local literal_map = {
																				[ "true"  ] = true,
																				[ "false" ] = false,
																				[ "null"  ] = nil,
																			}


																			local function next_char(str, idx, set, negate)
																				for i = idx, #str do
																					if set[str:sub(i, i)] ~= negate then
																						return i
																					end
																				end
																				return #str + 1
																			end


																			local function decode_error(str, idx, msg)
																				local line_count = 1
																				local col_count = 1
																				for i = 1, idx - 1 do
																					col_count = col_count + 1
																					if str:sub(i, i) == "\n" then
																						line_count = line_count + 1
																						col_count = 1
																					end
																				end
																				error( string.format("%s at line %d col %d", msg, line_count, col_count) )
																			end



																			local function codepoint_to_utf8(n)
																				-- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
																				local f = math.floor
																				if n <= 0x7f then
																					return string.char(n)
																				elseif n <= 0x7ff then
																					return string.char(f(n / 64) + 192, n % 64 + 128)
																				elseif n <= 0xffff then
																					return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
																				elseif n <= 0x10ffff then
																					return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
																						f(n % 4096 / 64) + 128, n % 64 + 128)
																				end
																				error( string.format("invalid unicode codepoint '%x'", n) )
																			end


																			local function parse_unicode_escape(s)
																				local n1 = tonumber( s:sub(1, 4),  16 )
																				local n2 = tonumber( s:sub(7, 10), 16 )
																				-- Surrogate pair?
																				if n2 then
																					return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
																				else
																					return codepoint_to_utf8(n1)
																				end
																			end


																			local function parse_string(str, i)
																				local res = ""
																				local j = i + 1
																				local k = j

																				while j <= #str do
																					local x = str:byte(j)

																					if x < 32 then
																						decode_error(str, j, "control character in string")

																					elseif x == 92 then -- `\`: Escape
																						res = res .. str:sub(k, j - 1)
																						j = j + 1
																						local c = str:sub(j, j)
																						if c == "u" then
																							local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
																								or str:match("^%x%x%x%x", j + 1)
																								or decode_error(str, j - 1, "invalid unicode escape in string")
																							res = res .. parse_unicode_escape(hex)
																							j = j + #hex
																						else
																							if not escape_chars[c] then
																								decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
																							end
																							res = res .. escape_char_map_inv[c]
																						end
																						k = j + 1

																					elseif x == 34 then -- `"`: End of string
																						res = res .. str:sub(k, j - 1)
																						return res, j + 1
																					end

																					j = j + 1
																					checkwait(i)
																				end

																				decode_error(str, i, "expected closing quote for string")
																			end


																			local function parse_number(str, i)
																				local x = next_char(str, i, delim_chars)
																				local s = str:sub(i, x - 1)
																				local n = tonumber(s)
																				if not n then
																					decode_error(str, i, "invalid number '" .. s .. "'")
																				end
																				checkwait(i)
																				return n, x
																			end


																			local function parse_literal(str, i)
																				local x = next_char(str, i, delim_chars)
																				local word = str:sub(i, x - 1)
																				if not literals[word] then
																					decode_error(str, i, "invalid literal '" .. word .. "'")
																				end
																				checkwait(i)
																				return literal_map[word], x
																			end


																			local function parse_array(str, i)
																				local res = {}
																				local n = 1
																				i = i + 1
																				while 1 do
																					local x
																					i = next_char(str, i, space_chars, true)
																					-- Empty / end of array?
																					if str:sub(i, i) == "]" then
																						i = i + 1
																						break
																					end
																					-- Read token
																					x, i = parse(str, i)
																					res[n] = x
																					n = n + 1
																					-- Next token
																					i = next_char(str, i, space_chars, true)
																					local chr = str:sub(i, i)
																					i = i + 1
																					checkwait(i)
																					if chr == "]" then break end
																					if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
																				end
																				return res, i
																			end


																			local function parse_object(str, i)
																				local res = {}
																				i = i + 1
																				while 1 do
																					local key, val
																					i = next_char(str, i, space_chars, true)
																					-- Empty / end of object?
																					if str:sub(i, i) == "}" then
																						i = i + 1
																						break
																					end
																					-- Read key
																					if str:sub(i, i) ~= '"' then
																						decode_error(str, i, "expected string for key")
																					end
																					key, i = parse(str, i)
																					-- Read ':' delimiter
																					i = next_char(str, i, space_chars, true)
																					if str:sub(i, i) ~= ":" then
																						decode_error(str, i, "expected ':' after key")
																					end
																					i = next_char(str, i + 1, space_chars, true)
																					-- Read value
																					val, i = parse(str, i)
																					-- Set
																					res[key] = val
																					-- Next token
																					i = next_char(str, i, space_chars, true)
																					local chr = str:sub(i, i)
																					i = i + 1
																					--ConsoleMessage(tick() - t, 1/60)
																					checkwait(i)
																					if chr == "}" then break end
																					if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
																				end
																				return res, i
																			end


																			local char_func_map = {
																				[ '"' ] = parse_string,
																				[ "0" ] = parse_number,
																				[ "1" ] = parse_number,
																				[ "2" ] = parse_number,
																				[ "3" ] = parse_number,
																				[ "4" ] = parse_number,
																				[ "5" ] = parse_number,
																				[ "6" ] = parse_number,
																				[ "7" ] = parse_number,
																				[ "8" ] = parse_number,
																				[ "9" ] = parse_number,
																				[ "-" ] = parse_number,
																				[ "t" ] = parse_literal,
																				[ "f" ] = parse_literal,
																				[ "n" ] = parse_literal,
																				[ "[" ] = parse_array,
																				[ "{" ] = parse_object,
																			}


																			parse = function(str, idx)
																				local chr = str:sub(idx, idx)
																				local f = char_func_map[chr]
																				if f then
																					return f(str, idx)
																				end
																				decode_error(str, idx, "unexpected character '" .. chr .. "'")
																			end


																			function json.decode(str)
																				t = tick()
																				currentstr = str
																				lasti = nil
																				if type(str) ~= "string" then
																					error("expected argument of type string, got " .. type(str))
																				end
																				local res, idx = parse(str, next_char(str, 1, space_chars, true))
																				idx = next_char(str, idx, space_chars, true)
																				if idx <= #str then
																					decode_error(str, idx, "trailing garbage")
																				end
																				return res
																			end


																			return json
	end)()
end

-- Functions
-- General Functions


local TracerEnabled = false
local TracerLines = {}
local TRACER_STEPS = 30
local TRACER_LOOKAHEAD = 0.5 -- seconds ahead to predict

local function clearTracerLines()
    for _, line in pairs(TracerLines) do
        pcall(function() line:Remove() end)
    end
    TracerLines = {}
end

local function updateTracer()
    if not TracerEnabled then
        clearTracerLines()
        return
    end

    if not Drawing then
        ConsoleMessage("Tracer: Drawing API not supported")
        TracerEnabled = false
        return
    end

    if not RootPart then return end

    local cam = workspace.CurrentCamera
    local gravity = Vector3.new(0, -workspace.Gravity, 0)
    local dt = TRACER_LOOKAHEAD / TRACER_STEPS

    -- Make sure we have enough line objects
    while #TracerLines < TRACER_STEPS do
        local ok, line = pcall(function()
            local l = Drawing.new("Line")
            l.Thickness = 2
            l.Visible = false
            return l
        end)
        if ok then
            table.insert(TracerLines, line)
        else
            ConsoleMessage("Tracer: Drawing.new failed")
            return
        end
    end

    -- Simulate trajectory
    local pos = RootPart.Position
    local vel = RootPart.Velocity
    local points = {pos}

    local onGround = Humanoid and (
        Humanoid:GetState() == Enum.HumanoidStateType.Running or
        Humanoid:GetState() == Enum.HumanoidStateType.RunningNoPhysics
    )

    for i = 1, TRACER_STEPS do
        if onGround then
            -- On ground: just extrapolate flat velocity
            pos = pos + vel * dt
        else
            -- In air: apply gravity
            vel = vel + gravity * dt
            pos = pos + vel * dt
        end
        table.insert(points, pos)
    end

    -- Draw lines between points
    for i = 1, #points - 1 do
        local line = TracerLines[i]
        if not line then continue end

        local s1, on1 = cam:WorldToViewportPoint(points[i])
        local s2, on2 = cam:WorldToViewportPoint(points[i + 1])

        if on1 and on2 then
            line.From = Vector2.new(s1.X, s1.Y)
            line.To   = Vector2.new(s2.X, s2.Y)

            -- Color gradient: green at start -> red at end
            local t = (i - 1) / (#points - 2)
            line.Color = Color3.fromRGB(
                math.floor(50  + 205 * t),
                math.floor(255 - 205 * t),
                50
            )
            line.Visible = true
        else
            line.Visible = false
        end
    end
end

-- Hook into existing RenderStepped connections
RenderSteppedConnections.GhostAndTracer = function()
    if TracerEnabled then
        updateTracer()
    elseif #TracerLines > 0 then
        clearTracerLines()
    end
end


local StatsHudEnabled = false
local StatsHudGui = nil
 
local function createStatsHud()
    if StatsHudGui then StatsHudGui:Destroy() end
 
    -- ── Colors (match main GUI theme) ────────────────────────────
    local HUD_BG       = Color3.fromRGB(10, 10, 14)
    local HUD_INLINE   = Color3.fromRGB(21, 21, 28)
    local HUD_BORDER   = Color3.fromRGB(8, 8, 12)
    local HUD_OUTLINE  = Color3.fromRGB(30, 30, 40)
    local HUD_ACCENT   = Color3.fromRGB(100, 175, 255)
    local HUD_TEXT      = Color3.fromRGB(215, 215, 228)
    local HUD_MUTED     = Color3.fromRGB(115, 115, 138)
    local HUD_TXTSHADOW = Color3.fromRGB(0, 0, 0)
 
    local gui = Instance.new("ScreenGui")
    gui.Name = "TAS_StatsHud"
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 9998
    gui.IgnoreGuiInset = true
    gui.Parent = Player.PlayerGui
 
    -- Main frame
    local frame = Instance.new("Frame")
    frame.Name = "StatsFrame"
    frame.Size = UDim2.new(0, 290, 0, 310)
    frame.Position = UDim2.new(0, 10, 1, -320)
    frame.BackgroundColor3 = HUD_BG
    frame.BorderSizePixel = 2
    frame.BorderColor3 = HUD_BORDER
    frame.Parent = gui
 
    -- Outline stroke
    local stroke = Instance.new("UIStroke")
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.LineJoinMode = Enum.LineJoinMode.Miter
    stroke.Color = HUD_OUTLINE
    stroke.Thickness = 1
    stroke.Parent = frame
 
    -- Accent line at top
    local accentLine = Instance.new("Frame")
    accentLine.Size = UDim2.new(1, 0, 0, 2)
    accentLine.Position = UDim2.new(0, 0, 0, 0)
    accentLine.BackgroundColor3 = HUD_ACCENT
    accentLine.BorderSizePixel = 0
    accentLine.ZIndex = 3
    accentLine.Parent = frame
 
    local accentGrad = Instance.new("UIGradient")
    accentGrad.Rotation = 90
    accentGrad.Color = ColorSequence.new{
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(65, 65, 65)),
    }
    accentGrad.Parent = accentLine
 
    -- Title
    local titleLbl = Instance.new("TextLabel")
    titleLbl.Size = UDim2.new(1, 0, 0, 18)
    titleLbl.Position = UDim2.new(0, 8, 0, 4)
    titleLbl.BackgroundTransparency = 1
    titleLbl.Text = "STATS HUD"
    titleLbl.TextColor3 = HUD_ACCENT
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.TextSize = 11
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = frame
 
    local titleShadow = Instance.new("UIStroke")
    titleShadow.LineJoinMode = Enum.LineJoinMode.Miter
    titleShadow.Color = HUD_TXTSHADOW
    titleShadow.Parent = titleLbl
 
    -- Separator below title
    local sep = Instance.new("Frame")
    sep.Size = UDim2.new(1, -16, 0, 1)
    sep.Position = UDim2.new(0, 8, 0, 22)
    sep.BackgroundColor3 = HUD_OUTLINE
    sep.BorderSizePixel = 0
    sep.Parent = frame
 
    -- Content area
    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, -16, 1, -30)
    content.Position = UDim2.new(0, 8, 0, 26)
    content.BackgroundTransparency = 1
    content.BorderSizePixel = 0
    content.Parent = frame
 
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 2)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = content
 
    -- Auto-resize
    layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        frame.Size = UDim2.new(0, 290, 0, layout.AbsoluteContentSize.Y + 34)
        frame.Position = UDim2.new(0, 10, 1, -(layout.AbsoluteContentSize.Y + 44))
    end)
 
    -- ── Label factory ────────────────────────────────────────────
    local function makeHeader(text)
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, 0, 0, 16)
        lbl.BackgroundTransparency = 1
        lbl.Text = text
        lbl.TextColor3 = HUD_ACCENT
        lbl.Font = Enum.Font.GothamBold
        lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = content
        local s = Instance.new("UIStroke")
        s.LineJoinMode = Enum.LineJoinMode.Miter
        s.Color = HUD_TXTSHADOW
        s.Parent = lbl
        return lbl
    end
 
    local function makeLabel(name, defaultText)
        local lbl = Instance.new("TextLabel")
        lbl.Name = name
        lbl.Size = UDim2.new(1, 0, 0, 15)
        lbl.BackgroundTransparency = 1
        lbl.Text = defaultText
        lbl.RichText = true
        lbl.TextColor3 = HUD_TEXT
        lbl.Font = Enum.Font.GothamMedium
        lbl.TextSize = 12
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Parent = content
        local s = Instance.new("UIStroke")
        s.LineJoinMode = Enum.LineJoinMode.Miter
        s.Color = HUD_TXTSHADOW
        s.Parent = lbl
        return lbl
    end
 
    local function makeDivider()
        local div = Instance.new("Frame")
        div.Size = UDim2.new(1, 0, 0, 1)
        div.BackgroundColor3 = HUD_OUTLINE
        div.BackgroundTransparency = 0.5
        div.BorderSizePixel = 0
        div.Parent = content
    end
 
    -- ── Build labels ─────────────────────────────────────────────
    makeHeader("POSITION")
    local posX   = makeLabel("PosX",   "X: 0.000")
    local posY   = makeLabel("PosY",   "Y: 0.000")
    local posZ   = makeLabel("PosZ",   "Z: 0.000")
    makeDivider()
    makeHeader("VELOCITY")
    local velX   = makeLabel("VelX",   "X: 0.000")
    local velY   = makeLabel("VelY",   "Y: 0.000")
    local velZ   = makeLabel("VelZ",   "Z: 0.000")
    local velMag = makeLabel("VelMag", "Magnitude: 0.000")
    makeDivider()
    makeHeader("ROTATION")
    local rotX   = makeLabel("RotX",   "Pitch: 0.00°")
    local rotY   = makeLabel("RotY",   "Yaw:   0.00°")
    local rotZ   = makeLabel("RotZ",   "Roll:  0.00°")
    makeDivider()
    makeHeader("CHARACTER")
    local stateLabel = makeLabel("State", "State: None")
    local floorLabel = makeLabel("Floor", "Floor: None")
    local jumpLabel  = makeLabel("Jump",  "JumpPower: 50")
    local wsLabel    = makeLabel("WS",    "WalkSpeed: 16")
    local gravLabel  = makeLabel("Grav",  "Gravity: 196.2")
    makeDivider()
    makeHeader("REPLAY")
    local frameLabel = makeLabel("Frame", "Frame: 0 / 0")
    local timeLabel  = makeLabel("Time",  "Time:  0.00s")
    local zoomLabel  = makeLabel("Zoom",  "Zoom:  0.00")
    makeDivider()
    makeHeader("CSYNC")
    local coPartLabel  = makeLabel("COParts", "Tracked: 0")
    local coFrameLabel = makeLabel("COState", "CO State: idle")
 
    -- ── Update loop ──────────────────────────────────────────────
    local updateConn = RunService.RenderStepped:Connect(function()
        if not StatsHudEnabled or not StatsHudGui then return end
        if not RootPart or not Humanoid then return end
 
        local pos = RootPart.Position
        posX.Text = string.format("X: <font color='#ff8080'>%.4f</font>", pos.X)
        posY.Text = string.format("Y: <font color='#80ff80'>%.4f</font>", pos.Y)
        posZ.Text = string.format("Z: <font color='#8080ff'>%.4f</font>", pos.Z)
 
        local vel = RootPart.Velocity
        velX.Text   = string.format("X: <font color='#ff8080'>%.4f</font>", vel.X)
        velY.Text   = string.format("Y: <font color='#80ff80'>%.4f</font>", vel.Y)
        velZ.Text   = string.format("Z: <font color='#8080ff'>%.4f</font>", vel.Z)
        velMag.Text = string.format("Magnitude: <font color='#ffdc50'>%.4f</font>", vel.Magnitude)
 
        local rx, ry, rz = RootPart.CFrame:ToOrientation()
        rotX.Text = string.format("Pitch: <font color='#ff8080'>%.2f°</font>", math.deg(rx))
        rotY.Text = string.format("Yaw:   <font color='#80ff80'>%.2f°</font>", math.deg(ry))
        rotZ.Text = string.format("Roll:  <font color='#8080ff'>%.2f°</font>", math.deg(rz))
 
        local stateStr = tostring(Humanoid:GetState()):gsub("Enum.HumanoidStateType.", "")
        local sc = "#ffffff"
        if stateStr == "Jumping" or stateStr == "Freefall" then sc = "#80ff80"
        elseif stateStr == "Running" then sc = "#ffdc50"
        elseif stateStr == "Climbing" then sc = "#ff9650"
        elseif stateStr == "Dead" then sc = "#ff5050" end
        stateLabel.Text = string.format("State: <font color='%s'>%s</font>", sc, stateStr)
 
        local floorMat = tostring(Humanoid.FloorMaterial):gsub("Enum.Material.", "")
        floorLabel.Text = string.format("Floor: <font color='#aaaaff'>%s</font>", floorMat)
        jumpLabel.Text  = string.format("JumpPower: <font color='#c8c8ff'>%.1f</font>", Humanoid.JumpPower)
        wsLabel.Text    = string.format("WalkSpeed: <font color='#c8c8ff'>%.1f</font>", Humanoid.WalkSpeed)
        gravLabel.Text  = string.format("Gravity: <font color='#c8c8ff'>%.2f</font>", workspace.Gravity)
 
        local totalFrames = #ReplayTable
        local cf = Frozen and RoundNumber(FreezeFrame, 0) or (Reading and ReplayTableIndex or 0)
        frameLabel.Text = string.format("Frame: <font color='#64afff'>%d / %d</font>", cf, totalFrames)
        timeLabel.Text  = string.format("Time:  <font color='#64afff'>%.2fs</font>", cf / math.max(FPS, 1))
 
        local zoom = GetZoom()
        zoomLabel.Text = string.format("Zoom:  <font color='#64afff'>%.2f</font>", zoom)
 
        -- CSync info
        local partCount = CO.GetPartCount and CO.GetPartCount() or 0
        coPartLabel.Text = string.format("Tracked: <font color='#64afff'>%d</font> parts", partCount)
        local coStatus = "idle"
        if Writing then coStatus = "recording"
        elseif Reading then coStatus = "playing"
        elseif Frozen then coStatus = "frozen" end
        coFrameLabel.Text = string.format("CO State: <font color='#64afff'>%s</font>", coStatus)
    end)
 
    getgenv().StatsHudConnection = updateConn
    StatsHudGui = gui
    ConsoleMessage("Stats HUD enabled")
end
 
local function destroyStatsHud()
    if getgenv().StatsHudConnection then
        getgenv().StatsHudConnection:Disconnect()
        getgenv().StatsHudConnection = nil
    end
    if StatsHudGui then
        StatsHudGui:Destroy()
        StatsHudGui = nil
    end
    ConsoleMessage("Stats HUD disabled")
end


-- Fast conversion functions for better performance
local function FastTableToCFrame(t)
	return CFrame.new(t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11], t[12])
end

local function FastTableToVector3(t)
	return Vector3.new(t[1], t[2], t[3])
end

local function FastTableToVector2(t)
	return Vector2.new(t[1], t[2])
end
local RandomString --RandomString() -> string
local RoundNumber -- RoundNumber(Number,Digits) -> number
local Vector3ToTable -- Vector3ToTable(Vector3) -> table
local TableToVector3 -- TableToVector3(Table) -> vector3
local CFrameToTable -- CFrameToTable(CFrame) -> table
local TableToCFrame -- TableToCFrame(Table) -> cframe
local RoundVector3 -- RoundVector3(Vector3,Digits) -> vector3
local RoundCFrame -- RoundCFrame(CFrame,Digits) -> cframe
local FindListIndex -- FindListIndex(Table,Search) -> number
local WaitForInput -- WaitForInput() -> nil
do
	RandomString = function()
		local str = ""
		for _ = 1,random(1,20) do
			local type = random(1,3)
			if type == 1 then
				str = str..string.char(random(97,122)) -- Lowercase
			elseif type == 2 then
				str = str..string.char(random(65,90)) -- Uppercase
			elseif type == 3 then
				str = str..string.char(random(48,57)) -- Numbers
			end
		end
		return str
	end
	RoundNumber = function(Number,Digits)
		local Mult = 10^max(tonumber(Digits) or 0,0)
		return floor(Number*Mult+0.5)/Mult
	end
	Vector3ToTable = function(V3)
		return {V3.X,V3.Y,V3.Z}
	end
	TableToVector3 = function(Table)
		return Vector3.new(unpack(Table))
	end
	Vector2ToTable = function(V2)
		return {V2.X,V2.Y}
	end
	TableToVector2 = function(Table)
		return Vector2.new(unpack(Table))
	end
	CFrameToTable = function(CF)
		return {CF:GetComponents()}
	end
	TableToCFrame = function(Table)
		return CFrame.new(unpack(Table))
	end
	RoundTable = function(Table,Digits)
		local RoundedTable = {}
		for Index,Number in pairs(Table) do
			RoundedTable[Index] = RoundNumber(Number,Digits)
		end
		return RoundedTable
	end
	FindListIndex = function(Table,Search)
		for Index,Value in pairs(Table) do
			if Value == Search then
				return Index
			end
		end
	end
	WaitForInput = function()
		local KeyPressed = Instance.new("BindableEvent")
		local InputBeganConnection
		InputBeganConnection = UserInputService.InputBegan:Connect(function(Input)
			if Input.UserInputType == Enum.UserInputType.Keyboard then
				RunService.RenderStepped:Wait()
				KeyPressed:Fire()
			end
		end)
		KeyPressed.Event:Wait()
		InputBeganConnection:Disconnect()
		KeyPressed:Destroy()
	end
end

local function ReleaseAllPlaybackKeys()
    for Input, Code in pairs(PlaybackPressedKeys) do
        if Code == "b1" then
            mouse1release()
        elseif Code == "b2" then
            mouse2release()
        elseif type(Code) == "number" then
            keyrelease(Code)
        end
    end
    PlaybackPressedKeys = {}
end

-- An executor without the absolute-move primitive (or one that throws for a frame) must not
-- take a playback or freeze loop down over a cosmetic cursor placement.
local function MoveMouseAbs(X, Y)
    if type(mousemoveabs) ~= "function" then return end
    pcall(mousemoveabs, X, Y)
end

local CO = {}
do
    local CO_EPSILON        = 0.001
    local CO_ATTRIBUTE_NAME = "TAS_ObjectId"

    local objectRegistry    = {}
    local idByObject        = {}
    local lastCFrames       = {}
    local pendingFirstRecord = {} -- id -> initial CFrame, force-included in next RecordFrame
    local nextId            = 1
    local scanComplete      = false
    local watchConn         = nil
    local recordingPhase    = false

    -- Interpolation state (for smooth playback)
    local prevCO        = {}    -- idStr -> CFrame at start of current interp window
    local targetCO      = {}    -- idStr -> CFrame at end of current interp window
    local interpStart   = 0
    local interpDuration = 1/60

    -- What each tracked part's Anchored flag was before playback or a still took it; restored
    -- on the way out so a part the game itself anchored is not unanchored by the tool.
    local anchorStates = {}

    -- A still redraws one frame many times; the custom-object state at frame N only grows, so
    -- the prefix is cached and extended forward. A different tape, a shrink, or a backward
    -- seek rebuilds it from the top.
    local stateCache     = {}
    local stateCacheUpTo = 0
    local stateCacheTape = nil

    local function isBlacklisted(part)
        if Character and part:IsDescendantOf(Character) then return true end
        for _, plr in ipairs(game.Players:GetPlayers()) do
            if plr.Character and part:IsDescendantOf(plr.Character) then return true end
        end
        return false
    end

    local function findNextFreeId()
        while objectRegistry[nextId] do
            nextId = nextId + 1
        end
        local id = nextId
        nextId = nextId + 1
        return id
    end

    -- keys are stable for the session and every recorded frame needs them, so the string
    -- form is made once per id instead of twice per part per frame
    local idStrings = {}
    local function keyFor(id)
        local key = idStrings[id]
        if not key then
            key = tostring(id)
            idStrings[id] = key
        end
        return key
    end

    local function registerPart(part)
        if idByObject[part] then return end
        if not part:IsA("BasePart") then return end
        if isBlacklisted(part) then return end

        local existingId = part:GetAttribute(CO_ATTRIBUTE_NAME)
        local id
        if existingId and type(existingId) == "number" and not objectRegistry[existingId] then
            id = existingId
            -- CRITICAL: bump nextId past existing IDs to prevent later collisions
            if id >= nextId then nextId = id + 1 end
        else
            id = findNextFreeId()
        end

        part:SetAttribute(CO_ATTRIBUTE_NAME, id)
        objectRegistry[id] = part
        idByObject[part]   = id

        if recordingPhase then
            -- Queue this part's starting CFrame for the next RecordFrame so the
            -- replay always knows where every tracked part started, even if it
            -- never moves during the recording.
            pendingFirstRecord[id] = part.CFrame
        else
            -- Reading-time registration: just baseline so we don't break later sessions.
            lastCFrames[id] = part.CFrame
        end
    end

    local function scanWorkspace()
        for _, desc in ipairs(workspace:GetDescendants()) do
            if desc:IsA("BasePart") and not desc.Anchored and not isBlacklisted(desc) then
                registerPart(desc)
            end
        end
        scanComplete = true
        ConsoleMessage("[CO] Scanned " .. tostring(nextId - 1) .. " moving parts")
    end

    local function startWatching()
        if watchConn then watchConn:Disconnect() end
        watchConn = workspace.DescendantAdded:Connect(function(desc)
            if desc:IsA("BasePart") and not desc.Anchored and not isBlacklisted(desc) then
                registerPart(desc)
            end
        end)
    end

    function CO.Init()
        anchorStates        = {}
        stateCache          = {}
        stateCacheUpTo      = 0
        stateCacheTape      = nil
        recordingPhase      = true
        -- A resume from a still, or a stop and restart, does not have to walk the world again:
        -- the registry and the watcher are still live. Re-baseline what is tracked so the first
        -- new frame carries every part's current pose, keep ids stable, and let the watcher pick
        -- up additions. The full scan is only for a session whose watcher was torn down.
        if scanComplete and watchConn then
            pendingFirstRecord = {}
            for id, part in pairs(objectRegistry) do
                if part and part.Parent and not isBlacklisted(part) then
                    pendingFirstRecord[id] = part.CFrame
                    lastCFrames[id]        = part.CFrame
                else
                    objectRegistry[id] = nil
                    if part then idByObject[part] = nil end
                    lastCFrames[id] = nil
                end
            end
            return
        end
        objectRegistry      = {}
        idByObject          = {}
        lastCFrames         = {}
        pendingFirstRecord  = {}
        nextId              = 1
        scanComplete        = false
        scanWorkspace()
        startWatching()
        RunService.Heartbeat:Wait()
        ConsoleMessage("[CO] Init done, recording world objects")
    end

    function CO.RecordFrame()
        if not scanComplete then return {} end
        local delta = {}

        -- Force-include any newly registered parts' starting CFrame.
        for id, cf in pairs(pendingFirstRecord) do
            local part = objectRegistry[id]
            if part and part.Parent then
                delta[keyFor(id)] = RoundTable({cf:GetComponents()}, RoundDigits)
                lastCFrames[id]     = cf
            end
        end
        pendingFirstRecord = {}

        -- Standard movement delta
        for id, part in pairs(objectRegistry) do
            if part and part.Parent then
                local key = keyFor(id)
                if not delta[key] then
                    local cf   = part.CFrame
                    local prev = lastCFrames[id]
                    local moved = false
                    if prev then
                        local rel = prev:ToObjectSpace(cf)
                        local pos = rel.Position
                        if math.abs(pos.X) > CO_EPSILON
                        or math.abs(pos.Y) > CO_EPSILON
                        or math.abs(pos.Z) > CO_EPSILON
                        or math.abs(rel.XVector.X - 1) > CO_EPSILON
                        then
                            moved = true
                        end
                    else
                        moved = true
                    end
                    if moved then
                        delta[key] = RoundTable({cf:GetComponents()}, RoundDigits)
                        lastCFrames[id]     = cf
                    end
                end
            end
        end
        return delta
    end

    -- Direct apply (snap) - used when interpolation is OFF
    local coDataWarned = false
    function CO.ApplyFrame(delta)
        if not delta then
            if not coDataWarned then
                coDataWarned = true
                ConsoleMessage("[CO] WARNING: No CO data in replay. Re-record to enable spinner sync.")
            end
            return
        end
        coDataWarned = false
        for idStr, components in pairs(delta) do
            local id   = tonumber(idStr)
            local part = objectRegistry[id]
            if part and part.Parent then
                part.CFrame = FastTableToCFrame(components)
            end
        end
    end

    -- Interpolated apply: stash prev/target, RenderStepped lerps between them.
    function CO.SetInterpolationTargets(delta, duration)
        if not delta then return end
        interpStart    = tick()
        interpDuration = math.max(duration or (1/60), 0.001)
        for idStr, components in pairs(delta) do
            local id   = tonumber(idStr)
            local part = objectRegistry[id]
            if part and part.Parent then
                prevCO[idStr]   = part.CFrame
                targetCO[idStr] = FastTableToCFrame(components)
            end
        end
    end

    function CO.UpdateInterpolation()
        if not next(targetCO) then return end
        local elapsed = tick() - interpStart
        local alpha   = math.clamp(elapsed / interpDuration, 0, 1)
        -- The window closes: once the part sits on its target, repeating that write every step
        -- for the rest of the run is pure cost, so the entry is dropped. A part that moves
        -- again is re-armed by the next frame's delta.
        local Settled = alpha >= 1
        for idStr, target in pairs(targetCO) do
            local prev = prevCO[idStr]
            if prev then
                local id   = tonumber(idStr)
                local part = objectRegistry[id]
                if part and part.Parent then
                    part.CFrame = prev:Lerp(target, alpha)
                end
            end
            if Settled then
                targetCO[idStr] = nil
                prevCO[idStr]   = nil
            end
        end
    end

    function CO.ClearInterpolation()
        prevCO   = {}
        targetCO = {}
    end

    function CO.AnchorAll()
        for id, part in pairs(objectRegistry) do
            if part and part.Parent then
                if anchorStates[id] == nil then
                    anchorStates[id] = part.Anchored
                end
                part.Anchored = true
            end
        end
        ConsoleMessage("[CO] All tracked parts anchored")
    end

    function CO.RestoreAnchors()
        for id, part in pairs(objectRegistry) do
            if part and part.Parent then
                part.Anchored = anchorStates[id] or false
            end
        end
        anchorStates = {}
        ConsoleMessage("[CO] All tracked parts restored")
    end

    function CO.RebuildFromAttributes()
        objectRegistry      = {}
        idByObject          = {}
        lastCFrames         = {}
        pendingFirstRecord  = {}
        anchorStates        = {}
        stateCache          = {}
        stateCacheUpTo      = 0
        stateCacheTape      = nil
        recordingPhase      = false
        local highest       = 0
        for _, desc in ipairs(workspace:GetDescendants()) do
            if desc:IsA("BasePart") and not isBlacklisted(desc) then
                local id = desc:GetAttribute(CO_ATTRIBUTE_NAME)
                if id and type(id) == "number" then
                    if objectRegistry[id] then
                        -- Duplicate ID: clear the offender's attribute, do NOT
                        -- double-register (this was a major source of the
                        -- "wrong object teleports" bug).
                        ConsoleMessage("[CO] WARN: duplicate ID " .. tostring(id) .. " on " .. desc.Name .. " - clearing")
                        desc:SetAttribute(CO_ATTRIBUTE_NAME, nil)
                    else
                        objectRegistry[id] = desc
                        idByObject[desc]   = id
                        lastCFrames[id]    = desc.CFrame
                        if id >= highest then highest = id + 1 end
                    end
                end
            end
        end
        nextId       = highest
        scanComplete = true
        startWatching()
        ConsoleMessage("[CO] Rebuilt registry: " .. tostring(highest - 1) .. " parts")
    end

    function CO.GetFullStateAtFrame(frameIndex, replayTable)
        if replayTable ~= stateCacheTape or frameIndex < stateCacheUpTo then
            stateCache     = {}
            stateCacheUpTo = 0
            stateCacheTape = replayTable
        end
        for i = stateCacheUpTo + 1, frameIndex do
            local frame = replayTable[i]
            if type(frame) == "table" and frame[13] then
                for idStr, components in pairs(frame[13]) do
                    stateCache[idStr] = components
                end
            end
        end
        if frameIndex > stateCacheUpTo then
            stateCacheUpTo = frameIndex
        end
        return stateCache
    end

    function CO.ApplyFullState(state)
        for idStr, components in pairs(state) do
            local id   = tonumber(idStr)
            local part = objectRegistry[id]
            if part and part.Parent then
                part.CFrame = FastTableToCFrame(components)
            end
        end
    end

    function CO.GetPartCount()
        local count = 0
        for _ in pairs(objectRegistry) do count = count + 1 end
        return count
    end

    function CO.Stop()
        if watchConn then
            watchConn:Disconnect()
            watchConn = nil
        end
        prevCO         = {}
        targetCO       = {}
        anchorStates   = {}
        stateCache     = {}
        stateCacheUpTo = 0
        stateCacheTape = nil
        scanComplete   = false
        recordingPhase = false
    end
end

do 
    
-- ── Services ─────────────────────────────────────────────────────────────────
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

-- ── Font ─────────────────────────────────────────────────────────────────────
local UIFont = Font.fromEnum(Enum.Font.Code)
local UIFontBold = Font.fromEnum(Enum.Font.GothamBold)
pcall(function()
    UIFont = Font.fromEnum(Enum.Font.GothamMedium)
    UIFontBold = Font.fromEnum(Enum.Font.GothamBold)
end)

-- ── Utilities ────────────────────────────────────────────────────────────────
local function tw(obj, props, dur, style)
    local t = TweenService:Create(
        obj,
        TweenInfo.new(dur or 0.12, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        props
    )
    t:Play()
    return t
end

local function mk(cls, props)
    local inst = Instance.new(cls)
    for k, v in pairs(props) do inst[k] = v end
    return inst
end

-- ══════════════════════════════════════════════════════════════════════════════
--  THEME SYSTEM
-- ══════════════════════════════════════════════════════════════════════════════

local ThemeBindings = {} -- {inst, property, themeKey}

local Theme = {
    bg_deep     = Color3.fromRGB(10, 10, 14),
    bg_window   = Color3.fromRGB(15, 15, 21),
    bg_inline   = Color3.fromRGB(21, 21, 28),
    bg_panel    = Color3.fromRGB(28, 28, 35),
    bg_element  = Color3.fromRGB(35, 35, 42),
    bg_hover    = Color3.fromRGB(44, 44, 54),

    accent      = Color3.fromRGB(100, 175, 255),
    accent_dim  = Color3.fromRGB(30, 60, 100),
    accent_glow = Color3.fromRGB(75, 145, 225),

    border      = Color3.fromRGB(8, 8, 12),
    outline     = Color3.fromRGB(30, 30, 40),

    txt         = Color3.fromRGB(215, 215, 228),
    txt_muted   = Color3.fromRGB(115, 115, 138),
    txt_dim     = Color3.fromRGB(55, 55, 70),
    txt_shadow  = Color3.fromRGB(0, 0, 0),

    red    = Color3.fromRGB(220, 60, 60),
    green  = Color3.fromRGB(60, 220, 100),
    cyan   = Color3.fromRGB(60, 200, 220),
    yellow = Color3.fromRGB(220, 200, 60),
}

local ThemePresets = {
    ["Midnight Blue"] = {
        accent=Color3.fromRGB(100,175,255), accent_dim=Color3.fromRGB(30,60,100), accent_glow=Color3.fromRGB(75,145,225),
        bg_deep=Color3.fromRGB(10,10,14), bg_window=Color3.fromRGB(15,15,21),
        bg_inline=Color3.fromRGB(21,21,28), bg_panel=Color3.fromRGB(28,28,35), bg_element=Color3.fromRGB(35,35,42),
        border=Color3.fromRGB(8,8,12), outline=Color3.fromRGB(30,30,40),
    },
    ["Neon Green"] = {
        accent=Color3.fromRGB(80,255,120), accent_dim=Color3.fromRGB(25,80,40), accent_glow=Color3.fromRGB(60,200,90),
        bg_deep=Color3.fromRGB(8,10,8), bg_window=Color3.fromRGB(12,16,12),
        bg_inline=Color3.fromRGB(18,22,18), bg_panel=Color3.fromRGB(24,30,24), bg_element=Color3.fromRGB(30,38,30),
        border=Color3.fromRGB(6,10,6), outline=Color3.fromRGB(28,42,28),
    },
    ["Blood Red"] = {
        accent=Color3.fromRGB(255,50,50), accent_dim=Color3.fromRGB(85,20,20), accent_glow=Color3.fromRGB(200,45,45),
        bg_deep=Color3.fromRGB(12,8,8), bg_window=Color3.fromRGB(18,12,12),
        bg_inline=Color3.fromRGB(26,16,16), bg_panel=Color3.fromRGB(34,20,20), bg_element=Color3.fromRGB(42,26,26),
        border=Color3.fromRGB(10,6,6), outline=Color3.fromRGB(45,25,25),
    },
    ["Purple Haze"] = {
        accent=Color3.fromRGB(180,100,255), accent_dim=Color3.fromRGB(55,28,90), accent_glow=Color3.fromRGB(145,75,215),
        bg_deep=Color3.fromRGB(11,9,16), bg_window=Color3.fromRGB(17,13,24),
        bg_inline=Color3.fromRGB(24,18,34), bg_panel=Color3.fromRGB(32,24,44), bg_element=Color3.fromRGB(40,30,54),
        border=Color3.fromRGB(9,7,14), outline=Color3.fromRGB(38,28,55),
    },
    ["Teal"] = {
        accent=Color3.fromRGB(0,210,180), accent_dim=Color3.fromRGB(0,65,55), accent_glow=Color3.fromRGB(0,170,140),
        bg_deep=Color3.fromRGB(7,11,11), bg_window=Color3.fromRGB(11,17,17),
        bg_inline=Color3.fromRGB(17,24,24), bg_panel=Color3.fromRGB(22,32,32), bg_element=Color3.fromRGB(28,40,40),
        border=Color3.fromRGB(5,9,9), outline=Color3.fromRGB(24,42,40),
    },
    ["Gold"] = {
        accent=Color3.fromRGB(255,200,60), accent_dim=Color3.fromRGB(90,70,18), accent_glow=Color3.fromRGB(215,165,45),
        bg_deep=Color3.fromRGB(13,11,7), bg_window=Color3.fromRGB(19,17,11),
        bg_inline=Color3.fromRGB(27,23,15), bg_panel=Color3.fromRGB(35,29,19), bg_element=Color3.fromRGB(43,35,23),
        border=Color3.fromRGB(10,8,5), outline=Color3.fromRGB(48,38,20),
    },
    ["Monochrome"] = {
        accent=Color3.fromRGB(200,200,200), accent_dim=Color3.fromRGB(55,55,55), accent_glow=Color3.fromRGB(160,160,160),
        bg_deep=Color3.fromRGB(9,9,9), bg_window=Color3.fromRGB(15,15,15),
        bg_inline=Color3.fromRGB(22,22,22), bg_panel=Color3.fromRGB(30,30,30), bg_element=Color3.fromRGB(38,38,38),
        border=Color3.fromRGB(6,6,6), outline=Color3.fromRGB(35,35,35),
    },
}

local function applyTheme(inst, prop, key)
    inst[prop] = Theme[key]
    table.insert(ThemeBindings, {inst, prop, key})
end

local function refreshAllTheme()
    for _, b in ipairs(ThemeBindings) do
        if b[1] and b[1].Parent then
            pcall(function() b[1][b[2]] = Theme[b[3]] end)
        end
    end
end

local function setThemePreset(name)
    local p = ThemePresets[name]
    if not p then return end
    for k, v in pairs(p) do Theme[k] = v end
    refreshAllTheme()
end

-- ── Instance helpers ─────────────────────────────────────────────────────────

local function addLayeredBorder(parent)
    parent.BorderSizePixel = 2
    parent.BorderColor3 = Theme.border
    applyTheme(parent, "BorderColor3", "border")
    local s = mk("UIStroke", {
        Parent = parent,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        LineJoinMode = Enum.LineJoinMode.Miter,
        Color = Theme.outline,
        Thickness = 1,
    })
    applyTheme(s, "Color", "outline")
    return s
end

local function addStroke(parent, themeKey, thickness, transparency)
    local s = mk("UIStroke", {
        Parent = parent,
        Color = Theme[themeKey or "outline"],
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        LineJoinMode = Enum.LineJoinMode.Miter,
    })
    applyTheme(s, "Color", themeKey or "outline")
    return s
end

local function addTextShadow(parent)
    return mk("UIStroke", {
        Parent = parent,
        LineJoinMode = Enum.LineJoinMode.Miter,
        Color = Theme.txt_shadow,
        Thickness = 1,
    })
end

local function addAccentLine(parent, pos, size)
    local line = mk("Frame", {
        Parent = parent,
        Position = pos or UDim2.new(0, 0, 0, 0),
        Size = size or UDim2.new(1, 0, 0, 2),
        BackgroundColor3 = Theme.accent,
        BorderSizePixel = 0,
        ZIndex = 3,
    })
    applyTheme(line, "BackgroundColor3", "accent")
    mk("UIGradient", {
        Parent = line,
        Rotation = 90,
        Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(65, 65, 65)),
        },
    })
    return line
end

local function addVertGradient(parent)
    return mk("UIGradient", {
        Parent = parent,
        Rotation = 90,
        Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 100, 100)),
        },
    })
end

-- ══════════════════════════════════════════════════════════════════════════════
--  ROOT GUI + BACKGROUND BLUR
-- ══════════════════════════════════════════════════════════════════════════════

-- ── Forward declarations (referenced by title-bar closures BEFORE definition) ──
local PlayerWindow, FileWindow
local buildPlayerWindow, buildFileWindow

local RootGui = mk("ScreenGui", {
    Name = "TasabilityGUI",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 9990,
    IgnoreGuiInset = true,
    Parent = game:GetService("CoreGui"),
})

-- Background blur (added to Lighting; toggled with window visibility)
local TasBlur = mk("BlurEffect", {
    Name = "TasabilityBlur",
    Size = 0,
    Parent = Lighting,
})

-- ══════════════════════════════════════════════════════════════════════════════
--  MAIN WINDOW (top-tab atlanta-style layout)
-- ══════════════════════════════════════════════════════════════════════════════

local WIN_W, WIN_H = 760, 540
local MainFrame = mk("Frame", {
    Name = "MainFrame",
    Size = UDim2.fromOffset(WIN_W, WIN_H),
    Position = UDim2.new(0.5, -WIN_W/2, 0.5, -WIN_H/2),
    BackgroundColor3 = Theme.bg_window,
    BorderSizePixel = 0,
    Parent = RootGui,
})
applyTheme(MainFrame, "BackgroundColor3", "bg_window")

-- Outer accent stroke
local accentBorder = mk("UIStroke", {
    Parent = MainFrame,
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    LineJoinMode = Enum.LineJoinMode.Miter,
    Color = Theme.accent,
    Thickness = 1,
})
applyTheme(accentBorder, "Color", "accent")

-- Top accent line
addAccentLine(MainFrame, UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0, 2))

-- ── Title bar ────────────────────────────────────────────────────────────────
local TitleBar = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 30),
    Position = UDim2.fromOffset(0, 2),
    BackgroundColor3 = Theme.bg_deep,
    BorderSizePixel = 0,
    Parent = MainFrame,
})
applyTheme(TitleBar, "BackgroundColor3", "bg_deep")

mk("Frame", { -- bottom hairline
    Size = UDim2.new(1, 0, 0, 1),
    Position = UDim2.new(0, 0, 1, -1),
    BackgroundColor3 = Theme.outline,
    BorderSizePixel = 0,
    Parent = TitleBar,
})

-- Drag
do
    local dragging, dragStart, frameStart
    TitleBar.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true; dragStart = inp.Position; frameStart = MainFrame.Position
        end
    end)
    TitleBar.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    UserInputService.InputChanged:Connect(function(inp)
        if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
            local d = inp.Position - dragStart
            MainFrame.Position = UDim2.new(
                frameStart.X.Scale, frameStart.X.Offset + d.X,
                frameStart.Y.Scale, frameStart.Y.Offset + d.Y)
        end
    end)
end

-- Title (no logo per request)
local TitleLabel = mk("TextLabel", {
    Size = UDim2.new(0, 110, 1, 0),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "TASABILITY",
    TextColor3 = Theme.accent,
    FontFace = UIFontBold,
    TextSize = 13,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TitleBar,
})
applyTheme(TitleLabel, "TextColor3", "accent")
addTextShadow(TitleLabel)

local VersionBadge = mk("Frame", {
    Size = UDim2.fromOffset(48, 16),
    Position = UDim2.fromOffset(98, 7),
    BackgroundColor3 = Theme.bg_panel,
    BorderSizePixel = 2,
    BorderColor3 = Theme.border,
    Parent = TitleBar,
})
applyTheme(VersionBadge, "BackgroundColor3", "bg_panel")
applyTheme(VersionBadge, "BorderColor3", "border")
addStroke(VersionBadge, "outline", 1)
mk("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = Version,
    TextColor3 = Theme.txt_muted,
    FontFace = UIFont,
    TextSize = 10,
    Parent = VersionBadge,
})

-- ── Title-bar window-toggle buttons (PLAYERS / FILES) ────────────────────────
local function makeTitleBarToggle(text, posX, width, onClick)
    local b = mk("TextButton", {
        Size = UDim2.fromOffset(width, 18),
        Position = UDim2.fromOffset(posX, 6),
        BackgroundColor3 = Theme.bg_element,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        Text = "", AutoButtonColor = false, Parent = TitleBar,
    })
    applyTheme(b, "BackgroundColor3", "bg_element")
    applyTheme(b, "BorderColor3", "border")
    addStroke(b, "outline", 1)
    addVertGradient(b)
    local t = mk("TextLabel", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Text = text, TextColor3 = Theme.txt_muted,
        FontFace = UIFontBold, TextSize = 10, Parent = b,
    })
    addTextShadow(t)
    b.MouseEnter:Connect(function()
        tw(b, {BackgroundColor3 = Theme.bg_hover})
        tw(t, {TextColor3 = Theme.accent})
    end)
    b.MouseLeave:Connect(function()
        tw(b, {BackgroundColor3 = Theme.bg_element})
        tw(t, {TextColor3 = Theme.txt_muted})
    end)
    b.MouseButton1Click:Connect(onClick)
    return b
end

-- Players toggle (lazy-build window on first open)
makeTitleBarToggle("PLAYERS", 156, 60, function()
    if not PlayerWindow then buildPlayerWindow() end
    PlayerWindow:Toggle()
end)
-- Files toggle (lazy-build window on first open)
makeTitleBarToggle("FILES", 220, 50, function()
    if not FileWindow then buildFileWindow() end
    FileWindow:Toggle()
end)

-- ── Search bar (in title bar) ────────────────────────────────────────────────
local SearchableElements = {} -- {instance, label, sectionWrap}

local SearchBox = mk("Frame", {
    Size = UDim2.fromOffset(180, 18),
    Position = UDim2.new(1, -332, 0, 6),
    BackgroundColor3 = Theme.bg_element,
    BorderSizePixel = 2,
    BorderColor3 = Theme.border,
    Parent = TitleBar,
})
applyTheme(SearchBox, "BackgroundColor3", "bg_element")
applyTheme(SearchBox, "BorderColor3", "border")
local searchStroke = addStroke(SearchBox, "outline", 1)

local SearchInput = mk("TextBox", {
    Size = UDim2.new(1, -10, 1, 0),
    Position = UDim2.fromOffset(6, 0),
    BackgroundTransparency = 1,
    Text = "",
    PlaceholderText = "search...",
    PlaceholderColor3 = Theme.txt_dim,
    TextColor3 = Theme.txt,
    FontFace = UIFont,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    ClearTextOnFocus = false,
    Parent = SearchBox,
})

SearchInput.Focused:Connect(function()
    tw(searchStroke, {Color = Theme.accent, Transparency = 0.3})
end)
SearchInput.FocusLost:Connect(function()
    tw(searchStroke, {Color = Theme.outline, Transparency = 0})
end)

local function applySearch(query)
    query = query and query:lower() or ""
    local sectionsHasMatch = {}
    for _, entry in ipairs(SearchableElements) do
        local match = (query == "") or (entry.label:lower():find(query, 1, true) ~= nil)
        entry.instance.Visible = match
        if match and entry.sectionWrap then
            sectionsHasMatch[entry.sectionWrap] = true
        end
    end
    if query ~= "" then
        for _, entry in ipairs(SearchableElements) do
            if entry.sectionWrap then
                entry.sectionWrap.Visible = sectionsHasMatch[entry.sectionWrap] or false
            end
        end
    else
        for _, entry in ipairs(SearchableElements) do
            if entry.sectionWrap then entry.sectionWrap.Visible = true end
        end
    end
end

SearchInput:GetPropertyChangedSignal("Text"):Connect(function()
    applySearch(SearchInput.Text)
end)

-- ── Status pill ──────────────────────────────────────────────────────────────
local StatusPill = mk("Frame", {
    Size = UDim2.fromOffset(110, 16),
    Position = UDim2.new(1, -148, 0, 7),
    BackgroundColor3 = Theme.bg_panel,
    BorderSizePixel = 2,
    BorderColor3 = Theme.border,
    Parent = TitleBar,
})
applyTheme(StatusPill, "BackgroundColor3", "bg_panel")
applyTheme(StatusPill, "BorderColor3", "border")
addStroke(StatusPill, "outline", 1)

local StatusDot = mk("Frame", {
    Size = UDim2.fromOffset(6, 6),
    Position = UDim2.fromOffset(5, 5),
    BackgroundColor3 = Theme.txt_muted,
    BorderSizePixel = 0,
    Parent = StatusPill,
})
local StatusText = mk("TextLabel", {
    Size = UDim2.new(1, -16, 1, 0),
    Position = UDim2.fromOffset(14, 0),
    BackgroundTransparency = 1,
    Text = "Idle",
    TextColor3 = Theme.txt,
    FontFace = UIFont,
    TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = StatusPill,
})

-- ── Hide button ──────────────────────────────────────────────────────────────
local HideBtn = mk("TextButton", {
    Size = UDim2.fromOffset(24, 16),
    Position = UDim2.new(1, -32, 0.5, -8),
    BackgroundColor3 = Theme.bg_element,
    BorderSizePixel = 2,
    BorderColor3 = Theme.border,
    Text = "—",
    TextColor3 = Theme.txt_muted,
    FontFace = UIFontBold,
    TextSize = 11,
    AutoButtonColor = false,
    Parent = TitleBar,
})
applyTheme(HideBtn, "BackgroundColor3", "bg_element")
applyTheme(HideBtn, "BorderColor3", "border")
addStroke(HideBtn, "outline", 1)
HideBtn.MouseEnter:Connect(function() tw(HideBtn, {TextColor3 = Theme.accent}) end)
HideBtn.MouseLeave:Connect(function() tw(HideBtn, {TextColor3 = Theme.txt_muted}) end)

-- ── Inline frame (everything below title bar) ────────────────────────────────
local InlineFrame = mk("Frame", {
    Position = UDim2.fromOffset(7, 36),
    Size = UDim2.new(1, -14, 1, -43),
    BackgroundColor3 = Theme.bg_inline,
    BorderSizePixel = 0,
    Parent = MainFrame,
})
applyTheme(InlineFrame, "BackgroundColor3", "bg_inline")
addLayeredBorder(InlineFrame)

-- ── TOP TAB BAR (atlanta-style) ──────────────────────────────────────────────
local TabBar = mk("Frame", {
    Position = UDim2.fromOffset(7, 7),
    Size = UDim2.new(1, -14, 0, 24),
    BackgroundTransparency = 1,
    Parent = InlineFrame,
})
mk("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    SortOrder = Enum.SortOrder.LayoutOrder,
    VerticalAlignment = Enum.VerticalAlignment.Center,
    Padding = UDim.new(0, 4),
    Parent = TabBar,
})

-- Content area (below tab bar)
local ContentFrame = mk("Frame", {
    Position = UDim2.fromOffset(7, 35),
    Size = UDim2.new(1, -14, 1, -42),
    BackgroundColor3 = Theme.bg_deep,
    BorderSizePixel = 0,
    Parent = InlineFrame,
})
applyTheme(ContentFrame, "BackgroundColor3", "bg_deep")
addLayeredBorder(ContentFrame)
addAccentLine(ContentFrame, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 2))

-- ══════════════════════════════════════════════════════════════════════════════
--  TAB SYSTEM
-- ══════════════════════════════════════════════════════════════════════════════

local tabPages = {}
local tabButtons = {}
local tabData = {}
local activeTab = nil

local function switchTab(name)
    for n, pg in pairs(tabPages) do pg.Visible = (n == name) end
    for n, _ in pairs(tabButtons) do
        local data = tabData[n]
        if not data then continue end
        if n == name then
            tw(data.textLbl, {TextColor3 = Theme.accent, TextTransparency = 0})
            tw(data.bg, {BackgroundColor3 = Theme.bg_panel})
            data.activeBar.Visible = true
            data.activeBar.BackgroundTransparency = 1
            tw(data.activeBar, {BackgroundTransparency = 0}, 0.25)
        else
            tw(data.textLbl, {TextColor3 = Theme.txt, TextTransparency = 0.45})
            tw(data.bg, {BackgroundColor3 = Theme.bg_inline})
            data.activeBar.Visible = false
        end
    end
    activeTab = name
end

local function addTab(label)
    -- Outer button (atlanta-style layered border)
    local btn = mk("TextButton", {
        Size = UDim2.fromOffset(96, 22),
        BackgroundColor3 = Theme.border,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        Parent = TabBar,
    })
    applyTheme(btn, "BackgroundColor3", "border")

    local inline = mk("Frame", {
        Size = UDim2.new(1, -2, 1, -2),
        Position = UDim2.fromOffset(1, 1),
        BackgroundColor3 = Theme.outline,
        BorderSizePixel = 0,
        Parent = btn,
    })
    applyTheme(inline, "BackgroundColor3", "outline")

    local bg = mk("Frame", {
        Size = UDim2.new(1, -2, 1, -2),
        Position = UDim2.fromOffset(1, 1),
        BackgroundColor3 = Theme.bg_inline,
        BorderSizePixel = 0,
        Parent = inline,
    })
    applyTheme(bg, "BackgroundColor3", "bg_inline")
    addVertGradient(bg)

    -- Active accent bar (bottom)
    local activeBar = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 2),
        Position = UDim2.new(0, 0, 1, -2),
        BackgroundColor3 = Theme.accent,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 3,
        Parent = bg,
    })
    applyTheme(activeBar, "BackgroundColor3", "accent")
    mk("UIGradient", {
        Parent = activeBar,
        Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255,255,255)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(165,165,165)),
        },
    })

    local textLbl = mk("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = label:upper(),
        TextColor3 = Theme.txt,
        TextTransparency = 0.45,
        FontFace = UIFontBold,
        TextSize = 11,
        Parent = bg,
    })
    addTextShadow(textLbl)

    tabData[label] = {btn = btn, bg = bg, textLbl = textLbl, activeBar = activeBar}

    btn.MouseEnter:Connect(function()
        if activeTab ~= label then
            tw(textLbl, {TextColor3 = Theme.accent_glow, TextTransparency = 0.1})
            tw(bg, {BackgroundColor3 = Theme.bg_panel})
        end
    end)
    btn.MouseLeave:Connect(function()
        if activeTab ~= label then
            tw(textLbl, {TextColor3 = Theme.txt, TextTransparency = 0.45})
            tw(bg, {BackgroundColor3 = Theme.bg_inline})
        end
    end)

    -- Page (a horizontal container that holds columns)
    local page = mk("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Visible = false,
        Parent = ContentFrame,
    })
    mk("UIPadding", {
        PaddingTop = UDim.new(0, 8),
        PaddingBottom = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 8),
        Parent = page,
    })
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 8),
        HorizontalFlex = Enum.UIFlexAlignment.Fill,
        Parent = page,
    })

    tabPages[label] = page
    tabButtons[label] = btn
    btn.MouseButton1Click:Connect(function() switchTab(label) end)
    return page
end

-- ══════════════════════════════════════════════════════════════════════════════
--  COLUMN BUILDER (a column inside a page; sections go inside columns)
-- ══════════════════════════════════════════════════════════════════════════════

local function addColumn(page)
    local col = mk("ScrollingFrame", {
        Size = UDim2.new(0.5, -4, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.accent,
        ScrollBarImageTransparency = 0.4,
        CanvasSize = UDim2.fromScale(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Parent = page,
    })
    applyTheme(col, "ScrollBarImageColor3", "accent")
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 6),
        Parent = col,
    })
    return col
end

-- ══════════════════════════════════════════════════════════════════════════════
--  SECTION BUILDER (auto-sized to content; atlanta-style top accent line)
-- ══════════════════════════════════════════════════════════════════════════════

-- Map a "body" Frame -> its outer wrap Frame (we can't store custom props on Roblox Instances)
local SectionWrapMap = {}

local function addSection(parent, title)
    -- Outer wrap (border)
    local wrap = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.bg_inline,
        BorderSizePixel = 0,
        Parent = parent,
    })
    applyTheme(wrap, "BackgroundColor3", "bg_inline")
    addLayeredBorder(wrap)

    -- Top accent gradient line
    addAccentLine(wrap, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 2))

    -- Auto vertical layout for header + body
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = wrap,
    })

    -- Header
    local header = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        Parent = wrap,
    })
    local titleLbl = mk("TextLabel", {
        Size = UDim2.new(1, -10, 1, 0),
        Position = UDim2.fromOffset(8, 2),
        BackgroundTransparency = 1,
        Text = title:upper(),
        TextColor3 = Theme.accent_glow,
        FontFace = UIFontBold,
        TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = header,
    })
    applyTheme(titleLbl, "TextColor3", "accent_glow")
    addTextShadow(titleLbl)

    -- Header divider hairline
    local hairline = mk("Frame", {
        Size = UDim2.new(1, -10, 0, 1),
        Position = UDim2.new(0, 5, 1, -1),
        BackgroundColor3 = Theme.outline,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.4,
        Parent = header,
    })
    applyTheme(hairline, "BackgroundColor3", "outline")

    -- Body
    local body = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 2,
        Parent = wrap,
    })
    mk("UIPadding", {
        PaddingTop = UDim.new(0, 4),
        PaddingBottom = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 8),
        PaddingRight = UDim.new(0, 8),
        Parent = body,
    })
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
        Parent = body,
    })

    -- attach the wrap reference so element builders can register for search
    SectionWrapMap[body] = wrap
    return body
end

-- Register an element for search (looks up section wrap from parent body)
local function registerSearch(instance, label, parent)
    local sectionWrap = nil
    if parent and SectionWrapMap[parent] then sectionWrap = SectionWrapMap[parent] end
    table.insert(SearchableElements, {
        instance = instance, label = tostring(label or ""), sectionWrap = sectionWrap,
    })
end

-- ══════════════════════════════════════════════════════════════════════════════
--  ELEMENT BUILDERS (signatures preserved)
-- ══════════════════════════════════════════════════════════════════════════════

-- addLabel ─────────────────────────────────────────────
local function addLabel(parent, defaultText)
    local lbl = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = defaultText or "",
        TextColor3 = Theme.txt_muted,
        FontFace = UIFont, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        RichText = true,
        Parent = parent,
    })
    addTextShadow(lbl)
    registerSearch(lbl, defaultText or "label", parent)
    local shim = {}
    setmetatable(shim, {
        __index = function(_, k)
            if k == "Text" then return lbl.Text end
            if k == "TextColor3" then return lbl.TextColor3 end
        end,
        __newindex = function(_, k, v)
            if k == "Text" then lbl.Text = v
            elseif k == "TextColor3" then lbl.TextColor3 = v end
        end,
    })
    return shim
end

-- addButton ────────────────────────────────────────────
local function addButton(parent, label, callback)
    local btn = mk("TextButton", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = Theme.bg_element,
        BorderSizePixel = 2,
        BorderColor3 = Theme.border,
        Text = "",
        AutoButtonColor = false,
        Parent = parent,
    })
    applyTheme(btn, "BackgroundColor3", "bg_element")
    applyTheme(btn, "BorderColor3", "border")
    addStroke(btn, "outline", 1)
    addVertGradient(btn)

    local textLbl = mk("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromOffset(0, -1),
        BackgroundTransparency = 1,
        Text = label,
        TextColor3 = Theme.txt,
        FontFace = UIFont, TextSize = 11,
        Parent = btn,
    })
    applyTheme(textLbl, "TextColor3", "txt")
    addTextShadow(textLbl)

    btn.MouseButton1Click:Connect(callback or function() end)
    btn.MouseEnter:Connect(function()
        tw(btn, {BackgroundColor3 = Theme.bg_hover})
        tw(textLbl, {TextColor3 = Theme.accent})
    end)
    btn.MouseLeave:Connect(function()
        tw(btn, {BackgroundColor3 = Theme.bg_element})
        tw(textLbl, {TextColor3 = Theme.txt})
    end)

    registerSearch(btn, label, parent)
    local shim = {}
    setmetatable(shim, {
        __index = function(_, k) if k == "Text" then return textLbl.Text end end,
        __newindex = function(_, k, v) if k == "Text" then textLbl.Text = v end end,
    })
    return shim
end

-- addRow ───────────────────────────────────────────────
local function addRow(parent)
    local row = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = parent,
    })
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Horizontal, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,4), Parent=row})

    registerSearch(row, "row", parent)
    local rowShim = {}
    function rowShim:Button(cfg)
        local b = mk("TextButton", {
            Size = UDim2.new(0.55, -2, 1, 0),
            BackgroundColor3 = Theme.bg_element,
            BorderSizePixel = 2, BorderColor3 = Theme.border,
            Text = "", AutoButtonColor = false, Parent = row,
        })
        applyTheme(b, "BackgroundColor3", "bg_element")
        applyTheme(b, "BorderColor3", "border")
        addStroke(b, "outline", 1)
        addVertGradient(b)
        local t = mk("TextLabel", {
            Size=UDim2.fromScale(1,1), Position=UDim2.fromOffset(0,-1),
            BackgroundTransparency=1, Text=cfg.Text or "button",
            TextColor3=Theme.txt, FontFace=UIFont, TextSize=11, Parent=b,
        })
        addTextShadow(t)
        b.MouseButton1Click:Connect(cfg.Callback or function() end)
        b.MouseEnter:Connect(function()
            tw(b, {BackgroundColor3 = Theme.bg_hover})
            tw(t, {TextColor3 = Theme.accent})
        end)
        b.MouseLeave:Connect(function()
            tw(b, {BackgroundColor3 = Theme.bg_element})
            tw(t, {TextColor3 = Theme.txt})
        end)
        return b
    end
    function rowShim:Keybind(cfg)
        return addKeybind(row, cfg, UDim2.new(0.45, -2, 1, 0))
    end
    function rowShim:Slider(cfg)
        return addSlider(row, cfg, UDim2.new(0.45, -2, 1, 0))
    end
    return rowShim
end

-- addKeybind ──────────────────────────────────────────
function addKeybind(parent, cfg, size)
    local currentKey = cfg.Value or Enum.KeyCode.Unknown
    local binding = false

    local btn = mk("TextButton", {
        Size = size or UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = Theme.bg_element,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        Text = "", AutoButtonColor = false, Parent = parent,
    })
    applyTheme(btn, "BackgroundColor3", "bg_element")
    applyTheme(btn, "BorderColor3", "border")
    addStroke(btn, "outline", 1)

    local inner = mk("Frame", {Size=UDim2.fromScale(1,1), BackgroundTransparency=1, Parent=btn})
    mk("UIPadding", {PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,4), Parent=inner})

    mk("TextLabel", {
        Size=UDim2.new(0.55,0,1,0), BackgroundTransparency=1,
        Text=cfg.Label or "keybind", TextColor3=Theme.txt_muted,
        FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=inner,
    })

    local keyBg = mk("Frame", {
        Size=UDim2.new(0.42,0,0.7,0), Position=UDim2.new(0.58,0,0.15,0),
        BackgroundColor3=Theme.bg_deep, BorderSizePixel=2, BorderColor3=Theme.border,
        Parent=inner,
    })
    applyTheme(keyBg, "BackgroundColor3", "bg_deep")
    applyTheme(keyBg, "BorderColor3", "border")
    addStroke(keyBg, "accent_dim", 1, 0.4)

    local keyLbl = mk("TextLabel", {
        Size=UDim2.fromScale(1,1), BackgroundTransparency=1,
        Text=tostring(currentKey):gsub("Enum.KeyCode.", ""),
        TextColor3=Theme.accent, FontFace=UIFont, TextSize=10,
        TextXAlignment=Enum.TextXAlignment.Center, Parent=keyBg,
    })
    applyTheme(keyLbl, "TextColor3", "accent")
    addTextShadow(keyLbl)

    if parent and parent ~= TabBar and parent.Name ~= "" then
        registerSearch(btn, cfg.Label or "keybind", parent)
    end

    local shim = {Value = currentKey}
    btn.MouseButton1Click:Connect(function()
        if binding then return end
        binding = true
        keyLbl.Text = "..."
        keyLbl.TextColor3 = Theme.yellow
        local conn
        conn = UserInputService.InputBegan:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.Keyboard then
                shim.Value = inp.KeyCode
                currentKey = inp.KeyCode
                keyLbl.Text = tostring(inp.KeyCode):gsub("Enum.KeyCode.", "")
                keyLbl.TextColor3 = Theme.accent
                binding = false
                conn:Disconnect()
            end
        end)
    end)
    return shim
end

-- addCheckbox ─────────────────────────────────────────
local function addCheckbox(parent, cfg)
    local enabled = cfg.Default or false

    local row = mk("TextButton", {
        Size=UDim2.new(1,0,0,18), BackgroundTransparency=1, BorderSizePixel=0,
        Text="", AutoButtonColor=false, Parent=parent,
    })

    local box = mk("Frame", {
        Size=UDim2.fromOffset(12,12), Position=UDim2.fromOffset(0,3),
        BackgroundColor3=Theme.bg_deep, BorderSizePixel=2, BorderColor3=Theme.border,
        Parent=row,
    })
    applyTheme(box, "BackgroundColor3", "bg_deep")
    applyTheme(box, "BorderColor3", "border")
    addStroke(box, "outline", 1)
    addVertGradient(box)

    -- Inner filled square as the "checked" indicator (no unicode/emoji)
    local tick = mk("Frame", {
        Size=UDim2.fromOffset(6, 6), Position=UDim2.fromOffset(3, 3),
        BackgroundColor3=Theme.accent, BorderSizePixel=0,
        Visible=enabled, Parent=box,
    })
    applyTheme(tick, "BackgroundColor3", "accent")

    local lbl = mk("TextLabel", {
        Size=UDim2.new(1,-20,1,0), Position=UDim2.fromOffset(20,0),
        BackgroundTransparency=1, Text=cfg.Label or "",
        TextColor3=Theme.txt, FontFace=UIFont, TextSize=11,
        TextXAlignment=Enum.TextXAlignment.Left, Parent=row,
    })
    addTextShadow(lbl)

    registerSearch(row, cfg.Label or "checkbox", parent)
    local shim = {Value = enabled}
    local function setState(v)
        shim.Value = v
        tick.Visible = v
        if v then
            tw(box, {BackgroundColor3 = Theme.accent_dim})
        else
            tw(box, {BackgroundColor3 = Theme.bg_deep})
        end
        if cfg.Callback then cfg.Callback(shim) end
    end
    row.MouseButton1Click:Connect(function() setState(not shim.Value) end)
    row.MouseEnter:Connect(function()
        if not shim.Value then tw(box, {BackgroundColor3 = Theme.bg_panel}) end
        tw(lbl, {TextColor3 = Theme.accent_glow})
    end)
    row.MouseLeave:Connect(function()
        if not shim.Value then tw(box, {BackgroundColor3 = Theme.bg_deep}) end
        tw(lbl, {TextColor3 = Theme.txt})
    end)
    setState(enabled)
    return shim
end

-- addSlider ────────────────────────────────────────────
function addSlider(parent, cfg, size)
    local minValue = cfg.Min or 0
    local maxValue = cfg.Max or 1
    if maxValue <= minValue then maxValue = minValue + 1 end
    local value = math.clamp(cfg.Default or minValue, minValue, maxValue)

    local wrap = mk("Frame", {
        Size = size or cfg.Size or UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = Theme.bg_element, Active = true,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        Parent = parent,
    })
    applyTheme(wrap, "BackgroundColor3", "bg_element")
    applyTheme(wrap, "BorderColor3", "border")
    addStroke(wrap, "outline", 1)

    local lbl = mk("TextLabel", {
        Size = UDim2.new(1, -10, 0, 11), Position = UDim2.fromOffset(5, 2),
        BackgroundTransparency = 1, Text = cfg.Label or "slider",
        TextColor3 = Theme.txt_muted, FontFace = UIFont, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = wrap,
    })

    local track = mk("Frame", {
        Size = UDim2.new(1, -10, 0, 3), Position = UDim2.new(0, 5, 1, -7),
        BackgroundColor3 = Theme.bg_deep, BorderSizePixel = 0, Parent = wrap,
    })
    applyTheme(track, "BackgroundColor3", "bg_deep")

    local fill = mk("Frame", {
        Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Theme.accent_dim,
        BorderSizePixel = 0, Parent = track,
    })
    applyTheme(fill, "BackgroundColor3", "accent_dim")

    local knob = mk("Frame", {
        Size = UDim2.fromOffset(7, 9), AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = Theme.accent,
        BorderSizePixel = 1, BorderColor3 = Theme.border, Parent = track,
    })
    applyTheme(knob, "BackgroundColor3", "accent")
    applyTheme(knob, "BorderColor3", "border")

    registerSearch(wrap, cfg.Label or "slider", parent)

    local shim = {Value = value}
    local dragging = false
    local dragConn = nil
    local function apply(v)
        v = math.clamp(v, minValue, maxValue)
        shim.Value = v
        local alpha = (v - minValue) / (maxValue - minValue)
        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.fromScale(alpha, 0.5)
        lbl.Text = (cfg.Label or "slider").." "..string.format("%.1f", v)
        if cfg.Callback then cfg.Callback(shim) end
    end
    local function setFromScreen(x)
        local width = track.AbsoluteSize.X
        if width <= 0 then return end
        local alpha = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
        apply(minValue + alpha * (maxValue - minValue))
    end
    local function stopDrag()
        dragging = false
        if dragConn then
            dragConn:Disconnect()
            dragConn = nil
        end
        tw(wrap, {BackgroundColor3 = Theme.bg_element})
    end
    wrap.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        dragging = true
        tw(wrap, {BackgroundColor3 = Theme.bg_hover})
        setFromScreen(input.Position.X)
        if not dragConn then
            dragConn = RunService.RenderStepped:Connect(function()
                if dragging then
                    setFromScreen(UserInputService:GetMouseLocation().X)
                end
            end)
        end
    end)
    wrap.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            stopDrag()
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch) then
            stopDrag()
        end
    end)
    apply(value)
    return shim
end

-- addTextbox ──────────────────────────────────────────
local function addTextbox(parent, cfg)
    local wrap = mk("Frame", {
        Size=UDim2.new(1,0,0,22), BackgroundTransparency=1, BorderSizePixel=0, Parent=parent,
    })
    mk("TextLabel", {
        Size=UDim2.new(0.38,0,1,0), BackgroundTransparency=1,
        Text=cfg.Label or "", TextColor3=Theme.txt_muted,
        FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=wrap,
    })
    local box = mk("TextBox", {
        Size=UDim2.new(0.62,0,1,0), Position=UDim2.fromScale(0.38,0),
        BackgroundColor3=Theme.bg_element, BorderSizePixel=2, BorderColor3=Theme.border,
        Text=tostring(cfg.Value or ""), PlaceholderText=cfg.Placeholder or "",
        PlaceholderColor3=Theme.txt_dim, TextColor3=Theme.txt,
        FontFace=UIFont, TextSize=11, TextXAlignment=Enum.TextXAlignment.Left,
        ClearTextOnFocus=false, Parent=wrap,
    })
    applyTheme(box, "BackgroundColor3", "bg_element")
    applyTheme(box, "BorderColor3", "border")
    mk("UIPadding", {PaddingLeft=UDim.new(0,5), PaddingRight=UDim.new(0,4), Parent=box})
    local bxStroke = addStroke(box, "outline", 1)

    box.Focused:Connect(function()
        tw(bxStroke, {Color = Theme.accent, Transparency = 0.3})
        tw(box, {TextColor3 = Theme.accent})
    end)
    box.FocusLost:Connect(function()
        tw(bxStroke, {Color = Theme.outline, Transparency = 0})
        tw(box, {TextColor3 = Theme.txt})
        if cfg.Callback then cfg.Callback(box, box.Text) end
    end)

    registerSearch(wrap, cfg.Label or "textbox", parent)
    local shim = {Value = cfg.Value or ""}
    -- Any assignment to a key the shim does not own is swallowed by __newindex,
    -- which silently dropped the SetValue method below and left callers with a
    -- "missing method" error. Fall through to a real write instead.
    setmetatable(shim, {
        __index = function(_, k) if k == "Value" then return box.Text end end,
        __newindex = function(t, k, v)
            if k == "Value" then box.Text = tostring(v) else rawset(t, k, v) end
        end,
    })
    function shim:SetValue(v) box.Text = tostring(v) end
    return shim
end

-- addCombo (dropdown) ─────────────────────────────────
local function addCombo(parent, cfg)
    local selected = ""
    local open = false

    local wrap = mk("Frame", {
        Size=UDim2.new(1,0,0,22), BackgroundTransparency=1, BorderSizePixel=0, Parent=parent,
    })
    mk("TextLabel", {
        Size=UDim2.new(0.38,0,1,0), BackgroundTransparency=1,
        Text=cfg.Text or "", TextColor3=Theme.txt_muted,
        FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=wrap,
    })

    local dropBtn = mk("TextButton", {
        Size=UDim2.new(0.62,0,1,0), Position=UDim2.fromScale(0.38,0),
        BackgroundColor3=Theme.bg_element, BorderSizePixel=2, BorderColor3=Theme.border,
        Text="  "..(cfg.Placeholder or "select..."), TextColor3=Theme.txt_muted,
        FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
        AutoButtonColor=false, Parent=wrap,
    })
    applyTheme(dropBtn, "BackgroundColor3", "bg_element")
    applyTheme(dropBtn, "BorderColor3", "border")
    addStroke(dropBtn, "outline", 1)

    -- Small "v" indicator (no unicode chevron)
    mk("TextLabel", {
        Size=UDim2.fromOffset(16,22), Position=UDim2.new(1,-18,0,0),
        BackgroundTransparency=1, Text="v", TextColor3=Theme.txt_dim,
        FontFace=UIFontBold, TextSize=11, Parent=dropBtn,
    })

    local listFrame = mk("Frame", {
        BackgroundColor3=Theme.bg_deep, BorderSizePixel=2, BorderColor3=Theme.border,
        Visible=false, ZIndex=100, Size=UDim2.fromOffset(0,0), Parent=RootGui,
    })
    applyTheme(listFrame, "BackgroundColor3", "bg_deep")
    applyTheme(listFrame, "BorderColor3", "border")
    addStroke(listFrame, "outline", 1)
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,0), Parent=listFrame})

    registerSearch(wrap, cfg.Text or "combo", parent)
    local shim = {Value = ""}

    local function buildList()
        for _, ch in ipairs(listFrame:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end
        local items = (cfg.GetItems and cfg.GetItems()) or cfg.Items or {}
        listFrame.Size = UDim2.fromOffset(dropBtn.AbsoluteSize.X, math.min(#items, 8) * 20)
        for _, item in ipairs(items) do
            local opt = mk("TextButton", {
                Size=UDim2.new(1,0,0,20), BackgroundTransparency=1, BorderSizePixel=0,
                Text="  "..tostring(item), TextColor3=Theme.txt_muted,
                FontFace=UIFont, TextSize=10, TextXAlignment=Enum.TextXAlignment.Left,
                AutoButtonColor=false, ZIndex=101, Parent=listFrame,
            })
            opt.MouseEnter:Connect(function()
                opt.BackgroundTransparency = 0.85
                tw(opt, {TextColor3 = Theme.accent})
            end)
            opt.MouseLeave:Connect(function()
                opt.BackgroundTransparency = 1
                tw(opt, {TextColor3 = Theme.txt_muted})
            end)
            opt.MouseButton1Click:Connect(function()
                selected = tostring(item); shim.Value = selected
                dropBtn.Text = "  "..selected; dropBtn.TextColor3 = Theme.txt
                listFrame.Visible = false; open = false
                if cfg.Callback then cfg.Callback(shim, item) end
            end)
        end
    end

    dropBtn.MouseButton1Click:Connect(function()
        open = not open
        if open then
            buildList()
            local abs = dropBtn.AbsolutePosition
            listFrame.Position = UDim2.fromOffset(abs.X, abs.Y + 23)
            listFrame.Visible = true
        else listFrame.Visible = false end
    end)
    UserInputService.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1 and open then
            task.wait()
            local mx, my = inp.Position.X, inp.Position.Y
            local ap, as = listFrame.AbsolutePosition, listFrame.AbsoluteSize
            if not (mx >= ap.X and mx <= ap.X+as.X and my >= ap.Y and my <= ap.Y+as.Y) then
                listFrame.Visible = false; open = false
            end
        end
    end)
    return shim
end

-- makeConsole ─────────────────────────────────────────
local function makeConsole(parent)
    local frame = mk("Frame", {
        Size=UDim2.fromScale(1,1), BackgroundColor3=Theme.bg_deep, BorderSizePixel=0, Parent=parent,
    })
    applyTheme(frame, "BackgroundColor3", "bg_deep")

    local sf = mk("ScrollingFrame", {
        Size=UDim2.new(1,0,1,-26), BackgroundTransparency=1, BorderSizePixel=0,
        ScrollBarThickness=2, ScrollBarImageColor3=Theme.accent_dim,
        CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
        Parent=frame,
    })
    mk("UIPadding", {PaddingTop=UDim.new(0,4), PaddingBottom=UDim.new(0,4),
        PaddingLeft=UDim.new(0,6), PaddingRight=UDim.new(0,6), Parent=sf})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,2), Parent=sf})

    local promptBar = mk("Frame", {
        Size=UDim2.new(1,0,0,26), Position=UDim2.new(0,0,1,-26),
        BackgroundColor3=Theme.bg_inline, BorderSizePixel=0, Parent=frame,
    })
    applyTheme(promptBar, "BackgroundColor3", "bg_inline")
    mk("Frame", {Size=UDim2.new(1,0,0,1), BackgroundColor3=Theme.outline, BorderSizePixel=0, Parent=promptBar})
    mk("Frame", {Size=UDim2.new(0,2,1,0), BackgroundColor3=Theme.accent, BorderSizePixel=0, Parent=promptBar})
    mk("TextLabel", {
        Size=UDim2.fromOffset(14,26), Position=UDim2.fromOffset(6,0),
        BackgroundTransparency=1, Text=">", TextColor3=Theme.accent_glow,
        FontFace=UIFont, TextSize=13, TextXAlignment=Enum.TextXAlignment.Center,
        Parent=promptBar,
    })

    local inputBox = mk("TextBox", {
        Size=UDim2.new(1,-22,1,0), Position=UDim2.fromOffset(20,0),
        BackgroundTransparency=1, BorderSizePixel=0,
        Text="", PlaceholderText="enter command...", PlaceholderColor3=Theme.txt_dim,
        TextColor3=Theme.accent, FontFace=UIFont, TextSize=11,
        TextXAlignment=Enum.TextXAlignment.Left, ClearTextOnFocus=false,
        Parent=promptBar,
    })
    mk("UIPadding", {PaddingLeft=UDim.new(0,4), PaddingRight=UDim.new(0,4), Parent=inputBox})

    local consoleShim = {Callback = nil}
    function consoleShim:AppendText(...)
        local parts = {}
        for _, v in ipairs({...}) do parts[#parts+1] = tostring(v) end
        local msg = table.concat(parts, " ")
        local lbl = mk("TextLabel", {
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            BackgroundTransparency=1, Text=msg, RichText=false,
            TextColor3=Theme.txt_muted, FontFace=UIFont, TextSize=11,
            TextXAlignment=Enum.TextXAlignment.Left, TextWrapped=true, Parent=sf,
        })
        local lo = msg:lower()
        if lo:find("error") or lo:find("fail") or lo:find("warn") then
            lbl.TextColor3 = Theme.yellow
        elseif lo:find("loaded") or lo:find("saved") or lo:find("done") or lo:find("ok") then
            lbl.TextColor3 = Theme.green
        elseif lo:find("reading") or lo:find("decod") or lo:find("encod") then
            lbl.TextColor3 = Theme.cyan
        end
        task.defer(function()
            sf.CanvasPosition = Vector2.new(0, sf.AbsoluteCanvasSize.Y)
        end)
    end

    inputBox.FocusLost:Connect(function(enter)
        if enter and #inputBox.Text > 0 then
            local txt = inputBox.Text; inputBox.Text = ""
            if consoleShim.Callback then
                local shimSelf = {Clear = function() inputBox.Text = "" end}
                consoleShim.Callback(shimSelf, txt)
            end
        end
    end)

    local inputShim = {}
    setmetatable(inputShim, {
        __newindex = function(_, k, v) if k == "Callback" then consoleShim.Callback = v end end,
        __index = function(_, k) if k == "Callback" then return consoleShim.Callback end end,
    })
    return consoleShim, inputShim
end

-- makePopup ───────────────────────────────────────────
local function makePopup(title)
    local overlay = mk("Frame", {
        Size=UDim2.fromScale(1,1), BackgroundColor3=Color3.new(0,0,0),
        BackgroundTransparency=0.5, BorderSizePixel=0, ZIndex=200, Parent=RootGui,
    })
    local box = mk("Frame", {
        Size=UDim2.fromOffset(320,0), AutomaticSize=Enum.AutomaticSize.Y,
        Position=UDim2.fromScale(0.5,0.5), AnchorPoint=Vector2.new(0.5,0.5),
        BackgroundColor3=Theme.bg_window, BorderSizePixel=2, BorderColor3=Theme.border,
        ZIndex=201, Parent=overlay,
    })
    applyTheme(box, "BackgroundColor3", "bg_window")
    applyTheme(box, "BorderColor3", "border")
    addStroke(box, "outline", 1)
    addAccentLine(box, UDim2.fromOffset(0,0), UDim2.new(1,0,0,2))

    local popHdr = mk("Frame", {
        Size=UDim2.new(1,0,0,26), BackgroundColor3=Theme.bg_deep,
        BorderSizePixel=0, ZIndex=202, Parent=box,
    })
    applyTheme(popHdr, "BackgroundColor3", "bg_deep")
    mk("TextLabel", {
        Size=UDim2.new(1,0,1,0), BackgroundTransparency=1,
        Text=title:upper(), TextColor3=Theme.accent,
        FontFace=UIFontBold, TextSize=11, ZIndex=202, Parent=popHdr,
    })
    mk("Frame", {
        Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1),
        BackgroundColor3=Theme.outline, BorderSizePixel=0, ZIndex=202, Parent=popHdr,
    })

    local body = mk("Frame", {
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        Position=UDim2.fromOffset(0,26), BackgroundTransparency=1,
        BorderSizePixel=0, ZIndex=202, Parent=box,
    })
    mk("UIPadding", {PaddingTop=UDim.new(0,8), PaddingBottom=UDim.new(0,10),
        PaddingLeft=UDim.new(0,10), PaddingRight=UDim.new(0,10), Parent=body})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical, SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0,6), Parent=body})

    -- subtle popup fade-in
    overlay.BackgroundTransparency = 1
    box.Size = UDim2.fromOffset(320, 0)
    tw(overlay, {BackgroundTransparency = 0.5}, 0.18)

    local popup = {}
    function popup:Textbox(c) return addTextbox(body, {Label=c.Text or "", Placeholder=c.Placeholder or "", Callback=c.Callback}) end
    function popup:Combo(c) return addCombo(body, c) end
    function popup:Button(c) addButton(body, c.Text or "ok", function() if c.Callback then c.Callback() end end) end
    function popup:ClosePopup() overlay:Destroy() end
    return popup
end

-- ══════════════════════════════════════════════════════════════════════════════
--  PLAYER VIEWER (adapted from atlanta playerlist)
-- ══════════════════════════════════════════════════════════════════════════════


-- ══════════════════════════════════════════════════════════════════════════════
--  SECONDARY WINDOW HELPER (draggable, same theme as main, hidden by default)
-- ══════════════════════════════════════════════════════════════════════════════

local SecondaryWindows = {} -- list of {frame=..., open=...} for housekeeping

local function makeSecondaryWindow(title, w, h, defaultPos)
    local win = mk("Frame", {
        Name = "SecondaryWindow_" .. title:gsub("%s+", "_"),
        Size = UDim2.fromOffset(w, h),
        Position = defaultPos or UDim2.new(0.5, -w/2 + 50, 0.5, -h/2 + 50),
        BackgroundColor3 = Theme.bg_window,
        BorderSizePixel = 0,
        Visible = false,
        Parent = RootGui,
    })
    applyTheme(win, "BackgroundColor3", "bg_window")

    -- Outer accent stroke
    local acStroke = mk("UIStroke", {
        Parent = win, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        LineJoinMode = Enum.LineJoinMode.Miter, Color = Theme.accent, Thickness = 1,
    })
    applyTheme(acStroke, "Color", "accent")

    -- Top accent line
    addAccentLine(win, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 2))

    -- Title bar
    local tb = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 26),
        Position = UDim2.fromOffset(0, 2),
        BackgroundColor3 = Theme.bg_deep,
        BorderSizePixel = 0,
        Parent = win,
    })
    applyTheme(tb, "BackgroundColor3", "bg_deep")
    mk("Frame", {
        Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = Theme.outline, BorderSizePixel = 0, Parent = tb,
    })
    applyTheme(mk("Frame", {
        Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1),
        BackgroundColor3 = Theme.outline, BorderSizePixel = 0, Parent = tb,
    }), "BackgroundColor3", "outline")

    -- Drag
    do
        local dragging, dragStart, frameStart
        tb.InputBegan:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true; dragStart = inp.Position; frameStart = win.Position
            end
        end)
        tb.InputEnded:Connect(function(inp)
            if inp.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
        end)
        UserInputService.InputChanged:Connect(function(inp)
            if dragging and inp.UserInputType == Enum.UserInputType.MouseMovement then
                local d = inp.Position - dragStart
                win.Position = UDim2.new(
                    frameStart.X.Scale, frameStart.X.Offset + d.X,
                    frameStart.Y.Scale, frameStart.Y.Offset + d.Y)
            end
        end)
    end

    -- Title text
    local titleLbl = mk("TextLabel", {
        Size = UDim2.new(1, -50, 1, 0),
        Position = UDim2.fromOffset(10, 0),
        BackgroundTransparency = 1,
        Text = title:upper(),
        TextColor3 = Theme.accent,
        FontFace = UIFontBold,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = tb,
    })
    applyTheme(titleLbl, "TextColor3", "accent")
    addTextShadow(titleLbl)

    -- Close (X) button
    local closeBtn = mk("TextButton", {
        Size = UDim2.fromOffset(20, 16),
        Position = UDim2.new(1, -28, 0.5, -8),
        BackgroundColor3 = Theme.bg_element,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        Text = "x", TextColor3 = Theme.txt_muted,
        FontFace = UIFontBold, TextSize = 11,
        AutoButtonColor = false, Parent = tb,
    })
    applyTheme(closeBtn, "BackgroundColor3", "bg_element")
    applyTheme(closeBtn, "BorderColor3", "border")
    addStroke(closeBtn, "outline", 1)

    -- Inline content frame
    local inline = mk("Frame", {
        Position = UDim2.fromOffset(7, 32),
        Size = UDim2.new(1, -14, 1, -39),
        BackgroundColor3 = Theme.bg_inline,
        BorderSizePixel = 0,
        Parent = win,
    })
    applyTheme(inline, "BackgroundColor3", "bg_inline")
    addLayeredBorder(inline)

    local content = mk("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = inline,
    })

    -- Toggle behavior
    local sw = {frame = win, content = content, isOpen = false}
    function sw:Show()
        if self.isOpen then return end
        self.isOpen = true
        win.Visible = true
        win.Size = UDim2.fromOffset(math.floor(w*0.92), math.floor(h*0.92))
        win.BackgroundTransparency = 1
        tw(win, {Size = UDim2.fromOffset(w, h), BackgroundTransparency = 0}, 0.14, Enum.EasingStyle.Cubic)
    end
    function sw:Hide()
        if not self.isOpen then return end
        self.isOpen = false
        local t = tw(win, {
            Size = UDim2.fromOffset(math.floor(w*0.92), math.floor(h*0.92)),
            BackgroundTransparency = 1,
        }, 0.12, Enum.EasingStyle.Cubic)
        t.Completed:Connect(function() if not self.isOpen then win.Visible = false end end)
    end
    function sw:Toggle() if self.isOpen then self:Hide() else self:Show() end end

    closeBtn.MouseButton1Click:Connect(function() sw:Hide() end)
    closeBtn.MouseEnter:Connect(function() tw(closeBtn, {TextColor3 = Theme.red}) end)
    closeBtn.MouseLeave:Connect(function() tw(closeBtn, {TextColor3 = Theme.txt_muted}) end)

    table.insert(SecondaryWindows, sw)
    return sw
end

-- ══════════════════════════════════════════════════════════════════════════════
--  PLAYER VIEWER WINDOW (3D viewport + state info, no ESP overlays)
-- ══════════════════════════════════════════════════════════════════════════════

function buildPlayerWindow()
    -- Bigger window so all sections fit comfortably
    PlayerWindow = makeSecondaryWindow("PLAYER VIEWER", 580, 510)
    local content = PlayerWindow.content

    mk("UIPadding", {
        PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
        PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
        Parent = content,
    })
    -- NOTE: no UIListLayout here. We use absolute positioning so sizes are deterministic.

    -- ── LEFT COLUMN: player list ──────────────────────────────────────────
    local leftCol = mk("Frame", {
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(0, 190, 1, 0),
        BackgroundColor3 = Theme.bg_inline, BorderSizePixel = 0,
        Parent = content,
    })
    applyTheme(leftCol, "BackgroundColor3", "bg_inline")
    addLayeredBorder(leftCol)
    addAccentLine(leftCol, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 2))

    mk("UIPadding", {
        PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 6),
        PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
        Parent = leftCol,
    })

    local leftHdr = mk("TextLabel", {
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1, Text = "PLAYERS",
        TextColor3 = Theme.accent_glow, FontFace = UIFontBold, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = leftCol,
    })
    applyTheme(leftHdr, "TextColor3", "accent_glow")
    addTextShadow(leftHdr)

    local plSrchWrap = mk("Frame", {
        Position = UDim2.fromOffset(0, 20),
        Size = UDim2.new(1, 0, 0, 20),
        BackgroundColor3 = Theme.bg_element, BorderSizePixel = 2, BorderColor3 = Theme.border,
        Parent = leftCol,
    })
    applyTheme(plSrchWrap, "BackgroundColor3", "bg_element")
    applyTheme(plSrchWrap, "BorderColor3", "border")
    local plSrchStroke = addStroke(plSrchWrap, "outline", 1)

    local plSrchInput = mk("TextBox", {
        Size = UDim2.new(1, -8, 1, 0),
        Position = UDim2.fromOffset(4, 0),
        BackgroundTransparency = 1, Text = "",
        PlaceholderText = "search players...",
        PlaceholderColor3 = Theme.txt_dim,
        TextColor3 = Theme.txt, FontFace = UIFont, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false, Parent = plSrchWrap,
    })
    plSrchInput.Focused:Connect(function() tw(plSrchStroke, {Color = Theme.accent, Transparency = 0.3}) end)
    plSrchInput.FocusLost:Connect(function() tw(plSrchStroke, {Color = Theme.outline, Transparency = 0}) end)

    local listScroll = mk("ScrollingFrame", {
        Position = UDim2.fromOffset(0, 46),
        Size = UDim2.new(1, 0, 1, -46),
        BackgroundColor3 = Theme.bg_deep,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.accent,
        ScrollBarImageTransparency = 0.4,
        CanvasSize = UDim2.fromScale(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Parent = leftCol,
    })
    applyTheme(listScroll, "BackgroundColor3", "bg_deep")
    applyTheme(listScroll, "BorderColor3", "border")
    applyTheme(listScroll, "ScrollBarImageColor3", "accent")
    addStroke(listScroll, "outline", 1)
    mk("UIPadding", {PaddingTop=UDim.new(0,3), PaddingBottom=UDim.new(0,3),
        PaddingLeft=UDim.new(0,3), PaddingRight=UDim.new(0,3), Parent=listScroll})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical,
        SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,2), Parent=listScroll})

    -- ── RIGHT COLUMN: viewport + state info ─────────────────────────────────
    local rightCol = mk("Frame", {
        Position = UDim2.fromOffset(196, 0),
        Size = UDim2.new(1, -196, 1, 0),
        BackgroundColor3 = Theme.bg_inline, BorderSizePixel = 0,
        Parent = content,
    })
    applyTheme(rightCol, "BackgroundColor3", "bg_inline")
    addLayeredBorder(rightCol)
    addAccentLine(rightCol, UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 2))

    mk("UIPadding", {
        PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 6),
        PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
        Parent = rightCol,
    })

    local rightHdr = mk("TextLabel", {
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1, Text = "PREVIEW",
        TextColor3 = Theme.accent_glow, FontFace = UIFontBold, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = rightCol,
    })
    applyTheme(rightHdr, "TextColor3", "accent_glow")
    addTextShadow(rightHdr)

    -- Viewport (200 px tall)
    local vpWrap = mk("Frame", {
        Position = UDim2.fromOffset(0, 20),
        Size = UDim2.new(1, 0, 0, 200),
        BackgroundColor3 = Theme.bg_deep,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        Parent = rightCol,
    })
    applyTheme(vpWrap, "BackgroundColor3", "bg_deep")
    applyTheme(vpWrap, "BorderColor3", "border")
    addStroke(vpWrap, "outline", 1)

    local vp = mk("ViewportFrame", {
        Size = UDim2.new(1, -2, 1, -2),
        Position = UDim2.fromOffset(1, 1),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Ambient = Color3.fromRGB(220, 220, 220),
        LightColor = Color3.fromRGB(255, 255, 255),
        LightDirection = Vector3.new(-0.4, -1, -0.6),
        Parent = vpWrap,
    })

    local vpCam = mk("Camera", {
        FieldOfView = 50,
        Parent = vp,
    })
    vp.CurrentCamera = vpCam
    -- Place camera once: position (0, 0.5, 2), looking toward (0, 0, -10) where the clone will live
    vpCam.CFrame = CFrame.lookAt(Vector3.new(0, 0.5, 2), Vector3.new(0, 0, -10))

    -- State header + box
    local stateHdr = mk("TextLabel", {
        Position = UDim2.fromOffset(0, 226),
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1, Text = "STATE",
        TextColor3 = Theme.accent_glow, FontFace = UIFontBold, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, Parent = rightCol,
    })
    applyTheme(stateHdr, "TextColor3", "accent_glow")
    addTextShadow(stateHdr)

    local stateBox = mk("Frame", {
        Position = UDim2.fromOffset(0, 244),
        Size = UDim2.new(1, 0, 1, -244),
        BackgroundColor3 = Theme.bg_deep,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        Parent = rightCol,
    })
    applyTheme(stateBox, "BackgroundColor3", "bg_deep")
    applyTheme(stateBox, "BorderColor3", "border")
    addStroke(stateBox, "outline", 1)

    mk("UIPadding", {
        PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
        PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
        Parent = stateBox,
    })
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 2),
        Parent = stateBox,
    })

    local function makeStateLine()
        local lbl = mk("TextLabel", {
            Size = UDim2.new(1, 0, 0, 13),
            BackgroundTransparency = 1, Text = "-",
            TextColor3 = Theme.txt, FontFace = UIFont, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            RichText = true, Parent = stateBox,
        })
        addTextShadow(lbl)
        return lbl
    end

    local sNameLbl   = makeStateLine()
    local sDispLbl   = makeStateLine()
    local sUidLbl    = makeStateLine()
    local sStateLbl  = makeStateLine()
    local sHealthLbl = makeStateLine()
    local sWalkLbl   = makeStateLine()
    local sJumpLbl   = makeStateLine()
    local sPosLbl    = makeStateLine()
    local sVelLbl    = makeStateLine()
    local sAnimLbl   = makeStateLine()
    local sTeamLbl   = makeStateLine()

    -- ── Selection + viewport mirroring ──────────────────────────────────────
    local selectedPlayer = nil
    local cloneChar = nil
    local livePartLookup = {}   -- relPath -> live BasePart
    local clonePartLookup = {}  -- relPath -> clone BasePart
    local cloneRoot = nil
    local rotation = 0
    local selectedRow = nil
    local rowMap = {}

    -- Compute path from a part up to (but not including) the character root
    local function getRelPath(part, root)
        local segs = {}
        local p = part
        while p and p ~= root do
            table.insert(segs, 1, p.Name)
            p = p.Parent
        end
        return table.concat(segs, "/")
    end

    local function clearClone()
        if cloneChar then cloneChar:Destroy() end
        cloneChar = nil
        livePartLookup = {}
        clonePartLookup = {}
        cloneRoot = nil
    end

    local function rebuildClone()
        clearClone()
        if not selectedPlayer then return end
        local liveChar = selectedPlayer.Character
        if not liveChar then return end
        local liveHRP = liveChar:FindFirstChild("HumanoidRootPart")
        if not liveHRP then return end

        local ok, c = pcall(function()
            liveChar.Archivable = true
            return liveChar:Clone()
        end)
        if not ok or not c then return end
        cloneChar = c

        -- Strip scripts, animator, and humanoid logic from the clone (we drive parts manually)
        for _, d in pairs(c:GetDescendants()) do
            if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
                d:Destroy()
            end
        end

        cloneChar.Parent = vp

        cloneRoot = cloneChar:FindFirstChild("HumanoidRootPart")
        if not cloneRoot then clearClone(); return end

        -- Build BasePart lookups keyed by RELATIVE PATH (not GetFullName)
        for _, p in pairs(liveChar:GetDescendants()) do
            if p:IsA("BasePart") then
                livePartLookup[getRelPath(p, liveChar)] = p
            end
        end
        for _, p in pairs(cloneChar:GetDescendants()) do
            if p:IsA("BasePart") then
                p.Anchored = true        -- prevent any drift; we set CFrame manually
                p.CanCollide = false     -- not strictly needed in viewport but safe
                clonePartLookup[getRelPath(p, cloneChar)] = p
            end
        end
    end

    local function setSelectedPlayer(plr)
        selectedPlayer = plr
        if not plr then
            sNameLbl.Text = "Name: -"; sDispLbl.Text = "Display: -"; sUidLbl.Text = "UserId: -"
            sStateLbl.Text = "State: -"; sHealthLbl.Text = "Health: -"
            sWalkLbl.Text = "WalkSpeed: -"; sJumpLbl.Text = "JumpPower: -"
            sPosLbl.Text = "Position: -"; sVelLbl.Text = "Velocity: -"
            sAnimLbl.Text = "Animation: -"; sTeamLbl.Text = "Team: -"
            clearClone()
            return
        end
        sNameLbl.Text = "Name: <font color='#ffffff'>" .. plr.Name .. "</font>"
        sDispLbl.Text = "Display: " .. plr.DisplayName
        sUidLbl.Text  = "UserId: " .. tostring(plr.UserId)
        sTeamLbl.Text = "Team: " .. (plr.Team and plr.Team.Name or "None")
        rebuildClone()
        if plr.CharacterAdded then
            plr.CharacterAdded:Connect(function()
                task.wait(0.5)
                if selectedPlayer == plr then rebuildClone() end
            end)
        end
    end

    local function makePlayerRow(plr)
        if rowMap[plr] then return end
        local row = mk("TextButton", {
            Size = UDim2.new(1, 0, 0, 18),
            BackgroundColor3 = Theme.bg_panel,
            BorderSizePixel = 0,
            Text = "", AutoButtonColor = false, Parent = listScroll,
        })
        applyTheme(row, "BackgroundColor3", "bg_panel")
        local nameLbl = mk("TextLabel", {
            Size = UDim2.new(1, -6, 1, 0),
            Position = UDim2.fromOffset(4, 0),
            BackgroundTransparency = 1, Text = plr.Name,
            TextColor3 = (plr == Player) and Theme.accent or Theme.txt,
            FontFace = UIFont, TextSize = 11,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
        })
        addTextShadow(nameLbl)
        row.MouseEnter:Connect(function()
            if selectedRow ~= row then tw(row, {BackgroundColor3 = Theme.bg_hover}) end
        end)
        row.MouseLeave:Connect(function()
            if selectedRow ~= row then tw(row, {BackgroundColor3 = Theme.bg_panel}) end
        end)
        row.MouseButton1Click:Connect(function()
            if selectedRow then tw(selectedRow, {BackgroundColor3 = Theme.bg_panel}) end
            selectedRow = row
            tw(row, {BackgroundColor3 = Theme.accent_dim})
            setSelectedPlayer(plr)
        end)
        rowMap[plr] = {row = row, nameLbl = nameLbl}
    end

    local function removePlayerRow(plr)
        local data = rowMap[plr]
        if data then data.row:Destroy(); rowMap[plr] = nil end
        if selectedPlayer == plr then setSelectedPlayer(nil) end
    end

    plSrchInput:GetPropertyChangedSignal("Text"):Connect(function()
        local q = plSrchInput.Text:lower()
        for plr, data in pairs(rowMap) do
            data.row.Visible = q == "" or plr.Name:lower():find(q, 1, true) ~= nil
                or plr.DisplayName:lower():find(q, 1, true) ~= nil
        end
    end)

    for _, plr in ipairs(Players:GetPlayers()) do makePlayerRow(plr) end
    Players.PlayerAdded:Connect(makePlayerRow)
    Players.PlayerRemoving:Connect(removePlayerRow)

    -- ── Render loop: mirror live character to clone, update state ───────────
    game:GetService("RunService").RenderStepped:Connect(function(dt)
        if not PlayerWindow or not PlayerWindow.isOpen then return end
        if not selectedPlayer then return end
        local liveChar = selectedPlayer.Character
        if not liveChar or not cloneChar or not cloneRoot then return end
        local liveHRP = liveChar:FindFirstChild("HumanoidRootPart")
        if not liveHRP then return end

        -- Rotate the preview view (around Y axis)
        rotation = rotation + dt * 30
        local previewRoot = CFrame.new(0, 0, -10) * CFrame.Angles(0, math.rad(rotation), 0)

        -- Mirror parts using relative-path lookup (this is what was broken before)
        for relPath, livePart in pairs(livePartLookup) do
            local clonePart = clonePartLookup[relPath]
            if clonePart and clonePart.Parent and livePart and livePart.Parent then
                -- Position relative to live HRP, then place at preview root
                local rel = liveHRP.CFrame:ToObjectSpace(livePart.CFrame)
                clonePart.CFrame = previewRoot * rel
            end
        end

        -- Update state info
        local hum = liveChar:FindFirstChildOfClass("Humanoid")
        if hum then
            local state = tostring(hum:GetState()):gsub("Enum.HumanoidStateType.", "")
            local stateColor = "#ffffff"
            if state == "Jumping" or state == "Freefall" then stateColor = "#80ff80"
            elseif state == "Running" then stateColor = "#ffdc50"
            elseif state == "Climbing" then stateColor = "#ff9650"
            elseif state == "Dead" then stateColor = "#ff5050" end
            sStateLbl.Text  = string.format("State: <font color='%s'>%s</font>", stateColor, state)
            sHealthLbl.Text = string.format("Health: <font color='#ff8080'>%.0f</font> / %.0f", hum.Health, hum.MaxHealth)
            sWalkLbl.Text   = string.format("WalkSpeed: <font color='#aaffaa'>%.1f</font>", hum.WalkSpeed)
            sJumpLbl.Text   = string.format("JumpPower: <font color='#aaffaa'>%.1f</font>", hum.JumpPower)

            -- Currently playing animation
            local anim = "-"
            local animator = hum:FindFirstChildOfClass("Animator")
            local tracks = animator and animator:GetPlayingAnimationTracks() or hum:GetPlayingAnimationTracks()
            if tracks and #tracks > 0 then
                local t = tracks[1]
                anim = t.Name
                if t.Animation and t.Animation.AnimationId then
                    anim = anim .. " (" .. t.Animation.AnimationId .. ")"
                end
            end
            sAnimLbl.Text = "Animation: " .. anim
        end

        local pos = liveHRP.Position
        local vel = liveHRP.Velocity
        sPosLbl.Text = string.format("Position: %.1f, %.1f, %.1f", pos.X, pos.Y, pos.Z)
        sVelLbl.Text = string.format("Velocity: <font color='#ffdc50'>%.1f</font>  (%.1f, %.1f, %.1f)",
            vel.Magnitude, vel.X, vel.Y, vel.Z)
    end)

    task.defer(function() setSelectedPlayer(Player) end)
end

-- ══════════════════════════════════════════════════════════════════════════════
--  FILE MANAGER WINDOW (config-style: list + actions + create input)
-- ══════════════════════════════════════════════════════════════════════════════

function buildFileWindow()
    FileWindow = makeSecondaryWindow("FILE MANAGER", 420, 420)
    local content = FileWindow.content

    mk("UIPadding", {
        PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
        PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
        Parent = content,
    })
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 6),
        Parent = content,
    })

    -- Top: "current file" display
    local curWrap = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundColor3 = Theme.bg_deep,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        LayoutOrder = 1, Parent = content,
    })
    applyTheme(curWrap, "BackgroundColor3", "bg_deep")
    applyTheme(curWrap, "BorderColor3", "border")
    addStroke(curWrap, "outline", 1)

    local curLbl = mk("TextLabel", {
        Size = UDim2.new(1, -10, 1, 0), Position = UDim2.fromOffset(6, 0),
        BackgroundTransparency = 1, Text = "Current: " .. tostring(ReplayPath or "—"),
        TextColor3 = Theme.accent, FontFace = UIFont, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd, Parent = curWrap,
    })
    applyTheme(curLbl, "TextColor3", "accent")

    -- Section: file list
    local listHdr = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = "REPLAY FILES", TextColor3 = Theme.accent_glow,
        FontFace = UIFontBold, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = 2, Parent = content,
    })
    applyTheme(listHdr, "TextColor3", "accent_glow")
    addTextShadow(listHdr)

    -- File list scrollable
    local listScroll = mk("ScrollingFrame", {
        Size = UDim2.new(1, 0, 0, 160),
        BackgroundColor3 = Theme.bg_deep,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.accent,
        ScrollBarImageTransparency = 0.4,
        CanvasSize = UDim2.fromScale(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        LayoutOrder = 3, Parent = content,
    })
    applyTheme(listScroll, "BackgroundColor3", "bg_deep")
    applyTheme(listScroll, "BorderColor3", "border")
    applyTheme(listScroll, "ScrollBarImageColor3", "accent")
    addStroke(listScroll, "outline", 1)
    mk("UIPadding", {PaddingTop=UDim.new(0,3), PaddingBottom=UDim.new(0,3),
        PaddingLeft=UDim.new(0,3), PaddingRight=UDim.new(0,3), Parent=listScroll})
    mk("UIListLayout", {FillDirection=Enum.FillDirection.Vertical,
        SortOrder=Enum.SortOrder.LayoutOrder, Padding=UDim.new(0,2), Parent=listScroll})

    local selectedRow = nil
    local selectedPath = nil

    local function fileShortName(path)
        local parts = string.split(path, "\\")
        local n = parts[#parts] or path
        return n
    end

    local function refreshList()
        for _, ch in ipairs(listScroll:GetChildren()) do
            if ch:IsA("TextButton") then ch:Destroy() end
        end
        selectedRow = nil
        local ok, files = pcall(function() return listfiles(FolderPath) end)
        if not ok or not files then return end
        for _, p in ipairs(files) do
            local row = mk("TextButton", {
                Size = UDim2.new(1, 0, 0, 18),
                BackgroundColor3 = Theme.bg_panel,
                BorderSizePixel = 0, Text = "", AutoButtonColor = false,
                Parent = listScroll,
            })
            applyTheme(row, "BackgroundColor3", "bg_panel")

            local nameLbl = mk("TextLabel", {
                Size = UDim2.new(1, -6, 1, 0),
                Position = UDim2.fromOffset(4, 0),
                BackgroundTransparency = 1, Text = fileShortName(p),
                TextColor3 = (p == ReplayPath) and Theme.accent or Theme.txt,
                FontFace = UIFont, TextSize = 11,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
            })
            addTextShadow(nameLbl)

            row.MouseEnter:Connect(function()
                if selectedRow ~= row then tw(row, {BackgroundColor3 = Theme.bg_hover}) end
            end)
            row.MouseLeave:Connect(function()
                if selectedRow ~= row then tw(row, {BackgroundColor3 = Theme.bg_panel}) end
            end)
            row.MouseButton1Click:Connect(function()
                if selectedRow then tw(selectedRow, {BackgroundColor3 = Theme.bg_panel}) end
                selectedRow = row
                selectedPath = p
                tw(row, {BackgroundColor3 = Theme.accent_dim})
            end)
        end
    end

    -- Section: actions (Save / Load / Delete on selection)
    local actHdr = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = "ACTIONS", TextColor3 = Theme.accent_glow,
        FontFace = UIFontBold, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = 4, Parent = content,
    })
    applyTheme(actHdr, "TextColor3", "accent_glow")
    addTextShadow(actHdr)

    local actRow = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1, LayoutOrder = 5, Parent = content,
    })
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
        HorizontalFlex = Enum.UIFlexAlignment.Fill,
        Parent = actRow,
    })

    local function makeFlexBtn(parent, label, callback)
        local b = mk("TextButton", {
            Size = UDim2.new(0.25, -3, 1, 0),
            BackgroundColor3 = Theme.bg_element,
            BorderSizePixel = 2, BorderColor3 = Theme.border,
            Text = "", AutoButtonColor = false, Parent = parent,
        })
        applyTheme(b, "BackgroundColor3", "bg_element")
        applyTheme(b, "BorderColor3", "border")
        addStroke(b, "outline", 1)
        addVertGradient(b)
        local t = mk("TextLabel", {
            Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
            Text = label, TextColor3 = Theme.txt,
            FontFace = UIFont, TextSize = 11, Parent = b,
        })
        addTextShadow(t)
        b.MouseButton1Click:Connect(callback)
        b.MouseEnter:Connect(function()
            tw(b, {BackgroundColor3 = Theme.bg_hover}); tw(t, {TextColor3 = Theme.accent})
        end)
        b.MouseLeave:Connect(function()
            tw(b, {BackgroundColor3 = Theme.bg_element}); tw(t, {TextColor3 = Theme.txt})
        end)
        return b
    end

    makeFlexBtn(actRow, "Load", function()
        if not selectedPath then ConsoleMessage("No file selected"); return end
        ReplayPath = selectedPath
        curLbl.Text = "Current: " .. selectedPath
        ConsoleMessage("Loading: " .. selectedPath)
        if selectedPath ~= LastLoadedPath or ReplayNeedsReload then
            -- a file the client cannot read (locked, removed, malformed) must leave the cached
            -- replay and the UI alive instead of erroring out of the click handler
            local okRead, fc = pcall(readfile, selectedPath)
            if not okRead then
                ConsoleMessage("Read error:", tostring(fc))
                return
            end
            if #fc > #ReplayFileBeginning then
                local okDec, Decoded, DecodedFPS = pcall(ReplayDecode, fc)
                if not okDec then
                    ConsoleMessage("Decode error:", tostring(Decoded))
                    return
                end
                ReplayTable = Decoded or {}
                SpeedHack.Rate.Loaded = true
                PlaybackCtl.FileFPS = tonumber(DecodedFPS) or nil
                ReplayNeedsReload = false; LastLoadedPath = selectedPath
                ConsoleMessage("Decoded and cached replay")
            else
                ReplayTable = {}; ReplayNeedsReload = false; LastLoadedPath = selectedPath
                ConsoleMessage("File is empty")
            end
        else ConsoleMessage("Using cached replay") end
        refreshList()
    end)

    makeFlexBtn(actRow, "Save", function() SaveToFile() end)

    makeFlexBtn(actRow, "Delete", function()
        if not selectedPath then ConsoleMessage("No file selected"); return end
        pcall(function() delfile(selectedPath) end)
        ConsoleMessage("Deleted: " .. selectedPath)
        selectedPath = nil; selectedRow = nil
        refreshList()
    end)

    makeFlexBtn(actRow, "Refresh", function() refreshList() end)

    -- Section: create new
    local crtHdr = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = "CREATE NEW", TextColor3 = Theme.accent_glow,
        FontFace = UIFontBold, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = 6, Parent = content,
    })
    applyTheme(crtHdr, "TextColor3", "accent_glow")
    addTextShadow(crtHdr)

    local crtRow = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1, LayoutOrder = 7, Parent = content,
    })
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
        Parent = crtRow,
    })

    local nameInputWrap = mk("Frame", {
        Size = UDim2.new(1, -90, 1, 0), BackgroundColor3 = Theme.bg_element,
        BorderSizePixel = 2, BorderColor3 = Theme.border, LayoutOrder = 1,
        Parent = crtRow,
    })
    applyTheme(nameInputWrap, "BackgroundColor3", "bg_element")
    applyTheme(nameInputWrap, "BorderColor3", "border")
    local crtStroke = addStroke(nameInputWrap, "outline", 1)

    local nameInput = mk("TextBox", {
        Size = UDim2.new(1, -8, 1, 0), Position = UDim2.fromOffset(4, 0),
        BackgroundTransparency = 1, Text = "",
        PlaceholderText = "filename (no extension)...",
        PlaceholderColor3 = Theme.txt_dim,
        TextColor3 = Theme.txt, FontFace = UIFont, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false, Parent = nameInputWrap,
    })
    nameInput.Focused:Connect(function() tw(crtStroke, {Color = Theme.accent, Transparency = 0.3}) end)
    nameInput.FocusLost:Connect(function() tw(crtStroke, {Color = Theme.outline, Transparency = 0}) end)

    local crtBtn = mk("TextButton", {
        Size = UDim2.fromOffset(86, 22), BackgroundColor3 = Theme.bg_element,
        BorderSizePixel = 2, BorderColor3 = Theme.border,
        Text = "", AutoButtonColor = false, LayoutOrder = 2, Parent = crtRow,
    })
    applyTheme(crtBtn, "BackgroundColor3", "bg_element")
    applyTheme(crtBtn, "BorderColor3", "border")
    addStroke(crtBtn, "outline", 1)
    addVertGradient(crtBtn)
    local crtBtnLbl = mk("TextLabel", {
        Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1,
        Text = "Create", TextColor3 = Theme.txt,
        FontFace = UIFont, TextSize = 11, Parent = crtBtn,
    })
    addTextShadow(crtBtnLbl)
    crtBtn.MouseEnter:Connect(function()
        tw(crtBtn, {BackgroundColor3 = Theme.bg_hover}); tw(crtBtnLbl, {TextColor3 = Theme.accent})
    end)
    crtBtn.MouseLeave:Connect(function()
        tw(crtBtn, {BackgroundColor3 = Theme.bg_element}); tw(crtBtnLbl, {TextColor3 = Theme.txt})
    end)
    crtBtn.MouseButton1Click:Connect(function()
        local n = nameInput.Text
        if not n or #n == 0 then ConsoleMessage("No filename specified"); return end
        local newPath = FolderPath .. "\\" .. n .. ".json"
        pcall(function() writefile(newPath, ReplayFileBeginning .. ReplayFileEnding) end)
        ConsoleMessage("Created: " .. newPath)
        nameInput.Text = ""
        refreshList()
    end)

    -- Erase + Open Folder row
    local extHdr = mk("TextLabel", {
        Size = UDim2.new(1, 0, 0, 14),
        BackgroundTransparency = 1,
        Text = "EXTRA", TextColor3 = Theme.accent_glow,
        FontFace = UIFontBold, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        LayoutOrder = 8, Parent = content,
    })
    applyTheme(extHdr, "TextColor3", "accent_glow")
    addTextShadow(extHdr)

    local extRow = mk("Frame", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1, LayoutOrder = 9, Parent = content,
    })
    mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
        HorizontalFlex = Enum.UIFlexAlignment.Fill,
        Parent = extRow,
    })
    makeFlexBtn(extRow, "Copy Path", function()
        if setclipboard then setclipboard(FolderPath); ConsoleMessage("Copied folder path") end
    end).Size = UDim2.new(0.5, -2, 1, 0)
    makeFlexBtn(extRow, "Erase Current", function()
        pcall(function() writefile(ReplayPath, ReplayFileBeginning) end)
        ReplayTable = {}; ReplayNeedsReload = false; LastLoadedPath = ReplayPath
        ConsoleMessage("Erased: " .. ReplayPath)
    end).Size = UDim2.new(0.5, -2, 1, 0)

    -- Update curLbl when ReplayPath changes
    task.spawn(function()
        local last = ReplayPath
        while task.wait(0.5) do
            if ReplayPath ~= last then
                last = ReplayPath
                curLbl.Text = "Current: " .. tostring(ReplayPath)
                refreshList()
            end
        end
    end)

    refreshList()
end

-- ══════════════════════════════════════════════════════════════════════════════
--  BUILD THE UI
-- ══════════════════════════════════════════════════════════════════════════════

local controlsPage = addTab("controls")
local physicsPage  = addTab("physics")
local visualsPage  = addTab("visuals")
local consolePage  = addTab("console")
local settingsPage = addTab("settings")

-- ══════════════════ CONTROLS TAB (two columns) ══════════════════
do
local ctrlLeft  = addColumn(controlsPage)
local ctrlRight = addColumn(controlsPage)

-- LEFT column: info + controls
local infoSec = addSection(ctrlLeft, "info")
RecordedFramesLabel    = addLabel(infoSec, "Frames: 0")
PressedKeysLabel       = addLabel(infoSec, "Pressed keys: |")
WritingPressedKeysLabel = addLabel(infoSec, "Writing Pressed keys: |")

do
    local _cfLbl = mk("TextLabel", {
        Size=UDim2.new(1,0,0,14), BackgroundTransparency=1,
        Text="Status: Idle", TextColor3=Theme.txt,
        FontFace=UIFontBold, TextSize=11, TextXAlignment=Enum.TextXAlignment.Left,
        Parent=infoSec,
    })
    addTextShadow(_cfLbl)
    ColorCodeFrame = {}
    setmetatable(ColorCodeFrame, {
        __newindex = function(_, k, v)
            if k == "Text" then
                _cfLbl.Text = v
                local sub = tostring(v):gsub("^Status: ", "")
                StatusText.Text = sub
            elseif k == "TextColor3" then
                _cfLbl.TextColor3 = v
                StatusText.TextColor3 = v
                StatusDot.BackgroundColor3 = v
            end
        end,
        __index = function(_, k)
            if k == "Text" then return _cfLbl.Text end
            if k == "TextColor3" then return _cfLbl.TextColor3 end
            return nil
        end,
    })
end

ConnectedLabel = addLabel(infoSec, "AHK folder not found")
do
    local _cpBtn = addButton(infoSec, "Place id: "..tostring(PlaceId), function()
        if setclipboard then setclipboard(tostring(PlaceId)) end
    end)
    CurrentPlaceIdButton = _cpBtn
end
local _currentFileLbl = addLabel(infoSec, "Current File: ")
CurrentFile = _currentFileLbl

-- Controls section
local ctrlSec = addSection(ctrlLeft, "controls")
local FrozenRow = addRow(ctrlSec)
FrozenRow:Button({Text = "Frozen -> Idle", Callback = function() IdleButton_MouseButton1Click() end})
Frozenkeybind = FrozenRow:Keybind({Label = "keybind", Value = Enum.KeyCode.M})

do -- playback control rows (own scope: the main chunk is close to the 200 local limit)
-- one scoped row handle per row: this chunk sits at the 200-local ceiling, so no handle may
-- outlive its row
do
	local Row = addRow(ctrlSec)
	Row:Button({Text = "Pause / Resume", Callback = function() PlaybackCtl.Toggle() end})
	Pausekeybind = Row:Keybind({Label = "keybind", Value = Enum.KeyCode.R})
end

do
	local Row = addRow(ctrlSec)
	Row:Button({Text = "Unpause", Callback = function() PlaybackCtl.Step() end})
	Unpausekeybind = Row:Keybind({Label = "keybind", Value = Enum.KeyCode.Y})
end

do
	local Row = addRow(ctrlSec)
	Row:Button({Text = "Unpause & Record", Callback = function() PlaybackCtl.TakeOver() end})
	Takeoverkeybind = Row:Keybind({Label = "keybind", Value = Enum.KeyCode.X})
end

do
	local Row = addRow(ctrlSec)
	Row:Button({Text = "Look around (paused)", Callback = function() PlaybackCtl.ToggleLookAround() end})
	LookAroundkeybind = Row:Keybind({Label = "keybind", Value = Enum.KeyCode.C})
end

addRow(ctrlSec):Button({Text = "Optimize replay", Callback = function() PlaybackCtl.Optimize() end})
addRow(ctrlSec):Button({Text = "Ultra optimize replay", Callback = function() PlaybackCtl.UltraOptimize() end})
addRow(ctrlSec):Button({Text = "Optimize replay speed", Callback = function() PlaybackCtl.RetimeReplay() end})
do
	local FpsRow = addRow(ctrlSec)
	FpsRow:Button({Text = "FPS converter", Callback = function() PlaybackCtl.ConvertFPS() end})
	FpsRow:Slider({
		Label = "fps",
		Min = 60, Max = 240,
		Default = math.clamp(math.floor(FPS + 0.5), 60, 240),
		Callback = function(self) PlaybackCtl.ConvertFpsTarget = math.floor(self.Value + 0.5) end,
	})
end
addRow(ctrlSec):Button({Text = "Realistic replay", Callback = function() PlaybackCtl.RealisticReplay() end})
do
	local SmoothRow = addRow(ctrlSec)
	SmoothRow:Button({Text = "Smooth out replay", Callback = function() PlaybackCtl.SmoothReplay() end})
	SmoothRow:Slider({
		Label = "smooth",
		Min = 1, Max = 10, Default = PlaybackCtl.SmoothStrength or 5,
		Callback = function(self) PlaybackCtl.SmoothStrength = self.Value end,
	})
end
end

IgnoreGameProcessedButton = addCheckbox(ctrlSec, {
    Label = "Ignore Game Processed", Default = false,
    Callback = function() IgnoreGameProcessed = not IgnoreGameProcessed end,
})


KeyboardOverlayThemes = {
    ["Default"] = {
        size = UDim2.fromOffset(280, 195),
        create = function(container)
            -- Container styling to match main UI
            container.BackgroundColor3 = Color3.fromRGB(15, 15, 21)
            container.BackgroundTransparency = 0.15
            container.BorderSizePixel = 2
            container.BorderColor3 = Color3.fromRGB(8, 8, 12)

            local containerStroke = Instance.new("UIStroke")
            containerStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
            containerStroke.LineJoinMode = Enum.LineJoinMode.Miter
            containerStroke.Color = Color3.fromRGB(30, 30, 40)
            containerStroke.Thickness = 1
            containerStroke.Parent = container

            -- Top accent line (matches main UI)
            local accentLine = Instance.new("Frame")
            accentLine.Size = UDim2.new(1, 0, 0, 2)
            accentLine.Position = UDim2.fromOffset(0, 0)
            accentLine.BackgroundColor3 = Color3.fromRGB(100, 175, 255)
            accentLine.BorderSizePixel = 0
            accentLine.ZIndex = 3
            accentLine.Parent = container

            local accentGrad = Instance.new("UIGradient")
            accentGrad.Rotation = 90
            accentGrad.Color = ColorSequence.new{
                ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(65, 65, 65)),
            }
            accentGrad.Parent = accentLine

            -- Title
            local titleLbl = Instance.new("TextLabel")
            titleLbl.Size = UDim2.new(1, 0, 0, 16)
            titleLbl.Position = UDim2.fromOffset(0, 4)
            titleLbl.BackgroundTransparency = 1
            titleLbl.Text = "INPUTS"
            titleLbl.TextColor3 = Color3.fromRGB(100, 175, 255)
            titleLbl.Font = Enum.Font.GothamBold
            titleLbl.TextSize = 10
            titleLbl.TextXAlignment = Enum.TextXAlignment.Center
            titleLbl.Parent = container

            local titleShadow = Instance.new("UIStroke")
            titleShadow.LineJoinMode = Enum.LineJoinMode.Miter
            titleShadow.Color = Color3.fromRGB(0, 0, 0)
            titleShadow.Thickness = 1
            titleShadow.Parent = titleLbl

            local function createKey(name, position, size, displayText)
                local key = Instance.new("TextLabel")
                key.Name = name
                key.Size = size
                key.Position = position
                key.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
                key.BorderSizePixel = 2
                key.BorderColor3 = Color3.fromRGB(8, 8, 12)
                key.Text = displayText or name
                key.TextColor3 = Color3.fromRGB(215, 215, 228)
                key.TextSize = (size.X.Offset > 70) and 11 or 14
                key.Font = Enum.Font.GothamBold
                key.Parent = container

                local keyStroke = Instance.new("UIStroke")
                keyStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
                keyStroke.LineJoinMode = Enum.LineJoinMode.Miter
                keyStroke.Color = Color3.fromRGB(30, 30, 40)
                keyStroke.Thickness = 1
                keyStroke.Parent = key

                local keyGrad = Instance.new("UIGradient")
                keyGrad.Rotation = 90
                keyGrad.Color = ColorSequence.new{
                    ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
                    ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 140, 140)),
                }
                keyGrad.Parent = key

                local txtShadow = Instance.new("UIStroke")
                txtShadow.LineJoinMode = Enum.LineJoinMode.Miter
                txtShadow.Color = Color3.fromRGB(0, 0, 0)
                txtShadow.Thickness = 1
                txtShadow.Parent = key

                return key
            end

            local ks = UDim2.fromOffset(40, 40)
            local W  = createKey("W", UDim2.fromOffset(110, 28), ks)
            local A  = createKey("A", UDim2.fromOffset(60, 78), ks)
            local S  = createKey("S", UDim2.fromOffset(110, 78), ks)
            local D  = createKey("D", UDim2.fromOffset(160, 78), ks)
            local CL = createKey("CapsLock", UDim2.fromOffset(8, 78), UDim2.fromOffset(45, 40), "CAPS")
            CL.TextSize = 10
            local SH = createKey("LeftShift", UDim2.fromOffset(8, 128), UDim2.fromOffset(45, 40), "SHFT")
            SH.TextSize = 10
            local SL = createKey("Slash", UDim2.fromOffset(160, 28), UDim2.fromOffset(40, 40), "/")
            local SP = createKey("Space", UDim2.fromOffset(60, 128), UDim2.fromOffset(190, 40), "SPACE")
            SP.TextSize = 11

            return {W=W, A=A, S=S, D=D, LeftShift=SH, RightShift=SH, Space=SP, CapsLock=CL, Slash=SL}
        end,
        updateColors = function(keyFrame, state)
            if state == "writing" then
                keyFrame.BackgroundColor3 = Color3.fromRGB(220, 200, 60)
                keyFrame.TextColor3 = Color3.fromRGB(20, 20, 20)
            elseif state == "pressed" then
                keyFrame.BackgroundColor3 = Color3.fromRGB(100, 175, 255)
                keyFrame.TextColor3 = Color3.fromRGB(255, 255, 255)
            else
                keyFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
                keyFrame.TextColor3 = Color3.fromRGB(215, 215, 228)
            end
        end,
    },
}

currentTheme = "Default"

KeyboardOverlay = addCheckbox(ctrlSec, {
    Label = "Keyboard Overlay", Default = false,
    Callback = function(self)
        local enabled = self.Value
        if enabled then
            getgenv().KeyboardOverlayEnabled = true
            if not getgenv().KeyboardOverlayGui then
                local overlayGui = Instance.new("ScreenGui")
                overlayGui.Name="KeyboardOverlay"; overlayGui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
                overlayGui.ResetOnSpawn=false; overlayGui.DisplayOrder=9999; overlayGui.Parent=Player.PlayerGui
                local container = Instance.new("Frame")
                container.Name="Container"; container.Size=KeyboardOverlayThemes[currentTheme].size
                container.Position=UDim2.new(0,20,1,-container.Size.Y.Offset-20)
                container.BackgroundTransparency=1; container.BorderSizePixel=0; container.Parent=overlayGui
                local keys = KeyboardOverlayThemes[currentTheme].create(container)
                getgenv().KeyboardOverlayGui = overlayGui
                getgenv().KeyboardOverlayContainer = container
                getgenv().KeyboardOverlayKeys = keys
            else getgenv().KeyboardOverlayGui.Enabled = true end
        else
            getgenv().KeyboardOverlayEnabled = false
            if getgenv().KeyboardOverlayGui then getgenv().KeyboardOverlayGui.Enabled = false end
        end
    end,
})

KeyboardThemeCombo = addCombo(ctrlSec, {
    Text = "Overlay Theme", Placeholder = "Default",
    GetItems = function() return {"Default"} end,
    Callback = function(_, sel)
        if sel and KeyboardOverlayThemes[sel] then
            currentTheme = sel; ConsoleMessage("Keyboard theme changed to: "..sel)
        end
    end,
})

addCheckbox(ctrlSec, {
    Label = "Frame interpolation", Default = true,
    Callback = function(self)
        PlaybackCtl.FrameInterp = self.Value
        -- a fresh blend starts from the frame currently on screen, not a stale playhead
        PlaybackCtl.RenderPos = nil
        PlaybackCtl.RenderAt = nil
    end,
})

movecameraonfroze = addCheckbox(ctrlSec, {Label = "Move camera while frozen", Default = false})
local ReadRow = addRow(ctrlSec)
ReadRow:Button({Text = "Read", Callback = function() ReadButton_MouseButton1Click() end})
Readkeybind = ReadRow:Keybind({Label = "keybind", Value = Enum.KeyCode.Z})

local AbortRow = addRow(ctrlSec)
AbortRow:Button({Text = "Abort", Callback = function() StopReading() end})
Abortkeybind = AbortRow:Keybind({Label = "keybind", Value = Enum.KeyCode.L})

-- RIGHT column: keybinds + utility + file management
local keybindsSec = addSection(ctrlRight, "keybinds")
Hideuikeybind              = addKeybind(keybindsSec, {Label = "Hide UI",                  Value = Enum.KeyCode.U})
Recordkeybind              = addKeybind(keybindsSec, {Label = "Record / Freeze",          Value = Enum.KeyCode.E})
Goforwardkeybind           = addKeybind(keybindsSec, {Label = "Go forward",               Value = Enum.KeyCode.T})
Gobackwardskeybind         = addKeybind(keybindsSec, {Label = "Go backwards",             Value = Enum.KeyCode.Q})
Frameadvanceforwardkeybind = addKeybind(keybindsSec, {Label = "Frame advance forward",    Value = Enum.KeyCode.G})
Frameadvancebackwardskeybind = addKeybind(keybindsSec, {Label = "Frame advance backward", Value = Enum.KeyCode.F})
Savekeybind                = addKeybind(keybindsSec, {Label = "Save to file",             Value = Enum.KeyCode.P})

local utilSec = addSection(ctrlRight, "utility")
addButton(utilSec, "Rejoin", function()
    ConsoleMessage("Rejoining...")
    SaveToFile()
    task.wait(0.5)
    if #game.Players:GetPlayers() <= 1 then
        game.Players.LocalPlayer:Kick("\nRejoining...")
        task.wait()
        game:GetService("TeleportService"):Teleport(game.PlaceId, game.Players.LocalPlayer)
    else
        game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId, game.Players.LocalPlayer)
    end
end)

FPSTextbox = addTextbox(utilSec, {
    Label = "FPS Cap", Value = tostring(FPS), Placeholder = "Enter FPS...",
    Callback = function(_, value)
        local newFPS = tonumber(value)
        if newFPS and newFPS > 0 and newFPS <= 1000 then
            FPS = newFPS
            if setfpscap then setfpscap(FPS) end
            ConsoleMessage("FPS set to "..tostring(FPS))
        end
    end,
})

TeleportTextbox = addTextbox(utilSec, {Label = "Teleport PlaceId", Placeholder = "Enter PlaceId..."})
addButton(utilSec, "Teleport", function()
    local placeId = tonumber(TeleportTextbox.Value)
    if placeId and placeId > 0 then
        ConsoleMessage("Teleporting to: "..tostring(placeId))
        SaveToFile(); task.wait(0.5)
        pcall(function() game:GetService("TeleportService"):Teleport(placeId, game.Players.LocalPlayer) end)
    else ConsoleMessage("Invalid PlaceId") end
end)

end

-- ══════════════════ PHYSICS TAB (two columns) ══════════════════
do
local physLeft  = addColumn(physicsPage)
local physRight = addColumn(physicsPage)

local physSec = addSection(physLeft, "physics modifiers")
WalkSpeedTextbox = addTextbox(physSec, {Label = "WalkSpeed", Value = "16", Placeholder = "16",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and Character and Character:FindFirstChild("Humanoid") then
            Character.Humanoid.WalkSpeed = n; DefaultWalkSpeed = n
        end
    end})
JumpPowerTextbox = addTextbox(physSec, {Label = "JumpPower", Value = "50", Placeholder = "50",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and Character and Character:FindFirstChild("Humanoid") then
            Character.Humanoid.JumpPower = n; DefaultJumpPower = n
        end
    end})
GravityTextbox = addTextbox(physSec, {Label = "Gravity", Value = "196.2", Placeholder = "196.2",
    Callback = function(_, v)
        local n = tonumber(v)
        if n then DefaultGravity = n; if not Reading and not Frozen then workspace.Gravity = n end end
    end})
FrictionTextbox = addTextbox(physSec, {Label = "Friction", Value = "0.3", Placeholder = "0.3",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and Character and Character:FindFirstChild("HumanoidRootPart") then
            local hrp = Character.HumanoidRootPart
            local cur = hrp.CustomPhysicalProperties
            hrp.CustomPhysicalProperties = PhysicalProperties.new(cur and cur.Density or 0.7, n, cur and cur.Elasticity or 0.5, 1, 1)
        end
    end})
DensityTextbox = addTextbox(physSec, {Label = "Density", Value = "0.7", Placeholder = "0.7",
    Callback = function(_, v)
        local n = tonumber(v)
        if n and Character and Character:FindFirstChild("HumanoidRootPart") then
            local hrp = Character.HumanoidRootPart
            local cur = hrp.CustomPhysicalProperties
            hrp.CustomPhysicalProperties = PhysicalProperties.new(n, cur and cur.Friction or 0.3, cur and cur.Elasticity or 0.5, 1, 1)
        end
    end})

local physActSec = addSection(physRight, "actions")
addButton(physActSec, "Apply Physics", function()
    local ws = tonumber(WalkSpeedTextbox.Value)
    local jp = tonumber(JumpPowerTextbox.Value)
    local grav = tonumber(GravityTextbox.Value)
    local fric = tonumber(FrictionTextbox.Value)
    local den = tonumber(DensityTextbox.Value)
    if Character then
        local hum = Character:FindFirstChild("Humanoid")
        local hrp = Character:FindFirstChild("HumanoidRootPart")
        if hum then
            if ws then hum.WalkSpeed = ws; DefaultWalkSpeed = ws end
            if jp then hum.JumpPower = jp; DefaultJumpPower = jp end
        end
        if grav then DefaultGravity = grav; if not Reading and not Frozen then workspace.Gravity = grav end end
        if hrp and fric and den then
            hrp.CustomPhysicalProperties = PhysicalProperties.new(den, fric, 0.5, 1, 1)
        end
    end
    ConsoleMessage("Physics applied")
end)
addButton(physActSec, "Reset Physics", function()
    if Character then
        local hum = Character:FindFirstChild("Humanoid")
        local hrp = Character:FindFirstChild("HumanoidRootPart")
        if hum then hum.WalkSpeed=16; hum.JumpPower=50; DefaultWalkSpeed=16; DefaultJumpPower=50 end
        workspace.Gravity=196.2; DefaultGravity=196.2
        if hrp then hrp.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.5, 1, 1) end
    end
    WalkSpeedTextbox:SetValue("16"); JumpPowerTextbox:SetValue("50")
    GravityTextbox:SetValue("196.2"); FrictionTextbox:SetValue("0.3"); DensityTextbox:SetValue("0.7")
    ConsoleMessage("Physics reset")
end)

;(function() -- speed hack section (own scope keeps the main chunk under the local limit)
	local Sec = addSection(physRight, "speed hack")
	local Wrap, Track, Fill, Knob, ValueLabel, Textbox
	local Dragging = false

	local function SetSpeed(Value)
		Value = math.clamp(tonumber(Value) or 0.5, 0.1, 1)
		Value = math.floor(Value * 100 + 0.5) / 100
		SpeedHack.Speed = Value
		local Alpha = (Value - 0.1) / 0.9
		local Text = string.format("%.2f", Value)
		if Fill then Fill.Size = UDim2.new(Alpha, 0, 1, 0) end
		if Knob then Knob.Position = UDim2.new(Alpha, -5, 0.5, -5) end
		if ValueLabel then ValueLabel.Text = Text end
		if Textbox and Textbox.Value ~= Text then Textbox:SetValue(Text) end
	end

	addCheckbox(Sec, {Label = "Enable speed hack", Default = SpeedHack.Enabled, Callback = function(self)
		SpeedHack.Enabled = self.Value == true
		if Wrap then Wrap.Visible = SpeedHack.Enabled end
		if SpeedHack.Enabled then
			ConsoleMessage("Speed hack on: "..string.format("%.2f", SpeedHack.Speed).."x (camera stays normal)")
		end
	end})

	Wrap = mk("Frame", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1, BorderSizePixel = 0, Visible = SpeedHack.Enabled, Parent = Sec})
	mk("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = Wrap})

	local Row = mk("Frame", {Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, BorderSizePixel = 0, Parent = Wrap})
	mk("TextLabel", {Size = UDim2.new(0.38, 0, 0, 16), BackgroundTransparency = 1, Text = "Speed",
		TextColor3 = Theme.txt_muted, FontFace = UIFont, TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left, Parent = Row})
	ValueLabel = mk("TextLabel", {Size = UDim2.new(0.62, 0, 0, 16), Position = UDim2.fromScale(0.38, 0),
		BackgroundTransparency = 1, Text = string.format("%.2f", SpeedHack.Speed),
		TextColor3 = Theme.accent, FontFace = UIFont, TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right, Parent = Row})
	applyTheme(ValueLabel, "TextColor3", "accent")

	Track = mk("Frame", {Size = UDim2.new(1, 0, 0, 6), Position = UDim2.fromOffset(0, 22),
		BackgroundColor3 = Theme.bg_deep, BorderSizePixel = 2, BorderColor3 = Theme.border,
		Active = true, Parent = Row})
	applyTheme(Track, "BackgroundColor3", "bg_deep")
	applyTheme(Track, "BorderColor3", "border")
	addStroke(Track, "outline", 1)

	Fill = mk("Frame", {Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Theme.accent_dim,
		BorderSizePixel = 0, Parent = Track})
	applyTheme(Fill, "BackgroundColor3", "accent_dim")

	Knob = mk("Frame", {Size = UDim2.fromOffset(10, 10), Position = UDim2.new(0, -5, 0.5, -5),
		BackgroundColor3 = Theme.accent, BorderSizePixel = 2, BorderColor3 = Theme.border, Parent = Track})
	applyTheme(Knob, "BackgroundColor3", "accent")
	applyTheme(Knob, "BorderColor3", "border")
	addStroke(Knob, "outline", 1)

	local function SetFromPointer(X)
		local Width = math.max(1, Track.AbsoluteSize.X)
		SetSpeed(0.1 + math.clamp((X - Track.AbsolutePosition.X) / Width, 0, 1) * 0.9)
	end

	Track.InputBegan:Connect(function(Input)
		if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
			Dragging = true
			SetFromPointer(Input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(Input)
		if Dragging and (Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch) then
			SetFromPointer(Input.Position.X)
		end
	end)
	-- stop dragging even when the button is released outside of the slider
	UserInputService.InputEnded:Connect(function(Input)
		if Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch then
			Dragging = false
		end
	end)

	Textbox = addTextbox(Wrap, {Label = "Speed (0.10 - 1.00)", Value = string.format("%.2f", SpeedHack.Speed),
		Placeholder = "0.50", Callback = function(_, Text)
			if tonumber(Text) then
				SetSpeed(Text)
			else
				Textbox:SetValue(string.format("%.2f", SpeedHack.Speed))
			end
		end})

	SetSpeed(SpeedHack.Speed)
end)()

end

-- ══════════════════ VISUALS TAB (two columns) ══════════════════
do
local visLeft  = addColumn(visualsPage)
local visRight = addColumn(visualsPage)

local visSec = addSection(visLeft, "hud")
addCheckbox(visSec, {Label = "Stats HUD", Default = false, Callback = function(self)
    StatsHudEnabled = self.Value
    if StatsHudEnabled then createStatsHud() else destroyStatsHud() end
end})

local effectsSec = addSection(visLeft, "effects")
DisableParticles = addCheckbox(effectsSec, {
    Label = "Disable Particle Emitters", Default = false,
    Callback = function(self)
        for _, obj in pairs(workspace:GetDescendants()) do
            if obj:IsA("ParticleEmitter") then obj.Enabled = not self.Value end
        end
    end,
})
DisableLighting = addCheckbox(effectsSec, {
    Label = "Disable Lighting Effects", Default = false,
    Callback = function(self)
        local L = game:GetService("Lighting")
        if self.Value then
            if not getgenv().OriginalLightingSettings then
                getgenv().OriginalLightingSettings = {
                    Ambient=L.Ambient, Brightness=L.Brightness,
                    GlobalShadows=L.GlobalShadows, ClockTime=L.ClockTime,
                }
            end
            L.Ambient=Color3.fromRGB(255,255,255); L.Brightness=2
            L.GlobalShadows=false; L.ClockTime=14
            for _, obj in pairs(L:GetChildren()) do
                if obj:IsA("BloomEffect") or obj:IsA("BlurEffect") or obj:IsA("ColorCorrectionEffect")
                    or obj:IsA("SunRaysEffect") or obj:IsA("DepthOfFieldEffect") then
                    if obj ~= TasBlur then obj.Enabled = false end
                end
            end
        else
            if getgenv().OriginalLightingSettings then
                for k, v in pairs(getgenv().OriginalLightingSettings) do L[k] = v end
            end
            for _, obj in pairs(L:GetChildren()) do
                if obj:IsA("BloomEffect") or obj:IsA("BlurEffect") or obj:IsA("ColorCorrectionEffect")
                    or obj:IsA("SunRaysEffect") or obj:IsA("DepthOfFieldEffect") then
                    if obj ~= TasBlur then obj.Enabled = true end
                end
            end
        end
    end,
})
MotionBlurToggle = addCheckbox(effectsSec, {
    Label = "Motion Blur", Default = false,
    Callback = function(self)
        local L = game:GetService("Lighting")
        if self.Value then
            if not L:FindFirstChild("TasabilityMotionBlur") then
                local blur = Instance.new("BlurEffect"); blur.Name="TasabilityMotionBlur"; blur.Size=3; blur.Parent=L
            end
        else
            local blur = L:FindFirstChild("TasabilityMotionBlur")
            if blur then blur:Destroy() end
        end
    end,
})

local tracerSec = addSection(visRight, "trajectory tracer")
addCheckbox(tracerSec, {Label = "Trajectory Tracer", Default = false, Callback = function(self)
    TracerEnabled = self.Value
    if not TracerEnabled then clearTracerLines() end
end})
addTextbox(tracerSec, {Label = "Lookahead (s)", Value = tostring(TRACER_LOOKAHEAD),
    Callback = function(_, v)
        local n = tonumber(v)
        if n and n > 0 and n <= 5 then TRACER_LOOKAHEAD = n end
    end})
addTextbox(tracerSec, {Label = "Steps", Value = tostring(TRACER_STEPS),
    Callback = function(_, v)
        local n = tonumber(v)
        if n and n > 0 and n <= 100 then TRACER_STEPS = math.floor(n); clearTracerLines() end
    end})

local soundSec = addSection(visRight, "input sounds")
addCheckbox(soundSec, {Label = "Keyboard sounds", Default = true, Callback = function(self)
    PlaybackCtl.KeySounds = self.Value
end})
addCheckbox(soundSec, {Label = "Mouse sounds", Default = true, Callback = function(self)
    PlaybackCtl.MouseSounds = self.Value
end})
addSlider(soundSec, {Label = "Loudness", Min = 0, Max = 100, Default = 60, Callback = function(self)
    PlaybackCtl.ClickLoudness = self.Value / 100
end})
addCombo(soundSec, {
    Text = "Keyboard set", Placeholder = "Mechanical mix",
    GetItems = function() return {"Mechanical mix", "Razer Huntsman", "Cherry MX Browns", "Pro SFX click", "Jade Pro"} end,
    Callback = function(_, Choice)
        if PlaybackCtl.SetKeySet then PlaybackCtl.SetKeySet(tostring(Choice)) end
    end,
})
addCombo(soundSec, {
    Text = "Mouse set", Placeholder = "G302 pair",
    GetItems = function() return {"G302 pair", "Mouse Down", "mouse_down"} end,
    Callback = function(_, Choice)
        if PlaybackCtl.SetMouseSet then PlaybackCtl.SetMouseSet(tostring(Choice)) end
    end,
})

end

-- Input sounds ────────────────────────────────────────
-- Playback drives the recorded inputs itself, so nothing reaches the speakers for them: the
-- real keyboard's noise is the player's, not the replay's. These voices put it back. Every
-- keydown picks its sample and pitch off the key name, so a given key always has its own
-- timbre and two keys never share one, with a small per-press jitter on top - no two presses
-- come out identical. Each key also carries the gain and pitch its physical cap would have:
-- the wide keys land harder and lower, the lower letter rows land softer, so Space reads
-- above W and W above X instead of the whole board sitting at one level. Mouse clicks are
-- down-only: b1 and b2 are different assets. Loudness is the shared trim. Voices exist in
-- small pools so fast typing overlaps instead of cutting.
do
    -- Own function scope on purpose: the main chunk already carries most of Luau's 200 active
    -- locals, and the helper locals below declared straight into it would cross the ceiling
    -- while the block runs.
    local function InitInputSounds()
        local SoundService = game:GetService("SoundService")

        -- Mechanical keyboard presses, one timbre per pool so a given key always sounds like
        -- itself: Razer Huntsman Mini (clicky optical), Cherry MX Browns (tactile thock), and
        -- the Pro Sound Effects mechanical click. All three are public Creator Store audio -
        -- AxXBaconTopXxA, Ayan21345, ProSoundEffects. The input-sounds dropdowns pick a set.
        local KeySets = {
            ["Mechanical mix"] = {
                "rbxassetid://8501176679",
                "rbxassetid://8350910210",
                "rbxassetid://9116158538",
            },
            ["Razer Huntsman"]   = { "rbxassetid://8501176679" },
            ["Cherry MX Browns"] = { "rbxassetid://8350910210" },
            ["Pro SFX click"]    = { "rbxassetid://9116158538" },
            ["Jade Pro"]         = { "rbxassetid://104798957330818" },
        }
        -- Mouse down-clicks aimed at the G302's Omron snap: Wrathoxic's Mouse Down and The_Sink's
        -- mouse_down. Paired by default so the two buttons are distinct recordings.
        local MouseSets = {
            ["G302 pair"] = { Left = "rbxassetid://5592577559", Right = "rbxassetid://6976440355" },
            ["Mouse Down"] = { Left = "rbxassetid://5592577559", Right = "rbxassetid://5592577559" },
            ["mouse_down"] = { Left = "rbxassetid://6976440355", Right = "rbxassetid://6976440355" },
        }
        local KeyAssets = KeySets["Mechanical mix"]
        -- The classic clickfast transient: short, sharp, and shipped with the client, so every
        -- key still lands a tick underneath its sample even if an upload cannot be played.
        local TickAsset = "rbxassetid://12221976"
        local LeftAsset  = MouseSets["G302 pair"].Left
        local RightAsset = MouseSets["G302 pair"].Right

        -- One gain per physical key. The wide caps carry more mass and land harder, the lower
        -- letter rows sit further from the board's pivot and read softer, and the number row
        -- sits between the rows. Space above W above X is the placement, not a random draw;
        -- each key still keeps its own pool timbre and a little press-to-press scatter on top.
        local KeyGain = {
            Space = 1.42,
            Return = 1.24, Backspace = 1.20, Tab = 1.16, CapsLock = 1.14,
            LeftShift = 1.18, RightShift = 1.18,
            LeftControl = 1.14, RightControl = 1.14,
            LeftAlt = 1.12, RightAlt = 1.12,
            Escape = 1.10, Delete = 1.08, Insert = 1.06,
            Home = 1.05, End = 1.05, PageUp = 1.05, PageDown = 1.05,
            Up = 1.02, Down = 1.02, Left = 1.02, Right = 1.02,
        }
        for _, Name in ipairs({
            "Q","W","E","R","T","Y","U","I","O","P",
            "One","Two","Three","Four","Five","Six","Seven","Eight","Nine","Zero",
        }) do KeyGain[Name] = 1.00 end
        for _, Name in ipairs({"A","S","D","F","G","H","J","K","L"}) do
            KeyGain[Name] = 0.95
        end
        for _, Name in ipairs({"Z","X","C","V","B","N","M"}) do
            KeyGain[Name] = 0.85
        end
        for _, Name in ipairs({
            "Minus","Equals","LeftBracket","RightBracket","Semicolon","Quote",
            "Comma","Period","Slash","BackSlash","Grave",
        }) do KeyGain[Name] = 0.90 end

        local function NewVoice(Asset)
            local S = Instance.new("Sound")
            S.Name = "TasInputSound"
            S.SoundId = Asset
            S.Volume = 0
            S.Parent = SoundService
            return S
        end

        -- a previous run of this script leaves its voices behind: they are ours, so clear them
        for _, Old in ipairs(SoundService:GetChildren()) do
            if Old:IsA("Sound") and Old.Name == "TasInputSound" then Old:Destroy() end
        end

        local KeyPools, TickVoices, LeftVoices, RightVoices = {}, {}, {}, {}
        for Slot = 1, #KeyAssets do
            KeyPools[Slot] = {}
            for Copy = 1, 3 do
                table.insert(KeyPools[Slot], NewVoice(KeyAssets[Slot]))
            end
        end
        for Copy = 1, 4 do
            table.insert(TickVoices, NewVoice(TickAsset))
            table.insert(LeftVoices, NewVoice(LeftAsset))
            table.insert(RightVoices, NewVoice(RightAsset))
        end

        local SlotCursor, TickCursor, LeftCursor, RightCursor = {0, 0, 0}, 0, 0, 0

        -- The input-sounds dropdowns call these; a switch re-points every voice in the pool, so
        -- the next press plays the new sample without a reload. One generation stamp per kind
        -- keeps the delayed dead-voice sweep from overruling a set the player picked after it
        -- was armed, without letting one kind's pick cancel the other kind's sweep.
        local KeyGeneration, MouseGeneration = 0, 0
        local StartKeyGeneration, StartMouseGeneration = KeyGeneration, MouseGeneration
        PlaybackCtl.SetKeySet = function(Name)
            local Set = KeySets[Name]
            if not Set then return end
            KeyGeneration += 1
            for Slot = 1, #KeyPools do
                local Asset = Set[(Slot - 1) % #Set + 1]
                for _, Voice in ipairs(KeyPools[Slot]) do Voice.SoundId = Asset end
            end
        end
        PlaybackCtl.SetMouseSet = function(Name)
            local Set = MouseSets[Name]
            if not Set then return end
            MouseGeneration += 1
            for _, Voice in ipairs(LeftVoices) do Voice.SoundId = Set.Left end
            for _, Voice in ipairs(RightVoices) do Voice.SoundId = Set.Right end
        end

        -- An uploaded asset can be private since audio privacy: one that never loads would leave
        -- its whole third of the keys silent. After the client has had time to fetch them, any
        -- dead voice is moved onto a sound that is guaranteed public - the Pro Sound Effects key
        -- click for the keys, the classic client click for the left button, and whatever loaded
        -- for the right - so nothing goes quiet.
        local function VoiceDead(Voice)
            local Ok, Loaded = pcall(function() return Voice.Loaded end)
            if not Ok then Ok, Loaded = pcall(function() return Voice.IsLoaded end) end
            return Ok and Loaded == false
        end
        task.delay(4, function()
            if KeyGeneration == StartKeyGeneration then
                for Slot = 1, #KeyPools do
                    local Voices = KeyPools[Slot]
                    local Dead = true
                    for Index = 1, #Voices do
                        if not VoiceDead(Voices[Index]) then Dead = false break end
                    end
                    if Dead then
                        for Index = 1, #Voices do Voices[Index].SoundId = "rbxassetid://9116158538" end
                    end
                end
            end
            if MouseGeneration == StartMouseGeneration then
                local LeftAlive = false
                for Index = 1, #LeftVoices do
                    if VoiceDead(LeftVoices[Index]) then
                        LeftVoices[Index].SoundId = "rbxassetid://12221976"
                    else
                        LeftAlive = true
                    end
                end
                local RightFallback = LeftAlive and LeftAsset or "rbxassetid://12221976"
                for Index = 1, #RightVoices do
                    if VoiceDead(RightVoices[Index]) then
                        RightVoices[Index].SoundId = RightFallback
                    end
                end
            end
        end)

        local function Hash(Text)
            local H = 7
            for Index = 1, #Text do
                H = (H * 31 + string.byte(Text, Index)) % 100003
            end
            return H
        end

        local function TakeVoice(Pool, Cursor)
            Cursor = (Cursor % #Pool) + 1
            return Pool[Cursor], Cursor
        end

        PlaybackCtl.PlayKeySound = function(Key)
            if PlaybackCtl.KeySounds == false then return end
            local Loud = PlaybackCtl.ClickLoudness or 0.6
            if Loud <= 0 then return end
            local Name = tostring(Key)
            local H = Hash(Name)
            local Gain = KeyGain[Name] or 1.00
            -- heavy caps also sit lower: the same sample drops in pitch as the key gets
            -- bigger, which is the part of the spread that reads as location
            local Pitch = 1.04 - math.clamp((Gain - 0.85) / 0.57, 0, 1) * 0.10
            -- sample and pitch belong to the key, so every key has its own sound
            local Slot = (H % #KeyPools) + 1
            local Voice, Cursor = TakeVoice(KeyPools[Slot], SlotCursor[Slot])
            SlotCursor[Slot] = Cursor
            -- press-to-press variation the way a real board spreads its strikes
            local Jitter = (math.random() - 0.5) * 0.03
            Voice.PlaybackSpeed = (0.94 + (H % 13) / 100 + Jitter) * Pitch
            -- the key's placement sets the level before the per-press scatter: Space sits
            -- above W and W above X the way the physical keys do, never a flat mix
            Voice.Volume = math.min(1.6, Loud * Gain * (0.98 + (H % 5) / 100 + math.random() * 0.04))
            Voice.TimePosition = 0
            Voice:Play()

            local Tick, TickAt = TakeVoice(TickVoices, TickCursor)
            TickCursor = TickAt
            Tick.PlaybackSpeed = (1.38 + (H % 17) / 100 + Jitter) * Pitch
            Tick.Volume = math.min(0.5, Loud * Gain * 0.16)
            Tick.TimePosition = 0
            Tick:Play()
        end

        PlaybackCtl.PlayMouseSound = function(Button)
            if PlaybackCtl.MouseSounds == false then return end
            local Loud = PlaybackCtl.ClickLoudness or 0.6
            if Loud <= 0 then return end
            local Right = (Button == 2)
            local Cursor
            local Voice
            if Right then
                Voice, Cursor = TakeVoice(RightVoices, RightCursor)
                RightCursor = Cursor
                Voice.PlaybackSpeed = 0.92 + (math.random() - 0.5) * 0.04
                Voice.Volume = Loud * 0.85
            else
                Voice, Cursor = TakeVoice(LeftVoices, LeftCursor)
                LeftCursor = Cursor
                Voice.PlaybackSpeed = 1.0 + (math.random() - 0.5) * 0.04
                Voice.Volume = Loud
            end
            Voice.TimePosition = 0
            Voice:Play()
        end

        PlaybackCtl.KeySounds = PlaybackCtl.KeySounds ~= false
        PlaybackCtl.MouseSounds = PlaybackCtl.MouseSounds ~= false
        PlaybackCtl.ClickLoudness = PlaybackCtl.ClickLoudness or 0.6
    end
    InitInputSounds()
end

-- ══════════════════ CONSOLE TAB (full-width) ══════════════════
do
local _console, _consoleInput = makeConsole(consolePage)
console = _console
ConsoleInput = _consoleInput

end

-- ══════════════════ SETTINGS TAB (two columns) ══════════════════
do
local setLeft  = addColumn(settingsPage)
local setRight = addColumn(settingsPage)

local themeSec = addSection(setLeft, "theme")
addCombo(themeSec, {
    Text = "Theme Preset", Placeholder = "Midnight Blue",
    GetItems = function()
        local names = {}
        for k in pairs(ThemePresets) do table.insert(names, k) end
        table.sort(names)
        return names
    end,
    Callback = function(_, presetName)
        if presetName then setThemePreset(presetName); ConsoleMessage("Theme set to: "..presetName) end
    end,
})
addLabel(themeSec, "Customize accent color below:")
addTextbox(themeSec, {
    Label = "Accent Hex", Value = "#64AFFF", Placeholder = "#64AFFF",
    Callback = function(_, v)
        local ok, col = pcall(function() return Color3.fromHex(v) end)
        if ok and col then
            Theme.accent = col
            Theme.accent_dim = Color3.fromRGB(
                math.floor(col.R*255*0.30), math.floor(col.G*255*0.30), math.floor(col.B*255*0.30))
            Theme.accent_glow = Color3.fromRGB(
                math.floor(col.R*255*0.80), math.floor(col.G*255*0.80), math.floor(col.B*255*0.80))
            refreshAllTheme()
            ConsoleMessage("Accent set to: "..v)
        end
    end,
})

local fileSettingsSec = addSection(setLeft, "replay file")
addLabel(fileSettingsSec, "Current replay file path:")
local replayPathLabel = addLabel(fileSettingsSec, ReplayPath or "N/A")
addCombo(fileSettingsSec, {
    Text = "Select File", Placeholder = "pick a replay...",
    GetItems = function()
        local ok, files = pcall(function() return listfiles(FolderPath) end)
        return ok and files or {}
    end,
    Callback = function(_, path)
        if not path then return end
        ReplayPath = path; replayPathLabel.Text = path
        ReplayNeedsReload = true
        ConsoleMessage("Replay file set to: "..path)
    end,
})
addButton(fileSettingsSec, "Open Folder (copy path)", function()
    if setclipboard then setclipboard(FolderPath); ConsoleMessage("Copied folder path to clipboard") end
end)

local windowSec = addSection(setRight, "window")
addTextbox(windowSec, {
    Label = "Window Width", Value = tostring(WIN_W), Placeholder = tostring(WIN_W),
    Callback = function(_, v)
        local n = tonumber(v)
        if n and n >= 400 and n <= 1400 then
            MainFrame.Size = UDim2.fromOffset(n, MainFrame.Size.Y.Offset)
        end
    end,
})
addTextbox(windowSec, {
    Label = "Window Height", Value = tostring(WIN_H), Placeholder = tostring(WIN_H),
    Callback = function(_, v)
        local n = tonumber(v)
        if n and n >= 300 and n <= 900 then
            MainFrame.Size = UDim2.fromOffset(MainFrame.Size.X.Offset, n)
        end
    end,
})

local effectsSettings = addSection(setRight, "effects")
addCheckbox(effectsSettings, {
    Label = "Background Blur", Default = true,
    Callback = function(self)
        if self.Value then
            tw(TasBlur, {Size = 12}, 0.3)
        else
            tw(TasBlur, {Size = 0}, 0.2)
        end
    end,
})

end

-- Activate first tab
switchTab("controls")

-- ══════════════════════════════════════════════════════════════════════════════
--  WINDOW VISIBILITY + ANIMATIONS
-- ══════════════════════════════════════════════════════════════════════════════

local windowOpen = true
local windowOpenSize = UDim2.fromOffset(WIN_W, WIN_H)

local function openWindow()
    if windowOpen then return end
    windowOpen = true
    MainFrame.Visible = true
    MainFrame.Size = UDim2.fromOffset(math.floor(windowOpenSize.X.Offset*0.92), math.floor(windowOpenSize.Y.Offset*0.92))
    MainFrame.BackgroundTransparency = 1
    tw(MainFrame, {Size = windowOpenSize, BackgroundTransparency = 0}, 0.16, Enum.EasingStyle.Cubic)
    tw(TasBlur, {Size = 12}, 0.16)
end

local function closeWindow()
    if not windowOpen then return end
    windowOpen = false
    windowOpenSize = MainFrame.Size
    local t1 = tw(MainFrame, {
        Size = UDim2.fromOffset(math.floor(windowOpenSize.X.Offset*0.92), math.floor(windowOpenSize.Y.Offset*0.92)),
        BackgroundTransparency = 1,
    }, 0.14, Enum.EasingStyle.Cubic)
    tw(TasBlur, {Size = 0}, 0.14)
    t1.Completed:Connect(function()
        if not windowOpen then MainFrame.Visible = false end
    end)
end

local function toggleWindow()
    if windowOpen then closeWindow() else openWindow() end
end

HideBtn.MouseButton1Click:Connect(toggleWindow)

-- Initial blur fade-in + window pop-up (no task.defer; runs immediately)
TasBlur.Size = 0
tw(TasBlur, {Size = 12}, 0.22)
MainFrame.Size = UDim2.fromOffset(math.floor(WIN_W*0.9), math.floor(WIN_H*0.9))
MainFrame.BackgroundTransparency = 1
tw(MainFrame, {Size = UDim2.fromOffset(WIN_W, WIN_H), BackgroundTransparency = 0}, 0.18, Enum.EasingStyle.Cubic)

-- ── Window shim (compatible API) ─────────────────────────────────────────────
Window = {}
function Window:ToggleVisibility()
    toggleWindow()
end

-- ── Current file auto-update ─────────────────────────────────────────────────
task.spawn(function()
    repeat task.wait() until type(ReplayPath) == "string"
    local function getFileName(path)
        local parts = string.split(path, "\\")
        return parts[#parts] or path
    end
    CurrentFile.Text = "Current File: "..getFileName(ReplayPath)
    local old = ReplayPath
    while task.wait() do
        if ReplayPath ~= old then
            CurrentFile.Text = "Current File: "..getFileName(ReplayPath)
            old = ReplayPath
        end
    end
end)

end -- ============== END Tasability UI v3 ==============

-- ══════════════════════════════════════════════════════════════════════════════
--  GUI FUNCTIONS
-- ══════════════════════════════════════════════════════════════════════════════

local SetColorCodeFrame
local GetColorCodeFrame
do
    ConsoleMessage = function(...)
        setthreadidentity(8)
        console:AppendText(...)
    end

    ConsoleMessage("Tasability loading...")

    SetColorCodeFrame = function(Name)
        ColorCodeFrame.TextColor3 = ColorCodes[Name] or ColorCodes.None
        ColorCodeFrame.Text = "Status: "..(ColorCodes[Name] and Name or "None")
    end

    GetColorCodeFrame = function()
        return string.sub(ColorCodeFrame.Text, 9, #ColorCodeFrame.Text)
    end
end

do -- Anticheat bypasses
	do -- standard anti kick
		--// Variables
		
		local Players = game:GetService("Players")
		local OldNameCall = nil

		--// Anti Kick Hook
		local plr = game.Players.LocalPlayer
		OldNameCall = hookmetamethod(game, "__namecall", function(Self, ...)
			local NameCallMethod = getnamecallmethod()

			if not checkcaller() and Self == plr and NameCallMethod == "Kick" then
				if getgenv().SendNotifications == true then
					game:GetService("StarterGui"):SetCore("SendNotification", {
						Title = "Almost Kicked",
						Text = tostring(({...})[1]),
						Icon = "rbxassetid://6238540373",
						Duration = 3,
					})
				end
				
				return nil
			end
			
			return OldNameCall(Self, ...)
		end)
	end
	pcall(function() -- Practice anticheat bypass
		game.ReplicatedStorage.Remotes.Send:Destroy()
	end)
	pcall(function() -- Slad anticheat bypass
		local sendremote = game.ReplicatedStorage.DefaultChatSystemChatEvents.ChannelNameColorUpdated
		local oldspawn
		oldspawn = hookfunction(getrenv().spawn, function(...)
			if not checkcaller() and (tostring(getcallingscript()) == "Animate" or tostring(getcallingscript()) == "RbxAnimateScript") then
				return oldspawn(function()
					
				end)
			end
			return oldspawn(...)
		end)
		sendremote:Destroy()
	end)

	-- ADONIS BYPASS 

local g = getinfo or debug.getinfo
local d = false
local h = {}

local x, y

setthreadidentity(2)

for i, v in getgc(true) do
    if typeof(v) == "table" then
        local a = rawget(v, "Detected")
        local b = rawget(v, "Kill")
    
        if typeof(a) == "function" and not x then
            x = a
            
            local o; o = hookfunction(x, function(c, f, n)
                if c ~= "_" then
                    if d then
                        warn(`Adonis AntiCheat flagged\nMethod: {c}\nInfo: {f}`)
                    end
                end
                
                return true
            end)

            table.insert(h, x)
        end

        if rawget(v, "Variables") and rawget(v, "Process") and typeof(b) == "function" and not y then
            y = b
            local o; o = hookfunction(y, function(f)
                if d then
                    warn(`Adonis AntiCheat tried to kill (fallback): {f}`)
                end
            end)

            table.insert(h, y)
        end
    end
end

local o; o = hookfunction(getrenv().debug.info, newcclosure(function(...)
    local a, f = ...

    if x and a == x then
        if d then
            warn(`zins adonis bypassed`)
        end

        return coroutine.yield(coroutine.running())
    end
    
    return o(...)
end))

setthreadidentity(7)

end



-- Animation Functions
local StopAllAnimations -- StopAllAnimations() -> nil
local Reanimate -- Reanimate(Character) -> nil

local GetAnimationFunctionFromId -- GetAnimationFunctionFromId(Id) -> function
local onDied -- onDied() -> nil
local onRunning -- onRunning(Speed) -> nil
local onJumping -- onJumping() -> nil
local onClimbing -- onClimbing(Speed) -> nil
local onGettingUp -- onGettingUp() -> nil
local onFreeFall -- onFreeFall() -> nil
local onFallingDown -- onFallingDown() -> nil
local onSeated -- onSeated() -> nil
local onPlatformStanding -- onPlatformStanding() -> nil
local onSwimming -- onSwimming() -> nil

local PlayAnimation -- PlayAnimation() -> nil
local setAnimationSpeed -- setAnimationSpeed() -> nil

do
	StopAllAnimations = function()
		for _,v in pairs(Humanoid:GetPlayingAnimationTracks()) do 
			v:Stop()
		end
	end
	
	GetAnimationFunctionFromId = function(Id)
		return ({
			[1] = OnDied;
			[2] = onRunning;
			[3] = onJumping;
			[4] = onClimbing;
			[5] = onGettingUp;
			[6] = onFreeFall;
			[7] = onFallingDown;
			[8] = onSeated;
			[9] = onPlatformStanding;
			[10] = onSwimming;
		})[Id]
	end

	Reanimate = function(Character)
		local animateFound = false
		
	
		if not Character:FindFirstChild("Humanoid") then
			Character:WaitForChild("Humanoid", 5)
		end
		
	
		if Character:WaitForChild("Animate", 3) then
			for _, Animate in ipairs(Character:GetDescendants()) do
				if Animate:IsA("LocalScript") and Animate.Name == "Animate" then
					animateFound = true
					for _,Connection in pairs(getconnections(Animate.Changed)) do
						Connection:Disconnect()
					end
					if BypassAntiExploit then
						Animate.Disabled = true
						if setparentinternal then
							setparentinternal(Animate, game.Lighting)
						else
							ConsoleMessage("Your exploit does not support setparentinternal, expect animation glitches")
						end
					else
						Animate:Destroy()
					end
					ConsoleMessage("Animate script found and disabled")
					break
				end
			end
		end
		
	
		if not animateFound then
			ConsoleMessage("[WARNING] Animate script not found - animations will be handled manually")
		end
		
		StopAllAnimations()
		
		do -- Animate script replacement
			local Figure = Character
			local Torso = Figure:WaitForChild("Torso")
			local RightShoulder = Torso:WaitForChild("Right Shoulder")
			local LeftShoulder = Torso:WaitForChild("Left Shoulder")
			local RightHip = Torso:WaitForChild("Right Hip")
			local LeftHip = Torso:WaitForChild("Left Hip")
			local Neck = Torso:WaitForChild("Neck")
			local Humanoid = Figure:WaitForChild("Humanoid")

			local currentAnim = ""
			local currentAnimInstance = nil
			local currentAnimTrack = nil
			local currentAnimKeyframeHandler = nil
			local animTable = {}
			local animNames = { 
				idle = 	{	
							{ id = "http://www.roblox.com/asset/?id=180435571", weight = 8 },
							{ id = "http://www.roblox.com/asset/?id=180435792", weight = 1 }
						},
				walk = 	{ 	
							{ id = "http://www.roblox.com/asset/?id=180426354", weight = 10 } 
						}, 
				run = 	{
							{ id = "run.xml", weight = 10 } 
						}, 
				jump = 	{
							{ id = "http://www.roblox.com/asset/?id=125750702", weight = 12 } 
						}, 
				fall = 	{
							{ id = "http://www.roblox.com/asset/?id=180436148", weight = 9 } 
						}, 
				climb = {
							{ id = "http://www.roblox.com/asset/?id=180436334", weight = 10 } 
						}, 
				sit = 	{
							{ id = "http://www.roblox.com/asset/?id=178130996", weight = 10 } 
						},	
				toolnone = {
							{ id = "http://www.roblox.com/asset/?id=182393478", weight = 10 } 
						},
				toolslash = {
							{ id = "http://www.roblox.com/asset/?id=129967390", weight = 10 } 
						},
				toollunge = {
							{ id = "http://www.roblox.com/asset/?id=129967478", weight = 10 } 
						},
				wave = {
							{ id = "http://www.roblox.com/asset/?id=128777973", weight = 10 } 
						},
				point = {
							{ id = "http://www.roblox.com/asset/?id=128853357", weight = 10 } 
						},
				dance1 = {
							{ id = "http://www.roblox.com/asset/?id=182435998", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491037", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491065", weight = 10 } 
						},
				dance2 = {
							{ id = "http://www.roblox.com/asset/?id=182436842", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491248", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491277", weight = 10 } 
						},
				dance3 = {
							{ id = "http://www.roblox.com/asset/?id=182436935", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491368", weight = 10 }, 
							{ id = "http://www.roblox.com/asset/?id=182491423", weight = 10 } 
						},
				laugh = {
							{ id = "http://www.roblox.com/asset/?id=129423131", weight = 10 } 
						},
				cheer = {
							{ id = "http://www.roblox.com/asset/?id=129423030", weight = 10 } 
						},
			}
			local dances = {"dance1", "dance2", "dance3"}

			local emoteNames = { wave = false, point = false, dance1 = true, dance2 = true, dance3 = true, laugh = false, cheer = false}

			function configureAnimationSet(name, fileList)
				if (animTable[name] ~= nil) then
					for _, connection in pairs(animTable[name].connections) do
						connection:disconnect()
					end
				end
				animTable[name] = {}
				animTable[name].count = 0
				animTable[name].totalWeight = 0	
				animTable[name].connections = {}

				if (animTable[name].count <= 0) then
					for idx, anim in pairs(fileList) do
						animTable[name][idx] = {}
						animTable[name][idx].anim = Instance.new("Animation")
						animTable[name][idx].anim.Name = name
						animTable[name][idx].anim.AnimationId = anim.id
						animTable[name][idx].weight = anim.weight
						animTable[name].count = animTable[name].count + 1
						animTable[name].totalWeight = animTable[name].totalWeight + anim.weight
					end
				end
			end

			local animator = Humanoid and Humanoid:FindFirstChildOfClass("Animator") or nil
			if animator then
				local animTracks = animator:GetPlayingAnimationTracks()
				for i,track in ipairs(animTracks) do
					track:Stop(0)
					track:Destroy()
				end
			end

			for name, fileList in pairs(animNames) do 
				configureAnimationSet(name, fileList)
			end	

			local toolAnim = "None"
			local toolAnimTime = 0
			local jumpAnimTime = 0
			local jumpAnimDuration = 0.3
			local toolTransitionTime = 0.1
			local fallTransitionTime = 0.3
			local jumpMaxLimbVelocity = 0.75

			function stopAllAnimations()
				local oldAnim = currentAnim
				if (emoteNames[oldAnim] ~= nil and emoteNames[oldAnim] == false) then
					oldAnim = "idle"
				end
				currentAnim = ""
				currentAnimInstance = nil
				if (currentAnimKeyframeHandler ~= nil) then
					currentAnimKeyframeHandler:disconnect()
				end
				if (currentAnimTrack ~= nil) then
					currentAnimTrack:Stop()
					currentAnimTrack:Destroy()
					currentAnimTrack = nil
				end
				return oldAnim
			end

			setAnimationSpeed = function(speed)
				if speed ~= currentAnimSpeed then
					currentAnimSpeed = speed
					if currentAnimTrack then
						-- the recorded speed stays unscaled: only the live track is slowed down
						currentAnimTrack:AdjustSpeed(currentAnimSpeed * SpeedHack.AnimationScale())
					end
				end
			end

			-- a rate change mid-run does not wait for the next animation transition: the track
			-- that is already playing is handed the new scale now, so the feet keep up with the
			-- body from the frame the rate changed on
			PlaybackCtl.RefreshAnimationSpeed = function()
				if currentAnimTrack then
					pcall(function()
						currentAnimTrack:AdjustSpeed(currentAnimSpeed * SpeedHack.AnimationScale())
					end)
				end
			end

			-- HappaTAS-style backtracking: a frame stepped onto in the middle of an animation
			-- should show the track at the phase the recording had reached, not at its first
			-- pose. Walk back to the frame that started the animation that is playing now and
			-- add the animation time every frame the run spent there at its recorded speed.
			PlaybackCtl.SyncAnimationPhase = function(TargetFrame)
				if not currentAnimTrack or type(ReplayTable) ~= "table" then return end
				local Rate = tonumber(FPS)
				if not Rate or Rate < 1 then return end
				if TargetFrame > #ReplayTable then TargetFrame = #ReplayTable end
				local Phase, Started = 0, nil
				for Index = TargetFrame, 1, -1 do
					local FrameData = ReplayTable[Index]
					if type(FrameData) ~= "table" then break end
					Phase = Phase + (tonumber(FrameData[3]) or 1) / Rate
					local Events = FrameData[2]
					if type(Events) == "table" and #Events > 0 then
						Started = Events[#Events][1]
						break
					end
				end
				-- a forced idle (landing, emote fallback) is not the animation the tape is on
				if Started and Started ~= currentAnim then return end
				local Length = tonumber(currentAnimTrack.Length)
				if Length and Length > 0.01 then
					if currentAnimTrack.Looped then
						Phase = Phase % Length
					elseif Phase > Length then
						Phase = Length
					end
				end
				pcall(function()
					currentAnimTrack.TimePosition = Phase
				end)
			end

			-- the variant the tape last played for this animation, so a seed after a start or a
			-- respawn shows the take the recording showed instead of rolling the other one
			PlaybackCtl.LastVariantFor = function(TargetFrame, AnimName)
				if type(ReplayTable) ~= "table" then return nil end
				if TargetFrame > #ReplayTable then TargetFrame = #ReplayTable end
				for Index = TargetFrame, 1, -1 do
					local FrameData = ReplayTable[Index]
					if type(FrameData) ~= "table" then return nil end
					local Events = FrameData[2]
					if type(Events) == "table" and #Events > 0 then
						local Last = Events[#Events]
						if Last[1] == AnimName then
							return Last[3]
						end
						return nil
					end
				end
				return nil
			end

			-- The sample the render step draws while frame interpolation is on: a continuous
			-- playhead over the recorded frames. It is driven by wall-clock time, not by how
			-- many frames the heartbeat happened to take, so the rig covers the same distance
			-- per real second on a beat that pulled one frame and on a beat that pulled three.
			PlaybackCtl.SampleInterpolatedFrame = function()
				if type(ReplayTable) ~= "table" then return nil end
				local Head = PlaybackCtl.AppliedIndex
				local Applied = Head and ReplayTable[Head]
				if type(Applied) ~= "table" or type(Applied[1]) ~= "table" then return nil end
				local AppliedRoot = FastTableToCFrame(Applied[1])
				local AppliedCam = type(Applied[7]) == "table" and FastTableToCFrame(Applied[7]) or nil
				-- a pause holds the frame it stopped on, untouched by the playhead
				if Paused or Frozen then return AppliedRoot,AppliedCam end
				local Pos = PlaybackCtl.RenderPos
				if not Pos then return AppliedRoot,AppliedCam end
				-- one frame of slack either side: the head may trail the applied frame by a
				-- beat or lead it by the one it is blending toward, never further
				if Pos < Head - 1 then Pos = Head - 1 end
				if Pos > Head + 1 then Pos = Head + 1 end
				local A = math.floor(Pos)
				local FrameA = ReplayTable[A]
				local FrameB = ReplayTable[A + 1]
				-- a marker, the tape edge or an empty slot: hold the pose that was applied
				if type(FrameA) ~= "table" or type(FrameA[1]) ~= "table" or type(FrameA[7]) ~= "table" then
					return AppliedRoot,AppliedCam
				end
				local Frac = Pos - A
				if type(FrameB) ~= "table" or type(FrameB[1]) ~= "table" or type(FrameB[7]) ~= "table" then
					return FastTableToCFrame(FrameA[1]),FastTableToCFrame(FrameA[7])
				end
				-- a gap over a tenth of a second is a cut or a hold, not travel: HappaTAS sits
				-- on the frame in front of it instead of sliding through it
				local Rate = PlaybackCtl.FileFPS or FPS
				local TimeA,TimeB = tonumber(FrameA[14]),tonumber(FrameB[14])
				if Rate and Rate >= 1 and TimeA and TimeB and (TimeB - TimeA) / Rate > 0.1 then
					Frac = 0
				end
				-- a jump this large in one frame is a respawn or a checkpoint set, not travel:
				-- the game puts the body there instantly, so the sample snaps instead of
				-- smearing the rig across the level for a beat
				local BodyDx,BodyDy,BodyDz =
					FrameB[1][1]-FrameA[1][1],FrameB[1][2]-FrameA[1][2],FrameB[1][3]-FrameA[1][3]
				if BodyDx*BodyDx + BodyDy*BodyDy + BodyDz*BodyDz > 900 then
					Frac = 0
				end
				local CamDx,CamDy,CamDz =
					FrameB[7][1]-FrameA[7][1],FrameB[7][2]-FrameA[7][2],FrameB[7][3]-FrameA[7][3]
				if CamDx*CamDx + CamDy*CamDy + CamDz*CamDz > 10000 then
					Frac = 0
				end
				if Frac <= 0 then
					return FastTableToCFrame(FrameA[1]),FastTableToCFrame(FrameA[7])
				end
				-- raw components, the way HappaTAS blends a pair: the pose lands between the two
				-- recorded samples at exactly the fraction the playhead has reached
				local RootCFrame,CameraCFrame = {},{}
				for i = 1,12 do
					table.insert(RootCFrame,FrameA[1][i]*(1-Frac) + FrameB[1][i]*Frac)
					table.insert(CameraCFrame,FrameA[7][i]*(1-Frac) + FrameB[7][i]*Frac)
				end
				return FastTableToCFrame(RootCFrame),FastTableToCFrame(CameraCFrame)
			end

			function keyFrameReachedFunc(frameName)
				-- a playing tape already carries every transition it saw; letting the track
				-- re-roll on its own loop would flip the take off the recorded variant
				if Reading then return end
				if (frameName == "End") then
					local repeatAnim = currentAnim
					if (emoteNames[repeatAnim] ~= nil and emoteNames[repeatAnim] == false) then
						repeatAnim = "idle"
					end
					local animSpeed = currentAnimSpeed
					playAnimation(repeatAnim, 0.0, Humanoid)
					setAnimationSpeed(animSpeed)
				end
			end

			playAnimation = function(animName, transitionTime, humanoid, bypassAnimateDisabled, animId) 
				pcall(function()
					if AnimateDisabled and not bypassAnimateDisabled then
						return
					end
					
					local anim
					-- a replay hands back the variant it recorded: idle rolls 8:1 between two
					-- takes, and a fresh roll would replay the other one
					if animId then
						local Set = animTable[animName]
						if Set then
							for idx = 1, Set.count or 0 do
								if Set[idx] and Set[idx].anim.AnimationId == animId then
									anim = Set[idx].anim
									break
								end
							end
						end
					end
					if not anim then
						local roll = math.random(1, animTable[animName].totalWeight) 
						local idx = 1
						while (roll > animTable[animName][idx].weight) do
							roll = roll - animTable[animName][idx].weight
							idx = idx + 1
						end
						anim = animTable[animName][idx].anim
					end

					-- the resolved variant rides with the event so playback can reproduce it
					table.insert(AnimationQueue,{animName,transitionTime,anim.AnimationId})

					if (anim ~= currentAnimInstance) then
						if (currentAnimTrack ~= nil) then
							currentAnimTrack:Stop(transitionTime)
							currentAnimTrack:Destroy()
						end
						currentAnimSpeed = 1.0
						currentAnimTrack = humanoid:LoadAnimation(anim)
						currentAnimTrack.Priority = Enum.AnimationPriority.Core
						currentAnimTrack:Play(transitionTime)
						local Scale = SpeedHack.AnimationScale()
						if Scale ~= 1 then
							currentAnimTrack:AdjustSpeed(Scale)
						end
						currentAnim = animName
						currentAnimInstance = anim
						if (currentAnimKeyframeHandler ~= nil) then
							currentAnimKeyframeHandler:disconnect()
						end
						currentAnimKeyframeHandler = currentAnimTrack.KeyframeReached:connect(keyFrameReachedFunc)
					end
				end)
			end

			local toolAnimName = ""
			local toolAnimTrack = nil
			local toolAnimInstance = nil
			local currentToolAnimKeyframeHandler = nil

			function toolKeyFrameReachedFunc(frameName)
				if (frameName == "End") then
					playToolAnimation(toolAnimName, 0.0, Humanoid)
				end
			end

			function playToolAnimation(animName, transitionTime, humanoid, priority)	 
				local roll = math.random(1, animTable[animName].totalWeight) 
				local origRoll = roll
				local idx = 1
				while (roll > animTable[animName][idx].weight) do
					roll = roll - animTable[animName][idx].weight
					idx = idx + 1
				end
				local anim = animTable[animName][idx].anim
				if (toolAnimInstance ~= anim) then
					if (toolAnimTrack ~= nil) then
						toolAnimTrack:Stop()
						toolAnimTrack:Destroy()
						transitionTime = 0
					end
					toolAnimTrack = humanoid:LoadAnimation(anim)
					if priority then
						toolAnimTrack.Priority = priority
					end
					toolAnimTrack:Play(transitionTime)
					local Scale = SpeedHack.AnimationScale()
					if Scale ~= 1 then
						toolAnimTrack:AdjustSpeed(Scale)
					end
					toolAnimName = animName
					toolAnimInstance = anim
					currentToolAnimKeyframeHandler = toolAnimTrack.KeyframeReached:connect(toolKeyFrameReachedFunc)
				end
			end

			function stopToolAnimations()
				local oldAnim = toolAnimName
				if (currentToolAnimKeyframeHandler ~= nil) then
					currentToolAnimKeyframeHandler:disconnect()
				end
				toolAnimName = ""
				toolAnimInstance = nil
				if (toolAnimTrack ~= nil) then
					toolAnimTrack:Stop()
					toolAnimTrack:Destroy()
					toolAnimTrack = nil
				end
				return oldAnim
			end

			-- re-applies the slow-motion scale to tracks that are already playing
			SpeedHack.RefreshAnimations = function()
				local Scale = SpeedHack.AnimationScale()
				if currentAnimTrack then
					pcall(function() currentAnimTrack:AdjustSpeed(currentAnimSpeed * Scale) end)
				end
				if toolAnimTrack then
					pcall(function() toolAnimTrack:AdjustSpeed(Scale) end)
				end
			end

			-- Pausing a replay stops the frame pointer, not the Animator: the track would keep
			-- ticking through the pause and come back at a different point in its cycle.
			SpeedHack.HoldAnimations = function(Hold)
				if not currentAnimTrack then
					return
				end
				pcall(function()
					if Hold then
						currentAnimTrack:AdjustSpeed(0)
					else
						currentAnimTrack:AdjustSpeed(currentAnimSpeed * SpeedHack.AnimationScale())
					end
				end)
			end

			onRunning = function(speed)
				if speed > 0.01 then
					playAnimation("walk", 0.1, Humanoid)
					if currentAnimInstance and currentAnimInstance.AnimationId == "http://www.roblox.com/asset/?id=180426354" then
						setAnimationSpeed((speed / 14.5) / SpeedHack.AnimationScale()) -- event speed is already slowed
					end
					pose = "Running"
				else
					if emoteNames[currentAnim] == nil then
						playAnimation("idle", 0.1, Humanoid)
						pose = "Standing"
					end
				end
			end

			onDied = function()
				pose = "Dead"
			end

			onJumping = function()
				playAnimation("jump", 0.1, Humanoid)
				jumpAnimTime = jumpAnimDuration
				pose = "Jumping"
			end

			onClimbing = function(speed)
				playAnimation("climb", 0.1, Humanoid)
				setAnimationSpeed((speed / 12.0) / SpeedHack.AnimationScale()) -- event speed is already slowed
				pose = "Climbing"
			end

			onGettingUp = function()
				pose = "GettingUp"
			end

			onFreeFall = function()
				if (jumpAnimTime <= 0) then
					playAnimation("fall", fallTransitionTime, Humanoid)
				end
				pose = "FreeFall"
			end

			onFallingDown = function()
				pose = "FallingDown"
			end

			onSeated = function()
				pose = "Seated"
			end

			onPlatformStanding = function()
				pose = "PlatformStanding"
			end

			onSwimming = function(speed)
				if speed > 0 then
					pose = "Running"
				else
					pose = "Standing"
				end
			end

			function getTool()	
				for _, kid in ipairs(Figure:GetChildren()) do
					if kid.className == "Tool" then return kid end
				end
				return nil
			end

			function getToolAnim(tool)
				for _, c in ipairs(tool:GetChildren()) do
					if c.Name == "toolanim" and c.className == "StringValue" then
						return c
					end
				end
				return nil
			end

			function animateTool()
				if (toolAnim == "None") then
					playToolAnimation("toolnone", toolTransitionTime, Humanoid, Enum.AnimationPriority.Idle)
					return
				end
				if (toolAnim == "Slash") then
					playToolAnimation("toolslash", 0, Humanoid, Enum.AnimationPriority.Action)
					return
				end
				if (toolAnim == "Lunge") then
					playToolAnimation("toollunge", 0, Humanoid, Enum.AnimationPriority.Action)
					return
				end
			end

			function moveSit()
				RightShoulder.MaxVelocity = 0.15
				LeftShoulder.MaxVelocity = 0.15
				RightShoulder:SetDesiredAngle(3.14 /2)
				LeftShoulder:SetDesiredAngle(-3.14 /2)
				RightHip:SetDesiredAngle(3.14 /2)
				LeftHip:SetDesiredAngle(-3.14 /2)
			end

			local lastTick = 0

			function move(time)
				if AnimateDisabled then
					return
				end
				
				local amplitude = 1
				local frequency = 1
				local deltaTime = time - lastTick
				lastTick = time
				local climbFudge = 0
				local setAngles = false

				if (jumpAnimTime > 0) then
					jumpAnimTime = jumpAnimTime - deltaTime
				end

				if (pose == "FreeFall" and jumpAnimTime <= 0) then
					playAnimation("fall", fallTransitionTime, Humanoid)
				elseif (pose == "Seated") then
					playAnimation("sit", 0.5, Humanoid)
					return
				elseif (pose == "Running") then
					playAnimation("walk", 0.1, Humanoid)
				elseif (pose == "Dead" or pose == "GettingUp" or pose == "FallingDown" or pose == "Seated" or pose == "PlatformStanding") then
					stopAllAnimations()
					amplitude = 0.1
					frequency = 1
					setAngles = true
				end

				if (setAngles) then
					local desiredAngle = amplitude * math.sin(time * frequency)
					RightShoulder:SetDesiredAngle(desiredAngle + climbFudge)
					LeftShoulder:SetDesiredAngle(desiredAngle - climbFudge)
					RightHip:SetDesiredAngle(-desiredAngle)
					LeftHip:SetDesiredAngle(-desiredAngle)
				end

				local tool = getTool()
				if tool and tool:FindFirstChild("Handle") then
					local animStringValueObject = getToolAnim(tool)
					if animStringValueObject then
						toolAnim = animStringValueObject.Value
						animStringValueObject.Parent = nil
						toolAnimTime = time + .3
					end
					if time > toolAnimTime then
						toolAnimTime = 0
						toolAnim = "None"
					end
					animateTool()		
				else
					stopToolAnimations()
					toolAnim = "None"
					toolAnimInstance = nil
					toolAnimTime = 0
				end
			end

			Humanoid.Died:connect(function(...)
				if AnimateDisabled then
					return
				end
				onDied(...)
			end)
			Humanoid.Running:connect(function(Speed)
				if AnimateDisabled then
					return
				end
				onRunning(Speed)
			end)
			Humanoid.Jumping:connect(onJumping)
			Humanoid.Climbing:connect(function(Speed)
				if AnimateDisabled then
					return
				end
				onClimbing(Speed)
			end)
			Humanoid.GettingUp:connect(function(...)
				if AnimateDisabled then
					return
				end
				onGettingUp(...)
			end)
			Humanoid.FreeFalling:connect(function(...)
				if AnimateDisabled then
					return
				end
				onFreeFall(...)
			end)
			Humanoid.FallingDown:connect(function(...)
				if AnimateDisabled then
					return
				end
				onFallingDown(...)
			end)
			Humanoid.Seated:connect(function(...)
				if AnimateDisabled then
					return
				end
				onSeated(...)
			end)
			Humanoid.PlatformStanding:connect(function(...)
				if AnimateDisabled then
					return
				end
				onPlatformStanding(...)
			end)
			Humanoid.Swimming:connect(function(...)
				if AnimateDisabled then
					return
				end
				onSwimming(...)
			end)

			game:GetService("Players").LocalPlayer.Chatted:connect(function(msg)
				local emote = ""
				if msg == "/e dance" then
					emote = dances[math.random(1, #dances)]
				elseif (string.sub(msg, 1, 3) == "/e ") then
					emote = string.sub(msg, 4)
				elseif (string.sub(msg, 1, 7) == "/emote ") then
					emote = string.sub(msg, 8)
				end
				
				if (pose == "Standing" and emoteNames[emote] ~= nil) then
					playAnimation(emote, 0.1, Humanoid)
				end
			end)

			playAnimation("idle", 0.1, Humanoid)
			pose = "Standing"

			spawn(function()
				while Figure.Parent ~= nil do
					local _, time = wait(0.1)
					move(time)
				end
			end)
		end 
	end 
end 

-- Camera/Input Functions
local GetZoom -- GetZoom() -> number
local SetZoom -- SetZoom(Zoom) -> nil

local GetShiftLockEnabled -- GetShiftLockEnabled() -> bool
local SetShiftLockEnabled -- SetShiftLockEnabled(Enabled) -> nil

local SetCameraCFrame -- SetCameraCFrame(NewCFrame) -> nil

local BlockInputs -- BlockInputs() -> nil
local UnlockInputs -- UnlockInputs() -> nil

local SetCursorIcon -- SetCursorIcon(Icon) -> nil
local SetCursorSize -- SetCursorSize(Size) -> nil
local SetCursorOffset -- SetCursorOffset(Offset) -> nil
local SetCursor -- SetCursorIcon(CursorName) -> nil

do
	-- Load mouse lock action
	VirtualInputManager:SendKeyEvent(true, 304, false, workspace)
	wait()
	VirtualInputManager:SendKeyEvent(true, 304, false, workspace)
	wait()
	
	local ZoomControllers = {}
	
	do -- Get ZoomControllers from getgc
		for _,Table in pairs(getgc(true)) do
			if type(Table) == "table" then
				pcall(function()
					if type(Table.SetCameraToSubjectDistance) == "function"
					and type(Table.GetCameraToSubjectDistance) == "function"
					and Table.FIRST_PERSON_DISTANCE_THRESHOLD
					and Table.lastCameraTransform then
						table.insert(ZoomControllers,Table)
					end
				end)
			end
		end
		ConsoleMessage(tostring(#ZoomControllers).." ZoomController"..(#ZoomControllers == 1 and "" or "s"))
	end
	GetZoom = function()
		for _,ZoomController in pairs(ZoomControllers) do
			local Zoom = ZoomController:GetCameraToSubjectDistance()
			if Zoom and Zoom ~= 12.5 then
				return Zoom
			end
		end
		return 12.5
	end
	local function SmoothSetZoom(zoom)
	TargetZoom = zoom
end

SetZoom = function(Zoom)
	for _,ZoomController in pairs(ZoomControllers) do
		pcall(function()
			ZoomController:SetCameraToSubjectDistance(Zoom)
		end)
	end
end

	
	GetShiftLockEnabled = function()
		return ShiftLockEnabled
	end

	local cachedMouseLockController = nil
	local function getMouseLockController()
		if cachedMouseLockController and cachedMouseLockController.DoMouseLockSwitch then
			return cachedMouseLockController
		end
		
		for _, obj in getgc(true) do 
			if type(obj) == "table" and rawget(obj, "activeMouseLockController") then 
				cachedMouseLockController = obj.activeMouseLockController
				return cachedMouseLockController
			end
		end
		return nil
	end

	function shiftLock(active)
		local mouseLockController = getMouseLockController()
		if not mouseLockController then return end
		
		local isLocked = mouseLockController:GetIsMouseLocked()
		if (active and not isLocked) or (not active and isLocked) then
			mouseLockController:DoMouseLockSwitch("MouseLockSwitchAction", Enum.UserInputState.Begin, game)
		end
	end

	-- DisplayOnly writes the tracked bit and the cursor without touching the live controller. A
	-- scripted camera (playback or a frozen still) has nothing for the mouse lock to do except
	-- fight the recorded view, and on a still the toggle outlived the unfreeze: the player was
	-- left mouse-locked by a frame they had only been looking at.
	SetShiftLockEnabled = function(Enabled, DisplayOnly)
		if ShiftLockEnabled ~= Enabled then
			ShiftLockEnabled = Enabled
			if Enabled then
				SetCursor("MouseLockedCursor")
			else
				SetCursor("ArrowFarCursor")
			end
			if not Reading and not DisplayOnly then
				pcall(function()
					shiftLock(Enabled)
				end)
			end
		end
	end

	-- The controller's own state is the live lock; the tracked boolean is only what the tape or
	-- the cursor last wanted. A game script, a mobile button or a module reload can toggle the
	-- lock behind the tool's back, and a recording has to store what the player actually had.
	PlaybackCtl.LiveShiftLock = function()
		local Controller = cachedMouseLockController
		if not (Controller and Controller.GetIsMouseLocked) then
			-- the scan walks the gc, so a game without the stock module gets one attempt a second
			local Now = tick()
			if PlaybackCtl.LockScanAt and Now - PlaybackCtl.LockScanAt < 1 then return nil end
			PlaybackCtl.LockScanAt = Now
			local Ok, Found = pcall(getMouseLockController)
			Controller = Ok and Found or nil
			if not (Controller and Controller.GetIsMouseLocked) then return nil end
		end
		local OkLocked, Locked = pcall(Controller.GetIsMouseLocked, Controller)
		if OkLocked and type(Locked) == "boolean" then
			return Locked
		end
		return nil
	end

	-- Adopt the live lock into the tracked bit and the cursor without toggling the controller.
	PlaybackCtl.SyncShiftLock = function()
		local Live = PlaybackCtl.LiveShiftLock()
		if Live == nil then return false end
		if Live ~= ShiftLockEnabled then
			SetShiftLockEnabled(Live, true)
		end
		return true
	end
		
	SetCameraCFrame = function(NewCFrame)
		if not NewCFrame then
			return -- a frame without a camera channel keeps the previous view
		end
		CameraCFrame = NewCFrame
		PlaybackCtl.CameraHold = true
		workspace.CurrentCamera.CFrame = NewCFrame
	end

	-- Playback owns the root through HumanoidRootPart; the rest of the rig only follows because
	-- something holds it there. The RootJoint is an animated motor, and R6 torso keyframes drive
	-- it: the Animator rewrites that joint every frame after these callbacks, so a transform
	-- written here is a suggestion, not a lock - the torso keeps easing through its recorded
	-- sway instead of staying square on the root. The run gets a real weld instead: a Weld with
	-- the motor's own offsets holds the torso on the root, and the motor is switched off, so no
	-- animation sample can turn the torso off the heading the root was placed on. R6 only: the
	-- torso hangs off Torso.RootJoint. The lock lands in the frame it is first needed and stays
	-- for the run; ReleaseRigLock hands the rig back to the motor when playback ends. Nothing is
	-- written to the torso: a CFrame write on a jointed part drags the assembly, and fighting the
	-- solver every frame is what made turns vibrate.
	PlaybackCtl.RigLockName = "PlaybackRigLock"
	PlaybackCtl.AlignRig = function()
		if not Character or not Character.Parent then return end
		-- Hot path: verification is by live reference, so a weld a game script destroyed or a
		-- motor switched back on still falls through to the full repair.
		local Cache = PlaybackCtl.RigCache
		if Cache and Cache.Character == Character then
			local CBody, CHRP = Cache.Body, Cache.HRP
			local CJoint, CLock = Cache.Joint, Cache.Lock
			if CBody.Parent == Character and CHRP.Parent == Character
				and CJoint.Parent and not CJoint.Enabled
				and CLock.Parent == CBody and CLock.Part0 == CHRP and CLock.Part1 == CBody then
				return
			end
		end
		local HRP = Character:FindFirstChild("HumanoidRootPart")
		if not HRP then return end
		local Body = Character:FindFirstChild("Torso")
		if not Body then return end
		local Joint = Body:FindFirstChild("RootJoint") or HRP:FindFirstChild("RootJoint")
		if not Joint or not Joint:IsA("Motor6D") then return end
		-- the motor goes off first: a weld and a live motor on the same pair would fight for a
		-- solve, and the fight is the shiver this whole path exists to remove
		if Joint.Enabled then
			Joint.Enabled = false
		end
		local Lock = Body:FindFirstChild(PlaybackCtl.RigLockName)
		if not Lock then
			Lock = Instance.new("Weld")
			Lock.Name = PlaybackCtl.RigLockName
			Lock.Part0 = HRP
			Lock.Part1 = Body
			-- the motor's offsets are the bind pose: copied over, the weld lands the torso
			-- exactly where a still joint sits, in the frame the lock goes on
			Lock.C0 = Joint.C0
			Lock.C1 = Joint.C1
			Lock.Parent = Body
			PlaybackCtl.RigRepairs = (PlaybackCtl.RigRepairs or 0) + 1
			if not PlaybackCtl.RigRepairLogged then
				PlaybackCtl.RigRepairLogged = true
				ConsoleMessage("Rig locked: the torso is welded onto the root for the run - animation cannot turn it off the recorded heading")
			end
		elseif Lock.Part0 ~= HRP or Lock.Part1 ~= Body then
			Lock.Part0 = HRP
			Lock.Part1 = Body
		end
		PlaybackCtl.RigCache = {
			Character = Character,
			HRP = HRP,
			Body = Body,
			Joint = Joint,
			Lock = Lock,
		}
	end

	-- hands the rig back when the run ends: the weld goes, the motor comes back on, and the
	-- character animates like any other again. Destroying the weld before re-enabling the motor
	-- leaves the two never live on the pair at the same time.
	PlaybackCtl.ReleaseRigLock = function()
		if not Character or not Character.Parent then return end
		PlaybackCtl.RigCache = nil
		local Body = Character:FindFirstChild("Torso")
		local HRP = Character:FindFirstChild("HumanoidRootPart")
		local Lock = Body and Body:FindFirstChild(PlaybackCtl.RigLockName)
		if Lock then
			Lock:Destroy()
		end
		local Joint = Body and (Body:FindFirstChild("RootJoint")
			or (HRP and HRP:FindFirstChild("RootJoint")))
		if Joint and Joint:IsA("Motor6D") and not Joint.Enabled then
			Joint.Enabled = true
		end
	end

	-- Happa-style body alignment. The stock camera swings the character toward the view in
	-- mouse-locked play through UserGameSettings.RotationType; left on CameraRelative while the
	-- replay holds the body still, a paused or frozen frame keeps turning with the mouse instead
	-- of staying on its recorded heading. The setting is captured once and handed back on stop.
	PlaybackCtl.RotationSettings = function()
		if PlaybackCtl.CachedRotationSettings == nil then
			local Ok, Result = pcall(function()
				return UserSettings():GetService("UserGameSettings")
			end)
			PlaybackCtl.CachedRotationSettings = (Ok and Result) or false
		end
		return PlaybackCtl.CachedRotationSettings or nil
	end

	PlaybackCtl.SetRotationType = function(CameraRelative)
		local Settings = PlaybackCtl.RotationSettings()
		if not Settings then return end
		local Want = CameraRelative and Enum.RotationType.CameraRelative or Enum.RotationType.MovementRelative
		-- a new intent is applied at once - a shift lock toggle recorded mid-run has to land on
		-- the frame it was recorded on
		local Changed = PlaybackCtl.RotationWant ~= Want
		PlaybackCtl.RotationWant = Want
		if Settings.RotationType ~= Want then
			-- a game or module that keeps writing the setting back must not turn this into a
			-- property fight every frame; repeat attempts at the same value wait a quarter second
			local Now = tick()
			if not Changed and PlaybackCtl.RotationRetryAt and Now < PlaybackCtl.RotationRetryAt then return end
			PlaybackCtl.RotationRetryAt = Now + 0.25
			pcall(function()
				Settings.RotationType = Want
			end)
		end
	end

	-- the body is not taking its own steps: hold the recorded heading, not the mouse
	PlaybackCtl.HoldRotationType = function()
		local Settings = PlaybackCtl.RotationSettings()
		if not Settings then return end
		if PlaybackCtl.PrevRotationType == nil then
			PlaybackCtl.PrevRotationType = Settings.RotationType
		end
		PlaybackCtl.SetRotationType(false)
	end

	-- SkipWrite forgets the held setting without writing it back. DesiredCameraRelative writes
	-- a specific value instead of the held one: the hand-back uses it when the live camera mode
	-- (mouse lock or first person) has moved since the setting was captured, and the captured
	-- value no longer describes the camera the player is about to get.
	PlaybackCtl.RestoreRotationType = function(SkipWrite, DesiredCameraRelative)
		local Settings = PlaybackCtl.RotationSettings()
		local Want
		if DesiredCameraRelative ~= nil then
			Want = DesiredCameraRelative and Enum.RotationType.CameraRelative
				or Enum.RotationType.MovementRelative
		elseif not SkipWrite then
			Want = PlaybackCtl.PrevRotationType
		end
		if Settings and Want ~= nil and Settings.RotationType ~= Want then
			pcall(function()
				Settings.RotationType = Want
			end)
		end
		PlaybackCtl.PrevRotationType = nil
		PlaybackCtl.RotationWant = nil
		PlaybackCtl.RotationRetryAt = nil
	end

	-- Happa-style look-around. A paused replay, or a frozen recorded frame, is a still placed by
	-- the tape; the camera on top of it is only there to show that still from the recorded angle.
	-- While looking around, the view is handed back to the stock camera so the frame can be
	-- inspected from any side; toggling off, stepping, unpausing, freezing or stopping snaps the
	-- view back to the recorded one.
	PlaybackCtl.ToggleLookAround = function()
		if PlaybackCtl.LookAround then
			PlaybackCtl.LookAround = nil
			SetColorCodeFrame(Frozen and "Frozen" or "Paused")
			ConsoleMessage("Look around off - back on the recorded view")
			return
		end
		if not ((Reading and Paused) or Frozen) then
			ConsoleMessage("Look around works while a replay is paused or a frame is frozen")
			return
		end
		PlaybackCtl.LookAround = true
		SetColorCodeFrame("LookAround")
		ConsoleMessage("Look around on - the camera is free, toggle again to snap back to the recorded view")
	end

	-- called from every transition that puts the recorded view back in charge
	PlaybackCtl.ClearLookAround = function()
		if not PlaybackCtl.LookAround then return end
		PlaybackCtl.LookAround = nil
		SetColorCodeFrame(Frozen and "Frozen" or (Reading and Paused and "Paused" or "Reading"))
	end

	-- The file's own velocity channel is ground truth for its frame rate: the root covers
	-- |v| / fps studs per frame, so fps = |v| / |delta position|. Frames that are braking keep a
	-- high velocity while the delta shrinks and land in the upper tail; the lower quartile sits
	-- on the captured rate. Replays saved before the rate was stamped with the file still play
	-- at the speed they were captured at, not at whatever this client is configured for.
	PlaybackCtl.EstimateFPS = function(Table)
		local Samples = {}
		local PrevPos
		for _, Frame in ipairs(Table) do
			if type(Frame) ~= "table" or type(Frame[1]) ~= "table" or type(Frame[5]) ~= "table" then
				PrevPos = nil
			else
				local Pos, Vel = Frame[1], Frame[5]
				local Speed = math.sqrt(Vel[1] * Vel[1] + Vel[2] * Vel[2] + Vel[3] * Vel[3])
				if PrevPos then
					local DX = Pos[1] - PrevPos[1]
					local DY = Pos[2] - PrevPos[2]
					local DZ = Pos[3] - PrevPos[3]
					local Delta = math.sqrt(DX * DX + DY * DY + DZ * DZ)
					if Delta > 0.02 and Speed > 8 then
						Samples[#Samples + 1] = Speed / Delta
					end
				end
				PrevPos = Pos
			end
		end
		if #Samples < 200 then return nil end
		table.sort(Samples)
		local Value = Samples[math.max(1, math.floor(#Samples * 0.25))]
		if Value < 24 or Value > 1000 then return nil end
		return Value
	end

	-- The camera module keeps running on purpose. It is what hides the local character in
	-- first person and pops parts the camera is inside; hijacking CameraType to Scriptable
	-- stops all of that and the replay shows the whole avatar from inside its head. The
	-- recorded view still wins: the bound step runs after RenderPriority.Camera and is the
	-- last write of the frame.
	PlaybackCtl.ReleaseCamera = function()
		PlaybackCtl.CameraHold = nil
	end

	PlaybackCtl.SetCamera = SetCameraCFrame
	
	local BlockGui = Instance.new("ScreenGui")
	local BlockFrame = Instance.new("TextButton")
	BlockFrame.Text = ""
	BlockFrame.BackgroundTransparency = 1
	BlockFrame.Size = UDim2.fromScale(1,1)
	BlockFrame.Selectable = false
	BlockFrame.Selected = false
	BlockFrame.Parent = BlockGui
	BlockGui.Enabled = false
	BlockGui.Parent = GUIParent
	BlockInputs = function()
		BlockGui.Enabled = true
	end
	UnblockInputs = function()
		BlockGui.Enabled = false
	end
	
	CursorHolder = Instance.new("ScreenGui")
    CursorHolder.Name = "TasabilityCursor"
    CursorHolder.ZIndexBehavior = Enum.ZIndexBehavior.Global  
    CursorHolder.IgnoreGuiInset = true
    CursorHolder.ResetOnSpawn = false
    CursorHolder.DisplayOrder = 999999  
    CursorHolder.Parent = game:GetService("CoreGui")  
	
	Cursor.Name = "Cursor"
	Cursor.BackgroundTransparency = 1
	Cursor.ZIndex = 10000
	Cursor.Parent = CursorHolder
	
	Resolution = workspace.CurrentCamera.ViewportSize
	
	SetCursor = function(CursorName)
		local CursorData = Cursors[CursorName]
		if CursorData then
			CursorIcon = CursorData.Icon
			CursorSize = CursorData.Size
			CursorOffset = CursorData.Offset
		end
	end
	
	-- Initialize cursor
	SetCursor("ArrowFarCursor")
end



-- AHK Functions
local IsInstalled -- IsInstalled() -> bool
local SendSignal -- SendSignal(Signal) -> nil
do
	IsInstalled = function()
		return isfolder(AHKConnectionFolderPath)
	end
	SendSignal = function(Signal)
		if IsInstalled() then
			writefile(AHKConnectionRequestPath,Signal)
		else
			ConsoleMessage("AHK folder not found")
		end
	end
end





local Freeze 


-- Replay Functions
local ReplayEncode -- ReplayEncode(Table) -> string
local RecordReplay -- RecordReplay() -> nil [Event]
local StartRecording -- StartRecording() -> nil
local StopRecording -- StopRecording() -> nil
local SaveRecording -- SaveRecording() -> nil
local DiscardRecording -- DiscardRecording() -> nil

local StartReading -- StartReading() -> nil

local GetCheckpoint -- GetCheckpoint(CheckpointNumber?) -> number
local SetCheckpoint -- SetCheckpoint(FrameIndex?) -> nil

local GotoFrame -- GotoFrame(Index) -> nil
do
	GetReplayFile = function()
    if not isfolder(string.split(FolderPath,"/")[1]) then
        makefolder(string.split(FolderPath,"/")[1])
    end
    if not isfolder(FolderPath) then
        makefolder(FolderPath)
    end
    if not isfile(ReplayPath) then
        writefile(ReplayPath,ReplayFileBeginning)
        return ReplayFileBeginning
    end
    return readfile(ReplayPath)
    end

	ReplayEncode = function(Table)
		ConsoleMessage("Encoding "..tostring(#Table).." frames")
		local StartTick = tick()
		local Encoded = json.encode(Table)
		ConsoleMessage("Done encoding in",RoundNumber(tick()-StartTick,2),"seconds")
		-- Stamp the capture rate next to the frames. Only a file built entirely from this
		-- session's recordings can carry a measured rate; a loaded file keeps whatever rate it
		-- came with, and a slow-motion take keeps the nominal rate because its frames are already
		-- on the normal-time timeline.
		local Rate = SpeedHack.Rate
		local RateValue = FPS
		if not Rate.Scaled and not Rate.Loaded and Rate.Count >= 8 and Rate.Sum > 0
			and Rate.Session >= #Table then
			local Measured = Rate.Count / Rate.Sum
			if Measured >= 1 and Measured <= 1000 then
				RateValue = Measured
			end
		end
		PlaybackCtl.SavedRate = RateValue
		return ReplayFileBeginning..Encoded..",\"FPS\":"..string.format("%.3f", RateValue)..ReplayFileEnding
	end
-- TAS4 / TAS5 / TASABILITY_JSON3 / TASABILITY_JSON2 replay decoder (ported from the newer Tasability build, decode only)
PlaybackCtl.Codec = (function()
	local Codec = {}
	local LastYield = tick()

	local function Yield(Force)
		if Force or tick() - LastYield >= 0.004 then
			if coroutine.isyieldable and coroutine.isyieldable() then
				RunService.Heartbeat:Wait()
			end
			LastYield = tick()
		end
	end

	local function ReadU(data, pos)
		local n, shift = 0, 0
		local len = #data
		while pos <= len do
			local b = string.byte(data, pos)
			pos = pos + 1
			n = n + (b % 128) * (2 ^ shift)
			if b < 128 then return n, pos end
			shift = shift + 7
			if shift > 49 then error("TAS4 varint too large") end
		end
		error("TAS4 truncated varint")
	end

	local function ReadString(data, pos)
		local len
		len, pos = ReadU(data, pos)
		local last = pos + len - 1
		if last > #data then error("TAS4 truncated string") end
		return string.sub(data, pos, last), last + 1
	end

	local function ReadDouble(data, pos)
		local value, nextPos = string.unpack("<d", data, pos)
		return value, nextPos
	end

	-- Exact IEEE-754 delta: XOR of the 64-bit representation
	local function ReadDoubleDelta(data, pos, previous)
		local dlo, dhi
		dlo, pos = ReadU(data, pos)
		dhi, pos = ReadU(data, pos)
		local plo, phi = 0, 0
		if previous ~= nil then
			plo, phi = string.unpack("<I4I4", string.pack("<d", previous))
		end
		local raw = string.pack("<I4I4", bit32.bxor(dlo, plo), bit32.bxor(dhi, phi))
		local value = string.unpack("<d", raw)
		return value, pos
	end

	local function ReadSparse(data, pos, previous, count)
		local mask
		mask, pos = ReadU(data, pos)
		local values = {}
		for i = 1, count do
			local bit = math.floor(mask / (2 ^ (i - 1))) % 2
			if bit == 1 then
				values[i], pos = ReadDoubleDelta(data, pos, previous and previous[i] or nil)
			elseif previous then
				values[i] = previous[i]
			else
				error("TAS4 sparse field missing initial component")
			end
		end
		return values, pos
	end

	local function Clone(v)
		if type(v) ~= "table" then return v end
		local c = {}
		for j = 1, #v do c[j] = Clone(v[j]) end
		return c
	end

	local function Tas4Decode(data)
		local pos = 6
		local version = string.byte(data, 5)
		if version ~= 1 then error("unsupported TAS4 version "..tostring(version)) end
		local replayFPS, frameCount
		replayFPS, pos = ReadU(data, pos)
		frameCount, pos = ReadU(data, pos)

		local function ReadDict()
			local count
			count, pos = ReadU(data, pos)
			local list = {}
			for i = 1, count do list[i], pos = ReadString(data, pos) end
			return list
		end
		local animList = ReadDict()
		local poseList = ReadDict()
		local inputList = ReadDict()

		local Replay = {}
		local prevCFrame1, prevCFrame7, prevV3_5, prevV3_6, prevV2_11
		local prevN3, prevN8
		local prevObjects = {}

		local function ReadEvents()
			local count
			count, pos = ReadU(data, pos)
			local events = {}
			for i = 1, count do
				local id
				id, pos = ReadU(data, pos)
				events[i] = inputList[id] or ""
			end
			return events
		end

		for i = 1, frameCount do
			Yield(false)
			local tag = string.byte(data, pos)
			pos = pos + 1
			if tag == nil then error("TAS4 truncated data at frame "..tostring(i)) end
			if tag == 0 then
				Replay[i] = 0
			elseif tag == 1 then
				Replay[i] = 1
			elseif tag == 3 then
				local previous = Replay[i - 1]
				if type(previous) ~= "table" then error("TAS4 repeat frame without previous table at "..tostring(i)) end
				Replay[i] = Clone(previous)
			elseif tag == 2 then
				local Frame = {}
				Frame[1], pos = ReadSparse(data, pos, prevCFrame1, 12)
				prevCFrame1 = Frame[1]
				local animCount
				animCount, pos = ReadU(data, pos)
				Frame[2] = {}
				for j = 1, animCount do
					local id, transition
					id, pos = ReadU(data, pos)
					transition, pos = ReadDouble(data, pos)
					Frame[2][j] = {animList[id] or "", transition}
				end
				local changed = string.byte(data, pos)
				pos = pos + 1
				if changed == 1 then
					Frame[3], pos = ReadDoubleDelta(data, pos, prevN3)
					prevN3 = Frame[3]
				else
					Frame[3] = prevN3
				end
				if Frame[3] == nil then Frame[3] = 0; prevN3 = 0 end
				Frame[4], pos = ReadU(data, pos)
				Frame[5], pos = ReadSparse(data, pos, prevV3_5, 3)
				prevV3_5 = Frame[5]
				Frame[6], pos = ReadSparse(data, pos, prevV3_6, 3)
				prevV3_6 = Frame[6]
				Frame[7], pos = ReadSparse(data, pos, prevCFrame7, 12)
				prevCFrame7 = Frame[7]
				changed = string.byte(data, pos)
				pos = pos + 1
				if changed == 1 then
					Frame[8], pos = ReadDoubleDelta(data, pos, prevN8)
					prevN8 = Frame[8]
				else
					Frame[8] = prevN8
				end
				if Frame[8] == nil then Frame[8] = 0; prevN8 = 0 end
				local poseId
				poseId, pos = ReadU(data, pos)
				Frame[9] = poseList[poseId] or ""
				local flags = string.byte(data, pos)
				pos = pos + 1
				Frame[10] = (flags % 2 == 1) and 1 or 0
				Frame[11], pos = ReadSparse(data, pos, prevV2_11, 2)
				prevV2_11 = Frame[11]
				local Began = ReadEvents()
				local Ended = ReadEvents()
				Frame[12] = {Began, Ended}

				local objectCount
				objectCount, pos = ReadU(data, pos)
				Frame[13] = {}
				local lastId = 0
				for j = 1, objectCount do
					Yield(false)
					local deltaId
					deltaId, pos = ReadU(data, pos)
					local id = lastId + deltaId
					lastId = id
					local key = tostring(id)
					local mode = string.byte(data, pos)
					pos = pos + 1
					if mode == 0 then
						local previous = prevObjects[key]
						if not previous then error("TAS4 object repeat without previous state for "..key) end
						Frame[13][key] = previous
					else
						local components
						components, pos = ReadSparse(data, pos, prevObjects[key], 12)
						prevObjects[key] = components
						Frame[13][key] = components
					end
				end
				Replay[i] = Frame
			else
				error("TAS4 unknown frame tag "..tostring(tag))
			end
		end
		return Replay, replayFPS
	end

	local function Tas5Decompress(data)
		local version = string.byte(data, 5)
		local flags = string.byte(data, 6)
		if version ~= 1 then error("unsupported TAS5 version "..tostring(version)) end
		local rawSize, pos = ReadU(data, 7)
		local payload = string.sub(data, pos)
		if flags == 0 then
			if #payload ~= rawSize then error("TAS5 raw payload size mismatch") end
			return payload
		end
		if flags ~= 1 then error("unsupported TAS5 compression flags "..tostring(flags)) end
		local ok, service = pcall(function() return game:GetService("EncodingService") end)
		if not ok or not service or type(buffer) ~= "table" or not Enum or not Enum.CompressionAlgorithm or not Enum.CompressionAlgorithm.Zstd then
			error("TAS5 Zstd decoder unavailable in this executor")
		end
		local ok2, raw = pcall(function()
			local out = service:DecompressBuffer(buffer.fromstring(payload), Enum.CompressionAlgorithm.Zstd)
			return buffer.tostring(out)
		end)
		if not ok2 or type(raw) ~= "string" then error("TAS5 Zstd decode failed: "..tostring(raw)) end
		if #raw ~= rawSize then error("TAS5 decompressed size mismatch") end
		return raw
	end

	local function DecodeBinary(data)
		if string.sub(data, 1, 4) == "TAS5" then
			data = Tas5Decompress(data)
		end
		return Tas4Decode(data)
	end

	-- Base64: use the executor's native function when there is one, otherwise a Lua fallback
	local Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local DecodeMap = {}
	for i = 1, 64 do DecodeMap[string.byte(Alphabet, i)] = i - 1 end

	local function NativeBase64(Data)
		local Candidates = {
			function() return crypt.base64decode(Data) end,
			function() return crypt.base64.decode(Data) end,
			function() return base64_decode(Data) end,
			function() return base64decode(Data) end,
			function() return base64.decode(Data) end,
		}
		for _, Fn in ipairs(Candidates) do
			local ok, Result = pcall(Fn)
			if ok and type(Result) == "string" and string.sub(Result, 1, 3) == "TAS" then
				return Result
			end
		end
		return nil
	end

	local function LuaBase64(Data)
		Data = string.gsub(Data, "[^%w%+/=]", "")
		if #Data % 4 ~= 0 then error("invalid base64 length") end
		local pad = 0
		if string.sub(Data, -1) == "=" then
			pad = 1
			if string.sub(Data, -2, -2) == "=" then pad = 2 end
		end
		local out = {}
		local len = #Data
		local i = 1
		while i <= len do
			local last = math.min(i + 2999, len) -- 3000 chars per block (multiple of 4)
			local buf = {}
			local n = 0
			for j = i, last, 4 do
				local a, b, c, d = string.byte(Data, j, j + 3)
				local v = (DecodeMap[a] or 0) * 262144 + (DecodeMap[b] or 0) * 4096 + (DecodeMap[c] or 0) * 64 + (DecodeMap[d] or 0)
				n = n + 1
				buf[n] = string.char(math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
			end
			out[#out + 1] = table.concat(buf)
			i = last + 1
			Yield(false)
		end
		local result = table.concat(out)
		if pad > 0 then result = string.sub(result, 1, #result - pad) end
		return result
	end

	local function Json2Decode(decoded)
		if type(decoded) ~= "table" or type(decoded.Replay) ~= "table" then
			error("invalid TASABILITY JSON2 replay")
		end
		local replay = {}
		local function UnpackCO(list)
			local result = {}
			if type(list) ~= "table" then return result end
			local index, lastId = 1, 0
			while index <= #list do
				local deltaId = tonumber(list[index]) or 0
				index = index + 1
				local id = lastId + deltaId
				lastId = id
				local components = {}
				for j = 1, 12 do
					components[j] = list[index] or 0
					index = index + 1
				end
				result[tostring(id)] = components
			end
			return result
		end
		local previousFrame = nil
		for _, item in ipairs(decoded.Replay) do
			Yield(false)
			if item == 0 or item == 1 then
				replay[#replay + 1] = item
				previousFrame = nil
			elseif type(item) == "table" and item[1] == 3 and #item == 2 then
				local count = math.max(0, math.floor(tonumber(item[2]) or 0))
				if not previousFrame then error("repeat frame without previous frame") end
				for _ = 1, count do
					local r = {}
					for k = 1, 11 do r[k] = previousFrame[k] end
					r[2] = {}
					r[12] = {{}, {}}
					r[13] = {}
					replay[#replay + 1] = r
				end
			elseif type(item) == "table" then
				local frame = {}
				for i = 1, 12 do frame[i] = item[i] end
				frame[13] = UnpackCO(item[13])
				replay[#replay + 1] = frame
				previousFrame = frame
			else
				replay[#replay + 1] = 0
				previousFrame = nil
			end
		end
		return replay, tonumber(decoded.FPS)
	end

	-- Returns handled, replay, fps.
	-- handled == false: not one of the newer formats, use the old decoder.
	-- handled == true and replay == nil: newer format but it failed (the reason is printed).
	Codec.Decode = function(String)
		local Head = string.sub(String, 1, 64)
		local Magic = string.sub(Head, 1, 4)
		local StartTick = tick()

		if Magic == "TAS4" or Magic == "TAS5" then
			ConsoleMessage("Decoding "..Magic.." ("..tostring(#String).." bytes)")
			local ok, Replay, ReplayFPS = pcall(DecodeBinary, String)
			if not ok then
				ConsoleMessage(Magic.." decode failed:", tostring(Replay))
				return true, nil
			end
			ConsoleMessage("Decoded "..tostring(#Replay).." frames in "..tostring(RoundNumber(tick() - StartTick, 2)).." seconds")
			return true, Replay, ReplayFPS
		end

		if not string.find(Head, "^%s*{") then
			return false
		end

		if string.find(String, '"TASABILITY_JSON3"', 1, true) then
			local Data = string.match(String, '"Data"%s*:%s*"([^"]*)"')
			if not Data then
				return false -- older JSON3 files that hold a plain Replay table
			end
			ConsoleMessage("Decoding TASABILITY_JSON3 ("..tostring(#Data).." base64 characters)")
			if string.find(Data, "\\", 1, true) then
				Data = string.gsub(Data, "\\/", "/")
			end
			local ok, Binary = pcall(function()
				return NativeBase64(Data) or LuaBase64(Data)
			end)
			if not ok then
				ConsoleMessage("JSON3 base64 decode failed:", tostring(Binary))
				return true, nil
			end
			Data = nil
			local ok2, Replay, ReplayFPS = pcall(DecodeBinary, Binary)
			if not ok2 then
				ConsoleMessage("JSON3 binary decode failed:", tostring(Replay))
				return true, nil
			end
			local HeaderFPS = tonumber(string.match(String, '"FPS"%s*:%s*([%d%.]+)'))
			local HeaderFrames = tonumber(string.match(String, '"Frames"%s*:%s*(%d+)'))
			if HeaderFrames and HeaderFrames ~= #Replay then
				ConsoleMessage("Warning: file says "..tostring(HeaderFrames).." frames but "..tostring(#Replay).." were decoded")
			end
			ConsoleMessage("Decoded "..tostring(#Replay).." frames in "..tostring(RoundNumber(tick() - StartTick, 2)).." seconds")
			return true, Replay, HeaderFPS or ReplayFPS
		end

		if string.find(String, '"TASABILITY_JSON2"', 1, true) then
			local ok, Replay, ReplayFPS = pcall(function()
				return Json2Decode(json.decode(String))
			end)
			if not ok then
				ConsoleMessage("JSON2 decode failed:", tostring(Replay))
				return true, nil
			end
			ConsoleMessage("Decoded "..tostring(#Replay).." frames (JSON2) in "..tostring(RoundNumber(tick() - StartTick, 2)).." seconds")
			return true, Replay, ReplayFPS
		end

		return false
	end

	return Codec
end)()

	ReplayDecode = function(String)
		if type(String) ~= "string" then
			ConsoleMessage("Replay file could not be read")
			return
		end
		-- Newer formats: TAS4 / TAS5 binary, TASABILITY_JSON3 (base64 + TAS4) and TASABILITY_JSON2
		do
			local Handled, DecodedReplay, DecodedFPS = PlaybackCtl.Codec.Decode(String)
			if Handled then
				return DecodedReplay, DecodedFPS
			end
		end
		-- Strip UTF-8 BOM and surrounding whitespace
		String = string.gsub(String,"^\239\187\191","")
		String = string.gsub(String,"^%s+","")
		String = string.gsub(String,"%s+$","")
		if String == "" or String == ReplayFileBeginning or String == ReplayFileBeginning..ReplayFileEnding then
			ConsoleMessage("Nothing to read (replay file is empty - record and Save first)")
			return
		end
		ConsoleMessage("Decoding "..tostring(#String).." characters")
		local StartTick = tick()
		local ok, Decoded = pcall(json.decode,String)
		if not ok and string.sub(String,1,#ReplayFileBeginning) == ReplayFileBeginning and string.sub(String,-1) ~= ReplayFileEnding then
			-- File may have been cut off before the closing brace; try to repair
			ok, Decoded = pcall(json.decode,String..ReplayFileEnding)
		end
		if not ok then
			ConsoleMessage("JSON error:",tostring(Decoded))
			return
		end
		ConsoleMessage("Done decoding in",RoundNumber(tick()-StartTick,2),"seconds")
		if type(Decoded) == "table" then
			local List
			if type(Decoded.Replay) == "table" then
				List = Decoded.Replay
			elseif #Decoded > 0 then
				List = Decoded -- file is a bare list of frames
			end
			if List then
				for _, Frame in ipairs(List) do
					if type(Frame) == "table" then
						if type(Frame[2]) ~= "table" then Frame[2] = {} end
						if type(Frame[3]) ~= "number" then Frame[3] = 1 end
						if Frame[9] == nil then Frame[9] = "Standing" end
						if type(Frame[12]) ~= "table" then Frame[12] = {} end
						if type(Frame[12][1]) ~= "table" then Frame[12][1] = {} end
						if type(Frame[12][2]) ~= "table" then Frame[12][2] = {} end
					end
				end
				return List, tonumber(Decoded.FPS)
			end
		end
		ConsoleMessage("Replay file has no 'Replay' data")
		return
	end
	
	
	RecordReplay = function()
		ConsoleMessage("Waiting for input")
		if Writing then
			ConsoleMessage("Recording stopped")
			StopRecording()
			return
		end
		SetColorCodeFrame("WaitingForInput")
		WaitForInput()
		StartRecording()
		ConsoleMessage("Recording started")
	end
	StartRecording = function()
		if not Reading then
		    CO.Init()
			SetColorCodeFrame("Recording")
			SpeedHack.Accumulator = 1 -- record the first tick right away
			SpeedHack.ClearPending()
			-- Reconcile the tape's open keys against the keyboard before the first new frame:
			-- a key released while recording was stopped (a still, or a keyup lost to focus)
			-- otherwise stays pressed in the tape, and playback holds it down until it ends.
			local Live, LiveOK = {}, false
			pcall(function()
				for _, Input in ipairs(UserInputService:GetKeysPressed()) do
					local Name = string.split(tostring(Input.KeyCode), ".")[3]
					if Name and not InputBlacklist[Name] then Live[Name] = true end
				end
				for _, Input in ipairs(UserInputService:GetMouseButtonsPressed()) do
					if Input.UserInputType == Enum.UserInputType.MouseButton1 then
						Live["b1"] = true
					elseif Input.UserInputType == Enum.UserInputType.MouseButton2 then
						Live["b2"] = true
					end
				end
				LiveOK = true
			end)
			-- The tape itself is the truth for what is open at the resume point: a still can
			-- rewind, so the set from before the freeze cannot be trusted as-is. A stopped
			-- segment waiting in RecordingTable is part of the tape the next frame extends.
			local Open = {}
			local Tapes = {ReplayTable, RecordingTable}
			for _, Tape in ipairs(Tapes) do
				for Index = 1, #Tape do
					local Frame = Tape[Index]
					local Events = type(Frame) == "table" and Frame[12]
					if type(Events) == "table" then
						for _, Name in ipairs(Events[1] or {}) do
							if Name ~= "u" and Name ~= "d" and not InputBlacklist[Name] then
								Open[Name] = true
							end
						end
						for _, Name in ipairs(Events[2] or {}) do
							Open[Name] = nil
						end
					end
				end
			end
			SpeedHack.OpenKeys = Open
			if LiveOK then
				for Name in pairs(Open) do
					if not Live[Name] then
						table.insert(SpeedHack.PendingEnded, Name)
						Open[Name] = nil
					end
				end
				for Name in pairs(Live) do
					if not Open[Name] then
						table.insert(SpeedHack.PendingBegan, Name)
						Open[Name] = true
					end
				end
				SpeedHack.HeldInputs = Live
			else
				-- the client would not report the keyboard: trust the tape's own open set
				local Held = {}
				for Name in pairs(Open) do Held[Name] = true end
				SpeedHack.HeldInputs = Held
			end
			local Rate = SpeedHack.Rate
			Rate.Prev = nil -- the gap across a stop is not a sample of the capture rate
			if #ReplayTable == 0 and #RecordingTable == 0 then
				-- a file started from nothing: measure its rate from the first frame
				Rate.Sum, Rate.Count, Rate.Session, Rate.Loaded = 0, 0, 0, false
				PlaybackCtl.FileFPS = nil
			end
			-- continue the timeline of whatever is already recorded so a freeze/resume or an
			-- appended recording keeps monotonic timestamps for the speed optimizer
			local LastFrame = RecordingTable[#RecordingTable] or ReplayTable[#ReplayTable]
			SpeedHack.NormalTime = (type(LastFrame) == "table" and tonumber(LastFrame[14])) or 0
            if SpeedHack.Enabled and SpeedHack.Speed < 0.999 then
				ConsoleMessage("Slow-mo recording at "..string.format("%.2f", SpeedHack.Speed).."x; the replay will play at normal speed")
			end
			Writing = true
		end
	end
	StopRecording = function()
		if not Reading then
			if Writing then
				-- Events queued this frame are drained here too. The heartbeat clears the
				-- queues, so a release sitting in one when recording stops would otherwise be
				-- lost - and a press with no release behind it stays lit on an input board for
				-- the rest of the replay.
				for _, Input in ipairs(InputBeganQueue) do
					table.insert(SpeedHack.PendingBegan, Input)
					if Input ~= "u" and Input ~= "d" and not InputBlacklist[Input] then
						SpeedHack.OpenKeys[Input] = true
					end
				end
				for _, Input in ipairs(InputEndedQueue) do
					table.insert(SpeedHack.PendingEnded, Input)
					SpeedHack.OpenKeys[Input] = nil
				end
				-- a key the tape still holds that the keyboard no longer has down (its keyup
				-- was swallowed) is released with the last frame; a key still physically down
				-- stays open across the seam, so a hold through a still is not broken
				for Name in pairs(SpeedHack.OpenKeys) do
					if not SpeedHack.HeldInputs[Name] then
						table.insert(SpeedHack.PendingEnded, Name)
						SpeedHack.OpenKeys[Name] = nil
					end
				end
				SpeedHack.FlushPending(RecordingTable[#RecordingTable])
			end
			Writing = false
		end
	end
	
	SaveToFile = function()
    -- the writer holds the newest frames until the take is closed; commit that buffer first,
    -- or Save writes a file that ends before the last thing the player recorded. The take is
    -- left running: committing frames does not need it closed, and stopping here would cut a
    -- seam into the recording every time the player saves
    if not Reading then
        SaveRecording()
    end
    local ReplayEncoded = ReplayEncode(ReplayTable)
    writefile(ReplayPath,ReplayEncoded)
    ReplayNeedsReload = false -- We just saved, so ReplayTable is already up to date
    LastLoadedPath = ReplayPath
    -- The file now carries the rate it was captured at; use it here too, so record -> save ->
    -- play does not need a reload to get the speed right.
    local Saved = PlaybackCtl.SavedRate
    if Saved and Saved >= 1 then
        local Was = FPS
        FPS = Saved
        PlaybackCtl.FileFPS = Saved
        if math.abs(Saved - Was) > 0.05 then
            ConsoleMessage("Capture rate: "..RoundNumber(Saved, 2).." fps (configured "
                ..RoundNumber(Was, 2)..")")
        end
    end
    ConsoleMessage("Saved to file (cached in memory)")
end
	
	SaveRecording = function()
    if #RecordingTable > 0 then
        local old = #ReplayTable
        for _,Frame in pairs(RecordingTable) do
            table.insert(ReplayTable,Frame)
        end
        RecordingTable = {}
        -- ReplayTable is in memory for the file it came from; after a path switch the new file
        -- still has to be decoded, so the dirty flag only clears when the tape matches the path
        if ReplayPath == LastLoadedPath then
            ReplayNeedsReload = false
        end
        ConsoleMessage("Saved recording to memory")
    end
end
	DiscardRecording = function()
		if #RecordingTable > 0 then
			RecordingTable = {}
			SpeedHack.ClearPending()
			SpeedHack.OpenKeys = {}
			ConsoleMessage("Discarded")
		end
	end
	StartReading = function()
    if not Reading then
        -- a played file is not this recorder's tape: its open-key state starts empty, and the
        -- first recording after a load reconciles against the real keyboard
        SpeedHack.OpenKeys = {}
        local Reloaded = false
        -- Only decode if we need to reload OR if path changed
        if ReplayNeedsReload or ReplayPath ~= LastLoadedPath then
            if PlaybackCtl.Decoding then
                ConsoleMessage("Still decoding the replay, please wait")
                return
            end
            PlaybackCtl.Decoding = true
            -- read and decode under one pcall: a filesystem error used to leave the latch set
            -- for the rest of the session, and every later play answered "still decoding"
            local okDecode, decoded, decodedFPS = pcall(function()
                return ReplayDecode(GetReplayFile())
            end)
            PlaybackCtl.Decoding = false
            if not okDecode then
                ConsoleMessage("Decode error:", tostring(decoded))
                decoded = nil
            end
            Reloaded = decoded ~= nil
            if decoded then
                ReplayTable = decoded
                SpeedHack.Rate.Loaded = true
                PlaybackCtl.FileFPS = tonumber(decodedFPS) or nil
                ReplayNeedsReload = false
                LastLoadedPath = ReplayPath
                ConsoleMessage("Decoded replay from file")
            else
                ReplayTable = {}
                SetColorCodeFrame("Idle")
                ConsoleMessage("Failed to decode replay")
                return
            end
        else
            ConsoleMessage("Using cached replay (no decode needed)")
        end
        
        if ReplayTable and #ReplayTable > 0 then
            -- Unfreeze without recording: Freeze(false) would truncate everything after the
            -- scrolled-to frame and start a recording, and the writer would then keep appending
            -- frames while the replay is being read.
            Freeze(false, true)
            StopRecording()
            -- a take that was still open when play was pressed has to reach the timeline, or
            -- the replay that starts now silently drops everything recorded this session; a
            -- freshly decoded file is a different tape, so its pending take is not merged in
            if not Reloaded and #RecordingTable > 0 then
                SaveRecording()
            end
            AnimateDisabled = true
            -- Playback rate: a rate stamped into the file wins. A file saved before rates were
            -- stamped is measured from its own velocity channel, which is in studs per second and
            -- therefore independent of the frame rate; only then does the configured FPS stand.
            -- Without this a run captured at 120 under a 144 cap replays 20% fast, and every
            -- jump and step lands a fifth early.
            local RateNow = PlaybackCtl.FileFPS
            if not (RateNow and RateNow >= 1) then
                local LastFrame = ReplayTable[#ReplayTable]
                -- Frame[14] means a normal-time timeline (slow-motion capture): its deltas are
                -- already normalised, so its rate is the configured one and is never guessed.
                if type(LastFrame) ~= "table" or LastFrame[14] == nil then
                    RateNow = PlaybackCtl.EstimateFPS(ReplayTable)
                    if RateNow then
                        ConsoleMessage("Capture rate measured from the replay's own motion: "
                            ..RoundNumber(RateNow, 1).." fps")
                    end
                end
            end
            if RateNow and RateNow >= 1 and math.abs(RateNow - FPS) > 0.01 then
                ConsoleMessage("Playback rate: "..RoundNumber(RateNow, 1).." fps (configured "
                    ..RoundNumber(FPS, 1)..")")
                FPS = RateNow
            end
            -- Gravity off keeps every loose part in the scene frozen along with the body. That is
            -- the safe default - nothing can push the rig. With world physics on, the sim stays
            -- alive (falling props, moving scenery) and the root write alone holds the body.
            if not PlaybackCtl.WorldPhys then
                Workspace.Gravity = 0
                -- remember that this build owns the value now, so the hand-back never
                -- overwrites a gravity the game itself set while playback was running
                PlaybackCtl.GravityOwned = true
            end
            ReplayTableIndex = 1
            CO.RebuildFromAttributes()
            CO.AnchorAll() 
            BlockInputs()
            Paused = false
            PlaybackCtl.Snapshot = nil
            -- a previous run that died outside its own cleanup can leave a synthetic key down;
            -- sweeping here means this run starts from a clean keyboard, not a stuck one
            ReleaseAllPlaybackKeys()
            -- Seed the view with what the player is looking at and release the engine's mouse
            -- lock before the first playback frame: the lock fights the recorded mouse every
            -- frame, and a stale seed would jump the camera on frame one.
            local Cam = workspace.CurrentCamera
            -- Recover from a session where an older build left the camera Scriptable: the
            -- module has to be alive for first person to hide the local body.
            if Cam.CameraType == Enum.CameraType.Scriptable then
                pcall(function()
                    Cam.CameraType = Enum.CameraType.Custom
                end)
            end
            CameraCFrame = Cam.CFrame
            -- Settle into the recorded view instead of cutting to it, but only when the run
            -- starts near where the player is already looking: a short pan reads as a head turn,
            -- while a long swing would eat the first frames of the run.
            PlaybackCtl.CamIntro = nil
            local First = ReplayTable[1]
            if type(First) == "table" and type(First[7]) == "table" then
                local FirstCam = FastTableToCFrame(First[7])
                local Sweep = math.deg(math.acos(math.clamp(
                    Cam.CFrame.LookVector:Dot(FirstCam.LookVector), -1, 1)))
                if Sweep <= 50 and (FirstCam.Position - Cam.CFrame.Position).Magnitude <= 60 then
                    -- A fixed settle time turns a small correction and a half-turn at the same
                    -- speed, and the short one reads as a snap. Give the pan the time a head gives
                    -- it: barely anything for a few degrees, half a second for a big look-around.
                    PlaybackCtl.CamIntro = {
                        From     = Cam.CFrame,
                        Start    = tick(),
                        Duration = math.clamp(0.16 + Sweep * 0.008, 0.2, 0.55),
                    }
                end
            end
            -- Playback hands the engine lock back on stop; remember what the player actually had
            -- before it is released, because the tape's last frame is not their setting.
            PlaybackCtl.SyncShiftLock()
            PlaybackCtl.PrevShiftLock = ShiftLockEnabled
            pcall(function()
                shiftLock(false)
            end)
            -- the root orientation is part of the recording; stop the engine steering it
            if Humanoid then
                PlaybackCtl.PrevAutoRotate = Humanoid.AutoRotate
                Humanoid.AutoRotate = false
            end
            -- the engine's camera-relative yaw is switched off for the run and handed back on
            -- stop; per-frame shift lock re-enables it only where the recording had it
            PlaybackCtl.ClearLookAround()
            PlaybackCtl.HoldRotationType()
            PlaybackCtl.NeedsAnimSeed = true
            PlaybackCtl.RigRepairs = 0
            PlaybackCtl.RigRepairLogged = nil
            -- the previous run's last pose is not where this one starts
            InterpHRPPrev = nil
            InterpHRPTarget = nil
            PlaybackCtl.InterpCamPrev = nil
            PlaybackCtl.InterpCamTarget = nil
            PlaybackCtl.StepTick = nil
            -- the previous run's render head is not this run's playhead
            PlaybackCtl.AppliedIndex = nil
            PlaybackCtl.RenderPos = nil
            PlaybackCtl.RenderAt = nil
            PlaybackCtl.PaceLast = nil
            PlaybackCtl.PaceDebt = nil
            PlaybackCtl.CamShown = nil
            PlaybackCtl.SteppedAt = nil
            PlaybackCtl.ZoomPrev = nil
            PlaybackCtl.ZoomTarget = nil
            PlaybackCtl.ZoomShown = nil
            PlaybackCtl.CamBlend = nil
            PlaybackCtl.MouseLastLook = nil
            PlaybackCtl.MouseTravel = nil
            -- One recorded frame per heartbeat is only real time when the client actually runs at
            -- the recorded rate. Hold the cap there for the run and hand back the old one on stop,
            -- so a replay recorded at 144 fps does not crawl at whatever the client drifted to.
            local okCap, prevCap = pcall(function()
                return getfpscap and getfpscap() or nil
            end)
            PlaybackCtl.PrevFPSCap = okCap and prevCap or nil
            if setfpscap then
                pcall(setfpscap, FPS)
                ConsoleMessage("Playback locked to the recorded rate: "..RoundNumber(FPS, 0).." fps")
            end
            -- The torso is placed by the physics solve, never by the root write, so the solver's
            -- cadence decides how far behind the root it can sit. The client default is Adaptive,
            -- which picks 240, 120 or 60 Hz per assembly and can switch between them mid-run: the
            -- torso's solve then lands at irregular moments against a root that is written every
            -- render frame, and on a turn that mismatch reads as a shiver. Fixed runs every
            -- assembly at 240 Hz, so each root write is followed by full solves before the frame
            -- is drawn, at the same rate every time.
            PlaybackCtl.SteppingPrev = nil
            pcall(function()
                local TargetStep = PlaybackCtl.SteppingPref or Enum.PhysicsSteppingMethod.Fixed
                local CurrentStep = workspace.PhysicsSteppingMethod
                if CurrentStep ~= TargetStep then
                    PlaybackCtl.SteppingPrev = CurrentStep
                    workspace.PhysicsSteppingMethod = TargetStep
                end
            end)
            Reading = true
            SetColorCodeFrame("Reading")
            ConsoleMessage("Reading started")
            ConsoleMessage("Length: "..RoundNumber(#ReplayTable/FPS).." seconds")
        else
            ConsoleMessage("No replay data to read")
            SetColorCodeFrame("Idle")
        end
    else
        ConsoleMessage("You are already reading")
    end
end
	StopReading = function()
    if Reading then
        -- the run is over: hand the rig back to its motor before anything else touches it, so
        -- the last pose is reached with the character's own animation chain live again
        if PlaybackCtl.ReleaseRigLock then
            PlaybackCtl.ReleaseRigLock()
        end
        CO.RestoreAnchors()
        CO.Stop()
        UnblockInputs()
        Paused = false
        PlaybackCtl.Snapshot = nil
        ReleaseAllPlaybackKeys()
        pcall(function()
            for _, PartName in ipairs({"Head", "Torso", "HumanoidRootPart"}) do
                local Part = Character:FindFirstChild(PartName)
                if Part then Part.CanCollide = true end
            end
        end)
        AnimateDisabled = false
        if SpeedHack.HoldAnimations then
            SpeedHack.HoldAnimations(false)
        end
        -- Land on the recorded final pose instead of wherever the eased sample happened to be:
        -- the body is always a fraction of a gap behind its target, and handing control back
        -- mid-gap leaves the character short of the spot the recording says he reached.
        pcall(function()
            if Character and InterpHRPTarget and Character:FindFirstChild("HumanoidRootPart") then
                local Root = Character.HumanoidRootPart
                Root.CFrame = InterpHRPTarget
                -- the recorded velocity is still on the root at this point; handing control back
                -- with it would launch the character off the spot the replay just landed on
                Root.Velocity    = Vector3.zero
                Root.RotVelocity = Vector3.zero
            end
        end)
        -- Hand the camera over instead of dropping it. Releasing the hold while the recorded
        -- view is still on screen cuts to wherever the engine's mouse state sits, and that cut
        -- is the one frame that announces a recording stopping. Ease from the last shown sample
        -- to what the camera module writes, so the shot settles the way a hand would.
        if PlaybackCtl.CamShown then
            PlaybackCtl.CamBlend = {
                From     = PlaybackCtl.CamShown,
                Start    = tick(),
                Duration = 0.45,
            }
        end
        PlaybackCtl.CamIntro = nil
        Reading = false
        PlaybackCtl.ClearLookAround()
        PlaybackCtl.ReleaseCamera()
        -- the engine's lock was released at the start of the run; hand back the state the player
        -- had before it, never the tape's last frame - leaving the run's lock behind is what
        -- makes a replay stop with the body still turning with the camera
        local WantShiftLock = PlaybackCtl.PrevShiftLock
        PlaybackCtl.PrevShiftLock = nil
        if WantShiftLock ~= nil then
            SetShiftLockEnabled(WantShiftLock, true)
            pcall(function()
                shiftLock(WantShiftLock)
            end)
        else
            pcall(function()
                shiftLock(ShiftLockEnabled)
            end)
        end
        pcall(function()
            Character.Humanoid.JumpPower = DefaultJumpPower
            Character.Humanoid.WalkSpeed = DefaultWalkSpeed
            if PlaybackCtl.PrevAutoRotate ~= nil then
                Character.Humanoid.AutoRotate = PlaybackCtl.PrevAutoRotate
                PlaybackCtl.PrevAutoRotate = nil
            end
        end)
        -- The per-frame channel was the last writer, and the run left the camera in its final
        -- mode (the tool does not put the player's pre-run zoom back). Hand the setting over in
        -- the form that mode calls for - mouse-locked or first-person is camera-relative, free
        -- third person movement-relative - instead of the pre-run value: a locked mouse steering
        -- a movement-relative body reads as exactly the shifted drift this is here to prevent.
        local LiveLock = PlaybackCtl.LiveShiftLock()
        if LiveLock ~= nil then
            local PostZoom = GetZoom()
            PlaybackCtl.RestoreRotationType(false,
                LiveLock or (type(PostZoom) == "number" and PostZoom < 1))
        else
            PlaybackCtl.RestoreRotationType()
        end
        -- only hand gravity back when this build zeroed it for playback; with world physics on
        -- the live value belongs to the game and a startup snapshot must not overwrite it
        if PlaybackCtl.GravityOwned then
            Workspace.Gravity = DefaultGravity
            PlaybackCtl.GravityOwned = nil
        end
        InterpHRPPrev   = nil
        InterpHRPTarget = nil
        PlaybackCtl.InterpCamPrev   = nil
        PlaybackCtl.InterpCamTarget = nil
        PlaybackCtl.StepTick = nil
        PlaybackCtl.PaceLast = nil
        PlaybackCtl.PaceDebt = nil
        PlaybackCtl.CamShown = nil
        PlaybackCtl.SteppedAt = nil
        PlaybackCtl.ZoomPrev = nil
        PlaybackCtl.ZoomTarget = nil
        PlaybackCtl.ZoomShown = nil
        PlaybackCtl.MouseLastLook = nil
        -- the run leaves the cursor where the tape travelled to; hand it back centred the way
        -- an idle session keeps it, so the free mouse does not resume at a screen edge
        if PlaybackCtl.MouseTravel then
            local Travel = PlaybackCtl.MouseTravel
            PlaybackCtl.MouseTravel = nil
            -- The injected steps also turned the live camera module, and the hand-back blend
            -- settles on wherever that module points. Giving the same travel back cancels the
            -- drift, so a stop still lands on the heading the player had before the run. The
            -- steps are chunked so no single relative move reaches the screen edge and gets
            -- clamped, which would swallow part of the correction; the absolute recentre
            -- between chunks feeds no relative input.
            if type(mousemoverel) == "function" then
                local Steps = 0
                while (Travel.PixelsX ~= 0 or Travel.PixelsY ~= 0) and Steps < 200 do
                    Steps = Steps + 1
                    local StepX = math.clamp(Travel.PixelsX, -700, 700)
                    local StepY = math.clamp(Travel.PixelsY, -700, 700)
                    mousemoverel(StepX, StepY)
                    Travel.PixelsX = Travel.PixelsX - StepX
                    Travel.PixelsY = Travel.PixelsY - StepY
                    if Travel.PixelsX ~= 0 or Travel.PixelsY ~= 0 then
                        local Viewport = workspace.CurrentCamera.ViewportSize
                        local Inset = GuiService:GetGuiInset()
                        MoveMouseAbs((Viewport.X / 2) - Inset.X, (Viewport.Y / 2) - Inset.Y)
                    end
                end
            end
            local Viewport = workspace.CurrentCamera.ViewportSize
            local Inset = GuiService:GetGuiInset()
            MoveMouseAbs((Viewport.X / 2) - Inset.X, (Viewport.Y / 2) - Inset.Y)
        end
        CO.ClearInterpolation()
        if PlaybackCtl.PrevFPSCap then
            if setfpscap then
                pcall(setfpscap, PlaybackCtl.PrevFPSCap)
            end
            PlaybackCtl.PrevFPSCap = nil
        end
        if PlaybackCtl.SteppingPrev then
            pcall(function()
                workspace.PhysicsSteppingMethod = PlaybackCtl.SteppingPrev
            end)
            PlaybackCtl.SteppingPrev = nil
        end
        SetColorCodeFrame("Idle")
        ConsoleMessage("Reading stopped")
    else
        ConsoleMessage("You are not reading")
    end
end
end

-- Tasability functions
--local Freeze -- Freeze(NewFrozen) -> nil
do
	Freeze = function(NewFrozen, DoNotRecord)
    if Frozen ~= NewFrozen and not Reading then
        SeekDirection = 0
        if NewFrozen then
            Frozen = true
            StopRecording()
            SaveRecording()
            -- a pause that lands during a resume prologue takes the body back; the guard
            -- must not outlive it and swallow the first frame of the next recording
            PlaybackCtl.FirstFrameRecord = false
            FreezeFrame = #ReplayTable
            -- the tape can be scrolled or truncated between stills: force the sparse freeze
            -- index to rebuild against the tape this freeze will actually draw
            PlaybackCtl.FreezeIndexTape = nil
            -- the key readout was last written by the live recorder; a still draws its own
            PlaybackCtl.FreezeInputTape = nil
            ReleaseAllPlaybackKeys()
			CO.AnchorAll() 
            -- a fresh still starts on its recorded view, never on the last free camera
            PlaybackCtl.ClearLookAround()
            -- anchored: hold the recorded heading instead of letting the mouse swing the body
            PlaybackCtl.HoldRotationType()
            -- the still's frame bit only drives the cursor: remember the lock the player really
            -- has, so the unfreeze hands that state back instead of the tape's
            PlaybackCtl.SyncShiftLock()
            PlaybackCtl.FreezeShiftLock = ShiftLockEnabled
            -- a frozen frame is a still: park the track so the pose cannot creep between phase seeks
            if SpeedHack.HoldAnimations then
                SpeedHack.HoldAnimations(true)
            end
            SetColorCodeFrame("Frozen")
        else
			CO.RestoreAnchors()
            PlaybackCtl.ClearLookAround()
            -- The still's lock bit was display only, so the controller is still the player's own.
            -- The body leaves with the setting its live camera mode calls for - mouse-locked or
            -- first-person is camera-relative, free third person movement-relative - because a
            -- lock toggled or a zoom across the first-person line while the still was up has
            -- already moved the camera there, and the pre-freeze capture cannot describe a mode
            -- the player changed during the still.
            local LiveLock = PlaybackCtl.LiveShiftLock()
            if LiveLock ~= nil then
                local FreeZoom = GetZoom()
                PlaybackCtl.RestoreRotationType(false,
                    LiveLock or (type(FreeZoom) == "number" and FreeZoom < 1))
            else
                PlaybackCtl.RestoreRotationType()
            end
            if LiveLock ~= nil then
                if LiveLock ~= ShiftLockEnabled then
                    SetShiftLockEnabled(LiveLock, true)
                end
            elseif PlaybackCtl.FreezeShiftLock ~= nil then
                SetShiftLockEnabled(PlaybackCtl.FreezeShiftLock, true)
            end
            PlaybackCtl.FreezeShiftLock = nil
            -- leaving the still: the track gets its live rate back
            if SpeedHack.HoldAnimations then
                SpeedHack.HoldAnimations(false)
            end
            -- the still's rigid lock is a playback lock, not a rig state: give the motor the
            -- torso back the moment the freeze ends
            if PlaybackCtl.ReleaseRigLock then
                PlaybackCtl.ReleaseRigLock()
            end
            PlaybackCtl.ReleaseCamera()
            if DoNotRecord then
                Frozen = false
                SetColorCodeFrame("Idle")
            else
                for Index = #ReplayTable, FreezeFrame, -1 do
                    ReplayTable[Index] = nil
                end
                Frozen = false
                StartRecording()
                SetColorCodeFrame("Recording")
            end
        end
    end
end
end
-- Playback control: Pause / Unpause / Take over
do
	-- HappaTAS create-mode unpause. A frozen recording is paused on a frame; resuming has to
	-- leave from that frame with the recorded velocity and state already applied, cut the tape
	-- after it, and hold the jump state off through one simulated tick so the first live frame
	-- cannot start on an instant jump. Both the resume button and the frame-advance button run
	-- this same sequence: the advance button leaves the tool live and recording like a resume,
	-- and playback keeps running until the player pauses it again.
	local function FrozenStateAt(Index)
		local F = ReplayTable[Index]
		if type(F) == "table" then return tonumber(F[4]) end
		return nil
	end

	local function FrozenJumpedOffLadder(Index)
		if Index < 2 then return false end
		return FrozenStateAt(Index) == Enum.HumanoidStateType.Jumping.Value
			and FrozenStateAt(Index - 1) == Enum.HumanoidStateType.Climbing.Value
	end

	local function FrozenUnpause()
		if not Frozen or Reading or PlaybackCtl.Resuming then return end
		PlaybackCtl.Resuming = true
		task.spawn(function()
			local Ok, Err = pcall(function()
				-- the playhead is FreezeFrame, not the tape end: a still can be scrolled back
				-- before the resume, and HappaTAS cuts everything after the frame it is on
				local Index = math.floor(math.clamp(FreezeFrame, 0, #ReplayTable))
				-- markers (0 voided, 1 dead) are not frames the body can leave from; a scroll
				-- can land on one, so walk back to the last real frame and cut the marker
				while Index > 0 and type(ReplayTable[Index]) ~= "table" do
					Index -= 1
				end
				-- HappaTAS: a jump taken straight off a ladder is cut with the frame before it,
				-- so the jump is re-recorded from the ladder instead of replayed from the tape
				if Index > 1 and FrozenJumpedOffLadder(Index) then
					Index -= 1
				end
				-- RemoveCutFrames: everything after the frame being resumed from is replaced
				for Cut = #ReplayTable, Index + 1, -1 do
					ReplayTable[Cut] = nil
				end
				-- Freeze(false) drops the frame it was frozen on so the first recorded frame
				-- can replace it. HappaTAS keeps the resume frame and rewrites it, so aim the
				-- truncation one past the playhead and restore it after the unfreeze; the
				-- saved tape then starts with that frame plus the frames recorded after it.
				FreezeFrame = Index + 1
				-- The writer must not append a duplicate still while the prologue below runs;
				-- HappaTAS keeps the playhead on the resume frame through the same window.
				-- With no resume frame to rewrite, HappaTAS records the first frame instead.
				PlaybackCtl.FirstFrameRecord = type(ReplayTable[Index]) == "table"
				Freeze(false)
				FreezeFrame = Index
				local Frame = ReplayTable[Index]
				local Root = Character and Character:FindFirstChild("HumanoidRootPart")
				if type(Frame) == "table" then
					if Root then
						if type(Frame[5]) == "table" then
							Root.AssemblyLinearVelocity = TableToVector3(Frame[5])
						end
						if type(Frame[6]) == "table" then
							Root.AssemblyAngularVelocity = TableToVector3(Frame[6])
						end
					end
					if Humanoid and type(Frame[4]) == "number" then
						Humanoid:ChangeState(Frame[4])
					end
				end
				if Humanoid then
					Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
				end
				RunService.Heartbeat:Wait()
				RunService.RenderStepped:Wait()
				-- HappaTAS writes the simulated body back onto the frame it resumed from
				-- while the guard is up, so the seam is one body position, not two. The
				-- animation channels belong to that frame too; rewriting only the root
				-- left the saved seam replaying the pose it had before the resume.
				local Last = ReplayTable[Index]
				Root = Character and Character:FindFirstChild("HumanoidRootPart")
				if type(Last) == "table" and Root then
					Last[1] = RoundTable(CFrameToTable(Root.CFrame), RoundDigits)
					Last[3] = RoundNumber(currentAnimSpeed, RoundDigits)
					Last[9] = pose
					if Humanoid then Last[4] = Humanoid:GetState().Value end
				end
				if Humanoid then
					Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
				end
				PlaybackCtl.FirstFrameRecord = false
			end)
			if not Ok then
				PlaybackCtl.FirstFrameRecord = false
				if Humanoid then
					pcall(function()
						Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
					end)
				end
				ConsoleMessage("Unpause error:", tostring(Err))
				pcall(Freeze, true)
			end
			PlaybackCtl.Resuming = false
		end)
	end

	PlaybackCtl.Pause = function()
		-- HappaTAS debounces the next input for three frames after an unpause; the resume
		-- prologue owns the body until then, so a pause cannot cut through it
		if PlaybackCtl.Resuming then return end
		if not Reading then
			if Writing and not Frozen then
				Freeze(true) -- pause while recording = freeze
			else
				ConsoleMessage("Nothing to pause")
			end
			return
		end
		if Paused then
			ConsoleMessage("Already paused")
			return
		end
		Paused = true
		if SpeedHack.HoldAnimations then
			SpeedHack.HoldAnimations(true)
		end
		-- a look-around view ends with the pause that was hosting it
		PlaybackCtl.ClearLookAround()
		-- a paused replay is a still: the body keeps the recorded heading, not the mouse
		PlaybackCtl.HoldRotationType()
		-- Remember held keys so they can be pressed again on unpause
		PlaybackCtl.Snapshot = {}
		for Input, Code in pairs(PlaybackPressedKeys) do
			PlaybackCtl.Snapshot[Input] = Code
		end
		ReleaseAllPlaybackKeys()
		SetColorCodeFrame("Paused")
		ConsoleMessage("Paused at frame "..tostring(ReplayTableIndex))
	end

	PlaybackCtl.Unpause = function()
		if Frozen and not Reading then
			-- create-mode resume: HappaTAS's unpause sequence, not a plain unfreeze
			FrozenUnpause()
			return
		end
		if not Reading then
			ConsoleMessage("Nothing to unpause")
			return
		end
		if not Paused then
			ConsoleMessage("Not paused")
			return
		end
		Paused = false
		-- a look-around view is a paused view only; playback takes the camera back
		PlaybackCtl.ClearLookAround()
		-- a pause is not played back: the first frame after it starts a fresh interval instead
		-- of paying the pause's wall time as a burst of skipped frames
		PlaybackCtl.PaceLast = nil
		PlaybackCtl.PaceDebt = nil
		if SpeedHack.HoldAnimations then
			SpeedHack.HoldAnimations(false)
		end
		for Input, Code in pairs(PlaybackCtl.Snapshot or {}) do
			if Code == "b1" then
				mouse1press()
			elseif Code == "b2" then
				mouse2press()
			elseif type(Code) == "number" then
				keypress(Code)
			end
			PlaybackPressedKeys[Input] = Code
		end
		PlaybackCtl.Snapshot = nil
		SetColorCodeFrame("Reading")
		ConsoleMessage("Unpaused at frame "..tostring(ReplayTableIndex))
	end

	PlaybackCtl.Toggle = function()
		if Paused or (Frozen and not Reading) then
			PlaybackCtl.Unpause()
		else
			PlaybackCtl.Pause()
		end
	end

	-- Stop playback at the current frame, give control back and keep recording from there
	PlaybackCtl.TakeOver = function()
		if Frozen and not Reading then
			PlaybackCtl.Unpause()
			return
		end
		if not Reading then
			ConsoleMessage("Nothing to take over (not reading or frozen)")
			return
		end
		local Index = ReplayTableIndex
		StopReading()
		for i = #ReplayTable, Index, -1 do
			ReplayTable[i] = nil
		end
		RecordingTable = {}
		FreezeFrame = #ReplayTable
		StartRecording()
		ConsoleMessage("You took over at frame "..tostring(#ReplayTable)..", recording")
	end

	-- Frozen while recording: the same HappaTAS resume as Unpause, leaving the tool live and
	-- recording until the player pauses. While reading and paused: plays one replay frame.
	PlaybackCtl.Step = function()
		if Reading then
			if not Paused then
				ConsoleMessage("Pause first to step one frame")
				return
			end
			-- the stepped frame brings its recorded view back
			PlaybackCtl.ClearLookAround()
			PlaybackCtl.StepOnce = true
			return
		end
		if not Frozen then
			ConsoleMessage("Already recording")
			return
		end
		FrozenUnpause()
	end

	local function NearlyEqual(a, b, Eps)
		if type(a) == "number" and type(b) == "number" then
			return math.abs(a - b) <= Eps
		end
		if type(a) ~= type(b) then
			return false
		end
		if type(a) == "table" then
			for k, v in pairs(a) do
				if not NearlyEqual(v, b[k], Eps) then
					return false
				end
			end
			for k in pairs(b) do
				if a[k] == nil then
					return false
				end
			end
			return true
		end
		return a == b
	end

	local function RoundList(List, Digits)
		if type(List) ~= "table" then
			return
		end
		local Mult = 10 ^ Digits
		for i, v in ipairs(List) do
			if type(v) == "number" then
				local r = math.floor(v * Mult + 0.5) / Mult
				if r == 0 then r = 0 end -- gets rid of -0
				List[i] = r
			end
		end
	end

	-- Rounding + animation-call cleanup + trailing idle trim, shared by both optimizers.
	local function NormalizeReplay()
		for _, Frame in ipairs(ReplayTable) do
			if type(Frame) == "table" then
				-- 1. round noisy numbers
				RoundList(Frame[1], 5)
				RoundList(Frame[5], 4)
				RoundList(Frame[6], 4)
				RoundList(Frame[7], 4)
				RoundList(Frame[11], 1)
				if type(Frame[3]) == "number" then Frame[3] = math.floor(Frame[3] * 1000 + 0.5) / 1000 end
				if type(Frame[8]) == "number" then Frame[8] = math.floor(Frame[8] * 1000 + 0.5) / 1000 end
				-- 2. remove repeated identical animation calls inside one frame
				if type(Frame[2]) == "table" and #Frame[2] > 1 then
					local Clean = {}
					for _, Entry in ipairs(Frame[2]) do
						local Prev = Clean[#Clean]
						if not (Prev and Prev[1] == Entry[1] and Prev[2] == Entry[2]) then
							table.insert(Clean, Entry)
						end
					end
					Frame[2] = Clean
				end
			end
		end

		-- 3. cut identical idle frames at the end of the replay (never in the middle: that would shift timing)
		local function IsIdleCopy(Frame, Prev)
			if type(Frame) ~= "table" or type(Prev) ~= "table" then
				return false
			end
			if #(Frame[2] or {}) > 0 then
				return false
			end
			local Inputs = Frame[12]
			if Inputs and (#(Inputs[1] or {}) > 0 or #(Inputs[2] or {}) > 0) then
				return false
			end
			for Index = 1, 11 do
				if Index ~= 2 and not NearlyEqual(Frame[Index], Prev[Index], 1e-3) then
					return false
				end
			end
			return NearlyEqual(Frame[13], Prev[13], 1e-3)
		end
		while #ReplayTable > 2 and IsIdleCopy(ReplayTable[#ReplayTable], ReplayTable[#ReplayTable - 1]) do
			table.remove(ReplayTable)
		end
	end

	-- Shrinks the replay in memory (press Save afterwards to write the file). Only works while idle.
	PlaybackCtl.Optimize = function()
		if Reading or Writing or Frozen then
			ConsoleMessage("Optimize only works while idle (stop reading/recording and unfreeze first)")
			return
		end
		if PlaybackCtl.Optimizing then
			return
		end
		if type(ReplayTable) ~= "table" or #ReplayTable == 0 then
			ConsoleMessage("No replay in memory to optimize (record or read one first)")
			return
		end
		PlaybackCtl.Optimizing = true
		local ok, err = pcall(function()
			local FramesBefore = #ReplayTable

			NormalizeReplay()

			ReplayNeedsReload = false
			ConsoleMessage("Optimized: "..FramesBefore.." -> "..#ReplayTable.." frames. Press Save to write it to the file")
		end)
		if not ok then
			ConsoleMessage("Optimize error:", tostring(err))
		end
		PlaybackCtl.Optimizing = false
	end

	-- True when the 12-component CFrame lists match.
	local function CFrameListUnchanged(A, B)
		for Index = 1, 12 do
			local X = type(A) == "table" and A[Index] or nil
			local Y = type(B) == "table" and B[Index] or nil
			if not NearlyEqual(X, Y, 1e-3) then
				return false
			end
		end
		return true
	end

	-- True while the camera sits exactly where the previous kept frame left it.
	local function CameraUnchanged(Frame, Prev)
		return CFrameListUnchanged(Frame[7], Prev[7])
			and NearlyEqual(Frame[8], Prev[8], 1e-3)     -- zoom changes the shot
			and NearlyEqual(Frame[10], Prev[10], 1e-3)   -- shift lock swaps the camera rig
	end

	local function HasQueuedInputs(Frame)
		local Inputs = Frame[12]
		if type(Inputs) ~= "table" then
			return false
		end
		return #(Inputs[1] or {}) > 0 or #(Inputs[2] or {}) > 0
	end

	-- A frame is redundant when the body and the camera both sit where the previous kept frame
	-- left them, no animation call fires and no applied state changes. Input frames are never
	-- dropped: removing one would delete the keypress instead of a duplicate frame.
	local function IsUltraRedundant(Frame, Prev)
		if type(Frame) ~= "table" or type(Prev) ~= "table" then
			return false
		end
		if type(Frame[2]) == "table" and #Frame[2] > 0 then
			return false
		end
		if HasQueuedInputs(Frame) then
			return false
		end
		if not CameraUnchanged(Frame, Prev) then
			return false
		end
		if not CFrameListUnchanged(Frame[1], Prev[1]) then return false end -- humanoid root part
		if not NearlyEqual(Frame[4], Prev[4], 1e-3) then return false end -- humanoid state
		if not NearlyEqual(Frame[3], Prev[3], 1e-3) then return false end -- animation speed
		if not NearlyEqual(Frame[9], Prev[9], 1e-3) then return false end -- pose
		-- custom object data is a one-shot delta: empty changes nothing, non-empty must run
		local CODelta = Frame[13]
		if type(CODelta) == "table" and next(CODelta) ~= nil then
			return false
		end
		return true
	end

	-- Optimize plus a full-pass frame drop. Playback advances one frame per Heartbeat, so
	-- every dropped frame shortens the replay and pulls later events earlier by one frame.
	PlaybackCtl.UltraOptimize = function()
		if Reading or Writing or Frozen then
			ConsoleMessage("Ultra optimize only works while idle (stop reading/recording and unfreeze first)")
			return
		end
		if PlaybackCtl.Optimizing then
			return
		end
		if type(ReplayTable) ~= "table" or #ReplayTable == 0 then
			ConsoleMessage("No replay in memory to ultra optimize (record or read one first)")
			return
		end
		PlaybackCtl.Optimizing = true
		local ok, err = pcall(function()
			local FramesBefore = #ReplayTable

			NormalizeReplay()

			local Kept = {}
			local Prev = nil
			local Last = #ReplayTable
			for Index = 1, Last do
				local Frame = ReplayTable[Index]
				-- always keep the first and last frame, drop only repeats of the last kept one
				if Index == 1 or Index == Last or not IsUltraRedundant(Frame, Prev) then
					table.insert(Kept, Frame)
					Prev = Frame
				end
			end
			ReplayTable = Kept

			ReplayNeedsReload = false
			ConsoleMessage("Ultra optimized: "..FramesBefore.." -> "..#ReplayTable.." frames ("
				..(FramesBefore - #ReplayTable).." dropped). Press Save to write it to the file")
		end)
		if not ok then
			ConsoleMessage("Ultra optimize error:", tostring(err))
		end
		PlaybackCtl.Optimizing = false
	end

	-- Realistic replay: reads the recording's own timeline (Frame[14]) and rebuilds the run at the
	-- speed the player actually moved. Slow-motion recording keeps one normal-time tick of motion
	-- per frame on average, but a fractional rate spaces the kept frames 0.7/1.4 ticks apart, and
	-- the frame-drop accumulator can leave one tick with no motion and the next carrying double;
	-- a replay stepped one frame per heartbeat turns both into speed pulses. This pass measures
	-- the recording rate, rebuilds the timeline on whole ticks with cubic positions so speed stays
	-- continuous, then pulls single-frame stalls and spikes back onto the chord between their
	-- neighbours. Only ground-contact frames are touched, never one carrying an animation, an
	-- input or an object delta.
	PlaybackCtl.RealisticReplay = function()
		if Reading or Writing or Frozen then
			ConsoleMessage("Realistic replay only works while idle (stop reading/recording and unfreeze first)")
			return
		end
		if PlaybackCtl.Optimizing then
			return
		end
		if type(ReplayTable) ~= "table" or #ReplayTable == 0 then
			ConsoleMessage("No replay in memory to analyse (record or read one first)")
			return
		end
		PlaybackCtl.Optimizing = true
		local ok, err = pcall(function()
			local FramesBefore = #ReplayTable

			-- A recording keeps one normal-time tick of motion per frame on average, so the total
			-- duration is right; what a replay pulses on is the spacing. Count the gaps that are
			-- not a whole tick and how far off the worst one is. Measured before the rebuild,
			-- which rewrites the stamps.
			local GapCount, Irregular, MaxDev, Missing = 0, 0, 0, false
			local PrevTime = nil
			for _, Frame in ipairs(ReplayTable) do
				if type(Frame) == "table" then
					local Time = tonumber(Frame[14])
					if not Time then
						Missing = true
					elseif PrevTime then
						local Gap = Time - PrevTime
						if Gap > 1e-3 and Gap < 64 then
							GapCount = GapCount + 1
							local Dev = math.abs(Gap - 1)
							if Dev > 1e-3 then
								Irregular = Irregular + 1
								if Dev > MaxDev then MaxDev = Dev end
							end
						end
					end
					PrevTime = Time
				else
					PrevTime = nil
				end
			end

			NormalizeReplay()

			if not Missing and GapCount > 0 then
				PlaybackCtl.RetimePass(true)
			end

			-- One tick of no motion followed by a tick carrying two is the recorder's own drop
			-- pattern, not the player: the body was somewhere on the line between the neighbours.
			-- Only a straight run is repaired (a turn has a chord much shorter than the sum of its
			-- steps) and two repairs never sit closer than three ticks, so a real stop or a tap
			-- stays exactly where it was recorded.
			local function RootPosition(Frame)
				local List = type(Frame) == "table" and Frame[1] or nil
				if type(List) ~= "table" or type(List[1]) ~= "number" then
					return nil
				end
				return Vector3.new(List[1], List[2] or 0, List[3] or 0)
			end

			local function OnGround(Frame)
				local State = type(Frame) == "table" and Frame[4] or nil
				return State == 8 or State == 10 or State == 11
			end

			local function CarriesEvent(Frame)
				if type(Frame[2]) == "table" and #Frame[2] > 0 then
					return true
				end
				local Inputs = Frame[12]
				if type(Inputs) == "table"
					and (#(Inputs[1] or {}) > 0 or #(Inputs[2] or {}) > 0) then
					return true
				end
				local Delta = Frame[13]
				return type(Delta) == "table" and next(Delta) ~= nil
			end

			local Repaired, LastRepaired = 0, -10
			for Index = 3, #ReplayTable - 1 do
				local Earlier = ReplayTable[Index - 2]
				local Prev, Cur, Next = ReplayTable[Index - 1], ReplayTable[Index], ReplayTable[Index + 1]
				if type(Earlier) == "table" and type(Prev) == "table" and type(Cur) == "table" and type(Next) == "table"
					and Index - LastRepaired >= 3
					and OnGround(Prev) and OnGround(Cur) and OnGround(Next)
					and not CarriesEvent(Cur) then
					local P0, Pa, Pc, Pb = RootPosition(Earlier), RootPosition(Prev), RootPosition(Cur), RootPosition(Next)
					if P0 and Pa and Pc and Pb then
						local Incoming = Pa - P0
						local Back  = (Pc - Pa).Magnitude
						local Ahead = (Pb - Pc).Magnitude
						local Chord = (Pb - Pa).Magnitude
						-- both sides have to be moving into and out of the frame, on a straight run,
						-- so a stop, a start or a turn at the apex is never mistaken for a dropped tick
						if Ahead > 0.05 and Incoming.Magnitude > 0.05
							and Chord > 0.5 * (Back + Ahead) then
							local Heading = Back > 0.01 and (Pc - Pa) or Incoming
							if Heading.Unit:Dot((Pb - Pc).Unit) > 0.5
								and (Back < 0.4 * Ahead or Back > 1.8 * Ahead) then
								local Position = Pa:Lerp(Pb, 0.5)
								Cur[1] = RoundTable(CFrameToTable(
									CFrame.new(Position) * TableToCFrame(Cur[1]).Rotation), 5)
								Repaired = Repaired + 1
								LastRepaired = Index
							end
						end
					end
				end
			end

			ReplayNeedsReload = false
			local Seconds = #ReplayTable / math.max(FPS, 1)
			if Missing or GapCount == 0 then
				ConsoleMessage(string.format(
					"Realistic replay: no speed-timing clock in this replay, so timing is already as recorded; %d speed artefacts repaired. Press Save to write it to the file",
					Repaired))
			elseif Irregular == 0 then
				ConsoleMessage(string.format(
					"Realistic replay: all %d frame gaps were already whole ticks (%.1f s at %d fps), so speed timing needed no rebuild; %d speed artefacts repaired. Press Save to write it to the file",
					GapCount, Seconds, FPS, Repaired))
			else
				ConsoleMessage(string.format(
					"Realistic replay: %d of %d frame gaps were uneven, worst %.0f ms off a whole tick -> rebuilt %d frames into %d on a uniform 1-tick timeline (%.1f s at %d fps); %d speed artefacts repaired. Press Save to write it to the file",
					Irregular, GapCount, MaxDev * 1000 / math.max(FPS, 1), FramesBefore, #ReplayTable, Seconds, FPS, Repaired))
			end
		end)
		if not ok then
			ConsoleMessage("Realistic replay error:", tostring(err))
		end
		PlaybackCtl.Optimizing = false
	end
end

-- Speed retiming: while slow-motion recording, the frame-drop accumulator keeps a whole
-- normal-time tick's worth of motion per frame on average, but fractional rates (0.7x, say)
-- hold one frame for 1 real tick and the next for 2, so their normal-time stamps alternate
-- between 0.7 and 1.4 ticks. Playback advances exactly one frame per Heartbeat, so those
-- uneven gaps replay as speed pulses. Frame[14] carries the recording's normal-time clock;
-- this pass rebuilds the replay on a uniform 1-tick timeline, interpolating the body and the
-- camera and moving animation calls, inputs and object deltas onto the nearest new tick.
-- Replays already on one tick per frame need no work.
--
-- The pass is shared with "Realistic replay": it rebuilds the replay on a uniform normal-time
-- tick grid and returns the number of output frames (0 when the input already sits on whole
-- ticks). Spline = cubic Hermite body and camera positions, so the rebuilt path keeps a
-- continuous velocity across samples the recorder spaced 0.7/1.4 ticks apart; without it the
-- rebuild is a straight lerp between those two samples.
PlaybackCtl.RetimePass = function(Spline)
	do
		local function BlendNumber(A, B, Alpha, Digits)
			if type(A) ~= "number" or Alpha <= 1e-6 or type(B) ~= "number" then
				return A
			end
			return RoundNumber(A + (B - A) * Alpha, Digits)
		end

		local function BlendList(A, B, Alpha, Digits)
			if type(A) ~= "table" then
				return A
			end
			local Result = {}
			for Index = 1, #A do
				Result[Index] = BlendNumber(A[Index], type(B) == "table" and B[Index] or nil, Alpha, Digits)
			end
			return Result
		end

		local function BlendCFrame(A, B, Alpha, Digits)
			if type(A) ~= "table" then
				return A
			end
			if Alpha <= 1e-6 or type(B) ~= "table" or #B < 12 then
				return BlendList(A, nil, 0, Digits)
			end
			return RoundTable(CFrameToTable(TableToCFrame(A):Lerp(TableToCFrame(B), Alpha)), Digits)
		end

		-- Cubic Hermite through four real samples. Tangents are scaled by the sample spacing, so
		-- the 0.7/1.4 tick alternation of a slow-motion recording cannot bend the path, and the
		-- result is held inside the segment's own box so a corner cannot overshoot the route.
		local function SplineCFrame(A, B, Prev, Next, Ta, Tb, Tprev, Tnext, Alpha, Digits)
			if type(A) ~= "table" or #A < 12 then
				return A
			end
			if type(B) ~= "table" or #B < 12 or Alpha <= 1e-6 then
				return BlendCFrame(A, B, Alpha, Digits)
			end
			local CA, CB = TableToCFrame(A), TableToCFrame(B)
			local PA, PB = CA.Position, CB.Position
			local Span = Tb - Ta
			if type(Span) ~= "number" or Span <= 1e-6 then
				return BlendCFrame(A, B, Alpha, Digits)
			end
			local M1, M2 = PB - PA, PB - PA
			if type(Prev) == "table" and #Prev >= 12 and type(Tprev) == "number" and Ta - Tprev > 1e-6 then
				M1 = (PB - TableToCFrame(Prev).Position) * (Span / (Tb - Tprev))
			end
			if type(Next) == "table" and #Next >= 12 and type(Tnext) == "number" and Tnext - Ta > 1e-6 then
				M2 = (TableToCFrame(Next).Position - PA) * (Span / (Tnext - Ta))
			end
			local U = Alpha
			local U2 = U * U
			local U3 = U2 * U
			local Position = PA * (2 * U3 - 3 * U2 + 1)
				+ M1 * (U3 - 2 * U2 + U)
				+ PB * (-2 * U3 + 3 * U2)
				+ M2 * (U3 - U2)
			Position = Vector3.new(
				math.clamp(Position.X, math.min(PA.X, PB.X), math.max(PA.X, PB.X)),
				math.clamp(Position.Y, math.min(PA.Y, PB.Y), math.max(PA.Y, PB.Y)),
				math.clamp(Position.Z, math.min(PA.Z, PB.Z), math.max(PA.Z, PB.Z)))
			return RoundTable(CFrameToTable(CFrame.new(Position) * CA:Lerp(CB, Alpha).Rotation), Digits)
		end

		local Out = {}
		local Segment = {}
		local Retimed = 0

		local function FlushSegment()
			local Frames = Segment
			Segment = {}
			if #Frames == 0 then
				return
			end

			local Times = {}
			local Uneven = false
			for Index = 1, #Frames do
				local Frame = Frames[Index]
				local Time = type(Frame) == "table" and tonumber(Frame[14]) or nil
				if not Time then
					error("replay has frames without speed timing data (record it with this version first)")
				end
				Times[Index] = Time
				-- the first gap is the recording-start seed (the first frame is forced out one
				-- tick early), not jitter, so clean rates like 0.5x stay untouched
				if Index > 2 and math.abs((Time - Times[Index - 1]) - 1) > 1e-3 then
					Uneven = true
				end
			end

			if not Uneven then
				-- already one normal-time tick per frame: playback speed is correct
				for Index = 1, #Frames do
					Out[#Out + 1] = Frames[Index]
				end
				return
			end

			local T0 = Times[1]
			local Count = floor(Times[#Frames] - T0 + 0.5) + 1
			if Count < 1 then Count = 1 end
			if Count > 2000000 or Count > #Frames * 64 + 64 then
				error("speed timing data looks corrupt ("..tostring(Count).." output ticks)")
			end

			local Base = #Out + 1
			local Cursor = 1
			for Index = 1, Count do
				local Target = T0 + (Index - 1)
				while Cursor < #Frames and Times[Cursor + 1] <= Target do
					Cursor = Cursor + 1
				end
				local A = Frames[Cursor]
				local B = Frames[Cursor + 1]
				local Ta = Times[Cursor]
				local Tb = B and Times[Cursor + 1] or Ta
				local Alpha = 0
				if B and Tb > Ta then
					Alpha = (Target - Ta) / (Tb - Ta)
					if Alpha < 0 then Alpha = 0 elseif Alpha > 1 then Alpha = 1 end
				end
				local Nearest = (B and Alpha >= 0.5) and B or A

				local PrevFrame = Cursor > 1 and Frames[Cursor - 1] or nil
				local NextFrame = B and Frames[Cursor + 2] or nil
				local Frame = {}
				if Spline then
					Frame[1] = SplineCFrame(A[1], B and B[1], PrevFrame and PrevFrame[1], NextFrame and NextFrame[1],
						Ta, Tb, PrevFrame and Times[Cursor - 1], NextFrame and Times[Cursor + 2], Alpha, 5)
					Frame[7] = SplineCFrame(A[7], B and B[7], PrevFrame and PrevFrame[7], NextFrame and NextFrame[7],
						Ta, Tb, PrevFrame and Times[Cursor - 1], NextFrame and Times[Cursor + 2], Alpha, 4)
				else
					Frame[1] = BlendCFrame(A[1], B and B[1], Alpha, 5)   -- humanoid root part
					Frame[7] = BlendCFrame(A[7], B and B[7], Alpha, 4)   -- camera
				end
				Frame[2] = {}
				Frame[3] = BlendNumber(A[3], B and B[3], Alpha, 3)   -- animation speed
				Frame[4] = Nearest[4]                                -- humanoid state
				Frame[5] = BlendList(A[5], B and B[5], Alpha, 4)     -- velocity
				Frame[6] = BlendList(A[6], B and B[6], Alpha, 4)     -- rotational velocity
				Frame[8] = Nearest[8]                                -- zoom (a threshold, blending erases short dives)
				Frame[9] = Nearest[9]                                -- pose
				Frame[10] = Nearest[10]                              -- shift lock
				Frame[11] = BlendList(A[11], B and B[11], Alpha, 2)  -- mouse location
				Frame[12] = {{}, {}}
				Frame[13] = {}
				Frame[14] = Target
				Out[Base + Index - 1] = Frame
			end

			-- animations, inputs and object deltas are one-shot events: land each on the output
			-- tick closest to the recorded frame that carried it
			for Index = 1, #Frames do
				local Source = Frames[Index]
				local Slot = floor(Times[Index] - T0 + 0.5) + 1
				if Slot < 1 then Slot = 1 elseif Slot > Count then Slot = Count end
				local Dest = Out[Base + Slot - 1]
				if type(Source[2]) == "table" then
					for _, Entry in ipairs(Source[2]) do
						Dest[2][#Dest[2] + 1] = Entry
					end
				end
				local Inputs = type(Source[12]) == "table" and Source[12] or nil
				if Inputs then
					for _, Input in ipairs(Inputs[1] or {}) do
						Dest[12][1][#Dest[12][1] + 1] = Input
					end
					for _, Input in ipairs(Inputs[2] or {}) do
						Dest[12][2][#Dest[12][2] + 1] = Input
					end
				end
				if type(Source[13]) == "table" then
					for Key, Value in pairs(Source[13]) do
						Dest[13][Key] = Value
					end
				end
			end

			Retimed = Retimed + Count
		end

		for _, Frame in ipairs(ReplayTable) do
			if type(Frame) == "table" then
				Segment[#Segment + 1] = Frame
			else
				FlushSegment()
				Out[#Out + 1] = Frame -- void / dead marker keeps its place in the timeline
			end
		end
		FlushSegment()

		if Retimed == 0 then
			return 0
		end

		ReplayTable = Out
		ReplayNeedsReload = false
		return Retimed
	end
end

PlaybackCtl.RetimeReplay = function()
	if Reading or Writing or Frozen then
		ConsoleMessage("Optimize replay speed only works while idle (stop reading/recording and unfreeze first)")
		return
	end
	if PlaybackCtl.Optimizing then
		return
	end
	if type(ReplayTable) ~= "table" or #ReplayTable == 0 then
		ConsoleMessage("No replay in memory to re-time (record or read one first)")
		return
	end
	PlaybackCtl.Optimizing = true
	local ok, err = pcall(function()
		local FramesBefore = #ReplayTable
		local Retimed = PlaybackCtl.RetimePass(false)
		if Retimed == 0 then
			ConsoleMessage("Replay already runs on whole normal-time ticks - nothing to re-time")
			return
		end
		ReplayNeedsReload = false
		ConsoleMessage("Replay speed optimized: "..FramesBefore.." -> "..Retimed.." frames on a uniform tick timeline. Press Save to write it to the file")
	end)
	if not ok then
		ConsoleMessage("Optimize replay speed error:", tostring(err))
	end
	PlaybackCtl.Optimizing = false
end

-- FPS converter: rebuilds the replay on a uniform timeline at the selected rate. Playback takes
-- one tape entry per 1/FPS seconds, so the conversion maps every entry through Target/Source and
-- resamples the body, camera, animation speed, velocities and mouse track at those positions:
-- the run keeps its wall-clock duration, path, inputs, markers and object deltas. Sampled frames
-- hold instead of blending across a respawn/death marker or a recorded stall, so the converted
-- tape moves exactly like the source did. The source rate is resolved the way playback resolves
-- it (stamped file rate, then measured from motion, then the configured rate), and the result is
-- stamped with the target rate so save -> read plays it back at that rate.
PlaybackCtl.ConvertFPS = function()
	if Reading or Writing or Frozen then
		ConsoleMessage("FPS converter only works while idle (stop reading/recording and unfreeze first)")
		return
	end
	if PlaybackCtl.Optimizing then
		return
	end
	if type(ReplayTable) ~= "table" or #ReplayTable == 0 then
		ConsoleMessage("No replay in memory to convert (record or read one first)")
		return
	end
	local Target = floor((tonumber(PlaybackCtl.ConvertFpsTarget) or FPS) + 0.5)
	if Target < 60 then Target = 60 elseif Target > 240 then Target = 240 end
	local SourceRate = PlaybackCtl.FileFPS
	if not (type(SourceRate) == "number" and SourceRate >= 1) then
		SourceRate = nil
		local LastEntry = ReplayTable[#ReplayTable]
		if type(LastEntry) ~= "table" or LastEntry[14] == nil then
			SourceRate = PlaybackCtl.EstimateFPS(ReplayTable)
		end
		if not SourceRate then
			SourceRate = FPS
		end
	end
	if not (type(SourceRate) == "number" and SourceRate >= 1) then
		ConsoleMessage("FPS converter: could not determine this replay's rate")
		return
	end
	if math.abs(SourceRate - Target) < 1e-3 then
		ConsoleMessage("FPS converter: this replay already runs at "..RoundNumber(SourceRate, 2).." fps")
		return
	end
	PlaybackCtl.Optimizing = true
	local ok, err = pcall(function()
		local Source = ReplayTable
		local EntryCount = #Source
		local Kind = {}
		local TableCount = 0
		local TickBase, TickBaseEntry = nil, nil
		for Index = 1, EntryCount do
			local Entry = Source[Index]
			if type(Entry) == "table" then
				Kind[Index] = "f"
				TableCount = TableCount + 1
				if not TickBase and type(Entry[14]) == "number" then
					TickBase = Entry[14]
					TickBaseEntry = Index
				end
			else
				Kind[Index] = "m"
			end
		end
		if TableCount == 0 then
			error("the replay has no frames to convert")
		end

		local Scale = Target / SourceRate
		local OutCount = floor((EntryCount - 1) * Scale + 0.5) + 1
		if OutCount < 1 then OutCount = 1 end
		-- a marker costs one playback tick on either timeline: keep its slot, and when a downscale
		-- rounds two markers onto the same tick push the later one forward instead of losing it
		local MarkerSlot, MarkerAt = {}, {}
		local PrevSlot = 0
		for Index = 1, EntryCount do
			if Kind[Index] == "m" then
				local Slot = floor((Index - 1) * Scale + 0.5) + 1
				if Slot <= PrevSlot then Slot = PrevSlot + 1 end
				if Slot > 2000000 then
					error("conversion would need more than two million frames")
				end
				MarkerSlot[Index] = Slot
				MarkerAt[Slot] = Index
				PrevSlot = Slot
				if Slot > OutCount then OutCount = Slot end
			end
		end
		if OutCount > 2000000 then
			error("conversion would need "..tostring(OutCount).." frames - too many")
		end
		local Base = nil
		if TickBase then
			local FirstSlot = floor((TickBaseEntry - 1) * Scale + 0.5) + 1
			Base = TickBase - (FirstSlot - 1)
		end

		local function CopyList(List)
			local Result = {}
			for Index = 1, #List do
				Result[Index] = List[Index]
			end
			return Result
		end
		local function MixNumber(A, B, Alpha, Digits)
			if type(A) ~= "number" then return A end
			if type(B) ~= "number" or Alpha <= 1e-9 then return A end
			if Alpha >= 1 - 1e-9 then return B end
			return RoundNumber(A + (B - A) * Alpha, Digits)
		end
		local function MixList(A, B, Alpha, Digits)
			if type(A) ~= "table" then return A end
			if type(B) ~= "table" or Alpha <= 1e-9 then return CopyList(A) end
			if Alpha >= 1 - 1e-9 then return CopyList(B) end
			local Result = {}
			for Index = 1, #A do
				Result[Index] = MixNumber(A[Index], B[Index], Alpha, Digits)
			end
			return Result
		end

		local Out = {}
		local Sampled = 0
		local Cursor = 1
		for Slot = 1, OutCount do
			if MarkerAt[Slot] then
				Out[Slot] = Source[MarkerAt[Slot]]
			else
				local S = (Slot - 1) / Scale + 1
				if S < 1 then S = 1 elseif S > EntryCount then S = EntryCount end
				while Cursor < EntryCount and Cursor + 1 <= S do
					Cursor = Cursor + 1
				end
				local AIndex
				for Back = Cursor, 1, -1 do
					if Kind[Back] == "f" then AIndex = Back; break end
				end
				local BIndex
				for Forward = Cursor + 1, EntryCount do
					if Kind[Forward] == "f" then BIndex = Forward; break end
				end
				local A = AIndex and Source[AIndex] or nil
				local B = BIndex and Source[BIndex] or nil
				if not A then
					A, AIndex = B, BIndex
					B, BIndex = nil, nil
				end
				if not A then
					error("the replay has no frames to convert")
				end
				local Alpha = 0
				local UseB = false
				local Hold = false
				if B then
					Alpha = (S - AIndex) / (BIndex - AIndex)
					if Alpha < 0 then Alpha = 0 elseif Alpha > 1 then Alpha = 1 end
					local CutEntry
					for Between = AIndex + 1, BIndex - 1 do
						if Kind[Between] == "m" then CutEntry = Between; break end
					end
					if CutEntry then
						-- a respawn / death marker is a cut: nothing may blend across it
						Hold = true
						if Slot >= MarkerSlot[CutEntry] then UseB = true end
					else
						local TimeA, TimeB = tonumber(A[14]), tonumber(B[14])
						if TimeA and TimeB and (TimeB - TimeA) / SourceRate > 0.1 then
							Hold = true
						end
						if type(A[1]) == "table" and type(B[1]) == "table" then
							local DX, DY, DZ = B[1][1] - A[1][1], B[1][2] - A[1][2], B[1][3] - A[1][3]
							if DX * DX + DY * DY + DZ * DZ > 900 then Hold = true end
						end
						if type(A[7]) == "table" and type(B[7]) == "table" then
							local DX, DY, DZ = B[7][1] - A[7][1], B[7][2] - A[7][2], B[7][3] - A[7][3]
							if DX * DX + DY * DY + DZ * DZ > 10000 then Hold = true end
						end
						if Hold and Alpha >= 1 - 1e-9 then UseB = true end
					end
				end
				local Frac = Alpha
				if Hold then Frac = 0 end
				if UseB then Frac = 1 end
				local FrameB = nil
				if not Hold or UseB then FrameB = B end
				-- the discrete channels belong to the frame playback would have applied at that
				-- moment (the last one at or before the sample), not to the nearest blend side
				local Discrete = A
				if UseB then Discrete = B end
				local Frame = {}
				Frame[1] = MixList(A[1], FrameB and FrameB[1], Frac, 5)
				Frame[2] = {}
				Frame[3] = MixNumber(A[3], FrameB and FrameB[3], Frac, 3)
				Frame[4] = Discrete[4]
				Frame[5] = MixList(A[5], FrameB and FrameB[5], Frac, 4)
				Frame[6] = MixList(A[6], FrameB and FrameB[6], Frac, 4)
				Frame[7] = MixList(A[7], FrameB and FrameB[7], Frac, 4)
				Frame[8] = Discrete[8]
				Frame[9] = Discrete[9]
				Frame[10] = Discrete[10]
				Frame[11] = MixList(A[11], FrameB and FrameB[11], Frac, 2)
				Frame[12] = {{}, {}}
				Frame[13] = {}
				if Base then
					Frame[14] = RoundNumber(Base + Slot - 1, 4)
				end
				Out[Slot] = Frame
				Sampled = Sampled + 1
			end
		end
		if Sampled == 0 then
			error("the replay is all markers - nothing to convert")
		end

		-- animation calls, inputs and object deltas are one-shot events: land each on the output
		-- tick nearest the recorded frame that carried it, never on a marker's tick
		local function FreeSlot(Index, Slot)
			while Slot >= 1 and Slot <= OutCount and MarkerAt[Slot] do
				if Index < MarkerAt[Slot] then
					Slot = Slot - 1
				else
					Slot = Slot + 1
				end
			end
			if Slot >= 1 and Slot <= OutCount then
				return Slot
			end
			if Slot < 1 then
				Slot = 1
				while Slot <= OutCount and MarkerAt[Slot] do Slot = Slot + 1 end
			else
				Slot = OutCount
				while Slot >= 1 and MarkerAt[Slot] do Slot = Slot - 1 end
			end
			if Slot >= 1 and Slot <= OutCount then return Slot end
			return nil
		end
		for Index = 1, EntryCount do
			if Kind[Index] == "f" then
				local SourceFrame = Source[Index]
				local Slot = floor((Index - 1) * Scale + 0.5) + 1
				if Slot < 1 then Slot = 1 elseif Slot > OutCount then Slot = OutCount end
				Slot = FreeSlot(Index, Slot)
				if Slot then
					local Dest = Out[Slot]
					if type(SourceFrame[2]) == "table" then
						for _, Entry in ipairs(SourceFrame[2]) do
							local Animations = Dest[2]
							Animations[#Animations + 1] = Entry
						end
					end
					local Inputs = type(SourceFrame[12]) == "table" and SourceFrame[12] or nil
					if Inputs then
						for _, Input in ipairs(Inputs[1] or {}) do
							local Began = Dest[12][1]
							Began[#Began + 1] = Input
						end
						for _, Input in ipairs(Inputs[2] or {}) do
							local Ended = Dest[12][2]
							Ended[#Ended + 1] = Input
						end
					end
					if type(SourceFrame[13]) == "table" then
						for Key, Value in pairs(SourceFrame[13]) do
							Dest[13][Key] = Value
						end
					end
				end
			end
		end

		ReplayTable = Out
		FPS = Target
		PlaybackCtl.FileFPS = Target
		-- the converted frames never came off the render loop: zero the capture counters so Save
		-- stamps the target rate instead of a measured source rate
		local Rate = SpeedHack.Rate
		Rate.Prev = nil
		Rate.Sum, Rate.Count, Rate.Session, Rate.Loaded = 0, 0, 0, false
		ReplayNeedsReload = false
		if FPSTextbox then
			FPSTextbox.Value = tostring(Target)
		end
		ConsoleMessage("FPS converted: "..TableCount.." frames at "..RoundNumber(SourceRate, 2)
			.." fps -> "..Sampled.." frames at "..Target.." fps ("
			..RoundNumber(OutCount / Target, 2).." s of run kept). Press Save to write it to the file")
	end)
	if not ok then
		ConsoleMessage("FPS converter error:", tostring(err))
	end
	PlaybackCtl.Optimizing = false
end

-- Smooth out: a centred, time-aware local quadratic fit (Savitzky-Golay) over the recorded
-- path. Every frame is re-fitted from its neighbours using their real spacing (Frame[14]
-- normal-time ticks), so a speed-hack replay with uneven kept-frame spacing smooths exactly
-- like a uniform one. Averaging is what makes a smoothed replay read as floaty: a Gaussian
-- window sags the apex of every jump arc and eats the peak of a fast strafe, because it
-- flattens anything with curvature. A quadratic fit carries velocity and acceleration, so a
-- ballistic arc is reproduced exactly and a tap keeps its shape. Near a run end the window
-- widens on the far side instead of truncating (a one-sided window biases the fit), and each
-- channel is held inside its local sample range so a hard corner cannot ring past the
-- recorded path. Rotation is filtered as a quaternion (hemisphere-aligned) so a turn can
-- never be averaged through the wrong one, and every neighbour is weighted by its turning
-- rate relative to the frame being fitted: a flick is a step in angular velocity, so without
-- that a quadratic bends across the step. On the camera that cost ~18 deg of lag and ~10%
-- of peak speed on a 35 ms 180; on the root it swung the body ~45 deg past a two-frame 180
-- and back through the far side, which reads as the torso facing the wrong way. Jitter is a
-- fraction of a degree and stays fully inside the fit. One output frame per input frame:
-- no resampling,
-- no interpolation of the frame list. Body and camera only:
-- the frames of a shift-lock toggle and the frames that switch between first and third person
-- are passed through raw and break the runs, so the hand-off stays bit-exact; between toggles
-- the camera is re-welded to the smoothed body with its
-- recorded offset (zoom stays raw), a shift-lock tap short enough to be folded away has its
-- camera bridged straight across so the pop it left behind cannot replay as a flick, the mouse
-- track is never touched, and runs break at
-- air/ground contact, at climbing and at emotes so an impact, a truss grab or a dance keeps
-- its recorded frames. An emote is played on the rig while the root is parked, so a fit
-- reaching in from the walk beside it would turn the standing body with a heading the emote
-- never had; those frames are copied through raw from the event that starts the emote to the
-- event that hands the rig back to a locomotion animation.
-- The smooth slider sets the window width (1..10, 5 = the tuned default).
PlaybackCtl.SmoothReplay = function()
	if Reading or Writing or Frozen then
		ConsoleMessage("Smooth out replay only works while idle (stop reading/recording and unfreeze first)")
		return
	end
	if PlaybackCtl.Optimizing then
		return
	end
	if type(ReplayTable) ~= "table" or #ReplayTable == 0 then
		ConsoleMessage("No replay in memory to smooth (record or read one first)")
		return
	end
	PlaybackCtl.Optimizing = true
	local ok, err = pcall(function()
		-- slider 1..10; 5 is the tuned default (body sigma 3.5 ticks, ~24 ms at 144 fps)
		local Strength = tonumber(PlaybackCtl.SmoothStrength) or 5
		if Strength < 1 then Strength = 1 elseif Strength > 10 then Strength = 10 end
		local SIGMA = Strength * 0.7       -- body window width in normal-time ticks
		local WINDOW = math.ceil(SIGMA * 3) -- body frames checked on each side
		local SIGMA_CAM = Strength * 0.5   -- camera stays closer to the raw input
		local WINDOW_CAM = math.ceil(SIGMA_CAM * 3)
		-- Angular speed (radians per normal-time tick) at which a camera sample stops
		-- counting as "the same look". Mouse jitter is a fraction of a degree per frame;
		-- a flick is tens.
		local RANGE_CAM = 10 * math.pi / 180
		-- Same idea for the root. The heading is engine-driven and carries no jitter worth
		-- keeping, but under shift lock the body turns at mouse speed, and an unweighted
		-- fit swings it the wrong way across a quick turn before settling.
		local RANGE_BODY = 6 * math.pi / 180
		-- The Animate replacement's emote names: the clips a player triggers from chat. Every
		-- other name in the animation channel is locomotion or a tool.
		local EMOTES = { wave = true, point = true, dance1 = true, dance2 = true, dance3 = true, laugh = true, cheer = true }
		local FramesBefore = #ReplayTable
		local Queue, Out, Smoothed, Climbed, Emoted, Toggled, Zoomed = {}, {}, 0, 0, 0, 0, 0

		-- Rotation matrix -> unit quaternion (w, x, y, z), Shepperd's method.
		local function ToQuat(CF)
			local Right, Up, Look = CF.RightVector, CF.UpVector, -CF.LookVector
			local M00, M01, M02 = Right.X, Up.X, Look.X
			local M10, M11, M12 = Right.Y, Up.Y, Look.Y
			local M20, M21, M22 = Right.Z, Up.Z, Look.Z
			local Trace = M00 + M11 + M22
			if Trace > 0 then
				local S = math.sqrt(Trace + 1) * 2
				return 0.25 * S, (M21 - M12) / S, (M02 - M20) / S, (M10 - M01) / S
			elseif M00 > M11 and M00 > M22 then
				local S = math.sqrt(1 + M00 - M11 - M22) * 2
				return (M21 - M12) / S, 0.25 * S, (M01 + M10) / S, (M02 + M20) / S
			elseif M11 > M22 then
				local S = math.sqrt(1 + M11 - M00 - M22) * 2
				return (M02 - M20) / S, (M01 + M10) / S, 0.25 * S, (M12 + M21) / S
			end
			local S = math.sqrt(1 + M22 - M00 - M11) * 2
			return (M10 - M01) / S, (M02 + M20) / S, (M12 + M21) / S, 0.25 * S
		end

		local function FromQuat(Position, W, X, Y, Z)
			local Length = math.sqrt(W * W + X * X + Y * Y + Z * Z)
			if Length < 1e-8 then
				return CFrame.new(Position)
			end
			W, X, Y, Z = W / Length, X / Length, Y / Length, Z / Length
			local Right = Vector3.new(
				1 - 2 * (Y * Y + Z * Z),
				2 * (X * Y + Z * W),
				2 * (X * Z - Y * W))
			local Up = Vector3.new(
				2 * (X * Y - Z * W),
				1 - 2 * (X * X + Z * Z),
				2 * (Y * Z + X * W))
			return CFrame.fromMatrix(Position, Right, Up)
		end

		-- Weighted sum of one channel over the current window, held inside the range of the
		-- samples it was fitted from. A quadratic fit overshoots a velocity discontinuity;
		-- clamping it is what lets a hard corner stay sharp without bulging past the geometry
		-- that corner was sitting on.
		local function Sample(Values, At, Left, Slots, Coefs)
			local Sum, Lo, Hi = 0, math.huge, -math.huge
			for Slot = 1, Slots do
				local Value = Values[At - Left + Slot - 1]
				Sum = Sum + Value * Coefs[Slot]
				if Value < Lo then
					Lo = Value
				end
				if Value > Hi then
					Hi = Value
				end
			end
			if Sum < Lo then
				return Lo
			elseif Sum > Hi then
				return Hi
			end
			return Sum
		end

		local function SmoothTrack(List, Times, Count, Sigma, Window, MinReach, RangeSigma)
			MinReach = MinReach or 0.5
			local PX, PY, PZ = {}, {}, {}
			local QW, QX, QY, QZ = {}, {}, {}, {}
			local PrevW, PrevX, PrevY, PrevZ
			for Index = 1, Count do
				local CF = List[Index]
				local Position = CF.Position
				PX[Index], PY[Index], PZ[Index] = Position.X, Position.Y, Position.Z
				local W, X, Y, Z = ToQuat(CF)
				if Index > 1 and (W * PrevW + X * PrevX + Y * PrevY + Z * PrevZ) < 0 then
					W, X, Y, Z = -W, -X, -Y, -Z -- q and -q are the same rotation; stay on one hemisphere
				end
				QW[Index], QX[Index], QY[Index], QZ[Index] = W, X, Y, Z
				PrevW, PrevX, PrevY, PrevZ = W, X, Y, Z
			end

			-- Scratch is reused per frame: one pass builds the moments and the coefficient row,
			-- then one pass per channel applies that row.
			local ZTab, WTab, CoefTab = {}, {}, {}
			local Result = {}
			for Index = 1, Count do
				local Left = math.min(Window, Index - 1)
				local Right = math.min(Window, Count - Index)
				-- Widen the far side instead of truncating. A one-sided window pulls the fit
				-- toward whichever end has data, and that bias is what lifts the first and last
				-- usable frames of a run off the recorded path.
				if Left < Window then
					Right = math.min(Count - Index, 2 * Window - Left)
				elseif Right < Window then
					Left = math.min(Index - 1, 2 * Window - Right)
				end
				local Slots = Left + Right + 1
				local Position, W, X, Y, Z
				local Ready = false
				if Slots >= 7 then
					-- Normal equations for offset + velocity + acceleration about this frame.
					-- Time is scaled by sigma so every moment is O(1) and the determinant test
					-- below means the same thing at every strength setting.
					local T0 = Times[Index]
					local S0, S1, S2, S3, S4 = 0, 0, 0, 0, 0
					-- Range weighting (camera only). A mouse flick is a step in angular
					-- velocity, and a plain quadratic fit bends across that step: the
					-- replayed view ends up a frame or two behind the flick and a few
					-- degrees slow at its peak. Weighting each sample by its turn rate
					-- relative to this frame keeps the fit on one side of the flick.
					-- Jitter is a fraction of a degree per tick, far under the cutoff, so
					-- everything the filter exists to remove is still filtered.
					local QW0, QX0, QY0, QZ0
					if RangeSigma then
						QW0, QX0, QY0, QZ0 = QW[Index], QX[Index], QY[Index], QZ[Index]
					end
					for Slot = 1, Slots do
						local At = Index - Left + Slot - 1
						local DT = (Times[At] - T0) / Sigma
						local Weight = math.exp(-0.5 * DT * DT)
						if RangeSigma then
							local Dot = QW0 * QW[At] + QX0 * QX[At] + QY0 * QY[At] + QZ0 * QZ[At]
							if Dot < 0 then
								Dot = -Dot
							end
							if Dot > 1 then
								Dot = 1 -- acos(NaN) would poison the whole frame
							end
							-- per normal-time tick, so a speed-hack replay with wider kept-frame
							-- spacing is judged by the turn rate and not by the gap
							local Gap = Times[At] - T0
							if Gap < 0 then
								Gap = -Gap
							end
							if Gap < 1e-4 then
								Gap = 1e-4
							end
							local ReachAngle = 2 * math.acos(Dot) / (RangeSigma * Gap)
							Weight = Weight * math.exp(-0.5 * ReachAngle * ReachAngle)
						end
						local Square = DT * DT
						ZTab[Slot], WTab[Slot] = DT, Weight
						S0 = S0 + Weight
						S1 = S1 + Weight * DT
						S2 = S2 + Weight * Square
						S3 = S3 + Weight * Square * DT
						S4 = S4 + Weight * Square * Square
					end
					local Det = S0 * (S2 * S4 - S3 * S3)
						- S1 * (S1 * S4 - S3 * S2)
						+ S2 * (S1 * S3 - S2 * S2)
					if Det > 1e-12 then
						-- First column of the inverse: the fitted value at the centre is
						-- sum(weight * (U0 + U1*dt + U2*dt^2) * sample), so one coefficient row
						-- serves every channel.
						local U0 = (S2 * S4 - S3 * S3) / Det
						local U1 = (S3 * S2 - S1 * S4) / Det
						local U2 = (S1 * S3 - S2 * S2) / Det
						for Slot = 1, Slots do
							local DT = ZTab[Slot]
							CoefTab[Slot] = WTab[Slot] * (U0 + U1 * DT + U2 * DT * DT)
						end
						Position = Vector3.new(
							Sample(PX, Index, Left, Slots, CoefTab),
							Sample(PY, Index, Left, Slots, CoefTab),
							Sample(PZ, Index, Left, Slots, CoefTab))
						W = Sample(QW, Index, Left, Slots, CoefTab)
						X = Sample(QX, Index, Left, Slots, CoefTab)
						Y = Sample(QY, Index, Left, Slots, CoefTab)
						Z = Sample(QZ, Index, Left, Slots, CoefTab)
						Ready = true
					end
				end
				if not Ready then
					-- Fewer than a quadratic can be fitted to (or a degenerate one): the
					-- recorded frame is the better answer than a fit with no redundancy.
					Position = List[Index].Position
					W, X, Y, Z = QW[Index], QX[Index], QY[Index], QZ[Index]
				end

				-- the corner cut is capped at one frame of travel so a hard turn cannot push the
				-- smoothed path through the geometry that corner was sitting on
				local Reach = 0
				if Index > 1 then
					Reach = (List[Index].Position - List[Index - 1].Position).Magnitude
				end
				if Index < Count then
					Reach = math.max(Reach, (List[Index + 1].Position - List[Index].Position).Magnitude)
				end
				local Offset = Position - List[Index].Position
				-- Body passes 0.1: the smoothed root stays within a tenth of a stud of the
				-- recorded path (or one frame of travel, whichever is larger), so a corner cannot
				-- be cut into a wall or a step. Camera keeps the 0.5 floor because its rigid
				-- body-space offset has tiny frame steps.
				local Limit = math.max(MinReach, Reach)
				if Offset.Magnitude > Limit then
					Position = List[Index].Position + Offset.Unit * Limit
				end
				Result[Index] = FromQuat(Position, W, X, Y, Z)
			end
			Result[1], Result[Count] = List[1], List[Count]
			return Result
		end

		local function Flush()
			local Frames, Count = Queue, #Queue
			Queue = {}
			if Count == 0 then
				return
			end
			if Count < 5 then
				for Index = 1, Count do
					Out[#Out + 1] = Frames[Index]
				end
				return
			end

			local Body, Camera, Times, Locked, Climb, Airborne, Blip = {}, {}, {}, {}, {}, {}, {}
			local BodyOK, CameraOK, TimeOK = true, true, true
			for Index = 1, Count do
				local Frame = Frames[Index]
				local BodyList = type(Frame[1]) == "table" and Frame[1] or nil
				if not BodyList or #BodyList ~= 12 then
					BodyOK = false
					break
				end
				Body[Index] = TableToCFrame(BodyList)
				local CameraList = type(Frame[7]) == "table" and Frame[7] or nil
				if CameraList and #CameraList == 12 then
					Camera[Index] = TableToCFrame(CameraList)
				else
					CameraOK = false
				end
				local State = tonumber(Frame[4])
				Locked[Index] = (tonumber(Frame[10]) == 1)
				Climb[Index] = (State == 12) -- Enum.HumanoidStateType.Climbing
				-- Jumping / Swimming / Freefall / Flying. A contact frame is where a jump starts or
				-- ends, and the body kernel must not average across it.
				Airborne[Index] = (State == 3 or State == 4 or State == 5 or State == 6)
				local Stamp = tonumber(Frame[14])
				if Stamp then
					Times[Index] = Stamp
				else
					TimeOK = false
					Times[Index] = Index
				end
			end
			if not BodyOK then
				for Index = 1, Count do
					Out[#Out + 1] = Frames[Index]
				end
				return
			end
			if TimeOK then
				for Index = 2, Count do
					if Times[Index] <= Times[Index - 1] then
						TimeOK = false
						break
					end
				end
			end
			if not TimeOK then
				for Index = 1, Count do
					Times[Index] = Index
				end
			end

			-- Shift lock is a hard edge for the camera, but the recorded setting can read back
			-- 0/1/0 for a frame or two while a toggle settles. Each direction rebuilds the camera
			-- differently, so an alternating run would jump-cut between two sources and read as
			-- a flicker. Anything shorter than three frames is folded into the state before it.
			-- A folded run is flagged: the lock bit no longer says it happened, but the recorded
			-- camera still carries the shoulder offset for those frames, and replaying it back
			-- reads as a one-frame sideways flick.
			do
				local MinRun = 3
				local Start = 1
				while Start <= Count do
					local Stop = Start
					while Stop < Count and Locked[Stop + 1] == Locked[Start] do
						Stop = Stop + 1
					end
					if Stop - Start + 1 < MinRun and Start > 1 then
						for Index = Start, Stop do
							Locked[Index] = Locked[Start - 1]
							Blip[Index] = true
						end
					end
					Start = Stop + 1
				end
			end

			-- A real toggle (after the debounce) is passed through raw on both sides and breaks
			-- the runs. The camera source changes at the edge (shoulder offset vs world), and
			-- the body heading snaps to the camera when the lock engages; letting the fit
			-- average across that snap is exactly what would blunt the toggle in the replay.
			local Toggle = {}
			for Index = 1, Count do
				if (Index > 1 and Locked[Index] ~= Locked[Index - 1])
					or (Index < Count and Locked[Index] ~= Locked[Index + 1]) then
					Toggle[Index] = true
				end
			end

			-- A first-person/third-person switch swaps the camera between the eye and the
			-- shoulder rig in one frame. Letting the fit average across that hand-off turns
			-- the pop into a slow glide, so the frames that perform the switch are passed
			-- through raw and break the runs. Only the switch frames are taken: the rest of
			-- the first-person stretch still smooths with the body, and the zoom number
			-- itself is never filtered. A frame with no zoom reading carries the last state.
			local FirstPerson = {}
			do
				local InFirst = false
				for Index = 1, Count do
					local Zoom = tonumber(Frames[Index][8])
					if Zoom ~= nil then
						InFirst = Zoom < 1
					end
					FirstPerson[Index] = InFirst
				end
			end
			local ZoomShift = {}
			for Index = 1, Count do
				if (Index > 1 and FirstPerson[Index] ~= FirstPerson[Index - 1])
					or (Index < Count and FirstPerson[Index] ~= FirstPerson[Index + 1]) then
					ZoomShift[Index] = true
				end
			end

			-- The frames either side of a real toggle or of a first/third person switch keep
			-- the camera exactly as recorded. A rebuilt camera on one side and a pinned raw
			-- edge on the other do not land on the same value, and that step is what shows up
			-- as the camera jumping when the hand-off happens. Leaving it bit-exact makes the
			-- switch invisible.
			local Seam = {}
			for Index = 1, Count do
				local Edge = (Index > 1 and Locked[Index] ~= Locked[Index - 1])
					or (Index < Count and Locked[Index] ~= Locked[Index + 1])
					or ZoomShift[Index]
				if Edge then
					Seam[Index] = true
					if Index > 1 then Seam[Index - 1] = true end
					if Index < Count then Seam[Index + 1] = true end
				end
			end

			-- Climbing gets the same treatment: a one-frame state readback at the moment of
			-- grabbing a truss would break the body kernel for nothing, and those frames are
			-- copied through raw, so a stray frame would sit unfiltered in the middle of a
			-- smoothed run.
			do
				local MinRun = 3
				local Start = 1
				while Start <= Count do
					local Stop = Start
					while Stop < Count and Climb[Stop + 1] == Climb[Start] do
						Stop = Stop + 1
					end
					if Stop - Start + 1 < MinRun then
						for Index = Start, Stop do
							Climb[Index] = false
						end
					end
					Start = Stop + 1
				end
			end

			-- The emote span is read off the animation channel: an event that names an emote
			-- opens it, and the next event that names any other animation closes it (an emote
			-- that ends on its own keyframe hands the rig back with an idle event, a player who
			-- walks out of it with a walk event). Unknown or empty names leave the span alone.
			local Emote = {}
			do
				local InEmote = false
				for Index = 1, Count do
					local Events = Frames[Index][2]
					if type(Events) == "table" then
						for _, Entry in ipairs(Events) do
							local Name = type(Entry) == "table" and Entry[1] or nil
							if type(Name) == "string" and Name ~= "" then
								InEmote = EMOTES[Name] or false
							end
						end
					end
					Emote[Index] = InEmote
				end
			end

			-- Climbing is engine-driven and snaps on and off the truss; filtering it blunts the
			-- grab and the pop, so climbing runs are never sampled. Body and camera are smoothed
			-- in runs of constant climb state, which also keeps a climb from bleeding into the
			-- frames on either side of it.
			-- Takeoff and touchdown get the same treatment. The recorded arc already ends exactly
			-- where the feet touched, and averaging that frame against the airborne ones folds
			-- the impact into a soft ease: the body hovers into the floor and leaves it a frame
			-- late. Splitting air from ground keeps the contact frame on the recorded spot.
			local Mode = {}
			for Index = 1, Count do
				if Climb[Index] then
					Mode[Index] = 3
				elseif Emote[Index] then
					Mode[Index] = 4
				elseif Toggle[Index] then
					Mode[Index] = 5
				elseif ZoomShift[Index] then
					Mode[Index] = 6
				elseif Airborne[Index] then
					Mode[Index] = 2
				else
					Mode[Index] = 1
				end
			end

			local NewBody, NewCamera = {}, {}
			local RunStart = 1
			while RunStart <= Count do
				local RunEnd = RunStart
				while RunEnd < Count and Mode[RunEnd + 1] == Mode[RunStart] do
					RunEnd = RunEnd + 1
				end
				local RunSize = RunEnd - RunStart + 1
				if Climb[RunStart] then
					Climbed = Climbed + RunSize
				elseif Emote[RunStart] then
					-- emote frames never reach the fit and never pull the runs beside them
					Emoted = Emoted + RunSize
				elseif Toggle[RunStart] then
					-- the frames either side of a shift-lock toggle stay bit-exact
					Toggled = Toggled + RunSize
				elseif ZoomShift[RunStart] then
					-- the frames that switch between first and third person stay bit-exact
					Zoomed = Zoomed + RunSize
				else
					local SubBody, SubTimes = {}, {}
					for Index = 1, RunSize do
						SubBody[Index] = Body[RunStart + Index - 1]
						SubTimes[Index] = Times[RunStart + Index - 1]
					end
					local SmoothedBody = SmoothTrack(SubBody, SubTimes, RunSize, SIGMA, WINDOW, 0.1, RANGE_BODY)
					for Index = 1, RunSize do
						NewBody[RunStart + Index - 1] = SmoothedBody[Index]
					end
					if CameraOK then
						-- Shift lock is rigid: the recorded camera is a fixed offset from the body,
						-- so the offset is what gets filtered and the view rides the smoothed body
						-- exactly. A free camera is filtered in world space instead - filtering it
						-- in body space would make it inherit the body's smoothed rotation, which
						-- reads as the camera tracking the character whenever the body turns.
						-- Runs break at the lock state, so a kernel never averages across a toggle.
						local CamStart = RunStart
						while CamStart <= RunEnd do
							local CamEnd = CamStart
							while CamEnd < RunEnd and Locked[CamEnd + 1] == Locked[CamStart] do
								CamEnd = CamEnd + 1
							end
							local CamSize = CamEnd - CamStart + 1
							local Track, CamTimes = {}, {}
							local Rigid = Locked[CamStart]
							for Index = 1, CamSize do
								local At = CamStart + Index - 1
								if Rigid then
									Track[Index] = Body[At]:Inverse() * Camera[At]
								else
									Track[Index] = Camera[At]
								end
								CamTimes[Index] = Times[At]
							end
							-- A folded lock tap left its shoulder offset in the recorded camera. The
							-- lock bit says no toggle happened, so the view has to agree: bridge the
							-- blip straight across from the frames either side and let the fit smooth
							-- the whole run. Left in, the two popped frames pull the fit with them and
							-- the deviation cap keeps the pop, which replays as a sideways flick.
							local Cursor = 1
							while Cursor <= CamSize do
								if Blip[CamStart + Cursor - 1] then
									local First = Cursor
									local Last = First
									while Last < CamSize and Blip[CamStart + Last] do
										Last = Last + 1
									end
									local Before, After = First - 1, Last + 1
									if Before >= 1 and After <= CamSize then
										local From, To = Track[Before], Track[After]
										for Fill = First, Last do
											Track[Fill] = From:Lerp(To, (Fill - Before) / (After - Before))
										end
									end
									Cursor = After
								else
									Cursor = Cursor + 1
								end
							end
							local SmoothedCam = SmoothTrack(Track, CamTimes, CamSize, SIGMA_CAM, WINDOW_CAM, nil, RANGE_CAM)
							for Index = 1, CamSize do
								local At = CamStart + Index - 1
								if Rigid then
									NewCamera[At] = NewBody[At] * SmoothedCam[Index]
								else
									NewCamera[At] = SmoothedCam[Index]
								end
							end
							CamStart = CamEnd + 1
						end
					end
				end
				RunStart = RunEnd + 1
			end

			for Index = 1, Count do
				local Source = Frames[Index]
				if Climb[Index] or Emote[Index] or Toggle[Index] or ZoomShift[Index] then
					-- Body, camera and zoom stay exactly as recorded on a truss, while an emote
					-- plays, on the frames of a shift-lock toggle, or on the frames that switch
					-- between first and third person, but the lock bit still
					-- carries the debounced state: a raw one-frame readback blip would flip the
					-- cursor and the engine lock for a frame mid-run.
					local Baked = Locked[Index] and 1 or 0
					if Source[10] ~= Baked then
						local Copy = {}
						for Key, Value in pairs(Source) do
							Copy[Key] = Value
						end
						Copy[10] = Baked
						Out[#Out + 1] = Copy
					else
						Out[#Out + 1] = Source
					end
				else
					local Frame = {}
					for Key, Value in pairs(Source) do
						Frame[Key] = Value
					end
					Frame[1] = RoundTable(CFrameToTable(NewBody[Index]), 5)
					-- Playback toggles the lock off the recorded bit, so the debounced state has
					-- to be baked back in or a one-frame readback blip still flips the cursor
					-- and the engine lock for a frame after smoothing.
					Frame[10] = Locked[Index] and 1 or 0
					if not Seam[Index] then
						-- NewCamera already carries the body motion (it is a smoothed body-space
						-- offset), so locked and unlocked frames rebuild the same way here
						if Camera[Index] and NewCamera[Index] then
							Frame[7] = RoundTable(CFrameToTable(NewCamera[Index]), 4)
						end
					end
					-- velocity comes off the smoothed path so physics does not drag the character
					-- back towards the line the original frames were on
					local First = Index > 1 and Index - 1 or 1
					local Last = Index < Count and Index + 1 or Count
					if Climb[First] or Emote[First] or Toggle[First] or ZoomShift[First] then First = Index end
					if Climb[Last] or Emote[Last] or Toggle[Last] or ZoomShift[Last] then Last = Index end
					local Delta = Times[Last] - Times[First]
					if Delta > 1e-6 then
						local Velocity = (NewBody[Last].Position - NewBody[First].Position) * (FPS / Delta)
						Frame[5] = RoundTable(Vector3ToTable(Velocity), 4)
					end
					Out[#Out + 1] = Frame
					Smoothed = Smoothed + 1
				end
			end
		end

		for _, Frame in ipairs(ReplayTable) do
			if type(Frame) == "table" then
				Queue[#Queue + 1] = Frame
			else
				Flush()
				Out[#Out + 1] = Frame -- void / dead marker keeps its place
			end
		end
		Flush()

		ReplayTable = Out
		ReplayNeedsReload = false
		local ClimbNote = ""
		if Climbed > 0 then
			ClimbNote = " ("..Climbed.." climbing frames left as recorded)"
		end
		if Emoted > 0 then
			ClimbNote = ClimbNote.." ("..Emoted.." emote frames left as recorded)"
		end
		if Toggled > 0 then
			ClimbNote = ClimbNote.." ("..Toggled.." shift-lock toggle frames left as recorded)"
		end
		if Zoomed > 0 then
			ClimbNote = ClimbNote.." ("..Zoomed.." first/third person shift frames left as recorded)"
		end
		ConsoleMessage("Smoothed "..Smoothed.." of "..FramesBefore.." frames at strength "
			..RoundNumber(Strength, 1)..ClimbNote..". Press Save to write it to the file")
	end)
	if not ok then
		ConsoleMessage("Smooth out replay error:", tostring(err))
	end
	PlaybackCtl.Optimizing = false
end

-- Speed hack runtime: slow motion for recording only.
-- Gravity goes down by scale^2 (JumpPower goes down by scale, so jump height stays the
-- same), WalkSpeed/JumpPower by scale, and the animation hooks above slow the tracks.
-- Playback is never touched: while reading the scale is forced to 1 and the playback loop
-- drives its own gravity, animation speed and root CFrame. The camera is not touched.
do
	local SH = SpeedHack

	local function ActiveScale()
		if SH.Enabled and SH.Speed < 0.999 and not Reading then
			return SH.Speed
		end
		return 1
	end

	SH.AnimationScale = function()
		if Reading then
			-- Playback rate has to reach the animation tracks too: at half speed the body covers
			-- half the ground per recorded frame, and a track left at the recorded speed would
			-- slide the feet through it. The recorded speed stays unscaled; only the live track
			-- is multiplied, the same way the slow-motion capture scales it back down.
			return PlaybackCtl.PlaySpeed or 1
		end
		return ActiveScale()
	end

	SH.ClearPending = function()
		SH.PendingAnimations, SH.PendingBegan, SH.PendingEnded = {}, {}, {}
	end

	-- merges events still waiting for a recorded frame into the last recorded frame
	SH.FlushPending = function(TargetFrame)
		local Anims, Began, Ended = SH.PendingAnimations, SH.PendingBegan, SH.PendingEnded
		if type(TargetFrame) == "table" and (next(Anims) or next(Began) or next(Ended)) then
			if type(TargetFrame[2]) ~= "table" then TargetFrame[2] = {} end
			for _, Entry in ipairs(Anims) do
				table.insert(TargetFrame[2], Entry)
			end
			if type(TargetFrame[12]) ~= "table" then TargetFrame[12] = {} end
			if type(TargetFrame[12][1]) ~= "table" then TargetFrame[12][1] = {} end
			if type(TargetFrame[12][2]) ~= "table" then TargetFrame[12][2] = {} end
			for _, Input in ipairs(Began) do
				table.insert(TargetFrame[12][1], Input)
			end
			for _, Input in ipairs(Ended) do
				table.insert(TargetFrame[12][2], Input)
			end
		end
		SH.ClearPending()
	end

	RenderSteppedConnections.SpeedHack = function()
		if Reading then
			-- playback owns gravity, animation speed and the root part; resync after it ends
			SH.AppliedScale = nil
			return
		end
		local Scale = ActiveScale()
		local Changed = Scale ~= SH.AppliedScale
		if Changed then
			SH.AppliedScale = Scale
			if SH.RefreshAnimations then
				SH.RefreshAnimations()
			end
		end
		if Scale == 1 and not Changed then
			return -- fully restored and nothing to hold down
		end

		-- captured once: never read back our own scaled value as the base
		if not SH.BaseGravity then SH.BaseGravity = DefaultGravity or workspace.Gravity end
		local BaseGravity = DefaultGravity or SH.BaseGravity
		local TargetGravity = BaseGravity * Scale * Scale
		if math.abs(workspace.Gravity - TargetGravity) > 1e-3 then
			workspace.Gravity = TargetGravity
		end

		local Hum = Humanoid
		if not Hum or not Hum.Parent then
			SH.Humanoid = nil
			return
		end
		if SH.Humanoid ~= Hum then
			SH.Humanoid = Hum
			SH.BaseWalk = DefaultWalkSpeed or Hum.WalkSpeed
			SH.BaseJump = DefaultJumpPower or Hum.JumpPower
			SH.LastWalk, SH.LastJump = nil, nil
		end
		-- a value the physics tab (or the game) changed on its own becomes the new base
		if SH.LastWalk and math.abs(Hum.WalkSpeed - SH.LastWalk) > 1e-3 then
			SH.BaseWalk = Hum.WalkSpeed
		end
		if SH.LastJump and math.abs(Hum.JumpPower - SH.LastJump) > 1e-3 then
			SH.BaseJump = Hum.JumpPower
		end
		local Walk = (SH.BaseWalk or Hum.WalkSpeed) * Scale
		local Jump = (SH.BaseJump or Hum.JumpPower) * Scale
		local WalkChanged = math.abs(Hum.WalkSpeed - Walk) > 1e-4
		local JumpChanged = math.abs(Hum.JumpPower - Jump) > 1e-4
		if WalkChanged then Hum.WalkSpeed = Walk end
		if JumpChanged then Hum.JumpPower = Jump end
		SH.LastWalk, SH.LastJump = Hum.WalkSpeed, Hum.JumpPower

		-- Truss ladders climb at 70% of WalkSpeed, but the engine can keep the rate it grabbed
		-- with and ignore a WalkSpeed change made mid-climb. Cap the measured climb to the
		-- slowed budget so the truss never moves the character faster than the rest of the
		-- world; the recorder would otherwise bake that overspeed into the replay.
		if Scale < 0.999 and Hum:GetState() == Enum.HumanoidStateType.Climbing then
			local Root = Hum.Parent and Hum.Parent:FindFirstChild("HumanoidRootPart")
			local Velocity = Root and Root.Velocity
			if Velocity then
				local Budget = (SH.BaseWalk or Walk) * Scale * 0.7
				local Speed = Velocity.Magnitude
				if Budget > 1e-3 and Speed > Budget * 1.05 then
					Root.Velocity = Velocity * (Budget / Speed)
				end
			end
		end
		if Changed then
			ConsoleMessage(string.format("Speed hack applied: %.2fx (gravity %.2f, walkspeed %.2f, jumppower %.2f)",
				Scale, workspace.Gravity, Hum.WalkSpeed, Hum.JumpPower))
		end
	end
end
-- Commands
local Commands = {}
do
	Commands["help"] = function(Args)
		if Args == "help" then
			ConsoleMessage("help <command>: Shows a list of all commands, or a specific command")
		else
			local Command = Args[1]
			if Command then
				Command = string.lower(Command)
				if Commands[Command] then
					Commands[Command]("help")
				else
					ConsoleMessage("Command", Command, "was not found")
				end
			else
				for _,Command in pairs(Commands) do
					Command("help")
				end
			end
		end
	end
	Commands["erase"] = function(Args)
    if Args == "help" then
        ConsoleMessage("erase: Erases all data from the folder",PlaceId)
    else
        writefile(ReplayPath,ReplayFileBeginning)
        ReplayTable = {}
        ReplayNeedsReload = false
        LastLoadedPath = ReplayPath
        return ReplayPath.." has been erased (cache cleared)"
    end
end

	Commands["camstep"] = function(Args)
		if Args == "help" then
			ConsoleMessage("camstep <on|off>: Whether the recorded view is written on the same step the rig is placed. on (default) - the body and the world it turns inside are always the same sample; off - the view is only written on the render step")
		else
			local Mode = string.lower(tostring(Args[1] or ""))
			if Mode == "on" or Mode == "1" then
				PlaybackCtl.CamAtStep = true
				return "Camera written with the rig: on"
			elseif Mode == "off" or Mode == "0" then
				PlaybackCtl.CamAtStep = false
				return "Camera written with the rig: off"
			end
			return "Usage: camstep <on|off>"
		end
	end
	Commands["physstep"] = function(Args)
		if Args == "help" then
			ConsoleMessage("physstep <adaptive|fixed|default>: Physics stepping used while a replay is read. fixed solves every assembly at 240 Hz (default here - stable joint cadence), adaptive lets the engine pick 60/120/240 Hz per assembly and change it mid-run, default leaves the client setting untouched")
		else
			local Mode = string.lower(tostring(Args[1] or ""))
			local Targets = {
				adaptive = Enum.PhysicsSteppingMethod.Adaptive,
				fixed    = Enum.PhysicsSteppingMethod.Fixed,
				default  = Enum.PhysicsSteppingMethod.Default,
			}
			local Target = Targets[Mode]
			if not Target then
				return "Usage: physstep <adaptive|fixed|default>"
			end
			PlaybackCtl.SteppingPref = Target
			local Applied = pcall(function()
				if Reading then
					if PlaybackCtl.SteppingPrev == nil then
						PlaybackCtl.SteppingPrev = workspace.PhysicsSteppingMethod
					end
					workspace.PhysicsSteppingMethod = Target
				end
			end)
			return "Playback physics stepping: "..Mode..(Applied and "" or " (not supported on this client)")
		end
	end
	Commands["worldphys"] = function(Args)
		if Args == "help" then
			ConsoleMessage("worldphys <on|off>: Whether the game world keeps simulating while a replay is read. off (default) - gravity is zeroed, so nothing in the scene can push the rig; on - gravity is left alone, loose parts keep falling and moving scenery keeps moving, and the recorded root write alone holds the body")
		else
			local Mode = string.lower(tostring(Args[1] or ""))
			if Mode == "on" or Mode == "1" then
				PlaybackCtl.WorldPhys = true
				if Reading then
					workspace.Gravity = DefaultGravity
					PlaybackCtl.GravityOwned = nil
				end
				return "World physics during playback: on"
			elseif Mode == "off" or Mode == "0" then
				PlaybackCtl.WorldPhys = false
				if Reading then
					workspace.Gravity = 0
					PlaybackCtl.GravityOwned = true
				end
				return "World physics during playback: off"
			end
			return "Usage: worldphys <on|off>"
		end
	end
	Commands["sounds"] = function(Args)
		if Args == "help" then
			ConsoleMessage("sounds <on|off>: Whether playback drives the character's built-in footstep loop from the recorded ground speed. The engine only plays it off physical movement, and a replay writes the root directly, so it stays silent without this. Same Sound instance, so it can never double up. Default on")
		else
			local Mode = string.lower(tostring(Args[1] or ""))
			if Mode == "on" or Mode == "1" then
				PlaybackCtl.Sounds = true
				return "Playback character sounds: on"
			elseif Mode == "off" or Mode == "0" then
				PlaybackCtl.Sounds = false
				if PlaybackCtl.FootstepsOwned then
					local Root = Character and Character:FindFirstChild("HumanoidRootPart")
					local Sound = Root and Root:FindFirstChild("Running")
					if Sound and Sound:IsA("Sound") and Sound.IsPlaying then
						pcall(function() Sound:Stop() end)
					end
					PlaybackCtl.FootstepsOwned = nil
				end
				return "Playback character sounds: off"
			end
			return "Usage: sounds <on|off>"
		end
	end
	Commands["playspeed"] = function(Args)
		if Args == "help" then
			ConsoleMessage("playspeed <0.1-4>: Replay rate multiplier. 1 (default) - the recorded rate; 0.5 - half speed for a clip; 2 - double. Animation speed, footstep rate and frame pacing all follow it; the saved file is never changed")
		else
			local Speed = tonumber(Args[1])
			if not Speed then
				return "Usage: playspeed <0.1-4> (current "..tostring(PlaybackCtl.PlaySpeed or 1).."x)"
			end
			Speed = math.clamp(Speed, 0.1, 4)
			PlaybackCtl.PlaySpeed = Speed
			if PlaybackCtl.RefreshAnimationSpeed then
				pcall(PlaybackCtl.RefreshAnimationSpeed)
			end
			return "Playback speed: "..tostring(Speed).."x"
		end
	end
	Commands["setsdm"] = function(Args)
		if Args == "help" then
			ConsoleMessage("setsdm <number SeekDirectionMultiplier>: Sets speed multiplier when using R and T while frozen")
		else
			local Number = tonumber(Args[1]) or 1
			if Number then
				local OldValue = SeekDirectionMultiplier
				SeekDirectionMultiplier = Number
				return "SeekDirectionMultiplier has been set from "..tostring(OldValue).." to "..tostring(Number)
			end
		end
	end
	Commands["rejoin"] = function(Args)
		if Args == "help" then
			ConsoleMessage("rejoin <bool SaveReplay>: Sets one of the configs at the top of the script (PlaybackInputs, etc)")
		else
			local SaveReplay = Args[1] and string.lower(Args[1])
			ConsoleMessage("Saving...")
			if SaveReplay == "true" or SaveReplay == "yes" or SaveReplay == "1" or SaveReplay == "save" then
				SaveToFile()
			end
			ConsoleMessage("Rejoining...")
			if #game.Players:GetPlayers() <= 1 then
				game.Players.LocalPlayer:Kick("\nRejoining...")
				wait()
				game:GetService("TeleportService"):Teleport(game.PlaceId, game.Players.LocalPlayer)
			else
				game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId, game.Players.LocalPlayer)
			end
			return "Sent request to rejoin"
		end
	end
	Commands["invite"] = function(Args)
		if Args == "help" then
			ConsoleMessage("invite: Invites you to Tasability Discord")
		else
			request({
				Url = "http://127.0.0.1:6463/rpc?v=1",
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["origin"] = "https://discord.com",
				},
				Body = game:GetService("HttpService"):JSONEncode({
					["args"] = {
						["code"] = "Shyfsc2cJ9",
					},
					["cmd"] = "INVITE_BROWSER",
					["nonce"] = "."
				})
			})
			return "Sent invite (if your exploit blocked it the invite is https://discord.gg/Shyfsc2cJ9)"
		end
	end
end

-- Connection Functions
local StateChanged
local CharacterAdded
local InputBegan
local RenderStepped
local Stepped
do
	StateChanged = function(_,State)
		table.insert(HumanoidStateQueue,State.Value)
	end
	CharacterAdded = function(NewCharacter)
		Humanoid = NewCharacter:WaitForChild("Humanoid")
		Humanoid.StateChanged:Connect(StateChanged)
		RootPart = NewCharacter:WaitForChild("HumanoidRootPart")
		DefaultJumpPower = Humanoid.JumpPower
		DefaultWalkSpeed = Humanoid.WalkSpeed
		Reanimate(NewCharacter)
		Character = NewCharacter
		Humanoid.Died:Connect(function()
			Dead = true
		end)
		Dead = false
	end
	-- A release that lands while a still is up has no running recording to walk into: the
	-- tape stops at the freeze, so the release is written onto the seam frame instead of
	-- being cleared with that frame's input queue.
	SpeedHack.CloseStillKey = function(Name)
		if Writing or Reading or not Frozen then return end
		if not SpeedHack.OpenKeys[Name] then return end
		SpeedHack.OpenKeys[Name] = nil
		local Target
		for Index = #ReplayTable, 1, -1 do
			if type(ReplayTable[Index]) == "table" then
				Target = ReplayTable[Index]
				break
			end
		end
		if not Target then return end
		if type(Target[12]) ~= "table" then Target[12] = {} end
		if type(Target[12][2]) ~= "table" then Target[12][2] = {} end
		table.insert(Target[12][2], Name)
	end
	InputBegan = function(Input,GameProcessed)
	if IgnoreGameProcessed then
		GameProcessed = false
	end
	
	if Input.UserInputType == Enum.UserInputType.MouseButton1 then
		if not SpeedHack.HeldInputs["b1"] then
			SpeedHack.HeldInputs["b1"] = true
			table.insert(InputBeganQueue,"b1")
		end
	elseif Input.UserInputType == Enum.UserInputType.MouseButton2 then
		if not SpeedHack.HeldInputs["b2"] then
			SpeedHack.HeldInputs["b2"] = true
			table.insert(InputBeganQueue,"b2")
		end
	elseif Input.UserInputType == Enum.UserInputType.Keyboard then
		local InputName = string.split(tostring(Input.KeyCode),".")[3]
		-- one down per hold: a bridge that injects repeated keydowns would otherwise write
		-- the same press into the tape many times, and playback would stack synthetic downs
		-- that a single recorded release can never clear
		if not InputBlacklist[InputName] and not SpeedHack.HeldInputs[InputName] then
			SpeedHack.HeldInputs[InputName] = true
			table.insert(InputBeganQueue,InputName)
		end
	end
	
	if Input.KeyCode == Enum.KeyCode.LeftShift and not Reading and not GameProcessed then
		if Frozen then
			-- a still repaints the tracked bit from the recorded frame every render, so it is not
			-- the lock to toggle from: pressing shift twice would read the repainted tape bit both
			-- times and leave the player on the same side of it. Toggle the lock the game
			-- actually has; the unfreeze hands that state back.
			local Live = PlaybackCtl.LiveShiftLock()
			local Base = ShiftLockEnabled
			if Live ~= nil then Base = Live end
			local Want = not Base
			SetShiftLockEnabled(Want, true)
			pcall(function()
				shiftLock(Want)
			end)
		else
			SetShiftLockEnabled(not ShiftLockEnabled)
		end
	end
	
	if Input.KeyCode == Recordkeybind.Value and not GameProcessed then
		-- Freeze/Unfreeze. The HappaTAS debounce owns the controls while an unpause
		-- prologue runs; a freeze landing inside it would split the seam frame.
		if not PlaybackCtl.Resuming then
			Freeze(not Frozen)
		end
	elseif Input.KeyCode == Gobackwardskeybind.Value and not GameProcessed then
		if not Reading and not PlaybackCtl.Resuming then
			Freeze(true)
			if SeekDirection == 0 then
				SeekDirection = -1*SeekDirectionMultiplier -- Backwards
			end
		end
	elseif Input.KeyCode == Goforwardkeybind.Value and not GameProcessed then
		-- Seek fowards
		if not Reading and not PlaybackCtl.Resuming then
			Freeze(true)
			if SeekDirection == 0 then
				SeekDirection = 1*SeekDirectionMultiplier -- Fowards
			end
		end
	elseif Input.KeyCode == Frameadvancebackwardskeybind.Value and not GameProcessed and not PlaybackCtl.Resuming then
		-- Go 1 frame backwards
		Freeze(true)
		if Frozen and SeekDirection == 0 then
			local NewFreezeFrame = FreezeFrame - 1
			if NewFreezeFrame > 0 and NewFreezeFrame <= #ReplayTable then
				FreezeFrame = NewFreezeFrame
			end
		end
	elseif Input.KeyCode == Frameadvanceforwardkeybind.Value and not GameProcessed and not PlaybackCtl.Resuming then
		-- Go 1 frame fowards
		Freeze(true)
		if Frozen and SeekDirection == 0 then
			local NewFreezeFrame = FreezeFrame + 1
			if NewFreezeFrame > 0 and NewFreezeFrame <= #ReplayTable then
				FreezeFrame = NewFreezeFrame
			end
		end
	elseif Input.KeyCode == Hideuikeybind.Value and not GameProcessed then
		-- Toggle UI
		Window:ToggleVisibility()
	elseif Input.KeyCode == Abortkeybind.Value and not GameProcessed then
		-- Stop reading
		StopReading()
	elseif Input.KeyCode == Savekeybind.Value and not GameProcessed then
		-- Save to file
		SaveToFile()
	elseif Input.KeyCode == Frozenkeybind.Value and not GameProcessed then
		-- Frozen to idle
		IdleButton_MouseButton1Click()
	elseif Input.KeyCode == Readkeybind.Value and not GameProcessed then
		ReadButton_MouseButton1Click()
	elseif Input.KeyCode == Pausekeybind.Value and not GameProcessed then
		-- Pause/Resume reading
		PlaybackCtl.Toggle()
	elseif Input.KeyCode == Unpausekeybind.Value and not GameProcessed then
		-- Unpause for one frame (frame advance)
		PlaybackCtl.Step()
	elseif Input.KeyCode == Takeoverkeybind.Value and not GameProcessed then
		-- Unpause, take control and record from here
		PlaybackCtl.TakeOver()
	elseif Input.KeyCode == LookAroundkeybind.Value and not GameProcessed then
		-- hand the view to the stock camera while a still is on screen
		PlaybackCtl.ToggleLookAround()
	end
end
	InputChanged = function(Input,GameProcessed)
		if Input.UserInputType == Enum.UserInputType.MouseWheel then
			if Input.Position.Z > 0 then
				table.insert(InputBeganQueue,"u")
			else
				table.insert(InputBeganQueue,"d")
			end
		end
	end
	InputEnded = function(Input,GameProcessed)
		if Input.UserInputType == Enum.UserInputType.MouseButton1 then
			SpeedHack.HeldInputs["b1"] = nil
			table.insert(InputEndedQueue,"b1")
			SpeedHack.CloseStillKey("b1")
		elseif Input.UserInputType == Enum.UserInputType.MouseButton2 then
			SpeedHack.HeldInputs["b2"] = nil
			table.insert(InputEndedQueue,"b2")
			SpeedHack.CloseStillKey("b2")
		elseif Input.UserInputType == Enum.UserInputType.MouseWheel then
			if Input.Position.Z > 0 then
				table.insert(InputEndedQueue,"u")
			else
				table.insert(InputEndedQueue,"d")
			end
		elseif Input.UserInputType == Enum.UserInputType.Keyboard then
			local InputName = string.split(tostring(Input.KeyCode),".")[3]
			SpeedHack.HeldInputs[InputName] = nil
			table.insert(InputEndedQueue,InputName)
			SpeedHack.CloseStillKey(InputName)
		end
		
		if Input.KeyCode == Gobackwardskeybind.Value then
			-- Stop seeking backwards
			if SeekDirection == -1*SeekDirectionMultiplier then
				SeekDirection = 0
			end
		elseif Input.KeyCode == Goforwardkeybind.Value then
			-- Stop seeking fowards
			if SeekDirection == 1*SeekDirectionMultiplier then
				SeekDirection = 0
			end
		end
	end
	RenderStepped = function(...)
		for _,Function in pairs(RenderSteppedConnections) do
			Function(...)
		end
	end
	Stepped = function(...)
		for _,Function in pairs(SteppedConnections) do
			Function(...)
		end
	end
	ReadButton_MouseButton1Click = function()
		if ReplayStartTime >= 1 then
			for i = ReplayStartTime,1,-1 do
				ConsoleMessage("Reading in "..tostring(i).." seconds")
				wait(1)
			end
		end
		StartReading()
	end
	IdleButton_MouseButton1Click = function()
		if GetColorCodeFrame() == "Frozen" then
			Freeze(false,true)
		end
	end
	ConsoleInput.Callback = function(self, value)
		local Input = value
		local InputSplit = string.split(Input," ")
		local Command = Commands[string.lower(InputSplit[1])]
		if Command then
			table.remove(InputSplit,1)
			local ReturnMessage = Command(InputSplit)
			if ReturnMessage then
				ConsoleMessage(ReturnMessage)
			end
		else
			ConsoleMessage("Command",InputSplit[1],"was not found")
		end
		self:Clear()
	end
end

-- RenderStepped/Stepped connections
do
    -- The rig is placed before the physics step, not before the render: the joints are solved
    -- during that step, so a root written after it is one step fresher than the torso pose that
    -- hangs off it, and on a turn that mismatch is the torso arriving a moment behind the rest.
    -- Applied here, the root and the joint solve belong to the same step, and the view is drawn
    -- from the pose that was applied, so the camera and the body are the same sample.
    PlaybackCtl.ApplyPose = function()
        if not (Reading and not Frozen and InterpHRPPrev and InterpHRPTarget) then return end

        -- The render head is a continuous playhead over the recorded frames: it moves with
        -- wall-clock time at the recorded rate, not with the frames this heartbeat happened
        -- to take. A beat that pulls two frames and a beat that pulls none then render as
        -- the same travel. Without it the rig alternated between a hold and a lurch under
        -- heartbeat jitter, and a capture of that alternation reads as a sped-up tape.
        if PlaybackCtl.FrameInterp then
            local Head = PlaybackCtl.AppliedIndex
            if Head then
                local Now = tick()
                local Pos = PlaybackCtl.RenderPos
                if not Pos or Paused then
                    Pos = Head
                else
                    local Dt = Now - (PlaybackCtl.RenderAt or Now)
                    if Dt < 0 then Dt = 0 elseif Dt > 0.1 then Dt = 0.1 end
                    local Rate = PlaybackCtl.FileFPS or FPS
                    if not Rate or Rate < 1 then Rate = 60 end
                    Pos = Pos + Dt * Rate * (PlaybackCtl.PlaySpeed or 1)
                end
                -- keep the head within a frame of the applied pose after a hitch: a head left
                -- far ahead would sit on its clamp for the rest of the run, rendering in steps
                -- again, and one left far behind would draw a pose the run has already left.
                if Pos < Head - 1 then Pos = Head - 1 end
                if Pos > Head + 1 then Pos = Head + 1 end
                PlaybackCtl.RenderPos = Pos
                PlaybackCtl.RenderAt = Now
            end
        elseif PlaybackCtl.RenderPos then
            PlaybackCtl.RenderPos = nil
            PlaybackCtl.RenderAt = nil
        end

        local alpha = math.clamp((tick() - InterpStart) / InterpDuration, 0, 1)

        -- Frame interpolation (HappaTAS): the rig is drawn at the weighted average of the frame
        -- that was applied and the one in front of it, sampled where the playhead sits between
        -- them, instead of easing into each recorded frame.
        local InterpRoot, InterpCam
        if PlaybackCtl.FrameInterp and PlaybackCtl.SampleInterpolatedFrame then
            InterpRoot, InterpCam = PlaybackCtl.SampleInterpolatedFrame()
        end

        if InterpRoot then
            if Character and Character:FindFirstChild("HumanoidRootPart") then
                local Root = Character.HumanoidRootPart
                Root.CFrame = InterpRoot
                Root.Velocity    = Vector3.zero
                Root.RotVelocity = Vector3.zero
                PlaybackCtl.AlignRig()
            end
            PlaybackCtl.CamShown = InterpCam
        else
            local DrawRoot = InterpHRPPrev:Lerp(InterpHRPTarget, alpha)
            if PlaybackCtl.InterpCamPrev and PlaybackCtl.InterpCamTarget then
                PlaybackCtl.CamShown = PlaybackCtl.InterpCamPrev:Lerp(PlaybackCtl.InterpCamTarget, alpha)
            end
            if Character and Character:FindFirstChild("HumanoidRootPart") then
                local Root = Character.HumanoidRootPart
                Root.CFrame = DrawRoot
                -- The solver takes the step with a still root: a velocity fed to it as well would run
                -- the body ahead of the recording between writes, straight through corners and into
                -- walls. The recorded velocity is put back after the step, for everything that reads it.
                Root.Velocity    = Vector3.zero
                Root.RotVelocity = Vector3.zero
                PlaybackCtl.AlignRig()
            end
        end

        -- The view is put on the camera here as well as on the render step, from the one value the
        -- rig just took. Whichever of the two callbacks sits closest to the draw, the body and the
        -- world it is turning inside are showing the same recorded frame, with no beat between
        -- them. A hand-off or a start settle owns the view until it finishes, so those are left alone.
        local Cam = workspace.CurrentCamera
        if Cam and PlaybackCtl.CamShown and PlaybackCtl.CamAtStep ~= false
            and not PlaybackCtl.CamBlend and not PlaybackCtl.CamIntro then
            Cam.CFrame = PlaybackCtl.CamShown
        end

        -- Distance is the last channel still landing in recorded-frame steps: a scroll comes out
        -- of the replay as a stair while the body and the view slide past it. Eased on the same
        -- alpha, it covers the gap the way a hand on the wheel covers it.
        if PlaybackCtl.ZoomPrev and PlaybackCtl.ZoomTarget then
            -- A run that starts in a different camera mode would cut to the recorded distance on
            -- frame one, right under a view that is easing in. Ride the settle's own ease instead,
            -- so the shot comes out of the old distance the way a hand would pull it back.
            local ZoomAlpha = alpha
            local Intro = PlaybackCtl.CamIntro
            if Intro then
                local IntroAlpha = math.clamp((tick() - Intro.Start) / Intro.Duration, 0, 1)
                ZoomAlpha = IntroAlpha * IntroAlpha * (3 - 2 * IntroAlpha)
            end
            local ZoomShown = PlaybackCtl.ZoomPrev
                + (PlaybackCtl.ZoomTarget - PlaybackCtl.ZoomPrev) * ZoomAlpha
            PlaybackCtl.ZoomShown = ZoomShown
            SetZoom(ZoomShown)
        end

        PlaybackCtl.SteppedAt = tick()
        CO.UpdateInterpolation()
    end

    SteppedConnections.PlaybackBody = PlaybackCtl.ApplyPose

    -- The weld is reasserted on every step and every render, not only when a recorded frame is
    -- applied: a game script that re-enables the motor, a respawned rig, or a joint that was
    -- rebuilt all get the lock back before anything is drawn, so the torso never spends a solve
    -- on the animation's heading while the run is playing.
    SteppedConnections.AlignRig = function()
        if Reading or Frozen then PlaybackCtl.AlignRig() end
    end
    RenderSteppedConnections.AlignRig = function()
        if Reading or Frozen then PlaybackCtl.AlignRig() end
    end

    RenderSteppedConnections.FrameInterpolation = function()
        -- only if this client never raises Stepped during playback
        if PlaybackCtl.SteppedAt and tick() - PlaybackCtl.SteppedAt < 0.05 then return end
        PlaybackCtl.ApplyPose()
    end

	local LastFreezeText = nil
	RenderSteppedConnections.UpdateFreezeFrame = function()
		local Text
		if Reading and ReplayTable then
			Text = "Frames: "..RoundNumber(ReplayTableIndex,0).." / "..#ReplayTable..(Paused and " (paused)" or "")
		else
			Text = "Frames: "..RoundNumber(FreezeFrame,0)
		end
		-- a property write rebuilds the text layout even when the string is identical; this
		-- label only changes when the playhead does
		if Text ~= LastFreezeText then
			LastFreezeText = Text
			RecordedFramesLabel.Text = Text
		end
	end

	RenderSteppedConnections.DrawPathVisuals = function()
        if pathVisualsEnabled then
            drawPathVisuals()
        end
    end

	RenderSteppedConnections.SeekDirectionHandler = function()
		if Frozen and ReplayTable then
			local NewFreezeFrame = FreezeFrame + SeekDirection
			if NewFreezeFrame < 1 then
				FreezeFrame = 1
			elseif NewFreezeFrame > #(ReplayTable or {}) then
				FreezeFrame = #(ReplayTable or {})
			else
				FreezeFrame = NewFreezeFrame
			end
		end
	end

	-- the overlay is redrawn every step; a key that is not changing does not need its colors
	-- written again, and the write is what costs
	local OverlayKeyStates = setmetatable({}, {__mode = "k"})
    	SteppedConnections.UpdateKeyboardOverlay = function()
        if getgenv().KeyboardOverlayEnabled and getgenv().KeyboardOverlayKeys then
            local keys = getgenv().KeyboardOverlayKeys
            local theme = KeyboardOverlayThemes[currentTheme]
            
            local keysToCheck = Writing and SpeedHack.OpenKeys or Pressed
            
            for keyName, keyFrame in pairs(keys) do
                local state = "normal"
                
                if keysToCheck[keyName] then
                    state = Writing and "writing" or "pressed"
                end
                
                if OverlayKeyStates[keyFrame] ~= state then
                    OverlayKeyStates[keyFrame] = state
                    theme.updateColors(keyFrame, state)
                end
            end
        end
    end

	local PressedText, WritingText
	local PressedParts = {"Pressed keys: |"}
	local WritingParts = {"Writing Pressed keys: |"}
	SteppedConnections.UpdateInputPreview = function()
		for _,Input in ipairs(InputBeganQueue) do
			if Input ~= "u" and Input ~= "d" then
				Pressed[Input] = true
			end
		end

		for _,Input in ipairs(InputEndedQueue) do
			Pressed[Input] = nil
		end

		for Index = #PressedParts, 2, -1 do
			PressedParts[Index] = nil
		end
		for Input in pairs(Pressed) do
			PressedParts[#PressedParts + 1] = Input.."|"
		end
		local NextPressed = table.concat(PressedParts)
		if NextPressed ~= PressedText then
			PressedText = NextPressed
			PressedKeysLabel.Text = NextPressed
		end
		
		if Writing then
			for Index = #WritingParts, 2, -1 do
				WritingParts[Index] = nil
			end
			for Input in pairs(SpeedHack.OpenKeys) do
				WritingParts[#WritingParts + 1] = Input.."|"
			end
			local NextWriting = table.concat(WritingParts)
			if NextWriting ~= WritingText then
				WritingText = NextWriting
				WritingPressedKeysLabel.Text = NextWriting
			end
		end
	end
end

do -- Connections
	UserInputService.InputBegan:Connect(InputBegan)
	UserInputService.InputChanged:Connect(InputChanged)
	UserInputService.InputEnded:Connect(InputEnded)
	UserInputService.WindowFocusReleased:Connect(function()
		if Reading then return end
		-- a keyup released while the window is not focused may never reach the game: close the
		-- tape's open keys and drop the live display so nothing stays lit after the release
		if Writing then
			local Closing = {}
			for Name in pairs(SpeedHack.OpenKeys) do
				table.insert(Closing, Name)
			end
			for _, Name in ipairs(Closing) do
				SpeedHack.OpenKeys[Name] = nil
				table.insert(InputEndedQueue, Name)
			end
		end
		SpeedHack.HeldInputs = {}
		for Name in pairs(Pressed) do
			Pressed[Name] = nil
		end
		-- a seek drag that was released outside the window never sees its mouseup: the playhead
		-- would keep following the cursor with no button held
		SeekDirection = 0
	end)
	RunService.RenderStepped:Connect(RenderStepped)
	RunService.Stepped:Connect(Stepped)
	Player.CharacterAdded:Connect(CharacterAdded)

	-- The default camera module runs at RenderPriority.Camera and writes the view from the
	-- character every frame, later than any RenderStepped connection. Binding one step after it
	-- makes the recorded camera the last write of the frame while leaving the module alive, so
	-- first person still hides the local body and the zoom state still drives occlusion.
	RunService:BindToRenderStep("TasabilityPlaybackCamera", Enum.RenderPriority.Camera.Value + 1, function()
		if not (Reading or PlaybackCtl.CameraHold or PlaybackCtl.CamBlend) then return end
		-- look-around: the still is parked and the view belongs to the stock camera until the
		-- flag clears; every path out of the still clears it before writing a new state
		if PlaybackCtl.LookAround and (Frozen or (Reading and Paused)) then return end
		local Cam = workspace.CurrentCamera
		local Blend = PlaybackCtl.CamBlend
		if Blend then
			-- The module has already written this frame at RenderPriority.Camera, so whatever is
			-- in CurrentCamera right now is the pose being handed over to.
			local Alpha  = math.clamp((tick() - Blend.Start) / Blend.Duration, 0, 1)
			local Eased  = Alpha * Alpha * (3 - 2 * Alpha)
			Cam.CFrame   = Blend.From:Lerp(Cam.CFrame, Eased)
			if Alpha >= 1 then
				PlaybackCtl.CamBlend = nil
			end
			return
		end
		local Intro = PlaybackCtl.CamIntro
		if Intro and Reading and not Frozen and PlaybackCtl.CamShown then
			local Alpha = math.clamp((tick() - Intro.Start) / Intro.Duration, 0, 1)
			local Eased = Alpha * Alpha * (3 - 2 * Alpha)
			Cam.CFrame  = Intro.From:Lerp(PlaybackCtl.CamShown, Eased)
			if Alpha >= 1 then
				PlaybackCtl.CamIntro = nil
			end
			return
		end
		if Reading and not Frozen and PlaybackCtl.CamShown then
			-- the very sample that went onto the rig this step, so the view and the body can
			-- never be a beat apart in a turn
			Cam.CFrame = PlaybackCtl.CamShown
		elseif Reading and not Frozen and PlaybackCtl.InterpCamPrev and PlaybackCtl.InterpCamTarget then
			local Alpha = math.clamp((tick() - InterpStart) / InterpDuration, 0, 1)
			Cam.CFrame = PlaybackCtl.InterpCamPrev:Lerp(PlaybackCtl.InterpCamTarget, Alpha)
		elseif CameraCFrame then
			Cam.CFrame = CameraCFrame
		end
	end)
end

do -- Setup
	-- folder and file creation is filesystem work on the executor's side; a locked or missing
	-- store has to leave the rest of setup running, and playback reports its own read errors
	pcall(GetReplayFile)
	SetCursor("ArrowFarCursor") -- Add fake cursor - MUST BE BEFORE HIDING REAL CURSOR
	UserInputService.MouseIconEnabled = false -- Remove real cursor
	DefaultGravity = Workspace.Gravity -- Set DefaultGravity
	if ShiftLockBoundKeys then
		ShiftLockBoundKeys.Value = "" -- Remove shift lock keybinds
	end
	-- the character exists only after the first spawn; setup can run before it
	if Player.Character then
		CharacterAdded(Player.Character) -- Set character
	end
	SetColorCodeFrame("Idle") -- Set color code
end

local function findAnimateScript(character)
    if not character then return nil end
          
    local names = {
        "Animate",
        "AnimationScript",
        "CharacterAnimate",
        "PlayerAnimate"
    }

    for _, name in ipairs(names) do
        local s = character:FindFirstChild(name, true)
        if s and s:IsA("LocalScript") then
            return s
        end
    end

    for _, obj in ipairs(character:GetDescendants()) do
        if obj:IsA("LocalScript") then
            for _, sub in ipairs(obj:GetChildren()) do
                local n = sub.Name:lower()
                if n == "idle" or n == "walk" or n == "run" or n == "jump" or n == "fall" then
                    return obj
                end
            end
        end
    end

    return nil
end


spawn(function() -- Reading Loop (supervised)
while true do
local ok, err = pcall(function()
    local idleFrameCount = 0
    local idle_threshold = 3

    while true do
        if Reading then
            local Stepping = false
            if Paused then
                if PlaybackCtl.StepOnce then
                    PlaybackCtl.StepOnce = false
                    Stepping = true
                else
                    if SpeedHack.HoldAnimations then
                        SpeedHack.HoldAnimations(true)
                    end
                    -- keep reasserting it: a single stepped shift-lock frame turns camera-relative
                    -- back on, and the pause has to stay a still
                    PlaybackCtl.SetRotationType(false)
                    -- a frozen body is not taking steps: do not leave the loop running under it
                    if PlaybackCtl.FootstepsOwned then
                        local Root = Character and Character:FindFirstChild("HumanoidRootPart")
                        local PausedSound = Root and Root:FindFirstChild("Running")
                        if PausedSound and PausedSound:IsA("Sound") and PausedSound.IsPlaying then
                            PausedSound:Stop()
                        end
                    end
                    RunService.Heartbeat:Wait()
                    continue
                end
            end

            -- Wall-clock pacing, counted in recorded frames. One recorded frame per heartbeat is
            -- only the recorded rate when the client happens to run at exactly that rate: above
            -- it the run plays high, and below it - a 60 Hz display on a 120 fps capture - at half
            -- speed. Spend real time instead: a frame is taken once its own interval has elapsed,
            -- and a slower client takes several in the same heartbeat. Debt is capped at a few
            -- intervals and the excess is discarded, so a hitch cannot turn into a burst of
            -- catch-up frames. The playback rate divides the interval: 0.5 spends twice the time
            -- per frame, 2 takes twice as many per heartbeat (the cap follows it so fast playback
            -- is not silently held at the display rate).
            local Skip = 0
            local Hitch = false
            if not Stepping then
                local PlaySpeed = PlaybackCtl.PlaySpeed or 1
                local Interval = 1 / math.max(FPS * PlaySpeed, 1)
                local MaxSteps = math.max(4, math.ceil(PlaySpeed * 4))
                local Now = tick()
                local Dt = Now - (PlaybackCtl.PaceLast or Now)
                PlaybackCtl.PaceLast = Now
                Hitch = Dt > MaxSteps * Interval
                PlaybackCtl.PaceDebt = (PlaybackCtl.PaceDebt or 1) + math.clamp(Dt, 0, MaxSteps * Interval)
                local StepCount = math.floor(PlaybackCtl.PaceDebt / Interval + 1e-6)
                if StepCount < 1 then
                    RunService.Heartbeat:Wait()
                    continue
                end
                if StepCount > MaxSteps then StepCount = MaxSteps end
                PlaybackCtl.PaceDebt = math.min(PlaybackCtl.PaceDebt - StepCount * Interval, Interval)
                -- The frames taken in between are not dropped silently: a marker or the end of
                -- the replay has to be handled on its own, so the jump stops in front of one.
                Skip = StepCount - 1
                if Skip > 0 then
                    if type(ReplayTable[ReplayTableIndex]) ~= "table" then
                        Skip = 0
                    else
                        for Offset = 1, Skip do
                            if type(ReplayTable[ReplayTableIndex + Offset]) ~= "table" then
                                Skip = Offset - 1
                                break
                            end
                        end
                    end
                end
            else
                PlaybackCtl.PaceLast = tick()
            end

            local Frame = ReplayTable[ReplayTableIndex + Skip]

            if Frame == 0 then
                Humanoid:ChangeState(15)
                for _,Descendant in pairs(Character:GetDescendants()) do
                    if Descendant:IsA("BasePart") then
                        Descendant:Destroy()
                    end
                end
                repeat wait() until not Dead or not Reading
                if Character and Character:FindFirstChild("Humanoid") then
                    Character.Humanoid.JumpPower = 0
                    Character.Humanoid.WalkSpeed = 0
                    Character.Humanoid.PlatformStand = true
                end
                if Character then
                    for _,v in pairs(Character:GetChildren()) do
                        if v:IsA("BasePart") and not v.CanCollide then
                            v.CanCollide = true
                        end
                    end
                end
                _CachedAnimateScript = nil
                -- Reset interp on a respawn
                InterpHRPPrev = nil
                InterpHRPTarget = nil
                PlaybackCtl.AppliedIndex = nil
                PlaybackCtl.RenderPos = nil
                PlaybackCtl.RenderAt = nil
                PlaybackCtl.CamShown = nil
                PlaybackCtl.ZoomPrev = nil
                PlaybackCtl.ZoomTarget = nil
                PlaybackCtl.ZoomShown = nil
                PlaybackCtl.MouseLastLook = nil
                CO.ClearInterpolation()
                PlaybackCtl.NeedsAnimSeed = true
                RunService.Heartbeat:Wait()
                ReplayTableIndex = ReplayTableIndex + 1
                idleFrameCount = 0
                continue
            elseif Frame == 1 then
                Humanoid:ChangeState(15)
                workspace.Gravity = DefaultGravity
                repeat wait() until not Dead or not Reading
                if Character and Character:FindFirstChild("Humanoid") then
                    Character.Humanoid.JumpPower = 0
                    Character.Humanoid.WalkSpeed = 0
                    Character.Humanoid.PlatformStand = true
                end
                if Character then
                    for _,v in pairs(Character:GetChildren()) do
                        if v:IsA("BasePart") and not v.CanCollide then
                            v.CanCollide = true
                        end
                    end
                end
                _CachedAnimateScript = nil
                InterpHRPPrev = nil
                InterpHRPTarget = nil
                PlaybackCtl.AppliedIndex = nil
                PlaybackCtl.RenderPos = nil
                PlaybackCtl.RenderAt = nil
                PlaybackCtl.CamShown = nil
                PlaybackCtl.ZoomPrev = nil
                PlaybackCtl.ZoomTarget = nil
                PlaybackCtl.ZoomShown = nil
                PlaybackCtl.MouseLastLook = nil
                CO.ClearInterpolation()
                PlaybackCtl.NeedsAnimSeed = true
                RunService.Heartbeat:Wait()
                ReplayTableIndex = ReplayTableIndex + 1
                idleFrameCount = 0
                continue
            end

            if not Frame then
                -- the tape ran out on its own: close the run with its length, the way HappaTAS
                -- closes a test with the total time instead of a bare stop
                local Rate = PlaybackCtl.FileFPS or FPS
                local Seconds = (Rate and Rate > 0) and (#ReplayTable / Rate) or 0
                local Mins = math.floor(Seconds / 60)
                ConsoleMessage(string.format("Replay completed - %d frames, %d:%05.2f", #ReplayTable, Mins, Seconds - Mins * 60))
                StopReading()
                continue
            end

            if typeof(Frame) == "string" then
                StopReading()
                continue
            end

            -- the frame the pose below is actually taken from, for the render head to anchor on
            PlaybackCtl.AppliedIndex = ReplayTableIndex + Skip

            if not _CachedAnimateScript or _CachedAnimateScript.Parent == nil then
                -- A game with no Animate script would otherwise walk the whole character on
                -- every played frame. A miss is retried twice a second, and immediately when
                -- the character itself is replaced.
                local ScanNow = tick()
                if PlaybackCtl.AnimateScanChar ~= Character
                    or not PlaybackCtl.AnimateScanAt
                    or ScanNow - PlaybackCtl.AnimateScanAt >= 0.5 then
                    PlaybackCtl.AnimateScanChar = Character
                    PlaybackCtl.AnimateScanAt = ScanNow
                    _CachedAnimateScript = findAnimateScript(Character)
                end
            end
            if _CachedAnimateScript and not _CachedAnimateScript.Disabled then
                _CachedAnimateScript.Disabled = true
            end

            if not AnimateDisabled then AnimateDisabled = true end
            if not PlaybackCtl.WorldPhys and workspace.Gravity ~= 0 then workspace.Gravity = 0 end
            if Humanoid.JumpPower ~= 0 then Humanoid.JumpPower = 0 end
            if Humanoid.WalkSpeed ~= 0 then Humanoid.WalkSpeed = 0 end
            if not Humanoid.PlatformStand then Humanoid.PlatformStand = true end
            -- playback owns the root rotation; left on, the engine yaws the body toward the
            -- replayed movement keys between frames and the torso drifts off the recorded heading
            if Humanoid.AutoRotate then Humanoid.AutoRotate = false end

            if not Character:FindFirstChild("HumanoidRootPart") then
                RunService.Heartbeat:Wait()
                continue
            end

            local HRP = Character.HumanoidRootPart

            local hrpCFrame      = FastTableToCFrame(Frame[1])
            local animations     = Frame[2] or {}
            local animSpeed      = Frame[3] or 1
            local humanoidState  = Frame[4]
            local hrpVel         = FastTableToVector3(Frame[5])
            local hrpRotVel      = FastTableToVector3(Frame[6])
            local camCFrame      = FastTableToCFrame(Frame[7])
            local zoom           = Frame[8]
            local animPose       = Frame[9]
            local shiftLock      = (Frame[10] == 1)
            -- the recorded run's shift lock decides whether the engine may turn the body with
            -- the camera, exactly like HappaTAS's ShiftlockRotation channel
            PlaybackCtl.SetRotationType(shiftLock)
            local mouseLocation  = FastTableToVector2(Frame[11])
            local inputBegan     = (Frame[12] and Frame[12][1]) or {}
            local inputEnded     = (Frame[12] and Frame[12][2]) or {}

            if Skip > 0 then
                -- A client slower than the capture shows one pose out of several. The skipped
                -- frames still carry one-shot events - animation transitions and key presses -
                -- so those are folded into the frame that is shown, in order: a jump that starts
                -- between two heartbeats would otherwise never play its animation.
                local MergedAnims, MergedBegan, MergedEnded, MergedCO = {}, {}, {}, {}
                for Offset = 0, Skip - 1 do
                    local Skipped = ReplayTable[ReplayTableIndex + Offset]
                    if type(Skipped[2]) == "table" then
                        for _, Entry in ipairs(Skipped[2]) do
                            MergedAnims[#MergedAnims + 1] = Entry
                        end
                    end
                    local Events = Skipped[12]
                    if type(Events) == "table" then
                        for _, Entry in ipairs(Events[1] or {}) do
                            MergedBegan[#MergedBegan + 1] = Entry
                        end
                        for _, Entry in ipairs(Events[2] or {}) do
                            MergedEnded[#MergedEnded + 1] = Entry
                        end
                    end
                    -- The object channel is sparse: a part that only moved on a skipped frame
                    -- is absent from the frame that gets shown, and would stay parked. Merge it
                    -- in; every entry is an absolute CFrame, so the latest write per part wins.
                    local Objects = Skipped[13]
                    if type(Objects) == "table" then
                        for Key, Components in pairs(Objects) do
                            MergedCO[Key] = Components
                        end
                    end
                end
                for _, Entry in ipairs(animations) do
                    MergedAnims[#MergedAnims + 1] = Entry
                end
                for _, Entry in ipairs(inputBegan) do
                    MergedBegan[#MergedBegan + 1] = Entry
                end
                for _, Entry in ipairs(inputEnded) do
                    MergedEnded[#MergedEnded + 1] = Entry
                end
                if type(Frame[13]) == "table" then
                    for Key, Components in pairs(Frame[13]) do
                        MergedCO[Key] = Components
                    end
                end
                animations, inputBegan, inputEnded = MergedAnims, MergedBegan, MergedEnded
                PlaybackCtl.MergedCO = MergedCO
            elseif PlaybackCtl.MergedCO then
                PlaybackCtl.MergedCO = nil
            end

            local velocityMagnitude = hrpVel.Magnitude
            local isOnGround = humanoidState == 8 or humanoidState == 0 or humanoidState == 2
            local isClimbing = humanoidState == 12
            local isSeated   = humanoidState == 13
            local isStationary = velocityMagnitude < 0.1

            if isStationary and isOnGround and not isClimbing and not isSeated then
                idleFrameCount = idleFrameCount + 1
            else
                idleFrameCount = 0
            end

            local shouldForceIdle = idleFrameCount >= idle_threshold and isOnGround and not isClimbing and not isSeated

            pose = animPose
            Humanoid:ChangeState(humanoidState)

            -- Footsteps are the one sound a replay normally loses: the engine plays the
            -- character's loop off physical movement, and a root that is placed instead of
            -- pushed reports none. Drive the character's own Running sound from the recorded
            -- ground speed. It is the same instance the engine uses, so if the engine is
            -- already playing it this only sets the rate - it can never be doubled.
            local RunningSound = HRP:FindFirstChild("Running")
            if RunningSound and RunningSound:IsA("Sound") then
                local WantSteps = PlaybackCtl.Sounds ~= false
                    and humanoidState == Enum.HumanoidStateType.Running.Value
                    and velocityMagnitude > 2
                if WantSteps then
                    if not RunningSound.IsPlaying then
                        PlaybackCtl.FootstepsOwned = true
                        RunningSound:Play()
                    end
                    -- steps land at the rate the body covers ground, so a slowed replay has
                    -- slower steps instead of a walk cycle running away from the feet
                    RunningSound.PlaybackSpeed = math.clamp(velocityMagnitude / 16, 0.5, 1.8)
                        * (PlaybackCtl.PlaySpeed or 1)
                elseif PlaybackCtl.FootstepsOwned and RunningSound.IsPlaying then
                    RunningSound:Stop()
                end
            end

            -- A replay can start, or resume after a respawn, with the animation already under
            -- way: no transition is recorded on that frame and the fresh character sits in
            -- idle. Seed from the pose channel so a run that begins on a truss or mid-air is
            -- not replayed in the wrong animation until the next transition arrives.
            if PlaybackCtl.NeedsAnimSeed then
                PlaybackCtl.NeedsAnimSeed = nil
                if #animations == 0 then
                    local Seed
                    if animPose == "Running" then
                        Seed = "walk"
                    elseif animPose == "Jumping" then
                        Seed = "jump"
                    elseif animPose == "FreeFall" then
                        Seed = "fall"
                    elseif animPose == "Climbing" then
                        Seed = "climb"
                    elseif animPose == "Seated" then
                        Seed = "sit"
                    end
                    if Seed then
                        local SeedId = PlaybackCtl.LastVariantFor and PlaybackCtl.LastVariantFor(ReplayTableIndex + Skip, Seed)
                        playAnimation(Seed, 0.0, Humanoid, true, SeedId)
                        setAnimationSpeed(animSpeed)
                        -- the run was already mid-cycle: land the fresh track on the phase
                        -- the recording had reached instead of its first pose
                        if PlaybackCtl.SyncAnimationPhase then
                            PlaybackCtl.SyncAnimationPhase(ReplayTableIndex + Skip)
                        end
                    end
                end
            end

            if shouldForceIdle then
                local hasWalkOrRun = false
                for _, Arguments in ipairs(animations) do
                    local animName = Arguments[1]
                    if animName == "walk" or animName == "run" then
                        hasWalkOrRun = true
                        break
                    end
                end
                if hasWalkOrRun then
                    playAnimation("idle", 0.1, Humanoid, true)
                    setAnimationSpeed(1.0)
                else
                    for _, Arguments in ipairs(animations) do
                        playAnimation(Arguments[1], Arguments[2], Humanoid, true, Arguments[3])
                    end
                    setAnimationSpeed(animSpeed)
                end
            else
                for _, Arguments in ipairs(animations) do
                    playAnimation(Arguments[1], Arguments[2], Humanoid, true, Arguments[3])
                end
                setAnimationSpeed(animSpeed)
            end

            -- stepping onto a frame mid-animation shows the pose the run had there, not the
            -- start of the cycle (Happa backtracking)
            if Stepping and PlaybackCtl.SyncAnimationPhase then
                PlaybackCtl.SyncAnimationPhase(ReplayTableIndex + Skip)
            end
            -- A hitch longer than the catch-up cap discarded tape time: the track kept running on
            -- the wall clock while the tape dropped those frames, so the walk cycle is handed back
            -- to the phase the tape is actually on. Without this the feet stay ahead of the body
            -- for the rest of the run, and a replay that hitched once reads as skating on every
            -- step after it.
            if Hitch and PlaybackCtl.SyncAnimationPhase then
                PlaybackCtl.SyncAnimationPhase(ReplayTableIndex + Skip)
            end

            local CamBefore = workspace.CurrentCamera.CFrame
            -- the view is applied on the render thread alongside the body; writing it here would
            -- put it on the recorded pose and then snap it back to the lerp a frame later
            if camCFrame then
                CameraCFrame = camCFrame
                PlaybackCtl.CameraHold = true
            end
            -- Older JSON replays may not carry a zoom channel; a missing value must not abort
            -- playback on the comparison below. The value is recorded here and applied on the
            -- render step with the body, from where the last eased sample left off, so a scroll
            -- never has to finish before the next one starts.
            if type(zoom) == "number" then
                local ZoomNow = PlaybackCtl.ZoomShown or PlaybackCtl.ZoomTarget or GetZoom()
                PlaybackCtl.ZoomPrev   = ZoomNow
                PlaybackCtl.ZoomTarget = zoom
                -- a respawn or a first-person toggle, not a scroll: the game cuts, the replay cuts.
                -- The start settle is the exception - it is already easing the view from where the
                -- player was looking, and the distance has to come with it.
                if math.abs(zoom - ZoomNow) > 4 and not PlaybackCtl.CamIntro then
                    PlaybackCtl.ZoomPrev  = zoom
                    PlaybackCtl.ZoomShown = zoom
                end
            end

            if shiftLock ~= GetShiftLockEnabled() then
                SetShiftLockEnabled(shiftLock)
            end

            -- Input boards such as NohBoard read the OS mouse, and a replayed camera turn emits
            -- no movement on its own. Travel the cursor with the recorded view's step so the
            -- board's indicator follows the camera. It samples cursor positions every 33 ms
            -- rather than the injected delta, so recentring between samples would cancel the
            -- travel: the cursor stays where the run puts it, and only wraps when it reaches
            -- the screen edge. One step per applied frame keeps it on the tape clock, so a run
            -- captured at 0.5x replays at the hand speed it actually had.
            if PlaybackInputs and not PlaybackMouseLocation and camCFrame
                and type(mousemoverel) == "function" then
                local LookDir = camCFrame.LookVector
                local YawNow = math.atan2(-LookDir.X, -LookDir.Z)
                local PitchNow = math.asin(math.clamp(LookDir.Y, -1, 1))
                local Travel = PlaybackCtl.MouseTravel
                if not Travel then
                    -- a run starts from the same centre the idle pin keeps
                    local Viewport = workspace.CurrentCamera.ViewportSize
                    local Inset = GuiService:GetGuiInset()
                    MoveMouseAbs((Viewport.X / 2) - Inset.X, (Viewport.Y / 2) - Inset.Y)
                    Travel = {
                        X = 0,
                        Y = 0,
                        PixelsX = 0,
                        PixelsY = 0,
                        LimitX = math.max((Viewport.X / 2) - 120, 120),
                        LimitY = math.max((Viewport.Y / 2) - 120, 120),
                    }
                    PlaybackCtl.MouseTravel = Travel
                end
                local PrevLook = PlaybackCtl.MouseLastLook
                if PrevLook then
                    local DYaw = YawNow - PrevLook[1]
                    if DYaw > math.pi then
                        DYaw = DYaw - 2 * math.pi
                    elseif DYaw < -math.pi then
                        DYaw = DYaw + 2 * math.pi
                    end
                    local DPitch = PitchNow - PrevLook[2]
                    -- A respawn or a camera cut is not a hand movement: the view teleports, or
                    -- it turns further in one frame than a wrist can.
                    if (camCFrame.Position - PrevLook[3]).Magnitude <= 100
                        and math.abs(DPitch) <= 2 then
                        -- 900 px per half turn is a wrist sweep at 800 dpi, screen axes applied:
                        -- positive X is right, positive Y is down
                        local Pixels = 900 / math.pi
                        local DX = math.floor(-DYaw * Pixels + 0.5)
                        local DY = math.floor(-DPitch * Pixels + 0.5)
                        if DX ~= 0 or DY ~= 0 then
                            mousemoverel(DX, DY)
                            Travel.X = Travel.X + DX
                            Travel.Y = Travel.Y + DY
                            -- the engine camera reads the same relative steps, so the raw sum is
                            -- what the stop has to give back to put the live heading where it was
                            Travel.PixelsX = Travel.PixelsX + DX
                            Travel.PixelsY = Travel.PixelsY + DY
                            -- Past the edge the OS clamps the cursor and the board would read
                            -- a stalled hand; place it on the far side and let the travel run on.
                            -- An absolute place also keeps the jump out of the live camera's
                            -- deltas, which only relative input feeds.
                            local Wrapped = false
                            if Travel.X > Travel.LimitX or Travel.X < -Travel.LimitX then
                                Travel.X = Travel.X - 2 * Travel.LimitX * (Travel.X > 0 and 1 or -1)
                                Wrapped = true
                            end
                            if Travel.Y > Travel.LimitY or Travel.Y < -Travel.LimitY then
                                Travel.Y = Travel.Y - 2 * Travel.LimitY * (Travel.Y > 0 and 1 or -1)
                                Wrapped = true
                            end
                            if Wrapped then
                                local Viewport = workspace.CurrentCamera.ViewportSize
                                local Inset = GuiService:GetGuiInset()
                                MoveMouseAbs(
                                    (Viewport.X / 2) - Inset.X + Travel.X,
                                    (Viewport.Y / 2) - Inset.Y + Travel.Y)
                            end
                        end
                    end
                end
                PlaybackCtl.MouseLastLook = {YawNow, PitchNow, camCFrame.Position}
            elseif PlaybackCtl.MouseLastLook or PlaybackCtl.MouseTravel then
                PlaybackCtl.MouseLastLook = nil
                PlaybackCtl.MouseTravel = nil
            end

            if PlaybackMouseLocation and not shiftLock and type(zoom) == "number" and zoom > 0.52 then
                MoveMouseAbs(mouseLocation.X, mouseLocation.Y)
            elseif not PlaybackCtl.MouseTravel then
                local CurrentResolution = workspace.CurrentCamera.ViewportSize
                local CurrentGuiInset = GuiService:GetGuiInset()
                MoveMouseAbs(
                    (CurrentResolution.X / 2) - CurrentGuiInset.X,
                    (CurrentResolution.Y / 2) - CurrentGuiInset.Y
                )
            end

            if PlaybackInputs then
                local Signal = {}
                -- Every synthetic down gets exactly one up. A tape can carry a repeated began
                -- for the same key (a duplicated transition, or a hold straddling a pause), and
                -- a second keydown with only one keyup behind it is what leaves an external
                -- input board lit after the game has already released the key. An ended for a
                -- key this run never pressed is skipped for the same reason in reverse.
                for _, Input in ipairs(inputBegan) do
                    if not InputBlacklist[Input] then
                        local Code = InputCodes[Input]
                        if Code then
                            if not PlaybackPressedKeys[Input] then
                                keypress(Code)
                                PlaybackPressedKeys[Input] = Code
                                if PlaybackCtl.PlayKeySound then PlaybackCtl.PlayKeySound(Input) end
                            end
                        elseif Input == "b1" then
                            if not PlaybackPressedKeys["b1"] then
                                mouse1press()
                                PlaybackPressedKeys["b1"] = "b1"
                                if PlaybackCtl.PlayMouseSound then PlaybackCtl.PlayMouseSound(1) end
                            end
                        elseif Input == "b2" then
                            if not PlaybackPressedKeys["b2"] then
                                mouse2press()
                                PlaybackPressedKeys["b2"] = "b2"
                                if PlaybackCtl.PlayMouseSound then PlaybackCtl.PlayMouseSound(2) end
                            end
                        elseif Input == "u" or Input == "d" then
                            table.insert(Signal, Input)
                        end
                    end
                end
                for _, Input in ipairs(inputEnded) do
                    if not InputBlacklist[Input] then
                        local Code = InputCodes[Input]
                        if Code then
                            if PlaybackPressedKeys[Input] then
                                keyrelease(Code)
                                PlaybackPressedKeys[Input] = nil
                            end
                        elseif Input == "b1" then
                            if PlaybackPressedKeys["b1"] then
                                mouse1release()
                                PlaybackPressedKeys["b1"] = nil
                            end
                        elseif Input == "b2" then
                            if PlaybackPressedKeys["b2"] then
                                mouse2release()
                                PlaybackPressedKeys["b2"] = nil
                            end
                        end
                    end
                end
                if #Signal > 0 then
                    SendSignal(table.concat(Signal, ","))
                end
            end

           
            -- The recorded pose is the end of the move, not a teleport: it is reached across the
            -- gap that actually elapses to the next frame, on the render thread, for the body and
            -- the view together. Both come off the recorded channel so the two never drift apart
            -- in a turn, which is what made the torso look late against the rest of the rig.
            InterpHRPPrev    = InterpHRPTarget or HRP.CFrame
            InterpHRPTarget  = hrpCFrame
            PlaybackCtl.InterpCamPrev    = PlaybackCtl.InterpCamTarget or CamBefore
            PlaybackCtl.InterpCamTarget  = camCFrame
            -- A move this large in one frame is a respawn or a checkpoint set, not travel: the
            -- game puts the body there instantly, so the replay snaps instead of gliding across
            -- the level for a frame's worth of time.
            if (InterpHRPTarget.Position - InterpHRPPrev.Position).Magnitude > 30 then
                InterpHRPPrev = InterpHRPTarget
            end
            if PlaybackCtl.InterpCamTarget
                and (PlaybackCtl.InterpCamTarget.Position - PlaybackCtl.InterpCamPrev.Position).Magnitude > 100 then
                PlaybackCtl.InterpCamPrev = PlaybackCtl.InterpCamTarget
            end
            InterpStart      = tick()
            -- Frame pacing is not perfectly even, and a duration that tracked every gap made the
            -- rig run slow for one frame and fast for the next - in a turn that reads as a shiver.
            -- Average the gap, then finish inside it, so the recorded pose is reached every frame
            -- and a long frame can no longer bend the speed for a step.
            PlaybackCtl.GapRaw = tick() - (PlaybackCtl.StepTick or tick())
            if PlaybackCtl.GapRaw <= 0 or PlaybackCtl.GapRaw > 0.1 then
                PlaybackCtl.GapRaw = 1 / math.max(FPS, 1)
            end
            PlaybackCtl.GapEMA = (PlaybackCtl.GapEMA or PlaybackCtl.GapRaw) * 0.85
                + PlaybackCtl.GapRaw * 0.15
            InterpDuration   = math.max(PlaybackCtl.GapEMA * 0.75, 1 / 480)
            PlaybackCtl.StepTick = tick()

            -- Reported, not simulated. The next step is handed a still root and the pose is driven
            -- positionally, but between that step and the next one the rig carries the velocity the
            -- run actually had: trail effects, speed-gated sounds and anything the game checks all
            -- see a moving character instead of a statue being dragged along its own path.
            HRP.Velocity     = hrpVel
            HRP.RotVelocity  = hrpRotVel
            PlaybackCtl.AlignRig()
            CO.SetInterpolationTargets(PlaybackCtl.MergedCO or Frame[13], InterpDuration)

            ReplayTableIndex = ReplayTableIndex + Skip + 1
        else
            -- the replay is not being read: a footstep loop this build started has nobody
            -- left to drive it, so it is stopped with everything else the playback owned
            if PlaybackCtl.FootstepsOwned then
                local Root = Character and Character:FindFirstChild("HumanoidRootPart")
                local EndedSound = Root and Root:FindFirstChild("Running")
                if EndedSound and EndedSound:IsA("Sound") and EndedSound.IsPlaying then
                    pcall(function() EndedSound:Stop() end)
                end
                PlaybackCtl.FootstepsOwned = nil
            end
            -- while the speed hack is engaged it owns gravity; leave it alone. Otherwise only
            -- undo a zero this build applied: writing the startup snapshot every heartbeat
            -- kept overwriting a gravity the game itself changed
            if PlaybackCtl.GravityOwned and not (SpeedHack.Enabled and SpeedHack.Speed < 0.999) then
                workspace.Gravity = DefaultGravity
                PlaybackCtl.GravityOwned = nil
            end
            pcall(function()
                if Character and Character:FindFirstChild("Humanoid") then
                    Character.Humanoid.PlatformStand = false
                end
            end)
            idleFrameCount = 0
            PlaybackPressedKeys = {}
        end

        RunService.Heartbeat:Wait()
    end
end) -- pcall
if not ok then
	ConsoleMessage("Playback error:", tostring(err))
	pcall(StopReading)
end
task.wait(0.2)
end
end)

-- Clear input queues
RunService.Heartbeat:Connect(function()
	table.clear(InputBeganQueue)
	table.clear(InputEndedQueue)
end)

spawn(function() -- Check if connected
	while true do
		wait(1)
		if not Reading then
			local Installed = IsInstalled()
			if Installed then
				ConnectedLabel.Text = "AHK folder found"
				ConnectedLabel.TextColor3 = Color3.new(0,0.8,0)
			else
				ConnectedLabel.Text = "AHK folder not found"
				ConnectedLabel.TextColor3 = Color3.new(0.8,0,0)
			end
		end
	end
end)

spawn(function() -- Writing (supervised)
while true do
local ok, err = pcall(function()
	while true do
		--print(currentAnimSpeed)
		--print(GetShiftLockEnabled())
		--table.foreach(InputEndedQueue,print)
		--print(GetZoom())
		if Writing and not Reading then
			-- With slow motion on, fewer frames are recorded so the replay plays at normal
			-- speed. Animation and input events of the skipped ticks are carried to the next
			-- recorded frame, and CO deltas are only pulled once per recorded frame, so the
			-- slowed-down world motion is still captured in full.
			local Scale = (SpeedHack.Enabled and SpeedHack.Speed < 0.999 and not Reading) and SpeedHack.Speed or 1
			-- world time advances by Scale each real tick; Frame[14] carries that clock so the
			-- speed optimizer can put the uneven kept frames back on a uniform timeline
			SpeedHack.NormalTime = SpeedHack.NormalTime + Scale
			for _, Entry in ipairs(AnimationQueue) do
				table.insert(SpeedHack.PendingAnimations, Entry)
			end
			table.clear(AnimationQueue)
			for _, Input in ipairs(InputBeganQueue) do
				table.insert(SpeedHack.PendingBegan, Input)
				if Input ~= "u" and Input ~= "d" and not InputBlacklist[Input] then
					SpeedHack.OpenKeys[Input] = true
				end
			end
			for _, Input in ipairs(InputEndedQueue) do
				table.insert(SpeedHack.PendingEnded, Input)
				SpeedHack.OpenKeys[Input] = nil
			end
			SpeedHack.Accumulator = SpeedHack.Accumulator + Scale

			if (not Character or not Character.Parent) or (not Character:FindFirstChild("HumanoidRootPart")) then
				if type(RecordingTable[#RecordingTable]) == "table" then
					table.insert(RecordingTable,0) -- Voided
					SpeedHack.Rate.Session = SpeedHack.Rate.Session + 1
				end
				SpeedHack.Accumulator = 0
				RunService.RenderStepped:Wait()
				continue
			end
			if (Humanoid.Health == 0) then
				if type(RecordingTable[#RecordingTable]) == "table" then
					table.insert(RecordingTable,1) -- Dead
					SpeedHack.Rate.Session = SpeedHack.Rate.Session + 1
				end
				SpeedHack.Accumulator = 0
				RunService.RenderStepped:Wait()
				continue
			end
			if SpeedHack.Accumulator >= 0.999 then
				SpeedHack.Accumulator = SpeedHack.Accumulator - 1
				-- The create-mode unpause holds the playhead on the frame it resumed from
				-- through one Heartbeat and one RenderStepped. A frame appended during those
				-- waits would be a duplicate still; the pending events ride the first real
				-- frame instead, exactly as HappaTAS keeps recording off the resume frame.
				if PlaybackCtl.FirstFrameRecord then
					RunService.RenderStepped:Wait()
					continue
				end
				local Frame = {}
				local RootCF = Character.HumanoidRootPart.CFrame
				local CamCF = workspace.CurrentCamera.CFrame
				local ZoomNow = GetZoom()
				-- the shift bit is the lock the game really has, not a boolean the tool stopped
				-- tracking when something else (a game script, a mobile button) toggled it
				PlaybackCtl.SyncShiftLock()
				local LockBit = (GetShiftLockEnabled() and 1) or 0
				local StateNow = Humanoid:GetState().Value
				Frame[1] = RoundTable(CFrameToTable(RootCF),RoundDigits)
				Frame[2] = SpeedHack.PendingAnimations
				Frame[3] = RoundNumber(currentAnimSpeed,RoundDigits)
				Frame[4] = StateNow
				-- world velocity is literally slower in slow motion; divide it back out so the
				-- replay drives the part at normal speed (CFrame deltas already match 1:1)
				local InvScale = 1 / Scale
				Frame[5] = RoundTable(Vector3ToTable(Character.HumanoidRootPart.Velocity * InvScale),RoundDigits)
				Frame[6] = RoundTable(Vector3ToTable(Character.HumanoidRootPart.RotVelocity * InvScale),RoundDigits)
				Frame[7] = RoundTable(CFrameToTable(CamCF),RoundDigits)
				Frame[8] = RoundNumber(ZoomNow,RoundDigits)
				Frame[9] = pose
				Frame[10] = LockBit
				Frame[11] = RoundTable(Vector2ToTable(UserInputService:GetMouseLocation()),RoundDigits)
				Frame[12] = {SpeedHack.PendingBegan, SpeedHack.PendingEnded}
				Frame[13] = CO.RecordFrame()
				Frame[14] = RoundNumber(SpeedHack.NormalTime,4)
				table.insert(RecordingTable,Frame)
				-- Capture rate: one frame per rendered tick, so the gaps between captured frames
				-- are the run's real sample interval. Gaps above a quarter second are a pause or
				-- a hitch and would drag the average down, so they are dropped.
				local Rate = SpeedHack.Rate
				local Now = tick()
				if Rate.Prev then
					local Gap = Now - Rate.Prev
					if Gap >= 0.002 and Gap <= 0.25 then
						Rate.Sum = Rate.Sum + Gap
						Rate.Count = Rate.Count + 1
					end
				end
				Rate.Prev = Now
				Rate.Session = Rate.Session + 1
				if Scale < 0.999 then
					-- slow motion samples the world at Scale times the rate; its timeline is
					-- already normalised, so its rate is the nominal one and is never measured
					Rate.Scaled = true
				end
				SpeedHack.ClearPending()
			end
		end
		table.clear(AnimationQueue)
		RunSpeed = 0
		ClimbSpeed = 0
		table.clear(HumanoidStateQueue)
		if setfpscap then
			setfpscap(FPS)
		end
		RunService.RenderStepped:Wait()
	end
end) -- pcall
if not ok then
	ConsoleMessage("Recording error:", tostring(err))
	task.wait(0.2)
end
end
end)

spawn(function() -- Update cursor
	
	local maxWait = 0
	repeat 
		task.wait(0.1)
		maxWait = maxWait + 0.1
		if maxWait > 5 then
			break
		end
	until CursorHolder and Cursor and CursorIcon
	
	SetCursor("ArrowFarCursor")

	Cursor.Image = CursorIcon
	Cursor.Size = CursorSize
	Cursor.Visible = true
	Cursor.BackgroundTransparency = 1
	Cursor.ZIndex = 10000

	
	-- The replay draws the mouse path it recorded, not the pinned OS pointer: the mouse
	-- channel sampled at the playhead. Slow motion stores the mouse on the body's normal-time
	-- timeline like every other channel, so a capture at 0.5x plays its movement back at 2x
	-- the hand speed it was made with - normal speed - and a playspeed change scales it too.
	local function RecordedCursorLocation()
		if type(ReplayTable) ~= "table" or #ReplayTable == 0 then return nil end
		local Head
		if Frozen then
			-- a free camera (look-around, or move-while-frozen) needs the player's own mouse
			if PlaybackCtl.LookAround or (movecameraonfroze and movecameraonfroze.Value) then
				return nil
			end
			Head = RoundNumber(FreezeFrame or 1, 0)
		elseif Reading then
			-- a look-around view is the player's mouse, not the tape's
			if PlaybackCtl.LookAround then return nil end
			Head = PlaybackCtl.RenderPos or PlaybackCtl.AppliedIndex
		else
			return nil
		end
		if not Head or Head < 1 then return nil end
		local Base = floor(Head)
		local A = ReplayTable[Base]
		if type(A) ~= "table" or type(A[11]) ~= "table" then return nil end
		local Frac = Head - Base
		local B = ReplayTable[Base + 1]
		if Frac > 0 and type(B) == "table" and type(B[11]) == "table" then
			return Vector2.new(
				A[11][1] + (B[11][1] - A[11][1]) * Frac,
				A[11][2] + (B[11][2] - A[11][2]) * Frac)
		end
		return Vector2.new(A[11][1], A[11][2])
	end

	local frameCount = 0
	while task.wait() do
		frameCount = frameCount + 1
		
		pcall(function()
			-- outside playback and stills the cursor follows the lock the game actually has,
			-- so a game-side or mobile-side toggle can't make the icon lie about the state
			if not Reading and not Frozen then
				PlaybackCtl.SyncShiftLock()
			end
			Cursor.Image = CursorIcon
			Cursor.Size = CursorSize
			Cursor.Visible = true
			
			-- during playback or a still the cursor is the tape's; live only outside both
			local MouseLocation = RecordedCursorLocation() or UserInputService:GetMouseLocation()
			local ViewportSize = workspace.CurrentCamera.ViewportSize

			local cursorWidth = CursorSize.X.Offset
			local cursorHeight = CursorSize.Y.Offset
			local centerOffsetX = -cursorWidth / 2
			local centerOffsetY = -cursorHeight / 2
			
			if ShiftLockEnabled then
				Cursor.Position = UDim2.fromOffset(
					(ViewportSize.X / 2) + centerOffsetX,
					(ViewportSize.Y / 2) + centerOffsetY
				)
			else
				Cursor.Position = UDim2.fromOffset(
					MouseLocation.X + centerOffsetX,
					MouseLocation.Y + centerOffsetY
				)
			end
			
			if frameCount % 60 == 0 then
			end
		end)
	end
end)

--[[local oldConsoleMessage
oldConsoleMessage = hookfunction(ConsoleMessage,function(...)
	if checkcaller() then
		return oldConsoleMessage(...)
	end
end)]]

-- The freeze draws a still every render but walked the whole tape backwards for the pose and
-- the animation, an O(n) scan per frame once a run gets long. Sparse indices built once per
-- tape turn both lookups into a binary search; a tape swap or a length change rebuilds them.
local function BuildFreezeIndex()
    local Tape = ReplayTable
    local AnimAt, PoseAt = {}, {}
    for Index = 1, #Tape do
        local F = Tape[Index]
        if type(F) == "table" then
            local AnimList = F[2]
            if type(AnimList) == "table" and AnimList[#AnimList] then
                AnimAt[#AnimAt + 1] = Index
            end
            local PoseName = F[9]
            if type(PoseName) == "string" and PoseName ~= "" then
                PoseAt[#PoseAt + 1] = Index
            end
        end
    end
    PlaybackCtl.FreezeIndexTape  = Tape
    PlaybackCtl.FreezeIndexCount = #Tape
    PlaybackCtl.FreezeAnimAt     = AnimAt
    PlaybackCtl.FreezePoseAt     = PoseAt
end

local function LastIndexAtOrBefore(List, Limit)
    local Low, High, Best = 1, #List, nil
    while Low <= High do
        local Mid = math.floor((Low + High) / 2)
        local Value = List[Mid]
        if Value <= Limit then
            Best = Value
            Low = Mid + 1
        else
            High = Mid - 1
        end
    end
    return Best
end

local function EnsureFreezeIndex()
    if PlaybackCtl.FreezeIndexTape ~= ReplayTable or PlaybackCtl.FreezeIndexCount ~= #ReplayTable then
        BuildFreezeIndex()
    end
end

local function ProcessFreezeFrame(RoundedFreezeFrame)
    local Frame = ReplayTable[RoundedFreezeFrame]
    if type(Frame) ~= "table" then return end

    EnsureFreezeIndex()
    local AnimatePose, Animation
    local PoseIndex = LastIndexAtOrBefore(PlaybackCtl.FreezePoseAt, RoundedFreezeFrame)
    if PoseIndex then
        AnimatePose = ReplayTable[PoseIndex][9]
    end
    local AnimIndex = LastIndexAtOrBefore(PlaybackCtl.FreezeAnimAt, RoundedFreezeFrame)
    if AnimIndex then
        local AnimList = ReplayTable[AnimIndex][2]
        Animation = AnimList[#AnimList]
    end

    -- The still is redrawn on purpose every render; the key readout is not. It is rebuilt only
    -- when the drawn frame, the tape behind it, or the backtrack window changes.
    if PlaybackCtl.FreezeInputTape ~= ReplayTable
        or PlaybackCtl.FreezeInputFrame ~= RoundedFreezeFrame
        or PlaybackCtl.FreezeInputLength ~= #ReplayTable
        or PlaybackCtl.FreezeInputBacktrack ~= FrameBacktrackCount then
        PlaybackCtl.FreezeInputTape      = ReplayTable
        PlaybackCtl.FreezeInputFrame     = RoundedFreezeFrame
        PlaybackCtl.FreezeInputLength    = #ReplayTable
        PlaybackCtl.FreezeInputBacktrack = FrameBacktrackCount
        local CurrentPressedKeys = {}
        for Index = RoundedFreezeFrame - math.max(FrameBacktrackCount, 0), RoundedFreezeFrame do
            local F = ReplayTable[Index]
            if F and type(F) == "table" then
                local Events = F[12]
                if type(Events) == "table" then
                    local BeganInputs, EndedInputs = Events[1], Events[2]
                    if type(BeganInputs) == "table" then
                        for _, Key in ipairs(BeganInputs) do
                            if Key ~= "u" and Key ~= "d" then
                                CurrentPressedKeys[Key] = true
                            end
                        end
                    end
                    if type(EndedInputs) == "table" then
                        for _, Key in ipairs(EndedInputs) do
                            CurrentPressedKeys[Key] = nil
                        end
                    end
                end
            end
        end

        local Parts = {"Writing Pressed keys: |"}
        for Input in pairs(CurrentPressedKeys) do
            Parts[#Parts + 1] = Input.."|"
        end
        WritingPressedKeysLabel.Text = table.concat(Parts)
    end

    local HumanoidRootPartCFrame     = TableToCFrame(Frame[1])
    local AnimationSpeed             = Frame[3]
    local HumanoidState              = Frame[4]
    local HumanoidRootPartVelocity   = TableToVector3(Frame[5])
    local HumanoidRootPartRotVelocity = TableToVector3(Frame[6])
    local FrameCameraCFrame          = TableToCFrame(Frame[7])
    local Zoom                       = Frame[8]
    local FrameShiftLock             = (Frame[10] == 1)
    local MouseLocation              = TableToVector2(Frame[11])

    if Animation then
        if Animation[1] == "walk" then
            if Humanoid.FloorMaterial ~= Enum.Material.Air and Humanoid:GetState().Value ~= 3 then
                playAnimation("walk", Animation[2], Humanoid, true, Animation[3])
            end
        else
            playAnimation(Animation[1], Animation[2], Humanoid, true, Animation[3])
        end
    end
    pcall(setAnimationSpeed, AnimationSpeed)
    -- the paused frame is a still: hold the track at the phase the recording had reached
    if Animation and PlaybackCtl.SyncAnimationPhase then
        PlaybackCtl.SyncAnimationPhase(RoundedFreezeFrame)
    end
    -- setAnimationSpeed just handed the track its live rate again; park it right after so the
    -- still does not advance between renders
    if SpeedHack.HoldAnimations then
        SpeedHack.HoldAnimations(true)
    end
    -- a tape with no pose channel at all leaves the applied pose alone instead of nulling it
    if AnimatePose ~= nil then
        pose = AnimatePose
    end

    if type(HumanoidState) == "number" then
        Humanoid:ChangeState(HumanoidState)
    end
    -- Frames hold normal-time velocity. While the speed hack is engaged the live body moves
    -- slower, so scale it back; applying it raw would hand the character more speed than it
    -- had, and every freeze/unfreeze cycle on the same jump would launch it higher again.
    local LiveScale = (SpeedHack.Enabled and SpeedHack.Speed < 0.999 and not Reading) and SpeedHack.Speed or 1
    Character.HumanoidRootPart.Velocity = HumanoidRootPartVelocity * LiveScale
    Character.HumanoidRootPart.RotVelocity = HumanoidRootPartRotVelocity * LiveScale
    Character.HumanoidRootPart.CFrame = HumanoidRootPartCFrame
    PlaybackCtl.AlignRig()

    if not movecameraonfroze.Value and not PlaybackCtl.LookAround then
        PlaybackCtl.SetCamera(FrameCameraCFrame)
        if type(Zoom) == "number" then
            SetZoom(Zoom)
            -- a frozen frame is a still, and the eased channel has to agree with what is on
            -- screen or the first live frame after unfreezing glides in from a stale distance
            PlaybackCtl.ZoomPrev   = Zoom
            PlaybackCtl.ZoomTarget = Zoom
            PlaybackCtl.ZoomShown  = Zoom
        end
        if FrameShiftLock ~= GetShiftLockEnabled() then
            -- display only: the still draws the recorded cursor, the live mouse lock stays the
            -- player's own. Toggling it here handed the tape's lock to the player and left it
            -- there after the unfreeze.
            SetShiftLockEnabled(FrameShiftLock, true)
        end
    end
    -- a free camera (look-around, or the move-while-frozen checkbox) needs the real mouse:
    -- snapping it back to the recorded spot every render makes the stock camera fight the hand
    if PlaybackMouseLocation and not PlaybackCtl.LookAround and not movecameraonfroze.Value then
        MoveMouseAbs(MouseLocation.X, MouseLocation.Y)
    end

 if #ReplayTable > 0 then
        local coState = CO.GetFullStateAtFrame(RoundedFreezeFrame, ReplayTable)
        CO.ApplyFullState(coState)
    end
end

spawn(function() -- Handling freezing
    while true do
        if Frozen then
            local ok, err = pcall(function()
                Character.HumanoidRootPart.Anchored = true
                if FreezeFrame > 0 and FreezeFrame <= #ReplayTable then
                    local RoundedFreezeFrame = RoundNumber(FreezeFrame, 0)
                    ProcessFreezeFrame(RoundedFreezeFrame)
                    if movecameraonfroze.Value then
                        PlaybackCtl.ReleaseCamera() -- checkbox wants the camera back while frozen
                    end
                end
            end)
            if not ok and tick() - (PlaybackCtl.LastFreezeErr or 0) > 5 then
                PlaybackCtl.LastFreezeErr = tick()
                ConsoleMessage("Freeze error:", tostring(err))
            end
        else
            pcall(function()
                Character.HumanoidRootPart.Anchored = false
            end)
        end
        RunService.RenderStepped:Wait()
    end
end)

do -- Set checkpoint
    ConsoleMessage("Loading from file...")
    local okRead, fileContent = pcall(GetReplayFile)
    local okDecode, Decoded = false, nil
    if okRead then
        okDecode, Decoded = pcall(ReplayDecode, fileContent)
    end
    if not okRead then
        ReplayTable = {}
        ConsoleMessage("Could not read the replay folder:", tostring(fileContent))
    elseif not okDecode then
        ReplayTable = {}
        ConsoleMessage("Decode error:", tostring(Decoded))
    elseif not Decoded then
        ReplayTable = {}
        ConsoleMessage("There is no replay folder for",PlaceId)
    else
        ReplayTable = Decoded
        ReplayNeedsReload = false
        LastLoadedPath = ReplayPath
        ConsoleMessage("Initial replay loaded and cached")
    end
end

ConsoleMessage("Tasability",Version,"loaded in",RoundNumber(tick()-ExecutionTick,2),"seconds")
ConsoleMessage("Type help to see all commands")
ConsoleMessage("Developed, revamped and made by 9kwr.")