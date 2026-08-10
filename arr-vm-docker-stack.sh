#!/usr/bin/env bash

set -eEo pipefail

SCRIPT_NAME="$(basename "$0")"
WORK_DIR="${WORK_DIR:-/var/lib/arr-vm-docker-stack}"
IMAGE_URL="${IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2}"
IMAGE_FILE="${IMAGE_FILE:-${WORK_DIR}/debian-13-generic-amd64.qcow2}"
PROVISION_KEY="${PROVISION_KEY:-${WORK_DIR}/arr-vm-provision}"
SUMMARY_FILE="${SUMMARY_FILE:-${WORK_DIR}/summary.txt}"
BACKTITLE="${BACKTITLE:-Proxmox VE Helper Scripts - ARR VM Docker Stack}"
SSH_WAIT_TIMEOUT="${SSH_WAIT_TIMEOUT:-1200}"

ACTION="${ACTION:-full}"
VMID="${VMID:-}"
VM_NAME="${VM_NAME:-arr-docker}"
VM_STORAGE="${VM_STORAGE:-}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_CORES="${VM_CORES:-2}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_DISK_SIZE="${VM_DISK_SIZE:-64G}"
VM_USER="${VM_USER:-arradmin}"
VM_PASSWORD="${VM_PASSWORD:-}"
VM_IP_MODE="${VM_IP_MODE:-dhcp}"
VM_IP="${VM_IP:-}"
VM_GATEWAY="${VM_GATEWAY:-}"
VM_CIDR="${VM_CIDR:-24}"
ARR_TZ="${ARR_TZ:-America/Sao_Paulo}"

SSH_CONNECT_IP=""
UI_BIN=""

msg() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }
cancelled() { die "Cancelled at ${1}."; }

