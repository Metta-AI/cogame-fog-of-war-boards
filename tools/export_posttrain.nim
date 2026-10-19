## Export complete native games with the exact hosted seat prompts.
## nim c -d:release --path:src -o:/tmp/fogboards-posttrain tools/export_posttrain.nim

import std/[json, options, os, osproc, strutils]
import fogboards/[llm, sim, prompts]
import bitworld/decision_trajectory

when isMainModule:
  let args = commandLineParams()
  if args.len notin [4, 6]:
    quit("usage: fogboards-posttrain OUTPUT EPISODES VARIANT GAME_VERSION [PROMPT_VARIANT PROMPT_SEED]", 1)
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
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
    trajectoryRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    var wording = selection
    if wording.variant == pvMixed: wording.seed += seed - 1
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = sampleEpisode(config)
    var game = initSim(config)
    let episodeId = "fogboards-" & variant & "-" & $seed & "-" & $wording.selectedVariant & "-" & $wording.seed
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
          {"role": "system", "content": systemPrompt(game, seat, wording)},
          {"role": "user", "content": userPrompt(game, seat, "", phase)}]
        view["prompt_template"] = wording.promptMetadata(
          prompt[0]["content"].getStr(), prompt[1]["content"].getStr())
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
        teacher.prompt = prompt
        teacher.response = %($reply)
        teacher.accepted = true
        teacher.parsedAction = reply
        trajectory.recordDecision(decisionId, $seat, view, @[teacher],
          some(teacher.attemptId), reply, asAccepted, terminal = game.done)
        inc decisionIndex
    var outcomes = newJObject()
    for seat in 0 ..< Seats: outcomes[$seat] = resultsJson(game)["scores"][seat]
    trajectory.finish(esCompleted, resultsJson(game), outcomes)
    trajectoryRows.add(trajectory.eventsJsonl().strip())
    doAssert game.reason == "complete"
    runs.add(%*{"seed": seed, "plies": game.plies,
      "scores": resultsJson(game)["scores"], "prompt_selection": wording.selectionMetadata()})
  writePrivate(output / "trajectories.jsonl", trajectoryRows.join("\n") & "\n")
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "fog-of-war-boards",
    "variant": variant,
    "game_version": gameVersion,
    "source_revision": revision,
    "teacher": "probe-vs-sweep",
    "prompt_selection": selection.selectionMetadata(),
    "episodes": episodes,
    "dataset_path": "canonical-trajectories-only; shared reviewed importer owns splits",
    "runs": runs
  }) & "\n")
  echo "complete games=", episodes
