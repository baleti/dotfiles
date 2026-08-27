pragma Singleton
import QtQuick
import Quickshell.Services.UPower

QtObject {
    readonly property var device: UPower.displayDevice
    readonly property bool present: device?.isLaptopBattery ?? false
    // UPower's own D-Bus percentage is 0-100, but Quickshell's wrapper
    // normalises it to 0-1 (confirmed by testing: upower -i reported 100%
    // while this read 1.0).
    readonly property real percent: (device?.percentage ?? 0) * 100
    readonly property bool charging: present && [UPowerDeviceState.Charging, UPowerDeviceState.FullyCharged, UPowerDeviceState.PendingCharge].includes(device.state)
    readonly property bool onBattery: UPower.onBattery
}
