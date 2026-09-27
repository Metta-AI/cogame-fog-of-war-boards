"""Prove that a normal player can use a sense result before choosing a cell."""

import asyncio
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import websockets


ROOT = Path(__file__).resolve().parents[1]
GAME = Path(sys.argv[1]).resolve()
VARIANTS = ("dark-hex-5", "recon-hex-5")


async def play(slot: int, port: int, recon: bool, phases: dict[int, list[str]]) -> None:
    url = f"ws://127.0.0.1:{port}/player?slot={slot}&token=seat-{slot}"
    async with websockets.connect(url) as socket:
        register = json.dumps({"type": "register", "control": "external"})
        await socket.send(register)
        async for raw in socket:
            packet = json.loads(raw)
            if packet["type"] == "welcome":
                assert packet["protocol"] == "fogboards.player.v3"
                await socket.send(register)
            elif packet["type"] == "observation":
                view = packet["observation"]
                assert view["first"] == 0 and isinstance(view["ownProbes"], int)
                assert view["opponentName"] != view["name"]
                phase = packet["phase"]
                phases[slot].append(phase)
                if phase == "sense":
                    assert recon
                    anchor = "a2" if slot == 0 and view["ply"] == 2 else view["legalSenseAnchors"][0]
                    reply = {"type": "action", "id": packet["id"], "sense": anchor}
                else:
                    assert phase == "attempt"
                    if recon and slot == 0 and view["ply"] == 2:
                        assert "b2" in view["provenOpponentStones"]
                        assert "b2" not in view["legalAttempts"]
                        await socket.send(json.dumps({
                            "type": "action", "id": packet["id"], "cell": "b2",
                        }))
                    cell = (
                        "a1" if slot == 0 and view["ply"] == 0 else
                        "b2" if slot == 1 and view["ply"] == 1 else
                        view["legalAttempts"][0]
                    )
                    reply = {"type": "action", "id": packet["id"], "cell": cell}
                await socket.send(json.dumps(reply))
            elif packet["type"] == "final":
                return
    raise RuntimeError(f"seat {slot} closed before final")


async def run_players(port: int, recon: bool, phases: dict[int, list[str]]) -> None:
    started = time.monotonic()
    while True:
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                break
        if time.monotonic() - started > 10:
            raise TimeoutError("game did not open its player socket")
        await asyncio.sleep(0.05)
    await asyncio.wait_for(
        asyncio.gather(play(0, port, recon, phases), play(1, port, recon, phases)),
        timeout=80,
    )


def main() -> None:
    manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    for variant in VARIANTS:
        recon = variant == "recon-hex-5"
        config = next(row["game_config"] for row in manifest["variants"] if row["id"] == variant).copy()
        config.update({
            "tokens": ["seat-0", "seat-1"], "players": [{"name": "seat-0"}, {"name": "seat-1"}],
            "seed": 21, "first": 0, "maxPlies": 4, "turnDelayMs": 0,
            "llmTimeoutSeconds": 10, "player_connect_timeout_seconds": 30,
        })
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "config.json").write_text(json.dumps(config))
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("ANTHROPIC_", "AWS_", "TYPESAFE_"))}
            env.update({
                "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
                "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
                "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
                "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
                "COGAME_PLAYER_FAILURE_URI": (output / "failure.json").as_uri(),
            })
            game = subprocess.Popen([str(GAME)], cwd=ROOT, env=env)
            phases: dict[int, list[str]] = {0: [], 1: []}
            try:
                asyncio.run(run_players(port, recon, phases))
                assert game.wait(timeout=35) == 0
                results = json.loads((output / "results.json").read_text())
                replay = json.loads((output / "replay.json").read_text())
                assert results["fallbacks"] == [0, 0]
                assert results["plies"] == 4
                assert sum(event["kind"] == "attempt" for event in replay["events"]) == 4
                assert sum(event["kind"] == "sense" for event in replay["events"]) == (4 if recon else 0)
                expected = (["sense", "attempt"] if recon else ["attempt"]) * 2
                assert all(seen == expected for seen in phases.values())
                print(variant, results["plies"], results["fallbacks"], phases)
            finally:
                if game.poll() is None:
                    game.terminate()
                    game.wait(timeout=5)


if __name__ == "__main__":
    main()
