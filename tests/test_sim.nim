## The rules. Everything here drives the same `sim` module the server, the
## wasm viewer and the baselines drive, so a rule that passes here is the
## rule the hosted episode plays.

import std/[json, os, random, sets, tables, unittest]
import fogboards/[llm, sim]

proc fixture(mode = mDarkHex, size = 5, abrupt = true, sense = 0,
    maxPlies = 50, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.mode = mode
  result.size = size
  result.abrupt = abrupt
  result.sense = sense
  result.maxPlies = maxPlies
  result.seed = seed
  result.turnDelayMs = 0
  ## Pinned, so these tests exercise the rules rather than the budget fit.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc variants(): seq[GameConfig] =
  @[
    fixture(mPhantomTtt, 3, false, 0, 18),
    fixture(mDarkHex, 4, false, 0, 32),
    fixture(mDarkHex, 5, true, 0, 50),
    fixture(mDarkHex, 5, true, 2, 50)
  ]

proc playBaseline(config: GameConfig, baseline: Baseline): Sim =
  result = initSim(config)
  while not result.done:
    let mover = result.beginPly()
    let decision = scriptedDecision(result, mover, baseline)
    if config.sense > 0:
      result.applySense(mover, decision.anchor)
    result.applyAttempt(mover, decision.cell, "", "", @[], true, false)

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir()
  for _ in 0 .. 4:
    if fileExists(dir / "coworld_manifest_template.json"):
      return dir
    dir = dir.parentDir()
  raise newException(IOError, "coworld_manifest_template.json not found")

suite "coordinates":
  test "1. algebraic names round-trip through every shipped size":
    for size in [3, 4, 5]:
      let sim = initSim(fixture(
        (if size == 3: mPhantomTtt else: mDarkHex), size, true, 0, 18))
      for cell in 0 ..< size * size:
        check sim.cellIndex(sim.cellName(cell)) == cell
      check sim.cellName(0) == "a1"
      check sim.rowOf(0) == 0
      check sim.colOf(0) == 0
      check sim.cellName(size * size - 1) ==
        $chr(ord('a') + size - 1) & $size
      ## Case and stray whitespace are tolerated; off-board is not.
      check sim.cellIndex(" A1 ") == 0
      expect FogError:
        discard sim.cellIndex("z9")
      expect FogError:
        discard sim.cellIndex("a" & $(size + 1))
      expect FogError:
        discard sim.cellIndex("")
    let five = initSim(fixture(mDarkHex, 5))
    check five.cellIndex("e5") == 24
    check five.rowOf(24) == 4
    check five.colOf(24) == 4
    check five.cellName(2 * 5 + 2) == "c3"

suite "board":
  test "2. the hex rhombus neighbourhood is exactly six, and symmetric":
    let sim = initSim(fixture(mDarkHex, 5))
    var around: HashSet[string]
    for cell in sim.neighbours(sim.cellIndex("c3")):
      around.incl(sim.cellName(cell))
    check around == toHashSet(["b3", "d3", "c2", "c4", "b4", "d2"])
    var corner: HashSet[string]
    for cell in sim.neighbours(sim.cellIndex("a1")):
      corner.incl(sim.cellName(cell))
    check corner == toHashSet(["b1", "a2"])
    for cell in 0 ..< sim.cells:
      for other in sim.neighbours(cell):
        check cell in sim.neighbours(other)

  test "3. a full hex board has exactly one winner, never zero, never two":
    for seed in 0 ..< 300:
      var sim = initSim(fixture(mDarkHex, 5, seed = seed))
      var rng = initRand(int64(seed) * 31 + 7)
      for cell in 0 ..< sim.cells:
        sim.board[cell] = if rng.rand(1) == 0: ocSeat0 else: ocSeat1
      let zero = sim.trueDistToWin(0) == 0
      let one = sim.trueDistToWin(1) == 0
      check zero != one

suite "plies":
  test "4. an empty cell places; an opponent stone is a collision":
    var sim = initSim(fixture(mDarkHex, 5, abrupt = true))
    discard sim.beginPly()
    sim.applyAttempt(0, sim.cellIndex("c3"), "", "", @[], true, false)
    check sim.events[^1].kind == evAttempt
    check sim.events[^1].outcome == "placed"
    check sim.stones[0] == 1
    check sim.board[sim.cellIndex("c3")] == ocSeat0
    check sim.mover == 1
    discard sim.beginPly()
    sim.applyAttempt(1, sim.cellIndex("c3"), "", "", @[], true, false)
    check sim.events[^1].outcome == "occupied"
    check sim.stones[1] == 0
    check sim.probes[1] == 1
    check sim.cellIndex("c3") in sim.known[1]
    check sim.board[sim.cellIndex("c3")] == ocSeat0
    ## The knowledge is one-way: seat 0 learned nothing.
    check sim.known[0].len == 0

  test "5. own stones, proven cells and off-board cells are not attempts":
    var sim = initSim(fixture(mDarkHex, 5, abrupt = true))
    let before = sim.legalAttempts(0).len
    check before == 25
    discard sim.beginPly()
    sim.applyAttempt(0, sim.cellIndex("c3"), "", "", @[], true, false)
    check sim.legalAttempts(0).len == before - 1
    check sim.cellIndex("c3") notin sim.legalAttempts(0)
    discard sim.beginPly()
    sim.applyAttempt(1, sim.cellIndex("c3"), "", "", @[], true, false)
    check sim.cellIndex("c3") notin sim.legalAttempts(1)
    expect FogError:
      sim.applyAttempt(0, sim.cellIndex("c3"), "", "", @[], true, false)
    expect FogError:
      sim.applyAttempt(0, -1, "", "", @[], true, false)
    expect FogError:
      sim.applyAttempt(0, 25, "", "", @[], true, false)
    ## Seat 1 has already proven c3; naming it again is not a game action.
    sim.mover = 1
    expect FogError:
      sim.applyAttempt(1, sim.cellIndex("c3"), "", "", @[], true, false)
    ## The legal set only ever shrinks.
    for baseline in [blProbe, blSweep]:
      for seed in 0 ..< 20:
        var live = initSim(fixture(mDarkHex, 5, seed = seed))
        var sizes = [live.legalAttempts(0).len, live.legalAttempts(1).len]
        while not live.done:
          let mover = live.beginPly()
          let decision = scriptedDecision(live, mover, baseline)
          live.applyAttempt(mover, decision.cell, "", "", @[], true, false)
          let now = live.legalAttempts(mover).len
          check now < sizes[mover]
          sizes[mover] = now

  test "6. a collision ends the turn only when the variant is abrupt":
    for abrupt in [false, true]:
      var sim = initSim(fixture(mDarkHex, 5, abrupt = abrupt))
      discard sim.beginPly()
      sim.applyAttempt(0, sim.cellIndex("a1"), "", "", @[], true, false)
      check sim.mover == 1                     ## a placement always flips
      discard sim.beginPly()
      sim.applyAttempt(1, sim.cellIndex("a1"), "", "", @[], true, false)
      check sim.mover == (if abrupt: 0 else: 1)
      if not abrupt:
        ## Seat 1 moves again, knowing one more cell.
        sim.applyAttempt(1, sim.cellIndex("e5"), "", "", @[], true, false)
        check sim.mover == 0

  test "7. every variant and baseline terminates inside its ply cap":
    for config in variants():
      for baseline in [blProbe, blSweep]:
        var reachedCap = 0
        for seed in 0 ..< 300:
          var seeded = config
          seeded.seed = seed
          let sim = playBaseline(seeded, baseline)
          check sim.done
          check sim.plies <= seeded.maxPlies
          check seeded.maxPlies <= 2 * seeded.size * seeded.size
          if sim.ending == "ply-cap":
            inc reachedCap
        ## In Hex the board fills before the cap can bite, and a full Hex
        ## board always has a winner.
        if config.mode == mDarkHex:
          check reachedCap == 0

suite "endings":
  test "8. every ending fires where the rules say it does":
    ## connection: a scripted hex episode ends on the placing ply.
    let hex = playBaseline(fixture(mDarkHex, 5, seed = 3), blProbe)
    check hex.reason == "complete"
    check hex.ending == "connection"
    check hex.winner in [0, 1]
    check hex.events[^1].kind == evEnd
    check hex.events[^2].kind == evWin
    check hex.events[^2].seat == hex.winner
    check hex.events[^2].how == "connection"
    check hex.events[^3].kind == evAttempt
    check hex.events[^3].outcome == "placed"
    check hex.events[^2].path.len >= hex.config.size
    ## The recorded path really is a chain of the winner's own stones.
    for name in hex.events[^2].path:
      check hex.board[hex.cellIndex(name)] == occupantOf(hex.winner)

    ## line: seat 0 takes the top row.
    var ttt = initSim(fixture(mPhantomTtt, 3, false, 0, 18))
    for move in ["a3", "a1", "b3", "b1", "c3"]:
      let mover = ttt.beginPly()
      ttt.applyAttempt(mover, ttt.cellIndex(move), "", "", @[], true, false)
    check ttt.done
    check ttt.reason == "complete"
    check ttt.ending == "line"
    check ttt.winner == 0
    check ttt.events[^2].how == "line"
    check ttt.events[^2].path == @["a3", "b3", "c3"]

    ## board-full: the classic drawn grid.
    var draw = initSim(fixture(mPhantomTtt, 3, false, 0, 18))
    for move in ["a3", "b3", "c3", "b2", "a2", "c2", "b1", "a1", "c1"]:
      let mover = draw.beginPly()
      draw.applyAttempt(mover, draw.cellIndex(move), "", "", @[], true, false)
    check draw.done
    check draw.reason == "complete"
    check draw.ending == "board-full"
    check draw.winner == -1
    check draw.score(0) == 0.0
    check draw.score(1) == 0.0

    ## ply-cap: a contrived four-ply hex episode nobody can win.
    var capped = initSim(fixture(mDarkHex, 5, maxPlies = 4))
    for move in ["a1", "b1", "a2", "b2"]:
      let mover = capped.beginPly()
      capped.applyAttempt(mover, capped.cellIndex(move), "", "", @[], true,
        false)
    check capped.done
    check capped.plies == 4
    check capped.reason == "complete"
    check capped.ending == "ply-cap"

    ## wall-clock: the play deadline, applied by the same settle.
    var stopped = initSim(fixture(mDarkHex, 5))
    discard stopped.beginPly()
    stopped.applyAttempt(0, stopped.cellIndex("c3"), "", "", @[], true, false)
    stopped.endEarly()
    check stopped.done
    check stopped.reason == "deadline"
    check stopped.ending == "wall-clock"
    check stopped.events[^1].kind == evEnd
    check stopped.events[^1].reason == "deadline"
    check stopped.events[^1].ending == "wall-clock"
    let before = stopped.events.len
    stopped.endEarly()                          ## idempotent
    check stopped.events.len == before

suite "tension":
  test "9. distToWin measures the real distance in both modes":
    var sim = initSim(fixture(mDarkHex, 5))
    ## An empty 5x5: five stones to cross.
    check sim.trueDistToWin(0) == 5
    check sim.trueDistToWin(1) == 5
    ## A full FILE of seat 1 is a bottom-to-top chain: it wins for seat 1
    ## and, by Hex's own duality, cuts seat 0 off completely.
    for row in 0 ..< 5:
      sim.board[row * 5 + 2] = ocSeat1
    check sim.trueDistToWin(0) == Unreachable
    check sim.trueDistToWin(1) == 0
    ## A finished connection is distance 0.
    var linked = initSim(fixture(mDarkHex, 5))
    for col in 0 ..< 5:
      linked.board[col] = ocSeat0
    check linked.trueDistToWin(0) == 0
    ## Monotone non-increasing for the seat that plays on its own route.
    var walk = initSim(fixture(mDarkHex, 5))
    var last = walk.trueDistToWin(0)
    for col in 0 ..< 5:
      walk.board[2 * 5 + col] = ocSeat0
      let now = walk.trueDistToWin(0)
      check now <= last
      last = now
    check last == 0
    ## Tic-tac-toe: the fewest marks any live line still needs.
    var ttt = initSim(fixture(mPhantomTtt, 3, false, 0, 18))
    check ttt.trueDistToWin(0) == 3
    ttt.board[ttt.cellIndex("b2")] = ocSeat0
    check ttt.trueDistToWin(0) == 2
    ttt.board[ttt.cellIndex("a1")] = ocSeat0
    check ttt.trueDistToWin(0) == 1
    for name in ["a1", "b2", "c3", "a2", "b1", "a3", "c1"]:
      ttt.board[ttt.cellIndex(name)] = ocSeat1
    ttt.board[ttt.cellIndex("b3")] = ocSeat1
    ttt.board[ttt.cellIndex("c2")] = ocSeat1
    check ttt.trueDistToWin(0) == Unreachable

suite "scoring":
  test "10. scores sum to zero and follow the ending table":
    for config in variants():
      for seed in 0 ..< 75:
        for baseline in [blProbe, blSweep]:
          var seeded = config
          seeded.seed = seed
          let sim = playBaseline(seeded, baseline)
          let results = sim.resultsJson()
          let a = results["scores"][0].getFloat()
          let b = results["scores"][1].getFloat()
          check a + b == 0.0
          check results["reason"].getStr() in ["complete", "deadline"]
          check results["ending"].getStr() in
            ["connection", "line", "board-full", "ply-cap", "wall-clock"]
          if sim.ending in ["connection", "line"]:
            check sim.winner >= 0
            check sim.score(sim.winner) == 1.0
            check sim.score(1 - sim.winner) == -1.0
          elif sim.winner < 0:
            ## A draw only ever happens on a non-terminal ending, and only
            ## when the true distances are level.
            check sim.ending in ["board-full", "ply-cap", "wall-clock"]
            check a == 0.0 and b == 0.0
            check sim.trueDistToWin(0) == sim.trueDistToWin(1)
          else:
            check sim.trueDistToWin(sim.winner) <
              sim.trueDistToWin(1 - sim.winner)

suite "reconnaissance":
  test "11. a sense reveals its window truthfully and nothing else":
    var sim = initSim(fixture(mDarkHex, 5, sense = 2))
    sim.board[sim.cellIndex("b3")] = ocSeat1
    sim.board[sim.cellIndex("c3")] = ocSeat1
    discard sim.beginPly()
    sim.applySense(0, sim.cellIndex("b3"))
    ## b3 and c3 are proven; b4 and c4 are merely sensed empty.
    check sim.cellIndex("b3") in sim.known[0]
    check sim.cellIndex("c3") in sim.known[0]
    check sim.cellIndex("b4") in sim.sensedEmptyAt[0]
    check sim.sensedEmptyAt[0][sim.cellIndex("b4")] == 0
    check sim.cellIndex("b4") notin sim.known[0]
    check sim.events[^1].kind == evSense
    check sim.events[^1].anchor == "b3"
    check sim.events[^1].seat == 0
    ## Seat 1 learned nothing from seat 0's window.
    check sim.known[1].len == 0
    check sim.sensedEmptyAt[1].len == 0
    ## Sensed-empty is NOT knowledge of occupancy: the cell stays legal
    ## and stays absent from the believed board.
    check sim.cellIndex("b4") in sim.legalAttempts(0)
    check sim.believedBoard(0)[sim.cellIndex("b4")] == ocEmpty
    expect FogError:
      sim.applySense(0, sim.cellIndex("e5"))    ## the window falls off
    expect FogError:
      sim.applySense(1, sim.cellIndex("a1"))    ## not seat 1's ply
    ## With sense off, no sense event is ever emitted.
    for baseline in [blProbe, blSweep]:
      for seed in 0 ..< 20:
        let plain = playBaseline(
          fixture(mDarkHex, 5, seed = seed), baseline)
        for event in plain.events:
          check event.kind != evSense
        let recon = playBaseline(
          fixture(mDarkHex, 5, sense = 2, seed = seed), baseline)
        var senses = 0
        for event in recon.events:
          if event.kind == evSense:
            inc senses
            check event.anchor.len >= 2
        check senses == recon.plies

suite "fog":
  test "12. a seat's believed board never holds an unproven stone":
    for config in variants():
      for seed in 0 ..< 75:
        for baseline in [blProbe, blSweep]:
          var seeded = config
          seeded.seed = seed
          var sim = initSim(seeded)
          while not sim.done:
            let mover = sim.beginPly()
            for seat in 0 ..< Seats:
              let believed = sim.believedBoard(seat)
              let them = occupantOf(1 - seat)
              for cell in 0 ..< sim.cells:
                if believed[cell] == them:
                  ## Everything it believes about the opponent it PROVED.
                  check cell in sim.known[seat]
                  check sim.board[cell] == them
                if sim.board[cell] == them and cell notin sim.known[seat]:
                  check believed[cell] == ocEmpty
                if believed[cell] == occupantOf(seat):
                  check sim.board[cell] == occupantOf(seat)
            let decision = scriptedDecision(sim, mover, baseline)
            if seeded.sense > 0:
              sim.applySense(mover, decision.anchor)
            sim.applyAttempt(mover, decision.cell, "", "", @[], true, false)

suite "manifest fixtures":
  test "13. every shipped game_config constructs a Sim and plays out":
    let manifest = parseJson(
      readFile(repoRoot() / "coworld_manifest_template.json"))
    var configs: seq[JsonNode]
    for variant in manifest["variants"]:
      configs.add(variant["game_config"])
    configs.add(manifest["certification"]["game_config"])
    check configs.len == 5
    for node in configs:
      var raw = node.copy()
      ## The runner injects the tokens; no shipped game_config carries them.
      check not raw.hasKey("tokens")
      var tokens = newJArray()
      for slot in 0 ..< raw["num_agents"].getInt():
        tokens.add(%("token-" & $slot))
      raw["tokens"] = tokens
      var config = defaultGameConfig()
      config.update($raw)
      config = sampleEpisode(config)
      check config.players.len == raw["num_agents"].getInt()
      let sim = playBaseline(config, blProbe)
      check sim.done
      check sim.plies <= config.maxPlies
      check sim.resultsJson()["reason"].getStr() == "complete"
