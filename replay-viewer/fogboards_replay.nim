## Fog-of-War Boards static replay viewer, wasm side.
##
## JS hands the raw replay bytes to fog_load_replay; this module parses
## them with the SAME sim code the game server runs, re-derives the
## per-event board states, and exposes the enriched payload (identical
## shape to the game's /replay websocket message) for the shared
## renderer.js to draw. Nothing about the episode is recomputed on a
## server: everything the viewer needs is in the bytes.

import
  std/json,
  fogboards/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc fogLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "fog_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    var config = defaultGameConfig()
    let node = replay["config"]
    config.mode =
      if node{"mode"}.getStr("dark-hex") == "phantom-ttt": mPhantomTtt
      else: mDarkHex
    config.size = node{"size"}.getInt(5)
    config.abrupt = node{"abrupt"}.getBool(true)
    config.sense = node{"sense"}.getInt(0)
    config.first = node{"first"}.getInt(0)
    config.seed = node{"seed"}.getInt(0)
    config.maxPlies = node{"maxPlies"}.getInt(50)
    ## The replay carries the episode's fitted cap; never re-fit it.
    config.sampled = true
    for name in replay["names"]:
      config.players.add(PlayerConfig(name: name.getStr()))
    var events: seq[GameEvent]
    for event in replay["events"]:
      events.add(eventFromJson(event))
    var states = newJArray()
    for frame in replayMatch(config, events):
      states.add(frame.boardStateJson())
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("fogboards.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": replay{"results"},
      "states": states
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc fogPayloadPointer(): ptr uint8 {.exportc: "fog_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc fogPayloadLength(): cint {.exportc: "fog_payload_len", cdecl.} =
  cint(payload.len)

proc fogErrorPointer(): ptr uint8 {.exportc: "fog_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc fogErrorLength(): cint {.exportc: "fog_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals
  ## stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
