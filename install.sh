#!/usr/bin/env bash
#
# Interactive installer for detachable-rotate.
#
# Detects your connector and base touchpad, asks which scale you want in
# docked mode and in tablet mode, writes a config file, and enables the
# user service. You should never need to edit the Python.

set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
UNIT_DIR="${HOME}/.config/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/detachable-rotate"
CONF_FILE="${CONF_DIR}/config.ini"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

say "== Checking dependencies =="

missing=()
command -v gdctl          >/dev/null 2>&1 || missing+=("gdctl (GNOME 47+)")
command -v monitor-sensor >/dev/null 2>&1 || missing+=("monitor-sensor (iio-sensor-proxy)")
command -v python3        >/dev/null 2>&1 || missing+=("python3")

if (( ${#missing[@]} )); then
    say "Missing required tools:"
    printf '  - %s\n' "${missing[@]}"
    die "Install them and re-run."
fi

# The service itself is pure standard library. PyGObject is only needed by
# query-display.py, which reads your supported scales straight from Mutter.
# Without it the installer still works, but it cannot show you the scale list.
if ! python3 -c "import gi; from gi.repository import Gio" >/dev/null 2>&1; then
    warn "PyGObject (python3 'gi' module) not found."
    say  "Without it the installer cannot list your supported scale values."
    say  "  Fedora:        sudo dnf install python3-gobject"
    say  "  Debian/Ubuntu: sudo apt install python3-gi"
    say  "  Arch:          sudo pacman -S python-gobject"
    say
    read -rp "Continue without the scale list? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || die "Install PyGObject and re-run."
    say
fi

say "All dependencies present."
say

# ---------------------------------------------------------------------------
# Existing install: offer to change only the scales, so nobody has to redo
# the attach/detach detection just to adjust a number.
# ---------------------------------------------------------------------------

SCALES_ONLY=0
OLD_DOCKED=""
OLD_TABLET=""

if [[ -f "${CONF_FILE}" ]]; then
    say "== Existing configuration found =="

    read_conf() {
        sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "${CONF_FILE}" \
            | head -n1
    }

    OLD_CONNECTOR="$(read_conf connector)"
    OLD_TOUCHPAD="$(read_conf touchpad_name)"
    OLD_DOCKED="$(read_conf docked_scale)"
    OLD_TABLET="$(read_conf tablet_scale)"

    say "  Connector:     ${OLD_CONNECTOR:-unset}"
    say "  Base device:   ${OLD_TOUCHPAD:-unset}"
    say "  Docked scale:  ${OLD_DOCKED:-unchanged}"
    say "  Tablet scale:  ${OLD_TABLET:-unchanged}"
    say
    say "  1) Change the scales only, keep the detected hardware"
    say "  2) Redo everything from scratch"
    say "  3) Quit and change nothing"
    say

    while true; do
        read -rp "Choice [1]: " choice
        case "${choice:-1}" in
            1)
                if [[ -z "${OLD_CONNECTOR}" || -z "${OLD_TOUCHPAD}" ]]; then
                    warn "Saved hardware is incomplete. Running full setup."
                    break
                fi
                SCALES_ONLY=1
                CONNECTOR="${OLD_CONNECTOR}"
                TOUCHPAD_NAME="${OLD_TOUCHPAD}"
                break
                ;;
            2) break ;;
            3) say "Nothing changed."; exit 0 ;;
            *) say "Enter 1, 2 or 3." ;;
        esac
    done
    say
fi


# ---------------------------------------------------------------------------
# Connector
# ---------------------------------------------------------------------------

if (( SCALES_ONLY == 0 )); then

say "== Display =="

# Ask Mutter directly. This is the same source GNOME Settings uses, so the
# scale list below cannot disagree with what Settings shows you.
QUERY="${SRC_DIR}/src/query-display.py"
DETECTED_CONNECTOR=""
CURRENT_SCALE=""
SUPPORTED_SCALES=""

