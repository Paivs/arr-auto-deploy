#!/usr/bin/env bash

set -eEo pipefail

SCRIPT_NAME="$(basename "$0")"
WORK_DIR="${WORK_DIR:-/var/lib/arr-vm-docker-stack}"
IMAGE_URL="${IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2}"
IMAGE_FILE="${IMAGE_FILE:-${WORK_DIR}/debian-13-generic-amd64.qcow2}"
PROVISION_KEY="${PROVISION_KEY:-${WORK_DIR}/arr-vm-provision}"
SUMMARY_FILE="${SUMMARY_FILE:-${WORK_DIR}/summary.txt}"

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

SSH_CONNECT_IP=""

msg() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo ./${SCRIPT_NAME}

Environment overrides:
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

next_vmid() {
  qm list 2>/dev/null | awk 'NR > 1 {print $1}' | sort -n | awk 'BEGIN {id=120} $1 >= id {id=$1+1} END {print id}'
}

storage_options() {
  pvesm status -content images 2>/dev/null | awk 'NR > 1 {print $1}'
}

bridge_options() {
  awk '/^iface vmbr/ {print $2}' /etc/network/interfaces 2>/dev/null
}

collect_inputs() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  local default_vmid
  default_vmid="$(next_vmid)"
  VMID="$(prompt_default "VMID" "${VMID:-$default_vmid}")"
  [[ "$VMID" =~ ^[0-9]+$ ]] || die "VMID must be numeric."
  qm status "$VMID" >/dev/null 2>&1 && die "VMID ${VMID} already exists."

  VM_NAME="$(prompt_default "VM name" "$VM_NAME")"
  VM_CORES="$(prompt_default "CPU cores" "$VM_CORES")"
  VM_MEMORY="$(prompt_default "Memory in MB" "$VM_MEMORY")"
  VM_DISK_SIZE="$(prompt_default "Disk size" "$VM_DISK_SIZE")"
  VM_USER="$(prompt_default "Cloud-init user" "$VM_USER")"

  if [[ -z "$VM_PASSWORD" ]]; then
    VM_PASSWORD="$(prompt_secret "Cloud-init password for ${VM_USER}")"
  fi
  [[ -n "$VM_PASSWORD" ]] || die "Password cannot be empty."

  if [[ -z "$VM_STORAGE" ]]; then
    msg "Available VM storages:"
    storage_options | sed 's/^/  - /'
    VM_STORAGE="$(prompt_default "VM disk storage" "$(storage_options | head -n1)")"
  fi
  [[ -n "$VM_STORAGE" ]] || die "No storage selected."

  msg "Available bridges:"
  bridge_options | sed 's/^/  - /' || true
  VM_BRIDGE="$(prompt_default "Network bridge" "$VM_BRIDGE")"
  [[ -n "$VM_BRIDGE" ]] || die "Bridge cannot be empty."

  VM_IP_MODE="$(prompt_default "Network mode: dhcp or static" "$VM_IP_MODE")"
  case "$VM_IP_MODE" in
    dhcp)
      SSH_CONNECT_IP="$(prompt_default "IP to wait for after DHCP reservation" "${VM_IP:-}")"
      [[ -n "$SSH_CONNECT_IP" ]] || die "For DHCP, provide the reserved IP so the script can finish provisioning."
      ;;
    static)
      VM_IP="$(prompt_default "Static VM IP" "$VM_IP")"
      VM_GATEWAY="$(prompt_default "Gateway" "$VM_GATEWAY")"
      VM_CIDR="$(prompt_default "CIDR mask" "$VM_CIDR")"
      is_valid_ipv4 "$VM_IP" || die "Invalid static IP: ${VM_IP}"
      is_valid_ipv4 "$VM_GATEWAY" || die "Invalid gateway: ${VM_GATEWAY}"
      [[ "$VM_CIDR" =~ ^[0-9]+$ ]] && ((VM_CIDR >= 1 && VM_CIDR <= 32)) || die "Invalid CIDR: ${VM_CIDR}"
      SSH_CONNECT_IP="$VM_IP"
      ;;
    *)
      die "Network mode must be dhcp or static."
      ;;
  esac
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
EOF
  ok "Summary written to ${SUMMARY_FILE}"
}

main() {
  require_root
  require_commands
  collect_inputs "$@"
  ensure_workdir
  download_image
  ensure_provision_key
  create_vm
  start_vm
  write_summary
}

main "$@"
