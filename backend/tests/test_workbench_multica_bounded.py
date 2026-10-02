"""验证真实 Swift 同步器的查询上限、标签撤回和失败保留。"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BoundedMultica(unittest.TestCase):
    def test_actual_sync_actor(self):
        with tempfile.TemporaryDirectory(prefix="panorama-sync-test-") as folder:
            binary = str(Path(folder) / "verify")
            subprocess.run(["swiftc", str(ROOT / "Sources/CortexSentinelBar/WorkbenchLedger.swift"),
                            str(ROOT / "Sources/CortexSentinelBar/WorkbenchMultica.swift"),
                            str(Path(__file__).with_name("workbench_multica_fixture.swift")),
                            "-o", binary], check=True, capture_output=True, timeout=120)
            result = subprocess.run([binary], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("bounded_sync_cases_passed=4", result.stdout)
