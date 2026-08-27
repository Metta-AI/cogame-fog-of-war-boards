## Packaging invariants, parsed from the template the release workflow
## actually builds. Every check here is a failure that repo CI is the only
## thing standing between and a red `coworld build` two phases later.

import std/[json, os, strutils, unittest]

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir()
  for _ in 0 .. 4:
    if fileExists(dir / "coworld_manifest_template.json"):
      return dir
    dir = dir.parentDir()
  raise newException(IOError, "coworld_manifest_template.json not found")

let manifest = parseJson(
  readFile(repoRoot() / "coworld_manifest_template.json"))
let game = manifest["game"]

proc gameConfigs(): seq[(string, JsonNode)] =
  for variant in manifest["variants"]:
    result.add((variant["id"].getStr(), variant["game_config"]))
  result.add(("certification", manifest["certification"]["game_config"]))

proc walkArrays(node: JsonNode, path: string, seen: var seq[string]) =
  ## Every ARRAY property of a schema must declare minItems and maxItems:
  ## certification rejects a manifest whose array bounds are only implied
  ## by `required` membership (tandem 0.1.0, 2026-08-23).
  if node.kind != JObject:
    return
  if node.hasKey("properties"):
    for name, property in node["properties"]:
      if property.kind == JObject and property{"type"}.getStr() == "array":
        seen.add(path & "." & name)
        check property.hasKey("minItems")
        check property.hasKey("maxItems")
      walkArrays(property, path & "." & name, seen)

suite "seats":
  test "22. num_agents is 2 inside every game_config and nowhere else":
    for (label, config) in gameConfigs():
      checkpoint label
      check config.hasKey("num_agents")
      check config["num_agents"].kind == JInt
      check config["num_agents"].getInt() == 2
      check config["players"].len == config["num_agents"].getInt()
      for player in config["players"]:
        check player["name"].getStr().len > 0
    ## `CoworldVariant` is additionalProperties:false and the platform reads
    ## only game_config.num_agents (cogame-goofspiel-oshi-zumo 0.1.0).
    for variant in manifest["variants"]:
      check not variant.hasKey("num_agents")
      check variant["id"].getStr().len > 0
      check variant["name"].getStr().len > 0
      check variant["description"].getStr().len > 0
    check manifest["variants"].len == 4
    var ids: seq[string]
    for variant in manifest["variants"]:
      ids.add(variant["id"].getStr())
    check ids == @["phantom-ttt-3", "dark-hex-4", "dark-hex-5",
      "recon-hex-5"]
    check manifest["certification"]["players"].len == 2

suite "schemas":
  test "23. no shipped game_config carries tokens; the schema still wants them":
    for (label, config) in gameConfigs():
      checkpoint label
      ## matriculate rejects "runner-managed tokens" in a game_config
      ## (cogame-knights-archers 0.1.0, 2026-08-26).
      check not config.hasKey("tokens")
    let configSchema = game["config_schema"]
    check "tokens" in configSchema["required"].to(seq[string])
    check "players" in configSchema["required"].to(seq[string])
    check configSchema["additionalProperties"].getBool() == false
    check game["results_schema"]["additionalProperties"].getBool() == false
    var arrays: seq[string]
    walkArrays(configSchema, "config_schema", arrays)
    walkArrays(game["results_schema"], "results_schema", arrays)
    check arrays.len >= 12
    ## Every key a shipped game_config uses must be declared, or
    ## `coworld build` rejects the variant against the schema.
    for (label, config) in gameConfigs():
      checkpoint label
      for key, _ in config:
        check configSchema["properties"].hasKey(key)
    ## The results schema names every field the sim writes.
    for field in ["names", "scores", "outcome", "stones", "probes",
        "discovered", "guessesMade", "guessAccuracy", "distToWin",
        "fallbacks", "plies", "maxPlies", "mode", "size", "abrupt", "sense",
        "ending", "reason"]:
      check field in game["results_schema"]["required"].to(seq[string])
      check game["results_schema"]["properties"].hasKey(field)
    check game["results_schema"]["properties"]["reason"]["enum"].to(
      seq[string]) == @["complete", "deadline"]
    check game["results_schema"]["properties"]["ending"]["enum"].to(
      seq[string]) == @["connection", "line", "board-full", "ply-cap",
      "wall-clock"]
    for name in ["scores", "outcome", "stones", "probes", "discovered",
        "guessesMade", "guessAccuracy", "distToWin", "fallbacks", "names"]:
      let property = game["results_schema"]["properties"][name]
      check property["minItems"].getInt() == 2
      check property["maxItems"].getInt() == 2

