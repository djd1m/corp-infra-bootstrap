# Installation notes

## 2026-09-07 — dual-S3 backup acceptance result

- `install-backup.sh`: OK; both live versioning checks passed, four persistent
  timers were enabled, and `corp-backup.slice` received the profile cap.
- First snapshot: OK for `platform` and `vpn-proxy`; manifest coverage 2/2.
- Local integrity: `restic check --read-data-subset=2%` found no errors.
- Primary immutable copy: Yandex Cloud OK.
- Secondary immutable copy: Cloud.ru OK.
- Restore proof: the `single-file` drill restored the SSH configuration into a
  scratch directory; recursive diff matched, the drill journal recorded OK,
  and the verified scratch directory was removed.
- Final `backup.sh --check`: exit 0. GitLab rows are correctly inconclusive on
  this apps VPS because GitLab belongs to the separate Cloud.ru server.

## 2026-09-07 — application install must create safe initial admins and coverage

- OpenProject upstream seeds `admin/admin` unless the initial seeder receives
  explicit admin password variables. The public template now supplies a
  generated password, email and display name through SOPS on the first run.
- Publishing a manifest and waiting cannot make a service appear in backup
  coverage: coverage records completed restic snapshots. A new service unit now
  triggers its mandatory first service-scoped backup, rescans, and only then
  writes its installed marker.
- The public proxy is bound to the explicit external address, so probing a new
  public vhost through `127.0.0.1` always produced a false warning. The probe now
  reads `PUBLIC_BIND_IP` from the rendered Caddy environment.
- The original coverage assertion searched the entire JSON document. A service
  listed only under `expected` was therefore mistaken for one listed under
  `covered`, and the installer could write its marker without a snapshot. The
  assertion now parses only `covered`; the live first runs moved coverage from
  `2/3` to `3/3`, then from `3/4` to `4/4` after real restic snapshots.

## 2026-09-07 — public application health and restore drills

- The Mattermost Team Edition image has no `curl` (and no shell), so its Docker
  healthcheck never ran although the server, database and filestore were OK.
  The checked command is now the bundled `mmctl system status --local`.
- Restarting Caddy to add a first public hostname briefly returns HTTP `000`
  while Caddy starts and ACME issues the certificate. Apply mode now waits a
  bounded 120 seconds for valid public TLS; check mode remains single-shot.
  Re-registering a byte-identical vhost is a no-op and no longer restarts Caddy.
- The vhost probe appended its fallback `000` to curl's own `000`, producing
  the misleading code `000000`. Curl output is now normalised once.
- A service restore drill used to record `OK` when `pg_restore` was absent even
  though no dump was validated. It now reuses an already-pulled, pinned
  PostgreSQL image with networking disabled and a read-only scratch mount, and
  fails if neither verifier is available. Live Mattermost and OpenProject
  restore drills both passed `pg_restore --list`.

## 2026-09-07 — Alpine PostgreSQL could not enter root-owned bind storage

- Symptom: `corp-mattermost-db` repeatedly logged `mkdir: can't create directory
  '/var/lib/postgresql/data/pgdata': Permission denied` and became unhealthy.
- Cause: the service template created the host bind directory as `root:root
  0750`, while `postgres:*‑alpine` drops to uid/gid `70:70` before creating
  `PGDATA`.
- Fix: both Mattermost and OpenProject installers assign only their dedicated
  `pgdata` directory recursively to `70:70` before Compose starts. Application
  storage keeps its separate application UID and no permission is widened.

## 2026-09-07 — the first real backup was blocked by its platform manifest

- Symptom: `rescan-manifests.sh --check` stopped the first snapshot because
  `/opt/corp-infra/versions.env` and `/opt/corp-infra/**/*.enc.yaml` did not
  resolve.
- Cause 1: the version lock is canonical inside the bootstrap checkout at
  `/opt/corp-infra/bootstrap/versions.env`; the platform manifest and two
  upgrade runbooks documented a stale root-level location.
- Cause 2: `*.enc.yaml` is a supported but profile-dependent secret format.
  The manifest language had no way to retain that future coverage without
  requiring at least one such file on every host.
- Fix: point every version-lock consumer at the canonical repository file and
  add schema-backed `optional_include[]`. Required `include[]` entries remain
  strict; optional entries are expanded and backed up whenever present, their
  absence is logged but is not a failure, and secret-key hygiene applies to
  both arrays.

## 2026-09-07 — freshly uploaded Cloud.ru objects were not immediately readable

- Symptom: initial `rclone copy --immutable` reported a transient 403 on one
  object, succeeded on its internal retry, but the immediately following
  `restic cat config` failed. A later read-only check succeeded for ListObject,
  GetObject, and `restic cat config` with the same credential.
- Cause: a short post-write visibility/policy-propagation window at the S3
  endpoint; treating one immediate read as final produced a false install
  failure.
