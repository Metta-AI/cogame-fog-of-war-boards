## Fog-of-War Boards prompt or scripted player.
##
## Prompt policies deliver PLAYER_PROMPT and idle until the final frame.
##
## PLAYER_SCRIPTED=probe|sweep registers the seat as one of the two
## built-in baselines instead: the server plays it deterministically, no
## LLM. `1`, `true` and `yes` mean `probe`.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <fog-of-war-boards-image> --name my-fog \
##     --run /bin/fog-of-war-boards-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, math, monotimes, os, strutils, times],
  bitworld/[native_stop, native_websocket]

const DefaultPrompt = "You can only see your own stones. Every ply, write " &
  "down what you have proven about the opponent and what you merely " &
  "suspect, then play the cell that most shortens your own connection " &
  "while sitting on the route they most likely need. Never attempt a cell " &
  "you already know is theirs. Reply with only the JSON object."

when isMainModule:
  installNativeStopHandlers()
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scriptedEnv = getEnv("PLAYER_SCRIPTED").strip()
  ## `1`, `true` and `yes` are synonyms for the default baseline; anything
  ## else names one (`probe` or `sweep`) and the server validates it.
  let scripted =
    if scriptedEnv.len == 0 or scriptedEnv.toLowerAscii() in
        ["0", "false", "no"]:
      ""
    elif scriptedEnv.toLowerAscii() in ["1", "true", "yes"]:
      "probe"
    else:
      scriptedEnv.toLowerAscii()

  let timeout = parseFloat(getEnv("COWORLD_TIMEOUT_SECONDS", "1200"))
  if timeout <= 0 or classify(timeout) in {fcNan, fcInf, fcNegInf}:
    quit("player timeout must be finite and positive", 1)
  let started = getMonoTime()
  let deadline = started + initDuration(nanoseconds = int64(timeout * 1_000_000_000))
  let connection = connectNativeWebSocket(url,
    min(deadline, started + initDuration(seconds = 30)), 16 * 1024 * 1024)
  case connection.kind
  of wsInterrupted, wsDeadline: quit(0)
  of wsReady: discard
  else: quit("player connection failed", 1)
  let socket = connection.socket
  var registered = false
  try:
    while true:
      let received = receiveNativeText(socket, deadline)
      case received.kind
      of wsClosed, wsInterrupted, wsDeadline: break
      of wsMessage: discard
      else: raise newException(ValueError, "player transport failed")
      let payload = parseJson(received.data)
      if payload.kind != JObject or not payload.hasKey("type") or payload["type"].kind != JString:
        raise newException(ValueError, "invalid player protocol packet")
      case payload["type"].getStr()
      of "welcome":
        if registered: raise newException(ValueError, "duplicate player welcome")
        let registration = $ %*{"type": "prompt", "prompt": prompt,
          "scripted": (if scripted.len > 0: %scripted else: %false)}
        let sent = sendNativeText(socket, registration, deadline)
        case sent.kind
        of wsInterrupted, wsDeadline: break
        of wsReady: registered = true
        else: raise newException(ValueError, "player registration failed")
      of "state": discard
      of "final": break
      else: raise newException(ValueError, "unexpected player protocol packet")
  finally:
    closeNativeWebSocket(socket)
