#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/opt/arm-hunter"
ENV_FILE="/etc/arm-hunter.env"

mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/arm_hunter.py" "$TARGET_DIR/arm_hunter.py"
cp "$SCRIPT_DIR/cleanup_hunter.sh" "$TARGET_DIR/cleanup_hunter.sh"
cp "$SCRIPT_DIR/arm-hunter.env.example" "$TARGET_DIR/arm-hunter.env.example"
chmod +x "$TARGET_DIR/arm_hunter.py" "$TARGET_DIR/cleanup_hunter.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/arm-hunter.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE. Edit it before starting timer."
fi

if [[ ! -f "$TARGET_DIR/config" ]]; then
  echo "Missing $TARGET_DIR/config (OCI config file)"
  echo "Copy your OCI config there and ensure key_file points to $TARGET_DIR/oci_api_key.pem"
fi

if [[ ! -f "$TARGET_DIR/oci_api_key.pem" ]]; then
  echo "Missing $TARGET_DIR/oci_api_key.pem (OCI private key)"
fi

python3 -m venv "$TARGET_DIR/.venv"
"$TARGET_DIR/.venv/bin/python" -m pip install --upgrade pip >/dev/null
"$TARGET_DIR/.venv/bin/pip" install --prefer-binary "oci==2.168.2" >/dev/null

cp "$SCRIPT_DIR/arm-hunter.service" /etc/systemd/system/arm-hunter.service
cp "$SCRIPT_DIR/arm-hunter.timer" /etc/systemd/system/arm-hunter.timer

systemctl daemon-reload
systemctl enable --now arm-hunter.timer

echo "Installed. Check status: systemctl status arm-hunter.timer --no-pager"
echo "Tail logs: journalctl -u arm-hunter.service -f"
