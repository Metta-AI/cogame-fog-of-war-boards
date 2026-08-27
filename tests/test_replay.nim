## Record -> re-derive, and the bytes themselves.
##
## The wasm replay viewer runs THIS sim module over the recorded events and
## must land on exactly the states the server broadcast — including for a
## wall-clock stop, which is not derivable from the attempts and therefore
## rides in the recording and is applied by the same `settle` on both
## paths (particle-worlds 13c66d7, 2026-08-26).

import std/[json, sets, strutils, unicode, unittest]
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

type Recording = object
  sim: Sim
  states: seq[string]     ## states[i] = the live state after events[0..<i]

proc topUp(rec: var Recording) =
  while rec.states.len < rec.sim.events.len + 1:
    rec.states.add($rec.sim.boardStateJson())

proc start(config: GameConfig): Recording =
  result.sim = initSim(config)
  result.states = @[$result.sim.boardStateJson()]
  result.topUp()

proc playOut(rec: var Recording, baseline = blProbe) =
  while not rec.sim.done:
    let mover = rec.sim.beginPly()
    let decision = scriptedDecision(rec.sim, mover, baseline)
    if rec.sim.config.sense > 0:
      rec.sim.applySense(mover, decision.anchor)
      rec.topUp()
    rec.sim.applyAttempt(mover, decision.cell,
      "route " & rec.sim.cellName(decision.cell),
      "proven so far: " & $rec.sim.known[mover].len, @[], true, false)
    rec.topUp()

proc move(rec: var Recording, name: string) =
  let mover = rec.sim.beginPly()
  rec.sim.applyAttempt(mover, rec.sim.cellIndex(name), "", "", @[], true,
    false)
  rec.topUp()

proc roundTrip(events: seq[GameEvent]): seq[GameEvent] =
  ## Through the wire, exactly as the wasm viewer reads them.
  for event in events:
    result.add(eventFromJson(event.eventToJson()))

proc recordings(): seq[(string, Recording)] =
  ## One recording per reason/ending pair.
  var connection = start(fixture(mDarkHex, 5, seed = 3))
  connection.playOut()
  result.add(("complete/connection", connection))

  var line = start(fixture(mPhantomTtt, 3, false, 0, 18))
  for name in ["a3", "a1", "b3", "b1", "c3"]:
    line.move(name)
  result.add(("complete/line", line))

  var full = start(fixture(mPhantomTtt, 3, false, 0, 18))
  for name in ["a3", "b3", "c3", "b2", "a2", "c2", "b1", "a1", "c1"]:
    full.move(name)
  result.add(("complete/board-full", full))

  var capped = start(fixture(mDarkHex, 5, maxPlies = 4))
  for name in ["a1", "b1", "a2", "b2"]:
    capped.move(name)
  result.add(("complete/ply-cap", capped))

  var stopped = start(fixture(mDarkHex, 5, sense = 2, seed = 9))
  for _ in 0 .. 3:
    let mover = stopped.sim.beginPly()
    let decision = scriptedDecision(stopped.sim, mover, blSweep)
    stopped.sim.applySense(mover, decision.anchor)
    stopped.topUp()
    stopped.sim.applyAttempt(mover, decision.cell, "", "", @[], true, false)
    stopped.topUp()
  stopped.sim.endEarly()
  stopped.topUp()
  result.add(("deadline/wall-clock", stopped))

suite "record then re-derive":
  test "18. every ending re-derives frame for frame":
    for (label, rec) in recordings():
      check rec.sim.done
      check label == rec.sim.reason & "/" & rec.sim.ending
      let events = roundTrip(rec.sim.events)
      let frames = replayMatch(rec.sim.config, events)
      check frames.len == events.len + 1
      check frames.len == rec.states.len
      for index in 0 ..< frames.len:
        check $frames[index].boardStateJson() == rec.states[index]
      check frames[^1].done
      check frames[^1].reason == rec.sim.reason
      check frames[^1].ending == rec.sim.ending
      check frames[^1].winner == rec.sim.winner
      check $frames[^1].resultsJson() == $rec.sim.resultsJson()

  test "19. a recording that disagrees with the rules raises":
    var rec = start(fixture(mDarkHex, 5, seed = 3))
    rec.playOut()
    let events = roundTrip(rec.sim.events)
    ## The honest log replays.
    discard replayMatch(rec.sim.config, events)

    ## A flipped attempt result.
    var flipped = events
    for index in 0 ..< flipped.len:
      if flipped[index].kind == evAttempt and flipped[index].outcome == "placed":
        flipped[index].outcome = "occupied"
        break
    expect FogError:
      discard replayMatch(rec.sim.config, flipped)

    ## A win credited to the wrong seat.
    var stolen = events
    for index in 0 ..< stolen.len:
      if stolen[index].kind == evWin:
        stolen[index].seat = 1 - stolen[index].seat
        break
    expect FogError:
      discard replayMatch(rec.sim.config, stolen)

    ## A win with the wrong shape.
    var mislabelled = events
    for index in 0 ..< mislabelled.len:
      if mislabelled[index].kind == evWin:
        mislabelled[index].how = "line"
        break
    expect FogError:
      discard replayMatch(rec.sim.config, mislabelled)

    ## A win with a path that is not the one the rules derive.
    var rerouted = events
    for index in 0 ..< rerouted.len:
      if rerouted[index].kind == evWin:
        rerouted[index].path.add("a1")
        break
    expect FogError:
      discard replayMatch(rec.sim.config, rerouted)

    ## A cell played out of turn.
    var jumped = events
    for index in 0 ..< jumped.len:
      if jumped[index].kind == evAttempt:
        jumped[index].seat = 1 - jumped[index].seat
        break
    expect FogError:
      discard replayMatch(rec.sim.config, jumped)

