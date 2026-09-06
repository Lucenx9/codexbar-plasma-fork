#!/usr/bin/env python3
"""Run the MiMo CLI against synthetic session files, before or after the fix."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[2]
relative_script = "Scripts/mimo-usage.py"
source = (
    subprocess.check_output(["git", "show", f"c15f736ef:{relative_script}"], cwd=repo, text=True)
    if sys.argv[1:] == ["baseline"]
    else (repo / relative_script).read_text()
)
valid = {"timestamp": "2026-01-01T12:00:00Z", "message": {"usage": {"input_tokens": 12}}}
cases = {
    "invalid UTF-8": b"\xff",
    "non-object JSON": [],
    "numeric timestamp": {**valid, "timestamp": 123},
    "invalid token count": {**valid, "message": {"usage": {"input_tokens": "unknown"}}},
}
failures = 0
for label, invalid in cases.items():
    with tempfile.TemporaryDirectory(prefix="codexbar-mimo-proof-") as root:
        root = Path(root)
        candidate = root / "mimo-usage.py"
        candidate.write_text(source)
        projects = root / "home" / ".claude" / "projects"
        projects.mkdir(parents=True)
        (projects / "session.jsonl").write_bytes(b"\n".join(
            row if isinstance(row, bytes) else json.dumps(row).encode("utf-8")
            for row in [valid, invalid, valid]
        ))
        cache = root / "usage.json"
        result = subprocess.run(
            [sys.executable, str(candidate), "--json"],
            env={**os.environ, "MIMO_CLAUDE_HOME": str(root / "home"), "MIMO_LOCAL_USAGE_PATH": str(cache)},
            text=True, capture_output=True, check=False,
        )
        observation = {"case": label, "exit_code": result.returncode, "cache_written": cache.exists()}
        if result.returncode:
            observation["error"] = result.stderr.strip().splitlines()[-1]
            failures += 1
        else:
            payload = json.loads(result.stdout)
            assert json.loads(cache.read_text()) == payload
            totals = payload["windows"]["all_time"]
            assert totals == {"input": 24, "output": 0, "cache_read": 0, "cache_create": 0, "messages": 2}
            observation["totals"] = totals
        print(json.dumps(observation))
print(f"{'FAIL' if failures else 'PASS'}: {len(cases) - failures}/{len(cases)} CLI fixtures refreshed the cache")
sys.exit(1 if failures else 0)
