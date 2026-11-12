# ROLLBACK / RESTORE — return to a previously working install

Deployment is designed so recovery is always available and simple. `deploy.sh`
takes a timestamped snapshot of the current install into `/mnt/backups` **before**
it replaces anything, so you can always go back to exactly what was running.

## Fastest: restore the newest snapshot
```sh
sh /mnt/onvif/scripts/restore.sh list              # show snapshots in /mnt/backups
sh /mnt/onvif/scripts/restore.sh latest            # DRY-RUN plan (changes nothing)
sh /mnt/onvif/scripts/restore.sh latest --commit   # restore newest (asks YES)
```
`restore.sh` is hardened: it extracts the chosen snapshot to a staging dir,
validates it (structure, required files, and the archive's `.sha256` sidecar),
atomic-swaps it into `/mnt/onvif`, restarts the services, and **rolls the previous
install back if the restarted services are unhealthy** — `/mnt/onvif` is never
left missing. The replaced install is kept as `/mnt/onvif.prev-<ts>`.

Restore a specific snapshot (not just the newest):
```sh
sh /mnt/onvif/scripts/restore.sh onvif-20261110-… --commit   # a name from `restore.sh list`
```

## Make a snapshot yourself at any time
```sh
sh /mnt/onvif/scripts/backup.sh [label]            # -> /mnt/backups/onvif-<ts>[-label].tar
```
Backups live at the SD-card root (`/mnt/backups`), so replacing the `/mnt/onvif`
package never removes them.

## Always-safe last resort: reboot
A reboot restores the baseline: the SD autostart brings the package back up,
`speed_step` 600/600 (it is read-only and reset at boot), RTSP, ONVIF HTTP,
WS-Discovery and normal operation. Reboot only after confirming Telnet and the
autostart are intact.

## Restore must restore
The PTZ bridge, `speed_step` 600/600, exactly one daemon, ONVIF, RTSP,
WS-Discovery, and the normal autostart.

## Note on the old experimental revert script
`revert-to-stable.sh` from the earlier speed experiment assumes the experimental
package layout. For the current staged/promoted layout use `restore.sh`, which
knows the production path (`/mnt/onvif`) and the `/mnt/backups` snapshots. Do not
blindly reuse the old script.
