#!/usr/bin/python3
"""Automatic display rotation and per-mode scaling for detachable 2-in-1s.

Works around GNOME not enabling auto-rotation when the machine is booted or
logged in with the keyboard base already detached.

All machine-specific values live in the config file, not in this script:
    ~/.config/detachable-rotate/config.ini

Behaviour:
    base attached   -> orientation "normal", docked scale
    base detached   -> follow accelerometer, tablet scale

GNOME's own Auto Rotate toggle is the on/off switch. It writes
    org.gnome.settings-daemon.peripherals.touchscreen orientation-lock
and this service watches that key: locked means leave the screen alone.
"""

import configparser
import glob
import logging
import os
import signal
import subprocess
import threading
import time
from pathlib import Path

CONFIG_PATH = Path(
    os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")
) / "detachable-rotate" / "config.ini"

LOCK_SCHEMA = "org.gnome.settings-daemon.peripherals.touchscreen"
LOCK_KEY = "orientation-lock"

ORIENTATION_TO_TRANSFORM = {
    "normal": "normal",
    "bottom-up": "180",
    "left-up": "90",
    "right-up": "270",
}

running = True
rotation_locked = False
current_orientation = None
current_state = None          # (transform, scale) last applied
base_attached_previous = None
lock = threading.Lock()


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

class Config:
    def __init__(self, path):
        parser = configparser.ConfigParser()

        if not parser.read(path):
            raise SystemExit(
                f"Config not found: {path}\nRun install.sh first."
            )

        section = parser["display"]

        self.connector = section.get("connector", "eDP-1").strip()
        self.touchpad_name = section.get("touchpad_name", "").strip()
        self.docked_scale = section.get("docked_scale", "").strip()
        self.tablet_scale = section.get("tablet_scale", "").strip()
        self.poll_interval = section.getfloat("poll_interval", 1.0)

        if not self.touchpad_name:
            raise SystemExit(
                "touchpad_name is empty in the config. Re-run install.sh."
            )


# ---------------------------------------------------------------------------
# Base detection
#
# The base is considered attached when its touchpad exists in the input
# device list. The touchpad is used rather than the keyboard because on some
# detachables a keyboard node is always present even when undocked.
# ---------------------------------------------------------------------------

def input_device_names():
    names = []

    for path in glob.glob("/sys/class/input/event*/device/name"):
        try:
            names.append(Path(path).read_text().strip())
        except OSError:
            continue

    return names


def base_attached(config):
    return config.touchpad_name in input_device_names()


# ---------------------------------------------------------------------------
# Applying state
# ---------------------------------------------------------------------------

def apply_state(config, transform, scale):
    """Apply transform, and scale if one is configured for this mode."""
    global current_state

    with lock:
        if (transform, scale) == current_state:
            return

        command = [
            "gdctl", "set",
            "--logical-monitor",
            "--monitor", config.connector,
            "--primary",
            "--transform", transform,
        ]

        # An empty scale means "leave the scale alone".
        if scale:
            command.extend(["--scale", scale])
            logging.info("Applying transform %s at scale %s", transform, scale)
        else:
            logging.info("Applying transform %s (scale unchanged)", transform)

        result = subprocess.run(command, text=True, capture_output=True)

        if result.returncode != 0:
            logging.error(
                "gdctl failed with status %d: %s",
                result.returncode,
                result.stderr.strip(),
            )
            return

        current_state = (transform, scale)


def apply_for_mode(config, attached):
    """Apply the correct transform and scale for the current mode."""
    if rotation_locked:
        return

    if attached:
        apply_state(config, "normal", config.docked_scale)
        return

    transform = ORIENTATION_TO_TRANSFORM.get(current_orientation, "normal")
    apply_state(config, transform, config.tablet_scale)


# ---------------------------------------------------------------------------
# Monitors
# ---------------------------------------------------------------------------

def read_lock():
    """Return the current value of GNOME's rotation lock, or False."""
    try:
        result = subprocess.run(
            ["gsettings", "get", LOCK_SCHEMA, LOCK_KEY],
            text=True,
            capture_output=True,
        )
    except OSError:
        return False

    if result.returncode != 0:
        return False

    return result.stdout.strip() == "true"


def lock_monitor(config):
    """Follow GNOME's Auto Rotate toggle.

    `gsettings monitor` prints a line whenever the key changes, which is the
    same subprocess-and-read-lines pattern used for the accelerometer. It
    keeps this service on the standard library with no extra dependencies.
    """
    global rotation_locked

    while running:
        process = subprocess.Popen(
            ["stdbuf", "-oL", "gsettings", "monitor", LOCK_SCHEMA, LOCK_KEY],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        try:
            if process.stdout is None:
                raise RuntimeError("gsettings monitor stdout is unavailable")

            for line in process.stdout:
                if not running:
                    break

                # Lines look like: "orientation-lock: true"
                if ":" not in line:
                    continue

                value = line.split(":", 1)[1].strip()
                locked = value == "true"

                if locked == rotation_locked:
                    continue

                rotation_locked = locked
                logging.info(
                    "Rotation %s by GNOME's Auto Rotate toggle",
                    "locked" if locked else "unlocked",
                )

                # On unlock, apply the correct state at once rather than
                # waiting for the next tilt or dock change.
                if not locked:
                    apply_for_mode(config, base_attached(config))

        except Exception:
            logging.exception("Lock monitor failed")

        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()

        if running:
            logging.warning("gsettings monitor stopped; restarting in 2 seconds")
            time.sleep(2)


def base_monitor(config):
    global base_attached_previous

    while running:
        attached = base_attached(config)

        if attached != base_attached_previous:
            base_attached_previous = attached

            logging.info(
                "Base %s", "attached" if attached else "detached"
            )
            apply_for_mode(config, attached)

        time.sleep(config.poll_interval)


def sensor_monitor(config):
    global current_orientation

    while running:
        logging.info("Starting monitor-sensor")

        process = subprocess.Popen(
            ["stdbuf", "-oL", "monitor-sensor", "--accel"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        try:
            if process.stdout is None:
                raise RuntimeError("monitor-sensor stdout is unavailable")

            for line in process.stdout:
                if not running:
                    break

                line = line.strip()
                marker = "Accelerometer orientation changed:"

                if marker not in line:
                    continue

                orientation = line.split(marker, 1)[1].strip()

                if orientation not in ORIENTATION_TO_TRANSFORM:
                    logging.warning("Unknown orientation: %s", orientation)
                    continue

                current_orientation = orientation
                logging.info("Orientation: %s", orientation)

                if not base_attached(config):
                    apply_for_mode(config, False)

        except Exception:
            logging.exception("Sensor monitor failed")

        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()

        if running:
            logging.warning("monitor-sensor stopped; restarting in 2 seconds")
            time.sleep(2)


# ---------------------------------------------------------------------------

def stop_handler(signum, frame):
    global running
    running = False


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    global rotation_locked

    config = Config(CONFIG_PATH)
    rotation_locked = read_lock()

    logging.info(
        "detachable-rotate starting (connector=%s docked=%s tablet=%s)",
        config.connector,
        config.docked_scale or "unchanged",
        config.tablet_scale or "unchanged",
    )

    if rotation_locked:
        logging.info("Rotation is locked by GNOME's Auto Rotate toggle")

    for target, name in ((base_monitor, "base-monitor"),
                         (lock_monitor, "lock-monitor")):
        threading.Thread(
            target=target,
            args=(config,),
            name=name,
            daemon=True,
        ).start()

    sensor_monitor(config)

    logging.info("detachable-rotate stopped")


if __name__ == "__main__":
    main()
