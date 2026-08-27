## Pure game rules for Fog-of-War Boards. No IO, no networking, no LLM —
## the server, the tests and the wasm replay viewer all drive this same
## module, which is what makes a replay re-derivable in the browser.
##
## A `Sim` is one whole episode: the true board, each seat's PROVEN
## knowledge of the other, the perishable sensed-empty timestamps, the
## tallies, and the append-only event log. Everything random is drawn from
## the seed at `initSim`, so a replay re-derives the episode from the
## recorded sense / attempt events alone.

import std/[algorithm, deques, json, random, sequtils, sets, strutils, tables], types

export types

const
  ## Anonymous table aliases. Policy display names never reach a seat.
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ## "already lost": no route to the seat's own edges survives.
  Unreachable* = 99
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 120_000
  ## The eight lines of a 3x3 board, as (row, col) triples.
  TttLines* = [
    [(0, 0), (0, 1), (0, 2)],
    [(1, 0), (1, 1), (1, 2)],
    [(2, 0), (2, 1), (2, 2)],
    [(0, 0), (1, 0), (2, 0)],
    [(0, 1), (1, 1), (2, 1)],
    [(0, 2), (1, 2), (2, 2)],
    [(0, 0), (1, 1), (2, 2)],
    [(0, 2), (1, 1), (2, 0)]
  ]

type
  Sim* = object
    config*: GameConfig
    names*: seq[string]                 ## anonymous cog aliases
    board*: seq[Occupant]               ## size*size, row-major from rank 1
    known*: seq[HashSet[int]]           ## known[seat] = PROVEN opponent cells
    sensedEmptyAt*: seq[Table[int, int]] ## seat: cell -> ply last seen empty
    stones*, probes*, fallbacks*: array[Seats, int]
    guessesMade*, guessHits*: array[Seats, int]
    says*, notes*: seq[string]          ## latest, per seat
    lastGuess*: seq[seq[int]]           ## latest guess cells, per seat
    scripted*, fellBack*: array[Seats, bool]
    mover*: int
    ply*, plies*: int
    winner*: int                        ## -1 = none yet / draw
    winPath*: seq[int]
    done*: bool
    reason*, ending*: string
    events*: seq[GameEvent]

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the episode: the ply cap can never exceed two attempts per cell
  ## (one placement, one collision), which is the bound the rules prove.
  ## Idempotent: a replay carrying `sampled: true` is untouched.
  result = config
  if result.sampled:
    return
  let cells = config.size * config.size
  result.maxPlies = max(MinPlies, min(config.maxPlies, 2 * cells))
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.maxPlies, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, seat: -1)

proc cells*(sim: Sim): int =
  sim.config.size * sim.config.size

proc initSim*(config: GameConfig): Sim =
  config.validate()
  result = Sim(
    config: config,
    names: tableNames(config.players, config.seed),
    board: newSeq[Occupant](config.size * config.size),
    mover: config.first,
    winner: -1
  )
  for _ in 0 ..< Seats:
    result.known.add(initHashSet[int]())
    result.sensedEmptyAt.add(initTable[int, int]())
    result.says.add("")
    result.notes.add("")
    result.lastGuess.add(@[])
  result.addEvent(blankEvent(evStart))

# ---- Coordinates ------------------------------------------------------------

proc cellName*(sim: Sim, cell: int): string =
  ## Algebraic: file letter from the column, rank number from the row.
  if cell < 0 or cell >= sim.cells:
    raise newException(FogError, "cell out of range: " & $cell)
  let row = cell div sim.config.size
  let col = cell mod sim.config.size
  $chr(ord('a') + col) & $(row + 1)

proc cellIndex*(sim: Sim, name: string): int =
  ## The inverse of `cellName`; raises on anything off-board.
  let text = name.strip().toLowerAscii()
  if text.len < 2:
    raise newException(FogError, "not a cell name: " & name)
  let col = ord(text[0]) - ord('a')
  var row = -1
  try:
    row = parseInt(text[1 .. ^1]) - 1
  except ValueError:
    raise newException(FogError, "not a cell name: " & name)
  if col < 0 or col >= sim.config.size or row < 0 or row >= sim.config.size:
    raise newException(FogError, "cell is off the board: " & name)
  row * sim.config.size + col

