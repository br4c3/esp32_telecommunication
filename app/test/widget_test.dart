import 'package:esp32_telecommunication/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows disconnected terminal screen', (tester) async {
    await tester.pumpWidget(const Esp32App(requestBluetoothOnLaunch: false));

    expect(find.text('ESP32 BLE Terminal'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Scan for ESP32'), findsOneWidget);
  });
}
