# Echo Chess

A chess puzzle game for Roblox. You control one white piece and clear the board by
capturing every black piece, and each capture turns you into the piece you took.

**Phase 3** adds the following:

- a faster solver
- a 30-puzzle catalogue across five difficulties, each puzzle checked automatically
- hints
- three ways to play: Journey (difficulties unlock in order), Practice (any puzzle) and a Daily Puzzle
- progress saved in a DataStore

Multiplayer, monetization and other rule sets are not built yet.

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
6. **Fail** when the remaining pieces can no longer all be captured. A solver checks this after every capture and pawn move. Undo is allowed, including out of a failed position.
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
| `ReplicatedStorage.Shared.PuzzleValidator` | `src/shared/PuzzleValidator.luau` | Solver (solve, shortest solution, capture-order count) and solution replay |
| `ReplicatedStorage.Shared.PuzzleSession` | `src/shared/PuzzleSession.luau` | One attempt: moves, status, undo, restart |
| `ReplicatedStorage.Shared.PuzzleDefinitions` | `src/shared/PuzzleDefinitions.luau` | The 30-puzzle catalogue |
| `ReplicatedStorage.Shared.PuzzleCheck` | `src/shared/PuzzleCheck.luau` | Validates a puzzle definition and grades its difficulty |
| `ReplicatedStorage.Shared.PuzzleHints` | `src/shared/PuzzleHints.luau` | Picks written or live hints |
| `ReplicatedStorage.Shared.Progression` | `src/shared/Progression.luau` | Profile schema, unlocks, resume, stars, Daily Puzzle and streak, hint allowances, rewards, settings |
| `ReplicatedStorage.Shared.Achievements` | `src/shared/Achievements.luau` | One-time coin goals and their checks |
| `ReplicatedStorage.Shared.GameConfig` | `src/shared/GameConfig.luau` | Difficulties, play modes, hint rules, rewards, star slack, streak shield, cosmetic slots, default settings, remotes, rate limits |
| `ReplicatedStorage.Remotes` | `default.project.json` | `PuzzleAction` (client → server) and `PuzzleState` (server → client) |
| `ServerScriptService.ServerMain` | `src/server/ServerMain.server.luau` | Boots services and keeps avatars still while the GUI is in use |
| `ServerScriptService.Services.PuzzleService` | `src/server/Services/PuzzleService.luau` | Per-player authoritative sessions, modes, hints, rewards |
| `ServerScriptService.Services.ProfileStore` | `src/server/Services/ProfileStore.luau` | DataStore loading and saving |
| `StarterPlayerScripts.ClientController` | `src/client/ClientController.client.luau` | Wires the HUD to the remotes and hides the mobile thumbstick |
| `StarterPlayerScripts.AnimationController` | `src/client/AnimationController.luau` | Tween helpers |
| `StarterPlayerScripts.SoundController` | `src/client/SoundController.luau` | Sound effects, master volume, haptics where supported |
| `StarterPlayerScripts.UI.PuzzleHUD` | `src/client/UI/PuzzleHUD.luau` | Board, stats, controls (Undo, Hint, Restart) and result card |
| `StarterPlayerScripts.UI.PuzzleMenu` | `src/client/UI/PuzzleMenu.luau` | Home screen, Journey, Practice, Daily, Statistics and Settings |
| `StarterPlayerScripts.UI.SoundConfig` | `src/client/UI/SoundConfig.luau` | The audio asset for each sound event |
| `StarterPlayerScripts.UI.PieceArt` | `src/client/UI/PieceArt.luau` | Pieces cut from the sprite sheet (drawn GUI shapes as a fallback) |
| `StarterPlayerScripts.UI.Theme` | `src/client/UI/Theme.luau` | Colours and fonts |

The UI is built in code, so `StarterGui` stays empty for now.
Roblox fonts don't include the Unicode chess glyphs, so the pieces come from a
sprite sheet: `assets/pieces.png` (6 x 2 cells of 170 px, columns K Q B N R P,
white row first), uploaded as the image in `Theme.PieceSheet`. Rebuild it from
`assets/source/pieces-reference.jpg` with `tools/build_piece_sheet.py`. If
`Theme.PieceSheet` is empty, PieceArt draws the pieces from GUI shapes instead.

### Layout

PuzzleHUD lays itself out from the screen size and redoes it on every resize:

- Tall screens (phones in portrait, tablets, most desktops) stack the header,
  stats, board, message and buttons in one column up to 720 px wide.
- Short, wide screens (phones in landscape, small windows) put the board on the
  left and the header, stats and buttons in a column on the right.

The layout was checked in Studio at 320x568, 390x844, 568x320, 844x390,
1024x768 and full desktop windows.

## Modes, hints and progression

