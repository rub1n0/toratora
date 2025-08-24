import time
import status_matrix
from status_matrix import StatusMatrix, Config


def test_traffic_bucket():
    cfg = Config()
    sm = StatusMatrix(config=cfg)
    values = [(0, 0), (16000, 16000)]
    sm._read_iface_bytes = lambda iface: values.pop(0)
    orig_sleep = status_matrix.time.sleep
    status_matrix.time.sleep = lambda _s: None
    try:
        level = sm._read_traffic_level('eth0')
    finally:
        status_matrix.time.sleep = orig_sleep
    assert level == 4  # above highest bucket


def test_hd_slice():
    cfg = Config()
    sm = StatusMatrix(config=cfg)
    sm.hd = True
    pixels = []

    class Dummy:
        def set_pixel(self, x, y, r, g, b):
            pixels.append((x, y, r, g, b))
        def show(self):
            pass
        def clear(self):
            pass
        def brightness(self, v):
            pass

    sm.uh = Dummy()
    sm._set_pixel(10, 10, 1, 2, 3)
    sm._set_pixel(7, 7, 1, 2, 3)
    assert (7, 7, 1, 2, 3) in pixels
    assert all(x < 8 and y < 8 for x, y, *_ in pixels)


def test_pi_health_warn_color():
    cfg = Config(
        pi_health={'warn': {'load': 2.0, 'disk_pct': 85}, 'crit': {'temp_c': 80, 'disk_pct': 95}},
        colors={'warn': (1, 2, 3)}
    )
    sm = StatusMatrix(config=cfg)
    captured = []
    sm._fill_quad = lambda origin, color: captured.append(color)
    sm._render_pi({'temp': 50, 'load': 3.0, 'disk': 50}, None, 0)
    assert captured[0] == (1, 2, 3)


def test_pi_health_gradient():
    cfg = Config(
        pi_health={'warn': {'load': 2.0, 'disk_pct': 85}, 'crit': {'temp_c': 80, 'disk_pct': 95}}
    )
    sm = StatusMatrix(config=cfg)
    captured = []
    sm._fill_quad = lambda origin, color: captured.append(color)
    sm._render_pi({'temp': 40, 'load': 0.5, 'disk': 10}, None, 0)
    assert captured[0][1] == int(255 * 40 / 80)
