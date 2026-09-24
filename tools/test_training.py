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
        subprocess.run([str(EXPORTER), str(output), "10", variant], cwd=ROOT, check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        assert manifest["variant"] == variant and len(manifest["runs"]) == 10
        assert len(train) == manifest["train_examples"]
        assert len(validation) == manifest["validation_examples"]
        assert all(run["plies"] > 0 and len(run["scores"]) == 2 for run in manifest["runs"])
        for row in train + validation:
            assert "YOUR LEGAL ATTEMPTS:" in row["prompt"][1]["content"]
            assert "THE FOG:" in row["prompt"][1]["content"]
            reply = json.loads(row["completion"][0]["content"])
            assert ("sense" in reply) == (variant == "recon-hex-5")
            if "sense" in reply:
                assert "YOUR LEGAL SENSE ANCHORS:" in row["prompt"][1]["content"]

        for teacher in (True, False):
            process = subprocess.Popen(
                [str(BRIDGE), str(MANIFEST), variant], stdin=subprocess.PIPE,
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
                while observation["kind"] == "decision":
                    assert observation["seat"] in (0, 1)
                    assert observation["decision_id"] == decisions
                    assert "YOUR LEGAL ATTEMPTS:" in observation["semantic_view"]["user"]
                    encoded = request({"kind": "encode"})
                    assert len(encoded["values"]) == 106
                    assert encoded["actions"] == [{"choice": 0}, {"choice": 1}]
                    action = (json.loads(request({"kind": "teacher"})["response"])
                              if teacher else rng.choice(encoded["actions"]))
                    accepted = request({"kind": "step", "decision_id": decisions,
                                        "response": json.dumps(action)})
                    assert accepted["kind"] == "accepted"
                    observation = accepted["observation"]
                    decisions += 1
                    assert decisions <= 50
                assert set(observation["scores"]) == {"0", "1"}
                assert sum(observation["scores"].values()) == 0
                assert observation["utilities"] == observation["scores"]
                print(variant, "teacher" if teacher else "random", decisions)
            finally:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
