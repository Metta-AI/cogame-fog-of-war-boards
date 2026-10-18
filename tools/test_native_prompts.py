"""Published Fog-of-War Boards episodes with real players and a closed inference endpoint."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import time
from pathlib import Path


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {entry["id"]: entry["game_config"] for entry in manifest["variants"]}
    cases = [(name, "canonical") for name in variants]
    cases += [
        ("recon-hex-5", wording)
        for wording in (
            "plain",
            "numbered",
            "questions",
            "reordered",
            "heldout-briefing",
            "heldout-reference",
            "mixed",
        )
    ]
    if args.smoke:
        cases = [("phantom-ttt-3", "canonical"), ("recon-hex-5", "canonical")]
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for variant, wording in cases:
        work = args.output / f"{variant}-{wording}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        seats = config["num_agents"]
        config.update(
            seed=7,
            promptVariant=wording,
            promptSeed=4,
            tokens=[f"t{seat}" for seat in range(seats)],
            players=[{"name": f"policy-{seat}"} for seat in range(seats)],
        )
        (work / "config.json").write_text(json.dumps(config))
        closed_endpoint = socket.socket()
        closed_endpoint.bind(("127.0.0.1", 0))
        closed_port = closed_endpoint.getsockname()[1]
        port = free_port()
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "PLAYER_SCRIPTED",
            "COWORLD_LLM_PLY_SPACING_SECONDS",
        ):
            env.pop(key, None)
        env.update(
            COGAME_HOST="127.0.0.1",
            COGAME_PORT=str(port),
            COGAME_CONFIG_URI=(work / "config.json").as_uri(),
            COGAME_RESULTS_URI=(work / "results.json").as_uri(),
            COGAME_SAVE_REPLAY_URI=(work / "episode.replay").as_uri(),
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed_port}",
            COGAME_SAVE_TRAJECTORY_URI=(work / "trajectory.jsonl").as_uri(),
            COWORLD_SOURCE_REVISION="uncommitted-fogboards-validation",
            COWORLD_GAME_VERSION="prompt-validation-v1",
            COWORLD_EPISODE_ID=work.name,
            COWORLD_LLM_MODEL="closed-endpoint-validation",
        )
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen(
                [str(args.game)],
                cwd=root,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(seats):
                player_env = dict(
                    env,
                    COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    PLAYER_PROMPT=(
                        f"PRIVATE-STRATEGY-{seat}: Cooperate using only the information available to your role."
                    ),
                )
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        [str(args.player)],
                        cwd=root,
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            assert game.wait(timeout=1200 + 30) == 0
            for player in processes[1:]:
                assert player.wait(timeout=15) == 0
            results = json.loads((work / "results.json").read_text())
            assert results["reason"] == "complete"
            assert 1 <= results["plies"] <= config["maxPlies"]
            records = [
                json.loads(line)
                for line in (work / "trajectory.jsonl").read_text().splitlines()
            ]
            episode = records[-1]
            assert (
                episode["event_type"] == "episode" and episode["status"] == "completed"
            )
            assert episode["outcome"] == results
            assert episode["source_revision"] == "uncommitted-fogboards-validation"
            decisions = records[:-1]
            assert len(decisions) == results["plies"] * (
                2 if variant == "recon-hex-5" else 1
            )
            replay = json.loads((work / "episode.replay").read_text())
            events = [
                event
                for event in replay["events"]
                if event["kind"] in ("sense", "attempt")
            ]
            assert len(events) == len(decisions)
            requests = 0
            for index, (row, event) in enumerate(zip(decisions, events, strict=True)):
                seat = int(row["seat"])
                action = row["executed_action"]
                phase = "sense" if set(action) == {"sense"} else "attempt"
                assert event["kind"] == phase and event["seat"] == seat
                view = row["observation"]
                assert view["slot"] == seat and "board" not in view
                assert row["action_status"] == "fallback" and row["fallback_origin"]
                assert row["selected_attempt_id"] is None and len(row["attempts"]) == 2
                for attempt in row["attempts"]:
                    requests += 1
                    assert (
                        attempt["origin"] == "model"
                        and not attempt["accepted"]
                        and attempt["rejection_reason"]
                    )
                    system, user = [message["content"] for message in attempt["prompt"]]
                    assert (
                        f"PRIVATE-STRATEGY-{seat}" in user
                        and f"PRIVATE-STRATEGY-{1 - seat}" not in user
                    )
                    assert attempt["request"]["system"] == system
                    assert attempt["request"]["messages"] == attempt["prompt"][1:]
                    assert attempt["platform_call_id"] is None
                metadata = view["prompt_template"]
                assert metadata["bank"] == "fog-of-war-boards-rules-v1"
                assert metadata["variant"] == (
                    "reordered" if wording == "mixed" else wording
                )
                for message in row["attempts"][-1]["prompt"]:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                assert (
                    "Your previous reply was invalid"
                    in row["attempts"][1]["prompt"][1]["content"]
                )
                if phase == "sense":
                    assert (
                        action["sense"] == event["anchor"]
                        and action["sense"] in view["legalSenseAnchors"]
                    )
                else:
                    assert (
                        action["cell"] == event["cell"]
                        and action["cell"] in view["legalAttempts"]
                    )
                    assert (
                        action["say"] == event["say"]
                        and action["guess"] == event["guess"]
                    )
                    if variant == "recon-hex-5":
                        assert index % 2 == 1 and events[index - 1]["kind"] == "sense"
                        assert (
                            " — you sensed "
                            in row["attempts"][0]["prompt"][1]["content"]
                        )
            assert decisions[-1]["terminal"]
            public = (work / "episode.replay").read_text()
            assert (
                "PRIVATE-STRATEGY-" not in public
                and "prompt_template" not in public
                and '"notes"' not in public
            )
            assert (work / "trajectory.jsonl").stat().st_mode & 0o777 == 0o600
            print(
                work.name,
                len(decisions),
                "phases;",
                requests,
                "actual failed requests; native fog and replay joins PASS",
                flush=True,
            )
        finally:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            for log in logs:
                log.close()
            closed_endpoint.close()


if __name__ == "__main__":
    main()
