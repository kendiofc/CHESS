--!strict
-- BoardGen: deterministic random Echo Clear boards for tests and benchmarks.
--
-- The same seed always gives the same layout, on every Luau runtime, because it
-- uses its own linear congruential generator instead of math.random.

local BoardGen = {}

local KINDS = { "Q", "R", "B", "N", "K", "P" }

local function rng(seed: number): (number) -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	-- Park-Miller minimal standard generator; returns an integer in [1, n].
	return function(n: number): number
		state = (state * 48271) % 2147483647
		return state % n + 1
	end
end

-- Returns a layout (top row first) with `targets` black pieces, one white piece
-- and roughly `wallPercent` percent blocked squares.
function BoardGen.layout(seed: number, width: number, height: number, targets: number, wallPercent: number): { string }
	local roll = rng(seed)
	local cells = table.create(width * height, ".")
	local free = {}
	for i = 1, width * height do
		table.insert(free, i)
	end
	local function take(): number
		local pick = roll(#free)
		local index = free[pick]
		free[pick] = free[#free]
		free[#free] = nil
		return index
	end
	cells[take()] = KINDS[roll(4)] -- the player starts as a Q, R, B or N
	for _ = 1, targets do
		cells[take()] = string.lower(KINDS[roll(#KINDS)])
	end
	local walls = math.floor(width * height * wallPercent / 100)
	for _ = 1, math.min(walls, #free) do
		cells[take()] = "#"
	end
	local layout = {}
	for row = 1, height do
		table.insert(layout, table.concat(cells, "", (row - 1) * width + 1, row * width))
	end
	return layout
end

return BoardGen