suite "the upload contract":
  test "24. the manifest matches the coworld 0.1.42 upload contract":
    ## Bare strings here are a platform-side validation error the repo CI
    ## does not otherwise catch (cogame-garble 0.1.0, 2026-08-24).
    for key in ["player", "global"]:
      check game["protocols"][key]["type"].getStr() == "text"
      check game["protocols"][key]["value"].getStr().len > 100
    check game["docs"]["readme"]["type"].getStr() == "text"
    check game["docs"]["readme"]["value"].getStr().len > 100
    check game["docs"]["pages"].len >= 1
    for page in game["docs"]["pages"]:
      check page["id"].getStr().len > 0
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 100
    check game["description"].getStr().len > 100
    check not game.hasKey("tags")            ## tags are top-level only
    check not game.hasKey("display_name")
    check not manifest.hasKey("version")
    check manifest["tags"].len >= 3
    check manifest.hasKey("$schema")
    check manifest["episode_timeout_minutes"].getInt() == 20
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"
    check not manifest.hasKey("replay_viewer")
    check game["owner"].getStr().len > 0
    check game["runnable"]["type"].getStr() == "game"
    check game["runnable"]["run"].to(seq[string]) ==
      @["/bin/fog-of-war-boards"]
    check game["runnable"]["image"].getStr() ==
      "{{FOG_OF_WAR_BOARDS_IMAGE}}"
    ## Without this the hosted container never receives the key and every
    ## league episode silently plays scripted (hive, 2026-08-23). The
    ## namespace is game.name, which is not always the slug.
    let uri = game["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr()
    check uri == "secret://coworld/" & game["name"].getStr() &
      "/anthropic_api_key"
    check game["name"].getStr() == "fog-of-war-boards"
    ## The bundled minimum for cpu is "1"; 500m is rejected at upload
    ## (cogame-pistonball 0.1.1, 2026-08-26).
    check manifest["player"].len == 2
    for player in manifest["player"]:
      check player["resources"]["limits"]["cpu"].getStr() == "1"
      check player["resources"]["requests"]["cpu"].getStr() == "100m"
      check player["type"].getStr() == "player"
      check player["id"].getStr().len > 0
      check player["name"].getStr().len > 0
      check player["description"].getStr().len > 0
      check player["image"].getStr() == "{{FOG_OF_WAR_BOARDS_IMAGE}}"
      check player["run"].to(seq[string]) ==
        @["/bin/fog-of-war-boards-player"]
      check player["source_url"].getStr().startsWith("https://github.com/")

  test "25. every declared player occupies a certification slot":
    ## A fixture that seats only one declared runnable fails cert
    ## `players_missing` (raid 0.1.2 -> 0.1.3, 2026-08-23).
    var declared: seq[string]
    for player in manifest["player"]:
      declared.add(player["id"].getStr())
    var seated: seq[string]
    for slot in manifest["certification"]["players"]:
      let id = slot["player_id"].getStr()
      check id in declared
      seated.add(id)
    for id in declared:
      check id in seated
    check seated.len == manifest["certification"]["game_config"][
      "num_agents"].getInt()
    ## The certification fixture is the dark-hex-5 variant, which is what
    ## the docker smoke plays and what the viewer smoke then loads.
    let fixture = manifest["certification"]["game_config"]
    check fixture["mode"].getStr() == "dark-hex"
    check fixture["size"].getInt() == 5
    check fixture["abrupt"].getBool()
    check fixture["sense"].getInt() == 0
    check fixture["turnDelayMs"].getInt() == 0
    check fixture.hasKey("seed")

suite "the policy set":
  test "the release workflow mints two prompt champions and two fillers":
    let policies = parseJson(readFile(repoRoot() / "tools/ci/policies.json"))
    check policies.len == 4
    var prompts, scripted: seq[string]
    for policy in policies:
      check policy["name"].getStr().startsWith("fog-of-war-boards-")
      check policy["run"].getStr() == "/bin/fog-of-war-boards-player"
      if policy["env"].hasKey("PLAYER_PROMPT"):
        prompts.add(policy["name"].getStr())
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      else:
        scripted.add(policy["env"]["PLAYER_SCRIPTED"].getStr())
    ## A scripted policy seated as a champion is a failure state.
    check prompts.len == 2
    check scripted == @["probe", "sweep"]
    ## Champion #2 must be uploaded while daveey-1 is the active player, or
    ## submitting it as daveey-1 409s "already assigned to player".
    check policies[1]["player"].getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check not policies[0].hasKey("player")
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()
