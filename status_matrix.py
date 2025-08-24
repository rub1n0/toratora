import os
import time
import threading
import logging
import shutil
import subprocess
import math
from dataclasses import dataclass, field
from typing import Tuple, Optional, Dict, Any

try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover - fallback minimal yaml
    yaml = None

logger = logging.getLogger(__name__)


class DummyUnicorn:
    """Fallback object used when Unicorn HAT is not available."""

    def __init__(self):
        self.brightness_value = 0.5
        logger.info("Unicorn HAT not detected; using dummy display")

    def set_layout(self, *_args, **_kwargs):
        pass

    def set_pixel(self, *_args, **_kwargs):
        pass

    def show(self):
        pass

    def brightness(self, value):
        self.brightness_value = value

    def clear(self):
        pass


@dataclass
class Config:
    device: str = "auto"
    iface: str = "auto"
    frame_ms: int = 80
    brightness: float = 0.35
    poll_interval_s: float = 1.0
    tor: Dict[str, Any] = field(default_factory=dict)
    ap: Dict[str, Any] = field(default_factory=dict)
    traffic: Dict[str, Any] = field(default_factory=dict)
    pi_health: Dict[str, Any] = field(default_factory=dict)
    colors: Dict[str, Tuple[int, int, int]] = field(default_factory=dict)