# Invoked through python3 rather than executed directly: downloaded files
# never keep their executable bit, and requiring it silently disabled this
# whole query.
query_err=""
if [[ -f "${QUERY}" ]]; then
    if query_out="$(python3 "${QUERY}" 2>/tmp/dr-query-err.$$)"; then
        DETECTED_CONNECTOR="$(sed -n 's/^CONNECTOR=//p' <<<"${query_out}")"
        CURRENT_SCALE="$(   sed -n 's/^CURRENT=//p'     <<<"${query_out}")"
        SUPPORTED_SCALES="$(sed -n 's/^SUPPORTED=//p'   <<<"${query_out}")"
    else
        query_err="$(cat /tmp/dr-query-err.$$ 2>/dev/null)"
    fi
    rm -f /tmp/dr-query-err.$$
else
    query_err="not found at ${QUERY}"
fi

if [[ -z "${DETECTED_CONNECTOR}" ]]; then
    warn "Could not query Mutter. Falling back to gdctl text output."
    [[ -n "${query_err}" ]] && say "  reason: ${query_err}"
    DETECTED_CONNECTOR="$(gdctl show 2>/dev/null \
        | grep -oE 'eDP-[0-9]+' | head -n1 || true)"
fi

if [[ -n "${DETECTED_CONNECTOR}" ]]; then
    read -rp "Internal display detected as '${DETECTED_CONNECTOR}'. Use it? [Y/n] " ans
    [[ "${ans,,}" == "n" ]] && DETECTED_CONNECTOR=""
fi

if [[ -z "${DETECTED_CONNECTOR}" ]]; then
    say "Connectors reported by gdctl:"
    gdctl show 2>/dev/null | grep -iE 'monitor|connector' || true
    read -rp "Enter the connector name for the internal panel: " DETECTED_CONNECTOR
    [[ -n "${DETECTED_CONNECTOR}" ]] || die "No connector given."
fi

CONNECTOR="${DETECTED_CONNECTOR}"
say "Using connector: ${CONNECTOR}"
say

fi   # end of full-setup display detection

# ---------------------------------------------------------------------------
# Touchpad detection by attach/detach diff
#
# Keyboard nodes are unreliable on detachables (some are always present).
# The base touchpad only exists while the base is physically attached, so we
# diff the input device list between the two states.
# ---------------------------------------------------------------------------

if (( SCALES_ONLY == 0 )); then

say "== Base detection =="
say "We need to learn which input device disappears when you detach the base."
say

snapshot() {
    local f
    for f in /sys/class/input/event*/device/name; do
        [[ -r "${f}" ]] && cat "${f}"
    done | sort -u
}

read -rp "ATTACH the keyboard base, then press Enter..." _
attached_list="$(snapshot)"

read -rp "Now DETACH the keyboard base, then press Enter..." _
detached_list="$(snapshot)"

mapfile -t gone < <(comm -23 \
    <(printf '%s\n' "${attached_list}") \
    <(printf '%s\n' "${detached_list}"))

TOUCHPAD_NAME=""

