"""Verify untrusted player origins and model-response binding through real sockets."""

import asyncio
import contextlib
import base64
import http.server
import re
import threading
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parents[1]
GAME = str(Path(sys.argv[1]).resolve())
NULL_FIELDS = (
    "model",
    "prompt",
    "request",
    "response",
    "raw_response",
    "decoder",
    "platform_call_id",
    "rejection_reason",
    "model_identity",
    "tokenizer_identity",
    "chat_template_sha256",
    "stop_reason",
    "latency_ms",
    "input_tokens",
    "output_tokens",
    "prompt_token_ids",
    "sampled_token_ids",
    "behavior_logprobs",
    "response_headers",
    "provider_request_id",
    "response_body_b64",
    "response_headers_b64",
    "response_complete",
    "response_reader_joined",
    "http_status",
)


class NativeFixture(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["content-length"])))
        assert self.path == "/v1/messages" and self.headers[
            "X-Coworld-Player-Slot"
        ] in {"0", "1"}
        user = request["messages"][0]["content"]
        sense = user.rsplit("Reply with ONLY ", 1)[1].startswith('{"sense"')
        label = "YOUR LEGAL SENSE ANCHORS:" if sense else "YOUR LEGAL ATTEMPTS:"
        legal = next(line for line in user.splitlines() if line.startswith(label))
        cells = re.findall(r"\b[a-e][1-5]\b", legal)
        assert len(cells) > 1
        action = (
            {"sense": cells[1]}
            if sense
            else {"cell": cells[1], "say": "", "notes": "", "guess": []}
        )
        payload = {
            "model": "fixture/served",
            "stop_reason": "end_turn",
            "content": [{"type": "text", "text": json.dumps(action)}],
        }
        if request["temperature"] == 1:
            payload["sampling_evidence"] = {
                "policy_revision": "a" * 64,
                "tokenizer_revision": "b" * 64,
                "chat_template": "fixture-template",
                "sampling": "full_softmax_temperature_one",
                "enable_thinking": False,
                "max_new_tokens": request["max_tokens"],
                "max_sequence_length": 40000,
                "sampling_seed": 7,
                "eos_token_ids": [4],
                "prompt_token_ids": list(range(32768)),
                "completion_token_ids": [3, 4],
                "behavior_log_probs": [-0.5, -0.3],
                "stop_reason": "eos",
                "response": json.dumps(action),
            }
            payload["usage"] = {"input_tokens": 32768, "output_tokens": 2}
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("content-length", str(len(body)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid4()))
        if request["temperature"] == 1:
            self.send_header("X-Coworld-Checkpoint-Sha256", "a" * 64)
            self.send_header("X-Coworld-Tokenizer-Sha256", "b" * 64)
            self.send_header("X-Coworld-Chat-Template-Sha256", "c" * 64)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def complete_fixture(attempt, slot):
    started = time.monotonic()
    body = json.dumps(attempt["request"]).encode()
    received = bytearray()
    with socket.create_connection(
        ("127.0.0.1", provider.server_port), timeout=3
    ) as stream:
        headers = (
            f"POST /v1/messages HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            f"X-Coworld-Player-Slot: {slot}\r\nContent-Length: {len(body)}\r\n\r\n"
        ).encode()
        stream.sendall(headers + body)
        while chunk := stream.recv(65536):
            received.extend(chunk)
    raw_headers, separator, raw_body = bytes(received).partition(b"\r\n\r\n")
    assert separator and raw_headers.splitlines()[0].split()[1] == b"200"
    header_map = dict(
        line.decode().split(": ", 1) for line in raw_headers.split(b"\r\n")[1:]
    )
    assert len(raw_body) == int(header_map["content-length"])
    served = json.loads(raw_body)
    attempt.update(
        {
            "response": served["content"][0]["text"],
            "model": served["model"],
            "raw_response": raw_body.decode(),
            "response_body_b64": base64.b64encode(raw_body).decode(),
            "response_headers_b64": base64.b64encode(raw_headers + separator).decode(),
            "response_headers": header_map,
            "http_status": 200,
            "response_complete": True,
            "response_reader_joined": True,
            "platform_call_id": header_map["X-Softmax-Llm-Call-Id"],
            "latency_ms": (time.monotonic() - started) * 1000,
            "stop_reason": served["stop_reason"],
        }
    )
    if "sampling_evidence" in served:
        sampled = served["sampling_evidence"]
        attempt.update(
            {
                "prompt_token_ids": sampled["prompt_token_ids"],
                "sampled_token_ids": sampled["completion_token_ids"],
                "behavior_logprobs": sampled["behavior_log_probs"],
                "stop_reason": sampled["stop_reason"],
                "model_identity": header_map["X-Coworld-Checkpoint-Sha256"],
                "tokenizer_identity": header_map["X-Coworld-Tokenizer-Sha256"],
                "chat_template_sha256": header_map["X-Coworld-Chat-Template-Sha256"],
                "input_tokens": served["usage"]["input_tokens"],
                "output_tokens": served["usage"]["output_tokens"],
            }
        )


