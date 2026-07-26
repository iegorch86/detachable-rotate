# detachable-rotate

Automatic display rotation and per-mode scaling for detachable 2-in-1 laptops
running GNOME on Wayland.

Developed on a Dell Latitude 7210 2-in-1, but nothing in it is hardware
specific: the installer detects your machine rather than hardcoding it.

---

## The problem

GNOME decides two different things from two different signals:

| Decision | Signal | Result when booted detached |
| --- | --- | --- |
| Show the Auto Rotate toggle? | Is there an accelerometer? | Yes, toggle appears |
| Actually rotate the screen? | Is the machine in tablet mode? | No, rotation is dead |

Tablet mode comes from an `SW_TABLET_MODE` switch that is only reported **on
transition**, when you physically attach or detach the base. Boot or log in
with the base already off and that transition never happens, so GNOME still
thinks it is a laptop.

The symptom: the rotation toggle is there and clickable, but the screen never
rotates. Attach the base and detach it again and rotation starts working.

This service sidesteps tablet mode entirely and drives the display directly.

---

## What it does

- Detects the base by watching for its **touchpad** in `/sys/class/input`.
  The touchpad only exists while the base is attached. Keyboard nodes are
  unreliable, since some detachables keep one present even when undocked.
- Reads orientation from `monitor-sensor` (iio-sensor-proxy).
- Applies transform and scale with `gdctl`.

| Mode | Orientation | Scale |
| --- | --- | --- |
| Base attached | Forced `normal` | Your docked scale |
| Base detached | Follows accelerometer | Your tablet scale |

### Why two scales

Touch targets need more room than a mouse pointer does. A scale that is
comfortable with a keyboard and touchpad is usually too small for fingers, so
you can set a larger one for tablet mode.

The idea is borrowed from TUXEDO OS, where folding the keyboard back enlarges
the interface automatically. GNOME has no equivalent built in.

### GNOME's Auto Rotate toggle turns it off

The service honours GNOME's own rotation lock:

```
org.gnome.settings-daemon.peripherals.touchscreen orientation-lock
```

That is the key GNOME's Auto Rotate toggle writes to. So switching Auto Rotate
off in Quick Settings stops the service from rotating or rescaling, and
switching it back on resumes it. No extra toggle, no extension — the control
you already have works.

---

## Requirements

- GNOME on Wayland, version 47 or newer (for `gdctl`)
- `iio-sensor-proxy` (provides `monitor-sensor`)
- `python3`
- PyGObject, optional — only used by the installer to read your supported
  scale values (`python3-gobject` on Fedora, `python3-gi` on Debian/Ubuntu,
  `python-gobject` on Arch)

---

## Install

```bash
git clone https://github.com/iegorch86/detachable-rotate.git
cd detachable-rotate
./install.sh
```

The installer will:

1. Check dependencies.
2. Detect your internal panel connector, usually `eDP-1`.
3. **Learn your base device**: it asks you to attach the base, then detach it,
   and diffs the input device list. Whatever disappeared is your base.
4. Show your current scale and the values your panel supports, then ask for a
   docked scale and a tablet scale.
5. Write `~/.config/detachable-rotate/config.ini`.
6. Enable and start the user service.

You should never need to edit the Python.

---

## Changing your scales later

Run the installer again:

```bash
./install.sh
```

It finds your existing config and offers to change **only the scales**, keeping
the hardware it already detected. No need to repeat the attach/detach step, and
no need to uninstall.

---

## Configuration

`~/.config/detachable-rotate/config.ini`

```ini
[display]
connector = eDP-1
touchpad_name = Alps Alps Touchpad
docked_scale = 1.25
tablet_scale = 1.3333
poll_interval = 1.0
```

After editing by hand:

```bash
systemctl --user restart detachable-rotate.service
```

Two things worth knowing about scales:

- **Leaving one empty means that mode never touches the scale.** It will not be
  restored when you switch back, so set both if you want them to swap.
- **Only values your panel supports will work.** Rejected values are logged and
  the rotation is skipped. To see your options:
  ```bash
  python3 src/query-display.py
  ```

---

## Usage

```bash
systemctl --user status detachable-rotate.service     # is it running
journalctl --user -u detachable-rotate.service -f     # watch it work
```

To turn rotation off, use GNOME's Auto Rotate toggle in Quick Settings.

---

## Uninstall

```bash
./uninstall.sh
```

Removes the service and script, and asks whether to keep your config.

---

## Why a service and not a GNOME extension

The interfaces this service uses — `gdctl`, `monitor-sensor`, `/sys`, gsettings
— are stable and do not change with GNOME releases. GNOME Shell's JavaScript
API is versioned strictly, and an extension refuses to load on a shell version
it does not declare support for.

After a major GNOME upgrade it is worth checking whether rotation now works
natively. If upstream fixes the boot-detached case, this is no longer needed:

```bash
systemctl --user stop detachable-rotate.service
# reboot with the base detached and test rotation
# still broken? turn it back on:
systemctl --user start detachable-rotate.service
```

---

## Multiple users

This is a user service, installed per account. Rotation has to be applied to a
specific logged-in session, since `gdctl` talks to that session's Mutter, so a
system-wide root service would have no display to act on.

If two people share the tablet, each runs `./install.sh` once under their own
account and picks their own scales.

---

## Known limitations

- **The GDM login screen is not rotated.** This is a user service, so it starts
  after login.
- **Polling.** The base state is polled once per second rather than driven by
  events, because the event that would be correct to use is the broken one.
- **One internal display.** Multi-monitor setups are not handled.
- **After a dock cycle GNOME's own rotation wakes up** and may rotate too. Both
  apply the same transform, so the visible result is the same, but only this
  service applies your tablet scale.

---

## Tested on

Dell Latitude 7210 2-in-1, GNOME 50 on Fedora, Wayland.

It should work on any GNOME detachable, since the installer detects your
hardware. If it does not work on yours, open an issue with the output of
`python3 src/query-display.py` and the name of your device.

---

## License

MIT
