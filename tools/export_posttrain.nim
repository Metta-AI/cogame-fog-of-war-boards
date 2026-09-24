## Export complete native games with the exact hosted seat prompts.
## nim c -d:release --path:src -o:/tmp/fogboards-posttrain tools/export_posttrain.nim

import std/[json, os, osproc, strutils]
import fogboards/[llm, sim]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: fogboards-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10:
    quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = sampleEpisode(config)
    var game = initSim(config)
    var rows: seq[string]
    while not game.done:
      let seat = game.beginPly()
      let baseline = if seat == 0: blProbe else: blSweep
      let decision = scriptedDecision(game, seat, baseline)
      var reply = %*{"cell": game.cellName(decision.cell)}
      if config.sense > 0:
        reply["sense"] = %game.cellName(decision.anchor)
      let accepted = parseReply(game, seat, reply)
      doAssert accepted.cell == decision.cell
      doAssert accepted.anchor == decision.anchor
      rows.add($(%*{
        "episode_id": "fogboards-" & variant & "-" & $seed,
        "seed": "fogboards-" & variant & "-" & $seed,
        "decision_id": game.plies,
        "prompt": [
          {"role": "system", "content": systemPrompt(game, seat)},
          {"role": "user", "content": userPrompt(game, seat, "")}
        ],
        "completion": [{"role": "assistant", "content": $reply}],
        "game": "fog-of-war-boards",
        "action_schema_revision": "fogboards-reply-v1"
      }))
      if config.sense > 0:
        game.applySense(seat, accepted.anchor)
      game.applyAttempt(seat, accepted.cell, accepted.say, accepted.notes,
        accepted.guess, true, false)
    doAssert game.reason == "complete"
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "plies": game.plies,
      "scores": resultsJson(game)["scores"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "fog-of-war-boards",
    "variant": variant,
    "source_revision": revision,
    "teacher": "probe-vs-sweep",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
