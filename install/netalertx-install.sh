#!/usr/bin/env bash

# License: MIT
# Source: https://github.com/netalertx/NetAlertX

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  nginx \
  php8.4-fpm \
  php8.4-cgi \
  php8.4-sqlite3 \
  php8.4-curl \
  sqlite3 \
  arp-scan \
  nmap \
  fping \
  nbtscan \
  traceroute \
  mtr-tiny \
  dnsutils \
  net-tools \
  iproute2 \
  snmp \
  avahi-daemon \
  avahi-utils \
  libwww-perl \
  wget \
  zip \
  cron \
  python3 \
  python3-dev \
  build-essential
msg_ok "Installed Dependencies"

setup_uv
fetch_and_deploy_gh_release "netalertx" "netalertx/NetAlertX" "tarball"

msg_info "Setting up Python environment"
$STD uv venv --python /usr/bin/python3 --clear /opt/netalertx-venv
$STD uv pip install --python /opt/netalertx-venv/bin/python -r /opt/netalertx/requirements.txt
msg_ok "Set up Python environment"

msg_info "Configuring NetAlertX"
# Frontend PHP hardcodes /app in a few places
ln -sfn /opt/netalertx /app
cat ~/.netalertx >/opt/netalertx/.VERSION
date +%s >/opt/netalertx/front/buildtimestamp.txt

mkdir -p /etc/netalertx
cat <<'EOF' >/etc/netalertx/netalertx.env
NETALERTX_APP=/opt/netalertx
NETALERTX_DATA=/opt/netalertx_data
NETALERTX_CONFIG=/opt/netalertx_data/config
NETALERTX_DB=/opt/netalertx_data/db
NETALERTX_TMP=/run/netalertx
NETALERTX_LOG=/run/netalertx/log
NETALERTX_PLUGINS_LOG=/run/netalertx/log/plugins
NETALERTX_API=/run/netalertx/api
VENDORSPATH=/opt/netalertx/back/ieee-oui.txt
VENDORSPATH_NEWEST=/opt/netalertx_data/ieee-oui.txt
SYSTEM_SERVICES_RUN_TMP=/opt/netalertx_data
LOG_EXECUTION_QUEUE=/run/netalertx/log/execution_queue.log
PORT=20211
PYTHONPATH=/opt/netalertx:/opt/netalertx/server:/opt/netalertx/server/plugins
PYTHONUNBUFFERED=1
PATH=/opt/netalertx-venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

# Runtime dirs (tmpfs under /run) + first-run config/DB. Runs as root before every start.
cat <<'EOF' >/usr/local/bin/netalertx-prepare
#!/usr/bin/env bash
set -euo pipefail
set -a
. /etc/netalertx/netalertx.env
set +a
install -d -o www-data -g www-data -m 0770 "$NETALERTX_TMP" "$NETALERTX_LOG" "$NETALERTX_PLUGINS_LOG" "$NETALERTX_API"
for f in app.log app_front.log app.php_errors.log execution_queue.log stderr.log stdout.log \
  db_is_locked.log IP_changes.log crond.log report_output.txt report_output.html report_output.json; do
  [[ -f "$NETALERTX_LOG/$f" ]] || install -o www-data -g www-data -m 0660 /dev/null "$NETALERTX_LOG/$f"
done
[[ -f "$NETALERTX_API/user_notifications.json" ]] || install -o www-data -g www-data -m 0660 /dev/null "$NETALERTX_API/user_notifications.json"
install -d -o www-data -g www-data -m 0770 "$NETALERTX_DATA" "$NETALERTX_CONFIG" "$NETALERTX_DB"
if [[ ! -f "$NETALERTX_CONFIG/app.conf" ]]; then
  install -o www-data -g www-data -m 0660 "$NETALERTX_APP/back/app.conf" "$NETALERTX_CONFIG/app.conf"
fi
if [[ ! -f "$NETALERTX_DB/app.db" ]]; then
  sqlite3 "$NETALERTX_DB/app.db" <"$NETALERTX_APP/server/db/schema/app.sql"
  chown www-data:www-data "$NETALERTX_DB/app.db"
  chmod 0660 "$NETALERTX_DB/app.db"
fi
EOF
chmod 0755 /usr/local/bin/netalertx-prepare
$STD /usr/local/bin/netalertx-prepare