suite "the bytes":
  test "20. multi-byte text at exactly the cap stays strict UTF-8":
    ## A byte-boundary cut renders in a browser and fails a strict JSON
    ## parser, which is exactly how a replay becomes unreadable.
    var wide = ""
    for _ in 0 ..< 400:
      wide.add("日")
    wide.add("🜁")
    let say = cleanText(wide, MaxSayLen)
    let notes = cleanText(wide, MaxNotesLen)
    check say.runeLen == MaxSayLen
    check notes.runeLen == MaxNotesLen
    check say.validateUtf8() == -1
    check notes.validateUtf8() == -1
    check say.endsWith("…")
    ## An emoji sitting exactly ON the cap survives whole.
    var edge = ""
    for _ in 0 ..< MaxSayLen - 1:
      edge.add("日")
    edge.add("🜁")
    check edge.runeLen == MaxSayLen
    check cleanText(edge, MaxSayLen) == edge

    var rec = start(fixture(mDarkHex, 5, seed = 11))
    while not rec.sim.done:
      let mover = rec.sim.beginPly()
      let decision = scriptedDecision(rec.sim, mover, blProbe)
      rec.sim.applyAttempt(mover, decision.cell, say, notes,
        @[decision.cell], true, false)
      rec.topUp()
    let bytes = $rec.sim.replayPayloadJson(rec.sim.resultsJson())
    check bytes.validateUtf8() == -1
    let parsed = parseJson(bytes)
    check parsed["events"].len == rec.sim.events.len
    for event in parsed["events"]:
      if event["kind"].getStr() == "attempt":
        check event["say"].getStr() == say
        check event["notes"].getStr() == notes
        check event["say"].getStr().runeLen == MaxSayLen
    ## And it survives the round trip the viewer makes.
    var back: seq[GameEvent]
    for node in parsed["events"]:
      back.add(eventFromJson(node))
    let frames = replayMatch(rec.sim.config, back)
    check $frames[^1].boardStateJson() == rec.states[^1]

  test "21. the replay payload carries everything the viewer needs":
    var rec = start(fixture(mDarkHex, 5, sense = 2, seed = 4))
    rec.playOut(blSweep)
    let payload = rec.sim.replayPayloadJson(rec.sim.resultsJson())
    for key in ["protocol", "names", "policyNames", "config", "events",
        "results"]:
      check payload.hasKey(key)
    check payload["protocol"].getStr() == "fogboards.replay.v1"
    check payload["names"].len == Seats
    check payload["policyNames"].len == Seats
    check payload["policyNames"][0].getStr() == "P1"
    for key in ["mode", "size", "abrupt", "sense", "first", "seed",
        "maxPlies", "sampled"]:
      check payload["config"].hasKey(key)
    check payload["config"]["mode"].getStr() == "dark-hex"
    check payload["config"]["size"].getInt() == 5
    check payload["config"]["abrupt"].getBool()
    check payload["config"]["sense"].getInt() == 2
    check payload["config"]["first"].getInt() == 0
    check payload["config"]["seed"].getInt() == 4
    check payload["config"]["maxPlies"].getInt() == 50
    check payload["events"].len == rec.sim.events.len
    check payload["events"][0]["kind"].getStr() == "start"
    check payload["events"][^1]["kind"].getStr() == "end"
    check payload["events"][^1]["reason"].getStr() == "complete"
    check payload["events"][^1]["ending"].getStr() == "connection"
    ## Cells ride as algebraic strings, never as internal indices.
    for event in payload["events"]:
      case event["kind"].getStr()
      of "attempt":
        check event["cell"].getStr().len >= 2
        check event["cell"].getStr()[0] in {'a' .. 'z'}
        check event["result"].getStr() in ["placed", "occupied"]
      of "sense":
        check event["anchor"].getStr()[0] in {'a' .. 'z'}
      of "win":
        for cell in event["path"]:
          check cell.getStr()[0] in {'a' .. 'z'}
      else: discard
    for key in ["names", "scores", "outcome", "stones", "probes",
        "discovered", "guessesMade", "guessAccuracy", "distToWin",
        "fallbacks", "plies", "maxPlies", "mode", "size", "abrupt", "sense",
        "ending", "reason"]:
      check payload["results"].hasKey(key)
    ## The config alone reconstructs the episode the viewer replays.
    var events: seq[GameEvent]
    for node in payload["events"]:
      events.add(eventFromJson(node))
    var config = defaultGameConfig()
    config.mode = mDarkHex
    config.size = payload["config"]["size"].getInt()
    config.abrupt = payload["config"]["abrupt"].getBool()
    config.sense = payload["config"]["sense"].getInt()
    config.first = payload["config"]["first"].getInt()
    config.seed = payload["config"]["seed"].getInt()
    config.maxPlies = payload["config"]["maxPlies"].getInt()
    config.sampled = true
    for name in payload["names"]:
      config.players.add(PlayerConfig(name: name.getStr()))
    let frames = replayMatch(config, events)
    check frames.len == events.len + 1
    check frames[^1].done
