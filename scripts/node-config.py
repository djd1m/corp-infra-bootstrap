#!/usr/bin/env python3
"""Resolve protected host config outside immutable source bundles.

Only prepare --yes writes. No private key, authentication or decrypted secret
is read or generated. Fail closed if an external layout exists but is invalid.
The /etc/corp-infra parent must already be a trusted root-owned directory with
no group/world write permission; prepare never creates that parent implicitly.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile

ROOT = Path('/etc/corp-infra/node-config')
MACHINE = Path('/etc/machine-id')
STATE = Path('/var/lib/corp-infra/state.json')
REPOS = ('bootstrap', 'security', 'vpn-proxy', 'backup', 'ent-infra', 'pop-agents')
PROFILES = ('ordinary-worker-v1', 'ordinary-worker-small-v1')
TEMPLATE_SHA256 = '5b271713bb564d70213b0eec321cbd91aaf10a602a70c1f89036c6649dac9698'
EXTERNAL_POLICY_SHA256 = '83f4677114c4a5700a9cc7db2e5013e5ff564f6cbfc68ec63d27144f7f3434a4'
IDENTITY_FIELDS = {'schema_version', 'node_id', 'machine_id', 'profile'}


class Invalid(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, 'INCONCLUSIVE: invalid node configuration arguments\n')


def ancestors(path, owner=0):
    """Every existing parent must be trusted, never a symlink or writable peer."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise Invalid()
    for item in reversed([path, *path.parents]):
        info = item.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, owner) or info.st_mode & 0o022:
            raise Invalid()


def protected(path, directory=False, owner=0):
    ancestors(path.parent, owner)
    info = path.lstat()
    expected = 0o700 if directory else 0o600
    if (info.st_uid != owner or stat.S_IMODE(info.st_mode) != expected
            or (not stat.S_ISDIR(info.st_mode) if directory else
                not stat.S_ISREG(info.st_mode) or info.st_nlink != 1)):
        raise Invalid()
    return info


def read_protected(path, owner=0, public=False):
    if not public:
        protected(path, owner=owner)
    else:
        ancestors(path.parent, owner)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != owner
                or stat.S_IMODE(info.st_mode) not in ((0o444, 0o644, 0o600) if public else (0o600,)) or info.st_nlink != 1
                or info.st_size > 65536):
            raise Invalid()
        with os.fdopen(descriptor, 'r', encoding='utf-8', closefd=False) as stream:
            return stream.read(65537)
    finally:
        os.close(descriptor)


def json_object(text):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise Invalid()
            result[key] = value
        return result
    try:
        result = json.loads(text, object_pairs_hook=pairs)
    except RecursionError:
        raise Invalid() from None
    if not isinstance(result, dict):
        raise Invalid()
    return result


def identity(value):
    if (set(value) != IDENTITY_FIELDS or type(value['schema_version']) is not int
            or value['schema_version'] != 1
            or not isinstance(value['node_id'], str)
            or not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', value['node_id'])
            or not isinstance(value['machine_id'], str)
            or not re.fullmatch(r'[0-9a-f]{32}', value['machine_id']) or value['machine_id'] == '0' * 32
            or value['profile'] not in PROFILES):
        raise Invalid()
    return value


def bind_host(value, machine=MACHINE, state=STATE, owner=0):
    ancestors(machine.parent, owner)
    info = machine.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != owner
            or info.st_mode & 0o022 or info.st_nlink != 1
            or info.st_size > 64 or machine.read_text().strip() != value['machine_id']):
        raise Invalid()
    if os.path.lexists(state):
        ancestors(state.parent, owner)
        info = state.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != owner
                or info.st_mode & 0o022 or info.st_nlink != 1 or info.st_size > 65536):
            raise Invalid()
        recorded = json_object(state.read_text())
        if recorded.get('profile') != value['profile']:
            raise Invalid()


def recipient(value):
    # Validate Bech32 alphabet and checksum, not a private key or a placeholder.
    if not isinstance(value, str) or not re.fullmatch(r'age1[023456789acdefghjklmnpqrstuvwxyz]{58}', value):
        raise Invalid()
    alphabet = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
    if alphabet.index(value[-7]) & 15:
        raise Invalid()
    values = [ord(c) >> 5 for c in 'age'] + [0] + [ord(c) & 31 for c in 'age']
    values += [alphabet.index(c) for c in value[4:]]
    check = 1
    for digit in values:
        top = check >> 25
        check = ((check & 0x1ffffff) << 5) ^ digit
        for index, generator in enumerate((0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)):
            if (top >> index) & 1:
                check ^= generator
    if check != 1:
        raise Invalid()
    return value


def policy_roles(text):
    if re.search(r'AGE-SECRET-KEY-[A-Z0-9]+', text):
        raise Invalid()
    roles = re.findall(r'^# corp-infra-recipient: (prod|ci|break-glass) (\S+)$', text, re.M)
    if len(roles) != 3 or {role for role, _ in roles} != {'prod', 'ci', 'break-glass'}:
        raise Invalid()
    result = dict(roles)
    if len(set(result.values())) != 3:
        raise Invalid()
    for role, value in result.items():
        if role == 'prod' and value == '<prod-recipient>':
            continue
        recipient(value)
    normalized = text
    for role, value in result.items():
        normalized = normalized.replace(value, '<' + role + '-recipient>')
    if hashlib.sha256(normalized.encode()).hexdigest() != EXTERNAL_POLICY_SHA256:
        raise Invalid()
    return result


