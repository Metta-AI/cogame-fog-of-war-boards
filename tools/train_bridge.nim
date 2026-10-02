## Numeric choices over the production simulator and the acting seat's fog.
## nim c -d:release --path:src -o:/tmp/fogboards-train-bridge tools/train_bridge.nim

import std/[hashes, json, os, sets, tables]
import fogboards/[llm, sim]

var
  game: Sim
  decisionId: int
  manifestPath: string
  variant: string
  language: bool
  sensePending: bool
  senseAnchor: int
  operatorPrompt: string
  retryCount: int

proc currentDecision(): JsonNode =
  let seat = game.beginPly()
  let system = systemPrompt(game, seat)
  let phase = if language and sensePending: "sense" else: "attempt"
  var user = userPrompt(game, seat, operatorPrompt, phase)
  if language and retryCount > 0: user.add(game.retryHint(seat, phase))
  var schema = %*{"type": "object", "properties": {
    "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
    "required": ["choice"]}
  if language:
    var legal = newJArray()
    for cell in (if sensePending: game.legalAnchors(seat) else: game.legalAttempts(seat)):
      legal.add(%game.cellName(cell))
    if sensePending:
      schema = %*{"type": "object", "properties": {
        "sense": {"type": "string", "enum": legal}}, "required": ["sense"]}
    else:
      schema = %*{"type": "object", "properties": {
        "cell": {"type": "string", "enum": legal},
        "say": {"type": "string"}, "notes": {"type": "string"},
        "guess": {"type": "array", "items": {"type": "string"}, "maxItems": MaxGuessCells}},
        "required": ["cell"]}
  %*{"kind": "decision", "game": "fog-of-war-boards",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "inference_mode": (if language: %"text_action" else: newJNull()),
    "turn": game.plies,
    "semantic_view": {"system": system, "user": user,
      "phase": phase, "observation": observationJson(game, seat)},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": schema, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %(int(hash(command["seed"].getStr()) mod 1_000_000_000))
  var config = defaultGameConfig()
  config.update($variantConfig)
  game = initSim(sampleEpisode(config))
  decisionId = 0
  retryCount = 0
  sensePending = language and game.config.sense > 0
  senseAnchor = -1
  currentDecision()

proc encode(): JsonNode =
  let seat = game.mover
  var values = newJArray()
  for name in ["phantom-ttt-3", "dark-hex-4", "dark-hex-5", "recon-hex-5"]:
    values.add(%(if variant == name: 1 else: 0))
  values.add(%seat)
  values.add(%(float(game.plies) / float(game.config.maxPlies)))
  let legal = game.legalAttempts(seat)
  for cell in 0 ..< 25:
    values.add(%(if cell < game.cells and game.ownsCell(seat, cell): 1 else: 0))
    values.add(%(if cell < game.cells and cell in game.known[seat]: 1 else: 0))
    values.add(%(if cell < game.cells and cell in game.sensedEmptyAt[seat]: 1 else: 0))
    values.add(%(if cell in legal: 1 else: 0))
  doAssert values.len == 106
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision", "observation": currentDecision()}
  var action: JsonNode
  var consumedRejection = ""
  let seat = game.mover
  if language:
    let phase = if sensePending: "sense" else: "attempt"
    let proposal = game.phaseProposal(seat, command["response"].getStr(), phase, senseAnchor)
    var decision: Decision
    if proposal.accepted:
      decision = proposal.decision
    elif retryCount == 0:
      retryCount = 1
      return %*{"kind": "rejected", "reason": proposal.rejection,
        "observation": currentDecision()}
    else:
      consumedRejection = proposal.rejection
      decision = game.scriptedPhase(seat, blProbe, phase, senseAnchor)
    retryCount = 0
    action = game.phaseAction(decision, phase)
    if sensePending:
      senseAnchor = decision.anchor
      game.applySense(seat, senseAnchor)
      sensePending = false
    else:
      game.applyAttempt(seat, decision.cell, decision.say, decision.notes,
        decision.guess, decision.scripted, consumedRejection.len > 0)
      sensePending = game.config.sense > 0
  else:
    action = parseJson(command["response"].getStr())
    let choice = action["choice"].getInt()
    doAssert choice in 0 .. 1
    let baseline = if choice == 0: blProbe else: blSweep
    let decision = scriptedDecision(game, seat, baseline)
    if game.config.sense > 0:
      game.applySense(seat, decision.anchor)
    game.applyAttempt(seat, decision.cell, decision.say, decision.notes,
      decision.guess, true, false)
  inc decisionId
  let observation = if game.done:
    let scores = resultsJson(game)["scores"]
    %*{"kind": "terminal", "scores": {"0": scores[0], "1": scores[1]},
      "utilities": {"0": scores[0], "1": scores[1]}}
  else: currentDecision()
  if consumedRejection.len > 0:
    %*{"kind": "consumed_rejection", "reason": consumedRejection,
      "action": action, "observation": observation}
  else: %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4 or (args.len >= 3 and args[2] != "--language"):
    quit("usage: fogboards-train-bridge MANIFEST VARIANT [--language [OPERATOR_PROMPT]]", 1)
  language = args.len >= 3
  operatorPrompt = if args.len == 4: args[3] else: ""
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["phantom-ttt-3", "dark-hex-4", "dark-hex-5",
    "recon-hex-5"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher":
        if language:
          let decision = scriptedPhase(game, game.mover, blProbe,
            if sensePending: "sense" else: "attempt", senseAnchor)
          let action = if sensePending: %*{"sense": game.cellName(decision.anchor)}
            else: %*{"cell": game.cellName(decision.cell)}
          %*{"response": $action}
        else: %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
