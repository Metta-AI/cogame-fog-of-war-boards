## The scripted baselines. They are the no-credentials fallback (offline
## certification runs entirely on them), the fallback every failed LLM
## decision lands on, AND fieldable policies, so "always legal, always
## blind, always terminating" is the completion path for this whole
## coworld, not a nicety.

import std/[monotimes, os, sets, strutils, tables, times, unittest]
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

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir()
  for _ in 0 .. 4:
    if fileExists(dir / "client" / "renderer.js"):
      return dir
    dir = dir.parentDir()
  raise newException(IOError, "client/renderer.js not found")

proc replayDwell(): Table[string, int] =
  ## The viewer's per-event pacing, read straight out of the shipped
  ## renderer so the soak arithmetic below cannot drift from it.
  let source = readFile(repoRoot() / "client" / "renderer.js")
  let start = source.find("var DWELL = {")
  doAssert start >= 0, "client/renderer.js no longer declares var DWELL"
  let stop = source.find("};", start)
  doAssert stop > start
  for entry in source[start + len("var DWELL = {") ..< stop].split(','):
    let parts = entry.split(':')
    if parts.len == 2:
      result[parts[0].strip()] = parseInt(parts[1].strip())

proc shadowed(sim: Sim, seat, anchor: int): Sim =
  ## The same episode with every cell the seat CANNOT legitimately see
  ## flipped: its own stones, the cells it has proven, and the window the
  ## referee is about to reveal to it are untouched; everything else is
  ## inverted. A baseline that reads `sim.board` behind the fog decides
  ## differently on this board — that is the whole point of the fixture.
  result = sim
  let me = occupantOf(seat)
  let them = occupantOf(1 - seat)
  var window: HashSet[int]
  if anchor >= 0:
    for cell in sim.senseWindow(anchor):
      window.incl(cell)
  for cell in 0 ..< sim.cells:
    if result.board[cell] == me or cell in sim.known[seat] or cell in window:
      continue
    result.board[cell] = if result.board[cell] == them: ocEmpty else: them

