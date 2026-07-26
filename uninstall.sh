#!/usr/bin/env bash
#
# Remove detachable-rotate. Config is kept unless you ask for it to go.

set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${HOME}/.config/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/detachable-rotate"

say() { printf '%s\n' "$*"; }

say "== Stopping service =="
systemctl --user disable --now detachable-rotate.service 2>/dev/null || true

say "== Removing files =="
rm -f "${UNIT_DIR}/detachable-rotate.service"
rm -f "${BIN_DIR}/detachable-rotate.py"
# Older versions installed a copy of the query helper. Clean it up.
rm -f "${BIN_DIR}/detachable-rotate-query.py"

systemctl --user daemon-reload

if [[ -d "${CONF_DIR}" ]]; then
    read -rp "Also delete your config at ${CONF_DIR}? [y/N] " ans
    if [[ "${ans,,}" == "y" ]]; then
        rm -rf "${CONF_DIR}"
        say "Config removed."
    else
        say "Config kept at ${CONF_DIR}"
    fi
fi

say
say "== Done =="
say "Your display is left at whatever transform and scale it currently has."
say "Adjust it in Settings > Displays if needed."
