import 'package:esp32_telecommunication/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('shows disconnected terminal screen', (tester) async {
    await tester.pumpWidget(const Esp32App(requestBluetoothOnLaunch: false));

    expect(find.text('ESP32 압력 모니터'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Scan for ESP32'), findsOneWidget);
  });

  test('parses a six-sensor pressure packet', () {
    final frame = PressureFrame.tryParse('P:0,12,345,678,999,2000');
    expect(frame?.values, [0, 12, 345, 678, 999, 2000]);
    expect(PressureFrame.tryParse('P:1,2,3'), isNull);
    expect(PressureFrame.tryParse('hello'), isNull);
  });

  testWidgets('pressure grid displays all six sensors', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: PressureGrid(values: [0, 10, 20, 30, 40, 50]),
          ),
        ),
      ),
    );

    expect(find.text('센서 1'), findsOneWidget);
    expect(find.text('센서 6'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(6));
  });
}