- Fix: the mutation path still requires the copied repository to answer through
  restic, but retries that read up to five times with a bounded five-second
  interval. The read-only checker remains strict and reports the live result.

## 2026-09-07 — Cloud.ru groups PutObject and DeleteObject in one role action

- Symptom: after fixing the composite access key ID, the live versioning query
  returned `403 AccessDenied`.
- Immediate cause: the service account lacked `GetBucketVersioning`, provided
  by bucket role `s3e.viewer-acl` / custom-role action
  `s3e.bucket.viewPolicy`.
- Deeper design issue: Cloud.ru action `s3e.bucket.edit` grants both PutObject
  and DeleteObject. A write-capable custom role therefore cannot itself be a
  no-delete credential, contrary to the original plan.
- Fix: use bucket-scoped `s3e.editor`, `s3e.viewer`, and `s3e.viewer-acl`, then
  explicitly Deny `s3:DeleteObject` and `s3:DeleteBucket` for the backup
  service-account principal in Bucket Policy. Do not grant `s3e.admin`,
  `s3e.tenant.edit`, or project Administrator because they bypass Bucket
  Policy. The reusable policy is
  `cloudru-backup-bucket-policy.json.example`.
- Verification: the repair helper distinguishes `InvalidAccessKeyId` from
  `AccessDenied` and requires a live `Enabled` response before changing the
  encrypted configuration.

## 2026-09-07 — Cloud.ru accepted an incomplete Access Key ID in the helper

- Symptom: the dual-S3 helper encrypted the entered values, but the canonical
  installer stopped before seeding or installing timers; Cloud.ru returned
  `403 InvalidAccessKeyId` while reading bucket versioning.
- Cause: Cloud.ru S3 authentication requires the complete
  `tenant_id:key_id` or `tenant_id.key_id` value. The helper only checked that
  the field was non-empty and therefore accepted a bare Key ID.
- Fix: validate the provider-specific composite ID before writing encrypted
  configuration. `repair-cloudru-backup-key.sh` checks the replacement key and
  live versioning read-only before replacing only the Cloud.ru credential; it
  preserves the restic password and the working Yandex configuration.
- Documentation improvement: show `tenant_id` and Key ID as two values that
  must be joined, and distinguish `InvalidAccessKeyId` from missing IAM actions.

## 2026-09-07 — two daily S3 targets expose a false delete-permission probe

- Selected layout: Yandex Cloud is the primary offsite repository; Cloud.ru is
  an independent secondary repository with its own credentials and timer.
- Existing partial support: `backup.sh` could copy to a secondary runtime env,
  but `install-backup.sh` neither rendered its encrypted source nor initialized
  the repository nor enabled the timer.
- Documentation bug: the installer treated a successful
  `restic forget --dry-run` as evidence that delete was allowed. Restic dry-run
  performs no removal, so it cannot test provider IAM in either direction.
- Fix: the installer now handles `backup-secondary.enc.env`, seeds and checks
  both offsite repositories, and enables the secondary daily timer. Its
  read-only check validates an explicit provider-role attestation and reads
  the live bucket-versioning status; provider IAM remains the enforcement point.
- Safe credential policy: Yandex uses a bucket-scoped `storage.uploader` role;
  Cloud.ru combines bucket-scoped roles with an explicit delete Deny in Bucket
  Policy. No effectively delete-capable credential is stored on this VPS.

## 2026-09-07 — decrypted backup scratch files escaped cleanup

- `bk_tmpfile` appended each temporary path to `BK_TMPFILES`, but every caller
  invoked it through command substitution (`path="$(bk_tmpfile)"`). Bash runs
  that function in a subshell, so the parent cleanup trap always saw an empty
  array and could leave decrypted 0600 files in `/tmp`.
- Fix: the function now assigns a caller variable directly in the current
  shell; every path is registered and removed by the EXIT trap. The dual-S3
  helper uses the same safe calling convention.

## 2026-09-07 — restic remote locks contradict no-delete S3 credentials

- The original design called `restic copy` against an S3 repository while also
  requiring the VPS credential to have no `DeleteObject` permission.
- Restic creates a destination lock and removes it on completion. Therefore a
  genuinely no-delete credential cannot complete the documented copy path;
  this would only become visible during the first real backup.
- Fix for S3 targets: keep restic as the repository/restore format, but copy
  the local repository object tree with `rclone copy --immutable`. This command
  does not delete destination-only objects and refuses mismatched overwrites.
  Bucket versioning is mandatory so a compromised PutObject credential cannot
  destroy the previous version by overwriting the same key.

## 2026-09-07 — an offline operator laptop blocked every downstream stage

- `install-wireguard.sh --check` required a handshake newer than 300 seconds.
  Once the Windows client was intentionally disconnected, the healthy server
  returned exit 2; `require_stage vpn.ready` therefore blocked backup and all
  later installation indefinitely.