class StatusMatrix:
    """High level controller for the Unicorn HAT status matrix."""

    def __init__(self, config_path: Optional[str] = None, config: Optional[Config] = None):
        self.config = config or self._load_config(config_path)
        self._init_device()
        self.running = False
        self.lock = threading.Lock()
        self.state: Dict[str, Any] = {
            "pi": {},
            "tor": {},
            "ap": {},
            "traffic": {"level": 0},
        }
        self.overrides: Dict[str, Dict[str, Any]] = {}

    # ------------------------------------------------------------------
    # Initialisation helpers
    # ------------------------------------------------------------------
    def _load_config(self, path: Optional[str]) -> Config:
        data = {}
        if path and os.path.exists(path) and yaml:
            with open(path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f) or {}
        return Config(**data)

    def _init_device(self):
        self.hd = False
        uh = None
        if self.config.device in ("auto", "unicorn_hat"):
            try:  # pragma: no cover - requires hardware
                import unicornhat as uh_mod
                uh = uh_mod
            except Exception:
                pass
        if uh is None and self.config.device in ("auto", "unicorn_hat_hd"):
            try:  # pragma: no cover - requires hardware
                import unicornhathd as uh_mod
                uh = uh_mod
                self.hd = True
            except Exception:
                pass
        if uh is None:
            self.uh = DummyUnicorn()
        else:  # pragma: no cover - hardware path
            self.uh = uh
            if self.hd:
                self.uh.set_layout("auto")
        self.uh.brightness(self.config.brightness)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------
    def start(self):
        if self.running:
            return
        self.running = True
        self.poll_thread = threading.Thread(target=self._poll_loop, daemon=True)
        self.render_thread = threading.Thread(target=self._render_loop, daemon=True)
        self.poll_thread.start()
        self.render_thread.start()

    def stop(self):
        self.running = False
        for t in (getattr(self, "poll_thread", None), getattr(self, "render_thread", None)):
            if t:
                t.join(timeout=1)
        self.clear()

    def clear(self):
        self.uh.clear()
        self.uh.show()

    def set_override(self, q: str, color: Tuple[int, int, int], mode: str = "solid", persist: bool = False, duration: float = 5.0):
        with self.lock:
            expiry = None if persist else time.time() + duration
            self.overrides[q] = {"color": color, "mode": mode, "expiry": expiry}

    def clear_override(self, q: str):
        with self.lock:
            self.overrides.pop(q, None)

    # ------------------------------------------------------------------
    # Polling
    # ------------------------------------------------------------------
    def _poll_loop(self):
        interval = self.config.poll_interval_s
        while self.running:
            start = time.time()
            try:
                self._poll()
            except Exception as exc:  # pragma: no cover - logging only
                logger.exception("poll error: %s", exc)
            elapsed = time.time() - start
            time.sleep(max(0, interval - elapsed))

    def _poll(self):
        pi = {
            "temp": self._read_cpu_temp(),
            "load": os.getloadavg()[0],
            "disk": shutil.disk_usage("/").used / shutil.disk_usage("/").total * 100.0,
        }
        tor = {"active": self._systemd_active("tor")}
        ap_iface = self.config.ap.get("iface", "wlan0")
        ap = {
            "active": all(self._systemd_active(s) for s in self.config.ap.get("service_names", [])),
            "clients": self._count_ap_clients(ap_iface) if ap_iface else 0,
        }
        traffic = {"level": self._read_traffic_level(self._get_iface())}
        with self.lock:
            self.state["pi"] = pi
            self.state["tor"] = tor
            self.state["ap"] = ap
            self.state["traffic"] = traffic

    def _read_cpu_temp(self) -> float:
        try:
            with open("/sys/class/thermal/thermal_zone0/temp", "r", encoding="utf-8") as f:
                return float(f.read()) / 1000.0
        except Exception:
            return 0.0

    def _systemd_active(self, service: str) -> bool:
        try:
            result = subprocess.run(["systemctl", "is-active", service], check=False, capture_output=True, text=True, timeout=0.5)
            return result.stdout.strip() == "active"
        except Exception:
            return False

    def _count_ap_clients(self, iface: str) -> int:
        try:
            result = subprocess.run(["iw", "dev", iface, "station", "dump"], check=False, capture_output=True, text=True, timeout=0.5)
            return sum(1 for line in result.stdout.splitlines() if line.strip().startswith("Station"))
        except Exception:
            return 0

    def _get_iface(self) -> str:
        if self.config.iface != "auto":
            return self.config.iface
        # auto detect via default route
        try:
            result = subprocess.run(["ip", "route", "show", "default"], capture_output=True, text=True, timeout=0.5)
            parts = result.stdout.strip().split()
            idx = parts.index("dev") + 1
            return parts[idx]
        except Exception:
            return "wlan0"

    def _read_iface_bytes(self, iface: str) -> Tuple[int, int]:
        try:
            with open(f"/sys/class/net/{iface}/statistics/rx_bytes", "r", encoding="utf-8") as f:
                rx = int(f.read())
            with open(f"/sys/class/net/{iface}/statistics/tx_bytes", "r", encoding="utf-8") as f:
                tx = int(f.read())
            return rx, tx
        except Exception:
            return 0, 0

    def _read_traffic_level(self, iface: str) -> int:
        buckets = self.config.traffic.get("buckets_kbps", [64, 256, 1024])
        rx1, tx1 = self._read_iface_bytes(iface)
        time.sleep(0.1)
        rx2, tx2 = self._read_iface_bytes(iface)
        delta = (rx2 - rx1) + (tx2 - tx1)
        kbps = delta * 8 / 1000 / 0.1
        for i, b in enumerate(buckets, start=1):
            if kbps <= b:
                return i
        return len(buckets) + 1

    # ------------------------------------------------------------------
    # Rendering
    # ------------------------------------------------------------------
    def _render_loop(self):
        frame = self.config.frame_ms / 1000.0
        while self.running:
            start = time.time()
            with self.lock:
                state = {k: v.copy() if isinstance(v, dict) else v for k, v in self.state.items()}
                overrides = self.overrides.copy()
            self._render(state, overrides, start)
            self.uh.show()
            elapsed = time.time() - start
            time.sleep(max(0, frame - elapsed))

    def _render(self, state: Dict[str, Any], overrides: Dict[str, Any], now: float):
        self.uh.clear()
        self._render_pi(state["pi"], overrides.get("pi"), now)
        self._render_tor(state["tor"], overrides.get("tor"), now)
        self._render_ap(state["ap"], overrides.get("ap"), now)
        self._render_traffic(state["traffic"], overrides.get("traffic"), now)

    def _apply_override(self, ov: Dict[str, Any], now: float) -> Optional[Tuple[int, int, int]]:
        if not ov:
            return None
        expiry = ov.get("expiry")
        if expiry and now > expiry:
            return None
        color = tuple(ov.get("color", (0, 0, 0)))
        if ov.get("mode") == "blink":
            return blink(color, now)
        if ov.get("mode") == "pulse":
            return pulse(color, now)
        return color

    # quadrant renderers
    def _render_pi(self, data, ov, now):
        color = self._apply_override(ov, now)
        quad = (0, 0)
        if color is None:
            temp = data.get("temp", 0)
            warn = self.config.pi_health.get("warn", {})
            crit = self.config.pi_health.get("crit", {})
            color = (0, int(255 * min(temp, 80) / 80), 0)
            if data.get("load", 0) > warn.get("load", 2.0) or data.get("disk", 0) > warn.get("disk_pct", 85):
                color = blink(self.config.colors.get("warn", (255, 165, 0)), now)
            if temp > crit.get("temp_c", 80) or data.get("disk", 0) > crit.get("disk_pct", 95):
                color = pulse(self.config.colors.get("crit", (255, 0, 0)), now)
        self._fill_quad(quad, color)

    def _render_tor(self, data, ov, now):
        color = self._apply_override(ov, now)
        quad = (4, 0)
        if color is None:
            active = data.get("active")
            if active:
                color = self.config.colors.get("tor_on", (0, 255, 255))
            else:
                color = blink((255, 0, 0), now, period=0.5)
        self._fill_quad(quad, color)

    def _render_ap(self, data, ov, now):
        color = self._apply_override(ov, now)
        quad = (0, 4)
        if color is None:
            if data.get("active"):
                color = self.config.colors.get("ap_on", (0, 128, 255))
                self._fill_quad(quad, color)
                clients = int(data.get("clients", 0))
                for i in range(min(clients, 4)):
                    x = i
                    y = i
                    self._set_pixel(quad[0] + x, quad[1] + y, 255, 255, 255)
                return
            else:
                color = blink((255, 0, 0), now, period=0.5)
        self._fill_quad(quad, color)

    def _render_traffic(self, data, ov, now):
        color = self._apply_override(ov, now)
        quad = (4, 4)
        if color is None:
            level = int(data.get("level", 0))
            color = self.config.colors.get("ok", (0, 255, 0))
            self._fill_rows(quad, level, color)
            return
        self._fill_quad(quad, color)

    # drawing helpers
    def _fill_quad(self, origin: Tuple[int, int], color: Tuple[int, int, int]):
        ox, oy = origin
        for x in range(ox, ox + 4):
            for y in range(oy, oy + 4):
                self._set_pixel(x, y, *color)

    def _fill_rows(self, origin: Tuple[int, int], level: int, color: Tuple[int, int, int]):
        ox, oy = origin
        for i in range(level):
            for x in range(ox, ox + 4):
                for y in range(oy + 3 - i, oy + 4):
                    self._set_pixel(x, y, *color)

    def _set_pixel(self, x: int, y: int, r: int, g: int, b: int):
        if self.hd:
            if x < 8 and y < 8:
                self.uh.set_pixel(x, y, r, g, b)
        else:
            self.uh.set_pixel(x, y, r, g, b)


# animation helpers


def blink(color: Tuple[int, int, int], now: float, period: float = 1.0, duty: float = 0.5) -> Tuple[int, int, int]:
    phase = (now % period) / period
    return color if phase < duty else (0, 0, 0)


def pulse(color: Tuple[int, int, int], now: float, period: float = 1.0) -> Tuple[int, int, int]:
    phase = (now % period) / period
    intensity = 0.5 * (1 - math.cos(2 * math.pi * phase))
    return tuple(int(c * intensity) for c in color)


def breath(color: Tuple[int, int, int], now: float, period: float = 2.0) -> Tuple[int, int, int]:
    return pulse(color, now, period)

