# esp32_telecommunication
# ESP32 Flutter BLE Terminal

This repository contains an ESP32 Arduino sketch and a Flutter mobile app that
communicate over Bluetooth Low Energy (BLE).

## Protocol

- Device name: `ESP32-P-XXXXXX` (`XXXXXX` is the six-digit chip code)
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- Phone writes to RX: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- Phone receives TX notifications: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Calibration status query: phone writes `GET_CALIBRATION_STATUS` to RX
- Zero calibration: phone writes `CALIBRATE_ZERO` to RX
- First-use sensor balance: phone writes `CALIBRATE_BALANCE` to RX
- Calibration status: ESP32 notifies `S:SETUP_REQUIRED`,
  `S:ZERO_CALIBRATING`, `S:BALANCE_REQUIRED`,
  `S:BALANCE_CALIBRATING`, and `S:READY` as the setup advances. Invalid
  unloaded wiring is reported as `S:ZERO_FAILED`.

The ESP32-C3 reads five pressure sensors from ADC1 GPIO pins 0, 1, 2, 3, and 4.
The voltage-divider topology is 3.3 V -> 10 kOhm -> ADC tap -> FSR -> GND, so
pressure is calculated from the voltage drop below each unloaded baseline. On
first use, a flat plate and uniform reference load are used to
calculate a separate gain for each sensor. Those gains are stored in ESP32 NVS,
while the unloaded baseline is refreshed for five seconds whenever the device is
connected. The ESP32 then sends filtered and balanced values at about 20 Hz as
`P:v1,v2,v3,v4,v5`. The app
solves a five-sensor Gaussian RBF system and projects the result onto a 48-by-72
aligned rectangular grid. The finer cells are interpolated estimates, not additional
physical measurements. Messages sent by the app are still printed to the
Arduino Serial Monitor at 115200 baud.

## Run

1. Open `esp/esp.ino` in Arduino IDE, select the correct ESP32 board and port,
   and upload it.
2. Leave all five sensors unloaded during the five-second startup calibration.
   Open Serial Monitor at 115200 baud and confirm that BLE advertising starts.
   Copy the printed `ESP32:XXXXXX` value into a QR code or barcode label and
   attach it to that ESP32.
3. Connect a physical Android or iOS phone, or use a Bluetooth-capable Mac. BLE
   is not available in most mobile simulators.
4. From the repository root, run:

   ```sh
   cd app
   flutter pub get
   flutter run
   ```

5. Grant Bluetooth and camera permission, tap **기기 코드 스캔**, and scan the
   label. The app scans BLE advertisements for the matching chip code and
   connects automatically. Remove all weight from the cushion and run the
   five-second calibration shown in the app. The Bluetooth icon remains
   available for manual discovery.

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
