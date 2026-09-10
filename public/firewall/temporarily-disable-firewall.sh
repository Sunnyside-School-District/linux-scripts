#!/usr/bin/env bash
# @title: Temporarily Disable Firewall
# @description: Temporarily unloads the active host firewall for troubleshooting without disabling its boot-time configuration. Reboot or run the companion restore script afterward.
# @platforms: Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux
# @requires-root: yes
#
# Supported firewall managers:
#   - UFW
#   - firewalld
#   - nftables.service
#
# IMPORTANT:
#   This script intentionally removes host firewall protection. Use it only for
#   short troubleshooting windows on systems/networks where that risk is
#   acceptable. It does not alter the saved firewall rules.
#
#   For firewalld and nftables, a runtime-only systemd mask prevents the service
#   from being restarted during the troubleshooting window. Runtime masks live
#   under /run and disappear automatically at reboot.
#
#   For UFW, the script calls ufw-init force-stop instead of `ufw disable` so
#   UFW's persistent ENABLED setting is not changed.
#
# Run as root:
#   sudo ./temporarily-disable-firewall.sh

set -Eeuo pipefail
export LC_ALL=C

STATE_DIR="/run/susd12-firewall-troubleshoot"
STATE_FILE="$STATE_DIR/active-managers"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root (for example: sudo $0)."

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
: > "$STATE_FILE"
chmod 600 "$STATE_FILE"

systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

unit_exists() {
    systemd_available && [[ "$(systemctl show -p LoadState --value "$1" 2>/dev/null || true)" != "not-found" ]]
}

service_active() {
    systemd_available && systemctl is-active --quiet "$1" 2>/dev/null
}

ufw_active() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status:[[:space:]]*active'
}

find_ufw_init() {
    local candidate
    for candidate in /lib/ufw/ufw-init /usr/lib/ufw/ufw-init; do
        if [[ -x "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

record_manager() {
    printf '%s\n' "$1" >> "$STATE_FILE"
}

active_count=0

if service_active firewalld.service; then
    record_manager firewalld
    ((active_count += 1))
fi

if ufw_active; then
    record_manager ufw
    ((active_count += 1))
fi

if service_active nftables.service; then
    record_manager nftables
    ((active_count += 1))
fi

if (( active_count == 0 )); then
    rm -f "$STATE_FILE"
    rmdir "$STATE_DIR" 2>/dev/null || true
    cat <<'MSG'
No active supported host firewall manager was detected.

This script looks for:
  - firewalld.service
  - UFW with "Status: active"
  - nftables.service

No changes were made. Note that standalone iptables/nftables rules, container
networking rules, cloud-provider firewalls, hypervisor firewalls, and upstream
network firewalls are outside the scope of this script.
MSG
    exit 0
fi

warn "HOST FIREWALL PROTECTION IS ABOUT TO BE TEMPORARILY REMOVED."
echo "Detected active manager(s): $(paste -sd ', ' "$STATE_FILE")"
echo "Troubleshooting state: $STATE_FILE"

# Disable UFW first because it is not a long-running daemon and its own init
# helper cleanly unloads UFW-managed rules without changing ENABLED=yes.
if grep -qx 'ufw' "$STATE_FILE"; then
    UFW_INIT="$(find_ufw_init || true)"
    [[ -n "$UFW_INIT" ]] || die "UFW is active but ufw-init could not be found. No further firewall changes were attempted."

    log "Temporarily unloading UFW rules"
    "$UFW_INIT" force-stop

    # Prevent an explicit service start during this boot, if the unit exists.
    if unit_exists ufw.service; then
        systemctl mask --runtime ufw.service >/dev/null
    fi
fi

if grep -qx 'firewalld' "$STATE_FILE"; then
    log "Temporarily stopping firewalld"
    systemctl stop firewalld.service
    systemctl mask --runtime firewalld.service >/dev/null
fi

if grep -qx 'nftables' "$STATE_FILE"; then
    log "Temporarily stopping nftables.service"
    systemctl stop nftables.service
    systemctl mask --runtime nftables.service >/dev/null
fi

cat <<'MSG'

======================================================================
FIREWALL TROUBLESHOOTING MODE IS ACTIVE
======================================================================

The supported host firewall manager(s) that were active have been unloaded.
Their saved rule/configuration files were not deleted or reset.

Restore protection as soon as troubleshooting is complete by running:
  https://linux-scripts.susd12.org/firewall/re-enable-firewall.sh

A normal reboot also removes the runtime-only systemd masks. Firewall managers
that were already configured to start at boot can then load normally.

IMPORTANT: Other packet filters can still exist, including Docker/Podman rules,
Kubernetes rules, manually-created iptables/nftables rules, cloud security
controls, hypervisor firewalls, or upstream network firewalls.
======================================================================
MSG
