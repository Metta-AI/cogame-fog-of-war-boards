# Fog-of-War Boards

Two cogs. One board. **You can only see your own stones.**

A merged port of OpenSpiel's hidden-information board games for the Softmax
Coworld platform, on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology stack
(forked from [cogame-babel](https://github.com/Metta-AI/cogame-babel)).
Phantom Tic-Tac-Toe and Dark Hex: classic boards, classic rules, and a
referee who tells you exactly one thing — **PLACED** or **OCCUPIED**. The
only channel through which a seat ever learns anything about its opponent
is the answer to its own move. You discover the enemy only by trying to
play on him.

Because a stone, once placed, never moves and is never removed, a seat's
knowledge is **monotone**: anything the referee has ever told you stays
true forever. That single invariant is why one sim module, one observation
builder, one referee vocabulary and one belief overlay serve every shipped
variant honestly — and why the whole skill is belief tracking on rules a
cog already knows cold.

## The four variants

| id | source | board | a collision… | sense | maxPlies |
|---|---|---|---|---|---|
| `phantom-ttt-3` | OpenSpiel `phantom_ttt` | 3×3 grid | …does not end your turn | — | 18 |
| `dark-hex-4` | OpenSpiel `dark_hex` | 4×4 rhombus | …does not end your turn | — | 32 |
| `dark-hex-5` | OpenSpiel `abrupt_dark_hex` | 5×5 rhombus | …**ends your turn** | — | 50 |
| `recon-hex-5` | **original** (RBC's sense loop on Abrupt Dark Hex) | 5×5 rhombus | …**ends your turn** | 2×2 each ply | 50 |

`recon-hex-5` is **not** a port of OpenSpiel `rbc`: it is Abrupt Dark Hex
5×5 with Reconnaissance Blind Chess's *sense-then-move* loop transplanted
onto it — each ply the mover first names a 2×2 window and is told the truth
about those four cells, then moves. It is the one variant where knowing a
cell is **empty** goes stale.

Kriegspiel, Reconnaissance Blind Chess and Phantom Go are deliberately out
of scope: the first two need a complete chess engine and a second referee
vocabulary, and Phantom Go's captures make a seat's knowledge non-monotone,
which would change what the belief overlay means. See
`docs/plans/2026-08-27-fog-of-war-boards-design.md` §Out of scope.

## The rules, in one screen

Cells are algebraic: files `a`, `b`, `c`… left to right, ranks `1`, `2`,
`3`… bottom to top. Seat 0 is red and moves first; seat 1 is blue.

- **Dark Hex.** Red links the left file to the right file, blue links the
  bottom rank to the top rank, on an `n × n` rhombus where every cell
  touches six others. Hex has no draws: a full board holds exactly one of
  those two connections.
- **Phantom Tic-Tac-Toe.** Own all three cells of one of the eight lines. A
  full board with no line is a draw.
- A ply is **one attempt**: one seat naming one cell (preceded, in
  `recon-hex-5`, by one sense anchor). An empty cell places your stone; a
  cell holding an opponent stone places nothing, proves that cell to you
  forever, and — in the *abrupt* variants — ends your turn.
- You may never name a cell you already hold or have already proven is
  theirs. That is what bounds the episode at `2 × cells` plies.
- `score = +1 / 0 / −1`, always summing to zero. `probes`, `discovered`,
  `guessAccuracy` and `distToWin` are reported and drawn but **never**
  scored, so no policy can farm them instead of winning.

`results.reason` is `complete` or `deadline`; the finer `results.ending` is
`connection`, `line`, `board-full`, `ply-cap` or `wall-clock`. A `deadline`
episode is fully scored at the stop by the true distance to victory — a
real result, not a discarded one.

## A policy is just a prompt

The game is LLM-driven. Whenever a seat has to move, the server sends that
seat's policy prompt plus **its own fogged view** — its stones, the
opponent stones it has proven, its referee log, its private notes, its
legal attempts — to Claude, which answers with one JSON object:

```json
{"cell": "c4", "sense": "b3", "guess": ["d3", "d4"],
 "say": "his chain has to cross d3", "notes": "proven: c2,d4. route a3-b3-c3-d3-e3."}
```

Field your own policy by reusing the published player runnable:

```bash
coworld upload-policy <fog-of-war-boards-image> --name my-fog \
  --run /bin/fog-of-war-boards-player \
  --secret-env PLAYER_PROMPT="<your strategy>"
```

Two **scripted baselines** ship in the same image, selected with
`PLAYER_SCRIPTED`:

- **`probe`** — a real Hex player: it computes its own distance to victory
  on the board *as it believes it to be* and plays the cell that shortens
  it most, which probes the opponent as a side effect, because the cells on
  its shortest path are exactly the ones the opponent wants.
- **`sweep`** — a corridor walker: it drives a straight lane across the
  board and shifts the whole lane one step every time it runs into a stone.

Both are always legal, both are blind (a test flips every cell they cannot
legitimately see and asserts they decide identically), and they disagree on
~70 % of plies. With no LLM credentials at all every seat plays `probe`
immediately — which is what makes offline certification and the CI smoke
complete without a key.

## Watchability

Spectators see the **true** board flanked by each seat's **belief** board.
The gap between them is the show:

- on the truth board, a stone the seat to move has not proven is covered by
  the ink cross-hatch — the fog is literally what the mover cannot see;
- on a belief board, own stones are solid, *proven* opponent stones are
  solid with a hard ring (that cell was **bought**), *guessed* cells are
  35 % with a dashed ring and resolve to a tick or a ghost cross, and cells
  sensed empty fade as they go stale;
- a collision flashes amber on all three boards and takes its own, taller
  beat on the scrubber. It is the most watchable moment in the game.

Replays are the **static wasm bundle** — `tools/build_replay_viewer.sh`
compiles the same `fogboards/sim` module to WebAssembly, and the viewer
re-derives every frame in the browser from the recorded events. There is no
replay pod anywhere.

## Layout

- `src/fogboards.nim` — entrypoint (Coworld runtime contract, live vs replay)
- `src/fogboards/types.nim` — config, events, enums
- `src/fogboards/sim.nim` — pure rules: the board, the fog, `distToWin`,
  `settle`, `replayMatch`; shared by the server, the tests and the viewer
- `src/fogboards/llm.nim` — the Claude client, the prompts, the two baselines
- `src/fogboards/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/fogboards_player.nim` — the prompt-delivery player
- `client/chrome_common.js` — the broadcast chrome, byte-copied from
  cogame-babel with six named edits
- `client/renderer.js` — the game block: three boards in one canvas
- `replay-viewer/` — the static wasm replay viewer (`?replay=<url>`)
- `data/` — the font and floor from cogame-babel (MIT, originally
  coworld-ctf); `fog_hatch.png` and `lens.png` authored for this repo
- `scripts/art/` — the nano-banana source sheet and the split script
- `docs/plans/` — the design note this game was built from

## Building and testing

The sandbox that wrote this repo has no Docker, no Nim and no emsdk; CI is
the harness. `.github/workflows/ci.yml` runs every `tests/*.nim` in debug
**and** release, builds the production image and plays one real episode
end to end in raw Docker with the certification fixture, then builds the
wasm bundle and opens it in headless chromium against the replay that
episode produced.

```bash
nim r --path:src tests/test_sim.nim       # the rules
nim r --path:src tests/test_bot.nim       # the baselines
nim r --path:src tests/test_replay.nim    # record -> re-derive, and the bytes
nim r --path:src tests/test_manifest.nim  # packaging invariants
```
