# esp32_telecommunication
# ESP32 Flutter BLE Terminal

This repository contains an ESP32 Arduino sketch and a Flutter mobile app that
communicate over Bluetooth Low Energy (BLE).

## Protocol

- Device name: `ESP32-ADS1115`
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- Phone writes to RX: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- Phone receives TX notifications: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

The current ESP32 firmware sends its uptime once per second. Messages sent by
the app are printed to the Arduino Serial Monitor at 115200 baud.

## Run

1. Open `esp/esp.ino` in Arduino IDE, select the correct ESP32 board and port,
   and upload it.
2. Open Serial Monitor at 115200 baud and confirm that BLE advertising starts.
3. Connect a physical Android or iOS phone, or use a Bluetooth-capable Mac. BLE
   is not available in most mobile simulators.
4. From the repository root, run:

   ```sh
   cd app
   flutter pub get
   flutter run
   ```

5. Grant Bluetooth permission, tap **Scan for ESP32**, then tap **Connect**.

To run it as a native macOS app instead, use:

```sh
cd app
flutter run -d macos
```

The first launch prompts for Bluetooth access. If access was previously denied,
enable it under **System Settings → Privacy & Security → Bluetooth**.

The app uses the nonprofit/personal-use option of the `flutter_blue_plus`
license. Review that package's license before distributing this app for a
commercial purpose.
