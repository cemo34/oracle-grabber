#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---success}"
BASE_DIR="/opt/arm-hunter"

if [[ "$MODE" != "--success" ]]; then
  echo "Usage: $0 --success"
  exit 1
fi

echo "[cleanup] stopping timer/service"
systemctl disable --now arm-hunter.timer >/dev/null 2>&1 || true
systemctl disable --now arm-hunter.service >/dev/null 2>&1 || true

if [[ -f "/etc/systemd/system/arm-hunter.service" ]]; then
  rm -f /etc/systemd/system/arm-hunter.service
fi
if [[ -f "/etc/systemd/system/arm-hunter.timer" ]]; then
  rm -f /etc/systemd/system/arm-hunter.timer
fi
systemctl daemon-reload >/dev/null 2>&1 || true

if [[ -f "$BASE_DIR/oci_api_key.pem" ]]; then
  shred -u "$BASE_DIR/oci_api_key.pem" >/dev/null 2>&1 || rm -f "$BASE_DIR/oci_api_key.pem"
fi
if [[ -f "$BASE_DIR/config" ]]; then
  rm -f "$BASE_DIR/config"
fi
if [[ -f "$BASE_DIR/.hunter_success" ]]; then
  rm -f "$BASE_DIR/.hunter_success"
fi

echo "[cleanup] deleting $BASE_DIR"
nohup bash -c "sleep 2; rm -rf '$BASE_DIR'" >/dev/null 2>&1 &

echo "[cleanup] done"
