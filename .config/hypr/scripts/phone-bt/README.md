# phone-bt

`BtDisconnect` disconnects one Bluetooth device on the Android phone, which no
normal app or `adb shell` command can do (hidden `BluetoothDevice.disconnect()`,
needs BLUETOOTH_PRIVILEGED, which the adb `shell` user holds). It runs on the
phone as `shell` via `app_process`; `headphones.sh` pushes and runs it.

Rebuild `btdisc.dex` after editing (reflection only, no android.jar needed):

    javac -source 8 -target 8 -d out BtDisconnect.java
    d8 --min-api 29 --output . out/BtDisconnect.class && mv classes.dex btdisc.dex

Run by hand: `adb shell 'CLASSPATH=/data/local/tmp/btdisc.dex app_process /system/bin BtDisconnect <MAC> disconnect'`
