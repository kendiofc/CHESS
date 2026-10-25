--!strict
-- TutorialFlow: the steps of the interactive tutorial and how player events
-- move between them. Pure logic; the client's TutorialCoach draws it.
--
-- The tutorial is played on the first Journey puzzle. Each step waits for
-- one thing the player does. Events that skip ahead (capturing before
-- selecting, say) jump to the step after the one they satisfy, so the
-- tutorial never asks for something already done. It ends when the board
-- is cleared ("completed"), when the player presses Skip ("skipped"), or
-- when they leave the tutorial puzzle ("interrupted"). Only completed and
-- skipped are saved; an interrupted tutorial is offered again next time if
-- the player still hasn't cleared any puzzle.

local TutorialFlow = {}

TutorialFlow.PUZZLE_ID = "beginner-01"

export type Step = { id: string, waitFor: string, text: string, target: string? }

TutorialFlow.STEPS = {
	{
		id = "select",
		waitFor = "select",
		target = "player",
		text = "Tap your white piece to select it. You can also drag it.",
	},
	{
		id = "capture",
		waitFor = "capture",
		text = "Dots show moves and rings show captures. Tap or drag onto a ringed piece.",
	},
	{
		id = "echo",
		waitFor = "next",
		text = "Echo! You became the piece you took and now move like it. Black never moves.",
	},
	{
		id = "hint",
		waitFor = "hint",
		target = "hint",
		text = "Stuck? Tap Hint. Hints are free in Journey and Practice.",
	},
	{
		id = "finish",
		waitFor = "win",
		text = "Capture every black piece to clear the board. Undo takes back a move.",
	},
} :: { Step }

export type State = { step: number, finished: string? }

function TutorialFlow.new(): State
	return { step = 1, finished = nil }
end

function TutorialFlow.current(state: State): Step?
	if state.finished then
		return nil
	end
	return TutorialFlow.STEPS[state.step]
end

local function indexOf(id: string): number
	for index, step in ipairs(TutorialFlow.STEPS) do
		if step.waitFor == id then
			return index
		end
	end
	return 0
end

-- Applies one event: "select", "capture", "next", "hint", "win", "skip" or
-- "leave". Returns true when the state changed.
function TutorialFlow.advance(state: State, event: string): boolean
	if state.finished then
		return false
	end
	if event == "skip" then
		state.finished = "skipped"
		return true
	elseif event == "leave" then
		state.finished = "interrupted"
		return true
	elseif event == "win" then
		state.finished = "completed"
		return true
	end
	local satisfied = indexOf(event)
	if satisfied >= state.step then
		-- The current step, or a later one done early: continue after it.
		state.step = satisfied + 1
		if state.step > #TutorialFlow.STEPS then
			state.finished = "completed"
		end
		return true
	end
	return false
end

return TutorialFlow