- A fresh handshake is required to establish the initial readiness marker.
  For subsequent live checks, a peer that has handshaked at least once proves
  the path was established; interface, forwarding, firewall and forbidden UI
  are still checked live. A stale handshake is now warning telemetry, not an
  inconclusive stage result.

## 2026-09-02 — repository checkout is disabled by the shipped lock file

- Stage: preflight before `security`.
- Expected: `bootstrap.sh` clones the five pinned stage repositories before
  starting the state machine.
- Actual: `versions.env` contains `CORP_INFRA_GITHUB_ORG="<org>"`; all five
  stage repositories are absent under `/opt/corp-infra`.
- Behaviour: `bootstrap.sh` will warn that the organisation is unset, skip all
  repository checkouts, and later stop because the `security` repository is
  absent.
- Safe remediation: set `CORP_INFRA_GITHUB_ORG` to the confirmed organisation
  that owns all five repositories, or place verified checkouts at the paths
  expected by the orchestrator.
- Verification:

  ```bash
  for name in security vpn-proxy backup ent-infra pop-agents; do
      test -d "/opt/corp-infra/$name/.git" || echo "$name: absent"
  done
  ./scripts/sync-lib.sh --check
  ```

- Documentation improvement: the quick start must explicitly require replacing
  `<org>` in `versions.env` (and verifying access to every pinned repository)
  before invoking `bootstrap.sh`.

## 2026-09-02 — unprivileged checks cannot open the standard log file

- Stage: disk/recon preflight.
- Expected: read-only checks print their verdict.
- Actual: when run as an unprivileged user, scripts also print a warning that
  `/var/log/corp-infra/...` is not writable and fall back to stdout.
- Impact: none on the check result; the commands still return their documented
  verdicts.
- Documentation improvement: describe this warning as expected for an
  unprivileged preflight, and use root for the actual bootstrap run.

## 2026-09-02 — private GitHub repositories are not accessible from the host

- Stage: repository checkout preflight.
- Expected: each pinned `v1.0.0` tag can be resolved before bootstrap starts.
- Actual: unauthenticated HTTPS asks for GitHub credentials; `gh` is not
  installed; SSH access to `github.com:22` times out.
- Impact: bootstrap cannot clone any stage repository yet.
- Safe remediation: configure read access over HTTPS, or configure GitHub SSH
  access over an allowed endpoint such as port 443, then verify every pinned
  tag with `git ls-remote` before running bootstrap.
- Documentation improvement: add GitHub authentication and connectivity to the
  quick-start prerequisites and provide a non-interactive verification command.

Follow-up: the token is stored at `/root/.secrets/github_token` (underscore,
not hyphen). Git Smart HTTP requires a username/password credential shape here;
an `Authorization: Bearer` extra header still caused Git to request a username.
The local helper `github-credential-helper.sh` supplies `x-access-token` and the
token ephemerally without storing it in a remote URL or Git configuration.

## 2026-09-02 — pinned release tags do not exist

- Stage: repository checkout preflight.
- Expected: `versions.env` pins `v1.0.0` for all five stage repositories.
- Actual: all repositories are accessible, but none has any Git tags.
- Temporary installation decision: use the current `main` heads, record their
  commit IDs, and do not create or push tags as part of server installation.
- Documentation improvement: publish the pinned release tags, or document a
  commit-based development installation path.

## 2026-09-02 — cached recon predates the disk resize

- Stage: sizing preflight.
- Expected: bootstrap sizing uses the resized root filesystem.
- Actual: `/var/lib/corp-infra/recon/latest.json` was still fresh by the 24-hour
  rule, but recorded 196 GB and a failing profile recommendation. A current
  read-only recon measured 216 GB.
- Safe remediation: regenerate the stored recon after changing VPS resources,
  even when the previous document is younger than 24 hours.
- Documentation improvement: explicitly invalidate/re-run recon after CPU, RAM,
  disk, network, or provider changes.

## 2026-09-02 — this host is the apps node, not the GitLab node

- Confirmed deployment profile: `two-vps-split-b` (`node_role: apps`).
- GitLab and CI are reserved for the second server in Cloud.ru and must not be
  installed on this host.
- The profile correctly includes only tracker (OpenProject), wiki, site, and
  observability business services.

## 2026-09-02 — Mattermost is missing from the corp-infra service model

- Confirmed placement: Mattermost runs on this apps node.
- Research input: `mattermost-k8s-adrs.zip`, SHA-256
  `cfe1352d018cce48ef26f85a71c5ee295c7d87cab6c18b88b045209f6c50169b`.
- Adopted findings: Mattermost Team Edition with PostgreSQL behind HTTPS;
  Mattermost is the user-facing agent console; an Agent Gateway provides a
  common Claude/Codex session contract; runners are isolated per project and
  each task uses its own Git worktree; credentials are rotated outside chat.
- Kubernetes/Kompose is deferred. This installation already has a Compose-based
  service contract, and the research describes Kompose only as a bootstrap
  generator whose output is not production-ready without manual design.
