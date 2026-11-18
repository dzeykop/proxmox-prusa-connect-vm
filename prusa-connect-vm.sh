#!/usr/bin/env bash
# =============================================================================
#  Prusa Connect Local – Proxmox VM installer
#  Version: 1.0.0
#  Author:  JFFK (github.com/dzeykop)
#  Repo:    https://github.com/dzeykop/proxmox-prusa-connect
#
#  Creates a Debian 13 VM (cloud image + cloud-init) on Proxmox VE and
#  installs Prusa Connect Local (binary + systemd service) inside it.
#
#  Run on the Proxmox host as root:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/dzeykop/proxmox-prusa-connect/main/prusa-connect-vm.sh)"
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
APP_NAME="Prusa Connect Local"
GH_REPO="prusa3d/prusa-connect"
ASSET_NAME="prusa_connect_amd64"
APP_DIR="/opt/prusa-connect"
APP_USER="prusa-connect"
APP_PORT="8080"
VM_USER="jffk"
IMG_BASE="https://cloud.debian.org/images/cloud/trixie/latest"
IMG_NAME="debian-13-genericcloud-amd64.qcow2"
TITLE="Prusa Connect Local VM Installer v${SCRIPT_VERSION}"

# Recommended / minimum values
REC_CORES=1;   MIN_CORES=1
REC_RAM=1024;  MIN_RAM=512      # MB
REC_DISK=10;   MIN_DISK=8       # GB (G-code files are stored here)

# State for rollback
VM_CREATED=0
INSTALL_DONE=0
VMID=""
SNIPPET_PATH=""
TMP_DIR="$(mktemp -d)"

# ---------- output helpers ----------------------------------------------------
GN="\e[32m"; YW="\e[33m"; RD="\e[31m"; BL="\e[36m"; CL="\e[0m"; BD="\e[1m"
msg_info() { echo -e " ${BL}[INFO]${CL} $*"; }
msg_ok()   { echo -e " ${GN}[ OK ]${CL} $*"; }
msg_warn() { echo -e " ${YW}[WARN]${CL} $*"; }
msg_err()  { echo -e " ${RD}[FAIL]${CL} $*" >&2; }
die()      { msg_err "$*"; exit 1; }

cleanup() {
  local rc=$?
  rm -rf "$TMP_DIR"
  if [[ $rc -ne 0 && $VM_CREATED -eq 1 && $INSTALL_DONE -eq 0 && -n "$VMID" ]]; then
    msg_warn "[ROLLBACK] Installation failed – removing unfinished VM ${VMID}"
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --purge >/dev/null 2>&1 || true
    [[ -n "$SNIPPET_PATH" ]] && rm -f "$SNIPPET_PATH"
    msg_ok "[ROLLBACK] VM ${VMID} removed"
  fi
}
trap cleanup EXIT
trap 'msg_err "Error in line $LINENO: $BASH_COMMAND"' ERR

cancelled() { echo; msg_warn "Cancelled by user – nothing was changed."; exit 0; }

# ---------- 1. pre-flight checks ------------------------------------------------
clear
echo -e "${BD}${TITLE}${CL}\n"

[[ $EUID -eq 0 ]] || die "Please run this script as root."
command -v qm >/dev/null && command -v pveversion >/dev/null \
  || die "This script must run on a Proxmox VE host."
command -v whiptail >/dev/null || die "whiptail not found."
msg_ok "Proxmox VE detected: $(pveversion | cut -d/ -f2)"

[[ "$(dpkg --print-architecture)" == "amd64" ]] \
  || die "Only amd64 (Intel/AMD) Proxmox hosts are supported."

msg_info "Checking internet connection..."
curl -fsS --max-time 10 -o /dev/null https://api.github.com \
  || die "No internet connection (api.github.com not reachable)."
msg_ok "Internet connection OK"

whiptail --title "$TITLE" --yesno \
"This will create a new Debian 13 VM with ${APP_NAME}.\n\nTip: an LXC container (prusa-connect-lxc.sh) needs fewer resources.\n\nProceed with a VM?" 12 66 \
  || cancelled

# ---------- 2. host resources -------------------------------------------------
HOST_CORES=$(nproc)
HOST_RAM_FREE=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)

# ---------- 3. settings ---------------------------------------------------------
NEXT_ID=$(pvesh get /cluster/nextid)
VMID=$(whiptail --title "$TITLE" --inputbox "VM ID:" 9 60 "$NEXT_ID" 3>&1 1>&2 2>&3) || cancelled
[[ "$VMID" =~ ^[0-9]+$ ]] || die "Invalid VM ID."
if qm status "$VMID" >/dev/null 2>&1 || pct status "$VMID" >/dev/null 2>&1; then
  die "ID ${VMID} is already in use."
fi

