## Fog-of-War Boards game server: implements the Coworld game contract.
##
## Routes, in REGISTRATION order (all before any catch-all): the episode
## runner probes /healthz, GET /client/player?slot=0&token=<t> and
## GET /client/global BEFORE the player pods start, and neither client
## route may open the player socket.
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - the game block
##   GET /client/chrome_common.js    - the inherited broadcast chrome
##   GET /client/chrome.css
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - fogboards.player.v1
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - the replay payload (replay mode)

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.
  PlayBudgetFraction* = 0.6
  ## The certifier pings /global AFTER the player pods start, so a short
  ## episode must keep answering for a bounded grace after the artifacts
  ## land (lantern 0.1.3 -> 0.1.4).
  ShutdownGraceMs = 20_000

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[bool]
    baselines: seq[Baseline]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous aliases; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.boardStateJson()
  result["type"] = %"state"
  result["game"] = %"fog-of-war-boards"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## REDACTED: no board, no cell list, and nothing about the opponent
  ## beyond what this seat has proven. `distToWin` is the seat's BELIEVED
  ## value, never the true one. Decisions are server-side, so a policy
  ## loses nothing by this.
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "ply": gs.sim.plies,
    "maxPlies": gs.config.maxPlies,
    "mode": $gs.config.mode,
    "seat": {
      "score": gs.sim.score(slot),
      "stones": gs.sim.stones[slot],
      "discovered": gs.sim.discovered(slot),
      "probes": gs.sim.probes[slot],
      "distToWin": gs.sim.believedDistToWin(slot),
      "fallbacks": gs.sim.fallbacks[slot]
    },
    "toMove": (not gs.sim.done) and gs.sim.mover == slot,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason,
    "ending": gs.sim.ending
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table (the truth
  ## board included); players get the redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## The pure writer in `sim`, so the bytes CI validates are the bytes the
  ## tests pin.
  $gs.sim.replayPayloadJson(results)

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One board state per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.boardStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection. Results carry POLICY
    ## names for the platform; the player sockets get the table aliases.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "outcome": results["outcome"],
      "names": aliasNames,
      "plies": results["plies"],
      "reason": results["reason"],
      "ending": results["ending"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "fogboards: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## Keep /healthz and /global answering for a bounded grace: the
  ## certifier pings /global after the player pods start, and a short
  ## episode is otherwise already gone.
  echo "fogboards: artifacts written; serving for ", ShutdownGraceMs div 1000,
    "s of shutdown grace"
  sleep(ShutdownGraceMs)
  echo "fogboards: episode complete, shutting down"
  quit(0)

proc plySpacing(config: GameConfig): float =
  if config.plySpacingSeconds > 0: config.plySpacingSeconds.float
  else: DerivedPlySpacingSeconds.float

proc worstPlySeconds(config: GameConfig): float =
  (2 * config.llmTimeoutSeconds + PlyGuardSlackSeconds).float

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "fogboards: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps NOTHING, so
    ## play inside a fraction of it. The hosted dispatcher hands the
    ## timeout only to its own worker sidecar, NOT to the game container,
    ## so when the env is silent assume the configured platform default.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "fogboards: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    let guard = config.worstPlySeconds()
    let spacing = config.plySpacing()
    var lastLlmStart = 0.0

    while true:
      var simCopy: Sim
      var mover = -1
      var seatPrompt: string
      var seatScripted = false
      var seatBaseline = blProbe

      ## 1. beginPly, and 2. the wall-clock guard — checked BEFORE any
      ## observation is built, so the episode never stops mid-ply.
      withLock stateLock:
        if state.sim.done:
          mover = -1
        elif playDeadline > 0.0 and epochTime() + guard > playDeadline:
          echo "fogboards: play deadline would be crossed by the next ply " &
            "(after ", state.sim.plies, "/", config.maxPlies,
            " plies); settling on distance"
          state.sim.endEarly()
          state.broadcastLocked()
          mover = -1
        else:
          mover = state.sim.beginPly()
          simCopy = state.sim
          seatPrompt = state.prompts[mover]
          seatScripted = state.scripted[mover]
          seatBaseline = state.baselines[mover]
      if mover < 0:
        break

      ## 13 (of the previous ply). The Bedrock sidecar caps 30 requests per
      ## minute per episode; a ply issues at most two, so LLM-driven plies
      ## start no closer together than the derived floor. Scripted seats
      ## are not gated, which is what keeps offline certification fast.
      let usesLlm = not (seatScripted or client.disabled)
      if usesLlm and lastLlmStart > 0.0:
        let wait = lastLlmStart + spacing - epochTime()
        if wait > 0.0:
          sleep(int(wait * 1000))
      if usesLlm:
        lastLlmStart = epochTime()

      ## 3-5. The slow part (Claude) runs OUTSIDE the lock on a snapshot;
      ## only this thread mutates the sim, so the snapshot cannot go stale.
      let decision = client.decide(simCopy, mover, seatPrompt, seatBaseline,
        scripted = seatScripted)

      withLock stateLock:
        if state.sim.done:
          break
        if decision.fellBack:
          inc state.sim.fallbacks[mover]
        var sensed = false
        try:
          ## 6. Sense, then 7-12. Attempt.
          if config.sense > 0 and decision.anchor >= 0:
            state.sim.applySense(mover, decision.anchor)
            sensed = true
          ## `decision.scripted`, not the seat's declared flag: with no
          ## credentials the client disables itself and a prompt seat is
          ## decided by the baseline too, and the event field means
          ## "decided by a scripted baseline" (types.nim).
          state.sim.applyAttempt(mover, decision.cell, decision.say,
            decision.notes, decision.guess, decision.scripted,
            decision.fellBack)
          echo "fogboards: ply ", state.sim.plies, " ",
            state.sim.names[mover], " plays ",
            state.sim.cellName(decision.cell), " at ",
            (epochTime() - gameStart).int, "s"
        except CatchableError as error:
          ## Degrade, never hang: an unusable decision is replaced by the
          ## always-legal baseline rather than stalling the episode. The
          ## probe in `decide` makes this unreachable in practice; if it
          ## ever fires, the episode still has to advance or end.
          echo "fogboards: decision rejected (", error.msg,
            "); using the scripted fallback"
          if not decision.fellBack:
            inc state.sim.fallbacks[mover]
          try:
            let fallback = scriptedDecision(state.sim, mover, seatBaseline)
            if config.sense > 0 and not sensed and fallback.anchor >= 0:
              state.sim.applySense(mover, fallback.anchor)
            state.sim.applyAttempt(mover, fallback.cell, "", "", @[],
              fallback.scripted, true)
          except CatchableError as fatal:
            echo "fogboards: the baseline could not move either (",
              fatal.msg, "); ending the episode"
            state.sim.endEarly()
        state.broadcastLocked()

      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    ## Let the verdict land before the final frame.
    if config.turnDelayMs > 0:
      sleep(config.turnDelayMs)
    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc scriptHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name,
        "application/javascript; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "fogboards: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "fogboards.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "seats": Seats,
        "mode": $state.config.mode,
        "size": state.config.size,
        "abrupt": state.config.abrupt,
        "sense": state.config.sense,
        "maxPlies": state.config.maxPlies
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          ## Over-cap prompts are cut on a RUNE boundary, never a byte one.
          let prompt = cleanText(payload{"prompt"}.getStr(), MaxPromptLen)
          var scripted = false
          var baseline = blProbe
          let node = payload{"scripted"}
          if not node.isNil:
            case node.kind
            of JBool:
              scripted = node.getBool()
            of JString:
              let text = node.getStr().strip()
              if text.len > 0 and text.toLowerAscii() notin ["0", "false", "no"]:
                scripted = true
                baseline = parseBaseline(text)
            else:
              discard
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.baselines[slot] = baseline
          echo "fogboards: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted: ", scripted " & $baseline else: ""), ")"
      except CatchableError as error:
        echo "fogboards: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay_broadcast.html"))
  result.get("/client/renderer.js", scriptHandler("renderer.js"))
  result.get("/client/chrome_common.js", scriptHandler("chrome_common.js"))
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  let config = payload["config"]
  case config{"mode"}.getStr("dark-hex")
  of "phantom-ttt": result.mode = mPhantomTtt
  else: result.mode = mDarkHex
  result.size = config{"size"}.getInt(5)
  result.abrupt = config{"abrupt"}.getBool(true)
  result.sense = config{"sense"}.getInt(0)
  result.first = config{"first"}.getInt(0)
  result.seed = config{"seed"}.getInt(0)
  result.maxPlies = config{"maxPlies"}.getInt(50)
  ## The replay carries the episode's fitted cap; never re-fit it.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("fogboards.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "fogboards: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(FogError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[bool](config.players.len)
  state.baselines = newSeq[Baseline](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "fogboards: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