proc rowOf*(sim: Sim, cell: int): int = cell div sim.config.size
proc colOf*(sim: Sim, cell: int): int = cell mod sim.config.size

proc neighbours*(sim: Sim, cell: int): seq[int] =
  ## The hex rhombus neighbourhood, or the 4-neighbourhood in phantom-ttt
  ## (unused there; kept so one board walker serves both modes).
  let n = sim.config.size
  let row = sim.rowOf(cell)
  let col = sim.colOf(cell)
  let steps =
    if sim.config.mode == mDarkHex:
      @[(0, -1), (0, 1), (-1, 0), (1, 0), (-1, 1), (1, -1)]
    else:
      @[(0, -1), (0, 1), (-1, 0), (1, 0)]
  for step in steps:
    let r = row + step[0]
    let c = col + step[1]
    if r >= 0 and r < n and c >= 0 and c < n:
      result.add(r * n + c)

# ---- Queries ----------------------------------------------------------------

proc occupantOf*(seat: int): Occupant =
  if seat == 0: ocSeat0 else: ocSeat1

proc ownsCell*(sim: Sim, seat, cell: int): bool =
  sim.board[cell] == occupantOf(seat)

proc legalAttempts*(sim: Sim, seat: int): seq[int] =
  ## Every on-board cell that is neither one of `seat`'s own stones nor a
  ## cell it has already PROVEN is the opponent's, ascending. The prompt,
  ## the retry hint and the validator all call this one proc, so they
  ## cannot drift.
  for cell in 0 ..< sim.cells:
    if sim.ownsCell(seat, cell):
      continue
    if cell in sim.known[seat]:
      continue
    result.add(cell)

proc legalAnchors*(sim: Sim, seat: int): seq[int] =
  ## The bottom-left corners of every sense window that fits on the board.
  ## Empty when reconnaissance is off.
  if sim.config.sense <= 0:
    return
  let n = sim.config.size
  let span = sim.config.sense
  for row in 0 .. n - span:
    for col in 0 .. n - span:
      result.add(row * n + col)

proc senseWindow*(sim: Sim, anchor: int): seq[int] =
  let n = sim.config.size
  let span = sim.config.sense
  let row = sim.rowOf(anchor)
  let col = sim.colOf(anchor)
  for i in 0 ..< span:
    for j in 0 ..< span:
      result.add((row + i) * n + col + j)

proc believedBoard*(sim: Sim, seat: int): seq[Occupant] =
  ## The seat's own stones plus the opponent stones it has PROVEN;
  ## everything else is empty. Every prompt number and every baseline
  ## decision is computed from this, never from `board`.
  result = newSeq[Occupant](sim.cells)
  let me = occupantOf(seat)
  let them = occupantOf(1 - seat)
  for cell in 0 ..< sim.cells:
    if sim.board[cell] == me:
      result[cell] = me
    elif cell in sim.known[seat]:
      result[cell] = them

