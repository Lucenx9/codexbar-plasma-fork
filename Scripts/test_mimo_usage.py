#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch


def load_mimo_usage():
    script_path = Path(__file__).with_name("mimo-usage.py")
    spec = importlib.util.spec_from_file_location("mimo_usage", script_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {script_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MiMoUsageCacheTests(unittest.TestCase):
    def test_concurrent_writers_publish_without_colliding(self):
        module = load_mimo_usage()
        original_cache_path = module.CACHE_PATH
        original_replace = os.replace
        replace_barrier = threading.Barrier(2)
        failures = []

        def synchronized_replace(source, destination):
            replace_barrier.wait(timeout=2)
            return original_replace(source, destination)

        with tempfile.TemporaryDirectory(prefix="codexbar-mimo-cache-") as root:
            cache_path = Path(root) / "usage.json"
            module.CACHE_PATH = cache_path
            try:
                def write_cache():
                    try:
                        module.write_cache({}, 0, None)
                    except Exception as error:
                        failures.append(error)

                with patch.object(os, "replace", synchronized_replace):
                    writers = [threading.Thread(target=write_cache) for _ in range(2)]
                    for writer in writers:
                        writer.start()
                    for writer in writers:
                        writer.join(timeout=5)

                self.assertTrue(all(not writer.is_alive() for writer in writers))
                self.assertEqual(failures, [])
                self.assertEqual(json.loads(cache_path.read_text())["sessions_scanned"], 0)
            finally:
                module.CACHE_PATH = original_cache_path


if __name__ == "__main__":
    unittest.main()
