# Recon — measure the host

Nothing in this file changes the host. Every command here is read-only.

Before you start, confirm the previous file's gate: you must have seen
`SYNTAX_OK` in [`00-start-here.md`](00-start-here.md) step 2. If you did not,
go back and do it now.

## Step 1 — run recon and print the result

Run:

```bash
cd /opt/corp-infra/bootstrap && ./scripts/recon.sh --json > /tmp/recon.json; echo "EXIT=$?"
```

**Expected output**

```
EXIT=0
```

`EXIT=1` or `EXIT=2` are also possible and are **not** a crash. They mean the
host has a problem that recon detected. Write the number down; you will use it
in step 4.

**Verification**

```bash
test -s /tmp/recon.json && echo FILE_WRITTEN
```

Expected: `FILE_WRITTEN`

If the file is empty, recon did not produce output.

```
STOP
```

Report: "recon.sh produced no output; exit code was <the number you wrote down>".

## Step 2 — confirm the output is valid JSON

Run:

```bash
python3 -m json.tool /tmp/recon.json > /dev/null && echo JSON_VALID
```

**Expected output**

```
JSON_VALID
```

**Verification**

```bash
python3 -c "import json;d=json.load(open('/tmp/recon.json'));print(d['schema_version'],d['generator']['script'])"
```

Expected output:

```
1 recon.sh
```

If the output is anything else, the document is not the one this instruction
expects.

```
STOP
```

Report: "recon output failed validation; python3 -m json.tool did not print JSON_VALID".

## Step 3 — read the measured facts

Run:

```bash
python3 -c "
import json
f=json.load(open('/tmp/recon.json'))['facts']
print('os       :', f['os']['pretty_name'])
print('kernel   :', f['os']['kernel'], f['os']['arch'])
print('virt     :', f['virt']['type'], 'detected=', f['virt']['detected'])
print('vcpu     :', f['cpu']['vcpu'])
print('ram_mb   :', f['memory']['mem_total_mb'])
print('avail_mb :', f['memory']['mem_available_mb'])
print('disk_gb  :', f['disk_root']['total_gb'], 'free', f['disk_root']['free_gb'])
"
```

**Expected output** (your numbers will differ; the shape must match)

```
os       : Ubuntu 24.04.1 LTS
kernel   : 6.8.0-41-generic x86_64
virt     : kvm detected= True
vcpu     : 8
ram_mb   : 16384
avail_mb : 15102
disk_gb  : 350 free 331
```

Note: `detected= True` means the machine **is** virtualised. This is the correct
reading. The underlying tool uses an inverted exit code and the library already
corrected for it. Do not reinterpret this field.

**Verification**

```bash
python3 -c "
import json
f=json.load(open('/tmp/recon.json'))['facts']
assert f['memory']['mem_total_mb']>0 and f['cpu']['vcpu']>0 and f['disk_root']['total_gb']>0
print('FACTS_PLAUSIBLE')"
```

Expected: `FACTS_PLAUSIBLE`

If any of those values is zero, the host could not be measured.

```
STOP
```

Report: "recon measured zero RAM, zero vCPU or zero disk".

## Step 4 — read the judgments

Run:

```bash
python3 -c "
import json
j=json.load(open('/tmp/recon.json'))['judgments']
print('os_tier            :', j['os_tier'])
print('profile_recommended:', j['profile_recommended'])
print('sizing_verdict     :', j['sizing_verdict'])
print('exit_code          :', j['exit_code'])
print('blockers:')
for b in j['blockers']: print('  -', b)
"
```

**Expected output on a host that is ready**

```
os_tier            : supported
profile_recommended: core-16
sizing_verdict     : pass
exit_code          : 0
blockers:
```

The `blockers:` line with nothing after it means the list is empty. An empty
blocker list is what you need.

**Verification**

```bash
python3 -c "
import json
j=json.load(open('/tmp/recon.json'))['judgments']
print('READY' if j['sizing_verdict']=='pass' and not j['blockers'] else 'NOT_READY')"
```

Expected: `READY`

## Step 5 — branch on the verification result

Exactly one of these applies.

**If step 4 printed `READY`:** go to
[`02-choose-profile.md`](02-choose-profile.md).

**If step 4 printed `NOT_READY`:** the host cannot be installed as it is.

```
STOP
```

Report to a human, and include:

- the value of `sizing_verdict`;
- every line from the `blockers:` list;
- the values of `ram_mb`, `vcpu` and `disk_gb` from step 3.

Do not try to fix it. Do not re-run with a different profile to see if that
helps. Do not pass `--force-profile`. That flag exists for a human to use after
reading the blockers.

## What recon does not do — and why you must not do it either

Recon never contacts the network. It does not query the cloud provider's
metadata service, and it does not scan ports on any host.

Port information comes only from listeners on this machine, read with `ss`. If
you are asked to "check whether port 443 is reachable from outside", the answer
is that a human does this from their own machine. Running a scan from this
server violates the hosting provider's contract.

## Ask, do not guess

If any expected output did not match, or a command printed an error you were not
told to expect: stop, report what you ran, what you got, and what you expected.
Do not improvise.