- Missing implementation: profile budget, pinned Compose service, encrypted
  secret template, backup manifest/hooks, vhost registration, health check and
  installer entry point.
- Product mapping: Grafana is already part of `observability`; Jira is not
  deployed, and the selected profile intentionally uses OpenProject CE as the
  tracker.

## 2026-09-02 — security prerequisites are not bootstrapped

- Stage: immediately before applying `security`.
- Present: `fail2ban-client`, `unattended-upgrade`.
- Missing: `ufw`, `age-keygen`, `sops`; `auditctl` is also missing but the
  script explicitly treats auditd as advisory.
- Expected: the documented bare-VPS quick start can run `harden.sh` directly.
- Actual: `harden.sh` calls `require_cmd ufw` and later `require_cmd age-keygen
  sops`, but neither it nor the umbrella installs these hard dependencies.
- Impact: applying the script now would stop partway through the security
  stage.
- Documentation/implementation improvement: add a checked prerequisite
  installer (including an authenticated, pinned source for sops), or list exact
  installation commands before the first mutation.

### Package-install side effect

Installing `ufw age auditd` from Ubuntu removed `iptables-persistent` and
`netfilter-persistent` and `needrestart` restarted SSH plus several systemd
services. The SSH session survived and `sshd -t` remained valid. Post-checks:
`ssh`, `docker`, `auditd`, and `fail2ban` were active; UFW was still inactive.
Docker's runtime chains remained present. Two pre-existing INPUT drops for TCP
ports 3389 and 2096 were still in memory, but their former persistence mechanism
was removed. The installation guide should call out this package conflict and
verify whether those provider rules are intentionally replaced by the canonical
UFW perimeter before enabling UFW.

## 2026-09-02 — first-run secrets policy prevents the documented escrow flow

- Stage: `security`, after the host baseline was applied.
- Expected by `harden.sh`: `secrets-init.sh` may return `2` on the first run
  while `ci` and `break-glass` recipients remain placeholders; the prod
  recipient should still be accepted and the private key display/escrow gate
  should follow.
- Actual: `secrets-init.sh` attempted its SOPS round-trip with the placeholder
  recipients, failed encryption, and returned `1`. `harden.sh` treated this as
  fatal and exited before `print_private_key_once` was called. Bootstrap marked
  `stages.security` as `failed` and never reached its documented escrow STOP.
- Current reality: SSH, Docker, fail2ban and auditd are active; UFW is active
  with the five canonical ports and SSH still open from `Anywhere`; the age key
  exists at the canonical path with mode 0600; escrow is not attested.
- Required improvement: on an initial prod-recipient update, either omit
  placeholder roles from `creation_rules` until assigned, or classify the
  placeholder-caused round-trip as inconclusive (`2`) so the human escrow flow
  is reachable. Add an end-to-end clean-host test that proves the key display
  precedes the escrow STOP.

## 2026-09-02 — interactive escrow confirmation rejected visible `y`

- The human-supplied fingerprint was accepted, proving that the escrow copy
  matched the host recipient.
- At the final `record the escrow attestation ...? [y/N]` prompt, a visible
  `y` entered from Windows Terminal was handled as a decline.
- No escrow document or marker was written.
- Safe retry: the human repeats the same independently derived fingerprint and
  locations with the documented `--yes` flag. This bypasses only the final
  write confirmation; it does not derive or bypass fingerprint validation.
- Improvement: trim carriage returns and surrounding whitespace in `confirm()`
  before matching the answer, and add a CRLF-input test.

## 2026-09-07 — `bootstrap --stage security` marks the whole run done

- After a successful single-stage security reconciliation, bootstrap correctly
  wrote `stages.security=ok` and published the live-backed marker.
- It then unconditionally wrote `current_stage=done` and presented the final
  disaster-recovery STOP even though VPN, backup, ent-infra and pop-agents were
  still pending.
- With `--yes`, both the already-completed escrow STOP and the not-yet-possible
  disaster-recovery STOP were auto-confirmed.
- The final stage map remained honest (security `ok`, all later stages pending),
  but `current_stage=done` and the STOP output were misleading.
- Improvement: single-stage mode must not set the global run to `done`; the DR
  gate must run only when every stage is live-verified `ok`; human STOP gates
  must never be bypassed merely because `--yes` was supplied.

## 2026-09-07 — adminVPS Netherlands had no exact provider policy

- Actual hosting class: adminVPS, Netherlands; the real base domain remains
  host-local and documentation uses `<base-domain>`.
- The profile `two-vps-split-b` used `generic`, whose policy says outbound port
  scanning is allowed. The adminVPS offer forbids it in every location.
- `adminvps-ru` carried the right technical constraints for the European
  locations but was the wrong declared provider/location identity.
- Fix prepared in the bootstrap source: add `adminvps-eu`, include it in all
  schemas and documentation, and select it in `two-vps-split-b`.