# Scan every directly connected IPv4 subnet (one per LXC NIC / VLAN)
SCAN_LIST=$(ip -o -4 route show scope link proto kernel |
  awk '$3 !~ /^(lo|docker|veth)/ {printf "%s'\''%s --interface=%s'\''", sep, $1, $3; sep=","}')
[[ -z "$SCAN_LIST" ]] && SCAN_LIST="'--localnet'"
sed -i "s|^SCAN_SUBNETS=.*|SCAN_SUBNETS=[${SCAN_LIST}]|" /opt/netalertx_data/config/app.conf

# Web login (upstream default is OFF). Single password, no username; stored as SHA256.
NAX_PASS=$(random_password 20)
NAX_HASH=$(printf '%s' "$NAX_PASS" | sha256sum | cut -d' ' -f1)
sed -i '/^SETPWD_enable_password=/d;/^SETPWD_password=/d' /opt/netalertx_data/config/app.conf
printf "SETPWD_enable_password=True\nSETPWD_password='%s'\n" "$NAX_HASH" >>/opt/netalertx_data/config/app.conf
{
  echo "NetAlertX web login"
  echo "URL:      http://$(hostname -I | awk '{print $1}'):20211"
  echo "Password: ${NAX_PASS}"
} >~/netalertx.creds
chmod 600 ~/netalertx.creds
chown -R www-data:www-data /opt/netalertx /opt/netalertx_data
msg_ok "Configured NetAlertX"

msg_info "Configuring PHP-FPM"
{
  echo "[netalertx]"
  echo "user = www-data"
  echo "group = www-data"
  echo "listen = /run/php/netalertx.sock"
  echo "listen.owner = www-data"
  echo "listen.group = www-data"
  echo "pm = dynamic"
  echo "pm.max_children = 10"
  echo "pm.start_servers = 2"
  echo "pm.min_spare_servers = 1"
  echo "pm.max_spare_servers = 3"
  grep -E '^(NETALERTX_|PATH=)' /etc/netalertx/netalertx.env | sed -E 's/^([^=]+)=(.*)$/env[\1] = \2/'
  echo "php_admin_value[memory_limit] = 256M"
  echo "php_admin_value[upload_max_filesize] = 1M"
  echo "php_admin_value[post_max_size] = 1M"
} >/etc/php/8.4/fpm/pool.d/netalertx.conf
$STD systemctl restart php8.4-fpm
msg_ok "Configured PHP-FPM"

msg_info "Configuring NGINX"
cat <<'EOF' >/etc/nginx/sites-available/netalertx
# Same-origin enforcement for the backend proxy (mirrors upstream container config)
map "$http_referer|$http_host" $nax_sec_legacy {
    "~^https?://(?<ref_host>[^/:]+)(?::\d+)?/.*\|\k<ref_host>(?::\d+)?$" "TRUSTED";
    default "UNTRUSTED";
}
map $http_sec_fetch_site $nax_is_trusted {
    "same-origin" "TRUSTED";
    ""            $nax_sec_legacy;
    default       "UNTRUSTED";
}

server {
    listen 20211 default_server;
    server_name _;
    root /opt/netalertx/front;
    index index.php;
    large_client_header_buffers 4 16k;
    client_max_body_size 1m;
    server_tokens off;
    add_header X-Forwarded-Prefix "/app" always;

    location /server/ {
        if ($nax_is_trusted != "TRUSTED") {
            return 403;
        }
        rewrite ^/server/(.*)$ /$1 break;
        proxy_pass http://127.0.0.1:20212;
        proxy_buffering off;
        proxy_cache off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        client_max_body_size 50m;
        proxy_read_timeout 3600s;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ~* \.php$ {
        add_header Cache-Control "no-store";
        fastcgi_pass unix:/run/php/netalertx.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param SCRIPT_NAME $fastcgi_script_name;
        fastcgi_connect_timeout 75;
        fastcgi_send_timeout 600;
        fastcgi_read_timeout 600;
    }
}
EOF
nginx_enable_site netalertx
msg_ok "Configured NGINX"

msg_info "Creating Service"
cat <<'EOF' >/etc/systemd/system/netalertx.service
[Unit]
Description=NetAlertX backend
After=network-online.target php8.4-fpm.service nginx.service
Wants=network-online.target

[Service]
Type=simple
User=www-data
Group=www-data
EnvironmentFile=/etc/netalertx/netalertx.env
WorkingDirectory=/opt/netalertx
ExecStartPre=+/usr/local/bin/netalertx-prepare
ExecStart=/opt/netalertx-venv/bin/python -m server
# arp-scan / nmap / scapy plugins need raw sockets; inherited by child processes
AmbientCapabilities=CAP_NET_RAW CAP_NET_ADMIN CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Backend restart requests from the UI + IEEE OUI refresh (replaces upstream supercronic jobs)
cat <<'EOF' >/usr/local/bin/netalertx-cron
#!/usr/bin/env bash
Q=/run/netalertx/log/execution_queue.log
if [[ -f "$Q" ]] && grep -q cron_restart_backend "$Q"; then
  grep -v cron_restart_backend "$Q" >"$Q.tmp" || true
  cat "$Q.tmp" >"$Q"
  rm -f "$Q.tmp"
  systemctl restart netalertx
fi
EOF
chmod 0755 /usr/local/bin/netalertx-cron
cat <<'EOF' >/etc/cron.d/netalertx
SHELL=/bin/bash
* * * * * root /usr/local/bin/netalertx-cron
17 */6 * * * www-data set -a; . /etc/netalertx/netalertx.env; set +a; /opt/netalertx/install/production-filesystem/services/scripts/update_vendors.sh >/dev/null 2>&1
EOF
systemctl enable -q --now netalertx
msg_ok "Created Service"

msg_info "Updating IEEE vendor database"
$STD runuser -u www-data -- bash -c 'set -a; . /etc/netalertx/netalertx.env; set +a; /opt/netalertx/install/production-filesystem/services/scripts/update_vendors.sh' || msg_warn "Vendor DB update failed - bundled list will be used"
msg_ok "Updated IEEE vendor database"

motd_ssh
customize
cleanup_lxc
