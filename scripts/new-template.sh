#!/bin/bash
set -eo pipefail

# ============================================================
# Proxmox VM Template Builder
# ============================================================
# Creates cloud-init enabled VM templates from Ubuntu cloud
# images. Fetches cloud-config templates from a git repo and
# substitutes environment-specific values via envsubst.
#
# Cloud-config templates live in your git repo under:
#   cloud-config/<purpose>.yml
#
# Usage:
#   ./new-template.sh
#   CLOUD_CONFIG_REPO=https://raw.githubusercontent.com/you/infra/main ./new-template.sh
# ============================================================

# --- Configuration -----------------------------------------------------------
# Raw content base URL for your git repo (no trailing slash)
# Override via environment or edit this default
CLOUD_CONFIG_REPO="${CLOUD_CONFIG_REPO:-https://raw.githubusercontent.com/EHLO1/proxmox-utils/main}"

WORK_DIR="/tmp/pve-template-builder"
SNIPPET_DIR="/var/lib/vz/snippets"
DISK_SIZE="40G"

# --- Output Helpers -----------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()   { echo -e "  ${CYAN}→${NC} $*" >&2; }
ok()     { echo -e "  ${GREEN}✓${NC} $*" >&2; }
warn()   { echo -e "  ${YELLOW}!${NC} $*" >&2; }
err()    { echo -e "  ${RED}✗${NC} $*" >&2; }
die()    { err "$*"; exit 1; }
header() { echo -e "\n${BOLD}$*${NC}\n"; }

# --- Prompt Helpers -----------------------------------------------------------

prompt_text() {
    local label="$1" default="$2" result
    if [ -n "$default" ]; then
        read -rp "  ${label} [${default}]: " result
        echo "${result:-$default}"
    else
        read -rp "  ${label}: " result
        [ -z "$result" ] && die "${label} cannot be empty"
        echo "$result"
    fi
}

