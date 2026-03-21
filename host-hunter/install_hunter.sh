#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/opt/arm-hunter"
ENV_FILE="/etc/arm-hunter.env"

RUNTIME_USER="${SUDO_USER:-root}"
RUNTIME_HOME="$(getent passwd "$RUNTIME_USER" | cut -d: -f6 || true)"
if [[ -z "$RUNTIME_HOME" ]]; then
  RUNTIME_HOME="/root"
fi

mkdir -p "$TARGET_DIR"
cp "$SCRIPT_DIR/arm_hunter.py" "$TARGET_DIR/arm_hunter.py"
cp "$SCRIPT_DIR/cleanup_hunter.sh" "$TARGET_DIR/cleanup_hunter.sh"
cp "$SCRIPT_DIR/arm-hunter.env.example" "$TARGET_DIR/arm-hunter.env.example"
chmod +x "$TARGET_DIR/arm_hunter.py" "$TARGET_DIR/cleanup_hunter.sh"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$SCRIPT_DIR/arm-hunter.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE"
fi

# Auto-import OCI config and key from the current host user if not present.
SOURCE_OCI_CONFIG="$RUNTIME_HOME/.oci/config"
SOURCE_OCI_KEY="$RUNTIME_HOME/.oci/oci_api_key.pem"

if [[ ! -f "$TARGET_DIR/config" && -f "$SOURCE_OCI_CONFIG" ]]; then
  cp "$SOURCE_OCI_CONFIG" "$TARGET_DIR/config"
  chmod 600 "$TARGET_DIR/config"
  echo "Imported OCI config from $SOURCE_OCI_CONFIG"
fi

if [[ ! -f "$TARGET_DIR/oci_api_key.pem" && -f "$SOURCE_OCI_KEY" ]]; then
  cp "$SOURCE_OCI_KEY" "$TARGET_DIR/oci_api_key.pem"
  chmod 600 "$TARGET_DIR/oci_api_key.pem"
  echo "Imported OCI key from $SOURCE_OCI_KEY"
fi

# Ensure OCI key carries marker line expected by OCI warning guidance.
if [[ -f "$TARGET_DIR/oci_api_key.pem" ]]; then
  if ! tail -n 1 "$TARGET_DIR/oci_api_key.pem" | grep -qx 'OCI_API_KEY'; then
    printf '%s\n' 'OCI_API_KEY' >> "$TARGET_DIR/oci_api_key.pem"
  fi
fi

# Ensure copied config points to key under /opt/arm-hunter.
if [[ -f "$TARGET_DIR/config" ]]; then
  if grep -q '^key_file=' "$TARGET_DIR/config"; then
    sed -i 's|^key_file=.*|key_file=/opt/arm-hunter/oci_api_key.pem|' "$TARGET_DIR/config"
  else
    printf '%s\n' 'key_file=/opt/arm-hunter/oci_api_key.pem' >> "$TARGET_DIR/config"
  fi
fi

# Auto-import SSH public key for launch metadata if available.
if [[ ! -f "$TARGET_DIR/id_rsa.pub" ]]; then
  if [[ -f "$RUNTIME_HOME/.ssh/id_ed25519.pub" ]]; then
    cp "$RUNTIME_HOME/.ssh/id_ed25519.pub" "$TARGET_DIR/id_rsa.pub"
    chmod 644 "$TARGET_DIR/id_rsa.pub"
    echo "Imported SSH key from $RUNTIME_HOME/.ssh/id_ed25519.pub"
  elif [[ -f "$RUNTIME_HOME/.ssh/id_rsa.pub" ]]; then
    cp "$RUNTIME_HOME/.ssh/id_rsa.pub" "$TARGET_DIR/id_rsa.pub"
    chmod 644 "$TARGET_DIR/id_rsa.pub"
    echo "Imported SSH key from $RUNTIME_HOME/.ssh/id_rsa.pub"
  fi
fi

# Prerequisite gate: do not start timer if OCI files are missing.
if [[ ! -f "$TARGET_DIR/config" ]]; then
  echo "Missing $TARGET_DIR/config"
  echo "Provide OCI config file, then rerun install script."
  exit 1
fi

if [[ ! -f "$TARGET_DIR/oci_api_key.pem" ]]; then
  echo "Missing $TARGET_DIR/oci_api_key.pem"
  echo "Provide OCI private key file, then rerun install script."
  exit 1
fi

python3 -m venv "$TARGET_DIR/.venv"
"$TARGET_DIR/.venv/bin/python" -m pip install --upgrade pip >/dev/null
"$TARGET_DIR/.venv/bin/pip" install --prefer-binary "oci==2.168.2" >/dev/null

cp "$SCRIPT_DIR/arm-hunter.service" /etc/systemd/system/arm-hunter.service
cp "$SCRIPT_DIR/arm-hunter.timer" /etc/systemd/system/arm-hunter.timer

systemctl daemon-reload
systemctl enable --now arm-hunter.timer

echo "Installed and started."
echo "Status: systemctl status arm-hunter.timer --no-pager"
echo "Logs:   journalctl -u arm-hunter.service -f"
