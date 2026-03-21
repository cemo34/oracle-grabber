# Host ARM Hunter (Self-Cleaning)

This package runs Oracle ARM capacity hunting directly on an existing Oracle host.
It avoids GitHub runner re-install overhead and can remove itself after success.

## Files
- `arm_hunter.py`: launch logic (all ADs, retryable error handling)
- `arm-hunter.service`: oneshot systemd unit
- `arm-hunter.timer`: runs every minute
- `install_hunter.sh`: install and enable timer
- `cleanup_hunter.sh`: stop units and delete `/opt/arm-hunter`
- `arm-hunter.env.example`: runtime settings

## Install on Oracle host
1. Clone/pull this repo on host.
2. Prepare OCI credentials:
   - `/opt/arm-hunter/config`
   - `/opt/arm-hunter/oci_api_key.pem`
3. Run as root:
   - `cd host-hunter`
   - `sudo ./install_hunter.sh`
4. Edit `/etc/arm-hunter.env` if needed.
5. Verify:
   - `systemctl status arm-hunter.timer --no-pager`
   - `journalctl -u arm-hunter.service -f`

## Behavior
- Every minute, tries launch across all ADs.
- If ARM instance already exists or launch succeeds:
  - stops/disables timer+service
  - removes systemd units
  - removes `/opt/arm-hunter` (async)

## Manual cleanup
- `sudo /opt/arm-hunter/cleanup_hunter.sh --success`
