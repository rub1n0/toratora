# Status Matrix

This module provides a small status display on the Pimoroni Unicorn HAT. Four quadrants show Raspberry Pi health, Tor service state, access point status and network traffic.

## Files

* `status_matrix.py` – main module with `StatusMatrix` class.
* `status_matrix_service.py` – simple runner/CLI for systemd.
* `status_matrix.yaml` – default configuration.
* `status-matrix.service` – example systemd unit.
* `tests/test_status_matrix.py` – unit tests.

## Installation

1. Install dependencies:

```bash
sudo apt install python3-yaml python3-unicornhat python3-unicornhathd
# or use: pip install -r requirements.txt
```

2. Copy files to desired directory, e.g. `/home/pi`.
3. Adjust `status_matrix.yaml` if required. Set `use_unicorn_hat: false`
   to run the service without the hardware.

## Running

```bash
python3 status_matrix_service.py --config status_matrix.yaml
```

Use `--demo` to run a simple colour cycle demonstration. `--print-debug` dumps collected metrics once per second.
Add `--no-hat` to run without Unicorn HAT output.

## Service

Install the provided systemd unit:

```bash
sudo cp status-matrix.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now status-matrix.service
```

## Troubleshooting

* If the Unicorn HAT is not detected the service runs but does not output any pixels.
* Ensure the `iw` command is available for access point statistics or run service as a user with permission to access it.