proc distToWin*(sim: Sim, board: seq[Occupant], seat: int): int =
  ## Hex: a 0-1 BFS from the seat's source edge to its target edge where a
  ## cell it owns costs 0, an empty cell costs 1 and an opponent cell is
  ## impassable. Tic-tac-toe: the fewest marks still needed on any line
  ## the opponent has not touched. `Unreachable` (99) when no route is left.
  let n = sim.config.size
  let me = occupantOf(seat)
  let them = occupantOf(1 - seat)
  if sim.config.mode == mPhantomTtt:
    result = Unreachable
    for line in TttLines:
      var mine = 0
      var dead = false
      for (r, c) in line:
        let occupant = board[r * n + c]
        if occupant == them: dead = true
        elif occupant == me: inc mine
      if not dead:
        result = min(result, 3 - mine)
    return
  var dist = newSeq[int](n * n)
  for index in 0 ..< dist.len:
    dist[index] = Unreachable
  var queue = initDeque[int]()
  for index in 0 ..< n:
    let cell = if seat == 0: index * n else: index
    if board[cell] == them:
      continue
    let cost = if board[cell] == me: 0 else: 1
    if cost < dist[cell]:
      dist[cell] = cost
      if cost == 0: queue.addFirst(cell) else: queue.addLast(cell)
  while queue.len > 0:
    let cell = queue.popFirst()
    let onTarget =
      if seat == 0: sim.colOf(cell) == n - 1
      else: sim.rowOf(cell) == n - 1
    if onTarget:
      return dist[cell]
    for next in sim.neighbours(cell):
      if board[next] == them:
        continue
      let step = if board[next] == me: 0 else: 1
      if dist[cell] + step < dist[next]:
        dist[next] = dist[cell] + step
        if step == 0: queue.addFirst(next) else: queue.addLast(next)
  Unreachable

proc trueDistToWin*(sim: Sim, seat: int): int =
  sim.distToWin(sim.board, seat)

proc believedDistToWin*(sim: Sim, seat: int): int =
  sim.distToWin(sim.believedBoard(seat), seat)

proc winPathFor(sim: Sim, seat: int): seq[int] =
  ## The shortest chain of the seat's OWN stones linking its two edges, or
  ## an empty sequence when no such chain exists.
  let n = sim.config.size
  let me = occupantOf(seat)
  var previous = newSeq[int](n * n)
  for index in 0 ..< previous.len:
    previous[index] = -2
  var queue = initDeque[int]()
  for index in 0 ..< n:
    let cell = if seat == 0: index * n else: index
    if sim.board[cell] == me:
      previous[cell] = -1
      queue.addLast(cell)
  while queue.len > 0:
    let cell = queue.popFirst()
    let onTarget =
      if seat == 0: sim.colOf(cell) == n - 1
      else: sim.rowOf(cell) == n - 1
    if onTarget:
      var walk = cell
      while walk >= 0:
        result.add(walk)
        walk = previous[walk]
      result.reverse()
      return
    for next in sim.neighbours(cell):
      if sim.board[next] == me and previous[next] == -2:
        previous[next] = cell
        queue.addLast(next)
  @[]

proc tttLineFor(sim: Sim, seat, cell: int): seq[int] =
  ## The line the seat has just completed through `cell`, if any.
  let n = sim.config.size
  let me = occupantOf(seat)
  let row = sim.rowOf(cell)
  let col = sim.colOf(cell)
  for line in TttLines:
    var holds = false
    var complete = true
    for (r, c) in line:
      if r == row and c == col: holds = true
      if sim.board[r * n + c] != me: complete = false
    if holds and complete:
      for (r, c) in line:
        result.add(r * n + c)
      return
  @[]

proc score*(sim: Sim, seat: int): float =
  ## +1 / 0 / -1. The array sums to zero, always.
  if not sim.done or sim.winner < 0:
    return 0.0
  if sim.winner == seat: 1.0 else: -1.0

proc outcomeOf*(sim: Sim, seat: int): float =
  ## 1 / 0.5 / 0 — the same verdict on the league's usual scale.
  if not sim.done or sim.winner < 0: 0.5
  elif sim.winner == seat: 1.0
  else: 0.0

proc discovered*(sim: Sim, seat: int): int =
  sim.known[seat].len

proc guessAccuracy*(sim: Sim, seat: int): float =
  if sim.guessesMade[seat] == 0: 0.0
  else: sim.guessHits[seat].float / sim.guessesMade[seat].float

# ---- Play -------------------------------------------------------------------

