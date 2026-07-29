# Orchestration semantics

## The state machine

Five stages, fixed order, not configurable:

```
security → vpn-proxy → backup → ent-infra → pop-agents
```

The ordering encodes three decisions worth understanding rather than
memorising:

- **security is first** because everything after it is installed onto an
  already-hardened host, not hardened afterwards.
- **backup is third, before any data exists.** A service enters the backup set
  at the moment it is installed. Installing backup last means the set contains
  what someone remembered, not what is needed.
- **pop-agents is last** because the AI operator operates a finished
  infrastructure; there is nothing to operate earlier.

`scripts/bootstrap.sh` is the only implementation of this machine. The stage
tables — which repository, which entry scripts, which marker, which live check —
live in one place in that file and nowhere else.

## The transition rule

This is the single most important contract in the repository set.

```
stage N+1 may start  ⟺  marker(stage N).status == "ok"
                        AND  live --check of repo N exits 0
```

Implemented as `require_stage <stage> <live-check-cmd...>` in `lib/common.sh`.
The function refuses to run when no live check command is supplied — the unsafe
call is not expressible.

Why both signals: a marker records that a stage ran at some past moment. It says
nothing about the present. Between then and now a person edited `sshd_config` by
hand, a container died, someone disabled ufw "for five minutes" three weeks ago.
Reality drifts away from markers, which is exactly why markers alone were
rejected as an idempotency mechanism.

The opposite extreme — checking reality only, no markers — loses the ordering
information the orchestrator needs. The resolution is to require both, and to
report disagreement loudly as `DRIFT` rather than picking a winner.

Consequence you must internalise: **never delete a marker to get past a failing
check.** The disagreement is the signal. Fix reality.

## Stage entry points

Fixed. `bootstrap.sh` calls them with `--yes --profile <name>`:

| Stage | Repository | Entry scripts | Marker used for the transition |
|---|---|---|---|
| security | `corp-infra-security` | `harden.sh` | `security.hardened` |
| vpn-proxy | `corp-infra-vpn-proxy` | `install-wireguard.sh`, then `install-proxy.sh` | `proxy.ready` |
| backup | `corp-infra-backup` | `install-backup.sh` | `backup.ready` |
| ent-infra | `corp-infra-ent-infra` | `install-<svc>.sh` per service in the profile | `ent-infra.observability.installed` |
| pop-agents | `corp-infra-pop-agents` | `install-agent.sh` | `agents.ready` |

`ent-infra` is profile-driven: the service list comes from `services[]` in the
selected profile. Each `install-<svc>.sh` is itself profile-aware and exits 0
with an explanatory message when its service is not part of the profile — so
calling all of them is safe, and the profile stays the single source of truth.

## STOP gates

Three points where the machine stops and requires a human. They are not
advisory.

| After | Gate | Why a machine cannot close it |
|---|---|---|
| `security` | Move the private age key into escrow, then `age-escrow.sh --attest <fingerprint>` | The attestation requires retyping the fingerprint *from the escrow copy*. That is what proves the copy exists and is readable, rather than documented. A machine typing a value it already has proves nothing. |
| `vpn-proxy` | Operator switches onto the VPN | The next stages narrow SSH to the VPN subnet. Confirming the new path works is a judgement about the operator's own connectivity. |
| End of run | `test-restore.sh --scenario vps-loss` | The installation is not complete until a restore is proven. The measured duration is appended to `drills.jsonl`, which either confirms or refutes the claimed 4-hour RTO. |

The escrow gate additionally hard-blocks stage 3: `install-backup.sh` requires
the `secrets.escrow.ok` marker. The reasoning is circular-dependency avoidance —
the restic password lives in a sops-encrypted file decrypted by the age key, so
a backup whose key is unrecoverable is not a backup.

## Profile resolution and INV-BS-2

```
--profile <name>  →  state.json.profile  →  judgments.profile_recommended
```

First non-empty wins. Then the sizing verdict decides:

| Verdict | Behaviour |
|---|---|
| `pass` | proceed |
| `fail` | `exit 2`. No override flag exists. The host is smaller than the profile — a measurement, not an opinion. |
| `inconclusive` | `exit 2` unless `--force-profile` is given; with it, proceed and record `profile_forced: true` in `state.json` |

Note the asymmetry: "does not fit" cannot be forced, "could not determine"
can — with the decision attributed to a human in the state file.

`--profile` means different things by design: for `bootstrap.sh` it **selects**
the profile; for every other script in every repository it **asserts** it. An
asserting script whose `state.json` records a different profile exits 2 rather
than silently switching. The profile is chosen once.

## Resuming after a failure

Three ways in, pick by situation:

- `--stage <name>` — run exactly one stage. Predecessors are still verified
  through `require_stage`.
- `--from <name>` — resume from this stage to the end.
- no flag — the full run; already-satisfied stages are cheap because every
  script is idempotent.

Idempotency here is built on **reality checks**, not markers: before each
mutation a script asks whether it has already been done (`command -v`,
`systemctl is-active`, `docker inspect`, `grep -q`). Re-running against a
configured host is therefore safe by construction.

When a stage fails, `state.json.stages.<stage>` becomes `failed` and the run
aborts rather than continuing into a broken dependency chain.

## Recon freshness

`/var/lib/corp-infra/recon/latest.json` is considered good for 24 hours. `bootstrap.sh` re-runs
recon itself when the document is older or absent. The history directory keeps
every previous document, which is what makes "the disk was at 40 % a month ago"
an answerable question during an incident.

## Where the numbers come from

Nothing in this repository invents a resource number. The chain is:

```
05_architecture section 1   base component budgets (steady, cap, disk)
  → sections 2.3-2.5        per-profile arithmetic
    → profiles/*.json       machine-readable form
      → sizing-check.sh     recomputes G1-G4 and fails on divergence
      → recon.sh            recomputes them against measured facts
      → compose mem_limit and systemd MemoryMax, generated from the profile
```

A divergence between the document and the JSON is caught in CI by the static
gate. Do not hand-edit a limit in a compose file; change the profile.

## Reading the state yourself

- `scripts/state.sh show` — fast, file-only view of stages and markers
- `scripts/bootstrap.sh --check` — the full view, including live checks
- `scripts/state.sh markers` — every marker with its status and timestamp
- `scripts/doctor.sh` — everything, aggregated

Aggregation rule in `doctor.sh`: a fail outranks an inconclusive. Result is 1 if
anything failed, else 2 if anything was inconclusive, else 0.
