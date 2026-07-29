# Choose the profile

Nothing in this file changes the host.

Before you start, confirm the previous file's gate: step 4 of
[`01-recon.md`](01-recon.md) must have printed `READY`. If it printed
`NOT_READY`, you must not be here.

Run this to re-confirm:

```bash
python3 -c "
import json
j=json.load(open('/tmp/recon.json'))['judgments']
print('READY' if j['sizing_verdict']=='pass' and not j['blockers'] else 'NOT_READY')"
```

Expected: `READY`

If it prints `NOT_READY`:

```
STOP
```

Report: "arrived at 02-choose-profile.md but recon says NOT_READY".

## Step 1 — read the recommended profile

Run:

```bash
python3 -c "
import json
j=json.load(open('/tmp/recon.json'))
print('recommended:', j['judgments']['profile_recommended'])
print('ram_mb     :', j['facts']['memory']['mem_total_mb'])
print('disk_gb    :', j['facts']['disk_root']['total_gb'])"
```

**Expected output** (numbers will differ)

```
recommended: core-16
ram_mb     : 16384
disk_gb    : 350
```

**Verification**

```bash
python3 -c "
import json
n=json.load(open('/tmp/recon.json'))['judgments']['profile_recommended']
import os
print('PROFILE_EXISTS' if os.path.exists('/opt/corp-infra/bootstrap/profiles/%s.json'%n) else 'PROFILE_MISSING')"
```

Expected: `PROFILE_EXISTS`

If you see `PROFILE_MISSING`:

```
STOP
```

Report: "recon recommended a profile that has no file in profiles/".

## Step 2 — check the decision table

Find the row that matches the `ram_mb` and `disk_gb` you printed in step 1.

| ram_mb | disk_gb | Profile |
|---|---|---|
| 32768 or more | 500 or more | `all-in-one-32` |
| 16384 to 32767 | 350 or more | `core-16` |
| 12288 to 16383 | 200 or more | `two-vps-split-b` |
| less than 12288 | any | none — see step 5 |
| any | below the value in the matching row | none — see step 5 |

The table must agree with the `recommended:` value from step 1. If it does not:

```
STOP
```

Report: "decision table and recon disagree", with both values.

## Step 3 — run the sizing gates for that profile

Replace `core-16` below with the profile name from step 1, and change nothing
else.

```bash
cd /opt/corp-infra/bootstrap && ./scripts/sizing-check.sh --static --profile core-16; echo "EXIT=$?"
```

**Expected output**

```
Profile: core-16   (RAM 16384 MB, disk 350 GB, source: profile minimums)

  GATE                                       REQUIRED       ACTUAL    RATIO  VERDICT
  ---------------------------------------------------------------------------------
  G1 sum(steady) <= 0.75 x RAM               12288 MB     11345 MB    0.692  PASS
  G2 sum(cap) <= 1.10 x RAM                  18022 MB     16793 MB    1.024  PASS
  G3 overcommit declares a policy        contention_policy    slices-v1    1.024  PASS
  G4 disk_total >= 1.15 x sum(disk)            336 GB       350 GB    1.041  PASS

  Result: PASS
EXIT=0
```

Log lines beginning with a timestamp may also appear. That is normal.

Every gate must read `PASS` and the exit code must be 0.

**Verification**

```bash
cd /opt/corp-infra/bootstrap && ./scripts/sizing-check.sh --static --profile core-16 --quiet; echo "EXIT=$?"
```

Expected output:

```
OK: sizing-check.sh
EXIT=0
```

If any gate reads `FAIL`, or the exit code is not 0:

```
STOP
```

Report: which gate failed, and the REQUIRED and ACTUAL numbers from its row.

## Step 4 — record the profile name

Write the profile name down. You will pass it to every command in
[`03-run-stages.md`](03-run-stages.md) as `--profile <name>`.

**Verification**

```bash
cd /opt/corp-infra/bootstrap && ls profiles/core-16.json && echo PROFILE_CONFIRMED
```

Expected output:

```
profiles/core-16.json
PROFILE_CONFIRMED
```

Now go to [`03-run-stages.md`](03-run-stages.md).

## Step 5 — when no profile fits

If the decision table gave you "none", the host is smaller than the smallest
supported configuration.

```
STOP
```

Report to a human, and include the `ram_mb` and `disk_gb` values from step 1.

Do not pick the closest profile and hope. Do not pass `--force-profile`. The
smallest supported configuration needs 12288 MB of RAM and 200 GB of disk, and
below that the installation does not fit — this is a measurement, not a
preference.

There is no `minimal-8` profile. Do not look for one. A human decides what to do
for an 8 GB machine, and the answer involves different software, not a different
flag.

## Ask, do not guess

If an expected output did not match, if the decision table and recon disagree,
or if a gate failed: stop, report what you ran, what you got, and what you
expected. Do not try another profile to see whether it passes.
