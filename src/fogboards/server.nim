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
##   WS  /player?slot=N&token=T      - fogboards.player.v4
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - the replay payload (replay mode)

import
  std/[base64, json, locks, math, monotimes, options, os, sets, strutils, sysrand, tables, times],
  bitworld/runtime, bitworld/decision_trajectory, bitworld/native_stop, bitworld/artifact_runtime,
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
  ExternalPhase = enum
    epNone = "none"
    epSense = "sense"
    epAttempt = "attempt"

  PendingPhase = object
    decisionId, seat: string
    observation: JsonNode
    attempts: seq[DecisionAttempt]
    selected: Option[string]
    action: JsonNode
    status: ActionStatus
    terminal: bool
    fallbackOrigin: Option[string]

  GameState = object
    trajectory: Option[DecisionTrajectory]
    externalAttempts: seq[DecisionAttempt]
    externalRejections: int
    externalFallback: bool
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[bool]
    baselines: seq[Baseline]
    external: seq[bool]
    registered: seq[bool]
    decisionId: int
    pendingId: string
    phaseDeadline: MonoTime
    issuedSeats: Table[string, int]
    issuedAt: Table[string, MonoTime]
    issuedPrompts: Table[string, JsonNode]
    latestDecisions: Table[int, string]
    startedAttempts, completedAttempts: Table[string, JsonNode]
    pendingPhases: seq[PendingPhase]
    stopping: bool
    stopId: string
    stopIssuedAt, acknowledgementDeadline: MonoTime
    stoppedSlots: HashSet[int]
    pendingSeat: int
    pendingPhase: ExternalPhase
    pendingSense: int
    pendingDecision: Decision
    pendingAccepted: bool
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
    events.add(event.publicEventJson())
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
  ## value, never the true one. External policies receive their legal
  ## choices in the per-turn observation frame.
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

proc writeArtifact(uri, data, contentType, methodEnv: string, cleanupDeadline: MonoTime) =
  if uri.len == 0: return
  let verb = getEnv(methodEnv, "PUT").toUpperAscii()
  let httpMethod = case verb
    of "PUT": ahPut
    of "POST": ahPost
    else: raise newException(ValueError, "unsupported artifact method")
  writeCogameArtifact(uri, data, contentType, methodEnv, cleanupDeadline, httpMethod)

proc waitUntil(deadline: MonoTime) =
  while getMonoTime() < deadline and not interruptionRequested():
    sleep(int(min(10'i64, max(1'i64, (deadline - getMonoTime()).inMilliseconds))))

proc replayPayload(gs: GameState, results: JsonNode): string =
  ## The pure writer in `sim`, so the bytes CI validates are the bytes the
  ## tests pin.
  $gs.sim.replayPayloadJson(results)

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One board state per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.boardStateJson())

