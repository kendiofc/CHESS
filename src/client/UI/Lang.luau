--!strict
-- Lang: shows the game in the language the player picked.
--
-- The UI code writes English. Every text object in the game's own screens is
-- watched (Lang.watch), and whatever English lands in its Text is swapped for
-- the chosen language from the tables in Translations (built from
-- tools/translations.txt by tools/build_translations.py). A text is matched:
--   1. exactly;
--   2. against the English format strings ("Best run: %d"), whose values are
--      translated too when they are known texts themselves ("Hint: %s");
--   3. line by line, and part by part around " · " / " • " separators;
--   4. without leading symbols or emoji ("🔥 ...", "✓ ...");
--   5. in capitals, for texts the code upper-cases ("PUZZLES CLEARED").
-- Anything not in the table stays English. Roblox's own automatic
-- translation is turned off on these screens so the two never mix.

local LocalizationService = game:GetService("LocalizationService")

local Translations = script.Parent:WaitForChild("Translations")

local Lang = {}

-- The languages a player can pick, in the picker's order. `name` is the
-- language's own name for itself.
Lang.LANGUAGES = {
	{ code = "en", name = "English" },
	{ code = "es", name = "Español" },
	{ code = "pt", name = "Português" },
	{ code = "fr", name = "Français" },
	{ code = "de", name = "Deutsch" },
	{ code = "id", name = "Bahasa Indonesia" },
}

local current = "en"
local exact: { [string]: string } = {}
local capitals: { [string]: string } = {} -- upper-cased English -> upper-cased translation
local patterns: { { pattern: string, out: string } } = {}
local cache: { [string]: string } = {}
local cacheSize = 0
local listeners: { () -> () } = {}

-- Months for dates written by os.date("%b %d").
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

function Lang.isLanguage(code: any): boolean
	for _, language in ipairs(Lang.LANGUAGES) do
		if language.code == code then
			return true
		end
	end
	return false
end

function Lang.nameOf(code: string): string
	for _, language in ipairs(Lang.LANGUAGES) do
		if language.code == code then
			return language.name
		end
	end
	return code
end

function Lang.current(): string
	return current
end

-- The supported language closest to the player's Roblox language, or English.
function Lang.suggested(): string
	local ok, locale = pcall(function()
		return LocalizationService.RobloxLocaleId
	end)
	if ok and type(locale) == "string" then
		local code = string.lower(string.sub(locale, 1, 2))
		if Lang.isLanguage(code) then
			return code
		end
	end
	return "en"
end

-- "Best run: %d" -> "^Best run: (%-?%d+)$"
local function compile(source: string): string
	local out = { "^" }
	local i = 1
	while i <= #source do
		local spec = string.match(source, "^%%[%d]*[ds]", i)
		if spec then
			table.insert(out, if string.sub(spec, -1) == "d" then "(%-?%d+)" else "(.-)")
			i += #spec
		elseif string.sub(source, i, i + 1) == "%%" then
			table.insert(out, "%%")
			i += 2
		else
			local char = string.sub(source, i, i)
			table.insert(out, if string.find(char, "^[%^%$%(%)%%%.%[%]%*%+%-%?]") then "%" .. char else char)
			i += 1
		end
	end
	table.insert(out, "$")
	return table.concat(out)
end

local translate: (text: string) -> string

-- Puts the captured values into a translated format string: "{1}" style
-- placeholders by number, otherwise %d / %s in order.
local function fill(out: string, values: { string }): string
	local function value(index: number): string
		local raw = values[index] or ""
		return if string.find(raw, "%a%a") then translate(raw) else raw
	end
	if string.find(out, "{%d}") then
		return (string.gsub(out, "{(%d)}", function(n: string)
			return value(tonumber(n) :: number)
		end))
	end
	local index = 0
	return (string.gsub(out, "%%[%d]*[ds]", function()
		index += 1
		return value(index)
	end))
end

-- Upper case that also covers the accented letters of the languages offered
-- (string.upper only knows A-Z).
local ACCENTS = {
	["á"] = "Á", ["à"] = "À", ["â"] = "Â", ["ã"] = "Ã", ["ä"] = "Ä", ["ç"] = "Ç",
	["é"] = "É", ["è"] = "È", ["ê"] = "Ê", ["ë"] = "Ë", ["í"] = "Í", ["î"] = "Î",
	["ï"] = "Ï", ["ñ"] = "Ñ", ["ó"] = "Ó", ["ô"] = "Ô", ["õ"] = "Õ", ["ö"] = "Ö",
	["ú"] = "Ú", ["ù"] = "Ù", ["û"] = "Û", ["ü"] = "Ü",
}
function Lang.upper(text: string): string
	local out = string.upper(text)
	for lower, upper in pairs(ACCENTS) do
		out = string.gsub(out, lower, upper)
	end
	return out
end

-- Upper-cases a format string without touching its %d / %s / {1}.
local function upperFormat(source: string): string
	local out = {}
	local i = 1
	while i <= #source do
		local s, e = string.find(source, "%%[%d]*[ds]", i)
		local b1, b2 = string.find(source, "{%d}", i)
		if b1 and (not s or b1 < s) then
			s, e = b1, b2
		end
		if not s then
			table.insert(out, Lang.upper(string.sub(source, i)))
			break
		end
		table.insert(out, Lang.upper(string.sub(source, i, s - 1)))
		table.insert(out, string.sub(source, s, e))
		i = (e :: number) + 1
	end
	return table.concat(out)
