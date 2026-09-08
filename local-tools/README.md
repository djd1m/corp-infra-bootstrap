# Local tools

This directory contains ad hoc diagnostic and troubleshooting scripts created
during installation work.

These scripts are not part of the canonical bootstrap interface. Production
entry points remain under `scripts/`. Before running any helper that can mutate
the host, run its documented read-only check first.

When a helper exposes an installation problem, record the expected result, the
actual result, the cause, the safe remediation, and the verification command so
the finding can be incorporated into the canonical installation instructions.

## Interactive helpers

- `complete-age-escrow.sh` records the human-verified age escrow attestation.
- `complete-wireguard-bootstrap.sh --issue-operator` performs the first
  WireGuard install in a real terminal, where the operator peer's private
  configuration cannot be captured by an automation log. Initial issuance
  requires a Windows handshake; later checks accept a stale handshake as proof
  of prior connectivity while still checking the live interface and firewall.
- `complete-public-apps-bootstrap.sh --install` creates SOPS-encrypted
  Mattermost/OpenProject configs, shows generated administrator passwords once
  on the operator TTY for KeePassXC, installs both public services and requires
  their first service-scoped backups before reporting success.
- `complete-observability-bootstrap.sh --install-disabled` creates a
  SOPS-encrypted Grafana credential, installs the full observability stack and
  intentionally keeps Telegram/SMTP/webhook delivery disabled until real
  external channel credentials are configured and tested. It performs normal
  and deep acceptance checks and, when the optional secondary offsite is
  enabled, synchronizes the new snapshot there before the final backup check.
- `configure-dual-s3-backup.sh --iam-ready` creates the encrypted configuration
  for Yandex Cloud primary plus Cloud.ru secondary and invokes the canonical
  backup installer. It prompts for credentials on `/dev/tty`; do not paste them
  into chat or put them on a command line.
- `repair-cloudru-backup-key.sh --iam-ready` replaces only the Cloud.ru key,
  first proving authentication and live bucket versioning without mutation.
- `cloudru-backup-bucket-policy.json.example` is the no-delete Cloud.ru policy
  template. Replace its three placeholders only in the provider console; never
  commit a rendered policy carrying account identifiers.
- `github-credential-helper.sh` supplies the token from the host-only root
  secret file to Git without putting it in a remote URL or command argument.

## Verified dual-S3 contract

The workflow was exercised end-to-end on 2026-09-07: local snapshot, restic
integrity check, immutable copies to both providers, and a single-file restore
drill all completed successfully.

- Yandex Cloud: bucket versioning enabled; dedicated bucket-scoped
  `storage.uploader` credential.
- Cloud.ru: the S3 access ID is the complete `tenant_id:key_id` (a dot separator
  is also accepted). Assign `s3e.editor`, `s3e.viewer`, and `s3e.viewer-acl` on
  the backup bucket, plus an explicit Bucket Policy Deny for
  `s3:DeleteObject` and `s3:DeleteBucket` for this service-account principal.
- Never assign the Cloud.ru backup account `s3e.admin`, `s3e.tenant.edit`, or
  project Administrator: those permissions bypass Bucket Policy.
- Both buckets must have versioning enabled before the installer writes data.

Final verification:

```bash
sudo /opt/corp-infra/backup/scripts/install-backup.sh --check --profile two-vps-split-b --offsite yandex-ru
sudo /opt/corp-infra/backup/scripts/backup.sh --check
sudo /opt/corp-infra/backup/scripts/test-restore.sh --check
```
