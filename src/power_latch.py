#!/usr/bin/env python3
from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from threading import Lock
from typing import NoReturn

DEFAULT_CONFIG_PATH = "/etc/power-latch/power-latch.conf"


@dataclass(frozen=True)
class Config:
    shutdown_button_pin: int = 27
    reboot_button_pin: int = 22
    poweroff_pin: int = 17
    hold_time_to_shutdown: float = 0.001
    hold_time_to_reboot: float = 0.001
    bounce_time: float | None = None
    pull_up: bool = True
    log_level: str = "INFO"

    def validate(self) -> None:
        pins = {
            "SHUTDOWN_BUTTON_PIN": self.shutdown_button_pin,
            "REBOOT_BUTTON_PIN": self.reboot_button_pin,
            "POWEROFF_PIN": self.poweroff_pin,
        }
        for name, pin in pins.items():
            if pin < 0 or pin > 40:
                raise ValueError(f"{name} is out of range: {pin}")

        values = [
            self.shutdown_button_pin,
            self.reboot_button_pin,
            self.poweroff_pin,
        ]
        if len(set(values)) != 3:
            raise ValueError(
                "SHUTDOWN_BUTTON_PIN, REBOOT_BUTTON_PIN, and POWEROFF_PIN must be unique"
            )

        if self.hold_time_to_shutdown <= 0 or self.hold_time_to_reboot <= 0:
            raise ValueError("hold times must be greater than zero")


def _parse_bool(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _parse_bounce(value: str) -> float | None:
    number = float(value)
    if number <= 0:
        return None
    return number


def load_kv_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.is_file():
        return data

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()

    return data


def load_config() -> Config:
    path = Path(os.environ.get("POWER_LATCH_CONFIG", DEFAULT_CONFIG_PATH))
    file_values = load_kv_file(path)

    def pick(key: str, default: str) -> str:
        env_value = os.environ.get(key)
        if env_value:
            return env_value
        return file_values.get(key, default)

    config = Config(
        shutdown_button_pin=int(pick("SHUTDOWN_BUTTON_PIN", "27")),
        reboot_button_pin=int(pick("REBOOT_BUTTON_PIN", "22")),
        poweroff_pin=int(pick("POWEROFF_PIN", "17")),
        hold_time_to_shutdown=float(pick("HOLD_TIME_SHUTDOWN", "0.001")),
        hold_time_to_reboot=float(pick("HOLD_TIME_REBOOT", "0.001")),
        bounce_time=_parse_bounce(pick("BOUNCE_TIME", "0")),
        pull_up=_parse_bool(pick("BUTTON_PULL_UP", "1")),
        log_level=pick("LOG_LEVEL", "INFO").upper(),
    )
    config.validate()
    return config


LOGGER = logging.getLogger("power-latch")


class PowerController:
    def __init__(self, config: Config) -> None:
        from gpiozero import Button

        self.config = config
        self._shutdown_started = False
        self._reboot_started = False
        self._shutdown_lock = Lock()
        self._reboot_lock = Lock()

        self.shutdown_button = Button(
            config.shutdown_button_pin,
            pull_up=config.pull_up,
            hold_time=config.hold_time_to_shutdown,
            bounce_time=config.bounce_time,
        )
        self.shutdown_button.when_held = self._on_shutdown_button_held

        self.reboot_button = Button(
            config.reboot_button_pin,
            pull_up=config.pull_up,
            hold_time=config.hold_time_to_reboot,
            bounce_time=config.bounce_time,
        )
        self.reboot_button.when_held = self._on_reboot_button_held

    def _on_shutdown_button_held(self) -> None:
        with self._shutdown_lock:
            if self._shutdown_started:
                LOGGER.debug("Shutdown already in progress; ignoring event")
                return
            self._shutdown_started = True

        LOGGER.warning(
            "Shutdown button held for %.3f seconds; initiating clean system shutdown",
            self.config.hold_time_to_shutdown,
        )

        try:
            subprocess.run(["systemctl", "poweroff"], check=True)
        except FileNotFoundError:
            LOGGER.exception("systemctl was not found")
        except subprocess.CalledProcessError as exc:
            LOGGER.exception(
                "System shutdown command failed with exit code %d",
                exc.returncode,
            )
        except Exception:
            LOGGER.exception("Unexpected error while initiating shutdown")

    def _on_reboot_button_held(self) -> None:
        with self._reboot_lock:
            if self._reboot_started:
                LOGGER.debug("Reboot already in progress; ignoring event")
                return
            self._reboot_started = True

        LOGGER.warning(
            "Reboot button held for %.3f seconds; initiating clean system reboot",
            self.config.hold_time_to_reboot,
        )

        try:
            subprocess.run(["systemctl", "reboot"], check=True)
        except FileNotFoundError:
            LOGGER.exception("systemctl was not found")
        except subprocess.CalledProcessError as exc:
            LOGGER.exception(
                "System reboot command failed with exit code %d",
                exc.returncode,
            )
        except Exception:
            LOGGER.exception("Unexpected error while initiating reboot")

    def start(self) -> NoReturn:
        LOGGER.info(
            "Starting power controller (shutdown=GPIO%d, reboot=GPIO%d, "
            "poweroff=GPIO%d, shutdown_hold=%.3fs, reboot_hold=%.3fs)",
            self.config.shutdown_button_pin,
            self.config.reboot_button_pin,
            self.config.poweroff_pin,
            self.config.hold_time_to_shutdown,
            self.config.hold_time_to_reboot,
        )
        LOGGER.info(
            "Monitoring shutdown and reboot buttons; gpio-poweroff drives the latch pin"
        )

        try:
            signal.pause()
        except KeyboardInterrupt:
            LOGGER.info("Interrupted by user")
        finally:
            self.stop()

        sys.exit(0)

    def stop(self) -> None:
        LOGGER.info("Stopping power controller")

        try:
            self.shutdown_button.close()
        except Exception:
            LOGGER.exception("Failed to close shutdown button GPIO")

        try:
            self.reboot_button.close()
        except Exception:
            LOGGER.exception("Failed to close reboot button GPIO")

        LOGGER.info("Power controller stopped")


_controller: PowerController | None = None


def handle_signal(signum: int, _frame: object) -> None:
    signal_name = signal.Signals(signum).name
    LOGGER.info("Received %s; shutting down controller", signal_name)

    if _controller is not None:
        _controller.stop()

    sys.exit(0)


def main() -> NoReturn:
    global _controller

    try:
        config = load_config()
    except Exception as exc:
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
        LOGGER.exception("Failed to load configuration: %s", exc)
        sys.exit(1)

    logging.basicConfig(
        level=getattr(logging, config.log_level, logging.INFO),
        format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        _controller = PowerController(config)
        _controller.start()
    except Exception:
        LOGGER.exception("Fatal error in power controller")
        if _controller is not None:
            try:
                _controller.stop()
            except Exception:
                LOGGER.exception("Failed during emergency cleanup")
        sys.exit(1)


if __name__ == "__main__":
    main()
