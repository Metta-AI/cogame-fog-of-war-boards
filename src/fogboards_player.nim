## Fog-of-War Boards player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default fog strategy), then idles until the final frame. All of the
## actual decision making happens inside the game server, which sends this
## seat's prompt plus its own view of the board to Claude on every ply it
## has to move.
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
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = "You can only see your own stones. Every ply, write " &
  "down what you have proven about the opponent and what you merely " &
  "suspect, then play the cell that most shortens your own connection " &
  "while sitting on the route they most likely need. Never attempt a cell " &
  "you already know is theirs. Reply with only the JSON object."

when isMainModule:
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

  proc promptFrame(): string =
    if scripted.len > 0:
      $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}
    else:
      $ %*{"type": "prompt", "prompt": prompt, "scripted": false}

  echo "fogboards player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "fogboards player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky RAISES on a close frame or a truncated read (only a timeout
  ## returns none), and the game's quit(0) can outrun the flushed final
  ## frame — so a dead socket is a normal end of episode, not a failure.
  ## Without this the player container exits 1 intermittently and hosted
  ## certification fails with player_error (raid 0.1.3 -> 0.1.4).
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "fogboards player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "fogboards player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first
          ## send raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "fogboards player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "fogboards player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "fogboards player: socket closed (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
