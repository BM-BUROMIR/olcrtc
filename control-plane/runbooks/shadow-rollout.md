# Always-on shadow rollout

## Preconditions

- Use an always-on Linux host with stable non-RU egress for the dedicated Telemost account.
- Install the repository at `/opt/olc` from the reviewed fork commit.
- Put non-secret `managed-rotation.json` in `/etc/olc-control-plane/`.
- Provision mode-0600 credentials: `rotation.env`, `ssh_key`, `telemost.cookies`,
  `deployment.json`, `server-base.yaml`, `managed-wb-rotation.json`, `wb.bearer`, `wb.room`,
  `wb-server-base.yaml`, and pinned `known_hosts`.
- Configure runtime and shadow paths below `/var/lib/olc-control-plane`.

Do not copy credentials through command arguments, shell history, git, or journal output.

## Install

```bash
sudo install -m 0755 control-plane/run-systemd-rotation.sh /opt/olc/control-plane/
sudo install -m 0755 control-plane/run-systemd-wb-rotation.sh /opt/olc/control-plane/
sudo install -m 0644 control-plane/systemd/olc-control-plane-shadow.service /etc/systemd/system/
sudo install -m 0644 control-plane/systemd/olc-control-plane-shadow.timer /etc/systemd/system/
sudo install -m 0644 control-plane/systemd/olc-control-plane-wb.service /etc/systemd/system/
sudo install -m 0644 control-plane/systemd/olc-control-plane-wb.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now olc-control-plane-shadow.timer olc-control-plane-wb.timer
sudo systemctl start olc-control-plane-shadow.service
sudo systemctl start olc-control-plane-wb.service
```

## Stop/go checks

```bash
sudo systemctl status olc-control-plane-shadow.timer --no-pager
sudo systemctl status olc-control-plane-wb.timer --no-pager
sudo journalctl -u olc-control-plane-shadow.service -n 100 --no-pager
sudo journalctl -u olc-control-plane-wb.service -n 100 --no-pager
sudo sqlite3 /var/lib/olc-control-plane/control-plane.db +  'SELECT id, phase, fencing_token, last_error_code FROM operations ORDER BY created_at DESC LIMIT 10;'
```

Continue only when both rotations succeed, the matching shadow operations are `active`, no raw
provider response or credential appears in logs, and both timers survive a host reboot. Stop one
provider service and verify the other timer can still complete a run before declaring failure
isolation operational.

Force two overlapping service starts and confirm one receives `LeaseBusy` or a stale-fence rejection
without changing the active manifest. Stop the timer immediately if shadow generation/hash differs
from the successful legacy envelope.

## Backup check

Run `backup_state.py backup` after each successful shadow rotation. Restore the backup to an isolated
path with independently signed epoch and revocation documents and verify the restore event before
production cutover.

## Rollback

```bash
sudo systemctl disable --now olc-control-plane-shadow.timer olc-control-plane-wb.timer
sudo systemctl stop olc-control-plane-shadow.service olc-control-plane-wb.service
```

Shadow objects and SQLite state are retained for diagnosis. Legacy profile delivery and the active
edge configuration are not changed by disabling shadow mode.