- Installation rule remains strict: no outbound scan; reachability is checked
  by the operator from their own Windows workstation.

## 2026-09-07 — first WireGuard peer requires a real human terminal

- `install-wireguard.sh` automatically issues the initial `operator` peer.
  The rendered configuration contains its private key and is intentionally
  emitted outside the log on file descriptor 9.
- Running this step through an automation capture channel would expose the
  credential and would violate the R3 rule against autonomous peer issuance.
- `local-tools/complete-wireguard-bootstrap.sh` requires a TTY and an explicit
  `ISSUE` confirmation, invokes the canonical installer, pauses for the Windows
  client to connect, and invokes it again to publish `vpn.ready` only after a
  fresh handshake.
- Windows Terminal again displayed the exact expected answer while the helper
  rejected it. The helper now removes CRLF, surrounding whitespace and the
  standard bracketed-paste start/end sequences before comparing the still-exact
  keyword `ISSUE`.
- The first real attempt then stopped before installing WireGuard because
  `require_stage` received `"/opt/.../harden.sh --check"` as one executable
  name instead of receiving the executable and `--check` as separate argv
  elements. The security marker was valid and a direct `harden.sh --check`
  returned 0; no `wg0`, package, server key, or operator peer had been created.
- The helper incorrectly treated every installer exit 2 as the expected
  "configuration created, handshake pending" state and invited the operator to
  import a configuration that had never been printed. It now continues on exit
  2 only when both live `wg0` and `/etc/wireguard/peers/operator.conf` exist;
  otherwise it stops explicitly. All four malformed `require_stage` call sites
  in `vpn-proxy` now pass `--check` as its own argument.
- The resumed run reached peer creation, but `sops` inherited
  `/opt/corp-infra/security/.sops.yaml` from the caller's working directory and
  rejected `/etc/wireguard/peers/operator.conf` with `no matching creation
  rules found`. The live peer and its 0600 operational file were already
  created, but no encrypted copy or terminal `BEGIN/END` block followed.
- `wg-user.sh` now disables implicit config discovery when it supplies the age
  recipient explicitly, and an idempotent retry repairs a missing encrypted
  copy before reprinting the existing peer configuration. The helper also
  recognises this exact partial state as resumable. `.gitignore` now re-includes
  `secrets/peers/*.enc.conf`; previously the ignored parent directory prevented
  the documented encrypted peer backups from being tracked.
- A second Windows Terminal attempt visibly entered `ISSUE` but still delivered
  a byte sequence the prompt rejected. Instead of broadening fuzzy input
  acceptance, the helper now requires the unambiguous command-line flag
  `--issue-operator`. Running that exact command is the human R3 decision; the
  TTY requirement remains, so the private configuration cannot be captured by
  non-interactive automation.

## 2026-09-07 — business services must be public, not VPN-only

- Operator decision: Mattermost and OpenProject are employee-facing services
  and must work without a WireGuard client. Templates use
  `chat.<base-domain>` and `projects.<base-domain>`.
- Databases and container ports remain private. Only `80/443` on the public
  Caddy instance may face the Internet; each public frontend needs its own
  explicit Docker network path to that proxy.
- Grafana and infrastructure administration remain VPN-only.
- Current mismatch: `install-tracker.sh` hard-codes
  `tracker.corp.<domain>`, registers only an internal vhost, and treats every
  public answer as `INV-ENT-7` failure. This is a product/plan mismatch, not an
  installation error.
- Orchestration mismatch: bootstrap does not accept or persist a corporate
  domain and does not pass one to the proxy or service installers, although
  those installers require it. The source plan must gain one authoritative
  domain input before an unattended five-stage run can work.

### Source fixes prepared

- Bootstrap now accepts `--domain`, persists it in `state.json`, and passes it
  to the proxy and all ent-infra installers.
- `two-vps-split-b` explicitly declares public `projects` and `chat` services.
- OpenProject uses a dedicated frontend network shared only with the selected
  Caddy instance; PostgreSQL and Memcached remain on `internal:true`.

## 2026-09-07 — wildcard public Caddy conflicts with VPN-only Caddy on 443

- The first proxy apply created both Docker networks and started
  `corp-caddy-public`, then Docker refused `corp-caddy-internal` with `Bind for
  0.0.0.0:443 failed: port is already allocated`.
- Compose had correctly rendered the internal binding as `10.8.0.1:443`; the
  error is the kernel-level collision with the public container already bound
  to wildcard `0.0.0.0:443`. A wildcard IPv4 socket includes the wg0 address,
  so the documented expectation that both sockets coexist is impossible on one
  host.
- The host has distinct public and WireGuard addresses. The safe single-host
  design is to bind public Caddy to
  the primary external-interface address explicitly and internal Caddy to the
  wg0 address explicitly. This keeps zone separation by network path but
  requires a reviewed change to the documented `0.0.0.0` public binding.
