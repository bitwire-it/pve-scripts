# pve-scripts

LXC installers for Proxmox VE built on the [community-scripts](https://community-scripts.org/docs/ct/detailed_guide) engine.
They use the same menu, defaults, and `update` command as the official scripts, but are served from this repo.

## Layout

```
ct/<app>.sh               # runs on the PVE host: LXC specs, creates the container, update logic
install/<app>-install.sh  # runs inside the new LXC: installs and configures the app
```

`<app>` is `APP` from the ct script, lowercased with spaces removed (`APP="NetAlertX"` → `netalertx`).

## Usage

```bash
# on the PVE host
export COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/bitwire-it/pve-scripts/main
bash -c "$(curl -fsSL $COMMUNITY_SCRIPTS_URL/ct/<app>.sh)"

# inside the LXC, to upgrade
update
```

- `COMMUNITY_SCRIPTS_URL` is mandatory. Without it the engine looks for the install script in the upstream repo and fails with exit 115.
- The URL is saved into `/usr/bin/update` in the LXC, so updates also come from this repo.
- The repo must stay **public** (raw URLs, no token).

---

## Scripts

### NetAlertX

Network discovery and new-device alerts. Upstream: <https://github.com/netalertx/NetAlertX>

| | |
|---|---|
| Defaults | Debian 13, unprivileged, 2 vCPU, 1 GB RAM, 6 GB disk |
| URL | `http://<ip>:20211` |
| Service | `netalertx.service`, which runs the backend as www-data (python, :20212 local only), plus nginx and php8.4-fpm |

**Install steps** (`install/netalertx-install.sh`)
1. Install apt packages: nginx, php8.4-fpm/sqlite3/curl, arp-scan, nmap, fping, nbtscan, snmp, avahi, sqlite3, python3, build-essential, cron
2. `setup_uv`, then `fetch_and_deploy_gh_release` puts the latest GitHub release in `/opt/netalertx`. The version is recorded in `~/.netalertx` and `/opt/netalertx/.VERSION`.
3. Create the Python venv `/opt/netalertx-venv` (system python3) and install `requirements.txt`
4. Symlink `/app` → `/opt/netalertx` (the PHP frontend hardcodes `/app`)
5. Write the env file `/etc/netalertx/netalertx.env` with paths, `PYTHONPATH` and `PATH`
6. Create `/usr/local/bin/netalertx-prepare`, which runs as root before every service start:
   - creates `/run/netalertx/{log,api}` (tmpfs, rebuilt on each boot)
   - on first run only, copies `back/app.conf` to `/opt/netalertx_data/config/` and builds the DB from `server/db/schema/app.sql`
7. Set `SCAN_SUBNETS` to every IPv4 subnet the LXC's NICs are on at install time. Turn on the web login (`SETPWD_enable_password=True`) with a random password, stored in `app.conf` as a SHA256 hash. The plain password is saved in `/root/netalertx.creds`.
8. Create a PHP-FPM pool `/etc/php/8.4/fpm/pool.d/netalertx.conf` (socket `/run/php/netalertx.sock`, env passed through)
9. Create the nginx site `/etc/nginx/sites-available/netalertx`: :20211, `/server/` proxied to :20212 with a same-origin check, PHP via the pool
10. Create the systemd unit `netalertx.service` with `AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN`
11. Create `/etc/cron.d/netalertx`:
    - every minute, `netalertx-cron` restarts the backend when the UI asks for it
    - every 6 h, the IEEE OUI vendor database is refreshed
12. Do the first vendor DB update, then the standard `motd_ssh`, `customize` and `cleanup_lxc`

**Upgrade method** (`update_script()` in `ct/netalertx.sh`)
1. `check_for_gh_release` compares the latest release with `~/.netalertx` and stops if they match
2. Stop `netalertx`
3. `CLEAN_INSTALL=1 fetch_and_deploy_gh_release` wipes and redeploys `/opt/netalertx`
4. `uv pip install -r requirements.txt` into the existing venv
5. Rewrite `.VERSION` and `buildtimestamp.txt`, then `chown -R www-data /opt/netalertx`
6. Start `netalertx` and reload nginx

**Kept across upgrades:** `/opt/netalertx_data` (config, DB, OUI file), `/opt/netalertx-venv`, `/etc/netalertx/`, the nginx/php/systemd/cron files.
**Not touched by upgrades:** if a release changes paths or env vars, edit `/etc/netalertx/netalertx.env` or `netalertx-prepare` by hand.

**Notes**
- Multiple VLANs: add one NIC per VLAN, then extend `SCAN_SUBNETS` in Settings:
  ```bash
  pct set <id> -net1 name=eth1,bridge=vmbr0,tag=20,ip=10.20.0.5/24
  ```
  Then add `'10.20.0.0/24 --interface=eth1'`.
- Whitelist the LXC's IP in the firewall's scan detection and with the MDR/SOC. arp-scan and nmap will trigger alerts.
- Logs: `journalctl -u netalertx`, `/run/netalertx/log/app.log`
- Login: one password, no username. Change it in Settings → Set Password, or from the CLI:
  ```bash
  H=$(printf '%s' 'NewPass' | sha256sum | cut -d' ' -f1)
  sed -i "s|^SETPWD_password=.*|SETPWD_password='$H'|" /opt/netalertx_data/config/app.conf
  ```
  Locked out? Set `SETPWD_enable_password=False` in the same file.
- The backend API on :20212 listens on all interfaces but requires `API_TOKEN` (Bearer). For extra hardening, allow only :20211 in the Proxmox firewall for the LXC.

---

## Adding a new script

1. Copy `ct/netalertx.sh` to `ct/<app>.sh`, then set `APP`, the `var_*` defaults, `update_script()` and the URL echo at the end.
2. Create `install/<app>-install.sh`. Keep the header block (`source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"` … `update_os`) and the footer (`motd_ssh`, `customize`, `cleanup_lxc`).
3. Keep data out of `/opt/<app>` so that `CLEAN_INSTALL=1` can safely wipe the app dir on update.
4. Run `bash -n` on both files, then test-install on a lab PVE. Add a section above using the same three parts: **Install steps**, **Upgrade method**, **Notes**.