proc settle*(sim: var Sim, reason, ending: string) =
  ## THE single proc that ends the game: it decides the winner from the
  ## ending table and logs `end`. Called on record AND on playback, so a
  ## wall-clock stop — which is not derivable from the attempts — re-derives
  ## identically in the wasm viewer.
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  case ending
  of "connection", "line":
    discard   ## the winner was set by the win check that called us
  else:
    let a = sim.trueDistToWin(0)
    let b = sim.trueDistToWin(1)
    sim.winner = if a < b: 0 elif b < a: 1 else: -1
  var event = blankEvent(evEnd)
  event.round = sim.plies
  event.reason = reason
  event.ending = ending
  event.scores = @[sim.score(0), sim.score(1)]
  sim.addEvent(event)

proc endEarly*(sim: var Sim) =
  ## The play deadline stopped the episode between plies. The episode is
  ## fully scored at the stop by the true distance, so this is a real
  ## result, not a discarded one.
  sim.settle("deadline", "wall-clock")

proc beginPly*(sim: var Sim): int =
  ## Step 1 of the resolution order: the mover of the ply about to open.
  if sim.done:
    raise newException(FogError, "the episode is over")
  sim.ply = sim.plies
  sim.mover

proc applySense*(sim: var Sim, seat, anchor: int) =
  ## Step 6: the referee truthfully reveals the sense x sense block at the
  ## anchor to the mover ONLY. Opponent stones become permanent knowledge;
  ## emptiness is timestamped, because it perishes.
  if sim.done:
    raise newException(FogError, "the episode is over")
  if sim.config.sense <= 0:
    raise newException(FogError, "this variant has no reconnaissance")
  if seat != sim.mover:
    raise newException(FogError, "seat " & $sim.mover & " is to move")
  if anchor notin sim.legalAnchors(seat):
    raise newException(FogError,
      "not a legal sense anchor: " & sim.cellName(anchor))
  let them = occupantOf(1 - seat)
  for cell in sim.senseWindow(anchor):
    if sim.board[cell] == them:
      sim.known[seat].incl(cell)
      sim.sensedEmptyAt[seat].del(cell)
    elif sim.board[cell] == ocEmpty:
      sim.sensedEmptyAt[seat][cell] = sim.plies
  var event = blankEvent(evSense)
  event.round = sim.plies
  event.seat = seat
  event.anchor = sim.cellName(anchor)
  sim.addEvent(event)

