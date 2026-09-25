"""Run one mixed Jev/scripted container episode for each Fogboards variant."""

import json
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class MockSystemOne(BaseHTTPRequestHandler):
    actions: list[tuple[str, str | None]] = []
    direct = False

    def do_POST(self) -> None:
        assert self.path == "/v1/systemone"
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        observation = json.loads(request["state"].split("Your seat observation:\n", 1)[1])
        assert observation["game"] == "fog-of-war-boards"
        assert "board" not in observation and "seed" not in observation
        assert "policyNames" not in observation
        own = set(observation["ownStones"])
        proven = set(observation["provenOpponentStones"])
        assert not own & proven
        assert not (own | proven) & set(observation["legalAttempts"])
        assert len(observation["legalAttempts"]) > 0
        questions = request["questions"]
        cell = next(iter(questions["cell"]["criteria"]))
        sense = next(iter(questions["sense"]["criteria"])) if "sense" in questions else None
        assert cell in observation["legalAttempts"]
        assert sense is None or sense in observation["legalSenseAnchors"]
        self.actions.append((cell, sense))
        if self.direct:
            assert self.headers.get("authorization") == "Bearer mock"
            assert self.headers.get("x-coworld-player-slot") is None
        else:
            assert self.headers.get("x-coworld-player-slot") == str(observation["slot"])
            assert self.headers.get("authorization") is None
        answers = {}
        for name, question in questions.items():
            selected = cell if name == "cell" else sense
            answers[name] = {
                "type": "choice", "confidence": 1.0,
                "probabilities": {option: float(option == selected)
                                  for option in question["criteria"]},
            }
        data = json.dumps({"model": "mock-jev", "answers": answers,
                           "usage": {"input_tokens": 1, "output_tokens": 1}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:
        pass


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def main() -> None:
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    image = sys.argv[2] if len(sys.argv) > 2 else "fogboards-jev-25001:local"
    variants = json.loads(Path("coworld_manifest_template.json").read_text())["variants"]
    mock = ThreadingHTTPServer(("0.0.0.0", 0), MockSystemOne)
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    try:
        for index, variant in enumerate(variants):
            MockSystemOne.actions = []
            MockSystemOne.direct = index == 0
            name = variant["id"]
            episode = output / name
            episode.mkdir(exist_ok=True)
            config = dict(variant["game_config"])
            config.update({
                "players": [{"name": "Jev" if slot == index % 2 else "Probe"}
                            for slot in range(2)],
                "tokens": ["fog-0", "fog-1"], "seed": 7,
                "maxPlies": 8, "turnDelayMs": 0,
                "llmTimeoutSeconds": 20,
                "player_connect_timeout_seconds": 60,
            })
            (episode / "config.json").write_text(json.dumps(config))
            port = free_port()
            game_name = f"fogboards-jev-smoke-{name}"
            game_log = (episode / "game.log").open("w")
            game = subprocess.Popen([
                "docker", "run", "--rm", "--platform=linux/amd64",
                "--add-host=host.docker.internal:host-gateway",
                "--name", game_name, "-p", f"{port}:8080",
                "-v", f"{episode}:/coworld", "-e", "COGAME_HOST=0.0.0.0",
                "-e", "COGAME_PORT=8080",
                "-e", "COGAME_CONFIG_URI=file:///coworld/config.json",
                "-e", "COGAME_RESULTS_URI=file:///coworld/results.json",
                "-e", "COGAME_SAVE_REPLAY_URI=file:///coworld/replay.json",
                image, "/bin/fog-of-war-boards",
            ], stdout=game_log, stderr=subprocess.STDOUT)
            players = []
            try:
                ready = False
                for _ in range(150):
                    if game.poll() is not None:
                        break
                    ready = subprocess.run([
                        "curl", "-fsS", "--max-time", "1",
                        f"http://127.0.0.1:{port}/healthz",
                    ], stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL).returncode == 0
                    if ready:
                        break
                    time.sleep(0.1)
                assert ready and game.poll() is None, (episode / "game.log").read_text()
                for slot in range(2):
                    env = ["-e", f"COWORLD_PLAYER_WS_URL=ws://host.docker.internal:{port}/player?slot={slot}&token=fog-{slot}"]
                    if slot == index % 2:
                        env += ["-e", "PLAYER_JEV=1"]
                        if MockSystemOne.direct:
                            env += ["-e", f"METTA_CAPTURE_URL=http://host.docker.internal:{mock.server_port}",
                                    "-e", "METTA_CAPTURE_KEY=mock"]
                        else:
                            env += ["-e", f"AWS_ENDPOINT_URL_BEDROCK_RUNTIME=http://host.docker.internal:{mock.server_port}"]
                    else:
                        env += ["-e", "PLAYER_SCRIPTED=probe"]
                    log = (episode / f"player-{slot}.log").open("w")
                    player = subprocess.Popen([
                        "docker", "run", "--rm", "--platform=linux/amd64",
                        "--add-host=host.docker.internal:host-gateway",
                        *env, image, "/bin/fog-of-war-boards-player",
                    ], stdout=log, stderr=subprocess.STDOUT)
                    players.append((player, log))
                for _ in range(1200):
                    if (episode / "results.json").exists() and (episode / "replay.json").exists():
                        break
                    if game.poll() is not None:
                        break
                    time.sleep(0.1)
                assert (episode / "results.json").exists(), (episode / "game.log").read_text()
                assert (episode / "replay.json").exists(), (episode / "game.log").read_text()
                for player, _ in players:
                    assert player.wait(timeout=10) == 0
                results = json.loads((episode / "results.json").read_text())
                replay = json.loads((episode / "replay.json").read_text())
                jev = index % 2
                assert results["fallbacks"][jev] == 0
                events = [e for e in replay["events"]
                          if e["kind"] == "attempt" and e["seat"] == jev]
                assert len(events) == len(MockSystemOne.actions) > 0
                for event, (cell, sense) in zip(events, MockSystemOne.actions, strict=True):
                    assert event["cell"] == cell
                    assert not event["scripted"] and not event["fellBack"]
                senses = [e["anchor"] for e in replay["events"]
                          if e["kind"] == "sense" and e["seat"] == jev]
                assert senses == [sense for _, sense in MockSystemOne.actions if sense]
                print(f"{name}: {len(events)} accepted Jev actions, 0 fallback")
            finally:
                subprocess.run(["docker", "stop", "--time", "1", game_name],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for player, log in players:
                    if player.poll() is None:
                        player.terminate()
                        player.wait(timeout=5)
                    log.close()
                game_log.close()
    finally:
        mock.shutdown()
        mock.server_close()


if __name__ == "__main__":
    main()
