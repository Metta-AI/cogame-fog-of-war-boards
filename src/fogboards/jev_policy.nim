## Jev ranks the acting seat's legal Fog-of-War Boards actions.

import std/[json, os, strutils, times]
import curly

var lastCall: float

proc choiceCriteria(options: JsonNode): JsonNode =
  result = newJObject()
  for option in options:
    let name = option.getStr()
    result[name] = %name

proc bestChoice(answer, criteria: JsonNode): string =
  if answer["type"].getStr() != "choice" or
      answer["probabilities"].len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for name, node in answer["probabilities"].pairs:
    if not criteria.hasKey(name):
      raise newException(ValueError, "Jev returned an unknown cell")
    let probability = node.getFloat()
    if probability < 0 or probability > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += probability
    if probability > best:
      best = probability
      result = name
  if abs(total - 1) > criteria.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseAction*(observation: JsonNode, guidance: string): JsonNode =
  let cells = choiceCriteria(observation["legalAttempts"])
  if cells.len == 0:
    raise newException(ValueError, "Jev received no legal cell")
  var questions = %*{
    "cell": {"type": "choice", "instructions":
      "Choose one exact legal cell attempt.", "criteria": cells}
  }
  let anchors = choiceCriteria(observation["legalSenseAnchors"])
  if anchors.len > 0:
    questions["sense"] = %*{
      "type": "choice", "instructions":
        "Choose one exact legal reconnaissance anchor before the attempt.",
      "criteria": anchors
    }

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint, model, key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Fogboards Jev has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Fog-of-War Boards. Choose legal actions " &
      "using only your seat observation. In Phantom Tic-Tac-Toe, complete " &
      "a row, column, or diagonal. In Dark Hex, RED connects left to right " &
      "and BLUE connects bottom to top. A collision reveals an opponent " &
      "stone without placing yours. " & guidance &
      "\nYour seat observation:\n" & $observation,
    "questions": questions
  }
  let elapsed = epochTime() - lastCall
  if lastCall > 0 and elapsed < 2.1:
    sleep(((2.1 - elapsed) * 1000).int)
  lastCall = epochTime()
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 18)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  result = %*{
    "type": "action",
    "cell": bestChoice(payload["answers"]["cell"], cells)
  }
  if anchors.len > 0:
    result["sense"] = %bestChoice(payload["answers"]["sense"], anchors)
  echo "Fogboards Jev: action ", result,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
