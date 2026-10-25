# Echo Chess

A chess puzzle game for Roblox. You control one white piece and clear the board by
capturing every black piece, and each capture turns you into the piece you took.

This is the **Phase 2 prototype**. It has a server-authoritative puzzle engine, a
playable board UI and three verified puzzles. The menus, the 30-puzzle catalogue,
progression, daily puzzles and the other modes come in later phases.

## Rules: Echo Clear mode

1. You control exactly one white piece. The black pieces never move.
2. Your piece moves with standard chess geometry:
   - **King**: moves one square in any direction.
   - **Queen / Rook / Bishop**: slide any distance (orthogonally and diagonally, orthogonally only, or diagonally only) and stop at the first occupied square.
   - **Knight**: makes an L-shaped jump and leaps over pieces and blocked squares.
   - **Pawn**: moves one square up the board onto an empty square, or captures one square diagonally upward. There is no double step, en passant or promotion.
3. **Blocked squares** (red crosshatch) can never be entered or slid through. Knights can jump over them.
4. Capturing removes the black piece, and your piece **becomes the captured piece's type** (the "echo").
5. **Win** when every black piece has been captured.
6. **Fail** when the remaining pieces can no longer all be captured. A solver checks this after every move. Undo is allowed, including out of a failed position.
7. There is no check or checkmate, because black never moves. A black king is just another target.

Any order of legal moves that clears the board wins. The rules engine checks
each move, so there is no fixed "intended line" to match.

## Board representation

- The board is a `width × height` grid (max 8×8). Squares are flat indices: `index = (row - 1) * width + col`. Column 1 is file `a`, and row 1 is the bottom rank.
- `board.pieces[index] = { kind = "K"|"Q"|"R"|"B"|"N"|"P", color = "white"|"black" }`, and `board.blocked[index] = true` marks a blocked square.
- Puzzles are written as rows of text, top row first: `.` is empty, `#` is blocked, uppercase is your piece and lowercase is a target.

```lua
layout = {
    "n..b",
    "....",
    "...r",
    "Q.#.",
}
```

## Project layout (Rojo)

| Roblox location | Source | Purpose |
| --- | --- | --- |
| `ReplicatedStorage.Shared.BoardState` | `src/shared/BoardState.luau` | Board model, layout parsing, square names |
| `ReplicatedStorage.Shared.ChessRules` | `src/shared/ChessRules.luau` | Move generation, apply/undo |
| `ReplicatedStorage.Shared.PuzzleValidator` | `src/shared/PuzzleValidator.luau` | Win check, solvability search, shortest solution, solution replay |
| `ReplicatedStorage.Shared.PuzzleSession` | `src/shared/PuzzleSession.luau` | One attempt: moves, status, undo, restart |
| `ReplicatedStorage.Shared.PuzzleDefinitions` | `src/shared/PuzzleDefinitions.luau` | Handcrafted puzzles |
| `ReplicatedStorage.Shared.GameConfig` | `src/shared/GameConfig.luau` | Remote names, actions, rate limits |
| `ReplicatedStorage.Remotes` | `default.project.json` | `PuzzleAction` (client → server) and `PuzzleState` (server → client) |
| `ServerScriptService.ServerMain` | `src/server/ServerMain.server.luau` | Boots services |
| `ServerScriptService.Services.PuzzleService` | `src/server/Services/PuzzleService.luau` | Per-player authoritative sessions |
| `StarterPlayerScripts.ClientController` | `src/client/ClientController.client.luau` | Wires the HUD to the remotes |
| `StarterPlayerScripts.AnimationController` | `src/client/AnimationController.luau` | Tween helpers |
| `StarterPlayerScripts.UI.PuzzleHUD` | `src/client/UI/PuzzleHUD.luau` | Board, stats, controls and result card |
| `StarterPlayerScripts.UI.PieceArt` | `src/client/UI/PieceArt.luau` | Piece silhouettes drawn from GUI shapes |
| `StarterPlayerScripts.UI.Theme` | `src/client/UI/Theme.luau` | Colours and fonts |

The UI is built in code, so `StarterGui` stays empty for now.
Roblox fonts don't include the Unicode chess glyphs, so the pieces are drawn
from GUI shapes. That means no uploaded images are needed.

## Security model

The client sends only intents (`start`, `move`, `undo`, `restart`, `sync`), and
the server owns everything else:

- The server validates every move against the shared rules and rejects it if the player has no piece there, the move is illegal or the input is malformed.
- The server decides win and fail and keeps its own timer.
- After every action the server sends a full snapshot.
- Each player is limited to a burst of 8 actions, refilled at 6 per second. A throttled burst gets a single "rate limited" notice.

The client calculates legal-move highlights only to draw them on the board.

## Running the tests

The engine is plain Luau and runs outside Roblox. Get the `luau` CLI from
<https://github.com/luau-lang/luau/releases>, then run:

```sh
python3 tools/run_tests.py path/to/luau
```

The suite checks:

- move generation for every piece, plus walls, blocking and captures
- echo transformation and undo
- solver correctness
- each puzzle's stored solution replays legally, and the solver agrees the puzzle is solvable
- par equals the true minimum number of moves (found by BFS)
- tampered solutions are rejected
- the session rejects bad input, and handles win, fail, undo and restart

## Syncing into Studio

You can use Rojo (`rojo serve` with `default.project.json`). Without Rojo,
`tools/studio_sync.py` prints a Luau chunk that creates the folders, remotes
and scripts and writes each script's source. Paste it into the Studio command bar:

```sh
python3 tools/studio_sync.py > sync.luau                                 # embeds sources
python3 tools/studio_sync.py --github kendiofc/CHESS@<commit> > sync.luau  # downloads them
```
