# Start here

You are reading the track for models that need exact commands. Follow it
literally.

## Hard rules — read these before any command

1. **Do not modify the commands.** Copy them exactly as written, character for
   character. Do not add flags. Do not remove flags. Do not substitute a similar
   command you know.
2. **Run the verification command after every step.** It is there because the
   step before it can fail silently.
3. **Compare the real output to the `Expected output` block.** If they do not
   match, go to the STOP rule below.
4. **Never skip a step**, even if you believe it was already done. The scripts
   are safe to re-run.
5. **Never run a command in a step marked STOP** until a human has answered.

## The STOP rule

When you see a block like this:

```
STOP
```

it means: **stop executing, report to a human, and wait.** Do not continue to
the next step. Do not try a different command. Do not guess what the human would
have said.

## Ask, do not guess

If any of the following happens, stop and report it to a human:

- the real output does not match the `Expected output` block;
- a command prints an error you were not told to expect;
- a file the instructions refer to does not exist;
- an exit code is not one of the codes listed for that step;
- you are unsure which of two branches applies.

Say what you ran, what you got, and what you expected. Do not improvise a fix.
A wrong guess on this repository set damages a production server.

## Exit codes

Every script in this repository set uses exactly three codes.

| Code | Meaning | What you do |
|---|---|---|
| 0 | Success | Continue to the next step |
| 1 | A check failed. Something is wrong and it is known what | STOP and report |
| 2 | Could not determine the state | STOP and report |

There are no other codes. If you see one, STOP and report.

## Step 1 — confirm you are in the right directory

Run:

```bash
cd /opt/corp-infra/bootstrap && pwd && ls -1
```

**Expected output**

```
/opt/corp-infra/bootstrap
AGENTS.md
CLAUDE.md
LICENSE
README.md
for-ai-dumb
for-ai-smart
for-humans
lib
profiles
providers
schemas
scripts
versions.env
```

The order of names may differ. Files beginning with a dot are not shown; that is
normal.

**Verification**

```bash
test -f scripts/recon.sh && test -f lib/common.sh && echo LAYOUT_OK
```

Expected: `LAYOUT_OK`

If you do not see `LAYOUT_OK`, the repository is not where the instructions
expect it.

```
STOP
```

Report: "scripts/recon.sh or lib/common.sh not found under /opt/corp-infra/bootstrap".

## Step 2 — confirm the scripts are syntactically intact

Run:

```bash
bash -n lib/common.sh scripts/recon.sh scripts/bootstrap.sh && echo SYNTAX_OK
```

**Expected output**

```
SYNTAX_OK
```

**Verification**

```bash
tail -1 scripts/recon.sh
```

Expected output:

```
main "$@"
```

The last line of every script must be exactly `main "$@"`. If it is not, the
file was truncated during download and must not be executed.

```
STOP
```

Report: "scripts/recon.sh does not end with main \"\$@\"; the file may be truncated".

## Step 3 — choose which file to read next

Read them in this order. Do not skip ahead.

| Order | File | What it does |
|---|---|---|
| 1 | [`01-recon.md`](01-recon.md) | Measure the host. Changes nothing. |
| 2 | [`02-choose-profile.md`](02-choose-profile.md) | Decide which profile fits. Changes nothing. |
| 3 | [`03-run-stages.md`](03-run-stages.md) | Install everything. **Changes the host.** |
| 4 | [`04-verify.md`](04-verify.md) | Confirm the result. Changes nothing. |

Go to [`01-recon.md`](01-recon.md) now.

## What you must never do

- Never run an outbound port scan (`nmap`, `masscan`, or any probe of a machine
  you do not own). It is forbidden by the hosting provider's contract.
- Never delete a file under `/var/lib/corp-infra/markers/` to make a check pass.
- Never edit `lib/common.sh` in any repository other than this one.
- Never commit or print a private key.
- Never run a script with both `--check` and `--yes`. That combination is an
  error and exits 2.
