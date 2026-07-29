# Goals and boundaries — corp-infra-bootstrap

You are reading the track for models that can plan several steps ahead, notice
when a command did something unexpected, and recover from it. You get goals,
invariants and the commands that prove them. Choosing the path is your job.

If that description does not fit, switch to
[`../for-ai-dumb/00-start-here.md`](../for-ai-dumb/00-start-here.md).

## Goal state

This repository has done its job when all of the following are true on the
target host:

| # | Goal | Proven by |
|---|---|---|
| G-a | The environment has been measured and the measurement is machine-readable | `scripts/recon.sh --json` emits a document valid against `schemas/recon.schema.json` |
| G-b | A deployment profile has been selected and it actually fits the host | `judgments.sizing_verdict == "pass"` in the recon document |
| G-c | Docker Engine is present and configured to corp-infra's target | `scripts/ensure-docker.sh --check` exits 0 |
| G-d | The five stages have been applied in the fixed order, each one proven twice | `scripts/bootstrap.sh --check` exits 0 with five `ok` verdicts |
| G-e | The canonical library is identical in all six repositories | `scripts/sync-lib.sh --check` exits 0 |
| G-f | The whole thing can report on itself | `scripts/doctor.sh` exits 0 |

## What this repository owns

Owns, and may write to:

- `/var/lib/corp-infra/**` — orchestration state, markers, manifests, recon
- `/opt/corp-infra/**` — repository checkouts and `versions.env`
- `/etc/docker/daemon.json` — via `ensure-docker.sh`, the single decision point

Never touches anything else. Installing Docker Engine is the one and only
exception to "stay inside your own two directories".

Specifically **not** owned here: sshd, ufw, WireGuard, Caddy, restic, any
service compose file. Those belong to the other five repositories. If a task
seems to require editing one of them from here, the task is wrong.

## Invariants

Four invariants are specific to this repository. The full list, each with the
exact command that proves it, is in
[`02-invariants.md`](02-invariants.md).

- **INV-BS-1** Stage N+1 does not begin until the marker of stage N says `ok`
  **and** the producing repository's live `--check` exits 0. A marker alone is
  never sufficient.
- **INV-BS-2** `sizing_verdict != pass` stops the installation.
  `inconclusive` may be overridden only by an explicit `--force-profile`, and
  the override is recorded in `state.json`.
- **INV-BS-3** Equal `lib/VERSION` across the six repositories implies
  byte-identical `lib/common.sh`.
- **INV-BS-4** An invalid recon document is a failure, not "just JSON".

Two global invariants also bind everything here:

- **INV-GLOBAL-1** Every filesystem path has exactly one owning context.
  Foreign scripts may read a path for `--check`, never mutate it.
- **INV-GLOBAL-2** A marker is a claim, not a proof.

## Boundaries — things that are never acceptable

| Never | Why |
|---|---|
| Run an outbound port scan, or probe a host you do not own | The adminVPS offer forbids it outright (`../../../research/08-vps-providers.md` section A5). Port facts come from local listeners only. |
| Query a cloud metadata service to identify the provider | `provider_hint` is a local heuristic over DMI, cloud-init and the hostname. A network call here would make recon non-hermetic. |
| Mutate anything in `--check` mode, including creating a directory | `--check` is the doctor mode the whole repo set relies on. If it can change state, it is not a doctor. |
| Edit a vendored `lib/common.sh` | Gate G-09 catches it. Change the canonical copy, bump `lib/VERSION`, run `sync-lib.sh`. |
| Use `jq` to generate JSON | `jq` is absent on stock Ubuntu. All JSON is generated with `json_escape` / `json_kv` / `json_arr`. `jq` is an optional pretty-printer, never a dependency. |
| Use `exit 1` to mean "I could not check" | That is `exit 2`. Conflating them turns "unknown" into "broken" and hides real failures. |
| Delete a marker to get past a failing check | The double-signal rule exists precisely for that situation. Fix reality instead. |
| Commit a secret in cleartext | Everything sensitive is sops-encrypted; runtime `.env` files are generated at 0600 and git-ignored. |

## Tools available to you

| Script | Purpose | Mutates? |
|---|---|---|
| `scripts/recon.sh` | Measure the environment, emit versioned JSON | Only its own output files; never in `--check` or `--json` |
| `scripts/sizing-check.sh` | Gates G1–G4, static or against recon facts | Never |
| `scripts/bootstrap.sh` | Five-stage state machine, the single entry point | Yes, in apply mode |
| `scripts/ensure-docker.sh` | Install and configure Docker Engine | Yes, in apply mode |
| `scripts/state.sh` | Read `state.json` and the markers | Only `state.sh set` |
| `scripts/sync-lib.sh` | Distribute the canonical library | Only with `--yes` |
| `scripts/doctor.sh` | Run every check, aggregate | Never |

Every one of them accepts `--check`, `--yes`, `--profile`, `--quiet`, `--help`,
`--version`, and returns 0 / 1 / 2 with the meanings above. `--check` and
`--yes` together is an error (exit 2), because "verify without changing
anything" and "change everything without asking" cannot both be true.

## The library

`lib/common.sh` is the canonical copy of a 35-function shell library. Read
[`01-orchestration.md`](01-orchestration.md) for the state machine semantics.
Three functions are worth knowing before you touch anything:

- `require_stage <stage> <live-check-cmd...>` — the only correct way to depend
  on a previous stage. It refuses to run without the live check command.
- `headroom_check <svc_id>` — gate G5. Refuses to add a service to a host whose
  `MemAvailable` is below that service's steady budget plus 512 MB.
- `detect_virt` — wraps `systemd-detect-virt`, whose exit code is inverted:
  **0 means virtualisation WAS found**. The wrapper pins that semantic so no
  caller has to remember it.

## Success criteria, as commands

```bash
bash -n scripts/*.sh lib/common.sh
./scripts/recon.sh --json | python3 -m json.tool
./scripts/sizing-check.sh --static --all
./scripts/bootstrap.sh --check
./scripts/doctor.sh
```

All five must exit 0 on a correctly installed host. On a clean host the last two
still exit 0, reporting five `pending` stages — that is the defined clean state,
not a failure.

## When to stop and ask

Stop and report to a human when: a command's output contradicts this
documentation; a referenced file does not exist; a check returns 2 and you
cannot determine why; or an action would fall outside the ownership boundary
above. Guessing on infrastructure damages a production host.
