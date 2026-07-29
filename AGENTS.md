# AGENTS.md — corp-infra-bootstrap

Canonical AI entry point for this repository. `CLAUDE.md` imports this file; do
not maintain two sets of instructions.

## What this repository is

The umbrella of a six-repository set that turns a bare VPS into a corporate
infrastructure. This repository owns **orchestration**: environment recon, the
canonical shell library, deployment profiles, the provider catalog, and the
five-stage state machine.

The other five repositories are applied in a fixed order and each one is a
separate bounded context:

```
security → vpn-proxy → backup → ent-infra → pop-agents
```

Backup comes before any data exists. That ordering is deliberate and is not
negotiable.

## Repo map

| Path | What lives here |
|---|---|
| `lib/common.sh` | The canonical shell library. 35 public functions. Vendored byte-identical into the other five repos. |
| `lib/VERSION` | SemVer of the library. Equal across all six repos or gate G-09 fails. |
| `scripts/recon.sh` | The only source of environment facts. Emits versioned JSON. |
| `scripts/sizing-check.sh` | Gates G1–G4, static (profiles only) or against recon facts. |
| `scripts/bootstrap.sh` | The single entry point. Five-stage state machine. |
| `scripts/ensure-docker.sh` | The only decision about installing Docker Engine. |
| `scripts/state.sh` | Read-only view of `state.json` and the markers. |
| `scripts/sync-lib.sh` | Distributes the canonical library. |
| `scripts/doctor.sh` | Runs every `--check` and aggregates the result. |
| `profiles/*.json` | Four deployment profiles with their RAM and disk budgets. |
| `providers/*.json` | VPS provider policy as configuration, never as code. |
| `schemas/*.json` | JSON Schema Draft 2020-12 contracts for every artefact. |

## Track selection

Pick one and stay in it:

- You can plan several steps ahead, notice when a command did something
  unexpected, and recover from it → **`for-ai-smart/`**. It gives goals,
  invariants and the commands that prove them, and lets you choose the path.
- You cannot reliably do that → **`for-ai-dumb/`**. It gives numbered steps,
  exact commands, expected output blocks, a verification command after every
  block, and STOP gates. Do not modify the commands.

Humans read `for-humans/` (Russian).

## Hard invariants

1. **Never commit a secret.** Anything sensitive lives in sops-encrypted
   `*.enc.env` / `*.enc.yaml`. Runtime `.env` files are generated on the host at
   mode 0600 and are git-ignored.
2. **Always `--check` before a mutation.** Every script supports it, and
   `--check` is guaranteed to mutate nothing at all — not even a directory.
3. **Never edit a vendored `lib/common.sh`.** The canonical copy is
   `lib/common.sh` in this repository. Need a new function? That is a change here
   plus a `lib/VERSION` bump plus `scripts/sync-lib.sh --yes`. Editing a
   vendored copy is caught by gate G-09.
4. **Never run an outbound port scan.** No `nmap`, no `masscan`, no probing of a
   host you do not own. Port facts come from local listeners only (`ss -Hln`).
   The adminVPS offer forbids scanning outright; see
   `../../research/08-vps-providers.md` section A5.
5. **A marker is a claim, not a proof.** Never accept
   `/var/lib/corp-infra/markers/<stage>.json` on its own. Use `require_stage`,
   which additionally runs the producing repository's live `--check`
   (INV-BS-1, INV-GLOBAL-2).
6. **`recon.sh` never mutates and never touches the network.** It measures.
7. **Exit codes mean exactly three things**: `0` ok, `1` a checked condition is
   violated, `2` the state could not be determined. Never use `exit 1` for "I
   could not check", and never `exit 0` on a check you skipped.
8. **Facts and judgments stay separate.** Nothing under `facts` contains the
   words ok / fail / recommended; nothing under `judgments` is recomputed by a
   consumer.

## Ask, do not guess

If a command's output does not match what the documentation says to expect, or
a file the documentation references does not exist, **stop and report it**. Do
not improvise a flag, do not substitute a similar command, do not skip the step.
A wrong guess on this repository set damages a production host.

## Proving it works

```bash
bash -n scripts/*.sh lib/common.sh          # syntax
./scripts/recon.sh --json | python3 -m json.tool   # facts, zero writes
./scripts/sizing-check.sh --static --all    # gates G1-G4 over every profile
./scripts/bootstrap.sh --check              # stage map
./scripts/doctor.sh                         # all of the above, aggregated
```
