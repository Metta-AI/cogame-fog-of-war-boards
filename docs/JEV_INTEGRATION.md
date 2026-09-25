# Jev as a Fog-of-War Boards player

`fogboards.player.v2` lets a player register external action control. At each
turn the game sends only that seat's stones, proven opponent stones, stale
sense readings, referee log, notes, and exact legal cell and sense choices.
The player returns a decision ID and its chosen cells. The game checks the
acting seat, decision ID, and action legality, then owns scoring, fallback,
results, and replay. Prompt control and probe/sweep scripted policies remain
available on the same game build.

`PLAYER_JEV=1` ranks the offered choices through SystemOne inside the player
container. Direct `TYPESAFE_API_KEY` and the hosted inference sidecar are
player credentials; the game does not receive them. `PLAYER_PROMPT` can add
strategy guidance to Jev's player-side request.

## Local evidence

Build with `coworld[auth]==0.1.43`, `--version 0.1.99`, and
`--compose compose.jev-local.yaml`. The normal prompt/probe roster passed all
ten Coworld certification checks. The separate mixed player smoke runs:

```bash
python3 tools/ci/smoke_jev.py /tmp/fogboards-jev-smoke
```

Four `linux/amd64` container episodes cover Phantom Tic-Tac-Toe, non-abrupt
Dark Hex, abrupt Dark Hex, and reconnaissance Dark Hex. A mock SystemOne
accepted 15 Jev actions with zero fallback. The smoke verifies seat-local
redaction, legal cell and sense choices, direct and sidecar headers, and
replayed actions. The normal prompt/probe Docker fixture passed. Four native
test suites passed in debug and release. These mock decisions test interface
wiring, not Jev strength or provider cost. No hosted resource changed.

The static viewer served at
`http://127.0.0.1:39814/?replay=replay.json` loaded the mixed
reconnaissance replay. Clicking the ply-3 `d2` action moved the timeline to
step 7 of 18.
