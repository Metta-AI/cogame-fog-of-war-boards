## Numeric choices over the production simulator and the acting seat's fog.
## nim c -d:release --path:src -o:/tmp/fogboards-train-bridge tools/train_bridge.nim

import std/[hashes, json, os, sets, tables]
import fogboards/[llm, sim]

var
  game: Sim
  decisionId: int
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let seat = game.beginPly()
  let system = systemPrompt(game, seat)
  let user = userPrompt(game, seat, "")
  %*{"kind": "decision", "game": "fog-of-war-boards",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.plies,
    "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
      "required": ["choice"]}, "typed_question": newJNull()}

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
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 1
  let seat = game.mover
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
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: fogboards-train-bridge MANIFEST VARIANT", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["phantom-ttt-3", "dark-hex-4", "dark-hex-5",
    "recon-hex-5"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