prompt_select() {
    local label="$1"; shift
    local options=("$@")

    # Auto-select if only one option
    if [ ${#options[@]} -eq 1 ]; then
        ok "${label}: ${options[0]}" 
        echo "${options[0]}"
        return
    fi

    echo -e "  ${BOLD}${label}${NC}" >&2
    for i in "${!options[@]}"; do
        echo "    $((i+1))) ${options[$i]}" >&2
    done

    while true; do
        read -rp "  Select [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return
        fi
        warn "Enter a number between 1 and ${#options[@]}"
    done
}

prompt_confirm() {
    read -rp "  $1 [Y/n]: " yn
    [[ ! "$yn" =~ ^[Nn] ]]
}

read_pubkey() {
    local label="$1" default="$2" path

    if [ -n "$default" ] && [ -f "$default" ]; then
        read -rp "  ${label} [${default}]: " path
        path="${path:-$default}"
    else
        if [ -n "$default" ]; then
            warn "Default not found: $default"
        fi
        read -rp "  ${label}: " path
        [ -z "$path" ] && die "SSH public key path is required"
    fi

    [ ! -f "$path" ] && die "File not found: $path"

    local key
    key=$(<"$path")

    echo "$key" | grep -qE '^ssh-(ed25519|rsa|ecdsa)' \
        || die "Doesn't look like an SSH public key: $path"

    echo "$key"
}

# --- Dependency Check ---------------------------------------------------------
check_deps() {
    local missing=()
    for cmd in wget qm pvesm qemu-img envsubst sha256sum; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing: ${missing[*]}  (apt-get install -y wget qemu-utils gettext-base)"
    fi
}

# --- Help ---------------------------------------------------------------------
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    cat <<'USAGE'
Proxmox VM Template Builder

Usage: ./new-template.sh

Environment variables:
  CLOUD_CONFIG_REPO   Raw git URL for cloud-config templates
                      e.g. https://raw.githubusercontent.com/user/repo/main

  Templates are expected at: <REPO>/cloud-config/<purpose>.yml
  If CLOUD_CONFIG_REPO is unset, a generic cloud-config is generated inline.

  All other values are collected interactively.
USAGE
    exit 0
fi

# ==============================================================================
# Main
# ==============================================================================
check_deps

header "═══ Proxmox VM Template Builder ═══"

# --- Distribution & Release ---------------------------------------------------
DISTRO=$(prompt_select "Distribution" "ubuntu")

case "$DISTRO" in
    ubuntu)
        CODENAME=$(prompt_select "Release" \
            "resolute (26.04 LTS)" \
            "noble (24.04 LTS)" \
            "jammy (22.04 LTS)")
        CODENAME="${CODENAME%% *}"
        ;;
    # Future distros:
    # debian)
    #     CODENAME=$(prompt_select "Release" "trixie (13)" "bookworm (12)")
    #     CODENAME="${CODENAME%% *}"
    #     ;;
esac

# --- Purpose ------------------------------------------------------------------
while true; do
    PURPOSE=$(prompt_text "Purpose (e.g. docker, standard, k8s)" "docker")
    if [[ ! "$PURPOSE" =~ ^[a-z0-9]+$ ]]; then
        warn "Lowercase letters and numbers only (a-z, 0-9)"
        continue
    elif [ ${#PURPOSE} -gt 15 ]; then
        warn "Must be 15 characters or fewer (got ${#PURPOSE})"
        continue
    fi
    break
done

# --- VM Configuration ---------------------------------------------------------
header "VM Configuration"

DESTROY_EXISTING=false
while true; do
    VMID=$(prompt_text "VM ID" "8001")

    [[ "$VMID" =~ ^[0-9]+$ ]] || { warn "VMID must be numeric"; continue; }

    if qm status "$VMID" &>/dev/null; then
        warn "VMID $VMID is already in use"
        action=$(prompt_select "What should we do?" \
            "Pick a different VMID" \
            "Destroy existing VM and reuse")
        if [ "$action" = "Destroy existing VM and reuse" ]; then
            DESTROY_EXISTING=true
            break
        fi
    else
        break
    fi
done

info "Querying available storage targets..."
mapfile -t STORAGES < <(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
[ ${#STORAGES[@]} -eq 0 ] && die "No active storage targets found with 'images' content type"
STORAGE=$(prompt_select "Storage target" "${STORAGES[@]}")

# --- Cloud-Init Configuration ------------------------------------------------
header "Cloud-Init"

USERNAME=$(prompt_text "Primary username (uid 1000)" "")

echo ""
info "SSH public keys"
USER_SSH_PUBKEY=$(read_pubkey "User public key" "$HOME/.ssh/id_ed25519.pub")
ok "User key loaded"
ANSIBLE_SSH_PUBKEY=$(read_pubkey "Ansible public key" "$HOME/.ssh/id_ansible.pub")
ok "Ansible key loaded"

TIMEZONE=$(cat /etc/timezone 2>/dev/null || echo "UTC")
LOCALE="${LANG:-en_US.UTF-8}"
ok "Timezone: $TIMEZONE (from host)"
ok "Locale:   $LOCALE (from host)"

# --- Summary & Confirm -------------------------------------------------------
TEMPLATE_NAME="$DISTRO-$CODENAME-$PURPOSE-template"
SNIPPET_NAME="$DISTRO-$CODENAME-$PURPOSE.yml"

header "Summary"
cat <<EOF
  Name:          $TEMPLATE_NAME
  VMID:          $VMID
  Storage:       $STORAGE
  Disk:          $DISK_SIZE
  Username:      $USERNAME
  Timezone:      $TIMEZONE
  Cloud-config:  $SNIPPET_NAME
  Tags:          $DISTRO, $CODENAME, $PURPOSE, cloudinit
EOF
echo ""
prompt_confirm "Proceed?" || die "Aborted"

# --- Download Cloud Image -----------------------------------------------------
header "Cloud Image"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

case "$DISTRO" in
    ubuntu)
        IMG="${CODENAME}-server-cloudimg-amd64.img"
        BASE_URL="https://cloud-images.ubuntu.com/${CODENAME}/current"
        ;;
    # Future distros: add image URL patterns here
    *)
        die "Cloud image support for '$DISTRO' is not yet implemented"
        ;;
esac

info "Fetching checksum..."
EXPECTED_SHA=$(wget -qO- "$BASE_URL/SHA256SUMS" | awk "/$IMG/"'{print $1}')
[ -z "$EXPECTED_SHA" ] && die "Could not find checksum for $IMG"

download_image() {
    info "Downloading $IMG..."
    wget -q --show-progress "$BASE_URL/$IMG" -O "$IMG"
}

verify_image() {
    sha256sum "$IMG" | awk '{print $1}'
}

# Download or verify existing
if [ -f "$IMG" ]; then
    info "Cached image found, verifying..."
    ACTUAL_SHA=$(verify_image)
    if [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
        warn "Stale image, re-downloading..."
        rm -f "$IMG"
        download_image
        ACTUAL_SHA=$(verify_image)
        [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ] && die "Checksum failed after re-download"
    fi
else
    download_image
    ACTUAL_SHA=$(verify_image)
    [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ] && die "Checksum verification failed"
fi
ok "Image verified ($IMG)"

# Resize
RESIZED_IMG="${IMG%.img}-resized.img"
info "Creating resized copy (${DISK_SIZE})..."
cp "$IMG" "$RESIZED_IMG"
qemu-img resize "$RESIZED_IMG" "$DISK_SIZE" &>/dev/null
ok "Image resized"

# --- Cloud-Config -------------------------------------------------------------
header "Cloud-Config"

export USERNAME USER_SSH_PUBKEY ANSIBLE_SSH_PUBKEY TIMEZONE LOCALE
ENVSUBST_VARS='${USERNAME} ${USER_SSH_PUBKEY} ${ANSIBLE_SSH_PUBKEY} ${TIMEZONE} ${LOCALE}'

mkdir -p "$SNIPPET_DIR"

if [ -n "$CLOUD_CONFIG_REPO" ]; then
    TEMPLATE_URL="$CLOUD_CONFIG_REPO/cloud-config/$PURPOSE.yml"
    info "Fetching template: cloud-config/$PURPOSE.yml"

    if wget -qO- "$TEMPLATE_URL" | envsubst "$ENVSUBST_VARS" | tee "$SNIPPET_DIR/$SNIPPET_NAME" >/dev/null; then
        ok "Template fetched and rendered"
    else
        die "Failed to fetch cloud-config/$PURPOSE.yml from repo"
    fi
else
    warn "CLOUD_CONFIG_REPO not set — generating inline (no purpose-specific groups)"
    info "Set CLOUD_CONFIG_REPO for purpose-specific templates from your git repo"

    cat <<'TMPL' | envsubst "$ENVSUBST_VARS" | tee "$SNIPPET_DIR/$SNIPPET_NAME" >/dev/null
#cloud-config
timezone: ${TIMEZONE}
locale: ${LOCALE}

users:
  - name: ${USERNAME}
    uid: 1000
    groups:
      - sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${USER_SSH_PUBKEY}

  - name: ansible
    system: true
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ANSIBLE_SSH_PUBKEY}

package_update: true
package_reboot_if_required: true
packages:
  - qemu-guest-agent
TMPL
    ok "Inline cloud-config generated"
fi

ok "Written to $SNIPPET_DIR/$SNIPPET_NAME"

# --- Create VM ----------------------------------------------------------------
header "Building Template"

if [ "$DESTROY_EXISTING" = true ]; then
    info "Destroying existing VMID $VMID..."
    qm destroy "$VMID" --purge 2>/dev/null || true
    ok "Destroyed"
fi

info "Creating VM..."
qm create "$VMID" --name "$TEMPLATE_NAME" --ostype l26 \
    --memory 1024 --balloon 0 \
    --agent 1 \
    --bios ovmf --machine q35 --efidisk0 "$STORAGE":0,pre-enrolled-keys=0 \
    --cpu host --socket 1 --cores 1 \
    --vga serial0 --serial0 socket \
    --net0 virtio,bridge=vmbr0

info "Importing disk..."
qm importdisk "$VMID" "$RESIZED_IMG" "$STORAGE" &>/dev/null

info "Configuring hardware..."
qm set "$VMID" --scsihw virtio-scsi-pci --virtio0 "$STORAGE:vm-$VMID-disk-1,discard=on"
qm set "$VMID" --boot order=virtio0
qm set "$VMID" --scsi1 "$STORAGE:cloudinit"

info "Applying cloud-init config..."
qm set "$VMID" --cicustom "user=local:snippets/$SNIPPET_NAME"
qm set "$VMID" --tags "$DISTRO,$CODENAME,$PURPOSE,cloudinit"
qm set "$VMID" --ipconfig0 ip=dhcp

info "Converting to template..."
qm template "$VMID"

header "Done"
ok "$TEMPLATE_NAME (VMID: $VMID) is ready to clone"