VM_NAME=$(whiptail --title "$TITLE" --inputbox "VM name / hostname:" 9 60 "prusa-connect" 3>&1 1>&2 2>&3) || cancelled
[[ "$VM_NAME" =~ ^[a-zA-Z0-9-]+$ ]] || die "Invalid name."

ask_number() { # $1 label $2 rec $3 min $4 max $5 unit
  local val
  val=$(whiptail --title "$TITLE" --inputbox \
"$1\n\nRecommended: $2 $5   Minimum: $3 $5   Host available: $4 $5" 11 66 "$2" 3>&1 1>&2 2>&3) || cancelled
  [[ "$val" =~ ^[0-9]+$ ]] || die "Invalid number for $1."
  if (( val < $3 )); then die "$1 below minimum ($3 $5)."; fi
  if (( val > $4 )); then
    whiptail --title "$TITLE" --defaultno --yesno "$1 ($val $5) exceeds available host resources ($4 $5).\nContinue anyway?" 10 64 || cancelled
  fi
  echo "$val"
}
CORES=$(ask_number "CPU cores" "$REC_CORES" "$MIN_CORES" "$HOST_CORES" "")
RAM=$(ask_number "RAM" "$REC_RAM" "$MIN_RAM" "$HOST_RAM_FREE" "MB")

