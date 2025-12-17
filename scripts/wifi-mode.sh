#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="@hostname@"
WIFI_CONF="@wifiConfPath@"
ROS_SERVICES=(
@rosServices@
)

restart_ros_services() {
  if [ "${#ROS_SERVICES[@]}" -eq 0 ]; then
    return
  fi
  local svc
  for svc in "${ROS_SERVICES[@]}"; do
    if [ -z "$svc" ]; then
      continue
    fi

    # Check if service is loaded
    if ! systemctl list-unit-files "$svc" >/dev/null 2>&1; then
      echo "[wifi-mode] Service $svc not found, skipping" >&2
      continue
    fi

    # Check if service is active/activating before restarting
    local state
    state="$(systemctl is-active "$svc" 2>/dev/null || echo 'inactive')"

    if [ "$state" = "inactive" ] || [ "$state" = "failed" ]; then
      echo "[wifi-mode] Service $svc is $state, starting instead of restarting" >&2
      if systemctl start --no-block "$svc" 2>&1; then
        echo "[wifi-mode] Successfully queued start for $svc" >&2
      else
        echo "[wifi-mode] Warning: failed to start $svc" >&2
      fi
    else
      echo "[wifi-mode] Restarting $svc (current state: $state)" >&2
      if systemctl restart --no-block "$svc" 2>&1; then
        echo "[wifi-mode] Successfully queued restart for $svc" >&2
      else
        echo "[wifi-mode] Warning: failed to restart $svc" >&2
      fi
    fi
  done
}

# Wait for NetworkManager D-Bus interface to be ready (up to 30s)
echo "[wifi-mode] Waiting for NetworkManager D-Bus interface..." >&2
for i in $(seq 1 60); do
  if nmcli -t -f RUNNING general 2>/dev/null | grep -q "running"; then
    echo "[wifi-mode] NetworkManager is ready" >&2
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[wifi-mode] ERROR: NetworkManager D-Bus interface not ready after 30s" >&2
    exit 1
  fi
  sleep 0.5
done

# wait up to ~10s for NM + wifi device
for _ in $(seq 1 20); do
  if nmcli -t -f DEVICE,TYPE device 2>/dev/null | grep -q ":wifi"; then
    break
  fi
  sleep 0.5
done

WIFI_IF="$(nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi"{print $1;exit}')"
if [ -z "$WIFI_IF" ]; then
  echo "[wifi-mode] No Wi-Fi interface found" >&2
  exit 0
fi

ensure_ap() {
  local ap_ssid="polyflow-robot-setup"
  local ap_pass="@password@"

  if ! nmcli -t -f NAME connection show | grep -Fx "robot-ap" >/dev/null; then
    # Add AP profile with shared-mode up front to avoid race on first activation
    nmcli connection add type wifi ifname "$WIFI_IF" mode ap con-name robot-ap ssid "$ap_ssid" \
      ipv4.method shared ipv6.method ignore

    nmcli connection modify robot-ap \
      802-11-wireless-security.key-mgmt wpa-psk \
      802-11-wireless-security.psk "$ap_pass"
  fi

  nmcli connection modify robot-ap connection.autoconnect yes || true

  # Remove any stale dnsmasq pid that can block shared-mode start (iface-safe)
  rm -f "/run/nm-dnsmasq-${WIFI_IF}.pid" 2>/dev/null || true

  # Force a clean up/down to dodge first-boot AP races
  nmcli connection down robot-ap || true
  nmcli connection up robot-ap || true
}

# If no credentials, start AP
if [ ! -f "$WIFI_CONF" ]; then
  echo "[wifi-mode] wifi.conf missing; enabling AP mode" >&2
  ensure_ap
  exit 0
fi

# Read credentials
WIFI_SSID=""
WIFI_PSK=""
# shellcheck disable=SC1090
source "$WIFI_CONF" || true
if [ -z "${WIFI_SSID:-}" ]; then
  echo "[wifi-mode] WIFI_SSID empty; enabling AP mode" >&2
  ensure_ap
  exit 0
fi

# Find the first robot-wifi UUID (if any)
ROBOT_UUID="$(nmcli -t -f UUID,NAME connection show \
  | awk -F: '$2=="robot-wifi"{print $1; exit}')"

if [ -z "$ROBOT_UUID" ]; then
  echo "[wifi-mode] Creating new robot-wifi connection for SSID=$WIFI_SSID" >&2
  if ! nmcli connection add type wifi ifname "$WIFI_IF" con-name robot-wifi ssid "$WIFI_SSID"; then
    echo "[wifi-mode] ERROR: Failed to create robot-wifi connection" >&2
    echo "[wifi-mode] Falling back to AP mode" >&2
    ensure_ap
    exit 0
  fi
  # Capture UUID for the newly created connection so we never rely on NAME
  ROBOT_UUID="$(nmcli -t -f UUID,NAME connection show \
    | awk -F: '$2=="robot-wifi"{print $1; exit}')"
  if [ -z "$ROBOT_UUID" ]; then
    echo "[wifi-mode] ERROR: Failed to retrieve UUID for robot-wifi" >&2
    ensure_ap
    exit 0
  fi
else
  echo "[wifi-mode] Updating existing robot-wifi connection (UUID=$ROBOT_UUID)" >&2
  if ! nmcli connection modify "$ROBOT_UUID" 802-11-wireless.ssid "$WIFI_SSID"; then
    echo "[wifi-mode] WARNING: Failed to update SSID, attempting to continue..." >&2
  fi
fi

if [ -n "${WIFI_PSK:-}" ]; then
  if ! nmcli connection modify "$ROBOT_UUID" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$WIFI_PSK" \
    802-11-wireless-security.psk-flags 0; then
    echo "[wifi-mode] WARNING: Failed to set WPA-PSK credentials" >&2
  fi
else
  if ! nmcli connection modify "$ROBOT_UUID" 802-11-wireless-security.key-mgmt none; then
    echo "[wifi-mode] WARNING: Failed to set open network security" >&2
  fi
  # (Per your request, not applying my earlier "clear stale PSK" suggestion.)
fi

if ! nmcli connection modify "$ROBOT_UUID" \
  ipv4.method auto \
  ipv6.method auto \
  connection.autoconnect yes \
  connection.permissions ""; then
  echo "[wifi-mode] WARNING: Failed to set connection parameters" >&2
fi

# Optional stability tweak (NOT forcing, just leaving note):
# If STA bring-up is slow/flaky on some networks, consider:
# nmcli connection modify "$ROBOT_UUID" ipv6.method disabled

# Enable AP alongside STA for concurrent dual-mode operation
echo "[wifi-mode] Ensuring AP is active for dual-mode" >&2
ensure_ap

echo "[wifi-mode] Bringing up STA connection to SSID=$WIFI_SSID" >&2

# Re-apply PSK every run to ensure NM has the secret stored.
if [ -n "${WIFI_PSK:-}" ]; then
  nmcli connection modify "$ROBOT_UUID" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$WIFI_PSK"
fi

if nmcli connection up "$ROBOT_UUID"; then
  echo "[wifi-mode] STA connected successfully; dual-mode active (AP + STA)" >&2
  restart_ros_services
else
  echo "[wifi-mode] STA connection failed; AP remains active for setup" >&2
  # AP is already running from ensure_ap above
  exit 0
fi
