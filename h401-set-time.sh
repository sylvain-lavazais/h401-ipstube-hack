#!/usr/bin/env bash
# Set the time on an IPSTube H401 clock over BLE (Nordic UART Service).
#
# Protocol (reverse-engineered from the IPSTUBE Android app v4.3.7):
#   Frame:  A5 <cmd> <payload...> <checksum> 5A
#   Checksum = (cmd + sum(payload)) & 0xFF
#   Writes must be BLE Write Commands (without response) to NUS RX (6E400002),
#   notifications arrive on NUS TX (6E400003). ACK frame: A5 <cmd> 00 <checksum> 5A
#
# Commands used here:
#   0x59  set timestamp, payload = unix epoch seconds, big-endian
#   0x53  sync-to-phone mode, payload = GMT offset in quarter-hours (15 min units)
#
# Usage: ./h401-set-time.sh
#   The script prompts for the clock's MAC address (there is no built-in
#   default). Find it with e.g. `bluetoothctl scan on`; the clock advertises
#   as IPSTube_XXXXXX.

set -euo pipefail

# --- ask for the device address ---
while true; do
    read -r -p "Clock MAC address: " MAC
    if [[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        break
    fi
    echo "Please enter a MAC address in the form AA:BB:CC:DD:EE:FF." >&2
done

RX_HANDLE="0x002d"     # NUS RX value handle (6E400002) on this firmware
CCCD_HANDLE="0x002b"   # CCCD of NUS TX (6E400003)

# --- timestamp frame (cmd 0x59) ---
SEC=$(date +%s)
HEX=$(printf '%x' "$SEC")
[ $(( ${#HEX} % 2 )) -ne 0 ] && HEX="0$HEX"

sum=$((0x59))
PAYLOAD=""
for (( i=0; i<${#HEX}; i+=2 )); do
    b="0x${HEX:i:2}"
    PAYLOAD+=" $(printf '%02x' "$b")"
    sum=$(( sum + b ))
done
TS_FRAME="a5 59 ${PAYLOAD} $(printf '%02x' $(( sum & 0xff ))) 5a"

# --- GMT offset frame (cmd 0x53), quarter-hours = minutes/15 ---
z=$(date +%z)
sign="${z:0:1}"; hh=$((10#${z:1:2})); mm=$((10#${z:3:2}))
q=$(( (hh * 60 + mm) / 15 ))
[ "$sign" = "-" ] && q=$((-q))
GQ=$(printf '%02x' $(( q & 0xff )))
GMT_FRAME="a5 53 ${GQ} $(printf '%02x' $(( (0x53 + q) & 0xff ))) 5a"

echo "Device:     $MAC"
echo "Timestamp:  $SEC (epoch)  frame: ${TS_FRAME}"
echo "GMT offset: $q quarter-hours  frame: ${GMT_FRAME}"

# --- connect, enable notifications, send both frames (interactive session) ---
{
    echo "connect"
    sleep 3
    echo "char-write-req $CCCD_HANDLE 0100"
    sleep 1
    echo "char-write-cmd $RX_HANDLE ${TS_FRAME// /}"
    sleep 3
    echo "char-write-cmd $RX_HANDLE ${GMT_FRAME// /}"
    sleep 3
    echo "exit"
} | timeout 25 gatttool -b "$MAC" -I

echo "Done. Verify the clock display; ACK frames appear above as notifications."
