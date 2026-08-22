# Power Latch

Controller for a Raspberry Pi power-latch board. Two GPIOs read the shutdown and reboot buttons. A third GPIO is driven by the kernel `gpio-poweroff` overlay at the last step of shutdown so the board can cut power.

Default BCM pins:

| Function | BCM GPIO | Physical pin |
| --- | ---: | ---: |
| Shutdown button | 27 | 13 |
| Reboot button | 22 | 15 |
| Latch poweroff | 17 | 11 |

Buttons are wired from the GPIO to GND. The daemon uses internal pull-ups. The latch pin is not driven by the Python service. The kernel asserts it only during `poweroff` / `halt`.

## Requirements

- Raspberry Pi OS, Debian, or Ubuntu on a Raspberry Pi
- Root access
- `python3`, `python3-gpiozero`, and `python3-lgpio` (installed by the script)
- systemd

## Install

```bash
bash <(curl -Ls https://raw.githubusercontent.com/M-H-Boroumandnia/latch/main/install.sh)
```

From a local clone:

```bash
sudo ./install.sh
```

The installer:

1. Installs Python GPIO packages
2. Copies the daemon to `/opt/power-latch`
3. Writes `/etc/power-latch/power-latch.conf` if it does not already exist
4. Installs and enables `power-latch.service`
5. Adds a managed `gpio-poweroff` block to `/boot/firmware/config.txt` (or `/boot/config.txt`)
6. Installs the `power-latch` command

A reboot is required once after the first install so the overlay is loaded.

## Manage

```bash
sudo power-latch
```

The menu can start, stop, and restart the service, enable or disable autostart, show logs, show or edit the configuration, update from GitHub, and uninstall.

The same actions are available as commands:

```text
power-latch start
power-latch stop
power-latch restart
power-latch status
power-latch enable
power-latch disable
power-latch log
power-latch config
power-latch edit
power-latch update
power-latch uninstall
```

## Configuration

File: `/etc/power-latch/power-latch.conf`

```text
SHUTDOWN_BUTTON_PIN=27
REBOOT_BUTTON_PIN=22
POWEROFF_PIN=17
POWEROFF_ACTIVE_HIGH=1
HOLD_TIME_SHUTDOWN=0.001
HOLD_TIME_REBOOT=0.001
BOUNCE_TIME=0
BUTTON_PULL_UP=1
LOG_LEVEL=INFO
```

All three pins must be unique. `POWEROFF_PIN` is reserved for the kernel overlay and must not be claimed by the daemon. After changing the poweroff pin or polarity, reboot.

Use `sudo power-latch edit` to change the file, re-apply the overlay, and restart the service.

## How it works

1. Pressing the shutdown button runs `systemctl poweroff`.
2. Pressing the reboot button runs `systemctl reboot`.
3. At the end of a clean poweroff, the kernel drives GPIO 17 high (`active_high=1`).
4. The latch board sees that signal and removes supply power.

Reboot does not use the overlay, so the board should keep power applied.

The installer writes this block into the boot firmware file:

```text
# power-latch begin
dtoverlay=gpio-poweroff,gpiopin=17,active_high=1
# power-latch end
```

An existing unmarked `dtoverlay=gpio-poweroff` line is replaced by that block. A one-time backup is stored as `config.txt.power-latch.bak` next to the boot file.

## Installed paths

| Path | Role |
| --- | --- |
| `/opt/power-latch/power_latch.py` | GPIO daemon |
| `/opt/power-latch/power-latch.sh` | Management script |
| `/opt/power-latch/VERSION` | Installed version |
| `/usr/bin/power-latch` | Menu and commands |
| `/etc/power-latch/power-latch.conf` | Pin and timing settings |
| `/etc/systemd/system/power-latch.service` | systemd unit |

Logs: `journalctl -u power-latch -e`

## Update

From the menu choose Update, or:

```bash
sudo power-latch update
```

The existing configuration file is kept.

## Uninstall

From the menu choose Uninstall, or:

```bash
sudo power-latch uninstall
```

The service, `/opt/power-latch`, and `/usr/bin/power-latch` are removed. The overlay block is removed from the boot firmware file. You can keep or delete `/etc/power-latch`. Reboot afterward so the overlay is fully cleared.

## Repository layout

```text
install.sh
power-latch.sh
VERSION
config/power-latch.conf
src/power_latch.py
systemd/power-latch.service
```

## Notes

- BCM numbering is used, not physical header numbers.
- `gpio-poweroff` only fires on poweroff or halt. Use `systemctl poweroff`, not reboot, when you want the latch to cut power.
- If the service fails to start, check `journalctl -u power-latch -e` and confirm the pins are free.
- Set `POWER_LATCH_FORCE=1` only if you are installing on a non-Pi system for testing.
