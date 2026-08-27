## Claude-backed decision making for Fog-of-War Boards, plus the two
## scripted baselines.
##
## A policy is just a prompt: the game server composes the acting seat's
## view (its own stones, the opponent stones it has PROVEN, its referee
## log, its notes) and sends it to Claude with that seat's prompt. The
## seat never sees the true board, and neither does this module's prompt
## builder — every number in a prompt comes from `believedBoard`.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## `probe` baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing.

import
  std/[json, os, sets, strutils, tables, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## Caps, in RUNES. Every one of them is cut on a rune boundary by
  ## `cleanText`: a byte-boundary cut renders in a browser and fails a
  ## strict JSON parser, which is exactly how a replay becomes unreadable.
  MaxSayLen* = 80
  MaxNotesLen* = 400
  MaxGuessCells* = 6
  MaxGuessLen* = 4
  MaxErrorLen* = 200
  ## The Bedrock sidecar caps 30 requests per minute per episode; a ply
  ## issues at most two (the call plus one retry), so LLM-driven plies may
  ## start no closer together than this.
  DerivedPlySpacingSeconds* = 4
  ## A ply's worst case: two calls at the timeout, plus apply/broadcast.
  ## Step 2 of the resolution order refuses to open a ply that cannot fit.
  PlyGuardSlackSeconds* = 2
  ## The staleness after which `probe` treats a sensed-empty cell as worth
  ## looking at again.
  StaleAfterPlies* = 4
  ## Tic-tac-toe opening order: centre, corners, edges.
  TttPriority* = ["b2", "a1", "c1", "a3", "c3", "b1", "a2", "c2", "b3"]

type
  Decision* = object
    cell*: int          ## the attempted cell
    anchor*: int        ## the sense anchor, or -1
    say*: string        ## spectator-facing, one line
    notes*: string      ## private, fed back to its author only
    guess*: seq[int]    ## cells this seat believes are the opponent's
    scripted*: bool     ## a scripted baseline decided this ply
    fellBack*: bool     ## an LLM seat whose reply could not be used

  Baseline* = enum
    blProbe = "probe"
    blSweep = "sweep"

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool     ## true once credentials are known-unavailable

proc parseBaseline*(text: string): Baseline =
  ## `1`, `true` and `yes` are accepted synonyms for `probe`.
  case text.strip().toLowerAscii()
  of "sweep": blSweep
  of "probe", "1", "true", "yes", "": blProbe
  else:
    raise newException(FogError, "unknown scripted baseline: " & text)

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "fogboards llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id. Haiku leads: hosted Bedrock capacity is shared
  ## account-wide and the sonnet profiles run out of daily tokens first.
  ## `us.anthropic.claude-sonnet-4-6` is deliberately NOT a candidate: it
  ## times out on every sidecar call, and one throttle then cascades into
  ## scripted fallbacks for the rest of the episode (raid, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "fogboards llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "fogboards llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "fogboards llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "fogboards llm: no LLM credentials; using scripted fallback"

# ---- Text hygiene -----------------------------------------------------------

proc cleanText*(text: string, cap: int): string =
  ## One shared truncator for every string that can reach an event, a
  ## prompt or the log. Cuts on a RUNE boundary with the cut marked.
  result = text.strip()
  if result.runeLen <= cap:
    return
  result = result.runeSubStr(0, cap - 1) & "…"

proc oneLine*(text: string): string =
  ## `say` is drawn on one line in a reserved band, so newlines become
  ## spaces before the cap is applied.
  text.replace("\r\n", " ").replace("\n", " ").replace("\r", " ")
    .replace("\t", " ")

# ---- The scripted baselines -------------------------------------------------

proc cellList(sim: Sim, cells: seq[int]): string =
  var parts: seq[string]
  for cell in cells:
    parts.add(sim.cellName(cell))
  if parts.len == 0: "(none)" else: parts.join(" ")

proc isUnknown(sim: Sim, seat, cell: int): bool =
  not sim.ownsCell(seat, cell) and cell notin sim.known[seat] and
    cell notin sim.sensedEmptyAt[seat]

proc probeAnchor*(sim: Sim, seat: int): int =
  ## Point the window where the seat knows least: unknown cells score, and
  ## a cell last seen empty long enough ago scores again.
  let anchors = sim.legalAnchors(seat)
  if anchors.len == 0:
    return -1
  var best = -1
  var bestScore = -1
  for anchor in anchors:
    var score = 0
    for cell in sim.senseWindow(anchor):
      if sim.isUnknown(seat, cell):
        inc score
      elif cell in sim.sensedEmptyAt[seat] and
          sim.plies - sim.sensedEmptyAt[seat][cell] >= StaleAfterPlies:
        inc score
    if score > bestScore:
      bestScore = score
      best = anchor
  best

proc sweepAnchor*(sim: Sim, seat: int): int =
  ## Round-robin, row-major, one per ply, wrapping.
  let anchors = sim.legalAnchors(seat)
  if anchors.len == 0:
    return -1
  anchors[sim.plies mod anchors.len]

proc centreDistance(sim: Sim, cell: int): int =
  ## Chebyshev distance from the board centre, doubled so an even board
  ## has no fractional centre.
  let n = sim.config.size
  max(abs(2 * sim.rowOf(cell) - (n - 1)), abs(2 * sim.colOf(cell) - (n - 1)))

proc probeCell*(sim: Sim, seat: int): int =
  ## Dark Hex: the legal attempt that shortens the seat's own chain most on
  ## the board as it BELIEVES it to be — which probes the opponent as a
  ## side effect, because the cells on a shortest path are exactly the ones
  ## the opponent wants. Tic-tac-toe: win, else block a proven double, else
  ## the fixed priority order.
  let legal = sim.legalAttempts(seat)
  if legal.len == 0:
    raise newException(FogError, "seat " & $seat & " has no legal attempt")
  var believed = sim.believedBoard(seat)
  let me = occupantOf(seat)
  let them = occupantOf(1 - seat)
  if sim.config.mode == mPhantomTtt:
    ## 1. take the win.
    for cell in legal:
      believed[cell] = me
      let distance = sim.distToWin(believed, seat)
      believed[cell] = ocEmpty   ## a legal attempt is empty on the belief
      if distance == 0:
        return cell
    ## 2. block a line where the opponent already has two PROVEN marks.
    for line in TttLines:
      var theirs = 0
      var mine = 0
      var empty = -1
      for (r, c) in line:
        let cell = r * sim.config.size + c
        if believed[cell] == them: inc theirs
        elif believed[cell] == me: inc mine
        else: empty = cell
      if theirs == 2 and mine == 0 and empty >= 0 and empty in legal:
        return empty
    ## 3. centre, corners, edges.
    for name in TttPriority:
      let cell = sim.cellIndex(name)
      if cell in legal:
        return cell
    return legal[0]
  var best = legal[0]
  var bestDistance = high(int)
  var bestCentre = high(int)
  for cell in legal:
    let restore = believed[cell]
    believed[cell] = me
    let distance = sim.distToWin(believed, seat)
    believed[cell] = restore
    let centre = sim.centreDistance(cell)
    if distance < bestDistance or
        (distance == bestDistance and centre < bestCentre):
      bestDistance = distance
      bestCentre = centre
      best = cell
  best

proc sweepCell*(sim: Sim, seat: int): int =
  ## A straight corridor across the board, shifted one step every time it
  ## runs into a stone. Deliberately a different shape from `probe`: two
  ## fillers that play the same game are one filler.
  let legal = sim.legalAttempts(seat)
  if legal.len == 0:
    raise newException(FogError, "seat " & $seat & " has no legal attempt")
  if sim.config.mode == mPhantomTtt:
    for name in TttPriority:
      let cell = sim.cellIndex(name)
      if cell in legal:
        return cell
    return legal[0]
  let n = sim.config.size
  ## Every collision this seat caused shifted the corridor one step.
  let shift = sim.probes[seat]
  let lane = (n div 2 + shift) mod n
  for offset in 0 ..< n:
    let cell =
      if seat == 0: lane * n + offset
      else: offset * n + lane
    if cell in legal:
      return cell
  legal[0]

proc scriptedDecision*(sim: Sim, seat: int, baseline: Baseline): Decision =
  ## Always legal, deterministic, and blind: it reads the seat's believed
  ## board and its own knowledge sets, never `sim.board`. Never produces
  ## `say`, `notes` or `guess`.
  ##
  ## Where the variant has reconnaissance the cell is chosen on a COPY
  ## that already carries this ply's window: the referee answers the sense
  ## before the attempt is applied, so a cell the window has just proven is
  ## the opponent's is no longer a legal attempt this ply.
  result.anchor =
    if sim.config.sense <= 0: -1
    elif baseline == blProbe: sim.probeAnchor(seat)
    else: sim.sweepAnchor(seat)
  var after = sim
  if sim.config.sense > 0 and result.anchor >= 0:
    after.applySense(seat, result.anchor)
  result.cell =
    if baseline == blProbe: after.probeCell(seat)
    else: after.sweepCell(seat)
  result.scripted = true

# ---- Prompt building --------------------------------------------------------

proc goalText(sim: Sim, seat: int): string =
  let n = sim.config.size
  let lastFile = $chr(ord('a') + n - 1)
  if sim.config.mode == mPhantomTtt:
    return "YOUR GOAL: own all three cells of one row, column or diagonal " &
      "before your opponent does."
  var touches: seq[string]
  let sampleCell = 2 * n + 2                         ## c3 on any board >= 3
  for neighbour in sim.neighbours(sampleCell):
    touches.add(sim.cellName(neighbour))
  if seat == 0:
    "YOUR GOAL: link the left file (a) to the right file (" & lastFile &
      ") with an unbroken chain of your own stones. Cells touch on six " &
      "sides: c3 touches " & touches.join(", ") & "."
  else:
    "YOUR GOAL: link the bottom rank (1) to the top rank (" & $n &
      ") with an unbroken chain of your own stones. Cells touch on six " &
      "sides: c3 touches " & touches.join(", ") & "."

proc refereeLog*(sim: Sim, seat: int): string =
  ## Everything this seat has ever been told, and nothing else. The window
  ## contents are re-derived from the board as it stood at that ply, by
  ## walking the recorded attempts — the same derivation the viewer makes.
  var board = newSeq[Occupant](sim.cells)
  var lines: seq[string]
  let me = occupantOf(seat)
  let them = occupantOf(1 - seat)
  for event in sim.events:
    case event.kind
    of evSense:
      if event.seat == seat:
        var parts: seq[string]
        let anchor = sim.cellIndex(event.anchor)
        for cell in sim.senseWindow(anchor):
          let name = sim.cellName(cell)
          if board[cell] == them: parts.add(name & " OPPONENT")
          elif board[cell] == me: parts.add(name & " yours")
          else: parts.add(name & " empty")
        lines.add("ply " & $(event.round + 1) & " — you sensed " &
          event.anchor & " — " & parts.join(", ") & ".")
    of evAttempt:
      if event.seat == seat:
        if event.outcome == "placed":
          lines.add("ply " & $(event.round + 1) & " — you played " &
            event.cell & " — PLACED.")
        else:
          lines.add("ply " & $(event.round + 1) & " — you played " &
            event.cell & " — OCCUPIED: an opponent stone is there.")
      if event.outcome == "placed":
        board[sim.cellIndex(event.cell)] = occupantOf(event.seat)
    else:
      discard
  if lines.len == 0:
    return "(nothing yet — this is your first action)"
  lines.join("\n")

proc systemPrompt*(sim: Sim, seat: int): string =
  ## One system prompt per mode, identical for both seats: the rules
  ## verbatim, the seat's alias, and the output contract. Bedrock Haiku
  ## answers prose-first without the last paragraph.
  let n = sim.config.size
  let lastFile = $chr(ord('a') + n - 1)
  result.add("You are " & sim.names[seat] & ", a cog playing " &
    "Fog-of-War Boards against " & sim.names[1 - seat] & ".\n\nRules:\n")
  if sim.config.mode == mPhantomTtt:
    result.add("- The board is a 3x3 grid. Files a, b, c run left to " &
      "right; ranks 1, 2, 3 run bottom to top, so the cells are a1..c3.\n")
    result.add("- You win by owning all three cells of one of the eight " &
      "lines (three rows, three columns, two diagonals). A full board " &
      "with no line is a draw.\n")
  else:
    result.add("- The board is an " & $n & "x" & $n & " rhombus of " &
      "hexagons. Files a.." & lastFile & " run left to right; ranks 1.." &
      $n & " run bottom to top.\n")
    result.add("- Every cell touches SIX others: the cell to its left and " &
      "the cell to its right, the cell directly below and the cell " &
      "directly above, the cell down-and-right, and the cell up-and-left. " &
      "On this board c3 touches " & sim.cellList(sim.neighbours(2 * n + 2)) &
      ".\n")
    result.add("- RED (seat 0) wins by linking the left file (a) to the " &
      "right file (" & lastFile & ") with an unbroken chain of its own " &
      "stones. BLUE (seat 1) wins by linking the bottom rank (1) to the " &
      "top rank (" & $n & "). A full board always has exactly one " &
      "winner: there are no draws.\n")
  result.add("- THE FOG: you see only your OWN stones. You are never told " &
    "anything about your opponent's moves. The only way you ever learn " &
    "where an opponent stone is, is by naming that cell yourself and " &
    "being told OCCUPIED.\n")
  if sim.config.abrupt:
    result.add("- A ply that names a cell already holding an opponent " &
      "stone places NOTHING and ENDS YOUR TURN. You have spent your move " &
      "to buy one certainty.\n")
  else:
    result.add("- A ply that names a cell already holding an opponent " &
      "stone places NOTHING, but does NOT end your turn: you move again " &
      "immediately, now knowing one more cell.\n")
  if sim.config.sense > 0:
    result.add("- RECONNAISSANCE: before each move you name the " &
      "bottom-left corner of a " & $sim.config.sense & "x" &
      $sim.config.sense & " window and are told the truth about those " &
      "cells. A cell you saw EMPTY may be filled later; a cell you saw " &
      "OCCUPIED stays occupied forever.\n")
  result.add("- You may never name a cell you already hold, nor one you " &
    "have already proven is your opponent's, nor a cell that is off the " &
    "board. Those are not moves; they are invalid replies.\n")
  result.add("- The episode stops after " & $sim.config.maxPlies &
    " plies at the latest; if nobody has won by then, the seat that is " &
    "closer to winning takes it.\n\n")
  result.add("OUTPUT FORMAT: reply with ONLY one JSON object, nothing " &
    "else — no analysis, no explanation, no markdown fences. Your reply " &
    "must begin with the character { and end with }.")

proc replyContract(sim: Sim): string =
  if sim.config.sense > 0:
    "Reply with ONLY {\"sense\": \"b3\", \"cell\": \"c4\", " &
      "\"guess\": [\"d3\",\"d4\"], \"say\": \"…\", \"notes\": \"…\"} — " &
      "`sense` one of YOUR LEGAL SENSE ANCHORS, `cell` one of YOUR LEGAL " &
      "ATTEMPTS, `guess` at most " & $MaxGuessCells & " cell names you " &
      "believe are your opponent's, `say` at most " & $MaxSayLen &
      " characters for the spectators, `notes` at most " & $MaxNotesLen &
      " characters kept private and handed back to you next ply."
  else:
    "Reply with ONLY {\"cell\": \"c4\", \"guess\": [\"d3\",\"d4\"], " &
      "\"say\": \"…\", \"notes\": \"…\"} — `cell` one of YOUR LEGAL " &
      "ATTEMPTS, `guess` at most " & $MaxGuessCells & " cell names you " &
      "believe are your opponent's, `say` at most " & $MaxSayLen &
      " characters for the spectators, `notes` at most " & $MaxNotesLen &
      " characters kept private and handed back to you next ply."

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let n = sim.config.size
  let colour = if seat == 0: "RED" else: "BLUE"
  let believed = sim.believedBoard(seat)
  var mine, proven, untouched, stale: seq[int]
  for cell in 0 ..< sim.cells:
    if sim.ownsCell(seat, cell): mine.add(cell)
    elif cell in sim.known[seat]: proven.add(cell)
    elif cell in sim.sensedEmptyAt[seat]: stale.add(cell)
    else: untouched.add(cell)

  result.add("Ply " & $(sim.plies + 1) & " of " & $sim.config.maxPlies &
    ". You are " & sim.names[seat] & ", playing " & colour & " on a " & $n &
    "×" & $n & " " &
    (if sim.config.mode == mPhantomTtt: "Phantom Tic-Tac-Toe"
     else: "Dark Hex") & " board.\n\n")
  result.add(sim.goalText(seat) & "\n\n")
  result.add("THE FOG: you see only your own stones and the opponent " &
    "stones you have proven. You are never told anything about their " &
    "moves.\n\n")
  result.add("YOUR STONES (" & $mine.len & "): " & sim.cellList(mine) & "\n")
  result.add("OPPONENT STONES YOU HAVE PROVEN (" & $proven.len & "): " &
    sim.cellList(proven) & "\n")
  if sim.config.sense > 0:
    var parts: seq[string]
    for cell in stale:
      parts.add(sim.cellName(cell) & " (ply " &
        $(sim.sensedEmptyAt[seat][cell] + 1) & ")")
    result.add("CELLS YOU SENSED EMPTY (may be stale): " &
      (if parts.len == 0: "(none)" else: parts.join(", ")) & "\n")
  result.add("CELLS YOU HAVE NEVER TOUCHED (" & $untouched.len & "): " &
    sim.cellList(untouched) & "\n")
  result.add("YOUR LEGAL ATTEMPTS: " &
    sim.cellList(sim.legalAttempts(seat)) & "\n")
  if sim.config.sense > 0:
    result.add("YOUR LEGAL SENSE ANCHORS: " &
      sim.cellList(sim.legalAnchors(seat)) & " (each names the bottom-left " &
      "corner of a " & $sim.config.sense & "×" & $sim.config.sense &
      " window)\n")
  result.add("STONES ON THE BOARD: you " & $mine.len & ". ")
  ## What a seat may infer about the opponent's stone COUNT is exactly what
  ## the collision rule allows — no more. Abrupt: every ply is a turn, so
  ## the seat can count their TURNS but not their stones. Non-abrupt: a
  ## turn only ends on a placement, so turns taken == stones held.
  if sim.config.abrupt:
    let theirTurns = max(sim.plies - mine.len - sim.probes[seat], 0)
    result.add("Opponent: unknown. They have taken " & $theirTurns &
      " turns, but in this variant a turn that hits one of your stones " &
      "places nothing, so they hold between 0 and " & $theirTurns &
      " stones.\n")
  else:
    let theirStones =
      mine.len + (if seat == sim.config.first: 0 else: 1)
    result.add("Opponent: exactly " & $theirStones &
      " — in this variant a collision does not end a turn, so they have " &
      "placed one stone per turn they have taken.\n")
  let distance = sim.distToWin(believed, seat)
  if sim.config.mode == mPhantomTtt:
    result.add("YOUR BEST LINE NEEDS " &
      (if distance >= Unreachable: "MORE CELLS THAN ANY LIVE LINE HAS"
       else: $distance & " MORE CELLS") &
      ", on the board as you believe it to be.\n\n")
  else:
    result.add("YOU ARE " &
      (if distance >= Unreachable: "CUT OFF FROM CONNECTING"
       else: $distance & " STONES FROM CONNECTING") &
      ", on the board as you believe it to be.\n\n")
  result.add("REFEREE LOG (everything you have ever been told):\n" &
    sim.refereeLog(seat) & "\n\n")
  result.add("YOUR NOTES FROM EARLIER PLIES:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  if prompt.len > 0:
    result.add("GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never " &
      "above the rules):\n" & prompt & "\n\n")
  result.add(sim.replyContract())

# ---- Reply parsing ----------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating
  ## fences and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(FogError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc parseCellNode*(sim: Sim, node: JsonNode): int =
  ## An algebraic string (case-insensitive, spaces and trailing prose
  ## tolerated) or a two-element [col, row] integer array, 0-based.
  if node.isNil:
    raise newException(FogError, "no cell in response")
  case node.kind
  of JArray:
    if node.len != 2:
      raise newException(FogError, "a cell array must be [col, row]")
    let col = node[0].getInt(-1)
    let row = node[1].getInt(-1)
    if col < 0 or col >= sim.config.size or row < 0 or row >= sim.config.size:
      raise newException(FogError,
        "cell [" & $col & ", " & $row & "] is off the board")
    return row * sim.config.size + col
  of JString:
    let text = node.getStr().strip().toLowerAscii()
    var index = 0
    while index < text.len and text[index] notin {'a' .. 'z'}:
      inc index
    if index >= text.len:
      raise newException(FogError, "not a cell name: " & node.getStr())
    let col = ord(text[index]) - ord('a')
    inc index
    while index < text.len and text[index] in {' ', '\t', '-', '.', ','}:
      inc index
    var digits = ""
    while index < text.len and text[index] in {'0' .. '9'}:
      digits.add(text[index])
      inc index
    if digits.len == 0:
      raise newException(FogError, "not a cell name: " & node.getStr())
    var row = -1
    try:
      row = parseInt(digits) - 1
    except ValueError:
      raise newException(FogError, "not a cell name: " & node.getStr())
    if col < 0 or col >= sim.config.size or row < 0 or row >= sim.config.size:
      raise newException(FogError,
        "cell is off the board: " & node.getStr())
    return row * sim.config.size + col
  else:
    raise newException(FogError, "a cell must be a name or [col, row]")

proc parseReply*(sim: Sim, seat: int, payload: JsonNode): Decision =
  ## `cell` (and `sense`, where the variant has one) are required and must
  ## be legal. `guess`, `say` and `notes` can never make a reply invalid:
  ## a malformed guess is dropped, over-long text is truncated on a rune
  ## boundary. The guess exists to put the seat's belief on the record for
  ## the overlay and the audit; making it fatal would trade the show for a
  ## fallback.
  result.anchor = -1
  result.cell = sim.parseCellNode(payload{"cell"})
  if sim.config.sense > 0:
    result.anchor = sim.parseCellNode(payload{"sense"})
  result.say = cleanText(oneLine(payload{"say"}.getStr()), MaxSayLen)
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  let guess = payload{"guess"}
  if not guess.isNil and guess.kind == JArray:
    for entry in guess:
      if result.guess.len >= MaxGuessCells:
        break
      if entry.kind != JString:
        continue
      let name = cleanText(entry.getStr(), MaxGuessLen)
      var cell = -1
      try:
        cell = sim.cellIndex(name)
      except FogError:
        continue
      if cell in sim.known[seat] or sim.ownsCell(seat, cell):
        continue
      if cell notin result.guess:
        result.guess.add(cell)

# ---- Anthropic / Bedrock transport ------------------------------------------

proc completeText(client: LlmClient, system, user: string): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
  if response.code == 401 or response.code == 403:
    ## Rune-safe, never a byte slice: an HTTP body cut at a byte offset can
    ## end in half a rune, and this text goes on to stdout.
    let detail = cleanText(response.body.replace("\n", " "), MaxErrorLen)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(FogError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(FogError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = cleanText(response.body.replace("\n", " "), MaxErrorLen)
    discard client.tryNextBedrockModel("throttled")
    raise newException(FogError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(FogError, "anthropic error " & $response.code &
      ": " & cleanText(response.body.replace("\n", " "), MaxErrorLen))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(FogError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(FogError, "reply cut off at max_tokens before " &
      "any JSON: " & cleanText(result.replace("\n", " "), 160))

proc retryHint(sim: Sim, seat: int): string =
  ## Printing the legal set — computed by the SAME predicate the validator
  ## applies — is what halves fallbacks in formal-output games.
  result = "\n\nYour previous reply was invalid. Respond with ONLY the " &
    "requested JSON object; `cell` must be one of: " &
    sim.cellList(sim.legalAttempts(seat))
  if sim.config.sense > 0:
    result.add(" and `sense` must be one of: " &
      sim.cellList(sim.legalAnchors(seat)))

proc decide*(
  client: LlmClient,
  sim: Sim,
  seat: int,
  prompt: string,
  baseline: Baseline,
  scripted: bool
): Decision =
  ## One decision for one seat. NEVER raises: any failure lands on the
  ## scripted baseline so the episode always advances.
  if scripted or client.disabled:
    return scriptedDecision(sim, seat, baseline)
  let system = systemPrompt(sim, seat)
  for attempt in 0 .. 1:
    var user = userPrompt(sim, seat, prompt)
    if attempt > 0:
      user.add(sim.retryHint(seat))
    try:
      let payload = extractJsonObject(client.completeText(system, user))
      let decision = parseReply(sim, seat, payload)
      ## Reject illegal replies HERE, on a copy, so the retry carries the
      ## hint and an illegal reply never touches the live sim.
      var probe = sim
      if sim.config.sense > 0:
        probe.applySense(seat, decision.anchor)
      probe.applyAttempt(seat, decision.cell, decision.say, decision.notes,
        decision.guess, false, false)
      return decision
    except CatchableError as error:
      echo "fogboards llm: seat ", seat, " attempt ", attempt, " failed: ",
        cleanText(error.msg.replace("\n", " "), MaxErrorLen)
      if client.disabled:
        break
  echo "fogboards: seat ", seat, " falling back to the ", $baseline,
    " baseline"
  result = scriptedDecision(sim, seat, baseline)
  result.fellBack = true