proc applyAttempt*(sim: var Sim, seat, cell: int, say, notes: string,
    guess: seq[int], scripted, fellBack: bool) =
  ## Steps 7-12 in one atomic step: place or collide, record, check the
  ## win, transfer the turn, check the full board, count the ply. Raises
  ## FogError naming the seat and the cell if the attempt is not in
  ## `legalAttempts(seat)`; the server probes with this on a COPY of the
  ## sim before committing, so an illegal model reply never mutates state.
  if sim.done:
    raise newException(FogError, "the episode is over")
  if seat != sim.mover:
    raise newException(FogError, "seat " & $sim.mover & " is to move")
  if cell < 0 or cell >= sim.cells:
    raise newException(FogError, "seat " & $seat & " named a cell off the board")
  if sim.ownsCell(seat, cell):
    raise newException(FogError,
      "seat " & $seat & " already holds " & sim.cellName(cell))
  if cell in sim.known[seat]:
    raise newException(FogError,
      "seat " & $seat & " has already proven " & sim.cellName(cell) &
        " is the opponent's")

  let them = occupantOf(1 - seat)
  var placed = false
  if sim.board[cell] == them:
    ## 7b: nothing is placed; the seat has bought one certainty.
    sim.known[seat].incl(cell)
    sim.sensedEmptyAt[seat].del(cell)
    inc sim.probes[seat]
  else:
    ## 7a: the cell was empty.
    sim.board[cell] = occupantOf(seat)
    inc sim.stones[seat]
    placed = true
    ## Only the MOVER's record is rewritten. The opponent was never told
    ## this cell was filled -- the only channel through which a seat
    ## learns anything about the other is the referee's answer to its own
    ## action -- so deleting its timestamp too would let a seat read the
    ## opponent's move straight out of its own sensed-empty list. It keeps
    ## the stale entry, which is what "may be stale" means in the prompt
    ## and what makes the belief board's dot fade rather than vanish.
    sim.sensedEmptyAt[seat].del(cell)

  ## Guesses are scored, never enforced: a wrong guess costs the seat
  ## nothing but its accuracy.
  sim.lastGuess[seat] = guess
  if guess.len > 0:
    for target in guess:
      inc sim.guessesMade[seat]
      if sim.board[target] == them:
        inc sim.guessHits[seat]
  sim.says[seat] = say
  if notes.len > 0:
    sim.notes[seat] = notes
  sim.scripted[seat] = scripted
  sim.fellBack[seat] = fellBack

  ## 8: record and emit.
  var event = blankEvent(evAttempt)
  event.round = sim.plies
  event.seat = seat
  event.cell = sim.cellName(cell)
  event.outcome = if placed: "placed" else: "occupied"
  event.say = say
  event.notes = notes
  for target in guess:
    event.guess.add(sim.cellName(target))
  event.scripted = scripted
  event.fellBack = fellBack
  sim.addEvent(event)

  ## 9: win check, only after a placement.
  var won = false
  if placed:
    if sim.config.mode == mDarkHex:
      let path = sim.winPathFor(seat)
      if path.len > 0:
        won = true
        sim.winner = seat
        sim.winPath = path
        var winEvent = blankEvent(evWin)
        winEvent.round = sim.plies
        winEvent.seat = seat
        winEvent.how = "connection"
        for step in path:
          winEvent.path.add(sim.cellName(step))
        sim.addEvent(winEvent)
        sim.settle("complete", "connection")
    else:
      let line = sim.tttLineFor(seat, cell)
      if line.len > 0:
        won = true
        sim.winner = seat
        sim.winPath = line
        var winEvent = blankEvent(evWin)
        winEvent.round = sim.plies
        winEvent.seat = seat
        winEvent.how = "line"
        for step in line:
          winEvent.path.add(sim.cellName(step))
        sim.addEvent(winEvent)
        sim.settle("complete", "line")

  ## 10: turn transfer. A placement always flips; a collision flips only
  ## in the abrupt variants.
  if placed or sim.config.abrupt:
    sim.mover = 1 - seat

  ## 11: a filled tic-tac-toe board with no line is a draw.
  if not won and placed and sim.config.mode == mPhantomTtt:
    var full = true
    for index in 0 ..< sim.cells:
      if sim.board[index] == ocEmpty:
        full = false
        break
    if full:
      sim.settle("complete", "board-full")

  ## 12: count the ply and check the cap.
  inc sim.plies
  sim.ply = sim.plies
  if not sim.done and sim.plies >= sim.config.maxPlies:
    sim.settle("complete", "ply-cap")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var outcome = newJArray()
  var stones = newJArray()
  var probes = newJArray()
  var discovered = newJArray()
  var guessesMade = newJArray()
  var guessAccuracy = newJArray()
  var distances = newJArray()
  var fallbacks = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    outcome.add(%sim.outcomeOf(seat))
    stones.add(%sim.stones[seat])
    probes.add(%sim.probes[seat])
    discovered.add(%sim.discovered(seat))
    guessesMade.add(%sim.guessesMade[seat])
    guessAccuracy.add(%sim.guessAccuracy(seat))
    distances.add(%sim.trueDistToWin(seat))
    fallbacks.add(%sim.fallbacks[seat])
  %*{
    "names": names,
    "scores": scores,
    "outcome": outcome,
    "stones": stones,
    "probes": probes,
    "discovered": discovered,
    "guessesMade": guessesMade,
    "guessAccuracy": guessAccuracy,
    "distToWin": distances,
    "fallbacks": fallbacks,
    "plies": sim.plies,
    "maxPlies": sim.config.maxPlies,
    "mode": $sim.config.mode,
    "size": sim.config.size,
    "abrupt": sim.config.abrupt,
    "sense": sim.config.sense,
    "ending": sim.ending,
    "reason": sim.reason
  }

# ---- Viewer state -----------------------------------------------------------

