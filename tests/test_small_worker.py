"""Explicit measured small-worker contract without weakening catalog fallback."""
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import unittest

import jsonschema

ROOT = Path(__file__).resolve().parents[1]
SMALL = json.loads((ROOT / 'profiles/ordinary-worker-small-v1.json').read_text())
SCHEMA = json.loads((ROOT / 'schemas/profile.schema.json').read_text())


class SmallWorkerTest(unittest.TestCase):
    def test_supported_exact_budget_and_owner_policy(self):
        jsonschema.validate(SMALL, SCHEMA)
        for field, value in [('per_binding_memory_high_mb', 6144),
                             ('per_binding_memory_max_mb', 8192)]:
            changed = copy.deepcopy(SMALL)
            next(p for p in changed['platform'] if p['id'] == 'coding-runtime')['opts'][field] = value
            with self.assertRaises(jsonschema.ValidationError):
                jsonschema.validate(changed, SCHEMA)
        for key, value in [('permitrootlogin', 'yes'), ('passwordauthentication', 'yes'),
                           ('authenticationmethods', 'any'), ('pubkeyauthentication', 'no')]:
            changed = copy.deepcopy(SMALL)
            changed['platform'][0]['opts']['owner_access']['sshd'][key] = value
            with self.assertRaises(jsonschema.ValidationError):
                jsonschema.validate(changed, SCHEMA)

    def admission(self, profile, memory=11959, disk=98, cpu=8, recorded=''):
        body = (ROOT / 'scripts/recon.sh').read_text()
        functions = '\n'.join(re.search(r'^' + name + r'\(\) \{\n.*?^\}', body, re.M | re.S).group()
                              for name in ('derive_judgments', '_gate_json'))
        script = '''source "$LIB"
state_get() { [ -n "$RECORDED" ] && printf '%s' "$RECORDED"; }
RECON_BLOCKERS=(); RECON_WARNINGS=(); RECON_MEM_SHORT=0
OS_TIER=supported; OS_PRETTY=fixture; RECON_PROVIDER=generic
F_PROVIDER_HINT=''; F_SWAP_ENABLED=0; VIRT_DETECTED=0
''' + functions + '''
derive_judgments
printf '%s\\n' "$RECON_EXIT" "$J_VERDICT" "${RECON_BLOCKERS[@]}"
'''
        result = subprocess.run(['bash', '-c', script], env={**os.environ,
            'LIB': str(ROOT / 'lib/common.sh'), 'CI_PROFILE_DIR': str(ROOT / 'profiles'),
            'CI_PROVIDER_DIR': str(ROOT / 'providers'), 'CI_PROFILE': profile,
            'RECORDED': recorded, 'F_MEM_TOTAL': str(memory), 'F_DISK_ROOT_TOTAL': str(disk),
            'F_VCPU': str(cpu)}, text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.splitlines()

    def test_explicit_and_state_selected_fit_12_and_16_gib(self):
        for memory in (11959, 16384):
            self.assertEqual(self.admission('ordinary-worker-small-v1', memory)[:2], ['0', 'pass'])
        self.assertEqual(self.admission('', recorded='ordinary-worker-small-v1')[:2], ['0', 'pass'])

    def test_automatic_missing_and_shortfall_still_rejected(self):
        self.assertNotEqual(self.admission('')[0], '0')
        self.assertEqual(self.admission('missing')[1], 'inconclusive')
        self.assertNotEqual(self.admission('ordinary-worker-v1')[0], '0')
        for params in ({'memory': 8192}, {'cpu': 4}, {'disk': 80}):
            with self.subTest(params=params):
                self.assertNotEqual(self.admission('ordinary-worker-small-v1', **params)[0], '0')


if __name__ == '__main__':
    unittest.main()