- Partial state after the failure: `corp-caddy-public` healthy on public
  80/443, `corp-caddy-internal` created but not running, both Docker networks
  present, and no application vhosts published.
- After the address fix both Caddy instances became healthy, but proxy apply
  still failed while publishing its backup manifest. It treated the mere
  presence of the cloned backup repository as proof that stage 3 was installed
  and ran `rescan-manifests.sh` before `backup.ready` existed. That creates a
  dependency cycle: stage 2 cannot require a live stage 3 when the fixed order
  is `vpn-proxy -> backup`.
- Proxy manifest publication now checks the stage state. Before `backup.ready`,
  it publishes the manifest and returns an explicit deferred-rescan warning;
  after `backup.ready`, a missing or failing rescan remains fatal.

## 2026-09-07 — backup check accepted a profile but did not load it

- `install-backup.sh --check --profile two-vps-split-b` reported that
  `profile.offsite.primary` was empty, although the profile selects a provider.
- The check branch called the offsite gate before any `profile_load`; only the
  apply branch loaded the profile. The CLI therefore promised an assertion it
  could not perform.
- Check and apply now use one `load_selected_profile` function. The corrected
  check distinguishes "no provider selected" from "provider selected but
  runtime credentials are not configured".
- Mattermost Team Edition is a full service unit: exact image tag, isolated
  PostgreSQL, public vhost, logical dump hook and backup manifest.

## 2026-09-07 — container registry transient 500

- Docker Hub returned HTTP 500 to manifest HEAD requests for both Mattermost
  and the official PostgreSQL image, so the first verification could not
  distinguish a missing tag from a registry failure.
- Retrying the same read-only requests, without changing tags, succeeded:
  Mattermost Team Edition `11.7.8`, PostgreSQL `16.9-alpine`, OpenProject
  `17.8.0-slim`, PostgreSQL `17.10-alpine`, Memcached `1.6.39-alpine` and
  Hocuspocus `17.8.0` all expose valid OCI manifests.
- Improvement: image preflight should retry transient registry 5xx responses
  and retain the exact requested tag.

## 2026-09-07 — OpenProject compose was stale and incomplete

- The repository pinned OpenProject `16.4`; the current exact release is
  `17.8.0`, and upstream recommends the `-slim` image for Compose production.
- The old compose configured `OPENPROJECT_RAILS__CACHE__STORE=memcache` but did
  not define any Memcached container. It also had no seeder or cron process.
- The corrected service unit follows upstream stable/17 process roles while
  omitting upstream's Docker-socket autoheal and disabling optional real-time
  collaboration until its separate WebSocket route is deliberately designed.

## 2026-09-07 — targeted vhost check ignored its target

- `register-vhost.sh --check --service ... --fqdn ... --zone ...` parsed those
  arguments but ran only a global fragment validation. A service could report
  its own vhost registered because an unrelated fragment was healthy.
- The check now proves the exact fragment, FQDN, service id and requested
  Docker network. It also proves the exact upstream and the selected Caddy
  container's live attachment to that network.

## 2026-09-07 — swap/OOM policy exists in prose but not in the baseline

- Recon reports 511 MB of active `/swapfile`; `/etc/fstab` enables it at boot.
- The quick start says swap must be disabled and observability has a firing
  alert for any configured swap, but `harden.sh --check` does not inspect swap
  and returned `OK`.
- `systemd-oomd` is not installed and no `corp-core`, `corp-ci` or
  `corp-agent` slice units exist; only the backup repository ships
  `corp-backup.slice`.
- The authoritative sizing result still classifies this as a warning, not a
  blocker, and the revised `two-vps-split-b` profile passes G1/G2/G4. Do not
  merely run `swapoff`: first implement and verify the replacement oomd/slice
  policy owned by the source plan.

## 2026-09-07 — source verification commands require their documented context

- Direct `docker compose config` for the Caddy files fails before proxy
  installation because `/etc/corp-infra/caddy/.env` intentionally does not yet
  exist. CI seeds a stub only inside its disposable runner; do not create that
  runtime file on a production host to make a static check green.
- `scripts/dr-coverage-check.py` is invoked through `python3` and requires both
  `--manifest manifests/platform.backup-manifest.json` and
  `--expected config/dr-coverage.expected.json`. Calling it as an executable or
  omitting these flags is an operator-command error, not a coverage failure.

Follow-up: the token is stored at `/root/.secrets/github_token`. Because shell
redirections are evaluated before `sudo`, `sudo tr ... < /root/...` still reads
the file as the unprivileged shell and fails. A command such as
`sudo cat /root/.secrets/github_token | tr -d '\\r\\n'` performs the read in
the privileged process. Never enable shell tracing around this operation.

Authentication with GitHub Smart HTTP requires the token in a Basic
`x-access-token:<token>` credential for these Git operations; a Bearer header
did not authenticate `git ls-remote`.

## 2026-09-02 — pinned release tags do not exist

