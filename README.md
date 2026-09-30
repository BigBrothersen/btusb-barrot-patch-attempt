# Barrot 33fa:0001 Bluetooth dongle on Linux

Notes from debugging a cheap Barrot USB Bluetooth dongle that would not keep a
connection to a Sony WH-1000XM4 headset on Arch Linux, while the same dongle
worked fine on Windows on the same PC.

## Summary

- **Workaround:** plug the dongle in (or unplug and replug it) **after Linux
  has booted**. When the dongle is already plugged in at boot, the headset pairs
  and authenticates but drops the connection after about 10 seconds.
- Only a **physical** replug helps. Reloading `btusb` and re-authorizing the
  USB device in sysfs didn't fix it, and forcing a USB suspend made the
  controller stop responding entirely.
- After system sleep (S3) the dongle may hang on USB and needs a replug.
- A kernel patch was written and tested on the assumption that this dongle has
  the known "bulk RX needs one suspend" bug of Barrot-based fake CSR dongles.
  **It does not work:** once the suspend succeeds, the controller stops
  responding at all. The patch is kept in [`experiments/`](experiments/) as a
  documented dead end. Don't install it.

## Hardware and software

| | |
|---|---|
| Dongle (current) | USB `33fa:0001`, product "USB2.0-BT", bcdDevice 88.91, `bmAttributes` 0xc0 (no remote wakeup). btmon reports the manufacturer as Barrot Technology Limited. |
| Dongle (old) | USB `0a12:0001`, product "BT DONGLE10", bcdDevice 88.91. Fake CSR (HCI ver 12, rev 0x0201, manufacturer 10), detected by the kernel as an unbranded CSR clone. |
| Headset | Sony WH-1000XM4 |
| OS | Arch Linux, KDE Plasma, dual boot with Windows |
| Kernel | 7.2.7-arch1-1 (earlier 7.0.10-arch1-1) |
| Stack | BlueZ 5.87, PipeWire 1.6.9, WirePlumber 0.5.17 |

## Symptoms (33fa:0001 plugged in at boot)

bluetoothd:

```
src/device.c:search_cb() XX:XX:XX:XX:XX:XX: error updating services: Connection reset by peer (104)
src/profile.c:record_cb() Unable to get Hands-Free Voice gateway SDP record: Connection reset by peer
profiles/audio/avdtp.c:avdtp_connect_cb() connect to XX:XX:XX:XX:XX:XX: Connection reset by peer (104)
```

Kernel, in some attempts:

```
Bluetooth: hci0: Unexpected continuation: 1 bytes
```

btmon during a connection attempt:

1. Create Connection succeeds.
2. Authentication with the stored link key succeeds.
3. Encryption is enabled (E0; key size 16).
4. The host sends an L2CAP Information Request, then an L2CAP Connection
   Request for PSM 25 (AVDTP).
5. No inbound ACL data from the headset appears.
6. About 10 s later: Disconnect Complete, reason 0x13 (Remote User Terminated
   Connection).

HCI events arrive normally, but L2CAP traffic from the headset never arrives
intact.

After waking from S3 sleep:

```
usb 1-8: reset full-speed USB device number 4 using xhci_hcd
usb 1-8: can't restore configuration #1 (error=-110)
usb 1-8: device descriptor read/64, error -110
usb 1-8: device not accepting address 7, error -71
```

## What was tried

| Attempt | Result |
|---|---|
| Rolling BlueZ back to 5.83 | No change |
| Rolling the kernel back to 7.0.10 (old dongle) | No change |
| `ControllerMode = bredr`, `SecureConnections = off` in `/etc/bluetooth/main.conf` | No change |
| Reloading the driver (`modprobe -r btusb && modprobe btusb`) | No change |
| Forced USB runtime suspend from userspace ([`barrot-kick.sh`](experiments/barrot-kick.sh)) | Controller hangs: `Opcode 0x0c03 failed: -110` (HCI Reset timeout) until replugged |
| Kernel patch v1 (force-suspend at setup) | Suspend refused with `-11`, so no effect |
| Kernel patch v2 ([`btusb-force-suspend-v2.patch`](experiments/btusb-force-suspend-v2.patch)) | Suspend succeeds at boot, then the controller hangs (HCI Reset timeout) |
| USB deauthorize/reauthorize (`/sys/bus/usb/devices/1-8/authorized`) | Controller comes back up, but the headset still doesn't connect |
| **Physical replug after boot** | **Works.** Every successful connection on 2026-09-30 followed one. In one case a very quick unplug/replug left the controller unresponsive (HCI Reset timeout); replugging again with a short pause worked. |

