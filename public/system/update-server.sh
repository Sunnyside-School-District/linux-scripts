#!/usr/bin/env bash
# @title: Update Server
# @description: Updates all distribution-managed packages and, when installed, system-wide Snap and Flatpak applications on Debian, Ubuntu, RHEL, Rocky Linux, and AlmaLinux.
# @platforms: Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux
# @requires-root: yes
#
# Updates:
#   - Debian / Ubuntu packages via APT
#   - RHEL / Rocky Linux / AlmaLinux packages via DNF (YUM fallback)
#   - Installed Snap packages, when snapd is present
#   - System-wide Flatpak applications and runtimes, when Flatpak is present
#
# Deliberately NOT updated automatically:
#   - Docker/Podman application containers
#   - Python packages installed with pip
#   - Global npm packages
#   - Ruby gems / Composer packages / other application-specific runtimes
#   - Distribution release upgrades (for example Ubuntu 24.04 -> 26.04)
#
# Those ecosystems can contain application-pinned dependencies, so blindly
# upgrading them can break production services.
#
# By default this script automatically reboots the server when a reboot is
# detected as required. Use --no-reboot to suppress the automatic reboot.
#
# Usage:
#   sudo ./update-server.sh
#   sudo ./update-server.sh --no-reboot
#   sudo ./update-server.sh --no-snap --no-flatpak
#
# Exit status:
#   0 = distribution update completed successfully
#   non-zero = a required update step failed

set -Eeuo pipefail
export LC_ALL=C

DO_SNAP=1
DO_FLATPAK=1
AUTO_REBOOT=1

usage() {
    cat <<'EOF'
Usage: update-server.sh [OPTIONS]

Update the operating system and common system-wide application packages.

Options:
  --no-reboot    Do not automatically reboot, even if updates require it.
  --reboot       Explicitly enable automatic reboot (the default behavior).
  --no-snap      Skip Snap package updates.
  --no-flatpak   Skip Flatpak package updates.
  -h, --help     Show this help text.

The script does not perform distribution release upgrades and does not
automatically upgrade application-specific package ecosystems such as pip,
npm, Docker/Podman containers, Ruby gems, or Composer dependencies.
EOF
}

while (($#)); do
    case "$1" in
        --reboot)
            AUTO_REBOOT=1
            ;;
        --no-reboot)
            AUTO_REBOOT=0
            ;;
        --no-snap)
            DO_SNAP=0
            ;;
        --no-flatpak)
            DO_FLATPAK=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: Unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    printf 'ERROR: Run this script as root (for example: sudo %s).\n' "$0" >&2
    exit 1
}

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="/var/log/susd12-update-server-${STAMP}.log"

# Preserve output on screen while also keeping an audit/troubleshooting log.
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\nWARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '\nERROR: Update failed at line %s (exit code %s).\n' "${BASH_LINENO[0]:-unknown}" "$rc" >&2
    printf 'Log: %s\n' "$LOG_FILE" >&2
    exit "$rc"
}
trap on_error ERR

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    die "/etc/os-release was not found; unable to identify this Linux distribution."
fi

DISTRO_ID="${ID:-unknown}"
DISTRO_LIKE="${ID_LIKE:-}"
DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

supported=0
case "$DISTRO_ID" in
    debian|ubuntu|rhel|rocky|almalinux)
        supported=1
        ;;
esac

if [[ "$supported" -ne 1 ]]; then
    case " $DISTRO_LIKE " in
        *" debian "*|*" rhel "*|*" fedora "*)
            warn "Distribution '$DISTRO_NAME' is not one of the explicitly supported targets, but it is in a compatible family. Continuing."
            ;;
        *)
            die "Unsupported distribution: $DISTRO_NAME"
            ;;
    esac
fi

log "Starting server update"
printf 'Distribution : %s\n' "$DISTRO_NAME"
printf 'Hostname     : %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'Kernel       : %s\n' "$(uname -r)"
printf 'Started      : %s\n' "$(date -Is)"
printf 'Log file     : %s\n' "$LOG_FILE"

update_apt() {
    command -v apt-get >/dev/null 2>&1 || die "APT was expected but apt-get was not found."

    log "Refreshing APT package indexes"
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none

    apt-get update

    log "Installing all available Debian/Ubuntu package upgrades"
    # --with-new-pkgs permits new dependencies required by an upgrade without
    # allowing package removals the way full-upgrade/dist-upgrade can.
    # --force-confold preserves locally modified configuration files.
    apt-get \
        -y \
        --with-new-pkgs \
        -o Dpkg::Options::="--force-confold" \
        upgrade

    log "Checking APT package database"
    apt-get check
}

