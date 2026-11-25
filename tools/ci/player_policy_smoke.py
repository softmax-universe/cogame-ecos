#!/usr/bin/env python3
"""Run native Ecos host+player round-trip episodes covering valid bare/fenced JSON,
invalid/ambiguous replies, provider failures, missing credentials, and missing or
disconnected seats (zero-participant startup, partial startup, and mid-game disconnect)."""

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


def run_episode(reply_fn=None, with_endpoint=True, expect_failure=False,
                expect_failure_artifact=True,
                seat_slots=(0, 1, 2), connect_timeout=10,
                kill_slot_after_requests=None):
    requests = {"prompt": 0}
    players = []
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
                if (kill_slot_after_requests is not None and
                        requests["prompt"] == kill_slot_after_requests):
                    # Abruptly disconnect seat 1 mid-turn before replying.
                    for slot_idx, proc in players:
                        if slot_idx == 1 and proc.poll() is None:
                            proc.kill()
                            break
                    time.sleep(0.2)
                    self.send_response(503)
                    self.end_headers()
                    return
                outcome = reply_fn(requests["prompt"])
                if isinstance(outcome, tuple):
                    status, payload = outcome
                    encoded = payload.encode()
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(encoded)))
                    self.end_headers()
                    self.wfile.write(encoded)
                else:
                    reply = {"content": [{"type": "text", "text": outcome}], "stop_reason": "end_turn"}
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
                  "playerConnectTimeoutSeconds": connect_timeout, "shutdownGraceSeconds": 0}
        (root / "config.json").write_text(json.dumps(config))
        game_env = os.environ.copy()
        game_env.update({"COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
                         "COGAME_CONFIG_URI": (root / "config.json").as_uri(),
                         "COGAME_RESULTS_URI": (root / "results.json").as_uri(),
                         "COGAME_SAVE_REPLAY_URI": (root / "replay.json").as_uri(),
                         "COGAME_PLAYER_FAILURE_URI": (root / "player_failure.json").as_uri(),
                         "COGAME_LOG_URI": (root / "episode.log").as_uri()})
        game = subprocess.Popen([GAME], env=game_env, stdout=(root / "game.log").open("w"),
                                stderr=subprocess.STDOUT)
        seat_configs = (
            {"PLAYER_SCRIPTED": "opportunist"},
            {"PLAYER_PROMPT": "Keep the ecosystem balanced."},
            {"PLAYER_SCRIPTED": "steward"},
        )
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
            for slot in seat_slots:
                settings = seat_configs[slot]
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
                players.append((slot, subprocess.Popen([PLAYER], env=env,
                               stdout=(root / f"player-{slot}.log").open("w"),
                               stderr=subprocess.STDOUT)))
            game_rc = game.wait(timeout=35)
            player_rcs = {slot: player.wait(timeout=5) for slot, player in players}
            results_path = root / "results.json"
            replay_path = root / "replay.json"
            failure_path = root / "player_failure.json"
            log_text = (root / "episode.log").read_text() if (root / "episode.log").exists() else ""
            if expect_failure:
                assert game_rc != 0, f"expected failed episode exit != 0, got 0:\n{(root / 'game.log').read_text()}"
                if 1 in player_rcs:
                    assert player_rcs[1] != 0, f"expected failing player exit != 0, got {player_rcs}"
                for innocent in (0, 2):
                    if innocent in player_rcs:
                        assert player_rcs[innocent] == 0, f"innocent seat {innocent} should exit 0, got {player_rcs}"
                assert not results_path.exists(), f"failed episode must not write numeric results: {results_path.read_text()}"
                assert not replay_path.exists(), "failed episode must not write scored replay"
                if expect_failure_artifact:
                    assert failure_path.exists(), f"missing player_failure.json:\n{(root / 'game.log').read_text()}"
                    failure = json.loads(failure_path.read_text())
                    assert set(failure.keys()) == {"failed_policy_index", "message", "kind"}, failure
                    assert isinstance(failure["failed_policy_index"], int) and failure["failed_policy_index"] >= 0, failure
                    assert isinstance(failure["message"], str) and 1 <= len(failure["message"]) <= 2000, failure
                    assert failure["kind"] in ("player_error", "episode_inconclusive"), failure
                    return requests, failure, log_text
                assert not failure_path.exists(), f"unattributed failure must not invent a seat: {failure_path.read_text()}"
                return requests, None, log_text
            else:
                assert game_rc == 0, (root / "game.log").read_text()
                for slot, rc in player_rcs.items():
                    assert rc == 0, (root / f"player-{slot}.log").read_text()
                assert not failure_path.exists(), failure_path.read_text()
                results = json.loads(results_path.read_text())
                replay = json.loads(replay_path.read_text())
                return requests, results, replay
        finally:
            for _slot, process in players:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            if game.poll() is None:
                game.terminate()
                game.wait(timeout=5)
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
assert len(results["scores"]) == 3 and all(isinstance(s, (int, float)) for s in results["scores"]), results

