import 'package:esp32_telecommunication/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('shows disconnected terminal screen', (tester) async {
    await tester.pumpWidget(const Esp32App(requestBluetoothOnLaunch: false));

    expect(find.text('ESP32 압력 모니터'), findsOneWidget);
    expect(find.text('연결되지 않음'), findsOneWidget);
    expect(find.text('기기 코드 스캔'), findsOneWidget);
    expect(find.text('압력 화면 테스트'), findsOneWidget);
  });

  test('parses a five-sensor pressure packet', () {
    final frame = PressureFrame.tryParse('P:0,12,345,678,999');
    expect(frame?.values, [0, 12, 345, 678, 999]);
    expect(PressureFrame.tryParse('P:1,2,3'), isNull);
    expect(PressureFrame.tryParse('hello'), isNull);
  });

  test('normalizes ESP32 barcode device codes', () {
    expect(DeviceCode.parse('ESP32:ABC123'), 'ABC123');
    expect(DeviceCode.parse('ESP32-P-abc123'), 'ABC123');
    expect(DeviceCode.parse('ABC123'), 'ABC123');
    expect(DeviceCode.parse('ESP32-Pressure-6'), isNull);
    expect(DeviceCode.parse('12345'), isNull);
  });

  test('reconstructs a fine pressure field from five sensor samples', () {
    final field = PressureField.interpolate(
      [2000, 0, 0, 0, 0],
      rows: 18,
      columns: 12,
    );

    expect(field, hasLength(18));
    expect(field.first, hasLength(12));
    expect(field[3][3], greaterThan(field[14][9]));
    expect(field.expand((row) => row).every((value) => value >= 0), isTrue);
  });

  testWidgets('pressure grid displays all five sensors', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: PressureGrid(values: [0, 10, 20, 30, 40]),
          ),
        ),
      ),
    );

    expect(find.text('S1'), findsOneWidget);
    expect(find.text('S5'), findsOneWidget);
    expect(find.text('등받이 쪽'), findsOneWidget);
    expect(find.text('방석 앞쪽'), findsOneWidget);
  });

  testWidgets('demo screen shows and controls simulated pressure', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PressureDemoPage()));

    expect(find.text('먼저 방석을 비워주세요'), findsOneWidget);
    await tester.ensureVisible(find.text('5초 영점 보정 시작'));
    await tester.pump();
    await tester.tap(find.text('5초 영점 보정 시작'));
    await tester.pump();
    expect(find.text('영점값을 측정하고 있어요'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('S1'), findsOneWidget);
    expect(find.text('S5'), findsOneWidget);
    expect(find.text('48 × 72 압력 그리드'), findsOneWidget);
    expect(find.text('일시정지'), findsOneWidget);

    await tester.tap(find.text('일시정지'));
    await tester.pump();
    expect(find.text('재생'), findsOneWidget);
  });

  testWidgets('calibration panel guides an unloaded five-second setup', (
    tester,
  ) async {
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: CalibrationPanel(
              status: CalibrationStatus.zeroRequired,
              firstSetup: false,
              onStartZero: () => started = true,
              onStartBalance: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('먼저 방석을 비워주세요'), findsOneWidget);
    expect(find.text('5초 영점 보정 시작'), findsOneWidget);
    await tester.tap(find.text('5초 영점 보정 시작'));
    expect(started, isTrue);
  });

  testWidgets('first setup requests a one-time sensor balance step', (
    tester,
  ) async {
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: CalibrationPanel(
              status: CalibrationStatus.balanceRequired,
              firstSetup: true,
              onStartZero: () {},
              onStartBalance: () => started = true,
            ),
          ),
        ),
      ),
    );

    expect(find.text('최초 설정 · 2 / 2'), findsOneWidget);
    expect(find.text('센서 균형을 맞춰주세요'), findsOneWidget);
    expect(find.text('5초 센서 균형 보정 시작'), findsOneWidget);
    await tester.tap(find.text('5초 센서 균형 보정 시작'));
    expect(started, isTrue);
  });
}
