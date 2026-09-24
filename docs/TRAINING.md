# Fog-of-War Boards training

The exporter plays ten complete native matches per variant. Each decision
records the hosted system prompt, the acting seat's fogged user prompt, and
the `probe` or `sweep` reply accepted by the production parser. The
`recon-hex-5` exporter applies the teacher's sense before its move. Train
and validation sets split whole matches by seed.

```sh
nim c -d:release --path:src -o:/tmp/fogboards-posttrain tools/export_posttrain.nim
/tmp/fogboards-posttrain /tmp/fogboards-data 10 recon-hex-5
```

The other certified variants are `phantom-ttt-3`, `dark-hex-4`, and
`dark-hex-5`. The output contains `train.jsonl`, `validation.jsonl`, and a
manifest with source revision, seeds, plies, final scores, and row counts.
Ten matches yielded 88/22, 64/16, 72/18, and 72/18 train/validation
decisions respectively, in that variant order.

All 370 examples fit 4,096 tokens with the local WordLevel smoke tokenizer.
One CPU optimizer step reduced four-example validation loss from 1.85891
to 1.85353, 1.83972 to 1.83441, 1.82757 to 1.82295, and 1.78231 to
1.77724 in the same variant order. This verifies the post-training path;
it does not measure league play.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/fogboards-data --output /tmp/fogboards-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

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
