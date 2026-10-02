"""Exercise full native matches, including recon sense-before-move."""

import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "coworld_manifest_template.json"
EXPORTER = Path(sys.argv[1]).resolve()
BRIDGE = Path(sys.argv[2]).resolve()
VARIANTS = ("phantom-ttt-3", "dark-hex-4", "dark-hex-5", "recon-hex-5")

with tempfile.TemporaryDirectory() as directory:
    for variant in VARIANTS:
        output = Path(directory) / variant
        subprocess.run([str(EXPORTER), str(output), "10", variant, "fixture-v3"], cwd=ROOT, check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        events = [json.loads(line) for line in (output / "trajectories.jsonl").read_text().splitlines()]
        episodes = [event for event in events if event["event_type"] == "episode"]
        assert len(episodes) == 10
        assert {event["seed_family"] for event in episodes} == {f"fog-{seed}" for seed in range(1, 11)}
        assert (output / "trajectories.jsonl").stat().st_mode & 0o777 == 0o600
        assert manifest["variant"] == variant and len(manifest["runs"]) == 10
        assert len(train) == manifest["train_examples"]
        assert len(validation) == manifest["validation_examples"]
        assert all(run["plies"] > 0 and len(run["scores"]) == 2 for run in manifest["runs"])
        phases_by_episode: dict[str, list[str]] = {}
        for row in train + validation:
            prompt = row["prompt"][1]["content"]
            view = row["observation"]
            assert view["name"] != view["opponentName"]
            assert view["mode"] and view["legalAttempts"]
            assert "YOUR LEGAL ATTEMPTS:" in prompt
            assert "THE FOG:" in prompt
            phases_by_episode.setdefault(row["episode_id"], []).append(row["phase"])
            reply = json.loads(row["completion"][0]["content"])
            if row["phase"] == "sense":
                assert variant == "recon-hex-5" and set(reply) == {"sense"}
                assert reply["sense"] in view["legalSenseAnchors"]
                anchors = next(line for line in prompt.splitlines()
                               if line.startswith("YOUR LEGAL SENSE ANCHORS:"))
                assert reply["sense"] in anchors.split(": ", 1)[1].split(" (")[0].split()
            else:
                assert row["phase"] == "attempt" and set(reply) == {"cell", "say", "notes", "guess"}
                assert reply["cell"] in view["legalAttempts"]
                attempts = next(line for line in prompt.splitlines()
                                if line.startswith("YOUR LEGAL ATTEMPTS:"))
                assert reply["cell"] in attempts.split(": ", 1)[1].split()
                if variant == "recon-hex-5":
                    assert " — you sensed " in prompt
        for phases in phases_by_episode.values():
            if variant == "recon-hex-5":
                assert len(phases) % 2 == 0
                assert phases == [phase for _ in range(len(phases) // 2)
                                  for phase in ("sense", "attempt")]
            else:
                assert phases == ["attempt"] * len(phases)

        for language, teacher in [(language, teacher) for language in (False, True)
                                  for teacher in (True, False)]:
            process = subprocess.Popen(
                [str(BRIDGE), str(MANIFEST), variant, *(["--language"] if language else [])], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, text=True, bufsize=1, cwd="/tmp",
            )
            assert process.stdin is not None and process.stdout is not None
            rng = random.Random(13)

            def request(payload: dict) -> dict:
                process.stdin.write(json.dumps(payload) + "\n")
                process.stdin.flush()
                return json.loads(process.stdout.readline())

            try:
                observation = request({"kind": "reset", "players": 2,
                                       "seed": f"fogboards-{variant}-{teacher}"})
                decisions = 0
                if language:
                    assert observation["inference_mode"] == "text_action"
                    original = observation
                    rejected = request({"kind": "step", "decision_id": 0, "response": "invalid phase"})
                    assert rejected["kind"] == "rejected"
                    assert rejected["observation"]["decision_id"] == 0
                    assert rejected["observation"]["messages"][1]["content"].startswith(original["messages"][1]["content"])
                    assert "Your previous reply was invalid" in rejected["observation"]["messages"][1]["content"]
                    consumed = request({"kind": "step", "decision_id": 0, "response": "invalid again"})
                    assert consumed["kind"] == "consumed_rejection" and consumed["reason"]
                    assert set(consumed["action"]) == ({"sense"} if variant == "recon-hex-5" else {"cell", "say", "notes", "guess"})
                    # Reset before the complete-match check; each phase below starts from an untouched episode.
                    observation = request({"kind": "reset", "players": 2,
                                           "seed": f"fogboards-{variant}-{teacher}"})
                phases = []
                prior_turn = None
                prior_seat = None
                while observation["kind"] == "decision":
                    assert observation["seat"] in (0, 1)
                    assert observation["decision_id"] == decisions
                    assert "YOUR LEGAL ATTEMPTS:" in observation["semantic_view"]["user"]
                    encoded = request({"kind": "encode"})
                    assert len(encoded["values"]) == 106
                    assert encoded["actions"] == [{"choice": 0}, {"choice": 1}]
                    if language:
                        phase = observation["semantic_view"]["phase"]
                        phases.append(phase)
                        properties = observation["action_schema"]["properties"]
                        if phase == "sense":
                            assert variant == "recon-hex-5"
                            assert set(properties) == {"sense"}
                            prior_turn, prior_seat = observation["turn"], observation["seat"]
                        elif variant == "recon-hex-5":
                            assert phases[-2:] == ["sense", "attempt"]
                            assert (observation["turn"], observation["seat"]) == (prior_turn, prior_seat)
                            assert " — you sensed " in observation["messages"][1]["content"]
                        name = "sense" if phase == "sense" else "cell"
                        action = (json.loads(request({"kind": "teacher"})["response"])
                                  if teacher else {name: rng.choice(properties[name]["enum"])})
                    else:
                        action = (json.loads(request({"kind": "teacher"})["response"])
                                  if teacher else rng.choice(encoded["actions"]))
                    accepted = request({"kind": "step", "decision_id": decisions,
                                        "response": json.dumps(action)})
                    if accepted["kind"] == "rejected":
                        assert language and "Your previous reply was invalid" in accepted["observation"]["messages"][1]["content"]
                        accepted = request({"kind": "step", "decision_id": decisions,
                                            "response": request({"kind": "teacher"})["response"]})
                    assert accepted["kind"] == "accepted"
                    observation = accepted["observation"]
                    decisions += 1
                    assert decisions <= (100 if language else 50)
                assert set(observation["scores"]) == {"0", "1"}
                assert sum(observation["scores"].values()) == 0
                assert observation["utilities"] == observation["scores"]
                print(variant, "language" if language else "numeric", "teacher" if teacher else "random", decisions)
            finally:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
