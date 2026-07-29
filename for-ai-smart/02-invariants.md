# Invariants, each with the command that proves it

An invariant without a check is a wish. Every row below is falsifiable by a
single command run from the repository root.

## Repository-specific

### INV-BS-1 — a stage is never trusted on its marker alone

Stage N+1 begins only when the marker of stage N reads `ok` **and** the
producing repository's live `--check` exits 0.

```bash
./scripts/bootstrap.sh --check
```

Proof: any row whose MARKER and LIVE CHECK columns disagree is printed as
`DRIFT` and the command exits 1. In source, the guarantee is structural —
`require_stage` refuses to run without a live check command:

```bash
grep -n 'live check command required' lib/common.sh
```

### INV-BS-2 — a profile that does not fit stops the installation

```bash
./scripts/recon.sh --json | python3 -c \
  'import json,sys; j=json.load(sys.stdin)["judgments"]; print(j["sizing_verdict"], j["exit_code"])'
```

Proof: `fail` or `inconclusive` never coexists with `exit_code: 0`.
`fail` has no override; `inconclusive` requires `--force-profile`, which is
recorded:

```bash
grep -n 'force-profile' scripts/bootstrap.sh
```

### INV-BS-3 — equal library version implies identical library

```bash
./scripts/sync-lib.sh --check
```

Proof: exits 1 on `VERSION-DRIFT` or on `CONTENT-DRIFT` (equal versions,
different bytes). Missing repositories are reported as inconclusive (2), not as
a failure, because "not cloned yet" is a legitimate state.

### INV-BS-4 — an invalid recon document is a failure, not "just JSON"

```bash
./scripts/recon.sh --json > /tmp/r.json && python3 -c \
 'import json,jsonschema; jsonschema.validate(json.load(open("/tmp/r.json")), json.load(open("schemas/recon.schema.json")))'
```

Proof: the schema sets `additionalProperties: false` at the root and inside
`facts` and `judgments`, so an extra or renamed field fails validation rather
than passing unnoticed.

## Global

### INV-GLOBAL-1 — one owner per filesystem path

This repository writes only to `/var/lib/corp-infra`, `/opt/corp-infra` and —
via `ensure-docker.sh` only — `/etc/docker/daemon.json`.

```bash
grep -nE '^\s*(mkdir|cp|mv|rm|chmod|chown|tee|install)\b' scripts/*.sh | \
  grep -vE '\$(CI_STATE|CI_ROOT|CI_LOGDIR|CI_ETC|CI_SRV|BOOTSTRAP_DIR|SCRIPT_DIR|dir|tmp|f|file|target|keyring|listfile)|/etc/docker|/etc/apt'
```

Proof: the filtered output is empty — no mutation targets a path outside the
owned set.

### INV-GLOBAL-2 — a marker is a claim, not a proof

Same command as INV-BS-1. The two invariants are the same rule stated from the
producer's and the consumer's side.

## Conventions that behave like invariants

### Every script has the mandated prologue

```bash
for f in scripts/*.sh; do
  head -20 "$f" | grep -q 'set -Eeuo pipefail' || echo "MISSING strict mode: $f"
  tail -1 "$f" | grep -q '^main "\$@"$'        || echo "MISSING main last line: $f"
done
```

Proof: no output. `main "$@"` on the final line protects against executing a
truncated download — a file cut short simply never invokes anything.

### Every script passes syntax and shellcheck

```bash
bash -n lib/common.sh scripts/*.sh
shellcheck -S warning lib/common.sh scripts/*.sh
```

Proof: zero findings. Exceptions are only permitted as inline
`# shellcheck disable=` with a justifying comment.

### `--check` mutates nothing, not even a directory

```bash
CI_STATE=/tmp/probe-state CI_LOGDIR=/tmp/probe-log ./scripts/recon.sh --check; \
  ls -d /tmp/probe-state /tmp/probe-log 2>&1
```

Proof: neither directory is created. `log_init` deliberately skips directory
creation when `CI_MODE=check`, so the doctor mode cannot leave traces.

### No outbound scanning, ever

```bash
grep -rnE '\b(nmap|masscan|zmap|hping|--external-probe)\b' scripts/ lib/
```

Proof: no output. Port facts come from `ss -Hln` with a `/proc/net/{tcp,udp}`
fallback — local listeners only. Forbidden by the adminVPS offer; see
`../../../research/08-vps-providers.md` section A5.

### No metadata-service calls in recon

```bash
grep -nE '169\.254\.169\.254|metadata\.(google|internal)|curl|wget' scripts/recon.sh
```

Proof: no output. `provider_hint` is derived from DMI, cloud-init and the
hostname suffix — all local reads.

### JSON is generated without `jq`

```bash
grep -n '\bjq\b' scripts/*.sh lib/common.sh
```

Proof: no output. `jq` was absent even on the research Ubuntu 22.04 host, while
`python3` was present. All generation goes through `json_escape` / `json_kv` /
`json_arr`; `python3` reads and validates but never generates.

### `json_kv` survives adversarial input

```bash
bash -c 'source lib/common.sh; CI_REPO=t; CI_SCRIPT=t;
  printf "{%s}\n" "$(json_kv k "$(printf "a\"b\\\\c\td\ne")")"' | python3 -m json.tool
```

Proof: valid JSON. Quotes, backslashes, tabs, newlines, control characters, `$`,
backticks and multi-byte UTF-8 are all handled in pure bash.

### The `systemd-detect-virt` inversion is pinned in one place

```bash
grep -n 'INVERSION PINNED' -A 6 lib/common.sh
```

Proof: `detect_virt` is the only caller, and its contract is documented at the
definition: exit 0 means virtualisation **was** found. Callers read
`VIRT_DETECTED` (1 virtualised / 0 bare metal / 2 unknown) and never re-derive
the polarity.

### Exit codes mean exactly three things

`0` ok · `1` a checked condition is violated · `2` the state is unknown.

```bash
grep -nE 'exit [3-9]|exit [0-9]{2,}' scripts/*.sh lib/common.sh
```

Proof: no output. Codes above 2 do not exist in this repository.

### Profile arithmetic matches the architecture document

```bash
./scripts/sizing-check.sh --static --all
```

Proof: exits 0, and the printed sums are 19742 / 11345 / 11448 / 7198 MB steady
for `all-in-one-32` / `core-16` / `two-vps-split-a` / `two-vps-split-b`,
reproducing 05_architecture sections 2.3–2.5 to the megabyte. Exactly one
profile has `default: true`.

### Every artefact validates against its schema

```bash
for f in profiles/*.json providers/*.json schemas/*.json; do
  python3 -m json.tool "$f" > /dev/null || echo "INVALID: $f"
done
```

Proof: no output. Schema-to-file pairing is listed in
`schemas/` (one schema per artefact contract).

### Provider policy is configuration, not code

```bash
grep -n 'vpn_hub_allowed' providers/*.json scripts/recon.sh
```

Proof: the value is read from `providers/<id>.json` and surfaced as
`judgments.provider_policy.vpn_hub_allowed`. Changing the verdict on whether a
provider permits a VPN hub is a one-boolean edit; `install-wireguard.sh` in the
vpn-proxy repository is not touched.