- Stage: repository checkout preflight.
- Expected: `versions.env` pins `v1.0.0` for every stage repository and
  `git ls-remote --tags` resolves those refs.
- Actual: authentication succeeds and all five repositories expose `main`, but
  none of them exposes any tag.
- Impact: the documented bootstrap clone command uses `--branch v1.0.0` and
  cannot check out any stage repository.
- Safe remediation: publish the reviewed `v1.0.0` tags required by the lock
  file, or intentionally revise the versioning contract and bootstrap logic.
  Do not silently substitute `main` for the pinned release.
- Documentation improvement: release preparation should verify that every
  version in `versions.env` exists remotely before the quick start is given to
  an operator.

## 2026-09-08 — observability `full` on `two-vps-split-b`

The final live acceptance result was positive: all eight containers healthy,
Prometheus 11/11 targets up, five Grafana dashboards provisioned, Loki
push/query round-trip green, four VPN-only vhosts unreachable through the
public address, backup coverage 5/5, and fresh immutable copies sent to the
Yandex Cloud primary and Cloud.ru secondary repositories.

Rakes found before that result and their necessary fixes:

1. `gcr.io/cadvisor/cadvisor:v0.53.0` does not exist. cAdvisor moved release
   `v0.53.0` and newer to `ghcr.io/google/cadvisor`; verify exact manifests
   before starting Compose so one missing image does not interrupt every pull.
2. OCI cannot create a nested bind mount below the read-only
   `/etc/prometheus` bind. Dynamic file-SD targets now mount separately at
   `/etc/corp-targets`.
3. Prometheus 3.5 rejects `source_labels` on a `labeldrop` action. The supported
   form is `regex: <label-name>` plus `action: labeldrop`.
4. The upstream Alloy image is distroless and has no `wget`/`curl`. Its Docker
   healthcheck uses `/bin/alloy validate`, while the HTTP server explicitly
   listens on `0.0.0.0:12345` so Prometheus can scrape it across the bridge.
5. A previously created target directory was `0750 root:root`; Prometheus runs
   as uid 65534 and could not traverse it. Reconcile repairs the directory to
   `0755`, not only on first creation.
6. Reusing service id `observability` for four hostnames overwrote one Caddy
   fragment four times. Each endpoint now has a distinct id:
   `observability-{grafana,prometheus,alerts,logs}`; the old single fragment is
   removed through the registration ACL.
7. Grafana API checks assumed username `admin`, although the bootstrap permits
   a different administrator name. Checks now read both username and password
   from the 0600 runtime env.
8. Static Caddy scrape targets were unreachable by design: the internal admin
   API is loopback-only and the public admin API is disabled. They were removed
   instead of permanently weakening the 95% target-health gate.
9. Static blackbox targets named services that were not installed in this
   profile, including GitLab on the other VPS. Targets are now rendered only
   for installed public service markers.
10. VPN-only Caddy cannot complete public HTTP-01, and repeated attempts caused
    ACME authorization errors. Internal fragments now use `tls internal` unless
    an explicit DNS-01 provider is configured; public vhosts keep HTTP-01.
11. Shell command substitution strips trailing newlines. The TLS fragment
    renderer failed because `tls internal` was joined to `reverse_proxy`; the
    renderer, not the producer, now restores exactly one newline.
12. Grafana's unauthenticated root returns `302` to the login page, not `200`.
    The observability acceptance check expects that exact healthy response.
13. Prometheus retained removed scrape jobs until reload. Apply now calls its
    lifecycle reload endpoint before measuring the target-up percentage.
14. Loki accepted the probe but the old instant-query did not reliably return
    it. Deep-check now writes a unique nanosecond marker and queries an explicit
    bounded interval with `query_range`; plain `--check` remains read-only.
15. Newly created private A records were immediately correct at the
    authoritative servers but recursive resolvers briefly disagreed because of
    negative caching. Name validation now tries three read-only lookups, still
    failing immediately on any concrete address outside the VPN subnet.
16. External notification credentials were intentionally unavailable at first
    deployment. `ALERT_DELIVERY_MODE=disabled` renders a no-op receiver while
    keeping Alertmanager and alert visibility healthy; external delivery can
    be enabled later as a separate tested change.

The bootstrap helper is safe to resume after an interrupted image pull: when
the encrypted observability bundle already exists, it validates and reuses it
without rotating or printing credentials. It reports success only after normal
and deep checks, primary backup coverage, and a secondary sync when that target
is enabled.

## 2026-09-08 — BookStack VPN-only bootstrap

The final live acceptance result was positive: BookStack and MariaDB were
healthy on isolated Docker networks, the private endpoint returned the expected
login redirect, the configured administrator had the admin system role, the
vendor `admin@admin.com` account was absent, coverage was 6/6, snapshot
`72014d62` was copied to Yandex Cloud, and the subsequent Cloud.ru secondary
phase returned `OK`.

Rakes found before that result and their necessary fixes:

