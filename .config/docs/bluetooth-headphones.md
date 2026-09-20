# Bluetooth headphones handover (host3 <-> phone)

`mod+b` / `mod+ctrl+b` move one pair of Bluetooth headphones between this
machine (host3, BlueZ) and the Android phone, which both have them paired.
A headset held by one refuses the other, so each key first makes the current
holder let go.

| Key | Does |
|---|---|
| `mod+b` | phone releases the headphones, then host3 connects them |
| `mod+ctrl+b` | host3 disconnects them, then the phone connects them |

## Files

| Path | Role |
|---|---|
| `~/.config/hypr/bluetooth-headphones.conf` | `HEADPHONES_ID=<MAC>` (the `bluetoothctl` address) and `PHONE_HOST=<ip>` (empty = skip the phone step) |
| `~/.config/hypr/scripts/headphones.sh` | `connect` / `disconnect`; the whole handover, driven from host3 |
| `~/.config/hypr/scripts/phone-bt/BtDisconnect.java`, `btdisc.dex` | tiny helper run **on the phone** as adb's `shell` user; `README.md` there has the rebuild recipe |
| `~/.config/hypr/keybinds.lua` | the two binds (they appear in the `mod+?` cheat-sheet) |
| PeerAgent Companion app (`github.com/baleti/peeragent-android`) | lends out Wireless debugging: `GET /adb-port`, `POST /adb/enable`, `POST /adb/release` on `:8788` |

## Why it needs adb

Connecting or disconnecting a single Bluetooth device needs
`BLUETOOTH_PRIVILEGED`, which no normal app can hold (being the default
assistant or a notification listener does not help). Android 13+ also blocks
apps from toggling Bluetooth at all. The one privileged identity a user can
reach is adb's `shell` user, so host3 talks to the phone over adb (via
WireGuard) and runs `BtDisconnect` there through `app_process`. It calls the
hidden `BluetoothDevice.connect()` / `disconnect()` by reflection. Shizuku was
considered and is not needed: it is just a longer-lived bridge to the same
adb shell.

## The handover ("dance")

```
host3                                          phone (Companion app)
  |-- POST /adb/enable ----------------------->  Wireless debugging on if it was off
  |<-------------------------- port ----------   (port learned from adbd's mDNS advert)
  |-- adb connect <ip>:<port>
  |-- adb push btdisc.dex ; adb shell app_process ... BtDisconnect <MAC> disconnect|connect
  |-- POST /adb/release -------------------->   off again, only if /adb/enable turned it on
  |-- bluetoothctl connect|disconnect <MAC>
```

The Wireless debugging port changes on every toggle and reboot, which is why
the app reports it instead of host3 scanning for it (an `nmap` sweep works but
is slow, and useless when it is off). If the caller never releases, the app
switches it off itself after 90 s.

## One-time setup

1. Pair host3's adb key with the phone once: phone > Developer options >
   Wireless debugging > *Pair device with pairing code*, then
   `adb pair <ip>:<pair port> <code>`.
2. Let the app write the setting (lost if the app is uninstalled):
   `adb shell pm grant dev.local.peeragent android.permission.WRITE_SECURE_SETTINGS`
3. Put the addresses in `bluetooth-headphones.conf`.

## Failure behaviour

The phone step is best-effort: if the phone is unreachable or Wireless
debugging cannot come up, it is skipped and the headphones are still
connected/disconnected on host3. If the port is open but adb's TLS handshake
is rejected (`adb connect` prints `failed to connect`, not `cannot connect`),
the phone no longer trusts host3's key and a critical notification says so,
with the re-pairing steps. Runs are serialised with `flock` so two presses do
not race.

## Gotchas found while building it

- `timeout adbq ...` fails silently when `adbq` is a shell function; call the
  real binary.
- The adb background server, if first started inside the locked section,
  inherits the lock fd and holds it forever. Every adb call closes fd 9
  (`9>&-`).
- adbd re-advertises under the **same mDNS service name** with a new port on
  each toggle, so a late "service lost" can erase the new port. The app
  restarts discovery when it turns Wireless debugging on and only reports a
  port that is really listening. A discovery listener object cannot be
  reused (`listener already in use`); each run makes a fresh one.
- A bare `app_process` on Android 17 gets a `null` `BluetoothAdapter` until
  `ActivityThread.initializeMainlineModules()` has been called; the helper
  calls it first.
- `bluetoothctl` colours its output even when piped; strip the escapes before
  putting it in a notification.
