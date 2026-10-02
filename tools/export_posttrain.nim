## Export complete native games with the exact hosted seat prompts.
## nim c -d:release --path:src -o:/tmp/fogboards-posttrain tools/export_posttrain.nim

import std/[json, options, os, osproc, strutils]
import fogboards/[llm, sim]
import bitworld/decision_trajectory

when isMainModule:
  let args = commandLineParams()
  if args.len != 4:
    quit("usage: fogboards-posttrain OUTPUT EPISODES VARIANT GAME_VERSION", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  let gameVersion = args[3]
  doAssert gameVersion.len > 0
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
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    trajectoryRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = sampleEpisode(config)
    var game = initSim(config)
    var rows: seq[string]
    let episodeId = "fogboards-" & variant & "-" & $seed
    let trajectory = newDecisionTrajectory(episodeId, "fog-" & $seed,
      "fog-of-war-boards", gameVersion, revision)
    var decisionIndex = 0
    while not game.done:
      let seat = game.beginPly()
      let baseline = if seat == 0: blProbe else: blSweep
      var anchor = -1
      let phases = if config.sense > 0: @["sense", "attempt"] else: @["attempt"]
      for phase in phases:
        let view = observationJson(game, seat)
        let prompt = %*[
          {"role": "system", "content": systemPrompt(game, seat)},
          {"role": "user", "content": userPrompt(game, seat, "", phase)}]
        let decision = game.scriptedPhase(seat, baseline, phase, anchor)
        let reply = game.phaseAction(decision, phase)
        let accepted = game.parsePhaseReply(seat, reply, phase, anchor)
        if phase == "sense":
          anchor = accepted.anchor
          game.applySense(seat, anchor)
        else:
          game.applyAttempt(seat, accepted.cell, accepted.say, accepted.notes,
            accepted.guess, true, false)
        let decisionId = episodeId & "-" & $decisionIndex
        var teacher = newDecisionAttempt(decisionId & "-teacher", $baseline, aoTeacher)
        teacher.model = some("scripted-" & $baseline)
        teacher.modelIdentity = some(revision)
        teacher.prompt = prompt
        teacher.request = %*{"teacher": $baseline, "observation": view, "phase": phase}
        teacher.response = %($reply)
        teacher.rawResponse = %($reply)
        teacher.decoder = %*{"method": "deterministic"}
        teacher.accepted = true
        teacher.parsedAction = reply
        trajectory.recordDecision(decisionId, $seat, view, @[teacher],
          some(teacher.attemptId), reply, asAccepted, terminal = game.done)
        rows.add($(%*{"episode_id": episodeId, "seed": "fog-" & $seed,
          "decision_id": decisionIndex, "phase": phase, "observation": view,
          "prompt": prompt, "completion": [{"role": "assistant", "content": $reply}],
          "game": "fog-of-war-boards", "action_schema_revision": "fogboards-player-v3"}))
        inc decisionIndex
    var outcomes = newJObject()
    for seat in 0 ..< Seats: outcomes[$seat] = resultsJson(game)["scores"][seat]
    trajectory.finish(esCompleted, resultsJson(game), outcomes)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
    doAssert game.reason == "complete"
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "plies": game.plies,
      "scores": resultsJson(game)["scores"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "fog-of-war-boards",
    "variant": variant,
    "game_version": gameVersion,
    "source_revision": revision,
    "teacher": "probe-vs-sweep",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  for name in ["train.jsonl", "validation.jsonl", "trajectories.jsonl", "manifest.json"]:
    setFilePermissions(output / name, {fpUserRead, fpUserWrite})
  echo "train=", trainRows.len, " validation=", validationRows.len