proc retainExternalAttempt(gs: var GameState, seat: int, id: string,
    evidence: JsonNode, completed: bool) =
  if not gs.issuedSeats.hasKey(id) or gs.issuedSeats[id] != seat:
    raise newException(FogError, "attempt does not belong to authenticated issued seat")
  let attempt = readAttemptEvidence(evidence)
  if attempt.attemptId != id & "-model" or attempt.origin != aoModel:
    raise newException(FogError, "external attempt must identify its issued model call")
  let prompt = gs.issuedPrompts[id]
  if attempt.prompt != prompt or attempt.request.kind != JObject or
      attempt.request["system"] != prompt[0]["content"] or
      attempt.request["messages"] != %*[prompt[1]]:
    raise newException(FogError, "model call rewrites the exact private prompt")
  if not gs.startedAttempts.hasKey(id):
    if completed:
      raise newException(FogError, "completed model evidence lacks pre-request start")
    if attempt.response.kind != JNull or attempt.rawResponse.kind != JNull or
        attempt.platformCallId.isSome or attempt.providerRequestId.isSome or
        attempt.responseHeaders.isSome or attempt.responseHeadersB64.isSome or
        attempt.responseBodyB64.isSome or attempt.responseComplete.isSome or
        attempt.responseReaderJoined.isSome or attempt.httpStatus.isSome or
        attempt.latencyMs.isSome or attempt.inputTokens.isSome or attempt.outputTokens.isSome or
        attempt.promptTokenIds.isSome or attempt.sampledTokenIds.isSome or
        attempt.behaviorLogprobs.isSome or attempt.stopReason.isSome or attempt.rejectionReason.isSome or
        attempt.modelIdentity.isSome or attempt.tokenizerIdentity.isSome or attempt.chatTemplateSha256.isSome:
      raise newException(FogError, "first model start must precede observed response facts")
  else:
    let before = gs.startedAttempts[id]
    if (before["latency_ms"].kind != JNull or before["response_reader_joined"] == %true) and evidence != before:
      raise newException(FogError, "finished native attempt evidence is immutable")
    for key in ["prompt", "request", "decoder", "policy"]:
      if evidence[key] != before[key]:
        raise newException(FogError, "started model request evidence is immutable")
    for key in ["response_body_b64", "response_headers_b64"]:
      if before[key].kind != JNull:
        if evidence[key].kind != JString or
            not decode(evidence[key].getStr()).startsWith(decode(before[key].getStr())):
          raise newException(FogError, "received native bytes cannot be rewritten")
    if before["response_complete"] == %true and
        (evidence["response_complete"] != %true or evidence["response_body_b64"] != before["response_body_b64"] or
          evidence["response_headers_b64"] != before["response_headers_b64"]):
      raise newException(FogError, "complete native response cannot be rewritten")
    for key in ["http_status", "response_headers", "platform_call_id", "provider_request_id",
        "model_identity", "tokenizer_identity", "chat_template_sha256"]:
      if before[key].kind != JNull and evidence[key] != before[key]:
        raise newException(FogError, "received native identity cannot be rewritten")
  if gs.completedAttempts.hasKey(id) and evidence != gs.completedAttempts[id]:
    raise newException(FogError, "completed native evidence is immutable")
  gs.startedAttempts[id] = copy(evidence)
  if completed: gs.completedAttempts[id] = copy(evidence)
  if gs.pendingSeat == seat and gs.pendingId == id:
    var updated = false
    for existing in gs.externalAttempts.mitems:
      if existing.attemptId == attempt.attemptId:
        let parsed = existing.parsedAction
        let accepted = existing.accepted
        let rejection = existing.rejectionReason
        existing = attempt
        existing.parsedAction = parsed
        existing.accepted = accepted
        existing.rejectionReason = rejection
        updated = true
    if not updated: gs.externalAttempts.add(attempt)