update_dnf() {
    if command -v dnf >/dev/null 2>&1; then
        log "Refreshing metadata and installing all available DNF upgrades"
        dnf -y upgrade --refresh
    elif command -v yum >/dev/null 2>&1; then
        log "Installing all available YUM upgrades"
        yum -y update
    else
        die "DNF/YUM was expected but neither command was found."
    fi
}

case "$DISTRO_ID" in
    debian|ubuntu)
        update_apt
        ;;
    rhel|rocky|almalinux)
        update_dnf
        ;;
    *)
        if command -v apt-get >/dev/null 2>&1; then
            update_apt
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            update_dnf
        else
            die "No supported package manager was detected."
        fi
        ;;
esac

optional_failure=0

if [[ "$DO_SNAP" -eq 1 ]] && command -v snap >/dev/null 2>&1; then
    log "Updating installed Snap packages"
    if snap refresh; then
        printf 'Snap update completed.\n'
    else
        warn "Snap refresh failed. The operating-system package update succeeded, but Snap packages may not be fully updated."
        optional_failure=1
    fi
elif [[ "$DO_SNAP" -eq 1 ]]; then
    log "Snap is not installed; skipping Snap updates"
fi

if [[ "$DO_FLATPAK" -eq 1 ]] && command -v flatpak >/dev/null 2>&1; then
    log "Updating system-wide Flatpak applications and runtimes"
    if flatpak update -y --system; then
        printf 'Flatpak update completed.\n'
    else
        warn "System-wide Flatpak update failed. The operating-system package update succeeded, but Flatpak packages may not be fully updated."
        optional_failure=1
    fi
elif [[ "$DO_FLATPAK" -eq 1 ]]; then
    log "Flatpak is not installed; skipping Flatpak updates"
fi

REBOOT_REQUIRED=0
REBOOT_REASON=""

if [[ -f /var/run/reboot-required ]]; then
    REBOOT_REQUIRED=1
    REBOOT_REASON="Debian/Ubuntu created /var/run/reboot-required."
fi

# On RHEL-family systems, use the DNF needs-restarting plugin when available.
if [[ "$REBOOT_REQUIRED" -eq 0 ]] && command -v dnf >/dev/null 2>&1; then
    if dnf needs-restarting --help >/dev/null 2>&1; then
        # dnf needs-restarting -r intentionally returns 1 when a reboot is
        # required. Run it as an if-condition so the global ERR trap does not
        # mistake that expected status for an update failure.
        if dnf needs-restarting -r >/dev/null 2>&1; then
            needs_restart_rc=0
        else
            needs_restart_rc=$?
        fi

        if [[ "$needs_restart_rc" -eq 1 ]]; then
            REBOOT_REQUIRED=1
            REBOOT_REASON="DNF reports that a reboot is required."
        elif [[ "$needs_restart_rc" -gt 1 ]]; then
            warn "Unable to determine reboot status using 'dnf needs-restarting -r'."
        fi
    fi
fi

# Kernel comparison is a useful fallback on RPM systems when the
# needs-restarting plugin is unavailable.
if [[ "$REBOOT_REQUIRED" -eq 0 ]] && command -v rpm >/dev/null 2>&1; then
    running_kernel="$(uname -r)"
    latest_kernel="$(
        rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2>/dev/null \
            | sort -V \
            | tail -n 1 \
            || true
    )"

    if [[ -n "$latest_kernel" && "$running_kernel" != "$latest_kernel" ]]; then
        REBOOT_REQUIRED=1
        REBOOT_REASON="The running kernel ($running_kernel) differs from the newest installed kernel ($latest_kernel)."
    fi
fi

log "Update summary"
printf 'Completed     : %s\n' "$(date -Is)"
printf 'Log file      : %s\n' "$LOG_FILE"

if [[ "$optional_failure" -eq 1 ]]; then
    printf 'Optional apps : One or more optional application update steps reported an error; review the warnings above.\n'
else
    printf 'Optional apps : Completed successfully or were not installed.\n'
fi

if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
    printf 'Reboot        : REQUIRED\n'
    printf 'Reason        : %s\n' "$REBOOT_REASON"

    if [[ "$AUTO_REBOOT" -eq 1 ]]; then
        log "A reboot is required; rebooting the server automatically"
        sync
        if command -v systemctl >/dev/null 2>&1; then
            systemctl reboot
        else
            reboot
        fi
    else
        cat <<EOF

A reboot is required to finish applying all updates.
Reboot when your maintenance window permits:

    sudo reboot

Automatic reboot was suppressed with --no-reboot.
EOF
    fi
else
    printf 'Reboot        : Not currently detected as required.\n'
fi

cat <<'EOF'

NOTE:
Application-specific dependency managers and deployed containers are not
blindly upgraded by this script. Updating pip/npm/Composer/Ruby dependencies
or replacing Docker/Podman container images should be handled per application
so pinned versions and production dependencies are not unexpectedly broken.
EOF

exit 0