| Mode | Puzzles | Hints | Rewards | Counts for unlocks |
| --- | --- | --- | --- | --- |
| Journey | unlocked difficulties only | unlimited | puzzle's XP and coins, first clear only | yes |
| Practice | any puzzle | unlimited | none | no |
| Daily | one puzzle per UTC day (Easy to Hard pool) | 1 per day | daily reward, once per day | yes |

- **Unlocks.** Beginner is always open. Each later difficulty opens after 4 Journey or Daily clears of the one before it (`GameConfig.UNLOCK_REQUIREMENT`).
- **Hints.** The first two hints are the puzzle's written hints: a strategy, then a first step. Each later hint is live: the server's solver names the next piece to capture from the current position. On a dead-end board the hint says to undo, and that costs nothing.
- **Competitive modes.** A mode that isn't listed in `GameConfig.HINTS` gets no hints. A competitive mode added later must be listed with `0`.
- **Home and resume.** The home screen opens on join. Continue starts the first unlocked, uncleared Journey puzzle after the player's last Journey clear (wrapping round to anything skipped). Resume returns to an attempt already in progress. The server also starts that puzzle behind the home screen once the profile loads.

### Stars, coins and achievements

- **Stars** depend on moves only. Hints never cost stars.
  - 3 stars: within par (par is the proven minimum).
  - 2 stars: at most `GameConfig.STAR_SLACK[difficulty]` moves over par (Beginner 1, Easy 2, Medium 3, Hard 4, Expert 5). A puzzle can set `twoStarMoves` to override this.
  - 1 star: any other clear.
  - The server rates the clear from its own move count. The best rating is kept from Journey and Daily clears. Practice shows a rating but doesn't save it.
