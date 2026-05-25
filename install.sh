#!/usr/bin/env sh
# install.sh - install/uninstall zombie-reaper. Pure POSIX sh, no make required.
#
# Usage:
#   ./install.sh              # user-scope install (default)
#   ./install.sh --system     # system-scope install (uses sudo)
#   ./install.sh --uninstall  # user-scope uninstall
#   ./install.sh --uninstall --system

set -eu

cd "$(dirname "$0")"

scope=user
action=install

while [ $# -gt 0 ]; do
    case "$1" in
        --system)    scope=system ;;
        --user)      scope=user ;;
        --uninstall) action=uninstall ;;
        -h|--help)
            sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
    esac
    shift
done

maybe_sudo() {
    if [ "$scope" = "system" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

if [ "$scope" = "user" ]; then
    prefix="${HOME}/.local"
    systemd_dir="${HOME}/.config/systemd/user"
    unit_src="systemd/user"
    enable_cmd="systemctl --user enable --now zombie-reaper.timer"
else
    prefix="/usr/local"
    systemd_dir="/etc/systemd/system"
    unit_src="systemd/system"
    enable_cmd="sudo systemctl enable --now zombie-reaper.timer"
fi

bin="${prefix}/bin/zombie-reaper"
service_dst="${systemd_dir}/zombie-reaper.service"
timer_dst="${systemd_dir}/zombie-reaper.timer"
manpage="${prefix}/share/man/man1/zombie-reaper.1"

if [ "$action" = "install" ]; then
    maybe_sudo install -d "${prefix}/bin"
    maybe_sudo install -m 0755 src/zombie-reaper.sh "$bin"
    maybe_sudo install -d "$systemd_dir"
    maybe_sudo install -m 0644 "${unit_src}/zombie-reaper.service" "$service_dst"
    maybe_sudo install -m 0644 "${unit_src}/zombie-reaper.timer"   "$timer_dst"
    maybe_sudo install -d "${prefix}/share/man/man1"
    maybe_sudo install -m 0644 man/zombie-reaper.1 "$manpage"
    echo
    echo "Installed to ${scope} scope. Enable the timer with:"
    echo "  ${enable_cmd}"
else
    if [ "$scope" = "user" ]; then
        systemctl --user disable --now zombie-reaper.timer 2>/dev/null || true
    else
        sudo systemctl disable --now zombie-reaper.timer 2>/dev/null || true
    fi
    maybe_sudo rm -f "$bin" "$service_dst" "$timer_dst" "$manpage"
    echo "Uninstalled ${scope} scope."
fi
