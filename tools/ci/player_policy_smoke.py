#!/usr/bin/env python3
"""Run native Ecos episodes with stub player-side model endpoints, including strict rejection/forfeit."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GAME, PLAYER = sys.argv[1:3]


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run_episode(reply_fn=None, with_endpoint=True):
    requests = {"prompt": 0}
    model = None
    if with_endpoint:
        class Stub(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.path == "/v1/messages"
                assert body["model"] == "anthropic/claude-haiku-4.5"
                assert "anthropic_version" not in body
                assert body["system"] == (
                    "Reply with ONLY one JSON object containing the four-integer doctrine for the next generation. "
                    "In Ecos you control the grazers species, pursuing integrated biomass without collapsing the food chain."
                )
                requests["prompt"] += 1
                assert self.headers["x-coworld-player-slot"] == "1"
                text = reply_fn(requests["prompt"])
                reply = {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}
                encoded = json.dumps(reply).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, *_args):
                pass

        model = ThreadingHTTPServer(("127.0.0.1", free_port()), Stub)
        threading.Thread(target=model.serve_forever, daemon=True).start()

    port = free_port()
    with tempfile.TemporaryDirectory(prefix="ecos-policy-") as scratch:
        root = Path(scratch)
        config = {"tokens": ["token-0", "token-1", "token-2"],
                  "players": [{"name": name} for name in ("Sedge", "Bramble", "Quill")],
                  "num_agents": 3, "seed": 7, "roleOffset": 0,
                  "promptVariant": "mixed", "promptSeed": 4,
                  "generations": 2, "ticksPerGeneration": 10,
                  "actionTimeoutSeconds": 5, "minTurnSeconds": 0,
                  "playerConnectTimeoutSeconds": 10, "shutdownGraceSeconds": 0}
        (root / "config.json").write_text(json.dumps(config))
        game_env = os.environ.copy()
        game_env.update({"COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
                         "COGAME_CONFIG_URI": (root / "config.json").as_uri(),
                         "COGAME_RESULTS_URI": (root / "results.json").as_uri(),
                         "COGAME_SAVE_REPLAY_URI": (root / "replay.json").as_uri()})
        game = subprocess.Popen([GAME], env=game_env, stdout=(root / "game.log").open("w"),
                                stderr=subprocess.STDOUT)
        players = []
        try:
            for _ in range(100):
                if game.poll() is not None:
                    raise AssertionError((root / "game.log").read_text())
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game health unavailable")
            for slot, settings in enumerate((
                {"PLAYER_SCRIPTED": "opportunist"},
                {"PLAYER_PROMPT": "Keep the ecosystem balanced."},
                {"PLAYER_SCRIPTED": "steward"},
            )):
                env = os.environ.copy()
                for key in ("COWORLD_LLM_ENDPOINT", "ANTHROPIC_API_KEY",
                            "ANTHROPIC_API_KEY_URI", "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
                            "AWS_BEARER_TOKEN_BEDROCK"):
                    env.pop(key, None)
                env.update(settings)
                env["COWORLD_PLAYER_WS_URL"] = (
                    f"ws://127.0.0.1:{port}/player?slot={slot}&token=token-{slot}"
                )
                if model is not None:
                    env["COWORLD_LLM_ENDPOINT"] = f"http://127.0.0.1:{model.server_port}"
                players.append(subprocess.Popen([PLAYER], env=env,
                               stdout=(root / f"player-{slot}.log").open("w"),
                               stderr=subprocess.STDOUT))
            assert game.wait(timeout=35) == 0, (root / "game.log").read_text()
            for slot, player in enumerate(players):
                assert player.wait(timeout=5) == 0, (root / f"player-{slot}.log").read_text()
            results = json.loads((root / "results.json").read_text())
            replay = json.loads((root / "replay.json").read_text())
            return requests, results, replay
        finally:
            for process in [*players, game]:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            if model is not None:
                model.shutdown()


valid_payload = json.dumps({
    "doctrine": {"birth_threshold": 110, "bite": 8,
                 "flee_range": 90, "herd": 55},
    "say": "keeping balance", "notes": "stub reply"
})

# 1. Valid replies (bare JSON on gen 1, single ```json fence on gen 2) complete cleanly.
requests, results, replay = run_episode(
    lambda n: valid_payload if n == 1 else f"```json\n{valid_payload}\n```"
)
assert requests == {"prompt": 2}, requests
doctrines = [event for event in replay["events"] if event["k"] == "doctrine"]
sources = [event["source"] for event in doctrines]
assert sources.count("llm") == 2, sources
assert sources.count("scripted") == 4, sources
assert sources.count("fallback") == 0, sources
assert results["reason"] == "complete", results

# 2. Ambiguous prose around JSON is rejected and forfeits instead of falling back.
requests, results, replay = run_episode(
    lambda _n: f"Here is my doctrine:\n{valid_payload}"
)
assert requests == {"prompt": 1}, requests
doctrines = [event for event in replay["events"] if event["k"] == "doctrine"]
assert len(doctrines) == 0, doctrines
assert results["reason"] == "forfeit" and results["ending"] == "forfeit", results
assert results["scores"][1] == 0.0, results

# 3. Missing credentials on a prompt player forfeits cleanly with zero fallback.
requests, results, replay = run_episode(with_endpoint=False)
assert requests == {"prompt": 0}, requests
doctrines = [event for event in replay["events"] if event["k"] == "doctrine"]
assert len(doctrines) == 0, doctrines
assert results["reason"] == "forfeit" and results["ending"] == "forfeit", results
assert results["scores"][1] == 0.0, results

print("ecos player smoke: valid bare/fenced replies pass; invalid reply and missing credentials forfeit with zero fallback")
