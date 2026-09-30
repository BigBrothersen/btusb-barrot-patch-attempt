#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Userspace emulation of btusb's "force-suspend once" workaround for the
# Barrot 33fa:0001 dongle. Run as root with the dongle plugged in.
#
# WARNING: kept as a record of a failed experiment. On the 33fa:0001 the
# suspend succeeds, but the controller then stops answering HCI commands
# (HCI Reset times out) until the dongle is physically replugged.
set -e

V=$(grep -lx 33fa /sys/bus/usb/devices/*/idVendor 2>/dev/null | head -1)
[ -n "$V" ] || { echo "33fa dongle not found (is it plugged in?)"; exit 1; }
D=$(dirname "$V")
echo "dongle: $D"

bluetoothctl power off >/dev/null        # close hci0 so the device may suspend
echo 0    > "$D/power/autosuspend_delay_ms"
echo auto > "$D/power/control"

for i in $(seq 1 20); do
	s=$(cat "$D/power/runtime_status")
	[ "$s" = suspended ] && break
	sleep 0.25
done
echo "runtime_status: $s"

echo on > "$D/power/control"             # wake it back up, keep it awake
sleep 0.5
bluetoothctl power on >/dev/null
echo "runtime_status now: $(cat "$D/power/runtime_status")"
[ "$s" = suspended ] && echo "OK: device was suspended once" \
	|| echo "WARNING: device never reached 'suspended'; test is inconclusive"