# 2. Ambiguous prose around JSON is rejected and terminates unscored with player_error.
requests, failure, log_text = run_episode(
    lambda _n: f"Here is my doctrine:\n{valid_payload}",
    expect_failure=True,
)
assert requests == {"prompt": 1}, requests
assert failure["failed_policy_index"] == 1, failure
assert failure["kind"] == "player_error", failure
assert "invalid JSON object" in failure["message"], failure
assert "seat=Bramble" in log_text and "role=grazers" in log_text, log_text
assert "terminated unscored" in log_text, log_text

# 3. Provider HTTP failure (503) terminates unscored with episode_inconclusive and no numeric results.
requests, failure, log_text = run_episode(
    lambda _n: (503, '{"error":{"message":"upstream unavailable"}}'),
    expect_failure=True,
)
assert requests == {"prompt": 1}, requests
assert failure["failed_policy_index"] == 1, failure
assert failure["kind"] == "episode_inconclusive", failure
assert "503" in failure["message"], failure
assert "terminated unscored" in log_text, log_text

# 4. Missing credentials on a prompt player terminates unscored with episode_inconclusive and no numeric results.
requests, failure, log_text = run_episode(with_endpoint=False, expect_failure=True)
assert requests == {"prompt": 0}, requests
assert failure["failed_policy_index"] == 1, failure
assert failure["kind"] == "episode_inconclusive", failure
assert failure["message"] == "no LLM credentials configured", failure
assert "terminated unscored" in log_text, log_text

# 5. Zero seats connected at startup terminates unscored without inventing a seat (no forfeit/zero results).
requests, failure, log_text = run_episode(
    with_endpoint=False,
    expect_failure=True,
    expect_failure_artifact=False,
    seat_slots=(),
    connect_timeout=1,
)
assert requests == {"prompt": 0}, requests
assert failure is None, failure
assert "no seats connected" in log_text, log_text
assert "terminated unscored" in log_text, log_text

# 6. Partially connected roster at startup (seat 1 missing) terminates unscored with episode_inconclusive.
requests, failure, log_text = run_episode(
    with_endpoint=False,
    expect_failure=True,
    seat_slots=(0, 2),
    connect_timeout=1,
)
assert requests == {"prompt": 0}, requests
assert failure["failed_policy_index"] == 1, failure
assert failure["kind"] == "episode_inconclusive", failure
assert "did not connect" in failure["message"], failure
assert "seat=Bramble" in log_text and "role=grazers" in log_text, log_text
assert "terminated unscored" in log_text, log_text

# 7. Mid-game disconnect of a required model seat terminates unscored with episode_inconclusive.
requests, failure, log_text = run_episode(
    lambda _n: valid_payload,
    expect_failure=True,
    kill_slot_after_requests=2,
)
assert requests == {"prompt": 2}, requests
assert failure["failed_policy_index"] == 1, failure
assert failure["kind"] == "episode_inconclusive", failure
assert "disconnected" in failure["message"], failure
assert "seat=Bramble" in log_text and "role=grazers" in log_text, log_text
assert "terminated unscored" in log_text, log_text

print("ecos player smoke: valid bare/fenced replies pass; invalid reply, provider failure, missing credentials, absent roster, partial roster, and mid-game disconnect terminate unscored with diagnostics")