proc phaseText*(sim: Sim): string =
  if sim.done: "done"
  elif sim.config.sense > 0: "sensing"
  else: "moving"

proc boardStateJson*(sim: Sim): JsonNode =
  var board = newJArray()
  for occupant in sim.board:
    board.add(%($occupant))
  var seats = newJArray()
  for seat in 0 ..< Seats:
    var known = newJArray()
    for cell in sorted(toSeq(sim.known[seat])):
      known.add(%sim.cellName(cell))
    var sensed = newJArray()
    var stale: seq[(int, int)]
    for cell, ply in sim.sensedEmptyAt[seat]:
      stale.add((cell, ply))
    stale.sort(proc (a, b: (int, int)): int = cmp(a[0], b[0]))
    for (cell, ply) in stale:
      sensed.add(%*{"cell": sim.cellName(cell), "ply": ply})
    var guess = newJArray()
    for cell in sim.lastGuess[seat]:
      guess.add(%sim.cellName(cell))
    seats.add(%*{
      "name": sim.names[seat],
      "policy": (
        if seat < sim.config.players.len: sim.config.players[seat].name
        else: sim.names[seat]),
      "stones": sim.stones[seat],
      "probes": sim.probes[seat],
      "discovered": sim.discovered(seat),
      "distToWin": sim.trueDistToWin(seat),
      "score": sim.score(seat),
      "known": known,
      "sensedEmpty": sensed,
      "guess": guess,
      "say": sim.says[seat],
      "notes": sim.notes[seat],
      "scripted": sim.scripted[seat],
      "fellBack": sim.fellBack[seat]
    })
  var lastAttempt = newJNull()
  var lastSense = newJNull()
  for index in countdown(sim.events.high, 0):
    let event = sim.events[index]
    if event.kind == evAttempt and lastAttempt.kind == JNull:
      lastAttempt = %*{
        "seat": event.seat, "cell": event.cell, "result": event.outcome}
    if event.kind == evSense and lastSense.kind == JNull:
      lastSense = %*{"seat": event.seat, "anchor": event.anchor}
  var winPath = newJArray()
  for cell in sim.winPath:
    winPath.add(%sim.cellName(cell))
  %*{
    "mode": $sim.config.mode,
    "size": sim.config.size,
    "abrupt": sim.config.abrupt,
    "sense": sim.config.sense,
    "board": board,
    "seats": seats,
    "mover": sim.mover,
    "ply": sim.ply,
    "maxPlies": sim.config.maxPlies,
    "plies": sim.plies,
    "lastAttempt": lastAttempt,
    "lastSense": lastSense,
    "winner": sim.winner,
    "winPath": winPath,
    "phase": sim.phaseText(),
    "gameDone": sim.done,
    "reason": sim.reason,
    "ending": sim.ending
  }

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  ## `round` is written for EVERY event, including the opening one, whose
  ## value is -1: design.md:594 gives `start` as {kind, round: -1}, and a
  ## key that is present-but-negative is what `eventFromJson` and the
  ## chrome already read (both treat a round below 0 as "no ply").
  result = %*{"kind": $event.kind, "round": event.round}
  case event.kind
  of evStart:
    discard
  of evSense:
    result["seat"] = %event.seat
    result["anchor"] = %event.anchor
  of evAttempt:
    result["seat"] = %event.seat
    result["cell"] = %event.cell
    result["result"] = %event.outcome
    result["say"] = %event.say
    result["notes"] = %event.notes
    var guess = newJArray()
    for cell in event.guess:
      guess.add(%cell)
    result["guess"] = guess
    result["scripted"] = %event.scripted
    result["fellBack"] = %event.fellBack
  of evWin:
    result["seat"] = %event.seat
    result["how"] = %event.how
    var path = newJArray()
    for cell in event.path:
      path.add(%cell)
    result["path"] = path
  of evEnd:
    result["reason"] = %event.reason
    result["ending"] = %event.ending
    var scores = newJArray()
    for value in event.scores:
      scores.add(%value)
    result["scores"] = scores

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    anchor: node{"anchor"}.getStr(""),
    cell: node{"cell"}.getStr(""),
    outcome: node{"result"}.getStr(""),
    say: node{"say"}.getStr(""),
    notes: node{"notes"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    fellBack: node{"fellBack"}.getBool(false),
    how: node{"how"}.getStr(""),
    reason: node{"reason"}.getStr(""),
    ending: node{"ending"}.getStr("")
  )
  if node.hasKey("guess"):
    for cell in node["guess"]:
      result.guess.add(cell.getStr())
  if node.hasKey("path"):
    for cell in node["path"]:
      result.path.add(cell.getStr())
  if node.hasKey("scores"):
    for value in node["scores"]:
      result.scores.add(value.getFloat())