- **Coins** are cosmetic only and can't be bought. They come from:
  - first Journey clears (the puzzle's reward)
  - the Daily Puzzle (once per day)
  - achievements (`Achievements.luau`, paid once under `ach:<id>`)

  Replays and repeated requests pay nothing. `GameConfig.COSMETIC_SLOTS` and `profile.cosmetics` hold places for future board themes, piece skins and effects. Nothing is for sale yet.
- **Daily streak.** Clearing the Daily Puzzle on consecutive UTC days builds the streak.
  - One shield per rolling 7 days (`GameConfig.STREAK_SHIELD_DAYS`) covers a single missed day: clearing on day N+2 after a clear on day N keeps the streak.
  - The missed day pays nothing and isn't marked cleared.
  - Two missed days, or a second miss inside the 7 days, reset the streak to 1.
  - Late or repeated ops never move the streak.
- **Settings.** Sound on/off, master volume and vibration are saved as a `settings` op. The server keeps only valid values.

### Sound and haptics

`UI/SoundConfig.luau` maps each event to a sound: click, select, move, capture, invalid, hint, win, fail, unlock and menu open.

- Every id is an Audio asset published by Roblox or ProSoundEffects. Each was checked with `MarketplaceService:GetProductInfo`, and each loaded in Studio.
- Set an id to `nil` to silence an event.
- The same event can't start twice within 80 ms.
- Vibration is used only when `HapticService` reports support for the current input (touch or gamepad). Otherwise the setting shows "Not supported on this device". Every vibration goes with a sound and a visual change, so nothing depends on it.

### Saving (ProfileStore)

Progress lives in the DataStore `EchoChessProfiles_v1`, under the key `player_<userId>`. It holds:

- completions, best results and star ratings
- XP and coins
- stats: solves, fails, restarts, hints, moves, dailies
- the Daily Puzzle state for the day, and the streak with its shield
- the last Journey clear (for Continue)
- settings, and cosmetic slots for later
- a ledger of rewards already paid

How saving works:

- **Ops, not overwrites.** Every change is an op. The server applies it to the in-memory profile at once, and applies it again inside `UpdateAsync` against whatever is stored at that moment. Another server's writes are kept.
- **No double counting.** Each op has an id, and the profile remembers the last 200 ids. A save that is retried, or that wrote but reported an error, counts only once.
- **No double rewards.** Rewards are keyed: `journey:<puzzle id>` for puzzle rewards, `ach:<id>` for achievements, the day number for the Daily reward. Each reward is paid at most once, even if two servers race.
- **Failures.** Loads and saves wait for request budget and retry with exponential backoff. Writes to one key are at least 7 s apart.
  - If loading fails, the player plays on a blank profile marked offline. The next save that succeeds merges into the stored data and replaces the blank view.
  - A failed save keeps its ops queued and writes nothing.
  - A permanent error (Studio without API access, or an unpublished place) turns DataStore calls off for that server instead of retrying.
- **When it saves.** Soon after each win, every 60 s, when a player leaves (with extra retries), and on `BindToClose`.

## Security model

The client sends only intents (`start`, `move`, `undo`, `restart`, `hint`, `settings`, `sync`). The server owns everything else:

- The server validates every move against the shared rules. It rejects the move if the player has no piece there, the move is illegal or the input is malformed.
- The server decides win and fail and keeps its own timer. Before recording a win, it replays its own move log through the rules.
- Unlocks, the Daily Puzzle choice, hint allowances, stars, achievements, the streak and rewards are decided on the server from the stored profile. The client's menu only displays them.
- After every action the server sends a full snapshot.
- Each player is limited to a burst of 8 actions, refilled at 6 per second. A throttled burst gets a single "rate limited" notice.

The client calculates legal-move highlights only to draw them on the board.

## Solver

`PuzzleValidator` searches capture by capture. It flood-fills the quiet moves from the current square, then recurses on each capture it finds.

After a capture, a state is fully described by two things: which target was just taken, and which targets remain. That makes memoising on that pair exact.

It is fast for three reasons:

- **Compiled board.** The board is compiled once per search into move rays per square and piece type, with walls already removed. The flood fill reuses preallocated arrays.
- **Bitmask targets.** Targets are stored as bits in a mask.
- **Capture-graph pruning.** The solver builds a graph of which piece could ever capture which, as if every other target were already gone. Any real position can do at most what this graph allows. If the remaining targets can't form a path through the graph, the state is cut. This cut never removes a solvable state.

There is no target limit. The server's dead-end check passes a state budget (`PuzzleSession.SOLVER_BUDGET`). If the budget runs out, the answer is "unknown" and the player keeps playing, so a solvable board is never failed by mistake.

A quiet move by anything but a pawn can be reversed. It changes nothing the solver cares about, so the server skips the check for those moves.

The Phase 2 solver is kept unchanged as `tests/lib/ReferenceSolver.luau`. The tests check the new solver against it.

## Running the tests

The engine is plain Luau and runs outside Roblox. Get the `luau` CLI from
<https://github.com/luau-lang/luau/releases>, then run:

```sh
python3 tools/run_tests.py path/to/luau
```

The suite checks:

**Rules and sessions**
- move generation for every piece, plus walls, blocking and captures
- echo transformation and undo
- the session rejects bad input, and handles win, fail, undo and restart

**Solver**
- the compiled move tables match `ChessRules` on every square for every piece
- the solver agrees with the Phase 2 solver on 600 random small boards and 24 random 8x8 boards
- shortest solutions match the Phase 2 full-position BFS
- capture-order counts match a plain enumeration
- a state budget never gives a wrong answer
- 39-target boards work
- after random play with undos, the session status always matches a full solver check

**Puzzles**
- `PuzzleCheck` passes for every puzzle, and the Phase 2 solver independently agrees each one is solvable
- each difficulty has 6 puzzles, and none repeat
- `PuzzleCheck` catches broken definitions

**Progression and saving**
- unlocks, Practice, Daily rewards and hints, and op de-duplication
- stars and their thresholds, achievements paid once (also across two servers), the streak and its 7-day shield, resume, unlock progress, settings validation, and loading Phase 3 profiles
- `ProfileStore`, against `tests/lib/FakeStore`: failed loads, failed saves, a write that reports an error, two servers racing, a concurrent write, write spacing, budget waits, the final save on leave, and permanent errors

**Hints**
- each live hint names a target that still leaves the board solvable

### Other scripts

`tests/analyze.luau` prints a report for every puzzle: size, targets, par, winning and dead-end capture orders, and the difficulty score `PuzzleCheck` grades it by.

`tests/bench.luau` times the Phase 2 solver against the current one on the shipped puzzles and on larger fixed boards.

```sh
python3 tools/run_tests.py path/to/luau tests/analyze.luau
python3 tools/run_tests.py path/to/luau tests/bench.luau
```

The same files also run inside Studio. Put copies of the `Shared` modules, `ProfileStore` and the `tests/lib` modules in one Folder. Then run the test file's source with `loadstring`, passing that Folder as `Shared`.

### Adding a puzzle

1. Add an entry to `CATALOG` in `PuzzleDefinitions` with:
   - an id
   - a name
   - the layout
   - a shortest solution: `PuzzleValidator.shortestSolution` gives one
   - two hints
2. Run the tests. `PuzzleCheck` reports anything wrong, including a puzzle filed under the wrong difficulty.

## Syncing into Studio

You can use Rojo (`rojo serve` with `default.project.json`). Without Rojo,
`tools/studio_sync.py` prints a Luau chunk that creates the folders, remotes
and scripts and writes each script's source. Paste it into the Studio command bar:

```sh
python3 tools/studio_sync.py > sync.luau                                 # embeds sources
python3 tools/studio_sync.py --github kendiofc/CHESS@<commit> > sync.luau  # downloads them
```