# storage for the VM disk
mapfile -t STORAGES < <(pvesm status -content images 2>/dev/null | awk 'NR>1 && $3=="active" {printf "%s %d\n", $1, $6/1024/1024}')
(( ${#STORAGES[@]} )) || die "No active storage for VM disks found."
MENU=(); for s in "${STORAGES[@]}"; do MENU+=("${s%% *}" "free: ${s##* } GB"); done
VM_STORAGE=$(whiptail --title "$TITLE" --menu "Storage for the VM disk:" 15 60 6 "${MENU[@]}" 3>&1 1>&2 2>&3) || cancelled
STORAGE_FREE=$(printf '%s\n' "${STORAGES[@]}" | awk -v s="$VM_STORAGE" '$1==s {print $2}')
DISK=$(ask_number "Disk size" "$REC_DISK" "$MIN_DISK" "$STORAGE_FREE" "GB")

# network bridge
mapfile -t BRIDGES < <(ip -o link show type bridge | awk -F': ' '{print $2}' | grep '^vmbr' || true)
(( ${#BRIDGES[@]} )) || die "No vmbr bridge found."
MENU=(); for b in "${BRIDGES[@]}"; do MENU+=("$b" ""); done
BRIDGE=$(whiptail --title "$TITLE" --menu "Network bridge:" 14 60 5 "${MENU[@]}" 3>&1 1>&2 2>&3) || cancelled

# IP configuration
STATIC_IP=""
if whiptail --title "$TITLE" --yes-button "DHCP" --no-button "Static" --yesno \
"IP address configuration:\n\nTip: a static IP (or a DHCP reservation in your router) keeps the web address stable." 11 66; then
  NET_IP="dhcp"; IPCFG="ip=dhcp"
else
  NET_IP=$(whiptail --title "$TITLE" --inputbox "Static IP with CIDR (e.g. 192.168.20.50/24):" 9 60 3>&1 1>&2 2>&3) || cancelled
  [[ "$NET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "Invalid IP/CIDR."
  NET_GW=$(whiptail --title "$TITLE" --inputbox "Gateway (e.g. 192.168.20.1):" 9 60 3>&1 1>&2 2>&3) || cancelled
  [[ "$NET_GW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid gateway."
  IPCFG="ip=${NET_IP},gw=${NET_GW}"
  STATIC_IP="${NET_IP%/*}"
fi

# login password for SSH into the VM
while true; do
  PW1=$(whiptail --title "$TITLE" --passwordbox "Password for VM user '${VM_USER}' (SSH login, min. 8 characters):" 10 66 3>&1 1>&2 2>&3) || cancelled
  PW2=$(whiptail --title "$TITLE" --passwordbox "Repeat password:" 9 60 3>&1 1>&2 2>&3) || cancelled
  if [[ "$PW1" != "$PW2" ]]; then whiptail --title "$TITLE" --msgbox "Passwords do not match." 8 50
  elif (( ${#PW1} < 8 )); then whiptail --title "$TITLE" --msgbox "Password too short (min. 8)." 8 50
  else break; fi
done
PW_HASH=$(openssl passwd -6 "$PW1"); unset PW1 PW2

# storage for the cloud-init snippet
SNIP_STORE=$(pvesm status -content snippets 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
if [[ -z "$SNIP_STORE" ]]; then
  whiptail --title "$TITLE" --yesno \
"No storage allows 'snippets' (needed for cloud-init).\n\nEnable 'snippets' on storage 'local'? Existing content types are kept." 11 66 || cancelled
  CUR_CONTENT=$(pvesh get /storage/local --output-format json | perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>)->{content}')
  pvesm set local --content "${CUR_CONTENT},snippets" || die "Could not enable snippets on 'local'."
  SNIP_STORE="local"
  msg_ok "Snippets enabled on storage 'local'"
fi

# summary
whiptail --title "$TITLE" --yesno \
"Summary:\n
  VM ID:       ${VMID}
  Name:        ${VM_NAME}
  OS:          Debian 13 (cloud image)
  CPU cores:   ${CORES}
  RAM:         ${RAM} MB
  Disk:        ${DISK} GB on ${VM_STORAGE}
  Bridge:      ${BRIDGE}
  IP:          ${NET_IP}
  SSH user:    ${VM_USER}
  Start at boot: yes\n
Create the VM now?" 21 64 || cancelled

# ---------- 4. find the newest Prusa Connect release ----------------------------
msg_info "Looking up the newest ${APP_NAME} release..."
curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases?per_page=10" -o "$TMP_DIR/releases.json" \
  || die "Could not read releases from GitHub."
read -r REL_TAG ASSET_URL ASSET_DIGEST < <(perl -MJSON::PP -e '
  local $/; my $r = decode_json(<STDIN>);
  for my $rel (@$r) {
    next if $rel->{draft};
    for my $a (@{$rel->{assets}}) {
      if ($a->{name} eq $ARGV[0]) {
        print join(" ", $rel->{tag_name}, $a->{browser_download_url}, ($a->{digest} // "none")), "\n";
        exit 0;
      }
    }
  }' "$ASSET_NAME" < "$TMP_DIR/releases.json") || true
[[ -n "${ASSET_URL:-}" ]] || die "Release file ${ASSET_NAME} not found on GitHub."
msg_ok "Found release ${REL_TAG}"
SHA_CHECK=""
if [[ "$ASSET_DIGEST" == sha256:* ]]; then
  SHA_CHECK="${ASSET_DIGEST#sha256:}"
else
  msg_warn "No checksum published by GitHub – verification inside the VM will be skipped"
fi

# ---------- 5. Debian cloud image -----------------------------------------------
msg_info "Downloading Debian 13 cloud image (about 400 MB)..."
curl -fsSL "${IMG_BASE}/${IMG_NAME}" -o "$TMP_DIR/$IMG_NAME" || die "Image download failed."
curl -fsSL "${IMG_BASE}/SHA512SUMS" -o "$TMP_DIR/SHA512SUMS" || die "Checksum list download failed."
( cd "$TMP_DIR" && grep " ${IMG_NAME}\$" SHA512SUMS | sha512sum -c --status ) \
  || die "Checksum mismatch – image damaged. Nothing was installed."
msg_ok "Image verified (SHA512)"

# ---------- 6. cloud-init user-data ---------------------------------------------
SNIPPET_FILE="prusa-connect-${VMID}.yaml"
SNIPPET_PATH=$(pvesm path "${SNIP_STORE}:snippets/${SNIPPET_FILE}")
mkdir -p "$(dirname "$SNIPPET_PATH")"
cat > "$SNIPPET_PATH" <<EOF
#cloud-config
hostname: ${VM_NAME}
timezone: Europe/Vienna
ssh_pwauth: true
users:
  - name: ${VM_USER}
    groups: [sudo]
    shell: /bin/bash
    lock_passwd: false
    passwd: '${PW_HASH}'
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - curl
  - ca-certificates
write_files:
  - path: /etc/systemd/system/prusa-connect.service
    content: |
      [Unit]
      Description=Prusa Connect Local
      After=network-online.target
      Wants=network-online.target

      [Service]
      User=${APP_USER}
      Group=${APP_USER}
      WorkingDirectory=${APP_DIR}
      ExecStart=${APP_DIR}/prusa_connect
      Restart=on-failure
      RestartSec=5
      # allows the time server on UDP port 123 (below 1024)
      AmbientCapabilities=CAP_NET_BIND_SERVICE

      [Install]
      WantedBy=multi-user.target
runcmd:
  - systemctl enable --now qemu-guest-agent
  - useradd --system --home ${APP_DIR} --shell /usr/sbin/nologin ${APP_USER}
  - mkdir -p ${APP_DIR}
  - curl -fsSL '${ASSET_URL}' -o ${APP_DIR}/prusa_connect
  - [ sh, -c, 'if [ -n "${SHA_CHECK}" ]; then echo "${SHA_CHECK}  ${APP_DIR}/prusa_connect" | sha256sum -c || { rm -f ${APP_DIR}/prusa_connect; exit 1; }; fi' ]
  - chmod 0755 ${APP_DIR}/prusa_connect
  - echo '${REL_TAG}' > ${APP_DIR}/VERSION
  - chown -R ${APP_USER}:${APP_USER} ${APP_DIR}
  - systemctl daemon-reload
  - systemctl enable --now prusa-connect
EOF
chmod 600 "$SNIPPET_PATH"
msg_ok "cloud-init configuration written"

# ---------- 7. create VM --------------------------------------------------------
msg_info "Creating VM ${VMID}..."
DESCRIPTION="<h3>${APP_NAME}</h3><p>Installed with proxmox-prusa-connect (VM) v${SCRIPT_VERSION}<br>Release: ${REL_TAG}<br>Web UI: port ${APP_PORT}<br>SSH user: ${VM_USER}</p><p>from JFFK</p>"
qm create "$VMID" --name "$VM_NAME" \
  --cores "$CORES" --memory "$RAM" --cpu host \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-single --ostype l26 \
  --agent enabled=1 --serial0 socket --vga serial0 \
  --onboot 1 --tags "prusa;3d-printing" \
  --description "$DESCRIPTION" >/dev/null
VM_CREATED=1
qm set "$VMID" --scsi0 "${VM_STORAGE}:0,import-from=${TMP_DIR}/${IMG_NAME},discard=on" >/dev/null
qm resize "$VMID" scsi0 "${DISK}G" >/dev/null
qm set "$VMID" --ide2 "${VM_STORAGE}:cloudinit" --boot order=scsi0 \
  --ipconfig0 "$IPCFG" \
  --cicustom "user=${SNIP_STORE}:snippets/${SNIPPET_FILE}" >/dev/null
msg_ok "VM ${VMID} created"

qm start "$VMID"
INSTALL_DONE=1   # from here on the VM is never removed automatically
msg_ok "VM started – cloud-init is installing (first boot takes 3–8 minutes)"

# ---------- 8. reachability + setup code ---------------------------------------
msg_info "Waiting for the guest agent..."
VM_IP="$STATIC_IP"
for _ in $(seq 1 120); do
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    if [[ -z "$VM_IP" ]]; then
      VM_IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | perl -MJSON::PP -e '
        local $/; my $j = decode_json(<STDIN>);
        for my $i (@$j) { next if $i->{name} eq "lo";
          for my $a (@{$i->{"ip-addresses"} || []}) {
            if ($a->{"ip-address-type"} eq "ipv4") { print $a->{"ip-address"}; exit } } }' || true)
    fi
    [[ -n "$VM_IP" ]] && break
  fi
  sleep 5
done
[[ -n "$VM_IP" ]] && msg_ok "VM IP: ${VM_IP}" || msg_warn "Could not detect the VM IP yet"

UP=0
if [[ -n "$VM_IP" ]]; then
  msg_info "Waiting for the web interface on port ${APP_PORT}..."
  for _ in $(seq 1 120); do
    if curl -fs -o /dev/null --max-time 3 "http://${VM_IP}:${APP_PORT}"; then UP=1; break; fi
    sleep 5
  done
fi

SETUP_LINE=""
if (( UP )); then
  SETUP_LINE=$(qm guest exec "$VMID" -- journalctl -u prusa-connect --no-pager -o cat 2>/dev/null \
    | perl -MJSON::PP -e 'local $/; my $j = eval { decode_json(<STDIN>) } || {}; print $j->{"out-data"} // ""' \
    | grep -i -m1 'setup' || true)
fi

echo
echo -e "${GN}${BD}==============================================================${CL}"
if (( UP )); then
  echo -e "${GN}${BD}  ${APP_NAME} is running!${CL}"
else
  msg_warn "Web interface did not answer yet – cloud-init may still be working."
  echo "        Check in the VM: journalctl -u prusa-connect   /   cloud-init status"
fi
echo -e "${GN}${BD}==============================================================${CL}"
echo -e "  Web UI:      ${BD}http://${VM_IP:-<vm-ip>}:${APP_PORT}${CL}"
echo -e "  VM:          ${VMID} (${VM_NAME})"
echo -e "  SSH:         ssh ${VM_USER}@${VM_IP:-<vm-ip>}"
echo -e "  Release:     ${REL_TAG}"
if [[ -n "$SETUP_LINE" ]]; then
  echo -e "  Setup code:  ${BD}${SETUP_LINE}${CL}"
else
  echo -e "  Setup code:  not found – show it in the VM with:"
  echo -e "               sudo journalctl -u prusa-connect --no-pager"
fi
echo
echo "  Next steps:"
echo "   1. Open the Web UI and enter the setup code in the wizard"
echo "   2. Create the admin account"
echo "   3. Add your printer (settings file via USB, firmware 6.4.0 or newer)"
echo
echo -e "  ${YW}Note:${CL} ${APP_NAME} is still beta (0.x). Take a Proxmox snapshot"
echo "        before every update: qm snapshot ${VMID} before-update"
echo
echo "  from JFFK"