header_info() {
  clear
  cat <<"EOF"
                         _      __     __ __  __
   __ _ _ __ _ __       / \     \ \   / /|  \/  |
  / _` | '__| '__|____ / _ \ ____\ \ / / | |\/| |
 | (_| | |  | | |_____/ ___ \_____\ V /  | |  | |
  \__,_|_|  |_|      /_/   \_\     \_/   |_|  |_|

EOF
}

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME}

Environment overrides:
  ACTION=full|bootstrap
  VMID=120
  VM_NAME=arr-docker
  VM_STORAGE=local-lvm
  VM_BRIDGE=vmbr0
  VM_CORES=2
  VM_MEMORY=4096
  VM_DISK_SIZE=64G
  VM_USER=arradmin
  VM_PASSWORD='strong-password'
  VM_IP_MODE=dhcp|static
  VM_IP=192.168.1.50
  VM_GATEWAY=192.168.1.1
  VM_CIDR=24
  ARR_TZ=America/Sao_Paulo
  SSH_WAIT_TIMEOUT=1200
  IMAGE_URL=${IMAGE_URL}
EOF
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root on a Proxmox VE node."
}

require_commands() {
  local missing=()
  local cmd
  for cmd in awk curl qm pvesm ssh ssh-keygen; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "Missing required commands: ${missing[*]}"
}

ensure_ui() {
  [[ -t 0 && -t 2 ]] || return 0

  if command -v whiptail >/dev/null 2>&1; then
    UI_BIN="$(command -v whiptail)"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    msg "Installing whiptail for the interactive setup menu"
    apt-get update
    apt-get install -y whiptail
  fi

  if command -v whiptail >/dev/null 2>&1; then
    UI_BIN="$(command -v whiptail)"
  else
    warn "whiptail is not available; falling back to text prompts."
  fi
}

is_valid_ipv4() {
  local ip=$1
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  ((a <= 255 && b <= 255 && c <= 255 && d <= 255))
}

prompt_default() {
  local prompt=$1 default=$2 value
  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

prompt_secret() {
  local prompt=$1 value
  read -r -s -p "${prompt}: " value
  printf '\n' >&2
  printf '%s' "$value"
}

use_ui() {
  [[ -n "$UI_BIN" && -t 0 && -t 2 ]]
}

ui_input() {
  local title=$1 prompt=$2 default=$3
  if use_ui; then
    "$UI_BIN" --backtitle "$BACKTITLE" \
      --title "$title" \
      --inputbox "$prompt" 10 70 "$default" \
      3>&1 1>&2 2>&3 || cancelled "$title"
  else
    prompt_default "$prompt" "$default"
  fi
}

ui_password() {
  local title=$1 prompt=$2
  if use_ui; then
    "$UI_BIN" --backtitle "$BACKTITLE" \
      --title "$title" \
      --passwordbox "$prompt" 10 70 \
      3>&1 1>&2 2>&3 || cancelled "$title"
  else
    prompt_secret "$prompt"
  fi
}

ui_menu() {
  local title=$1 prompt=$2 default=$3
  shift 3
  if use_ui; then
    "$UI_BIN" --backtitle "$BACKTITLE" \
      --title "$title" \
      --default-item "$default" \
      --menu "$prompt" 16 70 8 "$@" \
      3>&1 1>&2 2>&3 || cancelled "$title"
  else
    local tag desc
    printf '%s\n' "$prompt" >&2
    while (($# > 0)); do
      tag=$1
      desc=$2
      shift 2
      printf '  - %s %s\n' "$tag" "$desc" >&2
    done
    prompt_default "$title" "$default"
  fi
}

ui_msgbox() {
  local title=$1 message=$2
  if use_ui; then
    "$UI_BIN" --backtitle "$BACKTITLE" \
      --title "$title" \
      --msgbox "$message" 12 70 || cancelled "$title"
  else
    printf '%s\n\n%s\n' "$title" "$message" >&2
  fi
}

ui_confirm() {
  local title=$1 message=$2
  if use_ui; then
    "$UI_BIN" --backtitle "$BACKTITLE" \
      --title "$title" \
      --yesno "$message" 22 78 || cancelled "$title"
  else
    local value
    read -r -p "${message} [y/N]: " value
    [[ "$value" =~ ^[Yy]$ ]] || cancelled "$title"
  fi
}

next_vmid() {
  qm list 2>/dev/null | awk 'NR > 1 {print $1}' | sort -n | awk 'BEGIN {id=120} $1 >= id {id=$1+1} END {print id}'
}

storage_options() {
  pvesm status -content images 2>/dev/null | awk 'NR > 1 {print $1}'
}

bridge_options() {
  awk '/^iface vmbr/ {print $2}' /etc/network/interfaces 2>/dev/null
}

confirm_configuration() {
  local body
  if [[ "$ACTION" == "bootstrap" ]]; then
    body=$(cat <<EOF
Mode:      bootstrap
VMID:      ${VMID}
User:      ${VM_USER}
IP:        ${SSH_CONNECT_IP}
Timezone:  ${ARR_TZ}

The script will connect to the existing VM and resume Docker/ARR provisioning.
EOF
)
  else
    body=$(cat <<EOF
Mode:      full
VMID:      ${VMID}
Name:      ${VM_NAME}
CPU:       ${VM_CORES} cores
Memory:    ${VM_MEMORY} MB
Disk:      ${VM_DISK_SIZE}
Storage:   ${VM_STORAGE}
Bridge:    ${VM_BRIDGE}
Network:   ${VM_IP_MODE}
IP:        ${SSH_CONNECT_IP}
User:      ${VM_USER}
Timezone:  ${ARR_TZ}

The script will create the VM, start it, and install the Docker ARR stack.
EOF
)
  fi

  ui_confirm "Confirm Settings" "$body"
}

collect_inputs() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  ui_msgbox "ARR VM Docker Stack" \
    "This script creates or bootstraps a Debian VM for the ARR stack.

Use the arrow keys to move, Space to select, Tab to switch buttons, and Enter to confirm."

  local default_vmid
  default_vmid="$(next_vmid)"
  ACTION="$(ui_menu \
    "Execution Mode" \
    "Choose the operation to run:" \
    "$ACTION" \
    "full" "Create VM and install the stack" \
    "bootstrap" "Resume bootstrap on an existing VM")"
  case "$ACTION" in
    full|bootstrap) ;;
    *) die "Action must be full or bootstrap." ;;
  esac

  VMID="$(ui_input "Virtual Machine ID" "Set the VMID to use in Proxmox VE:" "${VMID:-$default_vmid}")"
  [[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be numeric."
  local vm_exists=0
  qm status "$VMID" >/dev/null 2>&1 && vm_exists=1
  if [[ "$ACTION" == "full" && "$vm_exists" -eq 1 ]]; then
    die "VMID ${VMID} already exists. Use ACTION=bootstrap to resume provisioning."
  fi
  if [[ "$ACTION" == "bootstrap" && "$vm_exists" -eq 0 ]]; then
    die "VMID ${VMID} does not exist. Use ACTION=full to create it."
  fi

  VM_USER="$(ui_input "Cloud-Init User" "Set the VM user used for SSH provisioning:" "$VM_USER")"
  [[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid Linux user name: ${VM_USER}"
  ARR_TZ="$(ui_input "Timezone" "Set the timezone for the containers:" "$ARR_TZ")"
  [[ "$ARR_TZ" =~ ^[A-Za-z0-9_./+-]+$ ]] || die "Invalid timezone: ${ARR_TZ}"

  if [[ "$ACTION" == "bootstrap" ]]; then
    SSH_CONNECT_IP="$(ui_input "VM IP Address" "Set the existing VM IP address for SSH provisioning:" "${VM_IP:-}")"
    is_valid_ipv4 "$SSH_CONNECT_IP" || die "Invalid VM IP: ${SSH_CONNECT_IP}"
    confirm_configuration
    return
  fi

  VM_NAME="$(ui_input "VM Name" "Set the VM name shown in Proxmox VE:" "$VM_NAME")"
  VM_CORES="$(ui_input "CPU Cores" "Set the number of vCPU cores:" "$VM_CORES")"
  VM_MEMORY="$(ui_input "Memory" "Set memory in MB:" "$VM_MEMORY")"
  VM_DISK_SIZE="$(ui_input "Disk Size" "Set the final VM disk size:" "$VM_DISK_SIZE")"

  if [[ -z "$VM_PASSWORD" ]]; then
    VM_PASSWORD="$(ui_password "Cloud-Init Password" "Set the cloud-init password for ${VM_USER}:")"
  fi
  [[ -n "$VM_PASSWORD" ]] || die "Password cannot be empty."

  if [[ -z "$VM_STORAGE" ]]; then
    local storage_default=""
    local storage_items=()
    local storage
    while IFS= read -r storage; do
      [[ -z "$storage" ]] && continue
      [[ -z "$storage_default" ]] && storage_default="$storage"
      storage_items+=("$storage" "VM disk images")
    done < <(storage_options)
    ((${#storage_items[@]} > 0)) || die "No storage with content 'images' available."
    VM_STORAGE="$(ui_menu "VM Storage" "Pick a PVE storage for the VM disk:" "$storage_default" "${storage_items[@]}")"
  fi
  [[ -n "$VM_STORAGE" ]] || die "No storage selected."

  local bridge_items=()
  local bridge
  while IFS= read -r bridge; do
    [[ -z "$bridge" ]] && continue
    bridge_items+=("$bridge" "Linux bridge")
  done < <(bridge_options)
  if ((${#bridge_items[@]} > 0)); then
    VM_BRIDGE="$(ui_menu "Network Bridge" "Pick the Linux bridge for the VM:" "$VM_BRIDGE" "${bridge_items[@]}")"
  else
    VM_BRIDGE="$(ui_input "Network Bridge" "Set the Linux bridge for the VM:" "$VM_BRIDGE")"
  fi
  [[ -n "$VM_BRIDGE" ]] || die "Bridge cannot be empty."

  VM_IP_MODE="$(ui_menu \
    "Network Mode" \
    "Choose how to configure the VM IPv4 address:" \
    "$VM_IP_MODE" \
    "dhcp" "Use DHCP and provide the reserved IP" \
    "static" "Configure static IP via cloud-init")"
  case "$VM_IP_MODE" in
    dhcp)
      SSH_CONNECT_IP="$(ui_input "Reserved DHCP IP" "Enter the DHCP-reserved VM IP used for SSH provisioning:" "${VM_IP:-}")"
      [[ -n "$SSH_CONNECT_IP" ]] || die "For DHCP, provide the reserved IP so the script can finish provisioning."
      ;;
    static)
      VM_IP="$(ui_input "Static IP" "Enter the static VM IPv4 address:" "$VM_IP")"
      VM_GATEWAY="$(ui_input "Gateway" "Enter the IPv4 gateway:" "$VM_GATEWAY")"
      VM_CIDR="$(ui_input "CIDR Mask" "Enter the network mask, for example 24:" "$VM_CIDR")"
      is_valid_ipv4 "$VM_IP" || die "Invalid static IP: ${VM_IP}"
      is_valid_ipv4 "$VM_GATEWAY" || die "Invalid gateway: ${VM_GATEWAY}"
      [[ "$VM_CIDR" =~ ^[0-9]+$ ]] && ((VM_CIDR >= 1 && VM_CIDR <= 32)) || die "Invalid CIDR: ${VM_CIDR}"
      SSH_CONNECT_IP="$VM_IP"
      ;;
    *)
      die "Network mode must be dhcp or static."
      ;;
  esac

  confirm_configuration
}

ensure_workdir() {
  mkdir -p "$WORK_DIR"
  chmod 700 "$WORK_DIR"
}

download_image() {
  if [[ -s "$IMAGE_FILE" ]]; then
    ok "Using existing image: ${IMAGE_FILE}"
    return
  fi

  msg "Downloading Debian 13 generic cloud image"
  curl -fL --progress-bar -o "${IMAGE_FILE}.tmp" "$IMAGE_URL"
  mv "${IMAGE_FILE}.tmp" "$IMAGE_FILE"
  ok "Downloaded ${IMAGE_FILE}"
}

ensure_provision_key() {
  if [[ -s "$PROVISION_KEY" && -s "${PROVISION_KEY}.pub" ]]; then
    ok "Using existing provisioning key: ${PROVISION_KEY}"
    return
  fi

  if [[ "$ACTION" == "bootstrap" ]]; then
    die "Provisioning key not found at ${PROVISION_KEY}. Reuse the WORK_DIR from the original run."
  fi

  msg "Generating provisioning SSH key"
  ssh-keygen -t ed25519 -N "" -f "$PROVISION_KEY" -C "arr-vm-docker-stack" >/dev/null
  chmod 600 "$PROVISION_KEY"
}

cloudinit_ipconfig() {
  if [[ "$VM_IP_MODE" == "dhcp" ]]; then
    printf 'ip=dhcp,ip6=auto'
  else
    printf 'ip=%s/%s,gw=%s,ip6=auto' "$VM_IP" "$VM_CIDR" "$VM_GATEWAY"
  fi
}

create_vm() {
  local ipconfig
  ipconfig="$(cloudinit_ipconfig)"

  msg "Creating VM ${VMID} (${VM_NAME})"
  qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --machine q35 \
    --cpu host \
    --cores "$VM_CORES" \
    --memory "$VM_MEMORY" \
    --agent enabled=1 \
    --net0 "virtio,bridge=${VM_BRIDGE}" \
    --scsihw virtio-scsi-single \
    --serial0 socket \
    --vga serial0

  qm set "$VMID" \
    --scsi0 "${VM_STORAGE}:0,import-from=${IMAGE_FILE},discard=on" \
    --ide2 "${VM_STORAGE}:cloudinit" \
    --boot order=scsi0 \
    --ciuser "$VM_USER" \
    --cipassword "$VM_PASSWORD" \
    --sshkeys "${PROVISION_KEY}.pub" \
    --ipconfig0 "$ipconfig"

  qm disk resize "$VMID" scsi0 "$VM_DISK_SIZE"
  ok "VM ${VMID} created"
}

start_vm() {
  msg "Starting VM ${VMID}"
  qm start "$VMID"
}

ssh_base() {
  ssh \
    -i "$PROVISION_KEY" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o PreferredAuthentications=publickey \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${WORK_DIR}/known_hosts" \
    -o ConnectTimeout=5 \
    "${VM_USER}@${SSH_CONNECT_IP}" "$@"
}

detect_guest_ipv4() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null \
    | awk -F\" '/ip-address/ && $4 ~ /^[0-9]+\./ && $4 !~ /^127\./ {print $4; exit}'
}

ssh_failure_help() {
  local last_error=$1 detected_ip=${2:-}
  warn "SSH did not become ready for VM ${VMID}."
  [[ -n "$detected_ip" ]] && warn "Guest agent reported IPv4: ${detected_ip}"
  [[ -n "$last_error" ]] && warn "Last SSH error: ${last_error}"
  cat >&2 <<EOF

Check these items on the Proxmox node:
  qm status ${VMID}
  qm terminal ${VMID}

Inside the VM console, verify:
  cloud-init status --long
  ip addr
  systemctl status ssh

Manual SSH test:
  ssh -i ${PROVISION_KEY} -o IdentitiesOnly=yes ${VM_USER}@${detected_ip:-${SSH_CONNECT_IP}}

When SSH works, resume without recreating the VM:
  ACTION=bootstrap VMID=${VMID} VM_IP=${detected_ip:-${SSH_CONNECT_IP}} VM_USER=${VM_USER} bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Paivs/arr-auto-deploy/refs/heads/main/arr-vm-docker-stack.sh)"

To wait longer next time:
  SSH_WAIT_TIMEOUT=1800 bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Paivs/arr-auto-deploy/refs/heads/main/arr-vm-docker-stack.sh)"

EOF
}

wait_for_ssh() {
  msg "Waiting for SSH at ssh://${VM_USER}@${SSH_CONNECT_IP}:22"
  local elapsed=0
  local timeout=$SSH_WAIT_TIMEOUT
  local last_error=""
  local detected_ip=""
  until last_error="$(ssh_base "true" 2>&1 >/dev/null)"; do
    if [[ "$last_error" == *"Permission denied"* ]]; then
      ssh_failure_help "$last_error" "$detected_ip"
      die "SSH key authentication failed for ${VM_USER}@${SSH_CONNECT_IP}."
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    if ((elapsed % 30 == 0)); then
      detected_ip="$(detect_guest_ipv4 || true)"
      if [[ -n "$detected_ip" && "$detected_ip" != "$SSH_CONNECT_IP" ]]; then
        msg "Guest agent reports ${detected_ip}; trying ssh://${VM_USER}@${detected_ip}:22"
        SSH_CONNECT_IP="$detected_ip"
      else
        msg "Still waiting for ssh://${VM_USER}@${SSH_CONNECT_IP}:22 (${elapsed}/${timeout}s)"
      fi
    fi
    if ((elapsed >= timeout)); then
      ssh_failure_help "$last_error" "$detected_ip"
      die "Timed out waiting for SSH on ${SSH_CONNECT_IP} after ${timeout}s."
    fi
  done
  ok "SSH is ready"
}

bootstrap_arr_stack() {
  msg "Bootstrapping Docker and ARR stack inside the VM"
  ssh_base "sudo env ARR_ADMIN_USER='${VM_USER}' ARR_TZ='${ARR_TZ}' bash -s" <<'REMOTE_BOOTSTRAP'
set -eEo pipefail

export DEBIAN_FRONTEND=noninteractive

if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait >/dev/null || true
fi

cat >/etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF

if grep -Rqs 'mirror+file:/etc/apt/mirrors' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  find /etc/apt/sources.list.d -type f \( -name '*.sources' -o -name '*.list' \) -print0 \
    | xargs -0 -r grep -l 'mirror+file:/etc/apt/mirrors' \
    | while IFS= read -r source_file; do
      mv "$source_file" "${source_file}.disabled-by-arr-stack"
    done

  if [[ -f /etc/apt/sources.list ]] && grep -q 'mirror+file:/etc/apt/mirrors' /etc/apt/sources.list; then
    mv /etc/apt/sources.list /etc/apt/sources.list.disabled-by-arr-stack
  fi

  cat >/etc/apt/sources.list.d/debian-direct.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates trixie-backports
Components: main

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main
EOF
fi

apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true install -y ca-certificates curl qemu-guest-agent
install -m 0755 -d /etc/apt/keyrings
curl -4 -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get -o Acquire::ForceIPv4=true update
apt-get -o Acquire::ForceIPv4=true install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker qemu-guest-agent
usermod -aG docker "$ARR_ADMIN_USER"

ARR_UID="$(id -u "$ARR_ADMIN_USER")"
ARR_GID="$(id -g "$ARR_ADMIN_USER")"

install -d -m 0755 -o "$ARR_ADMIN_USER" -g "$ARR_ADMIN_USER" \
  /opt/arr \
  /data/downloads/complete \
  /data/downloads/incomplete \
  /data/media/movies \
  /data/media/tv \
  /data/media/music \
  /data/configs/prowlarr \
  /data/configs/sonarr \
  /data/configs/radarr \
  /data/configs/lidarr \
  /data/configs/bazarr \
  /data/configs/qbittorrent

cat >/opt/arr/.env <<EOF
PUID=${ARR_UID}
PGID=${ARR_GID}
TZ=${ARR_TZ}
EOF

cat >/opt/arr/compose.yaml <<'EOF'
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /data/configs/prowlarr:/config
    ports:
      - "9696:9696"
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /data/configs/sonarr:/config
      - /data/media/tv:/tv
      - /data/downloads:/downloads
    ports:
      - "8989:8989"
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /data/configs/radarr:/config
      - /data/media/movies:/movies
      - /data/downloads:/downloads
    ports:
      - "7878:7878"
    restart: unless-stopped

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /data/configs/lidarr:/config
      - /data/media/music:/music
      - /data/downloads:/downloads
    ports:
      - "8686:8686"
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /data/configs/bazarr:/config
      - /data/media/movies:/movies
      - /data/media/tv:/tv
    ports:
      - "6767:6767"
    restart: unless-stopped

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - WEBUI_PORT=8090
    volumes:
      - /data/configs/qbittorrent:/config
      - /data/downloads:/downloads
    ports:
      - "8090:8090"
      - "6881:6881"
      - "6881:6881/udp"
    restart: unless-stopped
EOF

chown -R "$ARR_ADMIN_USER:$ARR_ADMIN_USER" /opt/arr /data
export COMPOSE_PARALLEL_LIMIT=1

compose_as_user() {
  sudo -u "$ARR_ADMIN_USER" docker compose --env-file /opt/arr/.env -f /opt/arr/compose.yaml "$@"
}

pull_with_retry() {
  local service=$1
  local attempt
  local delay=10
  for attempt in 1 2 3 4 5; do
    if compose_as_user pull "$service"; then
      return 0
    fi
    if [[ "$attempt" == "5" ]]; then
      break
    fi
    echo "Pull failed for ${service}; retry ${attempt}/5 in ${delay}s" >&2
    sleep "$delay"
    delay=$((delay * 2))
  done
  return 1
}

for service in prowlarr sonarr radarr lidarr bazarr qbittorrent; do
  pull_with_retry "$service"
done

compose_as_user up -d
compose_as_user ps
REMOTE_BOOTSTRAP
  ok "ARR stack bootstrapped"
}

write_summary() {
  cat >"$SUMMARY_FILE" <<EOF
ARR VM Docker Stack

VMID: ${VMID}
Name: ${VM_NAME}
User: ${VM_USER}
IP: ${SSH_CONNECT_IP}
Storage: ${VM_STORAGE}
Bridge: ${VM_BRIDGE}
Provision key: ${PROVISION_KEY}

Service URLs:
  Prowlarr:     http://${SSH_CONNECT_IP}:9696
  Sonarr:       http://${SSH_CONNECT_IP}:8989
  Radarr:       http://${SSH_CONNECT_IP}:7878
  Lidarr:       http://${SSH_CONNECT_IP}:8686
  Bazarr:       http://${SSH_CONNECT_IP}:6767
  qBittorrent:  http://${SSH_CONNECT_IP}:8090

Files inside VM:
  Compose: /opt/arr/compose.yaml
  Env:     /opt/arr/.env
  Configs: /data/configs
  Media:   /data/media
  Downloads: /data/downloads
EOF
  ok "Summary written to ${SUMMARY_FILE}"
}

main() {
  require_root
  require_commands
  ensure_ui
  header_info
  collect_inputs "$@"
  ensure_workdir
  ensure_provision_key

  if [[ "$ACTION" == "bootstrap" ]]; then
    wait_for_ssh
    bootstrap_arr_stack
    write_summary
    return
  fi

  download_image
  create_vm
  start_vm
  wait_for_ssh
  bootstrap_arr_stack
  write_summary
}

main "$@"
