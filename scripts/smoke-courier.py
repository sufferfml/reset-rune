#!/usr/bin/env python3
"""Isolated courier service/menu round trip. No launchd, real app, login, or AX."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--bin-dir", type=Path, default=ROOT / "native/.build/out/Products/Debug")
args = parser.parse_args()
port = 41000 + (os.getuid() % 6000) * 2 + 1
with socket.socket() as probe:
    probe.bind(("127.0.0.1", port))  # Refuse conflict; never stop somebody else's mock.
processes = []
out = ROOT / ".build/courier-smoke"
out.mkdir(parents=True, exist_ok=True)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

with tempfile.TemporaryDirectory(prefix="reset-rune-courier-smoke-") as name:
    work = Path(name)
    data, codex = work / "data", work / "empty-codex"
    data.mkdir(mode=0o700)
    codex.mkdir(mode=0o700)
    env = {**os.environ, "RESET_RUNE_DATA_DIR": str(data), "CODEX_HOME": str(codex),
           "RESET_RUNE_CODEX_PATH": "/not-a-real-runtime"}
    log = (out / "processes.log").open("w")
    connection = None

    def start_service():
        process = subprocess.Popen([str(args.bin_dir / "reset-rune"), "--serve", "--mock"],
                                   env=env, stdout=log, stderr=log)
        processes.append(process)
        return process

    def api(path, method="GET", body=None):
        headers = {"Authorization": "Bearer " + connection["token"]}
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"http://127.0.0.1:{port}/api/{path}", method=method, headers=headers,
            data=None if body is None else json.dumps(body).encode())
        with opener.open(request, timeout=3) as response:
            return json.load(response)

    def wait_connection(service, previous_token=None):
        file = data / "simulation/connection.json"
        for _ in range(120):
            if service.poll() is not None:
                raise RuntimeError("Owned mock service exited; inspect .build/courier-smoke/processes.log")
            if file.exists():
                value = json.loads(file.read_text())
                if value["mode"] == "mock" and value["token"] != previous_token:
                    return value
            time.sleep(.1)
        raise RuntimeError("Mock service did not become ready")

    try:
        service = start_service()
        connection = wait_connection(service)
        menu = subprocess.Popen([str(args.bin_dir / "BottledResetRuneMenu"), "--mock", "--start-hidden"],
                                env=env, stdout=log, stderr=log)
        processes.append(menu)
        now = int(time.time() * 1000)
        for agent in ("codex", "claude"):
            target = {"agent": agent, "bundleID": "local.reset-rune.mock." + agent,
                      "sourceID": "simulation", "threadID": "mock-" + agent,
                      "title": "Synthetic " + agent, "appVersion": "simulation"}
            api("courier/tasks", "POST", {"name": "Synthetic " + agent, "text": "只回复模拟结果 👋。\n'quoted'",
                "target": target, "scheduledAt": now + 2000, "deadlineAt": now + 902000,
                "timeZoneID": "Asia/Shanghai", "enabled": True})
        api("courier/settings", "PATCH", {"enabled": True})
        for _ in range(150):
            snapshot = api("courier/status")
            if len(snapshot["runs"]) == 2 and all(run["status"] == "sent" for run in snapshot["runs"]):
                break
            if menu.poll() is not None:
                raise RuntimeError("Owned mock menu exited")
            time.sleep(.1)
        else:
            raise RuntimeError("Simulation did not deliver both agents: " +
                               repr([(run["status"], run.get("waitReason")) for run in snapshot["runs"]]))
        assert all(len(run["attempts"]) == 1 for run in snapshot["runs"])
        assert api("status")["config"]["enabled"] is False, "Courier changed reset authorization"
        previous = connection["token"]
        service.send_signal(signal.SIGTERM)
        service.wait(timeout=10)
        service = start_service()
        connection = wait_connection(service, previous)
        # Stored sent runs must remain terminal across service epoch/token rotation.
        time.sleep(1)
        restored = api("courier/status")
        assert all(run["status"] == "sent" and len(run["attempts"]) == 1 for run in restored["runs"])
        api("courier/settings", "PATCH", {"enabled": False})
        assert not list(codex.iterdir()), "Synthetic pipeline accessed Codex home"
        report = {"syntheticOnly": True, "desktopAgents": ["codex", "claude"], "sent": 2,
                  "singleAttemptEach": True, "serviceRestartRetainedResults": True,
                  "resetAuthorizationUnchanged": True, "codexHomeUntouched": True}
        (out / "report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        log.close()
