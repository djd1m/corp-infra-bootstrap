# Verify the installation

Nothing in this file changes the host. Every command here is read-only.

Before you start, re-confirm the previous file's last gate:

```bash
test -s /var/lib/corp-infra/backup/drills.jsonl && echo DRILL_RECORDED
```

**Expected output**

```
DRILL_RECORDED
```

If the file is missing or empty, the restore drill from step 7 of
[`03-run-stages.md`](03-run-stages.md) was not completed.

```
STOP
```

Report: "arrived at 04-verify.md but no restore drill is recorded".

## Step 1 — the stage map

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/bootstrap.sh --check; echo "EXIT=$?"
```

**Expected output**

```
  STAGE        MARKER     LIVE CHECK   VERDICT
  -------------------------------------------------------------------
  security     ok         ok           ok
  vpn-proxy    ok         ok           ok
  backup       ok         ok           ok
  ent-infra    ok         ok           ok
  pop-agents   ok         ok           ok

EXIT=0
```

Every row must read `ok` in all three columns.

**Verification**

```bash
cd /opt/corp-infra/bootstrap && ./scripts/bootstrap.sh --check --quiet; echo "EXIT=$?"
```

Expected output:

```
OK: bootstrap.sh
EXIT=0
```

If any row reads `DRIFT`:

```
STOP
```

Report the full table. `DRIFT` means the marker and reality disagree. Do not
delete the marker. Do not re-run the stage to "refresh" it. A human decides.

## Step 2 — the aggregate check

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/doctor.sh; echo "EXIT=$?"
```

**Expected output**

```
  CHECK            VERDICT
  -------------------------------------
  recon            OK
  sizing-check     OK
  sync-lib         OK
  bootstrap        OK

EXIT=0
```

**Verification**

```bash
cd /opt/corp-infra/bootstrap && ./scripts/doctor.sh --quiet; echo "EXIT=$?"
```

Expected output:

```
OK: doctor.sh
EXIT=0
```

If any row is `FAIL` or `INCONCLUSIVE`:

```
STOP
```

Report which row, and the exit code.

## Step 3 — the recorded state

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/state.sh show
```

**Expected output**

```
corp-infra state
  state file : /var/lib/corp-infra/state.json
  host id    : sha256:e8b1267d942c...
  profile    : core-16 (node_role single)
  stage      : done
  lib version: 1.0.0

  STAGE          STATE      MARKER
  ---------------------------------------------
  security       ok         ok (security.hardened)
  vpn-proxy      ok         ok (vpn.ready)
  backup         ok         ok (backup.ready)
  ent-infra      ok         ok (ent-infra.gitlab.installed)
  pop-agents     ok         ok (agents.ready)
```

`stage : done` is what you want.

**Verification**

```bash
cd /opt/corp-infra/bootstrap && ./scripts/state.sh get current_stage
```

Expected output:

```
done
```

If it prints anything else, the run did not reach the end.

```
STOP
```

Report: "state.json current_stage is <value>, expected done".

## Step 4 — the library is identical everywhere

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/sync-lib.sh --check; echo "EXIT=$?"
```

**Expected output**

```
  REPO           VERSION    CONTENT      PATH
  -----------------------------------------------------------------------
  bootstrap      1.0.0      canonical    /opt/corp-infra/bootstrap/lib/common.sh
  security       1.0.0      identical    /opt/corp-infra/security/lib/common.sh
  vpn-proxy      1.0.0      identical    /opt/corp-infra/vpn-proxy/lib/common.sh
  backup         1.0.0      identical    /opt/corp-infra/backup/lib/common.sh
  ent-infra      1.0.0      identical    /opt/corp-infra/ent-infra/lib/common.sh
  pop-agents     1.0.0      identical    /opt/corp-infra/pop-agents/lib/common.sh

EXIT=0
```

Every row must read `identical` except the first, which reads `canonical`.

**Verification**

```bash
cd /opt/corp-infra/bootstrap && ./scripts/sync-lib.sh --check --quiet; echo "EXIT=$?"
```

Expected output:

```
OK: sync-lib.sh
EXIT=0
```

If any row reads `CONTENT-DRIFT`, somebody edited a vendored copy of the
library. That is forbidden.

```
STOP
```

Report: which repository drifted.

## Step 5 — recon is fresh and still valid

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/recon.sh --check; echo "EXIT=$?"
```

**Expected output**

```
2026-07-29T12:00:00Z INFO corp-infra-bootstrap/recon.sh: recon --check: schema valid
2026-07-29T12:00:00Z INFO corp-infra-bootstrap/recon.sh: recon --check: age 42m, within the 24h limit
2026-07-29T12:00:00Z INFO corp-infra-bootstrap/recon.sh: recon --check: OK
EXIT=0
```

**Verification**

```bash
python3 -c "
import json
d=json.load(open('/var/lib/corp-infra/recon/latest.json'))
print('SCHEMA_OK' if d['schema_version']==1 else 'SCHEMA_BAD')"
```

Expected output:

```
SCHEMA_OK
```

An exit code of 2 here usually means the recon document is older than 24 hours.
That is not a failure of the installation, but a human should be told.

```
STOP
```

Report: the exit code and the age line from the output.

## Step 6 — final report

If every step above matched, the installation is verified. Report to the human:

- all five stages read `ok` in all three columns;
- `doctor.sh` exited 0 with four `OK` rows;
- `state.json` records `current_stage: done` and the profile name;
- the library is identical across all six repositories;
- a restore drill is recorded in `/var/lib/corp-infra/backup/drills.jsonl`.

If any step did not match, you have already stopped at it. Do not continue past
a mismatch to produce a report that says everything is fine.

## Ask, do not guess

Report what you ran, what you got, and what you expected. Do not re-run a
failing check with different flags hoping for a different answer, and do not
delete state to make a check pass.