if (( ${#gone[@]} == 0 )); then
    warn "No device disappeared. Detection failed."
    say "Devices seen while attached:"
    printf '  %s\n' "${attached_list}"
    read -rp "Type the exact name of the base touchpad: " TOUCHPAD_NAME
elif (( ${#gone[@]} == 1 )); then
    TOUCHPAD_NAME="${gone[0]}"
    say "Detected base device: ${TOUCHPAD_NAME}"
else
    say "Several devices disappeared. Pick the touchpad:"
    select choice in "${gone[@]}"; do
        [[ -n "${choice}" ]] && { TOUCHPAD_NAME="${choice}"; break; }
    done
fi

[[ -n "${TOUCHPAD_NAME}" ]] || die "No base device chosen."
say

fi   # end of full-setup base detection

# In scales-only mode we still need the current and supported scales, since
# the display-detection block above was skipped.
if (( SCALES_ONLY == 1 )); then
    QUERY="${SRC_DIR}/src/query-display.py"
    CURRENT_SCALE=""
    SUPPORTED_SCALES=""
    if [[ -f "${QUERY}" ]]; then
        if query_out="$(python3 "${QUERY}" 2>/tmp/dr-query-err.$$)"; then
            CURRENT_SCALE="$(   sed -n 's/^CURRENT=//p'   <<<"${query_out}")"
            SUPPORTED_SCALES="$(sed -n 's/^SUPPORTED=//p' <<<"${query_out}")"
        else
            warn "Could not query Mutter for scales."
            say  "  reason: $(cat /tmp/dr-query-err.$$ 2>/dev/null)"
        fi
        rm -f /tmp/dr-query-err.$$
    fi
    say "Keeping connector ${CONNECTOR} and base device ${TOUCHPAD_NAME}."
    say
fi

# ---------------------------------------------------------------------------
# Scales
# ---------------------------------------------------------------------------

say "== Scaling =="
say "Touch targets want a larger scale than a mouse and keyboard do."
say "You can set a different scale for docked mode and tablet mode."
say

if [[ -n "${CURRENT_SCALE}" ]]; then
    say "Your current scale:    ${CURRENT_SCALE}"
else
    warn "Could not read your current scale."
fi

if [[ -n "${SUPPORTED_SCALES}" ]]; then
    say "Supported by this panel: ${SUPPORTED_SCALES}"
    say
    say "Enter one of the supported values. Anything else will be rejected"
    say "by GNOME and the rotation will be skipped."
else
    warn "Could not list supported scales."
    say "Check Settings > Displays > Scale to see your options, or run:"
    say "  python3 ${SRC_DIR}/src/query-display.py"
fi

say
say "Leave an answer EMPTY to leave the scale alone in that mode."
say "Note: empty means the scale is never touched in that mode, so it will"
say "not be restored when you switch back. Set both to swap between them."
say

valid_scale() {
    # Empty is allowed and means "do not change the scale".
    [[ -z "$1" ]] && return 0
    # If we could not read the supported list, accept anything.
    [[ -z "${SUPPORTED_SCALES}" ]] && return 0
    # Compare numerically, not as text, so "1" and "1.0" both match.
    local candidate
    for candidate in ${SUPPORTED_SCALES}; do
        if awk -v a="$1" -v b="${candidate}" \
            'BEGIN { exit !(a+0 == b+0) }' 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

ask_scale() {
    # $1 = prompt, $2 = default. Echoes the chosen value.
    local prompt="$1" default="$2" value
    while true; do
        read -rp "${prompt}" value
        value="${value:-${default}}"
        if valid_scale "${value}"; then
            printf '%s' "${value}"
            return 0
        fi
        printf 'Not a supported value. Choose from: %s\n' \
            "${SUPPORTED_SCALES}" >&2
    done
}

DOCKED_DEFAULT="${OLD_DOCKED:-${CURRENT_SCALE}}"
TABLET_DEFAULT="${OLD_TABLET:-}"

DOCKED_SCALE="$(ask_scale \
    "Scale when the base is ATTACHED [${DOCKED_DEFAULT:-leave alone}]: " \
    "${DOCKED_DEFAULT}")"

TABLET_SCALE="$(ask_scale \
    "Scale when the base is DETACHED, tablet mode [${TABLET_DEFAULT:-leave alone}]: " \
    "${TABLET_DEFAULT}")"

say
say "Docked scale: ${DOCKED_SCALE:-unchanged}"
say "Tablet scale: ${TABLET_SCALE:-unchanged}"
say

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

say "== Installing =="

mkdir -p "${BIN_DIR}" "${UNIT_DIR}" "${CONF_DIR}"

install -m 0755 "${SRC_DIR}/src/detachable-rotate.py" \
    "${BIN_DIR}/detachable-rotate.py"

install -m 0644 "${SRC_DIR}/systemd/detachable-rotate.service" \
    "${UNIT_DIR}/detachable-rotate.service"

if [[ -f "${CONF_FILE}" ]]; then
    cp -a "${CONF_FILE}" "${CONF_FILE}.bak"
    say "Existing config backed up to ${CONF_FILE}.bak"
fi

cat > "${CONF_FILE}" <<EOF
# detachable-rotate configuration
#
# docked_scale / tablet_scale: leave empty to not change the scale.
# Re-run install.sh to regenerate, or edit these values and restart:
#   systemctl --user restart detachable-rotate.service

[display]
connector = ${CONNECTOR}
touchpad_name = ${TOUCHPAD_NAME}
docked_scale = ${DOCKED_SCALE}
tablet_scale = ${TABLET_SCALE}
poll_interval = 1.0
EOF

chmod 0644 "${CONF_FILE}"

say "Config written to ${CONF_FILE}"

systemctl --user daemon-reload
systemctl --user enable --now detachable-rotate.service

say
say "== Done =="
say "Status:  systemctl --user status detachable-rotate.service"
say "Logs:    journalctl --user -u detachable-rotate.service -f"
say "Remove:  ./uninstall.sh"