async def player(slot, port, origin):
    async with websockets.connect(
        f"ws://127.0.0.1:{port}/player?slot={slot}&token=t{slot}"
    ) as connection:
        async for raw in connection:
            packet = json.loads(raw)
            if packet["type"] == "welcome":
                await connection.send(
                    json.dumps(
                        {"type": "register", "control": "external", "prompt": ""}
                    )
                )
            elif packet["type"] in {"decision", "rejected"}:
                if packet["type"] == "rejected":
                    packet = packet["observation"]
                view, phase, identity = (
                    packet["observation"],
                    packet["phase"],
                    packet["decision_id"],
                )
                choices = view[
                    "legalSenseAnchors" if phase == "sense" else "legalAttempts"
                ]
                action = (
                    {"sense": choices[0]}
                    if phase == "sense"
                    else {"cell": choices[0], "say": "", "notes": "", "guess": []}
                )
                evidence = dict.fromkeys(NULL_FIELDS)
                evidence.update(
                    {
                        "attempt_id": identity
                        + ("-model" if origin.startswith("model-") else "-external"),
                        "policy": "asserted-player",
                        "origin": "model" if origin.startswith("model-") else origin,
                        "prompt": packet["messages"],
                    }
                )
                if origin == "model-omitted-join":
                    request = {
                        "model": "fixture/requested",
                        "max_tokens": 256,
                        "temperature": 0,
                        "system": packet["messages"][0]["content"],
                        "messages": [packet["messages"][1]],
                    }
                    evidence.update(
                        {
                            "request": request,
                            "model": request["model"],
                            "decoder": {"temperature": 0, "max_tokens": 256},
                        }
                    )
                    await connection.send(
                        json.dumps(
                            {
                                "type": "attempt_started",
                                "decision_id": identity,
                                "training_attempt": evidence,
                            }
                        )
                    )
                    await connection.send(
                        json.dumps(
                            {
                                "type": "action",
                                "decision_id": identity,
                                "source": "unknown",
                                "action": action,
                                "training_attempt": None,
                            }
                        )
                    )
                    continue
                if origin.startswith("model-"):
                    request = {
                        "model": "fixture/requested",
                        "max_tokens": 256,
                        "temperature": 1 if origin == "model-large-sampled" else 0,
                        "system": packet["messages"][0]["content"],
                        "messages": [packet["messages"][1]],
                    }
                    evidence.update(
                        {
                            "request": request,
                            "model": request["model"],
                            "decoder": {
                                "temperature": request["temperature"],
                                "max_tokens": 256,
                            },
                        }
                    )
                    if origin in {
                        "model-forged-start",
                        "model-false-start",
                        "model-chronology",
                    }:
                        forged = evidence.copy()
                        if origin == "model-false-start":
                            forged["response_complete"] = False
                            forged["response_reader_joined"] = False
                        else:
                            forged.update(
                                {
                                    "response": "not a native response",
                                    "raw_response": "forged",
                                    "response_body_b64": base64.b64encode(
                                        b"forged"
                                    ).decode(),
                                    "response_complete": True,
                                    "response_reader_joined": True,
                                }
                            )
                        await connection.send(
                            json.dumps(
                                {
                                    "type": "attempt_started",
                                    "decision_id": identity,
                                    "training_attempt": forged,
                                }
                            )
                        )
                    if origin in {
                        "model-mismatch",
                        "model-chronology",
                        "model-large-sampled",
                    }:
                        await connection.send(
                            json.dumps(
                                {
                                    "type": "attempt_started",
                                    "decision_id": identity,
                                    "training_attempt": evidence,
                                }
                            )
                        )
                    complete_fixture(evidence, slot)
                    if origin != "model-mismatch":
                        action = json.loads(evidence["response"])
                else:
                    evidence["response"] = json.dumps(action)
                await connection.send(
                    json.dumps(
                        {
                            "type": "action",
                            "decision_id": identity,
                            "source": "llm"
                            if origin.startswith("model-")
                            else "unknown",
                            "action": action,
                            "training_attempt": evidence,
                        }
                    )
                )
            elif packet["type"] == "stop":
                await connection.send(
                    json.dumps(
                        {
                            "type": "stopped",
                            "decision_id": packet["decision_id"],
                            "stop_id": packet["stop_id"],
                            "worker_status": "no_active_call",
                            "attempts": [],
                        }
                    )
                )
            elif packet["type"] == "evidence_received":
                return
    raise AssertionError("player closed before acknowledged owned cleanup")


