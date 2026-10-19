# Fog-of-War Boards training

The native host, language bridge, and teacher exporter share one prompt builder.
Five training wordings vary fog, evidence, and collision explanations while
preserving board rules, private views, action schemas, and budgets. Canonical
recon wording now correctly includes reconnaissance as an information source;
other canonical variants preserve their original bytes.

Set `promptVariant` to `canonical` (default), `plain`, `numbered`, `questions`,
`reordered`, or `mixed`. Mixed selection requires a nonnegative `promptSeed`;
`promptSeed % 5` chooses a training wording. Selection remains fixed throughout
the episode without consuming simulator randomness. `heldout-briefing` and
`heldout-reference` are evaluation-only. The language bridge rejects these
when reset with `split: "train"`.

Private observations include bank `fog-of-war-boards-rules-v2`, wording, seed,
and SHA-256 hashes of actual system/user messages, including retry instructions.
Existing native trajectories retain attempts, provider identity, responses, and
executed phases. Operator instructions and prompt metadata stay out of replays.

## Candidate trajectories

Run from a clean, committed checkout. At least ten complete games and an
explicit game version are required:

```sh
nim c -d:release --path:src -o:/tmp/fogboards-posttrain tools/export_posttrain.nim
/tmp/fogboards-posttrain /tmp/fogboards-data 10 recon-hex-5 GAME_VERSION plain 0
```

Other published variants are `phantom-ttt-3`, `dark-hex-4`, and `dark-hex-5`.
Omit the final two arguments for canonical wording. Held-out exports are rejected.
Private outputs contain `trajectories.jsonl` and `manifest.json`, with source
revision and outcomes. Scripted `probe` and `sweep` policies supply teacher
actions. Recon applies sense before rendering the attempt's fresh private view.

These are candidates, not approved training examples. The shared Coworld
trajectory importer owns review and dataset splits. Keep each `fog-SEED`
family together across board variants and wordings; never split each wording
independently into training and validation.

## Validation and experiments

`tools/test_prompt_games.py BRIDGE` runs 40 complete language games across all
four board variants, including recon phases, retry failures, and matched play.
`tools/test_training.py EXPORTER BRIDGE` exercises mixed-wording candidate exports,
both bridge interfaces, and the complete language games. Mixed exports cycle
through five training wordings while retaining each episode's seed family.
The existing `tools/test_native_trajectory.py GAME PLAYER` fixture checks actual
mixed-selected HTTP prompts, failed requests, fallback execution, private hashes,
and replay joins. These fixtures use local inference stubs and do not measure
provider inference or learning.

Compare canonical and mixed training with matched game seeds, seats, opponents,
and inference settings. Report win rate, invalid-action rate, fallback rate,
request counts, and completion rates for familiar and held-out wording.
No learning stability improvement is claimed by deterministic checks.

## Numeric reinforcement learning

`tools/train_bridge.nim` uses the same native simulator. Its 106 values
contain variant, seat, ply progress, and 25 padded cells. Each cell is
encoded from the acting seat's own stones, proven opponent stones,
previously sensed empty cells, and legal attempts. Unseen opponent stones
are never encoded. Two choices select the published `probe` and `sweep`
policies. The native +1/0/-1 scores are terminal utilities. Post-training
above retains the game's complete JSON move and sense action space.

```sh
nim c -d:release --path:src -o:/tmp/fogboards-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/fogboards-posttrain /tmp/fogboards-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute bridge
and manifest paths to `recipes.external.coworld.train` for native PufferLib,
or `recipes.external.coworld_metta_rl.train` for Metta RL. Set `players=2`
and use any certified variant ID.

Each variant completed a 512-timestep Metta RL pilot with the native
terminal scores and the acting seat's fogged numeric observation.

Native PufferLib completed 4,096 CUDA timesteps per variant on metta1.
Reloaded checkpoints on held-out seeds 101 and 102 reported mean scores
0/0 for phantom tic-tac-toe and 1/1 for each Dark Hex variant. Checkpoint
SHA-256 values, in the variant order above, were
`22c7dd28572b85f79c0cfef85e47b233e1fc79983cb2d530df289db48cfb3677`,
`af9ebb66f78937b562f0144331f4f268d8a857956bf62d274c049f9806ef69c0`,
`f5174d2b1c088ee0646ab82c50418908c690d7a7d279306e7f6f131c85571243`,
and `6a84fed90122cf6376a3f03fcd6a8eda304ec6ba03b4a25f542dd9e7a3b6275f`.
