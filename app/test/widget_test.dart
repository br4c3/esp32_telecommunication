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

    expect(find.text('L1 · S1'), findsOneWidget);
    expect(find.text('C1 · S5'), findsOneWidget);
    expect(find.text('앞 · 무릎 방향'), findsOneWidget);
    expect(find.text('뒤 · 등받이 방향'), findsOneWidget);
  });

  testWidgets('demo screen shows and controls simulated pressure', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: PressureDemoPage()));

    expect(find.text('먼저 방석을 비워주세요'), findsOneWidget);
    await tester.ensureVisible(find.text('1단계 · 5초 무부하 보정 시작'));
    await tester.pump();
    await tester.tap(find.text('1단계 · 5초 무부하 보정 시작'));
    await tester.pump();
    expect(find.text('영점값을 측정하고 있어요'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('방석에 정자세로 앉아주세요'), findsOneWidget);
    await tester.ensureVisible(find.text('2단계 · 5초 정자세 보정 시작'));
    await tester.tap(find.text('2단계 · 5초 정자세 보정 시작'));
    await tester.pump();
    expect(find.text('정자세 압력을 측정하고 있어요'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('L1 · S1'), findsOneWidget);
    expect(find.text('C1 · S5'), findsOneWidget);
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
              onStartZero: () => started = true,
              onStartBalance: () {},
              onContinueWarning: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('먼저 방석을 비워주세요'), findsOneWidget);
    expect(find.text('1단계 · 5초 무부하 보정 시작'), findsOneWidget);
    await tester.tap(find.text('1단계 · 5초 무부하 보정 시작'));
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
              onStartZero: () {},
              onStartBalance: () => started = true,
              onContinueWarning: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('캘리브레이션 · 2 / 2'), findsOneWidget);
    expect(find.text('방석에 정자세로 앉아주세요'), findsOneWidget);
    expect(find.text('2단계 · 5초 정자세 보정 시작'), findsOneWidget);
    await tester.tap(find.text('2단계 · 5초 정자세 보정 시작'));
    expect(started, isTrue);
  });

  testWidgets(
    'allows continuing when seated calibration has unloaded sensors',
    (tester) async {
      var continued = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 800,
              child: CalibrationPanel(
                status: CalibrationStatus.balanceWarning,
                warningSensors: const [3],
                onStartZero: () {},
                onStartBalance: () {},
                onContinueWarning: () => continued = true,
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('무부하 센서가 있어도 그냥 계속하시겠습니까?'), findsOneWidget);
      expect(find.text('고장 의심 센서: L2 · S3 · 왼쪽 뒤'), findsOneWidget);
      await tester.ensureVisible(find.text('그래도 계속 진행'));
      await tester.tap(find.text('그래도 계속 진행'));
      expect(continued, isTrue);
    },
  );
}
