"""Complete published games with exact phase prompts, matched original play, and retries."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE, ORIGINAL = (Path(value).resolve() for value in sys.argv[1:3])
VARIANTS = ("phantom-ttt-3", "dark-hex-4", "dark-hex-5", "recon-hex-5")
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(
    variant, seed, wording="canonical", prompt_seed=0, original=False, retries=False
):
    with subprocess.Popen(
        [
            str(ORIGINAL if original else BRIDGE),
            str(ROOT / "coworld_manifest_template.json"),
            variant,
            "--language",
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 2,
                "seed": str(seed),
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace, systems = [], {}
        previous = None
        while observation["kind"] == "decision":
            index, seat = observation["decision_id"], observation["seat"]
            assert index == len(trace)
            messages = observation["messages"]
            view = observation["semantic_view"]
            phase = view["phase"]
            systems.setdefault(seat, messages[0]["content"])
            assert systems[seat] == messages[0]["content"]
            if not original:
                metadata = view.pop("prompt_template")
                assert metadata["bank"] == "fog-of-war-boards-rules-v1"
                assert metadata["variant"] == (
                    WORDINGS[prompt_seed] if wording == "mixed" else wording
                )
                for message in messages:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
            if variant == "recon-hex-5":
                assert phase == ("sense" if index % 2 == 0 else "attempt")
                if phase == "attempt":
                    assert previous == (observation["turn"], seat)
                    assert " — you sensed " in messages[1]["content"]
                previous = (observation["turn"], seat)
            else:
                assert phase == "attempt"
            teacher = json.loads(request({"kind": "teacher"})["response"])
            if retries and index == 0:
                rejected = request(
                    {"kind": "step", "decision_id": index, "response": "invalid"}
                )
                assert rejected["kind"] == "rejected"
                retry = rejected["observation"]
                assert retry["decision_id"] == index
                assert (
                    "Your previous reply was invalid" in retry["messages"][1]["content"]
                )
                metadata = retry["semantic_view"]["prompt_template"]
                assert (
                    metadata["user_sha256"].lower()
                    == hashlib.sha256(
                        retry["messages"][1]["content"].encode()
                    ).hexdigest()
                )
                result = request(
                    {"kind": "step", "decision_id": index, "response": "invalid again"}
                )
                assert result["kind"] == "consumed_rejection"
            else:
                result = request(
                    {
                        "kind": "step",
                        "decision_id": index,
                        "response": json.dumps(teacher),
                    }
                )
                assert result["kind"] == "accepted"
            trace.append(
                (view["observation"], phase, messages[1]["content"], result["action"])
            )
            observation = result["observation"]
        assert 0 < len(trace) <= (100 if variant == "recon-hex-5" else 50)
        assert (
            set(observation["scores"]) == {"0", "1"}
            and sum(observation["scores"].values()) == 0
        )
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        return trace, observation, systems


for variant in VARIANTS:
    for seed in (17, 946001):
        baseline = play(variant, seed, original=True)
        distinct = []
        for wording, prompt_seed in [(w, 0) for w in WORDINGS] + [
            ("mixed", i) for i in range(5)
        ]:
            result = play(variant, seed, wording, prompt_seed)
            assert result[:2] == baseline[:2]
            if wording == "canonical":
                assert result[2] == baseline[2]
            if wording == "mixed":
                assert result[2] == distinct[prompt_seed]
            else:
                distinct.append(result[2])
        assert all(len({systems[seat] for systems in distinct}) == 7 for seat in (0, 1))
    play(variant, 17, retries=True)
    print(
        variant,
        "24 matched games, two original comparisons, complete retry/fallback game PASS",
        flush=True,
    )
for wording in WORDINGS[-2:]:
    result = subprocess.run(
        [
            str(BRIDGE),
            str(ROOT / "coworld_manifest_template.json"),
            "recon-hex-5",
            "--language",
        ],
        input=json.dumps(
            {
                "kind": "reset",
                "players": 2,
                "seed": "17",
                "promptVariant": wording,
                "split": "train",
            }
        )
        + "\n",
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert (
        result.returncode != 0
        and "held-out wording cannot be used for training" in result.stderr
    )
print(
    "100 complete language games; eight original comparisons; held-out training gate PASS",
    flush=True,
)
