"""External configuration is host-bound, protected and fail-closed."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import sys
import subprocess
import re
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location('node_config', ROOT / 'scripts/node-config.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def public_recipient(number):
    alphabet = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
    data = [number] * 51 + [0]
    values = [ord(c) >> 5 for c in 'age'] + [0] + [ord(c) & 31 for c in 'age'] + data + [0] * 6
    check = 1
    for digit in values:
        top = check >> 25
        check = ((check & 0x1ffffff) << 5) ^ digit
        for index, generator in enumerate((0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)):
            if (top >> index) & 1:
                check ^= generator
    check ^= 1
    return 'age1' + ''.join(alphabet[n] for n in data + [(check >> 5 * (5 - i)) & 31 for i in range(6)])


class NodeConfig(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path.home())
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'node-config'
        self.owner = os.getuid()
        self.machine = self.base / 'machine-id'
        self.machine.write_text('a' * 32 + '\n')
        self.machine.chmod(0o600)
        self.state = self.base / 'state.json'
        self.template = self.base / 'policy'
        self.template.write_bytes((ROOT / 'tests/fixtures/node-config/public-policy.yaml').read_bytes())
        self.template.chmod(0o600)
        self.plan = self.base / 'plan.json'
        self.value = {'schema_version': 1, 'node_id': 'fixture-worker',
                      'machine_id': 'a' * 32, 'profile': 'ordinary-worker-small-v1',
                      'recipients': {'ci': public_recipient(1), 'break_glass': public_recipient(2)}}
        self.write_plan()

    def write_plan(self):
        self.plan.write_text(json.dumps(self.value))
        self.plan.chmod(0o600)

    def options(self):
        return dict(root=self.root, machine=self.machine, state=self.state, owner=self.owner)

    def prepare(self, check=False):
        MODULE.prepare(self.plan, self.template, check, **self.options())

    def resolve(self, relative='secrets/token.enc.env', repo='pop-agents'):
        return MODULE.resolve(repo, relative, '/opt/legacy/' + relative, **self.options())

    def test_absent_root_legacy_and_check_are_read_only(self):
        self.assertEqual(self.resolve(), '/opt/legacy/secrets/token.enc.env')
        before = {p.name: p.stat().st_mtime_ns for p in self.base.iterdir()}
        self.prepare(check=True)
        self.assertEqual(before, {p.name: p.stat().st_mtime_ns for p in self.base.iterdir()})
        self.assertFalse(self.root.exists())

    def test_atomic_prepare_resolves_directories_policy_and_missing_ciphertext(self):
        self.prepare()
        self.assertEqual(self.resolve('secrets'), str(self.root / 'pop-agents/secrets'))
        for repo in MODULE.REPOS:
            self.assertEqual(self.resolve('.sops.yaml', repo), str(self.root / 'security/.sops.yaml'))
        self.assertEqual(self.resolve(), str(self.root / 'pop-agents/secrets/token.enc.env'))
        self.assertEqual((self.root.stat().st_mode & 0o777), 0o700)
        self.assertEqual((self.root / 'identity.json').stat().st_mode & 0o777, 0o600)

    def test_external_policy_rules_match_encrypted_conf(self):
        self.prepare()
        text = (self.root / 'security/.sops.yaml').read_text()
        expressions = re.findall(r"path_regex: '([^']+)'", text)
        self.assertEqual(len(expressions), 2)
        for expression in expressions:
            self.assertIsNotNone(re.search(expression, 'vpn-proxy/secrets/peers/operator.enc.conf'))
        self.assertIsNone(re.search(expressions[0], 'vpn-proxy/secrets/peers/operator.conf'))

    def test_existing_prod_rewrite_and_ciphertext_preserved_idempotently(self):
        self.prepare()
        policy = self.root / 'security/.sops.yaml'
        policy.write_text(policy.read_text().replace('<prod-recipient>', public_recipient(3)))
        cipher = self.root / 'backup/secrets/offsite.enc.conf'
        cipher.write_text('opaque ciphertext')
        cipher.chmod(0o600)
        before = {str(p): (p.read_bytes(), p.stat().st_mtime_ns)
                  for p in self.root.rglob('*') if p.is_file()}
        self.prepare()
        self.assertEqual(before, {str(p): (p.read_bytes(), p.stat().st_mtime_ns)
                                 for p in self.root.rglob('*') if p.is_file()})

    def test_identity_profile_machine_and_recipient_drift_refused(self):
        self.prepare()
        for key, replacement in [('node_id', 'other'), ('machine_id', 'b' * 32),
                                 ('profile', 'ordinary-worker-v1')]:
            original = self.value[key]
            self.value[key] = replacement
            self.write_plan()
            with self.assertRaises(MODULE.Invalid):
                self.prepare()
            self.value[key] = original
        self.write_plan()
        self.state.write_text(json.dumps({'profile': 'ordinary-worker-v1'}))
        self.state.chmod(0o600)
        with self.assertRaises(MODULE.Invalid):
            self.resolve()

    def test_unprotected_plan_or_template_and_modified_policy_refused(self):
        self.plan.chmod(0o644)
        with self.assertRaises(MODULE.Invalid):
            self.prepare()
        self.plan.chmod(0o600)
        self.template.write_text(self.template.read_text().replace('secrets/', 'public/'))
        with self.assertRaises(MODULE.Invalid):
            self.prepare()
        self.template.unlink()
        os.mkfifo(self.template, 0o600)
        with self.assertRaises(MODULE.Invalid):
            self.prepare()

    def test_invalid_present_root_never_falls_back(self):
        self.root.mkdir(mode=0o700)
        with self.assertRaises(MODULE.Invalid):
            self.resolve()
        self.root.rmdir()
        self.root.symlink_to(self.base)
        with self.assertRaises(MODULE.Invalid):
            self.resolve()

    def test_layout_rejects_plaintext_extras_symlinks_links_and_permissions(self):
        self.prepare()
        path = self.root / 'backup/secrets/token.enc.env'
        for mode in (0o644, 0o660, 0o775):
            path.write_text('opaque')
            path.chmod(mode)
            with self.assertRaises(MODULE.Invalid):
                self.resolve()
            path.unlink()
        path.symlink_to(self.plan)
        with self.assertRaises(MODULE.Invalid):
            self.resolve()
        path.unlink()
        os.link(self.plan, path)
        with self.assertRaises(MODULE.Invalid):
            self.resolve()
        path.unlink()
        path = self.root / 'backup/secrets/runtime.env'
        path.write_text('synthetic')
        path.chmod(0o600)
        with self.assertRaises(MODULE.Invalid):
            self.resolve()

    def test_paths_and_nested_missing_parents_refused(self):
        for relative in ('../identity.json', 'secrets/../x', 'secrets//x', 'secrets/.hidden', '/secrets/x', 'secrets/runtime.env'):
            with self.assertRaises(MODULE.Invalid):
                self.resolve(relative)
        self.prepare()
        with self.assertRaises(OSError):
            self.resolve('secrets/not-created/token.enc.env')

    def test_bad_identity_schema_recipients_and_duplicate_json_refused(self):
        self.value['schema_version'] = True
        self.write_plan()
        with self.assertRaises(MODULE.Invalid):
            self.prepare()
        self.value['schema_version'] = 1
        self.value['recipients']['ci'] = 'age1bad'
        self.write_plan()
        with self.assertRaises(MODULE.Invalid):
            self.prepare()
        with self.assertRaises(MODULE.Invalid):
            MODULE.json_object('{"node_id":"one","node_id":"two"}')
        with self.assertRaises(MODULE.Invalid):
            MODULE.json_object('[' * 3000 + '0' + ']' * 3000)

    def test_public_readonly_template_and_oversized_host_state(self):
        for mode in (0o644, 0o444, 0o600):
            self.template.chmod(mode)
            self.prepare(check=True)
        self.state.write_text(' ' * 65537)
        self.state.chmod(0o600)
        with self.assertRaises(MODULE.Invalid):
            self.prepare(check=True)
        self.state.unlink()
        self.machine.write_text('0' * 32 + '\n')
        self.value['machine_id'] = '0' * 32
        self.write_plan()
        with self.assertRaises(MODULE.Invalid):
            self.prepare(check=True)

    def test_policy_tampering_unknown_files_and_symlink_parents(self):
        self.prepare()
        policy = self.root / 'security/.sops.yaml'
        original = policy.read_text()
        policy.write_text(original.replace('secrets/', 'public/'))
        with self.assertRaises(MODULE.Invalid):
            self.resolve()
        policy.write_text(original)
        (self.root / 'age-key.txt').write_text('synthetic')
        with self.assertRaises(MODULE.Invalid):
            self.resolve()
        (self.root / 'age-key.txt').unlink()
        secrets = self.root / 'backup/secrets'
        secrets.rmdir()
        secrets.symlink_to(self.base)
        with self.assertRaises(MODULE.Invalid):
            self.resolve()

    def test_atomic_publication_collision_does_not_overwrite(self):
        original = MODULE.publish_no_replace
        with mock.patch.object(MODULE, 'publish_no_replace', side_effect=lambda a, b: (
                b.mkdir(mode=0o700), original(a, b))):
            with self.assertRaises(MODULE.Invalid):
                self.prepare()
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertFalse(list(self.base.glob('.node-config-*')))

    def test_missing_parent_is_not_created_in_check_or_apply(self):
        self.root = self.base / 'missing-parent/node-config'
        for check in (True, False):
            with self.assertRaises(OSError):
                self.prepare(check=check)
            self.assertFalse(self.root.parent.exists())
            self.assertFalse(list(self.base.glob('.node-config-*')))

    def test_cli_has_no_root_override_and_does_not_echo_invalid_input(self):
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/node-config.py'),
                                 'path', '--repo', 'security', '--relative', 'secrets',
                                 '--legacy', '/opt/legacy', '--root', 'synthetic-secret'],
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('synthetic-secret', result.stdout + result.stderr)

    def test_candidate_public_policy_cli_validates_bounded_input_safely(self):
        self.prepare()
        valid = (self.root / 'security/.sops.yaml').read_text()
        cases = [(valid, 0),
                 (valid.replace(self.value['recipients']['ci'], 'age1synthetic-secret'), 2),
                 (valid + '\nAGE-SECRET-KEY-SYNTHETICSECRET\n', 2),
                 (valid.replace(self.value['recipients']['ci'], self.value['recipients']['break_glass']), 2),
                 (valid + '\n# corp-infra-recipient: ci ' + self.value['recipients']['ci'], 2),
                 ('x' * 65537, 2)]
        for candidate, expected in cases:
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/node-config.py'),
                                     'policy', '--stdin'], input=candidate,
                                    capture_output=True, text=True, timeout=3)
            self.assertEqual(result.returncode, expected)
            self.assertNotIn('synthetic-secret', result.stdout + result.stderr)
            self.assertNotIn('SYNTHETICSECRET', result.stdout + result.stderr)
            if expected == 0:
                self.assertEqual(result.stdout, 'OK public policy\n')


if __name__ == '__main__':
    unittest.main()