## Why the patch looked plausible, and why it failed

`btusb` already has a workaround for Barrot-based fake CSR dongles (`0a12:0001`).
It was introduced by Hans de Goede's commit
"Bluetooth: btusb: Add workaround for remote-wakeup issues with Barrot 8041a02
fake CSR controllers" and later extended to all detected clones in
`btusb_setup_csr()`. The comment there says these controllers' bulk RX endpoint
"will never report any data unless the device was suspended at least once".
The kernel therefore force-suspends them once during setup.

The `33fa:0001` has the same bcdDevice (88.91) as those clones and showed a
similar symptom (events arrive, ACL data doesn't). Because it has its own
VID/PID, it never goes through `btusb_setup_csr()`. The patch added it to the
quirks table with the same suspend-once routine.

- **v1:** the suspend was refused with `-EAGAIN`. `btusb_open()` sets
  `needs_remote_wakeup` on the interface, and this dongle does not advertise
  remote wakeup (`bmAttributes` 0xc0), so the USB core won't suspend it.
- **v2:** clears `needs_remote_wakeup` around the forced suspend. The suspend
  then succeeds (`runtime_suspended_time` ≈ 200 ms). On resume, the USB core
  has to reset the device, and the controller no longer answers HCI Reset.

So whatever this dongle's problem is, it isn't the fake-CSR bulk RX bug, and a
USB suspend makes it worse.

## The old dongle (0a12:0001)

The kernel already applies the fake-CSR workarounds to it. It started dropping
off the USB bus by itself about every 20 seconds (`USB disconnect`, followed by
re-enumeration, with no kernel error beforehand). This happened on kernel
7.0.10 as well as 7.2.x. It was retired.

## Timeline

| Date | Event |
|---|---|
| 2026-09-17 | Last working session with the old dongle (kernel 7.0.10, BlueZ 5.86), after several replugs |
| 2026-09-18 | Failures on the same software; kernel 7.2.6 / BlueZ 5.87 / WirePlumber 0.5.17 installed that evening |
| 2026-09-19 to 09-29 | Separately, PipeWire registered no A2DP endpoints (`a2dp-sink profile connect failed: Protocol not available`); fixed on 09-29 |
| 2026-09-29 | New `33fa:0001` dongle: pairs, then drops |
| 2026-09-30 | Patch tested and ruled out; replug-after-boot found to work |

## Open questions

- Why the dongle works when hot-plugged but not when it is already plugged in
  at boot. The difference may be the BIOS's USB handoff, or the time between
  power-up and driver initialization. Not investigated.
- What the Windows driver does differently.
- Whether cutting port power in software (`/sys/bus/usb/devices/1-0:1.0/usb1-port8/disable`)
  could replace the physical replug. Untested; most desktop boards don't
  actually switch VBUS on their root ports.

## If you're buying a dongle

Avoid dongles that enumerate as `0a12:0001` (fake CSR) or with Barrot's `33fa`
vendor ID. Controllers with good mainline Linux support include Realtek
RTL8761B-based USB dongles (for example the TP-Link UB500; firmware is in
`linux-firmware`) and Intel AX200/AX210 cards.

## Files

- [`experiments/btusb-force-suspend-v2.patch`](experiments/btusb-force-suspend-v2.patch):
  kernel patch against v7.2.7 (`git am`-able). **Does not work; don't install
  it.** Kept for reference.
- [`experiments/barrot-kick.sh`](experiments/barrot-kick.sh): userspace
  version of the same suspend. **Hangs the controller**; kept for reference.

## References

- `drivers/bluetooth/btusb.c`, `btusb_setup_csr()`:
  <https://github.com/torvalds/linux/blob/master/drivers/bluetooth/btusb.c>
- Barrot 8041a02 workaround commit (xanmod mirror):
  <https://github.com/xanmod/linux/commit/0671c0662383eefc272e107364cba7fe229dee44>
- Unofficial reverse-engineered Barrot driver (not tested here):
  <https://github.com/zhuzhuzihan/brtusb>

## License

The patch modifies the Linux kernel and is GPL-2.0-only, as is the script. See
[LICENSE](LICENSE).
