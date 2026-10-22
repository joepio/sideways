#!/usr/bin/env python3
"""Plays a fake GameNight host against the game, headless.

Checks the session lifecycle and the controller path: hello, declared
settings and a change from the party, prepare with a local seat and a bot
seat, ready, start, the left stick moves seat 0, A pulls the handbrake, RB shifts once the gearbox is manual, X resets, Start opens the
settings menu, a change there is sent to GameNight, B closes it, pause, resume and dispose. Grow it with every control you add.

    python3 tests/lifecycle.py [--godot path/to/godot] [--pack game.pck]   (needs `websockets`)
"""
import argparse
import asyncio
import json
import os
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

import websockets

ROOT = Path(__file__).resolve().parents[1]
GAME_ID = json.loads((ROOT / "gamenight.json").read_text())["id"]
A, B, X, RB, START = 0, 1, 2, 5, 7


def frame(buttons=0, move=(0, 0), throttle=0):
    axes = [move[0], move[1], 0, 0, 0, throttle]
    return {"type": "controller_frame", "controllers": [{"controller": "pad1", "axes": axes, "buttons": buttons}]}


async def run(godot: str, pack: str = "") -> None:
    inbox: asyncio.Queue = asyncio.Queue()
    conn = {}
    lines: list[str] = []

    async def handler(ws):
        conn["ws"] = ws
        try:
            async for text in ws:
                await inbox.put(json.loads(text))
        except websockets.ConnectionClosed:
            pass

    async def expect(kind, check=lambda m: True, timeout=30.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while True:
            left = end - loop.time()
            if left <= 0:
                raise AssertionError(f"timed out waiting for {kind}")
            m = await asyncio.wait_for(inbox.get(), left)
            if m.get("type") == kind and check(m):
                return m

    async def send(msg):
        await conn["ws"].send(json.dumps(msg))

    async def hold(msg, seconds):
        # The SDK treats input older than 250 ms as released, so keep sending.
        for _ in range(int(seconds / 0.05)):
            await send(msg)
            await asyncio.sleep(0.05)

    # The game writes to a file, not a pipe: a full pipe stalls Godot on Windows.
    log = tempfile.NamedTemporaryFile(prefix="game-", suffix=".log", delete=False)
    log.close()

    async def saw(text, timeout=8.0):
        loop = asyncio.get_running_loop()
        end = loop.time() + timeout
        while loop.time() < end:
            lines[:] = Path(log.name).read_text(errors="replace").splitlines()
            for line in lines:
                if text in line:
                    return line
            await asyncio.sleep(0.1)
        raise AssertionError(f"game never printed {text!r}; last lines: {lines[-8:]}")

    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    async with websockets.serve(handler, "127.0.0.1", port):
        env = dict(os.environ, GAMENIGHT="1", GAMENIGHT_ADDR=f"127.0.0.1:{port}",
                   GAMENIGHT_GAME_ID=GAME_ID, GAMENIGHT_TOKEN="t", GAME_TRACE="1")
        game = ["--main-pack", pack] if pack else ["--path", str(ROOT)]
        output = open(log.name, "w")
        proc = subprocess.Popen([godot, "--headless", *game], env=env,
                                stdout=output, stderr=subprocess.DEVNULL)
        try:
            hello = await expect("hello")
            assert hello["game"] == GAME_ID and hello.get("token") == "t", hello
            await send({"type": "welcome", "party": {}})
            declared = await expect("declare_settings")
            keys = {s["key"] for s in declared["settings"]}
            assert keys == {"gearbox", "stage_km", "rivals", "contact", "weather", "vegetation", "render_scale", "anti_aliasing"}, keys
            await send({"type": "setting_changed", "game": GAME_ID, "key": "stage_km", "value": 2})
            await saw("setting stage_km = 2")
            print("ok: settings declared and changed by the party")
            seats = [
                {"index": 0, "controller": "pad1", "occupant": {"kind": "local", "player_id": "ada"}},
                {"index": 1, "occupant": {"kind": "ai"}},
                {"index": 2, "occupant": {"kind": "local", "player_id": "bo"}},
            ]
            players = [{"id": "ada", "name": "Ada", "color": "#3d8fe0", "couch": 1}, {"id": "bo", "name": "Bo", "couch": 0}]
            await send({"type": "prepare", "game": GAME_ID, "session": "s1", "seats": seats, "players": players})
            await expect("ready", lambda m: m.get("session") == "s1")
            await saw("loading complete")
            await saw("seated Ada (seat 0), bot, Bo (seat 2)")
            loaded_at = next(i for i, line in enumerate(lines) if "loading complete" in line)
            seated_at = next(i for i, line in enumerate(lines) if "seated Ada" in line)
            assert loaded_at < seated_at, "ready/seated must follow completed stage loading"
            await saw("views Bo, Ada, bot")
            print("ok: views follow the couch, not the seats")
            await send({"type": "start", "session": "s1"})
            await saw("running")
            print("ok: prepared, ready and started")

            # Countdown, then the right trigger drives.
            await saw("stage go", timeout=12)
            await hold(frame(throttle=32767), 2.5)
            await saw("drove Ada")
            print("ok: the right trigger drives seat 0")
            await hold(frame(1 << A), 0.3)
            await saw("handbrake Ada")
            print("ok: A pulls the handbrake")
            await hold(frame(), 0.2)

            await hold(frame(1 << START), 0.15)
            await hold(frame(), 0.2)
            await saw("menu open")
            # Resume and New stage sit above the settings: two steps down to the gearbox.
            for _ in range(2):
                await hold(frame(move=(0, 32767)), 0.15)
                await hold(frame(), 0.15)
            await hold(frame(move=(32767, 0)), 0.15)
            await hold(frame(), 0.15)
            changed = await expect("set_setting")
            assert (changed["key"], changed["value"]) == ("gearbox", "manual"), changed
            print("ok: the menu writes the setting back to GameNight")
            await hold(frame(1 << B), 0.15)
            await hold(frame(), 0.2)
            line = await saw("menu closed")
            moved = float(line.split("moved ")[1].split(" ")[0])
            assert moved < 0.05, line
            print("ok: Start opens the settings menu and freezes the world, B closes it")
            await hold(frame(1 << RB, throttle=32767), 0.1)
            await hold(frame(throttle=32767), 0.3)
            await saw("shift Ada")
            print("ok: with the manual gearbox, RB shifts up")
            await hold(frame(1 << X), 0.1)
            await hold(frame(), 0.3)
            await saw("recover Ada")
            print("ok: X puts the car back on the road")

            await send({"type": "pause", "session": "s1"})
            await saw("paused")
            # A profile picked up in the lobby renames the driver in place.
            await send({"type": "players_updated", "session": "s1", "players": [{"id": "ada", "name": "Joep", "color": "#3d8fe0"}]})
            await saw("renamed Joep (seat 0)")
            # Moving on the couch in the lobby slides the views over.
            await send({"type": "players_updated", "session": "s1", "players": [{"id": "ada", "name": "Joep", "couch": 0}, {"id": "bo", "name": "Bo", "couch": 1}]})
            await saw("views Joep, Bo, bot")
            await send({"type": "resume", "session": "s1"})
            await saw("running")
            assert not any("seated Joep" in line for line in lines), "a rename must not reseat"
            print("ok: pause, rename and couch move in place, and resume")
            await send({"type": "dispose", "session": "s1"})
            await saw("disposed")
            print("ok: disposed")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            output.close()
            os.unlink(log.name)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    ap.add_argument("--pack", default="")
    args = ap.parse_args()
    asyncio.run(run(args.godot, args.pack))
    print("lifecycle: all good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