1. The documented `<version>` placeholder was not executable guidance. Exact
   reviewed releases are BookStack `v26.05.3-ls278` and MariaDB
   `11.8.8-r0-ls226`, pinned by their multi-platform OCI index digests.
2. `awk ... {print; exit}` in a digest-inspection pipeline causes upstream
   Docker Buildx to receive SIGPIPE. With `set -o pipefail` the helper exited
   silently. The parser now records the first digest but consumes all input
   before printing it in `END`.
3. A Windows terminal paste can append invisible whitespace to an otherwise
   valid email. The helper strips only outer whitespace before applying the
   strict email validation; an existing Yandex address is valid and no private
   mail server is required.
4. BookStack ships `admin@admin.com` / `password`. A healthy container was not
   sufficient acceptance. Apply now invokes the supported
   `bookstack:create-admin --initial` command without putting its password in
   argv, and check proves the configured email has `roles.system_name=admin`
   while the vendor account count is zero.
5. The old migration creates `roles.name`, but the live current schema has
   renamed that field to `roles.system_name`. Acceptance follows the live
   reviewed release schema and was tested against the running database.
6. Current LinuxServer MariaDB accepts local root through its Unix socket; using
   `-u root -p"$MYSQL_ROOT_PASSWORD"` returned `Access denied`. Read-only admin
   proof and backup dump use the least-privileged application account from the
   container environment. DR commands that need root use socket auth without a
   password argument.
7. An anonymous BookStack request returns `302` to the login route. The proxy
   correctly accepted it, while the installer incorrectly demanded only `200`.
   BookStack internal acceptance now allows exactly `200` or `302`; VPN-only
   negative-public reachability remains mandatory.

Canonical templates were updated only after the repaired installer produced a
dump, published its manifest, completed the first primary snapshot and passed
the independent Cloud.ru copy.

## 2026-09-08 — site temporarily external on apps node

- Read-only precheck proved that the apex corporate domain still resolves to a
  different host and the `www` name is absent. Publishing Hugo here would have
  changed ownership of an existing public surface and ACME could not succeed.
- Operator decision: keep the site outside this VPS for now and return to it
  later. `two-vps-split-b` therefore uses `site.variant=external` with zero
  local RAM/disk budget.
- This is a first-class profile decision, not a skipped failing step:
  `install-site.sh --check` exits 0 without a container, vhost, manifest or
  marker; backup coverage remains the six locally managed aggregates.
- Return gate: confirm content ownership and both apex/`www` DNS, change the
  variant back to `hugo-static`, rerun G1-G4, then follow the normal precheck →
  build → public TLS → acceptance sequence.
- The bootstrap stage map exposed a separate orchestration bug during this
  change: its ent-infra live proof selected the first generic installer
  (`install-gitlab.sh`) instead of checking the active profile. This produced a
  false `DRIFT` on the apps node although every installed service was green.
  Ent-infra now owns a read-only `check-all.sh` which enumerates the profile;
  bootstrap uses that aggregate for stage checks and prerequisite proof. Live
  result after the fix: `ent-infra ok / ok / ok`, `bootstrap: OK`.

## 2026-09-09 — memory policy gaps resolved with live proof

- Security now owns a dedicated `scripts/reconcile-memory.sh` check/apply path
  and the persistent corp parent/core/ci/agent units. Its live check is part
  of `harden.sh --check`, so a healthy marker cannot conceal missing limits.
- On dz-ent-01 (`two-vps-split-b`), core MemoryMax is 14029M; core and parent
  MemoryLow are 9246M. The exact kernel values were verified without restarting
  any of 19 containers. Guarded daemon-reload applies live resource controls.
- Installed systemd-oomd 255.4-1ubuntu8.17 with runtime service/socket masks
  during package configuration and an explicit user@ override before startup.
  Only CI/agent pressure domains opt in at 60%; core and its ancestors are not
  kill domains. CI/agent are currently empty/inactive, so oomctl has no
  monitored production cgroups until workloads explicitly enter them.
- The daemon killed only a bounded file-backed synthetic workload; kernel and
  core OOM counters stayed 0. A pure anonymous/no-swap probe had high PSI but
  no pgscan and did not trigger: systemd 255 requires recent reclaim activity.
- A repeated apply preserved all 8 file hashes/mtimes and daemon PID/starttime.
  Platform snapshot 2026-09-09T12:39:53Z reached offsite; all 8 policy files
  restored to scratch with identical bytes/modes. No speculative template
  changes were published before installation, repeat and restore proof.
- Human high/low-level architecture and flow diagrams plus smart/dumb tracks
  live in security's memory-policy docs. Backup owns the exact optional
  platform includes and DR instructions. Full replacement-host rebuild and
  a reboot were not part of this proof.
- Remaining placement/budget debt: Caddy x2 and ChatOps remain system.slice;
  ChatOps 1536M must not silently move into agent 600M. Backup still owns its
  installed 819M cap from platform budget; the profile slices table says 800M.