suite "the baselines are legal, blind and bounded":
  test "14. 200 seeded episodes x 4 variants x 2 baselines stay legal":
    for config in variants():
      for baseline in [blProbe, blSweep]:
        for seed in 0 ..< 200:
          var seeded = config
          seeded.seed = seed
          var sim = initSim(seeded)
          while not sim.done:
            let mover = sim.beginPly()
            let decision = scriptedDecision(sim, mover, baseline)
            ## Legal at the moment it is produced, by the same predicates
            ## the validator applies.
            check decision.cell in sim.legalAttempts(mover)
            if seeded.sense > 0:
              check decision.anchor in sim.legalAnchors(mover)
            else:
              check decision.anchor == -1
            ## Blind: the decision does not change when the fog changes.
            let blind = scriptedDecision(
              shadowed(sim, mover, decision.anchor), mover, baseline)
            check blind.cell == decision.cell
            check blind.anchor == decision.anchor
            ## A baseline never speaks, never writes notes, never guesses.
            check decision.say.len == 0
            check decision.notes.len == 0
            check decision.guess.len == 0
            check not decision.fellBack
            if seeded.sense > 0:
              sim.applySense(mover, decision.anchor)
            sim.applyAttempt(mover, decision.cell, "", "", @[], true, false)
          check sim.done
          check sim.plies <= seeded.maxPlies

  test "15. probe beats a uniform-random legal attacker":
    var total = 0.0
    var wins = 0
    for seed in 0 ..< 200:
      var config = fixture(mDarkHex, 5, seed = seed)
      ## Alternate the seats so the result is not a first-move artefact.
      let botSeat = seed mod 2
      var sim = initSim(config)
      var rng = uint32(seed) * 2654435761'u32 + 12345'u32
      while not sim.done:
        let mover = sim.beginPly()
        var cell = 0
        if mover == botSeat:
          cell = scriptedDecision(sim, mover, blProbe).cell
        else:
          let legal = sim.legalAttempts(mover)
          rng = rng * 1664525'u32 + 1013904223'u32
          cell = legal[int(rng shr 16) mod legal.len]
        sim.applyAttempt(mover, cell, "", "", @[], true, false)
      total += sim.score(botSeat)
      if sim.winner == botSeat:
        inc wins
    echo "probe vs random: mean score ", total / 200.0, " (", wins,
      "/200 wins)"
    check total / 200.0 > 0.0

  test "16. probe and sweep are two different players":
    var differ = 0
    var plies = 0
    for config in variants():
      for seed in 0 ..< 50:
        var seeded = config
        seeded.seed = seed
        var sim = initSim(seeded)
        while not sim.done:
          let mover = sim.beginPly()
          let probe = scriptedDecision(sim, mover, blProbe)
          let sweep = scriptedDecision(sim, mover, blSweep)
          inc plies
          if probe.cell != sweep.cell or probe.anchor != sweep.anchor:
            inc differ
          if seeded.sense > 0:
            sim.applySense(mover, probe.anchor)
          sim.applyAttempt(mover, probe.cell, "", "", @[], true, false)
    echo "probe/sweep disagreement: ", differ, "/", plies, " = ",
      differ.float / plies.float
    check differ.float / plies.float >= 0.30

  test "17. the scripted certification fixture completes well inside 50 s":
    ## `coworld certify` defaults to --timeout-seconds 60 covering start,
    ## the connect grace, every ply and the post-game linger, so the
    ## fixture's own play time has to be a rounding error.
    var config = fixture(mDarkHex, 5, abrupt = true, maxPlies = 50, seed = 23)
    config.turnDelayMs = 0
    let started = getMonoTime()
    var sim = initSim(config)
    while not sim.done:
      let mover = sim.beginPly()
      let decision = scriptedDecision(sim, mover, blProbe)
      sim.applyAttempt(mover, decision.cell, "", "", @[], true, false)
    let elapsed = (getMonoTime() - started).inMilliseconds
    echo "cert fixture: ", sim.plies, " plies, ending ", sim.ending, ", ",
      elapsed, " ms"
    check sim.done
    check elapsed < 50_000

    ## And the replay it derives has to OUTLAST the viewer soak: a replay
    ## shorter than the soak window reads as frozen and fails the
    ## wasm-viewer job (ecos, 2026-08-23). ci.yml soaks for 10 s. The
    ## viewer dwells on the event on screen, so the playback length is the
    ## sum of the dwells of every event except the last.
    let dwell = replayDwell()
    var playback = dwell["other"]          ## the first step, nothing shown
    for index in 0 ..< sim.events.len - 1:
      let event = sim.events[index]
      playback += (
        case event.kind
        of evStart: dwell["start"]
        of evSense: dwell["sense"]
        of evAttempt:
          if event.outcome == "occupied": dwell["occupied"] else: dwell["placed"]
        of evWin: dwell["win"]
        of evEnd: dwell["end"])
    echo "cert replay playback: ", sim.events.len, " events, ", playback,
      " ms against a 10 s soak"
    check playback >= 13_000

suite "the ladder degrades, never hangs":
  test "with no credentials every seat is decided by the baseline at once":
    let config = fixture(mDarkHex, 5, seed = 5)
    let client = newLlmClient(config)
    ## No key in the test environment: the client disables itself once and
    ## every later decision is scripted immediately — no retries, no
    ## network waits. This is what makes offline certification complete.
    check client.disabled
    var sim = initSim(config)
    let mover = sim.beginPly()
    let decision = client.decide(sim, mover, "take the middle", blProbe,
      scripted = false)
    check decision.cell == scriptedDecision(sim, mover, blProbe).cell
    check not decision.fellBack
    let sweep = client.decide(sim, mover, "", blSweep, scripted = true)
    check sweep.cell == scriptedDecision(sim, mover, blSweep).cell

  test "a scripted seat name is parsed the way the player sends it":
    check parseBaseline("probe") == blProbe
    check parseBaseline("sweep") == blSweep
    check parseBaseline("SWEEP") == blSweep
    check parseBaseline("1") == blProbe
    check parseBaseline("true") == blProbe
    check parseBaseline("yes") == blProbe
    check parseBaseline("") == blProbe
    expect FogError:
      discard parseBaseline("mirror")
