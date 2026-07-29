# Run the five stages

**This file changes the host.** Everything before it was read-only. From here
on, commands install software and modify system configuration.

Throughout this file, `core-16` stands for the profile name you recorded in
step 4 of [`02-choose-profile.md`](02-choose-profile.md). Substitute your name
and change nothing else.

## Step 0 — re-check the gate from the previous file

Do not skip this. It re-proves the previous file's conclusion, because a lot
depends on it being true right now.

```bash
cd /opt/corp-infra/bootstrap && ./scripts/sizing-check.sh --static --profile core-16 --quiet; echo "EXIT=$?"
```

**Expected output**

```
OK: sizing-check.sh
EXIT=0
```

**Verification**

```bash
test "$(id -u)" = 0 && echo AM_ROOT
```

Expected: `AM_ROOT`

If you are not root, or the sizing check did not print `OK`:

```
STOP
```

Report: "cannot start stages: not root, or sizing-check no longer passes".

## Step 1 — print the stage map before changing anything

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/bootstrap.sh --check; echo "EXIT=$?"
```

**Expected output on a host where nothing is installed yet**

```
corp-infra bootstrap - stage map
  root      : /opt/corp-infra
  state     : /var/lib/corp-infra
  host id   : sha256:e8b1267d942c...
  lib       : 1.0.0

  STAGE        MARKER     LIVE CHECK   VERDICT
  -------------------------------------------------------------------
  security     absent     n/a          pending
  vpn-proxy    absent     n/a          pending
  backup       absent     n/a          pending
  ent-infra    absent     n/a          pending
  pop-agents   absent     n/a          pending

EXIT=0
```

`n/a` in the LIVE CHECK column means the repository has not been cloned yet.
That is correct on a fresh host.

**Verification**

```bash
cd /opt/corp-infra/bootstrap && ./scripts/bootstrap.sh --check --quiet; echo "EXIT=$?"
```

Expected output:

```
OK: bootstrap.sh
EXIT=0
```

If any row reads `DRIFT` or `FAILED`, or the exit code is 1:

```
STOP
```

Report: the full stage map table exactly as printed.

## Step 2 — start the run

This command runs the stages and will pause at the first STOP gate on its own.

```bash
cd /opt/corp-infra/bootstrap && ./scripts/bootstrap.sh --profile core-16
```

The run will stop by itself and print a block that begins:

```
  ==================================================================
  STOP: move the private age key into escrow
  ==================================================================
```

**Expected output before that block**

```
2026-07-29T10:11:12Z INFO corp-infra-bootstrap/bootstrap.sh: === stage security ===
```

followed by log lines from `harden.sh`, then the private age key printed once.

**Verification**

```bash
sudo /opt/corp-infra/security/scripts/harden.sh --check; echo "EXIT=$?"
```

Expected: `EXIT=0`

If the exit code is 1 or 2, the security stage did not complete.

```
STOP
```

Report: the last 20 lines of `/var/log/corp-infra/corp-infra-security/harden.sh.log`.

## Step 3 — STOP gate 1: the age key

```
STOP
```

**A human must do this. You cannot.**

The private age key was printed once and was deliberately not written to any
log. A human must place it in at least two independent locations and then run
the attestation command, which requires retyping the key's fingerprint from the
escrow copy.

Report to the human:

- that the security stage completed and printed the key;
- that they must store it and then run:
  `sudo /opt/corp-infra/security/scripts/age-escrow.sh --attest <fingerprint>`

Do not run that command yourself. Retyping a value you already have on screen
proves nothing — the whole point of the gate is that a second, independent copy
exists and can be read.

Do not continue until the human confirms. When they do, verify:

```bash
sudo /opt/corp-infra/security/scripts/age-escrow.sh --check; echo "EXIT=$?"
```

Expected output:

```
EXIT=0
```

If it is not 0, the escrow is not in place and the backup stage will refuse to
run.

```
STOP
```

Report: "escrow check returned <code>; the backup stage cannot start".

## Step 4 — continue from the vpn-proxy stage

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/bootstrap.sh --from vpn-proxy --profile core-16
```

The run will stop by itself at the second gate:

```
  ==================================================================
  STOP: switch your session onto the VPN
  ==================================================================
```

**Expected output before that block**

```
2026-07-29T10:20:00Z INFO corp-infra-bootstrap/bootstrap.sh: === stage vpn-proxy ===
```

followed by log lines from `install-wireguard.sh` and `install-proxy.sh`, and a
peer configuration for the operator.

**Verification**

```bash
sudo /opt/corp-infra/vpn-proxy/scripts/install-proxy.sh --check; echo "EXIT=$?"
```

Expected: `EXIT=0`

## Step 5 — STOP gate 2: the VPN switch

```
STOP
```

**A human must do this. You cannot.**

The next stages narrow SSH access down to the VPN subnet. A human must import
the peer configuration on their own device, bring the tunnel up, and confirm
they can reach `10.8.0.1` — **while keeping the current SSH session open**.

Report to the human:

- that the VPN stage completed and a peer configuration was printed;
- that they must connect and confirm before you continue;
- that closing the existing session before confirming risks locking everyone
  out of the server.

Do not continue until the human confirms.

## Step 6 — run the remaining stages

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/bootstrap.sh --from backup --profile core-16
```

This runs `backup`, then `ent-infra`, then `pop-agents`.

**Expected output**

```
2026-07-29T10:40:00Z INFO corp-infra-bootstrap/bootstrap.sh: === stage backup ===
2026-07-29T10:52:00Z INFO corp-infra-bootstrap/bootstrap.sh: stage 'backup' complete
2026-07-29T10:52:01Z INFO corp-infra-bootstrap/bootstrap.sh: === stage ent-infra ===
2026-07-29T11:34:00Z INFO corp-infra-bootstrap/bootstrap.sh: stage 'ent-infra' complete
2026-07-29T11:34:01Z INFO corp-infra-bootstrap/bootstrap.sh: === stage pop-agents ===
2026-07-29T11:38:00Z INFO corp-infra-bootstrap/bootstrap.sh: stage 'pop-agents' complete
```

The timestamps will differ. The `ent-infra` stage takes the longest because
GitLab is large.

**Verification**

```bash
cd /opt/corp-infra/bootstrap && ./scripts/state.sh get stages.pop-agents
```

Expected output:

```
ok
```

If the run stopped with `stage '<name>' failed`:

```
STOP
```

Report: the stage name, the exit code, and the last 20 lines of
`/var/log/corp-infra/corp-infra-<name>/<script>.log`.

## Step 7 — STOP gate 3: the restore drill

```
STOP
```

**A human must authorise this.**

The installation is not complete until a restore has been proven rather than
assumed. Report to the human that they must run:

```
sudo /opt/corp-infra/backup/scripts/test-restore.sh --scenario vps-loss
```

This is a destructive-class operation and needs a human decision, even though
it restores into a temporary directory.

Do not run it yourself. When the human confirms it has been done, verify:

```bash
test -s /var/lib/corp-infra/backup/drills.jsonl && echo DRILL_RECORDED
```

Expected output:

```
DRILL_RECORDED
```

Then go to [`04-verify.md`](04-verify.md).

## Ask, do not guess

If a stage fails, do not re-run it with different flags to see what happens. Do
not delete a marker file to get past a check — a failing check with a present
marker is exactly the situation the design is meant to surface. Report what you
ran, what you got, and what you expected.
