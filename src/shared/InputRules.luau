--!strict
-- InputRules: small pure rules behind board input and confirmation dialogs,
-- kept here (not in the HUD) so the tests can check them outside Roblox.

local BoardState = require(script.Parent.BoardState)

local InputRules = {}

-- A press that moves at least this many pixels is a drag, not a tap.
InputRules.DRAG_THRESHOLD = 10

-- After a drag ends, a tap event arriving within this many seconds belongs to
-- the same press and is ignored, so a drag never also counts as a tap.
InputRules.TAP_SUPPRESS_SECONDS = 0.25

-- Dialog buttons ignore presses for this long after the dialog opens, so the
-- press (or a quick double tap) that opened it can't also answer it.
InputRules.DIALOG_ARM_SECONDS = 0.25

-- The square under a point given as a fraction (0..1) of the board's width
-- and height, measured from its top-left corner. nil when outside the board.
function InputRules.squareAt(board: BoardState.Board, relX: number, relY: number): number?
	if relX ~= relX or relY ~= relY or relX < 0 or relY < 0 or relX >= 1 or relY >= 1 then
		return nil
	end
	local col = math.floor(relX * board.width) + 1
	local row = board.height - math.floor(relY * board.height)
	if not BoardState.inBounds(board, col, row) then
		return nil
	end
	return BoardState.toIndex(board, col, row)
end

function InputRules.isDrag(dx: number, dy: number): boolean
	return dx * dx + dy * dy >= InputRules.DRAG_THRESHOLD * InputRules.DRAG_THRESHOLD
end

-- Whether leaving the current attempt would throw away progress the player
-- could still use: a puzzle in play with at least one move made.
function InputRules.needsConfirm(snapshot: any): boolean
	return snapshot ~= nil and snapshot.status == "playing" and (snapshot.moveCount or 0) > 0
end

return InputRules