# ---- Replay bytes -----------------------------------------------------------

proc replayPayloadJson*(sim: Sim, results: JsonNode): JsonNode =
  ## Self-sufficient replay bytes: names, policy names, the whole config,
  ## the seed, the ply cap, every event and the results. The viewer
  ## re-derives every frame in the browser and contacts nothing but S3 for
  ## this file. Built here, in the pure module, so the tests exercise the
  ## same writer the server ships.
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policyNames = newJArray()
  for player in sim.config.players:
    policyNames.add(%player.name)
  var events = newJArray()
  for event in sim.events:
    events.add(event.eventToJson())
  %*{
    "protocol": "fogboards.replay.v1",
    "names": names,
    "policyNames": policyNames,
    "config": {
      "mode": $sim.config.mode,
      "size": sim.config.size,
      "abrupt": sim.config.abrupt,
      "sense": sim.config.sense,
      "first": sim.config.first,
      "seed": sim.config.seed,
      "maxPlies": sim.config.maxPlies,
      "sampled": true
    },
    "events": events,
    "results": results
  }

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the sense (anchor) and attempt (cell) events through the rules and
  ## applying the end event's reason/ending through the SAME `settle`.
  ## frames[i] = state after events[0..<i]. `result` on an attempt, and
  ## seat/how/path on a win, are re-derived and CHECKED against the
  ## recording: a replay that disagrees with the rules raises here rather
  ## than drawing a lie.
  var sim = initSim(config)
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evSense:
      sim.applySense(event.seat, sim.cellIndex(event.anchor))
    of evAttempt:
      var guess: seq[int]
      for name in event.guess:
        guess.add(sim.cellIndex(name))
      let seat = sim.mover
      if event.seat >= 0 and event.seat != seat:
        raise newException(FogError,
          "ply " & $event.round & ": seat " & $event.seat &
            " attempted out of turn")
      sim.applyAttempt(seat, sim.cellIndex(event.cell), event.say,
        event.notes, guess, event.scripted, event.fellBack)
      var derived = ""
      for index in countdown(sim.events.high, 0):
        if sim.events[index].kind == evAttempt:
          derived = sim.events[index].outcome
          break
      if event.outcome.len > 0 and derived != event.outcome:
        raise newException(FogError,
          "ply " & $event.round & ": recorded " & event.outcome &
            " but the rules derive " & derived)
    of evWin:
      var found = false
      for index in countdown(sim.events.high, 0):
        if sim.events[index].kind == evWin:
          let derived = sim.events[index]
          if derived.seat != event.seat or derived.how != event.how or
              derived.path != event.path:
            raise newException(FogError,
              "ply " & $event.round & ": the recorded win does not match " &
                "the re-derived one")
          found = true
          break
      if not found:
        raise newException(FogError,
          "ply " & $event.round & ": a win was recorded that the rules " &
            "do not derive")
    of evEnd:
      if not sim.done:
        ## A wall-clock stop is not derivable from the attempts alone, so
        ## it rides in the recording and is applied by the same proc.
        sim.settle(event.reason, event.ending)
      elif sim.reason != event.reason or sim.ending != event.ending:
        raise newException(FogError,
          "recorded end " & event.reason & "/" & event.ending &
            " but the rules derive " & sim.reason & "/" & sim.ending)
    result.add(sim)
