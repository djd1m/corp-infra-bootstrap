"""Timing is observable without persisting checks or disclosing child output."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from test_worker_profile import bootstrap_functions


ROOT = Path(__file__).resolve().parents[1]


class StageTimingTest(unittest.TestCase):
    def prerequisite(self, child_rc=0, marker_rc=0):
        return subprocess.run(
            ["bash", "-c", '''
set -Eeuo pipefail
source "$LIB"
state_check() { return "$MARKER_RC"; }
producer() {
    printf '%s\\n' 'CHILD_SECRET_STDOUT'
    printf '%s\\n' 'CHILD_SECRET_STDERR' >&2
    sleep 0.08
    return "$CHILD_RC"
}
require_stage backup.ready producer --token 'ARGV_SECRET'
'''],
            env={**os.environ, "LIB": str(ROOT / "lib/common.sh"),
                 "CI_MODE": "check", "CHILD_RC": str(child_rc),
                 "MARKER_RC": str(marker_rc)},
            text=True, capture_output=True, check=False,
        )

    def test_check_classification_and_redaction(self):
        for rc, classification in ((0, "ok"), (1, "condition_failed"),
                                   (2, "inconclusive"), (124, "timeout"),
                                   (127, "execution_error"), (143, "signal_exit"),
                                   (9, "unexpected_exit")):
            with self.subTest(rc=rc):
                result = self.prerequisite(rc)
                text = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0 if rc == 0 else 2, text)
                self.assertIn(f"exit_code={rc} classification={classification}", text)
                for forbidden in ("CHILD_SECRET_STDOUT", "CHILD_SECRET_STDERR",
                                  "ARGV_SECRET", "--token"):
                    self.assertNotIn(forbidden, text)
                elapsed = re.search(r"event=end .*?elapsed_ms=(\d+)", text)
                self.assertIsNotNone(elapsed, text)
                self.assertGreaterEqual(int(elapsed.group(1)), 50)

    def test_failed_and_absent_marker_do_not_execute_producer(self):
        for marker_rc, name in ((1, "marker_failed"), (2, "marker_inconclusive")):
            with self.subTest(marker_rc=marker_rc):
                result = self.prerequisite(marker_rc=marker_rc)
                self.assertEqual(result.returncode, 2)
                self.assertIn(f"operation={name}", result.stdout)
                self.assertNotIn("live_check_failed", result.stdout)

    def test_telemetry_cannot_inject_multiline_identity(self):
        result = subprocess.run(
            ["bash", "-c", '''source "$LIB"
_ci_timing_log end prerequisite $'bad\\nSECRET_ID' "$(_ci_timing_now_ms)" 1
'''], env={**os.environ, "LIB": str(ROOT / "lib/common.sh")},
            text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertIn("identity=invalid_identifier", result.stdout)
        self.assertNotIn("SECRET_ID", result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 1)

    def test_stage_failure_is_timed_and_preserves_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / "vpn-proxy/scripts/install-worker-network.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\nexit 1\n")
            script.chmod(0o755)
            result = bootstrap_functions('''
BS_WORKER=1
PROFILE_NAME=ordinary-worker-v1
state_set() { :; }
run_stage vpn-proxy
''', {**os.environ, "CI_ROOT": str(root)})
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertRegex(result.stdout,
                             r"event=end operation=stage_entry .*exit_code=1 classification=condition_failed")
            self.assertRegex(result.stdout,
                             r"event=end operation=stage .*exit_code=1 classification=condition_failed")

    def test_real_check_leaves_state_and_existing_log_unchanged(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            logfile = root / "logs/corp-infra-bootstrap/bootstrap.sh.log"
            logfile.parent.mkdir(parents=True)
            logfile.write_text("unchanged\n")
            before = logfile.stat().st_mtime_ns
            result = subprocess.run(
                [str(ROOT / "scripts/bootstrap.sh"), "--check",
                 "--profile", "ordinary-worker-v1"],
                env={**os.environ, "CI_STATE": str(root / "state"),
                     "CI_ROOT": str(root / "repos"), "CI_LOGDIR": str(root / "logs"),
                     "CI_PROFILE_DIR": str(ROOT / "profiles")},
                text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.count("event=end operation=stage_check"), 5)
            self.assertFalse((root / "state").exists())
            self.assertEqual(logfile.read_text(), "unchanged\n")
            self.assertEqual(logfile.stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()
