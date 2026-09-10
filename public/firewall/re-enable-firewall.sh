#!/usr/bin/env bash
# @title: Re-Enable Firewall Permanently
# @description: Restores firewall protection after the temporary troubleshooting script and enables the restored firewall manager to start automatically at boot.
# @platforms: Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux
# @requires-root: yes
#
# Intended to be run after temporarily-disable-firewall.sh.
#
# Supported firewall managers:
#   - UFW
#   - firewalld
#   - nftables.service
#
# Run as root:
#   sudo ./re-enable-firewall.sh

set -Eeuo pipefail
export LC_ALL=C

STATE_DIR="/run/susd12-firewall-troubleshoot"
STATE_FILE="$STATE_DIR/active-managers"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root (for example: sudo $0)."

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

add_target() {
    local target="$1"
    local existing
    for existing in "${targets[@]:-}"; do
        [[ "$existing" == "$target" ]] && return 0
    done
    targets+=("$target")
}

targets=()

if [[ -s "$STATE_FILE" ]]; then
    while IFS= read -r manager; do
        case "$manager" in
            ufw|firewalld|nftables) add_target "$manager" ;;
        esac
    done < "$STATE_FILE"
else
    # If the system rebooted already, /run state is expected to be gone. In that
    # case we do not guess which inactive firewall should be enabled. We only
    # operate on supported managers that are already active.
    service_active firewalld.service && add_target firewalld
    ufw_active && add_target ufw
    service_active nftables.service && add_target nftables

    if (( ${#targets[@]} == 0 )); then
        die "No troubleshooting state and no active supported firewall manager were found. Refusing to guess which firewall should be enabled."
    fi

    warn "No troubleshooting state file was found; using currently active supported firewall manager(s)."
fi

warn "Re-enabling a firewall can change or interrupt remote connections if the saved rules do not allow them."
echo "Firewall manager(s) to restore: ${targets[*]}"

for manager in "${targets[@]}"; do
    case "$manager" in
        ufw)
            command -v ufw >/dev/null 2>&1 || die "UFW was recorded for restoration, but the ufw command is unavailable."

            log "Restoring UFW and enabling it persistently"
            if unit_exists ufw.service; then
                systemctl unmask --runtime ufw.service >/dev/null 2>&1 || true
                systemctl unmask ufw.service >/dev/null 2>&1 || true
            fi

            # --force suppresses the interactive SSH warning so this can run as
            # a deployment/troubleshooting script. Saved UFW rules are retained.
            ufw --force enable

            if unit_exists ufw.service; then
                # Some releases treat ufw.service as static; failure to "enable"
                # such a unit is not fatal because `ufw enable` sets ENABLED=yes.
                systemctl enable ufw.service >/dev/null 2>&1 || true
            fi
            ;;

        firewalld)
            systemd_available || die "systemd is required to restore firewalld."
            unit_exists firewalld.service || die "firewalld.service is not installed."

            log "Restoring firewalld and enabling it at boot"
            systemctl unmask --runtime firewalld.service >/dev/null 2>&1 || true
            systemctl unmask firewalld.service >/dev/null 2>&1 || true
            systemctl enable --now firewalld.service
            ;;

        nftables)
            systemd_available || die "systemd is required to restore nftables.service."
            unit_exists nftables.service || die "nftables.service is not installed."

            log "Restoring nftables and enabling it at boot"
            systemctl unmask --runtime nftables.service >/dev/null 2>&1 || true
            systemctl unmask nftables.service >/dev/null 2>&1 || true
            systemctl enable --now nftables.service
            ;;
    esac
done

rm -f "$STATE_FILE"
rmdir "$STATE_DIR" 2>/dev/null || true

printf '\n==> Verification\n'
for manager in "${targets[@]}"; do
    case "$manager" in
        ufw)
            ufw status || true
            ;;
        firewalld)
            systemctl --no-pager --full status firewalld.service 2>/dev/null | sed -n '1,5p' || true
            command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state || true
            ;;
        nftables)
            systemctl --no-pager --full status nftables.service 2>/dev/null | sed -n '1,5p' || true
            ;;
    esac
done

cat <<'MSG'

======================================================================
FIREWALL PROTECTION RESTORED
======================================================================

The supported firewall manager(s) recorded by the troubleshooting script have
been restored. The restore operation also enables the applicable firewall
manager to start automatically at boot.

Review the verification output above and confirm that required remote services
(such as SSH) remain reachable under the restored firewall policy.
======================================================================
MSG
