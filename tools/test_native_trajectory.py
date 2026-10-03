"""Real game/prompt-player sockets, native fixture headers, authoritative phase capture."""

import contextlib
import http.server
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER = (str(Path(arg).resolve()) for arg in sys.argv[1:3])
manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
for variant in manifest["variants"]:
    if os.environ.get("FOG_NATIVE_FIXTURE_VARIANT") and variant["id"] != os.environ["FOG_NATIVE_FIXTURE_VARIANT"]:
        continue
    for failure in (None, "sense", "attempt", "sampled", "greedy-null", "greedy-tokens"):
        if failure in {"sampled", "greedy-null", "greedy-tokens"} and variant["id"] != "recon-hex-5":
            continue
        if failure == "sense" and not variant["game_config"].get("sense", 0):
            continue
        calls = {}

        class Messages(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["content-length"])))
                assert self.path == "/v1/messages" and request["temperature"] == (1 if failure == "sampled" else 0)
                slot = int(self.headers["X-Coworld-Player-Slot"])
                user = request["messages"][0]["content"]
                phase = "sense" if user.rsplit("Reply with ONLY ", 1)[1].startswith('{"sense"') else "attempt"
                label = "YOUR LEGAL SENSE ANCHORS:" if phase == "sense" else "YOUR LEGAL ATTEMPTS:"
                legal = next(line for line in user.splitlines() if line.startswith(label))
                cell = re.findall(r"\b[a-e][1-5]\b", legal)[0]
                action = {"sense": cell} if phase == "sense" else {
                    "cell": cell, "notes": "private-notes-fixture", "say": "public speech", "guess": []}
                text = "invalid phase action" if slot == 0 and failure == phase else json.dumps(action)
                call_id = str(uuid.uuid4())
                body = {"id": "msg_" + call_id, "model": "mock/served",
                        "content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}
                if failure in {"sampled", "greedy-tokens"}:
                    body["sampling_evidence"] = {
                        "policy_revision": "a" * 64, "tokenizer_revision": "b" * 64,
                        "chat_template": "fixture-template", "sampling": "full_softmax_temperature_one" if failure == "sampled" else "greedy",
                        "enable_thinking": False, "max_new_tokens": request["max_tokens"],
                        "max_sequence_length": 4096, "sampling_seed": 7, "eos_token_ids": [4],
                        "prompt_token_ids": [1, 2], "completion_token_ids": [3, 4],
                        "behavior_log_probs": [-0.5, -0.3] if failure == "sampled" else None,
                        "stop_reason": "eos", "response": text}
                if failure == "greedy-null": body["sampling_evidence"] = None
                calls[call_id] = (request, body, phase)
                encoded = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(encoded)))
                self.send_header("X-Softmax-Llm-Call-Id", call_id)
                if failure in {"sampled", "greedy-tokens"}:
                    self.send_header("X-Coworld-Checkpoint-Sha256", "a" * 64)
                    self.send_header("X-Coworld-Tokenizer-Sha256", "b" * 64)
                    self.send_header("X-Coworld-Chat-Template-Sha256", "c" * 64)
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, *_args):
                pass

        provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Messages)
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        if len(sys.argv) == 4:
            target = Path(sys.argv[3]) / (variant["id"] + "-" + (failure or "accepted"))
            target.mkdir(parents=True, mode=0o700, exist_ok=False)
            output_context = contextlib.nullcontext(target)
        else: output_context = tempfile.TemporaryDirectory()
        with output_context as directory:
            output = Path(directory)
            with socket.socket() as reserve:
                reserve.bind(("127.0.0.1", 0))
                port = reserve.getsockname()[1]
            config = {**variant["game_config"], "seed": 7,
                      "players": [{"name": "red"}, {"name": "blue"}], "tokens": ["t0", "t1"],
                      "turnDelayMs": 0, "llmTimeoutSeconds": 2, "episodeTimeoutSeconds": 120}
            (output / "config.json").write_text(json.dumps(config))
            source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            env = {**os.environ, "COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
                   "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
                   "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
                   "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
                   "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
                   "COWORLD_EPISODE_ID": str(uuid.uuid4()), "COWORLD_GAME_VERSION": "native-fixture-v3",
                   "COWORLD_SOURCE_REVISION": source, "COWORLD_LLM_TEMPERATURE": "1" if failure == "sampled" else "0",
                   "COWORLD_LLM_PLY_SPACING_SECONDS": "0",
                   "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
                   "COWORLD_LLM_MODEL": "mock/fixture", "PLAYER_PROMPT": "private-guidance-fixture",
                   "PLAYER_SCRIPTED": ""}
            processes, logs = [], []
            try:
                log = (output / "game.log").open("w")
                logs.append(log)
                game = subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log)
                processes.append(game)
                deadline = time.monotonic() + 10
                while True:
                    with socket.socket() as probe:
                        ready = probe.connect_ex(("127.0.0.1", port)) == 0
                    if ready:
                        break
                    assert game.poll() is None, (output / "game.log").read_text()
                    assert time.monotonic() < deadline
                    time.sleep(0.02)
                for slot in range(2):
                    player_env = {**env, "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token=t{slot}"}
                    log = (output / f"player-{slot}.log").open("w")
                    logs.append(log)
                    processes.append(subprocess.Popen([PLAYER], cwd=ROOT, env=player_env, stdout=log, stderr=log))
                assert game.wait(timeout=30) == 0, (output / "game.log").read_text()
                for process in processes[1:]:
                    assert process.wait(timeout=5) == 0
                events = [json.loads(line) for line in (output / "trajectory.jsonl").read_text().splitlines()]
                decisions = events[:-1]
                assert events[-1]["status"] == "completed" and events[-1]["outcome"]["reason"] == "complete"
                assert events[-1]["source_revision"] == source
                joined = set()
                for decision in decisions:
                    phases = set()
                    for attempt in decision["attempts"]:
                        assert attempt["inference_mode"] == "text_action"
                        identity = attempt["platform_call_id"]
                        request, body, phase = calls[identity]
                        joined.add(identity)
                        phases.add(phase)
                        assert attempt["request"] == request and json.loads(attempt["raw_response"]) == body
                        assert "private-guidance-fixture" in attempt["prompt"][1]["content"]
                        assert attempt["model"] == "mock/served"
                        if failure in {"sampled", "greedy-tokens"}:
                            assert attempt["prompt_token_ids"] == [1, 2] and attempt["sampled_token_ids"] == [3, 4]
                            assert attempt["behavior_logprobs"] == ([-0.5, -0.3] if failure == "sampled" else None)
                            assert attempt["model_identity"] == "a" * 64
                            assert attempt["tokenizer_identity"] == "b" * 64
                            assert attempt["chat_template_sha256"] == "c" * 64
                        else: assert attempt["behavior_logprobs"] is None
                    phase, = phases
                    if decision["action_status"] == "accepted":
                        selected = next(a for a in decision["attempts"] if a["attempt_id"] == decision["selected_attempt_id"])
                        assert selected["accepted"] and selected["parsed_action"] == decision["executed_action"]
                    else:
                        assert decision["action_status"] == "fallback" and decision["fallback_origin"]
                        assert decision["selected_attempt_id"] is None
                        assert len(decision["attempts"]) == 2
                        assert all(not a["accepted"] and a["rejection_reason"] for a in decision["attempts"])
                        assert "Your previous reply was invalid" in decision["attempts"][1]["prompt"][1]["content"]
                    if config.get("sense", 0) and phase == "attempt":
                        assert " — you sensed " in decision["attempts"][0]["prompt"][1]["content"]
                assert joined == set(calls)
                for log in logs: log.flush()
                public_logs = "".join(path.read_text() for path in output.glob("*.log"))
                assert "private-guidance-fixture" not in public_logs and "private-notes-fixture" not in public_logs
                replay = (output / "replay.json").read_text()
                assert "private-guidance-fixture" not in replay and "private-notes-fixture" not in replay
                assert all(identity not in replay for identity in calls)
                assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
                print(variant["id"], failure or "accepted", len(decisions), "decisions", len(joined), "fixture joins", flush=True)
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)
                for log in logs:
                    log.close()
                provider.shutdown()
                provider.server_close()
