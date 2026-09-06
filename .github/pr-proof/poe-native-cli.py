#!/usr/bin/env python3
"""Exercise Poe through an installed Linux CLI, QuickJS, and a local HTTPS server."""
import argparse
import hashlib
import http.server
import json
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cli-dir", required=True, type=Path)
parser.add_argument("--image", required=True, help="An already installed Debian-compatible Docker image")
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
plugin_path = "Sources/CodexBarCore/Resources/Plugins/poe.js"
baseline = subprocess.check_output(["git", "show", f"c15f736ef:{plugin_path}"], cwd=repo, text=True)
fixed = (repo / plugin_path).read_text()
now = time.time()
activity = [
    {"creation_time": now - 2 * 86400, "cost_points": 10, "cost_usd": 0.01},
    {"creation_time": now - 5 * 86400, "cost_points": 20, "cost_usd": 0.02},
    {"creation_time": now - 20 * 86400, "cost_points": 1000, "cost_usd": 1.00},
]
requests = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if self.path == "/usage/current_balance":
            payload = {"current_point_balance": 2500}
        elif self.path == "/usage/points_history?limit=100":
            payload = {"data": activity}
        else:
            self.send_error(404)
            return
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *unused):
        pass


with tempfile.TemporaryDirectory(prefix="codexbar-poe-native-") as directory:
    root = Path(directory)
    app = root / "app"
    shutil.copytree(args.cli_dir, app)
    binary = app / "CodexBarCLI"
    print("Host version:", subprocess.check_output([str(binary), "--version"], text=True).strip())
    print("Host binary SHA256:", hashlib.sha256(binary.read_bytes()).hexdigest())
    print("Plugin-only change; the installed CLI and its other resources are copied without modification.")
    cert, key = root / "cert.pem", root / "key.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
        "-addext", "subjectAltName=IP:127.0.0.1,DNS:localhost",
    ], check=True, capture_output=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"https://127.0.0.1:{server.server_port}"
    (root / "config.json").write_text(json.dumps({
        "version": 1, "providers": [{"id": "poe", "enabled": True, "apiKey": "fixture-key"}],
    }))
    command = [
        "docker", "run", "--rm", "--pull", "never", "--network", "host", "--read-only", "--tmpfs", "/tmp",
        "--mount", f"type=bind,src={root},dst=/proof,readonly",
        "--mount", "type=bind,src=/lib/x86_64-linux-gnu,dst=/lib/x86_64-linux-gnu,readonly",
        "--mount", f"type=bind,src={cert},dst=/etc/ssl/certs/ca-certificates.crt,readonly",
        "--env", "CODEXBAR_CONFIG=/proof/config.json", "--env", "XDG_CONFIG_HOME=/tmp/config",
        "--env", "POE_API_KEY=fixture-key", "--entrypoint", "/proof/app/CodexBarCLI", args.image,
        "usage", "--provider", "poe", "--source", "api", "--json",
    ]
    try:
        for scenario in ["sparse history", "empty week"]:
            for revision, source in [("baseline", baseline), ("fixed", fixed)]:
                # Redirect only the origin. Authentication, fetchUsage, host clock, transport,
                # QuickJS execution, snapshot decoding, and CLI JSON output retain their real paths.
                (app / "CodexBar_CodexBarCore.bundle" / "poe.js").write_text(
                    source.replace("https://api.poe.com", endpoint))
                requests.clear()
                result = subprocess.run(command, text=True, capture_output=True, timeout=40)
                assert result.returncode == 0, result.stderr + result.stdout
                payload = json.loads(result.stdout)
                rows = {row["label"]: row for row in payload[0]["usage"]["details"][0]["rows"]}
                expected = "1,030 points" if revision == "baseline" else (
                    "30 points" if scenario == "sparse history" else "0 points")
                assert rows["Last 7 days"]["value"] == expected, rows
                assert rows["Last 30 days"]["value"] == "1,030 points", rows
                assert rows["Last 30 days"]["secondaryValue"] == "3 requests · $1.03", rows
                assert rows["Current balance"]["value"] == "2,500 points", rows
                assert requests == ["/usage/current_balance", "/usage/points_history?limit=100"], requests
                print(json.dumps({"scenario": scenario, "revision": revision, "exit_code": result.returncode,
                                  "https_requests": list(requests), "cli_json": payload}))
            activity = [{**row, "creation_time": row["creation_time"] - 8 * 86400} for row in activity]
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
print("PASS: native CLI before/after, sparse history, empty week, 30-day total, balance, and real HTTPS requests")