proc issueExternalPhase(gs: var GameState, seat: int, retry: bool) =
  inc gs.decisionId
  let id = "fog-" & $gs.sim.plies & "-" & $seat & "-" & $gs.pendingPhase & "-" & $gs.decisionId
  let phase = $gs.pendingPhase
  var user = userPrompt(gs.sim, seat, gs.prompts[seat], phase)
  if retry: user.add(gs.sim.retryHint(seat, phase))
  let messages = %*[{"role": "system", "content": systemPrompt(gs.sim, seat)},
    {"role": "user", "content": user}]
  gs.pendingId = id
  gs.issuedSeats[id] = seat
  gs.issuedAt[id] = getMonoTime()
  gs.issuedPrompts[id] = messages
  gs.latestDecisions[seat] = id
  let decision = %*{"type": "decision", "protocol": "fogboards.player.v4", "decision_id": id,
    "phase": phase, "observation": observationJson(gs.sim, seat), "messages": messages,
    "transport": {"budget_ms": max(0'i64, (gs.phaseDeadline - getMonoTime()).inMilliseconds),
      "cleanup_budget_ms": 5000}}
  if gs.playerSockets.hasKey(seat):
    if retry:
      gs.playerSockets[seat].send($(%*{"type": "rejected", "decision_id": id,
        "reason": "phase proposal rejected", "observation": decision}))
    else: gs.playerSockets[seat].send($decision)

proc finishEpisode(runtimeConfig: RuntimeConfig, episodeDeadline: MonoTime, failed = false) =
  let cleanupDeadline = min(episodeDeadline, getMonoTime() + initDuration(seconds = 5))
  var interrupted = interruptionRequested() or failed
  var targets: seq[int]
  withLock stateLock:
    if state.finished: return
    state.stopping = true
    state.stopId = ""
    for byte in urandom(16): state.stopId.add(toHex(byte, 2).toLowerAscii())
    state.stopIssuedAt = getMonoTime()
    state.acknowledgementDeadline = min(cleanupDeadline, getMonoTime() + initDuration(seconds = 3))
    for slot, external in state.external:
      if external and state.registered[slot]:
        targets.add(slot)
        if state.playerSockets.hasKey(slot):
          state.playerSockets[slot].send($(%*{"type": "stop", "stop_id": state.stopId,
            "decision_id": (if state.latestDecisions.hasKey(slot): %state.latestDecisions[slot] else: newJNull()),
            "transport": {"cleanup_budget_ms": max(0'i64, (state.acknowledgementDeadline - getMonoTime()).inMilliseconds)}}))
  while getMonoTime() < state.acknowledgementDeadline:
    var joined = true
    withLock stateLock:
      for slot in targets: joined = joined and slot in state.stoppedSlots
    if joined: break
    sleep(10)
  withLock stateLock:
    for slot in targets:
      if slot notin state.stoppedSlots: interrupted = true
  var results, privateOutcome: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished: return
    state.finished = true
    results = state.sim.resultsJson()
    var cleanup = newJObject()
    for slot in targets: cleanup[$slot] = %(if slot in state.stoppedSlots: "joined" else: "unresolved")
    privateOutcome = copy(results)
    privateOutcome["player_cleanup"] = cleanup
    replayData = state.replayPayload(results)
    if state.trajectory.isSome:
      for pending in state.pendingPhases:
        var attempts = pending.attempts
        for attempt in attempts.mitems:
          for _, evidence in state.startedAttempts:
            if evidence["attempt_id"] == %attempt.attemptId:
              let parsed = attempt.parsedAction
              let accepted = attempt.accepted
              let rejection = attempt.rejectionReason
              attempt = readAttemptEvidence(evidence)
              attempt.parsedAction = parsed
              attempt.accepted = accepted
              attempt.rejectionReason = rejection
        state.trajectory.get().recordDecision(pending.decisionId, pending.seat,
          pending.observation, attempts, pending.selected, pending.action,
          pending.status, terminal = pending.terminal, fallbackOrigin = pending.fallbackOrigin)
      var outcomes = newJObject()
      for seat in 0 ..< Seats: outcomes[$seat] = results["scores"][seat]
      state.trajectory.get().finish(
        if failed: esFailed
        elif not interrupted and state.sim.done and results["reason"].getStr() == "complete":
          esCompleted else: esTruncated,
        privateOutcome, if interrupted: newJNull() else: outcomes)
    if not interrupted:
      var aliasNames = newJArray()
      for name in state.sim.names: aliasNames.add(%name)
      var final = %*{"type": "final", "done": true, "scores": results["scores"],
        "outcome": results["outcome"], "names": aliasNames, "plies": results["plies"],
        "reason": results["reason"], "ending": results["ending"]}
      for slot, socket in state.playerSockets:
        final["slot"] = %slot
        socket.send($final)
      state.broadcastLocked()
  if state.trajectory.isSome:
    let trajectoryMethod = case getEnv("COGAME_SAVE_TRAJECTORY_METHOD", "PUT").toUpperAscii()
      of "PUT": ahPut
      of "POST": ahPost
      else: raise newException(ValueError, "unsupported artifact method")
    writeTrajectoryArtifact(state.trajectory.get(), getEnv(CogameSaveTrajectoryUriEnv), cleanupDeadline, trajectoryMethod)
  if interrupted: return
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD", cleanupDeadline)
  writeArtifact(runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD", cleanupDeadline)
  waitUntil(min(episodeDeadline, getMonoTime() + initDuration(milliseconds = ShutdownGraceMs)))

proc plySpacing(config: GameConfig): float =
  if existsEnv("COWORLD_LLM_PLY_SPACING_SECONDS"):
    result = getEnv("COWORLD_LLM_PLY_SPACING_SECONDS").parseFloat()
    if result < 0: raise newException(ValueError, "LLM ply spacing must be nonnegative")
    return
  if config.plySpacingSeconds > 0: config.plySpacingSeconds.float
  else: (DerivedPlySpacingSeconds * (if config.sense > 0: 2 else: 1)).float

proc worstPlySeconds(config: GameConfig): float =
  ((if config.sense > 0: 2 else: 1) * config.llmTimeoutSeconds + PlyGuardSlackSeconds).float

proc awaitExternalPhase(sim: Sim, mover: int, phase: ExternalPhase,
    deadline: MonoTime): bool {.gcsafe.} =
  {.gcsafe.}:
    var connected = false
    withLock stateLock:
      state.pendingSeat = mover
      state.pendingPhase = phase
      state.phaseDeadline = deadline
      state.pendingAccepted = false
      state.externalAttempts = @[]
      state.externalRejections = 0
      state.externalFallback = false
      if phase == epSense: state.pendingSense = -1
      connected = state.playerSockets.hasKey(mover)
      state.issueExternalPhase(mover, retry = false)
    while connected and getMonoTime() < deadline and not interruptionRequested():
      withLock stateLock:
        if state.pendingAccepted:
          result = true
          break
        connected = state.playerSockets.hasKey(mover)
      sleep(10)
    withLock stateLock:
      result = state.pendingAccepted
      if not result:
        for attempt in state.externalAttempts.mitems:
          attempt.accepted = false
          if attempt.rejectionReason.isNone:
            attempt.rejectionReason = some(if interruptionRequested(): "native_interrupted" else: "phase_deadline")
      state.pendingSeat = -1
      state.pendingPhase = epNone

proc recordPhase(gs: var GameState, before: Sim, seat: int, phase: string,
    decision: Decision, attempts: seq[DecisionAttempt], applied = true) =
  if gs.trajectory.isNone: return
  let action = if applied: gs.sim.phaseAction(decision, phase) else: newJNull()
  var selected = none(string)
  if applied and not decision.scripted and not decision.fellBack and attempts.len > 0:
    selected = some(attempts[^1].attemptId)
  gs.pendingPhases.add(PendingPhase(
    decisionId: "fog-" & $before.plies & "-" & $seat & "-" & phase,
    seat: $seat, observation: observationJson(before, seat), attempts: attempts,
    selected: selected, action: action,
    status: if not applied: asMissing elif selected.isSome: asAccepted else: asFallback,
    terminal: gs.sim.done or not applied,
    fallbackOrigin: if applied and selected.isNone: some("game-" & $gs.baselines[seat]) else: none(string)))

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    defer: gameServer.close()
    var episodeDeadline = getMonoTime() + initDuration(seconds = 5)
    var finalizationStarted = false
    defer:
      if not finalizationStarted:
        requestNativeStop()
        finishEpisode(runtimeConfig, episodeDeadline, failed = true)
    let config = state.config
    let gameStart = getMonoTime()
    let timeoutSeconds = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", $config.episodeTimeoutSeconds))
    if classify(timeoutSeconds) in {fcNan, fcInf, fcNegInf} or timeoutSeconds <= 0:
      raise newException(FogError, "episode timeout must be finite and positive")
    episodeDeadline = gameStart + initDuration(milliseconds = int64(timeoutSeconds * 1000))
    let playDeadline = gameStart + initDuration(milliseconds = int64(timeoutSeconds * PlayBudgetFraction * 1000))
    let connectDeadline = min(playDeadline, gameStart + initDuration(milliseconds = int64(config.playerConnectTimeoutSeconds * 1000)))

    while getMonoTime() < connectDeadline and not interruptionRequested():
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
        for registered in state.registered:
          allConnected = allConnected and registered
      if allConnected:
        break
      waitUntil(min(connectDeadline, getMonoTime() + initDuration(milliseconds = 200)))

    withLock stateLock:
      state.started = true
      echo "fogboards: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    let guard = config.worstPlySeconds()
    let spacing = config.plySpacing()
    var lastLlmStart = none(MonoTime)

    while true:
      var simCopy: Sim
      var mover = -1
      var seatPrompt: string
      var seatScripted = false
      var seatExternal = false
      var seatBaseline = blProbe

      ## 1. beginPly, and 2. the wall-clock guard — checked BEFORE any
      ## observation is built, so the episode never stops mid-ply.
      withLock stateLock:
        if state.sim.done or interruptionRequested():
          mover = -1
        elif getMonoTime() + initDuration(milliseconds = int64(guard * 1000)) > playDeadline:
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
          seatExternal = state.external[mover]
          seatBaseline = state.baselines[mover]
      if mover < 0:
        break

      ## Configured pacing bounds starts of native/external plies.
      ## Scripted seats proceed immediately. Recheck the phase budget after
      ## waiting, before rendering or applying another decision.
      let usesLlm = seatExternal or not (seatScripted or client.disabled)
      if usesLlm and lastLlmStart.isSome:
        waitUntil(min(playDeadline, lastLlmStart.get() + initDuration(milliseconds = int64(spacing * 1000))))
      if interruptionRequested(): break
      if getMonoTime() + initDuration(milliseconds = int64(guard * 1000)) > playDeadline:
        withLock stateLock:
          state.sim.endEarly()
          state.broadcastLocked()
        break
      if usesLlm: lastLlmStart = some(getMonoTime())

      ## Apply the sense before exposing its private window to any policy.
      var anchor = -1
      var senseFallback = false
      if config.sense > 0:
        var sense: Decision
        var attempts: seq[DecisionAttempt]
        if seatExternal:
          let accepted = awaitExternalPhase(simCopy, mover, epSense, min(playDeadline, getMonoTime() + initDuration(seconds = config.llmTimeoutSeconds)))
          withLock stateLock:
            attempts = state.externalAttempts
            sense = if accepted: Decision(anchor: state.pendingSense, cell: -1)
              else: scriptedPhase(simCopy, mover, seatBaseline, "sense")
            sense.fellBack = not accepted or state.externalFallback
        else:
          sense = client.decidePhase(simCopy, mover, seatPrompt, seatBaseline,
            seatScripted, "sense", min(playDeadline, getMonoTime() + initDuration(seconds = config.llmTimeoutSeconds)))
          attempts = client.attempts
        if interruptionRequested():
          withLock stateLock:
            for attempt in attempts.mitems:
              attempt.accepted = false
              attempt.rejectionReason = some("native_interrupted")
            state.recordPhase(simCopy, mover, "sense", sense, attempts, applied = false)
          break
        anchor = sense.anchor
        senseFallback = sense.fellBack
        withLock stateLock:
          state.sim.applySense(mover, anchor)
          state.pendingSense = anchor
          state.recordPhase(simCopy, mover, "sense", sense, attempts)
          state.broadcastLocked()
          simCopy = state.sim

      var decision: Decision
      var attempts: seq[DecisionAttempt]
      if seatExternal:
        let accepted = awaitExternalPhase(simCopy, mover, epAttempt, min(playDeadline, getMonoTime() + initDuration(seconds = config.llmTimeoutSeconds)))
        withLock stateLock:
          attempts = state.externalAttempts
          decision = if accepted: state.pendingDecision
            else: scriptedPhase(simCopy, mover, seatBaseline, "attempt", anchor)
          decision.fellBack = not accepted or state.externalFallback
      else:
        decision = client.decidePhase(simCopy, mover, seatPrompt, seatBaseline,
          seatScripted, "attempt", min(playDeadline, getMonoTime() + initDuration(seconds = config.llmTimeoutSeconds)), anchor)
        attempts = client.attempts
      if interruptionRequested():
        withLock stateLock:
          for attempt in attempts.mitems:
            attempt.accepted = false
            attempt.rejectionReason = some("native_interrupted")
          state.recordPhase(simCopy, mover, "attempt", decision, attempts, applied = false)
        break
      withLock stateLock:
        if state.sim.done: break
        if decision.fellBack or senseFallback: inc state.sim.fallbacks[mover]
        state.sim.applyAttempt(mover, decision.cell, decision.say, decision.notes,
          decision.guess, decision.scripted, decision.fellBack or senseFallback)
        state.recordPhase(simCopy, mover, "attempt", decision, attempts)
        echo "fogboards: ply ", state.sim.plies, " ", state.sim.names[mover],
          " plays ", state.sim.cellName(decision.cell), " at ",
          (getMonoTime() - gameStart).inSeconds, "s"
        state.broadcastLocked()

      if config.turnDelayMs > 0:
        waitUntil(min(playDeadline, getMonoTime() + initDuration(milliseconds = config.turnDelayMs)))

    ## Let the verdict land before the final frame.
    if config.turnDelayMs > 0:
      waitUntil(min(playDeadline, getMonoTime() + initDuration(milliseconds = config.turnDelayMs)))
    finalizationStarted = true
    finishEpisode(runtimeConfig, episodeDeadline)

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
    withLock stateLock:
      let authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
      if not authorized:
        request.respond(401)
        return
      if state.started or state.stopping or state.finished or state.playerSockets.hasKey(slot):
        request.respond(409)
        return
      let websocket = request.upgradeToWebSocket()
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "fogboards: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "fogboards.player.v4",
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
      let receivedAt = getMonoTime()
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
            if state.started or state.stopping or state.finished or state.registered[slot]:
              raise newException(FogError, "policy registration is frozen")
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
            state.baselines[slot] = baseline
            state.external[slot] = false
            state.registered[slot] = true
          echo "fogboards: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted: ", scripted " & $baseline else: ""), ")"
        elif payload{"type"}.getStr() == "register" and
            payload["control"].getStr() == "external":
          withLock stateLock:
            if state.started or state.stopping or state.finished or state.registered[slot]:
              raise newException(FogError, "policy registration is frozen")
            state.prompts[slot] = cleanText(payload["prompt"].getStr(), MaxPromptLen)
            state.external[slot] = true
            state.registered[slot] = true
          echo "fogboards: slot ", slot, " registered external control"
        elif payload["type"].getStr() in ["attempt_started", "action"]:
          let id = payload["decision_id"].getStr()
          withLock stateLock:
            if state.finished: return
            if not state.external[slot] or not state.issuedSeats.hasKey(id) or
                state.issuedSeats[id] != slot or receivedAt < state.issuedAt[id]:
              raise newException(FogError, "decision does not belong to authenticated issued seat")
            if payload["type"].getStr() == "attempt_started":
              state.retainExternalAttempt(slot, id, payload["training_attempt"], completed = false)
              return
            let evidence = payload["training_attempt"]
            let source = payload["source"].getStr()
            if source notin ["llm", "unknown", "fallback"]:
              raise newException(FogError, "unknown external action source")
            if evidence.kind != JNull and source != "unknown":
              state.retainExternalAttempt(slot, id, evidence, completed = true)
            elif source == "llm":
              raise newException(FogError, "model action requires native evidence")
            if state.stopping or interruptionRequested() or state.pendingSeat != slot or
                state.pendingId != id or state.pendingAccepted or receivedAt > state.phaseDeadline:
              return
            let phase = $state.pendingPhase
            var attempt = if evidence.kind == JNull:
              newDecisionAttempt(id & "-external", "external-fog", aoUnknown)
              else: readAttemptEvidence(evidence)
            if source == "unknown": attempt.origin = aoUnknown
            if evidence.kind == JNull: attempt.response = copy(payload["action"])
            let transportRejection = attempt.rejectionReason
            attempt.rejectionReason = some("external phase proposal not applied")
            var proposal = if source == "fallback": PhaseProposal()
              else: state.sim.phaseProposal(slot, $payload["action"], phase, state.pendingSense)
            if source == "llm":
              if attempt.response.kind != JString or attempt.rawResponse.kind != JString or
                  attempt.responseComplete != some(true) or attempt.responseReaderJoined != some(true) or
                  attempt.httpStatus != some(200) or attempt.model.isNone or transportRejection.isSome:
                raise newException(FogError, "model action requires its complete successful native response")
              let served = parseJson(attempt.rawResponse.getStr())
              var text = ""
              if served.kind != JObject or served["content"].kind != JArray or served["model"] != %attempt.model.get():
                raise newException(FogError, "selected model differs from received native body")
              for contentBlock in served["content"]:
                if contentBlock.kind != JObject or contentBlock["type"].kind != JString:
                  raise newException(FogError, "native content block violates completion schema")
                if contentBlock["type"].getStr() == "text":
                  if contentBlock["text"].kind != JString:
                    raise newException(FogError, "native text content must be text")
                  text.add(contentBlock["text"].getStr())
              if %text != attempt.response:
                raise newException(FogError, "selected response differs from received native body")
              let sampled = state.sim.phaseProposal(slot, attempt.response.getStr(), phase, state.pendingSense)
              if sampled.accepted: attempt.parsedAction = state.sim.phaseAction(sampled.decision, phase)
              if not sampled.accepted or not proposal.accepted or
                  attempt.parsedAction != state.sim.phaseAction(proposal.decision, phase):
                proposal.accepted = false
                proposal.rejection = "model response differs from player action"
            var chosen: Decision
            var retry = false
            if proposal.accepted:
              chosen = proposal.decision
              if source != "llm": attempt.parsedAction = state.sim.phaseAction(chosen, phase)
              attempt.accepted = true
              attempt.rejectionReason = none(string)
            else:
              inc state.externalRejections
              attempt.rejectionReason = some(if source == "fallback": "player fallback" else: proposal.rejection)
              retry = state.externalRejections == 1 and source != "fallback"
              if not retry:
                chosen = state.sim.scriptedPhase(slot, state.baselines[slot], phase, state.pendingSense)
                state.externalFallback = true
                websocket.send($(%*{"type": "consumed_rejection", "decision_id": id,
                  "phase": phase, "reason": attempt.rejectionReason.get(),
                  "action": state.sim.phaseAction(chosen, phase)}))
            var stored = false
            for existing in state.externalAttempts.mitems:
              if existing.attemptId == attempt.attemptId:
                existing = attempt
                stored = true
            if not stored: state.externalAttempts.add(attempt)
            if retry:
              state.issueExternalPhase(slot, retry = true)
              return
            if state.pendingPhase == epSense: state.pendingSense = chosen.anchor
            else: state.pendingDecision = chosen
            state.pendingAccepted = true
        elif payload["type"].getStr() == "stopped":
          withLock stateLock:
            if state.finished: return
            if not state.external[slot] or payload["worker_status"].getStr() notin ["joined", "no_active_call"] or
                payload["attempts"].kind != JArray:
              raise newException(FogError, "stop must carry its authenticated worker status and attempts")
            let id = payload["decision_id"]
            if id.kind == JString:
              if not state.issuedSeats.hasKey(id.getStr()) or state.issuedSeats[id.getStr()] != slot or
                  receivedAt < state.issuedAt[id.getStr()]:
                raise newException(FogError, "stop evidence does not belong to authenticated issued seat")
              for evidence in payload["attempts"]:
                state.retainExternalAttempt(slot, id.getStr(), evidence, completed = false)
            elif id.kind != JNull or payload["attempts"].len != 0:
              raise newException(FogError, "stop without issued decision cannot assert model attempts")
            if state.playerSockets.hasKey(slot) and state.playerSockets[slot] == websocket:
              websocket.send($(%*{"type": "evidence_received", "decision_id": id, "stop_id": payload["stop_id"]}))
            let latest = if state.latestDecisions.hasKey(slot): %state.latestDecisions[slot] else: newJNull()
            if not state.stopping or id != latest or receivedAt < state.stopIssuedAt or
                receivedAt > state.acknowledgementDeadline or payload["stop_id"] != %state.stopId:
              raise newException(FogError, "stop acknowledgement differs from issued cleanup window")
            for evidence in payload["attempts"]:
              if readAttemptEvidence(evidence).responseReaderJoined != some(true):
                raise newException(FogError, "stop retains an unjoined native reader")
            for issued, known in state.startedAttempts:
              if state.issuedSeats[issued] == slot and readAttemptEvidence(known).responseReaderJoined != some(true):
                raise newException(FogError, "stop omitted an unjoined issued native reader")
            state.stoppedSlots.incl(slot)
      except CatchableError as error:
        echo "fogboards: ignoring invalid player frame"
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
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
  gameServer = newServer(router, websocketHandler, workerThreads = 4, maxMessageLen = 16 * 1024 * 1024)
  echo "fogboards: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(FogError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  if getEnv(CogameSaveTrajectoryUriEnv).len > 0:
    state.trajectory = some(newDecisionTrajectory(getEnv("COWORLD_EPISODE_ID"),
      "fog-" & $config.seed, "fog-of-war-boards", getEnv("COWORLD_GAME_VERSION"),
      getEnv("COWORLD_SOURCE_REVISION")))
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[bool](config.players.len)
  state.baselines = newSeq[Baseline](config.players.len)
  state.external = newSeq[bool](config.players.len)
  state.registered = newSeq[bool](config.players.len)
  state.pendingSeat = -1
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4, maxMessageLen = 16 * 1024 * 1024)
  installNativeStopHandlers()
  var ownerCreated = false
  echo "fogboards: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  try:
    gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host,
      onReady = proc(server: Server) {.gcsafe.} =
        {.gcsafe.}:
          createThread(gameThread, runGame, runtimeConfig)
          ownerCreated = true)
  finally:
    let wasInterrupted = interruptionRequested()
    requestNativeStop()
    if ownerCreated:
      joinThread(gameThread)
    else:
      finishEpisode(runtimeConfig, getMonoTime() + initDuration(seconds = 5), failed = not wasInterrupted)
