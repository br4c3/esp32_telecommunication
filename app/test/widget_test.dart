import 'package:esp32_telecommunication/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() {
  testWidgets('login only shows account providers before authentication', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));

    expect(find.byType(SeatCareCushionIcon), findsOneWidget);
    expect(find.text('Google로 계속하기'), findsOneWidget);
    expect(find.text('Apple로 계속하기'), findsOneWidget);
    expect(find.text('기기 권한 확인'), findsNothing);
    expect(
      find.image(const AssetImage('assets/images/google_g.png')),
      findsOneWidget,
    );
  });

  testWidgets('permission onboarding appears after login', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: DevicePermissionGate(onReady: () {})),
    );

    expect(find.text('Seat Care 사용 권한'), findsOneWidget);
    expect(find.text('카메라 권한'), findsOneWidget);
    expect(find.text('알림 권한'), findsNothing);
    expect(find.text('Bluetooth 권한'), findsNothing);
    expect(find.text('카메라 허용'), findsOneWidget);
    expect(
      find.text('카메라를 허용하면 QR 연결 화면으로 바로 이동합니다. 자세 알림은 연결 후 앱 화면의 팝업으로 표시됩니다.'),
      findsOneWidget,
    );
  });

  testWidgets('shows disconnected terminal screen', (tester) async {
    await tester.pumpWidget(const Esp32App(requestBluetoothOnLaunch: false));

    expect(find.text('ESP32 압력 모니터'), findsOneWidget);
    expect(find.text('연결되지 않음'), findsOneWidget);
    expect(find.text('기기 코드 스캔'), findsOneWidget);
    expect(find.text('압력 화면 테스트'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_alt_outlined));
    await tester.pumpAndSettle();
    expect(find.text('기기 코드 직접 입력'), findsOneWidget);
    expect(find.text('코드 적용'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('bottom navigation opens device settings', (tester) async {
    await tester.pumpWidget(const Esp32App(requestBluetoothOnLaunch: false));

    expect(find.text('홈'), findsOneWidget);
    expect(find.text('기기'), findsOneWidget);
    expect(find.text('기록'), findsOneWidget);
    expect(find.text('설정'), findsOneWidget);

    await tester.tap(find.text('기록'));
    await tester.pumpAndSettle();
    expect(find.text('자세 기록'), findsOneWidget);
    expect(find.text('이 날짜에는 기록이 없어요'), findsOneWidget);

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    expect(find.text('정자세 다시 보정'), findsOneWidget);
    expect(find.text('권한 안내'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('parses a five-sensor pressure packet', () {
    final frame = PressureFrame.tryParse('P:0,12,345,678,999');
    expect(frame?.values, [0, 12, 345, 678, 999]);
    expect(PressureFrame.tryParse('P:1,2,3'), isNull);
    expect(PressureFrame.tryParse('hello'), isNull);
  });

  test('detects sustained posture direction from calibrated pressure', () {
    expect(
      PostureAnalyzer.assess([100, 100, 100, 100, 100]).lean,
      PostureLean.center,
    );
    expect(
      PostureAnalyzer.assess([220, 80, 220, 80, 100]).lean,
      PostureLean.left,
    );
    expect(
      PostureAnalyzer.assess([80, 220, 80, 220, 100]).lean,
      PostureLean.right,
    );
    expect(
      PostureAnalyzer.assess([80, 220, 80, 220, 100]).lateral,
      greaterThan(.2),
    );
    expect(
      PostureAnalyzer.assess([220, 220, 70, 70, 70]).lean,
      PostureLean.front,
    );
    expect(
      PostureAnalyzer.assess([70, 70, 200, 200, 200]).lean,
      PostureLean.back,
    );
    expect(PostureAnalyzer.assess([5, 5, 5, 5, 5]).lean, PostureLean.notSeated);
  });

  test('stores measured and unavailable posture in daily summaries', () {
    final record = DailyPostureRecord.empty('2026-10-08');
    record.addAssessment(const PostureAssessment(PostureLean.center, 0), 9);
    record.addAssessment(const PostureAssessment(PostureLean.left, .3), 9);
    record.addUnavailable(10);

    final restored = DailyPostureRecord.fromJson(record.toJson());
    expect(restored.centered, 1);
    expect(restored.left, 1);
    expect(restored.unavailable, 1);
    expect(restored.totalSeconds, 3);
    expect(restored.postureScore, 50);
  });

  testWidgets('renders readable daily posture charts', (tester) async {
    final record = DailyPostureRecord.empty('2026-10-08');
    record.addAssessment(const PostureAssessment(PostureLean.center, 0), 9);
    record.addAssessment(const PostureAssessment(PostureLean.right, .4), 10);
    record.addUnavailable(11);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              DailyPostureDistribution(record: record),
              SizedBox(
                width: 400,
                height: 190,
                child: DailyPostureBarChart(record: record),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.textContaining('정자세'), findsOneWidget);
    expect(find.textContaining('오른쪽'), findsOneWidget);
    expect(find.textContaining('미측정'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('posture alert is shown as an in-app popup', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PostureAlertDialog(message: '왼쪽으로 치우쳐 있어요. 몸을 방석 중앙으로 옮겨 주세요.'),
        ),
      ),
    );

    expect(find.text('자세를 바로잡아 주세요'), findsOneWidget);
    expect(find.textContaining('왼쪽으로 치우쳐'), findsOneWidget);
    expect(find.text('확인'), findsOneWidget);
  });

  test('normalizes ESP32 barcode device codes', () {
    expect(DeviceCode.parse('ESP32:ABC123'), 'ABC123');
    expect(DeviceCode.parse('ESP32-P-abc123'), 'ABC123');
    expect(DeviceCode.parse('ABC123'), 'ABC123');
    expect(DeviceCode.parse('ESP32-Pressure-6'), isNull);
    expect(DeviceCode.parse('12345'), isNull);
  });

  test('translates Bluetooth failures into Korean guidance', () {
    expect(
      bluetoothErrorMessage(
        Exception('NotFoundError: User cancelled the requestDevice chooser.'),
        fallback: '검색 실패',
      ),
      'Bluetooth 기기 선택이 취소되었습니다.',
    );
    expect(
      bluetoothErrorMessage(
        Exception('requestDevice() must be called from a user gesture'),
        fallback: '검색 실패',
      ),
      'Bluetooth 검색 버튼을 직접 눌러 기기를 선택해 주세요.',
    );
    expect(
      bluetoothErrorMessage(
        Exception('Web Bluetooth is not supported'),
        fallback: '검색 실패',
      ),
      contains('Chrome 또는 Edge'),
    );
  });

  test('translates camera scanner failures into Korean guidance', () {
    expect(
      scannerErrorMessage(
        const MobileScannerException(
          errorCode: MobileScannerErrorCode.permissionDenied,
        ),
      ),
      contains('카메라 권한이 거부되었습니다'),
    );
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

  test('pressure heat does not wrap to the opposite cushion edge', () {
    final leftOnly = PressureField.interpolate(
      [2400, 0, 0, 0, 0],
      rows: 20,
      columns: 20,
    );
    final rightOnly = PressureField.interpolate(
      [0, 2400, 0, 0, 0],
      rows: 20,
      columns: 20,
    );

    expect(leftOnly[5][5], greaterThan(1000));
    expect(leftOnly[5][19], 0);
    expect(rightOnly[5][14], greaterThan(1000));
    expect(rightOnly[5][0], 0);
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
