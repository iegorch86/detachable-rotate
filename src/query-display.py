#!/usr/bin/python3
"""Report the connector, current scale, and supported scales from Mutter.

This asks org.gnome.Mutter.DisplayConfig directly, which is the same source
GNOME Settings uses to build its scale options. That means the list printed
here cannot disagree with what Settings offers.

Output (one key per line, for easy shell parsing):
    CONNECTOR=eDP-1
    CURRENT=1.25
    SUPPORTED=1.0 1.25 1.5 1.75 2.0

Exits non-zero on failure and explains why on stderr, so the installer can
report the real reason instead of a bare "could not query Mutter".

Run it directly any time to see your options:
    python3 query-display.py
"""

import sys

try:
    import gi
    from gi.repository import Gio, GLib
except Exception as exc:
    print(f"PyGObject not available: {exc}", file=sys.stderr)
    sys.exit(1)


def fmt(value):
    """Trim float noise while keeping a decimal place.

    1.2999999 -> 1.3      1.0 -> 1.0      2.0 -> 2.0

    The trailing ".0" matters: the installer compares what you type against
    this list, and printing a bare "1" would make a typed "1.0" look invalid.
    """
    text = f"{round(float(value), 4):g}"
    if "." not in text:
        text += ".0"
    return text


def main():
    try:
        proxy = Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION,
            Gio.DBusProxyFlags.NONE,
            None,
            "org.gnome.Mutter.DisplayConfig",
            "/org/gnome/Mutter/DisplayConfig",
            "org.gnome.Mutter.DisplayConfig",
            None,
        )
        state = proxy.call_sync(
            "GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None
        )
    except Exception as exc:
        print(f"could not reach Mutter DisplayConfig: {exc}", file=sys.stderr)
        return 1

    # GetCurrentState -> (serial, monitors, logical_monitors, properties)
    try:
        _serial, monitors, logical_monitors, _props = state.unpack()
    except Exception as exc:
        print(f"unexpected GetCurrentState reply: {exc}", file=sys.stderr)
        return 1

    # Prefer the built-in panel. Its connector normally starts with eDP.
    target = None
    for monitor in monitors:
        spec = monitor[0]          # (connector, vendor, product, serial)
        connector = spec[0]
        if connector.lower().startswith("edp"):
            target = monitor
            break
    if target is None and monitors:
        target = monitors[0]
    if target is None:
        print("no monitors reported by Mutter", file=sys.stderr)
        return 1

    connector = target[0][0]
    modes = target[1]

    # Find the currently active mode; fall back to the preferred one.
    current_mode = None
    preferred_mode = None
    for mode in modes:
        mode_props = mode[6] if len(mode) > 6 else {}
        if mode_props.get("is-current"):
            current_mode = mode
        if mode_props.get("is-preferred"):
            preferred_mode = mode
    mode = current_mode or preferred_mode or (modes[0] if modes else None)
    if mode is None:
        print(f"no modes reported for {connector}", file=sys.stderr)
        return 1

    # Mode tuple: (id, width, height, refresh, preferred_scale, supported_scales, props)
    try:
        supported = [fmt(s) for s in mode[5]]
    except Exception as exc:
        print(f"could not read supported scales: {exc}", file=sys.stderr)
        supported = []

    # Current scale comes from the logical monitor carrying this connector.
    current = ""
    for logical in logical_monitors:
        # (x, y, scale, transform, primary, monitors, properties)
        try:
            for spec in logical[5]:
                if spec[0] == connector:
                    current = fmt(logical[2])
                    break
        except Exception:
            continue
        if current:
            break

    print(f"CONNECTOR={connector}")
    print(f"CURRENT={current}")
    print(f"SUPPORTED={' '.join(supported)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
