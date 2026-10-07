"""Isolated contract checks for the experimental ordinary worker route."""

from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import jsonschema


ROOT = Path(__file__).resolve().parents[1]
PROFILE = json.loads((ROOT / "profiles/ordinary-worker-v1.json").read_text())
SCHEMA = json.loads((ROOT / "schemas/profile.schema.json").read_text())


def bootstrap_functions(script: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    # Load real function definitions without executing bootstrap.sh's main.
    with tempfile.TemporaryDirectory() as temporary:
        fixture = Path(temporary)
        (fixture / "scripts").mkdir()
        (fixture / "lib").mkdir()
        shutil.copyfile(ROOT / "lib/common.sh", fixture / "lib/common.sh")
        shutil.copyfile(ROOT / "lib/VERSION", fixture / "lib/VERSION")
        body = (ROOT / "scripts/bootstrap.sh").read_text().split("exec 9>&1\nmain \"$@\"")[0]
        harness = fixture / "scripts/harness.sh"
        harness.write_text(body + "\n" + script)
        return subprocess.run(["bash", str(harness)], env=env, text=True,
                              capture_output=True, check=False)


class WorkerProfileTest(unittest.TestCase):
    def test_schema_and_static_budget(self) -> None:
        jsonschema.Draft202012Validator(SCHEMA).validate(PROFILE)
        for change in (
            lambda p: p["platform"].append({"id": "caddy", "steady_mb": 1, "cap_mb": 1, "disk_gb": 1}),
            lambda p: p["slices"].pop("corp-coding"),
            lambda p: p["vpn"].update(hub_role="self"),
            lambda p: p["services"][0].update(variant="full"),
        ):
            changed = copy.deepcopy(PROFILE)
            change(changed)
            with self.assertRaises(jsonschema.ValidationError):
                jsonschema.Draft202012Validator(SCHEMA).validate(changed)
        result = subprocess.run([str(ROOT / "scripts/sizing-check.sh"), "--static", "--all"],
                                env={**os.environ, "CI_PROFILE_DIR": str(ROOT / "profiles")},
                                text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Profile: ordinary-worker-v1", result.stdout)

    def test_stage_routes_and_domain_free_worker_apply(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for repo, script in (("vpn-proxy", "install-worker-network.sh"),
                                 ("ent-infra", "install-observability.sh")):
                path = root / repo / "scripts" / script
                path.parent.mkdir(parents=True)
                path.write_text("#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >> \"$ROUTE_LOG\"\n")
                path.chmod(0o755)
            env = {**os.environ, "CI_ROOT": str(root),
                   "CI_PROFILE_DIR": str(ROOT / "profiles"),
                   "ROUTE_LOG": str(root / "routes")}
            code = """
BS_WORKER=1
PROFILE_NAME=ordinary-worker-v1
PROFILE_JSON=\"$CI_PROFILE_DIR/ordinary-worker-v1.json\"
state_set() { :; }
log() { :; }
test \"$(stage_marker vpn-proxy)\" = worker-network.ready
test \"$(stage_marker ent-infra)\" = ent-infra.worker-observability.installed
test \"$(stage_check_cmd vpn-proxy)\" = \"$CI_ROOT/vpn-proxy/scripts/install-worker-network.sh\"
test \"$(stage_check_cmd ent-infra)\" = \"$CI_ROOT/ent-infra/scripts/install-observability.sh\"
run_stage vpn-proxy
run_stage ent-infra
BS_WORKER=0
test \"$(stage_entries vpn-proxy)\" = $'install-wireguard.sh\\ninstall-proxy.sh'
test \"$(stage_marker vpn-proxy)\" = proxy.ready
test \"$(stage_check_cmd ent-infra)\" = \"$CI_ROOT/ent-infra/scripts/check-all.sh\"
"""
            result = bootstrap_functions(code, env)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            routes = (root / "routes").read_text().splitlines()
            self.assertEqual(len(routes), 2)
            self.assertIn("install-worker-network.sh --yes --profile ordinary-worker-v1", routes[0])
            self.assertIn("install-observability.sh --yes --profile ordinary-worker-v1", routes[1])
            self.assertNotIn("--domain", "\n".join(routes))
            self.assertNotIn("install-proxy", "\n".join(routes))

    def test_check_does_not_touch_existing_log_or_create_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / "logs/corp-infra-bootstrap/bootstrap.sh.log"
            log.parent.mkdir(parents=True)
            log.write_text("existing log\n")
            before = log.stat().st_mtime_ns
            env = {**os.environ, "CI_ROOT": str(root / "repos"),
                   "CI_STATE": str(root / "state"), "CI_LOGDIR": str(root / "logs"),
                   "CI_PROFILE_DIR": str(ROOT / "profiles")}
            result = subprocess.run([str(ROOT / "scripts/bootstrap.sh"), "--check",
                                     "--profile", "ordinary-worker-v1"],
                                    env=env, text=True, capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("all 5 stages are pending", result.stdout + result.stderr)
            self.assertFalse((root / "state").exists())
            self.assertEqual(log.read_text(), "existing log\n")
            self.assertEqual(log.stat().st_mtime_ns, before)

    def test_worker_admission_requires_attestation_and_clean_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            recon = state / "recon/latest.json"
            recon.parent.mkdir()
            env = {**os.environ, "CI_STATE": str(state),
                   "CI_PROFILE_DIR": str(ROOT / "profiles")}
            recon.write_text(json.dumps({"facts": {"existing_components": []}}))
            absent = bootstrap_functions("BS_WORKER=1; worker_admission", env)
            self.assertEqual(absent.returncode, 2, absent.stdout + absent.stderr)
            recon.write_text(json.dumps({"facts": {"existing_components": [
                {"id": "caddy-public", "present": True}]}}))
            conflict = bootstrap_functions(
                "BS_WORKER=1; BS_WORKER_HOST_ATTESTED=1; worker_admission", env)
            self.assertEqual(conflict.returncode, 1, conflict.stdout + conflict.stderr)
            recon.write_text(json.dumps({"facts": {"existing_components": []}}))
            clean = bootstrap_functions(
                "BS_WORKER=1; BS_WORKER_HOST_ATTESTED=1; worker_admission", env)
            self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)


if __name__ == "__main__":
    unittest.main()