async def players(port, origin):
    for _ in range(100):
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                break
        await asyncio.sleep(0.05)
    else:
        raise AssertionError("game did not open sockets")
    await asyncio.wait_for(
        asyncio.gather(player(0, port, origin), player(1, port, origin)), 60
    )


manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NativeFixture)
provider_thread = threading.Thread(target=provider.serve_forever)
provider_thread.start()
try:
    for variant in ("dark-hex-5", "recon-hex-5"):
        if (
            os.environ.get("FOG_ORIGIN_FIXTURE_VARIANT")
            and variant != os.environ["FOG_ORIGIN_FIXTURE_VARIANT"]
        ):
            continue
        for origin in (
            (
                "teacher",
                "human",
                "model-mismatch",
                "model-forged-start",
                "model-false-start",
                "model-chronology",
                "model-large-sampled",
                "model-omitted-join",
            )
            if variant == "dark-hex-5"
            else ("teacher", "human", "model-mismatch")
        ):
            if (
                os.environ.get("FOG_ORIGIN_FIXTURE_CASE")
                and origin != os.environ["FOG_ORIGIN_FIXTURE_CASE"]
            ):
                continue
            config = next(
                row["game_config"]
                for row in manifest["variants"]
                if row["id"] == variant
            ).copy()
            config.update(
                {
                    "tokens": ["t0", "t1"],
                    "players": [{"name": "p0"}, {"name": "p1"}],
                    "seed": 21,
                    "first": 0,
                    "maxPlies": 4,
                    "turnDelayMs": 0,
                    "llmTimeoutSeconds": 1
                    if origin in {"model-forged-start", "model-false-start"}
                    else 10,
                    "player_connect_timeout_seconds": 10,
                }
            )
            if len(sys.argv) == 3:
                target = Path(sys.argv[2]) / (variant + "-" + origin)
                target.mkdir(parents=True, mode=0o700, exist_ok=False)
                output_context = contextlib.nullcontext(target)
            else:
                output_context = tempfile.TemporaryDirectory()
            with output_context as directory:
                output = Path(directory)
                (output / "config.json").write_text(json.dumps(config))
                with socket.socket() as reserve:
                    reserve.bind(("127.0.0.1", 0))
                    port = reserve.getsockname()[1]
                env = {
                    key: value
                    for key, value in os.environ.items()
                    if not key.startswith(("ANTHROPIC_", "AWS_", "TYPESAFE_"))
                }
                env.update(
                    {
                        "COWORLD_LLM_PLY_SPACING_SECONDS": "0",
                        "COGAME_HOST": "127.0.0.1",
                        "COGAME_PORT": str(port),
                        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
                        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
                        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
                        "COGAME_SAVE_TRAJECTORY_URI": (
                            output / "trajectory.jsonl"
                        ).as_uri(),
                        "COWORLD_EPISODE_ID": str(uuid.uuid4()),
                        "COWORLD_GAME_VERSION": "attack-fixture",
                        "COWORLD_SOURCE_REVISION": subprocess.check_output(
                            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
                        ).strip(),
                    }
                )
                with (output / "game.log").open("w") as log:
                    game = subprocess.Popen(
                        [GAME], cwd=ROOT, env=env, stdout=log, stderr=log
                    )
                    try:
                        asyncio.run(players(port, origin))
                        assert game.wait(timeout=35) == 0
                        events = [
                            json.loads(line)
                            for line in (output / "trajectory.jsonl")
                            .read_text()
                            .splitlines()
                        ]
                        assert events[-1]["status"] == (
                            "truncated"
                            if origin == "model-omitted-join"
                            else "completed"
                        )
                        assert len(events[:-1]) == (
                            8 if variant == "recon-hex-5" else 4
                        )
                        for decision in events[:-1]:
                            if origin == "model-mismatch":
                                assert len(decision["attempts"]) == 2
                                assert (
                                    decision["selected_attempt_id"] is None
                                    and decision["action_status"] == "fallback"
                                )
                                for attempt in decision["attempts"]:
                                    assert (
                                        attempt["origin"] == "model"
                                        and not attempt["accepted"]
                                    )
                                    assert attempt["parsed_action"] == json.loads(
                                        attempt["response"]
                                    )
                            elif origin in {"model-forged-start", "model-false-start"}:
                                assert decision["selected_attempt_id"] is None
                                assert (
                                    decision["action_status"] == "fallback"
                                    and not decision["attempts"]
                                )
                            elif origin == "model-omitted-join":
                                model, unknown = decision["attempts"]
                                assert (
                                    model["origin"] == "model"
                                    and model["response_reader_joined"] is None
                                )
                                assert (
                                    not model["accepted"]
                                    and unknown["origin"] == "unknown"
                                )
                                assert (
                                    decision["selected_attempt_id"]
                                    == unknown["attempt_id"]
                                )
                            elif origin in {"model-chronology", "model-large-sampled"}:
                                (attempt,) = decision["attempts"]
                                assert (
                                    decision["selected_attempt_id"]
                                    == attempt["attempt_id"]
                                )
                                assert (
                                    attempt["accepted"] and attempt["origin"] == "model"
                                )
                                assert (
                                    attempt["parsed_action"]
                                    == decision["executed_action"]
                                    == json.loads(attempt["response"])
                                )
                                if origin == "model-large-sampled":
                                    assert attempt["prompt_token_ids"] == list(
                                        range(32768)
                                    )
                                    assert attempt["sampled_token_ids"] == [
                                        3,
                                        4,
                                    ] and attempt["behavior_logprobs"] == [-0.5, -0.3]
                                    assert (
                                        attempt["response_body_b64"]
                                        and attempt["response_reader_joined"] is True
                                    )
                            else:
                                assert decision["action_status"] == "accepted"
                                assert all(
                                    attempt["origin"] == "unknown"
                                    for attempt in decision["attempts"]
                                )
                        print(
                            variant, origin, "no untrusted training targets", flush=True
                        )
                    finally:
                        if game.poll() is None:
                            game.terminate()
                            game.wait(timeout=5)
finally:
    provider.shutdown()
    provider.server_close()
    provider_thread.join(timeout=5)
    assert not provider_thread.is_alive()
