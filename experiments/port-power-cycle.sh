#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Try to replace a physical replug of the Barrot 33fa:0001 dongle by
# switching off the USB port it is plugged into, using the port's sysfs
# "disable" attribute. Run as root.
#
# Power is only really cut if the USB host controller supports port power
# switching. Otherwise the port is disabled logically but stays powered.
#
# Result on the original PC (xHCI without port power control): the dongle
# re-enumerates, but the headset still can't connect. Doesn't help there.

V=$(grep -lx 33fa /sys/bus/usb/devices/*/idVendor 2>/dev/null | head -1)
[ -n "$V" ] || { echo "33fa dongle not found (is it plugged in?)"; exit 1; }
DEV=$(basename "$(dirname "$V")")		# e.g. 1-8
case $DEV in
*.*) echo "$DEV is behind an external hub; only root-hub ports are handled"; exit 1 ;;
esac
BUS=${DEV%%-*}
PORT=/sys/bus/usb/devices/$BUS-0:1.0/usb$BUS-port${DEV#*-}
PEER=$(readlink -f "$PORT/peer" 2>/dev/null)	# USB 3 side of the same connector
ports="$PORT $PEER"

enable() { for p in $ports; do echo 0 > "$p/disable"; done; }
trap enable EXIT

echo "Switching off: $ports"
for p in $ports; do echo 1 > "$p/disable"; done
sleep 5
echo "Switching back on"
enable
trap - EXIT

for i in $(seq 1 20); do
	[ -e "/sys/bus/usb/devices/$DEV/idVendor" ] && break
	sleep 0.5
done
if [ -e "/sys/bus/usb/devices/$DEV/idVendor" ]; then
	echo "Dongle is back on $DEV"
else
	echo "Dongle did not come back; replug it or reboot"
fi