end

local function lookup(text: string): string?
	local found = exact[text]
	if found then
		return found
	end
	if string.upper(text) == text then
		found = capitals[text]
		if found then
			return found
		end
	end
	for _, entry in ipairs(patterns) do
		local values = { string.match(text, entry.pattern) }
		if #values > 0 then
			return fill(entry.out, values)
		end
	end
	local month, day = string.match(text, "^(%a%a%a) (%d%d?)$")
	if month and table.find(MONTHS, month) then
		local name = exact[month]
		if name then
			return name .. " " .. day
		end
	end
	return nil
end

-- Marks the UI puts after a word ("Continue  ▶").
local TRAILING = { "  ▶", " ▶", "  ▸", " ▸", "  ›", " ›" }

local function translateUncached(text: string): string
	local found = lookup(text)
	if found then
		return found
	end
	-- Several lines: each on its own.
	if string.find(text, "\n") then
		local lines = string.split(text, "\n")
		for index, line in ipairs(lines) do
			lines[index] = translate(line)
		end
		return table.concat(lines, "\n")
	end
	-- Parts joined with a separator: each part on its own.
	for _, separator in ipairs({ "  ·  ", " · ", "   •   ", "  •  ", " • " }) do
		if string.find(text, separator, 1, true) then
			local parts = string.split(text, separator)
			for index, part in ipairs(parts) do
				parts[index] = translate(part)
			end
			return table.concat(parts, separator)
		end
	end
	-- Leading numbers, symbols, emoji or spaces ("1.  ", "🔥 "), and trailing
	-- spaces or arrows.
	local head, core, tail = string.match(text, "^([^%a]*)(.-)(%s*)$")
	if core and core ~= "" then
		for _, mark in ipairs(TRAILING) do
			if #core > #mark and string.sub(core, -#mark) == mark then
				core, tail = string.sub(core, 1, -#mark - 1), mark .. (tail :: string)
				break
			end
		end
	end
	if core and core ~= text and core ~= "" then
		local inner = lookup(core)
		if inner then
			return (head :: string) .. inner .. (tail :: string)
		end
	end
	return text
end

translate = function(text: string): string
	if current == "en" or text == "" or not string.find(text, "%a%a") then
		return text
	end
	local cached = cache[text]
	if cached then
		return cached
	end
	local result = translateUncached(text)
	if cacheSize > 4000 then
		cache, cacheSize = {}, 0
	end
	cache[text] = result
	cacheSize += 1
	return result
end

Lang.translate = translate

-- Switches language. Watched screens are redrawn in it straight away.
function Lang.set(code: string)
	if not Lang.isLanguage(code) or code == current then
		return
	end
	current = code
	exact, capitals, patterns, cache, cacheSize = {}, {}, {}, {}, 0
	local module = Translations:FindFirstChild(code)
	if module and module:IsA("ModuleScript") then
		local data = require(module) :: { [string]: string }
		for source, out in pairs(data) do
			if string.find(source, "%%[%d]*[ds]") then
				table.insert(patterns, { pattern = compile(source), out = out, length = #source } :: any)
				-- The same format in capitals ("HARD %d/%d").
				local upperSource = upperFormat(source)
				if upperSource ~= source then
					table.insert(patterns, { pattern = compile(upperSource), out = upperFormat(out), length = #source } :: any)
				end
			else
				exact[source] = out
				capitals[string.upper(source)] = Lang.upper(out)
			end
		end
		-- Longer formats first, so the most specific one wins.
		table.sort(patterns, function(a: any, b: any)
			return a.length > b.length
		end)
	end
	for _, listener in ipairs(listeners) do
		task.spawn(listener)
	end
end

function Lang.onChanged(listener: () -> ())
	table.insert(listeners, listener)
end

-- Watching -------------------------------------------------------------------

local sources = setmetatable({}, { __mode = "k" }) :: { [Instance]: string } -- English as the code wrote it
local shown = setmetatable({}, { __mode = "k" }) :: { [Instance]: string } -- what we put on screen

local function apply(object: any)
	local text = object.Text
	if shown[object] == text then
		return -- our own write coming back
	end
	sources[object] = text
	local out = translate(text)
	shown[object] = out
	if out ~= text then
		object.Text = out
	end
end

local function track(object: Instance)
	if (object:IsA("TextLabel") or object:IsA("TextButton")) and sources[object] == nil then
		apply(object)
		object:GetPropertyChangedSignal("Text"):Connect(function()
			apply(object)
		end)
	end
end

-- Translates every text under `root` now and whenever it changes.
function Lang.watch(root: Instance)
	if root:IsA("GuiBase2d") then
		(root :: any).AutoLocalize = false
	end
	for _, object in ipairs(root:GetDescendants()) do
		track(object)
	end
	root.DescendantAdded:Connect(track)
end

-- Redraws every watched text in the current language.
local function retranslate()
	for object, source in pairs(sources) do
		if object.Parent then
			local out = translate(source)
			shown[object] = out;
			(object :: any).Text = out
		end
	end
end
Lang.onChanged(retranslate)

return Lang
