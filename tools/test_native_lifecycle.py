"""Stop the actual game-owned native reader before sealing its private episode."""

import base64
import http.server
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

GAME, PLAYER, OUTPUT = (Path(value).resolve() for value in sys.argv[1:4])
ROOT = Path(__file__).resolve().parents[1]
SOURCE = (
    os.environ["COWORLD_TEST_SOURCE_REVISION"]
    if "COWORLD_TEST_SOURCE_REVISION" in os.environ
    else subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
)

for case in (
    "started-sigterm",
    "partial-sigterm",
    "partial-sigint",
    "repair-deadline",
    "partial-http-sigterm",
    "partial-http-post-sigint",
    "partial-http-upload503",
    "completed-http-artifacts",
    "runtime-failure",
    "malformed-private-json",
    "malformed-private-schema",
    "paced-deadline",
):
    if (
        os.environ.get("FOG_LIFECYCLE_FIXTURE_CASE")
        and case != os.environ["FOG_LIFECYCLE_FIXTURE_CASE"]
    ):
        continue
    output = OUTPUT / case
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    entered = threading.Event()
    release = threading.Event()
    partial = b"\xffprivate-partial"
    call_id = str(uuid.uuid4())
    request_counts = [0, 0]
    artifacts = []

    class Messages(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            raw_body = self.rfile.read(int(self.headers["content-length"]))
            if self.path in {"/private", "/results", "/replay"}:
                artifacts.append((self.command, self.path, raw_body))
                self.send_response(503 if case == "partial-http-upload503" else 200)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            request = json.loads(raw_body)
            assert self.path == "/v1/messages" and self.headers[
                "X-Coworld-Player-Slot"
            ] in {"0", "1"}
            assert request["messages"][0]["content"]
            if case in {"malformed-private-json", "malformed-private-schema"}:
                body = (
                    b'{"private-schema-sentinel":'
                    if case == "malformed-private-json"
                    else json.dumps(
                        {
                            "model": "fixture/served",
                            "stop_reason": "end_turn",
                            "content": [
                                {
                                    "type": "text",
                                    "text": 123,
                                    "private": "private-schema-sentinel",
                                }
                            ],
                        }
                    ).encode()
                )
                self.send_response(200)
                self.send_header("content-length", str(len(body)))
                self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid4()))
                self.end_headers()
                self.wfile.write(body)
                entered.set()
                return
            if case in {"completed-http-artifacts", "paced-deadline"}:
                user = request["messages"][0]["content"]
                legal = next(
                    line
                    for line in user.splitlines()
                    if line.startswith("YOUR LEGAL ATTEMPTS:")
                )
                cell = re.findall(r"\b[a-e][1-5]\b", legal)[0]
                body = json.dumps(
                    {
                        "model": "fixture/served",
                        "stop_reason": "end_turn",
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(
                                    {"cell": cell, "say": "", "notes": "", "guess": []}
                                ),
                            }
                        ],
                    }
                ).encode()
                self.send_response(200)
                self.send_header("content-length", str(len(body)))
                self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid4()))
                self.end_headers()
                self.wfile.write(body)
                entered.set()
                return
            if case == "repair-deadline":
                slot = int(self.headers["X-Coworld-Player-Slot"])
                request_counts[slot] += 1
                if request_counts[slot] % 2:
                    time.sleep(3.25)
                    body = json.dumps(
                        {
                            "model": "fixture/served",
                            "stop_reason": "end_turn",
                            "content": [
                                {"type": "text", "text": "invalid phase action"}
                            ],
                        }
                    ).encode()
                    self.send_response(200)
                    self.send_header("content-length", str(len(body)))
                    self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid4()))
                    self.end_headers()
                    self.wfile.write(body)
                    return
            if case != "started-sigterm":
                self.send_response(200)
                self.send_header("content-length", str(len(partial) + 20))
                self.send_header("X-Softmax-Llm-Call-Id", call_id)
                self.send_header("X-Fixture", "private-header")
                self.end_headers()
                self.wfile.write(partial)
                self.wfile.flush()
            entered.set()
            release.wait(10)

        do_PUT = do_POST

        def log_message(self, *_args):
            pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Messages)
    thread = threading.Thread(target=provider.serve_forever)
    thread.start()
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    template = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    variant = next(
        value for value in template["variants"] if value["id"] == "dark-hex-5"
    )
    config = {
        **variant["game_config"],
        "seed": 7,
        "tokens": ["t0", "t1"],
        "players": [{"name": "red"}, {"name": "blue"}],
        "turnDelayMs": 0,
        "llmTimeoutSeconds": 3,
        "player_connect_timeout_seconds": 5,
        "episodeTimeoutSeconds": 120,
    }
    if case == "repair-deadline":
        config.update({"maxPlies": 4, "llmTimeoutSeconds": 5})
    if case in {
        "completed-http-artifacts",
        "malformed-private-json",
        "malformed-private-schema",
    }:
        config["maxPlies"] = 4
    (output / "config.json").write_text(json.dumps(config))
    env = {
        **os.environ,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": str(uuid.uuid4()),
        "COWORLD_GAME_VERSION": "native-lifecycle-fixture",
        "COWORLD_SOURCE_REVISION": SOURCE,
        "COWORLD_LLM_PLY_SPACING_SECONDS": "0",
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
        "COWORLD_LLM_MODEL": "fixture/requested",
        "PLAYER_SCRIPTED": "",
    }
    if "http" in case:
        env.update(
            {
                "COGAME_SAVE_TRAJECTORY_URI": f"http://127.0.0.1:{provider.server_port}/private",
                "COGAME_RESULTS_URI": f"http://127.0.0.1:{provider.server_port}/results",
                "COGAME_SAVE_REPLAY_URI": f"http://127.0.0.1:{provider.server_port}/replay",
                "COGAME_SAVE_TRAJECTORY_METHOD": "POST"
                if case == "partial-http-post-sigint"
                else "PUT",
            }
        )
    if case == "paced-deadline":
        config.update({"maxPlies": 4, "llmTimeoutSeconds": 5})
        (output / "config.json").write_text(json.dumps(config))
        env.update(
            {"COWORLD_TIMEOUT_SECONDS": "20", "COWORLD_LLM_PLY_SPACING_SECONDS": "30"}
        )
    if case == "runtime-failure":
        env["COWORLD_LLM_PLY_SPACING_SECONDS"] = "invalid-spacing-config"
    processes, logs = [], []
    try:
        game_log = (output / "game.log").open("w")
        logs.append(game_log)
        game = subprocess.Popen(
            [str(GAME)], cwd=ROOT, env=env, stdout=game_log, stderr=game_log
        )
        processes.append(game)
        ready_deadline = time.monotonic() + 5
        while True:
            with socket.socket() as probe:
                ready = probe.connect_ex(("127.0.0.1", port)) == 0
            if ready:
                break
            assert game.poll() is None and time.monotonic() < ready_deadline
            time.sleep(0.02)
        for seat in range(2):
            player_log = (output / f"player-{seat}.log").open("w")
            logs.append(player_log)
            player_env = {
                **env,
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
            }
            processes.append(
                subprocess.Popen(
                    [str(PLAYER)],
                    cwd=ROOT,
                    env=player_env,
                    stdout=player_log,
                    stderr=player_log,
                )
            )
        if case != "runtime-failure":
            assert entered.wait(5), "game-owned HTTP request was not observed"
        time.sleep(0.05)
        stopped_at = time.monotonic()
        if case not in {
            "repair-deadline",
            "completed-http-artifacts",
            "runtime-failure",
            "malformed-private-json",
            "malformed-private-schema",
            "paced-deadline",
        }:
            game.send_signal(
                signal.SIGINT
                if case in {"partial-sigint", "partial-http-post-sigint"}
                else signal.SIGTERM
            )
        exit_code = game.wait(
            timeout=60
            if case
            in {
                "repair-deadline",
                "completed-http-artifacts",
                "malformed-private-json",
                "malformed-private-schema",
                "paced-deadline",
            }
            else 5
        )
        assert (
            (exit_code != 0)
            if case in {"partial-http-upload503", "runtime-failure"}
            else (exit_code == 0)
        ), exit_code
        elapsed = time.monotonic() - stopped_at
        for player in processes[1:]:
            assert player.wait(timeout=1) == 0
        if "http" in case:
            expected_paths = (
                ["/private", "/results", "/replay"]
                if case == "completed-http-artifacts"
                else ["/private"]
            )
            assert [path for _, path, _ in artifacts] == expected_paths
            assert artifacts[0][0] == env["COGAME_SAVE_TRAJECTORY_METHOD"]
            raw_events = artifacts[0][2].decode()
            (output / "received-private.jsonl").write_text(raw_events)
            (output / "received-private.jsonl").chmod(0o600)
        else:
            raw_events = (output / "trajectory.jsonl").read_text()
        events = [json.loads(line) for line in raw_events.splitlines()]
        episode = events[-1]
        if case == "paced-deadline":
            assert (
                episode["status"] == "truncated"
                and episode["outcome"]["reason"] == "deadline"
            )
            assert len(events[:-1]) == 1 and events[0]["selected_attempt_id"]
            assert 18 <= elapsed <= 21, elapsed
            (output / "proof.json").write_text(
                json.dumps(
                    {
                        "case": case,
                        "elapsed_seconds": elapsed,
                        "whole_budget_seconds": 20,
                        "scope": "fixture-only",
                        "source_revision": SOURCE,
                    }
                )
                + "\n"
            )
            print(
                case,
                "no post-pacing expired action; terminal grace clipped",
                elapsed,
                flush=True,
            )
            continue
        if case in {"malformed-private-json", "malformed-private-schema"}:
            assert episode["status"] == "completed" and len(events[:-1]) == 4
            for decision in events[:-1]:
                assert (
                    decision["action_status"] == "fallback"
                    and decision["selected_attempt_id"] is None
                )
                assert len(decision["attempts"]) == 2
                for attempt in decision["attempts"]:
                    assert not attempt["accepted"] and attempt["response"] is None
                    assert "private-schema-sentinel" in attempt["raw_response"]
                    assert (
                        attempt["response_complete"] is True
                        and attempt["response_reader_joined"] is True
                    )
                    assert (
                        base64.b64decode(attempt["response_body_b64"]).decode()
                        == attempt["raw_response"]
                    )
            for log in logs:
                log.flush()
            assert all(
                "private-schema-sentinel" not in path.read_text()
                for path in output.glob("*.log")
            )
            assert "private-schema-sentinel" not in (output / "replay.json").read_text()
            (output / "proof.json").write_text(
                json.dumps(
                    {
                        "case": case,
                        "private_attempts": 8,
                        "scope": "fixture-only",
                        "source_revision": SOURCE,
                    }
                )
                + "\n"
            )
            print(
                case,
                "received bytes private; no targets or public error sentinel",
                flush=True,
            )
            continue
        if case == "runtime-failure":
            assert (
                episode["status"] == "failed"
                and episode["participant_outcomes"] is None
            )
            assert len(events) == 1 and not artifacts
            assert (
                not (output / "results.json").exists()
                and not (output / "replay.json").exists()
            )
            (output / "proof.json").write_text(
                json.dumps(
                    {
                        "case": case,
                        "exit_code": exit_code,
                        "scope": "fixture-only",
                        "source_revision": SOURCE,
                    }
                )
                + "\n"
            )
            print(
                case, "private Failed checkpoint then propagated exception", flush=True
            )
            continue
        if case == "completed-http-artifacts":
            assert episode["status"] == "completed" and len(events[:-1]) == 4
            assert all(decision["selected_attempt_id"] for decision in events[:-1])
            assert json.loads(artifacts[1][2])["reason"] == "complete"
            (output / "proof.json").write_text(
                json.dumps(
                    {
                        "case": case,
                        "artifact_paths": expected_paths,
                        "scope": "fixture-only HTTP",
                        "source_revision": SOURCE,
                    }
                )
                + "\n"
            )
            print(case, "private-first then public artifacts", flush=True)
            continue
        if case == "repair-deadline":
            assert episode["status"] == "completed"
            decisions = events[:-1]
            assert len(decisions) == 4 and request_counts == [4, 4]
            for decision in decisions:
                assert (
                    decision["action_status"] == "fallback"
                    and decision["selected_attempt_id"] is None
                )
                invalid, timed_out = decision["attempts"]
                assert invalid["response_complete"] is True
                assert (
                    timed_out["response_complete"] is False
                    and timed_out["response_reader_joined"] is True
                )
                assert base64.b64decode(timed_out["response_body_b64"]) == partial
                assert not invalid["accepted"] and not timed_out["accepted"]
                phase_ms = invalid["latency_ms"] + timed_out["latency_ms"]
                assert 4800 <= phase_ms <= 5250, phase_ms
            (output / "proof.json").write_text(
                json.dumps(
                    {
                        "case": case,
                        "configured_phase_ms": 5000,
                        "phase_latencies_ms": [
                            sum(
                                attempt["latency_ms"]
                                for attempt in decision["attempts"]
                            )
                            for decision in decisions
                        ],
                        "scope": "fixture-only",
                        "source_revision": SOURCE,
                    }
                )
                + "\n"
            )
            print(case, "one shared 5000ms repair budget", flush=True)
            continue
        assert (
            episode["status"] == "truncated" and episode["participant_outcomes"] is None
        )
        assert (
            not (output / "results.json").exists()
            and not (output / "replay.json").exists()
        )
        decisions = [event for event in events if event["event_type"] == "decision"]
        assert len(decisions) == 1
        decision = decisions[0]
        assert (
            decision["action_status"] == "missing"
            and decision["executed_action"] is None
        )
        assert decision["selected_attempt_id"] is None and decision["terminal"] is True
        (attempt,) = decision["attempts"]
        assert attempt["origin"] == "model" and not attempt["accepted"]
        assert (
            attempt["prompt"]
            and attempt["request"]
            and attempt["response_reader_joined"] is True
        )
        assert attempt["raw_response"] is None
        if case == "started-sigterm":
            assert attempt["platform_call_id"] is None
            assert (
                attempt["response_body_b64"] is None
                and attempt["response_headers_b64"] is None
            )
            assert (
                attempt["http_status"] is None and attempt["response_complete"] is None
            )
        else:
            assert base64.b64decode(attempt["response_body_b64"]) == partial
            assert b"X-Fixture: private-header" in base64.b64decode(
                attempt["response_headers_b64"]
            )
            assert attempt["platform_call_id"] == call_id
            assert (
                attempt["http_status"] == 200 and attempt["response_complete"] is False
            )
        if "http" not in case:
            assert (output / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
        (output / "proof.json").write_text(
            json.dumps(
                {
                    "case": case,
                    "signal_to_seal_seconds": elapsed,
                    "scope": "fixture-only",
                    "source_revision": SOURCE,
                }
            )
            + "\n"
        )
        print(case, "private truncated", elapsed, flush=True)
    finally:
        release.set()
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        for log in logs:
            log.close()
        provider.shutdown()
        provider.server_close()
        thread.join(timeout=5)
        assert not thread.is_alive()
