## Config, events and enums for Fog-of-War Boards.
##
## Cells travel through every recorded byte as ALGEBRAIC strings ("c3"),
## never as internal indices, so a replay stays readable and a future
## board size cannot silently reinterpret old bytes.

import std/[json, strutils]

type
  FogError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  Mode* = enum
    mPhantomTtt = "phantom-ttt"
    mDarkHex = "dark-hex"

  GameConfig* = object
    tokens*: seq[string]          ## connection tokens, injected by the runner
    players*: seq[PlayerConfig]   ## policy display names, by slot
    mode*: Mode
    size*: int                    ## 3 (ttt) | 4 | 5 (hex)
    abrupt*: bool                 ## true: a collision ends the turn
    sense*: int                   ## 0 = no reconnaissance; 2 = a 2x2 window
    first*: int                   ## the seat that moves on ply 0
    maxPlies*: int
    seed*: int
    episodeTimeoutSeconds*: int   ## assumed platform kill time when env is silent
    plySpacingSeconds*: int       ## 0 => derive 4 (the Bedrock sidecar floor)
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*, llmTimeoutSeconds*: int
    sampled*: bool                ## true once the budget fit has been applied

  Occupant* = enum
    ocEmpty = "empty", ocSeat0 = "seat0", ocSeat1 = "seat1"

  EventKind* = enum
    evStart = "start"
    evSense = "sense"
    evAttempt = "attempt"
    evWin = "win"
    evEnd = "end"

  GameEvent* = object
    kind*: EventKind
    round*: int             ## the PLY index (0-based); start: -1
    seat*: int              ## sense/attempt/win: the actor; -1 otherwise
    anchor*: string         ## sense: the bottom-left cell of the window
    cell*: string           ## attempt: the named cell
    outcome*: string        ## attempt: "placed" | "occupied" (JSON: "result")
    say*: string            ## attempt: the mover's spectator line
    notes*: string          ## attempt: the mover's private notes
    guess*: seq[string]     ## attempt: cells the mover guesses are theirs
    scripted*: bool         ## attempt: decided by a scripted baseline
    fellBack*: bool         ## attempt: an LLM seat that fell back
    how*: string            ## win: "connection" | "line"
    path*: seq[string]      ## win: the connecting / completed cells
    reason*: string         ## end: "complete" | "deadline"
    ending*: string         ## end: connection|line|board-full|ply-cap|wall-clock
    scores*: seq[float]     ## end: one per seat

const
  Seats* = 2
  MinSize* = 3
  MaxSize* = 7
  MinPlies* = 4
  MaxPliesCap* = 120

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    mode: mDarkHex,
    size: 5,
    abrupt: true,
    sense: 0,
    first: 0,
    maxPlies: 50,
    seed: 0,
    episodeTimeoutSeconds: 1200,
    plySpacingSeconds: 0,
    turnDelayMs: 250,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 30
  )

proc validate*(config: GameConfig) =
  ## Every rejection names the field and the value: a hosted episode that
  ## dies on a bad variant should say which knob was wrong.
  if config.players.len != Seats:
    raise newException(FogError,
      "fog-of-war-boards needs exactly " & $Seats & " players, got " &
        $config.players.len)
  if config.size < MinSize or config.size > MaxSize:
    raise newException(FogError,
      "size must be " & $MinSize & ".." & $MaxSize & ", got " & $config.size)
  if config.mode == mPhantomTtt and config.size != 3:
    raise newException(FogError,
      "phantom-ttt is played on size 3, got " & $config.size)
  if config.sense < 0 or config.sense > 3:
    raise newException(FogError, "sense must be 0..3, got " & $config.sense)
  if config.sense > 0 and config.sense > config.size - 1:
    raise newException(FogError,
      "a sense window of " & $config.sense & " does not fit on a " &
        $config.size & " board")
  if config.maxPlies < MinPlies or config.maxPlies > MaxPliesCap:
    raise newException(FogError,
      "maxPlies must be " & $MinPlies & ".." & $MaxPliesCap & ", got " &
        $config.maxPlies)
  if config.first < 0 or config.first >= Seats:
    raise newException(FogError, "first must be 0..1, got " & $config.first)

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(FogError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("mode"):
    let mode = node["mode"].getStr()
    case mode
    of "phantom-ttt": config.mode = mPhantomTtt
    of "dark-hex": config.mode = mDarkHex
    else:
      raise newException(FogError, "unknown mode: " & mode)
  if node.hasKey("size"):
    config.size = node["size"].getInt()
  if node.hasKey("abrupt"):
    config.abrupt = node["abrupt"].getBool()
  if node.hasKey("sense"):
    config.sense = node["sense"].getInt()
  if node.hasKey("first"):
    config.first = node["first"].getInt()
  if node.hasKey("maxPlies"):
    config.maxPlies = node["maxPlies"].getInt()
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("plySpacingSeconds"):
    config.plySpacingSeconds = node["plySpacingSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  config.validate()
