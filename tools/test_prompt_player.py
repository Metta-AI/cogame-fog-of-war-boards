"""Exercise the prompt-only reference player with real WebSocket lifecycle failures.

Arguments: compiled player binary, fresh private output directory.
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from websockets.sync.server import serve

binary, output = sys.argv[1:]
root = Path(output)
root.mkdir(mode=0o700)
for mode in (
    "final",
    "eof",
    "deadline",
    "partial-header-term",
    "partial-body-int",
    "malformed",
    "duplicate-welcome",
):
    entered = threading.Event()
    release = threading.Event()
    registrations = []

    def handle(connection):
        connection.send(json.dumps({"type": "welcome", "slot": 0, "name": "fixture"}))
        registrations.append(json.loads(connection.recv(timeout=1)))
        if mode == "final":
            connection.send(json.dumps({"type": "state"}))
            connection.send(json.dumps({"type": "final", "scores": [1]}))
        elif mode == "duplicate-welcome":
            connection.send(
                json.dumps({"type": "welcome", "slot": 0, "name": "fixture"})
            )
        elif mode == "malformed":
            connection.send("PRIVATE_PROMPT_FRAME_SENTINEL")
        elif mode.startswith("partial-"):
            connection.socket.sendall(
                b"\x81"
                if mode == "partial-header-term"
                else b"\x81\x7e\x00\xc8" + b"x" * 10
            )
            entered.set()
            release.wait(3)
        elif mode == "deadline":
            entered.set()
            release.wait(3)

    server = serve(handle, "127.0.0.1", 0)
    owner = threading.Thread(target=server.serve_forever)
    owner.start()
    env = dict(
        os.environ,
        COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{server.socket.getsockname()[1]}/player",
        PLAYER_PROMPT="PRIVATE_OPERATOR_SENTINEL",
        COWORLD_TIMEOUT_SECONDS="0.3" if mode == "deadline" else "3",
    )
    log_path = root / (mode + ".log")
    with log_path.open("w") as log:
        process = subprocess.Popen(
            [binary], env=env, stdout=log, stderr=subprocess.STDOUT
        )
        started = time.monotonic()
        try:
            if mode.startswith("partial-"):
                assert entered.wait(1)
                time.sleep(0.05)
                started = time.monotonic()
                process.send_signal(
                    signal.SIGTERM if mode.endswith("term") else signal.SIGINT
                )
            code = process.wait(timeout=2)
            elapsed = time.monotonic() - started
            assert code == (1 if mode in {"malformed", "duplicate-welcome"} else 0), (
                mode
            )
            assert elapsed < 1
            assert registrations == [
                {
                    "type": "prompt",
                    "prompt": "PRIVATE_OPERATOR_SENTINEL",
                    "scripted": False,
                }
            ]
            assert "PRIVATE_OPERATOR_SENTINEL" not in log_path.read_text()
            assert "PRIVATE_PROMPT_FRAME_SENTINEL" not in log_path.read_text()
            print(
                json.dumps(
                    {
                        "mode": mode,
                        "exit_status": code,
                        "elapsed_seconds": elapsed,
                        "scope": "prompt-player transport fixture; zero model authority",
                    }
                )
            )
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)
            release.set()
            server.shutdown()
            owner.join(timeout=2)
            assert not owner.is_alive()
            log_path.chmod(0o600)
