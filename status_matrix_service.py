import argparse
import signal
import time
import logging

from status_matrix import StatusMatrix

logging.basicConfig(level=logging.INFO)


def demo(sm: StatusMatrix):
    sm.start()
    quads = ['pi', 'tor', 'ap', 'traffic']
    colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
    try:
        i = 0
        while True:
            q = quads[i % 4]
            sm.set_override(q, colors[i % 4], mode='blink', duration=1.5)
            time.sleep(2)
            i += 1
    except KeyboardInterrupt:
        pass
    finally:
        sm.stop()


def main():
    parser = argparse.ArgumentParser(description="Status matrix service")
    parser.add_argument('--config', default='status_matrix.yaml')
    parser.add_argument('--brightness', type=float)
    parser.add_argument('--iface')
    parser.add_argument('--no-hat', action='store_true',
                        help='run without Unicorn HAT output')
    parser.add_argument('--demo', action='store_true')
    parser.add_argument('--print-debug', action='store_true')
    args = parser.parse_args()
    sm = StatusMatrix(config_path=args.config)
    if args.no_hat:
        sm.config.use_unicorn_hat = False
        sm._init_device()
    if args.brightness is not None:
        sm.uh.brightness(args.brightness)
    if args.iface:
        sm.config.iface = args.iface

    if args.demo:
        demo(sm)
        return

    sm.start()

    def shutdown(_signum, _frame):
        sm.stop()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    try:
        while True:
            if args.print_debug:
                with sm.lock:
                    logging.info("state: %s", sm.state)
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        sm.stop()


if __name__ == '__main__':
    main()
