#!/usr/bin/env bash
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# License: MIT
# Source: https://github.com/netalertx/NetAlertX
#
# Run on the PVE host (scripts root must point at YOUR repo, not upstream):
#   COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/<owner>/<repo>/main \
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/ct/netalertx.sh)"
# Update: run `update` inside the LXC (or re-run the line above inside it).

APP="NetAlertX"
var_tags="${var_tags:-network;monitoring}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-6}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-no}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/netalertx ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "netalertx" "netalertx/NetAlertX"; then
    setup_uv

    msg_info "Stopping Service"
    systemctl stop netalertx
    msg_ok "Stopped Service"

    # Config + DB live in /opt/netalertx_data, venv in /opt/netalertx-venv:
    # the app dir can be wiped and redeployed safely.
    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "netalertx" "netalertx/NetAlertX" "tarball"

    msg_info "Updating ${APP}"
    $STD uv pip install --python /opt/netalertx-venv/bin/python -r /opt/netalertx/requirements.txt
    cat ~/.netalertx >/opt/netalertx/.VERSION
    date +%s >/opt/netalertx/front/buildtimestamp.txt
    chown -R www-data:www-data /opt/netalertx
    msg_ok "Updated ${APP}"

    msg_info "Starting Service"
    systemctl start netalertx
    systemctl reload nginx
    msg_ok "Started Service"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:20211${CL}"
echo -e "${INFO}${YW}Login password: cat ~/netalertx.creds (inside the LXC)${CL}"
