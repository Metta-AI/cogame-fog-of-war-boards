"""Verify untrusted player origins and model-response binding through real sockets."""
import asyncio
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
NULL_FIELDS = ('model', 'prompt', 'request', 'response', 'raw_response', 'decoder',
               'platform_call_id', 'rejection_reason', 'model_identity', 'tokenizer_identity',
               'chat_template_sha256', 'stop_reason', 'latency_ms', 'input_tokens', 'output_tokens',
               'prompt_token_ids', 'sampled_token_ids', 'behavior_logprobs')


async def player(slot, port, origin):
    async with websockets.connect(f'ws://127.0.0.1:{port}/player?slot={slot}&token=t{slot}') as connection:
        register = json.dumps({'type': 'register', 'control': 'external'})
        await connection.send(register)
        attempts = {}
        async for raw in connection:
            packet = json.loads(raw)
            if packet['type'] == 'welcome': await connection.send(register)
            elif packet['type'] in {'observation', 'rejected'}:
                view, phase, identity = packet['observation'], packet['phase'], packet['id']
                attempts[identity] = attempts.get(identity, 0) + 1
                choices = view['legalSenseAnchors' if phase == 'sense' else 'legalAttempts']
                action = ({'sense': choices[0]} if phase == 'sense' else
                          {'cell': choices[0], 'say': '', 'notes': '', 'guess': []})
                sampled = action.copy()
                if origin == 'model-mismatch':
                    assert len(choices) > 1
                    sampled['sense' if phase == 'sense' else 'cell'] = choices[1]
                evidence = dict.fromkeys(NULL_FIELDS)
                evidence.update({'attempt_id': f'{slot}-{identity}-{attempts[identity]}',
                                 'policy': 'asserted-player', 'origin': 'model' if origin == 'model-mismatch' else origin,
                                 'model': 'asserted-player', 'model_identity': 'a' * 40,
                                 'prompt': packet['messages'], 'request': {'untrusted_assertion': origin},
                                 'response': json.dumps(sampled), 'raw_response': json.dumps(sampled),
                                 'decoder': {'method': 'asserted-player'}})
                await connection.send(json.dumps({'type': 'action', 'id': identity,
                                                   **action, 'training_attempt': evidence}))
            elif packet['type'] == 'final': return
    raise AssertionError('player closed before final')


async def players(port, origin):
    for _ in range(100):
        with socket.socket() as probe:
            if probe.connect_ex(('127.0.0.1', port)) == 0: break
        await asyncio.sleep(.05)
    else: raise AssertionError('game did not open sockets')
    await asyncio.wait_for(asyncio.gather(player(0, port, origin), player(1, port, origin)), 60)


manifest = json.loads((ROOT / 'coworld_manifest_template.json').read_text())
for variant in ('dark-hex-5', 'recon-hex-5'):
    for origin in ('teacher', 'human', 'model-mismatch'):
        config = next(row['game_config'] for row in manifest['variants'] if row['id'] == variant).copy()
        config.update({'tokens': ['t0', 't1'], 'players': [{'name': 'p0'}, {'name': 'p1'}],
                       'seed': 21, 'first': 0, 'maxPlies': 4, 'turnDelayMs': 0,
                       'llmTimeoutSeconds': 10, 'player_connect_timeout_seconds': 10})
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / 'config.json').write_text(json.dumps(config))
            with socket.socket() as reserve:
                reserve.bind(('127.0.0.1', 0)); port = reserve.getsockname()[1]
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(('ANTHROPIC_', 'AWS_', 'TYPESAFE_'))}
            env.update({'COGAME_HOST': '127.0.0.1', 'COGAME_PORT': str(port),
                        'COGAME_CONFIG_URI': (output / 'config.json').as_uri(),
                        'COGAME_RESULTS_URI': (output / 'results.json').as_uri(),
                        'COGAME_SAVE_REPLAY_URI': (output / 'replay.json').as_uri(),
                        'COGAME_SAVE_TRAJECTORY_URI': (output / 'trajectory.jsonl').as_uri(),
                        'COWORLD_EPISODE_ID': str(uuid.uuid4()), 'COWORLD_GAME_VERSION': 'attack-fixture',
                        'COWORLD_SOURCE_REVISION': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()})
            with (output / 'game.log').open('w') as log:
                game = subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log)
                try:
                    asyncio.run(players(port, origin))
                    assert game.wait(timeout=35) == 0
                    events = [json.loads(line) for line in (output / 'trajectory.jsonl').read_text().splitlines()]
                    assert events[-1]['status'] == 'completed'
                    assert len(events[:-1]) == (8 if variant == 'recon-hex-5' else 4)
                    for decision in events[:-1]:
                        if origin == 'model-mismatch':
                            assert len(decision['attempts']) == 2
                            assert decision['selected_attempt_id'] is None and decision['action_status'] == 'fallback'
                            for attempt in decision['attempts']:
                                assert attempt['origin'] == 'model' and not attempt['accepted']
                                assert attempt['parsed_action'] == json.loads(attempt['response'])
                        else:
                            assert decision['action_status'] == 'accepted'
                            assert all(attempt['origin'] == 'unknown' for attempt in decision['attempts'])
                    print(variant, origin, 'no untrusted training targets', flush=True)
                finally:
                    if game.poll() is None: game.terminate(); game.wait(timeout=5)