def validate_layout(root=ROOT, machine=MACHINE, state=STATE, owner=0):
    protected(root, directory=True, owner=owner)
    if {path.name for path in root.iterdir()} != {'identity.json', *REPOS}:
        raise Invalid()
    value = identity(json_object(read_protected(root / 'identity.json', owner)))
    bind_host(value, machine, state, owner)
    for repo in REPOS:
        folder = root / repo
        protected(folder, directory=True, owner=owner)
        if {path.name for path in folder.iterdir()} != ({'secrets', '.sops.yaml'} if repo == 'security' else {'secrets'}):
            raise Invalid()
        secrets = folder / 'secrets'
        protected(secrets, directory=True, owner=owner)
        for base, directories, files in os.walk(secrets, followlinks=False):
            for name in directories:
                if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', name):
                    raise Invalid()
                protected(Path(base) / name, directory=True, owner=owner)
            for name in files:
                if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*\.enc\.(env|yaml|json|conf)', name):
                    raise Invalid()
                protected(Path(base) / name, owner=owner)
    policy_roles(read_protected(root / 'security/.sops.yaml', owner))
    return value


def resolve(repo, relative, legacy, root=ROOT, machine=MACHINE, state=STATE, owner=0):
    if (repo not in REPOS or not Path(legacy).is_absolute() or '..' in Path(legacy).parts
            or any(c in legacy for c in '\r\n\x00')):
        raise Invalid()
    parts = relative.split('/')
    if relative != '.sops.yaml' and (parts[0] != 'secrets'
            or any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', part) or part in ('.', '..') for part in parts[1:])):
        raise Invalid()
    if relative not in ('.sops.yaml', 'secrets') and not re.fullmatch(
            r'[A-Za-z0-9][A-Za-z0-9_.-]*\.enc\.(env|yaml|json|conf)', parts[-1]):
        raise Invalid()
    if not os.path.lexists(root):
        return str(legacy)
    validate_layout(root, machine, state, owner)
    path = root / ('security/.sops.yaml' if relative == '.sops.yaml' else repo + '/' + relative)
    # Missing ciphertext is a valid destination only with protected parents.
    protected(path.parent, directory=True, owner=owner)
    if os.path.lexists(path):
        protected(path, directory=relative == 'secrets', owner=owner)
    return str(path)


def publish_no_replace(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    rename = getattr(libc, 'renameat2', None)
    if rename is None or rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1) != 0:
        raise Invalid()


def prepare(plan, template, check, root=ROOT, machine=MACHINE, state=STATE, owner=0):
    value = json_object(read_protected(plan, owner))
    if set(value) != IDENTITY_FIELDS | {'recipients'}:
        raise Invalid()
    public = value.pop('recipients')
    identity(value)
    if not isinstance(public, dict) or set(public) != {'ci', 'break_glass'}:
        raise Invalid()
    ci = recipient(public['ci'])
    emergency = recipient(public['break_glass'])
    if ci == emergency:
        raise Invalid()
    bind_host(value, machine, state, owner)
    text = read_protected(template, owner, public=True)
    # Pin the reviewed public policy, including mandatory role comments/rules.
    if hashlib.sha256(text.encode()).hexdigest() != TEMPLATE_SHA256:
        raise Invalid()
    # The external contract includes encrypted WireGuard binary .conf files.
    # Extend only the two reviewed rules; never accept arbitrary policy input.
    if text.count('env|yaml|json') != 2:
        raise Invalid()
    text = text.replace('env|yaml|json', 'env|yaml|json|conf')
    seeded = text.replace('<ci-recipient>', ci).replace('<break-glass-recipient>', emergency)
    ancestors(root.parent, owner)
    if os.path.lexists(root):
        if validate_layout(root, machine, state, owner) != value:
            raise Invalid()
        roles = policy_roles(read_protected(root / 'security/.sops.yaml', owner))
        if roles['ci'] != ci or roles['break-glass'] != emergency:
            raise Invalid()
        return
    if check:
        return
    temporary = Path(tempfile.mkdtemp(prefix='.node-config-', dir=root.parent))
    try:
        os.chmod(temporary, 0o700)
        for repo in REPOS:
            (temporary / repo).mkdir(mode=0o700)
            (temporary / repo / 'secrets').mkdir(mode=0o700)
        for path, content in ((temporary / 'identity.json', json.dumps(value, sort_keys=True) + '\n'),
                              (temporary / 'security/.sops.yaml', seeded)):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
        validate_layout(temporary, machine, state, owner)
        # Flush the complete tree before publication, then the naming parent.
        for base, _, _ in os.walk(temporary, topdown=False):
            sync_directory(Path(base))
        publish_no_replace(temporary, root)
        sync_directory(root.parent)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main():
    parser = Parser(description=__doc__)
    actions = parser.add_subparsers(dest='action', required=True, parser_class=Parser)
    path = actions.add_parser('path')
    path.add_argument('--repo', required=True, choices=REPOS)
    path.add_argument('--relative', required=True)
    path.add_argument('--legacy', required=True)
    init = actions.add_parser('prepare')
    init.add_argument('--plan', required=True, type=Path)
    init.add_argument('--source-policy', required=True, type=Path)
    mode = init.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--yes', action='store_true')
    policy = actions.add_parser('policy')
    policy.add_argument('--stdin', action='store_true', required=True)
    args = parser.parse_args()
    try:
        if args.action == 'path':
            print(resolve(args.repo, args.relative, args.legacy))
        elif args.action == 'prepare':
            prepare(args.plan, args.source_policy, args.check)
        else:
            payload = sys.stdin.buffer.read(65537)
            if len(payload) > 65536:
                raise Invalid()
            policy_roles(payload.decode('utf-8'))
            print('OK public policy')
        return 0
    except (Invalid, OSError, ValueError, TypeError, UnicodeError):
        print('INCONCLUSIVE: protected node configuration invalid or unavailable', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
